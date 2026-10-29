//! The C ABI's gRPC server, end to end: a consumer thread implements
//! anole.test.Echo, anole.test.Lookup and part of transcode.Library through
//! the engine's functions (what libanole's exports call), and Anole's own
//! gRPC client, HTTP/1.1 client and h2 client check what goes out. The C
//! suite (tests/capi/grpc.c) covers the exported API over gRPC-Web.
const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const grpc_capi = @import("grpc.zig");
const abi = engine.abi;
const features = anole.features;
const zio = anole.zio;
const grpc = anole.grpc;
const pb = @import("anole_test_pb");
const tpb = @import("anole_transcode_pb");

const alloc = std.testing.allocator;
const Echo = pb.Echo(grpc.Call, anyerror);

const Consumer = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    /// The call the consumer holds unanswered ("hold"), and the last ABORT.
    held: std.atomic.Value(u64) = .init(0),
    last_abort: std.atomic.Value(u64) = .init(0),
    calls: std.atomic.Value(u32) = .init(0),
    /// Client-streaming calls: what came so far.
    pending: std.AutoHashMapUnmanaged(u64, std.ArrayList(u8)) = .empty,
    bidi_index: std.AutoHashMapUnmanaged(u64, i32) = .empty,

    fn run(self: *Consumer) void {
        var buf: [256 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                self.handle(buf[off..][0..ev.len]) catch |err| {
                    std.debug.print("consumer failed: {t}\n", .{err});
                    _ = self.failures.fetchAdd(1, .monotonic);
                };
                off += ev.len;
            }
        }
        var it = self.pending.valueIterator();
        while (it.next()) |v| v.deinit(alloc);
        self.pending.deinit(alloc);
        self.bidi_index.deinit(alloc);
    }

    fn str(rec: []const u8, s: abi.Span) []const u8 {
        return rec[s.off..][0..s.len];
    }

    fn metadata(rec: []const u8, name: []const u8) ?[]const u8 {
        const call: *const abi.GrpcCallEvent = @ptrCast(@alignCast(rec.ptr));
        const spans: [*]align(1) const abi.Span = @ptrCast(rec[@sizeOf(abi.GrpcCallEvent)..].ptr);
        for (0..call.nmetadata) |k| if (std.mem.eql(u8, str(rec, spans[2 * k]), name)) return str(rec, spans[2 * k + 1]);
        return null;
    }

    fn encode(arena: std.mem.Allocator, msg: anytype) ![]const u8 {
        var w: std.Io.Writer.Allocating = .init(arena);
        try msg.encode(&w.writer, arena);
        return w.written();
    }

    fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) !T {
        var r: std.Io.Reader = .fixed(bytes);
        return T.decode(&r, arena);
    }

    fn handle(self: *Consumer, rec: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        const e = self.e;
        const h = ev.handle;
        const g = grpc_capi;
        switch (@as(abi.EventType, @fromBackingInt(@intCast(ev.type)))) {
            .abort => {
                self.last_abort.store(h, .release);
                if (self.pending.fetchRemove(h)) |kv| {
                    var list = kv.value;
                    list.deinit(alloc);
                }
                _ = self.bidi_index.remove(h);
                return;
            },
            .grpc_message => {
                const m: *const abi.GrpcMessageEvent = @ptrCast(@alignCast(rec.ptr));
                const req = try decode(pb.EchoRequest, arena, str(rec, m.data));
                if (self.pending.getPtr(h)) |list| {
                    try list.appendSlice(alloc, req.message);
                } else if (self.bidi_index.getPtr(h)) |i| {
                    _ = try g.send(e, h, try encode(arena, pb.EchoResponse{ .message = req.message, .index = i.* }), false, false);
                    i.* += 1;
                }
                try g.read(e, h, 1);
                return;
            },
            .grpc_half_close => {
                if (self.pending.fetchRemove(h)) |kv| {
                    var list = kv.value;
                    defer list.deinit(alloc);
                    _ = try g.send(e, h, try encode(arena, pb.EchoResponse{ .message = list.items }), false, true);
                } else if (self.bidi_index.remove(h)) {
                    try g.finish(e, h, 0, "", &.{});
                }
                return;
            },
            .grpc_call => {},
            else => return,
        }
        _ = self.calls.fetchAdd(1, .monotonic);
        const call: *const abi.GrpcCallEvent = @ptrCast(@alignCast(rec.ptr));
        const method = str(rec, call.method);
        switch (call.route_id) {
            // anole.test.Echo: Unary 0, ServerStream 1, ClientStream 2, Bidi 3.
            10 => switch (call.method_id) {
                0 => {
                    if (!std.mem.eql(u8, method, "/anole.test.Echo/Unary") or call.kind != abi.GRPC_KIND_UNARY) return error.WrongCall;
                    if (call.flags & abi.GRPC_CALL_MESSAGE == 0) return error.NoMessage;
                    const req = try decode(pb.EchoRequest, arena, str(rec, call.message));
                    if (std.mem.eql(u8, req.message, "fail")) {
                        return g.finish(e, h, @backingInt(grpc.Code.not_found), "no such thing: fail", &.{
                            .{ .name = .of("x-why"), .value = .of("test") },
                            .{ .name = .of("x-raw-bin"), .value = .of("\x00\x01\xff") },
                        });
                    }
                    if (std.mem.eql(u8, req.message, "hold")) {
                        if (call.timeout_us < 0 and metadata(rec, "x-expect-deadline") != null) return error.NoDeadline;
                        self.held.store(h, .release);
                        return;
                    }
                    if (std.mem.eql(u8, req.message, "headers")) {
                        try g.sendHeaders(e, h, &.{.{ .name = .of("x-initial"), .value = .of("yes") }});
                        // Twice: refused.
                        if (g.sendHeaders(e, h, &.{})) |_| return error.SecondHeaders else |err| if (err != error.State) return err;
                    }
                    const echoed = metadata(rec, "x-trace") orelse "none";
                    _ = try g.send(e, h, try encode(arena, pb.EchoResponse{ .message = req.message }), false, false);
                    // A second message for a unary call: refused.
                    if (g.send(e, h, "", false, false)) |_| return error.SecondMessage else |err| if (err != error.State) return err;
                    try g.finish(e, h, 0, "", &.{.{ .name = .of("x-echoed"), .value = .of(echoed) }});
                    // Finished: the handle is stale.
                    if (g.finish(e, h, 0, "", &.{})) |_| return error.NotStale else |err| if (err != error.Gone) return err;
                },
                1 => {
                    const req = try decode(pb.EchoRequest, arena, str(rec, call.message));
                    var i: i32 = 0;
                    while (i < req.repeat) : (i += 1) {
                        _ = try g.send(e, h, try encode(arena, pb.EchoResponse{ .message = req.message, .index = i }), false, false);
                    }
                    try g.finish(e, h, 0, "", &.{});
                },
                2 => try self.pending.put(alloc, h, .empty),
                3 => try self.bidi_index.put(alloc, h, 0),
                else => return error.WrongMethod,
            },
            // anole.test.Lookup: Find 0, Store 1.
            11 => {
                const req = try decode(pb.EchoRequest, arena, str(rec, call.message));
                _ = try g.send(e, h, try encode(arena, pb.EchoResponse{ .message = req.message }), false, true);
            },
            // transcode.Library, three methods listed: GetBook 0, WatchBooks 1, UploadBooks 2.
            12 => switch (call.method_id) {
                0 => {
                    const req = try decode(tpb.GetBookRequest, arena, str(rec, call.message));
                    _ = try g.send(e, h, try encode(arena, tpb.Book{ .name = req.name, .title = "T", .pages = 7 }), false, true);
                },
                1 => {
                    for ([_][]const u8{ "a", "b" }) |n| _ = try g.send(e, h, try encode(arena, tpb.Book{ .name = n }), false, false);
                    try g.finish(e, h, 0, "", &.{});
                },
                else => try g.finish(e, h, @backingInt(grpc.Code.unimplemented), "", &.{}),
            },
            else => return error.WrongService,
        }
    }
};

