//! Tests of `anole.sse.Topics` over the fake `Out`: manual ticks with made-up
//! clocks, waits on results, no timing windows.

const std = @import("std");
const root = @import("root.zig");
const out_mod = @import("out.zig");
const replay = @import("replay.zig");

const Topics = root.Topics;
const Subscriber = root.Subscriber;
const Fake = out_mod.Fake;

const gpa = std.testing.allocator;
const io = std.testing.io;

const Rec = struct {
    h: *Harness,
    sub: *Subscriber = undefined,
    done: std.atomic.Value(bool) = .init(false),
};

const Harness = struct {
    hub: Topics,
    fakes: std.ArrayList(*Fake) = .empty,
    recs: std.ArrayList(*Rec) = .empty,
    closed: std.atomic.Value(u32) = .init(0),
    last_reason: std.atomic.Value(u32) = .init(99),

    fn init(options: Topics.Options) !*Harness {
        const h = try gpa.create(Harness);
        var o = options;
        o._manual_ticks = true;
        h.* = .{ .hub = try Topics.init(gpa, o) };
        h.hub.fake_now_ms.store(1000, .monotonic);
        return h;
    }

    fn onClose(sub: *Subscriber, reason: root.CloseReason) void {
        const rec: *Rec = @ptrCast(@alignCast(sub.context.?));
        rec.h.last_reason.store(@intFromEnum(reason), .release);
        rec.done.store(true, .release);
        _ = rec.h.closed.fetchAdd(1, .release);
    }

    fn addWith(h: *Harness, topics: []const []const u8, last_header: ?[]const u8, last_n: u16, hold: bool) !*Fake {
        const f = try gpa.create(Fake);
        f.* = .init(gpa, io);
        f.hold = hold;
        try h.fakes.append(gpa, f);
        const rec = try gpa.create(Rec);
        rec.* = .{ .h = h };
        try h.recs.append(gpa, rec);
        rec.sub = try h.hub._attach(io, f.out(), .{ .topics = topics, .last = last_n, .context = rec, .on_close = onClose }, last_header);
        return f;
    }

    fn add(h: *Harness, topics: []const []const u8, last: ?[]const u8) !*Fake {
        return h.addWith(topics, last, 0, false);
    }

    fn add2(h: *Harness, topics: []const []const u8, last_n: u16) !*Fake {
        return h.addWith(topics, null, last_n, false);
    }

    fn addHeld(h: *Harness, topics: []const []const u8) !*Fake {
        return h.addWith(topics, null, 0, true);
    }

    fn subAt(h: *Harness, i: usize) *Subscriber {
        return h.recs.items[i].sub;
    }

    /// Waits until `f` has written `n` bytes (polling; no deadline).
    fn waitBytes(f: *Fake, n: usize) void {
        while (true) {
            f.mutex.lockUncancelable(io);
            const have = f.bytes.items.len;
            f.mutex.unlock(io);
            if (have >= n) return;
            io.sleep(.fromMilliseconds(1), .awake) catch return;
        }
    }

    fn waitWrites(f: *Fake, n: usize) void {
        while (f.writes_done.load(.acquire) < n) io.sleep(.fromMilliseconds(1), .awake) catch return;
    }

    fn waitClosed(h: *Harness, n: u32) void {
        while (h.closed.load(.acquire) < n) io.sleep(.fromMilliseconds(1), .awake) catch return;
    }

    fn text(f: *Fake) []const u8 {
        return f.bytes.items;
    }

    fn deinit(h: *Harness) void {
        // Every subscriber still open: its peer goes, and the ends finish.
        var open: u32 = 0;
        const base = h.closed.load(.acquire);
        for (h.fakes.items) |f| f.open();
        for (h.recs.items) |rec| {
            if (!rec.done.load(.acquire)) {
                open += 1;
                Topics._gone(rec.sub);
            }
        }
        h.waitClosed(base + open);
        h.hub.deinit();
        for (h.fakes.items) |f| {
            f.open();
            f.deinit();
            gpa.destroy(f);
        }
        for (h.recs.items) |rec| gpa.destroy(rec);
        h.fakes.deinit(gpa);
        h.recs.deinit(gpa);
        gpa.destroy(h);
    }

    fn expectId(h: *Harness, buf: []u8, seq: u64) []const u8 {
        return std.fmt.bufPrint(buf, "id: {x:0>8}-{d}\n", .{ h.hub.epoch, seq }) catch unreachable;
    }
};

