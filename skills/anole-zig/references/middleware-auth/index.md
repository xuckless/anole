# Middleware, auth and error answers

What runs around handlers: hand-written and built-in middleware, response caching, rate limits, sessions, auth and how errors become answers. Up: [SKILL.md](../../SKILL.md).

- [middleware.md](middleware.md): `app.use`, `anole.func` + `anole.Next`, middleware structs (`execute`, `no_wait`), `anole.Middleware(Ctx)` handles, request locals, the built-ins (`Cors`, `Compress`, `RequestId`, `Logger`), early data (0-RTT).
- [caching.md](caching.md): `anole.cached`, `app.responseCache`, `anole.middleware.ResponseCache`.
- [ratelimit.md](ratelimit.md): `app.rateLimit`, `anole.ratelimit.Middleware` with memory or Redis limiters.
- [sessions-csrf.md](sessions-csrf.md): `anole.session` (sealed cookie, memory, Redis) and `anole.auth.csrf`.
- [jwt-oidc.md](jwt-oidc.md): `anole.auth.RequireJwt`, `verify`, signing, `Keyring` (JWKS), OIDC sign-in.
- [keys-passwords-roles.md](keys-passwords-roles.md): `anole.auth.password`, `anole.auth.apikey`, `anole.auth.rbac`.
- [errors.md](errors.md): status-named errors, `ServerOptions.errors`, `error_handler`, `uncaughtError`, `notFound`, `anole.defaultError`, `anole.errorStatus`.

Elsewhere: routes and groups [http/server-routes.md](../http/server-routes.md); executor rules [runtime.md](../runtime.md); access logs and metrics [observability.md](../observability.md).
