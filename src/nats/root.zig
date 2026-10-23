//! `anole.nats` (`-Dnats`): a NATS client on `std.Io`: publish, request and
//! reply, handlers on subjects (with queue groups), TLS, token, NKey and
//! `.creds` logins, and JetStream. The protocol engine is adapted from
//! vkiryakov/zefir (`core/`); this file is Anole's connector layer on it.
//!
//!     const nc = try app.nats(.{});               // NATS_URL, else nats://127.0.0.1:4222
//!     try nc.handle(&app, "orders.created", .{ .queue = "billing" }, onOrder);
//!     ...
//!     try nc.publish(req, "orders.created", body);   // returns once queued; never waits
//!     const reply = try nc.request(req, "users.get", id);
//!
//! A publish returns once the frame is queued. When the outbound queue is
//! full it fails (`error.ServiceUnavailable`, `lastError` code
//! "outbound_full") rather than wait: a send that blocks on the network
//! stalls whatever lock the caller holds. `writable` and `waitWritable`
//! are the ways to wait on purpose.
//!
//! One connection serves the whole app by default (`Options.connections`),
//! so publishes keep their order across requests; handlers still run on
//! every executor. See docs/messaging.md.
const std = @import("std");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const url_mod = @import("../db/url.zig");
const observe = @import("../observe/root.zig");
const resilience = @import("../resilience/root.zig");

pub const core = @import("core/root.zig");
pub const nkeys = @import("nkeys.zig");
pub const auth = @import("auth.zig");
pub const jetstream = @import("jetstream.zig");

const placement = dusty.placement;
const Duration = std.Io.Duration;
const log = std.log.scoped(.nats);

pub const Header = [2][]const u8; // .{ "Name", "value" }
pub const JetStream = jetstream.JetStream;
pub const JetStreamOptions = jetstream.Options;

/// What a call can fail with: `anole.db.Error` (so a handler's `try` gives
/// the right status), a cancel, memory.
pub const Error = db.Error || error{ Canceled, OutOfMemory };

pub const Options = struct {
    /// nats://, tls:// or a comma-separated list of them; `user:password@`
    /// or `token@` in the URL log in. Null: `NATS_URL`, else
    /// nats://127.0.0.1:4222.
    url: ?[]const u8 = null,
    /// The connection name the server shows; null: "anole".
    name: ?[]const u8 = null,
    /// The client's name in metrics, spans, /readyz and logs; null: "nats".
    label: ?[]const u8 = null,
    auth: Auth = .none,
    tls: Tls = .{},
    connections: Connections = .one,
    /// A bound on requests, JetStream calls and flushes without their own.
    timeout: ?Duration = .fromSeconds(30),
    connect_timeout: Duration = .fromSeconds(5),
    /// Connect before serving and fail the start if that fails. Off: the
    /// client keeps trying in the background, and /readyz says not ready.
    connect_at_start: bool = false,
    ping_interval: Duration = .fromSeconds(30),
    max_outstanding_pings: u8 = 2,
    no_echo: bool = false,
    reconnect: Reconnect = .{},
    limits: Limits = .{},
    errors: db.ErrorMap = .{},
    /// What requests made `with(.{ .retry = true })` retry with: only on
    /// NoResponders (the request was never delivered).
    retry: resilience.Retry = .{ .attempts = 5, .backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(2) } },
    jetstream: JetStreamOptions = .{},
    /// Register a readiness check (connected = ready).
    readiness: bool = true,
    environ: ?std.process.Environ = null,

    pub const Connections = enum {
        /// One connection: publishes keep their order across the whole app.
        one,
        /// One per executor: more throughput; publishes made on different
        /// executors are not ordered relative to each other.
        per_executor,
    };
    pub const Auth = union(enum) {
        none,
        token: []const u8,
        user_password: struct { username: []const u8, password: []const u8 },
        /// An NKey seed ("SU..."), as text or a file.
        nkey: Secret,
        /// A .creds file (JWT and NKey seed), as text or a file.
        creds: Secret,
        pub const Secret = union(enum) { text: []const u8, file: []const u8 };
    };
    pub const Tls = struct {
        /// The CAs the server's certificate must chain to; null: the system store.
        ca: ?dusty.Ca = null,
        client_certificate: ?dusty.Cert = null,
        insecure_skip_verify: bool = false,
        /// TLS before the server's INFO (nats-server `handshake_first`).
        first: bool = false,
        /// TLS even with nats:// URLs (as if every one were tls://).
        required: bool = false,

        fn wanted(t: Tls) bool {
            return t.ca != null or t.client_certificate != null or t.insecure_skip_verify or t.first or t.required;
        }
    };
    /// zefir's ReconnectOptions, unchanged names and defaults.
    pub const Reconnect = core.ReconnectOptions;
    /// zefir's Limits, unchanged defaults; `outbound_bytes` is the publish cap.
    pub const Limits = core.Limits;
};

