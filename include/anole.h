/* anole.h - the C ABI of Anole (https://github.com/xuckless/anole). MIT.
 *
 * SPIKE (M17, 2026-10-21): the subset needed to prove the crossing design
 * (research/c-abi-design-2026-10-21.md). Shapes are not frozen; the ABI
 * version stays 0.0 until they are.
 *
 * Plain C99, no Zig types. Link libanole.a (static); it exports only
 * anole_* symbols.
 *
 * The model:
 *  - anole_server_create parses one JSON configuration (listeners, routes);
 *    nothing is bound until anole_server_start, which starts Anole's own
 *    threads (one "executor" per core) and returns once listening.
 *  - A route either answers natively ("respond": a fixed response, served
 *    on the executors with no consumer involved) or names a "handler" id:
 *    its requests go to a consumer.
 *  - A consumer is one language thread (Node's main thread or a worker, an
 *    asyncio loop, a C thread). Anole never calls into it, except for the
 *    non-blocking wake callback, called on an Anole thread when events
 *    become available after anole_poll returned 0. Without a callback,
 *    anole_consumer_fd gives a readable fd (eventfd on Linux, a pipe
 *    elsewhere).
 *  - The consumer drains events with anole_poll into its own buffer, and
 *    answers each request exactly once with anole_respond (or
 *    anole_release), from any thread.
 *  - Anole enforces the request deadline (timeouts.request_ms): the client
 *    gets 504, and a reply after that returns ANOLE_E_GONE, as does any
 *    stale or unknown handle. Never undefined behaviour.
 */
#ifndef ANOLE_H
#define ANOLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ANOLE_ABI_VERSION_MAJOR 0 /* breaking changes */
#define ANOLE_ABI_VERSION_MINOR 0 /* additions; 0.0 = spike, unfrozen */
#define ANOLE_ABI_VERSION ((ANOLE_ABI_VERSION_MAJOR << 16) | ANOLE_ABI_VERSION_MINOR)

/* libanole is linked statically: declarations need no import attribute.
   Define ANOLE_SHARED when linking the shared library on Windows. */
#if defined(_WIN32) && defined(ANOLE_SHARED)
#define ANOLE_API __declspec(dllimport)
#else
#define ANOLE_API
#endif

/* ---- basics ------------------------------------------------------------ */

/* A byte string; not NUL-terminated. */
typedef struct anole_str {
  const char *ptr;
  size_t len;
} anole_str;

typedef struct anole_header {
  anole_str name;
  anole_str value;
} anole_header;

typedef int32_t anole_status; /* 0 = ok, < 0 = ANOLE_E_* */
enum {
  ANOLE_OK = 0,
  ANOLE_E_INVALID = -1,     /* bad argument */
  ANOLE_E_GONE = -2,        /* handle answered, expired or stale */
  ANOLE_E_AGAIN = -3,       /* backpressure (not used by the spike) */
  ANOLE_E_NOMEM = -4,
  ANOLE_E_CONFIG = -5,      /* see anole_last_error */
  ANOLE_E_STATE = -6,       /* call not allowed in this state */
  ANOLE_E_UNSUPPORTED = -7, /* feature compiled out, or not on this OS */
  ANOLE_E_TOOBIG = -8,      /* anole_poll: the next event does not fit an empty buffer */
  ANOLE_E_SYSTEM = -9       /* the OS refused (threads, sockets); see anole_last_error */
};

/* The text of the last error on this thread; valid until the next call. */
ANOLE_API anole_str anole_last_error(void);
/* Compare with ANOLE_ABI_VERSION: the major must match, the minor be >=. */
ANOLE_API uint32_t anole_abi_version(void);
ANOLE_API anole_str anole_version(void);

/* 64-bit, generation-checked; 0 is never valid. */
typedef uint64_t anole_req;
typedef struct anole_server anole_server;     /* opaque */
typedef struct anole_consumer anole_consumer; /* opaque */

