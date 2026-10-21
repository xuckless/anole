//! A to-do API on SQLite: one file, created on the first run, nothing to
//! install and no database server to run.
//!
//!   zig build run-sqlite                        # todos.db, every interface, port 3000
//!   zig build run-sqlite -- :memory: 127.0.0.1:4000
//!
//!   curl -d '{"title":"Buy milk"}' localhost:3000/todos
//!   curl 'localhost:3000/todos?limit=10'
//!   curl localhost:3000/todos/1
//!   curl -X POST localhost:3000/todos/1/done
//!   curl -X DELETE localhost:3000/todos/1
//!
//! tests/sqlite_example_test.zig serves the same routes and checks each one.
const std = @import("std");
const anole = @import("anole");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;

pub const App = struct {
    db: *anole.sqlite.Client = undefined,
};

const Todo = struct { id: i64, title: []const u8, done: bool, created_at: anole.db.Time };
const NewTodo = struct { title: []const u8 };

pub const schema =
    \\CREATE TABLE IF NOT EXISTS todos (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL UNIQUE CHECK (length(title) > 0),
    \\    done INTEGER NOT NULL DEFAULT 0,
    \\    created_at TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
    \\);
;

fn todoId(req: *anole.Request) !i64 {
    return req.params.getInt(i64, "id") orelse error.NotFound;
}

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const limit = req.query.getInt(u32, "limit") orelse 50;
    // Reads run on the database's reader threads: the coroutine waits,
    // the executor serves other requests meanwhile.
    try res.json(try app.db.all(Todo, req, "SELECT * FROM todos ORDER BY id LIMIT ?", .{limit}));
}

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // No such row: error.NotFound, a 404.
    try res.json(try app.db.one(Todo, req, "SELECT * FROM todos WHERE id = ?", .{try todoId(req)}));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(NewTodo); // no body, or not a NewTodo: 400
    // On the writer thread. The same title twice breaks UNIQUE:
    // error.Conflict, a 409.
    const todo = try app.db.one(Todo, req, "INSERT INTO todos (title) VALUES (?) RETURNING *", .{in.title});
    res.status = .created;
    try res.json(todo);
}

fn done(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (try app.db.exec(req, "UPDATE todos SET done = 1 WHERE id = ?", .{try todoId(req)}) == 0) return error.NotFound;
    res.status = .no_content;
}

fn remove(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (try app.db.exec(req, "DELETE FROM todos WHERE id = ?", .{try todoId(req)}) == 0) return error.NotFound;
    res.status = .no_content;
}

/// Apart from `main` so that tests/sqlite_example_test.zig can serve the
/// same routes.
pub fn routes(app: *anole.Server(App)) void {
    app.get("/todos", list);
    app.get("/todos/:id", get);
    app.post("/todos", create);
    app.post("/todos/:id/done", done);
    app.delete("/todos/:id", remove);
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    const path = args.next() orelse "todos.db";
    const address = args.next() orelse ":3000";

    var state: App = .{};
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    app.use(anole.observe.AccessLog.init(.{}));
    state.db = try app.sqlite(path);
    try state.db.execScript(schema);
    routes(&app);
    try app.listen(address);
}
