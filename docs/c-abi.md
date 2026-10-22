# The C ABI

`libanole` is Anole as a C library: one server per process, configured by a
JSON document, whose routes either answer natively (fixed responses, static
files, the response cache, health, metrics, all of Anole's middleware) or
hand requests to a **consumer**: a thread of another language (Node's main
thread, a Python event loop, a C program) that answers by handle. The
bindings (`anole-node`, `anole-py`) are built on it; this guide is for
whoever writes one, or uses Anole from C.

The contract is [`include/anole.h`](../include/anole.h): every function
there says who owns what and for how long. The configuration's schema is
[`include/anole.schema.json`](../include/anole.schema.json). This is ABI
**0.1**: it changes before 1.0 (see [What comes next](#what-comes-next)).

## Building and linking

```sh
zig build capi -Doptimize=ReleaseFast
# zig-out/lib/libanole.a, zig-out/lib/libanole.{so,dylib}, zig-out/include/anole.h
cc -O2 app.c -Izig-out/include zig-out/lib/libanole.a -lpthread -o app
```

`libanole.a` is one object holding Anole, every C library it uses (BoringSSL,
nghttp2, ngtcp2, nghttp3, zlib-ng, zstd, Brotli, ...) and compiler-rt; it
needs only libc (and `-lpthread` on older glibc). It is packed with Zig alone
(no system linker, `objcopy` or `strip`), and every symbol but `anole_*` is
hidden (ELF `STV_HIDDEN`, Mach-O private extern), so a Node addon or a Python
extension that links it exports nothing else and never binds to, or
interposes on, the OpenSSL or zlib its host process carries. `zig build capi`
checks that the object and the shared library export `anole_*` alone. Hidden
symbols are still global within one link: two static libraries that both
define, say, `SSL_new` still clash when linked into the same extension.

The build flags apply: `-Dprofile=minimal` gives a library without TLS,
HTTP/2, HTTP/3 or WebSocket. `anole_has_feature("http3")` says what is in.

On Windows (a development target), `zig build capi` makes `anole.dll` and its
import library (COFF cannot merge objects into one); define `ANOLE_SHARED`
before including `anole.h`. There is no doorbell fd and no
`anole_respond_fd` there.

## The model

```
 clients ──> executors (one per core, Anole's threads)
               │  ring per executor (lock-free, one producer, one consumer)
               ▼
            consumer thread ── anole_poll (a batch) ── answers by handle
               ▲                                          │
               └────────── done list per executor ◄───────┘
```

- **Executors never run consumer code.** An executor fills a slot, pushes its
  handle onto the ring of the consumer it feeds, and rings the consumer's
  doorbell only if the consumer said it was going to sleep. Executors are
  shared out among the consumers at start (executor *e* feeds consumer
  *e* mod *M*).
- **The consumer drains a batch** with `anole_poll` into its own buffer, and
  answers with `anole_respond` (or a stream, or a file). The answer goes into
  the slot and onto the executor's done list; the executor is woken once per
  burst, not once per answer.
- **HTTP/2 and HTTP/3 requests need no task.** A request that arrived whole
  runs on the connection's reader and its response is *detached*: nothing
  waits for it, and the reply is written into the connection when it comes.
  HTTP/1.1 requests (and HTTP/2 and HTTP/3 requests whose body is still
  arriving) keep a task that waits. A streamed answer or a file gets a task
  when it starts.
- **Anole enforces deadlines.** A request not answered within its timeout
  (`timeouts.request_ms`, or the route's `timeout_ms`) gets 504 from Anole;
  the late answer gets `ANOLE_E_GONE`. One sweeper per executor checks them,
  no timer per request.

## Threads and the wake contract

Every function may be called from any thread unless it says otherwise. A
handle is meant for the thread that polled it; another thread may use it
with the binding's own synchronization (calls on one handle must not
overlap). `anole_poll` on one consumer must not overlap with itself, except
on a shared consumer (`ANOLE_CONSUMER_SHARED`), which serializes polls and
returns one event per call.

A consumer is woken one of three ways:

- **A wake callback** (`anole_consumer_options.wake`): called on an Anole
  thread; it must not block and must not enter the language. In Node it is
  `napi_call_threadsafe_function(..., napi_tsfn_nonblocking)`; in Python a
  write to a socket the event loop watches.
- **The doorbell fd** (`anole_consumer_fd`, no callback): readable when
  events may be there (an eventfd on Linux, a pipe on macOS). `anole_poll`
  empties it; never read it yourself.
- **`anole_poll_wait`**: blocks the calling thread (a WSGI thread pool with
  the GIL released).

The contract is **at least once, may repeat**: after `anole_poll` returned
0, the wake fires at least once when events arrive, and may fire when there
turn out to be none. Some runtimes lose wakes (Bun's threadsafe functions
drop calls under load; a loop shutting down drops `call_soon_threadsafe`),
so an executor whose ring stays unpolled for `timeouts.rewake_ms` rings
again (`anole_stats.rewakes` counts it). After every wake, poll until 0:

```c
for (;;) {
  int64_t n = anole_poll(c, buf, sizeof buf, 0);
  if (n < 0) { /* ANOLE_E_TOOBIG: a bigger buffer */ }
  if (n == 0) break;          /* the doorbell is armed again */
  for (int64_t off = 0; off < n;) {
    const anole_event *ev = (const anole_event *)(buf + off);
    handle(ev);               /* switch on ev->type; skip types you do not know */
    off += ev->len;
  }
}
```

`ANOLE_POLL_NOARM` leaves the doorbell disarmed on a 0 return, for a consumer
that spins a few microseconds before sleeping; it must end with a plain poll.

## Events and records

Every record starts with `anole_event` (`type`, `len`, `handle`); records are
8-byte aligned and `len` covers the payload and padding, so a binding skips
the types (and the trailing fields) it does not know. Strings inside a record
are `anole_span`s (offset from the record's start, length).

| Event | Record | Handle |
| --- | --- | --- |
| `ANOLE_EV_REQUEST` | `anole_request_event`, then header spans, parameter spans, bytes | `anole_req` |
| `ANOLE_EV_BODY` | `anole_event`: more request body (after `ANOLE_E_AGAIN`) | `anole_req` |
| `ANOLE_EV_ABORT` | `anole_event`: the client left (or the drain cut it); nothing more is owed | `anole_req` |
| `ANOLE_EV_WRITABLE` | `anole_event`: a stream that took `ANOLE_BUSY` has room | `anole_req` |
| `ANOLE_EV_SENT` | `anole_sent_event`: a borrowed body is no longer read | either |
| `ANOLE_EV_WS_OPEN` | `anole_request_event` of the upgrade request | `anole_ws` |
| `ANOLE_EV_WS_MESSAGE` | `anole_ws_message_event`, then the bytes | `anole_ws` |
| `ANOLE_EV_WS_CLOSE` | `anole_ws_close_event`: the socket is done | `anole_ws` |
| `ANOLE_EV_WS_DRAIN` | `anole_event`: a socket that took `ANOLE_BUSY` has room | `anole_ws` |
| `ANOLE_EV_DB_RESULT` | `anole_db_result_event`, then column names, cells, bytes | 0 (`user_data`) |
| `ANOLE_EV_STOPPED` | `anole_event`: the server stopped; the consumer's last event | 0 |

Types 12-39 are reserved (gRPC calls, WebTransport, more database events).

A request record carries the route's `handler` id, the method (an enum and
the name as sent), the HTTP version (11, 20, 30), the raw path and query, the
headers (names lower-cased, order and duplicates kept), the route parameters,
the client's address (proxies applied), the listener's name, the request ID
(the `request_id` middleware) and a verified JWT's claims as JSON (the `jwt`
middleware). The record's bytes belong to the caller's buffer: copy what you
keep.

## Handles

`anole_req` and `anole_ws` are 64-bit and generation-checked: a handle that
was answered, expired, aborted, made up, or belongs to another kind gets
`ANOLE_E_GONE`, never another request. Treat the bits as opaque; 0 is never a
handle.

## Who owns what

| Thing | Owner and lifetime |
| --- | --- |
| `anole_server_options`, its `config_json` | the caller; read (and copied) during `anole_server_create` |
| strings and headers passed in (`anole_str`, `anole_header`) | the caller; read during the call |
| a response body passed to `anole_respond` | copied before the call returns |
| a body passed with `ANOLE_BODY_BORROW` | the caller's, unchanged until `ANOLE_EV_SENT` for it (which also comes when the client is gone) |
| the fd passed to `anole_respond_fd` | the caller's; Anole duplicates it and may be closed at once |
| the poll buffer and the records in it | the caller's |
| `anole_last_error()`'s text | Anole's, valid until the next `anole_*` call on the thread |
| `anole_version()`'s text | static |
| a request handle | valid from `ANOLE_EV_REQUEST` until it is answered (`anole_respond`, `anole_respond_fd`, `anole_stream_end`, `anole_release`), expires or is aborted |
| a WebSocket handle | from `ANOLE_EV_WS_OPEN` until `ANOLE_EV_WS_CLOSE` |
| a consumer | until `anole_server_destroy` |

## Status codes

`>= 0` is success: `ANOLE_OK`, or `ANOLE_BUSY` (taken, but past the
high-water mark: wait for `ANOLE_EV_WRITABLE` or `ANOLE_EV_WS_DRAIN`).
Negative codes mean nothing was done unless the function says otherwise:

| Code | Meaning |
| --- | --- |
| `ANOLE_E_INVALID` | a bad argument: status, header name or value (`Connection` and `Transfer-Encoding` included: the server writes those), flag, size (a request is still owed) |
| `ANOLE_E_GONE` | the handle was answered, expired, aborted, is stale or of another kind |
| `ANOLE_E_AGAIN` | nothing now; an event follows (`anole_req_read` with timeout 0) |
| `ANOLE_E_NOMEM` | out of memory |
| `ANOLE_E_CONFIG` | the configuration is wrong; `anole_last_error` says what and where |
| `ANOLE_E_STATE` | not in this state (a second server, attaching after start) |
| `ANOLE_E_UNSUPPORTED` | compiled out, or not on this OS |
| `ANOLE_E_TOOBIG` | the next event does not fit the poll buffer (it stays queued) |
| `ANOLE_E_SYSTEM` | the OS refused (a port in use, a certificate that will not load) |
| `ANOLE_E_TIMEOUT` | a blocking call's timeout passed (a query's `timeout_ms`, in its answer) |
| `ANOLE_E_DB` | in a query's answer: the database refused the statement (`error_class`) |

## Configuration

`anole_server_create` takes one JSON document; unknown keys are refused with
the line and column. Everything that never needs the language is configured
here and runs on Anole's threads:

```json
{
  "executors": 0,
  "listeners": [
    { "name": "web", "address": "", "port": 8080 },
    { "name": "tls", "port": 8443, "tls": { "cert_file": "cert.pem", "key_file": "key.pem" }, "http3": true }
  ],
  "limits": { "body_max": 1048576, "inline_body_max": 65536, "max_inflight": 1024 },
  "timeouts": { "request_ms": 30000, "shutdown_ms": 10000, "rewake_ms": 20 },
  "middleware": [
    { "request_id": {} },
    { "access_log": { "format": "json", "exclude": ["/healthz"] } },
    { "compress": {} },
    { "cors": { "origins": ["https://app.example"] } },
    { "rate_limit": { "limit": 100, "window_ms": 60000, "key": "ip" } }
  ],
  "routes": [
    { "method": "GET", "path": "/", "respond": { "body": "hi", "headers": { "content-type": "text/plain" } } },
    { "path": "/assets", "static": { "dir": "public", "precompressed": ["br", "gzip"] } },
    { "method": "GET", "path": "/users/:id", "handler": 1, "cache": { "ttl_ms": 5000 } },
    { "method": "POST", "path": "/upload", "handler": 2, "timeout_ms": 120000 },
    { "path": "/api/*rest", "handler": 3, "middleware": [{ "jwt": { "jwks_url": "https://issuer.example/.well-known/jwks.json", "audience": "api" } }] },
    { "path": "/ws", "websocket": { "handler": 4 } }
  ],
  "observe": { "metrics": {}, "health": {} }
}
```

- A route has exactly one of `handler` (a consumer's route id), `respond` (a
  fixed answer), `static` (files under a directory) or `websocket`.
  A `respond` answer's `headers` may not name `Connection` or
  `Transfer-Encoding`, which the server writes itself, and must be valid
  field names and values; the configuration is refused otherwise.
- `middleware` at the top runs for every route, a route's own after it.
  `jwt` with `jwks_url` fetches keys, so its requests keep a task; with
  `jwks` inline (or no `jwt`), HTTP/2 and HTTP/3 requests detach.
  `jwt` with `jwks_url` needs `audience` (this API's identifier at the
  provider), since a provider's keys also sign tokens for its other
  clients; `allow_any_audience: true` is only for keys that sign for this
  application alone. The configuration is refused otherwise.
- `rate_limit` keys on the client's address (`"key": "ip"`, IPv6 clients
  by their /64) or on a header's raw value (`"header:<name>"`). The header
  is taken as the client sent it, unverified: a client that varies it gets
  a fresh limit each time. Use `header:` only when a proxy in front sets
  that header to a verified identity and overwrites any the client sent.
  Requests without the header share one limit.
