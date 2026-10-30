//! Kafka (`-Dkafka`): a client of Anole's own on std.Io, built from the
//! protocol specification (Apache Kafka's message definitions). No
//! librdkafka: it starts threads of its own and links OpenSSL, and nothing
//! it does can be canceled by a request's deadline.
//!
//!     const App = struct { kafka: *anole.kafka.Client };
//!     state.kafka = try app.kafka(.{}); // KAFKA_BOOTSTRAP_SERVERS, else localhost:9092
//!
//!     fn publish(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         try app.kafka.send(req, .{ .topic = "events", .key = "user-7", .value = req.body() });
//!         res.status = .accepted;
//!     }
//!
//!     fn onEvent(app: *App, msg: *anole.kafka.Msg) !void {
//!         const event = try msg.json(Event);
//!         _ = try app.db.exec(msg, "INSERT INTO events ...", .{event.id}); // a Msg is a call context
//!     }
//!     try state.kafka.consume(&app, .{ .group = "workers", .topics = &.{"events"} }, onEvent);
//!
//! What it does (v1): produce (acks 0, 1 or all, idempotent by default,
//! batching with `linger`, gzip/zstd/lz4 compression, Java's partitioner),
//! consumer groups (the classic protocol, eager rebalance, range and
//! roundrobin assignors, static membership, commit of processed offsets, a
//! dead letter topic), TLS (BoringSSL, mutual TLS) and SASL PLAIN,
//! SCRAM-SHA-256 and SCRAM-SHA-512. A consumer decompresses none, gzip,
//! zstd, lz4 and snappy. Later: transactions, KIP-848, cooperative-sticky,
//! the admin API, OAUTHBEARER and GSSAPI, fetch-from-follower.
//!
//! Writes never wait for the network: `send` queues the record and returns
//! (a full buffer is an error, `waitWritable` waits for room); `produce`
//! waits for the broker's acknowledgement, bounded by `timeout`; failures of
//! a queued record are logged and counted. Every call takes the request (or
//! an `anole.db.Ctx`, or a `Msg`) first and fails with `anole.db.Error`.
//!
//! The partitioner is Java's (murmur2 of the key), so keys land where Java
//! producers put them; librdkafka's default differs.
const std = @import("std");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");
const scram = @import("../net/scram.zig");
const net = @import("../net/client_stream.zig");

pub const protocol = @import("protocol.zig");
pub const records = @import("records.zig");
pub const compress = @import("compress.zig");
pub const murmur2 = @import("murmur2.zig");
pub const cluster = @import("cluster.zig");
pub const sasl = @import("sasl.zig");
const producer_mod = @import("producer.zig");
const consumer_mod = @import("consumer.zig");
const Telemetry = @import("telemetry.zig").Telemetry;
const testHold = @import("test_hold.zig").testHold;
/// An in-process broker for tests: `anole.kafka.testing.FakeBroker`.
pub const testing = @import("testing.zig");

const log = std.log.scoped(.anole);
const Duration = std.Io.Duration;

pub const Header = records.Header;
pub const Msg = consumer_mod.Msg;
pub const ConsumeOptions = consumer_mod.ConsumeOptions;
/// The engine room, for the C ABI (src/capi/kafka.zig).
pub const impl = struct {
    pub const producer = producer_mod;
    pub const consumer = consumer_mod;
};
pub const Assignor = consumer_mod.Assignor;

/// What every call fails with, besides what the call says: `anole.db.Error`
/// (the status each class gives), a cancel, or memory.
pub const Error = db.Error || std.Io.Cancelable || error{OutOfMemory};

