//! `anole.Server(Ctx)`: one entry point over the zio runtime, the core's server
//! and Anole's TLS. It owns the runtime (pinned scheduling, one executor per
//! core), builds the listeners (cleartext with h2c, TLS with ALPN), and
//! `run` serves until SIGINT, SIGTERM or `stop`, then drains.
//!
//!     pub fn main(init: std.process.Init) !void {
//!         var app = try anole.App.init(init.gpa, .{});
//!         defer app.deinit();
//!         app.use(anole.middleware.RequestId.init(.{}));
//!         app.get("/users/:id", getUser);
//!         try app.listen(":3000");
//!     }
//!
//! `anole.App` is `Server(void)` with a two-argument `init`. With state,
//! `Server(App).init(gpa, options, &state)`; the listeners can also be set
//! in `options` (`http`, `https`, `http3`, and any number more in
//! `listeners`) and served with `run`:
//!
//!     var app = try anole.Server(void).init(init.gpa, .{
//!         .http = .{ .port = 8080 },
//!         .https = .{ .port = 8443, .cert = .dev_self_signed },
//!     }, {});
//!     ...
//!     try app.run();
//!
//! Everything the HTTP core offers stays reachable: `app.router` is its
//! router, `app.server` its server, and `anole.http` the whole of it.
const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const zio = @import("zio");
const http = @import("http/root.zig");
const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};
const tls_testing = if (features.tls == .boringssl) @import("tls/testing.zig") else struct {};
const handoff = @import("handoff.zig");
const errors = @import("errors.zig");
const modes = @import("modes.zig");
const env_mod = @import("env.zig");
const net_mod = @import("net/root.zig");
/// SIGUSR2 (restart) and SIGHUP (certificate reload): not on Windows.
const unix_signals = builtin.os.tag != .windows;

/// The text `/config` shows, rendered once at init: the resolved modes, the
/// options with secrets left out, the `.env` files read (names and counts
/// only) and the features this build has.
fn renderConsoleConfig(a: std.mem.Allocator, opts: *const Options, mode: *const modes.Resolved) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.writeAll("# modes\n");
    var lines: [2048]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&lines);
    modes.writeLines(mode, .{ .used_listen_tls = false }, &lw) catch {};
    var it = std.mem.splitScalar(u8, lw.buffered(), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try w.print("{s}\n", .{if (line[0] == '!') line[1..] else line});
    }
    try w.writeAll("\n# options\n");
    try console.config_text.writeOptions(w, opts.*);
    if (mode.files) |f| {
        try w.writeAll("\n# .env files read (names and value counts)\n");
        for (f.read) |r| try w.print("{s}: {d} values\n", .{ r.path, r.count });
    }
    try w.writeAll("\n# build\n");
    try w.print("anole {s}, {s}\n", .{ features.version, @tagName(builtin.mode) });
    inline for (.{ "tls", "http2", "http3", "grpc", "websocket", "auth", "compression", "brotli", "json", "redis", "postgres", "sqlite", "mongodb", "nats", "kafka", "openapi" }) |name| {
        try w.print("{s} = {any}\n", .{ name, @field(features, name) });
    }
    return aw.written();
}

/// `name` in `environ`; on Windows, where `Environ` holds UTF-16 with
/// nothing to slice, in the C library's environment.
fn envVar(environ: std.process.Environ, name: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return @import("db/url.zig").env(null, name);
    return environ.getPosix(name);
}
const blocking = @import("blocking.zig");
const sd_notify = @import("sd_notify.zig");
const early_data = @import("early_data.zig");
const ratelimit = @import("ratelimit/root.zig");
const h3 = if (features.http3) @import("h3/root.zig") else struct {};
const address_mod = @import("address.zig");
const handlers = @import("handlers.zig");
const typed = @import("typed.zig");
const openapi_mod = if (features.openapi) @import("openapi/root.zig") else @import("openapi/off.zig");
const banner_mod = @import("banner.zig");
const console = @import("console/root.zig");
const console_host = @import("console/host.zig");
const anole_log = @import("anole_log");
const log_mod = @import("log.zig");
const route_pattern = @import("dusty").route_pattern;

/// The compile-time pattern check of a route that is not an ordinary
/// handler route (WebSocket, WebTransport).
fn checkPattern(comptime method: []const u8, comptime path: []const u8) void {
    if (route_pattern.problem(path)) |p| @compileError("anole: route " ++ method ++ " " ++ path ++ ": " ++ route_pattern.comptimeMessage(p));
}
const ResponseCache = @import("cache/response.zig").ResponseCache;
const client_mod = @import("client.zig");
const observe = @import("observe/root.zig");
const websocket = if (features.websocket) @import("websocket/root.zig") else struct {
    pub const UpgradeOptions = struct {};
};
const webtransport_mod = if (features.http3) @import("webtransport.zig") else struct {
    pub const AcceptOptions = struct {};
};
const sqlite_mod = if (features.sqlite) @import("sqlite/root.zig") else struct {
    pub const Client = void;
};
const pg_mod = if (features.postgres) @import("pg/root.zig") else struct {
    pub const Options = struct {};
    pub const Client = void;
};
const mongodb_mod = if (features.mongodb) @import("mongodb/root.zig") else struct {
    pub const Options = struct {};
    pub const Client = void;
};
const nats_mod = if (features.nats) @import("nats/root.zig") else struct {
    pub const Options = struct {};
    pub const Client = struct {};
};
const resilience_mod = @import("resilience/root.zig");
const redis_mod = if (features.redis) @import("redis/root.zig") else struct {
    pub const Options = struct {};
    pub const Client = void;
};
const kafka_mod = if (features.kafka) @import("kafka/root.zig") else struct {
    pub const Options = struct {};
    pub const Client = void;
};
const grpc_mod = if (features.grpc) @import("grpc/root.zig") else struct {
    pub const Health = void;
    pub const RegisterOptions = struct {};
};

/// The zio configuration Anole is built for. An executable declares it in
/// its root file: `pub const zio_options = anole.zio_options;`. Pinned: a
/// connection and everything it spawns stay on one OS thread, which the
/// nghttp2 sessions, BoringSSL's error queue and zig-protobuf rely on.
/// `fast_accept`: an accept loop takes the connections waiting in its
/// backlog directly, and the accept and spawn budgets grow with the run
/// queue, so new connections, parked ones waking and new HTTP/2 streams are
/// not left behind thousands of busy connections.
pub const zio_options: zio.Options = .{ .scheduling = .pinned, .fast_accept = true, .diagnostics = true };

/// Anole's own build of zio is pinned by default (build.zig), so a program
/// that declares no `zio_options` gets it; one that declares them must not
/// ask for work stealing.
fn checkZioOptions() void {
    const root = @import("root");
    if (!@hasDecl(root, "zio_options")) return;
    const scheduling: zio.Scheduling = root.zio_options.scheduling;
    if (scheduling == .work_stealing) @compileError("anole.Server needs zio's pinned scheduling, but the root file's zio_options " ++
        "asks for work stealing. Declare `pub const zio_options = anole.zio_options;`, or keep " ++
        "`.scheduling = .pinned` among your own zio options.");
}

/// zio's executor count (`.auto` or `.exact(n)`), which zio does not export
/// by name.
pub const ExecutorCount = @FieldType(@typeInfo(@TypeOf(zio.Runtime.init)).@"fn".param_types[1].?, "executors");

/// Set while an `anole.Server` is alive on this thread: its zio runtime
/// makes the thread its first executor, which a second runtime would take
/// over.
threadlocal var server_on_thread: bool = false;

/// A length of time: `.fromSeconds(30)`, `.fromMilliseconds(250)`.
pub const Duration = std.Io.Duration;

/// The index (in the options' listeners) of the listener whose UDP socket
/// could not be bound, on the thread that was starting (`init` fails and
/// leaves no server to ask); the C ABI reads it.
pub threadlocal var failed_listener_index: ?usize = null;

/// `anole.ServerOptions`: everything `App.init` and `Server(Ctx).init`
/// take. Every field has a default, so `.{}` is a working server (its
/// listener named later by `listen` or `listenTls`).
///
/// The HTTP behaviour groups (`timeouts`, `limits`, `proxy`, `request`,
/// `response`, `http2`, `errors`) have the same names and defaults as the
/// C ABI's JSON configuration.
pub const Options = struct {
    // Listeners

    /// The cleartext listener. When neither this nor `https` is set,
    /// 127.0.0.1:8080; with `https` set and this null, none: an HTTPS-only
    /// server. Set both for both.
    http: ?Http = null,
    /// The TLS listener, or null for none. Needs `-Dtls=boringssl`.
    https: ?Https = null,
    /// HTTP/3 over QUIC, beside `https` and with its certificate, or null
    /// for none. Needs `-Dhttp3` (on by default) and `https`. With
    /// `listeners`, the settings for the one marked `http3`.
    http3: ?Http3 = null,
    /// More listeners, for full control: each with its own address (or
    /// unix socket), TLS certificate and protocols, served after `http`
    /// and `https` and through the same routes. One port per protocol, an
    /// internal port for metrics, a unix socket for a proxy on the same
    /// machine. See `Listener`.
    ///
    ///     .listeners = &.{
    ///         .{ .name = "public", .address = "", .port = 443, .tls = .{ .cert = cert }, .http3 = true },
    ///         .{ .name = "admin", .port = 9090 },
    ///     },
    listeners: []const Listener = &.{},
    /// Whether `listenTls` also serves HTTP/3 on the same port number (UDP),
    /// advertised with `Alt-Svc`, when HTTP/3 is built in (the default
    /// `full` profile): with `http3`'s settings when set, else the defaults.
    ///
    /// Null: the deployment's default (on, except behind a proxy or on a
    /// platform, which terminate TLS themselves: docs/config.md).
    listen_tls_http3: ?bool = null,

    // HTTP behaviour: the same groups and names as the C ABI's JSON config.

    /// Time limits: the request, the head, a stalled write, keep-alive, the
    /// graceful drain.
    timeouts: Timeouts = .{},
    /// Size and count limits.
    limits: Limits = .{},
    /// Trust in proxies in front of the server.
    proxy: Proxy = .{},
    /// How requests are read.
    request: RequestOptions = .{},
    /// How responses are written.
    response: ResponseOptions = .{},
    /// HTTP/2 settings, for h2c and h2 over TLS. 250 concurrent streams per
    /// connection by default.
    http2: Http2 = .{},
    /// How the server writes its own error answers (404, 405, the status
    /// an error maps to, `res.fail`): `.auto` sends `{"error":"..."}` to a
    /// request that takes JSON and text to others, `.json` and `.text`
    /// always.
    errors: http.ErrorFormat = .auto,
    /// Answers handler and middleware errors in place of the default
    /// mapping, which it can fall back on with `anole.defaultError(req,
    /// res, err)`: no `Ctx` with `uncaughtError` needed.
    error_handler: ?http.ErrorHandler = null,
    /// Logging, process-wide: the format (`.auto`: JSON Lines in production,
    /// text otherwise), a level filter, a service name written in every
    /// JSON record. docs/logging.md.
    log: anole_log.Options = .{},
    /// Print the startup banner (the anole, the version, the address) when
    /// stderr is a terminal and the logs are text. Never under systemd, in
    /// JSON logs or when piped; off with false or `ANOLE_NO_BANNER=1`. The
    /// C ABI's default is false (config `banner`).
    banner: bool = true,

    // Modes (docs/config.md)

    /// development or production. Null: ANOLE_ENV, else development in a
    /// Debug build and production in a release build (production in tests).
    /// What it changes: docs/config.md.
    environment: ?modes.Environment = null,
    /// What sits in front of the server. Null: ANOLE_DEPLOYMENT, else
    /// standalone. What each changes: docs/config.md.
    deployment: ?modes.Deployment = null,
    /// The `.env` files read at `init` (first wins per key), relative to the
    /// working directory. Null: the environment's (development:
    /// ".env.development.local", ".env.local", ".env.development", ".env";
    /// production: none); `&.{}`: none.
    env_files: ?[]const []const u8 = null,
    /// A 500 answer for an error with no status of its own names the error
    /// ("Internal Server Error: ConnectionRefused"). Null: on in development.
    error_detail: ?bool = null,
    /// Internal: a resolution made already (the C ABI resolves at create).
    _resolved: ?*const modes.Resolved = null,

    // Process and runtime

    /// Executors (OS threads) for the runtime: one per CPU (cgroup-aware) by
    /// default.
    executors: ExecutorCount = .auto,
    /// The most stack a task (a connection, a stream, a socket) may grow
    /// to; past it the process crashes. Address space, not memory: a task
    /// holds only the pages it touches, and gives back those below where it
    /// waits once it has waited a second (Linux). What the size does cost
    /// is page tables: about 2 KiB per open connection at the default,
    /// 4 KiB at 8 MiB. Raise it for handlers that recurse deeply or keep
    /// large buffers on the stack. Below 1 MiB is not advised: some
    /// bundled code takes a lot of stack at once (zlib-ng's CRC-32 for
    /// gzip, 128 KiB in one frame; the DNS resolver, 73 KiB), and a
    /// handler's own needs are the application's to know. On Windows (a
    /// development target) the default is 4 MiB: its Debug frames are much
    /// larger, and BoringSSL's certificate loading overflowed 1 MiB there.
    max_stack_size: usize = if (builtin.os.tag == .windows) 4 * 1024 * 1024 else 1024 * 1024,
    /// Raise the soft open-file limit to the hard one when the server is
    /// made, as Go does at startup: every connection is a file descriptor,
    /// and the soft limit is often 1024. `limits.max_connections` follows
    /// the limit by default. Processes started from here inherit it (see
    /// docs/server.md, "Many connections", for programs that use `select`).
    raise_fd_limit: bool = true,
    /// Whether `run` listens for signals: SIGINT and SIGTERM drain and
    /// stop, SIGHUP reloads certificates (SIGUSR2 needs `process` too).
    /// False when Anole is embedded in a process whose signals belong to
    /// someone else (the C ABI under Node or Python): `stop` is then the
    /// only way to drain.
    signals: bool = true,
    /// The process's arguments and environment (`init.minimal`). With them
    /// the server takes listening sockets handed over by systemd socket
    /// activation or by the process it replaces (`LISTEN_FDS`), restarts
    /// without downtime on SIGUSR2 (a new copy of the program takes the
    /// sockets, and this one drains once it is serving), and tells systemd
    /// how it is doing when `NOTIFY_SOCKET` is set (`Type=notify`). Without
    /// them, none of these. (With them, listeners are single sockets, not
    /// one per core.)
    process: ?std.process.Init.Minimal = null,
    /// How long a restart waits for the new process to be serving before
    /// giving up on it and carrying on.
    restart_timeout: Duration = .fromSeconds(10),
    /// A blocking pool (`anole.blocking`): jobs that run on threads beside
    /// the executors, at most this many at once. Password hashing uses it.
    /// Null: none, and such work runs on the request's executor.
    blocking: ?blocking.Options = null,
    /// The live console (docs/console.md): a control socket that
    /// `anole console` attaches to, and in development `c` + Enter in the
    /// terminal. Nothing is collected on the request path unless a console
    /// is attached.
    console: console.Options = .{},
    /// Internal: the language runtime the C ABI's console shows
    /// ("node 22.11.0").
    _console_runtime: ?[]const u8 = null,

    // Outbound

    /// The server's outbound HTTP client (`app.client()`,
    /// `anole.client(req)`): its pool of idle connections
    /// (`max_idle_per_host`, 256 per executor; `max_idle_connections`,
    /// 1024 per executor; `idle_timeout`, 90 s), its timeout (30 s), the
    /// CAs it trusts (`tls`), redirects and size limits.
    client: http.ClientOptions = .{},

    // ---- p3/net ----
    // ---- end p3/net ----

    // ---- p3/jobs ----
    // ---- end p3/jobs ----

    // ---- p3/webhooks ----
    // ---- end p3/webhooks ----

    // ---- p3/realtime ----
    // ---- end p3/realtime ----

    // ---- p3/s3 ----
    // ---- end p3/s3 ----

    // ---- p3/smtp ----
    // ---- end p3/smtp ----

    // ---- p3/lambda ----
    // ---- end p3/lambda ----

    /// `Options.timeouts`. A duration is null for none.
    pub const Timeouts = struct {
        /// The whole request: reading it, the handler, the response (and
        /// the TLS handshake). Ends early for a streamed or file body
        /// (`write` then bounds each write). Null: none.
        request: ?Duration = .fromSeconds(30),
        /// The request head on HTTP/1.x (Slowloris). Null: `request` alone.
        read_header: ?Duration = .fromSeconds(10),
        /// One write the peer does not take for this long ends the
        /// response (HTTP/1.1: the connection; HTTP/2, HTTP/3: the
        /// stream). Applies once a stream or file body has started, and to
        /// every HTTP/2 connection write. Null: none.
        write: ?Duration = .fromSeconds(30),
        /// An idle keep-alive connection is closed after this. Null: never.
        keepalive: ?Duration = .fromSeconds(75),
        /// An idle HTTP/1.1 connection gives up its task after this
        /// (parks). Null or zero: never parks.
        idle_park: ?Duration = .fromSeconds(1),
        /// The graceful drain. Null: wait for every connection.
        shutdown: ?Duration = .fromSeconds(10),
    };

    /// `Options.limits`.
    pub const Limits = struct {
        /// The largest request body: `req.body()`, `req.reader()` (declared
        /// and chunked) and an early 413 on a larger `Content-Length`.
        body_max: usize = 1 << 20,
        /// The request line and headers; larger is 431.
        max_head_size: usize = 16 * 1024,
        max_header_count: usize = 32,
        max_param_count: usize = 8,
        max_query_count: usize = 32,
        max_form_count: usize = 32,
        max_multiform_count: usize = 32,
        /// Open connections at most; 0 follows the open-file limit
        /// (10 000 on Windows).
        max_connections: u32 = 0,
        /// Requests per keep-alive connection; null: no limit.
        max_requests_per_connection: ?u32 = null,
        /// The largest WebSocket message, in or out (after inflating): the
        /// default for routes whose upgrade options set none.
        ws_max_message: usize = 1 << 20,
    };

    /// `Options.proxy`.
    pub const Proxy = struct {
        /// The proxies in front: addresses ("192.0.2.7"), networks in CIDR
        /// notation ("10.0.0.0/8", "2001:db8::/32"), or the names "loopback"
        /// (127.0.0.0/8, ::1), "private" (10.0.0.0/8, 172.16.0.0/12,
        /// 192.168.0.0/16, fc00::/7) and "link_local" (169.254.0.0/16,
        /// fe80::/10). Only a request whose peer is one of them has its
        /// X-Forwarded-For, X-Forwarded-Proto (and, with trust_forwarded_host,
        /// X-Forwarded-Host) read; the client is the rightmost X-Forwarded-For
        /// address that is not one of them. On a listener with proxy_protocol
        /// and no proxy_protocol_from, only they may connect. Null:
        /// ANOLE_PROXY_TRUSTED, else the deployment's (behind_proxy, anole_lb,
        /// platform: "loopback" and "private"; standalone: none, and
        /// trusted_hops alone decides, as in 0.2). `&.{}`: no proxy is trusted.
        trusted: ?[]const []const u8 = null,
        /// A fixed number of proxies instead of the walk: the client is the
        /// trusted_hops-th X-Forwarded-For address from the right. With
        /// `trusted` set, only from a trusted peer. 0: the walk (or nothing,
        /// with no `trusted`).
        trusted_hops: u8 = 0,
        /// From a trusted proxy: the last `X-Forwarded-Proto` value sets
        /// `req.secure`.
        trust_forwarded_proto: bool = true,
        /// From a trusted proxy: the last `X-Forwarded-Host` value is
        /// `req.host`.
        trust_forwarded_host: bool = false,
    };

    /// `Options.request`.
    pub const RequestOptions = struct {
        /// HTTP/1.1 without exactly one Host is 400.
        require_host: bool = true,
        /// Undo Content-Encoding on request bodies.
        decompress: bool = true,
        /// Keep a connection's request buffers between requests.
        keep_buffers: bool = false,
    };

    /// `Options.response`: `write_buffer_size`, `date`,
    /// `default_content_type`, `max_header_count`, `brotli_quality`.
    pub const ResponseOptions = http.ServerConfig.Response;
    /// `Options.http2`: the core's HTTP/2 settings, 250 streams by default.
    pub const Http2 = http.ServerConfig.Http2;

    /// `Options.http`: a cleartext listener.
    pub const Http = struct {
        /// The interface to bind: "127.0.0.1" (this machine), "" (every
        /// interface, IPv6 and IPv4 alike: one dual-stack socket on `::`,
        /// or `0.0.0.0` where the system has no IPv6; what
        /// `listen(":3000")` binds), "0.0.0.0" (every IPv4 interface
        /// only), "::" (every IPv6 one, and IPv4 too where the system's
        /// default maps it).
        /// Null: the deployment's default ("127.0.0.1"; "" for anole_lb
        /// and platform).
        address: ?[]const u8 = null,
        /// 0 picks a free port (see `addresses`). Null: 8080, or $PORT
        /// under the platform deployment.
        port: ?u16 = null,
        /// Cleartext HTTP/2 for clients that open with its preface, beside
        /// HTTP/1.1 on the same port.
        h2c: bool = features.http2,
        /// Every connection starts with a PROXY protocol header (v1 or v2)
        /// from a load balancer in front, which gives the client's real
        /// address. Only for a port nothing else can reach, or with
        /// `proxy_protocol_from` naming the load balancers. Null: on under
        /// the anole_lb deployment, else off.
        proxy_protocol: ?bool = null,
        /// With `proxy_protocol`: the peers allowed to connect, in CIDR
        /// notation ("10.0.0.0/8", "2001:db8::/32", "192.0.2.7"); a
        /// connection from anywhere else is closed unread. Empty:
        /// `proxy.trusted` when set, else any peer.
        proxy_protocol_from: []const []const u8 = &.{},
    };

    /// `Options.http3`: HTTP/3 over QUIC beside the TLS listener.
    pub const Http3 = struct {
        /// The UDP address, as `Http.address` (so "" is dual-stack);
        /// `https`'s when null (the usual setup: one port number, over TCP
        /// and UDP).
        address: ?[]const u8 = null,
        /// The UDP port; null for the TLS listener's.
        port: ?u16 = null,
        /// Advertise HTTP/3 to HTTP/1.1 and HTTP/2 clients (`Alt-Svc`), so
        /// browsers switch to it.
        alt_svc: bool = true,
        /// Concurrent requests per connection.
        max_streams_bidi: u64 = 100,
        /// Make every new client prove its address with a Retry first (one
        /// more round trip; resists spoofed-source floods).
        validate_address: bool = false,
        /// How long a connection may sit idle before it is closed.
        idle_timeout: std.Io.Duration = .fromSeconds(30),
        /// Take 0-RTT (early data) from clients resuming a session, which
        /// saves them a round trip. GET, HEAD and OPTIONS that come in
        /// 0-RTT run at once, with `Early-Data: 1` among their headers
        /// (`anole.early_data.isEarly`); other methods wait until the
        /// handshake completes, which a replayed flight never does.
        early_data: bool = false,
        /// QUIC interop runner tests only: also speak "hq-interop"
        /// (HTTP/0.9), serving the files under this directory. Refused
        /// (`error.HqInteropNotAllowed`) unless the program's root file
        /// declares `pub const anole_hq_interop = true;`.
        hq_interop_root: ?[]const u8 = null,
        /// Move clients that offer QUIC v2 (RFC 9369) beside v1 to v2;
        /// false keeps them on v1 unless they start in v2.
        prefer_v2: bool = true,
        /// UDP sockets on Linux, each served on an executor of its own,
        /// with the kernel steering each connection's datagrams to its
        /// socket: null for one per executor, as the TCP accept loops. At
        /// most 255; macOS always uses one.
        sockets: ?u16 = null,
        /// Extended CONNECT (RFC 9220): WebSockets over HTTP/3, as over
        /// HTTP/2.
        enable_connect_protocol: bool = true,
        /// Speak WebTransport (draft-02, what Chrome and Firefox use), for
        /// `anole.webtransport.accept`. `app.webtransport` turns it on.
        webtransport: bool = false,
        /// Requests for `no_wait` routes that arrive whole run on the
        /// endpoint task, with no task each (as over HTTP/2). A `no_wait`
        /// handler that waits anyway then holds up every HTTP/3 connection
        /// on its core; false gives each request its task again.
        inline_no_wait: bool = true,
    };

    /// `Options.https`: a TLS listener with HTTP/2 and HTTP/1.1 by ALPN.
    pub const Https = struct {
        /// As `Http.address`.
        address: ?[]const u8 = null,
        port: u16 = 8443,
        /// The certificate and key: `.fromFiles(...)`, `.fromPem(...)` or
        /// `.dev_self_signed`.
        cert: Cert,
        /// "h2" and "http/1.1" when HTTP/2 is built in, else "http/1.1".
        alpn: ?[]const []const u8 = null,
        /// Mutual TLS: ask clients for a certificate signed by these CAs
        /// (`req.peerCertificate()` has it). Null: none asked for.
        client_auth: ?ClientAuth = null,
        /// As `Http.proxy_protocol`.
        proxy_protocol: ?bool = null,
        /// As `Http.proxy_protocol_from`.
        proxy_protocol_from: []const []const u8 = &.{},
    };

    /// A listener in `listeners`: where, plain or TLS, and what it speaks.
    pub const Listener = struct {
        /// What the listener is called: socket activation and SIGUSR2
        /// restarts match inherited sockets by it (`LISTEN_FDNAMES`), and
        /// handlers see it in `req.listener.name` (`anole.onlyOn`). Unique
        /// among the server's listeners ("http" and "https" are `http`'s
        /// and `https`'s), at most 255 bytes, no ':'. Null: "http-<port>",
        /// "https-<port>", or "unix-<path>".
        name: ?[]const u8 = null,
        /// As `Http.address`.
        address: ?[]const u8 = null,
        /// 0 picks a free port (see `addresses`). Null: as `Http.port`.
        port: ?u16 = null,
        /// A unix domain socket at this path instead of `address` and
        /// `port`. A socket file left behind by a server that is gone is
        /// replaced; one that something still listens on is an error.
        unix: ?[]const u8 = null,
        /// Permission bits for the socket file of a `unix` listener
        /// (owner and group may connect; others may not). A client needs
        /// write permission on the file. `0o666` opens it to every local
        /// user; ignored on Windows and for abstract sockets.
        unix_mode: u16 = 0o660,
        /// TLS with this certificate, or null for cleartext.
        tls: ?Tls = null,
        /// HTTP/1.1 (and 1.0).
        http1: bool = true,
        /// HTTP/2: "h2" by ALPN over TLS; on a cleartext listener, for
        /// clients that open with its preface (h2c, prior knowledge).
        /// Needs `-Dhttp2`.
        http2: bool = features.http2,
        /// HTTP/3 on the same port number over UDP (or `Options.http3`'s
        /// address and port), with `Options.http3`'s settings, and
        /// advertised with `Alt-Svc` on this listener's responses. TLS
        /// listeners only, and one per server. Needs `-Dhttp3`.
        http3: bool = false,
        /// As `Http.proxy_protocol`.
        proxy_protocol: ?bool = null,
        /// As `Http.proxy_protocol_from`.
        proxy_protocol_from: []const []const u8 = &.{},
        // ---- p3/net ----
        /// Raw TCP instead of HTTP: `anole.net.tcp(Ctx, Handler, .{...})`, or
        /// `app.tcp`. `http1`/`http2` are ignored; `http3 = true` is refused.
        /// Needs a port (0: a free one) or `unix`. See docs/net.md.
        tcp: ?net_mod.TcpService = null,
        /// UDP instead of HTTP: `anole.net.udp(...)`, or `app.udp`. Not with
        /// `tls`, `unix` or `proxy_protocol`.
        udp: ?net_mod.UdpService = null,
        // ---- end p3/net ----

        /// `Listener.tls`.
        pub const Tls = struct {
            /// Listeners that name the same certificate (the same files,
            /// the same PEM, `dev_self_signed`) share one copy of it.
            cert: Cert,
            /// Offered by ALPN, in order. Null: "h2" and "http/1.1", those
            /// of the two the listener speaks.
            alpn: ?[]const []const u8 = null,
            /// As `Https.client_auth`.
            client_auth: ?ClientAuth = null,
        };
    };

    /// `anole.Cert`: a certificate and key, for a listener or a client.
    pub const Cert = http.Cert;
    /// `anole.ClientAuth`: mutual TLS on a listener.
    pub const ClientAuth = http.ClientAuth;
};

