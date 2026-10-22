//! The C ABI's types, as `include/anole.h` declares them. Every extern
//! struct here is checked against the header's own layout (translated with
//! translate-c) by `abi_test.zig`, so the two cannot drift.
const std = @import("std");

pub const version_major: u32 = 0;
pub const version_minor: u32 = 1;
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

pub const DB_NULL: u32 = 0;
pub const DB_INT: u32 = 1;
pub const DB_FLOAT: u32 = 2;
pub const DB_TEXT: u32 = 3;
pub const DB_BLOB: u32 = 4;
pub const DB_BOOL: u32 = 5;
/// Cells of a Redis reply only: `v.i` items (an array), or `v.i` pairs
/// (a map) follow; an error reply inside another (EXEC's), as text.
pub const DB_ARRAY: u32 = 6;
pub const DB_MAP: u32 = 7;
pub const DB_ERROR: u32 = 8;
/// A BSON document (MongoDB): its bytes in the span.
pub const DB_BSON: u32 = 9;

pub const DbValue = extern struct {
    type: u32,
    reserved: u32 = 0,
    v: extern union { i: i64, f: f64, s: Str },
};

pub const DB_WRITE: u32 = 1;
pub const DB_COALESCE: u32 = 2;
pub const DB_NO_PREPARE: u32 = 4;
pub const DB_DROP_EMPTY: u32 = 8;

pub const DbOptions = extern struct {
    size: usize,
    flags: u32 = 0,
    timeout_ms: u32 = 0,
    cache_ttl_ms: u32 = 0,
    reserved: u32 = 0,
    cache_tag: Str = .{},
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
};

pub const DbCell = extern struct {
    type: u32,
    /// PostgreSQL: the column's type OID; 0 otherwise.
    db_type: u32 = 0,
    v: extern union { i: i64, f: f64, s: Span },
};

pub const POLL_NOARM: u32 = 1;
pub const BODY_BORROW: u32 = 1;

comptime {
    std.debug.assert(@sizeOf(Event) == 16);
    std.debug.assert(@sizeOf(Span) == 8);
    std.debug.assert(@sizeOf(RequestEvent) == 104);
    std.debug.assert(@sizeOf(SentEvent) == 32);
    std.debug.assert(@sizeOf(WsMessageEvent) == 32);
    std.debug.assert(@sizeOf(WsCloseEvent) == 32);
    std.debug.assert(@sizeOf(DbValue) == 24);
    std.debug.assert(@sizeOf(DbOptions) == 40);
    std.debug.assert(@sizeOf(DbResultEvent) == 96);
    std.debug.assert(@sizeOf(DbCell) == 16);
}

/// Records are padded to this.
pub const record_align = 8;

pub fn alignUp(n: usize) usize {
    return (n + record_align - 1) & ~@as(usize, record_align - 1);
}