pub const Options = struct {
    /// host:port list. Null: KAFKA_BOOTSTRAP_SERVERS, else KAFKA_URL
    /// (kafka://, kafka+ssl:// comma-separated, Heroku's form), else
    /// localhost:9092.
    brokers: ?[]const []const u8 = null,
    client_id: []const u8 = "anole",
    /// Metrics and logs name; null: "kafka".
    label: ?[]const u8 = null,
    /// Null: plain (kafka+ssl:// URLs turn it on).
    tls: ?Tls = null,
    sasl: ?Sasl = null,
    /// Bounds `produce` (with its acknowledgement) and `flush`.
    timeout: ?Duration = .fromSeconds(30),
    connect_timeout: Duration = .fromSeconds(10),
    /// One broker request.
    request_timeout: Duration = .fromSeconds(30),
    metadata_max_age: Duration = .fromSeconds(300),
    connect_at_start: bool = false,
    producer: Producer = .{},
    errors: db.ErrorMap = .{},
    /// Registers a metadata ping with `app.health` (`/readyz`).
    readiness: bool = true,
    environ: ?std.process.Environ = null,

    pub const Tls = struct {
        ca: ?dusty.Ca = null,
        client_certificate: ?dusty.Cert = null,
        insecure_skip_verify: bool = false,
    };
    pub const Sasl = struct {
        mechanism: enum { plain, scram_sha_256, scram_sha_512 },
        username: []const u8,
        password: []const u8,
    };
    pub const Producer = struct {
        acks: enum { none, leader, all } = .all,
        /// Needs acks = all (refused otherwise at init).
        idempotent: bool = true,
        linger: Duration = .fromMilliseconds(5),
        batch_bytes: u32 = 16 * 1024,
        /// Records buffered and not yet acknowledged, at most: past it
        /// `send` fails; past half, `writable()` is false.
        buffer_bytes: u32 = 32 * 1024 * 1024,
        compression: enum { none, gzip, zstd, lz4 } = .none,
        /// How long a record is retried before its delivery fails.
        delivery_timeout: Duration = .fromSeconds(30),
        /// How long a record for a topic the cluster does not list yet
        /// waits for it to appear (the broker's auto-create, or an admin
        /// call still spreading), capped by the call's timeout; then
        /// UNKNOWN_TOPIC_OR_PARTITION.
        metadata_wait: Duration = .fromSeconds(5),
        max_request_bytes: u32 = 1024 * 1024,
    };
};

pub const Record = struct {
    topic: []const u8,
    key: ?[]const u8 = null,
    value: ?[]const u8,
    headers: []const Header = &.{},
    /// Null: by key (murmur2), or sticky for no key.
    partition: ?i32 = null,
    /// Null: now.
    timestamp_ms: ?i64 = null,
};

pub const Delivery = struct {
    topic: []const u8,
    partition: i32,
    /// -1 when the broker was not asked to acknowledge (acks none).
    offset: i64,
    timestamp_ms: i64,
};

/// The bootstrap list and whether TLS was asked for by the URL, from
/// KAFKA_BOOTSTRAP_SERVERS / KAFKA_URL text: "host:9092,host2:9092" or
/// "kafka+ssl://host:9096,kafka+ssl://host2:9096".
pub fn parseBrokers(arena: std.mem.Allocator, text: []const u8) !struct { list: []const []const u8, tls: bool } {
    var list: std.ArrayList([]const u8) = .empty;
    var tls = false;
    var it = std.mem.tokenizeAny(u8, text, ", \t\n");
    while (it.next()) |raw| {
        var entry = raw;
        if (std.mem.indexOf(u8, entry, "://")) |i| {
            const scheme = entry[0..i];
            if (std.ascii.eqlIgnoreCase(scheme, "kafka+ssl") or std.ascii.eqlIgnoreCase(scheme, "ssl") or std.ascii.eqlIgnoreCase(scheme, "sasl_ssl")) tls = true;
            entry = entry[i + 3 ..];
        }
        if (entry.len == 0) continue;
        try list.append(arena, try arena.dupe(u8, entry));
    }
    return .{ .list = list.items, .tls = tls };
}

