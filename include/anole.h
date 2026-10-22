/* anole.h - the C ABI of Anole (https://github.com/xuckless/anole). MIT.
 *
 * ABI 0.1. Plain C99 (also valid C++), no Zig types. The reference for
 * binding authors is docs/c-abi.md; this header is the contract, and every
 * function below says who owns what and for how long.
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
 *  - Handles (anole_req, anole_ws) are 64-bit and generation-checked: a
 *    stale, finished or made-up handle gets ANOLE_E_GONE, never undefined
 *    behaviour.
 *  - Anole enforces deadlines: a request not answered within its timeout
 *    gets 504 from Anole, and a late answer gets ANOLE_E_GONE.
 *
 * Threads. Every function may be called from any thread unless it says
 * otherwise. A request or WebSocket handle is meant to be used by the thread
 * that polled it; another thread may use it with the binding's own
 * synchronization (calls on one handle must not overlap). anole_poll on one
 * consumer must not overlap with itself (a shared consumer serializes it).
 * No function may be called from inside the wake or log callbacks.
 *
 * Wake contract: "at least once, may repeat". After anole_poll returns 0,
 * the wake callback (or the fd) fires at least once when new events become
 * available; it may also fire when there turn out to be none (Anole rings
 * again when a ring stays unpolled for timeouts.rewake_ms, because some
 * runtimes lose threadsafe-function calls). A poll that returns 0 is cheap.
 */
#ifndef ANOLE_H
#define ANOLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ANOLE_ABI_VERSION_MAJOR 0 /* breaking changes */
#define ANOLE_ABI_VERSION_MINOR 1 /* additions */
#define ANOLE_ABI_VERSION ((ANOLE_ABI_VERSION_MAJOR << 16) | ANOLE_ABI_VERSION_MINOR)

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
                               ANOLE_EV_WRITABLE / ANOLE_EV_WS_DRAIN */
  ANOLE_E_INVALID = -1,     /* bad argument (a handle is still owed) */
  ANOLE_E_GONE = -2,        /* handle answered, expired, aborted or stale */
  ANOLE_E_AGAIN = -3,       /* nothing now; an event follows (see the call) */
  ANOLE_E_NOMEM = -4,
  ANOLE_E_CONFIG = -5,      /* see anole_last_error */
  ANOLE_E_STATE = -6,       /* not allowed in this state */
  ANOLE_E_UNSUPPORTED = -7, /* compiled out, or not on this OS */
  ANOLE_E_TOOBIG = -8,      /* anole_poll: the next event does not fit */
  ANOLE_E_SYSTEM = -9,      /* the OS refused (threads, sockets, files) */
  ANOLE_E_TIMEOUT = -10     /* a blocking call's timeout passed */
};

/* The text of the last error on the calling thread: valid until the next
   anole_* call on that thread. Empty when there is none. */
ANOLE_API anole_str anole_last_error(void);
/* Compare with ANOLE_ABI_VERSION at load: the major must match, the minor
   must be >= the header's. */
ANOLE_API uint32_t anole_abi_version(void);
/* Anole's version, such as "0.2.0"; static storage. */
ANOLE_API anole_str anole_version(void);
/* 1 when `name` is built in, else 0: "tls", "http2", "http3", "websocket",
   "compression", "brotli", "auth", "sqlite". */
ANOLE_API int anole_has_feature(anole_str name);

/* 64-bit, generation-checked; 0 is never valid. */
typedef uint64_t anole_req; /* one request: from ANOLE_EV_REQUEST until answered */
typedef uint64_t anole_ws;  /* one WebSocket: from ANOLE_EV_WS_OPEN until ANOLE_EV_WS_CLOSE */
typedef struct anole_server anole_server;     /* opaque */
typedef struct anole_consumer anole_consumer; /* opaque */

/* ---- lifecycle ------------------------------------------------------------- */

/* Embedded processes (Node, Python) own their signals, so by default Anole
   installs no signal handlers and only anole_server_drain stops it. A
   standalone C program may ask for SIGINT/SIGTERM (drain) and SIGHUP
   (reload certificates) with this flag. */
#define ANOLE_SERVER_SIGNALS 1u

/* Log levels, for the log callback and anole_server_options.log_level.
   Debug lines exist only in Debug builds of libanole. */
