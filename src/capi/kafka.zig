//! `anole_kafka_*`: the configuration's Kafka brokers, used without blocking
//! the caller.
//!
//! A produce copies the record and queues it on the broker's FIFO on the
//! calling thread (it never waits). One pump task, on an executor of a
//! consumer that produced, appends the queued records to the client's
//! producer in order (a key's records keep their order) and starts a waiter
//! per record, which posts `ANOLE_EV_KAFKA_DELIVERY` once the broker has
//! acknowledged it or the delivery failed. The queue is bounded by the
//! producer's `buffer_bytes`: past it a produce answers `ANOLE_E_AGAIN` and
//! `ANOLE_EV_KAFKA_WRITABLE` follows when there is room.
//!
//! A subscription is one group member (`anole.kafka` consumer with its batch
//! handler): each partition's delivery task posts one `ANOLE_EV_KAFKA_RECORDS`
//! batch and waits for `anole_kafka_batch_done` or `_retry`, so a partition
//! has at most one batch outstanding and is handled in order. A rebalance
//! posts `ANOLE_EV_KAFKA_REVOKE` first; batches the consumer does not finish
//! within `rebalance_timeout_ms` go stale.
//!
//! Handles: a group is a `kafka_group` and a batch a `kafka_batch`, kinds of
//! their own (a NATS handle given to a Kafka call is the wrong kind).
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const nats_cap = @import("nats.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const Handle = engine.Handle;

const KClient = if (features.kafka) anole.kafka.Client else void;
const KConsumer = if (features.kafka) anole.kafka.impl.consumer.Consumer else void;
const Slot = if (features.kafka) anole.kafka.impl.producer.Slot else void;
const KHeader = if (features.kafka) anole.kafka.Header else struct { key: []const u8, value: ?[]const u8 };
const KMsg = if (features.kafka) anole.kafka.Msg else void;

const log = std.log.scoped(.anole);
const ms = std.Io.Duration.fromMilliseconds;

const Table = nats_cap.Table;

/// One configured Kafka broker (`anole_kafka *` in C).
pub const Broker = struct {
    engine: *Engine,
    config: config_mod.Config.Broker,
    /// The place in the configuration's "brokers".
    index: u32,
    client: ?*KClient = null,
    open: std.atomic.Value(bool) = .init(false),
    wants: nats_cap.Wants = .{},
    /// Bytes produced and not yet delivered or failed.
    pending: std.atomic.Value(usize) = .init(0),
    buffer_bytes: usize = 32 << 20,
    queue: Queue = .{},
};

/// Engine-wide: group and batch handles.
pub const State = struct {
    groups: Table(*Group) = .{},
    batches: Table(*BatchWait) = .{},

    pub fn init(s: *State, first_gen: u32) void {
        s.groups.first_gen = first_gen;
        s.batches.first_gen = first_gen;
    }

    pub fn maxGen(s: *State) u32 {
        return @max(s.groups.maxGen(), s.batches.maxGen());
    }

    pub fn deinit(s: *State) void {
        s.groups.deinit();
        s.batches.deinit();
    }
};

/// Per executor: the tasks of this executor's pump, waiters, groups and
/// watchers, canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }

    pub fn deinit(_: *ExecState) void {}
};

pub const CallError = error{ Invalid, State, Again, OutOfMemory, Unsupported, Gone };

// ---------------------------------------------------------------------------
// Opening

/// Opens every configured Kafka broker on `app` (from the server's main
/// thread, before the listeners open). They connect when serving starts.
pub fn open(e: *Engine, app: *anole.App) !void {
    for (e.kafka_brokers) |*b| {
        if (comptime !features.kafka) unreachable;
        b.buffer_bytes = b.config.kafka.?.producer.buffer_bytes;
        b.client = try app.kafka(try kafkaOptions(e, b));
        b.open.store(true, .release);
    }
}

pub fn close(e: *Engine) void {
    for (e.kafka_brokers) |*b| b.open.store(false, .release);
}

/// Frees what a stopped server's queues still hold.
pub fn destroy(e: *Engine) void {
    for (e.kafka_brokers) |*b| {
        var it = b.queue.take();
        while (it) |item| {
            it = item.next;
            item.free();
        }
    }
}

pub fn find(e: *Engine, name: []const u8) ?*Broker {
    for (e.kafka_brokers) |*b| if (std.mem.eql(u8, b.config.name, name)) return b;
    return null;
}

fn optMs(n: u32) ?std.Io.Duration {
    return if (n > 0) ms(n) else null;
}

