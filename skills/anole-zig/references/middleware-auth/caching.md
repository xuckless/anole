# Response cache

Up: [index](index.md). Full docs: docs/routing.md (Response cache). Examples: src/cache/response_test.zig.
Related: [middleware.md](middleware.md), [http/static.md](../http/static.md). Row caching is in [databases](../databases/index.md).

Whole responses kept per executor and answered from memory without running the handler. Do not build a map-plus-TTL cache in front of handlers.

## One route: `anole.cached`

Use: `anole.cached` (src/handlers.zig); options `anole.middleware.ResponseCache.Options` (src/cache/response.zig): `ttl` (10 s), `max_entries` (1024), `max_bytes` (16 MiB), `max_entry_bytes` (1 MiB), `authenticated` (false), `credential_headers` (`Authorization`, `Cookie`, `X-API-Key`), `cacheable`, `name`.

```zig
app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed));
```

```zig
// A session token in a header of the app's own.
app.get("/me", anole.cached(.{ .ttl = .fromSeconds(5), .credential_headers = &.{ "Authorization", "Cookie", "X-API-Key", "X-Session-Token" } }, me));
// Any per-request rule.
fn anonymousOnly(req: *const anole.Request) bool {
    return req.headers.get("X-Tenant") == null;
}
app.get("/news", anole.cached(.{ .ttl = .fromSeconds(5), .cacheable = anonymousOnly }, news));
```

## Several routes, with invalidation: `app.responseCache`

Use: `anole.App.responseCache` (src/server.zig) returns a server-owned `*anole.middleware.ResponseCache`; put it in `with`, `group` or `use`; `ResponseCache.invalidate(.all)` or `.{ .path = "/posts/7" }` reaches every executor.

```zig
const App = struct { db: *anole.pg.Client, pages: *anole.middleware.ResponseCache };

state.pages = app.responseCache(.{ .ttl = .fromSeconds(60), .name = "pages" });
app.with(.{state.pages}).get("/posts/:id", showPost);
app.put("/posts/:id", editPost);

fn editPost(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.get("id").?;
    // ... the update ...
    app.pages.invalidate(.{ .path = try std.fmt.allocPrint(req.arena, "/posts/{s}", .{id}) });
    res.status = .no_content;
}
```

What is kept: GET answers (HEAD served from them) with status 200, 203, 204, 300, 301, 308, 404 or 410, in-memory bodies up to `max_entry_bytes`. Not kept: responses that set a cookie, `Cache-Control: no-store / no-cache / private`, streams, `sendFile`, `Vary: *`. `s-maxage` / `max-age` override `ttl`.

Traps:
- A cached answer goes to everyone who asks for the same URL. Requests with `Authorization`, `Cookie`, `X-API-Key` or a client certificate bypass the cache; a user identified any other way (a header of your own, the client address) would get another user's page. Add such headers to `credential_headers` or refuse them in `cacheable`.
- Authentication after the cache is skipped on a hit: put auth middleware before the cache, or cache public routes only.
- `anole.cached` is only for GET and HEAD routes (compile error otherwise).
- Each executor keeps its own entries, so two executors may answer from responses up to `ttl` apart.
- Large downloads and files belong to `staticDir`, not the cache.
