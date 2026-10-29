//! anole.nats against a live nats-server (2.10+, started with `-js`):
//! `-Dnats-test-url=nats://127.0.0.1:4222`. Without it the tests skip.
const std = @import("std");
const features = @import("build_options");
const nats = @import("root.zig");
const db = @import("../db/root.zig");

const testing = std.testing;
const gpa = testing.allocator;

const url: ?[]const u8 = features.nats_test_url;

fn open(io: std.Io, opts: nats.Options) !*nats.Client {
    var o = opts;
    if (o.url == null) o.url = url orelse return error.SkipZigTest;
    o.environ = .empty;
    o.connect_at_start = true;
    const c = try nats.Client.init(gpa, io, o);
    errdefer c.deinit();
    try c.start(null, null, null);
    return c;
}

test "live: a published message reaches a subscriber, and a request nobody answers is ServiceUnavailable (no_responders)" {
    if (url == null) return error.SkipZigTest;
    const io = testing.io;
    const nc = try open(io, .{});
    defer nc.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };

    const sub = try nc.subscribe(&c, "anole.live.hello", .{});
    defer sub.deinit();
    try nc.flush(&c);
    try nc.publish(&c, "anole.live.hello", "world");
    const got = (try sub.next(&c, .fromSeconds(5))).?;
    try testing.expectEqualStrings("world", got.payload);

    // Nobody listens on this subject.
    try testing.expectError(error.ServiceUnavailable, nc.request(&c, "anole.live.nobody", "x"));
    try testing.expectEqualStrings("no_responders", db.lastError(&c).?.code);
}

test "live: JetStream stream, publish with ack, duplicate id" {
    if (url == null) return error.SkipZigTest;
    const io = testing.io;
    const nc = try open(io, .{});
    defer nc.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
    const js = nc.js();
    try js.ensureStream(&c, .{ .name = "ANOLE_LIVE", .subjects = &.{"anole.live.js.>"}, .storage = .memory });
    // A message id of this run: a run within JetStream's duplicate window
    // of an earlier one (2 min by default) does not find it taken.
    var id_buf: [32]u8 = undefined;
    const msg_id = try std.fmt.bufPrint(&id_buf, "m-{x}", .{@as(u96, @bitCast(std.Io.Clock.real.now(io).nanoseconds))});
    errdefer std.debug.print("live JetStream test: msg_id {s}\n", .{msg_id});
    const first = try js.publish(&c, "anole.live.js.a", "one", .{ .msg_id = msg_id });
    try testing.expect(!first.duplicate);
    const second = try js.publish(&c, "anole.live.js.a", "one", .{ .msg_id = msg_id });
    try testing.expect(second.duplicate);
    try testing.expectEqual(first.sequence, second.sequence);
}