test "sse: publish reaches every subscriber once, in publish order" {
    const h = try Harness.init(.{ .replay = .{ .events = 1000 } });
    defer h.deinit();
    const topics = [_][]const u8{"news"};
    const a = try h.add(&topics, null);
    const b = try h.add(&topics, null);
    const c = try h.add(&topics, null);
    var expect: std.Io.Writer.Allocating = .init(gpa);
    defer expect.deinit();
    // The open line: the current id (0).
    try expect.writer.print("id: {x:0>8}-0\n\n", .{h.hub.epoch});
    for (0..200) |i| {
        var data: [16]u8 = undefined;
        const d = try std.fmt.bufPrint(&data, "e{d}", .{i});
        try std.testing.expectEqual(@as(usize, 3), try h.hub.publish("news", .{ .data = d }));
        try expect.writer.print("id: {x:0>8}-{d}\ndata: {s}\n\n", .{ h.hub.epoch, i + 1, d });
    }
    for ([_]*Fake{ a, b, c }) |f| {
        Harness.waitBytes(f, expect.written().len);
        try std.testing.expectEqualStrings(expect.written(), Harness.text(f));
    }
}

test "sse: events queued behind a write go out in one write" {
    const h = try Harness.init(.{});
    defer h.deinit();
    // The open line's write is held; ten events queue behind it.
    const f = try h.addHeld(&.{"t"});
    f.held.wait(io) catch unreachable;
    for (0..10) |i| {
        var data: [8]u8 = undefined;
        _ = try h.hub.publish("t", .{ .data = try std.fmt.bufPrint(&data, "{d}", .{i}) });
    }
    f.open();
    Harness.waitWrites(f, 2);
    f.mutex.lockUncancelable(io);
    defer f.mutex.unlock(io);
    try std.testing.expectEqual(@as(usize, 2), f.writes.items.len);
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, f.writes.items[1], "data: "));
}

test "sse: ids are <epoch>-<seq>, one sequence across topics" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const f = try h.add(&.{ "a", "b" }, null);
    _ = try h.hub.publish("a", .{ .data = "1" });
    _ = try h.hub.publish("b", .{ .data = "2", .event = "named" });
    _ = try h.hub.publish("a", .{ .data = "3" });
    var buf1: [40]u8 = undefined;
    var buf2: [40]u8 = undefined;
    var buf3: [40]u8 = undefined;
    var want: [256]u8 = undefined;
    const open = try std.fmt.bufPrint(&want, "id: {x:0>8}-0\n\n", .{h.hub.epoch});
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.writeAll(open);
    try w.writer.print("{s}data: 1\n\n", .{h.expectId(&buf1, 1)});
    try w.writer.print("{s}event: named\ndata: 2\n\n", .{h.expectId(&buf2, 2)});
    try w.writer.print("{s}data: 3\n\n", .{h.expectId(&buf3, 3)});
    Harness.waitBytes(f, w.written().len);
    try std.testing.expectEqualStrings(w.written(), Harness.text(f));
}

test "sse: the open line carries retry when set" {
    const h = try Harness.init(.{ .retry = .fromMilliseconds(2500) });
    defer h.deinit();
    const f = try h.add(&.{"t"}, null);
    var want: [64]u8 = undefined;
    const open = try std.fmt.bufPrint(&want, "retry: 2500\nid: {x:0>8}-0\n\n", .{h.hub.epoch});
    Harness.waitBytes(f, open.len);
    try std.testing.expectEqualStrings(open, Harness.text(f));
}

fn idOf(h: *Harness, seq: u64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>8}-{d}", .{ h.hub.epoch, seq }) catch unreachable;
}

