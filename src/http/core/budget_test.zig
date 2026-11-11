//! The buffer budget (#131) end to end over HTTP/1.1: bodies collected
//! whole hold their bytes of the executor's `buffer_budget`; a body of
//! known length past it is answered 503 with `Retry-After` before any of
//! it is read, one of unknown length when the budget runs out partway,
//! and every way a request ends gives its share back. The budget's
//! arithmetic is tested in admission.zig.
const std = @import("std");
const wait = @import("anole_test_wait");
const dusty = @import("root.zig");

const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};
const Server = dusty.Server(void);

/// Collects the body and answers its length.
fn length(req: *dusty.Request, res: *dusty.Response) !void {
    const b = try req.body();
    res.body = try std.fmt.allocPrint(req.arena, "{d}", .{if (b) |x| x.len else 0});
}

/// Collects the body, then fails.
fn failAfterBody(req: *dusty.Request, _: *dusty.Response) !void {
    _ = try req.body();
    return error.Nope;
}

fn startServer(server: *Server, io: std.Io) !std.Io.Future(anyerror!void) {
    server.router.post("/len", length);
    server.router.post("/fail", failAfterBody);
    var future = try io.concurrent(struct {
        fn run(s: *Server) anyerror!void {
            try s.run();
        }
    }.run, .{server});
    errdefer future.cancel(io) catch {};
    try server.waitReady(io);
    return future;
}

fn heldIs(server: *Server, n: usize) bool {
    return server.admission.rows[0].held_bytes.load(.monotonic) == n;
}

fn waitHeld(io: std.Io, server: *Server, n: usize) !void {
    const S = struct { s: *Server, n: usize };
    try wait.waitUntil(io, "the bytes held of the buffer budget", S{ .s = server, .n = n }, struct {
        fn f(x: S) bool {
            return heldIs(x.s, x.n);
        }
    }.f);
}

/// Opens a connection and sends `head` and `body_len` bytes of body.
fn startPost(io: std.Io, server: *Server, head: []const u8, body_len: usize) !std.Io.net.Stream {
    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    errdefer stream.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(head);
    try w.interface.splatByteAll('x', body_len);
    try w.interface.flush();
    return stream;
}

/// Sends `more` and reads the answer until the server closes.
fn finish(io: std.Io, stream: std.Io.net.Stream, more: []const u8, out: []u8) ![]const u8 {
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(more);
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.WriteFailed => {},
        else => |e| return e,
    };
    return fw.buffered();
}

fn rawAll(io: std.Io, server: *Server, request: []const u8, body_len: usize, out: []u8) ![]const u8 {
    const stream = try startPost(io, server, request, body_len);
    defer stream.close(io);
    return finish(io, stream, "", out);
}

fn headerValue(response: []const u8, name: []const u8) ?[]const u8 {
    const head = response[0 .. std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (line.len > name.len + 1 and std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':')
            return std.mem.trim(u8, line[name.len + 1 ..], " ");
    }
    return null;
}

/// A body of 64 KiB holds 64 KiB + 1 of the budget: the byte of room
/// the read that finds its end goes into.
const head_64k = "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n";

test "budget: slow senders holding nearly whole bodies fill it; the next is refused 503 before 100 Continue, the admitted ones complete" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .buffer_budget = 4 * 65537 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    // Four bodies one byte short of whole.
    var held: [4]std.Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |s| s.close(io);
    for (&held) |*s| {
        s.* = try startPost(io, &server, head_64k, 65535);
        opened += 1;
    }
    try waitHeld(io, &server, 4 * 65537);

    // The fifth is refused at once: it never gets a 100 Continue, and
    // the connection closes behind the 503.
    var buf: [2048]u8 = undefined;
    const refused = try rawAll(io, &server, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 65536\r\nExpect: 100-continue\r\n\r\n", 0, &buf);
    try std.testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 503"));
    try std.testing.expect(std.mem.indexOf(u8, refused, "100 Continue") == null);
    const secs = try std.fmt.parseInt(u16, headerValue(refused, "Retry-After") orelse return error.NoRetryAfter, 10);
    try std.testing.expect(secs >= 5 and secs <= 15);
    try std.testing.expect(std.ascii.eqlIgnoreCase(headerValue(refused, "Connection") orelse "", "close"));
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_memory.load(.monotonic));

    // The admitted ones complete.
    for (held) |s| {
        const answer = try finish(io, s, "x", &buf);
        try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200"));
        try std.testing.expect(std.mem.endsWith(u8, answer, "\r\n\r\n65536"));
    }
    try waitHeld(io, &server, 0);

    // And with the budget free again, a sixth passes.
    const sixth = try rawAll(io, &server, head_64k, 65536, &buf);
    try std.testing.expect(std.mem.startsWith(u8, sixth, "HTTP/1.1 200"));
    try waitHeld(io, &server, 0);
}

