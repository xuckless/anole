//! libanole: the C ABI (`include/anole.h`) over `anole.capi`. The root of
//! `zig build capi`; every exported symbol is `anole_*`.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("anole");
const engine = anole.capi;
const Engine = engine.Engine;

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    .log_level = .info,
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

// ---- C types (mirrors of anole.h) -------------------------------------------

const Str = engine.CStr;
const Header = engine.CHeader;

const ServerOptions = extern struct {
    size: usize,
    config_json: Str,
    flags: u32,
};
const ConsumerOptions = extern struct {
    size: usize,
    wake: ?engine.WakeFn,
    wake_ud: ?*anyopaque,
    flags: u32,
};
const Stats = extern struct {
    size: usize,
    expired: u64,
    gone: u64,
    busy: u64,
    wakes: u64,
    rewakes: u64,
};

const OK: i32 = 0;
const E_INVALID: i32 = -1;
const E_GONE: i32 = -2;
const E_NOMEM: i32 = -4;
const E_CONFIG: i32 = -5;
const E_STATE: i32 = -6;
const E_UNSUPPORTED: i32 = -7;
const E_TOOBIG: i32 = -8;
const E_SYSTEM: i32 = -9;

const abi_version: u32 = (0 << 16) | 0;
const SIGNALS: u32 = 1;

// ---- the last error, per thread ---------------------------------------------

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&last_error_buf, fmt, args) catch last_error_buf[0..];
    last_error_len = s.len;
}

fn fail(code: i32, err: anyerror) i32 {
    setError("{t}", .{err});
    return code;
}

/// Reads an options struct the caller may know fewer fields of: what its
/// `size` covers, the rest zero.
fn readSized(comptime T: type, p: *const T) ?T {
    const size = p.size;
    if (size < @sizeOf(usize)) return null;
    var out = std.mem.zeroes(T);
    const n = @min(size, @sizeOf(T));
    @memcpy(std.mem.asBytes(&out)[0..n], std.mem.asBytes(p)[0..n]);
    return out;
}

fn engineOf(s: ?*anyopaque) ?*Engine {
    return @ptrCast(@alignCast(s orelse return null));
}

// ---- exports ------------------------------------------------------------------

export fn anole_last_error() Str {
    return .{ .ptr = &last_error_buf, .len = last_error_len };
}

export fn anole_abi_version() u32 {
    return abi_version;
}

export fn anole_version() Str {
    const v = "0.1.0-capi-spike";
    return .{ .ptr = v.ptr, .len = v.len };
}

export fn anole_server_create(options: ?*const ServerOptions, out: ?*?*anyopaque) i32 {
    const o = readSized(ServerOptions, options orelse return E_INVALID) orelse return E_INVALID;
    const dst = out orelse return E_INVALID;
    if (engine.global != null) {
        setError("one anole_server per process", .{});
        return E_STATE;
    }
    const json = if (o.config_json.ptr) |p| p[0..o.config_json.len] else "{}";
    var why_buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = Engine.create(json, o.flags & SIGNALS != 0, &why) catch |err| switch (err) {
        error.Config => {
            setError("{s}", .{why.buffered()});
            return E_CONFIG;
        },
        error.OutOfMemory => return fail(E_NOMEM, err),
    };
    dst.* = e;
    return OK;
}

export fn anole_server_start(s: ?*anyopaque) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    e.start() catch |err| return switch (err) {
        error.State => fail(E_STATE, err),
        error.OutOfMemory => fail(E_NOMEM, err),
        else => fail(E_SYSTEM, err),
    };
    return OK;
}

export fn anole_server_port(s: ?*anyopaque, i: u32, out: ?*u16) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    if (i >= e.ports.items.len) return E_INVALID;
    (out orelse return E_INVALID).* = e.ports.items[i];
    return OK;
}

export fn anole_server_drain(s: ?*anyopaque) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    e.drain() catch |err| return fail(E_STATE, err);
    return OK;
}

