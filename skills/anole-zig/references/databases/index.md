# Databases

Up: [SKILL.md](../../SKILL.md). Full docs: docs/database.md. Examples: examples/postgres, examples/sqlite, examples/mongodb, examples/redis, templates/rest-postgres, templates/full.

Anole ships the pool, the error mapping, retries, the result cache and the health, metrics and tracing hooks for every connector. Don't hand-roll them. This page covers what all connectors share; the topic files cover each one.

- [postgres.md](postgres.md): PostgreSQL, `app.postgres`, transactions, raw connections.
- [sqlite.md](sqlite.md): SQLite, `app.sqlite`, the writer thread, `:memory:`.
- [mongodb.md](mongodb.md): MongoDB, `app.mongodb`, CRUD, cursors, `anole.bson`.
- [redis.md](redis.md): Redis and Valkey, `app.redis`, helpers, pipelines, pub/sub.
- [migrations.md](migrations.md): `anole.db.migrate` for PostgreSQL and SQLite.
- [caching.md](caching.md): `.coalesce` and `.cache` on reads, invalidation.

Change feeds (LISTEN/NOTIFY, Redis streams, MongoDB change streams) go through `app.watch`: see [realtime](../realtime/index.md).

## The handle lives in the state struct

Use this every time. Call `app.postgres` / `app.sqlite` / `app.mongodb` / `app.redis` once in `main`, before `listen`, and put the returned `*Client` in the `Server(Ctx)` state struct that handlers get first.

Use: `anole.App.postgres`, `anole.App.sqlite`, `anole.App.mongodb`, `anole.App.redis` (src/server.zig; the same methods on `anole.Server(Ctx)`); `anole.pg.Client`, `anole.sqlite.Client`, `anole.mongodb.Client`, `anole.redis.Client`.

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

Traps:
- The server owns the client: it is closed with the server, after the drain (src/server.zig, doc of `postgres`). Don't `deinit` it, and don't build one with `Client.init` in an app: `app.*` wires it to metrics, tracing and `/readyz`.
- The order of `app.postgres`, `app.metrics`, `app.tracing` and `app.health` does not matter (docs/database.md, Observability). See [observability](../observability.md).
- Each connector is a build flag (`-Dpostgres`, `-Dsqlite` in the `web` and `full` profiles; `-Dmongodb`, `-Dredis` in `full`). Calling `app.mongodb` in a build without it is a compile error naming the flag. See [config-cli](../config-cli.md).
- Made after serving started, a connector starts inside the call, and a failed start is that call's error (src/server.zig).

## Calls take the request

Use: the verbs on each `Client` (src/pg/root.zig, src/sqlite/root.zig), `anole.db.Ctx` (src/db/root.zig).

Every call takes the request (`*anole.Request`) first. Rows come back as your structs in the request's arena: nothing to free. There is no query builder.

| Call | Returns |
| --- | --- |
| `exec(req, sql, args)` | rows changed (`u64`) |
| `one(T, req, sql, args)` | the first row; none is `error.NotFound` (404) |
| `optional(T, req, sql, args)` | the first row, or null |
| `all(T, req, sql, args)` | every row (`[]T`) |
| `iterate(T, req, sql, args)` | rows one at a time: `next()`, then `deinit()` |
| `begin(req, opts)`, `transaction(req, opts, func, args)` | SQL connectors only |
| `acquire(req)` | the driver's connection, given back with `release()` |
| `with(.{ .timeout, .prepare, .coalesce, .cache, .retry })` | the same calls with per-call options |

Outside a handler (startup, a background task), pass an `anole.db.Ctx` (copied from examples/postgres/main.zig):

```zig
var arena: std.heap.ArenaAllocator = .init(init.gpa);
defer arena.deinit();
var c: anole.db.Ctx = .{ .io = app.io(), .arena = arena.allocator() };
_ = try state.db.exec(&c, schema, .{});
```

