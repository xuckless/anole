//! The realtime connection over WebTransport (draft-02, wtransport) on UDP
//! PORT: an extended CONNECT to /wt?token=…, a client-opened control stream
//! for text, client uni streams for media, and lazily opened server uni
//! streams, one per kind. Every frame is `u32 LE length` + body.

use std::net::SocketAddr;
use std::sync::Arc;

use wtransport::endpoint::IncomingSession;
use wtransport::{Connection, Endpoint, Identity, RecvStream, SendStream, ServerConfig, VarInt};

use crate::state::{App, ConnectError, MAX_MEDIA, Out, Rx};

pub async fn serve(addr: SocketAddr, cert: String, key: String, app: Arc<App>) {
    let identity = Identity::load_pemfiles(cert, key).await.expect("certificate");
    let config = ServerConfig::builder()
        .with_bind_address(addr)
        .with_identity(identity)
        .build();
    let server = Endpoint::server(config).expect("webtransport endpoint");
    loop {
        let incoming = server.accept().await;
        tokio::spawn(session(app.clone(), incoming));
    }
}

/// Splits `:path` into the path and the `token` query parameter.
fn split_token(path: &str) -> (&str, Option<&str>) {
    let (path, query) = path.split_once('?').unwrap_or((path, ""));
    (path, query.split('&').find_map(|kv| kv.strip_prefix("token=")))
}

async fn session(app: Arc<App>, incoming: IncomingSession) {
    let Ok(request) = incoming.await else { return };
    let (path, token) = split_token(request.path());
    let (is_wt, token) = (path == "/wt", token.map(str::to_owned));
    if !is_wt {
        request.not_found().await;
        return;
    }
    // wtransport's SessionRequest can only answer 200, 403, 404 or 429:
    // 403 stands in for 401 and 429 for 409.
    let (user, conn_id, rx) = match app.connect(token.as_deref()) {
        Ok(c) => c,
        Err(ConnectError::Unauthorized) => return request.forbidden().await,
        Err(ConnectError::Conflict) => return request.too_many_requests().await,
    };
    let Ok(conn) = request.accept().await else {
        app.disconnect(user, conn_id);
        return;
    };
    // The client opens the control stream right after the session is ready.
    let control = tokio::select! {
        s = conn.accept_bi() => s.ok(),
        _ = conn.closed() => None,
    };
    let Some((control_send, control_recv)) = control else {
        app.disconnect(user, conn_id);
        return;
    };

    let writer = tokio::spawn(write_loop(conn.clone(), control_send, rx));
    app.open(user);
    tokio::select! {
        _ = control_loop(&app, user, &conn, control_recv) => {}
        _ = accept_media(&app, user, &conn) => {}
        _ = conn.closed() => {}
    }
    app.disconnect(user, conn_id);
    writer.abort();
}

/// Reads one `u32 LE length` + body frame; `None` at the end of the stream.
/// A frame over 1 MiB closes the session.
async fn read_frame(conn: &Connection, recv: &mut RecvStream) -> Option<Vec<u8>> {
    let mut len = [0u8; 4];
    recv.read_exact(&mut len).await.ok()?;
    let len = u32::from_le_bytes(len) as usize;
    if len > MAX_MEDIA {
        conn.close(VarInt::from_u32(0), b"message too big");
        return None;
    }
    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf).await.ok()?;
    Some(buf)
}

async fn control_loop(app: &App, user: u64, conn: &Connection, mut recv: RecvStream) {
    while let Some(frame) = read_frame(conn, &mut recv).await {
        match std::str::from_utf8(&frame) {
            Ok(text) => app.text(user, text),
            Err(_) => app.text(user, ""),
        }
    }
}

async fn accept_media(app: &Arc<App>, user: u64, conn: &Connection) {
    while let Ok(recv) = conn.accept_uni().await {
        tokio::spawn(media_loop(app.clone(), user, conn.clone(), recv));
    }
}

async fn media_loop(app: Arc<App>, user: u64, conn: Connection, mut recv: RecvStream) {
    while let Some(frame) = read_frame(&conn, &mut recv).await {
        // Frames over 1 MiB were refused by read_frame already.
        let _ = app.media(user, &frame);
    }
}

async fn write_frame(send: &mut SendStream, body: &[u8]) -> bool {
    let len = (body.len() as u32).to_le_bytes();
    send.write_all(&len).await.is_ok() && send.write_all(body).await.is_ok()
}

async fn write_loop(conn: Connection, mut control: SendStream, mut rx: Rx) {
    // One server uni stream per kind (1 video, 2 audio), opened lazily and
    // kept for the rest of the session.
    let mut media: [Option<SendStream>; 2] = [None, None];
    while let Some(out) = rx.recv().await {
        match out {
            Out::Text(t) => {
                if !write_frame(&mut control, t.as_bytes()).await {
                    return;
                }
            }
            Out::Media(m) => {
                let slot = if m[0] == 2 { 1 } else { 0 };
                if media[slot].is_none() {
                    let Ok(opening) = conn.open_uni().await else { return };
                    let Ok(stream) = opening.await else { return };
                    media[slot] = Some(stream);
                }
                if !write_frame(media[slot].as_mut().unwrap(), &m).await {
                    return;
                }
            }
        }
    }
}
