//! An in-process Kafka broker for tests: one node on a loopback port that
//! speaks the protocol versions the client uses (ApiVersions, Metadata,
//! Produce, Fetch, ListOffsets, FindCoordinator, InitProducerId, the group
//! APIs, OffsetCommit/Fetch, SASL PLAIN and SCRAM), keeps the batches it is
//! given, and fails on request. It is not a Kafka: one broker, no
//! replication, topics made on first use, a join barrier of a few hundred
//! milliseconds. `anole.kafka.testing.FakeBroker` is for an app's own tests
//! (point `Options.brokers` at `broker.address()`); Anole's tests use it
//! too.
const std = @import("std");
const protocol = @import("protocol.zig");
const records = @import("records.zig");
const scram = @import("../net/scram.zig");
const sasl = @import("sasl.zig");

const Enc = protocol.Enc;
const Dec = protocol.Dec;

pub const Config = struct {
    /// Partitions of a topic made on first use.
    partitions: u32 = 3,
    /// Require this login before anything but ApiVersions.
    sasl: ?struct { mechanism: sasl.Mechanism, username: []const u8, password: []const u8 } = null,
    /// How long a JoinGroup waits for the other members of the round.
    join_wait_ms: u32 = 300,
    /// Replaces the version range ApiVersions advertises for these APIs
    /// (by default 0 to one past what the client speaks), to act as an
    /// older broker or Redpanda.
    serves: []const protocol.ApiRange = &.{},
};

const Stored = struct { base_offset: i64, count: i32, bytes: []u8 };

const PidState = struct { next_seq: i32 = 0, last_base: i64 = 0 };

const Partition = struct {
    batches: std.ArrayList(Stored) = .empty,
    next_offset: i64 = 0,
    pids: std.AutoHashMapUnmanaged(i64, PidState) = .empty,
};

const Topic = struct {
    name: []u8,
    parts: []Partition,
};

const Member = struct {
    id: []u8,
    instance: ?[]u8,
    metadata: []u8,
    protocol_name: []u8,
    joined: bool = false,
    assignment: []u8 = &.{},
};

const GroupState = enum { stable, joining, awaiting_sync };

const Group = struct {
    name: []u8,
    members: std.ArrayList(Member) = .empty,
    state: GroupState = .stable,
    generation: i32 = 0,
    leader: []u8 = &.{},
    protocol_name: []u8 = &.{},
    arrived: usize = 0,
    expected: usize = 0,
    synced: bool = false,
    offsets: std.StringHashMapUnmanaged(i64) = .empty,
    next_member: u32 = 1,
};

