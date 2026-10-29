//! Retries, backoff, retry throttling and circuit breakers: the parts that
//! need nothing but `std` and anole_safety's ranked locks, so the HTTP core
//! (its own module) and the rest of Anole use the same types. `anole.resilience` (root.zig) re-exports
//! them and adds the Prometheus binding.
const std = @import("std");
const safety = @import("anole_safety");

const log = std.log.scoped(.anole);

pub const Duration = std.Io.Duration;

/// Which client or connector a breaker or retry belongs to (the metrics'
/// `client` label).
pub const Kind = enum { http, grpc, h3, postgresql, mongodb, redis, nats, kafka, s3, smtp };

// ---------------------------------------------------------------------------
// Backoff

/// A retry schedule: how long to wait before retry `n` (gRPC A6's formula).
pub const Backoff = struct {
    /// The first retry's ceiling.
    base: Duration = .fromMilliseconds(100),
    /// No wait is longer.
    max: Duration = .fromSeconds(2),
    /// Growth per retry; at least 1.
    multiplier: f32 = 2.0,
    jitter: Jitter = .full,

    pub const Jitter = enum {
        /// random(0, ceiling): AWS's "full jitter", gRPC A6.
        full,
        /// ceiling/2 + random(0, ceiling/2).
        equal,
        /// exactly the ceiling; for tests and for schedules stored elsewhere.
        none,
    };

    /// The wait before retry `retry` (1 = the first retry, the second
    /// attempt). `random` is any random number. Saturates, never overflows.
    /// Pure: the job queue and webhooks (pass 3) use it to schedule stored
    /// retries.
    pub fn delay(self: Backoff, retry: u32, random: u64) Duration {
        const base: f64 = @floatFromInt(@max(self.base.nanoseconds, 0));
        const cap: f64 = @floatFromInt(@max(self.max.nanoseconds, 0));
        const mult: f64 = @max(self.multiplier, 1.0);
        var ceiling_f: f64 = base;
        var i: u32 = 1;
        // Stop as soon as the cap is reached: no overflow for retry 10_000.
        while (i < retry and ceiling_f < cap) : (i += 1) ceiling_f *= mult;
        if (ceiling_f > cap) ceiling_f = cap;
        const ceiling: u64 = @intFromFloat(@min(ceiling_f, @as(f64, @floatFromInt(std.math.maxInt(u63)))));
        const ns: u64 = switch (self.jitter) {
            .none => ceiling,
            .full => scale(ceiling, random),
            .equal => ceiling / 2 + scale(ceiling - ceiling / 2, random),
        };
        return .{ .nanoseconds = ns };
    }

    /// `random` mapped onto 0 .. limit (inclusive of 0, below limit + 1 for
    /// the maximum input only when limit is 0).
    fn scale(limit: u64, random: u64) u64 {
        return @intCast((@as(u128, limit) * random) >> 64);
    }
};

/// A retry policy. `attempts` counts every attempt, the first included.
pub const Retry = struct {
    /// 1 = no retry. 2..10; more is refused at init (error.InvalidOptions).
    attempts: u8 = 3,
    backoff: Backoff = .{},
    /// A bound on each attempt, inside the call's own timeout; null: none
    /// of its own. The attempt function applies it (`run` cannot cancel
    /// the code it calls on its own).
    attempt_timeout: ?Duration = null,
    /// Retry-After / grpc-retry-pushback-ms are obeyed up to this; a longer
    /// one ends the retries and returns that answer.
    max_retry_after: Duration = .fromSeconds(10),
    /// gRPC A6 retry throttling per target; null: none.
    throttle: ?Throttle.Options = .{},

    /// Checks the ranges; called by every `init` that takes a Retry.
    pub fn validate(self: Retry) error{InvalidOptions}!void {
        if (self.attempts < 1 or self.attempts > 10) return invalid("retry.attempts", "must be 1 .. 10");
        if (self.backoff.multiplier < 1.0) return invalid("retry.backoff.multiplier", "must be at least 1");
        if (self.backoff.base.nanoseconds < 0 or self.backoff.max.nanoseconds < self.backoff.base.nanoseconds)
            return invalid("retry.backoff", "base must not be negative or above max");
        if (self.throttle) |t| {
            if (t.token_ratio < 0.001 or t.token_ratio > 1.0) return invalid("retry.throttle.token_ratio", "must be 0.001 .. 1");
            if (t.max_tokens == 0) return invalid("retry.throttle.max_tokens", "must be at least 1");
        }
    }
};

fn invalid(field: []const u8, why: []const u8) error{InvalidOptions} {
    log.err("invalid option {s}: {s}", .{ field, why });
    return error.InvalidOptions;
}

/// A per-call choice between the client's policy, none, or another.
pub const Choice = union(enum) {
    inherit,
    off,
    on: Retry,

    /// The policy that applies: `client`'s unless this says otherwise.
    pub fn resolve(self: Choice, client: ?Retry) ?Retry {
        return switch (self) {
            .inherit => client,
            .off => null,
            .on => |r| r,
        };
    }
};

