# PostgreSQL

Up: [index](index.md). Related: [migrations](migrations.md), [caching](caching.md), [sqlite](sqlite.md) (same verbs).

Built in with `-Dpostgres` (on in the `web` and `full` profiles), on Anole's fork of pg.zig. Full docs: docs/database.md#postgresql. Example: examples/postgres/main.zig. Template: templates/rest-postgres.

## Setup

Use: `anole.App.postgres` (src/server.zig), `anole.pg.Client`, `anole.pg.Options` (src/pg/root.zig).

`app.postgres(.{})` reads `.url`, else `DATABASE_URL`, else libpq's `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`, else `postgres://postgres@127.0.0.1:5432/postgres`. Setup code: [index](index.md#the-handle-lives-in-the-state-struct).

Traps:
- Without an `sslmode`, a server on another host gets `verify-full`; one on this machine gets `prefer`. A self-signed or private-CA certificate (or a Docker Compose service name the certificate lacks) fails to connect: set `sslrootcert` (or `.tls.ca`), `sslmode=require`, or `sslmode=disable` on a trusted network. The log says which.
- With `.tls.ca` set in code, an `sslmode` that would not check the server is refused.

## Handlers

Use: `anole.pg.Client.all`, `.one`, `.optional`, `.exec`, `.iterate`, `.with` (src/pg/root.zig).

```zig
const Post = struct { id: i64, body: []const u8, likes: i32, created_at: anole.db.Time };

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

fn remove(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (try app.db.exec(req, "DELETE FROM posts WHERE id = $1", .{try postId(req)}) == 0) return error.NotFound;
    res.status = .no_content;
}
```

A single column reads into a plain type: `try app.db.one(i64, req, "SELECT count(*) FROM posts", .{})`.

Column types: integers (`int2`, `int4`, `int8`, `oid`), `f32`/`f64`, `bool`, `[]const u8` (text, `bytea`, `json`; `jsonb`, `uuid`, `numeric` as text), `anole.db.Time` (`timestamptz`, `timestamp` as UTC, `date`), enums (by label), slices (arrays), a struct or `std.json.Value` (`json`, `jsonb`), `?T` for NULL. Anything else: cast in the SQL (`::text`, `::int8`).

Traps:
- A `NULL` into a non-optional field is an error: make nullable columns `?T`.
- SQL built at run time that seldom repeats: `app.db.with(.{ .prepare = false })`. Behind PgBouncer older than 1.21 in transaction mode, set `statement_cache_size = 0` (docs/database.md:383).
- Long statements (a migration, a background job): `app.db.with(.{ .timeout = .max })`; every call is otherwise bounded by `Options.timeout` (30 s) and the request's deadline.

## Transactions

Use: `anole.pg.Client.transaction`, `anole.pg.Client.begin`, `anole.pg.Tx` (`exec`, `one`, `optional`, `all`, `iterate`, `with`, `commit`, `rollback`, `deinit`), `anole.db.TxOptions`, `anole.db.Isolation`.

Prefer `transaction`: it commits when the function returns, rolls back when it fails, and reruns it (up to `retries`) on a serialization failure or deadlock. From examples/postgres/main.zig:

```zig
fn like(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const post = try app.db.transaction(req, .{ .isolation = .serializable, .retries = 3 }, addLike, .{ req, try postId(req) });
    try res.json(post);
}

fn addLike(tx: *anole.pg.Tx, req: *anole.Request, id: i64) !Post {
    const post = try tx.one(Post, req, "UPDATE posts SET likes = likes + 1 WHERE id = $1 RETURNING id, body, likes, created_at", .{id});
    _ = try tx.exec(req, "INSERT INTO likes (post_id) VALUES ($1)", .{id});
    return post;
}
```

By hand:

```zig
var tx = try app.db.begin(req, .{ .isolation = .repeatable_read });
defer tx.deinit(); // rolls back unless committed
_ = try tx.exec(req, "...", .{});
try tx.commit(req);
```

Traps:
- Never send a bare `BEGIN` through `exec`: the next call may get another connection. A plain call that leaves a transaction open is rolled back and fails (docs/database.md:422). Use `begin` or `transaction`.
- Calls on a `Tx` are never cached or coalesced.

## Pooled connections and session state

Use: `anole.pg.Client.acquire`, `anole.pg.Conn` (`raw`, `release`), `anole.pg.Client.listener`, `anole.pg.Options.reset_session`.

`acquire(req)` hands over pg.zig's connection (`conn.raw`: `query`, `row`, `prepare`...) for what the verbs don't cover.

Traps:
- Release a connection from `acquire` once, and before the arena of the request or `Ctx` given to `acquire` is reset or freed: the checkout record lives there (docs/database.md:412, src/pg/root.zig `Conn.checkout`). A second `release` does nothing and is logged.
- A connection given back inside a transaction is rolled back and logged.
- Session state (`SET`, `SET ROLE`, temp tables, advisory locks, `LISTEN`) is reset before the next request gets the connection (`reset_session = .auto`). `.auto` judges from the SQL text, so a function whose body runs `SET ROLE` or `set_config(..., false)` leaks to the next request. Switching roles for row-level security: use `.always`, or `SET LOCAL ROLE` inside a transaction.
- `LISTEN`/`NOTIFY` feeds: use `app.watch` ([realtime](../realtime/index.md)) or `app.db.listener()`, not a pooled connection.

## Columns known only at run time

`with(opts).table(req, sql, params)` returns an `anole.db.Table` (column names, type OIDs, rows of `anole.db.Value`); `with(opts).execValues(req, sql, params)` returns an `anole.db.Changes`. `params` is a `[]const anole.db.Value`. This is what the C ABI and bindings use; typed structs are the normal path.

## Observability

`app.metrics`: `anole_db_query_duration_seconds`, `anole_db_errors_total{error}`, `anole_db_pool_acquire_duration_seconds`, `anole_db_pool_connections{state}`, `anole_db_pool_waiting`, labelled `system="postgresql"` and `db` (`Options.name`). `app.tracing`: a client span per call. `app.health`: `/readyz` fails while `SELECT 1` does not answer. See [observability](../observability.md).
