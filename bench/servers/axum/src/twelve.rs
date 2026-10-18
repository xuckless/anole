//! The $12 challenge routes (bench/twelve/SPEC.md) on Postgres: sqlx PgPool + jsonwebtoken.
use std::{sync::Arc, time::Instant};

use axum::{
    Json, Router,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode, header::AUTHORIZATION},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::{PgPool, postgres::PgPoolOptions};

use crate::{env_or, routes::ErrorBody};

const FEED_SQL: &str = "SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 ORDER BY p.created_at DESC, p.id DESC LIMIT 20";

const POST_SQL: &str = "SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 WHERE p.id = $1";

const INSERT_SQL: &str = "INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at";

const LIKE_SQL: &str = "WITH p AS (SELECT id FROM posts WHERE id = $2),
     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted";

struct Twelve {
    pool: PgPool,
    key: DecodingKey,
    validation: Validation,
    started: Instant,
}

pub fn routes(database_url: &str) -> Result<Router, sqlx::Error> {
    // One process shares one pool across all tokio workers, so it gets the whole PG_POOL.
    let pool = PgPoolOptions::new()
        .max_connections(env_or("PG_POOL", 20))
        .connect_lazy(database_url)?;
    let secret = std::env::var("JWT_SECRET").unwrap_or_else(|_| "twelve-dollar-challenge".into());
    let state = Arc::new(Twelve {
        pool,
        key: DecodingKey::from_secret(secret.as_bytes()),
        validation: Validation::new(Algorithm::HS256),
        started: Instant::now(),
    });
    Ok(Router::new()
        .route("/health", get(health))
        .route("/feed", get(feed))
        .route("/posts", post(create_post))
        .route("/posts/{id}", get(get_post))
        .route("/posts/{id}/like", post(like))
        .with_state(state))
}

struct ApiError(StatusCode, &'static str);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(ErrorBody { error: self.1 })).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(err: sqlx::Error) -> Self {
        eprintln!("database error: {err}");
        ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal server error")
    }
}

#[derive(Serialize)]
struct Post {
    id: i64,
    body: String,
    created_at: String,
    author: String,
    like_count: i64,
}

type PostRow = (i64, String, String, String, i64);

impl From<PostRow> for Post {
    fn from((id, body, created_at, author, like_count): PostRow) -> Self {
        Post { id, body, created_at, author, like_count }
    }
}

#[derive(Serialize)]
struct OnePost {
    post: Post,
}

#[derive(Serialize)]
struct Feed {
    posts: Vec<Post>,
}

#[derive(Serialize)]
struct Liked {
    liked: bool,
    already_liked: bool,
    post_id: i64,
}

#[derive(Serialize)]
struct Healthy {
    status: &'static str,
    db: &'static str,
    uptime_s: u64,
}

#[derive(Serialize)]
struct Degraded {
    status: &'static str,
    db: &'static str,
    error: String,
}

async fn health(State(s): State<Arc<Twelve>>) -> Response {
    match sqlx::query("SELECT 1").execute(&s.pool).await {
        Ok(_) => Json(Healthy { status: "ok", db: "ok", uptime_s: s.started.elapsed().as_secs() })
            .into_response(),
        Err(err) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(Degraded { status: "degraded", db: "unreachable", error: err.to_string() }),
        )
            .into_response(),
    }
}

async fn feed(State(s): State<Arc<Twelve>>) -> Result<Json<Feed>, ApiError> {
    let rows: Vec<PostRow> = sqlx::query_as(FEED_SQL).fetch_all(&s.pool).await?;
    Ok(Json(Feed { posts: rows.into_iter().map(Post::from).collect() }))
}

async fn get_post(
    State(s): State<Arc<Twelve>>,
    Path(id): Path<String>,
) -> Result<Json<OnePost>, ApiError> {
    let id = post_id(&id)?;
    let row: Option<PostRow> = sqlx::query_as(POST_SQL).bind(id).fetch_optional(&s.pool).await?;
    let row = row.ok_or(ApiError(StatusCode::NOT_FOUND, "post not found"))?;
    Ok(Json(OnePost { post: row.into() }))
}

async fn create_post(
    State(s): State<Arc<Twelve>>,
    headers: HeaderMap,
    body: Result<Json<Value>, JsonRejection>,
) -> Result<(StatusCode, Json<OnePost>), ApiError> {
    let (user_id, username) = authenticate(&s, &headers)?;
    let Json(body) = body.map_err(|_| ApiError(StatusCode::BAD_REQUEST, "malformed JSON body"))?;
    let text = body.get("body").and_then(Value::as_str).map(str::trim).unwrap_or_default();
    if text.is_empty() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "body is required"));
    }
    if text.chars().count() > 500 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "body must be at most 500 characters"));
    }
    let (id, created_at): (i64, String) =
        sqlx::query_as(INSERT_SQL).bind(user_id).bind(text).fetch_one(&s.pool).await?;
    let post = Post { id, body: text.to_owned(), created_at, author: username, like_count: 0 };
    Ok((StatusCode::CREATED, Json(OnePost { post })))
}

async fn like(
    State(s): State<Arc<Twelve>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<(StatusCode, Json<Liked>), ApiError> {
    let (user_id, _) = authenticate(&s, &headers)?;
    let post_id = post_id(&id)?;
    let (found, inserted): (i64, i64) =
        sqlx::query_as(LIKE_SQL).bind(user_id).bind(post_id).fetch_one(&s.pool).await?;
    if found == 0 {
        return Err(ApiError(StatusCode::NOT_FOUND, "post not found"));
    }
    let already_liked = inserted != 1;
    let status = if already_liked { StatusCode::OK } else { StatusCode::CREATED };
    Ok((status, Json(Liked { liked: true, already_liked, post_id })))
}

/// A positive integer written in plain digits.
fn positive_int(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok().filter(|&n| n > 0)
}

fn post_id(raw: &str) -> Result<i64, ApiError> {
    positive_int(raw).ok_or(ApiError(StatusCode::BAD_REQUEST, "invalid post id"))
}

#[derive(Deserialize)]
struct Claims {
    #[serde(default)]
    sub: Value,
    #[serde(default)]
    username: Value,
}

/// Verifies the bearer token (HS256 signature and `exp`) and returns (user id, username).
fn authenticate(s: &Twelve, headers: &HeaderMap) -> Result<(i64, String), ApiError> {
    let token = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(ApiError(StatusCode::UNAUTHORIZED, "missing bearer token"))?;
    let claims = jsonwebtoken::decode::<Claims>(token, &s.key, &s.validation)
        .map_err(|_| ApiError(StatusCode::UNAUTHORIZED, "invalid or expired token"))?
        .claims;
    match (claims.sub.as_str().and_then(positive_int), claims.username) {
        (Some(user_id), Value::String(username)) => Ok((user_id, username)),
        _ => Err(ApiError(StatusCode::UNAUTHORIZED, "invalid token payload")),
    }
}
