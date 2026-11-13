//! Tests for server.zig, the HTTP/2 engine on Anole's own protocol core
//! ("h2 engine: ..."). Each drives `Engine(void).serve` directly over a
//! loopback connection (the server is never `run`: the engine is not wired
//! in yet), with a small client written on our own codecs (frame.zig,
//! hpack.zig), so they depend neither on nghttp2 nor on the nghttp2
//! engine's test client.
const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const engine = @import("server.zig");
const server_mod = @import("../server.zig");
const config = @import("../config.zig");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const DeadlineReader = @import("../server/test_socket.zig").DeadlineReader;
const placement = @import("../placement.zig");
const wait = @import("anole_test_wait");

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
const ErrorCode = frame.ErrorCode;
const Server = server_mod.Server(void);
const E = engine.Engine(void);
const F = frame.flags;

// ---------------------------------------------------------------------------
// The client

const Resp = struct {
    status: u16 = 0,
    /// 1xx heads before the final one.
    interim: u16 = 0,
    /// Whether an interim head came before the final one.
    interim_first: bool = false,
    headers: std.ArrayList(hpack.Field) = .empty,
    trailers: std.ArrayList(hpack.Field) = .empty,
    body: std.ArrayList(u8) = .empty,
    ended: bool = false,
    /// DATA frames received.
    data_frames: u32 = 0,
    rst: ?ErrorCode = null,
    /// Our send credit on the stream.
    send_window: i64 = 0,

    fn header(r: *const Resp, name: []const u8) ?[]const u8 {
        for (r.headers.items) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    fn done(r: *const Resp) bool {
        return r.ended or r.rst != null;
    }
};

const Client = struct {
    gpa: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.heap.ArenaAllocator,
    rbuf: [32 * 1024]u8 = undefined,
    reader: DeadlineReader = undefined,
    wbuf: [4096]u8 = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    enc: hpack.Encoder = .{},
    dec: hpack.Decoder = .init(.{}),
    scratch: [65536]u8 = undefined,
    resps: std.AutoHashMapUnmanaged(u31, *Resp) = .empty,
    next_id: u31 = 1,
    /// The server's SETTINGS_INITIAL_WINDOW_SIZE, and our connection
    /// credit.
    peer_initial: i64 = 65535,
    conn_window: i64 = 65535,
    settings_seen: bool = false,
    ping_acks: u32 = 0,
    goaway: ?ErrorCode = null,
    /// WINDOW_UPDATEs for what arrives, as it arrives.
    auto_window: bool = true,

    fn init(c: *Client, gpa: Allocator, io: std.Io, stream: std.Io.net.Stream) !void {
        c.* = .{ .gpa = gpa, .io = io, .stream = stream, .arena = .init(gpa) };
        c.reader = .init(stream, io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        try c.write(server_mod_preface);
        try c.frameOut(.settings, 0, 0, "");
        try c.flush();
        // Until the server's SETTINGS, and its ACK of ours, nothing is
        // known about its windows.
        while (!c.settings_seen) try c.readOne();
        try c.frameOut(.settings, F.ack, 0, "");
        try c.flush();
    }

    fn deinit(c: *Client) void {
        var it = c.resps.valueIterator();
        while (it.next()) |r| {
            r.*.headers.deinit(c.gpa);
            r.*.trailers.deinit(c.gpa);
            r.*.body.deinit(c.gpa);
            c.gpa.destroy(r.*);
        }
        c.resps.deinit(c.gpa);
        c.arena.deinit();
    }

    fn write(c: *Client, bytes: []const u8) !void {
        try c.writer.interface.writeAll(bytes);
    }

    fn flush(c: *Client) !void {
        try c.writer.interface.flush();
    }

    fn frameOut(c: *Client, ty: frame.Type, fl: u8, id: u31, payload: []const u8) !void {
        var h: [frame.header_len]u8 = undefined;
        _ = frame.writeHeader(&h, .{ .length = @intCast(payload.len), .type = ty, .flags = fl, .stream_id = id });
        try c.write(&h);
        try c.write(payload);
    }

    /// Opens a stream: HEADERS with the pseudo-headers and `extra`, ended
    /// when `end` (not flushed).
    fn open(c: *Client, method: []const u8, path: []const u8, extra: []const hpack.Field, end: bool) !u31 {
        const id = c.next_id;
        c.next_id += 2;
        const r = try c.gpa.create(Resp);
        r.* = .{ .send_window = c.peer_initial };
        try c.resps.put(c.gpa, id, r);
        var fields: std.ArrayList(hpack.Field) = .empty;
        defer fields.deinit(c.gpa);
        try fields.appendSlice(c.gpa, &.{
            .{ .name = ":method", .value = method },
            .{ .name = ":scheme", .value = "http" },
            .{ .name = ":path", .value = path },
            .{ .name = ":authority", .value = "localhost" },
        });
        try fields.appendSlice(c.gpa, extra);
        var block: [4096]u8 = undefined;
        const n = try c.enc.encode(&block, fields.items);
        try c.frameOut(.headers, F.end_headers | (if (end) F.end_stream else 0), id, block[0..n]);
        return id;
    }

    /// A request with its whole body, sent and flushed, keeping to the
    /// server's windows (reading its frames while out of credit).
    fn request(c: *Client, method: []const u8, path: []const u8, body: ?[]const u8) !u31 {
        return c.requestWith(method, path, &.{}, body);
    }

    fn requestWith(c: *Client, method: []const u8, path: []const u8, extra: []const hpack.Field, body: ?[]const u8) !u31 {
        const id = try c.open(method, path, extra, body == null);
        if (body) |b| try c.sendBody(id, b, true) else try c.flush();
        return id;
    }

    fn sendBody(c: *Client, id: u31, body: []const u8, end: bool) !void {
        const r = c.resps.get(id).?;
        var rest = body;
        while (true) {
            const n: usize = @intCast(@min(@as(i64, @intCast(rest.len)), c.conn_window, r.send_window, 16384));
            if (n == 0 and rest.len > 0) {
                try c.flush();
                if (r.done()) return;
                try c.readOne();
                continue;
            }
            const last = n == rest.len;
            try c.frameOut(.data, if (last and end) F.end_stream else 0, id, rest[0..n]);
            c.conn_window -= @intCast(n);
            r.send_window -= @intCast(n);
            rest = rest[n..];
            if (last) break;
        }
        try c.flush();
    }

    fn get(c: *Client, id: u31) *Resp {
        return c.resps.get(id).?;
    }

    /// Reads frames until `id`'s response is over.
    fn until(c: *Client, id: u31) !*Resp {
        const r = c.get(id);
        while (!r.done()) try c.readOne();
        return r;
    }

    /// Reads frames until every stream opened is over.
    fn untilAll(c: *Client) !void {
        while (true) {
            var it = c.resps.valueIterator();
            const all = while (it.next()) |r| {
                if (!r.*.done()) break false;
            } else true;
            if (all) return;
            try c.readOne();
        }
    }

    /// Reads one frame and acts on it.
    fn readOne(c: *Client) !void {
        const r = &c.reader.interface;
        const head = try r.peek(frame.header_len);
        const h = frame.FrameHeader.parse(head[0..frame.header_len]);
        const whole = try r.take(frame.header_len + h.length);
        const payload = whole[frame.header_len..];
        switch (h.type) {
            .settings => if (h.flags & F.ack == 0) {
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const sid = std.mem.readInt(u16, payload[i..][0..2], .big);
                    const v = std.mem.readInt(u32, payload[i + 2 ..][0..4], .big);
                    if (sid == @backingInt(frame.SettingId.initial_window_size)) {
                        const delta = @as(i64, v) - c.peer_initial;
                        c.peer_initial = v;
                        var it = c.resps.valueIterator();
                        while (it.next()) |resp| resp.*.send_window += delta;
                    }
                }
                c.settings_seen = true;
            },
            .window_update => {
                const inc: i64 = std.mem.readInt(u32, payload[0..4], .big) & 0x7fffffff;
                if (h.stream_id == 0) c.conn_window += inc else if (c.resps.get(h.stream_id)) |resp| resp.send_window += inc;
            },
            .ping => if (h.flags & F.ack != 0) {
                c.ping_acks += 1;
            },
            .goaway => c.goaway = @fromBackingInt(std.mem.readInt(u32, payload[4..8], .big)),
            .rst_stream => if (c.resps.get(h.stream_id)) |resp| {
                resp.rst = @fromBackingInt(std.mem.readInt(u32, payload[0..4], .big));
            },
            .headers => {
                const resp = c.resps.get(h.stream_id) orelse return error.UnknownStream;
                try expect(h.flags & F.end_headers != 0);
                var blk = c.dec.block(payload, &c.scratch, c.scratch.len);
                var status: ?u16 = null;
                var list: std.ArrayList(hpack.Field) = .empty;
                defer list.deinit(c.gpa);
                while (try blk.next()) |f| {
                    if (std.mem.eql(u8, f.name, ":status")) {
                        status = try std.fmt.parseInt(u16, f.value, 10);
                        continue;
                    }
                    const a = c.arena.allocator();
                    try list.append(c.gpa, .{ .name = try a.dupe(u8, f.name), .value = try a.dupe(u8, f.value) });
                }
                if (status) |st| {
                    if (st < 200) {
                        try expect(h.flags & F.end_stream == 0);
                        if (resp.status == 0) resp.interim_first = true;
                        resp.interim += 1;
                    } else {
                        resp.status = st;
                        try resp.headers.appendSlice(c.gpa, list.items);
                    }
                } else try resp.trailers.appendSlice(c.gpa, list.items);
                if (h.flags & F.end_stream != 0) resp.ended = true;
            },
            .data => {
                const resp = c.resps.get(h.stream_id) orelse return error.UnknownStream;
                try resp.body.appendSlice(c.gpa, payload);
                resp.data_frames += 1;
                if (h.flags & F.end_stream != 0) resp.ended = true;
                if (c.auto_window and payload.len > 0) {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @intCast(payload.len), .big);
                    try c.frameOut(.window_update, 0, 0, &b);
                    if (!resp.ended) try c.frameOut(.window_update, 0, h.stream_id, &b);
                    try c.flush();
                }
            },
            else => {},
        }
    }

    fn ping(c: *Client, data: [8]u8) !void {
        try c.frameOut(.ping, 0, 0, &data);
    }

    fn windowUpdate(c: *Client, id: u31, inc: u31) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, inc, .big);
        try c.frameOut(.window_update, 0, id, &b);
    }

    fn rst(c: *Client, id: u31, code: ErrorCode) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @backingInt(code), .big);
        try c.frameOut(.rst_stream, 0, id, &b);
    }
};