- `cache` keeps GET answers per executor (the response cache) and serves
  hits without reaching the consumer.
- `no_wait: false` gives each request a task (for comparisons).

`anole_server_port(s, i)` reports listener *i*'s bound port (port 0 picks a
free one); *i* = the number of listeners gives the HTTP/3 UDP port.

## Requests

A body of up to `limits.inline_body_max` comes inline (`ANOLE_REQ_BODY_INLINE`,
the `body` span). A larger one (`ANOLE_REQ_BODY_STREAM`) is read with
`anole_req_read`: with timeout 0 it never blocks (`ANOLE_E_AGAIN`, then
`ANOLE_EV_BODY` when more is there); with a timeout it blocks the calling
thread. A body past `limits.body_max` ends the request with 413.

## Responses

- `anole_respond(r, status, headers, n, body, len, flags)`: the whole answer.
  The body is copied, or borrowed with `ANOLE_BODY_BORROW` (bindings borrow
  bodies above 64 KiB and copy small ones). Compression, the response cache
  and the access log run on Anole's side afterwards.
- `anole_respond_fd(r, status, headers, n, fd, offset, len)`: part of a
  regular file, sent by Anole (`sendfile` where it can).
- `anole_stream_start`, `anole_stream_write` (or `anole_stream_write_wait`
  for a thread that may block), `anole_stream_end` with trailers: a streamed
  answer. `ANOLE_BUSY` past `limits.stream_high_water`; wait for
  `ANOLE_EV_WRITABLE`. The deadline no longer applies once a stream started.
