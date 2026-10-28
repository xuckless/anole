//! Golden-frame and behaviour tests for the console's state machine. The
//! goldens are the characters of a 100x30 screen (golden/*.txt); regenerate
//! them with ANOLE_UPDATE_GOLDEN=1 after an intended change and read the diff.
const std = @import("std");
const protocol = @import("protocol.zig");
const app_mod = @import("app.zig");
const screen = @import("screen.zig");
const keys = @import("keys.zig");
const sys = @import("sys.zig");

const App = app_mod.App;
const gpa = std.testing.allocator;

const cols = 100;
const rows = 30;
const started_ms: i64 = 1792748222004;

fn hello(allow_restart: bool) protocol.Hello {
    return .{
        .anole = "0.3.0",
        .app = .{ .name = "api", .pid = 48213, .started = "2026-10-23T09:37:02.004Z", .host = "box", .environment = "development", .deployment = "standalone", .build = "Debug", .executors = 8, .runtime = "zig 0.17.0" },
        .allow = .{ .reload = true, .drain = true, .restart = allow_restart, .full_restart = true },
        .why_not = .{ .restart = "no listener hand-off: set .process = init.minimal in ServerOptions" },
        .supervisor = .{ .kind = "none" },
    };
}

const Fixture = struct {
    app: App,
    arena: std.heap.ArenaAllocator,
    next_id: u32 = 1,

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.arena.deinit();
    }

    fn json(self: *Fixture, text: []const u8) std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), text, .{}) catch @panic("bad test json");
    }

    /// Delivers the app's queued requests as the server would answer them.
    fn flushOutbox(self: *Fixture) void {
        const out = self.app.takeOutgoing();
        var copy: [32]app_mod.Outgoing = undefined;
        const n = @min(out.len, copy.len);
        @memcpy(copy[0..n], out[0..n]);
        self.app.clearOutgoing();
        for (copy[0..n]) |o| {
            const id = self.next_id;
            self.next_id += 1;
            self.app.registerSent(id, o);
            switch (o) {
                .subscribe_stats => self.app.frame(.{ .res = .{ .id = id, .ok = true, .data = self.json("{\"sub\":2,\"buckets\":98}") } }),
                .subscribe_errors => self.app.frame(.{ .res = .{ .id = id, .ok = true, .data = self.json("{\"sub\":4}") } }),
                .subscribe_logs => self.app.frame(.{ .res = .{ .id = id, .ok = true, .data = self.json("{\"sub\":3}") } }),
                else => {},
            }
        }
    }

    fn snapshot(self: *Fixture, view: protocol.View, text: []const u8) void {
        const id = self.next_id;
        self.next_id += 1;
        self.app.registerSent(id, .{ .snapshot = view });
        self.app.frame(.{ .res = .{ .id = id, .ok = true, .data = self.json(text) } });
    }

    fn type_(self: *Fixture, text: []const u8) void {
        for (text) |c| _ = self.app.key(.{ .char = c });
    }

    fn line(self: *Fixture, text: []const u8) app_mod.Effect {
        self.type_(text);
        return self.app.key(.enter);
    }
};

