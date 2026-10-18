//! Anole hello world: HTTP/1.1 (dusty on zio), pinned scheduling, one executor per CPU.
//! The server and router wiring follows dusty's README examples (lalinsky/dusty, MIT, d3cb485).
//!
//!   zig build run-hello                 # http://127.0.0.1:8080 and https://127.0.0.1:8443
//!   zig build run-hello -- 9000 9443    # other ports
//!
//! With TLS built in (the default; not with -Dtls=none) the HTTPS listener
//! uses a self-signed certificate for localhost that is generated at startup
//! and held only in memory, so clients need `curl -k` or similar.
//!
//!   GET /          -> "hello"
//!   GET /users/:id -> "user <id>"
//!   POST /echo     -> the request body, streamed back (a gzip body is decoded)
//!   GET /big       -> 200 lines of text, gzipped for a client that accepts it
//!
//! Every response carries `X-Thread: <os thread id>` so a test can see which
//! executor served it: under `.pinned` a connection's task stays on the
//! executor it was spawned on, so every request on one keep-alive connection
//! reports the same thread.
//!
//! SIGINT/SIGTERM cancel `Server.run`, which stops the accept loops and drains
//! in-flight requests (dusty server.zig `drainConnections`) before returning.
const std = @import("std");
const builtin = @import("builtin");
const anole = @import("anole");
const zio = anole.zio;
const http = anole.http;

/// Compile-time zio configuration, read by zio from the root module
/// (zio src/options.zig). `.pinned`: many executors, a task never migrates.
pub const zio_options: zio.Options = .{ .scheduling = .pinned };

// No `std_options_debug_io = zio.debug_io` (zio's examples set it so logging
// yields): std.debug uses that Io for stack unwinding too, and Debug builds
// capture a stack trace inside allocator and zio task-pool locks, so a
// coroutine could be suspended while holding them. Seen as a livelock with
// every executor spinning in SafeAllocator, and as a recursive-lock abort in
// zio's TaskPool. Debug output stays on std's blocking Io.

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

/// Streams the request body back as it arrives: a body larger than the
/// flow-control windows exercises backpressure in both directions.
fn handleEcho(req: *http.Request, res: *http.Response) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [16 * 1024]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

/// A compressible page, gzipped when the client accepts it (with
/// -Dcompression, on zlib-ng).
fn handleBig(_: *http.Request, res: *http.Response) !void {
    res.compress = true;
    var w = res.writer();
    for (0..200) |i| try w.interface.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    try w.end();
}

fn waitForSignal(kind: zio.SignalKind) !void {
    var sig = try zio.Signal.init(kind);
    defer sig.deinit();
    try sig.wait();
}

const has_tls = anole.features.tls != .none;

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var tls_port: u16 = 8443;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| tls_port = try std.fmt.parseInt(u16, p, 10);

    // One executor per CPU (cgroup-aware); executor 0 is this thread.
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .auto });
    defer rt.deinit();
    const io = rt.io();

    std.log.info("zio scheduling={t} executors={d}", .{ zio_options.scheduling, rt.executors.items.len });
    std.log.info("anole features: tls={t} http2={} http3={} websocket={}", .{
        anole.features.tls, anole.features.http2, anole.features.http3, anole.features.websocket,
    });

    const addr: http.Address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", port) };
    // One accept loop per executor (the default on a multi-executor zio);
    // on Linux each also gets its own SO_REUSEPORT socket, so the kernel
    // spreads new connections over the executors' queues.
    const per_core_sockets = builtin.os.tag == .linux;
    var listeners: [2]http.Listener = .{ .{
        .address = addr,
        .http2_prior_knowledge = anole.features.http2,
        .socket_per_acceptor = per_core_sockets,
    }, undefined };
    var listener_count: usize = 1;

    var dev_cert = if (has_tls) try anole.tls.selfSigned(init.gpa, .{}) else {};
    defer if (has_tls) dev_cert.deinit(init.gpa);
    if (has_tls) {
        listeners[1] = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parse("127.0.0.1", tls_port) },
            .socket_per_acceptor = per_core_sockets,
            .tls = .{
                .pem = .{ .cert = dev_cert.cert, .key = dev_cert.key },
                .alpn_protocols = if (anole.features.http2) &.{ "h2", "http/1.1" } else &.{"http/1.1"},
            },
        };
        listener_count = 2;
    }

    var server = http.Server(void).init(init.gpa, io, .{
        .listeners = listeners[0..listener_count],
        .http2 = .{ .max_concurrent_streams = 250 },
    }, {});
    defer server.deinit();

    // Every response gets an X-Request-Id and an access-log line.
    var request_id = http.middleware.RequestId.init(.{});
    var access_log = http.middleware.Logger.init();
    server.router.use(http.Middleware(void).init(&request_id));
    server.router.use(http.Middleware(void).init(&access_log));

    server.router.get("/", handleRoot);
    server.router.get("/users/:id", handleUser);
    server.router.post("/echo", handleEcho);
    server.router.get("/big", handleBig);

    // SIGINT, SIGTERM and the server run as three tasks of one std.Io.Select;
    // whichever finishes first decides. The buffer holds all three results
    // so cancelDiscard below cannot deadlock (std/Io.zig Select.cancel).
    const Done = union(enum) {
        int: anyerror!void,
        term: anyerror!void,
        served: anyerror!void,
    };
    std.log.info("listening on http://127.0.0.1:{d}", .{port});
    if (has_tls) std.log.info("listening on https://127.0.0.1:{d} (self-signed, BoringSSL)", .{tls_port});
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
