//! C ABI tests for p3/realtime (watch), imported from engine_test.zig:
//! listeners over a fake source, bounds and gaps, formats, the end of a
//! listener, and handle kinds.

const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const sse_test = @import("sse_test.zig");
const abi = engine.abi;
const features = anole.features;
const zio = anole.zio;
const alloc = std.testing.allocator;

/// The records a consumer polled, in order, copied.
const Rx = struct {
    c: *engine.Consumer,
    recs: std.ArrayList([]align(8) u8) = .empty,
    next_at: usize = 0,

    fn deinit(rx: *Rx) void {
        for (rx.recs.items) |r| alloc.free(r);
        rx.recs.deinit(alloc);
    }

    /// One poll, waiting up to `ms`; the records are kept.
    fn pump(rx: *Rx, ms: i32) !void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        const n = try engine.pollWait(rx.c, &buf, ms, &need);
        var off: usize = 0;
        while (off < n) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            const copy = try alloc.alignedAlloc(u8, .@"8", ev.len);
            @memcpy(copy, buf[off..][0..ev.len]);
            try rx.recs.append(alloc, copy);
            off += ev.len;
        }
    }

    /// The next watch record that is not a plain connection status,
    /// waiting up to `wait.deadline()`.
    fn next(rx: *Rx) ![]align(8) u8 {
        const tio = engine.threadedIo();
        const started = std.Io.Clock.awake.now(tio);
        while (started.untilNow(tio, .awake).nanoseconds < wait.deadline().nanoseconds) {
            while (rx.next_at < rx.recs.items.len) {
                const r = rx.recs.items[rx.next_at];
                rx.next_at += 1;
                const ev: *const abi.Event = @ptrCast(@alignCast(r.ptr));
                if (ev.type == @backingInt(abi.EventType.watch_status)) {
                    const st: *const abi.WatchStatusEvent = @ptrCast(@alignCast(r.ptr));
                    if (st.status == abi.WATCH_CONNECTED or st.status == abi.WATCH_DISCONNECTED) continue;
                }
                if (ev.type == @backingInt(abi.EventType.watch_event) or ev.type == @backingInt(abi.EventType.watch_status) or ev.type == @backingInt(abi.EventType.watch_end)) return r;
            }
            try rx.pump(25);
        }
        std.debug.print("timed out waiting for a watch record\n", .{});
        return error.TimedOut;
    }
};

fn text(rec: []const u8, s: abi.Span) []const u8 {
    return rec[s.off..][0..s.len];
}

const json_both =
    \\{"executors": 1, "timeouts": {"request_ms": 3000, "shutdown_ms": 1000},
    \\ "sse": {"heartbeat_ms": null},
    \\ "databases": [{"name": "r", "redis": {"url": "redis://127.0.0.1:1"}}],
    \\ "watches": [
    \\   {"name": "orders", "database": "r", "redis": {"channels": ["orders"]}, "to": [{"sse": "orders"}]},
    \\   {"name": "feed", "database": "r", "redis_stream": {"keys": ["events"]}}
    \\ ],
    \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
    \\ "routes": [{"path": "/me", "sse": {"handler": 7}}]}
;

fn listenOpts(max_events: u32, format: u32) abi.WatchListenOptions {
    return .{ .size = @sizeOf(abi.WatchListenOptions), .max_events = max_events, .format = format };
}

/// An engine with the "orders" (Redis channel) and "feed" (Redis stream)
/// watches over fake sources, and a consumer this thread polls.
const WatchRig = struct {
    e: *engine.Engine,
    rx: Rx,
    orders: *engine.watch.Entry,
    feed: *engine.watch.Entry,
    drained: bool = false,

    fn init(r: *WatchRig) !void {
        var why_buf: [256]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(json_both, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer e.destroy();
        const c = try e.attach(null, null, true);
        try e.start();
        r.* = .{ .e = e, .rx = .{ .c = c }, .orders = engine.watch.find(e, "orders").?, .feed = engine.watch.find(e, "feed").? };
        r.orders.w._fake();
        r.feed.w._fake();
    }

    fn deinit(r: *WatchRig) void {
        if (!r.drained) {
            r.e.drain() catch {};
            _ = r.e.wait(@intCast(wait.deadlineMs()));
        }
        r.rx.deinit();
        r.e.destroy();
    }
};

fn injectOrder(r: *WatchRig, i: usize) void {
    var data: [16]u8 = undefined;
    r.orders.w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = std.fmt.bufPrint(&data, "payload {d}", .{i}) catch unreachable });
}

