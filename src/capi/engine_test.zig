//! The engine over HTTP/2 and HTTP/3, where consumer requests detach: a
//! consumer thread answers through the engine's functions (what libanole's
//! exports call), and Anole's own clients check what goes out. The C suite
//! (tests/capi/consumer.c) covers HTTP/1.1 and the exported API.
const std = @import("std");
const wait = @import("anole_test_wait");
const builtin = @import("builtin");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = engine.abi;
const features = anole.features;
const zio = anole.zio;

const alloc = std.testing.allocator;

const Answerer = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(u64) = .init(0),
    aborts: std.atomic.Value(u32) = .init(0),
    /// The handle of the most recent ABORT event, and why.
    last_abort: std.atomic.Value(u64) = .init(0),
    last_abort_reason: std.atomic.Value(u32) = .init(0),
    last_abort_status: std.atomic.Value(u32) = .init(0),
    sent: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),
    late_reads: std.atomic.Value(u32) = .init(0),
    file_path: []const u8,

    var big: [200 * 1024]u8 = @splat('z');

    fn run(self: *Answerer) void {
        var buf: [256 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                self.handle(buf[off..][0..ev.len]) catch |err| {
                    std.debug.print("answer failed: {t}\n", .{err});
                    _ = self.failures.fetchAdd(1, .monotonic);
                };
                off += ev.len;
            }
        }
    }

    fn str(rec: []const u8, s: abi.Span) []const u8 {
        return rec[s.off..][0..s.len];
    }

    fn handle(self: *Answerer, rec: []const u8) !void {
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        const e = self.e;
        switch (@as(abi.EventType, @fromBackingInt(@intCast(ev.type)))) {
            .request => {},
            .abort => {
                const ab: *const abi.AbortEvent = @ptrCast(@alignCast(rec.ptr));
                self.last_abort_reason.store(ab.reason, .release);
                self.last_abort_status.store(ab.status, .release);
                self.last_abort.store(ev.handle, .release);
                _ = self.aborts.fetchAdd(1, .monotonic);
                return;
            },
            .sent => {
                _ = self.sent.fetchAdd(1, .monotonic);
                return;
            },
            else => return,
        }
        const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
        const h = ev.handle;
        const text: []const abi.Header = &.{.{ .name = .of("content-type"), .value = .of("text/plain") }};
        switch (r.route_id) {
            1 => {
                var out: [128]u8 = undefined;
                const body = try std.fmt.bufPrint(&out, "hello {s} {d}", .{ str(rec, r.path), r.version });
                try engine.respond(e, h, 200, text, body, false);
            },
            2 => {
                if (r.flags & abi.REQ_BODY_INLINE != 0) {
                    try engine.respond(e, h, 200, text, str(rec, r.body), false);
                } else {
                    var body: std.ArrayList(u8) = .empty;
                    defer body.deinit(alloc);
                    var chunk: [16 * 1024]u8 = undefined;
                    while (true) {
                        const k = try engine.reqRead(e, h, &chunk, 5000);
                        if (k == 0) break;
                        try body.appendSlice(alloc, chunk[0..k]);
                    }
                    try engine.respond(e, h, 200, text, body.items, false);
                }
            },
            3 => {
                try engine.streamStart(e, h, 200, text);
                _ = try engine.streamWrite(e, h, "a", false);
                _ = try engine.streamWrite(e, h, big[0..1000], true);
                try engine.streamEnd(e, h, &.{.{ .name = .of("x-t"), .value = .of("done") }});
            },
            // anole_req_respond_fd is not on Windows (std.c.open does not exist there).
            4 => if (comptime builtin.os.tag == .windows) {
                try engine.respond(e, h, 200, text, "world", false);
            } else {
                const fd = std.c.open(@ptrCast(self.file_path.ptr), .{ .ACCMODE = .RDONLY });
                if (fd < 0) return error.Open;
                defer _ = std.c.close(fd);
                try engine.respondFd(e, h, 200, text, fd, 6, 5);
            },
            5 => self.held.store(h, .release),
            6 => try engine.respond(e, h, 200, text, &big, true),
            // anole_req_abort: the stream is reset, the connection stays.
            8 => try engine.abort(e, h),
            // Reads the body, answers, and checks the answered handle is
            // gone for reads too (the body may live in the request's
            // memory, which goes with the answer).
            7 => {
                var chunk: [16 * 1024]u8 = undefined;
                var total: usize = 0;
                while (true) {
                    const k = try engine.reqRead(e, h, &chunk, 5000);
                    if (k == 0) break;
                    total += k;
                }
                var out: [32]u8 = undefined;
                try engine.respond(e, h, 200, text, try std.fmt.bufPrint(&out, "{d}", .{total}), false);
                if (engine.reqRead(e, h, &chunk, 0)) |_| {
                    _ = self.late_reads.fetchAdd(1, .monotonic);
                } else |err| if (err != error.Gone) return err;
            },
            else => try engine.respond(e, h, 404, &.{}, "", false),
        }
    }
};

const routes =
    \\"routes": [
    \\  {"method": "GET", "path": "/hello/:n", "handler": 1},
    \\  {"method": "POST", "path": "/echo", "handler": 2},
    \\  {"method": "GET", "path": "/stream", "handler": 3},
    \\  {"method": "GET", "path": "/file", "handler": 4},
    \\  {"method": "GET", "path": "/hold", "handler": 5},
    \\  {"method": "GET", "path": "/borrow", "handler": 6},
    \\  {"method": "GET", "path": "/short", "handler": 5, "timeout_ms": 100},
    \\  {"method": "GET", "path": "/abort", "handler": 8},
    \\  {"method": "POST", "path": "/late", "handler": 7}
    \\]
;

/// One engine with the routes above and its consumer thread (`Answerer`),
/// started for one test, with the file route 4 sends.
const Fixture = struct {
    e: *engine.Engine,
    a: Answerer,
    t: std.Thread,
    tmp: std.testing.TmpDir,
    file_path: [:0]u8,

    const plain_listener =
        \\"listeners": [{"address": "127.0.0.1", "port": 0}]
    ;
    const quic_listener =
        \\"listeners": [{"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}, "http3": true}]
    ;

    fn start(fx: *Fixture, comptime listener: []const u8) !void {
        const json = "{\"executors\": 2, \"timeouts\": {\"request_ms\": 3000, \"shutdown_ms\": 1000}," ++
            "\"limits\": {\"body_max\": 1048576, \"inline_body_max\": 4096}," ++ listener ++ "," ++ routes ++ "}";
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer e.destroy();
        const c = try e.attach(null, null, true);
        try e.start();

        fx.tmp = std.testing.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        const io0 = std.testing.io;
        try fx.tmp.dir.writeFile(io0, .{ .sub_path = "f.txt", .data = "hello world, from a file" });
        const dir_path = try fx.tmp.dir.realPathFileAlloc(io0, ".", alloc);
        defer alloc.free(dir_path);
        const file_path = try std.fmt.allocPrintSentinel(alloc, "{s}/f.txt", .{dir_path}, 0);
        errdefer alloc.free(file_path);

        fx.e = e;
        fx.file_path = file_path;
        fx.a = .{ .e = e, .c = c, .file_path = file_path };
        fx.t = try std.Thread.spawn(.{}, Answerer.run, .{&fx.a});
    }

    fn stop(fx: *Fixture) void {
        fx.a.stop.store(true, .release);
        fx.t.join();
        alloc.free(fx.file_path);
        fx.tmp.cleanup();
        fx.e.destroy();
    }

    /// The consumer answered everything without a failure, and the engine
    /// drains with nothing in flight.
    fn finish(fx: *Fixture) !void {
        try std.testing.expectEqual(@as(u32, 0), fx.a.failures.load(.acquire));
        try fx.e.drain();
        try std.testing.expect(fx.e.wait(stopWaitMs()));
        try std.testing.expectEqual(@as(u64, 0), fx.e.stats().inflight);
    }
};

/// The claims of the detached-answer tests, each run over HTTP/2 (h2c) and
/// HTTP/3 on a fresh engine (`Fixture`) and one client connection.
fn Harness(comptime proto: enum { h2, h3 }) type {
    return struct {
        const client = if (proto == .h2) anole.h2 else anole.h3;
        const version: u8 = if (proto == .h2) 20 else 30;
        const scheme = if (proto == .h2) "http" else "https";

        /// What a claim works with: the consumer, a connection to the
        /// engine, an arena for bodies, and the runtime's Io.
        const Ctx = struct {
            a: *Answerer,
            conn: *client.ClientConnection,
            arena: std.mem.Allocator,
            io: std.Io,
        };

        /// Runs `claim` on a fresh engine and connection, then drains the
        /// engine (`Fixture.finish`).
        fn run(comptime claim: anytype) !void {
            var fx: Fixture = undefined;
            try fx.start(if (proto == .h2) Fixture.plain_listener else Fixture.quic_listener);
            defer fx.stop();
            const rt = try zio.Runtime.init(alloc, .{});
            defer rt.deinit();
            const io = rt.io();
            const Body = struct {
                fn go(a: *Answerer, port: u16, io_: std.Io) !void {
                    var arena_state: std.heap.ArenaAllocator = .init(alloc);
                    defer arena_state.deinit();
                    const conn = try client.ClientConnection.connect(alloc, io_, if (proto == .h2)
                        .{ .host = "127.0.0.1", .port = port }
                    else
                        .{ .host = "localhost", .address = try .parseIp4("127.0.0.1", port), .port = port, .tls = .{ .insecure_skip_verify = true }, .connect_timeout = .fromSeconds(3) });
                    defer conn.close();
                    try claim(Ctx{ .a = a, .conn = conn, .arena = arena_state.allocator(), .io = io_ });
                }
            };
            // HTTP/3's UDP port comes after the listeners'.
            var f = try io.concurrent(Body.go, .{ &fx.a, fx.e.port(if (proto == .h2) 0 else 1), io });
            try f.await(io);
            try fx.finish();
        }

        fn open(conn: *client.ClientConnection, method: []const u8, path: []const u8, body: ?[]const u8) !*client.Stream {
            return conn.request(&.{
                .{ .name = ":method", .value = method }, .{ .name = ":path", .value = path },
                .{ .name = ":scheme", .value = scheme }, .{ .name = ":authority", .value = "localhost" },
            }, if (proto == .h2) .{ .body_bytes = body } else .{ .body = body != null });
        }

        fn get(conn: *client.ClientConnection, arena: std.mem.Allocator, method: []const u8, path: []const u8, body: ?[]const u8) !struct { u16, []const u8, *client.Stream } {
            const s = try open(conn, method, path, body);
            if (proto == .h3) if (body) |b| {
                try s.writer().writeAll(b);
                try s.closeSend();
            };
            try s.waitHead();
            const out = try s.reader().allocRemaining(arena, .unlimited);
            return .{ s.status, out, s };
        }

        /// Many at once on one connection: each answered from the consumer
        /// thread, none with a task waiting.
        fn detached(c: Ctx) !void {
            const d0 = c.a.e.stats().detached;
            var streams: [24]*client.Stream = undefined;
            for (&streams, 0..) |*st, i| st.* = try open(c.conn, "GET", try std.fmt.allocPrint(c.arena, "/hello/{d}", .{i}), null);
            for (streams, 0..) |st, i| {
                defer st.release();
                try st.waitHead();
                try std.testing.expectEqual(@as(u16, 200), st.status);
                const body = try st.reader().allocRemaining(c.arena, .unlimited);
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(c.arena, "hello /hello/{d} {d}", .{ i, version }), body);
            }
            try std.testing.expect(c.a.e.stats().detached >= d0 + streams.len);
        }

        /// One body that arrives whole (inline in the record), one larger
        /// than the stream window (read with anole_req_read).
        fn bodies(c: Ctx) !void {
            {
                const status, const body, const s = try get(c.conn, c.arena, "POST", "/echo", "the body");
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualStrings("the body", body);
            }
            {
                const big = try c.arena.alloc(u8, 300 * 1024);
                for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
                const status, const body, const s = try get(c.conn, c.arena, "POST", "/echo", big);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualSlices(u8, big, body);
            }
        }

        /// Route 7 reads the body, answers, then reads again: GONE every
        /// time (the body may live in the request's memory).
        fn readAfterAnswer(c: Ctx) !void {
            const body = try c.arena.alloc(u8, 10 * 1024);
            @memset(body, 'b');
            for (0..20) |_| {
                const status, const out, const s = try get(c.conn, c.arena, "POST", "/late", body);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualStrings("10240", out);
            }
            try std.testing.expectEqual(@as(u32, 0), c.a.late_reads.load(.acquire));
        }

        fn streamTrailers(c: Ctx) !void {
            const status, const body, const s = try get(c.conn, c.arena, "GET", "/stream", null);
            defer s.release();
            try std.testing.expectEqual(@as(u16, 200), status);
            try std.testing.expectEqual(@as(usize, 1001), body.len);
            try std.testing.expectEqual(@as(u8, 'a'), body[0]);
            try std.testing.expectEqualStrings("done", s.trailer("x-t").?);
        }

        fn fileRange(c: Ctx) !void {
            const status, const body, const s = try get(c.conn, c.arena, "GET", "/file", null);
            defer s.release();
            try std.testing.expectEqual(@as(u16, 200), status);
            try std.testing.expectEqualStrings("world", body);
        }

        fn borrowedSent(c: Ctx) !void {
            const sent0 = c.a.sent.load(.acquire);
            const status, const body, const s = try get(c.conn, c.arena, "GET", "/borrow", null);
            defer s.release();
            try std.testing.expectEqual(@as(u16, 200), status);
            try std.testing.expectEqual(@as(usize, Answerer.big.len), body.len);
            try wait.waitAtLeast(c.io, "the borrowed body reported SENT", &c.a.sent, sent0 + 1);
        }

        fn deadline(c: Ctx) !void {
            const status, _, const s = try get(c.conn, c.arena, "GET", "/short", null);
            defer s.release();
            try std.testing.expectEqual(@as(u16, 504), status);
            // The consumer may take the request after its deadline
            // answered (a busy machine): wait for it.
            const h = try waitHeld(c.io, &c.a.held);
            try std.testing.expectError(error.Gone, engine.respond(c.a.e, h, 200, &.{}, "", false));
            // The consumer hears why: the deadline, with the 504 sent.
            try wait.waitEqual(c.io, "the consumer heard the held request's ABORT", &c.a.last_abort, h);
            try std.testing.expectEqual(@as(u32, abi.ABORT_DEADLINE), c.a.last_abort_reason.load(.acquire));
            try std.testing.expectEqual(@as(u32, 504), c.a.last_abort_status.load(.acquire));
        }

        /// anole_req_abort resets this stream (CANCEL / H3_REQUEST_CANCELLED)
        /// and the connection serves the next request.
        fn reqAbort(c: Ctx) !void {
            {
                const s = try open(c.conn, "GET", "/abort", null);
                defer s.release();
                if (s.waitHead()) |_| return error.AbortedRequestAnswered else |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => try std.testing.expectEqual(error.StreamReset, err),
                }
            }
            const status, const out, const s2 = try get(c.conn, c.arena, "GET", "/hello/9", null);
            defer s2.release();
            try std.testing.expectEqual(@as(u16, 200), status);
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(c.arena, "hello /hello/9 {d}", .{version}), out);
        }

        /// The client resets a stream waiting for its answer.
        fn clientReset(c: Ctx) !void {
            const s = try open(c.conn, "GET", "/hold", null);
            const held = try wait.waitNonZero(c.io, "the consumer holds the request", &c.a.held);
            s.cancel();
            s.release();
            try wait.waitEqual(c.io, "the consumer heard the reset stream's ABORT", &c.a.last_abort, held);
            try std.testing.expectError(error.Gone, engine.respond(c.a.e, held, 200, &.{}, "", false));
            try std.testing.expectEqual(@as(u32, abi.ABORT_CLIENT), c.a.last_abort_reason.load(.acquire));
        }
    };
}

