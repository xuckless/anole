//! The shared connection behind the PostgreSQL LISTEN/NOTIFY (`pg.zig`) and
//! Redis Pub/Sub (`redis.zig`) watches: one connection per client, shared
//! by every watch on it, each name subscribed while it has watches (W2).
//! Messages are at most once: a lost connection is a gap, and the
//! connection is opened again with the backoff and every name subscribed
//! once more (§4.2, §4.3).
//!
//! A transport `T` supplies:
//! - `Client` (with `gpa` and `io`), `Conn`, and `Kind`, an enum of the name
//!   kinds (PostgreSQL: channels; Redis: channels and patterns);
//! - `log_name`, `verb` ("LISTEN", "SUBSCRIBE") and `ready_text` for logs;
//! - `keepalive: ?Keepalive`, and `ping(conn) !void` when it is set;
//! - `dial(client, arena, names) !*Conn`: a connection subscribed to `names`;
//! - `send(conn, gpa, io, on, kind, name) !void`: subscribes or unsubscribes
//!   one name, without waiting for the answer (it comes through `next`);
//! - `next(conn, arena) !?Message(Kind)`: the next message, or null once the
//!   connection ended; `arena` is reset before each call;
//! - `stop(conn)`: ends a `next` waiting on another task; any task;
//! - `close(conn, gpa)`: frees it, not while `next` waits.

const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const placement = dusty.placement;
const root = @import("root.zig");
const resilience = @import("../resilience/root.zig");

const Watch = root.Watch;
const log = @import("../errors.zig").log;

/// A ping every `interval`; no answer within `wait` is a dead connection.
pub const Keepalive = struct {
    interval: std.Io.Duration,
    wait: std.Io.Duration,
};

/// What `T.next` reads: an answer to a command (the keep-alive's proof of
/// life), or a message for the watches of `name` of `kind`.
pub fn Message(comptime Kind: type) type {
    return union(enum) {
        ready,
        message: struct { kind: Kind, name: []const u8, raw: root.Raw },
    };
}

/// The names `T.dial` subscribes to, per kind.
pub fn Names(comptime Kind: type) type {
    return std.EnumArray(Kind, []const []const u8);
}

