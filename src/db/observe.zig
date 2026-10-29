//! The hooks a connector's registration (`app.postgres`, `app.sqlite`,
//! `app.mongodb`) wires up: a readiness check for `/readyz`, Prometheus
//! metrics, and a client span per call in a traced request.
const std = @import("std");
const dusty = @import("dusty");
const observe = @import("../observe/root.zig");
const db = @import("root.zig");
const internal = @import("internal.zig");

const metrics = observe.metrics;

/// A readiness check that pings the database at most once per `ttl`;
/// probes in between get the last answer, and concurrent ones wait for the
/// ping in flight rather than start their own.
///
///     state.ready = .{ .io = io, .context = pg, .ping = Db.ping };
///     try state.ready.register(app.health(.{}), "postgres");
pub const Readiness = struct {
    io: std.Io,
    context: *anyopaque,
    /// True when the database answers. Bounded by the connector (a short
    /// timeout of its own): `/readyz` waits for it.
    ping: *const fn (context: *anyopaque, io: std.Io) bool,
    ttl: std.Io.Duration = .fromSeconds(1),
    mutex: std.Io.Mutex = .init,
    checked_at: ?std.Io.Clock.Timestamp = null,
    ready: bool = false,

    /// Adds the check to `health` under `name`. `self` must stay put.
    pub fn register(self: *Readiness, health: *observe.Health, name: []const u8) !void {
        try health.addCheck(name, check, self);
    }

    /// The `observe.Health` check.
    pub fn check(context: ?*anyopaque) bool {
        const self: *Readiness = @ptrCast(@alignCast(context.?));
        self.mutex.lock(self.io) catch {
            self.io.recancel();
            return false;
        };
        defer self.mutex.unlock(self.io);
        const now: std.Io.Clock.Timestamp = .now(self.io, .awake);
        if (self.checked_at) |at| {
            if (at.durationTo(now).raw.nanoseconds < self.ttl.nanoseconds) return self.ready;
        }
        self.ready = self.ping(self.context, self.io);
        self.checked_at = .now(self.io, .awake);
        return self.ready;
    }
};

/// Buckets for query and acquire times, in seconds: finer than HTTP's at
/// the low end, where most queries land.
pub const buckets = [_]f64{ 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 };

/// One database's series, labelled `system` and `db`:
/// `anole_db_query_duration_seconds`, `anole_db_errors_total{error}`,
/// `anole_db_pool_acquire_duration_seconds`,
/// `anole_db_pool_connections{state="idle"|"in_use"}` and
/// `anole_db_pool_waiting`. Every database of a registry shares the
/// metric names.
pub const Metrics = struct {
    system: []const u8,
    name: []const u8,
    query: *metrics.Histogram,
    acquire: *metrics.Histogram,
    idle: *metrics.Gauge,
    in_use: *metrics.Gauge,
    waiting: *metrics.Gauge,
    errors: *metrics.Family(metrics.Counter),

    /// `name` (the `db` label) must outlive `registry`.
    pub fn init(registry: *metrics.Registry, system: db.System, name: []const u8) !Metrics {
        const s = @tagName(system);
        const connections = try registry.gauge("anole_db_pool_connections", "Database connections open, by state.", &.{ "system", "db", "state" });
        return .{
            .system = s,
            .name = name,
            .query = (try registry.histogram("anole_db_query_duration_seconds", "Time a database call took.", &.{ "system", "db" }, &buckets)).with(&.{ s, name }),
            .acquire = (try registry.histogram("anole_db_pool_acquire_duration_seconds", "Time a call waited for a pooled connection.", &.{ "system", "db" }, &buckets)).with(&.{ s, name }),
            .idle = connections.with(&.{ s, name, "idle" }),
            .in_use = connections.with(&.{ s, name, "in_use" }),
            .waiting = (try registry.gauge("anole_db_pool_waiting", "Calls waiting for a pooled connection.", &.{ "system", "db" })).with(&.{ s, name }),
            .errors = try registry.counter("anole_db_errors_total", "Database calls that failed, by error.", &.{ "system", "db", "error" }),
        };
    }
};

