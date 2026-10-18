//! A JWK Set fetched from a URL (an OIDC provider's `jwks_uri`) and kept:
//! refetched when its time is up, or when a token names a key it does not
//! have (providers rotate keys), but no more often than `min_refresh`.
const std = @import("std");
const dusty = @import("dusty");
const jws = @import("jws.zig");

pub const Keyring = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *dusty.Client,
    url: []const u8,
    /// Keys are refetched this long after the last fetch.
    ttl_seconds: i64 = 3600,
    /// Fetches for an unknown `kid` are at least this far apart, so a
    /// stream of bogus tokens cannot make us hammer the provider.
    min_refresh_seconds: i64 = 60,

    mutex: std.Io.Mutex = .init,
    /// The current set and the arena it lives in.
    arena: ?*std.heap.ArenaAllocator = null,
    keys: []const jws.Key = &.{},
    fetched_at: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: *dusty.Client, url: []const u8) Keyring {
        return .{ .gpa = gpa, .io = io, .client = client, .url = url };
    }

    pub fn deinit(self: *Keyring) void {
        if (self.arena) |a| {
            a.deinit();
            self.gpa.destroy(a);
        }
    }

    fn now(self: *Keyring) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    /// Verifies `token` with the provider's keys and checks it against
    /// `policy`. Fetches the set on first use, on expiry, and once more
    /// when the token's key is unknown.
    pub fn verify(self: *Keyring, arena: std.mem.Allocator, token: []const u8, policy: jws.Policy) !jws.Verified {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const t = self.now();
        if (self.arena == null or t - self.fetched_at > self.ttl_seconds) try self.refreshLocked();
        return jws.verify(arena, token, self.keys, policy, t) catch |err| switch (err) {
            error.NoMatchingKey => {
                if (self.now() - self.fetched_at < self.min_refresh_seconds) return err;
                try self.refreshLocked();
                return jws.verify(arena, token, self.keys, policy, self.now());
            },
            else => |e| return e,
        };
    }

    fn refreshLocked(self: *Keyring) !void {
        const fresh = try self.gpa.create(std.heap.ArenaAllocator);
        fresh.* = .init(self.gpa);
        errdefer {
            fresh.deinit();
            self.gpa.destroy(fresh);
        }
        var response = try self.client.fetch(self.url, .{});
        defer response.deinit();
        if (response.status() != .ok) return error.JwksFetchFailed;
        const body = (try response.body()) orelse return error.JwksFetchFailed;
        const keys = try jws.parseJwks(fresh.allocator(), try fresh.allocator().dupe(u8, body));
        if (self.arena) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.arena = fresh;
        self.keys = keys;
        self.fetched_at = self.now();
    }
};
