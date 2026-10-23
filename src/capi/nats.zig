//! `anole_nats_*`: the configuration's NATS brokers, used without blocking
//! the caller. A publish copies the message into the client's outbound
//! queue on the calling thread and returns (it never waits). Requests,
//! JetStream publishes, subscriptions and JetStream consumes become
//! commands for one of the consumer's executors, whose tasks run them on
//! the `anole.nats` client and queue what comes back as records on the ring
//! that feeds the consumer: `ANOLE_EV_NATS_REPLY`, `ANOLE_EV_NATS_MSG`,
//! `ANOLE_EV_NATS_JS_MSG` and `ANOLE_EV_NATS_SUB_END`.
//!
//! Back-pressure is the protocol's own: a subscription's delivery task
//! waits for room in the consumer's ring (its own queue applies its
//! overflow policy meanwhile); a JetStream consume asks the server for more
//! only while fewer than `max_inflight` messages are unacked.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const db_cap = @import("db.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;
const db = anole.db;

const nats = if (features.nats) anole.nats else struct {
    pub const Client = void;
    pub const JsMsg = void;
};
const Puller = if (features.nats) anole.nats.jetstream.Puller else void;

const log = std.log.scoped(.anole);
const ms = std.Io.Duration.fromMilliseconds;

/// One configured broker (`anole_nats *` in C).
pub const Broker = struct {
    engine: *Engine,
    config: config_mod.Config.Broker,
    index: u32,
    client: ?*nats.Client = null,
    open: std.atomic.Value(bool) = .init(false),
    wants: Wants = .{},
};

/// Consumers whose publish was refused or advised against: told when the
/// queue has room.
const Wants = struct {
    lock: std.atomic.Mutex = .unlocked,
    list: [32]?*Consumer = @splat(null),
    running: std.atomic.Value(bool) = .init(false),

    fn acquire(w: *Wants) void {
        while (!w.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn add(w: *Wants, c: *Consumer) bool {
        w.acquire();
        defer w.lock.unlock();
        for (w.list) |e| if (e == c) return true;
        for (&w.list) |*e| if (e.* == null) {
            e.* = c;
            return true;
        };
        return false;
    }

    fn any(w: *Wants) bool {
        w.acquire();
        defer w.lock.unlock();
        for (w.list) |e| if (e != null) return true;
        return false;
    }

    fn take(w: *Wants, out: *[32]?*Consumer) void {
        w.acquire();
        defer w.lock.unlock();
        out.* = w.list;
        w.list = @splat(null);
    }
};

// ---------------------------------------------------------------------------
// Handles

fn Table(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { gen: u32, live: bool = false, value: T = undefined };

        lock: std.atomic.Mutex = .unlocked,
        entries: std.ArrayList(Entry) = .empty,
        free: std.ArrayList(u32) = .empty,
        first_gen: u32 = 1,

        pub fn acquire(t: *Self) void {
            while (!t.lock.tryLock()) std.atomic.spinLoopHint();
        }

        pub fn release(t: *Self) void {
            t.lock.unlock();
        }

        /// Under the lock.
        fn alloc(t: *Self, value: T) !struct { index: u32, gen: u32 } {
            if (t.free.pop()) |i| {
                const e = &t.entries.items[i];
                e.live = true;
                e.value = value;
                return .{ .index = i, .gen = e.gen };
            }
            if (t.entries.items.len >= (1 << 24)) return error.TooMany;
            try t.entries.append(gpa, .{ .gen = @max(1, t.first_gen), .live = true, .value = value });
            const i: u32 = @intCast(t.entries.items.len - 1);
            return .{ .index = i, .gen = t.entries.items[i].gen };
        }

        /// Under the lock: the live entry the handle names, or null.
        fn get(t: *Self, h: Handle) ?*Entry {
            if (h.slot >= t.entries.items.len) return null;
            const e = &t.entries.items[h.slot];
            return if (e.live and e.gen == h.gen) e else null;
        }

        /// Under the lock.
        fn drop(t: *Self, index: u32) void {
            const e = &t.entries.items[index];
            e.live = false;
            e.gen = engine.nextGen(e.gen);
            t.free.append(gpa, index) catch {};
        }

        fn maxGen(t: *Self) u32 {
            t.acquire();
            defer t.release();
            var max: u32 = 0;
            for (t.entries.items) |e| max = @max(max, e.gen);
            return max;
        }

        fn deinit(t: *Self) void {
            t.entries.deinit(gpa);
            t.free.deinit(gpa);
        }
    };
}

/// Engine-wide: subscription and message handles.
pub const State = struct {
    subs: Table(*SubRun) = .{},
    msgs: Table(*MsgWait) = .{},

    pub fn init(s: *State, first_gen: u32) void {
        s.subs.first_gen = first_gen;
        s.msgs.first_gen = first_gen;
    }

    pub fn maxGen(s: *State) u32 {
        return @max(s.subs.maxGen(), s.msgs.maxGen());
    }

    pub fn deinit(s: *State) void {
        s.subs.deinit();
        s.msgs.deinit();
    }
};

/// Per executor: the tasks of this executor's subscriptions, requests and
/// watchers, canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }

    pub fn deinit(_: *ExecState) void {}
};

