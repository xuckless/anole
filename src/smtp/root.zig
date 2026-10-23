//! Sending mail over SMTP (`-Dsmtp`): STARTTLS or implicit TLS, AUTH PLAIN
//! and LOGIN, MIME with HTML, attachments and inline images, and a pool of
//! connections per executor, on `anole.db`'s calling convention.
//!
//!     const App = struct { mail: *anole.smtp.Client };
//!     var state: App = undefined;
//!     var app = try anole.Server(App).init(gpa, .{}, &state);
//!     state.mail = try app.smtp(.{}); // SMTP_URL, else Mailpit on 127.0.0.1:1025
//!
//!     fn reset(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         _ = try app.mail.send(req, .{
//!             .to = &.{"ada@example.com"},
//!             .subject = "Reset your password",
//!             .text = "Open the link to choose a new one.",
//!         });
//!         res.status = .accepted;
//!     }
//!
//! See `anole.db` for the contract every connector keeps (the request
//! first, `with`, errors and `lastError`, cancellation). What is SMTP's:
//!
//! - `SMTP_URL` (or `Options.url`): `smtp://user:pass@host:587` (STARTTLS),
//!   `smtps://user:pass@host:465` (TLS from the first byte), and
//!   `?tls=none` for a plain local sink. Left unset, mail goes to
//!   Mailpit's `smtp://127.0.0.1:1025` with a line in the log, except in
//!   production, where a missing `SMTP_URL` stops `app.smtp`.
//! - A server on a public address must offer STARTTLS, or the connection
//!   fails; credentials are never sent without TLS to anything but
//!   loopback.
//! - `send` composes the message (text, HTML, attachments, inline images),
//!   checks every address and header, and returns once the server accepted
//!   it for at least one recipient. `sendRaw` sends a message composed
//!   elsewhere, as it is.
//! - Retries are opt-in (`with(.{ .retry = true })`): a failure before the
//!   final "." may be tried again, one after it never is, because the
//!   server may have kept the message.
//! - Errors: a refused or unreachable server is `ServiceUnavailable`
//!   (503), a timeout `GatewayTimeout` (504), a mistyped recipient or a
//!   message too large `BadRequest` (400), a server that refuses our
//!   credentials `Database` (500); `lastError(c)` says which, with the
//!   server's own words.
//!
//! Tests that need no server use `anole.smtp.testing.FakeServer`.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");
const resilience = @import("../resilience/root.zig");
const env_mod = @import("../env.zig");
const os = @import("../console/os.zig");
const errors = @import("../errors.zig");
const placement = dusty.placement;

const session_mod = @import("session.zig");
const pool_mod = @import("pool.zig");

pub const testing = @import("testing.zig");

const log = errors.log;
const Duration = std.Io.Duration;
const Session = session_mod.Session;
const Pool = pool_mod.Pool;
const Ctx = session_mod.Ctx;

const has_tls = features.tls == .boringssl;

/// Mailbox parsing and message composing, for the C ABI (`src/capi/smtp.zig`),
/// which checks a message on its caller's thread before queueing it.
pub const address = @import("address.zig");
pub const mime = @import("mime.zig");

pub const Header = mime.Header;
pub const Message = mime.Message;
pub const Attachment = mime.Attachment;

/// What every call fails with, besides `error.Canceled` and
/// `error.OutOfMemory`.
pub const Error = db.Error || error{ Canceled, OutOfMemory };

