//! A 12-byte ObjectId: a 4-byte big-endian timestamp in seconds, 5 bytes
//! random per process, and a 3-byte big-endian counter that starts at a
//! random value (specifications/source/bson-objectid/objectid.md).
const std = @import("std");

const ObjectId = @This();

bytes: [12]u8,

/// A new id for this process. Safe from any thread.
pub fn generate(io: std.Io) ObjectId {
    const unique = processUnique(io);
    const seconds: u32 = @truncate(@as(u64, @bitCast(std.Io.Clock.real.now(io).toSeconds())));
    const n = counter.fetchAdd(1, .monotonic) +% @as(u32, @truncate(unique >> 41));
    var id: ObjectId = undefined;
    std.mem.writeInt(u32, id.bytes[0..4], seconds, .big);
    std.mem.writeInt(u40, id.bytes[4..9], @truncate(unique), .big);
    std.mem.writeInt(u24, id.bytes[9..12], @truncate(n), .big);
    return id;
}

// Bits 0..39 the process value, bit 40 "set", bits 41.. the counter's
// random start. A re-exec (SIGUSR2 hand-off) is a new process and draws anew.
var process_value: std.atomic.Value(u64) = .init(0);
var counter: std.atomic.Value(u32) = .init(0);

fn processUnique(io: std.Io) u64 {
    const v = process_value.load(.acquire);
    if (v != 0) return v;
    var r: [8]u8 = undefined;
    io.random(&r);
    const fresh = std.mem.readInt(u64, &r, .little) | (1 << 40);
    return process_value.cmpxchgStrong(0, fresh, .acq_rel, .acquire) orelse fresh;
}

/// The creation time in seconds since the Unix epoch.
pub fn timestamp(id: ObjectId) u32 {
    return std.mem.readInt(u32, id.bytes[0..4], .big);
}

/// From 24 hex digits, either case.
pub fn parse(hex: []const u8) error{InvalidObjectId}!ObjectId {
    if (hex.len != 24) return error.InvalidObjectId;
    var id: ObjectId = undefined;
    _ = std.fmt.hexToBytes(&id.bytes, hex) catch return error.InvalidObjectId;
    return id;
}

/// 24 lowercase hex digits.
pub fn toHex(id: ObjectId) [24]u8 {
    return std.fmt.bytesToHex(id.bytes, .lower);
}

/// The 24 hex digits, for `{f}`.
pub fn format(id: ObjectId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(&id.toHex());
}

/// `std.json` (`res.json`): the 24 hex digits as a string.
pub fn jsonStringify(id: ObjectId, jw: anytype) !void {
    const hex = id.toHex();
    try jw.write(@as([]const u8, &hex));
}

/// Whether the two are the same id.
pub fn eql(a: ObjectId, b: ObjectId) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

test "parse and print" {
    const id = try parse("56E1FC72e0c917e9c4714161");
    try std.testing.expectEqualStrings("56e1fc72e0c917e9c4714161", &id.toHex());
    try std.testing.expectEqual(0x56e1fc72, id.timestamp());
    try std.testing.expectError(error.InvalidObjectId, parse("56e1fc72e0c917e9c471416"));
    try std.testing.expectError(error.InvalidObjectId, parse("56e1fc72e0c917e9c471416g"));
}

test "generated ids share the process bytes and count up" {
    const io = std.testing.io;
    const a = generate(io);
    const b = generate(io);
    try std.testing.expectEqualSlices(u8, a.bytes[4..9], b.bytes[4..9]);
    const ca = std.mem.readInt(u24, a.bytes[9..12], .big);
    const cb = std.mem.readInt(u24, b.bytes[9..12], .big);
    try std.testing.expectEqual(ca +% 1, cb);
    try std.testing.expect(!a.eql(b));
}
