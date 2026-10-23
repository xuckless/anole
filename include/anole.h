/* anole.h - the C ABI of Anole (https://github.com/xuckless/anole). MIT.
 *
 * Plain C99 (also valid C++), no Zig types. The ABI version is
 * ANOLE_ABI_VERSION below; check it with ANOLE_ABI_COMPATIBLE. The guide
 * for binding authors is docs/c-abi.md; anole.abi.json describes every
 * record, constant and event for generated parsers. This header is the
 * contract, and every function below says who owns what and for how long.
 *
 * Linking. Link libanole.a (zig build capi) statically: it is one object in
 * which every symbol but anole_* is hidden, so nothing in it is exported
 * from the binding or bound to the OpenSSL, nghttp2, zstd, brotli, sqlite
 * or zlib a host process (Node, CPython) carries. libanole.so /
 * libanole.dylib exist for C programs and tests. Define ANOLE_SHARED before
 * including this header when linking a Windows DLL import library.
 *
 * The model.
 *  - anole_server_create parses one JSON configuration (listeners, routes,
 *    native middleware; include/anole.schema.json). Nothing is bound until
 *    anole_server_start, which starts Anole's own threads (one "executor"
 *    per core) and returns once listening. One server per process.
 *  - Routes either answer natively (fixed responses, static files, the
 *    response cache, health, metrics: never leaving Anole's threads) or name
 *    a "handler" id: their requests go to a consumer.
 *  - A consumer is one language thread (Node's main thread or a worker, an
 *    asyncio loop, a C thread). Anole never calls into it; the only foreign
 *    call is the non-blocking wake callback (or the doorbell fd). The
 *    consumer drains events with anole_poll into its own buffer and answers
 *    by handle.
 *  - Handles are 64-bit and generation-checked: a handle whose object is
 *    over gets ANOLE_E_GONE from answer calls and ANOLE_OK from cleanup
 *    calls, never undefined behaviour and never another object, also across
 *    servers in one process.
 *  - Anole enforces deadlines: a request not answered within its timeout
 *    gets 504 from Anole, and a late answer gets ANOLE_E_GONE.
 *
 * Wake contract: "at least once, may repeat". After anole_poll returns 0,
 * the wake callback (or the fd) fires at least once when new events become
 * available; it may also fire when there turn out to be none (Anole rings
 * again when a ring stays unpolled for timeouts.rewake_ms, because some
 * runtimes lose threadsafe-function calls). A poll that returns 0 is cheap.
 *
 * Rules.
 *  Threads
 *  1. Any function may be called from any thread, except: anole_poll and
 *     anole_poll_wait never overlap on one consumer (a shared consumer
 *     serializes them); nothing is called from inside the wake or log
 *     callbacks; blocking functions are never called on an Anole thread;
 *     anole_server_destroy overlaps nothing on its server.
 *  2. Calls on one handle are memory-safe from any thread. Serialize them
 *     anyway: overlapping answer calls on one handle may answer
 *     ANOLE_E_GONE. Cleanup calls may race anything; at most one takes
 *     effect.
 *  3. Blocking: anole_server_open, _start, _wait, _destroy, anole_poll_wait;
 *     anole_req_read, anole_req_stream_write_wait and anole_grpc_send_wait
 *     with a timeout other than 0; briefly (file I/O) anole_server_reload_tls
 *     and anole_req_respond_fd. Everything else returns in microseconds.
 *  4. Consumers attach before anole_server_open/start; executor e feeds
 *     consumer e mod M, and start refuses a consumer that would get none.
 *  5. Wake: at least once, may repeat. After any wake, poll until 0.
 *  6. Shared consumers: any thread may get any event (route by handle);
 *     exactly one gets ANOLE_EV_STOPPED, after which anole_poll_wait
 *     returns 0 everywhere.
 *  7. One server per process. fork only before anole_server_create or
 *     after destroy; a child cannot use its parent's server. In embedded
 *     mode Anole installs no signal handlers and its threads block
 *     asynchronous signals.
 *  Lifetimes
 *  8. anole_server, anole_consumer and anole_db pointers live until
 *     anole_server_destroy returns; after it no callback runs again.
 *  9. Handles: request from its event to its answer, ABORT or STOPPED; gRPC
 *     call to anole_grpc_finish or ABORT; WebSocket to WS_CLOSE; WebTransport
 *     session to WT_CLOSE; WebTransport stream to anole_handle_release or
 *     its session's end; database transaction to commit, rollback, release,
 *     its timeout, its request's abort or deadline, or ANOLE_EV_STOPPED. Events for a handle that is already over may still
 *     be queued.
 * 10. Answer and data calls on an over handle: ANOLE_E_GONE. Cleanup calls
 *     (anole_handle_release, anole_req_abort, anole_ws_close,
 *     anole_ws_unsubscribe, anole_wt_close, anole_wt_stream_reset/_stop,
 *     anole_db_tx_release):
 *     ANOLE_OK, nothing done, no error set. 0 or a handle of another kind:
 *     ANOLE_E_INVALID everywhere.
 *  Ownership
 * 11. Everything passed in is copied before the call returns, except
 *     bodies passed with ANOLE_BODY_BORROW (see it).
 * 12. Records: in the caller's 8-byte aligned buffer, the caller's; 8-byte
 *     aligned, `len` covering padding; copy what you keep before the next
 *     poll. Skip types you do not know; types that create an obligation
 *     come only when the configuration asks for them. A record's fixed part
 *     may grow at its end; arrays are reached through offsets in it.
 * 13. Strings returned: anole_version and anole_last_error_name are static;
 *     anole_last_error is thread-local text for logs, set with the name and
 *     anole_last_errno by every call that returns < 0.
 * 14. Options structs start with size = sizeof as compiled. Bytes past what
 *     the library knows, reserved fields and unknown flag bits must be 0,
 *     or the call answers ANOLE_E_INVALID.
 */
#ifndef ANOLE_H
#define ANOLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ANOLE_ABI_VERSION_MAJOR 0 /* breaking changes */
#define ANOLE_ABI_VERSION_MINOR 8 /* additions (and, before 1.0, breaking changes; see CHANGELOG.md) */
#define ANOLE_ABI_VERSION ((ANOLE_ABI_VERSION_MAJOR << 16) | ANOLE_ABI_VERSION_MINOR)
/* Whether a library reporting anole_abi_version() == v serves code built
   against this header. Before 1.0 both numbers must match (every 0.x minor
   may break); from 1.0 the major must match and the minor must be >= the
   header's. */
#define ANOLE_ABI_COMPATIBLE(v)                                                   \
  (ANOLE_ABI_VERSION_MAJOR == 0                                                   \
       ? (uint32_t)(v) == (uint32_t)ANOLE_ABI_VERSION                             \
       : ((uint32_t)(v) >> 16) == ANOLE_ABI_VERSION_MAJOR &&                      \
             ((uint32_t)(v) & 0xffffu) >= ANOLE_ABI_VERSION_MINOR)

#if defined(_WIN32) && defined(ANOLE_SHARED)
#define ANOLE_API __declspec(dllimport)
#else
#define ANOLE_API
#endif

/* ---- basics --------------------------------------------------------------- */

/* A byte string; not NUL-terminated. In arguments, {NULL, 0} is the empty
   string. Strings passed in are read during the call only. */
typedef struct anole_str {
  const char *ptr;
  size_t len;
} anole_str;

typedef struct anole_header {
  anole_str name;
  anole_str value;
} anole_header;

/* >= 0: success (ANOLE_OK, or a positive advice such as ANOLE_BUSY);
   < 0: ANOLE_E_*, and nothing was done unless the function says otherwise. */
typedef int32_t anole_status;
enum {
  ANOLE_OK = 0,
  ANOLE_BUSY = 1,           /* taken, but past the high-water mark: wait for
                               ANOLE_EV_WRITABLE on that handle */
  ANOLE_E_INVALID = -1,     /* bad argument (a handle is still owed) */
  ANOLE_E_GONE = -2,        /* an answer or data call on a handle that is over: answered, expired, aborted or stale */
  ANOLE_E_AGAIN = -3,       /* nothing now; an event follows (see the call) */
  ANOLE_E_NOMEM = -4,
  ANOLE_E_CONFIG = -5,      /* see anole_last_error */
  ANOLE_E_STATE = -6,       /* not allowed in this state */
  ANOLE_E_UNSUPPORTED = -7, /* compiled out, or not on this OS */
  ANOLE_E_TOOBIG = -8,      /* anole_poll: the next event does not fit */
  ANOLE_E_SYSTEM = -9,      /* the OS refused (threads, sockets, files) */
  ANOLE_E_TIMEOUT = -10,    /* a blocking call's timeout passed */
  ANOLE_E_DB = -11          /* a database refused a statement (anole_db_result_event) */
};

/* The text of the last error on the calling thread, for logs: not API.
   Set by every call that returns < 0, which also sets the two below; read
   them right after that call (successful calls may leave old values). */
ANOLE_API anole_str anole_last_error(void);
/* A stable token for the same error: a specific name from the list in
   docs/c-abi.md (also in anole.abi.json "error_names"), such as
   "AddressInUse", "KeyMismatch", "UnknownField", "WrongHandleKind"; or, when
   there is none, the code's own name: "Invalid", "Gone", "Again",
   "NoMemory", "Config", "State", "Unsupported", "TooBig", "System",
   "Timeout", "Database". Static storage. API: bindings may switch on it,
   and tokens are only ever added. */
ANOLE_API anole_str anole_last_error_name(void);
/* The OS error behind the last error on this thread: errno on POSIX, the
   WSA or Win32 code on Windows; 0 when it did not come from the OS. */
ANOLE_API int32_t anole_last_errno(void);
/* The library's ABI version (ANOLE_ABI_VERSION as it was built). Check it
   at load with ANOLE_ABI_COMPATIBLE(anole_abi_version()). */
ANOLE_API uint32_t anole_abi_version(void);
/* Anole's version, such as "0.2.0"; static storage. */
ANOLE_API anole_str anole_version(void);
/* 1 when `name` is built in, else 0: "tls", "http2", "http3",
   "webtransport" (with http3), "websocket", "compression", "brotli",
   "auth", "grpc", "sqlite", "postgres", "redis", "mongodb". */
