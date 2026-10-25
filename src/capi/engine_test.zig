//! The engine over HTTP/2 and HTTP/3, where consumer requests detach: a
//! consumer thread answers through the engine's functions (what libanole's
//! exports call), and Anole's own clients check what goes out. The C suite
//! (tests/capi/consumer.c) covers HTTP/1.1 and the exported API.
const std = @import("std");
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

fn Harness(comptime proto: enum { h2, h3 }) type {
    return struct {
        const client = if (proto == .h2) anole.h2 else anole.h3;

        fn get(conn: *client.ClientConnection, arena: std.mem.Allocator, method: []const u8, path: []const u8, body: ?[]const u8) !struct { u16, []const u8, *client.Stream } {
            const s = try conn.request(&.{
                .{ .name = ":method", .value = method },                                .{ .name = ":path", .value = path },
                .{ .name = ":scheme", .value = if (proto == .h2) "http" else "https" }, .{ .name = ":authority", .value = "localhost" },
            }, if (proto == .h2) .{ .body_bytes = body } else .{ .body = body != null });
            if (proto == .h3) if (body) |b| {
                try s.writer().writeAll(b);
                try s.closeSend();
            };
            try s.waitHead();
            const out = try s.reader().allocRemaining(arena, .unlimited);
            return .{ s.status, out, s };
        }

        fn check(a: *Answerer, port: u16, io: std.Io) !void {
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const conn = try client.ClientConnection.connect(alloc, io, if (proto == .h2)
                .{ .host = "127.0.0.1", .port = port }
            else
                .{ .host = "localhost", .address = try .parseIp4("127.0.0.1", port), .port = port, .tls = .{ .insecure_skip_verify = true }, .connect_timeout = .fromSeconds(3) });
            defer conn.close();
            var step: []const u8 = "many";
            errdefer std.debug.print("{s} check failed at {s}\n", .{ @tagName(proto), step });
            const version: u8 = if (proto == .h2) 20 else 30;

            // Many at once on one connection: each answered from the
            // consumer thread, none with a task waiting.
            const d0 = a.e.stats().detached;
            var streams: [24]*client.Stream = undefined;
            for (&streams, 0..) |*st, i| st.* = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },                                 .{ .name = ":path", .value = try std.fmt.allocPrint(arena, "/hello/{d}", .{i}) },
                .{ .name = ":scheme", .value = if (proto == .h2) "http" else "https" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            for (streams, 0..) |st, i| {
                defer st.release();
                try st.waitHead();
                try std.testing.expectEqual(@as(u16, 200), st.status);
                const body = try st.reader().allocRemaining(arena, .unlimited);
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "hello /hello/{d} {d}", .{ i, version }), body);
            }
            try std.testing.expect(a.e.stats().detached >= d0 + streams.len);

            step = "bodies";
            // Bodies: one that arrives whole (detached), one larger than
            // the stream window (a task; read with anole_req_read).
            {
                const status, const body, const s = try get(conn, arena, "POST", "/echo", "the body");
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualStrings("the body", body);
            }
            {
                const big = try arena.alloc(u8, 300 * 1024);
                for (big, 0..) |*b, i| b.* = @truncate(i *% 7);
                const status, const body, const s = try get(conn, arena, "POST", "/echo", big);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualSlices(u8, big, body);
            }

            step = "read after answer";
            {
                const body = try arena.alloc(u8, 10 * 1024);
                @memset(body, 'b');
                for (0..20) |_| {
                    const status, const out, const s = try get(conn, arena, "POST", "/late", body);
                    defer s.release();
                    try std.testing.expectEqual(@as(u16, 200), status);
                    try std.testing.expectEqualStrings("10240", out);
                }
                try std.testing.expectEqual(@as(u32, 0), a.late_reads.load(.acquire));
            }

            step = "made-up handles";
            // Garbage handles are refused, never followed.
            {
                const forged_ws: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 2) << 28) | 1;
                if (comptime features.websocket) {
                    try std.testing.expectError(error.Gone, engine.ws.send(a.e, forged_ws, abi.WS_TEXT, "x", false));
                    try std.testing.expectError(error.Over, engine.ws.close(a.e, forged_ws, 1000, ""));
                    try std.testing.expectError(error.Gone, engine.ws.subscribe(a.e, forged_ws, "t", true));
                }
                if (comptime builtin.os.tag != .windows) {
                    // A length past the end of the file is refused, however large.
                    const fd = std.c.open(@ptrCast(a.file_path.ptr), .{ .ACCMODE = .RDONLY });
                    try std.testing.expect(fd >= 0);
                    defer _ = std.c.close(fd);
                    try std.testing.expectError(error.Invalid, engine.respondFd(a.e, 1, 200, &.{}, fd, 1, std.math.maxInt(u64)));
                    try std.testing.expectError(error.Invalid, engine.respondFd(a.e, 1, 200, &.{}, fd, 0, std.math.maxInt(u64)));
                }
            }

            step = "stream";
            // A streamed answer with trailers, a file, a borrowed body.
            {
                const status, const body, const s = try get(conn, arena, "GET", "/stream", null);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqual(@as(usize, 1001), body.len);
                try std.testing.expectEqual(@as(u8, 'a'), body[0]);
                try std.testing.expectEqualStrings("done", s.trailer("x-t").?);
            }
            step = "file";
            {
                const status, const body, const s = try get(conn, arena, "GET", "/file", null);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualStrings("world", body);
            }
            step = "borrow";
            {
                const sent0 = a.sent.load(.acquire);
                const status, const body, const s = try get(conn, arena, "GET", "/borrow", null);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqual(@as(usize, Answerer.big.len), body.len);
                try waitFor(io, &a.sent, sent0 + 1);
            }

            step = "deadline";
            // A detached request past its deadline: 504 from Anole, the
            // late answer refused.
            {
                a.held.store(0, .release);
                const status, _, const s = try get(conn, arena, "GET", "/short", null);
                defer s.release();
                try std.testing.expectEqual(@as(u16, 504), status);
                const h = a.held.load(.acquire);
                try std.testing.expect(h != 0);
                try std.testing.expectError(error.Gone, engine.respond(a.e, h, 200, &.{}, "", false));
                // The consumer hears why: the deadline, with the 504 sent.
                for (0..1000) |_| {
                    if (a.last_abort.load(.acquire) == h) break;
                    try io.sleep(.fromMilliseconds(2), .awake);
                } else return error.TimedOut;
                try std.testing.expectEqual(@as(u32, abi.ABORT_DEADLINE), a.last_abort_reason.load(.acquire));
                try std.testing.expectEqual(@as(u32, 504), a.last_abort_status.load(.acquire));
            }

            step = "abort";
            // anole_req_abort: this stream is reset (CANCEL / H3_REQUEST_CANCELLED)
            // and the connection serves the next request.
            {
                const s = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },                                 .{ .name = ":path", .value = "/abort" },
                    .{ .name = ":scheme", .value = if (proto == .h2) "http" else "https" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
                defer s.release();
                if (s.waitHead()) |_| return error.AbortedRequestAnswered else |_| {}
                const status, const out, const s2 = try get(conn, arena, "GET", "/hello/9", null);
                defer s2.release();
                try std.testing.expectEqual(@as(u16, 200), status);
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "hello /hello/9 {d}", .{version}), out);
            }

            step = "reset";
            // The client resets a stream waiting for its answer: ABORT,
            // and the handle is gone.
            {
                a.held.store(0, .release);
                const s = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },                                 .{ .name = ":path", .value = "/hold" },
                    .{ .name = ":scheme", .value = if (proto == .h2) "http" else "https" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
                var held: u64 = 0;
                for (0..500) |_| {
                    held = a.held.load(.acquire);
                    if (held != 0) break;
                    try io.sleep(.fromMilliseconds(2), .awake);
                }
                try std.testing.expect(held != 0);
                s.cancel();
                s.release();
                // Wait for this stream's ABORT: a late one from an earlier
                // step can arrive first.
                for (0..1000) |_| {
                    if (a.last_abort.load(.acquire) == held) break;
                    try io.sleep(.fromMilliseconds(2), .awake);
                } else return error.TimedOut;
                try std.testing.expectError(error.Gone, engine.respond(a.e, held, 200, &.{}, "", false));
                try std.testing.expectEqual(@as(u32, abi.ABORT_CLIENT), a.last_abort_reason.load(.acquire));
            }
        }

        fn waitFor(io: std.Io, v: *std.atomic.Value(u32), n: u32) !void {
            for (0..1000) |_| {
                if (v.load(.acquire) >= n) return;
                try io.sleep(.fromMilliseconds(2), .awake);
            }
            return error.TimedOut;
        }

        fn run() !void {
            const listener = if (proto == .h2)
                \\"listeners": [{"address": "127.0.0.1", "port": 0}]
            else
                \\"listeners": [{"address": "127.0.0.1", "port": 0, "tls": {"self_signed": true}, "http3": true}]
            ;
            const json = "{\"executors\": 2, \"timeouts\": {\"request_ms\": 3000, \"shutdown_ms\": 1000}," ++
                "\"limits\": {\"body_max\": 1048576, \"inline_body_max\": 4096}," ++ listener ++ "," ++ routes ++ "}";
            var why_buf: [256]u8 = undefined;
            var why: std.Io.Writer = .fixed(&why_buf);
            const e = engine.Engine.create(json, false, &why) catch |err| {
                std.debug.print("{s}\n", .{why.buffered()});
                return err;
            };
            defer e.destroy();
            const c = try e.attach(null, null, true);
            try e.start();

            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io0 = std.testing.io;
            try tmp.dir.writeFile(io0, .{ .sub_path = "f.txt", .data = "hello world, from a file" });
            const dir_path = try tmp.dir.realPathFileAlloc(io0, ".", alloc);
            defer alloc.free(dir_path);
            const file_path = try std.fmt.allocPrintSentinel(alloc, "{s}/f.txt", .{dir_path}, 0);
            defer alloc.free(file_path);

            var a: Answerer = .{ .e = e, .c = c, .file_path = file_path };
            const t = try std.Thread.spawn(.{}, Answerer.run, .{&a});
            defer {
                a.stop.store(true, .release);
                t.join();
            }

            const rt = try zio.Runtime.init(alloc, .{});
            defer rt.deinit();
            const io = rt.io();
            // HTTP/3's UDP port comes after the listeners'.
            var f = try io.concurrent(check, .{ &a, e.port(if (proto == .h2) 0 else 1), io });
            try f.await(io);
            try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));

            try e.drain();
            try std.testing.expect(e.wait(5000));
            try std.testing.expectEqual(@as(u64, 0), e.stats().inflight);
        }
    };
}

