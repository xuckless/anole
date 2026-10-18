# gRPC

Anole serves gRPC services generated from `.proto` files on the same router
as your REST handlers. One registration answers four wire protocols, told
apart by the request's content type:

| Protocol | Content type | Transport |
| --- | --- | --- |
| gRPC | `application/grpc`, `application/grpc+proto` | HTTP/2 only (h2c or TLS) |
| gRPC-Web | `application/grpc-web`, `application/grpc-web-text` (`+proto`) | HTTP/1.1 or HTTP/2 |
| Connect unary | `application/proto`, `application/json` | HTTP/1.1 or HTTP/2 |
| Connect streaming | `application/connect+proto`, `application/connect+json` | HTTP/1.1 or HTTP/2 |

A gRPC request over HTTP/1.1 gets `505 HTTP Version Not Supported`, and an
unknown content type gets `415`. gRPC needs `-Dgrpc` and `-Dhttp2`, both on in
the default `full` profile.

`examples/grpc` is a runnable Greeter with the health service:

```sh
zig build run-grpc              # h2c on 127.0.0.1:8083, TLS on 127.0.0.1:8483
zig build run-grpc -- 9000 9443 # other ports
```

## Generate code

You install nothing. Anole pins protoc and zig-protobuf's `protoc-gen-zig`,
and `zig build` downloads and builds them. In your `build.zig`, give a step
the `.proto` files with `addProtoGen`, and give the generated files the
`protobuf` module that Anole exports:

```zig
const anole_build = @import("anole");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const anole_dep = b.dependency("anole", .{ .target = target, .optimize = optimize });

    const gen = b.step("gen-proto", "Generate Zig from the .proto files");
    anole_build.addProtoGen(gen, anole_dep, .{
        .source_files = &.{b.path("proto/greeter.proto")},
        .include_directories = &.{b.path("proto")}, // protoc's -I
        .destination_directory = b.path("src/gen"),
    });

    const greeter_pb = b.createModule(.{
        .root_source_file = b.path("src/gen/greeter.pb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = anole_dep.module("protobuf") }},
    });
    // ... then add `anole_dep.module("anole")` and `greeter_pb` as imports
    // of your executable's root module.
}
```

Run `zig build gen-proto` after you change a `.proto` file, and commit the
generated `.pb.zig` files like any other source. `tests/consumer` is a
complete project set up this way.

For each service, the generated file has a function that returns its method
table, for example `pb.Greeter(UserData, ErrorSet)`. Anole instantiates it with
`anole.grpc.Call` as the user data.

## Serve a service

```zig
const std = @import("std");
const anole = @import("anole");
const pb = @import("greeter_pb");

pub const zio_options = anole.zio_options;
pub const std_options: std.Options = .{ .logFn = anole.logFn };

const Call = anole.grpc.Call;

fn sayHello(call: *Call, req: pb.HelloRequest) anyerror!pb.HelloReply {
    if (req.name.len == 0) return call.fail(.invalid_argument, "name must not be empty");
    return .{ .message = try std.fmt.allocPrint(call.arena, "hello, {s}", .{req.name}) };
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = 8083 }, // HTTP/1.1, plus h2c for clients that open with HTTP/2
        .https = .{ .port = 8483, .cert = .dev_self_signed }, // ALPN h2 and http/1.1
    }, {});
    defer app.deinit();
    anole.grpc.register(void, app.router, pb.Greeter(Call, anyerror), .{ .SayHello = sayHello });
    try app.run();
}
```

`register` adds one POST route per method, `/<package>.<Service>/<Method>`,
here `/greeter.Greeter/SayHello`. Every method of the service needs a handler;
a missing one is a compile error. Middleware added with `app.use` runs for
these routes too.

With application state, use `anole.Server(App)` and `register(App, ...)`, and
reach the state from a handler with `call.state(App)`.

## Handler shapes

The method's kind comes from the generated signature. Requests and responses
that stream are `std.Io.Queue`s:

```zig
// Unary
fn unary(call: *Call, req: Req) anyerror!Resp

// Server streaming: put responses on `out`; returning ends the call.
fn serverStream(call: *Call, req: Req, out: *std.Io.Queue(Resp)) anyerror!void

// Client streaming: take requests until the queue is closed.
fn clientStream(call: *Call, in: *std.Io.Queue(Req)) anyerror!Resp

// Bidirectional streaming
fn bidi(call: *Call, in: *std.Io.Queue(Req), out: *std.Io.Queue(Resp)) anyerror!void
```

