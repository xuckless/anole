# Outbound HTTP client

Up: [index](index.md). Related: [resilience](resilience.md) (retry and breaker options), [webhooks](../messaging/webhooks.md) (signed outbound webhooks are their own feature), [HTTP](../http/index.md) (`ServerOptions`).

Every `anole.Server` owns one pooled HTTP client (HTTP/1.1, HTTPS with HTTP/2 when offered, redirects, decompression, per-executor pools). Reach it from any handler; never create a `std.http.Client` or a client per request. It is in every build; HTTPS needs `-Dtls=boringssl`. Full docs: docs/clients.md. Examples: examples/clients/main.zig, templates/full/src/main.zig (`upstream`).

Use:
- `anole.client` (src/client.zig): `anole.client(req)` or `anole.client(io)` returns `anole.Client` for the server whose runtime that `io` belongs to
- `anole.App.client` (src/server.zig): `app.client()`, the same client
- `anole.Client.fetch`, field `anole.Client.http` (the core `*anole.http.Client`) (src/client.zig)
- `anole.FetchOptions`: `method`, `headers` (inline pairs, at most 32), `body`, `timeout`, `max_redirects`, `decompress`, `retry`, `idempotent` (src/client.zig)
- `anole.ClientResponse`: `status`, `header`, `body`, `json`, `deinit`; field `inner` (src/client.zig)
- `anole.http.ClientOptions` via `ServerOptions.client` (src/http/core/client.zig)

## A call from a handler

```zig
const Repo = struct { full_name: []const u8, stargazers_count: u64 };

fn stars(req: *anole.Request, res: *anole.Response) !void {
    var upstream = try anole.client(req).fetch("https://api.github.com/repos/ziglang/zig", .{
        .headers = &.{ .{ "User-Agent", "anole" }, .{ "Accept", "application/json" } },
    });
    defer upstream.deinit();
    if (upstream.status() != .ok) return error.BadGateway;
    const repo = try upstream.json(Repo, req.arena);
    try res.print(.text, "{s}: {d} stars\n", .{ repo.full_name, repo.stargazers_count });
}
```

`body()` is the whole body (`""` when none), held by the response. `json(T, allocator)` parses into `T` with memory from `allocator` (it outlives the response), skipping unknown fields.

A POST with a body:

```zig
var r = try anole.client(req).fetch(url, .{
    .method = .post,
    .headers = &.{.{ "Content-Type", "application/json" }},
    .body = payload,
});
defer r.deinit();
```

## Settings: retries, breaker, timeout

```zig
var app = try anole.Server(App).init(init.gpa, .{
    .http = .{ .port = cfg.port, .h2c = true },
    // The outbound client: retries on idempotent requests, a breaker per host.
    .client = .{ .retry = .{}, .breaker = .{} },
}, &state);
```

`ServerOptions.client` is an `anole.http.ClientOptions`: `timeout` (30 s per fetch, all attempts and redirects included), `retry` (off by default), `retry_statuses` (408, 429, 502, 503, 504), `breaker` (off by default; one per scheme://host:port), `max_idle_per_host` (256), `deny_private_addresses`, `http2`, CAs and client certificates. Per call: `FetchOptions.retry = .off` or `.{ .on = .{ .attempts = 5 } }`, `idempotent = true` for a POST that is safe to repeat. Details: [resilience](resilience.md#http-client).

A per-call timeout (docs/clients.md#timeouts):

```zig
var response = try anole.client(req).fetch(url, .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } } });
defer response.deinit();
```

Traps:
- Always `defer response.deinit()`: it hands the connection back to the pool. A missing deinit leaks the connection and its buffers.
- `json` does not check the status: check `status()` first where an error body would not parse as `T`.
- Read what you need before `deinit`: `body()` and `header()` slices die with the response; `json` into `req.arena` survives it ([request arena and lifetimes](../runtime.md#request-arena-and-lifetimes)).
- URLs are sent as given: percent-encode path and query from data (`std.Uri.Component.percentEncode`); a space, CR/LF or byte past 0x7f is `error.InvalidUrl`.
- Fetching URLs from users (link previews, callbacks)? Set `ClientOptions.deny_private_addresses = true` (`error.AddressNotAllowed`, checked after DNS on every hop).
- Retries only apply to idempotent requests (GET, HEAD, OPTIONS, TRACE, QUERY, an `Idempotency-Key` header, or `idempotent = true`). An open breaker is `error.CircuitOpen` (503 via `errorStatus`).
- Do not lower `max_idle_per_host` to save memory: under load it closes returning connections and redials every round (docs/clients.md#the-connection-pool).
- `anole.client(io)` panics outside a server's runtime. In a CLI or test with no server, make an `anole.http.Client` on your own runtime (docs/clients.md#outside-a-server).
- More than 32 headers, streaming, WebSocket or Unix sockets: use `.http` (the core `anole.http.Client`); HTTP/2 multiplexing, trailers: `anole.h2.ClientConnection` (docs/clients.md#http2).
- Requests made inside `io.concurrent` tasks must not share `req.arena` ([request arena and lifetimes](../runtime.md#request-arena-and-lifetimes)).
