# Error answers

Up: [index](index.md). Full docs: docs/routing.md (Error handling), docs/validation.md (The 422 document). Examples: examples/rest.
Related: [http/request-response.md](../http/request-response.md), [http/typed-validation.md](../http/typed-validation.md), [middleware.md](middleware.md).

A handler or middleware returns an error to give up; the error decides the answer. Do not write a 404/401 response by hand when an error says it.

## Status-named errors

- An error named after a status answers with it: `error.Unauthorized` 401, `error.Forbidden` 403, `error.NotFound` 404, `error.Conflict` 409, `error.UnprocessableEntity` 422, `error.TooManyRequests` 429, `error.ServiceUnavailable` 503. Any standard 4xx/5xx counts, by its `std.http.Status` tag in PascalCase or its RFC 9110 reason phrase.
- Request-body faults: `BodyTooBig` 413, `UnsupportedContentEncoding` 415, `InvalidJsonBody` / `MissingBody` / `IncompleteBody` / `MalformedBody` 400; `BadPathName` from `sendFile` 404. `error.ValidationFailed` is the 422 problem document.
- The database layer maps no row to `error.NotFound` and a unique violation to `error.Conflict` ([databases](../databases/index.md)).
- Anything else is logged at `err` and answered 500; what the handler wrote is discarded.
- Once a handler has started streaming no error answer can be sent: the connection is closed.

Use: `anole.errorStatus` (src/http/core/middleware.zig) says which status an error stands for, or null for a 500.

Traps:
- A panic is not an error: it ends the process. Prefer `orelse return error.NotFound` to `.?`, and build servers `ReleaseSafe`.
- Code that catches `error.Canceled` must re-raise it: see [re-raise error.Canceled](../runtime.md#re-raise-errorcanceled).

## A message of your own: `res.fail` and `res.problem`

`res.fail(status, message)` sets the status and replaces whatever was written; `res.problem(.{ ... })` answers an RFC 9457 document ([request-response.md](../http/request-response.md#writing-the-response)).

## The body format: `ServerOptions.errors`

`.auto` (default): `{"error":"..."}` for a request that takes or sent JSON, text otherwise; `.json` for an API; `.text` always text. An empty message stands for the status line.

```zig
var app = try anole.Server(Store).init(init.gpa, .{ .errors = .json }, &store);
```

## Answer errors yourself: `error_handler` and `anole.defaultError`

Use: `ServerOptions.error_handler` (src/server.zig; type `anole.http.ErrorHandler`), `anole.defaultError` (src/http/core/middleware.zig) for the rest.

```zig
fn onError(req: *anole.Request, res: *anole.Response, err: anyerror) void {
    switch (err) {
        error.OutOfStock => res.fail(.conflict, "out of stock"),
        else => anole.defaultError(req, res, err),
    }
}

var app = try anole.Server(void).init(gpa, .{ .error_handler = onError }, {});
```

## Declarations on `Ctx`: `uncaughtError`, `notFound`, `methodNotAllowed`, `dispatch`

With a context, these declarations on `Ctx` answer errors, 404s and 405s:

```zig
const App = struct {
    pub fn notFound(_: *App, req: *anole.Request, res: *anole.Response) !void {
        res.status = .not_found;
        try res.json(.{ .@"error" = "not found", .path = req.url });
    }

    pub fn uncaughtError(_: *App, req: *anole.Request, res: *anole.Response, err: anyerror) void {
        std.log.err("{s} {s}: {t}", .{ req.id, req.url, err });
        anole.defaultError(req, res, err);
    }
};
```

- `methodNotAllowed` has the signature of `notFound` and finds `Allow` already set.
- `dispatch(self, action, req, res)` wraps every handler call.

Traps:
- `uncaughtError` comes before `error_handler`; either replaces the built-in mapping unless it calls `anole.defaultError`.
- Built-in auth and rate-limit middleware refuse with status-named errors and set their headers first (`WWW-Authenticate`, `Retry-After`, `RateLimit-*`); a custom handler keeps those headers, so do not clear them.
- 4xx answers are logged at `debug`, 5xx at `err`.