enum { ANOLE_LOG_ERROR = 1, ANOLE_LOG_WARN = 2, ANOLE_LOG_INFO = 3, ANOLE_LOG_DEBUG = 4 };

typedef struct anole_server_options {
  size_t size;           /* sizeof(anole_server_options): fields past it read as 0 */
  anole_str config_json; /* the configuration; copied by anole_server_create */
  uint32_t flags;        /* ANOLE_SERVER_* */
  int32_t log_level;     /* the most verbose level passed on (ANOLE_LOG_*); 0: ANOLE_LOG_INFO */
  /* Receives Anole's log lines instead of stderr. Called on any Anole
     thread, possibly several at once; `scope` and `msg` are valid during the
     call only. Must not block and must not enter the language (append to a
     buffer the consumer flushes). NULL: stderr. Process-wide, set by the
     first anole_server_create. */
  void (*log)(void *ud, int level, anole_str scope, anole_str msg);
  void *log_ud;
} anole_server_options;

/* Parses and checks the configuration and binds nothing. One server per
   process (ANOLE_E_STATE for a second until the first is destroyed).
   ANOLE_E_CONFIG: anole_last_error says what and where. */
ANOLE_API anole_status anole_server_create(const anole_server_options *options, anole_server **out);
/* Starts Anole's threads and binds every listener; returns once listening,
   or with the error (the server may then only be destroyed). Consumers
   attach before this. */
ANOLE_API anole_status anole_server_start(anole_server *s);
/* The bound port of listener i, in configuration order (the real one when
   port 0 was asked for); i = the number of listeners: the HTTP/3 (UDP)
   port, when a listener serves HTTP/3. ANOLE_E_INVALID past the last. */
ANOLE_API anole_status anole_server_port(anole_server *s, uint32_t i, uint16_t *out);
/* Stops accepting and drains: HTTP/2 and HTTP/3 GOAWAY, WebSockets close
   1001, requests in flight finish within timeouts.shutdown_ms. Returns at
   once; again is a no-op. Consumers keep polling and answering until they
   see ANOLE_EV_STOPPED. */
ANOLE_API anole_status anole_server_drain(anole_server *s);
/* Blocks the calling thread until the server has stopped (after a drain):
   timeout_ms < 0 waits for ever; ANOLE_E_TIMEOUT when it passes. Never on
   a thread that must keep polling a consumer of this server meanwhile. */
ANOLE_API anole_status anole_server_wait(anole_server *s, int32_t timeout_ms);
/* Reads every TLS listener's certificate files again and swaps them in;
   handshakes under way keep the old ones. */
ANOLE_API anole_status anole_server_reload_certificates(anole_server *s);
/* Drains if still running, waits for the stop, joins Anole's threads and
   frees everything, consumers included. No handle, consumer or pointer
   from this server may be used afterwards. NULL is a no-op. */
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
} anole_stats;
/* Counters since start. Fills what out->size covers. */
ANOLE_API anole_status anole_server_stats(anole_server *s, anole_stats *out);

/* ---- consumers and events --------------------------------------------------- */

/* Many threads poll this consumer (a WSGI thread pool) with anole_poll_wait;
   each call takes at most one event. */
#define ANOLE_CONSUMER_SHARED 1u

typedef struct anole_consumer_options {
  size_t size; /* sizeof(anole_consumer_options) */
  /* Called on an Anole thread when events become available after a poll
     returned 0 (the wake contract above). Must not block and must not enter
     the language: napi_call_threadsafe_function(nonblocking), a write to an
     eventfd or a socket, PostQueuedCompletionStatus. NULL: use
     anole_consumer_fd, or anole_poll_wait. */
  void (*wake)(void *ud);
  void *wake_ud;
  uint32_t flags; /* ANOLE_CONSUMER_* */
} anole_consumer_options;

/* Before anole_server_start: executors are shared out among the consumers
   at start (executor e feeds consumer e mod M). Lives until
   anole_server_destroy. */
ANOLE_API anole_status anole_consumer_attach(anole_server *s, const anole_consumer_options *options,
                                             anole_consumer **out);
/* The doorbell fd when no wake callback was given: readable when events
   may be available (the wake contract). anole_poll empties it; the consumer
   never reads it itself. -1 with a callback, for a shared consumer, and on
   Windows (pass a callback there). Closed by anole_server_destroy. */
ANOLE_API int anole_consumer_fd(anole_consumer *c);

