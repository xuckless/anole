//! JetStream, scoped: publish with ack (`Nats-Msg-Id` dedup, expected
//! stream / last sequence), stream and durable pull-consumer "ensure"
//! (create, or update when the configuration differs), and pull
//! consumption with credit and explicit ack, nak (with delay), term and
//! in-progress. Key-value and the object store are later.
//!
//! The API is JSON requests on `$JS.API.*` and acks are publishes to the
//! reply subject of each delivered message, over the core client.
const std = @import("std");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const resilience = @import("../resilience/root.zig");
const nats = @import("root.zig");

const Client = nats.Client;
const Msg = nats.Msg;
const Error = nats.Error;
const Duration = std.Io.Duration;
const Header = nats.Header;
const placement = dusty.placement;
const log = std.log.scoped(.nats);

pub const Options = struct {
    /// The JetStream domain; null: the account's.
    domain: ?[]const u8 = null,
    /// Created or updated when serving starts (before the listeners).
    streams: []const StreamConfig = &.{},
    consumers: []const ConsumerConfig = &.{},
};

pub const StreamConfig = struct {
    name: []const u8,
    subjects: []const []const u8,
    retention: enum { limits, interest, workqueue } = .limits,
    storage: enum { file, memory } = .file,
    replicas: u8 = 1,
    max_age: ?Duration = null,
    max_bytes: ?i64 = null,
    max_msgs: ?i64 = null,
    /// null: the server's (2 min).
    duplicate_window: ?Duration = null,
    /// A JSON object merged over the fields above (anything else the server takes).
    extra_json: ?[]const u8 = null,
};

pub const ConsumerConfig = struct {
    stream: []const u8,
    durable: []const u8,
    filter_subjects: []const []const u8 = &.{},
    deliver_policy: enum { all, last, new, last_per_subject } = .all,
    ack_wait: Duration = .fromSeconds(30),
    max_deliver: i32 = -1,
    max_ack_pending: i32 = 1000,
    /// Redelivery delays after NAKs without a delay of their own.
    backoff: []const Duration = &.{},
    extra_json: ?[]const u8 = null,
};

pub const PublishOptions = struct {
    msg_id: ?[]const u8 = null,
    expected_stream: ?[]const u8 = null,
    expected_last_sequence: ?u64 = null,
    headers: []const Header = &.{},
    timeout: ?Duration = null,
};

pub const PubAck = struct { stream: []const u8, sequence: u64, duplicate: bool };

pub const ConsumeOptions = struct {
    /// Messages fetched and not yet acked, at most (the fetch batch).
    max_inflight: u32 = 64,
    /// How long one pull waits on the server.
    expires: Duration = .fromSeconds(30),
    /// A failed handler's NAK delay, by delivery count.
    nak_backoff: resilience.Backoff = .{ .base = .fromSeconds(1), .max = .fromSeconds(60) },
    /// A bound per message; null: none.
    timeout: ?Duration = .fromSeconds(30),
};

/// A JetStream message: a `Msg` plus metadata and acks. The handler's
/// return acks it (+ACK); an error NAKs it with `nak_backoff.delay(delivered)`;
/// `term()` ends redelivery; `inProgress()` extends ack_wait. Acks are
/// publishes: they never wait.
pub const JsMsg = struct {
    msg: Msg,
    stream: []const u8,
    consumer: []const u8,
    stream_seq: u64,
    consumer_seq: u64,
    delivered: u64,
    pending: u64,
    timestamp_ns: i64,
    acked: bool = false,

    fn send(self: *JsMsg, payload: []const u8) Error!void {
        const to = self.msg.reply_to orelse return error.BadRequest;
        return self.msg.client.publishMsg(&self.msg, .{ .subject = to, .payload = payload });
    }

    pub fn ack(self: *JsMsg) Error!void {
        if (self.acked) return;
        try self.send("+ACK");
        self.acked = true;
    }

    pub fn nak(self: *JsMsg, delay: ?Duration) Error!void {
        if (self.acked) return;
        if (delay) |d| {
            const text = std.fmt.allocPrint(self.msg.arena, "-NAK {{\"delay\":{d}}}", .{d.nanoseconds}) catch return error.OutOfMemory;
            try self.send(text);
        } else try self.send("-NAK");
        self.acked = true;
    }

    pub fn term(self: *JsMsg) Error!void {
        if (self.acked) return;
        try self.send("+TERM");
        self.acked = true;
    }

    pub fn inProgress(self: *JsMsg) Error!void {
        if (self.acked) return;
        try self.send("+WPI");
    }
};