test "budget: a chunked body that grows past it is answered 503 partway, and the connection closes" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .buffer_budget = 64 * 1024 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    const first = try startPost(io, &server, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 49152\r\nConnection: close\r\n\r\n", 49151);
    defer first.close(io);
    try waitHeld(io, &server, 49153);

    // 32 KiB more in one chunk: past the 16 KiB left.
    var buf: [2048]u8 = undefined;
    const stream = try startPost(io, &server, "POST /len HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8000\r\n", 32768);
    defer stream.close(io);
    const answer = try finish(io, stream, "\r\n0\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 503"));
    try std.testing.expect(headerValue(answer, "Retry-After") != null);
    try std.testing.expect(std.ascii.eqlIgnoreCase(headerValue(answer, "Connection") orelse "", "close"));
    try waitHeld(io, &server, 49153);

    const done = try finish(io, first, "x", &buf);
    try std.testing.expect(std.mem.startsWith(u8, done, "HTTP/1.1 200"));
    try waitHeld(io, &server, 0);
}

test "budget: given back when the handler fails, the client leaves mid-body, or the request times out" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{
        .listeners = loopback,
        .buffer_budget = 64 * 1024,
        // Only the third case waits for it: the hang guard otherwise.
        .timeout = .{ .request = .fromMilliseconds(200) },
    }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};
    var buf: [2048]u8 = undefined;

    // (a) The handler fails after its body.
    const failed = try rawAll(io, &server, "POST /fail HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n", 1000, &buf);
    try std.testing.expect(std.mem.startsWith(u8, failed, "HTTP/1.1 500"));
    try waitHeld(io, &server, 0);

    // (b) The client hangs up mid-body.
    const gone = try startPost(io, &server, head_64k, 1000);
    try waitHeld(io, &server, 65537);
    gone.close(io);
    try waitHeld(io, &server, 0);

    // (c) The request's deadline passes mid-body.
    const slow = try startPost(io, &server, head_64k, 1000);
    defer slow.close(io);
    try waitHeld(io, &server, 65537);
    try waitHeld(io, &server, 0);

    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_memory.load(.monotonic));
}

test "budget: given back when the server stops with a body pending" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{
        .listeners = loopback,
        .buffer_budget = 64 * 1024,
        .timeout = .{ .shutdown = .fromMilliseconds(50) },
    }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    var stopped = false;
    defer if (!stopped) future.cancel(io) catch {};

    const pending = try startPost(io, &server, head_64k, 1000);
    defer pending.close(io);
    try waitHeld(io, &server, 65537);
    future.cancel(io) catch {};
    stopped = true;
    try std.testing.expect(heldIs(&server, 0));
}

test "budget: an executor holding nothing else lets one body past it through" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .buffer_budget = 1024 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    var buf: [2048]u8 = undefined;
    const answer = try rawAll(io, &server, head_64k, 65536, &buf);
    try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, answer, "65536"));
    try waitHeld(io, &server, 0);
    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_memory.load(.monotonic));
}

test "budget: resolved per executor when the server starts, and set values kept" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .max_tasks = 7 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};
    // A quarter of memory over the executors: at least 64 MiB over one.
    try std.testing.expect(server.admission.buffer_budget >= 64 << 20);
    try std.testing.expectEqual(@as(u32, 7), server.admission.task_cap);
}

