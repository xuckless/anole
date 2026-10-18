# API spec

A small feed API (think a stripped-down Twitter). Five endpoints, JSON in and out. `test/test.sh`
checks everything on this page, and when the two disagree, the test suite wins.

## Runtime contract

Your server reads its config from these environment variables:

| Variable | Value on the benchmark box |
|---|---|
| `SQLITE_PATH` | path to a fresh copy of `seed/feed.db` (WAL mode, schema in `schema.sql`) |
| `JWT_SECRET` | `twelve-dollar-challenge` |
| `HOST`, `PORT` | `127.0.0.1`, `3000` behind Nginx; `0.0.0.0`, `80` if you serve directly |

Listen on `HOST:PORT` and speak HTTP/1.1 with keep-alive. Compression is optional.

- **Behind Nginx** (`bench/nginx.conf`): Nginx keeps up to 64 idle connections to you. Keep idle connections
  open for at least 65 s so Nginx never reuses a socket you just closed.
- **Direct**: every k6 user holds its own keep-alive connection, so expect up to ~15,000 open connections.
  Your service gets `LimitNOFILE=65535` and `CAP_NET_BIND_SERVICE` (it doesn't run as root).

## Responses

- Every body is **compact JSON**, `Content-Type: application/json` (`; charset=utf-8` is fine). A trailing newline is fine.
- **Key order is exactly as shown.**
- **Post object**: `{"id":<int>,"body":<string>,"created_at":<string>,"author":<string>,"like_count":<int>}`
  - `author` is the post author's `users.username`.
  - `like_count` is the number of rows in `likes` for that post, **as of this request**.
  - `created_at` is UTC with millisecond precision and a `Z` suffix: `2025-12-31T23:59:19.409Z`. It is stored in exactly
    this format, so send it as stored. New rows get `strftime('%Y-%m-%dT%H:%M:%fZ','now')` (the column default).
- Escaping `<>&/` or non-ASCII characters is optional. Load-test payloads are plain ASCII.

## Endpoints

| Request | Success | Body |
|---|---|---|
| `GET /health` | 200 | `{"status":"ok","db":"ok","uptime_s":<int>}` after a `SELECT 1` succeeds. If it fails: 503 `{"status":"degraded","db":"unreachable","error":<string>}` |
| `GET /feed` | 200 | `{"posts":[<post> × 20]}`: the 20 newest posts, `ORDER BY created_at DESC, id DESC` |
| `GET /posts/:id` | 200 | `{"post":<post>}` |
| `POST /posts` (auth) | 201 | `{"post":{"id":…,"body":<trimmed body>,"created_at":…,"author":<token username>,"like_count":0}}`. Request body: `{"body":"..."}` |
| `POST /posts/:id/like` (auth) | 201 first time, 200 on repeats | `{"liked":true,"already_liked":<bool>,"post_id":<int>}`. One like per (user, post) |

For reference, these are the queries the implementations in the video ran (one per request). You can write your own SQL.

```sql
-- post object (+ "ORDER BY p.created_at DESC, p.id DESC LIMIT 20" for the feed, or "WHERE p.id = ?")
SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at
INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING
```

## Errors

Every error body is `{"error":"<message>"}`.

| Condition | Status | Message |
|---|---|---|
| unknown path | 404 | `not found` |
| `:id` is not a positive integer (`0`, `-1`, `abc`, `1.5`) | 400 | `invalid post id` |
| the post doesn't exist (GET or like) | 404 | `post not found` |
| no `Authorization` header, or it doesn't start with `Bearer ` | 401 | `missing bearer token` |
| bad signature, expired, not HS256, or malformed JWT | 401 | `invalid or expired token` |
| valid JWT, but `sub` isn't a positive integer string or `username` isn't a string | 401 | `invalid token payload` |
| request body isn't valid JSON | 400 | `malformed JSON body` |
| `body` is missing, not a string, or empty after trimming whitespace | 400 | `body is required` |
| `body` is longer than 500 characters after trimming | 400 | `body must be at most 500 characters` |
| anything else | 500 | `internal server error` |

On authenticated routes, **check auth first, then the id**: `POST /posts/abc/like` without a token returns 401, and with a valid token it returns 400.

## Auth

`Authorization: Bearer <jwt>`, HS256 signed with `JWT_SECRET`, payload `{"sub":"<user id>","username":"<name>","iat":…,"exp":…}`.
Verify the signature and `exp`, and accept HS256 only. The user id is the integer in `sub`, and `username` is used as-is
(it isn't looked up). There is no login endpoint. `seed/make-seed.sh` writes pre-signed tokens for users 1–20,000 to
`seed/tokens.json`.

## Out of scope

These are not tested, so do whatever your framework does: bodies over 16 KB, ids beyond 2^53, hex or exponent ids,
wrong HTTP methods on known paths.
