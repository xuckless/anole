//! The cluster as the client sees it: broker connections (`Conn`, one
//! request in flight at a time, with SASL done at connect), the bootstrap
//! list, and the metadata cache (brokers, partition leaders), refreshed on
//! demand, on a leader error, and after `metadata_max_age`.
//!
//! A `Conn` is used by one component at a time (a producer sender, a
//! consumer's coordinator, one fetcher, the metadata refresh round holding
//! the turn), so a long fetch never holds up a produce or a heartbeat; its
//! I/O lock only keeps accidental sharing safe.
const std = @import("std");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const testHold = @import("test_hold.zig").testHold;
const protocol = @import("protocol.zig");
const sasl = @import("sasl.zig");
const scram = @import("../net/scram.zig");
const net = @import("../net/client_stream.zig");

const log = std.log.scoped(.anole);
const Api = protocol.Api;

pub const ConnError = protocol.Error || error{ Timeout, ConnectionLost, ProtocolError, AuthFailed, UnsupportedBroker, NoBroker } || std.Io.Cancelable;

/// What every connection of a client is opened with.
pub const Settings = struct {
    client_id: []const u8,
    tls: ?net.ConnectOptions.Tls = null,
    sasl: ?sasl.Credential = null,
    connect_timeout: std.Io.Duration = .fromSeconds(10),
    request_timeout: std.Io.Duration = .fromSeconds(30),
    metadata_max_age: std.Io.Duration = .fromSeconds(300),
    scram_cache: *scram.Cache,
};

pub const HostPort = struct { host: []const u8, port: u16 };

