//! libanole: the C ABI (`include/anole.h`) over `anole.capi`. The root of
//! `zig build capi`; every exported symbol is `anole_*`. This file only
//! translates: C arguments in, status codes and `anole_last_error` out.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("anole");
const capi_options = @import("capi_options");
const engine = anole.capi;
const abi = engine.abi;
const Engine = engine.Engine;
const Consumer = engine.Consumer;
const Str = abi.Str;
const Header = abi.Header;

pub const zio_options = anole.zio_options;
/// A panic goes to the binding's log callback (when it set one) as one error
/// line with its stack trace, and to standard error as Zig prints it (the
/// callback only queues the line, and the process aborts before a binding
/// could flush it).
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (log_fn != null) anole.logPanic(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr);
}
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = if (builtin.mode == .debug) .debug else .info,
    .log_scope_levels = &.{
        .{ .scope = .zio, .level = .info },
        .{ .scope = .anole, .level = .info },
        .{ .scope = .anole_h2, .level = .info },
        .{ .scope = .anole_h3, .level = .info },
    },
};

// ---- logging ---------------------------------------------------------------------

var log_fn: ?abi.LogFn = null;
var log_ud: ?*anyopaque = null;
var log_max: std.atomic.Value(i32) = .init(abi.LOG_INFO);

fn levelOf(l: std.log.Level) i32 {
    return switch (l) {
        .err => abi.LOG_ERROR,
        .warn => abi.LOG_WARN,
        .info => abi.LOG_INFO,
        .debug => abi.LOG_DEBUG,
    };
}

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (levelOf(level) > log_max.load(.monotonic)) return;
    const f = log_fn orelse return anole.logFn(level, scope, format, args);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(format, args) catch {
        // Cut short: what fits, marked.
        @memcpy(buf[buf.len - 3 ..], "...");
        w.end = buf.len;
    };
    f(log_ud, levelOf(level), Str.of(@tagName(scope)), Str.of(w.buffered()));
}

// ---- the last error, per thread --------------------------------------------------

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setError(comptime fmt: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&last_error_buf);
    w.print(fmt, args) catch {};
    last_error_len = w.end;
}

fn clearError() void {
    last_error_len = 0;
}

fn fail(code: i32, comptime what: []const u8, err: anyerror) i32 {
    setError(what ++ ": {t}", .{err});
    return code;
}

/// An options struct the caller may know fewer fields of: what its `size`
/// covers, the rest zero.
fn readSized(comptime T: type, p: *const T) ?T {
    const size = p.size;
    if (size < @sizeOf(usize)) return null;
    var out = std.mem.zeroes(T);
    const n = @min(size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&out)[0..n], @as([*]const u8, @ptrCast(p))[0..n]);
    return out;
}

fn engineOf(s: ?*anyopaque) ?*Engine {
    return @ptrCast(@alignCast(s orelse return null));
}

fn consumerOf(c: ?*anyopaque) ?*Consumer {
    return @ptrCast(@alignCast(c orelse return null));
}

fn bytes(p: ?*const anyopaque, len: usize) ?[]const u8 {
    if (len == 0) return "";
    return @as([*]const u8, @ptrCast(p orelse return null))[0..len];
}

fn headersOf(h: ?[*]const Header, n: usize) ?[]const Header {
    if (n == 0) return &.{};
    return (h orelse return null)[0..n];
}

fn answer(err: engine.AnswerError) i32 {
    return switch (err) {
        error.Gone => abi.E_GONE,
        error.Invalid => blk: {
            setError("invalid argument (status, header, flag or size)", .{});
            break :blk abi.E_INVALID;
        },
        error.OutOfMemory => abi.E_NOMEM,
        error.Unsupported => abi.E_UNSUPPORTED,
        error.Timeout => abi.E_TIMEOUT,
        error.Again => abi.E_AGAIN,
        error.State => blk: {
            setError("not in this state (a second message for a unary answer, metadata after the first message, OK without a response message, ...)", .{});
            break :blk abi.E_STATE;
        },
        error.TooBig => abi.E_TOOBIG,
    };
}

fn live() ?*Engine {
    return engine.global;
}

// ---- basics ------------------------------------------------------------------------

export fn anole_last_error() Str {
    return .{ .ptr = &last_error_buf, .len = last_error_len };
}