/// gRPC A6 retry throttling: a token bucket per target, lock-free.
pub const Throttle = struct {
    pub const Options = struct {
        max_tokens: u16 = 10,
        /// Tokens a success gives back (0.001 .. 1).
        token_ratio: f32 = 0.1,
    };
    /// Thousandths of a token.
    _tokens: std.atomic.Value(u32),
    _max: u32,
    _ratio: u32,

    pub fn init(o: Options) Throttle {
        const max: u32 = @as(u32, o.max_tokens) * 1000;
        const ratio: u32 = @max(1, @as(u32, @intFromFloat(@round(o.token_ratio * 1000.0))));
        return .{ ._tokens = .init(max), ._max = max, ._ratio = ratio };
    }

    pub fn onSuccess(t: *Throttle) void {
        var cur = t._tokens.load(.monotonic);
        while (true) {
            const next = @min(t._max, cur + t._ratio);
            if (next == cur) return;
            cur = t._tokens.cmpxchgWeak(cur, next, .monotonic, .monotonic) orelse return;
        }
    }

    pub fn onFailure(t: *Throttle) void {
        var cur = t._tokens.load(.monotonic);
        while (true) {
            const next = cur -| 1000;
            if (next == cur) return;
            cur = t._tokens.cmpxchgWeak(cur, next, .monotonic, .monotonic) orelse return;
        }
    }

    /// True while tokens > max_tokens / 2.
    pub fn allowRetry(t: *const Throttle) bool {
        return t._tokens.load(.monotonic) > t._max / 2;
    }
};

// ---------------------------------------------------------------------------
// Metrics hooks

/// Where breakers and retries report. `anole.resilience.Binding` makes one
/// for a Prometheus registry; tests make their own. Hooks run with no lock
/// of the breakers held, on any executor.
pub const Metrics = struct {
    context: ?*anyopaque = null,
    on_state: *const fn (ctx: ?*anyopaque, kind: Kind, target: []const u8, state: Breaker.State) void = noState,
    on_rejected: *const fn (ctx: ?*anyopaque, kind: Kind, target: []const u8) void = noTarget,
    on_retry: *const fn (ctx: ?*anyopaque, kind: Kind, target: []const u8, reason: []const u8) void = noRetry,
    on_throttled: *const fn (ctx: ?*anyopaque, kind: Kind, target: []const u8) void = noTarget,

    fn noState(_: ?*anyopaque, _: Kind, _: []const u8, _: Breaker.State) void {}
    fn noTarget(_: ?*anyopaque, _: Kind, _: []const u8) void {}
    fn noRetry(_: ?*anyopaque, _: Kind, _: []const u8, _: []const u8) void {}
};

// ---------------------------------------------------------------------------
// Breaker