test "capi engine over HTTP/2 (h2c): detached answers, bodies, streams, files, deadlines, resets" {
    if (comptime !features.http2) return error.SkipZigTest;
    try Harness(.h2).run();
}

test "capi engine over HTTP/3: detached answers, bodies, streams, files, deadlines, resets" {
    if (comptime !features.http3) return error.SkipZigTest;
    try Harness(.h3).run();
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

fn wtCheck(a: *WtAnswerer, port: u16, io: std.Io, keep: *?*anole.webtransport.Session, keep_conn: *?*anole.h3.ClientConnection) !void {
    const conn = try anole.h3.ClientConnection.connect(alloc, io, .{
        .host = "localhost",
        .address = try .parseIp4("127.0.0.1", port),
        .port = port,
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromSeconds(3),
        .webtransport = true,
    });
    var conn_kept = false;
    defer if (!conn_kept) conn.close();
    var step: []const u8 = "open";
    errdefer std.debug.print("webtransport check failed at {s}\n", .{step});
    const session = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    {
        defer session.deinit();

        step = "server's one-way stream";
        {
            const u = try session.acceptUniStream();
            defer u.release();
            const got = try u.reader().allocRemaining(alloc, .unlimited);
            defer alloc.free(got);
            try std.testing.expectEqualStrings("hello from server", got);
        }

        step = "echo";
        {
            const s = try session.openStream();
            defer s.release();
            try s.writer().writeAll("ping");
            try s.closeSend();
            const back = try s.reader().allocRemaining(alloc, .unlimited);
            defer alloc.free(back);
            try std.testing.expectEqualStrings("ping", back);
        }

        step = "one way in, a datagram out";
        var dbuf: [2048]u8 = undefined;
        {
            const s = try session.openUniStream();
            try s.writer().writeAll("uni-data");
            try s.closeSend();
            s.release();
            try std.testing.expectEqualStrings("uni:8", try session.receiveDatagram(&dbuf));
        }

        step = "datagrams";
        {
            try session.sendDatagram("dg1");
            try std.testing.expectEqualStrings("echo:dg1", try session.receiveDatagram(&dbuf));
        }

        step = "a large echo";
        {
            // Written whole before any of the echo is read: the echo
            // waits in the engine past the high-water mark (ANOLE_BUSY),
            // and drains as it is read (ANOLE_EV_WRITABLE).
            const big = try alloc.alloc(u8, 4 << 20);
            defer alloc.free(big);
            for (big, 0..) |*b, i| b.* = @truncate(i *% 13);
            const s = try session.openStream();
            defer s.release();
            try writeAll(s, big);
            const back = try s.reader().allocRemaining(alloc, .unlimited);
            defer alloc.free(back);
            try std.testing.expectEqualSlices(u8, big, back);
            try std.testing.expect(a.busies.load(.acquire) > 0);
            try waitAtLeast(io, &a.writables, 1);
        }

        step = "a reset closes the session";
        {
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
            try waitAtLeast(io, &a.closes, 1);
            try std.testing.expectEqual(@as(u32, 7), a.reset_code.load(.acquire));
            try std.testing.expectEqual(abi.WT_CLOSED_LOCAL, a.close_by.load(.acquire));
        }
    }

    step = "made-up handles";
    {
        const forged_session: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 4) << 28) | 1;
        const forged_stream: u64 = (@as(u64, 0x7fffff) << 33) | (@as(u64, 5) << 28) | 1;
        try std.testing.expectError(error.Gone, engine.wt.openStream(a.e, forged_session, false));
        try std.testing.expectError(error.Over, engine.wt.close(a.e, forged_session, 0, ""));
        try std.testing.expectError(error.Gone, engine.wt.write(a.e, forged_stream, "x", false, false));
        try std.testing.expectError(error.Over, engine.wt.streamOp(a.e, forged_stream, .release, 0));
        // A request handle is not a session, and 0 is no handle: misuse.
        try std.testing.expectError(error.WrongKind, engine.wt.sendDatagram(a.e, 1, "x", false));
        try std.testing.expectError(error.WrongKind, engine.wt.sendDatagram(a.e, 0, "x", false));
    }

    step = "a session left open for the drain";
    const second = try conn.openWebTransport(.{ .authority = "localhost", .path = "/wt" });
    try waitAtLeast(io, &a.opens, 2);
    keep.* = second;
    keep_conn.* = conn;
    conn_kept = true;
}