/// What `v` holds once it is `want` (or, with no `want`, not zero).
fn waitUntil(io: std.Io, v: *std.atomic.Value(u64), want: ?u64) !u64 {
    if (want) |w| {
        try wait.waitEqual(io, "the consumer heard the held request's ABORT", v, w);
        return w;
    }
    return wait.waitNonZero(io, "the consumer holds the request", v);
}

const Http1 = struct { status: u16, body: []const u8 };

fn http1(io: std.Io, arena: std.mem.Allocator, port: u16, method: dusty.Method, path: []const u8, content_type: ?[]const u8, body: ?[]const u8) !Http1 {
    var client = dusty.Client.init(alloc, io, .{});
    defer client.deinit();
    var headers = try dusty.Headers.init(alloc, 8);
    defer headers.deinit(alloc);
    if (content_type) |ct| try headers.put("Content-Type", ct);
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    var resp = try client.fetch(url, .{ .method = method, .headers = &headers, .body = body });
    defer resp.deinit();
    return .{ .status = @intCast(@backingInt(resp.status())), .body = try arena.dupe(u8, (try resp.body()) orelse "") };
}

/// Where a check talks to the engine: the consumer, a channel on the
/// transport, the zio `Io` it runs on and an arena for its answers.
const Ctx = struct {
    a: *Consumer,
    port: u16,
    io: std.Io,
    channel: *grpc.Channel,
    arena: std.mem.Allocator,

    fn echo(x: *Ctx) grpc.Client(Echo) {
        return .{ .channel = x.channel };
    }
};

