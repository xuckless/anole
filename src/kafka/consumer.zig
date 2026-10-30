//! Consumer groups: the classic protocol (JoinGroup, SyncGroup, Heartbeat,
//! OffsetCommit/Fetch) with eager rebalancing, the range and roundrobin
//! assignors, static membership, and per-partition delivery tasks.
//!
//! A member is one task running sessions. A session is one generation of
//! the group: it joins, gets its assignment, reads the committed offsets,
//! and then runs
//!
//! - one fetcher task per leader broker (one Fetch request per round for
//!   all its partitions; a partition whose buffer is full is left out, which
//!   is the back-pressure),
//! - one delivery task per partition (records go to the handler one at a
//!   time, in order, on executor `partition % executors`),
//! - a heartbeat task (which also commits processed offsets every
//!   `commit_interval`).
//!
//! A rebalance (or the client stopping) ends the session: fetching and
//! heartbeats stop at once, deliveries finish the record they are on (up to
//! `rebalance_timeout`), the processed offsets are committed, and the member
//! rejoins (or leaves).
const std = @import("std");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const test_hold = @import("test_hold.zig");
const placement = dusty.placement;
const protocol = @import("protocol.zig");
const records = @import("records.zig");
const cluster_mod = @import("cluster.zig");
const producer_mod = @import("producer.zig");
const resilience = @import("../resilience/root.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const anole_log = @import("anole_log");

const log = std.log.scoped(.anole);
const Duration = std.Io.Duration;
const Timestamp = std.Io.Clock.Timestamp;
const Conn = cluster_mod.Conn;

pub const Header = records.Header;

/// One record to a handler; a request-like context (the database
/// connectors take it where they take a request).
pub const Msg = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    locals: dusty.Locals = .{},
    /// "kafka-<topic>-<partition>-<offset>"
    id: []const u8,
    topic: []const u8,
    partition: i32,
    offset: i64,
    timestamp_ms: i64,
    key: ?[]const u8,
    value: ?[]const u8,
    headers: []const Header,

    /// The first header called `name`.
    pub fn header(self: *const Msg, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.key, name)) return h.value;
        return null;
    }

    /// The value parsed as JSON into `T` (strings point into the arena).
    pub fn json(self: *Msg, comptime T: type) !T {
        const v = self.value orelse return error.BadRequest;
        return std.json.parseFromSliceLeaky(T, self.arena, v, .{ .ignore_unknown_fields = true }) catch error.BadRequest;
    }

    /// The value as a `T`, mapped field by field and checked by `T`'s
    /// `field_rules` (`anole.bindJson`): `error.BadRequest` when there is no
    /// value, `error.InvalidJsonBody` when it is not JSON,
    /// `error.ValidationFailed` when it does not fit or breaks a rule, after
    /// one warning that names the first problem.
    pub fn bind(self: *Msg, comptime T: type) !T {
        const v = self.value orelse return error.BadRequest;
        const result = try dusty.bindJson(T, self.arena, v, .{});
        switch (result) {
            .ok => |value| return value,
            .invalid => |found| {
                const first = found.items[0];
                self.log().warn("message does not fit the type", .{
                    .violations = found.items.len,
                    .first_field = first.field orelse "",
                    .first_code = first.code,
                });
                return error.ValidationFailed;
            },
        }
    }

    /// A logger whose records carry this message's id, under the scope `kafka`.
    pub fn log(self: *const Msg) anole_log.Scoped(.kafka) {
        return .{ .context = .{ .request_id = self.id } };
    }
};

pub const Assignor = enum { range, roundrobin };

pub const ConsumeOptions = struct {
    group: []const u8,
    topics: []const []const u8,
    /// Where a partition without a committed offset starts.
    start: enum { latest, earliest } = .latest,
    /// Static membership (KIP-345): a restart within the session timeout
    /// keeps its partitions.
    instance_id: ?[]const u8 = null,
    members: u8 = 1,
    assignor: Assignor = .range,
    session_timeout: Duration = .fromSeconds(45),
    heartbeat_interval: Duration = .fromSeconds(3),
    /// How long a rebalance may wait for this member (also its longest handler run).
    rebalance_timeout: Duration = .fromSeconds(300),
    /// Records fetched ahead per partition, at most.
    prefetch_bytes: u32 = 1024 * 1024,
    commit_interval: Duration = .fromSeconds(5),
    /// A failed record is retried with this, then dead-lettered or skipped.
    retry: resilience.Retry = .{ .attempts = 10, .backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(10) } },
    /// A topic failed records are produced to (with headers
    /// anole-dlt-topic, -partition, -offset, -error); null: logged and skipped.
    dead_letter: ?[]const u8 = null,
    /// A bound per handler run; null: none.
    timeout: ?Duration = .fromSeconds(30),
    /// The C ABI's way in: when set, records go to this in batches of at
    /// most `max_batch` (one partition, in order, one batch outstanding per
    /// partition) instead of one by one to the record handler, which is
    /// then never called, and `retry` and `dead_letter` do not apply (the
    /// consumer of the batch decides).
    batch_handler: ?BatchHandlerFn = null,
    max_batch: u32 = 500,
    /// Told (from the member's task, without waiting) which partitions this
    /// member got after a join, and which it is about to give up.
    on_assign: ?PartitionsFn = null,
    on_revoke: ?PartitionsFn = null,
};

/// The records of one partition handed to a batch handler.
pub const BatchView = struct {
    topic: []const u8,
    partition: i32,
    recs: []const records.Record,
    high_watermark: i64,
};

/// What a batch handler answers: processed, or deliver the same records
/// again after `retry` milliseconds.
pub const BatchAnswer = union(enum) { done, retry: u32 };

/// Runs on the partition's delivery task; may wait for the answer. A
/// cancel (the session ended and the rebalance timeout passed) leaves the
/// batch unprocessed.
pub const BatchHandlerFn = *const fn (context: ?*anyopaque, batch: *const BatchView) std.Io.Cancelable!BatchAnswer;
pub const PartitionsFn = *const fn (context: ?*anyopaque, parts: []const protocol.TopicPartition) void;

pub const HandlerFn = *const fn (context: ?*anyopaque, msg: *Msg) anyerror!void;

/// What a consumer needs from its client.
pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cluster: *cluster_mod.Cluster,
    producer: *producer_mod.Producer,
    tel: ?*const Telemetry = null,
};

// ---------------------------------------------------------------------------
// Assignors (pure)

pub const MemberSub = struct { member_id: []const u8, topics: []const []const u8 };
pub const TopicParts = struct { topic: []const u8, count: u32 };

fn subscribed(m: MemberSub, topic: []const u8) bool {
    for (m.topics) |t| if (std.mem.eql(u8, t, topic)) return true;
    return false;
}

