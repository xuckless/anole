//! Kafka's wire protocol: the primitives, the error codes, and the request
//! encoders and response decoders for the fifteen APIs the client uses, at
//! the versions the broker tables allow from Kafka 2.8 to 4.x and Redpanda
//! (all non-flexible: no tagged fields, 16-bit string lengths, 32-bit array
//! counts). Layouts follow Apache Kafka's
//! `clients/src/main/resources/common/message/*.json`.
const std = @import("std");

pub const Error = error{ Truncated, Invalid } || std.mem.Allocator.Error;

pub const Api = enum(i16) {
    produce = 0,
    fetch = 1,
    list_offsets = 2,
    metadata = 3,
    offset_commit = 8,
    offset_fetch = 9,
    find_coordinator = 10,
    join_group = 11,
    heartbeat = 12,
    leave_group = 13,
    sync_group = 14,
    sasl_handshake = 17,
    api_versions = 18,
    init_producer_id = 22,
    sasl_authenticate = 36,

    /// The version this client speaks (§4.2 of the design).
    pub fn version(self: Api) i16 {
        return switch (self) {
            .produce => 8,
            .fetch => 11,
            .list_offsets => 5,
            .metadata => 8,
            .offset_commit => 7,
            .offset_fetch => 5,
            .find_coordinator => 2,
            .join_group => 5,
            .heartbeat => 3,
            .leave_group => 3,
            .sync_group => 3,
            .sasl_handshake => 1,
            .api_versions => 0,
            .init_producer_id => 1,
            .sasl_authenticate => 1,
        };
    }
};

// ---------------------------------------------------------------------------
// Error codes

pub const ErrorCode = struct { code: i16, name: []const u8, retriable: bool };

const error_table = [_]ErrorCode{
    .{ .code = -1, .name = "UNKNOWN_SERVER_ERROR", .retriable = false },
    .{ .code = 1, .name = "OFFSET_OUT_OF_RANGE", .retriable = false },
    .{ .code = 2, .name = "CORRUPT_MESSAGE", .retriable = true },
    .{ .code = 3, .name = "UNKNOWN_TOPIC_OR_PARTITION", .retriable = true },
    .{ .code = 4, .name = "INVALID_FETCH_SIZE", .retriable = false },
    .{ .code = 5, .name = "LEADER_NOT_AVAILABLE", .retriable = true },
    .{ .code = 6, .name = "NOT_LEADER_OR_FOLLOWER", .retriable = true },
    .{ .code = 7, .name = "REQUEST_TIMED_OUT", .retriable = true },
    .{ .code = 8, .name = "BROKER_NOT_AVAILABLE", .retriable = false },
    .{ .code = 9, .name = "REPLICA_NOT_AVAILABLE", .retriable = true },
    .{ .code = 10, .name = "MESSAGE_TOO_LARGE", .retriable = false },
    .{ .code = 13, .name = "NETWORK_EXCEPTION", .retriable = true },
    .{ .code = 14, .name = "COORDINATOR_LOAD_IN_PROGRESS", .retriable = true },
    .{ .code = 15, .name = "COORDINATOR_NOT_AVAILABLE", .retriable = true },
    .{ .code = 16, .name = "NOT_COORDINATOR", .retriable = true },
    .{ .code = 17, .name = "INVALID_TOPIC_EXCEPTION", .retriable = false },
    .{ .code = 18, .name = "RECORD_LIST_TOO_LARGE", .retriable = false },
    .{ .code = 19, .name = "NOT_ENOUGH_REPLICAS", .retriable = true },
    .{ .code = 20, .name = "NOT_ENOUGH_REPLICAS_AFTER_APPEND", .retriable = true },
    .{ .code = 21, .name = "INVALID_REQUIRED_ACKS", .retriable = false },
    .{ .code = 22, .name = "ILLEGAL_GENERATION", .retriable = false },
    .{ .code = 23, .name = "INCONSISTENT_GROUP_PROTOCOL", .retriable = false },
    .{ .code = 24, .name = "INVALID_GROUP_ID", .retriable = false },
    .{ .code = 25, .name = "UNKNOWN_MEMBER_ID", .retriable = false },
    .{ .code = 26, .name = "INVALID_SESSION_TIMEOUT", .retriable = false },
    .{ .code = 27, .name = "REBALANCE_IN_PROGRESS", .retriable = false },
    .{ .code = 28, .name = "INVALID_COMMIT_OFFSET_SIZE", .retriable = false },
    .{ .code = 29, .name = "TOPIC_AUTHORIZATION_FAILED", .retriable = false },
    .{ .code = 30, .name = "GROUP_AUTHORIZATION_FAILED", .retriable = false },
    .{ .code = 31, .name = "CLUSTER_AUTHORIZATION_FAILED", .retriable = false },
    .{ .code = 33, .name = "UNSUPPORTED_SASL_MECHANISM", .retriable = false },
    .{ .code = 34, .name = "ILLEGAL_SASL_STATE", .retriable = false },
    .{ .code = 35, .name = "UNSUPPORTED_VERSION", .retriable = false },
    .{ .code = 36, .name = "TOPIC_ALREADY_EXISTS", .retriable = false },
    .{ .code = 37, .name = "INVALID_PARTITIONS", .retriable = false },
    .{ .code = 42, .name = "INVALID_REQUEST", .retriable = false },
    .{ .code = 43, .name = "UNSUPPORTED_FOR_MESSAGE_FORMAT", .retriable = false },
    .{ .code = 44, .name = "POLICY_VIOLATION", .retriable = false },
    .{ .code = 45, .name = "OUT_OF_ORDER_SEQUENCE_NUMBER", .retriable = false },
    .{ .code = 46, .name = "DUPLICATE_SEQUENCE_NUMBER", .retriable = false },
    .{ .code = 47, .name = "INVALID_PRODUCER_EPOCH", .retriable = false },
    .{ .code = 48, .name = "INVALID_TXN_STATE", .retriable = false },
    .{ .code = 49, .name = "INVALID_PRODUCER_ID_MAPPING", .retriable = false },
    .{ .code = 51, .name = "CONCURRENT_TRANSACTIONS", .retriable = true },
    .{ .code = 53, .name = "TRANSACTIONAL_ID_AUTHORIZATION_FAILED", .retriable = false },
    .{ .code = 56, .name = "KAFKA_STORAGE_ERROR", .retriable = true },
    .{ .code = 58, .name = "SASL_AUTHENTICATION_FAILED", .retriable = false },
    .{ .code = 59, .name = "UNKNOWN_PRODUCER_ID", .retriable = false },
    .{ .code = 74, .name = "FENCED_LEADER_EPOCH", .retriable = true },
    .{ .code = 75, .name = "UNKNOWN_LEADER_EPOCH", .retriable = true },
    .{ .code = 76, .name = "UNSUPPORTED_COMPRESSION_TYPE", .retriable = false },
    .{ .code = 79, .name = "MEMBER_ID_REQUIRED", .retriable = false },
    .{ .code = 82, .name = "FENCED_INSTANCE_ID", .retriable = false },
    .{ .code = 87, .name = "INVALID_RECORD", .retriable = false },
    .{ .code = 89, .name = "THROTTLING_QUOTA_EXCEEDED", .retriable = true },
};

