//! Server-sent events with topics: publish once, every subscriber gets it,
//! with heartbeats and `Last-Event-ID` replay (p3/realtime, design-
//! realtime.md).
//!
//!     const live = try app.sseTopics(.{});
//!     app.sse("/orders/live", live, .{ .topics = &.{"orders"} });
//!     _ = try live.publish("orders", .{ .data = "{\"id\":7}" });
//!
//! A subscriber is a response nothing waits for: over HTTP/1.1 and
//! HTTP/2 its stream is parked (`dusty.Parked`), so an idle subscriber holds
//! no task, only a heap object, and a task exists only while it has events
//! to write. A publish queues the event for every subscriber of the topic
//! and returns; a sender task per subscriber with something queued then
//! writes up to 64 events in one write and one flush.
//!
//! Every event of a `Topics` has a number in one sequence, and its ID is
//! `<epoch>-<seq>` (the epoch is chosen at random for each `Topics`). A
//! browser that reconnects sends the last ID it saw as `Last-Event-ID`, and
//! gets what it missed from the topics' replay rings, or one `gap` event
//! when the rings no longer cover it.

const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
const observe_metrics = @import("../observe/metrics.zig");
pub const replay = @import("replay.zig");
pub const out_mod = @import("out.zig");

pub const Out = out_mod.Out;
pub const Payload = replay.Payload;

pub const Duration = std.Io.Duration;

/// One event as a publisher gives it.
pub const Event = struct {
    /// UTF-8; CR, LF and CRLF split it into `data:` lines (as `EventStream`).
    data: []const u8,
    /// `event:`; null sends none (the browser's `onmessage`). No CR or LF.
    event: ?[]const u8 = null,
    /// Kept for `Last-Event-ID` resume (topic publishes only).
    replay: bool = true,
};

pub const PublishError = error{ OutOfMemory, InvalidEventField, InvalidTopic };
pub const ServeError = anyerror;
pub const JoinError = error{ OutOfMemory, InvalidTopic, TooManyTopics, Closed };
pub const SendError = error{ OutOfMemory, InvalidEventField, Full, Closed };

/// Why a subscriber ended (`ServeOptions.on_close`, ABI `ANOLE_SSE_CLOSED_*`).
pub const CloseReason = enum { client_gone, slow, drain, closed, server };

pub const HttpVersion = enum { http1, http2, http3 };

/// The longest topic name.
pub const max_topic_len = 255;

fn validTopic(topic: []const u8) bool {
    return topic.len >= 1 and topic.len <= max_topic_len;
}

fn validField(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\r\n") == null;
}

/// The most queued events a sender writes in one go.
const send_round = 64;
/// Subscribers a publish notes on the stack for starting their senders.
const stack_snapshot = 64;
/// Precomputed retry values for the drain (S12).
const drain_spread = 16;