fn fixture(mode: app_mod.Mode, allow_restart: bool) !*Fixture {
    const f = try gpa.create(Fixture);
    f.* = .{ .app = App.init(gpa, mode, hello(allow_restart)), .arena = .init(gpa) };
    f.app.start();
    f.flushOutbox();
    f.app.tick(100_000, started_ms + 252_000);
    f.app.heard(100_000);
    // Three stats frames, one second apart.
    const h1 = [_][2]u32{ .{ 3, 700 }, .{ 7, 90 }, .{ 12, 10 } };
    const h2 = [_][2]u32{ .{ 3, 1400 }, .{ 7, 190 }, .{ 12, 22 } };
    const ho = [_][2]u32{ .{ 9, 20 }, .{ 20, 2 } };
    const ex = [_][2]u32{ .{ 20, 30 }, .{ 17, 22 } };
    const frames = [_]struct { t: i64, a: u32, b: u32, s5: u32, hist: []const [2]u32 }{
        .{ .t = 0, .a = 0, .b = 0, .s5 = 0, .hist = &.{} },
        .{ .t = 1000, .a = 800, .b = 30, .s5 = 1, .hist = &h1 },
        .{ .t = 2000, .a = 1612, .b = 61, .s5 = 3, .hist = &h2 },
    };
    for (frames, 0..) |fr, i| {
        const routes = try f.arena.allocator().alloc(protocol.RouteStat, 2);
        routes[0] = .{ .i = 1, .m = "GET", .p = "/users/:id", .n = fr.a, .s2 = fr.a - fr.s5, .s4 = 0, .s5 = fr.s5, .h = fr.hist };
        routes[1] = .{ .i = 2, .m = "POST", .p = "/orders", .n = fr.b, .s2 = fr.b, .h = if (i == 0) &.{} else &ho };
        f.app.frame(.{ .stats = .{ .sub = 2, .seq = i, .mono_ms = fr.t, .routes = routes, .conns = .{ .total = 37, .executors = &ex } } });
    }
    // Twenty log records.
    const levels = [_][]const u8{ "info", "info", "warn", "info", "err" };
    const scopes = [_][]const u8{ "access", "access", "billing", "access", "db" };
    for (0..20) |i| {
        const text = try std.fmt.allocPrint(f.arena.allocator(), "line {d}: GET /users/{d} 200 0.{d}ms", .{ i, 40 + i, i % 9 });
        const time = try std.fmt.allocPrint(f.arena.allocator(), "2026-10-23T09:41:07.{d:0>3}Z", .{400 + i * 3});
        f.app.frame(.{ .log = .{ .sub = 3, .time = time, .level = levels[i % 5], .scope = scopes[i % 5], .request_id = if (i % 5 == 4) "" else "7f3a91cc", .text = if (i % 5 == 2) "retrying charge attempt=2" else text } });
    }
    f.app.frame(.{ .error5xx = .{ .sub = 4, .seq = 1, .time = "2026-10-23T09:41:06.100Z", .status = 502, .method = "GET", .path = "/users/42", .route = "/users/:id", .@"error" = "ConnectionRefused", .request_id = "7f3a91cc-1", .duration_us = 31500 } });
    f.app.tick(100_000, started_ms + 252_000);
    return f;
}

fn updating() bool {
    return sys.getenv("ANOLE_UPDATE_GOLDEN") != null;
}

fn expectGolden(comptime name: []const u8, a: *App) !void {
    var scr = try screen.Screen.init(gpa, cols, rows);
    defer scr.deinit(gpa);
    a.draw(&scr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try scr.text(&aw.writer);
    const got = aw.written();
    if (updating()) {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "src/console/ui/golden/" ++ name ++ ".txt", .data = got });
        return;
    }
    try std.testing.expectEqualStrings(@embedFile("golden/" ++ name ++ ".txt"), got);
}

test "app golden: /logs" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    try expectGolden("logs", &f.app);
    // The style view of the same frame.
    var scr = try screen.Screen.init(gpa, cols, rows);
    defer scr.deinit(gpa);
    f.app.draw(&scr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try scr.styles(&aw.writer);
    if (updating()) {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "src/console/ui/golden/logs_styles.txt", .data = aw.written() });
    } else {
        try std.testing.expectEqualStrings(@embedFile("golden/logs_styles.txt"), aw.written());
    }
}

test "app golden: /requests" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/requests");
    try expectGolden("requests", &f.app);
}

test "app golden: /errors" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/errors");
    try expectGolden("errors", &f.app);
}

test "app golden: /conns" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/conns");
    f.snapshot(.conns,
        \\{"executors":[{"i":0,"tasks":120,"run_queue":2,"connections":20,"streams":{"h1":10,"h2":8,"h3":1,"ws":1,"wt":0,"grpc":0}},{"i":1,"tasks":90,"run_queue":0,"connections":17,"streams":{"h1":9,"h2":6,"h3":0,"ws":2,"wt":0,"grpc":0}}],
        \\"listeners":[{"name":"http","url":"http://127.0.0.1:3000","protocols":["h1","h2c"]},{"name":"https","url":"https://0.0.0.0:8443","protocols":["h1","h2","h3"]}],"stack_committed_bytes":9437184}
    );
    try expectGolden("conns", &f.app);
}