/// Whether a listener on `address` serving `cert` gets the development
/// certificate warning: `dev_self_signed` anywhere but loopback or a unix
/// socket.
fn warnsDevCert(cert: Options.Cert, address: http.Address) bool {
    if (cert != .dev_self_signed) return false;
    return switch (address) {
        .ip => |ip| !address_mod.isLoopback(ip),
        .unix => false,
    };
}

/// The core's server configuration for `opts`: the only place one is built.
/// The listeners are set later, by `listenOn`.
fn coreConfig(opts: Options, mode: *const modes.Resolved) http.ServerConfig {
    return .{
        .timeout = .{
            .request = opts.timeouts.request,
            .read_header = opts.timeouts.read_header,
            .write = opts.timeouts.write,
            .keepalive = opts.timeouts.keepalive,
            .request_count = if (opts.limits.max_requests_per_connection) |n| n else null,
            .idle_park = opts.timeouts.idle_park,
            .shutdown = opts.timeouts.shutdown,
        },
        .request = .{
            .max_body_size = opts.limits.body_max,
            .max_content_length = opts.limits.body_max,
            .require_host = opts.request.require_host,
            .decompress = opts.request.decompress,
            .buffer_size = opts.limits.max_head_size,
            .keep_buffers_between_requests = opts.request.keep_buffers,
            .max_header_count = opts.limits.max_header_count,
            .max_param_count = opts.limits.max_param_count,
            .max_query_count = opts.limits.max_query_count,
            .max_form_count = opts.limits.max_form_count,
            .max_multiform_count = opts.limits.max_multiform_count,
            .ws_max_message = opts.limits.ws_max_message,
        },
        .response = opts.response,
        .http2 = opts.http2,
        .listeners = &.{},
        .trusted_proxy_hops = opts.proxy.trusted_hops,
        .trusted_proxies = mode.trusted,
        .warn_untrusted_peer = mode.warn_untrusted_peer,
        .error_detail = mode.error_detail,
        .trust_forwarded_proto = opts.proxy.trust_forwarded_proto,
        .trust_forwarded_host = opts.proxy.trust_forwarded_host,
        .max_connections = if (opts.limits.max_connections == 0)
            http.ServerConfig.max_connections_from_fd_limit
        else
            opts.limits.max_connections,
        .errors = opts.errors,
        .error_handler = opts.error_handler,
    };
}

/// `Server(void)` with `init(gpa, options)`: a server without state, for
/// handlers that take `(req, res)`.
pub const App = ServerOf(void, true);

/// Middleware that lets requests through on the listener named `name`
/// alone (`Options.Listener.name`; "http" and "https" are `http`'s and
/// `https`'s, HTTP/3 its TLS listener's), and answers 404 on the others:
/// routes for an internal port. Every listener shares the routes; this
/// keeps some of them to one.
///
///     const admin = app.group("/admin", .{anole.onlyOn("admin")});
pub fn onlyOn(name: []const u8) OnlyOn {
    return .{ .name = name };
}

/// The middleware `onlyOn` returns.
pub const OnlyOn = struct {
    name: []const u8,

    /// Does nothing after `next()`: requests behind it can detach.
    pub const detach_safe = true;

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const OnlyOn, req: *http.Request, _: *http.Response, next: anytype) !void {
        if (!std.mem.eql(u8, req.listener.name, self.name)) return error.NotFound;
        return next.call();
    }
};

/// A server whose handlers share the state `Ctx`: `init(gpa, options,
/// &state)`, and handlers `fn (state: *Ctx, req, res) !void` (or plain
/// `(req, res)`). For no state, `App`.
///
///     var store: Store = .{ .gpa = init.gpa };
///     var app = try anole.Server(Store).init(init.gpa, .{}, &store);
///     defer app.deinit();
///     app.get("/users/:id", getUser); // fn getUser(store: *Store, req, res) !void
///     try app.listen(":3000");
///
/// A `Ctx` may also declare `notFound(self, req, res)`,
/// `uncaughtError(self, req, res, err)` and `dispatch(self, action, req,
/// res)` to take over those steps.
pub fn Server(comptime Ctx: type) type {
    return ServerOf(Ctx, false);
}

