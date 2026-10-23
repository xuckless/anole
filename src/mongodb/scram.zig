//! MongoDB's side of SCRAM: the exchange itself lives in src/net/scram.zig
//! (shared with Kafka). MongoDB's SCRAM-SHA-1 runs over a hashed password
//! (`hex(md5(user ":mongo:" password))`), SCRAM-SHA-256 over the SASLprep'd
//! one (auth.md).
const std = @import("std");
const net = @import("../net/scram.zig");

pub const Mechanism = net.Mechanism;
pub const Cache = net.Cache;
pub const Conversation = net.Conversation;
pub const Error = net.Error;
pub const max_iterations = net.max_iterations;

/// A conversation as MongoDB runs it for `mechanism` (`.sha1` or `.sha256`).
pub fn newConversation(arena: std.mem.Allocator, mechanism: Mechanism, username: []const u8, password: []const u8, random: [24]u8) Error!Conversation {
    return switch (mechanism) {
        .sha1 => Conversation.init(arena, .sha1, username, try mongoHashedPassword(arena, username, password), random, .none),
        else => Conversation.init(arena, mechanism, username, password, random, .saslprep),
    };
}

/// SCRAM-SHA-1's password: `hex(md5(username ":mongo:" password))`.
pub fn mongoHashedPassword(arena: std.mem.Allocator, username: []const u8, password: []const u8) error{OutOfMemory}![]const u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(username);
    md5.update(":mongo:");
    md5.update(password);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, &hex);
}

test "MongoDB's hashed password (auth.md)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("1c33006ec1ffd90f9cadcbcc0e118200", try mongoHashedPassword(arena, "user", "pencil"));
    var conv = try Conversation.initNonce(arena, .sha1, "user", try mongoHashedPassword(arena, "user", "pencil"), "fyko+d2lbbFgONRv9qkxdawL", .none);
    try std.testing.expectEqualStrings(
        "c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=",
        try conv.clientFinal(arena, std.testing.io, null, "r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000"),
    );
    try conv.verifyServerFinal("v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=");
}
