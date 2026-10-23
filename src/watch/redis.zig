//! Redis for `anole.watch`: pub/sub on one shared SUBSCRIBE connection per
//! client (channels and patterns counted per name), and streams read with
//! XREAD / XREADGROUP on a connection of their own (§4.3, §4.4).
//!
//! Pub/sub is at most once: a lost connection is a gap. A stream resumes
//! from the last entry ID it read, and says gap only when Redis reports
//! entries after that ID deleted (`max-deleted-entry-id`, Redis 7 and
//! Valkey 7.2).

const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const redis = @import("../redis/root.zig");
const db = @import("../db/root.zig");
const root = @import("root.zig");
const resilience = @import("../resilience/root.zig");

const Watch = root.Watch;
const Raw = root.Raw;
const log = std.log.scoped(.anole);
const builtin = @import("builtin");
/// A command as the client takes it.
const S = []const []const u8;

// ---------------------------------------------------------------------------
// Pub/sub

const Entry = struct {
    name: []u8,
    watches: std.ArrayList(*Watch) = .empty,
};

pub const PubSubHub = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *redis.Client,
    mutex: std.Io.Mutex = .init,
    channels: std.StringHashMapUnmanaged(*Entry) = .empty,
    patterns: std.StringHashMapUnmanaged(*Entry) = .empty,
    sub: ?*redis.Subscriber = null,
    connected: bool = false,
    write_mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,
    running: bool = false,
    stopping: std.atomic.Value(bool) = .init(false),
    reader_task: ?placement.Task = null,
    backoff: resilience.Backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(5) },

    pub fn create(client: *redis.Client) !*PubSubHub {
        const h = try client.gpa.create(PubSubHub);
        h.* = .{ .gpa = client.gpa, .io = client.io, .client = client };
        return h;
    }

    pub fn destroy(self: *PubSubHub) void {
        self.stopping.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        if (self.sub) |s| s.stop();
        if (self.reader_task) |t| placement.cancelTask(t);
        self.mutex.unlock(self.io);
        self.group.cancel(self.io);
        inline for (.{ &self.channels, &self.patterns }) |map| {
            var it = map.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.watches.deinit(self.gpa);
                self.gpa.free(e.value_ptr.*.name);
                self.gpa.destroy(e.value_ptr.*);
            }
            map.deinit(self.gpa);
        }
        self.gpa.destroy(self);
    }

    fn add(self: *PubSubHub, w: *Watch, names: []const []const u8, comptime patterns: bool) !void {
        for (names) |name| {
            var send = false;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const map = if (patterns) &self.patterns else &self.channels;
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
                    send = self.connected;
                }
                try entry.value_ptr.*.watches.append(self.gpa, w);
            }
            if (send) self.sendVerb(true, patterns, name);
        }
    }

    fn remove(self: *PubSubHub, w: *Watch, names: []const []const u8, comptime patterns: bool) void {
        for (names) |name| {
            var send = false;
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const map = if (patterns) &self.patterns else &self.channels;
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
                    send = self.connected;
                }
            }
            if (send) self.sendVerb(false, patterns, name);
        }
    }

    fn sendVerb(self: *PubSubHub, subscribe: bool, pattern: bool, name: []const u8) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        const s = self.sub orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena_state.allocator() };
        const one = [_][]const u8{name};
        const result = if (subscribe)
            (if (pattern) s.psubscribe(&ctx, one[0..]) else s.subscribe(&ctx, one[0..]))
        else
            (if (pattern) s.punsubscribe(&ctx, one[0..]) else s.unsubscribe(&ctx, one[0..]));
        result catch |err| {
            log.debug("redis watch: {s} {s} failed: {t}", .{ if (subscribe) "SUBSCRIBE" else "UNSUBSCRIBE", name, err });
            s.stop();
        };
    }

    fn ensureRunning(self: *PubSubHub) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.running) return;
        placement.concurrent(&self.group, self.io, .local, readerTask, .{self}) catch return error.ServiceUnavailable;
        self.running = true;
    }

    fn readerTask(self: *PubSubHub) std.Io.Cancelable!void {
        self.mutex.lockUncancelable(self.io);
        self.reader_task = placement.currentTask(self.io);
        self.mutex.unlock(self.io);
        var attempt: u32 = 0;
        var first = true;
        while (!self.stopping.load(.acquire)) {
            const sub = self.connect() catch |err| {
                if (err == error.Canceled) return error.Canceled;
                // Nothing to subscribe to (every watch left): idle.
                if (err == error.Nothing) {
                    self.mutex.lockUncancelable(self.io);
                    self.running = false;
                    self.mutex.unlock(self.io);
                    return;
                }
                attempt += 1;
                if (attempt == 1) {
                    log.warn("redis watch: cannot open the SUBSCRIBE connection ({t}); trying again", .{err});
                } else log.debug("redis watch: SUBSCRIBE connection attempt {d} failed: {t}", .{ attempt, err });
                self.statusAll(.reconnecting);
                try self.pause(attempt);
                continue;
            };
            attempt = 0;
            const lost = !first;
            first = false;
            self.mutex.lockUncancelable(self.io);
            self.sub = sub;
            self.connected = true;
            self.mutex.unlock(self.io);
            self.statusAll(.connected);
            if (lost) self.gapAll("the SUBSCRIBE connection was lost and opened again");
            log.info("redis watch: subscribed", .{});
            self.readLoop(sub);
            self.mutex.lockUncancelable(self.io);
            self.connected = false;
            self.sub = null;
            const idle = self.channels.count() == 0 and self.patterns.count() == 0;
            if (idle) self.running = false;
            self.mutex.unlock(self.io);
            sub.stop();
            sub.close();
            if (self.stopping.load(.acquire) or idle) return;
            log.warn("redis watch: the SUBSCRIBE connection was lost; opening it again", .{});
            self.statusAll(.reconnecting);
            attempt += 1;
            try self.pause(attempt);
        }
    }

    fn pause(self: *PubSubHub, attempt: u32) std.Io.Cancelable!void {
        var rnd: [8]u8 = undefined;
        self.io.random(&rnd);
        try self.io.sleep(self.backoff.delay(attempt, std.mem.readInt(u64, &rnd, .little)), .awake);
    }

    /// A subscriber with every channel and pattern registered so far.
    fn connect(self: *PubSubHub) !*redis.Subscriber {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var chans: std.ArrayList([]const u8) = .empty;
        var pats: std.ArrayList([]const u8) = .empty;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.channels.keyIterator();
            while (it.next()) |k| try chans.append(a, try a.dupe(u8, k.*));
            var pit = self.patterns.keyIterator();
            while (pit.next()) |k| try pats.append(a, try a.dupe(u8, k.*));
        }
        if (chans.items.len == 0 and pats.items.len == 0) return error.Nothing;
        var ctx: db.Ctx = .{ .io = self.io, .arena = a };
        const sub = if (chans.items.len > 0) blk: {
            const s = try self.client.subscribe(&ctx, chans.items);
            errdefer s.close();
            if (pats.items.len > 0) try s.psubscribe(&ctx, pats.items);
            break :blk s;
        } else try self.client.psubscribe(&ctx, pats.items);
        return sub;
    }

    fn readLoop(self: *PubSubHub, sub: *redis.Subscriber) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var ctx: db.Ctx = .{ .io = self.io, .arena = arena_state.allocator() };
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const msg = sub.next(&ctx) catch |err| {
                if (!self.stopping.load(.acquire)) log.debug("redis watch: read failed: {t}", .{err});
                return;
            } orelse return;
            self.dispatch(msg);
        }
    }

    fn dispatch(self: *PubSubHub, msg: redis.Message) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const e = (if (msg.pattern) |p| self.patterns.get(p) else self.channels.get(msg.channel)) orelse return;
        for (e.watches.items) |w| {
            w.onHubEvent(.{
                .op = .message,
                .op_name = "message",
                .channel = msg.channel,
                .pattern = msg.pattern,
                .data = msg.payload,
            });
        }
    }

    fn statusAll(self: *PubSubHub, s: root.Status) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        inline for (.{ &self.channels, &self.patterns }) |map| {
            var it = map.valueIterator();
            while (it.next()) |e| for (e.*.watches.items) |w| w.setStatus(s);
        }
    }

    fn gapAll(self: *PubSubHub, detail: []const u8) void {
        var seen: std.ArrayList(*Watch) = .empty;
        defer seen.deinit(self.gpa);
        self.mutex.lockUncancelable(self.io);
        inline for (.{ &self.channels, &self.patterns }) |map| {
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
        self.mutex.unlock(self.io);
        for (seen.items) |w| w.gapped(detail);
    }
};

