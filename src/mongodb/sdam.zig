//! Server discovery and monitoring, the state machine
//! (specifications: server-discovery-and-monitoring.md): what the client
//! knows of each server and of the deployment, updated from `hello`
//! replies and from the errors operations meet. Pure: no I/O and no
//! clock; the client feeds it and acts on what changed (servers to start
//! or stop monitoring, pools to clear, checks to request).
//!
//! Load-balanced topologies are not covered (the client refuses
//! `loadBalanced=true`).
const std = @import("std");
const bson = @import("bson");

/// The wire versions the client speaks: MongoDB 4.2 and later
/// (libmongoc 2.x's floor), up to what the newest servers report.
pub const client_min_wire_version: i32 = 8;
pub const client_max_wire_version: i32 = 30;

pub const ServerType = enum {
    unknown,
    standalone,
    mongos,
    possible_primary,
    rs_primary,
    rs_secondary,
    rs_arbiter,
    rs_other,
    rs_ghost,

    /// The spec's name ("RSPrimary").
    pub fn specName(t: ServerType) []const u8 {
        return switch (t) {
            .unknown => "Unknown",
            .standalone => "Standalone",
            .mongos => "Mongos",
            .possible_primary => "PossiblePrimary",
            .rs_primary => "RSPrimary",
            .rs_secondary => "RSSecondary",
            .rs_arbiter => "RSArbiter",
            .rs_other => "RSOther",
            .rs_ghost => "RSGhost",
        };
    }

    /// Holds data: what `logicalSessionTimeoutMinutes` is taken from.
    pub fn dataBearing(t: ServerType) bool {
        return switch (t) {
            .standalone, .mongos, .rs_primary, .rs_secondary => true,
            else => false,
        };
    }
};

pub const TopologyType = enum {
    unknown,
    single,
    replica_set_no_primary,
    replica_set_with_primary,
    sharded,

    pub fn specName(t: TopologyType) []const u8 {
        return switch (t) {
            .unknown => "Unknown",
            .single => "Single",
            .replica_set_no_primary => "ReplicaSetNoPrimary",
            .replica_set_with_primary => "ReplicaSetWithPrimary",
            .sharded => "Sharded",
        };
    }
};

pub const TopologyVersion = struct {
    process_id: bson.ObjectId,
    counter: i64,

    pub fn fromValue(v: ?bson.Value) ?TopologyVersion {
        const doc = switch (v orelse return null) {
            .document => |d| d,
            else => return null,
        };
        const pid = doc.get("processId") orelse return null;
        if (pid != .object_id) return null;
        return .{ .process_id = pid.object_id, .counter = intOf(doc.get("counter")) orelse return null };
    }
};

/// `a` against `b`: whether `b` is at least as recent (`b` may replace
/// `a`). An absent version, or another process's, counts as newer.
pub fn notOlder(current: ?TopologyVersion, incoming: ?TopologyVersion) bool {
    const a = current orelse return true;
    const b = incoming orelse return true;
    if (!a.process_id.eql(b.process_id)) return true;
    return b.counter >= a.counter;
}

/// What the client knows of one server, from its last `hello` (or the
/// error in its place). Owns its strings; made by `describe` or
/// `unknown`, given to `Topology.apply`.
pub const Description = struct {
    arena: std.heap.ArenaAllocator,
    /// "host:port", lower case.
    address: []const u8,
    type: ServerType = .unknown,
    /// Why it is Unknown, when an error made it so.
    @"error": ?[]const u8 = null,
    /// The hello's round trip, in nanoseconds.
    rtt_ns: ?u64 = null,
    min_wire_version: i32 = 0,
    max_wire_version: i32 = 0,
    me: ?[]const u8 = null,
    hosts: []const []const u8 = &.{},
    passives: []const []const u8 = &.{},
    arbiters: []const []const u8 = &.{},
    set_name: ?[]const u8 = null,
    set_version: ?i64 = null,
    election_id: ?bson.ObjectId = null,
    primary: ?[]const u8 = null,
    logical_session_timeout_minutes: ?i64 = null,
    topology_version: ?TopologyVersion = null,
    /// For the connections: the server's limits.
    max_bson_object_size: usize = 16 * 1024 * 1024,
    max_message_size: usize = 48_000_000,
    max_write_batch_size: usize = 100_000,
    hello_ok: bool = false,

    pub fn deinit(d: *Description, gpa: std.mem.Allocator) void {
        d.arena.deinit();
        gpa.destroy(d);
    }

    fn members(d: *const Description) [3][]const []const u8 {
        return .{ d.hosts, d.passives, d.arbiters };
    }

    fn lists(d: *const Description, address: []const u8) bool {
        for (d.members()) |list| for (list) |h| if (std.mem.eql(u8, h, address)) return true;
        return false;
    }
};