test "app golden: /db" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/db");
    f.snapshot(.db,
        \\{"databases":[{"i":0,"system":"postgresql","name":"main","target":"db.internal:5432/app","pools":[{"max":8,"open":6,"idle":3,"in_use":3,"waiting":0},{"max":8,"open":8,"idle":0,"in_use":8,"waiting":2}]}]}
    );
    try expectGolden("db", &f.app);
}

test "app golden: /ws" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/ws");
    f.snapshot(.ws,
        \\{"sockets":{"h1":12,"h2":3,"h3":1},"webtransport":2,"rooms":[{"name":"lobby","members":15,"queued_bytes":2048,"closed_slow":1}],"topics":[{"name":"prices","subscribers":40}]}
    );
    try expectGolden("ws", &f.app);
}

test "app golden: /h3" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/h3");
    // The host's own shape (`index`, then every field of the endpoint's
    // stats); console_test.zig checks the file against the real fields.
    f.snapshot(.h3, std.mem.trimEnd(u8, @embedFile("golden/h3_snapshot.json"), "\n"));
    try expectGolden("h3", &f.app);
}

test "app golden: /h3 scrolled right keeps the first column" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/h3");
    f.snapshot(.h3, std.mem.trimEnd(u8, @embedFile("golden/h3_snapshot.json"), "\n"));
    for (0..3) |_| _ = f.app.key(.right);
    try expectGolden("h3_right", &f.app);
}

fn drawn(a: *App) !void {
    var scr = try screen.Screen.init(gpa, cols, rows);
    defer scr.deinit(gpa);
    a.draw(&scr);
}

test "app: Left after Right past the last column moves back at once" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/h3");
    f.snapshot(.h3, std.mem.trimEnd(u8, @embedFile("golden/h3_snapshot.json"), "\n"));
    for (0..50) |_| _ = f.app.key(.right);
    try drawn(&f.app);
    const most = f.app.hcol;
    // Clamped to what the table needs, so one Left shows one column more.
    try std.testing.expect(most > 0 and most < 50);
    _ = f.app.key(.left);
    try drawn(&f.app);
    try std.testing.expectEqual(most - 1, f.app.hcol);
    // Another view starts at its first column.
    _ = f.line("/runtime");
    try std.testing.expectEqual(@as(usize, 0), f.app.hcol);
}

test "app golden: /h3 off" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/h3");
    f.snapshot(.h3, "{\"enabled\":false,\"endpoints\":[]}");
    try expectGolden("h3_off", &f.app);
}

test "app golden: /runtime" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/runtime");
    f.snapshot(.runtime,
        \\{"rss_bytes":52428800,"cpu_ms":8200,"threads":11,"fds":64,"fd_limit":1048576,"uptime_ms":252000,"build":"Debug","anole":"0.3.0","runtime":"node 22.11.0","language":[{"name":"event_loop_lag_p99","value":0.0031,"unit":"seconds"},{"name":"heap_used","value":31457280,"unit":"bytes"},{"name":"active_handles","value":14,"unit":"count"}]}
    );
    try expectGolden("runtime", &f.app);
}

test "app golden: /config" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/config");
    f.snapshot(.config, "{\"text\":\"environment = development (from Debug build)\\ndeployment = standalone\\nhttp.port = 3000\\ntls.key = [REDACTED]\\ndatabase = postgres://app:[REDACTED]@db:5432/app\"}");
    try expectGolden("config", &f.app);
}

test "app golden: /routes" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/routes");
    f.snapshot(.routes,
        \\{"routes":[{"i":1,"method":"GET","pattern":"/users/:id","no_wait":false,"cached":true,"kind":"http","middleware":3},{"i":2,"method":"POST","pattern":"/orders","no_wait":false,"cached":false,"kind":"http","middleware":3},{"i":3,"method":"GET","pattern":"/ws","no_wait":false,"cached":false,"kind":"ws","middleware":1},{"i":4,"method":"GET","pattern":"/ping","no_wait":true,"cached":false,"kind":"http","middleware":0}]}
    );
    try expectGolden("routes", &f.app);
}