const H2 = Harness(.h2);
const H3 = Harness(.h3);

test "capi engine over HTTP/2: 24 concurrent requests on one connection are answered from the consumer thread, detached" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.detached);
}

test "capi engine over HTTP/3: 24 concurrent requests on one connection are answered from the consumer thread, detached" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.detached);
}

test "capi engine over HTTP/2: a body that arrives whole comes inline; a larger one is read with anole_req_read" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.bodies);
}

test "capi engine over HTTP/3: a body that arrives whole comes inline; a larger one is read with anole_req_read" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.bodies);
}

test "capi engine over HTTP/2: anole_req_read after the answer is GONE" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.readAfterAnswer);
}

test "capi engine over HTTP/3: anole_req_read after the answer is GONE" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.readAfterAnswer);
}

test "capi engine over HTTP/2: a streamed answer carries its trailers" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.streamTrailers);
}

test "capi engine over HTTP/3: a streamed answer carries its trailers" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.streamTrailers);
}

// anole_req_respond_fd is not supported on Windows (ANOLE_E_UNSUPPORTED,
// anole.h), so these two have nothing to check there.
test "capi engine over HTTP/2: anole_req_respond_fd sends the file range" {
    if (comptime !features.http2 or builtin.os.tag == .windows) return error.SkipZigTest;
    try H2.run(H2.fileRange);
}

test "capi engine over HTTP/3: anole_req_respond_fd sends the file range" {
    if (comptime !features.http3 or builtin.os.tag == .windows) return error.SkipZigTest;
    try H3.run(H3.fileRange);
}

test "capi engine over HTTP/2: a borrowed body reports SENT" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.borrowedSent);
}

test "capi engine over HTTP/3: a borrowed body reports SENT" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.borrowedSent);
}

test "capi engine over HTTP/2: a detached request past its deadline gets 504, the late answer is GONE, the consumer hears ABORT DEADLINE" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.deadline);
}

test "capi engine over HTTP/3: a detached request past its deadline gets 504, the late answer is GONE, the consumer hears ABORT DEADLINE" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.deadline);
}

test "capi engine over HTTP/2: anole_req_abort resets the stream and the connection serves the next" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.reqAbort);
}

test "capi engine over HTTP/3: anole_req_abort resets the stream and the connection serves the next" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.reqAbort);
}

test "capi engine over HTTP/2: a client reset is ABORT CLIENT and the handle is GONE" {
    if (comptime !features.http2) return error.SkipZigTest;
    try H2.run(H2.clientReset);
}

test "capi engine over HTTP/3: a client reset is ABORT CLIENT and the handle is GONE" {
    if (comptime !features.http3) return error.SkipZigTest;
    try H3.run(H3.clientReset);
}

test "capi engine: made-up handles are refused, never followed, and so is a file range past the file's end" {
    var fx: Fixture = undefined;
    try fx.start(Fixture.plain_listener);
    defer fx.stop();
    const e = fx.e;
    const forged_ws: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 2) << 28) | 1;
    if (comptime features.websocket) {
        try std.testing.expectError(error.Gone, engine.ws.send(e, forged_ws, abi.WS_TEXT, "x", false));
        try std.testing.expectError(error.Over, engine.ws.close(e, forged_ws, 1000, ""));
        try std.testing.expectError(error.Gone, engine.ws.subscribe(e, forged_ws, "t", true));
    }
    if (comptime builtin.os.tag != .windows) {
        // A length past the end of the file is refused, however large.
        const fd = std.c.open(@ptrCast(fx.file_path.ptr), .{ .ACCMODE = .RDONLY });
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        try std.testing.expectError(error.Invalid, engine.respondFd(e, 1, 200, &.{}, fd, 1, std.math.maxInt(u64)));
        try std.testing.expectError(error.Invalid, engine.respondFd(e, 1, 200, &.{}, fd, 0, std.math.maxInt(u64)));
    }
    try fx.finish();
}

/// A consumer for the WebTransport test: echoes streams and datagrams,
/// answers one-way streams with a datagram, and closes a session whose
/// client resets a stream.
const WtAnswerer = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    opens: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    drains: std.atomic.Value(u32) = .init(0),
    busies: std.atomic.Value(u32) = .init(0),
    writables: std.atomic.Value(u32) = .init(0),
    resets: std.atomic.Value(u32) = .init(0),
    reset_code: std.atomic.Value(u32) = .init(0),
    close_code: std.atomic.Value(u32) = .init(0),
    close_by: std.atomic.Value(u32) = .init(99),
    stale_ok: std.atomic.Value(u32) = .init(0),
    /// Only the answering thread touches these.
    streams: std.AutoHashMapUnmanaged(u64, Ent) = .empty,

    const Ent = struct {
        uni: bool,
        session: u64,
        got: std.ArrayList(u8) = .empty,
        /// A write answered ANOLE_BUSY: ANOLE_EV_WRITABLE is owed.
        busy: bool = false,
        /// The echo is complete: let go once nothing is owed.
        done: bool = false,
    };

    fn run(self: *WtAnswerer) void {
        var buf: [256 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                self.handle(buf[off..][0..ev.len]) catch |err| {
                    std.debug.print("wt answer failed: {t}\n", .{err});
                    _ = self.failures.fetchAdd(1, .monotonic);
                };
                off += ev.len;
            }
        }
        var it = self.streams.valueIterator();
        while (it.next()) |ent| ent.got.deinit(alloc);
        self.streams.deinit(alloc);
    }

    fn str(rec: []const u8, s: abi.Span) []const u8 {
        return rec[s.off..][0..s.len];
    }

    fn write(self: *WtAnswerer, h: u64, data: []const u8, fin: bool) !void {
        if (try engine.wt.write(self.e, h, data, fin, false)) {
            _ = self.busies.fetchAdd(1, .monotonic);
            if (self.streams.getPtr(h)) |ent| ent.busy = true;
        }
    }

    fn handle(self: *WtAnswerer, rec: []const u8) !void {
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        const e = self.e;
        const h = ev.handle;
        switch (@as(abi.EventType, @fromBackingInt(@intCast(ev.type)))) {
            .wt_open => {
                const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
                if (!std.mem.eql(u8, str(rec, r.path), "/wt")) return error.WrongPath;
                // A one-way stream of the server's, written, ended and let
                // go at once: it still goes out whole.
                const s = try engine.wt.openStream(e, h, true);
                try self.write(s, "hello from server", true);
                try engine.wt.streamOp(e, s, .release, 0);
                _ = self.opens.fetchAdd(1, .monotonic);
            },
            .wt_stream => {
                const se: *const abi.WtStreamEvent = @ptrCast(@alignCast(rec.ptr));
                try self.streams.put(alloc, h, .{ .uni = se.flags & abi.WT_F_UNI != 0, .session = se.session });
            },
            .wt_data => {
                const de: *const abi.WtDataEvent = @ptrCast(@alignCast(rec.ptr));
                const ent = self.streams.getPtr(h) orelse return error.UnknownStream;
                const data = str(rec, de.data);
                const fin = de.flags & abi.WT_F_FIN != 0;
                if (ent.uni) {
                    try ent.got.appendSlice(alloc, data);
                    if (fin) {
                        var out: [64]u8 = undefined;
                        try engine.wt.sendDatagram(e, ent.session, try std.fmt.bufPrint(&out, "uni:{d}", .{ent.got.items.len}), false);
                        try self.forget(h);
                    }
                } else {
                    try self.write(h, data, fin);
                    if (fin) {
                        ent.done = true;
                        if (!ent.busy) try self.forget(h);
                    }
                }
            },
            .wt_datagram => {
                const de: *const abi.WtDatagramEvent = @ptrCast(@alignCast(rec.ptr));
                var out: [256]u8 = undefined;
                try engine.wt.sendDatagram(e, h, try std.fmt.bufPrint(&out, "echo:{s}", .{str(rec, de.data)}), false);
            },
            .wt_stream_reset => {
                const ce: *const abi.WtCodeEvent = @ptrCast(@alignCast(rec.ptr));
                self.reset_code.store(ce.code, .release);
                _ = self.resets.fetchAdd(1, .monotonic);
                const ent = self.streams.get(h) orelse return error.UnknownStream;
                try self.forget(h);
                try engine.wt.close(e, ent.session, 42, "bye");
            },
            .writable => {
                _ = self.writables.fetchAdd(1, .monotonic);
                const ent = self.streams.getPtr(h) orelse return error.UnknownStream;
                ent.busy = false;
                if (ent.done) try self.forget(h);
            },
            .wt_drain => _ = self.drains.fetchAdd(1, .monotonic),
            .wt_close => {
                const ce: *const abi.WtCloseEvent = @ptrCast(@alignCast(rec.ptr));
                self.close_code.store(ce.code, .release);
                self.close_by.store(ce.by, .release);
                // The session and its streams are gone for every call.
                if (engine.wt.openStream(e, h, false)) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                if (engine.wt.sendDatagram(e, h, "x", false)) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                var it = self.streams.iterator();
                while (it.next()) |kv| if (kv.value_ptr.session == h) {
                    if (engine.wt.write(e, kv.key_ptr.*, "x", false, false)) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                    _ = self.stale_ok.fetchAdd(1, .monotonic);
                };
                _ = self.closes.fetchAdd(1, .monotonic);
            },
            else => {},
        }
    }

    fn forget(self: *WtAnswerer, h: u64) !void {
        var kv = self.streams.fetchRemove(h) orelse return;
        kv.value.got.deinit(alloc);
        try engine.wt.streamOp(self.e, h, .release, 0);
    }
};