pub fn Hub(comptime T: type) type {
    return struct {
        const Self = @This();
        const Kind = T.Kind;
        const Entry = struct {
            name: []u8,
            watches: std.ArrayList(*Watch) = .empty,
        };
        const Entries = std.EnumArray(Kind, std.StringHashMapUnmanaged(*Entry));
        const NameSet = std.EnumArray(Kind, std.StringArrayHashMapUnmanaged(void));

        /// The reader's phase: none running, (re)connecting, or reading
        /// `ready`.
        pub const State = union(enum) { idle, connecting, ready: *T.Conn };

        gpa: std.mem.Allocator,
        io: std.Io,
        client: *T.Client,
        /// Over `entries`, `state`, `reader_task` and the watch lists.
        mutex: std.Io.Mutex = .init,
        entries: Entries = .initFill(.empty),
        state: State = .idle,
        /// Serializes the writes (verbs, pings) on the connection. Taken
        /// before `mutex`, never after. The reader takes it before it
        /// unpublishes a connection it frees, so a connection a writer read
        /// under both stays alive until the write ends (#198).
        write_mutex: std.Io.Mutex = .init,
        group: std.Io.Group = .init,
        /// The current connection's keep-alive, canceled (and waited for)
        /// before the reader frees the connection (#198).
        keepalive_group: std.Io.Group = .init,
        stopping: std.atomic.Value(bool) = .init(false),
        reader_task: ?placement.Task = null,
        backoff: resilience.Backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(5) },
        /// Awake-clock milliseconds of the last answer read (`.ready`).
        last_ready_ms: std.atomic.Value(i64) = .init(0),

        pub fn create(client: *T.Client) !*Self {
            const h = try client.gpa.create(Self);
            h.* = .{ .gpa = client.gpa, .io = client.io, .client = client };
            return h;
        }

        /// Stops the tasks and frees the hub (the client's `deinit`).
        pub fn destroy(self: *Self) void {
            self.stopping.store(true, .release);
            self.mutex.lockUncancelable(self.io);
            if (self.state == .ready) T.stop(self.state.ready);
            if (self.reader_task) |t| placement.cancelTask(t);
            self.mutex.unlock(self.io);
            self.group.cancel(self.io);
            self.keepalive_group.cancel(self.io);
            if (self.state == .ready) T.close(self.state.ready, self.gpa);
            for (&self.entries.values) |*map| {
                var it = map.valueIterator();
                while (it.next()) |e| {
                    e.*.watches.deinit(self.gpa);
                    self.gpa.free(e.*.name);
                    self.gpa.destroy(e.*);
                }
                map.deinit(self.gpa);
            }
            self.gpa.destroy(self);
        }

        /// Adds `w` to each name, subscribing to the new ones.
        pub fn add(self: *Self, w: *Watch, names: []const []const u8, kind: Kind) !void {
            for (names) |name| {
                var send = false;
                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    const map = self.entries.getPtr(kind);
                    const entry = try map.getOrPut(self.gpa, name);
                    if (!entry.found_existing) {
                        const e = self.gpa.create(Entry) catch |err| {
                            map.removeByPtr(entry.key_ptr);
                            return err;
                        };
                        e.* = .{ .name = self.gpa.dupe(u8, name) catch |err| {
                            self.gpa.destroy(e);
                            map.removeByPtr(entry.key_ptr);
                            return err;
                        } };
                        entry.key_ptr.* = e.name;
                        entry.value_ptr.* = e;
                        send = self.state == .ready;
                    }
                    try entry.value_ptr.*.watches.append(self.gpa, w);
                }
                if (send) self.sendVerb(true, kind, name);
            }
        }

        /// Takes `w` out of each name, unsubscribing from those left with
        /// none.
        pub fn remove(self: *Self, w: *Watch, names: []const []const u8, kind: Kind) void {
            for (names) |name| {
                var send = false;
                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    const map = self.entries.getPtr(kind);
                    const e = map.get(name) orelse continue;
                    for (e.watches.items, 0..) |x, i| if (x == w) {
                        _ = e.watches.swapRemove(i);
                        break;
                    };
                    if (e.watches.items.len == 0) {
                        _ = map.remove(name);
                        e.watches.deinit(self.gpa);
                        self.gpa.free(e.name);
                        self.gpa.destroy(e);
                        send = self.state == .ready;
                    }
                }
                if (send) self.sendVerb(false, kind, name);
            }
        }

        fn sendVerb(self: *Self, on: bool, kind: Kind, name: []const u8) void {
            self.write_mutex.lockUncancelable(self.io);
            defer self.write_mutex.unlock(self.io);
            const conn = self.current() orelse return;
            testBeforeSend(self);
            T.send(conn, self.gpa, self.io, on, kind, name) catch |err| {
                log.debug(T.log_name ++ ": {s} {s} failed: {t}", .{ if (on) T.verb else "UN" ++ T.verb, name, err });
                // The reader sees the broken connection and reconnects.
                T.stop(conn);
            };
        }

        /// Starts the reader, unless it runs.
        pub fn ensureRunning(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state != .idle) return;
            placement.concurrent(&self.group, self.io, .local, readerTask, .{self}) catch return error.ServiceUnavailable;
            self.state = .connecting;
        }

        /// The connection's task: connects, subscribes, reads, and again
        /// after a failure; ends once no watch is left.
        fn readerTask(self: *Self) std.Io.Cancelable!void {
            self.mutex.lockUncancelable(self.io);
            self.reader_task = placement.currentTask(self.io);
            self.mutex.unlock(self.io);
            var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena_state.deinit();
            var attempt: u32 = 0;
            var first = true;
            while (!self.stopping.load(.acquire)) {
                _ = arena_state.reset(.retain_capacity);
                const conn = self.open(arena_state.allocator()) catch |err| {
                    const e: anyerror = err;
                    if (e == error.Canceled) return error.Canceled;
                    if (e == error.Idle) return;
                    attempt += 1;
                    if (attempt == 1) {
                        log.warn(T.log_name ++ ": cannot open the " ++ T.verb ++ " connection ({t}); trying again", .{err});
                    } else log.debug(T.log_name ++ ": " ++ T.verb ++ " connection attempt {d} failed: {t}", .{ attempt, err });
                    self.statusAll(.reconnecting);
                    try self.pause(attempt);
                    continue;
                };
                attempt = 0;
                const lost = !first;
                first = false;
                self.last_ready_ms.store(self.nowMs(), .release);
                self.statusAll(.connected);
                if (lost) self.gapAll("the " ++ T.verb ++ " connection was lost and opened again");
                log.info(T.log_name ++ ": " ++ T.ready_text, .{});
                if (comptime T.keepalive != null) placement.concurrent(&self.keepalive_group, self.io, .local, keepaliveTask, .{ self, conn }) catch {};
                self.readLoop(conn);
                // Gone: close it, tell the watches, try again.
                const idle = self.retire(conn);
                if (self.stopping.load(.acquire) or idle) return;
                log.warn(T.log_name ++ ": the " ++ T.verb ++ " connection was lost; opening it again", .{});
                self.statusAll(.reconnecting);
                attempt += 1;
                try self.pause(attempt);
            }
        }

        /// A connection subscribed to every name, published as `.ready`.
        /// `error.Idle` when there are none: the hub is idle and the reader
        /// ends (the next `ensureRunning` starts one).
        fn open(self: *Self, arena: std.mem.Allocator) !*T.Conn {
            var dialed: NameSet = .initFill(.empty);
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                var any = false;
                for (&self.entries.values, &dialed.values) |*map, *set| {
                    var it = map.keyIterator();
                    while (it.next()) |k| {
                        try set.put(arena, try arena.dupe(u8, k.*), {});
                        any = true;
                    }
                }
                if (!any) {
                    self.goIdle();
                    return error.Idle;
                }
            }
            var names: Names(Kind) = .initFill(&.{});
            for (&names.values, &dialed.values) |*n, *set| n.* = set.keys();
            const conn = try T.dial(self.client, arena, names);
            // Names added or removed while it dialed are subscribed or
            // unsubscribed now; the rest already are.
            const Change = struct { on: bool, kind: Kind, name: []const u8 };
            var changes: std.ArrayList(Change) = .empty;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.state = .{ .ready = conn };
                for (std.enums.values(Kind)) |kind| {
                    const map = self.entries.getPtr(kind);
                    const set = dialed.getPtr(kind);
                    var it = map.keyIterator();
                    while (it.next()) |k| if (!set.contains(k.*)) {
                        const name = arena.dupe(u8, k.*) catch continue;
                        changes.append(arena, .{ .on = true, .kind = kind, .name = name }) catch {};
                    };
                    for (set.keys()) |k| if (!map.contains(k)) {
                        changes.append(arena, .{ .on = false, .kind = kind, .name = k }) catch {};
                    };
                }
            }
            for (changes.items) |c| self.sendVerb(c.on, c.kind, c.name);
            return conn;
        }

        /// Under `mutex`.
        fn goIdle(self: *Self) void {
            self.state = .idle;
            self.reader_task = null;
        }

        /// Takes the lost `conn` out and frees it, once its keep-alive and
        /// a send in flight on it ended (#198). True when no watch is left:
        /// the hub is idle and the reader ends.
        fn retire(self: *Self, conn: *T.Conn) bool {
            // A send or ping blocked on it fails now.
            T.stop(conn);
            testOnRetire(self);
            self.keepalive_group.cancel(self.io);
            self.write_mutex.lockUncancelable(self.io);
            self.mutex.lockUncancelable(self.io);
            var idle = true;
            for (&self.entries.values) |*map| idle = idle and map.count() == 0;
            if (idle) self.goIdle() else self.state = .connecting;
            self.mutex.unlock(self.io);
            self.write_mutex.unlock(self.io);
            T.close(conn, self.gpa);
            return idle;
        }

        /// The published connection; under `write_mutex`, it stays alive
        /// until that is unlocked.
        fn current(self: *Self) ?*T.Conn {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return switch (self.state) {
                .ready => |c| c,
                else => null,
            };
        }

        fn nowMs(self: *Self) i64 {
            return std.Io.Clock.awake.now(self.io).toMilliseconds();
        }

        fn pause(self: *Self, attempt: u32) std.Io.Cancelable!void {
            var rnd: [8]u8 = undefined;
            self.io.random(&rnd);
            try self.io.sleep(self.backoff.delay(attempt, std.mem.readInt(u64, &rnd, .little)), .awake);
        }

        fn readLoop(self: *Self, conn: *T.Conn) void {
            var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena_state.deinit();
            while (true) {
                _ = arena_state.reset(.retain_capacity);
                const msg = T.next(conn, arena_state.allocator()) catch |err| {
                    if (!self.stopping.load(.acquire)) log.debug(T.log_name ++ ": read failed: {t}", .{err});
                    return;
                } orelse return;
                switch (msg) {
                    .ready => self.last_ready_ms.store(self.nowMs(), .release),
                    .message => |m| self.dispatch(m.kind, m.name, m.raw),
                }
            }
        }

        /// Hands a message to the watches of its name, in arrival order.
        /// Holds the hub's lock: a watch's `onHubEvent` never waits.
        fn dispatch(self: *Self, kind: Kind, name: []const u8, raw: root.Raw) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const e = self.entries.getPtr(kind).get(name) orelse return;
            for (e.watches.items) |w| w.onHubEvent(raw);
        }

        fn statusAll(self: *Self, s: root.Status) void {
            testBeforeStatus();
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (&self.entries.values) |*map| {
                var it = map.valueIterator();
                while (it.next()) |e| for (e.*.watches.items) |w| w.setStatus(s);
            }
        }

        pub fn gapAll(self: *Self, detail: []const u8) void {
            // Each watch once, even when it has several names.
            var seen: std.ArrayList(*Watch) = .empty;
            defer seen.deinit(self.gpa);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (&self.entries.values) |*map| {
                var it = map.valueIterator();
                while (it.next()) |e| for (e.*.watches.items) |w| {
                    var dup = false;
                    for (seen.items) |s| if (s == w) {
                        dup = true;
                        break;
                    };
                    if (!dup) seen.append(self.gpa, w) catch {};
                };
            }
            // Still under the hub's lock, as `dispatch` and `statusAll`: a
            // watch that `stop` took out (and `deinit` may have freed) is
            // never reached (#165, #157).
            for (seen.items) |w| {
                testOnGap(self);
                w.gapped(detail);
            }
        }

        /// Every `interval` a ping; no answer within `wait` means a dead
        /// connection, which `stop` turns into a read error for the reader.
        /// `conn` outlives it: the reader cancels and waits for it before
        /// freeing `conn` (#198).
        fn keepaliveTask(self: *Self, conn: *T.Conn) std.Io.Cancelable!void {
            const ka = T.keepalive.?;
            while (true) {
                try self.io.sleep(ka.interval, .awake);
                if (self.stopping.load(.acquire)) return;
                const before = self.last_ready_ms.load(.acquire);
                {
                    self.write_mutex.lockUncancelable(self.io);
                    defer self.write_mutex.unlock(self.io);
                    testBeforeSend(self);
                    T.ping(conn) catch {
                        T.stop(conn);
                        return;
                    };
                }
                try self.io.sleep(ka.wait, .awake);
                if (self.last_ready_ms.load(.acquire) == before) {
                    log.warn(T.log_name ++ ": the server did not answer a ping; closing the " ++ T.verb ++ " connection", .{});
                    T.stop(conn);
                    return;
                }
            }
        }

        /// Tests: runs before each watch `gapAll` gives a gap, with the hub.
        /// Test builds only.
        pub var test_on_gap: if (builtin.is_test) std.atomic.Value(?*const fn (*Self) void) else void = if (builtin.is_test) .init(null) else {};

        fn testOnGap(hub: *Self) void {
            if (comptime !builtin.is_test) return;
            const hook = test_on_gap.load(.acquire) orelse return;
            hook(hub);
        }

        /// Tests: runs once, between a send's or ping's read of the
        /// connection and its use. Test builds only.
        pub var test_before_send: if (builtin.is_test) std.atomic.Value(?*const fn (*Self) void) else void = if (builtin.is_test) .init(null) else {};

        fn testBeforeSend(hub: *Self) void {
            if (comptime !builtin.is_test) return;
            const hook = test_before_send.swap(null, .acq_rel) orelse return;
            hook(hub);
        }

        /// Tests: runs on the reader once it stopped a lost connection,
        /// before it waits for the connection's other users and frees it.
        /// Test builds only.
        pub var test_on_retire: if (builtin.is_test) std.atomic.Value(?*const fn (*Self) void) else void = if (builtin.is_test) .init(null) else {};

        fn testOnRetire(hub: *Self) void {
            if (comptime !builtin.is_test) return;
            const hook = test_on_retire.load(.acquire) orelse return;
            hook(hub);
        }

        /// Tests: runs once, on the reader, as `statusAll` begins (before it
        /// takes the hub's lock), where a watch's owner may end and free it.
        /// Test builds only.
        pub var test_before_status: if (builtin.is_test) std.atomic.Value(?*const fn () void) else void = if (builtin.is_test) .init(null) else {};

        fn testBeforeStatus() void {
            if (comptime !builtin.is_test) return;
            const hook = test_before_status.swap(null, .acq_rel) orelse return;
            hook();
        }
    };
}

