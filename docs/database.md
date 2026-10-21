# Databases

Anole's database connectors share one shape (`anole.db`): the database is
a handle in your App state, every call takes the request first, rows come
back as your structs in the request's arena (nothing to free), and a
database error becomes an HTTP status. The SQL stays yours: there is no
query builder.

| Call | Returns |
| --- | --- |
| `exec(req, sql, args)` | rows changed (`u64`) |
| `one(T, req, sql, args)` | the first row; none is `error.NotFound` (404) |
| `optional(T, req, sql, args)` | the first row, or null |
| `all(T, req, sql, args)` | every row (`[]T`) |
| `iterate(T, req, sql, args)` | rows one at a time: `next()`, then `deinit()` |
| `begin(req, opts)` | a transaction: the same calls, `commit()`, `rollback()`, `deinit()` |
| `transaction(req, opts, func, args)` | `func(&tx, args...)`, committed, retried after a serialization failure |
| `acquire(req)` | the driver's own connection, given back with `release()` |
| `with(.{ .timeout, .prepare })` | the same calls with options |

`args` is a tuple: `.{ id, name }`. Outside a handler (startup, a
background task) pass an `anole.db.Ctx` instead of the request:

```zig
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
_ = try app_state.db.exec(&c, "CREATE TABLE IF NOT EXISTS posts (...)", .{});
```

## PostgreSQL

Built in with `-Dpostgres` (on in the `web` and `full` profiles), on
Anole's fork of [pg.zig](https://github.com/karlseguin/pg.zig). TLS goes
through the same BoringSSL as the rest of Anole. `examples/postgres` is a
small posts API:

```sh
docker run --rm -d -p 5433:5432 -e POSTGRES_PASSWORD=pw postgres:17
DATABASE_URL=postgres://postgres:pw@127.0.0.1:5433/postgres zig build run-postgres
```

### Setup

```zig
const App = struct { db: *anole.pg.Db };

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.db = try app.postgres(.{}); // DATABASE_URL
    _ = app.metrics(.{}); // pool and query metrics
    _ = app.health(.{}); // /readyz pings the database
    app.get("/posts", list);
    try app.listen(":3000");
}
```

`app.postgres` reads the connection from `.url`, else `DATABASE_URL`, else
libpq's variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`,
`PGDATABASE`, `PGSSLMODE`...), else `postgres://postgres@127.0.0.1:5432/postgres`.
The variables also fill in whatever the URL leaves out. A URL it cannot
use stops the start with the reason logged (never the password). No
connection opens before a handler needs one, so the server starts while
the database is still coming up; `.connect_at_start = true` opens one per
executor first and refuses to start without the database.

The URL takes libpq's parameters:

