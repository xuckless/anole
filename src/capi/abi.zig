//! The C ABI's types, as `include/anole.h` declares them. Every extern
//! struct here is checked against the header's own layout (translated with
//! translate-c) by `abi_test.zig`, so the two cannot drift.
const std = @import("std");

pub const version_major: u32 = 0;
pub const version_minor: u32 = 8;
pub const version: u32 = (version_major << 16) | version_minor;

pub const Status = i32;
pub const OK: Status = 0;
pub const BUSY: Status = 1;
pub const E_INVALID: Status = -1;
pub const E_GONE: Status = -2;
pub const E_AGAIN: Status = -3;
pub const E_NOMEM: Status = -4;
pub const E_CONFIG: Status = -5;
pub const E_STATE: Status = -6;
pub const E_UNSUPPORTED: Status = -7;
pub const E_TOOBIG: Status = -8;
pub const E_SYSTEM: Status = -9;
pub const E_TIMEOUT: Status = -10;
pub const E_DB: Status = -11;
pub const E_BROKER: Status = -12;

pub const Str = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn slice(s: Str) []const u8 {
        return if (s.ptr) |p| p[0..s.len] else "";
    }
    pub fn of(bytes: []const u8) Str {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }
};

pub const Header = extern struct {
    name: Str,
    value: Str,
};

pub const SERVER_F_SIGNALS: u32 = 1;

pub const LOG_ERROR: u32 = 1;
pub const LOG_WARN: u32 = 2;
pub const LOG_INFO: u32 = 3;
pub const LOG_DEBUG: u32 = 4;

pub const LogFn = *const fn (ud: ?*anyopaque, level: u32, scope: Str, msg: Str) callconv(.c) void;
pub const WakeFn = *const fn (ud: ?*anyopaque) callconv(.c) void;

pub const ServerOptions = extern struct {
    size: usize,
    config_json: Str,
    flags: u32,
    log_level: u32,
    log: ?LogFn,
    log_ud: ?*anyopaque,
};

pub const Stats = extern struct {
    size: usize,
    requests: u64 = 0,
    detached: u64 = 0,
    inflight: u64 = 0,
    expired: u64 = 0,
    aborted: u64 = 0,
    gone: u64 = 0,
    busy: u64 = 0,
    wakes: u64 = 0,
    rewakes: u64 = 0,
    websockets: u64 = 0,
    ws_messages_in: u64 = 0,
    ws_messages_out: u64 = 0,
    wt_sessions: u64 = 0,
    wt_datagrams_dropped: u64 = 0,
};

pub const CONSUMER_F_SHARED: u32 = 1;

pub const ConsumerOptions = extern struct {
    size: usize,
    wake: ?WakeFn,
    wake_ud: ?*anyopaque,
    flags: u32,
};

pub const EventType = enum(u32) {
    none = 0,
    request = 1,
    body = 2,
    abort = 3,
    writable = 4,
    sent = 5,
    ws_open = 6,
    ws_message = 7,
    ws_close = 8,
    db_result = 10,
    stopped = 11,
    grpc_call = 12,
    grpc_message = 13,
    grpc_half_close = 14,
    wt_open = 20,
    wt_close = 21,
    wt_drain = 22,
    wt_stream = 23,
    wt_data = 24,
    wt_stream_reset = 25,
    wt_stream_stop = 26,
    wt_datagram = 27,
    /// http-realtime: a WebSocket upgrade the consumer accepts or refuses.
    ws_upgrade = 40,
    /// http-realtime: the drain started.
    draining = 41,
    nats_msg = 64,
    nats_reply = 65,
    nats_js_msg = 66,
    nats_sub_end = 67,
    nats_writable = 69,
};

pub const Event = extern struct {
    type: u32,
    len: u32,
    handle: u64,
};

pub const Span = extern struct {
    off: u32 = 0,
    len: u32 = 0,
};

pub const REQ_BODY_INLINE: u16 = 1;
pub const REQ_BODY_STREAM: u16 = 2;
pub const REQ_SECURE: u16 = 4;
pub const REQ_EARLY_DATA: u16 = 8;
/// The client presented a certificate (mutual TLS): `peer_cert` is set.
pub const REQ_PEER_CERT: u16 = 16;
/// anole_server_reload_tls: the two arguments are PEM text, not paths.
pub const TLS_F_PEM: u32 = 1;

pub const METHOD_OTHER: u8 = 0;
pub const METHOD_GET: u8 = 1;
pub const METHOD_HEAD: u8 = 2;
pub const METHOD_POST: u8 = 3;
pub const METHOD_PUT: u8 = 4;
pub const METHOD_DELETE: u8 = 5;
pub const METHOD_CONNECT: u8 = 6;
pub const METHOD_OPTIONS: u8 = 7;
pub const METHOD_TRACE: u8 = 8;
pub const METHOD_PATCH: u8 = 9;

pub const ABORT_CLIENT: u16 = 1;
pub const ABORT_DEADLINE: u16 = 2;
pub const ABORT_BODY: u16 = 3;
pub const ABORT_DRAIN: u16 = 4;
pub const ABORT_SERVER: u16 = 5;