pub const Options = struct {
    /// smtp://user:pass@host:587, smtps://user:pass@host:465,
    /// smtp://127.0.0.1:1025?tls=none. Null: SMTP_URL, else Mailpit's
    /// smtp://127.0.0.1:1025 (not in production).
    url: ?[]const u8 = null,
    /// The default From ("Ada <ada@example.com>"); null: SMTP_FROM. A
    /// message without `from` and no default fails `invalid_address`.
    from: ?[]const u8 = null,
    /// Override the URL's user and password. Keep the password in an
    /// `anole.Secret` and pass `.expose()`.
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    tls_mode: TlsMode = .auto,
    tls: TlsOptions = .{},
    /// The EHLO name; null: the host name, else "localhost".
    helo_name: ?[]const u8 = null,
    /// The client's name in metrics, spans and logs; null: "smtp".
    name: ?[]const u8 = null,
    /// Connections in all, split between executors (at least one each),
    /// opened when needed; null: 2 per executor.
    max_connections: ?u32 = null,
    /// A connection QUITs after this many messages.
    max_messages_per_connection: u32 = 100,
    /// Idle connections are closed after this; providers drop idle SMTP
    /// sessions after 30 to 300 seconds.
    idle_timeout: Duration = .fromSeconds(30),
    acquire_timeout: Duration = .fromSeconds(5),
    connect_timeout: Duration = .fromSeconds(10),
    /// One send, connecting included, plus the message's size at
    /// `min_throughput`. Null: none. A call can give its own.
    timeout: ?Duration = .fromSeconds(30),
    /// Bytes per second a send is allowed to take at the least, added to
    /// `timeout` for the message's size.
    min_throughput: u64 = 1024 * 1024,
    /// Refused before connecting when the encoded message is larger, and
    /// when the server's SIZE says less.
    max_message_bytes: u64 = 25 * 1024 * 1024,
    errors: db.ErrorMap = .{},
    /// What `with(.{ .retry = true })` retries with.
    retry: resilience.Retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(500), .max = .fromSeconds(5) } },
    breaker: ?resilience.Breaker.Options = .{},
    /// Register a readiness check (connect, EHLO, QUIT; cached 30 s). Off
    /// by default: a mail outage must not pull every instance out of the
    /// load balancer.
    readiness: bool = false,
    /// Whose environment: null, production unless the build is Debug
    /// (`anole.env.environment`). `app.smtp` sets it from the app.
    environment: ?env_mod.Environment = null,
    environ: ?std.process.Environ = null,

    pub const TlsMode = enum {
        /// `smtps://` is implicit TLS; `smtp://` to a public host requires
        /// STARTTLS; to loopback it uses STARTTLS when offered.
        auto,
        starttls,
        implicit,
        none,
    };
    pub const TlsOptions = struct {
        /// What the server's certificate must chain to; null: the system store.
        ca: ?dusty.Ca = null,
        client_certificate: ?dusty.Cert = null,
        insecure_skip_verify: bool = false,
    };
};

/// What the server accepted.
pub const Sent = struct {
    /// Without the angle brackets.
    message_id: []const u8,
    accepted: []const []const u8,
    rejected: []const Rejected,
    /// The server's answer to the final ".", often its queue id.
    response: []const u8,
    /// The reply code of that answer (250).
    code: u16 = 250,
};

pub const Rejected = session_mod.Session.Rejected;

/// The envelope of `sendRaw`.
pub const Envelope = struct {
    /// MAIL FROM; empty for the null sender (a bounce).
    from: []const u8,
    to: []const []const u8,
};

pub const CallOptions = struct {
    /// Null: the client's `timeout`. `.max`: none.
    timeout: ?Duration = null,
    /// Try transient failures before the final "." again, with
    /// `Options.retry`. Off: a duplicate email is visible to a user.
    retry: bool = false,
};

/// A client with call options (`Client.with`).
pub const Call = struct {
    client: *Client,
    opts: CallOptions,

    /// `Client.send`, with the options.
    pub fn send(self: Call, c: anytype, message: Message) Error!Sent {
        return self.client.sendWith(c, message, self.opts);
    }

    /// `Client.sendRaw`, with the options.
    pub fn sendRaw(self: Call, c: anytype, envelope: Envelope, message: []const u8) Error!Sent {
        return self.client.sendRawWith(c, envelope, message, self.opts);
    }
};

