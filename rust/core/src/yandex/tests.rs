use super::*;
use std::{collections::HashMap, sync::Mutex};
use tiny_http::{Response, Server};

#[test]
fn callback_checks_origin_state_and_replay() {
    let mut a = Account {
        client: "example".into(),
        ..Account::default()
    };
    let authorize = Url::parse(&a.authorize().unwrap()).unwrap();
    let q: HashMap<_, _> = authorize.query_pairs().collect();
    assert_eq!(q["code_challenge_method"], "S256");
    assert!(
        a.callback("keykeep://oauth/callback?state=wrong&code=x")
            .is_err()
    );
    let callback = format!("{CALLBACK}?code=fixture&state={}", q["state"]);
    let (_, v) = a.callback(&callback).unwrap();
    assert_eq!(
        q["code_challenge"],
        URL_SAFE_NO_PAD.encode(Sha256::digest(v.as_bytes()))
    );
    assert!(a.callback(&callback).is_err());
}

#[derive(Default)]
struct Files {
    data: HashMap<String, Vec<u8>>,
    fail_snapshot: bool,
}
struct Mock {
    root: String,
    files: Arc<Mutex<Files>>,
    stop: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Mock {
    fn new() -> Self {
        let server = Server::http("127.0.0.1:0").unwrap();
        let root = format!("http://{}", server.server_addr());
        let shared = Arc::new(Mutex::new(Files::default()));
        let files = shared.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let done = stop.clone();
        let origin = root.clone();
        let worker = std::thread::spawn(move || {
            while !done.load(Ordering::Acquire) {
                let Some(mut req) = server.recv_timeout(Duration::from_millis(20)).unwrap() else {
                    continue;
                };
                let url = Url::parse(&origin).unwrap().join(req.url()).unwrap();
                let q: HashMap<_, _> = url.query_pairs().collect();
                let path = &q["path"];
                let auth = req.headers().iter().any(|h| h.field.equiv("Authorization"));
                let mut store = files.lock().unwrap();
                let (status,data)=match (req.method().as_str(),url.path()){
                    ("PUT","/resources") if path.ends_with(".keykeep-writing")=>{
                        if store.data.contains_key(path.as_ref()){(409,vec![])}else{store.data.insert(path.to_string(),vec![]);(201,vec![])}
                    }
                    ("DELETE","/resources") if path.ends_with(".keykeep-writing")=>{store.data.remove(path.as_ref());(204,vec![])},
                    ("PUT","/resources")=>(201,vec![]),
                    ("GET","/resources")=>match store.data.get(path.as_ref()){
                        None=>(404,vec![]),Some(d)=>(200,json!({"sha256":format!("{:x}",Sha256::digest(d)),"size":d.len(),"modified":"2026-01-01"}).to_string().into_bytes())
                    },
                    ("GET","/resources/download"|"/resources/upload")=>{
                        assert!(auth);
                        let mut transfer=Url::parse(&origin).unwrap().join("/transfer").unwrap();
                        transfer.query_pairs_mut().append_pair("path",path);
                        (200,json!({"href":transfer.to_string()}).to_string().into_bytes())
                    }
                    ("GET","/transfer")=>{assert!(!auth);(200,store.data[path.as_ref()].clone())}
                    ("PUT","/transfer")=>{
                        assert!(!auth);let mut bytes=vec![];req.as_reader().read_to_end(&mut bytes).unwrap();
                        if store.fail_snapshot && path.contains("keykeep-history"){(503,vec![])}
                        else{store.data.insert(path.to_string(),bytes);(201,vec![])}
                    }
                    _=>panic!("unexpected request")
                };
                req.respond(Response::from_data(data).with_status_code(status))
                    .unwrap();
            }
        });
        Self {
            root,
            files: shared,
            stop,
            worker: Some(worker),
        }
    }
    fn client(&self) -> Client {
        Client {
            api_root: format!("{}/resources", self.root),
            account: Account {
                token: "synthetic".into(),
                ..Default::default()
            },
            http: ureq::AgentBuilder::new().redirects(0).build(),
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }
}
impl Drop for Mock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.worker.take().unwrap().join().unwrap();
    }
}