/// ANOLE_EV_ABORT.
pub const AbortEvent = extern struct {
    ev: Event,
    reason: u16,
    status: u16,
    reserved: u32 = 0,
};

pub const LISTENER_F_TLS: u32 = 1;
pub const LISTENER_F_HTTP1: u32 = 2;
pub const LISTENER_F_HTTP2: u32 = 4;
pub const LISTENER_F_HTTP3: u32 = 8;
pub const LISTENER_F_UNIX: u32 = 16;
pub const LISTENER_F_PROXY_PROTOCOL: u32 = 32;
pub const LISTENER_PENDING: u32 = 0;
pub const LISTENER_LISTENING: u32 = 1;
pub const LISTENER_FAILED: u32 = 2;
pub const LISTENER_CLOSED: u32 = 3;

pub const ListenerInfo = extern struct {
    size: usize,
    name: Str = .{},
    address: Str = .{},
    port: u16 = 0,
    udp_port: u16 = 0,
    flags: u32 = 0,
    state: u32 = 0,
    error_errno: i32 = 0,
    error_name: Str = .{},
};

pub const RequestEvent = extern struct {
    ev: Event,
    route_id: u32,
    method: u8,
    version: u8,
    flags: u16,
    method_name: Span,
    path: Span,
    query: Span,
    body: Span,
    remote_addr: Span,
    listener: Span,
    id: Span,
    claims: Span,
    nheaders: u16,
    nparams: u16,
    /// Where the header spans start (then the parameter spans).
    spans_off: u32,
    content_length: u64,
    /// Mutual TLS: the client's certificate (DER), empty when none.
    peer_cert: Span = .{},
    /// Time left before Anole answers 504, measured when polled; -1 when
    /// no deadline applies.
    timeout_us: i64 = -1,
    /// ANOLE_EV_WS_OPEN: the selected subprotocol.
    subprotocol: Span = .{},
};

pub const SentEvent = extern struct {
    ev: Event,
    data: u64,
    len: u64,
};

/// `anole_ws_accept`'s options (NULL takes the defaults).
pub const WsAcceptOptions = extern struct {
    size: usize,
    flags: u32 = 0,
    reserved: u32 = 0,
    subprotocol: Str = .{},
    headers: ?[*]const Header = null,
    nheaders: usize = 0,
};

pub const WS_TEXT: u32 = 1;
pub const WS_BINARY: u32 = 2;

pub const WsMessageEvent = extern struct {
    ev: Event,
    route_id: u32,
    type: u32,
    data: Span,
};

pub const WsCloseEvent = extern struct {
    ev: Event,
    route_id: u32,
    code: u16,
    reserved: u16 = 0,
    reason: Span,
};

/// `anole_wt_open_stream`'s flag and ANOLE_EV_WT_STREAM's: one-way.
pub const WT_F_UNI: u32 = 1;
/// `anole_wt_stream_write`'s flag and ANOLE_EV_WT_DATA's: the end.
pub const WT_F_FIN: u32 = 2;
pub const WT_CLOSED_LOCAL: u32 = 0;
pub const WT_CLOSED_PEER: u32 = 1;
pub const WT_CLOSED_CONNECTION: u32 = 2;

pub const WtStreamEvent = extern struct {
    ev: Event,
    route_id: u32,
    flags: u32,
    session: u64,
};

pub const WtDataEvent = extern struct {
    ev: Event,
    flags: u32,
    reserved: u32 = 0,
    data: Span,
};

pub const WtCodeEvent = extern struct {
    ev: Event,
    code: u32,
    reserved: u32 = 0,
};

pub const WtDatagramEvent = extern struct {
    ev: Event,
    route_id: u32,
    reserved: u32 = 0,
    data: Span,
};

pub const WtCloseEvent = extern struct {
    ev: Event,
    route_id: u32,
    code: u32,
    by: u32,
    reserved: u32 = 0,
    reason: Span,
};

pub const DB_TYPE_NULL: u32 = 0;
pub const DB_TYPE_INT: u32 = 1;
pub const DB_TYPE_FLOAT: u32 = 2;
pub const DB_TYPE_TEXT: u32 = 3;
pub const DB_TYPE_BLOB: u32 = 4;
pub const DB_TYPE_BOOL: u32 = 5;
/// Cells of a Redis reply only: `v.i` items (an array), or `v.i` pairs
/// (a map) follow; an error reply inside another (EXEC's), as text.
pub const DB_TYPE_ARRAY: u32 = 6;
pub const DB_TYPE_MAP: u32 = 7;
pub const DB_TYPE_ERROR: u32 = 8;
/// A BSON document (MongoDB): its bytes in the span.
pub const DB_TYPE_BSON: u32 = 9;

pub const DbValue = extern struct {
    type: u32,
    reserved: u32 = 0,
    v: extern union { i: i64, f: f64, s: Str },
};