// ---------------------------------------------------------------------------
// Tests: a transport with no server.

const features = @import("build_options");
const pg_test = if (features.postgres) @import("../pg/root.zig") else struct {};

fn Fake(comptime ka: ?Keepalive) type {
    return struct {
        pub const Kind = enum { channel, pattern };
        pub const log_name = "fake watch";
        pub const verb = "LISTEN";
        pub const ready_text = "listening";
        pub const keepalive = ka;
        const alive: u32 = 0x5eed;

        pub const Client = struct {
            gpa: std.mem.Allocator,
            io: std.Io,
            refuse: bool = false,
            /// Connections dialed.
            dials: std.atomic.Value(u32) = .init(0),
            /// The last one.
            conn: ?*Conn = null,
            /// Set by the first two connections' first `next`: published
            /// and read.
            reading: [2]std.Io.Event = @splat(.unset),
            /// The verbs sent ("+a", "-p:b"), under the hub's write lock.
            sent: std.ArrayList(u8) = .empty,
        };

        pub const Conn = struct {
            client: *Client,
            index: u32,
            magic: u32 = alive,
            ended: std.Io.Event = .unset,
        };

        /// A send, ping or stop found a freed connection.
        var used_freed: std.atomic.Value(bool) = .init(false);
        /// Set when a connection is freed.
        var freed: std.Io.Event = .unset;
        /// Runs on the reader at each `dial`.
        var on_dial: ?*const fn () void = null;

        fn reset() void {
            used_freed.store(false, .release);
            freed = .unset;
            on_dial = null;
        }

        fn usable(c: *Conn) bool {
            if (c.magic == alive) return true;
            used_freed.store(true, .release);
            return false;
        }

        pub fn dial(client: *Client, _: std.mem.Allocator, _: Names(Kind)) !*Conn {
            if (on_dial) |f| f();
            if (client.refuse) return error.ConnectionRefused;
            const c = try client.gpa.create(Conn);
            c.* = .{ .client = client, .index = client.dials.load(.acquire) };
            client.conn = c;
            _ = client.dials.fetchAdd(1, .acq_rel);
            return c;
        }

        pub fn send(c: *Conn, gpa: std.mem.Allocator, _: std.Io, on: bool, kind: Kind, name: []const u8) !void {
            if (!usable(c)) return error.Closed;
            try c.client.sent.print(gpa, "{c}{s}{s} ", .{ @as(u8, if (on) '+' else '-'), if (kind == .pattern) "p:" else "", name });
        }

        pub fn ping(c: *Conn) !void {
            if (!usable(c)) return error.Closed;
        }

        pub fn next(c: *Conn, _: std.mem.Allocator) !?Message(Kind) {
            if (c.index < 2) c.client.reading[c.index].set(c.client.io);
            try c.ended.wait(c.client.io);
            return null;
        }

        pub fn stop(c: *Conn) void {
            if (!usable(c)) return;
            c.ended.set(c.client.io);
        }

        pub fn close(c: *Conn, gpa: std.mem.Allocator) void {
            const io = c.client.io;
            c.magic = 0;
            gpa.destroy(c);
            freed.set(io);
        }
    };
}