/// Assignments, one list per member of `members` sorted by member id (the
/// order the result is in; `sorted_ids` receives the ids in that order).
pub fn assign(arena: std.mem.Allocator, kind: Assignor, members_in: []const MemberSub, topics_in: []const TopicParts) ![]std.ArrayList(protocol.TopicPartition) {
    const members = try arena.dupe(MemberSub, members_in);
    std.mem.sort(MemberSub, members, {}, struct {
        fn lt(_: void, a: MemberSub, b: MemberSub) bool {
            return std.mem.lessThan(u8, a.member_id, b.member_id);
        }
    }.lt);
    const topics = try arena.dupe(TopicParts, topics_in);
    std.mem.sort(TopicParts, topics, {}, struct {
        fn lt(_: void, a: TopicParts, b: TopicParts) bool {
            return std.mem.lessThan(u8, a.topic, b.topic);
        }
    }.lt);
    const out = try arena.alloc(std.ArrayList(protocol.TopicPartition), members.len);
    for (out) |*l| l.* = .empty;
    switch (kind) {
        .range => for (topics) |t| {
            var subs: std.ArrayList(usize) = .empty;
            for (members, 0..) |m, i| if (subscribed(m, t.topic)) try subs.append(arena, i);
            if (subs.items.len == 0) continue;
            const per = t.count / @as(u32, @intCast(subs.items.len));
            const extra = t.count % @as(u32, @intCast(subs.items.len));
            var next: u32 = 0;
            for (subs.items, 0..) |mi, k| {
                const n = per + @as(u32, if (k < extra) 1 else 0);
                for (next..next + n) |p| try out[mi].append(arena, .{ .topic = t.topic, .partition = @intCast(p) });
                next += n;
            }
        },
        .roundrobin => {
            var cursor: usize = 0;
            for (topics) |t| {
                for (0..t.count) |p| {
                    var tries: usize = 0;
                    while (tries < members.len) : (tries += 1) {
                        const mi = (cursor + tries) % members.len;
                        if (!subscribed(members[mi], t.topic)) continue;
                        try out[mi].append(arena, .{ .topic = t.topic, .partition = @intCast(p) });
                        cursor = mi + 1;
                        break;
                    }
                }
            }
        },
    }
    return out;
}

// ---------------------------------------------------------------------------
// State

const RespArena = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(1),

    fn create(gpa: std.mem.Allocator) !*RespArena {
        const r = try gpa.create(RespArena);
        r.* = .{ .gpa = gpa, .arena = .init(gpa) };
        return r;
    }
    fn retain(r: *RespArena) void {
        _ = r.refs.fetchAdd(1, .monotonic);
    }
    fn release(r: *RespArena) void {
        if (r.refs.fetchSub(1, .acq_rel) == 1) {
            r.arena.deinit();
            r.gpa.destroy(r);
        }
    }
};

const Chunk = struct {
    resp: *RespArena,
    recs: []records.Record,
    idx: usize = 0,
    size: usize,
};

const PartState = struct {
    topic: []const u8,
    partition: i32,
    leader: i32 = -1,
    /// Over `chunks` and `buffered`: the fetcher appends, the delivery task
    /// takes (L1: they run on different executors). Nothing waits, calls
    /// out or takes another lock while it is held (L2-L4).
    mutex: safety.Mutex(.leaf) = .init,
    cond: safety.Condition = .init,
    chunks: std.ArrayList(*Chunk) = .empty,
    buffered: usize = 0,
    /// The next offset to fetch (the fetcher's).
    fetch_offset: i64 = -1,
    /// The offset after the last record the handler finished.
    processed: std.atomic.Value(i64) = .init(-1),
    /// The last offset committed (the heartbeat task's).
    committed: i64 = -1,
    high_watermark: std.atomic.Value(i64) = .init(-1),
};

const LeaderGroup = struct {
    id: i32,
    conn: *Conn,
    parts: []*PartState,
};

const Member = struct {
    consumer: *Consumer,
    index: usize,
    wake: std.Io.Event = .unset,
    member_id: std.ArrayList(u8) = .empty,
    coord: ?*Conn = null,
};

const Session = struct {
    consumer: *Consumer,
    member: *Member,
    arena_state: std.heap.ArenaAllocator,
    generation: i32 = -1,
    parts: []*PartState = &.{},
    leaders: []LeaderGroup = &.{},
    stop: std.atomic.Value(bool) = .init(false),
    rejoin: std.atomic.Value(bool) = .init(false),
    reset_member: std.atomic.Value(bool) = .init(false),
    stale_coord: std.atomic.Value(bool) = .init(false),
    fatal: std.atomic.Value(bool) = .init(false),
    group: std.Io.Group = .init,
    deliveries: std.Io.Group = .init,
    /// Over `running`: the delivery tasks (one per partition, each on its
    /// partition's executor) and `endSession`. A leaf (L4).
    mutex: safety.Mutex(.leaf) = .init,
    cond: safety.Condition = .init,
    running: usize = 0,

    /// Ends the session at the member's next look.
    fn rebalance(s: *Session) void {
        s.rejoin.store(true, .release);
        s.member.wake.set(s.consumer.host.io);
    }
};