pub const DB_F_WRITE: u32 = 1;
pub const DB_F_COALESCE: u32 = 2;
pub const DB_F_NO_PREPARE: u32 = 4;
pub const DB_F_DROP_EMPTY: u32 = 8;
pub const DB_F_RETRY: u32 = 16;

pub const DbOptions = extern struct {
    size: usize,
    flags: u32 = 0,
    timeout_ms: u32 = 0,
    cache_ttl_ms: u32 = 0,
    reserved: u32 = 0,
    cache_tag: Str = .{},
    /// The request or gRPC call this query serves, or 0 (ABI 0.7).
    req: u64 = 0,
};

/// `anole_db_options.timeout_ms`: no bound for this query.
pub const DB_TIMEOUT_NONE: u32 = 0xFFFFFFFF;

/// `anole_db_tx_options.flags`.
pub const DB_TX_READ_ONLY: u32 = 1;

/// `anole_db_tx_options.isolation`.
pub const DB_ISOLATION_DEFAULT: u32 = 0;
pub const DB_ISOLATION_READ_UNCOMMITTED: u32 = 1;
pub const DB_ISOLATION_READ_COMMITTED: u32 = 2;
pub const DB_ISOLATION_REPEATABLE_READ: u32 = 3;
pub const DB_ISOLATION_SERIALIZABLE: u32 = 4;

pub const DbTxOptions = extern struct {
    size: usize,
    flags: u32 = 0,
    isolation: u32 = 0,
    timeout_ms: u32 = 0,
    reserved: u32 = 0,
    req: u64 = 0,
};

pub const DB_FROM_DATABASE: u8 = 0;
pub const DB_FROM_COALESCED: u8 = 1;
pub const DB_FROM_CACHE: u8 = 2;

/// `anole.db.Class`, plus 0 for none, in its order.
pub const DbErrorClass = enum(u8) {
    none = 0,
    unique = 1,
    exclusion = 2,
    foreign_key = 3,
    not_null = 4,
    check = 5,
    serialization = 6,
    deadlock = 7,
    unavailable = 8,
    timeout = 9,
    other = 10,
};

pub const DbResultEvent = extern struct {
    ev: Event,
    user_data: u64,
    status: i32,
    http_status: u16,
    error_class: u8,
    source: u8,
    ncolumns: u32,
    nrows: u32,
    changes: u64,
    last_insert_rowid: i64,
    columns: Span,
    cells: Span,
    @"error": Span,
    error_code: Span,
    constraint: Span,
    /// The table (or collection) the error names, when the database says
    /// (ABI 0.7).
    table: Span,
};

pub const DbCell = extern struct {
    type: u32,
    /// PostgreSQL: the column's type OID; 0 otherwise.
    db_type: u32 = 0,
    v: extern union { i: i64, f: f64, s: Span },
};

// ---- Brokers (NATS) --------------------------------------------------------

/// `anole_nats_request_options.flags`: retry NoResponders with the broker's "retry".
pub const NATS_F_RETRY: u32 = 1;
/// `anole_nats_js_publish_options.flags`: check `expected_last_seq` (allows 0).
pub const NATS_JS_F_EXPECT_LAST_SEQ: u32 = 1;

/// `anole_nats_subscribe_options.overflow`.
pub const NATS_DROP_NEWEST: u32 = 0;
pub const NATS_DROP_OLDEST: u32 = 1;
pub const NATS_CLOSE: u32 = 2;

/// `anole_nats_ack`'s kind.
pub const NATS_ACK: u32 = 0;
pub const NATS_NAK: u32 = 1;
pub const NATS_TERM: u32 = 2;
pub const NATS_PROGRESS: u32 = 3;

/// `anole_nats_reply_event.op`.
pub const NATS_OP_REQUEST: u8 = 0;
pub const NATS_OP_JS_PUBLISH: u8 = 1;

/// `anole_broker_end_event.reason`.
pub const BROKER_END_CLOSED: u32 = 0;
pub const BROKER_END_DRAINED: u32 = 1;
pub const BROKER_END_SLOW: u32 = 2;
pub const BROKER_END_DENIED: u32 = 3;
pub const BROKER_END_FAILED: u32 = 4;

/// `anole_broker_status_event.status`.
pub const BROKER_CONNECTED: u32 = 0;
pub const BROKER_DISCONNECTED: u32 = 1;
pub const BROKER_RECONNECTED: u32 = 2;
pub const BROKER_LAME_DUCK: u32 = 3;
pub const BROKER_WRITABLE: u32 = 4;

/// A message to publish or a request to send (`anole_nats_out`).
pub const NatsOut = extern struct {
    size: usize,
    subject: Str = .{},
    /// Empty: none.
    reply: Str = .{},
    headers: ?[*]const Header = null,
    nheaders: usize = 0,
    data: ?[*]const u8 = null,
    len: usize = 0,
};

pub const NatsRequestOptions = extern struct {
    size: usize,
    flags: u32 = 0,
    /// 0: the broker's timeout_ms; ANOLE_DB_TIMEOUT_NONE: none.
    timeout_ms: u32 = 0,
    /// The request or gRPC call this serves, or 0.
    req: u64 = 0,
};

