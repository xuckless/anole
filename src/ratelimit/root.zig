//! Rate limiting: a token bucket per key behind a pluggable `Limiter`, kept
//! in memory (`MemoryLimiter`, bounded with LRU eviction) or in
//! Redis/Valkey (`RedisLimiter`, one atomic script, the server's clock), and
//! a middleware that answers 429 with Retry-After.
//!
//!     var limiter = anole.ratelimit.MemoryLimiter.init(gpa, io, .{});
//!     app.use(anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 100, .window = .fromSeconds(60) }));
//!     // by something else than the client's address:
//!     app.use(anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 10, .key = byApiKey }));
//!
//! The bucket arithmetic and the policy and result shapes are adapted from
//! httpx.zig's src/web/middleware/rateLimiter.zig (MIT, Copyright (c)
//! muhammad-fiaz); its eviction, a scan of every entry, is replaced by an
//! LRU list so a full table costs O(1) per new key.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");
const redis = if (features.redis) @import("../redis/root.zig") else struct {};
const db = @import("../db/root.zig");

/// How fast a key may go: `limit` requests per `window`, refilled
/// smoothly, with up to `burst` at once. 100 a minute by default.
pub const Policy = struct {
    /// Requests allowed per window.
    limit: u32 = 100,
    /// The window `limit` is counted over.
    window: std.Io.Duration = .fromSeconds(60),
    /// Bucket size: how many may come at once. 0 means `limit`.
    burst: u32 = 0,

    fn windowMs(p: Policy) i64 {
        return @max(1, p.window.toMilliseconds());
    }

    fn capacity(p: Policy) f64 {
        return @floatFromInt(if (p.burst > 0) p.burst else p.limit);
    }

    fn ratePerMs(p: Policy) f64 {
        return @as(f64, @floatFromInt(p.limit)) / @as(f64, @floatFromInt(p.windowMs()));
    }
};

/// What a `take` decided, with the numbers for the `RateLimit-*` headers.
pub const Result = struct {
    /// Whether the tokens were there (and taken).
    allowed: bool,
    /// The policy's `limit`.
    limit: u32,
    /// Requests left now.
    remaining: u32,
    /// Seconds until the bucket is full again.
    reset_seconds: u32,
    /// Seconds to wait before trying again (when not allowed).
    retry_after_seconds: u32,
};

/// Where buckets live.
pub const Limiter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// What a limiter implements: refill `key`'s bucket, then take `cost`.
    pub const VTable = struct {
        take: *const fn (ptr: *anyopaque, key: []const u8, cost: u32, policy: Policy) anyerror!Result,
    };

    /// Takes `cost` tokens from `key`'s bucket, if it has them.
    pub fn take(l: Limiter, key: []const u8, cost: u32, policy: Policy) !Result {
        return l.vtable.take(l.ptr, key, cost, policy);
    }
};

/// The bucket step: refill for the time passed, then take `cost` if there.
/// `tokens` and `last_ms` are updated in place.
fn step(tokens: *f64, last_ms: *i64, now_ms: i64, cost: u32, policy: Policy) Result {
    const capacity = policy.capacity();
    const rate = policy.ratePerMs();
    const elapsed: f64 = @floatFromInt(@max(0, now_ms - last_ms.*));
    tokens.* = @min(capacity, tokens.* + elapsed * rate);
    last_ms.* = now_ms;
    const cost_f: f64 = @floatFromInt(cost);
    if (tokens.* >= cost_f) {
        tokens.* -= cost_f;
        return .{
            .allowed = true,
            .limit = policy.limit,
            .remaining = @intFromFloat(@floor(tokens.*)),
            .reset_seconds = if (rate > 0) @intFromFloat(@ceil((capacity - tokens.*) / (rate * 1000.0))) else 0,
            .retry_after_seconds = 0,
        };
    }
    const wait_ms = if (rate > 0) (cost_f - tokens.*) / rate else @as(f64, @floatFromInt(policy.windowMs()));
    const retry: u32 = @max(1, @as(u32, @intFromFloat(@ceil(wait_ms / 1000.0))));
    return .{
        .allowed = false,
        .limit = policy.limit,
        .remaining = 0,
        .reset_seconds = if (rate > 0) @intFromFloat(@ceil((capacity - tokens.*) / (rate * 1000.0))) else retry,
        .retry_after_seconds = retry,
    };
}

