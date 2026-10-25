//! Tests of the console's server side: resolution, the service over
//! socketpairs and a real socket file, back-pressure.
const std = @import("std");
const ui = @import("anole_console_ui");
const logging = @import("anole_log");
const modes = @import("../modes.zig");
const root = @import("root.zig");
const service = @import("service.zig");
const stats_mod = @import("stats.zig");
const logring = @import("logring.zig");
const os = @import("os.zig");

const sys = ui.sys;
const protocol = ui.protocol;

// ----------------------------------------------------------- resolution

const FakeVars = struct {
    console: ?[]const u8 = null,
    name: ?[]const u8 = null,

    fn get(ctx: ?*const anyopaque, key: []const u8) ?[]const u8 {
        const self: *const FakeVars = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, key, "ANOLE_CONSOLE")) return self.console;
        if (std.mem.eql(u8, key, "ANOLE_CONSOLE_NAME")) return self.name;
        return null;
    }

    fn vars(self: *const FakeVars) modes.Vars {
        return .{ .ctx = self, .real = get, .any = get };
    }
};

const runtime_build: modes.Build = .{ .mode = .debug, .is_test = false };

test "resolution: enabled off in tests, lambda and with ANOLE_CONSOLE=0; allow_restart by environment" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const none: FakeVars = .{};
    const r1 = try root.resolve(.{}, none.vars(), .development, .standalone, runtime_build, &why);
    try std.testing.expect(r1.enabled);
    try std.testing.expect(r1.allow_restart);
    const r2 = try root.resolve(.{}, none.vars(), .production, .standalone, runtime_build, &why);
    try std.testing.expect(r2.enabled);
    try std.testing.expect(!r2.allow_restart);
    const r3 = try root.resolve(.{}, none.vars(), .development, .standalone, .{ .mode = .debug, .is_test = true }, &why);
    try std.testing.expect(!r3.enabled);
    const r4 = try root.resolve(.{}, none.vars(), .development, .lambda, runtime_build, &why);
    try std.testing.expect(!r4.enabled);
    const off: FakeVars = .{ .console = "0" };
    const r5 = try root.resolve(.{}, off.vars(), .development, .standalone, runtime_build, &why);
    try std.testing.expect(!r5.enabled);
    // An explicit option beats the variable and the test default.
    const r6 = try root.resolve(.{ .enabled = true }, off.vars(), .production, .standalone, .{ .mode = .debug, .is_test = true }, &why);
    try std.testing.expect(r6.enabled);
    const r7 = try root.resolve(.{ .allow_restart = true }, none.vars(), .production, .standalone, runtime_build, &why);
    try std.testing.expect(r7.allow_restart);
    const named: FakeVars = .{ .name = "billing" };
    const r8 = try root.resolve(.{}, named.vars(), .production, .standalone, runtime_build, &why);
    try std.testing.expectEqualStrings("billing", r8.name.?);
    const bad: FakeVars = .{ .console = "x" };
    try std.testing.expectError(error.InvalidEnvironmentVariable, root.resolve(.{}, bad.vars(), .production, .standalone, runtime_build, &why));
    try std.testing.expect(std.mem.find(u8, why.buffered(), "ANOLE_CONSOLE=\"x\": use 1 or 0") != null);
}

// ------------------------------------------------------- service harness

const Fake = struct {
    stopped: std.atomic.Value(bool) = .init(false),
    reloads: std.atomic.Value(u32) = .init(0),

    fn reload(ctx: *anyopaque, _: []u8) service.ReloadResult {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = self.reloads.fetchAdd(1, .monotonic);
        return .{ .ok = 1 };
    }
    fn stop(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.stopped.store(true, .release);
    }
    fn routeMeta(_: *anyopaque, index: u32) ?service.RouteMeta {
        if (index == 1) return .{ .method = "GET", .pattern = "/users/:id" };
        return null;
    }
    fn routes(_: *anyopaque, w: *std.Io.Writer) anyerror!void {
        try w.writeAll("[{\"i\":1,\"method\":\"GET\",\"pattern\":\"/users/:id\",\"no_wait\":false,\"cached\":false,\"kind\":\"http\",\"middleware\":0}]");
    }
};

