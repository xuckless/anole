//! The client against the in-process broker (testing.zig): produce with
//! every codec, idempotent retries, errors, SASL, consumer groups with
//! rebalances, commits and dead letters. Runs in every `zig build test`;
//! live_test.zig covers real brokers.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const kafka = @import("root.zig");
const records = @import("records.zig");
const FakeBroker = @import("testing.zig").FakeBroker;
const wait = @import("anole_test_wait");

const testing = std.testing;
const gpa = testing.allocator;

fn opts(broker: *const FakeBroker, producer: kafka.Options.Producer) kafka.Options {
    return .{
        .brokers = broker.bootstrap(),
        .producer = producer,
        .request_timeout = .fromSeconds(5),
        .timeout = .fromSeconds(10),
    };
}

fn waitCount(io: std.Io, v: *std.atomic.Value(u32), want: u32) !void {
    try wait.waitAtLeast(io, "the count reached what the test wants", v, want);
}

fn waitCommitted(io: std.Io, broker: *FakeBroker, group: []const u8, topic: []const u8, partition: i32, want: i64) !void {
    const Ctx = struct { broker: *FakeBroker, group: []const u8, topic: []const u8, partition: i32, want: i64 };
    try wait.waitUntil(io, "the broker has the committed offset", Ctx{ .broker = broker, .group = group, .topic = topic, .partition = partition, .want = want }, struct {
        fn committed(c: Ctx) bool {
            return (c.broker.committed(c.group, c.topic, c.partition) orelse -1) >= c.want;
        }
    }.committed);
}

test "fake broker: produce with every codec, keys keep their partition, send and flush" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 4 });
    defer broker.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    inline for (.{ .none, .gzip, .zstd, .lz4 }) |codec| {
        const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1), .compression = codec }));
        defer client.deinit();
        const topic = "codec-" ++ @tagName(codec);
        const a = try client.produce(&c, .{ .topic = topic, .key = "user-1", .value = "first", .headers = &.{.{ .key = "h", .value = "v" }} });
        const b = try client.produce(&c, .{ .topic = topic, .key = "user-1", .value = "second" });
        // The same key, the same partition, in order.
        try testing.expectEqual(a.partition, b.partition);
        try testing.expectEqual(a.offset + 1, b.offset);
        try testing.expectEqual(@as(i32, @intCast(@import("murmur2.zig").partition("user-1", 4))), a.partition);
        // send + flush
        for (0..20) |i| {
            var buf: [16]u8 = undefined;
            try client.send(&c, .{ .topic = topic, .key = "user-1", .value = std.fmt.bufPrint(&buf, "m{d}", .{i}) catch unreachable });
        }
        try client.flush(&c);
        const stored = try broker.stored(arena.allocator(), topic, @intCast(a.partition));
        try testing.expectEqual(@as(usize, 22), stored.len);
        try testing.expectEqualStrings("first", stored[0].value.?);
        try testing.expectEqualStrings("v", stored[0].headers[0].value.?);
        try testing.expectEqualStrings("m19", stored[21].value.?);
    }
}

test "fake broker: a record produced from a request that passes an unsampled caller on keeps traceparent -00" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    // As the tracing middleware leaves a request it does not record
    // (`sample_all` off, caller unsampled): the caller's IDs, as they came.
    var keys: [1][]const u8 = undefined;
    var values: [1][]const u8 = undefined;
    var hashes: [1]u8 = undefined;
    var req: dusty.Request = .{ .arena = arena.allocator(), .io = io, ._parser = undefined, ._transport = undefined };
    req.headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    const caller = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00";
    try req.headers.add("traceparent", caller);
    req.trace_id = "0af7651916cd43dd8448eb211c80319c";
    req.span_id = "b7ad6b7169203331";
    _ = try client.produce(&req, .{ .topic = "traced", .value = "v" });
    const stored = try broker.stored(arena.allocator(), "traced", 0);
    try testing.expectEqual(@as(usize, 1), stored.len);
    var got: ?[]const u8 = null;
    for (stored[0].headers) |h| if (std.mem.eql(u8, h.key, "traceparent")) {
        got = h.value;
    };
    try testing.expectEqualStrings(caller, got orelse return error.NoTraceparent);
}

