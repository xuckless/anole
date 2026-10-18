//! A Redis/Valkey client on std.Io: hiredis (redis/hiredis, BSD-3-Clause)
//! formats the commands and parses the replies; the socket is Anole's, so
//! waiting for Redis suspends the calling coroutine, not its thread.
//!
//!     var redis = try anole.redis.Client.connect(gpa, io, .{ .host = "127.0.0.1", .port = 6379 });
//!     defer redis.close();
//!     _ = try redis.command(arena, &.{ "SET", "k", "v" });
//!     const reply = try redis.command(arena, &.{ "GET", "k" });  // .string = "v"
//!
//! One connection serves one command at a time (a lock orders the tasks
//! that share it); replies are copied into the arena given.
const std = @import("std");
const c = @import("anole_hiredis_c");

pub const Reply = union(enum) {
    nil,
    status: []const u8,
    /// The server's error reply ("ERR ...", "WRONGTYPE ...").
    err: []const u8,
    int: i64,
    string: []const u8,
    double: f64,
    boolean: bool,
    array: []Reply,
    /// RESP3 maps, as key, value, key, value...
    map: []Reply,

    /// The string of a bulk-string or status reply; null for nil.
    pub fn text(self: Reply) ?[]const u8 {
        return switch (self) {
            .string, .status => |s| s,
            else => null,
        };
    }
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    /// AUTH after connecting (with `username` for an ACL user).
    password: ?[]const u8 = null,
    username: ?[]const u8 = null,
    /// SELECT after connecting.
    db: ?u32 = null,
};

pub const Error = error{ ConnectionClosed, ProtocolError, ServerError, OutOfMemory };

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Stream,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    parser: *c.redisReader,
    mutex: std.Io.Mutex = .init,
    broken: bool = false,

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Client {
        const socket = if (std.Io.net.IpAddress.parse(options.host, options.port)) |a|
            try a.connect(io, .{ .mode = .stream })
        else |_|
            try (try std.Io.net.HostName.init(options.host)).connect(io, options.port, .{ .mode = .stream });
        errdefer socket.close(io);
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .socket = socket, .parser = c.redisReaderCreate() orelse return error.OutOfMemory };
        self.reader = self.socket.reader(io, &self.read_buf);
        self.writer = self.socket.writer(io, &self.write_buf);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (options.password) |pw| {
            const r = if (options.username) |u|
                try self.command(arena.allocator(), &.{ "AUTH", u, pw })
            else
                try self.command(arena.allocator(), &.{ "AUTH", pw });
            if (r == .err) return error.ServerError;
        }
        if (options.db) |db| {
            var buf: [16]u8 = undefined;
            const r = try self.command(arena.allocator(), &.{ "SELECT", try std.fmt.bufPrint(&buf, "{d}", .{db}) });
            if (r == .err) return error.ServerError;
        }
        return self;
    }

    pub fn close(self: *Client) void {
        c.redisReaderFree(self.parser);
        self.socket.close(self.io);
        self.gpa.destroy(self);
    }

    /// Sends one command and waits for its reply. A server error is a
    /// `.err` reply, not a Zig error; a broken connection is.
    pub fn command(self: *Client, arena: std.mem.Allocator, args: []const []const u8) !Reply {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.broken) return error.ConnectionClosed;
        errdefer self.broken = true;
        try self.send(args);
        return self.receive(arena);
    }

    /// Sends several commands at once and reads their replies in order.
    pub fn pipeline(self: *Client, arena: std.mem.Allocator, commands: []const []const []const u8) ![]Reply {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.broken) return error.ConnectionClosed;
        errdefer self.broken = true;
        for (commands) |args| try self.send(args);
        const replies = try arena.alloc(Reply, commands.len);
        for (replies) |*r| r.* = try self.receive(arena);
        return replies;
    }

    fn send(self: *Client, args: []const []const u8) !void {
        var ptrs: [32][*c]const u8 = undefined;
        var lens: [32]usize = undefined;
        if (args.len > ptrs.len) return error.TooManyArguments;
        for (args, 0..) |a, i| {
            ptrs[i] = a.ptr;
            lens[i] = a.len;
        }
        var out: [*c]u8 = null;
        const n = c.redisFormatCommandArgv(&out, @intCast(args.len), &ptrs, &lens);
        if (n < 0) return error.OutOfMemory;
        defer c.redisFreeCommand(out);
        self.writer.interface.writeAll(out[0..@intCast(n)]) catch return error.ConnectionClosed;
        self.writer.interface.flush() catch return error.ConnectionClosed;
    }

    fn receive(self: *Client, arena: std.mem.Allocator) !Reply {
        while (true) {
            var raw: ?*anyopaque = null;
            if (c.redisReaderGetReply(self.parser, &raw) != c.REDIS_OK) return error.ProtocolError;
            if (raw) |p| {
                const reply: *c.redisReply = @ptrCast(@alignCast(p));
                defer c.freeReplyObject(reply);
                return convert(arena, reply);
            }
            // Not whole yet: feed more.
            const r = &self.reader.interface;
            r.fillMore() catch return error.ConnectionClosed;
            const bytes = r.buffered();
            if (c.redisReaderFeed(self.parser, bytes.ptr, bytes.len) != c.REDIS_OK) return error.ProtocolError;
            r.toss(bytes.len);
        }
    }
};

