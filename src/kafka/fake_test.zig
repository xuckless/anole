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

// ---------------------------------------------------------------------------
// SAFETY.md §8 step 4: nothing waits under the producer's, the cluster's or
// the client's locks (forced interleavings through test_hold.zig).

const hold_mod = @import("test_hold.zig");
const TestHold = hold_mod.TestHold;

/// What a task of a test did: set once, then `done`.
const TaskResult = struct {
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    delivery: ?kafka.Delivery = null,

    fn finish(r: *TaskResult) void {
        r.done.store(true, .release);
    }

    fn wait(r: *TaskResult, io: std.Io) !void {
        try wait_mod.waitFlag(io, "the test's task finished", &r.done);
        if (r.err) |e| return e;
    }
};
const wait_mod = wait;

fn produceTask(client: *kafka.Client, io: std.Io, record: kafka.Record, out: *TaskResult) std.Io.Cancelable!void {
    defer out.finish();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    out.delivery = client.produce(&c, record) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            out.err = err;
            return;
        },
    };
}

test "kafka producer: a record whose sender starts while the producing task is suspended at the spawn is delivered" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();

    var hold: TestHold = .{ .point = .sender_spawned };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    var result: TaskResult = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // The first record of a topic starts its leader's sender: the producing
    // task stops right after that spawn, where zio's spawn backpressure can
    // suspend it.
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, produceTask, .{ client, io, kafka.Record{ .topic = "spawned", .value = "v" }, &result });
    try wait.waitFlag(io, "the producing task is held at the sender's spawn", &hold.held);
    hold.let(io);
    try result.wait(io);
    try testing.expectEqual(@as(i64, 0), result.delivery.?.offset);
    try testing.expectEqual(@as(i64, 1), broker.count("spawned", 0));
}

const Joined = struct {
    var seen: std.atomic.Value(u32) = .init(0);

    fn on(_: ?*anyopaque, _: *kafka.Msg) anyerror!void {
        _ = seen.fetchAdd(1, .monotonic);
    }
};

fn consumeTask(client: *kafka.Client, out: *TaskResult) std.Io.Cancelable!void {
    defer out.finish();
    _ = client.consumeRaw(.{
        .group = "late",
        .topics = &.{"joined"},
        .start = .earliest,
        .heartbeat_interval = .fromMilliseconds(100),
        .commit_interval = .fromMilliseconds(100),
    }, Joined.on, null) catch |err| {
        out.err = err;
    };
}

test "kafka: a consumer group added after start joins while its member spawn is suspended" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    try client.start(null, null, null);
    Joined.seen.store(0, .release);

    var hold: TestHold = .{ .point = .member_spawned };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    var result: TaskResult = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // Serving has started, so the group joins at once: the adding task
    // stops right after its member's spawn.
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, consumeTask, .{ client, &result });
    try wait.waitFlag(io, "the adding task is held at the member's spawn", &hold.held);
    hold.let(io);
    try result.wait(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    _ = try client.produce(&c, .{ .topic = "joined", .value = "v" });
    try waitCount(io, &Joined.seen, 1);
}

test "kafka producer: after a producer id reset, the broker refuses no batch as out of order" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    // Two leaders: partition 0 on broker id 0 (its sender on executor 0),
    // partition 1 on broker id 1 (executor 1).
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 2, .nodes = 2 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    // Both partitions numbered past 0 under the first producer id.
    for (0..3) |_| {
        _ = try client.produce(&c, .{ .topic = "ids", .value = "warm", .partition = 0 });
        _ = try client.produce(&c, .{ .topic = "ids", .value = "warm", .partition = 1 });
    }

    // The next Produce is refused with UNKNOWN_PRODUCER_ID: partition 0's
    // sender resets the id and stops right after.
    broker.fail_code.store(59, .release);
    broker.fail_produce.store(1, .release);
    var hold: TestHold = .{ .point = .pid_reset };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    var result: TaskResult = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try dusty.placement.concurrent(&group, io, .{ .executor = 1 }, produceTask, .{ client, io, kafka.Record{ .topic = "ids", .value = "after-reset", .partition = 0 }, &result });
    try wait.waitFlag(io, "partition 0's sender is held after the id reset", &hold.held);
    // Meanwhile partition 1's sender takes a new id and sends.
    const other = try client.produce(&c, .{ .topic = "ids", .value = "other", .partition = 1 });
    try testing.expectEqual(@as(i32, 1), other.partition);
    hold.let(io);
    try result.wait(io);
    try testing.expectEqual(@as(u32, 0), broker.out_of_order.load(.monotonic));
    try testing.expectEqual(@as(i64, 4), broker.count("ids", 0));
    try testing.expectEqual(@as(i64, 4), broker.count("ids", 1));
}