pub const none: i16 = 0;
pub const offset_out_of_range: i16 = 1;
pub const unknown_topic_or_partition: i16 = 3;
pub const leader_not_available: i16 = 5;
pub const not_leader_or_follower: i16 = 6;
pub const coordinator_load_in_progress: i16 = 14;
pub const coordinator_not_available: i16 = 15;
pub const not_coordinator: i16 = 16;
pub const illegal_generation: i16 = 22;
pub const unknown_member_id: i16 = 25;
pub const rebalance_in_progress: i16 = 27;
pub const out_of_order_sequence: i16 = 45;
pub const duplicate_sequence: i16 = 46;
pub const unknown_producer_id: i16 = 59;
pub const invalid_producer_epoch: i16 = 47;
pub const member_id_required: i16 = 79;
pub const fenced_instance_id: i16 = 82;
pub const sasl_authentication_failed: i16 = 58;

pub fn errorName(code: i16) []const u8 {
    if (code == 0) return "NONE";
    for (error_table) |e| if (e.code == code) return e.name;
    return "UNKNOWN_ERROR";
}

pub fn isRetriable(code: i16) bool {
    for (error_table) |e| if (e.code == code) return e.retriable;
    return false;
}

// ---------------------------------------------------------------------------
// Primitives

/// Appends big-endian values to a growing buffer.
pub const Enc = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Enc {
        return .{ .gpa = gpa };
    }
    pub fn deinit(e: *Enc) void {
        e.buf.deinit(e.gpa);
    }
    pub fn bytesWritten(e: *const Enc) []const u8 {
        return e.buf.items;
    }
    pub fn raw(e: *Enc, b: []const u8) Error!void {
        try e.buf.appendSlice(e.gpa, b);
    }
    pub fn i8_(e: *Enc, v: i8) Error!void {
        try e.buf.append(e.gpa, @bitCast(v));
    }
    pub fn i16_(e: *Enc, v: i16) Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        try e.buf.appendSlice(e.gpa, &b);
    }
    pub fn i32_(e: *Enc, v: i32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        try e.buf.appendSlice(e.gpa, &b);
    }
    pub fn u32_(e: *Enc, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try e.buf.appendSlice(e.gpa, &b);
    }
    pub fn i64_(e: *Enc, v: i64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .big);
        try e.buf.appendSlice(e.gpa, &b);
    }
    pub fn bool_(e: *Enc, v: bool) Error!void {
        try e.i8_(@intFromBool(v));
    }
    pub fn string(e: *Enc, s: []const u8) Error!void {
        if (s.len > std.math.maxInt(i16)) return error.Invalid;
        try e.i16_(@intCast(s.len));
        try e.raw(s);
    }
    pub fn nullableString(e: *Enc, s: ?[]const u8) Error!void {
        if (s) |v| return e.string(v);
        try e.i16_(-1);
    }
    /// A length-prefixed byte string (int32).
    pub fn bytes(e: *Enc, b: []const u8) Error!void {
        try e.i32_(@intCast(b.len));
        try e.raw(b);
    }
    pub fn arrayLen(e: *Enc, n: usize) Error!void {
        try e.i32_(@intCast(n));
    }
    /// Zig-zag varint (records).
    pub fn varint(e: *Enc, v: i32) Error!void {
        try e.varlong(v);
    }
    pub fn varlong(e: *Enc, v: i64) Error!void {
        const bits: u64 = @bitCast(v);
        var u: u64 = (bits << 1) ^ @as(u64, @bitCast(v >> 63));
        while (u >= 0x80) {
            try e.buf.append(e.gpa, @as(u8, @truncate(u)) | 0x80);
            u >>= 7;
        }
        try e.buf.append(e.gpa, @truncate(u));
    }
    /// Reserves an int32 length; `patchLen` fills it with the bytes written since.
    pub fn reserveLen(e: *Enc) Error!usize {
        const at = e.buf.items.len;
        try e.i32_(0);
        return at;
    }
    pub fn patchLen(e: *Enc, at: usize) void {
        const n: i32 = @intCast(e.buf.items.len - at - 4);
        std.mem.writeInt(i32, e.buf.items[at..][0..4], n, .big);
    }
};

