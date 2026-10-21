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

### Bearer tokens

`anole.auth.RequireJwt` is a middleware that requires
`Authorization: Bearer <JWT>`. It verifies the token with your keys or a
`Keyring`, checks it against a `Policy` (the required issuer and audience
go there), and refuses the request as RFC 6750 says:

| Request | Answer |
| --- | --- |
| No `Authorization`, or another scheme | 401, `WWW-Authenticate: Bearer` |
| `Bearer` with no token, or more than one | 400, `error="invalid_request"` |
| A token that does not verify, or misses a required claim | 401, `error="invalid_token"` (expired ones also get an `error_description`) |
| A token without the required scopes | 403, `error="insufficient_scope"` |
| The keyring could not fetch the keys | 503, so the client keeps its token |

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

Keys are `.{ .static = &keys }` or `.{ .keyring = &keyring }`. The handler
gets the verified token from the request's locals
([routing.md](routing.md#request-locals)): `anole.auth.claims(req)` is the
`Verified` (claims and header as JSON objects, `string` and `integer` to
read one), `anole.auth.subject(req)` its `sub`. Both are null on a route
without `RequireJwt`. For claims that are arrays or objects, or checks of
your own, set `.hook = .{ .ptr = ..., .func = ... }`: it gets the whole
`Verified` before the handler, and an error from it refuses the token.

`.required_claims` lists string claims a token must carry; one without
them gets 401 `invalid_token`. It is `&.{"sub"}` by default, so
`anole.auth.subject(req)` is never null behind the middleware; `&.{}`
requires none. Nothing from the token goes into `req.session`.

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

For a provider's `jwks_uri`, use `anole.auth.Keyring`. Give it the
server's client, `app.client()` (or `anole.client(io)`), and the URL. It
fetches the set on first use, fetches it again after `ttl_seconds` (3600),
and fetches it once more when a token names an unknown `kid`. Providers rotate keys, but those
extra fetches are at least `min_refresh_seconds` (60) apart, so bogus tokens
can't make you hammer the provider.

```zig
var keyring = anole.auth.Keyring.init(gpa, app.io(), app.client(), "https://issuer.example/jwks.json");
defer keyring.deinit();
const v = try keyring.verify(req.arena, token, .{ .issuer = "https://issuer.example", .audience = "api" });
```

A fetch runs outside the keyring's lock, one at a time. Requests that
need it, because there are no keys yet, the keys are past their TTL, or the
token's `kid` is new, wait for that one fetch. If it fails, they get
`error.JwksFetchFailed`. Requests the current keys can verify don't wait,
and verification itself runs outside the lock.

## OIDC sign-in (Google, Apple)

`anole.auth.oidc` is a relying party. It is never a provider. It runs the
authorization-code flow with PKCE (S256), a random `state` and `nonce`, and
the ID-token checks of OIDC Core 3.1.3.7: signature, `iss`, `aud`, `exp`,
`iat`, `azp` and `nonce`. The logic is ported from liboauth2.

You need a `Provider`, a `Keyring` on its `jwks_uri`, and a `RelyingParty`:

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
const id = rp.finish(req.arena, req.io, anole.client(req), callback, saved) catch |err| {
    std.log.info("sign-in refused: {t}", .{err}); // StateMismatch, NonceMismatch, TokenRequestFailed, ...
    return refuse(res);
};
for ([_][]const u8{ "oidc_state", "oidc_nonce", "oidc_verifier" }) |k| req.session.remove(k);
try req.session.set("user", id.subject); // the stable account key
try anole.session.regenerate(req);       // a new session id for the signed-in session
```

`refuse` is your own function that answers 400 with a body, such as
`res.fail(.bad_request, "sign-in failed")`. Returning `error.BadRequest`
from the handler gives the same status with the status line as the body.

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
`init` returns an error union: in cookie mode it refuses to start without
a key (`error.SessionKeyMissing`, with the fix in the log), so a forgotten
key never gives cookies anyone could forge or read. `Config` also has
`cookie_name` (`anole_session`), `ttl_seconds` (24 h,
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
every node the same one. `anole.session.keyFromBase64` reads it from
configuration (`openssl rand -base64 32` makes one); a missing key, or
one of all zeros, is refused. For local development only,
`anole.session.devKey(io)` makes a random key and logs a warning: sessions
then end on every restart and differ between nodes.

```zig
const key = try anole.session.keyFromBase64(init.environ_map.get("SESSION_KEY") orelse return error.NoSessionKey);
app.use(try anole.session.Middleware.init(.{ .key = key }));
// local development: .{ .key = anole.session.devKey(app.io()) }
```

```zig
var mem = anole.session.MemoryStore.init(gpa, app.io()); // then .store = mem.store()
const redis = try app.redis(.{}); // REDIS_URL, else redis://127.0.0.1:6379 (docs/database.md)
var rs: anole.session.RedisStore = .{ .client = redis, .gpa = gpa }; // keys "anole:session:<id>" with the TTL
var sessions = try anole.session.Middleware.init(.{ .store = rs.store() });
```

A store is a vtable of `load`, `save` and `destroy` (`anole.session.Store`),
so you can bring your own.

### A new session at sign-in

Call `anole.session.regenerate(req)` when someone signs in, or when their
privileges change. Otherwise an attacker who planted a session ID in the
victim's browser before the sign-in would share the signed-in session
(session fixation). With a store, the middleware destroys the old ID in the
store when it saves the response, then saves the data under a fresh ID and
sends the new cookie. The data itself carries over.

```zig
try req.session.set("user", user.name);
try anole.session.regenerate(req);
```

A sealed cookie has no ID. `regenerate` makes the middleware seal it afresh
(a new nonce), which it does on every save anyway. A copy of the old cookie
stays valid until it expires, but it holds only what the session held
before the sign-in, and nobody can forge one with a user in it without the
key.

`regenerate` uses one of the session's 16 entries, under
`anole.session.regenerate_key`, until the response is saved. The middleware
takes it out before saving.

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
allocates 19 MiB and frees it again. A hash takes about 150 ms in a Debug
build and much less in ReleaseFast. With the server's blocking pool
(`.blocking = .{}` in the server options, see
[server.md](server.md#blocking-work)), `hash` and `verify` run on a pool
thread while the request waits, and the executor goes on serving. Without
it, they keep the request's executor busy for that long. `hashHere` and
`verifyHere` always run on the calling thread. A malformed stored hash
counts as no match, and so does a request canceled while `verify` runs.

When the user name is unknown, verify against a dummy hash anyway, so the
answer takes as long as a wrong password does.

## API keys

`anole.auth.apikey.generate(arena, io)` returns `{ key, digest }`. The key
is `ak_` plus 256 random bits in base64url, 46 characters. Show the key to
its owner once. Store only the digest, a SHA-256: the key is random, so a
slow hash adds nothing.

`apikey.Middleware` takes the key from the request (`apikey.fromRequest`),
hashes it, and asks your lookup function for the owner. It answers 401 with
`WWW-Authenticate: Bearer` when there is no owner. The handler reads the
owner with `anole.auth.apikey.owner(req)` (from the request's locals).

The key can come in two headers:

- `X-API-Key: <key>`, with any value: the header means nothing else, so
  keys without the prefix (imported from another system) work there.
- `Authorization: Bearer ak_...`, only with the `ak_` prefix. JWTs use the
  same header (`RequireJwt`), and the prefix is what tells the two apart:
  a bearer token without it is not an API key.

When both are sent, the bearer form wins.

```zig
fn lookup(ptr: ?*anyopaque, arena: std.mem.Allocator, digest: anole.auth.apikey.Digest) anyerror!?[]const u8 {
    const db: *Db = @ptrCast(@alignCast(ptr.?));
    return db.ownerOfKeyDigest(arena, &digest); // null: no such key
}
var api_keys = anole.auth.apikey.Middleware.init(.{ .ptr = &db, .lookup = lookup });
```

## Client certificates

Mutual TLS is a listener setting (`https.client_auth`, in
[docs/server.md](server.md#tls)), and it covers HTTP/3 as well. A handler or
middleware reads the verified certificate with `req.peerCertificate()`, the
leaf as DER or `null`, the same way over HTTP/1.1, HTTP/2 and HTTP/3. Map it
to an owner as you would an API key, for example by the SHA-256 of the DER or
by a subject name from `std.crypto.Certificate`.

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
roles grants `permission`. Your roles function decides where the roles
come from: the session, a token's claims, an API key's owner or your app's
state. It gets the `ptr` you pass with it, and returns a slice in
`req.arena` or longer-lived memory. An error from it becomes a 500.

```zig
fn rolesOf(ctx: ?*anyopaque, req: *anole.Request) anyerror![]const []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    return app.rolesOfUser(req.arena, req.session.get("user") orelse return &.{});
}
var can_write = anole.auth.rbac.Require.init(&policy, "notes:write", .{ .ptr = &app, .roles = rolesOf });
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
var per_key = anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 1000, .key = byApiKey, .on_error = .deny });
```

- `MemoryLimiter` is for one process. It holds at most `max_entries` keys,
  dropping the least recently used one first, and forgets keys idle for
  `idle_ms`.
- `RedisLimiter` (`.{ .client = redis, .gpa = gpa }` with `redis` from
  `app.redis(.{})`, keys `anole:rl:<key>`)
  is shared by every node. One Lua script refills and takes atomically, on
  the Redis server's clock.
- Your own limiter implements `anole.ratelimit.Limiter`: a vtable with
  `take(ptr, key, cost, policy) !Result`.

The key is the client's address by default (`ratelimit.clientAddress`).
Behind a proxy, set `.server = .{ .trusted_proxy_hops = 1 }` in the server
options so that the address comes from `X-Forwarded-For`, or turn on the
listener's `proxy_protocol`.
Otherwise every client shares the proxy's bucket. To limit by something
else, such as an account or an API key, pass `.key`, a
`fn (req: *anole.Request, buf: []u8) []const u8` that returns the key,
written into `buf` (128 bytes) or pointing into the request:

```zig
fn byApiKey(req: *anole.Request, _: []u8) []const u8 {
    return anole.auth.apikey.fromRequest(req) orelse "anonymous";
}
```

If the limiter fails, for example because Redis is down, `.on_error`
decides: `.allow` (the default) lets the request through, `.deny` answers
503 Service Unavailable. A warning is logged either way. Deny where an
unlimited burst costs more than an outage, such as a login.

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