test "capi engine: a bounded watch listener drops the overflow and reports one GAP with the count" {
    if (comptime !features.redis) return error.SkipZigTest;
    var r: WatchRig = undefined;
    try r.init();
    defer r.deinit();
    try std.testing.expect(engine.watch.find(r.e, "nope") == null);

    // Bounded: two events fit, the rest are counted.
    _ = try engine.watch.listen(r.e, r.orders, r.rx.c, listenOpts(2, abi.WATCH_NATIVE), 77);
    for (0..5) |i| injectOrder(&r, i);
    for (0..2) |i| {
        const rec = try r.rx.next();
        const ev: *const abi.WatchEvent = @ptrCast(@alignCast(rec.ptr));
        try std.testing.expectEqual(@as(u32, @backingInt(abi.EventType.watch_event)), ev.ev.type);
        try std.testing.expectEqual(@as(u64, 77), ev.user_data);
        try std.testing.expectEqual(@as(u16, abi.WATCH_SRC_REDIS), ev.source);
        try std.testing.expectEqual(@as(u16, abi.WATCH_OP_MESSAGE), ev.op);
        try std.testing.expectEqual(abi.WATCH_FMT_TEXT, ev.format);
        try std.testing.expectEqualStrings("orders", text(rec, ev.channel));
        var want: [16]u8 = undefined;
        try std.testing.expectEqualStrings(std.fmt.bufPrint(&want, "payload {d}", .{i}) catch unreachable, text(rec, ev.data));
    }
    // Room again: the next accepted event is preceded by one GAP with the count.
    injectOrder(&r, 5);
    const rec = try r.rx.next();
    const st: *const abi.WatchStatusEvent = @ptrCast(@alignCast(rec.ptr));
    try std.testing.expectEqual(@as(u32, @backingInt(abi.EventType.watch_status)), st.ev.type);
    try std.testing.expectEqual(abi.WATCH_GAP, st.status);
    try std.testing.expectEqual(@as(u64, 3), st.dropped);
    const rec2 = try r.rx.next();
    const ev: *const abi.WatchEvent = @ptrCast(@alignCast(rec2.ptr));
    try std.testing.expectEqual(@as(u32, @backingInt(abi.EventType.watch_event)), ev.ev.type);
    try std.testing.expectEqualStrings("payload 5", text(rec2, ev.data));
}

test "capi engine: a watch stream entry arrives as FIELDS natively and as JSON when asked" {
    if (comptime !features.redis) return error.SkipZigTest;
    var r: WatchRig = undefined;
    try r.init();
    defer r.deinit();
    const hf = try engine.watch.listen(r.e, r.feed, r.rx.c, listenOpts(0, abi.WATCH_NATIVE), 1);
    const hj = try engine.watch.listen(r.e, r.feed, r.rx.c, listenOpts(0, abi.WATCH_JSON), 2);
    r.feed.w._inject(.{
        .op = .entry,
        .op_name = "entry",
        .channel = "events",
        .position = "1-0",
        .data = "{\"a\":\"1\",\"b\":\"2\"}",
        .fields = &.{ .{ "a", "1" }, .{ "b", "2" } },
    });
    var saw_fields = false;
    var saw_json = false;
    for (0..2) |_| {
        const rec = try r.rx.next();
        const ev: *const abi.WatchEvent = @ptrCast(@alignCast(rec.ptr));
        try std.testing.expectEqual(@as(u16, abi.WATCH_SRC_REDIS_STREAM), ev.source);
        try std.testing.expectEqualStrings("1-0", text(rec, ev.position));
        if (ev.ev.handle == hf) {
            saw_fields = true;
            try std.testing.expectEqual(abi.WATCH_FMT_FIELDS, ev.format);
            try std.testing.expectEqual(@as(u32, 2), ev.nfields);
            const spans: [*]align(1) const abi.Span = @ptrCast(rec[ev.fields_off..].ptr);
            try std.testing.expectEqualStrings("a", text(rec, spans[0]));
            try std.testing.expectEqualStrings("1", text(rec, spans[1]));
            try std.testing.expectEqualStrings("b", text(rec, spans[2]));
            try std.testing.expectEqualStrings("2", text(rec, spans[3]));
        } else {
            try std.testing.expectEqual(hj, ev.ev.handle);
            saw_json = true;
            try std.testing.expectEqual(abi.WATCH_FMT_JSON, ev.format);
            try std.testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"2\"}", text(rec, ev.data));
        }
    }
    try std.testing.expect(saw_fields and saw_json);
}