/// A Description of type Unknown for `address`, with `why` (and the
/// error's `topology_version`) when an error is the reason.
pub fn unknown(gpa: std.mem.Allocator, address: []const u8, why: ?[]const u8, tv: ?TopologyVersion) error{OutOfMemory}!*Description {
    const d = try gpa.create(Description);
    d.* = .{ .arena = .init(gpa), .address = undefined };
    errdefer d.deinit(gpa);
    const a = d.arena.allocator();
    d.address = try a.dupe(u8, address);
    if (why) |w| d.@"error" = try a.dupe(u8, w);
    d.topology_version = tv;
    return d;
}

/// The Description a `hello` (or legacy hello) reply makes for `address`.
pub fn describe(gpa: std.mem.Allocator, address: []const u8, hello: bson.Document, rtt_ns: ?u64) error{OutOfMemory}!*Description {
    const d = try unknown(gpa, address, null, null);
    errdefer d.deinit(gpa);
    const a = d.arena.allocator();
    if (!okOf(hello)) {
        d.@"error" = try a.dupe(u8, stringOf(hello.get("errmsg")) orelse "hello failed");
        return d;
    }
    d.rtt_ns = rtt_ns;
    d.min_wire_version = @intCast(std.math.clamp(intOf(hello.get("minWireVersion")) orelse 0, 0, std.math.maxInt(i32)));
    d.max_wire_version = @intCast(std.math.clamp(intOf(hello.get("maxWireVersion")) orelse 0, 0, std.math.maxInt(i32)));
    d.hello_ok = boolOf(hello.get("helloOk"));
    const primary = boolOf(hello.get("isWritablePrimary")) or (hello.get("isWritablePrimary") == null and boolOf(hello.get("ismaster")));
    d.set_name = if (stringOf(hello.get("setName"))) |s| try a.dupe(u8, s) else null;
    d.type = if (boolOf(hello.get("isreplicaset")))
        .rs_ghost
    else if (std.mem.eql(u8, stringOf(hello.get("msg")) orelse "", "isdbgrid"))
        .mongos
    else if (d.set_name != null)
        (if (primary) .rs_primary else if (boolOf(hello.get("hidden"))) .rs_other else if (boolOf(hello.get("secondary"))) .rs_secondary else if (boolOf(hello.get("arbiterOnly"))) .rs_arbiter else .rs_other)
    else
        .standalone;
    d.hosts = try addresses(a, hello.get("hosts"));
    d.passives = try addresses(a, hello.get("passives"));
    d.arbiters = try addresses(a, hello.get("arbiters"));
    if (stringOf(hello.get("me"))) |me| d.me = try lower(a, me);
    if (stringOf(hello.get("primary"))) |p| d.primary = try lower(a, p);
    d.set_version = intOf(hello.get("setVersion"));
    if (hello.get("electionId")) |v| if (v == .object_id) {
        d.election_id = v.object_id;
    };
    d.logical_session_timeout_minutes = intOf(hello.get("logicalSessionTimeoutMinutes"));
    d.topology_version = TopologyVersion.fromValue(hello.get("topologyVersion"));
    if (intOf(hello.get("maxBsonObjectSize"))) |n| if (n > 0) {
        d.max_bson_object_size = @intCast(n);
    };
    if (intOf(hello.get("maxMessageSizeBytes"))) |n| if (n > 0) {
        d.max_message_size = @intCast(n);
    };
    if (intOf(hello.get("maxWriteBatchSize"))) |n| if (n > 0) {
        d.max_write_batch_size = @intCast(n);
    };
    return d;
}