/// An allocator that fails the `fail_at`-th allocation made by the thread
/// that armed it (other threads pass through), counting from the arming.
const FailNth = struct {
    backing: std.mem.Allocator,
    thread: std.atomic.Value(std.Thread.Id) = .init(0),
    armed: std.atomic.Value(bool) = .init(false),
    count: u32 = 0,
    fail_at: u32 = std.math.maxInt(u32),

    fn allocator(f: *FailNth) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// The calling thread's next allocations count; the `fail_at`-th fails.
    fn arm(f: *FailNth, fail_at: u32) void {
        f.count = 0;
        f.fail_at = fail_at;
        f.thread.store(std.Thread.getCurrentId(), .release);
        f.armed.store(true, .release);
    }

    /// How many allocations the arming thread made since `arm`.
    fn disarm(f: *FailNth) u32 {
        f.armed.store(false, .release);
        return f.count;
    }

    fn mine(f: *FailNth) bool {
        return f.armed.load(.acquire) and f.thread.load(.acquire) == std.Thread.getCurrentId();
    }

    fn of(p: *anyopaque) *FailNth {
        // SAFETY: `allocator()` sets the context to a *FailNth.
        return @ptrCast(@alignCast(p));
    }

    fn alloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const f = of(p);
        if (f.mine()) {
            defer f.count += 1;
            if (f.count == f.fail_at) return null;
        }
        return f.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        return of(p).backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return of(p).backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        of(p).backing.rawFree(memory, alignment, ra);
    }
};

/// One waiting append on the executor, failing its `fail_at`-th
/// allocation: `allocs` is how many it made, `outcome` its answer.
const FailingAppend = struct {
    fail: *FailNth,
    fail_at: u32,
    allocs: u32 = 0,
    err: ?anyerror = null,
    outcome: ?kafka.impl.producer.Producer.Outcome = null,
    done: std.atomic.Value(bool) = .init(false),

    fn run(r: *FailingAppend, client: *kafka.Client, value: []const u8) std.Io.Cancelable!void {
        defer r.done.store(true, .release);
        const p = client.producer;
        // A warm append never suspends: nothing else of this executor runs
        // (or allocates) until it returns.
        r.fail.arm(r.fail_at);
        const got = p.appendWaiting("oom", null, value, &.{}, 0, 1);
        r.allocs = r.fail.disarm();
        const ref = got catch |err| {
            r.err = err;
            return;
        };
        r.outcome = try p.waitFor(ref, null);
    }
};