pub fn register(w: *Watch) !void {
    const r = w.source.redis;
    const hub = try r.client._pubsubHub();
    try hub.add(w, r.channels, false);
    try hub.add(w, r.patterns, true);
    try hub.ensureRunning();
}

pub fn unregister(w: *Watch) void {
    const r = w.source.redis;
    const hub = r.client.pubsub_hub orelse return;
    hub.remove(w, r.channels, false);
    hub.remove(w, r.patterns, true);
}

// ---------------------------------------------------------------------------
// Streams

/// One stream entry as read.
pub const StreamEntry = struct {
    key: []const u8,
    id: []const u8,
    /// Field name, value; in order.
    fields: []const [2][]const u8,
};

/// The entries of an XREAD / XREADGROUP reply, in `arena`: RESP2's array of
/// `[key, [[id, [field, value, ...]], ...]]`, or RESP3's map of key to
/// entries; a nil reply (the block ended) is no entries. Anything that does
/// not fit is skipped, not an error: the reply's shape is the server's.
pub fn decodeEntries(arena: std.mem.Allocator, reply: redis.Reply, out: *std.ArrayList(StreamEntry)) error{OutOfMemory}!void {
    switch (reply) {
        .array => |streams| for (streams) |s| {
            const pair = switch (s) {
                .array => |p| p,
                else => continue,
            };
            if (pair.len != 2) continue;
            try decodeStream(arena, pair[0], pair[1], out);
        },
        .map => |items| {
            var i: usize = 0;
            while (i + 1 < items.len) : (i += 2) try decodeStream(arena, items[i], items[i + 1], out);
        },
        else => {},
    }
}

