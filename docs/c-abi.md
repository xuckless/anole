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
| `ANOLE_EV_STOPPED` | `anole_event`: the server stopped; the consumer's last event | 0 |
| `ANOLE_EV_GRPC_CALL` | `anole_grpc_call_event`, then metadata spans, bytes | `anole_grpc_call` |
| `ANOLE_EV_GRPC_MESSAGE` | `anole_grpc_message_event`, then the message | `anole_grpc_call` |
| `ANOLE_EV_GRPC_HALF_CLOSE` | `anole_event`: the client sent its last message | `anole_grpc_call` |

Types 10, 15-19 and 20-39 are reserved (database results, more gRPC,
WebTransport).

A request record carries the route's `handler` id, the method (an enum and
the name as sent), the HTTP version (11, 20, 30), the raw path and query, the
headers (names lower-cased, order and duplicates kept), the route parameters,
the client's address (proxies applied), the listener's name, the request ID
(the `request_id` middleware) and a verified JWT's claims as JSON (the `jwt`
middleware). The record's bytes belong to the caller's buffer: copy what you
keep.

## Handles

`anole_req`, `anole_ws` and `anole_grpc_call` are 64-bit and generation-checked: a handle that
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
| `ANOLE_E_TIMEOUT` | a blocking call's timeout passed |

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
engine's HTTP/2 and HTTP/3 tests; `zig build test-grpc` the gRPC ones
(native, transcoding, and the ABI's, with descriptors, JSON and
transcoding). `tests/capi/bench.sh` compares consumer
routes with native ones.

## What comes next

ABI 0.1 was the request/response and WebSocket core; 0.2 adds the gRPC
server. Before the ABI freezes
(1.0) and the bindings ship, these come as their own pull requests, in this
order; their event types and handle kinds are reserved already:

1. `anole_db_*` with SQLite: non-blocking queries for event-loop consumers,
   with per-query request coalescing and a TTL result cache.
2. gRPC: server, with service methods implemented in the language (in
   0.2; event types 12-14, 15-19 reserved for gRPC).
3. WebTransport: sessions, streams and datagrams.
4. PostgreSQL through `anole_db_*`.
5. Redis.
6. MongoDB.
7. TLS extras: mutual TLS and the client certificate in the request,
   certificate reload per listener.
8. The freeze: ABI 1.0.

Auth beyond the configured `jwt` middleware comes later.
