//! The heartbeat against the runs it watches: its store calls never hold
//! up a run's start or end (SAFETY.md L2, L3).
const std = @import("std");
const wait = @import("anole_test_wait");
const zio = @import("zio");
const anole = @import("../root.zig");
const root = @import("root.zig");
const store = @import("store.zig");

const gpa = std.testing.allocator;
const long_kind: root.Kind = .{ .name = "t.hb.long", .attempts = 3, .timeout = .max };
const next_kind: root.Kind = .{ .name = "t.hb.next", .attempts = 3, .timeout = .max };

/// A store whose heartbeat holds nothing (every held run is lost, so the
/// heartbeat looks each one up), and whose first `get` waits until the
/// test lets it go (a cancelable wait, as a store's round trip is).
const HeldGet = struct {
    var io: std.Io = undefined;
    var orig: *const store.VTable = undefined;
    var vt: store.VTable = undefined;
    var in_get: std.atomic.Value(bool) = .init(false);
    var release: std.Io.Event = .unset;
    var long_started: std.atomic.Value(bool) = .init(false);
    var next_ran: std.atomic.Value(bool) = .init(false);
    var never: std.Io.Event = .unset;

    fn install(client: *root.Client, rio: std.Io) void {
        io = rio;
        in_get.store(false, .release);
        release = .unset;
        long_started.store(false, .release);
        next_ran.store(false, .release);
        never = .unset;
        orig = client.backend.vt;
        vt = orig.*;
        vt.heartbeat = heartbeat;
        vt.get = get;
        client.backend.vt = &vt;
    }

    fn heartbeat(_: *anyopaque, _: std.mem.Allocator, _: root.Time, _: []const store.Held) anyerror![]root.Id {
        return &.{};
    }

    fn get(ptr: *anyopaque, arena: std.mem.Allocator, id: root.Id) anyerror!?store.Row {
        if (!in_get.swap(true, .acq_rel)) try release.wait(io);
        return orig.get(ptr, arena, id);
    }

    /// Runs until the heartbeat cancels it as lost.
    fn runLong(_: ?*anyopaque, _: *root.Job) anyerror!void {
        long_started.store(true, .release);
        try never.wait(io);
    }

    fn runNext(_: ?*anyopaque, _: *root.Job) anyerror!void {
        next_ran.store(true, .release);
    }
};

fn heartbeatGetCheck(io: std.Io) !void {
    // The shortest lease: the heartbeat comes every second.
    const client = try root.Client.init(gpa, io, .{ .store = .memory, .lease = .fromSeconds(3) });
    defer client.deinit();
    HeldGet.install(client, io);
    // Before the client's teardown: a failed check must not leave the
    // heartbeat in the held store call.
    defer HeldGet.release.set(io);
    try client.addHandler(long_kind, null, HeldGet.runLong);
    try client.addHandler(next_kind, null, HeldGet.runNext);
    try client.start(null, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
    _ = try client.enqueueRaw(&ctx, long_kind.name, "{}", .{});
    try wait.waitFlag(io, "the long run started", &HeldGet.long_started);
    try wait.waitFlag(io, "the heartbeat is in the store's get for the lost run", &HeldGet.in_get);
    // While the heartbeat waits on the store, a new run starts.
    _ = try client.enqueueRaw(&ctx, next_kind.name, "{}", .{});
    try wait.waitFlag(io, "the next run ran while the heartbeat waited on the store", &HeldGet.next_ran);
}

test "jobs: a heartbeat waiting on the store does not hold up a new run's start" {
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(heartbeatGetCheck, .{io});
    try f.await(io);
}
