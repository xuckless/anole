//! Anole's logger: structured records (`anole.log.info("msg", .{ .k = v })`)
//! and the bridge for std.log, in two formats. `text` keeps std.log's look
//! with ` key=value` fields appended; `json` writes one JSON object per
//! line. Records go to stderr, or to a sink (the C ABI's log callback, a
//! test's capture). The format is process-wide.
//!
//! ```zig
//! anole.log.info("todo created", .{ .title = title });
//! req.log().warn("slow upstream", .{ .ms = 840 });
//! ```

const std = @import("std");
const record = @import("record.zig");
const value = @import("value.zig");

pub const Context = record.Context;

pub const Format = enum { auto, text, json };

pub const Options = struct {
    /// .auto: json when ServerOptions.environment is .production, else text.
    format: Format = .auto,
    /// Null: only std's compile-time level filters.
    level: ?std.log.Level = null,
    /// Written as "service" in every JSON record; at most 64 bytes kept.
    service: ?[]const u8 = null,
};

/// Where records go instead of stderr. Called on any thread, possibly
/// several at once; `scope` and `line` are valid during the call only. Must
/// not block or log.
pub const Callback = struct {
    func: *const fn (ud: ?*anyopaque, level: std.log.Level, scope: []const u8, line: []const u8) void,
    ud: ?*anyopaque = null,
};

// ------------------------------------------------------------------ state

var format_state: std.atomic.Value(u8) = .init(@intFromEnum(Format.text));
/// 255: no runtime filter.
var level_state: std.atomic.Value(u8) = .init(255);
var sink_state: std.atomic.Value(?*const Callback) = .init(null);
var service_buf: [64]u8 = undefined;
var service_len: std.atomic.Value(usize) = .init(0);

threadlocal var tl_buf: [16 * 1024]u8 = undefined;
threadlocal var tl_msg: [8 * 1024]u8 = undefined;
threadlocal var tl_busy: bool = false;

/// `.auto` stores `.text`: resolve it from the environment first.
pub fn setFormat(f: Format) void {
    format_state.store(@intFromEnum(if (f == .auto) Format.text else f), .release);
}

/// `.text` or `.json`.
pub fn currentFormat() Format {
    return @enumFromInt(format_state.load(.acquire));
}

pub fn setLevel(l: ?std.log.Level) void {
    level_state.store(if (l) |x| @intFromEnum(x) else 255, .release);
}

pub fn setService(name: ?[]const u8) void {
    const n = name orelse {
        service_len.store(0, .release);
        return;
    };
    // Keep whole UTF-8 characters.
    var len = @min(n.len, service_buf.len);
    while (len > 0 and len < n.len and (n[len] & 0xc0) == 0x80) len -= 1;
    service_len.store(0, .release);
    @memcpy(service_buf[0..len], n[0..len]);
    service_len.store(len, .release);
}

fn service() []const u8 {
    return service_buf[0..service_len.load(.acquire)];
}

/// Null: stderr. The Callback must stay valid until replaced.
pub fn setSink(cb: ?*const Callback) void {
    sink_state.store(cb, .release);
}

/// The sink in place, null for stderr (to restore it later).
pub fn currentSink() ?*const Callback {
    return sink_state.load(.acquire);
}

pub fn hasSink() bool {
    return sink_state.load(.acquire) != null;
}

fn enabled(level: std.log.Level) bool {
    const l = level_state.load(.acquire);
    return l == 255 or @intFromEnum(level) <= l;
}

fn now() std.Io.Timestamp {
    return std.Io.Clock.real.now(std.Options.debug_io);
}

// ------------------------------------------------------------------ output

/// One line on stderr, under the lock std.log uses.
fn writeStderrLine(line: []const u8) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var b: [64]u8 = undefined;
    const t = std.debug.lockStderr(&b).terminal();
    defer std.debug.unlockStderr();
    t.writer.writeAll(line) catch return;
    t.writer.writeAll("\n") catch return;
    t.writer.flush() catch {};
}

fn deliver(level: std.log.Level, scope: []const u8, line: []const u8) void {
    if (sink_state.load(.acquire)) |cb| return cb.func(cb.ud, level, scope, line);
    writeStderrLine(line);
}

const Bufs = struct {
    buf: []u8,
    msg: []u8,
    was_busy: bool,
};

fn acquire(small: *[1024]u8, small_msg: *[512]u8) Bufs {
    const was = tl_busy;
    tl_busy = true;
    if (was) return .{ .buf = small, .msg = small_msg, .was_busy = true };
    return .{ .buf = &tl_buf, .msg = &tl_msg, .was_busy = false };
}

