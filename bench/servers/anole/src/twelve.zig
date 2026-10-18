//! The $12 server challenge's API (bench/twelve/SPEC.md) on Postgres, with
//! the statements bench/SPEC.md fixes for every framework.
const std = @import("std");
const anole = @import("anole");
const pg = @import("pg.zig");
const App = @import("main.zig").App;

const statements: pg.Statements = &.{
    "SELECT 1",
    \\SELECT p.id, p.body, p.created_at, u.username,
    \\       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    \\  FROM posts p JOIN users u ON u.id = p.user_id
    \\ ORDER BY p.created_at DESC, p.id DESC LIMIT 20
    ,
    \\SELECT p.id, p.body, p.created_at, u.username,
    \\       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    \\  FROM posts p JOIN users u ON u.id = p.user_id
    \\ WHERE p.id = $1
    ,
    "INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at",
    \\WITH p AS (SELECT id FROM posts WHERE id = $2),
    \\     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
    \\             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
    \\SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted
    ,
};
const q_health = 0;
const q_feed = 1;
const q_post = 2;
const q_create = 3;
const q_like = 4;

pub const State = struct {
    pools: pg.Pools,
    keys: [1]anole.auth.Key,
    started: i64,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, url: []const u8, pool_total: u32, workers: u16, secret: []const u8) !State {
        return .{
            .pools = .{ .gpa = gpa, .cfg = try .parseUrl(url), .per_pool = std.math.divCeil(u32, pool_total, workers) catch 1 },
            .keys = .{.{ .alg = .HS256, .material = .{ .hmac = secret } }},
            .started = std.Io.Clock.real.now(io).toSeconds(),
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

/// Runs one statement on a connection from this executor's pool.
fn run(app: *App, req: *anole.Request, index: u6, params: []const ?[]const u8) !pg.Result {
    const pool = try app.twelve.?.pools.get();
    const conn = try pool.acquire(req.io);
    defer pool.release(req.io, conn);
    const result = try conn.query(req.arena, statements, index, params);
    if (result.err) |msg| {
        std.log.err("postgres: {s}", .{msg});
        return error.InternalServerError;
    }
    return result;
}

fn toPost(row: pg.Row) !Post {
    return .{
        .id = try std.fmt.parseInt(i64, row[0].?, 10),
        .body = row[1].?,
        .created_at = row[2].?,
        .author = row[3].?,
        .like_count = try std.fmt.parseInt(i64, row[4].?, 10),
    };
}

/// A positive integer id, or null (`0`, `-1`, `abc`, `1.5`).
fn postId(req: *anole.Request) ?[]const u8 {
    const raw = req.params.get("id") orelse return null;
    const id = std.fmt.parseInt(u63, raw, 10) catch return null;
    if (id == 0 or raw[0] == '+') return null;
    return raw;
}

const Claims = struct { user_id: []const u8, username: []const u8 };

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
    const id_ok = if (sub) |s| (std.fmt.parseInt(u63, s, 10) catch 0) > 0 else false;
    if (!id_ok or name == null) {
        try fail(res, .unauthorized, "invalid token payload");
        return null;
    }
    return .{ .user_id = sub.?, .username = name.? };
}

fn health(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const pool = try app.twelve.?.pools.get();
    const ok = blk: {
        const conn = pool.acquire(req.io) catch |e| break :blk e;
        defer pool.release(req.io, conn);
        const r = conn.query(req.arena, statements, q_health, &.{}) catch |e| break :blk e;
        if (r.err != null) break :blk error.ServerError;
    };
    _ = ok catch |e| {
        res.status = .service_unavailable;
        return res.json(.{ .status = "degraded", .db = "unreachable", .@"error" = @errorName(e) });
    };
    const uptime = std.Io.Clock.real.now(req.io).toSeconds() - app.twelve.?.started;
    try res.json(.{ .status = "ok", .db = "ok", .uptime_s = uptime });
}

fn feed(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const r = try run(app, req, q_feed, &.{});
    const posts = try res.arena.alloc(Post, r.rows.len);
    for (posts, r.rows) |*p, row| p.* = try toPost(row);
    try res.json(.{ .posts = posts });
}

fn getPost(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = postId(req) orelse return fail(res, .bad_request, "invalid post id");
    const r = try run(app, req, q_post, &.{id});
    if (r.rows.len == 0) return fail(res, .not_found, "post not found");
    try res.json(.{ .post = try toPost(r.rows[0]) });
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

    const r = try run(app, req, q_create, &.{ who.user_id, text });
    res.status = .created;
    try res.json(.{ .post = Post{
        .id = try std.fmt.parseInt(i64, r.rows[0][0].?, 10),
        .body = text,
        .created_at = r.rows[0][1].?,
        .author = who.username,
        .like_count = 0,
    } });
}

fn like(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth(app, req, res) orelse return;
    const id = postId(req) orelse return fail(res, .bad_request, "invalid post id");
    const r = try run(app, req, q_like, &.{ who.user_id, id });
    if (std.mem.eql(u8, r.rows[0][0].?, "0")) return fail(res, .not_found, "post not found");
    const inserted = std.mem.eql(u8, r.rows[0][1].?, "1");
    res.status = if (inserted) .created else .ok;
    try res.json(.{ .liked = true, .already_liked = !inserted, .post_id = try std.fmt.parseInt(i64, id, 10) });
}