fn decodeStream(arena: std.mem.Allocator, key_r: redis.Reply, entries_r: redis.Reply, out: *std.ArrayList(StreamEntry)) error{OutOfMemory}!void {
    const key = key_r.text() orelse return;
    const entries = switch (entries_r) {
        .array => |e| e,
        else => return,
    };
    for (entries) |e| {
        const parts = switch (e) {
            .array => |p| p,
            else => continue,
        };
        if (parts.len != 2) continue;
        const id = parts[0].text() orelse continue;
        // A deleted entry read from the pending list has nil fields.
        const flat: []const redis.Reply = switch (parts[1]) {
            .array => |f| f,
            .map => |f| f,
            else => &.{},
        };
        const fields = try arena.alloc([2][]const u8, flat.len / 2);
        var n: usize = 0;
        var i: usize = 0;
        while (i + 1 < flat.len) : (i += 2) {
            const name = flat[i].text() orelse continue;
            const value = flat[i + 1].text() orelse continue;
            fields[n] = .{ name, value };
            n += 1;
        }
        try out.append(arena, .{ .key = key, .id = id, .fields = fields[0..n] });
    }
}

/// The entry's fields as a JSON object of strings; null when a name or a
/// value is not UTF-8 (the fields stay in `Event.fields`).
pub fn fieldsJson(arena: std.mem.Allocator, fields: []const [2][]const u8) error{OutOfMemory}!?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    for (fields, 0..) |f, i| {
        if (!std.unicode.utf8ValidateSlice(f[0]) or !std.unicode.utf8ValidateSlice(f[1])) return null;
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        std.json.Stringify.value(f[0], .{}, w) catch return error.OutOfMemory;
        w.writeByte(':') catch return error.OutOfMemory;
        std.json.Stringify.value(f[1], .{}, w) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return aw.written();
}