fn handleOf(kind: Handle.Kind, index: u32, gen: u32, exec: u8) u64 {
    return Handle.encode(.{ .gen = @intCast(gen), .kind = kind, .slot = @intCast(index), .exec = exec });
}

// ---------------------------------------------------------------------------
// Opening

/// Opens every configured broker on `app` (from the server's main thread,
/// before the listeners open). They connect when serving starts.
pub fn open(e: *Engine, app: *anole.App) !void {
    for (e.brokers) |*b| {
        if (comptime !features.nats) unreachable;
        b.client = try app.nats(try natsOptions(e, b));
        b.open.store(true, .release);
    }
}

pub fn close(e: *Engine) void {
    for (e.brokers) |*b| b.open.store(false, .release);
}

pub fn find(e: *Engine, name: []const u8) ?*Broker {
    for (e.brokers) |*b| if (std.mem.eql(u8, b.config.name, name)) return b;
    return null;
}

fn optMs(n: u32) ?std.Io.Duration {
    return if (n > 0) ms(n) else null;
}

fn natsOptions(e: *Engine, b: *Broker) !anole.nats.Options {
    const a = e.arena.allocator();
    const c = b.config.nats.?;
    const Secret = anole.nats.Options.Auth.Secret;
    var o: anole.nats.Options = .{
        .url = c.url,
        .name = c.name,
        .label = b.config.name,
        .connections = if (std.mem.eql(u8, c.connections, "per_executor")) .per_executor else .one,
        .timeout = optMs(b.config.timeout_ms),
        .connect_timeout = ms(c.connect_timeout_ms),
        .connect_at_start = c.connect_at_start,
        .ping_interval = ms(c.ping_interval_ms),
        .max_outstanding_pings = c.max_outstanding_pings,
        .no_echo = c.no_echo,
        .reconnect = .{
            .enabled = c.reconnect.enabled,
            .max_attempts = c.reconnect.max_attempts,
            .min_delay = ms(c.reconnect.min_delay_ms),
            .max_delay = ms(c.reconnect.max_delay_ms),
            .jitter = c.reconnect.jitter,
            .buffer_bytes = std.math.cast(usize, c.reconnect.buffer_bytes) orelse std.math.maxInt(usize),
            .abort_on_auth_error = c.reconnect.abort_on_auth_error,
        },
        .limits = .{
            .outbound_bytes = std.math.cast(usize, c.limits.outbound_bytes) orelse std.math.maxInt(usize),
            .subscription_messages = c.limits.subscription_messages,
            .subscription_bytes = std.math.cast(usize, c.limits.subscription_bytes) orelse std.math.maxInt(usize),
            .max_pending_requests = c.limits.max_pending_requests,
            .max_subscriptions = c.limits.max_subscriptions,
            .max_control_line_bytes = c.limits.max_control_line_bytes,
            .max_inbound_frame_bytes = c.limits.max_inbound_frame_bytes,
            .max_header_bytes = c.limits.max_header_bytes,
            .max_event_queue = c.limits.max_event_queue,
        },
        .errors = b.config.errors,
        .retry = .{
            .attempts = b.config.retry.attempts,
            .backoff = .{ .base = ms(b.config.retry.base_ms), .max = ms(b.config.retry.max_ms), .multiplier = b.config.retry.multiplier },
            .attempt_timeout = optMs(b.config.retry.attempt_timeout_ms),
            .max_retry_after = ms(b.config.retry.max_retry_after_ms),
        },
        .tls = .{
            .ca = if (c.ca_file) |f| .{ .file = f } else if (c.ca_pem) |pem| .{ .pem = pem } else null,
            .client_certificate = if (c.client_cert_file) |f|
                dusty.Cert.fromFiles(f, c.client_key_file.?)
            else if (c.client_cert_pem) |pem|
                dusty.Cert.fromPem(pem, c.client_key_pem.?)
            else
                null,
            .insecure_skip_verify = c.insecure_skip_verify,
            .first = c.tls_first,
            .required = c.tls_required,
        },
    };
    if (c.token) |t| o.auth = .{ .token = t };
    if (c.user) |u| o.auth = .{ .user_password = .{ .username = u, .password = c.password.? } };
    if (c.nkey_seed) |s| o.auth = .{ .nkey = Secret{ .text = s } };
    if (c.nkey_seed_file) |f| o.auth = .{ .nkey = Secret{ .file = f } };
    if (c.creds) |s| o.auth = .{ .creds = Secret{ .text = s } };
    if (c.creds_file) |f| o.auth = .{ .creds = Secret{ .file = f } };

    const js = c.jetstream;
    const streams = try a.alloc(anole.nats.jetstream.StreamConfig, js.streams.len);
    for (js.streams, streams) |s, *out| out.* = .{
        .name = s.name,
        .subjects = s.subjects,
        .retention = std.meta.stringToEnum(@TypeOf(out.retention), s.retention).?,
        .storage = std.meta.stringToEnum(@TypeOf(out.storage), s.storage).?,
        .replicas = s.replicas,
        .max_age = if (s.max_age_ms) |n| ms(@intCast(@min(n, std.math.maxInt(i64)))) else null,
        .max_bytes = s.max_bytes,
        .max_msgs = s.max_msgs,
        .duplicate_window = if (s.duplicate_window_ms) |n| ms(@intCast(@min(n, std.math.maxInt(i64)))) else null,
        .extra_json = if (s.extra) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else null,
    };
    const consumers = try a.alloc(anole.nats.jetstream.ConsumerConfig, js.consumers.len);
    for (js.consumers, consumers) |k, *out| {
        const backoff = try a.alloc(std.Io.Duration, k.backoff_ms.len);
        for (k.backoff_ms, backoff) |n, *d| d.* = ms(n);
        out.* = .{
            .stream = k.stream,
            .durable = k.durable,
            .filter_subjects = k.filter_subjects,
            .deliver_policy = std.meta.stringToEnum(@TypeOf(out.deliver_policy), k.deliver_policy).?,
            .ack_wait = ms(k.ack_wait_ms),
            .max_deliver = k.max_deliver,
            .max_ack_pending = k.max_ack_pending,
            .backoff = backoff,
            .extra_json = if (k.extra) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else null,
        };
    }
    o.jetstream = .{ .domain = js.domain, .streams = streams, .consumers = consumers };
    return o;
}