fn kafkaOptions(e: *Engine, b: *Broker) !anole.kafka.Options {
    _ = e;
    const c = b.config.kafka.?;
    const p = c.producer;
    var o: anole.kafka.Options = .{
        .brokers = c.brokers,
        .client_id = c.client_id,
        .label = b.config.name,
        .timeout = optMs(b.config.timeout_ms),
        .connect_timeout = ms(c.connect_timeout_ms),
        .request_timeout = ms(c.request_timeout_ms),
        .metadata_max_age = ms(c.metadata_max_age_ms),
        .connect_at_start = c.connect_at_start,
        .producer = .{
            .acks = if (std.mem.eql(u8, p.acks, "none")) .none else if (std.mem.eql(u8, p.acks, "leader")) .leader else .all,
            .idempotent = p.idempotent,
            .linger = ms(p.linger_ms),
            .batch_bytes = p.batch_bytes,
            .buffer_bytes = p.buffer_bytes,
            .compression = std.meta.stringToEnum(@FieldType(anole.kafka.Options.Producer, "compression"), p.compression).?,
            .delivery_timeout = ms(p.delivery_timeout_ms),
            .metadata_wait = ms(p.metadata_wait_ms),
            .max_request_bytes = p.max_request_bytes,
        },
        .errors = b.config.errors,
    };
    const any_tls = c.tls or c.ca_file != null or c.ca_pem != null or c.client_cert_file != null or
        c.client_cert_pem != null or c.insecure_skip_verify;
    if (any_tls) o.tls = .{
        .ca = if (c.ca_file) |f| .{ .file = f } else if (c.ca_pem) |pem| .{ .pem = pem } else null,
        .client_certificate = if (c.client_cert_file) |f|
            dusty.Cert.fromFiles(f, c.client_key_file.?)
        else if (c.client_cert_pem) |pem|
            dusty.Cert.fromPem(pem, c.client_key_pem.?)
        else
            null,
        .insecure_skip_verify = c.insecure_skip_verify,
    };
    if (c.sasl) |s| o.sasl = .{
        .mechanism = if (std.mem.eql(u8, s.mechanism, "PLAIN")) .plain else if (std.mem.eql(u8, s.mechanism, "SCRAM-SHA-256")) .scram_sha_256 else .scram_sha_512,
        .username = s.username,
        .password = s.password,
    };
    return o;
}

fn checkOpen(b: *Broker) CallError!void {
    if (comptime !features.kafka) return error.Unsupported;
    switch (b.engine.phase.load(.acquire)) {
        .open, .starting, .running, .draining => {},
        else => return error.State,
    }
    if (!b.open.load(.acquire) or b.client == null) return error.State;
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

/// An `ANOLE_EV_KAFKA_RECORDS` record: the records at `records_off`, their
/// header spans after them, then the bytes.
fn recordsRecord(handle: u64, user_data: u64, group: u64, topic: []const u8, partition: i32, high_watermark: i64, recs: []const KRec) ![]align(8) u8 {
    const Ev = abi.KafkaRecordsEvent;
    var bytes: usize = topic.len;
    var nh: usize = 0;
    for (recs) |r| {
        bytes += (if (r.key) |k| k.len else 0) + (if (r.value) |v| v.len else 0);
        for (r.headers) |h| bytes += h.key.len + (if (h.value) |v| v.len else 0);
        nh += r.headers.len;
    }
    const recs_off = @sizeOf(Ev);
    const spans_off = recs_off + recs.len * @sizeOf(abi.KafkaRecord);
    const bytes_off = spans_off + nh * 2 * @sizeOf(abi.Span);
    const rec = try engine.newRecord(bytes_off + bytes, .kafka_records, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = bytes_off };
    ev.user_data = user_data;
    ev.group = group;
    ev.topic = w.put(topic);
    ev.partition = partition;
    ev.nrecords = @intCast(recs.len);
    ev.records_off = @intCast(recs_off);
    ev.high_watermark = high_watermark;
    const out: [*]abi.KafkaRecord = @ptrCast(@alignCast(rec.ptr + recs_off));
    const spans: [*]abi.Span = @ptrCast(@alignCast(rec.ptr + spans_off));
    var hi: usize = 0;
    for (recs, 0..) |r, i| {
        out[i] = .{
            .offset = r.offset,
            .timestamp_ms = r.timestamp_ms,
            .key = if (r.key) |k| w.put(k) else .{},
            .value = if (r.value) |v| w.put(v) else .{},
            .headers_off = @intCast(spans_off + hi * 2 * @sizeOf(abi.Span)),
            .nheaders = @intCast(r.headers.len),
            .flags = (if (r.key == null) abi.KAFKA_REC_F_NULL_KEY else 0) | (if (r.value == null) abi.KAFKA_REC_F_NULL_VALUE else 0),
            .reserved = 0,
        };
        for (r.headers) |h| {
            spans[2 * hi] = w.put(h.key);
            spans[2 * hi + 1] = if (h.value) |v| w.put(v) else .{};
            hi += 1;
        }
    }
    return rec;
}

const KRec = if (features.kafka) anole.kafka.records.Record else struct {
    offset: i64,
    timestamp_ms: i64,
    key: ?[]const u8,
    value: ?[]const u8,
    headers: []const KHeader,
};

const Delivery = struct {
    user_data: u64,
    status: i32 = abi.OK,
    http_status: u16 = 0,
    error_class: abi.DbErrorClass = .none,
    partition: i32 = 0,
    offset: i64 = -1,
    timestamp_ms: i64 = 0,
    topic: []const u8 = "",
    message: []const u8 = "",
    code: []const u8 = "",
};

fn deliveryRecord(d: Delivery) ![]align(8) u8 {
    const Ev = abi.KafkaDeliveryEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + d.topic.len + d.message.len + d.code.len, .kafka_delivery, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = d.user_data;
    ev.status = d.status;
    ev.http_status = d.http_status;
    ev.error_class = @backingInt(d.error_class);
    ev.partition = d.partition;
    ev.offset = d.offset;
    ev.timestamp_ms = d.timestamp_ms;
    ev.topic = w.put(d.topic);
    ev.@"error" = w.put(d.message);
    ev.error_code = w.put(d.code);
    return rec;
}

/// `ANOLE_EV_KAFKA_ASSIGN` / `_REVOKE`.
fn assignRecord(typ: abi.EventType, handle: u64, user_data: u64, topics: []const []const u8, partitions: []const i32) ![]align(8) u8 {
    const Ev = abi.KafkaAssignEvent;
    var bytes: usize = 0;
    for (topics) |t| bytes += t.len;
    const entries_off = @sizeOf(Ev);
    const rec = try engine.newRecord(entries_off + topics.len * @sizeOf(abi.KafkaPartition) + bytes, typ, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = entries_off + topics.len * @sizeOf(abi.KafkaPartition) };
    ev.user_data = user_data;
    ev.entries_off = @intCast(entries_off);
    ev.nentries = @intCast(topics.len);
    const out: [*]abi.KafkaPartition = @ptrCast(@alignCast(rec.ptr + entries_off));
    for (topics, partitions, 0..) |t, p, i| out[i] = .{ .topic = w.put(t), .partition = p, .reserved = 0 };
    return rec;
}

fn endRecord(handle: u64, user_data: u64, reason: u32, message: []const u8) ![]align(8) u8 {
    const Ev = abi.BrokerEndEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + message.len, .kafka_group_end, handle);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = user_data;
    ev.reason = reason;
    ev.@"error" = w.put(message);
    return rec;
}

