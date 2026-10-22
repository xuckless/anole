//! The C ABI's configuration: one JSON document (`include/anole.schema.json`
//! is its schema) parsed by `anole_server_create`, and the Anole server it
//! describes, built on the server's own thread at start. Everything that
//! never needs the language (listeners, fixed responses, static files, the
//! response cache, compression, CORS, JWT, rate limits, request IDs, access
//! logs, health and metrics) is Anole's own middleware and handlers; the
//! ABI only configures them.
const std = @import("std");
const anole = @import("../root.zig");
const http = anole.http;
const features = anole.features;

/// The document. Unknown keys are an error, with the line and column.
pub const Config = struct {
    /// Executor threads: 0 for one per CPU (cgroup-aware).
    executors: u32 = 0,
    listeners: []const Listener = &.{.{}},
    limits: Limits = .{},
    timeouts: Timeouts = .{},
    http3: Http3 = .{},
    /// Proxies in front whose `X-Forwarded-For` (and PROXY protocol)
    /// Anole trusts for the client's address: 0 trusts none.
    trusted_proxy_hops: u8 = 0,
    /// Middleware for every route, in order, before the route's own.
    middleware: []const Middleware = &.{},
    routes: []const Route = &.{},
    observe: Observe = .{},

    pub const Listener = struct {
        /// Unique; "http-<port>" / "https-<port>" when left out. Requests
        /// carry it (`listener` in the record).
        name: ?[]const u8 = null,
        /// "127.0.0.1" (this machine), "" (every interface, IPv6 and IPv4),
        /// "0.0.0.0", "::".
        address: []const u8 = "127.0.0.1",
        /// 0 picks a free port (`anole_server_port`).
        port: u16 = 8080,
        /// A unix domain socket at this path instead of address and port.
        unix: ?[]const u8 = null,
        /// TLS with this certificate; cleartext when left out.
        tls: ?Tls = null,
        http1: bool = true,
        /// HTTP/2: h2 by ALPN over TLS, h2c (prior knowledge) in cleartext.
        http2: bool = true,
        /// HTTP/3 on the same port over UDP (a TLS listener; one per server).
        http3: bool = false,
        /// Connections start with a PROXY protocol header.
        proxy_protocol: bool = false,
    };

    pub const Tls = struct {
        /// PEM files, read at start (and by anole_server_reload_certificates).
        cert_file: ?[]const u8 = null,
        key_file: ?[]const u8 = null,
        /// Or PEM text.
        cert_pem: ?[]const u8 = null,
        key_pem: ?[]const u8 = null,
        /// Or a fresh self-signed certificate for localhost (development).
        self_signed: bool = false,
        /// ALPN protocols in order; default "h2", "http/1.1".
        alpn: ?[]const []const u8 = null,
    };

    pub const Limits = struct {
        /// The largest request body, inline or streamed: past it, 413.
        body_max: u64 = 1 << 20,
        /// Bodies up to this come inline in the request record; larger
        /// ones are read with anole_req_read. At most 1 GiB.
        inline_body_max: u32 = 64 * 1024,
        /// Requests handed to consumers and not yet answered, per executor;
        /// past it, 503.
        max_inflight: u32 = 1024,
        /// Events waiting for a consumer, per executor: 0 for twice
        /// max_inflight. A full queue holds requests back (backpressure).
        queue: u32 = 0,
        /// A streamed response or a WebSocket past this many bytes waiting
        /// to go out answers ANOLE_BUSY.
        stream_high_water: u32 = 256 * 1024,
        ws_high_water: u32 = 1 << 20,
        /// The largest WebSocket message, in or out (after inflating). At
        /// most 1 GiB.
        ws_max_message: u32 = 1 << 20,
        /// Open connections at most; 0 follows the open-file limit.
        max_connections: u32 = 0,
    };

    pub const Timeouts = struct {
        /// The default deadline of a consumer request: 504 from Anole after
        /// it. A route's `timeout_ms` overrides it (at most 16 distinct
        /// values per server).
        request_ms: u32 = 30_000,
        /// How long the drain waits for requests in flight.
        shutdown_ms: u32 = 10_000,
        /// An idle keep-alive connection is closed after this.
        keepalive_ms: u32 = 60_000,
        /// Ring a consumer's doorbell again when events wait and it has not
        /// polled for this long (a lost wake); 0 never.
        rewake_ms: u32 = 20,
    };

    pub const Http3 = struct {
        max_streams_bidi: u64 = 100,
        idle_timeout_ms: u32 = 30_000,
        /// Advertise HTTP/3 with Alt-Svc on the TLS listener's responses.
        alt_svc: bool = true,
        /// Take 0-RTT from resuming clients (replayable: safe methods only
        /// run before the handshake completes).
        early_data: bool = false,
    };

    pub const Middleware = union(enum) {
        request_id: RequestId,
        access_log: AccessLog,
        compress: Compress,
        cors: Cors,
        jwt: Jwt,
        rate_limit: RateLimit,
    };

    pub const RequestId = struct {
        header: []const u8 = "X-Request-Id",
        trust_incoming: bool = false,
    };
    pub const AccessLog = struct {
        format: enum { text, json } = .text,
        /// Paths not logged: exact, or a prefix ending in "*".
        exclude: []const []const u8 = &.{},
    };
    pub const Compress = struct {};
    pub const Cors = struct {
        /// Empty allows every origin.
        origins: []const []const u8 = &.{},
        methods: ?[]const u8 = null,
        headers: ?[]const u8 = null,
        expose: ?[]const u8 = null,
        credentials: bool = false,
        max_age: ?u32 = 600,
    };
    pub const Jwt = struct {
        /// The provider's JWK Set URL, fetched and refreshed; or
        jwks_url: ?[]const u8 = null,
        /// a JWK Set ({"keys": [...]}) given here.
        jwks: ?std.json.Value = null,
        issuer: ?[]const u8 = null,
        audience: ?[]const u8 = null,
        leeway_s: i64 = 60,
        require_exp: bool = true,
        /// String claims a token must carry.
        required_claims: []const []const u8 = &.{"sub"},
        /// Each must be in the `scope` claim; 403 otherwise.
        scopes: []const []const u8 = &.{},
        realm: ?[]const u8 = null,
    };
    pub const RateLimit = struct {
        /// Requests per window.
        limit: u32 = 100,
        window_ms: i64 = 60_000,
        /// How many at once; 0 means `limit`.
        burst: u32 = 0,
        /// "ip" (the client's address) or "header:<name>".
        key: []const u8 = "ip",
        /// Keys remembered at most (least recently used out first).
        max_entries: u32 = 10_000,
    };

    pub const Observe = struct {
        /// Prometheus metrics, with HTTP request counts.
        metrics: ?Metrics = null,
        /// /healthz and /readyz (not ready while draining).
        health: ?Health = null,
    };
    pub const Metrics = struct { path: []const u8 = "/metrics" };
    pub const Health = struct {
        live: []const u8 = "/healthz",
        ready: []const u8 = "/readyz",
    };

    pub const Route = struct {
        /// "GET", "POST", ...; left out: every method.
        method: ?[]const u8 = null,
        /// "/users/:id", "/files/*rest".
        path: []const u8,
        /// Exactly one of these four:
        /// a consumer's route id: the request goes to a consumer;
        handler: ?u32 = null,
        /// a fixed response, served natively;
        respond: ?Fixed = null,
        /// files under a directory (the path is the prefix);
        static: ?Static = null,
        /// a WebSocket endpoint whose events go to a consumer.
        websocket: ?WebSocket = null,
        /// This route's request deadline (consumer routes).
        timeout_ms: ?u32 = null,
        /// Handler and respond routes run on the protocol's reader when
        /// they can (HTTP/2, HTTP/3: no task per request, the answer
        /// detached); false gives each request a task of its own.
        no_wait: bool = true,
        /// Keep GET answers (consumer and fixed routes) per executor.
        cache: ?Cache = null,
        /// After the global ones.
        middleware: []const Middleware = &.{},
    };
    pub const Fixed = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: std.json.ArrayHashMap([]const u8) = .{},
    };
    pub const Static = struct {
        dir: []const u8,
        index: ?[]const u8 = "index.html",
        /// Precompressed siblings to look for: "br", "zstd", "gzip".
        precompressed: []const []const u8 = &.{},
        cache_control: ?[]const u8 = null,
        hide_dotfiles: bool = true,
    };
    pub const WebSocket = struct {
        /// The consumer's route id for this endpoint's events.
        handler: u32,
        /// permessage-deflate when the client offers it.
        compression: bool = true,
        /// Close 1001 when the server drains.
        close_on_drain: bool = true,
    };
    pub const Cache = struct {
        /// When the answer's Cache-Control does not say.
        ttl_ms: u32 = 10_000,
        /// Also keep answers to requests with credentials (only when the
        /// answer does not depend on who asks).
        authenticated: bool = false,
        max_entries: u32 = 1024,
        max_bytes: u64 = 16 << 20,
    };
};