// ---------------------------------------------------------------------------
// Records

const Writer = struct {
    rec: []u8,
    at: usize,

    fn put(w: *Writer, bytes: []const u8) abi.Span {
        if (bytes.len == 0) return .{};
        @memcpy(w.rec[w.at..][0..bytes.len], bytes);
        defer w.at += bytes.len;
        return .{ .off = @intCast(w.at), .len = @intCast(bytes.len) };
    }
};

const Header = [2][]const u8;

/// What goes into an `anole_nats_msg_event`.
const MsgData = struct {
    subject: []const u8,
    reply: []const u8 = "",
    headers: []const Header = &.{},
    payload: []const u8 = "",
    status: u16 = 0,
    user_data: u64,
    sub: u64,
    stream: []const u8 = "",
    consumer: []const u8 = "",
    stream_seq: u64 = 0,
    consumer_seq: u64 = 0,
    delivered: u64 = 0,
    pending: u64 = 0,
    timestamp_ns: i64 = 0,
};

fn msgRecord(typ: abi.EventType, handle: u64, m: MsgData) ![]align(8) u8 {
    const Ev = abi.NatsMsgEvent;
    var bytes: usize = m.subject.len + m.reply.len + m.payload.len + m.stream.len + m.consumer.len;
    for (m.headers) |h| bytes += h[0].len + h[1].len;
    const spans_off = @sizeOf(Ev);
    const bytes_off = spans_off + m.headers.len * 2 * @sizeOf(abi.Span);
    const rec = try engine.newRecord(bytes_off + bytes, typ, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = bytes_off };
    ev.user_data = m.user_data;
    ev.sub = m.sub;
    ev.subject = w.put(m.subject);
    ev.reply = w.put(m.reply);
    ev.headers_off = @intCast(spans_off);
    ev.nheaders = @intCast(m.headers.len);
    ev.payload = w.put(m.payload);
    ev.status = m.status;
    ev.stream_seq = m.stream_seq;
    ev.consumer_seq = m.consumer_seq;
    ev.delivered = m.delivered;
    ev.pending = m.pending;
    ev.timestamp_ns = m.timestamp_ns;
    ev.stream = w.put(m.stream);
    ev.consumer = w.put(m.consumer);
    const spans: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + spans_off));
    for (m.headers, 0..) |h, i| {
        spans[2 * i] = w.put(h[0]);
        spans[2 * i + 1] = w.put(h[1]);
    }
    return rec;
}

const ReplyData = struct {
    user_data: u64,
    op: u8,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: abi.DbErrorClass = .none,
    subject: []const u8 = "",
    headers: []const Header = &.{},
    payload: []const u8 = "",
    msg_status: u16 = 0,
    duplicate: u16 = 0,
    seq: u64 = 0,
    stream: []const u8 = "",
    message: []const u8 = "",
    code: []const u8 = "",
};