Traps:
- `args` is a tuple (`.{ id, name }`). Values always go in `args`, never into the SQL text. With no arguments (`.{}`), PostgreSQL's and SQLite's `exec` run every statement in the text, so SQL built from input could run statements of its own (docs/database.md:114).
- Struct fields take columns by name (rename with `AS`). A field the result lacks keeps its default, or the call fails with `error.MissingColumn`.
- A database call suspends the handler's coroutine, not the thread. Don't mark such routes `anole.noWait` (docs/database.md:409). Blocking work of your own: [never block an executor](../runtime.md#never-block-an-executor).
- What the rows hold lives in the arena of `req` or the `Ctx`: [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).

## Errors are statuses

Use: `anole.db.Error`, `anole.db.ErrorMap`, `anole.db.Class`, `anole.db.lastError`, `anole.db.retryable` (src/db/root.zig).

Return a connector error from the handler and the server answers with its status. The database's message stays in the log and in `anole.db.lastError(req)`, never in the response.

| Error | Status |
| --- | --- |
| `NotFound` (no row from `one`) | 404 |
| `Conflict` (unique, exclusion, serialization, deadlock) | 409 |
| `ServiceUnavailable` (no connection, pool busy, breaker open) | 503 |
| `GatewayTimeout` (statement timeout, call past its `timeout`) | 504 |
| `Database` (foreign key, not-null, check, syntax, the rest) | 500 |

Move a class with `.errors`, or catch one case (both from docs/database.md):

```zig
state.db = try app.postgres(.{ .errors = .{ .foreign_key = .unprocessable_entity, .check = .unprocessable_entity } });

_ = app.db.exec(req, "INSERT INTO users (email) VALUES ($1)", .{email}) catch |err| {
    if (err == error.Conflict) return res.fail(.conflict, "that email is taken");
    return err;
};
```

Traps:
- Don't check "does the row exist" before `one`: `error.NotFound` already is the 404. Don't pre-check uniqueness: the unique violation is the 409.
- A `catch` must end in `return err` for the cases it does not handle. Every connector's `Error` includes `error.Canceled`; swallowing it breaks cancellation: [re-raise error.Canceled](../runtime.md#re-raise-errorcanceled).

## Connection URLs, options, time

Use: `anole.db.Time`, `anole.db.Tls`, `anole.db.QueryOptions`, `anole.db.TxOptions`, `anole.Duration`.

- Each connector reads its URL from `.url`, else the environment (`.env` files too in development, src/db/url.zig): `DATABASE_URL` (then libpq's `PG*`), `MONGODB_URI`, `REDIS_URL`. SQLite takes a path. With `anole.config`, pass the secret through: `app.postgres(.{ .url = if (cfg.database_url) |u| u.expose() else null })` (templates/rest-postgres/src/main.zig).
- Options share one vocabulary: `max_connections`, `acquire_timeout`, `connect_timeout`, `idle_timeout`, `timeout` (30 s per call), `connect_at_start`, `ping_timeout`, `breaker`, `retry`, `errors`, `cache`, `tls`, `name`. Durations are `anole.Duration` (`.fromSeconds(2)`), no unit suffix.
- A pool per executor: `max_connections` is split between executors and a busy executor does not borrow from an idle one (docs/database.md:378). Size the total for the busiest.
- No connection opens before a handler needs one, so the server starts while the database comes up. `.connect_at_start = true` refuses to start without it.
- `anole.db.Time` (microseconds since the epoch, UTC; RFC 3339 in JSON) reads timestamp columns and binds as a parameter. `Time.now(io)` for the current time.
- Retries and the circuit breaker are built in: `with(.{ .retry = true })` reruns a statement on a transient failure, only for statements safe to repeat. Details: [resilience](../storage-email-clients/index.md).
- On AWS Lambda each environment holds its own pools: put RDS Proxy or PgBouncer in front (docs/database.md:34). See [deployment](../deployment/index.md).
- Testing with a real server or `:memory:`: [testing](../testing.md).