const Transport = enum { h2c, h3 };

const h2c_json =
    \\{{"executors": 2, "timeouts": {{"request_ms": 3000, "shutdown_ms": 1000}},
    \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
    \\ "grpc": {{"descriptor_set": "{s}", "health": true, "services": [
    \\   {{"name": "anole.test.Echo", "handler": 10}},
    \\   {{"name": "anole.test.Lookup", "handler": 11}},
    \\   {{"name": "transcode.Library", "handler": 12, "methods": [{{"name": "GetBook"}}, {{"name": "WatchBooks"}}, {{"name": "UploadBooks"}}]}}
    \\ ]}}}}
;

const h3_json =
    \\{{"executors": 2, "timeouts": {{"request_ms": 3000, "shutdown_ms": 1000}},
    \\ "listeners": [{{"address": "127.0.0.1", "port": 0, "tls": {{"self_signed": true}}, "http3": true}}],
    \\ "grpc": {{"descriptor_set": "{s}", "services": [
    \\   {{"name": "anole.test.Echo", "handler": 10}}
    \\ ]}}}}
;

/// Runs `checkFn` against a started engine with the consumer thread above
/// on its own thread, then drains: the consumer failed nothing and no
/// request is left in flight. Over h2c the engine also serves Lookup,
/// transcode.Library and gRPC health, with "later.Service" set
/// NOT_SERVING before start.
fn withEngine(comptime transport: Transport, comptime checkFn: fn (*Ctx) anyerror!void) !void {
    const set = @import("anole_test_descriptors").set;
    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(set.len));
    defer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, set);
    const json = try std.fmt.allocPrint(alloc, if (transport == .h2c) h2c_json else h3_json, .{b64});
    defer alloc.free(json);
    var why_buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    // Before start: kept until the health service exists.
    if (transport == .h2c) try grpc_capi.healthSet(e, "later.Service", abi.GRPC_HEALTH_NOT_SERVING);
    try e.start();

    var a: Consumer = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, Consumer.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    // HTTP/3's UDP port comes after the listeners'.
    const port = e.port(if (transport == .h3) 1 else 0);
    const Run = struct {
        fn run(ca: *Consumer, p: u16, rio: std.Io) anyerror!void {
            return runCheck(transport, checkFn, ca, p, rio);
        }
    };
    var f = try io.concurrent(Run.run, .{ &a, port, io });
    defer f.cancel(io) catch {};
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));
    try e.drain();
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
    try std.testing.expectEqual(@as(u64, 0), e.stats().inflight);
}

fn runCheck(comptime transport: Transport, comptime checkFn: fn (*Ctx) anyerror!void, a: *Consumer, port: u16, io: std.Io) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    switch (transport) {
        .h2c => {
            const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
            defer conn.close();
            var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost" };
            var x: Ctx = .{ .a = a, .port = port, .io = io, .channel = &channel, .arena = arena_state.allocator() };
            try checkFn(&x);
        },
        .h3 => {
            const conn = try anole.h3.ClientConnection.connect(alloc, io, .{
                .host = "localhost",
                .address = try .parseIp4("127.0.0.1", port),
                .port = port,
                .tls = .{ .insecure_skip_verify = true },
                .connect_timeout = .fromSeconds(5),
            });
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            var x: Ctx = .{ .a = a, .port = port, .io = io, .channel = &channel, .arena = arena_state.allocator() };
            try checkFn(&x);
        },
    }
}