fn replyRecord(r: ReplyData) ![]align(8) u8 {
    const Ev = abi.NatsReplyEvent;
    var bytes: usize = r.subject.len + r.payload.len + r.stream.len + r.message.len + r.code.len;
    for (r.headers) |h| bytes += h[0].len + h[1].len;
    const spans_off = @sizeOf(Ev);
    const bytes_off = spans_off + r.headers.len * 2 * @sizeOf(abi.Span);
    const rec = try engine.newRecord(bytes_off + bytes, .nats_reply, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = bytes_off };
    ev.user_data = r.user_data;
    ev.status = r.status;
    ev.http_status = r.http_status;
    ev.error_class = @backingInt(r.error_class);
    ev.op = r.op;
    ev.subject = w.put(r.subject);
    ev.headers_off = @intCast(spans_off);
    ev.nheaders = @intCast(r.headers.len);
    ev.payload = w.put(r.payload);
    ev.msg_status = r.msg_status;
    ev.duplicate = r.duplicate;
    ev.seq = r.seq;
    ev.stream = w.put(r.stream);
    ev.@"error" = w.put(r.message);
    ev.error_code = w.put(r.code);
    const spans: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + spans_off));
    for (r.headers, 0..) |h, i| {
        spans[2 * i] = w.put(h[0]);
        spans[2 * i + 1] = w.put(h[1]);
    }
    return rec;
}

fn endRecord(handle: u64, user_data: u64, reason: u32, dropped: u64, message: []const u8) ![]align(8) u8 {
    const Ev = abi.BrokerEndEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + message.len, .nats_sub_end, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = user_data;
    ev.reason = reason;
    ev.dropped = dropped;
    ev.@"error" = w.put(message);
    return rec;
}

// ---------------------------------------------------------------------------
// Publishing

pub const CallError = error{ Invalid, State, Again, OutOfMemory, Unsupported, Gone };

fn checkOpen(b: *Broker) CallError!void {
    if (comptime !features.nats) return error.Unsupported;
    switch (b.engine.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!b.open.load(.acquire) or b.client == null) return error.State;
}

/// `anole_nats_publish`: `.ok`, or `.busy` when taken past half the queue.
pub fn publish(b: *Broker, c: *Consumer, m: abi.NatsOut, flags: u32) CallError!bool {
    if (comptime !features.nats) return error.Unsupported;
    if (flags != 0) return error.Invalid;
    if (c.engine != b.engine) return error.Invalid;
    try checkOpen(b);
    const subject = m.subject.slice();
    if (subject.len == 0) return error.Invalid;
    var hbuf: [64]anole.nats.core.Headers.Header = undefined;
    const nh = m.nheaders;
    if (nh > hbuf.len) return error.Invalid;
    if (nh > 0) {
        const src = (m.headers orelse return error.Invalid)[0..nh];
        for (src, 0..) |h, i| hbuf[i] = .{ .name = h.name.slice(), .value = h.value.slice() };
    }
    const data: []const u8 = if (m.len == 0) "" else (m.data orelse return error.Invalid)[0..m.len];
    const k = b.client.?.pick();
    const r = k.publishNow(.{
        .subject = subject,
        .reply_to = if (m.reply.len > 0) m.reply.slice() else null,
        .headers = hbuf[0..nh],
        .payload = data,
    }) catch |err| {
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "Full") or std.mem.eql(u8, name, "BufferFull")) {
            want(b, c);
            return error.Again;
        }
        if (std.mem.eql(u8, name, "OutOfMemory")) return error.OutOfMemory;
        if (std.mem.eql(u8, name, "InvalidSubject") or std.mem.eql(u8, name, "InvalidHeader") or std.mem.eql(u8, name, "PayloadTooLarge") or std.mem.eql(u8, name, "UnsupportedFeature"))
            return error.Invalid;
        return error.State;
    };
    if (r == .busy) {
        want(b, c);
        return true;
    }
    return false;
}

fn want(b: *Broker, c: *Consumer) void {
    if (!b.wants.add(c)) return;
    if (b.wants.running.swap(true, .acq_rel)) return;
    if (c.execs.items.len == 0) {
        b.wants.running.store(false, .release);
        return;
    }
    const cmd = gpa.create(WatchCmd) catch {
        b.wants.running.store(false, .release);
        return;
    };
    cmd.* = .{ .b = b };
    c.execs.items[0].post(&cmd.cmd);
}

const WatchCmd = struct {
    cmd: Command = .{ .run = run },
    b: *Broker,

    fn run(cmd: *Command, x: *Exec) void {
        const w: *WatchCmd = @fieldParentPtr("cmd", cmd);
        const b = w.b;
        gpa.destroy(w);
        if (x.engine.phase.load(.acquire) == .stopped) return;
        placement.concurrent(&x.nats.work, x.engine.io, .local, watch, .{b}) catch b.wants.running.store(false, .release);
    }
};

