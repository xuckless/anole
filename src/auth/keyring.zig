//! A JWK Set fetched from a URL (an OIDC provider's `jwks_uri`) and kept:
//! refetched when its time is up, or when a token names a key it does not
//! have (providers rotate keys), but no more often than `min_refresh`.
//!
//! The fetch runs outside the lock, one at a time: requests that need it
//! wait for that one fetch, and requests the current keys can serve go on
//! verifying while it runs. Verification runs outside the lock too, on a
//! reference-counted set, so a rotation never frees keys in use.
//!
//! When the provider cannot be reached, the keys in hand stay in use for
//! `stale` past their TTL, and a failed fetch is not tried again
//! for a while (`retry`, doubling up to `max_retry`), so an
//! outage neither fails every request nor turns each one into a fetch.
const std = @import("std");
const jws = @import("jws.zig");
const Client = @import("../client.zig").Client;

const log = std.log.scoped(.anole_auth);

/// A provider's JWK Set behind a URL, fetched on first use and kept. Give it
/// the server's client (`app.client()`) and the provider's `jwks_uri`:
///
///     var keyring = anole.auth.Keyring.init(gpa, app.io(), app.client(), provider.jwks_uri);
///     defer keyring.deinit();
pub const Keyring = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: Client,
    url: []const u8,
    /// Keys are refetched this long after the last fetch.
    ttl: std.Io.Duration = .fromSeconds(3600),
    /// Fetches for an unknown `kid` are at least this far apart, so a
    /// stream of bogus tokens cannot make us hammer the provider.
    min_refresh: std.Io.Duration = .fromSeconds(60),
    /// While refetching fails, keys past their TTL are still used for this
    /// long (a day by default): an outage at the provider does not fail
    /// every request at once. Rotation away from a compromised key needs
    /// the provider to be reachable either way.
    stale: std.Io.Duration = .fromSeconds(24 * 3600),
    /// After a failed fetch, the next waits this long, doubling with each
    /// failure up to `max_retry`. Meanwhile requests use the stale
    /// keys, or fail at once (`error.JwksFetchFailed`) when there are none.
    retry: std.Io.Duration = .fromSeconds(5),
    max_retry: std.Io.Duration = .fromSeconds(300),

    /// Guards the fields below; never held across I/O or a verification.
    mutex: std.Io.Mutex = .init,
    /// The current set; null before the first fetch.
    current: ?*Set = null,
    /// A fetch is running (single flight); the others wait on `fetched`.
    fetching: bool = false,
    fetched: std.Io.Condition = .init,
    /// Bumped whenever a fetch ends, successful or not.
    generation: u64 = 0,
    /// When the last fetch began (for `min_refresh`).
    attempted_at: i64 = std.math.minInt(i64) / 2,
    /// Fetches failed in a row, and when the next may run.
    failures: u32 = 0,
    retry_at: i64 = std.math.minInt(i64) / 2,

    /// One fetched set, kept alive while verifications use it.
    const Set = struct {
        arena: std.heap.ArenaAllocator,
        keys: []const jws.Key,
        fetched_at: i64,
        /// One for being `current`, one per verification holding it.
        refs: usize = 1,
    };

    /// A keyring for the JWK Set at `url`, fetched through `client` (the
    /// server's, `app.client()` or `anole.client(io)`). Nothing is fetched
    /// until the first `verify`. `client`'s server and `url` must outlive it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: Client, url: []const u8) Keyring {
        return .{ .gpa = gpa, .io = io, .client = client, .url = url };
    }

    /// No verification may still be running.
    pub fn deinit(self: *Keyring) void {
        if (self.current) |set| self.free(set);
        self.current = null;
    }

    fn now(self: *Keyring) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    /// Verifies `token` with the provider's keys and checks it against
    /// `policy`, which must name an `audience` (`error.AudienceRequired`
    /// otherwise, unless `allow_any_audience`). Fetches the set on first use, on expiry, and once more
    /// when the token's key is unknown. A request that finds a fetch
    /// running waits for it only when the current keys cannot serve it;
    /// if that fetch fails, it gets `error.JwksFetchFailed`.
    pub fn verify(self: *Keyring, arena: std.mem.Allocator, token: []const u8, policy: jws.Policy) !jws.Verified {
        // A provider's keys sign for every one of its clients: without an
        // audience, their tokens for other applications would pass here.
        if (policy.audience == null and !policy.allow_any_audience) return error.AudienceRequired;
        const set = (try self.obtain(null)).?;
        defer self.release(set);
        return jws.verify(arena, token, set.keys, policy, self.now()) catch |err| switch (err) {
            error.NoMatchingKey => {
                // Rotated, perhaps: try a newer set, if one can be had.
                const newer = (try self.obtain(set)) orelse return err;
                defer self.release(newer);
                return jws.verify(arena, token, newer.keys, policy, self.now());
            },
            else => |e| return e,
        };
    }

    /// With `seen` null: a set within its TTL, fetching one (or waiting
    /// for the fetch running) when there is none; while fetches fail, the
    /// set within `stale` past its TTL. With `seen`: a set newer
    /// than `seen`, fetching one unless the last fetch began less than
    /// `min_refresh` ago or fetches are backing off; null when
    /// there is none. The caller releases what it gets.
    fn obtain(self: *Keyring, seen: ?*Set) !?*Set {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var waited_for: ?u64 = null;
        while (true) {
            const t = self.now();
            if (self.current) |cur| {
                const usable = if (seen) |s| cur != s else t - cur.fetched_at <= self.ttl.toSeconds();
                if (usable) {
                    cur.refs += 1;
                    return cur;
                }
            }
            if (waited_for) |g| if (g != self.generation) {
                // The fetch we waited for ended without a set we can use.
                if (seen != null) return null;
                return self.staleLocked(t) orelse error.JwksFetchFailed;
            };
            if (self.fetching) {
                // Stale keys serve while the fetch runs; only a request
                // with nothing to verify with waits for it.
                if (seen == null) if (self.staleLocked(t)) |stale| return stale;
                waited_for = self.generation;
                try self.fetched.wait(self.io, &self.mutex);
                continue;
            }
            if (seen != null and t - self.attempted_at < self.min_refresh.toSeconds()) return null;
            if (t < self.retry_at) {
                // Backing off after a failed fetch.
                if (seen != null) return null;
                return self.staleLocked(t) orelse error.JwksFetchFailed;
            }

            // This caller fetches, unlocked; the others wait for it.
            self.fetching = true;
            self.attempted_at = t;
            self.mutex.unlock(self.io);
            const fresh = self.fetch();
            self.mutex.lockUncancelable(self.io);
            self.fetching = false;
            self.generation +%= 1;
            self.fetched.broadcast(self.io);
            const set = fresh catch |err| {
                if (err == error.Canceled) return err;
                self.failures +|= 1;
                const shift: u6 = @intCast(@min(self.failures - 1, 20));
                self.retry_at = t + @min(self.max_retry.toSeconds(), self.retry.toSeconds() << shift);
                log.warn("JWKS fetch from {s} failed ({t}); next try in {d}s", .{ self.url, err, self.retry_at - t });
                if (seen == null) if (self.staleLocked(t)) |stale| return stale;
                return err;
            };
            self.failures = 0;
            self.retry_at = std.math.minInt(i64) / 2;
            if (self.current) |old| self.dropLocked(old);
            self.current = set;
        }
    }

    /// The current set while it is within `stale` past its TTL,
    /// with a reference taken; null otherwise.
    fn staleLocked(self: *Keyring, t: i64) ?*Set {
        const cur = self.current orelse return null;
        if (t - cur.fetched_at > self.ttl.toSeconds() +| self.stale.toSeconds()) return null;
        cur.refs += 1;
        return cur;
    }

    fn release(self: *Keyring, set: *Set) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropLocked(set);
    }

    fn dropLocked(self: *Keyring, set: *Set) void {
        set.refs -= 1;
        if (set.refs == 0) self.free(set);
    }

    fn free(self: *Keyring, set: *Set) void {
        set.arena.deinit();
        self.gpa.destroy(set);
    }

    /// Fetches and parses the set, with no lock held.
    fn fetch(self: *Keyring) !*Set {
        const set = try self.gpa.create(Set);
        set.* = .{ .arena = .init(self.gpa), .keys = &.{}, .fetched_at = 0 };
        errdefer self.free(set);
        var response = try self.client.http.fetch(self.url, .{});
        defer response.deinit();
        if (response.status() != .ok) return error.JwksFetchFailed;
        const body = (try response.body()) orelse return error.JwksFetchFailed;
        const a = set.arena.allocator();
        set.keys = try jws.parseJwks(a, try a.dupe(u8, body));
        set.fetched_at = self.now();
        return set;
    }
};

test {
    _ = @import("keyring_test.zig");
}