/// Buckets in this process: bounded, and a bucket is forgotten only when
/// that loses nothing (it is full again), or as a last resort one that
/// still has tokens; a throttled bucket is never pushed out by new keys.
pub const MemoryLimiter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    buckets: std.StringHashMapUnmanaged(*Bucket) = .empty,
    /// Most recently used first.
    lru: std.DoublyLinkedList = .{},
    max_entries: usize,
    idle_ms: i64,
    /// Shared by new keys while the table is full of buckets that cannot
    /// go: a flood of fresh keys then shares one limit.
    overflow: struct { tokens: f64 = -1, last_ms: i64 = 0 } = .{},

    const Bucket = struct {
        key: []u8,
        tokens: f64,
        last_ms: i64,
        /// The policy's numbers at the last take, to tell when it is full.
        capacity: f64,
        rate: f64,
        node: std.DoublyLinkedList.Node = .{},

        fn tokensAt(b: *const Bucket, now_ms: i64) f64 {
            const elapsed: f64 = @floatFromInt(@max(0, now_ms - b.last_ms));
            return @min(b.capacity, b.tokens + elapsed * b.rate);
        }
    };

    /// How far from the least recently used end a new key looks for a
    /// bucket to replace.
    const victim_scan = 16;

    /// `MemoryLimiter` settings.
    pub const Options = struct {
        /// At most this many keys. Past it, a new key replaces the least
        /// recently used bucket that is full again, else one that still
        /// has tokens; when every bucket near that end is throttled, new
        /// keys share one overflow bucket instead.
        max_entries: usize = 10_000,
        /// A key unseen this long is forgotten, once its bucket is full
        /// again (forgetting an emptier one would refill it).
        idle: std.Io.Duration = .fromSeconds(300),
    };

    /// An empty limiter. `io` reads the clock.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) MemoryLimiter {
        return .{ .gpa = gpa, .io = io, .max_entries = @max(1, options.max_entries), .idle_ms = options.idle.toMilliseconds() };
    }

    /// Frees every bucket.
    pub fn deinit(self: *MemoryLimiter) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| self.freeBucket(b.*);
        self.buckets.deinit(self.gpa);
    }

    /// The `Limiter` interface for `Middleware.init`; `self` must outlive it.
    pub fn limiter(self: *MemoryLimiter) Limiter {
        return .{ .ptr = self, .vtable = &.{ .take = takeFn } };
    }

    /// How many keys have a bucket now.
    pub fn count(self: *MemoryLimiter) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buckets.count();
    }

    fn freeBucket(self: *MemoryLimiter, b: *Bucket) void {
        self.gpa.free(b.key);
        self.gpa.destroy(b);
    }

    fn removeLocked(self: *MemoryLimiter, b: *Bucket) void {
        self.lru.remove(&b.node);
        _ = self.buckets.remove(b.key);
        self.freeBucket(b);
    }

    fn takeFn(ptr: *anyopaque, key: []const u8, cost: u32, policy: Policy) anyerror!Result {
        const self: *MemoryLimiter = @ptrCast(@alignCast(ptr));
        return self.takeAt(key, cost, policy, std.Io.Clock.real.now(self.io).toMilliseconds());
    }

    /// `take` at a given time, for tests.
    pub fn takeAt(self: *MemoryLimiter, key: []const u8, cost: u32, policy: Policy, now_ms: i64) !Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // The least recently used end is where idle buckets collect; one
        // that is full again holds nothing worth keeping.
        while (self.lru.last) |n| {
            const b: *Bucket = @fieldParentPtr("node", n);
            if (now_ms - b.last_ms <= self.idle_ms or b.tokensAt(now_ms) < b.capacity) break;
            self.removeLocked(b);
        }
        const bucket = self.buckets.get(key) orelse blk: {
            if (self.buckets.count() >= self.max_entries) {
                const victim = self.victimLocked(now_ms) orelse {
                    // Every bucket in reach is still counting down.
                    if (self.overflow.tokens < 0) self.overflow = .{ .tokens = policy.capacity(), .last_ms = now_ms };
                    return step(&self.overflow.tokens, &self.overflow.last_ms, now_ms, cost, policy);
                };
                self.removeLocked(victim);
            }
            const b = try self.gpa.create(Bucket);
            errdefer self.gpa.destroy(b);
            b.* = .{ .key = try self.gpa.dupe(u8, key), .tokens = policy.capacity(), .last_ms = now_ms, .capacity = policy.capacity(), .rate = policy.ratePerMs() };
            errdefer self.gpa.free(b.key);
            try self.buckets.put(self.gpa, b.key, b);
            self.lru.prepend(&b.node);
            break :blk b;
        };
        self.lru.remove(&bucket.node);
        self.lru.prepend(&bucket.node);
        bucket.capacity = policy.capacity();
        bucket.rate = policy.ratePerMs();
        return step(&bucket.tokens, &bucket.last_ms, now_ms, cost, policy);
    }

    /// The bucket a new key may replace: near the least recently used end,
    /// one that is full again, else one that still has a token; null when
    /// all of those are throttled.
    fn victimLocked(self: *MemoryLimiter, now_ms: i64) ?*Bucket {
        var spare: ?*Bucket = null;
        var node = self.lru.last;
        var seen: usize = 0;
        while (node) |n| : ({
            node = n.prev;
            seen += 1;
        }) {
            if (seen == victim_scan) break;
            const b: *Bucket = @fieldParentPtr("node", n);
            const tokens = b.tokensAt(now_ms);
            if (tokens >= b.capacity) return b;
            if (spare == null and tokens >= 1) spare = b;
        }
        return spare;
    }
};

