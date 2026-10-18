//! Handlers that wait on I/O without blocking a thread.
//!
//! Every handler gets the server's `std.Io` as `req.io`. On zio, a call
//! through it that has to wait (a socket, a file, a timer, an outbound
//! request) suspends the handler's coroutine and lets its executor run other
//! requests meanwhile; the code still reads top to bottom. Anything written
//! against `std.Io` works this way: dusty's HTTP client, `std.Io.Dir` and
//! `std.Io.File`, and DB drivers built on `std.Io.net`. A C library that
//! blocks in its own syscalls (most DB client libraries) does not, and holds
//! the executor's thread until it returns.
//!
//!   zig build run-io                    # http://127.0.0.1:8081
//!
//!   GET /slow?ms=200   waits 200 ms on a timer; other requests go on meanwhile
//!   GET /files/:name   reads examples/io/files/<name> through the Io
//!   GET /fanout        two outbound requests (to /slow on this server) at
//!                      once: it takes about one /slow, not two
//!
//! The state every handler shares (here, one HTTP client with its connection
//! pool) is the `Ctx` of `Server(Ctx)`, passed as the handler's first
//! argument.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;

pub const zio_options = anole.zio_options;

/// Log lines read `anole` and `access`, not the libraries underneath.
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    // zio's per-thread startup lines are debug noise here.
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

const App = struct {
    client: http.Client,
    files: std.Io.Dir,
    port: u16,
};

fn handleSlow(_: *App, req: *http.Request, res: *http.Response) !void {
    const ms = req.query.getInt(u32, "ms") orelse 200;
    // Suspends this request only; the executor serves others.
    try req.io.sleep(.fromMilliseconds(@min(ms, 10_000)), .awake);
    try res.print(.text, "slept {d} ms", .{ms});
}

fn handleFile(app: *App, req: *http.Request, res: *http.Response) !void {
    const name = req.params.get("name").?;
    // One plain name: no way out of the directory.
    if (std.mem.indexOfAny(u8, name, "/\\") != null or name[0] == '.') return error.NotFound;
    const data = app.files.readFileAlloc(req.io, name, req.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => |e| return e,
    };
    res.content_type = .fromExtension(std.fs.path.extension(name));
    res.body = data;
}

/// One outbound GET, its body copied into `out`. Each task gets a buffer
/// of its own: the request's arena is not thread-safe, and the runtime may
/// run the two tasks on different executors.
fn fetchBody(app: *App, path: []const u8, out: *[256]u8) ![]const u8 {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ app.port, path });
    var response = try app.client.fetch(url, .{});
    defer response.deinit();
    const body = (try response.body()) orelse "";
    const n = @min(body.len, out.len);
    @memcpy(out[0..n], body[0..n]);
    return out[0..n];
}

fn handleFanout(app: *App, req: *http.Request, res: *http.Response) !void {
    const io = req.io;
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    // Both requests are in flight at once. Each future is either awaited
    // or, on the way out after an error, canceled; never both.
    var out_a: [256]u8 = undefined;
    var out_b: [256]u8 = undefined;
    var a = try io.concurrent(fetchBody, .{ app, "/slow?ms=300", &out_a });
    var b = io.concurrent(fetchBody, .{ app, "/slow?ms=300", &out_b }) catch |err| {
        _ = a.cancel(io) catch {};
        return err;
    };
    const first = a.await(io) catch |err| {
        _ = b.cancel(io) catch {};
        return err;
    };
    const second = try b.await(io);
    const took = start.durationTo(.now(io, .awake)).raw.toMilliseconds();
    try res.print(.text, "{s} + {s} in {d} ms\n", .{ first, second, took });
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8081;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);

    var app: App = .{ .client = undefined, .files = undefined, .port = port };
    var server = try anole.Server(App).init(init.gpa, .{ .http = .{ .port = port } }, &app);
    defer server.deinit();
    const io = server.io();

    app.files = try std.Io.Dir.cwd().openDir(io, "examples/io/files", .{});
    defer app.files.close(io);
    app.client = http.Client.init(init.gpa, io, .{});
    defer app.client.deinit();

    server.get("/slow", handleSlow);
    server.get("/files/:name", handleFile);
    server.get("/fanout", handleFanout);

    std.log.info("listening on http://127.0.0.1:{d}", .{port});
    try server.run();
}
