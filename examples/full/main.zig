//! Anole with every listener and option spelled out: the full-control
//! counterpart of examples/hello, and the server the conformance and
//! restart scripts drive (tests/h2spec, tests/restart, CI).
//! The server and router wiring follows dusty's README examples (lalinsky/dusty, MIT, d3cb485).
//!
//!   zig build run-full                 # http://127.0.0.1:8080 and https://127.0.0.1:8443
//!   zig build run-full -- 9000 9443    # other ports
//!   zig build run-full -- 8080 8443 8081 8082
//!
//! With four ports it serves one listener per protocol mix through
//! `listeners`, the shape of HttpArena's ports: HTTP/1.1 and h2c on the
//! first, TLS with HTTP/2, HTTP/1.1 and HTTP/3 on the second, TLS with
//! HTTP/1.1 alone on the third, and h2c alone on the fourth. The two TLS
//! listeners share one certificate.
//!
//! With TLS built in (the default; not with -Dtls=none) the HTTPS listener
//! uses a self-signed certificate for localhost that is generated at startup
//! and held only in memory, so clients need `curl -k` or similar. With
//! HTTP/3 built in (the default `full` profile) QUIC serves on the HTTPS
//! port number over UDP.
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

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;

// No `std_options_debug_io = zio.debug_io` (zio's examples set it so logging
// yields): std.debug uses that Io for stack unwinding too, and Debug builds
// capture a stack trace inside allocator and zio task-pool locks, so a
// coroutine could be suspended while holding them. Seen as a livelock with
// every executor spinning in SafeAllocator, and as a recursive-lock abort in
// zio's TaskPool. Debug output stays on std's blocking Io.

fn setThreadHeader(res: *anole.Response) !void {
    const tid = std.Thread.getCurrentId();
    try res.header("X-Thread", try std.fmt.allocPrint(res.arena, "{d}", .{tid}));
}

fn handleRoot(req: *anole.Request, res: *anole.Response) !void {
    _ = req;
    try setThreadHeader(res);
    try res.print(.text, "hello", .{});
}

fn handleUser(req: *anole.Request, res: *anole.Response) !void {
    try setThreadHeader(res);
    const id = req.params.get("id") orelse "unknown";
    try res.print(.text, "user {s}", .{id});
}

/// Streams the request body back as it arrives: a body larger than the
/// flow-control windows exercises backpressure in both directions.
fn handleEcho(req: *anole.Request, res: *anole.Response) !void {
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
fn handleBig(_: *anole.Request, res: *anole.Response) !void {
    res.compress = true;
    var w = res.writer();
    for (0..200) |i| try w.interface.print("line {d}: the quick brown fox jumps over the lazy dog\n", .{i});
    try w.end();
}

pub fn main(init: std.process.Init) !void {
    var port: u16 = 8080;
    var tls_port: u16 = 8443;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    if (args.next()) |p| port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| tls_port = try std.fmt.parseInt(u16, p, 10);
    var h1_tls_port: ?u16 = null;
    var h2c_port: ?u16 = null;
    if (args.next()) |p| h1_tls_port = try std.fmt.parseInt(u16, p, 10);
    if (args.next()) |p| h2c_port = try std.fmt.parseInt(u16, p, 10);
    const tls = anole.features.tls != .none;

    // Four ports: a listener each, named (socket activation and SIGUSR2
    // restarts match sockets by name). The certificate is made once.
    const four = tls and anole.features.http2 and h1_tls_port != null and h2c_port != null;
    const listeners = [_]anole.Listener{
        .{ .name = "http", .port = port },
        .{ .name = "https", .port = tls_port, .tls = .{ .cert = .dev_self_signed }, .http3 = anole.features.http3 },
        .{ .name = "https-h1", .port = h1_tls_port orelse 0, .tls = .{ .cert = .dev_self_signed }, .http2 = false },
        .{ .name = "h2c", .port = h2c_port orelse 0, .http1 = false },
    };

    // The runtime (one executor per CPU, pinned), an HTTP listener with h2c,
    // and an HTTPS one with ALPN h2/http1.1 on a fresh in-memory certificate.
    var app = try anole.Server(void).init(init.gpa, if (four) .{
        .listeners = &listeners,
        .process = init.minimal,
    } else .{
        .http = .{ .port = port },
        .https = if (tls) .{ .port = tls_port, .cert = .dev_self_signed } else null,
        // HTTP/3 on the same port number over UDP, advertised by Alt-Svc.
        .http3 = if (anole.features.http3) .{} else null,
        // Takes sockets from systemd (LISTEN_FDS), and restarts without
        // downtime on SIGUSR2.
        .process = init.minimal,
    }, {});
    defer app.deinit();

    // Every response gets an X-Request-Id and an access-log line.
    app.use(anole.middleware.RequestId.init(.{}));
    app.use(anole.middleware.Logger.init());

    app.get("/", handleRoot);
    app.get("/users/:id", handleUser);
    app.post("/echo", handleEcho);
    app.get("/big", handleBig);

    std.log.info("anole features: tls={t} http2={} http3={} websocket={}", .{
        anole.features.tls, anole.features.http2, anole.features.http3, anole.features.websocket,
    });
    // The server logs one "listening on" line per listener as it starts,
    // HTTP/3 named on the HTTPS one.
    if (tls) std.log.info("the HTTPS certificate is a self-signed development one (curl -k)", .{});
    // Until SIGINT or SIGTERM; then the accept loops stop and in-flight
    // requests drain (bounded by timeout.shutdown).
    try app.run();
    std.log.info("server stopped cleanly", .{});
}
