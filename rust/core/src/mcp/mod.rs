//! MCP access is explicit, session-scoped and mediated by the unlocked vault UI.
mod transport;
use crate::{
    legacy::{Entry, Vault},
    session::Session,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::{RngCore, rngs::OsRng};
use serde_json::{Value, json};
use std::{sync::mpsc::SyncSender, time::Instant};
use transport::{Transport, error};
use uuid::Uuid;

const MCP_PORT: u16 = 8766;

type Result<T> = std::result::Result<T, &'static str>;
struct Request {
    message: Value,
    reply: SyncSender<Option<Value>>,
    expires: Instant,
}
impl Request {
    fn finish(self, result: std::result::Result<Value, Value>) {
        let id = &self.message["id"];
        let response = match result {
            Ok(value) => json!({"jsonrpc":"2.0","id":id,"result":value}),
            Err(value) => json!({"jsonrpc":"2.0","id":id,"error":value}),
        };
        let _ = self.reply.send(Some(response));
    }
}
struct Approval {
    key: Uuid,
    request: Request,
    original: Option<Entry>,
    write: bool,
    title: String,
}
pub struct Server {
    transport: Transport,
    writable: bool,
    requests: u64,
    last_client: Option<String>,
    approval: Option<Approval>,
}
fn random_token() -> Result<String> {
    let mut key = [0; 32];
    OsRng
        .try_fill_bytes(&mut key)
        .map_err(|_| "Ошибка генератора")?;
    Ok(URL_SAFE_NO_PAD.encode(key))
}
fn tool_result(result: Value) -> Value {
    json!({"content":[{"type":"text","text":result.to_string()}],"structuredContent":result,"isError":false})
}
fn tools() -> Value {
    let mut fields = serde_json::Map::new();
    for key in [
        "id", "title", "username", "password", "folderId", "website", "note",
    ] {
        fields.insert(key.into(), json!({"type":"string"}));
    }
    json!({"tools":[
        {"name":"list_vault_structure","description":"List folders and entry metadata.","inputSchema":{"type":"object","properties":{}}},
        {"name":"get_password_entry","description":"Read one entry after the owner approves.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
        {"name":"upsert_password_entry","description":"Create or update one entry after the owner approves.","inputSchema":{"type":"object","properties":fields,"required":["title","username","password"]}}
    ]})
}
impl Server {
    fn poll(&mut self, v: &Vault) -> Value {
        if self
            .approval
            .as_ref()
            .is_some_and(|a| a.request.expires <= Instant::now())
        {
            self.approval = None;
        }
        if self.approval.is_none()
            && let Some(request) = self.transport.poll(&v.mcp_token)
        {
            self.dispatch(v, request);
        }
        match &self.approval {
            None => Value::Null,
            Some(a) => {
                json!({"key":a.key.to_string(),"title":a.title,"previousTitle":a.original.as_ref().map(|e|&e.values.title),"action":if !a.write{"read"}else if a.original.is_some(){"update"}else{"create"}})
            }
        }
    }
    fn dispatch(&mut self, v: &Vault, request: Request) {
        let msg = &request.message;
        let method = msg["method"].as_str();
        if msg["jsonrpc"] != "2.0" || method.is_none() {
            request.finish(Err(
                json!({"code":-32600,"message":"Invalid JSON-RPC request"}),
            ));
            return;
        }
        if msg.get("id").is_none() {
            let _ = request.reply.send(None);
            return;
        }
        self.requests = self.requests.saturating_add(1);
        let params = &msg["params"];
        if method == Some("initialize") {
            self.last_client = params["clientInfo"]["name"]
                .as_str()
                .map(|s| s.chars().filter(|c| !c.is_control()).take(64).collect());
        }
        let result = match method.unwrap() {
            "initialize" => Ok(
                json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"KeyKeep","version":"1.0"}}),
            ),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(tools()),
            "tools/call" if params["name"] == "list_vault_structure" => Ok(tool_result(
                json!({"folders":v.folders,"entries":v.entries.iter().map(|e|json!({"id":e.id,"title":e.values.title,"username":e.values.username,"folderId":e.values.folder_id,"updatedAt":e.updated_at})).collect::<Vec<_>>()}),
            )),
            "tools/call" => {
                let args = &params["arguments"];
                let original = args["id"]
                    .as_str()
                    .and_then(|id| v.entries.iter().find(|e| e.id == id));
                let write = params["name"] == "upsert_password_entry";
                let title = if write
                    && self.writable
                    && ["title", "username", "password"]
                        .iter()
                        .all(|k| args[k].as_str().is_some_and(|s| !s.trim().is_empty()))
                {
                    args["title"].as_str()
                } else if params["name"] == "get_password_entry" {
                    original.map(|e| e.values.title.as_str())
                } else {
                    None
                };
                if let Some(title) = title {
                    let title = title.to_owned();
                    self.approval = Some(Approval {
                        key: Uuid::new_v4(),
                        original: original.cloned(),
                        write,
                        title,
                        request,
                    });
                    return;
                }
                Err(error(
                    "Запрос недоступен. Проверьте запись, аргументы и режим записи.",
                ))
            }
            _ => Err(json!({"code":-32601,"message":"Method not found"})),
        };
        request.finish(result);
    }
}

