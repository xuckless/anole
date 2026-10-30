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
const push_list = dusty.push_list;
const safety = @import("anole_safety");
const test_hold = @import("test_hold.zig");
const testHold = test_hold.testHold;
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
    /// How long a record for a topic the cluster does not list yet waits
    /// for it to appear (auto-create, an admin call still spreading).
    metadata_wait: Duration = .fromSeconds(5),
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

/// Where a waiting caller learns what became of its record
/// (`appendWaiting`, then `waitFor` or `abandon`). M2's fourth class: stable
/// memory in the producer's `waits` table (chunks of 64, freed only by
/// `Producer.deinit`), named by a generation-checked `Ref`. A batch keeps
/// the ref, never a pointer it could outlive. The holder of the ref (one
/// task or thread) gives the slot back; `complete` never frees, and a stale
/// ref is a no-op (T4). The shape of the C ABI's handle slots
/// (capi/engine.zig `Slot.word`).
pub const Wait = struct {
    /// gen (u32) << 32 | state (u32). `gen` counts takes, so a stale ref
    /// fails every compare-and-swap.
    word: std.atomic.Value(u64) = .init(0),
    /// An eventcount: bumped and futex-woken by `complete`; the holder
    /// sleeps on it. A late bump meant for an earlier holder only wakes the
    /// next one spuriously (it looks at `word` again).
    bell: std.atomic.Value(u32) = .init(0),
    /// Written only while `busy` (by `complete`), read only once `done` (by
    /// the holder).
    result: Result = .pending,
    /// On `WaitTable.freed` while given back.
    node: push_list.Node = .{},
    /// On `WaitTable.free`, under `Producer.mutex`.
    next_free: ?*Wait = null,

    pub const State = enum(u32) { free, pending, busy, done };

    /// What the holder keeps. Copied freely; valid until it is waited for
    /// or abandoned.
    pub const Ref = struct { wait: *Wait, gen: u32 };

    fn pack(gen: u32, state: State) u64 {
        return @as(u64, gen) << 32 | @backingInt(state);
    }

    fn genOf(word: u64) u32 {
        return @truncate(word >> 32);
    }

    fn stateOf(word: u64) State {
        return @fromBackingInt(@intCast(@as(u32, @truncate(word))));
    }
};

/// The wait slots. owner: the producer. The free list is taken under
/// `Producer.mutex`; holders give slots back from any task or thread
/// through `freed` (SAFETY.md L7's push-list hand-off: any thread pushes,
/// the mutex holder takes). Bounded by the records pending (U4): it keeps
/// its high-water mark until `Producer.deinit`.
const WaitTable = struct {
    chunks: std.ArrayList(*[chunk_len]Wait) = .empty,
    free: ?*Wait = null,
    freed: push_list.PushList = .{},

    const chunk_len = 64;

    /// Under `Producer.mutex`: makes `free` non-empty, from the slots given
    /// back or a new chunk (a `Mutex`, not a spin lock: allocating here is
    /// allowed, L5).
    fn reserve(t: *WaitTable, gpa: std.mem.Allocator) error{OutOfMemory}!void {
        if (t.free != null) return;
        var n = t.freed.takeAll();
        while (n) |node| {
            n = node.next;
            // SAFETY: every node on `freed` is the `node` of a `Wait` (`giveBack`).
            const w: *Wait = @fieldParentPtr("node", node);
            w.next_free = t.free;
            t.free = w;
        }
        if (t.free != null) return;
        try t.chunks.ensureUnusedCapacity(gpa, 1);
        const c = try gpa.create([chunk_len]Wait);
        c.* = @splat(.{});
        t.chunks.appendAssumeCapacity(c);
        var i: usize = chunk_len;
        while (i > 0) {
            i -= 1;
            c[i].next_free = t.free;
            t.free = &c[i];
        }
    }

    /// Under `Producer.mutex`, after `reserve`: never fails.
    fn take(t: *WaitTable) Wait.Ref {
        const w = t.free.?;
        t.free = w.next_free;
        w.next_free = null;
        const gen = Wait.genOf(w.word.load(.monotonic)) +% 1;
        w.result = .pending;
        w.word.store(Wait.pack(gen, .pending), .release);
        return .{ .wait = w, .gen = gen };
    }

    /// Any task or thread, by the slot's holder once it is done with it.
    fn giveBack(t: *WaitTable, w: *Wait) void {
        // Never sealed: the chunks live until `deinit`.
        _ = t.freed.push(&w.node) catch unreachable;
    }

    fn deinit(t: *WaitTable, gpa: std.mem.Allocator) void {
        for (t.chunks.items) |c| gpa.destroy(c);
        t.chunks.deinit(gpa);
    }
};

pub const AppendError = error{ BufferFull, TooLarge, UnknownTopic, BadPartition, Closing } || cluster_mod.ConnError;

const resolver_id: i32 = -1;

/// One request's worth of records of one partition. M2 class 2: its arena
/// holds the records, freed in one go by `destroyBatch`. owner: the queue
/// that holds it (an accumulator's `open` or `ready`, a sender's in-flight
/// work, a `Done` list): it moves between them only under `Producer.mutex`,
/// and a sender owns its in-flight batches alone until it hands them back.
const Batch = struct {
    arena: std.heap.ArenaAllocator,
    /// The topic's name (`TopicState.name`, freed only by `Producer.deinit`).
    topic: []const u8,
    recs: std.ArrayList(records.Rec) = .empty,
    /// Per record: the waiting caller's ref, or null.
    waits: std.ArrayList(?Wait.Ref) = .empty,
    bytes: usize = 0,
    created: Timestamp,
    deadline: Timestamp,
    sequence: ?i32 = null,
    generation: u32 = 0,
    attempts: u32 = 0,
    retry_after: ?Timestamp = null,
    reinit_tried: bool = false,
    /// The link of the queue that holds it.
    next: ?*Batch = null,
    /// Set when it is detached into a `Done` list.
    outcome: Result = .pending,
};

