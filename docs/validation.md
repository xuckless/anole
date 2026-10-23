# Validation

`req.bind(T)` checks a JSON body against the rules written on `T`, and
answers a body that breaks them with a 422 that names every field. The rules
are zefir's validator, exported as `anole.validate` (usually
`const v = anole.validate;`).

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

fn create(req: *anole.Request, res: *anole.Response, in: anole.In(.{ .body = NewTodo })) !void {
    res.status = .created;
    try res.json(in.body);
}
```

A request with `{"title":"   ","tags":["a",""],"due":"tomorrow"}` gets:

```json
{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"3 fields are invalid.",
 "errors":[{"in":"body","field":"title","code":"validation.not_blank","message":"must not be blank"},
           {"in":"body","field":"due","code":"validation.date","message":"must be a valid date in YYYY-MM-DD format"},
           {"in":"body","field":"tags[1]","code":"validation.not_empty","message":"must not be empty"}]}
```

## Rules in a minute

A struct lists the rules of its fields in `pub const field_rules`. An entry
is one rule or a tuple of them, written in this order: renames and
transforms first (`v.rename("outsideName")`, `v.trim`, `v.toLower`,
`v.transformWith(f)`), then the rules. Optional fields (`?T`) are skipped
when null. Nested structs, slices, arrays and `std.ArrayList` items are
walked, with paths like `items[2].name`; `v.each(rule)` applies a rule to the
items of a list.

The catalogue, grouped as in the validator's own files (each rule's code is
`validation.<snake_case_name>`, its message an English fragment starting with
"must"):

| Group | Rules |
| --- | --- |
| Common | `equals`, `notEquals`, `oneOf`, `noneOf`, `empty`, `notEmpty` |
| Numbers | `min`, `max`, `range`, `positive`, `nonNegative`, `negative`, `nonPositive`, `divisibleBy`, `finite` |
| Strings | `minLength`, `maxLength`, `length`, `minBytes`, `maxBytes`, `utf8`, `notBlank`, `ascii`, `printableAscii`, `alphanumeric`, `alpha`, `digits`, `lowercase`, `uppercase`, `multibyte`, `contains`, `notContains`, `strongPassword` |
| Formats | `email`, `httpUrl`, `fqdn`, `ip`, `ipv4`, `ipv6`, `macAddress`, `port`, `latitude`, `longitude`, `numberString`, `decimal`, `hexadecimal`, `octal`, `booleanString` |
| Encodings and identifiers | `json`, `jwt`, `base32`, `base58`, `base64`, `base64Url`, `dataUri`, `magnetUri`, `mimeType`, `locale`, `semVer`, `hexColor`, `rgbColor`, `hslColor`, `uuid`, `mongoId`, `firebasePushId`, `hash`, `creditCard`, `isbn`, `issn`, `ean`, `isin`, `isrc`, `bic`, `iban`, `btcAddress`, `ethereumAddress` |
| Dates | `date`, `rfc3339`, `iso8601`, `minDate`, `maxDate`, `militaryTime` |
| Lists | `minItems`, `maxItems`, `uniqueItems`, `uniqueBy`, `containsAll`, `containsNone`, `each` |

`.withMessage("must be a real {name}")` replaces a rule's message (English
only; translate by `code` on the client if you need another language).
`v.custom("orders.too_old", "is too old", predicate)` makes a rule of your
own; codes are `segment.segment` and the `validation.` and `rpc.` prefixes
are reserved. A struct can also declare
`pub fn validateSelf(self: *const T) ?v.Violation` for rules across fields,
which returns `v.fail(@This(), .end, "orders.end_before_start", "must not be
before start")`.

`comptime anole.validate.assertRules(T)` checks a type's rules at compile
time (every `anole.In` type is checked for you); a rule on a field type it
does not fit is a compile error with the field named.

## What reads a body, the query and the path

| Call | On a problem |
| --- | --- |
| `req.bind(T)` | no body: `error.MissingBody` (400); not JSON, a key twice in one object, nesting past 64: `error.InvalidJsonBody` (400); lists taking more than 4 x `limits.body_max`: `error.BodyTooBig` (413); a wrong type, a missing required field, an unknown field in a type that says `pub const unknown_fields = .reject;`, or a broken rule: `error.ValidationFailed` (422) |
| `req.json(T)` | as `bind`, but a request without a body is `null` |
| `req.bindQuery(T)` | the query as `T`: names by outside names, `?tag=a&tag=b` into `[]const T`, defaults for absent fields; problems are violations with `in: "query"` and `error.ValidationFailed` (422); a broken percent-escape or invalid UTF-8 is `error.BadRequest` (400) |
| `req.bindPath(T)` | the route's parameters as `T`; any problem is `error.NotFound` (404) with no violation: a value that does not fit names no resource |
| `req.bindHeaders(T)` | the headers as `T` (`x_request_id` reads `X-Request-Id`, any case; `v.rename` names the header otherwise); violations with `in: "header"` |
| `req.bindWith(T, std.json.ParseOptions)` | std.json as it was: no mapping, no rules; any mismatch is 400 |

Unknown fields are ignored unless the type says otherwise. Types the mapper
reads: integers, floats (finite), `bool`, enums (by tag name), `[]const u8`,
structs, `?T` and `[]const T`. A body type holding anything else (`[N]T`,
unions, `std.json.Value`, a type with `jsonParse`) is read with std.json,
unknown fields ignored, a type mismatch 400, and its rules still run (422).
A type that uses `v.rename` must stay inside the mapper's types: that is a
compile error otherwise.

Without a request, `anole.bindJson(T, arena, bytes, .{})` does the same and
returns `.ok` or `.invalid` with the violations (NATS and Kafka messages
bind with `msg.bind(T)`, which logs one warning and returns
`error.ValidationFailed`).

## Typed handlers: `anole.In`

A handler can name its inputs in its last parameter:

```zig
fn update(
    req: *anole.Request,
    res: *anole.Response,
    in: anole.In(.{ .path = struct { id: u64 }, .query = struct { dry_run: bool = false }, .body = UpdateUser }),
) !void { ... }
```

Keys are `.path`, `.query`, `.headers` and `.body`; absent keys are `void`
fields. The adapter binds the path (404 on a mismatch), then the query, the
headers and the body, and reports every query, header and body violation
together as one 422. Mistakes in the signature are compile errors: a path
field that is not a parameter of the route (at the root router; under a
group the prefix is a run-time string, so it is checked at startup), an
optional path field, `.body` on a GET, an unknown key (with a "did you
mean"), a field type a path or header cannot carry. See
[routing.md](routing.md#typed-handlers) for the output side.

## Your own checks: `req.invalid`

```zig
if (try users.exists(req, in.email)) return req.invalid("email", "users.email_taken", "is already taken");
```

`req.addViolation(field, code, message)` adds one without failing;
`req.invalid` adds it and returns `error.ValidationFailed`, so a business
check comes back in the same 422 document. `code` and `message` are checked
at compile time; `field` must live as long as the request (a literal or the
arena).

## The 422 document

`application/problem+json` (RFC 9457). Members, in this order: `type`
(`about:blank`), `title` (the status's phrase), `status`, `detail`,
`instance` (only when set), `errors`. `detail` is `"1 field is invalid."`,
`"N fields are invalid."`, or `"More than 100 fields are invalid; the first
100 are listed."` when there were more.

Each error has `in` (`"body"`, `"query"` or `"header"`), `field` (the dotted
path by outside names, `items[2].name`; the header's canonical name for
headers; left out for the root value), `code` and `message`. Codes of the
mapping are `http.invalid_type`, `http.missing_field` and
`http.unknown_field`; rules have `validation.*`; yours have what you wrote.

`res.problem(.{ .status = .conflict, .detail = "already exists" })` answers
with the same kind of document for anything else, and a handler that returns
`error.ValidationFailed` gets this answer whatever `ServerOptions.errors`
says.

Limits: 100 violations per request, messages of 1 to 512 bytes, nesting 64.

### From Node and Python

Validation stays in the language of the binding: use zod, pydantic or the
like, and answer with the same document if clients expect it. It is a few
lines:

```js
res.status(422).type("application/problem+json").send(JSON.stringify({
  type: "about:blank", title: "Unprocessable Content", status: 422,
  detail: `${issues.length} fields are invalid.`,
  errors: issues.map(i => ({ in: "body", field: i.path.join("."), code: i.code, message: i.message })),
}));
```

## Testing your types

```zig
test "NewTodo's rules" {
    comptime anole.validate.assertRules(NewTodo);
}
```

`anole.testing` runs a whole request without a socket; see
[testing.md](testing.md).