pub const Topics = struct {
    gpa: std.mem.Allocator,
    options: Options,
    epoch: u32,
    /// The last sequence number handed out.
    seq: u64 = 0,
    /// Over every field below and every subscriber's queue and flags;
    /// never held across I/O.
    mutex: std.Io.Mutex = .init,
    /// Signalled when a subscriber that left has no sender running.
    idle: std.Io.Condition = .init,
    topics: std.StringHashMapUnmanaged(*Topic) = .empty,
    store: replay.Store = .{},
    execs: []ExecList = &.{},
    io: std.Io = undefined,
    io_set: std.atomic.Value(bool) = .init(false),
    io_lock: std.atomic.Mutex = .unlocked,
    ends: std.Io.Group = .init,
    tickers: std.Io.Group = .init,
    draining: std.atomic.Value(bool) = .init(false),
    drain_hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
    drain_hooks: ?*dusty.DrainHooks = null,
    next_index: std.atomic.Value(u32) = .init(0),
    heartbeat_payload: *Payload,
    end_payload: *Payload,
    last_sweep_ms: i64 = 0,
    /// Tests: a made-up clock (milliseconds); `minInt` for the real one.
    fake_now_ms: std.atomic.Value(i64) = .init(std.math.minInt(i64)),
    subscribers: std.atomic.Value(usize) = .init(0),
    n_published: std.atomic.Value(u64) = .init(0),
    n_delivered: std.atomic.Value(u64) = .init(0),
    n_dropped: std.atomic.Value(u64) = .init(0),
    n_closed_slow: std.atomic.Value(u64) = .init(0),
    n_resumed: std.atomic.Value(u64) = .init(0),
    n_resume_gap: std.atomic.Value(u64) = .init(0),
    n_gaps: std.atomic.Value(u64) = .init(0),
    /// Made by `create` (the server's): `deinit` frees it too.
    heap_owned: bool = false,
    metrics: ?Metrics = null,
    closed_by: [5]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0), .init(0), .init(0) },
    /// Called after a sender wrote `bytes` of a subscriber's own `send`s
    /// (the C ABI's pending-bytes accounting); on the sender's task.
    written_hook: ?*const fn (sub: *Subscriber, bytes: usize) void = null,

    pub const Options = struct {
        /// A comment line to every subscriber idle this long; null: none.
        heartbeat: ?Duration = .fromSeconds(15),
        /// Sent as `retry:` at the start of each stream; null: the browser's default (about 3 s).
        retry: ?Duration = null,
        /// Null: no ids, no replay, no gap events.
        replay: ?Replay = .{},
        /// Bytes waiting for one subscriber (each event counts 64 more).
        max_queued_bytes: usize = 256 * 1024,
        on_full: OnFull = .close,
        /// `.close`: a sender stuck this long on a full subscriber aborts its stream.
        close_after: Duration = .fromSeconds(1),
        /// How long `leave`, and a subscriber's end, let a write under way finish before canceling it.
        leave_grace: Duration = .fromSeconds(1),
        max_topics_per_subscriber: u16 = 64,
        /// The gap event's name (S8); null sends no gap events. No CR or LF.
        gap_event: ?[]const u8 = "gap",
        /// The retry spread at the drain (S12); null: streams just end.
        drain_retry: ?RetrySpread = .{},
        /// Tests: no ticker tasks; `_tick` is called by hand.
        _manual_ticks: bool = false,
    };

    pub const Replay = struct {
        events: u32 = 256,
        bytes: usize = 256 * 1024,
        total_bytes: usize = 64 * 1024 * 1024,
        max_age: Duration = .fromSeconds(300),
        max_per_resume: u32 = 1024,
    };

    pub const RetrySpread = struct { min: Duration = .fromMilliseconds(500), max: Duration = .fromSeconds(5) };

    pub const OnFull = enum { close, drop };

    pub const Stats = struct {
        subscribers: usize,
        topics: usize,
        replay_bytes: usize,
        published: u64,
        delivered: u64,
        dropped: u64,
        closed_slow: u64,
        resumed: u64,
        gaps: u64,
    };

    const ExecList = struct {
        subscribers: std.DoublyLinkedList = .{},
        ticker_running: bool = false,
    };

    pub const Topic = struct {
        name: []u8,
        members: std.ArrayList(*Subscriber) = .empty,
        ring: replay.Ring = .{},
        /// Since when it has no member (kept for `replay.max_age`).
        empty_since_ms: ?i64 = null,
    };

    /// `error.InvalidEventField` for a gap_event with CR or LF;
    /// `error.InvalidOptions` for replay.events 0 or > 65535, a RetrySpread with min > max.
    pub fn init(gpa: std.mem.Allocator, options: Options) error{ InvalidEventField, InvalidOptions, OutOfMemory }!Topics {
        if (options.gap_event) |g| if (!validField(g)) return error.InvalidEventField;
        if (options.replay) |r| if (r.events == 0 or r.events > 65535) return error.InvalidOptions;
        if (options.drain_retry) |d| if (d.min.nanoseconds > d.max.nanoseconds) return error.InvalidOptions;
        const hb = try Payload.create(gpa, .heartbeat, ":\n\n");
        errdefer hb.release(gpa);
        const end_p = try Payload.create(gpa, .end, "");
        return .{
            .gpa = gpa,
            .options = options,
            .epoch = 0,
            .heartbeat_payload = hb,
            .end_payload = end_p,
        };
    }

    /// `init` on the heap, freed by `deinit` (the server's topics).
    pub fn create(gpa: std.mem.Allocator, options: Options) error{ InvalidEventField, InvalidOptions, OutOfMemory }!*Topics {
        const t = try gpa.create(Topics);
        errdefer gpa.destroy(t);
        t.* = try init(gpa, options);
        t.heap_owned = true;
        return t;
    }

    /// After the server stopped (no subscriber left). The drain hook is not
    /// taken out of the registry it was added to: that outlives nothing here.
    pub fn deinit(self: *Topics) void {
        if (self.io_set.load(.acquire)) {
            self.tickers.cancel(self.io);
            self.ends.cancel(self.io);
        }
        // The entries point into the topics' rings: first.
        self.store.clear(self.gpa);
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            const t = entry.value_ptr.*;
            t.members.deinit(self.gpa);
            self.gpa.free(t.name);
            self.gpa.destroy(t);
        }
        self.topics.deinit(self.gpa);
        self.heartbeat_payload.release(self.gpa);
        self.end_payload.release(self.gpa);
        if (self.execs.len > 0) self.gpa.free(self.execs);
        if (self.heap_owned) self.gpa.destroy(self);
    }

    const Metrics = struct {
        subscribers: *observe_metrics.Gauge,
        topics: *observe_metrics.Gauge,
        replay_bytes: *observe_metrics.Gauge,
        published: *observe_metrics.Counter,
        delivered: *observe_metrics.Counter,
        dropped: *observe_metrics.Counter,
        closed: [5]*observe_metrics.Counter,
        resumes_exact: *observe_metrics.Counter,
        resumes_gap: *observe_metrics.Counter,
    };

    /// Reports to `registry` (`anole_sse_*`); the server calls it when
    /// serving starts, with the app's registry. Series are never labelled
    /// by topic: their number would be unbounded.
    pub fn start(self: *Topics, registry: ?*observe_metrics.Registry, tracer: ?*anyopaque, health: ?*anyopaque) !void {
        _ = tracer;
        _ = health;
        const r = registry orelse return;
        if (self.metrics != null) return;
        const closed_fam = try r.counter("anole_sse_subscribers_closed_total", "Server-sent-event subscribers that ended, by reason.", &.{"reason"});
        const resumes_fam = try r.counter("anole_sse_resumes_total", "Last-Event-ID resumes, exact or answered with a gap event.", &.{"result"});
        var m: Metrics = .{
            .subscribers = (try r.gauge("anole_sse_subscribers", "Open server-sent-event streams.", &.{})).with(&.{}),
            .topics = (try r.gauge("anole_sse_topics", "Topics with a member or a replay ring.", &.{})).with(&.{}),
            .replay_bytes = (try r.gauge("anole_sse_replay_bytes", "Bytes in the replay rings.", &.{})).with(&.{}),
            .published = (try r.counter("anole_sse_events_published_total", "Events published to a topic.", &.{})).with(&.{}),
            .delivered = (try r.counter("anole_sse_events_delivered_total", "Events queued for a subscriber.", &.{})).with(&.{}),
            .dropped = (try r.counter("anole_sse_events_dropped_total", "Events skipped for a full subscriber (on_full = drop).", &.{})).with(&.{}),
            .closed = undefined,
            .resumes_exact = resumes_fam.with(&.{"exact"}),
            .resumes_gap = resumes_fam.with(&.{"gap"}),
        };
        inline for (std.enums.values(CloseReason), 0..) |v, i| m.closed[i] = closed_fam.with(&.{@tagName(v)});
        self.metrics = m;
    }

    /// Copies the counters into the registry's series. Cheap; called where
    /// they change.
    fn syncMetrics(self: *Topics, topics_n: ?usize, replay_bytes: ?usize) void {
        const m = self.metrics orelse return;
        m.subscribers.set(@intCast(self.subscribers.load(.monotonic)));
        if (topics_n) |n| m.topics.set(@intCast(n));
        if (replay_bytes) |n| m.replay_bytes.set(@intCast(n));
        m.published.value.store(self.n_published.load(.monotonic), .monotonic);
        m.delivered.value.store(self.n_delivered.load(.monotonic), .monotonic);
        m.dropped.value.store(self.n_dropped.load(.monotonic), .monotonic);
        for (m.closed, 0..) |c, i| c.value.store(self.closed_by[i].load(.monotonic), .monotonic);
        const resumed = self.n_resumed.load(.monotonic);
        const gaps = self.n_resume_gap.load(.monotonic);
        m.resumes_gap.value.store(gaps, .monotonic);
        m.resumes_exact.value.store(resumed -| gaps, .monotonic);
    }

    /// The `std.Io` to lock with: `io` (a subscriber's) unless an earlier
    /// one was taken.
    pub fn bind(self: *Topics, io: std.Io) std.Io {
        if (!self.io_set.load(.acquire)) {
            while (!self.io_lock.tryLock()) std.atomic.spinLoopHint();
            defer self.io_lock.unlock();
            if (!self.io_set.load(.monotonic)) {
                self.io = io;
                var epoch_bytes: [4]u8 = undefined;
                io.random(&epoch_bytes);
                self.epoch = std.mem.readInt(u32, &epoch_bytes, .little);
                const n = placement.executorCount(io) orelse 1;
                self.execs = self.gpa.alloc(ExecList, n) catch &.{};
                for (self.execs) |*e| e.* = .{};
                self.io_set.store(true, .release);
            }
        }
        return self.io;
    }

    fn bound(self: *Topics) ?std.Io {
        return if (self.io_set.load(.acquire)) self.io else null;
    }

    fn nowMs(self: *Topics) i64 {
        const fake = self.fake_now_ms.load(.monotonic);
        if (fake != std.math.minInt(i64)) return fake;
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    /// Registers the drain hook with `hooks` (once); a hook added after
    /// the drain started runs at once.
    pub fn _registerDrain(self: *Topics, io: std.Io, hooks: *dusty.DrainHooks) void {
        _ = self.bind(io);
        self.mutex.lockUncancelable(io);
        const already = self.drain_hooks != null;
        if (!already) self.drain_hooks = hooks;
        self.mutex.unlock(io);
        if (!already) hooks.add(io, &self.drain_hook);
    }

    // -- publishing ------------------------------------------------------

    /// Encodes `ev` into a payload (refs = 1, no id yet).
    pub fn _encode(self: *Topics, ev: Event) PublishError!*Payload {
        if (ev.event) |e| if (!validField(e)) return error.InvalidEventField;
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        dusty.writeEvent(&aw.writer, ev.data, .{ .event = ev.event }) catch return error.OutOfMemory;
        return Payload.create(self.gpa, .event, aw.written()) catch error.OutOfMemory;
    }

    /// Queues `ev` for every subscriber of `topic` (1-255 bytes); how many
    /// took it. Never waits for a subscriber. A topic nobody joined within
    /// `replay.max_age` is not created: 0.
    pub fn publish(self: *Topics, topic: []const u8, ev: Event) PublishError!usize {
        if (!validTopic(topic)) return error.InvalidTopic;
        const p = try self._encode(ev);
        defer p.release(self.gpa);
        return self._publishPayload(topic, p, ev.replay);
    }

    /// `publish` with `value` as JSON (std.json, into a scratch buffer).
    pub fn publishJson(self: *Topics, topic: []const u8, event: ?[]const u8, value: anytype) PublishError!usize {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        std.json.Stringify.value(value, .{}, &aw.writer) catch return error.OutOfMemory;
        return self.publish(topic, .{ .data = aw.written(), .event = event });
    }

    /// `publish` for a payload already encoded (`_encode`; the caller keeps
    /// its reference, and publishes a payload once). The one place events
    /// are numbered (S16: a cluster bus would assign `seq` and `epoch` and
    /// call this on every instance).
    pub fn _publishPayload(self: *Topics, topic: []const u8, p: *Payload, record: bool) usize {
        const io = self.bound() orelse return 0;
        var stack: [stack_snapshot]*Subscriber = undefined;
        var heap: []*Subscriber = &.{};
        defer self.gpa.free(heap);
        var starting: []*Subscriber = &.{};
        var reached: usize = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const t = self.topics.get(topic) orelse return 0;
            self.seq += 1;
            if (self.options.replay != null) p.setId(self.epoch, self.seq) else p.seq = self.seq;
            const now = self.nowMs();
            if (self.options.replay) |r| {
                if (record) {
                    self.store.add(self.gpa, &t.ring, p, now, .{
                        .events = r.events,
                        .bytes = r.bytes,
                        .total_bytes = r.total_bytes,
                        .max_age_ms = r.max_age.toMilliseconds(),
                    });
                } else {
                    // Not kept: a resume cannot replay it, so the ring is
                    // incomplete up to here.
                    t.ring.complete_after = self.seq;
                }
            }
            const members = t.members.items;
            const buf: ?[]*Subscriber = if (members.len <= stack.len) &stack else if (self.gpa.alloc(*Subscriber, members.len)) |h| big: {
                heap = h;
                break :big h;
            } else |_| null;
            var n: usize = 0;
            for (members) |sub| {
                if (sub.ending or sub.broken or sub.left) {
                    self.checkStuck(sub, now);
                    continue;
                }
                if (sub.queued_bytes > 0 and sub.queued_bytes + p.cost() > self.options.max_queued_bytes) {
                    if (self.options.on_full == .drop) {
                        _ = self.n_dropped.fetchAdd(1, .monotonic);
                        continue;
                    }
                    self.beginClose(sub, .slow, true);
                    self.checkStuck(sub, now);
                    if (!sub.running and sub.armed) {
                        sub.running = true;
                        if (buf) |b| {
                            b[n] = sub;
                            n += 1;
                        } else self.startSender(io, sub);
                    }
                    continue;
                }
                sub.queue.append(self.gpa, p) catch continue;
                p.retain();
                sub.queued_bytes += p.cost();
                reached += 1;
                if (sub.running or !sub.armed) continue;
                sub.running = true;
                if (buf) |b| {
                    b[n] = sub;
                    n += 1;
                } else self.startSender(io, sub);
            }
            if (buf) |b| starting = b[0..n];
        }
        _ = self.n_published.fetchAdd(1, .monotonic);
        _ = self.n_delivered.fetchAdd(reached, .monotonic);
        if (self.metrics != null) self.syncMetrics(null, null);
        for (starting) |sub| self.startSender(io, sub);
        return reached;
    }

    /// The gap event to `topic`'s subscribers, and its ring covers only what follows (S8).
    pub fn gap(self: *Topics, topic: []const u8) void {
        self.gapMatching(topic, false);
    }

    /// `gap` for every topic starting with `prefix` ("" for all).
    pub fn gapPrefix(self: *Topics, prefix: []const u8) void {
        self.gapMatching(prefix, true);
    }

    fn gapMatching(self: *Topics, name: []const u8, prefix: bool) void {
        const io = self.bound() orelse return;
        var started: std.ArrayList(*Subscriber) = .empty;
        defer started.deinit(self.gpa);
        self.mutex.lockUncancelable(io);
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            const matches = if (prefix) std.mem.startsWith(u8, entry.key_ptr.*, name) else std.mem.eql(u8, entry.key_ptr.*, name);
            if (!matches) continue;
            const t = entry.value_ptr.*;
            self.seq += 1;
            // Its ring's old entries cannot be told from a complete one.
            while (t.ring.list.first) |n| self.store.evict(self.gpa, replay.Entry.fromTopicNode(n));
            t.ring.complete_after = self.seq;
            const gap_name = self.options.gap_event orelse continue;
            const body = self.gapBody(gap_name, self.seq, &.{t.name}) catch continue;
            _ = self.n_gaps.fetchAdd(1, .monotonic);
            for (t.members.items) |sub| {
                if (sub.ending or sub.broken or sub.left) continue;
                sub.queue.append(self.gpa, body) catch continue;
                body.retain();
                sub.queued_bytes += body.cost();
                if (!sub.running and sub.armed) {
                    sub.running = true;
                    started.append(self.gpa, sub) catch {
                        sub.running = false;
                    };
                }
            }
            body.release(self.gpa);
        }
        self.mutex.unlock(io);
        for (started.items) |sub| self.startSender(io, sub);
    }

    /// `event: <name>\nid: <epoch>-<seq>\ndata: {"topics":[...]}\n\n`.
    fn gapBody(self: *Topics, name: []const u8, seq: u64, topics: []const []const u8) std.mem.Allocator.Error!*Payload {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("event: {s}\n", .{name}) catch return error.OutOfMemory;
        if (self.options.replay != null) w.print("id: {x:0>8}-{d}\n", .{ self.epoch, seq }) catch return error.OutOfMemory;
        w.writeAll("data: {\"topics\":") catch return error.OutOfMemory;
        std.json.Stringify.value(topics, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}\n\n") catch return error.OutOfMemory;
        const p = try Payload.create(self.gpa, .gap, aw.written());
        p.seq = seq;
        return p;
    }

    pub fn count(self: *Topics, topic: []const u8) usize {
        const io = self.bound() orelse return 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.topics.get(topic)) |t| t.members.items.len else 0;
    }

    pub fn stats(self: *Topics) Stats {
        var topics_n: usize = 0;
        var replay_bytes: usize = 0;
        if (self.bound()) |io| {
            self.mutex.lockUncancelable(io);
            topics_n = self.topics.count();
            replay_bytes = self.store.bytes;
            self.mutex.unlock(io);
        }
        return .{
            .subscribers = self.subscribers.load(.monotonic),
            .topics = topics_n,
            .replay_bytes = replay_bytes,
            .published = self.n_published.load(.monotonic),
            .delivered = self.n_delivered.load(.monotonic),
            .dropped = self.n_dropped.load(.monotonic),
            .closed_slow = self.n_closed_slow.load(.monotonic),
            .resumed = self.n_resumed.load(.monotonic),
            .gaps = self.n_gaps.load(.monotonic),
        };
    }

    // -- serving ---------------------------------------------------------

    /// Answers `req` with an event stream subscribed to `opts.topics`: writes
    /// the head and the open line, replays what `Last-Event-ID` (header, or
    /// the `lastEventId` query parameter of EventSource polyfills) missed,
    /// and parks the stream. The handler's last call: return right after it
    /// (`try topics.serve(req, res, .{...}); return;`) and touch neither
    /// `req` nor `res` again. Returns at once when the stream parked; in the
    /// fallback (S3) only when the subscriber ended. A HEAD gets the head only.
    pub fn serve(self: *Topics, req: *dusty.Request, res: *dusty.Response, opts: ServeOptions) ServeError!void {
        if (opts.topics.len > self.options.max_topics_per_subscriber) return error.TooManyTopics;
        for (opts.topics) |t| if (!validTopic(t)) return error.InvalidTopic;
        res.compress = false;
        try res.header("Content-Type", "text/event-stream");
        try res.header("Cache-Control", "no-cache");
        try res.header("X-Accel-Buffering", "no");
        for (opts.headers) |h| try res.addHeader(h[0], h[1]);
        if (req.method == .head) return;

        const io = req.io;
        _ = self.bind(io);
        if (opts.on_drain_hooks) |hooks| self._registerDrain(io, hooks) else if (req._drain_hooks) |hooks| self._registerDrain(io, hooks);
        const last_header: ?[]const u8 = req.headers.get("Last-Event-ID") orelse req.queryParam("lastEventId");

        const sub = try self.newSubscriber(io, .{
            .context = opts.context,
            .on_close = opts.on_close,
            .version = versionOf(req, res),
        });

        if (res._canPark()) {
            self.register(io, sub, opts, last_header) catch |err| {
                self.freeSubscriber(sub);
                return err;
            };
            const owner: dusty.Parked.Owner = .{ .gone = onGone, .ctx = sub };
            if (res._park(req, owner)) |p| {
                sub.out = Out.fromParked(p);
                sub.has_out = true;
                self.arm(io, sub, opts);
                return;
            } else |err| {
                self.abandon(io, sub);
                switch (err) {
                    error.Unsupported => {},
                    error.OutOfMemory => {
                        self.freeSubscriber(sub);
                        return error.OutOfMemory;
                    },
                    error.WriteFailed => {
                        self.freeSubscriber(sub);
                        return;
                    },
                }
            }
        }
        return self.serveFallback(req, res, sub, opts, last_header);
    }

    fn versionOf(req: *const dusty.Request, res: *const dusty.Response) HttpVersion {
        if (res._sink == null) return .http1;
        return if (req.version_major == 3) .http3 else .http2;
    }

    /// The handler's own task serves the subscriber (S3's fallback).
    fn serveFallback(self: *Topics, req: *dusty.Request, res: *dusty.Response, sub: *Subscriber, opts: ServeOptions, last_header: ?[]const u8) ServeError!void {
        const io = req.io;
        self.register(io, sub, opts, last_header) catch |err| {
            self.freeSubscriber(sub);
            return err;
        };
        const buf = req.arena.alloc(u8, 4096) catch {
            self.abandon(io, sub);
            self.freeSubscriber(sub);
            return error.OutOfMemory;
        };
        var fb: out_mod.Fallback = .{ .res = res, .body = res.stream(buf) catch |err| {
            self.abandon(io, sub);
            self.freeSubscriber(sub);
            return err;
        } };
        sub.out = fb.out();
        sub.has_out = true;
        sub.fallback = true;
        self.arm(io, sub, opts);
        while (true) {
            sub.wake.wait(io) catch break;
            sub.wake.reset();
            self.sendQueued(sub) catch break;
            if (sub.over or sub.broken) break;
        }
        // Canceled (the peer reset the stream, the server stopped) is the
        // peer going away; otherwise the hub ended the stream.
        const reason: CloseReason = if (sub.over) sub.close_reason else .client_gone;
        self.finishSubscriber(sub, reason);
        if (fb.aborted) return error.ResponseAborted;
    }

    /// A subscriber made but not in the hub yet.
    const NewSub = struct {
        context: ?*anyopaque = null,
        on_close: ?*const fn (sub: *Subscriber, reason: CloseReason) void = null,
        version: HttpVersion = .http1,
    };

    fn newSubscriber(self: *Topics, io: std.Io, init_opts: NewSub) error{OutOfMemory}!*Subscriber {
        const sub = try self.gpa.create(Subscriber);
        sub.* = .{
            .hub = self,
            .context = init_opts.context,
            .on_close = init_opts.on_close,
            .version = init_opts.version,
            .executor = placement.currentExecutor(io),
            .index = self.next_index.fetchAdd(1, .monotonic),
            .last_write_ms = self.nowMs(),
        };
        return sub;
    }

    /// For a subscriber made by tests or the C ABI over an `Out` of their
    /// own: registers it with `opts.topics` and arms it.
    pub fn _attach(self: *Topics, io: std.Io, out: Out, opts: ServeOptions, last_header: ?[]const u8) !*Subscriber {
        _ = self.bind(io);
        for (opts.topics) |t| if (!validTopic(t)) return error.InvalidTopic;
        const sub = try self.newSubscriber(io, .{ .context = opts.context, .on_close = opts.on_close });
        sub.out = out;
        sub.has_out = true;
        self.register(io, sub, opts, last_header) catch |err| {
            self.freeSubscriber(sub);
            return err;
        };
        self.arm(io, sub, opts);
        return sub;
    }

    /// The peer is gone, from a test or an engine without a callback.
    pub fn _gone(sub: *Subscriber) void {
        onGone(sub);
    }

    fn freeSubscriber(self: *Topics, sub: *Subscriber) void {
        for (sub.queue.items[sub.head..]) |p| p.release(self.gpa);
        sub.queue.deinit(self.gpa);
        sub.memberships.deinit(self.gpa);
        self.gpa.destroy(sub);
    }

    /// Joins `opts.topics`, queues the open line and the replay, and links
    /// the subscriber into its executor's list. Under no lock on entry.
    fn register(self: *Topics, io: std.Io, sub: *Subscriber, opts: ServeOptions, last_header: ?[]const u8) error{ OutOfMemory, TooManyTopics, InvalidTopic }!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        errdefer self.unlinkLocked(sub);
        if (self.draining.load(.acquire)) {
            sub.draining_at_start = true;
        } else {
            for (opts.topics) |name| try self.joinLocked(sub, name);
        }
        if (self.execs.len > 0) self.execs[sub.execIndex(self)].subscribers.append(&sub.exec_node);
        sub.linked = true;
        _ = self.subscribers.fetchAdd(1, .monotonic);
        try self.queueOpenLine(sub);
        if (sub.draining_at_start) {
            try self.queueDrainEnd(sub);
        } else {
            try self.queueReplayLocked(sub, last_header, opts.last);
        }
    }

    /// After a failed head: out of the hub again, the subscriber still ours.
    fn abandon(self: *Topics, io: std.Io, sub: *Subscriber) void {
        self.mutex.lockUncancelable(io);
        self.unlinkLocked(sub);
        sub.dropQueue(self.gpa);
        self.mutex.unlock(io);
    }

    /// Everything after the head is out: `on_open`, the first sender.
    fn arm(self: *Topics, io: std.Io, sub: *Subscriber, opts: ServeOptions) void {
        if (opts.on_open) |f| f(sub);
        var launch = false;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            sub.armed = true;
            if (!sub.running and sub.head < sub.queue.items.len) {
                sub.running = true;
                launch = true;
            }
        }
        if (launch) self.startSender(io, sub);
        self.ensureTickers(io, sub);
    }

    fn joinLocked(self: *Topics, sub: *Subscriber, name: []const u8) error{ OutOfMemory, TooManyTopics, InvalidTopic }!void {
        if (!validTopic(name)) return error.InvalidTopic;
        for (sub.memberships.items) |t| if (std.mem.eql(u8, t.name, name)) return;
        if (sub.memberships.items.len >= self.options.max_topics_per_subscriber) return error.TooManyTopics;
        const t = try self.topicLocked(name);
        try t.members.append(self.gpa, sub);
        errdefer _ = t.members.pop();
        try sub.memberships.append(self.gpa, t);
        t.empty_since_ms = null;
    }

    fn topicLocked(self: *Topics, name: []const u8) error{OutOfMemory}!*Topic {
        if (self.topics.get(name)) |t| return t;
        const t = try self.gpa.create(Topic);
        errdefer self.gpa.destroy(t);
        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        t.* = .{ .name = key, .ring = .{ .complete_after = self.seq } };
        try self.topics.put(self.gpa, key, t);
        return t;
    }

    /// Takes `sub` out of every topic and its executor's list.
    fn unlinkLocked(self: *Topics, sub: *Subscriber) void {
        const now = if (self.io_set.load(.acquire)) self.nowMs() else 0;
        for (sub.memberships.items) |t| {
            for (t.members.items, 0..) |m, i| if (m == sub) {
                _ = t.members.swapRemove(i);
                break;
            };
            if (t.members.items.len == 0) t.empty_since_ms = now;
        }
        sub.memberships.clearRetainingCapacity();
        if (sub.linked) {
            sub.linked = false;
            if (self.execs.len > 0) self.execs[sub.execIndex(self)].subscribers.remove(&sub.exec_node);
            _ = self.subscribers.fetchSub(1, .monotonic);
        }
    }

    fn queueOpenLine(self: *Topics, sub: *Subscriber) error{OutOfMemory}!void {
        var buf: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        if (self.options.retry) |r| w.print("retry: {d}\n", .{r.toMilliseconds()}) catch unreachable;
        if (self.options.replay != null) w.print("id: {x:0>8}-{d}\n", .{ self.epoch, self.seq }) catch unreachable;
        if (w.end == 0) return;
        w.writeAll("\n") catch unreachable;
        const p = try Payload.create(self.gpa, .retry, w.buffered());
        errdefer p.release(self.gpa);
        try self.enqueueLocked(sub, p);
    }

    /// Appends `p` (the caller's reference is consumed on success).
    fn enqueueLocked(self: *Topics, sub: *Subscriber, p: *Payload) error{OutOfMemory}!void {
        try sub.queue.append(self.gpa, p);
        sub.queued_bytes += p.cost();
    }

    fn queueDrainEnd(self: *Topics, sub: *Subscriber) error{OutOfMemory}!void {
        if (self.options.drain_retry) |spread| {
            const p = try self.retryPayload(spread, sub.index);
            errdefer p.release(self.gpa);
            try self.enqueueLocked(sub, p);
        }
        self.end_payload.retain();
        errdefer self.end_payload.release(self.gpa);
        try self.enqueueLocked(sub, self.end_payload);
        sub.ending = true;
        sub.close_reason = .drain;
    }

    /// `retry: N\n\n`, N spread over the range by the subscriber's index.
    fn retryPayload(self: *Topics, spread: RetrySpread, index: u32) error{OutOfMemory}!*Payload {
        const lo = spread.min.toMilliseconds();
        const hi = @max(lo, spread.max.toMilliseconds());
        const slot: i64 = @intCast(index % drain_spread);
        const ms = lo + @divTrunc((hi - lo) * slot, drain_spread - 1);
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "retry: {d}\n\n", .{ms}) catch unreachable;
        return Payload.create(self.gpa, .retry, text);
    }

    /// Queues the replay (S7, S8) after the joins. Under the mutex.
    fn queueReplayLocked(self: *Topics, sub: *Subscriber, last_header: ?[]const u8, last_n: u16) error{OutOfMemory}!void {
        const cfg = self.options.replay orelse return;
        const joined = sub.memberships.items;
        if (joined.len == 0) return;
        var entries: std.ArrayList(*replay.Entry) = .empty;
        defer entries.deinit(self.gpa);
        var gap_topics: std.ArrayList([]const u8) = .empty;
        defer gap_topics.deinit(self.gpa);

        if (last_header) |text| {
            const parsed = replay.parseLastEventId(text);
            var all_gap = parsed == null or parsed.?.epoch != self.epoch;
            if (!all_gap) {
                const last = parsed.?.seq;
                for (joined) |t| {
                    if (last < t.ring.complete_after) {
                        try gap_topics.append(self.gpa, t.name);
                        continue;
                    }
                    // Back to the first entry past `last`.
                    var node = t.ring.list.last;
                    var first: ?*std.DoublyLinkedList.Node = null;
                    while (node) |n| : (node = n.prev) {
                        if (replay.Entry.fromTopicNode(n).payload.seq <= last) break;
                        first = n;
                    }
                    var cur = first;
                    while (cur) |n| : (cur = n.next) try entries.append(self.gpa, replay.Entry.fromTopicNode(n));
                }
                if (entries.items.len > cfg.max_per_resume) all_gap = true;
                var bytes: usize = 0;
                for (entries.items) |e| bytes += e.payload.cost();
                if (bytes > self.options.max_queued_bytes) all_gap = true;
            }
            if (all_gap or gap_topics.items.len > 0) _ = self.n_resume_gap.fetchAdd(1, .monotonic);
            if (all_gap) {
                entries.clearRetainingCapacity();
                gap_topics.clearRetainingCapacity();
                for (joined) |t| try gap_topics.append(self.gpa, t.name);
            }
            _ = self.n_resumed.fetchAdd(1, .monotonic);
        } else if (last_n > 0) {
            for (joined) |t| {
                var node = t.ring.list.last;
                var taken: u16 = 0;
                var first: ?*std.DoublyLinkedList.Node = null;
                while (node) |n| : (node = n.prev) {
                    if (taken >= last_n) break;
                    first = n;
                    taken += 1;
                }
                var cur = first;
                while (cur) |n| : (cur = n.next) try entries.append(self.gpa, replay.Entry.fromTopicNode(n));
            }
        } else return;

        std.mem.sort(*replay.Entry, entries.items, {}, struct {
            fn less(_: void, a: *replay.Entry, b: *replay.Entry) bool {
                return a.payload.seq < b.payload.seq;
            }
        }.less);
        for (entries.items) |e| {
            e.payload.retain();
            errdefer e.payload.release(self.gpa);
            try self.enqueueLocked(sub, e.payload);
        }
        if (gap_topics.items.len > 0) if (self.options.gap_event) |name| {
            // The fresh id stops the next reconnect from reporting it again.
            const body = try self.gapBody(name, self.seq, gap_topics.items);
            errdefer body.release(self.gpa);
            _ = self.n_gaps.fetchAdd(1, .monotonic);
            try self.enqueueLocked(sub, body);
        };
    }

    // -- slow and stuck subscribers -------------------------------------

    /// A subscriber that takes no more events: after what is queued, its
    /// stream ends. Under the mutex.
    fn beginClose(self: *Topics, sub: *Subscriber, reason: CloseReason, count_slow: bool) void {
        if (sub.ending) return;
        sub.ending = true;
        sub.close_reason = reason;
        if (count_slow) _ = self.n_closed_slow.fetchAdd(1, .monotonic);
        self.end_payload.retain();
        sub.queue.append(self.gpa, self.end_payload) catch {
            self.end_payload.release(self.gpa);
            // No room even for that: it is stuck, and aborted below.
            sub.abort_requested = true;
            return;
        };
        sub.queued_bytes += self.end_payload.cost();
    }

    /// A sender stuck on an ending subscriber past `close_after` is
    /// canceled, which aborts the stream. Under the mutex.
    fn checkStuck(self: *Topics, sub: *Subscriber, now: i64) void {
        if (!sub.ending or !sub.running) return;
        const since = sub.sending_since_ms orelse return;
        if (now - since < self.options.close_after.toMilliseconds()) return;
        sub.abort_requested = true;
        if (sub.task) |t| placement.cancelTask(t);
    }

    // -- senders ---------------------------------------------------------

    /// Starts `sub`'s sender, `sub.running` already set. Without a task to
    /// spare, what is queued waits for the next event to try again.
    fn startSender(self: *Topics, io: std.Io, sub: *Subscriber) void {
        if (sub.fallback) {
            sub.wake.set(io);
            return;
        }
        const where: placement.Where = if (sub.executor) |i| .{ .executor = i } else .local;
        placement.concurrent(&sub.sender, io, where, senderTask, .{ self, sub }) catch {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            sub.running = false;
            if (sub.left) self.idle.broadcast(io);
        };
    }

    fn senderTask(self: *Topics, sub: *Subscriber) std.Io.Cancelable!void {
        return self.sendQueued(sub);
    }

    /// A subscriber's sender: writes what is queued for it, in order, until
    /// the queue is empty or the subscriber is done. Everything queued, up
    /// to a round's worth, goes out in one write.
    pub fn sendQueued(self: *Topics, sub: *Subscriber) error{Canceled}!void {
        const io = self.io;
        var canceled = false;
        var in_burst = false;
        var ended = false;
        var aborted = false;
        self.mutex.lockUncancelable(io);
        sub.task = placement.currentTask(io);
        // Each pass: send until the queue is empty, end the burst. Events
        // queued while the burst ended (unlocked) found `running` set and
        // started no sender: a further pass takes them.
        pass: while (true) {
            while (!sub.left and !sub.broken) {
                var round: [send_round]*Payload = undefined;
                var n: usize = 0;
                while (n < round.len) {
                    round[n] = sub.pop() orelse break;
                    n += 1;
                }
                if (n == 0) break;
                sub.sending_since_ms = self.nowMs();
                self.mutex.unlock(io);
                var ok = true;
                if (!in_burst) {
                    if (sub.out.begin()) in_burst = true else ok = false;
                }
                var has_end = false;
                if (ok) {
                    var parts: [send_round * 2][]const u8 = undefined;
                    var np: usize = 0;
                    var sent_bytes: usize = 0;
                    for (round[0..n]) |p| {
                        switch (p.kind) {
                            .end => {
                                has_end = true;
                                break;
                            },
                            .event => {
                                if (p.id_len > 0) {
                                    parts[np] = p.idLine();
                                    np += 1;
                                }
                                parts[np] = p.body();
                                np += 1;
                                if (p.seq == 0) sent_bytes += p.cost();
                            },
                            else => {
                                parts[np] = p.body();
                                np += 1;
                            },
                        }
                    }
                    if (np > 0) {
                        sub.out.write(parts[0..np]) catch |err| {
                            if (err == error.Canceled) canceled = true;
                            ok = false;
                        };
                    }
                    if (ok and sent_bytes > 0) if (self.written_hook) |hook| hook(sub, sent_bytes);
                }
                for (round[0..n]) |p| p.release(self.gpa);
                self.mutex.lockUncancelable(io);
                sub.sending_since_ms = null;
                sub.last_write_ms = self.nowMs();
                if (!ok) {
                    sub.broken = true;
                    sub.dropQueue(self.gpa);
                    if (canceled and sub.ending and sub.abort_requested) aborted = true;
                    break;
                }
                if (has_end) {
                    ended = true;
                    sub.dropQueue(self.gpa);
                    break;
                }
            }
            self.mutex.unlock(io);
            if (in_burst) {
                if (ended) {
                    sub.out.end();
                } else if (aborted) {
                    sub.out.abort();
                } else {
                    sub.out.endBurst();
                }
            }
            self.mutex.lockUncancelable(io);
            if (!ended and !aborted and !canceled and !sub.left and !sub.broken and sub.head < sub.queue.items.len) {
                in_burst = false;
                continue :pass;
            }
            break :pass;
        }
        if (ended or aborted) sub.over = true;
        sub.running = false;
        sub.task = null;
        const spawn_end = (ended or aborted or sub.broken) and !sub.fallback;
        if (sub.broken and !ended and !aborted) sub.close_reason = .client_gone;
        if (sub.left) self.idle.broadcast(io);
        self.mutex.unlock(io);
        if (spawn_end) self.spawnEnd(sub);
        if (canceled and !aborted) return error.Canceled;
    }

    /// Starts the task that ends `sub`, once.
    fn spawnEnd(self: *Topics, sub: *Subscriber) void {
        if (sub.end_started.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        const io = self.io;
        const where: placement.Where = if (sub.executor) |i| .{ .executor = i } else .local;
        placement.concurrent(&self.ends, io, where, endTask, .{ self, sub }) catch {
            // A tick tries again.
            sub.end_started.store(false, .release);
        };
    }

    fn endTask(self: *Topics, sub: *Subscriber) std.Io.Cancelable!void {
        self.finishSubscriber(sub, sub.close_reason);
    }

    /// Leaves every topic, waits for the sender, releases the stream, tells
    /// `on_close` and frees the subscriber.
    fn finishSubscriber(self: *Topics, sub: *Subscriber, reason: CloseReason) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        sub.left = true;
        self.unlinkLocked(sub);
        sub.dropQueue(self.gpa);
        const canceled = self.awaitSender(io, sub);
        self.mutex.unlock(io);
        _ = self.closed_by[@backingInt(reason)].fetchAdd(1, .monotonic);
        if (self.metrics != null) self.syncMetrics(null, null);
        if (sub.has_out) sub.out.release();
        sub.sender.cancel(io);
        if (sub.on_close) |f| f(sub, reason);
        self.freeSubscriber(sub);
        if (canceled) io.recancel();
    }

    /// Waits for `sub`'s sender to end: a write under way gets
    /// `leave_grace` to finish, and is canceled after. Under the mutex,
    /// which it lets go while it waits. Whether the caller was canceled
    /// meanwhile.
    fn awaitSender(self: *Topics, io: std.Io, sub: *Subscriber) bool {
        var canceled = false;
        const grace: std.Io.Timeout = .{ .duration = .{ .raw = self.options.leave_grace, .clock = .awake } };
        const deadline = grace.toDeadline(io);
        while (sub.running) {
            self.idle.waitTimeout(io, &self.mutex, deadline) catch |err| {
                if (err == error.Canceled) canceled = true;
                break;
            };
        }
        if (sub.running) {
            if (sub.task) |t| {
                placement.cancelTask(t);
            } else if (!sub.fallback) {
                // No task to cancel by itself (std.Io.Threaded): cancel the
                // sender's group, which also waits for it; it takes the
                // mutex on its way out.
                self.mutex.unlock(io);
                sub.sender.cancel(io);
                self.mutex.lockUncancelable(io);
            }
        }
        while (sub.running) self.idle.waitUncancelable(io, &self.mutex);
        return canceled;
    }

    // -- the peer going away ---------------------------------------------

    /// `Parked.Owner.gone`: must not wait. Marks the subscriber and starts
    /// its end task.
    fn onGone(ctx: *anyopaque) void {
        const sub: *Subscriber = @ptrCast(@alignCast(ctx));
        sub.gone.store(true, .release);
        if (!sub.ending) sub.close_reason = .client_gone;
        sub.hub.spawnEnd(sub);
    }

    // -- tickers (heartbeats, stuck senders, the sweep) ------------------

    fn ensureTickers(self: *Topics, io: std.Io, sub: *Subscriber) void {
        if (self.options._manual_ticks or self.execs.len == 0) return;
        const exec = sub.execIndex(self);
        self.mutex.lockUncancelable(io);
        const want0 = !self.execs[0].ticker_running;
        const wantx = exec != 0 and !self.execs[exec].ticker_running;
        if (want0) self.execs[0].ticker_running = true;
        if (wantx) self.execs[exec].ticker_running = true;
        self.mutex.unlock(io);
        if (want0) self.startTicker(io, 0);
        if (wantx) self.startTicker(io, exec);
    }

    fn startTicker(self: *Topics, io: std.Io, exec: usize) void {
        placement.concurrent(&self.tickers, io, .{ .executor = exec }, tickerTask, .{ self, exec }) catch {
            self.mutex.lockUncancelable(io);
            self.execs[exec].ticker_running = false;
            self.mutex.unlock(io);
        };
    }

    fn tickerTask(self: *Topics, exec: usize) std.Io.Cancelable!void {
        const io = self.io;
        const period: i64 = if (self.options.heartbeat) |h| @min(@divTrunc(h.toMilliseconds(), 2), 5000) else 5000;
        const sleep_ms = @max(period, 1);
        while (true) {
            try io.sleep(.fromMilliseconds(sleep_ms), .awake);
            if (!self.tick(exec, self.nowMs())) return;
        }
    }

    /// One tick of executor `exec`'s ticker at `now_ms` (a test's made-up
    /// clock, which this also adopts): see `tick`.
    pub fn _tick(self: *Topics, exec: usize, now_ms: i64) bool {
        self.fake_now_ms.store(now_ms, .monotonic);
        return self.tick(exec, now_ms);
    }

    /// Heartbeats for idle subscribers of executor `exec`, stuck senders,
    /// ends that could not start, and (executor 0) the sweep of old events
    /// and empty topics. False when this ticker has nothing left to watch
    /// and ends.
    fn tick(self: *Topics, exec: usize, now_ms: i64) bool {
        const io = self.io;
        var stack: [stack_snapshot]*Subscriber = undefined;
        var n: usize = 0;
        var ends: [stack_snapshot]*Subscriber = undefined;
        var ne: usize = 0;
        var more = false;
        self.mutex.lockUncancelable(io);
        if (exec < self.execs.len) {
            const list = &self.execs[exec];
            const hb_ms: ?i64 = if (self.options.heartbeat) |h| h.toMilliseconds() else null;
            var node = list.subscribers.first;
            while (node) |nd| : (node = nd.next) {
                const sub: *Subscriber = @alignCast(@fieldParentPtr("exec_node", nd));
                if (sub.gone.load(.acquire) and !sub.end_started.load(.acquire)) {
                    if (ne < ends.len) {
                        ends[ne] = sub;
                        ne += 1;
                    }
                    continue;
                }
                self.checkStuck(sub, now_ms);
                if (hb_ms) |hb| {
                    if (!sub.ending and !sub.broken and !sub.left and sub.armed and now_ms - sub.last_write_ms >= hb) {
                        self.heartbeat_payload.retain();
                        if (sub.queue.append(self.gpa, self.heartbeat_payload)) |_| {
                            sub.queued_bytes += self.heartbeat_payload.cost();
                            sub.last_write_ms = now_ms;
                            if (!sub.running and n < stack.len) {
                                sub.running = true;
                                stack[n] = sub;
                                n += 1;
                            }
                        } else |_| self.heartbeat_payload.release(self.gpa);
                    }
                }
            }
            more = list.subscribers.first != null;
        }
        if (exec == 0) {
            if (self.options.replay) |r| {
                if (now_ms - self.last_sweep_ms >= 1000 or self.options.heartbeat == null) {
                    self.last_sweep_ms = now_ms;
                    self.store.sweep(self.gpa, now_ms, r.max_age.toMilliseconds());
                }
                self.sweepTopicsLocked(now_ms, r.max_age.toMilliseconds());
            } else {
                self.sweepTopicsLocked(now_ms, 0);
            }
            more = more or self.topics.count() > 0;
        }
        if (!more and exec < self.execs.len) self.execs[exec].ticker_running = false;
        if (self.metrics != null) self.syncMetrics(self.topics.count(), self.store.bytes);
        self.mutex.unlock(io);
        for (stack[0..n]) |sub| self.startSender(io, sub);
        for (ends[0..ne]) |sub| self.spawnEnd(sub);
        return more;
    }

    /// Frees topics with no member for longer than `max_age_ms`. Under the mutex.
    fn sweepTopicsLocked(self: *Topics, now_ms: i64, max_age_ms: i64) void {
        var doomed: [16]*Topic = undefined;
        var nd: usize = 0;
        var it = self.topics.valueIterator();
        while (it.next()) |tp| {
            const t = tp.*;
            const since = t.empty_since_ms orelse continue;
            if (t.members.items.len != 0) continue;
            if (now_ms - since < max_age_ms) continue;
            if (nd < doomed.len) {
                doomed[nd] = t;
                nd += 1;
            }
        }
        for (doomed[0..nd]) |t| {
            while (t.ring.list.first) |node| self.store.evict(self.gpa, replay.Entry.fromTopicNode(node));
            _ = self.topics.remove(t.name);
            t.members.deinit(self.gpa);
            self.gpa.free(t.name);
            self.gpa.destroy(t);
        }
    }

    // -- the drain -------------------------------------------------------

    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const self: *Topics = @alignCast(@fieldParentPtr("drain_hook", hook));
        self.draining.store(true, .release);
        placement.concurrent(&self.ends, self.io, .{ .executor = 0 }, drainTask, .{self}) catch {};
    }

    /// Starts the drain by hand (tests, and the C ABI's own drain).
    pub fn _drainNow(self: *Topics) void {
        self.draining.store(true, .release);
        self.drainAll();
    }

    fn drainTask(self: *Topics) std.Io.Cancelable!void {
        self.drainAll();
    }

    /// Every subscriber gets a `retry:` from the spread and then its stream
    /// ends, after what is queued (S12).
    fn drainAll(self: *Topics) void {
        const io = self.io;
        var started: std.ArrayList(*Subscriber) = .empty;
        defer started.deinit(self.gpa);
        self.mutex.lockUncancelable(io);
        for (self.execs) |*list| {
            var node = list.subscribers.first;
            while (node) |nd| : (node = nd.next) {
                const sub: *Subscriber = @alignCast(@fieldParentPtr("exec_node", nd));
                if (sub.ending or sub.left or sub.broken) continue;
                self.queueDrainEnd(sub) catch continue;
                if (!sub.running and sub.armed) {
                    sub.running = true;
                    started.append(self.gpa, sub) catch {
                        sub.running = false;
                    };
                }
            }
        }
        self.mutex.unlock(io);
        for (started.items) |sub| self.startSender(io, sub);
    }
};