test "fake broker: a retriable error is retried, a lost reply is not duplicated" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    _ = try client.produce(&c, .{ .topic = "t", .value = "warm" });
    // NOT_LEADER_OR_FOLLOWER twice: the metadata is refreshed and the batch sent again.
    broker.fail_produce.store(2, .release);
    const d = try client.produce(&c, .{ .topic = "t", .value = "after-errors" });
    try testing.expect(d.offset >= 1);
    try testing.expect(broker.produce_requests.load(.monotonic) >= 4);

    // Stored, then the connection drops before the answer: the resend has
    // the same sequence number, the broker says DUPLICATE_SEQUENCE_NUMBER,
    // and the record is there once.
    broker.drop_after_store.store(1, .release);
    _ = try client.produce(&c, .{ .topic = "t", .value = "once" });
    const stored = try broker.stored(arena.allocator(), "t", 0);
    var n: usize = 0;
    for (stored) |r| if (std.mem.eql(u8, r.value.?, "once")) {
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
}

test "fake broker: a topic being auto-created is waited for; one that never appears fails" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 2 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    broker.creating_answers.store(3, .release);
    const d = try client.produce(&c, .{ .topic = "fresh", .key = "k", .value = "v" });
    try testing.expectEqualStrings("fresh", d.topic);
    try testing.expectEqual(@as(u32, 0), broker.creating_answers.load(.acquire));
    try testing.expectEqual(@as(i64, 1), broker.count("fresh", @intCast(d.partition)));

    // A topic that never appears fails after metadata_wait, though the
    // call's own timeout is far longer; then after a shorter call timeout.
    broker.hide_topics.store(true, .release);
    var o = opts(broker, .{ .metadata_wait = .fromMilliseconds(200) });
    o.timeout = .fromSeconds(600);
    const waiting = try kafka.Client.init(gpa, io, o);
    defer waiting.deinit();
    try testing.expectError(error.Database, waiting.produce(&c, .{ .topic = "absent", .value = "v" }));
    try testing.expectEqualStrings("UNKNOWN_TOPIC_OR_PARTITION", db.lastError(&c).?.code);
    o = opts(broker, .{ .metadata_wait = .fromSeconds(600) });
    o.timeout = .fromMilliseconds(200);
    const short = try kafka.Client.init(gpa, io, o);
    defer short.deinit();
    try testing.expectError(error.Database, short.produce(&c, .{ .topic = "absent", .value = "v" }));
    try testing.expectEqualStrings("UNKNOWN_TOPIC_OR_PARTITION", db.lastError(&c).?.code);
}

test "fake broker: errors are anole.db errors with the code in lastError" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    var o = opts(broker, .{ .linger = .fromSeconds(60), .batch_bytes = 1024, .buffer_bytes = 4096 });
    o.timeout = .fromMilliseconds(300);
    const client = try kafka.Client.init(gpa, io, o);
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    // A record bigger than a request.
    const big = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try testing.expectError(error.Database, client.send(&c, .{ .topic = "t", .value = big }));
    try testing.expectEqualStrings("MESSAGE_TOO_LARGE", db.lastError(&c).?.code);

    // The buffer fills (the broker refuses everything, so nothing is acknowledged).
    broker.fail_produce.store(1000, .release);
    var failed = false;
    for (0..64) |_| {
        client.send(&c, .{ .topic = "t", .value = "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy" }) catch |err| {
            try testing.expectEqual(error.ServiceUnavailable, err);
            try testing.expectEqualStrings("buffer_full", db.lastError(&c).?.code);
            failed = true;
            break;
        };
    }
    try testing.expect(failed);
    try testing.expect(!client.writable());

    // produce() with nothing delivered within the timeout fails (the buffer is full, too).
    if (client.produce(&c, .{ .topic = "t2", .value = "x" })) |_| {
        return error.ShouldHaveFailed;
    } else |err| try testing.expect(err == error.GatewayTimeout or err == error.ServiceUnavailable);
    broker.fail_produce.store(0, .release);
}

test "fake broker: SASL PLAIN and SCRAM, and a wrong password" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    inline for (.{ .plain, .scram_sha_256, .scram_sha_512 }) |mech| {
        const sasl_mech = comptime switch (mech) {
            .plain => @import("sasl.zig").Mechanism.plain,
            .scram_sha_256 => @import("sasl.zig").Mechanism.scram_sha_256,
            else => @import("sasl.zig").Mechanism.scram_sha_512,
        };
        const broker = try FakeBroker.start(gpa, io, .{ .sasl = .{ .mechanism = sasl_mech, .username = "alice", .password = "s3cret" } });
        defer broker.deinit();
        var o = opts(broker, .{ .linger = .fromMilliseconds(1) });
        o.sasl = .{ .mechanism = mech, .username = "alice", .password = "s3cret" };
        const client = try kafka.Client.init(gpa, io, o);
        defer client.deinit();
        const d = try client.produce(&c, .{ .topic = "t", .value = "hello" });
        try testing.expectEqual(@as(i64, 0), d.offset);

        var bad = o;
        bad.sasl = .{ .mechanism = mech, .username = "alice", .password = "wrong" };
        const bad_client = try kafka.Client.init(gpa, io, bad);
        defer bad_client.deinit();
        const level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = level;
        try testing.expectError(error.Database, bad_client.produce(&c, .{ .topic = "t", .value = "hello" }));
        try testing.expectEqualStrings("SASL_AUTHENTICATION_FAILED", db.lastError(&c).?.code);
    }
}