ANOLE_API int32_t anole_has_feature(anole_str name);

/* 64-bit, generation-checked; 0 is never valid. Each handle has a kind
   (a request, a WebSocket, a gRPC call, a WebTransport session or stream, a
   database transaction), and a function given a handle of another
   kind, or 0, answers ANOLE_E_INVALID. The bits are Anole's: treat them as
   opaque. */
typedef uint64_t anole_req;       /* one request: from ANOLE_EV_REQUEST until answered */
typedef uint64_t anole_ws;        /* one WebSocket: from ANOLE_EV_WS_OPEN until ANOLE_EV_WS_CLOSE */
typedef uint64_t anole_grpc_call; /* one gRPC call: from ANOLE_EV_GRPC_CALL until finished or aborted */
typedef uint64_t anole_wt;        /* one WebTransport session: from ANOLE_EV_WT_OPEN until ANOLE_EV_WT_CLOSE */
typedef uint64_t anole_wt_stream; /* one of its streams: until anole_handle_release or the session's close */
typedef uint64_t anole_db_tx;     /* one database transaction: from the answer to anole_db_begin until commit, rollback or release */
typedef struct anole_server anole_server;     /* opaque */
typedef struct anole_consumer anole_consumer; /* opaque */

/* ---- lifecycle ------------------------------------------------------------- */

/* Embedded processes (Node, Python) own their signals, so by default Anole
   installs no signal handlers and only anole_server_drain stops it. A
   standalone C program may ask for SIGINT/SIGTERM (drain) and SIGHUP
   (reload certificates) with this flag. */
#define ANOLE_SERVER_F_SIGNALS 1u

/* Log levels, for the log callback and anole_server_options.log_level.
   Debug lines exist only in Debug builds of libanole. */
enum { ANOLE_LOG_ERROR = 1, ANOLE_LOG_WARN = 2, ANOLE_LOG_INFO = 3, ANOLE_LOG_DEBUG = 4 };

typedef struct anole_server_options {
  size_t size;           /* sizeof(anole_server_options): fields past it read as 0 */
  anole_str config_json; /* the configuration; copied by anole_server_create */
  uint32_t flags;        /* ANOLE_SERVER_F_* */
  uint32_t log_level;    /* the most verbose level passed on (ANOLE_LOG_*); 0: ANOLE_LOG_INFO */
  /* Receives Anole's log lines instead of stderr, from anole_server_create
     until anole_server_destroy returns. Called on any Anole thread,
     possibly several at once; `scope` and `msg` are valid during the call
     only. Must not block and must not enter the language (append to a
     buffer the consumer flushes). NULL: stderr. Belongs to this server: a
     later server without one logs to stderr. */
  void (*log)(void *ud, uint32_t level, anole_str scope, anole_str msg);
  void *log_ud;
} anole_server_options;

/* Parses and checks the configuration and binds nothing. One server per
   process (ANOLE_E_STATE for a second until the first is destroyed).
   ANOLE_E_CONFIG: anole_last_error says what and where. */
ANOLE_API anole_status anole_server_create(const anole_server_options *options, anole_server **out);
/* Starts Anole's threads and opens the configuration's databases
   (connect_at_start included), without binding any listener: anole_db_*
   calls work from here (answers go to the consumers), and
   anole_grpc_health_set and anole_server_set_ready too. For startup work
   in the language before traffic (ASGI lifespan, Next.js prepare,
   migrations, cache warm-up). Consumers attach before this. Blocks until
   done. Optional: anole_server_start opens first when it was not called.
   ANOLE_E_STATE when already open or started ("State"); ANOLE_E_SYSTEM
   ("DatabaseUnavailable", "SystemResources"); ANOLE_E_STATE
   ("ConsumerWithoutExecutor", "NoConsumer"). After a failure the server
   may only be destroyed. */
ANOLE_API anole_status anole_server_open(anole_server *s);
/* Binds every listener; returns once listening, or with the error (the
   server may then only be destroyed). Opens first if needed. Consumers
   attach before this. ANOLE_E_CONFIG: two routes the router cannot tell
   apart (the same method and path twice, two parameter names at one
   position, a method route less specific than an any-method one, or a
   route on a path Anole serves itself, such as observe.metrics);
   anole_last_error names them. */
ANOLE_API anole_status anole_server_start(anole_server *s);
/* Readiness for the health route (observe.health): a check named in
   observe.health.checks starts not ready, so /readyz answers 503 naming it
   until anole_server_set_ready(s, name, 1). Any thread, from create to
   destroy, any number of times. ANOLE_E_INVALID ("UnknownCheck") for a
   name the configuration does not list. */
ANOLE_API anole_status anole_server_set_ready(anole_server *s, anole_str check, uint32_t ready);

#define ANOLE_LISTENER_F_TLS 1u
#define ANOLE_LISTENER_F_HTTP1 2u
#define ANOLE_LISTENER_F_HTTP2 4u
#define ANOLE_LISTENER_F_HTTP3 8u
#define ANOLE_LISTENER_F_UNIX 16u
#define ANOLE_LISTENER_F_PROXY_PROTOCOL 32u
enum {
  ANOLE_LISTENER_PENDING = 0,   /* not bound yet (before start, or start under way) */
  ANOLE_LISTENER_LISTENING = 1, /* bound and accepting */
  ANOLE_LISTENER_FAILED = 2,    /* start failed binding this one: error_name, error_errno */
  ANOLE_LISTENER_CLOSED = 3     /* the server drained or stopped */
};
typedef struct anole_listener_info {
  size_t size;            /* set by the caller: sizeof(anole_listener_info); filled up to it */
  anole_str name;         /* the configuration's name */
  anole_str address;      /* "127.0.0.1:8080", "[::]:8443", "unix:/run/app.sock": the bound
                             address once listening, the configured one before */
  uint16_t port;          /* the bound TCP port (the real one for port 0); 0 before, and for unix */
  uint16_t udp_port;      /* HTTP/3's bound UDP port; 0 when this listener serves no HTTP/3 */
  uint32_t flags;         /* ANOLE_LISTENER_F_* */
  uint32_t state;         /* ANOLE_LISTENER_* */
  int32_t error_errno;    /* FAILED: the OS error (as anole_last_errno), else 0 */
  anole_str error_name;   /* FAILED: the token (as anole_last_error_name), else empty */
} anole_listener_info;

/* The configuration's listeners, in order: from anole_server_create to
   anole_server_destroy. Strings stay valid until destroy (copy them). */
ANOLE_API uint32_t anole_server_listener_count(anole_server *s);
/* ANOLE_E_INVALID past the last (or a size below sizeof(size_t)). */
ANOLE_API anole_status anole_server_listener(anole_server *s, uint32_t i, anole_listener_info *out);
/* Stops accepting and drains: HTTP/2 and HTTP/3 GOAWAY, WebSockets close
   1001, requests in flight finish within timeouts.shutdown_ms. Returns at
   once; again, or once the server stops on its own, is a no-op (ANOLE_OK);
   ANOLE_E_STATE before anole_server_start has succeeded. Consumers keep
   polling and answering until they see ANOLE_EV_STOPPED. */
ANOLE_API anole_status anole_server_drain(anole_server *s);
/* Blocks the calling thread until the server has stopped (after a drain):
   timeout_ms < 0 waits for ever; ANOLE_E_TIMEOUT when it passes. Never on
   a thread that must keep polling a consumer of this server meanwhile. */
ANOLE_API anole_status anole_server_wait(anole_server *s, int32_t timeout_ms);
/* Swaps every TLS listener's certificate and key (the HTTP/3 one too).
   cert and key both empty: reads the configured (or last given) source
   again, as SIGHUP does. Otherwise both set: file paths, or PEM text with
   ANOLE_TLS_F_PEM (copied); later empty-argument reloads read this new
   source. Handshakes under way keep the old ones; on failure the old
   certificate stays. Brief file I/O: not on a thread that must not block.
   ANOLE_E_STATE (name "NotRunning" or "NoTlsListener"); ANOLE_E_SYSTEM
   when a file cannot be read (anole_last_errno; name
   "CertificateFileUnreadable" / "KeyFileUnreadable"); ANOLE_E_INVALID when
   the contents do not load ("InvalidCertificate", "InvalidKey",
   "KeyMismatch") or only one of cert and key is given. */
#define ANOLE_TLS_F_PEM 1u
ANOLE_API anole_status anole_server_reload_tls(anole_server *s, uint32_t flags, anole_str cert, anole_str key);
/* Frees the server. A graceful stop is anole_server_drain, then polling
   until ANOLE_EV_STOPPED, then this. Called on a server still running or
   draining, it drains, and answers every request, call and stream still
   owed by a consumer at once (503 and RST/close; nothing more is posted to
   consumers), so it does not wait for answers that cannot come: it may be
   called on a consumer's own thread (a Node env cleanup hook, Python
   atexit). It still waits for Anole's own in-flight work (static files,
   native routes) up to timeouts.shutdown_ms, then joins Anole's threads.
   Must not overlap any other call on this server, its consumers, databases
   or handles: stop every other thread's calls first. After it returns no
   wake or log callback runs again, and no pointer from the server is
   valid; handles stay safe to pass (cleanup calls answer ANOLE_OK, others
   ANOLE_E_GONE). NULL, or a server of another process (after fork), is a
   no-op. */
ANOLE_API void anole_server_destroy(anole_server *s);

typedef struct anole_stats {
  size_t size;            /* set by the caller: sizeof(anole_stats) */
  uint64_t requests;      /* handed to consumers */
  uint64_t detached;      /* of those, served with no task (HTTP/2, HTTP/3) */
  uint64_t inflight;      /* handed over and not yet finished (now) */
  uint64_t expired;       /* answered 504 by Anole: the deadline passed */
  uint64_t aborted;       /* ended by the client (or the drain) while handed over */
  uint64_t gone;          /* calls refused with ANOLE_E_GONE */
  uint64_t busy;          /* refused 503: limits.max_inflight reached */
  uint64_t wakes;         /* doorbells rung */
  uint64_t rewakes;       /* doorbells rung again: the first was lost */
  uint64_t websockets;    /* open now */
  uint64_t ws_messages_in;
  uint64_t ws_messages_out;
  uint64_t wt_sessions;          /* WebTransport sessions open now */
  uint64_t wt_datagrams_dropped; /* outgoing datagrams dropped: past datagram_queue, or too large */
} anole_stats;
/* Counters since start. Fills what out->size covers. */
ANOLE_API anole_status anole_server_stats(anole_server *s, anole_stats *out);