/// Reads big-endian values from a slice; strings and bytes borrow from it.
pub const Dec = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Dec {
        return .{ .buf = buf };
    }
    pub fn remaining(d: *const Dec) usize {
        return d.buf.len - d.pos;
    }
    fn take(d: *Dec, n: usize) error{Truncated}![]const u8 {
        if (d.remaining() < n) return error.Truncated;
        defer d.pos += n;
        return d.buf[d.pos..][0..n];
    }
    pub fn skip(d: *Dec, n: usize) error{Truncated}!void {
        _ = try d.take(n);
    }
    pub fn i8_(d: *Dec) error{Truncated}!i8 {
        return @bitCast((try d.take(1))[0]);
    }
    pub fn i16_(d: *Dec) error{Truncated}!i16 {
        return std.mem.readInt(i16, (try d.take(2))[0..2], .big);
    }
    pub fn i32_(d: *Dec) error{Truncated}!i32 {
        return std.mem.readInt(i32, (try d.take(4))[0..4], .big);
    }
    pub fn u32_(d: *Dec) error{Truncated}!u32 {
        return std.mem.readInt(u32, (try d.take(4))[0..4], .big);
    }
    pub fn i64_(d: *Dec) error{Truncated}!i64 {
        return std.mem.readInt(i64, (try d.take(8))[0..8], .big);
    }
    pub fn bool_(d: *Dec) error{Truncated}!bool {
        return (try d.i8_()) != 0;
    }
    pub fn string(d: *Dec) error{ Truncated, Invalid }![]const u8 {
        const n = try d.i16_();
        if (n < 0) return error.Invalid;
        return d.take(@intCast(n));
    }
    pub fn nullableString(d: *Dec) error{ Truncated, Invalid }!?[]const u8 {
        const n = try d.i16_();
        if (n < 0) return null;
        return try d.take(@intCast(n));
    }
    pub fn bytes(d: *Dec) error{ Truncated, Invalid }![]const u8 {
        const n = try d.i32_();
        if (n < 0) return "";
        return d.take(@intCast(n));
    }
    pub fn nullableBytes(d: *Dec) error{ Truncated, Invalid }!?[]const u8 {
        const n = try d.i32_();
        if (n < 0) return null;
        return try d.take(@intCast(n));
    }
    /// An array's count, checked against what could possibly follow (each
    /// element takes at least one byte).
    pub fn arrayLen(d: *Dec) error{ Truncated, Invalid }!usize {
        const n = try d.i32_();
        if (n < 0) return 0;
        if (@as(usize, @intCast(n)) > d.remaining()) return error.Invalid;
        return @intCast(n);
    }
    pub fn varlong(d: *Dec) error{ Truncated, Invalid }!i64 {
        var u: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = (try d.take(1))[0];
            u |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift >= 63) return error.Invalid;
            shift += 7;
        }
        return @as(i64, @bitCast(u >> 1)) ^ -@as(i64, @bitCast(u & 1));
    }
    pub fn varint(d: *Dec) error{ Truncated, Invalid }!i32 {
        const v = try d.varlong();
        return std.math.cast(i32, v) orelse error.Invalid;
    }
};