/// A message to send.
pub const OutMsg = struct {
    subject: []const u8,
    reply_to: ?[]const u8 = null,
    headers: []const Header = &.{},
    payload: []const u8 = "",
};

/// A reply (or a message read by hand), copied into the caller's arena.
pub const Reply = struct {
    subject: []const u8,
    headers: []const Header,
    payload: []const u8,
    /// A status line's code (NATS 2.2+ headers), null when none.
    status: ?u16,

    /// Header lookup, case-sensitive as NATS headers are.
    pub fn header(self: Reply, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.mem.eql(u8, h[0], name)) return h[1];
        return null;
    }

    /// The payload parsed as JSON into T (arena).
    pub fn json(self: Reply, comptime T: type, arena: std.mem.Allocator) !T {
        return std.json.parseFromSliceLeaky(T, arena, self.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// A NATS micro error answer (Nats-Service-Error-Code), when it is one.
    pub fn serviceError(self: Reply) ?struct { code: u16, description: []const u8 } {
        const code = self.header("Nats-Service-Error-Code") orelse return null;
        return .{ .code = std.fmt.parseInt(u16, code, 10) catch 500, .description = self.header("Nats-Service-Error") orelse "" };
    }
};

/// Per call (`with`).
pub const CallOptions = struct {
    timeout: ?Duration = null, // null: Options.timeout; .max: none
    /// Retry a request with Options.retry when no one subscribes yet.
    retry: bool = false,
    headers: []const Header = &.{},
};

pub const HandleOptions = struct {
    /// A queue group: each message goes to one member (of this process and
    /// of every process in the group). Null: every message to this
    /// handler (and to every other subscriber).
    queue: ?[]const u8 = null,
    /// Messages handled at once by this handler, over all executors.
    concurrency: u32 = 64,
    /// The subscription's own queue (zefir's pending limits and overflow).
    pending: core.SubscribeOptions.Pending = .{},
    overflow: core.OverflowPolicy = .drop_newest,
    /// A bound per message; past it the handler is canceled. Null: none.
    timeout: ?Duration = .fromSeconds(30),
};

var message_counter: std.atomic.Value(u64) = .init(0);

/// One message to a handler: a context like a request (`io`, `arena`,
/// `locals`), so `app.db.one(T, msg, ...)` works. Valid during the call.
pub const Msg = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    locals: dusty.Locals = .{},
    /// For logs: "nats-<n>".
    id: []const u8,
    subject: []const u8,
    reply_to: ?[]const u8,
    headers: []const Header,
    payload: []const u8,
    client: *Client,

    pub fn header(self: *const Msg, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.mem.eql(u8, h[0], name)) return h[1];
        return null;
    }

    /// The payload parsed as JSON into T (in the message's arena).
    pub fn json(self: *Msg, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena, self.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// Publishes to reply_to; error.BadRequest when there is none.
    pub fn respond(self: *Msg, payload: []const u8) Error!void {
        const to = self.reply_to orelse return error.BadRequest;
        return self.client.publishMsg(self, .{ .subject = to, .payload = payload });
    }

    pub fn respondJson(self: *Msg, value: anytype) Error!void {
        const text = std.json.Stringify.valueAlloc(self.arena, value, .{}) catch return error.OutOfMemory;
        return self.respond(text);
    }
};

