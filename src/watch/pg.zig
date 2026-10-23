//! PostgreSQL LISTEN/NOTIFY for `anole.watch`: one LISTEN connection per
//! `pg.Client`, shared by every watch on it, with LISTEN and UNLISTEN
//! counted per channel (W2). Notifications are at most once: a lost
//! connection is a gap, and the connection is opened again with the
//! backoff and every channel listened to once more (§4.2).

const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const pg_root = @import("../pg/root.zig");
const driver = pg_root.driver;
const root = @import("root.zig");
const resilience = @import("../resilience/root.zig");

const Watch = root.Watch;
const log = std.log.scoped(.anole);

/// How often the hub asks the server whether the connection is alive.
const keepalive_interval: std.Io.Duration = .fromSeconds(30);
/// How long the answer may take.
const keepalive_wait: std.Io.Duration = .fromSeconds(10);

const Channel = struct {
    name: []u8,
    watches: std.ArrayList(*Watch) = .empty,
};

pub const NotifyHub = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *pg_root.Client,
    /// Over `channels`, `connected`, the listener pointer and the watch lists.
    mutex: std.Io.Mutex = .init,
    channels: std.StringHashMapUnmanaged(*Channel) = .empty,
    listener: ?*driver.Listener = null,
    connected: bool = false,
    /// Serializes the writes (LISTEN, UNLISTEN, ping) on the connection.
    write_mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    running: bool = false,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Awake-clock milliseconds of the last ReadyForQuery, and of the last
    /// ping sent.
    last_ready_ms: std.atomic.Value(i64) = .init(0),
    backoff: resilience.Backoff,
    reader_task: ?placement.Task = null,

    pub fn create(client: *pg_root.Client) !*NotifyHub {
        const h = try client.gpa.create(NotifyHub);
        h.* = .{ .gpa = client.gpa, .io = client.io, .client = client, .backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(5) } };
        return h;
    }

    /// Stops the tasks and frees the hub (the client's `deinit`).
    pub fn destroy(self: *NotifyHub) void {
        self.stopping.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        if (self.listener) |l| l.stop() catch {};
        if (self.reader_task) |t| placement.cancelTask(t);
        self.mutex.unlock(self.io);
        self.group.cancel(self.io);
        if (self.listener) |l| {
            l.deinit();
            self.gpa.destroy(l);
        }
        var it = self.channels.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.watches.deinit(self.gpa);
            self.gpa.free(e.value_ptr.*.name);
            self.gpa.destroy(e.value_ptr.*);
        }
        self.channels.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn nowMs(self: *NotifyHub) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    /// Adds `w` to each of its channels, LISTENing to the new ones.
    pub fn add(self: *NotifyHub, w: *Watch, names: []const []const u8) !void {
        for (names) |name| {
            var send = false;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const entry = try self.channels.getOrPut(self.gpa, name);
                if (!entry.found_existing) {
                    const ch = self.gpa.create(Channel) catch |err| {
                        self.channels.removeByPtr(entry.key_ptr);
                        return err;
                    };
                    ch.* = .{ .name = self.gpa.dupe(u8, name) catch |err| {
                        self.gpa.destroy(ch);
                        self.channels.removeByPtr(entry.key_ptr);
                        return err;
                    } };
                    entry.key_ptr.* = ch.name;
                    entry.value_ptr.* = ch;
                    send = self.connected;
                }
                try entry.value_ptr.*.watches.append(self.gpa, w);
            }
            if (send) self.sendVerb(true, name);
        }
        try self.ensureRunning();
    }

    /// Takes `w` out of each channel, UNLISTENing to those left with none.
    pub fn remove(self: *NotifyHub, w: *Watch, names: []const []const u8) void {
        for (names) |name| {
            var send = false;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const ch = self.channels.get(name) orelse continue;
                for (ch.watches.items, 0..) |x, i| if (x == w) {
                    _ = ch.watches.swapRemove(i);
                    break;
                };
                if (ch.watches.items.len == 0) {
                    _ = self.channels.remove(name);
                    ch.watches.deinit(self.gpa);
                    self.gpa.free(ch.name);
                    self.gpa.destroy(ch);
                    send = self.connected;
                }
            }
            if (send) self.sendVerb(false, name);
        }
    }

    fn sendVerb(self: *NotifyHub, listen: bool, name: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        const l = self.listener orelse return;
        (if (listen) l.sendListen(name) else l.sendUnlisten(name)) catch |err| {
            log.debug("postgres watch: {s} {s} failed: {t}", .{ if (listen) "LISTEN" else "UNLISTEN", name, err });
            // The reader sees the broken connection and reconnects.
            l.stop() catch {};
        };
    }

    fn ensureRunning(self: *NotifyHub) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running) return;
        placement.concurrent(&self.group, self.io, .local, readerTask, .{self}) catch return error.ServiceUnavailable;
        self.running = true;
    }

    /// The connection's task: connects, listens, reads, and again after a
    /// failure.
    fn readerTask(self: *NotifyHub) std.Io.Cancelable!void {
        self.mutex.lockUncancelable(self.io);
        self.reader_task = placement.currentTask(self.io);
        self.mutex.unlock(self.io);
        var attempt: u32 = 0;
        var first = true;
        while (!self.stopping.load(.acquire)) {
            const l = self.connect() catch |err| {
                if (err == error.Canceled) return error.Canceled;
                attempt += 1;
                if (attempt == 1) {
                    log.warn("postgres watch: cannot open the LISTEN connection ({t}); trying again", .{err});
                } else log.debug("postgres watch: LISTEN connection attempt {d} failed: {t}", .{ attempt, err });
                self.statusAll(.reconnecting);
                try self.pause(attempt);
                continue;
            };
            attempt = 0;
            const lost = !first;
            first = false;
            // The channels listened to, and connected for the watches.
            {
                self.mutex.lockUncancelable(self.io);
                self.listener = l;
                self.connected = true;
                var names: std.ArrayList([]u8) = .empty;
                var it = self.channels.keyIterator();
                while (it.next()) |k| {
                    const copy = self.gpa.dupe(u8, k.*) catch continue;
                    names.append(self.gpa, copy) catch self.gpa.free(copy);
                }
                self.mutex.unlock(self.io);
                for (names.items) |n| {
                    self.sendVerb(true, n);
                    self.gpa.free(n);
                }
                names.deinit(self.gpa);
            }
            self.last_ready_ms.store(self.nowMs(), .release);
            self.statusAll(.connected);
            if (lost) self.gapAll("the LISTEN connection was lost and opened again");
            log.info("postgres watch: listening", .{});
            placement.concurrent(&self.group, self.io, .local, keepaliveTask, .{ self, l }) catch {};
            self.readLoop(l);
            // Gone: close it, tell the watches, try again.
            self.mutex.lockUncancelable(self.io);
            self.connected = false;
            self.listener = null;
            self.mutex.unlock(self.io);
            l.stop() catch {};
            l.deinit();
            self.gpa.destroy(l);
            if (self.stopping.load(.acquire)) return;
            log.warn("postgres watch: the LISTEN connection was lost; opening it again", .{});
            self.statusAll(.reconnecting);
            attempt += 1;
            try self.pause(attempt);
        }
    }

    fn pause(self: *NotifyHub, attempt: u32) std.Io.Cancelable!void {
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        const d = self.backoff.delay(attempt, std.mem.readInt(u64, &rnd, .little));
        try self.io.sleep(d, .awake);
    }

    fn connect(self: *NotifyHub) !*driver.Listener {
        const l = try self.gpa.create(driver.Listener);
        errdefer self.gpa.destroy(l);
        l.* = try self.client.listener();
        return l;
    }

    fn readLoop(self: *NotifyHub, l: *driver.Listener) void {
        while (true) {
            const ev = l.nextEvent() catch |err| {
                if (!self.stopping.load(.acquire)) log.debug("postgres watch: read failed: {t}", .{err});
                return;
            };
            switch (ev) {
                .ready => self.last_ready_ms.store(self.nowMs(), .release),
                .notification => |n| self.dispatch(n.channel, n.payload, n.process_id),
            }
        }
    }

    /// Hands a notification to the watches of its channel, in arrival order
    /// (which is commit order). Holds the hub's lock: a watch's `onHubEvent`
    /// never waits.
    fn dispatch(self: *NotifyHub, channel: []const u8, payload: []const u8, pid: u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const ch = self.channels.get(channel) orelse return;
        for (ch.watches.items) |w| {
            w.onHubEvent(.{
                .op = .message,
                .op_name = "message",
                .channel = channel,
                .data = payload,
                .pg_pid = @bitCast(pid),
            });
        }
    }

    fn statusAll(self: *NotifyHub, s: root.Status) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.channels.valueIterator();
        while (it.next()) |ch| for (ch.*.watches.items) |w| w.setStatus(s);
    }

    fn gapAll(self: *NotifyHub, detail: []const u8) void {
        // Each watch once, even when it listens on several channels.
        var seen: std.ArrayList(*Watch) = .empty;
        defer seen.deinit(self.gpa);
        self.mutex.lockUncancelable(self.io);
        var it = self.channels.valueIterator();
        while (it.next()) |ch| for (ch.*.watches.items) |w| {
            var dup = false;
            for (seen.items) |s| if (s == w) {
                dup = true;
                break;
            };
            if (!dup) seen.append(self.gpa, w) catch {};
        };
        self.mutex.unlock(self.io);
        for (seen.items) |w| w.gapped(detail);
    }

    /// Every 30 s a ping; no answer in 10 s means a dead connection, which
    /// `stop` turns into a read error for the reader.
    fn keepaliveTask(self: *NotifyHub, l: *driver.Listener) std.Io.Cancelable!void {
        while (true) {
            try self.io.sleep(keepalive_interval, .awake);
            if (self.stopping.load(.acquire)) return;
            self.mutex.lockUncancelable(self.io);
            const current = self.listener;
            self.mutex.unlock(self.io);
            if (current != l) return;
            const before = self.last_ready_ms.load(.acquire);
            {
                self.write_mutex.lockUncancelable(self.io);
                defer self.write_mutex.unlock(self.io);
                l.sendPing() catch {
                    l.stop() catch {};
                    return;
                };
            }
            try self.io.sleep(keepalive_wait, .awake);
            self.mutex.lockUncancelable(self.io);
            const still = self.listener == l;
            self.mutex.unlock(self.io);
            if (!still) return;
            if (self.last_ready_ms.load(.acquire) == before) {
                log.warn("postgres watch: the server did not answer a ping; closing the LISTEN connection", .{});
                l.stop() catch {};
                return;
            }
        }
    }
};

/// The hub of `w`'s client, made on first use.
fn hubOf(w: *Watch) !*NotifyHub {
    return w.source.postgres.client._notifyHub();
}

pub fn register(w: *Watch) !void {
    const hub = try hubOf(w);
    try hub.add(w, w.source.postgres.channels);
}

pub fn unregister(w: *Watch) void {
    const hub = w.source.postgres.client.notify_hub orelse return;
    hub.remove(w, w.source.postgres.channels);
}