/// Buckets in Redis/Valkey (-Dredis), shared by every node: one script
/// refills and takes atomically, on the server's clock. On the client's
/// pools (`app.redis`).
pub const RedisLimiter = if (features.redis) struct {
    /// The client buckets go through (`app.redis(.{})`).
    client: *redis.Client,
    /// For the scratch memory of each take.
    gpa: std.mem.Allocator,
    /// Prepended to each key to make the bucket's Redis key.
    prefix: []const u8 = "anole:rl:",

    /// KEYS[1] the bucket; ARGV capacity, rate per ms, cost, window ms.
    /// Returns {allowed, tokens*1000, wait ms}.
    const script =
        \\local t = redis.call('TIME')
        \\local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
        \\local cap = tonumber(ARGV[1]); local rate = tonumber(ARGV[2]); local cost = tonumber(ARGV[3])
        \\local b = redis.call('HMGET', KEYS[1], 'tokens', 'last')
        \\local tokens = tonumber(b[1]) or cap
        \\local last = tonumber(b[2]) or now
        \\tokens = math.min(cap, tokens + math.max(0, now - last) * rate)
        \\local allowed = 0
        \\local wait = 0
        \\if tokens >= cost then tokens = tokens - cost; allowed = 1
        \\elseif rate > 0 then wait = math.ceil((cost - tokens) / rate) end
        \\redis.call('HSET', KEYS[1], 'tokens', tostring(tokens), 'last', now)
        \\redis.call('PEXPIRE', KEYS[1], math.ceil(cap / math.max(rate, 1e-9)) + 1000)
        \\return {allowed, math.floor(tokens * 1000), wait}
    ;

    /// The `Limiter` interface for `Middleware.init`; `self` must outlive
    /// it.
    pub fn limiter(self: *@This()) Limiter {
        return .{ .ptr = self, .vtable = &.{ .take = takeFn } };
    }

    fn takeFn(ptr: *anyopaque, key: []const u8, cost: u32, policy: Policy) anyerror!Result {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const k = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.prefix, key });
        var c: db.Ctx = .{ .io = self.client.io, .arena = arena };
        const items = try self.client.all(i64, &c, .{ "EVAL", script, 1, k, policy.capacity(), policy.ratePerMs(), cost, policy.windowMs() });
        if (items.len != 3) return error.UnexpectedReply;
        const allowed = items[0] == 1;
        const tokens = @as(f64, @floatFromInt(items[1])) / 1000.0;
        const rate = policy.ratePerMs();
        return .{
            .allowed = allowed,
            .limit = policy.limit,
            .remaining = if (allowed) @intFromFloat(@floor(tokens)) else 0,
            .reset_seconds = if (rate > 0) @intFromFloat(@ceil((policy.capacity() - tokens) / (rate * 1000.0))) else 0,
            .retry_after_seconds = if (allowed) 0 else @max(1, @as(u32, @intCast(@divFloor(items[2] + 999, 1000)))),
        };
    }
} else struct {};

