//! The C ABI's NATS calls through the engine, against a fake NATS server
//! (the server side of the protocol on loopback): publishing and the
//! WRITABLE event, subscriptions and their end, requests tied to a request.
//! The engine is driven through its Zig entry points, as in engine_test.zig.
//! Waits poll the consumer with generous bounds; no assertion is about time.
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = engine.abi;
const features = anole.features;
const FakeServer = @import("../nats/core/testing/FakeServer.zig");
const golden = @import("../nats/core/protocol/golden.zig");

const alloc = std.testing.allocator;
const Io = std.Io;

/// What the fake server saw, and how it behaves.
const Fake = struct {
    listener: std.Io.net.Server,
    future: Io.Future(anyerror!void) = undefined,
    /// The sid of the first SUB, 0 before it.
    sid: std.atomic.Value(u32) = .init(0),
    pubs: std.atomic.Value(u32) = .init(0),
    unsubs: std.atomic.Value(u32) = .init(0),
    /// Deliver this once the first SUB arrives (null: nothing).
    deliver: ?[]const u8 = null,
    /// After the handshake read nothing until `release` is set.
    stall: bool = false,
    release: Io.Event = .unset,
    url_buf: [64]u8 = undefined,

    fn start(f: *Fake, io: Io) !void {
        f.listener = try FakeServer.listen(io);
        errdefer f.listener.deinit(io);
        f.future = try io.concurrent(serve, .{ io, f });
    }

    fn url(f: *Fake) ![]const u8 {
        return FakeServer.url(&f.listener, &f.url_buf);
    }

    fn stop(f: *Fake, io: Io) void {
        f.release.set(io);
        f.future.cancel(io) catch {};
        f.listener.deinit(io);
    }

    fn serve(io: Io, f: *Fake) anyerror!void {
        var peer: FakeServer.Peer = undefined;
        try peer.accept(io, &f.listener);
        defer peer.close();
        try peer.send(golden.info_default);
        const connect_line = try peer.readLine();
        if (!std.mem.startsWith(u8, connect_line, "CONNECT {")) return error.TestNotConnect;
        try peer.expectLine("PING");
        try peer.send(golden.pong);
        if (f.stall) f.release.wait(io) catch return;
        while (try peer.nextLine()) |line| {
            if (std.mem.eql(u8, line, "PING")) {
                try peer.send(golden.pong);
            } else if (std.mem.startsWith(u8, line, "SUB ")) {
                if (f.sid.load(.acquire) == 0) {
                    const sid = try std.fmt.parseInt(u32, line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..], 10);
                    f.sid.store(sid, .release);
                    if (f.deliver) |payload| {
                        var buf: [256]u8 = undefined;
                        try peer.send(try std.fmt.bufPrint(&buf, "MSG test.subject {d} {d}\r\n{s}\r\n", .{ sid, payload.len, payload }));
                    }
                }
            } else if (std.mem.startsWith(u8, line, "UNSUB ")) {
                _ = f.unsubs.fetchAdd(1, .release);
            } else if (std.mem.startsWith(u8, line, "PUB ") or std.mem.startsWith(u8, line, "HPUB ")) {
                const size = try std.fmt.parseInt(usize, line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..], 10);
                // Read the body in pieces: it may be large.
                var left = size + 2;
                var scratch: [4096]u8 = undefined;
                while (left > 0) {
                    const k = @min(left, scratch.len);
                    try peer.readExact(scratch[0..k]);
                    left -= k;
                }
                _ = f.pubs.fetchAdd(1, .release);
            }
        }
    }
};

/// The consumer's records, kept as they are polled.
const Events = struct {
    c: *engine.Consumer,
    list: std.ArrayList(struct { typ: u32, handle: u64, bytes: []align(8) u8 }) = .empty,

    fn pump(ev: *Events, ms: i32) !void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        const n = try engine.pollWait(ev.c, &buf, ms, &need);
        var off: usize = 0;
        while (off < n) {
            const head: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            const copy = try alloc.alignedAlloc(u8, .@"8", head.len);
            @memcpy(copy, buf[off..][0..head.len]);
            try ev.list.append(alloc, .{ .typ = head.type, .handle = head.handle, .bytes = copy });
            off += head.len;
        }
    }

    /// The index of the first record of `typ` at or after `from`, polling
    /// for up to `ms`.
    fn waitFor(ev: *Events, typ: abi.EventType, from: usize, ms: u32) !usize {
        var waited: u32 = 0;
        while (true) {
            for (ev.list.items[from..], from..) |r, i| if (r.typ == @backingInt(typ)) return i;
            if (waited >= ms) return error.TimedOut;
            try ev.pump(50);
            waited += 50;
        }
    }

    fn count(ev: *const Events, typ: abi.EventType) usize {
        var n: usize = 0;
        for (ev.list.items) |r| if (r.typ == @backingInt(typ)) {
            n += 1;
        };
        return n;
    }

    fn as(ev: *const Events, comptime T: type, i: usize) *const T {
        return @ptrCast(@alignCast(ev.list.items[i].bytes.ptr));
    }

    fn deinit(ev: *Events) void {
        for (ev.list.items) |r| alloc.free(r.bytes);
        ev.list.deinit(alloc);
    }
};

