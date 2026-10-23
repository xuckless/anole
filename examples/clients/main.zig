//! Anole's outbound clients, each called against a server in the same
//! process.
//!
//!   zig build run-clients
//!
//! The program starts an `anole.Server` on free local ports: HTTP/1.1 and
//! h2c on one, HTTPS (HTTP/1.1 and HTTP/2) on another, and HTTP/3 over UDP,
//! with a development certificate made in memory, which every client
//! trusts as a CA given as PEM in memory. It calls the server with each
//! client and prints what came back:
//!
//!   anole.client(io)           the server's own client: a GET with an
//!                              inline header
//!   anole.http.Client          an HTTPS GET over HTTP/1.1, and one over
//!                              HTTP/2 (`.http2 = true`)
//!   anole.h2.ClientConnection  a GET, a streamed POST with a trailer, and
//!                              8 requests at once on one TLS connection
//!   anole.grpc.Client          grpc.health.v1 Check, on that connection
//!   anole.h3.ClientConnection  a GET over QUIC, with a 5 s timeout
//!   GET /relay                 a handler that makes an HTTP/2 call itself,
//!                              through `req.io`
//!
//! Then it stops the server, which drains, and exits. docs/clients.md
//! explains each client.
const std = @import("std");
const anole = @import("anole");
const http = anole.http;
const h2 = anole.h2;
const h3 = anole.h3;
const grpc = anole.grpc;

/// Keeps the runtime's per-thread lines and the connection loops' debug
/// lines out of a Debug build; info (startup lines, access log) stays.
pub const std_options = anole.std_options;
// A panic is logged (message and stack trace) before the process aborts.
pub const panic = anole.panic;

const App = struct {
    /// Thread-safe: the clients' tasks may run on any executor.
    gpa: std.mem.Allocator,
    /// The cleartext port, for /relay. Set once the server listens.
    http_port: u16 = 0,
};

fn hello(_: *App, req: *anole.Request, res: *anole.Response) !void {
    const version = switch (req.version_major) {
        2 => "HTTP/2",
        3 => "HTTP/3",
        else => "HTTP/1.1",
    };
    try res.print(.text, "hello over {s}", .{version});
}

/// Streams the request body back and sends its length as a trailer. Only
/// HTTP/2 and HTTP/3 carry trailers; HTTP/1.1 drops them.
fn echo(_: *App, req: *anole.Request, res: *anole.Response) !void {
    var in_buf: [4096]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = try res.stream(&out_buf);
    const n = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try res.trailer("x-bytes", try std.fmt.allocPrint(req.arena, "{d}", .{n}));
    try out.end();
}

/// An HTTP/2 call made by a handler. `req.io` is the server's runtime, so
/// the wait suspends this request only. A real application keeps one
/// connection in its context and shares it between requests.
fn relay(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const conn = try h2.ClientConnection.connect(app.gpa, req.io, .{ .host = "127.0.0.1", .port = app.http_port });
    defer conn.close();
    var buf: [256]u8 = undefined;
    const r = try get(conn, "http", "/hello", &buf);
    try res.print(.text, "upstream said {d} \"{s}\"", .{ r.status, r.body });
}

const Got = struct { status: u16, body: []const u8 };

/// One GET on an HTTP/2 or HTTP/3 connection (the two share an API). The
/// body is copied into `out`.
fn get(conn: anytype, scheme: []const u8, path: []const u8, out: []u8) !Got {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = scheme }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    var w: std.Io.Writer = .fixed(out);
    _ = try s.reader().streamRemaining(&w);
    return .{ .status = s.status, .body = w.buffered() };
}

/// One of several GETs sharing a connection.
fn getCounted(conn: *h2.ClientConnection, ok: *std.atomic.Value(usize)) std.Io.Cancelable!void {
    var buf: [64]u8 = undefined;
    const r = get(conn, "https", "/hello", &buf) catch return;
    if (r.status == 200) _ = ok.fetchAdd(1, .monotonic);
}

/// Writes `len` bytes as a request body, then ends it.
fn sendBody(s: *h2.Stream, len: usize) !void {
    const w = s.writer();
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'a');
    var left = len;
    while (left > 0) {
        const n = @min(left, chunk.len);
        try w.writeAll(chunk[0..n]);
        left -= n;
    }
    try s.closeSend();
}

/// A streamed POST: the body goes out from a second task while this one
/// reads the response, as the server echoes it while it arrives.
fn postEcho(io: std.Io, conn: *h2.ClientConnection, len: usize, trailer_buf: []u8) !struct { usize, []const u8 } {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = "/echo" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{ .body = true });
    defer s.release();
    var sender = try io.concurrent(sendBody, .{ s, len });
    const n = blk: {
        s.waitHead() catch |err| break :blk err;
        break :blk s.reader().discardRemaining();
    } catch |err| {
        sender.cancel(io) catch {};
        return err;
    };
    try sender.await(io);
    // `trailers` are in once the body has ended. The slice lives in the
    // stream, so copy it out before `release`.
    const t = s.trailer("x-bytes") orelse "";
    const kept = trailer_buf[0..@min(t.len, trailer_buf.len)];
    @memcpy(kept, t[0..kept.len]);
    return .{ n, kept };
}