/// Tells the consumers that wait when the queue has room.
fn watch(b: *Broker) std.Io.Cancelable!void {
    const io = b.engine.io;
    while (true) {
        try io.sleep(ms(2), .awake);
        if (!b.wants.any()) {
            b.wants.running.store(false, .release);
            // One may have been added meanwhile.
            if (!b.wants.any() or b.wants.running.swap(true, .acq_rel)) return;
            continue;
        }
        if (!b.open.load(.acquire)) return;
        const cl = b.client orelse return;
        if (!cl.cores[0].writable()) continue;
        var taken: [32]?*Consumer = undefined;
        b.wants.take(&taken);
        for (taken) |maybe| {
            const c = maybe orelse continue;
            if (c.execs.items.len == 0) continue;
            const rec = engine.newRecord(@sizeOf(abi.BrokerStatusEvent), .nats_writable, 0) catch continue;
            const ev: *abi.BrokerStatusEvent = @ptrCast(rec.ptr);
            ev.broker = b.index;
            ev.status = abi.BROKER_WRITABLE;
            c.execs.items[0].postRecord(rec, false);
        }
    }
}

// ---------------------------------------------------------------------------
// Requests and JetStream publishes

const Op = enum { request, js_publish };

const Req = struct {
    cmd: Command = .{ .run = run },
    b: *Broker,
    op: Op,
    user_data: u64,
    flags: u32,
    timeout_ms: u32,
    subject: []const u8,
    reply_to: []const u8,
    headers: []const Header,
    payload: []const u8,
    msg_id: []const u8 = "",
    expected_stream: []const u8 = "",
    expected_last_seq: ?u64 = null,
    arena: std.heap.ArenaAllocator,

    fn free(q: *Req) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn run(cmd: *Command, x: *Exec) void {
        const q: *Req = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        placement.concurrent(&x.nats.work, x.engine.io, .local, task, .{ x, q }) catch q.free();
    }
};

/// Copies the call's pieces into a command's arena.
fn newReq(b: *Broker, op: Op, m: abi.NatsOut, user_data: u64) CallError!*Req {
    if (m.subject.len == 0) return error.Invalid;
    const nh = m.nheaders;
    if (nh > 64) return error.Invalid;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const q = try a.create(Req);
    const headers = try a.alloc(Header, nh);
    if (nh > 0) {
        const src = (m.headers orelse return error.Invalid)[0..nh];
        for (src, headers) |h, *o| o.* = .{ try a.dupe(u8, h.name.slice()), try a.dupe(u8, h.value.slice()) };
    }
    const data: []const u8 = if (m.len == 0) "" else (m.data orelse return error.Invalid)[0..m.len];
    q.* = .{
        .b = b,
        .op = op,
        .user_data = user_data,
        .flags = 0,
        .timeout_ms = 0,
        .subject = try a.dupe(u8, m.subject.slice()),
        .reply_to = try a.dupe(u8, m.reply.slice()),
        .headers = headers,
        .payload = try a.dupe(u8, data),
        .arena = arena,
    };
    return q;
}

/// The executor that serves a call: the request's, or the consumer's next.
fn pickExec(b: *Broker, c: ?*Consumer, req: u64) CallError!*Exec {
    const e = b.engine;
    if (c) |cc| if (cc.engine != e) return error.Invalid;
    if (req != 0) return db_cap.resolveReq(e, req, c) catch |err| switch (err) {
        error.Gone => error.Gone,
        error.State => error.State,
        else => error.Invalid,
    };
    const cc = c orelse return error.Invalid;
    if (cc.execs.items.len == 0) return error.State;
    const i = cc.next_db.fetchAdd(1, .monotonic) % cc.execs.items.len;
    return cc.execs.items[i];
}

/// `anole_nats_request`.
pub fn request(b: *Broker, c: ?*Consumer, m: abi.NatsOut, opts: abi.NatsRequestOptions, user_data: u64) CallError!void {
    try checkOpen(b);
    if (opts.flags & ~abi.NATS_F_RETRY != 0) return error.Invalid;
    const x = try pickExec(b, c, opts.req);
    if (!b.client.?.writable({})) return error.Again;
    const q = try newReq(b, .request, m, user_data);
    q.flags = opts.flags;
    q.timeout_ms = opts.timeout_ms;
    x.post(&q.cmd);
}

/// `anole_nats_js_publish`.
pub fn jsPublish(b: *Broker, c: ?*Consumer, m: abi.NatsOut, opts: abi.NatsJsPublishOptions, user_data: u64) CallError!void {
    try checkOpen(b);
    if (opts.flags & ~abi.NATS_JS_F_EXPECT_LAST_SEQ != 0) return error.Invalid;
    const x = try pickExec(b, c, opts.req);
    const q = try newReq(b, .js_publish, m, user_data);
    errdefer q.free();
    const a = q.arena.allocator();
    q.timeout_ms = opts.timeout_ms;
    q.msg_id = try a.dupe(u8, opts.msg_id.slice());
    q.expected_stream = try a.dupe(u8, opts.expected_stream.slice());
    q.expected_last_seq = if (opts.flags & abi.NATS_JS_F_EXPECT_LAST_SEQ != 0 or opts.expected_last_seq != 0) opts.expected_last_seq else null;
    x.post(&q.cmd);
}