fn release(b: Bufs) void {
    tl_busy = b.was_busy;
}

fn stdLogAt(comptime level: std.log.Level, comptime scope: @EnumLiteral(), line: []const u8) void {
    const l = std.log.scoped(scope);
    switch (level) {
        .err => l.err("{s}", .{line}),
        .warn => l.warn("{s}", .{line}),
        .info => l.info("{s}", .{line}),
        .debug => l.debug("{s}", .{line}),
    }
}

fn emit(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    ctx: Context,
    comptime message: []const u8,
    fields: anytype,
) void {
    if (!enabled(level)) return;
    comptime value.check(@TypeOf(fields));
    var small: [1024]u8 = undefined;
    var small_msg: [512]u8 = undefined;
    const b = acquire(&small, &small_msg);
    defer release(b);
    switch (currentFormat()) {
        .json => {
            const line = record.json(b.buf, .{
                .now = now(),
                .level = level,
                .scope = @tagName(scope),
                .message = message,
                .service = service(),
                .context = ctx,
            }, fields, "");
            deliver(level, @tagName(scope), line);
        },
        .auto, .text => {
            const line = record.text(b.buf, message, ctx, fields);
            if (sink_state.load(.acquire)) |cb| return cb.func(cb.ud, level, @tagName(scope), line);
            stdLogAt(level, scope, line);
        },
    }
}

// ------------------------------------------------------------------ API

/// A logger for one scope; `context` adds the request's ids to JSON
/// records and text lines.
pub fn Scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        context: Context = .{},

        const Self = @This();

        /// A copy that carries `ctx`.
        pub fn with(self: Self, ctx: Context) Self {
            _ = self;
            return .{ .context = ctx };
        }

        /// The same context under another scope.
        pub fn scoped(self: Self, comptime other: @EnumLiteral()) Scoped(other) {
            return .{ .context = self.context };
        }

        pub fn err(self: Self, comptime message: []const u8, fields: anytype) void {
            @branchHint(.cold);
            emit(.err, scope, self.context, message, fields);
        }
        pub fn warn(self: Self, comptime message: []const u8, fields: anytype) void {
            emit(.warn, scope, self.context, message, fields);
        }
        pub fn info(self: Self, comptime message: []const u8, fields: anytype) void {
            emit(.info, scope, self.context, message, fields);
        }
        pub fn debug(self: Self, comptime message: []const u8, fields: anytype) void {
            emit(.debug, scope, self.context, message, fields);
        }
    };
}

pub const Logger = Scoped(.default);

pub fn scoped(comptime scope: @EnumLiteral()) Scoped(scope) {
    return .{};
}

pub fn err(comptime message: []const u8, fields: anytype) void {
    emit(.err, .default, .{}, message, fields);
}
pub fn warn(comptime message: []const u8, fields: anytype) void {
    emit(.warn, .default, .{}, message, fields);
}
pub fn info(comptime message: []const u8, fields: anytype) void {
    emit(.info, .default, .{}, message, fields);
}
pub fn debug(comptime message: []const u8, fields: anytype) void {
    emit(.debug, .default, .{}, message, fields);
}

/// For anole.logFn: one std.log call as a record.
pub fn fromStd(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;
    const f = currentFormat();
    const sink = sink_state.load(.acquire);
    if (f != .json and sink == null) return std.log.defaultLog(level, scope, format, args);
    var small: [1024]u8 = undefined;
    var small_msg: [512]u8 = undefined;
    const b = acquire(&small, &small_msg);
    defer release(b);
    var mw: std.Io.Writer = .fixed(b.msg);
    mw.print(format, args) catch {};
    const message = mw.buffered();
    if (f == .json) {
        const line = record.json(b.buf, .{
            .now = now(),
            .level = level,
            .scope = @tagName(scope),
            .message = message,
            .service = service(),
        }, .{}, "");
        deliver(level, @tagName(scope), line);
    } else {
        sink.?.func(sink.?.ud, level, @tagName(scope), message);
    }
}

/// A JSON record whose members after the head are `fragment` (rendered
/// members, each starting with a comma). Used by the access log. In text
/// format nothing is written: the caller renders its own text line and
/// uses `writeRaw`.
pub fn writeJsonRecord(level: std.log.Level, scope: []const u8, ctx: Context, message: []const u8, fragment: []const u8) void {
    if (!enabled(level)) return;
    var small: [1024]u8 = undefined;
    var small_msg: [512]u8 = undefined;
    const b = acquire(&small, &small_msg);
    defer release(b);
    const line = record.json(b.buf, .{
        .now = now(),
        .level = level,
        .scope = scope,
        .message = message,
        .service = service(),
        .context = ctx,
    }, .{}, fragment);
    deliver(level, scope, line);
}

