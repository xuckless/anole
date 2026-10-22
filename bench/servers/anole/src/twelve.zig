//! The $12 server challenge's API (bench/twelve/SPEC.md) on Postgres, with
//! the statements bench/SPEC.md fixes for every framework.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;

const sql_health = "SELECT 1";
const sql_feed =
    \\SELECT p.id, p.body, p.created_at, u.username,
    \\       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    \\  FROM posts p JOIN users u ON u.id = p.user_id
    \\ ORDER BY p.created_at DESC, p.id DESC LIMIT 20
;
const sql_post =
    \\SELECT p.id, p.body, p.created_at, u.username,
    \\       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    \\  FROM posts p JOIN users u ON u.id = p.user_id
    \\ WHERE p.id = $1
;
const sql_create = "INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at";
const sql_like =
    \\WITH p AS (SELECT id FROM posts WHERE id = $2),
    \\     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
    \\             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
    \\SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted
;

pub const State = struct {
    db: *anole.pg.Client,
    keys: [1]anole.auth.Key,
    started: i64,

    /// Anole's own Postgres client (`app.postgres`): `pool_total`
    /// connections split between the executors, statements prepared per
    /// connection on first use.
    pub fn init(app: *anole.Server(App), url: []const u8, pool_total: u32, secret: []const u8) !State {
        return .{
            .db = try app.postgres(.{ .url = url, .max_connections = pool_total }),
            .keys = .{.{ .alg = .HS256, .material = .{ .hmac = secret } }},
            .started = std.Io.Clock.real.now(app.io()).toSeconds(),
        };
    }
};

pub fn routes(app: *anole.Server(App)) void {
    app.get("/health", health);
    app.get("/feed", feed);
    app.get("/posts/:id", getPost);
    app.post("/posts", createPost);
    app.post("/posts/:id/like", like);
}

const Post = struct { id: i64, body: []const u8, created_at: []const u8, author: []const u8, like_count: i64 };

fn fail(res: *anole.Response, status: anole.http.Status, message: []const u8) !void {
    res.status = status;
    try res.json(.{ .@"error" = message });
}

/// A row of the feed and post queries.
const Row = struct { id: i64, body: []const u8, created_at: []const u8, username: []const u8, like_count: i64 };

fn toPost(row: Row) Post {
    return .{ .id = row.id, .body = row.body, .created_at = row.created_at, .author = row.username, .like_count = row.like_count };
}

/// A positive integer id, or null (`0`, `-1`, `abc`, `1.5`).
fn postId(req: *anole.Request) ?i64 {
    const raw = req.params.get("id") orelse return null;
    const id = std.fmt.parseInt(u63, raw, 10) catch return null;
    if (id == 0 or raw[0] == '+') return null;
    return id;
}

const Claims = struct { user_id: i64, username: []const u8 };

/// Verifies the bearer token, answering 401 itself when it does not.
fn auth(app: *App, req: *anole.Request, res: *anole.Response) !?Claims {
    const header = req.headers.get("Authorization") orelse "";
    if (!std.mem.startsWith(u8, header, "Bearer ")) {
        try fail(res, .unauthorized, "missing bearer token");
        return null;
    }
    const now = std.Io.Clock.real.now(req.io).toSeconds();
    const v = anole.auth.verify(req.arena, header["Bearer ".len..], &app.twelve.?.keys, .{ .leeway_seconds = 0 }, now) catch {
        try fail(res, .unauthorized, "invalid or expired token");
        return null;
    };
    const sub = v.string("sub");
    const name = v.string("username");
    const id: i64 = if (sub) |s| std.fmt.parseInt(u63, s, 10) catch 0 else 0;
    if (id <= 0 or name == null) {
        try fail(res, .unauthorized, "invalid token payload");
        return null;
    }
    return .{ .user_id = id, .username = name.? };
}

fn health(app: *App, req: *anole.Request, res: *anole.Response) !void {
    _ = app.twelve.?.db.one(i32, req, sql_health, .{}) catch |e| {
        res.status = .service_unavailable;
        return res.json(.{ .status = "degraded", .db = "unreachable", .@"error" = @errorName(e) });
    };
    const uptime = std.Io.Clock.real.now(req.io).toSeconds() - app.twelve.?.started;
    try res.json(.{ .status = "ok", .db = "ok", .uptime_s = uptime });
}

fn feed(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const rows = try app.twelve.?.db.all(Row, req, sql_feed, .{});
    const posts = try res.arena.alloc(Post, rows.len);
    for (posts, rows) |*p, row| p.* = toPost(row);
    try res.json(.{ .posts = posts });
}

fn getPost(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = postId(req) orelse return fail(res, .bad_request, "invalid post id");
    const rows = try app.twelve.?.db.all(Row, req, sql_post, .{id});
    if (rows.len == 0) return fail(res, .not_found, "post not found");
    try res.json(.{ .post = toPost(rows[0]) });
}

const whitespace = " \t\n\r\x0b\x0c";

fn createPost(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth(app, req, res) orelse return;
    const raw = try req.body() orelse "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{}) catch
        return fail(res, .bad_request, "malformed JSON body");
    const field = if (parsed == .object) parsed.object.get("body") else null;
    const text = if (field) |f| (if (f == .string) std.mem.trim(u8, f.string, whitespace) else "") else "";
    if (text.len == 0) return fail(res, .bad_request, "body is required");
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (chars > 500) return fail(res, .bad_request, "body must be at most 500 characters");

    const created = try app.twelve.?.db.one(struct { id: i64, created_at: []const u8 }, req, sql_create, .{ who.user_id, text });
    res.status = .created;
    try res.json(.{ .post = Post{
        .id = created.id,
        .body = text,
        .created_at = created.created_at,
        .author = who.username,
        .like_count = 0,
    } });
}

fn like(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth(app, req, res) orelse return;
    const id = postId(req) orelse return fail(res, .bad_request, "invalid post id");
    const r = try app.twelve.?.db.one(struct { found: i64, inserted: i64 }, req, sql_like, .{ who.user_id, id });
    if (r.found == 0) return fail(res, .not_found, "post not found");
    const inserted = r.inserted == 1;
    res.status = if (inserted) .created else .ok;
    try res.json(.{ .liked = true, .already_liked = !inserted, .post_id = id });
}