pub const Consumer = struct {
    host: Host,
    opts: ConsumeOptions,
    handler: HandlerFn,
    context: ?*anyopaque,
    arena: std.heap.ArenaAllocator,
    group: std.Io.Group = .init,
    members: []Member = &.{},
    stopping: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    active: std.atomic.Value(u32) = .init(0),

    /// Copies the options (so the caller's strings need not outlive it).
    pub fn create(host: Host, opts: ConsumeOptions, handler: HandlerFn, context: ?*anyopaque) !*Consumer {
        const c = try host.gpa.create(Consumer);
        errdefer host.gpa.destroy(c);
        c.* = .{ .host = host, .opts = opts, .handler = handler, .context = context, .arena = .init(host.gpa) };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.opts.group = try a.dupe(u8, opts.group);
        const topics = try a.alloc([]const u8, opts.topics.len);
        for (opts.topics, topics) |t, *o| o.* = try a.dupe(u8, t);
        c.opts.topics = topics;
        if (opts.instance_id) |i| c.opts.instance_id = try a.dupe(u8, i);
        if (opts.dead_letter) |d| c.opts.dead_letter = try a.dupe(u8, d);
        if (opts.members == 0) return error.InvalidOptions;
        try opts.retry.validate();
        return c;
    }

    pub fn destroy(c: *Consumer) void {
        c.group.cancel(c.host.io);
        for (c.members) |*m| {
            m.member_id.deinit(c.host.gpa);
            if (m.coord) |k| k.close();
        }
        c.host.gpa.free(c.members);
        const gpa = c.host.gpa;
        c.arena.deinit();
        gpa.destroy(c);
    }

    /// Joins the group: spawns the member tasks.
    pub fn start(c: *Consumer) !void {
        if (c.started) return;
        c.started = true;
        c.members = try c.host.gpa.alloc(Member, c.opts.members);
        for (c.members, 0..) |*m, i| m.* = .{ .consumer = c, .index = i };
        for (c.members) |*m| {
            _ = c.active.fetchAdd(1, .acq_rel);
            placement.concurrent(&c.group, c.host.io, .{ .executor = m.index }, memberMain, .{m}) catch {
                _ = c.active.fetchSub(1, .acq_rel);
                return error.OutOfMemory;
            };
            test_hold.testHold(c.host.io, .member_spawned);
        }
    }

    /// Asks the members to finish: records in flight finish, offsets are
    /// committed, the group is left. Returns at once; `join` waits.
    pub fn stop(c: *Consumer) void {
        c.stopping.store(true, .release);
        for (c.members) |*m| m.wake.set(c.host.io);
    }

    /// Waits for the members to be gone, until `deadline`; then cancels.
    pub fn join(c: *Consumer, deadline: Timestamp) void {
        const io = c.host.io;
        while (c.active.load(.acquire) > 0 and Timestamp.now(io, .awake).compare(.lt, deadline)) {
            io.sleep(.fromMilliseconds(10), .awake) catch break;
        }
        c.group.cancel(io);
    }

    fn instanceFor(c: *Consumer, m: *const Member, buf: []u8) ?[]const u8 {
        const base = c.opts.instance_id orelse return null;
        if (c.opts.members == 1) return base;
        return std.fmt.bufPrint(buf, "{s}-{d}", .{ base, m.index }) catch base;
    }
};

fn memberMain(m: *Member) std.Io.Cancelable!void {
    const c = m.consumer;
    defer _ = c.active.fetchSub(1, .acq_rel);
    const io = c.host.io;
    var failures: u32 = 0;
    while (!c.stopping.load(.acquire)) {
        runSession(m) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Rebalance => {
                // Another member joined: join again at once.
                failures = 0;
                continue;
            },
            error.Fenced => {
                log.err("kafka group {s}: this member's instance id is in use by another member (FENCED_INSTANCE_ID); stopping it", .{c.opts.group});
                return;
            },
            else => {
                failures += 1;
                log.warn("kafka group {s}: session failed: {t}", .{ c.opts.group, err });
                const wait: i64 = @min(@as(i64, 200) << @intCast(@min(failures, 5)), 10_000);
                io.sleep(.fromMilliseconds(wait), .awake) catch return error.Canceled;
                continue;
            },
        };
        failures = 0;
    }
    leaveGroup(m);
}

fn leaveGroup(m: *Member) void {
    const c = m.consumer;
    // A static member keeps its place for the session timeout.
    var ibuf: [128]u8 = undefined;
    if (c.instanceFor(m, &ibuf) != null) return;
    const coord = m.coord orelse return;
    if (m.member_id.items.len == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(c.host.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e: protocol.Enc = .init(arena);
    protocol.encodeLeaveGroup(&e, c.opts.group, m.member_id.items, null) catch return;
    // Swallows a cancel (C3): the consumer retrofit's (step 9), not covered by step 4.
    _ = coord.call(arena, .leave_group, e.bytesWritten(), .fromSeconds(5)) catch {};
}

const SessionError = error{
    Fenced,
    CoordinatorUnavailable,
    NoLeader,
    GroupError,
    Rebalance,
} || cluster_mod.ConnError || std.mem.Allocator.Error;

fn runSession(m: *Member) (SessionError || error{ InvalidOptions, ConcurrencyUnavailable })!void {
    const c = m.consumer;
    const host = c.host;
    const io = host.io;
    var sess: Session = .{ .consumer = c, .member = m, .arena_state = .init(host.gpa) };
    defer sess.arena_state.deinit();
    const arena = sess.arena_state.allocator();
    var ibuf: [128]u8 = undefined;
    const instance = c.instanceFor(m, &ibuf);

    if (m.coord == null or sess.stale_coord.load(.acquire)) {
        if (m.coord) |k| k.close();
        m.coord = null;
        m.coord = try findCoordinator(c, arena);
    }
    const coord = m.coord.?;

    // ---- join and sync
    var tmp_state: std.heap.ArenaAllocator = .init(host.gpa);
    defer tmp_state.deinit();
    const tmp = tmp_state.allocator();
    var join_attempts: u32 = 0;
    const joined: protocol.Joined = while (true) : (join_attempts += 1) {
        if (c.stopping.load(.acquire)) return;
        if (join_attempts > 30) return error.GroupError;
        _ = tmp_state.reset(.retain_capacity);
        var sub: protocol.Enc = .init(tmp);
        try protocol.encodeSubscription(&sub, c.opts.topics);
        var e: protocol.Enc = .init(tmp);
        try protocol.encodeJoinGroup(
            &e,
            c.opts.group,
            msOf(c.opts.session_timeout),
            msOf(c.opts.rebalance_timeout),
            m.member_id.items,
            instance,
            &.{.{ .name = @tagName(c.opts.assignor), .metadata = sub.bytesWritten() }},
        );
        const wait: Duration = .fromMilliseconds(@as(i64, msOf(c.opts.rebalance_timeout)) + 15_000);
        const body = coord.call(tmp, .join_group, e.bytesWritten(), wait) catch |err| {
            if (err == error.Canceled) return err;
            m.coord.?.close();
            m.coord = null;
            return err;
        };
        const j = protocol.decodeJoinGroup(arena, body) catch return error.ProtocolError;
        switch (j.error_code) {
            protocol.none => break j,
            protocol.member_id_required => {
                m.member_id.clearRetainingCapacity();
                try m.member_id.appendSlice(host.gpa, j.member_id);
            },
            protocol.unknown_member_id => m.member_id.clearRetainingCapacity(),
            protocol.fenced_instance_id => return error.Fenced,
            protocol.coordinator_load_in_progress, protocol.coordinator_not_available, protocol.not_coordinator, protocol.rebalance_in_progress => {
                if (j.error_code == protocol.not_coordinator or j.error_code == protocol.coordinator_not_available) {
                    m.coord.?.close();
                    m.coord = null;
                    return error.CoordinatorUnavailable;
                }
                io.sleep(.fromMilliseconds(300), .awake) catch return error.Canceled;
            },
            else => {
                log.warn("kafka group {s}: JoinGroup: {s}", .{ c.opts.group, protocol.errorName(j.error_code) });
                return error.GroupError;
            },
        }
    };
    m.member_id.clearRetainingCapacity();
    try m.member_id.appendSlice(host.gpa, joined.member_id);
    sess.generation = joined.generation;
    const is_leader = std.mem.eql(u8, joined.leader, joined.member_id);

    var assignments: []const protocol.SyncAssignment = &.{};
    if (is_leader) assignments = try computeAssignments(c, arena, joined);
    {
        var e: protocol.Enc = .init(tmp);
        try protocol.encodeSyncGroup(&e, c.opts.group, joined.generation, joined.member_id, instance, assignments);
        const wait: Duration = .fromMilliseconds(@as(i64, msOf(c.opts.rebalance_timeout)) + 15_000);
        const body = coord.call(tmp, .sync_group, e.bytesWritten(), wait) catch |err| {
            if (err == error.Canceled) return err;
            m.coord.?.close();
            m.coord = null;
            return err;
        };
        const s = protocol.decodeSyncGroup(arena, body) catch return error.ProtocolError;
        switch (s.error_code) {
            protocol.none => {},
            protocol.rebalance_in_progress, protocol.illegal_generation => return error.Rebalance,
            protocol.unknown_member_id => {
                m.member_id.clearRetainingCapacity();
                return error.Rebalance;
            },
            protocol.fenced_instance_id => return error.Fenced,
            else => {
                log.warn("kafka group {s}: SyncGroup: {s}", .{ c.opts.group, protocol.errorName(s.error_code) });
                return error.GroupError;
            },
        }
        const assigned = protocol.decodeAssignment(arena, s.assignment) catch return error.ProtocolError;
        try setUpPartitions(&sess, assigned);
    }
    if (host.tel) |t| t.rebalanced(c.opts.group);
    log.info("kafka group {s}: member {s} joined generation {d} with {d} partitions", .{ c.opts.group, m.member_id.items, sess.generation, sess.parts.len });

    // ---- positions
    defer closeLeaders(&sess);
    try openLeaders(&sess, arena);
    try initialOffsets(&sess, arena, coord);

    // ---- run
    if (c.opts.on_assign) |f| if (sess.parts.len > 0) {
        const tps = try arena.alloc(protocol.TopicPartition, sess.parts.len);
        for (sess.parts, tps) |ps, *o| o.* = .{ .topic = ps.topic, .partition = ps.partition };
        f(c.context, tps);
    };
    runTasks(&sess) catch |err| {
        sess.stop.store(true, .release);
        endSession(&sess);
        return err;
    };
    while (true) {
        m.wake.wait(io) catch |err| {
            sess.stop.store(true, .release);
            endSession(&sess);
            return err;
        };
        m.wake.reset();
        if (c.stopping.load(.acquire) or sess.rejoin.load(.acquire) or sess.fatal.load(.acquire)) break;
    }
    sess.stop.store(true, .release);
    endSession(&sess);
    if (sess.reset_member.load(.acquire)) m.member_id.clearRetainingCapacity();
    if (sess.stale_coord.load(.acquire)) {
        if (m.coord) |k| k.close();
        m.coord = null;
    }
    if (sess.fatal.load(.acquire)) return error.Fenced;
}

fn msOf(d: Duration) i32 {
    return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_ms));
}

