// Adapted from karlseguin/smtp_client.zig (MIT, Copyright (c) 2024 Karl Seguin),
// commit 538d0ddc064248b6c1431bfd68df2481f431c0fd. See LICENSE.smtp_client and
// THIRD_PARTY_NOTICES.

//! SMTP AUTH: choosing a mechanism from the server's EHLO line, and the
//! PLAIN and LOGIN responses. CRAM-MD5 is left out (obsolete), and so is
//! XOAUTH2 (it needs a token provider).
const std = @import("std");

pub const Mechanism = enum { plain, login };

/// The mechanism to use from the words of an `AUTH` EHLO line ("PLAIN
/// LOGIN XOAUTH2"): PLAIN when offered, else LOGIN, else none.
pub fn choose(offered: []const u8) ?Mechanism {
    var found: ?Mechanism = null;
    var it = std.mem.tokenizeAny(u8, offered, " =");
    while (it.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "PLAIN")) return .plain;
        if (std.ascii.eqlIgnoreCase(word, "LOGIN")) found = .login;
    }
    return found;
}

/// Base64 of `text`, in `arena`.
pub fn base64(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
    return std.base64.standard.Encoder.encode(out, text);
}

/// The initial response of `AUTH PLAIN`: base64 of `\0user\0password`.
pub fn plain(arena: std.mem.Allocator, username: []const u8, password: []const u8) std.mem.Allocator.Error![]const u8 {
    const raw = try std.fmt.allocPrint(arena, "\x00{s}\x00{s}", .{ username, password });
    defer {
        std.crypto.secureZero(u8, raw);
        arena.free(raw);
    }
    return base64(arena, raw);
}

/// Whether a LOGIN challenge (base64 of "Username:" or "Password:") is the
/// one named; servers differ in case.
pub fn isChallenge(challenge_b64: []const u8, comptime what: enum { username, password }) bool {
    var buf: [32]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(challenge_b64) catch return false;
    if (size > buf.len) return false;
    std.base64.standard.Decoder.decode(buf[0..size], challenge_b64) catch return false;
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, buf[0..size], ": "), switch (what) {
        .username => "Username",
        .password => "Password",
    });
}

const testing = std.testing;

test "choose: PLAIN over LOGIN, LOGIN alone, neither" {
    try testing.expectEqual(Mechanism.plain, choose("LOGIN PLAIN XOAUTH2").?);
    try testing.expectEqual(Mechanism.plain, choose("plain").?);
    try testing.expectEqual(Mechanism.login, choose("CRAM-MD5 LOGIN").?);
    try testing.expect(choose("CRAM-MD5 XOAUTH2") == null);
    try testing.expectEqual(Mechanism.login, choose("=LOGIN").?);
}

test "plain: base64 of NUL user NUL password" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("AHVzZXIAcGFzcw==", try plain(arena.allocator(), "user", "pass"));
}

test "isChallenge: Username: and Password:" {
    try testing.expect(isChallenge("VXNlcm5hbWU6", .username));
    try testing.expect(isChallenge("UGFzc3dvcmQ6", .password));
    try testing.expect(!isChallenge("UGFzc3dvcmQ6", .username));
    try testing.expect(!isChallenge("!!", .password));
}