export fn anole_server_wait(s: ?*anyopaque) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    e.wait();
    return OK;
}

export fn anole_server_destroy(s: ?*anyopaque) void {
    const e = engineOf(s) orelse return;
    e.destroy();
}

export fn anole_server_stats(s: ?*anyopaque, out: ?*Stats) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    const dst = out orelse return E_INVALID;
    var wakes: u64 = 0;
    var rewakes: u64 = 0;
    for (e.consumers.items) |c| {
        wakes += c.wakes.load(.monotonic);
        rewakes += c.rewakes.load(.monotonic);
    }
    const st: Stats = .{
        .size = @sizeOf(Stats),
        .expired = e.expired_count.load(.monotonic),
        .gone = e.gone_count.load(.monotonic),
        .busy = e.busy_count.load(.monotonic),
        .wakes = wakes,
        .rewakes = rewakes,
    };
    const n = @min(dst.size, @sizeOf(Stats));
    if (n < @sizeOf(usize)) return E_INVALID;
    @memcpy(std.mem.asBytes(dst)[@sizeOf(usize)..n], std.mem.asBytes(&st)[@sizeOf(usize)..n]);
    return OK;
}

export fn anole_consumer_attach(s: ?*anyopaque, options: ?*const ConsumerOptions, out: ?*?*anyopaque) i32 {
    const e = engineOf(s) orelse return E_INVALID;
    const o = readSized(ConsumerOptions, options orelse return E_INVALID) orelse return E_INVALID;
    const dst = out orelse return E_INVALID;
    if (o.wake == null and builtin.os.tag == .windows) {
        setError("Windows has no doorbell fd: pass a wake callback", .{});
        return E_UNSUPPORTED;
    }
    const c = e.attach(o.wake, o.wake_ud) catch |err| return switch (err) {
        error.State => fail(E_STATE, err),
        error.OutOfMemory => fail(E_NOMEM, err),
        else => fail(E_SYSTEM, err),
    };
    dst.* = c;
    return OK;
}

export fn anole_consumer_fd(c: ?*anyopaque) c_int {
    const consumer: *engine.Consumer = @ptrCast(@alignCast(c orelse return -1));
    return if (consumer.wake_fn == null) consumer.fd_read else -1;
}

const POLL_NOARM: u32 = 1;

export fn anole_poll(c: ?*anyopaque, buf: ?*anyopaque, cap: usize, flags: u32) i64 {
    const consumer: *engine.Consumer = @ptrCast(@alignCast(c orelse return E_INVALID));
    const p: [*]u8 = @ptrCast(buf orelse return E_INVALID);
    if (@intFromPtr(p) % 8 != 0) {
        setError("anole_poll: the buffer must be 8-byte aligned", .{});
        return E_INVALID;
    }
    const n = engine.poll(consumer, p[0..cap], flags & POLL_NOARM == 0) catch |err| return switch (err) {
        error.TooBig => E_TOOBIG,
        error.State => E_STATE,
    };
    return @intCast(n);
}

export fn anole_respond(r: u64, status: u16, headers: ?[*]const Header, nheaders: usize, body: ?*const anyopaque, len: usize, flags: u32) i32 {
    if (flags != 0) return E_INVALID;
    const e = engine.global orelse return E_GONE;
    const hs: []const Header = if (headers) |h| h[0..nheaders] else &.{};
    const b: []const u8 = if (body) |p| @as([*]const u8, @ptrCast(p))[0..len] else "";
    engine.respond(e, r, status, hs, b) catch |err| return switch (err) {
        error.Gone => E_GONE,
        error.Invalid => E_INVALID,
        error.OutOfMemory => E_NOMEM,
    };
    return OK;
}

export fn anole_release(r: u64) i32 {
    const e = engine.global orelse return E_GONE;
    engine.respond(e, r, 500, &.{}, "") catch |err| return switch (err) {
        error.Gone => E_GONE,
        error.Invalid => E_INVALID,
        error.OutOfMemory => E_NOMEM,
    };
    return OK;
}