const server_mod_preface = engine.preface;

// ---------------------------------------------------------------------------
// The server side: the engine on a connection of a server that is never run.

const Fixture = struct {
    io: std.Io,
    server: Server,
    tcp: std.Io.net.Server,
    server_end: std.Io.net.Stream,
    connection: server_mod.Connection,
    listener: config.Listener,
    future: std.Io.Future(anyerror!void),
    client: Client,

    fn start(fx: *Fixture, gpa: Allocator, io: std.Io, cfg: config.ServerConfig) !void {
        fx.io = io;
        fx.server = Server.init(gpa, io, cfg, {});
        Handlers.route(&fx.server);
        fx.tcp = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
        const client_end = try fx.tcp.socket.address.connect(io, .{ .mode = .stream });
        fx.server_end = try fx.tcp.accept(io);
        try fx.connection.initPlain(gpa, io, fx.server_end);
        fx.connection.write_pool = &fx.server.request_buffers;
        fx.listener = .{ .address = .{ .ip = fx.tcp.socket.address } };
        fx.future = try io.concurrent(serve, .{fx});
        // The client's memory is the test's, never the server's.
        try fx.client.init(testing.allocator, io, client_end);
    }

    fn serve(fx: *Fixture) anyerror!void {
        var busy = false;
        try E.serve(&fx.server, &fx.listener, false, &fx.connection, &busy);
    }

    /// The client hangs up; the engine sees the end and returns.
    fn stop(fx: *Fixture) void {
        fx.client.stream.close(fx.io);
        fx.future.await(fx.io) catch {};
        fx.client.deinit();
        fx.connection.deinit();
        fx.server_end.close(fx.io);
        fx.tcp.deinit(fx.io);
        fx.server.deinit();
    }
};