enum anole_event_type {
  ANOLE_EV_REQUEST = 1,    /* anole_request_event; handle: anole_req */
  ANOLE_EV_BODY = 2,       /* anole_event: more request body to read (after ANOLE_E_AGAIN) */
  ANOLE_EV_ABORT = 3,      /* anole_event: the client went away (or the drain cut the request);
                              the handle is stale from now on and nothing more is owed */
  ANOLE_EV_WRITABLE = 4,   /* anole_event: a streamed response that took ANOLE_BUSY has room */
  ANOLE_EV_SENT = 5,       /* anole_sent_event: a borrowed body is no longer read */
  ANOLE_EV_WS_OPEN = 6,    /* anole_request_event (the upgrade request); handle: anole_ws */
  ANOLE_EV_WS_MESSAGE = 7, /* anole_ws_message_event */
  ANOLE_EV_WS_CLOSE = 8,   /* anole_ws_close_event: the handle is stale from now on */
  ANOLE_EV_WS_DRAIN = 9,   /* anole_event: a WebSocket that took ANOLE_BUSY has room */
  ANOLE_EV_DB_RESULT = 10, /* reserved for anole_db_* */
  ANOLE_EV_STOPPED = 11    /* anole_event: the server stopped; the consumer's last event */
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

/* ANOLE_EV_REQUEST and ANOLE_EV_WS_OPEN. Followed by
   `anole_span headers[2 * nheaders]` (name, value: names lower-cased, order
   and duplicates kept), then `anole_span params[2 * nparams]` (route
   parameters: name, value), then the bytes the spans point into. */
typedef struct anole_request_event {
  anole_event ev;
  uint32_t route_id;       /* the route's "handler" id */
  uint8_t method;          /* enum anole_method */
  uint8_t version;         /* 10, 11, 20, 30 */
  uint16_t flags;          /* ANOLE_REQ_* */
  anole_span method_name;  /* "GET", ... (any method, as sent) */
  anole_span path;         /* raw, not percent-decoded */
  anole_span query;        /* after '?', raw; empty when none */
  anole_span body;         /* with ANOLE_REQ_BODY_INLINE */
  anole_span remote_addr;  /* the client, "ip:port" ("[ip]:port" for IPv6), proxies applied */
  anole_span listener;     /* the listener's name */
  anole_span id;           /* the request ID (request_id middleware), else empty */
  anole_span claims;       /* a verified JWT's claims as JSON (jwt middleware), else empty */
  uint16_t nheaders;
  uint16_t nparams;
  uint32_t reserved;
  uint64_t content_length; /* UINT64_MAX when unknown */
} anole_request_event;

/* ANOLE_EV_SENT: Anole no longer reads the memory of a body passed with
   ANOLE_BODY_BORROW (to anole_respond or anole_stream_write on the request
   ev.handle, or anole_ws_send on the socket ev.handle; the handle may be
   stale by now). */
typedef struct anole_sent_event {
  anole_event ev;
  uint64_t data; /* the body's address, as passed */
  uint64_t len;
} anole_sent_event;

enum { ANOLE_WS_TEXT = 1, ANOLE_WS_BINARY = 2 };

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

static inline anole_str anole_event_str(const void *record, anole_span s) {
  anole_str r;
  r.ptr = (const char *)record + s.off;
  r.len = s.len;
  return r;
}
static inline const anole_span *anole_request_spans(const anole_request_event *r) {
  return (const anole_span *)(r + 1);
}

/* Drains events into buf (caller-owned, 8-byte aligned; the caller owns the
   bytes written). Returns the bytes written, a packed sequence of records;
   0 means nothing is pending and the doorbell is armed again (after every
   wake, poll until 0). ANOLE_E_TOOBIG: the next record needs more than
   `cap` (it stays queued; size the buffer for the largest request head
   plus limits.inline_body_max, or limits.ws_max_message). Not concurrently
   with itself on one consumer. A shared consumer returns one event per call.
   ANOLE_POLL_NOARM: a 0 return leaves the doorbell disarmed, so producers
   skip the wake while the consumer spins on NOARM polls for a few
   microseconds; it must end with a plain poll before it sleeps. */
#define ANOLE_POLL_NOARM 1u
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
   ANOLE_EV_SENT for them (which arrives even when the client is gone or
   the call fails with ANOLE_E_GONE after taking them). Bindings borrow
   large bodies (above 64 KiB, say) and copy small ones. */
#define ANOLE_BODY_BORROW 1u

/* The whole response: status (a code in the IANA registry, or one of the
   common unregistered ones Anole knows), headers and body. Headers and,
   unless borrowed, the body are copied before this returns. Compression,
   the response cache and the access log run on Anole's side afterwards.
   Finishes the request. ANOLE_E_INVALID: a bad status, flag, header name
   or value (nothing taken, the request is still owed); ANOLE_E_GONE. */
ANOLE_API anole_status anole_respond(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders,
                                     const void *body, size_t len, uint32_t flags);
/* Sends `len` bytes of the open regular file `fd` from `offset` (len 0: to
   the end of the file) as the body, with Content-Length set by Anole. Anole
   duplicates fd before returning, so the caller may close its own at once.
   Finishes the request. ANOLE_E_UNSUPPORTED on Windows. */
ANOLE_API anole_status anole_respond_fd(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders,
                                        int fd, uint64_t offset, uint64_t len);
/* Starts a streamed response: the head goes out now (copied); the body
   follows with anole_stream_write, and anole_stream_end finishes it. The
   request deadline no longer applies once a stream has started. */
ANOLE_API anole_status anole_stream_start(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders);
/* Queues body bytes (copied, or borrowed with ANOLE_BODY_BORROW). Returns
   ANOLE_OK, or ANOLE_BUSY when the bytes are taken but more than
   limits.stream_high_water bytes wait to go out: write no more until
   ANOLE_EV_WRITABLE. ANOLE_E_GONE when the client is gone (ANOLE_EV_ABORT
   is on its way). */
ANOLE_API anole_status anole_stream_write(anole_req r, const void *data, size_t len, uint32_t flags);
/* anole_stream_write for a thread that may block (WSGI): waits up to
   timeout_ms (< 0: for ever) for the queue to fall below the high-water
   mark, then copies the bytes. ANOLE_E_TIMEOUT: nothing taken. Never on an
   Anole thread. */
ANOLE_API anole_status anole_stream_write_wait(anole_req r, const void *data, size_t len, int32_t timeout_ms);
/* Ends a streamed response, with trailers (HTTP/2 and HTTP/3 send them;
   HTTP/1.1 drops them), copied. Finishes the request. */
ANOLE_API anole_status anole_stream_end(anole_req r, const anole_header *trailers, size_t ntrailers);
/* Gives up on the request: the client gets 500, or, once a stream has
   started, a cut-short response (HTTP/2 and HTTP/3 reset the stream,
   HTTP/1.1 closes the connection). Finishes the request. */
ANOLE_API anole_status anole_release(anole_req r);

/* ---- WebSocket -------------------------------------------------------------------- */

/* Sends one message: ANOLE_WS_TEXT (valid UTF-8 is the caller's to keep) or
   ANOLE_WS_BINARY; copied, or borrowed with ANOLE_BODY_BORROW (then
   ANOLE_EV_SENT follows with ev.handle = w). Returns ANOLE_OK, or
   ANOLE_BUSY when taken but more than limits.ws_high_water bytes wait to go
   out (send no more until ANOLE_EV_WS_DRAIN). ANOLE_E_GONE once closed. */
ANOLE_API anole_status anole_ws_send(anole_ws w, int type, const void *data, size_t len, uint32_t flags);
/* Sends a close frame (a code a peer may send: 1000-1003, 1007-1014 or
   3000-4999; a reason of up to 123 bytes, copied);
   ANOLE_EV_WS_CLOSE follows once the socket is done. */
ANOLE_API anole_status anole_ws_close(anole_ws w, uint16_t code, anole_str reason);
/* Joins or leaves a topic (copied, 1-255 bytes). A socket leaves every
   topic when it closes. */
ANOLE_API anole_status anole_ws_subscribe(anole_ws w, anole_str topic);
ANOLE_API anole_status anole_ws_unsubscribe(anole_ws w, anole_str topic);
/* Sends one message to every socket subscribed to `topic` but `except` (0:
   none), fanned out on Anole's threads; returns at once (topic and data
   copied). */
ANOLE_API anole_status anole_ws_publish(anole_server *s, anole_str topic, int type, const void *data, size_t len,
                                        anole_ws except);

#ifdef __cplusplus
}
#endif
#endif /* ANOLE_H */
