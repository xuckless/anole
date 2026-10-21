//! API keys: random, prefixed (`ak_...`) so they are recognisable in logs
//! and secret scanners, and stored only as a SHA-256 (they carry 256 bits,
//! so a slow hash adds nothing; no server secret is involved). The
//! middleware takes the key from `X-API-Key`, or from
//! `Authorization: Bearer ak_...`, and asks a lookup for its owner.
const std = @import("std");
const dusty = @import("dusty");

/// What every generated key starts with. `fromRequest` takes an
/// `Authorization: Bearer` token as a key only when it has this prefix, so
/// API keys and JWTs can share that header.
pub const prefix = "ak_";
/// A key's SHA-256: what the application stores and looks keys up by.
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

/// The digest of `key`, to store at creation and to look it up by.
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

/// The key a request carries, if any:
///
/// - `Authorization: Bearer ak_...`: only with the `ak_` prefix. The same
///   header carries JWTs (`anole.auth.RequireJwt`), and the prefix tells
///   the two apart: a bearer token without it is not an API key, so a
///   route can take either.
/// - `X-API-Key: <key>`: any value, since the header means nothing else.
///   Keys you issued without the prefix (imported from another system)
///   work here.
///
/// The bearer form wins when both are sent.
pub fn fromRequest(req: *dusty.Request) ?[]const u8 {
    if (req.headers.get("Authorization")) |auth| {
        if (std.ascii.startsWithIgnoreCase(auth, "Bearer ")) {
            const k = std.mem.trim(u8, auth["Bearer ".len..], " ");
            if (std.mem.startsWith(u8, k, prefix)) return k;
        }
    }
    return req.headers.get("X-API-Key");
}

/// Where `Middleware` keeps the key's owner in `req.locals`; read it with
/// `owner`.
pub const owner_key = "anole.auth.api_key_owner";

/// The owner `Middleware` found for this request's key, or null on a route
/// without it.
pub fn owner(req: *const dusty.Request) ?[]const u8 {
    return req.local([]const u8, owner_key);
}

/// Requires a valid key (see `fromRequest` for where it is read): 401 with
/// `WWW-Authenticate: Bearer` without one. The owner goes into the
/// request's locals, for the handler to read with `owner(req)`.
pub const Middleware = struct {
    lookup: Lookup,

    /// A middleware that asks `lookup` for the owner of each request's key.
    pub fn init(lookup: Lookup) Middleware {
        return .{ .lookup = lookup };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        const key = fromRequest(req) orelse return unauthorized(res);
        const found = (try self.lookup.lookup(self.lookup.ptr, req.arena, digest(key))) orelse return unauthorized(res);
        try req.setLocal(owner_key, found);
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
