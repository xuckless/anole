//! Tests of the console's server side: resolution, the service over
//! socketpairs and a real socket file, back-pressure.
const std = @import("std");
const wait = @import("anole_test_wait");
const ui = @import("anole_console_ui");
const logging = @import("anole_log");
const modes = @import("../modes.zig");
const root = @import("root.zig");
const service = @import("service.zig");
const stats_mod = @import("stats.zig");
const logring = @import("logring.zig");
const os = @import("os.zig");
const safety = @import("anole_safety");

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
    // Windows: the console is not available yet (docs/console.md), so it
    // resolves to disabled even where it would otherwise be on; the rest of
    // the table holds on every platform.
    const on_here = @import("builtin").os.tag != .windows;
    var buf: [128]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const none: FakeVars = .{};
    const r1 = try root.resolve(.{}, none.vars(), .development, .standalone, runtime_build, &why);
    try std.testing.expectEqual(on_here, r1.enabled);
    try std.testing.expect(r1.allow_restart);
    const r2 = try root.resolve(.{}, none.vars(), .production, .standalone, runtime_build, &why);
    try std.testing.expectEqual(on_here, r2.enabled);
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
    try std.testing.expectEqual(on_here, r6.enabled);
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
    /// What the service, its rings and its stats allocate with: a call
    /// while a spin lock is held panics (SAFETY.md L5).
    checked: *safety.SpinCheckedAllocator,
    fake: *Fake,
    stats: *stats_mod.Stats,
    logs: *logring.LogRing,
    svc: *service.Service,

    fn init(gpa: std.mem.Allocator, opts: service.Options, allow: protocol.Allow) !Harness {
        const checked = try gpa.create(safety.SpinCheckedAllocator);
        checked.* = .init(gpa);
        const sa = checked.allocator();
        const fake = try gpa.create(Fake);
        fake.* = .{};
        const st = try gpa.create(stats_mod.Stats);
        st.* = try stats_mod.Stats.init(sa, 2, 8, 16);
        const lr = try gpa.create(logring.LogRing);
        lr.* = logring.LogRing.init(sa, 64 * 1024);
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
        const svc = try service.Service.init(sa, host, info, opts, st, lr, null);
        return .{ .gpa = gpa, .checked = checked, .fake = fake, .stats = st, .logs = lr, .svc = svc };
    }

    fn deinit(self: *Harness) void {
        self.svc.deinit();
        self.logs.deinit();
        self.gpa.destroy(self.logs);
        self.stats.deinit();
        self.gpa.destroy(self.stats);
        self.gpa.destroy(self.fake);
        self.gpa.destroy(self.checked);
    }

    /// A connected, hello'd client.
    fn attach(self: *Harness) !ui.client.Conn {
        const pair = try os.socketpair();
        try self.svc.adopt(pair[0], false);
        var c = ui.client.Conn.init(self.gpa, pair[1], pair[1]);
        errdefer c.deinit();
        try c.handshake("test", @intCast(wait.deadlineMs()), sys.monotonicMs);
        return c;
    }
};

const Wanted = enum { res, log, dropped, stats, error5xx, bye, restarting };

