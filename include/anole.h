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
#define ANOLE_ABI_VERSION_MINOR 5 /* additions */
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
  ANOLE_E_TIMEOUT = -10,    /* a blocking call's timeout passed */
  ANOLE_E_DB = -11          /* a database refused a statement (anole_db_result_event) */
};

/* The text of the last error on the calling thread: valid until the next
   anole_* call on that thread. Empty when there is none. */
ANOLE_API anole_str anole_last_error(void);
/* Compare with ANOLE_ABI_VERSION at load: the major must match, the minor
   must be >= the header's. */
ANOLE_API uint32_t anole_abi_version(void);
/* Anole's version, such as "0.2.0"; static storage. */
ANOLE_API anole_str anole_version(void);
/* 1 when `name` is built in, else 0: "tls", "http2", "http3",
   "webtransport" (with http3), "websocket", "compression", "brotli",
   "auth", "grpc", "sqlite", "postgres", "redis", "mongodb". */
ANOLE_API int anole_has_feature(anole_str name);

/* 64-bit, generation-checked; 0 is never valid. Each handle has a kind
   (a request, a WebSocket, a gRPC call, a WebTransport session or stream;
   database queries later), and a function given a handle of another kind
   answers ANOLE_E_GONE. The bits are Anole's: treat them as opaque. */
typedef uint64_t anole_req;       /* one request: from ANOLE_EV_REQUEST until answered */
typedef uint64_t anole_ws;        /* one WebSocket: from ANOLE_EV_WS_OPEN until ANOLE_EV_WS_CLOSE */
typedef uint64_t anole_grpc_call; /* one gRPC call: from ANOLE_EV_GRPC_CALL until finished or aborted */
typedef uint64_t anole_wt;        /* one WebTransport session: from ANOLE_EV_WT_OPEN until ANOLE_EV_WT_CLOSE */
typedef uint64_t anole_wt_stream; /* one of its streams: until anole_wt_stream_release or the session's close */
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
/* Swaps every TLS listener's certificate and key (the HTTP/3 one too) for
   new ones: file paths, or PEM text with ANOLE_TLS_PEM (copied). Handshakes
   under way keep the old ones; later reloads (anole_server_reload_certificates,
   SIGHUP with ANOLE_SERVER_SIGNALS) read the new source. cert and key NULL:
   as anole_server_reload_certificates. ANOLE_E_STATE when the server has no
   TLS listener or is not running, ANOLE_E_INVALID when they do not load
   (anole_last_error says why); the old certificate stays then. */
#define ANOLE_TLS_PEM 1u
ANOLE_API anole_status anole_server_reload_tls(anole_server *s, uint32_t flags, const char *cert,
                                               size_t cert_len, const char *key, size_t key_len);
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
  uint64_t wt_sessions;          /* WebTransport sessions open now */
  uint64_t wt_datagrams_dropped; /* outgoing datagrams dropped: past datagram_queue, or too large */
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
  ANOLE_EV_WT_DATAGRAM = 27      /* anole_wt_datagram_event; handle: anole_wt */
  /* Reserved before ABI 1.0: 15-19 gRPC, 28-29 more WebTransport, 30-39
     more database events. A consumer skips types it does not know
     (ev.len). ANOLE_EV_ABORT, ANOLE_EV_WRITABLE and ANOLE_EV_SENT also come
     for gRPC calls (ev.handle an anole_grpc_call); ANOLE_EV_WRITABLE also
     for a WebTransport stream (ev.handle an anole_wt_stream). */
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
  uint32_t peer_cert;      /* mutual TLS: the offset of the client's certificate (verified
                              against the listener's client CAs): a little-endian uint32_t
                              length, then the DER; 0 when none (anole_request_peer_cert) */
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

/* ---- gRPC events ---------------------------------------------------------- */