const Reads = struct {
    var seen: std.atomic.Value(u32) = .init(0);
    var sum: std.atomic.Value(u32) = .init(0);
    var poison_tries: std.atomic.Value(u32) = .init(0);

    fn on(msg: *kafka.Msg) !void {
        _ = seen.fetchAdd(1, .monotonic);
        _ = sum.fetchAdd(@intCast(msg.value.?.len), .monotonic);
        try testing.expect(msg.key != null);
        try testing.expect(std.mem.startsWith(u8, msg.id, "kafka-orders-"));
    }

    fn poison(msg: *kafka.Msg) !void {
        if (std.mem.eql(u8, msg.value.?, "poison")) {
            _ = poison_tries.fetchAdd(1, .monotonic);
            return error.BadRecord;
        }
        _ = seen.fetchAdd(1, .monotonic);
    }
};

test "fake broker: a consumer group reads from the start, commits, and leaves" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 2 });
    defer broker.deinit();
    try broker.preload("orders", 0, &.{
        .{ .key = "a", .value = "1", .timestamp_ms = 1 },
        .{ .key = "a", .value = "22", .timestamp_ms = 2 },
        .{ .key = "a", .value = "333", .timestamp_ms = 3 },
    });
    try broker.preload("orders", 1, &.{
        .{ .key = "b", .value = "4444", .timestamp_ms = 4 },
        .{ .key = "b", .value = "55555", .timestamp_ms = 5 },
    });
    Reads.seen.store(0, .release);
    Reads.sum.store(0, .release);

    const client = try kafka.Client.init(gpa, io, opts(broker, .{}));
    // The deinit below is the leave under test; until then a failed wait
    // must still stop the consumer's tasks.
    var client_live = true;
    errdefer if (client_live) client.deinit();
    try client.consume({}, .{
        .group = "g1",
        .topics = &.{"orders"},
        .start = .earliest,
        .heartbeat_interval = .fromMilliseconds(100),
        .commit_interval = .fromMilliseconds(100),
    }, Reads.on);
    try client.start(null, null, null);
    try waitCount(io, &Reads.seen, 5);
    try testing.expectEqual(@as(u32, 1 + 2 + 3 + 4 + 5), Reads.sum.load(.acquire));
    try waitCommitted(io, broker, "g1", "orders", 0, 3);
    try waitCommitted(io, broker, "g1", "orders", 1, 2);
    // More records arrive while it runs.
    try broker.preload("orders", 1, &.{.{ .key = "b", .value = "6", .timestamp_ms = 6 }});
    try waitCount(io, &Reads.seen, 6);
    client_live = false;
    client.deinit();
    // Leaving the group removed the member.
    try testing.expectEqual(@as(usize, 0), broker.memberCount("g1"));
    try testing.expectEqual(@as(?i64, 3), broker.committed("g1", "orders", 1));
}

test "fake broker: two members share the partitions" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 4 });
    defer broker.deinit();
    for (0..4) |p| try broker.preload("orders", p, &.{.{ .key = "k", .value = "x", .timestamp_ms = 1 }});
    Reads.seen.store(0, .release);
    Reads.sum.store(0, .release);

    const client = try kafka.Client.init(gpa, io, opts(broker, .{}));
    defer client.deinit();
    try client.consume({}, .{
        .group = "g2",
        .topics = &.{"orders"},
        .start = .earliest,
        .members = 2,
        .assignor = .roundrobin,
        .heartbeat_interval = .fromMilliseconds(100),
        .commit_interval = .fromMilliseconds(100),
    }, Reads.on);
    try client.start(null, null, null);
    // Both members joined and a round with both of them completed.
    const Shared = struct {
        fn twoMembersSynced(b: *FakeBroker) bool {
            var out: [4]usize = undefined;
            const counts = b.assignedCounts("g2", &out) orelse return false;
            return counts.len == 2 and counts[0] + counts[1] == 4;
        }
    };
    try wait.waitUntil(io, "a completed round with both members", broker, Shared.twoMembersSynced);
    var out: [4]usize = undefined;
    const counts = broker.assignedCounts("g2", &out).?;
    try testing.expectEqualSlices(usize, &.{ 2, 2 }, counts);

    try waitCount(io, &Reads.seen, 4);
    for (0..4) |p| try waitCommitted(io, broker, "g2", "orders", @intCast(p), 1);
}