/// The JSON record for time `now_ms` (milliseconds since the epoch) into
/// `buf`, no newline: the shape every JSON record has (`time`, `level`,
/// `scope`, `message`, `service`, the request's ids), then `fragment`
/// (rendered members, each starting with a comma). For the access log.
pub fn renderJson(buf: []u8, now_ms: i64, level: std.log.Level, scope: []const u8, ctx: Context, message: []const u8, fragment: []const u8) []const u8 {
    return record.json(buf, .{
        .now = .{ .nanoseconds = @as(i96, now_ms) * std.time.ns_per_ms },
        .level = level,
        .scope = scope,
        .message = message,
        .service = service(),
        .context = ctx,
    }, .{}, fragment);
}

/// A pre-rendered line (the access log's text form): to the sink, or to
/// stderr as is.
pub fn writeRaw(level: std.log.Level, scope: []const u8, line: []const u8) void {
    if (!enabled(level)) return;
    deliver(level, scope, line);
}

test "level filter: below the runtime level nothing reaches the sink" {
    const T = struct {
        var count: usize = 0;
        fn f(_: ?*anyopaque, _: std.log.Level, _: []const u8, _: []const u8) void {
            count += 1;
        }
    };
    T.count = 0;
    var cb: Callback = .{ .func = T.f };
    setSink(&cb);
    setFormat(.json);
    setLevel(.warn);
    defer {
        setSink(null);
        setFormat(.text);
        setLevel(null);
    }
    info("dropped", .{});
    warn("kept", .{});
    err("kept", .{});
    try std.testing.expectEqual(@as(usize, 2), T.count);
}

test "sink: a callback gets the JSON line in json format and the text in text format" {
    const T = struct {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        fn f(_: ?*anyopaque, _: std.log.Level, _: []const u8, line: []const u8) void {
            len = line.len;
            @memcpy(buf[0..len], line);
        }
    };
    var cb: Callback = .{ .func = T.f };
    setSink(&cb);
    defer {
        setSink(null);
        setFormat(.text);
    }
    setFormat(.json);
    info("hello", .{ .n = 1 });
    try std.testing.expect(std.mem.startsWith(u8, T.buf[0..T.len], "{\"time\":\""));
    try std.testing.expect(std.mem.endsWith(u8, T.buf[0..T.len], "\"message\":\"hello\",\"n\":1}"));
    setFormat(.text);
    info("hello", .{ .n = 1 });
    try std.testing.expectEqualStrings("hello n=1", T.buf[0..T.len]);
}

test "fromStd: a std.log call in json format is a record with the formatted message" {
    const T = struct {
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        fn f(_: ?*anyopaque, _: std.log.Level, _: []const u8, line: []const u8) void {
            len = line.len;
            @memcpy(buf[0..len], line);
        }
    };
    var cb: Callback = .{ .func = T.f };
    setSink(&cb);
    setFormat(.json);
    defer {
        setSink(null);
        setFormat(.text);
    }
    fromStd(.info, .anole, "listening on {s}:{d}", .{ "0.0.0.0", @as(u16, 3000) });
    try std.testing.expect(std.mem.indexOf(u8, T.buf[0..T.len], "\"scope\":\"anole\",\"message\":\"listening on 0.0.0.0:3000\"") != null);
}

test "re-entrant log from a field's format uses the fallback buffer" {
    const Loud = struct {
        pub fn format(_: @This(), w: *std.Io.Writer) !void {
            info("inner", .{});
            try w.writeAll("loud");
        }
    };
    const T = struct {
        var count: usize = 0;
        fn f(_: ?*anyopaque, _: std.log.Level, _: []const u8, _: []const u8) void {
            count += 1;
        }
    };
    var cb: Callback = .{ .func = T.f };
    setSink(&cb);
    setFormat(.json);
    defer {
        setSink(null);
        setFormat(.text);
    }
    info("outer", .{ .v = Loud{} });
    try std.testing.expectEqual(@as(usize, 2), T.count);
}

test {
    _ = record;
    _ = value;
    _ = @import("escape.zig");
    _ = @import("timestamp.zig");
    _ = @import("redact.zig");
}
