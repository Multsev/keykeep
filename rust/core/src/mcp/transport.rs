//! One loopback request at a time. Network I/O never runs on the UI thread.
use super::Request;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

pub struct Transport {
    listener: TcpListener,
    incoming: Option<mpsc::Receiver<Request>>,
}
impl Transport {
    pub fn bind(port: u16) -> Result<Self, &'static str> {
        let listener = TcpListener::bind(("127.0.0.1", port)).map_err(|_| "Порт MCP занят")?;
        listener
            .set_nonblocking(true)
            .map_err(|_| "Не удалось запустить MCP")?;
        Ok(Self {
            listener,
            incoming: None,
        })
    }
    pub fn port(&self) -> u16 {
        self.listener.local_addr().unwrap().port()
    }
    pub fn poll(&mut self, token: &str) -> Option<Request> {
        if let Some(rx) = &self.incoming {
            match rx.try_recv() {
                Ok(req) => return Some(req),
                Err(mpsc::TryRecvError::Empty) => return None,
                Err(mpsc::TryRecvError::Disconnected) => self.incoming = None,
            }
        }
        let (stream, _) = self.listener.accept().ok()?;
        let (tx, rx) = mpsc::sync_channel(1);
        self.incoming = Some(rx);
        let token = Zeroizing::new(token.to_owned());
        let _ = thread::Builder::new()
            .name("keykeep-mcp".into())
            .spawn(move || {
                let mut stream = stream;
                if stream.set_nonblocking(false).is_err() {
                    return;
                }
                let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
                match receive(&mut stream, &token) {
                    Ok(message) => {
                        let (reply, rx) = mpsc::sync_channel(1);
                        let request = Request {
                            message,
                            reply,
                            expires: Instant::now() + Duration::from_secs(30),
                        };
                        if tx.send(request).is_err() {
                            respond(&mut stream, 403, None);
                            return;
                        }
                        match rx.recv_timeout(Duration::from_secs(30)) {
                            Ok(value) => {
                                respond(&mut stream, if value.is_some() { 200 } else { 202 }, value)
                            }
                            Err(_) => respond(&mut stream, 403, None),
                        }
                    }
                    Err(code) => respond(&mut stream, code, None),
                }
            });
        None
    }
}

fn receive(stream: &mut TcpStream, token: &str) -> Result<Value, u16> {
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut bytes = Zeroizing::new(Vec::new());
    let mut buffer = [0; 4096];
    let mut read = |bytes: &mut Vec<u8>| -> Result<(), u16> {
        let left = deadline
            .checked_duration_since(Instant::now())
            .ok_or(408u16)?;
        stream.set_read_timeout(Some(left)).map_err(|_| 408u16)?;
        let n = stream.read(&mut buffer).map_err(|_| 408u16)?;
        if n == 0 {
            return Err(400);
        }
        bytes.extend_from_slice(&buffer[..n]);
        Ok(())
    };
    let (offset, length) = loop {
        let mut headers = [httparse::EMPTY_HEADER; 32];
        let mut req = httparse::Request::new(&mut headers);
        if let httparse::Status::Complete(offset) = req.parse(&bytes).map_err(|_| 400u16)? {
            if req.path != Some("/mcp") {
                return Err(404);
            }
            let mut authorization = None;
            let mut length = None;
            for h in req.headers.iter() {
                if h.name.eq_ignore_ascii_case("MCP-Protocol-Version") && h.value != b"2025-06-18" {
                    return Err(400);
                }
                if h.name.eq_ignore_ascii_case("origin")
                    || h.name.eq_ignore_ascii_case("transfer-encoding")
                {
                    return Err(403);
                }
                if h.name.eq_ignore_ascii_case("authorization")
                    && authorization.replace(h.value).is_some()
                {
                    return Err(401);
                }
                if h.name.eq_ignore_ascii_case("content-length") {
                    if length.is_some() {
                        return Err(400);
                    }
                    length = std::str::from_utf8(h.value)
                        .ok()
                        .and_then(|s| s.parse::<usize>().ok());
                    if length.is_none() {
                        return Err(400);
                    }
                }
            }
            let provided = authorization
                .and_then(|a| a.strip_prefix(b"Bearer "))
                .ok_or(401u16)?;
            if !bool::from(provided.ct_eq(token.as_bytes())) {
                return Err(401);
            }
            if req.method != Some("POST") {
                return Err(405);
            }
            let length = length.ok_or(411u16)?;
            if length > 256 * 1024 {
                return Err(413);
            }
            break (offset, length);
        }
        if bytes.len() >= 8192 {
            return Err(431);
        }
        read(&mut bytes)?;
    };
    while bytes.len() < offset + length {
        read(&mut bytes)?;
    }
    serde_json::from_slice(&bytes[offset..offset + length]).map_err(|_| 400)
}
fn respond(stream: &mut TcpStream, status: u16, body: Option<Value>) {
    let body = Zeroizing::new(body.map(|b| b.to_string()).unwrap_or_default());
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Request Error",
    };
    let challenge = if status == 401 {
        "WWW-Authenticate: Bearer\r\n"
    } else {
        ""
    };
    if write!(stream,"HTTP/1.1 {status} {reason}\r\n{challenge}Content-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",body.len()).is_ok(){let _=stream.write_all(body.as_bytes());}
}
pub fn error(message: &str) -> Value {
    json!({"code":-32602,"message":message})
}