test "app golden: the splash before the first log line, coloured or plain" {
    var app = App.init(gpa, .attach, hello(true));
    defer app.deinit();
    app.start();
    app.clearOutgoing();
    app.tick(100_000, started_ms + 252_000);
    app.heard(100_000);
    try expectGolden("splash", &app);
    // Without colour the O's yellow inside is left out, so the O stays an O.
    var scr = try screen.Screen.init(gpa, cols, rows);
    defer scr.deinit(gpa);
    app.draw(&scr);
    var colored: std.Io.Writer.Allocating = .init(gpa);
    defer colored.deinit();
    try scr.text(&colored.writer);
    app.color = false;
    app.draw(&scr);
    var plain: std.Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    try scr.text(&plain.writer);
    try std.testing.expect(!std.mem.eql(u8, colored.written(), plain.written()));
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "waiting for log lines...") != null);
}

test "app golden: /help and /tasks" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/help");
    try expectGolden("help", &f.app);
    _ = f.line("/tasks");
    try expectGolden("tasks", &f.app);
}

test "app golden: popup for /re" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.type_("/re");
    try expectGolden("popup", &f.app);
}

test "app golden: confirm prompt for /drain" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/drain");
    try expectGolden("confirm_drain", &f.app);
}

test "app golden: not answering" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.app.tick(106_000, started_ms + 258_000);
    try std.testing.expectEqual(app_mod.Link.not_answering, f.app.link());
    try expectGolden("not_answering", &f.app);
}

test "app golden: too small" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    var scr = try screen.Screen.init(gpa, 40, 10);
    defer scr.deinit(gpa);
    f.app.draw(&scr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try scr.text(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "make the window at least 60x12") != null);
}

test "app: completion" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.type_("/re");
    try std.testing.expectEqual(@as(usize, 3), f.app.popupItems().len); // reload, requests, restart
    _ = f.app.key(.tab);
    try std.testing.expectEqualStrings("/reload ", f.app.input.items);
    // Down moves the popup selection.
    f.app.input.clearRetainingCapacity();
    f.type_("/re");
    _ = f.app.key(.down);
    _ = f.app.key(.tab);
    try std.testing.expectEqualStrings("/requests ", f.app.input.items);
    // A space closes the popup.
    try std.testing.expectEqual(@as(usize, 0), f.app.popupItems().len);
}

test "app: history" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    _ = f.line("/conns");
    _ = f.line("/runtime");
    _ = f.app.key(.up);
    try std.testing.expectEqualStrings("/runtime", f.app.input.items);
    _ = f.app.key(.up);
    try std.testing.expectEqualStrings("/conns", f.app.input.items);
    _ = f.app.key(.down);
    try std.testing.expectEqualStrings("/runtime", f.app.input.items);
    _ = f.app.key(.down);
    try std.testing.expectEqualStrings("", f.app.input.items);
}

test "app: confirm n sends nothing, y sends drain with its token" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.app.clearOutgoing();
    _ = f.line("/drain");
    try std.testing.expect(f.app.pending != null);
    _ = f.app.key(.{ .char = 'n' });
    try std.testing.expect(f.app.pending == null);
    try std.testing.expectEqual(@as(usize, 0), f.app.takeOutgoing().len);

    _ = f.line("/drain");
    _ = f.app.key(.{ .char = 'y' });
    const out = f.app.takeOutgoing();
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("drain", out[0].op.name);
    try std.testing.expectEqualStrings("drain", out[0].op.confirm.?);
    f.app.clearOutgoing();

    // /reload needs no confirmation.
    _ = f.line("/reload");
    const out2 = f.app.takeOutgoing();
    try std.testing.expectEqual(@as(usize, 1), out2.len);
    try std.testing.expectEqualStrings("reload", out2[0].op.name);
    try std.testing.expect(out2[0].op.confirm == null);
}