fn convert(arena: std.mem.Allocator, r: *c.redisReply) Error!Reply {
    const bytes = if (r.str) |s| s[0..r.len] else "";
    return switch (r.type) {
        c.REDIS_REPLY_NIL => .nil,
        c.REDIS_REPLY_STATUS => .{ .status = try arena.dupe(u8, bytes) },
        c.REDIS_REPLY_ERROR => .{ .err = try arena.dupe(u8, bytes) },
        c.REDIS_REPLY_INTEGER => .{ .int = r.integer },
        c.REDIS_REPLY_STRING, c.REDIS_REPLY_VERB, c.REDIS_REPLY_BIGNUM => .{ .string = try arena.dupe(u8, bytes) },
        c.REDIS_REPLY_DOUBLE => .{ .double = r.dval },
        c.REDIS_REPLY_BOOL => .{ .boolean = r.integer != 0 },
        c.REDIS_REPLY_ARRAY, c.REDIS_REPLY_SET, c.REDIS_REPLY_PUSH, c.REDIS_REPLY_MAP, c.REDIS_REPLY_ATTR => blk: {
            const items = try arena.alloc(Reply, r.elements);
            for (items, 0..) |*item, i| item.* = try convert(arena, r.element[i]);
            break :blk if (r.type == c.REDIS_REPLY_MAP or r.type == c.REDIS_REPLY_ATTR) .{ .map = items } else .{ .array = items };
        },
        else => error.ProtocolError,
    };
}

test "Client over a fake server: commands, pipelining, error replies, nil" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{});
    defer listener.deinit(io);
    var fake = try io.concurrent(struct {
        /// Answers each RESP command it sees with a canned reply.
        fn serve(l: *std.Io.net.Server, _io: std.Io) !void {
            const conn = try l.accept(_io);
            defer conn.close(_io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(_io, &rbuf);
            var w = conn.writer(_io, &wbuf);
            while (true) {
                // "*<n>\r\n" then n bulk strings.
                const head = r.interface.takeDelimiterInclusive('\n') catch return;
                const n = try std.fmt.parseInt(usize, std.mem.trim(u8, head[1..], "\r\n"), 10);
                var first: [16]u8 = undefined;
                var first_len: usize = 0;
                for (0..n) |i| {
                    const len_line = try r.interface.takeDelimiterInclusive('\n');
                    const len = try std.fmt.parseInt(usize, std.mem.trim(u8, len_line[1..], "\r\n"), 10);
                    const arg = try r.interface.take(len + 2);
                    if (i == 0) {
                        first_len = @min(len, first.len);
                        @memcpy(first[0..first_len], arg[0..first_len]);
                    }
                }
                const cmd = first[0..first_len];
                const reply = if (std.mem.eql(u8, cmd, "SET"))
                    "+OK\r\n"
                else if (std.mem.eql(u8, cmd, "GET"))
                    "$5\r\nvalue\r\n"
                else if (std.mem.eql(u8, cmd, "INCR"))
                    ":42\r\n"
                else if (std.mem.eql(u8, cmd, "MISSING"))
                    "$-1\r\n"
                else if (std.mem.eql(u8, cmd, "KEYS"))
                    "*2\r\n$1\r\na\r\n$1\r\nb\r\n"
                else
                    "-ERR unknown command\r\n";
                try w.interface.writeAll(reply);
                try w.interface.flush();
            }
        }
    }.serve, .{ &listener, io });
    defer fake.cancel(io) catch {};

    const client = try Client.connect(gpa, io, .{ .port = listener.socket.address.getPort() });
    defer client.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("OK", (try client.command(arena, &.{ "SET", "k", "value" })).status);
    try std.testing.expectEqualStrings("value", (try client.command(arena, &.{ "GET", "k" })).text().?);
    try std.testing.expectEqual(@as(i64, 42), (try client.command(arena, &.{ "INCR", "n" })).int);
    try std.testing.expect((try client.command(arena, &.{"MISSING"})) == .nil);
    try std.testing.expectEqualStrings("ERR unknown command", (try client.command(arena, &.{"NOPE"})).err);
    const replies = try client.pipeline(arena, &.{ &.{"KEYS"}, &.{ "INCR", "n" } });
    try std.testing.expectEqualStrings("b", replies[0].array[1].string);
    try std.testing.expectEqual(@as(i64, 42), replies[1].int);
}

test "Client and RedisStore against a live server (-Dredis-test-port)" {
    const port = @import("build_options").redis_test_port orelse return error.SkipZigTest;
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const client = try Client.connect(gpa, io, .{ .port = port });
    defer client.close();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try client.command(arena, &.{ "DEL", "anole:test:n" });
    try std.testing.expectEqual(@as(i64, 1), (try client.command(arena, &.{ "INCR", "anole:test:n" })).int);
    try std.testing.expectEqualStrings("OK", (try client.command(arena, &.{ "SET", "anole:test:k", "v\x00binary" })).status);
    try std.testing.expectEqualStrings("v\x00binary", (try client.command(arena, &.{ "GET", "anole:test:k" })).string);
    try std.testing.expect((try client.command(arena, &.{ "LPUSH", "anole:test:k", "x" })) == .err);

    const session = @import("../session/root.zig");
    var rs: session.RedisStore = .{ .client = client, .gpa = gpa };
    const store = rs.store();
    try store.save("abc", "user\x0042\x00", 60);
    try std.testing.expectEqualStrings("user\x0042\x00", (try store.load(arena, "abc")).?);
    try store.destroy("abc");
    try std.testing.expect(try store.load(arena, "abc") == null);
}
