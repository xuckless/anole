# Request and response

Up: [index](index.md). Full docs: docs/routing.md (The request, The response), docs/validation.md. Examples: examples/rest.
Related: [server-routes.md](server-routes.md), [typed-validation.md](typed-validation.md), [errors](../middleware-auth/errors.md).

## Path parameters and the query string

Use: `req.params.get` / `getInt` / `getFloat`, `req.query.get` / `getInt`, short forms `anole.Request.param` and `anole.Request.queryParam`, decoding with `anole.Request.paramDecoded` (src/http/core/request.zig).

```zig
fn getUser(req: *anole.Request, res: *anole.Response) !void {
    const id = req.params.getInt(u64, "id") orelse return error.NotFound;
    const fields = req.query.get("fields") orelse "all";
    try res.print(.text, "user {d} ({s})", .{ id, fields });
}
```

```zig
// GET /users/J%C3%BCrgen
const name = (try req.paramDecoded("name")).?; // "Jürgen"; req.params keeps "J%C3%BCrgen"
```

Traps:
- `getInt` / `getFloat` return null for a missing or malformed value: map null to `error.NotFound` (path) or a default (query).
- Path params are raw bytes (an encoded `/` never splits a segment); query values are already decoded.
- For a whole typed query, use `req.bindQuery(T)` or `anole.In(.{ .query = T })` instead of many `query.get` calls ([typed-validation.md](typed-validation.md)).

## Reading the body

Use: `anole.Request.bind` (JSON into `T`, runs `field_rules`), `anole.Request.json` (null for an empty body), `anole.Request.bindQuery`, `anole.Request.bindPath`, `anole.Request.bindHeaders`, `anole.Request.body`, `anole.Request.formData` (src/http/core/request.zig).

```zig
const NewUser = struct { name: []const u8, email: []const u8 };

fn createUser(req: *anole.Request, res: *anole.Response) !void {
    const user = try req.bind(NewUser); // 400 when missing or malformed
    res.status = .created;
    try res.json(.{ .name = user.name });
}
```

| Call | Problem answer |
| --- | --- |
| `req.bind(T)` | no body 400 (`MissingBody`), bad JSON 400 (`InvalidJsonBody`), wrong type / missing field / broken rule 422 (`ValidationFailed`) |
| `req.bindQuery(T)` | violations 422 (`in: "query"`); a broken escape 400 |
| `req.bindPath(T)` | anything 404 |
| `req.body()` | over `limits.body_max` (1 MiB) 413 |

Traps:
- The body is read once: a second `reader`, or `body()` after `reader`, is `error.BodyReaderTaken`.
- Everything `bind` returns lives in `req.arena`. Copy before storing; see [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).
- Raise `limits.body_max` in `ServerOptions` (`.limits = .{ .body_max = 8 << 20 }`) rather than reading around it.

## Request fields you will use

- `req.headers.get(name)` (case-insensitive), `req.cookies().get(name)`, `req.host()`, `req.remote_address`, `req.secure`, `req.id` (set by `RequestId`).
- `req.arena`: an allocator freed after the response; for per-request scratch (`std.fmt.allocPrint(req.arena, ...)`).
- `req.io`: the server's `std.Io`. Every wait through it (sleep, socket, file, outbound call, `std.Io.Mutex`) suspends only this request.
- `req.setLocal(key, value)` / `req.local(T, key)`: values a middleware hands to the handler; see [middleware.md](../middleware-auth/middleware.md#request-locals).

Traps:
- `req.arena` is not thread-safe. A task started with `req.io.concurrent` needs memory of its own (Debug builds panic on two tasks allocating at once).
- Blocking C calls or long CPU work hold the executor: see [never block an executor](../runtime.md#never-block-an-executor).

## Writing the response

Nothing is sent before the handler returns unless you stream.

Use: `res.status`, `res.content_type`, `res.body`, `anole.Response.json`, `anole.Response.print`, `anole.Response.header`, `anole.Response.addHeader`, `anole.Response.fail`, `anole.Response.problem` (src/http/core/response.zig); `anole.Problem` (src/http/core/http.zig).

```zig
res.status = .created;
res.content_type = .json; // .text, .html, .css, .js, .csv, .pdf, ...
try res.header("Location", "/users/42"); // replaces one of the same name
res.body = "{\"id\":42}"; // must outlive the handler: a literal or res.arena
```

```zig
fn requireKey(req: *anole.Request, res: *anole.Response, next: anole.Next) !void {
    if (req.headers.get("X-Api-Key") == null) return res.fail(.unauthorized, "missing API key");
    return next.call();
}
```

`res.problem(.{ .status = .conflict, .detail = "already exists" })` answers an RFC 9457 `application/problem+json` document (the same shape as the 422 from validation).

Traps:
- `res.body` must outlive the handler; `res.json` and `res.print` copy for you.
- `res.header` replaces; `res.addHeader` adds one that may repeat (`Vary`, `Link`). Both can fail (`TooManyHeaders`, `HeadersAlreadySent` after `res.stream`), so `try` them.
- `res.fail(status, message)` replaces whatever was written; its body is `{"error":"..."}` or text by `ServerOptions.errors` ([errors](../middleware-auth/errors.md)).

## Handler errors are statuses

Return an error instead of building the error response by hand: `error.NotFound` is 404, `error.Unauthorized` 401, `error.Forbidden` 403, `error.Conflict` 409, `error.TooManyRequests` 429; any standard 4xx/5xx by its `std.http.Status` tag in PascalCase. Anything else is logged and answered 500. The full mapping and custom handlers: [errors.md](../middleware-auth/errors.md).

```zig
fn get(store: *Store, req: *anole.Request, res: *anole.Response) !void {
    try store.mutex.lock(req.io);
    defer store.mutex.unlock(req.io);
    try res.json(store.users.get(try userId(req)) orelse return error.NotFound);
}
```