- `anole_release(r)`: give up; the client gets 500, or a cut-short stream.

## WebSocket

A `websocket` route upgrades over HTTP/1.1, HTTP/2 (RFC 8441) and HTTP/3
(RFC 9220). `ANOLE_EV_WS_OPEN` carries the upgrade request; each whole
message (inflated, UTF-8 checked) is an `ANOLE_EV_WS_MESSAGE`; the end is
`ANOLE_EV_WS_CLOSE` with the code (1005 without one, 1006 when the
connection ended without a close). Messages waiting for a consumer that is
behind are bounded per executor by bytes as well as by `limits.queue` (the
larger of 16 x `limits.ws_high_water` and 2 x `limits.ws_max_message`):
past that, the sockets feeding it are not read until it catches up. `anole_ws_send` queues a message
(`ANOLE_BUSY` past `limits.ws_high_water`, then `ANOLE_EV_WS_DRAIN`),
`anole_ws_close` sends a close. Topics are Anole's: `anole_ws_subscribe`,
`anole_ws_unsubscribe`, and `anole_ws_publish(server, topic, ...)` fans out
on Anole's threads without entering the language. A publish waits for no
subscriber: each one has up to `limits.ws_high_water` bytes queued for it;
past that, publishes skip it, and a subscriber whose send stays stuck that way
for a second is closed. Publishes still being fanned out are bounded too (64
per executor, and the larger of 16 x `limits.ws_high_water` and
2 x `limits.ws_max_message` bytes): past the bound `anole_ws_publish` answers
`ANOLE_E_AGAIN` and sends nothing. A drain closes sockets with 1001.

