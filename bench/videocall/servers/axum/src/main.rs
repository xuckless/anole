//! 1:1 video-call relay (bench/videocall/SPEC.md) on axum: the HTTP API and
//! WebSockets over TLS on TCP PORT (axum-server + rustls), WebTransport on
//! UDP PORT (wtransport), one process, tokio's default runtime.

mod state;
mod ws;
mod wt;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum_server::tls_rustls::RustlsConfig;
use serde::Serialize;

use state::{App, HistoryError};

type Shared = Arc<App>;

#[derive(Serialize)]
struct ErrorBody {
    error: &'static str,
}

fn json_response(status: StatusCode, body: impl Into<axum::body::Body>) -> Response {
    (status, [(header::CONTENT_TYPE, "application/json")], body.into()).into_response()
}

pub fn error_response(status: StatusCode, error: &'static str) -> Response {
    json_response(status, serde_json::to_string(&ErrorBody { error }).unwrap())
}

#[tokio::main]
async fn main() {
    // axum-server enables rustls' aws-lc-rs provider and wtransport its ring
    // one; with both compiled in, rustls needs a process default.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let port: u16 = std::env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8443);
    let cert = std::env::var("CERT").unwrap_or_else(|_| "/certs/cert.pem".into());
    let key = std::env::var("KEY").unwrap_or_else(|_| "/certs/key.pem".into());
    let addr = SocketAddr::from(([0, 0, 0, 0], port));

    let app = Arc::new(App::default());
    let router = Router::new()
        .route("/health", get(health))
        .route("/api/users", post(create_user))
        .route("/api/calls/{id}/messages", get(messages))
        .route("/ws", get(ws::handler))
        .with_state(app.clone());

    let tls = RustlsConfig::from_pem_file(&cert, &key).await.expect("certificate");
    let wt = tokio::spawn(wt::serve(addr, cert, key, app));
    let https = axum_server::bind_rustls(addr, tls).serve(router.into_make_service());
    tokio::select! {
        res = https => res.expect("https server"),
        res = wt => res.expect("webtransport server"),
    }
}

async fn health() -> Response {
    json_response(StatusCode::OK, r#"{"status":"ok"}"#)
}

#[derive(Serialize)]
struct Created<'a> {
    id: u64,
    name: &'a str,
    token: &'a str,
}

async fn create_user(State(app): State<Shared>, body: Bytes) -> Response {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return error_response(StatusCode::BAD_REQUEST, "malformed JSON body");
    };
    let name = match value.get("name") {
        Some(serde_json::Value::String(n))
            if (1..=32).contains(&n.len())
                && n.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') =>
        {
            n.clone()
        }
        _ => return error_response(StatusCode::BAD_REQUEST, "invalid name"),
    };
    let (id, token) = app.create_user(name.clone());
    let body = serde_json::to_string(&Created { id, name: &name, token: &token }).unwrap();
    json_response(StatusCode::CREATED, body)
}

pub fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers.get(header::AUTHORIZATION)?.to_str().ok()?.strip_prefix("Bearer ")
}

async fn messages(
    State(app): State<Shared>,
    Path(params): Path<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let Some(user) = bearer(&headers).and_then(|t| app.user_for_token(t)) else {
        return error_response(StatusCode::UNAUTHORIZED, "unauthorized");
    };
    let call_id = params.get("id").and_then(|id| id.parse::<u64>().ok());
    match app.history(user, call_id) {
        Ok(body) => json_response(StatusCode::OK, body),
        Err(HistoryError::NotFound) => error_response(StatusCode::NOT_FOUND, "call not found"),
        Err(HistoryError::Forbidden) => error_response(StatusCode::FORBIDDEN, "forbidden"),
    }
}
