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
const hubs = @import("hub.zig");

const Watch = root.Watch;
const Raw = root.Raw;
const log = @import("../errors.zig").log;
const builtin = @import("builtin");
/// A command as the client takes it.
const S = []const []const u8;

// ---------------------------------------------------------------------------
// Pub/sub

/// (P)SUBSCRIBE and (P)UNSUBSCRIBE on a `redis.Subscriber`.
const Transport = struct {
    pub const Client = redis.Client;
    pub const Conn = redis.Subscriber;
    pub const Kind = enum { channel, pattern };
    pub const log_name = "redis watch";
    pub const verb = "SUBSCRIBE";
    pub const ready_text = "subscribed";
    pub const keepalive: ?hubs.Keepalive = null;

    pub fn dial(client: *Client, arena: std.mem.Allocator, names: hubs.Names(Kind)) !*Conn {
        var ctx: db.Ctx = .{ .io = client.io, .arena = arena };
        const chans = names.get(.channel);
        const pats = names.get(.pattern);
        if (chans.len == 0) return client.psubscribe(&ctx, pats);
        const s = try client.subscribe(&ctx, chans);
        errdefer s.close();
        if (pats.len > 0) try s.psubscribe(&ctx, pats);
        return s;
    }

    pub fn send(s: *Conn, gpa: std.mem.Allocator, io: std.Io, on: bool, kind: Kind, name: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        var ctx: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
        const one = [_][]const u8{name};
        return switch (kind) {
            .channel => if (on) s.subscribe(&ctx, one[0..]) else s.unsubscribe(&ctx, one[0..]),
            .pattern => if (on) s.psubscribe(&ctx, one[0..]) else s.punsubscribe(&ctx, one[0..]),
        };
    }

    /// Null once stopped or subscribed to nothing.
    pub fn next(s: *Conn, arena: std.mem.Allocator) !?hubs.Message(Kind) {
        var ctx: db.Ctx = .{ .io = s.io, .arena = arena };
        const msg = (try s.next(&ctx)) orelse return null;
        return .{ .message = .{
            .kind = if (msg.pattern != null) .pattern else .channel,
            .name = msg.pattern orelse msg.channel,
            .raw = .{ .op = .message, .op_name = "message", .channel = msg.channel, .pattern = msg.pattern, .data = msg.payload },
        } };
    }

    pub fn stop(s: *Conn) void {
        s.stop();
    }

    pub fn close(s: *Conn, _: std.mem.Allocator) void {
        s.close();
    }
};

pub const PubSubHub = hubs.Hub(Transport);

/// Tests: the hub's hooks (`hub.Hub.test_on_gap`, `test_before_status`).
pub const test_on_gap = &PubSubHub.test_on_gap;
pub const test_before_status = &PubSubHub.test_before_status;

pub fn register(w: *Watch) !void {
    const r = w.source.redis;
    const h = try r.client._pubsubHub();
    try h.add(w, r.channels, .channel);
    try h.add(w, r.patterns, .pattern);
    try h.ensureRunning();
}

pub fn unregister(w: *Watch) void {
    const r = w.source.redis;
    const h = r.client.pubsub_hub orelse return;
    h.remove(w, r.channels, .channel);
    h.remove(w, r.patterns, .pattern);
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
    /// The pending phase reads after these IDs (one per key, owned): the
    /// entries still pending are returned for any ID before them, so
    /// without moving on the same ones would come back forever.
    pend: [][]u8 = &.{},

    const PendingAck = struct { key: []u8, id: []u8 };

    fn destroy(self: *StreamReader) void {
        for (self.last) |l| self.gpa.free(l);
        self.gpa.free(self.last);
        if (self.consumer.len > 0) self.gpa.free(self.consumer);
        self.freePend();
        for (self.acks.items) |a| {
            self.gpa.free(a.key);
            self.gpa.free(a.id);
        }
        self.acks.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freePend(self: *StreamReader) void {
        for (self.pend) |p| self.gpa.free(p);
        if (self.pend.len > 0) self.gpa.free(self.pend);
        self.pend = &.{};
    }

    /// The pending phase starts over: after "0" for every key.
    fn restartPending(self: *StreamReader) !void {
        self.freePend();
        const list = try self.gpa.alloc([]u8, self.cfg.keys.len);
        var made: usize = 0;
        errdefer {
            for (list[0..made]) |p| self.gpa.free(p);
            self.gpa.free(list);
        }
        for (list) |*p| {
            p.* = try self.gpa.dupe(u8, "0");
            made += 1;
        }
        self.pend = list;
        self.pending_phase = true;
    }

    fn setPend(self: *StreamReader, key: []const u8, id: []const u8) void {
        for (self.cfg.keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            const copy = self.gpa.dupe(u8, id) catch return;
            self.gpa.free(self.pend[i]);
            self.pend[i] = copy;
            return;
        };
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
        const hook: root.AckHook = .{ .ctx = r, .call = StreamReader.ackCall };
        if (g.ack == .manual) w.setAckHooks(hook, null) else w.setAckHooks(null, hook);
    }
    errdefer w.setAckHooks(null, null);
    try placement.concurrent(&w.group, w.io, .local, streamTask, .{r});
}

fn streamTask(r: *StreamReader) std.Io.Cancelable!void {
    defer r.destroy();
    // First: nothing queues an ack into `r` once it is going.
    defer r.w.setAckHooks(null, null);
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
            var host_buf: [if (builtin.os.tag == .windows) 1 else std.posix.HOST_NAME_MAX]u8 = undefined;
            const host = if (builtin.os.tag == .windows) "anole" else (std.posix.gethostname(&host_buf) catch "anole");
            const pid: i64 = if (builtin.os.tag == .windows) 0 else std.c.getpid();
            r.consumer = if (g.consumer) |c| try r.gpa.dupe(u8, c) else try std.fmt.allocPrint(r.gpa, "{s}-{d}", .{ host, pid });
        }
        try r.restartPending();
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
        args = .empty;
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
            for (cfg.keys, 0..) |_, i| try args.append(a, if (r.pending_phase) r.pend[i] else ">");
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
            if (cfg.group != null and r.pending_phase) r.setPend(e.key, e.id);
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
            const from = @min(pos.*, input.len);
            const end = @min(input.len, from + len);
            pos.* = end;
            return .{ .string = input[from..end] };
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

const GapProbe = struct {
    var calls: usize = 0;
    var unlocked: usize = 0;
    fn hook(hub: *PubSubHub) void {
        calls += 1;
        // `tryLock` succeeding means the hub's lock was free at the gap.
        if (hub.mutex.tryLock()) {
            hub.mutex.unlock(hub.io);
            unlocked += 1;
        }
    }
};

test "watch redis: gapAll reaches each watch under the hub's lock, once (#165)" {
    if (comptime !@import("build_options").redis) return error.SkipZigTest;
    const zio = @import("zio");
    const g = @import("../errors.zig").expectLog();
    defer g.deinit();
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const rio = rt.io();
    const gpa = std.testing.allocator;
    // Nothing listens on port 1, and the reader is never started: the hub
    // only holds the two watches.
    const client = try redis.Client.init(gpa, rio, .{ .url = "redis://127.0.0.1:1", .environ = .empty });
    defer client.deinit();
    const hub = try client._pubsubHub();
    const w1 = try Watch.init(gpa, rio, .{ .redis = .{ .client = client, .channels = &.{ "a", "b" } } }, .{});
    defer w1.deinit();
    const w2 = try Watch.init(gpa, rio, .{ .redis = .{ .client = client, .channels = &.{"a"} } }, .{});
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