## Databases

`anole_db_*` runs SQL without blocking the caller, for event-loop consumers
(Node, asyncio). A database is configured with the server and opened at
start, before the listeners, with its `init` script (SQL). SQLite,
PostgreSQL and Redis are the kinds so far:

```json
"databases": [
  { "name": "main",
    "sqlite": { "path": "app.db", "init": "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT UNIQUE NOT NULL);" },
    "cache": { "max_entries": 4096, "max_bytes": 33554432 } }
]
```

```c
anole_db *db;
anole_db_find(s, (anole_str){"main", 4}, &db);
anole_db_value p[] = {{ANOLE_DB_TEXT, 0, {.s = {"milk", 4}}}};
anole_db_exec(db, consumer, sql_insert, p, 1, NULL, /*user_data*/ 7);
anole_db_options o = {sizeof o, ANOLE_DB_COALESCE, 0, /*cache_ttl_ms*/ 5000, 0, {"notes", 5}};
anole_db_query(db, consumer, sql_select, NULL, 0, &o, 8);
/* later, from anole_poll: ANOLE_EV_DB_RESULT with user_data 7, then 8 */
```

- Each call copies the statement and its parameters and returns at once.
  The answer is one `ANOLE_EV_DB_RESULT` record for the consumer named in
  the call, carrying the call's `user_data` (a binding's promise ID).
  Answers to different calls may arrive in any order.