/* ---- consumers and events --------------------------------------------------- */

/* Many threads poll this consumer (a WSGI thread pool) with anole_poll_wait;
   each call takes at most one event. */
#define ANOLE_CONSUMER_F_SHARED 1u

typedef struct anole_consumer_options {
  size_t size; /* sizeof(anole_consumer_options) */
  /* Called on an Anole thread when events become available after a poll
     returned 0 (the wake contract above). Must not block and must not enter
     the language: napi_call_threadsafe_function(nonblocking), a write to an
     eventfd or a socket, PostQueuedCompletionStatus. NULL: use
     anole_consumer_fd, or anole_poll_wait. */
  void (*wake)(void *ud);
  void *wake_ud;
  uint32_t flags; /* ANOLE_CONSUMER_F_* */
} anole_consumer_options;

/* Before anole_server_open / anole_server_start: executors are shared out
   among the consumers at start (executor e feeds consumer e mod M). Lives
   until anole_server_destroy. */
ANOLE_API anole_status anole_consumer_attach(anole_server *s, const anole_consumer_options *options,
                                             anole_consumer **out);
/* The doorbell fd when no wake callback was given: readable when events
   may be available (the wake contract). anole_poll empties it; the consumer
   never reads it itself. -1 with a callback, for a shared consumer, and on
   Windows (pass a callback there). Closed by anole_server_destroy. */
ANOLE_API intptr_t anole_consumer_fd(anole_consumer *c);
/* Replaces the consumer's wake: a callback, or NULL for the doorbell fd
   (opened now if it was not; anole_consumer_fd gives it). For a restarted
   worker or a new event loop taking over a consumer. Not while
   anole_poll or anole_poll_wait runs on c; any thread otherwise. Once it
   returns, the old callback is not called again (calls under way are
   waited for), so the old ud may be freed. The new wake fires at least
   once if events are pending. */
ANOLE_API anole_status anole_consumer_set_wake(anole_consumer *c, void (*wake)(void *ud), void *ud);

/* Event types (allocation table, frozen): 0 none; 1-11 core (9 retired);
   12-19 gRPC; 20-29 WebTransport; 30-39 database; 40-49 HTTP and WebSocket
   additions; 50-63 core additions; 64-255 new areas, 16 per area; 256 up
   never used by Anole, and 0x80000000 up are free for a binding's own
   synthetic events. Rules: a consumer skips types it does not know
   (ev.len); an event that creates an obligation comes only when the
   configuration asked for the feature producing it; numbers are never
   reused. */
enum anole_event_type {
  ANOLE_EV_NONE = 0,       /* never sent as an event: only the header written on ANOLE_E_TOOBIG */
  ANOLE_EV_REQUEST = 1,    /* anole_request_event; handle: anole_req */
  ANOLE_EV_BODY = 2,       /* anole_event: more request body to read (after ANOLE_E_AGAIN) */
  ANOLE_EV_ABORT = 3,      /* anole_abort_event: the request or gRPC call ev.handle is over before
                              its answer (the client went away, its deadline passed, its body broke
                              a limit, the drain cut it); nothing more is owed, and answer calls on
                              it get ANOLE_E_GONE */
  ANOLE_EV_WRITABLE = 4,   /* anole_event: a streamed response, gRPC call, WebSocket or WebTransport
                              stream that took ANOLE_BUSY has room (ev.handle) */
  ANOLE_EV_SENT = 5,       /* anole_sent_event: a borrowed body is no longer read */
  ANOLE_EV_WS_OPEN = 6,    /* anole_request_event (the upgrade request; subprotocol set); handle:
                              anole_ws. Routes with "accept": "auto" only (the default) */
  ANOLE_EV_WS_MESSAGE = 7, /* anole_ws_message_event */
  ANOLE_EV_WS_CLOSE = 8,   /* anole_ws_close_event: the handle is stale from now on */
  /* 9 is retired (was ANOLE_EV_WS_DRAIN: WebSockets use ANOLE_EV_WRITABLE) */
  ANOLE_EV_DB_RESULT = 10, /* anole_db_result_event: a query's answer (anole_db_query, anole_db_exec) */
  ANOLE_EV_STOPPED = 11,   /* anole_event: the server stopped; the consumer's last event */
  ANOLE_EV_GRPC_CALL = 12, /* anole_grpc_call_event; handle: anole_grpc_call */
  ANOLE_EV_GRPC_MESSAGE = 13,   /* anole_grpc_message_event: a request message of a client- or
                                   bidirectional-streaming call */
  ANOLE_EV_GRPC_HALF_CLOSE = 14, /* anole_event: the client sent its last request message */
  ANOLE_EV_WT_OPEN = 20,   /* anole_request_event (the CONNECT); handle: anole_wt */
  ANOLE_EV_WT_CLOSE = 21,  /* anole_wt_close_event: the session and its streams are stale from now on */
  ANOLE_EV_WT_DRAIN = 22,  /* anole_event: the session is draining (the server's drain or the
                              peer's): finish up and close it */
  ANOLE_EV_WT_STREAM = 23, /* anole_wt_stream_event: the peer opened a stream; handle: anole_wt_stream */
  ANOLE_EV_WT_DATA = 24,   /* anole_wt_data_event: bytes of a stream, and/or its end */
  ANOLE_EV_WT_STREAM_RESET = 25, /* anole_wt_code_event: the peer reset its sending side
                                    (nothing more arrives) */
  ANOLE_EV_WT_STREAM_STOP = 26,  /* anole_wt_code_event: the peer asked this side to stop
                                    sending (writes now answer ANOLE_E_GONE) */
  ANOLE_EV_WT_DATAGRAM = 27,     /* anole_wt_datagram_event; handle: anole_wt */
  ANOLE_EV_WS_UPGRADE = 40,      /* anole_request_event; handle: anole_req. A WebSocket handshake on a
                                    route with "accept": "consumer": answer it with anole_ws_accept,
                                    or refuse it with any answer to a request (anole_req_respond,
                                    anole_req_fail, anole_req_stream_*, anole_req_abort) */
  ANOLE_EV_DRAINING = 41         /* anole_event, handle 0: anole_server_drain was called; once per
                                    consumer, before any WebSocket 1001 or abort. Long polls and
                                    event streams finish up while the drain's deadline
                                    (timeouts.shutdown_ms) runs */
};

/* Every event starts with this. Records are 8-byte aligned and `len`
   includes the header, payload and padding, so a binding skips types (and
   trailing fields) it does not know. */
typedef struct anole_event {
  uint32_t type;
  uint32_t len;
  uint64_t handle;
} anole_event;

/* A string inside a record: offset from the record's start, and length. */
typedef struct anole_span {
  uint32_t off;
  uint32_t len;
} anole_span;

enum anole_method {
  ANOLE_METHOD_OTHER = 0, /* see method_name */
  ANOLE_METHOD_GET = 1,
  ANOLE_METHOD_HEAD = 2,
  ANOLE_METHOD_POST = 3,
  ANOLE_METHOD_PUT = 4,
  ANOLE_METHOD_DELETE = 5,
  ANOLE_METHOD_CONNECT = 6,
  ANOLE_METHOD_OPTIONS = 7,
  ANOLE_METHOD_TRACE = 8,
  ANOLE_METHOD_PATCH = 9
};

#define ANOLE_REQ_BODY_INLINE 1u /* `body` is the whole request body (maybe empty) */
#define ANOLE_REQ_BODY_STREAM 2u /* there is a body to read with anole_req_read */
#define ANOLE_REQ_SECURE 4u      /* arrived over TLS (or QUIC) */
#define ANOLE_REQ_EARLY_DATA 8u  /* arrived in TLS 1.3 / QUIC 0-RTT (replayable) */
#define ANOLE_REQ_PEER_CERT 16u  /* the client presented a certificate (mutual TLS): see peer_cert */

/* The fixed part of a record may grow at its end, in a later ABI version.
   Every variable part (arrays, bytes) is reached through an offset or span
   stored in the record, never through sizeof. Parsers read the fields they
   know by offset and skip the rest with ev.len. */

/* ANOLE_EV_REQUEST, ANOLE_EV_WS_OPEN, ANOLE_EV_WT_OPEN and
   ANOLE_EV_WS_UPGRADE. Followed, at spans_off, by
   `anole_span headers[2 * nheaders]` (name, value: names lower-cased, order
   and duplicates kept) and then `anole_span params[2 * nparams]` (route
   parameters: name, value; values raw and percent-encoded as in the path:
   decode with decodeURIComponent / urllib.parse.unquote); the bytes the
   spans point into come after. */
typedef struct anole_request_event {
  anole_event ev;          /*   0 */
  uint32_t route_id;       /*  16 the route's "handler" id */
  uint8_t method;          /*  20 enum anole_method */
  uint8_t version;         /*  21 10, 11, 20, 30 */
  uint16_t flags;          /*  22 ANOLE_REQ_* */
  anole_span method_name;  /*  24 "GET", ... (any method, as sent) */
  anole_span path;         /*  32 raw, not percent-decoded */
  anole_span query;        /*  40 after '?', raw; empty when none */
  anole_span body;         /*  48 with ANOLE_REQ_BODY_INLINE */
  anole_span remote_addr;  /*  56 "ip:port" ("[ip]:port" for IPv6), proxies applied */
  anole_span listener;     /*  64 the listener's name */
  anole_span id;           /*  72 the request ID (request_id middleware), else empty */
  anole_span claims;       /*  80 a verified JWT's claims as JSON (jwt middleware), else empty */
  uint16_t nheaders;       /*  88 */
  uint16_t nparams;        /*  90 */
  uint32_t spans_off;      /*  92 where the header spans start (then the param spans) */
  uint64_t content_length; /*  96 UINT64_MAX when unknown */
  anole_span peer_cert;    /* 104 mutual TLS: the client's certificate (DER, verified against the
                                  listener's client CAs); empty when none (ANOLE_REQ_PEER_CERT) */
  int64_t timeout_us;      /* 112 time left before Anole answers 504, measured when polled;
                                  -1 when no deadline applies (WS_OPEN, WT_OPEN) */
  anole_span subprotocol;  /* 120 ANOLE_EV_WS_OPEN: the WebSocket subprotocol Anole selected
                                  (Sec-WebSocket-Protocol), empty when none; empty in other events */
} anole_request_event;     /* 128 */

