//! The client against the in-process broker (testing.zig): produce with
//! every codec, idempotent retries, errors, SASL, consumer groups with
//! rebalances, commits and dead letters. Runs in every `zig build test`;
//! live_test.zig covers real brokers.
const std = @import("std");
const zio = @import("zio");
const db = @import("../db/root.zig");
const kafka = @import("root.zig");
const records = @import("records.zig");
const FakeBroker = @import("testing.zig").FakeBroker;

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
    for (0..500) |_| {
        if (v.load(.acquire) >= want) return;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.TimedOut;
}

fn waitCommitted(io: std.Io, broker: *FakeBroker, group: []const u8, topic: []const u8, partition: i32, want: i64) !void {
    for (0..500) |_| {
        if ((broker.committed(group, topic, partition) orelse -1) >= want) return;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return error.TimedOut;
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

    // A topic that never appears fails once the call's timeout has passed.
    broker.hide_topics.store(true, .release);
    var o = opts(broker, .{});
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
    client.deinit();
    // Leaving the group removed the member.
    try testing.expectEqual(@as(usize, 0), broker.memberCount("g1"));
    try testing.expectEqual(@as(?i64, 3), broker.committed("g1", "orders", 1));
}

test "fake broker: two members share the partitions" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 4, .join_wait_ms = 400 });
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
    try waitCount(io, &Reads.seen, 4);
    try testing.expectEqual(@as(usize, 2), broker.memberCount("g2"));
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