fn trailer(r: anytype, name: []const u8) []const u8 {
    for (r.trailers) |t| if (std.mem.eql(u8, t.name, name)) return t.value;
    return "";
}

// ---- the checks, each one claim, shared by the transports where it holds

/// Unary, detached: the answer, trailing metadata from the request's.
fn checkUnaryDetached(x: *Ctx) anyerror!void {
    const d0 = x.a.e.stats().detached;
    const r = try x.echo().unary("Unary", x.arena, .{ .message = "hello" }, .{ .metadata = &.{.{ .name = "x-trace", .value = "t1" }} });
    try std.testing.expectEqual(grpc.Code.ok, r.status.code);
    try std.testing.expectEqualStrings("hello", r.message.?.message);
    try std.testing.expectEqualStrings("t1", trailer(r, "x-echoed"));
    try std.testing.expect(x.a.e.stats().detached > d0);
}

fn checkUnaryDetachedH3(x: *Ctx) anyerror!void {
    const r = try x.echo().unary("Unary", x.arena, .{ .message = "transport" }, .{});
    try std.testing.expectEqual(grpc.Transport.h3, r.transport);
    try checkUnaryDetached(x);
}

/// An error status with its message and trailers, a -bin one base64.
fn checkErrorStatus(x: *Ctx) anyerror!void {
    const r = try x.echo().unary("Unary", x.arena, .{ .message = "fail" }, .{});
    try std.testing.expectEqual(grpc.Code.not_found, r.status.code);
    try std.testing.expectEqualStrings("no such thing: fail", r.status.message);
    try std.testing.expectEqualStrings("test", trailer(r, "x-why"));
    try std.testing.expectEqualStrings("AAH/", trailer(r, "x-raw-bin"));
}

/// Initial metadata reaches the client; a second sendHeaders and a second
/// unary message are refused (the consumer fails otherwise).
fn checkInitialMetadata(x: *Ctx) anyerror!void {
    var s = try x.echo().stream("Unary", x.arena, .{});
    defer s.deinit();
    try s.send(.{ .message = "headers" });
    try s.closeSend();
    const reply = (try s.receive()).?;
    try std.testing.expectEqualStrings("headers", reply.message);
    try std.testing.expectEqualStrings("yes", s.stream.header("x-initial") orelse "");
    try std.testing.expect(try s.receive() == null);
    try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
}

fn checkServerStream(x: *Ctx) anyerror!void {
    var s = try x.echo().stream("ServerStream", x.arena, .{});
    defer s.deinit();
    try s.send(.{ .message = "tick", .repeat = 5 });
    try s.closeSend();
    var n: i32 = 0;
    while (try s.receive()) |m| : (n += 1) {
        try std.testing.expectEqual(n, m.index);
        try std.testing.expectEqualStrings("tick", m.message);
    }
    try std.testing.expectEqual(@as(i32, 5), n);
    try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
}

/// More messages than read_ahead (8): the consumer's credit lets the rest in.
fn checkClientStream(x: *Ctx) anyerror!void {
    var s = try x.echo().stream("ClientStream", x.arena, .{ .compression = if (features.compression) .gzip else .identity });
    defer s.deinit();
    var want: std.ArrayList(u8) = .empty;
    for (0..20) |i| {
        const m = try std.fmt.allocPrint(x.arena, "{c}", .{@as(u8, 'a') + @as(u8, @intCast(i))});
        try want.appendSlice(x.arena, m);
        try s.send(.{ .message = m });
    }
    try s.closeSend();
    const reply = (try s.receive()).?;
    try std.testing.expectEqualStrings(want.items, reply.message);
    try std.testing.expect(try s.receive() == null);
    try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
}

fn checkBidi(x: *Ctx) anyerror!void {
    var s = try x.echo().stream("Bidi", x.arena, .{});
    defer s.deinit();
    for ([_][]const u8{ "ping", "pong", "again" }, 0..) |m, i| {
        try s.send(.{ .message = m });
        const reply = (try s.receive()).?;
        try std.testing.expectEqualStrings(m, reply.message);
        try std.testing.expectEqual(@as(i32, @intCast(i)), reply.index);
    }
    try s.closeSend();
    try std.testing.expect(try s.receive() == null);
    try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
}

