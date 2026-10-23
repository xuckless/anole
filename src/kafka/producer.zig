//! The producer: records go into an accumulator per partition, are sealed
//! into batches at `batch_bytes` or after `linger`, and a sender task per
//! leader broker sends them (one in-flight batch per partition, so a retry
//! never reorders). Idempotence (a producer id and per-partition sequence
//! numbers) makes retries safe; a retriable error refreshes the metadata
//! and sends the same batch again until `delivery_timeout`.
//!
//! One producer serves the whole client (not one per executor), so a key's
//! records keep their order across requests served on different cores.
//! Sender tasks are spread over the executors by broker id.
const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const protocol = @import("protocol.zig");
const records = @import("records.zig");
const compress = @import("compress.zig");
const murmur2 = @import("murmur2.zig");
const cluster_mod = @import("cluster.zig");
const Telemetry = @import("telemetry.zig").Telemetry;

const log = std.log.scoped(.anole);
const Duration = std.Io.Duration;
const Timestamp = std.Io.Clock.Timestamp;

pub const Acks = enum { none, leader, all };

pub const Config = struct {
    acks: Acks = .all,
    idempotent: bool = true,
    linger: Duration = .fromMilliseconds(5),
    batch_bytes: u32 = 16 * 1024,
    buffer_bytes: u32 = 32 * 1024 * 1024,
    compression: compress.Codec = .none,
    delivery_timeout: Duration = .fromSeconds(30),
    max_request_bytes: u32 = 1024 * 1024,
    request_timeout: Duration = .fromSeconds(30),
};

/// Why a delivery failed. `code` is a static string: a Kafka error name or
/// one of ours ("delivery_timeout", "shutdown").
pub const Failure = struct {
    kind: enum { unavailable, timeout, other },
    code: []const u8,
};

pub const Delivered = struct { partition: i32, offset: i64, timestamp_ms: i64 };

pub const Result = union(enum) {
    pending,
    ok: Delivered,
    failed: Failure,
};

/// Where a waiting `produce` learns what became of its record. Shared
/// between the caller and the producer (two references).
pub const Slot = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(2),
    event: std.Io.Event = .unset,
    result: Result = .pending,

    pub fn create(gpa: std.mem.Allocator) !*Slot {
        const s = try gpa.create(Slot);
        s.* = .{ .gpa = gpa };
        return s;
    }

    pub fn release(s: *Slot) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.gpa.destroy(s);
    }

    fn finish(s: *Slot, io: std.Io, r: Result) void {
        s.result = r;
        s.event.set(io);
        s.release();
    }
};

pub const AppendError = error{ BufferFull, TooLarge, UnknownTopic, BadPartition, Closing } || cluster_mod.ConnError;

const resolver_id: i32 = -1;

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    recs: std.ArrayList(records.Rec) = .empty,
    slots: std.ArrayList(?*Slot) = .empty,
    bytes: usize = 0,
    created: Timestamp,
    deadline: Timestamp,
    sequence: ?i32 = null,
    generation: u32 = 0,
    attempts: u32 = 0,
    retry_after: ?Timestamp = null,
    reinit_tried: bool = false,
};

const Accum = struct {
    topic: []const u8,
    partition: i32,
    leader: i32 = resolver_id,
    open: ?*Batch = null,
    ready: std.ArrayList(*Batch) = .empty,
    in_flight: bool = false,
    next_seq: i32 = 0,
    in_active: bool = false,
};

const TopicState = struct {
    name: []u8,
    parts: []?*Accum = &.{},
    sticky: i32 = -1,
};

const Sender = struct {
    id: i32,
    wake: std.Io.Event = .unset,
    conn: ?*cluster_mod.Conn = null,
};

const Work = struct { accum: *Accum, batch: *Batch };