#[test]
fn failed_snapshot_or_concurrent_change_preserves_remote() {
    let mock = Mock::new();
    let path = mock.client().path();
    mock.files
        .lock()
        .unwrap()
        .data
        .insert(path.clone(), b"original".to_vec());
    let expected = mock.client().info(&path).unwrap();
    mock.files.lock().unwrap().fail_snapshot = true;
    assert!(
        mock.client()
            .upload(b"next".to_vec(), expected.clone())
            .is_err()
    );
    assert_eq!(mock.files.lock().unwrap().data[&path], b"original");
    mock.files.lock().unwrap().fail_snapshot = false;
    assert!(mock.client().upload(b"next".to_vec(), Value::Null).is_err());
    mock.client().upload(b"next".to_vec(), expected).unwrap();
    let files = mock.files.lock().unwrap();
    assert_eq!(files.data[&path], b"next");
    assert!(
        files
            .data
            .iter()
            .any(|(k, v)| k.contains("cloud-before-upload") && v == b"original")
    );
}

#[test]
fn corrupt_restore_does_not_publish_backup_or_replace_vault() {
    let mock = Mock::new();
    let path = mock.client().path();
    mock.files
        .lock()
        .unwrap()
        .data
        .insert(path.clone(), b"damaged fixture".to_vec());
    let expected = mock.client().info(&path).unwrap();
    assert!(
        mock.client()
            .restore(
                vec![],
                Zeroizing::new("test".into()),
                String::new(),
                expected
            )
            .is_err()
    );
    assert_eq!(mock.files.lock().unwrap().data.len(), 1);
}

#[test]
fn valid_restore_keeps_local_copy_and_excludes_oauth_from_kdbx() {
    let mock = Mock::new();
    let path = mock.client().path();
    let mut vault = crate::legacy::Vault::from_android(None, None).unwrap();
    vault.disk.token = "test-token-excluded-from-export".into();
    let cloud = crate::kdbx::export(&vault, "testpw", None).unwrap();
    let local = crate::kdbx::export(&vault, "localpw", None).unwrap();
    mock.files
        .lock()
        .unwrap()
        .data
        .insert(path.clone(), cloud.clone());
    let expected = mock.client().info(&path).unwrap();
    let outcome = mock
        .client()
        .restore(
            local.clone(),
            Zeroizing::new("testpw".into()),
            String::new(),
            expected,
        )
        .unwrap();
    let Outcome::Restore(downloaded, password) = outcome else {
        panic!("unexpected result")
    };
    assert_eq!(cloud, downloaded);
    assert!(
        crate::kdbx::import(&downloaded, &password, None)
            .unwrap()
            .disk
            .token
            .is_empty()
    );
    let xml = keepass::Database::get_xml(
        &mut downloaded.as_slice(),
        keepass::DatabaseKey::new().with_password(&password),
    )
    .unwrap();
    assert!(
        !String::from_utf8(xml)
            .unwrap()
            .contains("test-token-excluded-from-export")
    );
    assert!(
        mock.files
            .lock()
            .unwrap()
            .data
            .iter()
            .any(|(k, v)| k.contains("local-before-restore") && v == &local)
    );
    let encrypted = crate::storage::seal(&vault, "123456", &[7; 32]).unwrap();
    assert!(
        !encrypted
            .windows(vault.disk.token.len())
            .any(|w| w == vault.disk.token.as_bytes())
    );
    assert_eq!(
        crate::storage::open(&encrypted, "123456", &[7; 32])
            .unwrap()
            .disk
            .token,
        vault.disk.token
    );
}

