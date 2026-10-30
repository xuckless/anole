//! OpenTelemetry tracing for the server: a span per request, its context
//! from the W3C `traceparent` header when the caller sent one (a new trace
//! otherwise), and batches of finished spans sent to an OTLP/HTTP collector
//! as JSON (`POST {endpoint}/v1/traces`).
//!
//! In an app, `_ = try app.tracing(.{ .service_name = "api" });` does all
//! of this (see `TracingOptions` for the endpoint). By hand:
//!
//!     var exporter = try anole.observe.trace.Exporter.init(gpa, app.io(), app.client(), .{
//!         .endpoint = "http://otel-collector:4318", .service_name = "api" });
//!     defer exporter.deinit();
//!     try exporter.start();  // the batching task
//!     app.use(anole.observe.trace.Middleware.init(&exporter));
//!
//! Handlers see `req.trace_id` and `req.span_id`; `outgoing(req, &buf)`
//! makes the `traceparent` to pass downstream.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const common = @import("common.zig");
const Client = @import("../client.zig").Client;

/// A parsed `traceparent` (version 00).
pub const Context = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    sampled: bool,

    /// Null for an absent or malformed header (all-zero IDs included).
    pub fn parse(header: []const u8) ?Context {
        const h = std.mem.trim(u8, header, " \t");
        if (h.len < 55 or h[2] != '-' or h[35] != '-' or h[52] != '-') return null;
        if (!isHex(h[0..2]) or std.mem.eql(u8, h[0..2], "ff")) return null;
        // Version 00 is exactly 55 characters; later ones may add fields.
        if (std.mem.eql(u8, h[0..2], "00") and h.len != 55) return null;
        const tid = h[3..35];
        const sid = h[36..52];
        if (!isHex(tid) or !isHex(sid) or !isHex(h[53..55])) return null;
        if (allZero(tid) or allZero(sid)) return null;
        const flags = std.fmt.parseInt(u8, h[53..55], 16) catch return null;
        var c: Context = .{ .trace_id = undefined, .span_id = undefined, .sampled = flags & 1 == 1 };
        for (tid, 0..) |ch, i| c.trace_id[i] = std.ascii.toLower(ch);
        for (sid, 0..) |ch, i| c.span_id[i] = std.ascii.toLower(ch);
        return c;
    }

    /// Writes the context as a `traceparent` value (`{f}`).
    pub fn format(self: Context, w: *std.Io.Writer) !void {
        try w.print("00-{s}-{s}-{s}", .{ &self.trace_id, &self.span_id, if (self.sampled) "01" else "00" });
    }
};