// ---------------------------------------------------------------------------
// Requests. Each writes the body only; the header is the connection's.

pub fn encodeApiVersions(_: *Enc) Error!void {}

pub fn encodeMetadata(e: *Enc, topics: ?[]const []const u8, allow_auto_create: bool) Error!void {
    if (topics) |ts| {
        try e.arrayLen(ts.len);
        for (ts) |t| try e.string(t);
    } else try e.i32_(-1);
    try e.bool_(allow_auto_create);
    try e.bool_(false); // IncludeClusterAuthorizedOperations
    try e.bool_(false); // IncludeTopicAuthorizedOperations
}

pub fn encodeFindCoordinator(e: *Enc, key: []const u8) Error!void {
    try e.string(key);
    try e.i8_(0); // group
}

pub fn encodeInitProducerId(e: *Enc, timeout_ms: i32) Error!void {
    try e.nullableString(null);
    try e.i32_(timeout_ms);
}

pub fn encodeSaslHandshake(e: *Enc, mechanism: []const u8) Error!void {
    try e.string(mechanism);
}

pub fn encodeSaslAuthenticate(e: *Enc, auth: []const u8) Error!void {
    try e.bytes(auth);
}

pub const ProduceTopic = struct {
    topic: []const u8,
    partitions: []const ProducePartition,
};
pub const ProducePartition = struct { index: i32, batch: []const u8 };

pub fn encodeProduce(e: *Enc, acks: i16, timeout_ms: i32, topics: []const ProduceTopic) Error!void {
    try e.nullableString(null);
    try e.i16_(acks);
    try e.i32_(timeout_ms);
    try e.arrayLen(topics.len);
    for (topics) |t| {
        try e.string(t.topic);
        try e.arrayLen(t.partitions.len);
        for (t.partitions) |p| {
            try e.i32_(p.index);
            try e.bytes(p.batch);
        }
    }
}

pub const FetchPartition = struct { topic: []const u8, partition: i32, offset: i64, max_bytes: i32 };

/// `partitions` grouped by topic in order (callers sort them).
pub fn encodeFetch(e: *Enc, max_wait_ms: i32, min_bytes: i32, max_bytes: i32, partitions: []const FetchPartition) Error!void {
    try e.i32_(-1); // replica id
    try e.i32_(max_wait_ms);
    try e.i32_(min_bytes);
    try e.i32_(max_bytes);
    try e.i8_(0); // read_uncommitted
    try e.i32_(0); // session id
    try e.i32_(-1); // session epoch: no incremental sessions
    var topics: usize = 0;
    var i: usize = 0;
    while (i < partitions.len) : (i += 1) {
        if (i == 0 or !std.mem.eql(u8, partitions[i].topic, partitions[i - 1].topic)) topics += 1;
    }
    try e.arrayLen(topics);
    i = 0;
    while (i < partitions.len) {
        var j = i;
        while (j < partitions.len and std.mem.eql(u8, partitions[j].topic, partitions[i].topic)) j += 1;
        try e.string(partitions[i].topic);
        try e.arrayLen(j - i);
        for (partitions[i..j]) |p| {
            try e.i32_(p.partition);
            try e.i32_(-1); // current leader epoch
            try e.i64_(p.offset);
            try e.i64_(-1); // log start offset
            try e.i32_(p.max_bytes);
        }
        i = j;
    }
    try e.arrayLen(0); // forgotten topics
    try e.string(""); // rack id
}

pub const ListOffsetsPartition = struct { topic: []const u8, partition: i32, timestamp: i64 };

pub fn encodeListOffsets(e: *Enc, partitions: []const ListOffsetsPartition) Error!void {
    try e.i32_(-1);
    try e.i8_(0);
    var topics: usize = 0;
    for (partitions, 0..) |p, i| {
        if (i == 0 or !std.mem.eql(u8, p.topic, partitions[i - 1].topic)) topics += 1;
    }
    try e.arrayLen(topics);
    var i: usize = 0;
    while (i < partitions.len) {
        var j = i;
        while (j < partitions.len and std.mem.eql(u8, partitions[j].topic, partitions[i].topic)) j += 1;
        try e.string(partitions[i].topic);
        try e.arrayLen(j - i);
        for (partitions[i..j]) |p| {
            try e.i32_(p.partition);
            try e.i32_(-1);
            try e.i64_(p.timestamp);
        }
        i = j;
    }
}

