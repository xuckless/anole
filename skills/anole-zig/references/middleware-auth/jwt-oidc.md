# JWT bearer tokens, JWKS and OIDC

Up: [index](index.md). Full docs: docs/auth.md (JWT verification, Bearer tokens, Signing, JWK sets, OIDC sign-in). Examples: examples/auth, templates/full. Needs `-Dauth` (on by default).
Related: [sessions-csrf.md](sessions-csrf.md), [keys-passwords-roles.md](keys-passwords-roles.md), [errors.md](errors.md).

## Require a bearer token: `anole.auth.RequireJwt`

Use: `anole.auth.RequireJwt` (`init(keys, policy, options)`), `anole.auth.claims`, `anole.auth.subject`, `anole.auth.Key`, `anole.auth.Policy`, `anole.auth.Verified` (src/auth/root.zig, src/auth/bearer.zig). Keys are `.{ .static = &keys }` or `.{ .keyring = &keyring }`. Options: `required_claims` (`&.{"sub"}`), `scopes`, `realm`, `hook`.

```zig
const jwt_keys = [_]auth.Key{.{ .kid = "demo", .alg = .HS256, .material = .{ .hmac = &jwt_secret } }};
var bearer = auth.RequireJwt.init(.{ .static = &jwt_keys }, .{ .issuer = issuer, .audience = "api" }, .{});
```

```zig
const api = app.group("/api", .{anole.auth.RequireJwt.init(.{ .keyring = &keyring }, .{ .issuer = "https://issuer.example", .audience = "api" }, .{
    .scopes = &.{"notes:read"}, // all of these in the `scope` claim
    .realm = "api",
})});
api.get("/me", me);

fn me(req: *anole.Request, res: *anole.Response) !void {
    const token = anole.auth.claims(req) orelse return error.Unauthorized;
    try res.print(.text, "{s} ({s})", .{ anole.auth.subject(req) orelse "-", token.string("role") orelse "-" });
}
```

Answers (RFC 6750): no token 401 with `WWW-Authenticate: Bearer`; malformed 400; bad or expired token 401 `invalid_token`; missing scope 403; keyring fetch failed 503; weak HMAC key or keyring policy without audience 500 with the fix in the log. They are returned as status-named errors, so they follow `ServerOptions.errors` ([errors.md](errors.md)).

Traps:
- Each `Key` verifies only its own `alg`; `alg: none`, unknown algorithms and `crit` headers always fail.
- `exp` is required by default (`require_exp`). Always set `issuer` and `audience` when the keys sign for others (an identity provider's do). A `Keyring` refuses a policy without `audience` unless `allow_any_audience = true`.
- An HMAC secret shorter than its hash (32 bytes for HS256) verifies nothing (`error.WeakKey`).
- `RequireJwt` on a `Keyring` may wait (a JWKS fetch), so it is not `no_wait`.
- Nothing from the token goes into `req.session`; read it with `claims(req)` / `subject(req)`.

## Verify a token yourself: `anole.auth.verify`

`anole.auth.verify(arena, token, keys, policy, now)` (src/auth/jws.zig), `now` in Unix seconds, for example `std.Io.Clock.real.now(req.io).toSeconds()`. Policy fields: `issuer`, `audience`, `typ`, `leeway` (60 s), `require_exp`, `require_iat`, `max_age`, `allow_any_audience`. `anole.auth.parseJwks(arena, json)` turns a JWK Set into keys.

## Sign tokens: `anole.auth.jwt`

```zig
var signer = anole.auth.jwt.SigningMethodHS256.init(arena);
const token = try signer.signWithHeader(.{ .typ = "JWT", .alg = "HS256", .kid = "k1" }, .{
    .iss = "me", .aud = "api", .sub = "alice", .iat = now, .exp = now + 3600,
}, secret);
```

Traps: use an HMAC secret of 32 random bytes or more from the secret store; for tokens other services verify, prefer ES256 or EdDSA.

## A provider's keys: `anole.auth.Keyring`

Use: `anole.auth.Keyring` (src/auth/keyring.zig). Give it the server's client (`app.client()`) and the `jwks_uri`. It fetches on first use, after `ttl` (1 h) and once more for an unknown `kid` (at most every 60 s), and keeps stale keys for a day when the provider is down.

```zig
var keyring = anole.auth.Keyring.init(gpa, app.io(), app.client(), "https://issuer.example/jwks.json");
defer keyring.deinit();
const v = try keyring.verify(req.arena, token, .{ .issuer = "https://issuer.example", .audience = "api" });
```

## OIDC sign-in

Relying party only (authorization code + PKCE, `state`, `nonce`, ID-token checks), with Google and Apple presets.

Use: `anole.auth.oidc.Provider` (`.google`, `.apple`, `discover`), `anole.auth.oidc.RelyingParty` (`begin`, `finish`), `anole.auth.oidc.Start`, `anole.auth.oidc.Callback` (src/auth/oidc.zig).

```zig
const provider = anole.auth.oidc.Provider.google; // or: try Provider.discover(gpa, app.client(), issuer_url)
var keyring = anole.auth.Keyring.init(gpa, app.io(), app.client(), provider.jwks_uri);
const rp: anole.auth.oidc.RelyingParty = .{
    .provider = &provider,
    .client_id = google_client_id,         // from your configuration, never from source
    .client_secret = google_client_secret,
    .redirect_uri = "https://app.example/auth/google/callback",
    .keyring = &keyring,
};
```

Start: `const start = try rp.begin(req.arena, req.io);`, keep `start.state`, `start.nonce`, `start.code_verifier` in the session, redirect (303) to `start.url`. Callback: rebuild a `Start` from the session and a `Callback` from `code` / `state`, then `rp.finish(req.arena, req.io, anole.client(req), callback, saved)`, remove the three session keys, set the user and call `anole.session.regenerate(req)`. Full flow: docs/auth.md (OIDC sign-in).

Traps:
- Key accounts on `(id.issuer, id.subject)` together, never subject alone or email. Trust `email` only when `email_verified` is true.
- No CSRF middleware on the callback route: `state` is its CSRF check.
- Apple with `response_mode = "form_post"`: read `code`/`state` from `req.formData()` and set the session's `.cookie_opts = .{ .same_site = .none }`.
- The presets are tested against a fake provider, not yet against the live services.