fn callAll(server: *anole.Server(App), app: *App, ca_pem: []const u8) !void {
    defer server.stop();
    const io = server.io();
    const gpa = app.gpa;
    try server.waitReady();
    const http_addr = server.addresses()[0].ip;
    const https_addr = server.addresses()[1].ip;
    const h3_addr = server.http3Address().?;
    app.http_port = http_addr.getPort();

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    // The dev certificate is its own CA. Every client takes it as PEM in
    // memory (`.ca = .{ .pem = ... }`); by default they trust the system
    // store.
    const ca: http.Ca = .{ .pem = ca_pem };

    var url_buf: [128]u8 = undefined;

    // The server's own client, from any task of its runtime (a handler
    // passes `req`). It trusts the system store, so a plain http:// URL
    // here.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{http_addr.getPort()});
        var response = try anole.client(io).fetch(url, .{ .headers = &.{.{ "User-Agent", "anole-example" }} });
        defer response.deinit();
        try out.print("anole.client       GET  /hello  {d} \"{s}\"\n", .{ @backingInt(response.status()), try response.body() });
    }

    // dusty's client: pooled keep-alive connections, HTTP/1.1.
    var client = http.Client.init(gpa, io, .{
        .tls = .{ .ca = ca },
        .timeout = .fromSeconds(5),
    });
    defer client.deinit();
    {
        const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hello", .{https_addr.getPort()});
        var response = try client.fetch(url, .{});
        defer response.deinit();
        try out.print("anole.http.Client  GET  {s}  {d} \"{s}\"\n", .{ url, @backingInt(response.status()), (try response.body()) orelse "" });
    }
    // The same client offering HTTP/2 through ALPN: a server that picks it
    // gets the request over HTTP/2, one at a time per pooled connection.
    {
        var client2 = http.Client.init(gpa, io, .{ .tls = .{ .ca = ca }, .timeout = .fromSeconds(5), .http2 = true });
        defer client2.deinit();
        const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hello", .{https_addr.getPort()});
        var response = try client2.fetch(url, .{});
        defer response.deinit();
        try out.print("anole.http.Client  GET  {s}  {d} \"{s}\" (.http2 = true)\n", .{ url, @backingInt(response.status()), (try response.body()) orelse "" });
    }

    // HTTP/2 over TLS: one connection, many streams.
    const conn = try h2.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = https_addr,
        .port = https_addr.getPort(),
        .tls = .{ .ca = ca },
    });
    defer conn.close();
    {
        var buf: [256]u8 = undefined;
        const r = try get(conn, "https", "/hello", &buf);
        try out.print("anole.h2           GET  /hello  {d} \"{s}\"\n", .{ r.status, r.body });

        var trailer_buf: [32]u8 = undefined;
        const n, const trailer = try postEcho(io, conn, 256 * 1024, &trailer_buf);
        try out.print("anole.h2           POST /echo   {d} bytes back, trailer x-bytes: {s}\n", .{ n, trailer });

        var ok: std.atomic.Value(usize) = .init(0);
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..8) |_| try group.concurrent(io, getCounted, .{ conn, &ok });
        try group.await(io);
        try out.print("anole.h2           8 GETs at once on one connection: {d} ok\n", .{ok.load(.monotonic)});
    }

    // gRPC over the same HTTP/2 connection: the standard health service.
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost", .scheme = "https" };
        const health: grpc.Client(grpc.health.pb.Health(grpc.Call, anyerror)) = .{ .channel = &channel };
        const result = try health.unary("Check", arena.allocator(), .{ .service = "" }, .{ .timeout = .fromSeconds(2) });
        try out.print("anole.grpc         Health/Check  {t}, {t}\n", .{ result.status.code, result.message.?.status });
    }

    // HTTP/3 over QUIC, on the UDP port.
    {
        const q = try h3.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = h3_addr,
            .port = h3_addr.getPort(),
            .tls = .{ .ca = ca },
            // Each request's budget, through the end of its body (30 s by
            // default). Past it the stream is reset: error.Timeout.
            .timeout = .fromSeconds(5),
        });
        defer q.close();
        var buf: [256]u8 = undefined;
        const r = try get(q, "https", "/hello", &buf);
        try out.print("anole.h3           GET  /hello  {d} \"{s}\"\n", .{ r.status, r.body });
    }

    // A handler that is itself a client.
    {
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/relay", .{app.http_port});
        var response = try client.fetch(url, .{});
        defer response.deinit();
        try out.print("handler (req.io)   GET  /relay  {d} \"{s}\"\n", .{ @backingInt(response.status()), (try response.body()) orelse "" });
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // The certificate the server presents, which the clients then trust.
    var pem = try anole.tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);

    var app: App = .{ .gpa = gpa };
    var server = try anole.Server(App).init(gpa, .{
        // Port 0: any free port; `addresses()` has the real ones.
        .http = .{ .port = 0 },
        .https = .{ .port = 0, .cert = .{ .pem = .{ .cert = pem.cert, .key = pem.key } } },
        .http3 = .{},
    }, &app);
    defer server.deinit();

    _ = server.grpcHealth();
    server.get("/hello", hello);
    server.post("/echo", echo);
    server.get("/relay", relay);

    var calls = try server.io().concurrent(callAll, .{ &server, &app, pem.cert });
    server.run() catch |err| {
        calls.cancel(server.io()) catch {};
        return err;
    };
    try calls.await(server.io());
}