pub const JetStream = struct {
    client: *Client,

    /// Publish and wait for the stream's ack. `msg_id` sets Nats-Msg-Id
    /// (deduplicated within the stream's duplicate window).
    pub fn publish(self: JetStream, c: anytype, subject: []const u8, payload: []const u8, opts: PublishOptions) Error!PubAck {
        const a = c.arena;
        var headers: std.ArrayList(Header) = .empty;
        headers.appendSlice(a, opts.headers) catch return error.OutOfMemory;
        if (opts.msg_id) |id| headers.append(a, .{ "Nats-Msg-Id", id }) catch return error.OutOfMemory;
        if (opts.expected_stream) |s| headers.append(a, .{ "Nats-Expected-Stream", s }) catch return error.OutOfMemory;
        if (opts.expected_last_sequence) |n| headers.append(a, .{ "Nats-Expected-Last-Sequence", std.fmt.allocPrint(a, "{d}", .{n}) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        const reply = try self.client.with(.{ .timeout = opts.timeout }).requestMsg(c, .{ .subject = subject, .headers = headers.items, .payload = payload });
        const Ack = struct { stream: ?[]const u8 = null, seq: ?u64 = null, duplicate: ?bool = null, @"error": ?ApiError = null };
        const parsed = reply.json(Ack, a) catch return self.protocolError(c, "unreadable publish ack");
        if (parsed.@"error") |e| return self.apiFail(c, e);
        return .{ .stream = parsed.stream orelse "", .sequence = parsed.seq orelse 0, .duplicate = parsed.duplicate orelse false };
    }

    pub fn ensureStream(self: JetStream, c: anytype, config: StreamConfig) Error!void {
        const a = c.arena;
        const body = streamJson(a, config) catch return error.OutOfMemory;
        const create = try self.api(c, "STREAM.CREATE", config.name, body);
        const err = create orelse return;
        // 10058: the stream exists with another configuration.
        if (err.err_code != 10058) return self.apiFail(c, err);
        const update = try self.api(c, "STREAM.UPDATE", config.name, body);
        if (update) |e| return self.apiFail(c, e);
    }

    pub fn ensureConsumer(self: JetStream, c: anytype, config: ConsumerConfig) Error!void {
        const a = c.arena;
        const body = consumerJson(a, config) catch return error.OutOfMemory;
        const subject = std.fmt.allocPrint(a, "{s}.CONSUMER.CREATE.{s}.{s}", .{ self.prefix(a) catch return error.OutOfMemory, config.stream, config.durable }) catch return error.OutOfMemory;
        const r = try self.call(c, subject, body);
        if (r) |e| return self.apiFail(c, e);
    }

    /// Streams and consumers of `options`, in that order.
    pub fn ensureAll(self: JetStream, c: anytype, options: Options) Error!void {
        for (options.streams) |s| try self.ensureStream(c, s);
        for (options.consumers) |k| try self.ensureConsumer(c, k);
    }

    /// Pull-consumes `consumer` of `stream` with `handler` from serving
    /// start: `fn (*JsMsg) !void` or `fn (*App, *JsMsg) !void`.
    pub fn consume(self: JetStream, server: anytype, stream: []const u8, consumer: []const u8, opts: ConsumeOptions, comptime handler: anytype) !void {
        const Info = @typeInfo(@TypeOf(handler)).@"fn";
        const with_state = Info.params.len == 2;
        const state: ?*anyopaque = if (with_state) @ptrCast(server.server.ctx) else null;
        const Tramp = struct {
            fn run(ctx: ?*anyopaque, m: *JsMsg) anyerror!void {
                if (with_state) {
                    const P = Info.params[0].type.?;
                    return handler(@as(P, @ptrCast(@alignCast(ctx.?))), m);
                }
                return handler(m);
            }
        };
        const cl = self.client;
        const a = cl.arena.allocator();
        const p = try cl.gpa.create(Puller);
        errdefer cl.gpa.destroy(p);
        p.* = .{
            .client = cl,
            .stream = try a.dupe(u8, stream),
            .consumer = try a.dupe(u8, consumer),
            .opts = opts,
            .state = state,
            .run = Tramp.run,
            .domain = cl.js_options.domain,
        };
        try cl.addHook(.{ .context = p, .begin = Puller.begin, .free = Puller.free });
    }

    /// Starts a pull consumer at once (the client has started) whose
    /// messages go to `run(state, msg)`; stop it with `Puller.stop`. For the
    /// C ABI, which runs the handler as "post the message, wait for the
    /// consumer's ack".
    pub fn consumeRaw(self: JetStream, stream: []const u8, consumer: []const u8, opts: ConsumeOptions, state: ?*anyopaque, run: *const fn (?*anyopaque, *JsMsg) anyerror!void) !*Puller {
        const cl = self.client;
        const p = try cl.gpa.create(Puller);
        errdefer cl.gpa.destroy(p);
        p.* = .{
            .client = cl,
            .stream = try cl.gpa.dupe(u8, stream),
            .consumer = try cl.gpa.dupe(u8, consumer),
            .opts = opts,
            .state = state,
            .run = run,
            .domain = cl.js_options.domain,
            .standalone = true,
        };
        errdefer cl.gpa.free(p.stream);
        errdefer cl.gpa.free(p.consumer);
        try Puller.begin(p);
        return p;
    }

    // -- API plumbing ------------------------------------------------------

    fn prefix(self: JetStream, a: std.mem.Allocator) ![]const u8 {
        if (self.client.js_options.domain) |d| return std.fmt.allocPrint(a, "$JS.{s}.API", .{d});
        return "$JS.API";
    }

    fn api(self: JetStream, c: anytype, verb: []const u8, name: []const u8, body: []const u8) Error!?ApiError {
        const subject = std.fmt.allocPrint(c.arena, "{s}.{s}.{s}", .{ self.prefix(c.arena) catch return error.OutOfMemory, verb, name }) catch return error.OutOfMemory;
        return self.call(c, subject, body);
    }

    /// An API request; the error object of the answer, or null.
    fn call(self: JetStream, c: anytype, subject: []const u8, body: []const u8) Error!?ApiError {
        const reply = try self.client.request(c, subject, body);
        const Answer = struct { @"error": ?ApiError = null };
        const parsed = reply.json(Answer, c.arena) catch return self.protocolError(c, "unreadable JetStream answer");
        return parsed.@"error";
    }

    fn protocolError(self: JetStream, c: anytype, what: []const u8) Error {
        return internal.fail(c, self.client.errors, .{ .system = .nats, .class = .other, .code = "protocol", .message = what });
    }

    fn apiFail(self: JetStream, c: anytype, e: ApiError) Error {
        const class: db.Class = switch (e.code) {
            503 => .unavailable,
            408 => .timeout,
            else => .other,
        };
        const code = std.fmt.allocPrint(c.arena, "{d}", .{e.err_code}) catch "";
        return internal.fail(c, self.client.errors, .{ .system = .nats, .class = class, .code = code, .message = e.description });
    }
};

/// The `error` object of a JetStream API answer.
const ApiError = struct {
    code: u32 = 0,
    err_code: u32 = 0,
    description: []const u8 = "",
};

// ---------------------------------------------------------------------------
// JSON

fn nanos(d: Duration) i64 {
    return @intCast(@min(d.nanoseconds, std.math.maxInt(i64)));
}

fn streamJson(a: std.mem.Allocator, s: StreamConfig) ![]const u8 {
    const Wire = struct {
        name: []const u8,
        subjects: []const []const u8,
        retention: []const u8,
        storage: []const u8,
        num_replicas: u8,
        max_age: ?i64,
        max_bytes: ?i64,
        max_msgs: ?i64,
        duplicate_window: ?i64,
    };
    const base = try std.json.Stringify.valueAlloc(a, Wire{
        .name = s.name,
        .subjects = s.subjects,
        .retention = @tagName(s.retention),
        .storage = @tagName(s.storage),
        .num_replicas = s.replicas,
        .max_age = if (s.max_age) |d| nanos(d) else null,
        .max_bytes = s.max_bytes,
        .max_msgs = s.max_msgs,
        .duplicate_window = if (s.duplicate_window) |d| nanos(d) else null,
    }, .{ .emit_null_optional_fields = false });
    return mergeJson(a, base, s.extra_json);
}

fn consumerJson(a: std.mem.Allocator, k: ConsumerConfig) ![]const u8 {
    const policy: []const u8 = switch (k.deliver_policy) {
        .all => "all",
        .last => "last",
        .new => "new",
        .last_per_subject => "last_per_subject",
    };
    const backoff = try a.alloc(i64, k.backoff.len);
    for (k.backoff, backoff) |d, *o| o.* = nanos(d);
    const Config = struct {
        durable_name: []const u8,
        ack_policy: []const u8 = "explicit",
        deliver_policy: []const u8,
        ack_wait: i64,
        max_deliver: i32,
        max_ack_pending: i32,
        filter_subjects: ?[]const []const u8,
        backoff: ?[]const i64,
    };
    const Wire = struct { stream_name: []const u8, config: Config, action: []const u8 = "" };
    const base = try std.json.Stringify.valueAlloc(a, Wire{
        .stream_name = k.stream,
        .config = .{
            .durable_name = k.durable,
            .deliver_policy = policy,
            .ack_wait = nanos(k.ack_wait),
            .max_deliver = k.max_deliver,
            .max_ack_pending = k.max_ack_pending,
            .filter_subjects = if (k.filter_subjects.len > 0) k.filter_subjects else null,
            .backoff = if (backoff.len > 0) backoff else null,
        },
    }, .{ .emit_null_optional_fields = false });
    if (k.extra_json == null) return base;
    // The extra keys go into "config".
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, base, .{});
    const cfg = parsed.object.getPtr("config").?;
    const merged = try mergeJson(a, try std.json.Stringify.valueAlloc(a, cfg.*, .{}), k.extra_json);
    cfg.* = try std.json.parseFromSliceLeaky(std.json.Value, a, merged, .{});
    return std.json.Stringify.valueAlloc(a, parsed, .{});
}

/// `base` (a JSON object) with the keys of `extra` laid over it.
fn mergeJson(a: std.mem.Allocator, base: []const u8, extra: ?[]const u8) ![]const u8 {
    const text = extra orelse return base;
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a, base, .{});
    const over = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    if (over != .object or root != .object) return error.InvalidOptions;
    var it = over.object.iterator();
    while (it.next()) |e| try root.object.put(a, e.key_ptr.*, e.value_ptr.*);
    return std.json.Stringify.valueAlloc(a, root, .{});
}