pub const JoinProtocol = struct { name: []const u8, metadata: []const u8 };

pub fn encodeJoinGroup(e: *Enc, group: []const u8, session_ms: i32, rebalance_ms: i32, member_id: []const u8, instance_id: ?[]const u8, protocols: []const JoinProtocol) Error!void {
    try e.string(group);
    try e.i32_(session_ms);
    try e.i32_(rebalance_ms);
    try e.string(member_id);
    try e.nullableString(instance_id);
    try e.string("consumer");
    try e.arrayLen(protocols.len);
    for (protocols) |p| {
        try e.string(p.name);
        try e.bytes(p.metadata);
    }
}

pub const SyncAssignment = struct { member_id: []const u8, assignment: []const u8 };

pub fn encodeSyncGroup(e: *Enc, group: []const u8, generation: i32, member_id: []const u8, instance_id: ?[]const u8, assignments: []const SyncAssignment) Error!void {
    try e.string(group);
    try e.i32_(generation);
    try e.string(member_id);
    try e.nullableString(instance_id);
    try e.arrayLen(assignments.len);
    for (assignments) |a| {
        try e.string(a.member_id);
        try e.bytes(a.assignment);
    }
}

pub fn encodeHeartbeat(e: *Enc, group: []const u8, generation: i32, member_id: []const u8, instance_id: ?[]const u8) Error!void {
    try e.string(group);
    try e.i32_(generation);
    try e.string(member_id);
    try e.nullableString(instance_id);
}

pub fn encodeLeaveGroup(e: *Enc, group: []const u8, member_id: []const u8, instance_id: ?[]const u8) Error!void {
    try e.string(group);
    try e.arrayLen(1);
    try e.string(member_id);
    try e.nullableString(instance_id);
}

pub const CommitPartition = struct { topic: []const u8, partition: i32, offset: i64 };

pub fn encodeOffsetCommit(e: *Enc, group: []const u8, generation: i32, member_id: []const u8, instance_id: ?[]const u8, partitions: []const CommitPartition) Error!void {
    try e.string(group);
    try e.i32_(generation);
    try e.string(member_id);
    try e.nullableString(instance_id);
    var topics: usize = 0;
    for (partitions, 0..) |p, i| {
        if (i == 0 or !std.mem.eql(u8, p.topic, partitions[i - 1].topic)) topics += 1;
    }
    try e.arrayLen(topics);
    var i: usize = 0;
    while (i < partitions.len) {
        var j = i;
        while (j < partitions.len and std.mem.eql(u8, partitions[j].topic, partitions[i].topic)) j += 1;
        try e.string(partitions[i].topic);
        try e.arrayLen(j - i);
        for (partitions[i..j]) |p| {
            try e.i32_(p.partition);
            try e.i64_(p.offset);
            try e.i32_(-1);
            try e.nullableString(null);
        }
        i = j;
    }
}

pub const TopicPartition = struct { topic: []const u8, partition: i32 };

pub fn encodeOffsetFetch(e: *Enc, group: []const u8, partitions: []const TopicPartition) Error!void {
    try e.string(group);
    var topics: usize = 0;
    for (partitions, 0..) |p, i| {
        if (i == 0 or !std.mem.eql(u8, p.topic, partitions[i - 1].topic)) topics += 1;
    }
    try e.arrayLen(topics);
    var i: usize = 0;
    while (i < partitions.len) {
        var j = i;
        while (j < partitions.len and std.mem.eql(u8, partitions[j].topic, partitions[i].topic)) j += 1;
        try e.string(partitions[i].topic);
        try e.arrayLen(j - i);
        for (partitions[i..j]) |p| try e.i32_(p.partition);
        i = j;
    }
}

// ---------------------------------------------------------------------------
// Responses. Decoded into `arena`; strings are copied.

pub const Broker = struct { id: i32, host: []const u8, port: i32 };
pub const PartitionMeta = struct { index: i32, leader: i32, error_code: i16 };
pub const TopicMeta = struct { name: []const u8, error_code: i16, partitions: []PartitionMeta };
pub const Metadata = struct { brokers: []Broker, topics: []TopicMeta };