/* ANOLE_EV_ABORT: the request or gRPC call ev.handle is over before its
   answer; nothing more is owed, and answer calls on it get ANOLE_E_GONE. */
enum {
  ANOLE_ABORT_CLIENT = 1,   /* the client closed the connection or cancelled the stream */
  ANOLE_ABORT_DEADLINE = 2, /* its timeout passed: the client got `status` (504; gRPC DEADLINE_EXCEEDED) */
  ANOLE_ABORT_BODY = 3,     /* the request body broke a limit or its framing (413 or 400;
                               gRPC RESOURCE_EXHAUSTED or INTERNAL) */
  ANOLE_ABORT_DRAIN = 4,    /* the drain's deadline (timeouts.shutdown_ms) cut it */
  ANOLE_ABORT_SERVER = 5    /* Anole could not go on (out of memory, an internal error) */
};
typedef struct anole_abort_event {
  anole_event ev;
  uint16_t reason;   /* ANOLE_ABORT_* */
  uint16_t status;   /* what the client was sent: an HTTP status for a request, a gRPC status
                        code for a gRPC call; 0 when nothing was sent */
  uint32_t reserved;
} anole_abort_event; /* 24 */

/* ANOLE_EV_SENT: Anole no longer reads the memory of a body passed with
   ANOLE_BODY_BORROW (to anole_req_respond or anole_req_stream_write on the request
   ev.handle, anole_ws_send on the socket ev.handle, anole_grpc_send on the
   call, anole_wt_stream_write on the stream or anole_wt_send_datagram on the
   session; the handle may be stale by now). */
typedef struct anole_sent_event {
  anole_event ev;
  uint64_t data; /* the body's address, as passed */
  uint64_t len;
} anole_sent_event;

enum { ANOLE_WS_TEXT = 1, ANOLE_WS_BINARY = 2 }; /* passed as uint32_t */

/* ANOLE_EV_WS_MESSAGE: one whole message (inflated; UTF-8 checked when
   text), followed by its bytes. */
typedef struct anole_ws_message_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t type; /* ANOLE_WS_TEXT or ANOLE_WS_BINARY */
  anole_span data;
} anole_ws_message_event;

/* ANOLE_EV_WS_CLOSE: the socket is done. code: the peer's close code, 1005
   for a close without one, 1006 when the connection ended without a close,
   1001 on the server's drain. */
typedef struct anole_ws_close_event {
  anole_event ev;
  uint32_t route_id;
  uint16_t code;
  uint16_t reserved;
  anole_span reason;
} anole_ws_close_event;

/* Options for anole_ws_accept; NULL takes the defaults (no subprotocol, no
   extra headers). */
typedef struct anole_ws_accept_options {
  size_t size;                  /* sizeof(anole_ws_accept_options) */
  uint32_t flags;               /* ANOLE_WS_F_*: none defined yet, 0 */
  uint32_t reserved;            /* 0 */
  anole_str subprotocol;        /* one the client offered (see the request's sec-websocket-protocol
                                   headers); {NULL, 0}: none */
  const anole_header *headers;  /* extra headers on the handshake's answer (Set-Cookie, ...), copied */
  size_t nheaders;
} anole_ws_accept_options;

/* ---- gRPC events ---------------------------------------------------------- */

/* The call modes, and the wire protocols a call came in on. */
enum {
  ANOLE_GRPC_KIND_UNARY = 0,
  ANOLE_GRPC_KIND_SERVER_STREAMING = 1,
  ANOLE_GRPC_KIND_CLIENT_STREAMING = 2,
  ANOLE_GRPC_KIND_BIDI_STREAMING = 3
};
enum {
  ANOLE_GRPC_PROTOCOL_GRPC = 0,           /* gRPC over HTTP/2 */
  ANOLE_GRPC_PROTOCOL_GRPC_WEB = 1,       /* gRPC-Web (HTTP/1.1 or 2) */
  ANOLE_GRPC_PROTOCOL_GRPC_WEB_TEXT = 2,  /* gRPC-Web, base64 body */
  ANOLE_GRPC_PROTOCOL_CONNECT = 3,        /* Connect unary (POST, or GET) */
  ANOLE_GRPC_PROTOCOL_CONNECT_STREAM = 4, /* Connect streaming */
  ANOLE_GRPC_PROTOCOL_HTTP_JSON = 5       /* JSON transcoding (google.api.http) */
};

#define ANOLE_GRPC_CALL_MESSAGE 1u     /* `message` is the request message (unary, server streaming) */
#define ANOLE_GRPC_CALL_PEER_CERT 2u   /* the client presented a certificate: see peer_cert */
#define ANOLE_GRPC_CALL_SECURE 4u      /* arrived over TLS (or QUIC) */
#define ANOLE_GRPC_CALL_EARLY_DATA 8u  /* arrived in TLS 1.3 / QUIC 0-RTT (replayable) */
#define ANOLE_GRPC_CALL_JSON 16u       /* the client speaks JSON; Anole converted (messages are still protobuf) */
#define ANOLE_GRPC_CALL_COMPRESSED 32u /* the client compresses its messages (Anole inflated them) */

/* ANOLE_EV_GRPC_CALL: a call to a configured service ("grpc" in the
   configuration). Messages always cross as protobuf bytes, whatever the
   client spoke (Anole converts Connect JSON, gRPC-Web JSON and transcoded
   REST with the descriptors). Followed, at metadata_off, by
   `anole_span metadata[2 * nmetadata]` (name, value: names lower-cased, the
   protocols' own headers left out, `-bin` values decoded to bytes), then
   the bytes the spans point into. The consumer answers with anole_grpc_send
   and anole_grpc_finish; ANOLE_EV_ABORT ends the call instead (client gone,
   deadline passed, request messages failed). */
typedef struct anole_grpc_call_event {
  anole_event ev;         /*   0 */
  uint32_t route_id;      /*  16 the service's "handler" id */
  uint16_t method_id;     /*  20 the method's index in the service's "methods" (else the descriptors') */
  uint8_t kind;           /*  22 ANOLE_GRPC_KIND_* */
  uint8_t protocol;       /*  23 ANOLE_GRPC_PROTOCOL_* */
  uint16_t flags;         /*  24 ANOLE_GRPC_CALL_* */
  uint8_t version;        /*  26 HTTP version: 11, 20, 30 */
  uint8_t reserved0;      /*  27 */
  uint16_t nmetadata;     /*  28 */
  uint16_t reserved1;     /*  30 */
  anole_span method;      /*  32 "/package.Service/Method" */
  anole_span message;     /*  40 with ANOLE_GRPC_CALL_MESSAGE: the request message (may be empty) */
  anole_span remote_addr; /*  48 the client, "ip:port", proxies applied */
  anole_span listener;    /*  56 the listener's name */
  anole_span id;          /*  64 the request ID (request_id middleware), else empty */
  anole_span claims;      /*  72 a verified JWT's claims as JSON (jwt middleware), else empty */
  int64_t timeout_us;     /*  80 time left before the deadline when polled; -1 for none */
  uint32_t metadata_off;  /*  88 where the metadata spans start */
  uint32_t reserved2;     /*  92 */
  anole_span peer_cert;   /*  96 mutual TLS: the client's certificate (DER), empty when none */
} anole_grpc_call_event;  /* 104 */

/* ANOLE_EV_GRPC_MESSAGE: one request message (protobuf bytes), followed by
   them. Each takes one unit of credit (see anole_grpc_read). */
typedef struct anole_grpc_message_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t reserved;
  anole_span data;
} anole_grpc_message_event;

/* WebTransport (draft-02 over HTTP/3, what Chrome and Firefox speak). */
#define ANOLE_WT_F_UNI 1u /* anole_wt_open_stream's flag, and ANOLE_EV_WT_STREAM's: one-way */
#define ANOLE_WT_F_FIN 2u /* anole_wt_stream_write's flag, and ANOLE_EV_WT_DATA's: the end (1 before ABI 0.6) */
enum { ANOLE_WT_CLOSED_LOCAL = 0, ANOLE_WT_CLOSED_PEER = 1, ANOLE_WT_CLOSED_CONNECTION = 2 };

/* ANOLE_EV_WT_STREAM: a stream the peer opened, both ways or (ANOLE_WT_F_UNI)
   read-only. Release it (anole_handle_release) when done: the peer may
   open another only as streams are released. */
typedef struct anole_wt_stream_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t flags;   /* ANOLE_WT_F_UNI */
  anole_wt session; /* the session it belongs to */
} anole_wt_stream_event;

/* ANOLE_EV_WT_DATA: the next bytes of a stream, in order (at most 32 KiB
   each), followed by them; ANOLE_WT_F_FIN in flags with the last (or alone,
   with no bytes). */
typedef struct anole_wt_data_event {
  anole_event ev;
  uint32_t flags; /* ANOLE_WT_F_FIN */
  uint32_t reserved;
  anole_span data;
} anole_wt_data_event;

/* ANOLE_EV_WT_STREAM_RESET and ANOLE_EV_WT_STREAM_STOP: the peer's
   application error code (0 when it sent none Anole could read). */
typedef struct anole_wt_code_event {
  anole_event ev;
  uint32_t code;
  uint32_t reserved;
} anole_wt_code_event;

/* ANOLE_EV_WT_DATAGRAM: one datagram, followed by its bytes. */
typedef struct anole_wt_datagram_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t reserved;
  anole_span data;
} anole_wt_datagram_event;

/* ANOLE_EV_WT_CLOSE: the session is over. code and reason: the
   application's close (0 and empty when it ended without one); by: which
   side closed it (ANOLE_WT_CLOSED_*). Every stream of it is stale too. */
typedef struct anole_wt_close_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t code;
  uint32_t by;
  uint32_t reserved;
  anole_span reason;
} anole_wt_close_event;