test "fake broker: a record that keeps failing goes to the dead letter topic" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    try broker.preload("jobs", 0, &.{
        .{ .key = "k", .value = "ok-1", .timestamp_ms = 1 },
        .{ .key = "k", .value = "poison", .timestamp_ms = 2 },
        .{ .key = "k", .value = "ok-2", .timestamp_ms = 3 },
    });
    Reads.seen.store(0, .release);
    Reads.poison_tries.store(0, .release);

    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    try client.consume({}, .{
        .group = "g3",
        .topics = &.{"jobs"},
        .start = .earliest,
        .heartbeat_interval = .fromMilliseconds(100),
        .commit_interval = .fromMilliseconds(100),
        .retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(5), .max = .fromMilliseconds(20) } },
        .dead_letter = "jobs.dlt",
    }, Reads.poison);
    try client.start(null, null, null);
    // The two good records are handled, the poison one three times.
    try waitCount(io, &Reads.seen, 2);
    try waitCommitted(io, broker, "g3", "jobs", 0, 3);
    try testing.expectEqual(@as(u32, 3), Reads.poison_tries.load(.acquire));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..1) |p| {
        const dlt = try broker.stored(arena.allocator(), "jobs.dlt", p);
        if (dlt.len == 0) continue;
        try testing.expectEqualStrings("poison", dlt[0].value.?);
        var found_topic = false;
        for (dlt[0].headers) |h| if (std.mem.eql(u8, h.key, "anole-dlt-topic")) {
            found_topic = true;
            try testing.expectEqualStrings("jobs", h.value.?);
        };
        try testing.expect(found_topic);
        return;
    }
    return error.NothingDeadLettered;
}

test "fake broker: a metadata ping answers, and a dead address does not" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{});
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{}));
    defer client.deinit();
    try testing.expect(client.ping());

    var o = opts(broker, .{});
    o.brokers = &.{"127.0.0.1:1"};
    o.connect_timeout = .fromMilliseconds(300);
    const dead = try kafka.Client.init(gpa, io, o);
    defer dead.deinit();
    try testing.expect(!dead.ping());
}

test "fake broker: a broker serving Produce 0-7 and ListOffsets 0-4 (Redpanda) is spoken to at those versions" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    // A current broker gets the newest version.
    {
        const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
        defer broker.deinit();
        const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
        defer client.deinit();
        _ = try client.produce(&c, .{ .topic = "t", .value = "v" });
        try testing.expectEqual(@as(i16, 8), broker.produce_version.load(.acquire));
    }

    // Redpanda's ranges: Produce v7 out and back, then a group reading from
    // the start, which asks ListOffsets for the earliest offset.
    {
        const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1, .serves = &.{
            .{ .key = 0, .min = 0, .max = 7 },
            .{ .key = 2, .min = 0, .max = 4 },
        } });
        defer broker.deinit();
        const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
        errdefer client.deinit();
        const a = try client.produce(&c, .{ .topic = "t", .key = "a", .value = "1" });
        const b = try client.produce(&c, .{ .topic = "t", .key = "a", .value = "22" });
        try testing.expectEqual(a.offset + 1, b.offset);
        try testing.expectEqual(@as(i16, 7), broker.produce_version.load(.acquire));
        try broker.preload("orders", 0, &.{
            .{ .key = "a", .value = "1", .timestamp_ms = 1 },
            .{ .key = "a", .value = "22", .timestamp_ms = 2 },
        });
        Reads.seen.store(0, .release);
        Reads.sum.store(0, .release);
        try client.consume({}, .{
            .group = "g-old",
            .topics = &.{"orders"},
            .start = .earliest,
            .heartbeat_interval = .fromMilliseconds(100),
            .commit_interval = .fromMilliseconds(100),
        }, Reads.on);
        try client.start(null, null, null);
        try waitCount(io, &Reads.seen, 2);
        try testing.expectEqual(@as(u32, 1 + 2), Reads.sum.load(.acquire));
        client.deinit();
    }

    // Produce 0-6 is below what the client speaks: the broker is refused.
    {
        const broker = try FakeBroker.start(gpa, io, .{ .serves = &.{.{ .key = 0, .min = 0, .max = 6 }} });
        defer broker.deinit();
        const client = try kafka.Client.init(gpa, io, opts(broker, .{}));
        defer client.deinit();
        const level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = level;
        try testing.expect(!client.ping());
    }
}