/// `Server(Ctx)`, or with `app_init` `App`: the same server, whose `init`
/// takes no state.
fn ServerOf(comptime Ctx: type, comptime app_init: bool) type {
    comptime checkZioOptions();
    return struct {
        const Self = @This();
        const Cert = Options.Cert;
        /// The server's state type (`void` for `App`).
        pub const State = Ctx;
        /// A handler as the router stores it: `fn (*Request, *Response)
        /// anyerror!void`, with `*Ctx` first on a server with state.
        pub const Handler = http.Router(Ctx).Handler;

        /// The allocator given to `init`.
        gpa: std.mem.Allocator,
        /// The zio runtime the server owns; `io()` is its `std.Io`.
        rt: *zio.Runtime,
        /// Holds what the server points into for its whole life: the
        /// listeners, certificates and middleware copies. So `Self` can
        /// move after `init`.
        arena: *std.heap.ArenaAllocator,
        /// The HTTP core's server underneath.
        server: *http.Server(Ctx),
        /// The router the route methods add to, for what they do not
        /// cover (`app.router.addRouteWith`).
        router: *http.Router(Ctx),
        stopped: *std.Io.Event,
        /// For hand-off: the process (args, environment), and the
        /// listening sockets to pass on.
        process: ?std.process.Init.Minimal = null,
        held: []const handoff.Listener = &.{},
        // ---- p3/net ----
        /// The raw TCP listeners' services and the UDP listeners' sockets
        /// (docs/net.md), freed with the server.
        net_tcp: std.ArrayList(*net_mod.TcpListener) = .empty,
        net_udp: std.ArrayList(*net_mod.UdpGroup) = .empty,
        /// Why a raw listener's options were refused (the startup error's text).
        net_why: ?[]const u8 = null,
        /// A UDP listener's run failed.
        net_failed: ?anyerror = null,
        // ---- end p3/net ----
        restart_timeout: Duration = .fromSeconds(10),
        /// `Options.signals`.
        signals: bool = true,
        /// `Options.banner`.
        banner: bool = true,
        /// The HTTP/3 endpoint, when `Options.http3` asked for one.
        h3: H3Endpoint,
        /// The blocking pool, when `Options.blocking` asked for one.
        blocking_pool: ?*blocking.Pool = null,
        /// The resolved modes (docs/config.md): environment, deployment and
        /// what they fill in. In the server's arena.
        mode: *modes.Resolved,
        /// The live console: its resolved options, the running console (from
        /// `run` to the drain), the event `/restart` sets, and what `/config`
        /// shows.
        console_resolved: console.Resolved,
        console: ?*console.Console = null,
        console_restart: *std.Io.Event,
        console_config_text: []const u8 = "",
        console_runtime: ?[]const u8 = null,
        console_embedded: bool = false,
        last_successor_pid: i32 = 0,
        /// `listenTls` set up the TLS listener (for the startup line).
        used_listen_tls: bool = false,
        /// The TLS listeners' certificates, one per distinct source, for
        /// `reloadCertificates`; empty without a TLS listener.
        certs: []const *CertState = &.{},
        /// Middleware the server copied (`use`, `group`, `middleware`),
        /// deinitialized with it.
        owned_middleware: std.ArrayList(http.Middleware(Ctx)) = .empty,
        /// What `init` was given when it named no listener (neither
        /// `http` nor `https`): `listen`, `listenTls` or `run` sets them up
        /// from it. Null once they are.
        pending: ?Options = null,
        /// The `Alt-Svc` middleware, once there is one.
        alt_svc: ?*AltSvc = null,
        /// For tests: stands for ANOLE_OPENAPI_OUT / ANOLE_OPENAPI_CHECK.
        _openapi_env: ?OpenApiEnv = null,
        /// What the one-line helpers made (`client`, `metrics`, `health`,
        /// `grpcHealth`, `tracing`, `staticDir`), freed with the server.
        extras: *Extras,

        /// What `zig build openapi` and `openapi-check` pass the app.
        pub const OpenApiEnv = struct { out: ?[]const u8 = null, check: ?[]const u8 = null };

        const Extras = struct {
            /// The outbound client (`client()`, `anole.client(req)`).
            client: http.Client,
            client_entry: client_mod.Entry,
            client_registered: bool,
            metrics: ?*observe.metrics.Registry = null,
            metrics_path: []const u8 = "",
            metrics_listener: ?[]const u8 = null,
            health: ?*observe.Health = null,
            /// `metrics` and `health` register their routes when serving
            /// starts, so `use` can still follow them.
            routes_added: bool = false,
            grpc_health: ?*grpc_mod.Health = null,
            exporter: ?*observe.trace.Exporter = null,
            /// The breaker and retry series of the outbound client, when it has a policy.
            resilience: ?*resilience_mod.Binding = null,
            dirs: std.ArrayList(std.Io.Dir) = .empty,
            /// A WebTransport route exists: the HTTP/3 listener speaks it.
            webtransport: bool = false,
            /// The database connectors and response caches made here
            /// (`postgres`, `sqlite`, `mongodb`, `redis`, `responseCache`),
            /// in order.
            connectors: std.ArrayList(Connector) = .empty,
            connectors_started: bool = false,
            /// The connector whose start failed, and why (for the startup error's text).
            failed_system: ?[]const u8 = null,
            failed_cause: ?[]const u8 = null,
            /// One certificate reload at a time.
            cert_mutex: std.Io.Mutex = .init,
            /// The routes recorded for the OpenAPI document (`-Dopenapi`),
            /// and what `app.openapi` asked for.
            doc_entries: if (features.openapi) std.ArrayList(openapi_mod.Entry) else void = if (features.openapi) .empty else {},
            openapi_options: if (features.openapi) ?openapi_mod.Options else void = if (features.openapi) null else {},
            /// `serveOpenApi` could not build the document; `run` fails with it.
            openapi_failed: if (features.openapi) ?anyerror else void = if (features.openapi) null else {},
        };

        /// A database connector the server made: when serving starts it
        /// gets the app's metrics, tracer and health checks (whichever
        /// exist by then, so the helpers may come in any order), and it is
        /// closed with the server, after the drain.
        const Connector = struct {
            context: *anyopaque,
            start: *const fn (context: *anyopaque, metrics: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) anyerror!void,
            deinit: *const fn (context: *anyopaque) void,
            /// "postgres", "redis"...; "connector" for the rest.
            name: []const u8 = "connector",
            /// Writes the console's `/db` entry fields ("system", "name",
            /// "target", "pools") without the braces.
            describe: *const fn (context: *anyopaque, name: []const u8, w: *std.Io.Writer) anyerror!void,

            fn systemOf(comptime T: type) []const u8 {
                const n = @typeName(T);
                inline for (.{ "postgres:pg", "sqlite:sqlite", "mongodb:mongodb", "redis:redis", "nats:nats", "kafka:kafka", "smtp:smtp", "s3:s3" }) |pair| {
                    const colon = comptime std.mem.indexOfScalar(u8, pair, ':').?;
                    if (std.mem.find(u8, n, pair[colon + 1 ..]) != null) return pair[0..colon];
                }
                return "connector";
            }

            fn of(comptime T: type, value: *T) Connector {
                const Hooks = struct {
                    fn start(context: *anyopaque, metrics_: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health_: ?*observe.Health) anyerror!void {
                        const v: *T = @ptrCast(@alignCast(context));
                        return v.start(metrics_, tracer, health_);
                    }
                    fn deinit(context: *anyopaque) void {
                        const v: *T = @ptrCast(@alignCast(context));
                        v.deinit();
                    }
                    fn describe(context: *anyopaque, name: []const u8, w: *std.Io.Writer) anyerror!void {
                        const v: *T = @ptrCast(@alignCast(context));
                        if (comptime @hasDecl(T, "consoleInfo")) return v.consoleInfo(w);
                        try w.print("\"system\":\"{s}\",\"name\":\"{s}\",\"target\":\"\",\"pools\":[]", .{ name, name });
                    }
                };
                return .{ .context = value, .start = Hooks.start, .deinit = Hooks.deinit, .describe = Hooks.describe, .name = comptime systemOf(T) };
            }
        };

        const H3Endpoint = if (features.http3) ?*h3.Endpoint(Ctx) else void;

        /// A certificate the TLS listeners serve: the PEM in use, where a
        /// reload reads it again, and the listener configurations the core
        /// serves from, whose `pem` a reload points at the new one.
        /// Listeners that name the same source share one.
        const CertState = struct {
            gpa: std.mem.Allocator,
            /// Owned, the key zeroed when freed.
            pem: Pem,
            /// For `.files`: the paths each reload reads again. Owned.
            files: ?struct { cert_path: []u8, key_path: []u8 } = null,
            /// What the options named, to find listeners that share it.
            /// Only read while the listeners are set up.
            source: Options.Cert,
            /// The listeners serving it.
            listeners: std.ArrayList(*http.Listener) = .empty,
            /// The TLS listener HTTP/3 serves the port of, when it serves
            /// this certificate: its client CAs are HTTP/3's.
            h3_listener: ?*http.Listener = null,

            /// Whether `a` and `b` name the same certificate.
            fn sameSource(a: Options.Cert, b: Options.Cert) bool {
                return switch (a) {
                    .pem => |p| b == .pem and std.mem.eql(u8, p.cert, b.pem.cert) and std.mem.eql(u8, p.key, b.pem.key),
                    .files => |f| b == .files and std.mem.eql(u8, f.cert_path, b.files.cert_path) and
                        std.mem.eql(u8, f.key_path, b.files.key_path),
                    .dev_self_signed => b == .dev_self_signed,
                };
            }

            const Pem = struct {
                cert: []u8,
                key: []u8,

                fn dupe(p: Pem, gpa: std.mem.Allocator) !Pem {
                    const cert = try gpa.dupe(u8, p.cert);
                    errdefer gpa.free(cert);
                    return .{ .cert = cert, .key = try gpa.dupe(u8, p.key) };
                }

                fn deinit(p: *Pem, gpa: std.mem.Allocator) void {
                    gpa.free(p.cert);
                    std.crypto.secureZero(u8, p.key);
                    gpa.free(p.key);
                    p.* = undefined;
                }
            };

            /// The PEM `cert` names: copied, read from its files, or made
            /// (`dev_self_signed`).
            fn load(gpa: std.mem.Allocator, io_: std.Io, cert: Options.Cert) !Pem {
                switch (cert) {
                    .pem => |p| {
                        const cert_pem = try gpa.dupe(u8, p.cert);
                        errdefer gpa.free(cert_pem);
                        return .{ .cert = cert_pem, .key = try gpa.dupe(u8, p.key) };
                    },
                    .files => |f| {
                        const cert_pem = try readPem(gpa, io_, f.cert_path, "certificate");
                        errdefer gpa.free(cert_pem);
                        return .{ .cert = cert_pem, .key = try readPem(gpa, io_, f.key_path, "key") };
                    },
                    .dev_self_signed => {
                        if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
                        const made = try tls.selfSigned(gpa, .{});
                        return .{ .cert = made.cert, .key = made.key };
                    },
                }
            }

            /// A PEM file, with its path in the log line when it cannot
            /// be read.
            fn readPem(gpa: std.mem.Allocator, io_: std.Io, path: []const u8, what: []const u8) ![]u8 {
                return std.Io.Dir.cwd().readFileAlloc(io_, path, gpa, .limited(max_pem_len)) catch |err| {
                    errors.log.err("cannot read the TLS {s} \"{s}\": {t}", .{ what, path, err });
                    return err;
                };
            }

            fn setSource(state: *CertState, cert: Options.Cert) !void {
                var files: @FieldType(CertState, "files") = null;
                if (cert == .files) {
                    const cert_path = try state.gpa.dupe(u8, cert.files.cert_path);
                    errdefer state.gpa.free(cert_path);
                    files = .{ .cert_path = cert_path, .key_path = try state.gpa.dupe(u8, cert.files.key_path) };
                }
                state.freeSource();
                state.files = files;
            }

            fn freeSource(state: *CertState) void {
                if (state.files) |f| {
                    state.gpa.free(f.cert_path);
                    state.gpa.free(f.key_path);
                }
                state.files = null;
            }

            fn deinit(state: *CertState) void {
                state.freeSource();
                state.pem.deinit(state.gpa);
            }
        };

        /// A certificate or key file larger than this is refused.
        const max_pem_len = 1 << 20;

        /// `Alt-Svc` on responses from the TLS listener HTTP/3 serves the
        /// port of (`listener`) that did not come over HTTP/3, once HTTP/3
        /// is set up (`value`).
        const AltSvc = struct {
            value: ?[]const u8 = null,
            listener: ?*const http.Listener = null,

            /// Does nothing after `next()`: requests behind it can detach.
            pub const detach_safe = true;

            /// Never waits: no I/O, so `no_wait` routes may sit behind it.
            pub const no_wait = true;

            pub fn execute(self: *const AltSvc, req: *http.Request, res: *http.Response, next: anytype) !void {
                if (self.value) |v| if (req.version_major != 3 and self.listener != null and req.listener == self.listener.?) try res.header("Alt-Svc", v);
                return next.call();
            }
        };

        /// `App.init(gpa, options)`, or `Server(Ctx).init(gpa, options,
        /// state)`: the runtime, the server and the routes' home. The
        /// listeners `options` names (`http`, `https`, `http3`) are set up
        /// here; with neither `http` nor `https`, by `listen`, `listenTls`
        /// or `run` (127.0.0.1:8080).
        pub const init = if (app_init) initApp else initState;

        fn initApp(gpa: std.mem.Allocator, opts: Options) errors.ServerError!Self {
            return initState(gpa, opts, {});
        }

        fn initState(gpa: std.mem.Allocator, opts: Options, ctx: if (Ctx == void) void else *Ctx) errors.ServerError!Self {
            return initStateInner(gpa, opts, ctx) catch |err| errors.toServerError(err);
        }

        fn initStateInner(gpa: std.mem.Allocator, opts: Options, ctx: if (Ctx == void) void else *Ctx) !Self {
            // zio binds the runtime to this thread (its first executor), and
            // a second runtime would take the thread over from the first.
            if (server_on_thread) return error.ServerAlreadyOnThread;
            // systemd's notify socket is this process's to use, not its
            // children's: kept, and taken out of the environment.
            if (opts.process) |p| sd_notify.take(p.environ);
            // Before anything opens a socket, and before `run` works out
            // the connection cap from it.
            if (opts.raise_fd_limit) if (http.fd_limit.raiseSoftLimit()) |r| {
                std.log.scoped(.anole).debug("raised the open-file limit from {d} to {d}", .{ r.from, r.to });
            };
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            errdefer {
                arena.deinit();
                gpa.destroy(arena);
            }
            const a = arena.allocator();

            // The modes first: they can size the runtime, and the `.env`
            // files they read reach every environment read after this.
            const mode = try a.create(modes.Resolved);
            if (opts._resolved) |m| {
                mode.* = m.*;
            } else {
                var why_buf: [512]u8 = undefined;
                var why: std.Io.Writer = .fixed(&why_buf);
                mode.* = resolveModes(a, &opts, &why) catch |err| {
                    errors.log.err("{s}", .{why.buffered()});
                    return err;
                };
            }

            applyLogOptions(&opts, mode);

            var console_resolved: console.Resolved = undefined;
            {
                var cwhy_buf: [256]u8 = undefined;
                var cwhy: std.Io.Writer = .fixed(&cwhy_buf);
                console_resolved = console.resolve(opts.console, .process, mode.environment, mode.deployment, .current, &cwhy) catch |err| {
                    errors.log.err("{s}", .{cwhy.buffered()});
                    return err;
                };
            }
            const console_config_text: []const u8 = if (features.console and console_resolved.enabled) renderConsoleConfig(a, &opts, mode) catch "" else "";

            const rt = try zio.Runtime.init(gpa, .{
                .executors = opts.executors,
                .stack_pool = .{
                    .maximum_size = opts.max_stack_size,
                    .committed_size = @min(opts.max_stack_size, 256 * 1024),
                    // The stacks of tasks that ended, such as those of
                    // connections that parked (`timeout.idle_park`), go back
                    // to the system within seconds rather than minutes: the
                    // pool keeps what was in use at once during the last
                    // interval, and half of what it kept before.
                    .shrink_interval = .fromSeconds(2),
                },
            });
            errdefer rt.deinit();
            const rt_io = rt.io();
            server_on_thread = true;
            errdefer server_on_thread = false;

            const server_config = coreConfig(opts, mode);
            const server = try a.create(http.Server(Ctx));
            server.* = .init(gpa, rt_io, server_config, ctx);
            errdefer server.deinit();
            const stopped = try a.create(std.Io.Event);
            stopped.* = .unset;

            var pool: ?*blocking.Pool = null;
            if (opts.blocking) |b| {
                const p = try a.create(blocking.Pool);
                try p.init(rt, b);
                pool = p;
            }
            errdefer if (pool) |p| p.deinit();

            const extras = try a.create(Extras);
            extras.* = .{ .client = http.Client.init(gpa, rt_io, opts.client), .client_entry = undefined, .client_registered = false };
            extras.client_entry = .{ .rt = rt, .client = &extras.client };
            extras.client_registered = client_mod.register(&extras.client_entry);
            errdefer {
                if (extras.client_registered) client_mod.unregister(&extras.client_entry);
                extras.client.deinit();
            }

            const console_restart = try a.create(std.Io.Event);
            console_restart.* = .unset;
            var self: Self = .{
                .console_resolved = console_resolved,
                .console_restart = console_restart,
                .console_config_text = console_config_text,
                .console_runtime = opts._console_runtime,
                .console_embedded = opts._resolved != null,
                .gpa = gpa,
                .rt = rt,
                .arena = arena,
                .server = server,
                .router = &server.router,
                .stopped = stopped,
                .process = opts.process,
                .restart_timeout = opts.restart_timeout,
                .signals = opts.signals,
                .banner = opts.banner,
                .h3 = if (features.http3) null else {},
                .blocking_pool = pool,
                .extras = extras,
                .mode = mode,
            };
            // RFC 8470 §5.1: unsafe requests taken in early data (marked
            // `Early-Data: 1`, by the HTTP/3 endpoint or a proxy in front)
            // get 425 Too Early, on every route, with HTTP/3 or without:
            // a TLS-terminating proxy can forward the mark to any listener.
            // Now, before any route.
            const h3_possible = features.http3 and (opts.http3 != null or mode.listen_tls_http3 or anyHttp3(opts.listeners));
            {
                const guard = try a.create(early_data.Guard);
                guard.* = .{};
                self.router.use(http.Middleware(Ctx).init(guard));
            }
            // Neither `http` nor `https`: `listen`, `listenTls` or `run`
            // sets up the listeners, `listeners` among them.
            if (opts.http == null and opts.https == null) {
                self.pending = opts;
                // `listenTls` turns HTTP/3 on once routes exist, when no
                // middleware can be added any more: its `Alt-Svc` goes in
                // now, silent until then.
                if (h3_possible) self.alt_svc = self.addAltSvc();
            } else {
                try self.listenOn(opts);
            }
            return self;
        }

        /// The log format, level and service name (process-wide), after the
        /// modes are resolved and before anything logs.
        fn applyLogOptions(opts: *const Options, mode: *const modes.Resolved) void {
            const format: anole_log.Format = switch (opts.log.format) {
                .auto => if (mode.log_json_from_mode) .json else .text,
                else => |f| f,
            };
            anole_log.setFormat(format);
            anole_log.setLevel(opts.log.level);
            anole_log.setService(opts.log.service);
            if (format == .json and !log_mod.usesAnoleLogFn() and !anole_log.hasSink())
                std.log.scoped(.anole).warn("log format is json, but this program's std.log lines stay text: add `pub const std_options = anole.std_options;` to the root file", .{});
        }

        /// The modes for `opts`: the environment, the `.env` files it reads,
        /// then the deployment and its defaults.
        fn resolveModes(a: std.mem.Allocator, opts: *const Options, why: *std.Io.Writer) !modes.Resolved {
            const e = try modes.resolveEnvironment(opts.environment, .process, .current, why);
            const list = opts.env_files orelse env_mod.defaultFiles(e.environment);
            var files: ?*const env_mod.Files = null;
            if (list.len > 0) {
                files = env_mod.loadOnce(std.Io.Threaded.global_single_threaded.io(), list, null) catch |err| {
                    why.writeAll("the .env files have problems (logged above)") catch {};
                    return err;
                };
            }
            return modes.resolve(a, opts, e.environment, e.source, files, .process, why);
        }

        /// `development` or `production`, as resolved at `init`.
        pub fn environment(self: *const Self) modes.Environment {
            return self.mode.environment;
        }

        /// What sits in front of the server, as resolved at `init`.
        pub fn deployment(self: *const Self) modes.Deployment {
            return self.mode.deployment;
        }

        fn addAltSvc(self: *Self) *AltSvc {
            const alt = self.arena.allocator().create(AltSvc) catch @panic("OOM");
            alt.* = .{};
            self.router.use(http.Middleware(Ctx).init(alt));
            return alt;
        }

        /// A listener to set up: `http`, `https` and `listeners` alike.
        const Spec = struct { name: []const u8, listener: Options.Listener };

        /// `opts`' listeners in serving order (`http`, `https`, then
        /// `listeners`), named. `checkSpecs` checks them.
        fn listenerSpecs(a: std.mem.Allocator, opts: Options, m: *const modes.Resolved) ![]const Spec {
            var specs: std.ArrayList(Spec) = .empty;
            // 127.0.0.1:8080 when nothing else is named.
            const http_opts: ?Options.Http = opts.http orelse if (opts.https == null and opts.listeners.len == 0) .{} else null;
            if (http_opts) |h| try specs.append(a, .{ .name = "http", .listener = .{
                .address = h.address orelse m.default_address,
                .port = h.port orelse m.default_port,
                .http2 = h.h2c and features.http2,
                .proxy_protocol = h.proxy_protocol orelse m.proxy_protocol_default,
                .proxy_protocol_from = h.proxy_protocol_from,
            } });
            if (opts.https) |h| try specs.append(a, .{ .name = "https", .listener = .{
                .address = h.address orelse m.default_address,
                .port = h.port,
                .tls = .{ .cert = h.cert, .alpn = h.alpn, .client_auth = h.client_auth },
                .http3 = opts.http3 != null,
                .proxy_protocol = h.proxy_protocol orelse m.proxy_protocol_default,
                .proxy_protocol_from = h.proxy_protocol_from,
            } });
            for (opts.listeners) |l0| {
                var l = l0;
                // A raw listener never takes the HTTP default port, and a
                // UDP one no PROXY header.
                const raw = l.tcp != null or l.udp != null;
                if (l.unix == null) {
                    l.address = l.address orelse m.default_address;
                    if (!raw) l.port = l.port orelse m.default_port;
                    if (l.udp == null) l.proxy_protocol = l.proxy_protocol orelse m.proxy_protocol_default;
                }
                const kind: []const u8 = if (l.udp != null) "udp" else if (l.tcp != null) "tcp" else if (l.tls != null) "https" else "http";
                var name = l.name orelse if (l.unix) |path|
                    try std.fmt.allocPrint(a, "unix-{s}", .{path})
                else if (l.port) |p|
                    try std.fmt.allocPrint(a, "{s}-{d}", .{ kind, p })
                else
                    try std.fmt.allocPrint(a, "{s}", .{kind});
                // A made-up name taken already (two on port 0): made unique.
                if (l.name == null) for (specs.items) |other| {
                    if (std.mem.eql(u8, other.name, name)) {
                        name = try std.fmt.allocPrint(a, "{s}-{d}", .{ name, specs.items.len });
                        break;
                    }
                };
                try specs.append(a, .{ .name = name, .listener = l });
            }
            return specs.items;
        }

        /// Fails when `specs` cannot be served as they are, saying why to
        /// `why`: names unique, each listener speaking something, HTTP/3 on
        /// one TLS listener at most, and on one when `opts.http3` is set.
        fn checkSpecs(specs: []const Spec, opts: Options, m: *const modes.Resolved, why: *std.Io.Writer) !void {
            var h3_count: usize = 0;
            for (specs, 0..) |spec, i| {
                const l = spec.listener;
                if (spec.name.len == 0 or spec.name.len > 255 or std.mem.indexOfScalar(u8, spec.name, ':') != null) {
                    try why.print("listener name \"{s}\": names are 1 to 255 bytes, with no ':' (LISTEN_FDNAMES separates them with it)", .{spec.name});
                    return error.InvalidListenerName;
                }
                for (specs[0..i]) |other| if (std.mem.eql(u8, other.name, spec.name)) {
                    try why.print("two listeners are named \"{s}\"", .{spec.name});
                    return error.DuplicateListenerName;
                };
                if (l.proxy_protocol == true and l.proxy_protocol_from.len == 0) if (m.trusted) |t| if (t.len == 0) {
                    try why.print("listener \"{s}\": proxy_protocol is on but proxy.trusted is empty, so no peer may send the header; name the load balancers in proxy_protocol_from or proxy.trusted", .{spec.name});
                    return error.ProxyProtocolNoPeers;
                };
                for (l.proxy_protocol_from) |text| {
                    _ = http.ProxyNetwork.parse(text) catch {
                        try why.print("listener \"{s}\": proxy_protocol_from \"{s}\" is not an address or a network in CIDR notation", .{ spec.name, text });
                        return error.InvalidProxyNetwork;
                    };
                }
                // ---- p3/net ----
                if (l.tcp != null or l.udp != null) {
                    try checkRaw(spec, why);
                    continue;
                }
                // ---- end p3/net ----
                if (!l.http1 and !l.http2) {
                    try why.print("listener \"{s}\" speaks neither HTTP/1.1 nor HTTP/2", .{spec.name});
                    return error.NoProtocols;
                }
                if (l.http2 and !features.http2) {
                    try why.print("listener \"{s}\" speaks HTTP/2, which this build leaves out (-Dhttp2)", .{spec.name});
                    return error.Http2NotBuilt;
                }
                if (l.http3) {
                    if (comptime !features.http3) {
                        try why.print("listener \"{s}\" speaks HTTP/3, which this build leaves out (-Dhttp3)", .{spec.name});
                        return error.Http3NotBuilt;
                    }
                    if (l.tls == null or l.unix != null) {
                        try why.print("listener \"{s}\": HTTP/3 needs TLS and a UDP port", .{spec.name});
                        return error.Http3NeedsTls;
                    }
                    h3_count += 1;
                }
            }
            if (h3_count > 1) {
                try why.print("HTTP/3 is on for {d} listeners; a server serves it on one", .{h3_count});
                return error.SeveralHttp3Listeners;
            }
            if (opts.http3 != null and h3_count == 0) {
                if (comptime !features.http3) {
                    try why.writeAll("http3 is set, but this build leaves HTTP/3 out (-Dhttp3)");
                    return error.Http3NotBuilt;
                }
                try why.writeAll("http3 is set, but no TLS listener serves it: set https, or http3 = true on a TLS listener");
                return error.Http3NeedsHttps;
            }
        }

        // ---- p3/net ----
        /// A raw listener's options (`tcp`/`udp`): one kind, a port, no
        /// HTTP/3, and for UDP no TLS, unix socket or PROXY header.
        fn checkRaw(spec: Spec, why: *std.Io.Writer) !void {
            const l = spec.listener;
            if (l.tcp != null and l.udp != null) {
                try why.print("listener \"{s}\" is both TCP and UDP; use two listeners", .{spec.name});
                return error.TcpAndUdp;
            }
            if (comptime !features.net) {
                try why.print("listener \"{s}\" is a raw TCP/UDP listener, which this build leaves out (-Dnet)", .{spec.name});
                return error.NetNotBuilt;
            }
            if (l.http3) {
                try why.print("listener \"{s}\": HTTP/3 cannot run on a raw TCP or UDP listener", .{spec.name});
                return error.NetListenerHttp3;
            }
            if (l.port == null and l.unix == null) {
                try why.print("listener \"{s}\" has no port; a raw listener never takes $PORT or the 8080 default", .{spec.name});
                return error.NetListenerNeedsPort;
            }
            if (l.udp) |svc| {
                if (l.tls != null) {
                    try why.print("listener \"{s}\": UDP with TLS (DTLS) is not supported", .{spec.name});
                    return error.UdpWithTls;
                }
                if (l.unix != null) {
                    try why.print("listener \"{s}\": UDP cannot listen on a unix socket", .{spec.name});
                    return error.UdpOnUnixSocket;
                }
                if (l.proxy_protocol == true) {
                    try why.print("listener \"{s}\": the PROXY protocol does not apply to UDP", .{spec.name});
                    return error.UdpWithProxyProtocol;
                }
                svc.options.check() catch {
                    try why.print("listener \"{s}\": batch must be 1 to 64, max_datagram 1 to 65507, sockets 1 to 255", .{spec.name});
                    return error.InvalidFraming;
                };
                if (!std.mem.eql(u8, svc.ctx_type, @typeName(Ctx))) {
                    try why.print("listener \"{s}\": the UDP service was built for {s}, this server's state is {s}", .{ spec.name, svc.ctx_type, @typeName(Ctx) });
                    return error.NetHandlerContext;
                }
            }
            if (l.tcp) |svc| {
                svc.options.check() catch {
                    try why.print("listener \"{s}\": a framing max is 1 byte to 1 GiB, length prefixes are 1, 2 or 4 bytes, read_window 4 KiB to 64 KiB", .{spec.name});
                    return error.InvalidFraming;
                };
                if (!std.mem.eql(u8, svc.ctx_type, @typeName(Ctx))) {
                    try why.print("listener \"{s}\": the TCP service was built for {s}, this server's state is {s}", .{ spec.name, svc.ctx_type, @typeName(Ctx) });
                    return error.NetHandlerContext;
                }
            }
        }
        // ---- end p3/net ----

        /// Whether a listener in `listeners` asks for HTTP/3.
        fn anyHttp3(listeners: []const Options.Listener) bool {
            for (listeners) |l| if (l.http3) return true;
            return false;
        }

        /// The ALPN protocols a TLS listener offers by default.
        fn defaultAlpn(l: Options.Listener) []const []const u8 {
            if (l.http2 and l.http1) return &.{ "h2", "http/1.1" };
            if (l.http2) return &.{"h2"};
            return &.{"http/1.1"};
        }

        /// Sets up the listeners `opts` names (`http`, `https`,
        /// `listeners`, `http3`; 127.0.0.1:8080 when it names none). Once,
        /// before serving.
        fn listenOn(self: *Self, opts_in: Options) !void {
            const gpa = self.gpa;
            const a = self.arena.allocator();
            const rt_io = self.rt.io();
            const server = self.server;
            // What the options left null, from the modes.
            var opts = opts_in;
            try modes.fillListeners(a, &opts, self.mode);
            const specs = try listenerSpecs(a, opts, self.mode);
            {
                var why_buf: [512]u8 = undefined;
                var why: std.Io.Writer = .fixed(&why_buf);
                checkSpecs(specs, opts, self.mode, &why) catch |err| {
                    errors.log.err("{s}", .{why.buffered()});
                    // The startup error's text says which listener.
                    self.net_why = a.dupe(u8, why.buffered()) catch null;
                    return err;
                };
            }
            // One accept loop per executor (dusty's default on zio); on
            // Linux each with its own SO_REUSEPORT socket, so the kernel
            // spreads connections over the executors.
            // Hand-off needs one socket per listener, which we open (or
            // inherit) ourselves.
            // Not on Windows (`handoff.supported`): there `process` only
            // carries the environment, and dusty binds as usual.
            const handoff_mode = opts.process != null and handoff.supported;
            if (handoff_mode) {
                var tcp_specs: usize = 0;
                for (specs) |sp| tcp_specs += @intFromBool(sp.listener.udp == null);
                if (tcp_specs > handoff.max_tcp_listeners) return error.TooManyListeners;
            }
            const per_core_sockets = builtin.os.tag == .linux and !handoff_mode;
            const inherited = if (opts.process) |p| handoff.inherited(p.environ) else null;
            var held: std.ArrayList(handoff.Listener) = .empty;
            // Fixed now: the certificates and Alt-Svc point into it.
            // UDP listeners are not the core's: it accepts TCP only.
            var core_count: usize = 0;
            for (specs) |sp| {
                if (sp.listener.udp == null) core_count += 1;
            }
            const listeners = try a.alloc(http.Listener, core_count);
            var core_next: usize = 0;
            var h3_core: usize = 0;
            const ctx_state: ?*anyopaque = if (Ctx == void) null else @ptrCast(server.ctx);
            // The certificates are read here, files included, and handed
            // to dusty (and HTTP/3) as PEM: a reload reads them again the
            // same way.
            var certs: std.ArrayList(*CertState) = .empty;
            errdefer for (certs.items) |cs| cs.deinit();
            var h3_at: ?usize = null;
            // Whether "" (every interface) can be one dual-stack socket:
            // asked once, when a listener names it.
            var dual: DualStack = .{};
            for (specs, 0..) |spec, i| {
                const l = spec.listener;
                if (l.udp != null) {
                    try self.openUdp(spec, ctx_state, &dual, &inherited, handoff_mode, &held);
                    continue;
                }
                const out = &listeners[core_next];
                core_next += 1;
                var ipv6_only: ?bool = null;
                const address: http.Address = if (l.unix) |path|
                    .{ .unix = try std.Io.net.UnixAddress.init(path) }
                else blk: {
                    const bind = try address_mod.resolve(l.address.?, l.port.?, l.address.?.len == 0 and dual.get());
                    ipv6_only = bind.ipv6_only;
                    break :blk .{ .ip = bind.ip };
                };
                var config: ?http.ServerConfig.Tls = null;
                if (l.tls) |t| {
                    if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
                    if (warnsDevCert(t.cert, address)) std.log.scoped(.anole).warn(
                        "listener \"{s}\" serves a development certificate (dev_self_signed) on {f}: browsers will warn and clients cannot verify it. Use Cert.fromFiles(...) outside development.",
                        .{ spec.name, address.ip },
                    );
                    const cs = for (certs.items) |cs| {
                        if (CertState.sameSource(cs.source, t.cert)) break cs;
                    } else blk: {
                        const cs = try a.create(CertState);
                        cs.* = .{ .gpa = gpa, .pem = try CertState.load(gpa, rt_io, t.cert), .source = t.cert };
                        try certs.append(a, cs);
                        try cs.setSource(t.cert);
                        break :blk cs;
                    };
                    try cs.listeners.append(a, out);
                    config = .{
                        // A raw listener offers ALPN only when told to.
                        .alpn_protocols = t.alpn orelse if (l.tcp != null) &.{} else defaultAlpn(l),
                        .client_auth = t.client_auth,
                        .pem = .{ .cert = cs.pem.cert, .key = cs.pem.key },
                    };
                }
                if (l.http3) {
                    h3_at = i;
                    h3_core = core_next - 1;
                }
                if (address == .unix and !handoff_mode) try clearStaleUnixSocket(rt_io, address.unix);
                const fd = try listenerFd(rt_io, inherited, handoff_mode, spec.name, core_next - 1, address, ipv6_only, l.unix_mode);
                if (fd) |f| try held.append(a, .{ .fd = f, .name = spec.name });
                // ---- p3/net ----
                var raw: ?*net_mod.TcpListener = null;
                var raw_protocols: []const []const u8 = &.{};
                if (l.tcp) |svc0| {
                    var svc = svc0;
                    if (svc.state == null) svc.state = ctx_state;
                    const tl = try net_mod.TcpListener.create(gpa, rt_io, svc);
                    errdefer tl.destroy();
                    try self.net_tcp.append(a, tl);
                    raw = tl;
                    raw_protocols = switch (svc.options.framing) {
                        .none => &.{},
                        .lines => &.{"lines"},
                        .length => &.{"length-prefixed"},
                        .varint => &.{"varint-prefixed"},
                    };
                }
                // ---- end p3/net ----
                out.* = .{
                    .address = address,
                    .name = spec.name,
                    .http1 = l.http1,
                    .http2_prior_knowledge = l.tls == null and l.http2 and features.http2,
                    .socket_per_acceptor = per_core_sockets and address == .ip,
                    .ipv6_only = ipv6_only,
                    .unix_mode = if (address == .unix) l.unix_mode else null,
                    // Null only on a unix socket: the modes' default is for TCP listeners.
                    .proxy_protocol = l.proxy_protocol orelse false,
                    .proxy_protocol_from = from: {
                        const nets = try a.alloc(http.ProxyNetwork, l.proxy_protocol_from.len);
                        for (l.proxy_protocol_from, nets) |text, *net| net.* = http.ProxyNetwork.parse(text) catch return error.InvalidProxyNetwork;
                        break :from nets;
                    },
                    .tls = config,
                    .fd = fd,
                    // ---- p3/net ----
                    .raw = if (raw) |tl| &tl.raw else null,
                    .max_connections = if (l.tcp) |svc| svc.options.max_connections else null,
                    .handshake_timeout = if (l.tcp) |svc| svc.options.handshake_timeout else null,
                    .extra_protocols = raw_protocols,
                    // ---- end p3/net ----
                };
                if (l.tcp != null) {
                    out.http1 = false;
                    out.http2_prior_knowledge = false;
                }
            }

            server.config.listeners = listeners;
            errdefer server.config.listeners = &.{};

            var endpoint: H3Endpoint = if (features.http3) null else {};
            if (comptime features.http3) if (h3_at) |at| {
                const q = opts.http3 orelse Options.Http3{};
                const l = specs[at].listener;
                const tcp_listener = &listeners[h3_core];
                const cs = for (certs.items) |cs| {
                    if (std.mem.indexOfScalar(*http.Listener, cs.listeners.items, tcp_listener) != null) break cs;
                } else unreachable;
                cs.h3_listener = tcp_listener;
                const client_auth = l.tls.?.client_auth;
                // Mutual TLS: the same CAs and mode as the TCP listener,
                // loaded once more here (dusty loads its own when it
                // starts listening).
                var client_ca: ?std.crypto.Certificate.Bundle = null;
                defer if (client_ca) |*b| b.deinit(gpa);
                if (client_auth) |ca| client_ca = try ca.ca.load(gpa, rt_io);
                // The UDP sockets: inherited (`h3`, in the order the
                // predecessor bound them, or by position after the TCP
                // listeners), with the predecessor's secret.
                var h3_buf: [handoff.max_listeners]handoff.Fd = undefined;
                const h3_fds: []const handoff.Fd = if (inherited) |inh| inh.findAll("h3", listeners.len, &h3_buf) else &.{};
                for (h3_fds) |fd| handoff.checkInherited(fd, .datagram, true) catch |err| {
                    errors.log.err("inherited fd {any} for HTTP/3 is not a UDP socket", .{fd});
                    return err;
                };
                const secret: ?[32]u8 = if (h3_fds.len > 0) handoff.inheritedSecret(opts.process.?.environ) else null;
                // The UDP socket follows the TCP listener's address, "" (dual-stack) included.
                const udp_host = q.address orelse l.address.?;
                const udp_bind = try address_mod.resolve(udp_host, q.port orelse l.port.?, udp_host.len == 0 and dual.get());
                const ep = h3.Endpoint(Ctx).init(gpa, rt_io, server, .{
                    .address = udp_bind.ip,
                    .ipv6_only = udp_bind.ipv6_only,
                    .cert_pem = cs.pem.cert,
                    .key_pem = cs.pem.key,
                    .max_streams_bidi = q.max_streams_bidi,
                    .validate_address = q.validate_address,
                    .idle_timeout = q.idle_timeout,
                    .hq_interop_root = q.hq_interop_root,
                    .prefer_v2 = q.prefer_v2,
                    .early_data = q.early_data,
                    .enable_connect_protocol = q.enable_connect_protocol,
                    .webtransport = q.webtransport or self.extras.webtransport,
                    .inline_no_wait = q.inline_no_wait,
                    .client_auth = h3ClientAuth(client_auth, client_ca),
                    .listener_name = specs[at].name,
                    .fds = h3_fds,
                    .sockets = q.sockets orelse @intCast(@min(self.rt.executors.items.len, 255)),
                    .secret = secret,
                    // The same drain deadline as HTTP/1.1 and HTTP/2.
                    .drain_timeout_ms = if (server.config.timeout.shutdown) |d|
                        @intCast(@min(@max(d.toMilliseconds(), 0), std.math.maxInt(u32)))
                    else
                        std.math.maxInt(u32),
                }) catch |err| {
                    failed_listener_index = h3_core;
                    return err;
                };
                errdefer ep.deinit();
                endpoint = ep;
                // Named in the TLS listener's startup line.
                const udp_port = ep.address().getPort();
                tcp_listener.extra_protocols = if (udp_port == tcp_listener.address.ip.getPort())
                    &.{"HTTP/3"}
                else
                    try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "HTTP/3 on UDP port {d}", .{udp_port})});
                // Every socket, in the group's order.
                if (handoff_mode) for (ep.endpoints()) |e| try held.append(a, .{ .fd = e.udp.socket.handle, .name = "h3" });
                if (q.alt_svc) {
                    const alt = self.alt_svc orelse self.addAltSvc();
                    self.alt_svc = alt;
                    alt.listener = tcp_listener;
                    alt.value = try std.fmt.allocPrint(a, "h3=\":{d}\"; ma=86400", .{udp_port});
                }
            };
            self.held = held.items;
            self.h3 = endpoint;
            self.certs = certs.items;
        }

        // ---- p3/net ----
        /// Binds (or adopts) a UDP listener's sockets, in the order they are
        /// handed over in.
        fn openUdp(
            self: *Self,
            spec: Spec,
            ctx_state: ?*anyopaque,
            dual: *DualStack,
            inherited: *const ?handoff.Inherited,
            handoff_mode: bool,
            held: *std.ArrayList(handoff.Listener),
        ) !void {
            const a = self.arena.allocator();
            const l = spec.listener;
            var svc = l.udp.?;
            if (svc.state == null) svc.state = ctx_state;
            const bind = try address_mod.resolve(l.address.?, l.port.?, l.address.?.len == 0 and dual.get());
            // Sockets passed in by name only: a UDP socket is never found by
            // its position among the TCP ones.
            var fd_buf: [handoff.max_udp_sockets]handoff.Fd = undefined;
            const fds: []const handoff.Fd = if (inherited.*) |*inh| inh.findAll(spec.name, std.math.maxInt(usize), &fd_buf) else &.{};
            for (fds) |fd| handoff.checkInherited(fd, .datagram, true) catch |err| {
                errors.log.err("inherited fd {any} for listener \"{s}\" is not a UDP socket", .{ fd, spec.name });
                return err;
            };
            const g = try net_mod.UdpGroup.create(self.gpa, self.rt.io(), svc, spec.name, .{
                .address = bind.ip,
                .ipv6_only = bind.ipv6_only,
                .fds = fds,
                .executors = self.rt.executors.items.len,
            });
            errdefer g.destroy();
            try self.net_udp.append(a, g);
            if (handoff_mode) for (0..g.sockets.len) |j| try held.append(a, .{ .fd = g.socketFd(j), .name = spec.name });
            std.log.scoped(.anole).info("listening on udp://{f} ({d} socket{s})", .{ g.address(), g.sockets.len, if (g.sockets.len == 1) "" else "s" });
        }
        // ---- end p3/net ----

        /// `address_mod.dualStackAvailable`, asked at most once.
        const DualStack = struct {
            known: ?bool = null,

            fn get(d: *DualStack) bool {
                if (d.known == null) d.known = address_mod.dualStackAvailable();
                return d.known.?;
            }
        };

        /// The HTTP/3 endpoint's mutual TLS settings: the TCP listener's
        /// mode, with its CAs (`bundle`, loaded by the caller).
        fn h3ClientAuth(client_auth: ?http.ClientAuth, bundle: ?std.crypto.Certificate.Bundle) if (features.http3) ?h3.ClientAuth else void {
            if (comptime !features.http3) return;
            const ca = client_auth orelse return null;
            return .{
                .ca_der = bundle.?.bytes.items,
                .mode = switch (ca.mode) {
                    .request => .request,
                    .require => .require,
                },
            };
        }

        /// The socket for one listener in hand-off mode: inherited if one
        /// was passed in under `name` (or at `index`), else opened here.
        /// Null outside hand-off mode (the core binds).
        fn listenerFd(io_: std.Io, inherited: ?handoff.Inherited, handoff_mode: bool, name: []const u8, index: usize, address: http.Address, ipv6_only: ?bool, mode: u16) !?handoff.Fd {
            if (!handoff_mode) return null;
            if (inherited) |inh| if (inh.find(name, index)) |fd| {
                handoff.checkInherited(fd, .listener, address == .ip) catch |err| {
                    errors.log.err("inherited fd {any} for listener \"{s}\" is not a listening {s} socket", .{ fd, name, if (address == .ip) "TCP" else "unix" });
                    return err;
                };
                return fd;
            };
            switch (address) {
                .ip => |ip| {
                    // SO_REUSEPORT would share the port with whoever has it.
                    try http.checkAddressFree(ip, ipv6_only);
                    const s = try http.listenIp(io_, ip, .{ .reuse_address = true, .ipv6_only = ipv6_only });
                    return s.socket.handle;
                },
                .unix => |unix| {
                    try clearStaleUnixSocket(io_, unix);
                    const s = try unix.listen(io_, .{});
                    http.setUnixMode(io_, unix, mode);
                    return s.socket.handle;
                },
            }
        }

        /// Removes the socket file at `address` when nothing listens on it
        /// any more (a server that stopped without removing it, as Anole
        /// never does: a successor may be serving it), so it can be bound
        /// again. One that something answers on is in use.
        fn clearStaleUnixSocket(io_: std.Io, address: std.Io.net.UnixAddress) !void {
            if (address.isAbstract()) return;
            const cwd = std.Io.Dir.cwd();
            const stat = cwd.statFile(io_, address.path, .{}) catch return;
            if (stat.kind != .unix_domain_socket) return;
            if (address.connect(io_)) |stream| {
                stream.close(io_);
                errors.log.err("unix:{s} is already in use: another process is listening on it", .{address.path});
                return error.AddressInUse;
            } else |err| switch (err) {
                error.ConnectionRefused => cwd.deleteFile(io_, address.path) catch {},
                else => {},
            }
        }

        /// Frees the server and everything it owns: the runtime, the
        /// listeners, the middleware and helpers it made, and the database
        /// connectors (closed last made, first). Call it after `run` (or
        /// `listen`) has returned.
        pub fn deinit(self: *Self) void {
            const extras = self.extras;
            // First: it sends what is queued through the client, on the
            // runtime.
            if (extras.exporter) |e| e.deinit();
            if (comptime features.http3) if (self.h3) |ep| ep.deinit();
            self.server.deinit();
            // ---- p3/net ----
            for (self.net_udp.items) |g| g.destroy();
            for (self.net_tcp.items) |t| t.destroy();
            // ---- end p3/net ----
            // The databases, once nothing uses them: last made, first closed.
            var c = extras.connectors.items.len;
            while (c > 0) {
                c -= 1;
                extras.connectors.items[c].deinit(extras.connectors.items[c].context);
            }
            // Last added, first freed.
            var i = self.owned_middleware.items.len;
            while (i > 0) {
                i -= 1;
                self.owned_middleware.items[i].deinit();
            }
            if (extras.resilience) |b| {
                b.deinit();
                self.gpa.destroy(b);
            }
            if (extras.metrics) |r| r.deinit();
            if (comptime features.grpc) if (extras.grpc_health) |h| h.deinit();
            if (extras.client_registered) client_mod.unregister(&extras.client_entry);
            extras.client.deinit();
            for (extras.dirs.items) |d| d.close(self.rt.io());
            for (self.certs) |cs| cs.deinit();
            if (self.blocking_pool) |p| p.deinit();
            self.rt.deinit();
            server_on_thread = false;
            self.arena.deinit();
            self.gpa.destroy(self.arena);
            self.* = undefined;
        }

        /// The runtime's `std.Io`, for work beside the server.
        pub fn io(self: *const Self) std.Io {
            return self.rt.io();
        }

        /// Serves on `address`, in Go's notation, until SIGINT, SIGTERM or
        /// `stop`, as `run` does: ":3000" is every interface, IPv6 and
        /// IPv4 alike (as in a container; IPv4 alone where the system has
        /// no IPv6), "0.0.0.0:3000" every IPv4 interface only,
        /// "127.0.0.1:3000" or "localhost:3000" this machine only,
        /// "[::]:3000" every IPv6 interface. HTTP/1.1, and HTTP/2 for
        /// clients that open with its preface (h2c). For a server whose
        /// `init` options named neither `http` nor `https`; it serves the
        /// options' `listeners` too.
        pub fn listen(self: *Self, address: []const u8) errors.ServerError!void {
            return self.listenInner(address) catch |err| self.failWith(err);
        }

        fn listenInner(self: *Self, address: []const u8) !void {
            var opts = try self.takePending("listen");
            const at = address_mod.parse(address) catch |err| {
                errors.log.err("listen(\"{s}\"): not an address to listen on; use a port (\"3000\", every interface), \":3000\", or \"127.0.0.1:3000\" (this machine only)", .{address});
                return err;
            };
            opts.http = .{ .address = at.host, .port = at.port };
            self.warnPlatformPort("listen", address, at.port);
            try self.configure(opts);
            return self.runInner();
        }

        /// `listen`, over TLS with `cert`: HTTP/2 and HTTP/1.1 by ALPN, and
        /// HTTP/3 on the same port number over UDP (advertised with
        /// `Alt-Svc`) when it is built in, unless `Options.listen_tls_http3`
        /// is off.
        ///
        ///     try app.listenTls(":443", .fromFiles("cert.pem", "key.pem"));
        ///     try app.listenTls("localhost:8443", .dev_self_signed);
        pub fn listenTls(self: *Self, address: []const u8, cert: Cert) errors.ServerError!void {
            return self.listenTlsInner(address, cert) catch |err| self.failWith(err);
        }

        fn listenTlsInner(self: *Self, address: []const u8, cert: Cert) !void {
            var opts = try self.takePending("listenTls");
            const at = address_mod.parse(address) catch |err| {
                errors.log.err("listenTls(\"{s}\"): not an address to listen on; use a port (\"443\", every interface), \":443\", or \"127.0.0.1:8443\" (this machine only)", .{address});
                return err;
            };
            opts.https = .{ .address = at.host, .port = at.port, .cert = cert };
            // Unless a listener in `listeners` serves HTTP/3 already.
            self.warnPlatformPort("listenTls", address, at.port);
            self.used_listen_tls = true;
            if (features.http3 and self.mode.listen_tls_http3 and opts.http3 == null and !anyHttp3(opts.listeners)) opts.http3 = .{};
            try self.configure(opts);
            return self.runInner();
        }

        /// Under the platform deployment the platform sends traffic to
        /// $PORT: a port named in code wins, and this says so when it differs.
        fn warnPlatformPort(self: *const Self, comptime what: []const u8, address: []const u8, port: u16) void {
            const m = self.mode;
            if (m.deployment != .platform or m.port_source == .default or port == m.default_port) return;
            std.log.scoped(.anole).warn(
                "deployment platform: PORT={d}, but " ++ what ++ "(\"{s}\") names port {d}; the platform sends traffic to PORT. Leave the port to it: app.run(), or .http = .{{}}",
                .{ m.default_port, address, port },
            );
        }

        fn takePending(self: *Self, comptime what: []const u8) !Options {
            return self.pending orelse {
                // Not the end of the server: `run` still serves those.
                errors.log.err(what ++ "(): this server's listeners come from its init options (http, https); serve them with run(), or leave both out of init", .{});
                return error.ListenersAlreadySet;
            };
        }

        /// The listeners `init` left for later; a failure also ends
        /// `waitReady`.
        fn configure(self: *Self, opts: Options) !void {
            self.pending = null;
            self.listenOn(opts) catch |err| return self.failStart(errors.toServerError(err));
        }

        /// `err`, also for whoever waits in `waitReady`: the server will
        /// not start.
        fn failStart(self: *Self, err: errors.ServerError) errors.ServerError {
            if (!self.server.settled.isSet()) {
                self.server.start_error = err;
                self.server.settled.set(self.rt.io());
                // Once, readable: what could not be done, why, and the way out.
                errors.logExplained(err, self.startContext(err));
            }
            return err;
        }

        /// The readable text of the startup failure `err` (`errors.explain`
        /// with this server's context: the listener that failed, the
        /// connector), into `buf`; empty for an error that is not one of
        /// `ServerError`'s. The C ABI's `anole_last_error` shows the same.
        pub fn explainStart(self: *Self, buf: []u8, err: anyerror) []const u8 {
            const known = errors.serverErrorNamed(@errorName(err)) orelse return "";
            return errors.explainBuf(buf, known, self.startContext(known));
        }

        /// What `errors.explain` needs to know about a startup failure.
        fn startContext(self: *Self, err: errors.ServerError) errors.Context {
            var ctx: errors.Context = .{};
            if (err == error.AddressInUse or err == error.AddressNotAvailable or err == error.AccessDenied) {
                if (self.server.start_error_listener) |i| {
                    const listeners = self.server.config.listeners;
                    if (i < listeners.len) {
                        const l = listeners[i];
                        ctx.listener = l.name;
                        const a = self.arena.allocator();
                        switch (l.address) {
                            .ip => |ip| {
                                ctx.address = std.fmt.allocPrint(a, "{f}", .{ip}) catch null;
                                ctx.port = ip.getPort();
                            },
                            .unix => |u| ctx.address = u.path,
                        }
                    }
                }
            }
            if (err == error.DatabaseUnavailable) {
                ctx.system = self.extras.failed_system;
                ctx.cause = self.extras.failed_cause;
            }
            if (err == error.RouteConflict) ctx.detail = self.router.conflict;
            // ---- p3/net ----
            switch (err) {
                error.NetNotBuilt, error.NetListenerNeedsPort, error.NetListenerHttp3, error.TcpAndUdp, error.UdpWithTls, error.UdpOnUnixSocket, error.UdpWithProxyProtocol, error.InvalidFraming, error.NetHandlerContext => ctx.detail = self.net_why,
                else => {},
            }
            // ---- end p3/net ----
            return ctx;
        }

        /// `failStart` for whatever the layers below returned. A second
        /// `listen` on a server already set up fails alone: the server
        /// itself is fine.
        fn failWith(self: *Self, err: anyerror) errors.ServerError {
            const mapped = errors.toServerError(err);
            if (mapped == error.ListenersAlreadySet) return mapped;
            return self.failStart(mapped);
        }

        /// The listener whose socket could not be bound when `run` failed
        /// with `AddressInUse`, `AddressNotAvailable` or `AccessDenied`;
        /// null otherwise.
        pub fn failedListener(self: *const Self) ?[]const u8 {
            const err = self.server.start_error orelse return null;
            const name = @errorName(err);
            if (!std.mem.eql(u8, name, "AddressInUse") and !std.mem.eql(u8, name, "AddressNotAvailable") and
                !std.mem.eql(u8, name, "AccessDenied")) return null;
            const index = self.server.start_error_listener orelse return null;
            const listeners = self.server.config.listeners;
            if (index >= listeners.len) return null;
            return listeners[index].name;
        }

        /// `rateLimit`'s settings.
        pub const RateLimitOptions = struct {
            /// Requests allowed per `window`.
            limit: u32 = 100,
            window: Duration = .fromSeconds(60),
            /// How many may come at once; 0 means `limit`.
            burst: u32 = 0,
            /// What requests are counted by.
            key: ratelimit.Key = .ip,
            /// Keys remembered at most.
            max_entries: u32 = 10_000,
        };

        /// Rate limiting for every route after it, with an in-memory limiter
        /// the server owns: `app.rateLimit(.{ .limit = 100 })` is 100
        /// requests a minute per client address, over the limit 429 with
        /// `Retry-After`. Call it with `use`, before the routes.
        pub fn rateLimit(self: *Self, opts: RateLimitOptions) void {
            const a = self.arena.allocator();
            const limiter = self.gpa.create(ratelimit.MemoryLimiter) catch @panic("OOM");
            limiter.* = .init(self.gpa, self.rt.io(), .{ .max_entries = opts.max_entries });
            const key: ratelimit.Key = switch (opts.key) {
                .ip => .ip,
                .header => |h| .{ .header = a.dupe(u8, h) catch @panic("OOM") },
            };
            self.use(ratelimit.OwnedMiddleware{
                .limiter = limiter,
                .key = key,
                .policy = .{ .limit = opts.limit, .window = opts.window, .burst = opts.burst },
            });
        }

        /// A copy of `value`, a middleware (a struct with `execute`, or a
        /// function: see `anole.func`), that the server owns: freed with
        /// it, after its `deinit` if it has one. The handle can go into
        /// several groups. A handle given in place of a value is returned
        /// as it is, and so is a pointer to a middleware kept elsewhere
        /// (`responseCache`'s).
        pub fn middleware(self: *Self, value: anytype) http.Middleware(Ctx) {
            const T = @TypeOf(value);
            if (T == http.Middleware(Ctx)) return value;
            // A middleware kept elsewhere (`responseCache`'s).
            if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one and
                @typeInfo(@typeInfo(T).pointer.child) == .@"struct" and @hasDecl(@typeInfo(T).pointer.child, "execute"))
                return http.Middleware(Ctx).init(value);
            if (comptime handlers.isFn(T)) return self.middleware(handlers.func(value));
            if (comptime handlers.isNoWait(T)) {
                if (comptime !handlers.isMiddlewareFn(T.no_wait_handler))
                    @compileError("anole.noWait wraps a handler for a route, or a middleware function (taking anole.Next last) for use/group/with");
                return self.middleware(handlers.FuncNoWait(T.no_wait_handler){});
            }
            const copy = self.arena.allocator().create(T) catch @panic("OOM");
            copy.* = value;
            var handle = http.Middleware(Ctx).init(copy);
            // What the middleware tells the OpenAPI document.
            if (comptime features.openapi) {
                if (comptime openapi_mod.mw.infoOfType(T)) |info| handle.openapi = @ptrCast(info);
            }
            self.owned_middleware.append(self.arena.allocator(), handle) catch @panic("OOM");
            return handle;
        }

        /// Adds a global middleware, run before every route, in the order
        /// added. Before the routes, as `Router.use` requires. A value is
        /// copied and owned by the server (see `middleware`); a function
        /// `fn (req, res, next: anole.Next) !void` is taken too.
        pub fn use(self: *Self, value: anytype) void {
            self.router.use(self.middleware(value));
        }

        /// `handler` as the router takes it: a plain `(req, res)` handler
        /// is taken on a server with state too.
        fn route(comptime handler: anytype) Handler {
            return handlers.adapt(Ctx, handler);
        }

        /// Adds `handler` at `path` on `target` (the router, or a group),
        /// behind a `ResponseCache` of its own when it is `anole.cached`.
        fn register(self: *Self, target: anytype, method: ?http.Method, path: []const u8, comptime handler: anytype) void {
            const H = @TypeOf(handler);
            if (comptime features.openapi) if (method) |m| self.recordRoute(target, m, path, handler);
            if (comptime handlers.isCached(H)) {
                var settings: ResponseCache.Options = H.cache_options;
                // Named by its route in metrics.
                if (settings.name == null) settings.name = std.fmt.allocPrint(self.arena.allocator(), "{s}{s}", .{
                    if (@TypeOf(target) == *http.Router(Ctx)) "" else target.prefix, path,
                }) catch @panic("OOM");
                const cache = self.responseCache(settings);
                const g = target.group("", &.{http.Middleware(Ctx).init(cache)});
                return g.addRouteWith(method, path, route(handler), handlers.routeOptions(handler));
            }
            target.addRouteWith(method, path, route(handler), handlers.routeOptions(handler));
        }

        /// Keeps the route for the OpenAPI document: its comptime-built
        /// operation, its path and the documented middleware of its chain.
        fn recordRoute(self: *Self, target: anytype, method: http.Method, path: []const u8, comptime handler: anytype) void {
            if (comptime handlers.routeDoc(handler).hidden) return;
            const verb = std.meta.stringToEnum(openapi_mod.operation.Verb, @tagName(method)) orelse return;
            const a = self.arena.allocator();
            const prefix = if (comptime @TypeOf(target) == *http.Router(Ctx)) "" else target.prefix;
            const joined = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, path }) catch @panic("OOM");
            const op = comptime &openapi_mod.operation.forHandler(handler);
            self.extras.doc_entries.append(a, .{
                .verb = verb,
                .path = openapi_mod.operation.openApiPathAlloc(a, joined) catch @panic("OOM"),
                .op = op,
                .middleware = self.chainDocs(target),
            }) catch @panic("OOM");
        }

        /// The OpenAPI declarations of the middleware a route on `target`
        /// runs behind, the server's first.
        fn chainDocs(self: *Self, target: anytype) []const *const openapi_mod.mw.Info {
            const a = self.arena.allocator();
            var out: std.ArrayList(*const openapi_mod.mw.Info) = .empty;
            const groups: []const http.Middleware(Ctx) = if (comptime @TypeOf(target) == *http.Router(Ctx)) &.{} else target.middlewares;
            for ([_][]const http.Middleware(Ctx){ self.router.middlewares, groups }) |list| {
                for (list) |m| if (m.openapi) |p| out.append(a, @ptrCast(@alignCast(p))) catch @panic("OOM");
            }
            return out.items;
        }

        /// A route whose path is known only at run time (from configuration):
        /// `null` method is every method, as `any`. Checked when registered
        /// (a malformed pattern or a conflict panics, or is recorded in test
        /// builds), as the compile-time checks of `get` and the others would.
        ///
        ///     app.addRoute(.get, cfg.health_path, health);
        pub fn addRoute(self: *Self, method: ?http.Method, path: []const u8, comptime handler: anytype) void {
            self.register(self.router, method, path, handler);
        }

        /// A `ResponseCache` owned by the server, for `with`, `group` or
        /// `use`; it reports to `app.metrics` once serving starts and is
        /// freed with the server. `anole.cached` makes one per route.
        ///
        ///     const pages = app.responseCache(.{ .ttl = .fromSeconds(30), .name = "pages" });
        ///     app.with(.{pages}).get("/about", about);
        ///     pages.invalidate(.{ .path = "/about" });
        pub fn responseCache(self: *Self, settings: ResponseCache.Options) *ResponseCache {
            const cache = ResponseCache.init(self.gpa, self.rt.io(), settings) catch @panic("OOM");
            self.extras.connectors.append(self.arena.allocator(), .of(ResponseCache, cache)) catch @panic("OOM");
            if (self.extras.connectors_started) cache.start(self.extras.metrics, self.extras.exporter, self.extras.health) catch {};
            return cache;
        }

        /// Routes GET requests for `path` to `handler`; HEAD too, unless
        /// `head` registers its own. `path` may have `:name` segments
        /// (`req.params`) and end in `*name` (the rest of the path).
        /// `handler` is `fn (req, res) !void` (`*Ctx` first on a server with
        /// state), or wrapped in `anole.noWait` or `anole.cached`. Panics
        /// when the route is already registered or conflicts with another.
        ///
        ///     app.get("/users/:id", getUser);
        pub fn get(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.get, path, handler, true);
            self.register(self.router, .get, path, handler);
        }
        /// As `get`, for HEAD.
        pub fn head(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.head, path, handler, true);
            self.register(self.router, .head, path, handler);
        }
        /// As `get`, for POST.
        pub fn post(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.post, path, handler, true);
            self.register(self.router, .post, path, handler);
        }
        /// As `get`, for PUT.
        pub fn put(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.put, path, handler, true);
            self.register(self.router, .put, path, handler);
        }
        /// As `get`, for PATCH.
        pub fn patch(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.patch, path, handler, true);
            self.register(self.router, .patch, path, handler);
        }
        /// As `get`, for DELETE.
        pub fn delete(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.delete, path, handler, true);
            self.register(self.router, .delete, path, handler);
        }
        /// As `get`, for OPTIONS. (`middleware.Cors` answers preflights
        /// without one.)
        pub fn options(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.options, path, handler, true);
            self.register(self.router, .options, path, handler);
        }
        /// The HTTP QUERY method (a GET with a body).
        pub fn query(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(.query, path, handler, true);
            self.register(self.router, .query, path, handler);
        }
        /// As `get`, for every method; a route for a specific method at a
        /// path wins over it.
        pub fn any(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            comptime typed.checkRoute(null, path, handler, true);
            self.register(self.router, null, path, handler);
        }

        /// A WebSocket endpoint at `path`, over HTTP/1.1, HTTP/2 (RFC
        /// 8441) and HTTP/3 (RFC 9220): `handler` gets the open socket, which is closed
        /// when it returns, and with 1001 when the server drains. A plain
        /// HTTP request there gets 426 Upgrade Required. `handler` is
        /// `fn (ws: *anole.websocket.Socket, req: *anole.Request) !void`
        /// (the request may be left out; the server's state may come
        /// first):
        ///
        ///     fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
        ///         while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
        ///     }
        ///     app.ws("/echo", echo);
        pub fn ws(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            self.wsWith(path, handler, .{});
        }

        /// `ws` with upgrade options (message size limit, compression,
        /// timeout, the drain close).
        pub fn wsWith(self: *Self, comptime path: []const u8, comptime handler: anytype, comptime upgrade: websocket.UpgradeOptions) void {
            if (comptime !features.websocket) @compileError("app.ws needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
            comptime checkPattern("GET", path);
            self.router.get(path, websocket.route(Ctx, handler, upgrade));
        }

        /// A WebSocket endpoint at `path` served through callbacks:
        /// `Handlers`'s `message` for each message, and `open` and `close`
        /// if it declares them (see `anole.websocket.callbacks`). Over
        /// HTTP/1.1 an idle socket holds no task, only a small heap object,
        /// which suits many mostly idle sockets better than `ws`:
        ///
        ///     const Echo = struct {
        ///         pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
        ///             try ws.send(msg.type, msg.data);
        ///         }
        ///     };
        ///     app.wsCallbacks("/echo", Echo);
        pub fn wsCallbacks(self: *Self, comptime path: []const u8, comptime Handlers: type) void {
            self.wsCallbacksWith(path, Handlers, .{});
        }

        /// `wsCallbacks` with upgrade options.
        pub fn wsCallbacksWith(self: *Self, comptime path: []const u8, comptime Handlers: type, comptime upgrade: websocket.UpgradeOptions) void {
            if (comptime !features.websocket) @compileError("app.wsCallbacks needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
            comptime checkPattern("GET", path);
            self.router.get(path, websocket.callbacks(Ctx, Handlers, upgrade));
        }

        /// A WebTransport endpoint at `path` (draft-02, what Chrome and
        /// Firefox speak), on the HTTP/3 listener, which this turns
        /// WebTransport on for: `handler` gets the open session, which is
        /// closed when it returns, and on the server's drain. A request
        /// there that is no WebTransport session gets 400. `handler` is
        /// `fn (session: *anole.webtransport.Session, req: *anole.Request)
        /// !void` (the request may be left out; the server's state may
        /// come first):
        ///
        ///     fn echo(session: *anole.webtransport.Session) !void {
        ///         while (true) {
        ///             const stream = session.acceptStream() catch return;
        ///             defer stream.release();
        ///             ...
        ///         }
        ///     }
        ///     app.webtransport("/echo", echo);
        pub fn webtransport(self: *Self, comptime path: []const u8, comptime handler: anytype) void {
            self.webtransportWith(path, handler, .{});
        }

        /// `webtransport` with accept options (the drain's close, timeout).
        pub fn webtransportWith(self: *Self, comptime path: []const u8, comptime handler: anytype, comptime accept: webtransport_mod.AcceptOptions) void {
            if (comptime !features.http3) @compileError("app.webtransport needs HTTP/3 (-Dhttp3, on in the full profile)");
            comptime checkPattern("GET", path);
            self.enableWebTransport();
            self.router.get(path, webtransport_mod.route(Ctx, handler, accept));
        }

        /// The HTTP/3 listener speaks WebTransport, now or once it is set
        /// up.
        fn enableWebTransport(self: *Self) void {
            self.extras.webtransport = true;
            // Every endpoint (one per core on Linux), or tickets from one
            // would not resume in 0-RTT on another.
            if (comptime features.http3) if (self.h3) |ep| ep.enableWebTransport();
        }

        /// Serves the files under `dir` below `prefix`: ranges, ETags and
        /// conditional requests, and precompressed copies (`style.css.br`,
        /// `.zst`, `.gz`) when `opts.precompressed` lists them. `dir` must
        /// stay open while the server runs; `staticDir` opens and closes
        /// one for you.
        pub fn static(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: http.StaticOptions) void {
            self.router.static(prefix, dir, opts);
        }

        /// `static` from the directory at `path` (relative to the working
        /// directory), which the server opens now and closes with itself.
        ///
        ///     try app.staticDir("/", "public", .{});
        pub fn staticDir(self: *Self, prefix: []const u8, path: []const u8, opts: http.StaticOptions) !void {
            self.router.static(prefix, try self.openDir(path), opts);
        }

        fn openDir(self: *Self, path: []const u8) !std.Io.Dir {
            const io_ = self.rt.io();
            const dir = std.Io.Dir.cwd().openDir(io_, path, .{}) catch |err| {
                errors.log.err("cannot open the static directory \"{s}\": {t}", .{ path, err });
                return err;
            };
            self.extras.dirs.append(self.arena.allocator(), dir) catch {
                dir.close(io_);
                return error.OutOfMemory;
            };
            return dir;
        }

        /// Serves `data` (usually `@embedFile`) at `path`.
        pub fn embedded(self: *Self, path: []const u8, data: []const u8, opts: http.EmbeddedOptions) void {
            self.router.embedded(path, data, opts);
        }

        /// Routes under `prefix`, behind `middlewares` (after the global
        /// ones): a tuple whose values are copied and owned by the server,
        /// as with `use`, and whose handles (`middleware`, or
        /// `anole.Middleware(Ctx).init(&value)` for a value you keep) are
        /// taken as they are; functions are taken as with `use`. A slice
        /// of handles works too.
        pub fn group(self: *Self, prefix: []const u8, middlewares: anytype) Group {
            return .{ .server = self, .inner = self.router.group(prefix, self.handles(middlewares)) };
        }

        /// Routes behind `middlewares` with no prefix: middleware for the
        /// routes registered through it alone.
        ///
        ///     app.with(.{requireAdmin}).delete("/users/:id", deleteUser);
        pub fn with(self: *Self, middlewares: anytype) Group {
            return self.group("", middlewares);
        }

        /// `middlewares` (a tuple of values and handles, or a slice or array
        /// of handles) as a slice of handles in the server's arena.
        fn handles(self: *Self, middlewares: anytype) []const http.Middleware(Ctx) {
            const M = http.Middleware(Ctx);
            const T = @TypeOf(middlewares);
            const a = self.arena.allocator();
            const info = @typeInfo(T);
            if (info == .@"struct" and info.@"struct".is_tuple) {
                const list = a.alloc(M, info.@"struct".field_names.len) catch @panic("OOM");
                inline for (0..info.@"struct".field_names.len) |i| list[i] = self.middleware(middlewares[i]);
                return list;
            }
            const slice: []const M = middlewares;
            return a.dupe(M, slice) catch @panic("OOM");
        }

        /// Routes registered under a prefix and behind middleware; see
        /// `Server.group`. Groups nest: a nested group's prefix and
        /// middleware come after its parent's.
        pub const Group = struct {
            server: *Self,
            /// The core router's group underneath.
            inner: http.Router(Ctx).Group,

            /// `Server.group`, nested: `prefix` after this group's, and
            /// `middlewares` after its own.
            pub fn group(g: Group, prefix: []const u8, middlewares: anytype) Group {
                return .{ .server = g.server, .inner = g.inner.group(prefix, g.server.handles(middlewares)) };
            }
            /// Routes behind more middleware, with no further prefix.
            pub fn with(g: Group, middlewares: anytype) Group {
                return g.group("", middlewares);
            }
            /// `Server.get` under this group.
            pub fn get(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.get, path, handler, false);
                g.server.register(g.inner, .get, path, handler);
            }
            /// `Server.head` under this group.
            pub fn head(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.head, path, handler, false);
                g.server.register(g.inner, .head, path, handler);
            }
            /// `Server.post` under this group.
            pub fn post(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.post, path, handler, false);
                g.server.register(g.inner, .post, path, handler);
            }
            /// `Server.put` under this group.
            pub fn put(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.put, path, handler, false);
                g.server.register(g.inner, .put, path, handler);
            }
            /// `Server.patch` under this group.
            pub fn patch(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.patch, path, handler, false);
                g.server.register(g.inner, .patch, path, handler);
            }
            /// `Server.delete` under this group.
            pub fn delete(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.delete, path, handler, false);
                g.server.register(g.inner, .delete, path, handler);
            }
            /// `Server.options` under this group.
            pub fn options(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.options, path, handler, false);
                g.server.register(g.inner, .options, path, handler);
            }
            /// `Server.query` under this group.
            pub fn query(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(.query, path, handler, false);
                g.server.register(g.inner, .query, path, handler);
            }
            /// `Server.any` under this group.
            pub fn any(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                comptime typed.checkRoute(null, path, handler, false);
                g.server.register(g.inner, null, path, handler);
            }
            /// `Server.ws` under this group.
            pub fn ws(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                g.wsWith(path, handler, .{});
            }
            /// `Server.wsWith` under this group.
            pub fn wsWith(g: Group, comptime path: []const u8, comptime handler: anytype, comptime upgrade: websocket.UpgradeOptions) void {
                if (comptime !features.websocket) @compileError("ws needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
                if (comptime path.len > 0) comptime checkPattern("GET", path); // "": the group's own path
                g.inner.get(path, websocket.route(Ctx, handler, upgrade));
            }
            /// `Server.wsCallbacks` under this group.
            pub fn wsCallbacks(g: Group, comptime path: []const u8, comptime Handlers: type) void {
                g.wsCallbacksWith(path, Handlers, .{});
            }
            /// `Server.wsCallbacksWith` under this group.
            pub fn wsCallbacksWith(g: Group, comptime path: []const u8, comptime Handlers: type, comptime upgrade: websocket.UpgradeOptions) void {
                if (comptime !features.websocket) @compileError("wsCallbacks needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
                if (comptime path.len > 0) comptime checkPattern("GET", path); // "": the group's own path
                g.inner.get(path, websocket.callbacks(Ctx, Handlers, upgrade));
            }
            /// `Server.webtransport` under this group.
            pub fn webtransport(g: Group, comptime path: []const u8, comptime handler: anytype) void {
                g.webtransportWith(path, handler, .{});
            }
            /// `Server.webtransportWith` under this group.
            pub fn webtransportWith(g: Group, comptime path: []const u8, comptime handler: anytype, comptime accept: webtransport_mod.AcceptOptions) void {
                if (comptime !features.http3) @compileError("webtransport needs HTTP/3 (-Dhttp3, on in the full profile)");
                if (comptime path.len > 0) comptime checkPattern("GET", path); // "": the group's own path
                g.server.enableWebTransport();
                g.inner.get(path, webtransport_mod.route(Ctx, handler, accept));
            }
            /// `Server.addRoute` under this group.
            pub fn addRoute(g: Group, method: ?http.Method, path: []const u8, comptime handler: anytype) void {
                g.server.register(g.inner, method, path, handler);
            }
            /// `Server.static` under this group.
            pub fn static(g: Group, prefix: []const u8, dir: std.Io.Dir, opts: http.StaticOptions) void {
                g.inner.static(prefix, dir, opts);
            }
            /// `Server.staticDir` under this group.
            pub fn staticDir(g: Group, prefix: []const u8, path: []const u8, opts: http.StaticOptions) !void {
                g.inner.static(prefix, try g.server.openDir(path), opts);
            }
            /// `Server.embedded` under this group.
            pub fn embedded(g: Group, path: []const u8, data: []const u8, opts: http.EmbeddedOptions) void {
                g.inner.embedded(path, data, opts);
            }
            /// `Server.grpc` behind this group's middleware (and the global
            /// ones). The gRPC paths (`/pkg.Service/Method`) and the
            /// transcoded REST paths come from the proto, so the group's
            /// prefix does not apply to them; its middleware runs for both,
            /// as for any route of the group.
            ///
            ///     const api = app.group("/v1", .{auth});
            ///     api.grpc(pb.Users, users);          // /pkg.Users/Get and GET /v1/users/{id}, both behind auth
            pub fn grpc(g: Group, comptime Service: anytype, impl: anytype) void {
                g.grpcWith(Service, impl, .{});
            }
            /// `Server.grpcWith` under this group.
            pub fn grpcWith(g: Group, comptime Service: anytype, impl: anytype, opts: grpc_mod.RegisterOptions) void {
                g.server.grpcOn(g.inner, Service, impl, opts);
            }
        };

        /// The server's outbound HTTP client, made with the server and
        /// shared by every handler; `anole.client(req)` finds the same one
        /// from a request.
        pub fn client(self: *Self) client_mod.Client {
            return .{ .http = &self.extras.client };
        }

        /// Serves the gRPC service `Service` with the handlers in `impl`,
        /// over gRPC (HTTP/2), gRPC-Web, Connect (Connect GET for methods
        /// marked `NO_SIDE_EFFECTS`), and as REST routes for methods
        /// annotated with `google.api.http` (JSON transcoding).
        ///
        /// `Service` is the generated service (`pb.Greeter`, or an
        /// instance `pb.Greeter(anole.grpc.Call, anyerror)`). `impl` holds
        /// the handlers, `fn (call: *anole.grpc.Call, request) !Response`
        /// and the streaming shapes: a struct literal
        /// (`.{ .SayHello = sayHello }`), a type that declares them by
        /// method name, or a pointer to a value whose methods take it first
        /// (`fn (self: *Greeter, call, request)`).
        pub fn grpc(self: *Self, comptime Service: anytype, impl: anytype) void {
            self.grpcWith(Service, impl, .{});
        }

        /// `grpc`, with options for this registration (the message size
        /// limit, transcoding off).
        pub fn grpcWith(self: *Self, comptime Service: anytype, impl: anytype, opts: grpc_mod.RegisterOptions) void {
            self.grpcOn(self.router, Service, impl, opts);
        }

        /// `grpcWith` on a router or one of its groups (`Group.grpc`).
        fn grpcOn(self: *Self, target: anytype, comptime Service: anytype, impl: anytype, opts: grpc_mod.RegisterOptions) void {
            if (comptime !features.grpc) @compileError("app.grpc needs gRPC (-Dgrpc, on in the full profile)");
            const Svc = if (@TypeOf(Service) == type) Service else Service(grpc_mod.Call, anyerror);
            if (comptime features.openapi) self.recordGrpc(target, Svc, opts);
            const I = @TypeOf(impl);
            if (@typeInfo(I) == .pointer and @typeInfo(@typeInfo(I).pointer.child) == .@"struct") {
                // Methods on a value: the registration carries the pointer
                // (`Call.data`) to them.
                var with_data = opts;
                with_data.data = @ptrCast(@constCast(impl));
                grpc_mod.registerWith(Ctx, target, Svc, comptime boundMethods(Svc, @typeInfo(I).pointer.child), with_data);
            } else if (I == type) {
                grpc_mod.registerWith(Ctx, target, Svc, comptime declaredMethods(Svc, impl), opts);
            } else {
                grpc_mod.registerWith(Ctx, target, Svc, comptime listedMethods(Svc, impl), opts);
            }
        }

        /// Keeps the documented operations of `Svc` for the OpenAPI document.
        /// Which forms appear (`Options.grpc`) is decided when it is built.
        fn recordGrpc(self: *Self, target: anytype, comptime Svc: type, opts: grpc_mod.RegisterOptions) void {
            const ops = comptime openapi_mod.proto.serviceOperations(Svc);
            const a = self.arena.allocator();
            const chain = self.chainDocs(target);
            inline for (0..ops.len) |i| {
                const wanted = ops[i].kind != .transcoded or opts.transcode;
                if (wanted) {
                    const op: *const openapi_mod.operation.Operation = comptime &ops[i].op;
                    self.extras.doc_entries.append(a, .{
                        .verb = ops[i].verb,
                        .path = ops[i].path,
                        .op = op,
                        .middleware = chain,
                        .annotated = ops[i].annotated,
                        .tag_doc = comptime openapi_mod.proto.serviceDoc(Svc),
                    }) catch @panic("OOM");
                }
            }
        }

        /// The service's handlers from a struct literal naming each one.
        fn listedMethods(comptime Svc: type, comptime impl: anytype) Svc {
            if (@TypeOf(impl) == Svc) return impl;
            var out: Svc = undefined;
            for (@typeInfo(Svc).@"struct".field_names) |name| {
                if (!@hasField(@TypeOf(impl), name)) @compileError("no handler for " ++ Svc.service_name ++ "." ++ name ++ " in " ++ @typeName(@TypeOf(impl)));
                @field(out, name) = @field(impl, name);
            }
            return out;
        }

        /// The service's handlers from `Impl`'s declarations.
        fn declaredMethods(comptime Svc: type, comptime Impl: type) Svc {
            var out: Svc = undefined;
            for (@typeInfo(Svc).@"struct".field_names) |name| {
                if (!@hasDecl(Impl, name)) @compileError(@typeName(Impl) ++ " has no handler for " ++ Svc.service_name ++ "." ++ name);
                @field(out, name) = @field(Impl, name);
            }
            return out;
        }

        /// The service's handlers from `T`'s methods, each called on the
        /// value the registration carries.
        fn boundMethods(comptime Svc: type, comptime T: type) Svc {
            var out: Svc = undefined;
            const info = @typeInfo(Svc).@"struct";
            for (info.field_names, info.field_types) |name, F| {
                if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " has no method for " ++ Svc.service_name ++ "." ++ name);
                const method = @field(T, name);
                const f = @typeInfo(@typeInfo(F).pointer.child).@"fn";
                const R = f.return_type.?;
                const Call = grpc_mod.Call;
                @field(out, name) = if (f.param_types.len == 2) struct {
                    fn call(c: *Call, a: f.param_types[1].?) R {
                        return method(@as(*T, @ptrCast(@alignCast(c.data.?))), c, a);
                    }
                }.call else struct {
                    fn call(c: *Call, a: f.param_types[1].?, b: f.param_types[2].?) R {
                        return method(@as(*T, @ptrCast(@alignCast(c.data.?))), c, a, b);
                    }
                }.call;
            }
            return out;
        }

        /// Hands the databases what the app observes with, once (`run` does
        /// it too): the C ABI opens them before anything listens.
        pub fn startConnectors(self: *Self) !void {
            const extras = self.extras;
            if (extras.connectors_started) return;
            extras.connectors_started = true;
            for (extras.connectors.items) |c| c.start(c.context, extras.metrics, extras.exporter, extras.health) catch |err| {
                extras.failed_system = c.name;
                extras.failed_cause = @errorName(err);
                return err;
            };
            if (extras.metrics) |registry| {
                const cfg = extras.client.config;
                if (cfg.breaker != null or cfg.retry != null) {
                    const binding = try self.gpa.create(resilience_mod.Binding);
                    errdefer self.gpa.destroy(binding);
                    binding.* = try .init(self.gpa, registry);
                    extras.resilience = binding;
                    extras.client.observeResilience(binding.metricsHooks());
                }
            }
        }

        /// The routes `metrics` and `health` left for when serving starts.
        fn addHelperRoutes(self: *Self) void {
            const extras = self.extras;
            if (extras.routes_added) return;
            extras.routes_added = true;
            if (extras.metrics) |r| r.serveOnListener(Ctx, self.router, extras.metrics_path, extras.metrics_listener);
            if (extras.health) |h| h.registerOn(Ctx, self.router, self.server);
            if (comptime features.openapi) self.serveOpenApi();
        }

        /// Serves the OpenAPI document of this server's routes at
        /// `opts.path` and the Scalar page at `opts.page`, when `opts.serve`
        /// allows (by default in development only). Call it any time before
        /// `run`/`listen`. The document is built once when serving starts, so
        /// a schema-name clash stops the start (`error.OpenApiNameClash`,
        /// with both type names in the log).
        pub fn openapi(self: *Self, opts: openapi_mod.Options) void {
            if (comptime !features.openapi) @compileError("app.openapi needs -Dopenapi (on in the web and full profiles)");
            self.extras.openapi_options = opts;
        }

        /// The document as `run` would serve it, in `gpa`'s memory (caller
        /// frees), for tests and tools. Works whether or not `openapi` was
        /// called (default options then).
        pub fn openapiDocument(self: *Self, gpa: std.mem.Allocator) openapi_mod.BuildError![]u8 {
            if (comptime !features.openapi) @compileError("app.openapiDocument needs -Dopenapi (on in the web and full profiles)");
            const opts = self.extras.openapi_options orelse openapi_mod.Options{};
            return openapi_mod.document.build(gpa, self.extras.doc_entries.items, opts, self.server.config.errors, errors.log);
        }

        fn serveOpenApi(self: *Self) void {
            const opts = self.extras.openapi_options orelse return;
            const on = switch (opts.serve) {
                .always => true,
                .development => self.mode.environment == .development,
                .never => false,
            };
            if (!on) return;
            const a = self.arena.allocator();
            const doc = self.openapiDocument(self.gpa) catch |err| {
                // `run` reports it again as the start's error.
                self.extras.openapi_failed = err;
                return;
            };
            defer self.gpa.free(doc);
            const data = a.dupe(u8, doc) catch @panic("OOM");
            var chain: [1]http.Middleware(Ctx) = undefined;
            var n: usize = 0;
            if (opts.listener) |name| {
                const only = a.create(OnlyOn) catch @panic("OOM");
                only.* = onlyOn(name);
                chain[0] = http.Middleware(Ctx).init(only);
                n = 1;
            }
            const g = self.router.group("", chain[0..n]);
            g.embedded(opts.path, data, .{ .content_type = .json, .cache_control = "no-cache" });
            if (opts.page) |page_path| {
                const html = openapi_mod.page.render(self.gpa, opts.info.title, opts.path) catch @panic("OOM");
                defer self.gpa.free(html);
                g.embedded(page_path, a.dupe(u8, html) catch @panic("OOM"), .{ .content_type = .html, .cache_control = "no-cache" });
            }
            std.log.scoped(.anole).info("openapi: {s} and {s} (development only unless serve = .always)", .{ opts.path, opts.page orelse "(no page)" });
        }

        /// ANOLE_OPENAPI_OUT / ANOLE_OPENAPI_CHECK: the real environment
        /// only, never a `.env` file.
        fn openapiEnv(self: *const Self) OpenApiEnv {
            if (self._openapi_env) |e| return e;
            const environ = if (self.process) |p| p.environ else null;
            const url = @import("db/url.zig");
            return .{ .out = url.realEnv(environ, "ANOLE_OPENAPI_OUT"), .check = url.realEnv(environ, "ANOLE_OPENAPI_CHECK") };
        }

        /// `zig build openapi` / `openapi-check`: writes or compares the
        /// document, before anything binds or starts.
        fn openapiTool(self: *Self, env: OpenApiEnv) !void {
            const log = errors.log;
            if (comptime !features.openapi) return self.failStart(error.OpenApiNotBuilt);
            if (self.router.conflict != null) return self.failStart(error.RouteConflict);
            const doc = self.openapiDocument(self.gpa) catch |err| return self.failStart(errors.toServerError(err));
            defer self.gpa.free(doc);
            const io_ = self.rt.io();
            const cwd = std.Io.Dir.cwd();
            if (env.out) |path| {
                const tmp = std.fmt.allocPrint(self.gpa, "{s}.tmp", .{path}) catch return self.failStart(error.OutOfMemory);
                defer self.gpa.free(tmp);
                cwd.writeFile(io_, .{ .sub_path = tmp, .data = doc }) catch |err| {
                    log.err("openapi: can't write {s}: {t}", .{ path, err });
                    return self.failStart(error.AccessDenied);
                };
                cwd.rename(tmp, cwd, path, io_) catch |err| {
                    log.err("openapi: can't write {s}: {t}", .{ path, err });
                    return self.failStart(error.AccessDenied);
                };
                var paths: usize = 0;
                for (self.extras.doc_entries.items) |_| paths += 1;
                log.info("openapi: wrote {s} ({d} operations)", .{ path, paths });
                return;
            }
            if (env.check) |path| {
                const have = cwd.readFileAlloc(io_, path, self.gpa, .limited(64 << 20)) catch "";
                defer if (have.len > 0) self.gpa.free(have);
                if (!std.mem.eql(u8, have, doc)) {
                    log.err("openapi: {s} is out of date; run `zig build openapi`", .{path});
                    return self.failStart(error.OpenApiOutOfDate);
                }
                log.info("openapi: {s} is up to date", .{path});
            }
        }

        /// The standard gRPC health service (grpc.health.v1), owned by the
        /// server: the server as a whole ("") is SERVING, and every service
        /// turns NOT_SERVING when the server drains. Set a service's status
        /// through what it returns.
        pub fn grpcHealth(self: *Self) *grpc_mod.Health {
            if (comptime !features.grpc) @compileError("app.grpcHealth needs gRPC (-Dgrpc, on in the full profile)");
            if (self.extras.grpc_health) |h| return h;
            const h = self.arena.allocator().create(grpc_mod.Health) catch @panic("OOM");
            h.* = .init(self.gpa, self.rt.io());
            h.registerOn(Ctx, self.router);
            self.extras.grpc_health = h;
            return h;
        }

        /// `metrics`' settings.
        pub const MetricsOptions = struct {
            /// Where Prometheus scrapes.
            path: []const u8 = "/metrics",
            /// Count every request (`anole_http_*`), through a middleware.
            /// Off: `/metrics` serves only what is added to the registry.
            http: bool = true,
            /// Paths the HTTP metrics leave out.
            exclude: []const []const u8 = &observe.probe_paths,
            /// Serve `path` only on the listener of this name
            /// (`Options.Listener.name`, an internal port the scraper
            /// reaches), 404 on the others. Null: on every listener,
            /// public ones included, and the metrics name routes, errors
            /// and databases; then keep the port private or put auth
            /// middleware in front (global `use` middleware runs first).
            listener: ?[]const u8 = null,
        };

        /// Prometheus metrics at `/metrics`, with the HTTP request counts,
        /// durations and requests in flight. Returns the registry, owned by
        /// the server, for metrics of your own. It adds a middleware: call
        /// it with the other `use` calls, before the routes. (The
        /// `/metrics` route itself is added when serving starts.)
        pub fn metrics(self: *Self, opts: MetricsOptions) *observe.metrics.Registry {
            if (self.extras.metrics) |r| return r;
            if (opts.http and self.router.has_routes) @panic("app.metrics() adds a middleware, so it goes before the routes, with app.use()");
            const r = self.arena.allocator().create(observe.metrics.Registry) catch @panic("OOM");
            r.* = .init(self.gpa, self.rt.io());
            r.runtime_gauges = true;
            self.extras.metrics = r;
            self.extras.metrics_path = opts.path;
            self.extras.metrics_listener = opts.listener;
            if (opts.http) self.use(observe.metrics.HttpMetrics.init(r, .{ .exclude = opts.exclude }) catch @panic("OOM"));
            return r;
        }

        /// `/healthz` (alive) and `/readyz` (every readiness check passes
        /// and the server is not draining). Returns them, owned by the
        /// server, for `addCheck`. The routes are added when serving
        /// starts, after everything `use` adds.
        pub fn health(self: *Self, opts: observe.Health.Options) *observe.Health {
            if (self.extras.health) |h| return h;
            const h = self.arena.allocator().create(observe.Health) catch @panic("OOM");
            h.* = .init(opts);
            self.extras.health = h;
            return h;
        }

        /// `tracing`'s settings.
        pub const TracingOptions = struct {
            /// The collector's OTLP/HTTP base URL. Null: the
            /// `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable, else
            /// http://localhost:4318.
            endpoint: ?[]const u8 = null,
            /// Null: `OTEL_SERVICE_NAME` (as above), else "anole".
            service_name: ?[]const u8 = null,
            /// Record every request, or only those whose caller sampled.
            sample_all: bool = true,
            /// Paths not traced.
            exclude: []const []const u8 = &observe.probe_paths,
            /// Spans per export request.
            batch_size: usize = 256,
            /// How often finished spans are sent, at the latest.
            interval: Duration = .fromSeconds(2),
            /// Spans held while waiting to be sent; past it, new ones are
            /// dropped.
            queue_len: usize = 4096,
        };

        /// OpenTelemetry traces: a span per request (W3C `traceparent` in
        /// and out), sent in batches to an OTLP/HTTP collector through the
        /// server's client. The exporter is owned by the server, which
        /// sends what is left when it is freed. It adds a middleware: call
        /// it with the other `use` calls, before the routes.
        pub fn tracing(self: *Self, opts: TracingOptions) !*observe.trace.Exporter {
            if (self.extras.exporter) |e| return e;
            if (self.router.has_routes) @panic("app.tracing() adds a middleware, so it goes before the routes, with app.use()");
            const env: ?std.process.Environ = if (self.process) |p| p.environ else null;
            const url = @import("db/url.zig");
            const e = try self.arena.allocator().create(observe.trace.Exporter);
            e.* = try observe.trace.Exporter.init(self.gpa, self.rt.io(), self.client(), .{
                .endpoint = opts.endpoint orelse url.env(env, "OTEL_EXPORTER_OTLP_ENDPOINT") orelse "http://localhost:4318",
                .service_name = opts.service_name orelse url.env(env, "OTEL_SERVICE_NAME") orelse "anole",
                .sample_all = opts.sample_all,
                .exclude = opts.exclude,
                .batch_size = opts.batch_size,
                .interval = opts.interval,
                .queue_len = opts.queue_len,
            });
            e.start() catch |err| {
                e.deinit();
                return err;
            };
            self.extras.exporter = e;
            self.use(observe.trace.Middleware.init(e));
            return e;
        }

        /// A PostgreSQL database for the handlers, owned by the server:
        /// `state.db = try app.postgres(.{});` reads `DATABASE_URL` (or
        /// `options.url`, or libpq's `PG*` variables). No connection opens
        /// before a handler needs one (unless `connect_at_start`). Once
        /// serving, it reports to `app.metrics`, `app.tracing` and
        /// `app.health` (a ping behind `/readyz`) when the app has them,
        /// and it is closed with the server, after the drain. See
        /// `anole.pg`.
        pub fn postgres(self: *Self, config: pg_mod.Options) !*pg_mod.Client {
            if (comptime !features.postgres) @compileError("app.postgres needs PostgreSQL (-Dpostgres, on in the web and full profiles)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const d = try pg_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer d.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(pg_mod.Client, d));
            return d;
        }

        /// Opens a SQLite database (`anole.sqlite`), closed with the server:
        /// a file, created when missing, or `":memory:"`, one in-memory
        /// database for the whole app; or `anole.sqlite.Options`. Writes
        /// run on its writer thread and reads on the blocking pool, which
        /// this starts when `Options.blocking` did not. When serving starts
        /// it reports to `metrics`, `tracing` and `/readyz`, whichever the
        /// app has, and it is closed with the server, after the drain.
        ///
        ///     state.db = try app.sqlite("app.db");
        ///     state.db = try app.sqlite(.{ .path = "data/app.db", .busy_timeout = .fromSeconds(10) });
        pub fn sqlite(self: *Self, config: anytype) !*sqlite_mod.Client {
            if (comptime !features.sqlite) @compileError("app.sqlite needs SQLite (-Dsqlite, on in the web and full profiles)");
            const opts: sqlite_mod.Options = switch (@typeInfo(@TypeOf(config))) {
                .pointer => .{ .path = config },
                else => config,
            };
            if (self.blocking_pool == null) {
                const p = try self.arena.allocator().create(blocking.Pool);
                try p.init(self.rt, .{});
                self.blocking_pool = p;
            }
            const d = try sqlite_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer d.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(sqlite_mod.Client, d));
            return d;
        }

        /// A MongoDB client for the handlers, owned by the server:
        /// `state.db = try app.mongodb(.{});` reads `MONGODB_URI` (or
        /// `options.url`), else mongodb://localhost:27017. It starts
        /// monitoring the servers at once; connections for calls open when
        /// a handler needs one. Once serving, it reports to `app.metrics`,
        /// `app.tracing` and `app.health` (a ping behind `/readyz`) when the
        /// app has them, and it is closed with the server, after the drain.
        /// See `anole.mongodb`.
        pub fn mongodb(self: *Self, config: mongodb_mod.Options) !*mongodb_mod.Client {
            if (comptime !features.mongodb) @compileError("app.mongodb needs MongoDB (-Dmongodb, on in the full profile)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const mongo = try mongodb_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer mongo.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(mongodb_mod.Client, mongo));
            return mongo;
        }

        /// A Redis or Valkey client for the handlers, owned by the server:
        /// `state.redis = try app.redis(.{});` reads `REDIS_URL` (or
        /// `options.url`), else uses `redis://127.0.0.1:6379`. No
        /// connection opens before a handler needs one (unless
        /// `connect_at_start`). Once serving, it reports to `app.metrics`,
        /// `app.tracing` and `app.health` (a PING behind `/readyz`) when
        /// the app has them, and it is closed with the server, after the
        /// drain. See `anole.redis`.
        pub fn redis(self: *Self, config: redis_mod.Options) !*redis_mod.Client {
            if (comptime !features.redis) @compileError("app.redis needs Redis (-Dredis, on in the full profile)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const r = try redis_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer r.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(redis_mod.Client, r));
            return r;
        }

        /// A NATS client for the handlers, owned by the server: `NATS_URL`
        /// (or `config.url`), else nats://127.0.0.1:4222. It connects when
        /// serving starts, feeds `app.metrics`, `app.tracing` and
        /// `app.health` (readiness = connected) when the app has them, and
        /// is drained and closed with the server. Register handlers with
        /// `nc.handle(&app, subject, opts, fn)` before `run`. See
        /// `anole.nats`.
        pub fn nats(self: *Self, config: nats_mod.Options) !*nats_mod.Client {
            if (comptime !features.nats) @compileError("app.nats needs NATS (-Dnats, on in the full profile)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const n = try nats_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer n.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(nats_mod.Client, n));
            return n;
        }

        /// A Kafka client for the handlers, owned by the server:
        /// `state.kafka = try app.kafka(.{});` reads KAFKA_BOOTSTRAP_SERVERS
        /// (or `options.brokers`), else `localhost:9092`. Nothing connects
        /// before the first call (unless `connect_at_start`). Once serving,
        /// it reports to `app.metrics`, `app.tracing` and `app.health` when
        /// the app has them, joins the groups registered with `consume`,
        /// and at shutdown drains: records in flight finish, offsets are
        /// committed, the producer flushes. See `anole.kafka`.
        pub fn kafka(self: *Self, config: kafka_mod.Options) !*kafka_mod.Client {
            if (comptime !features.kafka) @compileError("app.kafka needs Kafka (-Dkafka, on in the full profile)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const k = try kafka_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer k.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(kafka_mod.Client, k));
            if (self.extras.connectors_started) try k.start(self.extras.metrics, self.extras.exporter, self.extras.health);
            return k;
        }

        // ---- p3/net ----
        /// Serves `handler` (callbacks or `fn (*Conn) !void`) on raw TCP at
        /// `address` (":7000", "127.0.0.1:7000"), beside whatever else the
        /// server serves. Before `listen`/`listenTls`/`run`, on a server
        /// whose init named no listener (else `error.ListenersAlreadySet`:
        /// put it in `.listeners`). See docs/net.md.
        ///
        ///     try app.tcp(":7000", Echo, .{});
        pub fn tcp(self: *Self, address: []const u8, comptime handler: anytype, comptime opts: net_mod.Tcp.Options) errors.ServerError!void {
            return self.addRaw("tcp", address, .{ .tcp = net_mod.tcp(Ctx, handler, opts) });
        }

        /// `tcp` with a whole listener (name, TLS, PROXY, unix socket); its
        /// `tcp` and `udp` fields must be null.
        pub fn tcpOn(self: *Self, listener: Options.Listener, comptime handler: anytype, comptime opts: net_mod.Tcp.Options) errors.ServerError!void {
            var l = listener;
            l.tcp = net_mod.tcp(Ctx, handler, opts);
            return self.addRawListener("tcpOn", l);
        }

        /// Serves UDP datagrams to `handler` at `address`: one socket per
        /// core on Linux, batched both ways. Handlers run inline and must
        /// not wait. See docs/net.md.
        pub fn udp(self: *Self, address: []const u8, comptime handler: type, comptime opts: net_mod.Udp.Options) errors.ServerError!void {
            return self.addRaw("udp", address, .{ .udp = net_mod.udp(Ctx, handler, opts) });
        }

        pub fn udpOn(self: *Self, listener: Options.Listener, comptime handler: type, comptime opts: net_mod.Udp.Options) errors.ServerError!void {
            var l = listener;
            l.udp = net_mod.udp(Ctx, handler, opts);
            return self.addRawListener("udpOn", l);
        }

        const RawKind = struct { tcp: ?net_mod.TcpService = null, udp: ?net_mod.UdpService = null };

        fn addRaw(self: *Self, comptime what: []const u8, address: []const u8, kind: RawKind) errors.ServerError!void {
            const at = address_mod.parse(address) catch {
                errors.log.err(what ++ "(\"{s}\"): not an address to listen on; use \":7000\" (every interface) or \"127.0.0.1:7000\" (this machine only)", .{address});
                return error.InvalidListenAddress;
            };
            return self.addRawListener(what, .{ .address = at.host, .port = at.port, .tcp = kind.tcp, .udp = kind.udp });
        }

        fn addRawListener(self: *Self, comptime what: []const u8, l: Options.Listener) errors.ServerError!void {
            if (comptime !features.net) @compileError("app." ++ what ++ " needs raw TCP and UDP servers (-Dnet, on in the web and full profiles)");
            const opts = &(self.pending orelse {
                errors.log.err(what ++ "(): this server's listeners come from its init options (http, https); add it to .listeners, or leave both out of init", .{});
                return error.ListenersAlreadySet;
            });
            const a = self.arena.allocator();
            const list = a.alloc(Options.Listener, opts.listeners.len + 1) catch return error.OutOfMemory;
            @memcpy(list[0..opts.listeners.len], opts.listeners);
            list[opts.listeners.len] = l;
            opts.listeners = list;
        }

        /// A UDP listener's first socket, for sends from elsewhere; null
        /// before serving or for no such UDP listener.
        pub fn udpSocket(self: *Self, listener: []const u8) ?*net_mod.UdpSocket {
            for (self.net_udp.items) |g| if (std.mem.eql(u8, g.name, listener)) return &g.sockets[0];
            return null;
        }

        /// Counters over every raw listener.
        pub fn netStats(self: *const Self) net_mod.Stats {
            var st: net_mod.Stats = .{};
            for (self.net_tcp.items) |t| {
                st.connections += t.stats.open.load(.monotonic);
                st.connections_total += t.stats.total.load(.monotonic);
                st.bytes_in += t.stats.bytes_in.load(.monotonic);
                st.bytes_out += t.stats.bytes_out.load(.monotonic);
            }
            for (self.net_udp.items) |g| {
                const t = g.totals();
                st.datagrams_in += t.datagrams_in;
                st.datagrams_out += t.datagrams_out;
                st.datagrams_dropped += t.dropped;
                st.sessions += t.sessions;
            }
            return st;
        }
        // ---- end p3/net ----

        // ---- p3/jobs ----
        const jobs_mod = if (features.jobs) @import("jobs/root.zig") else struct {
            pub const Options = struct {};
            pub const Client = void;
        };

        /// A durable job queue for the handlers, owned by the server
        /// (`anole.jobs`): its store is a connector made with `postgres`,
        /// `sqlite` or `redis` (or `.memory`, lost on restart). It starts
        /// with serving, after its store, and is drained and closed with the
        /// server. Register handlers with `jobs.handle(&app, Args, .{}, fn)`
        /// before `run`. Under `deployment = lambda` it only enqueues.
        pub fn jobs(self: *Self, config: jobs_mod.Options) !*jobs_mod.Client {
            if (comptime !features.jobs) @compileError("app.jobs needs jobs (-Djobs, on in the web and full profiles)");
            switch (config.store) {
                .memory => {},
                inline else => |store_client| {
                    var known = false;
                    for (self.extras.connectors.items) |k| {
                        if (k.context == @as(*anyopaque, @ptrCast(store_client))) known = true;
                    }
                    if (!known) {
                        std.log.scoped(.anole).err("jobs.store: a client made by this app (app.postgres, app.sqlite or app.redis)", .{});
                        return error.InvalidOptions;
                    }
                },
            }
            const j = try jobs_mod.Client.init(self.gpa, self.rt.io(), config);
            errdefer j.deinit();
            j.suppress_workers = self.mode.deployment == .lambda;
            j.drain_event = &self.server.draining;
            try self.extras.connectors.append(self.arena.allocator(), .of(jobs_mod.Client, j));
            if (self.extras.connectors_started) try j.start(self.extras.metrics, self.extras.exporter, self.extras.health);
            return j;
        }
        // ---- end p3/jobs ----

        // ---- p3/webhooks ----
        /// Webhooks out: endpoints, signed deliveries run as jobs, retries,
        /// and the delivery log, on `options.jobs`' store. Owned by the
        /// server (started and freed with it). See `anole.webhooks`.
        ///
        ///     const hooks = try app.webhooks(.{ .jobs = jobs });
        ///     _ = try hooks.publish(req, .{ .owner = "acme", .type = "invoice.paid" }, .{ .id = 7 });
        pub fn webhooks(self: *Self, config: @import("webhooks/root.zig").Options) !*@import("webhooks/root.zig").Client {
            if (comptime !features.webhooks) @compileError("app.webhooks needs webhooks (-Dwebhooks, on in the web and full profiles)");
            const wh = @import("webhooks/root.zig");
            const w = try wh.Client.init(self.gpa, self.rt.io(), config);
            errdefer w.deinit();
            try w.register(self);
            try self.extras.connectors.append(self.arena.allocator(), .of(wh.Client, w));
            if (self.extras.connectors_started) try w.start(self.extras.metrics, self.extras.exporter, self.extras.health);
            return w;
        }

        /// A middleware that checks the signature of an incoming webhook
        /// and drops duplicate deliveries; freed with the server. Panics
        /// with the reason when the options are invalid (startup code).
        ///
        ///     const hook = app.webhookVerify(.{ .preset = .stripe, .secrets = &.{secret} });
        ///     app.with(.{hook}).post("/hooks/stripe", stripeHook);
        pub fn webhookVerify(self: *Self, config: @import("webhooks/root.zig").Verify.Options) *@import("webhooks/root.zig").Verify {
            if (comptime !features.webhooks) @compileError("app.webhookVerify needs webhooks (-Dwebhooks, on in the web and full profiles)");
            const wh = @import("webhooks/root.zig");
            const v = wh.Verify.init(self.gpa, self.rt.io(), config) catch |err| @panic(@errorName(err));
            self.extras.connectors.append(self.arena.allocator(), .of(wh.Verify, v)) catch @panic("OOM");
            return v;
        }
        // ---- end p3/webhooks ----

        // ---- p3/realtime ----
        // ---- end p3/realtime ----

        // ---- p3/s3 ----
        const s3_mod = if (features.s3) @import("s3/root.zig") else struct {
            pub const Options = struct {};
            pub const Client = void;
        };

        /// An S3-compatible object store for the handlers (AWS S3,
        /// Cloudflare R2, MinIO, Backblaze B2, Supabase Storage), owned by
        /// the server: `state.files = try app.s3(.{});` reads the AWS SDKs'
        /// environment (AWS_ENDPOINT_URL_S3, AWS_REGION, AWS_ACCESS_KEY_ID,
        /// AWS_SECRET_ACCESS_KEY...) and S3_BUCKET. Credentials are resolved
        /// when serving starts (a start that finds none fails, naming every
        /// source it tried). Once serving it reports to `app.metrics`,
        /// `app.tracing` and, with `readiness`, `app.health`, and it is
        /// drained and closed with the server. See `anole.s3`.
        pub fn s3(self: *Self, config: s3_mod.Options) !*s3_mod.Client {
            if (comptime !features.s3) @compileError("app.s3 needs the S3 client (-Ds3, on in the web and full profiles)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const c = try s3_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer c.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(s3_mod.Client, c));
            if (self.extras.connectors_started) try c.start(self.extras.metrics, self.extras.exporter, self.extras.health);
            return c;
        }
        // ---- end p3/s3 ----

        // ---- p3/smtp ----
        const smtp_mod = if (features.smtp) @import("smtp/root.zig") else struct {
            pub const Options = struct {};
            pub const Client = struct {};
        };

        /// An SMTP client for sending mail, owned by the server:
        /// `state.mail = try app.smtp(.{});` reads `SMTP_URL`
        /// (`smtp://user:pass@host:587` for STARTTLS, `smtps://` for TLS from
        /// the first byte), else sends to Mailpit's `smtp://127.0.0.1:1025`
        /// outside production; in production a missing `SMTP_URL` is
        /// `error.InvalidOptions`. Nothing connects before the first send.
        /// Once serving, it reports to `app.metrics`, `app.tracing` and
        /// `app.health` when the app has them, and is drained and closed with
        /// the server. See `anole.smtp`.
        pub fn smtp(self: *Self, config: smtp_mod.Options) !*smtp_mod.Client {
            if (comptime !features.smtp) @compileError("app.smtp needs SMTP (-Dsmtp, on in the web and full profiles)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            if (opts.environment == null) opts.environment = self.environment();
            const m = try smtp_mod.Client.init(self.gpa, self.rt.io(), opts);
            errdefer m.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(smtp_mod.Client, m));
            if (self.extras.connectors_started) try m.start(self.extras.metrics, self.extras.exporter, self.extras.health);
            return m;
        }
        // ---- end p3/smtp ----

        // ---- p3/lambda ----
        // ---- end p3/lambda ----

        /// Loads every TLS listener's certificate and key again (from their
        /// files, for `.files`) and their client CAs (`client_auth`, from
        /// theirs), and switches the TLS listeners and HTTP/3 to them.
        /// Connections that start from then on get the new ones;
        /// connections already open, handshakes in progress included, keep
        /// theirs. Session tickets issued before still resume. SIGHUP calls
        /// it while `run` serves.
        ///
        /// All or nothing: on an error (a file missing, a key that does not
        /// match the certificate) nothing changes, on any listener, and the
        /// server goes on with what it had. Call it from a task of the
        /// server's runtime (`io()`); one reload runs at a time.
        pub fn reloadCertificates(self: *Self) errors.TlsLoadError!void {
            return self.reloadCertificatesInner() catch |err| errors.toTlsLoadError(err);
        }

        fn reloadCertificatesInner(self: *Self) !void {
            if (self.certs.len == 0) return error.NoTlsListener;
            const io_ = self.rt.io();
            try self.extras.cert_mutex.lock(io_);
            defer self.extras.cert_mutex.unlock(io_);
            const next = try self.gpa.alloc(CertState.Pem, self.certs.len);
            defer self.gpa.free(next);
            var loaded: usize = 0;
            defer for (next[0..loaded]) |*p| p.deinit(self.gpa);
            for (self.certs, next) |cs, *n| {
                n.* = if (cs.files) |f|
                    try CertState.load(cs.gpa, io_, .{ .files = .{ .cert_path = f.cert_path, .key_path = f.key_path } })
                else
                    try CertState.load(cs.gpa, io_, .{ .pem = .{ .cert = cs.pem.cert, .key = cs.pem.key } });
                loaded += 1;
            }
            try self.switchCertificates(next);
            loaded = 0;
        }

        /// As `reloadCertificates`, from `cert` instead, for every TLS
        /// listener: new PEM in memory, other files, or a fresh development
        /// certificate. On success it becomes the source later reloads (and
        /// SIGHUP) read again.
        pub fn setCertificate(self: *Self, cert: Cert) errors.TlsLoadError!void {
            return self.setCertificateInner(cert) catch |err| errors.toTlsLoadError(err);
        }

        fn setCertificateInner(self: *Self, cert: Cert) !void {
            if (self.certs.len == 0) return error.NoTlsListener;
            const io_ = self.rt.io();
            try self.extras.cert_mutex.lock(io_);
            defer self.extras.cert_mutex.unlock(io_);
            const next = try self.gpa.alloc(CertState.Pem, self.certs.len);
            defer self.gpa.free(next);
            var loaded: usize = 0;
            defer for (next[0..loaded]) |*p| p.deinit(self.gpa);
            next[0] = try CertState.load(self.gpa, io_, cert);
            loaded = 1;
            for (next[1..]) |*n| {
                n.* = try next[0].dupe(self.gpa);
                loaded += 1;
            }
            try self.switchCertificates(next);
            loaded = 0;
            // In place now; only the paths are left to remember.
            for (self.certs) |cs| cs.setSource(cert) catch |err| {
                std.log.scoped(.anole).warn("certificate in use, but its source is not remembered for the next reload: {t}", .{err});
                cs.freeSource();
            };
        }

        /// Puts `next` (one per `certs`) in place on the TLS listeners and
        /// HTTP/3, or none of it. Takes `next` on success. Under
        /// `cert_mutex`.
        fn switchCertificates(self: *Self, next: []const CertState.Pem) !void {
            const gpa = self.gpa;
            // HTTP/3's context first: it checks the certificate and key, and
            // is dropped if the TCP listeners' reload fails.
            var quic: if (features.http3) ?h3.TlsContext else void = if (features.http3) null else {};
            if (comptime features.http3) if (self.h3) |ep| {
                for (self.certs, next) |cs, n| {
                    const tcp_listener = cs.h3_listener orelse continue;
                    const client_auth = tcp_listener.tls.?.client_auth;
                    var client_ca: ?std.crypto.Certificate.Bundle = null;
                    defer if (client_ca) |*b| b.deinit(gpa);
                    if (client_auth) |ca| client_ca = try ca.ca.load(gpa, self.rt.io());
                    quic = try ep.loadTls(n.cert, n.key, h3ClientAuth(client_auth, client_ca));
                }
            };
            errdefer if (comptime features.http3) if (quic) |*q| q.deinit();

            const TlsPem = @FieldType(http.ServerConfig.Tls, "pem");
            var count: usize = 0;
            for (self.certs) |cs| count += cs.listeners.items.len;
            const before = try gpa.alloc(TlsPem, count);
            defer gpa.free(before);
            var i: usize = 0;
            for (self.certs, next) |cs, n| for (cs.listeners.items) |l| {
                before[i] = l.tls.?.pem;
                l.tls.?.pem = .{ .cert = n.cert, .key = n.key };
                i += 1;
            };
            self.server.reloadTls() catch |err| {
                i = 0;
                for (self.certs) |cs| for (cs.listeners.items) |l| {
                    l.tls.?.pem = before[i];
                    i += 1;
                };
                return err;
            };
            if (comptime features.http3) if (quic) |q| self.h3.?.useTls(q);
            for (self.certs, next) |cs, n| {
                cs.pem.deinit(cs.gpa);
                cs.pem = n;
            }
        }

        /// Ends `run`, as a signal would: the server drains and `run`
        /// returns. Safe from any task or thread of the runtime.
        pub fn stop(self: *Self) void {
            self.stopped.set(self.rt.io());
        }

        /// The live console's socket, once `run` serves; null when it is off
        /// or could not be set up.
        pub fn consoleSocket(self: *const Self) ?[]const u8 {
            const c = self.console orelse return null;
            return c.socket_path;
        }

        /// Whether SIGUSR2's hand-off (and so the console's /restart) is
        /// possible.
        pub fn consoleRestartable(self: *const Self) bool {
            return unix_signals and self.process != null and self.held.len > 0;
        }

        /// HTTP/3 is on.
        pub fn consoleHasH3(self: *const Self) bool {
            if (comptime !features.http3) return false;
            return self.h3 != null;
        }

        /// The console's /restart: `run` hands over as it does on SIGUSR2.
        pub fn consoleRequestRestart(self: *Self) void {
            self.console_restart.set(self.rt.io());
        }

        /// Why /restart cannot hand over the listeners, or null.
        fn consoleRestartWhy(self: *const Self) ?[]const u8 {
            if (!unix_signals) return "not on Windows";
            if (self.console_embedded) return "the C ABI has no listener hand-off; /full-restart re-executes the process";
            if (self.process == null) return "no listener hand-off: set .process = init.minimal in ServerOptions";
            if (self.held.len == 0) return "no listener to hand over";
            return null;
        }

        const console_features: []const []const u8 = blk: {
            var l: []const []const u8 = &.{"h1"};
            if (features.http2) l = l ++ &[_][]const u8{"h2"};
            if (features.http3) l = l ++ &[_][]const u8{"h3"};
            if (features.websocket) l = l ++ &[_][]const u8{"ws"};
            if (features.grpc) l = l ++ &[_][]const u8{"grpc"};
            if (features.postgres or features.sqlite or features.mongodb or features.redis) l = l ++ &[_][]const u8{"db"};
            break :blk l;
        };

        /// Starts the live console (socket, rings, hooks) unless it is off.
        fn startConsole(self: *Self) void {
            if (comptime !features.console) return;
            if (!self.console_resolved.enabled) return;
            const executors: u32 = @intCast(self.rt.executors.items.len);
            self.console = console.Console.start(.{
                .gpa = self.gpa,
                .io = self.rt.io(),
                .resolved = self.console_resolved,
                .host = console_host.Of(Self).make(self, executors),
                .executors = executors,
                .environment = @tagName(self.mode.environment),
                .deployment = @tagName(self.mode.deployment),
                .runtime = self.console_runtime,
                .features = console_features,
                .has_tls = self.certs.len > 0,
                .restart_unavailable = self.consoleRestartWhy(),
                .embedded = self.console_embedded,
            }) catch |err| {
                std.log.scoped(.anole).warn("console: not available: {t}", .{err});
                return;
            };
        }

        /// Once the listeners are up: the console's startup lines, and the
        /// development hotkey.
        fn consoleAnnounce(self: *Self) void {
            const c = self.console orelse return;
            const log = std.log.scoped(.anole);
            self.server.waitReady(self.rt.io()) catch return;
            if (c.warning) |w| {
                log.warn("{s}", .{w});
            } else if (c.socket_path) |path| {
                if (self.console_resolved.socket != null) {
                    log.info("console: `anole console {s}` attaches", .{path});
                } else log.info("console: `anole console {s}` attaches (socket {s})", .{ c.name, path });
            }
            if (self.console_embedded) return;
            const ui_sys = @import("anole_console_ui").sys;
            const gate: console.keys_dev.Gate = .{
                .enabled = true,
                .development = self.mode.environment == .development,
                .is_test = builtin.is_test,
                .stdin_tty = ui_sys.isatty(0),
                .stderr_tty = ui_sys.isatty(2),
                .term = ui_sys.getenv("TERM"),
                .invocation_id = ui_sys.getenv("INVOCATION_ID") != null,
                .journal_stream = ui_sys.getenv("JOURNAL_STREAM") != null,
                .ci = ui_sys.getenv("CI") != null,
                .container = console.supervisor.inContainer(),
                .explicit = self.console_resolved.keys,
            };
            if (console.keys_dev.allowed(gate)) {
                c.startKeys() catch return;
                log.info("press c + Enter for the live console", .{});
            } else if (self.console_resolved.keys == true) {
                log.info("console: keys need a terminal on stdin", .{});
            }
        }

        fn stopConsole(self: *Self, drain: bool) void {
            const c = self.console orelse return;
            self.console = null;
            c.stop(drain);
        }

        /// The bound address of each listener (`http`, `https`, then
        /// `listeners`, in order), once serving; a listener given port 0
        /// has its real port here.
        pub fn addresses(self: *const Self) []const http.Address {
            return self.server.addresses;
        }

        /// Waits until the listeners are bound, or returns `run`'s error if
        /// it stopped before they were (a certificate that will not load,
        /// a port in use) rather than waiting for good.
        pub fn waitReady(self: *Self) errors.ServerError!void {
            self.server.waitReady(self.rt.io()) catch |err| return errors.toServerError(err);
        }

        /// After a start that failed binding: the index (in the options'
        /// listeners) of the listener that could not be bound.
        pub fn failedListenerIndex(self: *const Self) ?usize {
            return self.server.start_error_listener;
        }

        /// The first route conflict recorded (test builds, the C ABI), or
        /// null: what `run` fails with `error.RouteConflict` for.
        pub fn routeConflict(self: *const Self) ?[]const u8 {
            return self.router.conflict;
        }

        /// For `anole.testing`: everything `run` does before binding (the
        /// helper routes, the conflict check, the connectors), and no
        /// listener. Repeatable.
        pub fn _prepareInMemory(self: *Self) errors.ServerError!void {
            return self.prepareInMemoryInner() catch |err| self.failWith(err);
        }

        fn prepareInMemoryInner(self: *Self) !void {
            self.addHelperRoutes();
            if (self.router.conflict) |msg| {
                // Printed, not logged: a test that provokes it must not fail on the log.
                std.debug.print("anole: {s}\n", .{msg});
                return self.failStart(error.RouteConflict);
            }
            self.startConnectors() catch |err| {
                errors.log.err("a database connector could not start: {t}", .{err});
                return self.failStart(error.DatabaseUnavailable);
            };
        }

        /// Serves until SIGINT, SIGTERM or `stop`, then stops accepting and
        /// drains the requests in flight (bounded by `timeout.shutdown`).
        /// Sets up the listeners first when `init` left them (the options'
        /// `listeners`, or 127.0.0.1:8080 when there are none, unless
        /// `listen` or `listenTls` named others). Call it from the
        /// thread that called `init`.
        pub fn run(self: *Self) errors.ServerError!void {
            return self.runInner() catch |err| self.failWith(err);
        }

        fn runInner(self: *Self) !void {
            if (self.pending) |opts| try self.configure(opts);
            // `zig build openapi` and `openapi-check`: before the banner, the
            // helper routes, any listener or connector.
            {
                const env = self.openapiEnv();
                if (env.out != null or env.check != null) return self.openapiTool(env);
            }
            self.printBanner();
            self.logModes();
            logBuildMode(self.mode.debug_production);
            self.addHelperRoutes();
            if (comptime features.openapi) if (self.extras.openapi_failed) |err| {
                errors.log.err("openapi: the document can't be built: {t}", .{err});
                return self.failStart(errors.toServerError(err));
            };
            // Only with `router.record_conflicts` (the C ABI, test builds): a
            // route that conflicted with another, or that the helper routes
            // collided with.
            if (self.router.conflict != null) return self.failStart(error.RouteConflict);
            self.startConnectors() catch return self.failStart(error.DatabaseUnavailable);
            const rt_io = self.rt.io();
            const Done = union(enum) {
                int: anyerror!void,
                term: anyerror!void,
                stop: anyerror!void,
                served: anyerror!void,
                restart: anyerror!void,
                h3: anyerror!void,
                reload: anyerror!void,
                restart_cmd: anyerror!void,
                net: anyerror!void,
            };
            var done_buf: [9]Done = undefined;
            var sel = std.Io.Select(Done).init(rt_io, &done_buf);
            if (self.signals) {
                try sel.concurrent(.int, waitForSignal, .{.interrupt});
                try sel.concurrent(.term, waitForSignal, .{.terminate});
            }
            try sel.concurrent(.stop, waitStopped, .{ self.stopped, rt_io });
            // The live console: its socket and rings, and what it may ask of
            // this loop (/restart).
            // ---- p3/net ----
            self.attachNetMetrics();
            // ---- end p3/net ----
            self.startConsole();
            defer if (self.console != null) self.stopConsole(false);
            if (self.console != null) {
                if (self.consoleRestartWhy() == null and self.console_resolved.allow_restart and !self.console_resolved.read_only) {
                    try sel.concurrent(.restart_cmd, waitStopped, .{ self.console_restart, rt_io });
                }
            }
            var announce: ?std.Io.Future(void) = if (self.console != null) try rt_io.concurrent(consoleAnnounce, .{self}) else null;
            defer if (announce) |*f| f.cancel(rt_io);
            try sel.concurrent(.served, serve, .{self.server});
            if (comptime features.http3) if (self.h3) |ep| try sel.concurrent(.h3, serveH3, .{ep});
            if (self.net_udp.items.len > 0) try sel.concurrent(.net, serveNet, .{self});
            // Windows has neither SIGUSR2 nor SIGHUP (zio maps Ctrl-C to
            // `.interrupt` and closing the console to `.terminate`): no
            // restart, and certificates reload by `reloadCertificates` only.
            // With `signals` off (an embedding process owns them: the C
            // ABI) none of them is watched.
            const restartable = self.signals and self.process != null and self.held.len > 0;
            if (comptime unix_signals) if (restartable) try sel.concurrent(.restart, waitForSignal, .{.user2});
            // SIGHUP reloads the certificate, where there is one.
            if (comptime unix_signals) if (self.signals and self.certs.len > 0) try sel.concurrent(.reload, reloadOnHangup, .{self});
            // Once serving: systemd hears (`NOTIFY_SOCKET`), and a successor
            // tells the predecessor that started it.
            var notify: ?std.Io.Future(void) = if (self.process) |p|
                try rt_io.concurrent(notifyWhenReady, .{ self.server, rt_io, p })
            else
                null;
            defer if (notify) |*n| n.cancel(rt_io);
            const log = std.log.scoped(.anole);
            const first = while (true) {
                const done = try sel.await();
                // Ends only when it cannot listen for SIGHUP (logged).
                if (done == .reload) continue;
                if (done != .restart and done != .restart_cmd) break done;
                // SIGUSR2 or the console's /restart: start the successor;
                // drain once it serves.
                if (comptime !unix_signals) unreachable;
                if (self.restart()) {
                    if (self.console) |c| c.service.restartFinished(true, self.last_successor_pid);
                    break done;
                }
                if (self.console) |c| c.service.restartFinished(false, 0);
                if (done == .restart) {
                    try sel.concurrent(.restart, waitForSignal, .{.user2});
                } else {
                    self.console_restart.reset();
                    try sel.concurrent(.restart_cmd, waitStopped, .{ self.console_restart, rt_io });
                }
            };
            // The console says goodbye before the drain, and the terminal is
            // back for what the drain logs.
            switch (first) {
                .served, .h3, .net => self.stopConsole(false),
                else => self.stopConsole(true),
            }
            if (first == .restart or first == .restart_cmd) {
                // HTTP/3 cannot drain beside the successor on one UDP
                // socket: its connections close now and it stops reading.
                if (comptime features.http3) if (self.h3) |ep| ep.handOver();
                for (self.net_udp.items) |g| g.handOver();
            } else if (self.process) |p| {
                sd_notify.stopping(p.environ);
            }
            // gRPC health watchers hear of the drain before it starts.
            if (comptime features.grpc) if (self.extras.grpc_health) |h| h.shutdown();
            // Cancels the server's run, which drains, then the watchers.
            sel.cancelDiscard();
            switch (first) {
                .served, .h3, .net => |r| return r,
                .reload => unreachable,
                .int, .term => log.info("signal received ({t}); drained and stopped", .{first}),
                .restart, .restart_cmd => log.info("handed over to the new process; drained and stopped", .{}),
                .stop => {},
            }
        }

        /// Starts the successor and waits for it to serve. False when it
        /// did not, and this process keeps serving.
        fn restart(self: *Self) bool {
            const log = std.log.scoped(.anole);
            const environ = self.process.?.environ;
            sd_notify.reloading(environ);
            const h3_secret: ?*const [32]u8 = if (comptime features.http3)
                (if (self.h3) |ep| &ep.secret else null)
            else
                null;
            const successor = handoff.spawn(self.gpa, self.rt.io(), self.process.?, self.held, h3_secret) catch |err| {
                log.err("restart: could not start the new process: {t}", .{err});
                sd_notify.ready(environ, null);
                return false;
            };
            log.info("restart: started process {d}; waiting for it to serve", .{successor.pid});
            self.last_successor_pid = @intCast(successor.pid);
            if (!successor.waitReady(self.rt.io(), self.restart_timeout)) {
                log.err("restart: process {d} did not report serving; stopped it and carrying on", .{successor.pid});
                successor.abandon();
                sd_notify.ready(environ, null);
                return false;
            }
            return true;
        }

        /// Reloads the certificate on every SIGHUP, telling systemd
        /// (`RELOADING=1`, then `READY=1`) when `NOTIFY_SOCKET` is set. A
        /// failed reload is logged and the old certificate stays.
        fn reloadOnHangup(self: *Self) anyerror!void {
            const log = std.log.scoped(.anole);
            var sig = zio.Signal.init(.hangup) catch |err| {
                log.err("cannot reload certificates on SIGHUP: {t}", .{err});
                return;
            };
            defer sig.deinit();
            while (true) {
                try sig.wait();
                if (self.process) |p| sd_notify.reloading(p.environ);
                if (self.reloadCertificates()) {
                    log.info("SIGHUP: certificates reloaded", .{});
                } else |err| switch (err) {
                    error.Canceled => return err,
                    else => log.err("SIGHUP: certificate reload failed, keeping the current one: {t}", .{err}),
                }
                if (self.process) |p| sd_notify.ready(p.environ, null);
            }
        }

        /// The banner, when a person is looking (docs/server.md): see
        /// `Options.banner`.
        fn printBanner(self: *const Self) void {
            if (comptime builtin.is_test) return;
            const dbg_io = std.Options.debug_io;
            const tty = std.Io.File.stderr().isTty(dbg_io) catch false;
            const Env = struct {
                pub fn get(_: @This(), name: []const u8) ?[]const u8 {
                    return @import("db/url.zig").realEnv(null, name);
                }
            };
            const env: Env = .{};
            if (!banner_mod.show(self.banner, anole_log.currentFormat() == .text, tty, env)) return;
            var info: banner_mod.Info = .{ .version = features.version, .environment = @tagName(self.mode.environment) };
            const listeners = self.server.config.listeners;
            var host_buf: [64]u8 = undefined;
            if (listeners.len > 0) {
                const l = listeners[0];
                info.scheme = if (l.tls != null) "https" else "http";
                info.h1 = l.http1;
                if (l.tls) |t| {
                    for (t.alpn_protocols) |p| if (std.mem.eql(u8, p, "h2")) {
                        info.h2 = true;
                    };
                } else info.h2 = l.http2_prior_knowledge;
                if (comptime features.http3) info.h3 = l.tls != null and self.h3 != null;
                switch (l.address) {
                    .ip => |ip| {
                        info.port = ip.getPort();
                        const local = switch (ip) {
                            .ip4 => |a| a.bytes[0] == 127 or std.mem.eql(u8, &a.bytes, &.{ 0, 0, 0, 0 }),
                            .ip6 => |a| blk: {
                                // :: (every interface) or ::1.
                                for (a.bytes[0..15]) |b| if (b != 0) break :blk false;
                                break :blk a.bytes[15] == 0 or a.bytes[15] == 1;
                            },
                        };
                        if (local) {
                            info.host = "localhost";
                        } else {
                            var w: std.Io.Writer = .fixed(&host_buf);
                            switch (ip) {
                                .ip4 => |a| w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch {},
                                .ip6 => w.print("[{f}]", .{ip}) catch {},
                            }
                            info.host = w.buffered();
                        }
                    },
                    .unix => {},
                }
            }
            var buf: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            banner_mod.write(&w, info, banner_mod.styleFor(terminalColumns(dbg_io), env)) catch return;
            const prev = dbg_io.swapCancelProtection(.blocked);
            defer _ = dbg_io.swapCancelProtection(prev);
            var lock_buf: [64]u8 = undefined;
            const t = std.debug.lockStderr(&lock_buf).terminal();
            defer std.debug.unlockStderr();
            t.writer.writeAll(w.buffered()) catch return;
            t.writer.flush() catch {};
        }

        /// The width of the terminal on stderr, or null when unknown.
        fn terminalColumns(dbg_io: std.Io) ?usize {
            if (comptime builtin.os.tag == .windows) return null;
            var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const result = (dbg_io.operate(.{ .device_io_control = .{
                .file = std.Io.File.stderr(),
                .code = std.posix.T.IOCGWINSZ,
                .arg = &size,
            } }) catch return null).device_io_control;
            if (result < 0 or size.col == 0) return null;
            return size.col;
        }

        /// The startup lines about the environment and deployment
        /// (`modes.writeLines`), one log record each.
        fn logModes(self: *const Self) void {
            var buf: [2048]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            modes.writeLines(self.mode, .{ .used_listen_tls = self.used_listen_tls }, &w) catch return;
            const log = std.log.scoped(.anole);
            var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '!') log.warn("{s}", .{line[1..]}) else log.info("{s}", .{line});
            }
        }

        /// Which build this is; a loud word for ReleaseFast, which has none
        /// of Zig's safety checks (docs/server.md recommends ReleaseSafe).
        fn logBuildMode(quiet_debug: bool) void {
            const log = std.log.scoped(.anole);
            const name = switch (builtin.mode) {
                .debug => "Debug",
                .safe => "ReleaseSafe",
                .fast => "ReleaseFast",
                .small => "ReleaseSmall",
            };
            switch (builtin.mode) {
                .fast, .small => log.warn("built with {s}: Zig's safety checks are off, so a bug that ReleaseSafe would stop at the faulty line can corrupt memory instead; ReleaseSafe is the recommended build for production", .{name}),
                .debug => if (!quiet_debug) log.info("{s} build", .{name}),
                .safe => log.info("{s} build", .{name}),
            }
        }

        fn notifyWhenReady(server: *http.Server(Ctx), rt_io: std.Io, process: std.process.Init.Minimal) void {
            // Only a server that is listening tells the predecessor so;
            // one that failed to start leaves it to time out and carry on.
            server.waitReady(rt_io) catch return;
            // A successor names itself the main process before its
            // predecessor starts to exit.
            const successor = handoff.isSuccessor(process.environ);
            const main_pid: ?i64 = if (comptime handoff.supported) (if (successor) std.c.getpid() else null) else null;
            sd_notify.ready(process.environ, main_pid);
            handoff.notifyReady(process.environ);
        }

        fn waitForSignal(kind: zio.SignalKind) anyerror!void {
            var sig = try zio.Signal.init(kind);
            defer sig.deinit();
            try sig.wait();
        }

        fn waitStopped(event: *std.Io.Event, rt_io: std.Io) anyerror!void {
            try event.wait(rt_io);
        }

        fn serve(server: *http.Server(Ctx)) anyerror!void {
            return server.run();
        }

        // ---- p3/net ----
        /// The raw listeners' Prometheus series, when the app has metrics
        /// (`app.metrics`): one label set per listener.
        fn attachNetMetrics(self: *Self) void {
            const registry = self.extras.metrics orelse return;
            for (self.net_tcp.items, 0..) |t, i| {
                if (t.series != null) continue;
                t.series = net_mod.metrics.TcpSeries.init(registry, self.arena.allocator(), self.tcpName(i)) catch null;
            }
            for (self.net_udp.items) |g| {
                if (g.series != null) continue;
                g.series = net_mod.metrics.UdpSeries.init(registry, self.arena.allocator(), g.name) catch null;
            }
        }

        /// The name of the `i`th raw TCP listener.
        fn tcpName(self: *const Self, i: usize) []const u8 {
            var n: usize = 0;
            for (self.server.config.listeners) |l| if (l.raw != null) {
                if (n == i) return l.name;
                n += 1;
            };
            return "tcp";
        }

        /// Every UDP listener's tasks, until canceled; a listener that fails
        /// to run ends the server with that error.
        fn serveNet(self: *Self) anyerror!void {
            const rt_io = self.rt.io();
            var tasks: std.Io.Group = .init;
            defer tasks.cancel(rt_io);
            for (self.net_udp.items) |g| tasks.concurrent(rt_io, runUdp, .{ self, g }) catch return error.SystemResources;
            tasks.await(rt_io) catch return error.Canceled;
            if (self.net_failed) |err| return err;
        }

        fn runUdp(self: *Self, g: *net_mod.UdpGroup) std.Io.Cancelable!void {
            g.run() catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.log.scoped(.anole).err("udp listener \"{s}\" stopped: {t}", .{ g.name, err });
                    self.net_failed = err;
                },
            };
        }
        // ---- end p3/net ----

        fn serveH3(ep: if (features.http3) *h3.Endpoint(Ctx) else void) anyerror!void {
            if (comptime features.http3) return ep.run();
        }

        /// The HTTP/3 endpoint's address (its real port when 0 was asked
        /// for), or null without one.
        pub fn http3Address(self: *const Self) ?std.Io.net.IpAddress {
            if (comptime !features.http3) return null;
            const ep = self.h3 orelse return null;
            return ep.address();
        }
    };
}

