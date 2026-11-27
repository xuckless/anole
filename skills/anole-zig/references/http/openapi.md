# OpenAPI

Up: [index](index.md). Full docs: docs/openapi.md. Examples: templates/minimal, templates/rest-postgres, templates/grpc.
Related: [typed-validation.md](typed-validation.md), [grpc.md](grpc.md).

Anole writes an OpenAPI 3.1 document from the code: typed handler signatures, `field_rules`, middleware security and gRPC services. Do not write the spec by hand or annotate twice. Needs `-Dopenapi` (on in the `web` and `full` profiles); `anole.doc` and the declaration types compile in every profile.

## Serve the document: `app.openapi`

Use: `anole.App.openapi`, `anole.App.openapiDocument` (src/server.zig); options `anole.openapi.Options` (src/openapi/root.zig): `info`, `servers`, `path` (`/openapi.json`), `page` (`/docs`, null for none), `serve`, `listener`, `grpc`, `tags`, `tags_from_path`, `rename`.

```zig
var app = try anole.App.init(init.gpa, .{});
app.openapi(.{ .info = .{ .title = "Todos", .version = "1.0.0" } });
app.get("/todos/:id", getTodo);
```

- `serve`: `.development` (default; production 404s), `.always`, `.never`.
- `zig build openapi` writes `openapi.json`; `zig build openapi-check` fails when it no longer matches (CI). Both come with `addApp`.

Traps:
- `zig build openapi` runs `main` up to the routes: code before `listen` still runs, so a `main` that needs a secret needs it in `.env` or the environment. Connectors are lazy by default, so no database is needed.
- Not in the document: `any`, `ws`, `webtransport`, `static`, `embedded`, `QUERY` routes and helper routes (`/metrics`, health).
- Two types with one name stop the document (`error.OpenApiNameClash`); give one a `.name`, or `rename` it.

## What a typed handler gives the document

```zig
fn getTodo(req: *anole.Request, in: anole.In(.{ .path = struct { id: u64 } })) error{NotFound}!Todo
fn create(req: *anole.Request, in: anole.In(.{ .body = NewTodo })) !anole.Created(Todo)
fn list(req: *anole.Request, in: anole.In(.{ .query = struct { limit: u32 = 50 } })) ![]const Todo
```

Parameters, request body, the success status (`Created` 201, `Accepted` 202, `void` 204), 422 when there is input, and one response per status-named error in an explicit error set. An `anyerror` (or inferred `!`) set lists none.

## Texts and plain handlers: `anole.doc`

Use: `anole.doc` (src/handlers.zig), texts `anole.openapi.RouteDoc` (src/openapi/declarations.zig): `summary`, `description`, `tags`, `operation_id`, `deprecated`, `hidden`, `responses` for any handler; `body`, `query`, `headers`, `response`, `status`, `errors` for a plain `(req, res)` handler only.

```zig
app.get("/export", anole.doc(.{
    .summary = "Export everything",
    .response = []const Todo,
    .responses = &.{.{ .status = .not_modified, .description = "Unchanged" }},
}, export_all));
```

Traps:
- Giving `body`/`response`/... to a typed handler is a compile error: its signature already says them.
- `anole.doc` combines with `anole.noWait` and `anole.cached` in any order.

## Texts on types: `pub const openapi`

Use: `anole.openapi.Doc` (src/openapi/declarations.zig). Fields: `name`, `description`, `deprecated`, `example`, `examples`, `fields`, `as`.

```zig
const Todo = struct {
    id: u64,
    title: []const u8,

    pub const openapi: anole.openapi.Doc(@This()) = .{
        .description = "A thing to do.",
        .example = .{ .id = 1, .title = "write docs" },
        .fields = .{ .title = .{ .description = "What to do." } },
    };
};
```

Traps:
- A type with its own `jsonStringify` must set `.as = <a type with the same JSON>`, or the build stops.
- `field_rules` become schema keywords (`maxLength`, `format`, ...): do not repeat them in descriptions.

## Security of a function middleware: `anole.openapi.middleware`

The built-in auth and rate-limit middleware already declare their schemes. For a function middleware of your own, wrap it with `anole.openapi.middleware` (src/openapi/root.zig) and an `anole.openapi.MiddlewareDoc`:

```zig
app.use(anole.openapi.middleware(.{
    .security_schemes = &.{.{ .name = "tenant", .kind = .{ .api_key = .{ .in = .header, .param = "X-Tenant" } } }},
    .security = .any,
    .responses = .{ .unauthorized = .{ .description = "Unknown tenant" } },
}, requireTenant));
```