pub const NatsSubscribeOptions = extern struct {
    size: usize,
    queue: Str = .{},
    max_messages: u32 = 0,
    max_bytes: u32 = 0,
    overflow: u32 = 0,
    reserved: u32 = 0,
};

pub const NatsJsPublishOptions = extern struct {
    size: usize,
    msg_id: Str = .{},
    expected_stream: Str = .{},
    expected_last_seq: u64 = 0,
    timeout_ms: u32 = 0,
    flags: u32 = 0,
    req: u64 = 0,
};

pub const NatsJsConsumeOptions = extern struct {
    size: usize,
    max_inflight: u32 = 0,
    expires_ms: u32 = 0,
};

/// ANOLE_EV_NATS_MSG and ANOLE_EV_NATS_JS_MSG. Followed by the headers
/// (`headers_off`: `nheaders` name/value `anole_span` pairs) and the bytes
/// the spans name.
pub const NatsMsgEvent = extern struct {
    ev: Event,
    user_data: u64,
    sub: u64,
    subject: Span,
    reply: Span,
    headers_off: u32,
    nheaders: u32,
    payload: Span,
    status: u16,
    reserved16: u16,
    reserved: u32,
    stream_seq: u64,
    consumer_seq: u64,
    delivered: u64,
    pending: u64,
    timestamp_ns: i64,
    stream: Span,
    consumer: Span,
};

/// ANOLE_EV_NATS_REPLY: the answer to anole_nats_request or anole_nats_js_publish.
pub const NatsReplyEvent = extern struct {
    ev: Event,
    user_data: u64,
    status: i32,
    http_status: u16,
    error_class: u8,
    op: u8,
    subject: Span,
    headers_off: u32,
    nheaders: u32,
    payload: Span,
    msg_status: u16,
    duplicate: u16,
    reserved: u32,
    seq: u64,
    stream: Span,
    @"error": Span,
    error_code: Span,
};

/// ANOLE_EV_NATS_SUB_END.
pub const BrokerEndEvent = extern struct {
    ev: Event,
    user_data: u64,
    reason: u32,
    reserved: u32,
    dropped: u64,
    @"error": Span,
};

/// ANOLE_EV_NATS_WRITABLE.
pub const BrokerStatusEvent = extern struct {
    ev: Event,
    broker: u32,
    status: u32,
};

pub const POLL_F_NOARM: u32 = 1;
pub const BODY_BORROW: u32 = 1;

// ---- gRPC ----------------------------------------------------------------

pub const GRPC_KIND_UNARY: u8 = 0;
pub const GRPC_KIND_SERVER_STREAMING: u8 = 1;
pub const GRPC_KIND_CLIENT_STREAMING: u8 = 2;
pub const GRPC_KIND_BIDI_STREAMING: u8 = 3;

pub const GRPC_PROTOCOL_GRPC: u8 = 0;
pub const GRPC_PROTOCOL_GRPC_WEB: u8 = 1;
pub const GRPC_PROTOCOL_GRPC_WEB_TEXT: u8 = 2;
pub const GRPC_PROTOCOL_CONNECT: u8 = 3;
pub const GRPC_PROTOCOL_CONNECT_STREAM: u8 = 4;
pub const GRPC_PROTOCOL_HTTP_JSON: u8 = 5;

pub const GRPC_CALL_MESSAGE: u16 = 1;
pub const GRPC_CALL_PEER_CERT: u16 = 2;
pub const GRPC_CALL_SECURE: u16 = 4;
pub const GRPC_CALL_EARLY_DATA: u16 = 8;
pub const GRPC_CALL_JSON: u16 = 16;
pub const GRPC_CALL_COMPRESSED: u16 = 32;

pub const GRPC_F_FINISH: u32 = 2;

pub const GRPC_STATUS_OK: u32 = 0;
pub const GRPC_STATUS_CANCELLED: u32 = 1;
pub const GRPC_STATUS_UNKNOWN: u32 = 2;
pub const GRPC_STATUS_INVALID_ARGUMENT: u32 = 3;
pub const GRPC_STATUS_DEADLINE_EXCEEDED: u32 = 4;
pub const GRPC_STATUS_NOT_FOUND: u32 = 5;
pub const GRPC_STATUS_ALREADY_EXISTS: u32 = 6;
pub const GRPC_STATUS_PERMISSION_DENIED: u32 = 7;
pub const GRPC_STATUS_RESOURCE_EXHAUSTED: u32 = 8;
pub const GRPC_STATUS_FAILED_PRECONDITION: u32 = 9;
pub const GRPC_STATUS_ABORTED: u32 = 10;
pub const GRPC_STATUS_OUT_OF_RANGE: u32 = 11;
pub const GRPC_STATUS_UNIMPLEMENTED: u32 = 12;
pub const GRPC_STATUS_INTERNAL: u32 = 13;
pub const GRPC_STATUS_UNAVAILABLE: u32 = 14;
pub const GRPC_STATUS_DATA_LOSS: u32 = 15;
pub const GRPC_STATUS_UNAUTHENTICATED: u32 = 16;

