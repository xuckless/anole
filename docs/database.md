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

## SQLite

SQLite is compiled into your program (the amalgamation, 3.54.1): no server,
no install, one file.

```zig
const App = struct { db: *anole.sqlite.Db = undefined };

pub fn main(init: std.process.Init) !void {
    var state: App = .{};
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.db = try app.sqlite("app.db"); // created when missing; ":memory:" for one in memory
    try state.db.execScript(
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
run time).

### Transactions

```zig
fn move(tx: *anole.sqlite.Tx, req: *anole.Request, from: i64, to: i64, amount: i64) !void {
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance - ? WHERE id = ?", .{ amount, from });
    _ = try tx.exec(req, "UPDATE accounts SET balance = balance + ? WHERE id = ?", .{ amount, to });
}

try app.db.transaction(req, .{ .retries = 3 }, move, .{ req, from, to, amount });
```

A transaction holds the writer (`BEGIN IMMEDIATE`) until it commits or
rolls back, so make it short, and inside it use the `Tx`, not the `Db`: a
write on the `Db` would wait for the transaction's own writer. `transaction`
runs again after `SQLITE_BUSY` (another process held the file past
`busy_timeout_ms`, as during a restart), up to `retries` more times.
`begin(req, .{ .read_only = true })` is a snapshot on a reader that writes
do not disturb.

### Options

```zig
state.db = try app.sqlite(.{
    .path = "data/app.db",       // or "sqlite:data/app.db", ":memory:"
    .readers = 4,                // read-only connections; 0: everything on the writer
    .busy_timeout_ms = 5000,     // waiting for a lock another process holds
    .statement_cache = 64,       // per connection
    .pragmas = &.{"PRAGMA cache_size = -20000"}, // run on every connection
});
```

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
| `BUSY` past `busy_timeout_ms`, `LOCKED` | `error.ServiceUnavailable` | 503 |
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
Anole. MongoDB 4.2 and later; CI runs 7.0, 8.0 and 9.0. `examples/mongodb` is
a small users API:

```sh
docker run --rm -d --name mongo -p 27017:27017 mongo:8.0 --replSet rs0 --bind_ip_all
docker exec mongo mongosh --quiet --eval 'rs.initiate()'
MONGODB_URI='mongodb://localhost:27017/app?directConnection=true' zig build run-mongodb
```

### Setup

```zig
const App = struct { mongo: *anole.mongodb.Client };

pub fn main(init: std.process.Init) !void {
    var state: App = undefined;
    var app = try anole.Server(App).init(init.gpa, .{ .errors = .json }, &state);
    defer app.deinit();
    state.mongo = try app.mongodb(.{ .environ = init.minimal.environ }); // MONGODB_URI
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
| `tls`, `tlsCAFile`, `tlsCertificateKeyFile`, `tlsInsecure`, `tlsAllowInvalidCertificates`, `tlsAllowInvalidHostnames` | TLS; the system's trust store when no CA is given |
| `appName` | in the server's logs and `currentOp` |
| `maxPoolSize` | connections in all, split between the executors (100) |
| `waitQueueTimeoutMS`, `serverSelectionTimeoutMS`, `connectTimeoutMS`, `heartbeatFrequencyMS`, `maxIdleTimeMS` | the waits (10 s, 30 s, 10 s, 10 s, none) |
| `timeoutMS` | a bound on every call, also sent as `maxTimeMS` |
| `retryWrites`, `retryReads` | on by default |
| `w`, `journal`, `wTimeoutMS`, `readConcernLevel` | the write and read concerns of every call |

Not yet: `mongodb+srv://`, read preferences other than `primary`,
`loadBalanced`, compression, and the GSSAPI, AWS and OIDC mechanisms; the
client refuses them at start rather than ignore them. `anole.mongodb.Options`
has the same settings as fields, plus `tls.ca` and `tls.client_certificate`
in memory, `errors`, and `name` (the `db` label in metrics, `"mongodb"`).

### Handlers

The calls are the official drivers', with the request first. Filters,
updates, projections and pipelines are Zig literals: an anonymous struct
is a document, a tuple an array.

```zig
const User = struct { _id: anole.bson.ObjectId, name: []const u8, email: []const u8, tags: []const []const u8 = &.{} };

fn get(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = anole.bson.ObjectId.parse(req.params.get("id").?) catch return error.NotFound;
    try res.json(try app.mongo.collection("users").findOne(User, req, .{ ._id = id }, .{})); // none: 404
}

fn recent(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const users = app.mongo.db("app").collection("users");
    try res.json(try users.find(User, req, .{ .tags = "beta", .age = .{ .@"$gte" = 18 } }, .{
        .sort = .{ .created = -1 },
        .limit = 20,
        .projection = .{ .email = 0 },
    }));
}

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const in = try req.bind(struct { name: []const u8, email: []const u8 });
    const r = try app.mongo.collection("users").insertOne(req, in); // a duplicate email: 409
    res.status = .created;
    try res.json(.{ .id = r.objectId().? });
}
```

| Call | Returns |
| --- | --- |
| `find(T, req, filter, opts)` | every match (`[]T`); options `sort`, `projection`, `skip`, `limit`, `batch_size`, `hint`, `collation`, `comment`, `allow_disk_use`, `let` |
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
| `one`, `optional`, `all` | the shared verbs: `findOne`, `findOptional`, `find` without options |
| `with(.{ .timeout })` | the same calls with a timeout of their own |

`client.collection(name)` is in the connection string's database (else
`"test"`, as the drivers do); `client.db(name).collection(name)` names
it. An option a call does not take is a compile error that lists those it
does.

Documents map onto structs by field name, through `anole.bson`: integers,
floats, `bool`, `[]const u8`, enums (by name), slices, nested structs,
optionals (missing or `null` is null), `anole.bson.ObjectId`,
`anole.bson.Datetime`, and `anole.bson.Value` or `anole.bson.Document`
for anything dynamic. A field the document lacks keeps its default, or
the call fails (500, logged). Decoded strings are copies in the request's
arena. In JSON responses an ObjectId is its hex string, a date an ISO
8601 string, and a raw document relaxed Extended JSON.

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
or `timeoutMS` bounds a call (server selection, the pool, the round trip)
and sends the rest of the budget as `maxTimeMS`, so the server stops too.
The request's own deadline is not sent as `maxTimeMS` yet.

### Observability

As for PostgreSQL, with `system="mongodb"`: the same metrics when the app
has `app.metrics`, a client span per command in a traced request (the
command's name as the operation, the collection as the target), and a
`/readyz` check that fails when the primary does not answer a `ping`
(checked at most once a second).

### Testing against a server

`tests/mongodb/run.sh [image]` starts MongoDB in Docker (`mongo:8.0` by
default; CI runs 7.0, 8.0 and 9.0) as a replica set of one with
authentication and test commands on, with a CA and certificate made for
the run, and runs `zig build test-mongodb` three times: SCRAM-SHA-256,
SCRAM-SHA-1, and over TLS. MongoDB 8.0.21 and later and 9.x refuse to
start on Linux kernels 6.19 to 7.0.13 (a TCMalloc incompatibility,
[SERVER-125742](https://jira.mongodb.org/browse/SERVER-125742)), and
earlier 8.0 releases crash there; the script says so when it sees it.
On such a host use `mongo:7.0` or a kernel from 7.0.14 (CI runs 8.0 and
9.0 on `ubuntu-22.04`, kernel 6.8). Against a server of your own:

```sh
zig build test-mongodb -Dmongodb-test-url='mongodb://user:pw@localhost:27017/?replicaSet=rs0&authSource=admin'
```
