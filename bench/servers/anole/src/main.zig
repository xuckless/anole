//! The Anole side of the cross-framework benchmark: every route in
//! bench/SPEC.md, written the way examples/rest and docs/routing.md do.
//!
//!   zig build -Doptimize=ReleaseFast && MODE=h1 zig-out/bin/anole-bench
const std = @import("std");
const anole = @import("anole");
const websocket = anole.websocket;
const twelve = @import("twelve.zig");
const asyncdb = @import("asyncdb.zig");
const httparena = @import("arena.zig");
const features = @import("features.zig");

pub const zio_options = anole.zio_options;
pub const std_options = anole.std_options;

pub const App = struct {
    gpa: std.mem.Allocator,
    feed: websocket.Rooms,
    retained: []Retained = &.{},
    positions_mutex: std.Io.Mutex = .init,
    positions: std.StringHashMapUnmanaged(i64) = .empty,
    twelve: ?twelve.State = null,
    asyncdb: ?asyncdb.State = null,

    pub fn notFound(_: *App, _: *anole.Request, res: *anole.Response) !void {
        res.status = .not_found;
        try res.json(.{ .@"error" = "not found" });
    }
};

const Mode = enum { h1, h2c, tls, h3 };

fn env(name: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(name) orelse return default;
    return std.mem.span(v);
}

fn envInt(comptime T: type, name: [:0]const u8, default: T) T {
    return std.fmt.parseInt(T, env(name, ""), 10) catch default;
}

// --- raw routes ---------------------------------------------------------

fn plaintext(_: *anole.Request, res: *anole.Response) !void {
    res.content_type = .text;
    res.body = "Hello, World!";
}

fn json(_: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .message = "Hello, World!" });
}

fn user(req: *anole.Request, res: *anole.Response) !void {
    try res.print(.text, "user {s}", .{req.params.get("id") orelse ""});
}

const Item = struct { id: u32, name: []const u8, active: bool, score: u32 };

fn list(req: *anole.Request, res: *anole.Response) !void {
    _ = req;
    var items: [50]Item = undefined;
    for (&items, 1..) |*it, i| it.* = .{
        .id = @intCast(i),
        .name = try std.fmt.allocPrint(res.arena, "item-{d}", .{i}),
        .active = i % 2 == 0,
        .score = @intCast(i * 7),
    };
    try res.json(.{ .items = &items });
}

/// Streams the body back as it arrives (examples/full's /echo).
fn echo(req: *anole.Request, res: *anole.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    res.content_type = .unknown; // application/octet-stream
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

// --- garbage-collection test ---------------------------------------------

const Node = struct { id: u32, name: []const u8, tags: [3][]const u8, active: bool };

/// Builds `n` nodes in the request's arena and serializes them: the
/// allocation-heavy request the GC test measures. The arena is reset after
/// the response, so this is Anole's answer to a collector.
fn gcAlloc(req: *anole.Request, res: *anole.Response) !void {
    const n = req.query.getInt(u32, "n") orelse 2000;
    const a = res.arena;
    const nodes = try a.alloc(Node, n);
    for (nodes, 0..) |*node, i| node.* = .{
        .id = @intCast(i),
        .name = try std.fmt.allocPrint(a, "node-{d}", .{i}),
        .tags = .{
            try std.fmt.allocPrint(a, "a{d}", .{i % 7}),
            try std.fmt.allocPrint(a, "b{d}", .{i % 11}),
            try std.fmt.allocPrint(a, "c{d}", .{i % 13}),
        },
        .active = i % 2 == 0,
    };
    const out = try std.json.Stringify.valueAlloc(a, nodes, .{});
    try res.json(.{ .n = n, .bytes = out.len });
}

const Retained = struct { id: u32, name: []u8, tags: [3][]u8 };

/// RETAIN objects that live as long as the server, each string its own
/// allocation, as the other languages' object graphs are.
fn buildRetained(gpa: std.mem.Allocator, n: u32) ![]Retained {
    const out = try gpa.alloc(Retained, n);
    for (out, 0..) |*r, i| r.* = .{
        .id = @intCast(i),
        .name = try std.fmt.allocPrint(gpa, "retained-{d}", .{i}),
        .tags = .{
            try std.fmt.allocPrint(gpa, "x{d}", .{i % 7}),
            try std.fmt.allocPrint(gpa, "y{d}", .{i % 11}),
            try std.fmt.allocPrint(gpa, "z{d}", .{i % 13}),
        },
    };
    return out;
}

fn gcStats(app: *App, _: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .retained = app.retained.len });
}