const Handlers = struct {
    fn route(s: *Server) void {
        s.router.get("/hello", hello);
        s.router.get("/users/:id", user);
        s.router.post("/echo", echo);
        s.router.post("/slurp", slurp);
        s.router.get("/big", big);
        s.router.get("/trailers", trailers);
        s.router.get("/held", held);
        s.router.post("/ack", ack);
        s.router.addRouteWith(.get, "/nw/hello", hello, .{ .no_wait = true });
        s.router.addRouteWith(.post, "/nw/echo", echo, .{ .no_wait = true });
        s.router.addRouteWith(.get, "/nw/big", big, .{ .no_wait = true });
    }

    fn hello(_: *Request, res: *Response) !void {
        res.body = "hello";
    }

    fn user(req: *Request, res: *Response) !void {
        try res.print(.text, "user {s}", .{req.params.get("id").?});
    }

    fn echo(req: *Request, res: *Response) !void {
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var out_buf: [4096]u8 = undefined;
        var out = try res.stream(&out_buf);
        _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
            error.ReadFailed => return body.err orelse error.Unexpected,
            error.WriteFailed => return out.err orelse error.Unexpected,
        };
        try out.end();
    }

    /// The whole body read first, then answered: its first read is what
    /// sends a `100 Continue` (a streamed answer's head would come first).
    fn slurp(req: *Request, res: *Response) !void {
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var all: std.Io.Writer.Allocating = .init(req.arena);
        _ = body.interface.streamRemaining(&all.writer) catch |err| switch (err) {
            error.ReadFailed => return body.err orelse error.Unexpected,
            error.WriteFailed => return error.OutOfMemory,
        };
        res.body = all.written();
    }

    fn trailers(_: *Request, res: *Response) !void {
        res.body = "with trailers";
        try res.trailer("x-done", "yes");
    }

    /// 1 MB streamed, far past the client's 64 KiB window.
    fn big(_: *Request, res: *Response) !void {
        var buf: [4096]u8 = undefined;
        var out = try res.stream(&buf);
        for (0..big_len / 1000) |i| out.interface.print("{d:0>999}\n", .{i}) catch |err| {
            _ = big_failed.fetchAdd(1, .monotonic);
            return out.err orelse err;
        };
        try out.end();
    }
    const big_len = 1000 * 1000;
    var big_failed: std.atomic.Value(u32) = .init(0);

    /// Answers once the test sets `held_gate`.
    fn held(req: *Request, res: *Response) !void {
        _ = held_entered.fetchAdd(1, .acq_rel);
        try wait.waitEvent(req.io, "the test opened the held handlers' gate", &held_gate);
        res.body = "held";
    }
    var held_gate: std.Io.Event = .unset;
    var held_entered: std.atomic.Value(u32) = .init(0);

    /// Once the test sets `ack_gate`: 204 at once, then the whole body
    /// read, as an ack-then-process handler does.
    fn ack(req: *Request, res: *Response) !void {
        try wait.waitEvent(req.io, "the test opened the ack gate", &ack_gate);
        res.status = .no_content;
        try res.write();
        var in_buf: [4096]u8 = undefined;
        var body = try req.reader(&in_buf);
        var all: std.Io.Writer.Allocating = .init(req.arena);
        const read = if (body.interface.streamRemaining(&all.writer)) |_| true else |_| false;
        ack_read_ok.store(read and std.mem.eql(u8, all.written(), ack_body), .release);
        ack_gone.store(res.peerGone(), .release);
        _ = ack_done.fetchAdd(1, .acq_rel);
    }
    const ack_body = "the whole request body";
    var ack_gate: std.Io.Event = .unset;
    var ack_read_ok: std.atomic.Value(bool) = .init(false);
    var ack_gone: std.atomic.Value(bool) = .init(true);
    var ack_done: std.atomic.Value(u32) = .init(0);
};