pub const GRPC_HEALTH_UNKNOWN: u32 = 0;
pub const GRPC_HEALTH_SERVING: u32 = 1;
pub const GRPC_HEALTH_NOT_SERVING: u32 = 2;

/// ANOLE_EV_GRPC_CALL: followed, at `metadata_off`, by
/// `anole_span metadata[2 * nmetadata]`, then the bytes the spans point into.
pub const GrpcCallEvent = extern struct {
    ev: Event,
    route_id: u32,
    method_id: u16,
    kind: u8,
    protocol: u8,
    flags: u16,
    version: u8,
    reserved0: u8 = 0,
    nmetadata: u16,
    reserved1: u16 = 0,
    method: Span,
    message: Span,
    remote_addr: Span,
    listener: Span,
    id: Span,
    claims: Span,
    timeout_us: i64,
    metadata_off: u32,
    reserved2: u32 = 0,
    peer_cert: Span = .{},
};

/// ANOLE_EV_GRPC_MESSAGE: one request message, followed by its bytes.
pub const GrpcMessageEvent = extern struct {
    ev: Event,
    route_id: u32,
    reserved: u32 = 0,
    data: Span,
};

comptime {
    std.debug.assert(@sizeOf(Event) == 16);
    std.debug.assert(@sizeOf(Span) == 8);
    std.debug.assert(@sizeOf(RequestEvent) == 128);
    std.debug.assert(@sizeOf(AbortEvent) == 24);
    std.debug.assert(@sizeOf(ListenerInfo) == 72);
    std.debug.assert(@sizeOf(SentEvent) == 32);
    std.debug.assert(@sizeOf(WsMessageEvent) == 32);
    std.debug.assert(@sizeOf(WsCloseEvent) == 32);
    std.debug.assert(@sizeOf(WsAcceptOptions) == 48);
    std.debug.assert(@sizeOf(GrpcCallEvent) == 104);
    std.debug.assert(@sizeOf(GrpcMessageEvent) == 32);
    std.debug.assert(@sizeOf(DbValue) == 24);
    std.debug.assert(@sizeOf(DbOptions) == 48);
    std.debug.assert(@sizeOf(DbTxOptions) == 32);
    std.debug.assert(@sizeOf(DbResultEvent) == 104);
    std.debug.assert(@sizeOf(DbCell) == 16);
    std.debug.assert(@sizeOf(WtStreamEvent) == 32);
    std.debug.assert(@sizeOf(WtDataEvent) == 32);
    std.debug.assert(@sizeOf(WtCodeEvent) == 24);
    std.debug.assert(@sizeOf(WtDatagramEvent) == 32);
    std.debug.assert(@sizeOf(WtCloseEvent) == 40);
    std.debug.assert(@sizeOf(NatsOut) == 72);
    std.debug.assert(@sizeOf(NatsRequestOptions) == 24);
    std.debug.assert(@sizeOf(NatsSubscribeOptions) == 40);
    std.debug.assert(@sizeOf(NatsJsPublishOptions) == 64);
    std.debug.assert(@sizeOf(NatsJsConsumeOptions) == 16);
    std.debug.assert(@sizeOf(NatsMsgEvent) == 128);
    std.debug.assert(@sizeOf(NatsReplyEvent) == 96);
    std.debug.assert(@sizeOf(BrokerEndEvent) == 48);
    std.debug.assert(@sizeOf(BrokerStatusEvent) == 24);
}

/// Records are padded to this.
pub const record_align = 8;

pub fn alignUp(n: usize) usize {
    return (n + record_align - 1) & ~@as(usize, record_align - 1);
}

// ---- the machine-readable description (include/anole.abi.json) -------------
//
// tools/capi_abi_json.zig turns these tables, and the constants and records
// above, into the committed `include/anole.abi.json`. This file stays the
// single source.

/// Every extern struct `anole.h` declares, in header order.
pub const records = .{
    .{ "anole_str", Str },
    .{ "anole_header", Header },
    .{ "anole_server_options", ServerOptions },
    .{ "anole_stats", Stats },
    .{ "anole_consumer_options", ConsumerOptions },
    .{ "anole_event", Event },
    .{ "anole_span", Span },
    .{ "anole_request_event", RequestEvent },
    .{ "anole_abort_event", AbortEvent },
    .{ "anole_sent_event", SentEvent },
    .{ "anole_ws_message_event", WsMessageEvent },
    .{ "anole_ws_close_event", WsCloseEvent },
    .{ "anole_ws_accept_options", WsAcceptOptions },
    .{ "anole_grpc_call_event", GrpcCallEvent },
    .{ "anole_grpc_message_event", GrpcMessageEvent },
    .{ "anole_wt_stream_event", WtStreamEvent },
    .{ "anole_wt_data_event", WtDataEvent },
    .{ "anole_wt_code_event", WtCodeEvent },
    .{ "anole_wt_datagram_event", WtDatagramEvent },
    .{ "anole_wt_close_event", WtCloseEvent },
    .{ "anole_listener_info", ListenerInfo },
    .{ "anole_db_value", DbValue },
    .{ "anole_db_options", DbOptions },
    .{ "anole_db_tx_options", DbTxOptions },
    .{ "anole_db_cell", DbCell },
    .{ "anole_db_result_event", DbResultEvent },
    .{ "anole_nats_out", NatsOut },
    .{ "anole_nats_request_options", NatsRequestOptions },
    .{ "anole_nats_subscribe_options", NatsSubscribeOptions },
    .{ "anole_nats_js_publish_options", NatsJsPublishOptions },
    .{ "anole_nats_js_consume_options", NatsJsConsumeOptions },
    .{ "anole_nats_msg_event", NatsMsgEvent },
    .{ "anole_nats_reply_event", NatsReplyEvent },
    .{ "anole_broker_end_event", BrokerEndEvent },
    .{ "anole_broker_status_event", BrokerStatusEvent },
};