/// What a connector reports through: metrics when the app has them, spans
/// when it traces. Without either, every call is a no-op.
pub const Observer = struct {
    system: db.System,
    /// The database's name: the `db` label, and `db.namespace` on spans.
    name: []const u8,
    metrics: ?Metrics = null,
    tracer: ?*observe.trace.Exporter = null,

    /// `registry` and `tracer` are the app's, when it has them
    /// (`app.metrics`, `app.tracing`); `name` must outlive them. A call
    /// that ends after the app has closed its exporter (`App.deinit`
    /// closes it first) has its span dropped and counted
    /// (`Exporter.close`).
    pub fn init(system: db.System, name: []const u8, registry: ?*metrics.Registry, tracer: ?*observe.trace.Exporter) !Observer {
        return .{
            .system = system,
            .name = name,
            .metrics = if (registry) |r| try Metrics.init(r, system, name) else null,
            .tracer = tracer,
        };
    }

    /// Which spans it makes: database, messaging (NATS, Kafka), rpc (S3) or
    /// mail (SMTP).
    pub fn kind(self: *const Observer) db.System.Kind {
        return self.system.kind();
    }

    /// Marks the start of a call (a statement, a command) made with `c`.
    pub fn start(self: *const Observer, c: anytype) Call {
        return .{
            .observer = self,
            .awake = .now(c.io, .awake),
            .real_ns = if (self.tracer != null) std.Io.Clock.real.now(c.io).nanoseconds else 0,
        };
    }

    /// A call waited `waited` for a pooled connection.
    pub fn acquired(self: *const Observer, waited: std.Io.Duration) void {
        if (self.metrics) |m| m.acquire.observeDuration(waited);
    }

    /// The pool's connections changed: `idle` and `in_use` are deltas
    /// (opened idle: `(1, 0)`; taken: `(-1, 1)`; closed while in use:
    /// `(0, -1)`).
    pub fn connections(self: *const Observer, idle: i64, in_use: i64) void {
        const m = self.metrics orelse return;
        if (idle != 0) m.idle.add(idle);
        if (in_use != 0) m.in_use.add(in_use);
    }

    /// A call started (`1`) or stopped (`-1`) waiting for a connection.
    pub fn waiting(self: *const Observer, delta: i64) void {
        if (self.metrics) |m| m.waiting.add(delta);
    }
};

/// One call in progress, from `Observer.start`.
pub const Call = struct {
    observer: *const Observer,
    awake: std.Io.Clock.Timestamp,
    real_ns: i96,

    /// Records the call: its duration, its error (`err`, null when it
    /// succeeded), and a span when `c` is a traced request. `operation` is
    /// the statement's first keyword or the command's name ("SELECT",
    /// "find"); `target` the table or collection, when known.
    ///
    ///     const call = self.observer.start(req);
    ///     const result = self.query(req, sql, args);
    ///     call.end(req, "SELECT", null, if (result) |_| null else |e| e);
    pub fn end(self: Call, c: anytype, operation: []const u8, target: ?[]const u8, err: ?anyerror) void {
        self.endWith(c, operation, target, err, .{});
    }

    /// What an S3 or SMTP span carries besides `end`'s.
    pub const Detail = struct {
        /// S3: the object key (`aws.s3.key`).
        key: ?[]const u8 = null,
        /// SMTP: the envelope's recipients (`smtp.recipients`).
        recipients: u32 = 0,
        /// SMTP: the message's Message-ID (`smtp.message_id`), when known.
        message_id: ?[]const u8 = null,
    };

    /// `end`, with `detail` on the span (S3, SMTP).
    pub fn endWith(self: Call, c: anytype, operation: []const u8, target: ?[]const u8, err: ?anyerror, detail: Detail) void {
        const o = self.observer;
        if (o.metrics) |m| {
            m.query.observeDuration(self.awake.durationTo(.now(c.io, .awake)).raw);
            if (err) |e| m.errors.with(&.{ m.system, m.name, @errorName(e) }).inc();
        }
        const exporter = o.tracer orelse return;
        const req = internal.requestOf(c) orelse return;
        var span_db: observe.trace.Span.Db = .init(
            @tagName(o.system),
            o.name,
            operation,
            target,
            if (err) |e| @errorName(e) else null,
        );
        switch (o.kind()) {
            .database => {},
            .messaging => span_db.kind = .messaging,
            // S3: `S3.<operation>` with the AWS SDK conventions' attributes.
            .rpc => {
                span_db.kind = .rpc;
                if (detail.key) |k| span_db.setDetail(k);
            },
            // SMTP: "smtp send", the recipients and the Message-ID.
            .mail => {
                span_db.kind = .mail;
                span_db.count = detail.recipients;
                if (detail.message_id) |id| span_db.setDetail(id);
            },
        }
        exporter.child(req, self.real_ns, std.Io.Clock.real.now(c.io).nanoseconds, span_db);
    }
};