fn task(x: *Exec, q: *Req) std.Io.Cancelable!void {
    defer q.free();
    if (comptime !features.nats) return;
    const b = q.b;
    if (!b.open.load(.acquire)) return;
    const cl = b.client orelse return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: db.Ctx = .{ .io = x.engine.io, .arena = arena.allocator() };
    const timeout: ?std.Io.Duration = if (q.timeout_ms == abi.DB_TIMEOUT_NONE) .max else if (q.timeout_ms > 0) ms(q.timeout_ms) else null;
    var data: ReplyData = .{ .user_data = q.user_data, .op = if (q.op == .request) abi.NATS_OP_REQUEST else abi.NATS_OP_JS_PUBLISH };
    var failed: ?anyerror = null;
    switch (q.op) {
        .request => {
            const out = cl.with(.{ .timeout = timeout, .retry = q.flags & abi.NATS_F_RETRY != 0 }).requestMsg(&ctx, .{
                .subject = q.subject,
                .headers = q.headers,
                .payload = q.payload,
            });
            if (out) |r| {
                data.subject = r.subject;
                data.headers = r.headers;
                data.payload = r.payload;
                data.msg_status = r.status orelse 0;
            } else |err| failed = err;
        },
        .js_publish => {
            const out = cl.js().publish(&ctx, q.subject, q.payload, .{
                .msg_id = if (q.msg_id.len > 0) q.msg_id else null,
                .expected_stream = if (q.expected_stream.len > 0) q.expected_stream else null,
                .expected_last_sequence = q.expected_last_seq,
                .headers = q.headers,
                .timeout = timeout,
            });
            if (out) |pub_ack| {
                data.stream = pub_ack.stream;
                data.seq = pub_ack.sequence;
                data.duplicate = @intFromBool(pub_ack.duplicate);
            } else |err| failed = err;
        },
    }
    if (failed) |err| {
        if (err == error.Canceled) return error.Canceled;
        data.status = abi.E_BROKER;
        data.http_status = switch (err) {
            error.ServiceUnavailable => 503,
            error.GatewayTimeout => 504,
            else => 500,
        };
        if (db.lastError(&ctx)) |detail| {
            data.error_class = std.meta.stringToEnum(abi.DbErrorClass, @tagName(detail.class)) orelse .other;
            data.message = detail.message;
            data.code = detail.code;
        } else {
            data.error_class = .other;
            data.message = @errorName(err);
        }
        if (err == error.GatewayTimeout) data.status = abi.E_TIMEOUT;
    }
    const rec = replyRecord(data) catch return;
    x.postRecord(rec, true);
}

// ---------------------------------------------------------------------------
// Subscriptions and JetStream consumes

const SubKind = enum { subscription, consume };

/// A subscription or consume in flight: one allocation holding the command,
/// the copied subject and names.
pub const SubRun = struct {
    cmd: Command = .{ .run = start },
    b: *Broker,
    c: *Consumer,
    x: *Exec,
    kind: SubKind,
    handle: u64 = 0,
    user_data: u64,
    subject: []const u8,
    queue: []const u8,
    stream: []const u8 = "",
    consumer: []const u8 = "",
    max_messages: u32,
    max_bytes: u32,
    overflow: u32,
    max_inflight: u32 = 64,
    expires_ms: u32 = 30_000,
    stop: std.atomic.Value(bool) = .init(false),
    task: ?placement.Task = null,
    puller: ?*Puller = null,
    arena: std.heap.ArenaAllocator,

    fn free(s: *SubRun) void {
        var arena = s.arena;
        arena.deinit();
    }

    fn start(cmd: *Command, x: *Exec) void {
        const s: *SubRun = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return s.release();
        placement.concurrent(&x.nats.work, x.engine.io, .local, subTask, .{ x, s }) catch {
            s.release();
        };
    }

    /// Drops the handle and frees the run.
    fn release(s: *SubRun) void {
        const st = &s.b.engine.nats_state;
        st.subs.acquire();
        const h = Handle.decode(s.handle);
        if (st.subs.get(h)) |_| st.subs.drop(h.slot);
        st.subs.release();
        s.free();
    }
};

fn newSub(b: *Broker, c: *Consumer, kind: SubKind, subject: []const u8, user_data: u64) CallError!*SubRun {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const s = try a.create(SubRun);
    s.* = .{
        .b = b,
        .c = c,
        .x = undefined,
        .kind = kind,
        .user_data = user_data,
        .subject = try a.dupe(u8, subject),
        .queue = "",
        .max_messages = 0,
        .max_bytes = 0,
        .overflow = 0,
        .arena = arena,
    };
    return s;
}