#[test]
fn merge_preserves_local_remote_histories_and_is_repeatable() {
    let mock = Mock::new();
    let path = mock.client().path();
    let local=crate::legacy::Vault::from_android(
        Some(r#"[{"id":"root","name":"Все записи"},{"id":"old-folder","name":"Работа"}]"#),
        Some(r#"[{"id":"old-id","folderId":"old-folder","title":"Example","username":"demo","password":"local-test","updatedAt":"2026-01-01T10:00:00Z","history":[{"changedAt":"2025-01-01","password":"earlier-local"}]}]"#)).unwrap();
    let mut remote = local.clone();
    remote.entries[0].values.password = "cloud-test".into();
    remote.entries[0].updated_at = "2026-01-02T06:00:00-03:00".into();
    remote.entries[0].history[0].password = Some("earlier-remote".into());
    let mut extra = remote.entries[0].clone();
    extra.id = "other-id".into();
    remote.entries.push(extra);
    let password = Zeroizing::new("fixture".to_string());
    let previous = crate::kdbx::export(&remote, &password, None).unwrap();
    mock.files
        .lock()
        .unwrap()
        .data
        .insert(path.clone(), previous.clone());
    let mut merged = local;
    for _ in 0..2 {
        let expected = mock.client().info(&path).unwrap();
        let Outcome::Merged(next, _) = mock
            .client()
            .merge(merged, password.clone(), expected)
            .unwrap()
        else {
            panic!("missing merge")
        };
        assert_eq!(next.entries.len(), 2);
        let e = next.entries.iter().find(|e| e.id == "old-id").unwrap();
        assert_eq!(e.values.folder_id, "old-folder");
        assert_eq!(e.values.password, "cloud-test");
        assert_eq!(e.history.len(), 3);
        assert!(
            e.history
                .iter()
                .any(|h| h.values.as_deref().unwrap_or("").contains("local-test"))
        );
        let uploaded = mock.files.lock().unwrap().data[&path].clone();
        let db = crate::kdbx::import(&uploaded, &password, None).unwrap();
        assert_eq!(db.entries.len(), 2);
        assert!(db.entries.iter().any(|e| e.history.len() == 3));
        merged = *next;
    }
    assert!(
        mock.files
            .lock()
            .unwrap()
            .data
            .iter()
            .any(|(k, v)| k.contains("cloud-before-upload") && *v == previous)
    );
}

#[test]
fn queued_upload_survives_restart_and_obeys_original_confirmation() {
    use crate::session::Session;
    fn wait(session: &mut Session) -> Result<Value> {
        for _ in 0..200 {
            let result = session.call(json!({"op":"diskPoll"}))?;
            if result["pending"] == false {
                return Ok(result["result"].clone());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Err("test job timeout")
    }
    let mock = Mock::new();
    let path = mock.client().path();
    let tmp = tempfile::tempdir().unwrap();
    let vault = tmp.path().join("vault.kk");
    let queued = vault.with_extension("pending-upload.kdbx");
    let api = format!("{}/resources", mock.root);
    let mut session = Session::new(vault.clone(), [3; 32]).unwrap();
    session
        .call(json!({"op":"create","pin":"test-pin"}))
        .unwrap();
    let disk = &mut session.unlocked.as_mut().unwrap().1.disk;
    disk.token = "test-token".into();
    disk.mock_api = Some(api.clone());
    mock.files.lock().unwrap().fail_snapshot = true;
    session
        .call(json!({"op":"diskUpload","expected":null,"confirmed":true,"password":"fixture"}))
        .unwrap();
    assert!(wait(&mut session).is_err());
    let saved = std::fs::read(&queued).unwrap();
    drop(session);
    let mut session = Session::new(vault, [3; 32]).unwrap();
    session
        .call(json!({"op":"unlock","pin":"test-pin"}))
        .unwrap();
    session.unlocked.as_mut().unwrap().1.disk.mock_api = Some(api);
    assert_eq!(
        session.call(json!({"op":"diskStatus"})).unwrap()["pendingUpload"],
        true
    );
    {
        let mut f = mock.files.lock().unwrap();
        f.fail_snapshot = false;
        f.data.insert(path.clone(), b"changed remotely".to_vec());
    }
    session.call(json!({"op":"diskRetryUpload"})).unwrap();
    assert!(wait(&mut session).is_err());
    assert_eq!(mock.files.lock().unwrap().data[&path], b"changed remotely");
    mock.files.lock().unwrap().data.remove(&path);
    session.call(json!({"op":"diskRetryUpload"})).unwrap();
    assert_eq!(wait(&mut session).unwrap()["uploaded"], true);
    assert_eq!(mock.files.lock().unwrap().data[&path], saved);
    assert!(!queued.exists());
    session
        .call(json!({"op":"addFolder","name":"Changed locally","parent":"root"}))
        .unwrap();
    mock.files
        .lock()
        .unwrap()
        .data
        .insert(path.clone(), b"changed remotely".to_vec());
    session.call(json!({"op":"diskInspect"})).unwrap();
    assert_eq!(wait(&mut session).unwrap()["conflict"], true);
    assert_eq!(
        session.call(json!({"op":"diskStatus"})).unwrap()["pendingUpload"],
        false
    );
}

#[test]
fn shared_account_requires_opt_in_and_never_persists_its_token_in_the_vault() {
    use crate::session::Session;
    let mock = Mock::new();
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("vault.kk");
    let mut session = Session::new(path.clone(), [7; 32]).unwrap();
    session
        .call(json!({"op":"create","pin":"fixture-pin"}))
        .unwrap();
    let upload = json!({"op":"diskUpload","accountBinding":"account-a","accountToken":"synthetic","password":"fixture","expected":null,"confirmed":true});
    assert!(session.call(upload.clone()).is_err());
    session.call(json!({"op":"diskBind","enabled":true,"folder":"Personal","accountBinding":"account-a"})).unwrap();
    session.unlocked.as_mut().unwrap().1.disk.mock_api = Some(format!("{}/resources", mock.root));
    let mut foreign = upload.clone();
    foreign["accountBinding"] = json!("account-b");
    assert!(session.call(foreign).is_err());
    session.call(upload.clone()).unwrap();
    let uploaded = loop {
        let result = session.call(json!({"op":"diskPoll"})).unwrap();
        if result["pending"] == false {
            break result["result"]["uploaded"].clone();
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(uploaded, true);
    assert!(
        mock.files
            .lock()
            .unwrap()
            .data
            .keys()
            .any(|p| p.ends_with("/Personal/keykeep-vault.kdbx"))
    );
    drop(session);
    let mut session = Session::new(path, [7; 32]).unwrap();
    session
        .call(json!({"op":"unlock","pin":"fixture-pin"}))
        .unwrap();
    assert!(session.unlocked.as_ref().unwrap().1.disk.token.is_empty());
    assert_eq!(
        session.call(json!({"op":"diskStatus"})).unwrap()["connected"],
        false
    );
    session
        .call(json!({"op":"diskBind","enabled":false}))
        .unwrap();
    assert!(session.call(upload).is_err());
}

#[test]
fn automatic_two_open_vaults_merge_and_resolve_conflicts() {
    use crate::session::Session;
    let mock = Mock::new();
    let tmp = tempfile::tempdir().unwrap();
    let open = |name: &str| {
        let mut session = Session::new(tmp.path().join(name), [3; 32]).unwrap();
        session
            .call(json!({"op":"create","pin":"fixture"}))
            .unwrap();
        let disk = &mut session.unlocked.as_mut().unwrap().1.disk;
        disk.mock_api = Some(format!("{}/resources", mock.root));
        disk.token = "test".into();
        session
            .call(json!({"op":"diskAutoConfigure","enabled":true,"password":"shared-fixture"}))
            .unwrap();
        session
    };
    let sync = |session: &mut Session, choices: Value| {
        session
            .call(json!({"op":"diskAutoSync","choices":choices}))
            .unwrap();
        for _ in 0..1000 {
            let state = session.call(json!({"op":"diskPoll"})).unwrap();
            if state["pending"] == false {
                return state["result"].clone();
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("automatic job timeout");
    };
    let save = |session: &mut Session, id: &str, title: &str, password: &str| {
        session.call(json!({"op":"save","id":id,"time":"2026-11-26T09:00:00Z","values":{"title":title,"username":"fixture","password":password,"folderId":"root"}})).unwrap().as_str().unwrap().to_owned()
    };
    let mut mac = open("mac.kk");
    let mut android = open("android.kk");
    let id = save(&mut mac, "", "first", "initial");
    sync(&mut mac, Value::Null);
    sync(&mut android, Value::Null);
    assert_eq!(
        android.call(json!({"op":"get","id":id})).unwrap()["password"],
        "initial"
    );
    save(&mut mac, &id, "first", "mac-edit");
    let other = save(&mut android, "", "second", "android-edit");
    sync(&mut mac, Value::Null);
    sync(&mut android, Value::Null);
    sync(&mut mac, Value::Null);
    assert_eq!(
        mac.call(json!({"op":"get","id":other})).unwrap()["password"],
        "android-edit"
    );
    save(&mut android, &id, "first", "android-conflict");
    save(&mut mac, &id, "first", "mac-conflict");
    sync(&mut mac, Value::Null);
    let conflict = sync(&mut android, Value::Null);
    assert_eq!(conflict["conflicts"].as_array().unwrap().len(), 1);
    let key = conflict["conflicts"][0]["id"].as_str().unwrap();
    sync(
        &mut android,
        json!({"versions":{key:"local"},"local":conflict["local"],"remote":conflict["remote"]}),
    );
    sync(&mut mac, Value::Null);
    let entry = mac.call(json!({"op":"get","id":id})).unwrap();
    assert_eq!(entry["password"], "android-conflict");
    assert!(entry["history"].to_string().contains("mac-conflict"));
    assert_eq!(sync(&mut mac, Value::Null)["unchanged"], true);
}