- SQLite runs as in Zig ([database.md](database.md)): reads on read-only
  connections on Anole's blocking pool beside the writer (WAL), writes in
  turn on the database's writer thread, `:memory:` all on the writer.
- `anole_db_query` returns rows: the column names (`columns`), then
  `nrows * ncolumns` cells (`anole_db_cell`: null, integer, float, bool,
  text or blob), row after row, all in the record. A bool parameter binds
  as 1 or 0 in SQLite. `anole_db_exec` returns
  `changes` and `last_insert_rowid`; with no parameters its SQL may hold
  several statements.
- Options (`anole_db_options`, or NULL):
  - `timeout_ms` interrupts the statement (`ANOLE_E_TIMEOUT`, 504).
  - `ANOLE_DB_COALESCE`: identical reads in flight at once on one executor
    share one run.
  - `cache_ttl_ms`: the answer is kept per executor and served from memory
    (`source` says whether it was). `cache_tag` names a group of kept
    answers to drop by, with `anole_db_invalidate` after a write.
  - Nothing is coalesced or cached unless the call asks.
- Failures come back in the record, never as a call's return:
  - `status` is `ANOLE_E_DB`, `ANOLE_E_TIMEOUT`, `ANOLE_E_TOOBIG` (an answer
    past `limits.db_result_max`) or `ANOLE_E_NOMEM`.
  - `error_class` gives the kind of failure (`ANOLE_DB_ERR_UNIQUE`, ...).
  - `http_status` is what Anole's own handlers would answer for it (409, 503,
    504, 500).
  - The database's message, its code and the constraint are in the record,
    for logs. Don't send them to clients.
- Queries can be queued from `anole_server_start` until the server stops.
  Queries still running at the stop get no answer.

### PostgreSQL

The same calls, options, answers and error classes, with a `"postgres"`
database:

```json
"databases": [
  { "name": "main",
    "postgres": { "url": "postgres://app:secret@db.internal:5432/app",
                  "ca_file": "/etc/ssl/db-ca.pem",
                  "init": "CREATE TABLE IF NOT EXISTS notes (id bigserial PRIMARY KEY, title text UNIQUE NOT NULL)" } }
]
```

- It is `anole.pg` underneath ([database.md](database.md)): each executor
  has its own pool, so a query never leaves the executor that runs it,
  and `timeout_ms` also sends PostgreSQL a CancelRequest.