fn isHex(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn allZero(s: []const u8) bool {
    for (s) |ch| if (ch != '0') return false;
    return true;
}

fn randomHex(io: std.Io, out: []u8) void {
    var bytes: [16]u8 = undefined;
    io.random(bytes[0 .. out.len / 2]);
    const hex = "0123456789abcdef";
    for (bytes[0 .. out.len / 2], 0..) |b, i| {
        out[2 * i] = hex[b >> 4];
        out[2 * i + 1] = hex[b & 15];
    }
}

/// The `traceparent` for a call made from within `req`'s span. Sampled,
/// unless the request was not recorded and passes its caller's unsampled
/// context on as it came.
pub fn outgoing(req: *const dusty.Request, buf: *[55]u8) ?[]const u8 {
    if (req.trace_id.len != 32 or req.span_id.len != 16) return null;
    const passed_on = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
    const sampled = if (passed_on) |p| p.sampled or !std.mem.eql(u8, &p.span_id, req.span_id) else true;
    return std.fmt.bufPrint(buf, "00-{s}-{s}-{s}", .{ req.trace_id, req.span_id, if (sampled) "01" else "00" }) catch null;
}

/// Whether `req`'s span is recorded here, so calls it makes get child
/// spans: the middleware gave it a span ID of its own, rather than
/// passing an unsampled caller's context on as it came.
pub fn recording(req: *const dusty.Request) bool {
    if (req.trace_id.len != 32 or req.span_id.len != 16) return false;
    const passed_on = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
    const p = passed_on orelse return true;
    return !std.mem.eql(u8, &p.span_id, req.span_id);
}

/// The `traceparent` of the context `req` runs in, for work it hands on
/// (a job it enqueues): its span when it is recorded here (`outgoing`),
/// else the caller's `traceparent` as it came, every trace flag kept (W3C
/// Level 2's random flag too), so an app or a binding with no tracing of
/// its own, or a request passed on unrecorded, still hands it on
/// unchanged. A later version's header is written as version 00 with its
/// IDs and flags. Null when there is neither.
pub fn current(req: *const dusty.Request, buf: *[55]u8) ?[]const u8 {
    if (recording(req)) return outgoing(req, buf);
    const header = std.mem.trim(u8, req.headers.get("traceparent") orelse return null, " \t");
    const caller = Context.parse(header) orelse return null;
    const flags = header[53..55];
    return std.fmt.bufPrint(buf, "00-{s}-{s}-{c}{c}", .{ &caller.trace_id, &caller.span_id, std.ascii.toLower(flags[0]), std.ascii.toLower(flags[1]) }) catch null;
}

/// The caller's `tracestate` to keep with `current`'s context: only
/// beside a valid `traceparent` (W3C Trace Context §3.3), trimmed, and
/// null past `max_trace_state` bytes or when empty.
pub fn currentState(req: *const dusty.Request) ?[]const u8 {
    if (Context.parse(req.headers.get("traceparent") orelse return null) == null) return null;
    const ts = std.mem.trim(u8, req.headers.get("tracestate") orelse return null, " \t");
    if (ts.len == 0 or ts.len > max_trace_state) return null;
    return ts;
}

/// The longest `tracestate` a link keeps (W3C asks vendors to pass on
/// at least 512 bytes; a longer one is left off rather than cut).
pub const max_trace_state = 512;

/// A new trace ID or span ID (`out.len` 32 or 16), in hex.
pub fn newId(io: std.Io, out: []u8) void {
    randomHex(io, out);
}

/// A finished span, as the exporter queues it.
pub const Span = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_span_id: ?[16]u8,
    /// "GET /users/:id"
    name: [96]u8,
    name_len: u8,
    start_ns: i96,
    end_ns: i96,
    method: [12]u8,
    method_len: u8,
    route: [64]u8,
    route_len: u8,
    status_code: u16,
    /// Set for a database call made while serving a request (a client
    /// span, child of the request's; `Exporter.child`), when the HTTP
    /// fields above are unused. Null for the request's own span.
    db: ?Db = null,
    /// Set for a job's run (a CONSUMER span, `Exporter.job`), when the
    /// HTTP fields above are unused. A span is copied by value, but this
    /// is owned by one copy at a time: `Exporter.job` makes it,
    /// `Exporter.submit` takes it, and the exporter frees it once the span
    /// is sent or dropped (`Exporter.release`); a test that takes spans
    /// off the queue owns them through `Exporter.takeQueued`.
    job: ?*JobRun = null,

    /// One run of a job: OpenTelemetry's messaging attributes for a
    /// process span (`messaging.system` "anole", the queue as
    /// `messaging.destination.name`, the job's id as
    /// `messaging.message.id`) and Anole's `anole.job.*`, and the link to
    /// the context that enqueued it (otelriver, opentelemetry_oban and
    /// the Sidekiq instrumentation link by default).
    ///
    /// owner: the Exporter (SAFETY.md M1), through the span that carries
    /// it. M2 class: child of the exporter (on its allocator), freed by
    /// `Exporter.release` exactly once: when the span is sent, dropped,
    /// left over at `close`, or given back by a test's `Taken.deinit`.
    pub const JobRun = struct {
        queue: []const u8,
        kind: []const u8,
        id: i64,
        attempt: u16,
        max_attempts: u16,
        /// `anole.job.outcome`: completed, retried, dead, snoozed,
        /// interrupted, lost.
        outcome: []const u8,
        /// `error.type` when the handler failed (the span's status is
        /// then ERROR); empty otherwise.
        error_type: []const u8 = "",
        /// The enqueuer's context: a link, not the parent.
        link: ?Context = null,
        /// The enqueuer's `tracestate`, kept on the link.
        link_state: []const u8 = "",
        /// The exporter's copy of the strings above (`Exporter.job`).
        _block: []u8 = &.{},
    };

    /// OpenTelemetry's database attributes, cut to fit.
    pub const Db = struct {
        /// `db.system.name`: "postgresql", "sqlite", "mongodb", "redis".
        system: [16]u8 = undefined,
        system_len: u8 = 0,
        /// `db.namespace`: the database.
        namespace: [48]u8 = undefined,
        namespace_len: u8 = 0,
        /// `db.operation.name`: "SELECT", "find".
        operation: [24]u8 = undefined,
        operation_len: u8 = 0,
        /// `db.collection.name`: the table or collection, when known.
        collection: [48]u8 = undefined,
        collection_len: u8 = 0,
        /// `error.type` (the error's name) for a failed call; empty for
        /// success.
        error_type: [32]u8 = undefined,
        error_type_len: u8 = 0,
        /// Which conventions the span follows.
        kind: Kind = .database,
        /// An RPC span's object key (`aws.s3.key`), or a mail span's
        /// `smtp.message_id`; empty when unknown.
        detail: [128]u8 = undefined,
        detail_len: u8 = 0,
        /// A mail span's `smtp.recipients`.
        count: u32 = 0,

        pub const Kind = enum {
            /// `db.*` attributes.
            database,
            /// NATS, Kafka: `system` is `messaging.system`, `collection`
            /// the destination (`messaging.destination.name`) and
            /// `operation` the `messaging.operation.type`.
            messaging,
            /// S3 (OpenTelemetry's AWS SDK conventions): span `S3.<operation>`,
            /// `rpc.system` "aws-api", `rpc.service` "S3", `rpc.method` the
            /// operation, `aws.s3.bucket` the collection, `aws.s3.key` the
            /// detail.
            rpc,
            /// SMTP (no OpenTelemetry convention; Anole's names): span
            /// "smtp <operation>", `smtp.recipients`, `smtp.message_id`.
            mail,
        };

        /// The attributes from their values, each cut to its field's size.
        pub fn init(system: []const u8, namespace: []const u8, operation: []const u8, collection: ?[]const u8, error_type: ?[]const u8) Db {
            var d: Db = .{};
            d.system_len = put(&d.system, system);
            d.namespace_len = put(&d.namespace, namespace);
            d.operation_len = put(&d.operation, operation);
            d.collection_len = put(&d.collection, collection orelse "");
            d.error_type_len = put(&d.error_type, error_type orelse "");
            return d;
        }

        /// Sets `detail` (an object key, a Message-ID), cut to fit.
        pub fn setDetail(d: *Db, detail: []const u8) void {
            d.detail_len = put(&d.detail, detail);
        }

        fn put(dst: []u8, src: []const u8) u8 {
            const n = @min(dst.len, src.len);
            @memcpy(dst[0..n], src[0..n]);
            return @intCast(n);
        }
    };
};

