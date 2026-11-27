# Passwords, API keys and roles

Up: [index](index.md). Full docs: docs/auth.md (Passwords, API keys, Client certificates, Roles). Examples: examples/auth, templates/full.
Related: [jwt-oidc.md](jwt-oidc.md), [sessions-csrf.md](sessions-csrf.md), [ratelimit.md](ratelimit.md).

## Passwords: `anole.auth.password`

Argon2id PHC strings at OWASP's baseline; `verify` also takes bcrypt. Do not hash passwords with a fast hash or hand-roll Argon2.

Use: `anole.auth.password.hash`, `verify`, `needsRehash`, `hashHere`, `verifyHere` (src/auth/password.zig).

```zig
var buf: [128]u8 = undefined;
const phc = try anole.auth.password.hash(gpa, io, plain, &buf);  // "$argon2id$v=19$m=19456,t=2,p=1$..."
const ok = try anole.auth.password.verify(gpa, req.io, stored, plain); // also takes bcrypt "$2b$..."
if (ok and anole.auth.password.needsRehash(stored)) { ... hash again and store ... }
```

A login that does not reveal which users exist (examples/auth):

```zig
const stored = if (user) |u| u.hash else app.dummy_hash;
const ok = try auth.password.verify(app.gpa, req.io, stored, form.get("password") orelse "");
if (!ok or user == null) return res.fail(.unauthorized, "wrong user or password");
```

Traps:
- Set `.blocking = .{}` in `ServerOptions`: then `hash` and `verify` run on the blocking pool; without it each call holds the executor about 150 ms (Debug). See [never block an executor](../runtime.md#never-block-an-executor).
- Pass a thread-safe allocator (`init.gpa`), not `req.arena`: each call allocates 19 MiB.
- `verify` can fail with `error.ServiceUnavailable` (the pool's queue is full): `try` it, it becomes a 503.
- Verify against a dummy hash when the user is unknown, as above.
- Rate-limit the login route ([ratelimit.md](ratelimit.md)).

## API keys

Random `ak_` keys, stored as SHA-256 digests.

Use: `anole.auth.apikey.generate`, `anole.auth.apikey.digest`, `anole.auth.apikey.Digest`, `anole.auth.apikey.Middleware`, `anole.auth.apikey.Lookup`, `anole.auth.apikey.owner`, `anole.auth.apikey.fromRequest` (src/auth/apikey.zig).

```zig
fn lookupKey(ptr: ?*anyopaque, _: std.mem.Allocator, digest: auth.apikey.Digest) anyerror!?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ptr.?));
    return if (std.mem.eql(u8, &digest, &app.api_key_digest)) "reporting-service" else null;
}

var api_keys = auth.apikey.Middleware.init(.{ .ptr = &app, .lookup = lookupKey });
// in a handler:
const owner = auth.apikey.owner(req) orelse return error.Unauthorized;
```

- `generate(arena, io)` returns `{ key, digest }`: show `key` once, store only `digest`.
- The key comes in `X-API-Key: <key>` or `Authorization: Bearer ak_...` (only with the prefix; the bearer form wins).
- No owner: 401 with `WWW-Authenticate: Bearer`.

Traps:
- A lookup that queries a database may wait, so that middleware is not `no_wait`.
- Store only the digest; the key is random, so a slow hash adds nothing.

## Client certificates

Mutual TLS is a listener setting (`https.client_auth`, docs/server.md TLS). Read the verified leaf (DER or null) with `req.peerCertificate()` and map it to an owner as you would an API key.

## Roles: `anole.auth.rbac`

Use: `anole.auth.rbac.Policy`, `anole.auth.rbac.Role`, `anole.auth.rbac.Require` (`init(&policy, permission, roles)`), `anole.auth.rbac.Roles`, `anole.auth.rbac.RolesFn` (src/auth/rbac.zig). Permissions are exact names, `area:*` or `*`; roles can include others.

```zig
const policy: auth.rbac.Policy = .{ .roles = &.{
    .{ .name = "reader", .grants = &.{"notes:read"} },
    .{ .name = "editor", .grants = &.{"notes:*"}, .includes = &.{"reader"} },
} };

/// The request's roles: the verified token's `role` claim.
fn rolesOf(_: ?*anyopaque, req: *anole.Request) anyerror![]const []const u8 {
    const claims = auth.claims(req) orelse return &.{};
    const role = claims.string("role") orelse return &.{};
    const roles = try req.arena.alloc([]const u8, 1);
    roles[0] = role;
    return roles;
}

const api = app.group("/api", .{bearer});
api.with(.{auth.rbac.Require.init(&policy, "notes:write", .{ .roles = rolesOf })}).post("/notes", addNote);
```

Traps:
- `Require` answers 403 unless a role grants the permission; an error from the roles function is a 500.
- Put `Require` after the middleware that establishes who the caller is (`RequireJwt`, the session), since it reads their result.
- The roles slice must live in `req.arena` or longer-lived memory.
