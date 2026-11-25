use super::*;
use std::{net::TcpStream, thread, time::Duration};

fn tool(name: &str, args: Value) -> Value {
    json!({"jsonrpc":"2.0","method":"tools/call","id":1,"params":{"name":name,"arguments":args}})
}
fn client(port: u16, token: &str, msg: Value) -> thread::JoinHandle<(u16, Value)> {
    let token = token.to_owned();
    thread::spawn(move || {
        let call = ureq::post(&format!("http://127.0.0.1:{port}/mcp"))
            .timeout(Duration::from_secs(5))
            .set("Authorization", &format!("Bearer {token}"))
            .send_json(msg);
        match call {
            Ok(r) => (r.status(), r.into_json().unwrap_or(Value::Null)),
            Err(ureq::Error::Status(s, _)) => (s, Value::Null),
            Err(e) => panic!("transport: {e}"),
        }
    })
}
fn pump(s: &mut Session, port: u16, token: &str, msg: Value, allow: Option<bool>) -> (u16, Value) {
    let worker = client(port, token, msg);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut approvals = 0;
    while !worker.is_finished() {
        assert!(Instant::now() < deadline);
        let a = s.call(json!({"op":"mcpPoll"})).unwrap();
        if !a.is_null() {
            approvals += 1;
            s.call(json!({"op":"mcpDecide","key":a["key"],"allow":allow.expect("unexpected approval")})).unwrap();
        }
        thread::sleep(Duration::from_millis(4));
    }
    assert_eq!(approvals, usize::from(allow.is_some()));
    worker.join().unwrap()
}
#[test]
fn loopback_approval_modes_rotation_and_lock() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = Session::new(dir.path().join("vault.kk"), [17; 32]).unwrap();
    let op = |name: &str| json!({"op":name});
    s.call(json!({"op":"create","pin":"fixture-pin"})).unwrap();
    assert_eq!(s.call(op("mcpStatus")).unwrap()["running"], false);
    s.call(op("mcpStart")).unwrap();
    let port = s.mcp.as_ref().unwrap().transport.port();
    let token = s.unlocked.as_ref().unwrap().1.mcp_token.clone();
    let list = tool("list_vault_structure", json!({}));
    assert_eq!(pump(&mut s, port, "invalid", list.clone(), None).0, 401);
    let create = tool(
        "upsert_password_entry",
        json!({"id":"fixture-id","title":"Fixture","username":"demo","password":"fixture-secret"}),
    );
    assert!(
        pump(&mut s, port, &token, create.clone(), None)
            .1
            .get("error")
            .is_some()
    );
    s.call(json!({"op":"mcpMode","enabled":true})).unwrap();
    assert!(
        pump(&mut s, port, &token, create.clone(), Some(false))
            .1
            .get("error")
            .is_some()
    );
    assert!(s.unlocked.as_ref().unwrap().1.entries.is_empty());
    let created = pump(&mut s, port, &token, create, Some(true)).1;
    let id = created["result"]["structuredContent"]["id"]
        .as_str()
        .unwrap();
    assert_eq!(id, "fixture-id");
    let get = tool("get_password_entry", json!({"id":id}));
    assert!(
        !pump(&mut s, port, &token, list.clone(), None)
            .1
            .to_string()
            .contains("fixture-secret")
    );
    assert!(
        pump(&mut s, port, &token, get.clone(), Some(false))
            .1
            .get("error")
            .is_some()
    );
    assert_eq!(
        pump(&mut s, port, &token, get.clone(), Some(true)).1["result"]["structuredContent"]["password"],
        "fixture-secret"
    );
    let update = tool(
        "upsert_password_entry",
        json!({"id":id,"title":"Renamed","username":"user","password":"updated"}),
    );
    assert_eq!(
        pump(&mut s, port, &token, update, Some(true)).1["result"]["structuredContent"]["updated"],
        true
    );
    assert_eq!(s.unlocked.as_ref().unwrap().1.entries[0].history.len(), 1);
    let mut invoke = |name, args| {
        pump(&mut s, port, &token, tool(name, args), Some(true)).1["result"]["structuredContent"]
            .clone()
    };
    let parent = invoke("create_folder", json!({"name":"Parent"}))["id"].clone();
    let child = invoke("create_folder", json!({"name":"Child","parentId":parent}))["id"].clone();
    let entry = invoke(
        "create_password_entry",
        json!({"title":"New","username":"demo","password":"test","folderId":child}),
    )["id"]
        .clone();
    assert!(entry.is_string());
    assert_eq!(
        invoke(
            "update_password_entry",
            json!({"id":entry,"customFields":[{"name":"Field","value":"Value"}]})
        )["updated"],
        true
    );
    let deleted = invoke("delete_password_entry", json!({"id":entry}))["id"].clone();
    invoke("delete_folder", json!({"id":parent}));
    invoke("restore_trash_item", json!({"id":deleted}));
    let restored = invoke("get_password_entry", json!({"id":entry}));
    assert_eq!(restored["folderId"], child);
    assert_eq!(restored["customFields"][0]["value"], "Value");
    assert_eq!(restored["history"].as_array().unwrap().len(), 1);
    let trash = pump(&mut s, port, &token, tool("list_trash", json!({})), None).1;
    assert_eq!(
        trash["result"]["structuredContent"]["items"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    s.call(op("mcpRotate")).unwrap();
    s.call(op("mcpStart")).unwrap();
    assert_eq!(pump(&mut s, port, &token, list, None).0, 401);
    let new_token = s.unlocked.as_ref().unwrap().1.mcp_token.clone();
    let worker = client(port, &new_token, get);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        assert!(Instant::now() < deadline);
        if !s.call(op("mcpPoll")).unwrap().is_null() {
            break;
        }
        thread::sleep(Duration::from_millis(4));
    }
    s.call(op("lock")).unwrap();
    assert_eq!(worker.join().unwrap().0, 403);
    assert!(TcpStream::connect(("127.0.0.1", port)).is_err());
    s.call(json!({"op":"unlock","pin":"fixture-pin"})).unwrap();
    assert_eq!(s.call(op("mcpStatus")).unwrap()["running"], false);
    assert_eq!(s.unlocked.as_ref().unwrap().1.mcp_token, new_token);
}