| Parameter | |
| --- | --- |
| `sslmode` | `disable`, `allow`, `prefer` (the default), `require`, `verify-ca`, `verify-full` |
| `sslrootcert` | the CA file for `verify-ca`/`verify-full`; the system's store when unset (or `system`) |
| `sslcert`, `sslkey` | a client certificate |
| `sslnegotiation=direct` | TLS without the SSLRequest round trip (PostgreSQL 17+) |
| `application_name`, `options`, `connect_timeout` | as in libpq |
| `pool_max_conns` | connections in all (pgx's name) |
| anything else | a run-time parameter set at login: `?search_path=app&timezone=UTC` |

A host that is a directory is a Unix socket's:
`postgres://app@%2Fvar%2Frun%2Fpostgresql/app`.

`anole.pg.Options` has the rest: `max_connections` (twice the executors,
at least 4), `acquire_timeout` (5 s), `connect_timeout` (10 s),
`statement_cache_size` (256), `max_lifetime` (1 h), `idle_timeout`
(30 min), `errors`, `tls.ca` and `tls.client_certificate`, `name` (the
`db` label in metrics, `"postgres"`).

### Handlers

```zig
const Post = struct { id: i64, body: []const u8, author: []const u8, created_at: anole.db.Time };

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const limit = req.query.getInt(u32, "limit") orelse 20;
    try res.json(try app.db.all(Post, req,
        \\SELECT p.id, p.body, u.name AS author, p.created_at
        \\  FROM posts p JOIN users u ON u.id = p.user_id
        \\ ORDER BY p.created_at DESC LIMIT $1
    , .{limit}));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { body: []const u8 });
    const user_id = req.local(i64, "user_id") orelse return error.Unauthorized; // set by an auth middleware
    const id = try app.db.one(i64, req, "INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id", .{ user_id, in.body });
    res.status = .created;
    try res.json(.{ .id = id });
}
```

Rows go into a struct by column name (rename with `AS`); a struct field
the result lacks keeps its default, or the call fails with
`error.MissingColumn` naming it. A single column also reads into a plain
type: `try app.db.one(i64, req, "SELECT count(*) FROM posts", .{})`.

| Field type | Columns |
| --- | --- |
| any integer type | `int2`, `int4`, `int8`, `oid` (a value that does not fit is an error) |
| `f32`, `f64` | `float4`, `float8`, `numeric`, integers |
| `bool` | `bool` |
| `[]const u8` | text-like columns, `bytea`, `json`; `jsonb` as its JSON, `uuid` and `numeric` as their text |
| `anole.db.Time` | `timestamptz`, `timestamp` (as UTC), `date` |
| an enum | a PostgreSQL enum or text, by label |
| a slice | an array of any of the above |
| a struct, `std.json.Value` | `json`, `jsonb` |
| `?T` | `NULL` as null (a `NULL` into a non-optional field is an error) |

Other types: cast in the SQL (`::text`, `::int8`). Parameters take pg.zig's
types plus `anole.db.Time` (a timestamp). Strings in rows are copies in the
request's arena, so they outlive the call.

### Errors

A failed call returns one of `anole.db.Error`, which the server answers
with a status; what the database said stays in the log and in
`anole.db.lastError(req)` (SQLSTATE, message, constraint, table), never in
the response:

| SQLSTATE | Error | Status |
| --- | --- | --- |
| no row from `one` | `NotFound` | 404 |
| 23505 unique, 23P01 exclusion | `Conflict` | 409 |
| 40001 serialization, 40P01 deadlock (after `transaction`'s retries) | `Conflict` | 409 |
| no connection: refused, login failed, pool busy past `acquire_timeout`, class 08, 53300, 57P01-57P03 | `ServiceUnavailable` | 503 |
| 57014 (`statement_timeout`), a call past its `timeout` | `GatewayTimeout` | 504 |
| everything else: foreign key, not-null, check, syntax, permissions | `Database` | 500 |

`.errors` moves a class to another status, for an app that validates
input through its constraints:

```zig
state.db = try app.postgres(.{ .errors = .{ .foreign_key = .unprocessable_entity, .check = .unprocessable_entity } });
```

Or catch one case in the handler:

```zig
app.db.exec(req, "INSERT INTO users (email) VALUES ($1)", .{email}) catch |err| {
    if (err == error.Conflict) return res.fail(.conflict, "that email is taken");
    return err;
};
```

### Transactions

```zig
fn transfer(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { from: i64, to: i64, cents: i64 });
    try app.db.transaction(req, .{ .isolation = .serializable, .retries = 3 }, move, .{ req, in.from, in.to, in.cents });
    res.status = .no_content;
}

fn move(tx: *anole.pg.Tx, req: *anole.Request, from: i64, to: i64, cents: i64) !void {
    if (try tx.exec(req, "UPDATE accounts SET cents = cents - $1 WHERE id = $2 AND cents >= $1", .{ cents, from }) == 0)
        return error.UnprocessableEntity;
    _ = try tx.exec(req, "UPDATE accounts SET cents = cents + $1 WHERE id = $2", .{ cents, to });
}
```

`transaction` commits when the function returns, rolls back when it
fails, and runs it again (up to `retries` times) when PostgreSQL reports
a serialization failure or a deadlock. By hand:

```zig
var tx = try app.db.begin(req, .{ .isolation = .repeatable_read });
defer tx.deinit(); // rolls back unless committed
_ = try tx.exec(req, "...", .{});
try tx.commit();
```

### Pools, statements, timeouts

- **A pool per executor.** `max_connections` is split between the
  executors, and a handler only takes connections from its own
  executor's pool, so no lock is shared between threads. A busy executor
  does not borrow from an idle one; size the total for the busiest.
- **Prepared statements.** Each connection prepares a statement the
  first time it runs it and keeps it (`statement_cache_size`), so every
  later run is one round trip. For SQL built at run time that seldom
  repeats, `app.db.with(.{ .prepare = false })`. Behind PgBouncer older
  than 1.21 in transaction mode, set `statement_cache_size = 0`.
- **Deadlines.** A call waits as long as the request may. When the
  request's deadline passes or the client goes away (an HTTP/2 reset),
  the call is canceled, Anole sends PostgreSQL a CancelRequest so the
  statement stops on the server too, and the connection is replaced.
  `with(.{ .timeout = .fromSeconds(2) })` bounds one call (a 504 past
  it); `TxOptions.timeout` a whole transaction. The server's own
  `statement_timeout` (`?options=-c%20statement_timeout%3D5s`) is a 504
  as well.
- **Handlers that wait.** A database call suspends the handler's
  coroutine, never the thread. Don't mark such routes `anole.noWait`.
- **Raw access.** `app.db.acquire(req)` hands over pg.zig's connection
  (`conn.raw`: `query`, `row`, `prepare`...) for what the calls above do
  not cover; `conn.release()` gives it back. `app.db.listener()` opens a
  connection for `LISTEN`/`NOTIFY`.

### Observability

With `app.metrics`, the series below appear, labelled `system="postgresql"`
and `db` (`Options.name`); with `app.tracing`, every call in a traced
request is a client span (`db.system.name`, `db.namespace`,
`db.operation.name`); with `app.health`, `/readyz` fails while the
database does not answer `SELECT 1` (checked at most once a second). The
order of `app.postgres`, `app.metrics`, `app.tracing` and `app.health`
does not matter.

- `anole_db_query_duration_seconds` (histogram)
- `anole_db_errors_total{error}` (`Conflict`, `NotFound`, ...)
- `anole_db_pool_acquire_duration_seconds` (histogram)
- `anole_db_pool_connections{state="idle"|"in_use"}`
- `anole_db_pool_waiting`

### Testing against a server

`tests/postgres/run.sh` starts `postgres:17` in Docker (with a CA and
certificate made for the run) and runs `zig build test-postgres` twice:
in plain text and with `sslmode=verify-full`, logging in with
scram-sha-256. Against a server of your own:

```sh
zig build test-postgres -Dpostgres-test-url='postgres://postgres:pw@127.0.0.1:5433/postgres'
```