fn findCoordinator(c: *Consumer, arena: std.mem.Allocator) SessionError!*Conn {
    const host = c.host;
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        if (attempts > 20) return error.CoordinatorUnavailable;
        const any = try host.cluster.connectAny();
        defer any.close();
        var e: protocol.Enc = .init(arena);
        try protocol.encodeFindCoordinator(&e, c.opts.group);
        const body = try any.call(arena, .find_coordinator, e.bytesWritten(), host.cluster.settings.request_timeout);
        const fc = protocol.decodeFindCoordinator(arena, body) catch return error.ProtocolError;
        switch (fc.error_code) {
            protocol.none => {
                const port: u16 = std.math.cast(u16, fc.port) orelse return error.CoordinatorUnavailable;
                return Conn.open(host.gpa, host.io, host.cluster.settings, fc.host, port, fc.node_id);
            },
            protocol.coordinator_load_in_progress, protocol.coordinator_not_available => {
                host.io.sleep(.fromMilliseconds(500), .awake) catch return error.Canceled;
            },
            else => {
                log.warn("kafka group {s}: FindCoordinator: {s}", .{ c.opts.group, protocol.errorName(fc.error_code) });
                return error.CoordinatorUnavailable;
            },
        }
    }
}

/// The leader's part: assigns the partitions of every subscribed topic.
fn computeAssignments(c: *Consumer, arena: std.mem.Allocator, joined: protocol.Joined) SessionError![]const protocol.SyncAssignment {
    const host = c.host;
    const subs = try arena.alloc(MemberSub, joined.members.len);
    var all_topics: std.ArrayList([]const u8) = .empty;
    for (joined.members, subs) |jm, *s| {
        const topics = protocol.decodeSubscription(arena, jm.metadata) catch return error.ProtocolError;
        s.* = .{ .member_id = jm.member_id, .topics = topics };
        for (topics) |t| {
            var seen = false;
            for (all_topics.items) |x| if (std.mem.eql(u8, x, t)) {
                seen = true;
                break;
            };
            if (!seen) try all_topics.append(arena, t);
        }
    }
    try host.cluster.refresh(all_topics.items, false);
    var parts: std.ArrayList(TopicParts) = .empty;
    for (all_topics.items) |t| {
        const n = (try host.cluster.partitionCount(t)) orelse {
            log.warn("kafka group {s}: topic {s} does not exist (yet); no partitions assigned for it", .{ c.opts.group, t });
            continue;
        };
        try parts.append(arena, .{ .topic = t, .count = n });
    }
    const assigned = try assign(arena, c.opts.assignor, subs, parts.items);
    // `assign` sorts members by id; so do we, to pair them up.
    const sorted = try arena.dupe(MemberSub, subs);
    std.mem.sort(MemberSub, sorted, {}, struct {
        fn lt(_: void, a: MemberSub, b: MemberSub) bool {
            return std.mem.lessThan(u8, a.member_id, b.member_id);
        }
    }.lt);
    const out = try arena.alloc(protocol.SyncAssignment, sorted.len);
    for (sorted, assigned, out) |s, list, *o| {
        var e: protocol.Enc = .init(arena);
        try protocol.encodeAssignment(&e, list.items);
        o.* = .{ .member_id = s.member_id, .assignment = e.bytesWritten() };
    }
    return out;
}

