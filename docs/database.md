# Databases

Anole's database connectors share one shape (`anole.db`): the database is
a handle in your App state (each connector's `Client`), every call takes
the request first, rows come back as your structs in the request's arena
(nothing to free), and a database error becomes an HTTP status (each
connector's `Error` is `anole.db.Error` plus a cancel and memory). The
SQL stays yours: there is no query builder.

Each connector is a build flag, downloaded and compiled only when it is on:

| Connector | Flag | Profiles | Handle |
| --- | --- | --- | --- |
| [PostgreSQL](#postgresql) | `-Dpostgres` | `web`, `full` | `anole.pg.Client`, from `app.postgres(.{})` |
| [SQLite](#sqlite) | `-Dsqlite` | `web`, `full` | `anole.sqlite.Client`, from `app.sqlite("app.db")` |
| [MongoDB](#mongodb) | `-Dmongodb` | `full` | `anole.mongodb.Client`, from `app.mongodb(.{})` |
| [Redis and Valkey](#redis-and-valkey) | `-Dredis` | `full` | `anole.redis.Client`, from `app.redis(.{})` |

A flag overrides the profile: `-Dprofile=web -Dmongodb=true` adds MongoDB,
`-Dpostgres=false` drops PostgreSQL. Calling `app.mongodb` (or another
connector's) in a build without it is a compile error that names the flag.
Choose them where you add the dependency, as for the other
[build flags](server.md#build-flags).

### Failing fast and retrying

After 5 connection failures in a row (or half of 20 calls in 10 s) a network connector's breaker opens: calls fail at once with `error.ServiceUnavailable` and `lastError` code `circuit_open`, for 5 s and then while probes fail (up to 60 s). Answers from a live server (a unique violation, a statement timeout) and a busy pool (`pool_timeout`) never count. `breaker = null` turns it off. `with(.{ .retry = true })` runs a statement again on a transient failure (the server unreachable, a connection lost) with the connector's `retry`; use it only for statements that are safe to repeat. See [resilience.md](resilience.md).

### Options every connector shares

One vocabulary: a concept has the same field name and type on every
connector that has it (durations are `anole.Duration`, with no unit suffix).
The C ABI's JSON config uses the same names, with `_ms` on durations (0 is
null where the field is optional).

| Concept | PostgreSQL | SQLite | Redis | MongoDB | JSON (`databases[i].<kind>.`) |
| --- | --- | --- | --- | --- | --- |
| `name` (metrics label) | `?[]const u8`, "postgres" | file name | "redis" | "mongodb" | `databases[i].name` |
| pool size | `max_connections: ?u32` | `readers: ?u32` | `max_connections: ?u32` | `max_connections: ?u32` (null: 100) | `max_connections`, `readers` |
| 0 connections | `error.InvalidOptions` | `readers = 0`: all on the writer | `error.InvalidOptions` | `error.InvalidOptions` (a URL's `maxPoolSize=0` too) | E_CONFIG |
| wait for a connection | `acquire_timeout` (5 s) | - | `acquire_timeout` (5 s) | `acquire_timeout` (10 s) | `acquire_timeout_ms` |
| connect bound | `connect_timeout: ?Duration` (10 s) | - | same | same | `connect_timeout_ms` (0: none) |
| idle close | `idle_timeout` (30 min) | - | `idle_timeout` (5 min) | `idle_timeout` (null) | `idle_timeout_ms` (0: none) |
| lifetime | `max_lifetime` (1 h) | - | - | - | `max_lifetime_ms` |
| circuit breaker | `breaker: ?resilience.Breaker.Options` (on) | - | same | same | `databases[i].breaker` (null: off) |
| retry policy | `retry: resilience.Retry` (3 attempts, 50 ms .. 1 s) | - | same | same (ignored: the spec's retryable reads and writes) | `databases[i].retry` |
| statement cache | `statement_cache_size: u16` (256) | `statement_cache_size: u16` (64) | - | - | `statement_cache_size` |
| lock wait | - | `busy_timeout: Duration` (5 s) | - | - | `busy_timeout_ms` |
| per-call bound | `timeout: ?Duration` (30 s) | same | same | same (also `maxTimeMS`) | `databases[i].timeout_ms` (0: none) |
| fail fast at start | `connect_at_start` | opens at init | `connect_at_start` | `connect_at_start` | `connect_at_start` |
| readiness bound | `ping_timeout` (2 s) | `ping_timeout` (2 s) | `ping_timeout` | `ping_timeout` | `ping_timeout_ms` |
| TLS | `tls: anole.db.Tls` | - | `tls: anole.db.Tls` | `tls: anole.db.Tls` | `ca_file`, `ca_pem`, `client_cert_file`, `client_key_file`, `client_cert_pem`, `client_key_pem`, `insecure_skip_verify` |
| errors | `errors: db.ErrorMap` | same | same | same | `databases[i].errors` |
| result cache bounds | `cache: db.CacheOptions` | same | same | same | `databases[i].cache` |

`anole.db.Tls` has three fields: `ca: ?anole.Ca`, `client_certificate:
?anole.Cert` (`.dev_self_signed` is refused) and `insecure_skip_verify`.
Whether TLS is used is the URL's (`sslmode`, `rediss://`, `tls=true`);
giving `ca` or `client_certificate` asks for it with the certificate
checked, and a URL that turns TLS off or stops checking (`sslmode=disable`,
`allow`, `prefer`, `redis://`, `tls=false`, `tlsInsecure`) is refused at
init rather than silently obeyed. `insecure_skip_verify` (TLS without
checking, for a managed server with a self-signed certificate on a network
you trust) is refused with `ca` and with an sslmode that verifies. Invalid
combinations log one message and fail with `error.InvalidOptions`.

The calls:

| Call | Returns |
| --- | --- |
| `exec(req, sql, args)` | rows changed (`u64`) |
| `one(T, req, sql, args)` | the first row; none is `error.NotFound` (404) |
| `optional(T, req, sql, args)` | the first row, or null |
| `all(T, req, sql, args)` | every row (`[]T`) |
| `iterate(T, req, sql, args)` | rows one at a time: `next()`, then `deinit()` |
| `begin(req, opts)` | a transaction: the same calls, `commit(req)`, `rollback(req)`, `deinit()` |
| `transaction(req, opts, func, args)` | `func(&tx, args...)`, committed, retried after a serialization failure |
| `acquire(req)` | the driver's own connection, given back with `release()` |
| `with(.{ .timeout, .prepare, .coalesce, .cache, .retry })` | the same calls with options; see [Caching](#caching) |

Each connector has the calls its database can do, and a call of the same
name means the same thing in each:

| | PostgreSQL | SQLite | MongoDB | Redis |
| --- | --- | --- | --- | --- |
| `exec` | yes | yes | no: writes return their counts (`updateMany`...), and `db(name).runCommand(req, command)` runs any command | no: `command(req, args)` runs any command |
| `one`, `optional`, `all` | yes | yes | yes, on a collection: a filter and find options for the SQL and its arguments | yes, a command for the SQL |
| `iterate` | yes | yes | yes, a cursor | no |
| `begin`, `transaction` | yes | yes | not yet | no; MULTI in a `pipeline` |
| `acquire` | yes | yes, the writer | no | yes |
| `with` | yes | yes | yes, and on a `db(name)` or a collection | yes |

`args` is a tuple: `.{ id, name }`. Values always go in `args`, never
into the SQL text: with arguments, a call runs exactly one statement. With
no arguments (`.{}`), PostgreSQL's and SQLite's `exec` run every statement
in the text (a schema, a migration), so SQL built from input there could
run statements of its own.

Outside a handler (startup, a
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
const App = struct { db: *anole.pg.Client };

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
| `sslmode` | `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`; unset: `verify-full`, or `prefer` for a server on this machine (see below) |
| `require_auth` | the ways the server may ask for the password, as in libpq: `scram-sha-256`, `md5`, `password`, `none`, a list, or `!` to exclude |
| `channel_binding` | `prefer` (the default), `require` (SCRAM-SHA-256-PLUS over TLS only), `disable` |
| `sslrootcert` | the CA file for `verify-ca`/`verify-full`; the system's store when unset (or `system`) |
| `sslcert`, `sslkey` | a client certificate |
| `sslnegotiation=direct` | TLS without the SSLRequest round trip (PostgreSQL 17+) |
| `application_name`, `options`, `connect_timeout` | as in libpq |
| `pool_max_conns` | connections in all (pgx's name) |
| anything else | a run-time parameter set at login: `?search_path=app&timezone=UTC` |

A host that is a directory is a Unix socket's:
`postgres://app@%2Fvar%2Frun%2Fpostgresql/app`.

**TLS and logging in.** Without an `sslmode` (in the URL, `Options.sslmode`
or `PGSSLMODE`, in that order),
a server on another host is reached with `verify-full`: TLS, with its
certificate checked against the system's store (or `sslrootcert`, or
`Options.tls.ca`) and its host name. A server on this machine (`localhost`,
127.0.0.0/8, `::1`, a Unix socket) gets libpq's `prefer`. So a server
whose certificate does not check out (self-signed, a private CA you did not
give, a Docker Compose service name the certificate does not carry) fails
to connect, and the log says what to set: `sslrootcert` (or `tls.ca`) for
a private CA, or `sslmode=require` to encrypt without checking, or
`sslmode=disable` on a network you trust. With `Options.tls.ca` set in
code, the server is always checked: an `sslmode` that would not check it
(`disable`, `allow`, `prefer`), from the URL or the environment, is
refused.

The password is sent in clear text or as MD5 only to a server that was
verified or is on this machine; otherwise a server asking for it that
way is refused (SCRAM-SHA-256 is PostgreSQL's default since 14).
`require_auth` sets the allowed methods explicitly, for example
`require_auth=md5` for an old server you trust. SCRAM uses channel binding
when the server offers it over TLS, which ties the login to the TLS
connection; `channel_binding=require` refuses to log in without it.

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

When the columns and parameters are known only at run time (what the C ABI
and the language bindings do), `with(opts).table(req, sql, params)` returns
an `anole.db.Table` (column names, type OIDs, rows of `anole.db.Value`) and
`with(opts).execValues(req, sql, params)` the rows changed, with `params` a
`[]const anole.db.Value`. Values come in PostgreSQL's text format: bool,
the integer types and float4/float8 are converted, bytea becomes bytes,
and everything else stays text (numeric exactly, dates as PostgreSQL prints
them, JSON text) for the caller to parse by the column's type OID. A
parameter goes as its type when the statement's parameter takes it in
binary, else as text that PostgreSQL parses.

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
_ = app.db.exec(req, "INSERT INTO users (email) VALUES ($1)", .{email}) catch |err| {
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
try tx.commit(req); // under the request's deadline, like every call
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
  Every call is bounded by `Options.timeout` (30 s) unless it passes its
  own `QueryOptions.timeout`; `.max` lifts it for one call (a long
  migration, a background job: `app.db.with(.{ .timeout = .max })`), and
  `timeout = null` removes it from the connector. Inside a request the
  request's deadline applies too, whichever comes first.
  `with(.{ .timeout = .fromSeconds(2) })` bounds one call (a 504 past
  it); `TxOptions.timeout` a whole transaction (null: the connector's).
  The server's own
  `statement_timeout` (`?options=-c%20statement_timeout%3D5s`) is a 504
  as well.
- **Shared and cached reads.** `with(.{ .coalesce = true })` and
  `with(.{ .cache = .{ .ttl = ... } })`, off by default: see
  [Caching](#caching).
- **Handlers that wait.** A database call suspends the handler's
  coroutine, never the thread. Don't mark such routes `anole.noWait`.
- **Raw access.** `app.db.acquire(req)` hands over pg.zig's connection
  (`conn.raw`: `query`, `row`, `prepare`...) for what the calls above do
  not cover; `conn.release()` gives it back. `app.db.listener()` opens a
  connection for `LISTEN`/`NOTIFY` (channel names up to 63 bytes,
  PostgreSQL's limit).
- **Session state.** What a call left in its connection's session with
  `SET`, `set_config(..., false)`, `SET ROLE`, `SET SESSION
  AUTHORIZATION`, temporary tables, cursors `WITH HOLD`, advisory locks or
  `LISTEN` is gone before another request gets the connection. A
  connection given back inside a transaction is closed, never handed on.
  A plain call (`exec`, `one`, `all`... on the client, not a `Tx`) that
  leaves a transaction open, such as a bare `BEGIN`, is rolled back and
  fails, and so does an `iterate` that leaves one open; a connection from
  `acquire` given back inside a transaction is rolled back (and logged).
  The next call may get another connection, so the transaction
  would not be one. Use `begin` or `transaction`; a whole `BEGIN; ...;
  COMMIT` in one call without parameters still works. SQLite does the
  same, since its writer is shared by every request.
  `Options.reset_session` says how:
  - `.auto` (the default) resets a connection only when what it ran may
    have changed its session, and then sends only the statements that undo
    it, so the plain reads and writes most requests make cost nothing.
    Anole judges from each statement's SQL (string literals, quoted names
    and comments are skipped; this covers every verb, `acquire`'s raw
    connection and the C ABI): `SET` but `SET LOCAL`, `RESET`,
    `set_config` without a literal `true` as its third argument, `CREATE
    TEMP` and anything in `pg_temp`, `pg_advisory_lock` and
    `pg_try_advisory_lock` (not the `_xact_` ones), `LISTEN`, `DECLARE ...
    WITH HOLD`, and `nextval`, `setval`, `INSERT`, `MERGE` and `COPY`
    (which may leave `lastval()` behind); `DO` and `CALL` get the full
    reset. A setting the server reports changed (`TimeZone`, `DateStyle`,
    `application_name`, `is_superuser`...) counts too, wherever it was
    changed. `PREPARE`, `DEALLOCATE`, `DISCARD ALL` and `LOAD` close the
    connection rather than reset it.
  - `.always` sends the full reset (`DISCARD ALL` but for the prepared
    statements and `UNLISTEN`) on every release.
  - `.off` sends none; then set per-request state only with `SET LOCAL`
    (or `set_config(..., true)`) inside a transaction, since the next call
    on that connection may be another user's.

  Either reset is sent with the release and its answer read with the next
  call's, so it adds no round trip, only work on the server: `.always`
  cost about a fifth of the requests per second on a read-heavy benchmark
  (pooled single-row reads, 1024 connections), which `.auto` doesn't pay.
  The limit of `.auto`: what a server-side function or trigger does is not
  in the statement's text, so `SELECT my_function()` whose body runs
  `set_config(..., false)`, `SET ROLE` or `CREATE TEMP TABLE` leaves that
  for the next request (a changed `TimeZone`, `DateStyle`, `application_name`
  or superuser status is still caught, since the server reports those; a
  role switch between two ordinary roles is not: PostgreSQL does not report
  `role`, so a function that runs `SET ROLE` or `set_config('role', ..., false)`
  leaves the next request running as that role). If your functions change
  session state, or your app switches roles for row-level security, use
  `.always`, or switch roles only with `SET LOCAL ROLE` inside a transaction.

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

## SQLite

Built in with `-Dsqlite` (on in the `web` and `full` profiles). SQLite is
compiled into your program (the amalgamation, 3.54.1, through Anole's fork
of [zig-sqlite](https://github.com/vrischmann/zig-sqlite)): no server, no
install, one file.

```zig
const App = struct { db: *anole.sqlite.Client = undefined };

pub fn main(init: std.process.Init) !void {
    var state: App = .{};
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.db = try app.sqlite("app.db"); // created when missing; ":memory:" for one in memory
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
    try state.db.execScript(&c,
        \\CREATE TABLE IF NOT EXISTS notes (
        \\    id INTEGER PRIMARY KEY,
        \\    title TEXT NOT NULL UNIQUE,
        \\    done INTEGER NOT NULL DEFAULT 0
        \\);
    );
    app.get("/notes", list);
    app.get("/notes/:id", show);
    app.post("/notes", create);
    try app.listen(":3000");
}

const Note = struct { id: i64, title: []const u8, done: bool };

fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(try app.db.all(Note, req, "SELECT id, title, done FROM notes ORDER BY id LIMIT ?", .{50}));
}

fn show(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(i64, "id") orelse return error.NotFound;
    try res.json(try app.db.one(Note, req, "SELECT id, title, done FROM notes WHERE id = ?", .{id})); // none: 404
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { title: []const u8 });
    // The same title twice: error.Conflict, a 409.
    const note = try app.db.one(Note, req, "INSERT INTO notes (title) VALUES (?) RETURNING id, title, done", .{in.title});
    res.status = .created;
    try res.json(note);
}
```

`examples/sqlite` is a complete to-do API: `zig build run-sqlite`.

### Where the work runs

SQLite reads and writes its file on the thread that runs a statement, so
no statement runs on an executor:

- **Writes** go to the database's writer thread, which owns the one
  read-write connection: `exec`, any statement that changes something
  (`INSERT ... RETURNING` through `one` included), and transactions.
  Writers take turns in arrival order, so they never get `SQLITE_BUSY`
  from each other.
- **Reads** (`SELECT`, `WITH`, `VALUES`, `PRAGMA`, `EXPLAIN`) run on the
  server's blocking pool over read-only connections, one per executor (at
  most 8). The database is in WAL mode, so reads run beside a write and
  never wait for it. A read that turns out to write (`WITH ... INSERT`)
  moves to the writer by itself; `with(.{ .write = true })` sends one
  there directly (a `SELECT` of a function with side effects).
- **`:memory:`** is one database for the whole app, on the writer's
  connection: every executor sees the same tables.

`app.sqlite` starts the blocking pool when `Options.blocking` did not.

Each connection runs with `journal_mode=WAL`, `synchronous=NORMAL`,
`busy_timeout=5000` and `foreign_keys=ON`. Prepared statements are kept per
connection, by SQL text (64 by default; `.prepare = false` for SQL built at
run time). `with(.{ .timeout })` bounds a call, interrupting the statement
past it; `.coalesce` and `.cache` share and keep reads, as for every
connector ([Caching](#caching)).

### Transactions

```zig
fn move(tx: *anole.sqlite.Tx, req: *anole.Request, from: i64, to: i64, amount: i64) !void {
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ amount, from });
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ amount, to });
}

try app.db.transaction(req, .{ .retries = 3 }, move, .{ req, from, to, amount });
```

A transaction holds the writer (`BEGIN IMMEDIATE`) until it commits or
rolls back, so make it short, and inside it use the `Tx`, not the `Client`: a
write on the `Client` would wait for the transaction's own writer. `transaction`
runs again after `SQLITE_BUSY` (another process held the file past
`busy_timeout`, as during a restart), up to `retries` more times.
`begin(req, .{ .read_only = true })` is a snapshot on a reader that writes
do not disturb. By hand, as with PostgreSQL:

```zig
var tx = try app.db.begin(req, .{});
defer tx.deinit(); // rolls back unless committed
_ = try tx.exec(req, "DELETE FROM notes WHERE done = 1", .{});
try tx.commit(req);
```

On both SQL connectors a `Tx` also has `table(req, sql, values)` and
`run(req, sql, values)` (columns and parameters known at run time) and
`with(options)`, whose calls take `timeout` and `prepare`; `coalesce` and
`cache` fail the call inside a transaction. A `Tx` used after `commit` or
`rollback` fails with `error.Database` ("the transaction is over"), never
an assert. A transaction left open by `iterate`, or by a connection from
`acquire` given back (the writer, for SQLite), is rolled back and logged,
as a plain call that leaves one is.

### Options

```zig
state.db = try app.sqlite(.{
    .path = "data/app.db",       // or "sqlite:data/app.db", ":memory:"
    .uri = false,                // true: a "file:..." path is a SQLite URI
    .readers = 4,                // read-only connections; 0: everything on the writer
    .busy_timeout = .fromSeconds(5), // waiting for a lock another process holds
    .statement_cache_size = 64,     // per connection
    .ping_timeout = .fromSeconds(2), // /readyz
    .timeout = .fromSeconds(30),     // every call without its own bound
    .pragmas = &.{"PRAGMA cache_size = -20000"}, // run on every connection
});
```

A path starting with `file:` is a [SQLite URI](https://sqlite.org/uri.html),
whose parameters pick the VFS, the open mode, `immutable` and `nolock`.
Since the path often comes from the environment, such a path is refused
unless `.uri = true`.

### Values

| Zig | SQLite |
| --- | --- |
| integers, `bool` | INTEGER |
| floats | REAL |
| `[]const u8` | TEXT (a BLOB column reads as its bytes) |
| `anole.sqlite.Blob` | BLOB |
| enums | TEXT, their name (an INTEGER column reads by value) |
| `anole.db.Time` | TEXT as SQLite writes times (`2026-10-21 09:30:00.25`, UTC); reads `unixepoch()` integers and `julianday()` reals too |
| optionals | NULL for null |
| other structs and slices | JSON text |

### Errors

| SQLite | Error | Status |
| --- | --- | --- |
| `CONSTRAINT_UNIQUE`, `CONSTRAINT_PRIMARYKEY` | `error.Conflict` | 409 |
| `BUSY` past `busy_timeout`, `LOCKED` | `error.ServiceUnavailable` | 503 |
| interrupted by `with(.{ .timeout })` | `error.GatewayTimeout` | 504 |
| `CONSTRAINT_FOREIGNKEY`, `_NOTNULL`, `_CHECK`, the rest | `error.Database` | 500 |

`anole.db.lastError(req)` has SQLite's extended result code (`2067`), its
message, and for a constraint its name and table (`users.email`, `users`).
`errors` moves the classes, as for PostgreSQL:
`app.sqlite(.{ .path = "app.db", .errors = .{ .foreign_key = .unprocessable_entity } })`.

### What it reports

When serving starts, `app.sqlite`'s database reports through what the app
has, whatever the order of the calls: `anole_db_*` metrics with
`system="sqlite"` and `db` the file's name (`app.metrics`), a span per call
(`app.tracing`), and a readiness check that runs `SELECT 1` within a second
(`/readyz`, `app.health`).

### Driver calls

`acquire(req)` holds the writer connection for SQLite's own API through
zig-sqlite (user functions, blobs, backups): `conn.run(func, args)` runs
`func(driver_db, args...)` on the writer thread; `conn.release()` gives it
back. `anole.sqlite.c` is the C API.

## MongoDB

Built in with `-Dmongodb` (in the `full` profile): Anole's own client on
`std.Io`, written to MongoDB's driver specifications (OP_MSG, the
handshake, SCRAM, the connection string, server discovery and monitoring,
connection pooling, sessions, retryable reads and writes), with documents
in BSON (`anole.bson`). TLS goes through the same BoringSSL as the rest of
Anole. MongoDB 4.2 and later. CI tests 7.0 on ubuntu-latest, and 8.0 and
9.0 only on ubuntu-22.04: they do not run on newer Linux kernels yet (see
[below](#testing-against-mongodb)). `examples/mongodb` is a small users
API:

```sh
docker run --rm -d --name mongo -p 27017:27017 mongo:8.0 --replSet rs0 --bind_ip_all
docker exec mongo mongosh --quiet --eval 'rs.initiate()'
MONGODB_URI='mongodb://localhost:27017/app?directConnection=true' zig build run-mongodb
```

### Setup

```zig
const App = struct { db: *anole.mongodb.Client };

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.db = try app.mongodb(.{}); // MONGODB_URI
    _ = app.metrics(.{}); // pool and command metrics
    _ = app.health(.{}); // /readyz pings the primary
    app.get("/users/:id", get);
    try app.listen(":3000");
}
```

`app.mongodb` reads the connection string from `.url`, else
`MONGODB_URI`, else `mongodb://localhost:27017`. A string it cannot use
stops the start with the reason logged (never the password). It starts a
monitor per server at once; connections for calls open when a handler
needs one, per executor. A replica set gets primary discovery, failover
and retryable writes; a standalone server works without them; a
`directConnection=true` connection talks to that one server only.

The connection string takes the standard options; these are honoured:

| Option | |
| --- | --- |
| `replicaSet`, `directConnection` | the topology |
| `authSource`, `authMechanism` | `SCRAM-SHA-256` (the default when the server has it), `SCRAM-SHA-1`, `PLAIN`, `MONGODB-X509` |
| `tls`, `tlsCAFile`, `tlsCertificateKeyFile`, `tlsInsecure`, `tlsAllowInvalidCertificates`, `tlsAllowInvalidHostnames` | TLS; the system's trust store when no CA is given. The options that stop checking the certificate are logged as warnings, and with `Options.tls` set in code, `tls=false` and those options are refused |
| `appName` | in the server's logs and `currentOp` |
| `maxPoolSize` | connections in all, split between the executors (100) |
| `waitQueueTimeoutMS`, `serverSelectionTimeoutMS`, `connectTimeoutMS`, `heartbeatFrequencyMS`, `maxIdleTimeMS` | the waits (10 s, 30 s, 10 s, 10 s, none) |
| `timeoutMS` | a bound on every call, also sent as `maxTimeMS` |
| `retryWrites`, `retryReads` | on by default |
| `w`, `journal`, `wTimeoutMS`, `readConcernLevel` | the write and read concerns of every call |

Not yet: `mongodb+srv://` (it needs a DNS SRV lookup; use the standard
`mongodb://host1,host2,host3/?replicaSet=...&tls=true` string, which MongoDB
Atlas shows under Connect > Drivers when you pick an older driver version), read preferences other than `primary`,
`loadBalanced`, compression, and the GSSAPI, AWS and OIDC mechanisms; the
client refuses them at start rather than ignore them. `anole.mongodb.Options`
has the same settings as fields (`idle_timeout`, `connect_timeout: ?Duration`,
`max_connections: ?u32`, `connect_at_start`, `ping_timeout`), plus `tls`
(`anole.db.Tls`: a CA and a client certificate in memory), `errors`, and
`name` (the `db` label in metrics, `"mongodb"`). With `connect_at_start`
the start selects a server and opens a connection per executor, and fails
if that fails.

### Handlers

The calls are the official drivers', with the request first. Filters,
updates, projections and pipelines are Zig literals: an anonymous struct
is a document, a tuple an array.

```zig
const User = struct { _id: anole.bson.ObjectId, name: []const u8, email: []const u8, tags: []const []const u8 = &.{} };

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = anole.bson.ObjectId.parse(req.params.get("id").?) catch return error.NotFound;
    try res.json(try app.db.collection("users").findOne(User, req, .{ ._id = id }, .{})); // none: 404
}

fn recent(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const users = app.db.db("app").collection("users");
    try res.json(try users.find(User, req, .{ .tags = "beta", .age = .{ .@"$gte" = 18 } }, .{
        .sort = .{ .created = -1 },
        .limit = 20,
        .projection = .{ .email = 0 },
    }));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { name: []const u8, email: []const u8 });
    const r = try app.db.collection("users").insertOne(req, in); // a duplicate email: 409
    res.status = .created;
    try res.json(.{ .id = r.objectId().? });
}
```

| Call | Returns |
| --- | --- |
| `find(T, req, filter, opts)` | every match (`[]T`); options `sort`, `projection`, `skip`, `limit`, `batch_size`, `hint`, `collation`, `comment`, `allow_disk_use`, `let`, `max`, `min`, `return_key`, `show_record_id` |
| `findOne(T, req, filter, opts)` | the first match; none is `error.NotFound` (404) |
| `findOptional(T, req, filter, opts)` | the first match, or null |
| `iterate(T, req, filter, opts)` | a cursor: `while (try cur.next()) \|doc\|`, then `deinit()` |
| `aggregate(T, req, pipeline, opts)` | the pipeline's documents; `aggregateIterate` for a cursor |
| `countDocuments(req, filter, opts)`, `estimatedDocumentCount(req)` | a count |
| `distinct(T, req, field, filter)` | the distinct values |
| `insertOne(req, doc)` | `inserted_id` (an ObjectId made when the document has no `_id`) |
| `insertMany(req, docs, opts)` | `inserted_count`, `inserted_ids` |
| `updateOne`, `updateMany`, `replaceOne(req, filter, update, opts)` | `matched_count`, `modified_count`, `upserted_id` |
| `deleteOne`, `deleteMany(req, filter, opts)` | `deleted_count` |
| `findOneAndUpdate`, `findOneAndReplace`, `findOneAndDelete(T, req, ...)` | the document before (or, with `.return_document = .after`, after), or null |
| `createIndex(req, keys, opts)`, `dropIndex(req, name)`, `drop(req)` | indexes and the collection |
| `db(name).runCommand(req, command)` | any command's reply, as a `bson.Document` |
| `one(T, req, filter, opts)`, `optional`, `all` | the shared verbs: `findOne`, `findOptional` and `find` under the names the other connectors use |
| `with(.{ .timeout })` | the same calls with a timeout of their own (`app.db.with(...)`, or on a `db(name)` or a collection) |
| `with(.{ .coalesce = true })`, `with(.{ .cache = .{ .ttl, .tag, .keep_empty } })` | reads shared or kept ([Caching](#caching)) |

There are no transactions yet: each call stands alone, and is retried on
its own.

`app.db.collection(name)` is in the connection string's database (else
`"test"`, as the drivers do); `app.db.db(name).collection(name)` names
it. MongoDB has no `exec`: a write returns its own counts
(`matched_count`, `deleted_count`...), and `runCommand` returns the reply
of any command, as the official drivers name it. An option a call does not take is a compile error that lists those it
does.

Documents map onto structs by field name, through `anole.bson`: integers,
floats, `bool`, `[]const u8`, enums (by name), slices, nested structs,
optionals (missing or `null` is null), `anole.bson.ObjectId`,
`anole.bson.Datetime`, and `anole.bson.Value` or `anole.bson.Document`
for anything dynamic. A field the document lacks keeps its default, or
the call fails (500, logged). Decoded strings are copies in the request's
arena. In JSON responses an ObjectId is its hex string, a date an ISO
8601 string, and a raw document relaxed Extended JSON.

Calls named only at run time, with BSON documents for arguments (what the
C ABI and the language bindings send), go through
`anole.mongodb.dynamic.run(collection, database, ctx, op, args)`: `op` is
the method's name (`.find`, `.insertMany`, `.runCommand`...), `args` the
documents in the drivers' order, and options use the command's own names
(`sort`, `limit`, `batchSize`, `upsert`...). Reads return
`bson.Document`s, writes the driver's result as a document.

### Errors

| Server error | Error | Status |
| --- | --- | --- |
| no document from `findOne` | `NotFound` | 404 |
| 11000 duplicate key | `Conflict` | 409 |
| 112 write conflict, 251 no such transaction | `Conflict` | 409 |
| no primary within `serverSelectionTimeoutMS`, connection refused, authentication failed, a pool busy past `waitQueueTimeoutMS`, "not primary" and "node is recovering" after the retry | `ServiceUnavailable` | 503 |
| 50 `MaxTimeMSExpired`, 262, 64 (write concern timeout), a call past its `timeout` | `GatewayTimeout` | 504 |
| everything else, 121 document validation included | `Database` | 500 |

`anole.db.lastError(req)` has the code (`"11000"`), the server's message
and the collection. Writes that may be retried (single-document inserts,
updates, deletes and findOneAnd*, on a replica set) are sent once more
after a network error or a retryable error, with the same transaction
number, so the server applies them once; reads are retried once too.
`updateMany` and `deleteMany` are not retried, as the specifications say.

### Timeouts and cancellation

A request that ends early (a client gone, `req.setTimeout`, an HTTP/2
reset) cancels the call where it waits; the connection it was using is
closed, so no reply arrives on a reused one. `with(.{ .timeout = .fromSeconds(2) })`
or `timeoutMS` (`Options.timeout`, 30 s unless set) bounds a call (server
selection, the pool, the round trip) and sends the rest of the budget as
`maxTimeMS`, so the server stops too.
The request's own deadline is not sent as `maxTimeMS` yet.

### Observability

As for PostgreSQL, with `system="mongodb"`: the same metrics when the app
has `app.metrics`, a client span per command in a traced request (the
command's name as the operation, the collection as the target), and a
`/readyz` check that fails when the primary does not answer a `ping`
(checked at most once a second).

### Testing against MongoDB

`tests/mongodb/run.sh [image]` starts MongoDB in Docker (`mongo:8.0` by
default) as a replica set of one with authentication and test commands on,
with a CA and certificate made for the run, and runs `zig build
test-mongodb` three times: SCRAM-SHA-256, SCRAM-SHA-1, and over TLS.

MongoDB 8.x and 9.x are tested only on `ubuntu-22.04` (kernel 6.8). They do
not run on Linux kernels from 6.19 to 7.0.13, which newer runners and
distributions ship: 8.0.21 and later and every 9.x refuse to start there
(TCMalloc and rseq,
[SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912),
[SERVER-125742](https://jira.mongodb.org/browse/SERVER-125742)), and
earlier 8.0 releases start but crash within minutes. The script says so
when it sees it. On such a host test with `mongo:7.0`, which CI runs on
`ubuntu-latest`, or use a kernel before 6.19 or from 7.0.14. Against a
server of your own:

```sh
zig build test-mongodb -Dmongodb-test-url='mongodb://user:pw@localhost:27017/?replicaSet=rs0&authSource=admin'
```

## Redis and Valkey

Built in with `-Dredis` (on in the `full` profile). hiredis parses the
replies; the connections, pools and TLS are Anole's, the same shape as
the other connectors: a handle in your App state, the request first,
replies in the request's arena, errors as statuses. `examples/redis` has a
counter, a cache, a leaderboard and pub/sub streamed as Server-Sent Events:

```sh
docker run --rm -d -p 6379:6379 redis:7     # or valkey/valkey:8
zig build run-redis                         # REDIS_URL, else redis://127.0.0.1:6379
```

### Setup

```zig
const App = struct { redis: *anole.redis.Client };

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.redis = try app.redis(.{}); // REDIS_URL
    _ = app.metrics(.{}); // pool and command metrics
    _ = app.health(.{}); // /readyz sends PING
    app.get("/hits", hits);
    try app.listen(":3000");
}
```

`app.redis` reads `.url`, else `REDIS_URL`, else `redis://127.0.0.1:6379`,
and like `app.postgres` opens nothing before a handler needs it
(`.connect_at_start = true` to refuse to start without the server). The
URL is the one go-redis and redis-py take:

| URL | |
| --- | --- |
| `redis://host:6379/2` | plain text, database 2 (SELECT); `?db=2` works too |
| `redis://:password@host` | AUTH with the password (the default user) |
| `redis://user:password@host` | AUTH as an ACL user (Redis 6+, Valkey) |
| `rediss://...` | TLS, the certificate checked against the system's store |
| `rediss://...?ssl_ca_certs=/etc/ca.pem` | ... against this CA instead (or `.tls.ca`) |
| `rediss://...?ssl_certfile=c.pem&ssl_keyfile=k.pem` | a client certificate (or `.tls.client_certificate`) |
| `rediss://...?ssl_cert_reqs=none` | any certificate: a managed server with a self-signed one (logged as a warning; refused when `.tls.ca` is set in code) |
| `unix:///run/redis.sock?db=0` | a Unix socket |

`anole.redis.Options` has the rest: `max_connections` (ten per executor),
`acquire_timeout` (5 s), `connect_timeout` (10 s), `idle_timeout` (5 min:
an idle connection older than this is replaced, in case a proxy dropped
it), `errors`, `name` (the `db` label, `"redis"`). Redis Cluster and
Sentinel are not supported; a URL with several hosts is refused.

### Handlers

```zig
fn hits(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .hits = try app.redis.incr(req, "hits") });
}

const Profile = struct { name: []const u8, visits: u32, plan: enum { free, pro } = .free };

fn profile(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.get("id") orelse return error.NotFound;
    const key = try std.fmt.allocPrint(req.arena, "user:{s}", .{id});
    try res.json(try app.redis.hgetAll(Profile, req, key)); // no such hash: 404
}

fn page(app: *App, req: *anole.Request, res: *anole.Response) !void {
    if (try app.redis.get(req, "page:/")) |body| {
        res.body = body;
        return;
    }
    const body = try render(req); // the slow part
    _ = try app.redis.set(req, "page:/", body, .{ .ttl = .fromSeconds(30) });
    res.body = body;
}
```

Any command goes through `command`, which returns the `Reply`, or through
the typed calls, which read it into your type:

| Call | Returns |
| --- | --- |
| `command(req, .{ "INCR", key })` | the `Reply` (`.int`, `.string`, `.array`, `.nil`...) |
| `one(T, req, args)` | the reply as a `T`; nil (or an empty hash, for a struct) is `error.NotFound` (404) |
| `optional(T, req, args)` | the reply as a `T`, or null |
| `all(T, req, args)` | an array reply as `[]T` |
| `pipeline(req, .{ cmd1, cmd2 })` | every reply, in one round trip |
| `acquire(req)` | one connection for several calls, given back with `release()` |
| `subscribe(req, channels)`, `psubscribe` | a pub/sub connection of its own |
| `with(.{ .timeout })` | the same calls, bounded |
| `with(.{ .coalesce = true })`, `with(.{ .cache = .{ .ttl, .tag, .keep_empty } })` | reads shared or kept ([Caching](#caching)) |

The arguments are a tuple: strings as they are (binary-safe), numbers in
decimal, `bool` as 1 or 0, enums by name, null left out, slices and
nested tuples item by item, and a struct as its field names and values:
`.{ "HSET", key, profile }`, `.{ "DEL", keys }`, `.{ "SET", key, value, "EX", 60 }`.
Replies read into integers (from integers or numeric strings), floats,
`bool` (1/0, OK), `[]const u8`, enums, slices (`all(?[]const u8, req, .{ "MGET", keys })`),
structs (from a hash, by field name; a missing field keeps its default or
is `error.MissingColumn`) and optionals.

For what most apps do there are helpers: `get`, `set` (`.ttl`, `.nx`, `.xx`,
`.keep_ttl`; false when NX/XX kept it from being set), `del`, `incr`,
`incrBy`, `expire`; `hget`, `hset` (from a struct), `hgetAll` (into one),
`hdel`, `hincrBy`; `lpush`, `rpush`, `lrange`; `sadd`, `srem`, `smembers`,
`sismember`; `zadd`, `zincrBy`, `zscore`, `zrem`, `zrange`,
`zrangeWithScores` (a leaderboard: `zrangeWithScores(req, "board", 0, 9, .{ .rev = true })`);
`publish`. Everything else is `command` or a typed call.

`.coalesce` and `.cache` apply to `one`, `optional` and `all` and the
read helpers (`get`, `hget`, `hgetAll`, `lrange`, `smembers`,
`sismember`, `zscore`, `zrange`, `zrangeWithScores`) when the command
only reads: `GET`, `MGET`, `HGETALL`, `ZRANGE` and the other names in
`anole.redis.read_commands`. Every other command, `command`, pipelines,
pub/sub and calls on an `acquire`d connection run as they are, whatever
the options. A nil reply is a reply, and kept.

```zig
const profile = try app.redis.with(.{ .cache = .{ .ttl = .fromSeconds(30), .tag = "profiles" } }).hgetAll(Profile, req, key);
// After a write:
_ = try app.redis.hset(req, key, changed);
app.redis.cache.invalidate(.{ .tag = "profiles" });
```

A command known only at run time (what the C ABI and the language
bindings send) goes through `with(opts).reply(req, args)`, with `args` a
`[]const []const u8` (the name, then the items). It returns the `Reply`,
and `.coalesce` and `.cache` apply as above when the name is a read
command.

### Pipelines and transactions

```zig
// One round trip; MULTI ... EXEC makes it atomic.
const r = try app.redis.pipeline(req, .{ .{"MULTI"}, .{ "INCR", key }, .{ "EXPIRE", key, 60 }, .{"EXEC"} });
const count = r[3].array[0].int;
```

A pipeline fails with its first error reply, after every reply was read,
so the connection stays usable; errors inside EXEC's reply come back as
`.err` replies. WATCH needs one connection across round trips:

```zig
var conn = try app.redis.acquire(req);
defer conn.release();
_ = try conn.command(req, .{ "WATCH", key });
const stock = try conn.one(i64, req, .{ "GET", key });
const r = try conn.pipeline(req, .{ .{"MULTI"}, .{ "SET", key, stock - 1 }, .{"EXEC"} });
if (r[2] == .nil) return error.Conflict; // the key changed: nothing was set
```

A connection that a call leaves inside MULTI or WATCH, on another
database (SELECT), subscribed, or with other connection state (`CLIENT
SETNAME`, `CLIENT TRACKING`...) is closed rather than given to the next
call.

### Pub/sub

```zig
fn events(app: *App, req: *anole.Request, res: *anole.Response) !void {
    req.setTimeout(null); // a stream
    const sub = try app.redis.subscribe(req, "room:lobby");
    defer sub.close();
    var buf: [1024]u8 = undefined;
    var stream = try res.startEventStream(&buf);
    while (try sub.next(req)) |msg| try stream.send(msg.payload, .{});
    try stream.body.end();
}

fn post(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .receivers = try app.redis.publish(req, "room:lobby", (try req.body()).?) });
}
```

A subscriber has a connection of its own, outside the pools, confirmed by
the server when `subscribe` returns. `next` waits for a message (valid
until the next `next`) and returns null once nothing is subscribed, after
`stop()` (from any task), or when the server starts to drain, so a stream
like the one above ends in time. `subscribe`, `psubscribe`, `unsubscribe`
and `punsubscribe` on the subscriber change what it listens to without
waiting, even while another task waits in `next`.

### Errors and timeouts

| Reply or failure | Error | Status |
| --- | --- | --- |
| nil from `one` | `NotFound` | 404 |
| `LOADING`, `MASTERDOWN`, `BUSY`, `READONLY`, `OOM`, `TRYAGAIN`, `CLUSTERDOWN`, `NOREPLICAS`, `MISCONF`; a refused login (`WRONGPASS`, `NOAUTH`); no connection (refused, pool busy past `acquire_timeout`) | `ServiceUnavailable` | 503 |
| a call past `with(.{ .timeout })` | `GatewayTimeout` | 504 |
| any other error reply (`WRONGTYPE`, `ERR`, a script's), a reply that does not fit the type asked for | `Database` | 500 |

`anole.db.lastError(req)` has the server's message (`.code` is its first
word, `WRONGTYPE`), and `.errors` moves a class, as for PostgreSQL. A
call canceled in flight (the request's deadline, an HTTP/2 reset,
`with(.{ .timeout })`) closes its connection, since the reply may still
be on its way; the next call opens another. A blocking command
(`BLPOP`, `XREAD BLOCK`) holds its pooled connection while it waits, so
give it a `timeout` of its own or `acquire` one.

### Sessions and rate limits

`anole.session.RedisStore` and `anole.ratelimit.RedisLimiter` take the
same client and use its pools ([auth.md](auth.md)):

```zig
var sessions: anole.session.RedisStore = .{ .client = state.redis, .gpa = gpa };
var limits: anole.ratelimit.RedisLimiter = .{ .client = state.redis, .gpa = gpa };
```

### Observability

With `app.metrics`, the series of the PostgreSQL section appear with
`system="redis"` (command times, errors by name, the pools); with
`app.tracing`, each call in a traced request is a client span named after
the command (`PIPELINE` for a pipeline); with `app.health`, `/readyz`
fails while the server does not answer PING (checked at most once a
second).

### Testing against a server

`tests/redis/run.sh` starts `redis:7` (or `REDIS_IMAGE=valkey/valkey:8`)
in Docker, with a CA and certificate made for the run, and runs
`zig build test-redis` twice: in plain text as the default user, and over
TLS as an ACL user on database 1. Against a server of your own:

```sh
zig build test-redis -Dredis-test-url='redis://127.0.0.1:6379'
```

## Caching

Two opt-in options on the reads (`one`, `optional`, `all`) of every
connector, and on MongoDB's `find`, `findOne`, `findOptional`, `distinct`,
`estimatedDocumentCount`, `countDocuments` and `aggregate` (a pipeline
written as a tuple of stages that ends in neither `$out` nor `$merge`;
any other runs unshared), and on Redis's read commands and read helpers
([above](#redis-and-valkey)). Nothing is shared or cached unless a call asks: a call without
them is the plain call, with nothing added (no key, no lookup, no
allocation).

```zig
// Identical reads in flight at once share one round trip.
const feed = try app.db.with(.{ .coalesce = true }).all(Post, req, feed_sql, .{limit});

// The result kept for 5 s and served from memory meanwhile.
const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5), .tag = "posts" } }).all(Post, req, top_sql, .{});

// After a write: drop what it changed, on every executor.
_ = try app.db.exec(req, "INSERT INTO posts (body) VALUES ($1)", .{body});
app.db.cache.invalidate(.{ .tag = "posts" });
```

**Coalescing** (`.coalesce = true`): calls on one executor that are
identical (the same connector, statement, arguments, verb and row type)
and in flight at the same time run the statement once. Each caller waits
under its own deadline and cancellation and gets its own copy of the rows
in its own arena. A caller that is canceled or runs out of time leaves on
its own; the others still get the rows. When every caller has left, the
statement is canceled as a plain call's would be (a CancelRequest for
PostgreSQL, an interrupt for SQLite, a closed connection for MongoDB). Errors reach every caller, with the
detail in `lastError(req)`.

**Result cache** (`.cache = .{ .ttl, .tag }`): the result is kept per
executor for `ttl` and copied into the caller's arena on a hit. A miss
coalesces, so a burst of misses for one key runs the statement once per
executor. Errors are never kept (`one`'s `NotFound` included); an empty
result is a result and is kept, unless the call sets `.keep_empty = false`.

**Empty results** (`.keep_empty`, true by default): false serves an empty
result but keeps nothing, so the next call asks the database again. Empty
means `optional`'s null (a Redis nil from `get` or `hget`, MongoDB's
`findOne`/`findOptional` with no match) and `all`'s zero rows (MongoDB's
`find`, `aggregate` and `distinct` with none, an empty Redis list or set).
`one` and counts are never empty: no row is `error.NotFound`, which is
never kept. This is what cache-aside wants, where a miss is followed by
filling the store: with nil kept, the local cache would answer "missing"
for up to `ttl` after the value exists, or need an `invalidateQuery` on
every fill.

```zig
// In-process cache over Redis over PostgreSQL.
const aside = app.redis.with(.{ .cache = .{ .ttl = .fromSeconds(5), .keep_empty = false } });
const name = try aside.get(req, key) orelse blk: {
    const user = try app.db.one(User, req, "SELECT name FROM users WHERE id = $1", .{id});
    _ = try app.redis.set(req, key, user.name, .{ .ttl = .fromSeconds(60) });
    break :blk user.name;
};
```

**Where an answer came from**: `anole.db.lastSource(req)` says how the
last call made with `req` through `.cache` or `.coalesce` was answered:
`.cache` (this executor's result cache, no round trip), `.coalesced`
(an identical call already in flight, joined) or `.database` (a round trip
of its own); null when the request made none. Plain calls leave it as it
was, and a failed call sets it too, as `lastError` holds the failure. It
lives with the request (a `*anole.db.Ctx` keeps it in `last_source`), like
`lastError`, so the verbs keep their return types:

```zig
const top = try app.db.with(.{ .cache = .{ .ttl = .fromSeconds(5) } }).all(Post, req, top_sql, .{});
try res.header("X-Cache", if (anole.db.lastSource(req) == .cache) "HIT" else "MISS");
```

**Invalidation**: `app.db.cache.invalidate(.all)`, `.invalidate(.{ .tag =
"posts" })` for the results cached with that tag, or
`.invalidateQuery(sql, .{args})` for one statement's results (for
MongoDB, invalidate by tag: `app.db.cache.invalidate(.{ .tag = "users" })`;
for Redis, the command's name, then the rest:
`app.redis.cache.invalidateQuery("GET", .{key})`). It reaches
every executor at once, including a statement still running: a result read
before the invalidation is not kept, and a caller arriving after it does
not join that statement.

**Coherence**: each executor keeps its own results (no lock between
threads on the way), so two executors may answer from results read up to
`ttl` apart, and a write shows in the cache only after `ttl` or an
invalidation. Coalescing has a smaller window of its own: a caller that
joins a statement already running gets what that statement reads, which
may predate a write that committed a moment before the caller arrived,
unless that write invalidated.

Bounds are per connector, split between the executors, and least recently
used results go first: `.cache = .{ .max_entries = 4096, .max_bytes = 32 << 20 }`
in the connector's options (`app.postgres(.{ .cache = ... })`,
`app.sqlite(.{ .path = ..., .cache = ... })`, `app.mongodb(.{ .cache = ... })`,
`app.redis(.{ .cache = ... })`). A result larger than an
executor's share is not kept. With `app.metrics`, each cache reports
`anole_cache_hits_total`, `anole_cache_misses_total`,
`anole_cache_coalesced_total`, `anole_cache_stores_total`,
`anole_cache_evictions_total`, `anole_cache_entries` and
`anole_cache_bytes`, labelled `kind="db"` and the database's name;
`app.db.cache.stats()` has the same numbers.

Rows are copied, so their types must be copyable: numbers, `bool`, enums,
optionals, arrays, structs, tagged unions and slices of these (strings
included). A row type with another kind of pointer (`std.json.Value`, a
pointer to a single value) runs its calls unshared, with a warning logged
once. Arguments are compared by value: `5` as a `u8` and as an `i64` are
the same key, the string `"5"` is not; a MongoDB filter `.{ .age = 18 }`
is not `.{ .score = 18 }`.

When not to use them:

- Anything that must see its own or another request's write at once
  (read-your-writes, balances, stock counts), unless every write
  invalidates what it changes.
- Per-user data with the user in the key only through a session, not the
  SQL arguments: the key is the statement and its arguments, so a read
  that depends on who asks must take that as an argument.
- Statements with side effects (`nextval`, `INSERT ... RETURNING` through
  `one`): the statement runs once for all the callers that share it.
- Large or one-off results: each kept result takes memory on every
  executor that reads it, and a cache that never hits only adds a copy.
- Transactions: calls on a `Tx` are never shared.

For whole responses rather than rows, see `ResponseCache` in
[routing.md](routing.md#response-cache).