/// Parses "host:port", "[::1]:9092" or a bare host (port 9092).
pub fn parseHostPort(text: []const u8) HostPort {
    if (std.mem.startsWith(u8, text, "[")) {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return .{ .host = text, .port = 9092 };
        const port = if (close + 2 <= text.len) std.fmt.parseInt(u16, text[close + 2 ..], 10) catch 9092 else 9092;
        return .{ .host = text[1..close], .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return .{ .host = text, .port = 9092 };
    return .{ .host = text[0..colon], .port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch 9092 };
}

const max_response = 256 * 1024 * 1024;

/// owner: the component that opened it (a sender task, the refresh round
/// holding the turn, a consumer task); `close` is the owner's.
pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    settings: Settings,
    stream: *net.ClientStream,
    /// One round trip at a time on this socket, taken with no other lock
    /// held, until #111's reader demux. L2's exception (an I/O lock); held
    /// per task, so other tasks of the executor take their own connections'
    /// locks while this one waits for its answer.
    mutex: safety.IoLock = .init,
    correlation: i32 = 1,
    broken: bool = false,
    node_id: i32,
    host: []const u8,
    port: u16,
    /// The version of each API this connection speaks, settled against the
    /// broker's ApiVersions answer when it opens.
    versions: std.EnumArray(Api, i16) = versions_newest,

    const versions_newest: std.EnumArray(Api, i16) = blk: {
        var v: std.EnumArray(Api, i16) = undefined;
        for (std.enums.values(Api)) |api| v.set(api, api.version());
        break :blk v;
    };

    /// The version `api` requests go out at on this connection.
    pub fn version(self: *const Conn, api: Api) i16 {
        return self.versions.get(api);
    }

    /// Connects (TCP, TLS), checks the broker speaks the versions this
    /// client needs, and authenticates when `settings.sasl` is set.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, settings: Settings, host: []const u8, port: u16, node_id: i32) ConnError!*Conn {
        const stream = net.ClientStream.connect(gpa, io, .{
            .host = host,
            .port = port,
            .tls = settings.tls,
            .connect_timeout = settings.connect_timeout,
        }) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.Timeout => error.Timeout,
            else => blk: {
                log.debug("kafka {s}:{d}: connect failed: {t}", .{ host, port, err });
                break :blk error.ConnectionLost;
            },
        };
        errdefer stream.close();
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        const owned_host = try gpa.dupe(u8, host);
        errdefer gpa.free(owned_host);
        self.* = .{ .gpa = gpa, .io = io, .settings = settings, .stream = stream, .node_id = node_id, .host = owned_host, .port = port };
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try self.checkVersions(arena);
        if (settings.sasl) |cred| try sasl.authenticate(self, arena, cred, settings.scram_cache);
        return self;
    }

    pub fn close(self: *Conn) void {
        self.stream.close();
        self.gpa.free(self.host);
        self.gpa.destroy(self);
    }

    /// Wakes a task blocked on this connection (it then fails with
    /// `ConnectionLost`).
    pub fn abort(self: *Conn) void {
        self.stream.shutdown();
    }

    fn checkVersions(self: *Conn, arena: std.mem.Allocator) ConnError!void {
        var e: protocol.Enc = .init(arena);
        try protocol.encodeApiVersions(&e);
        const body = try self.call(arena, .api_versions, e.bytesWritten(), self.settings.request_timeout);
        const r = protocol.decodeApiVersions(arena, body) catch return error.ProtocolError;
        if (r.error_code != 0) return error.UnsupportedBroker;
        const all = [_]Api{ .produce, .fetch, .list_offsets, .metadata, .offset_commit, .offset_fetch, .find_coordinator, .join_group, .heartbeat, .leave_group, .sync_group, .sasl_handshake, .init_producer_id, .sasl_authenticate };
        for (all) |api| {
            const lo = api.minVersion();
            const hi = api.version();
            var found = false;
            for (r.apis) |a| {
                if (a.key != @backingInt(api)) continue;
                found = true;
                const use = @min(hi, a.max);
                if (use < lo or use < a.min) {
                    if (lo == hi) {
                        log.warn("kafka {s}:{d}: the broker serves {t} versions {d}-{d}; this client needs {d}", .{ self.host, self.port, api, a.min, a.max, hi });
                    } else {
                        log.warn("kafka {s}:{d}: the broker serves {t} versions {d}-{d}; this client needs one of {d}-{d}", .{ self.host, self.port, api, a.min, a.max, lo, hi });
                    }
                    return error.UnsupportedBroker;
                }
                self.versions.set(api, use);
            }
            // SASL APIs are absent from a broker without SASL support at all;
            // everything else is required.
            if (!found and api != .sasl_handshake and api != .sasl_authenticate) {
                log.warn("kafka {s}:{d}: the broker lacks {t}", .{ self.host, self.port, api });
                return error.UnsupportedBroker;
            }
        }
    }

    /// One request and its response, within `timeout`. The response body
    /// (without the correlation id) is allocated in `arena`.
    pub fn call(self: *Conn, arena: std.mem.Allocator, api: Api, body: []const u8, timeout: std.Io.Duration) ConnError![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.broken) return error.ConnectionLost;
        const deadline: dusty.Deadline = .init(self.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
        return deadline.run(roundTrip, .{ self, arena, api, body, true }) catch |err| {
            self.broken = true;
            self.stream.shutdown();
            return switch (err) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                error.Timeout => error.Timeout,
                error.ProtocolError => error.ProtocolError,
                else => error.ConnectionLost,
            };
        };
    }

    /// A request the broker does not answer (Produce with acks 0).
    pub fn send(self: *Conn, arena: std.mem.Allocator, api: Api, body: []const u8, timeout: std.Io.Duration) ConnError!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.broken) return error.ConnectionLost;
        const deadline: dusty.Deadline = .init(self.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
        _ = deadline.run(roundTrip, .{ self, arena, api, body, false }) catch |err| {
            self.broken = true;
            self.stream.shutdown();
            return switch (err) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                error.Timeout => error.Timeout,
                else => error.ConnectionLost,
            };
        };
    }

    /// A failed read or write: the cancel that ended it, so it reaches the
    /// caller (C3), else the connection is gone.
    fn lost(cause: ?anyerror) ConnError {
        if (cause) |e| if (e == error.Canceled) return error.Canceled;
        return error.ConnectionLost;
    }

    fn roundTrip(self: *Conn, arena: std.mem.Allocator, api: Api, body: []const u8, want_reply: bool) ConnError![]const u8 {
        const corr = self.correlation;
        self.correlation +%= 1;
        var e: protocol.Enc = .init(arena);
        const at = try e.reserveLen();
        try e.i16_(@backingInt(api));
        try e.i16_(self.versions.get(api));
        try e.i32_(corr);
        try e.string(self.settings.client_id);
        try e.raw(body);
        e.patchLen(at);
        const w = self.stream.writer();
        w.writeAll(e.bytesWritten()) catch return lost(self.stream.writeError());
        w.flush() catch return lost(self.stream.writeError());
        if (!want_reply) return "";
        testHold(self.io, .request_written);
        const r = self.stream.reader();
        var len_buf: [4]u8 = undefined;
        r.readSliceAll(&len_buf) catch return lost(self.stream.readError());
        const len = std.mem.readInt(i32, &len_buf, .big);
        if (len < 4 or len > max_response) return error.ProtocolError;
        const data = r.readAllocAll(arena, @intCast(len)) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => lost(self.stream.readError()),
        };
        if (std.mem.readInt(i32, data[0..4], .big) != corr) return error.ProtocolError;
        return data[4..];
    }
};