test "sse: resume replays exactly the missed events of two topics, merged by seq" {
    const h = try Harness.init(.{});
    defer h.deinit();
    // A first subscriber keeps both topics alive.
    _ = try h.add(&.{ "a", "b" }, null);
    _ = try h.hub.publish("a", .{ .data = "a1" }); // 1
    _ = try h.hub.publish("b", .{ .data = "b2" }); // 2
    _ = try h.hub.publish("a", .{ .data = "a3" }); // 3
    _ = try h.hub.publish("b", .{ .data = "b4" }); // 4
    var buf: [40]u8 = undefined;
    const f = try h.add(&.{ "a", "b" }, idOf(h, 2, &buf));
    Harness.waitBytes(f, 1);
    // Open line, then 3 and 4 in order.
    var want: std.Io.Writer.Allocating = .init(gpa);
    defer want.deinit();
    var b1: [40]u8 = undefined;
    var b2: [40]u8 = undefined;
    try want.writer.print("id: {x:0>8}-4\n\n", .{h.hub.epoch});
    try want.writer.print("{s}data: a3\n\n{s}data: b4\n\n", .{ h.expectId(&b1, 3), h.expectId(&b2, 4) });
    Harness.waitBytes(f, want.written().len);
    try std.testing.expectEqualStrings(want.written(), Harness.text(f));
}

test "sse: a resume older than the ring is one gap event, other topics replay" {
    const h = try Harness.init(.{ .replay = .{ .events = 2 } });
    defer h.deinit();
    _ = try h.add(&.{ "a", "b" }, null);
    for (0..5) |i| {
        var d: [8]u8 = undefined;
        _ = try h.hub.publish("a", .{ .data = try std.fmt.bufPrint(&d, "a{d}", .{i}) }); // seq 1..5
    }
    _ = try h.hub.publish("b", .{ .data = "b" }); // 6
    var buf: [40]u8 = undefined;
    // Last seen: seq 1. Topic a kept only 4 and 5; b is complete.
    const f = try h.add(&.{ "a", "b" }, idOf(h, 1, &buf));
    var want: std.Io.Writer.Allocating = .init(gpa);
    defer want.deinit();
    var b1: [40]u8 = undefined;
    try want.writer.print("id: {x:0>8}-6\n\n", .{h.hub.epoch});
    try want.writer.print("{s}data: b\n\n", .{h.expectId(&b1, 6)});
    try want.writer.print("event: gap\nid: {x:0>8}-6\ndata: {{\"topics\":[\"a\"]}}\n\n", .{h.hub.epoch});
    Harness.waitBytes(f, want.written().len);
    try std.testing.expectEqualStrings(want.written(), Harness.text(f));
}

test "sse: another epoch or a malformed id is a gap for every topic" {
    const h = try Harness.init(.{});
    defer h.deinit();
    _ = try h.add(&.{ "a", "b" }, null);
    _ = try h.hub.publish("a", .{ .data = "x" });
    const f = try h.add(&.{ "a", "b" }, "ffffffff-1");
    const g = try h.add(&.{ "a", "b" }, "garbage");
    for ([_]*Fake{ f, g }) |fk| {
        Harness.waitBytes(fk, 1);
        while (std.mem.count(u8, Harness.text(fk), "event: gap") == 0) io.sleep(.fromMilliseconds(1), .awake) catch return;
        try std.testing.expect(std.mem.indexOf(u8, Harness.text(fk), "{\"topics\":[\"a\",\"b\"]}") != null);
        try std.testing.expect(std.mem.indexOf(u8, Harness.text(fk), "data: x") == null);
    }
}

test "sse: a resume over max_per_resume is a gap" {
    const h = try Harness.init(.{ .replay = .{ .max_per_resume = 3 } });
    defer h.deinit();
    _ = try h.add(&.{"t"}, null);
    for (0..5) |_| _ = try h.hub.publish("t", .{ .data = "x" });
    var buf: [40]u8 = undefined;
    const f = try h.add(&.{"t"}, idOf(h, 0, &buf));
    while (std.mem.count(u8, Harness.text(f), "event: gap") == 0) io.sleep(.fromMilliseconds(1), .awake) catch return;
    try std.testing.expect(std.mem.indexOf(u8, Harness.text(f), "data: x") == null);
}

