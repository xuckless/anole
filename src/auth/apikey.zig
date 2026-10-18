//! API keys: random, prefixed (`ak_...`) so they are recognisable in logs
//! and secret scanners, and stored only as a SHA-256 (they carry 256 bits,
//! so a slow hash adds nothing). The middleware takes the key from
//! `Authorization: Bearer` or `X-API-Key` and asks a lookup for its owner.
const std = @import("std");
const dusty = @import("dusty");

pub const prefix = "ak_";
pub const Digest = [32]u8;

/// A new key (to show the user once) and its digest (to store).
pub fn generate(arena: std.mem.Allocator, io: std.Io) !struct { key: []const u8, digest: Digest } {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    const key = try arena.alloc(u8, prefix.len + 43);
    @memcpy(key[0..prefix.len], prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(key[prefix.len..], &bytes);
    return .{ .key = key, .digest = digest(key) };
}

pub fn digest(key: []const u8) Digest {
    var d: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &d, .{});
    return d;
}

/// Finds who a key digest belongs to (a database lookup by digest); null
/// for nobody.
pub const Lookup = struct {
    ptr: ?*anyopaque,
    lookup: *const fn (ptr: ?*anyopaque, arena: std.mem.Allocator, digest: Digest) anyerror!?[]const u8,
};

/// The key a request carries, if any.
pub fn fromRequest(req: *dusty.Request) ?[]const u8 {
    if (req.headers.get("Authorization")) |auth| {
        if (std.ascii.startsWithIgnoreCase(auth, "Bearer ")) {
            const k = std.mem.trim(u8, auth["Bearer ".len..], " ");
            if (std.mem.startsWith(u8, k, prefix)) return k;
        }
    }
    return req.headers.get("X-API-Key");
}

/// Requires a valid key: 401 without one. The owner is put in the
/// request's session data as "api_key_owner" for handlers to read.
pub const Middleware = struct {
    lookup: Lookup,

    pub fn init(lookup: Lookup) Middleware {
        return .{ .lookup = lookup };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        const key = fromRequest(req) orelse return unauthorized(res);
        const owner = (try self.lookup.lookup(self.lookup.ptr, req.arena, digest(key))) orelse return unauthorized(res);
        try req.session.set("api_key_owner", owner);
        // Nothing to persist: an API-key request has no session cookie.
        req.session.modified = false;
        return executor.next();
    }

    fn unauthorized(res: *dusty.Response) !void {
        res.status = .unauthorized;
        try res.header("WWW-Authenticate", "Bearer");
        res.content_type = .text;
        res.body = "401 Unauthorized\n";
    }
};

test "generate and digest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const k = try generate(arena.allocator(), std.testing.io);
    try std.testing.expect(std.mem.startsWith(u8, k.key, prefix));
    try std.testing.expectEqual(@as(usize, 46), k.key.len);
    try std.testing.expectEqualSlices(u8, &k.digest, &digest(k.key));
}