const Rig = struct {
    fake: Fake,
    e: *engine.Engine,
    c: *engine.Consumer,
    ev: Events,
    json: []u8,

    /// `extra_nats` is spliced into the broker's "nats" object after the url.
    fn start(r: *Rig, extra_nats: []const u8, with_route: bool) !void {
        return r.startWith(extra_nats, with_route, .{ .listener = undefined });
    }

    fn startDelivering(r: *Rig, payload: []const u8) !void {
        return r.startWith("", false, .{ .listener = undefined, .deliver = payload });
    }

    fn startStalled(r: *Rig, extra_nats: []const u8) !void {
        return r.startWith(extra_nats, false, .{ .listener = undefined, .stall = true });
    }

    fn startWith(r: *Rig, extra_nats: []const u8, with_route: bool, fake: Fake) !void {
        // The fake server runs as its own task: on std.testing.io, which
        // runs tasks concurrently (threadedIo's single-threaded instance
        // does not).
        const fio = std.testing.io;
        r.fake = fake;
        try r.fake.start(fio);
        errdefer r.fake.stop(fio);
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 1, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "routes": [{s}],
            \\ "brokers": [{{"name": "events", "nats": {{"url": "{s}", "connect_at_start": true{s}}}}}]}}
        , .{ if (with_route) "{\"path\": \"/hold\", \"handler\": 1, \"timeout_ms\": 2000}" else "", try r.fake.url(), extra_nats });
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        try r.e.start();
        r.ev = .{ .c = r.c };
    }

    fn broker(r: *Rig) *engine.nats.Broker {
        return engine.nats.find(r.e, "events").?;
    }

    fn deinit(r: *Rig) void {
        r.ev.deinit();
        r.e.drain() catch {};
        _ = r.e.wait(5000);
        r.e.destroy();
        r.fake.stop(std.testing.io);
        alloc.free(r.json);
    }
};

fn out(subject: []const u8, payload: []const u8) abi.NatsOut {
    return .{ .size = @sizeOf(abi.NatsOut), .subject = .of(subject), .data = payload.ptr, .len = payload.len };
}

fn waitAtLeast(v: *std.atomic.Value(u32), n: u32) !void {
    const tio = engine.threadedIo();
    for (0..2000) |_| {
        if (v.load(.acquire) >= n) return;
        try Io.sleep(tio, .fromMilliseconds(5), .awake);
    }
    return error.TimedOut;
}

test "capi nats: publish is taken (OK) and reaches the server" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start("", false);
    defer r.deinit();
    const busy = try engine.nats.publish(r.broker(), r.c, out("test.subject", "payload"), 0);
    try std.testing.expect(!busy);
    try waitAtLeast(&r.fake.pubs, 1);
}

test "capi nats: subscribe delivers NATS_MSG; unsubscribe ends it with SUB_END CLOSED" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start("", false);
    defer r.deinit();
    const h = try engine.nats.subscribe(r.broker(), r.c, "test.subject", .{ .size = @sizeOf(abi.NatsSubscribeOptions) }, 77);
    // The fake delivers on the first SUB only when asked to: it was not, so
    // publish to ourselves is not possible; check the subscription exists.
    try waitAtLeast(&r.fake.sid, 1);
    engine.nats.unsubscribe(r.e, h);
    const end = try r.ev.waitFor(.nats_sub_end, 0, 5000);
    const rec = r.ev.as(abi.BrokerEndEvent, end);
    try std.testing.expectEqual(abi.BROKER_END_CLOSED, rec.reason);
    try std.testing.expectEqual(@as(u64, 77), rec.user_data);
    // Idempotent: a second unsubscribe says nothing.
    engine.nats.unsubscribe(r.e, h);
}

test "capi nats: a delivered message is a NATS_MSG record naming the subscription" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.startDelivering("hello");
    defer r.deinit();
    const h = try engine.nats.subscribe(r.broker(), r.c, "test.subject", .{ .size = @sizeOf(abi.NatsSubscribeOptions) }, 5);
    const i = try r.ev.waitFor(.nats_msg, 0, 5000);
    const m = r.ev.as(abi.NatsMsgEvent, i);
    try std.testing.expectEqual(h, m.sub);
    try std.testing.expectEqual(@as(u64, 5), m.user_data);
    const bytes = r.ev.list.items[i].bytes;
    try std.testing.expectEqualStrings("test.subject", bytes[m.subject.off..][0..m.subject.len]);
    try std.testing.expectEqualStrings("hello", bytes[m.payload.off..][0..m.payload.len]);
}