/* The call modes, and the wire protocols a call came in on. */
enum {
  ANOLE_GRPC_UNARY = 0,
  ANOLE_GRPC_SERVER_STREAMING = 1,
  ANOLE_GRPC_CLIENT_STREAMING = 2,
  ANOLE_GRPC_BIDI_STREAMING = 3
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
#define ANOLE_GRPC_CALL_SECURE 4u      /* arrived over TLS (or QUIC) */
#define ANOLE_GRPC_CALL_EARLY_DATA 8u  /* arrived in TLS 1.3 / QUIC 0-RTT (replayable) */
#define ANOLE_GRPC_CALL_JSON 16u       /* the client speaks JSON; Anole converted (messages are still protobuf) */
#define ANOLE_GRPC_CALL_COMPRESSED 32u /* the client compresses its messages (Anole inflated them) */

/* ANOLE_EV_GRPC_CALL: a call to a configured service ("grpc" in the
   configuration). Messages always cross as protobuf bytes, whatever the
   client spoke (Anole converts Connect JSON, gRPC-Web JSON and transcoded
   REST with the descriptors). Followed by `anole_span metadata[2 *
   nmetadata]` (name, value: names lower-cased, the protocols' own headers
   left out, `-bin` values decoded to bytes), then the bytes the spans
   point into. The consumer answers with anole_grpc_send and
   anole_grpc_finish; ANOLE_EV_ABORT ends the call instead (client gone,
   deadline passed, request messages failed). */
typedef struct anole_grpc_call_event {
  anole_event ev;
  uint32_t route_id;      /* the service's "handler" id */
  uint16_t method_id;     /* the method's index in the service's "methods" (else the descriptors') */
  uint8_t kind;           /* ANOLE_GRPC_UNARY .. ANOLE_GRPC_BIDI_STREAMING */
  uint8_t protocol;       /* ANOLE_GRPC_PROTOCOL_* */
  uint16_t flags;         /* ANOLE_GRPC_CALL_* */
  uint8_t version;        /* HTTP version: 11, 20, 30 */
  uint8_t reserved0;
  uint16_t nmetadata;
  uint16_t reserved1;
  anole_span method;      /* "/package.Service/Method" */
  anole_span message;     /* with ANOLE_GRPC_CALL_MESSAGE: the request message (may be empty) */
  anole_span remote_addr; /* the client, "ip:port", proxies applied */
  anole_span listener;    /* the listener's name */
  anole_span id;          /* the request ID (request_id middleware), else empty */
  anole_span claims;      /* a verified JWT's claims as JSON (jwt middleware), else empty */
  int64_t timeout_us;     /* time left before the deadline when polled; -1 for none */
} anole_grpc_call_event;

/* ANOLE_EV_GRPC_MESSAGE: one request message (protobuf bytes), followed by
   them. Each takes one unit of credit (see anole_grpc_read). */
typedef struct anole_grpc_message_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t reserved;
  anole_span data;
} anole_grpc_message_event;

/* WebTransport (draft-02 over HTTP/3, what Chrome and Firefox speak). */
#define ANOLE_WT_UNI 1u /* anole_wt_open_stream's flag, and ANOLE_EV_WT_STREAM's: one-way */
#define ANOLE_WT_FIN 1u /* anole_wt_stream_write's flag, and ANOLE_EV_WT_DATA's: the end */
enum { ANOLE_WT_CLOSED_LOCAL = 0, ANOLE_WT_CLOSED_PEER = 1, ANOLE_WT_CLOSED_CONNECTION = 2 };

/* ANOLE_EV_WT_STREAM: a stream the peer opened, both ways or (ANOLE_WT_UNI)
   read-only. Release it (anole_wt_stream_release) when done: the peer may
   open another only as streams are released. */
typedef struct anole_wt_stream_event {
  anole_event ev;
  uint32_t route_id;
  uint32_t flags;   /* ANOLE_WT_UNI */
  anole_wt session; /* the session it belongs to */
} anole_wt_stream_event;

/* ANOLE_EV_WT_DATA: the next bytes of a stream, in order (at most 32 KiB
   each), followed by them; ANOLE_WT_FIN in flags with the last (or alone,
   with no bytes). */