const Harness = struct {
    gpa: std.mem.Allocator,
    fake: *Fake,
    stats: *stats_mod.Stats,
    logs: *logring.LogRing,
    svc: *service.Service,

    fn init(gpa: std.mem.Allocator, opts: service.Options, allow: protocol.Allow) !Harness {
        const fake = try gpa.create(Fake);
        fake.* = .{};
        const st = try gpa.create(stats_mod.Stats);
        st.* = try stats_mod.Stats.init(gpa, 2, 8, 16);
        const lr = try gpa.create(logring.LogRing);
        lr.* = logring.LogRing.init(gpa, 64 * 1024);
        const info: service.Info = .{
            .anole = "0.3.0",
            .name = "test",
            .started_iso = "2026-10-23T09:37:02.004Z",
            .host = "box",
            .environment = "development",
            .deployment = "standalone",
            .build = "Debug",
            .executors = 2,
            .runtime = "zig 0.17.0",
            .allow = allow,
            .why_not = .{ .restart = "no listener hand-off: set .process = init.minimal in ServerOptions" },
            .supervisor = .{},
            .features = &.{"h2"},
            .started_ms = sys.wallMs(),
        };
        const host: service.Host = .{
            .ctx = fake,
            .executors = 2,
            .reload = Fake.reload,
            .stop = Fake.stop,
            .route_meta = Fake.routeMeta,
            .routes = Fake.routes,
        };
        const svc = try service.Service.init(gpa, host, info, opts, st, lr, null);
        return .{ .gpa = gpa, .fake = fake, .stats = st, .logs = lr, .svc = svc };
    }

    fn deinit(self: *Harness) void {
        self.svc.deinit();
        self.logs.deinit();
        self.gpa.destroy(self.logs);
        self.stats.deinit();
        self.gpa.destroy(self.stats);
        self.gpa.destroy(self.fake);
    }

    /// A connected, hello'd client.
    fn attach(self: *Harness) !ui.client.Conn {
        const pair = try os.socketpair();
        try self.svc.adopt(pair[0], false);
        var c = ui.client.Conn.init(self.gpa, pair[1], pair[1]);
        errdefer c.deinit();
        try c.handshake("test", 10_000, sys.monotonicMs);
        return c;
    }
};

const Wanted = enum { res, log, dropped, stats, error5xx, bye, restarting };

/// Reads frames until one of kind `want` arrives (or ~10 s pass: a failure).
fn waitFor(c: *ui.client.Conn, arena: std.mem.Allocator, want: Wanted) !protocol.Frame {
    const deadline = sys.monotonicMs() + 10_000;
    while (sys.monotonicMs() < deadline) {
        while (try c.nextFrame(arena)) |f| {
            switch (f) {
                .res => if (want == .res) return f,
                .log => if (want == .log) return f,
                .dropped => if (want == .dropped) return f,
                .stats => if (want == .stats) return f,
                .error5xx => if (want == .error5xx) return f,
                .bye => if (want == .bye) return f,
                .restarting => if (want == .restarting) return f,
                else => {},
            }
        }
        var p = [1]sys.PollFd{.{ .fd = c.in_fd, .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&p, 200) > 0) _ = try c.fill();
    }
    return error.TimedOut;
}

const full_allow: protocol.Allow = .{ .reload = true, .drain = true, .restart = false, .full_restart = true };

