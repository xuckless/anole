# Rate limits

Up: [index](index.md). Full docs: docs/auth.md (Rate limiting). Examples: examples/auth, templates/full.
Related: [middleware.md](middleware.md), [keys-passwords-roles.md](keys-passwords-roles.md), [deployment.md](../deployment/index.md).

Token buckets per key, with `RateLimit-*` headers on every response and 429 with `Retry-After` once empty.

## One line for the whole app: `app.rateLimit`

Use: `anole.App.rateLimit`, `anole.App.RateLimitOptions` (src/server.zig): `limit` (100), `window` (60 s), `burst` (0 means `limit`), `key` (`.ip` or `.{ .header = "..." }`), `max_entries` (10 000). An in-memory limiter the server owns, applied with `use`.

```zig
app.rateLimit(.{ .limit = 300 }); // 300 requests a minute per client address
```

Traps:
- It is a `use`: call it before the routes.
- `.key = .{ .header = ... }` counts by a raw header the client chooses; prefer a verified identity (below).

## Per route or group: `anole.ratelimit.Middleware`

Use: `anole.ratelimit.Middleware`, `anole.ratelimit.MemoryLimiter`, `anole.ratelimit.RedisLimiter`, `anole.ratelimit.Policy`, `anole.ratelimit.Limiter`, `anole.ratelimit.clientAddress`, `anole.ratelimit.clientAddressPrefix` (src/ratelimit/root.zig).

```zig
var limiter = anole.ratelimit.MemoryLimiter.init(gpa, app.io(), .{}); // max_entries 10_000, idle 5 minutes
defer limiter.deinit();
var login_limit = anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 5, .window = .fromSeconds(60) });
var per_key = anole.ratelimit.Middleware.init(limiter.limiter(), .{ .limit = 1000, .key = byApiKeyOwner, .on_error = .deny });
```

Key on an identity that was checked, never a raw header, falling back to the address:

```zig
// After anole.auth.apikey.Middleware, so the owner is a key that exists.
fn byApiKeyOwner(req: *anole.Request, buf: []u8) []const u8 {
    if (anole.auth.apikey.owner(req)) |owner| {
        return std.fmt.bufPrint(buf, "key:{s}", .{owner}) catch owner;
    }
    return anole.ratelimit.clientAddress(req, buf);
}
```

- Default key: the client address (IPv6 by its /64). `.key = anole.ratelimit.clientAddressPrefix(56)` groups by another prefix.
- `RedisLimiter` (`.{ .client = redis, .gpa = gpa }`, `redis` from `app.redis(.{})`) is shared by every node.
- `.on_error`: `.allow` (default) or `.deny` (503) when the limiter fails. Deny on a login.

Traps:
- Make a `Middleware` with `init`, never as a struct literal: `init` gives it its scope.
- Each `init` is its own policy with its own buckets; one value in several groups is one policy. Use [handles](middleware.md#sharing-one-middleware-value) to share it.
- Order: put the login limit first, so requests later middleware refuses still count. Put a limit keyed on an identity after the auth middleware that verified it.
- Behind a proxy, set `.proxy = .{ .trusted_hops = 1 }` in `ServerOptions` (or the listener's `proxy_protocol`), or every client shares the proxy's bucket.
- `RedisLimiter` on nodes that create their middlewares in a different order needs an explicit `.scope` below 2^31.
