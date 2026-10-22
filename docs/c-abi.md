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
**0.2**: it changes before 1.0 (see [What comes next](#what-comes-next)).

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

Dead-stripping is safe (`-Wl,-dead_strip` on macOS, `-Wl,--gc-sections` on
Linux, Zig's release links): the packing step restores the Mach-O symbol
flags that keep BoringSSL's assembly whole, and the ELF object carries
`.note.GNU-stack`, so programs and extensions linking it keep a
non-executable stack. `zig build capi-test` serves HTTPS from a dead-stripped
link of `libanole.a`; `capi-test-asan` does the same with the system linker.

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
| `ANOLE_EV_ABORT` | `anole_event`: the client left (or the drain cut it, or the deadline passed); nothing more is owed | `anole_req`, `anole_grpc_call` |
| `ANOLE_EV_WRITABLE` | `anole_event`: a stream that took `ANOLE_BUSY` has room | `anole_req`, `anole_grpc_call` |
| `ANOLE_EV_SENT` | `anole_sent_event`: a borrowed body is no longer read | any |
| `ANOLE_EV_WS_OPEN` | `anole_request_event` of the upgrade request | `anole_ws` |
| `ANOLE_EV_WS_MESSAGE` | `anole_ws_message_event`, then the bytes | `anole_ws` |
| `ANOLE_EV_WS_CLOSE` | `anole_ws_close_event`: the socket is done | `anole_ws` |
| `ANOLE_EV_WS_DRAIN` | `anole_event`: a socket that took `ANOLE_BUSY` has room | `anole_ws` |
| `ANOLE_EV_DB_RESULT` | `anole_db_result_event`, then column names, cells, bytes | 0 (`user_data`) |
| `ANOLE_EV_STOPPED` | `anole_event`: the server stopped; the consumer's last event | 0 |
| `ANOLE_EV_GRPC_CALL` | `anole_grpc_call_event`, then metadata spans, bytes | `anole_grpc_call` |
| `ANOLE_EV_GRPC_MESSAGE` | `anole_grpc_message_event`, then the message | `anole_grpc_call` |
| `ANOLE_EV_GRPC_HALF_CLOSE` | `anole_event`: the client sent its last message | `anole_grpc_call` |

Types 15-39 are reserved (more gRPC, WebTransport, more database events).

A request record carries the route's `handler` id, the method (an enum and
the name as sent), the HTTP version (11, 20, 30), the raw path and query, the
headers (names lower-cased, order and duplicates kept), the route parameters,
the client's address (proxies applied), the listener's name, the request ID
(the `request_id` middleware) and a verified JWT's claims as JSON (the `jwt`
middleware). The record's bytes belong to the caller's buffer: copy what you
keep.

## Handles

`anole_req`, `anole_ws`, `anole_grpc_call`, `anole_wt` and `anole_wt_stream`
are 64-bit and generation-checked: a handle that
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

## WebTransport

A `webtransport` route accepts WebTransport sessions (draft-02 over HTTP/3,
what Chrome and Firefox speak) and hands them to a consumer. It needs a
listener with `http3`, and takes no method (a session is an extended
CONNECT):

```json
"listeners": [{ "port": 8443, "tls": { "cert_file": "cert.pem", "key_file": "key.pem" }, "http3": true }],
"routes": [{ "path": "/game", "webtransport": { "handler": 4, "origins": ["https://app.example.com"], "datagram_queue": 64 } }]
```

```c
case ANOLE_EV_WT_OPEN:      /* anole_request_event: the CONNECT; ev.handle is the anole_wt */
case ANOLE_EV_WT_STREAM:    /* the peer opened a stream: ev.handle, its session, ANOLE_WT_UNI */
case ANOLE_EV_WT_DATA:      /* bytes of a stream in order, ANOLE_WT_FIN with the last */
case ANOLE_EV_WT_DATAGRAM:  /* one datagram of the session */
case ANOLE_EV_WT_STREAM_RESET: case ANOLE_EV_WT_STREAM_STOP: /* the peer's code */
case ANOLE_EV_WT_DRAIN:     /* the server (or the peer) is draining */
case ANOLE_EV_WT_CLOSE:     /* code, reason, which side; the session and its streams are stale */

anole_wt_stream s;
anole_wt_open_stream(w, 0 /* or ANOLE_WT_UNI */, &s);   /* the handle is good at once */
anole_wt_stream_write(s, data, len, ANOLE_WT_FIN);       /* ANOLE_BUSY: wait for ANOLE_EV_WRITABLE */
anole_wt_stream_release(s);                              /* the end above still goes out */
anole_wt_send_datagram(w, buf, n);
anole_wt_close(w, 0, (anole_str){"bye", 3});
```

- One task on the connection's executor runs each session with the
  session calls that never wait, so a session costs no thread and no task
  per stream; what a consumer asks for wakes it like a WebSocket sender.
- Streams in either direction, opened by either side. The peer's stream
  data comes in `ANOLE_EV_WT_DATA` records of at most 32 KiB, in order;
  a consumer that falls behind holds back the reading (the record budget,
  then QUIC flow control). Writes are copied and queued:
  `limits.stream_high_water` bytes waiting answers `ANOLE_BUSY`, then
  `ANOLE_EV_WRITABLE` comes for the stream.
- Every stream must be released (`anole_wt_stream_release`) or go with
  its session: the peer may open a new stream only as earlier ones are
  released. A release resets a sending side not ended with
  `ANOLE_WT_FIN` and stops a receiving side not read to its end; one
  written with `ANOLE_WT_FIN` first sends everything.
- Datagrams: received ones are `ANOLE_EV_WT_DATAGRAM` (the session keeps
  up to 256 or 1 MiB waiting for the consumer, then drops new ones, as
  Anole does in Zig). Sent ones wait in a queue of the route's
  `datagram_queue` (64 by default) and past it **the oldest is dropped**:
  datagrams are for data that goes stale (positions, frames), so a new one
  matters more than the one it replaces, and the consumer never has to
  hold or retry them. Drops count in `anole_stats.wt_datagrams_dropped`.
  `anole_wt_max_datagram` says the largest one the session takes now;
  a larger one is `ANOLE_E_TOOBIG`.
- The drain: `ANOLE_EV_WT_DRAIN`, then each session closes (code 0) unless
  the route sets `close_on_drain: false`, which leaves it to the consumer
  until `timeouts.shutdown_ms`.

## Databases

`anole_db_*` runs SQL without blocking the caller, for event-loop consumers
(Node, asyncio). A database is configured with the server and opened at
start, before the listeners, with its `init` script (SQL). SQLite,
PostgreSQL, Redis and MongoDB are the kinds:

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

### MongoDB

The same calls with a `"mongodb"` database, on `anole.mongodb`:

```json
"databases": [
  { "name": "docs", "mongodb": { "url": "mongodb://app:secret@db1,db2,db3/?replicaSet=rs0", "database": "shop" } }
]
```

```c
/* filter and options: BSON documents the binding encoded */
anole_db_value p[] = {{ANOLE_DB_BLOB, 0, {.s = {filter, filter_len}}},
                      {ANOLE_DB_BLOB, 0, {.s = {options, options_len}}}};
anole_db_query(db, consumer, (anole_str){"find orders", 11}, p, 2, NULL, 1);
/* ANOLE_EV_DB_RESULT: a row per document, each cell ANOLE_DB_BSON */
```

- `sql` names the operation and the collection, and optionally another
  database than the configured one: `"find orders"`, `"aggregate events
  analytics"`. The operations are the drivers' methods of the same name:
  `find`, `findOne`, `aggregate`, `countDocuments`, `insertOne`,
  `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`,
  `deleteMany`, and `runCommand` (a database's; `sql` is `"runCommand"` or
  `"runCommand <database>"`, the escape hatch for everything else:
  indexes, `findAndModify`, `distinct`, admin commands).
- The parameters are BSON documents (`ANOLE_DB_BLOB`), in the order the
  drivers' methods take them: `find(filter, options)`, `insertOne(doc)`,
  `insertMany(doc, doc, ...)`, `updateOne(filter, update, options)` (the
  update may be a pipeline: an array), `aggregate(pipeline, options)` (a
  BSON array of stages; a document whose values are the stages works too),
  `deleteOne(filter, options)`, `runCommand(command)`. Options go under
  the command's own names, as the Node driver spells them: `sort`,
  `projection`, `limit`, `skip`, `batchSize`, `hint`, `collation`,
  `comment`, `allowDiskUse`, `let`, `upsert`, `arrayFilters`. An unknown
  option, a missing or extra document, or a parameter that is not valid
  BSON is answered with `http_status` 400 and the reason in `error`.
- Answers have one column, `"document"`. `find`, `findOne` and `aggregate`
  give a row per document, its cell `ANOLE_DB_BSON` (the document's
  bytes); `countDocuments` one `ANOLE_DB_INT`; the writes one BSON row
  with the driver's result (`{insertedId}`, `{insertedCount,
  insertedIds}`, `{matchedCount, modifiedCount, upsertedId}`,
  `{deletedCount}`); `runCommand` the server's reply. `anole_db_exec`
  answers with no rows and `changes`: the documents inserted, modified
  (and upserted) or deleted, or for a read their count.
- Why BSON both ways, not JSON: Anole passes the bytes it gets from the
  server, with no conversion, and a binding decodes them with the BSON
  library its ecosystem already uses (`bson` on npm, the one the official
  Node driver uses; `bson` from PyMongo, in C), so documents come out as
  the types users of the official drivers know: ObjectId, Date, Long,
  Decimal128, Binary. JSON would lose int64 precision in JavaScript,
  dates and ObjectIds would need Extended JSON wrappers anyway, and Anole
  would spend time converting what the binding converts again.
- The reads are cursors drained to the end within `limits.db_result_max`;
  use `limit` (and `skip` or a range filter) to page. `timeout_ms` bounds
  the call and goes to the server as `maxTimeMS`. `ANOLE_DB_COALESCE` and
  `cache_ttl_ms` apply to `find`, `findOne`, `countDocuments` and an
  `aggregate` that does not end in `$out` or `$merge`.
- Errors carry MongoDB's code in `error_code` (`"11000"` for a duplicate
  key: `ANOLE_DB_ERR_UNIQUE`, 409); no primary or an unreachable server is
  `ANOLE_DB_ERR_UNAVAILABLE` (503). Retryable reads and writes are retried
  once, as the drivers do.
- Transactions and change streams are not part of the ABI yet.

## gRPC

A `"grpc"` section serves gRPC services whose methods the consumer
implements. Anole does everything that is not the method itself: gRPC over
HTTP/2 (cleartext and TLS), gRPC-Web (binary and text, HTTP/1.1 and 2),
Connect (unary, GET for methods without side effects, streaming), JSON
transcoding of `google.api.http` routes, message framing and gzip, the
deadline (`grpc-timeout`, `connect-timeout-ms`, capped by
`max_call_duration_ms`), the per-call limits (`max_message_size`,
`max_received_bytes`, `read_timeout_ms`), status and trailers in each
protocol's form, and `grpc.health.v1` (`"health": true`).

```json
{"grpc": {
  "descriptor_set_file": "api.binpb",
  "health": true,
  "services": [
    {"name": "helloworld.Greeter", "handler": 1},
    {"name": "chat.Room", "handler": 2, "read_ahead": 16, "max_message_size": 65536}
  ]}}