fn register(b: *Broker, s: *SubRun, x: *Exec) CallError!u64 {
    const st = &b.engine.nats_state;
    st.subs.acquire();
    defer st.subs.release();
    const slot = st.subs.alloc(s) catch return error.OutOfMemory;
    s.x = x;
    s.handle = handleOf(.broker_sub, slot.index, slot.gen, x.index);
    return s.handle;
}

/// `anole_nats_subscribe`.
pub fn subscribe(b: *Broker, c: *Consumer, subject: []const u8, opts: abi.NatsSubscribeOptions, user_data: u64) CallError!u64 {
    try checkOpen(b);
    if (opts.reserved != 0 or opts.overflow > abi.NATS_CLOSE or subject.len == 0) return error.Invalid;
    const x = try pickExec(b, c, 0);
    const s = try newSub(b, c, .subscription, subject, user_data);
    errdefer s.free();
    s.queue = try s.arena.allocator().dupe(u8, opts.queue.slice());
    s.max_messages = opts.max_messages;
    s.max_bytes = opts.max_bytes;
    s.overflow = opts.overflow;
    const h = try register(b, s, x);
    x.post(&s.cmd);
    return h;
}

/// `anole_nats_js_consume`.
pub fn consume(b: *Broker, c: *Consumer, stream: []const u8, consumer: []const u8, opts: abi.NatsJsConsumeOptions, user_data: u64) CallError!u64 {
    try checkOpen(b);
    if (stream.len == 0 or consumer.len == 0) return error.Invalid;
    const x = try pickExec(b, c, 0);
    const s = try newSub(b, c, .consume, "", user_data);
    errdefer s.free();
    const a = s.arena.allocator();
    s.stream = try a.dupe(u8, stream);
    s.consumer = try a.dupe(u8, consumer);
    if (opts.max_inflight > 0) s.max_inflight = opts.max_inflight;
    if (opts.expires_ms > 0) s.expires_ms = opts.expires_ms;
    const h = try register(b, s, x);
    x.post(&s.cmd);
    return h;
}

/// `anole_nats_unsubscribe` and releasing a subscription handle (a cleanup
/// call: nothing to say when it is over).
pub fn unsubscribe(e: *Engine, hv: u64) void {
    const h = Handle.decode(hv);
    const st = &e.nats_state;
    st.subs.acquire();
    defer st.subs.release();
    const entry = st.subs.get(h) orelse return;
    const s = entry.value;
    s.stop.store(true, .release);
    if (s.task) |t| placement.cancelTask(t);
}

fn subTask(x: *Exec, s: *SubRun) std.Io.Cancelable!void {
    const e = x.engine;
    const st = &e.nats_state;
    // The task, so that `unsubscribe` can cancel it.
    st.subs.acquire();
    s.task = placement.currentTask(e.io);
    st.subs.release();
    var reason: u32 = abi.BROKER_END_CLOSED;
    var dropped: u64 = 0;
    var message: []const u8 = "";
    var stopped_by_engine = false;
    if (comptime features.nats) {
        const cl = s.b.client.?;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = e.io, .arena = arena.allocator() };
        switch (s.kind) {
            .subscription => {
                if (cl.subscribe(&ctx, s.subject, .{
                    .queue = if (s.queue.len > 0) s.queue else null,
                    .pending = .{ .messages = if (s.max_messages > 0) s.max_messages else null, .bytes = if (s.max_bytes > 0) s.max_bytes else null },
                    .overflow = switch (s.overflow) {
                        abi.NATS_DROP_OLDEST => .drop_oldest,
                        abi.NATS_CLOSE => .close_subscription,
                        else => .drop_newest,
                    },
                })) |sub| {
                    defer sub.deinit();
                    while (!s.stop.load(.acquire)) {
                        const got = sub.inner.next(.{}) catch |err| {
                            switch (err) {
                                error.Canceled => stopped_by_engine = !s.stop.load(.acquire),
                                error.SlowConsumer => reason = abi.BROKER_END_SLOW,
                                error.PermissionDenied => reason = abi.BROKER_END_DENIED,
                                else => reason = abi.BROKER_END_FAILED,
                            }
                            break;
                        };
                        var m = got orelse break;
                        defer m.deinit();
                        deliver(x, s, &m) catch {
                            stopped_by_engine = !s.stop.load(.acquire);
                            break;
                        };
                    }
                    dropped = sub.inner.stats().dropped;
                } else |err| {
                    reason = if (err == error.Database) abi.BROKER_END_DENIED else abi.BROKER_END_FAILED;
                    if (db.lastError(&ctx)) |d| message = d.message else message = @errorName(err);
                    if (err == error.Canceled) stopped_by_engine = !s.stop.load(.acquire);
                }
            },
            .consume => {
                if (cl.js().consumeRaw(s.stream, s.consumer, .{
                    .max_inflight = s.max_inflight,
                    .expires = ms(s.expires_ms),
                    .timeout = .fromSeconds(300),
                }, s, jsRun)) |p| {
                    s.puller = p;
                    // Until unsubscribed (a cancel), or the stop.
                    var never: std.Io.Event = .unset;
                    never.wait(e.io) catch {
                        stopped_by_engine = !s.stop.load(.acquire);
                    };
                    p.stop();
                } else |err| {
                    reason = abi.BROKER_END_FAILED;
                    message = @errorName(err);
                }
            },
        }
    }
    const h = s.handle;
    const user_data = s.user_data;
    if (!stopped_by_engine) {
        if (endRecord(h, user_data, reason, dropped, message)) |rec| x.postRecord(rec, false) else |_| {}
    }
    s.release();
}

