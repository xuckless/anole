# Sessions and CSRF

Up: [index](index.md). Full docs: docs/auth.md (Sessions, CSRF). Examples: examples/auth, templates/full.
Related: [jwt-oidc.md](jwt-oidc.md), [keys-passwords-roles.md](keys-passwords-roles.md), [config-cli.md](../config-cli.md).

## Sessions: `anole.session.Middleware`

Loads `req.session` before the handler and saves it after. In handlers: `req.session.set(k, v)`, `get`, `remove`, `clear`.

Use: `anole.session.Middleware`, `anole.session.Options`, `anole.session.keyFromBase64`, `anole.session.devKey`, `anole.session.regenerate`, `anole.session.MemoryStore`, `anole.session.RedisStore`, `anole.session.Store`, `anole.session.key_length` (src/session/root.zig).

```zig
const key = try anole.session.keyFromBase64(init.environ_map.get("SESSION_KEY") orelse return error.NoSessionKey);
app.use(try anole.session.Middleware.init(.{ .key = key }));
// local development: .{ .key = anole.session.devKey(app.io()) }
```

Server-side stores:

```zig
var mem = anole.session.MemoryStore.init(gpa, app.io(), .{}); // then .store = mem.store()
const redis = try app.redis(.{}); // REDIS_URL
var rs: anole.session.RedisStore = .{ .client = redis, .gpa = gpa }; // keys "anole:session:<id>" with the TTL
var sessions = try anole.session.Middleware.init(.{ .store = rs.store() });
```

`Options`: `store` (null: sealed cookie), `key`, `cookie_name` (`anole_session`), `ttl` (24 h, renewed by each response), `cookie_opts` (`Path=/`, `HttpOnly`, `Secure`, `SameSite=Lax`; setting one field keeps the others).

| | Sealed cookie (`.key`) | `MemoryStore` | `RedisStore` |
| --- | --- | --- | --- |
| Several nodes | Yes, same key on each | No | Yes |
| Server-side logout of every device | No | Yes | Yes |
| Survives a restart | Yes, if the key does | No | Yes |

Sign-in, against session fixation:

```zig
try req.session.set("user", user.name);
try anole.session.regenerate(req);
```

Traps:
- `init` returns an error union: in cookie mode it refuses a missing or all-zero key (`error.SessionKeyMissing`). Key: 32 random bytes from the secret store (`openssl rand -base64 32`), the same on every node. `devKey` is for local development only.
- A session holds at most 16 entries; `regenerate` uses one until the response is saved.
- In production, `.cookie_name = "__Host-anole_session"`; `init` refuses a `__Host-` name without `Secure` / `Path=/` or with a `Domain`.
- `Secure` cookies are kept on `http://localhost` only; elsewhere serve HTTPS.
- A sealed cookie keeps all data in the cookie: keep it small, and know a copied cookie stays valid until it expires.
- A session store over Redis may wait: such a session middleware is not `no_wait` ([middleware.md](middleware.md#middleware-that-never-waits)).

## CSRF: `anole.auth.csrf`

Synchronizer tokens in the session: place it after the session middleware. Refuses POST, PUT, PATCH and DELETE with 403 unless the token comes back in `X-CSRF-Token` or the `_csrf` form field.

Use: `anole.auth.csrf.Middleware`, `anole.auth.csrf.token`, `anole.auth.csrf.header_name`, `anole.auth.csrf.field_name`, `anole.auth.csrf.session_key` (src/auth/csrf.zig).

```zig
const web = app.group("", .{ try anole.session.Middleware.init(.{ .key = state.session_key }), auth.csrf.Middleware.init(.{ .check_json = true }) });
web.get("/session", sessionInfo);
web.post("/session", signIn);
```

```zig
fn loginForm(_: *App, req: *anole.Request, res: *anole.Response) !void {
    const token = try auth.csrf.token(req);
    try res.header(auth.csrf.header_name, token);
    try res.print(.html, form_html, .{token});
}
```

Traps:
- JSON bodies are not checked by default (`check_json = false`); set it when CORS allows cross-origin JSON with credentials.
- After sign-in, drop the old token: `regenerate` does, or `req.session.remove(anole.auth.csrf.session_key)`.
- Do not put CSRF on an OIDC callback route: its `state` check is its CSRF protection ([jwt-oidc.md](jwt-oidc.md#oidc-sign-in)).
- A session middleware listed by value in two groups is two copies; share one with a [handle](middleware.md#sharing-one-middleware-value).
