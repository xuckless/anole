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
[`include/anole.schema.json`](../include/anole.schema.json), and every
record, constant, event and handle kind is described by
[`include/anole.abi.json`](../include/anole.abi.json), which bindings
generate their parsers from. This guide describes the ABI that ships with
the Anole release it belongs to; `ANOLE_ABI_VERSION` in `anole.h` is the
number, and the ABI changes before 1.0 (see
[What comes next](#what-comes-next)).

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
`anole_req_respond_fd` there.

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
  answers with `anole_req_respond` (or a stream, or a file). The answer goes into
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

## Console

The live console ([console.md](console.md)). The `console` configuration group
(`enabled`, `name`, `socket`, `allow_restart`, `read_only`, `log_buffer`,
`errors_kept`, `max_routes`, `runtime`) sets up the control socket that
`anole console` attaches to; a binding passes `name` (its package or module)
and `runtime` (`"node 22.11.0"`). libanole never reads stdin: the binding does,
stops reading and calls `anole_console_open(s, 0)` when the user asks, and
resumes after `ANOLE_EV_CONSOLE_CLOSED`. While it is open, descriptors 1 and 2
are captured and show in `/logs` as `stdout` and `stderr`.

| Call | Answers |
|---|---|
| `anole_console_open` | `ANOLE_E_STATE` (not running, or open already), `ANOLE_E_UNSUPPORTED` (`NoTerminal`), `ANOLE_E_CONFIG` (`ConsoleOff`) |
| `anole_console_close` | `ANOLE_OK`, also when it was not open (no event) |
| `anole_console_attached` | the consoles attached now, 0 or more |
| `anole_console_report` | `ANOLE_E_INVALID` (more than 32, a bad name or unit) |
| `anole_console_log` | `ANOLE_OK`, also when nothing is kept |

`anole_console_log` keeps the record for `/logs` only; the request handle
argument is accepted and not yet used to attach the request id.

## Rules

Fourteen rules, the same ones `anole.h` states at its top.

**Threads**

1. Any function may be called from any thread, except: `anole_poll` and
   `anole_poll_wait` never overlap on one consumer (a shared consumer
   serializes them); nothing is called from inside the wake or log
   callbacks; blocking functions are never called on an Anole thread;
   `anole_server_destroy` overlaps nothing on its server.
2. Calls on one handle are memory-safe from any thread. Serialize them
   anyway: overlapping answer calls on one handle may answer
   `ANOLE_E_GONE`. Cleanup calls may race anything; at most one takes effect.
3. Blocking: `anole_server_open`, `anole_server_start`, `anole_server_wait`,
   `anole_server_destroy`, `anole_poll_wait`; `anole_req_read`,
   `anole_req_stream_write_wait` and `anole_grpc_send_wait` with a timeout
   other than 0; briefly (file I/O) `anole_server_reload_tls` and
   `anole_req_respond_fd`. Everything else returns in microseconds.
4. Consumers attach before `anole_server_open` / `anole_server_start`;
   executor *e* feeds consumer *e* mod *M*, and start refuses a consumer that
   would get none (`ConsumerWithoutExecutor`).
5. Wake: at least once, may repeat. After any wake, poll until 0.
6. Shared consumers: any thread may get any event (route by handle); exactly
   one gets `ANOLE_EV_STOPPED`, after which `anole_poll_wait` returns 0
   everywhere.
7. One server per process. `fork` only before `anole_server_create` or after
   `anole_server_destroy`; a child cannot use its parent's server (its calls
   answer `ANOLE_E_STATE`, and it may create its own). In embedded mode
   Anole installs no signal handlers and its threads block asynchronous
   signals, so a host's SIGCHLD or SIGINT handler never runs on them.

**Lifetimes**

8. `anole_server`, `anole_consumer` and `anole_db` pointers live until
   `anole_server_destroy` returns; after it no callback runs again.
9. Handles: a request from its event to its answer, `ANOLE_EV_ABORT` or
   `ANOLE_EV_STOPPED`; a gRPC call to `anole_grpc_finish` or abort; a
   WebSocket to `ANOLE_EV_WS_CLOSE`; a WebTransport session to
   `ANOLE_EV_WT_CLOSE`; a WebTransport stream to `anole_handle_release` or
   its session's end. Events for a handle that is already over may still be
   queued.
10. Answer and data calls on an over handle answer `ANOLE_E_GONE` (counted in
    `anole_stats.gone`). **Cleanup calls** (`anole_handle_release`,
    `anole_req_abort`, `anole_ws_close`, `anole_ws_unsubscribe`,
    `anole_wt_close`, `anole_wt_stream_reset`, `anole_wt_stream_stop`)
    answer `ANOLE_OK` on a handle that is already over (answered, expired,
    aborted, closed by either side, released, from a destroyed server, with
    no server at all), do nothing, set no error and are not counted, so
    finalizers and `finally` blocks can call them blindly. 0, or a handle of
    another kind than the call takes, is `ANOLE_E_INVALID` everywhere
    (token `WrongHandleKind`): that is misuse, not a race.

**Ownership**

11. Everything passed in is copied before the call returns, except bodies
    passed with `ANOLE_BODY_BORROW`.
12. Records live in the caller's 8-byte aligned buffer; `len` covers the
    padding; copy what you keep before the next poll. Skip types you do not
    know; types that create an obligation come only when the configuration
    asks for them. A record's fixed part may grow at its end in a later ABI
    version, and its arrays are reached through offsets in it
    (`spans_off`, `metadata_off`), never through `sizeof`.
13. Strings returned: `anole_version` and `anole_last_error_name` are static;
    `anole_last_error` is thread-local text for logs, set with the name and
    `anole_last_errno` by every call that returns < 0.
14. Options structs start with `size = sizeof` as compiled. Bytes past what
    the library knows, reserved fields and unknown flag bits must be 0, or
    the call answers `ANOLE_E_INVALID` (`UnknownField`, `ReservedNotZero`,
    `UnknownFlag`).

### Notes for binding authors

- A handle is a `uint64_t`; JavaScript Numbers hold 53 bits and BigInt
  allocates, so anole-node may carry a handle as two `u32` halves (low at
  `ev+8`, high at `ev+12`; every supported target is little-endian) and pass
  both back to the addon. The generation is not shortened to fit 53 bits.
- `anole_str` and `anole_span` are passed by value; ctypes, cffi's ABI mode
  and `bun:ffi` handle struct-by-value poorly, so prototype bindings as C
  extensions (as anole-node and anole-py are).
- An `ArrayBuffer` and a `bytearray` are 8-byte aligned enough for the poll
  buffer.
- Check the library at load with `ANOLE_ABI_COMPATIBLE(anole_abi_version())`:
  before 1.0 both numbers must match; from 1.0 the major must match and the
  minor must be at least the header's.
- Generate parsers and constants from `anole.abi.json` (and config types from
  `anole.schema.json`), pinned to the Anole tag, and check in CI that what
  you regenerated is what you committed. Do not write a layout by hand.
- For `anole_poll`'s `ANOLE_E_TOOBIG`: keep a steady buffer (256 KiB serves
  requests and messages up to the defaults) and, when it happens, poll once
  into a one-off buffer of at least the `len` the answer put in the first
  `anole_event` (type `ANOLE_EV_NONE`).

## Threads and the wake contract

Every function may be called from any thread unless it says otherwise. A
handle is meant for the thread that polled it; another thread may use it
with the binding's own synchronization (calls on one handle must not
overlap). `anole_poll` on one consumer must not overlap with itself, except
on a shared consumer (`ANOLE_CONSUMER_F_SHARED`), which serializes polls and
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

`ANOLE_POLL_F_NOARM` leaves the doorbell disarmed on a 0 return, for a consumer
that spins a few microseconds before sleeping; it must end with a plain poll.

## Events and records

