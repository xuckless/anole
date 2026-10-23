//! The console's wire protocol (design section 5): newline-delimited JSON
//! over a stream, `proto: 1`. Std-only; the server and the client share these
//! types. Unknown fields are ignored on both sides; an unknown frame type
//! decodes as `.unknown`.
const std = @import("std");

pub const proto: u32 = 1;
pub const max_client_line = 64 * 1024;
pub const max_server_line = 1024 * 1024;
pub const max_clients = 4;
/// A log record's text is cut here.
pub const max_log_text = 16 * 1024;
pub const bucket_count = 98;

// Error and result codes.
pub const code_unknown_op = "unknown_op";
pub const code_invalid = "invalid";
pub const code_unavailable = "unavailable";
pub const code_refused = "refused";
pub const code_confirm_required = "confirm_required";
pub const code_busy = "busy";
pub const code_failed = "failed";
pub const code_too_big = "too_big";
pub const code_version = "version";

pub const version_message = "this app speaks console protocol 1 (Anole 0.3.0); use an anole CLI of the same version";

// Confirm tokens of the mutating ops.
pub const confirm_drain = "drain";
pub const confirm_restart = "restart";
pub const confirm_full_restart = "full-restart";

pub const Op = enum {
    ping,
    snapshot,
    subscribe,
    unsubscribe,
    reload,
    drain,
    restart,
    full_restart,
    launch_info,

    pub fn parse(s: []const u8) ?Op {
        return std.meta.stringToEnum(Op, s);
    }
};

pub const View = enum { conns, db, ws, h3, runtime, config, routes, errors, tasks };

pub const App = struct {
    name: []const u8 = "",
    pid: i32 = 0,
    started: []const u8 = "",
    host: []const u8 = "",
    environment: []const u8 = "",
    deployment: []const u8 = "",
    build: []const u8 = "",
    executors: u32 = 0,
    runtime: []const u8 = "",
};

pub const Allow = struct {
    reload: bool = false,
    drain: bool = false,
    restart: bool = false,
    full_restart: bool = false,
};

pub const WhyNot = struct {
    reload: ?[]const u8 = null,
    drain: ?[]const u8 = null,
    restart: ?[]const u8 = null,
    full_restart: ?[]const u8 = null,
};

pub const Supervisor = struct {
    kind: []const u8 = "none",
    detail: []const u8 = "",
};

/// Server hello (first frame) and client hello share one shape.
pub const Hello = struct {
    proto: u32 = proto,
    anole: ?[]const u8 = null,
    client: ?[]const u8 = null,
    app: ?App = null,
    allow: ?Allow = null,
    why_not: ?WhyNot = null,
    supervisor: ?Supervisor = null,
    features: []const []const u8 = &.{},
    unavailable: ?std.json.Value = null,
};

pub const Filter = struct {
    level: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    route: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    grep: ?[]const u8 = null,
};

pub const Request = struct {
    id: u32,
    op: []const u8,
    what: ?[]const u8 = null,
    stream: ?[]const u8 = null,
    filter: ?Filter = null,
    backlog: ?u16 = null,
    interval_ms: ?u32 = null,
    sub: ?u32 = null,
    confirm: ?[]const u8 = null,
};