static inline anole_str anole_event_str(const void *record, anole_span s) {
  anole_str r;
  r.ptr = (const char *)record + s.off;
  r.len = s.len;
  return r;
}
/* A span array inside a record (headers, parameters, metadata). */
static inline const anole_span *anole_record_spans(const void *record, uint32_t off) {
  return (const anole_span *)((const char *)record + off);
}
/* The header spans, then the parameter spans, of a request record. */
static inline const anole_span *anole_request_spans(const anole_request_event *r) {
  return anole_record_spans(r, r->spans_off);
}
/* The metadata spans of a gRPC call record. */
static inline const anole_span *anole_grpc_metadata(const anole_grpc_call_event *c) {
  return anole_record_spans(c, c->metadata_off);
}

/* Drains events into buf (caller-owned, 8-byte aligned; the caller owns the
   bytes written). Returns the bytes written, a packed sequence of records;
   0 means nothing is pending and the doorbell is armed again (after every
   wake, poll until 0). ANOLE_E_TOOBIG: the next record needs more than
   `cap`; it stays queued. When cap >= sizeof(anole_event), buf then holds an
   anole_event with type ANOLE_EV_NONE (0), handle 0 and len = the bytes
   that record needs (a multiple of 8). Keep a steady buffer (256 KiB serves
   requests and messages up to the defaults) and poll once into a one-off
   buffer of at least `len` when this happens. Not concurrently
   with itself on one consumer. A shared consumer returns one event per call.
   ANOLE_POLL_F_NOARM: a 0 return leaves the doorbell disarmed, so producers
   skip the wake while the consumer spins on NOARM polls for a few
   microseconds; it must end with a plain poll before it sleeps. */
#define ANOLE_POLL_F_NOARM 1u
ANOLE_API int64_t anole_poll(anole_consumer *c, void *buf, size_t cap, uint32_t flags);
/* anole_poll that blocks the calling thread up to timeout_ms (< 0: for
   ever) until it has at least one event: for thread-pool consumers (WSGI),
   with the GIL released. 0 on timeout. Never on an Anole thread. */
ANOLE_API int64_t anole_poll_wait(anole_consumer *c, void *buf, size_t cap, int32_t timeout_ms);

/* ---- requests ---------------------------------------------------------------- */

/* Copies up to `cap` bytes of the request body into buf (requests with
   ANOLE_REQ_BODY_STREAM; with ANOLE_REQ_BODY_INLINE it returns 0). Returns
   the bytes copied (> 0), 0 at the end of the body, or: ANOLE_E_AGAIN when
   timeout_ms is 0 and nothing is buffered (ANOLE_EV_BODY follows when there
   is); ANOLE_E_TIMEOUT when a blocking read (timeout_ms > 0, or < 0 for
   ever; never on an Anole thread) waited in vain; ANOLE_E_GONE. A body over
   limits.body_max ends the request with 413. Valid until the request is
   answered. */
ANOLE_API int64_t anole_req_read(anole_req r, void *buf, size_t cap, int32_t timeout_ms);

/* ---- responses ------------------------------------------------------------------ */

/* Body flags. ANOLE_BODY_BORROW: Anole reads the bytes where they are
   instead of copying them; they must stay valid and unchanged until
   ANOLE_EV_SENT for them. With ANOLE_BODY_BORROW, a call that answers >= 0
   (OK or BUSY) produces exactly one ANOLE_EV_SENT for that (data, len),
   zero length included, even when the client goes away before it is sent;
   a call that answers < 0 took nothing and produces none. The same address
   may appear in several SENT events (one per call that borrowed it). Every
   borrowing call accepts the flag: anole_req_respond,
   anole_req_stream_write, anole_ws_send, anole_grpc_send,
   anole_wt_stream_write, anole_wt_send_datagram. Where borrowing pays:
   HTTP/1.1 whole bodies, streamed writes, WebSocket sends. Whole bodies
   answered over HTTP/2 and HTTP/3, and WebTransport writes and datagrams,
   are copied by Anole all the same (SENT then comes early).
   ANOLE_EV_STOPPED releases everything still borrowed: after it, and after
   anole_server_destroy returns, no borrowed memory is read and no SENT
   comes. Bit 0 of every send-type call's flags is ANOLE_BODY_BORROW; flags
   of one call start at bit 1, and unknown bits are ANOLE_E_INVALID. */
#define ANOLE_BODY_BORROW 1u

/* The whole response: status (a code in the IANA registry, or one of the
   common unregistered ones Anole knows), headers and body. Headers and,
   unless borrowed, the body are copied before this returns. Compression,
   the response cache and the access log run on Anole's side afterwards.
   Finishes the request. ANOLE_E_INVALID: a bad status, flag, header name
   or value, or Connection / Transfer-Encoding, which the server writes
   itself (nothing taken, the request is still owed); ANOLE_E_GONE. */
ANOLE_API anole_status anole_req_respond(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders,
                                     const void *body, size_t len, uint32_t flags);
/* Sends `len` bytes of the open regular file `fd` from `offset` (len 0: to
   the end of the file) as the body, with Content-Length set by Anole. Anole
   duplicates fd before returning, so the caller may close its own at once.
   Finishes the request. fd is an intptr_t: POSIX takes a file descriptor
   (values outside int are ANOLE_E_INVALID); ANOLE_E_UNSUPPORTED on Windows
   (a HANDLE later, additively). ANOLE_E_SYSTEM when the dup fails
   (anole_last_errno), ANOLE_E_INVALID (errno EBADF) when fd cannot be
   stat'ed. */
ANOLE_API anole_status anole_req_respond_fd(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders,
                                        intptr_t fd, uint64_t offset, uint64_t len);
/* Starts a streamed response: the head goes out now (copied); the body
   follows with anole_req_stream_write, and anole_req_stream_end finishes it.
   The request deadline ends once a stream has started; each write the peer
   does not take within timeouts.write_ms ends the stream (ANOLE_EV_ABORT). */
ANOLE_API anole_status anole_req_stream_start(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders);
/* Queues body bytes (copied, or borrowed with ANOLE_BODY_BORROW). Returns
   ANOLE_OK, or ANOLE_BUSY when the bytes are taken but more than
   limits.stream_high_water bytes wait to go out: write no more until
   ANOLE_EV_WRITABLE. ANOLE_E_GONE when the client is gone (ANOLE_EV_ABORT
   is on its way). */
ANOLE_API anole_status anole_req_stream_write(anole_req r, const void *data, size_t len, uint32_t flags);
/* anole_req_stream_write for a thread that may block (WSGI): waits up to
   timeout_ms (< 0: for ever) for the queue to fall below the high-water
   mark, then copies the bytes. ANOLE_E_TIMEOUT: nothing taken. Never on an
   Anole thread. */
ANOLE_API anole_status anole_req_stream_write_wait(anole_req r, const void *data, size_t len, int32_t timeout_ms);
/* Ends a streamed response, with trailers (HTTP/2 and HTTP/3 send them;
   HTTP/1.1 drops them), copied. Finishes the request. */
ANOLE_API anole_status anole_req_stream_end(anole_req r, const anole_header *trailers, size_t ntrailers);
/* An error answer in the server's configured error format (the same body
   Anole's own 404/413/504 have): status 400-599, or 0 for 500; message
   (UTF-8, at most 4096 bytes, copied) is the detail, empty for the status's
   reason phrase. Finishes the request. ANOLE_E_INVALID: another status or a
   longer message (still owed). An answer call. */
ANOLE_API anole_status anole_req_fail(anole_req r, uint16_t status, anole_str message);
/* Drops the request without an answer (Zig's res.abort()): HTTP/1.1 closes
   the connection, HTTP/2 resets the stream (CANCEL), HTTP/3 cancels it
   (H3_REQUEST_CANCELLED); a stream under way is cut short. A cleanup call:
   ANOLE_OK also when the request is already over. */
ANOLE_API anole_status anole_req_abort(anole_req r);

/* Done with a handle, whatever its kind: the one call a finalizer needs.
   It ends what is still open, the way the application giving up would:
     request          not answered yet: as anole_req_fail(r, 500, {0});
                      a stream under way: cut short, as anole_req_abort
     WebSocket        closes with 1001 (going away)
     gRPC call        finishes with ANOLE_GRPC_STATUS_UNKNOWN,
                      "Application error processing RPC"
     WebTransport     closes the session with code 0
     session
     WebTransport     a sending side not ended is reset and a receiving side
     stream           not read to its end is stopped (code 0); the stream is
                      let go (the peer may open another)
     database         an open transaction is rolled back
     transaction
   A cleanup call: ANOLE_OK also when the object is already over, from any
   thread, before or after the server is destroyed. ANOLE_E_INVALID for 0
   or a value that is no handle kind. */
ANOLE_API anole_status anole_handle_release(uint64_t h);

/* ---- WebSocket -------------------------------------------------------------------- */

/* Sends one message: ANOLE_WS_TEXT (valid UTF-8 is the caller's to keep) or
   ANOLE_WS_BINARY; copied, or borrowed with ANOLE_BODY_BORROW (then
   ANOLE_EV_SENT follows with ev.handle = w). Returns ANOLE_OK, or
   ANOLE_BUSY when taken but more than limits.ws_high_water bytes wait to go
   out (send no more until ANOLE_EV_WRITABLE, ev.handle w). ANOLE_E_GONE once closed. */
ANOLE_API anole_status anole_ws_send(anole_ws w, uint32_t type, const void *data, size_t len, uint32_t flags);
/* Sends a close frame (a code a peer may send: 1000-1003, 1007-1014 or
   3000-4999; a reason of up to 123 bytes, copied);
   ANOLE_EV_WS_CLOSE follows once the socket is done. A cleanup call. */
