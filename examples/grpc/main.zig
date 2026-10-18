//! Anole gRPC example: the Greeter service from proto/greeter.proto and the
//! standard grpc.health.v1 service, over cleartext HTTP/2 (h2c) and TLS.
//!
//!   zig build run-grpc                  # h2c on 127.0.0.1:8083, TLS on 127.0.0.1:8483
//!   zig build run-grpc -- 9000 9443     # other ports
//!
//! The same routes also answer gRPC-Web and Buf's Connect protocol, so plain
//! curl over HTTP/1.1 works:
//!
//!   curl -H 'Content-Type: application/json' -d '{"name":"Ada"}' \
//!     http://localhost:8083/greeter.Greeter/SayHello
//!   curl -H 'Content-Type: application/json' -d '{}' \
//!     http://localhost:8083/grpc.health.v1.Health/Check
//!
//! SayHello is also a REST route, from its `google.api.http` annotation
//! (JSON transcoding):
//!
//!   curl http://localhost:8083/v1/hello/Ada
//!   curl -d '{"name":"Ada"}' http://localhost:8083/v1/hello
//!
//! And with grpcurl (h2c):
//!
//!   grpcurl -plaintext -import-path examples/grpc/proto -import-path src/grpc/proto -proto greeter.proto \
//!     -d '{"name":"Ada"}' localhost:8083 greeter.Greeter/SayHello
//!
//! SayHello shows the parts of `anole.grpc.Call` a handler uses most:
//!   - an empty name fails with INVALID_ARGUMENT (`call.fail`);
//!   - request metadata `x-salutation` replaces "hello" (`call.metadata`);
//!   - the reply carries a header and a trailer (`addHeader`, `addTrailer`);
//!   - the name "slow" takes 2 s, so a client deadline shorter than that
//!     (`grpc-timeout: 500m`, or `connect-timeout-ms: 500` for Connect) ends
//!     the call with DEADLINE_EXCEEDED.
const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;

const Call = anole.grpc.Call;

fn sayHello(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name must not be empty");

    if (std.mem.eql(u8, req.name, "slow")) {
        // Canceled when the client's deadline passes; the client then gets
        // DEADLINE_EXCEEDED, without this handler doing anything more.
        try call.io.sleep(.fromSeconds(2), .awake);
    }

    // Initial metadata goes out before the first message, trailing metadata
    // with the status.
    try call.addHeader("x-greeter", "anole");
    try call.addTrailer("x-name-length", try std.fmt.allocPrint(call.arena, "{d}", .{req.name.len}));

    const salutation = call.metadata("x-salutation") orelse "hello";
    // The reply may point into the call's arena: it lives until the reply
    // is sent.
    return .{ .message = try std.fmt.allocPrint(call.arena, "{s}, {s}", .{ salutation, req.name }) };
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8083;
    var tls_port: u16 = 8483;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| tls_port = try std.fmt.parseInt(u16, p, 10);

    // gRPC needs HTTP/2. The cleartext listener takes HTTP/2 with prior
    // knowledge (h2c) beside HTTP/1.1; the TLS one offers "h2" by ALPN.
    // gRPC-Web and Connect unary also work over HTTP/1.1 on both.
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = port, .h2c = true },
        .https = if (anole.features.tls != .none) .{ .port = tls_port, .cert = .dev_self_signed } else null,
    }, {});
    defer app.deinit();

    app.use(anole.middleware.Logger.init());

    // One POST route per method (/greeter.Greeter/SayHello), Connect GET,
    // and the REST routes of its google.api.http annotation.
    app.grpc(pb.Greeter, .{ .SayHello = sayHello });

    // grpc.health.v1.Health: Check, List and Watch. The empty service name
    // is the server as a whole and starts SERVING; every service turns
    // NOT_SERVING when the server drains.
    try app.grpcHealth().set("greeter.Greeter", .SERVING);

    std.log.info("gRPC (h2c), gRPC-Web and Connect on http://127.0.0.1:{d}", .{port});
    if (anole.features.tls != .none) std.log.info("gRPC over TLS on https://127.0.0.1:{d} (self-signed)", .{tls_port});
    try app.run();
}