/// The client: `app.nats(options)` makes one.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Strings the core clients point into.
    arena: std.heap.ArenaAllocator,
    label: []const u8,
    timeout: ?Duration,
    errors: db.ErrorMap,
    connections: Options.Connections,
    connect_at_start: bool,
    readiness_on: bool,
    js_options: JetStreamOptions,
    /// One core client, or one per executor.
    cores: []core.Client,
    tls: core.Options.Tls = .{},
    guard: internal.Guard,
    observer: db.Observer,
    handlers: std.ArrayList(*Handler) = .empty,
    /// Things that start with the client (JetStream consumers).
    hooks: std.ArrayList(Hook) = .empty,
    /// Delivery and message tasks.
    group: std.Io.Group = .init,
    started: bool = false,
    closing: std.atomic.Value(bool) = .init(false),
    rr: std.atomic.Value(usize) = .init(0),

    /// Makes the core clients and checks the options; nothing connects.
    /// `app.nats` calls it; outside an app, `init` then `start`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .label = opts.label orelse "nats",
            .timeout = opts.timeout,
            .errors = opts.errors,
            .connections = opts.connections,
            .connect_at_start = opts.connect_at_start,
            .readiness_on = opts.readiness,
            .js_options = opts.jetstream,
            .cores = &.{},
            .guard = try .init(.nats, opts.label orelse "nats", null, opts.retry),
            .observer = .{ .system = .nats, .name = opts.label orelse "nats" },
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        var url_auth: core.Options.Auth = .none;
        const servers = try serverList(a, opts, &url_auth);
        const tls_wanted = opts.tls.wanted() or anyTlsScheme(servers);
        if (tls_wanted) {
            self.tls = .{
                .settings = .{
                    .ca = opts.tls.ca orelse .system,
                    .client_certificate = opts.tls.client_certificate,
                    .insecure_skip_verify = opts.tls.insecure_skip_verify,
                },
                .first = opts.tls.first,
                .required = opts.tls.required,
            };
        }
        const login: core.Options.Auth = switch (opts.auth) {
            .none => url_auth,
            .token => |t| .{ .token = t },
            .user_password => |p| .{ .user_password = .{ .username = p.username, .password = p.password } },
            .nkey => |s| .{ .nkey = .{ .seed = std.mem.trim(u8, try readSecret(a, io, s), " \t\r\n") } },
            .creds => |s| blk: {
                const text = try readSecret(a, io, s);
                const parts = auth.parseCreds(text) catch {
                    log.err("nats: the creds contain no user JWT and NKey seed", .{});
                    return error.InvalidOptions;
                };
                break :blk .{ .creds = .{ .jwt = parts.jwt, .seed = parts.seed } };
            },
        };
        const core_options: core.Options = .{
            .servers = servers,
            .name = opts.name orelse "anole",
            .auth = login,
            .connect_timeout = opts.connect_timeout,
            .ping_interval = opts.ping_interval,
            .max_outstanding_pings = opts.max_outstanding_pings,
            .no_echo = opts.no_echo,
            .retry_initial_connect = !opts.connect_at_start and opts.reconnect.enabled,
            .reconnect = opts.reconnect,
            .limits = opts.limits,
            .tls = if (tls_wanted) &self.tls else null,
        };
        const count: usize = switch (opts.connections) {
            .one => 1,
            .per_executor => internal.executorCount(io),
        };
        self.cores = try gpa.alloc(core.Client, count);
        errdefer gpa.free(self.cores);
        var made: usize = 0;
        errdefer for (self.cores[0..made]) |*c| c.deinit();
        for (self.cores, 0..) |*c, i| {
            c.* = core.Client.init(gpa, io, core_options) catch |err| {
                log.err("nats: invalid options ({t})", .{err});
                return err;
            };
            c.executor = i;
            made += 1;
        }
        return self;
    }

    /// Connects (every connection), ensures JetStream streams and
    /// consumers, starts handlers. `app` calls it when serving starts.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        if (self.started) return;
        self.observer = try .init(.nats, self.label, registry, tracer);
        try self.guard.observe(self.gpa, registry);
        if (health) |h| if (self.readiness_on) try h.addCheck(self.label, readyCheck, self);
        const need_js = self.js_options.streams.len > 0 or self.js_options.consumers.len > 0;
        for (self.cores) |*c| {
            c.connect() catch |err| {
                if (self.connect_at_start or need_js) {
                    log.err("nats \"{s}\": not serving, the server is not reachable ({t})", .{ self.label, err });
                    return err;
                }
                // retry_initial_connect: it keeps trying in the background.
                log.warn("nats \"{s}\": not connected yet ({t}); trying in the background", .{ self.label, err });
            };
        }
        self.started = true;
        if (need_js) {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            var c: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
            self.js().ensureAll(&c, self.js_options) catch |err| {
                if (db.lastError(&c)) |d| log.err("nats \"{s}\": JetStream setup failed: {f}", .{ self.label, d }) else log.err("nats \"{s}\": JetStream setup failed: {t}", .{ self.label, err });
                return err;
            };
        }
        for (self.handlers.items) |h| try h.begin();
        for (self.hooks.items) |hook| try hook.begin(hook.context);
    }

    /// Something to start with the client (or at once when it has started),
    /// freed with it.
    pub const Hook = struct {
        context: *anyopaque,
        begin: *const fn (context: *anyopaque) anyerror!void,
        free: *const fn (context: *anyopaque) void,
    };

    pub fn addHook(self: *Client, hook: Hook) !void {
        try self.hooks.append(self.gpa, hook);
        if (self.started) try hook.begin(hook.context);
    }

    /// Stops handlers (subscriptions drain: messages taken are finished),
    /// flushes and closes; by `deadline`. `deinit` calls it.
    pub fn drain(self: *Client, deadline: std.Io.Clock.Timestamp) void {
        if (self.closing.swap(true, .acq_rel)) return;
        for (self.cores) |*c| {
            if (!c.isConnected()) continue;
            c.drain(.{ .timeout = .{ .deadline = deadline } }) catch {};
        }
        self.group.cancel(self.io);
    }

    pub fn deinit(self: *Client) void {
        self.drain(std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromSeconds(5), .clock = .awake }));
        for (self.handlers.items) |h| self.gpa.destroy(h);
        self.handlers.deinit(self.gpa);
        for (self.hooks.items) |hook| hook.free(hook.context);
        self.hooks.deinit(self.gpa);
        for (self.cores) |*c| {
            c.close();
            c.deinit();
        }
        self.gpa.free(self.cores);
        self.guard.deinit();
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn readyCheck(ctx: ?*anyopaque) bool {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        if (self.closing.load(.acquire)) return false;
        for (self.cores) |*c| if (!c.isConnected()) return false;
        return true;
    }

    /// A handle that sends with these options.
    pub fn with(self: *Client, opts: CallOptions) Call {
        return .{ .client = self, .opts = opts };
    }

    /// JetStream.
    pub fn js(self: *Client) JetStream {
        return .{ .client = self };
    }

    pub fn pick(self: *Client) *core.Client {
        if (self.cores.len == 1) return &self.cores[0];
        const idx = internal.executorIndex(self.io) orelse 0;
        return &self.cores[idx % self.cores.len];
    }

    // -- sending -----------------------------------------------------------

    /// Queues a message; never waits. `error.ServiceUnavailable` (code
    /// "outbound_full") when the outbound queue is full.
    pub fn publish(self: *Client, c: anytype, subject: []const u8, payload: []const u8) Error!void {
        return self.publishMsg(c, .{ .subject = subject, .payload = payload });
    }

    pub fn publishMsg(self: *Client, c: anytype, msg: OutMsg) Error!void {
        return self.with(.{}).publishMsg(c, msg);
    }

    /// Whether a publish now would be taken.
    pub fn writable(self: *Client, c: anytype) bool {
        _ = c;
        for (self.cores) |*k| if (!k.writable()) return false;
        return true;
    }

    /// Waits until the queue has room (below half its cap); then the next
    /// publish is taken. `error.GatewayTimeout` past `timeout`.
    pub fn waitWritable(self: *Client, c: anytype, timeout: ?Duration) Error!void {
        const started = std.Io.Clock.Timestamp.now(self.io, .awake);
        while (!self.writable(c)) {
            if (timeout) |t| if (started.durationTo(.now(self.io, .awake)).raw.nanoseconds > t.nanoseconds)
                return internal.fail(c, self.errors, .{ .system = .nats, .class = .timeout, .code = "timeout", .message = "the outbound queue stayed full" });
            self.io.sleep(.fromMilliseconds(2), .awake) catch return error.Canceled;
        }
    }

    /// Sends a request and waits for the first reply (copied into c's
    /// arena). NoResponders is `error.ServiceUnavailable` (code
    /// "no_responders"); past the timeout `error.GatewayTimeout`.
    pub fn request(self: *Client, c: anytype, subject: []const u8, payload: []const u8) Error!Reply {
        return self.with(.{}).request(c, subject, payload);
    }

    pub fn requestMsg(self: *Client, c: anytype, msg: OutMsg) Error!Reply {
        return self.with(.{}).requestMsg(c, msg);
    }

    /// Waits until the server has everything published so far.
    pub fn flush(self: *Client, c: anytype) Error!void {
        return self.with(.{}).flush(c);
    }

    /// A subscription read by hand (a background task): `next(c)`, `deinit`.
    pub fn subscribe(self: *Client, c: anytype, subject: []const u8, opts: HandleOptions) Error!*Subscription {
        const k = self.pick();
        const sub = k.subscribe(subject, .{ .queue = opts.queue, .pending = opts.pending, .overflow = opts.overflow }) catch |err| return self.mapError(c, err);
        const wrapped = self.gpa.create(Subscription) catch return error.OutOfMemory;
        wrapped.* = .{ .client = self, .inner = sub };
        return wrapped;
    }

    // -- handlers ----------------------------------------------------------

    /// Runs `handler` for each message on `subject` once serving starts.
    /// `handler` is `fn (*Msg) !void` or `fn (*App, *Msg) !void`, where
    /// `server` is the `*anole.Server(App)`. Register before `run`.
    pub fn handle(self: *Client, server: anytype, subject: []const u8, opts: HandleOptions, comptime handler: anytype) !void {
        const Info = @typeInfo(@TypeOf(handler)).@"fn";
        const with_state = Info.params.len == 2;
        const state: ?*anyopaque = if (with_state) @ptrCast(server.server.ctx) else null;
        const Tramp = struct {
            fn run(ctx: ?*anyopaque, m: *Msg) anyerror!void {
                if (with_state) {
                    const P = Info.params[0].type.?;
                    return handler(@as(P, @ptrCast(@alignCast(ctx.?))), m);
                }
                return handler(m);
            }
        };
        try self.addHandler(subject, opts, state, Tramp.run);
    }

    pub fn addHandler(self: *Client, subject: []const u8, opts: HandleOptions, state: ?*anyopaque, run: *const fn (?*anyopaque, *Msg) anyerror!void) !void {
        const h = try self.gpa.create(Handler);
        errdefer self.gpa.destroy(h);
        const a = self.arena.allocator();
        h.* = .{
            .client = self,
            .subject = try a.dupe(u8, subject),
            .opts = opts,
            .state = state,
            .run = run,
            .slots = .{ .permits = @max(1, opts.concurrency) },
        };
        if (opts.queue) |q| h.opts.queue = try a.dupe(u8, q);
        try self.handlers.append(self.gpa, h);
        if (self.started) try h.begin();
    }

    // -- errors ------------------------------------------------------------

    /// A core client error as `Error`, recorded for `lastError`.
    pub fn mapError(self: *Client, c: anytype, err: anyerror) Error {
        const name = @errorName(err);
        const eql = std.mem.eql;
        const Spec = struct { class: db.Class, code: []const u8 };
        const spec: Spec = if (eql(u8, name, "Canceled"))
            return error.Canceled
        else if (eql(u8, name, "OutOfMemory"))
            return error.OutOfMemory
        else if (eql(u8, name, "NoResponders"))
            .{ .class = .unavailable, .code = "no_responders" }
        else if (eql(u8, name, "Full") or eql(u8, name, "BufferFull"))
            .{ .class = .unavailable, .code = "outbound_full" }
        else if (eql(u8, name, "Disconnected") or eql(u8, name, "ConnectionClosed") or eql(u8, name, "ConnectionDraining") or eql(u8, name, "ConnectionLost"))
            .{ .class = .unavailable, .code = "disconnected" }
        else if (eql(u8, name, "Timeout"))
            .{ .class = .timeout, .code = "timeout" }
        else if (eql(u8, name, "PayloadTooLarge"))
            .{ .class = .other, .code = "payload_too_large" }
        else if (eql(u8, name, "InvalidSubject") or eql(u8, name, "InvalidHeader") or eql(u8, name, "InvalidOptions"))
            .{ .class = .other, .code = "invalid_subject" }
        else if (eql(u8, name, "PermissionDenied"))
            .{ .class = .other, .code = "permission_denied" }
        else if (eql(u8, name, "AuthenticationFailed"))
            .{ .class = .other, .code = "authentication_failed" }
        else
            .{ .class = .other, .code = "error" };
        return internal.fail(c, self.errors, .{ .system = .nats, .class = spec.class, .code = spec.code, .message = name });
    }
};

