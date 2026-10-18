//! HTTP/1.1: re-exports lalinsky/dusty (MIT), wired to the real zio runtime.
//! Handlers have the shape `fn (*Request, *Response) !void`, or
//! `fn (*Ctx, *Request, *Response) !void` for a `Server(Ctx)`.
const std = @import("std");
const dusty = @import("dusty");

pub const Server = dusty.Server;
pub const ServerConfig = dusty.ServerConfig;
pub const Address = dusty.Address;
pub const Listener = dusty.Listener;
pub const Router = dusty.Router;
pub const Request = dusty.Request;
pub const Response = dusty.Response;
pub const Method = dusty.Method;
pub const Status = dusty.Status;
pub const Headers = dusty.Headers;
pub const Params = dusty.Params;
pub const ContentType = dusty.ContentType;
pub const Cookie = dusty.Cookie;
pub const middleware = dusty.middleware;
pub const Middleware = dusty.Middleware;
pub const Client = dusty.Client;
pub const ClientConfig = dusty.ClientConfig;
/// Options for `Server.static` / `Router.static` and `Server.embedded`.
pub const StaticOptions = dusty.StaticOptions;
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

/// The whole dusty module, for anything not re-exported above.
pub const dusty_module = dusty;

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