```

**Registration.** Each service names its full name and a route id
(`handler`). Its methods come from the descriptors, a serialized
`FileDescriptorSet` with imports (`protoc --include_imports
--descriptor_set_out`, `buf build -o`, or what the binding's protobuf
library emits), given inline as base64 (`descriptor_set`) or as a file;
`methods` picks some and fixes their order. Without descriptors every
service lists its methods with their `kind`, and only protobuf is served.
`method_id` in each call is the method's index in that list.

**Messages cross as protobuf bytes, always.** Bindings already have
protobuf code generation (protobufjs, ts-proto, @bufbuild/protobuf,
grpcio-tools, betterproto), so the consumer decodes and encodes with its
own; Anole never needs the language's types. JSON is Anole's side of the
wire: with descriptors it converts Connect JSON, gRPC-Web JSON and
transcoded REST to protobuf and back with upb (protobuf's C runtime, the
proto3 JSON mapping including the well-known types), so a consumer sees
the same bytes whatever the client spoke (`ANOLE_GRPC_CALL_JSON` says
which). Without descriptors a JSON content type is answered 415. This is
why the descriptors are the registration: they are the one input that makes
JSON, transcoding and Connect GET possible, and every protobuf toolchain
can produce them.

**A call.** `ANOLE_EV_GRPC_CALL` carries the method (`route_id`,
`method_id`, `/package.Service/Method`), the call mode, the protocol, the
request metadata (the protocols' own headers left out, `-bin` values
decoded), the time left before the deadline (`timeout_us`, -1 for none),
the client's address and, for unary and server-streaming methods, the one
request message (`ANOLE_GRPC_CALL_MESSAGE`). The consumer answers:

- `anole_grpc_send_headers`: initial metadata, before the first message.
- `anole_grpc_send`: a response message. A unary or client-streaming
  call keeps its one message until `anole_grpc_finish`; with
  `ANOLE_GRPC_SEND_FINISH` it is sent with OK at once (a unary answer in
  one call). For server and bidirectional streaming each message goes out
  in order, and `ANOLE_BUSY` past `limits.stream_high_water` waits for
  `ANOLE_EV_WRITABLE`, as a streamed response does. `ANOLE_BODY_BORROW`
  borrows the bytes until `ANOLE_EV_SENT`.
- `anole_grpc_finish(code, message, trailers)`: the status, after the
  messages. The handle is stale afterwards.

Client- and bidirectional-streaming calls get their request messages as
`ANOLE_EV_GRPC_MESSAGE` events, then `ANOLE_EV_GRPC_HALF_CLOSE`. A call
starts with `read_ahead` messages of credit (8); `anole_grpc_read(c, n)`
grants more. Without credit Anole stops reading the call's messages, so a
slow consumer holds back its client through HTTP/2 flow control rather than
filling memory. Metadata the consumer sends follows gRPC's rules: a
lower-case key, a printable ASCII value, bytes under a `-bin` key (Anole
encodes them); the protocols' own keys (`grpc-*` but
`grpc-status-details-bin`, `connect-*`, `content-type`, `te`) are refused.

**The end.** `ANOLE_EV_ABORT` ends a call the consumer has not finished:
the client reset the stream or left, the deadline passed (the client got
DEADLINE_EXCEEDED), or its request messages failed a limit (the client got
RESOURCE_EXHAUSTED, or INTERNAL for a malformed frame). Calls on the handle
then return `ANOLE_E_GONE`. Anole enforces deadlines: a call needs no timer
in the language. Over HTTP/2 a client's RST_STREAM aborts the call at once;
over HTTP/1.1 (gRPC-Web, Connect) a client that hangs up while the answer is
pending is noticed only at the call's deadline, as for REST requests.

**The hot path.** A unary or server-streaming call that arrives whole over
HTTP/2 or HTTP/3 (the usual case) is detached, as a `no_wait` REST route's
request is: no task waits for it, its message is read where it lies in the
request (no copy when it is not compressed), and the consumer's answer is
written by the executor's capi task as one response with its trailers.
Deadlines of detached calls sit in a per-executor heap the capi task
sweeps. Client and bidirectional streaming, and calls over HTTP/1.1, run
on a task, whose deadline cancels it as a native handler's does. gRPC over
HTTP/3 is not served (as natively: gRPC runs over HTTP/2).

**Health.** With `"health": true`, `grpc.health.v1.Health` (Check, List,
Watch) is Anole's: the server (`""`) and every configured service start
SERVING, all turn NOT_SERVING when the server drains, and
`anole_grpc_health_set(server, service, status)` changes one, from any
thread, before or after start.

**Not in this ABI yet.** Reflection, server-side interceptors in the
language (Anole's middleware applies: `request_id`, `jwt` (its claims are
in the call event), `cors`, rate limits), gRPC over HTTP/3, and the
gRPC client.

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
and runs the C suites (`tests/capi/consumer.c`, and `tests/capi/grpc.c`
for gRPC over gRPC-Web and HTTP/2) against `libanole.a`. `zig build
capi-grpc` builds `capi-grpc-interop` (`tests/capi/grpc_interop.c`,
grpc.testing.TestService in C), which `tests/grpc/interop/run.sh
zig-out/bin/capi-grpc-interop` runs grpc-go's interop client against.
`zig build capi-test-asan` builds the suite with the system C compiler under
ASan and UBSan (it runs with `ASAN_OPTIONS=use_sigaltstack=0`: Zig's threads
install their own signal stack). `zig build test-capi-engine` runs the
engine's HTTP/2, HTTP/3 and WebTransport tests; `zig build test-grpc` the gRPC
ones (native, transcoding, and the ABI's, with descriptors, JSON and
transcoding). The C suite's WebTransport part has its server in C and its
client in Zig (`tests/capi/wt_client.zig`, built with the suite and passed
to it), since C has no WebTransport client. `tests/capi/bench.sh` compares consumer
routes with native ones.

## What comes next

ABI 0.1 was the request/response and WebSocket core, plus `anole_db_*` with
SQLite, PostgreSQL and Redis; 0.2 adds the gRPC server, 0.3 MongoDB through
`anole_db_*`, and 0.4 WebTransport. Before the ABI freezes (1.0) and the
bindings ship, these come as their own pull requests; their event types and
handle kinds are reserved already:

- TLS extras: mutual TLS and the client certificate in the request,
  certificate reload per listener.
- Then the freeze: ABI 1.0.

Auth beyond the configured `jwt` middleware comes later.