pub const Response = struct {
    id: u32,
    ok: bool,
    data: ?std.json.Value = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const Log = struct {
    sub: u32 = 0,
    time: []const u8 = "",
    level: []const u8 = "info",
    scope: []const u8 = "",
    request_id: []const u8 = "",
    route: []const u8 = "",
    json: bool = false,
    text: []const u8 = "",
};

pub const Dropped = struct { sub: u32 = 0, n: u64 = 0 };

pub const RouteStat = struct {
    i: u32 = 0,
    m: []const u8 = "",
    p: []const u8 = "",
    n: u32 = 0,
    s2: u32 = 0,
    s3: u32 = 0,
    s4: u32 = 0,
    s5: u32 = 0,
    /// Non-zero latency buckets only: [bucket, count].
    h: []const [2]u32 = &.{},
};

pub const DbStat = struct {
    i: u32 = 0,
    n: u32 = 0,
    e: u32 = 0,
    h: []const [2]u32 = &.{},
};

pub const ConnsStat = struct {
    total: u32 = 0,
    /// [connections, streams] per executor.
    executors: []const [2]u32 = &.{},
};

pub const Stats = struct {
    sub: u32 = 0,
    seq: u64 = 0,
    mono_ms: i64 = 0,
    routes: []const RouteStat = &.{},
    db: []const DbStat = &.{},
    conns: ?ConnsStat = null,
    err_seq: u64 = 0,
};

pub const Error5xx = struct {
    sub: u32 = 0,
    seq: u64 = 0,
    time: []const u8 = "",
    status: u16 = 500,
    method: []const u8 = "",
    path: []const u8 = "",
    route: []const u8 = "",
    @"error": []const u8 = "",
    request_id: []const u8 = "",
    duration_us: u64 = 0,
};

pub const Restarting = struct {
    mode: []const u8 = "",
    successor_pid: ?i32 = null,
    pid: ?i32 = null,
};

pub const Bye = struct { reason: []const u8 = "stop" };

pub const ErrorFrame = struct {
    code: []const u8,
    message: ?[]const u8 = null,
};

pub const Frame = union(enum) {
    hello: Hello,
    req: Request,
    res: Response,
    log: Log,
    dropped: Dropped,
    stats: Stats,
    error5xx: Error5xx,
    restarting: Restarting,
    bye: Bye,
    err: ErrorFrame,
    /// A well-formed object whose `t` this side does not know: ignored.
    unknown,

    pub fn tag(self: Frame) []const u8 {
        return switch (self) {
            .err => "error",
            .unknown => "unknown",
            inline else => |_, t| @tagName(t),
        };
    }
};

pub const DecodeError = error{ InvalidFrame, OutOfMemory };

/// Writes one frame and its newline. Optional fields that are null are left out.
pub fn encode(frame: Frame, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    jw.beginObject() catch return error.WriteFailed;
    jw.objectField("t") catch return error.WriteFailed;
    jw.write(frame.tag()) catch return error.WriteFailed;
    switch (frame) {
        .unknown => {},
        inline else => |v| writeFields(&jw, v) catch return error.WriteFailed,
    }
    jw.endObject() catch return error.WriteFailed;
    try w.writeByte('\n');
}

fn writeFields(jw: *std.json.Stringify, v: anytype) !void {
    const info = @typeInfo(@TypeOf(v)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const val = @field(v, name);
        if (@typeInfo(T) == .optional) {
            if (val) |x| {
                try jw.objectField(name);
                try jw.write(x);
            }
        } else {
            try jw.objectField(name);
            try jw.write(val);
        }
    }
}

/// Decodes one line (without its newline). Everything in the result is
/// allocated from `arena`.
pub fn decode(arena: std.mem.Allocator, line: []const u8) DecodeError!Frame {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFrame,
    };
    if (root != .object) return error.InvalidFrame;
    const t_val = root.object.get("t") orelse return error.InvalidFrame;
    if (t_val != .string) return error.InvalidFrame;
    const t = t_val.string;
    const info = @typeInfo(Frame).@"union";
    inline for (info.field_names, info.field_types) |fname, FT| {
        if (FT == void) continue;
        const name = comptime if (std.mem.eql(u8, fname, "err")) "error" else fname;
        if (std.mem.eql(u8, t, name)) {
            const v = std.json.parseFromValueLeaky(FT, arena, root, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidFrame,
            };
            return @unionInit(Frame, fname, v);
        }
    }
    return .unknown;
}

