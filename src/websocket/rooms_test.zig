//! Rooms over real sockets: two HTTP/1.1 clients in one room, one message
//! reaching both.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const websocket = @import("root.zig");
const wait = @import("anole_test_wait");

var rooms: websocket.Rooms = undefined;

fn chat(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try rooms.join("lobby", &ws);
    defer rooms.leave("lobby", &ws);
    try ws.send(.text, "joined");
    while (true) {
        const msg = ws.receive() catch return;
        switch (msg.type) {
            .text, .binary => _ = rooms.broadcast("lobby", msg.type, msg.data, null),
            .close => return,
            else => {},
        }
    }
}

test "Rooms: a message to the room reaches every member" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    rooms = .init(gpa, .{});
    defer rooms.deinit();

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/chat", chat);
    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.waitReady(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/chat", .{server.address.ip.getPort()});
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var a = try client.connectWebSocket(url, .{});
    defer a.deinit();
    try std.testing.expectEqualStrings("joined", (try a.receive()).data);
    var b = try client.connectWebSocket(url, .{});
    defer b.deinit();
    try std.testing.expectEqualStrings("joined", (try b.receive()).data);
    try std.testing.expectEqual(@as(usize, 2), rooms.count("lobby"));

    try a.send(.text, "hello, room");
    try std.testing.expectEqualStrings("hello, room", (try b.receive()).data);
    try std.testing.expectEqualStrings("hello, room", (try a.receive()).data);

    try a.close(.normal, "");
    _ = try a.receive(); // the close echo
    // b alone now: the room keeps working.
    try b.send(.text, "still here");
    try std.testing.expectEqualStrings("still here", (try b.receive()).data);
    try b.close(.normal, "");
}

/// A socket whose sends block until `release` is set: a member whose
/// client has stopped reading.
const Stalled = struct {
    interface: std.Io.Writer,
    io: std.Io,
    release: std.Io.Event = .unset,
    /// A send has reached the transport.
    entered: std.Io.Event = .unset,
    /// A send that is canceled while it waits fails, as a socket's write
    /// does; otherwise it waits for `release` regardless.
    cancelable: bool = false,
    /// Bytes that went through.
    written: std.atomic.Value(usize) = .init(0),
    reader: std.Io.Reader = .fixed(""),
    ws: dusty.WebSocket = undefined,
    socket: websocket.Socket = undefined,

    fn init(self: *Stalled, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} }, .io = io };
        self.ws = dusty.WebSocket.init(io, .{ .writer = &self.interface, .reader = &self.reader }, gpa, 0);
        self.socket = .{ ._conn = .{ .h1 = &self.ws }, ._allocator = gpa, .io = io, .max_message_size = 1024 };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Stalled = @alignCast(@fieldParentPtr("interface", w));
        self.entered.set(self.io);
        if (self.cancelable) {
            self.release.wait(self.io) catch return error.WriteFailed;
        } else self.release.waitUncancelable(self.io);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| n += bytes.len;
        n += data[data.len - 1].len * splat;
        _ = self.written.fetchAdd(n, .monotonic);
        return n;
    }
};

test "Rooms: a stalled member holds up neither other rooms nor joins, and leaves once its send ends" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{});
    defer r.deinit();

    var stalled: Stalled = undefined;
    stalled.init(gpa, io);
    defer stalled.ws.deinit();
    var other: Stalled = undefined;
    other.init(gpa, io);
    defer other.ws.deinit();
    other.release.set(io); // never stalls

    // Made without an Io: before the first join, every room is empty.
    try std.testing.expectEqual(@as(usize, 0), r.broadcast("slow", .text, "nobody here", null));
    try std.testing.expectEqual(@as(usize, 0), r.count("slow"));

    try r.join("slow", &stalled.socket);
    try r.join("fast", &other.socket);

    // A broadcast stuck sending to the stalled member.
    var stuck = try io.concurrent(struct {
        fn run(rooms_: *websocket.Rooms) usize {
            return rooms_.broadcast("slow", .text, "hello", null);
        }
    }.run, .{&r});
    try stalled.entered.wait(io);

    // Another room, and joins and counts, go on meanwhile.
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("fast", .text, "hi", null));
    try r.join("slow", &other.socket);
    try std.testing.expectEqual(@as(usize, 2), r.count("slow"));
    r.leave("slow", &other.socket);

    // Leaving waits for the send under way to the leaver.
    var left: std.atomic.Value(bool) = .init(false);
    var leaving = try io.concurrent(struct {
        fn run(rooms_: *websocket.Rooms, s: *websocket.Socket, done: *std.atomic.Value(bool)) void {
            rooms_.leave("slow", s);
            done.store(true, .release);
        }
    }.run, .{ &r, &stalled.socket, &left });
    try wait.waitUntil(io, "the leaver is out of the room's list", &r, struct {
        fn f(rooms_: *websocket.Rooms) bool {
            return rooms_.count("slow") == 0;
        }
    }.f);
    try wait.expectStays(io, "leave waits for the send under way", &left, notSet, wait.short_window);
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("fast", .text, "still", null));

    stalled.release.set(io);
    leaving.await(io);
    try std.testing.expect(left.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), stuck.await(io));
    try std.testing.expectEqual(@as(usize, 0), r.broadcast("slow", .text, "gone", null));
    r.leave("fast", &other.socket);
}