const testing = std.testing;

test "Readiness: one ping per ttl, the answer kept in between" {
    const Fake = struct {
        pings: u32 = 0,
        up: bool = true,
        fn ping(context: *anyopaque, _: std.Io) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.pings += 1;
            return self.up;
        }
    };
    var fake: Fake = .{};
    // A ttl no run of the test outlives while the answer must be kept, so
    // the kept answer never depends on how fast the machine is.
    var ready: Readiness = .{ .io = testing.io, .context = &fake, .ping = Fake.ping, .ttl = .fromSeconds(600) };
    var health = observe.Health.init(.{});
    try ready.register(&health, "db");
    try testing.expect(health.checks[0].ready(health.checks[0].ctx));
    fake.up = false;
    try testing.expect(Readiness.check(&ready));
    try testing.expectEqual(@as(u32, 1), fake.pings);
    // Then a 10 ms ttl, and time passes on purpose past it, 6x the ttl
    // (a lower bound). An injected clock replaces it if Readiness gets one.
    ready.ttl = .fromMilliseconds(10);
    try testing.io.sleep(.fromMilliseconds(60), .awake);
    try testing.expect(!Readiness.check(&ready));
    try testing.expectEqual(@as(u32, 2), fake.pings);
}

test "Observer: metrics shared by two databases, and a child span in a traced request" {
    const gpa = testing.allocator;
    var registry = metrics.Registry.init(gpa, testing.io);
    defer registry.deinit();
    var client = dusty.Client.init(gpa, testing.io, .{});
    defer client.deinit();
    // Never started: what is submitted stays in its queue.
    var exporter = try observe.trace.Exporter.init(gpa, testing.io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t" });
    defer exporter.deinit();

    const main_db = try Observer.init(.postgresql, "main", &registry, &exporter);
    const files = try Observer.init(.sqlite, "files", &registry, null);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = testing.io, ._parser = undefined, ._transport = undefined };
    req.trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
    req.span_id = "00f067aa0ba902b7";

    main_db.start(&req).end(&req, "SELECT", "posts", null);
    main_db.start(&req).end(&req, "INSERT", "posts", error.Conflict);
    main_db.connections(1, 0);
    main_db.connections(-1, 1);
    main_db.acquired(.fromMilliseconds(2));
    var ctx: db.Ctx = .{ .io = testing.io, .arena = arena_state.allocator() };
    files.start(&ctx).end(&ctx, "SELECT", null, null);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try registry.render(&out.writer);
    const text = out.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "# TYPE anole_db_query_duration_seconds histogram"));
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_query_duration_seconds_count{system=\"postgresql\",db=\"main\"} 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_query_duration_seconds_count{system=\"sqlite\",db=\"files\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_errors_total{system=\"postgresql\",db=\"main\",error=\"Conflict\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"postgresql\",db=\"main\",state=\"in_use\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "anole_db_pool_connections{system=\"postgresql\",db=\"main\",state=\"idle\"} 0") != null);

    // Two child spans of the request's, the second failed.
    var spans: [4]observe.trace.Span = undefined;
    try testing.expectEqual(@as(usize, 2), try exporter.queue.get(testing.io, &spans, 0));
    try testing.expectEqualStrings("SELECT posts", spans[0].name[0..spans[0].name_len]);
    try testing.expectEqualStrings(req.trace_id, &spans[0].trace_id);
    try testing.expectEqualStrings(req.span_id, &spans[0].parent_span_id.?);
    const body = try observe.trace.encode(arena_state.allocator(), "t", spans[0..2]);
    try testing.expect(std.mem.indexOf(u8, body, "\"kind\":3") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"key\":\"db.system.name\",\"value\":{\"stringValue\":\"postgresql\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"key\":\"db.collection.name\",\"value\":{\"stringValue\":\"posts\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "{\"key\":\"error.type\",\"value\":{\"stringValue\":\"Conflict\"}}],\"status\":{\"code\":2}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"http.request.method\"") == null);

    // An untraced request gets no span.
    req.trace_id = "";
    main_db.start(&req).end(&req, "SELECT", null, null);
    try testing.expectEqual(@as(usize, 0), try exporter.queue.get(testing.io, &spans, 0));
}

