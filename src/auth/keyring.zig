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

    /// Guards the fields below; never held across I/O, a verification or
    /// a log call.
    mutex: std.Io.Mutex = .init,
    /// The current set; null before the first fetch.
    current: ?*Set = null,
    /// A fetch is running (single flight); the others wait on `fetched`.
    /// Set and cleared only by `fetchUnlocked`.
    fetching: bool = false,
    fetched: std.Io.Condition = .init,
    /// Bumped whenever a fetch ends, successful or not.
    generation: u64 = 0,
    /// When the last fetch began (for `min_refresh`).
    attempted_at: i64 = std.math.minInt(i64) / 2,
    /// Fetches failed in a row, and when the next may run.
    backoff: Backoff = .{},

    /// Fetches failed in a row and when the next may run; changed only by
    /// `onFailure` and `onSuccess`, under `mutex`.
    const Backoff = struct {
        failures: u32 = 0,
        until: i64 = std.math.minInt(i64) / 2,

        /// Records a failed fetch at `t`; returns the delay to the next try:
        /// `retry` doubled per failure in a row, at most `max_retry`.
        fn onFailure(b: *Backoff, t: i64, retry: i64, max_retry: i64) i64 {
            b.failures +|= 1;
            const shift: u6 = @intCast(@min(b.failures - 1, 20));
            const delay = @min(max_retry, retry << shift);
            b.until = t + delay;
            return delay;
        }

        fn onSuccess(b: *Backoff) void {
            b.* = .{};
        }
    };

    /// What `obtain` is asked for: a set within its TTL (`seen` null), or
    /// one newer than the set the caller already tried.
    const Want = enum { fresh, newer };

    /// Only a request for a set within its TTL may be served stale keys: a
    /// request for a newer set already holds them.
    const serves_stale = std.EnumArray(Want, bool).init(.{ .fresh = true, .newer = false });

    /// With nothing to serve, a request for a fresh set fails, one for a
    /// newer set gets none.
    const empty_handed = std.EnumArray(Want, Decision).init(.{ .fresh = .fail, .newer = .none });

    /// The numbers `decide` reads, copied under the lock (durations in seconds).
    const Snapshot = struct {
        want: Want,
        t: i64,
        /// `t - current.fetched_at`; null before the first fetch.
        age: ?i64,
        /// `want == .newer`: the current set is the one the caller tried.
        is_seen: bool,
        fetching: bool,
        generation: u64,
        attempted_at: i64,
        retry_at: i64,
        ttl: i64,
        stale: i64,
        min_refresh: i64,

        fn usable(s: Snapshot) bool {
            const age = s.age orelse return false;
            return switch (s.want) {
                .fresh => age <= s.ttl,
                .newer => !s.is_seen,
            };
        }

        /// The current set is within `stale` past its TTL and this request may use it.
        fn staleServes(s: Snapshot) bool {
            const age = s.age orelse return false;
            return serves_stale.get(s.want) and age <= s.ttl +| s.stale;
        }

        /// The fetch waited for ended, or fetches are backing off, with no
        /// usable set: stale keys, else fail or none.
        fn giveUp(s: Snapshot) Decision {
            return if (s.staleServes()) .use_current else empty_handed.get(s.want);
        }
    };

    const Decision = enum {
        /// Take a reference on `current` (usable, or stale but allowed).
        use_current,
        /// Return null: no newer set can be had now.
        none,
        /// Return `error.JwksFetchFailed`.
        fail,
        /// Wait for the running fetch, then decide again.
        wait,
        /// Become the fetcher.
        fetch,
    };

    /// The key-selection rules in order; `waited_for` is the generation a
    /// wait began at. Each step's comment is the rule it keeps.
    fn decide(s: Snapshot, waited_for: ?u64) Decision {
        // 1. The current set serves this request.
        if (s.usable()) return .use_current;
        // 2. The fetch we waited for ended without a set we can use.
        if (waited_for) |g| if (g != s.generation) return s.giveUp();
        // 3. Stale keys serve while the fetch runs; only a request with
        // nothing to verify with waits for it.
        if (s.fetching) return if (s.staleServes()) .use_current else .wait;
        // 4. Unknown-kid refetches are at least `min_refresh` apart.
        if (s.want == .newer and s.t - s.attempted_at < s.min_refresh) return .none;
        // 5. Backing off after a failed fetch.
        if (s.t < s.retry_at) return s.giveUp();
        // 6. This caller fetches; the others wait for it.
        return .fetch;
    }

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
        // A failed fetch is logged after the lock is let go.
        var failed: ?struct { err: anyerror, retry_in: i64 } = null;
        defer if (failed) |f| log.warn("JWKS fetch from {s} failed ({t}); next try in {d}s", .{ self.url, f.err, f.retry_in });
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var waited_for: ?u64 = null;
        while (true) {
            const t = self.now();
            const snap = self.snapshot(seen, t);
            switch (decide(snap, waited_for)) {
                .use_current => return self.refCurrent(),
                .none => return null,
                .fail => return error.JwksFetchFailed,
                .wait => {
                    waited_for = self.generation;
                    try self.fetched.wait(self.io, &self.mutex);
                },
                .fetch => {
                    const set = self.fetchUnlocked(t) catch |err| {
                        if (err == error.Canceled) return err;
                        const retry_in = self.backoff.onFailure(t, self.retry.toSeconds(), self.max_retry.toSeconds());
                        failed = .{ .err = err, .retry_in = retry_in };
                        // Not through `decide`: the raw error, not
                        // `JwksFetchFailed`, when no stale keys serve. Only
                        // the fetcher replaces `current`, so `snap` holds.
                        if (snap.staleServes()) return self.refCurrent();
                        return err;
                    };
                    self.backoff.onSuccess();
                    if (self.current) |old| self.dropLocked(old);
                    self.current = set;
                },
            }
        }
    }

    fn snapshot(self: *const Keyring, seen: ?*Set, t: i64) Snapshot {
        return .{
            .want = if (seen == null) .fresh else .newer,
            .t = t,
            .age = if (self.current) |cur| t - cur.fetched_at else null,
            .is_seen = seen != null and self.current == seen,
            .fetching = self.fetching,
            .generation = self.generation,
            .attempted_at = self.attempted_at,
            .retry_at = self.backoff.until,
            .ttl = self.ttl.toSeconds(),
            .stale = self.stale.toSeconds(),
            .min_refresh = self.min_refresh.toSeconds(),
        };
    }

    /// The current set with a reference taken; `decide` returns
    /// `.use_current` only when there is one.
    fn refCurrent(self: *Keyring) *Set {
        const cur = self.current.?;
        cur.refs += 1;
        return cur;
    }

    /// Runs the one fetch with the lock let go (`fetching` idle -> running
    /// -> idle), then wakes the waiters; the lock is held again on return.
    fn fetchUnlocked(self: *Keyring, t: i64) !*Set {
        self.fetching = true;
        self.attempted_at = t;
        self.mutex.unlock(self.io);
        const fresh = self.fetch();
        self.mutex.lockUncancelable(self.io);
        self.fetching = false;
        self.generation +%= 1;
        self.fetched.broadcast(self.io);
        return fresh;
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

test "Keyring: decide picks one action per snapshot" {
    const never = std.math.minInt(i64) / 2;
    // A snapshot with defaults: t = 1000, ttl 100, stale 1000, min_refresh 60.
    const Row = struct {
        name: []const u8,
        want: Keyring.Want = .fresh,
        t: i64 = 1000,
        age: ?i64 = 10,
        is_seen: bool = false,
        fetching: bool = false,
        generation: u64 = 5,
        attempted_at: i64 = never,
        retry_at: i64 = never,
        ttl: i64 = 100,
        stale: i64 = 1000,
        min_refresh: i64 = 60,
        waited_for: ?u64 = null,
        expect: Keyring.Decision,
    };
    const rows = [_]Row{
        .{ .name = "fresh usable at age == ttl", .age = 100, .expect = .use_current },
        .{ .name = "fresh expired idle", .age = 101, .expect = .fetch },
        .{ .name = "newer, current not seen, very old", .want = .newer, .age = 1 << 40, .expect = .use_current },
        .{ .name = "usable beats moved generation", .want = .newer, .waited_for = 4, .expect = .use_current },
        .{ .name = "moved generation, in stale window", .age = 500, .waited_for = 4, .expect = .use_current },
        .{ .name = "moved generation, no current", .age = null, .waited_for = 4, .expect = .fail },
        .{ .name = "moved generation, past stale window", .age = 1101, .waited_for = 4, .expect = .fail },
        .{ .name = "newer, moved generation", .want = .newer, .is_seen = true, .waited_for = 4, .expect = .none },
        .{ .name = "fetching, age == ttl+stale serves", .fetching = true, .age = 1100, .expect = .use_current },
        .{ .name = "fetching, age == ttl+stale+1 waits", .fetching = true, .age = 1101, .expect = .wait },
        .{ .name = "fetching, no current waits", .fetching = true, .age = null, .expect = .wait },
        .{ .name = "fetching, same generation waits", .fetching = true, .age = 1101, .waited_for = 5, .expect = .wait },
        .{ .name = "moved generation beats fetching", .fetching = true, .age = 1101, .waited_for = 4, .expect = .fail },
        .{ .name = "stale saturates", .fetching = true, .age = 1 << 40, .stale = std.math.maxInt(i64), .expect = .use_current },
        .{ .name = "newer never serves stale", .want = .newer, .is_seen = true, .fetching = true, .age = 500, .attempted_at = 999, .expect = .wait },
        .{ .name = "newer 59 s after attempt", .want = .newer, .is_seen = true, .attempted_at = 941, .expect = .none },
        .{ .name = "newer 60 s after attempt", .want = .newer, .is_seen = true, .attempted_at = 940, .expect = .fetch },
        .{ .name = "fresh ignores min_refresh", .age = 101, .attempted_at = 999, .expect = .fetch },
        .{ .name = "fresh backing off with stale", .age = 500, .retry_at = 1001, .expect = .use_current },
        .{ .name = "fresh backing off without current", .age = null, .retry_at = 1001, .expect = .fail },
        .{ .name = "fresh backing off past stale window", .age = 1101, .retry_at = 1001, .expect = .fail },
        .{ .name = "retry_at edge", .age = 101, .retry_at = 1000, .expect = .fetch },
        .{ .name = "newer backing off", .want = .newer, .is_seen = true, .retry_at = 1001, .expect = .none },
        .{ .name = "newer seen idle", .want = .newer, .is_seen = true, .expect = .fetch },
        .{ .name = "fresh, no current, idle", .age = null, .expect = .fetch },
    };
    for (rows) |row| {
        var s: Keyring.Snapshot = undefined;
        inline for (@typeInfo(Keyring.Snapshot).@"struct".field_names) |name| @field(s, name) = @field(row, name);
        std.testing.expectEqual(row.expect, Keyring.decide(s, row.waited_for)) catch |err| {
            std.debug.print("row: {s}\n", .{row.name});
            return err;
        };
    }
}

test "Keyring: Backoff doubles per failure, caps, limits the shift and resets" {
    var b: Keyring.Backoff = .{};
    for ([_]i64{ 5, 10, 20, 40, 80, 160, 300, 300 }) |want| {
        try std.testing.expectEqual(want, b.onFailure(1000, 5, 300));
        try std.testing.expectEqual(1000 + want, b.until);
    }
    try std.testing.expectEqual(8, b.failures);
    b.onSuccess();
    try std.testing.expectEqual(Keyring.Backoff{}, b);
    try std.testing.expectEqual(std.math.minInt(i64) / 2, b.until);

    b.failures = std.math.maxInt(u32);
    try std.testing.expectEqual(1 << 20, b.onFailure(0, 1, std.math.maxInt(i64)));
    try std.testing.expectEqual(std.math.maxInt(u32), b.failures);
}
