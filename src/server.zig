//! `anole.Server(Ctx)`: one entry point over the zio runtime, dusty's server
//! and Anole's TLS. It owns the runtime (pinned scheduling, one executor per
//! core), builds the listeners (cleartext with h2c, TLS with ALPN), and
//! `run` serves until SIGINT, SIGTERM or `stop`, then drains.
//!
//!     pub const zio_options = anole.zio_options;
//!
//!     pub fn main(init: std.process.Init) !void {
//!         var app = try anole.Server(void).init(init.gpa, .{
//!             .http = .{ .port = 8080 },
//!             .https = .{ .port = 8443, .cert = .dev_self_signed },
//!         }, {});
//!         defer app.deinit();
//!         app.use(anole.middleware.RequestId.init(.{}));
//!         app.get("/users/:id", getUser);
//!         try app.run();
//!     }
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
const h3 = if (features.http3) @import("h3/root.zig") else struct {};

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
    /// for none. Needs `-Dhttp3` (on by default) and `https`.
    http3: ?Http3 = null,
    /// HTTP/2 settings, for h2c and h2 over TLS. 250 concurrent streams per
    /// connection by default.
    http2: http.ServerConfig.Http2 = .{ .max_concurrent_streams = 250 },
    /// Executors (OS threads) for the runtime: one per CPU (cgroup-aware) by
    /// default.
    executors: ExecutorCount = .auto,
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
    /// A blocking pool (`anole.blocking`): jobs that run on threads beside
    /// the executors, at most this many at once. Password hashing uses it.
    /// Null: none, and such work runs on the request's executor.
    blocking: ?blocking.Options = null,
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
        /// QUIC interop runner tests only: also speak "hq-interop"
        /// (HTTP/0.9), serving the files under this directory.
        hq_interop_root: ?[]const u8 = null,
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

    pub const Cert = union(enum) {
        /// PEM text in memory, copied by `init`.
        pem: struct { cert: []const u8, key: []const u8 },
        /// PEM files, read when the server starts.
        files: struct { cert_path: []const u8, key_path: []const u8 },
        /// A fresh self-signed certificate for localhost, held in memory:
        /// for development only.
        dev_self_signed,
    };
};

