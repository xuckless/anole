//! {{name}}: a gRPC service that also speaks REST and Connect.
//!
//!   zig build run          # http://localhost:3000 (HTTP/1.1 and h2c), docs at /docs
//!   zig build test         # the REST and Connect forms, in memory
//!   zig build openapi      # writes openapi.json: the REST and Connect forms
//!
//! The Greeter service is proto/greeter.proto; `zig build` generates its Zig
//! code (nothing to install). See the README for grpcurl and curl calls.
const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

/// Keeps the runtime's per-thread lines out of a Debug build.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const Call = anole.grpc.Call;

fn sayHello(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name must not be empty");
    // The reply may point into the call's arena: it lives until it is sent.
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

fn lookup(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    return .{ .message = try std.fmt.allocPrint(call.arena, "hi again, {s}", .{req.name}) };
}

/// Apart from `main` so that src/main_test.zig serves the same routes.
pub fn routes(app: *anole.App) !void {
    // One POST route per method (/greeter.Greeter/SayHello), Connect GET for
    // the idempotent one, and the REST routes of google.api.http.
    app.grpc(pb.Greeter, .{ .SayHello = sayHello, .Lookup = lookup });
    // grpc.health.v1.Health: the server and each service SERVING until drain.
    try app.grpcHealth().set("greeter.Greeter", .SERVING);
}

pub fn main(init: std.process.Init) !void {
    // gRPC needs HTTP/2: the cleartext listener takes it with prior
    // knowledge (h2c) beside HTTP/1.1.
    var app = try anole.App.init(init.gpa, .{ .http = .{ .port = 3000, .h2c = true } });
    defer app.deinit();
    app.use(anole.observe.AccessLog.init(.{}));
    app.openapi(.{ .info = .{ .title = "{{name}}", .version = "0.1.0" } });
    try routes(&app);
    try app.run();
}