test "kafka producer: an allocation failure at any step of a waiting produce answers it once and leaks nothing" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    var fail: FailNth = .{ .backing = gpa };
    const client = try kafka.Client.init(fail.allocator(), io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    // Warm: the topic, its accumulator and the sender exist.
    _ = try client.produce(&c, .{ .topic = "oom", .value = "warm", .partition = 0 });

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    // The dry run counts the allocations of a waiting append.
    var dry: FailingAppend = .{ .fail = &fail, .fail_at = std.math.maxInt(u32) };
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, FailingAppend.run, .{ &dry, client, "dry" });
    try wait.waitFlag(io, "the dry run's append was answered", &dry.done);
    try testing.expect(dry.outcome.? == .ok);
    try testing.expect(dry.allocs > 0);
    var delivered: i64 = 2;
    for (0..dry.allocs) |n| {
        var run: FailingAppend = .{ .fail = &fail, .fail_at = @intCast(n) };
        try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, FailingAppend.run, .{ &run, client, "x" });
        try wait.waitFlag(io, "the failing append was answered", &run.done);
        // Either refused with no wait made, or queued and answered once.
        if (run.err) |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        } else {
            try testing.expect(run.outcome.? == .ok);
            delivered += 1;
        }
        try client.producer.flush(.fromSeconds(10));
    }
    try testing.expectEqual(delivered, broker.count("oom", 0));
}

test "kafka producer: a produce that timed out is still delivered, and nothing leaks" {
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
    _ = try client.produce(&c, .{ .topic = "late", .value = "warm" });

    // The sender stops before its Produce round trip: no outcome can come
    // while the caller waits.
    var hold: TestHold = .{ .point = .send_request };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    const ref = try client.producer.appendWaiting("late", null, "late", &.{}, 0, 1);
    try wait.waitFlag(io, "the sender is held before its round trip", &hold.held);
    // Time passes on purpose: the hold guarantees no outcome meanwhile.
    try testing.expect(try client.producer.waitFor(ref, .fromMilliseconds(10)) == .timeout);
    hold.let(io);
    try client.producer.flush(.fromSeconds(10));
    try testing.expectEqual(@as(i64, 2), broker.count("late", 0));
}

test "kafka producer: a sender whose producer id was reset after it took it numbers its batch under the new id" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 2, .nodes = 2 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    for (0..3) |_| {
        _ = try client.produce(&c, .{ .topic = "ids", .value = "warm", .partition = 0 });
        _ = try client.produce(&c, .{ .topic = "ids", .value = "warm", .partition = 1 });
    }

    // Partition 1's sender stops after taking the producer id.
    var hold: TestHold = .{ .point = .ids_taken };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    var result: TaskResult = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try dusty.placement.concurrent(&group, io, .{ .executor = 0 }, produceTask, .{ client, io, kafka.Record{ .topic = "ids", .value = "held", .partition = 1 }, &result });
    try wait.waitFlag(io, "partition 1's sender is held after taking the id", &hold.held);
    // Meanwhile partition 0's sender is refused (UNKNOWN_PRODUCER_ID), resets
    // the id and takes a new one.
    broker.fail_code.store(59, .release);
    broker.fail_produce.store(1, .release);
    _ = try client.produce(&c, .{ .topic = "ids", .value = "reset", .partition = 0 });
    hold.let(io);
    try result.wait(io);
    // The held batch went out under the new id: stored, not taken for a
    // duplicate of the old id's sequence.
    try testing.expectEqual(@as(i64, 4), broker.count("ids", 0));
    try testing.expectEqual(@as(i64, 4), broker.count("ids", 1));
    try testing.expectEqual(@as(u32, 0), broker.out_of_order.load(.monotonic));
}

