# {{name}}

Most of [Anole](https://github.com/xuckless/anole) in one app that runs with no
outside service: read `src/main.zig` top to bottom, keep what you need and
delete the rest.

```
zig build run          # http://localhost:3000 (HTTP/1.1 and h2c), docs at /docs
zig build test         # one test per area, in memory
zig build openapi      # writes openapi.json
```

| Area | Where |
| --- | --- |
| typed routes, validation, 422, SQLite (`data/app.db`) | `todos` |
| WebSocket rooms | `/ws?room=lobby` |
| server-sent events | `/events?count=3` |
| sessions + CSRF | `/session` |
| JWT bearer tokens, roles (RBAC) | `/api/me`, `/api/notes` |
| API keys | `/service/stats` |
| gRPC, gRPC-Web, Connect and REST from one .proto | `proto/greeter.proto`, `/v1/hello/Ada` |
| outbound client with retry and a circuit breaker | `/upstream` |
| rate limit, request ids, access log, CORS, compression | `main` |
| metrics, health, tracing | `/metrics`, `/healthz`, `/readyz`; tracing with `OTEL_EXPORTER_OTLP_ENDPOINT` |
| typed settings and `.env` | `src/config.zig`, `.env` |

In development the log prints a demo bearer token and API key. PostgreSQL,
Redis, NATS and Kafka start when their URL is set in `.env` (see
`.env.example`). `.env` is read in development only; a release build
(`-Doptimize=ReleaseSafe`) runs in production mode and needs `JWT_SECRET` in
the real environment. See
[the server guide](https://github.com/xuckless/anole/blob/main/docs/server.md).