/// Batches of one partition waiting to be sent, oldest first: an intrusive
/// FIFO, so moving a batch never allocates (U4). Under `Producer.mutex`.
const BatchQueue = struct {
    head: ?*Batch = null,
    tail: ?*Batch = null,
    len: u32 = 0,

    fn pushBack(q: *BatchQueue, b: *Batch) void {
        b.next = null;
        if (q.tail) |t| t.next = b else q.head = b;
        q.tail = b;
        q.len += 1;
    }

    /// A retry goes back in front.
    fn pushFront(q: *BatchQueue, b: *Batch) void {
        b.next = q.head;
        q.head = b;
        if (q.tail == null) q.tail = b;
        q.len += 1;
    }

    fn popFront(q: *BatchQueue) ?*Batch {
        const b = q.head orelse return null;
        q.head = b.next;
        if (q.head == null) q.tail = null;
        b.next = null;
        q.len -= 1;
        return b;
    }

    fn first(q: *const BatchQueue) ?*Batch {
        return q.head;
    }

    /// Takes `b` out; `prev` is the batch before it (null: `b` is first).
    fn removeAfter(q: *BatchQueue, prev: ?*Batch, b: *Batch) void {
        if (prev) |p| p.next = b.next else q.head = b.next;
        if (q.tail == b) q.tail = prev;
        b.next = null;
        q.len -= 1;
    }
};

/// Batches detached under `Producer.mutex` with their outcome, finished by
/// `retire` after it (waits, telemetry, counters, free), oldest first. The
/// list is its maker's alone.
const Done = struct {
    head: ?*Batch = null,
    tail: ?*Batch = null,

    fn add(d: *Done, b: *Batch, r: Result) void {
        b.outcome = r;
        b.next = null;
        if (d.tail) |t| t.next = b else d.head = b;
        d.tail = b;
    }
};

/// One partition's records. Process-wide memory (freed only by
/// `Producer.deinit`, so a pointer read under `mutex` stays valid after it);
/// every field under `Producer.mutex`.
const Accum = struct {
    topic: []const u8,
    partition: i32,
    leader: i32 = resolver_id,
    open: ?*Batch = null,
    ready: BatchQueue = .{},
    in_flight: bool = false,
    next_seq: i32 = 0,
    in_active: bool = false,
};

/// Process-wide memory (freed only by `Producer.deinit`), under
/// `Producer.mutex`.
const TopicState = struct {
    name: []u8,
    parts: []?*Accum = &.{},
    sticky: i32 = -1,
};

/// One per leader broker id. owner: the producer (memory freed in `deinit`,
/// never earlier, so a pointer read under `mutex` stays valid after it); its
/// task is a child of `Producer.group` (T1).
const Sender = struct {
    id: i32,
    wake: std.Io.Event = .unset,
    /// Under `Producer.mutex`. `failed`: its spawn failed; the next
    /// `startSender` tries again.
    state: enum { starting, running, failed } = .starting,
    /// The executor of its task, which alone uses `conn` (T3).
    owner: safety.Owner = .none,
    conn: ?*cluster_mod.Conn = null,
};

const Work = struct { accum: *Accum, batch: *Batch };

/// What became of an in-flight batch, decided without the lock.
const Verdict = union(enum) {
    /// Delivered; the batch's base offset (-1 under acks none).
    ok: i64,
    failed: Failure,
    /// Send it again; true: its leader is stale.
    retry: bool,
    /// The producer id (or its sequences) is no good: a new id, then again.
    reinit,
};

/// A record to append, as the caller gave it.
const Rec = struct {
    topic: []const u8,
    key: ?[]const u8,
    value: ?[]const u8,
    headers: []const records.Header,
    partition: ?i32,
    timestamp_ms: i64,
};