fn httpStatusOf(map: anole.db.ErrorMap, class: anole.db.Class) u16 {
    return switch (map.errorFor(class)) {
        error.BadRequest => 400,
        error.NotFound => 404,
        error.Conflict => 409,
        error.UnprocessableEntity => 422,
        error.ServiceUnavailable => 503,
        error.GatewayTimeout => 504,
        else => 500,
    };
}

fn failedDelivery(b: *Broker, user_data: u64, topic: []const u8, class: anole.db.Class, code: []const u8, message: []const u8) Delivery {
    return .{
        .user_data = user_data,
        .status = if (class == .timeout) abi.E_TIMEOUT else abi.E_BROKER,
        .http_status = httpStatusOf(b.config.errors, class),
        .error_class = std.meta.stringToEnum(abi.DbErrorClass, @tagName(class)) orelse .other,
        .topic = topic,
        .message = message,
        .code = code,
    };
}

// ---------------------------------------------------------------------------
// Producing

/// The FIFO a pump task drains.
const Queue = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Item = null,
    tail: ?*Item = null,
    running: std.atomic.Value(bool) = .init(false),

    fn acquire(q: *Queue) void {
        while (!q.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn push(q: *Queue, it: *Item) void {
        q.acquire();
        defer q.lock.unlock();
        it.next = null;
        if (q.tail) |t| t.next = it else q.head = it;
        q.tail = it;
    }

    fn take(q: *Queue) ?*Item {
        q.acquire();
        defer q.lock.unlock();
        const h = q.head;
        q.head = null;
        q.tail = null;
        return h;
    }

    fn isEmpty(q: *Queue) bool {
        q.acquire();
        defer q.lock.unlock();
        return q.head == null;
    }
};

const Item = struct {
    next: ?*Item = null,
    kind: enum { record, flush },
    c: *Consumer,
    user_data: u64,
    flags: u32 = 0,
    /// What it holds against the broker's `buffer_bytes`.
    size: usize = 0,
    partition: i32 = -1,
    timestamp_ms: i64 = 0,
    topic: []const u8 = "",
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    headers: []const KHeader = &.{},
    arena: std.heap.ArenaAllocator,

    fn free(it: *Item) void {
        var arena = it.arena;
        arena.deinit();
    }
};

fn newItem(c: *Consumer, user_data: u64) !*Item {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const it = try arena.allocator().create(Item);
    it.* = .{ .kind = .record, .c = c, .user_data = user_data, .arena = arena };
    return it;
}

/// `anole_kafka_produce`: `true` when taken past half the buffer.
pub fn produce(b: *Broker, c: *Consumer, m: abi.KafkaOut, user_data: u64) CallError!bool {
    if (comptime !features.kafka) return error.Unsupported;
    if (c.engine != b.engine) return error.Invalid;
    try checkOpen(b);
    const allowed = abi.KAFKA_F_NULL_KEY | abi.KAFKA_F_NULL_VALUE | abi.KAFKA_F_NO_REPORT;
    if (m.flags & ~allowed != 0) return error.Invalid;
    const topic = m.topic.slice();
    if (topic.len == 0 or topic.len > 249 or m.partition < -1 or m.nheaders > 256) return error.Invalid;
    if (c.execs.items.len == 0) return error.State;
    const key = m.key.slice();
    const data: []const u8 = if (m.len == 0) "" else (m.value orelse return error.Invalid)[0..m.len];
    var size: usize = 64 + topic.len + key.len + data.len;
    const hdrs: []const abi.Header = if (m.nheaders == 0) &.{} else (m.headers orelse return error.Invalid)[0..m.nheaders];
    for (hdrs) |h| size += 16 + h.name.len + h.value.len;
    const before = b.pending.fetchAdd(size, .acq_rel);
    if (before + size > b.buffer_bytes) {
        _ = b.pending.fetchSub(size, .acq_rel);
        want(b, c);
        return error.Again;
    }
    const it = newItem(c, user_data) catch {
        _ = b.pending.fetchSub(size, .acq_rel);
        return error.OutOfMemory;
    };
    fill(it, m, topic, key, data, hdrs, size) catch {
        _ = b.pending.fetchSub(size, .acq_rel);
        it.free();
        return error.OutOfMemory;
    };
    b.queue.push(it);
    kick(b, c);
    if (before + size > b.buffer_bytes / 2) {
        want(b, c);
        return true;
    }
    return false;
}

fn fill(it: *Item, m: abi.KafkaOut, topic: []const u8, key: []const u8, data: []const u8, hdrs: []const abi.Header, size: usize) !void {
    const a = it.arena.allocator();
    it.flags = m.flags;
    it.size = size;
    it.partition = m.partition;
    it.timestamp_ms = if (m.timestamp_ms != 0) m.timestamp_ms else @intCast(@divTrunc(std.Io.Clock.real.now(it.c.engine.io).nanoseconds, std.time.ns_per_ms));
    it.topic = try a.dupe(u8, topic);
    it.key = if (m.flags & abi.KAFKA_F_NULL_KEY != 0) null else try a.dupe(u8, key);
    it.value = if (m.flags & abi.KAFKA_F_NULL_VALUE != 0) null else try a.dupe(u8, data);
    const out = try a.alloc(KHeader, hdrs.len);
    for (hdrs, out) |h, *o| o.* = .{ .key = try a.dupe(u8, h.name.slice()), .value = try a.dupe(u8, h.value.slice()) };
    it.headers = out;
}

/// `anole_kafka_flush`.
pub fn flush(b: *Broker, c: *Consumer, user_data: u64) CallError!void {
    if (comptime !features.kafka) return error.Unsupported;
    if (c.engine != b.engine) return error.Invalid;
    try checkOpen(b);
    if (c.execs.items.len == 0) return error.State;
    const it = newItem(c, user_data) catch return error.OutOfMemory;
    it.kind = .flush;
    b.queue.push(it);
    kick(b, c);
}

fn kick(b: *Broker, c: *Consumer) void {
    if (b.queue.running.swap(true, .acq_rel)) return;
    const cmd = gpa.create(PumpCmd) catch {
        b.queue.running.store(false, .release);
        return;
    };
    cmd.* = .{ .b = b };
    c.execs.items[0].post(&cmd.cmd);
}

const PumpCmd = struct {
    cmd: Command = .{ .run = run },
    b: *Broker,

    fn run(cmd: *Command, x: *Exec) void {
        const p: *PumpCmd = @fieldParentPtr("cmd", cmd);
        const b = p.b;
        gpa.destroy(p);
        if (x.engine.phase.load(.acquire) == .stopped) return b.queue.running.store(false, .release);
        placement.concurrent(&x.kafka.work, x.engine.io, .local, pump, .{ x, b }) catch b.queue.running.store(false, .release);
    }
};

/// Appends the queued records to the producer in the order they came.
fn pump(x: *Exec, b: *Broker) std.Io.Cancelable!void {
    var rest: ?*Item = null;
    defer while (rest) |r| {
        rest = r.next;
        _ = b.pending.fetchSub(r.size, .acq_rel);
        r.free();
    };
    while (true) {
        rest = b.queue.take();
        if (rest == null) {
            b.queue.running.store(false, .release);
            // One may have been added meanwhile.
            if (b.queue.isEmpty() or b.queue.running.swap(true, .acq_rel)) return;
            continue;
        }
        while (rest) |it| {
            rest = it.next;
            try handleItem(x, b, it);
        }
    }
}

fn post(it: *Item, rec: []align(8) u8) void {
    if (it.c.execs.items.len == 0) return engine.freeRecord(rec.ptr);
    it.c.execs.items[0].postRecord(rec, false);
}

fn finish(b: *Broker, it: *Item) void {
    _ = b.pending.fetchSub(it.size, .acq_rel);
    it.free();
}

fn handleItem(x: *Exec, b: *Broker, it: *Item) std.Io.Cancelable!void {
    if (comptime !features.kafka) return;
    const cl = b.client orelse return finish(b, it);
    if (!b.open.load(.acquire)) return finish(b, it);
    if (it.kind == .flush) {
        placement.concurrent(&x.kafka.work, x.engine.io, .local, flushTask, .{ b, cl, it }) catch finish(b, it);
        return;
    }
    const slot = Slot.create(gpa) catch return reportFailure(b, it, .unavailable, "out_of_memory", "out of memory");
    cl.producer.append(it.topic, it.key, it.value, it.headers, if (it.partition >= 0) it.partition else null, it.timestamp_ms, slot) catch |err| {
        slot.release();
        slot.release();
        return switch (err) {
            error.Canceled => {
                finish(b, it);
                return error.Canceled;
            },
            error.OutOfMemory => reportFailure(b, it, .other, "out_of_memory", "out of memory"),
            error.BufferFull => reportFailure(b, it, .unavailable, "buffer_full", "the producer's buffer is full"),
            error.TooLarge => reportFailure(b, it, .other, "MESSAGE_TOO_LARGE", "the record is larger than max_request_bytes"),
            error.UnknownTopic => reportFailure(b, it, .other, "UNKNOWN_TOPIC_OR_PARTITION", "the topic does not exist"),
            error.BadPartition => reportFailure(b, it, .other, "invalid_partition", "the partition is not one of the topic's"),
            error.Closing => reportFailure(b, it, .unavailable, "closing", "the client is shutting down"),
            error.Timeout => reportFailure(b, it, .timeout, "timeout", "the broker did not answer in time"),
            error.ConnectionLost, error.NoBroker, error.UnsupportedBroker => reportFailure(b, it, .unavailable, "no_broker", "no broker could be reached"),
            error.AuthFailed => reportFailure(b, it, .other, "SASL_AUTHENTICATION_FAILED", "the broker refused the credentials"),
            error.ProtocolError, error.Truncated, error.Invalid => reportFailure(b, it, .other, "protocol", "the broker's answer was not understood"),
        };
    };
    placement.concurrent(&x.kafka.work, x.engine.io, .local, waiter, .{ b, it, slot }) catch {
        slot.release();
        finish(b, it);
    };
}

/// A record that never reached the producer.
fn reportFailure(b: *Broker, it: *Item, class: anole.db.Class, code: []const u8, message: []const u8) void {
    defer finish(b, it);
    if (it.flags & abi.KAFKA_F_NO_REPORT != 0) {
        log.warn("kafka {s}: record for {s} not produced: {s}", .{ b.config.name, it.topic, code });
        return;
    }
    const rec = deliveryRecord(failedDelivery(b, it.user_data, it.topic, class, code, message)) catch return;
    post(it, rec);
}

fn waiter(b: *Broker, it: *Item, slot: *Slot) std.Io.Cancelable!void {
    if (comptime !features.kafka) return;
    defer slot.release();
    defer finish(b, it);
    const io = b.engine.io;
    try slot.event.wait(io);
    var d: Delivery = .{ .user_data = it.user_data, .topic = it.topic };
    switch (slot.result) {
        .ok => |ok| {
            d.partition = ok.partition;
            d.offset = ok.offset;
            d.timestamp_ms = ok.timestamp_ms;
        },
        .failed => |f| d = failedDelivery(b, it.user_data, it.topic, switch (f.kind) {
            .unavailable => .unavailable,
            .timeout => .timeout,
            .other => .other,
        }, f.code, "the record was not delivered"),
        .pending => d = failedDelivery(b, it.user_data, it.topic, .timeout, "delivery_pending", "no result"),
    }
    if (it.flags & abi.KAFKA_F_NO_REPORT != 0) {
        if (d.status != abi.OK) log.warn("kafka {s}: record for {s} not delivered: {s}", .{ b.config.name, it.topic, d.code });
        return;
    }
    const rec = deliveryRecord(d) catch return;
    post(it, rec);
}

fn flushTask(b: *Broker, cl: *KClient, it: *Item) std.Io.Cancelable!void {
    if (comptime !features.kafka) return;
    defer finish(b, it);
    var d: Delivery = .{ .user_data = it.user_data };
    cl.producer.flush(optMs(b.config.timeout_ms)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Timeout => d = failedDelivery(b, it.user_data, "", .timeout, "delivery_pending", "records were still unsent at the timeout"),
    };
    const rec = deliveryRecord(d) catch return;
    post(it, rec);
}

// ---- WRITABLE ----------------------------------------------------------------------

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
        placement.concurrent(&x.kafka.work, x.engine.io, .local, watch, .{b}) catch b.wants.running.store(false, .release);
    }
};