Every record starts with `anole_event` (`type`, `len`, `handle`); records are
8-byte aligned and `len` covers the payload and padding, so a binding skips
the types (and the trailing fields) it does not know. Strings inside a record
are `anole_span`s (offset from the record's start, length). The fixed part of
a record may grow at its end in a later ABI version; arrays (headers,
parameters, metadata) are reached through the offset stored in the record.

| Event | Record | Handle | Obligation |
| --- | --- | --- | --- |
| `ANOLE_EV_NONE` (0) | `anole_event`, written by `ANOLE_E_TOOBIG` only: `len` is the size the next record needs | 0 | none |
| `ANOLE_EV_REQUEST` | `anole_request_event`, then header spans, parameter spans, bytes | `anole_req` | an answer: respond, respond_fd, stream_end, fail, abort or handle_release |
| `ANOLE_EV_BODY` | `anole_event`: more request body (after `ANOLE_E_AGAIN`) | `anole_req` | none |
| `ANOLE_EV_ABORT` | `anole_abort_event`: why (`reason`) and what the client was sent (`status`); nothing more is owed | `anole_req`, `anole_grpc_call` | ends it |
| `ANOLE_EV_WRITABLE` | `anole_event`: a stream, call, WebSocket or WebTransport stream that took `ANOLE_BUSY` has room | `anole_req`, `anole_grpc_call`, `anole_ws`, `anole_wt_stream` | none |
| `ANOLE_EV_SENT` | `anole_sent_event`: a borrowed body is no longer read | any (may be stale) | none |
| `ANOLE_EV_WS_OPEN` | `anole_request_event` of the upgrade request | `anole_ws` | none |
| `ANOLE_EV_WS_MESSAGE` | `anole_ws_message_event`, then the bytes | `anole_ws` | none |
| `ANOLE_EV_WS_CLOSE` | `anole_ws_close_event`: the socket is done | `anole_ws` | ends the socket |
| (9) | retired: was `ANOLE_EV_WS_DRAIN`; WebSockets use `ANOLE_EV_WRITABLE` | | |
| `ANOLE_EV_DB_RESULT` | `anole_db_result_event`, then column names, cells, bytes | 0 (`user_data`) | none |
| `ANOLE_EV_STOPPED` | `anole_event`: the server stopped; the consumer's last event | 0 | none |
| `ANOLE_EV_GRPC_CALL` | `anole_grpc_call_event`, then metadata spans, bytes | `anole_grpc_call` | `anole_grpc_finish` (or `anole_handle_release`) |
| `ANOLE_EV_GRPC_MESSAGE` | `anole_grpc_message_event`, then the message | `anole_grpc_call` | none |
| `ANOLE_EV_GRPC_HALF_CLOSE` | `anole_event`: the client sent its last message | `anole_grpc_call` | none |
| `ANOLE_EV_WT_OPEN` | `anole_request_event` of the CONNECT | `anole_wt` | none |
| `ANOLE_EV_WT_CLOSE` | `anole_wt_close_event` | `anole_wt` | ends the session |
| `ANOLE_EV_WT_DRAIN` | `anole_event`: the session is draining | `anole_wt` | none |
| `ANOLE_EV_WT_STREAM` | `anole_wt_stream_event`: the peer opened a stream | `anole_wt_stream` | release (`anole_handle_release`) |
| `ANOLE_EV_WT_DATA` | `anole_wt_data_event`, then the bytes | `anole_wt_stream` | none |
| `ANOLE_EV_WT_STREAM_RESET` | `anole_wt_code_event`: the peer reset its sending side | `anole_wt_stream` | none |
| `ANOLE_EV_WT_STREAM_STOP` | `anole_wt_code_event`: the peer asked this side to stop sending | `anole_wt_stream` | none |
| `ANOLE_EV_WT_DATAGRAM` | `anole_wt_datagram_event`, then the bytes | `anole_wt` | none |
| `ANOLE_EV_WS_UPGRADE` (40) | `anole_request_event`: a WebSocket handshake the consumer accepts (`anole_ws_accept`) or refuses (any request answer); only on routes with `"accept": "consumer"` | `anole_req` | accept or a refusing answer |
| `ANOLE_EV_NATS_MSG` (64) | `anole_nats_msg_event`, then header spans and bytes: a message of a subscription | `anole_nats_sub` | none (answer with `anole_nats_publish` to its `reply` if wanted) |
| `ANOLE_EV_NATS_REPLY` (65) | `anole_nats_reply_event`: the answer to `anole_nats_request` or `anole_nats_js_publish` | 0 (`user_data`) | none |
| `ANOLE_EV_NATS_JS_MSG` (66) | `anole_nats_msg_event` with the JetStream fields set | `anole_nats_msg` | `anole_nats_ack` (any kind) or `anole_handle_release` (= NAK) |
| `ANOLE_EV_NATS_SUB_END` (67) | `anole_broker_end_event`: the subscription is over (`reason`, `dropped`) | `anole_nats_sub` | ends it |
| `ANOLE_EV_NATS_STATUS` (68) | `anole_broker_status_event`: the connection came up (`ANOLE_BROKER_CONNECTED`), was lost (`DISCONNECTED`), came back (`RECONNECTED`) or the server announced lame duck mode (`LAME_DUCK`); sent to every consumer | 0 | none |
| `ANOLE_EV_NATS_WRITABLE` (69) | `anole_broker_status_event`: a publish refused with `ANOLE_E_AGAIN` (or advised with `ANOLE_BUSY`) would be taken now | 0 | none |
| `ANOLE_EV_KAFKA_RECORDS` (80) | `anole_kafka_records_event`, then `anole_kafka_record`s, header spans and bytes: the next records of one partition | `anole_kafka_batch` | `anole_kafka_batch_done`, `anole_kafka_batch_retry`, or `anole_handle_release` (= retry now) |
| `ANOLE_EV_KAFKA_DELIVERY` (81) | `anole_kafka_delivery_event`: what became of a produced record, or (topic empty) of `anole_kafka_flush` | 0 (`user_data`) | none |
| `ANOLE_EV_KAFKA_ASSIGN` (82) | `anole_kafka_assign_event`: the partitions this member got | `anole_kafka_group` | none |
| `ANOLE_EV_KAFKA_REVOKE` (83) | `anole_kafka_assign_event`: the partitions it is about to lose | `anole_kafka_group` | finish those partitions' batches (they go stale at `rebalance_timeout_ms`) |
| `ANOLE_EV_KAFKA_WRITABLE` (84) | `anole_broker_status_event`: a produce refused with `ANOLE_E_AGAIN` (or advised with `ANOLE_BUSY`) would be taken now | 0 | none |
| `ANOLE_EV_KAFKA_GROUP_END` (85) | `anole_broker_end_event`: the group membership is over (`reason`) | `anole_kafka_group` | ends it |
| (86-95) | reserved for Kafka | | |
| `ANOLE_EV_NET_OPEN` (96) | `anole_net_open_event`: a raw TCP connection opened (ABI 0.10, p3/net) | `anole_net_conn` | none (the connection runs until CLOSE) |
| `ANOLE_EV_NET_DATA` (97) | `anole_net_data_event`: bytes or frames of a connection | `anole_net_conn` | none |
| `ANOLE_EV_NET_END` (98) | `anole_event`: the peer ended its side | `anole_net_conn` | with `half_open`: end this side when done |
| `ANOLE_EV_NET_CLOSE` (99) | `anole_net_close_event`: the connection is over | `anole_net_conn` | ends it |
| `ANOLE_EV_NET_DATAGRAMS` (100) | `anole_net_datagrams_event`: a batch of datagrams of a UDP socket | `anole_net_udp` | none |
| (101-103) | reserved for raw TCP and UDP | | |
| `ANOLE_EV_JOB_ENQUEUED` (104) | `anole_job_enqueued_event`: the answer to `anole_jobs_enqueue` (ABI 0.10, p3/jobs) | 0, or the `anole_db_tx` | none |
| `ANOLE_EV_JOB` (105) | `anole_job_event`: a job for a worker | `anole_job` | `anole_job_finish` (or `anole_handle_release` = retry) |
| `ANOLE_EV_JOB_CANCEL` (106) | `anole_job_cancel_event`: a held job was canceled | `anole_job` | ends it |
| `ANOLE_EV_JOB_WORKER_END` (107) | `anole_job_worker_end_event`: the worker stopped | `anole_job_worker` | ends it |
| `ANOLE_EV_JOBS_RESULT` (108) | `anole_jobs_result_event`: the answer to an admin call | 0 | none |
| `ANOLE_EV_WEBHOOK_PUBLISHED` (109) | `anole_webhook_published_event`: the answer to `anole_webhooks_publish` (p3/webhooks) | 0, or the `anole_db_tx` | none |
| `ANOLE_EV_WEBHOOK_STATUS` (110) | `anole_webhook_status_event` | 0 | none |
| (111) | reserved for jobs and webhooks | | |
| `ANOLE_EV_SSE_SUBSCRIBE` (112) | `anole_request_event`: a subscriber on a consumer's SSE route (ABI 0.10, p3/realtime) | `anole_req` | `anole_sse_accept`, or any request answer (a refusal) |
| `ANOLE_EV_SSE_CLOSE` (113) | `anole_sse_close_event`: the subscriber is gone | `anole_sse` | ends it |
| (114-115) | reserved for SSE | | |
| `ANOLE_EV_WATCH_EVENT` (116) | `anole_watch_event`: a change a watch saw | `anole_watch_sub` | `anole_watch_ack` for a stream group with `"ack": "manual"` |
| `ANOLE_EV_WATCH_STATUS` (117) | `anole_watch_status_event` | `anole_watch_sub` | none |
| `ANOLE_EV_WATCH_END` (118) | `anole_watch_end_event`: the watch is over | `anole_watch_sub` | ends it |
| (119-123) | reserved for watch | | |
| `ANOLE_EV_S3_RESULT` (124) | `anole_s3_result_event`: the answer to an `anole_s3_*` call (ABI 0.10, p3/s3) | 0, or the `anole_s3_transfer` it opens or ends | a transfer it opens: write and finish it, or read it to the end, or `anole_handle_release` |
| `ANOLE_EV_S3_DATA` (125) | `anole_s3_data_event`: bytes of a download | `anole_s3_transfer` | none (FIN ends the handle) |
| `ANOLE_EV_SMTP_RESULT` (126) | `anole_smtp_result_event`: the answer to `anole_smtp_send` (p3/smtp) | 0 | none |
| (127-131) | reserved for storage and mail | | |
| `ANOLE_EV_CONSOLE_CLOSED` (132) | `anole_console_closed_event`: the in-process console closed (`reason`: `ANOLE_CONSOLE_QUIT`, `_INTERRUPT`, `_RESTARTING`); only after `anole_console_open` | 0 | none: resume reading stdin |
| (133-135) | reserved for the console | | |
| `ANOLE_EV_DRAINING` (41) | `anole_event`: `anole_server_drain` was called; once per consumer, before sockets get 1001 or requests are cut: finish long polls and event streams | 0 | none |

The numbers are allocated once and frozen: 0 none; 1-11 core; 12-19 gRPC;
20-29 WebTransport; 30-39 database; 40-49 HTTP and WebSocket additions;
50-63 core additions; 64-79 NATS; 80-95 Kafka; 96-103 raw TCP and UDP;
104-111 jobs and webhooks; 112-115 SSE; 116-123 watch; 124-131 storage and
mail; 132-135 the console; 136-255 new areas; 256 and up are
never used by Anole (0x80000000 and up are free for a binding's own
synthetic events in its dispatch loop). Three rules go with them: a consumer
**skips types it does not know** (`ev.len`); an event that creates an
obligation is sent **only when the configuration asked** for the feature that
produces it, so a binding built for this version never receives an
obligation it cannot meet from a later Anole fed its own configuration; and
numbers are **never reused**.

`ANOLE_EV_ABORT`'s `reason` is one of `ANOLE_ABORT_CLIENT` (the client closed
the connection or cancelled the stream), `ANOLE_ABORT_DEADLINE` (the timeout
passed: the client got `status`, 504, or gRPC `DEADLINE_EXCEEDED`),
`ANOLE_ABORT_BODY` (the request body broke a limit or its framing: 413 or
400, or gRPC `RESOURCE_EXHAUSTED` / `INTERNAL`), `ANOLE_ABORT_DRAIN` (the
drain's deadline cut it) or `ANOLE_ABORT_SERVER` (Anole could not go on).
`ANOLE_E_TOOBIG` from `anole_poll` writes an `ANOLE_EV_NONE` header whose
`len` is the size the next record needs, so a binding allocates once instead
of doubling.

A request record (128 bytes, then variable parts) carries the route's
`handler` id, the method (an enum and the name as sent), the HTTP version
(11, 20, 30), the raw path and query, the headers (names lower-cased, order
and duplicates kept; their spans start at `spans_off`, then the route
parameters' spans: `anole_request_spans(r)`), the client's address (proxies
applied), the listener's name, the request ID (the `request_id` middleware),
a verified JWT's claims as JSON (the `jwt` middleware), the client's
certificate as a span (`peer_cert`, mutual TLS), `timeout_us` (the time left
before Anole answers 504, -1 when no deadline applies) and, for
`ANOLE_EV_WS_OPEN`, the selected `subprotocol`. A gRPC call record (104 bytes)
likewise has `metadata_off` (`anole_grpc_metadata(c)`) and `peer_cert`; both
helpers and `anole_record_spans` read the offset from the record. The
record's bytes belong to the caller's buffer: copy what you keep.

## Handles

`anole_req`, `anole_ws`, `anole_grpc_call`, `anole_wt` and `anole_wt_stream`
are 64-bit and generation-checked: an answer or data call on a handle that
was answered, expired, aborted or made up gets `ANOLE_E_GONE`, never another
request; a cleanup call gets `ANOLE_OK`; a handle that is 0 or of another
kind than the call takes gets `ANOLE_E_INVALID` (rule 10). Treat the bits as
opaque; 0 is never a handle. The kinds (published in `anole.abi.json` for
diagnostics) are:

| Kind | Name | C type |
| --- | --- | --- |
| 1 | request | `anole_req` |
| 2 | websocket | `anole_ws` |
| 3 | grpc_call | `anole_grpc_call` |
| 4 | wt_session | `anole_wt` |
| 5 | wt_stream | `anole_wt_stream` |
| 6 | db_tx | `anole_db_tx` (`anole_handle_release` rolls an open one back) |
| 7 | reserved for a per-query handle | |
| 8 | broker_sub | `anole_nats_sub` |
| 9 | broker_msg | `anole_nats_msg` |
| 10 | net_conn | `anole_net_conn` |
| 11 | net_udp | `anole_net_udp` |
| 12 | job_worker | `anole_job_worker` |
| 13 | job | `anole_job` |
| 14 | sse | `anole_sse` |
| 15 | watch_sub | `anole_watch_sub` |
| 16 | transfer | `anole_s3_transfer` |
| 17 | kafka_group | `anole_kafka_group` |
| 18 | kafka_batch | `anole_kafka_batch` |

19-31 are free. Since ABI 0.10 a Kafka group and batch are kinds of their
own (before, NATS's kinds with a marker bit), so a NATS handle given to a
Kafka call is the wrong kind.

`anole_handle_release(h)` ends any handle, whatever its kind, the way the
application giving up would: an unanswered request gets
`anole_req_fail(r, 500)` and a stream under way is cut short; a WebSocket
closes with 1001; a gRPC call finishes with `UNKNOWN`
("Application error processing RPC"); a WebTransport session closes with
code 0; a WebTransport stream resets what it has not ended and stops what it
has not read, and is let go. It is the one call a finalizer needs.

## Who owns what

| Thing | Owner and lifetime |
| --- | --- |
| `anole_server_options`, its `config_json` | the caller; read (and copied) during `anole_server_create` |
| strings and headers passed in (`anole_str`, `anole_header`) | the caller; read during the call |
| a response body passed to `anole_req_respond` | copied before the call returns |
| a body passed with `ANOLE_BODY_BORROW` | the caller's, unchanged until `ANOLE_EV_SENT` for it (which also comes when the client is gone) |
| the fd passed to `anole_req_respond_fd` | the caller's; Anole duplicates it and may be closed at once |
| the poll buffer and the records in it | the caller's |
| `anole_last_error()`'s text | Anole's, valid until the next `anole_*` call on the thread |
| `anole_version()`'s and `anole_last_error_name()`'s text | static |
| `anole_listener_info`'s strings | Anole's, valid until `anole_server_destroy` |
| a request handle | valid from `ANOLE_EV_REQUEST` until it is answered (`anole_req_respond`, `anole_req_respond_fd`, `anole_req_stream_end`, `anole_req_fail`, `anole_req_abort`, `anole_handle_release`), expires or is aborted |
| a WebSocket handle | from `ANOLE_EV_WS_OPEN` (or the `anole_ws_accept` that returned it) until `ANOLE_EV_WS_CLOSE` |
| a gRPC call handle | from `ANOLE_EV_GRPC_CALL` until `anole_grpc_finish` or abort |
| a WebTransport session and its streams | the session from `ANOLE_EV_WT_OPEN` to `ANOLE_EV_WT_CLOSE`; a stream until `anole_handle_release` or its session's end |
| a gRPC message passed with `ANOLE_BODY_BORROW` | the caller's, until `ANOLE_EV_SENT` |
| a database answer (`ANOLE_EV_DB_RESULT`'s rows and bytes) | in the record, which is the caller's buffer |
| a consumer, a database | until `anole_server_destroy` |

## Status codes

`>= 0` is success: `ANOLE_OK`, or `ANOLE_BUSY` (taken, but past the
high-water mark: wait for `ANOLE_EV_WRITABLE` on that handle).
Negative codes mean nothing was done unless the function says otherwise,
and each sets `anole_last_error` (text for logs, not API), `anole_last_error_name`
(a stable token, below) and `anole_last_errno` (the OS error behind it, 0
when it did not come from the OS):

| Code | Meaning |
| --- | --- |
| `ANOLE_E_INVALID` | a bad argument: status, header name or value (`Connection` and `Transfer-Encoding` included: the server writes those), flag, size, a handle that is 0 or of another kind (a request is still owed) |
| `ANOLE_E_GONE` | an answer or data call on a handle that was answered, expired, aborted or is stale |
| `ANOLE_E_AGAIN` | nothing now; an event follows (`anole_req_read` with timeout 0) |
| `ANOLE_E_NOMEM` | out of memory |
| `ANOLE_E_CONFIG` | the configuration is wrong; `anole_last_error` says what and where |
| `ANOLE_E_STATE` | not in this state (a second server, attaching after start) |
| `ANOLE_E_UNSUPPORTED` | compiled out, or not on this OS |
| `ANOLE_E_TOOBIG` | the next event does not fit the poll buffer (it stays queued) |
| `ANOLE_E_SYSTEM` | the OS refused (a port in use, a certificate that will not load) |
| `ANOLE_E_TIMEOUT` | a blocking call's timeout passed (a query's `timeout_ms`, in its answer) |
| `ANOLE_E_DB` | in a query's answer: the database refused the statement (`error_class`) |
| `ANOLE_E_BROKER` | in a broker call's answer: the broker refused it or could not be reached (`error_class`) |
| `ANOLE_E_SERVICE` | in an object store's or mail server's answer: it refused the call or could not be reached (`error_class`, `http_status`, `error_code`) |

### Error tokens

`anole_last_error_name()` is a stable token for the same error: a specific
name from this table (also `error_names` in `anole.abi.json`), or, when
there is none, the code's own name (`Invalid`, `Gone`, `Again`, `NoMemory`,
`Config`, `State`, `Unsupported`, `TooBig`, `System`, `Timeout`, `Database`,
`Broker`, `Service`).
Bindings may switch on it; tokens are only ever added.

| Token | Code | From |
| --- | --- | --- |
| `WrongHandleKind` | `ANOLE_E_INVALID` | 0, or a handle of another kind |
| `UnknownFlag`, `UnknownField`, `ReservedNotZero` | `ANOLE_E_INVALID` | a flag bit, a non-zero byte past an options struct or a reserved field the library does not know |
| `SyntaxError`, `UnknownKey`, `MissingKey`, `InvalidValue` | `ANOLE_E_CONFIG` | `anole_server_create` |
| `RouteConflict` | `ANOLE_E_CONFIG` | `anole_server_start` |
| `OneServerPerProcess` | `ANOLE_E_STATE` | `anole_server_create` |
| `NoConsumer`, `ConsumerWithoutExecutor` | `ANOLE_E_STATE` | `anole_server_open` / `anole_server_start` |
| `NotRunning`, `NoTlsListener` | `ANOLE_E_STATE` | reload, publish |
| `UnknownCheck` | `ANOLE_E_INVALID` | `anole_server_set_ready` |
| `InvalidEnvironmentVariable`, `DeploymentUnavailable`, `ProxyProtocolNoPeers` | `ANOLE_E_CONFIG` | `anole_server_create` (`ANOLE_ENV`, `ANOLE_DEPLOYMENT`, `PORT`; `deployment` lambda; `proxy_protocol` with an empty `proxy.trusted`) |
| `UnknownEnvironment`, `InvalidEnvFile` | `ANOLE_E_INVALID`, `ANOLE_E_CONFIG` | `anole_dotenv_read` |
| `AddressInUse`, `AddressNotAvailable`, `AccessDenied`, `TooManyOpenFiles`, `SystemResources` | `ANOLE_E_SYSTEM` | binds, threads, files (errno set) |
| `CertificateFileUnreadable`, `KeyFileUnreadable`, `ClientCaFileUnreadable` | `ANOLE_E_SYSTEM` | TLS files (errno set) |
| `InvalidCertificate`, `InvalidKey`, `KeyMismatch`, `InvalidClientCa` | `ANOLE_E_INVALID` from a reload, `ANOLE_E_CONFIG` from start | TLS contents |
| `DatabaseUnavailable` | `ANOLE_E_SYSTEM` | `connect_at_start` failed |
| `Canceled` | `ANOLE_E_STATE` | the call was canceled (a stop or drain raced it) |
| `Unexpected` | `ANOLE_E_SYSTEM` | anything not named (the text has the Zig error) |

The member names of `anole.ServerError` and `anole.TlsLoadError` are tokens
verbatim (`FileNotFound`, `InvalidListenAddress`, ...; the full list is
`error_names`).

### What each call returns

Every call may also return `ANOLE_E_INVALID` for a NULL pointer it needs, and
`ANOLE_E_UNSUPPORTED` when its feature is compiled out. Cleanup calls are
marked (C): they answer `ANOLE_OK` on an object that is already over.

| Function | Returns besides OK |
| --- | --- |
| `anole_server_create` | `ANOLE_E_INVALID` (options), `ANOLE_E_CONFIG`, `ANOLE_E_STATE` (`OneServerPerProcess`), `ANOLE_E_NOMEM` |
| `anole_server_open` | `ANOLE_E_STATE` (`State`, `NoConsumer`, `ConsumerWithoutExecutor`), `ANOLE_E_SYSTEM` (`DatabaseUnavailable`, `SystemResources`), `ANOLE_E_NOMEM` |
| `anole_server_start` | as open, plus `ANOLE_E_CONFIG` (`RouteConflict`, TLS contents), `ANOLE_E_SYSTEM` (`AddressInUse`, `AccessDenied`, `AddressNotAvailable`, `TooManyOpenFiles`, the file tokens) |
| `anole_server_listener_count` | the count (0 for no server) |
| `anole_server_listener` | `ANOLE_E_INVALID` (index, size) |
| `anole_server_set_ready` | `ANOLE_E_INVALID` (`UnknownCheck`) |
| `anole_server_drain` | `ANOLE_E_STATE` (before start) |
| `anole_server_wait` | `ANOLE_E_TIMEOUT` |
| `anole_server_reload_tls` | `ANOLE_E_STATE` (`NotRunning`, `NoTlsListener`), `ANOLE_E_SYSTEM` (file tokens), `ANOLE_E_INVALID` (content tokens, one argument), `ANOLE_E_NOMEM` |
| `anole_server_stats` | `ANOLE_E_INVALID` (size) |
| `anole_server_destroy` | (no result) |
| `anole_consumer_attach` | `ANOLE_E_STATE`, `ANOLE_E_UNSUPPORTED` (Windows, no wake), `ANOLE_E_SYSTEM`, `ANOLE_E_NOMEM` |
| `anole_consumer_fd` | -1 with a callback, for a shared consumer, on Windows |
| `anole_consumer_set_wake` | `ANOLE_E_UNSUPPORTED` (Windows, NULL wake), `ANOLE_E_SYSTEM` (fd) |
| `anole_poll`, `anole_poll_wait` | `ANOLE_E_INVALID` (alignment, flags), `ANOLE_E_TOOBIG` |
| `anole_handle_release` (C) | `ANOLE_E_INVALID` (`WrongHandleKind`) |
| `anole_req_read` | `ANOLE_E_AGAIN`, `ANOLE_E_TIMEOUT`, `ANOLE_E_GONE`, `ANOLE_E_INVALID` |
| `anole_req_respond` | `ANOLE_E_INVALID` (status, header, flags), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_respond_fd` | `ANOLE_E_INVALID` (fd, range), `ANOLE_E_SYSTEM` (dup), `ANOLE_E_GONE`, `ANOLE_E_NOMEM`, `ANOLE_E_UNSUPPORTED` (Windows) |
| `anole_req_stream_start` | `ANOLE_E_INVALID`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_stream_write` | `ANOLE_BUSY`, `ANOLE_E_INVALID` (flags), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_stream_write_wait` | `ANOLE_E_TIMEOUT`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_stream_end` | `ANOLE_E_INVALID` (trailer), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_fail` | `ANOLE_E_INVALID` (status, message), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_req_abort` (C) | `ANOLE_E_INVALID` (`WrongHandleKind`) |
| `anole_ws_accept` | `ANOLE_E_STATE` (the request is no handshake), `ANOLE_E_INVALID` (subprotocol not offered, a header the handshake writes, flags, reserved, size), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_ws_send` | `ANOLE_BUSY`, `ANOLE_E_INVALID` (type, size, flags), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_ws_close` (C) | `ANOLE_E_INVALID` (code, reason), `ANOLE_E_NOMEM` |
| `anole_ws_subscribe` | `ANOLE_E_INVALID` (topic), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_ws_unsubscribe` (C) | `ANOLE_E_INVALID` (topic), `ANOLE_E_NOMEM` |
| `anole_ws_publish` | `ANOLE_E_INVALID`, `ANOLE_E_AGAIN`, `ANOLE_E_STATE` (`NotRunning`), `ANOLE_E_NOMEM` |
| `anole_grpc_send_headers` | `ANOLE_E_INVALID` (metadata), `ANOLE_E_STATE`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_grpc_send` | `ANOLE_BUSY`, `ANOLE_E_INVALID`, `ANOLE_E_STATE`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_grpc_send_wait` | `ANOLE_E_TIMEOUT`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_grpc_finish` | `ANOLE_E_INVALID` (code, message, trailers), `ANOLE_E_STATE`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_grpc_read` | `ANOLE_E_INVALID` (n == 0), `ANOLE_E_STATE`, `ANOLE_E_GONE` |
| `anole_grpc_health_set` | `ANOLE_E_INVALID`, `ANOLE_E_STATE` (health off) |
| `anole_wt_open_stream` | `ANOLE_E_INVALID` (flags), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_wt_stream_write` | `ANOLE_BUSY`, `ANOLE_E_INVALID` (flags, direction, after end), `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_wt_stream_reset`, `anole_wt_stream_stop` (C) | `ANOLE_E_INVALID` (direction) |
| `anole_wt_stream_set_priority` | `ANOLE_E_INVALID` (above 7, or a read-only stream), `ANOLE_E_GONE` |
| `anole_wt_send_datagram` | `ANOLE_E_INVALID` (flags), `ANOLE_E_TOOBIG`, `ANOLE_E_GONE`, `ANOLE_E_NOMEM` |
| `anole_wt_max_datagram` | `ANOLE_E_GONE` |
| `anole_wt_close` (C) | `ANOLE_E_INVALID` (reason), `ANOLE_E_NOMEM` |
| `anole_db_find` | `ANOLE_E_INVALID` |
| `anole_db_query`, `anole_db_exec` | `ANOLE_E_INVALID` (value, options, flags, reserved, a NULL consumer without `req`, a `req` of another kind or another consumer's), `ANOLE_E_GONE` (a stale `req`), `ANOLE_E_STATE`, `ANOLE_E_NOMEM` |
| `anole_db_begin` | `ANOLE_E_INVALID` (options), `ANOLE_E_UNSUPPORTED` (Redis, MongoDB), `ANOLE_E_GONE` (a stale `req`), `ANOLE_E_STATE`, `ANOLE_E_NOMEM` |
| `anole_db_tx_query`, `anole_db_tx_exec` | `ANOLE_E_INVALID` (value, options: only `timeout_ms` and `ANOLE_DB_F_NO_PREPARE`; a handle of another kind), `ANOLE_E_GONE` (over, or commit/rollback/release called), `ANOLE_E_NOMEM` |
| `anole_db_tx_commit`, `anole_db_tx_rollback` | `ANOLE_E_INVALID` (a handle of another kind), `ANOLE_E_GONE` |
| `anole_db_tx_release` (C) | `ANOLE_E_INVALID` (0 or another kind) |
| `anole_db_invalidate` | `ANOLE_E_STATE`, `ANOLE_E_NOMEM` |

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
  "timeouts": { "request_ms": 30000, "write_ms": 30000, "shutdown_ms": 10000, "rewake_ms": 20 },
  "limits": { "body_max": 1048576, "inline_body_max": 65536, "max_inflight": 1024 },
  "proxy": { "trusted_hops": 1 },
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
  fixed answer), `static` (files under a directory) or `websocket` (with
  `"accept": "consumer"`, also `handler`).
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

## TLS

A listener's `tls` takes the certificate and key as files (`cert_file`,
`key_file`), as PEM text (`cert_pem`, `key_pem`) or `self_signed` for
development, plus `alpn`.

Mutual TLS is `client_auth`: `"none"` (the default), `"request"` (a
certificate is asked for and checked when the client sends one) or
`"require"` (a client without one is refused at the handshake), with the CAs
that client certificates must chain to as exactly one of `client_ca_file`,
`client_ca_pem`, `client_ca_dir` (a directory of PEM files) or
`client_ca_system: true`:

```json
{ "port": 8443, "http3": true,
  "tls": { "cert_file": "cert.pem", "key_file": "key.pem",
           "client_auth": "require", "client_ca_file": "clients-ca.pem" } }
```

The HTTP/3 endpoint follows the settings of the listener with `http3`.
A request whose client presented a certificate has `ANOLE_REQ_PEER_CERT`
in its flags; `anole_event_str(r, r->peer_cert)` returns it (DER, verified,
the leaf only): `peer_cert` is a plain span into the record, empty when
there is none. The same goes for `ANOLE_EV_WS_OPEN`, `ANOLE_EV_WT_OPEN` and
the gRPC call record (`ANOLE_GRPC_CALL_PEER_CERT`).

Certificates change without a restart:
`anole_server_reload_tls(s, flags, cert, key)` (both `anole_str`) with both
empty reads every TLS listener's sources again; with both set it swaps in
new ones for every TLS listener (and HTTP/3), as file paths or, with
`ANOLE_TLS_F_PEM`, as PEM text, and they become what later empty-argument
reloads read. Handshakes under way finish on the old certificate, and session
tickets issued before still resume. A certificate that does not load leaves
the old one in place (`ANOLE_E_INVALID`: `InvalidCertificate`, `InvalidKey`,
`KeyMismatch`, or only one of the two given; `ANOLE_E_SYSTEM` for a file that
cannot be read: `CertificateFileUnreadable`, `KeyFileUnreadable`, with
`anole_last_errno`; `ANOLE_E_STATE`: `NotRunning`, `NoTlsListener`). With
`ANOLE_SERVER_F_SIGNALS`, SIGHUP does the same as the empty reload. A reload
changes the server's own certificate only; it re-reads the client CA source
the configuration names (`client_ca_file`, `client_ca_dir` or the system
store again; `client_ca_pem` as given).

Behind a proxy, `deployment` (`"behind_proxy"`, `"anole_lb"`, `"platform"`)
and `proxy.trusted` (addresses, CIDR networks, `"loopback"`, `"private"`,
`"link_local"`) say which peers' `X-Forwarded-For` to read: the client's
address in `remote_addr` is the rightmost address in it that is not trusted
([config.md](config.md#deployment)). `proxy.trusted_hops` is the fixed-count
alternative (how many proxies in front), with
`proxy.trust_forwarded_proto` (default true: `X-Forwarded-Proto` decides
`ANOLE_REQ_SECURE`) and `proxy.trust_forwarded_host` (default false). A
listener's `proxy_protocol` expects a PROXY protocol (v1 or v2) header on
every connection (PROXY protocol is per listener); `proxy_protocol_from`
limits who may send one (addresses or CIDR networks).

`anole_server_listener_count(s)` and `anole_server_listener(s, i, &info)` describe the
configuration's listeners, in order, from `anole_server_create` to
`anole_server_destroy`: `name`, `address` (`"127.0.0.1:8080"`, `"[::]:8443"`,
`"unix:/run/app.sock"`: the bound one once listening), `port` (the real one
for port 0), `udp_port` (HTTP/3's, 0 when the listener serves none), `flags`
(`ANOLE_LISTENER_F_TLS`, `_HTTP1`, `_HTTP2`, `_HTTP3`, `_UNIX`,
`_PROXY_PROTOCOL`), `state` (`ANOLE_LISTENER_PENDING`, `_LISTENING`,
`_FAILED`, `_CLOSED`) and, when start failed binding it, `error_name` and
`error_errno`. Node's `server.address()` and an EADDRINUSE error are built
from it.

## Environment and .env

`environment` ("development" or "production") and `deployment` are resolved
once, at `anole_server_create`: the key, else `ANOLE_ENV` / `ANOLE_DEPLOYMENT`
in the process environment, else production and standalone. libanole reads
no `.env` file itself and treats a build without `environment` as
production, so a binding that leaves it out gets JSON records in its log
callback. Resolution failures are `ANOLE_E_CONFIG` from `anole_server_create`
(`InvalidEnvironmentVariable`, `InvalidProxyNetwork`, `DeploymentUnavailable`),
with the reason in `anole_last_error`. `anole_server_listener` reports the
filled address and port before start, so a binding sees `$PORT` at once.

`anole_dotenv_read(dir, environment, fn, ud)` reads the `.env` files Anole
reads for the environment (development: `.env.development.local`,
`.env.local`, `.env.development`, `.env`; the first file with a key wins;
`ANOLE_ENV` is never passed on) and calls `fn` once per variable; production
reads nothing. It does not touch the process environment: the binding sets
each variable that is not already set, in its language, before
`anole_server_create`. One parser in every language, so the dialect (quotes,
multi-line values, comments) and the order are the same everywhere.

- anole-node: `environment` = the option, else `ANOLE_ENV`, else
  `"production"` when `NODE_ENV === "production"`, else `"development"`; in
  development call `anole_dotenv_read(root, "development", ...)` and set
  `process.env[k] = v` when it is undefined; pass `environment` explicitly in
  the JSON. Next.js loads the same files in the same order itself.
- anole-py: `environment` = the option, else `ANOLE_ENV`, else
  `"production"`; in development `os.environ.setdefault(k, v)` per entry; pass
  it in the JSON.

libanole then sees `ANOLE_DEPLOYMENT`, `ANOLE_PROXY_TRUSTED`, `PORT`,
`DATABASE_URL`... through `getenv`.

## Keys and defaults

Every option of Zig's `ServerOptions` has a key here with the same name and
the same default, or is listed below with the reason it has none; a test
holds the two together (`src/capi/parity.zig`, `include/anole.schema.json`).
A duration in Zig (`anole.Duration`) is `<name>_ms` here, and `null` means
none.

| Key | Default | Zig |
| --- | --- | --- |
| `timeouts.request_ms` | 30000 | `timeouts.request`: the consumer deadline (504); the core gets the longest plus 5 s |
| `timeouts.read_header_ms` | 10000 | `timeouts.read_header` |
| `timeouts.write_ms` | 30000 | `timeouts.write`: a write the peer does not take ends the response; replaces the request deadline once a stream or file body has started |
| `timeouts.keepalive_ms` | 75000 | `timeouts.keepalive` |
| `timeouts.idle_park_ms` | 1000 | `timeouts.idle_park` |
| `timeouts.shutdown_ms` | 10000 | `timeouts.shutdown` |
| `limits.body_max` | 1048576 | `limits.body_max` |
| `limits.max_head_size` | 16384 | `limits.max_head_size` (431 past it) |
| `limits.max_header_count`, `max_param_count`, `max_query_count`, `max_form_count`, `max_multiform_count` | 32, 8, 32, 32, 32 | `limits.*` |
| `limits.max_connections` | 0 | `limits.max_connections` (0: the open-file limit) |
| `limits.max_requests_per_connection` | null | `limits.max_requests_per_connection` |
| `limits.ws_max_message` | 1048576 | `limits.ws_max_message` |
| `proxy.trusted`, `trusted_hops`, `trust_forwarded_proto`, `trust_forwarded_host` | null, 0, true, false | `proxy.*` |
| `environment`, `deployment`, `error_detail` | null, null, null | `environment`, `deployment`, `error_detail` (null: `ANOLE_ENV` else production; `ANOLE_DEPLOYMENT` else standalone; on in development) |
| `listeners[].address`, `port`, `proxy_protocol` | null, null, null | `Listener.*` (null: the deployment's default: `127.0.0.1`, 8080 or `$PORT`, off or on under `anole_lb`) |
| `request.require_host`, `decompress`, `keep_buffers` | true, true, false | `request.*` |
| `response.write_buffer_size`, `date`, `default_content_type`, `max_header_count`, `brotli_quality` | 16384, true, "text", 64, 5 | `response.*` (`default_content_type` by tag name; null: none) |
| `http2.*` | 250 streams, ..., `enable_connect_protocol` false | `http2.*` (`max_concurrent_streams`, `stream_window`, `stream_window_reading`, `tunnel_window`, `reading_window_budget`, `connection_window`, `max_header_list_size`, `stream_reset_burst`, `stream_reset_rate`, `max_continuations`, `refused_stream_burst`, `refused_stream_rate`, `enable_connect_protocol`, `inline_no_wait`) |
| `http3.address`, `port`, `max_streams_bidi`, `validate_address`, `idle_timeout_ms`, `alt_svc`, `early_data`, `prefer_v2`, `sockets`, `enable_connect_protocol`, `inline_no_wait` | null, null, 100, false, 30000, true, false, true, null, true, true | `http3.*` |
| `errors` | "auto" | `errors` ("auto", "json", "text") |
| `routes[].websocket.accept`, `subprotocols`, `compression`, `close_on_drain`, `origins` | "auto", [], true, true, [] | `websocket.UpgradeOptions` (`subprotocols`, `compression`, `close_on_drain`, `allowed_origins`); `accept` is the ABI's own: "consumer" hands each handshake to the application |
| `executors` | 0 | `executors` (0 is `.auto`, n is `.exact(n)`) |
| `databases[].timeout_ms` | 30000 | the connectors' `timeout` (0 is null: none); also a transaction's bound when its `timeout_ms` is 0 |
| `databases[].mongodb.max_connections`, `databases[].sqlite.ping_timeout_ms` | null (100), 2000 | `mongodb.Options.max_connections`, `sqlite.Options.ping_timeout` |

Keys with no Zig option: `limits.inline_body_max`, `max_inflight`, `queue`,
`stream_high_water`, `ws_high_water`, `db_result_max`; `timeouts.rewake_ms`;
`routes`, `middleware`, `grpc`, `observe`, `databases`.

Zig options with no key, and why:

| Zig option | Why the ABI has none |
| --- | --- |
| `http`, `https`, `listen_tls_http3` | shorthands for a listener; the ABI names every listener in `listeners`, with `http3: true` |
| `http3.hq_interop_root` | QUIC interop runner only |
| `http3.webtransport` | on when a route is `webtransport` |
| `error_handler` | a function: the language answers its own errors |
| `max_stack_size` | stacks run Anole's native work only, never language handlers |
| `raise_fd_limit` | always on under the ABI |
| `signals` | the `ANOLE_SERVER_SIGNALS` flag of `anole_server_create` |
| `env_files` | the binding reads `.env` files into its language's environment (`anole_dotenv_read`) |
| `process`, `restart_timeout` | embedded mode: no hand-off, SIGUSR2, LISTEN_FDS or sd_notify |
| `blocking` | the ABI starts a pool when SQLite is configured |
| `client` | no outbound client in the ABI |
| `websocket.UpgradeOptions.max_message_size`, `timeout`, `deflate`, `drain_reason` | `limits.ws_max_message` applies to every socket; sockets have no deadline of their own; permessage-deflate runs on its defaults; the drain's close carries the default reason |
| `websocket.UpgradeOptions.headers` | Zig only: the consumer passes headers per `anole_ws_accept` |

The middleware keys follow the same rule for durations: `jwt.leeway_ms`
(60000) and `cors.max_age_ms` (600000).

## Requests

A body of up to `limits.inline_body_max` comes inline (`ANOLE_REQ_BODY_INLINE`,
the `body` span). A larger one (`ANOLE_REQ_BODY_STREAM`) is read with
`anole_req_read`: with timeout 0 it never blocks (`ANOLE_E_AGAIN`, then
`ANOLE_EV_BODY` when more is there); with a timeout it blocks the calling
thread. A body past `limits.body_max` ends the request with 413.

## Responses

- `anole_req_respond(r, status, headers, n, body, len, flags)`: the whole answer.
  The body is copied, or borrowed with `ANOLE_BODY_BORROW` (bindings borrow
  bodies above 64 KiB and copy small ones). Compression, the response cache
  and the access log run on Anole's side afterwards.
- `anole_req_respond_fd(r, status, headers, n, fd, offset, len)`: part of a
  regular file, sent by Anole (`sendfile` where it can).
- `anole_req_stream_start`, `anole_req_stream_write` (or `anole_req_stream_write_wait`
  for a thread that may block), `anole_req_stream_end` with trailers: a streamed
  answer. `ANOLE_BUSY` past `limits.stream_high_water`; wait for
  `ANOLE_EV_WRITABLE`. The request deadline ends once a stream has started
  (the same on every protocol and for `anole_req_respond_fd`); each write the
  peer does not take within `timeouts.write_ms` ends the stream
  (`ANOLE_EV_ABORT`).
- `anole_req_fail(r, status, message)`: an error answer in the server's
  configured error format (the same body Anole's own 404, 413 and 504
  have): status 400-599, or 0 for 500; `message` (UTF-8, at most 4096
  bytes, copied) is the detail.
- `anole_req_abort(r)`: drop the request without an answer (Zig's
  `res.abort()`): HTTP/1.1 closes the connection, HTTP/2 resets the stream
  (CANCEL), HTTP/3 cancels it (`H3_REQUEST_CANCELLED`); a stream under way is
  cut short. A cleanup call.
- `anole_handle_release(h)`: the generic cleanup (see Handles).

What borrowing saves, per call (Anole's own copies of the body before the
protocol writes it):

| Call | not borrowed | borrowed | `ANOLE_EV_SENT` for a borrow |
| --- | --- | --- | --- |
| `anole_req_respond`, HTTP/1.1 and HTTP/3 | 2 (into the slot, then the arena) | 0 | once the answer is written |
| `anole_req_respond`, HTTP/2 | 2 | 1 (the arena) | as soon as the answer is applied |
| `anole_req_stream_write` | 1 | 0 | once the chunk is written |
| `anole_ws_send` | 1 | 0 | once the message is written |
| `anole_wt_stream_write` | 1 | 1 (taken for the API's sake) | at once |

HTTP/2 copies a borrowed whole body because its writer cuts DATA frames from
the body after the call returns; zero-copy would need the request slot to
live until the last frame. Borrowing never costs more than copying.

`ANOLE_BODY_BORROW` is bit 0 of every send-type call's flags: a call that
answers `>= 0` produces exactly one `ANOLE_EV_SENT` for that (data, len),
zero length included, even when the client goes away first; a call that
answers `< 0` took nothing and produces none. The record is built by the
call itself, which answers `ANOLE_E_NOMEM` and takes nothing if it cannot,
and it is never lost to a full queue. Where borrowing pays: HTTP/1.1 whole
bodies, streamed writes, WebSocket sends. Whole bodies answered over HTTP/2
and HTTP/3, and WebTransport writes and datagrams, are copied by Anole all
the same (`ANOLE_EV_SENT` then comes early). `ANOLE_EV_STOPPED` releases
everything still borrowed: after it, and after `anole_server_destroy`
returns, no borrowed memory is read and no `ANOLE_EV_SENT` comes.

## WebSocket

A `websocket` route upgrades over HTTP/1.1, HTTP/2 (RFC 8441, only with
`"http2": {"enable_connect_protocol": true}`, off by default since 0.3:
about twice the CPU per message of HTTP/1.1) and HTTP/3 (RFC 9220). Who answers the handshake is the route's `"accept"`.

**Auto endpoints** (`"accept": "auto"`, the default). Anole answers the
handshake: origins (`"origins"`, 403 otherwise), permessage-deflate, and
subprotocols (`"subprotocols": ["graphql-transport-ws"]`, most preferred
first; the first the client offered is selected and echoed).
`ANOLE_EV_WS_OPEN` carries the upgrade request and the selected one in its
`subprotocol` span. Each whole message (inflated, UTF-8 checked) is an
`ANOLE_EV_WS_MESSAGE`; the end is `ANOLE_EV_WS_CLOSE` with the code (1005
without one, 1006 when the connection ended without a close). Messages
waiting for a consumer that is behind are bounded per executor by bytes as
well as by `limits.queue` (the larger of 16 x `limits.ws_high_water` and
2 x `limits.ws_max_message`): past that, the sockets feeding it are not read
until it catches up. `anole_ws_send` queues a message (`ANOLE_BUSY` past
`limits.ws_high_water`, then `ANOLE_EV_WRITABLE` with the socket as
`ev.handle`), `anole_ws_close` sends a close.

**Handshakes the application decides** (`"accept": "consumer"`). Anole
checks it is a handshake and the route's `origins` (403 natively), then
sends it as `ANOLE_EV_WS_UPGRADE`: an `anole_request_event` whose handle is
an `anole_req`, under the route's `timeout_ms` (else `timeouts.request_ms`)
and `limits.max_inflight`. Answer it with `anole_ws_accept` (a subprotocol
the client offered, extra headers such as `Set-Cookie`), which returns the
`anole_ws` handle at once, or with any answer a request takes
(`anole_req_respond` 401 or 403 with a body, `anole_req_stream_*`,
`anole_req_respond_fd`, `anole_req_fail`, `anole_req_abort`), which refuses
the socket. After an accept there is no `ANOLE_EV_WS_OPEN` (the accept is
the open): sends, closes and topic changes on the new handle work at once
and wait until the handshake's answer is out; then come
`ANOLE_EV_WS_MESSAGE`s and one `ANOLE_EV_WS_CLOSE`. If the answer cannot be
written (the client left), the handle gets `ANOLE_EV_WS_CLOSE` with 1006
and nothing else. No answer by the deadline: 504, the handle goes stale and
a late accept answers `ANOLE_E_GONE`; the client leaving first gives
`ANOLE_EV_ABORT`, as for any request.

A route may also carry `handler`: plain requests go to it as
`ANOLE_EV_REQUEST` and handshakes to `websocket.handler` as
`ANOLE_EV_WS_UPGRADE`, so one app sees every request on a path (a catch-all
`/*` route serves a whole app):

```json
{"path": "/graphql", "websocket": {"handler": 3, "subprotocols": ["graphql-transport-ws"]}}
{"path": "/chat", "timeout_ms": 5000, "websocket": {"handler": 2, "accept": "consumer"}}
{"path": "/*", "handler": 1, "websocket": {"handler": 1, "accept": "consumer", "origins": ["*"]}}
```

How the usual APIs map onto it:

| API | ABI |
| --- | --- |
| ASGI `websocket.accept` (subprotocol, headers) | `anole_ws_accept` |
| ASGI `websocket.close` before accept | `anole_req_respond` 403 |
| ASGI `websocket.http.response.start` (denial response) | `anole_req_stream_start` |
| Bun `server.upgrade(req, { headers })` | `anole_ws_accept` |
| Bun `fetch` returning a `Response` instead | `anole_req_respond` |
| `ws` `verifyClient` / `handleProtocols` | the decision before `anole_ws_accept` |

Topics are Anole's: `anole_ws_subscribe`, `anole_ws_unsubscribe`, and
`anole_ws_publish(server, topic, ...)` fans out on Anole's threads without
entering the language. Publishes to one topic reach every subscriber in the
order they were taken (from one thread: call order); publishes to different
topics, and a publish against an `anole_ws_send` to the same socket, are
not ordered against each other. A publish waits for no subscriber: each one
has up to `limits.ws_high_water` bytes queued for it; past that, publishes
skip it, and a subscriber whose send stays stuck that way for a second is
closed. Publishes still being fanned out are bounded too (64 per executor,
and the larger of 16 x `limits.ws_high_water` and 2 x `limits.ws_max_message`
bytes): past the bound `anole_ws_publish` answers `ANOLE_E_AGAIN` and sends
nothing (a caller that retries the refused publish before the next keeps
the order). A drain closes sockets with 1001.

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
case ANOLE_EV_WT_STREAM:    /* the peer opened a stream: ev.handle, its session, ANOLE_WT_F_UNI */
case ANOLE_EV_WT_DATA:      /* bytes of a stream in order, ANOLE_WT_F_FIN with the last */
case ANOLE_EV_WT_DATAGRAM:  /* one datagram of the session */
case ANOLE_EV_WT_STREAM_RESET: case ANOLE_EV_WT_STREAM_STOP: /* the peer's code */
case ANOLE_EV_WT_DRAIN:     /* the server (or the peer) is draining */
case ANOLE_EV_WT_CLOSE:     /* code, reason, which side; the session and its streams are stale */

anole_wt_stream s;
anole_wt_open_stream(w, 0 /* or ANOLE_WT_F_UNI */, &s);   /* the handle is good at once */
anole_wt_stream_write(s, data, len, ANOLE_WT_F_FIN);       /* ANOLE_BUSY: wait for ANOLE_EV_WRITABLE */
anole_wt_stream_set_priority(s, 2);                   /* ABI 0.8: 0 most urgent .. 7 least; 3 by default */
anole_handle_release(s);                              /* the end above still goes out */
anole_wt_send_datagram(w, buf, n, 0);
anole_wt_close(w, 0, (anole_str){"bye", 3});
```

- One task on the connection's executor runs each session with the
  session calls that never wait, so a session costs no thread and no task
  per stream; what a consumer asks for wakes it like a WebSocket sender.
- Streams in either direction, opened by either side. The peer's stream
  data comes in `ANOLE_EV_WT_DATA` records of at most 32 KiB, in order;
  a consumer that falls behind holds back the reading (the record budget,
  then QUIC flow control). Writes are copied and queued (a write with
  `ANOLE_BODY_BORROW` is copied too, and gets its `ANOLE_EV_SENT`, so a
  binding's one borrowing helper works here as everywhere):
  `limits.stream_high_water` bytes waiting answers `ANOLE_BUSY`, then
  `ANOLE_EV_WRITABLE` comes for the stream.
- `anole_wt_stream_set_priority(s, urgency)` (ABI 0.8) sets a stream's
  RFC 9218 urgency, 0 (most urgent) to 7 (least); every stream starts at
  3, and streams of one urgency take turns packet by packet. A more
  urgent stream's bytes go out before any less urgent one's, so a busy
  stream at a low number starves the higher ones: mark audio or control
  2, not 0. A stream holds at most 1 MiB unacknowledged before a write
  waits (`ANOLE_BUSY`), and a connection 4 MiB across its streams.
- Every stream must be released (`anole_handle_release`) or go with
  its session: the peer may open a new stream only as earlier ones are
  released. A release resets a sending side not ended with
  `ANOLE_WT_F_FIN` and stops a receiving side not read to its end; one
  written with `ANOLE_WT_F_FIN` first sends everything. Once the session
  is over its streams answer `ANOLE_E_GONE`, release too, and that can
  come before `ANOLE_EV_WT_CLOSE` is read: the peer may close at any
  time. Release a stream before an answer after which the peer may
  close.
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
anole_db_value p[] = {{ANOLE_DB_TYPE_TEXT, 0, {.s = {"milk", 4}}}};
anole_db_exec(db, consumer, sql_insert, p, 1, NULL, /*user_data*/ 7);
anole_db_options o = {sizeof o, ANOLE_DB_F_COALESCE, 0, /*cache_ttl_ms*/ 5000, 0, {"notes", 5}};
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
  - `timeout_ms` interrupts the statement (`ANOLE_E_TIMEOUT`, 504). Every
    query is bounded: 0 takes the database's `timeout_ms` (30 s by default;
    0 there lifts it), and `ANOLE_DB_TIMEOUT_NONE` lifts it for one call.
  - `req` ties the query to the `anole_req` or `anole_grpc_call` it serves.
    It then runs on that request's executor (its pools and cache) and its
    answer goes to the consumer that polled the request, so the `anole_consumer`
    argument may be NULL (a non-NULL one must be that consumer). When the
    request is aborted or passes its deadline, the query is canceled and
    answers `ANOLE_E_GONE` (`http_status` 0); a request that was answered
    leaves it running, bounded by `timeout_ms`. A stale `req` is
    `ANOLE_E_GONE` from the call, nothing queued; a handle of another kind
    is `ANOLE_E_INVALID`.
  - `ANOLE_DB_F_COALESCE`: identical reads in flight at once on one executor
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
  - An error names its table (or collection) in `table`, when the database
    says.
- A database can also set, beside its kind's keys: `timeout_ms` (above),
  `errors` (a class name to the status it answers with, as
  `anole.db.ErrorMap`: `{"foreign_key": "unprocessable_entity"}`) and, for
  PostgreSQL, Redis and MongoDB, a client certificate (`client_cert_file` and
  `client_key_file`, or `client_cert_pem` and `client_key_pem`),
  `insecure_skip_verify` and `ping_timeout_ms`. SQLite takes `uri`,
  `statement_cache_size` and `ping_timeout_ms`; MongoDB `idle_timeout_ms`,
  `heartbeat_ms`, `retry_reads`, `retry_writes`, `connect_at_start`
  (`max_connections` 0 is refused, as for every connector).
- Queries can be queued from `anole_server_open` (or `anole_server_start`) until the server stops.
  Queries still running at the stop get no answer.

### Transactions

SQLite and PostgreSQL. `anole_db_begin` answers with an `anole_db_tx`
handle in the `ev.handle` of its `ANOLE_EV_DB_RESULT`; from then on the
consumer sends `anole_db_tx_query` and `anole_db_tx_exec` (they take
`anole_db_options` but only `timeout_ms` and `ANOLE_DB_F_NO_PREPARE` apply),
and ends it with `anole_db_tx_commit` or `anole_db_tx_rollback`. Calls on
one transaction run one at a time, in the order made, on one connection of
one executor; the consumer may queue several without waiting for answers,
and each answer is an `ANOLE_EV_DB_RESULT` whose `ev.handle` is the
transaction.

```c
anole_db_tx_options o = {sizeof o, 0, ANOLE_DB_ISOLATION_SERIALIZABLE, /*timeout_ms*/ 5000, 0, /*req*/ r};
anole_db_begin(db, NULL, &o, 1);              /* answer: ev.handle = the transaction */
anole_db_tx_exec(tx, debit, p1, 2, NULL, 2);
anole_db_tx_exec(tx, credit, p2, 2, NULL, 3);
anole_db_tx_commit(tx, 4);                    /* error_class SERIALIZATION: lost a race, 409 */
```

`anole_db_tx_options.timeout_ms` bounds the whole transaction, idle time
included (0: the database's `timeout_ms`; `ANOLE_DB_TIMEOUT_NONE`: none).
`req` ties it to a request as for a query. How it ends, and what its queued
and running calls answer:

| How it ends | Calls queued or running | Then |
| --- | --- | --- |
| `anole_db_tx_commit` / `_rollback` | run first, answered normally | COMMIT/ROLLBACK answered |
| `anole_db_tx_release` | `ANOLE_E_GONE` | ROLLBACK, not answered |
| its `timeout_ms` | `ANOLE_E_TIMEOUT` (504) | ROLLBACK |
| its request aborted or past its deadline | `ANOLE_E_GONE` | ROLLBACK |
| its request answered normally | nothing: it goes on, bounded by `timeout_ms` | |
| the server stops | no answer | ROLLBACK |

A later call on the stale handle returns `ANOLE_E_GONE` at once, and
`anole_last_error` says which ending it was. `anole_db_tx_release` (or
`anole_handle_release`) is the cleanup call for finalizers: it rolls back an
open transaction and is `ANOLE_OK` on one that is over. A failed statement does
not end the transaction: PostgreSQL then refuses every later statement
until the rollback (SQLSTATE 25P02, `SAVEPOINT` recovers part of it), SQLite
keeps what the others did. A read-write SQLite transaction holds the
database's writer, so every other write waits: a forgotten transaction
blocks writes for at most its `timeout_ms`.

How bindings wrap it: a `pg`-style client keeps no connection until a
`BEGIN` statement (`BEGIN`/`START TRANSACTION` becomes `anole_db_begin`,
statements while open `anole_db_tx_query`, `COMMIT`/`ROLLBACK` the matching
calls, `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` plain statements, `release()`
`anole_db_tx_release` if still open); a `db.transaction(fn)` helper commits
on return, rolls back on a throw and retries on `error_class` SERIALIZATION or
DEADLOCK; a DB-API connection begins on its first `execute` and maps
`commit()`/`rollback()`/`close()` one to one. A pinned connection without a
transaction (session `SET`, temporary tables across calls, `LISTEN`) is not
offered; use `SET LOCAL` inside a transaction.

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
- Cells: `bool` is `ANOLE_DB_TYPE_BOOL`; `int2`, `int4`, `int8`, `oid` are
  `ANOLE_DB_TYPE_INT`; `float4`, `float8` are `ANOLE_DB_TYPE_FLOAT`; `bytea` is
  `ANOLE_DB_TYPE_BLOB`; every other type is `ANOLE_DB_TYPE_TEXT` in PostgreSQL's text
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
- `ANOLE_DB_F_WRITE` means nothing here (any connection runs any
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
anole_db_value p[] = {{ANOLE_DB_TYPE_TEXT, 0, {.s = {"user:7", 6}}},
                      {ANOLE_DB_TYPE_BLOB, 0, {.s = {data, len}}},
                      {ANOLE_DB_TYPE_TEXT, 0, {.s = {"EX", 2}}},
                      {ANOLE_DB_TYPE_INT, 0, {.i = 60}}};
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
  cells. `ANOLE_DB_TYPE_ARRAY` (`i` items follow, each a whole subtree) and
  `ANOLE_DB_TYPE_MAP` (`i` key, value pairs follow) are the inner nodes; bulk
  strings are `ANOLE_DB_TYPE_BLOB` (bytes: a binding decodes UTF-8 by default
  and offers the bytes, as ioredis and redis-py do); status replies
  (`"OK"`) are `ANOLE_DB_TYPE_TEXT`; integers `ANOLE_DB_TYPE_INT`; nil
  `ANOLE_DB_TYPE_NULL`; `ANOLE_DB_TYPE_ERROR` is an error reply inside another
  (EXEC's). A binding rebuilds the reply with one recursive walk; for a
  flat reply (`GET`, `LRANGE`) it reads the cells after the first. Why
  the same record rather than one of its own: one event, one parser and
  one size limit for every database, and the cell types it needs already
  exist but for three.
- `anole_db_exec` runs the command for its effect: no cells, and
  `changes` holds the reply when it is an integer (`DEL`, `INCR`,
  `RPUSH`...).
- `ANOLE_DB_F_COALESCE` and `cache_ttl_ms` apply only to commands that just
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
anole_db_value p[] = {{ANOLE_DB_TYPE_BLOB, 0, {.s = {filter, filter_len}}},
                      {ANOLE_DB_TYPE_BLOB, 0, {.s = {options, options_len}}}};
anole_db_query(db, consumer, (anole_str){"find orders", 11}, p, 2, NULL, 1);
/* ANOLE_EV_DB_RESULT: a row per document, each cell ANOLE_DB_TYPE_BSON */
```

- `sql` names the operation and the collection, and optionally another
  database than the configured one: `"find orders"`, `"aggregate events
  analytics"`. The operations are the drivers' methods of the same name:
  `find`, `findOne`, `aggregate`, `countDocuments`, `insertOne`,
  `insertMany`, `updateOne`, `updateMany`, `replaceOne`, `deleteOne`,
  `deleteMany`, and `runCommand` (a database's; `sql` is `"runCommand"` or
  `"runCommand <database>"`, the escape hatch for everything else:
  indexes, `findAndModify`, `distinct`, admin commands).
- The parameters are BSON documents (`ANOLE_DB_TYPE_BLOB`), in the order the
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
  give a row per document, its cell `ANOLE_DB_TYPE_BSON` (the document's
  bytes); `countDocuments` one `ANOLE_DB_TYPE_INT`; the writes one BSON row
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
  the call and goes to the server as `maxTimeMS`. `ANOLE_DB_F_COALESCE` and
  `cache_ttl_ms` apply to `find`, `findOne`, `countDocuments` and an
  `aggregate` that does not end in `$out` or `$merge`.
- Errors carry MongoDB's code in `error_code` (`"11000"` for a duplicate
  key: `ANOLE_DB_ERR_UNIQUE`, 409); no primary or an unreachable server is
  `ANOLE_DB_ERR_UNAVAILABLE` (503). Retryable reads and writes are retried
  once, as the drivers do.
- Transactions (`anole_db_begin`) are SQLite and PostgreSQL only; change streams are not part of the ABI yet.

## Brokers

Brokers are configured under `"brokers"` (one object per broker, with a
`"name"` and exactly one kind key, `"nats"` or `"kafka"`) and used through
`anole_nats_*` and `anole_kafka_*` calls. They are built with `-Dnats` and
`-Dkafka` (`anole_has_feature("nats")`, `anole_has_feature("kafka")`).

```json
"brokers": [
  { "name": "events",
    "nats": { "url": "tls://nats.internal:4222", "creds_file": "/run/secrets/app.creds",
              "connections": "one",
              "jetstream": { "streams": [ { "name": "ORDERS", "subjects": ["orders.>"] } ],
                             "consumers": [ { "stream": "ORDERS", "durable": "billing" } ] } },
    "timeout_ms": 30000, "retry": { "attempts": 5 } }
]
```

`nats` takes `url` (`nats://`, `tls://`, a comma-separated list; `user:password@`
or `token@` in it log in), `name`, one login (`token`, `user` and `password`,
`nkey_seed` or `nkey_seed_file`, `creds` or `creds_file`), TLS (`ca_file` or
`ca_pem`, `client_cert_file` and `client_key_file` or their `_pem` forms,
`insecure_skip_verify`, `tls_first`, `tls_required`), `connections` (`"one"`,
the default, keeps publishes ordered across the app; `"per_executor"`),
`connect_timeout_ms`, `connect_at_start`, `ping_interval_ms`,
`max_outstanding_pings`, `no_echo`, `reconnect`, `limits` and `jetstream`
(`domain`, `streams`, `consumers`, created or updated when the server starts).
`timeout_ms` bounds requests that have none of their own; `retry` is what
`ANOLE_NATS_F_RETRY` requests retry with (only on no-responders: the request
was never delivered).

**Publishing never waits.** `anole_nats_publish` copies the message and
returns: `ANOLE_OK`, `ANOLE_BUSY` (taken, but the queue is past half its
limit), or `ANOLE_E_AGAIN` (not taken: the queue is full; the consumer gets
`ANOLE_EV_NATS_WRITABLE` when there is room). A send that blocks on the
network would stall whatever lock the caller holds.

**Requests and JetStream publishes** return at once; the answer is one
`ANOLE_EV_NATS_REPLY` to the consumer given, with the caller's `user_data`:
`status` is `ANOLE_OK`, `ANOLE_E_TIMEOUT`, `ANOLE_E_BROKER` (`error_class`
`UNAVAILABLE` for no responders or a lost connection, `OTHER` for a refusal;
`error_code` says which: `no_responders`, `timeout`, `outbound_full`, a
JetStream `err_code`) or `ANOLE_E_GONE` (the request it served ended first).
`http_status` is what Anole's own handlers would answer (503, 504, 500).

**Subscriptions** (`anole_nats_subscribe`, with a queue group when several
processes share the work) deliver `ANOLE_EV_NATS_MSG` records on the consumer
given. Delivery waits for room in the consumer's ring; meanwhile the
subscription's own queue applies its `overflow` policy (`ANOLE_NATS_DROP_*`,
`ANOLE_NATS_CLOSE`), and the drops are counted in the
`ANOLE_EV_NATS_SUB_END` record (`dropped`). `anole_nats_unsubscribe` (or
`anole_handle_release`) ends one.

**JetStream consumption** (`anole_nats_js_consume`) pulls with credit: it
asks for more only while fewer than `max_inflight` messages are unacked, so
nothing is dropped. Each message is an `ANOLE_EV_NATS_JS_MSG` with its own
`anole_nats_msg` handle, owing `anole_nats_ack` (`ANOLE_NATS_ACK`,
`ANOLE_NATS_NAK` with a delay, `ANOLE_NATS_TERM`, `ANOLE_NATS_PROGRESS`) or
`anole_handle_release`, which is a NAK. An unanswered message is redelivered
by the server after the consumer's `ack_wait`.

At the stop, subscriptions end without events (the consumer's last event is
`ANOLE_EV_STOPPED`). `anole_nats_find` looks a broker up by name and
`anole_nats_index` gives its place in `"brokers"`.

### Kafka

```json
"brokers": [
  { "name": "log",
    "kafka": { "brokers": ["kafka-1:9093"], "ca_file": "/etc/ssl/kafka-ca.pem",
               "sasl": { "mechanism": "SCRAM-SHA-512", "username": "app", "password": "..." },
               "producer": { "acks": "all", "compression": "zstd" } } }
]
```

`kafka` takes `brokers` (`host:port` entries; null reads `KAFKA_BOOTSTRAP_SERVERS`,
then `KAFKA_URL`, else `localhost:9092`), `client_id`, TLS (`tls`, or any of
`ca_file`/`ca_pem`, `client_cert_file` and `client_key_file` or their `_pem`
forms, `insecure_skip_verify`), `sasl` (`mechanism` `"PLAIN"`,
`"SCRAM-SHA-256"` or `"SCRAM-SHA-512"`, `username`, `password`),
`connect_timeout_ms`, `request_timeout_ms`, `metadata_max_age_ms`,
`connect_at_start` and `producer` (`acks` `"none"`, `"leader"` or `"all"`,
`idempotent` (needs `"all"`), `linger_ms`, `batch_bytes`, `buffer_bytes`,
`compression` `"none"`, `"gzip"`, `"zstd"` or `"lz4"`, `delivery_timeout_ms`,
`metadata_wait_ms` (default 5000: how long a record for a topic the cluster
does not list yet waits for it before `UNKNOWN_TOPIC_OR_PARTITION`),
`max_request_bytes`). `timeout_ms` of the broker bounds `anole_kafka_flush`.
There is one producer per broker, so records of a key keep their order across
the calls of every thread. The partitioner is Java's (murmur2 of the key),
so keys land where Java producers put them.

**Producing never waits.** `anole_kafka_produce` copies the record and
returns: `ANOLE_OK`, `ANOLE_BUSY` (taken; the buffer is past half), or
`ANOLE_E_AGAIN` (not taken: `producer.buffer_bytes` are waiting; the consumer
gets `ANOLE_EV_KAFKA_WRITABLE` when there is room). Unless
`ANOLE_KAFKA_F_NO_REPORT`, the record's fate is one `ANOLE_EV_KAFKA_DELIVERY`
with the caller's `user_data`: `status` `ANOLE_OK` (`partition`, `offset`,
`timestamp_ms`), `ANOLE_E_TIMEOUT` (`delivery_timeout_ms`) or `ANOLE_E_BROKER`
(`error_class` `UNAVAILABLE` or `OTHER`; `error_code` is the Kafka error name,
such as `MESSAGE_TOO_LARGE`, or one of `buffer_full`, `no_broker`, `closing`,
`delivery_pending`). `anole_kafka_flush` answers with a delivery event whose
topic is empty once everything queued before it is acknowledged or failed.

**Groups.** `anole_kafka_subscribe` joins a consumer group as one member.
Each assigned partition delivers `ANOLE_EV_KAFKA_RECORDS`: at most
`max_batch` records of that partition, in order, and never a second batch of
the partition before the first is answered. `anole_kafka_batch_done` marks the
records processed (their offsets are committed with the next commit);
`anole_kafka_batch_retry` delivers the same records again after a delay, and
the partition waits meanwhile. Dead letters are the binding's: produce the
record to a dead-letter topic with `anole_kafka_produce`, then call
`anole_kafka_batch_done`. A rebalance first sends `ANOLE_EV_KAFKA_REVOKE`; a
batch not answered within `rebalance_timeout_ms` goes stale (answering it is
`ANOLE_OK` for `anole_kafka_batch_done`, `ANOLE_E_GONE` for `_retry`, and its
offsets are not committed). `ANOLE_EV_KAFKA_ASSIGN` follows the join.
`anole_kafka_group_close` (or `anole_handle_release`) commits the done batches
and leaves the group; `ANOLE_EV_KAFKA_GROUP_END` says it is over
(`ANOLE_BROKER_END_CLOSED`, `_DRAINED` when `anole_server_drain` ended it,
`_FAILED`). At the stop, groups end without events.

`anole_kafka_find` looks a broker up by name and `anole_kafka_index` gives
its place in `"brokers"` (what `anole_broker_status_event.broker` names).
The consumer reads none, gzip, zstd, lz4 and snappy batches. Transactions,
the KIP-848 protocol and the admin API are not part of the ABI.

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
  `ANOLE_GRPC_F_FINISH` it is sent with OK at once (a unary answer in
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
`grpc-status-details-bin` and `grpc-retry-pushback-ms` in trailers only, `connect-*`, `trailer-*`,
`content-type`, `te` and the transport's headers) are refused with
`ANOLE_E_INVALID`: the same rule as Zig's `Call.addHeader` and `addTrailer`.

**Per-service middleware.** A service can carry `"middleware"`, a list as a
route's (`jwt`, `rate_limit`, `compress`...), after the global one. It runs
for the service's gRPC paths and its transcoded REST routes alike; a
rejection reaches a gRPC or Connect client as the HTTP status
(401 UNAUTHENTICATED, 403 PERMISSION_DENIED, 429 UNAVAILABLE, 404
UNIMPLEMENTED). A middleware that can wait (`jwt` with `jwks_url`) keeps the
service's calls attached to a task instead of detached. Two transcoded
bindings may share a route only behind the same middleware; otherwise
`anole_server_start` answers `ANOLE_E_CONFIG` naming the route.

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
anole_consumer_attach(s, &co, &c);   /* before open/start */
anole_server_open(s);                /* optional: threads and databases, no listener */
/* ... startup work in the language: migrations, lifespan, Next.js prepare ... */
anole_server_start(s);               /* returns once listening (opens first if needed) */
anole_server_set_ready(s, name, 1);  /* observe.health.checks */
/* ... poll and answer ... */
anole_server_drain(s);               /* stop accepting, finish what is in flight */
/* keep polling until ANOLE_EV_STOPPED */
anole_server_destroy(s);
```

`anole_server_open` starts Anole's threads and opens the configuration's
databases (`connect_at_start` included) without binding a listener, so
`anole_db_*` calls work from there and answers go to the consumers. An ASGI
server calls it, runs `lifespan.startup`, then `anole_server_start`; on
`lifespan.startup.failed` it destroys. Both `open` and `start` block until
done. After a failure the server may only be destroyed.

`observe.health.checks` names readiness flags: each starts not ready, so
`/readyz` answers 503 naming it until `anole_server_set_ready(s, name, 1)`;
any thread, any number of times. `observe.health.listener` serves the health
routes on one listener only.

`anole_server_destroy` on a server that was not drained drains it and
answers every request, call and stream still owed by a consumer at once (503
and a reset or close; nothing more is posted to consumers), so it does not
wait for answers that cannot come and may run on a consumer's own thread (a
Node environment cleanup hook, Python `atexit`). It still waits for Anole's
own in-flight work (static files, native routes) up to `timeouts.shutdown_ms`,
then joins Anole's threads. It must not overlap any other call on its server,
consumers, databases or handles. After it returns no callback runs again and
no pointer from the server is valid; handles stay safe to pass.

One server per process. By default Anole installs no signal handlers (the
host process owns its signals) and its threads block asynchronous signals;
`ANOLE_SERVER_F_SIGNALS` asks for SIGINT and SIGTERM (drain) and SIGHUP
(reload certificates), for a standalone C program. A forked child cannot use
its parent's server: its calls on the parent's pointers answer
`ANOLE_E_STATE`, cleanup calls on its handles answer `ANOLE_OK`, and it may
create a server of its own.
`anole_consumer_set_wake(c, wake, ud)` replaces a consumer's wake (a
callback, or NULL for the doorbell fd), for a restarted worker or a new event
loop taking over; once it returns the old callback is not called again.
`anole_server_stats` reports counters (requests, detached, in flight,
expired, aborted, refused, wakes and re-wakes, WebSockets); options structs
and the stats struct start with their `size`, so an older header keeps
working against a newer library, and one larger than the library knows is
accepted only when every byte past what it knows is 0.

Logs go to stderr, or to `anole_server_options.log` (called on Anole's
threads; it must not block or enter the language), filtered by `log_level`.
The callback belongs to its server: it is set by `anole_server_create`,
cleared by `anole_server_destroy`, and a later server without one logs to
stderr.

`"log": {"format": "auto" | "text" | "json", "service": "..."}` picks the
format of every record (`auto`: JSON when `environment` is production, which
is what a binding that leaves it out gets). In `json` the callback's `msg` is
the complete record as one JSON object with no newline, byte for byte what
stderr would get; in `text` it is the message, with structured fields
appended as ` key=value`. Access log lines (the `access_log` middleware, whose
`format` defaults to `"auto"`, following `log.format`) reach the callback too,
with scope `access`. Records can be up to 16 KiB; a binding that parses them
should expect `time`, `level`, `scope`, `message`, `service`, `request_id`,
`trace_id` and `span_id`, then the record's fields ([logging.md](logging.md)).

`"banner": true` prints the startup banner to stderr (when it is a terminal
and the format is text); it is off by default under the ABI.

Validation stays in the binding's language (zod, pydantic): the 422
problem document is described in [validation.md](validation.md#the-422-document)
for bindings that want the same shape.

## Testing

`zig build capi-test` (part of `zig build test`) checks `anole.h` through
translate-c against the Zig side (every struct's layout, every constant, in
both directions), that `include/anole.abi.json` is what `zig build
capi-abi-json` generates, that this guide names every event and function,
and runs the C suites (`tests/capi/consumer.c`, and `tests/capi/grpc.c`
for gRPC over gRPC-Web and HTTP/2) against `libanole.a`. `zig build
capi-grpc` builds `capi-grpc-interop` (`tests/capi/grpc_interop.c`,
grpc.testing.TestService in C), which `tests/grpc/interop/run.sh
zig-out/bin/capi-grpc-interop` runs grpc-go's interop client against.
`zig build capi-test-asan` builds the suite with the system C compiler under
ASan and UBSan (it runs with `ASAN_OPTIONS=use_sigaltstack=0`: Zig's threads
install their own signal stack). `zig build test-capi-engine` runs the
engine's HTTP/2, HTTP/3, WebTransport and TLS tests (mutual TLS over HTTP/2
and HTTP/3, certificate reload from PEM, files and SIGHUP); `zig build
test-grpc` the gRPC ones (native, transcoding, and the ABI's, with
descriptors, JSON and transcoding). The C suite's WebTransport part has its
server in C and its client in Zig (`tests/capi/wt_client.zig`, built with
the suite and passed to it), since C has no WebTransport client. `tests/capi/bench.sh` compares consumer
routes with native ones.

## From ABI 0.6

ABI 0.8 only adds `anole_wt_stream_set_priority`; nothing from 0.7 changes.

ABI 0.9 adds the `environment`, `deployment`, `error_detail`, `proxy.trusted`,
`log`, `banner` and `console` keys, `anole_dotenv_read`, the brokers (NATS
events 64-69, Kafka events 80-85, handle kinds 8 and 9, `ANOLE_E_BROKER`),
`ANOLE_DB_F_RETRY` with `breaker` and `retry` on databases, and the console
calls with event 132. What a 0.8 binding notices: with `environment` unset
(production) the log callback's `msg` is a whole JSON record (`"log":
{"format": "text"}` keeps messages) and access lines reach the callback;
`timeouts.keepalive_ms` defaults to 75 s; `listeners[].address`, `port` and
`proxy_protocol` default to null (the deployment's default); a malformed
route pattern is `ANOLE_E_CONFIG` ([migrating.md](migrating.md#c-abi-json-config-abi-09)).

| 0.6 | 0.7 |
| --- | --- |
| `anole_respond(r, ...)` | `anole_req_respond(r, ...)` |
| `anole_respond_fd(r, ..., int fd, ...)` | `anole_req_respond_fd(r, ..., intptr_t fd, ...)` |
| `anole_stream_start/write/write_wait/end` | `anole_req_stream_start/write/write_wait/end` |
| `anole_release(r)` | `anole_req_fail(r, 0, (anole_str){0})` (500) or `anole_handle_release(r)` (finalizers) |
| (none) | `anole_req_abort(r)` |
| `anole_wt_stream_release(s)` | `anole_handle_release(s)` |
| `anole_server_port(s, i, &port)` | `anole_server_listener(s, i, &info)`; `info.port`, `info.udp_port` |
| `anole_server_reload_certificates(s)` | `anole_server_reload_tls(s, 0, (anole_str){0}, (anole_str){0})` |
| `anole_server_reload_tls(s, f, c, cl, k, kl)` | `anole_server_reload_tls(s, f, (anole_str){c, cl}, (anole_str){k, kl})` |
| `anole_wt_send_datagram(w, d, n)` | `anole_wt_send_datagram(w, d, n, 0)` |
| `ANOLE_EV_WS_DRAIN` | `ANOLE_EV_WRITABLE` (`ev.handle` the socket) |
| `ANOLE_EV_ABORT` read as `anole_event` | `anole_abort_event` (`reason`, `status`) |
| `anole_request_spans(r)` = `r + 1` | the same helper, now reading `r->spans_off` |
| `anole_request_peer_cert(r)` | `anole_event_str(r, r->peer_cert)` |
| gRPC metadata at `c + 1` | `anole_grpc_metadata(c)` (`c->metadata_off`) |
| `ANOLE_DB_INT`, ... | `ANOLE_DB_TYPE_INT`, ...; `ANOLE_DB_WRITE`... are `ANOLE_DB_F_*` |
| `ANOLE_GRPC_OK`... | `ANOLE_GRPC_STATUS_OK`...; `ANOLE_GRPC_UNARY`... are `ANOLE_GRPC_KIND_*`; `ANOLE_GRPC_SEND_FINISH` is `ANOLE_GRPC_F_FINISH` |
| `ANOLE_WT_UNI`, `ANOLE_WT_FIN` | `ANOLE_WT_F_UNI`, `ANOLE_WT_F_FIN` (values kept) |
| `ANOLE_TLS_PEM`, `ANOLE_SERVER_SIGNALS`, `ANOLE_CONSUMER_SHARED`, `ANOLE_POLL_NOARM` | `ANOLE_TLS_F_PEM`, `ANOLE_SERVER_F_SIGNALS`, `ANOLE_CONSUMER_F_SHARED`, `ANOLE_POLL_F_NOARM` |
| `major ==` / `minor >=` checks | `ANOLE_ABI_COMPATIBLE(anole_abi_version())` |
| enum-valued parameters as `int` | `uint32_t`; `anole_consumer_fd` returns `intptr_t`; `anole_has_feature` returns `int32_t` |

## What comes next

ABI 0.1 was the request/response and WebSocket core, plus `anole_db_*` with
SQLite, PostgreSQL and Redis; 0.2 adds the gRPC server, 0.3 MongoDB through
`anole_db_*`, 0.4 WebTransport, and 0.5 the TLS extras (mutual TLS, the
client certificate in requests, certificate reload). 0.6 makes bit 0 of every
send-type call's flags `ANOLE_BODY_BORROW`, so `ANOLE_WT_F_FIN` moved from 1 to
2. 0.7 is the hardening release: records that grow (`spans_off`,
`metadata_off`), one allocation table for events and handle kinds,
`anole_abi.json`'s generated parsers, one cleanup rule and
`anole_handle_release`, the `anole_req_` names and the constant families,
stable error tokens, `anole_server_open`, `anole_listener_info`, abort
reasons, the SENT contract and a poll that never drops an event. 0.8 adds
`anole_wt_stream_set_priority`. 0.9 is the developer-experience release:
environment and deployment modes with `.env` files, the NATS and Kafka
brokers, breakers and retries on databases, JSON Lines logs, the banner and
the live console. Before 1.0
every minor may break (`ANOLE_ABI_COMPATIBLE` asks for an exact match).
The freeze, ABI 1.0, comes after anole-node 0.1 and anole-py 0.1 ship on it.

Auth beyond the configured `jwt` middleware comes later.


## Breakers and retries (databases)

Every `databases[]` entry of a network connector (PostgreSQL, Redis, MongoDB) takes `"breaker"` (an object with `consecutive_failures`, `failure_ratio`, `min_calls`, `window_ms`, `open_ms`, `max_open_ms`, `half_open_calls`; `null` turns it off; ignored for SQLite) and `"retry"` (`attempts`, `base_ms`, `max_ms`, `multiplier`, `attempt_timeout_ms`, `max_retry_after_ms`). `ANOLE_DB_F_RETRY` marks a query that may run again on a transient failure; it is refused (`ANOLE_E_INVALID`) on `anole_db_tx_query` and `anole_db_tx_exec`, and SQLite and MongoDB ignore it. An open breaker answers `ANOLE_EV_DB_RESULT` with `status = ANOLE_E_DB`, `error_class = ANOLE_DB_ERR_UNAVAILABLE`, `http_status = 503` and `error_code = "circuit_open"`.
