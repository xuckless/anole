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

Methods annotated with `google.api.http` also get REST routes of their own,
JSON in and out ([JSON transcoding](#json-transcoding)).

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
generated `.pb.zig` files like any other source. `addProtoGen` also puts
Anole's copies of `google/api/annotations.proto` and `google/api/http.proto`
on protoc's include path, so a file can import them for
[JSON transcoding](#json-transcoding) without vendoring them; the code for
their packages is generated beside yours (`google/api.pb.zig`, and
`google/protobuf.pb.zig` for descriptor.proto). `tests/consumer` is a
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

`registerWith` takes options for one registration:

```zig
anole.grpc.registerWith(void, app.router, pb.Greeter(Call, anyerror), .{ .SayHello = sayHello }, .{
    .max_message_size = 64 * 1024, // default anole.grpc.default_max_message_size, 4 MiB
    .data = &greeter_state, // `call.data` in each handler of this registration
});
```

`max_message_size` bounds each request message after decompression; a larger
one fails the call with RESOURCE_EXHAUSTED. `data` is for handlers that serve
more than one registration, such as the same service on two servers.

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
| `call.addHeader(name, value)` | Initial metadata. `error.HeadersSent` once the first response message has gone out. |
| `call.addTrailer(name, value)` | Trailing metadata, sent with the status. |
| `call.fail(code, message)` | Sets the status; return what it returns. |
| `call.deadline` | The client's deadline, if it sent one. |
| `call.deadlineExceeded()` | True once the deadline has passed. |
| `call.cancelled()` | The client went away, or the deadline passed. |
| `call.state(T)` | The `Server(T)` application state. |
| `call.data` | `RegisterOptions.data` of the registration, or null. |
| `call.request_compression`, `call.protocol`, `call.codec` | How the request came in. |

In a streaming handler, add headers before the first `putOne`: the writer
task sends the response head with the first message, and once it has,
`addHeader` returns `error.HeadersSent`.

### Status codes

Return `call.fail(.not_found, "no such user")` to end the call with a status.
The codes are `anole.grpc.Code`: `.ok`, `.cancelled`, `.unknown`,
`.invalid_argument`, `.deadline_exceeded`, `.not_found`, `.already_exists`,
`.permission_denied`, `.resource_exhausted`, `.failed_precondition`,
`.aborted`, `.out_of_range`, `.unimplemented`, `.internal`, `.unavailable`,
`.data_loss` and `.unauthenticated`. `Code.fromInt` converts a number.

Other errors map to a status too:

- `error.Canceled` becomes DEADLINE_EXCEEDED past the deadline, else CANCELLED;
- a request message over the registration's limit (4 MiB by default) becomes
  RESOURCE_EXHAUSTED;
- a message that does not decode becomes INTERNAL;
- any other error becomes UNKNOWN with the message "Application error
  processing RPC" (grpc-java's wording). The error's name stays on the
  server: it is logged at `warn` in scope `anole_grpc`, with the path and the
  request ID when the RequestId middleware runs. Use `call.fail` for anything
  the client should read.

The response's HTTP status is 200 for gRPC and gRPC-Web, so an access log
shows 200 for a failed call; the gRPC status travels in the trailers.

### Deadlines and cancellation

A client sets a deadline with `grpc-timeout` (Connect: `connect-timeout-ms`).
When it passes, Anole cancels the handler: any wait on `call.io` returns
`error.Canceled`, and the client gets DEADLINE_EXCEEDED. You do not need to
check the deadline yourself while you wait on `call.io`. A call without a
deadline is not bound by the server's request timeout.

When the client resets the stream (RST_STREAM), or the connection is lost,
the handler is canceled the same way: its next wait on `call.io` returns
`error.Canceled`, so a call blocked in a sleep, a database query or an
outbound request ends at once. The call ends as CANCELLED, which a client
that reset its stream no longer reads. This holds for HTTP/2 under Anole's
zio runtime, which is what `anole.Server` runs. A connection that ends
cleanly may be only half-closed, so the server first checks with a PING
(every 500 ms) whether the client is gone before canceling handlers whose
request was complete.

`call.cancelled()` still reports the client going away or the deadline
passing: use it in work that does not wait on `call.io`, such as a long
computation, and on HTTP/1.1 (gRPC-Web, Connect), where nothing cancels the
handler.

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
grpcurl -plaintext -import-path examples/grpc/proto -import-path src/grpc/proto -proto greeter.proto \
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

### Connect GET

A unary method marked as free of side effects also answers Connect's GET
form, which browsers, proxies and CDNs can cache:

```proto
rpc GetGreeting(GreetingRequest) returns (Greeting) {
  option idempotency_level = NO_SIDE_EFFECTS;
}
```

`register` adds a GET route beside the POST one for such methods (zig-protobuf
keeps the option in the generated `_method_options`). The query carries the
call: `encoding` (`proto` or `json`, else `415`), `message` (the request,
percent-encoded, or with `base64=1` in URL-safe base64, padded or not; absent
is an empty message), `compression` (`identity` or `gzip`, else
UNIMPLEMENTED) and `connect=v1` (optional; another version is
INVALID_ARGUMENT). Other parameters are ignored. The answer is a Connect unary
response, compressed by the request's `Accept-Encoding`.

```sh
curl 'http://localhost:8083/greeter.Greeter/GetGreeting?connect=v1&encoding=json&message=%7B%22name%22%3A%22Ada%22%7D'
```

A GET on any other method is `405 Method Not Allowed`.

## JSON transcoding

A method annotated with `google.api.http` (google/api/http.proto, as Envoy's
gRPC-JSON transcoder and grpc-gateway read it) also answers plain REST
requests, JSON in and out, on routes of its own:

```proto
import "google/api/annotations.proto";

service Library {
  rpc GetBook(GetBookRequest) returns (Book) {
    option (google.api.http) = {
      get: "/v1/{name=shelves/*/books/*}"
      additional_bindings { get: "/v1/books/{name}" }
    };
  }
  rpc CreateBook(CreateBookRequest) returns (Book) {
    option (google.api.http) = { post: "/v1/{parent=shelves/*}/books" body: "book" };
  }
}
```

```sh
curl 'http://localhost:8083/v1/shelves/s1/books/b1?view=FULL'
curl -d '{"title":"Dune"}' 'http://localhost:8083/v1/shelves/s1/books?bookId=dune'
```

`register` adds these routes beside the gRPC one, for HTTP/1.1 and HTTP/2,
from the annotations zig-protobuf keeps in the generated code: there is no
protoc plugin to run. `registerWith(..., .{ .transcode = false })` leaves
them out. The handlers are the same; `call.protocol` is `.http_json`.

The rules are checked at compile time: the template's syntax, that each path
variable names a single field of a primitive type (a string, number, bool,
enum, or a Timestamp, Duration, FieldMask or wrapper), and that `body` and
`response_body` name top-level fields.

### Routes

The verbs are `get`, `put`, `post`, `delete` and `patch`, plus `custom` with
any HTTP method dusty knows (`custom: { kind: "SEARCH" path: "/v1/books" }`),
and each of `additional_bindings` is a route too. Path templates take the
whole syntax:

| Template | Matches | Sets |
| --- | --- | --- |
| `/v1/books/{name}` | one segment | `name` |
| `/v1/{name=shelves/*/books/*}` | the segments, literals included | `name` to `shelves/1/books/2` |
| `/files/{path=**}` | the rest of the path | `path` to `a/b/c.txt` |
| `/v1/*/x` | any one segment, bound to nothing | |
| `/v1/{book.name}` | one segment | the nested field `book.name` |
| `/v1/{name=books/*}:publish`, `/v1/books:batchGet` | a custom verb after the last segment | |

A one-segment variable is percent-decoded in full; a longer one keeps `%2F`
as it is, as http.proto asks.

Each template becomes a router route: `*` a parameter, `**` a wildcard, a
verb part of a last literal. What the router cannot say (literals inside a
variable, a verb after a variable) the binding checks itself, so several
bindings can share a route, `/v1/books/{name}` and `/v1/books/{name}:stat`
for example; those with a verb are tried first. A path that the route
matches and no binding does is a 404. Transcoding routes follow the router's
rules:

- A parameter at a position where another route has one takes that route's
  name (the router keeps one name per position; the binding reads its
  values from the path, not from `req.params`).
- A binding whose route is already someone else's (yours, or another
  method's gRPC route) panics at registration, as two bindings that match
  the same paths do.
- `**` needs at least one segment here (Envoy also matches none).
- The router picks a route before the binding is asked: of `/v1/{name}:x`
  and `/v1/{name=**}`, `/v1/abc` reaches the first's route and is a 404.

### The request

The request message is put together the way http.proto describes:

- `body: "*"`: the JSON body is the message, with the path variables set over
  it. Query parameters are ignored.
- `body: "book"`: the JSON body is that field (any type, a repeated field
  takes an array); the other fields come from the path and the query.
- No `body`: everything from the path and the query; a body is ignored.

A query parameter names a field by its proto or JSON name, nested with dots
(`author.name=Ada`, `pageSize=10`), and repeats for a repeated field
(`tags=a&tags=b`). Values read as the proto3 JSON mapping reads strings:
enums by name or number, `true`/`false`, 64-bit integers, `NaN` and
`Infinity` for floats, base64 for bytes, RFC 3339 for a Timestamp, `1.5s` for
a Duration. Parameters for no field are ignored (cache-busters, tracking
tags), and so are those for fields the path or the body set. A message or map
field cannot be set from the query.

A request that does not make a message (a value of the wrong type, a body
that is not JSON) fails with INVALID_ARGUMENT before the handler runs. The
body may nest 100 arrays or objects deep; it is limited to the
registration's `max_message_size` (RESOURCE_EXHAUSTED past it), and may come
compressed with `Content-Encoding`.

### The response

The response message as JSON (`application/json`), in the proto3 mapping of
the generated `jsonEncode`: JSON field names, fields at their default left
out, 64-bit integers as strings, oneof members as fields. With
`response_body: "books"`, the body is that field alone: `[...]` for a
repeated field, its default (`[]`, `""`, `0`) when unset. Responses are
compressed by the request's `Accept-Encoding`.

`call.addHeader` sets response headers, and `call.addTrailer` sends
`grpc-trailer-<name>` headers, as grpc-gateway does. A client's
`grpc-timeout` header sets the deadline; without one, the call is not bound
by the server's request timeout, as with gRPC.

A failed call answers the gRPC code's HTTP status (the same table as
Connect: NOT_FOUND 404, INVALID_ARGUMENT 400, UNAUTHENTICATED 401,
UNIMPLEMENTED 501, and so on) with a google.rpc.Status body:

```json
{"code":5,"message":"no such book","details":[]}
```

### Streaming

A server-streaming method answers one JSON array, as Envoy's transcoder
does, sent element by element as the handler queues messages: `[` with the
first, `,` before each next one, `]` when the handler returns. No message is
`[]`.

A failure before the first message is an ordinary error response. After it
the status line has gone out as 200, so the array is cut short instead
(`Response.abort`): on HTTP/2 and HTTP/3 the stream is reset, on HTTP/1.1 the
connection closes before the body's last chunk. A client never reads a complete array from a failed
call; the server logs the status at `warn`. On HTTP/2, trailing metadata of a
successful stream goes out as HTTP trailers (HTTP/1.1 has none to carry it).

Client- and bidirectional-streaming methods are not transcoded: their routes
answer 501 with UNIMPLEMENTED. Call them over gRPC, gRPC-Web or Connect.

Not supported: rules from a service config (`selector`; annotations only),
and map fields from query parameters.

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
NOT_FOUND. Each `Health` is its own registry: two servers in one process can
each register their own, or both register the same one. It must outlive the
router.

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

`CallOptions` takes a `timeout` (sent as `grpc-timeout`, and the client
resets the stream past it too), extra `metadata` with lower-case names, and
`compression = .gzip`. A call without a `timeout` has no time limit on the
client side, whatever the connection's default request `timeout`.

For TLS, connect with `.tls = .{}` (the system trust store), or name a CA
(`.tls = .{ .ca = .{ .pem = ca_pem } }`, see
[TLS options](clients.md#tls-options)), and set `.scheme = "https"` on the
channel. The connection negotiates `h2` by ALPN.

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
server (`tests/grpc/interop/run.sh`), and Anole's client passes 11 cases
against grpc-go's server (`tests/grpc/interop/run-client.sh`), each over h2c
and, with `--tls`, over TLS with a certificate made for the run. grpc's
HTTP/2 server checks (`tools/http2_interop`, `tests/grpc/interop/run-http2.sh`)
pass their framing cases over h2c and TLS and the TLS profile, except five
results the tool itself causes (listed with reasons in
`tests/grpc/interop/http2-known-failures.txt`). All of it runs in CI. For
benchmark numbers against grpc-go, see the README.

## Not there yet

- gRPC over HTTP/3. Native gRPC runs over HTTP/2 only.
- Server reflection.
- Canceling the handler of a gRPC-Web or Connect call over HTTP/1.1 when the
  client goes away (check `call.cancelled()`).