fn writeAll(s: *anole.webtransport.Stream, data: []const u8) !void {
    try s.writer().writeAll(data);
    try s.closeSend();
}

fn waitAtLeast(io: std.Io, v: *std.atomic.Value(u32), n: u32) !void {
    for (0..2500) |_| {
        if (v.load(.acquire) >= n) return;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    return error.TimedOut;
}

fn wtEnd(session: *anole.webtransport.Session, conn: *anole.h3.ClientConnection) void {
    session.deinit();
    conn.close();
}

test "capi engine: WebTransport sessions, streams both ways, datagrams, close, drain" {
    if (comptime !features.http3) return error.SkipZigTest;
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
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();

    var a: WtAnswerer = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, WtAnswerer.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }

    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var second: ?*anole.webtransport.Session = null;
    var conn: ?*anole.h3.ClientConnection = null;
    var f = try io.concurrent(wtCheck, .{ &a, e.port(1), io, &second, &conn });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), e.stats().wt_sessions);

    // The drain: the open session hears it, then closes (close_on_drain).
    try e.drain();
    var wait_drain = try io.concurrent(waitAtLeast, .{ io, &a.closes, 2 });
    try wait_drain.await(io);
    try std.testing.expect(a.drains.load(.acquire) >= 1);
    var end = try io.concurrent(wtEnd, .{ second.?, conn.? });
    end.await(io);
    try std.testing.expect(e.wait(5000));
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

