//! The plain HTTP routes: plaintext, JSON, params, echo, GC, static files, 404.
use std::{env, sync::OnceLock};

use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query},
    handler::HandlerWithoutStateExt,
    http::StatusCode,
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use tower_http::services::ServeDir;

use crate::{BoxError, env_or, twelve, ws};

pub fn app() -> Result<Router, BoxError> {
    build_retained(env_or("RETAIN", 0));
    let media = env::var("MEDIA_DIR").unwrap_or_else(|_| "/media".into());

    let mut app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json))
        .route("/users/{id}", get(user))
        .route("/list", get(list))
        .route("/echo", post(echo).layer(DefaultBodyLimit::max(8 * 1024 * 1024)))
        .route("/gc/alloc", get(gc_alloc))
        .route("/gc/stats", get(gc_stats))
        .nest_service(
            "/static",
            ServeDir::new(media).not_found_service(not_found.into_service()),
        )
        .merge(ws::routes())
        .fallback(not_found);
    if let Ok(url) = env::var("DATABASE_URL") {
        app = app.merge(twelve::routes(&url)?);
    }
    Ok(app)
}

async fn plaintext() -> &'static str {
    "Hello, World!"
}

#[derive(Serialize)]
struct Message {
    message: &'static str,
}

async fn json() -> Json<Message> {
    Json(Message { message: "Hello, World!" })
}

async fn user(Path(id): Path<String>) -> String {
    format!("user {id}")
}

#[derive(Serialize)]
struct Item {
    id: u32,
    name: String,
    active: bool,
    score: u32,
}

#[derive(Serialize)]
struct List {
    items: Vec<Item>,
}

async fn list() -> Json<List> {
    let items = (1..=50)
        .map(|i| Item { id: i, name: format!("item-{i}"), active: i % 2 == 0, score: i * 7 })
        .collect();
    Json(List { items })
}

/// `Bytes` responds as application/octet-stream.
async fn echo(body: Bytes) -> Bytes {
    body
}

#[derive(Deserialize)]
struct AllocParams {
    n: Option<usize>,
}

#[derive(Serialize)]
struct Node {
    id: usize,
    name: String,
    tags: Vec<String>,
    active: bool,
}

#[derive(Serialize)]
struct AllocResult {
    n: usize,
    bytes: usize,
}

async fn gc_alloc(Query(params): Query<AllocParams>) -> Json<AllocResult> {
    let n = params.n.unwrap_or(2000);
    let nodes: Vec<Node> = (0..n)
        .map(|i| Node {
            id: i,
            name: format!("node-{i}"),
            tags: vec![format!("a{}", i % 7), format!("b{}", i % 11), format!("c{}", i % 13)],
            active: i % 2 == 0,
        })
        .collect();
    let bytes = serde_json::to_string(&nodes).expect("serializable").len();
    Json(AllocResult { n, bytes })
}

/// Objects built at startup and kept for the life of the process.
#[allow(dead_code)]
struct Retained {
    id: usize,
    name: String,
    tags: Vec<String>,
}

static RETAINED: OnceLock<Vec<Retained>> = OnceLock::new();

fn build_retained(count: usize) {
    RETAINED.get_or_init(|| {
        (0..count)
            .map(|i| Retained {
                id: i,
                name: format!("retained-{i}"),
                tags: vec![format!("x{}", i % 7), format!("y{}", i % 11), format!("z{}", i % 13)],
            })
            .collect()
    });
}

#[derive(Serialize)]
struct Stats {
    retained: usize,
}

async fn gc_stats() -> Json<Stats> {
    Json(Stats { retained: RETAINED.get().map_or(0, Vec::len) })
}

#[derive(Serialize)]
pub struct ErrorBody {
    pub error: &'static str,
}

pub async fn not_found() -> (StatusCode, Json<ErrorBody>) {
    (StatusCode::NOT_FOUND, Json(ErrorBody { error: "not found" }))
}