/// A client with call options (`Client.with`).
pub const Call = struct {
    client: *Client,
    opts: CallOptions,

    pub fn publish(self: Call, c: anytype, subject: []const u8, payload: []const u8) Error!void {
        return self.publishMsg(c, .{ .subject = subject, .payload = payload });
    }

    pub fn publishMsg(self: Call, c: anytype, msg: OutMsg) Error!void {
        const cl = self.client;
        const call = cl.observer.start(c);
        var buf: [32]core.Headers.Header = undefined;
        const headers = coreHeaders(c, &buf, self.opts.headers, msg.headers) catch |err| return cl.mapError(c, err);
        const result = cl.pick().publishNow(.{
            .subject = msg.subject,
            .reply_to = msg.reply_to,
            .headers = headers,
            .payload = msg.payload,
        });
        const out: Error!void = if (result) |_| {} else |err| cl.mapError(c, err);
        endCall(c, call, "publish", msg.subject, out);
        return out;
    }

    pub fn request(self: Call, c: anytype, subject: []const u8, payload: []const u8) Error!Reply {
        return self.requestMsg(c, .{ .subject = subject, .payload = payload });
    }

    pub fn requestMsg(self: Call, c: anytype, msg: OutMsg) Error!Reply {
        const cl = self.client;
        const call = cl.observer.start(c);
        const timeout = internal.callTimeout(self.opts.timeout, cl.timeout);
        const started = std.Io.Clock.Timestamp.now(cl.io, .awake);
        const deadline: ?std.Io.Clock.Timestamp = if (timeout) |t| started.addDuration(.{ .raw = t, .clock = .awake }) else null;
        var buf: [32]core.Headers.Header = undefined;
        const headers = coreHeaders(c, &buf, self.opts.headers, msg.headers) catch |err| return cl.mapError(c, err);
        const attempts: u8 = if (self.opts.retry) cl.guard.retry.attempts else 1;
        var n: u8 = 1;
        const out: Error!Reply = while (true) : (n += 1) {
            const remaining: Duration = if (deadline) |d| .{ .nanoseconds = @max(1_000_000, d.raw.nanoseconds - std.Io.Clock.Timestamp.now(cl.io, .awake).raw.nanoseconds) } else .fromSeconds(3600);
            const got = cl.pick().requestMessage(.{
                .subject = msg.subject,
                .headers = headers,
                .payload = msg.payload,
            }, .{ .timeout = .{ .duration = .{ .raw = remaining, .clock = .awake } } });
            if (got) |m0| {
                var m = m0;
                defer m.deinit();
                break copyReply(c, m);
            } else |err| {
                if (err == error.NoResponders and n < attempts and cl.guard.throttle.allowRetry()) {
                    cl.guard.throttle.onFailure();
                    var rb: [8]u8 = undefined;
                    cl.io.random(&rb);
                    const wait = cl.guard.retry.backoff.delay(n, std.mem.readInt(u64, &rb, .little));
                    const now = std.Io.Clock.Timestamp.now(cl.io, .awake);
                    if (deadline) |d| if (now.raw.nanoseconds + wait.nanoseconds >= d.raw.nanoseconds) break cl.mapError(c, err);
                    cl.io.sleep(wait, .awake) catch break error.Canceled;
                    continue;
                }
                break cl.mapError(c, err);
            }
        };
        endCall(c, call, "request", msg.subject, if (out) |_| {} else |e| e);
        return out;
    }

    pub fn flush(self: Call, c: anytype) Error!void {
        const cl = self.client;
        const t = internal.callTimeout(self.opts.timeout, cl.timeout) orelse Duration.fromSeconds(3600);
        for (cl.cores) |*k| k.flush(.{ .timeout = .{ .duration = .{ .raw = t, .clock = .awake } } }) catch |err| return cl.mapError(c, err);
    }
};