/// What one task of the four-executor stress test did with each record.
const StressTask = struct {
    const records_per_task = 24;
    const Kind = enum(u8) { send, ok, failed, pending };

    client: *kafka.Client,
    broker: *FakeBroker,
    io: std.Io,
    index: u32,
    seed: u64,
    /// Inject retriable failures and dropped answers (phase 1 only: a
    /// dropped answer across an id reset may store a record twice, which
    /// an idempotent producer allows).
    inject: bool,
    kinds: [records_per_task]Kind = @splat(.failed),
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),

    fn name(t: *const StressTask, buf: []u8, i: usize) []const u8 {
        return std.fmt.bufPrint(buf, "p{d}-t{d}-r{d}", .{ @intFromBool(t.inject), t.index, i }) catch unreachable;
    }

    fn run(t: *StressTask) std.Io.Cancelable!void {
        defer t.done.store(true, .release);
        t.runInner() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => t.failure = err,
        };
    }

    fn runInner(t: *StressTask) !void {
        var prng: std.Random.DefaultPrng = .init(t.seed);
        const rand = prng.random();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        for (0..records_per_task) |i| {
            _ = arena.reset(.retain_capacity);
            var c: db.Ctx = .{ .io = t.io, .arena = arena.allocator() };
            var buf: [32]u8 = undefined;
            const record: kafka.Record = .{ .topic = "stress", .key = t.name(&buf, i), .value = t.name(&buf, i) };
            if (t.inject) switch (rand.uintLessThan(u32, 48)) {
                0 => t.broker.fail_produce.store(1, .release),
                1 => t.broker.drop_after_store.store(1, .release),
                else => {},
            };
            switch (rand.uintLessThan(u32, 8)) {
                0...4 => t.kinds[i] = try sendOne(t.client, &c, record),
                5, 6 => {
                    const ms = 1 + rand.uintLessThan(u32, 1000);
                    if (t.client.with(.{ .timeout = .fromMilliseconds(ms) }).produce(&c, record)) |_| {
                        t.kinds[i] = .ok;
                    } else |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => {
                            const code = (db.lastError(&c) orelse return err).code;
                            t.kinds[i] = if (std.mem.eql(u8, code, "delivery_pending")) .pending else .failed;
                        },
                    }
                },
                else => {
                    t.kinds[i] = try sendOne(t.client, &c, record);
                    // A flush waits until nothing is pending, the other
                    // tasks' records included: under their load it may time
                    // out (delivery_pending), which is its contract.
                    t.client.with(.{ .timeout = .fromSeconds(1) }).flush(&c) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => {
                            const e = db.lastError(&c) orelse return err;
                            if (!std.mem.eql(u8, e.code, "delivery_pending")) return err;
                        },
                    };
                },
            }
        }
    }
};

/// A send, or `.failed` when the topic was dropped from the metadata
/// cache (a stale leader) between the refresh and the lookup of its
/// partitions: the call fails visibly, nothing is lost.
fn sendOne(client: *kafka.Client, c: *db.Ctx, record: kafka.Record) !StressTask.Kind {
    client.send(c, record) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            const e = db.lastError(c) orelse return err;
            if (std.mem.eql(u8, e.code, "UNKNOWN_TOPIC_OR_PARTITION")) return .failed;
            return err;
        },
    };
    return .send;
}

fn stressPhase(io: std.Io, client: *kafka.Client, broker: *FakeBroker, tasks: []StressTask, inject: bool, seed: u64) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (tasks, 0..) |*t, i| {
        t.* = .{ .client = client, .broker = broker, .io = io, .index = @intCast(i), .seed = seed +% i, .inject = inject };
        try dusty.placement.concurrent(&group, io, .{ .executor = i }, StressTask.run, .{t});
    }
    for (tasks) |*t| try wait.waitUntilFor(io, "every stress task finished", .fromSeconds(120), t, struct {
        fn done(x: *StressTask) bool {
            return x.done.load(.acquire);
        }
    }.done);
    for (tasks) |*t| if (t.failure) |err| return err;
}