/// `a > b` for entry IDs `ms-seq` (a missing `-seq` is 0); an ID that is not
/// numbers compares as 0.
pub fn idGreater(a: []const u8, b: []const u8) bool {
    const pa = parseId(a);
    const pb = parseId(b);
    if (pa[0] != pb[0]) return pa[0] > pb[0];
    return pa[1] > pb[1];
}

fn parseId(id: []const u8) [2]u64 {
    const dash = std.mem.indexOfScalar(u8, id, '-');
    const ms = std.fmt.parseInt(u64, if (dash) |d| id[0..d] else id, 10) catch 0;
    const seq = if (dash) |d| (std.fmt.parseInt(u64, id[d + 1 ..], 10) catch 0) else 0;
    return .{ ms, seq };
}

/// Per watch: the task that reads the stream.
const StreamReader = struct {
    w: *Watch,
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: root.RedisStream,
    /// The last entry ID read per key, owned; position = joined with ','.
    last: [][]u8,
    consumer: []u8 = &.{},
    /// XACKs for `Event.ack()`, drained by the reader.
    mutex: std.Io.Mutex = .init,
    acks: std.ArrayList(PendingAck) = .empty,
    /// The first read of a group: this consumer's pending entries.
    pending_phase: bool = true,

    const PendingAck = struct { key: []u8, id: []u8 };

    fn destroy(self: *StreamReader) void {
        for (self.last) |l| self.gpa.free(l);
        self.gpa.free(self.last);
        if (self.consumer.len > 0) self.gpa.free(self.consumer);
        for (self.acks.items) |a| {
            self.gpa.free(a.key);
            self.gpa.free(a.id);
        }
        self.acks.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn ackCall(ctx: *anyopaque, key: []const u8, id: []const u8) error{ OutOfMemory, Unsupported }!void {
        const self: *StreamReader = @ptrCast(@alignCast(ctx));
        const k = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(k);
        const i = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(i);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.acks.append(self.gpa, .{ .key = k, .id = i });
    }

    fn position(self: *StreamReader, arena: std.mem.Allocator) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        for (self.last, 0..) |l, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.writeAll(l);
        }
        return aw.written();
    }

    fn setLast(self: *StreamReader, key: []const u8, id: []const u8) void {
        for (self.cfg.keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            const copy = self.gpa.dupe(u8, id) catch return;
            self.gpa.free(self.last[i]);
            self.last[i] = copy;
            return;
        };
    }
};

pub fn startStream(w: *Watch) !void {
    const cfg = w.source.redis_stream;
    const gpa = w.gpa;
    const r = try gpa.create(StreamReader);
    errdefer gpa.destroy(r);
    r.* = .{ .w = w, .gpa = gpa, .io = w.io, .cfg = cfg, .last = try gpa.alloc([]u8, cfg.keys.len) };
    var made: usize = 0;
    errdefer {
        for (r.last[0..made]) |l| gpa.free(l);
        gpa.free(r.last);
    }
    for (cfg.keys, 0..) |_, i| {
        const initial: []const u8 = switch (cfg.start) {
            .after => |ids| ids[i],
            // Resolved at the first connect for `.new`.
            .new => "",
            .all => "0-0",
        };
        r.last[i] = try gpa.dupe(u8, initial);
        made += 1;
    }
    if (cfg.group) |g| {
        if (g.ack == .manual) w.ack_hook = .{ .ctx = r, .call = StreamReader.ackCall };
    }
    try placement.concurrent(&w.group, w.io, .local, streamTask, .{r});
}