/// owner: Client (M2 process-wide). Teardown: `deinit`, after every caller
/// is joined (handlers, consumer deliveries, the C ABI's pump and waiters:
/// capi/engine.zig joins `x.kafka.work` before `app.deinit`). Shared by
/// every executor under `mutex` (L1: real cross-thread state).
pub const Producer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cluster: *cluster_mod.Cluster,
    cfg: Config,
    tel: ?*const Telemetry = null,

    teardown: safety.Teardown = .init,
    /// Over everything below but `group`. A leaf (L4): no cluster call, no
    /// spawn, no metrics family, no I/O and no other lock while it is held.
    mutex: safety.Mutex(.leaf) = .init,
    drained: safety.Condition = .init,
    topics: std.StringHashMapUnmanaged(*TopicState) = .empty,
    active: std.ArrayList(*Accum) = .empty,
    senders: std.AutoHashMapUnmanaged(i32, *Sender) = .empty,
    buffered: usize = 0,
    pending: usize = 0,
    flushing: u32 = 0,
    stopping: bool = false,

    /// The producer id, under `mutex`. One InitProducerId at a time (the
    /// keyring shape: `pid_fetching` and `pid_ready`), never a lock held
    /// across the round trip.
    pid: i64 = -1,
    epoch: i16 = -1,
    generation: u32 = 0,
    pid_fetching: bool = false,
    pid_ready: safety.Condition = .init,

    /// The waiting callers' slots (M2's fourth class).
    waits: WaitTable = .{},

    /// The senders (T1).
    group: std.Io.Group = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cl: *cluster_mod.Cluster, cfg: Config) !*Producer {
        const p = try gpa.create(Producer);
        p.* = .{ .gpa = gpa, .io = io, .cluster = cl, .cfg = cfg };
        return p;
    }

    /// Stops the senders, fails what is left, frees everything.
    pub fn deinit(self: *Producer) void {
        self.teardown.begin();
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        // Joins the senders; a canceled sender retires its in-flight work.
        self.group.cancel(self.io);
        self.failAll("shutdown");
        var si = self.senders.valueIterator();
        while (si.next()) |s| self.gpa.destroy(s.*);
        self.senders.deinit(self.gpa);
        var ti = self.topics.valueIterator();
        while (ti.next()) |t| {
            for (t.*.parts) |maybe| if (maybe) |a| self.gpa.destroy(a);
            self.gpa.free(t.*.parts);
            self.gpa.free(t.*.name);
            self.gpa.destroy(t.*);
        }
        self.topics.deinit(self.gpa);
        self.active.deinit(self.gpa);
        self.waits.deinit(self.gpa);
        self.teardown.end();
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

    /// Queues one record. A topic the cluster does not list yet is waited
    /// for, at most `metadata_wait`. A later delivery failure is counted.
    pub fn append(
        self: *Producer,
        topic: []const u8,
        key: ?[]const u8,
        value: ?[]const u8,
        headers: []const records.Header,
        explicit_partition: ?i32,
        timestamp_ms: i64,
    ) AppendError!void {
        const rec: Rec = .{ .topic = topic, .key = key, .value = value, .headers = headers, .partition = explicit_partition, .timestamp_ms = timestamp_ms };
        _ = try self.appendWithin(&rec, false, self.cfg.metadata_wait);
    }

    /// `append`, and a ref to wait for the record's outcome with: the
    /// caller must end it with `waitFor` or `abandon`. On an error there is
    /// none.
    pub fn appendWaiting(
        self: *Producer,
        topic: []const u8,
        key: ?[]const u8,
        value: ?[]const u8,
        headers: []const records.Header,
        explicit_partition: ?i32,
        timestamp_ms: i64,
    ) AppendError!Wait.Ref {
        const rec: Rec = .{ .topic = topic, .key = key, .value = value, .headers = headers, .partition = explicit_partition, .timestamp_ms = timestamp_ms };
        return (try self.appendWithin(&rec, true, self.cfg.metadata_wait)).?;
    }

    /// What `appendLocked` asks its caller to do.
    const Step = union(enum) {
        /// The record is in a batch (and the wait taken when asked). Wake
        /// this sender, if any.
        done: struct { wake: ?*Sender, ref: ?Wait.Ref },
        /// Partition `p` has no leader yet: look it up without the lock,
        /// then try again.
        need_leader: i32,
        /// Leader `id` has no running sender: start it without the lock,
        /// then try again.
        need_sender: i32,
    };

    /// A partition's leader as looked up without the lock (null: unknown).
    const Leader = struct { partition: i32, id: ?i32 };

    /// Any task, or a thread the runtime's owner joins first. Nothing that
    /// waits runs under `mutex`: the topic's partition count, a leader
    /// lookup and a sender's start come between lock sections, and a record
    /// joins its batch in one section in the steady state.
    fn appendWithin(self: *Producer, rec: *const Rec, wait: bool, metadata_wait: Duration) AppendError!?Wait.Ref {
        const size = recordBytes(rec.key, rec.value, rec.headers);
        if (size + records.header_len > self.cfg.max_request_bytes) return error.TooLarge;
        // May suspend; touches only `self` (process-wide) and the caller's
        // arguments after.
        const count = (try self.cluster.partitionCountWait(rec.topic, metadata_wait)) orelse return error.UnknownTopic;
        const now: Timestamp = .now(self.io, .awake);
        var known: ?Leader = null;
        var lookups: u32 = 0;
        while (true) {
            const step = blk: {
                try self.mutex.lock(self.io);
                defer self.mutex.unlock(self.io);
                break :blk try self.appendLocked(rec, size, count, now, known, lookups >= 2, wait);
            };
            switch (step) {
                // Senders are freed only by `deinit`: `s` stays valid.
                .done => |d| {
                    if (d.wake) |s| s.wake.set(self.io);
                    return d.ref;
                },
                .need_leader => |p| {
                    // Looked up without the lock: a settleAll may invalidate it meanwhile; the record then costs one refused round trip and resolves again.
                    known = .{ .partition = p, .id = self.cluster.leader(rec.topic, p) };
                    lookups += 1;
                },
                .need_sender => |id| self.startSender(id) catch |err| {
                    // Not started: the partitions it was to lead (this
                    // record's, whose leader `appendLocked` set) went back to
                    // the resolver, which assigns them again.
                    if (id != resolver_id) self.kickResolver();
                    return err;
                },
            }
        }
    }

    /// Under `mutex`. Every fallible step (the topic, accumulator and batch,
    /// the record's copies, `active`'s capacity) comes before the record
    /// joins its batch; past that point nothing fails (M1: the batch owns
    /// the record, and the wait is taken there, so an error never leaves a
    /// wait behind). `settle_unknown`: a partition whose leader is still
    /// unknown goes to the resolver.
    fn appendLocked(self: *Producer, rec: *const Rec, size: usize, count: u32, now: Timestamp, known: ?Leader, settle_unknown: bool, wait: bool) AppendError!Step {
        if (self.stopping) return error.Closing;
        if (self.buffered + size > self.cfg.buffer_bytes) return error.BufferFull;
        const ts = try self.topicState(rec.topic, count);
        const p: i32 = if (rec.partition) |ep| blk: {
            if (ep < 0 or @as(u32, @intCast(ep)) >= count) return error.BadPartition;
            break :blk ep;
        } else if (rec.key) |k| @intCast(murmur2.partition(k, count)) else blk: {
            if (ts.sticky < 0 or @as(u32, @intCast(ts.sticky)) >= count) ts.sticky = self.randomPartition(count, -1);
            break :blk ts.sticky;
        };
        const a = try self.accum(ts, p);
        if (a.leader == resolver_id) {
            const k = known orelse return .{ .need_leader = p };
            if (k.partition == p) {
                if (k.id) |id| a.leader = id;
            } else if (!settle_unknown) return .{ .need_leader = p };
        }
        const s = self.senders.get(a.leader) orelse return .{ .need_sender = a.leader };
        if (s.state == .failed) return .{ .need_sender = a.leader };
        try self.active.ensureUnusedCapacity(self.gpa, 1);
        if (wait) try self.waits.reserve(self.gpa);
        const fresh = a.open == null;
        const batch = a.open orelse try self.newBatch(ts.name, now);
        const copy: records.Rec = blk: {
            errdefer if (fresh) self.destroyBatch(batch);
            const arena = batch.arena.allocator();
            const k2: ?[]const u8 = if (rec.key) |k| try arena.dupe(u8, k) else null;
            const v2: ?[]const u8 = if (rec.value) |v| try arena.dupe(u8, v) else null;
            const hs = try arena.alloc(records.Header, rec.headers.len);
            for (rec.headers, hs) |h, *o| o.* = .{ .key = try arena.dupe(u8, h.key), .value = if (h.value) |v| try arena.dupe(u8, v) else null };
            try batch.recs.ensureUnusedCapacity(arena, 1);
            try batch.waits.ensureUnusedCapacity(arena, 1);
            break :blk .{ .key = k2, .value = v2, .headers = hs, .timestamp_ms = rec.timestamp_ms };
        };
        // Nothing fails from here on.
        const ref: ?Wait.Ref = if (wait) self.waits.take() else null;
        batch.recs.appendAssumeCapacity(copy);
        batch.waits.appendAssumeCapacity(ref);
        batch.bytes += size;
        a.open = batch;
        self.buffered += size;
        self.pending += 1;
        if (self.tel) |t| t.buffer.set(@intCast(self.buffered));
        var sealed = false;
        if (batch.bytes >= self.cfg.batch_bytes) {
            a.ready.pushBack(batch);
            a.open = null;
            sealed = true;
            if (rec.key == null and rec.partition == null) ts.sticky = self.randomPartition(count, p);
        }
        if (!a.in_active) {
            self.active.appendAssumeCapacity(a);
            a.in_active = true;
        }
        return .{ .done = .{ .wake = if (fresh or sealed) s else null, .ref = ref } };
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
        const started: Timestamp = .now(self.io, .awake);
        const metadata_wait = if (timeout) |t| (if (t.nanoseconds < self.cfg.metadata_wait.nanoseconds) t else self.cfg.metadata_wait) else self.cfg.metadata_wait;
        const rec: Rec = .{ .topic = topic, .key = key, .value = value, .headers = headers, .partition = partition, .timestamp_ms = timestamp_ms };
        // On an error no wait exists: nothing to give back.
        const ref = (try self.appendWithin(&rec, true, metadata_wait)).?;
        // The time spent waiting for a new topic's metadata counts.
        const left: ?Duration = if (timeout) |t| .{ .nanoseconds = @max(0, t.nanoseconds - started.durationTo(.now(self.io, .awake)).raw.nanoseconds) } else null;
        return self.waitFor(ref, left);
    }

    /// The holder of `ref`, once: waits for the record's outcome, at most
    /// `timeout` (null: until it comes; the delivery timeout ends every
    /// record). Gives the slot back. At the timeout, or on a cancel, the
    /// ref is abandoned (`.timeout`, `error.Canceled`): the record still
    /// finishes, and its outcome reaches no one.
    pub fn waitFor(self: *Producer, ref: Wait.Ref, timeout: ?Duration) error{Canceled}!Outcome {
        const w = ref.wait;
        const until: ?Timestamp = if (timeout) |t| Timestamp.now(self.io, .awake).addDuration(.{ .raw = t, .clock = .awake }) else null;
        while (true) {
            const bell = w.bell.load(.acquire);
            const word = w.word.load(.acquire);
            std.debug.assert(Wait.genOf(word) == ref.gen);
            switch (Wait.stateOf(word)) {
                .done => {
                    const r = w.result;
                    w.word.store(Wait.pack(ref.gen, .free), .release);
                    self.waits.giveBack(w);
                    return switch (r) {
                        .ok => |d| .{ .ok = d },
                        .failed => |f| .{ .failed = f },
                        .pending => .timeout,
                    };
                },
                // `complete` is copying the result: a few instructions (only deinit's failAll completes off a task, after every holder is joined).
                .busy => std.atomic.spinLoopHint(),
                .pending => {
                    if (until) |u| if (!Timestamp.now(self.io, .awake).compare(.lt, u)) {
                        self.abandon(ref);
                        return .timeout;
                    };
                    const t: std.Io.Timeout = if (until) |u| .{ .deadline = u } else .none;
                    self.io.futexWaitTimeout(u32, &w.bell.raw, bell, t) catch |err| switch (err) {
                        error.Canceled => {
                            self.abandon(ref);
                            return error.Canceled;
                        },
                    };
                },
                .free => unreachable,
            }
        }
    }

    /// The holder gives `ref` up without the outcome. The record still
    /// finishes; its outcome reaches no one.
    pub fn abandon(self: *Producer, ref: Wait.Ref) void {
        const w = ref.wait;
        while (true) {
            const word = w.word.load(.acquire);
            std.debug.assert(Wait.genOf(word) == ref.gen);
            switch (Wait.stateOf(word)) {
                .pending => if (w.word.cmpxchgWeak(word, Wait.pack(ref.gen, .free), .acq_rel, .acquire) != null) continue,
                .busy => {
                    // As in waitFor: a completer's busy window is a few instructions on a task.
                    std.atomic.spinLoopHint();
                    continue;
                },
                .done => w.word.store(Wait.pack(ref.gen, .free), .release),
                .free => unreachable,
            }
            self.waits.giveBack(w);
            return;
        }
    }

    /// Any task or thread (a sender's `retire`, `deinit`): gives the holder
    /// of `ref` its outcome, unless it abandoned it (a stale ref is a
    /// no-op). The pinned (`busy`) section only copies the result: it never
    /// allocates or waits. Never frees.
    fn complete(self: *Producer, ref: Wait.Ref, r: Result) void {
        const w = ref.wait;
        if (w.word.cmpxchgStrong(Wait.pack(ref.gen, .pending), Wait.pack(ref.gen, .busy), .acquire, .monotonic) != null) return;
        w.result = r;
        w.word.store(Wait.pack(ref.gen, .done), .release);
        _ = w.bell.fetchAdd(1, .release);
        self.io.futexWake(u32, &w.bell.raw, 1);
    }

    fn randomPartition(self: *Producer, count: u32, avoid: i32) i32 {
        var b: [4]u8 = undefined;
        self.io.random(&b);
        var r: i32 = @intCast(std.mem.readInt(u32, &b, .little) % count);
        if (count > 1 and r == avoid) r = @intCast((@as(u32, @intCast(r)) + 1) % count);
        return r;
    }

    /// Under `mutex`.
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

    /// Under `mutex`.
    fn accum(self: *Producer, ts: *TopicState, partition: i32) !*Accum {
        const i: usize = @intCast(partition);
        if (ts.parts[i]) |a| return a;
        const a = try self.gpa.create(Accum);
        a.* = .{ .topic = ts.name, .partition = partition };
        ts.parts[i] = a;
        return a;
    }

    fn newBatch(self: *Producer, topic: []const u8, now: Timestamp) !*Batch {
        const b = try self.gpa.create(Batch);
        b.* = .{
            .arena = .init(self.gpa),
            .topic = topic,
            .created = now,
            .deadline = now.addDuration(.{ .raw = self.cfg.delivery_timeout, .clock = .awake }),
        };
        return b;
    }

    fn destroyBatch(self: *Producer, b: *Batch) void {
        b.arena.deinit();
        self.gpa.destroy(b);
    }

    /// No lock held on entry. Starts the sender of broker `id` unless it is
    /// running or starting; the spawn runs after the lock is let go (zio's
    /// spawn backpressure may suspend the caller there, L2). A start that
    /// fails gives the partitions led by `id` back to the resolver
    /// (`startFailedLocked`), a start canceled at its lock included.
    fn startSender(self: *Producer, id: i32) error{ OutOfMemory, Closing, Canceled }!void {
        const s = blk: {
            self.mutex.lock(self.io) catch |err| {
                if (id != resolver_id) {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.startFailedLocked(id);
                }
                return err;
            };
            defer self.mutex.unlock(self.io);
            if (self.stopping) {
                self.startFailedLocked(id);
                return error.Closing;
            }
            const gop = self.senders.getOrPut(self.gpa, id) catch |err| {
                self.startFailedLocked(id);
                return err;
            };
            if (gop.found_existing) {
                const old = gop.value_ptr.*;
                if (old.state != .failed) return;
                old.state = .starting;
                break :blk old;
            }
            const made = self.gpa.create(Sender) catch |err| {
                _ = self.senders.remove(id);
                self.startFailedLocked(id);
                return err;
            };
            made.* = .{ .id = id };
            gop.value_ptr.* = made;
            break :blk made;
        };
        const exec: usize = if (id >= 0) @intCast(id) else 0;
        placement.concurrent(&self.group, self.io, .{ .executor = exec }, senderLoop, .{ self, s }) catch {
            // Kept, not freed: a racing `wake` may hold it.
            self.mutex.lockUncancelable(self.io);
            s.state = .failed;
            self.startFailedLocked(id);
            self.mutex.unlock(self.io);
            return error.OutOfMemory;
        };
        testHold(self.io, .sender_spawned);
    }

    /// Under `mutex`: broker `id`'s sender did not start. Every partition
    /// with batches whose leader is `id` goes back to the resolver: a leader
    /// set by an append (`appendLocked`) or by the resolver, which saw this
    /// start under way and took it as started, would otherwise keep its
    /// batches unsent and unexpired. The caller wakes the resolver
    /// (`kickResolver`), or is the resolver and tries again.
    fn startFailedLocked(self: *Producer, id: i32) void {
        if (id == resolver_id) return;
        for (self.active.items) |a| if (a.leader == id) {
            a.leader = resolver_id;
        };
    }

    /// Starts the resolver unless it runs, and wakes it: for partitions
    /// given back to it outside its own rounds. A caller's pending cancel
    /// waits until after (C3: it meets it at its next wait).
    fn kickResolver(self: *Producer) void {
        const was = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(was);
        self.startSender(resolver_id) catch {};
        self.wake(resolver_id);
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
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            s.owner = .here(self.io);
            s.state = .running;
        }
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
            // The work list's room is taken before the lock, so `collect`
            // never allocates under it.
            var work: std.ArrayList(Work) = .empty;
            const room = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                break :blk self.active.items.len;
            };
            var next_wake: ?Timestamp = null;
            work.ensureTotalCapacity(arena, room) catch {
                next_wake = Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromMilliseconds(50), .clock = .awake });
            };
            var unresolved = false;
            var done: Done = .{};
            const more = self.collect(s, &work, &next_wake, &unresolved, &done);
            self.retire(&done);
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
            if (more) continue;
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

    /// Takes `mutex`. Seals batches whose linger is up, detaches batches
    /// past their delivery deadline into `done`, and picks one ready batch
    /// per idle partition this sender leads, as many as `work` has room
    /// for. True when a batch was left for want of room, unless `work` has
    /// none at all (its allocation failed): the caller then waits instead
    /// of coming straight back.
    fn collect(self: *Producer, s: *Sender, work: *std.ArrayList(Work), next_wake: *?Timestamp, unresolved: *bool, done: *Done) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now: Timestamp = .now(self.io, .awake);
        const linger: std.Io.Clock.Duration = .{ .raw = self.cfg.linger, .clock = .awake };
        var request_bytes: usize = 0;
        var more = false;
        var i: usize = 0;
        while (i < self.active.items.len) {
            const a = self.active.items[i];
            self.expire(a, now, done);
            if (s.id == resolver_id) {
                if (a.leader == resolver_id and (a.open != null or a.ready.len > 0 or a.in_flight)) unresolved.* = true;
            } else if (a.leader == s.id) {
                if (a.open) |b| {
                    if (self.flushing > 0 or !now.compare(.lt, b.created.addDuration(linger))) {
                        a.ready.pushBack(b);
                        a.open = null;
                    } else next_wake.* = earliest(next_wake.*, b.created.addDuration(linger));
                }
                if (!a.in_flight) if (a.ready.first()) |b| {
                    if (b.retry_after != null and now.compare(.lt, b.retry_after.?)) {
                        next_wake.* = earliest(next_wake.*, b.retry_after.?);
                    } else if (request_bytes == 0 or request_bytes + b.bytes <= self.cfg.max_request_bytes) {
                        if (work.items.len < work.capacity) {
                            _ = a.ready.popFront();
                            a.in_flight = true;
                            request_bytes += b.bytes;
                            work.appendAssumeCapacity(.{ .accum = a, .batch = b });
                        } else if (work.capacity > 0) more = true;
                    }
                };
            }
            if (a.open == null and a.ready.len == 0 and !a.in_flight) {
                _ = self.active.swapRemove(i);
                a.in_active = false;
                continue;
            }
            // An in-flight or waiting batch can run out of time.
            if (a.ready.first()) |b| next_wake.* = earliest(next_wake.*, b.deadline);
            i += 1;
        }
        return more;
    }

    /// Under `mutex`: detaches waiting batches past their deadline.
    fn expire(self: *Producer, a: *Accum, now: Timestamp, done: *Done) void {
        _ = self;
        var prev: ?*Batch = null;
        var cur = a.ready.first();
        while (cur) |b| {
            cur = b.next;
            if (now.compare(.lt, b.deadline)) {
                prev = b;
                continue;
            }
            a.ready.removeAfter(prev, b);
            done.add(b, .{ .failed = .{ .kind = .unavailable, .code = "delivery_timeout" } });
        }
    }

    /// Refreshes the metadata of the topics with unresolved partitions and
    /// assigns their leaders. True when none is left unresolved. Leaders
    /// are looked up and senders started with no lock held.
    fn resolve(self: *Producer, arena: std.mem.Allocator) std.Io.Cancelable!bool {
        var topics: std.ArrayList([]const u8) = .empty;
        var pend: std.ArrayList(*Accum) = .empty;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            for (self.active.items) |a| {
                if (a.leader != resolver_id) continue;
                pend.append(arena, a) catch continue;
                var seen = false;
                for (topics.items) |t| if (std.mem.eql(u8, t, a.topic)) {
                    seen = true;
                    break;
                };
                if (!seen) topics.append(arena, a.topic) catch {};
            }
        }
        if (topics.items.len == 0) return true;
        self.cluster.refresh(topics.items, true) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.debug("kafka: metadata refresh failed: {t}", .{err});
            return false;
        };
        // `topic` and `partition` never change: read without the lock.
        const ids = arena.alloc(?i32, pend.items.len) catch return false;
        for (pend.items, ids) |a, *id| id.* = self.cluster.leader(a.topic, a.partition);
        var start: std.ArrayList(i32) = .empty;
        var all = true;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            for (pend.items, ids) |a, maybe| {
                const id = maybe orelse {
                    if (a.leader == resolver_id) all = false;
                    continue;
                };
                if (a.leader != resolver_id) continue;
                // The id is kept for its start before the leader is set: a
                // leader whose sender never starts strands the batches.
                const listed = for (start.items) |x| {
                    if (x == id) break true;
                } else false;
                if (!listed) start.append(arena, id) catch {
                    all = false;
                    continue;
                };
                a.leader = id;
            }
        }
        for (start.items) |id| {
            self.startSender(id) catch |err| switch (err) {
                // Its partitions went back to the resolver as well.
                error.Canceled => return error.Canceled,
                else => {
                    // Not started: its partitions went back to the resolver
                    // (`startFailedLocked`), which tries again.
                    all = false;
                    continue;
                },
            };
            self.wake(id);
        }
        return all;
    }

    // -----------------------------------------------------------------------
    // Sending

    fn sendWork(self: *Producer, s: *Sender, arena: std.mem.Allocator, work: []Work) std.Io.Cancelable!void {
        self.sendWorkInner(s, arena, work) catch |err| switch (err) {
            error.Canceled => {
                self.failWork(work, "shutdown");
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
                const verdicts = arena.alloc(Verdict, work.len) catch {
                    self.failWork(work, "OUT_OF_MEMORY");
                    return;
                };
                @memset(verdicts, .{ .retry = true });
                self.settleAll(work, verdicts, 0);
            },
        };
    }

    fn sendWorkInner(self: *Producer, s: *Sender, arena: std.mem.Allocator, work: []Work) cluster_mod.ConnError!void {
        s.owner.check(self.io);
        if (s.conn == null) s.conn = try self.cluster.connectBroker(s.id);
        const conn = s.conn.?;
        std.mem.sort(Work, work, {}, struct {
            fn lt(_: void, a: Work, b: Work) bool {
                return std.mem.lessThan(u8, a.accum.topic, b.accum.topic);
            }
        }.lt);
        var pid: i64 = -1;
        var epoch: i16 = -1;
        var generation: u32 = 0;
        // Sequence numbers: assigned at the first send under an id, kept for
        // retries. The ids and the sequences are of one generation: when the
        // id was reset after `ensurePid` returned (its next section), the
        // sender takes the new one first.
        if (self.cfg.idempotent) while (true) {
            const ids = try self.ensurePid(conn, arena);
            testHold(self.io, .ids_taken);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.pid != ids.id or self.generation != ids.generation) continue;
            pid = ids.id;
            epoch = ids.epoch;
            generation = ids.generation;
            for (work) |w| {
                if (w.batch.sequence == null or w.batch.generation != generation) {
                    const n: i32 = @intCast(w.batch.recs.items.len);
                    w.batch.sequence = w.accum.next_seq;
                    w.batch.generation = generation;
                    w.accum.next_seq = (w.accum.next_seq +% n) & 0x7fffffff;
                }
            }
            break;
        };
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
        const verdicts = try arena.alloc(Verdict, work.len);
        var e: protocol.Enc = .init(arena);
        const acks: i16 = switch (self.cfg.acks) {
            .none => 0,
            .leader => 1,
            .all => -1,
        };
        try protocol.encodeProduce(&e, acks, @intCast(@divTrunc(self.cfg.request_timeout.nanoseconds, std.time.ns_per_ms)), topics[0..n_topics]);
        if (acks == 0) {
            try conn.send(arena, .produce, e.bytesWritten(), self.cfg.request_timeout);
            @memset(verdicts, .{ .ok = -1 });
            return self.settleAll(work, verdicts, generation);
        }
        const timeout: Duration = .fromMilliseconds(@as(i64, @intCast(@divTrunc(self.cfg.request_timeout.nanoseconds, std.time.ns_per_ms))) + 5000);
        testHold(self.io, .send_request);
        const body = try conn.call(arena, .produce, e.bytesWritten(), timeout);
        const results = protocol.decodeProduce(arena, body, conn.version(.produce)) catch return error.ProtocolError;
        for (work, verdicts) |w, *v| {
            var code: i16 = protocol.unknown_topic_or_partition;
            var base: i64 = -1;
            for (results) |r| {
                if (r.partition == w.accum.partition and std.mem.eql(u8, r.topic, w.accum.topic)) {
                    code = r.error_code;
                    base = r.base_offset;
                    break;
                }
            }
            // The batch is this sender's until `settleAll` hands it back.
            v.* = self.verdictOf(w.batch, code, base);
        }
        self.settleAll(work, verdicts, generation);
    }

    fn verdictOf(self: *Producer, b: *const Batch, code: i16, base: i64) Verdict {
        if (code == protocol.none or code == protocol.duplicate_sequence) return .{ .ok = base };
        if (self.cfg.idempotent and !b.reinit_tried and (code == protocol.out_of_order_sequence or code == protocol.unknown_producer_id or code == protocol.invalid_producer_epoch)) return .reinit;
        if (protocol.isRetriable(code)) return .{ .retry = switch (code) {
            protocol.unknown_topic_or_partition, protocol.leader_not_available, protocol.not_leader_or_follower, 9, 74, 75 => true,
            else => false,
        } };
        return .{ .failed = .{ .kind = .other, .code = protocol.errorName(code) } };
    }

    /// Hands a request's batches back in one lock section: finished ones
    /// into a `Done` list, retries to the front of their queue (or failed
    /// when their delivery time is up). After the lock: stale topics are
    /// dropped from the metadata, the resolver is started and woken, the
    /// finished batches are retired.
    fn settleAll(self: *Producer, work: []const Work, verdicts: []const Verdict, generation: u32) void {
        const now: Timestamp = .now(self.io, .awake);
        var done: Done = .{};
        var stale = false;
        var reinit = false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (work, verdicts) |w, v| {
                const a = w.accum;
                const b = w.batch;
                a.in_flight = false;
                switch (v) {
                    .ok => |base| done.add(b, .{ .ok = .{ .partition = a.partition, .offset = base, .timestamp_ms = 0 } }),
                    .failed => |f| done.add(b, .{ .failed = f }),
                    .reinit => {
                        reinit = true;
                        b.reinit_tried = true;
                        b.sequence = null;
                        requeueLocked(a, b, now, false, &done);
                    },
                    .retry => |stale_leader| {
                        requeueLocked(a, b, now, stale_leader, &done);
                        if (stale_leader) stale = true;
                    },
                }
            }
            // In the same section as the requeues: a sender that takes the
            // next id afterwards numbers from zero.
            if (reinit) self.resetPidLocked(generation);
        }
        if (reinit) testHold(self.io, .pid_reset);
        // Retries and a reinit need no wake: this is the leader's own sender, which loops again after settleAll.
        if (stale) {
            for (work, verdicts, 0..) |w, v, i| {
                if (v != .retry or !v.retry) continue;
                // Once per topic.
                const seen = for (work[0..i], verdicts[0..i]) |x, xv| {
                    if (xv == .retry and xv.retry and std.mem.eql(u8, x.accum.topic, w.accum.topic)) break true;
                } else false;
                if (!seen) self.cluster.invalidate(w.accum.topic);
            }
            testHold(self.io, .stale_settled);
            self.startSender(resolver_id) catch |err| switch (err) {
                // Not this sender's wait point: it meets the cancel at its
                // next wait (C3; the lock's wait consumed it).
                error.Canceled => self.io.recancel(),
                else => {},
            };
            testHold(self.io, .resolver_started);
            self.wake(resolver_id);
        }
        self.retire(&done);
    }

    /// Under `mutex`: puts an in-flight batch back at the front of its
    /// partition's queue for another try, or detaches it as failed when
    /// its delivery time is up. `stale_leader`: forget the leader.
    fn requeueLocked(a: *Accum, b: *Batch, now: Timestamp, stale_leader: bool, done: *Done) void {
        if (!now.compare(.lt, b.deadline)) {
            done.add(b, .{ .failed = .{ .kind = .unavailable, .code = "delivery_timeout" } });
            return;
        }
        b.attempts += 1;
        const shift: u6 = @intCast(@min(b.attempts, 4));
        const backoff: Duration = .fromMilliseconds(@as(i64, 50) << shift);
        b.retry_after = now.addDuration(.{ .raw = backoff, .clock = .awake });
        a.ready.pushFront(b);
        if (stale_leader) a.leader = resolver_id;
    }

    /// Fails a request's batches (a cancel, an allocation failure).
    fn failWork(self: *Producer, work: []const Work, code: []const u8) void {
        var done: Done = .{};
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (work) |w| {
                w.accum.in_flight = false;
                done.add(w.batch, .{ .failed = .{ .kind = .unavailable, .code = code } });
            }
        }
        self.retire(&done);
    }

    /// No lock held on entry. The batches were detached under the lock, so
    /// the caller is their only owner: completes every record's wait, counts
    /// the telemetry (a metrics family takes its own lock: never under
    /// `mutex`, L3), then gives the buffer space back in one section and
    /// frees them. Completions come first, so `flush` returns only after
    /// every waiter of the flushed records has its outcome.
    fn retire(self: *Producer, done: *Done) void {
        if (done.head == null) return;
        var bytes: usize = 0;
        var n: usize = 0;
        var it = done.head;
        while (it) |b| : (it = b.next) {
            const result = b.outcome;
            for (b.waits.items, b.recs.items, 0..) |maybe, rec, i| {
                if (maybe) |ref| {
                    const r: Result = switch (result) {
                        .ok => |d| .{ .ok = .{ .partition = d.partition, .offset = if (d.offset >= 0) d.offset + @as(i64, @intCast(i)) else -1, .timestamp_ms = rec.timestamp_ms } },
                        else => result,
                    };
                    self.complete(ref, r);
                }
            }
            const count = b.recs.items.len;
            // `tel` is read without the lock; Client.start writes it without one too (a race already on main).
            if (self.tel) |t| switch (result) {
                .ok => t.produced.with(&.{ t.client, b.topic }).add(count),
                .failed => |f| for (0..count) |_| t.failedOne(f.code),
                .pending => {},
            };
            bytes += b.bytes;
            n += count;
        }
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.buffered -|= bytes;
            self.pending -|= n;
            if (self.tel) |t| t.buffer.set(@intCast(self.buffered));
            if (self.pending == 0) self.drained.broadcast(self.io);
        }
        it = done.head;
        while (it) |b| {
            it = b.next;
            self.destroyBatch(b);
        }
        done.* = .{};
    }

    /// Fails every batch still queued (at `deinit`, after the senders are
    /// joined).
    fn failAll(self: *Producer, code: []const u8) void {
        var done: Done = .{};
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const failure: Result = .{ .failed = .{ .kind = .unavailable, .code = code } };
            var ti = self.topics.valueIterator();
            while (ti.next()) |t| for (t.*.parts) |maybe| if (maybe) |a| {
                if (a.open) |b| {
                    a.open = null;
                    done.add(b, failure);
                }
                while (a.ready.popFront()) |b| done.add(b, failure);
            };
        }
        self.retire(&done);
    }

    // -----------------------------------------------------------------------
    // Producer id

    const Ids = struct { id: i64, epoch: i16, generation: u32 };

    /// The producer id, asking for one when there is none. One task asks at
    /// a time and the others wait for its answer (the keyring shape): the
    /// round trip runs with no lock held, so the connection's I/O lock is
    /// the only one (L2's exception).
    fn ensurePid(self: *Producer, conn: *cluster_mod.Conn, arena: std.mem.Allocator) cluster_mod.ConnError!Ids {
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                if (self.pid >= 0) return .{ .id = self.pid, .epoch = self.epoch, .generation = self.generation };
                if (!self.pid_fetching) break;
                try self.pid_ready.wait(self.io, &self.mutex);
            }
            self.pid_fetching = true;
        }
        const got = fetchPid(self, conn, arena);
        // C2: the flag is cleared on every exit, a cancel included.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pid_fetching = false;
        self.pid_ready.broadcast(self.io);
        const r = try got;
        self.pid = r.id;
        self.epoch = r.epoch;
        self.generation +%= 1;
        return .{ .id = self.pid, .epoch = self.epoch, .generation = self.generation };
    }

    fn fetchPid(self: *Producer, conn: *cluster_mod.Conn, arena: std.mem.Allocator) cluster_mod.ConnError!struct { id: i64, epoch: i16 } {
        var e: protocol.Enc = .init(arena);
        try protocol.encodeInitProducerId(&e, 60_000);
        const body = try conn.call(arena, .init_producer_id, e.bytesWritten(), self.cfg.request_timeout);
        const r = protocol.decodeInitProducerId(body) catch return error.ProtocolError;
        if (r.error_code != 0) {
            log.debug("kafka: InitProducerId: {s}", .{protocol.errorName(r.error_code)});
            return error.ConnectionLost;
        }
        return .{ .id = r.id, .epoch = r.epoch };
    }

    /// Under `mutex`. The producer id is no good (or its sequences are):
    /// ask for a new one at the next send and renumber every partition
    /// from zero, in one step, so no sender numbers a batch under the new
    /// id from the old sequence (franz-go resets the sequences under the
    /// lock that installs the id; the Java producer's epoch bump is one
    /// synchronized step). Ignored when `seen` is not the current
    /// generation (someone already did).
    fn resetPidLocked(self: *Producer, seen: u32) void {
        if (self.generation != seen or self.pid < 0) return;
        self.pid = -1;
        var ti = self.topics.valueIterator();
        while (ti.next()) |t| for (t.*.parts) |maybe| if (maybe) |a| {
            a.next_seq = 0;
            var it = a.ready.first();
            while (it) |b| : (it = b.next) b.sequence = null;
            if (a.open) |b| b.sequence = null;
        };
    }
};