pub const Breaker = struct {
    pub const Options = struct {
        /// Open after this many failures in a row; 0: not this rule.
        consecutive_failures: u32 = 5,
        /// Open when failures / calls >= this over `window`, once `min_calls`
        /// calls are in it; 0: not this rule. 0 .. 1.
        failure_ratio: f32 = 0.5,
        min_calls: u32 = 20,
        /// The ratio's sliding window, kept as 10 buckets.
        window: Duration = .fromSeconds(10),
        /// The first open period; doubles after each failed probe.
        open_for: Duration = .fromSeconds(5),
        max_open_for: Duration = .fromSeconds(60),
        /// Calls let through at once while half-open; each must succeed.
        half_open_calls: u8 = 1,

        pub fn validate(self: Options) error{InvalidOptions}!void {
            if (self.failure_ratio < 0 or self.failure_ratio > 1) return invalid("breaker.failure_ratio", "must be 0 .. 1");
            if (self.consecutive_failures == 0 and self.failure_ratio == 0) return invalid("breaker", "needs consecutive_failures or failure_ratio");
            if (self.window.nanoseconds < 10) return invalid("breaker.window", "too short");
            if (self.open_for.nanoseconds <= 0 or self.max_open_for.nanoseconds < self.open_for.nanoseconds)
                return invalid("breaker.open_for", "must be positive and at most max_open_for");
            if (self.half_open_calls == 0) return invalid("breaker.half_open_calls", "must be at least 1");
        }
    };
    pub const State = enum(u8) { closed = 0, half_open = 1, open = 2 };
    /// What `allow` hands out; give it back to `record`.
    pub const Permit = struct { probe: bool };
    pub const Outcome = enum { success, failure, neutral };

    const Bucket = struct {
        epoch: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
        calls: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),
    };

    options: Options,
    kind: Kind,
    name_buf: [255]u8 = undefined,
    name_len: u8 = 0,
    metrics: ?*const Metrics = null,
    _bucket_ns: i64,
    _state: std.atomic.Value(u8) = .init(0),
    _consecutive: std.atomic.Value(u32) = .init(0),
    _buckets: [10]Bucket = @splat(.{}),
    _open_until: std.atomic.Value(i64) = .init(0),
    _open_for: std.atomic.Value(i64),
    _probes: std.atomic.Value(u32) = .init(0),
    _probe_ok: std.atomic.Value(u32) = .init(0),
    _inflight: std.atomic.Value(u32) = .init(0),
    _rng: std.atomic.Value(u64),

    /// `name` labels logs and metrics ("api.example.com:443", "orders-db");
    /// copied (max 255 bytes). The breaker must not move once used.
    pub fn init(options: Options, kind: Kind, label: []const u8) Breaker {
        var b: Breaker = .{
            .options = options,
            .kind = kind,
            ._bucket_ns = @intCast(@max(1, @divTrunc(options.window.nanoseconds, 10))),
            ._open_for = .init(@intCast(@min(options.open_for.nanoseconds, std.math.maxInt(i64)))),
            ._rng = .init(std.hash.Wyhash.hash(0x9e3779b97f4a7c15, label) | 1),
        };
        const n = @min(label.len, b.name_buf.len);
        @memcpy(b.name_buf[0..n], label[0..n]);
        b.name_len = @intCast(n);
        return b;
    }

    pub fn name(b: *const Breaker) []const u8 {
        return b.name_buf[0..b.name_len];
    }

    /// Reports to `m` from now on. `m` must outlive the breaker.
    pub fn observe(b: *Breaker, m: ?*const Metrics) void {
        b.metrics = m;
        if (m) |h| h.on_state(h.context, b.kind, b.name(), b.state());
    }

    pub fn state(b: *const Breaker) State {
        return @fromBackingInt(@intCast(b._state.load(.acquire)));
    }

    /// When an open breaker lets the next probe through (awake ns).
    pub fn openUntil(b: *const Breaker) ?i96 {
        if (b.state() != .open) return null;
        return b._open_until.load(.monotonic);
    }

    /// True when `allow(now)` would refuse (open and not yet due); takes
    /// no permit.
    pub fn wouldReject(b: *const Breaker, now: i96) bool {
        return b.state() == .open and now < b._open_until.load(.monotonic);
    }

    /// Back to closed, counts cleared (tests, admin).
    pub fn reset(b: *Breaker) void {
        const prev = b._state.swap(0, .acq_rel);
        b.clear();
        b._open_for.store(@intCast(@min(b.options.open_for.nanoseconds, std.math.maxInt(i64))), .monotonic);
        if (prev != 0) b.announce(.closed);
    }

    fn clear(b: *Breaker) void {
        b._consecutive.store(0, .monotonic);
        b._probes.store(0, .monotonic);
        b._probe_ok.store(0, .monotonic);
        for (&b._buckets) |*k| {
            k.calls.store(0, .monotonic);
            k.failures.store(0, .monotonic);
        }
    }

    /// Null: open, reject the call. `now` is the awake clock in ns, passed
    /// in so tests are deterministic.
    pub fn allow(b: *Breaker, now: i96) ?Permit {
        var st = b.state();
        if (st == .open) {
            if (now < b._open_until.load(.monotonic)) {
                if (b.metrics) |m| m.on_rejected(m.context, b.kind, b.name());
                return null;
            }
            b._probes.store(0, .monotonic);
            b._probe_ok.store(0, .monotonic);
            if (b._state.cmpxchgStrong(@backingInt(State.open), @backingInt(State.half_open), .acq_rel, .acquire) == null) {
                b.announce(.half_open);
            }
            st = b.state();
        }
        switch (st) {
            .closed => {
                _ = b._inflight.fetchAdd(1, .monotonic);
                return .{ .probe = false };
            },
            .half_open => {
                const before = b._probes.fetchAdd(1, .acq_rel);
                if (before < b.options.half_open_calls) {
                    _ = b._inflight.fetchAdd(1, .monotonic);
                    return .{ .probe = true };
                }
                _ = b._probes.fetchSub(1, .acq_rel);
                if (b.metrics) |m| m.on_rejected(m.context, b.kind, b.name());
                return null;
            },
            .open => {
                if (b.metrics) |m| m.on_rejected(m.context, b.kind, b.name());
                return null;
            },
        }
    }

    pub fn record(b: *Breaker, permit: Permit, outcome: Outcome, now: i96) void {
        defer _ = b._inflight.fetchSub(1, .monotonic);
        const now_ns: i64 = @intCast(@min(@max(now, 0), std.math.maxInt(i64)));
        if (permit.probe) {
            switch (outcome) {
                .success => {
                    const ok = b._probe_ok.fetchAdd(1, .acq_rel) + 1;
                    if (ok >= b.options.half_open_calls) b.close();
                },
                .failure => b.trip(.half_open, now_ns, true),
                .neutral => {
                    _ = b._probes.fetchSub(1, .acq_rel);
                },
            }
            return;
        }
        if (outcome == .neutral) return;
        const failed = outcome == .failure;
        b.count(now_ns, failed);
        if (b.state() != .closed) return;
        if (!failed) {
            b._consecutive.store(0, .monotonic);
            return;
        }
        const streak = b._consecutive.fetchAdd(1, .monotonic) + 1;
        var open = b.options.consecutive_failures != 0 and streak >= b.options.consecutive_failures;
        if (!open and b.options.failure_ratio > 0) {
            var calls: u64 = 0;
            var fails: u64 = 0;
            const epoch: u64 = @intCast(@divTrunc(now_ns, b._bucket_ns));
            for (&b._buckets) |*k| {
                const e = k.epoch.load(.monotonic);
                if (e <= epoch and epoch - e < 10) {
                    calls += k.calls.load(.monotonic);
                    fails += k.failures.load(.monotonic);
                }
            }
            if (calls >= b.options.min_calls and calls > 0) {
                const ratio: f64 = @as(f64, @floatFromInt(fails)) / @as(f64, @floatFromInt(calls));
                open = ratio >= b.options.failure_ratio;
            }
        }
        if (open) b.trip(.closed, now_ns, false);
    }

    fn count(b: *Breaker, now_ns: i64, failed: bool) void {
        const epoch: u64 = @intCast(@divTrunc(now_ns, b._bucket_ns));
        const k = &b._buckets[@intCast(epoch % 10)];
        const cur = k.epoch.load(.acquire);
        if (cur != epoch) {
            // A lost race just undercounts one call.
            if (k.epoch.cmpxchgStrong(cur, epoch, .acq_rel, .acquire) == null) {
                k.calls.store(0, .monotonic);
                k.failures.store(0, .monotonic);
            }
        }
        _ = k.calls.fetchAdd(1, .monotonic);
        if (failed) _ = k.failures.fetchAdd(1, .monotonic);
    }

    fn close(b: *Breaker) void {
        if (b._state.cmpxchgStrong(@backingInt(State.half_open), @backingInt(State.closed), .acq_rel, .acquire) != null) return;
        b.clear();
        b._open_for.store(@intCast(@min(b.options.open_for.nanoseconds, std.math.maxInt(i64))), .monotonic);
        b.announce(.closed);
    }

    fn trip(b: *Breaker, from: State, now_ns: i64, double: bool) void {
        var period = b._open_for.load(.monotonic);
        if (double) {
            const cap: i64 = @intCast(@min(b.options.max_open_for.nanoseconds, std.math.maxInt(i64)));
            period = @min(cap, period *| 2);
            b._open_for.store(period, .monotonic);
        }
        // Cut by a random part of up to a fifth.
        const cut: i64 = @intCast(b.random() % @as(u64, @intCast(@max(1, @divTrunc(period, 5)))));
        b._open_until.store(now_ns +| (period - cut), .monotonic);
        if (b._state.cmpxchgStrong(@backingInt(from), @backingInt(State.open), .acq_rel, .acquire) != null) return;
        b._consecutive.store(0, .monotonic);
        b.announce(.open);
    }

    fn random(b: *Breaker) u64 {
        // xorshift64 on an atomic: races only scramble the sequence further.
        var x = b._rng.load(.monotonic);
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b._rng.store(x, .monotonic);
        return x;
    }

    fn announce(b: *Breaker, st: State) void {
        switch (st) {
            .open => log.warn("circuit breaker {s} {s}: open", .{ @tagName(b.kind), b.name() }),
            .half_open => log.info("circuit breaker {s} {s}: half-open", .{ @tagName(b.kind), b.name() }),
            .closed => log.info("circuit breaker {s} {s}: closed", .{ @tagName(b.kind), b.name() }),
        }
        if (b.metrics) |m| m.on_state(m.context, b.kind, b.name(), st);
    }
};