fn writeAll(s: *anole.webtransport.Stream, data: []const u8) !void {
    try s.writer().writeAll(data);
    try s.closeSend();
}

fn waitAtLeast(io: std.Io, v: *std.atomic.Value(u32), n: u32) !void {
    try wait.waitAtLeast(io, "the counter reached its count", v, n);
}

/// An engine with one WebTransport route (handler 9) on an HTTP/3
/// listener and its consumer thread (`WtAnswerer`), started for one test.
const WtFixture = struct {
    e: *engine.Engine,
    a: WtAnswerer,
    t: std.Thread,

    fn start(fx: *WtFixture) !void {
        const json =
            \\{"executors": 2, "timeouts": {"request_ms": 3000, "shutdown_ms": 2000},
            \\ "listeners": [{"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}, "http3": true}],
            \\ "routes": [{"path": "/wt", "webtransport": {"handler": 9, "datagram_queue": 8}}]}
        ;
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer e.destroy();
        const c = try e.attach(null, null, true);
        try e.start();
        fx.e = e;
        fx.a = .{ .e = e, .c = c };
        fx.t = try std.Thread.spawn(.{}, WtAnswerer.run, .{&fx.a});
    }

    fn stop(fx: *WtFixture) void {
        fx.a.stop.store(true, .release);
        fx.t.join();
        fx.e.destroy();
    }

    /// The HTTP/3 listener's UDP port (after the listeners').
    fn port(fx: *WtFixture) u16 {
        return fx.e.port(1);
    }

    fn finish(fx: *WtFixture) !void {
        try std.testing.expectEqual(@as(u32, 0), fx.a.failures.load(.acquire));
        try fx.e.drain();
        try std.testing.expect(fx.e.wait(stopWaitMs()));
    }
};

fn wtConnect(io: std.Io, port: u16) !*anole.h3.ClientConnection {
    return anole.h3.ClientConnection.connect(alloc, io, .{
        .host = "localhost",
        .address = try .parseIp4("127.0.0.1", port),
        .port = port,
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromSeconds(3),
        .webtransport = true,
    });
}

/// What a WebTransport claim works with: the consumer, one open session,
/// and the runtime's Io.
const WtCtx = struct {
    a: *WtAnswerer,
    session: *anole.webtransport.Session,
    io: std.Io,
};

/// Runs `claim` with one session to /wt on a fresh engine, then ends the
/// session and drains the engine.
fn wtRun(comptime claim: anytype) !void {
    var fx: WtFixture = undefined;
    try fx.start();
    defer fx.stop();
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    const Body = struct {
        fn go(a: *WtAnswerer, port: u16, io_: std.Io) !void {
            const conn = try wtConnect(io_, port);
            defer conn.close();
            const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
            defer session.deinit();
            try claim(WtCtx{ .a = a, .session = session, .io = io_ });
        }
    };
    var f = try io.concurrent(Body.go, .{ &fx.a, fx.port(), io });
    try f.await(io);
    try fx.finish();
}

const WtClaims = struct {
    /// WtAnswerer writes, ends and releases a one-way stream at WT_OPEN.
    fn serverUni(c: WtCtx) !void {
        const u = try c.session.acceptUniStream();
        defer u.release();
        const got = try u.reader().allocRemaining(alloc, .unlimited);
        defer alloc.free(got);
        try std.testing.expectEqualStrings("hello from server", got);
    }

    fn echo(c: WtCtx) !void {
        const s = try c.session.openStream();
        defer s.release();
        try s.writer().writeAll("ping");
        try s.closeSend();
        const back = try s.reader().allocRemaining(alloc, .unlimited);
        defer alloc.free(back);
        try std.testing.expectEqualStrings("ping", back);
    }

    fn uniInDatagramOut(c: WtCtx) !void {
        var dbuf: [2048]u8 = undefined;
        const s = try c.session.openUniStream();
        try s.writer().writeAll("uni-data");
        try s.closeSend();
        s.release();
        try std.testing.expectEqualStrings("uni:8", try c.session.receiveDatagram(&dbuf));
    }

    fn datagrams(c: WtCtx) !void {
        var dbuf: [2048]u8 = undefined;
        try c.session.sendDatagram("dg1");
        try std.testing.expectEqualStrings("echo:dg1", try c.session.receiveDatagram(&dbuf));
    }

    /// Written whole before any of the echo is read: the echo waits in
    /// the engine past the high-water mark (ANOLE_BUSY), and drains as it
    /// is read (ANOLE_EV_WRITABLE).
    fn busyWritable(c: WtCtx) !void {
        const big = try alloc.alloc(u8, 4 << 20);
        defer alloc.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 13);
        const s = try c.session.openStream();
        defer s.release();
        try writeAll(s, big);
        const back = try s.reader().allocRemaining(alloc, .unlimited);
        defer alloc.free(back);
        try std.testing.expectEqualSlices(u8, big, back);
        try std.testing.expect(c.a.busies.load(.acquire) > 0);
        try waitAtLeast(c.io, &c.a.writables, 1);
    }

    /// WtAnswerer closes the session (42, "bye") when a stream is reset.
    fn resetThenClose(c: WtCtx) !void {
        const session = c.session;
        const s = try session.openStream();
        defer s.release();
        try s.writer().writeAll("x");
        try s.writer().flush();
        // The echo says the server has the stream: a reset sent with
        // the stream's first bytes may arrive before them.
        var one: [1]u8 = undefined;
        try s.reader().readSliceAll(&one);
        s.reset(7);
        while (true) {
            const in = session.acceptStream() catch break;
            in.release();
        }
        const info = session.closeInfo().?;
        try std.testing.expectEqual(@as(u32, 42), info.code);
        try std.testing.expectEqualStrings("bye", info.reason);
        try std.testing.expectEqual(.peer, info.by);
        try waitAtLeast(c.io, &c.a.closes, 1);
        try std.testing.expectEqual(@as(u32, 7), c.a.reset_code.load(.acquire));
        try std.testing.expectEqual(abi.WT_CLOSED_LOCAL, c.a.close_by.load(.acquire));
    }
};

test "capi engine: WebTransport: a one-way stream the server writes, ends and releases at WT_OPEN reaches the client whole, not freed with its data before the session is up" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.serverUni);
}

test "capi engine: WebTransport: a bidirectional stream echoes" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.echo);
}

test "capi engine: WebTransport: a one-way stream in is answered by a datagram" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.uniInDatagramOut);
}

test "capi engine: WebTransport: datagrams echo" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.datagrams);
}

test "capi engine: WebTransport: a write past stream_high_water answers BUSY, and WRITABLE follows the drain" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.busyWritable);
}

test "capi engine: WebTransport: a client stream reset reaches the consumer with its code, and anole_wt_close sends code and reason" {
    if (comptime !features.http3) return error.SkipZigTest;
    try wtRun(WtClaims.resetThenClose);
}

test "capi engine: WebTransport: made-up session and stream handles are GONE, OVER or WRONG_KIND" {
    if (comptime !features.http3) return error.SkipZigTest;
    var fx: WtFixture = undefined;
    try fx.start();
    defer fx.stop();
    const e = fx.e;
    const forged_session: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 4) << 28) | 1;
    const forged_stream: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 5) << 28) | 1;
    try std.testing.expectError(error.Gone, engine.wt.openStream(e, forged_session, false));
    try std.testing.expectError(error.Over, engine.wt.close(e, forged_session, 0, ""));
    try std.testing.expectError(error.Gone, engine.wt.write(e, forged_stream, "x", false, false));
    try std.testing.expectError(error.Over, engine.wt.streamOp(e, forged_stream, .release, 0));
    // A request handle is not a session, and 0 is no handle: misuse.
    try std.testing.expectError(error.WrongKind, engine.wt.sendDatagram(e, 1, "x", false));
    try std.testing.expectError(error.WrongKind, engine.wt.sendDatagram(e, 0, "x", false));
    try fx.finish();
}

fn wtOpenKept(a: *WtAnswerer, port: u16, io: std.Io, keep: *?*anole.webtransport.Session, keep_conn: *?*anole.h3.ClientConnection) !void {
    const conn = try wtConnect(io, port);
    const session = conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" }) catch |err| {
        conn.close();
        return err;
    };
    // The test ends both (wtEnd), on success or failure.
    keep.* = session;
    keep_conn.* = conn;
    try waitAtLeast(io, &a.opens, 1);
}

fn wtEnd(session: *anole.webtransport.Session, conn: *anole.h3.ClientConnection) void {
    session.deinit();
    conn.close();
}

