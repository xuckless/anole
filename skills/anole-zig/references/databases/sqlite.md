# SQLite

Up: [index](index.md). Related: [postgres](postgres.md) (same verbs), [migrations](migrations.md), [caching](caching.md).

Built in with `-Dsqlite` (on in the `web` and `full` profiles): SQLite compiled into the program, no server, one file. Full docs: docs/database.md#sqlite. Example: examples/sqlite/main.zig. Template: templates/full.

## Setup

Use: `anole.App.sqlite` (src/server.zig), `anole.sqlite.Client`, `anole.sqlite.Options`, `anole.sqlite.Client.execScript` (src/sqlite/root.zig).

`app.sqlite` takes a path (created when missing), `":memory:"`, or an `anole.sqlite.Options`. From examples/sqlite/main.zig:

```zig
pub const App = struct {
    db: *anole.sqlite.Client = undefined,
};

pub fn main(init: std.process.Init) !void {
    var state: App = .{};
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.db = try app.sqlite("todos.db");
    var setup_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer setup_arena.deinit();
    var setup: anole.db.Ctx = .{ .io = app.io(), .arena = setup_arena.allocator() };
    try state.db.execScript(&setup, schema);
    routes(&app);
    try app.listen(":3000");
}
```

With options (docs/database.md, SQLite Options; fields in src/sqlite/root.zig `Options`):

```zig
state.db = try app.sqlite(.{
    .path = "data/app.db",       // or "sqlite:data/app.db", ":memory:"
    .readers = 4,                // read-only connections; 0: everything on the writer
    .busy_timeout = .fromSeconds(5),
    .pragmas = &.{"PRAGMA cache_size = -20000"}, // run on every connection
});
```

Traps:
- The directory must exist: templates/full calls `std.Io.Dir.cwd().createDirPath(io, "data")` before `app.sqlite("data/app.db")`.
- A `file:` path is a SQLite URI and is refused unless `.uri = true` (the path often comes from the environment).
- `:memory:` is one database for the whole app, on the writer's connection: every executor sees the same tables. Handy in tests (templates/full/src/main_test.zig).

## Where the work runs

No statement runs on an executor. `app.sqlite` starts the blocking pool when `Options.blocking` did not (src/server.zig).

- Writes (`exec`, any statement that changes something, `INSERT ... RETURNING` through `one`, transactions) go to the writer thread, which owns the one read-write connection. Writers take turns, so they never get `SQLITE_BUSY` from each other.
- Reads (`SELECT`, `WITH`, `VALUES`, `PRAGMA`, `EXPLAIN`) run on the blocking pool over read-only connections. WAL mode: reads never wait for a write.
- A `SELECT` with side effects: `with(.{ .write = true })` sends it to the writer.

Each connection runs with `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`.

## Handlers

Use: `anole.sqlite.Client.all`, `.one`, `.optional`, `.exec`, `.iterate`, `.with`. Parameters are `?`. From examples/sqlite/main.zig (`todoId` reads `:id`, as `postId` in [postgres](postgres.md#handlers)):

```zig
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
```

Values: integers and `bool` are INTEGER, floats REAL, `[]const u8` TEXT, `anole.sqlite.Blob` BLOB, enums TEXT by name, `anole.db.Time` TEXT (`2026-10-21 09:30:00.25`, UTC; also reads `unixepoch()` integers and `julianday()` reals), optionals NULL, other structs and slices JSON text.

Errors: `CONSTRAINT_UNIQUE`/`PRIMARYKEY` is `Conflict` (409); `BUSY` past `busy_timeout`, `LOCKED` is `ServiceUnavailable` (503); a `with(.{ .timeout })` interrupt is `GatewayTimeout` (504); the rest `Database` (500).

## Transactions

Use: `anole.sqlite.Client.transaction`, `anole.sqlite.Client.begin`, `anole.sqlite.Tx`.

```zig
fn move(tx: *anole.sqlite.Tx, req: *anole.Request, from: i64, to: i64, amount: i64) !void {
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ amount, from });
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ amount, to });
}

try app.db.transaction(req, .{ .retries = 3 }, move, .{ req, from, to, amount });
```

Traps:
- A transaction holds the writer (`BEGIN IMMEDIATE`) until it ends: keep it short.
- Inside a transaction call through the `Tx`, never the `Client`. A write on the `Client` from the task that holds the transaction (or an open `iterate` or `acquire` on the writer) fails at once with `error.Database` ("this task already holds the writer"), since it could only wait for itself (docs/database.md:594, src/sqlite/root.zig:347).
- `begin(req, .{ .read_only = true })` is a snapshot on a reader.
- A `Tx` used after `commit` or `rollback` fails with `error.Database`.

## Driver calls

Use: `anole.sqlite.Client.acquire`, `anole.sqlite.Conn` (`run`, `release`), `anole.sqlite.c`.

`acquire(req)` holds the writer connection; `conn.run(func, args)` runs `func(driver_db, args...)` on the writer thread (user functions, blobs, backups).

Traps:
- Release it once, before the arena of the request or `Ctx` given to `acquire` is reset or freed: the checkout record lives there (docs/database.md:683). Call nothing on it after `release()`.
