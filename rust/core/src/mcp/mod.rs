//! MCP access is explicit, session-scoped and mediated by the unlocked vault UI.
mod catalog;
use catalog::tools;
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
    allow_creation: bool,
    requests: u64,
    last_client: Option<String>,
    approval: Option<Approval>,
}
fn is_create(name: &Value) -> bool {
    matches!(
        name.as_str(),
        Some("create_folder" | "create_password_entry")
    )
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
                json!({"key":a.key.to_string(),"title":a.title,"canAllowCreation":is_create(&a.request.message["params"]["name"]),"previousTitle":a.original.as_ref().map(|e|&e.values.title),"action":if !a.write{"read"}else{"operation"}})
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
                json!({"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false},"experimental":{"com.max.keykeep/session-creation":{"allowed":self.allow_creation}}},"serverInfo":{"name":"KeyKeep","version":"1.0"}}),
            ),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(tools()),
            "tools/call" if params["name"] == "list_vault_structure" => Ok(tool_result(
                json!({"folders":v.folders,"entries":v.entries.iter().map(|e|json!({"id":e.id,"title":e.values.title,"username":e.values.username,"folderId":e.values.folder_id,"updatedAt":e.updated_at})).collect::<Vec<_>>()}),
            )),
            "tools/call" if params["name"] == "list_trash" => {
                Ok(tool_result(json!({"items":v.trash_list()})))
            }
            "tools/call" => {
                let args = &params["arguments"];
                let name = params["name"].as_str().unwrap_or("");
                let original = args["id"]
                    .as_str()
                    .and_then(|id| v.entries.iter().find(|e| e.id == id));
                let write = name != "get_password_entry";
                let catalog = tools();
                let spec = catalog["tools"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|t| t["name"] == name);
                let title = spec
                    .filter(|t| {
                        let schema = &t["inputSchema"];
                        (!write
                            || self.writable
                            || self.allow_creation && is_create(&params["name"]))
                            && schema["required"].as_array().unwrap().iter().all(|k| {
                                args[k.as_str().unwrap()]
                                    .as_str()
                                    .is_some_and(|v| !v.trim().is_empty())
                            })
                            && (args.is_null()
                                || args.as_object().is_some_and(|obj| {
                                    obj.iter().all(|(k, v)| {
                                        schema["properties"].get(k).is_some()
                                            && if k == "customFields" {
                                                v.is_array()
                                            } else {
                                                v.is_string()
                                            }
                                    })
                                }))
                    })
                    .and_then(|t| {
                        if !write {
                            return original.map(|e| e.values.title.clone());
                        }
                        let target = original
                            .map(|e| e.values.title.as_str())
                            .or_else(|| {
                                v.folders
                                    .iter()
                                    .find(|f| args["id"] == f.id)
                                    .map(|f| f.name.as_str())
                            })
                            .or_else(|| {
                                v.trash
                                    .iter()
                                    .find(|f| args["id"] == f.id)
                                    .map(|f| f.name.as_str())
                            })
                            .unwrap_or("");
                        Some(format!(
                            "{} {} {}",
                            t["description"].as_str().unwrap(),
                            target,
                            args["name"]
                                .as_str()
                                .or(args["title"].as_str())
                                .unwrap_or("")
                        ))
                    });
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
        if op == "mcpToolCatalog" {
            return Ok(tools());
        }
        let (pin, v) = self.unlocked.as_ref().ok_or("Хранилище заблокировано")?;
        match op {
            "mcpStatus" => Ok(
                json!({"requests":self.mcp.as_ref().map_or(0, |s|s.requests),"client":self.mcp.as_ref().and_then(|s|s.last_client.as_deref()),"allowCreation":self.mcp.as_ref().is_some_and(|s|s.allow_creation),"running":self.mcp.is_some(),"writable":self.mcp.as_ref().is_some_and(|s|s.writable)}),
            ),
            "mcpStart" => {
                if self.mcp.is_none() {
                    let transport = Transport::bind(if cfg!(test) { 0 } else { MCP_PORT })?;
                    self.ensure_mcp_token()?;
                    self.mcp = Some(Server {
                        transport,
                        requests: 0,
                        last_client: None,
                        writable: false,
                        allow_creation: false,
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
                if !s.writable {
                    s.allow_creation = false;
                }
                if !s.writable && s.approval.as_ref().is_some_and(|a| a.write) {
                    s.approval = None;
                }
                Ok(Value::Null)
            }
            "mcpCreationMode" => {
                self.mcp.as_mut().ok_or("MCP выключен")?.allow_creation = r["enabled"]
                    .as_bool()
                    .ok_or("Укажите разрешение на создание")?;
                Ok(Value::Null)
            }
            "mcpPoll" => {
                let Some(server) = self.mcp.as_mut() else {
                    return Ok(json!(false));
                };
                let prompt = server.poll(v);
                if server.allow_creation && prompt["canAllowCreation"] == true {
                    return self
                        .mcp_operation("mcpDecide", &json!({"key":prompt["key"],"allow":true}));
                }
                Ok(prompt)
            }
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
                let create = is_create(&a.request.message["params"]["name"]);
                let writable = server.writable || (create && server.allow_creation);
                if create
                    && server.writable
                    && r["allow"] == true
                    && r["sessionCreation"] == true
                    && a.request.expires > Instant::now()
                {
                    server.allow_creation = true;
                }
                let mut changed = false;
                let result = if r["allow"] != true || a.request.expires <= Instant::now() {
                    Err(error("Владелец не подтвердил запрос"))
                } else if old != a.original.as_ref() {
                    Err(error("Запись изменилась. Повторите запрос"))
                } else if !a.write {
                    Ok(tool_result(json!(old)))
                } else if writable
                    && matches!(
                        a.request.message["params"]["name"].as_str(),
                        Some("create_vault" | "rename_vault" | "delete_vault")
                    )
                {
                    let vault_name = args["name"].clone();
                    let action = a.request.message["params"]["name"].clone();
                    a.request.finish(Ok(tool_result(
                        json!({"status":"accepted","completion":"local_application"}),
                    )));
                    return Ok(json!({"vaultAction":action,"name":vault_name}));
                } else if writable
                    && matches!(
                        a.request.message["params"]["name"].as_str(),
                        Some(
                            "create_folder"
                                | "update_folder"
                                | "delete_folder"
                                | "delete_password_entry"
                                | "restore_trash_item"
                        )
                    )
                {
                    let id = &args["id"];
                    let current = v.folders.iter().find(|f| id == &f.id);
                    let cmd = match a.request.message["params"]["name"].as_str().unwrap() {
                        "create_folder" => {
                            json!({"op":"addFolder","name":args["name"],"parent":args["parentId"].as_str().unwrap_or("root")})
                        }
                        "update_folder" => {
                            json!({"op":"editFolder","id":id,"name":args["name"].as_str().or(current.map(|f|f.name.as_str())),"parent":args["parentId"].as_str().or(current.map(|f|f.parent_id.as_str()))})
                        }
                        "delete_folder" => json!({"op":"deleteFolder","id":id,"confirmed":true}),
                        "delete_password_entry" => {
                            json!({"op":"deleteEntry","id":id,"confirmed":true})
                        }
                        _ => json!({"op":"restoreDeleted","id":id}),
                    };
                    self.call(cmd)
                        .map(|value| {
                            changed = true;
                            tool_result(json!({"id":value.as_str().or(id.as_str())}))
                        })
                        .map_err(error)
                } else if writable {
                    if a.request.message["params"]["name"] == "update_password_entry"
                        && old.is_none()
                    {
                        a.request.finish(Err(error("Запись отсутствует")));
                        return Ok(json!({"changed":false}));
                    }
                    let mut values = old.map(|e| json!(e.values)).unwrap_or_else(|| json!({}));
                    for field in [
                        "title",
                        "username",
                        "password",
                        "website",
                        "note",
                        "folderId",
                        "customFields",
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
