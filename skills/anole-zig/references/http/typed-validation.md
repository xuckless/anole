# Typed handlers and validation

Up: [index](index.md). Full docs: docs/routing.md (Typed handlers), docs/validation.md. Examples: templates/minimal, templates/rest-postgres, templates/full.
Related: [request-response.md](request-response.md), [openapi.md](openapi.md).

## Typed handlers: `anole.In` and a return value

Use when a handler takes path, query, header or body input and returns a value. Anole binds and validates the input before the handler runs, writes the result as JSON, and the OpenAPI document is built from the signature. Prefer this to hand parsing.

Use: `anole.In` (src/typed.zig).

Shape: `fn ([ctx: *Ctx,] req: *anole.Request, [res: *anole.Response,] [in: anole.In(...)]) [E!]Out`. Exactly `(req, res)` or `(ctx, req, res)` returning `void` is a plain handler; anything else of this shape is typed.

```zig
fn user(_: *anole.Request, in: anole.In(.{ .path = struct { id: u64 } })) User {
    return .{ .id = in.path.id, .name = "Ada" };
}

fn list(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .query = struct { limit: u32 = 50 } })) ![]const Todo {
    return ctx.db.all(Todo, req, "SELECT " ++ columns ++ " FROM todos ORDER BY id LIMIT $1", .{in.query.limit});
}
```

- Keys are `.path`, `.query`, `.headers`, `.body`. The path is bound first (a mismatch is 404), then query, headers and body, whose violations come back together as one 422.
- A typed handler that returns `void` and does not take `res` answers 204.
- Returned errors map as for any handler (`error.NotFound` 404, `error.ValidationFailed` 422).

Traps:
- Compile errors, not runtime ones: a path field that is not a route param, an optional path field, `.body` on GET/HEAD, an unknown key.
- `in.body` and friends live in `req.arena`; copy before storing ([lifetimes](../runtime.md#request-arena-and-lifetimes)).

## Status of the result: `Created`, `Accepted`, `WithStatus`

Use: `anole.Created`, `anole.Accepted`, `anole.WithStatus` (src/typed.zig). Each is a struct `{ value: T, location: ?[]const u8 = null }`.

```zig
fn create(ctx: *Ctx, req: *anole.Request, in: anole.In(.{ .body = NewTodo })) !anole.Created(Todo) {
    const todo = try ctx.db.one(Todo, req, "INSERT INTO todos (title, done) VALUES ($1, $2) RETURNING " ++ columns, .{ in.body.title, in.body.done });
    return .{ .value = todo, .location = try std.fmt.allocPrint(req.arena, "/todos/{d}", .{todo.id}) };
}
```

- `anole.Created(T)` is 201 (with `Location` when set), `anole.Accepted(T)` 202, `anole.WithStatus(.status, T)` any 2xx (a non-2xx is a compile error).
- With `T = void` (`anole.WithStatus(.no_content, void)`, `anole.Created(void)`) only the status (and `Location`) is sent.
- A typed handler that takes `res` and sets `res.status` keeps that status.

## Validation rules: `field_rules`

Use: `anole.validate` (usually `const v = anole.validate;`), checked by `req.bind`, `req.bindQuery` and `anole.In`. Rules are declared on the type as `pub const field_rules`.

```zig
const v = anole.validate;

const NewTodo = struct {
    title: []const u8,
    due: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const field_rules = .{
        .title = .{ v.trim, v.notBlank, v.maxLength(200) },
        .due = v.date,
        .tags = .{ v.maxItems(10), v.each(v.notEmpty) },
    };
};
```

- An entry is one rule or a tuple: renames and transforms first (`v.rename("outsideName")`, `v.trim`, `v.toLower`), then rules. `?T` fields are skipped when null. Nested structs and slices are walked (`items[2].name`).
- Common rules: `notBlank`, `notEmpty`, `minLength`, `maxLength`, `min`, `max`, `range`, `oneOf`, `email`, `httpUrl`, `uuid`, `date`, `rfc3339`, `minItems`, `maxItems`, `each`. Full catalogue: docs/validation.md.
- Cross-field rules: `pub fn validateSelf(self: *const T) ?v.Violation`, returning `v.fail(@This(), .end, "orders.end_before_start", "must not be before start")`.
- Custom rule: `v.custom("orders.too_old", "is too old", predicate)`; `.withMessage("...")` replaces a message.
- Unknown JSON fields are ignored unless the type says `pub const unknown_fields = .reject;`.
- Check rules in a test: `comptime anole.validate.assertRules(T);`.

The 422 answer is `application/problem+json` with `errors: [{in, field, code, message}]`.

## Business checks in the same 422: `req.invalid`

Use: `anole.Request.invalid`, `anole.Request.addViolation`, `anole.Request.violations` (src/http/core/request.zig); `anole.Violation`, `anole.Violations` (src/root.zig).

```zig
if (try users.exists(req, in.email)) return req.invalid("email", "users.email_taken", "is already taken");
```

Traps:
- `code` and `message` are compile-time strings; `field` must live as long as the request (a literal or the arena).
- Codes are `segment.segment`; the `validation.` and `rpc.` prefixes are reserved.

## Without a request: `anole.bindJson`

`anole.bindJson(T, arena, bytes, .{})` (src/root.zig) applies the same mapping and rules to bytes and returns `.ok` or `.invalid` with the violations.