test "capi engine: WebTransport: the drain sends WT_DRAIN and closes an open session (close_on_drain), and wt_sessions goes back to 0" {
    if (comptime !features.http3) return error.SkipZigTest;
    var fx: WtFixture = undefined;
    try fx.start();
    defer fx.stop();
    const e = fx.e;
    const a = &fx.a;
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var session: ?*anole.webtransport.Session = null;
    var conn: ?*anole.h3.ClientConnection = null;
    {
        var f = try io.concurrent(wtOpenKept, .{ a, fx.port(), io, &session, &conn });
        f.await(io) catch |err| {
            if (session) |s| {
                var end = try io.concurrent(wtEnd, .{ s, conn.? });
                end.await(io);
            }
            return err;
        };
    }
    try std.testing.expectEqual(@as(u64, 1), e.stats().wt_sessions);

    // The drain: the open session hears it, then closes (close_on_drain).
    try e.drain();
    const waited = blk: {
        var wait_drain = try io.concurrent(waitAtLeast, .{ io, &a.closes, 1 });
        break :blk wait_drain.await(io);
    };
    var end = try io.concurrent(wtEnd, .{ session.?, conn.? });
    end.await(io);
    try waited;
    try std.testing.expect(a.drains.load(.acquire) >= 1);
    try std.testing.expect(e.wait(stopWaitMs()));
    try std.testing.expectEqual(@as(u64, 0), e.stats().wt_sessions);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
}

/// A consumer for the TLS test: answers every request with the client's
/// certificate from the record (the DER), or "none".
const PeerAnswerer = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),

    fn run(self: *PeerAnswerer) void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                self.handle(buf[off..][0..ev.len]) catch |err| {
                    std.debug.print("peer answer failed: {t}\n", .{err});
                    _ = self.failures.fetchAdd(1, .monotonic);
                };
                off += ev.len;
            }
        }
    }

    fn handle(self: *PeerAnswerer, rec: []const u8) !void {
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        if (@as(abi.EventType, @fromBackingInt(@intCast(ev.type))) != .request) return;
        const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
        const has = r.flags & abi.REQ_PEER_CERT != 0;
        if (has != (r.peer_cert.len != 0)) return error.FlagAndSpanDisagree;
        var body: []const u8 = "none";
        if (r.peer_cert.len != 0) {
            if (r.peer_cert.off + r.peer_cert.len > rec.len) return error.BadSpan;
            body = rec[r.peer_cert.off..][0..r.peer_cert.len];
        }
        try engine.respond(self.e, ev.handle, 200, &.{}, body, false);
    }
};

const tls_testing = if (features.tls == .boringssl) @import("../tls/testing.zig") else struct {};

fn h2Get(io: std.Io, port: u16, ca: []const u8, client: ?*const anole.tls.Pem) ![]u8 {
    const conn = try anole.h2.ClientConnection.connect(alloc, io, .{
        .host = "localhost",
        .port = port,
        .tls = .{
            .ca = .{ .pem = ca },
            .client_certificate = if (client) |p| .{ .pem = .{ .cert = p.cert, .key = p.key } } else null,
        },
    });
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/peer" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    if (s.status != 200) return error.UnexpectedStatus;
    return s.reader().allocRemaining(alloc, .unlimited);
}

fn h3Get(io: std.Io, port: u16, ca: []const u8, client: ?*const anole.tls.Pem) ![]u8 {
    const conn = try anole.h3.ClientConnection.connect(alloc, io, .{
        .host = "localhost",
        .address = try .parseIp4("127.0.0.1", port),
        .port = port,
        .tls = .{
            .ca = .{ .pem = ca },
            .client_certificate = if (client) |p| .{ .pem = .{ .cert = p.cert, .key = p.key } } else null,
        },
        .connect_timeout = .fromSeconds(3),
    });
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/peer" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    if (s.status != 200) return error.UnexpectedStatus;
    return s.reader().allocRemaining(alloc, .unlimited);
}

/// A request one side's TLS must refuse: it fails with one of `refusals`;
/// a cancel goes up (SAFETY C3), and an answer is `served`.
fn expectRefused(r: anyerror![]u8, comptime refusals: []const anyerror, served: anyerror) !void {
    const body = r catch |err| {
        if (err == error.Canceled) return error.Canceled;
        for (refusals) |want| if (err == want) return;
        std.debug.print("refused with {t}, not one of {any}\n", .{ err, refusals });
        return error.TestUnexpectedError;
    };
    alloc.free(body);
    return served;
}

/// Waits until the TCP listener at `port` serves the certificate `ca`
/// names.
fn waitServes(io: std.Io, port: u16, ca: []const u8, client: *const anole.tls.Pem) !void {
    const C = struct {
        io: std.Io,
        port: u16,
        ca: []const u8,
        client: *const anole.tls.Pem,
        fn serves(c: @This()) error{Canceled}!bool {
            const body = h2Get(c.io, c.port, c.ca, c.client) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return false,
            };
            alloc.free(body);
            return true;
        }
    };
    try wait.waitUntil(io, "the listener serves the reloaded certificate", C{ .io = io, .port = port, .ca = ca, .client = client }, C.serves);
}

/// Three self-signed pairs (the server's, a client's, and the next server
/// certificate), the server's in files, and an engine with two TLS
/// listeners: the first (with HTTP/3) requires a client certificate, the
/// second requests one; its consumer (`PeerAnswerer`) answers with the
/// client's certificate.
const TlsFixture = struct {
    server: anole.tls.Pem,
    client: anole.tls.Pem,
    next: anole.tls.Pem,
    tmp: std.testing.TmpDir,
    dir_path: [:0]u8,
    e: *engine.Engine,
    a: PeerAnswerer,
    t: std.Thread,

    fn start(fx: *TlsFixture, signals: bool) !void {
        fx.server = try anole.tls.selfSigned(alloc, .{});
        errdefer fx.server.deinit(alloc);
        fx.client = try anole.tls.selfSigned(alloc, .{});
        errdefer fx.client.deinit(alloc);
        fx.next = try anole.tls.selfSigned(alloc, .{});
        errdefer fx.next.deinit(alloc);

        fx.tmp = std.testing.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        const io0 = std.testing.io;
        try fx.tmp.dir.writeFile(io0, .{ .sub_path = "server.pem", .data = fx.server.cert });
        try fx.tmp.dir.writeFile(io0, .{ .sub_path = "server.key", .data = fx.server.key });
        try fx.tmp.dir.writeFile(io0, .{ .sub_path = "client-ca.pem", .data = fx.client.cert });
        fx.dir_path = try fx.tmp.dir.realPathFileAlloc(io0, ".", alloc);
        errdefer alloc.free(fx.dir_path);

        // Files for the listener that SIGHUP rereads; PEM text for the
        // other one and for the client CA of the first. Paths go through
        // JSON's escaping too (Windows' backslashes).
        const cert_file = try std.fs.path.join(alloc, &.{ fx.dir_path, "server.pem" });
        defer alloc.free(cert_file);
        const key_file = try std.fs.path.join(alloc, &.{ fx.dir_path, "server.key" });
        defer alloc.free(key_file);
        const ca_file = try std.fs.path.join(alloc, &.{ fx.dir_path, "client-ca.pem" });
        defer alloc.free(ca_file);
        const json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 2, "timeouts": {{"request_ms": 3000, "shutdown_ms": 1000}},
            \\ "listeners": [
            \\   {{"address": "127.0.0.1", "port": 0, "http3": true, "tls": {{"cert_file": {f}, "key_file": {f},
            \\     "client_auth": "require", "client_ca_pem": {f}}}}},
            \\   {{"address": "127.0.0.1", "port": 0, "tls": {{"cert_pem": {f}, "key_pem": {f},
            \\     "client_auth": "request", "client_ca_file": {f}}}}}],
            \\ "routes": [{{"method": "GET", "path": "/peer", "handler": 1}}]}}
        , .{ std.json.fmt(cert_file, .{}), std.json.fmt(key_file, .{}), std.json.fmt(fx.client.cert, .{}), std.json.fmt(fx.server.cert, .{}), std.json.fmt(fx.server.key, .{}), std.json.fmt(ca_file, .{}) });
        defer alloc.free(json);
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(json, signals, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer e.destroy();
        const c = try e.attach(null, null, true);
        try e.start();
        fx.e = e;
        fx.a = .{ .e = e, .c = c };
        fx.t = try std.Thread.spawn(.{}, PeerAnswerer.run, .{&fx.a});
    }

    fn stop(fx: *TlsFixture) void {
        fx.a.stop.store(true, .release);
        fx.t.join();
        fx.e.destroy();
        alloc.free(fx.dir_path);
        fx.tmp.cleanup();
        fx.next.deinit(alloc);
        fx.client.deinit(alloc);
        fx.server.deinit(alloc);
    }

    fn required(fx: *const TlsFixture) u16 {
        return fx.e.port(0);
    }
    fn requested(fx: *const TlsFixture) u16 {
        return fx.e.port(1);
    }
    /// The first listener's UDP port (after the listeners').
    fn quic(fx: *const TlsFixture) u16 {
        return fx.e.port(2);
    }

    /// The client certificate's DER, as the records carry it.
    fn clientDer(fx: *const TlsFixture, io: std.Io) !std.crypto.Certificate.Bundle {
        return tls_testing.bundleFromPem(alloc, std.Io.Clock.real.now(io).toSeconds(), fx.client.cert);
    }

    /// Runs `claim` (`fn (*TlsFixture, std.Io) !void`) on a fresh fixture,
    /// then drains the engine.
    fn run(comptime claim: anytype, signals: bool) !void {
        var fx: TlsFixture = undefined;
        try fx.start(signals);
        defer fx.stop();
        const rt = try zio.Runtime.init(alloc, .{});
        defer rt.deinit();
        const io = rt.io();
        var f = try io.concurrent(claim, .{ &fx, io });
        try f.await(io);
        try std.testing.expectEqual(@as(u32, 0), fx.a.failures.load(.acquire));
        try fx.e.drain();
        try std.testing.expect(fx.e.wait(stopWaitMs()));
    }
};

/// How a client sees the server refuse its certificate: the alert itself
/// when it comes during the handshake, or a closed connection when it
/// comes after the client's side of the handshake is done (TLS 1.3, QUIC).
/// Which one depends on timing, so either is a refusal (D5).
const server_refusals = &[_]anyerror{ error.ConnectionClosed, error.TlsAlertCertificateRequired, error.TlsAlertUnknownCa, error.TlsAlertBadCertificate, error.TlsAlertHandshakeFailure };
/// Over QUIC the client's own handshake can also end on the refusal: a
/// CONNECTION_CLOSE that lands before the client's handshake completes
/// ends its wait with HandshakeFailed (h3/client.zig waitHandshake). The
/// client is usually open by then, but which comes first is timing (D5).
const h3_server_refusals = &(server_refusals.* ++ [_]anyerror{error.HandshakeFailed});
/// How a client refuses a server certificate its CA did not sign.
const client_refusals = &[_]anyerror{error.CertificateIssuerNotFound};