test "sse: a topic outlives its last member by max_age; after the sweep a resume is a gap" {
    const h = try Harness.init(.{ .replay = .{ .max_age = .fromSeconds(60) } });
    defer h.deinit();
    const f = try h.add(&.{"t"}, null);
    _ = f;
    _ = try h.hub.publish("t", .{ .data = "one" });
    Topics._gone(h.subAt(0));
    h.waitClosed(1);
    // Within max_age: the topic still records, and a resume is exact.
    try std.testing.expectEqual(@as(usize, 0), try h.hub.publish("t", .{ .data = "two" }));
    var buf: [40]u8 = undefined;
    const g = try h.add(&.{"t"}, idOf(h, 1, &buf));
    var want: std.Io.Writer.Allocating = .init(gpa);
    defer want.deinit();
    var b1: [40]u8 = undefined;
    try want.writer.print("id: {x:0>8}-2\n\n{s}data: two\n\n", .{ h.hub.epoch, h.expectId(&b1, 2) });
    Harness.waitBytes(g, want.written().len);
    try std.testing.expectEqualStrings(want.written(), Harness.text(g));
    // The last member goes again; past max_age the sweep removes the topic.
    Topics._gone(h.subAt(1));
    h.waitClosed(2);
    _ = h.hub._tick(0, 1000 + 61_000);
    try std.testing.expectEqual(@as(usize, 0), h.hub.stats().topics);
    // A client that last saw seq 1 missed seq 2, which the swept topic forgot.
    const k = try h.add(&.{"t"}, idOf(h, 1, &buf));
    while (std.mem.count(u8, Harness.text(k), "event: gap") == 0) io.sleep(.fromMilliseconds(1), .awake) catch return;
}

test "sse: events with replay=false are delivered, never replayed; replay=null sends no ids" {
    {
        const h = try Harness.init(.{});
        defer h.deinit();
        const live = try h.add(&.{"t"}, null);
        _ = try h.hub.publish("t", .{ .data = "typing", .replay = false });
        Harness.waitBytes(live, 40);
        try std.testing.expect(std.mem.indexOf(u8, Harness.text(live), "data: typing") != null);
        var buf: [40]u8 = undefined;
        const late = try h.add(&.{"t"}, idOf(h, 0, &buf));
        // seq 1 is not in the ring, and the ring cannot say it is complete.
        while (std.mem.count(u8, Harness.text(late), "event: gap") == 0) io.sleep(.fromMilliseconds(1), .awake) catch return;
    }
    {
        const h = try Harness.init(.{ .replay = null });
        defer h.deinit();
        const f = try h.add(&.{"t"}, null);
        _ = try h.hub.publish("t", .{ .data = "x" });
        Harness.waitBytes(f, "data: x\n\n".len);
        try std.testing.expectEqualStrings("data: x\n\n", Harness.text(f));
    }
}

test "sse: last=N gives the newest N per topic, merged by seq" {
    const h = try Harness.init(.{});
    defer h.deinit();
    _ = try h.add(&.{ "a", "b" }, null);
    _ = try h.hub.publish("a", .{ .data = "a1" });
    _ = try h.hub.publish("b", .{ .data = "b2" });
    _ = try h.hub.publish("a", .{ .data = "a3" });
    const f = try h.add2(&.{ "a", "b" }, 1);
    var want: std.Io.Writer.Allocating = .init(gpa);
    defer want.deinit();
    var b1: [40]u8 = undefined;
    var b2: [40]u8 = undefined;
    // Newest one of each: b2 (seq 2) and a3 (seq 3).
    try want.writer.print("id: {x:0>8}-3\n\n{s}data: b2\n\n{s}data: a3\n\n", .{ h.hub.epoch, h.expectId(&b1, 2), h.expectId(&b2, 3) });
    Harness.waitBytes(f, want.written().len);
    try std.testing.expectEqualStrings(want.written(), Harness.text(f));
}