pub fn decodeMetadata(arena: std.mem.Allocator, body: []const u8) Error!Metadata {
    var d: Dec = .init(body);
    _ = try d.i32_(); // throttle
    const nb = try d.arrayLen();
    const brokers = try arena.alloc(Broker, nb);
    for (brokers) |*b| {
        b.id = try d.i32_();
        b.host = try arena.dupe(u8, try d.string());
        b.port = try d.i32_();
        _ = try d.nullableString(); // rack
    }
    _ = try d.nullableString(); // cluster id
    _ = try d.i32_(); // controller
    const nt = try d.arrayLen();
    const topics = try arena.alloc(TopicMeta, nt);
    for (topics) |*t| {
        t.error_code = try d.i16_();
        t.name = try arena.dupe(u8, try d.string());
        _ = try d.bool_(); // internal
        const np = try d.arrayLen();
        t.partitions = try arena.alloc(PartitionMeta, np);
        for (t.partitions) |*p| {
            p.error_code = try d.i16_();
            p.index = try d.i32_();
            p.leader = try d.i32_();
            _ = try d.i32_(); // leader epoch
            for (0..3) |_| { // replicas, isr, offline
                const n = try d.arrayLen();
                try d.skip(n * 4);
            }
        }
        _ = try d.i32_(); // topic authorized operations
    }
    return .{ .brokers = brokers, .topics = topics };
}

pub const ApiRange = struct { key: i16, min: i16, max: i16 };

pub fn decodeApiVersions(arena: std.mem.Allocator, body: []const u8) Error!struct { error_code: i16, apis: []ApiRange } {
    var d: Dec = .init(body);
    const ec = try d.i16_();
    const n = try d.arrayLen();
    const apis = try arena.alloc(ApiRange, n);
    for (apis) |*a| {
        a.key = try d.i16_();
        a.min = try d.i16_();
        a.max = try d.i16_();
    }
    return .{ .error_code = ec, .apis = apis };
}

pub const Coordinator = struct { error_code: i16, node_id: i32, host: []const u8, port: i32 };

pub fn decodeFindCoordinator(arena: std.mem.Allocator, body: []const u8) Error!Coordinator {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const ec = try d.i16_();
    _ = try d.nullableString();
    return .{ .error_code = ec, .node_id = try d.i32_(), .host = try arena.dupe(u8, try d.string()), .port = try d.i32_() };
}

pub const ProducerId = struct { error_code: i16, id: i64, epoch: i16 };

pub fn decodeInitProducerId(body: []const u8) Error!ProducerId {
    var d: Dec = .init(body);
    _ = try d.i32_();
    return .{ .error_code = try d.i16_(), .id = try d.i64_(), .epoch = try d.i16_() };
}

pub fn decodeSaslHandshake(body: []const u8) Error!i16 {
    var d: Dec = .init(body);
    return d.i16_();
}

/// A reply that starts with its error code (SaslHandshake).
pub const decodeSimpleErrorFirst = decodeSaslHandshake;

pub const SaslReply = struct { error_code: i16, message: ?[]const u8, auth: []const u8 };

pub fn decodeSaslAuthenticate(arena: std.mem.Allocator, body: []const u8) Error!SaslReply {
    var d: Dec = .init(body);
    const ec = try d.i16_();
    const msg = try d.nullableString();
    const auth = try d.bytes();
    return .{ .error_code = ec, .message = if (msg) |m| try arena.dupe(u8, m) else null, .auth = try arena.dupe(u8, auth) };
}

pub const ProduceResult = struct { topic: []const u8, partition: i32, error_code: i16, base_offset: i64, log_append_time: i64 };

pub fn decodeProduce(arena: std.mem.Allocator, body: []const u8) Error![]ProduceResult {
    var d: Dec = .init(body);
    const nt = try d.arrayLen();
    var out: std.ArrayList(ProduceResult) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| {
            const index = try d.i32_();
            const ec = try d.i16_();
            const base = try d.i64_();
            const lat = try d.i64_();
            _ = try d.i64_(); // log start offset
            const nr = try d.arrayLen();
            for (0..nr) |_| {
                _ = try d.i32_();
                _ = try d.nullableString();
            }
            _ = try d.nullableString();
            try out.append(arena, .{ .topic = topic, .partition = index, .error_code = ec, .base_offset = base, .log_append_time = lat });
        }
    }
    return out.items;
}

pub const FetchedPartition = struct {
    topic: []const u8,
    partition: i32,
    error_code: i16,
    high_watermark: i64,
    /// The raw record batches (borrowed from the response body).
    records: []const u8,
};

