# Static files

Up: [index](index.md). Full docs: docs/routing.md (Static files, The response). Examples: templates/full (`staticDir`).
Related: [server-routes.md](server-routes.md), [caching](../middleware-auth/caching.md).

Do not hand-roll file serving: the static routes already do ETag / Last-Modified with 304, `Range` with 206/416, index files, directory redirects, dotfile hiding and precompressed variants.

## A directory by path: `staticDir`

Use: `anole.App.staticDir` (src/server.zig), options `anole.http.StaticOptions` (src/http/core/server/static.zig). The server opens the directory (relative to the working directory) and closes it with itself.

```zig
try app.staticDir("/", "public", .{});
```

## A directory you opened: `static`

Use: `anole.App.static` (src/server.zig).

```zig
var public = try std.Io.Dir.cwd().openDir(io, "public", .{});
defer public.close(io);
app.static("/assets", public, .{
    .precompressed = &.{ .br, .zstd, .gzip },
    .cache_control = "public, max-age=3600",
});
```

Options (`StaticOptions`): `index` (`"index.html"`; null makes a directory a 404), `precompressed`, `hide_dotfiles` (true), `resolve_beneath` (true), `cache_control`.

Traps:
- The `std.Io.Dir` passed to `static` must stay open while the server runs.
- A symlink that leaves the directory is a 404 (`resolve_beneath`). Use relative links inside the directory; an absolute link can be refused on one OS and served on another.
- Dotfiles (`/.env`) are 404 by default; serve `/.well-known/` with a route of its own.
- `precompressed` needs the plain file too. Static files are not compressed on the fly.

## One file in the binary: `embedded`

Use: `anole.App.embedded` (src/server.zig), options `anole.http.EmbeddedOptions`: `content_type`, precompressed `br` / `zstd` / `gzip` copies, `version` (a request with a matching `?v=` is cached for good), `cache_control`.

```zig
app.embedded("/favicon.ico", @embedFile("favicon.ico"), .{ .cache_control = "public, max-age=86400" });
```

## One file from a handler: `res.sendFile`

Use: `anole.Response.sendFile` (src/http/core/response.zig) when a handler decides which file to send.

```zig
fn download(_: *anole.Request, res: *anole.Response) !void {
    _ = res.sendFile(std.Io.Dir.cwd(), "reports/latest.pdf", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => |e| return e,
    };
    res.content_type = .pdf;
}
```

Traps:
- `sendFile` does no ranges, conditional requests or compression; static routes do.
- A path with `..` or an absolute path fails with `error.BadPathName` (a 404), so a name from the request cannot escape the directory.