fn bigBody() ![]u8 {
    const b = try testing.allocator.alloc(u8, Handlers.big_len);
    var w: std.Io.Writer = .fixed(b);
    for (0..Handlers.big_len / 1000) |i| try w.print("{d:0>999}\n", .{i});
    return b;
}

fn pattern(n: usize) ![]u8 {
    const b = try testing.allocator.alloc(u8, n);
    for (b, 0..) |*x, i| x.* = @truncate(i *% 31 +% (i >> 11));
    return b;
}

// ---------------------------------------------------------------------------

test "h2 engine: GET and HEAD round trip" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    const ok = try c.request("GET", "/hello", null);
    const head = try c.request("HEAD", "/hello", null);
    const missing = try c.request("GET", "/nope", null);
    const t = try c.request("GET", "/trailers", null);
    try c.untilAll();
    try expectEqual(200, c.get(ok).status);
    try expectEqualStrings("hello", c.get(ok).body.items);
    try expectEqualStrings("5", c.get(ok).header("content-length").?);
    try expect(c.get(ok).header("date") != null);
    try expectEqual(200, c.get(head).status);
    try expectEqualStrings("5", c.get(head).header("content-length").?);
    try expectEqualStrings("", c.get(head).body.items);
    try expectEqual(404, c.get(missing).status);
    try expectEqualStrings("with trailers", c.get(t).body.items);
    try expectEqual(1, c.get(t).trailers.items.len);
    try expectEqualStrings("yes", c.get(t).trailers.items[0].value);
}