test "sse: a heartbeat tick writes a comment only to subscribers idle for the interval" {
    const h = try Harness.init(.{ .heartbeat = .fromSeconds(10) });
    defer h.deinit();
    const idle = try h.add(&.{"t"}, null);
    Harness.waitWrites(idle, 1);
    // Not yet: 5 s after the last write.
    _ = h.hub._tick(0, 1000 + 5_000);
    try std.testing.expect(std.mem.indexOf(u8, Harness.text(idle), ":\n\n") == null);
    _ = h.hub._tick(0, 1000 + 10_000);
    while (std.mem.indexOf(u8, Harness.text(idle), ":\n\n") == null) io.sleep(.fromMilliseconds(1), .awake) catch return;
}

test "sse: on_full=close: what is queued goes out, then the stream ends (slow)" {
    const h = try Harness.init(.{ .max_queued_bytes = 400, .replay = null });
    defer h.deinit();
    // Without replay and retry there is no open line: the first event's
    // write is the one held.
    const f = try h.addHeld(&.{"t"});
    _ = try h.hub.publish("t", .{ .data = "first" });
    f.held.wait(io) catch unreachable;
    // Queue until the cap: 64 bytes of cost each.
    var took: usize = 0;
    for (0..20) |_| took += try h.hub.publish("t", .{ .data = "more" });
    try std.testing.expect(took >= 1 and took < 20);
    f.open();
    h.waitClosed(1);
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.slow)), h.last_reason.load(.acquire));
    try std.testing.expect(f.ended);
    try std.testing.expectEqual(@as(u64, 1), h.hub.stats().closed_slow);
    // What was queued went out before the end.
    try std.testing.expect(std.mem.count(u8, Harness.text(f), "data: more") == took);
}

test "sse: on_full=drop: the full subscriber misses the event, the others get it" {
    const h = try Harness.init(.{ .max_queued_bytes = 400, .on_full = .drop, .replay = null });
    defer h.deinit();
    const slow = try h.addHeld(&.{"t"});
    const fast = try h.add(&.{"t"}, null);
    _ = try h.hub.publish("t", .{ .data = "first" });
    slow.held.wait(io) catch unreachable;
    // One at a time, each waited for on the fast one, so only the held one
    // fills up (the fast one has the same cap).
    Harness.waitBytes(fast, "data: first\n\n".len);
    for (1..21) |i| {
        _ = try h.hub.publish("t", .{ .data = "more" });
        Harness.waitBytes(fast, "data: first\n\n".len + i * "data: more\n\n".len);
    }
    try std.testing.expect(h.hub.stats().dropped > 0);
    try std.testing.expectEqual(@as(usize, 20), std.mem.count(u8, Harness.text(fast), "data: more"));
}

test "sse: Subscriber.send reaches one subscriber, with no id; Full past the cap" {
    const h = try Harness.init(.{ .max_queued_bytes = 300 });
    defer h.deinit();
    const a = try h.add(&.{"t"}, null);
    const b = try h.add(&.{"t"}, null);
    Harness.waitWrites(a, 1);
    Harness.waitWrites(b, 1);
    try h.subAt(0).send(.{ .data = "private", .event = "dm" });
    while (std.mem.indexOf(u8, Harness.text(a), "event: dm\ndata: private\n\n") == null) io.sleep(.fromMilliseconds(1), .awake) catch return;
    try std.testing.expect(std.mem.indexOf(u8, Harness.text(b), "private") == null);
    // Full: a held writer so the queue fills.
    const f = try h.addHeld(&.{"t"});
    f.held.wait(io) catch unreachable;
    const sub = h.subAt(2);
    var full = false;
    for (0..20) |_| sub.send(.{ .data = "xxxxxxxxxx" }) catch |err| {
        try std.testing.expect(err == error.Full);
        full = true;
        break;
    };
    try std.testing.expect(full);
}