fn setUpPartitions(sess: *Session, assigned: []const protocol.TopicPartition) !void {
    const arena = sess.arena_state.allocator();
    const parts = try arena.alloc(*PartState, assigned.len);
    for (assigned, parts) |tp, *p| {
        const ps = try arena.create(PartState);
        ps.* = .{ .topic = tp.topic, .partition = tp.partition };
        p.* = ps;
    }
    sess.parts = parts;
}

/// Connects to each partition leader of the assignment.
fn openLeaders(sess: *Session, arena: std.mem.Allocator) SessionError!void {
    const c = sess.consumer;
    const cl = c.host.cluster;
    if (sess.parts.len == 0) return;
    var topics: std.ArrayList([]const u8) = .empty;
    for (sess.parts) |ps| {
        var seen = false;
        for (topics.items) |t| if (std.mem.eql(u8, t, ps.topic)) {
            seen = true;
            break;
        };
        if (!seen) try topics.append(arena, ps.topic);
    }
    try cl.refresh(topics.items, false);
    for (sess.parts) |ps| ps.leader = cl.leader(ps.topic, ps.partition) orelse return error.NoLeader;
    var groups: std.ArrayList(LeaderGroup) = .empty;
    errdefer for (groups.items) |g| g.conn.close();
    for (sess.parts) |ps| {
        var found = false;
        for (groups.items) |g| if (g.id == ps.leader) {
            found = true;
            break;
        };
        if (found) continue;
        const conn = try cl.connectBroker(ps.leader);
        errdefer conn.close();
        var members: std.ArrayList(*PartState) = .empty;
        for (sess.parts) |q| if (q.leader == ps.leader) try members.append(arena, q);
        try groups.append(arena, .{ .id = ps.leader, .conn = conn, .parts = members.items });
    }
    sess.leaders = groups.items;
}

fn closeLeaders(sess: *Session) void {
    for (sess.leaders) |g| g.conn.close();
    sess.leaders = &.{};
}

fn initialOffsets(sess: *Session, arena: std.mem.Allocator, coord: *Conn) SessionError!void {
    const c = sess.consumer;
    if (sess.parts.len == 0) return;
    const tps = try arena.alloc(protocol.TopicPartition, sess.parts.len);
    for (sess.parts, tps) |ps, *tp| tp.* = .{ .topic = ps.topic, .partition = ps.partition };
    std.mem.sort(protocol.TopicPartition, tps, {}, struct {
        fn lt(_: void, a: protocol.TopicPartition, b: protocol.TopicPartition) bool {
            return switch (std.mem.order(u8, a.topic, b.topic)) {
                .lt => true,
                .gt => false,
                .eq => a.partition < b.partition,
            };
        }
    }.lt);
    var attempts: u32 = 0;
    const fetched = while (true) : (attempts += 1) {
        var e: protocol.Enc = .init(arena);
        try protocol.encodeOffsetFetch(&e, c.opts.group, tps);
        const body = try coord.call(arena, .offset_fetch, e.bytesWritten(), c.host.cluster.settings.request_timeout);
        const r = protocol.decodeOffsetFetch(arena, body) catch return error.ProtocolError;
        var retry = r.error_code == protocol.coordinator_load_in_progress;
        for (r.offsets) |o| if (o.error_code == protocol.coordinator_load_in_progress) {
            retry = true;
        };
        if (retry and attempts < 20) {
            c.host.io.sleep(.fromMilliseconds(300), .awake) catch return error.Canceled;
            continue;
        }
        if (r.error_code != 0) {
            log.warn("kafka group {s}: OffsetFetch: {s}", .{ c.opts.group, protocol.errorName(r.error_code) });
            return error.GroupError;
        }
        break r.offsets;
    };
    for (sess.parts) |ps| {
        var offset: i64 = -1;
        for (fetched) |o| if (o.partition == ps.partition and std.mem.eql(u8, o.topic, ps.topic) and o.error_code == 0) {
            offset = o.offset;
        };
        if (offset < 0) {
            const g = for (sess.leaders) |g| {
                if (g.id == ps.leader) break g;
            } else return error.NoLeader;
            offset = try listOffset(c, arena, g.conn, ps, c.opts.start == .earliest);
        }
        ps.fetch_offset = offset;
        ps.processed.store(offset, .release);
        ps.committed = if (offset >= 0) offset else -1;
    }
}

fn listOffset(c: *Consumer, arena: std.mem.Allocator, conn: *Conn, ps: *PartState, earliest: bool) SessionError!i64 {
    var e: protocol.Enc = .init(arena);
    try protocol.encodeListOffsets(&e, &.{.{ .topic = ps.topic, .partition = ps.partition, .timestamp = if (earliest) -2 else -1 }});
    const body = try conn.call(arena, .list_offsets, e.bytesWritten(), c.host.cluster.settings.request_timeout);
    const r = protocol.decodeListOffsets(arena, body) catch return error.ProtocolError;
    if (r.len == 0 or r[0].error_code != 0) {
        log.warn("kafka group {s}: ListOffsets {s}/{d}: {s}", .{ c.opts.group, ps.topic, ps.partition, if (r.len > 0) protocol.errorName(r[0].error_code) else "no answer" });
        return error.GroupError;
    }
    return r[0].offset;
}

fn runTasks(sess: *Session) !void {
    const c = sess.consumer;
    const io = c.host.io;
    for (sess.parts) |ps| {
        sess.mutex.lockUncancelable(io);
        sess.running += 1;
        sess.mutex.unlock(io);
        placement.concurrent(&sess.deliveries, io, .{ .executor = @intCast(ps.partition) }, deliverLoop, .{ sess, ps }) catch {
            sess.mutex.lockUncancelable(io);
            sess.running -= 1;
            sess.mutex.unlock(io);
            return error.OutOfMemory;
        };
    }
    for (sess.leaders) |*g| {
        placement.concurrent(&sess.group, io, .{ .executor = @intCast(@max(g.id, 0)) }, fetchLoop, .{ sess, g }) catch return error.OutOfMemory;
    }
    placement.concurrent(&sess.group, io, .{ .executor = sess.member.index }, heartbeatLoop, .{sess}) catch return error.OutOfMemory;
}