/// The error a server answers a hello of another protocol version with.
pub fn versionError(h: Hello) ?ErrorFrame {
    if (h.proto == proto) return null;
    return .{ .code = code_version, .message = version_message };
}

pub const LineError = error{LineTooLong} || std.mem.Allocator.Error;

/// Splits a byte stream into lines, with a cap on one line's length.
pub const LineReader = struct {
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,
    max: usize,

    pub fn init(max: usize) LineReader {
        return .{ .max = max };
    }

    pub fn deinit(self: *LineReader, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn feed(self: *LineReader, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        if (self.start > 0 and self.start == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.start = 0;
        } else if (self.start > 64 * 1024) {
            const rest = self.buf.items[self.start..];
            std.mem.copyForwards(u8, self.buf.items[0..rest.len], rest);
            self.buf.shrinkRetainingCapacity(rest.len);
            self.start = 0;
        }
        try self.buf.appendSlice(gpa, bytes);
    }

    /// The next complete line, valid until the next `feed`. Null when only a
    /// partial line is buffered. A line longer than `max` is an error (the
    /// connection is closed after it).
    pub fn next(self: *LineReader) error{LineTooLong}!?[]const u8 {
        const pending = self.buf.items[self.start..];
        if (std.mem.indexOfScalar(u8, pending, '\n')) |i| {
            if (i > self.max) return error.LineTooLong;
            self.start += i + 1;
            const line = pending[0..i];
            return std.mem.trimEnd(u8, line, "\r");
        }
        if (pending.len > self.max) return error.LineTooLong;
        return null;
    }
};

// ---- Snapshot data shapes (design 6.6), decoded by the views ----

pub const ExecutorConns = struct {
    i: u32 = 0,
    tasks: ?u64 = null,
    run_queue: ?u64 = null,
    connections: ?u64 = null,
    streams: ?StreamCounts = null,
};

pub const StreamCounts = struct { h1: u64 = 0, h2: u64 = 0, h3: u64 = 0, ws: u64 = 0, wt: u64 = 0, grpc: u64 = 0 };

pub const ListenerInfo = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    protocols: []const []const u8 = &.{},
};

pub const ConnsData = struct {
    executors: []const ExecutorConns = &.{},
    listeners: []const ListenerInfo = &.{},
    stack_committed_bytes: ?u64 = null,
};

pub const PoolStat = struct { max: u32 = 0, open: u32 = 0, idle: u32 = 0, in_use: u32 = 0, waiting: u32 = 0 };

pub const DatabaseInfo = struct {
    i: u32 = 0,
    system: []const u8 = "",
    name: []const u8 = "",
    target: []const u8 = "",
    pools: []const PoolStat = &.{},
};

pub const DbData = struct { databases: []const DatabaseInfo = &.{} };

pub const RoomInfo = struct { name: []const u8 = "", members: u64 = 0, queued_bytes: u64 = 0, closed_slow: u64 = 0 };
pub const TopicInfo = struct { name: []const u8 = "", subscribers: u64 = 0 };
pub const WsSockets = struct { h1: u64 = 0, h2: u64 = 0, h3: u64 = 0 };

pub const WsData = struct {
    sockets: WsSockets = .{},
    webtransport: u64 = 0,
    rooms: []const RoomInfo = &.{},
    topics: []const TopicInfo = &.{},
};

pub const H3Data = struct {
    enabled: bool = false,
    endpoints: []const std.json.Value = &.{},
};

pub const LanguageMetric = struct { name: []const u8 = "", value: f64 = 0, unit: []const u8 = "" };

pub const RuntimeData = struct {
    rss_bytes: u64 = 0,
    cpu_ms: u64 = 0,
    threads: u64 = 0,
    fds: u64 = 0,
    fd_limit: u64 = 0,
    uptime_ms: u64 = 0,
    build: []const u8 = "",
    anole: []const u8 = "",
    runtime: []const u8 = "",
    language: []const LanguageMetric = &.{},
};