/// A variable part of a record, reached through an offset or a span in it.
pub const ArrayInfo = struct {
    record: []const u8,
    name: []const u8,
    /// Exactly one of the three: the field holding the offset, the array it
    /// follows, or the span field holding it.
    at: ?[]const u8 = null,
    after: ?[]const u8 = null,
    span: ?[]const u8 = null,
    item: []const u8,
    count: []const u8,
};

pub const arrays = [_]ArrayInfo{
    .{ .record = "anole_request_event", .name = "headers", .at = "spans_off", .item = "anole_span", .count = "2*nheaders" },
    .{ .record = "anole_request_event", .name = "params", .after = "headers", .item = "anole_span", .count = "2*nparams" },
    .{ .record = "anole_grpc_call_event", .name = "metadata", .at = "metadata_off", .item = "anole_span", .count = "2*nmetadata" },
    .{ .record = "anole_db_result_event", .name = "columns", .span = "columns", .item = "anole_span", .count = "ncolumns" },
    .{ .record = "anole_db_result_event", .name = "cells", .span = "cells", .item = "anole_db_cell", .count = "nrows*ncolumns" },
    .{ .record = "anole_nats_msg_event", .name = "headers", .at = "headers_off", .item = "anole_span", .count = "2*nheaders" },
    .{ .record = "anole_nats_reply_event", .name = "headers", .at = "headers_off", .item = "anole_span", .count = "2*nheaders" },
};

pub const HandleKindInfo = struct { kind: u8, name: []const u8, c_type: []const u8 };

/// The kind lives in bits 28-31 of a handle (`engine.Handle`). 7 is
/// reserved for a per-query handle; 10-15 are reserved.
pub const handle_kinds = [_]HandleKindInfo{
    .{ .kind = 1, .name = "request", .c_type = "anole_req" },
    .{ .kind = 2, .name = "websocket", .c_type = "anole_ws" },
    .{ .kind = 3, .name = "grpc_call", .c_type = "anole_grpc_call" },
    .{ .kind = 4, .name = "wt_session", .c_type = "anole_wt" },
    .{ .kind = 5, .name = "wt_stream", .c_type = "anole_wt_stream" },
    .{ .kind = 6, .name = "db_tx", .c_type = "anole_db_tx" },
    .{ .kind = 8, .name = "broker_sub", .c_type = "anole_nats_sub" },
    .{ .kind = 9, .name = "broker_msg", .c_type = "anole_nats_msg" },
};

pub const EventInfo = struct {
    type: u32,
    name: []const u8,
    record: []const u8,
    /// Handle kind names (`handle_kinds`); empty: ev.handle is 0.
    handles: []const []const u8 = &.{},
    /// What the consumer owes for the event, if anything.
    obligation: ?[]const u8 = null,
};