/// A watch the hub can hold (never started), on a client nothing listens
/// for.
const TestWatch = struct {
    client: *pg_test.Client,
    w: *Watch,

    fn init(gpa: std.mem.Allocator, io: std.Io) !TestWatch {
        const client = try pg_test.Client.init(gpa, io, .{ .url = "postgres://u@127.0.0.1:1/db", .environ = .empty });
        errdefer client.deinit();
        const w = try Watch.init(gpa, io, .{ .postgres = .{ .client = client, .channels = &.{"a"} } }, .{});
        return .{ .client = client, .w = w };
    }

    fn deinit(self: TestWatch) void {
        self.w.deinit();
        self.client.deinit();
    }
};

test "watch hub: names added or removed while the connection opens are subscribed or unsubscribed once it is open (#216)" {
    if (comptime !features.postgres) return error.SkipZigTest;
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const F = Fake(null);
    const H = Hub(F);
    F.reset();
    defer F.reset();
    var client: F.Client = .{ .gpa = gpa, .io = io };
    defer client.sent.deinit(gpa);
    const h = try H.create(&client);
    defer h.destroy();
    const tw = try TestWatch.init(gpa, io);
    defer tw.deinit();
    try h.add(tw.w, &.{"a"}, .channel);
    defer h.remove(tw.w, &.{"b"}, .pattern);
    // While the reader dials with "a": "a" goes, the pattern "b" comes.
    const Dial = struct {
        var hub: *H = undefined;
        var w: *Watch = undefined;
        fn hook() void {
            F.on_dial = null;
            hub.add(w, &.{"b"}, .pattern) catch unreachable;
            hub.remove(w, &.{"a"}, .channel);
        }
    };
    Dial.hub = h;
    Dial.w = tw.w;
    F.on_dial = &Dial.hook;
    try h.ensureRunning();
    client.reading[0].waitUncancelable(io);
    try std.testing.expectEqualStrings("-a +p:b ", client.sent.items);
}