const testing = std.testing;
const test_wait = @import("anole_test_wait");

/// One holder thread's refs to its completer thread, oldest first (an SPSC
/// ring of test tooling).
const RefRing = struct {
    // SAFETY: an item is written before `tail` passes it, and read only below `tail`.
    items: [256]Wait.Ref = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),

    fn push(r: *RefRing, ref: Wait.Ref) void {
        const t = r.tail.load(.monotonic);
        while (t - r.head.load(.acquire) == r.items.len) std.Thread.yield() catch {};
        r.items[t % r.items.len] = ref;
        r.tail.store(t + 1, .release);
    }

    /// Null once the ring is closed and empty.
    fn pop(r: *RefRing) ?Wait.Ref {
        while (true) {
            const h = r.head.load(.monotonic);
            if (h != r.tail.load(.acquire)) {
                const ref = r.items[h % r.items.len];
                r.head.store(h + 1, .release);
                return ref;
            }
            if (r.closed.load(.acquire) and h == r.tail.load(.acquire)) return null;
            std.Thread.yield() catch {};
        }
    }
};

const WaitRace = struct {
    p: *Producer,
    ring: RefRing = .{},
    index: u32,
    seed: u64,
    refs: usize,
    failure: ?anyerror = null,

    fn hold(w: *WaitRace) void {
        w.holdInner() catch |err| {
            w.failure = err;
        };
        w.ring.closed.store(true, .release);
    }

    fn holdInner(w: *WaitRace) !void {
        var prng: std.Random.DefaultPrng = .init(w.seed);
        const rand = prng.random();
        for (0..w.refs) |_| {
            const ref = blk: {
                w.p.mutex.lockUncancelable(w.p.io);
                defer w.p.mutex.unlock(w.p.io);
                try w.p.waits.reserve(w.p.gpa);
                break :blk w.p.waits.take();
            };
            w.ring.push(ref);
            switch (rand.uintLessThan(u32, 5)) {
                0 => w.p.abandon(ref),
                4 => try w.check(ref, try w.p.waitFor(ref, null)),
                else => |ticks| try w.check(ref, try w.p.waitFor(ref, .fromMicroseconds(20 * (ticks - 1)))),
            }
        }
    }

    /// A result reaches only the holder whose own completion made it.
    fn check(w: *WaitRace, ref: Wait.Ref, out: Producer.Outcome) !void {
        switch (out) {
            .ok => |d| {
                try testing.expectEqual(@as(i32, @intCast(w.index)), d.partition);
                try testing.expectEqual(@as(i64, ref.gen), d.offset);
            },
            .timeout => {},
            .failed => return error.TestUnexpectedResult,
        }
    }

    fn completeAll(w: *WaitRace) void {
        while (w.ring.pop()) |ref| {
            w.p.complete(ref, .{ .ok = .{ .partition = @intCast(w.index), .offset = ref.gen, .timestamp_ms = 0 } });
        }
    }
};

