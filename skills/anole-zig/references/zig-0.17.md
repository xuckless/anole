# Zig 0.17 as Anole code meets it

Up: [SKILL.md](../SKILL.md). Runtime rules: [runtime.md](runtime.md).

Anole needs Zig 0.17.0 (`minimum_zig_version` in Anole's build.zig.zon). Most
training data is Zig 0.11-0.13, whose std looks different. Each item below
is checked against Anole's code and the 0.17.0 std; where this file does not
say, read the std source (`zig env` prints `lib_dir`) rather than guess.

## main takes std.process.Init

```zig
pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    // ...
}
```

`init.gpa` is a general-purpose allocator (leak-checked in Debug),
`init.arena` a `*std.heap.ArenaAllocator` for the whole process
(`init.arena.allocator()`), `init.minimal.args` the arguments
(`try init.minimal.args.iterateAllocator(arena)`), `init.environ_map` the
environment. Don't build a `GeneralPurposeAllocator`: it is gone
(`std.heap.DebugAllocator` is the leak-checking one). Sources:
templates/*/src/main.zig, examples/io/main.zig, std/process.zig.

## I/O goes through std.Io, passed in

There is no global I/O. Files, sockets, time, sleep and randomness take an
`io: std.Io` argument. In Anole, use `req.io` in handlers and `app.io()`
elsewhere; see [runtime.md](runtime.md#use-the-servers-io).

| Old habit | Zig 0.17 (as Anole uses it) |
| --- | --- |
| `std.fs.cwd().openDir(...)` | `std.Io.Dir.cwd().openDir(io, path, .{})` (examples/io/main.zig) |
| `dir.readFileAlloc(alloc, name, max)` | `dir.readFileAlloc(io, name, alloc, .limited(1 << 20))` |
| `std.time.milliTimestamp()`, `std.time.Timer` | `std.Io.Clock.Timestamp.now(io, .awake)`; `.durationTo(...)` |
| `std.Thread.sleep(ns)` | `try io.sleep(.fromMilliseconds(200), .awake)` |
| `std.crypto.random.bytes(&b)` | `io.random(&b)` (src/db/internal.zig) |
| `std.Thread.Mutex` | `std.Io.Mutex` (`.init`), `std.Io.RwLock` |
| `std.io.getStdErr()` | `std.Io.File.stderr()`; a writer is `file.writer(io, &buf)` |
| `std.posix.getenv` | `anole.env.get("NAME")` (src/env.zig) or `init.environ_map.get` |
| `async`/`await` keywords | `io.concurrent(func, args)` then `future.await(io)` or `future.cancel(io)` (examples/io/main.zig) |

`std.time` keeps only unit constants (`ns_per_ms` ...) and `epoch`.

## Containers are unmanaged

`std.ArrayList(T)` no longer stores its allocator (`ArrayListUnmanaged` is
now an alias of it). Initialise with `.empty` and pass the allocator to every
call that may allocate or free:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);
try list.append(gpa, 'x');
```

Struct fields follow the same pattern: `users: std.AutoArrayHashMapUnmanaged(u64, User) = .empty`
(examples/rest/main.zig). The old managed list survives as `std.array_list.Managed`, marked deprecated.
Prefer the unmanaged forms; Anole's code uses them throughout.

## Writers and readers are interfaces

`std.Io.Writer` and `std.Io.Reader` are concrete structs with a buffer, passed
as `*std.Io.Writer`; there is no `anytype` writer and no `.writer()` that
returns a generic one.

- Into memory: `var out: std.Io.Writer.Allocating = .init(gpa);` then
  `out.writer` is the interface, `out.written()` the bytes,
  `out.toOwnedSlice()` takes them (src/openapi/json.zig).
- Into a fixed buffer: `var w: std.Io.Writer = .fixed(&buf);`.
- To a file: `var fw = file.writer(io, &buf);` use `&fw.interface`, then
  `try fw.interface.flush()`. Forgetting `flush` loses the tail.
- A type prints itself with `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void`
  and the `{f}` specifier (src/db/root.zig `ErrorDetail.format`; `anole.Secret`
  prints `[REDACTED]` through `{f}`).
- JSON from std: `std.json.Stringify.valueAlloc(gpa, value, .{})`. In a
  handler you rarely need it: `res.json(value)` writes the body.

Unsure: the exact reader API for streaming reads changed several times; read
std/Io/Reader.zig before writing a parser by hand.

## build.zig and build.zig.zon

Add Anole with `zig fetch`, pinned to a tag (docs/getting-started.md):

```sh
zig fetch --save git+https://github.com/xuckless/anole#v0.7.0
```

`anole new` uses `zig fetch --save=anole <url>` (tools/anole/main.zig). The
manifest's `.name` is an enum literal (`.name = .api`) and it has a
`.fingerprint`; `zig init` writes both, so don't hand-write the file or the
dependency `.hash`. In `build.zig`, Anole's helper makes the executable,
installs it and adds `zig build run`:

```zig
pub fn build(b: *std.Build) void {
    _ = @import("anole").addApp(b, .{
        .name = "api",
        .root_source_file = b.path("src/main.zig"),
    });
}
```

Modules are explicit: `b.addTest(.{ .root_module = b.createModule(.{ ... }) })`,
as in templates/minimal/build.zig. Profiles and feature flags:
[config-cli.md](config-cli.md).

## Errors

- Handlers return inferred error sets (`!void`). Anole turns status-named
  errors into answers: `error.NotFound` 404, `error.Unauthorized` 401, others
  500 (src/root.zig header, `anole.errorStatus`). Return them instead of
  setting the status and returning.
- Map and pass through: `catch |err| switch (err) { error.FileNotFound => return error.NotFound, else => |e| return e }`
  (examples/io/main.zig).
- `error.Canceled` is special; see [runtime.md](runtime.md#re-raise-errorcanceled).
- Functions that take `io` and wait return `std.Io.Cancelable` (`error{Canceled}`)
  in their set.

## Language changes seen in Anole code

- `callconv(.c)`, lowercase (src/capi).
- No `usingnamespace`: neither Anole nor the 0.17 std uses it; it was removed
  from the language.
- Hot/cold paths use `@branchHint(.cold)` as the first statement.
- `std.debug.print` still exists, for quick debugging; use
  [`anole.log`](observability.md) in app code.
