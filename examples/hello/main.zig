//! Anole hello world: HTTP/1.1 (dusty on zio), pinned scheduling, one executor per CPU.
//! The server and router wiring follows dusty's README examples (lalinsky/dusty, MIT, d3cb485).
//!
//!   zig build run-hello            # listens on 127.0.0.1:8080
//!   zig build run-hello -- 9000    # another port
//!
//!   GET /          -> "hello"
//!   GET /users/:id -> "user <id>"
//!
//! Every response carries `X-Thread: <os thread id>` so a test can see which
//! executor served it: under `.pinned` a connection's task stays on the
//! executor it was spawned on, so every request on one keep-alive connection
//! reports the same thread.
//!
//! SIGINT/SIGTERM cancel `Server.run`, which stops the accept loops and drains
//! in-flight requests (dusty server.zig `drainConnections`) before returning.
const std = @import("std");
const anole = @import("anole");
const zio = anole.zio;
const http = anole.http;

/// Compile-time zio configuration, read by zio from the root module
/// (zio src/options.zig). `.pinned`: many executors, a task never migrates.
pub const zio_options: zio.Options = .{ .scheduling = .pinned };

/// Route std.log / std.debug.print through zio so logging from a task yields
/// instead of blocking the executor thread (zio examples/*.zig).
pub const std_options_debug_io = zio.debug_io;

fn setThreadHeader(res: *http.Response) !void {
    const tid = std.Thread.getCurrentId();
    try res.header("X-Thread", try std.fmt.allocPrint(res.arena, "{d}", .{tid}));
}

fn handleRoot(req: *http.Request, res: *http.Response) !void {
    _ = req;
    try setThreadHeader(res);
    try res.print(.text, "hello", .{});
}

fn handleUser(req: *http.Request, res: *http.Response) !void {
    try setThreadHeader(res);
    const id = req.params.get("id") orelse "unknown";
    try res.print(.text, "user {s}", .{id});
}

fn waitForSignal(kind: zio.SignalKind) !void {
    var sig = try zio.Signal.init(kind);
    defer sig.deinit();
    try sig.wait();
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);

    // One executor per CPU (cgroup-aware); executor 0 is this thread.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    std.log.info("zio scheduling={t} executors={d}", .{ zio_options.scheduling, rt.executors.items.len });
    std.log.info("anole features: tls={t} http2={} http3={} websocket={}", .{
        anole.features.tls, anole.features.http2, anole.features.http3, anole.features.websocket,
    });

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", port) };
    var server = http.Server(void).init(init.gpa, io, .{
        .listeners = &.{.{ .address = addr }},
    }, {});
    defer server.deinit();

    server.router.get("/", handleRoot);
    server.router.get("/users/:id", handleUser);

    // SIGINT, SIGTERM and the server run as three tasks of one std.Io.Select;
    // whichever finishes first decides. The buffer holds all three results
    // so cancelDiscard below cannot deadlock (std/Io.zig Select.cancel).
    const Done = union(enum) {
        int: anyerror!void,
        term: anyerror!void,
        served: anyerror!void,
    };
    std.log.info("listening on http://127.0.0.1:{d}", .{port});
    var done_buf: [3]Done = undefined;
    var sel = std.Io.Select(Done).init(io, &done_buf);
    try sel.concurrent(.int, waitForSignal, .{.interrupt});
    try sel.concurrent(.term, waitForSignal, .{.terminate});
    try sel.concurrent(.served, serve, .{&server});

    const first = try sel.await();
    switch (first) {
        .served => |r| std.log.err("server stopped on its own: {any}", .{r}),
        .int, .term => std.log.info("signal received ({t}); shutting down", .{first}),
    }
    // Cancels Server.run: the accept loops stop, in-flight requests drain
    // (bounded by timeout.shutdown), then the other signal watcher is canceled.
    sel.cancelDiscard();
    std.log.info("server stopped cleanly", .{});
}

fn serve(server: *http.Server(void)) anyerror!void {
    return server.run();
}