test "app: Esc closes the popup, then clears the input, then goes back in-process" {
    const f = try fixture(.in_process, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.type_("/re");
    try std.testing.expect(f.app.popupItems().len > 0);
    try std.testing.expectEqual(app_mod.Effect.none, f.app.key(.escape));
    try std.testing.expectEqual(@as(usize, 0), f.app.popupItems().len);
    try std.testing.expectEqualStrings("/re", f.app.input.items);
    try std.testing.expectEqual(app_mod.Effect.none, f.app.key(.escape));
    try std.testing.expectEqualStrings("", f.app.input.items);
    try std.testing.expectEqual(app_mod.Effect.back, f.app.key(.escape));
    // Ctrl-C stops the server in-process.
    try std.testing.expectEqual(app_mod.Effect.interrupt, f.app.key(.{ .ctrl = 'c' }));

    // Attached: Esc does nothing, Ctrl-C leaves.
    const g = try fixture(.attach, true);
    defer {
        g.deinit();
        gpa.destroy(g);
    }
    try std.testing.expectEqual(app_mod.Effect.none, g.app.key(.escape));
    try std.testing.expectEqual(app_mod.Effect.quit, g.app.key(.{ .ctrl = 'c' }));
    try std.testing.expectEqual(app_mod.Effect.quit, g.line("/quit"));
}

test "app: /full-restart --kill in-process is refused, restart unavailable explains why" {
    const f = try fixture(.in_process, false);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.app.clearOutgoing();
    _ = f.line("/full-restart --kill");
    try std.testing.expect(f.app.pending == null);
    try std.testing.expect(std.mem.indexOf(u8, f.app.notice.?, "--kill can't be used from the in-process console") != null);
    _ = f.line("/restart");
    try std.testing.expect(std.mem.indexOf(u8, f.app.notice.?, "no listener hand-off") != null);
    try std.testing.expectEqual(@as(usize, 0), f.app.takeOutgoing().len);
    // A plain /full-restart asks, and the answer is the op with its token.
    _ = f.line("/full-restart");
    _ = f.app.key(.{ .char = 'y' });
    const out = f.app.takeOutgoing();
    try std.testing.expectEqualStrings("full_restart", out[0].op.name);
    try std.testing.expectEqualStrings("full-restart", out[0].op.confirm.?);
}

test "app: /logs filters resubscribe and clear" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.app.clearOutgoing();
    _ = f.line("/logs level=warn route=/orders grep=boom");
    const out = f.app.takeOutgoing();
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(u32, 3), out[0].unsubscribe);
    try std.testing.expectEqualStrings("warn", out[1].subscribe_logs.level.?);
    try std.testing.expectEqualStrings("/orders", out[1].subscribe_logs.route.?);
    try std.testing.expectEqualStrings("boom", out[1].subscribe_logs.grep.?);
    try std.testing.expectEqual(@as(usize, 0), f.app.logLines().len);
}

test "app: stale subscription frames are ignored, dropped is counted" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    const before = f.app.logLines().len;
    f.app.frame(.{ .log = .{ .sub = 99, .text = "stale" } });
    try std.testing.expectEqual(before, f.app.logLines().len);
    f.app.frame(.{ .dropped = .{ .sub = 3, .n = 12 } });
    try std.testing.expectEqual(@as(u64, 12), f.app.dropped);
    f.app.frame(.{ .bye = .{ .reason = "drain" } });
    try std.testing.expectEqual(app_mod.Link.exited, f.app.link());
}

test "app: JSON log records show their message and fields" {
    const f = try fixture(.attach, true);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.app.frame(.{ .log = .{ .sub = 3, .time = "2026-10-23T09:41:08.000Z", .level = "info", .json = true, .text = "{\"time\":\"x\",\"level\":\"info\",\"message\":\"charged\",\"amount\":12,\"currency\":\"EUR\"}" } });
    const last = f.app.logLines()[f.app.logLines().len - 1];
    try std.testing.expectEqualStrings("charged amount=12 currency=EUR", last.text);
}
