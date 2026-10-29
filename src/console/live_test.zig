//! The live console end to end (#113): a real app with the console on, real
//! traffic over loopback (requests, a 5xx, a WebSocket in a room, an SSE
//! subscription, SQLite reads), and a client attached over the real
//! control socket as `anole console` attaches (`UnixAddress.connect`, the
//! UI's `Conn`, the same hello). Each panel's data is checked as the client
//! decodes it (`protocol.decodeData`), not as the screen draws it: the pty
//! test (tests/console/pty_test.py) covers the screen.
//!
//! The shape follows tokio-console's console-subscriber tests: the real
//! instrumented runtime, the real client over the real transport, and
//! assertions on the parsed updates, waiting for an update that carries
//! what the test did instead of for a fixed time.
//!
//! The console's client is a plain OS thread with blocking I/O, as the CLI
//! is a process of its own; the app runs on its zio runtime. Every wait in
//! the client is a poll on a socket (or an answer to an ask) bounded by a
//! hang guard of 10 s times ANOLE_TEST_TIMEOUT_FACTOR, never a latency
//! bound (TESTING.md D1, D2, D6).
const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const wait = @import("anole_test_wait");
const ui = @import("anole_console_ui");
const anole = @import("../root.zig");
const server_mod = @import("../server.zig");
const http = @import("../http/root.zig");
const websocket = if (features.websocket) @import("../websocket/root.zig") else struct {};
const sqlite = if (features.sqlite) @import("../sqlite/root.zig") else struct {};

const protocol = ui.protocol;
const sys = ui.sys;
const App = server_mod.App;
const alloc = std.testing.allocator;

// ------------------------------------------------------------- the app

var rooms: if (features.websocket) websocket.Rooms else void = undefined;
var notes_db: if (features.sqlite) *sqlite.Client else void = undefined;

/// GET /notes/:id: a read on SQLite (a reader of the pool).
fn note(req: *http.Request, res: *http.Response) !void {
    const id = req.params.getInt(i64, "id") orelse return error.NotFound;
    const got = try notes_db.one(i64, req, "SELECT ? + 0", .{id});
    try res.json(.{ .id = got });
}

/// GET /boom: an unhandled error, a 500.
fn boom(_: *http.Request, _: *http.Response) !void {
    return error.Boom;
}

/// GET /lobby: joins room "lobby", says so, then reads until the peer goes.
fn lobby(ws: *websocket.Socket, _: *http.Request) !void {
    try rooms.join("lobby", ws);
    try ws.send(.text, "joined");
    while (try ws.next()) |_| {}
}

// ------------------------------------------------------- the hang guard

/// Waits until `fd` is readable or `deadline` (monotonic ms) passes.
fn readable(fd: sys.fd_t, deadline: i64, comptime what: []const u8) !void {
    while (true) {
        const left = deadline - sys.monotonicMs();
        if (left <= 0) {
            std.log.warn("console live test: timed out waiting for: " ++ what, .{});
            return error.TimedOut;
        }
        var p = [1]sys.PollFd{.{ .fd = fd, .events = sys.POLLIN, .revents = 0 }};
        if (sys.poll(&p, @intCast(@min(left, 1000))) > 0) return;
    }
}

// ------------------------------------------------------ loopback client

/// A TCP connection to the app, read with deadlines.
const Peer = struct {
    stream: std.Io.net.Stream,
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn open(port: u16, request: []const u8) !Peer {
        const io = std.testing.io;
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);
        try sys.writeAll(stream.socket.handle, request);
        return .{ .stream = stream };
    }

    fn fd(self: *const Peer) sys.fd_t {
        return self.stream.socket.handle;
    }

    /// Reads until `needle` is in what came, or the peer closed (false).
    fn until(self: *Peer, needle: []const u8, deadline: i64) !bool {
        while (std.mem.find(u8, self.buf[0..self.len], needle) == null) {
            if (self.len == self.buf.len) return error.ResponseTooLong;
            try readable(self.fd(), deadline, "an answer from the app");
            const n = try sys.read(self.fd(), self.buf[self.len..]);
            if (n == 0) return false;
            self.len += n;
        }
        return true;
    }

    /// Reads until the app closes the connection.
    fn untilClosed(self: *Peer, deadline: i64) !void {
        while (true) {
            if (self.len == self.buf.len) return error.ResponseTooLong;
            try readable(self.fd(), deadline, "the app to close the connection");
            const n = try sys.read(self.fd(), self.buf[self.len..]);
            if (n == 0) return;
            self.len += n;
        }
    }

    fn close(self: *Peer) void {
        self.stream.close(std.testing.io);
    }
};

