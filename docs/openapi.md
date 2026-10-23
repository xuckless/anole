# OpenAPI

Anole writes an OpenAPI 3.1 document from your code: the typed handlers' inputs
and outputs, the validator's rules, the middleware's security and your gRPC
services. Nothing is written twice, so the document can't drift from what the
server does. The page that shows it (Scalar) is served in development.

It needs `-Dopenapi`, on in the `web` and `full` profiles and off in
`minimal`. Typed handlers and `anole.doc` work without it; the document and
the page drop out.

```zig
var app = try anole.App.init(init.gpa, .{});
app.openapi(.{ .info = .{ .title = "Todos", .version = "1.0.0" } });
app.get("/todos/:id", getTodo);
```

## Where it comes from

A typed handler says what it takes and gives in its signature:

```zig
fn getTodo(req: *anole.Request, in: anole.In(.{ .path = struct { id: u64 } })) error{NotFound}!Todo
fn create(req: *anole.Request, in: anole.In(.{ .body = NewTodo })) !anole.Created(Todo)
fn list(req: *anole.Request, in: anole.In(.{ .query = struct { limit: u32 = 50 } })) ![]const Todo
```

(The shapes are in [routing.md](routing.md#typed-handlers).) From these the
document gets, per route:

- **parameters**: path, query and header fields, with their types, defaults and
  rules. Query lists (`[]const T`) are `explode: true`, one key per item;
- **the request body**: the `.body` type, with `required` for fields that are
  neither optional nor defaulted;
- **responses**: the success status of the return type (`anole.Created` is
  201 with a `Location` header, `anole.Accepted` 202, a `void` result 204),
  400 for a malformed body, 404 when there are path parameters, 422
  `application/problem+json` when there is a body, a query or headers, and
  one response for each status-named error the handler can return
  (`error.NotFound`, `error.Conflict`). A handler whose error set is
  `anyerror` lists none of these; the default 500 is implicit everywhere;
- **`operationId`**: the method and path in camel case (`getUsersByIdPosts`),
  `_2` for a repeat, or what you set;
- **tags**: the first path segment that is not `api` or a version
  (`/api/v1/todos/:id` is `todos`), or what you set.

A plain `(req, res)` handler is in the document too, with its method and
path. Give it more through `anole.doc`:

```zig
app.get("/export", anole.doc(.{
    .summary = "Export everything",
    .response = []const Todo,
    .responses = &.{.{ .status = .not_modified, .description = "Unchanged" }},
}, export_all));
```

`anole.doc(texts, handler)` takes `summary`, `description`, `tags`,
`operation_id`, `deprecated`, `hidden` (left out of the document) and
`responses` for any handler, and `body`, `query`, `headers`, `response`,
`status` and `errors` for a plain one only (a typed handler's signature
already says them: giving them is a compile error). It combines with
`anole.noWait` and `anole.cached` in any order.

## Schemas of your types

The schema of a type is what `std.json` reads and writes (what `req.bind`
and `res.json` use): structs are objects, `?T` is nullable and not required,
a field with a default is not required and shows its `default`, a `union(enum)`
is an object with one key, an enum is a string. A struct with a name is a
component (`#/components/schemas/Todo`); one without a name stands inline.

**Validator rules become keywords.** The rules in `field_rules` are merged into
the field's schema (`maxLength`, `minimum`, `pattern`, `format`, `enum`...); a
rule the schema can't say exactly adds a sentence to the description. A field
renamed by `v.rename` has its outside name. You never write constraints twice.

**Texts** go in a `pub const openapi` declaration of the type:

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

`name` renames the component, `deprecated`, `example` and `examples` are as
you'd expect. A type with its own `jsonStringify` must say what it writes with
`.as = <a type with the same JSON>`, or the build stops with a message that
says so.

**Two types with one name** stop the document: `error.OpenApiNameClash`, and
the log names both types. Give one a `.name`, or rename it where you can't edit
it (generated protobuf messages): `app.openapi(.{ .rename = &.{.{ .type_name =
"billing_pb.Invoice", .name = "BillingInvoice" }} })`, where `type_name` is the
`@typeName` the message prints.

## Security

A middleware type says how it knows the client with a `pub const openapi:
anole.openapi.MiddlewareDoc`. The built-ins have theirs: `auth.RequireJwt`
(a bearer scheme, 401), `auth.apikey.Middleware` (the `X-API-Key` scheme,
401), `auth.rbac.Require` (403), the rate limiters (429) and `auth.csrf`
(403). A route behind them gets the scheme in `security` and the responses.
For a function middleware:

```zig
app.use(anole.openapi.middleware(.{
    .security_schemes = &.{.{ .name = "tenant", .kind = .{ .api_key = .{ .in = .header, .param = "X-Tenant" } } }},
    .security = .any,
    .responses = .{ .unauthorized = .{ .description = "Unknown tenant" } },
}, requireTenant));
```

`security` is `.any` (any scheme declared before it in the chain) or
`.{ .schemes = &.{"tenant"} }`. `query`, `headers` and `cookies` name DTOs the
middleware reads; they become parameters of every route behind it.

## gRPC services

Each unary method appears once. A method with a `google.api.http` annotation
appears as its REST route (JSON transcoding, a server stream as one JSON array);
one without appears as Connect's `POST /pkg.Service/Method` (and a `GET` for
`NO_SIDE_EFFECTS`). Native gRPC can't be written in OpenAPI: the `.proto` file
is that contract. Client and bidirectional streams have no form.
`app.openapi(.{ .grpc = .{ .connect = .all } })` shows both forms of annotated
methods; `.none` leaves Connect out; `.transcoded = false` leaves the REST
routes out.

Messages are described as protobuf's JSON mapping writes them (64-bit
integers as strings, `bytes` as base64, enums by name, well-known types by their
JSON form). `[(google.api.field_behavior) = REQUIRED]` makes a field required,
`OUTPUT_ONLY` read-only and `INPUT_ONLY` write-only (`google/api/field_behavior.proto`
is bundled: `import` it). Comments in the `.proto` file become descriptions of
messages, fields, services and methods.

