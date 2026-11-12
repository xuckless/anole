//! PostgreSQL LISTEN/NOTIFY for `anole.watch`: one LISTEN connection per
//! `pg.Client`, shared by every watch on it, with LISTEN and UNLISTEN
//! counted per channel (W2). Notifications are at most once: a lost
//! connection is a gap, and the connection is opened again with the
//! backoff and every channel listened to once more (§4.2).

const std = @import("std");
const pg_root = @import("../pg/root.zig");
const driver = pg_root.driver;
const root = @import("root.zig");
const hubs = @import("hub.zig");

const Watch = root.Watch;
const Allocator = std.mem.Allocator;

/// LISTEN and UNLISTEN on a `driver.Listener`, with a ping every 30 s.
const Transport = struct {
    pub const Client = pg_root.Client;
    pub const Conn = driver.Listener;
    pub const Kind = enum { channel };
    pub const log_name = "postgres watch";
    pub const verb = "LISTEN";
    pub const ready_text = "listening";
    pub const keepalive: ?hubs.Keepalive = .{ .interval = .fromSeconds(30), .wait = .fromSeconds(10) };

    pub fn dial(client: *Client, _: Allocator, names: hubs.Names(Kind)) !*Conn {
        const l = try client.gpa.create(Conn);
        errdefer client.gpa.destroy(l);
        l.* = try client.listener();
        errdefer l.deinit();
        // Answered through `next` (`.ready`).
        for (names.get(.channel)) |n| try l.sendListen(n);
        return l;
    }

    pub fn send(l: *Conn, _: Allocator, _: std.Io, on: bool, _: Kind, name: []const u8) !void {
        return if (on) l.sendListen(name) else l.sendUnlisten(name);
    }

    pub fn ping(l: *Conn) !void {
        return l.sendPing();
    }

    pub fn next(l: *Conn, _: Allocator) !?hubs.Message(Kind) {
        return switch (try l.nextEvent()) {
            .ready => .ready,
            .notification => |n| .{ .message = .{ .kind = .channel, .name = n.channel, .raw = .{
                .op = .message,
                .op_name = "message",
                .channel = n.channel,
                .data = n.payload,
                .pg_pid = @bitCast(n.process_id),
            } } },
        };
    }

    pub fn stop(l: *Conn) void {
        l.stop() catch {};
    }

    pub fn close(l: *Conn, gpa: Allocator) void {
        l.deinit();
        gpa.destroy(l);
    }
};

pub const NotifyHub = hubs.Hub(Transport);

/// The hub of `w`'s client, made on first use.
fn hubOf(w: *Watch) !*NotifyHub {
    return w.source.postgres.client._notifyHub();
}

pub fn register(w: *Watch) !void {
    const h = try hubOf(w);
    try h.add(w, w.source.postgres.channels, .channel);
    try h.ensureRunning();
}

pub fn unregister(w: *Watch) void {
    const h = w.source.postgres.client.notify_hub orelse return;
    h.remove(w, w.source.postgres.channels, .channel);
}

/// Tests: the hub's hook (`hub.Hub.test_on_gap`).
pub const test_on_gap = &NotifyHub.test_on_gap;

const GapProbe = struct {
    var calls: usize = 0;
    var unlocked: usize = 0;
    fn hook(hub: *NotifyHub) void {
        calls += 1;
        // `tryLock` succeeding means the hub's lock was free at the gap.
        if (hub.mutex.tryLock()) {
            hub.mutex.unlock(hub.io);
            unlocked += 1;
        }
    }
};

test "watch postgres: gapAll reaches each watch under the hub's lock, once (#165)" {
    const zio = @import("zio");
    const g = @import("../errors.zig").expectLog();
    defer g.deinit();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const rio = rt.io();
    // Nothing listens on port 1, and the reader is never started: the hub
    // only holds the two watches.
    const client = try pg_root.Client.init(gpa, rio, .{ .url = "postgres://u@127.0.0.1:1/db", .environ = .empty });
    defer client.deinit();
    const hub = try client._notifyHub();
    const w1 = try Watch.init(gpa, rio, .{ .postgres = .{ .client = client, .channels = &.{ "a", "b" } } }, .{});
    defer w1.deinit();
    const w2 = try Watch.init(gpa, rio, .{ .postgres = .{ .client = client, .channels = &.{"a"} } }, .{});
    defer w2.deinit();
    try hub.add(w1, &.{ "a", "b" }, .channel);
    try hub.add(w2, &.{"a"}, .channel);
    defer {
        hub.remove(w1, &.{ "a", "b" }, .channel);
        hub.remove(w2, &.{"a"}, .channel);
    }
    GapProbe.calls = 0;
    GapProbe.unlocked = 0;
    test_on_gap.store(&GapProbe.hook, .release);
    defer test_on_gap.store(null, .release);
    hub.gapAll("test");
    try std.testing.expectEqual(@as(usize, 2), GapProbe.calls);
    try std.testing.expectEqual(@as(usize, 0), GapProbe.unlocked);
    try std.testing.expectEqual(@as(u64, 1), w1.n_gaps.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), w2.n_gaps.load(.monotonic));
}
