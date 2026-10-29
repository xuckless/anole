//! The C ABI's Kafka produce path through the engine, against the in-process
//! broker (src/kafka/testing.zig): every produced record is answered once,
//! in order per key, and producing from several consumer threads while the
//! server stops answers every call. The engine is driven through its Zig
//! entry points, as in nats_test.zig. Waits poll the consumer with
//! generous bounds; no assertion is about time.
const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = engine.abi;
const features = anole.features;
const FakeBroker = if (features.kafka) anole.kafka.testing.FakeBroker else void;

const alloc = std.testing.allocator;
const Io = std.Io;

/// The DELIVERY records a consumer polled, by `user_data`.
const Deliveries = struct {
    c: *engine.Consumer,
    list: std.ArrayList(abi.KafkaDeliveryEvent) = .empty,
    stopped: bool = false,

    fn pump(d: *Deliveries, ms: i32) !void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        const n = try engine.pollWait(d.c, &buf, ms, &need);
        var off: usize = 0;
        while (off < n) {
            const head: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            if (head.type == @backingInt(abi.EventType.kafka_delivery)) {
                const ev: *const abi.KafkaDeliveryEvent = @ptrCast(@alignCast(&buf[off]));
                try d.list.append(alloc, ev.*);
            } else if (head.type == @backingInt(abi.EventType.stopped)) d.stopped = true;
            off += head.len;
        }
    }

    fn deinit(d: *Deliveries) void {
        d.list.deinit(alloc);
    }
};

const Rig = struct {
    broker: *FakeBroker,
    e: *engine.Engine,
    json: []u8,

    fn start(r: *Rig, consumers: []*engine.Consumer) !void {
        // The fake broker runs on std.testing.io, whose tasks run
        // concurrently with the engine's.
        const fio = std.testing.io;
        r.broker = try FakeBroker.start(alloc, fio, .{ .partitions = 3 });
        errdefer r.broker.deinit();
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 2, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "brokers": [{{"name": "log", "kafka": {{"brokers": ["{s}"], "producer": {{"linger_ms": 1}}}}}}]}}
        , .{r.broker.address()});
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        for (consumers) |*c| c.* = try r.e.attach(null, null, false);
        try r.e.start();
    }

    fn log(r: *Rig) *engine.kafka.Broker {
        return engine.kafka.find(r.e, "log").?;
    }

    fn stop(r: *Rig) void {
        r.e.drain() catch {};
        _ = r.e.wait(@intCast(wait.deadlineMs()));
    }

    fn deinit(r: *Rig) void {
        r.e.destroy();
        r.broker.deinit();
        alloc.free(r.json);
    }
};

fn out(topic: []const u8, key: []const u8, value: []const u8, flags: u32) abi.KafkaOut {
    return .{ .size = @sizeOf(abi.KafkaOut), .topic = .of(topic), .key = .of(key), .value = value.ptr, .len = value.len, .flags = flags };
}

fn pastDeadline(started: std.Io.Timestamp) bool {
    return started.untilNow(engine.threadedIo(), .awake).toMilliseconds() >= wait.deadlineMs();
}

test "capi kafka: every produced record gets one DELIVERY event, a key's records in order" {
    if (comptime !features.kafka) return error.SkipZigTest;
    var r: Rig = undefined;
    var cs: [1]*engine.Consumer = undefined;
    try r.start(&cs);
    defer r.deinit();
    defer r.stop();
    var d: Deliveries = .{ .c = cs[0] };
    defer d.deinit();

    const keys = [_][]const u8{ "a", "b", "c" };
    const n = 200;
    var reported: usize = 0;
    for (0..n) |i| {
        // Every 7th record asks for no report.
        const quiet = i % 7 == 3;
        const flags: u32 = if (quiet) abi.KAFKA_F_NO_REPORT else 0;
        _ = try engine.kafka.produce(r.log(), cs[0], out("orders", keys[i % keys.len], "v", flags), i + 1);
        if (!quiet) reported += 1;
    }
    const started = std.Io.Clock.awake.now(engine.threadedIo());
    while (d.list.items.len < reported) {
        if (pastDeadline(started)) return error.TimedOut;
        try d.pump(50);
    }
    // No more come: one per record, none for the quiet ones.
    try wait.expectStays(engine.threadedIo(), "no DELIVERY beyond one per reported record", &d, struct {
        fn same(dl: *Deliveries) !bool {
            const before = dl.list.items.len;
            try dl.pump(0);
            return dl.list.items.len == before;
        }
    }.same, wait.short_window);
    try std.testing.expectEqual(reported, d.list.items.len);

    var seen: [n + 1]bool = @splat(false);
    var last: [keys.len]i64 = @splat(-1);
    var by_key: [keys.len]std.ArrayList(abi.KafkaDeliveryEvent) = @splat(.empty);
    defer for (&by_key) |*l| l.deinit(alloc);
    for (d.list.items) |ev| {
        try std.testing.expectEqual(abi.OK, ev.status);
        const i: usize = @intCast(ev.user_data - 1);
        try std.testing.expect(i % 7 != 3);
        try std.testing.expect(!seen[i + 1]);
        seen[i + 1] = true;
        try by_key[i % keys.len].append(alloc, ev);
    }
    // A key's records were stored in the order they were produced.
    for (&by_key, 0..) |*l, k| {
        std.mem.sort(abi.KafkaDeliveryEvent, l.items, {}, struct {
            fn lt(_: void, x: abi.KafkaDeliveryEvent, y: abi.KafkaDeliveryEvent) bool {
                return x.user_data < y.user_data;
            }
        }.lt);
        for (l.items) |ev| {
            try std.testing.expect(ev.offset > last[k]);
            last[k] = ev.offset;
        }
    }
}