pub const ServeOptions = struct {
    topics: []const []const u8 = &.{},
    /// Without `Last-Event-ID`: the newest `last` events of each topic first
    /// (merged by sequence). 0: none.
    last: u16 = 0,
    /// Extra response headers (Set-Cookie...), copied before the head goes out.
    headers: []const [2][]const u8 = &.{},
    context: ?*anyopaque = null,
    /// Right after the head is out, before replay: keep the pointer to
    /// join, leave, send or close later. On the request's executor.
    on_open: ?*const fn (sub: *Subscriber) void = null,
    /// Once, when the subscriber ends; the pointer is invalid after it
    /// returns. Must not wait. On the subscriber's executor.
    on_close: ?*const fn (sub: *Subscriber, reason: CloseReason) void = null,
    /// The registry whose drain this hub follows when the request has none
    /// (the C ABI's own).
    on_drain_hooks: ?*dusty.DrainHooks = null,
};

/// One subscriber's stream. Valid from `on_open` until `on_close` returns;
/// its methods are safe from any task of the runtime.
pub const Subscriber = struct {
    context: ?*anyopaque,
    hub: *Topics,
    on_close: ?*const fn (sub: *Subscriber, reason: CloseReason) void,
    version: HttpVersion,
    executor: ?usize,
    /// Spreads the drain's retry over the range.
    index: u32,
    out: Out = undefined,
    has_out: bool = false,
    queue: std.ArrayList(*Payload) = .empty,
    head: usize = 0,
    queued_bytes: usize = 0,
    /// A sender is started or running; it alone takes from the queue.
    running: bool = false,
    /// The head is out and the first sender may start.
    armed: bool = false,
    /// The end is queued (slow, drain, `close`): it takes no more events.
    ending: bool = false,
    broken: bool = false,
    left: bool = false,
    over: bool = false,
    linked: bool = false,
    fallback: bool = false,
    draining_at_start: bool = false,
    abort_requested: bool = false,
    /// The peer is gone (set from the engine's callback).
    gone: std.atomic.Value(bool) = .init(false),
    end_started: std.atomic.Value(bool) = .init(false),
    close_reason: CloseReason = .client_gone,
    sending_since_ms: ?i64 = null,
    last_write_ms: i64,
    memberships: std.ArrayList(*Topics.Topic) = .empty,
    exec_node: std.DoublyLinkedList.Node = .{},
    sender: std.Io.Group = .init,
    task: ?placement.Task = null,
    wake: std.Io.Event = .unset,

    pub const JoinOptions = struct { last: u16 = 0 };

    fn execIndex(sub: *const Subscriber, hub: *const Topics) usize {
        const e = sub.executor orelse return 0;
        return if (hub.execs.len == 0) 0 else e % hub.execs.len;
    }

    fn pop(sub: *Subscriber) ?*Payload {
        if (sub.head == sub.queue.items.len) return null;
        const p = sub.queue.items[sub.head];
        sub.head += 1;
        sub.queued_bytes -= p.cost();
        if (sub.head == sub.queue.items.len) {
            sub.queue.clearRetainingCapacity();
            sub.head = 0;
        } else if (sub.head >= 64 and sub.head * 2 >= sub.queue.items.len) {
            const rest = sub.queue.items[sub.head..];
            std.mem.copyForwards(*Payload, sub.queue.items[0..rest.len], rest);
            sub.queue.items.len = rest.len;
            sub.head = 0;
        }
        return p;
    }

    fn dropQueue(sub: *Subscriber, gpa: std.mem.Allocator) void {
        for (sub.queue.items[sub.head..]) |p| p.release(gpa);
        sub.queue.clearRetainingCapacity();
        sub.head = 0;
        sub.queued_bytes = 0;
    }

    /// Joins `topic`; events published after this returns reach the stream.
    pub fn join(sub: *Subscriber, topic: []const u8, opts: JoinOptions) JoinError!void {
        const hub = sub.hub;
        const io = hub.io;
        if (!validTopic(topic)) return error.InvalidTopic;
        var start = false;
        {
            hub.mutex.lockUncancelable(io);
            defer hub.mutex.unlock(io);
            if (sub.left or sub.ending or sub.broken) return error.Closed;
            hub.joinLocked(sub, topic) catch |err| return err;
            if (opts.last > 0) {
                hub.queueReplayLocked(sub, null, opts.last) catch return error.OutOfMemory;
                if (!sub.running and sub.armed and sub.head < sub.queue.items.len) {
                    sub.running = true;
                    start = true;
                }
            }
        }
        if (start) hub.startSender(io, sub);
    }

    /// Leaves `topic`: events published after this returns do not reach
    /// the stream (those already queued still go out).
    pub fn leave(sub: *Subscriber, topic: []const u8) void {
        const hub = sub.hub;
        const io = hub.io;
        hub.mutex.lockUncancelable(io);
        defer hub.mutex.unlock(io);
        var i: usize = 0;
        while (i < sub.memberships.items.len) : (i += 1) {
            const t = sub.memberships.items[i];
            if (!std.mem.eql(u8, t.name, topic)) continue;
            _ = sub.memberships.swapRemove(i);
            for (t.members.items, 0..) |m, j| if (m == sub) {
                _ = t.members.swapRemove(j);
                break;
            };
            if (t.members.items.len == 0) t.empty_since_ms = hub.nowMs();
            break;
        }
    }

    /// One event to this subscriber only: no id, never replayed. `error.Full`
    /// past `max_queued_bytes` (nothing queued; S11).
    pub fn send(sub: *Subscriber, ev: Event) SendError!void {
        const hub = sub.hub;
        const p = hub._encode(ev) catch |err| return switch (err) {
            error.InvalidEventField => error.InvalidEventField,
            else => error.OutOfMemory,
        };
        defer p.release(hub.gpa);
        return sub._sendPayload(p);
    }

    /// `send` for a payload already encoded (`Topics._encode`; the caller
    /// keeps its reference).
    pub fn _sendPayload(sub: *Subscriber, p: *Payload) SendError!void {
        const hub = sub.hub;
        const io = hub.io;
        var launch = false;
        {
            hub.mutex.lockUncancelable(io);
            defer hub.mutex.unlock(io);
            if (sub.left or sub.ending or sub.broken or sub.gone.load(.acquire)) return error.Closed;
            if (sub.queued_bytes > 0 and sub.queued_bytes + p.cost() > hub.options.max_queued_bytes) return error.Full;
            sub.queue.append(hub.gpa, p) catch return error.OutOfMemory;
            p.retain();
            sub.queued_bytes += p.cost();
            if (!sub.running and sub.armed) {
                sub.running = true;
                launch = true;
            }
        }
        if (launch) hub.startSender(io, sub);
    }

    /// Bytes queued for this subscriber (the C ABI's accounting).
    pub fn queuedBytes(sub: *Subscriber) usize {
        const hub = sub.hub;
        hub.mutex.lockUncancelable(hub.io);
        defer hub.mutex.unlock(hub.io);
        return sub.queued_bytes;
    }

    /// Ends the stream after what is queued (`on_close` reason `.closed`).
    pub fn close(sub: *Subscriber) void {
        const hub = sub.hub;
        const io = hub.io;
        var start = false;
        {
            hub.mutex.lockUncancelable(io);
            defer hub.mutex.unlock(io);
            if (sub.ending or sub.left) return;
            hub.beginClose(sub, .closed, false);
            if (!sub.running and sub.armed) {
                sub.running = true;
                start = true;
            }
        }
        if (start) hub.startSender(io, sub);
    }

    pub fn httpVersion(sub: *const Subscriber) HttpVersion {
        return sub.version;
    }
};