/// A call past its deadline: DEADLINE_EXCEEDED at the client, ABORT at the
/// consumer, and the handle is gone.
fn checkDeadline(x: *Ctx) anyerror!void {
    const r = try x.echo().unary("Unary", x.arena, .{ .message = "hold" }, .{ .timeout = .fromMilliseconds(150), .metadata = &.{.{ .name = "x-expect-deadline", .value = "1" }} });
    try std.testing.expectEqual(grpc.Code.deadline_exceeded, r.status.code);
    const held = try waitUntil(x.io, &x.a.held, null);
    _ = try waitUntil(x.io, &x.a.last_abort, held);
    try std.testing.expectError(error.Gone, grpc_capi.finish(x.a.e, held, 0, "", &.{}));
}

/// A call the client cancels: ABORT at the consumer, and the handle is gone.
fn checkCancel(x: *Ctx) anyerror!void {
    var s = try x.echo().stream("Unary", x.arena, .{});
    try s.send(.{ .message = "hold" });
    try s.closeSend();
    const held = try waitUntil(x.io, &x.a.held, null);
    s.cancel();
    s.deinit();
    _ = try waitUntil(x.io, &x.a.last_abort, held);
    try std.testing.expectError(error.Gone, grpc_capi.send(x.a.e, held, "", false, true));
}

fn checkConnectJson(x: *Ctx) anyerror!void {
    const r = try http1(x.io, x.arena, x.port, .post, "/anole.test.Echo/Unary", "application/json", "{\"message\":\"json\"}");
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"message\":\"json\"}", r.body);
    const bad = try http1(x.io, x.arena, x.port, .post, "/anole.test.Echo/Unary", "application/json", "{\"message\":7}");
    try std.testing.expectEqual(@as(u16, 400), bad.status);
}

/// Lookup.Find has no side effects: GET with the message in the query;
/// Store is not reachable by GET.
fn checkConnectGet(x: *Ctx) anyerror!void {
    const r = try http1(x.io, x.arena, x.port, .get, "/anole.test.Lookup/Find?encoding=json&message=%7B%22message%22%3A%22got%22%7D", null, null);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"message\":\"got\"}", r.body);
    const store = try http1(x.io, x.arena, x.port, .get, "/anole.test.Lookup/Store?encoding=json&message=%7B%7D", null, null);
    try std.testing.expect(store.status == 404 or store.status == 405);
}

fn checkTranscoding(x: *Ctx) anyerror!void {
    const r = try http1(x.io, x.arena, x.port, .get, "/v1/books/abc", null, null);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"name\":\"abc\",\"title\":\"T\",\"pages\":\"7\"}", r.body);
    const w = try http1(x.io, x.arena, x.port, .get, "/v1/shelves/s1/books:watch", null, null);
    try std.testing.expectEqual(@as(u16, 200), w.status);
    try std.testing.expectEqualStrings("[{\"name\":\"a\"},{\"name\":\"b\"}]", w.body);
    const up = try http1(x.io, x.arena, x.port, .post, "/v1/books:upload", "application/json", "{}");
    try std.testing.expectEqual(@as(u16, 501), up.status);
}

const Health = grpc.health.pb.Health(grpc.Call, anyerror);

fn checkHealth(x: *Ctx) anyerror!void {
    const hc: grpc.Client(Health) = .{ .channel = x.channel };
    // Set before start, kept until the health service existed.
    const later = try hc.unary("Check", x.arena, .{ .service = "later.Service" }, .{});
    try std.testing.expectEqual(grpc.Code.ok, later.status.code);
    try std.testing.expectEqual(grpc.health.ServingStatus.NOT_SERVING, later.message.?.status);
    const r = try hc.unary("Check", x.arena, .{ .service = "anole.test.Echo" }, .{});
    try std.testing.expectEqual(grpc.Code.ok, r.status.code);
    try std.testing.expectEqual(grpc.health.ServingStatus.SERVING, r.message.?.status);
    try grpc_capi.healthSet(x.a.e, "anole.test.Echo", abi.GRPC_HEALTH_NOT_SERVING);
    try wait.waitUntil(x.io, "health reports NOT_SERVING", x, struct {
        fn notServing(c: *Ctx) !bool {
            const h: grpc.Client(Health) = .{ .channel = c.channel };
            const again = try h.unary("Check", c.arena, .{ .service = "anole.test.Echo" }, .{});
            return again.message.?.status == .NOT_SERVING;
        }
    }.notServing);
}

// ---- over h2c

test "capi grpc: a unary call answered detached carries the trailing metadata the consumer set" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkUnaryDetached);
}