/// Breakers by key ("https://api.example.com:443"), made on first use;
/// at most `max_entries`, the least recently used closed one evicted.
pub const Breakers = struct {
    const shards = 16;
    /// How much of a key a breaker keeps as its name.
    const max_name = @sizeOf(@FieldType(Breaker, "name_buf"));

    const Entry = struct {
        breaker: Breaker,
        last_used: u64,
    };
    const Shard = struct {
        mutex: safety.Mutex(.leaf) = .init,
        map: std.StringHashMapUnmanaged(*Entry) = .empty,
    };

    gpa: std.mem.Allocator,
    options: Breaker.Options,
    kind: Kind,
    max_entries: u32,
    metrics: ?*const Metrics = null,
    tick: std.atomic.Value(u64) = .init(0),
    shard: [shards]Shard = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator, options: Breaker.Options, kind: Kind, max_entries: u32) Breakers {
        return .{ .gpa = gpa, .options = options, .kind = kind, .max_entries = max_entries };
    }

    pub fn deinit(self: *Breakers) void {
        for (&self.shard) |*s| {
            var it = s.map.iterator();
            while (it.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                self.gpa.destroy(e.value_ptr.*);
            }
            s.map.deinit(self.gpa);
        }
    }

    /// Reports every breaker (existing and future) to `m`: each shard's
    /// breakers are noted under its lock, and reported after it (the hooks
    /// take locks of their own).
    pub fn observe(self: *Breakers, io: std.Io, m: ?*const Metrics) void {
        self.metrics = m;
        const hooks = m orelse {
            for (&self.shard) |*s| {
                s.mutex.lockUncancelable(io);
                defer s.mutex.unlock(io);
                var it = s.map.valueIterator();
                while (it.next()) |e| e.*.breaker.metrics = null;
            }
            return;
        };
        const Seen = struct { name: []const u8, state: Breaker.State };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for (&self.shard) |*s| {
            var seen: std.ArrayList(Seen) = .empty;
            {
                s.mutex.lockUncancelable(io);
                defer s.mutex.unlock(io);
                var it = s.map.valueIterator();
                while (it.next()) |e| {
                    const b = &e.*.breaker;
                    b.metrics = hooks;
                    // A breaker that cannot be noted is still reported from
                    // its next transition on.
                    const name = arena.dupe(u8, b.name()) catch continue;
                    seen.append(arena, .{ .name = name, .state = b.state() }) catch continue;
                }
            }
            for (seen.items) |x| hooks.on_state(hooks.context, self.kind, x.name, x.state);
        }
    }

    /// Sharded (16 shards, a `safety.Mutex` each, held only for the map
    /// lookup). The pointer lives until `deinit` or the entry's eviction,
    /// which never happens while a permit of it is outstanding. A breaker
    /// made here is reported to the metrics after the shard's lock is let
    /// go.
    pub fn get(self: *Breakers, io: std.Io, key: []const u8) error{OutOfMemory}!*Breaker {
        const s = &self.shard[std.hash.Wyhash.hash(0, key) % shards];
        const made = made: {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            const stamp = self.tick.fetchAdd(1, .monotonic);
            if (s.map.get(key)) |e| {
                e.last_used = stamp;
                return &e.breaker;
            }
            if (s.map.count() >= @max(1, self.max_entries / shards)) self.evict(s);
            const entry = try self.gpa.create(Entry);
            errdefer self.gpa.destroy(entry);
            const owned = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned);
            entry.* = .{ .breaker = .init(self.options, self.kind, key), .last_used = stamp };
            try s.map.put(self.gpa, owned, entry);
            entry.breaker.metrics = self.metrics;
            break :made &entry.breaker;
        };
        // A new breaker starts closed; its label is the caller's key, cut
        // as the breaker cuts its name, so nothing of the entry is read
        // here.
        if (self.metrics) |m| m.on_state(m.context, self.kind, key[0..@min(key.len, max_name)], .closed);
        return made;
    }

    fn evict(self: *Breakers, s: *Shard) void {
        var oldest: ?*Entry = null;
        var oldest_key: []const u8 = "";
        var it = s.map.iterator();
        while (it.next()) |e| {
            const b = &e.value_ptr.*.breaker;
            if (b.state() != .closed or b._inflight.load(.monotonic) != 0) continue;
            if (oldest == null or e.value_ptr.*.last_used < oldest.?.last_used) {
                oldest = e.value_ptr.*;
                oldest_key = e.key_ptr.*;
            }
        }
        const victim = oldest orelse return;
        const owned = s.map.getKey(oldest_key).?;
        _ = s.map.remove(oldest_key);
        self.gpa.free(owned);
        self.gpa.destroy(victim);
    }

    /// How many breakers exist.
    pub fn count(self: *Breakers, io: std.Io) usize {
        var n: usize = 0;
        for (&self.shard) |*s| {
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            n += s.map.count();
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// run

/// How `run` judges one attempt's result.
pub const Verdict = enum {
    /// Done; the breaker counts a success.
    success,
    /// Failed for a reason that may pass: retried when the policy, the
    /// throttle and the budget allow; the breaker counts a failure.
    transient,
    /// Retried like `transient`, but the target is not failing, so the
    /// breaker counts nothing (an HTTP 429).
    retryable,
    /// Failed for good; returned; the breaker counts a failure.
    failure,
    /// Returned as it is; the breaker counts nothing (a 404, a unique violation).
    neutral,
};

pub const Policy = struct {
    retry: ?Retry = null,
    breaker: ?*Breaker = null,
    throttle: ?*Throttle = null,
    /// The whole call's end (awake clock); null: none.
    deadline: ?std.Io.Clock.Timestamp = null,
    /// Counts retries; null: no metrics.
    metrics: ?*const Metrics = null,
    /// The metrics' labels when there is no breaker to name them.
    kind: Kind = .http,
    target: []const u8 = "",
};

/// `run` adds these to the attempt's own error set.
pub const Error = error{CircuitOpen} || std.Io.Cancelable;

/// The type `run` returns for an attempt returning `R`.
pub fn Run(comptime R: type) type {
    return switch (@typeInfo(R)) {
        .error_union => |eu| (eu.error_set || Error)!eu.payload,
        else => Error!R,
    };
}

fn AttemptResult(comptime attempt: anytype) type {
    return @typeInfo(@TypeOf(attempt)).@"fn".return_type.?;
}

/// Runs `attempt(context, n)` (n = 1, 2, ...) under `policy`. `Judge` has:
///     fn verdict(result: *const R) Verdict
///     fn retryAfter(result: *const R) ?Duration   // optional: Retry-After, pushback
///     fn discard(result: *R) void                 // optional: a result not returned
///     fn reason(result: *const R) []const u8      // optional: the retries metric's `reason`
/// Returns the last attempt's result, or error.CircuitOpen before the first
/// attempt when the breaker is open (a half-open breaker that has no probe
/// slot left also rejects).
pub fn run(
    io: std.Io,
    policy: Policy,
    context: anytype,
    comptime attempt: anytype,
    comptime Judge: type,
) Run(AttemptResult(attempt)) {
    const R = AttemptResult(attempt);
    var n: u32 = 1;
    while (true) : (n += 1) {
        var permit: ?Breaker.Permit = null;
        if (policy.breaker) |b| {
            permit = b.allow(nowNs(io)) orelse return error.CircuitOpen;
        }
        var r: R = attempt(context, n);
        const v = Judge.verdict(&r);
        if (policy.breaker) |b| b.record(permit.?, switch (v) {
            .success => .success,
            .transient, .failure => .failure,
            .neutral, .retryable => .neutral,
        }, nowNs(io));
        if (policy.throttle) |t| switch (v) {
            .success => t.onSuccess(),
            .transient, .failure, .retryable => t.onFailure(),
            .neutral => {},
        };
        const retry = policy.retry orelse return r;
        if ((v != .transient and v != .retryable) or n >= retry.attempts) return r;
        if (policy.throttle) |t| if (!t.allowRetry()) {
            if (policy.metrics) |m| m.on_throttled(m.context, kindOf(policy), targetOf(policy));
            return r;
        };
        const hinted: ?Duration = if (comptime @hasDecl(Judge, "retryAfter")) Judge.retryAfter(&r) else null;
        var wait: Duration = undefined;
        if (hinted) |h| {
            if (h.nanoseconds > retry.max_retry_after.nanoseconds) return r;
            wait = h;
        } else {
            var rb: [8]u8 = undefined;
            io.random(&rb);
            wait = retry.backoff.delay(n, std.mem.readInt(u64, &rb, .little));
        }
        const now = nowNs(io);
        if (policy.deadline) |d| if (now + wait.nanoseconds >= d.raw.nanoseconds) return r;
        if (policy.breaker) |b| if (b.wouldReject(now + wait.nanoseconds)) return r;
        if (policy.metrics) |m| {
            const why: []const u8 = if (comptime @hasDecl(Judge, "reason")) Judge.reason(&r) else "status";
            m.on_retry(m.context, kindOf(policy), targetOf(policy), why);
        }
        if (comptime @hasDecl(Judge, "discard")) Judge.discard(&r);
        try io.sleep(wait, .awake);
    }
}

fn kindOf(p: Policy) Kind {
    return if (p.breaker) |b| b.kind else p.kind;
}
fn targetOf(p: Policy) []const u8 {
    return if (p.breaker) |b| b.name() else p.target;
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn ms(n: i64) Duration {
    return .fromMilliseconds(n);
}
const sec: i96 = std.time.ns_per_s;

test "backoff: delays grow by multiplier up to max, none jitter" {
    const b: Backoff = .{ .jitter = .none };
    const expect = [_]i64{ 100, 200, 400, 800, 1600, 2000, 2000, 2000 };
    for (expect, 1..) |e, i| try testing.expectEqual(@as(i96, e) * std.time.ns_per_ms, b.delay(@intCast(i), 0).nanoseconds);
}

test "backoff: full jitter stays in [0, ceiling]; equal jitter in [ceiling/2, ceiling]" {
    const full: Backoff = .{};
    const equal: Backoff = .{ .jitter = .equal };
    for ([_]u64{ 0, 1, std.math.maxInt(u64) / 2, std.math.maxInt(u64) }) |r| {
        const f = full.delay(3, r).nanoseconds;
        try testing.expect(f >= 0 and f <= 400 * std.time.ns_per_ms);
        const e = equal.delay(3, r).nanoseconds;
        try testing.expect(e >= 200 * std.time.ns_per_ms and e <= 400 * std.time.ns_per_ms);
    }
}

test "backoff: retry 10_000 and huge durations saturate at max" {
    const b: Backoff = .{ .jitter = .none };
    try testing.expectEqual(@as(i96, 2 * sec), b.delay(10_000, 0).nanoseconds);
    try testing.expectEqual(@as(i96, 2 * sec), b.delay(std.math.maxInt(u32), 0).nanoseconds);
    const huge: Backoff = .{ .base = .max, .max = .max, .multiplier = 1000, .jitter = .none };
    _ = huge.delay(50, 0);
}

test "retry: validate refuses attempts 0 and 11, multiplier < 1" {
    try testing.expectError(error.InvalidOptions, (Retry{ .attempts = 0 }).validate());
    try testing.expectError(error.InvalidOptions, (Retry{ .attempts = 11 }).validate());
    try testing.expectError(error.InvalidOptions, (Retry{ .backoff = .{ .multiplier = 0.5 } }).validate());
    try (Retry{}).validate();
}

test "throttle: five failures stop retries; successes earn them back at 0.1 each" {
    var t: Throttle = .init(.{});
    try testing.expect(t.allowRetry());
    var failures: u32 = 0;
    while (t.allowRetry()) : (failures += 1) t.onFailure();
    try testing.expectEqual(@as(u32, 5), failures);
    t.onSuccess();
    try testing.expect(t.allowRetry());
    for (0..20) |_| t.onSuccess();
    // 21 successes at 0.1 earn 2.1 tokens over the 5 left: 7.1. Retries
    // need more than 5, so three failures stop them again (a whole token
    // per success would have refilled to 10 and needed five).
    failures = 0;
    while (t.allowRetry()) : (failures += 1) t.onFailure();
    try testing.expectEqual(@as(u32, 3), failures);
}

test "breaker: five consecutive failures open it; allow is null until open_until" {
    var b: Breaker = .init(.{}, .redis, "t");
    var now: i96 = 1000 * sec;
    for (0..5) |_| {
        const p = b.allow(now).?;
        b.record(p, .failure, now);
    }
    try testing.expectEqual(Breaker.State.open, b.state());
    try testing.expect(b.allow(now) == null);
    try testing.expect(b.allow(now + 3 * sec) == null);
    now += 6 * sec;
    try testing.expect(b.allow(now) != null);
    try testing.expectEqual(Breaker.State.half_open, b.state());
}

test "breaker: ratio rule needs min_calls; 10 of 20 failures in the window open it; old buckets age out" {
    var b: Breaker = .init(.{ .consecutive_failures = 0 }, .redis, "t");
    var now: i96 = 100 * sec;
    // 9 failures alternate with successes: under min_calls, still closed.
    for (0..19) |i| {
        const p = b.allow(now).?;
        b.record(p, if (i % 2 == 0) .failure else .success, now);
    }
    try testing.expectEqual(Breaker.State.closed, b.state());
    const p = b.allow(now).?;
    b.record(p, .failure, now);
    try testing.expectEqual(Breaker.State.open, b.state());

    var c: Breaker = .init(.{ .consecutive_failures = 0 }, .redis, "t");
    now = 100 * sec;
    for (0..19) |_| c.record(c.allow(now).?, .failure, now);
    // The 19 failures are 11 s old: out of the window, and a failure alone
    // is below min_calls.
    now += 11 * sec;
    c.record(c.allow(now).?, .failure, now);
    try testing.expectEqual(Breaker.State.closed, c.state());
}

test "breaker: half-open lets one probe; success closes and resets open_for; failure reopens with double, capped at max" {
    var b: Breaker = .init(.{ .open_for = ms(1000), .max_open_for = ms(3000) }, .redis, "t");
    var now: i96 = 0;
    const trip = struct {
        fn go(br: *Breaker, at: i96) void {
            for (0..5) |_| br.record(br.allow(at).?, .failure, at);
        }
    }.go;
    trip(&b, now);
    try testing.expectEqual(Breaker.State.open, b.state());
    now += 2 * sec;
    const probe = b.allow(now).?;
    try testing.expect(probe.probe);
    try testing.expect(b.allow(now) == null);
    b.record(probe, .failure, now);
    try testing.expectEqual(Breaker.State.open, b.state());
    // Doubled to 2 s.
    try testing.expect(b.allow(now + 1900 * std.time.ns_per_ms) == null);
    now += 2100 * std.time.ns_per_ms;
    const second = b.allow(now).?;
    try testing.expect(second.probe);
    b.record(second, .failure, now);
    // Doubled again, capped at 3 s.
    try testing.expect(b.allow(now + 2900 * std.time.ns_per_ms) == null);
    now += 3100 * std.time.ns_per_ms;
    b.record(b.allow(now).?, .success, now);
    try testing.expectEqual(Breaker.State.closed, b.state());
    // The next trip is open for 1 s again.
    trip(&b, now);
    try testing.expect(b.allow(now + 900 * std.time.ns_per_ms) == null);
    try testing.expect(b.allow(now + 1100 * std.time.ns_per_ms) != null);
}

test "breaker: neutral outcomes change nothing; a non-probe call recorded while open only counts in buckets" {
    var b: Breaker = .init(.{}, .redis, "t");
    const now: i96 = 50 * sec;
    // Neutrals between failures neither count toward the run nor reset it.
    for (0..2) |_| b.record(b.allow(now).?, .failure, now);
    for (0..10) |_| b.record(b.allow(now).?, .neutral, now);
    for (0..2) |_| b.record(b.allow(now).?, .failure, now);
    try testing.expectEqual(Breaker.State.closed, b.state());
    b.record(b.allow(now).?, .failure, now);
    try testing.expectEqual(Breaker.State.open, b.state());
    // A call admitted before the trip finishes after it.
    var c: Breaker = .init(.{}, .redis, "t");
    const late = c.allow(now).?;
    for (0..5) |_| c.record(c.allow(now).?, .failure, now);
    try testing.expectEqual(Breaker.State.open, c.state());
    c.record(late, .success, now);
    try testing.expectEqual(Breaker.State.open, c.state());
}

test "breakers: same key gives the same breaker; past max_entries the least recently used closed one is evicted, an open one never" {
    var bs: Breakers = .init(testing.allocator, .{}, .http, 16);
    defer bs.deinit();
    const io = testing.io;
    const a = try bs.get(io, "https://a:443");
    try testing.expect(a == try bs.get(io, "https://a:443"));
    // a: four failures, one short of opening. b: open.
    for (0..4) |_| a.record(a.allow(0).?, .failure, 0);
    const b = try bs.get(io, "https://b:443");
    for (0..5) |_| b.record(b.allow(0).?, .failure, 0);
    try testing.expectEqual(Breaker.State.open, b.state());
    // Many more keys than max_entries: every shard overflows.
    for (0..200) |i| {
        var buf: [32]u8 = undefined;
        _ = try bs.get(io, std.fmt.bufPrint(&buf, "https://h{d}:443", .{i}) catch unreachable);
    }
    // a was evicted: its breaker is a fresh one, which one failure leaves closed.
    const a2 = try bs.get(io, "https://a:443");
    a2.record(a2.allow(0).?, .failure, 0);
    try testing.expectEqual(Breaker.State.closed, a2.state());
    // b was kept, still open.
    try testing.expect((try bs.get(io, "https://b:443")).allow(0) == null);
}

const CountJudge = struct {
    var discarded: u32 = 0;
    fn verdict(r: *const u32) Verdict {
        return switch (r.*) {
            200 => .success,
            503 => .transient,
            404 => .neutral,
            else => .failure,
        };
    }
    fn discard(_: *u32) void {
        discarded += 1;
    }
};

const Script = struct {
    codes: []const u32,
    calls: u32 = 0,
    fn attempt(self: *Script, n: u32) u32 {
        _ = n;
        defer self.calls += 1;
        return self.codes[@min(self.calls, self.codes.len - 1)];
    }
};

test "run: transient then success = 2 attempts, discard called once" {
    CountJudge.discarded = 0;
    var s: Script = .{ .codes = &.{ 503, 200 } };
    const policy: Policy = .{ .retry = .{ .attempts = 3, .backoff = .{ .base = ms(1), .max = ms(1), .jitter = .none }, .throttle = null } };
    const r = try run(testing.io, policy, &s, Script.attempt, CountJudge);
    try testing.expectEqual(@as(u32, 200), r);
    try testing.expectEqual(@as(u32, 2), s.calls);
    try testing.expectEqual(@as(u32, 1), CountJudge.discarded);
}

test "run: neutral and failure are returned at once" {
    var s: Script = .{ .codes = &.{404} };
    const policy: Policy = .{ .retry = .{ .backoff = .{ .base = ms(1), .max = ms(1) } } };
    try testing.expectEqual(@as(u32, 404), try run(testing.io, policy, &s, Script.attempt, CountJudge));
    try testing.expectEqual(@as(u32, 1), s.calls);
    var f: Script = .{ .codes = &.{500} };
    try testing.expectEqual(@as(u32, 500), try run(testing.io, policy, &f, Script.attempt, CountJudge));
    try testing.expectEqual(@as(u32, 1), f.calls);
}

const HintJudge = struct {
    var hint: ?Duration = null;
    fn verdict(r: *const u32) Verdict {
        return CountJudge.verdict(r);
    }
    fn retryAfter(_: *const u32) ?Duration {
        return hint;
    }
};

test "run: Retry-After above max_retry_after returns the answer at once; a Retry-After of 0 retries" {
    const policy: Policy = .{ .retry = .{ .attempts = 3, .max_retry_after = .fromSeconds(10), .throttle = null } };
    HintJudge.hint = .fromSeconds(60);
    var s: Script = .{ .codes = &.{ 503, 200 } };
    try testing.expectEqual(@as(u32, 503), try run(testing.io, policy, &s, Script.attempt, HintJudge));
    try testing.expectEqual(@as(u32, 1), s.calls);
    HintJudge.hint = .fromSeconds(0);
    var t: Script = .{ .codes = &.{ 503, 503, 200 } };
    try testing.expectEqual(@as(u32, 200), try run(testing.io, policy, &t, Script.attempt, HintJudge));
    try testing.expectEqual(@as(u32, 3), t.calls);
}

test "run: a retry whose wait ends past the deadline is not made" {
    var s: Script = .{ .codes = &.{ 503, 200 } };
    const now = std.Io.Clock.Timestamp.now(testing.io, .awake);
    const policy: Policy = .{
        .retry = .{ .backoff = .{ .base = .fromSeconds(1), .max = .fromSeconds(1), .jitter = .none }, .throttle = null },
        .deadline = .{ .raw = now.raw.addDuration(ms(1)), .clock = .awake },
    };
    try testing.expectEqual(@as(u32, 503), try run(testing.io, policy, &s, Script.attempt, CountJudge));
    try testing.expectEqual(@as(u32, 1), s.calls);
}

test "run: open breaker -> CircuitOpen before the first attempt; after the first, the previous result" {
    var b: Breaker = .init(.{ .consecutive_failures = 2 }, .http, "t");
    var s: Script = .{ .codes = &.{ 503, 503, 503 } };
    const policy: Policy = .{ .retry = .{ .attempts = 5, .backoff = .{ .base = ms(1), .max = ms(1) }, .throttle = null }, .breaker = &b };
    // The second failure opens the breaker; the third attempt is not made.
    try testing.expectEqual(@as(u32, 503), try run(testing.io, policy, &s, Script.attempt, CountJudge));
    try testing.expectEqual(@as(u32, 2), s.calls);
    try testing.expectError(error.CircuitOpen, run(testing.io, policy, &s, Script.attempt, CountJudge));
    try testing.expectEqual(@as(u32, 2), s.calls);
}