Read a request queue until it reports `error.Closed`, which means the client
has finished sending:

```zig
fn bidi(call: *Call, in: *std.Io.Queue(pb.Note), out: *std.Io.Queue(pb.Note)) anyerror!void {
    while (true) {
        const note = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        };
        try out.putOne(call.io, note);
    }
}
```

A unary handler runs on the stream's own task. For a streaming method, the
handler, the request reader and the response writer run as tasks of one
group: when one of them fails, or the deadline passes, the others are
canceled. Messages you return or queue may point into `call.arena`, which
lives until the call ends.

## The call

`anole.grpc.Call` gives a handler what it needs about the call:

| Member | What it does |
| --- | --- |
| `call.io` | The `std.Io` for async work (timers, outbound calls, files). |
| `call.arena` | The call's arena; thread-safe. |
| `call.metadata(name)` | A request metadata value by lower-case name, or null. |
| `call.addHeader(name, value)` | Initial metadata. Only before the first response message. |
| `call.addTrailer(name, value)` | Trailing metadata, sent with the status. |
| `call.fail(code, message)` | Sets the status; return what it returns. |
| `call.deadline` | The client's deadline, if it sent one. |
| `call.deadlineExceeded()` | True once the deadline has passed. |
| `call.cancelled()` | The client went away, or the deadline passed. |
| `call.state(T)` | The `Server(T)` application state. |
| `call.request_compression`, `call.protocol`, `call.codec` | How the request came in. |

In a streaming handler, add headers before the first `putOne`: the writer
task sends the response head with the first message.

### Status codes

Return `call.fail(.not_found, "no such user")` to end the call with a status.
The codes are `anole.grpc.Code`: `.ok`, `.cancelled`, `.unknown`,
`.invalid_argument`, `.deadline_exceeded`, `.not_found`, `.already_exists`,
`.permission_denied`, `.resource_exhausted`, `.failed_precondition`,
`.aborted`, `.out_of_range`, `.unimplemented`, `.internal`, `.unavailable`,
`.data_loss` and `.unauthenticated`. `Code.fromInt` converts a number.

Other errors map to a status too:

- `error.Canceled` becomes DEADLINE_EXCEEDED past the deadline, else CANCELLED;
- a request message over 4 MiB becomes RESOURCE_EXHAUSTED;
- a message that does not decode becomes INTERNAL;
- any other error becomes UNKNOWN, with the error's name as the message, so
  the client sees it. Use `call.fail` for anything you want to word yourself.

The response's HTTP status is 200 for gRPC and gRPC-Web, so an access log
shows 200 for a failed call; the gRPC status travels in the trailers.

### Deadlines and cancellation

A client sets a deadline with `grpc-timeout` (Connect: `connect-timeout-ms`).
When it passes, Anole cancels the handler: any wait on `call.io` returns
`error.Canceled`, and the client gets DEADLINE_EXCEEDED. You do not need to
check the deadline yourself while you wait on `call.io`. A call without a
deadline is not bound by the server's request timeout.

When the client resets the stream, the handler is not canceled. A handler that
waits a long time on something other than its queues checks
`call.cancelled()` between waits.

### Compression

With `-Dcompression` (on by default), Anole reads gzip request messages
(`grpc-encoding: gzip`) and compresses responses with gzip when the client's
`grpc-accept-encoding` lists it. A request in any other encoding fails with
UNIMPLEMENTED. Connect unary uses HTTP's `Content-Encoding` instead, and
compresses JSON responses only.

## Try it with curl

Connect unary is plain HTTP, so curl works over HTTP/1.1:

```sh
curl -H 'Content-Type: application/json' -d '{"name":"Ada"}' \
  http://localhost:8083/greeter.Greeter/SayHello
# {"message":"hello, Ada"}
```

Errors come back as JSON with an HTTP status that matches the code, here
`400`, and a Connect deadline as `504`:

```sh
curl -H 'Content-Type: application/json' -d '{"name":""}' \
  http://localhost:8083/greeter.Greeter/SayHello
# {"code":"invalid_argument","message":"name must not be empty"}
```

Trailing metadata appears as `trailer-<name>` headers in a Connect unary
response.

