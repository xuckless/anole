//! Rate limiting: a token bucket per key behind a pluggable `Limiter`, kept
//! in memory (`MemoryLimiter`, bounded with LRU eviction) or in
//! Redis/Valkey (`RedisLimiter`, one atomic script, the server's clock), and
//! a middleware that answers 429 with Retry-After.
//!
//!     var limiter = anole.ratelimit.MemoryLimiter.init(gpa, io, .{});
//!     app.use(anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 100, .window_ms = 60_000 }));
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

pub const Policy = struct {
    /// Requests allowed per window.
    limit: u32 = 100,
    window_ms: i64 = 60_000,
    /// Bucket size: how many may come at once. 0 means `limit`.
    burst: u32 = 0,

    fn capacity(p: Policy) f64 {
        return @floatFromInt(if (p.burst > 0) p.burst else p.limit);
    }

    fn ratePerMs(p: Policy) f64 {
        return @as(f64, @floatFromInt(p.limit)) / @as(f64, @floatFromInt(@max(1, p.window_ms)));
    }
};

pub const Result = struct {
    allowed: bool,
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
    const wait_ms = if (rate > 0) (cost_f - tokens.*) / rate else @as(f64, @floatFromInt(policy.window_ms));
    const retry: u32 = @max(1, @as(u32, @intFromFloat(@ceil(wait_ms / 1000.0))));
    return .{
        .allowed = false,
        .limit = policy.limit,
        .remaining = 0,
        .reset_seconds = if (rate > 0) @intFromFloat(@ceil((capacity - tokens.*) / (rate * 1000.0))) else retry,
        .retry_after_seconds = retry,
    };
}

/// Buckets in this process: bounded, least recently used out first, and
/// idle ones dropped after `idle_ms`.
pub const MemoryLimiter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    buckets: std.StringHashMapUnmanaged(*Bucket) = .empty,
    /// Most recently used first.
    lru: std.DoublyLinkedList = .{},
    max_entries: usize,
    idle_ms: i64,

    const Bucket = struct {
        key: []u8,
        tokens: f64,
        last_ms: i64,
        node: std.DoublyLinkedList.Node = .{},
    };

    pub const Options = struct {
        max_entries: usize = 10_000,
        /// A key unseen this long is forgotten (its bucket would be full).
        idle_ms: i64 = 300_000,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) MemoryLimiter {
        return .{ .gpa = gpa, .io = io, .max_entries = @max(1, options.max_entries), .idle_ms = options.idle_ms };
    }

    pub fn deinit(self: *MemoryLimiter) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| self.freeBucket(b.*);
        self.buckets.deinit(self.gpa);
    }

    pub fn limiter(self: *MemoryLimiter) Limiter {
        return .{ .ptr = self, .vtable = &.{ .take = takeFn } };
    }

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
        // The least recently used end is where idle buckets collect.
        while (self.lru.last) |n| {
            const b: *Bucket = @fieldParentPtr("node", n);
            if (now_ms - b.last_ms <= self.idle_ms) break;
            self.removeLocked(b);
        }
        const bucket = self.buckets.get(key) orelse blk: {
            if (self.buckets.count() >= self.max_entries) {
                const oldest: *Bucket = @fieldParentPtr("node", self.lru.last.?);
                self.removeLocked(oldest);
            }
            const b = try self.gpa.create(Bucket);
            errdefer self.gpa.destroy(b);
            b.* = .{ .key = try self.gpa.dupe(u8, key), .tokens = policy.capacity(), .last_ms = now_ms };
            errdefer self.gpa.free(b.key);
            try self.buckets.put(self.gpa, b.key, b);
            self.lru.prepend(&b.node);
            break :blk b;
        };
        self.lru.remove(&bucket.node);
        self.lru.prepend(&bucket.node);
        return step(&bucket.tokens, &bucket.last_ms, now_ms, cost, policy);
    }
};

/// Buckets in Redis/Valkey (-Dredis), shared by every node: one script
/// refills and takes atomically, on the server's clock. On the client's
/// pools (`app.redis`).
pub const RedisLimiter = if (features.redis) struct {
    client: *redis.Client,
    gpa: std.mem.Allocator,
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
        const items = try self.client.all(i64, &c, .{ "EVAL", script, 1, k, policy.capacity(), policy.ratePerMs(), cost, policy.window_ms });
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

/// The key a request is limited by.
pub const KeyFn = *const fn (req: *dusty.Request, buf: []u8) []const u8;

/// The client's address (as trusted proxies report it), without the port.
pub fn clientAddress(req: *dusty.Request, buf: []u8) []const u8 {
    var addr = req.remote_address;
    addr.setPort(0);
    var w: std.Io.Writer = .fixed(buf);
    w.print("{f}", .{addr}) catch return "?";
    const text = w.buffered();
    // "1.2.3.4:0" / "[::1]:0"
    return text[0 .. std.mem.lastIndexOfScalar(u8, text, ':') orelse text.len];
}

/// Limits every request through it: `RateLimit-*` headers on each
/// response, and 429 with Retry-After once a key's bucket is empty. A
/// limiter that fails lets the request through.
pub const Middleware = struct {
    limiter: Limiter,
    policy: Policy,
    key: KeyFn = clientAddress,

    pub fn init(limiter: Limiter, policy: Policy) Middleware {
        return .{ .limiter = limiter, .policy = policy };
    }

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        var key_buf: [128]u8 = undefined;
        const key = self.key(req, &key_buf);
        const r = self.limiter.take(key, 1, self.policy) catch |err| {
            std.log.scoped(.anole_ratelimit).warn("limiter failed, request let through: {t}", .{err});
            return executor.next();
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
        return executor.next();
    }
};

test "token bucket: burst, refill over time, retry-after" {
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{});
    defer l.deinit();
    const policy: Policy = .{ .limit = 10, .window_ms = 1000 };
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
    var l = MemoryLimiter.init(std.testing.allocator, std.testing.io, .{ .max_entries = 3, .idle_ms = 1000 });
    defer l.deinit();
    const policy: Policy = .{ .limit = 2, .window_ms = 60_000 };
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
    var mw = Middleware.init(limiter.limiter(), .{ .limit = 2, .window_ms = 60_000 });
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
    const policy: Policy = .{ .limit = 3, .window_ms = 60_000 };
    for (0..3) |_| try std.testing.expect((try l.take("t", 1, policy)).allowed);
    const denied = try l.take("t", 1, policy);
    try std.testing.expect(!denied.allowed);
    try std.testing.expect(denied.retry_after_seconds >= 1);
}