test "service: hello on attach, ping and the routes snapshot" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    try std.testing.expectEqualStrings("test", c.hello.?.app.?.name);
    try std.testing.expect(c.hello.?.allow.?.drain);
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.ping();
    try c.flush();
    try std.testing.expect((try waitFor(&c, a, .res)).res.ok);
    _ = try c.snapshot(.routes);
    try c.flush();
    const res = (try waitFor(&c, a, .res)).res;
    try std.testing.expect(res.ok);
    const data = try protocol.decodeData(protocol.RoutesData, a, res.data);
    try std.testing.expectEqual(@as(usize, 1), data.routes.len);
    try std.testing.expectEqualStrings("/users/:id", data.routes[0].pattern);
    _ = try c.snapshot(.tasks);
    try c.flush();
    const t = (try waitFor(&c, a, .res)).res;
    try std.testing.expect(!t.ok);
    try std.testing.expectEqualStrings("unavailable", t.code.?);
}

test "service: logs subscription filters, backlog first" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    h.logs.push(.warn, "billing", "r1", "/charges", false, "old warning");
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.subscribeLogs(.{ .level = "warn", .route = "/charges" }, 10);
    try c.flush();
    _ = try waitFor(&c, a, .res);
    const first = (try waitFor(&c, a, .log)).log;
    try std.testing.expectEqualStrings("old warning", first.text);
    try std.testing.expectEqualStrings("r1", first.request_id);
    h.logs.push(.info, "access", "", "/other", false, "filtered out");
    h.logs.push(.err, "billing", "r2", "/charges", false, "new error");
    const next = (try waitFor(&c, a, .log)).log;
    try std.testing.expectEqualStrings("new error", next.text);
}

test "service: a stats subscription carries the requests just counted" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.subscribeStats(250);
    try c.flush();
    _ = try waitFor(&c, a, .res);
    h.stats.count(0, 1, 200, 20_000);
    h.stats.count(1, 1, 503, 40_000);
    // Frames come every 250 ms; wait for one that has both requests.
    var seen = false;
    var tries: u32 = 0;
    while (!seen and tries < 40) : (tries += 1) {
        const f = (try waitFor(&c, a, .stats)).stats;
        for (f.routes) |r| if (r.i == 1 and r.n == 2) {
            seen = true;
            try std.testing.expectEqualStrings("/users/:id", r.p);
            try std.testing.expectEqual(@as(u32, 1), r.s5);
        };
    }
    try std.testing.expect(seen);
}

test "service: 5xx entries stream to a subscriber" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.subscribeErrors();
    try c.flush();
    _ = try waitFor(&c, a, .res);
    var e: stats_mod.ErrorEntry = .{ .status = 502, .time_ms = 1792748467415, .route_index = 1 };
    e.path_len = @intCast("/users/42".len);
    @memcpy(e.path[0..e.path_len], "/users/42");
    h.stats.errors.push(e);
    const f = (try waitFor(&c, a, .error5xx)).error5xx;
    try std.testing.expectEqual(@as(u16, 502), f.status);
    try std.testing.expectEqualStrings("/users/42", f.path);
    try std.testing.expectEqualStrings("/users/:id", f.route);
    try std.testing.expectEqualStrings("2026-10-23T09:41:07.415Z", f.time);
}

test "service: the fifth client is told busy" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    var clients: [4]ui.client.Conn = undefined;
    for (&clients) |*c| c.* = try h.attach();
    defer for (&clients) |*c| {
        c.close();
        c.deinit();
    };
    const pair = try os.socketpair();
    try std.testing.expectError(error.Busy, h.svc.adopt(pair[0], false));
    var c5 = ui.client.Conn.init(std.testing.allocator, pair[1], pair[1]);
    defer {
        c5.close();
        c5.deinit();
    }
    try std.testing.expectError(error.Refused, c5.handshake("test", 5000, sys.monotonicMs));
    try std.testing.expect(std.mem.startsWith(u8, c5.refusal.?, "busy:"));
}