// --- WebSockets -----------------------------------------------------------

fn wsEcho(ws: *websocket.Socket, _: *anole.Request) !void {
    while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
}

/// /ws/echo-cb: the echo through WebSocket callbacks (docs/websocket.md),
/// where the library has them; between messages the socket parks without
/// a task.
const EchoCallbacks = struct {
    pub fn message(ws: *websocket.Socket, msg: websocket.Message) !void {
        try ws.send(msg.type, msg.data);
    }
};

fn wsFeed(app: *App, ws: *websocket.Socket, _: *anole.Request) !void {
    try app.feed.join("feed", ws);
    defer app.feed.leave("feed", ws);
    while (try ws.next()) |_| {}
}

/// TICK_HZ ticks a second to every /ws/feed socket: a wake every 10 ms that
/// sends TICK_HZ/100, each stamped as it goes out.
fn ticker(app: *App, io: std.Io, hz: u32) void {
    const per_wake = @max(1, hz / 100);
    var seq: u64 = 0;
    var buf: [128]u8 = undefined;
    // Wakes on a fixed 10 ms grid, so the rate does not drift with the
    // time each round of sends takes.
    var next: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        next = next.addDuration(.{ .raw = .fromMilliseconds(10), .clock = .awake });
        (std.Io.Timeout{ .deadline = next }).sleep(io) catch return;
        if (app.feed.count("feed") == 0) continue;
        for (0..per_wake) |_| {
            seq += 1;
            const ts = std.Io.Clock.real.now(io).toMicroseconds();
            const msg = std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"ts\":{d},\"sym\":\"BTCUSD\",\"px\":{d},\"qty\":{d}}}", .{
                seq, ts, 100000 + seq % 1000, 1 + seq % 10,
            }) catch unreachable;
            _ = app.feed.broadcast("feed", .text, msg, null);
        }
    }
}

const Order = struct { id: i64, sym: []const u8, side: []const u8, px: i64, qty: i64, t: i64 };

