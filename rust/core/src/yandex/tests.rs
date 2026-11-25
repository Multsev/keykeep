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
