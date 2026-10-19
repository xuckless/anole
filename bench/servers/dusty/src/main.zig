//! The dusty bench server (bench/SPEC.md): /plaintext and /json for the
//! readiness probe, and the WebSocket routes of the ws scenario. Upstream
//! dusty has no rooms, so /ws/feed keeps its subscribers in a list behind
//! a mutex and the ticker sends each tick to every one, holding the mutex
//! so that no socket leaves mid-send.
const std = @import("std");
const http = @import("dusty");
const zio = @import("zio");

const App = struct {
    gpa: std.mem.Allocator,
    subs_mutex: std.Io.Mutex = .init,
    subs: std.ArrayListUnmanaged(*http.WebSocket) = .empty,
    positions_mutex: std.Io.Mutex = .init,
    positions: std.StringHashMapUnmanaged(i64) = .empty,
};

fn env(name: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(name) orelse return default;
    return std.mem.span(v);
}

fn envInt(comptime T: type, name: [:0]const u8, default: T) T {
    return std.fmt.parseInt(T, env(name, ""), 10) catch default;
}

fn plaintext(_: *App, _: *http.Request, res: *http.Response) !void {
    try res.header("Content-Type", "text/plain");
    res.body = "Hello, World!";
}

fn json(_: *App, _: *http.Request, res: *http.Response) !void {
    try res.json(.{ .message = "Hello, World!" }, .{});
}

fn upgrade(req: *http.Request, res: *http.Response) !?http.WebSocket {
    return try res.upgradeWebSocket(req) orelse {
        res.status = .bad_request;
        res.body = "Expected WebSocket upgrade\n";
        return null;
    };
}

fn wsEcho(_: *App, req: *http.Request, res: *http.Response) !void {
    var ws = (try upgrade(req, res)) orelse return;
    while (true) {
        const msg = ws.receive() catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        switch (msg.type) {
            .text, .binary => try ws.send(msg.type, msg.data),
            .close => return,
            else => {},
        }
    }
}

fn wsFeed(app: *App, req: *http.Request, res: *http.Response) !void {
    var ws = (try upgrade(req, res)) orelse return;
    {
        try app.subs_mutex.lock(req.io);
        defer app.subs_mutex.unlock(req.io);
        try app.subs.append(app.gpa, &ws);
    }
    defer {
        app.subs_mutex.lockUncancelable(req.io);
        defer app.subs_mutex.unlock(req.io);
        for (app.subs.items, 0..) |s, i| if (s == &ws) {
            _ = app.subs.swapRemove(i);
            break;
        };
    }
    while (true) {
        const msg = ws.receive() catch return;
        if (msg.type == .close) return;
    }
}

/// TICK_HZ ticks a second to every /ws/feed socket: a wake every 10 ms on a
/// fixed grid that sends TICK_HZ/100, each stamped as it goes out.
fn ticker(app: *App, io: std.Io, hz: u32) void {
    const per_wake = @max(1, hz / 100);
    var seq: u64 = 0;
    var buf: [128]u8 = undefined;
    var next: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        next = next.addDuration(.{ .raw = .fromMilliseconds(10), .clock = .awake });
        (std.Io.Timeout{ .deadline = next }).sleep(io) catch return;
        app.subs_mutex.lock(io) catch return;
        defer app.subs_mutex.unlock(io);
        if (app.subs.items.len == 0) continue;
        for (0..per_wake) |_| {
            seq += 1;
            const ts = std.Io.Clock.real.now(io).toMicroseconds();
            const msg = std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"ts\":{d},\"sym\":\"BTCUSD\",\"px\":{d},\"qty\":{d}}}", .{
                seq, ts, 100000 + seq % 1000, 1 + seq % 10,
            }) catch unreachable;
            for (app.subs.items) |ws| ws.send(.text, msg) catch {};
        }
    }
}

const Order = struct { id: i64, sym: []const u8, side: []const u8, px: i64, qty: i64, t: i64 };

fn wsTrade(app: *App, req: *http.Request, res: *http.Response) !void {
    var ws = (try upgrade(req, res)) orelse return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => {},
            .close => return,
            else => continue,
        }
        defer _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const o = std.json.parseFromSliceLeaky(Order, a, msg.data, .{ .ignore_unknown_fields = true }) catch {
            try ws.send(.text, "{\"error\":\"bad order\"}");
            continue;
        };
        const delta = if (std.mem.eql(u8, o.side, "sell")) -o.qty else o.qty;
        const pos = blk: {
            try app.positions_mutex.lock(req.io);
            defer app.positions_mutex.unlock(req.io);
            const slot = try app.positions.getOrPut(app.gpa, o.sym);
            if (!slot.found_existing) {
                slot.key_ptr.* = try app.gpa.dupe(u8, o.sym);
                slot.value_ptr.* = 0;
            }
            slot.value_ptr.* += delta;
            break :blk slot.value_ptr.*;
        };
        const reply = try std.json.Stringify.valueAlloc(a, .{
            .id = o.id, .status = "filled", .px = o.px, .qty = o.qty, .pos = pos, .t = o.t,
        }, .{});
        try ws.send(.text, reply);
    }
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, env("MODE", "h1"), "h1")) {
        std.log.err("dusty: MODE={s} is not supported (h1)", .{env("MODE", "")});
        std.process.exit(3);
    }
    const workers = envInt(u8, "WORKERS", 1);
    var rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(workers) });
    defer rt.deinit();
    const io = rt.io();

    var app: App = .{ .gpa = init.gpa };
    const port = envInt(u16, "HTTP_PORT", 8080);
    var server = http.Server(App).init(init.gpa, io, .{
        .listeners = &.{.{ .address = .{ .ip = try std.Io.net.IpAddress.parse("0.0.0.0", port) } }},
        // As in Anole's bench server: no whole-request timeout (WebSockets
        // live for the whole case), the benchmark's 75 s keep-alive, no cap.
        .timeout = .{ .request = null, .keepalive = .fromSeconds(75) },
        .max_connections = null,
    }, &app);
    defer server.deinit();

    server.router.get("/plaintext", plaintext);
    server.router.get("/json", json);
    server.router.get("/ws/echo", wsEcho);
    server.router.get("/ws/feed", wsFeed);
    server.router.get("/ws/trade", wsTrade);

    const hz = envInt(u32, "TICK_HZ", 1000);
    var tick = if (hz > 0) try io.concurrent(ticker, .{ &app, io, hz }) else null;
    defer if (tick) |*t| t.cancel(io);
    try server.run();
}
