# gRPC

Up: [index](index.md). Full docs: docs/grpc.md, docs/clients.md (gRPC). Examples: examples/grpc, templates/grpc, templates/full.
Related: [server-routes.md](server-routes.md), [openapi.md](openapi.md), [middleware](../middleware-auth/middleware.md).

One registration serves gRPC, gRPC-Web, Connect and (for methods with `google.api.http`) JSON REST routes on the same router as the REST handlers. Needs `-Dgrpc` and `-Dhttp2` (on in `full`). Do not install protoc: `addApp`'s `.protos` generates the Zig code during `zig build`.

## Generate code

```zig
pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "greeter",
        .root_source_file = b.path("src/main.zig"),
        .protos = &.{.{ .name = "greeter_pb", .file = b.path("proto/greeter.proto") }},
    });
}
```

The program imports the proto by its `name`: `const pb = @import("greeter_pb");`.

## Serve a service: `app.grpc`

Use: `anole.App.grpc`, `anole.App.grpcWith` (src/server.zig), also on groups; `anole.grpc.Call` (src/grpc/server.zig).

```zig
const Call = anole.grpc.Call;

fn sayHello(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name must not be empty");
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{ .http = .{ .port = 3000, .h2c = true } });
    defer app.deinit();
    app.grpc(pb.Greeter, .{ .SayHello = sayHello });
    try app.run();
}
```

- Handlers come as a struct literal (above), a type declaring them by method name, or a pointer to a value whose methods take it first (`app.grpc(pb.Greeter, &greeter)`; the value must outlive the server).
- On `anole.Server(App)`, reach the state with `call.state(App)`.
- `call.fail(code, message)` ends the call with a gRPC status; `call.arena` lives until the call ends; `call.io` is the call's `std.Io`.

Streaming shapes come from the generated signature; streams are `std.Io.Queue`s:

```zig
fn serverStream(call: *Call, req: Req, out: *std.Io.Queue(Resp)) anyerror!void
fn clientStream(call: *Call, in: *std.Io.Queue(Req)) anyerror!Resp
fn bidi(call: *Call, in: *std.Io.Queue(Req), out: *std.Io.Queue(Resp)) anyerror!void
```

Read a request queue until `error.Closed` (the client finished sending).

Traps:
- Every method of the service needs a handler: a missing one is a compile error.
- gRPC needs HTTP/2: over HTTP/1.1 a gRPC request gets 505. A cleartext listener needs h2c (`.h2c = true` above); `listenTls` gives ALPN h2.
- `app.grpc` registers behind the global middleware only. For auth on a service, register through a group: `app.with(.{auth}).grpc(...)` or `app.group("/v1", .{auth}).grpc(...)`. The group prefix does not apply (paths come from the proto).

## Per-registration options: `grpcWith`

Use: `anole.grpc.RegisterOptions` (src/grpc/root.zig).

```zig
app.grpcWith(pb.Greeter, .{ .SayHello = sayHello }, .{
    .max_message_size = 64 * 1024, // default anole.grpc.default_max_message_size, 4 MiB
    .data = &greeter_state, // `call.data` in each handler of this registration
    .transcode = false, // gRPC routes only
    .response_compression = .accepted, // default .mirror; see Compression
    .no_wait = true, // the unary handlers never wait; see below
    .max_received_bytes = 16 * 1024 * 1024, // default 64 MiB per call
    .read_timeout = .fromSeconds(10), // default 30 s per request message
    .max_call_duration = .fromSeconds(600), // default none
});
```

Traps:
- `.no_wait = true` has the same promise as `anole.noWait` ([server-routes.md](server-routes.md#handlers-that-never-wait-anolenowait)): no database or other service in those unary handlers.
- Without `max_call_duration`, a call whose client sent no deadline runs as long as its handler does.

## Health service: `app.grpcHealth`

Use: `anole.App.grpcHealth` (src/server.zig), `anole.grpc.Health` (src/grpc/health.zig). The server owns it and marks every service NOT_SERVING when it starts to drain.

```zig
try app.grpcHealth().set("greeter.Greeter", .SERVING);
```

This is separate from the HTTP `/healthz` and `/readyz` ([observability.md](../observability.md)).

## Calling gRPC services

`anole.grpc.Client(Service)` over an `anole.grpc.Channel` (src/grpc/root.zig): see docs/grpc.md (The client) and [storage-email-clients](../storage-email-clients/index.md).