test "Rooms: joining twice is one membership, and one leave ends it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{});
    defer r.deinit();

    var a: Stalled = undefined;
    a.init(gpa, io);
    a.release.set(io);
    try r.join("lobby", &a.socket);
    try r.join("lobby", &a.socket);
    try std.testing.expectEqual(@as(usize, 1), r.count("lobby"));
    r.leave("lobby", &a.socket);
    try std.testing.expectEqual(@as(usize, 0), r.count("lobby"));
    a.ws.deinit();
    // Nothing of the socket is left in the room.
    try std.testing.expectEqual(@as(usize, 0), r.broadcast("lobby", .text, "anyone?", null));
}

fn notSet(flag: *const std.atomic.Value(bool)) bool {
    return !flag.load(.acquire);
}

test "Rooms: a broadcast does not wait for a member that stopped reading, and a full member is closed" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{ .max_queued_bytes = 1024, .close_after_ms = 50 });
    defer r.deinit();

    var stalled: Stalled = undefined;
    stalled.init(gpa, io);
    stalled.cancelable = true;
    defer stalled.ws.deinit();
    // However the test ends, nothing stays stuck.
    defer stalled.release.set(io);
    var other: Stalled = undefined;
    other.init(gpa, io);
    other.release.set(io);
    defer other.ws.deinit();
    try r.join("room", &stalled.socket);
    try r.join("room", &other.socket);

    // The first broadcast's send to the stalled member never ends; the
    // broadcast returns all the same, and the other member gets it.
    var done: std.atomic.Value(bool) = .init(false);
    var first = try io.concurrent(struct {
        fn run(rooms_: *websocket.Rooms, d: *std.atomic.Value(bool)) usize {
            defer d.store(true, .release);
            return rooms_.broadcast("room", .text, "one", null);
        }
    }.run, .{ &r, &done });
    try wait.waitFlag(io, "the first broadcast returned", &done);
    try std.testing.expectEqual(@as(usize, 2), first.await(io));
    try stalled.entered.wait(io);

    // What follows queues up for the stalled member until it is full; then
    // messages are skipped for it, and once its send has been stuck for
    // `close_after_ms` it is closed and gets nothing more.
    const msg: [200]u8 = @splat('m');
    var reached_all: usize = 0;
    for (0..20) |_| {
        reached_all += r.broadcast("room", .binary, &msg, null);
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(reached_all < 40);
    // Time passing on purpose: past `close_after_ms` (a sleep never ends
    // early, so a slow machine only makes it longer).
    try io.sleep(.fromMilliseconds(60), .awake);
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("room", .binary, &msg, null));
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("room", .binary, &msg, null));
    // Its send was canceled: its sending side is over.
    try wait.waitUntil(io, "the stalled member's sending side closed", &stalled, struct {
        fn f(st: *Stalled) bool {
            return st.ws.closed;
        }
    }.f);

    r.leave("room", &stalled.socket);
    r.leave("room", &other.socket);
    // The other member got every message, in order of sending.
    try std.testing.expect(other.written.load(.acquire) > 20 * msg.len);
}

