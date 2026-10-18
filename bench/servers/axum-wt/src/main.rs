//! The Rust WebTransport bench server: /wt/echo (bench/SPEC.md,
//! "WebTransport") on wtransport, which speaks draft-02, the version
//! Chrome, Edge and Firefox use.
//!
//! MODE=h3: WebTransport on UDP HTTPS_PORT (default 8443).
//!
//! wtransport owns its QUIC endpoint and answers only extended CONNECTs, so
//! the axum Router can't share the port and there is no /plaintext over h3:
//! any other request is refused (STOP_SENDING H3_REQUEST_REJECTED) by the
//! library before the application sees it.

use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use wtransport::endpoint::IncomingSession;
use wtransport::{Endpoint, Identity, ServerConfig};

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v.parse().unwrap_or_else(|_| panic!("{key}: {v:?}")),
        _ => default,
    }
}

fn main() {
    let mode = std::env::var("MODE").unwrap_or_else(|_| "h1".into());
    if mode != "h3" {
        eprintln!("unsupported MODE {mode:?}: this server only does h3 (WebTransport)");
        std::process::exit(3);
    }
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(env_or("WORKERS", 1))
        .enable_all()
        .build()
        .expect("tokio runtime")
        .block_on(serve());
}

async fn serve() {
    let identity = Identity::load_pemfiles(
        env_or("CERT_FILE", "/certs/cert.pem".to_string()),
        env_or("KEY_FILE", "/certs/key.pem".to_string()),
    )
    .await
    .expect("certificate");
    let config = ServerConfig::builder()
        .with_bind_address(SocketAddr::from((Ipv4Addr::UNSPECIFIED, env_or("HTTPS_PORT", 8443u16))))
        .with_identity(identity)
        // quinn's default idle timeout is 30 s; the spec wants 75 s or more.
        .max_idle_timeout(Some(Duration::from_secs(120)))
        .expect("idle timeout")
        .build();
    let server = Endpoint::server(config).expect("endpoint");
    loop {
        let incoming = server.accept().await;
        tokio::spawn(session(incoming));
    }
}

async fn session(incoming: IncomingSession) {
    let Ok(request) = incoming.await else { return };
    if request.path() != "/wt/echo" {
        request.not_found().await;
        return;
    }
    let Ok(conn) = request.accept().await else { return };
    loop {
        tokio::select! {
            stream = conn.accept_bi() => {
                let Ok((mut send, mut recv)) = stream else { return };
                // Every byte back; the send side ends when the client's does.
                tokio::spawn(async move {
                    if tokio::io::copy(&mut recv, &mut send).await.is_ok() {
                        let _ = send.finish().await;
                    }
                });
            }
            dgram = conn.receive_datagram() => {
                let Ok(dgram) = dgram else { return };
                let _ = conn.send_datagram(dgram.payload());
            }
        }
    }
}
