//! A posts API on PostgreSQL: rows into structs, a transaction, errors as
//! statuses, and the database in /readyz and /metrics.
//!
//!   docker run --rm -d --name posts-db -p 5433:5432 -e POSTGRES_PASSWORD=pw postgres:17
//!   DATABASE_URL=postgres://postgres:pw@127.0.0.1:5433/postgres zig build run-postgres
//!
//!   curl -d '{"body":"hello"}' localhost:3000/posts
//!   curl 'localhost:3000/posts?limit=10'
//!   curl localhost:3000/posts/1               # none: 404
//!   curl -X POST localhost:3000/posts/1/like
//!   curl -X DELETE localhost:3000/posts/1
//!   curl localhost:3000/readyz
//!   curl localhost:3000/metrics
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const App = struct { db: *anole.pg.Client };

const Post = struct { id: i64, body: []const u8, likes: i32, created_at: anole.db.Time };
const NewPost = struct { body: []const u8 };

const schema =
    \\CREATE TABLE IF NOT EXISTS posts (
    \\  id bigserial PRIMARY KEY,
    \\  body text NOT NULL CHECK (body <> ''),
    \\  likes int NOT NULL DEFAULT 0,
    \\  created_at timestamptz NOT NULL DEFAULT now()
    \\);
    \\CREATE TABLE IF NOT EXISTS likes (
    \\  post_id bigint NOT NULL REFERENCES posts (id) ON DELETE CASCADE,
    \\  at timestamptz NOT NULL DEFAULT now()
    \\);
;

fn postId(req: *anole.Request) !i64 {
    return req.params.getInt(i64, "id") orelse error.NotFound;
}

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const limit = req.query.getInt(u32, "limit") orelse 20;
    try res.json(try app.db.all(Post, req, "SELECT id, body, likes, created_at FROM posts ORDER BY id DESC LIMIT $1", .{limit}));
}

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // No row: error.NotFound, a 404.
    try res.json(try app.db.one(Post, req, "SELECT id, body, likes, created_at FROM posts WHERE id = $1", .{try postId(req)}));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewPost); // no body, or not a NewPost: 400
    if (in.body.len == 0) return error.UnprocessableEntity;
    const post = try app.db.one(Post, req, "INSERT INTO posts (body) VALUES ($1) RETURNING id, body, likes, created_at", .{in.body});
    res.status = .created;
    try res.json(post);
}

/// Two statements that stand or fall together; run again if a concurrent
/// like wins a serialization race.
fn like(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const post = try app.db.transaction(req, .{ .isolation = .serializable, .retries = 3 }, addLike, .{ req, try postId(req) });
    try res.json(post);
}

fn addLike(tx: *anole.pg.Tx, req: *anole.Request, id: i64) !Post {
    // No such post: error.NotFound, and nothing is kept.
    const post = try tx.one(Post, req, "UPDATE posts SET likes = likes + 1 WHERE id = $1 RETURNING id, body, likes, created_at", .{id});
    _ = try tx.exec(req, "INSERT INTO likes (post_id) VALUES ($1)", .{id});
    return post;
}

fn remove(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (try app.db.exec(req, "DELETE FROM posts WHERE id = $1", .{try postId(req)}) == 0) return error.NotFound;
    res.status = .no_content;
}

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    // Error answers as {"error":"..."}; the database's detail stays in the log.
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    // DATABASE_URL, else the PG* variables, else postgres@127.0.0.1:5432.
    state.db = try app.postgres(.{});
    _ = app.metrics(.{}); // the database's pools and query times too
    _ = app.health(.{}); // /readyz pings the database
    app.use(anole.observe.AccessLog.init(.{}));

    // Outside a request, calls take an anole.db.Ctx.
    {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
        _ = try state.db.exec(&c, schema, .{});
    }

    app.get("/posts", list);
    app.get("/posts/:id", get);
    app.post("/posts", create);
    app.post("/posts/:id/like", like);
    app.delete("/posts/:id", remove);

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    try app.listen(args.next() orelse ":3000");
}