/// One request on a connection of its own; the status line's code.
fn get(port: u16, path: []const u8, request_id: []const u8, deadline: i64) !u16 {
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nX-Request-Id: {s}\r\nConnection: close\r\n\r\n", .{ path, request_id });
    var p = try Peer.open(port, req);
    defer p.close();
    // Connection: close: the whole answer has come once the app closes.
    try p.untilClosed(deadline);
    const head = p.buf[0..p.len];
    if (!std.mem.startsWith(u8, head, "HTTP/1.1 ") or head.len < 12) return error.NotHttp;
    return std.fmt.parseInt(u16, head[9..12], 10);
}

// ------------------------------------------------------- console client

/// The client side: what `anole console` keeps of the frames it got.
const Console = struct {
    conn: ui.client.Conn,
    arena: std.heap.ArenaAllocator,
    deadline: i64,
    last_stats: ?protocol.Stats = null,
    errors: std.ArrayList(protocol.Error5xx) = .empty,
    logs: std.ArrayList(protocol.Log) = .empty,

    fn attach(path: []const u8, deadline: i64) !Console {
        // As tools/anole/console.zig's `connect`.
        const addr = try std.Io.net.UnixAddress.init(path);
        const stream = try addr.connect(std.testing.io);
        const fd: sys.fd_t = @intCast(stream.socket.handle);
        var conn = ui.client.Conn.init(alloc, fd, fd);
        errdefer {
            conn.close();
            conn.deinit();
        }
        try conn.handshake("anole live test", @intCast(@min(deadline - sys.monotonicMs(), std.math.maxInt(i32))), sys.monotonicMs);
        return .{ .conn = conn, .arena = .init(alloc), .deadline = deadline };
    }

    fn deinit(self: *Console) void {
        self.conn.close();
        self.conn.deinit();
        self.arena.deinit();
    }

    fn a(self: *Console) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reads one batch of frames (waiting for the socket), keeping the
    /// streamed ones; returns the answer to `want_id` if it came.
    fn pump(self: *Console, want_id: ?u32) !?protocol.Response {
        var got: ?protocol.Response = null;
        while (try self.conn.nextFrame(self.a())) |f| switch (f) {
            .res => |r| if (want_id != null and r.id == want_id.?) {
                got = r;
            },
            .stats => |s| self.last_stats = s,
            .error5xx => |e| try self.errors.append(self.a(), e),
            .log => |l| try self.logs.append(self.a(), l),
            .bye => return error.ServerSaidBye,
            else => {},
        };
        if (got != null) return got;
        try readable(self.conn.in_fd, self.deadline, "a frame from the console's socket");
        if (!try self.conn.fill()) return error.ConsoleClosed;
        return null;
    }

    /// Sends what is queued and waits for the answer to `id`.
    fn answer(self: *Console, id: u32) !protocol.Response {
        try self.conn.flush();
        while (true) if (try self.pump(id)) |r| return r;
    }

    fn subscribed(self: *Console, id: u32) !void {
        const r = try self.answer(id);
        if (!r.ok) return error.SubscribeRefused;
    }

    /// The snapshot `view`, decoded as `T`; null when the server answered
    /// that it is not available right now (the collector's busy answer).
    fn snapshot(self: *Console, comptime T: type, view: protocol.View) !?T {
        const r = try self.answer(try self.conn.snapshot(view));
        if (!r.ok) {
            if (r.code != null and std.mem.eql(u8, r.code.?, protocol.code_unavailable)) return null;
            std.log.warn("console live test: snapshot {t}: {s} {s}", .{ view, r.code orelse "", r.message orelse "" });
            return error.SnapshotFailed;
        }
        return try protocol.decodeData(T, self.a(), r.data);
    }

    /// Asks `view` until `check` holds (the state is the runtime's, reached
    /// on its own time); the last snapshot. A busy answer is "not yet".
    fn snapshotUntil(self: *Console, comptime T: type, view: protocol.View, comptime what: []const u8, comptime check: fn (T) bool) !T {
        const Ctx = struct {
            c: *Console,
            view: protocol.View,
            last: *?T,
            fn holds(x: @This()) !bool {
                const v = (try x.c.snapshot(T, x.view)) orelse return false;
                x.last.* = v;
                return check(v);
            }
        };
        var last: ?T = null;
        try wait.waitUntil(std.testing.io, what, Ctx{ .c = self, .view = view, .last = &last }, Ctx.holds);
        return last.?;
    }

    /// Reads frames (each batch waited for on the socket) until
    /// `check(self)` holds.
    fn until(self: *Console, comptime what: []const u8, comptime check: fn (*Console) bool) !void {
        const Ctx = struct {
            c: *Console,
            fn holds(x: @This()) !bool {
                if (check(x.c)) return true;
                _ = try x.c.pump(null);
                return check(x.c);
            }
        };
        try wait.waitUntil(std.testing.io, what, Ctx{ .c = self }, Ctx.holds);
    }
};

