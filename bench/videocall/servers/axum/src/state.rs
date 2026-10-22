//! In-memory app state: users, tokens, the lobby, calls and chat history.
//! Everything sits behind one mutex; nothing awaits while it is held.

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::Bytes;
use flate2::Compression;
use flate2::write::DeflateEncoder;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::mpsc;

pub const HEADER_LEN: usize = 24;
pub const MAX_MEDIA: usize = 1 << 20;
const FLAG_COMPRESSED: u8 = 0b10;
const HISTORY: usize = 100;

/// A message for a connection's writer task.
pub enum Out {
    Text(String),
    /// Header + compressed payload; byte 0 is the kind.
    Media(Bytes),
}

pub type Tx = mpsc::UnboundedSender<Out>;
pub type Rx = mpsc::UnboundedReceiver<Out>;

pub struct User {
    pub name: String,
}

struct Conn {
    id: u64,
    tx: Tx,
    call: Option<u64>,
}

pub struct Call {
    pub users: [u64; 2],
    next_msg: u64,
    pub history: VecDeque<String>,
}

#[derive(Default)]
struct Inner {
    users: HashMap<u64, User>,
    tokens: HashMap<String, u64>,
    conns: HashMap<u64, Conn>,
    lobby: VecDeque<u64>,
    calls: HashMap<u64, Call>,
    next_user: u64,
    next_call: u64,
}

#[derive(Default)]
pub struct App {
    inner: Mutex<Inner>,
    next_conn: AtomicU64,
}

pub enum ConnectError {
    Unauthorized,
    Conflict,
}

pub enum HistoryError {
    NotFound,
    Forbidden,
}

/// Returned when a media message is over 1 MiB: the connection must close.
pub struct TooBig;

#[derive(Serialize)]
struct UserRef<'a> {
    id: u64,
    name: &'a str,
}

#[derive(Serialize)]
struct Hello<'a> {
    #[serde(rename = "type")]
    ty: &'static str,
    user: UserRef<'a>,
}

#[derive(Serialize)]
struct CallMsg<'a> {
    #[serde(rename = "type")]
    ty: &'static str,
    call_id: u64,
    peer: UserRef<'a>,
}

#[derive(Serialize)]
struct ChatOut<'a> {
    #[serde(rename = "type")]
    ty: &'static str,
    call_id: u64,
    id: u64,
    from: &'a str,
    text: &'a str,
    sent_us: &'a Value,
}

#[derive(Serialize)]
struct PeerLeft {
    #[serde(rename = "type")]
    ty: &'static str,
    call_id: u64,
}

#[derive(Serialize)]
struct ErrorMsg {
    #[serde(rename = "type")]
    ty: &'static str,
    error: &'static str,
}

#[derive(Deserialize)]
struct ClientMsg {
    #[serde(rename = "type")]
    ty: String,
    text: Option<Value>,
    #[serde(default)]
    sent_us: Value,
}

fn json<T: Serialize>(v: &T) -> String {
    serde_json::to_string(v).expect("serialize")
}

fn error(e: &'static str) -> Out {
    Out::Text(json(&ErrorMsg { ty: "error", error: e }))
}

impl Inner {
    fn send(&self, user: u64, out: Out) {
        if let Some(c) = self.conns.get(&user) {
            let _ = c.tx.send(out);
        }
    }

    /// Pairs the two oldest waiting users while there are two.
    fn pair(&mut self) {
        while self.lobby.len() >= 2 {
            let a = self.lobby.pop_front().unwrap();
            let b = self.lobby.pop_front().unwrap();
            self.next_call += 1;
            let call_id = self.next_call;
            self.calls.insert(
                call_id,
                Call { users: [a, b], next_msg: 0, history: VecDeque::new() },
            );
            for (me, peer) in [(a, b), (b, a)] {
                self.conns.get_mut(&me).unwrap().call = Some(call_id);
                let msg = json(&CallMsg {
                    ty: "call",
                    call_id,
                    peer: UserRef { id: peer, name: &self.users[&peer].name },
                });
                self.send(me, Out::Text(msg));
            }
        }
    }

    /// Ends `call_id` because `leaver` left or disconnected. The peer, if
    /// still connected, gets `peer_left` and goes back into the lobby.
    fn end_call(&mut self, call_id: u64, leaver: u64) {
        let Some(call) = self.calls.get(&call_id) else { return };
        let peer = if call.users[0] == leaver { call.users[1] } else { call.users[0] };
        if let Some(c) = self.conns.get_mut(&leaver) {
            c.call = None;
        }
        if let Some(c) = self.conns.get_mut(&peer) {
            if c.call == Some(call_id) {
                c.call = None;
                let _ = c.tx.send(Out::Text(json(&PeerLeft { ty: "peer_left", call_id })));
                self.lobby.push_back(peer);
            }
        }
    }
}