pub fn Server(comptime Ctx: type) type {
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
        /// The TLS listener's certificate, for `reloadCertificates`; null
        /// without `https`.
        cert: ?*CertState = null,
        /// Middleware the server copied (`use`, `group`, `middleware`),
        /// deinitialized with it.
        owned_middleware: std.ArrayList(http.Middleware(Ctx)) = .empty,

        const H3Endpoint = if (features.http3) ?*h3.Endpoint(Ctx) else void;

        /// The TLS listener's certificate: the PEM in use, where a reload
        /// reads it again, and the listener configuration dusty serves
        /// from, whose `pem` a reload points at the new one.
        const CertState = struct {
            gpa: std.mem.Allocator,
            /// One reload at a time.
            mutex: std.Io.Mutex = .init,
            /// Owned, the key zeroed when freed.
            pem: Pem,
            /// For `.files`: the paths each reload reads again. Owned.
            files: ?struct { cert_path: []u8, key_path: []u8 } = null,
            listener: *http.Listener,

            const Pem = struct {
                cert: []u8,
                key: []u8,

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
                        const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io_, f.cert_path, gpa, .limited(max_pem_len));
                        errdefer gpa.free(cert_pem);
                        return .{ .cert = cert_pem, .key = try std.Io.Dir.cwd().readFileAlloc(io_, f.key_path, gpa, .limited(max_pem_len)) };
                    },
                    .dev_self_signed => {
                        if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
                        const made = try tls.selfSigned(gpa, .{});
                        return .{ .cert = made.cert, .key = made.key };
                    },
                }
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

        /// `Alt-Svc` on responses that did not come over HTTP/3.
        const AltSvc = struct {
            value: []const u8,

            pub fn execute(self: *const AltSvc, req: *http.Request, res: *http.Response, executor: anytype) !void {
                if (req.version_major != 3) try res.header("Alt-Svc", self.value);
                return executor.next();
            }
        };

        pub fn init(gpa: std.mem.Allocator, opts: Options, ctx: if (Ctx == void) void else *Ctx) !Self {
            // zio binds the runtime to this thread (its first executor), and
            // a second runtime would take the thread over from the first.
            if (server_on_thread) return error.ServerAlreadyOnThread;
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            errdefer {
                arena.deinit();
                gpa.destroy(arena);
            }
            const a = arena.allocator();

            const rt = try zio.Runtime.init(gpa, .{ .executors = opts.executors });
            errdefer rt.deinit();
            const rt_io = rt.io();
            server_on_thread = true;
            errdefer server_on_thread = false;

            // One accept loop per executor (dusty's default on zio); on
            // Linux each with its own SO_REUSEPORT socket, so the kernel
            // spreads connections over the executors.
            // Hand-off needs one socket per listener, which we open (or
            // inherit) ourselves.
            const handoff_mode = opts.process != null;
            const per_core_sockets = builtin.os.tag == .linux and !handoff_mode;
            const inherited = if (opts.process) |p| handoff.inherited(p.environ) else null;
            var held: std.ArrayList(handoff.Listener) = .empty;
            var listeners: std.ArrayList(http.Listener) = .empty;
            const http_opts: ?Options.Http = opts.http orelse if (opts.https == null) .{} else null;
            if (http_opts) |h| {
                const address = try std.Io.net.IpAddress.parse(h.address, h.port);
                const fd = try listenerFd(rt_io, inherited, handoff_mode, "http", 0, address);
                if (fd) |f| try held.append(a, .{ .fd = f, .name = "http" });
                try listeners.append(a, .{
                    .address = .{ .ip = address },
                    .http2_prior_knowledge = h.h2c and features.http2,
                    .socket_per_acceptor = per_core_sockets,
                    .proxy_protocol = h.proxy_protocol,
                    .fd = fd,
                });
            }
            // The certificate is read here, files included, and handed to
            // dusty (and HTTP/3) as PEM: a reload reads it again the same way.
            var cert_state: ?*CertState = null;
            errdefer if (cert_state) |cs| cs.deinit();
            if (opts.https) |h| {
                if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
                const cs = try a.create(CertState);
                cs.* = .{ .gpa = gpa, .pem = try CertState.load(gpa, rt_io, h.cert), .listener = undefined };
                cert_state = cs;
                try cs.setSource(h.cert);
                const config: http.ServerConfig.Tls = .{
                    .alpn_protocols = h.alpn_protocols orelse
                        if (features.http2) &.{ "h2", "http/1.1" } else &.{"http/1.1"},
                    .client_auth = h.client_auth,
                    .pem = .{ .cert = cs.pem.cert, .key = cs.pem.key },
                };
                const address = try std.Io.net.IpAddress.parse(h.address, h.port);
                const fd = try listenerFd(rt_io, inherited, handoff_mode, "https", listeners.items.len, address);
                if (fd) |f| try held.append(a, .{ .fd = f, .name = "https" });
                try listeners.append(a, .{
                    .address = .{ .ip = address },
                    .socket_per_acceptor = per_core_sockets,
                    .proxy_protocol = h.proxy_protocol,
                    .tls = config,
                    .fd = fd,
                });
            }
            if (listeners.items.len == 0) return error.NoListeners;
            // The HTTPS listener comes last; the list grows no more.
            if (cert_state) |cs| cs.listener = &listeners.items[listeners.items.len - 1];

            var server_config = opts.server;
            server_config.listeners = listeners.items;
            server_config.http2 = opts.http2;
            const server = try a.create(http.Server(Ctx));
            server.* = .init(gpa, rt_io, server_config, ctx);
            const stopped = try a.create(std.Io.Event);
            stopped.* = .unset;

            var endpoint: H3Endpoint = if (features.http3) null else {};
            if (opts.http3) |q| {
                if (comptime !features.http3) return error.Http3NotBuilt;
                if (comptime features.http3) {
                    const https = opts.https orelse return error.Http3NeedsHttps;
                    // Mutual TLS: the same CAs and mode as the TCP listener,
                    // loaded once more here (dusty loads its own when it
                    // starts listening).
                    var client_ca: ?std.crypto.Certificate.Bundle = null;
                    defer if (client_ca) |*b| b.deinit(gpa);
                    if (https.client_auth) |ca| client_ca = try ca.ca.load(gpa, rt_io);
                    // The UDP socket: inherited (`h3`, or by position after
                    // the TCP listeners), with the predecessor's secret.
                    const h3_fd: ?handoff.Fd = if (inherited) |inh| inh.find("h3", listeners.items.len) else null;
                    const secret: ?[32]u8 = if (h3_fd != null) handoff.inheritedSecret(opts.process.?.environ) else null;
                    const ep = try h3.Endpoint(Ctx).init(gpa, rt_io, server, .{
                        .address = try std.Io.net.IpAddress.parse(q.address orelse https.address, q.port orelse https.port),
                        .cert_pem = cert_state.?.pem.cert,
                        .key_pem = cert_state.?.pem.key,
                        .max_streams_bidi = q.max_streams_bidi,
                        .validate_address = q.validate_address,
                        .idle_timeout_ms = q.idle_timeout_ms,
                        .hq_interop_root = q.hq_interop_root,
                        .client_auth = h3ClientAuth(https.client_auth, client_ca),
                        .fd = h3_fd,
                        .secret = secret,
                        // The same drain deadline as HTTP/1.1 and HTTP/2.
                        .drain_timeout_ms = if (server.config.timeout.shutdown) |d|
                            @intCast(@min(@max(d.toMilliseconds(), 0), std.math.maxInt(u32)))
                        else
                            std.math.maxInt(u32),
                    });
                    errdefer ep.deinit();
                    endpoint = ep;
                    if (handoff_mode) try held.append(a, .{ .fd = ep.udp.socket.handle, .name = "h3" });
                    if (q.alt_svc) {
                        const alt = try a.create(AltSvc);
                        alt.* = .{ .value = try std.fmt.allocPrint(a, "h3=\":{d}\"; ma=86400", .{ep.address().getPort()}) };
                        server.router.use(http.Middleware(Ctx).init(alt));
                    }
                }
            }
            var pool: ?*blocking.Pool = null;
            if (opts.blocking) |b| {
                const p = try a.create(blocking.Pool);
                try p.init(rt, b);
                pool = p;
            }
            return .{
                .gpa = gpa,
                .rt = rt,
                .arena = arena,
                .server = server,
                .router = &server.router,
                .stopped = stopped,
                .process = opts.process,
                .held = held.items,
                .restart_timeout_ms = opts.restart_timeout_ms,
                .h3 = endpoint,
                .blocking_pool = pool,
                .cert = cert_state,
            };
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
        fn listenerFd(io_: std.Io, inherited: ?handoff.Inherited, handoff_mode: bool, name: []const u8, index: usize, address: std.Io.net.IpAddress) !?handoff.Fd {
            if (!handoff_mode) return null;
            if (inherited) |inh| if (inh.find(name, index)) |fd| return fd;
            const s = try address.listen(io_, .{ .reuse_address = true });
            return s.socket.handle;
        }

        pub fn deinit(self: *Self) void {
            if (comptime features.http3) if (self.h3) |ep| ep.deinit();
            self.server.deinit();
            // Last added, first freed.
            var i = self.owned_middleware.items.len;
            while (i > 0) {
                i -= 1;
                self.owned_middleware.items[i].deinit();
            }
            if (self.cert) |cs| cs.deinit();
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

        /// A copy of `value`, a middleware (a struct with `execute`), that
        /// the server owns: freed with it, after its `deinit` if it has one.
        /// The handle can go into several groups. A handle given in place of
        /// a value is returned as it is.
        pub fn middleware(self: *Self, value: anytype) http.Middleware(Ctx) {
            const T = @TypeOf(value);
            if (T == http.Middleware(Ctx)) return value;
            const copy = self.arena.allocator().create(T) catch @panic("OOM");
            copy.* = value;
            const handle = http.Middleware(Ctx).init(copy);
            self.owned_middleware.append(self.arena.allocator(), handle) catch @panic("OOM");
            return handle;
        }

        /// Adds a global middleware, run before every route, in the order
        /// added. Before the routes, as `Router.use` requires. A value is
        /// copied and owned by the server (see `middleware`).
        pub fn use(self: *Self, value: anytype) void {
            self.router.use(self.middleware(value));
        }

        pub fn get(self: *Self, path: []const u8, handler: Handler) void {
            self.router.get(path, handler);
        }
        pub fn head(self: *Self, path: []const u8, handler: Handler) void {
            self.router.head(path, handler);
        }
        pub fn post(self: *Self, path: []const u8, handler: Handler) void {
            self.router.post(path, handler);
        }
        pub fn put(self: *Self, path: []const u8, handler: Handler) void {
            self.router.put(path, handler);
        }
        pub fn patch(self: *Self, path: []const u8, handler: Handler) void {
            self.router.patch(path, handler);
        }
        pub fn delete(self: *Self, path: []const u8, handler: Handler) void {
            self.router.delete(path, handler);
        }
        pub fn options(self: *Self, path: []const u8, handler: Handler) void {
            self.router.options(path, handler);
        }
        /// The HTTP QUERY method (a GET with a body).
        pub fn query(self: *Self, path: []const u8, handler: Handler) void {
            self.router.query(path, handler);
        }
        pub fn any(self: *Self, path: []const u8, handler: Handler) void {
            self.router.any(path, handler);
        }

        /// Serves the files under `dir` below `prefix`: ranges, ETags and
        /// conditional requests, and precompressed copies (`style.css.br`,
        /// `.zst`, `.gz`) when `opts.precompressed` lists them. `dir` must
        /// stay open while the server runs.
        pub fn static(self: *Self, prefix: []const u8, dir: std.Io.Dir, opts: http.StaticOptions) void {
            self.router.static(prefix, dir, opts);
        }

        /// Serves `data` (usually `@embedFile`) at `path`.
        pub fn embedded(self: *Self, path: []const u8, data: []const u8, opts: http.EmbeddedOptions) void {
            self.router.embedded(path, data, opts);
        }

        /// Routes under `prefix`, behind `middlewares` (after the global
        /// ones): a tuple whose values are copied and owned by the server,
        /// as with `use`, and whose handles (`middleware`, or
        /// `anole.Middleware(Ctx).init(&value)` for a value you keep) are
        /// taken as they are. A slice of handles works too.
        pub fn group(self: *Self, prefix: []const u8, middlewares: anytype) Group {
            return .{ .server = self, .inner = self.router.group(prefix, self.handles(middlewares)) };
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
            pub fn get(g: Group, path: []const u8, handler: Handler) void {
                g.inner.get(path, handler);
            }
            pub fn head(g: Group, path: []const u8, handler: Handler) void {
                g.inner.head(path, handler);
            }
            pub fn post(g: Group, path: []const u8, handler: Handler) void {
                g.inner.post(path, handler);
            }
            pub fn put(g: Group, path: []const u8, handler: Handler) void {
                g.inner.put(path, handler);
            }
            pub fn patch(g: Group, path: []const u8, handler: Handler) void {
                g.inner.patch(path, handler);
            }
            pub fn delete(g: Group, path: []const u8, handler: Handler) void {
                g.inner.delete(path, handler);
            }
            pub fn options(g: Group, path: []const u8, handler: Handler) void {
                g.inner.options(path, handler);
            }
            pub fn query(g: Group, path: []const u8, handler: Handler) void {
                g.inner.query(path, handler);
            }
            pub fn any(g: Group, path: []const u8, handler: Handler) void {
                g.inner.any(path, handler);
            }
            pub fn static(g: Group, prefix: []const u8, dir: std.Io.Dir, opts: http.StaticOptions) void {
                g.inner.static(prefix, dir, opts);
            }
            pub fn embedded(g: Group, path: []const u8, data: []const u8, opts: http.EmbeddedOptions) void {
                g.inner.embedded(path, data, opts);
            }
        };

        /// Loads the TLS certificate and key again (from their files, for
        /// `.files`) and the client CAs of `https.client_auth` (from theirs),
        /// and switches the HTTPS listener and HTTP/3 to them. Connections
        /// that start from then on get the new ones; connections already
        /// open, handshakes in progress included, keep theirs. Session
        /// tickets issued before still resume. SIGHUP calls it while `run`
        /// serves.
        ///
        /// On an error (a file missing, a key that does not match the
        /// certificate) nothing changes: the server goes on with what it
        /// had. Call it from a task of the server's runtime (`io()`); one
        /// reload runs at a time.
        pub fn reloadCertificates(self: *Self) !void {
            const cs = self.cert orelse return error.NoTlsListener;
            const io_ = self.rt.io();
            try cs.mutex.lock(io_);
            defer cs.mutex.unlock(io_);
            var next: CertState.Pem = if (cs.files) |f|
                try CertState.load(cs.gpa, io_, .{ .files = .{ .cert_path = f.cert_path, .key_path = f.key_path } })
            else
                try CertState.load(cs.gpa, io_, .{ .pem = .{ .cert = cs.pem.cert, .key = cs.pem.key } });
            errdefer next.deinit(cs.gpa);
            try self.switchCertificate(cs, next);
        }

        /// As `reloadCertificates`, from `cert` instead: new PEM in memory,
        /// other files, or a fresh development certificate. On success it
        /// becomes the source later reloads (and SIGHUP) read again.
        pub fn setCertificate(self: *Self, cert: Options.Cert) !void {
            const cs = self.cert orelse return error.NoTlsListener;
            const io_ = self.rt.io();
            try cs.mutex.lock(io_);
            defer cs.mutex.unlock(io_);
            var next = try CertState.load(cs.gpa, io_, cert);
            errdefer next.deinit(cs.gpa);
            try self.switchCertificate(cs, next);
            // In place now; only the paths are left to remember.
            cs.setSource(cert) catch |err| {
                std.log.scoped(.anole).warn("certificate in use, but its source is not remembered for the next reload: {t}", .{err});
                cs.freeSource();
            };
        }

        /// Puts `next` in place on the TCP listener and HTTP/3, or neither.
        /// Takes `next` on success. Under `cs.mutex`.
        fn switchCertificate(self: *Self, cs: *CertState, next: CertState.Pem) !void {
            const listener_tls = &cs.listener.tls.?;
            // HTTP/3's context first: it checks the certificate and key, and
            // is dropped if the TCP listener's reload fails.
            var quic: if (features.http3) ?h3.TlsContext else void = if (features.http3) null else {};
            if (comptime features.http3) if (self.h3) |ep| {
                var client_ca: ?std.crypto.Certificate.Bundle = null;
                defer if (client_ca) |*b| b.deinit(cs.gpa);
                if (listener_tls.client_auth) |ca| client_ca = try ca.ca.load(cs.gpa, self.rt.io());
                quic = try ep.loadTls(next.cert, next.key, h3ClientAuth(listener_tls.client_auth, client_ca));
            };
            errdefer if (comptime features.http3) if (quic) |*q| q.deinit();

            const before = listener_tls.pem;
            listener_tls.pem = .{ .cert = next.cert, .key = next.key };
            self.server.reloadTls() catch |err| {
                listener_tls.pem = before;
                return err;
            };
            if (comptime features.http3) if (quic) |q| self.h3.?.useTls(q);
            cs.pem.deinit(cs.gpa);
            cs.pem = next;
        }

        /// Ends `run`, as a signal would: the server drains and `run`
        /// returns. Safe from any task or thread of the runtime.
        pub fn stop(self: *Self) void {
            self.stopped.set(self.rt.io());
        }

        /// The bound address of each listener (`http` first), once serving;
        /// a listener given port 0 has its real port here.
        pub fn addresses(self: *const Self) []const http.Address {
            return self.server.addresses;
        }

        /// Waits until the listeners are bound.
        pub fn waitReady(self: *Self) !void {
            try self.server.ready.wait(self.rt.io());
        }

        /// Serves until SIGINT, SIGTERM or `stop`, then stops accepting and
        /// drains the requests in flight (bounded by `timeout.shutdown`).
        /// Call it from the thread that called `init`.
        pub fn run(self: *Self) !void {
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
            if (self.cert != null) try sel.concurrent(.reload, reloadOnHangup, .{self});
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
            server.ready.wait(rt_io) catch return;
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
            const h2c = @import("h2/client.zig");
            {
                const conn = try h2c.ClientConnection.connect(alloc, io_, .{
                    .host = "localhost",
                    .port = port,
                    .tls = .{ .root_ca = bundle, .certificate = .{ .cert_pem = p.cert, .key_pem = p.key } },
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
                .tls = .{ .root_ca = bundle },
                .handshake_timeout_ms = 3000,
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
                .tls = .{ .root_ca = bundle, .certificate = .{ .cert_pem = p.cert, .key_pem = p.key } },
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
    const h2c = @import("h2/client.zig");

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

    fn h2(io_: std.Io, port: u16, ca: std.crypto.Certificate.Bundle) !*h2c.ClientConnection {
        return h2c.ClientConnection.connect(alloc, io_, .{ .host = "localhost", .port = port, .tls = .{ .root_ca = ca } });
    }

    fn h3c(io_: std.Io, q: std.Io.net.IpAddress, ca: std.crypto.Certificate.Bundle) !*h3.ClientConnection {
        return h3.ClientConnection.connect(alloc, io_, .{
            .host = "localhost",
            .address = q,
            .port = q.getPort(),
            .tls = .{ .root_ca = ca },
            .handshake_timeout_ms = 3000,
        });
    }

    /// New connections over all three protocols verify against `ca` alone.
    fn serves(a: *Server(void), dir: std.Io.Dir, ca_name: []const u8, ca: std.crypto.Certificate.Bundle) !void {
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
            const alloc = std.testing.allocator;
            try a.waitReady();
            var cas: [4]std.crypto.Certificate.Bundle = undefined;
            var loaded: usize = 0;
            defer for (cas[0..loaded]) |*b| b.deinit(alloc);
            while (loaded < cas.len) : (loaded += 1) cas[loaded] = try tls.testing.bundleFromPem(alloc, std.Io.Clock.real.now(io_).toSeconds(), p[loaded].cert);
            const port = a.addresses()[0].ip.getPort();

            try ReloadCheck.serves(a, dir, "ca0.pem", cas[0]);
            // Connections that outlive the reloads.
            const old2 = try ReloadCheck.h2(io_, port, cas[0]);
            defer old2.close();
            try ReloadCheck.request(old2);
            const old3 = try ReloadCheck.h3c(io_, a.http3Address().?, cas[0]);
            defer old3.close();
            try ReloadCheck.request(old3);

            // reloadCertificates reads the files again.
            try dir.writeFile(io_, .{ .sub_path = "cert.pem", .data = p[1].cert });
            try dir.writeFile(io_, .{ .sub_path = "key.pem", .data = p[1].key });
            try a.reloadCertificates();
            try ReloadCheck.serves(a, dir, "ca1.pem", cas[1]);
            try std.testing.expect(std.meta.isError(ReloadCheck.h1(io_, port, dir, "ca0.pem")));
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);

            // A key that does not go with the certificate: refused, and
            // nothing changes.
            try dir.writeFile(io_, .{ .sub_path = "key.pem", .data = p[2].key });
            try std.testing.expect(std.meta.isError(a.reloadCertificates()));
            try ReloadCheck.serves(a, dir, "ca1.pem", cas[1]);

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
            try ReloadCheck.serves(a, dir, "ca2.pem", cas[2]);

            // setCertificate: PEM in memory.
            try a.setCertificate(.{ .pem = .{ .cert = p[3].cert, .key = p[3].key } });
            try ReloadCheck.serves(a, dir, "ca3.pem", cas[3]);
            try ReloadCheck.request(old2);
            try ReloadCheck.request(old3);
        }
    };
    var client_future = try app.io().concurrent(Run.run, .{ &app, &pems, tmp.dir });
    try app.run();
    try client_future.await(app.io());
}

test "anole.Server: a second server on the same thread is refused, and one after the first is freed is fine" {
    const gpa = std.testing.allocator;
    var first = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {});
    try std.testing.expectError(error.ServerAlreadyOnThread, Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {}));
    first.deinit();
    var second = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {});
    second.deinit();
}

test "anole.Server: http listens on 127.0.0.1:8080 when nothing is set" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{ .executors = .exact(1) }, {});
    defer app.deinit();
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