pub const Producer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cluster: *cluster_mod.Cluster,
    cfg: Config,
    tel: ?*const Telemetry = null,

    mutex: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    topics: std.StringHashMapUnmanaged(*TopicState) = .empty,
    active: std.ArrayList(*Accum) = .empty,
    senders: std.AutoHashMapUnmanaged(i32, *Sender) = .empty,
    group: std.Io.Group = .init,
    buffered: usize = 0,
    pending: usize = 0,
    flushing: u32 = 0,
    stopping: bool = false,

    pid_mutex: std.Io.Mutex = .init,
    pid: i64 = -1,
    epoch: i16 = -1,
    generation: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cl: *cluster_mod.Cluster, cfg: Config) !*Producer {
        const p = try gpa.create(Producer);
        p.* = .{ .gpa = gpa, .io = io, .cluster = cl, .cfg = cfg };
        return p;
    }

    /// Stops the senders, fails what is left, frees everything.
    pub fn deinit(self: *Producer) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.group.cancel(self.io);
        self.failAll("shutdown");
        var si = self.senders.valueIterator();
        while (si.next()) |s| self.gpa.destroy(s.*);
        self.senders.deinit(self.gpa);
        var ti = self.topics.valueIterator();
        while (ti.next()) |t| {
            for (t.*.parts) |maybe| if (maybe) |a| {
                a.ready.deinit(self.gpa);
                self.gpa.destroy(a);
            };
            self.gpa.free(t.*.parts);
            self.gpa.free(t.*.name);
            self.gpa.destroy(t.*);
        }
        self.topics.deinit(self.gpa);
        self.active.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn writable(self: *Producer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buffered < self.cfg.buffer_bytes / 2;
    }

    // -----------------------------------------------------------------------
    // Appending

    fn recordBytes(key: ?[]const u8, value: ?[]const u8, headers: []const records.Header) usize {
        var n: usize = 32 + (if (key) |k| k.len else 0) + (if (value) |v| v.len else 0);
        for (headers) |h| n += 8 + h.key.len + (if (h.value) |v| v.len else 0);
        return n;
    }

    /// Queues one record. `slot`, when given, receives the outcome (the
    /// producer then owns one reference to it).
    pub fn append(
        self: *Producer,
        topic: []const u8,
        key: ?[]const u8,
        value: ?[]const u8,
        headers: []const records.Header,
        explicit_partition: ?i32,
        timestamp_ms: i64,
        slot: ?*Slot,
    ) AppendError!void {
        const size = recordBytes(key, value, headers);
        if (size + records.header_len > self.cfg.max_request_bytes) return error.TooLarge;
        const count = (try self.cluster.partitionCount(topic)) orelse return error.UnknownTopic;
        const now: Timestamp = .now(self.io, .awake);

        var wake_id: ?i32 = null;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stopping) return error.Closing;
            if (self.buffered + size > self.cfg.buffer_bytes) return error.BufferFull;
            const ts = try self.topicState(topic, count);
            const p: i32 = if (explicit_partition) |ep| blk: {
                if (ep < 0 or @as(u32, @intCast(ep)) >= count) return error.BadPartition;
                break :blk ep;
            } else if (key) |k| @intCast(murmur2.partition(k, count)) else blk: {
                if (ts.sticky < 0 or @as(u32, @intCast(ts.sticky)) >= count) ts.sticky = self.randomPartition(count, -1);
                break :blk ts.sticky;
            };
            const a = try self.accum(ts, p);
            if (a.leader == resolver_id) a.leader = self.cluster.leader(topic, p) orelse resolver_id;
            const fresh = a.open == null;
            const batch = a.open orelse try self.newBatch(now);
            {
                errdefer if (fresh) self.destroyBatch(batch);
                const arena = batch.arena.allocator();
                const k2: ?[]const u8 = if (key) |k| try arena.dupe(u8, k) else null;
                const v2: ?[]const u8 = if (value) |v| try arena.dupe(u8, v) else null;
                const hs = try arena.alloc(records.Header, headers.len);
                for (headers, hs) |h, *o| o.* = .{ .key = try arena.dupe(u8, h.key), .value = if (h.value) |v| try arena.dupe(u8, v) else null };
                try batch.recs.append(arena, .{ .key = k2, .value = v2, .headers = hs, .timestamp_ms = timestamp_ms });
                try batch.slots.append(arena, slot);
            }
            batch.bytes += size;
            a.open = batch;
            self.buffered += size;
            self.pending += 1;
            if (self.tel) |t| t.buffer.set(@intCast(self.buffered));
            var sealed = false;
            if (batch.bytes >= self.cfg.batch_bytes) {
                try a.ready.append(self.gpa, batch);
                a.open = null;
                sealed = true;
                if (key == null and explicit_partition == null) ts.sticky = self.randomPartition(count, p);
            }
            if (!a.in_active) {
                try self.active.append(self.gpa, a);
                a.in_active = true;
            }
            if (fresh or sealed) {
                _ = try self.ensureSender(a.leader);
                wake_id = a.leader;
            }
        }
        if (wake_id) |id| self.wake(id);
    }

    pub const Outcome = union(enum) { ok: Delivered, failed: Failure, timeout };

    /// Queues a record and waits for its acknowledgement, at most
    /// `timeout` (null: until the delivery timeout ends it).
    pub fn produceWait(
        self: *Producer,
        topic: []const u8,
        key: ?[]const u8,
        value: ?[]const u8,
        headers: []const records.Header,
        partition: ?i32,
        timestamp_ms: i64,
        timeout: ?Duration,
    ) AppendError!Outcome {
        const slot = try Slot.create(self.gpa);
        self.append(topic, key, value, headers, partition, timestamp_ms, slot) catch |err| {
            slot.release();
            slot.release();
            return err;
        };
        defer slot.release();
        if (timeout) |t| {
            slot.event.waitTimeout(self.io, .{ .duration = .{ .raw = t, .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => return .timeout,
                error.Canceled => return error.Canceled,
            };
        } else try slot.event.wait(self.io);
        return switch (slot.result) {
            .ok => |d| .{ .ok = d },
            .failed => |f| .{ .failed = f },
            .pending => .timeout,
        };
    }

    fn randomPartition(self: *Producer, count: u32, avoid: i32) i32 {
        var b: [4]u8 = undefined;
        self.io.random(&b);
        var r: i32 = @intCast(std.mem.readInt(u32, &b, .little) % count);
        if (count > 1 and r == avoid) r = @intCast((@as(u32, @intCast(r)) + 1) % count);
        return r;
    }

    fn topicState(self: *Producer, topic: []const u8, count: u32) !*TopicState {
        const ts = self.topics.get(topic) orelse blk: {
            const t = try self.gpa.create(TopicState);
            errdefer self.gpa.destroy(t);
            t.* = .{ .name = try self.gpa.dupe(u8, topic) };
            errdefer self.gpa.free(t.name);
            try self.topics.put(self.gpa, t.name, t);
            break :blk t;
        };
        if (ts.parts.len < count) {
            const old = ts.parts.len;
            ts.parts = try self.gpa.realloc(ts.parts, count);
            @memset(ts.parts[old..], null);
        }
        return ts;
    }

    fn accum(self: *Producer, ts: *TopicState, partition: i32) !*Accum {
        const i: usize = @intCast(partition);
        if (ts.parts[i]) |a| return a;
        const a = try self.gpa.create(Accum);
        a.* = .{ .topic = ts.name, .partition = partition };
        ts.parts[i] = a;
        return a;
    }

    fn newBatch(self: *Producer, now: Timestamp) !*Batch {
        const b = try self.gpa.create(Batch);
        b.* = .{
            .arena = .init(self.gpa),
            .created = now,
            .deadline = now.addDuration(.{ .raw = self.cfg.delivery_timeout, .clock = .awake }),
        };
        return b;
    }

    fn destroyBatch(self: *Producer, b: *Batch) void {
        b.arena.deinit();
        self.gpa.destroy(b);
    }

    /// Under `mutex`.
    fn ensureSender(self: *Producer, id: i32) !*Sender {
        if (self.senders.get(id)) |s| return s;
        const s = try self.gpa.create(Sender);
        errdefer self.gpa.destroy(s);
        s.* = .{ .id = id };
        try self.senders.put(self.gpa, id, s);
        errdefer _ = self.senders.remove(id);
        const exec: usize = if (id >= 0) @intCast(id) else 0;
        placement.concurrent(&self.group, self.io, .{ .executor = exec }, senderLoop, .{ self, s }) catch return error.OutOfMemory;
        return s;
    }

    fn wake(self: *Producer, id: i32) void {
        self.mutex.lockUncancelable(self.io);
        const s = self.senders.get(id);
        self.mutex.unlock(self.io);
        if (s) |sender| sender.wake.set(self.io);
    }

    fn wakeAll(self: *Producer) void {
        self.mutex.lockUncancelable(self.io);
        var it = self.senders.valueIterator();
        while (it.next()) |s| s.*.wake.set(self.io);
        self.mutex.unlock(self.io);
    }

    // -----------------------------------------------------------------------
    // Flushing

    /// Seals every open batch and waits until nothing is pending, or until
    /// `timeout` has passed (`error.Timeout`).
    pub fn flush(self: *Producer, timeout: ?Duration) error{ Timeout, Canceled }!void {
        const until: ?Timestamp = if (timeout) |t| Timestamp.now(self.io, .awake).addDuration(.{ .raw = t, .clock = .awake }) else null;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.flushing += 1;
        defer self.flushing -= 1;
        while (self.pending > 0) {
            self.mutex.unlock(self.io);
            self.wakeAll();
            self.mutex.lockUncancelable(self.io);
            if (self.pending == 0) break;
            if (until) |u| {
                self.drained.waitTimeout(self.io, &self.mutex, .{ .deadline = u }) catch |err| switch (err) {
                    error.Timeout => return if (self.pending == 0) {} else error.Timeout,
                    error.Canceled => return error.Canceled,
                };
            } else try self.drained.wait(self.io, &self.mutex);
        }
    }

    // -----------------------------------------------------------------------
    // Senders

    fn senderLoop(self: *Producer, s: *Sender) std.Io.Cancelable!void {
        defer if (s.conn) |c| {
            c.close();
            s.conn = null;
        };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            s.wake.reset();
            var work: std.ArrayList(Work) = .empty;
            var next_wake: ?Timestamp = null;
            var unresolved = false;
            self.collect(s, arena, &work, &next_wake, &unresolved);
            if (s.id == resolver_id) {
                if (unresolved and !try self.resolve(arena)) {
                    const retry_at = Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromMilliseconds(250), .clock = .awake });
                    next_wake = earliest(next_wake, retry_at);
                }
            }
            if (work.items.len > 0) {
                try self.sendWork(s, arena, work.items);
                continue;
            }
            if (next_wake) |t| {
                s.wake.waitTimeout(self.io, .{ .deadline = t }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return error.Canceled,
                };
            } else try s.wake.wait(self.io);
        }
    }

    fn earliest(a: ?Timestamp, b: Timestamp) Timestamp {
        if (a) |x| return if (x.compare(.lt, b)) x else b;
        return b;
    }

    /// Under no lock: takes `mutex`. Seals batches whose linger is up,
    /// expires batches past their delivery deadline, and picks one ready
    /// batch per idle partition this sender leads.
    fn collect(self: *Producer, s: *Sender, arena: std.mem.Allocator, work: *std.ArrayList(Work), next_wake: *?Timestamp, unresolved: *bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now: Timestamp = .now(self.io, .awake);
        const linger: std.Io.Clock.Duration = .{ .raw = self.cfg.linger, .clock = .awake };
        var request_bytes: usize = 0;
        var i: usize = 0;
        while (i < self.active.items.len) {
            const a = self.active.items[i];
            self.expire(a, now);
            if (s.id == resolver_id) {
                if (a.leader == resolver_id and (a.open != null or a.ready.items.len > 0 or a.in_flight)) unresolved.* = true;
            } else if (a.leader == s.id) {
                if (a.open) |b| {
                    if (self.flushing > 0 or !now.compare(.lt, b.created.addDuration(linger))) {
                        a.ready.append(self.gpa, b) catch {};
                        a.open = null;
                    } else next_wake.* = earliest(next_wake.*, b.created.addDuration(linger));
                }
                if (!a.in_flight and a.ready.items.len > 0) {
                    const b = a.ready.items[0];
                    if (b.retry_after != null and now.compare(.lt, b.retry_after.?)) {
                        next_wake.* = earliest(next_wake.*, b.retry_after.?);
                    } else if (request_bytes == 0 or request_bytes + b.bytes <= self.cfg.max_request_bytes) {
                        _ = a.ready.orderedRemove(0);
                        a.in_flight = true;
                        request_bytes += b.bytes;
                        work.append(arena, .{ .accum = a, .batch = b }) catch {
                            a.ready.insert(self.gpa, 0, b) catch {};
                            a.in_flight = false;
                        };
                    }
                }
            }
            if (a.open == null and a.ready.items.len == 0 and !a.in_flight) {
                _ = self.active.swapRemove(i);
                a.in_active = false;
                continue;
            }
            // An in-flight or waiting batch can run out of time.
            if (a.ready.items.len > 0) next_wake.* = earliest(next_wake.*, a.ready.items[0].deadline);
            i += 1;
        }
    }

    /// Under `mutex`: fails waiting batches past their deadline.
    fn expire(self: *Producer, a: *Accum, now: Timestamp) void {
        var i: usize = 0;
        while (i < a.ready.items.len) {
            const b = a.ready.items[i];
            if (now.compare(.lt, b.deadline)) {
                i += 1;
                continue;
            }
            _ = a.ready.orderedRemove(i);
            self.finishLocked(a.topic, b, .{ .failed = .{ .kind = .unavailable, .code = "delivery_timeout" } });
        }
    }

    /// Refreshes the metadata of the topics with unresolved partitions and
    /// assigns their leaders. True when none is left unresolved.
    fn resolve(self: *Producer, arena: std.mem.Allocator) std.Io.Cancelable!bool {
        var topics: std.ArrayList([]const u8) = .empty;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            for (self.active.items) |a| {
                if (a.leader != resolver_id) continue;
                var seen = false;
                for (topics.items) |t| if (std.mem.eql(u8, t, a.topic)) {
                    seen = true;
                    break;
                };
                if (!seen) topics.append(arena, arena.dupe(u8, a.topic) catch continue) catch {};
            }
        }
        if (topics.items.len == 0) return true;
        self.cluster.refresh(topics.items, true) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.debug("kafka: metadata refresh failed: {t}", .{err});
            return false;
        };
        var wake_ids: std.ArrayList(i32) = .empty;
        var all = true;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            for (self.active.items) |a| {
                if (a.leader != resolver_id) continue;
                if (self.cluster.leader(a.topic, a.partition)) |id| {
                    a.leader = id;
                    _ = self.ensureSender(id) catch continue;
                    wake_ids.append(arena, id) catch {};
                } else all = false;
            }
        }
        for (wake_ids.items) |id| self.wake(id);
        return all;
    }

    // -----------------------------------------------------------------------
    // Sending

    fn sendWork(self: *Producer, s: *Sender, arena: std.mem.Allocator, work: []Work) std.Io.Cancelable!void {
        self.sendWorkInner(s, arena, work) catch |err| switch (err) {
            error.Canceled => {
                for (work) |w| self.finish(w.accum, w.batch, .{ .failed = .{ .kind = .unavailable, .code = "shutdown" } });
                return error.Canceled;
            },
            else => {
                // The connection (or the producer id) failed: the batches wait
                // for another try.
                if (s.conn) |c| {
                    c.close();
                    s.conn = null;
                }
                log.debug("kafka: send to broker {d} failed: {t}", .{ s.id, err });
                for (work) |w| self.retry(w.accum, w.batch, true);
            },
        };
    }

    fn sendWorkInner(self: *Producer, s: *Sender, arena: std.mem.Allocator, work: []Work) cluster_mod.ConnError!void {
        if (s.conn == null) s.conn = try self.cluster.connectBroker(s.id);
        const conn = s.conn.?;
        var pid: i64 = -1;
        var epoch: i16 = -1;
        var generation: u32 = 0;
        if (self.cfg.idempotent) {
            const ids = try self.ensurePid(conn, arena);
            pid = ids.id;
            epoch = ids.epoch;
            generation = ids.generation;
        }
        std.mem.sort(Work, work, {}, struct {
            fn lt(_: void, a: Work, b: Work) bool {
                return std.mem.lessThan(u8, a.accum.topic, b.accum.topic);
            }
        }.lt);
        // Sequence numbers: assigned at the first send, kept for retries.
        if (self.cfg.idempotent) {
            self.mutex.lockUncancelable(self.io);
            for (work) |w| {
                if (w.batch.sequence == null or w.batch.generation != generation) {
                    const n: i32 = @intCast(w.batch.recs.items.len);
                    w.batch.sequence = w.accum.next_seq;
                    w.batch.generation = generation;
                    w.accum.next_seq = (w.accum.next_seq +% n) & 0x7fffffff;
                }
            }
            self.mutex.unlock(self.io);
        }
        const topics = try arena.alloc(protocol.ProduceTopic, work.len);
        const parts = try arena.alloc(protocol.ProducePartition, work.len);
        var n_topics: usize = 0;
        var i: usize = 0;
        while (i < work.len) {
            var j = i;
            while (j < work.len and std.mem.eql(u8, work[j].accum.topic, work[i].accum.topic)) j += 1;
            for (work[i..j], i..) |w, k| {
                const bytes = records.encodeBatch(arena, w.batch.recs.items, .{
                    .codec = self.cfg.compression,
                    .producer_id = pid,
                    .producer_epoch = epoch,
                    .base_sequence = if (self.cfg.idempotent) w.batch.sequence.? else -1,
                }) catch return error.OutOfMemory;
                parts[k] = .{ .index = w.accum.partition, .batch = bytes };
            }
            topics[n_topics] = .{ .topic = work[i].accum.topic, .partitions = parts[i..j] };
            n_topics += 1;
            i = j;
        }
        var e: protocol.Enc = .init(arena);
        const acks: i16 = switch (self.cfg.acks) {
            .none => 0,
            .leader => 1,
            .all => -1,
        };
        try protocol.encodeProduce(&e, acks, @intCast(@divTrunc(self.cfg.request_timeout.nanoseconds, std.time.ns_per_ms)), topics[0..n_topics]);
        if (acks == 0) {
            try conn.send(arena, .produce, e.bytesWritten(), self.cfg.request_timeout);
            for (work) |w| self.finish(w.accum, w.batch, .{ .ok = .{ .partition = w.accum.partition, .offset = -1, .timestamp_ms = 0 } });
            return;
        }
        const timeout: Duration = .fromMilliseconds(@as(i64, @intCast(@divTrunc(self.cfg.request_timeout.nanoseconds, std.time.ns_per_ms))) + 5000);
        const body = try conn.call(arena, .produce, e.bytesWritten(), timeout);
        const results = protocol.decodeProduce(arena, body) catch return error.ProtocolError;
        for (work) |w| {
            var code: i16 = protocol.unknown_topic_or_partition;
            var base: i64 = -1;
            for (results) |r| {
                if (r.partition == w.accum.partition and std.mem.eql(u8, r.topic, w.accum.topic)) {
                    code = r.error_code;
                    base = r.base_offset;
                    break;
                }
            }
            self.settle(w, code, base, generation);
        }
    }

    fn settle(self: *Producer, w: Work, code: i16, base: i64, generation: u32) void {
        if (code == protocol.none or code == protocol.duplicate_sequence) {
            self.finish(w.accum, w.batch, .{ .ok = .{ .partition = w.accum.partition, .offset = base, .timestamp_ms = 0 } });
            return;
        }
        if (self.cfg.idempotent and (code == protocol.out_of_order_sequence or code == protocol.unknown_producer_id or code == protocol.invalid_producer_epoch)) {
            if (!w.batch.reinit_tried) {
                self.resetPid(generation);
                w.batch.reinit_tried = true;
                w.batch.sequence = null;
                self.retry(w.accum, w.batch, false);
                return;
            }
        }
        if (protocol.isRetriable(code)) {
            const leader_error = switch (code) {
                protocol.unknown_topic_or_partition, protocol.leader_not_available, protocol.not_leader_or_follower, 9, 74, 75 => true,
                else => false,
            };
            self.retry(w.accum, w.batch, leader_error);
            return;
        }
        self.finish(w.accum, w.batch, .{ .failed = .{ .kind = .other, .code = protocol.errorName(code) } });
    }

    /// Puts a batch back at the front of its partition's queue for another
    /// try (or fails it when its delivery time is up). `stale_leader`:
    /// forget the leader.
    fn retry(self: *Producer, a: *Accum, b: *Batch, stale_leader: bool) void {
        const now: Timestamp = .now(self.io, .awake);
        self.mutex.lockUncancelable(self.io);
        if (!now.compare(.lt, b.deadline)) {
            self.mutex.unlock(self.io);
            self.finish(a, b, .{ .failed = .{ .kind = .unavailable, .code = "delivery_timeout" } });
            return;
        }
        b.attempts += 1;
        const shift: u6 = @intCast(@min(b.attempts, 4));
        const backoff: Duration = .fromMilliseconds(@as(i64, 50) << shift);
        b.retry_after = now.addDuration(.{ .raw = backoff, .clock = .awake });
        a.ready.insert(self.gpa, 0, b) catch {
            self.mutex.unlock(self.io);
            self.finish(a, b, .{ .failed = .{ .kind = .other, .code = "OUT_OF_MEMORY" } });
            return;
        };
        a.in_flight = false;
        if (stale_leader) a.leader = resolver_id;
        const leader = a.leader;
        const topic = a.topic;
        self.mutex.unlock(self.io);
        if (stale_leader) {
            self.cluster.invalidate(topic);
            self.mutex.lockUncancelable(self.io);
            _ = self.ensureSender(resolver_id) catch {};
            self.mutex.unlock(self.io);
            self.wake(resolver_id);
        } else self.wake(leader);
    }

    /// Completes every record of `b` with `result` and frees it.
    fn finish(self: *Producer, a: *Accum, b: *Batch, result: Result) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        a.in_flight = false;
        self.finishLocked(a.topic, b, result);
    }

    /// Under `mutex`. `result.ok.offset` is the batch's base offset.
    fn finishLocked(self: *Producer, topic: []const u8, b: *Batch, result: Result) void {
        for (b.slots.items, b.recs.items, 0..) |maybe, rec, i| {
            if (maybe) |slot| {
                const r: Result = switch (result) {
                    .ok => |d| .{ .ok = .{ .partition = d.partition, .offset = if (d.offset >= 0) d.offset + @as(i64, @intCast(i)) else -1, .timestamp_ms = rec.timestamp_ms } },
                    else => result,
                };
                slot.finish(self.io, r);
            }
        }
        const n = b.recs.items.len;
        if (self.tel) |t| {
            switch (result) {
                .ok => t.produced.with(&.{ t.client, topic }).add(n),
                .failed => |f| for (0..n) |_| t.failedOne(f.code),
                .pending => {},
            }
        }
        self.buffered -|= b.bytes;
        self.pending -|= n;
        if (self.tel) |t| t.buffer.set(@intCast(self.buffered));
        if (self.pending == 0) self.drained.broadcast(self.io);
        self.destroyBatch(b);
    }

    fn failAll(self: *Producer, code: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var ti = self.topics.valueIterator();
        while (ti.next()) |t| for (t.*.parts) |maybe| if (maybe) |a| {
            if (a.open) |b| {
                a.open = null;
                self.finishLocked(a.topic, b, .{ .failed = .{ .kind = .unavailable, .code = code } });
            }
            while (a.ready.items.len > 0) {
                const b = a.ready.orderedRemove(0);
                self.finishLocked(a.topic, b, .{ .failed = .{ .kind = .unavailable, .code = code } });
            }
        };
    }

    // -----------------------------------------------------------------------
    // Producer id

    const Ids = struct { id: i64, epoch: i16, generation: u32 };

    fn ensurePid(self: *Producer, conn: *cluster_mod.Conn, arena: std.mem.Allocator) cluster_mod.ConnError!Ids {
        try self.pid_mutex.lock(self.io);
        defer self.pid_mutex.unlock(self.io);
        if (self.pid >= 0) return .{ .id = self.pid, .epoch = self.epoch, .generation = self.generation };
        var e: protocol.Enc = .init(arena);
        try protocol.encodeInitProducerId(&e, 60_000);
        const body = try conn.call(arena, .init_producer_id, e.bytesWritten(), self.cfg.request_timeout);
        const r = protocol.decodeInitProducerId(body) catch return error.ProtocolError;
        if (r.error_code != 0) {
            log.debug("kafka: InitProducerId: {s}", .{protocol.errorName(r.error_code)});
            return error.ConnectionLost;
        }
        self.pid = r.id;
        self.epoch = r.epoch;
        self.generation +%= 1;
        return .{ .id = self.pid, .epoch = self.epoch, .generation = self.generation };
    }

    /// The producer id is no good (or its sequences are): ask for a new one
    /// at the next send, and renumber every partition from zero. Ignored
    /// when `seen` is not the current generation (someone already did).
    fn resetPid(self: *Producer, seen: u32) void {
        self.pid_mutex.lockUncancelable(self.io);
        if (self.generation != seen or self.pid < 0) {
            self.pid_mutex.unlock(self.io);
            return;
        }
        self.pid = -1;
        self.pid_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var ti = self.topics.valueIterator();
        while (ti.next()) |t| for (t.*.parts) |maybe| if (maybe) |a| {
            a.next_seq = 0;
            for (a.ready.items) |b| b.sequence = null;
            if (a.open) |b| b.sequence = null;
        };
    }
};

const testing = std.testing;

test "Slot: two references, finished once" {
    const s = try Slot.create(testing.allocator);
    s.finish(testing.io, .{ .ok = .{ .partition = 1, .offset = 5, .timestamp_ms = 9 } });
    try s.event.wait(testing.io);
    try testing.expectEqual(@as(i64, 5), s.result.ok.offset);
    s.release();
}
