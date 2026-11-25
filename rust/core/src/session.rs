use crate::{
    credentials,
    legacy::{Entry, Folder, Revision, Values, Vault},
    storage,
};
use serde_json::{Value, json};
use std::{fs, os::fd::AsRawFd, path::PathBuf};
use uuid::Uuid;
use zeroize::Zeroizing;

pub struct Session {
    pub(crate) mcp: Option<crate::mcp::Server>,
    cloud_job: Option<crate::yandex::Job>,
    restore_revision: Option<Vec<u8>>,
    attempts: crate::attempts::Attempts,
    erasing: bool,
    path: PathBuf,
    device: Zeroizing<[u8; 32]>,
    pub(crate) unlocked: Option<(Zeroizing<String>, Vault)>,
    // Exclude independent editing sessions across processes.
    _lock: fs::File,
}
impl Session {
    pub fn new(path: PathBuf, device: [u8; 32]) -> Result<Self, &'static str> {
        let lock = fs::File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path.with_extension("lock"))
            .map_err(|_| "Не удалось открыть каталог")?;
        // Rust std does not implement File::try_lock on every Android target.
        // Both supported operating systems provide flock; closing the descriptor releases it.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Хранилище уже открыто");
        }
        Ok(Self {
            erasing: path
                .with_extension("erasing")
                .try_exists()
                .map_err(|_| "Ошибка доступа")?,
            mcp: None,
            cloud_job: None,
            restore_revision: None,
            attempts: crate::attempts::Attempts::new(path.with_extension("attempts")),
            path,
            device: Zeroizing::new(device),
            unlocked: None,
            _lock: lock,
        })
    }
    pub(crate) fn write(&self, v: &Vault, pin: &str) -> Result<(), &'static str> {
        storage::persist(&self.path, &storage::seal(v, pin, &self.device)?)
            .map_err(|_| "Ошибка сохранения")
    }
    pub(crate) fn active_pin(&self) -> Option<&str> {
        self.unlocked.as_ref().map(|(pin, _)| pin.as_str())
    }
    pub(crate) fn save_entry(
        next: &mut Vault,
        id: &str,
        values: Values,
        time: String,
        create_missing: bool,
    ) -> Result<String, &'static str> {
        if values.username.trim().is_empty() {
            return Err("Укажите логин");
        }
        if values.password.is_empty() {
            return Err("Укажите пароль");
        }
        if values.title.trim().is_empty() || !next.folders.iter().any(|f| f.id == values.folder_id)
        {
            return Err("Проверьте название и папку");
        }

        if id.is_empty() || (create_missing && !next.entries.iter().any(|e| e.id == id)) {
            let id = if id.is_empty() {
                Uuid::new_v4().to_string()
            } else {
                id.to_owned()
            };
            next.entries.push(Entry {
                id: id.clone(),
                values,
                updated_at: time,
                history: vec![],
            });
            Ok(id)
        } else {
            let e = next
                .entries
                .iter_mut()
                .find(|e| e.id == id)
                .ok_or("Запись отсутствует")?;
            if e.values != values {
                e.history.push(Revision {
                    changed_at: time.clone(),
                    values: Some(serde_json::to_string(&e.values).map_err(|_| "Ошибка истории")?),
                    password: None,
                });
                e.updated_at = time;
                e.values = values;
            }
            Ok(id.to_owned())
        }
    }
    pub(crate) fn erasing(&self) -> bool {
        self.erasing
    }
    pub(crate) fn initialize_device(&mut self, key: [u8; 32]) -> bool {
        if self.erasing || self.unlocked.is_some() {
            return false;
        }
        self.device = Zeroizing::new(key);
        true
    }
    pub(crate) fn finish_erasure(&mut self, key: [u8; 32]) -> Result<(), &'static str> {
        if !self.erasing {
            return Err("Удаление не подтверждено");
        }
        let remove = |path: &std::path::Path| match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err("Не удалось завершить удаление"),
        };
        for ext in ["before-import.kk", "before-restore.kk", "attempts"] {
            remove(&self.path.with_extension(ext))?;
        }
        remove(&self.path)?;
        let dir = fs::File::open(self.path.parent().ok_or("Ошибка каталога")?)
            .map_err(|_| "Ошибка каталога")?;
        dir.sync_all().map_err(|_| "Ошибка сохранения")?;
        remove(&self.path.with_extension("erasing"))?;
        self.device = Zeroizing::new(key);
        self.erasing = false;
        dir.sync_all().map_err(|_| "Ошибка сохранения")
    }
    fn keyfile(request: &Value) -> Result<Option<Zeroizing<Vec<u8>>>, &'static str> {
        use base64::{Engine, engine::general_purpose::STANDARD};
        request["keyfile"]
            .as_str()
            .map(|data| STANDARD.decode(data).map(Zeroizing::new))
            .transpose()
            .map_err(|_| "Ошибка ключевого файла")
    }
    fn read_database(
        request: &Value,
        password: &str,
        keyfile: Option<&[u8]>,
    ) -> Result<Vault, &'static str> {
        use base64::{Engine, engine::general_purpose::STANDARD};
        let bytes = STANDARD
            .decode(request["data"].as_str().ok_or("Выберите файл KDBX")?)
            .map_err(|_| "Ошибка файла")?;
        crate::kdbx::import(&bytes, password, keyfile)
    }
    pub fn call(&mut self, r: Value) -> Result<Value, &'static str> {
        let arg = |k: &str| {
            r.get(k)
                .and_then(Value::as_str)
                .ok_or("Некорректный запрос")
        };
        let op = arg("op")?;
        if self.erasing {
            return Err("Требуется завершить удаление. Откройте приложение повторно.");
        }
        if op == "beginErase" {
            if r["confirmed"] != true {
                return Err("Подтвердите удаление хранилища");
            }
            if self.cloud_job.is_some() {
                return Err("Дождитесь завершения синхронизации");
            }
            self.call(json!({"op":"verifyPin","currentPin":arg("currentPin")?}))?;
            storage::persist(&self.path.with_extension("erasing"), b"KeyKeep erasure v1")
                .map_err(|_| "Не удалось начать удаление")?;
            self.erasing = true;
            self.unlocked = None;
            self.mcp = None;
            self.restore_revision = None;
            self.device = Zeroizing::new([0; 32]);
            return Ok(Value::Null);
        }
        if matches!(op, "unlock" | "migrateAndroid" | "verifyPin" | "changePin") {
            self.attempts.check()?;
        }
        match op {
            "status" => {
                return Ok(
                    json!({"exists":self.path.try_exists().map_err(|_|"Ошибка доступа")?,"open":self.unlocked.is_some()}),
                );
            }
            "lock" => {
                self.cloud_job = None;
                self.restore_revision = None;
                self.mcp = None;
                self.unlocked = None;
                return Ok(Value::Null);
            }
            "migrateAndroid" => {
                if self.path.try_exists().map_err(|_| "Ошибка доступа")? {
                    return Err("Хранилище уже существует");
                }
                let pin = arg("pin")?;
                if !credentials::legacy_pin_matches(
                    pin,
                    arg("master_pin_salt")?,
                    arg("master_pin_verifier")?,
                ) {
                    self.attempts.failed()?;
                    return Err("Неверный PIN");
                }
                let mut vault =
                    Vault::from_android(r["vault_folders"].as_str(), r["vault_entries"].as_str())?;
                if let Some(folder) = r["yandex_disk_sync_folder"].as_str() {
                    vault
                        .disk
                        .configure(r["yandex_disk_client_id"].as_str().unwrap_or(""), folder)?;
                } else if let Some(client) = r["yandex_disk_client_id"].as_str() {
                    vault.disk.configure(client, "KeyKeep")?;
                }
                if let Some(token) = r["keykeep_mcp_token"].as_str().filter(|t| {
                    t.len() == 43
                        && t.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                }) {
                    vault.mcp_token = token.into();
                }
                vault.disk.token = r["yandex_disk_access_token"]
                    .as_str()
                    .unwrap_or_default()
                    .into();
                let ciphertext = storage::seal(&vault, pin, &self.device)?;
                let verified = storage::open(&ciphertext, pin, &self.device)?;
                if verified.entries != vault.entries || verified.folders != vault.folders {
                    return Err("Ошибка проверки переноса");
                }
                storage::persist(&self.path, &ciphertext).map_err(|_| "Ошибка сохранения")?;
                self.attempts.clear()?;
                self.unlocked = Some((Zeroizing::new(pin.to_owned()), verified));
                return Ok(Value::Null);
            }
            "unlock" | "create" | "createFromKdbx" => {
                self.cloud_job = None;
                self.restore_revision = None;
                self.mcp = None;
                self.unlocked = None;
                let pin = arg("pin")?;
                let vault = if op != "unlock" {
                    if self.path.try_exists().map_err(|_| "Ошибка доступа")? {
                        return Err("Хранилище уже существует");
                    }
                    if pin.chars().count() < 6 {
                        return Err("Введите минимум 6 символов");
                    }
                    let v = if op == "createFromKdbx" {
                        let keyfile = Self::keyfile(&r)?;
                        Self::read_database(
                            &r,
                            arg("password")?,
                            keyfile.as_ref().map(|f| f.as_slice()),
                        )?
                    } else {
                        Vault::from_android(None, None)?
                    };
                    self.write(&v, pin)?;
                    v
                } else {
                    let encrypted = fs::read(&self.path).map_err(|_| "Ошибка чтения")?;
                    match storage::open(&encrypted, pin, &self.device) {
                        Ok(vault) => {
                            self.attempts.clear()?;
                            vault
                        }
                        Err(message) => {
                            self.attempts.failed()?;
                            return Err(message);
                        }
                    }
                };
                self.unlocked = Some((Zeroizing::new(pin.to_owned()), vault));
                return Ok(Value::Null);
            }
            _ => {}
        }
        if op.starts_with("mcp") {
            return self.mcp_operation(op, &r);
        }
        if op.starts_with("disk") {
            return self.disk_operation(op, &r);
        }
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        match op {
            "exportKdbx" | "importKdbx" => {
                use base64::{Engine, engine::general_purpose::STANDARD};
                let password = arg("password")?;
                let keyfile = Self::keyfile(&r)?;
                let keyfile = keyfile.as_ref().map(|k| k.as_slice());
                if op == "exportKdbx" {
                    return Ok(json!(STANDARD.encode(crate::kdbx::export_version(
                        v,
                        password,
                        keyfile,
                        r["version"].as_u64().unwrap_or(4)
                    )?)));
                }
                if r["confirmed"] != true {
                    return Err("Подтвердите замену данных");
                }
                let mut next = Self::read_database(&r, password, keyfile)?;
                next.disk = v.disk.clone();
                next.mcp_token.clone_from(&v.mcp_token);
                self.mcp = None;
                let backup =
                    fs::read(&self.path).map_err(|_| "Не удалось прочитать прежнюю базу")?;
                storage::persist(&self.path.with_extension("before-import.kk"), &backup)
                    .map_err(|_| "Не удалось сохранить снимок")?;
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                Ok(Value::Null)
            }
            "verifyPin" | "changePin" => {
                use subtle::ConstantTimeEq;
                if !bool::from(pin.as_bytes().ct_eq(arg("currentPin")?.as_bytes())) {
                    self.attempts.failed()?;
                    return Err("Неверный текущий PIN");
                }
                self.attempts.clear()?;
                if op == "changePin" {
                    let next = arg("newPin")?;
                    if next.chars().count() < 6 {
                        return Err("Введите минимум 6 символов");
                    }
                    self.write(v, next)?;
                    self.unlocked.as_mut().unwrap().0 = Zeroizing::new(next.to_owned());
                }
                Ok(Value::Null)
            }
            "list" => {
                let folder = arg("folder")?;
                let query = arg("query")?.to_lowercase();
                let mut rows: Vec<_> = v
                    .entries
                    .iter()
                    .filter(|e| {
                        (folder == "root" || e.values.folder_id == folder)
                            && (query.is_empty()
                                || [
                                    &e.values.title,
                                    &e.values.username,
                                    &e.values.website,
                                    &e.values.note,
                                ]
                                .iter()
                                .any(|s| s.to_lowercase().contains(&query))
                                || e.values.custom_fields.iter().any(|f| {
                                    f.name.to_lowercase().contains(&query)
                                        || f.value.to_lowercase().contains(&query)
                                }))
                    })
                    .collect();
                rows.sort_by_cached_key(|e| e.values.title.to_lowercase());
                let mut entry_counts = std::collections::HashMap::new();
                for e in &v.entries {
                    *entry_counts.entry(&e.values.folder_id).or_insert(0usize) += 1;
                }
                Ok(
                    json!({"folders":v.folders,"entryCounts":entry_counts,"entries":rows.iter().map(|e|json!({"id":e.id,"title":e.values.title,"username":e.values.username})).collect::<Vec<_>>()}),
                )
            }
            "get" => {
                let id = arg("id")?;
                Ok(json!(
                    v.entries
                        .iter()
                        .find(|e| e.id == id)
                        .ok_or("Запись отсутствует")?
                ))
            }
            "totp" => {
                let seconds = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| "Проверьте время устройства")?
                    .as_secs();
                let code = credentials::totp(arg("secret")?, seconds)
                    .ok_or("Некорректный Base32-секрет")?;
                Ok(json!({"code":code,"validUntil": (seconds/30+1)*30}))
            }
            "generate" => Ok(json!(
                credentials::generate_password(18, true)
                    .ok_or("Ошибка генерации")?
                    .as_str()
            )),
            "folderInfo" | "editFolder" | "deleteFolder" => {
                let id = arg("id")?;
                let ids = v.subtree(id)?;
                if op == "folderInfo" {
                    let info = v
                        .folders
                        .iter()
                        .find(|f| f.id == id)
                        .ok_or("Папка отсутствует")?;
                    return Ok(
                        json!({"folder":info,"choices":v.folders.iter().filter(|f|!ids.contains(&f.id)).collect::<Vec<_>>(),
                        "entries":v.entries.iter().filter(|e|ids.contains(&e.values.folder_id)).count(),"folders":ids.len()}),
                    );
                }
                let mut next = v.clone();
                if op == "deleteFolder" {
                    if r["confirmed"] != true {
                        return Err("Подтвердите удаление папки");
                    }
                    next.folders.retain(|f| !ids.contains(&f.id));
                    next.entries.retain(|e| !ids.contains(&e.values.folder_id));
                } else {
                    let name = arg("name")?.trim();
                    let parent = arg("parent")?;
                    if name.is_empty()
                        || ids.contains(parent)
                        || !v.folders.iter().any(|f| f.id == parent)
                    {
                        return Err("Недопустимое название или родительская папка");
                    }
                    let item = next
                        .folders
                        .iter_mut()
                        .find(|f| f.id == id)
                        .ok_or("Папка отсутствует")?;
                    item.name = name.to_owned();
                    item.parent_id = parent.to_owned();
                }
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                Ok(Value::Null)
            }
            "deleteEntry" => {
                let id = arg("id")?;
                if r["confirmed"] != true {
                    return Err("Подтвердите удаление записи");
                }
                let mut next = v.clone();
                next.entries.retain(|e| e.id != id);
                if next.entries.len() == v.entries.len() {
                    return Err("Запись отсутствует");
                }
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                Ok(Value::Null)
            }
            "save" | "addFolder" => {
                let mut next = v.clone();
                let id = if op == "addFolder" {
                    let parent = arg("parent")?;
                    let name = arg("name")?.trim();
                    if name.is_empty() || !next.folders.iter().any(|f| f.id == parent) {
                        return Err("Проверьте название и папку");
                    }
                    let id = Uuid::new_v4().to_string();
                    next.folders.push(Folder {
                        id: id.clone(),
                        name: name.into(),
                        parent_id: parent.into(),
                    });
                    id
                } else {
                    let values: Values = serde_json::from_value(r["values"].clone())
                        .map_err(|_| "Некорректные поля")?;
                    Self::save_entry(
                        &mut next,
                        arg("id")?,
                        values,
                        arg("time")?.to_owned(),
                        false,
                    )?
                };
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                Ok(json!(id))
            }
            _ => Err("Неизвестная операция"),
        }
    }
    fn disk_operation(&mut self, op: &str, r: &Value) -> Result<Value, &'static str> {
        use crate::yandex::{Client, Job, Outcome};
        use sha2::{Digest, Sha256};
        let arg = |k: &str| r[k].as_str().ok_or("Некорректный запрос");
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        if op == "diskStatus" {
            return Ok(
                json!({"client":v.disk.client,"folder":v.disk.folder,"connected":!v.disk.token.is_empty(),"busy":self.cloud_job.is_some(),"localModified":fs::metadata(&self.path).and_then(|m|m.modified()).ok().and_then(|t|t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d|d.as_secs())}),
            );
        }
        if op == "diskPoll" {
            let job = self.cloud_job.as_ref().ok_or("Нет операции")?;
            let result = job.poll();
            if matches!(result, Ok(None)) {
                return Ok(json!({"pending":true}));
            }
            self.cloud_job = None;
            let expected = self.restore_revision.take();
            let value = match result?.ok_or("Нет результата")? {
                Outcome::Info(value) => value,
                Outcome::Token(token) => {
                    let mut next = v.clone();
                    next.disk.token = token.to_string();
                    self.write(&next, pin)?;
                    self.unlocked.as_mut().unwrap().1 = next;
                    json!({"connected":true})
                }
                Outcome::Restore(data, password) => {
                    let current = fs::read(&self.path).map_err(|_| "Ошибка чтения")?;
                    if expected != Some(Sha256::digest(&current).to_vec()) {
                        return Err("Локальное хранилище изменилось. Повторите восстановление.");
                    }
                    let mut next = crate::kdbx::import(&data, &password, None)?;
                    next.disk = v.disk.clone();
                    next.mcp_token.clone_from(&v.mcp_token);
                    self.mcp = None;
                    storage::persist(&self.path.with_extension("before-restore.kk"), &current)
                        .map_err(|_| "Не удалось сохранить локальный снимок")?;
                    self.write(&next, pin)?;
                    self.unlocked.as_mut().unwrap().1 = next;
                    json!({"restored":true})
                }
            };
            return Ok(json!({"pending":false,"result":value}));
        }
        if self.cloud_job.is_some() {
            return Err("Дождитесь завершения текущей операции");
        }
        match op {
            "diskConfigure" | "diskAuthorize" | "diskDisconnect" | "diskCallback" => {
                let mut next = v.clone();
                let value = match op {
                    "diskConfigure" => {
                        let client = arg("client")?.trim();
                        let folder = arg("folder")?.trim();
                        if client == v.disk.client && folder == v.disk.folder {
                            return Ok(Value::Null);
                        }
                        next.disk.configure(client, folder)?;
                        Value::Null
                    }
                    "diskAuthorize" => json!(next.disk.authorize()?),
                    "diskDisconnect" => {
                        next.disk.disconnect();
                        Value::Null
                    }
                    _ => {
                        let (code, verifier) = next.disk.callback(arg("callback")?)?;
                        self.write(&next, pin)?;
                        self.cloud_job = Some(Job::start(
                            move |c| c.exchange(code, verifier),
                            next.disk.clone(),
                        ));
                        self.unlocked.as_mut().unwrap().1 = next;
                        return Ok(Value::Null);
                    }
                };
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                return Ok(value);
            }
            _ => {}
        }
        if v.disk.token.is_empty() {
            return Err("Сначала подключите Яндекс Диск");
        }
        let account = v.disk.clone();
        let job = match op {
            "diskInspect" => Job::start(Client::inspect, account),
            "diskFolders" | "diskVersions" => {
                let versions = op == "diskVersions";
                Job::start(move |c| c.list(versions), account)
            }
            "diskUpload" | "diskRestore" => {
                if r["confirmed"] != true || r.get("expected").is_none() {
                    return Err("Подтвердите операцию после проверки облачной версии");
                }
                let password = Zeroizing::new(arg("password")?.to_owned());
                let bytes = crate::kdbx::export(v, &password, None)?;
                let expected = r["expected"].clone();
                if op == "diskUpload" {
                    Job::start(move |c| c.upload(bytes, expected), account)
                } else {
                    self.restore_revision = Some(
                        Sha256::digest(fs::read(&self.path).map_err(|_| "Ошибка чтения")?).to_vec(),
                    );
                    let version = r["version"].as_str().unwrap_or_default().to_owned();
                    Job::start(
                        move |c| c.restore(bytes, password, version, expected),
                        account,
                    )
                }
            }
            _ => return Err("Неизвестная операция Диска"),
        };
        self.cloud_job = Some(job);
        Ok(Value::Null)
    }
}
