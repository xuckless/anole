# {{name}}

A gRPC service on [Anole](https://github.com/xuckless/anole) that also answers
gRPC-Web, Connect and REST. `proto/greeter.proto` is the contract; `zig build`
generates its Zig code, nothing to install.

```
zig build run          # http://localhost:3000 (HTTP/1.1 and h2c), docs at /docs
zig build test         # REST and Connect, in memory
zig build openapi      # writes openapi.json (REST and Connect forms; native gRPC is the .proto)
```

Try it:

```
# native gRPC
grpcurl -plaintext -import-path proto -proto greeter.proto -d '{"name":"Ada"}' localhost:3000 greeter.Greeter/SayHello
# Connect, with curl
curl -H 'Content-Type: application/json' -d '{"name":"Ada"}' localhost:3000/greeter.Greeter/SayHello
# REST, from the google.api.http annotation
curl localhost:3000/v1/hello/Ada
```

Handlers are `fn (call: *anole.grpc.Call, request) !Response` in `src/main.zig`.
The comments in the .proto file become the OpenAPI document's descriptions.
Release builds run in production mode; see
[the server guide](https://github.com/xuckless/anole/blob/main/docs/server.md).
