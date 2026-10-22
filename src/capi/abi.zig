//! The C ABI's types, as `include/anole.h` declares them. Every extern
//! struct here is checked against the header's own layout (translated with
//! translate-c) by `abi_test.zig`, so the two cannot drift.
const std = @import("std");

pub const version_major: u32 = 0;
pub const version_minor: u32 = 2;
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

pub const SERVER_SIGNALS: u32 = 1;

pub const LOG_ERROR: i32 = 1;
pub const LOG_WARN: i32 = 2;
pub const LOG_INFO: i32 = 3;
pub const LOG_DEBUG: i32 = 4;

pub const LogFn = *const fn (ud: ?*anyopaque, level: c_int, scope: Str, msg: Str) callconv(.c) void;
pub const WakeFn = *const fn (ud: ?*anyopaque) callconv(.c) void;

pub const ServerOptions = extern struct {
    size: usize,
    config_json: Str,
    flags: u32,
    log_level: i32,
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
};

pub const CONSUMER_SHARED: u32 = 1;

pub const ConsumerOptions = extern struct {
    size: usize,
    wake: ?WakeFn,
    wake_ud: ?*anyopaque,
    flags: u32,
};

pub const EventType = enum(u32) {
    request = 1,
    body = 2,
    abort = 3,
    writable = 4,
    sent = 5,
    ws_open = 6,
    ws_message = 7,
    ws_close = 8,
    ws_drain = 9,
    db_result = 10,
    stopped = 11,
    grpc_call = 12,
    grpc_message = 13,
    grpc_half_close = 14,
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
    reserved: u32 = 0,
    content_length: u64,
};

pub const SentEvent = extern struct {
    ev: Event,
    data: u64,
    len: u64,
};

pub const WS_TEXT: c_int = 1;
pub const WS_BINARY: c_int = 2;

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

pub const POLL_NOARM: u32 = 1;
pub const BODY_BORROW: u32 = 1;

// ---- gRPC ----------------------------------------------------------------

pub const GRPC_UNARY: u8 = 0;
pub const GRPC_SERVER_STREAMING: u8 = 1;
pub const GRPC_CLIENT_STREAMING: u8 = 2;
pub const GRPC_BIDI_STREAMING: u8 = 3;

pub const GRPC_PROTOCOL_GRPC: u8 = 0;
pub const GRPC_PROTOCOL_GRPC_WEB: u8 = 1;
pub const GRPC_PROTOCOL_GRPC_WEB_TEXT: u8 = 2;
pub const GRPC_PROTOCOL_CONNECT: u8 = 3;
pub const GRPC_PROTOCOL_CONNECT_STREAM: u8 = 4;
pub const GRPC_PROTOCOL_HTTP_JSON: u8 = 5;

pub const GRPC_CALL_MESSAGE: u16 = 1;
pub const GRPC_CALL_SECURE: u16 = 4;
pub const GRPC_CALL_EARLY_DATA: u16 = 8;
pub const GRPC_CALL_JSON: u16 = 16;
pub const GRPC_CALL_COMPRESSED: u16 = 32;

pub const GRPC_SEND_FINISH: u32 = 2;

pub const GRPC_HEALTH_UNKNOWN: c_int = 0;
pub const GRPC_HEALTH_SERVING: c_int = 1;
pub const GRPC_HEALTH_NOT_SERVING: c_int = 2;

/// ANOLE_EV_GRPC_CALL: followed by `anole_span metadata[2 * nmetadata]`,
/// then the bytes the spans point into.
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
};

/// ANOLE_EV_GRPC_MESSAGE: one request message, followed by its bytes.
pub const GrpcMessageEvent = extern struct {
    ev: Event,
    route_id: u32,
    flags: u32 = 0,
    data: Span,
};

comptime {
    std.debug.assert(@sizeOf(Event) == 16);
    std.debug.assert(@sizeOf(Span) == 8);
    std.debug.assert(@sizeOf(RequestEvent) == 104);
    std.debug.assert(@sizeOf(SentEvent) == 32);
    std.debug.assert(@sizeOf(WsMessageEvent) == 32);
    std.debug.assert(@sizeOf(WsCloseEvent) == 32);
    std.debug.assert(@sizeOf(GrpcCallEvent) == 88);
    std.debug.assert(@sizeOf(GrpcMessageEvent) == 32);
}

/// Records are padded to this.
pub const record_align = 8;

pub fn alignUp(n: usize) usize {
    return (n + record_align - 1) & ~@as(usize, record_align - 1);
}
