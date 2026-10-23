//! `anole.http`, the HTTP core under `anole.Server`: the HTTP/1.1 server
//! and its HTTP/2 engine, the router, middleware, static files, and the
//! outbound client. Adapted from lalinsky/dusty (MIT); part of Anole, in
//! src/http/core.
//!
//! Most applications need only `anole.App` or `anole.Server`, which wrap
//! this; reach here for settings and types they pass through
//! (`ServerConfig`, `StaticOptions`, `Status`, `Headers`) or to drive the
//! core directly. Handlers have the shape `fn (*Request, *Response) !void`,
//! or `fn (*Ctx, *Request, *Response) !void` for a `Server(Ctx)`.
const std = @import("std");
const dusty = @import("dusty");

/// The core server on a `std.Io` you run yourself: no runtime, signals or
/// TLS setup of its own. `anole.Server` builds on it and exposes it as
/// `app.server`.
pub const Server = dusty.Server;
/// The core server's settings: timeouts, limits, listeners, HTTP/2. Anole
/// builds it from `anole.ServerOptions`; use that unless you drive the core
/// alone.
pub const ServerConfig = dusty.ServerConfig;
/// An IP address and port, or a Unix socket path.
pub const Address = dusty.Address;
/// One socket the core server accepts on (`ServerConfig.listeners`);
/// `req.listener` points at the one a request came in on.
pub const Listener = dusty.Listener;
/// A peer range for `Listener.proxy_protocol_from` ("10.0.0.0/8").
pub const ProxyNetwork = dusty.ProxyNetwork;
/// The named groups of `proxy.trusted`: `loopback`, `private`, `link_local`.
pub const proxy_networks = dusty.proxy_networks;
/// Whether an address is public (not loopback, private, link-local, CGNAT, unspecified or multicast).
pub const isPublicAddress = dusty.isPublicAddress;
/// The radix-tree router with `:param` and `*wildcard` segments;
/// `app.router` is one.
pub const Router = dusty.Router;
/// `anole.Request`.
pub const Request = dusty.Request;
/// `anole.Response`.
pub const Response = dusty.Response;
/// A request method (`req.method`).
pub const Method = dusty.Method;
/// A response status (`res.status`).
pub const Status = dusty.Status;
/// Request and response headers, looked up case-insensitively.
pub const Headers = dusty.Headers;
/// Path and query parameters (`req.params`, `req.query`).
pub const Params = dusty.Params;
/// The media types known by name (`res.content_type`).
pub const ContentType = dusty.ContentType;
/// A request's cookies (`req.cookies()`).
pub const Cookie = dusty.Cookie;
/// The core's middleware; `anole.middleware` re-exports them.
pub const middleware = dusty.middleware;
/// A type-erased middleware handle for a `Server(Ctx)`:
/// `anole.Middleware(Ctx).init(&value)` for a middleware value you keep.
pub const Middleware = dusty.Middleware;
/// The outbound HTTP/1.1 client (HTTP/2 by ALPN), with a connection pool.
/// Inside a server use `anole.client(req)`, which shares one.
pub const Client = dusty.Client;
/// `Client.init`'s settings.
pub const ClientOptions = dusty.ClientOptions;
/// Options for `Server.static` / `Router.static` and `Server.embedded`.
pub const StaticOptions = dusty.StaticOptions;
/// Options for `Server.embedded`.
pub const EmbeddedOptions = dusty.EmbeddedOptions;
/// `ClientOptions.tls`; `anole.h2` and `anole.h3` take the same fields.
pub const TlsOptions = dusty.TlsOptions;
/// A certificate and its key (`anole.Cert`).
pub const Cert = dusty.Cert;
/// Where trusted CAs come from (`anole.Ca`).
pub const Ca = dusty.Ca;
/// Mutual TLS on a listener (`anole.ClientAuth`).
pub const ClientAuth = dusty.ClientAuth;

/// One problem found in a request's input (`req.violations()`): where
/// (`in`), which field, a machine-readable `code`, a `message`.
pub const Violation = dusty.Violation;
/// The violations of one request, as `req.violations()` returns them.
pub const Violations = dusty.Violations;
/// An RFC 9457 problem document (`res.problem`).
pub const Problem = dusty.Problem;
/// JSON bytes as a `T` checked by its `field_rules`, without a request:
/// what `req.bind` is built on (broker messages use it too).
pub const bindJson = dusty.bindJson;
/// `bindJson`'s settings.
pub const BindOptions = dusty.BindOptions;
/// `bindJson`'s result: `.ok` or `.invalid` with the violations.
pub const BindResult = dusty.BindResult;
/// `pub const unknown_fields = .reject;` on a DTO refuses unknown keys.
pub const UnknownFields = dusty.UnknownFields;
/// The syntax check of a route pattern.
pub const route_pattern = dusty.route_pattern;