test "anole.Server: one call each to serve HTTP/1.1 and HTTPS, routes and middleware, stop" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{
        .http = .{ .port = 0, .h2c = false },
        .https = if (features.tls == .boringssl) .{ .port = 0, .cert = .dev_self_signed } else null,
        .executors = .exact(2),
    }, {});
    defer app.deinit();
    app.use(http.middleware.RequestId.init(.{}));
    app.get("/users/:id", struct {
        fn handle(req: *http.Request, res: *http.Response) !void {
            try res.print(.text, "user {s} id={d}", .{ req.params.get("id").?, req.id.len });
        }
    }.handle);

    var client_future = try app.io().concurrent(struct {
        fn run(a: *Server(void)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const addr = a.addresses()[0].ip;
            const stream = try addr.connect(io_, .{ .mode = .stream });
            defer stream.close(io_);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            try w.interface.writeAll("GET /users/7 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            var out: [1024]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&out);
            _ = r.interface.streamRemaining(&fw) catch {};
            const resp = fw.buffered();
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expect(std.mem.indexOf(u8, resp, "X-Request-Id: ") != null);
            try std.testing.expect(std.mem.endsWith(u8, resp, "user 7 id=32"));
            if (features.tls == .boringssl) try std.testing.expectEqual(@as(usize, 2), a.addresses().len);
        }
    }.run, .{&app});
    try app.run();
    try client_future.await(app.io());
}