fn streamTask(r: *StreamReader) std.Io.Cancelable!void {
    defer r.destroy();
    const w = r.w;
    w.reader_task = placement.currentTask(r.io);
    var attempt: u32 = 0;
    var first = true;
    while (!w.isStopped()) {
        const outcome = streamSession(r, first) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            if (w.isStopped()) return;
            attempt += 1;
            if (attempt == 1) {
                log.warn("watch \"{s}\": the Redis stream connection failed ({t}); trying again", .{ w.name, err });
            } else log.debug("watch \"{s}\": stream attempt {d} failed: {t}", .{ w.name, attempt, err });
            w.setStatus(.reconnecting);
            var rnd: [8]u8 = undefined;
            r.io.random(&rnd);
            try r.io.sleep(w.reconnect.delay(attempt, std.mem.readInt(u64, &rnd, .little)), .awake);
            first = false;
            continue;
        };
        _ = outcome;
        return;
    }
}

/// One connection's life: returns when the watch stops; an error means the
/// connection broke (or a start step failed) and the caller reconnects.
fn streamSession(r: *StreamReader, first: bool) !void {
    const w = r.w;
    const cfg = r.cfg;
    var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
    defer arena_state.deinit();
    var ctx: db.Ctx = .{ .io = r.io, .arena = arena_state.allocator() };
    var conn = cfg.client.acquire(&ctx) catch |err| return err;
    defer conn.release();

    // Where each key starts: a `new` watch begins after the newest entry.
    for (cfg.keys, 0..) |key, i| {
        if (r.last[i].len == 0) {
            _ = arena_state.reset(.retain_capacity);
            const reply = try conn.command(&ctx, @as(S, &[_][]const u8{ "XREVRANGE", key, "+", "-", "COUNT", "1" }));
            var id: []const u8 = "0-0";
            if (reply == .array and reply.array.len > 0) {
                if (reply.array[0] == .array and reply.array[0].array.len > 0) id = reply.array[0].array[0].text() orelse "0-0";
            }
            const copy = try r.gpa.dupe(u8, id);
            r.gpa.free(r.last[i]);
            r.last[i] = copy;
        }
    }
    // A group: created when missing, and this consumer's pending entries
    // are read first.
    if (cfg.group) |g| {
        if (g.create) for (cfg.keys) |key| {
            _ = arena_state.reset(.retain_capacity);
            const start: []const u8 = if (cfg.start == .all) "0" else "$";
            _ = conn.command(&ctx, @as(S, &[_][]const u8{ "XGROUP", "CREATE", key, g.name, start, "MKSTREAM" })) catch |err| {
                const busy = if (db.lastError(&ctx)) |d| std.mem.indexOf(u8, d.message, "BUSYGROUP") != null else false;
                if (!busy) return err;
            };
        };
        if (r.consumer.len == 0) {
            var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const host = if (builtin.os.tag == .windows) "anole" else (std.posix.gethostname(&host_buf) catch "anole");
            const pid: i64 = if (builtin.os.tag == .windows) 0 else std.c.getpid();
            r.consumer = if (g.consumer) |c| try r.gpa.dupe(u8, c) else try std.fmt.allocPrint(r.gpa, "{s}-{d}", .{ host, pid });
        }
        r.pending_phase = true;
    }
    // Entries the stream deleted after our position are lost.
    if (!first or cfg.start == .after) try checkDeleted(r, &conn, &ctx, &arena_state);

    w.setStatus(.connected);
    if (!first) w.gapped("the stream connection was lost and opened again");
    log.info("watch \"{s}\": reading the stream", .{w.name});
    return readLoop(r, &conn, &ctx, &arena_state);
}

/// XINFO STREAM `max-deleted-entry-id` against the position.
fn checkDeleted(r: *StreamReader, conn: *redis.Conn, ctx: *db.Ctx, arena_state: *std.heap.ArenaAllocator) !void {
    for (r.cfg.keys, 0..) |key, i| {
        _ = arena_state.reset(.retain_capacity);
        const reply = conn.command(ctx, @as(S, &[_][]const u8{ "XINFO", "STREAM", key })) catch continue;
        const items: []const redis.Reply = switch (reply) {
            .array => |a| a,
            .map => |m| m,
            else => continue,
        };
        var k: usize = 0;
        while (k + 1 < items.len) : (k += 2) {
            const name = items[k].text() orelse continue;
            if (!std.mem.eql(u8, name, "max-deleted-entry-id")) continue;
            const id = items[k + 1].text() orelse continue;
            if (idGreater(id, r.last[i])) {
                var buf: [160]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "entries of \"{s}\" after {s} were deleted before they were read", .{ key, r.last[i] }) catch "entries were deleted";
                r.w.gapped(detail);
            }
        }
    }
}

