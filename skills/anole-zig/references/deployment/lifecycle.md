# Lifecycle: run, drain, restarts, release builds

Up: [deployment](index.md), [SKILL.md](../../SKILL.md). Related: [listeners-proxy.md](listeners-proxy.md), [tls-http.md](tls-http.md), [observability.md](../observability.md#health-and-readiness), [runtime.md](../runtime.md).

Full docs: docs/server.md (What `run` owns, When it does not start, Zero-downtime restart and socket activation), docs/getting-started.md (Deploy). Source: src/server.zig, src/handoff.zig, src/sd_notify.zig.

Do not install SIGINT/SIGTERM handlers, write a drain loop, a pid-file restart script or an sd_notify call: `run` owns all of it.

## run, stop, waitReady

Use: `anole.App.run()`, `stop()`, `waitReady()`, `addresses()`, `io()`, `deinit()` (src/server.zig).

- `run` (and `listen`, `listenTls`) serves until SIGINT, SIGTERM or `stop()`, then drains and returns. SIGHUP reloads certificates.
- `stop()` is safe from any task or thread of the runtime. `waitReady()` returns once listeners are bound, or `run`'s start error.

Traps:
- Call `run` from the thread that called `init`. One server per thread: a second `init` there is `error.ServerAlreadyOnThread`.
- `ServerOptions.signals = false` only when the process's signals belong to someone else; then `stop()` is the only way to drain.
- `use` middleware before any route; the router panics on a `use` after a route.

## When it does not start

`init`, `listen`, `listenTls`, `run` and `waitReady` fail with `anole.ServerError`, a named set (src/errors.zig). The failure is logged once with the cause and the fix:

```
error(anole): can't listen on 0.0.0.0:3000: the port is already in use.
  Another process holds it (`lsof -i :3000` shows which); stop it or use app.listen(":3001").
```

Use: `anole.App.explainStart(buf, err)` for the same text, `anole.App.failedListener()` for the listener name (src/server.zig).

Traps:
- Let `try app.run()` propagate from `main`; do not catch and re-log the error (it is already explained).
- Common ones: `AddressInUse`, `AccessDenied` (port below 1024 without `CAP_NET_BIND_SERVICE`), `FileNotFound`/`KeyMismatch` (certificates), `RouteConflict`, `ListenersAlreadySet`, `InvalidEnvironmentVariable`, `DatabaseUnavailable` (a connector with `connect_at_start`).

## Graceful drain

On SIGINT, SIGTERM, SIGUSR2 or `stop()`: listeners stop accepting; HTTP/1.1 finishes the request in flight; HTTP/2 gets a two-phase GOAWAY; HTTP/3 a GOAWAY; WebSockets close 1001; `/readyz` answers 503 `draining`; `run` returns when all connections are closed or `timeouts.shutdown` (10 s) runs out.

Use: `req.drain` (an optional `*std.Io.Event`, set when the drain starts) for long handlers and streams (src/http/core/request.zig).

Traps:
- Give the supervisor more than the drain: `docker stop -t 15` or Compose `stop_grace_period: 15s` (Docker waits 10 s, the same as the drain); systemd `TimeoutStopSec` above `timeouts.shutdown` (and above a job queue's `drain_timeout` + 3 s). Kubernetes' 30 s default is enough.
- To leave a balancer's rotation first, fail a readiness check, wait, then SIGTERM.
- A long-running handler that never waits and never checks `req.drain` holds the drain to its timeout. Blocking work belongs on the pool: [never block an executor](../runtime.md#never-block-an-executor).

## Zero-downtime restart and systemd

Use: `ServerOptions.process = init.minimal`, `ServerOptions.restart_timeout` (10 s) (src/server.zig, src/handoff.zig, src/sd_notify.zig).

```zig
var app = try anole.App.init(init.gpa, .{
    .listeners = &.{ .{ .name = "http", .address = "", .port = 8080 } },
    .process = init.minimal,
});
```

With `process` set:
- Socket activation: `LISTEN_FDS`/`LISTEN_FDNAMES` sockets are matched by listener name (`h3` for HTTP/3's UDP).
- `kill -USR2 <pid>` re-executes the binary at the same path with the sockets inherited; the old process drains only once the new one reports serving, and keeps serving if it does not within `restart_timeout`. Deploy = replace the binary, send SIGUSR2.
- `NOTIFY_SOCKET` set: `READY=1`, `RELOADING=1`, `MAINPID=`, `STOPPING=1`, with no libsystemd.

```ini
# from docs/server.md anole.service (socket units omitted)
[Service]
Type=notify
NotifyAccess=all
ExecStart=/usr/local/bin/myapp
ExecReload=/bin/kill -USR2 $MAINPID
ExecStop=/bin/sh -c 'kill -TERM $MAINPID; while kill -0 $MAINPID 2>/dev/null; do sleep 0.1; done'
KillMode=control-group
TimeoutStopSec=20
```

Traps:
- With `process`, each TCP listener is a single socket, not one per core (HTTP/3 keeps per-core UDP sockets).
- HTTP/3 requests in flight at a restart are cut; clients reconnect.
- `systemctl restart` drains and starts; use `systemctl reload` (SIGUSR2) for zero downtime. `NotifyAccess=all` is required.
- Unix only; on Windows nothing is inherited. At most 64 TCP listeners and 1024 UDP sockets can be handed over (`error.TooManyListeners`).

## Release builds are production

`zig build -Doptimize=ReleaseSafe` makes a release build, whose environment is production unless `ANOLE_ENV` says otherwise: JSON logs, no `.env`, no error names in 500s ([environment](../config-cli.md#environment-and-deployment)).

Traps:
- `ReleaseSafe` is the production build. `addApp` warns on `ReleaseFast`/`ReleaseSmall`, and the server warns at start: safety checks off means a bug can corrupt memory instead of stopping.
- A Debug build running as production logs a warning ("Debug builds are several times slower").

## Docker

The templates ship no Dockerfile on purpose (docs/templates.md): build the binary, copy it into a small image. From docs/getting-started.md:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu   # or aarch64-linux-gnu
```

```dockerfile
FROM gcr.io/distroless/cc-debian12
COPY zig-out/bin/api /api
EXPOSE 3000
ENTRYPOINT ["/api"]
```

Traps:
- Listen on `":3000"`, not `127.0.0.1` (unreachable from outside the container).
- An image without CA certificates cannot make outbound HTTPS calls (`distroless/cc` has them; `debian:*-slim` needs `ca-certificates`).
- HTTP/3 needs the UDP port published too; a browser that cannot reach it stays on HTTP/2.
- The console attaches with `docker exec -it c anole console` ([console](../observability.md#live-console)).