/// The key a request is limited by, written into `buf` (128 bytes) or
/// pointing into the request.
pub const KeyFn = *const fn (req: *dusty.Request, buf: []u8) []const u8;

/// The client's address (as trusted proxies report it), without the
/// port: an IPv4 address on its own, an IPv6 one by its /64 network
/// ("2001:db8:1:2::/64"), the block one subscriber or host typically gets,
/// so a client cannot step out of its bucket by changing the low bits.
/// `clientAddressPrefix` chooses another IPv6 prefix.
pub fn clientAddress(req: *dusty.Request, buf: []u8) []const u8 {
    return addressKey(req.remote_address, 64, buf);
}

/// `clientAddress` with IPv6 addresses grouped by their first
/// `ipv6_prefix_bits` bits instead of 64 (128: each address alone; 56 or
/// 48 for providers that hand out larger blocks):
/// `.key = anole.ratelimit.clientAddressPrefix(56)`.
pub fn clientAddressPrefix(comptime ipv6_prefix_bits: u8) KeyFn {
    if (ipv6_prefix_bits > 128) @compileError("an IPv6 prefix is at most 128 bits");
    return struct {
        fn key(req: *dusty.Request, buf: []u8) []const u8 {
            return addressKey(req.remote_address, ipv6_prefix_bits, buf);
        }
    }.key;
}

fn addressKey(address: std.Io.net.IpAddress, ipv6_prefix_bits: u8, buf: []u8) []const u8 {
    var formatted: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&formatted);
    var grouped = false;
    switch (address) {
        .ip4 => |a| w.print("{f}", .{std.Io.net.IpAddress{ .ip4 = .{ .bytes = a.bytes, .port = 0 } }}) catch return "?",
        .ip6 => |a| {
            const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            if (std.mem.eql(u8, a.bytes[0..12], &mapped_prefix)) {
                // An IPv4 client on a dual-stack socket: its IPv4 address.
                w.print("{d}.{d}.{d}.{d}:0", .{ a.bytes[12], a.bytes[13], a.bytes[14], a.bytes[15] }) catch return "?";
            } else {
                var net: std.Io.net.Ip6Address = .{ .port = 0, .bytes = a.bytes };
                for (&net.bytes, 0..) |*b, i| {
                    const first_bit = i * 8;
                    if (first_bit >= ipv6_prefix_bits) {
                        b.* = 0;
                    } else if (first_bit + 8 > ipv6_prefix_bits) {
                        const keep: u4 = @intCast(ipv6_prefix_bits - first_bit);
                        b.* &= @truncate(@as(u16, 0xff00) >> keep);
                    }
                }
                w.print("{f}", .{std.Io.net.IpAddress{ .ip6 = net }}) catch return "?";
                grouped = ipv6_prefix_bits < 128;
            }
        },
    }
    const text = w.buffered();
    // "1.2.3.4:0" / "[2001:db8::]:0"
    var host = text[0 .. std.mem.lastIndexOfScalar(u8, text, ':') orelse text.len];
    if (host.len >= 2 and host[0] == '[') host = host[1 .. host.len - 1];
    if (grouped) return std.fmt.bufPrint(buf, "{s}/{d}", .{ host, ipv6_prefix_bits }) catch "?";
    return std.fmt.bufPrint(buf, "{s}", .{host}) catch "?";
}

