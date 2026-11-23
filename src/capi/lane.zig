//! The ordered publish lane of the ws and sse areas: an executor-local FIFO
//! of publishes and the one task that fans them out in the order they were
//! taken. Executor-local, so no atomics or locks.
const std = @import("std");

/// A FIFO of `Cmd` linked through `Cmd.next`, and whether its task runs.
/// `Cmd` has `next: ?*Cmd`, `after: u32` (the topic-change count to wait
/// for) and `fn free(*Cmd) void`.
///
/// Every lane transition is a method here; add behaviour as a state or an
/// event column of this table, not as a flag in an area. The queue is
/// empty in idle.
///
/// | state   | push                                   | take (non-empty)              | take (empty)              | dropAll (spawn failed, canceled wait, deinit) |
/// |---------|----------------------------------------|-------------------------------|---------------------------|-----------------------------------------------|
/// | idle    | enqueue, -> running, true (start task) | unreachable (no task): null   | null, stays idle          | frees nothing, stays idle, 0                  |
/// | running | enqueue, stays running, false          | pop, stays running, the cmd   | -> idle, null (task ends) | frees all queued, -> idle, the count          |
///
/// A cancel is the lane task calling `dropAll` (`run`); the cmd it had
/// popped is no longer queued and is freed by `run` itself.
pub fn Lane(comptime Cmd: type) type {
    return struct {
        const Self = @This();
        pub const State = enum { idle, running };

        head: ?*Cmd = null,
        tail: ?*Cmd = null,
        state: State = .idle,

        /// Appends `cmd`; true when the caller must start the lane task.
        pub fn push(l: *Self, cmd: *Cmd) bool {
            cmd.next = null;
            if (l.tail) |t| t.next = cmd else l.head = cmd;
            l.tail = cmd;
            const start = l.state == .idle;
            l.state = .running;
            return start;
        }

        /// The next cmd, or null and idle when the queue is empty.
        pub fn take(l: *Self) ?*Cmd {
            const cmd = l.head orelse {
                l.state = .idle;
                return null;
            };
            l.head = cmd.next;
            if (l.head == null) l.tail = null;
            return cmd;
        }

        /// Frees every queued cmd and goes idle; returns how many it freed.
        pub fn dropAll(l: *Self) usize {
            var n: usize = 0;
            while (l.head) |cmd| {
                l.head = cmd.next;
                cmd.free();
                n += 1;
            }
            l.tail = null;
            l.state = .idle;
            return n;
        }

        /// The lane task: takes the cmds one after the other, each waiting
        /// until `done` reaches its `after`, then `fanOut(ctx, cmd)`. A
        /// cancel (of the wait or of the fan-out) drops what is left.
        pub fn run(
            l: *Self,
            io: std.Io,
            done: *const std.atomic.Value(u32),
            ctx: anytype,
            comptime fanOut: fn (@TypeOf(ctx), *Cmd) std.Io.Cancelable!void,
        ) std.Io.Cancelable!void {
            while (l.take()) |cmd| {
                defer cmd.free();
                errdefer _ = l.dropAll();
                try awaitAtLeast(io, done, cmd.after);
                try fanOut(ctx, cmd);
            }
        }
    };
}

/// Waits until `done` has counted to `want` (wrap-safe): every topic change
/// taken before a publish is applied before it fans out.
pub fn awaitAtLeast(io: std.Io, done: *const std.atomic.Value(u32), want: u32) std.Io.Cancelable!void {
    while (true) {
        const d = done.load(.acquire);
        if (@as(i32, @bitCast(d -% want)) >= 0) return;
        try io.futexWait(u32, &done.raw, d);
    }
}

const TestCmd = struct {
    id: u8,
    after: u32 = 0,
    next: ?*TestCmd = null,
    freed: *u32,

    pub fn free(c: *TestCmd) void {
        c.freed.* += 1;
    }
};
const TestLane = Lane(TestCmd);

const Recorder = struct {
    seen: [8]u8 = undefined,
    len: usize = 0,
    fail_at: ?usize = null,

    fn fanOut(r: *Recorder, c: *TestCmd) std.Io.Cancelable!void {
        if (r.fail_at == r.len) return error.Canceled;
        r.seen[r.len] = c.id;
        r.len += 1;
    }
};

