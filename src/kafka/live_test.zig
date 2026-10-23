//! Tests against a live broker: `zig build test -Dkafka-test-url=host:port`
//! (tests/kafka/run.sh starts Kafka 4.1 in KRaft mode or Redpanda in
//! Docker, plain and with SASL SCRAM over TLS). Skipped without the option.
const std = @import("std");
const zio = @import("zio");
const db = @import("../db/root.zig");
const kafka = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn url() ?[]const u8 {
    return @import("build_options").kafka_test_url;
}

const Seen = struct {
    var count: std.atomic.Value(u32) = .init(0);
    fn on(msg: *kafka.Msg) !void {
        if (msg.value != null) _ = count.fetchAdd(1, .monotonic);
    }
};

fn uniqueName(io: std.Io, buf: []u8, prefix: []const u8) []const u8 {
    var random: [4]u8 = undefined;
    io.random(&random);
    return std.fmt.bufPrint(buf, "{s}-{x}", .{ prefix, std.mem.readInt(u32, &random, .little) }) catch prefix;
}

test "live: produce with every codec and consume it back from the start" {
    const addr = url() orelse return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    var tbuf: [64]u8 = undefined;
    const topic = uniqueName(io, &tbuf, "anole-live");
    var gbuf: [64]u8 = undefined;
    const group = uniqueName(io, &gbuf, "anole-group");

    var total: u32 = 0;
    inline for (.{ .none, .gzip, .zstd, .lz4 }) |codec| {
        const producer = try kafka.Client.init(gpa, io, .{ .brokers = &.{addr}, .producer = .{ .compression = codec, .linger = .fromMilliseconds(2) } });
        defer producer.deinit();
        for (0..50) |i| {
            var buf: [32]u8 = undefined;
            _ = try producer.produce(&c, .{ .topic = topic, .key = "k", .value = std.fmt.bufPrint(&buf, "{s}-{d}", .{ @tagName(codec), i }) catch unreachable });
            total += 1;
        }
    }
    Seen.count.store(0, .release);
    const consumer = try kafka.Client.init(gpa, io, .{ .brokers = &.{addr} });
    defer consumer.deinit();
    try consumer.consume({}, .{ .group = group, .topics = &.{topic}, .start = .earliest }, Seen.on);
    try consumer.start(null, null, null);
    for (0..500) |_| {
        if (Seen.count.load(.acquire) >= total) break;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    try testing.expectEqual(total, Seen.count.load(.acquire));
}

test "live: the cluster answers a metadata ping" {
    const addr = url() orelse return error.SkipZigTest;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const client = try kafka.Client.init(gpa, rt.io(), .{ .brokers = &.{addr} });
    defer client.deinit();
    try testing.expect(client.ping());
}
