//! Bounded loopback HTTP workers wake the vault owner when a request is ready. Network I/O never runs on the UI thread.
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

use std::os::{fd::AsRawFd, unix::net::UnixStream};
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicUsize, Ordering},
};

// One wake per enqueued request. Detached native waiters own only this signal.
#[derive(Default)]
pub(crate) struct Signal {
    state: Mutex<(usize, bool)>,
    wake: Condvar,
}
impl Signal {
    pub(crate) fn wait(&self) {
        let state = self.state.lock().unwrap();
        let (mut state, _) = self
            .wake
            .wait_timeout_while(state, Duration::from_secs(1), |s| s.0 == 0 && !s.1)
            .unwrap();
        state.0 = state.0.saturating_sub(1);
    }
    fn notify(&self) {
        self.state.lock().unwrap().0 += 1;
        self.wake.notify_one();
    }
}
pub struct Transport {
    port: u16,
    incoming: mpsc::Receiver<Request>,
    stop: UnixStream,
    acceptor: Option<thread::JoinHandle<()>>,
    pub(crate) signal: Arc<Signal>,
}
impl Drop for Transport {
    fn drop(&mut self) {
        self.signal.state.lock().unwrap().1 = true;
        self.signal.wake.notify_all();
        let _ = self.stop.shutdown(std::net::Shutdown::Both);
        if let Some(thread) = self.acceptor.take() {
            let _ = thread.join();
        }
    }
}
impl Transport {
    pub fn bind(port: u16, token: &str) -> Result<Self, &'static str> {
        let listener = TcpListener::bind(("127.0.0.1", port)).map_err(|_| "Порт MCP занят")?;
        listener
            .set_nonblocking(true)
            .map_err(|_| "Не удалось запустить MCP")?;
        let port = listener
            .local_addr()
            .map_err(|_| "Ошибка адреса MCP")?
            .port();
        let (stop, cancel) = UnixStream::pair().map_err(|_| "Ошибка запуска MCP")?;
        let (tx, incoming) = mpsc::channel();
        let signal = Arc::new(Signal::default());
        let ready = signal.clone();
        let token = Arc::new(Zeroizing::new(token.to_owned()));
        let acceptor = thread::Builder::new()
            .name("keykeep-mcp-listener".into())
            .spawn(move || {
                let active = Arc::new(AtomicUsize::new(0));
                let mut events = [
                    libc::pollfd {
                        fd: listener.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                    libc::pollfd {
                        fd: cancel.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                ];
                loop {
                    // Both descriptors are owned by this thread until it exits.
                    if unsafe { libc::poll(events.as_mut_ptr(), 2, -1) } < 0 {
                        if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                        {
                            continue;
                        }
                        break;
                    }
                    if events[1].revents != 0 {
                        break;
                    }
                    let Ok((mut stream, _)) = listener.accept() else {
                        continue;
                    };
                    if active.load(Ordering::Acquire) >= 8 {
                        continue;
                    }
                    let (tx, ready, token, workers) =
                        (tx.clone(), ready.clone(), token.clone(), active.clone());
                    active.fetch_add(1, Ordering::AcqRel);
                    if thread::Builder::new()
                        .name("keykeep-mcp-http".into())
                        .spawn(move || {
                            if stream.set_nonblocking(false).is_ok() {
                                let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
                                match receive(&mut stream, &token) {
                                    Ok(message) => {
                                        let (reply, rx) = mpsc::sync_channel(1);
                                        let request = Request {
                                            message,
                                            reply,
                                            expires: Instant::now() + Duration::from_secs(30),
                                        };
                                        if tx.send(request).is_ok() {
                                            ready.notify();
                                        }
                                        match rx.recv_timeout(Duration::from_secs(30)) {
                                            Ok(value) => respond(
                                                &mut stream,
                                                if value.is_some() { 200 } else { 202 },
                                                value,
                                            ),
                                            Err(_) => respond(&mut stream, 403, None),
                                        }
                                    }
                                    Err(code) => reject(&mut stream, code),
                                }
                            }
                            workers.fetch_sub(1, Ordering::AcqRel);
                        })
                        .is_err()
                    {
                        active.fetch_sub(1, Ordering::AcqRel);
                    }
                }
            })
            .map_err(|_| "Ошибка запуска MCP")?;
        Ok(Self {
            port,
            incoming,
            stop,
            acceptor: Some(acceptor),
            signal,
        })
    }
    pub fn port(&self) -> u16 {
        self.port
    }
    pub(super) fn poll(&self) -> Option<Request> {
        self.incoming.try_recv().ok()
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
// A rejected request can still be arriving. Send FIN before draining so clients
// can read the HTTP error even if closing with unread input would reset TCP.
fn reject(stream: &mut TcpStream, status: u16) {
    respond(stream, status, None);
    if stream.shutdown(std::net::Shutdown::Write).is_err() {
        return;
    }
    let deadline = Instant::now() + Duration::from_millis(250);
    let mut remaining = 256 * 1024;
    let mut buffer = [0; 4096];
    while remaining > 0 {
        let Some(timeout) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        if stream.set_read_timeout(Some(timeout)).is_err() {
            break;
        }
        let limit = remaining.min(buffer.len());
        match stream.read(&mut buffer[..limit]) {
            Ok(0) | Err(_) => break,
            Ok(n) => remaining -= n,
        }
    }
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
