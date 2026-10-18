# Auth and request protection

Anole's auth pieces are separate parts that you combine as middleware: JWT
verification, OIDC sign-in, sessions, CSRF tokens, password hashes, API
keys, roles and rate limits. You choose which routes get which. `anole.auth`
needs `-Dauth` (on by default); `anole.session` and `anole.ratelimit` are
always built, and their Redis stores need `-Dredis` (on in the default
`full` profile). `examples/auth/main.zig` puts most of this guide together;
see [Try the example](#try-the-example).

## Where the pieces go

Middleware runs in the order you list it. A global `app.use(...)` must come
before the first route. For protection per route, use groups:

```zig
const M = anole.http.Middleware(App);
const web = [_]M{ .init(&sessions), .init(&csrf) };
const login_mw = [_]M{ .init(&login_limit), .init(&sessions), .init(&csrf) };
app.group("", &web).get("/me", me);
app.group("", &login_mw).post("/login", login);
```

Keep the middleware values and the arrays alive for as long as the server
runs. Locals in `main` before `app.run()` are fine. Put the rate limit first,
so that requests the later middleware refuses still count against the limit.

## JWT verification

`anole.auth.verify(arena, token, keys, policy, now) Error!Verified` checks a
JWS compact token (a signed JWT) against your keys and a claims policy.

A `Key` has an optional `kid`, exactly one `alg`, and its `material`
(`.hmac`, `.rsa` with big-endian `n` and `e`, `.p256`, `.p384` or `.ed25519`).
It supports HS256/384/512, RS256/384/512, PS256/384/512, ES256, ES384 and
EdDSA, all on Zig's `std.crypto`. `Policy` holds `issuer`, `audience`,
`leeway_seconds` (60), `require_exp` (true) and `max_age_seconds`. `now` is
in Unix seconds, for example `std.Io.Clock.real.now(req.io).toSeconds()`.

Each key verifies only its own algorithm. A token whose `alg` differs from
the key's never verifies. An RSA public key therefore can't be used as an
HMAC secret.

These defaults are enforced, not optional:

- `alg: none` and unknown algorithms fail with `error.UnsupportedAlgorithm`,
  and so does any `crit` header.
- `exp` is required (`error.MissingExpiry`). Turn off `require_exp` only for
  tokens that really have no expiry.
- `nbf` and `iat` are checked when present. `iss`, `aud` (a string or an
  array) and `max_age_seconds` are checked when you set them in the policy.
- An HMAC comparison runs in constant time.

The result, `Verified`, gives you the header and claims as JSON objects,
plus `string("sub")` and `integer("exp")`. They live in the arena you pass,
which is usually `req.arena`.

Anole has no bearer-token middleware yet. `RequireJwt` in the example is
one in about 25 lines: it reads `Authorization: Bearer`, calls `verify`, and
answers 401 with `WWW-Authenticate` on any error.

### Signing

To issue tokens, use `anole.auth.jwt`, the patched zig-jwt fork. This fork
compares MACs in constant time and has no `none` or MD5/SHA-1 methods.
Signing is deterministic for HS*, RS*, ES* and EdDSA. PS* needs
`withRandom` first and panics without it.

```zig
var signer = anole.auth.jwt.SigningMethodHS256.init(arena);
const token = try signer.signWithHeader(.{ .typ = "JWT", .alg = "HS256", .kid = "k1" }, .{
    .iss = "me", .aud = "api", .sub = "alice", .iat = now, .exp = now + 3600,
}, secret);
```

Use an HMAC secret of 32 random bytes or more, kept in your secret store.
For tokens that other services verify, prefer ES256 or EdDSA, so that those
services hold only a public key.

### JWK sets and key rotation

`anole.auth.parseJwks(arena, json)` turns a JWK Set into keys. It skips
`use: enc` keys. A key without `alg` gets the one its type implies: RSA gets
RS256, P-256 gets ES256, P-384 gets ES384 and Ed25519 gets EdDSA.

For a provider's `jwks_uri`, use `anole.auth.Keyring`. It fetches the set on
first use, fetches it again after `ttl_seconds` (3600), and fetches it once
more when a token names an unknown `kid`. Providers rotate keys, but those
extra fetches are at least `min_refresh_seconds` (60) apart, so bogus tokens
can't make you hammer the provider.

```zig
var client = anole.http.Client.init(gpa, io, .{});
var keyring = anole.auth.Keyring.init(gpa, io, &client, "https://issuer.example/jwks.json");
defer keyring.deinit();
const v = try keyring.verify(req.arena, token, .{ .issuer = "https://issuer.example", .audience = "api" });
```

The keyring holds one lock while it fetches, so requests that verify tokens
wait for that fetch.

## OIDC sign-in (Google, Apple)

`anole.auth.oidc` is a relying party. It is never a provider. It runs the
authorization-code flow with PKCE (S256), a random `state` and `nonce`, and
the ID-token checks of OIDC Core 3.1.3.7: signature, `iss`, `aud`, `exp`,
`iat`, `azp` and `nonce`. The logic is ported from liboauth2.

You need a `Provider`, a `Keyring` on its `jwks_uri`, and a `RelyingParty`:

```zig
var client = anole.http.Client.init(gpa, io, .{});
const provider = anole.auth.oidc.Provider.google; // or: try Provider.discover(&client, gpa, issuer_url)
var keyring = anole.auth.Keyring.init(gpa, io, &client, provider.jwks_uri);
const rp: anole.auth.oidc.RelyingParty = .{
    .provider = &provider,
    .client_id = google_client_id,         // from your configuration, never from source
    .client_secret = google_client_secret,
    .redirect_uri = "https://app.example/auth/google/callback",
    .keyring = &keyring,
};
```

Start the flow on one route. Keep what `begin` returns in the session until
the callback comes back:

```zig
const start = try rp.begin(req.arena, req.io);
try req.session.set("oidc_state", start.state);
try req.session.set("oidc_nonce", start.nonce);
try req.session.set("oidc_verifier", start.code_verifier);
res.status = .see_other;
try res.header("Location", start.url);
```

Finish the flow on the callback route:

```zig
const saved: anole.auth.oidc.Start = .{
    .url = "",
    .state = req.session.get("oidc_state") orelse return refuse(res),
    .nonce = req.session.get("oidc_nonce") orelse return refuse(res),
    .code_verifier = req.session.get("oidc_verifier") orelse return refuse(res),
};
const callback: anole.auth.oidc.Callback = .{
    .code = req.query.get("code") orelse return refuse(res),
    .state = req.query.get("state") orelse return refuse(res),
};
const id = rp.finish(req.arena, req.io, &app.client, callback, saved) catch |err| {
    std.log.info("sign-in refused: {t}", .{err}); // StateMismatch, NonceMismatch, TokenRequestFailed, ...
    return refuse(res);
};
for ([_][]const u8{ "oidc_state", "oidc_nonce", "oidc_verifier" }) |k| req.session.remove(k);
try req.session.set("user", id.subject); // the stable account key
```

`refuse` is your own function that sets a 400 and a body: an error returned
from a handler becomes a 500 (only `error.NotFound` becomes a 404, and
request faults such as `error.BodyTooBig` their 4xx).

`Identity` holds `subject`, `email`, `email_verified`, `name`, every claim,
and the access and refresh tokens. Key accounts on `subject`. Trust `email`
only when `email_verified` is true.

The callback is a top-level navigation from the provider. Its `state` check
is its CSRF protection, so don't put the CSRF middleware on that route.

**Google.** Create an OAuth client of type "Web application" in the Google
Cloud console, and add your exact callback URL as an authorized redirect URI.
Use `Provider.google`, or `Provider.discover` with
`https://accounts.google.com`. The default scope `openid email profile` is
right.

**Apple.** Create a Services ID; it is the `client_id`. Then create a Sign in
with Apple key, which gives you a `.p8` file, a key ID and your team ID.
Apple's client secret is a short-lived ES256 JWT, which Anole makes for each
token request:

```zig
const rp: anole.auth.oidc.RelyingParty = .{
    .provider = &anole.auth.oidc.Provider.apple,
    .client_id = "com.example.web",                 // the Services ID
    .apple_secret = .{ .team_id = team_id, .key_id = key_id, .private_key_pem = p8_pem },
    .redirect_uri = "https://app.example/auth/apple/callback",
    .scope = "openid email name",
    .response_mode = "form_post",                   // Apple requires it when name or email is in scope
    .keyring = &apple_keyring,
};
```

With `form_post`, the callback is a cross-site `POST`, so read `code` and
`state` from `req.formData()`. Browsers don't send a `SameSite=Lax` cookie
on that request. Set `cookie_opts.same_site = .none` on the session
middleware, and keep `secure = true`. Apple sends `email_verified` as a
string; Anole reads it as a boolean. Apple sends the user's name only once,
in a `user` form field on the first sign-in, so `Identity.name` is null for
Apple.

The Google and Apple presets are tested against a fake provider, but not
yet against the live services.

## Sessions

`anole.session.Middleware` loads `req.session` before the handler and saves
it afterwards. It sets the cookie when the session changed or has data, and
expires the cookie when the handler cleared the session. In a handler, use
`req.session.set(k, v)`, `get`, `remove` and `clear`. A session holds at most
16 entries, with no NUL bytes in keys or values.

Pass `.key` for a sealed cookie, or `.store` for server-side sessions.
`Config` also has `cookie_name` (`anole_session`), `ttl_seconds` (24 h,
renewed by each response that carries the session) and `cookie_opts`
(`Path=/`, `HttpOnly`, `Secure`, `SameSite=Lax`). Chrome, Firefox and curl
keep `Secure` cookies on `http://localhost`; anywhere else, serve over HTTPS.

There are three ways to keep sessions:

| | Sealed cookie (`.key`) | `MemoryStore` | `RedisStore` |
| --- | --- | --- | --- |
| Where the data lives | In the cookie, encrypted with XChaCha20-Poly1305 | In this process | In Redis or Valkey |
| Cookie carries | All the data (keep it small) | A random 128-bit ID | A random 128-bit ID |
| Several nodes | Yes, with the same key on each | No | Yes |
| Server-side logout of every device | No: a copied cookie stays valid until it expires | Yes | Yes |
| Survives a restart | Yes, if the key does | No | Yes |

A sealed cookie that was changed, renamed or has expired is no session.
Make its key from 32 random bytes, keep it in your secret store, and give
every node the same one.

```zig
var mem = anole.session.MemoryStore.init(gpa, app.io()); // then .store = mem.store()
var redis = try anole.redis.Client.connect(gpa, app.io(), .{ .host = "127.0.0.1", .port = 6379 });
var rs: anole.session.RedisStore = .{ .client = redis, .gpa = gpa }; // keys "anole:session:<id>" with the TTL
var sessions = anole.session.Middleware.init(.{ .store = rs.store() });
```

A store is a vtable of `load`, `save` and `destroy` (`anole.session.Store`),
so you can bring your own.

A server-side session keeps its ID when someone signs in. There is no call
yet to issue a new ID, so with a store, clear the session on sign-in, or
use the sealed cookie for the signed-in state.

## CSRF

`anole.auth.csrf` uses synchronizer tokens kept in the session, so place it
after the session middleware. `csrf.token(req)` returns the session's token
and makes one on first use. Each token is 256 random bits, base64url. The
middleware refuses `POST`, `PUT`, `PATCH` and `DELETE` with 403 unless the
token comes back. A script sends it in the `X-CSRF-Token` header; a form
sends it in the `_csrf` field of an `application/x-www-form-urlencoded` body.
The token is compared in constant time.

```zig
var csrf = anole.auth.csrf.Middleware.init(.{});
// in the form: <input type="hidden" name="_csrf" value="{token}">
```

JSON bodies are not checked by default (`check_json = false`). A browser
can't send `application/json` to another site without a CORS preflight, as
long as your CORS policy doesn't allow it. Set `check_json = true` if you
allow cross-origin JSON with credentials. After a sign-in, call
`req.session.remove(anole.auth.csrf.session_key)` so the next page gets a
fresh token.

## Passwords

`anole.auth.password` stores Argon2id hashes as PHC strings, at OWASP's
baseline (m = 19 MiB, t = 2, p = 1).

```zig
var buf: [128]u8 = undefined;
const phc = try anole.auth.password.hash(gpa, io, plain, &buf);  // "$argon2id$v=19$m=19456,t=2,p=1$..."
const ok = anole.auth.password.verify(gpa, req.io, stored, plain); // also takes bcrypt "$2b$..."
if (ok and anole.auth.password.needsRehash(stored)) { ... hash again and store ... }
```

Pass a thread-safe allocator such as `init.gpa`, not `req.arena`: each call
allocates 19 MiB and frees it again. A hash runs on the request's executor
and keeps that thread busy, about 150 ms in a Debug build and much less in
ReleaseFast. A malformed stored hash counts as no match.

When the user name is unknown, verify against a dummy hash anyway, so the
answer takes as long as a wrong password does.

## API keys

`anole.auth.apikey.generate(arena, io)` returns `{ key, digest }`. The key
is `ak_` plus 256 random bits in base64url, 46 characters. Show the key to
its owner once. Store only the digest, a SHA-256: the key is random, so a
slow hash adds nothing.

`apikey.Middleware` takes the key from `Authorization: Bearer ak_...` or
`X-API-Key`, hashes it, and asks your lookup function for the owner. It
answers 401 with `WWW-Authenticate: Bearer` when there is no owner. The
owner goes into `req.session` as `"api_key_owner"` for that request only:
the middleware takes it out again when the handler returns, so a session
middleware in front never saves it into a cookie.

```zig
fn lookup(ptr: ?*anyopaque, arena: std.mem.Allocator, digest: anole.auth.apikey.Digest) anyerror!?[]const u8 {
    const db: *Db = @ptrCast(@alignCast(ptr.?));
    return db.ownerOfKeyDigest(arena, &digest); // null: no such key
}
var api_keys = anole.auth.apikey.Middleware.init(.{ .ptr = &db, .lookup = lookup });
```

## Roles (RBAC)

A `Policy` lists roles. Each role grants permissions, which are exact names,
`area:*` or `*`, and can include other roles. Inclusion cycles are safe.

```zig
const policy: anole.auth.rbac.Policy = .{ .roles = &.{
    .{ .name = "reader", .grants = &.{"notes:read"} },
    .{ .name = "editor", .grants = &.{"notes:*"}, .includes = &.{"reader"} },
    .{ .name = "admin", .grants = &.{"*"} },
} };
policy.allows("editor", "notes:write"); // true
```

`rbac.Require` is a middleware that answers 403 unless one of the request's
roles grants `permission`. Your `roles` function decides where the roles
come from: the session, a token's claims or an API key's owner. It returns
a slice that lives in `req.arena`.

```zig
var can_write: anole.auth.rbac.Require = .{ .policy = &policy, .permission = "notes:write", .roles = rolesOf };
```

## Rate limiting

`anole.ratelimit` keeps a token bucket per key. `Policy` allows `limit`
requests per `window_ms`, with a bucket of `burst`, which defaults to
`limit`.

`ratelimit.Middleware` sets the `RateLimit-Limit`, `RateLimit-Remaining` and
`RateLimit-Reset` headers on every response. Once a bucket is empty, it
answers 429 with `Retry-After`.

```zig
var limiter = anole.ratelimit.MemoryLimiter.init(gpa, app.io(), .{}); // max_entries 10_000, idle_ms 300_000
defer limiter.deinit();
var login_limit = anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 5, .window_ms = 60_000 });
```

- `MemoryLimiter` is for one process. It holds at most `max_entries` keys,
  dropping the least recently used one first, and forgets keys idle for
  `idle_ms`.
- `RedisLimiter` (`.{ .client = redis, .gpa = gpa }`, keys `anole:rl:<key>`)
  is shared by every node. One Lua script refills and takes atomically, on
  the Redis server's clock.
- Your own limiter implements `anole.ratelimit.Limiter`: a vtable with
  `take(ptr, key, cost, policy) !Result`.

The key is the client's address by default (`ratelimit.clientAddress`).
Behind a proxy, set `.server = .{ .trusted_proxy_hops = 1 }` in the server
options so that the address comes from `X-Forwarded-For`, or turn on the
listener's `proxy_protocol`.
Otherwise every client shares the proxy's bucket. To limit by something
else, such as an account or an API key, set the middleware's
`key: fn (req, buf: []u8) []const u8` field. `buf` is 128 bytes.

If the limiter fails, for example because Redis is down, the request is let
through and a warning is logged.

## Try the example

```sh
~/.local/zig/0.17.0/zig build run-auth -- 8084
```

It prints a demo JWT for alice and a demo API key. Every secret in it is
made at startup, so none survives a restart. The users are alice (editor)
and bob (reader), both with the password `demo-password`.

```sh
B=http://localhost:8084
T=$(curl -s -D - -c jar -b jar $B/login -o /dev/null | awk -F': ' 'tolower($1)=="x-csrf-token"{print $2}' | tr -d '\r')
curl -c jar -b jar -d user=alice -d password=demo-password $B/login             # 403: no CSRF token
curl -c jar -b jar -d user=alice -d password=demo-password -d _csrf=$T $B/login # signed in as alice
T=$(curl -s -c jar -b jar $B/me | awk '/^csrf:/{print $2}')                     # a fresh token
curl -c jar -b jar -X POST -H "X-CSRF-Token: $T" $B/notes                       # 201; bob gets 403 (reader)
curl -H "Authorization: Bearer <the printed JWT>" $B/api/me                     # token subject: alice
curl -H "X-API-Key: <the printed key>" $B/service/stats                         # stats for reporting-service
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w '%{http_code} ' -d user=x -d password=y $B/login; done
# 403 403 403 429 429 429: five POSTs a minute per address, the two above included
```