test "service: a newer protocol gets a version error" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    const pair = try os.socketpair();
    try h.svc.adopt(pair[0], false);
    defer sys.close(pair[1]);
    var c = ui.client.Conn.init(std.testing.allocator, pair[1], pair[1]);
    defer c.deinit();
    // Read the server's hello by hand, then answer with proto 2.
    var buf: [4096]u8 = undefined;
    var p = [1]sys.PollFd{.{ .fd = pair[1], .events = sys.POLLIN, .revents = 0 }};
    _ = sys.poll(&p, 5000);
    _ = try sys.read(pair[1], &buf);
    try sys.writeAll(pair[1], "{\"t\":\"hello\",\"proto\":2}\n");
    _ = sys.poll(&p, 5000);
    const n = try sys.read(pair[1], &buf);
    try std.testing.expect(std.mem.find(u8, buf[0..n], "\"code\":\"version\"") != null);
}

test "service: drain needs its token; read_only refuses; restart and full restart are gated" {
    if (!os.supported) return error.SkipZigTest;
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    {
        var h = try Harness.init(std.testing.allocator, .{}, full_allow);
        defer h.deinit();
        var c = try h.attach();
        defer {
            c.close();
            c.deinit();
        }
        _ = try c.op("drain", null);
        try c.flush();
        const no_token = (try waitFor(&c, a, .res)).res;
        try std.testing.expectEqualStrings("confirm_required", no_token.code.?);
        try std.testing.expect(!h.fake.stopped.load(.acquire));

        _ = try c.op("reload", null);
        try c.flush();
        const rel = (try waitFor(&c, a, .res)).res;
        try std.testing.expect(rel.ok);
        try std.testing.expectEqual(@as(u32, 1), h.fake.reloads.load(.monotonic));

        _ = try c.op("restart", "restart");
        try c.flush();
        const rs = (try waitFor(&c, a, .res)).res;
        try std.testing.expect(!rs.ok);
        try std.testing.expect(std.mem.find(u8, rs.message.?, "no listener hand-off: set .process = init.minimal in ServerOptions") != null);

        _ = try c.op("drain", "drain");
        try c.flush();
        const ok = (try waitFor(&c, a, .res)).res;
        try std.testing.expect(ok.ok);
        var tries: u32 = 0;
        while (!h.fake.stopped.load(.acquire) and tries < 200) : (tries += 1) {
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 10);
        }
        try std.testing.expect(h.fake.stopped.load(.acquire));
    }
    {
        var h = try Harness.init(std.testing.allocator, .{ .read_only = true }, .{});
        defer h.deinit();
        var c = try h.attach();
        defer {
            c.close();
            c.deinit();
        }
        for ([_][]const u8{ "reload", "drain", "restart", "full_restart" }) |op| {
            _ = try c.op(op, "drain");
            try c.flush();
            const r = (try waitFor(&c, a, .res)).res;
            try std.testing.expectEqualStrings("refused", r.code.?);
        }
        try std.testing.expectEqual(@as(u32, 0), h.fake.reloads.load(.monotonic));
        try std.testing.expect(!h.fake.stopped.load(.acquire));
    }
    {
        // allow_restart off: full_restart is refused with the reason.
        var h = try Harness.init(std.testing.allocator, .{}, .{ .reload = true, .drain = true });
        defer h.deinit();
        var c = try h.attach();
        defer {
            c.close();
            c.deinit();
        }
        _ = try c.op("full_restart", "full-restart");
        try c.flush();
        const r = (try waitFor(&c, a, .res)).res;
        try std.testing.expectEqualStrings("refused", r.code.?);
    }
}

test "service: stopping sends bye to every client" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    var c = try h.attach();
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    h.svc.bye_reason.store(1, .release);
    h.svc.setStopping();
    const bye = (try waitFor(&c, a, .bye)).bye;
    try std.testing.expectEqualStrings("drain", bye.reason);
    c.close();
    c.deinit();
    h.deinit();
}