test "kafka producer: [stress] waits, completions and abandons race" {
    try test_wait.requireStress();
    const seed: u64 = 0x5eed_4a1f;
    errdefer std.debug.print("kafka wait race: seed 0x{x}\n", .{seed});
    var p: Producer = .{
        .gpa = testing.allocator,
        .io = testing.io,
        // SAFETY: the wait table never reaches the cluster.
        .cluster = undefined,
        .cfg = .{},
    };
    defer p.waits.deinit(testing.allocator);
    const pairs = 4;
    // SAFETY: every element is set on the next line.
    var races: [pairs]WaitRace = undefined;
    for (&races, 0..) |*w, i| w.* = .{ .p = &p, .index = @intCast(i), .seed = seed +% i, .refs = 1_000_000 / pairs };
    // SAFETY: only `threads[0..started]` is read.
    var threads: [2 * pairs]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |t| t.join();
    for (&races) |*w| {
        threads[started] = try std.Thread.spawn(.{}, WaitRace.completeAll, .{w});
        started += 1;
        threads[started] = try std.Thread.spawn(.{}, WaitRace.hold, .{w});
        started += 1;
    }
    for (threads[0..started]) |t| t.join();
    started = 0;
    for (&races) |*w| if (w.failure) |err| return err;
    // Every slot was given back. Asserts the table's free lists (implementation): the wrapper's own stress test, as design §6 allows.
    p.mutex.lockUncancelable(p.io);
    defer p.mutex.unlock(p.io);
    var free: usize = 0;
    var n = p.waits.freed.takeAll();
    while (n) |node| : (n = node.next) free += 1;
    var f = p.waits.free;
    while (f) |w| : (f = w.next_free) free += 1;
    try testing.expectEqual(p.waits.chunks.items.len * WaitTable.chunk_len, free);
}