/* ---- lifecycle ------------------------------------------------------------ */

/* Embedded processes (Node, Python) own their signals, so by default Anole
   installs no signal handlers and only anole_server_drain stops it. A
   standalone C program may ask for SIGINT/SIGTERM handling with this. */
#define ANOLE_SERVER_SIGNALS 1u

typedef struct anole_server_options {
  size_t size;           /* sizeof(anole_server_options) */
  anole_str config_json; /* see "Configuration" below */
  uint32_t flags;        /* ANOLE_SERVER_* */
} anole_server_options;

/* Configuration (JSON; unknown keys are an error):
   {
     "listeners": [{ "address": "127.0.0.1", "port": 0, "h2c": true }],
     "executors": 0,                    // 0 = one per CPU
     "limits":   { "inline_body_max": 65536, "max_inflight": 1024, "body_max": 1048576 },
     "timeouts": { "request_ms": 30000, "shutdown_ms": 10000, "keepalive_ms": 60000,
                   "rewake_ms": 20 },    // ring again if a doorbell was lost; 0 = never
     "routes": [
       { "method": "GET", "path": "/healthz", "respond": { "status": 200, "body": "ok",
                                                       "headers": { "content-type": "text/plain" } } },
       { "method": "GET", "path": "/users/:id", "handler": 1 }
     ]
   }
   max_inflight is per executor; past it, 503. Request bodies larger than
   inline_body_max get 413 on consumer routes (the spike has no streaming). */

/* One server per process. Parses and checks the configuration; binds nothing. */
ANOLE_API anole_status anole_server_create(const anole_server_options *options, anole_server **out);
/* Starts Anole's threads and binds; returns once listening, or the error. */
ANOLE_API anole_status anole_server_start(anole_server *s);
/* The bound port of listener i (the real one when 0 was asked for). */
ANOLE_API anole_status anole_server_port(anole_server *s, uint32_t i, uint16_t *out);
/* Stops accepting and drains the requests in flight (bounded by
   timeouts.shutdown_ms); returns at once. Consumers keep polling and
   answering until they see ANOLE_EV_STOPPED. Any thread. */
ANOLE_API anole_status anole_server_drain(anole_server *s);
/* Blocks until the server has stopped (after a drain). */
ANOLE_API anole_status anole_server_wait(anole_server *s);
/* Drains if still running, joins Anole's threads and frees everything,
   consumers included. No handle or consumer may be used afterwards. */
ANOLE_API void anole_server_destroy(anole_server *s);

/* ---- consumers and events -------------------------------------------------- */

typedef struct anole_consumer_options {
  size_t size; /* sizeof(anole_consumer_options) */
  /* Called on an Anole thread when events become available after anole_poll
     returned 0. Must not block and must not enter the language
     (napi_call_threadsafe_function(nonblocking), write to an eventfd,
     PostQueuedCompletionStatus). NULL: use anole_consumer_fd. */
  void (*wake)(void *ud);
  void *wake_ud;
  uint32_t flags; /* none yet */
} anole_consumer_options;

/* Before anole_server_start (spike). Executor e feeds consumer e mod M. */
ANOLE_API anole_status anole_consumer_attach(anole_server *s, const anole_consumer_options *o, anole_consumer **out);
/* The doorbell fd when no wake callback was given: readable when events may
   be available. anole_poll empties it; the consumer never reads it. -1 with
   a callback, and on Windows. */
ANOLE_API int anole_consumer_fd(anole_consumer *c);

enum anole_event_type {
  ANOLE_EV_REQUEST = 1,
  ANOLE_EV_STOPPED = 11 /* the server stopped: last event of the consumer */
};

/* Every event starts with this; records are 8-byte aligned and `len`
   includes the header and padding, so unknown types can be skipped. */
typedef struct anole_event {
  uint32_t type;
  uint32_t len;
  uint64_t handle; /* anole_req for ANOLE_EV_REQUEST */
} anole_event;