test "h2 engine: POST body echoed, with and without content-length" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    const body = try pattern(100 * 1024 + 3);
    defer testing.allocator.free(body);
    const small = try c.requestWith("POST", "/echo", &.{.{ .name = "content-length", .value = "11" }}, "hello world");
    const unsized = try c.request("POST", "/echo", body);
    const inline_echo = try c.request("POST", "/nw/echo", "whole in one read");
    try c.untilAll();
    try expectEqualStrings("hello world", c.get(small).body.items);
    try expect(std.mem.eql(u8, body, c.get(unsized).body.items));
    try expectEqualStrings("whole in one read", c.get(inline_echo).body.items);
}

test "h2 engine: a noWait route is answered inline" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    // The handshake's frames are all out by now.
    const spawned = engine.test_spawned.load(.acquire);
    const flushers = engine.test_flushers.load(.acquire);
    const writes = server_mod.Connection.TestSocketWrites.get();
    const id = try c.request("GET", "/nw/hello", null);
    const r = try c.until(id);
    try expectEqualStrings("hello", r.body.items);
    try expectEqual(spawned, engine.test_spawned.load(.acquire));
    try expectEqual(flushers, engine.test_flushers.load(.acquire));
    // The head and the body in one write, from the reader.
    try expectEqual(writes + 1, server_mod.Connection.TestSocketWrites.get());
}

test "h2 engine: a tasked route runs on its own task; a noWait request whose body comes later runs on a task" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    var spawned = engine.test_spawned.load(.acquire);
    const id = try c.request("GET", "/users/7", null);
    try expectEqualStrings("user 7", (try c.until(id)).body.items);
    try expectEqual(spawned + 1, engine.test_spawned.load(.acquire));

    spawned = engine.test_spawned.load(.acquire);
    const late = try c.open("POST", "/nw/echo", &.{}, false);
    try c.flush();
    try wait.waitAtLeast(testing.io, "the request waiting for its body got a task", &engine.test_spawned, spawned + 1);
    try c.sendBody(late, "came later", true);
    try expectEqualStrings("came later", (try c.until(late)).body.items);
}

test "h2 engine: a streamed body larger than the window" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    const want = try bigBody();
    defer testing.allocator.free(want);
    const blocks = engine.test_blocks.load(.acquire);
    const id = try c.request("GET", "/big", null);
    const r = try c.until(id);
    try expectEqual(200, r.status);
    try expect(std.mem.eql(u8, want, r.body.items));
    // On a task: two blocks, reused while the other one is written.
    try expectEqual(blocks + 2, engine.test_blocks.load(.acquire));
    // On the reader too, where blocks are never waited for.
    const inl = try c.request("GET", "/nw/big", null);
    try expect(std.mem.eql(u8, want, (try c.until(inl)).body.items));
}

test "h2 engine: a small streamed body takes one block, and its end rides on its DATA" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    // On the reader: the last flush takes no second block, and the end
    // that follows it joins the queued DATA (one frame).
    var blocks = engine.test_blocks.load(.acquire);
    const inl = try c.request("POST", "/nw/echo", "tiny");
    const r = try c.until(inl);
    try expectEqualStrings("tiny", r.body.items);
    try expectEqual(1, r.data_frames);
    try expectEqual(blocks + 1, engine.test_blocks.load(.acquire));
    // On a task the same block count (the flusher may frame the DATA
    // before the end comes, so not the frame count).
    blocks = engine.test_blocks.load(.acquire);
    const tasked = try c.request("POST", "/echo", "tiny");
    try expectEqualStrings("tiny", (try c.until(tasked)).body.items);
    try expectEqual(blocks + 1, engine.test_blocks.load(.acquire));
}