impl Session {
    fn ensure_mcp_token(&mut self) -> Result<&str> {
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        if v.mcp_token.is_empty() {
            let mut next = v.clone();
            next.mcp_token = random_token()?;
            self.write(&next, pin)?;
            self.unlocked.as_mut().unwrap().1 = next;
        }
        Ok(&self.unlocked.as_ref().unwrap().1.mcp_token)
    }
    pub(crate) fn mcp_operation(&mut self, op: &str, r: &Value) -> Result<Value> {
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        match op {
            "mcpStatus" => Ok(
                json!({"requests":self.mcp.as_ref().map_or(0, |s|s.requests),"client":self.mcp.as_ref().and_then(|s|s.last_client.as_deref()),"running":self.mcp.is_some(),"writable":self.mcp.as_ref().is_some_and(|s|s.writable)}),
            ),
            "mcpStart" => {
                if self.mcp.is_none() {
                    let transport = Transport::bind(MCP_PORT)?;
                    self.ensure_mcp_token()?;
                    self.mcp = Some(Server {
                        transport,
                        requests: 0,
                        last_client: None,
                        writable: false,
                        approval: None,
                    });
                }
                Ok(Value::Null)
            }
            "mcpStop" => {
                self.mcp = None;
                Ok(Value::Null)
            }
            "mcpConnection" => {
                let port = self
                    .mcp
                    .as_ref()
                    .map_or(MCP_PORT, |server| server.transport.port());
                let token = self.ensure_mcp_token()?;
                Ok(json!(format!(
                    "export KEYKEEP_MCP_TOKEN='{}'\ncodex mcp add keykeep --url 'http://127.0.0.1:{}/mcp' --bearer-token-env-var KEYKEEP_MCP_TOKEN",
                    token, port
                )))
            }
            "mcpRotate" => {
                let mut next = v.clone();
                next.mcp_token = random_token()?;
                self.write(&next, pin)?;
                self.unlocked.as_mut().unwrap().1 = next;
                self.mcp = None;
                Ok(Value::Null)
            }
            "mcpMode" => {
                let s = self.mcp.as_mut().ok_or("MCP выключен")?;
                s.writable = r["enabled"].as_bool().ok_or("Укажите режим записи")?;
                if !s.writable && s.approval.as_ref().is_some_and(|a| a.write) {
                    s.approval = None;
                }
                Ok(Value::Null)
            }
            "mcpPoll" => Ok(self
                .mcp
                .as_mut()
                .map(|s| s.poll(v))
                .unwrap_or(Value::Bool(false))),
            "mcpDecide" => {
                let server = self.mcp.as_mut().ok_or("MCP выключен")?;
                if !server
                    .approval
                    .as_ref()
                    .is_some_and(|a| r["key"] == a.key.to_string())
                {
                    return Err("Запрос устарел");
                }
                let a = server.approval.take().unwrap();
                let args = &a.request.message["params"]["arguments"];
                let old = args["id"]
                    .as_str()
                    .and_then(|id| v.entries.iter().find(|e| e.id == id));
                let mut changed = false;
                let result = if r["allow"] != true || a.request.expires <= Instant::now() {
                    Err(error("Владелец не подтвердил запрос"))
                } else if old != a.original.as_ref() {
                    Err(error("Запись изменилась. Повторите запрос"))
                } else if !a.write {
                    Ok(tool_result(json!(old)))
                } else if server.writable {
                    let mut values = old.map(|e| json!(e.values)).unwrap_or_else(|| json!({}));
                    for field in [
                        "title", "username", "password", "website", "note", "folderId",
                    ] {
                        if let Some(val) = args.get(field) {
                            values[field] = val.clone();
                        }
                    }
                    let updated = old.is_some();
                    let id = args["id"].as_str().unwrap_or("");
                    let result = (|| -> Result<(Vault, String)> {
                        let values =
                            serde_json::from_value(values).map_err(|_| "Некорректные поля")?;
                        let mut next = v.clone();
                        let id = Self::save_entry(
                            &mut next,
                            id,
                            values,
                            chrono::Utc::now().to_rfc3339(),
                            true,
                        )?;
                        self.write(&next, pin)?;
                        Ok((next, id))
                    })();
                    result
                        .map(|(next, id)| {
                            self.unlocked.as_mut().unwrap().1 = next;
                            changed = true;
                            tool_result(json!({"id":id,"updated":updated}))
                        })
                        .map_err(error)
                } else {
                    Err(error("Режим только для чтения"))
                };
                a.request.finish(result);
                Ok(json!({"changed":changed}))
            }
            _ => Err("Неизвестная операция MCP"),
        }
    }
}

#[cfg(test)]
mod tests;