/// Stops fetching and heartbeating, lets the deliveries finish their
/// record, commits, and joins every task.
fn endSession(sess: *Session) void {
    const c = sess.consumer;
    const io = c.host.io;
    if (c.opts.on_revoke) |f| if (sess.parts.len > 0) {
        if (sess.arena_state.allocator().alloc(protocol.TopicPartition, sess.parts.len)) |tps| {
            for (sess.parts, tps) |ps, *o| o.* = .{ .topic = ps.topic, .partition = ps.partition };
            f(c.context, tps);
        } else |_| {}
    };
    sess.group.cancel(io);
    for (sess.parts) |ps| {
        ps.mutex.lockUncancelable(io);
        ps.cond.broadcast(io);
        ps.mutex.unlock(io);
    }
    const until: Timestamp = Timestamp.now(io, .awake).addDuration(.{ .raw = c.opts.rebalance_timeout, .clock = .awake });
    sess.mutex.lockUncancelable(io);
    while (sess.running > 0) {
        sess.cond.waitTimeout(io, &sess.mutex, .{ .deadline = until }) catch |err| switch (err) {
            error.Timeout => break,
            error.Canceled => {
                io.recancel();
                break;
            },
        };
    }
    const stuck = sess.running > 0;
    sess.mutex.unlock(io);
    if (stuck) log.warn("kafka group {s}: a handler did not finish within the rebalance timeout; canceling it", .{c.opts.group});
    sess.deliveries.cancel(io);
    // Free what was fetched and not delivered.
    for (sess.parts) |ps| {
        for (ps.chunks.items) |ch| {
            ch.resp.release();
            c.host.gpa.destroy(ch);
        }
        ps.chunks.deinit(c.host.gpa);
        ps.chunks = .empty;
    }
    if (sess.member.coord) |coord| {
        var arena_state: std.heap.ArenaAllocator = .init(c.host.gpa);
        defer arena_state.deinit();
        commit(sess, arena_state.allocator(), coord) catch |err| log.debug("kafka group {s}: final commit failed: {t}", .{ c.opts.group, err });
    }
}

fn commit(sess: *Session, arena: std.mem.Allocator, coord: *Conn) !void {
    const c = sess.consumer;
    var list: std.ArrayList(protocol.CommitPartition) = .empty;
    for (sess.parts) |ps| {
        const p = ps.processed.load(.acquire);
        if (p >= 0 and p > ps.committed) try list.append(arena, .{ .topic = ps.topic, .partition = ps.partition, .offset = p });
    }
    if (list.items.len == 0) return;
    std.mem.sort(protocol.CommitPartition, list.items, {}, struct {
        fn lt(_: void, a: protocol.CommitPartition, b: protocol.CommitPartition) bool {
            return switch (std.mem.order(u8, a.topic, b.topic)) {
                .lt => true,
                .gt => false,
                .eq => a.partition < b.partition,
            };
        }
    }.lt);
    var ibuf: [128]u8 = undefined;
    var e: protocol.Enc = .init(arena);
    try protocol.encodeOffsetCommit(&e, c.opts.group, sess.generation, sess.member.member_id.items, c.instanceFor(sess.member, &ibuf), list.items);
    const body = try coord.call(arena, .offset_commit, e.bytesWritten(), c.host.cluster.settings.request_timeout);
    const results = protocol.decodeOffsetCommit(arena, body) catch return error.ProtocolError;
    for (results) |r| {
        if (r.error_code == 0) {
            for (sess.parts) |ps| if (ps.partition == r.partition and std.mem.eql(u8, ps.topic, r.topic)) {
                for (list.items) |l| if (l.partition == r.partition and std.mem.eql(u8, l.topic, r.topic)) {
                    ps.committed = l.offset;
                };
            };
        } else switch (r.error_code) {
            protocol.rebalance_in_progress, protocol.illegal_generation, protocol.unknown_member_id => {},
            else => log.warn("kafka group {s}: OffsetCommit {s}/{d}: {s}", .{ c.opts.group, r.topic, r.partition, protocol.errorName(r.error_code) }),
        }
    }
}

// ---------------------------------------------------------------------------
// Tasks

fn heartbeatLoop(sess: *Session) std.Io.Cancelable!void {
    const c = sess.consumer;
    const io = c.host.io;
    const coord = sess.member.coord orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(c.host.gpa);
    defer arena_state.deinit();
    var last_commit: Timestamp = .now(io, .awake);
    var ibuf: [128]u8 = undefined;
    while (!sess.stop.load(.acquire)) {
        try io.sleep(c.opts.heartbeat_interval, .awake);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var e: protocol.Enc = .init(arena);
        protocol.encodeHeartbeat(&e, c.opts.group, sess.generation, sess.member.member_id.items, c.instanceFor(sess.member, &ibuf)) catch return;
        const body = coord.call(arena, .heartbeat, e.bytesWritten(), c.host.cluster.settings.request_timeout) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.debug("kafka group {s}: heartbeat failed: {t}", .{ c.opts.group, err });
            sess.stale_coord.store(true, .release);
            sess.rebalance();
            return;
        };
        const ec = protocol.decodeSimpleError(body) catch 0;
        switch (ec) {
            protocol.none => {},
            protocol.rebalance_in_progress, protocol.illegal_generation => {
                sess.rebalance();
                return;
            },
            protocol.unknown_member_id => {
                sess.reset_member.store(true, .release);
                sess.rebalance();
                return;
            },
            protocol.not_coordinator, protocol.coordinator_not_available, protocol.coordinator_load_in_progress => {
                sess.stale_coord.store(true, .release);
                sess.rebalance();
                return;
            },
            protocol.fenced_instance_id => {
                sess.fatal.store(true, .release);
                sess.rebalance();
                return;
            },
            else => log.warn("kafka group {s}: Heartbeat: {s}", .{ c.opts.group, protocol.errorName(ec) }),
        }
        if (c.host.tel) |t| for (sess.parts) |ps| {
            const hw = ps.high_watermark.load(.acquire);
            if (hw >= 0) t.setLag(c.opts.group, ps.topic, ps.partition, @max(0, hw - ps.processed.load(.acquire)));
        };
        if (!Timestamp.now(io, .awake).compare(.lt, last_commit.addDuration(.{ .raw = c.opts.commit_interval, .clock = .awake }))) {
            commit(sess, arena, coord) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                log.debug("kafka group {s}: commit failed: {t}", .{ c.opts.group, err });
            };
            last_commit = .now(io, .awake);
        }
    }
}

fn fetchLoop(sess: *Session, g: *LeaderGroup) std.Io.Cancelable!void {
    fetchLoopInner(sess, g) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            log.warn("kafka group {s}: fetch from broker {d} failed: {t}", .{ sess.consumer.opts.group, g.id, err });
            sess.rebalance();
        },
    };
}

