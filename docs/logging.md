# Logging

Anole's logs come in two formats with one record shape, and every layer
writes through the same place: your own lines, the server's, the access log
and (under the C ABI) the binding's log callback.

- **text**, for a terminal: std.log's look (`info(scope): message`, colour on
  a terminal) with structured fields appended as ` key=value`.
- **json**, for a collector: one JSON object per line on stderr (JSON Lines).

`ServerOptions.log.format` is `.auto` by default: JSON when the environment
is production ([config.md](config.md)), text otherwise. Test builds are
always text. `.text` and `.json` always win. The startup line says when
`.auto` chose JSON ("JSON Lines logs"). The format is process-wide, as
std.log is: the last `Server.init` (or `anole.log.setFormat`) sets it.

```zig
pub const std_options = anole.std_options; // std.log lines become records too

var app = try anole.App.init(gpa, .{ .log = .{ .service = "billing" } });
```

Without the `std_options` line, the server's own std.log lines stay text in
a JSON deployment, and `init` prints one warning saying so.

## The record

```json
{"time":"2026-10-23T09:41:07.415Z","level":"info","scope":"billing","message":"todo created","service":"api","request_id":"01JB...","trace_id":"4bf9...","span_id":"00f0...","title":"Buy milk"}
```

Keys, in this order: `time` (RFC 3339 UTC, milliseconds), `level`
(`error`, `warn`, `info`, `debug`), `scope` (left out for std.log's default
scope), `message`, `service` (when set), `request_id`, `trace_id` and
`span_id` (each when the request has one), then the fields. Invalid UTF-8 is
written as U+FFFD, integers wider than 64 bits and non-finite floats as
strings. A record over 16 KiB is rewritten with the message cut at a
character boundary, no fields, and `"truncated":true`. Everything goes to
stderr under the lock std.log uses, so lines never interleave with std.debug
output.

## Writing records

```zig
anole.log.info("todo created", .{ .title = title });
anole.log.scoped(.billing).warn("card declined", .{ .customer = id, .code = 402 });
req.log().info("slow upstream", .{ .ms = 840 }); // adds request_id, trace_id, span_id
```

The message is fixed text and the data goes in named fields: a tuple
(`.{id}`) is a compile error that points to std.log for format strings.
Field names that collide with a record key (`time`, `level`, `scope`,
`message`, `service`, `request_id`, `trace_id`, `span_id`, `truncated`) are
compile errors too. Values may be numbers, bools, strings, enums, errors,
optionals, slices, arrays, structs, tagged unions and anything with
`pub fn format(self, w: *std.Io.Writer) !void` (written as a string).

**Redaction.** A field whose name ends in a secret word (`password`,
`api_key`, `access_token`, `authorization`, `cookie`, `private_key`...) or
whose type declares `pub const anole_sensitive = true;` (`anole.Secret` does)
is written as `"[REDACTED]"`. This applies to fields, not to std.log format
arguments: std.fmt formats those before the logger sees them.

**Levels.** `ServerOptions.log.level` (null by default) filters at run time;
std's compile-time `log_level` still applies, so a Debug build keeps showing
debug lines.

Plain `std.log` calls carry no request id: only `req.log()`, the access log
and the server's "unhandled error in request handler" line know the request.

## Access log

`anole.observe.AccessLog` writes through the same place: `format` follows the
log format unless set, and without a `.file` its lines go where the logs go
(stderr, or the C ABI's callback). See [observability.md](observability.md).

## Under the C ABI

`"log": {"format": "auto"|"text"|"json", "service": "..."}` in the
configuration. The callback `anole_server_options.log` is unchanged:
`(ud, level, scope, msg)`. With the JSON format `msg` is the whole record
with no newline, byte for byte what stderr would get; with text it is the
message (and ` key=value` fields). Access log lines come through it too, with
scope `access`. A binding that leaves `environment` out gets production, so
JSON records ([c-abi.md](c-abi.md#environment-and-env)). `level` stays
`anole_server_options.log_level`.

## Collecting

One record per line on stderr: Docker, systemd's journal, Kubernetes and
every platform collect it as it is. Pipe it through `jq` in development:
`./app 2>&1 | jq -c .`.
