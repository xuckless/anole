//! Tests of `anole.watch` over a fake source: events injected the way a
//! shared-connection source hands them over.

const std = @import("std");
const wait = @import("anole_test_wait");
const root = @import("root.zig");
const sse = @import("../sse/root.zig");
const metrics = @import("../observe/metrics.zig");

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

fn waitFor(fake: *sse.out_mod.Fake, needle: []const u8) !void {
    const C = struct {
        fake: *sse.out_mod.Fake,
        needle: []const u8,
        fn found(c: @This()) bool {
            c.fake.mutex.lockUncancelable(io);
            defer c.fake.mutex.unlock(io);
            return std.mem.indexOf(u8, c.fake.bytes.items, c.needle) != null;
        }
    };
    try wait.waitUntil(io, "the subscriber's output holds the text", C{ .fake = fake, .needle = needle }, C.found);
}

const Closed = struct {
    var n: std.atomic.Value(u32) = .init(0);
    fn onClose(_: *sse.Subscriber, _: sse.CloseReason) void {
        _ = n.fetchAdd(1, .release);
    }
};

test "watch: a templated SSE topic gets only matching events; an event without the field is skipped" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true, .replay = null });
    defer topics.deinit();
    var fake: sse.out_mod.Fake = .init(gpa, io);
    defer fake.deinit();
    var registry = metrics.Registry.init(gpa, io);
    defer registry.deinit();
    const w = try newWatch(&topics, "room:{data.room}", &.{});
    defer w.deinit();
    try w.start(&registry, null, null);
    Closed.n.store(0, .release);
    const sub = try topics._attach(io, fake.out(), .{ .topics = &.{"room:lobby"}, .on_close = Closed.onClose }, null);
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"room\":\"lobby\",\"n\":1}" });
    try waitFor(&fake, "\"n\":1");
    // Another room: not this subscriber. A payload without the field: skipped.
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"room\":\"other\"}" });
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"x\":1}" });
    // A later lobby event is the barrier: once it arrived, "other" would have too.
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "{\"room\":\"lobby\",\"n\":2}" });
    try waitFor(&fake, "\"n\":2");
    {
        fake.mutex.lockUncancelable(io);
        defer fake.mutex.unlock(io);
        try std.testing.expect(std.mem.indexOf(u8, fake.bytes.items, "other") == null);
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "anole_watch_template_skipped_total{watch=\"orders\"} 1") != null);
    sse.Topics._gone(sub);
    try wait.waitAtLeast(io, "the subscriber closed", &Closed.n, 1);
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
    try waitFor(&fixed, "event: gap");
    try std.testing.expect(std.mem.indexOf(u8, fixed.bytes.items, "{\"topics\":[\"orders\"]}") != null);
    w2.gapped("test");
    try waitFor(&templated, "event: gap");
    try std.testing.expect(std.mem.indexOf(u8, templated.bytes.items, "{\"topics\":[\"room:a\"]}") != null);
    sse.Topics._gone(s1);
    sse.Topics._gone(s2);
    try wait.waitAtLeast(io, "both subscribers closed", &Closed.n, 2);
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

test "watch: a handler runs events in order; after a failing one the next still runs" {
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
    try wait.waitAtLeast(io, "the handler saw four events", &Seen.count, 4);
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

    const GapThenNew = struct {
        out: *sse.out_mod.Fake,
        rio: std.Io,
        fn have(c: @This()) bool {
            c.out.mutex.lockUncancelable(c.rio);
            defer c.out.mutex.unlock(c.rio);
            return std.mem.indexOf(u8, c.out.bytes.items, "event: gap") != null and std.mem.indexOf(u8, c.out.bytes.items, "\"x\":20") != null;
        }
    };
    try wait.waitUntil(rio, "a gap, then the stream from now", GapThenNew{ .out = &out, .rio = rio }, GapThenNew.have);
    // Aggregate, getMore (history lost), aggregate again: from now.
    try std.testing.expect(fake.commandCount(rio) >= 3);
    const again = fake.command(rio, 2);
    var it = again.get("pipeline").?.array.iterator();
    const stage = it.next().?.document.get("$changeStream").?.document;
    try std.testing.expect(stage.get("resumeAfter") == null);
    try std.testing.expect(stage.get("startAfter") == null);
}

const Acks = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var ids: [8][8]u8 = undefined;
    var lens: [8]usize = @splat(0);
    var count: usize = 0;
    var handled: std.atomic.Value(u32) = .init(0);

    fn reset() void {
        count = 0;
        handled.store(0, .release);
    }

    fn call(_: *anyopaque, _: []const u8, id: []const u8) error{ OutOfMemory, Unsupported }!void {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        defer lock.unlock();
        @memcpy(ids[count][0..id.len], id);
        lens[count] = id.len;
        count += 1;
    }

    fn has(id: []const u8) bool {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        defer lock.unlock();
        for (0..count) |i| if (std.mem.eql(u8, ids[i][0..lens[i]], id)) return true;
        return false;
    }

    /// Fails for the data "bad".
    fn handle(_: ?*anyopaque, ev: *root.Event) anyerror!void {
        defer _ = handled.fetchAdd(1, .acq_rel);
        if (std.mem.eql(u8, ev.data, "bad")) return error.Boom;
    }
};