impl App {
    pub fn create_user(&self, name: String) -> (u64, String) {
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).expect("CSPRNG");
        let token: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let mut s = self.inner.lock().unwrap();
        s.next_user += 1;
        let id = s.next_user;
        s.users.insert(id, User { name });
        s.tokens.insert(token.clone(), id);
        (id, token)
    }

    pub fn user_for_token(&self, token: &str) -> Option<u64> {
        self.inner.lock().unwrap().tokens.get(token).copied()
    }

    /// The call's history as a JSON body, if `user` may read it.
    pub fn history(&self, user: u64, call_id: Option<u64>) -> Result<String, HistoryError> {
        let s = self.inner.lock().unwrap();
        let call = call_id.and_then(|id| s.calls.get(&id)).ok_or(HistoryError::NotFound)?;
        if !call.users.contains(&user) {
            return Err(HistoryError::Forbidden);
        }
        let mut body = format!("{{\"call_id\":{},\"messages\":[", call_id.unwrap());
        for (i, m) in call.history.iter().enumerate() {
            if i > 0 {
                body.push(',');
            }
            body.push_str(m);
        }
        body.push_str("]}");
        Ok(body)
    }

    /// Reserves the user's one realtime connection (before the upgrade).
    pub fn connect(&self, token: Option<&str>) -> Result<(u64, u64, Rx), ConnectError> {
        let mut s = self.inner.lock().unwrap();
        let user = token
            .and_then(|t| s.tokens.get(t).copied())
            .ok_or(ConnectError::Unauthorized)?;
        if s.conns.contains_key(&user) {
            return Err(ConnectError::Conflict);
        }
        let id = self.next_conn.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::unbounded_channel();
        s.conns.insert(user, Conn { id, tx, call: None });
        Ok((user, id, rx))
    }

    /// The connection is open: send `hello` and join the lobby.
    pub fn open(&self, user: u64) {
        let mut s = self.inner.lock().unwrap();
        let hello = json(&Hello {
            ty: "hello",
            user: UserRef { id: user, name: &s.users[&user].name },
        });
        s.send(user, Out::Text(hello));
        s.lobby.push_back(user);
        s.pair();
    }

    pub fn disconnect(&self, user: u64, conn: u64) {
        let mut s = self.inner.lock().unwrap();
        if s.conns.get(&user).map(|c| c.id) != Some(conn) {
            return;
        }
        let c = s.conns.remove(&user).unwrap();
        s.lobby.retain(|&u| u != user);
        if let Some(call) = c.call {
            s.end_call(call, user);
            s.pair();
        }
    }

    /// Handles one client text message.
    pub fn text(&self, user: u64, text: &str) {
        let msg: Option<ClientMsg> = serde_json::from_str(text).ok();
        let mut s = self.inner.lock().unwrap();
        match msg.as_ref().map(|m| m.ty.as_str()) {
            Some("chat") => {
                let msg = msg.as_ref().unwrap();
                let text = match &msg.text {
                    Some(Value::String(t)) if (1..=500).contains(&t.chars().count()) => t,
                    _ => return s.send(user, error("invalid chat")),
                };
                let Some(call_id) = s.conns.get(&user).and_then(|c| c.call) else {
                    return s.send(user, error("not in a call"));
                };
                let from = s.users[&user].name.clone();
                let call = s.calls.get_mut(&call_id).unwrap();
                call.next_msg += 1;
                let out = json(&ChatOut {
                    ty: "chat",
                    call_id,
                    id: call.next_msg,
                    from: &from,
                    text,
                    sent_us: &msg.sent_us,
                });
                if call.history.len() == HISTORY {
                    call.history.pop_front();
                }
                call.history.push_back(out.clone());
                let users = call.users;
                s.send(users[0], Out::Text(out.clone()));
                s.send(users[1], Out::Text(out));
            }
            Some("leave") => {
                if let Some(call_id) = s.conns.get(&user).and_then(|c| c.call) {
                    s.end_call(call_id, user);
                    s.lobby.push_back(user);
                    s.pair();
                }
            }
            _ => s.send(user, error("bad message")),
        }
    }

    /// Relays one client media message to the peer, compressed.
    pub fn media(&self, user: u64, data: &[u8]) -> Result<(), TooBig> {
        if data.len() > MAX_MEDIA {
            return Err(TooBig);
        }
        if data.len() < HEADER_LEN || data[1] & FLAG_COMPRESSED != 0 {
            return Ok(());
        }
        let peer_tx = {
            let s = self.inner.lock().unwrap();
            let Some(call) = s.conns.get(&user).and_then(|c| c.call) else { return Ok(()) };
            let users = s.calls[&call].users;
            let peer = if users[0] == user { users[1] } else { users[0] };
            match s.conns.get(&peer) {
                Some(c) => c.tx.clone(),
                None => return Ok(()),
            }
        };
        let mut out = Vec::with_capacity(data.len());
        out.extend_from_slice(&data[..HEADER_LEN]);
        out[1] |= FLAG_COMPRESSED;
        let mut enc = DeflateEncoder::new(out, Compression::default());
        enc.write_all(&data[HEADER_LEN..]).expect("deflate");
        let out = enc.finish().expect("deflate");
        let _ = peer_tx.send(Out::Media(Bytes::from(out)));
        Ok(())
    }
}