- TLS is checked by default. A server on another host gets
  `sslmode=verify-full` (TLS, the certificate and the host name checked
  against the system's store) unless the URL, `"sslmode"` or `PGSSLMODE`
  says otherwise; a server on this machine gets `prefer`. For a private CA,
  give `"ca_file"` (or `"ca_pem"`, the PEM text): with either, the server is
  always checked, and an sslmode that would not check it is refused. The
  URL's `sslrootcert`, `sslcert` and `sslkey` work as in libpq. `"sslmode"`
  and an `sslmode=` in the URL together are refused.
- `"url"` may be left out: then `DATABASE_URL`, else libpq's variables
  (`PGHOST`, `PGUSER`, `PGPASSWORD`...), from the process's environment.
- Parameters are `$1`, `$2`... Each value goes as the parameter's type when
  PostgreSQL takes it that way (an int for int4, int8 or numeric, a blob
  for bytea, a bool for bool), else as text that PostgreSQL parses into the
  parameter's type: a timestamptz as text (`"2026-10-22T10:00:00Z"`), an
  array literal (`"{1,2}"`), a number for a text parameter. A value
  PostgreSQL can't parse fails the query (`ANOLE_E_DB`, SQLSTATE 22P02).
- Cells: `bool` is `ANOLE_DB_BOOL`; `int2`, `int4`, `int8`, `oid` are
  `ANOLE_DB_INT`; `float4`, `float8` are `ANOLE_DB_FLOAT`; `bytea` is
  `ANOLE_DB_BLOB`; every other type is `ANOLE_DB_TEXT` in PostgreSQL's text
  format, as psql prints it: `numeric` exactly (`"12.50"`), timestamps as
  the session prints them (`"2026-10-22 10:00:00+00"`), JSON as its text,
  arrays as `"{1,2}"`. Every cell carries its column's type OID in
  `db_type` (`20` int8, `1700` numeric, `1184` timestamptz, `3802`
  jsonb...), so a binding parses text cells with its ecosystem's own
  PostgreSQL type parsers (what node-postgres and psycopg do with the same
  text) instead of Anole guessing at a JavaScript or Python type. NULL
  cells carry the OID too.
- `anole_db_exec` returns `changes` (rows inserted, updated or deleted);
  `last_insert_rowid` is 0. For generated keys, use `RETURNING` with
  `anole_db_query`.
- Errors: `error_code` is the SQLSTATE (`"23505"`), `constraint` the
  constraint's name; the classes are those of `anole.db`
  (`ANOLE_DB_ERR_UNIQUE` for 23505, `SERIALIZATION` for 40001,
  `UNAVAILABLE` when no connection could be had...).
- `ANOLE_DB_WRITE` means nothing here (any connection runs any
  statement).

### Redis

The same calls with a `"redis"` database (Redis or Valkey), on
`anole.redis`:

```json
"databases": [
  { "name": "kv", "redis": { "url": "rediss://app:secret@cache.internal:6380/0", "ca_file": "/etc/ssl/cache-ca.pem" } }
]
```

```c
anole_db_value p[] = {{ANOLE_DB_TEXT, 0, {.s = {"user:7", 6}}},
                      {ANOLE_DB_BLOB, 0, {.s = {data, len}}},
                      {ANOLE_DB_TEXT, 0, {.s = {"EX", 2}}},
                      {ANOLE_DB_INT, 0, {.i = 60}}};
anole_db_exec(db, consumer, (anole_str){"SET", 3}, p, 4, NULL, 1);
anole_db_query(db, consumer, (anole_str){"GET", 3}, p, 1, &cached, 2);
```

- A command is an array of arguments: `sql` holds the command's name and
  any fixed words (`"GET"`, `"CLIENT INFO"`, split on spaces), and each
  parameter is one more argument, binary-safe: text and blobs as they are,
  numbers in decimal, a bool as `1` or `0`, NULL left out. Keys and values
  always go in parameters, never in `sql`, as with SQL.
- `anole_db_query` answers with the whole reply. Replies are trees (an
  array of arrays, a map), so they are not forced into rows: the cells are
  the reply in preorder, `ncolumns` is 0 and `nrows` is the number of
  cells. `ANOLE_DB_ARRAY` (`i` items follow, each a whole subtree) and
  `ANOLE_DB_MAP` (`i` key, value pairs follow) are the inner nodes; bulk
  strings are `ANOLE_DB_BLOB` (bytes: a binding decodes UTF-8 by default
  and offers the bytes, as ioredis and redis-py do); status replies
  (`"OK"`) are `ANOLE_DB_TEXT`; integers `ANOLE_DB_INT`; nil
  `ANOLE_DB_NULL`; `ANOLE_DB_ERROR` is an error reply inside another
  (EXEC's). A binding rebuilds the reply with one recursive walk; for a
  flat reply (`GET`, `LRANGE`) it reads the cells after the first. Why
  the same record rather than one of its own: one event, one parser and
  one size limit for every database, and the cell types it needs already
  exist but for three.
- `anole_db_exec` runs the command for its effect: no cells, and
  `changes` holds the reply when it is an integer (`DEL`, `INCR`,
  `RPUSH`...).
- `ANOLE_DB_COALESCE` and `cache_ttl_ms` apply only to commands that just
  read (`GET`, `MGET`, `HGETALL`, `LRANGE`, `ZRANGE`... as
  `anole.redis.read_commands`); others run as they are. `timeout_ms`
  closes the connection the command waits on (a blocking pop, say).
- An error reply is `ANOLE_E_DB`: `error_code` is its first word
  (`"WRONGTYPE"`), `error` the whole message. `LOADING`, `READONLY`,
  `OOM`, `BUSY` and the like, a refused login and an unreachable server are
  `ANOLE_DB_ERR_UNAVAILABLE` (503); the rest `ANOLE_DB_ERR_OTHER` (500).
  An empty command is answered with `http_status` 400.
- One command per call. A transaction that must stay on one connection
  (`MULTI`/`EXEC`, `WATCH`) goes in one `EVAL` script for now; pub/sub is
  not part of `anole_db_*` (WebSocket topics cover fan-out to clients).

## Lifecycle

```c
anole_server_options o = { sizeof o, { json, strlen(json) } };
anole_server *s;   anole_server_create(&o, &s);
anole_consumer *c; anole_consumer_options co = { sizeof co, wake, ud, 0 };
anole_consumer_attach(s, &co, &c);   /* before start */
anole_server_start(s);               /* returns once listening */
/* ... poll and answer ... */
anole_server_drain(s);               /* stop accepting, finish what is in flight */
/* keep polling until ANOLE_EV_STOPPED */
anole_server_destroy(s);
```

One server per process. By default Anole installs no signal handlers (the
host process owns its signals); `ANOLE_SERVER_SIGNALS` asks for SIGINT and
SIGTERM (drain) and SIGHUP (reload certificates), for a standalone C program.
`anole_server_reload_certificates` reloads TLS certificates on demand.
`anole_server_stats` reports counters (requests, detached, in flight,
expired, aborted, refused, wakes and re-wakes, WebSockets); options structs
and the stats struct start with their `size`, so an older header keeps
working against a newer library.

Logs go to stderr, or to `anole_server_options.log` (called on Anole's
threads; it must not block or enter the language), filtered by `log_level`.

## Testing

`zig build capi-test` (part of `zig build test`) checks `anole.h` through
translate-c against the Zig side (every struct's layout, every constant),
and runs the C suite (`tests/capi/consumer.c`) against `libanole.a`.
`zig build capi-test-asan` builds the suite with the system C compiler under
ASan and UBSan (it runs with `ASAN_OPTIONS=use_sigaltstack=0`: Zig's threads
install their own signal stack). `zig build test-capi-engine` runs the
engine's HTTP/2 and HTTP/3 tests. `tests/capi/bench.sh` compares consumer
routes with native ones.

## What comes next

ABI 0.1 is the request/response and WebSocket core, plus `anole_db_*` with
SQLite, PostgreSQL and Redis. Before the ABI freezes (1.0) and the bindings ship, these come as
their own pull requests; their event types and handle kinds are reserved
already:

- MongoDB through `anole_db_*`.
- gRPC: server, with service methods implemented in the language.
- WebTransport: sessions, streams and datagrams.
- TLS extras: mutual TLS and the client certificate in the request,
  certificate reload per listener.
- Then the freeze: ABI 1.0.

Auth beyond the configured `jwt` middleware comes later.
