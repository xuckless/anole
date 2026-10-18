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
//! SIGINT/SIGTERM end `anole.Server.run`, which stops the accept loops and
//! drains in-flight requests before returning. SIGUSR2 starts a new copy of
//! the binary on the same sockets and drains this one once it serves.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;

/// Compile-time zio configuration, read by zio from the root module
/// (zio src/options.zig). `.pinned`: many executors, a task never migrates.
pub const zio_options = anole.zio_options;

/// Log lines read `anole` and `access`, not the libraries underneath.
pub const std_options: std.Options = .{
    .logFn = anole.logFn,
    // zio's per-thread startup lines are debug noise here.
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

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

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var tls_port: u16 = 8443;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| tls_port = try std.fmt.parseInt(u16, p, 10);

    // The runtime (one executor per CPU, pinned), an HTTP listener with h2c,
    // and an HTTPS one with ALPN h2/http1.1 on a fresh in-memory certificate.
    var app = try anole.Server(void).init(init.gpa, .{
        .http = .{ .port = port },
        .https = if (anole.features.tls != .none) .{ .port = tls_port, .cert = .dev_self_signed } else null,
        // Takes sockets from systemd (LISTEN_FDS), and restarts without
        // downtime on SIGUSR2.
        .process = init.minimal,
    }, {});
    defer app.deinit();

    // Every response gets an X-Request-Id and an access-log line.
    app.use(http.middleware.RequestId.init(.{}));
    app.use(http.middleware.Logger.init());

    app.get("/", handleRoot);
    app.get("/users/:id", handleUser);
    app.post("/echo", handleEcho);
    app.get("/big", handleBig);

    std.log.info("anole features: tls={t} http2={} http3={} websocket={}", .{
        anole.features.tls, anole.features.http2, anole.features.http3, anole.features.websocket,
    });
    std.log.info("listening on http://127.0.0.1:{d}", .{port});
    if (anole.features.tls != .none) std.log.info("listening on https://127.0.0.1:{d} (self-signed, BoringSSL)", .{tls_port});
    // Until SIGINT or SIGTERM; then the accept loops stop and in-flight
    // requests drain (bounded by timeout.shutdown).
    try app.run();
    std.log.info("server stopped cleanly", .{});
}