/// The client's certificate as the handler sees it: the DER, or "none".
fn handlePeerCertificate(req: *http.Request, res: *http.Response) !void {
    res.body = req.peerCertificate() orelse "none";
}

test "anole.Server: mutual TLS on HTTP/1.1, HTTP/2 and HTTP/3, and the client certificate in handlers" {
    if (comptime !features.http3 or !features.http2) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pem = try tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    // The self-signed certificate is CA:TRUE: it is the server's identity,
    // the client's, and the CA that verifies both. dusty reads CAs and
    // client certificates from files.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cert.pem", .data = pem.cert });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = pem.key });
    var ca_buf: [160]u8 = undefined;

    var app = try Server(void).init(gpa, .{
        .http = null,
        .https = .{
            .port = 0,
            .cert = .{ .pem = .{ .cert = pem.cert, .key = pem.key } },
            .client_auth = .{ .ca = .{ .file = tmpPath(&ca_buf, &tmp, "cert.pem") } },
        },
        .http3 = .{ .port = 0, .alt_svc = false },
        .executors = .exact(2),
    }, {});
    defer app.deinit();
    app.get("/peer", handlePeerCertificate);

    const Check = struct {
        fn run(a: *Server(void), p: *const tls.Pem, td: *const std.testing.TmpDir) !void {
            defer a.stop();
            const io_ = a.io();
            const alloc = std.testing.allocator;
            var cert_buf: [160]u8 = undefined;
            var key_buf: [160]u8 = undefined;
            try a.waitReady();
            var bundle = try tls_testing.bundleFromPem(alloc, std.Io.Clock.real.now(io_).toSeconds(), p.cert);
            defer bundle.deinit(alloc);
            // The certificate's DER: the bundle holds exactly it.
            const der = bundle.bytes.items;
            const port = a.addresses()[0].ip.getPort();

            // HTTP/1.1, without a certificate and with one.
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/peer", .{port});
            const ca: http.core.Ca = .{ .file = tmpPath(&cert_buf, td, "cert.pem") };
            {
                var anon = http.Client.init(alloc, io_, .{ .tls = .{ .ca = ca } });
                defer anon.deinit();
                if (anon.fetch(url, .{})) |r| {
                    var resp = r;
                    resp.deinit();
                    return error.ServedWithoutClientCertificate;
                } else |_| {}
            }
            {
                var authed = http.Client.init(alloc, io_, .{ .tls = .{
                    .ca = ca,
                    .client_certificate = .fromFiles(tmpPath(&cert_buf, td, "cert.pem"), tmpPath(&key_buf, td, "key.pem")),
                } });
                defer authed.deinit();
                var resp = try authed.fetch(url, .{});
                defer resp.deinit();
                try std.testing.expectEqualSlices(u8, der, (try resp.body()).?);
                // What docs/server.md shows a handler doing with it.
                const cert: std.crypto.Certificate = .{ .buffer = (try resp.body()).?, .index = 0 };
                try std.testing.expectEqualStrings("localhost", (try cert.parse()).commonName());
            }

            // HTTP/2.
            const h2c = @import("anole_h2_client");
            {
                const conn = try h2c.ClientConnection.connect(alloc, io_, .{
                    .host = "localhost",
                    .port = port,
                    .tls = .{ .ca = .{ .pem = p.cert }, .client_certificate = .{ .pem = .{ .cert = p.cert, .key = p.key } } },
                });
                defer conn.close();
                const s = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/peer" },
                    .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
                defer s.release();
                try s.waitHead();
                const body = try s.reader().allocRemaining(alloc, .unlimited);
                defer alloc.free(body);
                try std.testing.expectEqualSlices(u8, der, body);
            }

            // HTTP/3: refused without a certificate (at the handshake, or on
            // the first request, which the server's verdict overtakes)...
            const q = a.http3Address().?;
            if (h3.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .address = q,
                .port = q.getPort(),
                .tls = .{ .ca = .{ .pem = p.cert } },
                .connect_timeout = .fromSeconds(3),
            })) |conn| {
                defer conn.close();
                if (h3Get(conn, alloc)) |body| {
                    alloc.free(body);
                    return error.ServedWithoutClientCertificate;
                } else |_| {}
            } else |_| {}
            // ...and served with one, which the handler sees.
            const conn = try h3.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .address = q,
                .port = q.getPort(),
                .tls = .{ .ca = .{ .pem = p.cert }, .client_certificate = .{ .pem = .{ .cert = p.cert, .key = p.key } } },
            });
            defer conn.close();
            const body = try h3Get(conn, alloc);
            defer alloc.free(body);
            try std.testing.expectEqualSlices(u8, der, body);
        }

        fn h3Get(conn: *h3.ClientConnection, alloc: std.mem.Allocator) ![]u8 {
            const s = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/peer" },
                .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            defer s.release();
            try s.waitHead();
            if (s.status != 200) return error.UnexpectedStatus;
            return s.reader().allocRemaining(alloc, .unlimited);
        }
    };
    var client_future = try app.io().concurrent(Check.run, .{ &app, &pem, &tmp });
    try app.run();
    try client_future.await(app.io());
}