/// One consumer thread producing until the server refuses.
const Producer = struct {
    r: *Rig,
    c: *engine.Consumer,
    index: u64,
    taken: std.ArrayList(u64) = .empty,
    /// `taken.items.len`, for the test's thread.
    taken_count: std.atomic.Value(usize) = .init(0),
    deliveries: ?Deliveries = null,
    failure: ?anyerror = null,

    fn run(p: *Producer) void {
        p.runInner() catch |err| {
            p.failure = err;
        };
    }

    fn runInner(p: *Producer) !void {
        p.deliveries = .{ .c = p.c };
        const d = &p.deliveries.?;
        var i: u64 = 0;
        while (true) : (i += 1) {
            const ud = p.index << 32 | i;
            if (engine.kafka.produce(p.r.log(), p.c, out("race", "k", "v", 0), ud)) |_| {
                try p.taken.append(alloc, ud);
                _ = p.taken_count.fetchAdd(1, .release);
            } else |err| switch (err) {
                error.Again => {},
                error.State => break,
                else => return err,
            }
            if (i % 16 == 0) try d.pump(0);
        }
        // Collect what is still coming, until the consumer is stopped.
        const started = std.Io.Clock.awake.now(engine.threadedIo());
        while (!d.stopped) {
            if (pastDeadline(started)) return error.TimedOut;
            try d.pump(50);
        }
    }
};

test "capi kafka: [stress] produces from four consumer threads racing the stop" {
    if (comptime !features.kafka) return error.SkipZigTest;
    try wait.requireStress();
    var r: Rig = undefined;
    var cs: [4]*engine.Consumer = undefined;
    try r.start(&cs);
    defer r.deinit();
    var ps: [4]Producer = undefined;
    for (&ps, cs, 0..) |*p, c, i| p.* = .{ .r = &r, .c = c, .index = i };
    defer for (&ps) |*p| {
        p.taken.deinit(alloc);
        if (p.deliveries) |*d| d.deinit();
    };
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |t| t.join();
    for (&ps, &threads) |*p, *t| {
        t.* = try std.Thread.spawn(.{}, Producer.run, .{p});
        started += 1;
    }
    // Let every thread produce a while, then stop the server under them.
    try wait.waitUntil(engine.threadedIo(), "every consumer thread had a record taken", &ps, struct {
        fn all(list: *[4]Producer) bool {
            for (list) |*p| if (p.taken_count.load(.acquire) == 0) return false;
            return true;
        }
    }.all);
    r.stop();
    for (threads[0..started]) |t| t.join();
    started = 0;
    for (&ps) |*p| {
        if (p.failure) |err| return err;
        // At most one DELIVERY per record taken, none for one not taken.
        const d = &p.deliveries.?;
        std.mem.sort(u64, p.taken.items, {}, std.sort.asc(u64));
        var got: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer got.deinit(alloc);
        for (d.list.items) |ev| {
            const gop = try got.getOrPut(alloc, ev.user_data);
            try std.testing.expect(!gop.found_existing);
            try std.testing.expect(std.sort.binarySearch(u64, p.taken.items, ev.user_data, struct {
                fn order(a: u64, b: u64) std.math.Order {
                    return std.math.order(a, b);
                }
            }.order) != null);
        }
    }
}