test "watch hub: the reader ends once no watch is left, and the next watch starts it again (#216)" {
    if (comptime !features.postgres) return error.SkipZigTest;
    const zio = @import("zio");
    const g = @import("../errors.zig").expectLog();
    defer g.deinit();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const F = Fake(null);
    const H = Hub(F);
    F.reset();
    defer F.reset();
    var client: F.Client = .{ .gpa = gpa, .io = io, .refuse = true };
    defer client.sent.deinit(gpa);
    const h = try H.create(&client);
    defer h.destroy();
    h.backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(1) };
    const tw = try TestWatch.init(gpa, io);
    defer tw.deinit();
    // Refused, so it retries, until the watch leaves.
    try h.add(tw.w, &.{"a"}, .channel);
    try h.ensureRunning();
    h.remove(tw.w, &.{"a"}, .channel);
    try h.group.await(io);
    try std.testing.expect(h.state == .idle);
    try std.testing.expectEqual(@as(u32, 0), client.dials.load(.acquire));
    // The next watch starts it again.
    client.refuse = false;
    try h.add(tw.w, &.{"a"}, .channel);
    defer h.remove(tw.w, &.{"a"}, .channel);
    try h.ensureRunning();
    client.reading[0].waitUncancelable(io);
    try std.testing.expect(h.state == .ready);
}