test "kafka: [stress] produce from four executors to two nodes with retries, timeouts and an id reset" {
    try wait.requireStress();
    const seed: u64 = 0x4b_af_4a;
    errdefer std.debug.print("kafka four-executor stress: seed 0x{x}\n", .{seed});
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 8, .nodes = 2 });
    defer broker.deinit();
    const client = try kafka.Client.init(gpa, io, opts(broker, .{ .linger = .fromMilliseconds(1) }));
    defer client.deinit();
    const tasks = try gpa.alloc(StressTask, 4 * 64);
    defer gpa.free(tasks);
    const both = try gpa.alloc(StressTask, 2 * tasks.len);
    defer gpa.free(both);

    // Phase 1: NOT_LEADER_OR_FOLLOWER (a stale leader) and dropped answers.
    broker.fail_code.store(6, .release);
    try stressPhase(io, client, broker, tasks, true, seed);
    @memcpy(both[0..tasks.len], tasks);
    // Phase 2: UNKNOWN_PRODUCER_ID once: the id is reset under load.
    try client.producer.flush(.fromSeconds(30));
    broker.fail_code.store(59, .release);
    broker.fail_produce.store(1, .release);
    try stressPhase(io, client, broker, tasks, false, seed +% 0x10000);
    @memcpy(both[tasks.len..], tasks);
    try client.producer.flush(.fromSeconds(30));

    try testing.expectEqual(@as(u32, 0), broker.out_of_order.load(.monotonic));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    for (0..8) |p| for (try broker.stored(arena.allocator(), "stress", p)) |r| {
        const gop = try seen.getOrPut(arena.allocator(), r.value.?);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    };
    // Every record is stored once, but a failed one at most once.
    for (both) |*t| for (t.kinds, 0..) |k, i| {
        var buf: [32]u8 = undefined;
        const n = seen.get(t.name(&buf, i)) orelse 0;
        if (k == .failed) try testing.expect(n <= 1) else try testing.expectEqual(@as(u32, 1), n);
    };
}

test "kafka: a broker connection's round trip canceled while it waits for the answer ends in Canceled" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // A listener that never answers: the connect completes in its backlog.
    const at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var silent = try at.listen(io, .{});
    defer silent.deinit(io);
    var cache: @import("../net/scram.zig").Cache = .{};
    const settings: kafka.cluster.Settings = .{ .client_id = "t", .scram_cache = &cache, .request_timeout = .fromSeconds(60) };
    var hold: TestHold = .{ .point = .request_written };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    // Conn.open asks ApiVersions: the request is written, then the open
    // waits for an answer that never comes.
    var future = try io.concurrent(kafka.cluster.Conn.open, .{ gpa, io, settings, "127.0.0.1", silent.socket.address.getPort(), -1 });
    try wait.waitFlag(io, "the round trip's request is written", &hold.held);
    hold.let(io);
    const conn = future.cancel(io) catch |err| return testing.expectEqual(error.Canceled, err);
    conn.close();
    return error.TestUnexpectedResult;
}

test "kafka: a broker connection opens on an executor where another connection's task is suspended in its round trip" {
    // One executor: both connections' tasks run on the same thread. The
    // first holds its connection's I/O lock while it waits for an answer;
    // the second takes its own connection's lock meanwhile (SAFETY.md L2's
    // exception: one I/O lock per task, not per thread).
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const broker = try FakeBroker.start(gpa, io, .{ .partitions = 1 });
    defer broker.deinit();
    const at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var silent = try at.listen(io, .{});
    defer silent.deinit(io);
    var cache: @import("../net/scram.zig").Cache = .{};
    const settings: kafka.cluster.Settings = .{ .client_id = "t", .scram_cache = &cache, .request_timeout = .fromSeconds(60) };
    var hold: TestHold = .{ .point = .request_written };
    hold.arm();
    defer hold_mod.test_hold.store(null, .release);
    var stuck = try io.concurrent(kafka.cluster.Conn.open, .{ gpa, io, settings, "127.0.0.1", silent.socket.address.getPort(), -1 });
    try wait.waitFlag(io, "the silent connection's request is written", &hold.held);
    var other = try io.concurrent(kafka.cluster.Conn.open, .{ gpa, io, settings, "127.0.0.1", broker.listener.socket.address.getPort(), 0 });
    const conn = other.await(io) catch |err| {
        hold.let(io);
        if (stuck.cancel(io)) |c| c.close() else |_| {}
        return err;
    };
    conn.close();
    hold.let(io);
    const c = stuck.cancel(io) catch |err| return testing.expectEqual(error.Canceled, err);
    c.close();
    return error.TestUnexpectedResult;
}