fn wsTrade(app: *App, ws: *websocket.Socket, req: *anole.Request) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    while (try ws.next()) |msg| {
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

/// QUIC's idle timeout, 120 s: `idle_timeout` (a Duration) on current Anole,
/// `idle_timeout_ms` before it.
fn http3Options() anole.ServerOptions.Http3 {
    const H3 = anole.ServerOptions.Http3;
    return if (@hasField(H3, "idle_timeout")) .{ .idle_timeout = .fromSeconds(120) } else .{ .idle_timeout_ms = 120_000 };
}

pub fn main(init: std.process.Init) !void {
    const mode = std.meta.stringToEnum(Mode, env("MODE", "h1")) orelse {
        std.log.err("MODE={s} is not supported here (grpc runs the interop server)", .{env("MODE", "")});
        std.process.exit(3);
    };
    const workers = envInt(u16, "WORKERS", 1);
    const http_port = envInt(u16, "HTTP_PORT", 8080);
    const https_port = envInt(u16, "HTTPS_PORT", 8443);
    const cert: anole.Cert = .fromFiles(env("CERT_FILE", "/certs/cert.pem"), env("KEY_FILE", "/certs/key.pem"));

    const ServerOptions = @typeInfo(@TypeOf(anole.Server(App).init)).@"fn".param_types[1].?;
    // Rooms.init takes options from 0.2.0 on; the bench builds against both.
    const rooms_args = @typeInfo(@TypeOf(websocket.Rooms.init)).@"fn".param_types.len;
    var state: App = .{ .gpa = init.gpa, .feed = if (rooms_args == 2) .init(init.gpa, .{}) else .init(init.gpa) };
    defer state.feed.deinit();
    state.retained = try buildRetained(init.gpa, envInt(u32, "RETAIN", 0));

    var opts: ServerOptions = .{
        .executors = .exact(@intCast(workers)),
        .http = switch (mode) {
            .h1, .h2c => .{ .address = "0.0.0.0", .port = http_port },
            else => null,
        },
        .https = switch (mode) {
            .tls, .h3 => .{ .address = "0.0.0.0", .port = https_port, .cert = cert },
            else => null,
        },
        // QUIC's idle timeout to the benchmark's 75 s keep-alive floor.
        .http3 = if (mode == .h3) http3Options() else null,
    };
    // Video streams and sockets outlive the 30 s default; the challenge
    // wants idle keep-alive kept 65 s or more; the connection tests go past
    // the 10 000 default cap. 0.2.0 split `server` into `timeouts` and
    // `limits` (max_connections 0 follows the open-file limit); the bench
    // builds against both.
    if (comptime @hasField(ServerOptions, "timeouts")) {
        opts.timeouts.request = null;
        opts.timeouts.keepalive = .fromSeconds(75);
        opts.limits.body_max = 8 << 20;
        opts.limits.max_connections = 0;
    } else {
        opts.server = .{
            .timeout = .{ .request = null, .keepalive = .fromSeconds(75) },
            .request = .{ .max_body_size = 8 << 20 },
            .max_connections = null,
        };
    }
    const feature_cfg: features.Config = .{
        .tcp_port = envInt(u16, "NET_TCP_PORT", 0),
        .udp_port = envInt(u16, "NET_UDP_PORT", 0),
        .sse = envInt(u8, "SSE", 0) == 1,
        .upstream = env("UPSTREAM", ""),
        .upstream_h2c = envInt(u8, "UPSTREAM_H2C", 0) == 1,
        .metrics = envInt(u8, "METRICS", 0) == 1,
    };
    features.configure(&opts, feature_cfg);
    var app = try anole.Server(App).init(init.gpa, opts, &state);
    defer app.deinit();
    features.registerEarly(&app, feature_cfg);

    // Handlers that never wait (docs/routing.md): on HTTP/2 a request that
    // arrives whole runs where the connection reads it, without a task.
    app.get("/plaintext", anole.noWait(plaintext));
    app.get("/json", anole.noWait(json));
    app.get("/users/:id", anole.noWait(user));
    app.get("/list", anole.noWait(list));
    app.post("/echo", echo);
    app.get("/gc/alloc", gcAlloc);
    app.get("/gc/stats", gcStats);
    // HttpArena's json-comp and static data (arena.zig) replace the media.
    const arena_data = env("ARENA_DATA", "");
    if (arena_data.len > 0) {
        try httparena.routes(&app, init.io, init.arena.allocator(), arena_data);
    } else try app.staticDir("/static", env("MEDIA_DIR", "/media"), .{});
    app.wsWith("/ws/echo", wsEcho, .{ .max_message_size = 1 << 20 });
    app.ws("/ws/feed", wsFeed);
    app.ws("/ws/trade", wsTrade);
    if (comptime @hasDecl(@TypeOf(app), "wsCallbacksWith"))
        app.wsCallbacksWith("/ws/echo-cb", EchoCallbacks, .{ .max_message_size = 1 << 20 });
    if (mode == .h3) app.webtransport("/wt/echo", wtEcho);

    const database_url = env("DATABASE_URL", "");
    if (database_url.len > 0) {
        state.twelve = try twelve.State.init(&app, database_url, envInt(u32, "PG_POOL", 20), env("JWT_SECRET", "twelve-dollar-challenge"));
        twelve.routes(&app);
    }
    // HttpArena's async-db profile, on its seeded items table.
    const arena_url = env("ARENA_DATABASE_URL", "");
    if (arena_url.len > 0) {
        state.asyncdb = try asyncdb.State.init(&app, arena_url, envInt(u32, "PG_POOL", 20));
        asyncdb.routes(&app);
    }

    try features.register(&app, feature_cfg);

    const hz = envInt(u32, "TICK_HZ", 1000);
    var tick = if (hz > 0) try app.io().concurrent(ticker, .{ &state, app.io(), hz }) else null;
    defer if (tick) |*t| t.cancel(app.io());

    try app.run();
}

const wt = anole.webtransport;

/// /wt/echo (SPEC.md): every bidirectional stream back on itself, every
/// datagram back unchanged.
fn wtEcho(session: *wt.Session, req: *anole.Request) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(req.io);
    try group.concurrent(req.io, wtStreams, .{ session, req.io });
    try group.concurrent(req.io, wtDatagrams, .{session});
    group.await(req.io) catch {};
}

fn wtStreams(session: *wt.Session, io: std.Io) std.Io.Cancelable!void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = session.acceptStream() catch return;
        group.concurrent(io, wtStream, .{stream}) catch stream.release();
    }
}

fn wtStream(stream: *wt.Stream) std.Io.Cancelable!void {
    defer stream.release();
    _ = stream.reader().streamRemaining(stream.writer()) catch return;
    stream.closeSend() catch {};
}

fn wtDatagrams(session: *wt.Session) std.Io.Cancelable!void {
    var buf: [2048]u8 = undefined;
    while (true) {
        const d = session.receiveDatagram(&buf) catch return;
        session.sendDatagram(d) catch return;
    }
}