/// What `Server.rateLimit` counts requests by.
pub const Key = union(enum) {
    /// The client's address (`clientAddress`).
    ip,
    /// The value of this request header; requests without it share one
    /// bucket.
    header: []const u8,
};

/// A rate limit on a memory limiter of its own, for `Server.rateLimit`:
/// `Middleware`'s answers, counted by a `Key`.
pub const OwnedMiddleware = struct {
    limiter: *MemoryLimiter,
    key: Key,
    policy: Policy,

    pub const detach_safe = true;

    pub fn execute(self: *const OwnedMiddleware, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        var key_buf: [128]u8 = undefined;
        const key = switch (self.key) {
            .ip => clientAddress(req, &key_buf),
            .header => |h| req.headers.get(h) orelse "",
        };
        const r = self.limiter.limiter().take(key, 1, self.policy) catch return next.call();
        try res.header("RateLimit-Limit", try std.fmt.allocPrint(res.arena, "{d}", .{r.limit}));
        try res.header("RateLimit-Remaining", try std.fmt.allocPrint(res.arena, "{d}", .{r.remaining}));
        try res.header("RateLimit-Reset", try std.fmt.allocPrint(res.arena, "{d}", .{r.reset_seconds}));
        if (!r.allowed) {
            try res.header("Retry-After", try std.fmt.allocPrint(res.arena, "{d}", .{r.retry_after_seconds}));
            res.status = .too_many_requests;
            res.content_type = .text;
            res.body = "429 Too Many Requests\n";
            return;
        }
        return next.call();
    }

    pub fn deinit(self: *OwnedMiddleware) void {
        self.limiter.deinit();
        self.limiter.gpa.destroy(self.limiter);
    }
};

/// What `Middleware` does when the limiter fails (Redis is down, say).
pub const OnError = enum {
    /// Let the request through, with a warning in the log: an outage of
    /// the limiter's store does not take the routes down with it.
    allow,
    /// Answer 503 Service Unavailable, with a warning in the log: for
    /// routes where an unlimited burst costs more than an outage (a login,
    /// an expensive call).
    deny,
};