pub const events = [_]EventInfo{
    .{ .type = 0, .name = "ANOLE_EV_NONE", .record = "anole_event" },
    .{ .type = 1, .name = "ANOLE_EV_REQUEST", .record = "anole_request_event", .handles = &.{"request"}, .obligation = "answer" },
    .{ .type = 2, .name = "ANOLE_EV_BODY", .record = "anole_event", .handles = &.{"request"} },
    .{ .type = 3, .name = "ANOLE_EV_ABORT", .record = "anole_abort_event", .handles = &.{ "request", "grpc_call" } },
    .{ .type = 4, .name = "ANOLE_EV_WRITABLE", .record = "anole_event", .handles = &.{ "request", "grpc_call", "websocket", "wt_stream" } },
    .{ .type = 5, .name = "ANOLE_EV_SENT", .record = "anole_sent_event", .handles = &.{ "request", "websocket", "grpc_call", "wt_stream", "wt_session" } },
    .{ .type = 6, .name = "ANOLE_EV_WS_OPEN", .record = "anole_request_event", .handles = &.{"websocket"} },
    .{ .type = 7, .name = "ANOLE_EV_WS_MESSAGE", .record = "anole_ws_message_event", .handles = &.{"websocket"} },
    .{ .type = 8, .name = "ANOLE_EV_WS_CLOSE", .record = "anole_ws_close_event", .handles = &.{"websocket"} },
    .{ .type = 10, .name = "ANOLE_EV_DB_RESULT", .record = "anole_db_result_event", .handles = &.{"db_tx"} },
    .{ .type = 11, .name = "ANOLE_EV_STOPPED", .record = "anole_event" },
    .{ .type = 12, .name = "ANOLE_EV_GRPC_CALL", .record = "anole_grpc_call_event", .handles = &.{"grpc_call"}, .obligation = "finish" },
    .{ .type = 13, .name = "ANOLE_EV_GRPC_MESSAGE", .record = "anole_grpc_message_event", .handles = &.{"grpc_call"} },
    .{ .type = 14, .name = "ANOLE_EV_GRPC_HALF_CLOSE", .record = "anole_event", .handles = &.{"grpc_call"} },
    .{ .type = 20, .name = "ANOLE_EV_WT_OPEN", .record = "anole_request_event", .handles = &.{"wt_session"} },
    .{ .type = 21, .name = "ANOLE_EV_WT_CLOSE", .record = "anole_wt_close_event", .handles = &.{"wt_session"} },
    .{ .type = 22, .name = "ANOLE_EV_WT_DRAIN", .record = "anole_event", .handles = &.{"wt_session"} },
    .{ .type = 23, .name = "ANOLE_EV_WT_STREAM", .record = "anole_wt_stream_event", .handles = &.{"wt_stream"}, .obligation = "release" },
    .{ .type = 24, .name = "ANOLE_EV_WT_DATA", .record = "anole_wt_data_event", .handles = &.{"wt_stream"} },
    .{ .type = 25, .name = "ANOLE_EV_WT_STREAM_RESET", .record = "anole_wt_code_event", .handles = &.{"wt_stream"} },
    .{ .type = 26, .name = "ANOLE_EV_WT_STREAM_STOP", .record = "anole_wt_code_event", .handles = &.{"wt_stream"} },
    .{ .type = 27, .name = "ANOLE_EV_WT_DATAGRAM", .record = "anole_wt_datagram_event", .handles = &.{"wt_session"} },
    .{ .type = 40, .name = "ANOLE_EV_WS_UPGRADE", .record = "anole_request_event", .handles = &.{"request"}, .obligation = "accept or answer" },
    .{ .type = 41, .name = "ANOLE_EV_DRAINING", .record = "anole_event" },
    .{ .type = 64, .name = "ANOLE_EV_NATS_MSG", .record = "anole_nats_msg_event", .handles = &.{"broker_sub"} },
    .{ .type = 65, .name = "ANOLE_EV_NATS_REPLY", .record = "anole_nats_reply_event" },
    .{ .type = 66, .name = "ANOLE_EV_NATS_JS_MSG", .record = "anole_nats_msg_event", .handles = &.{"broker_msg"}, .obligation = "ack" },
    .{ .type = 67, .name = "ANOLE_EV_NATS_SUB_END", .record = "anole_broker_end_event", .handles = &.{"broker_sub"} },
    .{ .type = 69, .name = "ANOLE_EV_NATS_WRITABLE", .record = "anole_broker_status_event" },
};

pub const EventRange = struct { from: u32, to: u32, use: []const u8 };

pub const event_ranges = [_]EventRange{
    .{ .from = 0, .to = 0, .use = "none: only the header written on ANOLE_E_TOOBIG" },
    .{ .from = 1, .to = 11, .use = "core (9 retired)" },
    .{ .from = 12, .to = 19, .use = "gRPC" },
    .{ .from = 20, .to = 29, .use = "WebTransport" },
    .{ .from = 30, .to = 39, .use = "database" },
    .{ .from = 40, .to = 49, .use = "HTTP and WebSocket additions" },
    .{ .from = 50, .to = 63, .use = "core additions" },
    .{ .from = 64, .to = 255, .use = "new areas, a block of 16 per area" },
    .{ .from = 256, .to = 0x7FFFFFFF, .use = "never used" },
    .{ .from = 0x80000000, .to = 0xFFFFFFFF, .use = "never used by Anole: free for a binding's own synthetic events" },
};

pub const ConstantGroup = struct { prefix: []const u8, group: []const u8 };