export fn anole_abi_version() u32 {
    return abi.version;
}

export fn anole_version() Str {
    return Str.of(capi_options.version);
}

export fn anole_has_feature(name: Str) c_int {
    const f = anole.features;
    const n = name.slice();
    const table = .{
        .{ "tls", f.tls == .boringssl },
        .{ "http2", f.http2 },
        .{ "http3", f.http3 },
        .{ "webtransport", f.http3 },
        .{ "websocket", f.websocket },
        .{ "compression", f.compression },
        .{ "brotli", f.brotli },
        .{ "auth", f.auth },
        .{ "grpc", f.grpc },
        .{ "sqlite", f.sqlite },
        .{ "postgres", f.postgres },
        .{ "redis", f.redis },
        .{ "mongodb", f.mongodb },
    };
    inline for (table) |entry| if (std.mem.eql(u8, n, entry[0])) return @intFromBool(entry[1]);
    return 0;
}

// ---- lifecycle --------------------------------------------------------------------

export fn anole_server_create(options: ?*const abi.ServerOptions, out: ?*?*anyopaque) i32 {
    clearError();
    const o = readSized(abi.ServerOptions, options orelse return abi.E_INVALID) orelse return abi.E_INVALID;
    const dst = out orelse return abi.E_INVALID;
    if (engine.global != null) {
        setError("one anole_server per process", .{});
        return abi.E_STATE;
    }
    if (o.log_level < 0 or o.log_level > abi.LOG_DEBUG) {
        setError("log_level: 0 or ANOLE_LOG_ERROR..ANOLE_LOG_DEBUG", .{});
        return abi.E_INVALID;
    }
    if (o.flags & ~abi.SERVER_SIGNALS != 0) return abi.E_INVALID;
    log_max.store(if (o.log_level == 0) abi.LOG_INFO else o.log_level, .monotonic);
    if (o.log) |f| {
        log_fn = f;
        log_ud = o.log_ud;
    }
    const json = o.config_json.slice();
    var why_buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = Engine.create(if (json.len == 0) "{}" else json, o.flags & abi.SERVER_SIGNALS != 0, &why) catch |err| switch (err) {
        error.Config => {
            setError("{s}", .{why.buffered()});
            return abi.E_CONFIG;
        },
        error.OutOfMemory => return fail(abi.E_NOMEM, "anole_server_create", err),
    };
    dst.* = e;
    return abi.OK;
}

export fn anole_server_start(s: ?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return abi.E_INVALID;
    if (e.consumers.items.len == 0 and e.needsConsumer()) {
        setError("routes name handlers but no consumer is attached", .{});
        return abi.E_STATE;
    }
    e.start() catch |err| return switch (err) {
        error.State => fail(abi.E_STATE, "anole_server_start", err),
        error.OutOfMemory => fail(abi.E_NOMEM, "anole_server_start", err),
        else => fail(abi.E_SYSTEM, "anole_server_start", err),
    };
    return abi.OK;
}

export fn anole_server_port(s: ?*anyopaque, i: u32, out: ?*u16) i32 {
    const e = engineOf(s) orelse return abi.E_INVALID;
    if (i >= e.ports.items.len) return abi.E_INVALID;
    (out orelse return abi.E_INVALID).* = e.ports.items[i];
    return abi.OK;
}

export fn anole_server_drain(s: ?*anyopaque) i32 {
    const e = engineOf(s) orelse return abi.E_INVALID;
    e.drain() catch |err| return fail(abi.E_STATE, "anole_server_drain", err);
    return abi.OK;
}

export fn anole_server_wait(s: ?*anyopaque, timeout_ms: i32) i32 {
    const e = engineOf(s) orelse return abi.E_INVALID;
    return if (e.wait(timeout_ms)) abi.OK else abi.E_TIMEOUT;
}

export fn anole_server_reload_certificates(s: ?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return abi.E_INVALID;
    e.reloadCertificates() catch |err| return switch (err) {
        error.State => fail(abi.E_STATE, "anole_server_reload_certificates", err),
        else => fail(abi.E_SYSTEM, "anole_server_reload_certificates", err),
    };
    return abi.OK;
}

export fn anole_server_destroy(s: ?*anyopaque) void {
    const e = engineOf(s) orelse return;
    e.destroy();
}