test "capi grpc: an error status reaches the client with its message and trailers, a -bin one base64" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkErrorStatus);
}

test "capi grpc: initial metadata reaches the client; a second sendHeaders and a second unary message are refused" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkInitialMetadata);
}

test "capi grpc: a server stream delivers every message in order, then OK" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkServerStream);
}

test "capi grpc: a client stream longer than read_ahead reaches the consumer whole" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkClientStream);
}

test "capi grpc: a bidi stream answers each message in turn" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkBidi);
}

test "capi grpc: a call past its deadline is DEADLINE_EXCEEDED, ABORT reaches the consumer and the handle is gone" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkDeadline);
}

test "capi grpc: a call the client cancels reaches the consumer as ABORT and the handle is gone" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkCancel);
}

test "capi grpc: Connect JSON over HTTP/1.1 answers 200, a wrong field type 400" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkConnectJson);
}

test "capi grpc: Connect GET reaches a side-effect-free method, not the others" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkConnectGet);
}

test "capi grpc: transcoding serves unary and server-streaming methods as JSON, client streams 501" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkTranscoding);
}

test "capi grpc: health set before start holds after it, and healthSet turns a service NOT_SERVING" {
    if (comptime !features.http2) return error.SkipZigTest;
    try withEngine(.h2c, checkHealth);
}

// ---- over HTTP/3

test "capi grpc over HTTP/3: a unary call goes over h3, answered detached with its trailing metadata" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try withEngine(.h3, checkUnaryDetachedH3);
}

test "capi grpc over HTTP/3: an error status reaches the client with its message and trailers" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try withEngine(.h3, checkErrorStatus);
}

test "capi grpc over HTTP/3: a server stream delivers every message in order, then OK" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try withEngine(.h3, checkServerStream);
}

test "capi grpc over HTTP/3: a bidi stream answers each message in turn" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try withEngine(.h3, checkBidi);
}

test "capi grpc over HTTP/3: a call the client cancels reaches the consumer as ABORT and the handle is gone" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    try withEngine(.h3, checkCancel);
}

test "capi grpc: configurations refused" {
    const cases = [_][]const u8{
        // No descriptors and no methods.
        \\{"grpc": {"services": [{"name": "a.B", "handler": 1}]}}
        ,
        // No descriptors and a method without its kind.
        \\{"grpc": {"services": [{"name": "a.B", "handler": 1, "methods": [{"name": "M"}]}]}}
        ,
        // A service twice.
        \\{"grpc": {"services": [{"name": "a.B", "handler": 1, "methods": [{"name": "M", "kind": "unary"}]}, {"name": "a.B", "handler": 2, "methods": [{"name": "M", "kind": "unary"}]}]}}
        ,
        // Not base64.
        \\{"grpc": {"descriptor_set": "!!", "services": [{"name": "a.B", "handler": 1}]}}
        ,
        // Bytes that are not a FileDescriptorSet.
        \\{"grpc": {"descriptor_set": "AAAA", "services": [{"name": "a.B", "handler": 1}]}}
        ,
    };
    for (cases) |json| {
        var why_buf: [400]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        if (engine.Engine.create(json, false, &why)) |e| {
            e.destroy();
            std.debug.print("accepted: {s}\n", .{json});
            return error.Accepted;
        } else |err| try std.testing.expectEqual(error.Config, err);
    }
    // A service the descriptors do not have, and a kind they contradict.
    const set = @import("anole_test_descriptors").set;
    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(set.len));
    defer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, set);
    inline for (.{
        \\{{"grpc": {{"descriptor_set": "{s}", "services": [{{"name": "no.Such", "handler": 1}}]}}}}
        ,
        \\{{"grpc": {{"descriptor_set": "{s}", "services": [{{"name": "anole.test.Echo", "handler": 1, "methods": [{{"name": "Unary", "kind": "bidi_streaming"}}]}}]}}}}
        ,
        \\{{"grpc": {{"descriptor_set": "{s}", "services": [{{"name": "anole.test.Echo", "handler": 1, "methods": [{{"name": "Nope"}}]}}]}}}}
    }) |fmt| {
        const json = try std.fmt.allocPrint(alloc, fmt, .{b64});
        defer alloc.free(json);
        var why_buf: [400]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        if (engine.Engine.create(json, false, &why)) |e| {
            e.destroy();
            return error.Accepted;
        } else |err| try std.testing.expectEqual(error.Config, err);
    }
}