test "anole.Server: with a blocking pool, one executor serves other requests while a job runs" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{
        .http = .{ .port = 0, .h2c = false },
        .executors = .exact(1),
        .blocking = .{ .threads = 2 },
    }, {});
    defer app.deinit();
    const Routes = struct {
        /// 600 ms of CPU, as a slow password hash would take.
        fn spin(io_: std.Io) u32 {
            const start = std.Io.Clock.awake.now(io_);
            var n: u32 = 0;
            while (start.durationTo(std.Io.Clock.awake.now(io_)).toMilliseconds() < 600) n +%= 1;
            return n;
        }
        fn slow(req: *http.Request, res: *http.Response) !void {
            _ = try blocking.run(req.io, spin, .{req.io});
            res.body = "slow";
        }
        fn fast(_: *http.Request, res: *http.Response) !void {
            res.body = "fast";
        }
        fn get(io_: std.Io, addr: std.Io.net.IpAddress, path: []const u8) !i64 {
            const start = std.Io.Clock.awake.now(io_);
            const stream = try addr.connect(io_, .{ .mode = .stream });
            defer stream.close(io_);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            var out: [1024]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&out);
            _ = r.interface.streamRemaining(&fw) catch {};
            try std.testing.expect(std.mem.endsWith(u8, fw.buffered(), path[1..]));
            return start.durationTo(std.Io.Clock.awake.now(io_)).toMilliseconds();
        }
        fn client(a: *Server(void)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const addr = a.addresses()[0].ip;
            var slow_req = try io_.concurrent(get, .{ io_, addr, "/slow" });
            defer _ = slow_req.cancel(io_) catch {};
            try io_.sleep(.fromMilliseconds(100), .awake);
            // The slow job is running; the only executor still answers.
            try std.testing.expect(try get(io_, addr, "/fast") < 300);
            try std.testing.expect(try slow_req.await(io_) >= 500);
        }
    };
    app.get("/slow", Routes.slow);
    app.get("/fast", Routes.fast);
    var client_future = try app.io().concurrent(Routes.client, .{&app});
    try app.run();
    try client_future.await(app.io());
}