/// The #198 race: a send (or ping) has read the connection, then it is lost
/// and the reader retires it before the send uses it.
fn raceRetire(comptime ka: ?Keepalive, comptime by_verb: bool) !void {
    const zio = @import("zio");
    const g = @import("../errors.zig").expectLog();
    defer g.deinit();
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const F = Fake(ka);
    const H = Hub(F);
    F.reset();
    defer F.reset();
    var client: F.Client = .{ .gpa = gpa, .io = io };
    defer client.sent.deinit(gpa);
    const h = try H.create(&client);
    defer h.destroy();
    h.backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(1) };
    const tw = try TestWatch.init(gpa, io);
    defer tw.deinit();
    const Race = struct {
        var conn: ?*F.Conn = null;
        /// On the sender, between its read of the connection and its use:
        /// the connection is lost, and the sender goes on only once the
        /// reader freed it, or stopped it and waits for the sender.
        fn beforeSend(hub: *H) void {
            conn = hub.client.conn;
            F.stop(conn.?);
            F.freed.waitUncancelable(hub.io);
        }
        fn onRetire(hub: *H) void {
            F.freed.set(hub.io);
        }
    };
    H.test_before_send.store(&Race.beforeSend, .release);
    defer H.test_before_send.store(null, .release);
    H.test_on_retire.store(&Race.onRetire, .release);
    defer H.test_on_retire.store(null, .release);
    try h.add(tw.w, &.{"a"}, .channel);
    defer h.remove(tw.w, &.{ "a", "b" }, .channel);
    if (by_verb) {
        // The ping is off; the hook is armed for the LISTEN of "b".
        try h.ensureRunning();
        client.reading[0].waitUncancelable(io);
        try h.add(tw.w, &.{"b"}, .channel);
    } else {
        // The keep-alive's first ping, at once, meets the hook.
        try h.ensureRunning();
    }
    // The reader went on to a new connection.
    client.reading[1].waitUncancelable(io);
    try std.testing.expect(Race.conn != null);
    try std.testing.expect(!F.used_freed.load(.acquire));
}

test "watch hub: a LISTEN racing the reader's reconnect never uses the connection it frees (#198)" {
    if (comptime !features.postgres) return error.SkipZigTest;
    try raceRetire(null, true);
}

test "watch hub: a keep-alive ping racing the reader's reconnect never uses the connection it frees (#198)" {
    if (comptime !features.postgres) return error.SkipZigTest;
    try raceRetire(.{ .interval = .fromNanoseconds(0), .wait = .fromSeconds(3600) }, false);
}