fn readLoop(r: *StreamReader, conn: *redis.Conn, ctx: *db.Ctx, arena_state: *std.heap.ArenaAllocator) !void {
    const w = r.w;
    const cfg = r.cfg;
    var args: std.ArrayList([]const u8) = .empty;
    while (!w.isStopped()) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        try flushAcks(r, conn, ctx);
        args.clearRetainingCapacity();
        var count_buf: [16]u8 = undefined;
        var block_buf: [24]u8 = undefined;
        const count_s = try std.fmt.bufPrint(&count_buf, "{d}", .{cfg.count});
        const block_s = try std.fmt.bufPrint(&block_buf, "{d}", .{@max(1, cfg.block.toMilliseconds())});
        if (cfg.group) |g| {
            try args.appendSlice(a, &.{ "XREADGROUP", "GROUP", g.name, r.consumer, "COUNT", count_s });
            // The pending phase does not block: it ends when nothing is left.
            if (!r.pending_phase) try args.appendSlice(a, &.{ "BLOCK", block_s });
            try args.append(a, "STREAMS");
            try args.appendSlice(a, cfg.keys);
            for (cfg.keys) |_| try args.append(a, if (r.pending_phase) "0" else ">");
        } else {
            try args.appendSlice(a, &.{ "XREAD", "COUNT", count_s, "BLOCK", block_s, "STREAMS" });
            try args.appendSlice(a, cfg.keys);
            for (r.last) |l| try args.append(a, l);
        }
        const reply = try conn.command(ctx, args.items);
        var entries: std.ArrayList(StreamEntry) = .empty;
        try decodeEntries(a, reply, &entries);
        if (entries.items.len == 0) {
            if (r.pending_phase) r.pending_phase = false;
            continue;
        }
        var warned = false;
        for (entries.items) |e| {
            if (w.isStopped()) return;
            const data = (try fieldsJson(a, e.fields)) orelse blk: {
                if (!warned) {
                    warned = true;
                    log.warn("watch \"{s}\": a stream entry has fields that are not UTF-8; its data is {{}} and only Event.fields carries them", .{w.name});
                }
                break :blk @as([]const u8, "{}");
            };
            const outcome = w.deliver(.{
                .op = .entry,
                .op_name = "entry",
                .channel = e.key,
                .data = data,
                .position = e.id,
                .fields = e.fields,
            });
            r.setLast(e.key, e.id);
            w.setPosition(try r.position(a));
            if (cfg.group) |g| {
                if (g.ack == .auto and outcome == .ok) {
                    _ = conn.command(ctx, @as(S, &[_][]const u8{ "XACK", e.key, g.name, e.id })) catch {};
                }
            }
        }
        // A pending read that returned entries goes on until empty.
    }
}

