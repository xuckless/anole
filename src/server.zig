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

/// The zio configuration Anole is built for. An executable declares it in
/// its root file: `pub const zio_options = anole.zio_options;`. Pinned: a
/// connection and everything it spawns stay on one OS thread, which the
/// nghttp2 sessions, BoringSSL's error queue and zig-protobuf rely on.
pub const zio_options: zio.Options = .{ .scheduling = .pinned };

/// zio's executor count (`.auto` or `.exact(n)`), which zio does not export
/// by name.
pub const ExecutorCount = @FieldType(@typeInfo(@TypeOf(zio.Runtime.init)).@"fn".param_types[1].?, "executors");

pub const Options = struct {
    /// The cleartext listener, or null for none.
    http: ?Http = .{},
    /// The TLS listener, or null for none. Needs `-Dtls=boringssl`.
    https: ?Https = null,
    /// HTTP/2 settings, for h2c and h2 over TLS. 250 concurrent streams per
    /// connection by default.
    http2: http.ServerConfig.Http2 = .{ .max_concurrent_streams = 250 },
    /// Executors (OS threads) for the runtime: one per CPU (cgroup-aware) by
    /// default.
    executors: ExecutorCount = .auto,
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

        pub fn init(gpa: std.mem.Allocator, opts: Options, ctx: if (Ctx == void) void else *Ctx) !Self {
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

            // One accept loop per executor (dusty's default on zio); on
            // Linux each with its own SO_REUSEPORT socket, so the kernel
            // spreads connections over the executors.
            const per_core_sockets = builtin.os.tag == .linux;
            var listeners: std.ArrayList(http.Listener) = .empty;
            if (opts.http) |h| try listeners.append(a, .{
                .address = .{ .ip = try std.Io.net.IpAddress.parse(h.address, h.port) },
                .http2_prior_knowledge = h.h2c and features.http2,
                .socket_per_acceptor = per_core_sockets,
                .proxy_protocol = h.proxy_protocol,
            });
            if (opts.https) |h| {
                if (comptime features.tls != .boringssl) return error.TlsNotBuilt;
                var config: http.ServerConfig.Tls = .{
                    .alpn_protocols = h.alpn_protocols orelse
                        if (features.http2) &.{ "h2", "http/1.1" } else &.{"http/1.1"},
                    .client_auth = h.client_auth,
                };
                switch (h.cert) {
                    .pem => |p| config.pem = .{ .cert = try a.dupe(u8, p.cert), .key = try a.dupe(u8, p.key) },
                    .files => |f| {
                        config.cert_path = try a.dupe(u8, f.cert_path);
                        config.key_path = try a.dupe(u8, f.key_path);
                    },
                    .dev_self_signed => if (comptime features.tls == .boringssl) {
                        var pem = try tls.selfSigned(gpa, .{});
                        defer pem.deinit(gpa);
                        config.pem = .{ .cert = try a.dupe(u8, pem.cert), .key = try a.dupe(u8, pem.key) };
                    },
                }
                try listeners.append(a, .{
                    .address = .{ .ip = try std.Io.net.IpAddress.parse(h.address, h.port) },
                    .socket_per_acceptor = per_core_sockets,
                    .proxy_protocol = h.proxy_protocol,
                    .tls = config,
                });
            }
            if (listeners.items.len == 0) return error.NoListeners;

            var server_config = opts.server;
            server_config.listeners = listeners.items;
            server_config.http2 = opts.http2;
            const server = try a.create(http.Server(Ctx));
            server.* = .init(gpa, rt_io, server_config, ctx);
            const stopped = try a.create(std.Io.Event);
            stopped.* = .unset;
            return .{ .gpa = gpa, .rt = rt, .arena = arena, .server = server, .router = &server.router, .stopped = stopped };
        }

        pub fn deinit(self: *Self) void {
            self.server.deinit();
            self.rt.deinit();
            self.arena.deinit();
            self.gpa.destroy(self.arena);
            self.* = undefined;
        }

        /// The runtime's `std.Io`, for work beside the server.
        pub fn io(self: *const Self) std.Io {
            return self.rt.io();
        }

        /// Adds a global middleware (copied), run before every route, in the
        /// order added. Before the routes, as `Router.use` requires.
        pub fn use(self: *Self, middleware: anytype) void {
            const T = @TypeOf(middleware);
            const copy = self.arena.allocator().create(T) catch @panic("OOM");
            copy.* = middleware;
            self.router.use(http.Middleware(Ctx).init(copy));
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
        pub fn any(self: *Self, path: []const u8, handler: Handler) void {
            self.router.any(path, handler);
        }
        pub fn group(self: *Self, prefix: []const u8, middlewares: []const http.Middleware(Ctx)) http.Router(Ctx).Group {
            return self.router.group(prefix, middlewares);
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
            };
            var done_buf: [4]Done = undefined;
            var sel = std.Io.Select(Done).init(rt_io, &done_buf);
            try sel.concurrent(.int, waitForSignal, .{.interrupt});
            try sel.concurrent(.term, waitForSignal, .{.terminate});
            try sel.concurrent(.stop, waitStopped, .{ self.stopped, rt_io });
            try sel.concurrent(.served, serve, .{self.server});
            const first = try sel.await();
            // Cancels the server's run, which drains, then the watchers.
            sel.cancelDiscard();
            switch (first) {
                .served => |r| return r,
                .int, .term => std.log.scoped(.anole).info("signal received ({t}); drained and stopped", .{first}),
                .stop => {},
            }
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