const TlsClaims = struct {
    fn require(fx: *TlsFixture, io: std.Io) !void {
        var bundle = try fx.clientDer(io);
        defer bundle.deinit(alloc);
        try expectRefused(h2Get(io, fx.required(), fx.server.cert, null), server_refusals, error.ServedWithoutClientCertificate);
        {
            const body = try h2Get(io, fx.required(), fx.server.cert, &fx.client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, bundle.bytes.items, body);
        }
        // A certificate no client CA signed is refused.
        try expectRefused(h2Get(io, fx.required(), fx.server.cert, &fx.next), server_refusals, error.ServedWithUnknownCertificate);
    }

    fn request(fx: *TlsFixture, io: std.Io) !void {
        var bundle = try fx.clientDer(io);
        defer bundle.deinit(alloc);
        {
            const body = try h2Get(io, fx.requested(), fx.server.cert, null);
            defer alloc.free(body);
            try std.testing.expectEqualStrings("none", body);
        }
        {
            const body = try h2Get(io, fx.requested(), fx.server.cert, &fx.client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, bundle.bytes.items, body);
        }
    }

    fn http3(fx: *TlsFixture, io: std.Io) !void {
        var bundle = try fx.clientDer(io);
        defer bundle.deinit(alloc);
        try expectRefused(h3Get(io, fx.quic(), fx.server.cert, null), h3_server_refusals, error.ServedWithoutClientCertificate);
        const body = try h3Get(io, fx.quic(), fx.server.cert, &fx.client);
        defer alloc.free(body);
        try std.testing.expectEqualSlices(u8, bundle.bytes.items, body);
    }

    fn setCertificate(fx: *TlsFixture, io: std.Io) !void {
        var bundle = try fx.clientDer(io);
        defer bundle.deinit(alloc);
        const e = fx.e;
        // From PEM: both listeners and HTTP/3 serve the next certificate.
        try e.setCertificate(.{ .pem = .{ .cert = fx.next.cert, .key = fx.next.key } });
        try waitServes(io, fx.required(), fx.next.cert, &fx.client);
        {
            const body = try h3Get(io, fx.quic(), fx.next.cert, &fx.client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, bundle.bytes.items, body);
        }
        try expectRefused(h2Get(io, fx.requested(), fx.server.cert, &fx.client), client_refusals, error.OldCertificateServed);

        // From files: the server's certificate again.
        const cert_path = try std.fs.path.join(alloc, &.{ fx.dir_path, "server.pem" });
        defer alloc.free(cert_path);
        const key_path = try std.fs.path.join(alloc, &.{ fx.dir_path, "server.key" });
        defer alloc.free(key_path);
        try e.setCertificate(.{ .files = .{ .cert_path = cert_path, .key_path = key_path } });
        try waitServes(io, fx.requested(), fx.server.cert, &fx.client);
        // A bad one leaves the certificate in place.
        try std.testing.expect(std.meta.isError(e.setCertificate(.{ .pem = .{ .cert = "not a certificate", .key = fx.next.key } })));
        try waitServes(io, fx.requested(), fx.server.cert, &fx.client);
    }

    fn sighup(fx: *TlsFixture, io: std.Io) !void {
        // The files now hold the other certificate; SIGHUP reads them.
        var dir = try std.Io.Dir.cwd().openDir(io, fx.dir_path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "server.pem", .data = fx.next.cert });
        try dir.writeFile(io, .{ .sub_path = "server.key", .data = fx.next.key });
        try std.posix.raise(.HUP);
        try waitServes(io, fx.required(), fx.next.cert, &fx.client);
    }
};

test "capi engine: client_auth require refuses a connection without a certificate or with an unknown one, and the record carries the client's DER" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try TlsFixture.run(TlsClaims.require, false);
}

test "capi engine: client_auth request answers without a certificate (none) and carries the client's DER with one" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try TlsFixture.run(TlsClaims.request, false);
}

test "capi engine: mutual TLS over HTTP/3 refuses a connection without a certificate and carries the client's DER" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try TlsFixture.run(TlsClaims.http3, false);
}

test "capi engine: anole_server_set_certificate from PEM and from files swaps the certificate; a bad one leaves it in place" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try TlsFixture.run(TlsClaims.setCertificate, false);
}

// Not supported on Windows, which has no SIGHUP: an app there reloads
// with anole_server_set_certificate.
test "capi engine: SIGHUP rereads the certificate files" {
    if (comptime !features.http3 or !features.http2 or builtin.os.tag == .windows) return error.SkipZigTest;
    try TlsFixture.run(TlsClaims.sighup, true);
}

/// The handle a consumer stored in `held`, once it has.
/// How long a test waits for an engine to stop: the wait helper's deadline.
fn stopWaitMs() i32 {
    return @intCast(wait.deadlineMs());
}

fn waitHeld(io: std.Io, held: *std.atomic.Value(u64)) !u64 {
    return wait.waitNonZero(io, "the consumer holds the request", held);
}

/// Holds a control call inside the engine (`engine.test_control_hook`)
/// until the test lets it go.
const ControlHold = struct {
    var entered: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;

    fn hook() void {
        entered.set(engine.threadedIo());
        go.waitUncancelable(engine.threadedIo());
    }

    fn reload(e: *engine.Engine, out: *?anyerror) void {
        e.reloadCertificates() catch |err| {
            out.* = err;
        };
    }
};

test "capi engine: a reload from another thread holds the server's stop until it returns" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const json =
        \\{"executors": 1, "timeouts": {"shutdown_ms": 200},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}}]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = try engine.Engine.create(json, false, &why);
    defer e.destroy();
    try e.start();
    const tio = engine.threadedIo();
    ControlHold.entered = .unset;
    ControlHold.go = .unset;
    engine.test_control_hook = &ControlHold.hook;
    var result: ?anyerror = null;
    const t = try std.Thread.spawn(.{}, ControlHold.reload, .{ e, &result });
    // The reload holds the server; nothing else is held.
    ControlHold.entered.waitUncancelable(tio);
    engine.test_control_hook = null;
    try e.drain();
    // Had the stop not waited for the reload, the run thread would free
    // the server and exit (its stack, which held the server, with it)
    // within the 200 ms shutdown: it must still be running past that. A
    // slow machine can only make this miss the bug, never fail.
    const held = wait.expectStays(tio, "the stop waits while the reload holds the server", &e.stopped, struct {
        fn unset(ev: *std.Io.Event) bool {
            return !ev.isSet();
        }
    }.unset, .fromMilliseconds(400));
    if (e.stopped.isSet()) {
        e.thread.?.join();
        e.thread = null;
    }
    ControlHold.go.set(tio);
    t.join();
    try held;
    // The reload ran on the live server (a self-signed listener reloads in
    // place), and the stop went on after it.
    try std.testing.expectEqual(@as(?anyerror, null), result);
    try std.testing.expect(e.wait(stopWaitMs()));
    // After the stop: refused, never followed into a freed server.
    try std.testing.expectError(error.State, e.reloadCertificates());
    try e.drain();
}

/// Holds one thread's wake inside an executor's `IoGate`
/// (`engine.test_io_hook`) until the test lets it go; other threads pass.
const WakeHold = struct {
    var thread: std.atomic.Value(std.Thread.Id) = .init(0);
    var entered: std.Io.Event = .unset;
    var go: std.Io.Event = .unset;

    fn hook() void {
        if (std.Thread.getCurrentId() != thread.load(.acquire)) return;
        entered.set(engine.threadedIo());
        go.waitUncancelable(engine.threadedIo());
    }

    /// A consumer thread's wake of executor 0 (as an answer makes).
    fn wake(e: *engine.Engine) void {
        thread.store(std.Thread.getCurrentId(), .release);
        const x = &e.execs[0];
        x.setEvent(&x.kick);
    }
};

test "capi engine: a wake from a consumer thread under way holds the server's stop until it returns" {
    const json =
        \\{"executors": 1, "timeouts": {"shutdown_ms": 200},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = try engine.Engine.create(json, false, &why);
    defer e.destroy();
    _ = try e.attach(null, null, true);
    try e.start();
    const tio = engine.threadedIo();
    WakeHold.entered = .unset;
    WakeHold.go = .unset;
    engine.test_io_hook = &WakeHold.hook;
    defer engine.test_io_hook = null;
    const t = try std.Thread.spawn(.{}, WakeHold.wake, .{e});
    // The wake is inside the gate, about to call into the runtime.
    WakeHold.entered.waitUncancelable(tio);
    try e.drain();
    // Had the stop not waited for it, the run thread would free the runtime
    // the wake is about to use, and set `stopped`.
    try std.testing.expect(!e.wait(400));
    WakeHold.go.set(tio);
    t.join();
    try std.testing.expect(e.wait(stopWaitMs()));
    // After the stop: a wake is skipped, never followed into the freed
    // runtime.
    const x = &e.execs[0];
    x.setEvent(&x.kick);
}

const Racer = struct {
    e: *engine.Engine,
    stop: *std.atomic.Value(bool),
    which: u8,
    /// Calls this racer has made.
    calls: *std.atomic.Value(u64),

    fn run(r: Racer) void {
        var n: usize = 0;
        while (!r.stop.load(.acquire)) : (n += 1) {
            switch (r.which) {
                0 => r.e.reloadCertificates() catch {},
                1 => r.e.setCertificate(.dev_self_signed) catch {},
                else => if (n % 64 == 63) r.e.drain() catch {} else r.e.reloadCertificates() catch {},
            }
            _ = r.calls.fetchAdd(1, .release);
        }
    }

    /// The racers' call counts, and where they stood at the stop.
    const Past = struct {
        calls: *const [3]std.atomic.Value(u64),
        at: [3]u64,
        /// Every racer has made a call it started after `at` was taken.
        fn passed(c: Past) bool {
            for (c.calls, c.at) |*n, at| if (n.load(.acquire) < at + 2) return false;
            return true;
        }
    };
};

test "capi engine: drain and reloads from other threads race the stop, many times over" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const json =
        \\{"executors": 2, "timeouts": {"shutdown_ms": 100},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}}]}
    ;
    const tio = engine.threadedIo();
    for (0..24) |round| {
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = try engine.Engine.create(json, false, &why);
        defer e.destroy();
        try e.start();
        var stop: std.atomic.Value(bool) = .init(false);
        var calls: [3]std.atomic.Value(u64) = @splat(.init(0));
        var threads: [3]std.Thread = undefined;
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Racer.run, .{Racer{ .e = e, .stop = &stop, .which = @intCast(i), .calls = &calls[i] }});
        // The stop lands at a different point of the racers' calls each
        // round (load spread on purpose, no claim on time).
        try std.Io.sleep(tio, .fromMicroseconds(@intCast(round * 400)), .awake);
        try e.drain();
        try std.testing.expect(e.wait(stopWaitMs()));
        // Past the stop the calls are refused: each racer makes one whole
        // call that began after the stop (two counted past this point).
        var at: [3]u64 = undefined;
        for (&at, &calls) |*a, *n| a.* = n.load(.acquire);
        wait.waitUntil(tio, "every racer called past the stop", Racer.Past{ .calls = &calls, .at = at }, Racer.Past.passed) catch |err| {
            stop.store(true, .release);
            for (threads) |t| t.join();
            return err;
        };
        stop.store(true, .release);
        for (threads) |t| t.join();
        try std.testing.expectError(error.State, e.reloadCertificates());
    }
}