pub const max_timeouts = 16;

/// The most an inline body or a WebSocket message may be (one event each).
pub const max_record_payload: u32 = 1 << 30;

/// What `check` found wrong, for anole_last_error.
pub const Problem = error{Config};

pub fn methodOf(name: []const u8) ?http.Method {
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&buf, name));
}

/// Parses `json` into `arena`, with "UnknownField at line L column C" and
/// the like in `why` on failure.
pub fn parse(arena: std.mem.Allocator, json: []const u8, why: *std.Io.Writer) Problem!Config {
    var diag: std.json.Diagnostics = .{};
    var scanner = std.json.Scanner.initCompleteInput(arena, json);
    scanner.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &scanner, .{ .allocate = .alloc_always }) catch |err| {
        why.print("config: {t} at line {d} column {d}", .{ err, diag.getLine(), diag.getColumn() }) catch {};
        return error.Config;
    };
    try check(cfg, why);
    return cfg;
}

fn fail(why: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Problem {
    why.print("config: " ++ fmt, args) catch {};
    return error.Config;
}

/// What the types cannot say.
fn check(cfg: Config, why: *std.Io.Writer) Problem!void {
    if (cfg.listeners.len == 0) return fail(why, "listeners: at least one", .{});
    if (cfg.executors > 256) return fail(why, "executors: at most 256", .{});
    if (cfg.limits.max_inflight == 0 or cfg.limits.max_inflight > 1 << 20) return fail(why, "limits.max_inflight: 1 to 1048576", .{});
    if (cfg.limits.inline_body_max > cfg.limits.body_max) return fail(why, "limits.inline_body_max is above limits.body_max", .{});
    // Events carry their length in 32 bits: what goes inside one is bounded
    // well below that (the request head comes on top of an inline body).
    if (cfg.limits.inline_body_max > max_record_payload) return fail(why, "limits.inline_body_max: at most {d}", .{max_record_payload});
    if (cfg.limits.ws_max_message > max_record_payload) return fail(why, "limits.ws_max_message: at most {d}", .{max_record_payload});
    var http3_listeners: usize = 0;
    for (cfg.listeners, 0..) |l, i| {
        if (l.tls) |t| {
            if (comptime features.tls != .boringssl) return fail(why, "listeners[{d}].tls: TLS is not built in (-Dtls=boringssl)", .{i});
            const files = t.cert_file != null or t.key_file != null;
            const pem = t.cert_pem != null or t.key_pem != null;
            const n = @as(u8, @intFromBool(files)) + @intFromBool(pem) + @intFromBool(t.self_signed);
            if (n != 1) return fail(why, "listeners[{d}].tls: exactly one of cert_file/key_file, cert_pem/key_pem, self_signed", .{i});
            if (files and (t.cert_file == null or t.key_file == null)) return fail(why, "listeners[{d}].tls: cert_file and key_file go together", .{i});
            if (pem and (t.cert_pem == null or t.key_pem == null)) return fail(why, "listeners[{d}].tls: cert_pem and key_pem go together", .{i});
        }
        if (l.http3) {
            if (comptime !features.http3) return fail(why, "listeners[{d}].http3: HTTP/3 is not built in (-Dhttp3)", .{i});
            if (l.tls == null) return fail(why, "listeners[{d}].http3 needs tls", .{i});
            http3_listeners += 1;
        }
        if (l.http2 and !features.http2 and l.tls != null) {}
        if (l.name) |n| if (n.len == 0 or n.len > 255 or std.mem.indexOfScalar(u8, n, ':') != null)
            return fail(why, "listeners[{d}].name: 1-255 bytes, no ':'", .{i});
        for (cfg.listeners[0..i]) |other| if (l.name != null and other.name != null and std.mem.eql(u8, l.name.?, other.name.?))
            return fail(why, "listeners[{d}].name \"{s}\" is taken", .{ i, l.name.? });
    }
    if (http3_listeners > 1) return fail(why, "listeners: http3 on one listener at most", .{});
    try checkMiddleware(cfg.middleware, "middleware", why);
    var timeouts: [max_timeouts]u32 = undefined;
    var ntimeouts: usize = 1;
    timeouts[0] = cfg.timeouts.request_ms;
    for (cfg.routes, 0..) |r, i| {
        const kinds = @as(u8, @intFromBool(r.handler != null)) + @intFromBool(r.respond != null) +
            @intFromBool(r.static != null) + @intFromBool(r.websocket != null);
        if (kinds != 1) return fail(why, "routes[{d}]: exactly one of handler, respond, static, websocket", .{i});
        if (r.path.len == 0 or r.path[0] != '/') return fail(why, "routes[{d}].path must start with '/'", .{i});
        if (r.method) |m| if (methodOf(m) == null) return fail(why, "routes[{d}].method \"{s}\" is unknown", .{ i, m });
        if (r.respond) |f| _ = http.Status.fromCode(f.status) catch return fail(why, "routes[{d}].respond.status {d} is not a status Anole knows", .{ i, f.status });
        if (r.websocket != null) {
            if (comptime !features.websocket) return fail(why, "routes[{d}].websocket: WebSocket is not built in (-Dwebsocket)", .{i});
            if (r.method) |m| if (methodOf(m) != .get) return fail(why, "routes[{d}]: a websocket route is GET", .{i});
        }
        if (r.static != null and r.method != null) return fail(why, "routes[{d}]: a static route takes no method (GET and HEAD)", .{i});
        if (r.cache != null and r.handler == null and r.respond == null) return fail(why, "routes[{d}].cache: on handler and respond routes", .{i});
        if (r.timeout_ms) |t| {
            if (r.handler == null) return fail(why, "routes[{d}].timeout_ms: on handler routes", .{i});
            if (std.mem.indexOfScalar(u32, timeouts[0..ntimeouts], t) == null) {
                if (ntimeouts == max_timeouts) return fail(why, "routes: at most {d} distinct timeout_ms values", .{max_timeouts});
                timeouts[ntimeouts] = t;
                ntimeouts += 1;
            }
        }
        var buf: [32]u8 = undefined;
        try checkMiddleware(r.middleware, std.fmt.bufPrint(&buf, "routes[{d}].middleware", .{i}) catch "routes[].middleware", why);
    }
}

fn checkMiddleware(list: []const Config.Middleware, where: []const u8, why: *std.Io.Writer) Problem!void {
    for (list, 0..) |m, i| switch (m) {
        .jwt => |j| {
            if (comptime !features.auth) return fail(why, "{s}[{d}].jwt: auth is not built in (-Dauth)", .{ where, i });
            if ((j.jwks_url == null) == (j.jwks == null)) return fail(why, "{s}[{d}].jwt: exactly one of jwks_url and jwks", .{ where, i });
        },
        .rate_limit => |r| {
            if (!std.mem.eql(u8, r.key, "ip") and !std.mem.startsWith(u8, r.key, "header:"))
                return fail(why, "{s}[{d}].rate_limit.key: \"ip\" or \"header:<name>\"", .{ where, i });
            if (r.limit == 0 or r.window_ms <= 0) return fail(why, "{s}[{d}].rate_limit: limit and window_ms must be positive", .{ where, i });
        },
        .compress => if (comptime !features.compression) return fail(why, "{s}[{d}].compress: compression is not built in (-Dcompression)", .{ where, i }),
        else => {},
    };
}

/// Whether requests behind `list` can run on the protocol's reader and
/// detach (`anole.http.Detached`): none of it may wait. A JWT middleware
/// that fetches keys can.
pub fn neverWaits(list: []const Config.Middleware) bool {
    for (list) |m| switch (m) {
        .jwt => |j| if (j.jwks_url != null) return false,
        else => {},
    };
    return true;
}

// ---------------------------------------------------------------------------
// Building the server's middleware

/// A rate limit keyed by the client's address or a header, on a memory
/// limiter of its own: `anole.ratelimit.Middleware`'s answers.
pub const RateLimitMw = struct {
    limiter: *anole.ratelimit.MemoryLimiter,
    header: ?[]const u8,
    policy: anole.ratelimit.Policy,

    pub const detach_safe = true;

    pub fn execute(self: *const RateLimitMw, req: *http.Request, res: *http.Response, executor: anytype) !void {
        var key_buf: [128]u8 = undefined;
        const key = if (self.header) |h| req.headers.get(h) orelse "" else anole.ratelimit.clientAddress(req, &key_buf);
        const r = self.limiter.limiter().take(key, 1, self.policy) catch return executor.next();
        try res.header("RateLimit-Limit", try std.fmt.allocPrint(res.arena, "{d}", .{r.limit}));
        try res.header("RateLimit-Remaining", try std.fmt.allocPrint(res.arena, "{d}", .{r.remaining}));
        try res.header("RateLimit-Reset", try std.fmt.allocPrint(res.arena, "{d}", .{r.reset_seconds}));
        if (!r.allowed) {
            try res.header("Retry-After", try std.fmt.allocPrint(res.arena, "{d}", .{r.retry_after_seconds}));
            res.status = .too_many_requests;
            res.content_type = .text;
            res.body = "429 Too Many Requests\n";
            return;
        }
        return executor.next();
    }

    pub fn deinit(self: *RateLimitMw) void {
        self.limiter.deinit();
    }
};

/// Anole's middleware for one configuration entry, as a handle the server
/// owns. `keep` holds what must outlive the server's start (keyrings,
/// limiters), freed by the engine.
pub fn middleware(app: *anole.App, arena: std.mem.Allocator, m: Config.Middleware) !http.Middleware(void) {
    switch (m) {
        .request_id => |c| return app.middleware(http.middleware.RequestId.init(.{ .header = c.header, .trust_incoming = c.trust_incoming })),
        .access_log => |c| return app.middleware(anole.observe.AccessLog.init(.{
            .format = switch (c.format) {
                .text => .text,
                .json => .json,
            },
            .exclude = c.exclude,
        })),
        .compress => {
            if (comptime !features.compression) unreachable;
            return app.middleware(http.middleware.Compress.init());
        },
        .cors => |c| return app.middleware(http.middleware.Cors.init(.{
            .origins = c.origins,
            .methods = c.methods,
            .headers = c.headers,
            .expose = c.expose,
            .credentials = c.credentials,
            .max_age = c.max_age,
        })),
        .jwt => |c| {
            if (comptime !features.auth) unreachable;
            const keys: anole.auth.bearer.Keys = if (c.jwks_url) |url| blk: {
                const ring = try arena.create(anole.auth.Keyring);
                ring.* = .init(app.gpa, app.io(), app.client(), url);
                break :blk .{ .keyring = ring };
            } else blk: {
                const text = try std.json.Stringify.valueAlloc(arena, c.jwks.?, .{});
                break :blk .{ .static = try anole.auth.parseJwks(arena, text) };
            };
            return app.middleware(anole.auth.RequireJwt.init(keys, .{
                .issuer = c.issuer,
                .audience = c.audience,
                .leeway_seconds = c.leeway_s,
                .require_exp = c.require_exp,
            }, .{ .required_claims = c.required_claims, .scopes = c.scopes, .realm = c.realm }));
        },
        .rate_limit => |c| {
            const limiter = try arena.create(anole.ratelimit.MemoryLimiter);
            limiter.* = .init(app.gpa, app.io(), .{ .max_entries = c.max_entries });
            return app.middleware(RateLimitMw{
                .limiter = limiter,
                .header = if (std.mem.startsWith(u8, c.key, "header:")) c.key["header:".len..] else null,
                .policy = .{ .limit = c.limit, .window_ms = c.window_ms, .burst = c.burst },
            });
        },
    }
}

pub fn precompressed(arena: std.mem.Allocator, names: []const []const u8) ![]const http.core.Precompressed {
    const out = try arena.alloc(http.core.Precompressed, names.len);
    for (names, out) |n, *o| {
        o.* = std.meta.stringToEnum(http.core.Precompressed, n) orelse return error.Config;
    }
    return out;
}

/// A fixed response route's data.
pub const FixedRoute = struct {
    status: http.Status,
    body: []const u8,
    headers: []const [2][]const u8,

    pub fn handler(req: *http.Request, res: *http.Response) anyerror!void {
        const f: *const FixedRoute = @ptrCast(@alignCast(req.route.?.data.?));
        res.status = f.status;
        for (f.headers) |h| try res.header(h[0], h[1]);
        res.body = f.body;
    }
};

pub fn fixed(arena: std.mem.Allocator, f: Config.Fixed) !*FixedRoute {
    const hs = try arena.alloc([2][]const u8, f.headers.map.count());
    var it = f.headers.map.iterator();
    var j: usize = 0;
    while (it.next()) |kv| : (j += 1) hs[j] = .{ kv.key_ptr.*, kv.value_ptr.* };
    const out = try arena.create(FixedRoute);
    out.* = .{ .status = http.Status.fromCode(f.status) catch .internal_server_error, .body = f.body, .headers = hs };
    return out;
}

test "parse: the defaults, a full document, and what is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);

    const d = try parse(a, "{}", &why);
    try std.testing.expectEqual(@as(usize, 1), d.listeners.len);
    try std.testing.expectEqual(@as(u32, 30_000), d.timeouts.request_ms);

    const full_doc =
        \\{"executors": 2,
        \\ "listeners": [{"name": "web", "address": "127.0.0.1", "port": 0}],
        \\ "limits": {"inline_body_max": 1024, "max_inflight": 8},
        \\ "middleware": [{"request_id": {}}, {"cors": {"origins": ["https://a.example"]}},
        \\                {"rate_limit": {"limit": 5, "key": "header:X-Key"}}],
        \\ "routes": [
        \\   {"method": "GET", "path": "/a", "handler": 1, "timeout_ms": 500, "cache": {"ttl_ms": 1000}},
        \\   {"path": "/b", "respond": {"status": 201, "body": "x", "headers": {"x-y": "z"}}}
    ;
    const ws_route = ",\n   {\"path\": \"/ws\", \"websocket\": {\"handler\": 2}}";
    const end = "\n ],\n \"observe\": {\"metrics\": {}, \"health\": {}}}";
    // The WebSocket route only where WebSocket is built in.
    const full = if (features.websocket) full_doc ++ ws_route ++ end else full_doc ++ end;
    const f = try parse(a, full, &why);
    try std.testing.expectEqual(@as(usize, if (features.websocket) 3 else 2), f.routes.len);
    try std.testing.expectEqual(@as(?u32, 500), f.routes[0].timeout_ms);
    try std.testing.expect(f.middleware[2] == .rate_limit);

    const bad = [_][]const u8{
        "{\"nope\": 1}",
        "{\"routes\": [{\"path\": \"/x\"}]}",
        "{\"routes\": [{\"path\": \"/x\", \"handler\": 1, \"respond\": {}}]}",
        "{\"routes\": [{\"path\": \"x\", \"handler\": 1}]}",
        "{\"routes\": [{\"method\": \"FETCH\", \"path\": \"/x\", \"handler\": 1}]}",
        "{\"listeners\": []}",
        "{\"middleware\": [{\"rate_limit\": {\"key\": \"cookie\"}}]}",
        "{\"limits\": {\"inline_body_max\": 10, \"body_max\": 5}}",
        // A record carries its length in 32 bits.
        "{\"limits\": {\"inline_body_max\": 4294967295, \"body_max\": 8589934592}}",
        "{\"limits\": {\"ws_max_message\": 4294967295}}",
    };
    for (bad) |doc| {
        why.end = 0;
        try std.testing.expectError(error.Config, parse(a, doc, &why));
        try std.testing.expect(why.buffered().len > 0);
    }
}

test "parse: include/anole.schema.json names every field Config has, and no other" {
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    const defs = root.object.get("$defs").?.object;
    try SchemaCheck.walk(Config, root, defs);
}

const SchemaCheck = struct {
    fn resolve(node: std.json.Value, defs: std.json.ObjectMap) std.json.Value {
        var n = node;
        while (true) {
            if (n.object.get("$ref")) |r| {
                n = defs.get(r.string["#/$defs/".len..]).?;
                continue;
            }
            if (n.object.get("anyOf")) |any| {
                n = any.array.items[0];
                continue;
            }
            return n;
        }
    }

    fn walk(comptime T: type, node_in: std.json.Value, defs: std.json.ObjectMap) error{SchemaOutOfDate}!void {
        if (T == std.json.Value) return;
        const node = resolve(node_in, defs);
        switch (@typeInfo(T)) {
            .optional => |o| return walk(o.child, node, defs),
            .pointer => |p| if (p.child != u8) return walk(p.child, node.object.get("items").?, defs),
            .@"struct" => |s| {
                if (T == std.json.Value or T == std.json.ArrayHashMap([]const u8)) return;
                const props = node.object.get("properties") orelse {
                    std.debug.print("schema: no properties for {s}\n", .{@typeName(T)});
                    return error.SchemaOutOfDate;
                };
                if (props.object.count() != s.field_names.len) {
                    std.debug.print("schema: {s} has {d} fields, the schema {d}\n", .{ @typeName(T), s.field_names.len, props.object.count() });
                    return error.SchemaOutOfDate;
                }
                inline for (s.field_names, s.field_types) |name, FT| {
                    const p = props.object.get(name) orelse {
                        std.debug.print("schema: {s}.{s} missing\n", .{ @typeName(T), name });
                        return error.SchemaOutOfDate;
                    };
                    try walk(FT, p, defs);
                }
            },
            .@"union" => |u| {
                const variants = node.object.get("oneOf").?.array.items;
                if (variants.len != u.field_names.len) return error.SchemaOutOfDate;
                inline for (u.field_names, u.field_types) |name, FT| {
                    const v = for (variants) |v| {
                        if (v.object.get("properties").?.object.get(name)) |p| break p;
                    } else {
                        std.debug.print("schema: middleware {s} missing\n", .{name});
                        return error.SchemaOutOfDate;
                    };
                    try walk(FT, v, defs);
                }
            },
            else => {},
        }
    }
};
