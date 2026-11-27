# HTTP: server, routes, requests, responses

How to stand up an Anole server and answer HTTP requests the Anole way. Up: [SKILL.md](../../SKILL.md).

- [server-routes.md](server-routes.md): `anole.App` / `anole.Server(Ctx)` with shared state, route methods, path params, groups, `onlyOn`, `noWait`.
- [request-response.md](request-response.md): reading the request (`params`, `query`, `bind`, `bindQuery`, `arena`, `io`) and writing the response (`json`, `print`, `fail`, `problem`, `header`).
- [typed-validation.md](typed-validation.md): typed handlers (`anole.In`, `Created`, `Accepted`, `WithStatus`) and `field_rules` validation (`anole.validate`, `Violation`, `req.invalid`).
- [static.md](static.md): `static`, `staticDir`, `embedded`.
- [openapi.md](openapi.md): `app.openapi`, `anole.doc`, `pub const openapi` declarations on types.
- [grpc.md](grpc.md): `app.grpc`, `grpcWith`, `grpcHealth`, `anole.grpc.Call`.

Elsewhere:
- Middleware, caching, rate limits, sessions, auth and error answers: [middleware-auth](../middleware-auth/index.md).
- Outbound HTTP (`anole.client`, `Client.fetch`, `ClientResponse`): [storage-email-clients](../storage-email-clients/index.md).
- WebSocket, SSE, WebTransport: [realtime](../realtime/index.md).
- Executor rules every handler must follow: [runtime.md](../runtime.md).