pub const ConfigData = struct { text: []const u8 = "" };

pub const RouteEntry = struct {
    i: u32 = 0,
    method: []const u8 = "",
    pattern: []const u8 = "",
    no_wait: bool = false,
    cached: bool = false,
    kind: []const u8 = "http",
    middleware: u32 = 0,
};

pub const RoutesData = struct { routes: []const RouteEntry = &.{} };
pub const ErrorsData = struct { entries: []const Error5xx = &.{} };

pub fn decodeData(comptime T: type, arena: std.mem.Allocator, data: ?std.json.Value) !T {
    const v = data orelse return error.InvalidFrame;
    return std.json.parseFromValueLeaky(T, arena, v, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFrame,
    };
}

// ------------------------------------------------------------------ tests

fn roundTrip(arena: std.mem.Allocator, frame: Frame) !Frame {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try encode(frame, &aw.writer);
    const out = aw.written();
    try std.testing.expect(out[out.len - 1] == '\n');
    try std.testing.expect(std.mem.indexOfScalar(u8, out[0 .. out.len - 1], '\n') == null);
    return decode(arena, out[0 .. out.len - 1]);
}

test "protocol: hello round trip" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const features = [_][]const u8{ "h2", "ws" };
    const hello: Hello = .{
        .anole = "0.3.0",
        .app = .{ .name = "api", .pid = 48213, .started = "2026-10-23T09:37:02.004Z", .host = "box", .environment = "development", .deployment = "standalone", .build = "Debug", .executors = 8, .runtime = "zig 0.17.0" },
        .allow = .{ .reload = true, .drain = true, .restart = false, .full_restart = true },
        .why_not = .{ .restart = "no listener hand-off" },
        .supervisor = .{ .kind = "systemd", .detail = "api.service" },
        .features = &features,
    };
    const got = (try roundTrip(a, .{ .hello = hello })).hello;
    try std.testing.expectEqualDeep(hello, got);

    const client: Hello = .{ .client = "anole 0.3.0" };
    try std.testing.expectEqualDeep(client, (try roundTrip(a, .{ .hello = client })).hello);
}

test "protocol: every op and frame encodes and decodes" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const h = [_][2]u32{ .{ 3, 10 }, .{ 20, 2 } };
    const routes = [_]RouteStat{.{ .i = 3, .m = "GET", .p = "/users/:id", .n = 9, .s2 = 8, .s5 = 1, .h = &h }};
    const execs = [_][2]u32{ .{ 5, 12 }, .{ 1, 0 } };
    const frames = [_]Frame{
        .{ .req = .{ .id = 1, .op = "ping" } },
        .{ .req = .{ .id = 2, .op = "snapshot", .what = "conns" } },
        .{ .req = .{ .id = 3, .op = "subscribe", .stream = "logs", .filter = .{ .level = "warn", .route = "/x", .grep = "boom" }, .backlog = 500 } },
        .{ .req = .{ .id = 4, .op = "subscribe", .stream = "stats", .interval_ms = 1000 } },
        .{ .req = .{ .id = 5, .op = "unsubscribe", .sub = 7 } },
        .{ .req = .{ .id = 6, .op = "drain", .confirm = "drain" } },
        .{ .res = .{ .id = 1, .ok = true } },
        .{ .res = .{ .id = 2, .ok = false, .code = code_refused, .message = "read only" } },
        .{ .log = .{ .sub = 1, .time = "2026-10-23T09:41:07.415Z", .level = "warn", .scope = "billing", .request_id = "7f3b", .route = "/charges", .json = false, .text = "retrying \"charge\"\nattempt=2" } },
        .{ .dropped = .{ .sub = 1, .n = 42 } },
        .{ .stats = .{ .sub = 2, .seq = 9, .mono_ms = 123456, .routes = &routes, .db = &.{.{ .i = 0, .n = 4, .e = 1, .h = &h }}, .conns = .{ .total = 37, .executors = &execs }, .err_seq = 3 } },
        .{ .error5xx = .{ .sub = 3, .seq = 1, .time = "t", .status = 502, .method = "GET", .path = "/u/42", .route = "/u/:id", .@"error" = "ConnectionRefused", .request_id = "r", .duration_us = 1500 } },
        .{ .restarting = .{ .mode = "handoff", .successor_pid = 77 } },
        .{ .bye = .{ .reason = "drain" } },
        .{ .err = .{ .code = code_busy, .message = "4 consoles are attached already" } },
    };
    for (frames) |f| {
        const got = try roundTrip(a, f);
        try std.testing.expectEqual(std.meta.activeTag(f), std.meta.activeTag(got));
        try std.testing.expectEqualDeep(f, got);
    }
}