/// `Exporter` settings.
pub const Options = struct {
    /// The collector's OTLP/HTTP base URL ("http://localhost:4318").
    endpoint: []const u8,
    /// `service.name` on every span.
    service_name: []const u8,
    /// Spans sent per request to the collector, and how often.
    batch_size: usize = 256,
    interval: std.Io.Duration = .fromSeconds(2),
    /// Spans waiting beyond this are dropped (and counted).
    queue_len: usize = 4096,
    /// Record only requests whose caller asked for it (sampled flag), or
    /// every request.
    sample_all: bool = true,
    /// Paths the middleware does not trace: exact, or a prefix when the
    /// entry ends in `*`. `&anole.observe.probe_paths` leaves out health
    /// checks and scrapes.
    exclude: []const []const u8 = &.{},
};

/// Queues finished spans and sends them to the collector in batches from a
/// task of its own, through `client`. A full queue drops spans rather than
/// slow requests. `app.tracing(.{})` makes one owned by the server,
/// already started.
///
/// owner: whoever made it (`App` for `app.tracing`). M2 class:
/// process-wide. Teardown (M5) runs in two steps, as the OpenTelemetry
/// SDK's Shutdown: `close` sends what is queued and stops the task (it
/// needs `client`'s server still running), after which `submit`, `job`
/// and `child` are no-ops that allocate nothing and count the span as
/// dropped ("after Shutdown, subsequent calls ... SHOULD be ignored");
/// `deinit` then frees its memory, once nothing can call it any more. A
/// database, S3, SMTP or jobs observer that settles a call between the
/// two (the App closes its exporter first) has its span dropped.
pub const Exporter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    client: Client,
    options: Options,
    queue: std.Io.Queue(Span),
    buffer: []Span,
    /// The batching task: only `start` and `close` (the owner) touch it.
    task: ?std.Io.Future(void) = null,
    /// Set by `start` (release) once the task runs, read by `flush`
    /// (acquire) in place of `task`.
    started: std.atomic.Value(bool) = .init(false),
    /// Set by `deinit`: wakes the task from its pause between batches.
    closing: std.Io.Event = .unset,
    /// Set by `flush` and `deinit`: cuts the task's pause short. Only the
    /// task waits on it and resets it.
    kick: std.Io.Event = .unset,
    /// Over the flushers' wait for `finished`: `flush` waits on
    /// `progressed`; the task broadcasts after each batch and when it ends,
    /// `close` once more after the join. Never held across anything but the
    /// condition's own wait (SAFETY.md L2).
    progress_lock: safety.Mutex(.leaf) = .init,
    progressed: safety.Condition = .init,
    /// Tests: waits of a flusher for progress, counted under
    /// `progress_lock` as each starts. Test builds only.
    test_flush_waits: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {},
    /// Spans queued, and spans the task has finished with (sent or
    /// dropped): `flush` waits until `finished` reaches what `queued` was.
    queued: std.atomic.Value(u64) = .init(0),
    finished: std.atomic.Value(u64) = .init(0),
    /// Spans dropped: the queue was full, or the collector did not take
    /// them.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Spans the collector accepted.
    exported: std.atomic.Value(u64) = .init(0),
    /// M5's teardown state: alive, then closed (`close`), then dead
    /// (`deinit`).
    state: std.atomic.Value(State) = .init(.alive),

    pub const State = enum(u8) { alive, closed, dead };

    /// An exporter with its queue allocated, sending through `client` (the
    /// server's, `app.client()`). Nothing is sent until `start`. `client`'s
    /// server must outlive it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, client: Client, options: Options) !Exporter {
        const buffer = try gpa.alloc(Span, options.queue_len);
        return .{ .gpa = gpa, .io = io, .client = client, .options = options, .queue = .init(buffer), .buffer = buffer };
    }

    /// Starts the batching task.
    pub fn start(self: *Exporter) !void {
        self.task = try self.io.concurrent(run, .{self});
        self.started.store(true, .release);
    }

    /// Sends what is queued and stops the task, then takes no more spans:
    /// from here on `submit`, `job` and `child` drop theirs (counted in
    /// `dropped`) and allocate nothing, and `flush` returns at once. The
    /// memory stays until `deinit`. Once only (a second close panics in
    /// debug builds).
    pub fn close(self: *Exporter) void {
        if (self.state.cmpxchgStrong(.alive, .closed, .acq_rel, .acquire)) |was| {
            if (builtin.mode == .debug) std.debug.panic("trace.Exporter.close on an exporter already {t}", .{was});
            return;
        }
        self.closing.set(self.io);
        self.kick.set(self.io);
        self.queue.close(self.io);
        if (self.task) |*t| t.await(self.io);
        self.task = null;
        // What was never sent (no `start`, or past the task's last batch):
        // its job runs are freed, and counted as finished and dropped. No
        // span can be queued after the close.
        var rest: [16]Span = undefined;
        while (true) {
            const n = self.queue.getUncancelable(self.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |span| self.release(span);
            _ = self.dropped.fetchAdd(n, .monotonic);
            _ = self.finished.fetchAdd(n, .release);
        }
        // A flusher that saw the exporter alive returns now.
        self.notifyProgress();
    }

    /// `close`, when not done yet, then frees the queue. Nothing may use
    /// the exporter afterwards (a use panics in debug builds).
    pub fn deinit(self: *Exporter) void {
        if (self.state.load(.acquire) == .alive) self.close();
        const was = self.state.swap(.dead, .acq_rel);
        if (was == .dead) {
            if (builtin.mode == .debug) @panic("trace.Exporter.deinit twice");
            return;
        }
        self.gpa.free(self.buffer);
    }

    /// Whether spans are still taken; past `close`, the span is counted as
    /// dropped. A use after `deinit` panics in debug builds.
    fn taking(self: *Exporter) bool {
        switch (self.state.load(.acquire)) {
            .alive => return true,
            .closed => {},
            .dead => if (builtin.mode == .debug) @panic("trace.Exporter used after deinit"),
        }
        _ = self.dropped.fetchAdd(1, .monotonic);
        return false;
    }

    /// Sends the spans queued so far and waits until the collector has
    /// answered for them, or `timeout` passes (they are not lost then; the
    /// task keeps going). For a process that may be frozen after this call
    /// (AWS Lambda between invocations). Several callers may flush at once;
    /// each waits for the spans queued when it called. A canceled caller
    /// returns at once and stays canceled. Does nothing before `start`, and
    /// returns at once after `close`.
    pub fn flush(self: *Exporter, timeout: std.Io.Duration) void {
        if (self.state.load(.acquire) != .alive or !self.started.load(.acquire)) return;
        const target = self.queued.load(.acquire);
        if (self.finished.load(.acquire) >= target) return;
        const deadline = std.Io.Timeout{ .deadline = .{ .raw = std.Io.Clock.awake.now(self.io).addDuration(timeout), .clock = .awake } };
        self.progress_lock.lockUncancelable(self.io);
        defer self.progress_lock.unlock(self.io);
        // `finished` and `state` change before `notifyProgress`, which
        // takes the lock to broadcast: a change after this check wakes the
        // wait below.
        while (self.finished.load(.acquire) < target and self.state.load(.acquire) == .alive) {
            self.kick.set(self.io);
            if (comptime builtin.is_test) _ = self.test_flush_waits.fetchAdd(1, .release);
            self.progressed.waitTimeout(self.io, &self.progress_lock, deadline) catch |err| switch (err) {
                error.Timeout => return,
                // SAFETY.md C3: the caller stays canceled.
                error.Canceled => {
                    self.io.recancel();
                    return;
                },
            };
        }
    }

    /// Wakes every flusher to look again: after `finished` or `state`
    /// changed.
    fn notifyProgress(self: *Exporter) void {
        self.progress_lock.lockUncancelable(self.io);
        defer self.progress_lock.unlock(self.io);
        self.progressed.broadcast(self.io);
    }

    /// Queues a client span for a call made while serving `req` (a
    /// database query), as a child of the request's span, from
    /// `start_ns` to `end_ns` (real clock). Nothing when the request is
    /// not recorded (`recording`); after `close`, counted as dropped.
    pub fn child(self: *Exporter, req: *const dusty.Request, start_ns: i96, end_ns: i96, db: Span.Db) void {
        if (!recording(req)) return;
        if (!self.taking()) return;
        var span: Span = undefined;
        @memcpy(&span.trace_id, req.trace_id[0..32]);
        randomHex(req.io, &span.span_id);
        span.parent_span_id = req.span_id[0..16].*;
        const collection = db.collection[0..db.collection_len];
        const operation = db.operation[0..db.operation_len];
        const name = switch (db.kind) {
            .rpc => std.fmt.bufPrint(&span.name, "{s}.{s}", .{ rpcService(db.system[0..db.system_len]), operation }),
            .mail => std.fmt.bufPrint(&span.name, "{s} {s}", .{ db.system[0..db.system_len], operation }),
            .database, .messaging => std.fmt.bufPrint(&span.name, "{s} {s}", .{
                operation,
                if (collection.len > 0) collection else db.namespace[0..db.namespace_len],
            }),
        } catch span.name[0..0];
        span.name_len = @intCast(std.mem.trimEnd(u8, name, " ").len);
        span.start_ns = start_ns;
        span.end_ns = end_ns;
        span.method_len = 0;
        span.route_len = 0;
        span.status_code = 0;
        span.db = db;
        span.job = null;
        self.submit(span);
    }

    /// Queues the CONSUMER span of one run of a job, `process <queue>`,
    /// from `start_ns` to `end_ns` (real clock): a root of trace
    /// `trace_id` (the run's own, `newId`) with `span_id`, linked to
    /// `run.link` (OpenTelemetry's messaging conventions: the process span
    /// SHOULD link to the creation context, a parent is NOT RECOMMENDED by
    /// default). `run`'s slices are copied. Recorded when the exporter
    /// records every request (`sample_all`), or when the enqueuer's
    /// context was sampled (`recordsJob`). After `close`, counted as
    /// dropped, with nothing allocated.
    pub fn job(self: *Exporter, trace_id: [32]u8, span_id: [16]u8, start_ns: i96, end_ns: i96, attrs: Span.JobRun) void {
        if (!self.taking()) return;
        const owned = self.ownJob(attrs) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };
        // SAFETY: every field the encoder reads for a job span is set below (`method`, `route` stay unread at length 0).
        var span: Span = undefined;
        span.trace_id = trace_id;
        span.span_id = span_id;
        span.parent_span_id = null;
        const name = std.fmt.bufPrint(&span.name, "process {s}", .{owned.queue}) catch span.name[0..0];
        span.name_len = @intCast(name.len);
        span.start_ns = start_ns;
        span.end_ns = end_ns;
        span.method_len = 0;
        span.route_len = 0;
        span.status_code = 0;
        span.db = null;
        span.job = owned;
        self.submit(span);
    }

    /// Whether a run of a job whose enqueuer's context is `link` is
    /// recorded: always under `sample_all`, else when that context was
    /// sampled, as the middleware records a request.
    pub fn recordsJob(self: *const Exporter, link: ?Context) bool {
        if (self.options.sample_all) return true;
        return if (link) |l| l.sampled else false;
    }

    fn ownJob(self: *Exporter, attrs: Span.JobRun) !*Span.JobRun {
        const total = attrs.queue.len + attrs.kind.len + attrs.outcome.len + attrs.error_type.len + attrs.link_state.len;
        const bytes = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(bytes);
        const owned = try self.gpa.create(Span.JobRun);
        var at: usize = 0;
        const copy = struct {
            fn f(dst: []u8, pos: *usize, src: []const u8) []const u8 {
                @memcpy(dst[pos.*..][0..src.len], src);
                defer pos.* += src.len;
                return dst[pos.*..][0..src.len];
            }
        }.f;
        owned.* = attrs;
        owned.queue = copy(bytes, &at, attrs.queue);
        owned.kind = copy(bytes, &at, attrs.kind);
        owned.outcome = copy(bytes, &at, attrs.outcome);
        owned.error_type = copy(bytes, &at, attrs.error_type);
        owned.link_state = copy(bytes, &at, attrs.link_state);
        owned._block = bytes;
        return owned;
    }

    /// Spans a test took off the queue (`takeQueued`): owned by this
    /// value until `deinit` releases them, once.
    pub const Taken = struct {
        exporter: *Exporter,
        spans: []Span,

        /// Releases every span (what each owns); afterwards `spans` is
        /// empty, so a second call releases nothing.
        pub fn deinit(t: *Taken) void {
            for (t.spans) |span| t.exporter.release(span);
            t.spans = &.{};
        }
    };

    /// For tests: up to `buf.len` queued spans, taken off the queue
    /// without waiting, owned by the result (`defer taken.deinit()`), so a
    /// test can neither leak a job run nor release one twice.
    pub fn takeQueued(self: *Exporter, buf: []Span) std.Io.QueueClosedError!Taken {
        const n = try self.queue.getUncancelable(self.io, buf, 0);
        return .{ .exporter = self, .spans = buf[0..n] };
    }

    /// Frees what `span` owns (a job run's attributes): once it is sent,
    /// dropped, left over at `close`, or given back by `Taken.deinit`.
    pub fn release(self: *Exporter, span: Span) void {
        const attrs = span.job orelse return;
        self.gpa.free(attrs._block);
        self.gpa.destroy(attrs);
    }

    /// Queues `span`, taking what it owns (`span.job`): the exporter frees
    /// it once the span is sent or dropped, so the caller's copy must not
    /// be released or submitted again. After `close` the span is dropped
    /// (counted) and what it owns freed at once.
    pub fn submit(self: *Exporter, span: Span) void {
        if (!self.taking()) {
            self.release(span);
            return;
        }
        const n = self.queue.putUncancelable(self.io, &.{span}, 0) catch 0;
        if (n == 0) {
            self.release(span);
            _ = self.dropped.fetchAdd(1, .monotonic);
        } else _ = self.queued.fetchAdd(1, .release);
    }

    fn run(self: *Exporter) void {
        // However the task ends (closed, canceled), flushers look again.
        defer self.notifyProgress();
        const batch = self.gpa.alloc(Span, self.options.batch_size) catch return;
        defer self.gpa.free(batch);
        while (true) {
            // Whatever is there, or wait for one span (closing ends it).
            const n = self.queue.getUncancelable(self.io, batch, 1) catch {
                // Closed: one last drain of what is left.
                const rest = self.queue.getUncancelable(self.io, batch, 0) catch 0;
                if (rest > 0) self.send(batch[0..rest]);
                for (batch[0..rest]) |span| self.release(span);
                _ = self.finished.fetchAdd(rest, .release);
                return;
            };
            self.send(batch[0..n]);
            for (batch[0..n]) |span| self.release(span);
            _ = self.finished.fetchAdd(n, .release);
            self.notifyProgress();
            // A pause before the next batch, cut short by `deinit` and
            // `flush`.
            if (n < batch.len) self.kick.waitTimeout(self.io, .{ .duration = .{
                .raw = self.options.interval,
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (!self.closing.isSet()) self.kick.reset();
        }
    }

    fn send(self: *Exporter, spans: []const Span) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = encode(arena, self.options.service_name, spans) catch return;
        const url = std.fmt.allocPrint(arena, "{s}/v1/traces", .{std.mem.trimEnd(u8, self.options.endpoint, "/")}) catch return;
        var headers = dusty.Headers.init(arena, 2) catch return;
        headers.put("Content-Type", "application/json") catch return;
        var response = self.client.http.fetch(url, .{ .method = .post, .headers = &headers, .body = body }) catch {
            _ = self.dropped.fetchAdd(spans.len, .monotonic);
            return;
        };
        defer response.deinit();
        if (response.status() == .ok) _ = self.exported.fetchAdd(spans.len, .monotonic) else _ = self.dropped.fetchAdd(spans.len, .monotonic);
    }
};

/// `rpc.service` (and the span name's prefix) for an RPC span's system.
fn rpcService(system: []const u8) []const u8 {
    return if (std.mem.eql(u8, system, "s3")) "S3" else system;
}

/// OTLP/HTTP JSON (opentelemetry-proto's JSON mapping: IDs in hex, times
/// as decimal strings).
pub fn encode(arena: std.mem.Allocator, service: []const u8, spans: []const Span) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"resourceSpans\":[{{\"resource\":{{\"attributes\":[{{\"key\":\"service.name\",\"value\":{{\"stringValue\":{f}}}}}]}},", .{std.json.fmt(service, .{})});
    try w.writeAll("\"scopeSpans\":[{\"scope\":{\"name\":\"anole\"},\"spans\":[");
    for (spans, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"traceId\":\"{s}\",\"spanId\":\"{s}\",", .{ &s.trace_id, &s.span_id });
        if (s.parent_span_id) |p| try w.print("\"parentSpanId\":\"{s}\",", .{&p});
        if (s.job) |j| {
            try encodeJob(w, s, j);
            continue;
        }
        if (s.db) |d| {
            if (d.kind == .rpc or d.kind == .mail) {
                try w.print("\"name\":{f},\"kind\":3,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
                const system = d.system[0..d.system_len];
                const detail = d.detail[0..d.detail_len];
                if (d.kind == .rpc) {
                    const aws = std.mem.eql(u8, system, "s3");
                    try w.print("\"attributes\":[{{\"key\":\"rpc.system\",\"value\":{{\"stringValue\":{f}}}}}", .{std.json.fmt(if (aws) "aws-api" else system, .{})});
                    const rpc_attrs = [_]struct { []const u8, []const u8 }{
                        .{ "rpc.service", rpcService(system) },
                        .{ "rpc.method", d.operation[0..d.operation_len] },
                        .{ if (aws) "aws.s3.bucket" else "rpc.target", d.collection[0..d.collection_len] },
                        .{ if (aws) "aws.s3.key" else "rpc.detail", detail },
                        .{ "error.type", d.error_type[0..d.error_type_len] },
                    };
                    for (rpc_attrs) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
                } else {
                    try w.print("\"attributes\":[{{\"key\":\"smtp.recipients\",\"value\":{{\"intValue\":\"{d}\"}}}}", .{d.count});
                    const mail_attrs = [_]struct { []const u8, []const u8 }{
                        .{ "smtp.message_id", detail },
                        .{ "error.type", d.error_type[0..d.error_type_len] },
                    };
                    for (mail_attrs) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
                }
                try w.print("],\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (d.error_type_len > 0) 2 else 0)});
                continue;
            }
            if (d.kind == .messaging) {
                const op = d.operation[0..d.operation_len];
                const kind: u8 = if (std.mem.eql(u8, op, "publish")) 4 else if (std.mem.eql(u8, op, "process") or std.mem.eql(u8, op, "receive")) 5 else 3;
                try w.print("\"name\":{f},\"kind\":{d},\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), kind, s.start_ns, s.end_ns });
                try w.print("\"attributes\":[{{\"key\":\"messaging.system\",\"value\":{{\"stringValue\":{f}}}}}", .{std.json.fmt(d.system[0..d.system_len], .{})});
                const msg_attrs = [_]struct { []const u8, []const u8 }{
                    .{ "messaging.destination.name", d.collection[0..d.collection_len] },
                    .{ "messaging.operation.type", op },
                    .{ "error.type", d.error_type[0..d.error_type_len] },
                };
                for (msg_attrs) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
                try w.print("],\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (d.error_type_len > 0) 2 else 0)});
                continue;
            }
            try w.print("\"name\":{f},\"kind\":3,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
            try w.print("\"attributes\":[{{\"key\":\"db.system.name\",\"value\":{{\"stringValue\":{f}}}}}", .{std.json.fmt(d.system[0..d.system_len], .{})});
            const optional = [_]struct { []const u8, []const u8 }{
                .{ "db.namespace", d.namespace[0..d.namespace_len] },
                .{ "db.operation.name", d.operation[0..d.operation_len] },
                .{ "db.collection.name", d.collection[0..d.collection_len] },
                .{ "error.type", d.error_type[0..d.error_type_len] },
            };
            for (optional) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
            try w.print("],\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (d.error_type_len > 0) 2 else 0)});
            continue;
        }
        try w.print("\"name\":{f},\"kind\":2,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
        try w.print("\"attributes\":[{{\"key\":\"http.request.method\",\"value\":{{\"stringValue\":{f}}}}},", .{std.json.fmt(s.method[0..s.method_len], .{})});
        try w.print("{{\"key\":\"http.route\",\"value\":{{\"stringValue\":{f}}}}},", .{std.json.fmt(s.route[0..s.route_len], .{})});
        try w.print("{{\"key\":\"http.response.status_code\",\"value\":{{\"intValue\":\"{d}\"}}}}],", .{s.status_code});
        // ERROR for 5xx (the server's failure), unset otherwise.
        try w.print("\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (s.status_code >= 500) 2 else 0)});
    }
    try w.writeAll("]}]}]}");
    return out.written();
}

/// A job run's span: CONSUMER, its link, the messaging and `anole.job.*`
/// attributes, ERROR with `error.type` when the handler failed.
fn encodeJob(w: *std.Io.Writer, s: Span, j: *const Span.JobRun) !void {
    try w.print("\"name\":{f},\"kind\":5,\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",", .{ std.json.fmt(s.name[0..s.name_len], .{}), s.start_ns, s.end_ns });
    if (j.link) |l| {
        try w.print("\"links\":[{{\"traceId\":\"{s}\",\"spanId\":\"{s}\",", .{ &l.trace_id, &l.span_id });
        if (j.link_state.len > 0) try w.print("\"traceState\":{f},", .{std.json.fmt(j.link_state, .{})});
        // The W3C trace flags (OTLP's low byte).
        try w.print("\"flags\":{d}}}],", .{@as(u8, @intFromBool(l.sampled))});
    }
    const strings = [_]struct { []const u8, []const u8 }{
        .{ "messaging.system", "anole" },
        .{ "messaging.destination.name", j.queue },
        .{ "messaging.operation.type", "process" },
        .{ "anole.job.kind", j.kind },
        .{ "anole.job.outcome", j.outcome },
        .{ "error.type", j.error_type },
    };
    try w.writeAll("\"attributes\":[");
    try w.print("{{\"key\":\"messaging.message.id\",\"value\":{{\"stringValue\":\"{d}\"}}}}", .{j.id});
    try w.print(",{{\"key\":\"anole.job.attempt\",\"value\":{{\"intValue\":\"{d}\"}}}}", .{j.attempt});
    try w.print(",{{\"key\":\"anole.job.max_attempts\",\"value\":{{\"intValue\":\"{d}\"}}}}", .{j.max_attempts});
    for (strings) |a| if (a[1].len > 0) try w.print(",{{\"key\":\"{s}\",\"value\":{{\"stringValue\":{f}}}}}", .{ a[0], std.json.fmt(a[1], .{}) });
    try w.print("],\"status\":{{\"code\":{d}}}}}", .{@as(u8, if (j.error_type.len > 0) 2 else 0)});
}

/// Starts a span for each request (continuing the caller's trace), sets
/// `req.trace_id`/`span_id`, and queues the span when the response is done.
pub const Middleware = struct {
    exporter: *Exporter,

    /// The middleware, queueing spans on `exporter`, which must outlive it.
    pub fn init(exporter: *Exporter) Middleware {
        return .{ .exporter = exporter };
    }

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        if (common.excluded(req, self.exporter.options.exclude)) return next.call();
        const parent = if (req.headers.get("traceparent")) |h| Context.parse(h) else null;
        if (!self.exporter.options.sample_all) if (parent == null or !parent.?.sampled) {
            // Not recorded here, but the caller's context still goes on to
            // the calls this request makes, unchanged (W3C Trace Context:
            // `outgoing` keeps its sampled flag).
            if (parent) |p| {
                req.trace_id = try req.arena.dupe(u8, &p.trace_id);
                req.span_id = try req.arena.dupe(u8, &p.span_id);
            }
            return next.call();
        };
        var span: Span = undefined;
        span.db = null;
        span.job = null;
        if (parent) |p| span.trace_id = p.trace_id else randomHex(req.io, &span.trace_id);
        randomHex(req.io, &span.span_id);
        span.parent_span_id = if (parent) |p| p.span_id else null;
        req.trace_id = try req.arena.dupe(u8, &span.trace_id);
        req.span_id = try req.arena.dupe(u8, &span.span_id);
        span.start_ns = std.Io.Clock.real.now(req.io).nanoseconds;

        const result = next.call();

        span.end_ns = std.Io.Clock.real.now(req.io).nanoseconds;
        var mbuf: [12]u8 = undefined;
        const method = std.fmt.bufPrint(&mbuf, "{f}", .{req.method}) catch "?";
        const route = if (req.route) |r| r.path else "unmatched";
        span.method_len = @intCast(method.len);
        @memcpy(span.method[0..method.len], method);
        span.route_len = @intCast(@min(route.len, span.route.len));
        @memcpy(span.route[0..span.route_len], route[0..span.route_len]);
        const name = std.fmt.bufPrint(&span.name, "{s} {s}", .{ method, route[0..span.route_len] }) catch span.name[0..0];
        span.name_len = @intCast(name.len);
        span.status_code = common.statusOf(req, res, result);
        self.exporter.submit(span);
        return result;
    }
};

test "traceparent: parse, round trip, and what is refused" {
    const c = Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", &c.trace_id);
    try std.testing.expect(c.sampled);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try c.format(&w);
    try std.testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", w.buffered());
    try std.testing.expect(Context.parse("00-00000000000000000000000000000000-00f067aa0ba902b7-01") == null);
    try std.testing.expect(Context.parse("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") == null);
    try std.testing.expect(Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra") == null);
    try std.testing.expect(Context.parse("garbage") == null);
}

test "fuzz: traceparent parsing round-trips" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            const ctx = Context.parse(input) orelse return;
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try ctx.format(&w);
            const again = Context.parse(w.buffered()) orelse return error.RoundTrip;
            try std.testing.expectEqual(ctx, again);
        }
    }.check, &.{
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        " 00-0AF7651916CD43DD8448EB211C80319C-B7AD6B7169203331-00\t",
        "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-future",
    });
}