test "sse: the peer gone with events queued: leaves every topic, on_close(client_gone)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const f = try h.addHeld(&.{ "a", "b" });
    f.held.wait(io) catch unreachable;
    _ = try h.hub.publish("a", .{ .data = "x" });
    _ = try h.hub.publish("b", .{ .data = "y" });
    Topics._gone(h.subAt(0));
    f.open();
    h.waitClosed(1);
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.client_gone)), h.last_reason.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), h.hub.count("a"));
    try std.testing.expectEqual(@as(usize, 0), h.hub.stats().subscribers);
    try std.testing.expect(f.released);
}

test "sse: the drain gives each subscriber a retry from the spread, then ends the stream" {
    const h = try Harness.init(.{ .drain_retry = .{ .min = .fromMilliseconds(500), .max = .fromSeconds(5) } });
    defer h.deinit();
    const a = try h.add(&.{"t"}, null);
    const b = try h.add(&.{"t"}, null);
    h.hub._drainNow();
    h.waitClosed(2);
    for ([_]*Fake{ a, b }) |f| {
        try std.testing.expect(f.ended);
        try std.testing.expect(std.mem.indexOf(u8, Harness.text(f), "retry: ") != null);
    }
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.drain)), h.last_reason.load(.acquire));
    // The spread differs between the two (indexes 0 and 1).
    const ta = Harness.text(a);
    const tb = Harness.text(b);
    try std.testing.expect(!std.mem.eql(u8, ta[std.mem.indexOf(u8, ta, "retry: ").?..], tb[std.mem.indexOf(u8, tb, "retry: ").?..]));
    // A subscribe during the drain: open line, retry, end.
    const late = try h.add(&.{"t"}, null);
    h.waitClosed(3);
    try std.testing.expect(late.ended);
}

test "sse: publish to an unknown topic is 0 and allocates nothing; bad input is an error" {
    const h = try Harness.init(.{});
    defer h.deinit();
    _ = try h.add(&.{"t"}, null);
    try std.testing.expectEqual(@as(usize, 0), try h.hub.publish("nobody", .{ .data = "x" }));
    try std.testing.expectError(error.InvalidTopic, h.hub.publish("", .{ .data = "x" }));
    const long: [256]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTopic, h.hub.publish(&long, .{ .data = "x" }));
    try std.testing.expectError(error.InvalidEventField, h.hub.publish("t", .{ .data = "x", .event = "a\nb" }));
    try std.testing.expectError(error.InvalidEventField, Topics.init(gpa, .{ .gap_event = "g\n" }));
}

test "sse: Subscriber.join and leave: events after the call" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const f = try h.add(&.{"a"}, null);
    Harness.waitWrites(f, 1);
    try std.testing.expectEqual(@as(usize, 0), try h.hub.publish("b", .{ .data = "before" }));
    try h.subAt(0).join("b", .{});
    try std.testing.expectEqual(@as(usize, 1), try h.hub.publish("b", .{ .data = "after-join" }));
    h.subAt(0).leave("b");
    try std.testing.expectEqual(@as(usize, 0), try h.hub.publish("b", .{ .data = "after-leave" }));
    while (std.mem.indexOf(u8, Harness.text(f), "after-join") == null) io.sleep(.fromMilliseconds(1), .awake) catch return;
    try std.testing.expect(std.mem.indexOf(u8, Harness.text(f), "after-leave") == null);
}

test "sse: a write error ends the subscriber (client_gone)" {
    const h = try Harness.init(.{});
    defer h.deinit();
    const f = try h.add(&.{"t"}, null);
    _ = f;
    h.waitClosed(0);
    // The first write (the open line) may already be done: fail the next.
    Harness.waitWrites(h.fakes.items[0], 1);
    h.fakes.items[0].fail_with = error.Gone;
    _ = try h.hub.publish("t", .{ .data = "x" });
    h.waitClosed(1);
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.client_gone)), h.last_reason.load(.acquire));
}