fn fetchLoopInner(sess: *Session, g: *LeaderGroup) !void {
    const c = sess.consumer;
    const io = c.host.io;
    const gpa = c.host.gpa;
    var req_arena: std.heap.ArenaAllocator = .init(gpa);
    defer req_arena.deinit();
    const max_wait_ms: i32 = 500;
    while (!sess.stop.load(.acquire)) {
        _ = req_arena.reset(.retain_capacity);
        const ra = req_arena.allocator();
        var want: std.ArrayList(protocol.FetchPartition) = .empty;
        for (g.parts) |ps| {
            ps.mutex.lockUncancelable(io);
            const room = ps.buffered < c.opts.prefetch_bytes;
            ps.mutex.unlock(io);
            if (room) try want.append(ra, .{ .topic = ps.topic, .partition = ps.partition, .offset = ps.fetch_offset, .max_bytes = @intCast(c.opts.prefetch_bytes) });
        }
        if (want.items.len == 0) {
            try io.sleep(.fromMilliseconds(30), .awake);
            continue;
        }
        std.mem.sort(protocol.FetchPartition, want.items, {}, struct {
            fn lt(_: void, a: protocol.FetchPartition, b: protocol.FetchPartition) bool {
                return std.mem.lessThan(u8, a.topic, b.topic);
            }
        }.lt);
        var e: protocol.Enc = .init(ra);
        const total: i64 = @min(@as(i64, 50 * 1024 * 1024), @as(i64, c.opts.prefetch_bytes) * @as(i64, @intCast(want.items.len)));
        try protocol.encodeFetch(&e, max_wait_ms, 1, @intCast(total), want.items);
        const resp = try RespArena.create(gpa);
        defer resp.release();
        const timeout: Duration = .fromMilliseconds(@as(i64, max_wait_ms) + @as(i64, msOf(c.host.cluster.settings.request_timeout)));
        const body = try g.conn.call(resp.arena.allocator(), .fetch, e.bytesWritten(), timeout);
        const fr = protocol.decodeFetch(resp.arena.allocator(), body) catch return error.ProtocolError;
        if (fr.error_code != 0) return error.GroupError;
        for (fr.partitions) |fp| {
            const ps = for (g.parts) |q| {
                if (q.partition == fp.partition and std.mem.eql(u8, q.topic, fp.topic)) break q;
            } else continue;
            switch (fp.error_code) {
                protocol.none => {},
                protocol.offset_out_of_range => {
                    const off = try listOffset(c, ra, g.conn, ps, c.opts.start == .earliest);
                    log.warn("kafka group {s}: {s}/{d}: offset {d} is out of range; continuing at {d}", .{ c.opts.group, ps.topic, ps.partition, ps.fetch_offset, off });
                    ps.fetch_offset = off;
                    ps.processed.store(off, .release);
                    continue;
                },
                protocol.not_leader_or_follower, protocol.unknown_topic_or_partition, protocol.leader_not_available, 9, 74, 75 => {
                    c.host.cluster.invalidate(ps.topic);
                    sess.rebalance();
                    return;
                },
                else => {
                    log.warn("kafka group {s}: Fetch {s}/{d}: {s}", .{ c.opts.group, ps.topic, ps.partition, protocol.errorName(fp.error_code) });
                    try io.sleep(.fromSeconds(1), .awake);
                    continue;
                },
            }
            ps.high_watermark.store(fp.high_watermark, .release);
            if (fp.records.len == 0) continue;
            const decoded = records.decode(resp.arena.allocator(), fp.records, ps.fetch_offset, 64 * 1024 * 1024) catch |err| {
                log.err("kafka group {s}: {s}/{d}: cannot decode the records at offset {d}: {t}", .{ c.opts.group, ps.topic, ps.partition, ps.fetch_offset, err });
                try io.sleep(.fromSeconds(1), .awake);
                continue;
            };
            if (decoded.records.len > 0) {
                const chunk = try gpa.create(Chunk);
                resp.retain();
                chunk.* = .{ .resp = resp, .recs = decoded.records, .size = fp.records.len };
                ps.mutex.lockUncancelable(io);
                ps.chunks.append(gpa, chunk) catch {
                    ps.mutex.unlock(io);
                    resp.release();
                    gpa.destroy(chunk);
                    return error.OutOfMemory;
                };
                ps.buffered += chunk.size;
                ps.cond.signal(io);
                ps.mutex.unlock(io);
            }
            if (decoded.next_offset) |n| ps.fetch_offset = @max(ps.fetch_offset, n);
        }
    }
}

fn deliverLoop(sess: *Session, ps: *PartState) std.Io.Cancelable!void {
    const c = sess.consumer;
    const io = c.host.io;
    defer {
        sess.mutex.lockUncancelable(io);
        sess.running -= 1;
        sess.cond.broadcast(io);
        sess.mutex.unlock(io);
    }
    var scratch: std.heap.ArenaAllocator = .init(c.host.gpa);
    defer scratch.deinit();
    while (true) {
        ps.mutex.lockUncancelable(io);
        while (ps.chunks.items.len == 0 and !sess.stop.load(.acquire)) {
            ps.cond.wait(io, &ps.mutex) catch |err| {
                ps.mutex.unlock(io);
                return err;
            };
        }
        if (sess.stop.load(.acquire)) {
            ps.mutex.unlock(io);
            return;
        }
        const chunk = ps.chunks.items[0];
        ps.mutex.unlock(io);
        if (c.opts.batch_handler) |bh| {
            const remaining = chunk.recs[chunk.idx..];
            const n = @min(remaining.len, @max(c.opts.max_batch, 1));
            const view: BatchView = .{
                .topic = ps.topic,
                .partition = ps.partition,
                .recs = remaining[0..n],
                .high_watermark = ps.high_watermark.load(.acquire),
            };
            switch (try bh(c.context, &view)) {
                .retry => |delay_ms| {
                    try io.sleep(.fromMilliseconds(delay_ms), .awake);
                    continue;
                },
                .done => {},
            }
            ps.mutex.lockUncancelable(io);
            chunk.idx += n;
            ps.processed.store(remaining[n - 1].offset + 1, .release);
            if (chunk.idx >= chunk.recs.len) {
                _ = ps.chunks.orderedRemove(0);
                ps.buffered -|= chunk.size;
                ps.mutex.unlock(io);
                chunk.resp.release();
                c.host.gpa.destroy(chunk);
            } else ps.mutex.unlock(io);
            if (c.host.tel) |t| for (0..n) |_| t.consumedOne(c.opts.group, ps.topic);
            continue;
        }
        const rec = chunk.recs[chunk.idx];

        _ = scratch.reset(.retain_capacity);
        const done = try handleRecord(sess, ps, &scratch, rec);
        if (!done) return;

        ps.mutex.lockUncancelable(io);
        chunk.idx += 1;
        ps.processed.store(rec.offset + 1, .release);
        if (chunk.idx >= chunk.recs.len) {
            _ = ps.chunks.orderedRemove(0);
            ps.buffered -|= chunk.size;
            ps.mutex.unlock(io);
            chunk.resp.release();
            c.host.gpa.destroy(chunk);
        } else ps.mutex.unlock(io);
        if (c.host.tel) |t| t.consumedOne(c.opts.group, ps.topic);
    }
}