fn endCall(c: anytype, call: db.Call, op: []const u8, subject: []const u8, result: Error!void) void {
    call.end(c, op, subject, if (result) |_| null else |e| e);
}

/// The message in `c`'s arena.
fn copyReply(c: anytype, m: core.Message) Error!Reply {
    const a = c.arena;
    var list: std.ArrayList(Header) = .empty;
    var it = m.headers.iterator();
    while (it.next()) |h| {
        list.append(a, .{ a.dupe(u8, h.name) catch return error.OutOfMemory, a.dupe(u8, h.value) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    }
    return .{
        .subject = a.dupe(u8, m.subject) catch return error.OutOfMemory,
        .headers = list.items,
        .payload = a.dupe(u8, m.payload) catch return error.OutOfMemory,
        .status = m.headers.status(),
    };
}

/// The core's header list: the call's, the message's, and `traceparent`
/// when `c` is a traced request.
fn coreHeaders(c: anytype, buf: *[32]core.Headers.Header, call_headers: []const Header, msg_headers: []const Header) ![]const core.Headers.Header {
    var n: usize = 0;
    for ([_][]const Header{ call_headers, msg_headers }) |list| {
        for (list) |h| {
            if (n == buf.len) return error.InvalidHeader;
            buf[n] = .{ .name = h[0], .value = h[1] };
            n += 1;
        }
    }
    if (internal.requestOf(c)) |req| {
        if (req.trace_id.len == 32 and req.span_id.len == 16 and n < buf.len) {
            const text = std.fmt.allocPrint(c.arena, "00-{s}-{s}-01", .{ req.trace_id, req.span_id }) catch return error.OutOfMemory;
            buf[n] = .{ .name = "traceparent", .value = text };
            n += 1;
        }
    }
    return buf[0..n];
}

/// A subscription read by hand.
pub const Subscription = struct {
    client: *Client,
    inner: *core.Subscription,

    /// The next message (in `c`'s arena), or null once it has ended.
    /// `timeout` null waits as long as it takes.
    pub fn next(self: *Subscription, c: anytype, timeout: ?Duration) Error!?Reply {
        const t: std.Io.Timeout = if (timeout) |d| .{ .duration = .{ .raw = d, .clock = .awake } } else .none;
        const got = self.inner.next(.{ .timeout = t }) catch |err| return self.client.mapError(c, err);
        var m = got orelse return null;
        defer m.deinit();
        return try copyReply(c, m);
    }

    pub fn deinit(self: *Subscription) void {
        self.inner.unsubscribe() catch {};
        self.inner.deinit();
        self.client.gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Handlers

const Handler = struct {
    client: *Client,
    subject: []const u8,
    opts: HandleOptions,
    state: ?*anyopaque,
    run: *const fn (?*anyopaque, *Msg) anyerror!void,
    slots: std.Io.Semaphore,

    /// Subscribes (on every connection that should) and starts delivery.
    fn begin(h: *Handler) !void {
        const cl = h.client;
        for (cl.cores, 0..) |*k, i| {
            // Without a queue group, one subscription is enough: another
            // connection's would deliver every message again.
            if (h.opts.queue == null and i != std.hash.Wyhash.hash(0, h.subject) % cl.cores.len) continue;
            const sub = k.subscribe(h.subject, .{ .queue = h.opts.queue, .pending = h.opts.pending, .overflow = h.opts.overflow }) catch |err| {
                log.err("nats \"{s}\": subscribing to {s} failed: {t}", .{ cl.label, h.subject, err });
                return err;
            };
            try placement.concurrent(&cl.group, cl.io, .{ .executor = i }, deliver, .{ h, sub });
        }
    }

    /// Takes messages from the subscription's queue and starts a task for
    /// each, at most `concurrency` at once.
    fn deliver(h: *Handler, sub: *core.Subscription) std.Io.Cancelable!void {
        const cl = h.client;
        const io = cl.io;
        defer sub.deinit();
        while (true) {
            const got = sub.next(.{}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.SlowConsumer => {
                    log.warn("nats \"{s}\": handler for {s} fell behind: subscription closed", .{ cl.label, h.subject });
                    return;
                },
                else => return,
            };
            var msg = got orelse return;
            h.slots.wait(io) catch {
                msg.deinit();
                return error.Canceled;
            };
            const worker = cl.rr.fetchAdd(1, .monotonic);
            placement.concurrent(&cl.group, io, .{ .executor = worker }, runOne, .{ h, msg }) catch {
                msg.deinit();
                h.slots.post(io);
                log.warn("nats \"{s}\": no task for a message on {s}", .{ cl.label, h.subject });
            };
        }
    }

    fn runOne(h: *Handler, msg0: core.Message) std.Io.Cancelable!void {
        var m = msg0;
        defer m.deinit();
        const cl = h.client;
        const io = cl.io;
        defer h.slots.post(io);
        var arena: std.heap.ArenaAllocator = .init(cl.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "nats-{d}", .{message_counter.fetchAdd(1, .monotonic)}) catch "nats";
        var headers: std.ArrayList(Header) = .empty;
        var it = m.headers.iterator();
        while (it.next()) |hd| headers.append(a, .{ hd.name, hd.value }) catch {};
        var msg: Msg = .{
            .io = io,
            .arena = a,
            .id = a.dupe(u8, id) catch "nats",
            .subject = m.subject,
            .reply_to = m.reply_to,
            .headers = headers.items,
            .payload = m.payload,
            .client = cl,
        };
        const call = cl.observer.start(&msg);
        const bound = internal.callTimeout(h.opts.timeout, null);
        const result: anyerror!void = if (bound) |t| blk: {
            const d: dusty.Deadline = .init(io, .{ .duration = .{ .raw = t, .clock = .awake } });
            break :blk d.run(invoke, .{ h, &msg }) catch |e| e;
        } else invoke(h, &msg);
        if (result) |_| {} else |err| {
            if (err == error.Canceled) return error.Canceled;
            handlerFailed(cl, &msg, err);
        }
        call.end(&msg, "process", h.subject, if (result) |_| null else |e| e);
    }

    fn invoke(h: *Handler, msg: *Msg) anyerror!void {
        return h.run(h.state, msg);
    }
};

/// Logs a handler's failure and, for a request, answers with the NATS
/// micro error headers.
fn handlerFailed(cl: *Client, msg: *Msg, err: anyerror) void {
    const status = dusty.errorStatus(err);
    const code: u16 = if (status) |s| @intCast(@intFromEnum(s)) else 500;
    if (code >= 500) log.warn("{s} handler for {s} failed: {t}", .{ msg.id, msg.subject, err }) else log.debug("{s} handler for {s} failed: {t}", .{ msg.id, msg.subject, err });
    const to = msg.reply_to orelse return;
    var code_text: [8]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_text, "{d}", .{code}) catch "500";
    const phrase = if (status) |s| s.phrase() else "Internal Server Error";
    cl.publishMsg(msg, .{
        .subject = to,
        .headers = &.{ .{ "Nats-Service-Error", phrase }, .{ "Nats-Service-Error-Code", code_str } },
    }) catch {};
}

// ---------------------------------------------------------------------------
// Options helpers

/// The URL list as the core takes it (`nats://host:port`, `tls://host:port`);
/// user:password@ or token@ of the first server becomes `login`.
fn serverList(a: std.mem.Allocator, opts: Options, login: *core.Options.Auth) ![]const []const u8 {
    const text = opts.url orelse url_mod.env(opts.environ, "NATS_URL") orelse "nats://127.0.0.1:4222";
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    var first = true;
    while (it.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len == 0) continue;
        var scheme: []const u8 = "";
        var rest = item;
        if (std.mem.indexOf(u8, item, "://")) |i| {
            scheme = item[0 .. i + 3];
            rest = item[i + 3 ..];
        }
        if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
            const info = rest[0..at];
            rest = rest[at + 1 ..];
            if (first) {
                if (std.mem.indexOfScalar(u8, info, ':')) |colon| {
                    login.* = .{ .user_password = .{ .username = try percentDecode(a, info[0..colon]), .password = try percentDecode(a, info[colon + 1 ..]) } };
                } else login.* = .{ .token = try percentDecode(a, info) };
            }
        }
        first = false;
        try list.append(a, try std.fmt.allocPrint(a, "{s}{s}", .{ scheme, rest }));
    }
    if (list.items.len == 0) return error.InvalidOptions;
    return list.items;
}

fn percentDecode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |b| {
                try out.append(a, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(a, text[i]);
    }
    return out.items;
}

fn anyTlsScheme(servers: []const []const u8) bool {
    for (servers) |s| if (std.ascii.startsWithIgnoreCase(s, "tls://")) return true;
    return false;
}

fn readSecret(a: std.mem.Allocator, io: std.Io, s: Options.Auth.Secret) ![]const u8 {
    return switch (s) {
        .text => |t| t,
        .file => |path| std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch |err| {
            log.err("nats: cannot read {s}: {t}", .{ path, err });
            return error.InvalidOptions;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "nats: the URL list, user:password@ and token@, and tls://" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var login: core.Options.Auth = .none;
    const list = try serverList(a, .{ .url = "tls://app:p%40ss@a.example:4222, nats://b.example" }, &login);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("tls://a.example:4222", list[0]);
    try testing.expectEqualStrings("nats://b.example", list[1]);
    try testing.expectEqualStrings("app", login.user_password.username);
    try testing.expectEqualStrings("p@ss", login.user_password.password);
    try testing.expect(anyTlsScheme(list));

    login = .none;
    const tok = try serverList(a, .{ .url = "s3cret@nats.internal:4222" }, &login);
    try testing.expectEqualStrings("nats.internal:4222", tok[0]);
    try testing.expectEqualStrings("s3cret", login.token);
}

test "nats: errors map to classes and codes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var ctx: db.Ctx = .{ .io = testing.io, .arena = arena_state.allocator() };
    var dummy: Client = undefined;
    dummy.errors = .{};
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectEqual(error.ServiceUnavailable, dummy.mapError(&ctx, error.NoResponders));
    try testing.expectEqualStrings("no_responders", db.lastError(&ctx).?.code);
    try testing.expectEqual(error.ServiceUnavailable, dummy.mapError(&ctx, error.Full));
    try testing.expectEqualStrings("outbound_full", db.lastError(&ctx).?.code);
    try testing.expectEqual(error.GatewayTimeout, dummy.mapError(&ctx, error.Timeout));
    try testing.expectEqual(error.Database, dummy.mapError(&ctx, error.PermissionDenied));
    try testing.expectEqual(error.Canceled, dummy.mapError(&ctx, error.Canceled));
}

test "nats: Reply headers and the micro error" {
    const r: Reply = .{
        .subject = "s",
        .headers = &.{ .{ "Nats-Service-Error", "Not Found" }, .{ "Nats-Service-Error-Code", "404" } },
        .payload = "",
        .status = null,
    };
    try testing.expectEqualStrings("404", r.header("Nats-Service-Error-Code").?);
    try testing.expectEqual(@as(u16, 404), r.serviceError().?.code);
    try testing.expect(r.header("nats-service-error") == null);
}

test {
    _ = core;
    _ = nkeys;
    _ = auth;
    _ = jetstream;
    _ = @import("live_test.zig");
}