/// One message of a subscription, as a record on the consumer's ring; waits
/// for room (back-pressure).
fn deliver(x: *Exec, s: *SubRun, m: *anole.nats.core.Message) error{Canceled}!void {
    var hbuf: [64]Header = undefined;
    var n: usize = 0;
    var it = m.headers.iterator();
    while (it.next()) |hd| {
        if (n == hbuf.len) break;
        hbuf[n] = .{ hd.name, hd.value };
        n += 1;
    }
    const rec = msgRecord(.nats_msg, s.handle, .{
        .subject = m.subject,
        .reply = m.reply_to orelse "",
        .headers = hbuf[0..n],
        .payload = m.payload,
        .status = m.headers.status() orelse 0,
        .user_data = s.user_data,
        .sub = s.handle,
    }) catch return;
    x.postRecord(rec, true);
}

// ---- JetStream messages --------------------------------------------------------------

/// What a JetStream message's handler waits for: the consumer's answer.
pub const MsgWait = struct {
    event: std.Io.Event = .unset,
    kind: u32 = abi.NATS_ACK,
    delay_ms: u32 = 0,
    resolved: bool = false,
    jm: *anole.nats.jetstream.JsMsg,
};

/// The handler of a consume: posts the message and waits for the consumer.
fn jsRun(state: ?*anyopaque, jm: *anole.nats.jetstream.JsMsg) anyerror!void {
    const s: *SubRun = @ptrCast(@alignCast(state.?));
    const e = s.b.engine;
    const st = &e.nats_state;
    if (s.stop.load(.acquire)) return jm.nak(null);
    var w: MsgWait = .{ .jm = jm };
    st.msgs.acquire();
    const slot = st.msgs.alloc(&w) catch {
        st.msgs.release();
        return jm.nak(null);
    };
    st.msgs.release();
    const handle = handleOf(.broker_msg, slot.index, slot.gen, s.x.index);
    defer {
        st.msgs.acquire();
        st.msgs.drop(slot.index);
        st.msgs.release();
    }
    var hbuf: [64]Header = undefined;
    const n = @min(jm.msg.headers.len, hbuf.len);
    @memcpy(hbuf[0..n], jm.msg.headers[0..n]);
    const rec = msgRecord(.nats_js_msg, handle, .{
        .subject = jm.msg.subject,
        .headers = hbuf[0..n],
        .payload = jm.msg.payload,
        .user_data = s.user_data,
        .sub = s.handle,
        .stream = jm.stream,
        .consumer = jm.consumer,
        .stream_seq = jm.stream_seq,
        .consumer_seq = jm.consumer_seq,
        .delivered = jm.delivered,
        .pending = jm.pending,
        .timestamp_ns = jm.timestamp_ns,
    }) catch return jm.nak(null);
    s.x.postRecord(rec, true);
    w.event.wait(e.io) catch |err| {
        jm.nak(null) catch {};
        return err;
    };
    switch (w.kind) {
        abi.NATS_NAK => try jm.nak(if (w.delay_ms > 0) ms(w.delay_ms) else null),
        abi.NATS_TERM => try jm.term(),
        else => try jm.ack(),
    }
}

/// `anole_nats_ack` and releasing a message handle (= NAK).
pub fn ack(e: *Engine, hv: u64, kind: u32, delay_ms: u32) CallError!void {
    if (comptime !features.nats) return error.Unsupported;
    if (kind > abi.NATS_PROGRESS) return error.Invalid;
    const h = Handle.decode(hv);
    const st = &e.nats_state;
    st.msgs.acquire();
    defer st.msgs.release();
    const entry = st.msgs.get(h) orelse return error.Gone;
    const w = entry.value;
    if (w.resolved) return error.Gone;
    if (kind == abi.NATS_PROGRESS) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var ctx: db.Ctx = .{ .io = e.io, .arena = arena.allocator() };
        w.jm.inProgress() catch {
            _ = &ctx;
            return error.Again;
        };
        return;
    }
    w.kind = kind;
    w.delay_ms = delay_ms;
    w.resolved = true;
    w.event.set(e.io);
}