pub const Client = struct {
    /// The console's `/db` "system" for this connector.
    pub const console_system = "kafka";

    gpa: std.mem.Allocator,
    io: std.Io,
    arena_state: std.heap.ArenaAllocator,
    name: []const u8,
    errors: db.ErrorMap,
    timeout: ?Duration,
    readiness_enabled: bool,
    connect_at_start: bool,
    scram_cache: *scram.Cache,
    cluster: *cluster.Cluster,
    producer: *producer_mod.Producer,
    observer: db.Observer,
    telemetry: ?Telemetry = null,
    ready: ?db.Readiness = null,
    consumers: std.ArrayList(*consumer_mod.Consumer) = .empty,
    /// Over `consumers`, `started`, `drained` and `starting`. A leaf (L4).
    consumers_mutex: safety.Mutex(.leaf) = .init,
    started: bool = false,
    drained: bool = false,
    /// Consumer starts under way outside the lock (`start`, `consume`):
    /// `drain` waits for them (`starts_done`) before it stops and joins the
    /// consumers, so a start never races its consumer's stop.
    starting: u32 = 0,
    starts_done: safety.Condition = .init,
    /// Set by `app.kafka` under `deployment = lambda`: consumer groups are
    /// not joined (the process is frozen between invocations); producing
    /// works.
    suppress_consumers: bool = false,

    /// Validates the options and prepares the connections; nothing connects
    /// before the first call (unless `connect_at_start`).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Client {
        const p = options.producer;
        if (p.idempotent and p.acks != .all) {
            log.err("invalid option kafka.producer.idempotent: needs acks = .all", .{});
            return error.InvalidOptions;
        }
        if (p.batch_bytes == 0 or p.buffer_bytes < p.batch_bytes or p.max_request_bytes < 1024) {
            log.err("invalid option kafka.producer: batch_bytes, buffer_bytes or max_request_bytes", .{});
            return error.InvalidOptions;
        }
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.arena_state = .init(gpa);
        errdefer self.arena_state.deinit();
        const arena = self.arena_state.allocator();

        var tls_from_url = false;
        const brokers: []const []const u8 = blk: {
            if (options.brokers) |b| {
                const copy = try arena.alloc([]const u8, b.len);
                for (b, copy) |s, *o| o.* = try arena.dupe(u8, s);
                break :blk copy;
            }
            const text = db.env(options.environ, "KAFKA_BOOTSTRAP_SERVERS") orelse db.env(options.environ, "KAFKA_URL") orelse "localhost:9092";
            const parsed = try parseBrokers(arena, text);
            tls_from_url = parsed.tls;
            break :blk parsed.list;
        };
        if (brokers.len == 0) return error.NoBrokers;

        const scram_cache = try gpa.create(scram.Cache);
        errdefer gpa.destroy(scram_cache);
        scram_cache.* = .{};

        var tls_settings: ?net.ConnectOptions.Tls = null;
        if (options.tls) |t| {
            tls_settings = .{ .ca = t.ca orelse .system, .client_certificate = t.client_certificate, .insecure_skip_verify = t.insecure_skip_verify };
        } else if (tls_from_url) tls_settings = .{};
        const credential: ?sasl.Credential = if (options.sasl) |s| .{
            .mechanism = switch (s.mechanism) {
                .plain => .plain,
                .scram_sha_256 => .scram_sha_256,
                .scram_sha_512 => .scram_sha_512,
            },
            .username = try arena.dupe(u8, s.username),
            .password = try arena.dupe(u8, s.password),
        } else null;
        const settings: cluster.Settings = .{
            .client_id = try arena.dupe(u8, options.client_id),
            .tls = tls_settings,
            .sasl = credential,
            .connect_timeout = options.connect_timeout,
            .request_timeout = options.request_timeout,
            .metadata_max_age = options.metadata_max_age,
            .scram_cache = scram_cache,
        };
        const cl = try cluster.Cluster.init(gpa, io, settings, brokers);
        errdefer cl.deinit();
        const prod = try producer_mod.Producer.init(gpa, io, cl, .{
            .acks = switch (p.acks) {
                .none => .none,
                .leader => .leader,
                .all => .all,
            },
            .idempotent = p.idempotent,
            .linger = p.linger,
            .batch_bytes = p.batch_bytes,
            .buffer_bytes = p.buffer_bytes,
            .compression = switch (p.compression) {
                .none => .none,
                .gzip => .gzip,
                .zstd => .zstd,
                .lz4 => .lz4,
            },
            .delivery_timeout = p.delivery_timeout,
            .metadata_wait = p.metadata_wait,
            .max_request_bytes = p.max_request_bytes,
            .request_timeout = options.request_timeout,
        });
        errdefer prod.deinit();

        const name = try arena.dupe(u8, options.label orelse "kafka");
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = self.arena_state,
            .name = name,
            .errors = options.errors,
            .timeout = options.timeout,
            .readiness_enabled = options.readiness,
            .connect_at_start = options.connect_at_start,
            .scram_cache = scram_cache,
            .cluster = cl,
            .producer = prod,
            .observer = .{ .system = .kafka, .name = name },
        };
        return self;
    }

    /// Drains (a consumer's records in flight finish, offsets are committed,
    /// the producer flushes; at most 10 s) and frees everything.
    pub fn deinit(self: *Client) void {
        self.drain(std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromSeconds(10), .clock = .awake }));
        for (self.consumers.items) |c| c.destroy();
        self.consumers.deinit(self.gpa);
        self.producer.deinit();
        self.cluster.deinit();
        self.gpa.destroy(self.scram_cache);
        const gpa = self.gpa;
        self.arena_state.deinit();
        gpa.destroy(self);
    }

    /// What the app observes with, once serving starts (`app.kafka` does
    /// this for you): metrics, spans for calls in traced requests, the
    /// `/readyz` check. Also starts the consumers registered so far.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        if (self.isStarted()) return;
        self.observer = try db.Observer.init(.kafka, self.name, registry, tracer);
        if (registry) |r| {
            self.telemetry = try Telemetry.init(r, self.name);
            self.producer.tel = &self.telemetry.?;
        }
        if (health) |h| if (self.readiness_enabled) {
            self.ready = .{ .io = self.io, .context = self, .ping = pingFn };
            try self.ready.?.register(h, "kafka");
        };
        if (self.connect_at_start) {
            self.cluster.refresh(&.{}, false) catch |err| {
                log.err("kafka: cannot reach the brokers at start: {t}", .{err});
                return error.KafkaUnavailable;
            };
        }
        // The consumers added before `started` is set are started here, the
        // ones after it by `consume`: each by exactly one of the two. A start
        // spawns (and may suspend), and the log line may wait: both after
        // the lock (L2, L3).
        const n = blk: {
            self.consumers_mutex.lockUncancelable(self.io);
            defer self.consumers_mutex.unlock(self.io);
            // Set only once the observer, telemetry, health check and the
            // start's refresh succeeded: a failed start can be retried, and
            // consume does not start groups added before a successful start.
            self.started = true;
            break :blk self.consumers.items.len;
        };
        if (self.suppress_consumers) {
            if (n > 0) log.info("kafka \"{s}\": lambda deployment joins no consumer groups here; producing works", .{self.name});
            return;
        }
        // The list only grows until `deinit`: an index read under the lock
        // names a live consumer.
        for (0..n) |i| {
            const c = blk: {
                self.consumers_mutex.lockUncancelable(self.io);
                defer self.consumers_mutex.unlock(self.io);
                // A drain that began meanwhile stops what is started: start
                // no more.
                if (self.drained) return;
                self.starting += 1;
                break :blk self.consumers.items[i];
            };
            defer self.endStart();
            try c.start();
        }
    }

    /// Ends a consumer start counted in `starting` (no lock held).
    fn endStart(self: *Client) void {
        self.consumers_mutex.lockUncancelable(self.io);
        defer self.consumers_mutex.unlock(self.io);
        self.starting -= 1;
        if (self.starting == 0) self.starts_done.broadcast(self.io);
    }

    fn isStarted(self: *Client) bool {
        self.consumers_mutex.lockUncancelable(self.io);
        defer self.consumers_mutex.unlock(self.io);
        return self.started;
    }

    /// Adds a consumer; true when it is to be started now (serving has
    /// started), which the caller does after the lock and ends with
    /// `endStart`. `error.Closing` once a drain began: the list `drain`
    /// joins without the lock grows no more.
    fn addConsumer(self: *Client, c: *consumer_mod.Consumer) error{ OutOfMemory, Closing }!bool {
        self.consumers_mutex.lockUncancelable(self.io);
        defer self.consumers_mutex.unlock(self.io);
        if (self.drained) return error.Closing;
        try self.consumers.append(self.gpa, c);
        const now = self.started and !self.drained and !self.suppress_consumers;
        if (now) self.starting += 1;
        return now;
    }

    fn pingFn(context: *anyopaque, _: std.Io) std.Io.Cancelable!bool {
        const self: *Client = @ptrCast(@alignCast(context));
        return self.cluster.ping();
    }

    /// Whether the brokers answer a metadata request.
    pub fn ping(self: *Client) bool {
        return self.cluster.ping();
    }

    fn host(self: *Client) consumer_mod.Host {
        return .{ .gpa = self.gpa, .io = self.io, .cluster = self.cluster, .producer = self.producer, .tel = if (self.telemetry != null) &self.telemetry.? else null };
    }

    /// Stops the consumers (in-flight records finish, offsets are
    /// committed, groups are left) and flushes the producer, by `deadline`.
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        self.consumers_mutex.lockUncancelable(self.io);
        if (self.drained) {
            self.consumers_mutex.unlock(self.io);
            return;
        }
        self.drained = true;
        // No start begins from here on; the ones under way finish first.
        if (self.starting > 0) {
            self.consumers_mutex.unlock(self.io);
            testHold(self.io, .drain_waits);
            self.consumers_mutex.lockUncancelable(self.io);
        }
        while (self.starting > 0) self.starts_done.waitUncancelable(self.io, &self.consumers_mutex);
        for (self.consumers.items) |c| c.stop();
        // `addConsumer` refuses from `drained` on: the list read after the
        // lock is the one stopped above.
        const consumers = self.consumers.items;
        self.consumers_mutex.unlock(self.io);
        for (consumers) |c| c.join(deadline);
        const left = std.Io.Clock.Timestamp.now(self.io, .awake).durationTo(deadline).raw;
        self.producer.flush(if (left.nanoseconds > 0) left else .fromMilliseconds(1)) catch |err| switch (err) {
            error.Timeout => log.warn("kafka: records were still unsent at the drain deadline", .{}),
            error.Canceled => self.io.recancel(),
        };
    }

    // -----------------------------------------------------------------------
    // Producing

    /// Queues a record and returns. `ServiceUnavailable` (code
    /// "buffer_full") when `producer.buffer_bytes` are waiting. A later
    /// delivery failure is logged and counted.
    pub fn send(self: *Client, c: anytype, record: Record) Error!void {
        const call = self.observer.start(c);
        const r = self.sendInner(c, record);
        call.end(c, "publish", record.topic, if (r) |_| null else |e| e);
        return r;
    }

    fn sendInner(self: *Client, c: anytype, record: Record) Error!void {
        const headers = try self.withTrace(c, record);
        self.producer.append(record.topic, record.key, record.value, headers, record.partition, self.timestampOf(record)) catch |err|
            return self.appendError(c, err);
    }

    /// Queues a record and waits for its acknowledgement, bounded by
    /// `Options.timeout`. A timeout is `GatewayTimeout` (code
    /// "delivery_pending": the record may still be delivered).
    pub fn produce(self: *Client, c: anytype, record: Record) Error!Delivery {
        return self.produceWith(c, record, self.timeout);
    }

    fn produceWith(self: *Client, c: anytype, record: Record, timeout: ?Duration) Error!Delivery {
        const call = self.observer.start(c);
        const r = self.produceInner(c, record, internal.callTimeout(timeout, null));
        call.end(c, "publish", record.topic, if (r) |_| null else |e| e);
        return r;
    }

    fn produceInner(self: *Client, c: anytype, record: Record, timeout: ?Duration) Error!Delivery {
        const headers = try self.withTrace(c, record);
        const outcome = self.producer.produceWait(record.topic, record.key, record.value, headers, record.partition, self.timestampOf(record), timeout) catch |err|
            return self.appendError(c, err);
        return switch (outcome) {
            .ok => |d| .{ .topic = record.topic, .partition = d.partition, .offset = d.offset, .timestamp_ms = d.timestamp_ms },
            .failed => |f| self.deliveryFailed(c, f),
            .timeout => internal.fail(c, self.errors, .{
                .system = .kafka,
                .class = .timeout,
                .code = "delivery_pending",
                .message = "no acknowledgement within the timeout; the record may still be delivered",
            }),
        };
    }

    /// Whether the buffer has room (less than half full).
    pub fn writable(self: *Client) bool {
        return self.producer.writable();
    }

    /// Waits until `writable()`, at most `timeout`.
    pub fn waitWritable(self: *Client, c: anytype, timeout: ?Duration) Error!void {
        const started: std.Io.Clock.Timestamp = .now(c.io, .awake);
        while (!self.producer.writable()) {
            if (timeout) |t| if (started.durationTo(.now(c.io, .awake)).raw.nanoseconds >= t.nanoseconds)
                return internal.fail(c, self.errors, .{ .system = .kafka, .class = .unavailable, .code = "buffer_full", .message = "the producer's buffer stayed full" });
            try c.io.sleep(.fromMilliseconds(5), .awake);
        }
    }

    /// Sends everything buffered now (no linger) and waits for the acks.
    pub fn flush(self: *Client, c: anytype) Error!void {
        return self.flushWith(c, self.timeout);
    }

    fn flushWith(self: *Client, c: anytype, timeout: ?Duration) Error!void {
        self.producer.flush(internal.callTimeout(timeout, null)) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return internal.fail(c, self.errors, .{ .system = .kafka, .class = .timeout, .code = "delivery_pending", .message = "records were still unsent at the timeout" }),
        };
    }

    /// The same calls with a timeout of their own.
    pub fn with(self: *Client, opts: CallOptions) Call {
        return .{ .client = self, .timeout = opts.timeout };
    }

    pub const CallOptions = struct {
        /// `.max` for none; null: the client's.
        timeout: ?Duration = null,
    };

    pub const Call = struct {
        client: *Client,
        timeout: ?Duration,

        fn bound(self: Call) ?Duration {
            return self.timeout orelse self.client.timeout;
        }
        pub fn produce(self: Call, c: anytype, record: Record) Error!Delivery {
            return self.client.produceWith(c, record, self.bound());
        }
        pub fn send(self: Call, c: anytype, record: Record) Error!void {
            return self.client.send(c, record);
        }
        pub fn flush(self: Call, c: anytype) Error!void {
            return self.client.flushWith(c, self.bound());
        }
    };

    fn timestampOf(self: *Client, record: Record) i64 {
        if (record.timestamp_ms) |t| return t;
        return @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    /// The record's headers, plus `traceparent` when the call is made in a
    /// traced request that did not set one (`observe.trace.outgoing`: a
    /// caller's unsampled context passed on unrecorded stays `-00`).
    fn withTrace(self: *Client, c: anytype, record: Record) Error![]const Header {
        _ = self;
        const req = internal.requestOf(c) orelse return record.headers;
        var buf: [55]u8 = undefined;
        const tp = observe.trace.outgoing(req, &buf) orelse return record.headers;
        for (record.headers) |h| if (std.ascii.eqlIgnoreCase(h.key, "traceparent")) return record.headers;
        const out = try c.arena.alloc(Header, record.headers.len + 1);
        @memcpy(out[0..record.headers.len], record.headers);
        out[record.headers.len] = .{ .key = "traceparent", .value = try c.arena.dupe(u8, tp) };
        return out;
    }

    fn deliveryFailed(self: *Client, c: anytype, f: producer_mod.Failure) Error {
        const class: db.Class = switch (f.kind) {
            .unavailable => .unavailable,
            .timeout => .timeout,
            .other => .other,
        };
        return internal.fail(c, self.errors, .{ .system = .kafka, .class = class, .code = f.code, .message = "the record was not delivered" });
    }

    fn appendError(self: *Client, c: anytype, err: producer_mod.AppendError) Error {
        const D = db.ErrorDetail;
        const detail: D = switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.BufferFull => .{ .system = .kafka, .class = .unavailable, .code = "buffer_full", .message = "the producer's buffer is full" },
            error.TooLarge => .{ .system = .kafka, .class = .other, .code = "MESSAGE_TOO_LARGE", .message = "the record is larger than max_request_bytes" },
            error.UnknownTopic => .{ .system = .kafka, .class = .other, .code = "UNKNOWN_TOPIC_OR_PARTITION", .message = "the topic does not exist" },
            error.BadPartition => .{ .system = .kafka, .class = .other, .code = "invalid_partition", .message = "the partition is not one of the topic's" },
            error.Closing => .{ .system = .kafka, .class = .unavailable, .code = "closing", .message = "the client is shutting down" },
            error.Timeout => .{ .system = .kafka, .class = .timeout, .code = "timeout", .message = "the broker did not answer in time" },
            error.ConnectionLost, error.NoBroker, error.UnsupportedBroker => .{ .system = .kafka, .class = .unavailable, .code = "no_broker", .message = "no broker could be reached" },
            error.AuthFailed => .{ .system = .kafka, .class = .other, .code = "SASL_AUTHENTICATION_FAILED", .message = "the broker refused the credentials" },
            error.ProtocolError, error.Truncated, error.Invalid => .{ .system = .kafka, .class = .other, .code = "protocol", .message = "the broker's answer was not understood" },
        };
        return internal.fail(c, self.errors, detail);
    }

    // -----------------------------------------------------------------------
    // Consuming

    /// Consumes `topics` as a member of `group` once serving starts (at
    /// once when it already has): `handler` is `fn (*Msg) !void` or
    /// `fn (*App, *Msg) !void`, with `server` the `anole.Server` (or any
    /// value with the app's state as `.ctx`). A record is retried in place
    /// and then dead-lettered or skipped (`ConsumeOptions.retry`,
    /// `dead_letter`); offsets are committed once handled. Once the
    /// client's drain began, `error.Closing`.
    pub fn consume(self: *Client, server: anytype, opts: ConsumeOptions, comptime handler: anytype) !void {
        const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
        if (params.len < 1 or params.len > 2) @compileError("a Kafka handler is fn (*Msg) !void or fn (*App, *Msg) !void");
        const Thunk = struct {
            fn call(context: ?*anyopaque, msg: *Msg) anyerror!void {
                if (comptime params.len == 1) return handler(msg);
                const App = @typeInfo(params[0].?).pointer.child;
                const app: *App = @ptrCast(@alignCast(context.?));
                return handler(app, msg);
            }
        };
        const context: ?*anyopaque = if (comptime params.len == 2) appOf(server) else null;
        const c = try consumer_mod.Consumer.create(self.host(), opts, Thunk.call, context);
        const start_now = self.addConsumer(c) catch |err| {
            c.destroy();
            return err;
        };
        // In the list from here on: the client frees it, a failed start
        // included.
        if (start_now) {
            defer self.endStart();
            try c.start();
        }
    }

    /// `consume` for callers that bring their own function pointers (the C
    /// ABI): the consumer joins once serving starts (at once when it
    /// already has). It lives, stopped or not, until the client is freed.
    /// Once the client's drain began, `error.Closing`.
    pub fn consumeRaw(self: *Client, opts: ConsumeOptions, handler: consumer_mod.HandlerFn, context: ?*anyopaque) !*consumer_mod.Consumer {
        const c = try consumer_mod.Consumer.create(self.host(), opts, handler, context);
        const start_now = self.addConsumer(c) catch |err| {
            c.destroy();
            return err;
        };
        // In the list from here on: the client frees it, a failed start
        // included.
        if (start_now) {
            defer self.endStart();
            try c.start();
        }
        return c;
    }

    fn appOf(server: anytype) *anyopaque {
        const T = @typeInfo(@TypeOf(server)).pointer.child;
        if (comptime @hasField(T, "server")) return @ptrCast(server.server.ctx);
        return @ptrCast(server.ctx);
    }
};