#[test]
#[ignore = "requires the official MCP Python SDK, configured through MCP_PYTHON"]
fn official_client_initializes_and_lists_tools() {
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let mut s = Session::new(dir.path().join("vault.kk"), [9; 32]).unwrap();
    s.call(json!({"op":"create","pin":"fixture-pin"})).unwrap();
    let token = random_token().unwrap();
    s.unlocked.as_mut().unwrap().1.mcp_token = token.clone();
    let transport = Transport::bind(0).unwrap();
    let port = transport.port();
    s.mcp = Some(Server {
        requests: 0,
        last_client: None,
        transport,
        writable: false,
        approval: None,
    });
    let mut client=Command::new(std::env::var("MCP_PYTHON").expect("set MCP_PYTHON"))
        .args(["-c",r#"
import asyncio, os
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def run():
    headers = {"Authorization": "Bearer " + os.environ["FIXTURE_TOKEN"]}
    async with streamablehttp_client(os.environ["FIXTURE_URL"], headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            assert {"list_vault_structure","create_folder","delete_folder","restore_trash_item","create_password_entry"} <= {t.name for t in result.tools}
            data = await session.call_tool("list_vault_structure", {})
            assert data.structuredContent["entries"] == []
asyncio.run(run())
"#]).env("FIXTURE_TOKEN",token).env("FIXTURE_URL",format!("http://127.0.0.1:{port}/mcp")).spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while client.try_wait().unwrap().is_none() {
        if Instant::now() > deadline {
            client.kill().unwrap();
            client.wait().unwrap();
            panic!("MCP client timed out");
        }
        assert!(s.call(json!({"op":"mcpPoll"})).unwrap().is_null());
        thread::sleep(Duration::from_millis(5));
    }
    assert!(client.wait().unwrap().success());
}