test "parse: proxy, request, response, http2, errors groups reach ServerOptions" {
    const json =
        \\{"executors": 1,
        \\ "timeouts": {"request_ms": null, "read_header_ms": 3000, "write_ms": 2000, "idle_park_ms": null, "shutdown_ms": 150},
        \\ "limits": {"max_head_size": 8192, "max_header_count": 40, "max_requests_per_connection": 9, "ws_max_message": 65536},
        \\ "proxy": {"trusted_hops": 2, "trust_forwarded_host": true},
        \\ "request": {"require_host": false, "keep_buffers": true},
        \\ "response": {"date": false, "brotli_quality": 3, "default_content_type": "json"},
        \\ "http2": {"max_concurrent_streams": 7},
        \\ "errors": "text",
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = try engine.Engine.create(json, false, &why);
    defer e.destroy();
    try e.start();
    const cfg = e.app.?.server.config;
    try std.testing.expectEqual(@as(?std.Io.Duration, null), cfg.timeout.request);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(3), cfg.timeout.read_header.?);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(2), cfg.timeout.write.?);
    try std.testing.expectEqual(@as(?std.Io.Duration, null), cfg.timeout.idle_park);
    try std.testing.expectEqual(std.Io.Duration.fromMilliseconds(150), cfg.timeout.shutdown.?);
    try std.testing.expectEqual(@as(usize, 8192), cfg.request.buffer_size);
    try std.testing.expectEqual(@as(usize, 40), cfg.request.max_header_count);
    try std.testing.expectEqual(@as(?usize, 9), cfg.timeout.request_count);
    try std.testing.expectEqual(@as(usize, 65536), cfg.request.ws_max_message);
    try std.testing.expectEqual(@as(usize, 2), cfg.trusted_proxy_hops);
    try std.testing.expect(cfg.trust_forwarded_host);
    try std.testing.expect(!cfg.request.require_host);
    try std.testing.expect(cfg.request.keep_buffers_between_requests);
    try std.testing.expect(!cfg.response.date);
    try std.testing.expectEqual(@as(u4, 3), cfg.response.brotli_quality);
    try std.testing.expectEqual(@as(?anole.http.ContentType, .json), cfg.response.default_content_type);
    try std.testing.expectEqual(@as(u32, 7), cfg.http2.max_concurrent_streams);
    try std.testing.expectEqual(anole.http.ErrorFormat.text, cfg.errors);
    try e.drain();
    try std.testing.expect(e.wait(stopWaitMs()));
}

// ---------------------------------------------------------------------------
// Rings, rooms and records (C ABI 0.7)

/// An engine with one executor, a consumer and a ring of `queue` entries,
/// started, for the tests that post records straight onto its ring.
fn ringEngine(comptime queue: u32) !struct { *engine.Engine, *engine.Consumer } {
    const json = std.fmt.comptimePrint(
        \\{{"executors": 1, "limits": {{"queue": {d}}}, "timeouts": {{"shutdown_ms": 200}},
        \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
        \\ "routes": [{{"path": "/x", "handler": 1}}]}}
    , .{queue});
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    errdefer e.destroy();
    const c = try e.attach(null, null, false);
    try e.start();
    return .{ e, c };
}

/// Counts what a poll returns, by event type.
fn drainCounts(c: *engine.Consumer, counts: *[64]u32, want: u32) !void {
    const Drain = struct {
        c: *engine.Consumer,
        counts: *[64]u32,
        want: u32,
        total: u32 = 0,
        buf: [64 * 1024]u8 align(8) = undefined,

        /// One poll, counted; done once `want` events came.
        fn more(d: *@This()) error{TooBig}!bool {
            var need: u32 = 0;
            const n = engine.poll(d.c, &d.buf, true, &need) catch return error.TooBig;
            var off: usize = 0;
            while (off < n) {
                // SAFETY: `poll` writes whole records into `buf` (8-aligned),
                // each starting with an Event header and `len` a multiple of
                // 8, so every `off` reached here starts an aligned Event.
                const ev: *const abi.Event = @ptrCast(@alignCast(&d.buf[off]));
                if (ev.type < d.counts.len) d.counts[ev.type] += 1;
                d.total += 1;
                off += ev.len;
            }
            return d.total >= d.want;
        }
    };
    const d = try alloc.create(Drain);
    defer alloc.destroy(d);
    d.* = .{ .c = c, .counts = counts, .want = want };
    try wait.waitUntil(engine.threadedIo(), "the consumer polled every event it waits for", d, Drain.more);
}

fn postMany(x: *engine.Exec, n: u32, posted: *std.atomic.Value(u32), stop: *const std.atomic.Value(bool)) std.Io.Cancelable!void {
    for (0..n) |_| {
        // A canceled wait for room ends only that post: the test's stop
        // ends the loop.
        if (stop.load(.acquire)) return;
        const rec = engine.newRecord(@sizeOf(abi.Event), .writable, 7) catch return;
        x.postRecord(rec, true);
        _ = posted.fetchAdd(1, .release);
    }
}

test "capi engine: a full ring holds records back until the consumer polls, and none is lost" {
    const e, const c = try ringEngine(2);
    defer e.destroy();
    const x = &e.execs[0];
    var posted: std.atomic.Value(u32) = .init(0);
    var stop: std.atomic.Value(bool) = .init(false);
    // One executor: the task runs on it.
    var f = try e.io.concurrent(postMany, .{ x, 8, &posted, &stop });
    // A failed wait stops the poster before the engine goes; after the
    // await below this does nothing.
    defer {
        stop.store(true, .release);
        f.cancel(e.io) catch {};
    }
    // The consumer does not poll: two fit the ring, and the task waits for
    // room (announced on the room futex), so no third goes in.
    const Parked = struct {
        posted: *std.atomic.Value(u32),
        x: *engine.Exec,
        fn waiting(p: @This()) bool {
            return p.posted.load(.acquire) == 2 and p.x.room_waiters.load(.seq_cst) == 1;
        }
    };
    try wait.waitUntil(engine.threadedIo(), "two posted, and the poster waits for room", Parked{ .posted = &posted, .x = x }, Parked.waiting);
    // While nobody polls, no third goes in.
    try wait.expectStays(engine.threadedIo(), "the full ring holds the third record back", &posted, struct {
        fn two(p: *std.atomic.Value(u32)) bool {
            return p.load(.acquire) == 2;
        }
    }.two, wait.short_window);
    // Polling makes room, and all eight arrive.
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 8);
    try f.await(e.io);
    try std.testing.expectEqual(@as(u32, 8), counts[@backingInt(abi.EventType.writable)]);
}

fn postAdvisory(x: *engine.Exec) std.Io.Cancelable!void {
    // The ring fills with records that wait for room...
    for (0..2) |_| x.postRecord(engine.newRecord(@sizeOf(abi.Event), .body, 1) catch return, true);
    // ...and these must still arrive: nothing is dropped for a full ring.
    for (0..4) |i| x.postAbort(100 + i, abi.ABORT_CLIENT, 0);
    for (0..2) |i| x.postEvent(.writable, 200 + i);
}

test "capi engine: advisory events are never dropped" {
    const e, const c = try ringEngine(2);
    defer e.destroy();
    const x = &e.execs[0];
    var f = try e.io.concurrent(postAdvisory, .{x});
    // A failed drain collects the poster before the engine goes; after the
    // await below this does nothing. The poster never waits for room (the
    // two records fit the empty ring of 2, and the advisory events take the
    // overflow list when it is full), so the cancel cannot be swallowed.
    defer f.cancel(e.io) catch {};
    // From another thread too: the overflow list takes it.
    x.postEvent(.writable, 300);
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 9);
    try f.await(e.io);
    try std.testing.expectEqual(@as(u32, 2), counts[@backingInt(abi.EventType.body)]);
    try std.testing.expectEqual(@as(u32, 4), counts[@backingInt(abi.EventType.abort)]);
    try std.testing.expectEqual(@as(u32, 3), counts[@backingInt(abi.EventType.writable)]);
}

fn postSentMany(x: *engine.Exec, n: u32) std.Io.Cancelable!void {
    for (0..n) |i| {
        const rec = engine.newSent("data") catch return;
        x.postSentRec(1000 + i, rec);
    }
}

test "capi engine: SENT is never lost to a full ring" {
    const e, const c = try ringEngine(8);
    defer e.destroy();
    const x = &e.execs[0];
    var f = try e.io.concurrent(postSentMany, .{ x, 64 });
    // The consumer does not poll while all 64 are posted (the poster never
    // waits for room: SENT records go around the ring).
    try f.await(e.io);
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 64);
    try std.testing.expectEqual(@as(u32, 64), counts[@backingInt(abi.EventType.sent)]);
}

fn getStatus(io: std.Io, port: u16, path: []const u8) !u16 {
    const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    return s.status;
}

fn readyzCheck(io: std.Io, e: *engine.Engine) !void {
    const pub_port = e.port(0);
    const admin_port = e.port(1);
    // The check starts not ready; the routes are on the admin listener only.
    try std.testing.expectEqual(@as(u16, 503), try getStatus(io, admin_port, "/readyz"));
    try std.testing.expectEqual(@as(u16, 200), try getStatus(io, admin_port, "/healthz"));
    try std.testing.expectEqual(@as(u16, 404), try getStatus(io, pub_port, "/readyz"));
    try e.setReady("app", true);
    try std.testing.expectEqual(@as(u16, 200), try getStatus(io, admin_port, "/readyz"));
    try std.testing.expectError(error.UnknownCheck, e.setReady("nope", true));
    try e.setReady("app", false);
    try std.testing.expectEqual(@as(u16, 503), try getStatus(io, admin_port, "/readyz"));
}

test "capi engine: /readyz honours readiness checks and the health listener" {
    if (comptime !features.http2) return error.SkipZigTest;
    const json =
        \\{"executors": 1, "timeouts": {"shutdown_ms": 200},
        \\ "listeners": [{"name": "public", "address": "127.0.0.1", "port": 0},
        \\               {"name": "admin", "address": "127.0.0.1", "port": 0}],
        \\ "observe": {"health": {"checks": ["app"], "listener": "admin"}}}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    try e.start();
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(readyzCheck, .{ io, e });
    try f.await(io);
    try e.drain();
    try std.testing.expect(e.wait(stopWaitMs()));
}

