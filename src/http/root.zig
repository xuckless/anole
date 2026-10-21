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
/// The core server's settings: timeouts, limits, listeners, HTTP/2.
/// `anole.ServerOptions.server` takes it.
pub const ServerConfig = dusty.ServerConfig;
/// An IP address and port, or a Unix socket path.
pub const Address = dusty.Address;
/// One socket the core server accepts on (`ServerConfig.listeners`);
/// `req.listener` points at the one a request came in on.
pub const Listener = dusty.Listener;
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
pub const ClientConfig = dusty.ClientConfig;
/// Options for `Server.static` / `Router.static` and `Server.embedded`.
pub const StaticOptions = dusty.StaticOptions;
/// Options for `Server.embedded`.
pub const EmbeddedOptions = dusty.EmbeddedOptions;
/// `ClientConfig.tls`; `anole.h2` and `anole.h3` take the same fields.
pub const TlsConfig = dusty.TlsConfig;
/// Where a client's trusted CAs come from: the system store, a file, a
/// directory, or PEM in memory.
pub const TlsCa = dusty.TlsCa;

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

test {
    _ = @import("park_test.zig");
}
