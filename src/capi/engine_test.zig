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
    /// The handle of the most recent ABORT event.
    last_abort: std.atomic.Value(u64) = .init(0),
    sent: std.atomic.Value(u32) = .init(0),
    failures: std.atomic.Value(u32) = .init(0),
    late_reads: std.atomic.Value(u32) = .init(0),
    file_path: []const u8,

    var big: [200 * 1024]u8 = @splat('z');

    fn run(self: *Answerer) void {
        var buf: [256 * 1024]u8 align(8) = undefined;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50) catch unreachable;
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
            // anole_respond_fd is not on Windows (std.c.open does not exist there).
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
                const forged_ws: u64 = (@as(u64, 0xffffff) << 32) | (@as(u64, 2) << 28) | 1;
                if (comptime features.websocket) {
                    try std.testing.expectError(error.Gone, engine.ws.send(a.e, forged_ws, abi.WS_TEXT, "x", false));
                    try std.testing.expectError(error.Gone, engine.ws.close(a.e, forged_ws, 1000, ""));
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
            var f = try io.concurrent(check, .{ &a, e.ports.items[if (proto == .h2) 0 else 1], io });
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
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50) catch unreachable;
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
        if (try engine.wt.write(self.e, h, data, fin)) {
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
                try self.streams.put(alloc, h, .{ .uni = se.flags & abi.WT_UNI != 0, .session = se.session });
            },
            .wt_data => {
                const de: *const abi.WtDataEvent = @ptrCast(@alignCast(rec.ptr));
                const ent = self.streams.getPtr(h) orelse return error.UnknownStream;
                const data = str(rec, de.data);
                const fin = de.flags & abi.WT_FIN != 0;
                if (ent.uni) {
                    try ent.got.appendSlice(alloc, data);
                    if (fin) {
                        var out: [64]u8 = undefined;
                        try engine.wt.sendDatagram(e, ent.session, try std.fmt.bufPrint(&out, "uni:{d}", .{ent.got.items.len}));
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
                try engine.wt.sendDatagram(e, h, try std.fmt.bufPrint(&out, "echo:{s}", .{str(rec, de.data)}));
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
                if (engine.wt.sendDatagram(e, h, "x")) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                var it = self.streams.iterator();
                while (it.next()) |kv| if (kv.value_ptr.session == h) {
                    if (engine.wt.write(e, kv.key_ptr.*, "x", false)) |_| return error.NotStale else |err| if (err != error.Gone) return err;
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
        const forged_session: u64 = (@as(u64, 0xffffff) << 32) | (@as(u64, 4) << 28) | 1;
        const forged_stream: u64 = (@as(u64, 0xffffff) << 32) | (@as(u64, 5) << 28) | 1;
        try std.testing.expectError(error.Gone, engine.wt.openStream(a.e, forged_session, false));
        try std.testing.expectError(error.Gone, engine.wt.close(a.e, forged_session, 0, ""));
        try std.testing.expectError(error.Gone, engine.wt.write(a.e, forged_stream, "x", false));
        try std.testing.expectError(error.Gone, engine.wt.streamOp(a.e, forged_stream, .release, 0));
        // A request handle is not a session.
        try std.testing.expectError(error.Gone, engine.wt.sendDatagram(a.e, 1, "x"));
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
    var f = try io.concurrent(wtCheck, .{ &a, e.ports.items[1], io, &second, &conn });
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