typedef struct anole_wt_data_event {
  anole_event ev;
  uint32_t flags; /* ANOLE_WT_FIN */
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
static inline const anole_span *anole_request_spans(const anole_request_event *r) {
  return (const anole_span *)(r + 1);
}
/* The client's certificate (DER) in a request record (ANOLE_EV_REQUEST,
   ANOLE_EV_WS_OPEN, ANOLE_EV_WT_OPEN); empty when it sent none. */
static inline anole_str anole_request_peer_cert(const anole_request_event *r) {
  anole_str s = {0, 0};
  if (r->peer_cert == 0) return s;
  const unsigned char *p = (const unsigned char *)r + r->peer_cert;
  s.len = (size_t)p[0] | (size_t)p[1] << 8 | (size_t)p[2] << 16 | (size_t)p[3] << 24;
  s.ptr = (const char *)(p + 4);
  return s;
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
   or value, or Connection / Transfer-Encoding, which the server writes
   itself (nothing taken, the request is still owed); ANOLE_E_GONE. */
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
   topic when it closes. A publish called after this returns sees the
   change (it reaches a socket that joined, and not one that left). */
ANOLE_API anole_status anole_ws_subscribe(anole_ws w, anole_str topic);
ANOLE_API anole_status anole_ws_unsubscribe(anole_ws w, anole_str topic);
/* Sends one message to every socket subscribed to `topic` but `except` (0:
   none), fanned out on Anole's threads; returns at once (topic and data
   copied). At most limits.ws_max_message bytes (else ANOLE_E_INVALID).
   No subscriber holds a publish up: each has up to limits.ws_high_water
   bytes queued for it, past which publishes skip it (and one stuck that way
   for a second is closed). ANOLE_E_AGAIN: not sent, because too many
   publishes are still being fanned out (at most 64 per executor and the
   larger of 16 x limits.ws_high_water and 2 x limits.ws_max_message bytes);
   no event follows, publish again later. */
ANOLE_API anole_status anole_ws_publish(anole_server *s, anole_str topic, int type, const void *data, size_t len,
                                        anole_ws except);

/* ---- gRPC ------------------------------------------------------------------- */

/* Status codes (google.rpc.Code). */
enum {
  ANOLE_GRPC_OK = 0,
  ANOLE_GRPC_CANCELLED = 1,
  ANOLE_GRPC_UNKNOWN = 2,
  ANOLE_GRPC_INVALID_ARGUMENT = 3,
  ANOLE_GRPC_DEADLINE_EXCEEDED = 4,
  ANOLE_GRPC_NOT_FOUND = 5,
  ANOLE_GRPC_ALREADY_EXISTS = 6,
  ANOLE_GRPC_PERMISSION_DENIED = 7,
  ANOLE_GRPC_RESOURCE_EXHAUSTED = 8,
  ANOLE_GRPC_FAILED_PRECONDITION = 9,
  ANOLE_GRPC_ABORTED = 10,
  ANOLE_GRPC_OUT_OF_RANGE = 11,
  ANOLE_GRPC_UNIMPLEMENTED = 12,
  ANOLE_GRPC_INTERNAL = 13,
  ANOLE_GRPC_UNAVAILABLE = 14,
  ANOLE_GRPC_DATA_LOSS = 15,
  ANOLE_GRPC_UNAUTHENTICATED = 16
};

/* anole_grpc_send flag: the call ends after this message with OK and no
   trailing metadata (a unary answer in one call). */
#define ANOLE_GRPC_SEND_FINISH 2u

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
   anole_grpc_finish (a second: ANOLE_E_STATE); with ANOLE_GRPC_SEND_FINISH
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
ANOLE_API anole_status anole_grpc_health_set(anole_server *s, anole_str service, int status);

/* ---- WebTransport ----------------------------------------------------------------- */

/* A "webtransport" route accepts sessions (draft-02 over HTTP/3; the route
   needs a listener with http3) and hands them to a consumer: ANOLE_EV_WT_OPEN
   with the CONNECT request, then the session's streams, data and datagrams,
   then ANOLE_EV_WT_CLOSE. Calls on a session or stream that is gone answer
   ANOLE_E_GONE. */

/* Opens a stream: both ways, or with ANOLE_WT_UNI write-only. The handle is
   good at once; what is written waits until the stream opens (the peer's
   stream limit may hold it). */
ANOLE_API anole_status anole_wt_open_stream(anole_wt w, uint32_t flags, anole_wt_stream *out);
/* Queues bytes to send on a stream (copied), and with ANOLE_WT_FIN its end
   after them. ANOLE_BUSY: queued, but past limits.stream_high_water bytes
   waiting: wait for ANOLE_EV_WRITABLE (ev.handle the stream). ANOLE_E_INVALID
   for a read-only stream or after its end; ANOLE_E_GONE once its sending
   side is over (reset, or stopped by the peer: ANOLE_EV_WT_STREAM_STOP). */
ANOLE_API anole_status anole_wt_stream_write(anole_wt_stream s, const void *data, size_t len, uint32_t flags);
/* Abandons sending (RESET_STREAM with the application code); what was
   queued is dropped. */
ANOLE_API anole_status anole_wt_stream_reset(anole_wt_stream s, uint32_t code);
/* Asks the peer to stop sending (STOP_SENDING); what arrives is dropped. */
ANOLE_API anole_status anole_wt_stream_stop(anole_wt_stream s, uint32_t code);
/* Done with the stream: a sending side not ended with ANOLE_WT_FIN is reset
   and a receiving side not read to its end is stopped (code 0); the handle
   is stale at once. Every stream must be released (or its session closed). */
ANOLE_API anole_status anole_wt_stream_release(anole_wt_stream s);
/* Queues a datagram (copied). Datagrams are unreliable: the session keeps
   the route's datagram_queue of them waiting to go out, and past it drops
   the oldest (a datagram that waits goes stale; counted in
   anole_stats.wt_datagrams_dropped). ANOLE_E_TOOBIG past
   anole_wt_max_datagram. */
ANOLE_API anole_status anole_wt_send_datagram(anole_wt w, const void *data, size_t len);
/* The largest datagram the session takes now (it follows the path's
   packet size), 0 when the peer takes none; or ANOLE_E_GONE. */
ANOLE_API int64_t anole_wt_max_datagram(anole_wt w);
/* Closes the session with an application code and a reason (at most 1024
   bytes): every stream is reset, and ANOLE_EV_WT_CLOSE follows. */
ANOLE_API anole_status anole_wt_close(anole_wt w, uint32_t code, anole_str reason);

/* ---- databases ---------------------------------------------------------------- */

/* A database from the configuration's "databases": SQLite, PostgreSQL,
   Redis or MongoDB. Statements run on Anole's threads and never
   block the caller: each call queues one, and its answer comes back as an
   ANOLE_EV_DB_RESULT to the consumer named in the call, with the caller's
   user_data. SQLite: reads run beside the writer (WAL), writes take turns on
   the database's writer thread. PostgreSQL, Redis and MongoDB: each
   executor has its own pool of connections. Statements may be queued from anole_server_start until
   the server stops; ones still running when it stops get no answer
   (ANOLE_EV_STOPPED is the consumer's last event). */
typedef struct anole_db anole_db; /* opaque; lives until anole_server_destroy */

/* The database named `name` in the configuration (after
   anole_server_create). ANOLE_E_INVALID when there is none. */
ANOLE_API anole_status anole_db_find(anole_server *s, anole_str name, anole_db **out);

/* Value and cell types. ANOLE_DB_BOOL holds 0 or 1 in `i`. ARRAY, MAP and
   ERROR are cells of a Redis reply only, BSON of a MongoDB answer (see
   anole_db_cell). */
enum {
  ANOLE_DB_NULL = 0,
  ANOLE_DB_INT = 1,
  ANOLE_DB_FLOAT = 2,
  ANOLE_DB_TEXT = 3,
  ANOLE_DB_BLOB = 4,
  ANOLE_DB_BOOL = 5,
  ANOLE_DB_ARRAY = 6,
  ANOLE_DB_MAP = 7,
  ANOLE_DB_ERROR = 8,
  ANOLE_DB_BSON = 9
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
   parameter is a BSON document (ANOLE_DB_BLOB), in the order the drivers'
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
  uint32_t reserved;
  union {
    int64_t i;   /* ANOLE_DB_INT, ANOLE_DB_BOOL */
    double f;    /* ANOLE_DB_FLOAT */
    anole_str s; /* ANOLE_DB_TEXT (UTF-8), ANOLE_DB_BLOB */
  } v;
} anole_db_value;

/* Query flags. ANOLE_DB_WRITE (SQLite): run on the writer, for a statement
   that writes but does not look like it (a SELECT with side effects).
   ANOLE_DB_COALESCE: identical reads in flight at once (same statement and
   parameters) share one run, each caller getting its own answer.
   ANOLE_DB_NO_PREPARE: do not keep the prepared statement (SQL built at run
   time). ANOLE_DB_DROP_EMPTY: with a cache_ttl_ms, an answer with no row is
   served but not kept (cache-aside). */
#define ANOLE_DB_WRITE 1u
#define ANOLE_DB_COALESCE 2u
#define ANOLE_DB_NO_PREPARE 4u
#define ANOLE_DB_DROP_EMPTY 8u

typedef struct anole_db_options {
  size_t size;           /* sizeof(anole_db_options): fields past it read as 0 */
  uint32_t flags;        /* ANOLE_DB_* */
  uint32_t timeout_ms;   /* 0: none; past it, the statement is interrupted (ANOLE_E_TIMEOUT);
                            PostgreSQL also gets a CancelRequest */
  uint32_t cache_ttl_ms; /* reads: keep the answer this long per executor, served
                            from memory meanwhile; 0: not kept */
  uint32_t reserved;
  anole_str cache_tag;   /* a name to drop kept answers by (anole_db_invalidate); copied */
} anole_db_options;

/* Queues a read (or any statement that returns rows): the answer holds the
   column names and every row. `params` (copied) bind in order; `opts` may
   be NULL. `c` receives the answer; it must be fed by at least one
   executor (ANOLE_E_STATE otherwise, or before start or after the stop).
   ANOLE_E_INVALID: a bad value type or options size. Returns at once.
   Redis: runs the command and answers with its whole reply. timeout_ms,
   ANOLE_DB_COALESCE and cache_ttl_ms apply; the last two only to commands
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
   ANOLE_DB_BOOL; int2, int4, int8, oid and xid are ANOLE_DB_INT; float4 and
   float8 are ANOLE_DB_FLOAT; bytea is ANOLE_DB_BLOB; every other type is
   ANOLE_DB_TEXT in PostgreSQL's text format (as psql prints it: numeric
   exactly, '2026-10-22 10:00:00+00', '{1,2}', JSON text), for the caller to
   parse by db_type, as the language's own PostgreSQL drivers do.
   Redis: the reply is a tree of cells in preorder, with no columns
   (ncolumns 0, nrows the number of cells). Bulk strings are BLOB (bytes,
   often UTF-8), status replies ("OK") TEXT, integers INT, nil NULL, RESP3
   doubles FLOAT and booleans BOOL. An ARRAY cell with `i` = n is followed by
   its n items, each a whole subtree; a MAP with `i` = n by n key, value
   pairs. ERROR (text) is an error reply inside another, as EXEC's.
   MongoDB: one column, "document". find, findOne and aggregate answer a
   row per document, each cell ANOLE_DB_BSON (the document's bytes, for the
   binding's BSON library); countDocuments one ANOLE_DB_INT; the writes one
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

/* ANOLE_EV_DB_RESULT: ev.handle is 0; user_data as given to the call.
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
} anole_db_result_event;

#ifdef __cplusplus
}
#endif
#endif /* ANOLE_H */