/// Limits every request through it: `RateLimit-*` headers on each
/// response, and 429 with Retry-After once a key's bucket is empty. A
/// limiter that fails lets the request through, or answers 503 with
/// `.on_error = .deny`.
pub const Middleware = struct {
    limiter: Limiter,
    options: Options,

    /// `init`'s options: the policy (`limit` per `window`, up to
    /// `burst` at once), what requests are counted by, and what a failing
    /// limiter means.
    pub const Options = struct {
        /// Requests allowed per window (`Policy.limit`).
        limit: u32 = 100,
        /// The window `limit` is counted over.
        window: std.Io.Duration = .fromSeconds(60),
        /// How many may come at once; 0 means `limit`.
        burst: u32 = 0,
        /// What requests are counted by: the client's address by default
        /// (`clientAddress`). A function of your own limits by an API key, a
        /// user or anything else in the request.
        key: KeyFn = clientAddress,
        /// When the limiter fails: `.allow` (the default) lets the request
        /// through, `.deny` answers 503. Either way a warning is logged.
        on_error: OnError = .allow,

        /// The bucket policy these options describe.
        pub fn policy(o: Options) Policy {
            return .{ .limit = o.limit, .window = o.window, .burst = o.burst };
        }
    };

    /// A middleware taking from `limiter` (which must outlive it) as
    /// `options` say: `.{ .limit = 5, .window = .fromSeconds(60) }` per client
    /// address, `.key` to count by something else.
    pub fn init(limiter: Limiter, options: Options) Middleware {
        return .{ .limiter = limiter, .options = options };
    }

    /// Does nothing after `next()`: requests behind it can detach.
    pub const detach_safe = true;

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        var key_buf: [128]u8 = undefined;
        const key = self.options.key(req, &key_buf);
        const r = self.limiter.take(key, 1, self.options.policy()) catch |err| switch (self.options.on_error) {
            .allow => {
                std.log.scoped(.anole_ratelimit).warn("limiter failed, request let through: {t}", .{err});
                return next.call();
            },
            .deny => {
                std.log.scoped(.anole_ratelimit).warn("limiter failed, request refused (503): {t}", .{err});
                res.status = .service_unavailable;
                res.content_type = .text;
                res.body = "503 Service Unavailable\n";
                return;
            },
        };
        try res.header("RateLimit-Limit", try std.fmt.allocPrint(res.arena, "{d}", .{r.limit}));
        try res.header("RateLimit-Remaining", try std.fmt.allocPrint(res.arena, "{d}", .{r.remaining}));
        try res.header("RateLimit-Reset", try std.fmt.allocPrint(res.arena, "{d}", .{r.reset_seconds}));
        if (!r.allowed) {
            try res.header("Retry-After", try std.fmt.allocPrint(res.arena, "{d}", .{r.retry_after_seconds}));
            res.status = .too_many_requests;
            res.content_type = .text;
            res.body = "429 Too Many Requests\n";
            return;
        }
        return next.call();
    }
};

test "token bucket: burst, refill over time, retry-after" {
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{});
    defer l.deinit();
    const policy: Policy = .{ .limit = 10, .window = .fromMilliseconds(1000) };
    for (0..10) |_| try std.testing.expect((try l.takeAt("a", 1, policy, 0)).allowed);
    const denied = try l.takeAt("a", 1, policy, 0);
    try std.testing.expect(!denied.allowed);
    try std.testing.expectEqual(@as(u32, 1), denied.retry_after_seconds);
    // Half a window later, half the bucket is back.
    const later = try l.takeAt("a", 1, policy, 500);
    try std.testing.expect(later.allowed);
    try std.testing.expectEqual(@as(u32, 4), later.remaining);
    // Another key is untouched.
    try std.testing.expectEqual(@as(u32, 9), (try l.takeAt("b", 1, policy, 500)).remaining);
}

test "MemoryLimiter: bounded by LRU eviction, idle keys dropped" {
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{ .max_entries = 3, .idle = .fromMilliseconds(1000) });
    defer l.deinit();
    // Full again within a second, so idle buckets may go.
    const policy: Policy = .{ .limit = 2, .window = .fromMilliseconds(1000) };
    _ = try l.takeAt("a", 1, policy, 0);
    _ = try l.takeAt("b", 1, policy, 1);
    _ = try l.takeAt("c", 1, policy, 2);
    _ = try l.takeAt("a", 1, policy, 3); // a is now the most recent
    _ = try l.takeAt("d", 1, policy, 4); // evicts b
    try std.testing.expectEqual(@as(usize, 3), l.count());
    try std.testing.expect(!(try l.takeAt("a", 1, policy, 5)).allowed); // a kept its count
    try std.testing.expectEqual(@as(u32, 1), (try l.takeAt("b", 1, policy, 6)).remaining); // b started over
    // Everything idle for over a second goes.
    _ = try l.takeAt("e", 1, policy, 5000);
    try std.testing.expectEqual(@as(usize, 1), l.count());
}