/// The path of `name` in a test's temporary directory, relative to the
/// working directory (TLS settings take paths, not directory handles).
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }) catch unreachable;
}

/// Certificate reload checks: GETs over each protocol, trusting one CA.
const ReloadCheck = struct {
    const alloc = std.testing.allocator;
    const h2c = @import("anole_h2_client");

    fn request(conn: anytype) !void {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        if (s.status != 200) return error.UnexpectedStatus;
        const body = try s.reader().allocRemaining(alloc, .unlimited);
        defer alloc.free(body);
        try std.testing.expectEqualStrings("reloaded", body);
    }

    /// HTTP/1.1, trusting only the CA in `tmp/ca_name`.
    fn h1(io_: std.Io, port: u16, tmp: *const std.testing.TmpDir, ca_name: []const u8) !void {
        var path_buf: [160]u8 = undefined;
        var client = http.Client.init(alloc, io_, .{ .tls = .{ .ca = .{ .file = tmpPath(&path_buf, tmp, ca_name) } } });
        defer client.deinit();
        var url_buf: [64]u8 = undefined;
        var resp = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{port}), .{});
        defer resp.deinit();
        try std.testing.expectEqualStrings("reloaded", (try resp.body()).?);
    }

    /// `ca`: the one CA certificate to trust, PEM.
    fn h2(io_: std.Io, port: u16, ca: []const u8) !*h2c.ClientConnection {
        return h2c.ClientConnection.connect(alloc, io_, .{ .host = "localhost", .port = port, .tls = .{ .ca = .{ .pem = ca } } });
    }

    fn h3c(io_: std.Io, q: std.Io.net.IpAddress, ca: []const u8) !*h3.ClientConnection {
        return h3.ClientConnection.connect(alloc, io_, .{
            .host = "localhost",
            .address = q,
            .port = q.getPort(),
            .tls = .{ .ca = .{ .pem = ca } },
            .connect_timeout = .fromSeconds(3),
        });
    }

    /// New connections over all three protocols verify against `ca` alone.
    fn serves(a: *Server(void), tmp: *const std.testing.TmpDir, ca_name: []const u8, ca: []const u8) !void {
        const io_ = a.io();
        const port = a.addresses()[0].ip.getPort();
        try h1(io_, port, tmp, ca_name);
        const c2 = try h2(io_, port, ca);
        defer c2.close();
        try request(c2);
        const c3 = try h3c(io_, a.http3Address().?, ca);
        defer c3.close();
        try request(c3);
    }

    fn handle(_: *http.Request, res: *http.Response) !void {
        res.body = "reloaded";
    }
};

test "anole.Server: reloadCertificates, SIGHUP and setCertificate switch the certificate on HTTP/1.1, HTTP/2 and HTTP/3; open connections keep theirs" {
    if (comptime features.tls != .boringssl or !features.http2 or !features.http3) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // A to start with, B by reloadCertificates, C by SIGHUP (both from the
    // files), D by setCertificate (PEM in memory). Each self-signed: a
    // client trusting one rejects the others.
    var pems: [4]tls.Pem = undefined;
    var made: usize = 0;
    defer for (pems[0..made]) |*p| p.deinit(gpa);
    while (made < pems.len) : (made += 1) pems[made] = try tls.selfSigned(gpa, .{});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.testing.io;
    for (pems, 0..) |p, i| {
        var name_buf: [16]u8 = undefined;
        try tmp.dir.writeFile(tio, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "ca{d}.pem", .{i}), .data = p.cert });
    }
    try tmp.dir.writeFile(tio, .{ .sub_path = "cert.pem", .data = pems[0].cert });
    try tmp.dir.writeFile(tio, .{ .sub_path = "key.pem", .data = pems[0].key });
    // `.files` paths are relative to the working directory, where
    // std.testing.tmpDir makes its directories.
    const cert_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
    defer gpa.free(cert_path);
    const key_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
    defer gpa.free(key_path);

    var app = try Server(void).init(gpa, .{
        .https = .{ .port = 0, .cert = .{ .files = .{ .cert_path = cert_path, .key_path = key_path } } },
        .http3 = .{ .port = 0, .alt_svc = false },
        .executors = .exact(2),
    }, {});
    defer app.deinit();
    // HTTPS only: `http` defaults to none beside `https`.
    try std.testing.expectEqual(@as(usize, 1), app.server.config.listeners.len);
    app.get("/", ReloadCheck.handle);

    const Run = struct {
        fn run(a: *Server(void), p: *const [4]tls.Pem, td: *const std.testing.TmpDir) !void {
            const dir = td.dir;
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();

            try ReloadCheck.serves(a, td, "ca0.pem", p[0].cert);
            // Connections that outlive the reloads.
            const old2 = try ReloadCheck.h2(io_, port, p[0].cert);
            defer old2.close();
            try ReloadCheck.request(old2);
            const old3 = try ReloadCheck.h3c(io_, a.http3Address().?, p[0].cert);
            defer old3.close();
            try ReloadCheck.request(old3);

            // reloadCertificates reads the files again.
            try dir.writeFile(io_, .{ .sub_path = "cert.pem", .data = p[1].cert });
            try dir.writeFile(io_, .{ .sub_path = "key.pem", .data = p[1].key });
            try a.reloadCertificates();
            try ReloadCheck.serves(a, td, "ca1.pem", p[1].cert);
            try std.testing.expect(std.meta.isError(ReloadCheck.h1(io_, port, td, "ca0.pem")));
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);

            // A key that does not go with the certificate: refused, and
            // nothing changes.
            try dir.writeFile(io_, .{ .sub_path = "key.pem", .data = p[2].key });
            try std.testing.expect(std.meta.isError(a.reloadCertificates()));
            try ReloadCheck.serves(a, td, "ca1.pem", p[1].cert);

            // SIGHUP, once `run` listens for it.
            try dir.writeFile(io_, .{ .sub_path = "cert.pem", .data = p[2].cert });
            if (comptime unix_signals) {
                var armed = false;
                for (0..500) |_| {
                    var current: std.posix.Sigaction = undefined;
                    std.posix.sigaction(.HUP, null, &current);
                    if (current.handler.handler != std.posix.SIG.DFL) {
                        armed = true;
                        break;
                    }
                    try io_.sleep(.fromMilliseconds(10), .awake);
                }
                try std.testing.expect(armed);
                _ = std.c.kill(std.c.getpid(), std.c.SIG.HUP);
            } else {
                // No SIGHUP on Windows: the call it makes.
                try a.reloadCertificates();
            }
            const switched = for (0..300) |_| {
                if (ReloadCheck.h1(io_, port, td, "ca2.pem")) |_| break true else |_| {}
                try io_.sleep(.fromMilliseconds(10), .awake);
            } else false;
            try std.testing.expect(switched);
            try ReloadCheck.serves(a, td, "ca2.pem", p[2].cert);

            // setCertificate: PEM in memory.
            try a.setCertificate(.{ .pem = .{ .cert = p[3].cert, .key = p[3].key } });
            try ReloadCheck.serves(a, td, "ca3.pem", p[3].cert);
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);
        }
    };
    var client_future = try app.io().concurrent(Run.run, .{ &app, &pems, &tmp });
    try app.run();
    try client_future.await(app.io());
}

test "anole.Server: app.webtransport after init reaches every HTTP/3 endpoint, which share one 0-RTT context" {
    if (comptime !features.http3) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pem = try tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    var app = try Server(void).init(gpa, .{
        .http = null,
        .https = .{ .port = 0, .cert = .{ .pem = .{ .cert = pem.cert, .key = pem.key } } },
        // One endpoint per executor on Linux; one elsewhere.
        .http3 = .{ .port = 0, .alt_svc = false, .early_data = true },
        .executors = .exact(4),
    }, {});
    defer app.deinit();
    const S = struct {
        fn session(_: *webtransport_mod.Session) !void {}
    };
    app.webtransport("/wt", S.session);
    const endpoints = app.h3.?.endpoints();
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(usize, 4), endpoints.len);
    const h3_server = @import("h3/server.zig");
    const early_context_max = h3_server.early_context_max;
    var first_buf: [early_context_max]u8 = undefined;
    const first = try h3_server.earlyDataContextOf(&endpoints[0].options, &first_buf);
    for (endpoints) |e| {
        try std.testing.expect(e.options.webtransport);
        var buf: [early_context_max]u8 = undefined;
        try std.testing.expectEqualSlices(u8, first, try h3_server.earlyDataContextOf(&e.options, &buf));
    }
}

test "anole.Server: a second server on the same thread is refused, and one after the first is freed is fine" {
    const gpa = std.testing.allocator;
    var first = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {});
    try std.testing.expectError(error.ServerAlreadyOnThread, Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {}));
    first.deinit();
    var second = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {});
    second.deinit();
}

test "anole.Server: http listens on 127.0.0.1:8080 when nothing is set, from run on" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{ .executors = .exact(1) }, {});
    defer app.deinit();
    // Left for `listen`, `listenTls` or `run`.
    try std.testing.expectEqual(@as(usize, 0), app.server.config.listeners.len);
    try app.configure(app.pending.?);
    const listeners = app.server.config.listeners;
    try std.testing.expectEqual(@as(usize, 1), listeners.len);
    try std.testing.expectEqual(@as(u16, 8080), listeners[0].address.ip.getPort());
    try std.testing.expect(listeners[0].tls == null);
}

/// Counts what reaches it and its `deinit`s, for the ownership test.
const CountingMiddleware = struct {
    hits: *std.atomic.Value(u32),
    deinits: *u32,

    pub fn execute(self: *const CountingMiddleware, _: *http.Request, _: *http.Response, next: anytype) !void {
        _ = self.hits.fetchAdd(1, .monotonic);
        return next.call();
    }

    pub fn deinit(self: *CountingMiddleware) void {
        self.deinits.* += 1;
    }
};

test "Server: anole.noWait(f) marks a function middleware; a noWait route behind it registers" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{ .http = .{ .port = 0, .h2c = true }, .executors = .exact(1) }, {});
    defer app.deinit();
    const Fns = struct {
        fn tag(_: *http.Request, res: *http.Response, next: handlers.Next) !void {
            try res.header("X-Tag", "1");
            return next.call();
        }
        fn quick(_: *http.Request, res: *http.Response) !void {
            res.body = "quick";
        }
    };
    const plain = app.middleware(Fns.tag);
    try std.testing.expect(!plain.no_wait);
    const marked = app.middleware(handlers.noWait(Fns.tag));
    try std.testing.expect(marked.no_wait);
    app.use(handlers.noWait(Fns.tag));
    // Would panic at registration if the middleware were not marked.
    app.get("/quick", handlers.noWait(Fns.quick));
}