fn invoke(c: *Consumer, msg: *Msg) anyerror!void {
    return c.handler(c.context, msg);
}

/// Runs the handler with retries, then dead-letters or skips. False when
/// the session ended before the record was dealt with (it will be
/// delivered again).
fn handleRecord(sess: *Session, ps: *PartState, scratch: *std.heap.ArenaAllocator, rec: records.Record) std.Io.Cancelable!bool {
    const c = sess.consumer;
    const io = c.host.io;
    const arena = scratch.allocator();
    var msg: Msg = .{
        .io = io,
        .arena = arena,
        .id = std.fmt.allocPrint(arena, "kafka-{s}-{d}-{d}", .{ ps.topic, ps.partition, rec.offset }) catch "kafka",
        .topic = ps.topic,
        .partition = ps.partition,
        .offset = rec.offset,
        .timestamp_ms = rec.timestamp_ms,
        .key = rec.key,
        .value = rec.value,
        .headers = rec.headers,
    };
    var attempt: u32 = 1;
    var last_error: []const u8 = "";
    while (true) : (attempt += 1) {
        const outcome: anyerror!void = blk: {
            if (c.opts.timeout) |t| {
                const d: dusty.Deadline = .init(io, .{ .duration = .{ .raw = t, .clock = .awake } });
                break :blk d.run(invoke, .{ c, &msg });
            }
            break :blk invoke(c, &msg);
        };
        if (outcome) |_| return true else |err| {
            if (err == error.Canceled) return error.Canceled;
            last_error = @errorName(err);
            log.warn("kafka group {s}: handler failed for {s} (attempt {d} of {d}): {t}", .{ c.opts.group, msg.id, attempt, c.opts.retry.attempts, err });
        }
        if (attempt >= c.opts.retry.attempts or sess.stop.load(.acquire)) break;
        var rb: [8]u8 = undefined;
        io.random(&rb);
        try io.sleep(c.opts.retry.backoff.delay(attempt, std.mem.readInt(u64, &rb, .little)), .awake);
        if (sess.stop.load(.acquire)) return false;
    }
    if (sess.stop.load(.acquire) and attempt < c.opts.retry.attempts) return false;
    // Out of attempts.
    if (c.opts.dead_letter) |dlt| {
        while (true) {
            if (deadLetter(c, dlt, &msg, last_error, arena)) {
                if (c.host.tel) |t| t.deadLettered(c.opts.group, ps.topic);
                return true;
            }
            if (sess.stop.load(.acquire)) return false;
            try io.sleep(.fromSeconds(1), .awake);
        }
    }
    log.err("kafka group {s}: giving up on {s} after {d} attempts ({s}); skipping it", .{ c.opts.group, msg.id, attempt, last_error });
    return true;
}

fn deadLetter(c: *Consumer, topic: []const u8, msg: *const Msg, err_name: []const u8, arena: std.mem.Allocator) bool {
    const headers = arena.alloc(Header, msg.headers.len + 4) catch return false;
    @memcpy(headers[0..msg.headers.len], msg.headers);
    headers[msg.headers.len] = .{ .key = "anole-dlt-topic", .value = msg.topic };
    headers[msg.headers.len + 1] = .{ .key = "anole-dlt-partition", .value = std.fmt.allocPrint(arena, "{d}", .{msg.partition}) catch return false };
    headers[msg.headers.len + 2] = .{ .key = "anole-dlt-offset", .value = std.fmt.allocPrint(arena, "{d}", .{msg.offset}) catch return false };
    headers[msg.headers.len + 3] = .{ .key = "anole-dlt-error", .value = err_name };
    const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(c.host.io).nanoseconds, std.time.ns_per_ms));
    const outcome = c.host.producer.produceWait(topic, msg.key, msg.value, headers, null, now_ms, .fromSeconds(30)) catch |err| {
        log.warn("kafka group {s}: dead letter to {s} failed: {t}", .{ c.opts.group, topic, err });
        return false;
    };
    switch (outcome) {
        .ok => return true,
        .failed => |f| log.warn("kafka group {s}: dead letter to {s} failed: {s}", .{ c.opts.group, topic, f.code }),
        .timeout => log.warn("kafka group {s}: dead letter to {s} timed out", .{ c.opts.group, topic }),
    }
    return false;
}

const testing = std.testing;

test "assignors: range spreads partitions in runs, roundrobin deals them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const members = [_]MemberSub{
        .{ .member_id = "b", .topics = &.{ "t1", "t2" } },
        .{ .member_id = "a", .topics = &.{ "t1", "t2" } },
        .{ .member_id = "c", .topics = &.{"t2"} },
    };
    const topics = [_]TopicParts{ .{ .topic = "t2", .count = 3 }, .{ .topic = "t1", .count = 3 } };
    // Sorted members: a, b, c. t1 (a, b): 3 partitions -> a gets 2, b gets 1.
    // t2 (a, b, c): one each.
    const range = try assign(arena, .range, &members, &topics);
    try testing.expectEqual(@as(usize, 3), range[0].items.len);
    try testing.expectEqual(@as(usize, 2), range[1].items.len);
    try testing.expectEqual(@as(usize, 1), range[2].items.len);
    try testing.expectEqualStrings("t1", range[0].items[0].topic);
    try testing.expectEqual(@as(i32, 1), range[0].items[1].partition);
    // Every partition assigned exactly once.
    var seen: [6]bool = @splat(false);
    for (range) |l| for (l.items) |tp| {
        const idx: usize = (if (std.mem.eql(u8, tp.topic, "t1")) @as(usize, 0) else 3) + @as(usize, @intCast(tp.partition));
        try testing.expect(!seen[idx]);
        seen[idx] = true;
    };
    for (seen) |s| try testing.expect(s);

    const rr = try assign(arena, .roundrobin, &members, &topics);
    var total: usize = 0;
    for (rr) |l| total += l.items.len;
    try testing.expectEqual(@as(usize, 6), total);
    // c is only subscribed to t2.
    for (rr[2].items) |tp| try testing.expectEqualStrings("t2", tp.topic);
    // The deal is even to within one.
    try testing.expect(rr[0].items.len >= 1 and rr[1].items.len >= 1);
}

test "assignors: a topic nobody subscribes to is skipped; no members, nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const members = [_]MemberSub{.{ .member_id = "a", .topics = &.{"x"} }};
    const out = try assign(arena, .range, &members, &.{.{ .topic = "y", .count = 4 }});
    try testing.expectEqual(@as(usize, 0), out[0].items.len);
    const none = try assign(arena, .roundrobin, &.{}, &.{.{ .topic = "y", .count = 4 }});
    try testing.expectEqual(@as(usize, 0), none.len);
}