test "capi engine: a request cut by the drain's deadline aborts with reason DRAIN" {
    if (comptime !features.http2) return error.SkipZigTest;
    const json = "{\"executors\": 2, \"timeouts\": {\"request_ms\": 10000, \"shutdown_ms\": 200}," ++
        "\"listeners\": [{\"address\": \"127.0.0.1\", \"port\": 0}]," ++ routes ++ "}";
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    var a: Answerer = .{ .e = e, .c = c, .file_path = "" };
    const t = try std.Thread.spawn(.{}, Answerer.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(drainCheck, .{ &a, e, e.port(0), io });
    try f.await(io);
    try std.testing.expect(e.wait(stopWaitMs()));
}

fn drainCheck(a: *Answerer, e: *engine.Engine, port: u16, io: std.Io) !void {
    const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
    defer conn.close();
    a.held.store(0, .release);
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/hold" },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    const held = try wait.waitNonZero(io, "the consumer holds the request", &a.held);
    // The drain's deadline (shutdown_ms) cuts the request nobody answered.
    try e.drain();
    try wait.waitEqual(io, "the consumer heard the held request's ABORT", &a.last_abort, held);
    try std.testing.expectEqual(@as(u32, abi.ABORT_DRAIN), a.last_abort_reason.load(.acquire));
}

test "capi: every ServerError and TlsLoadError name is an ABI error token" {
    // The server design's named error sets (`anole.ServerError`,
    // `anole.TlsLoadError`): their member names are the tokens verbatim.
    if (comptime !@hasDecl(anole, "ServerError")) return error.SkipZigTest;
    inline for (.{ anole.ServerError, anole.TlsLoadError }) |Set| {
        const names = @typeInfo(Set).error_set.error_names.?;
        inline for (names) |name| {
            var found = false;
            for (abi.error_names) |t| found = found or std.mem.eql(u8, t, name);
            if (!found) {
                std.debug.print("{s} is not in abi.error_names\n", .{name});
                return error.NotAToken;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// WebSocket handshakes decided by the consumer (ANOLE_EV_WS_UPGRADE)

/// A consumer for "accept": "consumer" routes. `/decide?accept`: accepts
/// with the subprotocol "b" and a cookie and sends a message at once;
/// `?refuse`: 401 with a body; `?silent`: holds the request until its 504.
/// `/app` takes plain requests (route 11) and handshakes (route 12);
/// `/plain` (route 13) holds its request for the test to answer.
const WsDecider = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    opens: std.atomic.Value(u32) = .init(0),
    upgrades: std.atomic.Value(u32) = .init(0),
    plains: std.atomic.Value(u32) = .init(0),
    closes: std.atomic.Value(u32) = .init(0),
    close_code: std.atomic.Value(u32) = .init(0),
    held: std.atomic.Value(u64) = .init(0),
    aborts: std.atomic.Value(u32) = .init(0),

    fn run(self: *WsDecider) void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                self.handle(buf[off..][0..ev.len]) catch |err| {
                    std.debug.print("ws decider failed: {t}\n", .{err});
                    _ = self.failures.fetchAdd(1, .monotonic);
                };
                off += ev.len;
            }
        }
    }

    fn str(rec: []const u8, s: abi.Span) []const u8 {
        return rec[s.off..][0..s.len];
    }

    fn handle(self: *WsDecider, rec: []const u8) !void {
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        const e = self.e;
        const h = ev.handle;
        switch (@as(abi.EventType, @fromBackingInt(@intCast(ev.type)))) {
            .ws_upgrade => {
                _ = self.upgrades.fetchAdd(1, .monotonic);
                const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
                const query = str(rec, r.query);
                if (std.mem.eql(u8, query, "accept") or r.route_id == 12) {
                    const ws = try engine.wsAccept(e, h, if (r.route_id == 12) "" else "b", &.{.{ .name = .of("Set-Cookie"), .value = .of("s=1") }});
                    // Queued before the handshake's answer is out: it must
                    // arrive first, and the request handle is stale.
                    _ = try engine.ws.send(e, ws, abi.WS_TEXT, "first", false);
                    if (engine.respond(e, h, 200, &.{}, "", false)) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                } else if (std.mem.eql(u8, query, "refuse")) {
                    try engine.respond(e, h, 401, &.{.{ .name = .of("content-type"), .value = .of("text/plain") }}, "no thanks", false);
                } else if (std.mem.eql(u8, query, "bad-subprotocol")) {
                    try std.testing.expectError(error.Invalid, engine.wsAccept(e, h, "zzz", &.{}));
                    try std.testing.expectError(error.Invalid, engine.wsAccept(e, h, "", &.{.{ .name = .of("Sec-WebSocket-Accept"), .value = .of("x") }}));
                    // Nothing was taken: the request is still owed an answer.
                    try engine.respond(e, h, 400, &.{}, "bad", false);
                } else if (std.mem.eql(u8, query, "silent")) {
                    self.held.store(h, .release);
                }
            },
            .request => {
                const r: *const abi.RequestEvent = @ptrCast(@alignCast(rec.ptr));
                _ = self.plains.fetchAdd(1, .monotonic);
                if (r.route_id == 11) {
                    try engine.respond(e, h, 200, &.{}, "plain", false);
                } else {
                    // Route 13: the test answers it.
                    self.held.store(h, .release);
                }
            },
            .ws_open => _ = self.opens.fetchAdd(1, .monotonic),
            .ws_message => {
                const m: *const abi.WsMessageEvent = @ptrCast(@alignCast(rec.ptr));
                _ = try engine.ws.send(e, h, m.type, str(rec, m.data), false);
            },
            .ws_close => {
                const c: *const abi.WsCloseEvent = @ptrCast(@alignCast(rec.ptr));
                self.close_code.store(c.code, .release);
                _ = self.closes.fetchAdd(1, .monotonic);
            },
            .abort => _ = self.aborts.fetchAdd(1, .monotonic),
            else => {},
        }
    }
};

/// A raw HTTP/1.1 WebSocket client: the handshake's head, then short
/// unmasked server frames and masked (zero key) client frames.
const RawWs = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [2048]u8 = undefined,
    wbuf: [1024]u8 = undefined,
    head: [1024]u8 = undefined,
    head_len: usize = 0,

    fn open(self: *RawWs, io: std.Io, port: u16, path: []const u8, extra: []const u8) !void {
        self.stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        try self.writer.interface.print("GET {s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{s}\r\n", .{ path, extra });
        try self.writer.interface.flush();
        self.head_len = 0;
        while (std.mem.indexOf(u8, self.head[0..self.head_len], "\r\n\r\n") == null) {
            const line = try self.reader.interface.takeDelimiterInclusive('\n');
            @memcpy(self.head[self.head_len..][0..line.len], line);
            self.head_len += line.len;
        }
    }

    fn headText(self: *const RawWs) []const u8 {
        return self.head[0..self.head_len];
    }

    fn frame(self: *RawWs, out: []u8) !struct { opcode: u8, payload: []u8 } {
        const h = try self.reader.interface.takeArray(2);
        const len = h[1] & 0x7f;
        try self.reader.interface.readSliceAll(out[0..len]);
        return .{ .opcode = h[0] & 0x0f, .payload = out[0..len] };
    }

    fn send(self: *RawWs, opcode: u8, payload: []const u8) !void {
        try self.writer.interface.writeAll(&.{ 0x80 | opcode, 0x80 | @as(u8, @intCast(payload.len)), 0, 0, 0, 0 });
        try self.writer.interface.writeAll(payload);
        try self.writer.interface.flush();
    }

    fn close(self: *RawWs, io: std.Io) void {
        self.stream.close(io);
    }
};

/// Reads the rest of a response into `w`. A read error past the response
/// (the server's close) ends it; a cancel goes up (SAFETY C3), and so does
/// a response too large for `w`.
fn readRest(r: *std.Io.net.Stream.Reader, w: *std.Io.Writer) !void {
    _ = r.interface.streamRemaining(w) catch |err| switch (err) {
        error.ReadFailed => if (r.err) |re| if (re == error.Canceled) return error.Canceled,
        error.WriteFailed => return err,
    };
}

/// A plain HTTP/1.1 GET of `path` with `Connection: close`: the request is
/// written, the response is left to `readRest`.
const RawGet = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    rbuf: [2048]u8 = undefined,
    wbuf: [256]u8 = undefined,

    fn open(self: *RawGet, io: std.Io, port: u16, path: []const u8) !void {
        self.stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);
        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);
        try self.writer.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
        try self.writer.interface.flush();
    }

    fn close(self: *RawGet, io: std.Io) void {
        self.stream.close(io);
    }
};

/// Runs `claim` (`fn (*WsDecider, port, std.Io) !void`) against a fresh
/// engine with the consumer-decided routes (/decide, /app, /plain) and its
/// consumer thread, then drains the engine. `upgrades`: the handshakes the
/// claim makes, each of which the consumer must have been asked about.
fn wsDecideRun(comptime claim: anytype, upgrades: u32) !void {
    const json =
        \\{"executors": 2, "timeouts": {"request_ms": 3000, "shutdown_ms": 1000},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
        \\ "routes": [
        \\   {"path": "/decide", "timeout_ms": 300, "websocket": {"handler": 10, "accept": "consumer", "origins": ["*"]}},
        \\   {"path": "/app", "handler": 11, "websocket": {"handler": 12, "accept": "consumer", "origins": ["*"]}},
        \\   {"path": "/plain", "handler": 13}
        \\ ]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    var a: WsDecider = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, WsDecider.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(claim, .{ &a, e.port(0), io });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try std.testing.expect(a.upgrades.load(.acquire) >= upgrades);
    try e.drain();
    try std.testing.expect(e.wait(stopWaitMs()));
}

const WsDecideClaims = struct {
    fn accept(a: *WsDecider, port: u16, io: std.Io) !void {
        var buf: [256]u8 = undefined;
        {
            var c: RawWs = undefined;
            try c.open(io, port, "/decide?accept", "Sec-WebSocket-Protocol: a, b\r\n");
            defer c.close(io);
            try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 101"));
            try std.testing.expect(std.ascii.findIgnoreCase(c.headText(), "Sec-WebSocket-Protocol: b\r\n") != null);
            try std.testing.expect(std.ascii.findIgnoreCase(c.headText(), "Set-Cookie: s=1\r\n") != null);
            const first = try c.frame(&buf);
            try std.testing.expectEqualStrings("first", first.payload);
            try c.send(0x1, "echo me");
            try std.testing.expectEqualStrings("echo me", (try c.frame(&buf)).payload);
            try c.send(0x8, &.{ 0x03, 0xe8 });
            _ = try c.frame(&buf);
        }
        try waitAtLeast(io, &a.closes, 1);
        try std.testing.expectEqual(@as(u32, 1000), a.close_code.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), a.opens.load(.acquire));
    }

    fn refuse(_: *WsDecider, port: u16, io: std.Io) !void {
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?refuse", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 401"));
    }

    /// WsDecider checks the INVALID answers, then answers 400.
    fn badArguments(_: *WsDecider, port: u16, io: std.Io) !void {
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?bad-subprotocol", "Sec-WebSocket-Protocol: a\r\n");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 400"));
    }

    fn deadline(a: *WsDecider, port: u16, io: std.Io) !void {
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?silent", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 504"));
        // The consumer may take the handshake after its deadline answered
        // (a busy machine): wait for it.
        const h = try waitHeld(io, &a.held);
        // The decision came late: the handle is stale.
        try std.testing.expectError(error.Gone, engine.wsAccept(a.e, h, "", &.{}));
    }

    fn oneRoute(a: *WsDecider, port: u16, io: std.Io) !void {
        var buf: [256]u8 = undefined;
        // A GET without Upgrade headers: the plain handler (route 11).
        {
            var plain: RawGet = undefined;
            try plain.open(io, port, "/app");
            defer plain.close(io);
            var out: [512]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out);
            try readRest(&plain.reader, &w);
            try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "HTTP/1.1 200"));
            try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "plain"));
            try std.testing.expectEqual(@as(u32, 1), a.plains.load(.acquire));
        }
        // A handshake: the websocket handler (route 12).
        var c: RawWs = undefined;
        try c.open(io, port, "/app", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 101"));
        const first = try c.frame(&buf);
        try std.testing.expectEqualStrings("first", first.payload);
    }

    /// WsDecider holds the plain request of route 13; the test answers it.
    fn acceptPlain(a: *WsDecider, port: u16, io: std.Io) !void {
        var plain: RawGet = undefined;
        try plain.open(io, port, "/plain");
        defer plain.close(io);
        const h = try waitHeld(io, &a.held);
        try std.testing.expectError(error.State, engine.wsAccept(a.e, h, "", &.{}));
        // Nothing was taken: the request is still owed its answer.
        try engine.respond(a.e, h, 200, &.{}, "not a handshake", false);
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try readRest(&plain.reader, &w);
        try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "HTTP/1.1 200"));
        try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "not a handshake"));
    }
};

test "capi engine: anole_ws_accept sends the chosen subprotocol and headers on the 101, a message sent right after the accept arrives first, no WS_OPEN, and the request handle is GONE" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.accept, 1);
}

test "capi engine: a consumer's answer to a WebSocket handshake refuses it with its status" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.refuse, 1);
}

test "capi engine: anole_ws_accept with an unoffered subprotocol or a reserved header is INVALID, and the handshake is still owed its answer" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.badArguments, 1);
}

test "capi engine: a WebSocket handshake past its deadline gets 504, and a late anole_ws_accept is GONE" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.deadline, 1);
}

test "capi engine: one route takes plain requests (its handler) and WebSocket handshakes (its websocket handler)" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.oneRoute, 1);
}

