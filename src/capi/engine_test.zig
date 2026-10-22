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
    \\  {"method": "GET", "path": "/short", "handler": 5, "timeout_ms": 100}
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
                "\"limits\": {\"body_max\": 1048576}," ++ listener ++ "," ++ routes ++ "}";
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