/// Tells the consumers that wait when the buffer has room.
fn watch(b: *Broker) std.Io.Cancelable!void {
    const io = b.engine.io;
    while (true) {
        try io.sleep(ms(2), .awake);
        if (!b.wants.any()) {
            b.wants.running.store(false, .release);
            if (!b.wants.any() or b.wants.running.swap(true, .acq_rel)) return;
            continue;
        }
        if (!b.open.load(.acquire)) return;
        if (b.pending.load(.acquire) > b.buffer_bytes / 4) continue;
        var taken: [32]?*Consumer = undefined;
        b.wants.take(&taken);
        for (taken) |maybe| {
            const c = maybe orelse continue;
            if (c.execs.items.len == 0) continue;
            const rec = engine.newRecord(@sizeOf(abi.BrokerStatusEvent), .kafka_writable, 0) catch continue;
            const ev: *abi.BrokerStatusEvent = @ptrCast(rec.ptr);
            ev.broker = b.index;
            ev.status = abi.BROKER_WRITABLE;
            c.execs.items[0].postRecord(rec, false);
        }
    }
}

// ---------------------------------------------------------------------------
// Groups

/// A group member in flight: one allocation holding the command and the
/// copied names.
pub const Group = struct {
    cmd: Command = .{ .run = start },
    b: *Broker,
    c: *Consumer,
    x: *Exec,
    handle: u64 = 0,
    user_data: u64,
    group: []const u8 = "",
    topics: []const []const u8 = &.{},
    instance_id: ?[]const u8 = null,
    start_at: u32 = 0,
    assignor: u32 = 0,
    max_batch: u32 = 500,
    prefetch_bytes: u32 = 1 << 20,
    session_ms: u32 = 45_000,
    rebalance_ms: u32 = 300_000,
    commit_ms: u32 = 5_000,
    wake: std.Io.Event = .unset,
    closing: std.atomic.Value(bool) = .init(false),
    draining: std.atomic.Value(bool) = .init(false),
    arena: std.heap.ArenaAllocator,

    fn free(g: *Group) void {
        var arena = g.arena;
        arena.deinit();
    }

    fn start(cmd: *Command, x: *Exec) void {
        const g: *Group = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return g.release();
        placement.concurrent(&x.kafka.work, x.engine.io, .local, groupTask, .{ x, g }) catch g.release();
    }

    /// Drops the handle and frees the group.
    fn release(g: *Group) void {
        const st = &g.b.engine.kafka_state;
        st.groups.acquire();
        const h = Handle.decode(g.handle);
        if (st.groups.get(h)) |_| st.groups.drop(h.slot);
        st.groups.release();
        g.free();
    }
};