ANOLE_API anole_status anole_ws_close(anole_ws w, uint16_t code, anole_str reason);
/* Accepts the WebSocket handshake r (an ANOLE_EV_WS_UPGRADE): Anole answers
   it (101 over HTTP/1.1, 200 over HTTP/2 and HTTP/3; permessage-deflate as
   the route says) and *out is the socket's handle, usable at once: sends,
   closes and topic changes wait until the answer is out. The request handle
   is stale from here. ANOLE_EV_WS_MESSAGE and ANOLE_EV_WS_CLOSE follow on
   this consumer; ANOLE_EV_WS_OPEN does not. If the answer cannot be sent
   (the client left), ANOLE_EV_WS_CLOSE with 1006 follows alone.
   ANOLE_E_STATE: r is a request that is not a WebSocket handshake.
   ANOLE_E_INVALID: a subprotocol the client did not offer, a header Anole
   writes for the handshake (Upgrade, Connection, Sec-WebSocket-*,
   Content-Length, Transfer-Encoding) or an invalid one, unknown flags or
   reserved != 0, a NULL out, or an options->size larger than this header's.
   Nothing is taken on a negative answer: r is still owed an answer
   (ANOLE_E_GONE excepted: it is over). */
ANOLE_API anole_status anole_ws_accept(anole_req r, const anole_ws_accept_options *options, anole_ws *out);
/* Joins or leaves a topic (copied, 1-255 bytes). A socket leaves every
   topic when it closes. A publish called after this returns sees the
   change (it reaches a socket that joined, and not one that left).
   anole_ws_unsubscribe is a cleanup call. */
ANOLE_API anole_status anole_ws_subscribe(anole_ws w, anole_str topic);
ANOLE_API anole_status anole_ws_unsubscribe(anole_ws w, anole_str topic);
/* Sends one message to every socket subscribed to `topic` but `except` (0:
   none), fanned out on Anole's threads; returns at once (topic and data
   copied). Publishes to one topic reach every subscriber in the order they
   were taken (from one thread: call order); publishes to different topics,
   and a publish against an anole_ws_send to the same socket, are not
   ordered against each other. At most limits.ws_max_message bytes (else ANOLE_E_INVALID).
   No subscriber holds a publish up: each has up to limits.ws_high_water
   bytes queued for it, past which publishes skip it (and one stuck that way
   for a second is closed). ANOLE_E_AGAIN: not sent, because too many
   publishes are still being fanned out (at most 64 per executor and the
   larger of 16 x limits.ws_high_water and 2 x limits.ws_max_message bytes);
   no event follows, publish again later. ANOLE_E_STATE ("NotRunning") on a
   server that is not running. */
ANOLE_API anole_status anole_ws_publish(anole_server *s, anole_str topic, uint32_t type, const void *data,
                                        size_t len, anole_ws except);

/* ---- gRPC ------------------------------------------------------------------- */

/* Status codes (google.rpc.Code). */
enum {
  ANOLE_GRPC_STATUS_OK = 0,
  ANOLE_GRPC_STATUS_CANCELLED = 1,
  ANOLE_GRPC_STATUS_UNKNOWN = 2,
  ANOLE_GRPC_STATUS_INVALID_ARGUMENT = 3,
  ANOLE_GRPC_STATUS_DEADLINE_EXCEEDED = 4,
  ANOLE_GRPC_STATUS_NOT_FOUND = 5,
  ANOLE_GRPC_STATUS_ALREADY_EXISTS = 6,
  ANOLE_GRPC_STATUS_PERMISSION_DENIED = 7,
  ANOLE_GRPC_STATUS_RESOURCE_EXHAUSTED = 8,
  ANOLE_GRPC_STATUS_FAILED_PRECONDITION = 9,
  ANOLE_GRPC_STATUS_ABORTED = 10,
  ANOLE_GRPC_STATUS_OUT_OF_RANGE = 11,
  ANOLE_GRPC_STATUS_UNIMPLEMENTED = 12,
  ANOLE_GRPC_STATUS_INTERNAL = 13,
  ANOLE_GRPC_STATUS_UNAVAILABLE = 14,
  ANOLE_GRPC_STATUS_DATA_LOSS = 15,
  ANOLE_GRPC_STATUS_UNAUTHENTICATED = 16
};

/* anole_grpc_send flag: the call ends after this message with OK and no
   trailing metadata (a unary answer in one call). */
#define ANOLE_GRPC_F_FINISH 2u

/* Metadata (anole_header name/value pairs) a consumer sends: a lower-case
   key (letters, digits, '-', '_', '.'), not the protocols' own (grpc-*
   except grpc-status-details-bin, connect-*, trailer-*, content-type, te,
   HTTP's framing); a printable ASCII value, except under a key ending in
   "-bin", whose value is bytes (Anole base64-encodes them). Copied.
   ANOLE_E_INVALID otherwise. */

/* Initial metadata (response headers), before the first message; at most
   once. ANOLE_E_STATE after a message. */
ANOLE_API anole_status anole_grpc_send_headers(anole_grpc_call c, const anole_header *metadata, size_t n);

/* One response message (protobuf bytes; copied, or borrowed with
   ANOLE_BODY_BORROW, then ANOLE_EV_SENT follows with ev.handle = c).
   Unary and client streaming: the one answer message, kept until
   anole_grpc_finish (a second: ANOLE_E_STATE); with ANOLE_GRPC_F_FINISH
   it is sent with OK at once. Server and bidirectional streaming: sent
   now, in order; ANOLE_BUSY when it went in but past
   limits.stream_high_water bytes are queued (send no more until
   ANOLE_EV_WRITABLE). ANOLE_E_GONE once the call is over (ANOLE_EV_ABORT,
   or finished). */
ANOLE_API anole_status anole_grpc_send(anole_grpc_call c, const void *msg, size_t len, uint32_t flags);

/* anole_grpc_send for a blocking consumer thread: waits up to timeout_ms
   (< 0: no limit) for room, then sends (copied). ANOLE_E_TIMEOUT. */
ANOLE_API anole_status anole_grpc_send_wait(anole_grpc_call c, const void *msg, size_t len, int32_t timeout_ms);

/* Ends the call: the status (an ANOLE_GRPC_* code), its message (UTF-8, at
   most 64 KiB, copied; sent as grpc-message) and trailing metadata. After
   a stream's messages are sent. ANOLE_E_STATE for OK on a unary or
   client-streaming call without its message. The handle is stale after. */
ANOLE_API anole_status anole_grpc_finish(anole_grpc_call c, uint32_t code, anole_str message,
                                         const anole_header *trailers, size_t n);

/* Client and bidirectional streaming: takes n more ANOLE_EV_GRPC_MESSAGE
   events. A call starts with the service's read_ahead (default 8); Anole
   stops reading the client's messages while the credit is spent, so a
   slow consumer holds back the client (HTTP/2 flow control). ANOLE_E_STATE
   on other calls. */
ANOLE_API anole_status anole_grpc_read(anole_grpc_call c, uint32_t n);

/* grpc.health.v1 ("grpc": {"health": true}): a service's status ("" for
   the server as a whole). Every configured service and "" start SERVING;
   all turn NOT_SERVING when the server drains. Any thread, before or after
   start. ANOLE_E_STATE when health is off. */
enum { ANOLE_GRPC_HEALTH_UNKNOWN = 0, ANOLE_GRPC_HEALTH_SERVING = 1, ANOLE_GRPC_HEALTH_NOT_SERVING = 2 };
ANOLE_API anole_status anole_grpc_health_set(anole_server *s, anole_str service, uint32_t status);

/* ---- WebTransport ----------------------------------------------------------------- */

/* A "webtransport" route accepts sessions (draft-02 over HTTP/3; the route
   needs a listener with http3) and hands them to a consumer: ANOLE_EV_WT_OPEN
   with the CONNECT request, then the session's streams, data and datagrams,
   then ANOLE_EV_WT_CLOSE. Calls on a session or stream that is gone answer
   ANOLE_E_GONE. */

/* Opens a stream: both ways, or with ANOLE_WT_F_UNI write-only. The handle is
   good at once; what is written waits until the stream opens (the peer's
   stream limit may hold it). */
ANOLE_API anole_status anole_wt_open_stream(anole_wt w, uint32_t flags, anole_wt_stream *out);
/* Queues bytes to send on a stream (copied), and with ANOLE_WT_F_FIN its end
   after them. ANOLE_BODY_BORROW is taken too: the bytes are copied all the
   same, and ANOLE_EV_SENT follows (ev.handle s), as for every borrowing
   call. ANOLE_BUSY: queued, but past limits.stream_high_water bytes
   waiting: wait for ANOLE_EV_WRITABLE (ev.handle the stream). ANOLE_E_INVALID
   for a read-only stream or after its end; ANOLE_E_GONE once its sending
   side is over (reset, or stopped by the peer: ANOLE_EV_WT_STREAM_STOP). */
ANOLE_API anole_status anole_wt_stream_write(anole_wt_stream s, const void *data, size_t len, uint32_t flags);
/* Sets the stream's urgency, 0 (most urgent) to 7 (least); the default is 3
   (RFC 9218). Data of a more urgent stream goes out before any less
   urgent one's, and streams of one urgency take turns packet by packet. A
   busy stream at a low number starves the higher ones: mark audio or
   control 2, not 0. Takes effect for the next packet. ANOLE_E_INVALID above
   7 and for a read-only stream, ANOLE_E_GONE once the stream is stale. Not
   a cleanup call. (ABI 0.8) */
ANOLE_API anole_status anole_wt_stream_set_priority(anole_wt_stream s, uint32_t urgency);
/* Abandons sending (RESET_STREAM with the application code); what was
   queued is dropped. A cleanup call. */
ANOLE_API anole_status anole_wt_stream_reset(anole_wt_stream s, uint32_t code);
/* Asks the peer to stop sending (STOP_SENDING); what arrives is dropped.
   A cleanup call. */
ANOLE_API anole_status anole_wt_stream_stop(anole_wt_stream s, uint32_t code);
/* Releasing a stream (anole_handle_release): a sending side not ended with
   ANOLE_WT_F_FIN is reset and a receiving side not read to its end is
   stopped (code 0); the handle is stale at once. Every stream must be
   released with anole_handle_release (or its session closed); once the
   session is over, which can be before its ANOLE_EV_WT_CLOSE is read, the
   stream was let go with it and the release answers ANOLE_OK. */
/* Queues a datagram (copied; ANOLE_BODY_BORROW is taken as on every send
   call: the bytes are copied all the same and ANOLE_EV_SENT follows,
   ev.handle w). Datagrams are unreliable: the session keeps
   the route's datagram_queue of them waiting to go out, and past it drops
   the oldest (a datagram that waits goes stale; counted in
   anole_stats.wt_datagrams_dropped). ANOLE_E_TOOBIG past
   anole_wt_max_datagram. */