test "capi engine: unlisten ends a watch listener with one END UNLISTENED; the handle is over after" {
    if (comptime !features.redis) return error.SkipZigTest;
    var r: WatchRig = undefined;
    try r.init();
    defer r.deinit();
    const h = try engine.watch.listen(r.e, r.feed, r.rx.c, listenOpts(0, abi.WATCH_NATIVE), 1);
    try engine.watch.unlisten(r.e, h);
    const rec = try r.rx.next();
    const en: *const abi.WatchEndEvent = @ptrCast(@alignCast(rec.ptr));
    try std.testing.expectEqual(@as(u32, @backingInt(abi.EventType.watch_end)), en.ev.type);
    try std.testing.expectEqual(abi.WATCH_END_UNLISTENED, en.reason);
    try std.testing.expectEqual(h, en.ev.handle);
    const NoSecondEnd = struct {
        rx: *Rx,
        h: @TypeOf(h),
        fn none(s: *@This()) anyerror!bool {
            try s.rx.pump(0);
            for (s.rx.recs.items[s.rx.next_at..]) |later| {
                const ev: *const abi.Event = @ptrCast(@alignCast(later.ptr));
                if (ev.type == @backingInt(abi.EventType.watch_end) and ev.handle == s.h) return false;
            }
            return true;
        }
    };
    var no_second: NoSecondEnd = .{ .rx = &r.rx, .h = h };
    try wait.expectStays(std.testing.io, "no second watch END for the handle", &no_second, NoSecondEnd.none, wait.short_window);
    try std.testing.expectError(error.Over, engine.watch.unlisten(r.e, h));
}

test "capi engine: the drain ends every watch listener with END DRAINED" {
    if (comptime !features.redis) return error.SkipZigTest;
    var r: WatchRig = undefined;
    try r.init();
    defer r.deinit();
    const h = try engine.watch.listen(r.e, r.orders, r.rx.c, listenOpts(2, abi.WATCH_NATIVE), 77);
    const hj = try engine.watch.listen(r.e, r.feed, r.rx.c, listenOpts(0, abi.WATCH_JSON), 2);
    try r.e.drain();
    r.drained = true;
    var ended: usize = 0;
    while (ended < 2) {
        const rec = try r.rx.next();
        const ev: *const abi.Event = @ptrCast(@alignCast(rec.ptr));
        if (ev.type != @backingInt(abi.EventType.watch_end)) continue;
        const en: *const abi.WatchEndEvent = @ptrCast(@alignCast(rec.ptr));
        try std.testing.expectEqual(abi.WATCH_END_DRAINED, en.reason);
        try std.testing.expect(ev.handle == h or ev.handle == hj);
        ended += 1;
    }
    try std.testing.expect(r.e.wait(@intCast(wait.deadlineMs())));
}

test "capi engine: handle kinds: an sse handle given to ws_send, a watch handle to sse_send: Invalid; release works on both" {
    if (comptime !features.redis or !features.websocket) return error.SkipZigTest;
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json_both, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    var a: sse_test.SseConsumer = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, sse_test.SseConsumer.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const orders = engine.watch.find(e, "orders").?;
    orders.w._fake();
    const wh = try engine.watch.listen(e, orders, c, listenOpts(0, abi.WATCH_NATIVE), 5);

    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(kindsCheck, .{ &a, e.port(0), io, wh });
    try f.await(io);
    try e.drain();
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
}

fn kindsCheck(a: *sse_test.SseConsumer, port: u16, io: std.Io, wh: u64) !void {
    const e = a.e;
    var cl: sse_test.RawSse = undefined;
    try cl.open(io, port, "/me", "");
    defer cl.close(io);
    try wait.waitAtLeast(io, "the consumer saw the subscribe", &a.subscribes, 1);
    const sh = try wait.waitNonZero(io, "the consumer stored the subscriber's handle", &a.handles[0]);
    try std.testing.expectError(error.WrongKind, engine.ws.send(e, sh, abi.WS_TEXT, "x", false));
    try std.testing.expectError(error.WrongKind, engine.sse.send(e, wh, "", "x"));
    // Release works for both kinds.
    try engine.watch.release(e, wh);
    try engine.sse.release(e, sh);
}