const TlsCheck = struct {
    const h2 = anole.h2;
    const h3 = anole.h3;

    fn h2Get(io: std.Io, port: u16, ca: []const u8, client: ?*const anole.tls.Pem) ![]u8 {
        const conn = try h2.ClientConnection.connect(alloc, io, .{
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
        const conn = try h3.ClientConnection.connect(alloc, io, .{
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

    /// Waits (up to 3 s) until the TCP listener at `port` serves the
    /// certificate `ca` names.
    fn waitServes(io: std.Io, port: u16, ca: []const u8, client: *const anole.tls.Pem) !void {
        for (0..300) |_| {
            if (h2Get(io, port, ca, client)) |body| {
                alloc.free(body);
                return;
            } else |_| {}
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.NotReloaded;
    }

    fn run(e: *engine.Engine, io: std.Io, server: *const anole.tls.Pem, client: *const anole.tls.Pem, next: *const anole.tls.Pem, dir_path: []const u8) !void {
        var step: []const u8 = "require";
        errdefer std.debug.print("tls check failed at {s}\n", .{step});
        const required = e.port(0);
        const requested = e.port(1);
        const quic = e.port(2);
        var bundle = try tls_testing.bundleFromPem(alloc, std.Io.Clock.real.now(io).toSeconds(), client.cert);
        defer bundle.deinit(alloc);
        const der = bundle.bytes.items;

        // "require": refused without a certificate; with one, the record
        // carries it.
        if (h2Get(io, required, server.cert, null)) |body| {
            alloc.free(body);
            return error.ServedWithoutClientCertificate;
        } else |_| {}
        {
            const body = try h2Get(io, required, server.cert, client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, der, body);
        }
        // A certificate no client CA signed is refused.
        if (h2Get(io, required, server.cert, next)) |body| {
            alloc.free(body);
            return error.ServedWithUnknownCertificate;
        } else |_| {}

        step = "request";
        {
            const body = try h2Get(io, requested, server.cert, null);
            defer alloc.free(body);
            try std.testing.expectEqualStrings("none", body);
        }
        {
            const body = try h2Get(io, requested, server.cert, client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, der, body);
        }

        step = "http3";
        if (h3Get(io, quic, server.cert, null)) |body| {
            alloc.free(body);
            return error.ServedWithoutClientCertificate;
        } else |_| {}
        {
            const body = try h3Get(io, quic, server.cert, client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, der, body);
        }

        step = "reload from PEM";
        try e.setCertificate(.{ .pem = .{ .cert = next.cert, .key = next.key } });
        try waitServes(io, required, next.cert, client);
        {
            const body = try h3Get(io, quic, next.cert, client);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, der, body);
        }
        if (h2Get(io, requested, server.cert, client)) |body| {
            alloc.free(body);
            return error.OldCertificateServed;
        } else |_| {}

        step = "reload from files";
        const cert_path = try std.fs.path.join(alloc, &.{ dir_path, "server.pem" });
        defer alloc.free(cert_path);
        const key_path = try std.fs.path.join(alloc, &.{ dir_path, "server.key" });
        defer alloc.free(key_path);
        try e.setCertificate(.{ .files = .{ .cert_path = cert_path, .key_path = key_path } });
        try waitServes(io, requested, server.cert, client);
        // A bad one leaves the certificate in place.
        try std.testing.expect(std.meta.isError(e.setCertificate(.{ .pem = .{ .cert = "not a certificate", .key = next.key } })));
        try waitServes(io, requested, server.cert, client);

        if (comptime builtin.os.tag != .windows) {
            step = "SIGHUP";
            // The files now hold the other certificate; SIGHUP reads them.
            var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
            defer dir.close(io);
            try dir.writeFile(io, .{ .sub_path = "server.pem", .data = next.cert });
            try dir.writeFile(io, .{ .sub_path = "server.key", .data = next.key });
            try std.posix.raise(.HUP);
            try waitServes(io, required, next.cert, client);
        }
    }
};

test "capi engine: mutual TLS (require, request, HTTP/3), the client certificate in records, certificate reload and SIGHUP" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    var server = try anole.tls.selfSigned(alloc, .{});
    defer server.deinit(alloc);
    var client = try anole.tls.selfSigned(alloc, .{});
    defer client.deinit(alloc);
    var next = try anole.tls.selfSigned(alloc, .{});
    defer next.deinit(alloc);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io0 = std.testing.io;
    try tmp.dir.writeFile(io0, .{ .sub_path = "server.pem", .data = server.cert });
    try tmp.dir.writeFile(io0, .{ .sub_path = "server.key", .data = server.key });
    try tmp.dir.writeFile(io0, .{ .sub_path = "client-ca.pem", .data = client.cert });
    const dir_path = try tmp.dir.realPathFileAlloc(io0, ".", alloc);
    defer alloc.free(dir_path);

    // Files for the listener that SIGHUP rereads; PEM text for the other
    // one and for the client CA of the first. Paths go through JSON's
    // escaping too (Windows' backslashes).
    const cert_file = try std.fs.path.join(alloc, &.{ dir_path, "server.pem" });
    defer alloc.free(cert_file);
    const key_file = try std.fs.path.join(alloc, &.{ dir_path, "server.key" });
    defer alloc.free(key_file);
    const ca_file = try std.fs.path.join(alloc, &.{ dir_path, "client-ca.pem" });
    defer alloc.free(ca_file);
    const json = try std.fmt.allocPrint(alloc,
        \\{{"executors": 2, "timeouts": {{"request_ms": 3000, "shutdown_ms": 1000}},
        \\ "listeners": [
        \\   {{"address": "127.0.0.1", "port": 0, "http3": true, "tls": {{"cert_file": {f}, "key_file": {f},
        \\     "client_auth": "require", "client_ca_pem": {f}}}}},
        \\   {{"address": "127.0.0.1", "port": 0, "tls": {{"cert_pem": {f}, "key_pem": {f},
        \\     "client_auth": "request", "client_ca_file": {f}}}}}],
        \\ "routes": [{{"method": "GET", "path": "/peer", "handler": 1}}]}}
    , .{ std.json.fmt(cert_file, .{}), std.json.fmt(key_file, .{}), std.json.fmt(client.cert, .{}), std.json.fmt(server.cert, .{}), std.json.fmt(server.key, .{}), std.json.fmt(ca_file, .{}) });
    defer alloc.free(json);
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, builtin.os.tag != .windows, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();

    var a: PeerAnswerer = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, PeerAnswerer.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }

    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(TlsCheck.run, .{ e, io, &server, &client, &next, dir_path });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try e.drain();
    try std.testing.expect(e.wait(5000));
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
    // Give the stop time to finish, had it not waited for the reload: the
    // run thread would free the server and exit (its stack, which held the
    // server, with it).
    try std.Io.sleep(tio, .fromMilliseconds(400), .awake);
    if (e.stopped.isSet()) {
        e.thread.?.join();
        e.thread = null;
    }
    ControlHold.go.set(tio);
    t.join();
    // The reload ran on the live server (a self-signed listener reloads in
    // place), and the stop went on after it.
    try std.testing.expectEqual(@as(?anyerror, null), result);
    try std.testing.expect(e.wait(5000));
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
    try std.testing.expect(e.wait(5000));
    // After the stop: a wake is skipped, never followed into the freed
    // runtime.
    const x = &e.execs[0];
    x.setEvent(&x.kick);
}

const Racer = struct {
    e: *engine.Engine,
    stop: *std.atomic.Value(bool),
    which: u8,

    fn run(r: Racer) void {
        var n: usize = 0;
        while (!r.stop.load(.acquire)) : (n += 1) {
            switch (r.which) {
                0 => r.e.reloadCertificates() catch {},
                1 => r.e.setCertificate(.dev_self_signed) catch {},
                else => if (n % 64 == 63) r.e.drain() catch {} else r.e.reloadCertificates() catch {},
            }
        }
    }
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
        var threads: [3]std.Thread = undefined;
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Racer.run, .{Racer{ .e = e, .stop = &stop, .which = @intCast(i) }});
        // The stop lands at a different point of the racers' calls each
        // round.
        try std.Io.sleep(tio, .fromMicroseconds(@intCast(round * 400)), .awake);
        try e.drain();
        try std.testing.expect(e.wait(5000));
        // Past the stop the calls are refused; let them run into that too.
        try std.Io.sleep(tio, .fromMilliseconds(2), .awake);
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
    try std.testing.expect(e.wait(5000));
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
fn drainCounts(c: *engine.Consumer, counts: *[64]u32, want: u32, timeout_ms: u64) !void {
    var buf: [64 * 1024]u8 align(8) = undefined;
    var need: u32 = 0;
    var total: u32 = 0;
    const tio = engine.threadedIo();
    var waited: u64 = 0;
    while (total < want) {
        const n = engine.poll(c, &buf, true, &need) catch return error.TooBig;
        if (n == 0) {
            if (waited >= timeout_ms) return error.TimedOut;
            try std.Io.sleep(tio, .fromMilliseconds(5), .awake);
            waited += 5;
            continue;
        }
        var off: usize = 0;
        while (off < n) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            if (ev.type < counts.len) counts[ev.type] += 1;
            total += 1;
            off += ev.len;
        }
    }
}

fn postMany(x: *engine.Exec, n: u32, posted: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    for (0..n) |_| {
        const rec = engine.newRecord(@sizeOf(abi.Event), .writable, 7) catch return;
        x.postRecord(rec, true);
        _ = posted.fetchAdd(1, .release);
    }
}

test "capi engine: a full ring parks the executor on the room futex" {
    const e, const c = try ringEngine(2);
    defer e.destroy();
    const x = &e.execs[0];
    var posted: std.atomic.Value(u32) = .init(0);
    // One executor: the task runs on it.
    var f = try e.io.concurrent(postMany, .{ x, 8, &posted });
    // The consumer does not poll: two fit the ring, the task waits.
    const tio = engine.threadedIo();
    try std.Io.sleep(tio, .fromMilliseconds(300), .awake);
    try std.testing.expectEqual(@as(u32, 2), posted.load(.acquire));
    // Parked on the futex, not spinning on a yield (that gave thousands).
    try std.testing.expect(x.room_wakeups.load(.monotonic) < 10);
    // Polling makes room, and all eight arrive.
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 8, 3000);
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
    // From another thread too: the overflow list takes it.
    x.postEvent(.writable, 300);
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 9, 3000);
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
    // The consumer does not poll while all 64 are posted.
    try std.Io.sleep(engine.threadedIo(), .fromMilliseconds(200), .awake);
    try f.await(e.io);
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 64, 3000);
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
    try std.testing.expect(e.wait(5000));
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
    try std.testing.expect(e.wait(5000));
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
    var held: u64 = 0;
    for (0..500) |_| {
        held = a.held.load(.acquire);
        if (held != 0) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try std.testing.expect(held != 0);
    // The drain's deadline (shutdown_ms) cuts the request nobody answered.
    try e.drain();
    for (0..1500) |_| {
        if (a.last_abort.load(.acquire) == held) break;
        try io.sleep(.fromMilliseconds(2), .awake);
    } else return error.TimedOut;
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
/// `/app` takes plain requests (route 11) and handshakes (route 12).
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
                    // A request that is not a handshake is refused with a State error.
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
                    // anole_ws_accept on a request that is no handshake.
                    try std.testing.expectError(error.State, engine.wsAccept(e, h, "", &.{}));
                    try engine.respond(e, h, 200, &.{}, "not a handshake", false);
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

fn wsDecideCheck(a: *WsDecider, port: u16, io: std.Io) !void {
    var step: []const u8 = "accept";
    errdefer std.debug.print("ws decide check failed at {s}\n", .{step});
    var buf: [256]u8 = undefined;
    // An accept: the subprotocol and the cookie ride on the 101, the
    // message sent right after the accept comes first, no WS_OPEN.
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

    step = "refuse";
    {
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?refuse", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 401"));
    }

    step = "bad accept arguments";
    {
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?bad-subprotocol", "Sec-WebSocket-Protocol: a\r\n");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 400"));
    }

    step = "deadline";
    {
        a.held.store(0, .release);
        var c: RawWs = undefined;
        try c.open(io, port, "/decide?silent", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 504"));
        const h = a.held.load(.acquire);
        try std.testing.expect(h != 0);
        // The decision came late: the handle is stale.
        try std.testing.expectError(error.Gone, engine.wsAccept(a.e, h, "", &.{}));
    }

    step = "one route, plain requests and handshakes";
    {
        const p0 = a.plains.load(.acquire);
        var plain: RawWs = undefined;
        // A GET without Upgrade headers: the plain handler (route 11).
        plain.stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
        defer plain.stream.close(io);
        plain.reader = plain.stream.reader(io, &plain.rbuf);
        plain.writer = plain.stream.writer(io, &plain.wbuf);
        try plain.writer.interface.writeAll("GET /app HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try plain.writer.interface.flush();
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        _ = plain.reader.interface.streamRemaining(&w) catch {};
        try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "HTTP/1.1 200"));
        try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "plain"));
        try std.testing.expectEqual(p0 + 1, a.plains.load(.acquire));

        var c: RawWs = undefined;
        try c.open(io, port, "/app", "");
        defer c.close(io);
        try std.testing.expect(std.mem.startsWith(u8, c.headText(), "HTTP/1.1 101"));
        const first = try c.frame(&buf);
        try std.testing.expectEqualStrings("first", first.payload);
    }
}