ANOLE_API anole_status anole_wt_send_datagram(anole_wt w, const void *data, size_t len, uint32_t flags);
/* The largest datagram the session takes now (it follows the path's
   packet size), 0 when the peer takes none; or ANOLE_E_GONE. */
ANOLE_API int64_t anole_wt_max_datagram(anole_wt w);
/* Closes the session with an application code and a reason (at most 1024
   bytes): every stream is reset, and ANOLE_EV_WT_CLOSE follows. A cleanup
   call. */
ANOLE_API anole_status anole_wt_close(anole_wt w, uint32_t code, anole_str reason);

/* ---- databases ---------------------------------------------------------------- */

/* A database from the configuration's "databases": SQLite, PostgreSQL,
   Redis or MongoDB. Statements run on Anole's threads and never
   block the caller: each call queues one, and its answer comes back as an
   ANOLE_EV_DB_RESULT to the consumer named in the call, with the caller's
   user_data. SQLite: reads run beside the writer (WAL), writes take turns on
   the database's writer thread. PostgreSQL, Redis and MongoDB: each
   executor has its own pool of connections. Statements may be queued from
   anole_server_open (or start) until the server stops; open transactions are
   rolled back at the stop, and nothing queued then is answered
   (ANOLE_EV_STOPPED is the consumer's last event). Every query is bounded by
   the database's timeout_ms (30 s by default) unless it names its own. */
typedef struct anole_db anole_db; /* opaque; lives until anole_server_destroy */

/* The database named `name` in the configuration (after
   anole_server_create). ANOLE_E_INVALID when there is none. */
ANOLE_API anole_status anole_db_find(anole_server *s, anole_str name, anole_db **out);

/* Value and cell types. ANOLE_DB_TYPE_BOOL holds 0 or 1 in `i`. ARRAY, MAP and
   ERROR are cells of a Redis reply only, BSON of a MongoDB answer (see
   anole_db_cell). */
enum {
  ANOLE_DB_TYPE_NULL = 0,
  ANOLE_DB_TYPE_INT = 1,
  ANOLE_DB_TYPE_FLOAT = 2,
  ANOLE_DB_TYPE_TEXT = 3,
  ANOLE_DB_TYPE_BLOB = 4,
  ANOLE_DB_TYPE_BOOL = 5,
  ANOLE_DB_TYPE_ARRAY = 6,
  ANOLE_DB_TYPE_MAP = 7,
  ANOLE_DB_TYPE_ERROR = 8,
  ANOLE_DB_TYPE_BSON = 9
};

/* A parameter: binds SQLite's `?` (or `?NNN`), PostgreSQL's $1, $2... in
   order. Text and blobs are copied by the call. SQLite binds a bool as 1 or
   0. PostgreSQL sends each value as the parameter's type when it can (an
   int to int2/int4/int8/numeric, a blob to bytea), else as text that
   PostgreSQL parses into that type: text holding '2026-10-22T10:00:00Z' for
   a timestamptz, '{1,2}' for an int4[], an int for a text parameter.
   Redis: `sql` holds the command's name and any fixed words ("GET",
   "CLIENT INFO"), split on spaces; each parameter is one more argument,
   binary-safe: text and blobs as they are, numbers in decimal, a bool as 1
   or 0, NULL left out. Keys and values always go in parameters.
   MongoDB: `sql` names the operation and the collection, and optionally a
   database other than the configured one ("find users", "aggregate events
   analytics"); runCommand takes only the database, optionally. Each
   parameter is a BSON document (ANOLE_DB_TYPE_BLOB), in the order the drivers'
   methods take them: find(filter, options), findOne(filter, options),
   aggregate(pipeline, options), countDocuments(filter, options),
   insertOne(document), insertMany(document, ...), updateOne/updateMany(
   filter, update or pipeline, options), replaceOne(filter, replacement,
   options), deleteOne/deleteMany(filter, options), runCommand(command).
   Options use the command's own names (sort, projection, limit, skip,
   batchSize, allowDiskUse, upsert, arrayFilters, hint, collation...). A
   pipeline is a BSON array (or a document whose values are the stages). */
typedef struct anole_db_value {
  uint32_t type; /* ANOLE_DB_* */
  uint32_t reserved; /* must be 0 */
  union {
    int64_t i;   /* ANOLE_DB_TYPE_INT, ANOLE_DB_TYPE_BOOL */
    double f;    /* ANOLE_DB_TYPE_FLOAT */
    anole_str s; /* ANOLE_DB_TYPE_TEXT (UTF-8), ANOLE_DB_TYPE_BLOB */
  } v;
} anole_db_value;

/* Query flags. ANOLE_DB_F_WRITE (SQLite): run on the writer, for a statement
   that writes but does not look like it (a SELECT with side effects).
   ANOLE_DB_F_COALESCE: identical reads in flight at once (same statement and
   parameters) share one run, each caller getting its own answer.
   ANOLE_DB_F_NO_PREPARE: do not keep the prepared statement (SQL built at run
   time). ANOLE_DB_F_DROP_EMPTY: with a cache_ttl_ms, an answer with no row is
   served but not kept (cache-aside). ANOLE_DB_F_RETRY: the query may run
   again on a transient failure (the server unreachable, a connection lost),
   with the database's "retry" configuration; only for statements safe to
   repeat. Refused (ANOLE_E_INVALID) on anole_db_tx_*; SQLite and MongoDB
   ignore it. */
#define ANOLE_DB_F_WRITE 1u
#define ANOLE_DB_F_COALESCE 2u
#define ANOLE_DB_F_NO_PREPARE 4u
#define ANOLE_DB_F_DROP_EMPTY 8u
#define ANOLE_DB_F_RETRY 16u

/* anole_db_options.timeout_ms: no bound for this query. */
#define ANOLE_DB_TIMEOUT_NONE 0xFFFFFFFFu

typedef struct anole_db_options {
  size_t size;           /* sizeof(anole_db_options): fields past it read as 0 */
  uint32_t flags;        /* ANOLE_DB_F_* (unknown bits: ANOLE_E_INVALID) */
  uint32_t timeout_ms;   /* 0: the database's timeout_ms (30 s by default);
                            ANOLE_DB_TIMEOUT_NONE: none. Past it the statement is
                            interrupted (ANOLE_E_TIMEOUT); PostgreSQL also gets a
                            CancelRequest */
  uint32_t cache_ttl_ms; /* reads: keep the answer this long per executor, served
                            from memory meanwhile; 0: not kept */
  uint32_t reserved;     /* must be 0 */
  anole_str cache_tag;   /* a name to drop kept answers by (anole_db_invalidate); copied */
  uint64_t req;          /* ABI 0.7: the anole_req or anole_grpc_call this query
                            serves, or 0. It runs on that request's executor (its
                            pools and cache) and answers to the consumer that
                            polled it; `c` may then be NULL. When the request is
                            aborted or passes its deadline, the query is canceled
                            and answers ANOLE_E_GONE; an answered request leaves
                            it running (bounded by timeout_ms). A stale req:
                            ANOLE_E_GONE from the call, nothing queued. Another
                            handle kind: ANOLE_E_INVALID. */
} anole_db_options; /* 48 bytes (was 40) */

/* Queues a read (or any statement that returns rows): the answer holds the
   column names and every row. `params` (copied) bind in order; `opts` may
   be NULL. `c` receives the answer; it must be fed by at least one
   executor (ANOLE_E_STATE otherwise, or after the stop). `c` may be NULL
   only with opts->req, where the answer goes to that request's consumer (a
   non-NULL `c` must be it: ANOLE_E_INVALID otherwise). The answer's status
   is also ANOLE_E_GONE when the request it served ended first.
   ANOLE_E_INVALID: a bad value type or options size. Returns at once.
   Redis: runs the command and answers with its whole reply. timeout_ms,
   ANOLE_DB_F_COALESCE and cache_ttl_ms apply; the last two only to commands
   that just read (GET, MGET, HGETALL, LRANGE, ZRANGE... as anole.redis's
   read_commands), others run as they are. */
ANOLE_API anole_status anole_db_query(anole_db *db, anole_consumer *c, anole_str sql, const anole_db_value *params,
                                      size_t nparams, const anole_db_options *opts, uint64_t user_data);
/* Queues a write (SQLite: on the writer): the answer has `changes` and, for
   SQLite, `last_insert_rowid` (PostgreSQL: 0; use RETURNING with
   anole_db_query), and no rows. With no parameters, `sql` may hold several
   statements (a schema), run in order. Redis: runs the command and answers
   with no cells; `changes` is its reply when that is an integer (DEL,
   INCR, LPUSH...), else 0. MongoDB: no cells; `changes` is the documents
   inserted, modified (and upserted) or deleted, or for a read the count. */
ANOLE_API anole_status anole_db_exec(anole_db *db, anole_consumer *c, anole_str sql, const anole_db_value *params,
                                     size_t nparams, const anole_db_options *opts, uint64_t user_data);
/* Drops the answers kept with cache_tag `tag` on every executor ({NULL, 0}:
   every kept answer), and keeps reads that started before from filling the
   cache. Call it after a write commits. */
ANOLE_API anole_status anole_db_invalidate(anole_db *db, anole_str tag);

/* ---- database transactions ------------------------------------------------- */

/* One transaction on one connection of one executor: from the
   ANOLE_EV_DB_RESULT that answers anole_db_begin (its ev.handle) until
   anole_db_tx_commit, anole_db_tx_rollback or anole_db_tx_release is
   called. SQLite and PostgreSQL only. */

/* anole_db_tx_options.flags. PostgreSQL: BEGIN READ ONLY. SQLite: on a
   reader connection, a snapshot that writes do not disturb (the writer
   when the database has no readers, as ":memory:"). */
#define ANOLE_DB_TX_READ_ONLY 1u

/* anole_db_tx_options.isolation. SQLite is always serializable and takes
   any of them. */
enum {
  ANOLE_DB_ISOLATION_DEFAULT = 0, /* the database's own default */
  ANOLE_DB_ISOLATION_READ_UNCOMMITTED = 1,
  ANOLE_DB_ISOLATION_READ_COMMITTED = 2,
  ANOLE_DB_ISOLATION_REPEATABLE_READ = 3,
  ANOLE_DB_ISOLATION_SERIALIZABLE = 4
};