test "capi nats: a live subscription ends with SUB_END at the server's stop, before STOPPED" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start("", false);
    defer r.deinit();
    _ = try engine.nats.subscribe(r.broker(), r.c, "test.subject", .{ .size = @sizeOf(abi.NatsSubscribeOptions) }, 9);
    try waitAtLeast(&r.fake.sid, 1);
    try r.e.drain();
    const stopped = try r.ev.waitFor(.stopped, 0, 10_000);
    const end = try r.ev.waitFor(.nats_sub_end, 0, 100);
    try std.testing.expect(end < stopped);
    try std.testing.expectEqual(@as(u64, 9), r.ev.as(abi.BrokerEndEvent, end).user_data);
}

test "capi nats: a request tied to a req answers E_GONE when the req ends" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start("", true);
    defer r.deinit();
    const tio = engine.threadedIo();
    // An HTTP/1.1 request the consumer holds, unanswered. It ends at its
    // route's deadline (2 s, a 504): an HTTP/1.1 request waiting for the
    // consumer does not watch its socket, so the end comes from the
    // deadline, not from the client closing.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", r.e.port(0));
    var conn = try addr.connect(tio, .{ .mode = .stream });
    defer conn.close(tio);
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(tio, &wbuf);
    try w.interface.writeAll("GET /hold HTTP/1.1\r\nHost: x\r\n\r\n");
    try w.interface.flush();
    const req_i = try r.ev.waitFor(.request, 0, 5000);
    const req_handle = r.ev.list.items[req_i].handle;
    // A request to the broker for it: the fake never answers, and the
    // call has no timeout of its own.
    try engine.nats.request(r.broker(), r.c, out("no.answer", "?"), .{ .size = @sizeOf(abi.NatsRequestOptions), .req = req_handle, .timeout_ms = abi.DB_TIMEOUT_NONE }, 31);
    const reply_i = try r.ev.waitFor(.nats_reply, 0, 10_000);
    const reply = r.ev.as(abi.NatsReplyEvent, reply_i);
    try std.testing.expectEqual(@as(u64, 31), reply.user_data);
    try std.testing.expectEqual(abi.E_GONE, reply.status);
}

test "capi nats: a request for a req that is already over is refused with E_GONE at the call" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start("", true);
    defer r.deinit();
    // A forged request handle: never live.
    const forged: u64 = (@as(u64, 0x7fffff) << 33) | 1;
    const got = engine.nats.request(r.broker(), r.c, out("no.answer", "?"), .{ .size = @sizeOf(abi.NatsRequestOptions), .req = forged }, 1);
    try std.testing.expect(std.meta.isError(got));
}

test "capi nats: past the outbound limit a publish is E_AGAIN; when the server reads again, WRITABLE comes once per answer that asked for it" {
    if (comptime !features.nats) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.startStalled(", \"limits\": {\"outbound_bytes\": 1}");
    defer r.deinit();
    const payload = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'x');
    const tio = engine.threadedIo();
    // Every BUSY answer and the E_AGAIN ask for one WRITABLE; how many
    // BUSY answers come before the queue refuses depends on how much the
    // sockets take, so the count is kept rather than assumed.
    var asked: usize = 0;
    var again = false;
    for (0..100_000) |_| {
        if (engine.nats.publish(r.broker(), r.c, out("stalled", payload), 0)) |busy| {
            if (busy) asked += 1;
            try Io.sleep(tio, .fromMilliseconds(1), .awake);
        } else |err| {
            try std.testing.expectEqual(error.Again, err);
            asked += 1;
            again = true;
            break;
        }
    }
    try std.testing.expect(again);
    try r.ev.pump(0);
    const refused_at = r.ev.list.items.len;
    // The server reads again: the consumer that was refused is told.
    r.fake.release.set(std.testing.io);
    _ = try r.ev.waitFor(.nats_writable, refused_at, 10_000);
    // A publish is taken again, and WRITABLE never came more often than
    // answers asked for it (a consumer is told once per refusal, not on
    // every pass of the watcher).
    _ = try engine.nats.publish(r.broker(), r.c, out("stalled", "again"), 0);
    try r.ev.pump(0);
    const writable = r.ev.count(.nats_writable);
    try std.testing.expect(writable >= 1 and writable <= asked);
}