test "protocol: unknown fields ignored, unknown frame and op" {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const f = try decode(a, "{\"t\":\"req\",\"id\":9,\"op\":\"frobnicate\",\"extra\":[1,2,{\"x\":null}]}");
    try std.testing.expectEqualStrings("frobnicate", f.req.op);
    try std.testing.expect(Op.parse(f.req.op) == null);
    try std.testing.expect(Op.parse("full_restart").? == .full_restart);
    try std.testing.expect((try decode(a, "{\"t\":\"zzz\",\"a\":1}")) == .unknown);
    try std.testing.expectError(error.InvalidFrame, decode(a, "[1]"));
    try std.testing.expectError(error.InvalidFrame, decode(a, "{\"id\":1}"));
    try std.testing.expectError(error.InvalidFrame, decode(a, "{\"t\":\"req\",\"id\":\"x\"}"));
    try std.testing.expectError(error.InvalidFrame, decode(a, "not json"));
}

test "protocol: line over the limit rejected" {
    var lr = LineReader.init(16);
    defer lr.deinit(std.testing.allocator);
    try lr.feed(std.testing.allocator, "short\nsecond line is ");
    try std.testing.expectEqualStrings("short", (try lr.next()).?);
    try std.testing.expect((try lr.next()) == null);
    try lr.feed(std.testing.allocator, "way too long for the cap");
    try std.testing.expectError(error.LineTooLong, lr.next());

    var lr2 = LineReader.init(8);
    defer lr2.deinit(std.testing.allocator);
    try lr2.feed(std.testing.allocator, "aaaaaaaaaaaa\n");
    try std.testing.expectError(error.LineTooLong, lr2.next());
}

test "protocol: proto mismatch gives a version error" {
    try std.testing.expect(versionError(.{ .proto = 1 }) == null);
    const e = versionError(.{ .proto = 2 }).?;
    try std.testing.expectEqualStrings("version", e.code);
    try std.testing.expect(std.mem.indexOf(u8, e.message.?, "console protocol 1") != null);
}

fn fuzzDecode(input: []const u8) anyerror!void {
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    const f = decode(a, input) catch return;
    // Whatever decoded can be written again, within the server's cap.
    var aw: std.Io.Writer.Allocating = .init(a);
    try encode(f, &aw.writer);
    try std.testing.expect(aw.written().len <= 8 * input.len + 1024);
}

test "fuzz: console frame decode" {
    const fuzz = @import("fuzz");
    try fuzz.bytes(fuzzDecode, &.{
        "{\"t\":\"hello\",\"proto\":1,\"client\":\"anole\"}",
        "{\"t\":\"req\",\"id\":3,\"op\":\"subscribe\",\"stream\":\"logs\",\"filter\":{\"level\":\"warn\"}}",
        "{\"t\":\"stats\",\"sub\":1,\"seq\":2,\"routes\":[{\"i\":1,\"m\":\"GET\",\"p\":\"/\",\"n\":3,\"h\":[[1,2]]}]}",
        "{\"t\":\"log\",\"text\":\"x\"}",
    });
}