// ---------------------------------------------------------------------------
// Metadata

pub const PartInfo = struct { leader: i32, error_code: i16 };

const TopicInfo = struct {
    partitions: []PartInfo,
    error_code: i16,
    fetched_at: std.Io.Clock.Timestamp,
};

const BrokerInfo = struct { host: []u8, port: u16 };

/// owner: Client. M2 process-wide: `deinit` runs after the producer and the
/// consumers are torn down (every task that calls it is joined first).
/// Shared by every executor under `mutex` (L1: real cross-thread state).
pub const Cluster = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    settings: Settings,
    /// "host:port" strings, owned.
    bootstrap: [][]u8,
    teardown: safety.Teardown = .init,
    /// Over `brokers`, `topics` and `refresh_busy`. A leaf (L4): nothing
    /// waits, calls out or takes another lock while it is held.
    mutex: safety.Mutex(.leaf) = .init,
    brokers: std.AutoHashMapUnmanaged(i32, BrokerInfo) = .empty,
    topics: std.StringHashMapUnmanaged(TopicInfo) = .empty,
    /// One metadata refresh at a time (the keyring shape: a flag and a
    /// condition under `mutex`, never a lock held across the round trip).
    /// The round that holds the turn owns `meta_conn`.
    refresh_busy: bool = false,
    refresh_done: safety.Condition = .init,
    meta_conn: ?*Conn = null,
    closing: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, settings: Settings, bootstrap: []const []const u8) !*Cluster {
        if (bootstrap.len == 0) return error.NoBrokers;
        const self = try gpa.create(Cluster);
        errdefer gpa.destroy(self);
        const list = try gpa.alloc([]u8, bootstrap.len);
        var made: usize = 0;
        errdefer {
            for (list[0..made]) |s| gpa.free(s);
            gpa.free(list);
        }
        for (bootstrap, list) |b, *slot| {
            slot.* = try gpa.dupe(u8, b);
            made += 1;
        }
        self.* = .{ .gpa = gpa, .io = io, .settings = settings, .bootstrap = list };
        return self;
    }

    pub fn deinit(self: *Cluster) void {
        self.teardown.begin();
        self.closing.store(true, .release);
        // No round holds the turn: every caller is joined.
        if (self.meta_conn) |c| c.close();
        var bi = self.brokers.iterator();
        while (bi.next()) |e| self.gpa.free(e.value_ptr.host);
        self.brokers.deinit(self.gpa);
        var ti = self.topics.iterator();
        while (ti.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.partitions);
        }
        self.topics.deinit(self.gpa);
        for (self.bootstrap) |s| self.gpa.free(s);
        self.gpa.free(self.bootstrap);
        self.teardown.end();
        self.gpa.destroy(self);
    }

    /// A new connection to broker `id`, from the metadata.
    pub fn connectBroker(self: *Cluster, id: i32) ConnError!*Conn {
        var host_buf: [256]u8 = undefined;
        var port: u16 = 0;
        var host_len: usize = 0;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            const info = self.brokers.get(id) orelse return error.NoBroker;
            if (info.host.len > host_buf.len) return error.NoBroker;
            @memcpy(host_buf[0..info.host.len], info.host);
            host_len = info.host.len;
            port = info.port;
        }
        return Conn.open(self.gpa, self.io, self.settings, host_buf[0..host_len], port, id);
    }

    /// A broker's address as a copy in `buf`, for logs and coordinator lookups.
    pub fn brokerAddress(self: *Cluster, id: i32, buf: *[256]u8) ?HostPort {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const info = self.brokers.get(id) orelse return null;
        if (info.host.len > buf.len) return null;
        @memcpy(buf[0..info.host.len], info.host);
        return .{ .host = buf[0..info.host.len], .port = info.port };
    }

    /// Any broker: the known ones first, then the bootstrap list.
    pub fn connectAny(self: *Cluster) ConnError!*Conn {
        var ids: [64]i32 = undefined;
        var n: usize = 0;
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            var it = self.brokers.keyIterator();
            while (it.next()) |k| {
                if (n == ids.len) break;
                ids[n] = k.*;
                n += 1;
            }
        }
        var last: ConnError = error.NoBroker;
        for (ids[0..n]) |id| {
            return self.connectBroker(id) catch |err| {
                if (err == error.Canceled) return err;
                last = err;
                continue;
            };
        }
        for (self.bootstrap) |text| {
            const hp = parseHostPort(text);
            return Conn.open(self.gpa, self.io, self.settings, hp.host, hp.port, -1) catch |err| {
                if (err == error.Canceled) return err;
                last = err;
                continue;
            };
        }
        return last;
    }

    /// Fetches the metadata of `topics` (just the brokers when empty) and
    /// updates the cache. One round at a time: a caller waits for the turn
    /// (cancelable), then runs its own round holding no lock.
    pub fn refresh(self: *Cluster, topics: []const []const u8, allow_auto_create: bool) ConnError!void {
        try self.takeRefreshTurn();
        // C2: the turn goes back on every exit, a cancel included.
        defer self.giveRefreshTurn();
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var e: protocol.Enc = .init(arena);
        try protocol.encodeMetadata(&e, topics, allow_auto_create);
        var attempts: u32 = 0;
        const body = while (true) : (attempts += 1) {
            if (self.meta_conn == null) self.meta_conn = try self.connectAny();
            const r = self.meta_conn.?.call(arena, .metadata, e.bytesWritten(), self.settings.request_timeout) catch |err| {
                self.meta_conn.?.close();
                self.meta_conn = null;
                if (err == error.Canceled or attempts >= 2) return err;
                continue;
            };
            break r;
        };
        const md = protocol.decodeMetadata(arena, body) catch return error.ProtocolError;
        try self.apply(md);
    }

    fn takeRefreshTurn(self: *Cluster) std.Io.Cancelable!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        while (self.refresh_busy) try self.refresh_done.wait(self.io, &self.mutex);
        self.refresh_busy = true;
    }

    fn giveRefreshTurn(self: *Cluster) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.refresh_busy = false;
        self.refresh_done.broadcast(self.io);
    }

    fn apply(self: *Cluster, md: protocol.Metadata) ConnError!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        for (md.brokers) |b| {
            const port: u16 = std.math.cast(u16, b.port) orelse continue;
            if (self.brokers.getPtr(b.id)) |old| {
                if (std.mem.eql(u8, old.host, b.host) and old.port == port) continue;
                self.gpa.free(old.host);
                old.* = .{ .host = try self.gpa.dupe(u8, b.host), .port = port };
                continue;
            }
            const host = try self.gpa.dupe(u8, b.host);
            errdefer self.gpa.free(host);
            try self.brokers.put(self.gpa, b.id, .{ .host = host, .port = port });
        }
        const now: std.Io.Clock.Timestamp = .now(self.io, .awake);
        for (md.topics) |t| {
            const parts = try self.gpa.alloc(PartInfo, t.partitions.len);
            errdefer self.gpa.free(parts);
            // Partition indexes are dense from 0; place by index.
            for (parts) |*p| p.* = .{ .leader = -1, .error_code = protocol.leader_not_available };
            for (t.partitions) |p| {
                if (p.index >= 0 and @as(usize, @intCast(p.index)) < parts.len) parts[@intCast(p.index)] = .{ .leader = p.leader, .error_code = p.error_code };
            }
            if (self.topics.getPtr(t.name)) |old| {
                self.gpa.free(old.partitions);
                old.* = .{ .partitions = parts, .error_code = t.error_code, .fetched_at = now };
            } else {
                const key = try self.gpa.dupe(u8, t.name);
                errdefer self.gpa.free(key);
                try self.topics.put(self.gpa, key, .{ .partitions = parts, .error_code = t.error_code, .fetched_at = now });
            }
        }
    }

    /// The number of partitions of `topic`, refreshing the metadata when
    /// the topic is unknown or its entry older than `metadata_max_age`.
    /// Null: the topic does not exist (or no leader is known yet).
    pub fn partitionCount(self: *Cluster, topic: []const u8) ConnError!?u32 {
        if (self.lookupCount(topic)) |n| return n;
        try self.refresh(&.{topic}, true);
        return self.lookupCount(topic);
    }

    /// `partitionCount`, but a topic that may still be on its way is asked
    /// for again until it has partitions, at most `max_wait`. A Metadata
    /// request for an unknown topic asks the broker to auto-create it, and
    /// until the topic exists the answers say UNKNOWN_TOPIC_OR_PARTITION
    /// (Kafka 4.x), LEADER_NOT_AVAILABLE (older brokers) or list no
    /// partitions; a topic just created by an admin call looks the same on a
    /// broker the creation has not reached yet. A broker without auto-create
    /// gives the same answer, so those wait the whole `max_wait` too, as
    /// librdkafka's topic.metadata.propagation.max.ms and the Java
    /// producer's max.block.ms do. Any other topic error (authorization, an
    /// invalid name) is null after one refresh.
    pub fn partitionCountWait(self: *Cluster, topic: []const u8, max_wait: std.Io.Duration) ConnError!?u32 {
        if (self.lookupCount(topic)) |n| return n;
        const started: std.Io.Clock.Timestamp = .now(self.io, .awake);
        var pause: std.Io.Duration = .fromMilliseconds(10);
        while (true) {
            try self.refresh(&.{topic}, true);
            testHold(self.io, .metadata_refreshed);
            if (self.lookupCount(topic)) |n| return n;
            if (!self.mayAppear(topic)) return null;
            const elapsed = started.durationTo(.now(self.io, .awake)).raw.nanoseconds;
            if (elapsed >= max_wait.nanoseconds) return null;
            const left: i96 = max_wait.nanoseconds - elapsed;
            try self.io.sleep(.{ .nanoseconds = @min(pause.nanoseconds, left) }, .awake);
            pause = .{ .nanoseconds = @min(pause.nanoseconds * 2, std.Io.Duration.fromMilliseconds(500).nanoseconds) };
        }
    }

    /// Whether the cached answer for `topic` is one a topic being created
    /// gives.
    fn mayAppear(self: *Cluster, topic: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.topics.get(topic) orelse return false;
        return switch (t.error_code) {
            protocol.unknown_topic_or_partition, protocol.leader_not_available => true,
            0 => t.partitions.len == 0,
            else => false,
        };
    }

    fn lookupCount(self: *Cluster, topic: []const u8) ?u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.topics.get(topic) orelse return null;
        if (t.error_code != 0 or t.partitions.len == 0) return null;
        const age = t.fetched_at.durationTo(.now(self.io, .awake)).raw;
        if (age.nanoseconds > self.settings.metadata_max_age.nanoseconds) return null;
        return @intCast(t.partitions.len);
    }

    /// The leader broker of a partition (-1 and null: unknown).
    pub fn leader(self: *Cluster, topic: []const u8, partition: i32) ?i32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.topics.get(topic) orelse return null;
        if (partition < 0 or @as(usize, @intCast(partition)) >= t.partitions.len) return null;
        const p = t.partitions[@intCast(partition)];
        return if (p.leader >= 0 and p.error_code == 0) p.leader else null;
    }

    /// Drops what is known of `topic`, so the next lookup refreshes (after
    /// NOT_LEADER_OR_FOLLOWER and the like).
    pub fn invalidate(self: *Cluster, topic: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.topics.fetchRemove(topic)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.partitions);
        }
    }

    /// Whether the cluster answers: a metadata request for the brokers.
    pub fn ping(self: *Cluster) bool {
        self.refresh(&.{}, false) catch return false;
        return true;
    }
};

test "kafka: host:port parsing takes bracketed IPv6 and defaults the port to 9092" {
    const a = parseHostPort("kafka-1:9093");
    try std.testing.expectEqualStrings("kafka-1", a.host);
    try std.testing.expectEqual(@as(u16, 9093), a.port);
    const b = parseHostPort("[::1]:9094");
    try std.testing.expectEqualStrings("::1", b.host);
    try std.testing.expectEqual(@as(u16, 9094), b.port);
    try std.testing.expectEqual(@as(u16, 9092), parseHostPort("localhost").port);
}