/// Route options for `app.sse`.
pub const RouteOptions = struct {
    /// `{name}` is replaced by the route parameter `name` (percent-decoded).
    topics: []const []const u8,
    last: u16 = 0,
};

/// What an `app.sse` route keeps: the hub it serves.
pub const RouteData = struct {
    topics: *Topics,
};

/// The handler body of an `app.sse` route: the topics of `options` with
/// `{name}` replaced by the route's parameters, served from the hub the
/// route was registered with.
pub fn serveRoute(req: *dusty.Request, res: *dusty.Response, comptime options: RouteOptions) !void {
    const info = req.route orelse return error.NotFound;
    const data: *const RouteData = @ptrCast(@alignCast(info.data orelse return error.NotFound));
    var topics: [options.topics.len][]const u8 = undefined;
    inline for (options.topics, 0..) |tmpl, i| topics[i] = try renderTopic(req, tmpl);
    return data.topics.serve(req, res, .{ .topics = &topics, .last = options.last });
}

/// `tmpl` with each `{name}` replaced by the route parameter `name`, in the
/// request's arena.
pub fn renderTopic(req: *dusty.Request, tmpl: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, tmpl, '{') == null) return tmpl;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            const close_at = std.mem.indexOfScalarPos(u8, tmpl, i, '}') orelse return error.InvalidTopic;
            const name = tmpl[i + 1 .. close_at];
            const value = (try req.paramDecoded(name)) orelse return error.InvalidTopic;
            try out.appendSlice(req.arena, value);
            i = close_at + 1;
        } else {
            try out.append(req.arena, tmpl[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Whether every `{name}` of the topic templates names a parameter of
/// `path` (comptime, for `app.sse`).
pub fn templatesMatch(path: []const u8, options: RouteOptions) bool {
    for (options.topics) |tmpl| {
        var i: usize = 0;
        while (i < tmpl.len) : (i += 1) {
            if (tmpl[i] != '{') continue;
            const close_at = std.mem.indexOfScalarPos(u8, tmpl, i, '}') orelse return false;
            const name = tmpl[i + 1 .. close_at];
            if (!pathHasParam(path, name)) return false;
            i = close_at;
        }
    }
    return true;
}

fn pathHasParam(path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len > 1 and (seg[0] == ':' or seg[0] == '*') and std.mem.eql(u8, seg[1..], name)) return true;
    }
    return false;
}

test {
    _ = replay;
    _ = @import("topics_test.zig");
    _ = @import("serve_test.zig");
}