pub fn decodeFetch(arena: std.mem.Allocator, body: []const u8) Error!struct { error_code: i16, partitions: []FetchedPartition } {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const ec = try d.i16_();
    _ = try d.i32_(); // session id
    const nt = try d.arrayLen();
    var out: std.ArrayList(FetchedPartition) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| {
            const index = try d.i32_();
            const pec = try d.i16_();
            const hw = try d.i64_();
            _ = try d.i64_(); // last stable
            _ = try d.i64_(); // log start
            const n_aborted = try d.i32_();
            if (n_aborted > 0) for (0..@as(usize, @intCast(n_aborted))) |_| {
                _ = try d.i64_();
                _ = try d.i64_();
            };
            _ = try d.i32_(); // preferred read replica
            const records = (try d.nullableBytes()) orelse "";
            try out.append(arena, .{ .topic = topic, .partition = index, .error_code = pec, .high_watermark = hw, .records = records });
        }
    }
    return .{ .error_code = ec, .partitions = out.items };
}

pub const ListedOffset = struct { topic: []const u8, partition: i32, error_code: i16, offset: i64 };

pub fn decodeListOffsets(arena: std.mem.Allocator, body: []const u8) Error![]ListedOffset {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const nt = try d.arrayLen();
    var out: std.ArrayList(ListedOffset) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| {
            const index = try d.i32_();
            const ec = try d.i16_();
            _ = try d.i64_(); // timestamp
            const off = try d.i64_();
            _ = try d.i32_(); // leader epoch
            try out.append(arena, .{ .topic = topic, .partition = index, .error_code = ec, .offset = off });
        }
    }
    return out.items;
}

pub const JoinMember = struct { member_id: []const u8, metadata: []const u8 };
pub const Joined = struct {
    error_code: i16,
    generation: i32,
    protocol: []const u8,
    leader: []const u8,
    member_id: []const u8,
    members: []JoinMember,
};

pub fn decodeJoinGroup(arena: std.mem.Allocator, body: []const u8) Error!Joined {
    var d: Dec = .init(body);
    _ = try d.i32_();
    var j: Joined = undefined;
    j.error_code = try d.i16_();
    j.generation = try d.i32_();
    j.protocol = try arena.dupe(u8, try d.string());
    j.leader = try arena.dupe(u8, try d.string());
    j.member_id = try arena.dupe(u8, try d.string());
    const n = try d.arrayLen();
    j.members = try arena.alloc(JoinMember, n);
    for (j.members) |*m| {
        m.member_id = try arena.dupe(u8, try d.string());
        _ = try d.nullableString();
        m.metadata = try arena.dupe(u8, try d.bytes());
    }
    return j;
}

pub fn decodeSyncGroup(arena: std.mem.Allocator, body: []const u8) Error!struct { error_code: i16, assignment: []const u8 } {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const ec = try d.i16_();
    return .{ .error_code = ec, .assignment = try arena.dupe(u8, try d.bytes()) };
}

/// Heartbeat and LeaveGroup start with throttle time and an error code.
pub fn decodeSimpleError(body: []const u8) Error!i16 {
    var d: Dec = .init(body);
    _ = try d.i32_();
    return d.i16_();
}

pub const CommitResult = struct { topic: []const u8, partition: i32, error_code: i16 };

pub fn decodeOffsetCommit(arena: std.mem.Allocator, body: []const u8) Error![]CommitResult {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const nt = try d.arrayLen();
    var out: std.ArrayList(CommitResult) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| try out.append(arena, .{ .topic = topic, .partition = try d.i32_(), .error_code = try d.i16_() });
    }
    return out.items;
}

pub const FetchedOffset = struct { topic: []const u8, partition: i32, offset: i64, error_code: i16 };

pub fn decodeOffsetFetch(arena: std.mem.Allocator, body: []const u8) Error!struct { error_code: i16, offsets: []FetchedOffset } {
    var d: Dec = .init(body);
    _ = try d.i32_();
    const nt = try d.arrayLen();
    var out: std.ArrayList(FetchedOffset) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| {
            const index = try d.i32_();
            const off = try d.i64_();
            _ = try d.i32_(); // leader epoch
            _ = try d.nullableString();
            const ec = try d.i16_();
            try out.append(arena, .{ .topic = topic, .partition = index, .offset = off, .error_code = ec });
        }
    }
    return .{ .error_code = try d.i16_(), .offsets = out.items };
}

// ---------------------------------------------------------------------------
// The consumer protocol's member metadata and assignment (version 0)

pub fn encodeSubscription(e: *Enc, topics: []const []const u8) Error!void {
    try e.i16_(0);
    try e.arrayLen(topics.len);
    for (topics) |t| try e.string(t);
    try e.bytes("");
}

pub fn decodeSubscription(arena: std.mem.Allocator, data: []const u8) Error![]const []const u8 {
    var d: Dec = .init(data);
    _ = try d.i16_();
    const n = try d.arrayLen();
    const out = try arena.alloc([]const u8, n);
    for (out) |*t| t.* = try arena.dupe(u8, try d.string());
    return out;
}