test "h2 engine: a read's many small responses go out in one write" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    const reads = engine.test_reads.load(.acquire);
    const writes = server_mod.Connection.TestSocketWrites.get();
    const flushers = engine.test_flushers.load(.acquire);
    var ids: [100]u31 = undefined;
    for (&ids) |*id| id.* = try c.open("GET", "/nw/hello", &.{}, true);
    try c.flush();
    try c.untilAll();
    for (ids) |id| try expectEqualStrings("hello", c.get(id).body.items);
    // Far less than a write buffer of output per read: one write each at
    // most (the reads that carry only WINDOW_UPDATEs write nothing).
    try expect(server_mod.Connection.TestSocketWrites.get() - writes <= engine.test_reads.load(.acquire) - reads);
    try expectEqual(flushers, engine.test_flushers.load(.acquire));
}

test "h2 engine: a response with no body on a stream the peer has ended is no reset" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    Handlers.ack_gate.reset();
    defer Handlers.ack_gate.reset();
    const done = Handlers.ack_done.load(.acquire);
    const id = try c.request("POST", "/ack", Handlers.ack_body);
    // The PING's ACK comes after the server took the whole body: the 204
    // then closes the stream inside its own submit.
    try c.ping("ack-body".*);
    try c.flush();
    while (c.ping_acks == 0) try c.readOne();
    Handlers.ack_gate.set(testing.io);
    const r = try c.until(id);
    try expectEqual(204, r.status);
    try expect(r.rst == null);
    try wait.waitAtLeast(testing.io, "the ack handler read its body", &Handlers.ack_done, done + 1);
    try expect(Handlers.ack_read_ok.load(.acquire));
    try expect(!Handlers.ack_gone.load(.acquire));
}

test "h2 engine: a connection error mid-stream lets the streaming handler go and the connection close" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    c.auto_window = false;
    const failed = Handlers.big_failed.load(.acquire);
    const id = try c.request("GET", "/big", null);
    const r = c.get(id);
    // A window's worth arrives; the handler then waits for room.
    while (r.body.items.len < 65535) try c.readOne();
    // A PING on a stream is a connection error (RFC 9113 §6.7): no more
    // DATA is framed, so the handler must be let go, not left waiting.
    try c.frameOut(.ping, 0, id, "12345678");
    try c.flush();
    while (c.goaway == null) try c.readOne();
    try expectEqual(ErrorCode.protocol_error, c.goaway.?);
    try wait.waitAtLeast(testing.io, "the streaming handler failed its write", &Handlers.big_failed, failed + 1);
    // `stop` then waits for `serve`, which returns only once the handler
    // is gone.
}

test "h2 engine: 100-continue sends a 1xx HEADERS without END_STREAM before the final head" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    const id = try c.open("POST", "/slurp", &.{.{ .name = "expect", .value = "100-continue" }}, false);
    try c.flush();
    const r = c.get(id);
    while (r.interim == 0) try c.readOne();
    try expectEqual(0, r.status);
    try c.sendBody(id, "after the continue", true);
    _ = try c.until(id);
    try expect(r.interim_first);
    try expectEqual(1, r.interim);
    try expectEqual(200, r.status);
    try expectEqualStrings("after the continue", r.body.items);
}

test "h2 engine: many concurrent streams on one connection" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    var ids: [100]u31 = undefined;
    var paths: [100][24]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        const path = if (i % 2 == 0)
            try std.fmt.bufPrint(&paths[i], "/users/{d}", .{i})
        else
            "/nw/hello";
        id.* = try c.open("GET", path, &.{}, true);
    }
    try c.flush();
    try c.untilAll();
    for (ids, 0..) |id, i| {
        var want: [24]u8 = undefined;
        const body = if (i % 2 == 0) try std.fmt.bufPrint(&want, "user {d}", .{i}) else "hello";
        try expectEqualStrings(body, c.get(id).body.items);
    }
}

test "h2 engine: past out_high new HEADERS are refused while a PING is still ACKed" {
    // Any owned byte unwritten is past it: a PING's ACK queued ahead of a
    // request in the same read.
    engine.test_out_high = 0;
    defer engine.test_out_high = null;
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    try c.ping("12345678".*);
    const refused = try c.open("GET", "/hello", &.{}, true);
    try c.flush();
    const r = try c.until(refused);
    try expectEqual(ErrorCode.refused_stream, r.rst.?);
    while (c.ping_acks == 0) try c.readOne();
    // Once the queue is written, streams are taken again.
    const ok = try c.request("GET", "/hello", null);
    try expectEqualStrings("hello", (try c.until(ok)).body.items);
}