test "Rooms: with on_full = drop, a full member skips messages and stays" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{ .max_queued_bytes = 600, .on_full = .drop });
    defer r.deinit();

    var slow: Stalled = undefined;
    slow.init(gpa, io);
    defer slow.ws.deinit();
    try r.join("room", &slow.socket);
    const msg: [200]u8 = @splat('m');
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("room", .binary, &msg, null));
    try slow.entered.wait(io);
    // Two more fit behind the one under way; the rest are skipped.
    var reached: usize = 0;
    for (0..5) |_| reached += r.broadcast("room", .binary, &msg, null);
    try std.testing.expectEqual(@as(usize, 2), reached);
    slow.release.set(io);
    // Room again once the queue drains.
    try wait.waitAtLeast(io, "the three queued messages written", &slow.written, 3 * msg.len);
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("room", .binary, &msg, null));
    r.leave("room", &slow.socket);
}

test "Rooms: a socket released without leave is out of every room, so no broadcast reaches it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{});
    defer r.deinit();
    var other_rooms: websocket.Rooms = .init(gpa, .{});
    defer other_rooms.deinit();

    // On the heap, as a request's arena or a callback socket holds it: once
    // it is freed, a broadcast that still finds it writes into freed memory.
    const gone = try gpa.create(Stalled);
    gone.init(gpa, io);
    gone.release.set(io);
    var stays: Stalled = undefined;
    stays.init(gpa, io);
    stays.release.set(io);
    defer stays.ws.deinit();

    try r.join("lobby", &gone.socket);
    try r.join("news", &gone.socket);
    try other_rooms.join("lobby", &gone.socket);
    try r.join("lobby", &stays.socket);
    try std.testing.expectEqual(@as(usize, 2), r.count("lobby"));

    // Released with no `leave`: an early return before the `defer`, a
    // `close` callback that forgot a room.
    gone.socket.deinit();
    gpa.destroy(gone);

    try std.testing.expectEqual(@as(usize, 1), r.count("lobby"));
    try std.testing.expectEqual(@as(usize, 0), r.count("news"));
    try std.testing.expectEqual(@as(usize, 0), other_rooms.count("lobby"));
    try std.testing.expectEqual(@as(usize, 1), r.broadcast("lobby", .text, "anyone?", null));
    try std.testing.expectEqual(@as(usize, 0), r.broadcast("news", .text, "anyone?", null));
    r.leave("lobby", &stays.socket);
}

var auto_rooms: websocket.Rooms = undefined;

/// Joins the lobby and never leaves it: the socket's end has to.
fn joinOnly(req: *dusty.Request, res: *dusty.Response) !void {
    var ws = (try websocket.upgrade(req, res, .{})) orelse {
        res.status = .bad_request;
        return;
    };
    defer ws.deinit();
    try auto_rooms.join("lobby", &ws);
    try ws.send(.text, "joined");
    while (try ws.next()) |_| {}
}

/// Waits until the lobby of `auto_rooms` has `want` members.
fn lobbyCountBecomes(io: std.Io, comptime want: usize) !void {
    try wait.waitUntil(io, std.fmt.comptimePrint("the lobby has {d} member(s)", .{want}), {}, struct {
        fn f(_: void) bool {
            return auto_rooms.count("lobby") == want;
        }
    }.f);
}

const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

fn startServer(gpa: std.mem.Allocator, io: std.Io, server: *dusty.Server(void)) !std.Io.Future(anyerror!void) {
    server.* = dusty.Server(void).init(gpa, io, .{ .listeners = loopback }, {});
    server.router.get("/lobby", joinOnly);
    const future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    try server.waitReady(io);
    return future;
}

test "Rooms: a socket whose handler ends without leave leaves its rooms" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    auto_rooms = .init(gpa, .{});
    defer auto_rooms.deinit();

    var server: dusty.Server(void) = undefined;
    var server_future = try startServer(gpa, io, &server);
    defer server.deinit();
    defer server_future.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/lobby", .{server.address.ip.getPort()});
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var a = try client.connectWebSocket(url, .{});
    defer a.deinit();
    try std.testing.expectEqualStrings("joined", (try a.receive()).data);
    var b = try client.connectWebSocket(url, .{});
    defer b.deinit();
    try std.testing.expectEqualStrings("joined", (try b.receive()).data);
    try std.testing.expectEqual(@as(usize, 2), auto_rooms.count("lobby"));

    // a goes; its handler returns and its socket, in the request's arena,
    // is gone with it.
    try a.close(.normal, "");
    _ = try a.receive(); // the close echo
    try lobbyCountBecomes(io, 1);
    try std.testing.expectEqual(@as(usize, 1), auto_rooms.broadcast("lobby", .text, "to b", null));
    try std.testing.expectEqualStrings("to b", (try b.receive()).data);
    try b.close(.normal, "");
    _ = try b.receive();
    try lobbyCountBecomes(io, 0);
}