export fn anole_server_stats(s: ?*anyopaque, out: ?*abi.Stats) i32 {
    const e = engineOf(s) orelse return abi.E_INVALID;
    const dst = out orelse return abi.E_INVALID;
    const size = dst.size;
    if (size < @sizeOf(usize)) return abi.E_INVALID;
    const st = e.stats();
    const n = @min(size, @sizeOf(abi.Stats));
    @memcpy(@as([*]u8, @ptrCast(dst))[@sizeOf(usize)..n], std.mem.asBytes(&st)[@sizeOf(usize)..n]);
    return abi.OK;
}

// ---- consumers ---------------------------------------------------------------------

export fn anole_consumer_attach(s: ?*anyopaque, options: ?*const abi.ConsumerOptions, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return abi.E_INVALID;
    const o = readSized(abi.ConsumerOptions, options orelse return abi.E_INVALID) orelse return abi.E_INVALID;
    const dst = out orelse return abi.E_INVALID;
    if (o.flags & ~abi.CONSUMER_SHARED != 0) return abi.E_INVALID;
    const shared = o.flags & abi.CONSUMER_SHARED != 0;
    if (o.wake == null and !shared and builtin.os.tag == .windows) {
        setError("Windows has no doorbell fd: pass a wake callback, or use anole_poll_wait", .{});
        return abi.E_UNSUPPORTED;
    }
    const c = e.attach(o.wake, o.wake_ud, shared) catch |err| return switch (@as(anyerror, err)) {
        error.State => fail(abi.E_STATE, "anole_consumer_attach (before anole_server_start, 256 at most)", err),
        error.OutOfMemory => fail(abi.E_NOMEM, "anole_consumer_attach", err),
        else => fail(abi.E_SYSTEM, "anole_consumer_attach", err),
    };
    dst.* = c;
    return abi.OK;
}

export fn anole_consumer_fd(c: ?*anyopaque) c_int {
    const consumer = consumerOf(c) orelse return -1;
    return if (consumer.wake_fn == null) consumer.fd_read else -1;
}

fn pollBuf(buf: ?*anyopaque, cap: usize) ?[]u8 {
    const p: [*]u8 = @ptrCast(buf orelse return null);
    if (@intFromPtr(p) % abi.record_align != 0) {
        setError("the poll buffer must be 8-byte aligned", .{});
        return null;
    }
    return p[0..cap];
}

export fn anole_poll(c: ?*anyopaque, buf: ?*anyopaque, cap: usize, flags: u32) i64 {
    const consumer = consumerOf(c) orelse return abi.E_INVALID;
    const out = pollBuf(buf, cap) orelse return abi.E_INVALID;
    if (flags & ~abi.POLL_NOARM != 0) return abi.E_INVALID;
    const n = engine.poll(consumer, out, flags & abi.POLL_NOARM == 0) catch return abi.E_TOOBIG;
    return @intCast(n);
}

export fn anole_poll_wait(c: ?*anyopaque, buf: ?*anyopaque, cap: usize, timeout_ms: i32) i64 {
    const consumer = consumerOf(c) orelse return abi.E_INVALID;
    const out = pollBuf(buf, cap) orelse return abi.E_INVALID;
    const n = engine.pollWait(consumer, out, timeout_ms) catch return abi.E_TOOBIG;
    return @intCast(n);
}

// ---- requests and responses -------------------------------------------------------

export fn anole_req_read(r: u64, buf: ?*anyopaque, cap: usize, timeout_ms: i32) i64 {
    const e = live() orelse return abi.E_GONE;
    if (cap == 0) return abi.E_INVALID;
    const p: [*]u8 = @ptrCast(buf orelse return abi.E_INVALID);
    const n = engine.reqRead(e, r, p[0..cap], timeout_ms) catch |err| return answer(err);
    return @intCast(n);
}