test "service: a client that never reads never blocks logging, then sees a dropped count" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.subscribeLogs(.{}, 0);
    try c.flush();
    _ = try waitFor(&c, a, .res);
    // The client stops reading; the producers write 200,000 records. Every
    // call returning is the check.
    var i: usize = 0;
    while (i < 200_000) : (i += 1) h.logs.push(.warn, "load", "", "", false, "a record that is long enough to lap a 4 KiB ring many times over, quickly");
    // Reading again: a dropped frame, then records after it.
    const d = (try waitFor(&c, a, .dropped)).dropped;
    try std.testing.expect(d.n > 0);
    _ = try waitFor(&c, a, .log);
}

test "service: the socket file is 0600 in a 0700 directory and goes away with the service" {
    if (!os.supported) return error.SkipZigTest;
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/anole-ct-{d}", .{sys.getpid()});
    try std.testing.expect(os.ensurePrivateDir(dir, sys.geteuid()) == .created);
    defer os.chmod(dir, 0o700);
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/t.1.sock", .{dir});
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    try h.svc.listen(path);
    const info = os.lstat(path).?;
    try std.testing.expect(info.is_socket);
    try std.testing.expectEqual(@as(u32, 0o600), info.mode);
    try std.testing.expectEqual(@as(u32, 0o700), os.lstat(dir).?.mode);

    // A real client over the socket.
    const fd = try os.connectUnix(path);
    var c = ui.client.Conn.init(std.testing.allocator, fd, fd);
    defer {
        c.close();
        c.deinit();
    }
    try c.handshake("test", 10_000, sys.monotonicMs);
    try std.testing.expectEqual(@as(u32, 1), h.svc.attachedCount());
}

test "service: language metrics show in the runtime snapshot" {
    if (!os.supported) return error.SkipZigTest;
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    try h.svc.setMetrics(&.{.{ .name = "event_loop_lag_p99", .value = 0.002, .unit = "seconds" }});
    var c = try h.attach();
    defer {
        c.close();
        c.deinit();
    }
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    _ = try c.snapshot(.runtime);
    try c.flush();
    const res = (try waitFor(&c, a, .res)).res;
    const data = try protocol.decodeData(protocol.RuntimeData, a, res.data);
    try std.testing.expectEqual(@as(usize, 1), data.language.len);
    try std.testing.expectEqualStrings("event_loop_lag_p99", data.language[0].name);
    try std.testing.expect(data.rss_bytes > 0);
}

// ------------------------------------------------------------- lifetime

test "console: a tap and the request counters taken before stop stay usable until release (the drain still logs and answers)" {
    if (!os.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c.sock", .{dir_buf[0..dir_len]});
    var why_buf: [128]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const none: FakeVars = .{};
    const resolved = try root.resolve(.{ .enabled = true, .socket = path, .log_buffer = 256 * 1024 }, none.vars(), .production, .standalone, runtime_build, &why);
    var fake: Fake = .{};
    const c = try root.Console.start(.{
        .gpa = gpa,
        .io = std.testing.io,
        .resolved = resolved,
        .host = .{ .ctx = &fake, .executors = 2, .reload = Fake.reload, .stop = Fake.stop, .route_meta = Fake.routeMeta, .routes = Fake.routes },
        .executors = 2,
        .environment = "production",
        .deployment = "standalone",
        .features = &.{},
        .has_tls = false,
        .restart_unavailable = null,
        .vars = none.vars(),
        .embedded = true,
    });
    // An executor that loaded the tap before the stop uninstalled it
    // (the drain runs after the console stopped, and logs).
    const tap = &c.logs.?.tap;
    const st = stats_mod.global.?;
    try st.ensureTables();
    tap.func(tap.ud, .warn, "anole", .{}, false, "draining");
    c.stop(false);
    try std.testing.expect(stats_mod.global == null);
    tap.func(tap.ud, .warn, "anole", .{}, false, "Shutdown timed out with 1 request(s) still in flight");
    st.count(0, 0, 504, 1000);
    c.release();
}