test {
    _ = protocol;
    _ = records;
    _ = compress;
    _ = murmur2;
    _ = cluster;
    _ = @import("producer.zig");
    _ = consumer_mod;
    _ = @import("telemetry.zig");
    _ = testing;
    _ = @import("fake_test.zig");
    _ = @import("live_test.zig");
}

test "kafka: every call compiles for a Ctx and for a Msg" {
    const Probe = struct {
        fn run(k: *Client, c: *db.Ctx, m: *Msg) !void {
            _ = try k.produce(c, .{ .topic = "t", .value = null });
            try k.send(c, .{ .topic = "t", .value = "v" });
            try k.waitWritable(c, null);
            try k.flush(c);
            _ = try k.with(.{ .timeout = .fromSeconds(1) }).produce(c, .{ .topic = "t", .value = null });
            try k.with(.{}).flush(c);
            try k.with(.{}).send(c, .{ .topic = "t", .value = null });
            _ = try k.produce(m, .{ .topic = "t", .value = m.value });
            try k.send(m, .{ .topic = "t", .value = m.value });
            _ = m.header("traceparent");
            _ = try m.json(struct { id: u32 });
            _ = k.writable();
            k.drain(std.Io.Clock.Timestamp.now(c.io, .awake));
        }
        fn app(_: *u32, _: *Msg) !void {}
        fn plain(_: *Msg) !void {}
        const Fake = struct { ctx: *u32 };
        const Wrapper = struct { server: *Fake };
        fn consume(k: *Client, server: *Wrapper) !void {
            try k.consume(server, .{ .group = "g", .topics = &.{"t"} }, app);
            try k.consume(server, .{ .group = "g", .topics = &.{"t"} }, plain);
        }
    };
    _ = &Probe.run;
    _ = &Probe.consume;
}

test "parseBrokers: plain lists, Heroku's URL form, and the TLS schemes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseBrokers(arena_state.allocator(), "k1:9092, k2:9092");
    try std.testing.expectEqual(@as(usize, 2), a.list.len);
    try std.testing.expect(!a.tls);
    try std.testing.expectEqualStrings("k2:9092", a.list[1]);
    const b = try parseBrokers(arena_state.allocator(), "kafka+ssl://h1:9096,kafka+ssl://h2:9096");
    try std.testing.expect(b.tls);
    try std.testing.expectEqualStrings("h1:9096", b.list[0]);
    const d = try parseBrokers(arena_state.allocator(), "kafka://solo");
    try std.testing.expect(!d.tls);
    try std.testing.expectEqualStrings("solo", d.list[0]);
}