/// An SMTP server: the handle in the App state.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The settings' strings.
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    settings: session_mod.Settings,
    /// The default From, if any.
    from: ?[]const u8,
    timeout: ?Duration,
    min_throughput: u64,
    max_message_bytes: u64,
    max_messages: u32,
    idle_timeout: Duration,
    acquire_timeout: Duration,
    errors: db.ErrorMap,
    pools: internal.PerExecutor(Pool),
    guard: internal.Guard,
    observer: db.Observer,
    readiness: db.Readiness,
    readiness_on: bool,
    group: std.Io.Group = .init,
    /// No new sends are taken (`stopAccepting`, `drain`).
    draining: std.atomic.Value(bool) = .init(false),
    /// `drain` has run.
    drained: std.atomic.Value(bool) = .init(false),
    inflight: std.atomic.Value(u32) = .init(0),
    started: bool = false,

    /// Resolves the settings and sets up a pool per executor; nothing
    /// connects. `app.smtp` calls it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        if (opts.max_connections) |n| if (n == 0) {
            log.err("smtp: max_connections is 0; set at least 1, or leave it null for the default", .{});
            return error.InvalidOptions;
        };
        if (opts.max_messages_per_connection == 0) {
            log.err("smtp: max_messages_per_connection is 0; set at least 1", .{});
            return error.InvalidOptions;
        }
        if (opts.min_throughput == 0) {
            log.err("smtp: min_throughput is 0; set bytes per second above 0", .{});
            return error.InvalidOptions;
        }
        if (opts.tls.insecure_skip_verify and opts.tls.ca != null) {
            log.err("smtp: tls.insecure_skip_verify cannot be set with tls.ca: one checks the server's certificate and the other does not", .{});
            return error.InvalidOptions;
        }
        if (opts.tls.client_certificate) |cc| if (cc == .dev_self_signed) {
            log.err("smtp: tls.client_certificate cannot be .dev_self_signed", .{});
            return error.InvalidOptions;
        };
        const name = opts.name orelse "smtp";
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .name = name,
            .settings = undefined,
            .from = null,
            .timeout = opts.timeout,
            .min_throughput = opts.min_throughput,
            .max_message_bytes = opts.max_message_bytes,
            .max_messages = opts.max_messages_per_connection,
            .idle_timeout = opts.idle_timeout,
            .acquire_timeout = opts.acquire_timeout,
            .errors = opts.errors,
            .pools = undefined,
            .guard = try .init(.smtp, name, opts.breaker, opts.retry),
            .observer = .{ .system = .smtp, .name = name },
            .readiness = .{ .io = io, .context = self, .ping = ping, .ttl = .fromSeconds(30) },
            .readiness_on = opts.readiness,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.settings = try resolve(a, opts);
        self.from = opts.from orelse db.env(opts.environ, "SMTP_FROM");
        if (self.from) |f| {
            _ = address.parse(a, f) catch {
                log.err("smtp: the default From \"{s}\" is not a mailbox (Name <local@domain> or local@domain)", .{f});
                return error.InvalidOptions;
            };
        }

        const executors = internal.executorCount(io);
        const total: usize = opts.max_connections orelse 2 * executors;
        self.pools = try .init(gpa, io);
        var made: usize = 0;
        errdefer {
            for (self.pools.pools[0..made]) |*p| gpa.free(p.idle);
            self.pools.deinit(gpa);
        }
        for (self.pools.pools, 0..) |*p, i| {
            const max = self.pools.share(total, i);
            p.* = .init(try gpa.alloc(*Session, max), max);
            made += 1;
        }
        log.info("smtp \"{s}\": {s}:{d} ({t}), up to {d} connections over {d} executors", .{ name, self.settings.host, self.settings.port, self.settings.tls_mode, @max(total, executors), executors });
        return self;
    }

    /// Stops accepting sends, lets those in flight finish (until
    /// `deadline`), and QUITs the idle connections. `deinit` calls it.
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        if (self.drained.swap(true, .acq_rel)) return;
        self.draining.store(true, .release);
        const io = self.io;
        while (self.inflight.load(.acquire) > 0) {
            if (deadline.untilNow(io).raw.nanoseconds >= 0) break;
            io.sleep(.fromMilliseconds(5), .awake) catch {
                io.recancel();
                break;
            };
        }
        self.group.cancel(io);
        _ = self.closeIdle();
    }

    /// Refuses new sends from now on (a send in flight finishes) without
    /// waiting for anything: the start of a drain.
    pub fn stopAccepting(self: *Client) void {
        self.draining.store(true, .release);
    }

    /// Closes the connections now idle (QUIT, then the socket), for a
    /// process that is about to be frozen (a Lambda execution
    /// environment) or wants to give the server's slots back. A send in
    /// flight keeps its connection; the next send opens a new one.
    /// Returns how many it closed.
    pub fn closeIdle(self: *Client) usize {
        var n: usize = 0;
        for (self.pools.pools) |*p| n += p.closeIdle(self.gpa, self.io, &self.observer, null);
        return n;
    }

    pub fn deinit(self: *Client) void {
        const io = self.io;
        self.drain(std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(5), .clock = .awake }));
        const gpa = self.gpa;
        self.guard.deinit();
        for (self.pools.pools) |*p| {
            if (p.open > p.idle_len) log.warn("smtp \"{s}\": {d} connections were still taken at deinit", .{ self.name, p.open - p.idle_len });
            gpa.free(p.idle);
        }
        self.pools.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// What the server hands over when serving starts: the app's metrics
    /// registry, tracer and health checks, when it has them.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        if (self.started) return;
        self.observer = try .init(.smtp, self.name, registry, tracer);
        try self.guard.observe(self.gpa, registry);
        if (health) |h| if (self.readiness_on) try self.readiness.register(h, self.name);
        self.started = true;
        if (self.idle_timeout.nanoseconds > 0) {
            placement.concurrent(&self.group, self.io, .{ .executor = 0 }, reaper, .{self}) catch |err|
                log.warn("smtp \"{s}\": the idle reaper did not start ({t}); idle connections close when next used", .{ self.name, err });
        }
    }

    /// What the live console's /db entry shows.
    pub fn consoleInfo(self: *Client, w: *std.Io.Writer) !void {
        var open: usize = 0;
        for (self.pools.pools) |*p| open += p.open;
        try w.print("\"system\":\"smtp\",\"name\":\"{s}\",\"target\":\"{s}:{d}\",\"pools\":[{{\"open\":{d}}}]", .{ self.name, self.settings.host, self.settings.port, open });
    }

    fn reaper(self: *Client) std.Io.Cancelable!void {
        const every: Duration = .{ .nanoseconds = @max(std.time.ns_per_s, @divTrunc(self.idle_timeout.nanoseconds, 2)) };
        while (true) {
            try self.io.sleep(every, .awake);
            for (self.pools.pools) |*p| _ = p.closeIdle(self.gpa, self.io, &self.observer, self.idle_timeout);
        }
    }

    fn ping(context: *anyopaque, io: std.Io) bool {
        const self: *Client = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var c: db.Ctx = .{ .io = io, .arena = arena.allocator() };
        const ctx = erase(&c);
        const deadline: dusty.Deadline = .init(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        deadline.run(Session.probe, .{ self.gpa, &ctx, self.errors, &self.settings }) catch return false;
        return true;
    }

    // -- calls ------------------------------------------------------------------

    /// The calls with `opts`: `app.mail.with(.{ .retry = true }).send(req, msg)`.
    pub fn with(self: *Client, opts: CallOptions) Call {
        return .{ .client = self, .opts = opts };
    }

    /// Composes and sends `message`; returns once the server accepted it
    /// (its answer to the final ".") for at least one recipient. Recipients
    /// it refused are in `Sent.rejected`. Every recipient refused is
    /// `error.BadRequest` (`recipient_rejected`).
    pub fn send(self: *Client, c: anytype, message: Message) Error!Sent {
        return self.sendWith(c, message, .{});
    }

    /// A message composed elsewhere (RFC 5322 bytes, CRLF or LF line ends)
    /// sent as it is, dot-stuffed with line ends made CRLF, to the
    /// envelope's recipients.
    pub fn sendRaw(self: *Client, c: anytype, envelope: Envelope, message: []const u8) Error!Sent {
        return self.sendRawWith(c, envelope, message, .{});
    }

    fn sendWith(self: *Client, c: anytype, message: Message, opts: CallOptions) Error!Sent {
        const ctx = erase(c);
        const observed = self.observer.start(&ctx);
        const result = self.composeAndDeliver(&ctx, message, opts);
        endCall(&ctx, observed, "send", if (result) |_| null else |e| e);
        return result;
    }

    fn sendRawWith(self: *Client, c: anytype, envelope: Envelope, message: []const u8, opts: CallOptions) Error!Sent {
        const ctx = erase(c);
        const observed = self.observer.start(&ctx);
        const result = self.rawAndDeliver(&ctx, envelope, message, opts);
        endCall(&ctx, observed, "send raw", if (result) |_| null else |e| e);
        return result;
    }

    fn composeAndDeliver(self: *Client, ctx: *const Ctx, message: Message, opts: CallOptions) Error!Sent {
        var rng: std.Random.IoSource = .{ .io = ctx.io };
        var failure: mime.Failure = .{};
        const composed = mime.compose(ctx.arena, ctx.io, message, .{
            .from = self.from,
            .max_bytes = self.max_message_bytes,
        }, rng.interface(), std.Io.Clock.real.now(ctx.io).toSeconds(), &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return ctx.fail(self.errors, .{
                .system = .smtp,
                .class = switch (failure.class) {
                    .invalid => .invalid,
                    .other => .other,
                },
                .code = failure.code,
                .message = failure.message,
            }),
        };
        return self.deliver(ctx, &composed, opts);
    }

    fn rawAndDeliver(self: *Client, ctx: *const Ctx, envelope: Envelope, message: []const u8, opts: CallOptions) Error!Sent {
        const a = ctx.arena;
        if (envelope.to.len == 0) return ctx.failf(self.errors, .invalid, "invalid_address", "the envelope has no recipients", .{});
        if (envelope.to.len > 100) return ctx.failf(self.errors, .invalid, "too_many_recipients", "{d} recipients; at most 100 per message", .{envelope.to.len});
        var utf8 = false;
        const recipients = try a.alloc([]const u8, envelope.to.len);
        for (envelope.to, 0..) |t, i| {
            const m = address.parse(a, t) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidAddress => return ctx.failf(self.errors, .invalid, "invalid_address", "to: \"{f}\" is not a mailbox", .{std.zig.fmtString(t[0..@min(t.len, 80)])}),
            };
            recipients[i] = m.address;
            utf8 = utf8 or m.needsUtf8();
        }
        var from: []const u8 = "";
        if (envelope.from.len > 0) {
            const m = address.parse(a, envelope.from) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidAddress => return ctx.failf(self.errors, .invalid, "invalid_address", "from: \"{f}\" is not a mailbox", .{std.zig.fmtString(envelope.from[0..@min(envelope.from.len, 80)])}),
            };
            from = m.address;
            utf8 = utf8 or m.needsUtf8();
        }
        if (message.len > self.max_message_bytes)
            return ctx.failf(self.errors, .invalid, "message_too_large", "the message is {d} bytes; the limit is {d} (Options.max_message_bytes)", .{ message.len, self.max_message_bytes });
        const parts = try a.alloc(mime.Part, 1);
        parts[0] = .{ .bytes = message };
        const composed: mime.Composed = .{
            .parts = parts,
            .size = message.len,
            .envelope_from = from,
            .recipients = recipients,
            .message_id = rawMessageId(message),
            .utf8 = utf8,
            .normalize = true,
        };
        return self.deliver(ctx, &composed, opts);
    }

    /// The Message-ID of a message composed elsewhere, without the angle
    /// brackets; empty when the header block has none.
    fn rawMessageId(message: []const u8) []const u8 {
        var it = std.mem.splitScalar(u8, message, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) return "";
            if (line.len > 11 and std.ascii.eqlIgnoreCase(line[0..11], "message-id:"))
                return std.mem.trim(u8, line[11..], " \t<>");
        }
        return "";
    }

    /// What a send's attempts share.
    const Attempt = struct {
        /// The final "." may have reached the server.
        after_dot: bool = false,
    };

    fn deliver(self: *Client, ctx: *const Ctx, composed: *const mime.Composed, opts: CallOptions) Error!Sent {
        if (self.draining.load(.acquire))
            return ctx.failf(self.errors, .unavailable, "draining", "the server is shutting down; no new mail is sent", .{});
        _ = self.inflight.fetchAdd(1, .acq_rel);
        defer _ = self.inflight.fetchSub(1, .acq_rel);

        const timeout = boundFor(internal.callTimeout(opts.timeout, self.timeout), composed.size, self.min_throughput);
        const started = std.Io.Clock.Timestamp.now(ctx.io, .awake);
        const deadline: ?std.Io.Clock.Timestamp = if (timeout) |t| started.addDuration(.{ .raw = t, .clock = .awake }) else null;
        var attempt: Attempt = .{};
        var n: u32 = 1;
        while (true) : (n += 1) {
            attempt.after_dot = false;
            const r = internal.guarded(ctx, &self.guard, self.errors, false, deadline, attemptOnce, .{ self, ctx, composed, timeout, &attempt });
            const out = r catch |err| {
                if (!opts.retry or attempt.after_dot or n >= self.guard.retry.attempts or !self.retryable(ctx, err)) return err;
                if (!self.guard.throttle.allowRetry()) return err;
                self.guard.throttle.onFailure();
                var rb: [8]u8 = undefined;
                ctx.io.random(&rb);
                const wait = self.guard.retry.backoff.delay(n, std.mem.readInt(u64, &rb, .little));
                const now = std.Io.Clock.Timestamp.now(ctx.io, .awake);
                if (deadline) |d| if (now.raw.nanoseconds + wait.nanoseconds >= d.raw.nanoseconds) return err;
                if (self.guard.binding) |*bd| {
                    const h = bd.metricsHooks();
                    h.on_retry(h.context, .smtp, self.name, "transport");
                }
                ctx.io.sleep(wait, .awake) catch return error.Canceled;
                continue;
            };
            if (opts.retry) self.guard.throttle.onSuccess();
            return .{
                .message_id = composed.message_id,
                .accepted = out.accepted,
                .rejected = out.rejected,
                .response = out.response,
                .code = out.code,
            };
        }
    }

    /// Whether a failure is one a retry may fix: the server could not be
    /// reached or said "try later" (class unavailable, not a full pool or
    /// an open breaker), or the attempt timed out.
    fn retryable(self: *Client, ctx: *const Ctx, err: Error) bool {
        _ = self;
        switch (err) {
            error.ServiceUnavailable, error.GatewayTimeout => {},
            else => return false,
        }
        const d = ctx.lastDetail() orelse return false;
        if (d.class == .timeout) return true;
        return d.class == .unavailable and !std.mem.eql(u8, d.code, "pool_timeout") and
            !std.mem.eql(u8, d.code, "circuit_open") and !std.mem.eql(u8, d.code, "draining") and
            !std.mem.eql(u8, d.code, "starttls_unavailable");
    }

    /// `timeout` and what a body of `size` bytes adds at `throughput`.
    pub fn boundFor(timeout: ?Duration, size: u64, throughput: u64) ?Duration {
        const t = timeout orelse return null;
        const extra_ns: u128 = @as(u128, size) * std.time.ns_per_s / throughput;
        const total: u128 = @as(u128, @intCast(@max(t.nanoseconds, 0))) + extra_ns;
        return .{ .nanoseconds = @intCast(@min(total, std.math.maxInt(i64))) };
    }

    const Done = session_mod.Session.Sent;

    fn attemptOnce(self: *Client, ctx: *const Ctx, c: *const mime.Composed, timeout: ?Duration, attempt: *Attempt) Error!Done {
        const t = timeout orelse return self.exchange(ctx, c, attempt);
        const deadline: dusty.Deadline = .init(ctx.io, .{ .duration = .{ .raw = t, .clock = .awake } });
        return deadline.run(exchange, .{ self, ctx, c, attempt }) catch |err| switch (err) {
            error.Timeout => ctx.fail(self.errors, .{ .system = .smtp, .class = .timeout, .code = "timeout", .message = "the send ran past its timeout" }),
            else => |e| e,
        };
    }

    /// One send on a pooled connection.
    fn exchange(self: *Client, ctx: *const Ctx, c: *const mime.Composed, attempt: *Attempt) Error!Done {
        var s = try self.take(ctx);
        var stale: u8 = 0;
        while (true) {
            const r = s.transact(ctx, self.errors, ctx.io, c, self.max_message_bytes) catch |err| {
                attempt.after_dot = attempt.after_dot or s.after_dot;
                // A connection taken idle that the server had closed meanwhile
                // fails before it accepted anything: once more on another, not
                // a failure of the send.
                if (s.reused and !s.mail_accepted and !s.after_dot and stale < 3 and isStale(err, s)) {
                    s.broken = true;
                    self.give(s);
                    stale += 1;
                    s = try self.take(ctx);
                    continue;
                }
                return self.broke(ctx, s, err);
            };
            self.give(s);
            return r;
        }
    }

    /// Whether `err` says the connection was dead before the send reached
    /// the server: the transport failed, or the server said 421.
    fn isStale(err: anyerror, s: *const Session) bool {
        return switch (err) {
            error.ReadFailed, error.WriteFailed, error.EndOfStream => true,
            else => s.broken and isDbError(err),
        };
    }

    fn isDbError(err: anyerror) bool {
        inline for (@typeInfo(db.Error).error_set.error_names.?) |name| {
            if (err == @field(db.Error, name)) return true;
        }
        return false;
    }

    /// What a send that failed returns: the connection is given back
    /// (closed when it is no good), and the error is one of `Error`.
    fn broke(self: *Client, ctx: *const Ctx, s: *Session, err: anyerror) Error {
        if (isDbError(err)) {
            self.give(s);
            return @errorCast(err);
        }
        s.broken = true;
        const cause = switch (err) {
            error.ReadFailed => s.stream.readError() orelse err,
            error.WriteFailed => s.stream.writeError() orelse err,
            else => err,
        };
        self.give(s);
        return switch (cause) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.EndOfStream => ctx.failf(self.errors, .unavailable, "connection_closed", "{s}:{d} closed the connection", .{ self.settings.host, self.settings.port }),
            error.AttachmentUnreadable => ctx.failf(self.errors, .other, "attachment_unreadable", "an attachment file could not be read while sending", .{}),
            else => ctx.failf(self.errors, .unavailable, "connection_failed", "the connection to {s}:{d} broke: {t}", .{ self.settings.host, self.settings.port, cause }),
        };
    }

    // -- the pool -------------------------------------------------------------------

    /// A session from the calling executor's pool.
    fn take(self: *Client, ctx: *const Ctx) Error!*Session {
        const io = ctx.io;
        const pool = self.pools.get(io);
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        const until: std.Io.Timeout = .{ .deadline = started.addDuration(.{ .raw = self.acquire_timeout, .clock = .awake }) };
        pool.mutex.lock(io) catch return error.Canceled;
        while (true) {
            if (pool.idle_len > 0) {
                pool.idle_len -= 1;
                const s = pool.idle[pool.idle_len];
                if (self.expired(s, io)) {
                    pool.open -= 1;
                    pool.mutex.unlock(io);
                    self.observer.connections(-1, 0);
                    s.close(true);
                    pool.mutex.lockUncancelable(io);
                    continue;
                }
                pool.mutex.unlock(io);
                self.observer.connections(-1, 1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                s.reused = true;
                return s;
            }
            if (pool.open < pool.max) {
                pool.open += 1;
                pool.mutex.unlock(io);
                const s = self.dial(ctx, pool) catch |err| {
                    pool.mutex.lockUncancelable(io);
                    pool.open -= 1;
                    pool.returned.signal(io);
                    pool.mutex.unlock(io);
                    return err;
                };
                self.observer.connections(0, 1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                return s;
            }
            self.observer.waiting(1);
            pool.returned.waitTimeout(io, &pool.mutex, until) catch |err| {
                self.observer.waiting(-1);
                pool.mutex.unlock(io);
                return switch (err) {
                    error.Canceled => error.Canceled,
                    error.Timeout => ctx.failf(self.errors, .unavailable, "pool_timeout", "no connection within {d} ms: all {d} of this executor's connections were busy", .{ self.acquire_timeout.toMilliseconds(), pool.max }),
                };
            };
            self.observer.waiting(-1);
        }
    }

    fn expired(self: *const Client, s: *const Session, io: std.Io) bool {
        if (self.idle_timeout.nanoseconds <= 0) return false;
        return s.idle_since.durationTo(.now(io, .awake)).raw.nanoseconds > self.idle_timeout.nanoseconds;
    }

    /// Gives a session back to its pool, or closes it when it is broken or
    /// has sent its share of messages.
    fn give(self: *Client, s: *Session) void {
        const io = self.io;
        const pool = s.pool.?;
        if (s.broken or s.messages >= self.max_messages or self.draining.load(.acquire)) {
            s.close(true);
            pool.mutex.lockUncancelable(io);
            pool.open -= 1;
            pool.returned.signal(io);
            pool.mutex.unlock(io);
            self.observer.connections(0, -1);
            return;
        }
        s.idle_since = .now(io, .awake);
        pool.mutex.lockUncancelable(io);
        pool.idle[pool.idle_len] = s;
        pool.idle_len += 1;
        pool.returned.signal(io);
        pool.mutex.unlock(io);
        self.observer.connections(1, -1);
    }

    /// Opens a connection and logs in, within `connect_timeout`.
    fn dial(self: *Client, ctx: *const Ctx, pool: *Pool) Error!*Session {
        const timeout: std.Io.Timeout = if (self.settings.connect_timeout) |t| .{ .duration = .{ .raw = t, .clock = .awake } } else .none;
        const deadline: dusty.Deadline = .init(ctx.io, timeout);
        const s = deadline.run(Session.open, .{ self.gpa, ctx, self.errors, &self.settings }) catch |err| {
            // Recorded already: the server refused the login, or the like.
            if (isDbError(err)) return @errorCast(err);
            return switch (err) {
                error.Canceled => error.Canceled,
                error.OutOfMemory => error.OutOfMemory,
                error.Timeout => ctx.failf(self.errors, .unavailable, "connect_timeout", "{s}:{d} did not answer within {d} ms", .{ self.settings.host, self.settings.port, if (self.settings.connect_timeout) |t| t.toMilliseconds() else 0 }),
                error.EndOfStream => ctx.failf(self.errors, .unavailable, "connection_closed", "{s}:{d} closed the connection while connecting", .{ self.settings.host, self.settings.port }),
                else => ctx.failf(self.errors, .unavailable, "connect_failed", "cannot connect to {s}:{d}: {t}", .{ self.settings.host, self.settings.port, err }),
            };
        };
        s.pool = pool;
        return s;
    }
};

fn endCall(ctx: *const Ctx, observed: db.Call, op: []const u8, failure: ?anyerror) void {
    if (ctx.request) |req| observed.end(req, op, null, failure) else observed.end(ctx, op, null, failure);
}

// ---------------------------------------------------------------------------
// Settings

fn isLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]")) return true;
    return std.mem.startsWith(u8, host, "127.");
}