pub const FakeBroker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config: Config,
    listener: std.Io.net.Server,
    addr_buf: [32]u8 = undefined,
    /// `address()` as a one-entry broker list, for `Options.brokers`.
    bootstrap_list: [1][]const u8 = undefined,
    addr_len: usize = 0,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    topics: std.StringHashMapUnmanaged(*Topic) = .empty,
    groups: std.StringHashMapUnmanaged(*Group) = .empty,
    next_pid: i64 = 1000,

    /// The next N Produce requests are answered with `fail_code` for every
    /// partition, storing nothing.
    fail_produce: std.atomic.Value(u32) = .init(0),
    fail_code: std.atomic.Value(i16) = .init(6),
    /// The next N Produce requests are stored, and the connection is dropped
    /// before the answer.
    drop_after_store: std.atomic.Value(u32) = .init(0),
    /// Counters.
    produce_requests: std.atomic.Value(u32) = .init(0),
    /// The version of the last Produce request.
    produce_version: std.atomic.Value(i16) = .init(-1),
    fetch_requests: std.atomic.Value(u32) = .init(0),
    connections: std.atomic.Value(u32) = .init(0),
    commits: std.atomic.Value(u32) = .init(0),
    /// Every Metadata request answers with the topic missing.
    hide_topics: std.atomic.Value(bool) = .init(false),
    /// The next N Metadata answers for a topic that does not exist yet say
    /// UNKNOWN_TOPIC_OR_PARTITION, as Kafka 4.x does while it auto-creates
    /// one; the answer after them creates it.
    creating_answers: std.atomic.Value(u32) = .init(0),

    pub fn start(gpa: std.mem.Allocator, io: std.Io, config: Config) !*FakeBroker {
        const b = try gpa.create(FakeBroker);
        errdefer gpa.destroy(b);
        const listen_at: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        b.* = .{ .gpa = gpa, .io = io, .config = config, .listener = try listen_at.listen(io, .{}) };
        b.addr_len = (try std.fmt.bufPrint(&b.addr_buf, "127.0.0.1:{d}", .{b.listener.socket.address.getPort()})).len;
        b.bootstrap_list = .{b.address()};
        try b.group.concurrent(io, acceptLoop, .{b});
        return b;
    }

    pub fn deinit(b: *FakeBroker) void {
        b.group.cancel(b.io);
        b.listener.deinit(b.io);
        var ti = b.topics.valueIterator();
        while (ti.next()) |t| {
            for (t.*.parts) |*p| {
                for (p.batches.items) |s| b.gpa.free(s.bytes);
                p.batches.deinit(b.gpa);
                p.pids.deinit(b.gpa);
            }
            b.gpa.free(t.*.parts);
            b.gpa.free(t.*.name);
            b.gpa.destroy(t.*);
        }
        b.topics.deinit(b.gpa);
        var gi = b.groups.valueIterator();
        while (gi.next()) |g| {
            for (g.*.members.items) |m| {
                b.gpa.free(m.id);
                if (m.instance) |i| b.gpa.free(i);
                b.gpa.free(m.metadata);
                b.gpa.free(m.protocol_name);
                b.gpa.free(m.assignment);
            }
            g.*.members.deinit(b.gpa);
            var oi = g.*.offsets.keyIterator();
            while (oi.next()) |k| b.gpa.free(k.*);
            g.*.offsets.deinit(b.gpa);
            b.gpa.free(g.*.leader);
            b.gpa.free(g.*.protocol_name);
            b.gpa.free(g.*.name);
            b.gpa.destroy(g.*);
        }
        b.groups.deinit(b.gpa);
        b.gpa.destroy(b);
    }

    /// "127.0.0.1:port".
    pub fn address(b: *const FakeBroker) []const u8 {
        return b.addr_buf[0..b.addr_len];
    }

    /// The broker list for `Options.brokers`: lives as long as the broker
    /// (a `&.{b.address()}` made in a helper points into its stack frame).
    pub fn bootstrap(b: *const FakeBroker) []const []const u8 {
        return &b.bootstrap_list;
    }

    /// Stores a batch of `recs` at the end of a partition (making the topic).
    pub fn preload(b: *FakeBroker, topic: []const u8, partition: usize, recs: []const records.Rec) !void {
        const bytes = try records.encodeBatch(b.gpa, recs, .{});
        defer b.gpa.free(bytes);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const t = try b.topicOf(topic);
        try b.store(&t.parts[partition], bytes);
    }

    /// Every record stored in a partition, decoded into `arena`.
    pub fn stored(b: *FakeBroker, arena: std.mem.Allocator, topic_name: []const u8, partition: usize) ![]records.Record {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const t = b.topics.get(topic_name) orelse return &.{};
        var all: std.ArrayList(u8) = .empty;
        for (t.parts[partition].batches.items) |s| try all.appendSlice(arena, s.bytes);
        return (try records.decode(arena, all.items, 0, 64 * 1024 * 1024)).records;
    }

    /// How many records a partition holds.
    pub fn count(b: *FakeBroker, topic_name: []const u8, partition: usize) i64 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const t = b.topics.get(topic_name) orelse return 0;
        return t.parts[partition].next_offset;
    }

    /// The offset a group committed for a partition, or null.
    pub fn committed(b: *FakeBroker, group_name: []const u8, topic_name: []const u8, partition: i32) ?i64 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const g = b.groups.get(group_name) orelse return null;
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{d}", .{ topic_name, partition }) catch return null;
        return g.offsets.get(key);
    }

    /// The members the group has now.
    pub fn memberCount(b: *FakeBroker, group_name: []const u8) usize {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const g = b.groups.get(group_name) orelse return 0;
        return g.members.items.len;
    }

    /// How many partitions each member of the group was assigned, in
    /// member order, written to `out`; null while a round is open (not
    /// every member synced yet) or the group has more members than `out`.
    pub fn assignedCounts(b: *FakeBroker, group_name: []const u8, out: []usize) ?[]usize {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const g = b.groups.get(group_name) orelse return null;
        if (g.state != .stable or !g.synced or g.members.items.len > out.len) return null;
        for (g.members.items, 0..) |m, i| {
            var buf: [4096]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const parts = protocol.decodeAssignment(fba.allocator(), m.assignment) catch return null;
            out[i] = parts.len;
        }
        return out[0..g.members.items.len];
    }

    // Under `mutex`.
    fn topicOf(b: *FakeBroker, name: []const u8) !*Topic {
        if (b.topics.get(name)) |t| return t;
        const t = try b.gpa.create(Topic);
        errdefer b.gpa.destroy(t);
        t.name = try b.gpa.dupe(u8, name);
        errdefer b.gpa.free(t.name);
        t.parts = try b.gpa.alloc(Partition, b.config.partitions);
        for (t.parts) |*p| p.* = .{};
        try b.topics.put(b.gpa, t.name, t);
        return t;
    }

    fn groupOf(b: *FakeBroker, name: []const u8) !*Group {
        if (b.groups.get(name)) |g| return g;
        const g = try b.gpa.create(Group);
        errdefer b.gpa.destroy(g);
        g.* = .{ .name = try b.gpa.dupe(u8, name) };
        try b.groups.put(b.gpa, g.name, g);
        return g;
    }

    // Under `mutex`: appends a batch (its base offset rewritten).
    fn store(b: *FakeBroker, p: *Partition, bytes: []const u8) !void {
        const copy = try b.gpa.dupe(u8, bytes);
        errdefer b.gpa.free(copy);
        const n = std.mem.readInt(i32, copy[57..61], .big);
        std.mem.writeInt(i64, copy[0..8], p.next_offset, .big);
        try p.batches.append(b.gpa, .{ .base_offset = p.next_offset, .count = n, .bytes = copy });
        p.next_offset += n;
    }

    fn acceptLoop(b: *FakeBroker) std.Io.Cancelable!void {
        while (true) {
            const conn = b.listener.accept(b.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            b.group.concurrent(b.io, serve, .{ b, conn }) catch conn.close(b.io);
        }
    }

    const Conn = struct {
        authenticated: bool,
        scram_state: ?ScramState = null,
    };

    const ScramState = struct {
        first_bare: []const u8,
        server_first: []const u8,
    };

    fn serve(b: *FakeBroker, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer stream.close(b.io);
        _ = b.connections.fetchAdd(1, .monotonic);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var r = stream.reader(b.io, &rbuf);
        var w = stream.writer(b.io, &wbuf);
        var arena_state: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena_state.deinit();
        var conn: Conn = .{ .authenticated = b.config.sasl == null };
        while (true) {
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            var len_buf: [4]u8 = undefined;
            r.interface.readSliceAll(&len_buf) catch return;
            const len = std.mem.readInt(i32, &len_buf, .big);
            if (len < 8 or len > 64 * 1024 * 1024) return;
            const frame = r.interface.readAlloc(arena, @intCast(len)) catch return;
            var d: Dec = .init(frame);
            const api_key = d.i16_() catch return;
            const version = d.i16_() catch return;
            const corr = d.i32_() catch return;
            _ = d.nullableString() catch return;
            var out: Enc = .init(arena);
            const lead = out.reserveLen() catch return;
            out.i32_(corr) catch return;
            const keep = b.handle(arena, &conn, api_key, version, &d, &out) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            switch (keep) {
                .drop => return,
                .no_reply => continue,
                .reply => {},
            }
            out.patchLen(lead);
            w.interface.writeAll(out.bytesWritten()) catch return;
            w.interface.flush() catch return;
        }
    }

    const Outcome = enum { reply, no_reply, drop };

    fn handle(b: *FakeBroker, arena: std.mem.Allocator, conn: *Conn, api_key: i16, version: i16, d: *Dec, out: *Enc) !Outcome {
        const api = std.enums.fromInt(protocol.Api, api_key) orelse return .drop;
        if (!conn.authenticated and api != .api_versions and api != .sasl_handshake and api != .sasl_authenticate) return .drop;
        switch (api) {
            .api_versions => {
                try out.i16_(0);
                const all = [_]protocol.Api{ .produce, .fetch, .list_offsets, .metadata, .offset_commit, .offset_fetch, .find_coordinator, .join_group, .heartbeat, .leave_group, .sync_group, .sasl_handshake, .api_versions, .init_producer_id, .sasl_authenticate };
                try out.arrayLen(all.len);
                for (all) |a| {
                    var lo: i16 = 0;
                    var hi: i16 = a.version() + 1;
                    for (b.config.serves) |r| if (r.key == @backingInt(a)) {
                        lo = r.min;
                        hi = r.max;
                    };
                    try out.i16_(@backingInt(a));
                    try out.i16_(lo);
                    try out.i16_(hi);
                }
            },
            .sasl_handshake => {
                const want = try d.string();
                const cfg = b.config.sasl orelse {
                    try out.i16_(0);
                    try out.arrayLen(0);
                    return .reply;
                };
                try out.i16_(if (std.mem.eql(u8, want, cfg.mechanism.name())) 0 else 33);
                try out.arrayLen(1);
                try out.string(cfg.mechanism.name());
            },
            .sasl_authenticate => try b.saslAuthenticate(arena, conn, d, out),
            .metadata => try b.metadata(d, out),
            .find_coordinator => {
                _ = try d.string();
                _ = try d.i8_();
                try out.i32_(0);
                try out.i16_(0);
                try out.nullableString(null);
                try out.i32_(0);
                try out.string("127.0.0.1");
                try out.i32_(b.listener.socket.address.getPort());
            },
            .init_producer_id => {
                b.mutex.lockUncancelable(b.io);
                const pid = b.next_pid;
                b.next_pid += 1;
                b.mutex.unlock(b.io);
                try out.i32_(0);
                try out.i16_(0);
                try out.i64_(pid);
                try out.i16_(0);
            },
            .produce => return b.produce(arena, version, d, out),
            .fetch => try b.fetch(arena, d, out),
            .list_offsets => try b.listOffsets(arena, d, out),
            .join_group => try b.joinGroup(arena, d, out),
            .sync_group => try b.syncGroup(arena, d, out),
            .heartbeat => try b.heartbeat(d, out),
            .leave_group => try b.leaveGroup(d, out),
            .offset_commit => try b.offsetCommit(d, out),
            .offset_fetch => try b.offsetFetch(d, out),
        }
        return .reply;
    }

    fn metadata(b: *FakeBroker, d: *Dec, out: *Enc) !void {
        const n = try d.i32_();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(b.gpa);
        const all = n < 0;
        if (!all) for (0..@intCast(n)) |_| try names.append(b.gpa, try d.string());
        const auto_create = d.bool_() catch true;
        try out.i32_(0);
        try out.arrayLen(1);
        try out.i32_(0);
        try out.string("127.0.0.1");
        try out.i32_(b.listener.socket.address.getPort());
        try out.nullableString(null);
        try out.nullableString("fake");
        try out.i32_(0);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        if (all) {
            var it = b.topics.keyIterator();
            while (it.next()) |k| try names.append(b.gpa, k.*);
        }
        try out.arrayLen(names.items.len);
        for (names.items) |name| {
            const hidden = b.hide_topics.load(.acquire);
            const exists = b.topics.get(name) != null;
            if (!hidden and !exists and auto_create and takeOne(&b.creating_answers)) {
                try out.i16_(protocol.unknown_topic_or_partition);
                try out.string(name);
                try out.bool_(false);
                try out.arrayLen(0);
                try out.i32_(0);
                continue;
            }
            const t: ?*Topic = if (hidden) null else if (b.topics.get(name)) |t| t else if (auto_create) try b.topicOf(name) else null;
            if (t) |tp| {
                try out.i16_(0);
                try out.string(name);
                try out.bool_(false);
                try out.arrayLen(tp.parts.len);
                for (tp.parts, 0..) |_, i| {
                    try out.i16_(0);
                    try out.i32_(@intCast(i));
                    try out.i32_(0);
                    try out.i32_(0);
                    try out.arrayLen(1);
                    try out.i32_(0);
                    try out.arrayLen(1);
                    try out.i32_(0);
                    try out.arrayLen(0);
                }
            } else {
                try out.i16_(protocol.unknown_topic_or_partition);
                try out.string(name);
                try out.bool_(false);
                try out.arrayLen(0);
            }
            try out.i32_(0);
        }
        try out.i32_(0);
    }

    fn produce(b: *FakeBroker, arena: std.mem.Allocator, version: i16, d: *Dec, out: *Enc) !Outcome {
        _ = arena;
        _ = try d.nullableString();
        const acks = try d.i16_();
        _ = try d.i32_();
        _ = b.produce_requests.fetchAdd(1, .monotonic);
        b.produce_version.store(version, .release);
        const failing = takeOne(&b.fail_produce);
        const fail_code = b.fail_code.load(.acquire);
        const drop = takeOne(&b.drop_after_store);
        const nt = try d.arrayLen();
        try out.arrayLen(nt);
        for (0..nt) |_| {
            const name = try d.string();
            const np = try d.arrayLen();
            try out.string(name);
            try out.arrayLen(np);
            for (0..np) |_| {
                const index = try d.i32_();
                const batch = (try d.nullableBytes()) orelse "";
                var code: i16 = 0;
                var base: i64 = -1;
                if (failing) {
                    code = fail_code;
                } else if (batch.len < records.header_len) {
                    code = 2;
                } else {
                    b.mutex.lockUncancelable(b.io);
                    defer b.mutex.unlock(b.io);
                    const t = try b.topicOf(name);
                    if (index < 0 or @as(usize, @intCast(index)) >= t.parts.len) {
                        code = protocol.unknown_topic_or_partition;
                    } else {
                        const p = &t.parts[@intCast(index)];
                        const pid = std.mem.readInt(i64, batch[43..51], .big);
                        const seq = std.mem.readInt(i32, batch[53..57], .big);
                        const n = std.mem.readInt(i32, batch[57..61], .big);
                        if (pid >= 0) {
                            const st = p.pids.get(pid) orelse PidState{};
                            if (seq + n <= st.next_seq and st.next_seq > 0) {
                                code = protocol.duplicate_sequence;
                                base = st.last_base;
                            } else if (seq != st.next_seq) {
                                code = protocol.out_of_order_sequence;
                            }
                        }
                        if (code == 0) {
                            base = p.next_offset;
                            try b.store(p, batch);
                            if (pid >= 0) try p.pids.put(b.gpa, pid, .{ .next_seq = seq + n, .last_base = base });
                        }
                    }
                }
                try out.i32_(index);
                try out.i16_(code);
                try out.i64_(base);
                try out.i64_(-1);
                try out.i64_(0);
                if (version >= 8) {
                    try out.arrayLen(0);
                    try out.nullableString(null);
                }
            }
        }
        try out.i32_(0);
        if (drop) return .drop;
        return if (acks == 0) .no_reply else .reply;
    }

    fn takeOne(a: *std.atomic.Value(u32)) bool {
        while (true) {
            const v = a.load(.acquire);
            if (v == 0) return false;
            if (a.cmpxchgWeak(v, v - 1, .acq_rel, .acquire) == null) return true;
        }
    }

    fn fetch(b: *FakeBroker, arena: std.mem.Allocator, d: *Dec, out: *Enc) !void {
        _ = b.fetch_requests.fetchAdd(1, .monotonic);
        _ = try d.i32_();
        const max_wait = try d.i32_();
        _ = try d.i32_();
        _ = try d.i32_();
        _ = try d.i8_();
        _ = try d.i32_();
        _ = try d.i32_();
        const Want = struct { topic: []const u8, partition: i32, offset: i64, max: i32 };
        var wants: std.ArrayList(Want) = .empty;
        const nt = try d.arrayLen();
        for (0..nt) |_| {
            const name = try d.string();
            const np = try d.arrayLen();
            for (0..np) |_| {
                const p = try d.i32_();
                _ = try d.i32_();
                const off = try d.i64_();
                _ = try d.i64_();
                const max = try d.i32_();
                try wants.append(arena, .{ .topic = name, .partition = p, .offset = off, .max = max });
            }
        }
        var waited: i32 = 0;
        // Poll for data, up to max_wait.
        const Got = struct { want: Want, data: []u8, hw: i64, code: i16 };
        var got: std.ArrayList(Got) = .empty;
        while (true) {
            got.clearRetainingCapacity();
            var any = false;
            b.mutex.lockUncancelable(b.io);
            for (wants.items) |w| {
                const t = b.topics.get(w.topic);
                if (t == null or w.partition < 0 or @as(usize, @intCast(w.partition)) >= t.?.parts.len) {
                    try got.append(arena, .{ .want = w, .data = &.{}, .hw = -1, .code = protocol.unknown_topic_or_partition });
                    continue;
                }
                const p = &t.?.parts[@intCast(w.partition)];
                if (w.offset > p.next_offset) {
                    try got.append(arena, .{ .want = w, .data = &.{}, .hw = p.next_offset, .code = protocol.offset_out_of_range });
                    any = true;
                    continue;
                }
                var data: std.ArrayList(u8) = .empty;
                for (p.batches.items) |s| {
                    if (s.base_offset + s.count <= w.offset) continue;
                    if (data.items.len > 0 and data.items.len + s.bytes.len > @as(usize, @intCast(@max(w.max, 0)))) break;
                    try data.appendSlice(arena, s.bytes);
                }
                if (data.items.len > 0) any = true;
                try got.append(arena, .{ .want = w, .data = data.items, .hw = p.next_offset, .code = 0 });
            }
            b.mutex.unlock(b.io);
            if (any or waited >= max_wait) break;
            try b.io.sleep(.fromMilliseconds(10), .awake);
            waited += 10;
        }
        try out.i32_(0);
        try out.i16_(0);
        try out.i32_(0);
        // Group by topic in request order.
        var topics: usize = 0;
        for (got.items, 0..) |g, i| {
            if (i == 0 or !std.mem.eql(u8, g.want.topic, got.items[i - 1].want.topic)) topics += 1;
        }
        try out.arrayLen(topics);
        var i: usize = 0;
        while (i < got.items.len) {
            var j = i;
            while (j < got.items.len and std.mem.eql(u8, got.items[j].want.topic, got.items[i].want.topic)) j += 1;
            try out.string(got.items[i].want.topic);
            try out.arrayLen(j - i);
            for (got.items[i..j]) |g| {
                try out.i32_(g.want.partition);
                try out.i16_(g.code);
                try out.i64_(g.hw);
                try out.i64_(g.hw);
                try out.i64_(0);
                try out.arrayLen(0);
                try out.i32_(-1);
                try out.bytes(g.data);
            }
            i = j;
        }
    }

    fn listOffsets(b: *FakeBroker, arena: std.mem.Allocator, d: *Dec, out: *Enc) !void {
        _ = arena;
        _ = try d.i32_();
        _ = try d.i8_();
        const nt = try d.arrayLen();
        try out.i32_(0);
        try out.arrayLen(nt);
        for (0..nt) |_| {
            const name = try d.string();
            const np = try d.arrayLen();
            try out.string(name);
            try out.arrayLen(np);
            for (0..np) |_| {
                const p = try d.i32_();
                _ = try d.i32_();
                const ts = try d.i64_();
                b.mutex.lockUncancelable(b.io);
                const t = b.topics.get(name);
                var code: i16 = 0;
                var off: i64 = 0;
                if (t == null or p < 0 or @as(usize, @intCast(p)) >= t.?.parts.len) {
                    code = protocol.unknown_topic_or_partition;
                } else if (ts != -2) off = t.?.parts[@intCast(p)].next_offset;
                b.mutex.unlock(b.io);
                try out.i32_(p);
                try out.i16_(code);
                try out.i64_(-1);
                try out.i64_(off);
                try out.i32_(0);
            }
        }
    }

    // ---- groups. All of it under `mutex`, with `cond` for the barriers.

    fn joinGroup(b: *FakeBroker, arena: std.mem.Allocator, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        _ = try d.i32_();
        _ = try d.i32_();
        var member_id = try d.string();
        const instance = try d.nullableString();
        _ = try d.string();
        const np = try d.arrayLen();
        var proto_name: []const u8 = "";
        var meta: []const u8 = "";
        for (0..np) |k| {
            const nm = try d.string();
            const md = try d.bytes();
            if (k == 0) {
                proto_name = nm;
                meta = md;
            }
        }
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = try b.groupOf(group_name);
        if (member_id.len == 0) {
            // Like a real broker: the first join gets an id to come back with.
            // A static member that is known keeps its id.
            if (instance) |inst| {
                for (g.members.items) |m| if (m.instance != null and std.mem.eql(u8, m.instance.?, inst)) {
                    member_id = try arena.dupe(u8, m.id);
                };
            }
            if (member_id.len == 0) {
                const id = try std.fmt.allocPrint(arena, "member-{d}", .{g.next_member});
                g.next_member += 1;
                try writeJoin(out, protocol.member_id_required, -1, "", "", id, &.{});
                return;
            }
        }
        // Find or add.
        var idx: ?usize = null;
        for (g.members.items, 0..) |m, k| if (std.mem.eql(u8, m.id, member_id)) {
            idx = k;
        };
        if (idx == null) {
            try g.members.append(b.gpa, .{
                .id = try b.gpa.dupe(u8, member_id),
                .instance = if (instance) |i| try b.gpa.dupe(u8, i) else null,
                .metadata = try b.gpa.dupe(u8, meta),
                .protocol_name = try b.gpa.dupe(u8, proto_name),
            });
            idx = g.members.items.len - 1;
        } else {
            const m = &g.members.items[idx.?];
            b.gpa.free(m.metadata);
            m.metadata = try b.gpa.dupe(u8, meta);
        }
        if (g.state != .joining) {
            g.state = .joining;
            g.arrived = 0;
            g.expected = g.members.items.len;
            for (g.members.items) |*m| m.joined = false;
        } else if (idx.? >= g.expected) g.expected = g.members.items.len;
        const me = &g.members.items[idx.?];
        if (!me.joined) {
            me.joined = true;
            g.arrived += 1;
        }
        const my_id = try arena.dupe(u8, me.id);
        if (g.arrived >= g.expected) b.completeRound(g) else b.cond.broadcast(b.io);
        var waited: u32 = 0;
        while (g.state == .joining) {
            b.cond.waitTimeout(b.io, &b.mutex, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {
                    waited += 50;
                    if (waited >= b.config.join_wait_ms and g.state == .joining) {
                        // Members that never came back are gone.
                        var k: usize = 0;
                        while (k < g.members.items.len) {
                            if (!g.members.items[k].joined) {
                                const gone = g.members.orderedRemove(k);
                                b.gpa.free(gone.id);
                                if (gone.instance) |i| b.gpa.free(i);
                                b.gpa.free(gone.metadata);
                                b.gpa.free(gone.protocol_name);
                                b.gpa.free(gone.assignment);
                            } else k += 1;
                        }
                        b.completeRound(g);
                    }
                },
                error.Canceled => return error.Canceled,
            };
        }
        // Answer: the leader gets the member list.
        const is_leader = std.mem.eql(u8, g.leader, my_id);
        var list: std.ArrayList(protocol.JoinMember) = .empty;
        if (is_leader) for (g.members.items) |m| try list.append(arena, .{ .member_id = try arena.dupe(u8, m.id), .metadata = try arena.dupe(u8, m.metadata) });
        try writeJoin(out, 0, g.generation, try arena.dupe(u8, g.protocol_name), try arena.dupe(u8, g.leader), my_id, list.items);
    }

    fn completeRound(b: *FakeBroker, g: *Group) void {
        g.generation += 1;
        g.state = .awaiting_sync;
        g.synced = false;
        b.gpa.free(g.leader);
        b.gpa.free(g.protocol_name);
        g.leader = if (g.members.items.len > 0) b.gpa.dupe(u8, g.members.items[0].id) catch &.{} else &.{};
        g.protocol_name = if (g.members.items.len > 0) b.gpa.dupe(u8, g.members.items[0].protocol_name) catch &.{} else &.{};
        b.cond.broadcast(b.io);
    }

    fn writeJoin(out: *Enc, code: i16, generation: i32, proto_name: []const u8, leader: []const u8, member: []const u8, members: []const protocol.JoinMember) !void {
        try out.i32_(0);
        try out.i16_(code);
        try out.i32_(generation);
        try out.string(proto_name);
        try out.string(leader);
        try out.string(member);
        try out.arrayLen(members.len);
        for (members) |m| {
            try out.string(m.member_id);
            try out.nullableString(null);
            try out.bytes(m.metadata);
        }
    }

    fn syncGroup(b: *FakeBroker, arena: std.mem.Allocator, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        const generation = try d.i32_();
        const member_id = try d.string();
        _ = try d.nullableString();
        const na = try d.arrayLen();
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = b.groupOf(group_name) catch return error.OutOfMemory;
        const reply = struct {
            fn write(o: *Enc, code: i16, assignment: []const u8) !void {
                try o.i32_(0);
                try o.i16_(code);
                try o.bytes(assignment);
            }
        };
        var me: ?*Member = null;
        for (g.members.items) |*m| if (std.mem.eql(u8, m.id, member_id)) {
            me = m;
        };
        if (me == null) return reply.write(out, protocol.unknown_member_id, "");
        if (generation != g.generation) return reply.write(out, protocol.illegal_generation, "");
        if (g.state == .joining) return reply.write(out, protocol.rebalance_in_progress, "");
        for (0..na) |_| {
            const mid = try d.string();
            const bytes = try d.bytes();
            for (g.members.items) |*m| if (std.mem.eql(u8, m.id, mid)) {
                b.gpa.free(m.assignment);
                m.assignment = try b.gpa.dupe(u8, bytes);
            };
        }
        if (std.mem.eql(u8, g.leader, member_id)) {
            g.synced = true;
            g.state = .stable;
            b.cond.broadcast(b.io);
        }
        var waited: u32 = 0;
        while (!g.synced and g.generation == generation) {
            if (g.state == .joining) return reply.write(out, protocol.rebalance_in_progress, "");
            b.cond.waitTimeout(b.io, &b.mutex, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {
                    waited += 50;
                    if (waited > 5000) return reply.write(out, protocol.rebalance_in_progress, "");
                },
                error.Canceled => return error.Canceled,
            };
        }
        if (g.generation != generation) return reply.write(out, protocol.rebalance_in_progress, "");
        return reply.write(out, 0, try arena.dupe(u8, me.?.assignment));
    }

    fn heartbeat(b: *FakeBroker, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        const generation = try d.i32_();
        const member_id = try d.string();
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = try b.groupOf(group_name);
        var known = false;
        for (g.members.items) |m| if (std.mem.eql(u8, m.id, member_id)) {
            known = true;
        };
        try out.i32_(0);
        if (!known) return out.i16_(protocol.unknown_member_id);
        if (g.state == .joining) return out.i16_(protocol.rebalance_in_progress);
        if (generation != g.generation) return out.i16_(protocol.illegal_generation);
        try out.i16_(0);
    }

    fn leaveGroup(b: *FakeBroker, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        const n = try d.arrayLen();
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = try b.groupOf(group_name);
        for (0..n) |_| {
            const mid = try d.string();
            _ = try d.nullableString();
            var k: usize = 0;
            while (k < g.members.items.len) {
                if (std.mem.eql(u8, g.members.items[k].id, mid)) {
                    const gone = g.members.orderedRemove(k);
                    b.gpa.free(gone.id);
                    if (gone.instance) |i| b.gpa.free(i);
                    b.gpa.free(gone.metadata);
                    b.gpa.free(gone.protocol_name);
                    b.gpa.free(gone.assignment);
                } else k += 1;
            }
        }
        if (g.members.items.len > 0) {
            g.state = .joining;
            g.arrived = 0;
            g.expected = g.members.items.len;
            for (g.members.items) |*m| m.joined = false;
        } else g.state = .stable;
        b.cond.broadcast(b.io);
        try out.i32_(0);
        try out.i16_(0);
        try out.arrayLen(0);
    }

    fn offsetCommit(b: *FakeBroker, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        const generation = try d.i32_();
        const member_id = try d.string();
        _ = try d.nullableString();
        _ = b.commits.fetchAdd(1, .monotonic);
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = try b.groupOf(group_name);
        var known = false;
        for (g.members.items) |m| if (std.mem.eql(u8, m.id, member_id)) {
            known = true;
        };
        const code: i16 = if (!known) protocol.unknown_member_id else if (generation != g.generation) protocol.illegal_generation else 0;
        const nt = try d.arrayLen();
        try out.i32_(0);
        try out.arrayLen(nt);
        for (0..nt) |_| {
            const name = try d.string();
            const np = try d.arrayLen();
            try out.string(name);
            try out.arrayLen(np);
            for (0..np) |_| {
                const p = try d.i32_();
                const off = try d.i64_();
                _ = try d.i32_();
                _ = try d.nullableString();
                if (code == 0) {
                    var buf: [256]u8 = undefined;
                    const key = try std.fmt.bufPrint(&buf, "{s}\x00{d}", .{ name, p });
                    if (g.offsets.getPtr(key)) |v| v.* = off else try g.offsets.put(b.gpa, try b.gpa.dupe(u8, key), off);
                }
                try out.i32_(p);
                try out.i16_(code);
            }
        }
    }

    fn offsetFetch(b: *FakeBroker, d: *Dec, out: *Enc) !void {
        const group_name = try d.string();
        const nt = try d.arrayLen();
        try b.mutex.lock(b.io);
        defer b.mutex.unlock(b.io);
        const g = try b.groupOf(group_name);
        try out.i32_(0);
        try out.arrayLen(nt);
        for (0..nt) |_| {
            const name = try d.string();
            const np = try d.arrayLen();
            try out.string(name);
            try out.arrayLen(np);
            for (0..np) |_| {
                const p = try d.i32_();
                var buf: [256]u8 = undefined;
                const key = try std.fmt.bufPrint(&buf, "{s}\x00{d}", .{ name, p });
                try out.i32_(p);
                try out.i64_(g.offsets.get(key) orelse -1);
                try out.i32_(-1);
                try out.nullableString(null);
                try out.i16_(0);
            }
        }
        try out.i16_(0);
    }

    // ---- SASL

    fn saslAuthenticate(b: *FakeBroker, arena: std.mem.Allocator, conn: *Conn, d: *Dec, out: *Enc) !void {
        const auth = try d.bytes();
        const cfg = b.config.sasl orelse return error.Invalid;
        const fail = struct {
            fn write(o: *Enc, msg: []const u8) !void {
                try o.i16_(protocol.sasl_authentication_failed);
                try o.nullableString(msg);
                try o.bytes("");
                try o.i64_(0);
            }
        };
        switch (cfg.mechanism) {
            .plain => {
                const expect = try sasl.plainMessage(arena, cfg.username, cfg.password);
                if (!std.mem.eql(u8, auth, expect)) return fail.write(out, "Authentication failed: Invalid username or password");
                conn.authenticated = true;
                try out.i16_(0);
                try out.nullableString(null);
                try out.bytes("");
                try out.i64_(0);
            },
            .scram_sha_256, .scram_sha_512 => {
                const m: scram.Mechanism = if (cfg.mechanism == .scram_sha_256) .sha256 else .sha512;
                const salt = "0123456789abcdef";
                if (conn.scram_state == null) {
                    // client-first: "n,,n=<user>,r=<nonce>"
                    if (!std.mem.startsWith(u8, auth, "n,,")) return fail.write(out, "bad client-first");
                    const bare = auth[3..];
                    var nonce: []const u8 = "";
                    var it = std.mem.splitScalar(u8, bare, ',');
                    while (it.next()) |attr| {
                        if (std.mem.startsWith(u8, attr, "r=")) nonce = attr[2..];
                        if (std.mem.startsWith(u8, attr, "n=") and !std.mem.eql(u8, attr[2..], cfg.username)) return fail.write(out, "unknown user");
                    }
                    var salt_b64: [24]u8 = undefined;
                    const salt_text = std.base64.standard.Encoder.encode(&salt_b64, salt);
                    const server_first = try std.fmt.allocPrint(b.gpa, "r={s}srv,s={s},i=4096", .{ nonce, salt_text });
                    conn.scram_state = .{ .first_bare = try b.gpa.dupe(u8, bare), .server_first = server_first };
                    try out.i16_(0);
                    try out.nullableString(null);
                    try out.bytes(server_first);
                    try out.i64_(0);
                    return;
                }
                const st = conn.scram_state.?;
                defer {
                    b.gpa.free(st.first_bare);
                    b.gpa.free(st.server_first);
                    conn.scram_state = null;
                }
                // client-final: "c=biws,r=<nonce>,p=<proof>"
                const p_at = std.mem.lastIndexOf(u8, auth, ",p=") orelse return fail.write(out, "bad client-final");
                const without_proof = auth[0..p_at];
                const proof_b64 = auth[p_at + 3 ..];
                const n = m.digestLen();
                var proof: [scram.max_digest]u8 = undefined;
                if ((std.base64.standard.Decoder.calcSizeForSlice(proof_b64) catch 0) != n) return fail.write(out, "bad proof");
                std.base64.standard.Decoder.decode(proof[0..n], proof_b64) catch return fail.write(out, "bad proof");
                const keys = scram.deriveKeys(m, cfg.password, salt, 4096);
                const auth_message = try std.fmt.allocPrint(arena, "{s},{s},{s}", .{ st.first_bare, st.server_first, without_proof });
                var stored_key: [scram.max_digest]u8 = undefined;
                scram.hash(m, keys.client[0..n], stored_key[0..n]);
                var sig: [scram.max_digest]u8 = undefined;
                scram.hmac(m, sig[0..n], auth_message, stored_key[0..n]);
                var client_key: [scram.max_digest]u8 = undefined;
                for (client_key[0..n], proof[0..n], sig[0..n]) |*o, p, s| o.* = p ^ s;
                var check: [scram.max_digest]u8 = undefined;
                scram.hash(m, client_key[0..n], check[0..n]);
                if (!std.mem.eql(u8, check[0..n], stored_key[0..n])) return fail.write(out, "Authentication failed: Invalid username or password");
                var server_sig: [scram.max_digest]u8 = undefined;
                scram.hmac(m, server_sig[0..n], auth_message, keys.server[0..n]);
                var sig_b64: [88]u8 = undefined;
                const v = try std.fmt.allocPrint(arena, "v={s}", .{std.base64.standard.Encoder.encode(&sig_b64, server_sig[0..n])});
                conn.authenticated = true;
                try out.i16_(0);
                try out.nullableString(null);
                try out.bytes(v);
                try out.i64_(0);
            },
        }
    }
};