export fn anole_respond(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize, body: ?*const anyopaque, len: usize, flags: u32) i32 {
    const e = live() orelse return abi.E_GONE;
    if (flags & ~abi.BODY_BORROW != 0) return abi.E_INVALID;
    const hs = headersOf(headers, nheaders) orelse return abi.E_INVALID;
    const b = bytes(body, len) orelse return abi.E_INVALID;
    engine.respond(e, r, status, hs, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_respond_fd(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize, fd: c_int, offset: u64, len: u64) i32 {
    const e = live() orelse return abi.E_GONE;
    const hs = headersOf(headers, nheaders) orelse return abi.E_INVALID;
    engine.respondFd(e, r, status, hs, fd, offset, len) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_stream_start(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize) i32 {
    const e = live() orelse return abi.E_GONE;
    const hs = headersOf(headers, nheaders) orelse return abi.E_INVALID;
    engine.streamStart(e, r, status, hs) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_stream_write(r: u64, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    const e = live() orelse return abi.E_GONE;
    if (flags & ~abi.BODY_BORROW != 0) return abi.E_INVALID;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    const busy = engine.streamWrite(e, r, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_stream_write_wait(r: u64, data: ?*const anyopaque, len: usize, timeout_ms: i32) i32 {
    const e = live() orelse return abi.E_GONE;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    engine.streamWriteWait(e, r, b, timeout_ms) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_stream_end(r: u64, trailers: ?[*]const Header, ntrailers: usize) i32 {
    const e = live() orelse return abi.E_GONE;
    const ts = headersOf(trailers, ntrailers) orelse return abi.E_INVALID;
    engine.streamEnd(e, r, ts) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_release(r: u64) i32 {
    const e = live() orelse return abi.E_GONE;
    engine.release(e, r) catch |err| return answer(err);
    return abi.OK;
}

// ---- WebSocket -----------------------------------------------------------------------

const have_ws = anole.features.websocket;

export fn anole_ws_send(w: u64, typ: c_int, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_ws) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    if (flags & ~abi.BODY_BORROW != 0) return abi.E_INVALID;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    const busy = engine.ws.send(e, w, typ, b, flags & abi.BODY_BORROW != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_ws_close(w: u64, code: u16, reason: Str) i32 {
    if (comptime !have_ws) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.ws.close(e, w, code, reason.slice()) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_ws_subscribe(w: u64, topic: Str) i32 {
    if (comptime !have_ws) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.ws.subscribe(e, w, topic.slice(), true) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_ws_unsubscribe(w: u64, topic: Str) i32 {
    if (comptime !have_ws) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.ws.subscribe(e, w, topic.slice(), false) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_ws_publish(s: ?*anyopaque, topic: Str, typ: c_int, data: ?*const anyopaque, len: usize, except: u64) i32 {
    if (comptime !have_ws) return abi.E_UNSUPPORTED;
    const e = engineOf(s) orelse return abi.E_INVALID;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    engine.ws.publish(e, topic.slice(), typ, b, except) catch |err| return answer(err);
    return abi.OK;
}

// ---- gRPC ------------------------------------------------------------------------------

const have_grpc = anole.features.grpc;

export fn anole_grpc_send_headers(c: u64, metadata: ?[*]const Header, n: usize) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const md = headersOf(metadata, n) orelse return abi.E_INVALID;
    engine.grpc.sendHeaders(e, c, md) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_send(c: u64, msg: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    if (flags & ~(abi.BODY_BORROW | abi.GRPC_SEND_FINISH) != 0) return abi.E_INVALID;
    const b = bytes(msg, len) orelse return abi.E_INVALID;
    const busy = engine.grpc.send(e, c, b, flags & abi.BODY_BORROW != 0, flags & abi.GRPC_SEND_FINISH != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_grpc_send_wait(c: u64, msg: ?*const anyopaque, len: usize, timeout_ms: i32) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const b = bytes(msg, len) orelse return abi.E_INVALID;
    engine.grpc.sendWait(e, c, b, timeout_ms) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_finish(c: u64, code: u32, message: Str, trailers: ?[*]const Header, n: usize) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const ts = headersOf(trailers, n) orelse return abi.E_INVALID;
    engine.grpc.finish(e, c, code, message.slice(), ts) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_read(c: u64, n: u32) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    if (n == 0) return abi.E_INVALID;
    engine.grpc.read(e, c, n) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_grpc_health_set(s: ?*anyopaque, service: Str, status: c_int) i32 {
    if (comptime !have_grpc) return abi.E_UNSUPPORTED;
    clearError();
    const e = engineOf(s) orelse return abi.E_INVALID;
    engine.grpc.healthSet(e, service.slice(), status) catch |err| return switch (err) {
        error.State => blk: {
            setError("anole_grpc_health_set: the configuration has no \"grpc\": {{\"health\": true}}", .{});
            break :blk abi.E_STATE;
        },
        else => answer(err),
    };
    return abi.OK;
}

// ---- WebTransport ------------------------------------------------------------------

const have_wt = anole.features.http3;

export fn anole_wt_open_stream(w: u64, flags: u32, out: ?*u64) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const o = out orelse return abi.E_INVALID;
    if (flags & ~abi.WT_UNI != 0) return abi.E_INVALID;
    o.* = engine.wt.openStream(e, w, flags & abi.WT_UNI != 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_stream_write(st: u64, data: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    if (flags & ~abi.WT_FIN != 0) return abi.E_INVALID;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    const busy = engine.wt.write(e, st, b, flags & abi.WT_FIN != 0) catch |err| return answer(err);
    return if (busy) abi.BUSY else abi.OK;
}

export fn anole_wt_stream_reset(st: u64, code: u32) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.wt.streamOp(e, st, .reset, code) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_stream_stop(st: u64, code: u32) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.wt.streamOp(e, st, .stop, code) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_stream_release(st: u64) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.wt.streamOp(e, st, .release, 0) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_send_datagram(w: u64, data: ?*const anyopaque, len: usize) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const b = bytes(data, len) orelse return abi.E_INVALID;
    engine.wt.sendDatagram(e, w, b) catch |err| return answer(err);
    return abi.OK;
}

export fn anole_wt_max_datagram(w: u64) i64 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    const n = engine.wt.maxDatagram(e, w) catch |err| return answer(err);
    return @intCast(n);
}

export fn anole_wt_close(w: u64, code: u32, reason: Str) i32 {
    if (comptime !have_wt) return abi.E_UNSUPPORTED;
    const e = live() orelse return abi.E_GONE;
    engine.wt.close(e, w, code, reason.slice()) catch |err| return answer(err);
    return abi.OK;
}

// ---- databases ---------------------------------------------------------------------

const db_mod = engine.db;

fn dbOf(d: ?*anyopaque) ?*db_mod.Db {
    return @ptrCast(@alignCast(d orelse return null));
}

export fn anole_db_find(s: ?*anyopaque, name: Str, out: ?*?*anyopaque) i32 {
    clearError();
    const e = engineOf(s) orelse return abi.E_INVALID;
    const dst = out orelse return abi.E_INVALID;
    const d = db_mod.find(e, name.slice()) orelse {
        setError("no database \"{s}\" in the configuration", .{name.slice()});
        return abi.E_INVALID;
    };
    dst.* = d;
    return abi.OK;
}

fn dbSubmit(verb: db_mod.Verb, d_: ?*anyopaque, c_: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    clearError();
    const d = dbOf(d_) orelse return abi.E_INVALID;
    const c = consumerOf(c_) orelse return abi.E_INVALID;
    const ps: []const abi.DbValue = if (nparams == 0) &.{} else (params orelse return abi.E_INVALID)[0..nparams];
    const o: abi.DbOptions = if (opts) |p| readSized(abi.DbOptions, p) orelse return abi.E_INVALID else .{ .size = @sizeOf(abi.DbOptions) };
    db_mod.submit(d, c, verb, sql.slice(), ps, o, user_data) catch |err| return switch (err) {
        error.Invalid => blk: {
            setError("invalid argument (a value type, or a consumer of another server)", .{});
            break :blk abi.E_INVALID;
        },
        error.State => blk: {
            setError("the server is not running, or no executor feeds this consumer", .{});
            break :blk abi.E_STATE;
        },
        error.OutOfMemory => abi.E_NOMEM,
        error.Unsupported => abi.E_UNSUPPORTED,
    };
    return abi.OK;
}

export fn anole_db_query(d: ?*anyopaque, c: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbSubmit(.query, d, c, sql, params, nparams, opts, user_data);
}

export fn anole_db_exec(d: ?*anyopaque, c: ?*anyopaque, sql: Str, params: ?[*]const abi.DbValue, nparams: usize, opts: ?*const abi.DbOptions, user_data: u64) i32 {
    return dbSubmit(.exec, d, c, sql, params, nparams, opts, user_data);
}

export fn anole_db_invalidate(d_: ?*anyopaque, tag: Str) i32 {
    const d = dbOf(d_) orelse return abi.E_INVALID;
    db_mod.invalidate(d, tag.slice()) catch return abi.E_STATE;
    return abi.OK;
}