## Serving it

`app.openapi(opts)` serves the document at `path` (`/openapi.json`) and the
Scalar page at `page` (`/docs`; `null` for none) when `serve` allows:

| `serve` | |
| --- | --- |
| `.development` (default) | when the environment is development (`zig build run`); a release build is production and 404s |
| `.always` | always |
| `.never` | never; `zig build openapi` and `app.openapiDocument(gpa)` still work |

`listener` limits both routes to one named listener (an internal port).
`info`, `servers`, `tags` (descriptions) and `tags_from_path` shape the rest.
The page loads Scalar from jsDelivr with a pinned version and a Subresource
Integrity hash (with no proxy and no AI panel); a Content-Security-Policy
that you set must allow `https://cdn.jsdelivr.net` scripts, `'unsafe-inline'`
styles and `https://fonts.scalar.com` fonts, and `connect-src` for the API's
own origin.

Routes registered with `any`, `ws`, `webtransport`, `static` and `embedded`,
the helper routes (`/metrics`, health), `QUERY` routes (OpenAPI 3.1 has no such
method) and routes added to `app.router` directly are not in the document.

## At build time

`addApp` adds two steps (`.openapi = null` leaves them out):

```
zig build openapi         # writes openapi.json next to build.zig
zig build openapi-check   # fails when the file doesn't match the routes (CI)
```

Both run your program with `ANOLE_OPENAPI_OUT` or `ANOLE_OPENAPI_CHECK` set;
`run()` then writes or compares the document as soon as the routes exist and
returns before anything binds, so no code split or test file is needed. Those
two variables are read from the real environment only, never from `.env`. The
code before `listen` still runs: a `main` that needs a secret needs it in
`.env` (development) or the environment, and one that connects to a database
eagerly (`connect_at_start`) needs the database; connectors are lazy by
default. In a build without `-Dopenapi` both steps fail with
`error.OpenApiNotBuilt`.

The output is deterministic: paths, methods, tags and components are sorted,
so the same code writes the same bytes and a diff shows only real changes.

## The C ABI

Nothing here is in the C ABI: libanole is built without OpenAPI, and the
bindings use their ecosystems' generators (FastAPI's `/docs`, `@hono/zod-openapi`).