typedef struct anole_db_tx_options {
  size_t size;         /* sizeof(anole_db_tx_options) */
  uint32_t flags;      /* ANOLE_DB_TX_*; other bits: ANOLE_E_INVALID */
  uint32_t isolation;  /* ANOLE_DB_ISOLATION_* */
  uint32_t timeout_ms; /* the whole transaction, from begin to commit, idle time
                          included: past it, it is rolled back. 0: the
                          database's timeout_ms; ANOLE_DB_TIMEOUT_NONE: none */
  uint32_t reserved;   /* 0 */
  uint64_t req;        /* the anole_req or anole_grpc_call it serves, or 0 (see
                          anole_db_options.req) */
} anole_db_tx_options; /* 32 bytes */

/* Queues a BEGIN. The answer (ANOLE_EV_DB_RESULT to `c`) carries the new
   transaction in ev.handle when status is ANOLE_OK, else 0 with the reason
   (ANOLE_E_DB, error_class UNAVAILABLE: no connection in time; ANOLE_E_TIMEOUT:
   the SQLite writer or a connection was not had within timeout_ms;
   ANOLE_E_GONE: the request it serves ended first). `opts` may be NULL.
   With opts->req, the transaction runs on that request's executor and `c`
   may be NULL (if given, it must be the consumer that request came to).
   Returns ANOLE_E_UNSUPPORTED for Redis and MongoDB (and when SQLite and
   PostgreSQL are not built in), ANOLE_E_GONE for a stale opts->req,
   ANOLE_E_INVALID for bad options, ANOLE_E_STATE before the databases are
   open or after the stop. */
ANOLE_API anole_status anole_db_begin(anole_db *db, anole_consumer *c, const anole_db_tx_options *opts,
                                      uint64_t user_data);
/* anole_db_query and anole_db_exec inside the transaction. Calls on one
   transaction run one at a time, in the order made; the consumer may queue
   several without waiting for answers. Each answer is an
   ANOLE_EV_DB_RESULT whose ev.handle is the transaction. `opts`: only
   timeout_ms and ANOLE_DB_F_NO_PREPARE apply; any other flag, a
   cache_ttl_ms, a cache_tag or a req is ANOLE_E_INVALID. ANOLE_E_GONE once
   the transaction is over, or once commit, rollback or release was called.
   A failed statement does not end the transaction: PostgreSQL then refuses
   every later statement until the rollback (SQLSTATE 25P02; use SAVEPOINT
   to recover part of it), SQLite keeps what the others did. */
ANOLE_API anole_status anole_db_tx_query(anole_db_tx tx, anole_str sql, const anole_db_value *params,
                                         size_t nparams, const anole_db_options *opts, uint64_t user_data);
ANOLE_API anole_status anole_db_tx_exec(anole_db_tx tx, anole_str sql, const anole_db_value *params,
                                        size_t nparams, const anole_db_options *opts, uint64_t user_data);
/* Queue COMMIT (ROLLBACK) after the calls already queued; from this call on
   the handle takes nothing more. Answered with ev.handle the transaction:
   ANOLE_OK, or ANOLE_E_DB when the commit was refused (error_class
   SERIALIZATION: lost a race, 409) or the transaction had failed and was
   rolled back instead (PostgreSQL). Either way the connection goes back and
   the handle is stale once the answer is queued. ANOLE_E_GONE when the
   transaction is already over (timed out, its request ended, released). */
ANOLE_API anole_status anole_db_tx_commit(anole_db_tx tx, uint64_t user_data);
ANOLE_API anole_status anole_db_tx_rollback(anole_db_tx tx, uint64_t user_data);
/* Cleanup, for finalizers and `finally`: rolls back an open transaction now
   and gives its connection back. Calls queued and not started answer
   ANOLE_E_GONE; one running is interrupted (SQLite) or canceled (PostgreSQL
   CancelRequest) and answers ANOLE_E_GONE; the release itself is not
   answered. ANOLE_OK on a transaction already over or released;
   ANOLE_E_INVALID for 0 or a handle of another kind. anole_handle_release
   does the same for an anole_db_tx.

   How a transaction ends, and what its queued and running calls answer:
     commit / rollback        they run first, answered normally; then COMMIT or
                              ROLLBACK is answered
     anole_db_tx_release      ANOLE_E_GONE; ROLLBACK, not answered
     its timeout_ms           ANOLE_E_TIMEOUT (error_class TIMEOUT, http_status
                              504); ROLLBACK
     its request aborted or   ANOLE_E_GONE; ROLLBACK
     past its deadline
     its request answered     nothing: it goes on, bounded by timeout_ms
     the server stops         no answer (ANOLE_EV_STOPPED is the consumer's
                              last event); ROLLBACK
   A later call on the stale handle returns ANOLE_E_GONE at once;
   anole_last_error says which ending it was. A read-write SQLite
   transaction holds the database's writer: every other write waits, so a
   forgotten transaction blocks writes for at most timeout_ms. */
ANOLE_API anole_status anole_db_tx_release(anole_db_tx tx);

/* Where an answer came from. */
enum { ANOLE_DB_FROM_DATABASE = 0, ANOLE_DB_FROM_COALESCED = 1, ANOLE_DB_FROM_CACHE = 2 };

/* What kind of failure (error_class), for every database Anole speaks. */
enum {
  ANOLE_DB_ERR_NONE = 0,
  ANOLE_DB_ERR_UNIQUE = 1,        /* a unique or primary key */
  ANOLE_DB_ERR_EXCLUSION = 2,
  ANOLE_DB_ERR_FOREIGN_KEY = 3,
  ANOLE_DB_ERR_NOT_NULL = 4,
  ANOLE_DB_ERR_CHECK = 5,
  ANOLE_DB_ERR_SERIALIZATION = 6, /* lost a race with another transaction */
  ANOLE_DB_ERR_DEADLOCK = 7,
  ANOLE_DB_ERR_UNAVAILABLE = 8,   /* no connection, or busy past its timeout */
  ANOLE_DB_ERR_TIMEOUT = 9,
  ANOLE_DB_ERR_OTHER = 10         /* syntax, a wrong parameter count, ... */
};

/* One cell of a row. Text and blobs are spans in the record.
   SQLite: each cell has its own type (NULL, INT, FLOAT, TEXT, BLOB);
   db_type is 0.
   PostgreSQL: db_type is the column's type OID (pg_type.oid: 16 bool, 20
   int8, 1700 numeric, 1184 timestamptz, 3802 jsonb...). bool is
   ANOLE_DB_TYPE_BOOL; int2, int4, int8, oid and xid are ANOLE_DB_TYPE_INT; float4 and
   float8 are ANOLE_DB_TYPE_FLOAT; bytea is ANOLE_DB_TYPE_BLOB; every other type is
   ANOLE_DB_TYPE_TEXT in PostgreSQL's text format (as psql prints it: numeric
   exactly, '2026-10-22 10:00:00+00', '{1,2}', JSON text), for the caller to
   parse by db_type, as the language's own PostgreSQL drivers do.
   Redis: the reply is a tree of cells in preorder, with no columns
   (ncolumns 0, nrows the number of cells). Bulk strings are BLOB (bytes,
   often UTF-8), status replies ("OK") TEXT, integers INT, nil NULL, RESP3
   doubles FLOAT and booleans BOOL. An ARRAY cell with `i` = n is followed by
   its n items, each a whole subtree; a MAP with `i` = n by n key, value
   pairs. ERROR (text) is an error reply inside another, as EXEC's.
   MongoDB: one column, "document". find, findOne and aggregate answer a
   row per document, each cell ANOLE_DB_TYPE_BSON (the document's bytes, for the
   binding's BSON library); countDocuments one ANOLE_DB_TYPE_INT; the writes one
   BSON row with the driver's result ({insertedId}, {insertedCount,
   insertedIds}, {matchedCount, modifiedCount, upsertedId}, {deletedCount});
   runCommand one BSON row, the server's reply. */
typedef struct anole_db_cell {
  uint32_t type;    /* ANOLE_DB_* */
  uint32_t db_type; /* PostgreSQL: the type OID; 0 otherwise */
  union {
    int64_t i;
    double f;
    anole_span s;
  } v;
} anole_db_cell;

/* ANOLE_EV_DB_RESULT: ev.handle is 0 for a plain query, and the transaction
   (the new one, for anole_db_begin's answer) for a call on one; user_data as
   given to the call.
   Followed by the column names (`columns`: ncolumns anole_span), the cells
   (`cells`: nrows * ncolumns anole_db_cell, row after row) and their bytes.
   A large answer makes a large record: anole_poll answers ANOLE_E_TOOBIG
   until its buffer fits it (limits.db_result_max bounds it). */
typedef struct anole_db_result_event {
  anole_event ev;
  uint64_t user_data;
  int32_t status;       /* ANOLE_OK; ANOLE_E_DB (error_class says why), ANOLE_E_TIMEOUT
                           (timeout_ms), ANOLE_E_TOOBIG (past limits.db_result_max),
                           ANOLE_E_NOMEM */
  uint16_t http_status; /* the status Anole's own handlers answer for this failure
                           (409 unique, 503 unavailable, 504 timeout, 500 other); 0 on success */
  uint8_t error_class;  /* ANOLE_DB_ERR_* */
  uint8_t source;       /* ANOLE_DB_FROM_* */
  uint32_t ncolumns;
  uint32_t nrows;
  uint64_t changes;          /* anole_db_exec: rows changed */
  int64_t last_insert_rowid; /* anole_db_exec, SQLite: the rowid of the last row inserted */
  anole_span columns;
  anole_span cells;
  anole_span error;      /* the database's message (for logs; not for clients) */
  anole_span error_code; /* the database's own code as text (SQLite's extended code,
                            PostgreSQL's SQLSTATE, the first word of a Redis error,
                            MongoDB's error code: "11000") */
  anole_span constraint; /* the constraint that failed, when the database names it */
  anole_span table;      /* ABI 0.7: the table (or collection) the error names, when the database says */
} anole_db_result_event; /* 104 bytes (was 96) */

#ifdef __cplusplus
}
#endif
#endif /* ANOLE_H */