fn routeStat(st: protocol.Stats, pattern: []const u8) ?protocol.RouteStat {
    for (st.routes) |r| if (std.mem.eql(u8, r.p, pattern)) return r;
    return null;
}

fn bothCounted(c: *Console) bool {
    const st = c.last_stats orelse return false;
    const ok = routeStat(st, "/notes/:id") orelse return false;
    const err = routeStat(st, "/boom") orelse return false;
    return ok.s2 >= 1 and err.s5 >= 1;
}

fn errorStreamed(c: *Console) bool {
    return c.errors.items.len >= 1;
}

fn logOf(c: *Console, rid: []const u8) ?protocol.Log {
    for (c.logs.items) |l| if (std.mem.eql(u8, l.request_id, rid)) return l;
    return null;
}

fn bothLogged(c: *Console) bool {
    return logOf(c, "req-ok-1") != null and logOf(c, "req-err-1") != null;
}

fn room(d: protocol.WsData, name: []const u8) ?protocol.RoomInfo {
    for (d.rooms) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

fn topic(d: protocol.WsData, name: []const u8) ?protocol.TopicInfo {
    for (d.topics) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn wsAllIn(d: protocol.WsData) bool {
    const r = room(d, "lobby") orelse return false;
    const t = topic(d, "news") orelse return false;
    return d.sockets.h1 == 1 and r.members == 1 and t.subscribers == 1;
}

fn connsBoth(d: protocol.ConnsData) bool {
    var n: u64 = 0;
    for (d.executors) |e| n += e.connections orelse 0;
    return n >= 2;
}

fn poolIdle(d: protocol.DbData) bool {
    for (d.databases) |db| if (std.mem.eql(u8, db.system, "sqlite")) {
        var in_use: u32 = 0;
        for (db.pools) |p| in_use += p.in_use;
        return in_use == 0;
    };
    return false;
}

fn routeEntry(d: protocol.RoutesData, pattern: []const u8) ?protocol.RouteEntry {
    for (d.routes) |r| if (std.mem.eql(u8, r.pattern, pattern)) return r;
    return null;
}

/// Everything the attached console checks, on its own thread.
const Check = struct {
    port: u16,
    socket: []const u8,
    db_path: []const u8,
    err: ?anyerror = null,
    /// Set (on the runtime's `Io`) once `run` is over, failed or not.
    done: std.Io.Event = .unset,
    io: std.Io,

    fn main(self: *Check) void {
        self.run() catch |e| {
            self.err = e;
            // Where on this thread it failed: the test returns the error
            // on another.
            if (@errorReturnTrace()) |t| std.debug.dumpErrorReturnTrace(t);
        };
        self.done.set(self.io);
    }

    fn run(self: *Check) !void {
        const deadline = sys.monotonicMs() + wait.deadlineMs();
        var c = try Console.attach(self.socket, deadline);
        defer c.deinit();

        // The hello: the app's name and executors, this process.
        const hello = c.conn.hello.?;
        try std.testing.expectEqualStrings("live", hello.app.?.name);
        try std.testing.expectEqual(@as(u32, 2), hello.app.?.executors);
        try std.testing.expectEqual(sys.getpid(), hello.app.?.pid);

        // As the TUI does for /requests, /errors and /logs.
        try c.subscribed(try c.conn.subscribeStats(250));
        try c.subscribed(try c.conn.subscribeErrors());
        try c.subscribed(try c.conn.subscribeLogs(.{ .scope = "access" }, 0));

        // Traffic: a read on SQLite, a 500, a WebSocket that joins a room,
        // an SSE stream on a topic.
        try std.testing.expectEqual(@as(u16, 200), try get(self.port, "/notes/7", "req-ok-1", deadline));
        try std.testing.expectEqual(@as(u16, 500), try get(self.port, "/boom", "req-err-1", deadline));
        var ws = try Peer.open(self.port, "GET /lobby HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        defer ws.close();
        if (!try ws.until("joined", deadline)) return error.WebSocketClosed;
        try std.testing.expect(std.mem.startsWith(u8, ws.buf[0..ws.len], "HTTP/1.1 101"));
        var ev = try Peer.open(self.port, "GET /live HTTP/1.1\r\nHost: x\r\nAccept: text/event-stream\r\n\r\n");
        defer ev.close();
        if (!try ev.until("\r\n\r\n", deadline)) return error.EventStreamClosed;
        try std.testing.expect(std.mem.startsWith(u8, ev.buf[0..ev.len], "HTTP/1.1 200"));

        // /requests: both requests under their route patterns. Subscribing
        // again replaces the subscription, whose first frame goes out at
        // once with the cumulative sums (no 250 ms interval to wait).
        try c.subscribed(try c.conn.subscribeStats(250));
        try c.until("both requests in a stats frame", bothCounted);
        const st = c.last_stats.?;
        const ok = routeStat(st, "/notes/:id").?;
        try std.testing.expectEqualStrings("GET", ok.m);
        try std.testing.expectEqual(@as(u32, 1), ok.n);
        try std.testing.expectEqual(@as(u32, 1), ok.s2);
        const failed = routeStat(st, "/boom").?;
        try std.testing.expectEqual(@as(u32, 1), failed.n);
        try std.testing.expectEqual(@as(u32, 1), failed.s5);

        // /errors, streamed and as the snapshot.
        try c.until("the 5xx streamed", errorStreamed);
        inline for (.{ c.errors.items[0], (try c.snapshot(protocol.ErrorsData, .errors)).?.entries[0] }) |e| {
            try std.testing.expectEqual(@as(u16, 500), e.status);
            try std.testing.expectEqualStrings("GET", e.method);
            try std.testing.expectEqualStrings("/boom", e.path);
            try std.testing.expectEqualStrings("/boom", e.route);
            try std.testing.expectEqualStrings("Boom", e.@"error");
            try std.testing.expectEqualStrings("req-err-1", e.request_id);
        }

        // /logs: the access lines carry each request's id and route.
        try c.until("both access lines", bothLogged);
        try std.testing.expectEqualStrings("/notes/:id", logOf(&c, "req-ok-1").?.route);
        try std.testing.expectEqualStrings("/boom", logOf(&c, "req-err-1").?.route);
        try std.testing.expectEqualStrings("access", logOf(&c, "req-ok-1").?.scope);

        // /ws: the WebSocket by protocol, its room, the SSE topic.
        const wsd = try c.snapshotUntil(protocol.WsData, .ws, "the WebSocket in lobby and the subscriber of news", wsAllIn);
        try std.testing.expectEqual(@as(u64, 0), wsd.sockets.h2);
        try std.testing.expectEqual(@as(u64, 0), wsd.sockets.h3);
        try std.testing.expectEqual(@as(u64, 0), room(wsd, "lobby").?.closed_slow);

        // /conns: two executors, the two open connections, the listener.
        const cd = try c.snapshotUntil(protocol.ConnsData, .conns, "the two open connections", connsBoth);
        try std.testing.expectEqual(@as(usize, 2), cd.executors.len);
        try std.testing.expectEqual(@as(usize, 1), cd.listeners.len);
        var url_buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}", .{self.port}), cd.listeners[0].url);
        try std.testing.expectEqualStrings("h1", cd.listeners[0].protocols[0]);

        // /db: the SQLite database alone (no other connector is a
        // database), its file, and its pool: the writer and one reader
        // per executor, all open, none in use once the read is over.
        const dd = try c.snapshotUntil(protocol.DbData, .db, "the SQLite pool idle", poolIdle);
        try std.testing.expectEqual(@as(usize, 1), dd.databases.len);
        const db = dd.databases[0];
        try std.testing.expectEqualStrings("sqlite", db.system);
        try std.testing.expectEqualStrings("notes.db", db.name);
        try std.testing.expectEqualStrings(self.db_path, db.target);
        var total: protocol.PoolStat = .{};
        for (db.pools) |p| {
            total.max += p.max;
            total.open += p.open;
            total.idle += p.idle;
        }
        try std.testing.expectEqual(@as(u32, 3), total.max);
        try std.testing.expectEqual(@as(u32, 3), total.open);
        try std.testing.expectEqual(@as(u32, 3), total.idle);

        // /routes: each route with its method and kind; the numbers of
        // /requests are keyed by the same index.
        const rd = (try c.snapshot(protocol.RoutesData, .routes)).?;
        const notes_route = routeEntry(rd, "/notes/:id") orelse return error.NoRoute;
        try std.testing.expectEqualStrings("GET", notes_route.method);
        try std.testing.expectEqualStrings("http", notes_route.kind);
        try std.testing.expectEqual(ok.i, notes_route.i);
        try std.testing.expectEqualStrings("ws", (routeEntry(rd, "/lobby") orelse return error.NoRoute).kind);
        try std.testing.expectEqualStrings("http", (routeEntry(rd, "/live") orelse return error.NoRoute).kind);

        // /config: the resolved options, as set.
        const cfg = (try c.snapshot(protocol.ConfigData, .config)).?;
        try std.testing.expect(std.mem.find(u8, cfg.text, "console.name = \"live\"") != null);
    }
};

test "console live: an attached console gets each panel's data from a real app (requests, 5xx, logs, WebSocket rooms, SSE topics, connections, SQLite pool, routes, config)" {
    if (comptime !features.console or !features.websocket or !features.sqlite) return error.SkipZigTest;
    // The console has no socket on Windows (docs/console.md).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // GET /boom logs its unhandled error.
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const dir = dir_buf[0..dir_len];
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/c.sock", .{dir});
    var db_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_buf, "{s}/notes.db", .{dir});

    // The app's log lines (the access log's among them) go here instead of
    // stderr; the console's tap still gets each one.
    var logs = anole.testing.LogCapture.init(alloc);
    defer logs.deinit();
    logs.start();

    rooms = .init(alloc, .{});
    defer rooms.deinit();
    var app = try App.init(alloc, .{
        .executors = .exact(2),
        .console = .{ .enabled = true, .name = "live", .socket = sock },
    });
    defer app.deinit();
    notes_db = try app.sqlite(db_path);
    app.use(anole.middleware.RequestId.init(.{ .trust_incoming = true }));
    app.use(anole.observe.AccessLog.init(.{ .format = .text }));
    app.get("/notes/:id", note);
    app.get("/boom", boom);
    app.ws("/lobby", lobby);
    const live = try app.sseTopics(.{ .heartbeat = null });
    app.sse("/live", live, .{ .topics = &.{"news"} });

    const Runner = struct {
        fn run(a: *App, check: *Check) !void {
            defer a.stop();
            try a.waitReady();
            check.port = a.addresses()[0].ip.getPort();
            const t = try std.Thread.spawn(.{}, Check.main, .{check});
            defer t.join();
            // The check ends on its own (its waits are bounded), so this
            // wait is not canceled: the thread is joined after it.
            check.done.waitUncancelable(a.io());
        }
    };
    var check: Check = .{ .port = 0, .socket = sock, .db_path = db_path, .io = app.io() };
    var running = try app.io().concurrent(Runner.run, .{ &app, &check });
    defer running.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try running.await(app.io());
    if (check.err) |e| return e;
}