pub fn encodeAssignment(e: *Enc, parts: []const TopicPartition) Error!void {
    try e.i16_(0);
    var topics: usize = 0;
    for (parts, 0..) |p, i| {
        if (i == 0 or !std.mem.eql(u8, p.topic, parts[i - 1].topic)) topics += 1;
    }
    try e.arrayLen(topics);
    var i: usize = 0;
    while (i < parts.len) {
        var j = i;
        while (j < parts.len and std.mem.eql(u8, parts[j].topic, parts[i].topic)) j += 1;
        try e.string(parts[i].topic);
        try e.arrayLen(j - i);
        for (parts[i..j]) |p| try e.i32_(p.partition);
        i = j;
    }
    try e.bytes("");
}

pub fn decodeAssignment(arena: std.mem.Allocator, data: []const u8) Error![]TopicPartition {
    if (data.len == 0) return &.{};
    var d: Dec = .init(data);
    _ = try d.i16_();
    const nt = try d.arrayLen();
    var out: std.ArrayList(TopicPartition) = .empty;
    for (0..nt) |_| {
        const topic = try arena.dupe(u8, try d.string());
        const np = try d.arrayLen();
        for (0..np) |_| try out.append(arena, .{ .topic = topic, .partition = try d.i32_() });
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "varint and varlong: zig-zag" {
    var e: Enc = .init(testing.allocator);
    defer e.deinit();
    const values = [_]i64{ 0, -1, 1, -2, 63, -64, 64, 300, -300, std.math.maxInt(i32), std.math.minInt(i32), std.math.maxInt(i64), std.math.minInt(i64) };
    for (values) |v| try e.varlong(v);
    var d: Dec = .init(e.bytesWritten());
    for (values) |v| try testing.expectEqual(v, try d.varlong());
    try testing.expectEqual(@as(usize, 0), d.remaining());
    // Known encodings.
    var one: Enc = .init(testing.allocator);
    defer one.deinit();
    try one.varint(-1);
    try one.varint(300);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0xd8, 0x04 }, one.bytesWritten());
}

test "Dec: truncation and bad lengths" {
    var d: Dec = .init(&.{ 0, 5, 'a' });
    try testing.expectError(error.Truncated, d.string());
    var d2: Dec = .init(&.{ 0x7f, 0xff, 0xff, 0xff });
    try testing.expectError(error.Invalid, d2.arrayLen());
}

test "error table" {
    try testing.expectEqualStrings("NOT_LEADER_OR_FOLLOWER", errorName(6));
    try testing.expect(isRetriable(6));
    try testing.expect(!isRetriable(58));
    try testing.expectEqualStrings("NONE", errorName(0));
}

test "metadata response round trip through a hand-built body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e: Enc = .init(testing.allocator);
    defer e.deinit();
    try e.i32_(0);
    try e.arrayLen(1);
    try e.i32_(7);
    try e.string("b1");
    try e.i32_(9092);
    try e.nullableString(null);
    try e.nullableString("cluster");
    try e.i32_(7);
    try e.arrayLen(1);
    try e.i16_(0);
    try e.string("t");
    try e.bool_(false);
    try e.arrayLen(2);
    for (0..2) |i| {
        try e.i16_(0);
        try e.i32_(@intCast(i));
        try e.i32_(7);
        try e.i32_(0);
        for (0..3) |_| {
            try e.arrayLen(1);
            try e.i32_(7);
        }
    }
    try e.i32_(0);
    try e.i32_(0);
    const m = try decodeMetadata(arena, e.bytesWritten());
    try testing.expectEqual(@as(usize, 1), m.brokers.len);
    try testing.expectEqualStrings("b1", m.brokers[0].host);
    try testing.expectEqual(@as(usize, 2), m.topics[0].partitions.len);
    try testing.expectEqual(@as(i32, 7), m.topics[0].partitions[1].leader);
}

test "consumer protocol: subscription and assignment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e: Enc = .init(testing.allocator);
    defer e.deinit();
    try encodeSubscription(&e, &.{ "a", "b" });
    const subs = try decodeSubscription(arena, e.bytesWritten());
    try testing.expectEqual(@as(usize, 2), subs.len);
    try testing.expectEqualStrings("b", subs[1]);
    var a: Enc = .init(testing.allocator);
    defer a.deinit();
    try encodeAssignment(&a, &.{ .{ .topic = "a", .partition = 0 }, .{ .topic = "a", .partition = 3 }, .{ .topic = "b", .partition = 1 } });
    const parts = try decodeAssignment(arena, a.bytesWritten());
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqual(@as(i32, 3), parts[1].partition);
    try testing.expectEqualStrings("b", parts[2].topic);
}