test "capi engine: WebSocket handshakes decided by the consumer: accept with a subprotocol and headers, refuse, bad arguments, deadline 504, one route for plain requests and handshakes" {
    if (comptime !features.websocket) return error.SkipZigTest;
    const json =
        \\{"executors": 2, "timeouts": {"request_ms": 3000, "shutdown_ms": 1000},
        \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
        \\ "routes": [
        \\   {"path": "/decide", "timeout_ms": 300, "websocket": {"handler": 10, "accept": "consumer", "origins": ["*"]}},
        \\   {"path": "/app", "handler": 11, "websocket": {"handler": 12, "accept": "consumer", "origins": ["*"]}}
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
    var f = try io.concurrent(wsDecideCheck, .{ &a, e.port(0), io });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try std.testing.expect(a.upgrades.load(.acquire) >= 5);
    try e.drain();
    try std.testing.expect(e.wait(5000));
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
        fn run(self: *@This()) void {
            var buf: [64 * 1024]u8 align(8) = undefined;
            var need: u32 = 0;
            while (!self.stop.load(.acquire)) {
                const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
                var off: usize = 0;
                while (off < n) {
                    const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                    if (ev.type == @backingInt(abi.EventType.ws_open)) {
                        engine.ws.subscribe(self.e, ev.handle, "seq", true) catch {
                            _ = self.failures.fetchAdd(1, .monotonic);
                        };
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
        fn run(e_: *engine.Engine, port: u16, io_: std.Io) !void {
            var client: RawWs = undefined;
            try client.open(io_, port, "/ws", "");
            defer client.close(io_);
            // Let the subscription land.
            try io_.sleep(.fromMilliseconds(200), .awake);
            var i: u32 = 0;
            while (i < 2000) : (i += 1) {
                var b0: [16]u8 = undefined;
                const text = try std.fmt.bufPrint(&b0, "{d}", .{i});
                while (true) {
                    engine.ws.publish(e_, "seq", abi.WS_TEXT, text, 0) catch |err| switch (err) {
                        error.Again => {
                            try io_.sleep(.fromMilliseconds(1), .awake);
                            continue;
                        },
                        else => return err,
                    };
                    break;
                }
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
    var f = try io.concurrent(Body.run, .{ e, e.port(0), io });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), sub.failures.load(.acquire));
    try e.drain();
    try std.testing.expect(e.wait(5000));
}

test "capi engine: ANOLE_EV_DRAINING reaches every consumer once when the drain starts, before ANOLE_EV_STOPPED" {
    const e, const c = try ringEngine(8);
    defer e.destroy();
    try e.drain();
    // A second drain call tells nobody.
    try e.drain();
    var counts: [64]u32 = @splat(0);
    try drainCounts(c, &counts, 2, 5000);
    try std.testing.expectEqual(@as(u32, 1), counts[@backingInt(abi.EventType.draining)]);
    try std.testing.expectEqual(@as(u32, 1), counts[@backingInt(abi.EventType.stopped)]);
    try std.testing.expect(e.wait(5000));
}

// ---------------------------------------------------------------------------
// A streamed answer outlives request_ms + 5 s on every protocol

/// Route 20: a stream that writes one byte every 500 ms, 13 times (6.5 s),
/// from a thread of the test's, then ends.
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
            std.Io.sleep(tio, .fromMilliseconds(500), .awake) catch return;
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
    _ = r.interface.streamRemaining(&fw) catch {};
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

test "capi engine: a streamed answer outlives request_ms + 5 s on every protocol (C ABI)" {
    if (comptime !features.http2 or !features.http3) return error.SkipZigTest;
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
    try std.testing.expect(e.wait(5000));
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
        try std.testing.expect(e.wait(5000));
    }
}

fn testVarsReal(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "PORT")) return "41234";
    return null;
}

test "capi: deployment resolution at create" {
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
    _ = @import("watch_test.zig");
    _ = @import("s3_test.zig");
    _ = @import("smtp_test.zig");
    _ = @import("lambda_test.zig");
}