test "capi engine: anole_ws_accept on a plain request is STATE, and the request is still owed its answer" {
    if (comptime !features.websocket) return error.SkipZigTest;
    try wsDecideRun(WsDecideClaims.acceptPlain, 0);
}

test "capi engine: two publishes to one topic from one thread never swap, on 4 executors, 2000 rounds" {
    if (comptime !features.websocket) return error.SkipZigTest;
    const json =
        \\{"executors": 4, "timeouts": {"shutdown_ms": 500},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
        \\ "routes": [{"path": "/ws", "websocket": {"handler": 20}}]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    const Sub = struct {
        e: *engine.Engine,
        c: *engine.Consumer,
        stop: std.atomic.Value(bool) = .init(false),
        failures: std.atomic.Value(u32) = .init(0),
        /// Subscribes that returned: a publish made after one reaches it
        /// (publishes wait for the topic changes before them).
        subscribed: std.atomic.Value(u32) = .init(0),
        fn run(self: *@This()) void {
            var buf: [64 * 1024]u8 align(8) = undefined;
            var need: u32 = 0;
            while (!self.stop.load(.acquire)) {
                const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
                var off: usize = 0;
                while (off < n) {
                    const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                    if (ev.type == @backingInt(abi.EventType.ws_open)) {
                        if (engine.ws.subscribe(self.e, ev.handle, "seq", true)) |_| {
                            _ = self.subscribed.fetchAdd(1, .release);
                        } else |_| {
                            _ = self.failures.fetchAdd(1, .monotonic);
                        }
                    }
                    off += ev.len;
                }
            }
        }
    };
    var sub: Sub = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, Sub.run, .{&sub});
    defer {
        sub.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    const Body = struct {
        fn run(e_: *engine.Engine, port: u16, io_: std.Io, subscribed: *std.atomic.Value(u32)) !void {
            var client: RawWs = undefined;
            try client.open(io_, port, "/ws", "");
            defer client.close(io_);
            try waitAtLeast(io_, subscribed, 1);
            var i: u32 = 0;
            while (i < 2000) : (i += 1) {
                var b0: [16]u8 = undefined;
                const text = try std.fmt.bufPrint(&b0, "{d}", .{i});
                // Back-pressure (Again) is retried until the topic takes it.
                const Pub = struct { e: *engine.Engine, text: []const u8 };
                try wait.waitUntil(io_, "the topic took the message", Pub{ .e = e_, .text = text }, struct {
                    fn published(p: Pub) !bool {
                        engine.ws.publish(p.e, "seq", abi.WS_TEXT, p.text, 0) catch |err| switch (err) {
                            error.Again => return false,
                            else => return err,
                        };
                        return true;
                    }
                }.published);
            }
            var buf: [64]u8 = undefined;
            var want: u32 = 0;
            while (want < 2000) : (want += 1) {
                const f = try client.frame(&buf);
                var exp: [16]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&exp, "{d}", .{want}), f.payload);
            }
        }
    };
    var f = try io.concurrent(Body.run, .{ e, e.port(0), io, &sub.subscribed });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), sub.failures.load(.acquire));
    try e.drain();
    try std.testing.expect(e.wait(stopWaitMs()));
}

test "capi engine: ANOLE_EV_DRAINING reaches every consumer once when the drain starts, before ANOLE_EV_STOPPED" {
    const e, const c = try ringEngine(8);
    defer e.destroy();
    try e.drain();
    // A second drain call tells nobody.
    try e.drain();
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 2);
    try std.testing.expectEqual(@as(u32, 1), counts[@backingInt(abi.EventType.draining)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@backingInt(abi.EventType.stopped)]);
    try std.testing.expect(e.wait(stopWaitMs()));
}

// ---------------------------------------------------------------------------
// A streamed answer outlives request_ms and Anole's backstop on every protocol

/// The backstop's margin past request_ms in the test below
/// (`engine.test_backstop_margin_ms`; 5 s outside tests).
const slow_backstop_margin_ms = 300;

/// Route 20: a stream that writes one byte every 50 ms, 13 times (650 ms,
/// past request_ms 200 + the 300 ms backstop margin), from a thread of the
/// test's, then ends. A slow machine only makes the stream longer.
const SlowStreams = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    started: std.atomic.Value(u32) = .init(0),
    threads: [8]?std.Thread = @splat(null),
    nthreads: usize = 0,

    fn run(self: *SlowStreams) void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                if (ev.type == @backingInt(abi.EventType.request)) {
                    const r: *const abi.RequestEvent = @ptrCast(@alignCast(&buf[off]));
                    if (r.route_id == 20) self.begin(ev.handle);
                }
                off += ev.len;
            }
        }
        for (&self.threads) |*t| if (t.*) |th| th.join();
    }

    fn begin(self: *SlowStreams, h: u64) void {
        engine.streamStart(self.e, h, 200, &.{}) catch {
            _ = self.failures.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.started.fetchAdd(1, .monotonic);
        if (self.nthreads == self.threads.len) {
            _ = self.failures.fetchAdd(1, .monotonic);
            return;
        }
        self.threads[self.nthreads] = std.Thread.spawn(.{}, pump, .{ self, h }) catch {
            _ = self.failures.fetchAdd(1, .monotonic);
            return;
        };
        self.nthreads += 1;
    }

    fn pump(self: *SlowStreams, h: u64) void {
        const tio = engine.threadedIo();
        for (0..13) |_| {
            std.Io.sleep(tio, .fromMilliseconds(50), .awake) catch return;
            _ = engine.streamWrite(self.e, h, "x", false) catch {
                _ = self.failures.fetchAdd(1, .monotonic);
                return;
            };
        }
        engine.streamEnd(self.e, h, &.{}) catch {
            _ = self.failures.fetchAdd(1, .monotonic);
        };
    }
};

fn slowH1(io: std.Io, port: u16) !void {
    errdefer std.debug.print("slow stream over HTTP/1.1 failed\n", .{});
    const stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var out: [2048]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&out);
    try readRest(&r, &fw);
    const got = fw.buffered();
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200"));
    // The chunked body, whole: the writes may share chunks.
    var rest = got[(std.mem.indexOf(u8, got, "\r\n\r\n") orelse return error.NoBody) + 4 ..];
    var total: usize = 0;
    while (true) {
        const eol = std.mem.indexOf(u8, rest, "\r\n") orelse return error.TruncatedBody;
        const n = try std.fmt.parseInt(usize, rest[0..eol], 16);
        if (n == 0) break;
        total += n;
        if (rest.len < eol + 2 + n + 2) return error.TruncatedBody;
        rest = rest[eol + 2 + n + 2 ..];
    }
    try std.testing.expectEqual(@as(usize, 13), total);
}

fn slowH2(io: std.Io, port: u16, path: []const u8) !void {
    errdefer std.debug.print("slow stream over HTTP/2 {s} failed\n", .{path});
    const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    const body = try s.reader().allocRemaining(alloc, .unlimited);
    defer alloc.free(body);
    try std.testing.expectEqual(@as(usize, 13), body.len);
}

fn slowH3(io: std.Io, port: u16) !void {
    errdefer std.debug.print("slow stream over HTTP/3 failed\n", .{});
    const conn = try anole.h3.ClientConnection.connect(alloc, io, .{
        .host = "localhost",
        .address = try .parseIp4("127.0.0.1", port),
        .port = port,
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromSeconds(3),
    });
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/slowd" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    const body = try s.reader().allocRemaining(alloc, .unlimited);
    defer alloc.free(body);
    try std.testing.expectEqual(@as(usize, 13), body.len);
}

fn slowAll(plain_port: u16, h3_port: u16, io: std.Io) !void {
    var h1 = try io.concurrent(slowH1, .{ io, plain_port });
    var h2_tasked = try io.concurrent(slowH2, .{ io, plain_port, "/slow" });
    var h2_detached = try io.concurrent(slowH2, .{ io, plain_port, "/slowd" });
    var h3 = try io.concurrent(slowH3, .{ io, h3_port });
    // Await all before returning an error: the futures reference this frame.
    const r1 = h1.await(io);
    const r2 = h2_tasked.await(io);
    const r3 = h2_detached.await(io);
    const r4 = h3.await(io);
    try r1;
    try r2;
    try r3;
    try r4;
}

test "capi engine: a streamed answer outlives request_ms and Anole's backstop on every protocol (C ABI)" {
    if (comptime !features.http2 or !features.http3) return error.SkipZigTest;
    const margin0 = engine.test_backstop_margin_ms;
    engine.test_backstop_margin_ms = slow_backstop_margin_ms;
    defer engine.test_backstop_margin_ms = margin0;
    const json =
        \\{"executors": 2, "timeouts": {"request_ms": 200, "shutdown_ms": 1000},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0},
        \\               {"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}, "http3": true}],
        \\ "routes": [{"path": "/slow", "handler": 20, "no_wait": false},
        \\            {"path": "/slowd", "handler": 20}]}
    ;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    var a: SlowStreams = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, SlowStreams.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    // The UDP port of the HTTP/3 listener comes after the listeners'.
    var f = try io.concurrent(slowAll, .{ e.port(0), e.port(2), io });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, 4), a.started.load(.acquire));
    try e.drain();
    try std.testing.expect(e.wait(stopWaitMs()));
}

test "capi engine: a fixed route behind a JWKS jwt middleware is not run inline; behind none it is" {
    if (comptime !features.auth) return error.SkipZigTest;
    const base =
        \\{"executors": 1, "timeouts": {"shutdown_ms": 200},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
    ;
    const cases = [_]struct { json: []const u8, inline_ok: bool }{
        .{ .json = base ++
            \\ "middleware": [{"jwt": {"jwks_url": "http://127.0.0.1:1/jwks", "audience": "api"}}],
            \\ "routes": [{"path": "/fixed", "respond": {"status": 200, "body": "ok"}}]}
        , .inline_ok = false },
        .{ .json = base ++
            \\ "routes": [{"path": "/fixed", "respond": {"status": 200, "body": "ok"}}]}
        , .inline_ok = true },
        .{ .json = base ++
            \\ "routes": [{"path": "/fixed", "no_wait": false, "respond": {"status": 200, "body": "ok"}}]}
        , .inline_ok = false },
    };
    inline for (cases) |case| {
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(case.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        defer e.destroy();
        _ = try e.attach(null, null, false);
        try e.start();
        // `has_no_wait`: some route promised not to wait.
        try std.testing.expectEqual(case.inline_ok, e.app.?.router.has_no_wait);
        try e.drain();
        try std.testing.expect(e.wait(stopWaitMs()));
    }
}

fn testVarsReal(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "PORT")) return "41234";
    return null;
}

test "capi: deployment platform binds every interface on PORT and names the listener after it" {
    engine._test_vars = .{ .real = testVarsReal, .any = testVarsReal };
    defer engine._test_vars = null;
    {
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = try engine.Engine.create("{\"deployment\":\"platform\",\"listeners\":[{}]}", false, &why);
        defer e.destroy();
        try std.testing.expectEqualStrings("[::]:41234", e.listeners[0].cfg_address);
        try std.testing.expectEqualStrings("http-41234", e.listeners[0].name);
    }
}

// Pass 3's areas: each its own file of C ABI tests (research/p3-pass/PLAN.md R8).
test {
    _ = @import("net_test.zig");
    _ = @import("jobs_test.zig");
    _ = @import("webhooks_test.zig");
    _ = @import("sse_test.zig");
    _ = @import("console_test.zig");
    _ = @import("watch_test.zig");
    _ = @import("s3_test.zig");
    _ = @import("smtp_test.zig");
    _ = @import("lambda_test.zig");
}