test "Observer: S3 spans follow the AWS SDK conventions, SMTP spans carry recipients and the Message-ID" {
    const gpa = testing.allocator;
    var client = dusty.Client.init(gpa, testing.io, .{});
    defer client.deinit();
    var exporter = try observe.trace.Exporter.init(gpa, testing.io, .{ .http = &client }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t" });
    defer exporter.deinit();
    const media = try Observer.init(.s3, "media", null, &exporter);
    const mail = try Observer.init(.smtp, "mail", null, &exporter);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var req: dusty.Request = .{ .arena = arena_state.allocator(), .io = testing.io, ._parser = undefined, ._transport = undefined };
    req.trace_id = "4bf92f3577b34da6a3ce929d0e0e4736";
    req.span_id = "00f067aa0ba902b7";

    media.start(&req).endWith(&req, "GetObject", "photos", null, .{ .key = "2026/cat.jpg" });
    media.start(&req).endWith(&req, "HeadBucket", "photos", error.NotFound, .{});
    mail.start(&req).endWith(&req, "send", null, null, .{ .recipients = 3, .message_id = "<a1@example.com>" });

    var spans: [4]observe.trace.Span = undefined;
    try testing.expectEqual(@as(usize, 3), try exporter.queue.get(testing.io, &spans, 0));
    try testing.expectEqualStrings("S3.GetObject", spans[0].name[0..spans[0].name_len]);
    try testing.expectEqualStrings("smtp send", spans[2].name[0..spans[2].name_len]);
    const body = try observe.trace.encode(arena_state.allocator(), "t", spans[0..3]);
    const attr = struct {
        fn has(text: []const u8, key: []const u8, value: []const u8) bool {
            var buf: [160]u8 = undefined;
            const want = std.fmt.bufPrint(&buf, "{{\"key\":\"{s}\",\"value\":{{\"stringValue\":\"{s}\"}}}}", .{ key, value }) catch return false;
            return std.mem.indexOf(u8, text, want) != null;
        }
    };
    try testing.expect(attr.has(body, "rpc.system", "aws-api"));
    try testing.expect(attr.has(body, "rpc.service", "S3"));
    try testing.expect(attr.has(body, "rpc.method", "GetObject"));
    try testing.expect(attr.has(body, "aws.s3.bucket", "photos"));
    try testing.expect(attr.has(body, "aws.s3.key", "2026/cat.jpg"));
    try testing.expect(attr.has(body, "error.type", "NotFound"));
    try testing.expect(std.mem.indexOf(u8, body, "{\"key\":\"smtp.recipients\",\"value\":{\"intValue\":\"3\"}}") != null);
    try testing.expect(attr.has(body, "smtp.message_id", "<a1@example.com>"));
    // The bucket-only call has no key, and no span has database attributes.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "aws.s3.key"));
    try testing.expect(std.mem.indexOf(u8, body, "db.system.name") == null);
}