fn flushAcks(r: *StreamReader, conn: *redis.Conn, ctx: *db.Ctx) !void {
    const g = r.cfg.group orelse return;
    r.mutex.lockUncancelable(r.io);
    var taken = r.acks;
    r.acks = .empty;
    r.mutex.unlock(r.io);
    defer {
        for (taken.items) |a| {
            r.gpa.free(a.key);
            r.gpa.free(a.id);
        }
        taken.deinit(r.gpa);
    }
    for (taken.items) |a| {
        _ = conn.command(ctx, @as(S, &[_][]const u8{ "XACK", a.key, g.name, a.id })) catch |err| {
            if (err == error.Canceled) return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Tests

test "decodeEntries: RESP2 arrays and RESP3 maps, nil fields skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const fields1 = [_]redis.Reply{ .{ .string = "a" }, .{ .string = "1" }, .{ .string = "b" }, .{ .string = "2" } };
    const e1 = [_]redis.Reply{ .{ .string = "1-0" }, .{ .array = @constCast(&fields1) } };
    const e2 = [_]redis.Reply{ .{ .string = "2-0" }, .nil };
    const entries = [_]redis.Reply{ .{ .array = @constCast(&e1) }, .{ .array = @constCast(&e2) } };
    const stream = [_]redis.Reply{ .{ .string = "k" }, .{ .array = @constCast(&entries) } };
    const resp2 = [_]redis.Reply{.{ .array = @constCast(&stream) }};
    var out: std.ArrayList(StreamEntry) = .empty;
    try decodeEntries(a, .{ .array = @constCast(&resp2) }, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("k", out.items[0].key);
    try std.testing.expectEqualStrings("1-0", out.items[0].id);
    try std.testing.expectEqual(@as(usize, 2), out.items[0].fields.len);
    try std.testing.expectEqualStrings("b", out.items[0].fields[1][0]);
    try std.testing.expectEqual(@as(usize, 0), out.items[1].fields.len);
    // RESP3.
    const map = [_]redis.Reply{ .{ .string = "k" }, .{ .array = @constCast(&entries) } };
    var out3: std.ArrayList(StreamEntry) = .empty;
    try decodeEntries(a, .{ .map = @constCast(&map) }, &out3);
    try std.testing.expectEqual(@as(usize, 2), out3.items.len);
    // The block ended.
    var none: std.ArrayList(StreamEntry) = .empty;
    try decodeEntries(a, .nil, &none);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}

test "fieldsJson: strings escaped, non-UTF-8 gives null" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = [_][2][]const u8{ .{ "name", "Ada \"A\"" }, .{ "n", "1" } };
    try std.testing.expectEqualStrings("{\"name\":\"Ada \\\"A\\\"\",\"n\":\"1\"}", (try fieldsJson(a, &ok)).?);
    const bad = [_][2][]const u8{.{ "k", "\xff\xfe" }};
    try std.testing.expect((try fieldsJson(a, &bad)) == null);
    try std.testing.expectEqualStrings("{}", (try fieldsJson(a, &.{})).?);
}

test "idGreater compares ms then sequence" {
    try std.testing.expect(idGreater("2-0", "1-9"));
    try std.testing.expect(idGreater("1-2", "1-1"));
    try std.testing.expect(!idGreater("1-1", "1-1"));
    try std.testing.expect(idGreater("5", "4-99"));
    try std.testing.expect(!idGreater("x", "1-0"));
}

test "fuzz: the stream reply decoder on arbitrary reply trees" {
    try @import("../fuzz.zig").bytes(fuzzDecode, &.{ "\x01\x02k\x01\x01\x021-0", "\x00", "\x02\x02\x02\x02\x02\x02\x02", "\x03\x03\x03\x03" });
}

fn fuzzDecode(input: []const u8) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var pos: usize = 0;
    const reply = try buildReply(a, input, &pos, 0);
    var out: std.ArrayList(StreamEntry) = .empty;
    try decodeEntries(a, reply, &out);
    for (out.items) |e| _ = try fieldsJson(a, e.fields);
}

/// A reply tree from bytes: the first byte of each node picks its kind.
fn buildReply(a: std.mem.Allocator, input: []const u8, pos: *usize, depth: u32) !redis.Reply {
    if (pos.* >= input.len or depth > 6) return .nil;
    const tag = input[pos.*] % 6;
    pos.* += 1;
    switch (tag) {
        0 => return .nil,
        1 => {
            const len = if (pos.* < input.len) input[pos.*] % 8 else 0;
            pos.* += 1;
            const end = @min(input.len, pos.* + len);
            const s = input[pos.*..end];
            pos.* = end;
            return .{ .string = s };
        },
        2, 3 => {
            const n = if (pos.* < input.len) input[pos.*] % 5 else 0;
            pos.* += 1;
            const items = try a.alloc(redis.Reply, n);
            for (items) |*it| it.* = try buildReply(a, input, pos, depth + 1);
            return if (tag == 2) .{ .array = items } else .{ .map = items };
        },
        4 => return .{ .int = 7 },
        else => return .{ .status = "OK" },
    }
}