/// Using a request or response out of order (a second `req.reader()`,
/// `res.stream` after `res.body` was set): a named error, answered 500.
pub const MisuseError = dusty.MisuseError;

/// How the server writes its own error answers (`ServerConfig.errors`).
pub const ErrorFormat = dusty.ErrorFormat;
/// `ServerConfig.error_handler`: a function that answers handler errors.
pub const ErrorHandler = dusty.ErrorHandler;
/// Per-request values (`Request.locals`).
pub const Locals = dusty.Locals;
/// The status a handler error stands for, or null for a 500.
pub const errorStatus = dusty.errorStatus;
/// The default answer to a handler error, to fall back on.
pub const defaultError = dusty.defaultError;
/// Fails with `error.AddressInUse` when a socket already listens on the
/// address (which SO_REUSEPORT would silently share).
pub const checkAddressFree = dusty.checkAddressFree;
/// A listening TCP socket like `IpAddress.listen`'s, with IPV6_V6ONLY as
/// asked: `.ipv6_only = false` on `::` takes IPv4 clients too.
pub const listenIp = dusty.listenIp;
/// Sets the permission bits of a unix socket file.
pub const setUnixMode = dusty.setUnixMode;
/// An IPv4-mapped IPv6 address (`::ffff:127.0.0.1`) as the IPv4 address
/// it stands for; any other address as it is.
pub const unmapIpv4 = dusty.unmapIpv4;
/// The open-file limit (raised at startup), and the connection cap worked
/// out from it.
pub const fd_limit = dusty.fd_limit;

/// The whole HTTP core module (src/http/core), for anything not
/// re-exported above.
pub const core = dusty;

// Loopback smoke test: a dusty server and a raw TCP client as two tasks of a
// zio runtime. The harness shape is adapted from dusty's src/server_test.zig
// (testClientServer, MIT, d3cb485).
test "HTTP/1.1 smoke: GET /users/:id over loopback on zio" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;

    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const Ctx = struct {
        fn handleUser(req: *Request, res: *Response) !void {
            const id = req.params.get("id") orelse "unknown";
            try res.print(.text, "user {s}", .{id});
        }
    };

    const loopback: Address = .{ .ip = .{ .ip4 = .loopback(0) } };
    var server = Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = loopback }} }, {});
    defer server.deinit();
    server.router.get("/users/:id", Ctx.handleUser);

    var server_future = try io.concurrent(struct {
        fn run(s: *Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var response: [512]u8 = undefined;
    var client_future = try io.concurrent(struct {
        fn run(s: *Server(void), _io: std.Io, out: *[512]u8) ![]const u8 {
            try s.waitReady(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET /users/42 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [512]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            var w = std.Io.Writer.fixed(out);
            _ = reader.interface.streamRemaining(&w) catch |err| switch (err) {
                error.WriteFailed => return error.ResponseTooLarge,
                else => |e| return e,
            };
            return w.buffered();
        }
    }.run, .{ &server, io, &response });

    const got = try client_future.await(io);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nuser 42"));
}

// What the core's own test of this checks under std.Io.Threaded, here on
// zio, the runtime Anole serves on: on Windows the listener binds without
// SO_REUSEADDR and the bind refuses (std.Io.Threaded's Windows bind shares
// the address, so the core's test is skipped there).
test "port in use on zio: a second server on the same port fails instead of sharing it" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const Run = struct {
        fn run(s: *Server(void)) anyerror!void {
            try s.run();
        }
    };

    var first = Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer first.deinit();
    var first_future = try io.concurrent(Run.run, .{&first});
    defer first_future.cancel(io) catch {};
    try first.waitReady(io);

    const taken: Address = .{ .ip = first.address.ip };
    var second = Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = taken }} }, {});
    defer second.deinit();
    var second_future = try io.concurrent(Run.run, .{&second});
    defer second_future.cancel(io) catch {};
    try std.testing.expectError(error.AddressInUse, second.waitReady(io));
}

test {
    // Idle parking is off on Windows (the core's server/park.zig).
    if (@import("builtin").os.tag != .windows) _ = @import("park_test.zig");
}