test "Rooms: a member closed for not keeping up is shut down, so its handler ends and it leaves" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    auto_rooms = .init(gpa, .{ .max_queued_bytes = 256 * 1024, .close_after_ms = 50 });
    defer auto_rooms.deinit();

    var server: dusty.Server(void) = undefined;
    var server_future = try startServer(gpa, io, &server);
    defer server.deinit();
    defer server_future.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/lobby", .{server.address.ip.getPort()});
    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    // A client that stops reading after the greeting.
    var slow = try client.connectWebSocket(url, .{});
    defer slow.deinit();
    try std.testing.expectEqualStrings("joined", (try slow.receive()).data);
    try std.testing.expectEqual(@as(usize, 1), auto_rooms.count("lobby"));

    // Broadcast until the kernel's buffers are full, the member's queue
    // fills, and its send has been stuck long enough to close it: then its
    // connection ends, its handler returns, and the room is empty.
    const msg = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(msg);
    @memset(msg, 'm');
    // Each poll broadcasts once more, until the member is gone.
    try wait.waitUntil(io, "the member that stopped reading left the lobby", msg, struct {
        fn f(m: []const u8) bool {
            _ = auto_rooms.broadcast("lobby", .binary, m, null);
            return auto_rooms.count("lobby") == 0;
        }
    }.f);
}

/// A member whose socket counts the writes that reach it.
const Counting = struct {
    interface: std.Io.Writer,
    buf: [4096]u8 = undefined,
    writes: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(usize) = .init(0),
    reader: std.Io.Reader = .fixed(""),
    ws: dusty.WebSocket = undefined,
    socket: websocket.Socket = undefined,

    fn init(self: *Counting, gpa: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
        self.interface.buffer = &self.buf;
        self.ws = dusty.WebSocket.init(io, .{ .writer = &self.interface, .reader = &self.reader }, gpa, 0);
        self.socket = .{ ._conn = .{ .h1 = &self.ws }, ._allocator = gpa, .io = io, .max_message_size = 1024 };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counting = @alignCast(@fieldParentPtr("interface", w));
        _ = self.writes.fetchAdd(1, .monotonic);
        var n: usize = w.end;
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| consumed += bytes.len;
        consumed += data[data.len - 1].len * splat;
        n += consumed;
        _ = self.bytes.fetchAdd(n, .monotonic);
        return consumed;
    }
};

test "Rooms: a member with ten queued messages gets them in one write" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{});
    defer r.deinit();

    var member: Counting = undefined;
    member.init(gpa, io);
    defer member.ws.deinit();
    try r.join("room", &member.socket);
    defer r.leave("room", &member.socket);

    // The sender task cannot run before this one yields: all ten are
    // queued when it starts.
    for (0..10) |_| try std.testing.expectEqual(@as(usize, 1), r.broadcast("room", .text, "hello", null));
    try wait.waitAtLeast(io, "the ten messages written", &member.bytes, 70);
    try std.testing.expectEqual(@as(usize, 70), member.bytes.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), member.writes.load(.monotonic));
}

test "Rooms: a member that leaves mid-drain gets nothing after leave returns and strands no bytes" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    var r: websocket.Rooms = .init(gpa, .{});
    defer r.deinit();

    var member: Counting = undefined;
    member.init(gpa, io);
    defer member.ws.deinit();
    try r.join("room", &member.socket);
    for (0..20) |_| _ = r.broadcast("room", .text, "hello", null);
    r.leave("room", &member.socket);
    const Unchanged = struct {
        member: *Counting,
        after: usize,
        fn f(c: @This()) bool {
            return c.member.bytes.load(.monotonic) == c.after;
        }
    };
    try wait.expectStays(io, "no bytes reach the member after leave returned", Unchanged{ .member = &member, .after = member.bytes.load(.monotonic) }, Unchanged.f, wait.short_window);
    try std.testing.expectEqual(@as(usize, 0), r.count("room"));
}