/// Reads frames until one of kind `want` arrives (or the wait helper's
/// deadline passes: a failure).
fn waitFor(c: *ui.client.Conn, arena: std.mem.Allocator, want: Wanted) !protocol.Frame {
    const deadline = sys.monotonicMs() + wait.deadlineMs();
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

test "service: hello on attach; ping and /routes are answered, /tasks is unavailable" {
    // Windows: the console is not available yet (docs/console.md).
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

test "service: a stats subscription carries the requests counted so far" {
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
    // Count before subscribing: the subscription's first frame goes out at
    // once and carries the cumulative sums, so no interval passes.
    try h.stats.ensureTables();
    h.stats.count(0, 1, 200, 20_000);
    h.stats.count(1, 1, 503, 40_000);
    _ = try c.subscribeStats(250);
    try c.flush();
    _ = try waitFor(&c, a, .res);
    const f = (try waitFor(&c, a, .stats)).stats;
    var seen = false;
    for (f.routes) |r| if (r.i == 1) {
        seen = true;
        try std.testing.expectEqual(@as(u32, 2), r.n);
        try std.testing.expectEqualStrings("/users/:id", r.p);
        try std.testing.expectEqual(@as(u32, 1), r.s5);
    };
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
    // Read the server's hello by hand, then answer with proto 2.
    var buf: [4096]u8 = undefined;
    _ = try readLineRaw(pair[1], &buf);
    try sys.writeAll(pair[1], "{\"t\":\"hello\",\"proto\":2}\n");
    const line = try readLineRaw(pair[1], &buf);
    try std.testing.expect(std.mem.find(u8, line, "\"code\":\"version\"") != null);
}

/// Reads one whole line from `fd` by hand (the server says nothing more until
/// answered); fails when none arrives within the wait helper's deadline.
fn readLineRaw(fd: sys.fd_t, buf: []u8) ![]const u8 {
    var len: usize = 0;
    const deadline = sys.monotonicMs() + wait.deadlineMs();
    while (std.mem.indexOfScalar(u8, buf[0..len], '\n') == null) {
        const now = sys.monotonicMs();
        if (now >= deadline) return error.TimedOut;
        if (len == buf.len) return error.LineTooLong;
        var p = [1]sys.PollFd{.{ .fd = fd, .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&p, @intCast(deadline - now)) == 0) continue;
        const n = try sys.read(fd, buf[len..]);
        if (n == 0) return error.EndOfStream;
        len += n;
    }
    return buf[0..len];
}

test "service: drain without its token is refused, with it the server stops; reload runs; restart without hand-off explains why" {
    if (!os.supported) return error.SkipZigTest;
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
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
    try wait.waitFlag(std.testing.io, "the drain stopped the server", &h.fake.stopped);
}

test "service: read_only refuses reload, drain, restart and full_restart" {
    if (!os.supported) return error.SkipZigTest;
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
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

test "service: full_restart is refused when restarts are not allowed" {
    if (!os.supported) return error.SkipZigTest;
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
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

test "service: stopping sends bye to every client" {
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
    h.svc.bye_reason.store(1, .release);
    h.svc.setStopping();
    const bye = (try waitFor(&c, a, .bye)).bye;
    try std.testing.expectEqualStrings("drain", bye.reason);
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
    // A short /tmp path: sun_path holds at most 104 bytes on macOS.
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/anole-ct-{d}", .{sys.getpid()}, 0);
    try std.testing.expect(os.ensurePrivateDir(dir, sys.geteuid()) == .created);
    defer _ = std.c.rmdir(dir.ptr);
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/t.1.sock", .{dir});
    var h = try Harness.init(std.testing.allocator, .{}, full_allow);
    defer h.deinit();
    try h.svc.listen(path);
    const info = os.lstat(path).?;
    try std.testing.expect(info.is_socket);
    try std.testing.expectEqual(@as(u32, 0o600), info.mode);
    try std.testing.expectEqual(@as(u32, 0o700), os.lstat(dir).?.mode);

    {
        // A real client over the socket.
        const fd = try os.connectUnix(path);
        var c = ui.client.Conn.init(std.testing.allocator, fd, fd);
        defer {
            c.close();
            c.deinit();
        }
        try c.handshake("test", @intCast(wait.deadlineMs()), sys.monotonicMs);
        try std.testing.expectEqual(@as(u32, 1), h.svc.attachedCount());
    }

    // Stopping the service removes the socket file.
    h.svc.stop();
    try std.testing.expect(os.lstat(path) == null);
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
    tap.func(tap.ud, .warn, "anole", .{}, false, "Shutdown timed out with 1 request(s) or connection(s) still in flight");
    st.count(0, 0, 504, 1000);
    c.release();
}

// ----------------------------------------------------------- fixtures

test "console: the /h3 fixture of the UI's golden test has the fields the host sends" {
    const features = @import("build_options");
    if (comptime !features.http3) return error.SkipZigTest; // no /h3 without HTTP/3
    const Stats = @import("../h3/server.zig").Stats;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, @embedFile("ui/golden/h3_snapshot.json"), .{});
    defer parsed.deinit();
    const endpoints = parsed.value.object.get("endpoints").?.array.items;
    try std.testing.expect(endpoints.len > 0);
    // As `host.zig` writes it: `index`, then the stats' fields in order.
    const names = comptime std.meta.fieldNames(Stats);
    for (endpoints) |ep| {
        const keys = ep.object.keys();
        try std.testing.expectEqual(names.len + 1, keys.len);
        try std.testing.expectEqualStrings("index", keys[0]);
        for (names, keys[1..]) |name, key| try std.testing.expectEqualStrings(name, key);
    }
}