test "sse: routes: templates are checked against the path" {
    try std.testing.expect(root.templatesMatch("/rooms/:room/events", .{ .topics = &.{ "news", "room:{room}" } }));
    try std.testing.expect(!root.templatesMatch("/rooms/:id/events", .{ .topics = &.{"room:{room}"} }));
    try std.testing.expect(root.templatesMatch("/a/*rest", .{ .topics = &.{"{rest}"} }));
}

/// A hub and one held subscriber on a zio runtime, whose tasks can be
/// canceled one by one (the stuck-sender and leave paths cancel the
/// sender's task).
const ZioCase = struct {
    rt: *@import("zio").Runtime,
    hub: Topics,
    f: Fake,
    closed: std.atomic.Value(u32) = .init(0),
    reason: std.atomic.Value(u32) = .init(99),

    fn onClose(sub: *Subscriber, reason: root.CloseReason) void {
        const c: *ZioCase = @ptrCast(@alignCast(sub.context.?));
        c.reason.store(@intFromEnum(reason), .release);
        _ = c.closed.fetchAdd(1, .release);
    }

    fn init(c: *ZioCase, options: Topics.Options) !*Subscriber {
        c.rt = try @import("zio").Runtime.init(gpa, .{});
        const rio = c.rt.io();
        var o = options;
        o._manual_ticks = true;
        c.hub = try Topics.init(gpa, o);
        c.hub.fake_now_ms.store(1000, .monotonic);
        c.f = .init(gpa, rio);
        c.f.hold = true;
        c.closed = .init(0);
        c.reason = .init(99);
        return c.hub._attach(rio, c.f.out(), .{ .topics = &.{"t"}, .context = c, .on_close = onClose }, null);
    }

    fn waitClosed(c: *ZioCase) void {
        while (c.closed.load(.acquire) == 0) c.rt.io().sleep(.fromMilliseconds(1), .awake) catch return;
    }

    fn deinit(c: *ZioCase) void {
        c.f.open();
        c.hub.deinit();
        c.f.deinit();
        c.rt.deinit();
    }
};

test "sse: on_full=close with a stuck sender: the tick past close_after aborts the stream" {
    var c: ZioCase = undefined;
    _ = try c.init(.{ .max_queued_bytes = 400, .replay = null, .close_after = .fromSeconds(1) });
    defer c.deinit();
    const rio = c.rt.io();
    _ = try c.hub.publish("t", .{ .data = "first" });
    c.f.held.wait(rio) catch unreachable;
    // Fill the queue: the subscriber is ending (slow) with its sender stuck.
    for (0..20) |_| _ = try c.hub.publish("t", .{ .data = "more" });
    try std.testing.expectEqual(@as(u64, 1), c.hub.stats().closed_slow);
    // Before close_after: nothing happens.
    _ = c.hub._tick(0, 1000 + 500);
    try std.testing.expectEqual(@as(u32, 0), c.closed.load(.acquire));
    // Past it: the sender is canceled and the stream aborted.
    _ = c.hub._tick(0, 1000 + 1_500);
    c.waitClosed();
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.slow)), c.reason.load(.acquire));
    try std.testing.expect(c.f.aborted);
    try std.testing.expect(!c.f.ended);
    try std.testing.expectEqual(@as(u32, 0), c.f.writes_done.load(.acquire));
}

test "sse: leave while a write is under way: nothing is written after the end returns" {
    var c: ZioCase = undefined;
    const sub = try c.init(.{ .replay = null, .leave_grace = .fromMilliseconds(20) });
    defer c.deinit();
    const rio = c.rt.io();
    _ = try c.hub.publish("t", .{ .data = "x" });
    c.f.held.wait(rio) catch unreachable;
    Topics._gone(sub);
    c.waitClosed();
    try std.testing.expectEqual(@as(u32, @intFromEnum(root.CloseReason.client_gone)), c.reason.load(.acquire));
    try std.testing.expect(c.f.released);
    // The held write was canceled: letting it go writes nothing.
    c.f.open();
    try std.testing.expectEqual(@as(u32, 0), c.f.writes_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), c.f.bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.hub.count("t"));
}