/* A string inside the record: (offset from the record start, length). */
typedef struct anole_span {
  uint32_t off;
  uint32_t len;
} anole_span;

enum anole_method {
  ANOLE_METHOD_OTHER = 0, /* see method_name */
  ANOLE_METHOD_GET, ANOLE_METHOD_HEAD, ANOLE_METHOD_POST, ANOLE_METHOD_PUT,
  ANOLE_METHOD_DELETE, ANOLE_METHOD_CONNECT, ANOLE_METHOD_OPTIONS,
  ANOLE_METHOD_TRACE, ANOLE_METHOD_PATCH
};

#define ANOLE_REQ_BODY_INLINE 1u /* `body` is the whole request body */
#define ANOLE_REQ_SECURE 4u      /* arrived over TLS */

/* ANOLE_EV_REQUEST. Followed by `anole_span headers[2 * nheaders]` (name,
   value; names lower-cased, order and duplicates kept), then
   `anole_span params[2 * nparams]` (name, value), then the bytes. */
typedef struct anole_request_event {
  anole_event ev;
  uint32_t route_id;   /* the route's "handler" id */
  uint8_t method;      /* enum anole_method */
  uint8_t version;     /* 10, 11, 20, 30 */
  uint16_t flags;      /* ANOLE_REQ_* */
  anole_span method_name;
  anole_span path;     /* raw, not percent-decoded */
  anole_span query;    /* after '?', raw */
  anole_span body;
  uint16_t nheaders;
  uint16_t nparams;
  uint32_t reserved;
} anole_request_event;

static inline anole_str anole_event_str(const void *record, anole_span s) {
  anole_str r;
  r.ptr = (const char *)record + s.off;
  r.len = s.len;
  return r;
}
static inline const anole_span *anole_request_spans(const anole_request_event *r) {
  return (const anole_span *)(r + 1);
}

/* Drains events into buf (caller-owned, 8-byte aligned): a packed sequence
   of records. Returns the bytes written; 0 means nothing is pending and
   the doorbell is armed again (call until 0 after every wake).
   ANOLE_E_TOOBIG: the next record needs more than `cap` (it stays queued).
   < 0 otherwise. Call from one thread per consumer at a time.
   ANOLE_POLL_NOARM: a 0 return leaves the doorbell disarmed, so producers
   skip the wake while the consumer spins on NOARM polls for a few
   microseconds; it must end with a plain poll before it sleeps. */
#define ANOLE_POLL_NOARM 1u
ANOLE_API int64_t anole_poll(anole_consumer *c, void *buf, size_t cap, uint32_t flags);

/* ---- responses -------------------------------------------------------------- */

/* The whole response: status, headers and body, copied before returning.
   Finishes the request. Any thread. ANOLE_E_GONE: already answered,
   expired (the client got 504) or stale. `flags` must be 0. */
ANOLE_API anole_status anole_respond(anole_req r, uint16_t status, const anole_header *headers, size_t nheaders,
                                     const void *body, size_t len, uint32_t flags);
/* Gives up without a response: the client gets 500. Finishes the request. */
ANOLE_API anole_status anole_release(anole_req r);

/* ---- counters (spike) -------------------------------------------------------- */

typedef struct anole_stats {
  size_t size;
  uint64_t expired; /* requests Anole answered 504 (or abandoned on drain) */
  uint64_t gone;    /* replies refused with ANOLE_E_GONE */
  uint64_t busy;    /* requests refused 503: max_inflight reached */
  uint64_t wakes;   /* doorbells rung, all consumers */
  uint64_t rewakes; /* doorbells rung again: the first was lost (timeouts.rewake_ms) */
} anole_stats;
ANOLE_API anole_status anole_server_stats(anole_server *s, anole_stats *out);

#ifdef __cplusplus
}
#endif
#endif /* ANOLE_H */
