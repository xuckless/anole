//! Bench server (bench/SPEC.md) on Axum: h1/h2c through `axum::serve`, TLS through
//! axum-server + rustls, HTTP/3 through h3 + h3-quinn, gRPC through tonic.
mod grpc;
mod http3;
mod routes;
mod twelve;
mod ws;

use std::{env, net::SocketAddr, process};

use axum_server::tls_rustls::RustlsConfig;

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Reads an environment variable, falling back to `default` when unset or unparsable.
pub fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn main() {
    let mode = env::var("MODE").unwrap_or_else(|_| "h1".into());
    if !matches!(mode.as_str(), "h1" | "h2c" | "tls" | "h3" | "grpc") {
        eprintln!("unsupported MODE {mode:?} (h1, h2c, tls, h3, grpc)");
        process::exit(3);
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(env_or("WORKERS", 1))
        .enable_all()
        .build()
        .expect("tokio runtime");
    let result = runtime.block_on(async {
        tokio::select! {
            res = run(&mode) => res,
            _ = shutdown_signal() => Ok(()),
        }
    });
    if let Err(err) = result {
        eprintln!("error: {err}");
        process::exit(1);
    }
}

async fn run(mode: &str) -> Result<(), BoxError> {
    let http = SocketAddr::from(([0, 0, 0, 0], env_or("HTTP_PORT", 8080)));
    let https = SocketAddr::from(([0, 0, 0, 0], env_or("HTTPS_PORT", 8443)));
    let cert = env::var("CERT_FILE").unwrap_or_else(|_| "/certs/cert.pem".into());
    let key = env::var("KEY_FILE").unwrap_or_else(|_| "/certs/key.pem".into());

    if mode == "grpc" {
        let addr = SocketAddr::from(([0, 0, 0, 0], env_or("GRPC_PORT", 50051)));
        return grpc::serve(addr).await;
    }

    let app = routes::app()?;
    match mode {
        // axum::serve speaks HTTP/1.1 and HTTP/2 prior knowledge on the same port.
        "h1" | "h2c" => {
            let listener = tokio::net::TcpListener::bind(http).await?;
            axum::serve(listener, app).await?;
        }
        // ALPN h2 + http/1.1 (axum-server sets both).
        "tls" => {
            let config = RustlsConfig::from_pem_file(cert, key).await?;
            let mut server = axum_server::bind_rustls(https, config);
            // WebSockets over HTTP/2 (RFC 8441), as axum::serve enables for h2c.
            server.http_builder().http2().enable_connect_protocol();
            server.serve(app.into_make_service()).await?;
        }
        "h3" => http3::serve(https, &cert, &key, app).await?,
        _ => unreachable!(),
    }
    Ok(())
}

async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}