test "budget: a refused body sent without Expect gets its 503 before the rest of it" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .buffer_budget = 64 * 1024 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    const first = try startPost(io, &server, head_64k, 1000);
    defer first.close(io);
    try waitHeld(io, &server, 65537);

    // A browser's POST: no Expect, part of the body sent. The 503 comes
    // without the server waiting for the rest (it is never sent here).
    var buf: [2048]u8 = undefined;
    const stream = try startPost(io, &server, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 65536\r\n\r\n", 1000);
    defer stream.close(io);
    const refused = try finish(io, stream, "", &buf);
    try std.testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 503"));
    try std.testing.expect(headerValue(refused, "Retry-After") != null);
    try std.testing.expect(std.ascii.eqlIgnoreCase(headerValue(refused, "Connection") orelse "", "close"));
    try std.testing.expectEqual(@as(u64, 1), server.admission.refused_memory.load(.monotonic));

    const done = try finish(io, first, &@as([64536]u8, @splat('x')), &buf);
    try std.testing.expect(std.mem.startsWith(u8, done, "HTTP/1.1 200"));
    try waitHeld(io, &server, 0);
}

test "budget: a declared length past max_body_size is 413 at once, holding nothing, however full the budget" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{
        .listeners = loopback,
        .buffer_budget = 64 * 1024,
        .request = .{ .max_body_size = 128 * 1024 },
    }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    const first = try startPost(io, &server, head_64k, 1000);
    defer first.close(io);
    try waitHeld(io, &server, 65537);

    // Not a 503 to retry: it can never pass. No 100 Continue either.
    var buf: [2048]u8 = undefined;
    const too_big = try rawAll(io, &server, "POST /len HTTP/1.1\r\nHost: x\r\nContent-Length: 5000000\r\nExpect: 100-continue\r\n\r\n", 0, &buf);
    try std.testing.expect(std.mem.startsWith(u8, too_big, "HTTP/1.1 413"));
    try std.testing.expect(std.mem.indexOf(u8, too_big, "100 Continue") == null);
    try std.testing.expectEqual(@as(u64, 0), server.admission.refused_memory.load(.monotonic));
    try std.testing.expect(heldIs(&server, 65537));

    const done = try finish(io, first, &@as([64536]u8, @splat('x')), &buf);
    try std.testing.expect(std.mem.startsWith(u8, done, "HTTP/1.1 200"));
    try waitHeld(io, &server, 0);
}

test "tasks: a quarter below the cap an HTTP/1.x accept waits for a task to end" {
    const io = std.testing.io;
    // Accepts stop at 2 of 3: the third slot is kept for streams.
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .max_tasks = 3 }, {});
    defer server.deinit();
    var future = try startServer(&server, io);
    defer future.cancel(io) catch {};

    // The two slots accepts may take: connections whose bodies never
    // complete.
    var held: [2]std.Io.net.Stream = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |s| s.close(io);
    for (&held) |*s| {
        s.* = try startPost(io, &server, head_64k, 1000);
        opened += 1;
    }
    try waitHeld(io, &server, 2 * 65537);
    try std.testing.expectEqual(@as(u32, 2), server.admission.rows[0].tasks.load(.monotonic));

    // A third connection is accepted by the kernel, then waits for a
    // slot; once the first ends it is served.
    const third = try startPost(io, &server, head_64k, 65536);
    defer third.close(io);
    try wait.waitAtLeast(io, "the accept waiting at the task cap", &server.admission.refused_tasks, 1);
    var buf: [2048]u8 = undefined;
    const answer_first = try finish(io, held[0], &@as([64536]u8, @splat('x')), &buf);
    try std.testing.expect(std.mem.startsWith(u8, answer_first, "HTTP/1.1 200"));
    const answer = try finish(io, third, "", &buf);
    try std.testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 200"));
    const answer_second = try finish(io, held[1], &@as([64536]u8, @splat('x')), &buf);
    try std.testing.expect(std.mem.startsWith(u8, answer_second, "HTTP/1.1 200"));
}

test "tasks: max_tasks below 3 is refused at startup" {
    const io = std.testing.io;
    var server = Server.init(std.testing.allocator, io, .{ .listeners = loopback, .max_tasks = 2 }, {});
    defer server.deinit();
    try std.testing.expectError(error.NoTasksAllowed, server.run());
}
