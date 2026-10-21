//! `anole.Server(Ctx)`: one entry point over the zio runtime, dusty's server
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
//! Everything dusty offers stays reachable: `app.router` is dusty's router,
//! `app.server` dusty's server, and `anole.http` the whole of dusty.
const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const zio = @import("zio");
const http = @import("http/root.zig");
const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};
const handoff = @import("handoff.zig");
const blocking = @import("blocking.zig");
const sd_notify = @import("sd_notify.zig");
const early_data = @import("early_data.zig");
const h3 = if (features.http3) @import("h3/root.zig") else struct {};
const address_mod = @import("address.zig");
const handlers = @import("handlers.zig");
const client_mod = @import("client.zig");
const observe = @import("observe/root.zig");
const websocket = if (features.websocket) @import("websocket/root.zig") else struct {
    pub const UpgradeOptions = struct {};
};
const webtransport_mod = if (features.http3) @import("webtransport.zig") else struct {
    pub const AcceptOptions = struct {};
};
const sqlite_mod = if (features.sqlite) @import("sqlite/root.zig") else struct {
    pub const Db = void;
};
const pg_mod = if (features.postgres) @import("pg/root.zig") else struct {
    pub const Options = struct {};
    pub const Db = void;
};
const mongodb_mod = if (features.mongodb) @import("mongodb/root.zig") else struct {
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
pub const zio_options: zio.Options = .{ .scheduling = .pinned };

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

pub const Options = struct {
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
    ///         .{ .name = "public", .address = "0.0.0.0", .port = 443, .tls = .{ .cert = cert }, .http3 = true },
    ///         .{ .name = "admin", .port = 9090 },
    ///     },
    listeners: []const Listener = &.{},
    /// Raise the soft open-file limit to the hard one when the server is
    /// made, as Go does at startup: every connection is a file descriptor,
    /// and the soft limit is often 1024. `server.max_connections` follows
    /// the limit by default. Processes started from here inherit it.
    raise_fd_limit: bool = true,
    /// HTTP/2 settings, for h2c and h2 over TLS. 250 concurrent streams per
    /// connection by default.
    http2: http.ServerConfig.Http2 = .{ .max_concurrent_streams = 250 },
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
    /// handler's own needs are the application's to know.
    max_stack_size: usize = 1024 * 1024,
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
    restart_timeout_ms: u32 = 10_000,
    /// Whether `listenTls` also serves HTTP/3 on the same port number (UDP),
    /// advertised with `Alt-Svc`, when HTTP/3 is built in (the default
    /// `full` profile): with `http3`'s settings when set, else the defaults.
    listen_tls_http3: bool = true,
    /// A blocking pool (`anole.blocking`): jobs that run on threads beside
    /// the executors, at most this many at once. Password hashing uses it.
    /// Null: none, and such work runs on the request's executor.
    blocking: ?blocking.Options = null,
    /// How the server writes its own error answers (404, 405, the status
    /// an error maps to, `res.fail`): `.auto` sends `{"error":"..."}` to a
    /// request that takes JSON and text to others, `.json` and `.text`
    /// always. Replaces `server.errors`.
    errors: http.ErrorFormat = .auto,
    /// Answers handler and middleware errors in place of the default
    /// mapping, which it can fall back on with `anole.defaultError(req,
    /// res, err)`: no `Ctx` with `uncaughtError` needed. Replaces
    /// `server.error_handler` when set.
    error_handler: ?http.ErrorHandler = null,
    /// The rest of dusty's server configuration: timeouts, limits,
    /// `trusted_proxy_hops` and so on. Its `listeners` and `http2` are
    /// replaced by the fields above.
    server: http.ServerConfig = .{},

    pub const Http = struct {
        address: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        /// Cleartext HTTP/2 for clients that open with its preface, beside
        /// HTTP/1.1 on the same port.
        h2c: bool = features.http2,
        proxy_protocol: bool = false,
    };

    pub const Http3 = struct {
        /// The UDP address and port; `https`'s when null (the usual setup:
        /// one port number, over TCP and UDP).
        address: ?[]const u8 = null,
        port: ?u16 = null,
        /// Advertise HTTP/3 to HTTP/1.1 and HTTP/2 clients (`Alt-Svc`), so
        /// browsers switch to it.
        alt_svc: bool = true,
        /// Concurrent requests per connection.
        max_streams_bidi: u64 = 100,
        /// Make every new client prove its address with a Retry first (one
        /// more round trip; resists spoofed-source floods).
        validate_address: bool = false,
        idle_timeout_ms: u32 = 30_000,
        /// Take 0-RTT (early data) from clients resuming a session, which
        /// saves them a round trip. GET, HEAD and OPTIONS that come in
        /// 0-RTT run at once, with `Early-Data: 1` among their headers
        /// (`anole.early_data.isEarly`); other methods wait until the
        /// handshake completes, which a replayed flight never does.
        early_data: bool = false,
        /// QUIC interop runner tests only: also speak "hq-interop"
        /// (HTTP/0.9), serving the files under this directory.
        hq_interop_root: ?[]const u8 = null,
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

    pub const Https = struct {
        address: []const u8 = "127.0.0.1",
        port: u16 = 8443,
        cert: Cert,
        /// "h2" and "http/1.1" when HTTP/2 is built in, else "http/1.1".
        alpn_protocols: ?[]const []const u8 = null,
        client_auth: ?http.ServerConfig.Tls.ClientAuth = null,
        proxy_protocol: bool = false,
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
        address: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        /// A unix domain socket at this path instead of `address` and
        /// `port`. A socket file left behind by a server that is gone is
        /// replaced; one that something still listens on is an error.
        unix: ?[]const u8 = null,
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
        proxy_protocol: bool = false,

        pub const Tls = struct {
            /// Listeners that name the same certificate (the same files,
            /// the same PEM, `dev_self_signed`) share one copy of it.
            cert: Cert,
            /// Offered by ALPN, in order. Null: "h2" and "http/1.1", those
            /// of the two the listener speaks.
            alpn_protocols: ?[]const []const u8 = null,
            client_auth: ?http.ServerConfig.Tls.ClientAuth = null,
        };
    };

    pub const Cert = union(enum) {
        /// PEM text in memory, copied by `init`.
        pem: struct { cert: []const u8, key: []const u8 },
        /// PEM files, read when the server starts.
        files: struct { cert_path: []const u8, key_path: []const u8 },
        /// A fresh self-signed certificate for localhost, held in memory:
        /// for development only.
        dev_self_signed,

        /// PEM files, read when the server starts (and again by
        /// `reloadCertificates` and SIGHUP).
        pub fn fromFiles(cert_path: []const u8, key_path: []const u8) Cert {
            return .{ .files = .{ .cert_path = cert_path, .key_path = key_path } };
        }

        /// PEM text in memory.
        pub fn fromPem(cert: []const u8, key: []const u8) Cert {
            return .{ .pem = .{ .cert = cert, .key = key } };
        }
    };
};

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

pub const OnlyOn = struct {
    name: []const u8,

    pub fn execute(self: *const OnlyOn, req: *http.Request, _: *http.Response, executor: anytype) !void {
        if (!std.mem.eql(u8, req.listener.name, self.name)) return error.NotFound;
        return executor.next();
    }
};

pub fn Server(comptime Ctx: type) type {
    return ServerOf(Ctx, false);
}

/// `Server(Ctx)`, or with `app_init` `App`: the same server, whose `init`
/// takes no state.
fn ServerOf(comptime Ctx: type, comptime app_init: bool) type {
    comptime checkZioOptions();
    return struct {
        const Self = @This();
        pub const Handler = http.Router(Ctx).Handler;

        gpa: std.mem.Allocator,
        rt: *zio.Runtime,
        /// Holds what the server points into for its whole life: the
        /// listeners, certificates and middleware copies. So `Self` can
        /// move after `init`.
        arena: *std.heap.ArenaAllocator,
        server: *http.Server(Ctx),
        router: *http.Router(Ctx),
        stopped: *std.Io.Event,
        /// For hand-off: the process (args, environment), and the
        /// listening sockets to pass on.
        process: ?std.process.Init.Minimal = null,
        held: []const handoff.Listener = &.{},
        restart_timeout_ms: u32 = 10_000,
        /// The HTTP/3 endpoint, when `Options.http3` asked for one.
        h3: H3Endpoint,
        /// The blocking pool, when `Options.blocking` asked for one.
        blocking_pool: ?*blocking.Pool = null,
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
        /// What the one-line helpers made (`client`, `metrics`, `health`,
        /// `grpcHealth`, `tracing`, `staticDir`), freed with the server.
        extras: *Extras,

        const Extras = struct {
            /// The outbound client (`client()`, `anole.client(req)`).
            client: http.Client,
            client_entry: client_mod.Entry,
            client_registered: bool,
            metrics: ?*observe.metrics.Registry = null,
            metrics_path: []const u8 = "",
            health: ?*observe.Health = null,
            /// `metrics` and `health` register their routes when serving
            /// starts, so `use` can still follow them.
            routes_added: bool = false,
            grpc_health: ?*grpc_mod.Health = null,
            exporter: ?*observe.trace.Exporter = null,
            dirs: std.ArrayList(std.Io.Dir) = .empty,
            /// A WebTransport route exists: the HTTP/3 listener speaks it.
            webtransport: bool = false,
            /// The database connectors made here (`postgres`, `sqlite`), in order.
            connectors: std.ArrayList(Connector) = .empty,
            connectors_started: bool = false,
            /// One certificate reload at a time.
            cert_mutex: std.Io.Mutex = .init,
        };

        /// A database connector the server made: when serving starts it
        /// gets the app's metrics, tracer and health checks (whichever
        /// exist by then, so the helpers may come in any order), and it is
        /// closed with the server, after the drain.
        const Connector = struct {
            context: *anyopaque,
            start: *const fn (context: *anyopaque, metrics: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) anyerror!void,
            deinit: *const fn (context: *anyopaque) void,

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
                };
                return .{ .context = value, .start = Hooks.start, .deinit = Hooks.deinit };
            }
        };

        const H3Endpoint = if (features.http3) ?*h3.Endpoint(Ctx) else void;

        /// A certificate the TLS listeners serve: the PEM in use, where a
        /// reload reads it again, and the listener configurations dusty
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
                    std.log.scoped(.anole).err("cannot read the TLS {s} \"{s}\": {t}", .{ what, path, err });
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

            pub fn execute(self: *const AltSvc, req: *http.Request, res: *http.Response, executor: anytype) !void {
                if (self.value) |v| if (req.version_major != 3 and self.listener != null and req.listener == self.listener.?) try res.header("Alt-Svc", v);
                return executor.next();
            }
        };

        /// `App.init(gpa, options)`, or `Server(Ctx).init(gpa, options,
        /// state)`: the runtime, the server and the routes' home. The
        /// listeners `options` names (`http`, `https`, `http3`) are set up
        /// here; with neither `http` nor `https`, by `listen`, `listenTls`
        /// or `run` (127.0.0.1:8080).
        pub const init = if (app_init) initApp else initState;

        fn initApp(gpa: std.mem.Allocator, opts: Options) !Self {
            return initState(gpa, opts, {});
        }

        fn initState(gpa: std.mem.Allocator, opts: Options, ctx: if (Ctx == void) void else *Ctx) !Self {
            // zio binds the runtime to this thread (its first executor), and
            // a second runtime would take the thread over from the first.
            if (server_on_thread) return error.ServerAlreadyOnThread;
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

            const rt = try zio.Runtime.init(gpa, .{
                .executors = opts.executors,
                .stack_pool = .{
                    .maximum_size = opts.max_stack_size,
                    .committed_size = @min(opts.max_stack_size, 256 * 1024),
                },
            });
            errdefer rt.deinit();
            const rt_io = rt.io();
            server_on_thread = true;
            errdefer server_on_thread = false;

            var server_config = opts.server;
            server_config.listeners = &.{};
            server_config.http2 = opts.http2;
            server_config.errors = opts.errors;
            if (opts.error_handler) |h| server_config.error_handler = h;
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
            extras.* = .{ .client = http.Client.init(gpa, rt_io, .{}), .client_entry = undefined, .client_registered = false };
            extras.client_entry = .{ .rt = rt, .client = &extras.client };
            extras.client_registered = client_mod.register(&extras.client_entry);
            errdefer {
                if (extras.client_registered) client_mod.unregister(&extras.client_entry);
                extras.client.deinit();
            }

            var self: Self = .{
                .gpa = gpa,
                .rt = rt,
                .arena = arena,
                .server = server,
                .router = &server.router,
                .stopped = stopped,
                .process = opts.process,
                .restart_timeout_ms = opts.restart_timeout_ms,
                .h3 = if (features.http3) null else {},
                .blocking_pool = pool,
                .extras = extras,
            };
            // RFC 8470 §5.1: unsafe requests taken in early data (marked
            // `Early-Data: 1`, by the HTTP/3 endpoint or a proxy in front)
            // get 425 Too Early, on every route. Now, before any route, and
            // for `listenTls` too, which turns HTTP/3 on later.
            const h3_possible = features.http3 and (opts.http3 != null or opts.listen_tls_http3 or anyHttp3(opts.listeners));
            if (h3_possible) {
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
        fn listenerSpecs(a: std.mem.Allocator, opts: Options) ![]const Spec {
            var specs: std.ArrayList(Spec) = .empty;
            // 127.0.0.1:8080 when nothing else is named.
            const http_opts: ?Options.Http = opts.http orelse if (opts.https == null and opts.listeners.len == 0) .{} else null;
            if (http_opts) |h| try specs.append(a, .{ .name = "http", .listener = .{
                .address = h.address,
                .port = h.port,
                .http2 = h.h2c and features.http2,
                .proxy_protocol = h.proxy_protocol,
            } });
            if (opts.https) |h| try specs.append(a, .{ .name = "https", .listener = .{
                .address = h.address,
                .port = h.port,
                .tls = .{ .cert = h.cert, .alpn_protocols = h.alpn_protocols, .client_auth = h.client_auth },
                .http3 = opts.http3 != null,
                .proxy_protocol = h.proxy_protocol,
            } });
            for (opts.listeners) |l| {
                var name = l.name orelse if (l.unix) |path|
                    try std.fmt.allocPrint(a, "unix-{s}", .{path})
                else
                    try std.fmt.allocPrint(a, "{s}-{d}", .{ if (l.tls != null) "https" else "http", l.port });
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
        fn checkSpecs(specs: []const Spec, opts: Options, why: *std.Io.Writer) !void {
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
        fn listenOn(self: *Self, opts: Options) !void {
            const gpa = self.gpa;
            const a = self.arena.allocator();
            const rt_io = self.rt.io();
            const server = self.server;
            const specs = try listenerSpecs(a, opts);
            {
                var why_buf: [512]u8 = undefined;
                var why: std.Io.Writer = .fixed(&why_buf);
                checkSpecs(specs, opts, &why) catch |err| {
                    std.log.scoped(.anole).err("{s}", .{why.buffered()});
                    return err;
                };
            }
            // One accept loop per executor (dusty's default on zio); on
            // Linux each with its own SO_REUSEPORT socket, so the kernel
            // spreads connections over the executors.
            // Hand-off needs one socket per listener, which we open (or
            // inherit) ourselves.
            const handoff_mode = opts.process != null;
            if (handoff_mode and specs.len > handoff.max_tcp_listeners) return error.TooManyListeners;
            const per_core_sockets = builtin.os.tag == .linux and !handoff_mode;
            const inherited = if (opts.process) |p| handoff.inherited(p.environ) else null;
            var held: std.ArrayList(handoff.Listener) = .empty;
            // Fixed now: the certificates and Alt-Svc point into it.
            const listeners = try a.alloc(http.Listener, specs.len);
            // The certificates are read here, files included, and handed
            // to dusty (and HTTP/3) as PEM: a reload reads them again the
            // same way.
            var certs: std.ArrayList(*CertState) = .empty;
            errdefer for (certs.items) |cs| cs.deinit();
            var h3_at: ?usize = null;
            for (specs, listeners, 0..) |spec, *out, i| {
                const l = spec.listener;
                const address: http.Address = if (l.unix) |path|
                    .{ .unix = try std.Io.net.UnixAddress.init(path) }
                else
                    .{ .ip = try std.Io.net.IpAddress.parse(l.address, l.port) };
                var config: ?http.ServerConfig.Tls = null;
                if (l.tls) |t| {
                    if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
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
                        .alpn_protocols = t.alpn_protocols orelse defaultAlpn(l),
                        .client_auth = t.client_auth,
                        .pem = .{ .cert = cs.pem.cert, .key = cs.pem.key },
                    };
                }
                if (l.http3) h3_at = i;
                if (address == .unix and !handoff_mode) try clearStaleUnixSocket(rt_io, address.unix);
                const fd = try listenerFd(rt_io, inherited, handoff_mode, spec.name, i, address);
                if (fd) |f| try held.append(a, .{ .fd = f, .name = spec.name });
                out.* = .{
                    .address = address,
                    .name = spec.name,
                    .http1 = l.http1,
                    .http2_prior_knowledge = l.tls == null and l.http2 and features.http2,
                    .socket_per_acceptor = per_core_sockets and address == .ip,
                    .proxy_protocol = l.proxy_protocol,
                    .tls = config,
                    .fd = fd,
                };
            }

            server.config.listeners = listeners;
            errdefer server.config.listeners = &.{};

            var endpoint: H3Endpoint = if (features.http3) null else {};
            if (comptime features.http3) if (h3_at) |at| {
                const q = opts.http3 orelse Options.Http3{};
                const l = specs[at].listener;
                const tcp = &listeners[at];
                const cs = for (certs.items) |cs| {
                    if (std.mem.indexOfScalar(*http.Listener, cs.listeners.items, tcp) != null) break cs;
                } else unreachable;
                cs.h3_listener = tcp;
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
                const secret: ?[32]u8 = if (h3_fds.len > 0) handoff.inheritedSecret(opts.process.?.environ) else null;
                const ep = try h3.Endpoint(Ctx).init(gpa, rt_io, server, .{
                    .address = try std.Io.net.IpAddress.parse(q.address orelse l.address, q.port orelse l.port),
                    .cert_pem = cs.pem.cert,
                    .key_pem = cs.pem.key,
                    .max_streams_bidi = q.max_streams_bidi,
                    .validate_address = q.validate_address,
                    .idle_timeout_ms = q.idle_timeout_ms,
                    .hq_interop_root = q.hq_interop_root,
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
                });
                errdefer ep.deinit();
                endpoint = ep;
                // Named in the TLS listener's startup line.
                const udp_port = ep.address().getPort();
                tcp.extra_protocols = if (udp_port == tcp.address.ip.getPort())
                    &.{"HTTP/3"}
                else
                    try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "HTTP/3 on UDP port {d}", .{udp_port})});
                // Every socket, in the group's order.
                if (handoff_mode) for (ep.endpoints()) |e| try held.append(a, .{ .fd = e.udp.socket.handle, .name = "h3" });
                if (q.alt_svc) {
                    const alt = self.alt_svc orelse self.addAltSvc();
                    self.alt_svc = alt;
                    alt.listener = tcp;
                    alt.value = try std.fmt.allocPrint(a, "h3=\":{d}\"; ma=86400", .{udp_port});
                }
            };
            self.held = held.items;
            self.h3 = endpoint;
            self.certs = certs.items;
        }

        /// The HTTP/3 endpoint's mutual TLS settings: the TCP listener's
        /// mode, with its CAs (`bundle`, loaded by the caller).
        fn h3ClientAuth(client_auth: ?http.ServerConfig.Tls.ClientAuth, bundle: ?std.crypto.Certificate.Bundle) if (features.http3) ?h3.ClientAuth else void {
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
        /// Null outside hand-off mode (dusty binds).
        fn listenerFd(io_: std.Io, inherited: ?handoff.Inherited, handoff_mode: bool, name: []const u8, index: usize, address: http.Address) !?handoff.Fd {
            if (!handoff_mode) return null;
            if (inherited) |inh| if (inh.find(name, index)) |fd| return fd;
            switch (address) {
                .ip => |ip| {
                    // SO_REUSEPORT would share the port with whoever has it.
                    try http.checkAddressFree(ip);
                    const s = try ip.listen(io_, .{ .reuse_address = true });
                    return s.socket.handle;
                },
                .unix => |unix| {
                    try clearStaleUnixSocket(io_, unix);
                    const s = try unix.listen(io_, .{});
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
                std.log.scoped(.anole).err("unix:{s} is already in use: another process is listening on it", .{address.path});
                return error.AddressInUse;
            } else |err| switch (err) {
                error.ConnectionRefused => cwd.deleteFile(io_, address.path) catch {},
                else => {},
            }
        }

        pub fn deinit(self: *Self) void {
            const extras = self.extras;
            // First: it sends what is queued through the client, on the
            // runtime.
            if (extras.exporter) |e| e.deinit();
            if (comptime features.http3) if (self.h3) |ep| ep.deinit();
            self.server.deinit();
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
        /// `stop`, as `run` does: ":3000" is every IPv4 interface (as in
        /// a container), "127.0.0.1:3000" or "localhost:3000" this machine
        /// only, "[::]:3000" every IPv6 interface. HTTP/1.1, and HTTP/2 for
        /// clients that open with its preface (h2c). For a server whose
        /// `init` options named neither `http` nor `https`; it serves the
        /// options' `listeners` too.
        pub fn listen(self: *Self, address: []const u8) !void {
            var opts = try self.takePending("listen");
            const at = address_mod.parse(address) catch |err| return self.failStart(err);
            opts.http = .{ .address = at.host, .port = at.port };
            try self.configure(opts);
            return self.run();
        }

        /// `listen`, over TLS with `cert`: HTTP/2 and HTTP/1.1 by ALPN, and
        /// HTTP/3 on the same port number over UDP (advertised with
        /// `Alt-Svc`) when it is built in, unless `Options.listen_tls_http3`
        /// is off.
        ///
        ///     try app.listenTls(":443", .fromFiles("cert.pem", "key.pem"));
        ///     try app.listenTls("localhost:8443", .dev_self_signed);
        pub fn listenTls(self: *Self, address: []const u8, cert: Options.Cert) !void {
            var opts = try self.takePending("listenTls");
            const at = address_mod.parse(address) catch |err| return self.failStart(err);
            opts.https = .{ .address = at.host, .port = at.port, .cert = cert };
            // Unless a listener in `listeners` serves HTTP/3 already.
            if (features.http3 and opts.listen_tls_http3 and opts.http3 == null and !anyHttp3(opts.listeners)) opts.http3 = .{};
            try self.configure(opts);
            return self.run();
        }

        fn takePending(self: *Self, comptime what: []const u8) !Options {
            return self.pending orelse {
                // Not the end of the server: `run` still serves those.
                std.log.scoped(.anole).info(what ++ "(): this server's listeners come from its init options (http, https); serve them with run(), or leave both out of init", .{});
                return error.ListenersAlreadySet;
            };
        }

        /// The listeners `init` left for later; a failure also ends
        /// `waitReady`.
        fn configure(self: *Self, opts: Options) !void {
            self.pending = null;
            self.listenOn(opts) catch |err| return self.failStart(err);
        }

        /// `err`, also for whoever waits in `waitReady`: the server will
        /// not start.
        fn failStart(self: *Self, err: anyerror) anyerror {
            if (!self.server.settled.isSet()) {
                self.server.start_error = err;
                self.server.settled.set(self.rt.io());
            }
            return err;
        }

        /// A copy of `value`, a middleware (a struct with `execute`, or a
        /// function: see `anole.func`), that the server owns: freed with
        /// it, after its `deinit` if it has one. The handle can go into
        /// several groups. A handle given in place of a value is returned
        /// as it is.
        pub fn middleware(self: *Self, value: anytype) http.Middleware(Ctx) {
            const T = @TypeOf(value);
            if (T == http.Middleware(Ctx)) return value;
            if (comptime handlers.isFn(T)) return self.middleware(handlers.func(value));
            const copy = self.arena.allocator().create(T) catch @panic("OOM");
            copy.* = value;
            const handle = http.Middleware(Ctx).init(copy);
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

        pub fn get(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.get, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn head(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.head, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn post(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.post, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn put(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.put, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn patch(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.patch, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn delete(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.delete, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn options(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.options, path, route(handler), handlers.routeOptions(handler));
        }
        /// The HTTP QUERY method (a GET with a body).
        pub fn query(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(.query, path, route(handler), handlers.routeOptions(handler));
        }
        pub fn any(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.router.addRouteWith(null, path, route(handler), handlers.routeOptions(handler));
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
        pub fn ws(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.wsWith(path, handler, .{});
        }

        /// `ws` with upgrade options (message size limit, compression,
        /// timeout, the drain close).
        pub fn wsWith(self: *Self, path: []const u8, comptime handler: anytype, comptime upgrade: websocket.UpgradeOptions) void {
            if (comptime !features.websocket) @compileError("app.ws needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
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
        pub fn wsCallbacks(self: *Self, path: []const u8, comptime Handlers: type) void {
            self.wsCallbacksWith(path, Handlers, .{});
        }

        /// `wsCallbacks` with upgrade options.
        pub fn wsCallbacksWith(self: *Self, path: []const u8, comptime Handlers: type, comptime upgrade: websocket.UpgradeOptions) void {
            if (comptime !features.websocket) @compileError("app.wsCallbacks needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
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
        pub fn webtransport(self: *Self, path: []const u8, comptime handler: anytype) void {
            self.webtransportWith(path, handler, .{});
        }

        /// `webtransport` with accept options (the drain's close, timeout).
        pub fn webtransportWith(self: *Self, path: []const u8, comptime handler: anytype, comptime accept: webtransport_mod.AcceptOptions) void {
            if (comptime !features.http3) @compileError("app.webtransport needs HTTP/3 (-Dhttp3, on in the full profile)");
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
                std.log.scoped(.anole).err("cannot open the static directory \"{s}\": {t}", .{ path, err });
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
            inner: http.Router(Ctx).Group,

            pub fn group(g: Group, prefix: []const u8, middlewares: anytype) Group {
                return .{ .server = g.server, .inner = g.inner.group(prefix, g.server.handles(middlewares)) };
            }
            /// Routes behind more middleware, with no further prefix.
            pub fn with(g: Group, middlewares: anytype) Group {
                return g.group("", middlewares);
            }
            pub fn get(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.get, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn head(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.head, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn post(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.post, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn put(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.put, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn patch(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.patch, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn delete(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.delete, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn options(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.options, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn query(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(.query, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn any(g: Group, path: []const u8, comptime handler: anytype) void {
                g.inner.addRouteWith(null, path, route(handler), handlers.routeOptions(handler));
            }
            pub fn ws(g: Group, path: []const u8, comptime handler: anytype) void {
                g.wsWith(path, handler, .{});
            }
            pub fn wsWith(g: Group, path: []const u8, comptime handler: anytype, comptime upgrade: websocket.UpgradeOptions) void {
                if (comptime !features.websocket) @compileError("ws needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
                g.inner.get(path, websocket.route(Ctx, handler, upgrade));
            }
            pub fn wsCallbacks(g: Group, path: []const u8, comptime Handlers: type) void {
                g.wsCallbacksWith(path, Handlers, .{});
            }
            pub fn wsCallbacksWith(g: Group, path: []const u8, comptime Handlers: type, comptime upgrade: websocket.UpgradeOptions) void {
                if (comptime !features.websocket) @compileError("wsCallbacks needs WebSocket support (-Dwebsocket, on in the web and full profiles)");
                g.inner.get(path, websocket.callbacks(Ctx, Handlers, upgrade));
            }
            pub fn webtransport(g: Group, path: []const u8, comptime handler: anytype) void {
                g.webtransportWith(path, handler, .{});
            }
            pub fn webtransportWith(g: Group, path: []const u8, comptime handler: anytype, comptime accept: webtransport_mod.AcceptOptions) void {
                if (comptime !features.http3) @compileError("webtransport needs HTTP/3 (-Dhttp3, on in the full profile)");
                g.server.enableWebTransport();
                g.inner.get(path, webtransport_mod.route(Ctx, handler, accept));
            }
            pub fn static(g: Group, prefix: []const u8, dir: std.Io.Dir, opts: http.StaticOptions) void {
                g.inner.static(prefix, dir, opts);
            }
            pub fn staticDir(g: Group, prefix: []const u8, path: []const u8, opts: http.StaticOptions) !void {
                g.inner.static(prefix, try g.server.openDir(path), opts);
            }
            pub fn embedded(g: Group, path: []const u8, data: []const u8, opts: http.EmbeddedOptions) void {
                g.inner.embedded(path, data, opts);
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
            if (comptime !features.grpc) @compileError("app.grpc needs gRPC (-Dgrpc, on in the full profile)");
            const Svc = if (@TypeOf(Service) == type) Service else Service(grpc_mod.Call, anyerror);
            const I = @TypeOf(impl);
            if (@typeInfo(I) == .pointer and @typeInfo(@typeInfo(I).pointer.child) == .@"struct") {
                // Methods on a value: the registration carries the pointer
                // (`Call.data`) to them.
                var with_data = opts;
                with_data.data = @ptrCast(@constCast(impl));
                grpc_mod.registerWith(Ctx, self.router, Svc, comptime boundMethods(Svc, @typeInfo(I).pointer.child), with_data);
            } else if (I == type) {
                grpc_mod.registerWith(Ctx, self.router, Svc, comptime declaredMethods(Svc, impl), opts);
            } else {
                grpc_mod.registerWith(Ctx, self.router, Svc, comptime listedMethods(Svc, impl), opts);
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

        /// Hands the databases what the app observes with, once.
        fn startConnectors(self: *Self) !void {
            const extras = self.extras;
            if (extras.connectors_started) return;
            extras.connectors_started = true;
            for (extras.connectors.items) |c| try c.start(c.context, extras.metrics, extras.exporter, extras.health);
        }

        /// The routes `metrics` and `health` left for when serving starts.
        fn addHelperRoutes(self: *Self) void {
            const extras = self.extras;
            if (extras.routes_added) return;
            extras.routes_added = true;
            if (extras.metrics) |r| r.serveOn(Ctx, self.router, extras.metrics_path);
            if (extras.health) |h| h.registerOn(Ctx, self.router, self.server);
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

        pub const MetricsOptions = struct {
            /// Where Prometheus scrapes.
            path: []const u8 = "/metrics",
            /// Count every request (`anole_http_*`), through a middleware.
            /// Off: `/metrics` serves only what is added to the registry.
            http: bool = true,
            /// Paths the HTTP metrics leave out.
            exclude: []const []const u8 = &observe.probe_paths,
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
            self.extras.metrics = r;
            self.extras.metrics_path = opts.path;
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

        pub const TracingOptions = struct {
            /// The collector's OTLP/HTTP base URL. Null: the
            /// `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable (read
            /// through `Options.process`), else http://localhost:4318.
            endpoint: ?[]const u8 = null,
            /// Null: `OTEL_SERVICE_NAME` (as above), else "anole".
            service_name: ?[]const u8 = null,
            /// Record every request, or only those whose caller sampled.
            sample_all: bool = true,
            /// Paths not traced.
            exclude: []const []const u8 = &observe.probe_paths,
            batch_size: usize = 256,
            interval_ms: u32 = 2000,
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
            const env = if (self.process) |p| p.environ else null;
            const e = try self.arena.allocator().create(observe.trace.Exporter);
            e.* = try observe.trace.Exporter.init(self.gpa, self.rt.io(), &self.extras.client, .{
                .endpoint = opts.endpoint orelse (if (env) |v| v.getPosix("OTEL_EXPORTER_OTLP_ENDPOINT") else null) orelse "http://localhost:4318",
                .service_name = opts.service_name orelse (if (env) |v| v.getPosix("OTEL_SERVICE_NAME") else null) orelse "anole",
                .sample_all = opts.sample_all,
                .exclude = opts.exclude,
                .batch_size = opts.batch_size,
                .interval_ms = opts.interval_ms,
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
        pub fn postgres(self: *Self, config: pg_mod.Options) !*pg_mod.Db {
            if (comptime !features.postgres) @compileError("app.postgres needs PostgreSQL (-Dpostgres, on in the web and full profiles)");
            var opts = config;
            if (opts.environ == null) if (self.process) |p| {
                opts.environ = p.environ;
            };
            const d = try pg_mod.Db.init(self.gpa, self.rt.io(), opts);
            errdefer d.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(pg_mod.Db, d));
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
        ///     state.db = try app.sqlite(.{ .path = "data/app.db", .busy_timeout_ms = 10_000 });
        pub fn sqlite(self: *Self, config: anytype) !*sqlite_mod.Db {
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
            const d = try sqlite_mod.Db.init(self.gpa, self.rt.io(), opts);
            errdefer d.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(sqlite_mod.Db, d));
            return d;
        }

        /// A MongoDB client for the handlers, owned by the server:
        /// `state.mongo = try app.mongodb(.{});` reads `MONGODB_URI` (or
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
            const mongo = try mongodb_mod.Client.connect(self.gpa, self.rt.io(), opts);
            errdefer mongo.deinit();
            try self.extras.connectors.append(self.arena.allocator(), .of(mongodb_mod.Client, mongo));
            return mongo;
        }

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
        pub fn reloadCertificates(self: *Self) !void {
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
        pub fn setCertificate(self: *Self, cert: Options.Cert) !void {
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
                    const tcp = cs.h3_listener orelse continue;
                    const client_auth = tcp.tls.?.client_auth;
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

        /// The bound address of each listener (`http`, `https`, then
        /// `listeners`, in order), once serving; a listener given port 0
        /// has its real port here.
        pub fn addresses(self: *const Self) []const http.Address {
            return self.server.addresses;
        }

        /// Waits until the listeners are bound, or returns `run`'s error if
        /// it stopped before they were (a certificate that will not load,
        /// a port in use) rather than waiting for good.
        pub fn waitReady(self: *Self) !void {
            try self.server.waitReady(self.rt.io());
        }

        /// Serves until SIGINT, SIGTERM or `stop`, then stops accepting and
        /// drains the requests in flight (bounded by `timeout.shutdown`).
        /// Sets up the listeners first when `init` left them (the options'
        /// `listeners`, or 127.0.0.1:8080 when there are none, unless
        /// `listen` or `listenTls` named others). Call it from the
        /// thread that called `init`.
        pub fn run(self: *Self) !void {
            if (self.pending) |opts| try self.configure(opts);
            self.addHelperRoutes();
            self.startConnectors() catch |err| return self.failStart(err);
            const rt_io = self.rt.io();
            const Done = union(enum) {
                int: anyerror!void,
                term: anyerror!void,
                stop: anyerror!void,
                served: anyerror!void,
                restart: anyerror!void,
                h3: anyerror!void,
                reload: anyerror!void,
            };
            var done_buf: [8]Done = undefined;
            var sel = std.Io.Select(Done).init(rt_io, &done_buf);
            try sel.concurrent(.int, waitForSignal, .{.interrupt});
            try sel.concurrent(.term, waitForSignal, .{.terminate});
            try sel.concurrent(.stop, waitStopped, .{ self.stopped, rt_io });
            try sel.concurrent(.served, serve, .{self.server});
            if (comptime features.http3) if (self.h3) |ep| try sel.concurrent(.h3, serveH3, .{ep});
            const restartable = self.process != null and self.held.len > 0;
            if (restartable) try sel.concurrent(.restart, waitForSignal, .{.user2});
            // SIGHUP reloads the certificate, where there is one.
            if (self.certs.len > 0) try sel.concurrent(.reload, reloadOnHangup, .{self});
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
                if (done != .restart) break done;
                // SIGUSR2: start the successor; drain once it serves.
                if (self.restart()) break done;
                try sel.concurrent(.restart, waitForSignal, .{.user2});
            };
            if (first == .restart) {
                // HTTP/3 cannot drain beside the successor on one UDP
                // socket: its connections close now and it stops reading.
                if (comptime features.http3) if (self.h3) |ep| ep.handOver();
            } else if (self.process) |p| {
                sd_notify.stopping(p.environ);
            }
            // gRPC health watchers hear of the drain before it starts.
            if (comptime features.grpc) if (self.extras.grpc_health) |h| h.shutdown();
            // Cancels the server's run, which drains, then the watchers.
            sel.cancelDiscard();
            switch (first) {
                .served, .h3 => |r| return r,
                .reload => unreachable,
                .int, .term => log.info("signal received ({t}); drained and stopped", .{first}),
                .restart => log.info("handed over to the new process; drained and stopped", .{}),
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
            if (!successor.waitReady(self.rt.io(), self.restart_timeout_ms)) {
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

        fn notifyWhenReady(server: *http.Server(Ctx), rt_io: std.Io, process: std.process.Init.Minimal) void {
            // Only a server that is listening tells the predecessor so;
            // one that failed to start leaves it to time out and carry on.
            server.waitReady(rt_io) catch return;
            // A successor names itself the main process before its
            // predecessor starts to exit.
            const successor = handoff.isSuccessor(process.environ);
            sd_notify.ready(process.environ, if (successor) std.c.getpid() else null);
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

    var app = try Server(void).init(gpa, .{
        .http = null,
        .https = .{
            .port = 0,
            .cert = .{ .pem = .{ .cert = pem.cert, .key = pem.key } },
            .client_auth = .{ .ca = .{ .file = .{ .path = "cert.pem", .dir = tmp.dir } } },
        },
        .http3 = .{ .port = 0, .alt_svc = false },
        .executors = .exact(2),
    }, {});
    defer app.deinit();
    app.get("/peer", handlePeerCertificate);

    const Check = struct {
        fn run(a: *Server(void), p: *const tls.Pem, dir: std.Io.Dir) !void {
            defer a.stop();
            const io_ = a.io();
            const alloc = std.testing.allocator;
            try a.waitReady();
            var bundle = try tls.testing.bundleFromPem(alloc, std.Io.Clock.real.now(io_).toSeconds(), p.cert);
            defer bundle.deinit(alloc);
            // The certificate's DER: the bundle holds exactly it.
            const der = bundle.bytes.items;
            const port = a.addresses()[0].ip.getPort();

            // HTTP/1.1, without a certificate and with one.
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/peer", .{port});
            const ca: http.dusty_module.TlsCa = .{ .file = .{ .path = "cert.pem", .dir = dir } };
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
                    .client_certificate = .{ .cert_path = "cert.pem", .key_path = "key.pem", .dir = dir },
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
    var client_future = try app.io().concurrent(Check.run, .{ &app, &pem, tmp.dir });
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

    /// HTTP/1.1, trusting only the CA in `dir/ca_name`.
    fn h1(io_: std.Io, port: u16, dir: std.Io.Dir, ca_name: []const u8) !void {
        var client = http.Client.init(alloc, io_, .{ .tls = .{ .ca = .{ .file = .{ .path = ca_name, .dir = dir } } } });
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
    fn serves(a: *Server(void), dir: std.Io.Dir, ca_name: []const u8, ca: []const u8) !void {
        const io_ = a.io();
        const port = a.addresses()[0].ip.getPort();
        try h1(io_, port, dir, ca_name);
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
        fn run(a: *Server(void), p: *const [4]tls.Pem, dir: std.Io.Dir) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();

            try ReloadCheck.serves(a, dir, "ca0.pem", p[0].cert);
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
            try ReloadCheck.serves(a, dir, "ca1.pem", p[1].cert);
            try std.testing.expect(std.meta.isError(ReloadCheck.h1(io_, port, dir, "ca0.pem")));
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);

            // A key that does not go with the certificate: refused, and
            // nothing changes.
            try dir.writeFile(io_, .{ .sub_path = "key.pem", .data = p[2].key });
            try std.testing.expect(std.meta.isError(a.reloadCertificates()));
            try ReloadCheck.serves(a, dir, "ca1.pem", p[1].cert);

            // SIGHUP, once `run` listens for it.
            try dir.writeFile(io_, .{ .sub_path = "cert.pem", .data = p[2].cert });
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
            const switched = for (0..300) |_| {
                if (ReloadCheck.h1(io_, port, dir, "ca2.pem")) |_| break true else |_| {}
                try io_.sleep(.fromMilliseconds(10), .awake);
            } else false;
            try std.testing.expect(switched);
            try ReloadCheck.serves(a, dir, "ca2.pem", p[2].cert);

            // setCertificate: PEM in memory.
            try a.setCertificate(.{ .pem = .{ .cert = p[3].cert, .key = p[3].key } });
            try ReloadCheck.serves(a, dir, "ca3.pem", p[3].cert);
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);
        }
    };
    var client_future = try app.io().concurrent(Run.run, .{ &app, &pems, tmp.dir });
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

    pub fn execute(self: *const CountingMiddleware, _: *http.Request, _: *http.Response, executor: anytype) !void {
        _ = self.hits.fetchAdd(1, .monotonic);
        return executor.next();
    }

    pub fn deinit(self: *CountingMiddleware) void {
        self.deinits.* += 1;
    }
};

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
            const ca: http.dusty_module.TlsCa = .{ .pem = p.cert };
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

            // TLS, HTTP/2 only: a client that offers HTTP/1.1 alone (as
            // the HTTP client does by default) is not served.
            const h2tls = addrs[6].ip.getPort();
            try std.testing.expect(std.meta.isError(client.fetch(try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{h2tls}), .{})));
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
        const specs = try S.listenerSpecs(arena.allocator(), c.opts);
        var why_buf: [512]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        try std.testing.expectError(c.err, S.checkSpecs(specs, c.opts, &why));
        try std.testing.expect(why.buffered().len > 0);
    }
    // The names made up for listeners without one, unique on port 0 too.
    const specs = try S.listenerSpecs(arena.allocator(), .{
        .http = .{},
        .listeners = &.{ .{ .port = 0 }, .{ .port = 0 }, .{ .port = 9443, .tls = .{ .cert = cert } }, .{ .unix = "/run/app.sock" } },
    });
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
        .server = .{ .max_connections = 77 },
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
