//! Tests of `anole.watch` over a fake source: events injected the way a
//! shared-connection source hands them over.

const std = @import("std");
const root = @import("root.zig");
const sse = @import("../sse/root.zig");

const Watch = root.Watch;
const gpa = std.testing.allocator;
const io = std.testing.io;

const SourceStub = struct {
    var unused: u64 = 0;
};

fn stubClient() @FieldType(root.Postgres, "client") {
    return @ptrCast(@alignCast(&SourceStub.unused));
}

fn newWatch(topics: *sse.Topics, topic: []const u8, extra: []const root.Target) !*Watch {
    var targets: std.ArrayList(root.Target) = .empty;
    defer targets.deinit(gpa);
    try targets.append(gpa, .{ .sse = .{ .topics = topics, .topic = topic } });
    try targets.appendSlice(gpa, extra);
    // The source is never read (fake): a channel list is all it needs.
    const w = try Watch.init(gpa, io, .{ .postgres = .{ .client = stubClient(), .channels = &.{"orders"} } }, .{ .to = targets.items });
    w._fake();
    return w;
}

fn waitFor(fake: *sse.out_mod.Fake, needle: []const u8) void {
    while (true) {
        fake.mutex.lockUncancelable(io);
        const found = std.mem.indexOf(u8, fake.bytes.items, needle) != null;
        fake.mutex.unlock(io);
        if (found) return;
        io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
}

const Closed = struct {
    var n: std.atomic.Value(u32) = .init(0);
    fn onClose(_: *sse.Subscriber, _: sse.CloseReason) void {
        _ = n.fetchAdd(1, .release);
    }
};

test "watch: a fake source publishes to SSE topics, templates {channel}, {op}, {data.room}" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true, .replay = null });
    defer topics.deinit();
    var fake: sse.out_mod.Fake = .init(gpa, io);
    defer fake.deinit();
    const w = try newWatch(&topics, "room:{data.room}", &.{});
    defer w.deinit();
    Closed.n.store(0, .release);
    const sub = try topics._attach(io, fake.out(), .{ .topics = &.{"room:lobby"}, .on_close = Closed.onClose }, null);
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"room\":\"lobby\",\"n\":1}" });
    waitFor(&fake, "\"n\":1");
    // Another room: not this subscriber. A payload without the field: skipped.
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"room\":\"other\"}" });
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"x\":1}" });
    try std.testing.expectEqual(@as(u64, 1), w.n_template_skipped.load(.monotonic));
    try std.testing.expect(std.mem.indexOf(u8, fake.bytes.items, "other") == null);
    sse.Topics._gone(sub);
    while (Closed.n.load(.acquire) < 1) io.sleep(.fromMilliseconds(1), .awake) catch return;
}

test "watch: a gap reaches a fixed topic, a templated one by prefix" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    var fixed: sse.out_mod.Fake = .init(gpa, io);
    defer fixed.deinit();
    var templated: sse.out_mod.Fake = .init(gpa, io);
    defer templated.deinit();
    const w1 = try newWatch(&topics, "orders", &.{});
    defer w1.deinit();
    const w2 = try newWatch(&topics, "room:{data.room}", &.{});
    defer w2.deinit();
    Closed.n.store(0, .release);
    const s1 = try topics._attach(io, fixed.out(), .{ .topics = &.{"orders"}, .on_close = Closed.onClose }, null);
    const s2 = try topics._attach(io, templated.out(), .{ .topics = &.{"room:a"}, .on_close = Closed.onClose }, null);
    w1.gapped("test");
    waitFor(&fixed, "event: gap");
    try std.testing.expect(std.mem.indexOf(u8, fixed.bytes.items, "{\"topics\":[\"orders\"]}") != null);
    w2.gapped("test");
    waitFor(&templated, "event: gap");
    try std.testing.expect(std.mem.indexOf(u8, templated.bytes.items, "{\"topics\":[\"room:a\"]}") != null);
    sse.Topics._gone(s1);
    sse.Topics._gone(s2);
    while (Closed.n.load(.acquire) < 2) io.sleep(.fromMilliseconds(1), .awake) catch return;
}

const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
};

test "watch: a listener reads events in order; past max_events the oldest drop and one gap takes their place" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    const w = try newWatch(&topics, "t", &.{});
    defer w.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const l = try w.listen(&c, .{ .max_events = 3 });
    defer l.close();
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable });
    }
    // 0 and 1 dropped: a gap first, then 2, 3, 4.
    const gap = (try l.next(&c)).?;
    try std.testing.expectEqual(root.Op.gap, gap.op);
    for (2..5) |i| {
        const ev = (try l.next(&c)).?;
        var buf: [8]u8 = undefined;
        try std.testing.expectEqualStrings(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable, ev.data);
        try std.testing.expectEqualStrings("orders", ev.channel);
    }
    w.stop();
    try std.testing.expect((try l.next(&c)) == null);
}