fn addresses(a: std.mem.Allocator, v: ?bson.Value) error{OutOfMemory}![]const []const u8 {
    const arr = switch (v orelse return &.{}) {
        .array => |x| x,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    var it = arr.iterator();
    while (it.next()) |item| if (item == .string) try out.append(a, try lower(a, item.string));
    return out.items;
}

fn lower(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    return std.ascii.allocLowerString(a, s);
}

pub fn okOf(doc: bson.Document) bool {
    const v = doc.get("ok") orelse return false;
    return switch (v) {
        .double => |f| f == 1,
        .int32 => |n| n == 1,
        .int64 => |n| n == 1,
        .boolean => |b| b,
        else => false,
    };
}

pub fn intOf(v: ?bson.Value) ?i64 {
    return switch (v orelse return null) {
        .int32 => |n| n,
        .int64 => |n| n,
        .double => |f| if (@trunc(f) == f and f >= -9.2e18 and f <= 9.2e18) @intFromFloat(f) else null,
        else => null,
    };
}

pub fn boolOf(v: ?bson.Value) bool {
    return switch (v orelse return false) {
        .boolean => |b| b,
        .int32 => |n| n != 0,
        .int64 => |n| n != 0,
        .double => |f| f != 0,
        else => false,
    };
}

pub fn stringOf(v: ?bson.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// "host:port" for a seed: lower case, 27017 by default, IPv6 in
/// brackets; a Unix socket's path as it is.
pub fn formatAddress(a: std.mem.Allocator, name: []const u8, port: ?u16, unix: bool) error{OutOfMemory}![]const u8 {
    if (unix) return a.dupe(u8, name);
    const host = try std.ascii.allocLowerString(a, name);
    if (std.mem.indexOfScalar(u8, host, ':') != null) return std.fmt.allocPrint(a, "[{s}]:{d}", .{ host, port orelse 27017 });
    return std.fmt.allocPrint(a, "{s}:{d}", .{ host, port orelse 27017 });
}

pub const Settings = struct {
    seeds: []const []const u8,
    /// `replicaSet`.
    set_name: ?[]const u8 = null,
    /// `directConnection=true`: one server, never another.
    direct: bool = false,
};

/// One server in the topology: its description, its pool generation, and
/// whatever the client hangs on it (its monitor and pools).
pub const Server = struct {
    description: *Description,
    /// Bumped when the server's pools are cleared; a connection, and an
    /// error met on one, carries the generation it was made in.
    generation: u32 = 0,
    context: ?*anyopaque = null,
};

/// The client's view of the deployment (TopologyDescription).
pub const Topology = struct {
    gpa: std.mem.Allocator,
    type: TopologyType,
    set_name: ?[]u8 = null,
    max_set_version: ?i64 = null,
    max_election_id: ?bson.ObjectId = null,
    servers: std.ArrayList(Server) = .empty,
    compatible: bool = true,
    compatibility_error: [160]u8 = undefined,
    compatibility_error_len: usize = 0,
    logical_session_timeout_minutes: ?i64 = null,
    seed_count: usize,
    /// The client's contexts of servers removed since the last
    /// `takeRemoved`: monitors to stop, pools to close.
    removed: std.ArrayList(?*anyopaque) = .empty,
    /// Addresses whose check the client should run now (a stale primary,
    /// a state change error).
    check_requests: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, settings: Settings) error{OutOfMemory}!Topology {
        var t: Topology = .{
            .gpa = gpa,
            .type = if (settings.direct) .single else if (settings.set_name != null) .replica_set_no_primary else .unknown,
            .seed_count = settings.seeds.len,
        };
        errdefer t.deinit();
        if (settings.set_name) |s| t.set_name = try gpa.dupe(u8, s);
        for (settings.seeds) |seed| {
            if (t.find(seed) != null) continue;
            try t.add(seed);
        }
        return t;
    }

    pub fn deinit(t: *Topology) void {
        for (t.servers.items) |s| s.description.deinit(t.gpa);
        t.servers.deinit(t.gpa);
        if (t.set_name) |s| t.gpa.free(s);
        t.removed.deinit(t.gpa);
        for (t.check_requests.items) |a| t.gpa.free(a);
        t.check_requests.deinit(t.gpa);
        t.* = undefined;
    }

    pub fn find(t: *Topology, address: []const u8) ?*Server {
        for (t.servers.items) |*s| if (std.mem.eql(u8, s.description.address, address)) return s;
        return null;
    }

    pub fn compatibilityError(t: *const Topology) ?[]const u8 {
        return if (t.compatible) null else t.compatibility_error[0..t.compatibility_error_len];
    }

    /// The contexts of the servers removed since the last call; the
    /// caller owns the slice.
    pub fn takeRemoved(t: *Topology) error{OutOfMemory}![]?*anyopaque {
        return t.removed.toOwnedSlice(t.gpa);
    }

    /// The addresses to check now; the caller frees each and the slice.
    pub fn takeCheckRequests(t: *Topology) error{OutOfMemory}![][]const u8 {
        return t.check_requests.toOwnedSlice(t.gpa);
    }

    fn add(t: *Topology, address: []const u8) error{OutOfMemory}!void {
        const d = try unknown(t.gpa, address, null, null);
        errdefer d.deinit(t.gpa);
        try t.servers.append(t.gpa, .{ .description = d });
    }

    fn remove(t: *Topology, address: []const u8) void {
        for (t.servers.items, 0..) |s, i| if (std.mem.eql(u8, s.description.address, address)) {
            t.removed.append(t.gpa, s.context) catch {};
            s.description.deinit(t.gpa);
            _ = t.servers.orderedRemove(i);
            return;
        };
    }

    fn requestCheck(t: *Topology, address: []const u8) void {
        const copy = t.gpa.dupe(u8, address) catch return;
        t.check_requests.append(t.gpa, copy) catch t.gpa.free(copy);
    }

    /// Replaces a server's description with `d` (taking it) and updates
    /// the topology as the spec's table says. A description of a server
    /// no longer in the topology, or one older than what is known (by
    /// topologyVersion), is dropped.
    pub fn apply(t: *Topology, d: *Description) error{OutOfMemory}!void {
        const server = t.find(d.address) orelse {
            d.deinit(t.gpa);
            return;
        };
        if (!notOlder(server.description.topology_version, d.topology_version)) {
            d.deinit(t.gpa);
            return;
        }
        try t.replace(server, d);
        try t.afterReplace(d.address);
        t.updateCompatibility();
        t.updateSessionTimeout();
    }

    fn replace(t: *Topology, server: *Server, d: *Description) error{OutOfMemory}!void {
        const old = server.description;
        server.description = d;
        old.deinit(t.gpa);
    }

    /// The description now in place for `address` drives the table.
    fn afterReplace(t: *Topology, address: []const u8) error{OutOfMemory}!void {
        const d = t.find(address).?.description;
        switch (t.type) {
            .single => {
                if (t.set_name) |want| {
                    if (d.type != .unknown and (d.set_name == null or !std.mem.eql(u8, d.set_name.?, want))) {
                        try t.markUnknown(address, "the server's replica set name is not replicaSet's", null);
                    }
                }
            },
            .unknown => switch (d.type) {
                .standalone => {
                    if (t.seed_count == 1) t.type = .single else t.remove(address);
                },
                .mongos => t.type = .sharded,
                .rs_primary => {
                    t.type = .replica_set_with_primary;
                    try t.updateRsFromPrimary(address);
                },
                .rs_secondary, .rs_arbiter, .rs_other => {
                    t.type = .replica_set_no_primary;
                    try t.updateRsWithoutPrimary(address);
                },
                else => {},
            },
            .sharded => switch (d.type) {
                .unknown, .mongos, .possible_primary => {},
                else => t.remove(address),
            },
            .replica_set_no_primary => switch (d.type) {
                .standalone, .mongos => t.remove(address),
                .rs_primary => {
                    t.type = .replica_set_with_primary;
                    try t.updateRsFromPrimary(address);
                },
                .rs_secondary, .rs_arbiter, .rs_other => try t.updateRsWithoutPrimary(address),
                else => {},
            },
            .replica_set_with_primary => switch (d.type) {
                .standalone, .mongos => {
                    t.remove(address);
                    t.checkIfHasPrimary();
                },
                .rs_primary => try t.updateRsFromPrimary(address),
                .rs_secondary, .rs_arbiter, .rs_other => try t.updateRsWithPrimaryFromMember(address),
                else => t.checkIfHasPrimary(),
            },
        }
    }

    fn setSetName(t: *Topology, name: []const u8) error{OutOfMemory}!void {
        t.set_name = try t.gpa.dupe(u8, name);
    }

    fn updateRsWithoutPrimary(t: *Topology, address: []const u8) error{OutOfMemory}!void {
        const d = t.find(address).?.description;
        if (t.set_name) |name| {
            if (!std.mem.eql(u8, name, d.set_name.?)) {
                t.remove(address);
                return;
            }
        } else try t.setSetName(d.set_name.?);
        try t.addMembers(d);
        if (d.primary) |p| if (t.find(p)) |s| if (s.description.type == .unknown) {
            s.description.type = .possible_primary;
        };
        // A member that names itself otherwise is known here by another
        // name; it is kept under the one it gives.
        if (d.me) |me| if (!std.mem.eql(u8, me, address)) t.remove(address);
    }

    fn updateRsWithPrimaryFromMember(t: *Topology, address: []const u8) error{OutOfMemory}!void {
        const d = t.find(address).?.description;
        if (t.set_name == null or !std.mem.eql(u8, t.set_name.?, d.set_name.?) or (d.me != null and !std.mem.eql(u8, d.me.?, address))) {
            t.remove(address);
            t.checkIfHasPrimary();
            return;
        }
        if (!t.hasPrimary()) {
            t.type = .replica_set_no_primary;
            if (d.primary) |p| if (t.find(p)) |s| if (s.description.type == .unknown) {
                s.description.type = .possible_primary;
            };
        }
    }

    fn updateRsFromPrimary(t: *Topology, address: []const u8) error{OutOfMemory}!void {
        const d = t.find(address).?.description;
        if (t.set_name) |name| {
            if (!std.mem.eql(u8, name, d.set_name.?)) {
                t.remove(address);
                t.checkIfHasPrimary();
                return;
            }
        } else try t.setSetName(d.set_name.?);

        if (d.max_wire_version >= 17) {
            // electionId first, then setVersion; null is less than any.
            const e = compareElection(d.election_id, t.max_election_id);
            if (e == .gt or (e == .eq and compareOptional(d.set_version, t.max_set_version) != .lt)) {
                t.max_election_id = d.election_id;
                t.max_set_version = d.set_version;
            } else {
                try t.staleTuple(address, d);
                return;
            }
        } else {
            if (d.set_version != null and d.election_id != null) {
                if (t.max_set_version != null and t.max_election_id != null and
                    (t.max_set_version.? > d.set_version.? or
                        (t.max_set_version.? == d.set_version.? and compareElection(t.max_election_id, d.election_id) == .gt)))
                {
                    try t.staleTuple(address, d);
                    return;
                }
                t.max_election_id = d.election_id;
            }
            if (d.set_version) |v| if (t.max_set_version == null or v > t.max_set_version.?) {
                t.max_set_version = v;
            };
        }

        // Any other primary is stale now.
        var i: usize = 0;
        while (i < t.servers.items.len) : (i += 1) {
            const s = t.servers.items[i];
            if (s.description.type == .rs_primary and !std.mem.eql(u8, s.description.address, address)) {
                const other = try t.gpa.dupe(u8, s.description.address);
                defer t.gpa.free(other);
                const u = try unknown(t.gpa, other, "primary marked stale due to discovery of newer primary", null);
                try t.replace(&t.servers.items[i], u);
                t.requestCheck(other);
            }
        }
        const primary = t.find(address).?.description;
        try t.addMembers(primary);
        // Everyone the primary does not list goes (perhaps the primary
        // itself, known by another name), once the list is read.
        var gone: std.ArrayList([]const u8) = .empty;
        defer {
            for (gone.items) |a| t.gpa.free(a);
            gone.deinit(t.gpa);
        }
        for (t.servers.items) |s| {
            if (!primary.lists(s.description.address)) try gone.append(t.gpa, try t.gpa.dupe(u8, s.description.address));
        }
        for (gone.items) |a| t.remove(a);
        t.checkIfHasPrimary();
    }

    fn staleTuple(t: *Topology, address: []const u8, d: *const Description) error{OutOfMemory}!void {
        var buf: [256]u8 = undefined;
        const theirs: [24]u8 = if (d.election_id) |id| id.toHex() else @splat('-');
        const ours: [24]u8 = if (t.max_election_id) |id| id.toHex() else @splat('-');
        const why = std.fmt.bufPrint(&buf, "primary marked stale due to electionId/setVersion mismatch, {s}/{?d} is stale compared to {s}/{?d}", .{
            &theirs, d.set_version, &ours, t.max_set_version,
        }) catch "primary marked stale due to electionId/setVersion mismatch";
        const u = try unknown(t.gpa, address, why, null);
        try t.replace(t.find(address).?, u);
        t.checkIfHasPrimary();
    }

    fn addMembers(t: *Topology, d: *const Description) error{OutOfMemory}!void {
        for (d.members()) |list| for (list) |a| if (t.find(a) == null) try t.add(a);
    }

    fn hasPrimary(t: *Topology) bool {
        for (t.servers.items) |s| if (s.description.type == .rs_primary) return true;
        return false;
    }

    fn checkIfHasPrimary(t: *Topology) void {
        t.type = if (t.hasPrimary()) .replica_set_with_primary else .replica_set_no_primary;
    }

    /// Replaces `address`'s description with Unknown (`why`) and runs the
    /// table for it.
    pub fn markUnknown(t: *Topology, address: []const u8, why: ?[]const u8, tv: ?TopologyVersion) error{OutOfMemory}!void {
        const server = t.find(address) orelse return;
        // `address` may be the old description's, which `replace` frees.
        const u = try unknown(t.gpa, address, why, tv);
        try t.replace(server, u);
        try t.afterReplace(u.address);
        t.updateCompatibility();
        t.updateSessionTimeout();
    }

    fn updateCompatibility(t: *Topology) void {
        t.compatible = true;
        for (t.servers.items) |s| {
            const d = s.description;
            if (d.type == .unknown or d.type == .possible_primary) continue;
            if (d.min_wire_version > client_max_wire_version) {
                t.compatible = false;
                t.setCompatibilityError("Server at {s} requires wire version {d}, but this version of Anole only supports up to {d}.", .{ d.address, d.min_wire_version, client_max_wire_version });
                return;
            }
            if (d.max_wire_version < client_min_wire_version) {
                t.compatible = false;
                t.setCompatibilityError("Server at {s} reports wire version {d}, but this version of Anole requires at least {d} (MongoDB 4.2).", .{ d.address, d.max_wire_version, client_min_wire_version });
                return;
            }
        }
    }

    fn setCompatibilityError(t: *Topology, comptime fmt: []const u8, args: anytype) void {
        t.compatible = false;
        const text = std.fmt.bufPrint(&t.compatibility_error, fmt, args) catch &t.compatibility_error;
        t.compatibility_error_len = text.len;
    }

    fn updateSessionTimeout(t: *Topology) void {
        var out: ?i64 = null;
        var any = false;
        for (t.servers.items) |s| {
            const d = s.description;
            if (!d.type.dataBearing()) continue;
            const v = d.logical_session_timeout_minutes orelse {
                t.logical_session_timeout_minutes = null;
                return;
            };
            out = if (out) |o| @min(o, v) else v;
            any = true;
        }
        t.logical_session_timeout_minutes = if (any) out else null;
    }

    /// The primary, the standalone, or a mongos: where writes and the
    /// default (primary) reads go. Null when there is none to be had.
    pub fn selectWritable(t: *Topology) ?*Server {
        if (!t.compatible) return null;
        var best: ?*Server = null;
        for (t.servers.items) |*s| {
            const ok = switch (t.type) {
                .single => s.description.type != .unknown and s.description.type != .possible_primary,
                .replica_set_with_primary => s.description.type == .rs_primary,
                .sharded => s.description.type == .mongos,
                else => false,
            };
            if (!ok) continue;
            // Among mongoses, the nearest.
            if (best == null or (s.description.rtt_ns orelse std.math.maxInt(u64)) < (best.?.description.rtt_ns orelse std.math.maxInt(u64))) best = s;
        }
        return best;
    }

    /// Handles an error an operation met on `address`: may mark the
    /// server Unknown, clear its pools (bump `generation`) and request a
    /// check, as the spec's "Error handling" says. Returns whether the
    /// pools were cleared.
    pub fn handleError(t: *Topology, e: AppError) error{OutOfMemory}!bool {
        const server = t.find(e.address) orelse return false;
        const generation = e.generation orelse server.generation;
        if (generation < server.generation) return false;
        switch (e.kind) {
            .network => {
                try t.markUnknown(e.address, e.message orelse "network error", null);
                t.find(e.address).?.generation += 1;
                return true;
            },
            // A timeout may be a slow server, not a gone one: the
            // description stays (the spec's error_handling_handshake
            // cases, before and after the handshake alike).
            .timeout => return false,
            .command => {
                const response = e.response orelse return false;
                var code = intOf(response.get("code"));
                var message = stringOf(response.get("errmsg")) orelse "";
                if (okOf(response)) {
                    // Only a write concern error is looked at; writeErrors never.
                    const wce = switch (response.get("writeConcernError") orelse return false) {
                        .document => |d| d,
                        else => return false,
                    };
                    code = intOf(wce.get("code"));
                    message = stringOf(wce.get("errmsg")) orelse "";
                }
                const tv = TopologyVersion.fromValue(response.get("topologyVersion"));
                if (isStateChange(code, message)) {
                    // Stale when what we know is at least as recent.
                    if (server.description.topology_version != null and tv != null and !notOlderStrict(server.description.topology_version.?, tv.?)) return false;
                    try t.markUnknown(e.address, message, tv);
                    t.requestCheck(e.address);
                    if (isShutdown(code) or e.max_wire_version <= 7) {
                        t.find(e.address).?.generation += 1;
                        return true;
                    }
                    return false;
                }
                if (e.when == .before_handshake) {
                    // A failed handshake or authentication.
                    try t.markUnknown(e.address, message, null);
                    t.find(e.address).?.generation += 1;
                    return true;
                }
                return false;
            },
        }
    }
};

/// Whether `incoming` is strictly newer than `current` (for errors: an
/// error carrying the version already known is stale).
fn notOlderStrict(current: TopologyVersion, incoming: TopologyVersion) bool {
    if (!current.process_id.eql(incoming.process_id)) return true;
    return incoming.counter > current.counter;
}

pub const AppError = struct {
    address: []const u8,
    /// The pool generation of the connection it happened on; null for the
    /// current one.
    generation: ?u32 = null,
    max_wire_version: i32 = 0,
    when: When = .after_handshake,
    kind: Kind,
    /// For `.command`: the server's reply.
    response: ?bson.Document = null,
    message: ?[]const u8 = null,

    pub const When = enum { before_handshake, after_handshake };
    pub const Kind = enum { network, timeout, command };
};

const recovering_codes = [_]i64{ 11600, 11602, 13436, 189, 91 };
const not_writable_primary_codes = [_]i64{ 10107, 13435, 10058 };

pub fn isRecovering(code: ?i64, message: []const u8) bool {
    if (code) |c| return std.mem.indexOfScalar(i64, &recovering_codes, c) != null;
    return std.mem.indexOf(u8, message, "not master or secondary") != null or std.mem.indexOf(u8, message, "node is recovering") != null;
}

pub fn isNotWritablePrimary(code: ?i64, message: []const u8) bool {
    if (code) |c| return std.mem.indexOfScalar(i64, &not_writable_primary_codes, c) != null;
    if (isRecovering(null, message)) return false;
    return std.mem.indexOf(u8, message, "not master") != null;
}

pub fn isStateChange(code: ?i64, message: []const u8) bool {
    return isRecovering(code, message) or isNotWritablePrimary(code, message);
}

pub fn isShutdown(code: ?i64) bool {
    const c = code orelse return false;
    return c == 11600 or c == 91;
}

fn compareElection(a: ?bson.ObjectId, b: ?bson.ObjectId) std.math.Order {
    const x = a orelse return if (b == null) .eq else .lt;
    const y = b orelse return .gt;
    return std.mem.order(u8, &x.bytes, &y.bytes);
}

fn compareOptional(a: ?i64, b: ?i64) std.math.Order {
    const x = a orelse return if (b == null) .eq else .lt;
    const y = b orelse return .gt;
    return std.math.order(x, y);
}
