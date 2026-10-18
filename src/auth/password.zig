//! Password hashing: Argon2id in PHC strings (std.crypto.pwhash), at
//! OWASP's parameters by default. `verify` also takes bcrypt hashes, for
//! users carried over from elsewhere; `needsRehash` says when to redo one.
const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const bcrypt = std.crypto.pwhash.bcrypt;

/// OWASP's Argon2id baseline (m = 19 MiB, t = 2, p = 1).
pub const default_params = argon2.Params.owasp_2id;

/// A PHC string ("$argon2id$v=19$m=...") for `password`, in `out`
/// (128 bytes is plenty).
pub fn hash(gpa: std.mem.Allocator, io: std.Io, password: []const u8, out: []u8) ![]const u8 {
    return argon2.strHash(password, .{ .allocator = gpa, .params = default_params, .mode = .argon2id }, out, io);
}

/// Whether `password` matches `stored` (Argon2 PHC, or bcrypt "$2b$...").
/// A malformed `stored` is no match.
pub fn verify(gpa: std.mem.Allocator, io: std.Io, stored: []const u8, password: []const u8) bool {
    if (std.mem.startsWith(u8, stored, "$2")) {
        bcrypt.strVerify(stored, password, .{ .silently_truncate_password = false }) catch return false;
        return true;
    }
    argon2.strVerify(stored, password, .{ .allocator = gpa }, io) catch return false;
    return true;
}

/// Whether `stored` was made with something weaker than `hash` uses now
/// (bcrypt, another Argon2 mode, or smaller parameters): rehash it after
/// the next successful login.
pub fn needsRehash(stored: []const u8) bool {
    if (!std.mem.startsWith(u8, stored, "$argon2id$")) return true;
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "m={d},t={d},p={d}", .{ default_params.m, default_params.t, default_params.p }) catch return true;
    return std.mem.indexOf(u8, stored, want) == null;
}

test "hash, verify, rehash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var buf: [128]u8 = undefined;
    const h = try hash(gpa, io, "correct horse", &buf);
    try std.testing.expect(std.mem.startsWith(u8, h, "$argon2id$"));
    try std.testing.expect(verify(gpa, io, h, "correct horse"));
    try std.testing.expect(!verify(gpa, io, h, "wrong horse"));
    try std.testing.expect(!verify(gpa, io, "garbage", "x"));
    try std.testing.expect(!needsRehash(h));
    try std.testing.expect(needsRehash("$2b$10$abcdefghijklmnopqrstuuJ8x1ZY7aQ9w6pW5V4v3ZQ2l1X0y9z8."));
}