test "h2 engine: one writer at a time" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    Handlers.held_gate.reset();
    defer Handlers.held_gate.reset();
    const entered = Handlers.held_entered.load(.acquire);
    engine.test_max_writers.store(0, .release);
    var ids: [64]u31 = undefined;
    for (&ids) |*id| id.* = try c.open("GET", "/held", &.{}, true);
    try c.flush();
    try wait.waitAtLeast(testing.io, "every held handler started", &Handlers.held_entered, entered + 64);
    // All 64 finish together and race for the token.
    Handlers.held_gate.set(testing.io);
    try c.untilAll();
    for (ids) |id| try expectEqualStrings("held", c.get(id).body.items);
    try expectEqual(1, engine.test_max_writers.load(.acquire));
}

test "h2 engine: Out is released at the first read after a trim interval that finds the connection idle" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    // The handshake's frames took a block.
    const releases = engine.test_out_releases.load(.acquire);
    // A trim interval passes; the next read finds the connection idle.
    _ = engine.test_trim_epoch.fetchAdd(1, .release);
    try c.ping("idle....".*);
    try c.flush();
    try wait.waitAtLeast(testing.io, "the idle connection released its output blocks", &engine.test_out_releases, releases + 1);
    try expect(fx.connection.write_held == null);
    try expectEqual(0, fx.connection.writer.buffer.len);
    // And takes them again for the next response.
    const again = try c.request("GET", "/hello", null);
    try expectEqualStrings("hello", (try c.until(again)).body.items);
}

test "h2 engine: a peer reset mid-response lets the handler go and the connection carries on" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    c.auto_window = false;
    const failed = Handlers.big_failed.load(.acquire);
    const id = try c.request("GET", "/big", null);
    const r = c.get(id);
    // A window's worth arrives; the rest waits for credit that never
    // comes, with the handler waiting for room.
    while (r.body.items.len < 65535) try c.readOne();
    try c.rst(id, .cancel);
    // The connection's credit for what arrived.
    try c.windowUpdate(0, @intCast(r.body.items.len));
    try c.flush();
    try wait.waitAtLeast(testing.io, "the reset handler failed its write", &Handlers.big_failed, failed + 1);
    c.auto_window = true;
    const next = try c.request("GET", "/hello", null);
    try expectEqualStrings("hello", (try c.until(next)).body.items);
}

test "h2 engine: concurrent upload and download with small windows" {
    var fx: Fixture = undefined;
    try fx.start(testing.allocator, testing.io, .{ .request = .{ .max_body_size = 8 << 20 } });
    defer fx.stop();
    const c = &fx.client;
    const body = try pattern(1024 * 1024 + 17);
    defer testing.allocator.free(body);
    // The echo writes back as it reads: the server waits on the client's
    // window while the client waits on the server's, each reading the
    // other's frames meanwhile.
    const up = try c.request("POST", "/echo", body);
    const down = try c.request("GET", "/big", null);
    try c.untilAll();
    try expect(std.mem.eql(u8, body, c.get(up).body.items));
    try expectEqual(Handlers.big_len, c.get(down).body.items.len);
}

/// Counts allocations through it.
const CountingAllocator = struct {
    inner: Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

test "h2 engine: a warm connection serves requests without allocating" {
    // The release behaviour: a spare stream keeps its arena's memory.
    const safety = @import("anole_safety");
    safety.arena_poisoning.store(false, .monotonic);
    defer safety.arena_poisoning.store(true, .monotonic);
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    var fx: Fixture = undefined;
    try fx.start(counting.allocator(), testing.io, .{});
    defer fx.stop();
    const c = &fx.client;
    // Warm-up: bursts of more streams at once than the measured requests
    // ever have alive (a stream is let go a little after its response is
    // out), so the spares, the stream table and the queues are grown.
    for (0..3) |_| {
        var ids: [8]u31 = undefined;
        for (&ids, 0..) |*id, i| id.* = try c.open("GET", if (i % 2 == 0) "/users/1" else "/nw/hello", &.{}, true);
        try c.flush();
        try c.untilAll();
    }
    const before = counting.count.load(.monotonic);
    for (0..20) |_| {
        const a = try c.request("GET", "/users/2", null);
        const b = try c.request("GET", "/nw/hello", null);
        try expectEqualStrings("user 2", (try c.until(a)).body.items);
        try expectEqualStrings("hello", (try c.until(b)).body.items);
    }
    try expectEqual(before, counting.count.load(.monotonic));
}