/// The URL, the options and the environment as the settings a session
/// needs. Strings live in `a`.
fn resolve(a: std.mem.Allocator, opts: Options) !session_mod.Settings {
    const production = (opts.environment orelse env_mod.environment()) == .production;
    var text: []const u8 = undefined;
    if (opts.url) |u| {
        text = u;
    } else if (db.env(opts.environ, "SMTP_URL")) |u| {
        text = u;
    } else if (production) {
        log.err("smtp: SMTP_URL is not set; mail would go to a local test server. Set SMTP_URL (smtps://user:password@smtp.example.com:465) or pass Options.url", .{});
        return error.InvalidOptions;
    } else {
        text = "smtp://127.0.0.1:1025";
        log.info("smtp: SMTP_URL is not set; mail goes to {s} (Mailpit's port: docker run -p 1025:1025 -p 8025:8025 axllent/mailpit)", .{text});
    }
    const url = db.Url.parse(a, text) catch |err| {
        log.err("smtp: the URL is not valid ({t}); the form is smtp://user:password@host:587 or smtps://user:password@host:465", .{err});
        return error.InvalidOptions;
    };
    const implicit_scheme = std.ascii.eqlIgnoreCase(url.scheme, "smtps");
    if (!implicit_scheme and !std.ascii.eqlIgnoreCase(url.scheme, "smtp")) {
        log.err("smtp: the URL scheme \"{s}\" is not smtp or smtps", .{url.scheme});
        return error.InvalidOptions;
    }
    if (url.hosts.len != 1) {
        log.err("smtp: the URL names {d} hosts; it takes one", .{url.hosts.len});
        return error.InvalidOptions;
    }
    const host_in = url.hosts[0];
    if (host_in.name.len == 0 or host_in.name.len > 255) {
        log.err("smtp: the URL has no host name (or one longer than 255 bytes)", .{});
        return error.InvalidOptions;
    }
    const host = host_in.name;
    const port: u16 = host_in.port orelse if (implicit_scheme) 465 else 587;
    const loopback = isLoopback(host);
    var url_tls_none = false;
    for (url.params) |p| {
        if (std.mem.eql(u8, p.name, "tls")) {
            if (std.mem.eql(u8, p.value, "none")) {
                url_tls_none = true;
            } else {
                log.err("smtp: the URL parameter tls=\"{s}\" is not understood; use tls=none for plain SMTP", .{p.value});
                return error.InvalidOptions;
            }
        }
    }
    const username: ?[]const u8 = opts.username orelse url.username;
    const password: ?[]const u8 = opts.password orelse url.password;
    if (password != null and username == null) {
        log.err("smtp: a password without a user name", .{});
        return error.InvalidOptions;
    }

    const mode: session_mod.Settings.TlsMode = switch (opts.tls_mode) {
        .implicit => .implicit,
        .starttls => .starttls_required,
        .none => .none,
        .auto => if (implicit_scheme) .implicit else if (url_tls_none) .none else if (loopback) .starttls_optional else .starttls_required,
    };
    if (mode == .none and username != null and !loopback) {
        log.err("smtp: credentials for {s} would be sent without TLS; use smtps://, or smtp:// with STARTTLS", .{host});
        return error.InvalidOptions;
    }
    var effective = mode;
    if (!has_tls) {
        switch (mode) {
            .implicit, .starttls_required => {
                log.err("smtp: {s}:{d} needs TLS, which this build leaves out (-Dtls=none)", .{ host, port });
                return error.TlsNotBuilt;
            },
            .starttls_optional => effective = .none,
            .none => {},
        }
    }
    if (opts.tls.insecure_skip_verify) log.warn("smtp: tls.insecure_skip_verify: the server's certificate is not checked, so whoever is between this process and {s} can read and change all mail", .{host});

    var hostname_buf: [256]u8 = undefined;
    const helo: []const u8 = if (opts.helo_name) |h| h else blk: {
        const hn = os.hostname(&hostname_buf);
        break :blk if (hn.len > 0) try a.dupe(u8, hn) else "localhost";
    };
    for (helo) |ch| if (ch <= 0x20 or ch >= 0x7f) {
        log.err("smtp: the EHLO name \"{f}\" holds a space or a non-ASCII byte", .{std.zig.fmtString(helo)});
        return error.InvalidOptions;
    };
    return .{
        .host = host,
        .port = port,
        .tls_mode = effective,
        .tls = .{
            .ca = opts.tls.ca orelse .system,
            .client_certificate = opts.tls.client_certificate,
            .insecure_skip_verify = opts.tls.insecure_skip_verify,
        },
        .username = username,
        .password = password,
        .helo = helo,
        .connect_timeout = opts.connect_timeout,
        .loopback = loopback,
    };
}

/// The context a call records its failures on, from a request or a
/// `db.Ctx`; for the tests in this directory.
pub fn erase(c: anytype) Ctx {
    const C = @TypeOf(c);
    if (C == *Ctx or C == *const Ctx) return c.*;
    const R = struct {
        fn record(any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
            return internal.fail(@as(C, @ptrCast(@alignCast(any))), map, detail);
        }
        fn last(any: *anyopaque) ?db.ErrorDetail {
            return internal.lastError(@as(C, @ptrCast(@alignCast(any))));
        }
    };
    return .{ .io = c.io, .arena = c.arena, .any = @ptrCast(c), .record = R.record, .last = R.last, .request = internal.requestOf(c) };
}

test {
    _ = @import("core/date.zig");
    _ = @import("core/encode.zig");
    _ = @import("core/reply.zig");
    _ = @import("core/auth.zig");
    _ = @import("address.zig");
    _ = @import("mime.zig");
    _ = @import("testing.zig");
    _ = @import("smtp_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("live_test.zig");
}