const Seen = struct {
    var mutex: std.Io.Mutex = .init;
    var data: [8][8]u8 = undefined;
    var len: [8]usize = @splat(0);
    var count: std.atomic.Value(u32) = .init(0);
    var fail_on: u32 = 99;

    fn handle(_: ?*anyopaque, ev: *root.Event) anyerror!void {
        const i = count.fetchAdd(1, .acq_rel);
        const n = @min(ev.data.len, 8);
        @memcpy(data[i][0..n], ev.data[0..n]);
        len[i] = n;
        if (i == fail_on) return error.Boom;
    }
};

test "watch: a handler runs events in order; a failing one is logged and the next runs" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    const w = try newWatch(&topics, "t", &.{});
    defer w.deinit();
    Seen.count.store(0, .release);
    Seen.fail_on = 1;
    w.setHandler(null, .{ .timeout = null }, Seen.handle);
    try w._startWorker();
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = std.fmt.bufPrint(&buf, "e{d}", .{i}) catch unreachable });
    }
    while (Seen.count.load(.acquire) < 4) io.sleep(.fromMilliseconds(1), .awake) catch return;
    for (0..4) |i| {
        var buf: [8]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "e{d}", .{i}) catch unreachable;
        try std.testing.expectEqualStrings(want, Seen.data[i][0..Seen.len[i]]);
    }
}

test "watch: init refuses what cannot work" {
    const g = @import("../errors.zig").expectLog();
    defer g.deinit();
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    try std.testing.expectError(error.InvalidWatch, Watch.init(gpa, io, .{ .postgres = .{ .client = stubClient(), .channels = &.{} } }, .{}));
    const long: [64]u8 = @splat('c');
    try std.testing.expectError(error.InvalidWatch, Watch.init(gpa, io, .{ .postgres = .{ .client = stubClient(), .channels = &.{&long} } }, .{}));
    try std.testing.expectError(error.InvalidWatch, Watch.init(gpa, io, .{ .postgres = .{ .client = stubClient(), .channels = &.{"a"} } }, .{
        .to = &.{.{ .sse = .{ .topics = &topics, .topic = "{key}" } }},
    }));
    try std.testing.expectError(error.InvalidWatch, Watch.init(gpa, io, .{ .postgres = .{ .client = stubClient(), .channels = &.{"a"} } }, .{
        .to = &.{.{ .sse = .{ .topics = &topics, .topic = "{nope" } }},
    }));
}

test "watch mongo: history lost -> a gap, then the stream reopens from now" {
    if (comptime !@import("build_options").mongodb) return error.SkipZigTest;
    const zio = @import("zio");
    const fake_cs = @import("../mongodb/fake_cs.zig");
    const mongodb = @import("../mongodb/root.zig");
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const rio = rt.io();
    var fake: fake_cs.Fake = undefined;
    try fake.init(rio, &.{
        .{ .batch = .{ .ids = &.{1}, .pbrt = "p1" } },
        .{ .fail = .{ .code = 286, .name = "ChangeStreamHistoryLost" } },
        .{ .batch = .{ .ids = &.{2} } },
    });
    defer fake.deinit(rio);
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "mongodb://{s}/app?replicaSet=rs0&heartbeatFrequencyMS=500", .{fake.addr()});
    const client = try mongodb.Client.init(gpa, rio, .{ .url = url, .server_selection_timeout = .fromSeconds(5) });
    defer client.deinit();

    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true, .replay = null });
    defer topics.deinit();
    var out: sse.out_mod.Fake = .init(gpa, rio);
    defer out.deinit();
    const w = try Watch.init(gpa, rio, .{ .mongodb = .{
        .client = client,
        .collection = "users",
        .max_await = .fromMilliseconds(20),
    } }, .{
        .to = &.{.{ .sse = .{ .topics = &topics, .topic = "users" } }},
        .reconnect = .{ .base = .fromMilliseconds(5), .max = .fromMilliseconds(20) },
    });
    defer w.deinit();
    const sub = try topics._attach(rio, out.out(), .{ .topics = &.{"users"} }, null);
    try w.start(null, null, null);
    defer sse.Topics._gone(sub);
    defer w.stop();

    while (true) {
        out.mutex.lockUncancelable(rio);
        const have = std.mem.indexOf(u8, out.bytes.items, "event: gap") != null and std.mem.indexOf(u8, out.bytes.items, "\"x\":20") != null;
        out.mutex.unlock(rio);
        if (have) break;
        try rio.sleep(.fromMilliseconds(2), .awake);
    }
    // Aggregate, getMore (history lost), aggregate again: from now.
    try std.testing.expect(fake.commandCount(rio) >= 3);
    const again = fake.command(rio, 2);
    var it = again.get("pipeline").?.array.iterator();
    const stage = it.next().?.document.get("$changeStream").?.document;
    try std.testing.expect(stage.get("resumeAfter") == null);
    try std.testing.expect(stage.get("startAfter") == null);
}