// ---------------------------------------------------------------------------
// Ack subjects

pub const AckInfo = struct {
    stream: []const u8,
    consumer: []const u8,
    delivered: u64,
    stream_seq: u64,
    consumer_seq: u64,
    timestamp_ns: i64,
    pending: u64,
};

/// `$JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<ts>.<pending>`
/// (9 tokens), or the form with a domain and an account hash before the
/// stream and a random token at the end (12 tokens). Read from the end.
pub fn parseAckSubject(subject: []const u8) ?AckInfo {
    var tokens: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, subject, '.');
    while (it.next()) |t| {
        if (n == tokens.len) return null;
        tokens[n] = t;
        n += 1;
    }
    if (n < 9 or !std.mem.eql(u8, tokens[0], "$JS") or !std.mem.eql(u8, tokens[1], "ACK")) return null;
    // The last token of a v2 subject is random: the metadata ends before it.
    const end: usize = if (n >= 11) n - 1 else n;
    if (end < 9) return null;
    const p = std.fmt.parseInt(u64, tokens[end - 1], 10) catch return null;
    const ts = std.fmt.parseInt(i64, tokens[end - 2], 10) catch return null;
    const cseq = std.fmt.parseInt(u64, tokens[end - 3], 10) catch return null;
    const sseq = std.fmt.parseInt(u64, tokens[end - 4], 10) catch return null;
    const delivered = std.fmt.parseInt(u64, tokens[end - 5], 10) catch return null;
    return .{ .stream = tokens[end - 7], .consumer = tokens[end - 6], .delivered = delivered, .stream_seq = sseq, .consumer_seq = cseq, .timestamp_ns = ts, .pending = p };
}