/// Longest matching prefix wins. A constant matching none fails the
/// generator, so a new prefix must be named here.
pub const constant_groups = [_]ConstantGroup{
    .{ .prefix = "ANOLE_E_", .group = "status" },
    .{ .prefix = "ANOLE_OK", .group = "status" },
    .{ .prefix = "ANOLE_BUSY", .group = "status" },
    .{ .prefix = "ANOLE_EV_", .group = "event" },
    .{ .prefix = "ANOLE_ABORT_", .group = "abort_reason" },
    .{ .prefix = "ANOLE_LOG_", .group = "log_level" },
    .{ .prefix = "ANOLE_SERVER_F_", .group = "server_flag" },
    .{ .prefix = "ANOLE_CONSUMER_F_", .group = "consumer_flag" },
    .{ .prefix = "ANOLE_POLL_F_", .group = "poll_flag" },
    .{ .prefix = "ANOLE_BODY_", .group = "body_flag" },
    .{ .prefix = "ANOLE_TLS_F_", .group = "tls_flag" },
    .{ .prefix = "ANOLE_LISTENER_F_", .group = "listener_flag" },
    .{ .prefix = "ANOLE_LISTENER_", .group = "listener_state" },
    .{ .prefix = "ANOLE_METHOD_", .group = "method" },
    .{ .prefix = "ANOLE_REQ_", .group = "req_flag" },
    .{ .prefix = "ANOLE_WS_", .group = "ws_type" },
    .{ .prefix = "ANOLE_GRPC_KIND_", .group = "grpc_kind" },
    .{ .prefix = "ANOLE_GRPC_PROTOCOL_", .group = "grpc_protocol" },
    .{ .prefix = "ANOLE_GRPC_CALL_", .group = "grpc_call_flag" },
    .{ .prefix = "ANOLE_GRPC_F_", .group = "grpc_send_flag" },
    .{ .prefix = "ANOLE_GRPC_STATUS_", .group = "grpc_status" },
    .{ .prefix = "ANOLE_GRPC_HEALTH_", .group = "grpc_health" },
    .{ .prefix = "ANOLE_WT_F_", .group = "wt_flag" },
    .{ .prefix = "ANOLE_WT_CLOSED_", .group = "wt_closed_by" },
    .{ .prefix = "ANOLE_DB_TYPE_", .group = "db_type" },
    .{ .prefix = "ANOLE_DB_F_", .group = "db_flag" },
    .{ .prefix = "ANOLE_DB_FROM_", .group = "db_source" },
    .{ .prefix = "ANOLE_DB_ERR_", .group = "db_error_class" },
    .{ .prefix = "ANOLE_DB_TX_", .group = "db_tx_flag" },
    .{ .prefix = "ANOLE_DB_ISOLATION_", .group = "db_isolation" },
    .{ .prefix = "ANOLE_DB_TIMEOUT_", .group = "db_timeout" },
    .{ .prefix = "ANOLE_NATS_F_", .group = "nats_flag" },
    .{ .prefix = "ANOLE_NATS_JS_F_", .group = "nats_js_flag" },
    .{ .prefix = "ANOLE_NATS_DROP_", .group = "nats_overflow" },
    .{ .prefix = "ANOLE_NATS_CLOSE", .group = "nats_overflow" },
    .{ .prefix = "ANOLE_NATS_OP_", .group = "nats_op" },
    .{ .prefix = "ANOLE_NATS_", .group = "nats_ack" },
    .{ .prefix = "ANOLE_BROKER_END_", .group = "broker_end" },
    .{ .prefix = "ANOLE_BROKER_", .group = "broker_status" },
    .{ .prefix = "ANOLE_ABI_", .group = "abi" },
};

/// The tokens `anole_last_error_name` returns (sorted). Tokens are only
/// ever added. The member names of `anole.ServerError` and
/// `anole.TlsLoadError` are tokens verbatim.
pub const error_names = [_][]const u8{
    "AccessDenied",
    "AddressInUse",
    "AddressNotAvailable",
    "Again",
    "Broker",
    "Canceled",
    "CertificateFileUnreadable",
    "ClientCaFileUnreadable",
    "Config",
    "ConsumerWithoutExecutor",
    "Database",
    "DatabaseUnavailable",
    "DeploymentUnavailable",
    "DuplicateListenerName",
    "FileNotFound",
    "Gone",
    "HqInteropNotAllowed",
    "Http2NotBuilt",
    "Http3NeedsHttps",
    "Http3NeedsTls",
    "Http3NotBuilt",
    "InheritedSocketMismatch",
    "Invalid",
    "InvalidCertificate",
    "InvalidClientCa",
    "InvalidEnvFile",
    "InvalidEnvironmentVariable",
    "InvalidKey",
    "InvalidListenAddress",
    "InvalidListenerName",
    "InvalidProxyNetwork",
    "InvalidValue",
    "KeyFileUnreadable",
    "KeyMismatch",
    "ListenersAlreadySet",
    "MissingKey",
    "NoConsumer",
    "NoMemory",
    "NoProtocols",
    "NoTlsListener",
    "NotRunning",
    "OneServerPerProcess",
    "OutOfMemory",
    "ProxyProtocolNoPeers",
    "ReservedNotZero",
    "RouteConflict",
    "ServerAlreadyOnThread",
    "SeveralHttp3Listeners",
    "State",
    "SyntaxError",
    "System",
    "SystemResources",
    "Timeout",
    "TlsNotBuilt",
    "TooBig",
    "TooManyListeners",
    "TooManyOpenFiles",
    "Unexpected",
    "UnknownCheck",
    "UnknownEnvironment",
    "UnknownField",
    "UnknownFlag",
    "UnknownKey",
    "Unsupported",
    "WrongHandleKind",
};