/// `anole_kafka_subscribe`.
pub fn subscribe(b: *Broker, c: *Consumer, opts: abi.KafkaSubscribeOptions, user_data: u64) CallError!u64 {
    if (comptime !features.kafka) return error.Unsupported;
    if (c.engine != b.engine) return error.Invalid;
    try checkOpen(b);
    if (opts.reserved != 0 or opts.start > abi.KAFKA_START_EARLIEST or opts.assignor > abi.KAFKA_ASSIGN_ROUNDROBIN) return error.Invalid;
    if (opts.group.len == 0 or opts.ntopics == 0 or opts.ntopics > 1024) return error.Invalid;
    const topics_in = (opts.topics orelse return error.Invalid)[0..opts.ntopics];
    for (topics_in) |t| if (t.len == 0 or t.len > 249) return error.Invalid;
    if (c.execs.items.len == 0) return error.State;
    const x = c.execs.items[c.next_db.fetchAdd(1, .monotonic) % c.execs.items.len];

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const g = try a.create(Group);
    const topics = try a.alloc([]const u8, topics_in.len);
    for (topics_in, topics) |t, *o| o.* = try a.dupe(u8, t.slice());
    g.* = .{
        .b = b,
        .c = c,
        .x = x,
        .user_data = user_data,
        .group = try a.dupe(u8, opts.group.slice()),
        .topics = topics,
        .instance_id = if (opts.instance_id.len > 0) try a.dupe(u8, opts.instance_id.slice()) else null,
        .start_at = opts.start,
        .assignor = opts.assignor,
        .max_batch = if (opts.max_batch > 0) opts.max_batch else 500,
        .prefetch_bytes = if (opts.prefetch_bytes > 0) opts.prefetch_bytes else 1 << 20,
        .session_ms = if (opts.session_timeout_ms > 0) opts.session_timeout_ms else 45_000,
        .rebalance_ms = if (opts.rebalance_timeout_ms > 0) opts.rebalance_timeout_ms else 300_000,
        .commit_ms = if (opts.commit_interval_ms > 0) opts.commit_interval_ms else 5_000,
        .arena = arena,
    };
    errdefer g.free();
    const st = &b.engine.kafka_state;
    st.groups.acquire();
    const slot = st.groups.alloc(g) catch {
        st.groups.release();
        return error.OutOfMemory;
    };
    g.handle = nats_cap.handleOf(.kafka_group, slot.index, slot.gen, x.index);
    st.groups.release();
    x.post(&g.cmd);
    return g.handle;
}

