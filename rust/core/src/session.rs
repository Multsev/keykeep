use crate::{
    credentials,
    legacy::{Entry, Folder, Revision, Values, Vault},
    storage,
};
use serde_json::{Value, json};
use std::{fs, os::fd::AsRawFd, path::PathBuf};
use uuid::Uuid;
use zeroize::Zeroizing;

struct DeletedEntry {
    bytes: Zeroizing<Vec<u8>>,
    token: String,
    expires: std::time::Instant,
}

pub struct Session {
    deleted_entry: Option<DeletedEntry>,
    pub(crate) mcp: Option<crate::mcp::Server>,
    cloud_job: Option<crate::yandex::Job>,
    restore_revision: Option<Vec<u8>>,
    attempts: crate::attempts::Attempts,
    erasing: bool,
    path: PathBuf,
    state_path: PathBuf,
    device: Zeroizing<[u8; 32]>,
    pub(crate) unlocked: Option<(Zeroizing<String>, Vault)>,
    // Exclude independent editing sessions across processes.
    _lock: fs::File,
}
impl Session {
    pub fn new(path: PathBuf, device: [u8; 32]) -> Result<Self, &'static str> {
        Self::with_state(path.clone(), path, device)
    }
    pub(crate) fn with_state(
        path: PathBuf,
        state_path: PathBuf,
        device: [u8; 32],
    ) -> Result<Self, &'static str> {
        let lock = fs::File::options()
            .create(true)
            .truncate(false)
            .write(true)
            .open(state_path.with_extension("lock"))
            .map_err(|_| "Не удалось открыть каталог")?;
        // Rust std does not implement File::try_lock on every Android target.
        // Both supported operating systems provide flock; closing the descriptor releases it.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Хранилище уже открыто");
        }
        Ok(Self {
            deleted_entry: None,
            erasing: state_path
                .with_extension("erasing")
                .try_exists()
                .map_err(|_| "Ошибка доступа")?,
            mcp: None,
            cloud_job: None,
            restore_revision: None,
            attempts: crate::attempts::Attempts::new(state_path.with_extension("attempts")),
            path,
            state_path,
            device: Zeroizing::new(device),
            unlocked: None,
            _lock: lock,
        })
    }
    fn missing_external_file(&self) -> Result<bool, &'static str> {
        Ok(self.path != self.state_path
            && !self.path.try_exists().map_err(|_| "Ошибка доступа")?
            && self
                .state_path
                .with_extension("created")
                .try_exists()
                .map_err(|_| "Ошибка доступа")?)
    }
    pub(crate) fn write(&self, v: &Vault, pin: &str) -> Result<(), &'static str> {
        if self.missing_external_file()? {
            return Err("Файл хранилища отсутствует. Проверьте путь внизу окна");
        }
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
        for ext in [
            "created",
            "before-import.kk",
            "before-restore.kk",
            "pending-upload.kdbx",
            "attempts",
        ] {
            remove(&self.state_path.with_extension(ext))?;
        }
        remove(&self.path)?;
        let dir = fs::File::open(self.path.parent().ok_or("Ошибка каталога")?)
            .map_err(|_| "Ошибка каталога")?;
        dir.sync_all().map_err(|_| "Ошибка сохранения")?;
        let state_dir = fs::File::open(self.state_path.parent().ok_or("Ошибка каталога")?)
            .map_err(|_| "Ошибка каталога")?;
        state_dir.sync_all().map_err(|_| "Ошибка сохранения")?;
        remove(&self.state_path.with_extension("erasing"))?;
        self.device = Zeroizing::new(key);
        self.erasing = false;
        state_dir.sync_all().map_err(|_| "Ошибка сохранения")
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
        if self
            .deleted_entry
            .as_ref()
            .is_some_and(|d| d.expires <= std::time::Instant::now())
        {
            self.deleted_entry = None;
        }
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
            storage::persist(
                &self.state_path.with_extension("erasing"),
                b"KeyKeep erasure v1",
            )
            .map_err(|_| "Не удалось начать удаление")?;
            self.erasing = true;
            self.deleted_entry = None;
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
                    json!({"exists":self.path.try_exists().map_err(|_|"Ошибка доступа")? || self.missing_external_file()?,"open":self.unlocked.is_some()}),
                );
            }
            "lock" | "suspendServices" => {
                if op == "suspendServices" && self.cloud_job.is_some() {
                    return Err("Дождитесь завершения синхронизации");
                }
                self.cloud_job = None;
                self.restore_revision = None;
                self.mcp = None;
                self.deleted_entry = None;
                if op == "lock" {
                    self.unlocked = None;
                }
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
                self.deleted_entry = None;
                self.unlocked = None;
                let pin = arg("pin")?;
                if self.missing_external_file()? {
                    return Err("Файл хранилища отсутствует. Проверьте путь внизу окна");
                }
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
                    storage::persist_new(&self.path, &storage::seal(&v, pin, &self.device)?)
                        .map_err(|_| "Не удалось создать файл. Проверьте имя и доступ к папке")?;
                    if self.path != self.state_path {
                        storage::persist(&self.state_path.with_extension("created"), b"1")
                            .map_err(|_| "Ошибка сохранения расположения")?;
                    }
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
                if self.cloud_job.is_some() {
                    return Err("Дождитесь завершения синхронизации");
                }
                let mut next = Self::read_database(&r, password, keyfile)?;
                next.disk = v.disk.clone();
                next.disk.upload = None;
                next.mcp_token.clone_from(&v.mcp_token);
                self.mcp = None;
                let backup =
                    fs::read(&self.path).map_err(|_| "Не удалось прочитать прежнюю базу")?;
                storage::persist(&self.state_path.with_extension("before-import.kk"), &backup)
                    .map_err(|_| "Не удалось сохранить снимок")?;
                self.write(&next, pin)?;
                self.deleted_entry = None;
                self.unlocked.as_mut().unwrap().1 = next;
                let _ = fs::remove_file(self.state_path.with_extension("pending-upload.kdbx"));
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
                let query = arg("query")?.trim().to_lowercase();
                let mut rows: Vec<_> = v
                    .entries
                    .iter()
                    .filter(|e| {
                        (!query.is_empty() || folder == "root" || e.values.folder_id == folder)
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
                    json!({"folders":v.folders,"entryCounts":entry_counts,"entries":rows.iter().map(|e|json!({"id":e.id,"title":e.values.title,"username":e.values.username,"folderId":e.values.folder_id})).collect::<Vec<_>>()}),
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
                let index = next
                    .entries
                    .iter()
                    .position(|e| e.id == id)
                    .ok_or("Запись отсутствует")?;
                let bytes = Zeroizing::new(
                    serde_json::to_vec(&next.entries.remove(index))
                        .map_err(|_| "Ошибка удаления")?,
                );
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                let token = Uuid::new_v4().to_string();
                self.deleted_entry = Some(DeletedEntry {
                    bytes,
                    token: token.clone(),
                    expires: std::time::Instant::now() + std::time::Duration::from_secs(30),
                });
                Ok(json!(token))
            }
            "undoDelete" | "forgetDelete" => {
                let token = arg("token")?;
                let deleted = self.deleted_entry.as_ref().filter(|d| d.token == token);
                if op == "forgetDelete" {
                    if deleted.is_some() {
                        self.deleted_entry = None;
                    }
                    return Ok(Value::Null);
                }
                let entry: Entry =
                    serde_json::from_slice(&deleted.ok_or("Время отмены истекло")?.bytes)
                        .map_err(|_| "Ошибка восстановления")?;
                if v.entries.iter().any(|e| e.id == entry.id)
                    || !v.folders.iter().any(|f| f.id == entry.values.folder_id)
                {
                    return Err("Запись или папка уже изменена");
                }
                let mut next = v.clone();
                next.entries.push(entry);
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                self.deleted_entry = None;
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
    fn content_digest(v: &Vault) -> Result<String, &'static str> {
        use sha2::{Digest, Sha256};
        let mut hash = Sha256::new();
        serde_json::to_writer(&mut hash, &(&v.folders, &v.entries))
            .map_err(|_| "Ошибка сравнения версий")?;
        Ok(format!("{:x}", hash.finalize()))
    }
    fn disk_operation(&mut self, op: &str, r: &Value) -> Result<Value, &'static str> {
        use crate::yandex::{Client, Job, Outcome};
        use sha2::{Digest, Sha256};
        let arg = |k: &str| r[k].as_str().ok_or("Некорректный запрос");
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        if op == "diskStatus" {
            return Ok(
                json!({"client":v.disk.client,"folder":v.disk.folder,"connected":!v.disk.token.is_empty(),"busy":self.cloud_job.is_some(),"pendingUpload":v.disk.upload.is_some(),"localModified":fs::metadata(&self.path).and_then(|m|m.modified()).ok().and_then(|t|t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d|d.as_secs())}),
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
                Outcome::Info(mut value) => {
                    if let (Some(remote), Some(synced)) =
                        (value.get("remote"), v.disk.synced.as_ref())
                    {
                        value["conflict"] = json!(
                            remote["sha256"].as_str() != Some(&synced.remote)
                                && Self::content_digest(v)? != synced.local
                        );
                    }
                    if value["uploaded"] == true
                        && let Some(upload) = &v.disk.upload
                    {
                        let mut next = v.clone();
                        next.disk.synced = Some(crate::yandex::SyncVersion {
                            local: upload.local.clone(),
                            remote: upload.sha256.clone(),
                        });
                        next.disk.upload = None;
                        self.write(&next, pin)?;
                        self.unlocked.as_mut().unwrap().1 = next;
                        let _ =
                            fs::remove_file(self.state_path.with_extension("pending-upload.kdbx"));
                    }
                    value
                }
                Outcome::Token(token) => {
                    let mut next = v.clone();
                    next.disk.token = token.to_string();
                    self.write(&next, pin)?;
                    self.unlocked.as_mut().unwrap().1 = next;
                    json!({"connected":true})
                }
                outcome @ (Outcome::Restore(..) | Outcome::Merged(..)) => {
                    let current = fs::read(&self.path).map_err(|_| "Ошибка чтения")?;
                    if expected != Some(Sha256::digest(&current).to_vec()) {
                        return Err(
                            "Локальная база изменилась во время обмена и сохранена. Снова проверьте версии.",
                        );
                    }
                    let (mut next, remote_digest) = match outcome {
                        Outcome::Restore(data, password) => (
                            crate::kdbx::import(&data, &password, None)?,
                            format!("{:x}", Sha256::digest(&data)),
                        ),
                        Outcome::Merged(vault, digest) => (*vault, digest),
                        _ => unreachable!(),
                    };
                    next.disk = v.disk.clone();
                    next.disk.synced = Some(crate::yandex::SyncVersion {
                        remote: remote_digest,
                        local: Self::content_digest(&next)?,
                    });
                    next.disk.upload = None;
                    next.mcp_token.clone_from(&v.mcp_token);
                    self.mcp = None;
                    storage::persist(
                        &self.state_path.with_extension("before-restore.kk"),
                        &current,
                    )
                    .map_err(|_| "Не удалось сохранить локальный снимок")?;
                    self.write(&next, pin)?;
                    self.deleted_entry = None;
                    self.unlocked.as_mut().unwrap().1 = next;
                    let _ = fs::remove_file(self.state_path.with_extension("pending-upload.kdbx"));
                    json!({"restored":true})
                }
            };
            return Ok(json!({"pending":false,"result":value}));
        }
        if self.cloud_job.is_some() {
            return Err("Дождитесь завершения текущей операции");
        }
        match op {
            "diskConfigure" | "diskAuthorize" | "diskDisconnect" | "diskCallback"
            | "diskCancelUpload" => {
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
                    "diskCancelUpload" => {
                        next.disk.upload = None;
                        Value::Null
                    }
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
                if self.unlocked.as_ref().unwrap().1.disk.upload.is_none() {
                    let _ = fs::remove_file(self.state_path.with_extension("pending-upload.kdbx"));
                }
                return Ok(value);
            }
            _ => {}
        }
        if v.disk.token.is_empty() {
            return Err("Сначала подключите Яндекс Диск");
        }
        let account = v.disk.clone();
        let job = match op {
            "diskRetryUpload" => {
                let pending = v.disk.upload.as_ref().ok_or("Нет отложенной отправки")?;
                let bytes = fs::read(self.state_path.with_extension("pending-upload.kdbx"))
                    .map_err(|_| "Нет файла отложенной отправки. Проверьте версии.")?;
                if format!("{:x}", Sha256::digest(&bytes)) != pending.sha256 {
                    return Err("Копия для отправки изменилась. Проверьте версии.");
                }
                let expected = pending.expected.clone();
                Job::start(move |c| c.upload(bytes, expected), account)
            }
            "diskInspect" => Job::start(Client::inspect, account),
            "diskFolders" | "diskVersions" => {
                let versions = op == "diskVersions";
                Job::start(move |c| c.list(versions), account)
            }
            "diskUpload" | "diskRestore" | "diskMerge" => {
                if r["confirmed"] != true || r.get("expected").is_none() {
                    return Err("Подтвердите операцию после проверки облачной версии");
                }
                let password = Zeroizing::new(arg("password")?.to_owned());
                let expected = r["expected"].clone();
                if op == "diskUpload" {
                    let bytes = crate::kdbx::export(v, &password, None)?;
                    let mut next = v.clone();
                    next.disk.upload = Some(crate::yandex::PendingUpload {
                        local: Self::content_digest(v)?,
                        expected: expected.clone(),
                        sha256: format!("{:x}", Sha256::digest(&bytes)),
                    });
                    storage::persist(
                        &self.state_path.with_extension("pending-upload.kdbx"),
                        &bytes,
                    )
                    .map_err(|_| "Не удалось сохранить файл для повторной отправки")?;
                    self.write(&next, pin)?;
                    self.unlocked.as_mut().unwrap().1 = next;
                    Job::start(move |c| c.upload(bytes, expected), account)
                } else {
                    self.restore_revision = Some(
                        Sha256::digest(fs::read(&self.path).map_err(|_| "Ошибка чтения")?).to_vec(),
                    );
                    let version = r["version"].as_str().unwrap_or_default().to_owned();
                    if op == "diskMerge" {
                        if !version.is_empty() || expected.is_null() {
                            return Err("Для объединения выберите текущую облачную базу");
                        }
                        let mut local = v.clone();
                        local.disk = Default::default();
                        local.mcp_token.clear();
                        Job::start(move |c| c.merge(local, password, expected), account)
                    } else {
                        let bytes = crate::kdbx::export(v, &password, None)?;
                        Job::start(
                            move |c| c.restore(bytes, password, version, expected),
                            account,
                        )
                    }
                }
            }
            _ => return Err("Неизвестная операция Диска"),
        };
        self.cloud_job = Some(job);
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_selected_file_survives_reopen_and_missing_file_is_not_recreated() {
        let folder = tempfile::tempdir().unwrap();
        let profile = tempfile::tempdir().unwrap();
        let path = folder.path().join("Работа.kk");
        let state = profile.path().join("vault.kk");
        let open = || Session::with_state(path.clone(), state.clone(), [42; 32]).unwrap();
        let create = json!({"op":"create","pin":"fixture-pin"});
        open().call(create.clone()).unwrap();
        assert_eq!(fs::read_dir(folder.path()).unwrap().count(), 1);
        let mut session = open();
        session
            .call(json!({"op":"unlock","pin":"fixture-pin"}))
            .unwrap();
        let moved = folder.path().join("Перенесено.kk");
        fs::rename(&path, &moved).unwrap();
        assert_eq!(
            session.call(json!({"op":"status"})).unwrap()["exists"],
            true
        );
        assert!(session.call(create.clone()).is_err());
        assert!(!path.exists());
        fs::rename(moved, &path).unwrap();
        let bytes = fs::read(&path).unwrap();
        assert!(storage::persist_new(&path, b"replacement").is_err());
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }

    #[test]
    fn undo_expires_and_cannot_cross_sessions() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = Session::new(dir.path().join("vault"), [42; 32]).unwrap();
        session
            .call(json!({"op":"create","pin":"fixture-pin"}))
            .unwrap();
        for lock in [false, true] {
            let id = session.call(json!({"op":"save","id":"","time":"2026-01-01T00:00:00Z",
                "values":{"folderId":"root","title":"Example","username":"demo","password":"fixture-only"}})).unwrap();
            let token = session
                .call(json!({"op":"deleteEntry","id":id,"confirmed":true}))
                .unwrap();
            if lock {
                session.call(json!({"op":"lock"})).unwrap();
                session
                    .call(json!({"op":"unlock","pin":"fixture-pin"}))
                    .unwrap();
            } else {
                session.deleted_entry.as_mut().unwrap().expires = std::time::Instant::now();
            }
            assert!(
                session
                    .call(json!({"op":"undoDelete","token":token}))
                    .is_err()
            );
            assert!(session.call(json!({"op":"get","id":id})).is_err());
            assert!(session.deleted_entry.is_none());
        }
    }
}