test "Middleware: 429 with Retry-After once the bucket is empty" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var limiter = MemoryLimiter.init(gpa, io, .{});
    defer limiter.deinit();
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var mw = Middleware.init(limiter.limiter(), .{ .limit = 2, .window = .fromMilliseconds(60_000) });
    server.router.use(dusty.Middleware(void).init(&mw));
    server.router.get("/", struct {
        fn h(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "ok";
        }
    }.h);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var statuses: [3]u16 = undefined;
    var last: [1024]u8 = undefined;
    var last_len: usize = 0;
    for (&statuses) |*st| {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        try w.interface.flush();
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var fw: std.Io.Writer = .fixed(&last);
        _ = r.interface.streamRemaining(&fw) catch {};
        last_len = fw.buffered().len;
        st.* = try std.fmt.parseInt(u16, last[9..12], 10);
    }
    try std.testing.expectEqualSlices(u16, &.{ 200, 200, 429 }, &statuses);
    try std.testing.expect(std.mem.indexOf(u8, last[0..last_len], "Retry-After: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, last[0..last_len], "RateLimit-Remaining: 0") != null);
}

test "Middleware: a key of the request's choosing, and on_error" {
    // The failing limiter's warnings are expected here.
    const level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = level;
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var limiter = MemoryLimiter.init(gpa, io, .{});
    defer limiter.deinit();
    const Broken = struct {
        fn take(_: *anyopaque, _: []const u8, _: u32, _: Policy) anyerror!Result {
            return error.ConnectionRefused;
        }
        fn byUser(req: *dusty.Request, _: []u8) []const u8 {
            return req.headers.get("X-User") orelse "anonymous";
        }
    };
    var dummy: u8 = 0;
    const broken: Limiter = .{ .ptr = &dummy, .vtable = &.{ .take = Broken.take } };
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var per_user = Middleware.init(limiter.limiter(), .{ .limit = 1, .key = Broken.byUser });
    var allow = Middleware.init(broken, .{});
    var deny = Middleware.init(broken, .{ .on_error = .deny });
    const M = dusty.Middleware(void);
    const ok = struct {
        fn h(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "ok";
        }
    }.h;
    server.router.group("/user", &[_]M{.init(&per_user)}).get("/", ok);
    server.router.group("/allow", &[_]M{.init(&allow)}).get("/", ok);
    server.router.group("/deny", &[_]M{.init(&deny)}).get("/", ok);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const Get = struct {
        fn status(s: *dusty.Server(void), io_: std.Io, path: []const u8, user: []const u8) !u16 {
            const stream = try s.address.ip.connect(io_, .{ .mode = .stream });
            defer stream.close(io_);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nX-User: {s}\r\nConnection: close\r\n\r\n", .{ path, user });
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            var out: [1024]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&out);
            _ = r.interface.streamRemaining(&fw) catch {};
            return std.fmt.parseInt(u16, fw.buffered()[9..12], 10);
        }
    };
    // One a minute per user: each user has a bucket of their own.
    try std.testing.expectEqual(@as(u16, 200), try Get.status(&server, io, "/user/", "alice"));
    try std.testing.expectEqual(@as(u16, 429), try Get.status(&server, io, "/user/", "alice"));
    try std.testing.expectEqual(@as(u16, 200), try Get.status(&server, io, "/user/", "bob"));
    // A limiter that fails: let through by default, 503 with `.deny`.
    try std.testing.expectEqual(@as(u16, 200), try Get.status(&server, io, "/allow/", "alice"));
    try std.testing.expectEqual(@as(u16, 503), try Get.status(&server, io, "/deny/", "alice"));
}