/// `anole_kafka_group_close` and releasing a group handle (a cleanup call).
pub fn groupClose(e: *Engine, hv: u64) void {
    const h = Handle.decode(hv);
    const st = &e.kafka_state;
    st.groups.acquire();
    defer st.groups.release();
    const entry = st.groups.get(h) orelse return;
    const g = entry.value;
    g.closing.store(true, .release);
    g.wake.set(e.io);
}

/// The drain started: every group finishes up and ends with
/// `ANOLE_BROKER_END_DRAINED`.
pub fn draining(e: *Engine) void {
    const st = &e.kafka_state;
    st.groups.acquire();
    defer st.groups.release();
    for (st.groups.entries.items) |*entry| {
        if (!entry.live) continue;
        entry.value.draining.store(true, .release);
        entry.value.closing.store(true, .release);
        entry.value.wake.set(e.io);
    }
}

fn unusedHandler(_: ?*anyopaque, _: *KMsg) anyerror!void {}

fn groupTask(x: *Exec, g: *Group) std.Io.Cancelable!void {
    const e = x.engine;
    var reason: u32 = abi.BROKER_END_CLOSED;
    var message: []const u8 = "";
    var stopped_by_engine = false;
    if (comptime features.kafka) {
        const cl = g.b.client.?;
        const kc = cl.consumeRaw(.{
            .group = g.group,
            .topics = g.topics,
            .start = if (g.start_at == abi.KAFKA_START_EARLIEST) .earliest else .latest,
            .instance_id = g.instance_id,
            .members = 1,
            .assignor = if (g.assignor == abi.KAFKA_ASSIGN_ROUNDROBIN) .roundrobin else .range,
            .session_timeout = ms(g.session_ms),
            .rebalance_timeout = ms(g.rebalance_ms),
            .prefetch_bytes = g.prefetch_bytes,
            .commit_interval = ms(g.commit_ms),
            .timeout = null,
            .batch_handler = batchHandler,
            .max_batch = g.max_batch,
            .on_assign = onAssign,
            .on_revoke = onRevoke,
        }, unusedHandler, g) catch |err| {
            if (endRecord(g.handle, g.user_data, abi.BROKER_END_FAILED, @errorName(err))) |rec| x.postRecord(rec, false) else |_| {}
            g.release();
            return;
        };
        while (true) {
            g.wake.waitTimeout(e.io, .{ .duration = .{ .raw = ms(250), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    stopped_by_engine = true;
                    break;
                },
            };
            if (g.closing.load(.acquire)) {
                reason = if (g.draining.load(.acquire)) abi.BROKER_END_DRAINED else abi.BROKER_END_CLOSED;
                break;
            }
            if (kc.started and kc.active.load(.acquire) == 0) {
                reason = abi.BROKER_END_FAILED;
                message = "the group member stopped (its instance id is in use, or it failed)";
                break;
            }
        }
        kc.stop();
        if (!stopped_by_engine) {
            const deadline = std.Io.Clock.Timestamp.now(e.io, .awake).addDuration(.{ .raw = ms(@as(i64, g.rebalance_ms) + 5_000), .clock = .awake });
            kc.join(deadline);
        }
    }
    if (!stopped_by_engine) {
        if (endRecord(g.handle, g.user_data, reason, message)) |rec| x.postRecord(rec, false) else |_| {}
    }
    g.release();
}

fn groupOf(context: ?*anyopaque) *Group {
    return @ptrCast(@alignCast(context.?));
}

fn onAssign(context: ?*anyopaque, parts: []const anole.kafka.protocol.TopicPartition) void {
    partitionsEvent(.kafka_assign, context, parts);
}

fn onRevoke(context: ?*anyopaque, parts: []const anole.kafka.protocol.TopicPartition) void {
    partitionsEvent(.kafka_revoke, context, parts);
}

fn partitionsEvent(typ: abi.EventType, context: ?*anyopaque, parts: []const anole.kafka.protocol.TopicPartition) void {
    const g = groupOf(context);
    var topics: std.ArrayList([]const u8) = .empty;
    defer topics.deinit(gpa);
    var numbers: std.ArrayList(i32) = .empty;
    defer numbers.deinit(gpa);
    for (parts) |p| {
        topics.append(gpa, p.topic) catch return;
        numbers.append(gpa, p.partition) catch return;
    }
    const rec = assignRecord(typ, g.handle, g.user_data, topics.items, numbers.items) catch return;
    g.x.postRecord(rec, false);
}

// ---- batches -----------------------------------------------------------------------

/// What a batch's delivery task waits for: the consumer's answer.
pub const BatchWait = struct {
    event: std.Io.Event = .unset,
    retry: bool = false,
    delay_ms: u32 = 0,
    resolved: bool = false,
};

fn batchHandler(context: ?*anyopaque, view: *const anole.kafka.impl.consumer.BatchView) std.Io.Cancelable!anole.kafka.impl.consumer.BatchAnswer {
    const g = groupOf(context);
    const e = g.b.engine;
    const st = &e.kafka_state;
    const Answer = anole.kafka.impl.consumer.BatchAnswer;
    var w: BatchWait = .{};
    st.batches.acquire();
    const slot = st.batches.alloc(&w) catch {
        st.batches.release();
        return Answer{ .retry = 1000 };
    };
    st.batches.release();
    const execs = g.c.execs.items;
    if (execs.len == 0) {
        st.batches.acquire();
        st.batches.drop(slot.index);
        st.batches.release();
        return Answer{ .retry = 1000 };
    }
    const x = execs[@as(usize, @intCast(view.partition)) % execs.len];
    const handle = nats_cap.handleOf(.kafka_batch, slot.index, slot.gen, x.index);
    defer {
        st.batches.acquire();
        st.batches.drop(slot.index);
        st.batches.release();
    }
    const rec = recordsRecord(handle, g.user_data, g.handle, view.topic, view.partition, view.high_watermark, view.recs) catch return Answer{ .retry = 1000 };
    x.postRecord(rec, true);
    w.event.wait(e.io) catch |err| {
        // Stale: the session ended and the rebalance timeout passed.
        st.batches.acquire();
        w.resolved = true;
        st.batches.release();
        return err;
    };
    return if (w.retry) Answer{ .retry = w.delay_ms } else Answer.done;
}

/// `anole_kafka_batch_done`: processed (a cleanup-style call: OK when the
/// batch is over).
pub fn batchDone(e: *Engine, hv: u64) void {
    const st = &e.kafka_state;
    st.batches.acquire();
    defer st.batches.release();
    const entry = st.batches.get(Handle.decode(hv)) orelse return;
    const w = entry.value;
    if (w.resolved) return;
    w.retry = false;
    w.resolved = true;
    w.event.set(e.io);
}

/// `anole_kafka_batch_retry` and releasing a batch handle (= retry now).
pub fn batchRetry(e: *Engine, hv: u64, delay_ms: u32) CallError!void {
    if (comptime !features.kafka) return error.Unsupported;
    const st = &e.kafka_state;
    st.batches.acquire();
    defer st.batches.release();
    const entry = st.batches.get(Handle.decode(hv)) orelse return error.Gone;
    const w = entry.value;
    if (w.resolved) return error.Gone;
    w.retry = true;
    w.delay_ms = delay_ms;
    w.resolved = true;
    w.event.set(e.io);
}

// ---------------------------------------------------------------------------

test "kafka capi: a records event lays out records, header spans and bytes" {
    if (comptime !features.kafka) return error.SkipZigTest;
    const hs = [_]KHeader{
        .{ .key = "h1", .value = "v1" },
        .{ .key = "h2", .value = null },
    };
    const recs = [_]KRec{
        .{ .offset = 7, .timestamp_ms = 100, .key = "k", .value = "value", .headers = &hs },
        .{ .offset = 8, .timestamp_ms = 101, .key = null, .value = null, .headers = &.{} },
    };
    const rec = try recordsRecord(0x1234, 5, 6, "topic", 2, 99, &recs);
    defer engine.freeRecord(rec.ptr);
    const ev: *const abi.KafkaRecordsEvent = @ptrCast(rec.ptr);
    try std.testing.expectEqual(@as(u32, 80), ev.ev.type);
    try std.testing.expectEqual(@as(u64, 0x1234), ev.ev.handle);
    try std.testing.expectEqual(@as(u32, 2), ev.nrecords);
    try std.testing.expectEqual(@as(i32, 2), ev.partition);
    try std.testing.expectEqual(@as(i64, 99), ev.high_watermark);
    try std.testing.expectEqualStrings("topic", rec[ev.topic.off..][0..ev.topic.len]);
    const out: [*]const abi.KafkaRecord = @ptrCast(@alignCast(rec.ptr + ev.records_off));
    try std.testing.expectEqual(@as(i64, 7), out[0].offset);
    try std.testing.expectEqualStrings("k", rec[out[0].key.off..][0..out[0].key.len]);
    try std.testing.expectEqualStrings("value", rec[out[0].value.off..][0..out[0].value.len]);
    try std.testing.expectEqual(@as(u32, 2), out[0].nheaders);
    try std.testing.expectEqual(@as(u32, 0), out[0].flags);
    try std.testing.expectEqual(abi.KAFKA_REC_F_NULL_KEY | abi.KAFKA_REC_F_NULL_VALUE, out[1].flags);
    const spans: [*]const abi.Span = @ptrCast(@alignCast(rec.ptr + out[0].headers_off));
    try std.testing.expectEqualStrings("h1", rec[spans[0].off..][0..spans[0].len]);
    try std.testing.expectEqualStrings("v1", rec[spans[1].off..][0..spans[1].len]);
    try std.testing.expectEqual(@as(u32, 0), spans[3].len);
}

test "kafka capi: a delivery event and an assign event" {
    const rec = try deliveryRecord(.{ .user_data = 9, .partition = 3, .offset = 42, .timestamp_ms = 5, .topic = "t", .code = "MESSAGE_TOO_LARGE", .status = abi.E_BROKER, .http_status = 500, .error_class = .other });
    defer engine.freeRecord(rec.ptr);
    const ev: *const abi.KafkaDeliveryEvent = @ptrCast(rec.ptr);
    try std.testing.expectEqual(@as(u32, 81), ev.ev.type);
    try std.testing.expectEqual(@as(i64, 42), ev.offset);
    try std.testing.expectEqualStrings("MESSAGE_TOO_LARGE", rec[ev.error_code.off..][0..ev.error_code.len]);
    const topics = [_][]const u8{ "a", "bb" };
    const parts = [_]i32{ 0, 4 };
    const arec = try assignRecord(.kafka_assign, 1, 2, &topics, &parts);
    defer engine.freeRecord(arec.ptr);
    const aev: *const abi.KafkaAssignEvent = @ptrCast(arec.ptr);
    try std.testing.expectEqual(@as(u32, 2), aev.nentries);
    const entries: [*]const abi.KafkaPartition = @ptrCast(@alignCast(arec.ptr + aev.entries_off));
    try std.testing.expectEqual(@as(i32, 4), entries[1].partition);
    try std.testing.expectEqualStrings("bb", arec[entries[1].topic.off..][0..entries[1].topic.len]);
}