// ---------------------------------------------------------------------------
// Pull consumption

pub const Puller = struct {
    client: *Client,
    stream: []const u8,
    consumer: []const u8,
    opts: ConsumeOptions,
    state: ?*anyopaque,
    run: *const fn (?*anyopaque, *JsMsg) anyerror!void,
    domain: ?[]const u8,
    inflight: std.atomic.Value(u32) = .init(0),
    rr: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),
    /// Made by `consumeRaw`: owns its strings, ends itself.
    standalone: bool = false,

    /// Ends the pulling; messages already delivered finish.
    pub fn stop(p: *Puller) void {
        p.stopped.store(true, .release);
    }

    fn begin(context: *anyopaque) anyerror!void {
        const p: *Puller = @ptrCast(@alignCast(context));
        try placement.concurrent(&p.client.group, p.client.io, .{ .executor = 0 }, pull, .{p});
    }

    fn free(context: *anyopaque) void {
        const p: *Puller = @ptrCast(@alignCast(context));
        if (p.standalone) {
            p.client.gpa.free(p.stream);
            p.client.gpa.free(p.consumer);
        }
        p.client.gpa.destroy(p);
    }

    fn pull(p: *Puller) std.Io.Cancelable!void {
        const cl = p.client;
        const io = cl.io;
        const k = &cl.cores[0];
        var inbox_buf: [48]u8 = undefined;
        var rb: [8]u8 = undefined;
        io.random(&rb);
        const inbox = std.fmt.bufPrint(&inbox_buf, "_INBOX.js.{x}", .{std.mem.readInt(u64, &rb, .little)}) catch return;
        const sub = k.subscribe(inbox, .{}) catch |err| {
            log.err("nats \"{s}\": JetStream consumer {s}/{s}: cannot subscribe ({t})", .{ cl.label, p.stream, p.consumer, err });
            return;
        };
        defer sub.deinit();
        var subject_buf: [256]u8 = undefined;
        const prefix = if (p.domain) |d| std.fmt.bufPrint(subject_buf[0..64], "$JS.{s}.API", .{d}) catch "$JS.API" else "$JS.API";
        var pull_subject_buf: [320]u8 = undefined;
        const pull_subject = std.fmt.bufPrint(&pull_subject_buf, "{s}.CONSUMER.MSG.NEXT.{s}.{s}", .{ prefix, p.stream, p.consumer }) catch return;
        var requested: u32 = 0;
        var pulled_at: std.Io.Clock.Timestamp = .now(io, .awake);
        const max = @max(1, p.opts.max_inflight);
        while (true) {
            if (p.stopped.load(.acquire)) return;
            const inflight = p.inflight.load(.acquire);
            const want = max -| inflight -| requested;
            if (requested == 0 and want >= @max(1, max / 2)) {
                var body: [96]u8 = undefined;
                const text = std.fmt.bufPrint(&body, "{{\"batch\":{d},\"expires\":{d}}}", .{ want, @max(1, p.opts.expires.nanoseconds - 1_000_000_000) }) catch return;
                if (k.publishNow(.{ .subject = pull_subject, .reply_to = inbox, .payload = text })) |_| {
                    requested = want;
                    pulled_at = .now(io, .awake);
                } else |_| {}
            }
            const wait: Duration = if (requested == 0) .fromMilliseconds(100) else .{ .nanoseconds = @min(p.opts.expires.nanoseconds, std.time.ns_per_s) };
            const got = sub.next(.{ .timeout = .{ .duration = .{ .raw = wait, .clock = .awake } } }) catch |err| switch (err) {
                error.Timeout => {
                    // The pull ends at `expires` on the server's side.
                    if (requested != 0 and pulled_at.durationTo(.now(io, .awake)).raw.nanoseconds > p.opts.expires.nanoseconds) requested = 0;
                    continue;
                },
                error.Canceled => return error.Canceled,
                else => return,
            };
            var m = got orelse return;
            if (m.headers.status()) |status| {
                m.deinit();
                switch (status) {
                    100 => {},
                    404, 408 => requested = 0,
                    409 => {
                        log.warn("nats \"{s}\": JetStream consumer {s}/{s}: {s}", .{ cl.label, p.stream, p.consumer, "pull refused (409)" });
                        requested = 0;
                    },
                    else => requested = 0,
                }
                continue;
            }
            requested -|= 1;
            _ = p.inflight.fetchAdd(1, .acq_rel);
            const worker = p.rr.fetchAdd(1, .monotonic);
            placement.concurrent(&cl.group, io, .{ .executor = worker }, deliver, .{ p, m }) catch {
                m.deinit();
                _ = p.inflight.fetchSub(1, .acq_rel);
            };
        }
    }

    fn deliver(p: *Puller, m0: nats.core.Message) std.Io.Cancelable!void {
        var m = m0;
        defer m.deinit();
        const cl = p.client;
        defer _ = p.inflight.fetchSub(1, .acq_rel);
        var arena: std.heap.ArenaAllocator = .init(cl.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const reply = m.reply_to orelse return;
        const info = parseAckSubject(reply) orelse {
            log.warn("nats \"{s}\": JetStream message with an unreadable ack subject {s}", .{ cl.label, reply });
            return;
        };
        var headers: std.ArrayList(Header) = .empty;
        var it = m.headers.iterator();
        while (it.next()) |hd| headers.append(a, .{ hd.name, hd.value }) catch {};
        var jm: JsMsg = .{
            .msg = .{
                .io = cl.io,
                .arena = a,
                .id = "js",
                .subject = m.subject,
                .reply_to = reply,
                .headers = headers.items,
                .payload = m.payload,
                .client = cl,
            },
            .stream = info.stream,
            .consumer = info.consumer,
            .stream_seq = info.stream_seq,
            .consumer_seq = info.consumer_seq,
            .delivered = info.delivered,
            .pending = info.pending,
            .timestamp_ns = info.timestamp_ns,
        };
        const result: anyerror!void = if (internal.callTimeout(p.opts.timeout, null)) |t| blk: {
            const d: dusty.Deadline = .init(cl.io, .{ .duration = .{ .raw = t, .clock = .awake } });
            break :blk d.run(invoke, .{ p, &jm }) catch |e| e;
        } else invoke(p, &jm);
        if (result) |_| {
            jm.ack() catch |err| log.warn("nats: acking {s} failed: {t}", .{ reply, err });
        } else |err| {
            if (err == error.Canceled) return error.Canceled;
            log.warn("JetStream handler for {s}/{s} failed: {t}", .{ p.stream, p.consumer, err });
            const delay = p.opts.nak_backoff.delay(@intCast(@min(info.delivered, std.math.maxInt(u32))), blk: {
                var rb: [8]u8 = undefined;
                cl.io.random(&rb);
                break :blk std.mem.readInt(u64, &rb, .little);
            });
            jm.nak(delay) catch {};
        }
    }

    fn invoke(p: *Puller, jm: *JsMsg) anyerror!void {
        return p.run(p.state, jm);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "jetstream: ack reply subject v1 and v2 forms parse" {
    const v1 = parseAckSubject("$JS.ACK.ORDERS.billing.2.17.5.1700000000000000000.9").?;
    try testing.expectEqualStrings("ORDERS", v1.stream);
    try testing.expectEqualStrings("billing", v1.consumer);
    try testing.expectEqual(@as(u64, 2), v1.delivered);
    try testing.expectEqual(@as(u64, 17), v1.stream_seq);
    try testing.expectEqual(@as(u64, 5), v1.consumer_seq);
    try testing.expectEqual(@as(u64, 9), v1.pending);
    const v2 = parseAckSubject("$JS.ACK.dom.ACCHASH.ORDERS.billing.1.3.4.1700000000000000001.0.rnd123").?;
    try testing.expectEqualStrings("ORDERS", v2.stream);
    try testing.expectEqualStrings("billing", v2.consumer);
    try testing.expectEqual(@as(u64, 3), v2.stream_seq);
    try testing.expect(parseAckSubject("$JS.ACK.short") == null);
    try testing.expect(parseAckSubject("foo.bar.baz") == null);
    try testing.expect(parseAckSubject("$JS.ACK.S.C.x.1.1.1.1") == null);
}

test "jetstream: stream and consumer JSON, with extra keys merged" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = try streamJson(a, .{ .name = "ORDERS", .subjects = &.{"orders.>"}, .max_age = .fromSeconds(60), .extra_json = "{\"description\":\"d\"}" });
    try testing.expect(std.mem.indexOf(u8, s, "\"name\":\"ORDERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"max_age\":60000000000") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"description\":\"d\"") != null);
    const k = try consumerJson(a, .{ .stream = "ORDERS", .durable = "billing", .backoff = &.{.fromSeconds(1)}, .extra_json = "{\"inactive_threshold\":1000}" });
    try testing.expect(std.mem.indexOf(u8, k, "\"durable_name\":\"billing\"") != null);
    try testing.expect(std.mem.indexOf(u8, k, "\"inactive_threshold\":1000") != null);
    try testing.expect(std.mem.indexOf(u8, k, "\"stream_name\":\"ORDERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, k, "\"backoff\":[1000000000]") != null);
}