test "capi engine: lane, state x event" {
    var freed: u32 = 0;
    var cmds: [3]TestCmd = .{ .{ .id = 'a', .freed = &freed }, .{ .id = 'b', .freed = &freed }, .{ .id = 'c', .freed = &freed } };
    const a, const b, const c = .{ &cmds[0], &cmds[1], &cmds[2] };

    const Row = struct {
        name: []const u8,
        start: []const *TestCmd,
        start_state: TestLane.State,
        event: enum { push_c, take, take_twice, drop_all, repush_a },
        returned: usize,
        order: []const u8 = "",
        state: TestLane.State,
        freed: u32 = 0,
    };
    const rows = [_]Row{
        .{ .name = "idle push starts", .start = &.{}, .start_state = .idle, .event = .push_c, .returned = 1, .order = "c", .state = .running },
        .{ .name = "running push queues", .start = &.{a}, .start_state = .running, .event = .push_c, .returned = 0, .order = "ac", .state = .running },
        .{ .name = "take pops in order", .start = &.{ a, b }, .start_state = .running, .event = .take_twice, .returned = 2, .order = "", .state = .running },
        .{ .name = "take empty ends", .start = &.{}, .start_state = .running, .event = .take, .returned = 0, .state = .idle },
        .{ .name = "idle take", .start = &.{}, .start_state = .idle, .event = .take, .returned = 0, .state = .idle },
        .{ .name = "dropAll running", .start = &.{ a, b, c }, .start_state = .running, .event = .drop_all, .returned = 3, .state = .idle, .freed = 3 },
        .{ .name = "dropAll idle", .start = &.{}, .start_state = .idle, .event = .drop_all, .returned = 0, .state = .idle },
        .{ .name = "link reuse", .start = &.{ a, b }, .start_state = .running, .event = .repush_a, .returned = 0, .order = "ba", .state = .running },
    };
    for (rows) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        freed = 0;
        var l: TestLane = .{};
        for (row.start) |s| _ = l.push(s);
        l.state = row.start_state;
        const got: usize = switch (row.event) {
            .push_c => @intFromBool(l.push(c)),
            .take => if (l.take()) |_| 1 else 0,
            .take_twice => blk: {
                try std.testing.expectEqual(a, l.take().?);
                try std.testing.expectEqual(b, l.take().?);
                break :blk 2;
            },
            .drop_all => l.dropAll(),
            .repush_a => blk: {
                const p = l.take().?;
                try std.testing.expectEqual(a, p);
                break :blk @intFromBool(l.push(p));
            },
        };
        try std.testing.expectEqual(row.returned, got);
        try std.testing.expectEqual(row.state, l.state);
        try std.testing.expectEqual(row.freed, freed);
        var order: [8]u8 = undefined;
        var n: usize = 0;
        var it = l.head;
        while (it) |p| : (it = p.next) {
            order[n] = p.id;
            n += 1;
        }
        try std.testing.expectEqualStrings(row.order, order[0..n]);
        try std.testing.expectEqual(n == 0, l.tail == null);
        if (l.tail) |t| try std.testing.expectEqual(@as(?*TestCmd, null), t.next);
    }
}

test "capi engine: lane, push after drain starts again" {
    var freed: u32 = 0;
    var a: TestCmd = .{ .id = 'a', .freed = &freed };
    var c: TestCmd = .{ .id = 'c', .freed = &freed };
    var l: TestLane = .{};
    try std.testing.expect(l.push(&a));
    try std.testing.expect(!l.push(&c));
    _ = l.take();
    _ = l.take();
    try std.testing.expectEqual(@as(?*TestCmd, null), l.take());
    try std.testing.expectEqual(TestLane.State.idle, l.state);
    try std.testing.expect(l.push(&c));
}

test "capi engine: lane, awaitAtLeast is wrap-safe" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const rows = [_]struct { done: u32, want: u32 }{
        .{ .done = std.math.maxInt(u32), .want = std.math.maxInt(u32) },
        .{ .done = 0, .want = 0 },
        .{ .done = 1, .want = std.math.maxInt(u32) },
        .{ .done = 5, .want = 3 },
    };
    for (rows) |row| {
        var done: std.atomic.Value(u32) = .init(row.done);
        try awaitAtLeast(io, &done, row.want);
    }
}

test "capi engine: lane, run" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const rows = [_]struct { name: []const u8, fail_at: ?usize, seen: []const u8, err: bool }{
        .{ .name = "run drains in order", .fail_at = null, .seen = "abc", .err = false },
        .{ .name = "run fanOut error", .fail_at = 1, .seen = "a", .err = true },
    };
    for (rows) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        var freed: u32 = 0;
        var cmds: [3]TestCmd = .{ .{ .id = 'a', .freed = &freed }, .{ .id = 'b', .freed = &freed }, .{ .id = 'c', .freed = &freed } };
        var l: TestLane = .{};
        for (&cmds) |*cm| _ = l.push(cm);
        var done: std.atomic.Value(u32) = .init(0);
        var r: Recorder = .{ .fail_at = row.fail_at };
        const res = l.run(io, &done, &r, Recorder.fanOut);
        if (row.err) try std.testing.expectError(error.Canceled, res) else try res;
        try std.testing.expectEqualStrings(row.seen, r.seen[0..r.len]);
        try std.testing.expectEqual(@as(u32, 3), freed);
        try std.testing.expectEqual(TestLane.State.idle, l.state);
        try std.testing.expectEqual(@as(?*TestCmd, null), l.head);
        try std.testing.expectEqual(@as(?*TestCmd, null), l.tail);
    }
}

test "capi engine: lane, run cancel during the wait" {
    const zio = @import("../root.zig").zio;
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var freed: u32 = 0;
    var cmds: [3]TestCmd = .{ .{ .id = 'a', .after = 1, .freed = &freed }, .{ .id = 'b', .after = 1, .freed = &freed }, .{ .id = 'c', .after = 1, .freed = &freed } };
    var l: TestLane = .{};
    for (&cmds) |*cm| _ = l.push(cm);
    var done: std.atomic.Value(u32) = .init(0);
    var r: Recorder = .{};
    var f = try io.concurrent(struct {
        fn lane(l_: *TestLane, io_: std.Io, done_: *const std.atomic.Value(u32), r_: *Recorder) std.Io.Cancelable!void {
            return l_.run(io_, done_, r_, Recorder.fanOut);
        }
    }.lane, .{ &l, io, &done, &r });
    try std.testing.expectError(error.Canceled, f.cancel(io));
    try std.testing.expectEqual(@as(usize, 0), r.len);
    try std.testing.expectEqual(@as(u32, 3), freed);
    try std.testing.expectEqual(TestLane.State.idle, l.state);
    try std.testing.expectEqual(@as(?*TestCmd, null), l.head);
}