fn entry(data: []const u8, id: []const u8) root.Raw {
    return .{ .op = .entry, .op_name = "entry", .channel = "k", .data = data, .position = id };
}

test "watch: auto-ack: after the handler succeeded, never after it failed (handler on the reader, and on its own tasks)" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    const w = try newWatch(&topics, "t", &.{});
    defer w.deinit();
    Acks.reset();
    var dummy: u8 = 0;
    const hook: root.AckHook = .{ .ctx = &dummy, .call = Acks.call };
    w.setAckHooks(null, hook);

    // Concurrency 1: the outcome tells the reader whether to ack.
    w.setHandler(null, .{ .timeout = null }, Acks.handle);
    try std.testing.expectEqual(root.Outcome.ok, w.deliver(entry("good", "1-0")));
    try std.testing.expectEqual(root.Outcome.failed, w.deliver(entry("bad", "2-0")));
    try std.testing.expectEqual(@as(usize, 0), Acks.count);

    // More: each handler acks its own entry when it succeeded.
    Acks.reset();
    w.setHandler(null, .{ .timeout = null, .concurrency = 2 }, Acks.handle);
    try std.testing.expectEqual(root.Outcome.deferred, w.deliver(entry("good", "3-0")));
    try std.testing.expectEqual(root.Outcome.deferred, w.deliver(entry("bad", "4-0")));
    try std.testing.expectEqual(root.Outcome.deferred, w.deliver(entry("good", "5-0")));
    const Settled = struct {
        fn done(wt: *Watch) bool {
            wt.slots.mutex.lockUncancelable(io);
            defer wt.slots.mutex.unlock(io);
            return wt.slots.in_use == 0 and Acks.handled.load(.acquire) == 3;
        }
    };
    try wait.waitUntil(io, "the three events handled and their slots free", w, Settled.done);
    try std.testing.expect(Acks.has("3-0"));
    try std.testing.expect(Acks.has("5-0"));
    try std.testing.expect(!Acks.has("4-0"));
    try std.testing.expectEqual(@as(usize, 2), Acks.count);
}

test "watch: a manual ack goes through the manual hook only; with the reader gone it is refused (Unsupported)" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    const w = try newWatch(&topics, "t", &.{});
    defer w.deinit();
    Acks.reset();
    var dummy: u8 = 0;
    const hook: root.AckHook = .{ .ctx = &dummy, .call = Acks.call };
    w.setAckHooks(hook, null);
    w.setHandler(null, .{ .timeout = null }, Acks.handle);
    try std.testing.expectEqual(root.Outcome.ok, w.deliver(entry("good", "6-0")));
    try std.testing.expectEqual(@as(usize, 0), Acks.count);
    try w.ackEntry("k", "6-0");
    try std.testing.expect(Acks.has("6-0"));
    // The reader gone: acks are refused, not queued into freed memory.
    w.setAckHooks(null, null);
    try std.testing.expectError(error.Unsupported, w.ackEntry("k", "7-0"));
}

const Gate = struct {
    var entered: std.atomic.Value(bool) = .init(false);
    var open: std.Io.Event = .unset;
    var finished: std.atomic.Value(bool) = .init(false);

    fn handle(_: ?*anyopaque, _: *root.Event) anyerror!void {
        entered.store(true, .release);
        open.waitUncancelable(io);
        finished.store(true, .release);
    }
};

test "watch: stop: a running handler finishes, a listener ends after what it has queued" {
    var topics = try sse.Topics.init(gpa, .{ ._manual_ticks = true });
    defer topics.deinit();
    const w = try newWatch(&topics, "t", &.{});
    defer w.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const l = try w.listen(&c, .{});
    defer l.close();
    Gate.entered.store(false, .release);
    Gate.open = .unset;
    // A failed check before the gate opens must not leave the handler blocked (w.deinit would hang).
    defer Gate.open.set(io);
    Gate.finished.store(false, .release);
    w.setHandler(null, .{ .timeout = null }, Gate.handle);
    try w._startWorker();
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "a" });
    w._inject(.{ .op = .message, .op_name = "message", .channel = "orders", .data = "b" });
    try wait.waitFlag(io, "the handler entered", &Gate.entered);
    w.stop();
    try std.testing.expectEqual(root.Status.stopped, w.status());
    // The handler was not canceled by the stop: it ends its event.
    Gate.open.set(io);
    try wait.waitFlag(io, "the handler finished its event", &Gate.finished);
    // The listener still has both events, then the end.
    try std.testing.expectEqualStrings("a", (try l.next(&c)).?.data);
    try std.testing.expectEqualStrings("b", (try l.next(&c)).?.data);
    try std.testing.expect((try l.next(&c)) == null);
    try std.testing.expectError(error.Stopped, w.listen(&c, .{}));
}
