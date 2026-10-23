//! Anole raw TCP and UDP example: a line chat, a UDP responder with
//! per-peer sessions and an HTTP /stats page, in one process.
//!
//!   zig build run-net                       # chat on 7000, UDP on 7001, HTTP on 3000
//!   zig build run-net -- 7100 7101 3100     # other ports
//!
//!   nc localhost 7000                       # type lines; everyone connected sees them
//!   echo hello | nc -u -w1 localhost 7001   # "hello (1)"; the count is per peer
//!   curl localhost:3000/stats
//!
//! The chat uses callbacks, so an idle connection holds no task. Every send
//! returns once the bytes are queued: a slow reader fills its own queue and
//! is told so (`.busy`), it never holds up the others.
const std = @import("std");
const anole = @import("anole");
const net = anole.net;

pub const std_options = anole.std_options;
pub const panic = anole.panic;

const log = std.log.scoped(.net_example);

/// What the handlers share (`Server(Hub)` passes a `*Hub` to each one).
const Hub = struct {
    lock: std.atomic.Mutex = .unlocked,
    users: std.ArrayList(*net.Conn) = .empty,
    gpa: std.mem.Allocator,

    fn acquire(h: *Hub) void {
        while (!h.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn broadcast(h: *Hub, from: *net.Conn, text: []const u8) void {
        h.acquire();
        defer h.lock.unlock();
        for (h.users.items) |u| {
            if (u == from) continue;
            // A queue past its maximum drops the line for that user alone.
            _ = u.sendFrame(text) catch {};
        }
    }
};

const Chat = struct {
    /// One per connection, made with it and freed after `close`.
    pub const State = struct { name: [24]u8 = undefined, name_len: u8 = 0 };

    pub fn open(hub: *Hub, conn: *net.Conn) !void {
        const st = conn.contextAs(State);
        const name = try std.fmt.bufPrint(&st.name, "guest{d}", .{conn.id()});
        st.name_len = @intCast(name.len);
        hub.acquire();
        defer hub.lock.unlock();
        try hub.users.append(hub.gpa, conn);
        _ = try conn.sendFrame("welcome; see /stats for who is here");
    }

    pub fn message(hub: *Hub, conn: *net.Conn, line: []const u8) !void {
        const st = conn.contextAs(State);
        var buf: [1024]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{s}: {s}", .{ st.name[0..st.name_len], line });
        hub.broadcast(conn, text);
    }

    pub fn close(hub: *Hub, conn: *net.Conn, _: net.CloseReason) void {
        hub.acquire();
        defer hub.lock.unlock();
        for (hub.users.items, 0..) |u, i| if (u == conn) {
            _ = hub.users.swapRemove(i);
            break;
        };
    }

    /// The server is draining: say goodbye and close.
    pub fn drain(_: *Hub, conn: *net.Conn) !void {
        _ = try conn.sendFrame("server is shutting down");
        conn.close();
    }
};

/// Answers every datagram with its own text and a count of the peer's.
const Counter = struct {
    pub const State = struct { seen: u32 = 0 };

    pub fn datagram(session: *net.Session, d: *net.Datagram) !void {
        const st = session.contextAs(State);
        st.seen += 1;
        var buf: [1500]u8 = undefined;
        const text = std.mem.trimEnd(u8, d.data, "\r\n");
        try d.reply(try std.fmt.bufPrint(&buf, "{s} ({d})\n", .{ text, st.seen }));
    }
};

fn stats(hub: *Hub, _: *anole.Request, res: *anole.Response) !void {
    hub.acquire();
    const users = hub.users.items.len;
    hub.lock.unlock();
    try res.print(.text, "chat users: {d}\n", .{users});
}

pub fn main(init: std.process.Init) !void {
    var tcp_port: u16 = 7000;
    var udp_port: u16 = 7001;
    var http_port: u16 = 3000;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| tcp_port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| udp_port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| http_port = try std.fmt.parseInt(u16, p, 10);

    var hub: Hub = .{ .gpa = init.gpa };
    defer hub.users.deinit(init.gpa);
    var app = try anole.Server(Hub).init(init.gpa, .{}, &hub);
    defer app.deinit();

    var buf: [32]u8 = undefined;
    try app.tcp(try std.fmt.bufPrint(&buf, ":{d}", .{tcp_port}), Chat, .{ .framing = .{ .lines = .{} }, .idle_timeout = .fromSeconds(600) });
    var ubuf: [32]u8 = undefined;
    try app.udp(try std.fmt.bufPrint(&ubuf, ":{d}", .{udp_port}), Counter, .{ .sessions = .{ .idle_timeout = .fromSeconds(30) } });
    app.get("/stats", stats);
    log.info("chat on tcp {d}, udp responder on {d}, stats on http {d}", .{ tcp_port, udp_port, http_port });
    var hbuf: [32]u8 = undefined;
    try app.listen(try std.fmt.bufPrint(&hbuf, ":{d}", .{http_port}));
}
