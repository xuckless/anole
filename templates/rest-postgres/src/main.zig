//! {{name}}: a todo API on PostgreSQL.
//!
//!   docker compose up -d     # Postgres, with db/schema.sql applied
//!   zig build run            # http://localhost:3000, API docs at /docs
//!   zig build test           # the tests; the database ones need DATABASE_URL
//!   zig build openapi        # writes openapi.json (needs no database)
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const v = anole.validate;

/// The db/schema.sql the tests apply to their database.
pub const schema = @embedFile("schema_sql");

/// Your settings: from the defaults below, the environment and `.env`
/// (development). `DATABASE_URL` is also read by `app.postgres` itself.
const Config = struct {
    port: u16 = 3000,
    database_url: ?anole.Secret = null,
};

/// The state every handler gets first.
pub const Ctx = struct { db: *anole.pg.Client };

pub const Todo = struct { id: i64, title: []const u8, done: bool };

pub const NewTodo = struct {
    title: []const u8,
    done: bool = false,

    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
    };
};

const columns = "id, title, done";

fn list(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .query = struct { limit: u32 = 50 } })) ![]const Todo {
    return ctx.db.all(Todo, req, "SELECT " ++ columns ++ " FROM todos ORDER BY id LIMIT $1", .{in.query.limit});
}

// No row is error.NotFound, a 404; a duplicate title is a unique violation,
// a 409. Anole's database layer maps both.

fn get(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .path = struct { id: i64 } })) !Todo {
    return ctx.db.one(Todo, req, "SELECT " ++ columns ++ " FROM todos WHERE id = $1", .{in.path.id});
}

fn create(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .body = NewTodo })) !anole.Created(Todo) {
    const todo = try ctx.db.one(Todo, req, "INSERT INTO todos (title, done) VALUES ($1, $2) RETURNING " ++ columns, .{ in.body.title, in.body.done });
    return .{ .value = todo, .location = try std.fmt.allocPrint(req.arena, "/todos/{d}", .{todo.id}) };
}

fn update(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .path = struct { id: i64 }, .body = NewTodo })) !Todo {
    return ctx.db.one(Todo, req, "UPDATE todos SET title = $2, done = $3 WHERE id = $1 RETURNING " ++ columns, .{ in.path.id, in.body.title, in.body.done });
}

fn remove(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .path = struct { id: i64 } })) !void {
    if (try ctx.db.exec(req, "DELETE FROM todos WHERE id = $1", .{in.path.id}) == 0) return error.NotFound;
}

/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.Server(Ctx)) void {
    app.get("/todos", list);
    app.get("/todos/:id", get);
    app.post("/todos", create);
    app.put("/todos/:id", update);
    app.delete("/todos/:id", remove);
}

pub fn main(init: std.process.Init) !void {
    const cfg = try anole.config.load(Config, init, .{});

    var ctx: Ctx = undefined;
    var app = try anole.Server(Ctx).init(init.gpa, .{}, &ctx);
    defer app.deinit();
    // Connections are made when first needed, so the server starts (and
    // `zig build openapi` runs) without a database.
    ctx.db = try app.postgres(.{ .url = if (cfg.database_url) |u| u.expose() else null });

    app.use(anole.middleware.RequestId.init(.{})); // X-Request-Id
    app.use(anole.observe.AccessLog.init(.{})); // a line per request
    app.use(anole.middleware.Cors.init(.{})); // any origin; narrow it for production
    _ = app.health(.{}); // /readyz pings the database
    app.openapi(.{ .info = .{ .title = "{{name}}", .version = "0.1.0" } });
    routes(&app);

    var addr: [16]u8 = undefined;
    try app.listen(try std.fmt.bufPrint(&addr, ":{d}", .{cfg.port}));
}