test "redis: live rate limiter (RedisLimiter)" {
    if (!features.redis) return error.SkipZigTest;
    const live = @import("../redis/live_test.zig");
    if (live.url == null) return error.SkipZigTest;
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    const client = try live.open(io, .{});
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try client.del(&c, "anole:rl:t");
    var rl: RedisLimiter = .{ .client = client, .gpa = gpa };
    const l = rl.limiter();
    const policy: Policy = .{ .limit = 3, .window = .fromMilliseconds(60_000) };
    for (0..3) |_| try std.testing.expect((try l.take("t", 1, policy)).allowed);
    const denied = try l.take("t", 1, policy);
    try std.testing.expect(!denied.allowed);
    try std.testing.expect(denied.retry_after_seconds >= 1);
}

test "clientAddress: IPv6 clients share their /64, IPv4 clients are one address each" {
    var req: dusty.Request = .{ .arena = std.testing.allocator, ._parser = undefined, ._transport = undefined };
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    req.remote_address = try std.Io.net.IpAddress.parse("2001:db8:1:2:aaaa:bbbb:cccc:dddd", 443);
    const first = clientAddress(&req, &a);
    req.remote_address = try std.Io.net.IpAddress.parse("2001:db8:1:2::1", 80);
    try std.testing.expectEqualStrings(first, clientAddress(&req, &b));
    req.remote_address = try std.Io.net.IpAddress.parse("2001:db8:1:3::1", 80);
    try std.testing.expect(!std.mem.eql(u8, first, clientAddress(&req, &b)));
    req.remote_address = try std.Io.net.IpAddress.parse("192.0.2.7", 80);
    try std.testing.expectEqualStrings("192.0.2.7", clientAddress(&req, &a));
    req.remote_address = try std.Io.net.IpAddress.parse("192.0.2.8", 80);
    try std.testing.expectEqualStrings("192.0.2.8", clientAddress(&req, &a));
    // Another prefix, each address alone, and IPv4 on a dual-stack socket.
    req.remote_address = try std.Io.net.IpAddress.parse("2001:db8:1:2ff::1", 80);
    try std.testing.expectEqualStrings("2001:db8:1:200::/56", clientAddressPrefix(56)(&req, &a));
    try std.testing.expectEqualStrings("2001:db8:1:2f0::/60", clientAddressPrefix(60)(&req, &a));
    try std.testing.expectEqualStrings("2001:db8:1:2ff::1", clientAddressPrefix(128)(&req, &a));
    req.remote_address = try std.Io.net.IpAddress.parse("::ffff:192.0.2.9", 80);
    try std.testing.expectEqualStrings("192.0.2.9", clientAddress(&req, &a));
}

test "MemoryLimiter: new keys never push out a throttled bucket" {
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{ .max_entries = 4 });
    defer l.deinit();
    const policy: Policy = .{ .limit = 2, .window = .fromMilliseconds(3_600_000) };
    _ = try l.takeAt("attacker", 1, policy, 0);
    _ = try l.takeAt("attacker", 1, policy, 0);
    try std.testing.expect(!(try l.takeAt("attacker", 1, policy, 0)).allowed);
    // A flood of fresh keys, each throttled in turn.
    var buf: [16]u8 = undefined;
    for (0..1000) |i| {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        _ = try l.takeAt(k, 2, policy, 1);
    }
    try std.testing.expect(l.count() <= 4);
    try std.testing.expect(!(try l.takeAt("attacker", 1, policy, 2)).allowed);
}

test "MemoryLimiter: an idle bucket is forgotten only once it is full again" {
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{ .idle = .fromMilliseconds(1000) });
    defer l.deinit();
    // One an hour: idle for longer than `idle`, still empty.
    const policy: Policy = .{ .limit = 1, .window = .fromMilliseconds(3_600_000) };
    try std.testing.expect((try l.takeAt("a", 1, policy, 0)).allowed);
    _ = try l.takeAt("b", 1, policy, 10_000);
    try std.testing.expect(!(try l.takeAt("a", 1, policy, 10_000)).allowed);
    // A whole window later it is full, and may go.
    _ = try l.takeAt("c", 1, policy, 3_700_000);
    try std.testing.expect((try l.takeAt("a", 1, policy, 3_700_000)).allowed);
}