With [grpcurl](https://github.com/fullstorydev/grpcurl), pass the `.proto`
file, since Anole has no server reflection yet. Use `-plaintext` for h2c and
`-insecure` for the self-signed TLS listener:

```sh
grpcurl -plaintext -import-path examples/grpc/proto -proto greeter.proto \
  -d '{"name":"Ada"}' localhost:8083 greeter.Greeter/SayHello
```

## gRPC-Web and Connect

You need nothing extra on the server: the routes `register` adds serve them.

- gRPC-Web, binary and text (base64), works over HTTP/1.1 and HTTP/2. The
  status comes in a last body frame flagged `0x80`, so browsers can call the
  service without a proxy such as Envoy. Add CORS middleware if the page is
  on another origin.
- Connect unary (`application/proto` or `application/json`) sends one bare
  message each way. JSON follows the proto3 JSON mapping, through the
  generated `jsonEncode` and `jsonDecode`.
- Connect streaming (`application/connect+proto` or `+json`) serves all four
  call modes, with the status in an end-of-stream message.

Connect's GET form for idempotent methods is not supported yet.

## The health service

`anole.grpc.Health` serves `grpc.health.v1.Health` (Check, List and Watch):

```zig
var health: anole.grpc.Health = .init(init.gpa, app.io());
defer health.deinit();
health.registerOn(void, app.router);
try health.set("greeter.Greeter", .SERVING);
```

The empty service name is the server as a whole, and starts SERVING. Change a
status with `set(name, .NOT_SERVING)`, or mark everything NOT_SERVING with
`shutdown()`. Watch streams each change. Check on an unknown name fails with
NOT_FOUND. Keep one `Health` per process: the routes it registers read a
process-wide instance.

```sh
curl -H 'Content-Type: application/json' -d '{"service":"greeter.Greeter"}' \
  http://localhost:8083/grpc.health.v1.Health/Check
# {"status":"SERVING"}
```

This service is separate from the HTTP `/healthz` and `/readyz` in
`anole.observe`.

## The client

`anole.grpc.Client(Service)` makes typed calls over an
`anole.h2.ClientConnection`. Pass it the same generated service type the
server uses; only its names and message types matter.

```zig
const Greeter = pb.Greeter(anole.grpc.Call, anyerror);

const conn = try anole.h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = 8083 });
defer conn.close();
var channel: anole.grpc.Channel = .{ .conn = conn, .authority = "localhost" };
const client: anole.grpc.Client(Greeter) = .{ .channel = &channel };

const r = try client.unary("SayHello", arena, .{ .name = "Ada" }, .{
    .timeout = .fromSeconds(1),
    .metadata = &.{.{ .name = "x-salutation", .value = "hi" }},
});
if (r.status.code == .ok) std.log.info("{s}", .{r.message.?.message});
```

`io` is the runtime's `std.Io`: `req.io` or `call.io` in a handler. Results
and received messages live in `arena`. `r.headers` and `r.trailers` hold the
response metadata.

`CallOptions` takes a `timeout` (sent as `grpc-timeout`), extra `metadata`
with lower-case names, and `compression = .gzip`.

For TLS, connect with `.tls = .{ .root_ca = bundle }` (or
`.insecure_skip_verify = true` against a development certificate) and set
`.scheme = "https"` on the channel. The connection negotiates `h2` by ALPN.

Every call mode goes through `stream`:

```zig
var s = try client.stream("Chat", arena, .{});
defer s.deinit();
try s.send(.{ .text = "a" });
try s.closeSend();
while (try s.receive()) |reply| {
    // ...
}
const status = s.status.?; // set once receive returns null
```

`s.cancel()` resets the call. `anole.grpc.openCall` opens a call by path, for
code without a generated service type. A non-200 HTTP answer (from a proxy,
say) maps to gRPC's codes, and a call that ends without a status after its
deadline reports DEADLINE_EXCEEDED.

## Interop

grpc-go v1.84.0's interop client passes all 14 cases it runs against Anole's
server over h2c (`tests/grpc/interop/run.sh`), and Anole's client passes 11
cases against grpc-go's server (`tests/grpc/interop/run-client.sh`). Both run
in CI. The same cases over TLS, and grpc's `http2_interop` suite, are not run
yet. For benchmark numbers against grpc-go, see the README.

## Not there yet

- JSON transcoding from `google.api.http` annotations (REST routes for gRPC
  methods). Connect's JSON covers many of the same uses meanwhile.
- gRPC over HTTP/3. Native gRPC runs over HTTP/2 only.
- Server reflection.
- Connect GET requests.
- A configurable message size limit on the server: it is 4 MiB. The client's
  is `Channel.max_message_size`, also 4 MiB by default.
- Canceling a handler when the client resets its stream (use
  `call.cancelled()`).
