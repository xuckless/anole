# Listeners, proxies, timeouts and limits

Up: [deployment](index.md), [SKILL.md](../../SKILL.md). Related: [tls-http.md](tls-http.md), [lifecycle.md](lifecycle.md), [net.md](net.md), [environment and deployment modes](../config-cli.md#environment-and-deployment).

Full docs: docs/server.md (listen and listenTls, Several listeners, Behind a proxy, Defaults), docs/config.md (6. deployment). Source: src/server.zig (`Options`, `Listener`, `Timeouts`, `Limits`, `Proxy`, `onlyOn`).

## listen addresses

Use: `anole.App.listen(address)` (src/server.zig), Go notation:

| Address | Binds |
| --- | --- |
| `":3000"`, `"3000"` | every interface, IPv6 and IPv4 (what a container needs) |
| `"0.0.0.0:3000"` | every IPv4 interface only |
| `"127.0.0.1:3000"`, `"localhost:3000"` | this machine only |
| `"[::]:3000"` | every IPv6 interface |

Traps:
- `ServerOptions.http` with `address` null defaults to `127.0.0.1:8080` (the deployment may change it); inside a container that is unreachable. Use `":3000"` or `.address = ""`.
- A port another process holds is `error.AddressInUse`, not a silent `SO_REUSEPORT` share. After a failed start, `app.failedListener()` names the listener.
- Port 0 picks a free port: read it from `app.addresses()` after `waitReady()`.

## Several listeners, unix sockets, onlyOn

Use: `ServerOptions.listeners: []const anole.Listener` (`.name`, `.address`, `.port`, `.unix`, `.unix_mode` 0o660, `.tls = .{ .cert, .alpn, .client_auth }`, `.http1`, `.http2`, `.http3`, `.proxy_protocol`, `.proxy_protocol_from`, `.tcp`, `.udp`); `anole.onlyOn(name)` (src/server.zig).

```zig
// docs/server.md
var app = try anole.App.init(init.gpa, .{
    .https = .{ .address = "", .port = 443, .cert = cert },
    .listeners = &.{
        .{ .name = "admin", .port = 9090 }, // 127.0.0.1 only
        .{ .name = "proxy", .unix = "/run/myapp/http.sock" },
    },
});
const admin = app.group("/admin", .{anole.onlyOn("admin")});
admin.get("/stats", stats);
```

Traps:
- Every listener serves every route; `anole.onlyOn(name)` keeps a group to one listener (404 elsewhere). Metrics and health take `.listener = "admin"` instead ([observability](../observability.md#wiring-the-canonical-block)).
- Names are unique, at most 255 bytes, no `:`. `http`'s and `https`'s listeners are named `http` and `https`. Restarts and socket activation match sockets by name.
- A stale unix socket file is replaced if nothing listens; one that answers is `AddressInUse`. Anole never removes the file.
- Naming any listener (raw TCP/UDP included) removes the implicit 127.0.0.1:8080.
- In tests, `.listener = "admin"` on an `anole.testing` request reaches `onlyOn` routes ([testing](../testing.md#the-in-memory-client)).

## Behind a proxy

Use: `ServerOptions.deployment = .behind_proxy | .anole_lb | .platform` (or `ANOLE_DEPLOYMENT`), `ServerOptions.proxy` (`anole.ServerOptions.Proxy`: `.trusted`, `.trusted_hops`, `.trust_forwarded_proto` true, `.trust_forwarded_host` false), listener `.proxy_protocol`, `.proxy_protocol_from` (src/server.zig, src/modes.zig).

```zig
// PROXY protocol on one listener, from the load balancers only (docs/server.md)
.http = .{ .port = 8080, .proxy_protocol = true, .proxy_protocol_from = &.{ "10.0.0.0/8", "2001:db8::/32" } },
```

- `behind_proxy`, `anole_lb`, `platform` trust `loopback` and `private` by default; `ANOLE_PROXY_TRUSTED=10.0.0.0/8,203.0.113.7` overrides. Then `req.remote_address` is the rightmost untrusted `X-Forwarded-For` address and `X-Forwarded-Proto` sets `req.secure`.
- `anole_lb` expects a PROXY v1/v2 header on every TCP listener; `platform` listens on `""` and `$PORT`.

Traps:
- Do not parse `X-Forwarded-For` yourself; read `req.remote_address`.
- `behind_proxy` keeps `127.0.0.1`: a proxy in another container or host needs `.address = ""`.
- Under `anole_lb`, a metrics or admin port scraped directly must set `proxy_protocol = false`.
- `trust_forwarded_host = true` only behind a proxy that overwrites `X-Forwarded-Host`, or clients choose your link host.
- `trusted_hops` alone (standalone) reads headers from any peer: only on a port nothing but the proxy can reach.
- Keep `timeouts.keepalive` (75 s) above the balancer's idle timeout (nginx, AWS ALB: 60 s), or the balancer reuses a closed connection and returns 502.
- gRPC upstream needs h2c (nginx `grpc_pass`, Caddy `versions h2c`); cleartext listeners accept h2c by default.

## Timeouts

Use: `ServerOptions.timeouts` (`anole.ServerOptions.Timeouts`, durations, null for none) (src/server.zig):

| Field | Default | What |
| --- | --- | --- |
| `request` | 30 s | reading the request, the handler, the response, the TLS handshake |
| `read_header` | 10 s | HTTP/1.x request head (Slowloris) |
| `write` | 30 s | one stalled write once a streamed body started |
| `keepalive` | 75 s | idle keep-alive connection |
| `idle_park` | 1 s | idle HTTP/1.1 connection gives up its task |
| `shutdown` | 10 s | the graceful drain; null waits for every connection |

```zig
var app = try anole.App.init(init.gpa, .{ .timeouts = .{ .request = cfg.request_timeout } });
```

Traps:
- Do not wrap handlers in your own timers; set `timeouts.request` (per request: `req.setTimeout`, used by the Lambda deadline).
- Long event streams must watch `req.drain`, or with `shutdown = null` they hold the drain open forever ([drain](lifecycle.md#graceful-drain)).

## Limits

Use: `ServerOptions.limits` (`anole.ServerOptions.Limits`) (src/server.zig): `body_max` (1 MiB; 413 past it), `max_head_size` (16 KiB; 431), `max_header_count` 32, `max_param_count` 8, `max_query_count` 32, `max_form_count` 32, `max_connections` (0 follows the fd limit), `max_requests_per_connection`, `ws_max_message` (1 MiB), `max_websockets`, `buffer_budget`, `max_tasks`. Also `raise_fd_limit` (true), `executors` (`.auto`: one per CPU, cgroup-aware), `max_stack_size` (1 MiB), `admission` (WebSocket gate under load).

Traps:
- Raise `limits.body_max` for uploads instead of reading the socket yourself.
- HTTP/2 memory is per stream: up to `max_concurrent_streams` x `body_max` per connection. Lower one of them for small hosts.
- `max_stack_size` below 1 MiB is not advised; raise it for deep recursion or large stack buffers.
