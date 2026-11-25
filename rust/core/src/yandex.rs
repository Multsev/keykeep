//! OAuth PKCE and manual encrypted KDBX exchange with Yandex Disk.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use url::Url;
use zeroize::Zeroizing;
pub(crate) mod automatic;
type Result<T> = std::result::Result<T, &'static str>;
const CALLBACK: &str = "keykeep://oauth/callback";
const SERVICE: &str = "Ошибка запроса к Яндекс Диску";
const STALE: &str = "Облачная версия изменилась. Обновите сведения перед синхронизацией.";

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Account {
    #[cfg(test)]
    #[serde(skip)]
    mock_api: Option<String>,
    pub(crate) auto_password: String,
    pub(crate) auto_base: automatic::Baseline,
    pub client: String,
    pub folder: String,
    pub token: String,
    pub(crate) shared_binding: Option<String>,
    pending: Option<Pending>,
    pub(crate) upload: Option<PendingUpload>,
    pub(crate) synced: Option<SyncVersion>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct SyncVersion {
    pub remote: String,
    pub local: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct PendingUpload {
    pub local: String,
    pub expected: Value,
    pub sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
struct Pending {
    state: String,
    verifier: String,
    created: u64,
}
impl Default for Account {
    fn default() -> Self {
        Self {
            #[cfg(test)]
            mock_api: None,
            auto_password: String::new(),
            auto_base: Default::default(),
            client: option_env!("YANDEX_OAUTH_CLIENT_ID").unwrap_or("").into(),
            folder: "KeyKeep".into(),
            token: String::new(),
            shared_binding: None,
            pending: None,
            upload: None,
            synced: None,
        }
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn random() -> Result<String> {
    let mut bytes = [0; 32];
    OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(|_| "Ошибка генератора")?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}
fn component(value: &str) -> bool {
    !value.trim().is_empty()
        && value != "."
        && value != ".."
        && !value.contains(['/', '\\'])
        && !value.chars().any(char::is_control)
}
impl Account {
    pub fn configure(&mut self, client: &str, folder: &str) -> Result<()> {
        if !component(folder) {
            return Err("Укажите имя папки без пути");
        }
        if client.trim() != self.client || folder.trim() != self.folder {
            self.auto_password.clear();
            self.auto_base.clear();
            self.upload = None;
            self.synced = None;
        }
        if client != self.client {
            self.token.clear();
            self.pending = None;
        }
        self.client = client.trim().into();
        self.folder = folder.trim().into();
        Ok(())
    }
    pub fn authorize(&mut self) -> Result<String> {
        if self.client.is_empty() {
            return Err("Укажите публичный OAuth Client ID");
        }
        let pending = Pending {
            state: random()?,
            verifier: random()?,
            created: now(),
        };
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(pending.verifier.as_bytes()));
        let mut url = Url::parse("https://oauth.yandex.ru/authorize").unwrap();
        url.query_pairs_mut().extend_pairs([
            ("response_type", "code"),
            ("client_id", &self.client),
            ("redirect_uri", CALLBACK),
            ("scope", "cloud_api:disk.read cloud_api:disk.write"),
            ("state", &pending.state),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
        ]);
        self.pending = Some(pending);
        Ok(url.into())
    }
    pub fn callback(&mut self, callback: &str) -> Result<(String, String)> {
        let invalid = "Проверка ответа OAuth не пройдена";
        let url = Url::parse(callback).map_err(|_| invalid)?;
        if url.scheme() != "keykeep"
            || url.host_str() != Some("oauth")
            || !url.username().is_empty()
            || url.password().is_some()
            || url.port().is_some()
            || url.path() != "/callback"
            || url.fragment().is_some()
        {
            return Err(invalid);
        }
        let one = |name: &str| {
            let mut pairs = url.query_pairs().filter(|(k, _)| k == name);
            let v = pairs.next()?.1.into_owned();
            (pairs.next().is_none() && !v.is_empty()).then_some(v)
        };
        let p = self.pending.as_ref().ok_or(invalid)?;
        if now().saturating_sub(p.created) > 600 || one("state").as_deref() != Some(&p.state) {
            return Err(invalid);
        }
        let code = one("code").ok_or(invalid)?;
        Ok((code, self.pending.take().unwrap().verifier))
    }
    pub fn disconnect(&mut self) {
        self.auto_password.clear();
        self.auto_base.clear();
        self.upload = None;
        self.synced = None;
        self.token.clear();
        self.pending = None;
    }
}

pub enum Outcome {
    Info(Value),
    Token(Zeroizing<String>),
    Restore(Vec<u8>, Zeroizing<String>),
    Merged(Box<crate::legacy::Vault>, String),
    Automatic(Box<crate::legacy::Vault>, String),
}
pub struct Job {
    rx: mpsc::Receiver<Result<Outcome>>,
    cancelled: Arc<AtomicBool>,
}
impl Drop for Job {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}
impl Job {
    pub fn start(
        action: impl FnOnce(Client) -> Result<Outcome> + Send + 'static,
        account: Account,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = cancelled.clone();
        std::thread::spawn(move || {
            let client = Client::new(account, flag);
            let _ = tx.send(action(client));
        });
        Self { rx, cancelled }
    }
    pub fn poll(&self) -> Result<Option<Outcome>> {
        match self.rx.try_recv() {
            Ok(result) => result.map(Some),
            Err(mpsc::TryRecvError::Empty) => Ok(None),
            Err(_) => Err(SERVICE),
        }
    }
}
pub struct Client {
    api_root: String,
    account: Account,
    http: ureq::Agent,
    cancelled: Arc<AtomicBool>,
}
fn payload(r: ureq::Response) -> Result<Value> {
    serde_json::from_reader(r.into_reader().take(4 << 20)).map_err(|_| SERVICE)
}
impl Client {
    fn new(account: Account, flag: Arc<AtomicBool>) -> Self {
        let api_root = String::from("https://cloud-api.yandex.net/v1/disk/resources");
        #[cfg(test)]
        let api_root = account.mock_api.clone().unwrap_or(api_root);
        Self {
            account,
            api_root,
            cancelled: flag,
            http: ureq::AgentBuilder::new()
                .redirects(0)
                .timeout(Duration::from_secs(45))
                .build(),
        }
    }

    fn active(&self) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            Err("Операция отменена")
        } else {
            Ok(())
        }
    }
    pub fn exchange(self, code: String, verifier: String) -> Result<Outcome> {
        self.active()?;
        let r = self
            .http
            .post("https://oauth.yandex.ru/token")
            .send_form(&[
                ("grant_type", "authorization_code"),
                ("code", &code),
                ("client_id", &self.account.client),
                ("redirect_uri", CALLBACK),
                ("code_verifier", &verifier),
            ])
            .map_err(|_| "Не удалось обменять код OAuth")?;
        let data = payload(r)?;
        Ok(Outcome::Token(Zeroizing::new(
            data["access_token"]
                .as_str()
                .filter(|v| !v.is_empty())
                .ok_or(SERVICE)?
                .into(),
        )))
    }
    fn api(&self, method: &str, route: &str, params: &[(&str, &str)]) -> Result<ureq::Response> {
        self.active()?;
        let mut req = self
            .http
            .request(method, &format!("{}{route}", self.api_root))
            .set("Authorization", &format!("OAuth {}", self.account.token));
        for (key, value) in params {
            req = req.query(key, value);
        }
        match req.call() {
            Ok(r) | Err(ureq::Error::Status(_, r)) => Ok(r),
            Err(_) => Err(SERVICE),
        }
    }
    fn dir(&self) -> String {
        format!("disk:/{}", self.account.folder)
    }
    fn path(&self) -> String {
        format!("{}/keykeep-vault.kdbx", self.dir())
    }
    fn info(&self, path: &str) -> Result<Value> {
        let r = self.api("GET", "", &[("path", path)])?;
        match r.status() {
            404 => Ok(Value::Null),
            200 => {
                let v = payload(r)?;
                let hash = v["sha256"].as_str().ok_or(SERVICE)?;
                Ok(json!({"sha256":hash,"modified":v["modified"],"size":v["size"]}))
            }
            _ => Err(SERVICE),
        }
    }
    pub fn inspect(self) -> Result<Outcome> {
        let info = self.info(&self.path())?;
        Ok(Outcome::Info(json!({"remote":info})))
    }
    pub fn list(self, versions: bool) -> Result<Outcome> {
        let path = if versions {
            format!("{}/keykeep-history", self.dir())
        } else {
            "disk:/".into()
        };
        let mut out = vec![];
        let mut offset = 0;
        loop {
            let r = self.api(
                "GET",
                "",
                &[
                    ("path", &path),
                    ("limit", "300"),
                    ("offset", &offset.to_string()),
                ],
            )?;
            if versions && r.status() == 404 {
                break;
            }
            if r.status() != 200 {
                return Err(SERVICE);
            }
            let v = payload(r)?;
            let items = v["_embedded"]["items"].as_array().ok_or(SERVICE)?;
            for f in items {
                let Some(name) = f["name"].as_str() else {
                    continue;
                };
                if component(name)
                    && (if versions {
                        f["type"] == "file" && name.ends_with(".kdbx")
                    } else {
                        f["type"] == "dir"
                    })
                {
                    out.push(json!({"name":name,"modified":f["modified"]}));
                }
            }
            offset += items.len();
            if items.is_empty()
                || offset >= v["_embedded"]["total"].as_u64().ok_or(SERVICE)? as usize
            {
                break;
            }
        }
        Ok(Outcome::Info(json!({"items":out})))
    }
    fn href(&self, route: &str, path: &str, overwrite: bool) -> Result<String> {
        let mut pairs = vec![("path", path)];
        if route == "/upload" {
            pairs.push(("overwrite", if overwrite { "true" } else { "false" }));
        }
        let r = self.api("GET", route, &pairs)?;
        if r.status() != 200 {
            return Err(SERVICE);
        }
        let v = payload(r)?;
        let url = Url::parse(v["href"].as_str().ok_or(SERVICE)?).map_err(|_| SERVICE)?;
        #[cfg(test)]
        if url.host_str() == Some("127.0.0.1") && self.api_root.starts_with("http://127.0.0.1:") {
            return Ok(url.into());
        }
        if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
            return Err(SERVICE);
        }
        Ok(url.into())
    }
    fn download(&self, path: &str) -> Result<Vec<u8>> {
        let mut url = self.href("/download", path, false)?;
        for _ in 0..5 {
            self.active()?;
            let response = self.http.get(&url).call().map_err(|_| SERVICE)?;
            if (300..400).contains(&response.status()) {
                let target = Url::parse(&url)
                    .map_err(|_| SERVICE)?
                    .join(response.header("Location").ok_or(SERVICE)?)
                    .map_err(|_| SERVICE)?;
                if target.scheme() != "https"
                    || target.password().is_some()
                    || !target.username().is_empty()
                {
                    return Err(SERVICE);
                }
                url = target.into();
                continue;
            }
            if response.status() != 200 {
                return Err(SERVICE);
            }
            let mut data = vec![];
            response
                .into_reader()
                .take((64 << 20) + 1)
                .read_to_end(&mut data)
                .map_err(|_| SERVICE)?;
            if data.len() > 64 << 20 {
                return Err("Размер базы превышает 64 МБ");
            }
            return Ok(data);
        }
        Err(SERVICE)
    }
    fn put(&self, path: &str, data: &[u8], overwrite: bool) -> Result<()> {
        let url = self.href("/upload", path, overwrite)?;
        self.active()?;
        let response = self.http.put(&url).send_bytes(data).map_err(|_| SERVICE)?;
        if !(200..300).contains(&response.status()) {
            return Err(SERVICE);
        }
        Ok(())
    }
    fn prepare(&self) -> Result<()> {
        for path in [self.dir(), format!("{}/keykeep-history", self.dir())] {
            let r = self.api("PUT", "", &[("path", &path)])?;
            if !matches!(r.status(), 201 | 409) {
                return Err(SERVICE);
            }
        }
        Ok(())
    }
    fn snapshot(&self, prefix: &str, data: &[u8]) -> Result<()> {
        let path = format!(
            "{}/keykeep-history/{prefix}-{}-{}.kdbx",
            self.dir(),
            now(),
            uuid::Uuid::new_v4()
        );
        self.put(&path, data, false)
    }
    pub fn upload(mut self, bytes: Vec<u8>, expected: Value) -> Result<Outcome> {
        self.prepare()?;
        // Serialize the final compare and publish across KeyKeep clients.
        let lock = format!("{}/.keykeep-writing", self.dir());
        match self.api("PUT", "", &[("path", &lock)])?.status() {
            201 => {}
            409 => {
                return Err(
                    "Диск занят другим клиентом. Если все клиенты закрыты, удалите оставшуюся папку .keykeep-writing.",
                );
            }
            _ => return Err(SERVICE),
        }
        let result = self.publish(bytes, expected);
        // Unlock even when the vault owner cancelled the job.
        self.cancelled = Arc::new(AtomicBool::new(false));
        let released = self.api("DELETE", "", &[("path", &lock), ("permanently", "true")])?;
        if !(200..300).contains(&released.status()) {
            return Err(SERVICE);
        }
        result
    }
    fn publish(&self, bytes: Vec<u8>, expected: Value) -> Result<Outcome> {
        let path = self.path();
        let info = self.info(&path)?;
        if info["sha256"].as_str() == Some(format!("{:x}", Sha256::digest(&bytes)).as_str()) {
            return Ok(Outcome::Info(json!({"uploaded":true})));
        }
        if info != expected {
            return Err(STALE);
        }
        if !info.is_null() {
            let old = self.download(&path)?;
            if format!("{:x}", Sha256::digest(&old)) != info["sha256"].as_str().ok_or(SERVICE)? {
                return Err(STALE);
            }
            self.snapshot("cloud-before-upload", &old)?;
        }
        self.snapshot("cloud", &bytes)?;
        if self.info(&path)? != expected {
            return Err(STALE);
        }
        self.put(&path, &bytes, !expected.is_null())?;
        Ok(Outcome::Info(json!({"uploaded":true})))
    }
    pub fn merge(
        self,
        local: crate::legacy::Vault,
        password: Zeroizing<String>,
        expected: Value,
    ) -> Result<Outcome> {
        let bytes = self.download(&self.path())?;
        if Some(format!("{:x}", Sha256::digest(&bytes)).as_str()) != expected["sha256"].as_str() {
            return Err(STALE);
        }
        let remote = crate::kdbx::import(&bytes, &password, None)?;
        let merged = crate::merge::merge(&local, remote)?;
        let export = crate::kdbx::export(&merged, &password, None)?;
        let digest = format!("{:x}", Sha256::digest(&export));
        self.upload(export, expected)?;
        Ok(Outcome::Merged(Box::new(merged), digest))
    }
    pub fn restore(
        self,
        backup: Vec<u8>,
        password: Zeroizing<String>,
        version: String,
        expected: Value,
    ) -> Result<Outcome> {
        let path = if version.is_empty() {
            self.path()
        } else {
            if !component(&version) || !version.ends_with(".kdbx") {
                return Err("Недопустимая версия");
            }
            format!("{}/keykeep-history/{version}", self.dir())
        };
        let bytes = self.download(&path)?;
        if version.is_empty()
            && Some(format!("{:x}", Sha256::digest(&bytes)).as_str()) != expected["sha256"].as_str()
        {
            return Err(STALE);
        }
        // Verify the downloaded database before creating any remote backup.
        crate::kdbx::import(&bytes, &password, None)?;
        self.prepare()?;
        self.snapshot("local-before-restore", &backup)?;
        Ok(Outcome::Restore(bytes, password))
    }
}

#[cfg(test)]
mod tests;

/// Native-only account exchange. The platform stores the returned account in its credential store.
pub(crate) fn shared_oauth(request: Value) -> Result<Value> {
    let mut account: Account =
        serde_json::from_value(request["account"].clone()).map_err(|_| SERVICE)?;
    match request["op"].as_str() {
        Some("authorize") => {
            let url = account.authorize()?;
            Ok(json!({"account":account,"url":url}))
        }
        Some("callback") => {
            let (code, verifier) =
                account.callback(request["callback"].as_str().ok_or(SERVICE)?)?;
            let client = Client::new(account.clone(), Arc::new(AtomicBool::new(false)));
            let Outcome::Token(token) = client.exchange(code, verifier)? else {
                return Err(SERVICE);
            };
            account.token = token.to_string();
            Ok(json!({"account":account}))
        }
        _ => Err(SERVICE),
    }
}