test "anole.Server: use, group and middleware copy what they are given, and deinit it with the server; static, embedded and query" {
    const gpa = std.testing.allocator;
    var hits: std.atomic.Value(u32) = .init(0);
    var deinits: u32 = 0;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.txt", .data = "static page" });
    {
        var app = try Server(void).init(gpa, .{ .http = .{ .port = 0, .h2c = false }, .executors = .exact(2) }, {});
        defer app.deinit();
        const counting: CountingMiddleware = .{ .hits = &hits, .deinits = &deinits };
        app.use(counting);
        // One handle in two groups: one copy, one deinit.
        const shared = app.middleware(counting);
        const api = app.group("/api", .{ shared, counting });
        api.get("/a", struct {
            fn handle(_: *http.Request, res: *http.Response) !void {
                res.body = "a";
            }
        }.handle);
        api.group("/v2", .{shared}).query("/q", struct {
            fn handle(req: *http.Request, res: *http.Response) !void {
                res.body = (try req.body()) orelse "";
            }
        }.handle);
        app.static("/files", tmp.dir, .{});
        app.embedded("/embedded.txt", "embedded file", .{});

        const Client = struct {
            fn get(io_: std.Io, port: u16, head: []const u8) ![]const u8 {
                const stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io_, .{ .mode = .stream });
                defer stream.close(io_);
                var wbuf: [512]u8 = undefined;
                var w = stream.writer(io_, &wbuf);
                try w.interface.writeAll(head);
                try w.interface.flush();
                var rbuf: [2048]u8 = undefined;
                var r = stream.reader(io_, &rbuf);
                var out: [2048]u8 = undefined;
                var fw: std.Io.Writer = .fixed(&out);
                _ = r.interface.streamRemaining(&fw) catch {};
                const resp = fw.buffered();
                if (!std.mem.startsWith(u8, resp, "HTTP/1.1 200")) return error.UnexpectedStatus;
                const body_at = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoBody;
                return std.testing.allocator.dupe(u8, resp[body_at + 4 ..]);
            }

            fn expectBody(io_: std.Io, port: u16, head: []const u8, want: []const u8) !void {
                const body = try get(io_, port, head);
                defer std.testing.allocator.free(body);
                try std.testing.expectEqualStrings(want, body);
            }

            fn run(a: *Server(void)) !void {
                defer a.stop();
                const io_ = a.io();
                try a.waitReady();
                const port = a.addresses()[0].ip.getPort();
                try expectBody(io_, port, "GET /api/a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "a");
                try expectBody(io_, port, "QUERY /api/v2/q HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: 5\r\n\r\nq=abc", "q=abc");
                try expectBody(io_, port, "GET /files/page.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "static page");
                try expectBody(io_, port, "GET /embedded.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "embedded file");
            }
        };
        var client_future = try app.io().concurrent(Client.run, .{&app});
        try app.run();
        try client_future.await(app.io());
        // use: all 4 requests; /api/a: shared and the group's copy;
        // /api/v2/q: those two, then shared again (the nested group's).
        try std.testing.expectEqual(@as(u32, 4 + 2 + 3), hits.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), deinits);
    }
    // The `use` copy, `shared`, and the copy in the "/api" group.
    try std.testing.expectEqual(@as(u32, 3), deinits);
}

/// Raw HTTP/1.1 over one connection, for the listener tests: the whole
/// answer (up to 4 KiB), empty when the server closes without one.
const RawGet = struct {
    fn over(io_: std.Io, stream: std.Io.net.Stream, path: []const u8, out: []u8) ![]const u8 {
        defer stream.close(io_);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(io_, &wbuf);
        try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
        try w.interface.flush();
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(io_, &rbuf);
        var fw: std.Io.Writer = .fixed(out);
        _ = r.interface.streamRemaining(&fw) catch {};
        return fw.buffered();
    }

    fn ip(io_: std.Io, address: std.Io.net.IpAddress, path: []const u8, out: []u8) ![]const u8 {
        return over(io_, try address.connect(io_, .{ .mode = .stream }), path, out);
    }
};

fn handleListenerName(req: *http.Request, res: *http.Response) !void {
    try res.print(.text, "on {s}", .{req.listener.name});
}

test "anole.Server: several listeners: h1 + h2c, TLS h1 only, h2c only, TLS h2 + h3 with Alt-Svc, a unix socket, TLS h2 only, onlyOn" {
    if (comptime features.tls != .boringssl or !features.http2 or !features.http3) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pem = try tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    const cert: Options.Cert = .fromPem(pem.cert, pem.key);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative: a unix socket path has room for about 104 bytes.
    const sock_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/s.sock", .{tmp.sub_path});
    defer gpa.free(sock_path);

    var app = try Server(void).init(gpa, .{
        .listeners = &.{
            .{ .name = "plain", .port = 0 },
            .{ .name = "h1tls", .port = 0, .tls = .{ .cert = cert }, .http2 = false },
            .{ .name = "h2c", .port = 0, .http1 = false },
            .{ .name = "tls", .port = 0, .tls = .{ .cert = cert }, .http3 = true },
            .{ .name = "admin", .port = 0 },
            .{ .unix = sock_path },
            .{ .name = "h2tls", .port = 0, .tls = .{ .cert = cert }, .http1 = false },
        },
        .executors = .exact(2),
    }, {});
    defer app.deinit();
    app.get("/", handleListenerName);
    app.group("/admin", .{onlyOn("admin")}).get("/stats", handleListenerName);

    const Check = struct {
        const h2c = @import("anole_h2_client");
        const alloc = std.testing.allocator;

        fn h2Get(conn: *h2c.ClientConnection, path: []const u8) ![]u8 {
            const s = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = path },
                .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            defer s.release();
            try s.waitHead();
            if (s.status != 200) return error.UnexpectedStatus;
            return s.reader().allocRemaining(alloc, .unlimited);
        }

        fn expectH2(conn: *h2c.ClientConnection, want: []const u8) !void {
            defer conn.close();
            const body = try h2Get(conn, "/");
            defer alloc.free(body);
            try std.testing.expectEqualStrings(want, body);
        }

        fn run(a: *Server(void), p: *const tls.Pem, path: []const u8) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const addrs = a.addresses();
            try std.testing.expectEqual(@as(usize, 7), addrs.len);
            const plain = addrs[0].ip;
            const h1tls = addrs[1].ip.getPort();
            const h2c_only = addrs[2].ip;
            const tls_port = addrs[3].ip.getPort();
            const admin = addrs[4].ip;
            var out: [4096]u8 = undefined;

            // HTTP/1.1 and h2c on one port; no Alt-Svc on cleartext.
            var resp = try RawGet.ip(io_, plain, "/", &out);
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expect(std.mem.endsWith(u8, resp, "on plain"));
            try std.testing.expect(std.mem.indexOf(u8, resp, "Alt-Svc") == null);
            try expectH2(try h2c.ClientConnection.connect(alloc, io_, .{ .host = "127.0.0.1", .port = plain.getPort() }), "on plain");

            // h2c only: HTTP/1.1 gets the connection closed, unanswered.
            resp = try RawGet.ip(io_, h2c_only, "/", &out);
            try std.testing.expectEqual(@as(usize, 0), resp.len);
            try expectH2(try h2c.ClientConnection.connect(alloc, io_, .{ .host = "127.0.0.1", .port = h2c_only.getPort() }), "on h2c");

            // TLS, HTTP/1.1 only: a client that offers h2 alone does not
            // get it; one that offers both gets HTTP/1.1. No Alt-Svc.
            const ca: http.core.Ca = .{ .pem = p.cert };
            try std.testing.expect(std.meta.isError(h2c.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .port = h1tls,
                .tls = .{ .ca = .{ .pem = p.cert } },
            })));
            var client = http.Client.init(alloc, io_, .{ .tls = .{ .ca = ca } });
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            {
                var r = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{h1tls}), .{});
                defer r.deinit();
                try std.testing.expectEqualStrings("on h1tls", (try r.body()).?);
                try std.testing.expect(r.headers().get("Alt-Svc") == null);
            }

            // TLS with HTTP/2 and HTTP/3, advertised on this listener.
            const q = a.http3Address().?;
            var alt_buf: [64]u8 = undefined;
            const alt = try std.fmt.bufPrint(&alt_buf, "h3=\":{d}\"; ma=86400", .{q.getPort()});
            {
                var r = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{tls_port}), .{});
                defer r.deinit();
                try std.testing.expectEqualStrings("on tls", (try r.body()).?);
                try std.testing.expectEqualStrings(alt, r.headers().get("Alt-Svc").?);
            }
            try expectH2(try h2c.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .port = tls_port,
                .tls = .{ .ca = .{ .pem = p.cert } },
            }), "on tls");
            {
                const conn = try h3.ClientConnection.connect(alloc, io_, .{
                    .host = "localhost",
                    .address = q,
                    .port = q.getPort(),
                    .tls = .{ .ca = .{ .pem = p.cert } },
                });
                defer conn.close();
                const s = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/" },
                    .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
                defer s.release();
                try s.waitHead();
                const body = try s.reader().allocRemaining(alloc, .unlimited);
                defer alloc.free(body);
                // HTTP/3 requests report the TLS listener they serve.
                try std.testing.expectEqualStrings("on tls", body);
            }

            // onlyOn: /admin on its listener alone.
            resp = try RawGet.ip(io_, admin, "/admin/stats", &out);
            try std.testing.expect(std.mem.endsWith(u8, resp, "on admin"));
            resp = try RawGet.ip(io_, plain, "/admin/stats", &out);
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 "));

            // The unix socket, named after its path.
            const unix = try std.Io.net.UnixAddress.init(path);
            resp = try RawGet.over(io_, try unix.connect(io_), "/", &out);
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
            var name_buf: [128]u8 = undefined;
            try std.testing.expect(std.mem.endsWith(u8, resp, try std.fmt.bufPrint(&name_buf, "on unix-{s}", .{path})));

            // TLS, HTTP/2 only: a client that offers HTTP/1.1 alone is not
            // served; the HTTP client offers h2 by default and is.
            const h2tls = addrs[6].ip.getPort();
            {
                var h1_only = http.Client.init(alloc, io_, .{ .tls = .{ .ca = ca }, .http2 = false });
                defer h1_only.deinit();
                try std.testing.expect(std.meta.isError(h1_only.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{h2tls}), .{})));
                var r = try client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{h2tls}), .{});
                defer r.deinit();
                try std.testing.expectEqualStrings("on h2tls", (try r.body()).?);
            }
            try expectH2(try h2c.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .port = h2tls,
                .tls = .{ .ca = .{ .pem = p.cert } },
            }), "on h2tls");
        }
    };
    var client_future = try app.io().concurrent(Check.run, .{ &app, &pem, sock_path });
    try app.run();
    try client_future.await(app.io());
    // Every TLS listener named the same certificate: one copy.
    try std.testing.expectEqual(@as(usize, 1), app.certs.len);
    try std.testing.expectEqual(@as(usize, 3), app.certs[0].listeners.items.len);
}

test "anole.Server: listeners that cannot be set up are refused, with what is wrong" {
    const S = Server(void);
    const Case = struct { opts: Options, err: anyerror };
    const cert: Options.Cert = .dev_self_signed;
    const cases = [_]Case{
        .{ .opts = .{ .listeners = &.{ .{ .name = "a" }, .{ .name = "a" } } }, .err = error.DuplicateListenerName },
        // `http` is "http".
        .{ .opts = .{ .http = .{}, .listeners = &.{.{ .name = "http" }} }, .err = error.DuplicateListenerName },
        .{ .opts = .{ .listeners = &.{.{ .name = "a:b" }} }, .err = error.InvalidListenerName },
        .{ .opts = .{ .listeners = &.{.{ .http1 = false, .http2 = false }} }, .err = error.NoProtocols },
        .{ .opts = .{ .listeners = &.{.{ .http3 = true }} }, .err = if (features.http3) error.Http3NeedsTls else error.Http3NotBuilt },
        .{ .opts = .{ .listeners = &.{
            .{ .port = 1, .tls = .{ .cert = cert }, .http3 = true },
            .{ .port = 2, .tls = .{ .cert = cert }, .http3 = true },
        } }, .err = if (features.http3) error.SeveralHttp3Listeners else error.Http3NotBuilt },
        .{ .opts = .{ .http3 = .{}, .listeners = &.{.{ .tls = .{ .cert = cert } }} }, .err = if (features.http3) error.Http3NeedsHttps else error.Http3NotBuilt },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |c| {
        const m = try testMode(arena.allocator(), c.opts);
        const specs = try S.listenerSpecs(arena.allocator(), c.opts, m);
        var why_buf: [512]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        try std.testing.expectError(c.err, S.checkSpecs(specs, c.opts, m, &why));
        try std.testing.expect(why.buffered().len > 0);
    }
    // The names made up for listeners without one, unique on port 0 too.
    const names_opts: Options = .{
        .http = .{},
        .listeners = &.{ .{ .port = 0 }, .{ .port = 0 }, .{ .port = 9443, .tls = .{ .cert = cert } }, .{ .unix = "/run/app.sock" } },
    };
    const specs = try S.listenerSpecs(arena.allocator(), names_opts, try testMode(arena.allocator(), names_opts));
    var names: [5][]const u8 = undefined;
    for (specs, &names) |spec, *n| n.* = spec.name;
    for ([_][]const u8{ "http", "http-0", "http-0-2", "https-9443", "unix-/run/app.sock" }, names) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "anole.Server: the open-file limit is raised, and max_connections follows it unless set" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const before = try std.posix.getrlimit(.NOFILE);
    defer std.posix.setrlimit(.NOFILE, before) catch {};
    var low = before;
    low.cur = @min(before.max, 512);
    try std.posix.setrlimit(.NOFILE, low);

    {
        // Two listeners, one socket each (one per executor on Linux).
        var app = try App.init(gpa, .{
            .listeners = &.{ .{ .port = 0 }, .{ .port = 0 } },
            .executors = .exact(2),
        });
        defer app.deinit();
        const soft = http.fd_limit.softLimit().?;
        if (before.max > 512) try std.testing.expect(soft > 512);
        const Run = struct {
            fn run(a: *App, limit: u64) !void {
                defer a.stop();
                try a.waitReady();
                const sockets: usize = if (builtin.os.tag == .linux) 4 else 2;
                try std.testing.expectEqual(http.fd_limit.maxConnections(limit, 2, sockets), a.server.config.max_connections.?);
            }
        };
        var f = try app.io().concurrent(Run.run, .{ &app, soft });
        try app.run();
        try f.await(app.io());
    }

    // Set: kept as it is; and with `raise_fd_limit` off, the limit is left
    // alone.
    try std.posix.setrlimit(.NOFILE, low);
    var capped = try App.init(gpa, .{
        .listeners = &.{.{ .port = 0 }},
        .executors = .exact(1),
        .raise_fd_limit = false,
        .limits = .{ .max_connections = 77 },
    });
    defer capped.deinit();
    try std.testing.expectEqual(@as(u64, @intCast(low.cur)), http.fd_limit.softLimit().?);
    const Capped = struct {
        fn run(a: *App) !void {
            defer a.stop();
            try a.waitReady();
            try std.testing.expectEqual(@as(?u32, 77), a.server.config.max_connections);
        }
    };
    var g = try capped.io().concurrent(Capped.run, .{&capped});
    try capped.run();
    try g.await(capped.io());
}

/// The modes of a test: production, standalone unless `opts` says otherwise.
fn testMode(a: std.mem.Allocator, opts: Options) !*const modes.Resolved {
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const m = try a.create(modes.Resolved);
    m.* = try modes.resolve(a, &opts, .production, .tests, null, .process, &why);
    return m;
}

fn testCoreConfig(opts: Options) http.ServerConfig {
    return coreConfig(opts, testMode(std.heap.page_allocator, opts) catch unreachable);
}

test "options: coreConfig maps every group" {
    const cfg = testCoreConfig(.{
        .timeouts = .{
            .request = .fromSeconds(61),
            .read_header = .fromSeconds(7),
            .write = .fromSeconds(13),
            .keepalive = .fromSeconds(91),
            .idle_park = .fromMilliseconds(250),
            .shutdown = .fromSeconds(17),
        },
        .limits = .{
            .body_max = 3 << 20,
            .max_head_size = 8192,
            .max_header_count = 33,
            .max_param_count = 9,
            .max_query_count = 34,
            .max_form_count = 35,
            .max_multiform_count = 36,
            .max_connections = 77,
            .max_requests_per_connection = 5,
            .ws_max_message = 2 << 20,
        },
        .proxy = .{ .trusted_hops = 2, .trust_forwarded_proto = false, .trust_forwarded_host = true },
        .request = .{ .require_host = false, .decompress = false, .keep_buffers = true },
        .response = .{ .write_buffer_size = 4096, .date = false, .default_content_type = .json, .max_header_count = 70, .brotli_quality = 7 },
        .http2 = .{ .max_concurrent_streams = 9, .stream_window = 1000 },
        .errors = .json,
    });
    try std.testing.expectEqual(Duration.fromSeconds(61), cfg.timeout.request.?);
    try std.testing.expectEqual(Duration.fromSeconds(7), cfg.timeout.read_header.?);
    try std.testing.expectEqual(Duration.fromSeconds(13), cfg.timeout.write.?);
    try std.testing.expectEqual(Duration.fromSeconds(91), cfg.timeout.keepalive.?);
    try std.testing.expectEqual(Duration.fromMilliseconds(250), cfg.timeout.idle_park.?);
    try std.testing.expectEqual(Duration.fromSeconds(17), cfg.timeout.shutdown.?);
    try std.testing.expectEqual(@as(?usize, 5), cfg.timeout.request_count);
    try std.testing.expectEqual(@as(usize, 3 << 20), cfg.request.max_body_size);
    try std.testing.expectEqual(@as(?usize, 3 << 20), cfg.request.max_content_length);
    try std.testing.expectEqual(@as(usize, 8192), cfg.request.buffer_size);
    try std.testing.expectEqual(@as(usize, 33), cfg.request.max_header_count);
    try std.testing.expectEqual(@as(usize, 9), cfg.request.max_param_count);
    try std.testing.expectEqual(@as(usize, 34), cfg.request.max_query_count);
    try std.testing.expectEqual(@as(usize, 35), cfg.request.max_form_count);
    try std.testing.expectEqual(@as(usize, 36), cfg.request.max_multiform_count);
    try std.testing.expectEqual(@as(usize, 2 << 20), cfg.request.ws_max_message);
    try std.testing.expect(!cfg.request.require_host);
    try std.testing.expect(!cfg.request.decompress);
    try std.testing.expect(cfg.request.keep_buffers_between_requests);
    try std.testing.expectEqual(@as(?u32, 77), cfg.max_connections);
    try std.testing.expectEqual(@as(usize, 2), cfg.trusted_proxy_hops);
    try std.testing.expect(!cfg.trust_forwarded_proto);
    try std.testing.expect(cfg.trust_forwarded_host);
    try std.testing.expectEqual(@as(usize, 4096), cfg.response.write_buffer_size);
    try std.testing.expect(!cfg.response.date);
    try std.testing.expectEqual(@as(?http.ContentType, .json), cfg.response.default_content_type);
    try std.testing.expectEqual(@as(usize, 70), cfg.response.max_header_count);
    try std.testing.expectEqual(@as(u4, 7), cfg.response.brotli_quality);
    try std.testing.expectEqual(@as(u32, 9), cfg.http2.max_concurrent_streams);
    try std.testing.expectEqual(http.ErrorFormat.json, cfg.errors);
    try std.testing.expectEqual(@as(usize, 0), cfg.listeners.len);
}

test "options: limits.max_connections 0 follows the open-file limit" {
    try std.testing.expectEqual(@as(?u32, http.ServerConfig.max_connections_from_fd_limit), testCoreConfig(.{}).max_connections);
    try std.testing.expectEqual(@as(?u32, 5), testCoreConfig(.{ .limits = .{ .max_connections = 5 } }).max_connections);
}

test "options: shutdown drains for 10 s by default" {
    try std.testing.expectEqual(Duration.fromSeconds(10), testCoreConfig(.{}).timeout.shutdown.?);
}

test "options: http2 with one field set keeps 250 streams" {
    try std.testing.expectEqual(@as(u32, 250), testCoreConfig(.{ .http2 = .{ .stream_window = 128 * 1024 } }).http2.max_concurrent_streams);
    try std.testing.expectEqual(@as(u32, 250), testCoreConfig(.{}).http2.max_concurrent_streams);
}

test "options: no struct-typed default is a partial literal" {
    const check = struct {
        fn walk(comptime T: type) void {
            comptime {
                const info = @typeInfo(T).@"struct";
                for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                    const S = switch (@typeInfo(FT)) {
                        .@"struct" => FT,
                        .optional => |o| if (@typeInfo(o.child) == .@"struct") o.child else continue,
                        else => continue,
                    };
                    // Types holding what cannot be built from `.{}`, or that are not ours.
                    if (S == Duration or S == std.process.Init.Minimal) continue;
                    if (attrs.defaultValue(FT)) |dv| {
                        if (@typeInfo(FT) == .optional) continue;
                        // A default that is the type's own default.
                        if (@hasDecl(S, "__no_default")) continue;
                        const plain = canDefault(S);
                        if (plain) |p| if (!std.meta.eql(dv, p)) @compileError("ServerOptions." ++ name ++ " defaults to a partial literal: put the default in " ++ @typeName(S));
                    }
                    if (@hasDecl(S, "default_walk_skip")) continue;
                    if (ownStruct(S)) walk(S);
                }
            }
        }
        /// `S{}` when every field has a default.
        fn canDefault(comptime S: type) ?S {
            const info = @typeInfo(S).@"struct";
            for (info.field_attrs, info.field_types) |a, FT| if (a.default_value_ptr == null and @typeInfo(FT) != .optional) return null;
            return S{};
        }
        /// Only the option structs of this file and the core's config.
        fn ownStruct(comptime S: type) bool {
            const name = @typeName(S);
            return std.mem.startsWith(u8, name, "server.Options") or std.mem.startsWith(u8, name, "config.ServerConfig");
        }
    };
    check.walk(Options);
}

test "run: a port in use is error.AddressInUse and names its listener" {
    const gpa = std.testing.allocator;
    const tio = std.testing.io;
    var taken = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(tio, .{ .reuse_address = false });
    defer taken.deinit(tio);
    var app = try App.init(gpa, .{
        .http = .{ .address = "127.0.0.1", .port = taken.socket.address.getPort() },
        .executors = .exact(1),
    });
    defer app.deinit();
    try std.testing.expectError(error.AddressInUse, app.run());
    try std.testing.expectEqualStrings("http", app.failedListener().?);
    try std.testing.expectError(error.AddressInUse, app.waitReady());
}

test "setCertificate: a key that does not match is error.KeyMismatch, from either reload" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var a = try tls.selfSigned(gpa, .{});
    defer a.deinit(gpa);
    var b = try tls.selfSigned(gpa, .{});
    defer b.deinit(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cert.pem", .data = a.cert });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = a.key });
    var cert_buf: [160]u8 = undefined;
    var key_buf: [160]u8 = undefined;
    var app = try App.init(gpa, .{
        .https = .{ .port = 0, .cert = .fromFiles(tmpPath(&cert_buf, &tmp, "cert.pem"), tmpPath(&key_buf, &tmp, "key.pem")) },
        .http3 = null,
        .listen_tls_http3 = false,
        .executors = .exact(1),
    });
    defer app.deinit();
    const Run = struct {
        fn run(s: *App, other_key: []const u8, mixed_cert: []const u8, td: *const std.testing.TmpDir) !void {
            defer s.stop();
            try s.waitReady();
            // setCertificate: A's certificate with B's key.
            try std.testing.expectError(error.KeyMismatch, s.setCertificate(.fromPem(mixed_cert, other_key)));
            // reloadCertificates: the key file swapped for B's.
            try td.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = other_key });
            try std.testing.expectError(error.KeyMismatch, s.reloadCertificates());
        }
    };
    var f = try app.io().concurrent(Run.run, .{ &app, b.key, a.cert, &tmp });
    try app.run();
    try f.await(app.io());
}

test "listenOn: only a development certificate off loopback warns" {
    try std.testing.expect(warnsDevCert(.dev_self_signed, .{ .ip = .{ .ip4 = .unspecified(8443) } }));
    try std.testing.expect(!warnsDevCert(.dev_self_signed, .{ .ip = .{ .ip4 = .loopback(8443) } }));
    try std.testing.expect(!warnsDevCert(.dev_self_signed, .{ .ip = .{ .ip6 = .loopback(8443) } }));
    try std.testing.expect(!warnsDevCert(.fromPem("c", "k"), .{ .ip = .{ .ip4 = .unspecified(8443) } }));
    try std.testing.expect(!warnsDevCert(.dev_self_signed, .{ .unix = try std.Io.net.UnixAddress.init("/tmp/x.sock") }));
}

const RawRequest = struct {
    fn send(io_: std.Io, address: std.Io.net.IpAddress, request: []const u8, out: []u8) ![]const u8 {
        const stream = try address.connect(io_, .{ .mode = .stream });
        defer stream.close(io_);
        var wbuf: [512]u8 = undefined;
        var w = stream.writer(io_, &wbuf);
        try w.interface.writeAll(request);
        try w.interface.flush();
        var rbuf: [1024]u8 = undefined;
        var r = stream.reader(io_, &rbuf);
        var fw: std.Io.Writer = .fixed(out);
        _ = r.interface.streamRemaining(&fw) catch {};
        return fw.buffered();
    }
};

fn echoRemote(req: *http.Request, res: *http.Response) !void {
    try res.print(.text, "{f}", .{req.remote_address});
}

fn failBoom(_: *http.Request, _: *http.Response) !void {
    return error.Boom;
}

fn failNotFound(_: *http.Request, _: *http.Response) !void {
    return error.NotFound;
}

test "anole.Server: behind_proxy over a real connection reads X-Forwarded-For from a trusted peer" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{
        .deployment = .behind_proxy,
        .http = .{ .port = 0, .h2c = false },
        .executors = .exact(1),
    }, {});
    defer app.deinit();
    try std.testing.expectEqual(modes.Deployment.behind_proxy, app.deployment());
    app.get("/who", echoRemote);
    var client_future = try app.io().concurrent(struct {
        fn run(a: *Server(void)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var out: [1024]u8 = undefined;
            const resp = try RawRequest.send(io_, a.addresses()[0].ip, "GET /who HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 198.51.100.7\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expect(std.mem.endsWith(u8, resp, "198.51.100.7:0"));
        }
    }.run, .{&app});
    try app.run();
    try client_future.await(app.io());
}

test "anole.Server: error_detail names the error in a 500, in development only" {
    // GET /boom logs its unhandled error, once per environment.
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    const gpa = std.testing.allocator;
    inline for (.{ modes.Environment.development, modes.Environment.production }) |environment| {
        var app = try Server(void).init(gpa, .{
            .environment = environment,
            .http = .{ .port = 0, .h2c = false },
            .executors = .exact(1),
        }, {});
        defer app.deinit();
        app.get("/boom", failBoom);
        app.get("/missing", failNotFound);
        const Client = struct {
            fn run(a: *Server(void)) !void {
                defer a.stop();
                const io_ = a.io();
                try a.waitReady();
                var out: [1024]u8 = undefined;
                const resp = try RawRequest.send(io_, a.addresses()[0].ip, "GET /boom HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
                try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 500"));
                const detail = std.mem.indexOf(u8, resp, "Internal Server Error: Boom") != null;
                try std.testing.expectEqual(environment == .development, detail);
                var out2: [1024]u8 = undefined;
                const resp2 = try RawRequest.send(io_, a.addresses()[0].ip, "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out2);
                try std.testing.expect(std.mem.startsWith(u8, resp2, "HTTP/1.1 404"));
            }
        };
        var client_future = try app.io().concurrent(Client.run, .{&app});
        try app.run();
        try client_future.await(app.io());
    }
}

test "anole.Server: proxy_protocol with an empty proxy.trusted is ProxyProtocolNoPeers" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ProxyProtocolNoPeers, Server(void).init(gpa, .{
        .proxy = .{ .trusted = &.{} },
        .http = .{ .port = 0, .proxy_protocol = true },
        .executors = .exact(1),
    }, {}));
}

test "anole.Server: a .env file with a problem is InvalidEnvFile" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.env", .data = "NOT A PAIR\n" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir_path);
    const path = try std.fmt.allocPrint(gpa, "{s}/bad.env", .{dir_path});
    defer gpa.free(path);
    env_mod._resetForTest();
    defer env_mod._resetForTest();
    try std.testing.expectError(error.InvalidEnvFile, Server(void).init(gpa, .{
        .environment = .development,
        .env_files = &.{path},
        .http = .{ .port = 0 },
        .executors = .exact(1),
    }, {}));
}
