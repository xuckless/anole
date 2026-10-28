//! The HTTP/3 client against Anole's HTTP/3 server engine: plain requests,
//! a streamed body both ways larger than the windows and the ring,
//! trailers, many concurrent streams on one connection, certificate checks,
//! a server that closes, resumption and 0-RTT (and a replay of it), and a
//! client that moves to a new port.
const std = @import("std");
const wait = @import("anole_test_wait");
const zio = @import("zio");
const dusty = @import("dusty");
const anole_tls = @import("../tls/root.zig");
const client = @import("client.zig");
const Endpoint = @import("server.zig").Endpoint(void);
const quic_tls = @import("quic_tls.zig");
const net = @import("net.zig");
const udp_net = @import("../net/udp.zig");
const Udp = udp_net.Udp;
const early_data = @import("../early_data.zig");

fn hello(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello over h3";
}

fn echo(req: *dusty.Request, res: *dusty.Response) !void {
    var in_buf: [4096]u8 = undefined;
    var body = try req.reader(&in_buf);
    var out_buf: [4096]u8 = undefined;
    var out = try res.stream(&out_buf);
    _ = body.interface.streamRemaining(&out.interface) catch |err| switch (err) {
        error.ReadFailed => return body.err orelse error.Unexpected,
        error.WriteFailed => return out.err orelse error.Unexpected,
    };
    try out.end();
}

fn withTrailers(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "body";
    try res.trailer("x-checksum", "abc");
}

/// The client's certificate as the handler sees it: the DER, or "none".
fn peer(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = req.peerCertificate() orelse "none";
}

/// GET /early: whether the request may be a replay of 0-RTT data.
fn early(req: *dusty.Request, res: *dusty.Response) !void {
    res.body = if (early_data.isEarly(req)) "early" else "late";
}

/// How often POST /early-post ran.
var early_posts: std.atomic.Value(u32) = .init(0);

/// POST /early-post: counts, and says whether it may be a replay.
fn earlyPost(req: *dusty.Request, res: *dusty.Response) !void {
    _ = early_posts.fetchAdd(1, .monotonic);
    res.body = if (early_data.isEarly(req)) "early" else "late";
}

/// POST /answer-first: answers without reading the request body.
fn answerFirst(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "first";
}

/// GET /port: the client's port, as the request reports it.
fn port(req: *dusty.Request, res: *dusty.Response) !void {
    try res.print(.text, "{d}", .{req.remote_address.getPort()});
}

/// GET /download?n=BYTES: that many bytes, streamed.
fn download(req: *dusty.Request, res: *dusty.Response) !void {
    const n = std.fmt.parseInt(usize, req.query.get("n") orelse "0", 10) catch 0;
    var w = try res.writer();
    var chunk: [16 * 1024]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = @truncate(i);
    var left = n;
    while (left > 0) {
        const k = @min(left, chunk.len);
        try w.interface.writeAll(chunk[0..k]);
        left -= k;
    }
    try w.end();
}

fn slow(req: *dusty.Request, res: *dusty.Response) !void {
    try req.io.sleep(.fromSeconds(5), .awake);
    res.body = "too late";
}

/// An event every 100 ms for 1.2 s: a stream that outlives a short
/// request timeout.
fn ticks(req: *dusty.Request, res: *dusty.Response) !void {
    var buf: [256]u8 = undefined;
    var events = try res.startEventStream(&buf);
    for (0..12) |_| {
        try events.send("tick", .{});
        try req.io.sleep(.fromMilliseconds(100), .awake);
    }
    try events.end();
}

/// The head and some of the body, then nothing for a while.
fn stall(req: *dusty.Request, res: *dusty.Response) !void {
    var out_buf: [256]u8 = undefined;
    var out = try res.stream(&out_buf);
    try out.interface.writeAll("part of it");
    try out.interface.flush();
    try req.io.sleep(.fromSeconds(5), .awake);
    try out.end();
}

/// Part of a body, then `Response.abort`.
fn aborted(_: *dusty.Request, res: *dusty.Response) !void {
    var out_buf: [256]u8 = undefined;
    var out = try res.stream(&out_buf);
    try out.interface.writeAll("[1,");
    try out.interface.flush();
    return res.abort();
}

/// POST /nw/sum: the body's length and hash.
fn sum(req: *dusty.Request, res: *dusty.Response) !void {
    var in_buf: [4096]u8 = undefined;
    var body = try req.reader(&in_buf);
    var hasher: std.hash.Wyhash = .init(0);
    var n: usize = 0;
    while (true) {
        const chunk = body.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return body.err orelse error.Unexpected,
        };
        hasher.update(chunk);
        n += chunk.len;
        body.interface.toss(chunk.len);
    }
    try res.print(.text, "{d} {x}", .{ n, hasher.final() });
}

/// Far more than a response ring holds, written at once.
const big_body_len = 300 * 1024 + 7;

fn bigBody(_: *dusty.Request, res: *dusty.Response) !void {
    const body = try res.arena.alloc(u8, big_body_len);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 13);
    res.body = body;
}

/// GET /huge-head: a response head of 90 KiB, in three fields.
fn hugeHead(_: *dusty.Request, res: *dusty.Response) !void {
    const value = try res.arena.alloc(u8, 30 * 1024);
    @memset(value, 'h');
    try res.header("x-big-1", value);
    try res.header("x-big-2", value);
    try res.header("x-big-3", value);
    res.body = "big head";
}

/// GET /fields: the request's cookie, then every `x-multi` value.
fn fields(req: *dusty.Request, res: *dusty.Response) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(res.arena, req.headers.get("cookie") orelse "");
    var it = req.headers.iterator();
    while (it.next()) |e| if (std.ascii.eqlIgnoreCase(e.key, "x-multi")) {
        try out.append(res.arena, '|');
        try out.appendSlice(res.arena, e.value);
    };
    res.body = out.items;
}

/// GET /hold: runs for a second, counting the handlers running at once.
var holding_now: std.atomic.Value(u32) = .init(0);
var holding_peak: std.atomic.Value(u32) = .init(0);
fn holdHandler(req: *dusty.Request, res: *dusty.Response) !void {
    const n = holding_now.fetchAdd(1, .acq_rel) + 1;
    defer _ = holding_now.fetchSub(1, .acq_rel);
    _ = holding_peak.fetchMax(n, .acq_rel);
    req.io.sleep(.fromSeconds(1), .awake) catch {};
    res.body = "held";
}

/// A `no_wait` handler that waits all the same.
fn slowNoWait(req: *dusty.Request, res: *dusty.Response) !void {
    try req.io.sleep(.fromMilliseconds(20), .awake);
    res.body = "slow but whole";
}

/// Three 2000-byte header fields.
fn bigHead(_: *dusty.Request, res: *dusty.Response) !void {
    const value: [2000]u8 = @splat('v');
    try res.header("x-a", &value);
    try res.header("x-b", &value);
    try res.header("x-c", &value);
    res.body = "big head";
}

/// GET /wait: tells the test it started, then waits for a cancel.
var wait_started: std.Io.Event = .unset;
var wait_canceled: std.Io.Event = .unset;
fn waitHandler(req: *dusty.Request, res: *dusty.Response) !void {
    wait_started.set(req.io);
    req.io.sleep(.fromSeconds(30), .awake) catch |err| {
        wait_canceled.set(req.io);
        return err;
    };
    res.body = "late";
}

/// POST /gated: reads nothing until the test opens the gate, then echoes.
var gate: std.Io.Event = .unset;
fn gated(req: *dusty.Request, res: *dusty.Response) !void {
    try gate.wait(req.io);
    return echo(req, res);
}

fn get(conn: *client.ClientConnection, path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    return s.reader().allocRemaining(gpa, .unlimited);
}

const Fixture = struct {
    pem: anole_tls.Pem,
    http: *dusty.Server(void),
    ep: *Endpoint,
    future: std.Io.Future(anyerror!void),
    bundle: std.crypto.Certificate.Bundle,

    fn start(gpa: std.mem.Allocator, io: std.Io) !Fixture {
        return startWith(gpa, io, .{ .listeners = &.{}, .request = .{ .max_body_size = 8 << 20 } }, .{});
    }

    /// What `startWith` sets on the endpoint beyond the defaults.
    const Extra = struct {
        /// Mutual TLS, with the server's own (CA:TRUE) certificate as the CA.
        client_auth: ?@FieldType(quic_tls.ClientAuth, "mode") = null,
        fd: ?std.posix.fd_t = null,
        secret: ?[32]u8 = null,
        /// GET /hello says it comes from the successor.
        successor: bool = false,
        early_data: bool = false,
        prefer_v2: bool = true,
    };

    fn startWith(gpa: std.mem.Allocator, io: std.Io, config: dusty.ServerConfig, extra: Extra) !Fixture {
        var pem = try anole_tls.selfSigned(gpa, .{});
        errdefer pem.deinit(gpa);
        return startWithPem(gpa, io, config, extra, pem);
    }

    /// As `startWith`, with a given certificate (which the fixture owns).
    fn startWithPem(gpa: std.mem.Allocator, io: std.Io, config: dusty.ServerConfig, extra: Extra, pem_in: anole_tls.Pem) !Fixture {
        var pem = pem_in;
        errdefer pem.deinit(gpa);
        const http = try gpa.create(dusty.Server(void));
        errdefer gpa.destroy(http);
        http.* = .init(gpa, io, config, {});
        errdefer http.deinit();
        if (extra.successor) http.router.get("/hello", helloFromSuccessor) else http.router.get("/hello", hello);
        http.router.post("/echo", echo);
        http.router.get("/trailers", withTrailers);
        http.router.get("/slow", slow);
        http.router.get("/ticks", ticks);
        http.router.get("/stall", stall);
        http.router.get("/peer", peer);
        http.router.get("/abort", aborted);
        http.router.get("/early", early);
        http.router.post("/early-post", earlyPost);
        http.router.post("/answer-first", answerFirst);
        http.router.get("/port", port);
        http.router.get("/download", download);
        http.router.get("/huge-head", hugeHead);
        http.router.get("/fields", fields);
        http.router.get("/hold", holdHandler);
        http.router.get("/wait", waitHandler);
        http.router.post("/gated", gated);
        http.router.get("/big-head", bigHead);
        http.router.addRouteWith(.get, "/nw/hello", hello, .{ .no_wait = true });
        http.router.addRouteWith(.post, "/nw/sum", sum, .{ .no_wait = true });
        http.router.addRouteWith(.get, "/nw/big", bigBody, .{ .no_wait = true });
        http.router.addRouteWith(.get, "/nw/slow", slowNoWait, .{ .no_wait = true });
        var bundle = try @import("../tls/testing.zig").bundleFromPem(gpa, std.Io.Clock.real.now(io).toSeconds(), pem.cert);
        errdefer bundle.deinit(gpa);
        const ep = try Endpoint.init(gpa, io, http, .{
            .address = .{ .ip4 = .loopback(0) },
            .cert_pem = pem.cert,
            .key_pem = pem.key,
            .max_streams_bidi = 8,
            .client_auth = if (extra.client_auth) |mode| .{ .ca_der = bundle.bytes.items, .mode = mode } else null,
            .fd = extra.fd,
            .secret = extra.secret,
            .early_data = extra.early_data,
            .prefer_v2 = extra.prefer_v2,
        });
        errdefer ep.deinit();
        const future = try io.concurrent(runEndpoint, .{ep});
        return .{ .pem = pem, .http = http, .ep = ep, .future = future, .bundle = bundle };
    }

    fn runEndpoint(ep: *Endpoint) anyerror!void {
        try ep.run();
    }

    fn stop(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) void {
        f.future.cancel(io) catch {};
        f.ep.deinit();
        f.http.deinit();
        gpa.destroy(f.http);
        f.bundle.deinit(gpa);
        f.pem.deinit(gpa);
    }

    fn connect(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) !*client.ClientConnection {
        return client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert } },
        });
    }

    /// Through `via` (a relay) if given, with tickets in `cache`.
    fn connectResuming(f: *Fixture, gpa: std.mem.Allocator, io: std.Io, cache: *client.SessionCache, early_ok: bool, via: ?*Relay) !*client.ClientConnection {
        return client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = if (via) |r| r.front.socket.address else f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert } },
            .session_cache = cache,
            .early_data = early_ok,
        });
    }
};

test "h3 client: GET, a large streamed echo, trailers and 40 concurrent streams" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);

    const conn = try f.connect(gpa, io);
    defer conn.close();

    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);

    {
        // 3 MiB up and back: many windows and rings' worth each way.
        const big = try gpa.alloc(u8, 3 << 20);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = "/echo" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{ .body = true });
        defer s.release();
        var sender = try io.concurrent(struct {
            fn send(st: *client.Stream, data: []const u8) !void {
                try st.writer().writeAll(data);
                try st.closeSend();
            }
        }.send, .{ s, big });
        try s.waitHead();
        const back = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(back);
        try sender.await(io);
        try std.testing.expect(std.mem.eql(u8, big, back));
    }
    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/trailers" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try s.waitHead();
        const b = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("body", b);
        try std.testing.expectEqualStrings("abc", s.trailer("x-checksum").?);
    }
    {
        // Forty tasks, one connection, a server limit of 8 streams at once:
        // requests wait for stream credit.
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        var ok: std.atomic.Value(usize) = .init(0);
        for (0..40) |_| try group.concurrent(io, struct {
            fn one(cn: *client.ClientConnection, a: std.mem.Allocator, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
                const b = get(cn, "/hello", a) catch return;
                defer a.free(b);
                if (std.mem.eql(u8, b, "hello over h3")) _ = count.fetchAdd(1, .monotonic);
            }
        }.one, .{ conn, gpa, &ok });
        try group.await(io);
        try std.testing.expectEqual(@as(usize, 40), ok.load(.monotonic));
    }
    // Every packet went out through the endpoint's outbox, and its sends
    // carried several at a time: the 3 MiB alone is thousands of packets.
    const stats = &f.ep.stats;
    const datagrams = stats.datagrams_out.load(.monotonic);
    try std.testing.expect(datagrams > 2000);
    try std.testing.expect(stats.tx_flushes.load(.monotonic) < datagrams);
}

test "h3 client: certificate checks, and a server that goes away" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    var stopped = false;
    defer if (!stopped) f.stop(gpa, io);

    // No trust in the server's certificate, or the wrong name.
    try std.testing.expectError(error.HandshakeFailed, client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .connect_timeout = .fromSeconds(2),
    }));
    try std.testing.expectError(error.HandshakeFailed, client.ClientConnection.connect(gpa, io, .{
        .host = "example.com",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .connect_timeout = .fromSeconds(2),
    }));

    const conn = try f.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    gpa.free(body);

    // The server drains: GOAWAY, then CONNECTION_CLOSE. New requests fail.
    f.stop(gpa, io);
    stopped = true;
    const Refused = struct {
        conn: *client.ClientConnection,
        gpa: std.mem.Allocator,
        fn cond(c: @This()) !bool {
            const b = get(c.conn, "/hello", c.gpa) catch |err| {
                try std.testing.expect(err == error.ConnectionClosed or err == error.StreamReset);
                return true;
            };
            c.gpa.free(b);
            return false;
        }
    };
    try wait.waitUntil(io, "a request on the draining connection fails", Refused{ .conn = conn, .gpa = gpa }, Refused.cond);
}

/// POSTs `body` to `path` and returns the response body.
fn post(conn: *client.ClientConnection, io: std.Io, path: []const u8, body: []const u8, gpa: std.mem.Allocator) ![]u8 {
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{ .body = true });
    defer s.release();
    var sender = try io.concurrent(struct {
        fn send(st: *client.Stream, data: []const u8) !void {
            try st.writer().writeAll(data);
            try st.closeSend();
        }
    }.send, .{ s, body });
    try s.waitHead();
    const back = try s.reader().allocRemaining(gpa, .unlimited);
    errdefer gpa.free(back);
    try sender.await(io);
    try std.testing.expectEqual(@as(u16, 200), s.status);
    return back;
}

test "h3 server: no_wait routes run inline, past the ring, beside tasks; one that waits still answers" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var ok: std.atomic.Value(usize) = .init(0);
    const Check = struct {
        fn one(cn: *client.ClientConnection, a: std.mem.Allocator, path: []const u8, want: []const u8, count: *std.atomic.Value(usize)) std.Io.Cancelable!void {
            const b = get(cn, path, a) catch return;
            defer a.free(b);
            if (std.mem.eql(u8, b, want)) _ = count.fetchAdd(1, .monotonic);
        }
    };
    for (0..20) |_| try group.concurrent(io, Check.one, .{ conn, gpa, "/nw/hello?x=1", "hello over h3", &ok });
    try group.concurrent(io, Check.one, .{ conn, gpa, "/hello", "hello over h3", &ok });
    try group.concurrent(io, Check.one, .{ conn, gpa, "/nw/slow", "slow but whole", &ok });
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 22), ok.load(.monotonic));

    // Written at once, far past the ring: the rest waits for the peer's
    // acknowledgments without the endpoint task waiting for them.
    const b = try get(conn, "/nw/big", gpa);
    defer gpa.free(b);
    try std.testing.expectEqual(@as(usize, big_body_len), b.len);
    for (b, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i *% 13)), byte);

    // A body: inline when it came whole with the head, on a task when it
    // takes many packets.
    const body = try gpa.alloc(u8, 2 << 20);
    defer gpa.free(body);
    for (body, 0..) |*x, i| x.* = @truncate(i *% 77 +% (i >> 13));
    var expect: [64]u8 = undefined;
    for ([_]usize{ 0, 10, 1000, body.len }) |n| {
        const got = try post(conn, io, "/nw/sum", body[0..n], gpa);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ n, std.hash.Wyhash.hash(0, body[0..n]) }), got);
    }

    const s = try conn.request(&.{
        .{ .name = ":method", .value = "HEAD" },  .{ .name = ":path", .value = "/nw/hello" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    const none = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // The twenty, the slow one, the big one and the HEAD at least; most of
    // the bodies too.
    try std.testing.expect(f.ep.stats.served_inline.load(.monotonic) >= 23);
}

test "h3 server: long-header packets with a connection ID over 20 bytes are dropped, and the endpoint carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);

    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var raw: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer raw.socket.close(io);
    var pkt: [1300]u8 = undefined;
    // Version 0 (Version Negotiation), version 1 and an unknown version,
    // each with a 200-byte destination ID; short and padded to 1200+.
    for ([_]u32{ 0, 1, 0x1a2a3a4a }) |version| for ([_]usize{ 208, 1300 }) |len| {
        @memset(&pkt, 0xab);
        pkt[0] = 0xc0;
        std.mem.writeInt(u32, pkt[1..5], version, .big);
        pkt[5] = 200;
        pkt[6 + 200] = 0;
        raw.send(io, f.ep.address(), null, 0, pkt[0..len], len);
    };
    // A destination ID of 21 bytes, one past the limit.
    pkt[0] = 0xc0;
    std.mem.writeInt(u32, pkt[1..5], 0, .big);
    pkt[5] = 21;
    pkt[6 + 21] = 0;
    raw.send(io, f.ep.address(), null, 0, pkt[0..28], 28);
    // No wait: the endpoint reads its socket in order, so they are behind
    // it before the connection's Initial.

    const conn = try f.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

fn headersStatus(conn: *client.ClientConnection, gpa: std.mem.Allocator, extra: []const client.Header) !u16 {
    var all: std.ArrayList(client.Header) = .empty;
    defer all.deinit(gpa);
    try all.appendSlice(gpa, &.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/hello" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    });
    try all.appendSlice(gpa, extra);
    const s = try conn.request(all.items, .{});
    defer s.release();
    try s.waitHead();
    const body = try s.reader().allocRemaining(gpa, .unlimited);
    gpa.free(body);
    return s.status;
}

test "h3 server: a request head past max_field_section_size or max_header_count gets 431, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    // 160 KiB in 20 fields: few enough, but past the 64 KiB section limit.
    const value = try gpa.alloc(u8, 8 * 1024);
    defer gpa.free(value);
    @memset(value, 'v');
    var names: [40][16]u8 = undefined;
    var big: [20]client.Header = undefined;
    for (&big, 0..) |*hd, i| hd.* = .{ .name = try std.fmt.bufPrint(&names[i], "x-big-{d}", .{i}), .value = value };
    try std.testing.expectEqual(@as(u16, 431), try headersStatus(conn, gpa, &big));

    // Small, but more fields than request.max_header_count (32).
    var many: [40]client.Header = undefined;
    for (&many, 0..) |*hd, i| hd.* = .{ .name = try std.fmt.bufPrint(&names[i], "x-many-{d}", .{i}), .value = "1" };
    try std.testing.expectEqual(@as(u16, 431), try headersStatus(conn, gpa, &many));

    // Just under both limits: served.
    try std.testing.expectEqual(@as(u16, 200), try headersStatus(conn, gpa, big[0..6]));
    try std.testing.expectEqual(@as(u16, 200), try headersStatus(conn, gpa, many[0..30]));
}

test "h3 client: a 90 KiB response head fails under the default max_header_list_size, and passes when it is raised" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    {
        const conn = try f.connect(gpa, io);
        defer conn.close();
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/huge-head" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{});
        defer s.release();
        try std.testing.expectError(error.HeadersTooLarge, s.waitHead());
    }
    // A client that allows it takes the head.
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .max_header_list_size = 128 * 1024,
    });
    defer conn.close();
    const body = try get(conn, "/huge-head", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("big head", body);
}

test "h3 server: cookie crumbs are joined with \"; \", other repeated fields all kept" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/fields" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        .{ .name = "cookie", .value = "a=1" },    .{ .name = "x-multi", .value = "one" },
        .{ .name = "cookie", .value = "b=2" },    .{ .name = "x-multi", .value = "two" },
        .{ .name = "cookie", .value = "c=3" },
    }, .{});
    defer s.release();
    try s.waitHead();
    const body = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a=1; b=2; c=3|one|two", body);
}

test "h3 server: hq_interop_root is refused outside the interop runner's program" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var pem = try anole_tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    var http: dusty.Server(void) = .init(gpa, io, .{ .listeners = &.{} }, {});
    defer http.deinit();
    try std.testing.expectError(error.HqInteropNotAllowed, Endpoint.init(gpa, io, &http, .{
        .address = .{ .ip4 = .loopback(0) },
        .cert_pem = pem.cert,
        .key_pem = pem.key,
        .hq_interop_root = ".",
    }));
}

test "h3 server: requests the client cancels keep their stream credit until their handlers end" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    holding_peak.store(0, .monotonic);

    // Forty requests, each canceled once its handler has started: the
    // server's limit is 8 streams at once, handlers included.
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..40) |_| try group.concurrent(io, struct {
        fn one(cn: *client.ClientConnection, i: std.Io) std.Io.Cancelable!void {
            const st = request(cn, "GET", "/hold", .{}) catch return;
            try i.sleep(.fromMilliseconds(30), .awake);
            st.release();
        }
    }.one, .{ conn, io });
    try group.await(io);
    try std.testing.expect(holding_peak.load(.monotonic) <= 8);

    // The connection carries on once they are done.
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 server: Response.abort resets the stream, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/abort" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    // A reset, before or after the head: never a whole body.
    if (s.waitHead()) |_| {
        if (s.reader().allocRemaining(gpa, .unlimited)) |body| {
            gpa.free(body);
            return error.WholeBody;
        } else |_| {}
    } else |_| {}

    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 server: a request that outlives timeout.request is reset" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{}, .timeout = .{ .request = .fromMilliseconds(300) } }, .{});
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const started = std.Io.Clock.awake.now(io);
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/slow" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    // The handler takes 5 s: no head before that is the timeout's doing.
    if (s.waitHead()) |_| return error.ServedPastTheTimeout else |_| {}
    if (wait.timing()) try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);

    // The connection carries on.
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 server: an event stream outlives timeouts.request" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{}, .timeout = .{ .request = .fromMilliseconds(300), .write = .fromSeconds(5) } }, .{});
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/ticks", gpa);
    defer gpa.free(body);
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, body, "data: tick"));
}

test "h3 server: mutual TLS in request mode, and the client certificate in handlers (PEM or files)" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .client_auth = .request });
    defer f.stop(gpa, io);

    // No certificate: served, and the handler sees none.
    {
        const conn = try f.connect(gpa, io);
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("none", body);
    }
    // The server's own certificate (it is its own CA) as the client's.
    {
        const conn = try client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert }, .client_certificate = .{ .pem = .{ .cert = f.pem.cert, .key = f.pem.key } } },
        });
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualSlices(u8, f.bundle.bytes.items, body);
    }
    // The same certificate and the CA from files.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cert.pem", .data = f.pem.cert });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = f.pem.key });
        var cert_buf: [160]u8 = undefined;
        var key_buf: [160]u8 = undefined;
        const cert_path = try std.fmt.bufPrint(&cert_buf, ".zig-cache/tmp/{s}/cert.pem", .{tmp.sub_path});
        const key_path = try std.fmt.bufPrint(&key_buf, ".zig-cache/tmp/{s}/key.pem", .{tmp.sub_path});
        const conn = try client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{
                .ca = .{ .file = cert_path },
                .client_certificate = .fromFiles(cert_path, key_path),
            },
        });
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        defer gpa.free(body);
        try std.testing.expectEqualSlices(u8, f.bundle.bytes.items, body);
    }
    // A certificate from a CA the server does not know is refused, even
    // though one was only requested.
    {
        var other = try anole_tls.selfSigned(gpa, .{});
        defer other.deinit(gpa);
        if (client.ClientConnection.connect(gpa, io, .{
            .host = "localhost",
            .address = f.ep.address(),
            .port = f.ep.address().getPort(),
            .tls = .{ .ca = .{ .pem = f.pem.cert }, .client_certificate = .{ .pem = .{ .cert = other.cert, .key = other.key } } },
            .connect_timeout = .fromSeconds(3),
        })) |conn| {
            defer conn.close();
            if (get(conn, "/peer", gpa)) |body| {
                gpa.free(body);
                return error.ServedAnUntrustedCertificate;
            } else |_| {}
        } else |_| {}
    }
}

fn helloFromSuccessor(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "hello from the successor";
}

test "h3 server: a hand-over closes the connections at once and leaves the socket to the successor" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest; // hands the UDP socket over by fd (dup), which is Unix only
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var old = try Fixture.start(gpa, io);
    var old_stopped = false;
    defer if (!old_stopped) old.stop(gpa, io);

    // An idle timeout no run reaches: only the hand-over can end it.
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = old.ep.address(),
        .port = old.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = old.pem.cert } },
        .idle_timeout = .fromSeconds(3600),
    });
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    gpa.free(body);

    // The successor: the same socket (a duplicate, as a new process would
    // inherit it), the same secret and certificate, binding nothing.
    const fd = std.c.dup(old.ep.udp.socket.handle);
    try std.testing.expect(fd >= 0);
    const pem_copy: anole_tls.Pem = .{ .cert = try gpa.dupe(u8, old.pem.cert), .key = try gpa.dupe(u8, old.pem.key) };
    var new = try Fixture.startWithPem(gpa, io, .{ .listeners = &.{} }, .{
        .fd = fd,
        .secret = old.ep.secret,
        .successor = true,
    }, pem_copy);
    defer new.stop(gpa, io);
    try std.testing.expectEqual(old.ep.address().getPort(), new.ep.address().getPort());
    try std.testing.expectEqualSlices(u8, &old.ep.secret, &new.ep.secret);

    // The old endpoint hands over: its client hears CONNECTION_CLOSE at
    // once, not after an idle timeout.
    const started = std.Io.Clock.awake.now(io);
    old.ep.handOver();
    old.stop(gpa, io);
    old_stopped = true;
    if (get(conn, "/hello", gpa)) |b| {
        gpa.free(b);
        return error.ServedAfterHandOver;
    } else |err| try std.testing.expect(err == error.ConnectionClosed or err == error.StreamReset);
    // The client's idle timeout is an hour: the close came from the
    // hand-over, whenever it arrived.
    if (wait.timing()) try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);

    // Every new connection reaches the successor.
    for (0..5) |_| {
        const c2 = try new.connect(gpa, io);
        defer c2.close();
        const b = try get(c2, "/hello", gpa);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("hello from the successor", b);
    }
}

test "h3 client: request timeouts, for the head and for the body, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .timeout = .fromMilliseconds(300),
    });
    defer conn.close();
    const headers: []const client.Header = &.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/slow" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    };

    const started = std.Io.Clock.awake.now(io);
    {
        const s = try conn.request(headers, .{});
        defer s.release();
        try std.testing.expectError(error.Timeout, s.waitHead());
    }
    // The handler takes 5 s: Timeout before that is the timeout's doing.
    if (wait.timing()) try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);
    {
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/stall" },
            .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
        }, .{ .timeout = .{ .duration = .{ .raw = .fromMilliseconds(300), .clock = .awake } } });
        defer s.release();
        try s.waitHead();
        try std.testing.expectError(error.ReadFailed, s.reader().allocRemaining(gpa, .unlimited));
        try std.testing.expectEqual(@as(?client.StreamError, error.Timeout), s.readError());
    }
    {
        const s = try conn.request(headers, .{});
        defer s.release();
        s.cancel();
        try std.testing.expectError(error.Canceled, s.waitHead());
    }
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 client: connect_timeout bounds a handshake nobody answers" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    // Bound, never read: the packets go nowhere, and nothing says so.
    const hole = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer hole.close(io);
    const started = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = hole.address,
        .port = hole.address.getPort(),
        .tls = .{ .insecure_skip_verify = true },
        .connect_timeout = .fromMilliseconds(300),
    }));
    // 300 ms, not the 10 s default: a bound only test-timing checks.
    if (wait.timing()) try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3000);
}

/// A UDP relay between a client and a server, which can hold the server's
/// answer back until the server has seen what the test waits for (so 0-RTT
/// requests are sure to be sent, and handled, before the handshake
/// completes) and record what the client sent (to replay it).
///
/// It works per datagram and decides by what a datagram carries or by what
/// the server reports, never by how many reads it took: its sockets have
/// GRO off, and a client's flight may leave in one GSO send or several.
pub const Relay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Where the client sends.
    front: Udp,
    /// Toward the server.
    back: Udp,
    /// Toward the server after a NAT rebinding (`rebind_on_answer`).
    back2: Udp,
    server: std.Io.net.IpAddress,
    mutex: std.Io.Mutex = .init,
    client: ?std.Io.net.IpAddress = null,
    /// Once the server has answered, the client's next datagram (and so all
    /// after it) waits this long, once.
    hold_ms: u32 = 0,
    answered: bool = false,
    /// The client's next this many datagrams are lost.
    drop_up: u32 = 0,
    /// The server's next datagram, and so all after it, waits this long,
    /// once.
    hold_down_ms: u32 = 0,
    /// When set, the NAT rebinds as the server first answers: that answer
    /// is lost, as is everything else the server sends to the old port, and
    /// the client's datagrams from then on leave from another port.
    rebind_on_answer: bool = false,
    rebound: bool = false,
    recording: bool = false,
    /// What the client sent while recording, one datagram each.
    recorded: std.ArrayList([]u8) = .empty,
    /// While set (`armGated`), the server's datagrams wait for `openDown`:
    /// the client hears nothing from the server, so it has no handshake
    /// keys, and every request it makes meanwhile goes in 0-RTT packets.
    gate_down: bool = false,
    gate: std.Io.Event = .unset,
    /// The datagrams recorded before the gate opened: the first flight.
    first_flight: usize = 0,
    group: std.Io.Group = .init,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, server: std.Io.net.IpAddress) !*Relay {
        const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        // One datagram per read and per send: GRO would merge a flight
        // into one read, and the decisions below are per datagram.
        const opts: Udp.Options = .{ .gro = false, .gso = false };
        const r = try gpa.create(Relay);
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .io = io,
            .front = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), opts),
            .back = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), opts),
            .back2 = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), opts),
            .server = server,
        };
        try r.group.concurrent(io, up, .{r});
        try r.group.concurrent(io, down, .{ r, false });
        try r.group.concurrent(io, down, .{ r, true });
        return r;
    }

    pub fn stop(r: *Relay) void {
        r.group.cancel(r.io);
        r.front.socket.close(r.io);
        r.back.socket.close(r.io);
        r.back2.socket.close(r.io);
        r.forget();
        r.recorded.deinit(r.gpa);
        r.gpa.destroy(r);
    }

    fn forget(r: *Relay) void {
        for (r.recorded.items) |d| r.gpa.free(d);
        r.recorded.clearRetainingCapacity();
    }

    /// Records from now on, holding the client back `hold_ms` once the
    /// server answers: for the next connection.
    fn arm(r: *Relay, hold_ms: u32) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.forget();
        r.recording = true;
        r.answered = false;
        r.hold_ms = hold_ms;
    }

    /// `arm`, with the server's datagrams held until `openDown`: the first
    /// flight is whatever the client sends until then.
    fn armGated(r: *Relay) void {
        r.arm(0);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.gate_down = true;
        r.gate = .unset;
        r.first_flight = 0;
    }

    /// The server's datagrams go on; what was recorded so far is the
    /// first flight.
    fn openDown(r: *Relay) void {
        r.mutex.lockUncancelable(r.io);
        r.first_flight = r.recorded.items.len;
        r.gate_down = false;
        r.mutex.unlock(r.io);
        r.gate.set(r.io);
    }

    /// Opens the gate once the server has handled the client's early
    /// requests (`want_served` early GETs served, `want_held` early POSTs held for
    /// the handshake): they reached it in 0-RTT, so they are in the
    /// recorded first flight, and the handshake can't have completed (the
    /// client hasn't heard the server yet). It waits on the server's own
    /// counters, not on the relay's traffic: how a client spreads its
    /// requests over datagrams is its business.
    fn openDownWhenEarly(r: *Relay, io: std.Io, ep: *Endpoint, want_served: u64, want_held: u64) !void {
        const Early = struct {
            ep: *Endpoint,
            served: u64,
            held: u64,
            fn seen(self: *const @This()) bool {
                return self.ep.early_served.load(.monotonic) >= self.served and
                    self.ep.early_held.load(.monotonic) >= self.held;
            }
        };
        const counts: Early = .{ .ep = ep, .served = want_served, .held = want_held };
        try wait.waitUntil(io, "Early.seen", &counts, Early.seen);
        r.openDown();
    }

    /// The client's next datagram, and so all after it, waits `ms` once:
    /// whatever the client sends meanwhile reaches the server together.
    pub fn holdNext(r: *Relay, ms: u32) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.answered = true;
        r.hold_ms = ms;
    }

    fn disarm(r: *Relay) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.recording = false;
        r.hold_ms = 0;
    }

    fn up(r: *Relay) std.Io.Cancelable!void {
        const buf = r.gpa.alloc(u8, 65536) catch return;
        defer r.gpa.free(buf);
        var control: Udp.Control align(std.Io.net.cmsg_align) = undefined;
        while (true) {
            var dg = r.front.receive(r.io, buf, &control, .none) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => continue,
            };
            // GRO is off, so this is one datagram; `next` would still walk
            // a batch one by one.
            while (dg.next()) |d| try r.forwardUp(dg.from, d);
        }
    }

    /// One of the client's datagrams, toward the server (or lost).
    fn forwardUp(r: *Relay, from: std.Io.net.IpAddress, d: []const u8) std.Io.Cancelable!void {
        r.mutex.lockUncancelable(r.io);
        r.client = from;
        if (r.drop_up > 0) {
            r.drop_up -= 1;
            r.mutex.unlock(r.io);
            return;
        }
        const hold = if (r.answered) r.hold_ms else 0;
        if (hold > 0) r.hold_ms = 0;
        if (r.recording) {
            const copy = r.gpa.dupe(u8, d) catch null;
            if (copy) |c| r.recorded.append(r.gpa, c) catch r.gpa.free(c);
        }
        const via = if (r.rebound) &r.back2 else &r.back;
        r.mutex.unlock(r.io);
        if (hold > 0) try r.io.sleep(.fromMilliseconds(hold), .awake);
        via.send(r.io, r.server, null, 0, d, d.len);
    }

    fn down(r: *Relay, second: bool) std.Io.Cancelable!void {
        const buf = r.gpa.alloc(u8, 65536) catch return;
        defer r.gpa.free(buf);
        var control: Udp.Control align(std.Io.net.cmsg_align) = undefined;
        const from = if (second) &r.back2 else &r.back;
        while (true) {
            var dg = from.receive(r.io, buf, &control, .none) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => continue,
            };
            r.mutex.lockUncancelable(r.io);
            if (!second and r.rebind_on_answer) {
                // The NAT rebinds now: this answer, to the old port, is lost.
                r.rebind_on_answer = false;
                r.rebound = true;
            }
            if (r.rebound != second) {
                // To a binding the NAT no longer has: lost.
                r.mutex.unlock(r.io);
                continue;
            }
            if (r.gate_down) {
                r.mutex.unlock(r.io);
                try r.gate.wait(r.io);
                r.mutex.lockUncancelable(r.io);
            }
            r.answered = true;
            const to = r.client;
            const hold = r.hold_down_ms;
            r.hold_down_ms = 0;
            r.mutex.unlock(r.io);
            if (hold > 0) try r.io.sleep(.fromMilliseconds(hold), .awake);
            if (to) |a| while (dg.next()) |d| r.front.send(r.io, a, null, 0, d, d.len);
        }
    }

    /// What the client sent while recording, again, from a new address: an
    /// attacker who captured the flight.
    fn replay(r: *Relay) !void {
        const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var attacker: Udp = .init(try lo.bind(r.io, .{ .mode = .dgram, .protocol = .udp }), .{});
        defer attacker.socket.close(r.io);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        for (r.recorded.items) |d| attacker.send(r.io, r.server, null, 0, d, d.len);
    }

    /// The first flight (`armGated`) again as one datagram, as clients
    /// that coalesce their first flight send it: its Initial packets in
    /// order (a post-quantum ClientHello spans two), then every 0-RTT
    /// packet, so the requests are in the server's first datagram.
    fn replayCoalesced(r: *Relay) !void {
        const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var sender: Udp = .init(try lo.bind(r.io, .{ .mode = .dgram, .protocol = .udp }), .{});
        defer sender.socket.close(r.io);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.first_flight == 0) return error.NoFirstFlight;
        var initials: std.ArrayList([]const u8) = .empty;
        defer initials.deinit(r.gpa);
        var zero_rtt: std.ArrayList([]const u8) = .empty;
        defer zero_rtt.deinit(r.gpa);
        for (r.recorded.items[0..r.first_flight]) |d| {
            var it: LongPackets = .{ .data = d };
            while (it.next()) |pkt| switch (pkt.kind) {
                .initial => try initials.append(r.gpa, pkt.bytes),
                .zero_rtt => try zero_rtt.append(r.gpa, pkt.bytes),
                else => {},
            };
        }
        if (zero_rtt.items.len == 0) return error.NoEarlyData;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(r.gpa);
        if (initials.items.len == 0) return error.NoInitial;
        for (initials.items) |pkt| try joined.appendSlice(r.gpa, pkt);
        for (zero_rtt.items) |pkt| try joined.appendSlice(r.gpa, pkt);
        sender.send(r.io, r.server, null, 0, joined.items, joined.items.len);
    }
};

/// The long-header packets at the start of a datagram, each whole (RFC 9000
/// §17.2; the type bits are not header-protected). A short-header packet,
/// or anything unreadable, ends them.
const LongPackets = struct {
    data: []const u8,
    at: usize = 0,

    const Kind = enum { initial, zero_rtt, handshake, retry };

    fn kindOf(first: u8, version: u32) ?Kind {
        const bits: u2 = @truncate(first >> 4);
        return switch (version) {
            0x00000001 => switch (bits) {
                0 => .initial,
                1 => .zero_rtt,
                2 => .handshake,
                3 => .retry,
            },
            // QUIC v2 (RFC 9369) numbers them differently.
            0x6b3343cf => switch (bits) {
                1 => .initial,
                2 => .zero_rtt,
                3 => .handshake,
                0 => .retry,
            },
            else => null,
        };
    }

    fn varint(d: []const u8, p: *usize) ?usize {
        if (p.* >= d.len) return null;
        const n = @as(usize, 1) << @intCast(d[p.*] >> 6);
        if (p.* + n > d.len) return null;
        var v: usize = d[p.*] & 0x3f;
        for (d[p.* + 1 .. p.* + n]) |b| v = (v << 8) | b;
        p.* += n;
        return v;
    }

    fn next(it: *LongPackets) ?struct { kind: Kind, bytes: []const u8 } {
        const d = it.data;
        const start = it.at;
        if (start + 7 > d.len or d[start] & 0x80 == 0) return null;
        const kind = kindOf(d[start], std.mem.readInt(u32, d[start + 1 ..][0..4], .big)) orelse return null;
        if (kind == .retry) return null;
        var p = start + 5;
        p += 1 + @as(usize, d[p]);
        if (p >= d.len) return null;
        p += 1 + @as(usize, d[p]);
        if (kind == .initial) {
            // The token: its length moves `p` past the length's own bytes.
            const token_len = varint(d, &p) orelse return null;
            p += token_len;
        }
        const len = varint(d, &p) orelse return null;
        if (p + len > d.len) return null;
        it.at = p + len;
        return .{ .kind = kind, .bytes = d[start..it.at] };
    }
};

fn request(conn: *client.ClientConnection, method: []const u8, path: []const u8, options: client.ClientConnection.RequestOptions) !*client.Stream {
    return conn.request(&.{
        .{ .name = ":method", .value = method },  .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, options);
}

/// The response body, which must come with a 200.
fn finish(s: *client.Stream, gpa: std.mem.Allocator) ![]u8 {
    defer s.release();
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    return s.reader().allocRemaining(gpa, .unlimited);
}

fn hasTicket(cache: *client.SessionCache) bool {
    return cache.count() > 0;
}

fn noConnections(ep: *Endpoint) bool {
    ep.map_mutex.lockUncancelable(ep.io);
    defer ep.map_mutex.unlock(ep.io);
    return ep.conns.count() == 0;
}

/// The server's closed connections are gone: each one's closing or
/// draining period is cut short as it enters it (`testExpirePeriods`), so
/// this waits for the server to see the close, not for three PTOs.
fn connectionsGone(ep: *Endpoint) bool {
    ep.testExpirePeriods();
    return noConnections(ep);
}

test "h3: resumption and 0-RTT; early GET runs at once, early POST waits, a replayed POST never runs" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .early_data = true });
    defer f.stop(gpa, io);
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();

    // A first connection: a full handshake, and a ticket.
    {
        const conn = try f.connectResuming(gpa, io, &cache, true, relay);
        defer conn.close();
        try std.testing.expect(!conn.resumed());
        try std.testing.expectEqual(client.EarlyData.none, conn.earlyData());
        const b = try finish(try request(conn, "GET", "/early", .{}), gpa);
        defer gpa.free(b);
        try std.testing.expectEqualStrings("late", b);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }

    // The second: resumed, its requests in 0-RTT. The relay holds the
    // server's answer until the server has run the GET and held the POST,
    // so both went in 0-RTT (the client had no handshake keys) and were
    // handled before the handshake completed; they are in the recorded
    // first flight, which the replay below sends again.
    const posts = early_posts.load(.monotonic);
    relay.armGated();
    {
        const conn = try f.connectResuming(gpa, io, &cache, true, relay);
        defer conn.close();
        try std.testing.expectEqual(client.EarlyData.pending, conn.earlyData());
        const get_early = try request(conn, "GET", "/early", .{});
        const post_early = try request(conn, "POST", "/early-post", .{ .early = true });
        try relay.openDownWhenEarly(io, f.ep, 1, 1);
        const g = try finish(get_early, gpa);
        defer gpa.free(g);
        const p = try finish(post_early, gpa);
        defer gpa.free(p);
        // The GET ran from early data, and says so; the POST waited for
        // the handshake, after which it is no replay.
        try std.testing.expectEqualStrings("early", g);
        try std.testing.expectEqualStrings("late", p);
        try std.testing.expectEqual(client.EarlyData.accepted, conn.earlyData());
        try std.testing.expect(conn.resumed());
        try std.testing.expectEqual(posts + 1, early_posts.load(.monotonic));
        try std.testing.expectEqual(@as(u64, 1), f.ep.early_served.load(.monotonic));
        try std.testing.expectEqual(@as(u64, 1), f.ep.early_held.load(.monotonic));
        relay.disarm();
    }

    // An attacker replays that flight once the connection is gone: the
    // server takes the 0-RTT again (nothing in TLS stops it), runs the GET
    // and holds the POST for a handshake that never completes.
    try wait.waitUntil(io, "connectionsGone", f.ep, connectionsGone);
    try relay.replay();
    const Held = struct {
        fn two(ep: *Endpoint) bool {
            return ep.early_held.load(.monotonic) == 2;
        }
    };
    try wait.waitUntil(io, "Held.two", f.ep, Held.two);
    // The POST never runs: its handshake never completes.
    const Unrun = struct {
        posts: u32,
        fn cond(c: @This()) bool {
            return early_posts.load(.monotonic) == c.posts;
        }
    };
    try wait.expectStays(io, "the replayed POST is not run", Unrun{ .posts = posts + 1 }, Unrun.cond, .fromMilliseconds(300));
    try std.testing.expectEqual(posts + 1, early_posts.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), f.ep.early_served.load(.monotonic));
}

test "h3: a new connection given up after its first packet started a 0-RTT request is freed safely" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .early_data = true });
    defer f.stop(gpa, io);
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();
    {
        const conn = try f.connectResuming(gpa, io, &cache, true, relay);
        defer conn.close();
        const b = try finish(try request(conn, "GET", "/early", .{}), gpa);
        defer gpa.free(b);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }
    // A resumed connection whose first flight carries a request that
    // waits (a POST held for the handshake): recorded. The server's answer
    // waits until the server holds the POST, so the request went in 0-RTT
    // and is in the first flight.
    relay.armGated();
    {
        const conn = try f.connectResuming(gpa, io, &cache, true, relay);
        defer conn.close();
        const post_early = try request(conn, "POST", "/early-post", .{ .early = true });
        try relay.openDownWhenEarly(io, f.ep, 0, 1);
        const p = try finish(post_early, gpa);
        gpa.free(p);
        relay.disarm();
    }
    try wait.waitUntil(io, "connectionsGone", f.ep, connectionsGone);
    // The same flight again, and the server gives the new connection up
    // right after reading its first packet.
    f.ep.test_fail_accept = true;
    try relay.replayCoalesced();
    // It did start a request before it was given up (its first packet
    // carries the request; a busy machine may take a while over it).
    const GivenUp = struct {
        fn once(ep: *Endpoint) bool {
            return ep.test_given_up_with_tasks.load(.acquire) == 1;
        }
    };
    try wait.waitUntil(io, "GivenUp.once", f.ep, GivenUp.once);
    try std.testing.expect(!f.ep.test_fail_accept);
    // The endpoint still serves.
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3: 0-RTT carries on across a certificate reload" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .early_data = true });
    defer f.stop(gpa, io);
    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();
    {
        const conn = try f.connectResuming(gpa, io, &cache, true, null);
        defer conn.close();
        const b = try finish(try request(conn, "GET", "/hello", .{}), gpa);
        gpa.free(b);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }
    // A new TLS context (the same certificate, so the client still trusts
    // it): the ticket keys carry over, and 0-RTT with them.
    f.ep.useTls(try f.ep.loadTls(f.pem.cert, f.pem.key, null));
    const conn = try f.connectResuming(gpa, io, &cache, true, null);
    defer conn.close();
    try std.testing.expectEqual(client.EarlyData.pending, conn.earlyData());
    const b = try finish(try request(conn, "GET", "/hello", .{}), gpa);
    gpa.free(b);
    try std.testing.expectEqual(client.EarlyData.accepted, conn.earlyData());
    try std.testing.expect(conn.resumed());
}

test "h3: 0-RTT the server refuses goes again after the handshake" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest; // hands the UDP socket over by fd (dup), which is Unix only
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var old = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .early_data = true });
    var old_stopped = false;
    defer if (!old_stopped) old.stop(gpa, io);
    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();
    {
        const conn = try old.connectResuming(gpa, io, &cache, true, null);
        defer conn.close();
        const b = try finish(try request(conn, "GET", "/hello", .{}), gpa);
        gpa.free(b);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }

    // The same address and certificate, but a new process's ticket keys:
    // the ticket does not open, so no resumption and no 0-RTT.
    const fd = std.c.dup(old.ep.udp.socket.handle);
    try std.testing.expect(fd >= 0);
    const pem_copy: anole_tls.Pem = .{ .cert = try gpa.dupe(u8, old.pem.cert), .key = try gpa.dupe(u8, old.pem.key) };
    old.stop(gpa, io);
    old_stopped = true;
    var new = try Fixture.startWithPem(gpa, io, .{ .listeners = &.{} }, .{ .fd = fd, .early_data = true }, pem_copy);
    defer new.stop(gpa, io);

    const conn = try new.connectResuming(gpa, io, &cache, true, null);
    defer conn.close();
    try std.testing.expectEqual(client.EarlyData.pending, conn.earlyData());
    const g = try request(conn, "GET", "/early", .{});
    // A body too, which must go again from its start.
    const e = try request(conn, "POST", "/echo", .{ .body = true, .early = true });
    try e.writer().writeAll("sent early, and again");
    try e.closeSend();
    const gb = try finish(g, gpa);
    defer gpa.free(gb);
    const eb = try finish(e, gpa);
    defer gpa.free(eb);
    try std.testing.expectEqualStrings("late", gb);
    try std.testing.expectEqualStrings("sent early, and again", eb);
    try std.testing.expectEqual(client.EarlyData.rejected, conn.earlyData());
    try std.testing.expect(!conn.resumed());
    try std.testing.expectEqual(@as(u64, 0), new.ep.early_served.load(.monotonic));
}

test "h3: a client offering QUIC v2 moves to it only when the server prefers v2" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const v1: u32 = 1;
    const v2: u32 = 0x6b3343cf;
    // The interop runner's v2 case wants v2, every other case v1, from
    // clients (aioquic) that offer both every time.
    for ([_]bool{ true, false }) |prefer_v2| {
        var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .prefer_v2 = prefer_v2 });
        defer f.stop(gpa, io);
        for ([_]bool{ true, false }) |offer_v2| {
            const conn = try client.ClientConnection.connect(gpa, io, .{
                .host = "localhost",
                .address = f.ep.address(),
                .port = f.ep.address().getPort(),
                .tls = .{ .ca = .{ .pem = f.pem.cert } },
                .quic_v2 = offer_v2,
            });
            defer conn.close();
            const body = try finish(try request(conn, "GET", "/hello", .{}), gpa);
            defer gpa.free(body);
            try std.testing.expectEqualStrings("hello over h3", body);
            try std.testing.expectEqual(if (prefer_v2 and offer_v2) v2 else v1, conn.quicVersion());
        }
    }
}

test "h3 server: a ClientHello resent before the client acted on our Retry gets a Retry again, not a second connection" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    // The ClientHello (with its post-quantum key share) spans two
    // Initials; the first is lost, so the server sees a later piece first
    // and answers with a Retry. That Retry is held up past the client's
    // PTO, so the client resends its whole ClientHello, still without a
    // token, before it acts on the Retry: the runner's handshakecorruption
    // case with neqo, whose first Initial leads with a later piece.
    relay.mutex.lockUncancelable(io);
    relay.drop_up = 1;
    relay.hold_down_ms = 1500;
    relay.mutex.unlock(io);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = relay.front.socket.address,
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
    });
    defer conn.close();
    const body = try finish(try request(conn, "GET", "/hello", .{}), gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
    // A Retry for the piece and one for the resent ClientHello; one
    // connection, the one the client's token led to.
    try std.testing.expect(f.ep.stats.retries.load(.monotonic) >= 2);
    try std.testing.expectEqual(@as(u64, 1), f.ep.stats.accepted.load(.monotonic));
    // The console's gauge: the one connection, still open.
    try std.testing.expectEqual(@as(u64, 1), f.ep.stats.connections_open.load(.monotonic));
}

test "h3 server: a NAT rebinding during the handshake: the server follows the client to its new port" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const relay = try Relay.start(gpa, io, f.ep.address());
    defer relay.stop();
    // The client's first flight leaves from one port; the NAT rebinds as
    // the server answers, so that answer is lost and the client's
    // retransmission comes from another: the interop runner's rebind-port
    // case when the first rebind falls inside the handshake. Before the
    // xuckless/ngtcp2 patch the server ignored the new port until the
    // handshake timed out.
    relay.mutex.lockUncancelable(io);
    relay.rebind_on_answer = true;
    relay.mutex.unlock(io);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = relay.front.socket.address,
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
    });
    defer conn.close();
    const body = try finish(try request(conn, "GET", "/hello", .{}), gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
    try std.testing.expectEqual(@as(u64, 1), f.ep.stats.accepted.load(.monotonic));
    const p = try finish(try request(conn, "GET", "/port", .{}), gpa);
    defer gpa.free(p);
    var port_text: [8]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&port_text, "{d}", .{relay.back2.socket.address.getPort()}), p);
}

test "h3: a client that moves to a new port keeps its connection, and the server follows" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    // Every pair of moves, back to back: a migration right after a NAT
    // rebinding needs the xuckless/ngtcp2 fix, without which the server
    // retired the connection ID it kept as the fallback and closed with
    // CONNECTION_ID_LIMIT_ERROR.
    for ([_]client.Rebind{ .migrate, .nat, .migrate, .migrate, .nat, .nat }) |how| {
        const before = conn.udp.socket.address.getPort();
        // A download in flight across the move.
        const d = try request(conn, "GET", "/download?n=2000000", .{});
        try d.waitHead();
        var some: [1000]u8 = undefined;
        try d.reader().readSliceAll(&some);
        try conn.rebind(how);
        const after = conn.udp.socket.address.getPort();
        try std.testing.expect(after != before);
        const rest = try finish(d, gpa);
        defer gpa.free(rest);
        try std.testing.expectEqual(@as(usize, 2000000 - some.len), rest.len);
        // Requests see where the client is now.
        const p = try finish(try request(conn, "GET", "/port", .{}), gpa);
        defer gpa.free(p);
        try std.testing.expectEqual(after, try std.fmt.parseInt(u16, p, 10));
    }
}

test "h3 client: a response head past max_header_list_size fails the stream, and the connection carries on" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try client.ClientConnection.connect(gpa, io, .{
        .host = "localhost",
        .address = f.ep.address(),
        .port = f.ep.address().getPort(),
        .tls = .{ .ca = .{ .pem = f.pem.cert } },
        .max_header_list_size = 4096,
    });
    defer conn.close();
    {
        const s = try request(conn, "GET", "/big-head", .{});
        defer s.release();
        try std.testing.expectError(error.HeadersTooLarge, s.waitHead());
    }
    const body = try get(conn, "/hello", gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello over h3", body);
}

test "h3 server: a reload that changes the client CAs stops earlier sessions from resuming" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.startWith(gpa, io, .{ .listeners = &.{} }, .{ .client_auth = .request });
    defer f.stop(gpa, io);
    var cache: client.SessionCache = .init(gpa, io);
    defer cache.deinit();
    var other = try anole_tls.selfSigned(gpa, .{});
    defer other.deinit(gpa);
    var other_bundle = try @import("../tls/testing.zig").bundleFromPem(gpa, std.Io.Clock.real.now(io).toSeconds(), other.cert);
    defer other_bundle.deinit(gpa);

    const Connect = struct {
        fn run(fx: *Fixture, gpa_: std.mem.Allocator, io_: std.Io, cache_: *client.SessionCache) !*client.ClientConnection {
            return client.ClientConnection.connect(gpa_, io_, .{
                .host = "localhost",
                .address = fx.ep.address(),
                .port = fx.ep.address().getPort(),
                .tls = .{ .ca = .{ .pem = fx.pem.cert }, .client_certificate = .{ .pem = .{ .cert = fx.pem.cert, .key = fx.pem.key } } },
                .session_cache = cache_,
                .connect_timeout = .fromSeconds(3),
            });
        }
    };
    {
        const conn = try Connect.run(&f, gpa, io, &cache);
        defer conn.close();
        const body = try get(conn, "/peer", gpa);
        gpa.free(body);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }
    // The same client CAs: the session resumes.
    f.ep.useTls(try f.ep.loadTls(f.pem.cert, f.pem.key, .{ .ca_der = f.bundle.bytes.items, .mode = .request }));
    {
        const conn = try Connect.run(&f, gpa, io, &cache);
        defer conn.close();
        try std.testing.expect(conn.resumed());
        const body = try get(conn, "/peer", gpa);
        gpa.free(body);
        try wait.waitUntil(io, "hasTicket", &cache, hasTicket);
    }
    // Other client CAs, which do not cover the client's certificate.
    f.ep.useTls(try f.ep.loadTls(f.pem.cert, f.pem.key, .{ .ca_der = other_bundle.bytes.items, .mode = .request }));
    if (Connect.run(&f, gpa, io, &cache)) |conn| {
        defer conn.close();
        try std.testing.expect(!conn.resumed());
        if (get(conn, "/peer", gpa)) |body| {
            gpa.free(body);
            return error.ServedAfterTheClientCasChanged;
        } else |_| {}
    } else |_| {}
}

test "h3 server: a response streamed past its send buffer completes and leaves no blocks" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    // 4 MiB through a 64 KiB per-stream queue and a 4 MiB connection budget.
    const body = try get(conn, "/download?n=4194304", gpa);
    defer gpa.free(body);
    try std.testing.expectEqual(@as(usize, 4 << 20), body.len);
    // Once the request is over and acknowledged, the stream holds nothing
    // but the one block it keeps in the stream pool for its next response.
    try wait.waitUntil(io, "the stream keeps one block at most", f.ep, struct {
        fn cond(ep: *Endpoint) bool {
            ep.sampleStats();
            return ep.stats.blocks_live.load(.monotonic) <= 1;
        }
    }.cond);
}

test "h3 client: unprocessed is true after H3_REQUEST_REJECTED and for a request the GOAWAY did not reach" {
    const h = @import("anole_nghttp3_c");
    var conn: client.ClientConnection = undefined;
    var s: client.Stream = undefined;
    s.conn = &conn;
    s.id = 4;
    s.status = 0;
    s.reset_code = null;
    conn.goaway_id = std.math.maxInt(i64);
    // Nothing happened to it.
    try std.testing.expect(!s.unprocessed());
    // Rejected by the server (RFC 9114 H3_REQUEST_REJECTED).
    s.reset_code = h.NGHTTP3_H3_REQUEST_REJECTED;
    try std.testing.expect(s.unprocessed());
    // Another error code is not "unprocessed".
    s.reset_code = h.NGHTTP3_H3_REQUEST_CANCELLED;
    try std.testing.expect(!s.unprocessed());
    s.reset_code = null;
    // GOAWAY(8): streams at or above 8 were not processed, those below were
    // (unless they have no head, below it they carry on).
    conn.goaway_id = 8;
    s.id = 4;
    try std.testing.expect(!s.unprocessed());
    s.id = 8;
    try std.testing.expect(s.unprocessed());
    s.id = 12;
    try std.testing.expect(s.unprocessed());
    // A request that already has its answer ran.
    s.status = 200;
    try std.testing.expect(!s.unprocessed());
}

test "h3 client: resetCode reports the server's RESET_STREAM code" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/abort" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    s.waitHead() catch {};
    _ = s.reader().allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed, error.OutOfMemory, error.StreamTooLong => {},
    };
    try std.testing.expectEqual(@as(?u64, @import("nghttp3.zig").c.NGHTTP3_H3_REQUEST_CANCELLED), s.resetCode());
}

test "h3 client: send_buffer = 1 MiB queues a 1 MiB body before the server reads it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    gate = .unset;
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = "/gated" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{ .body = true, .send_buffer = 1 << 20 });
    defer s.release();
    const body = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 7);
    try s.writer().writeAll(body);
    try s.writer().flush();
    gate.set(io);
    try s.closeSend();
    try s.waitHead();
    const echoed = try s.reader().allocRemaining(gpa, .unlimited);
    defer gpa.free(echoed);
    try std.testing.expectEqualSlices(u8, body, echoed);
}

test "h3 server: an answer before the request body ends lets the client finish sending it; past 256 KiB more it is stopped" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const head: []const client.Header = &.{
        .{ .name = ":method", .value = "POST" },  .{ .name = ":path", .value = "/answer-first" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    };
    var chunk: [4096]u8 = @splat('x');
    // Within the bound: the rest of the body is read and dropped, and the
    // client ends its stream normally. A STOP_SENDING here raced a client
    // still sending (.NET's HTTP/3 client failed whole gRPC calls on it).
    {
        const s = try conn.request(head, .{ .body = true, .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } });
        defer s.release();
        try s.writer().writeAll(&chunk);
        try s.writer().flush();
        try s.waitHead();
        const got = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try std.testing.expectEqualStrings("first", got);
        for (0..16) |_| try s.writer().writeAll(&chunk);
        try s.closeSend();
        try std.testing.expectEqual(@as(?client.StreamError, null), s.writeError());
    }
    // Past it: the server asks the client to stop (STOP_SENDING).
    {
        const s = try conn.request(head, .{ .body = true, .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } } });
        defer s.release();
        try s.writer().writeAll(&chunk);
        try s.writer().flush();
        try s.waitHead();
        const got = try s.reader().allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        var sent: usize = 0;
        while (sent < 4 << 20) : (sent += chunk.len) {
            s.writer().writeAll(&chunk) catch break;
            s.writer().flush() catch break;
        }
        try std.testing.expect(sent < 4 << 20);
        try std.testing.expectEqual(@as(?client.StreamError, error.StreamReset), s.writeError());
    }
}

fn keepAliveOn(conn: *client.ClientConnection) bool {
    return conn.keepAliveArmed();
}

test "h3 client: keep-alive is armed while a request is open and disarmed after" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    wait_started = .unset;
    wait_canceled = .unset;
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    try std.testing.expect(!keepAliveOn(conn));
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/wait" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    try wait_started.wait(io);
    try std.testing.expect(keepAliveOn(conn));
    // The server arms its side the same way.
    try std.testing.expect(f.ep.stats.keep_alive_arms.load(.monotonic) >= 1);
    s.release();
    // The stream is freed once QUIC has closed it; then it disarms.
    try wait.waitUntil(io, "the client's keep-alive disarmed", conn, struct {
        fn off(cn: *client.ClientConnection) bool {
            return !keepAliveOn(cn);
        }
    }.off);
}

test "h3 server: a peer RESET_STREAM cancels a REST handler's wait" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    wait_started = .unset;
    wait_canceled = .unset;
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    const conn = try f.connect(gpa, io);
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/wait" },
        .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
    }, .{});
    defer s.release();
    try wait_started.wait(io);
    s.cancel();
    try wait_canceled.wait(io);
}

/// A parked response (`Response._park`, design-realtime §3.4): the handler
/// returns, and bursts from a task on the request's executor write to the
/// stream.
const H3Park = struct {
    var parked: ?*dusty.Parked = null;
    var exec: usize = 0;
    var io_: std.Io = undefined;
    var opened: std.Io.Event = .unset;
    var gone: std.Io.Event = .unset;
    var gone_calls: std.atomic.Value(u32) = .init(0);
    var dummy: u8 = 0;

    fn reset() void {
        parked = null;
        opened = .unset;
        gone = .unset;
        gone_calls.store(0, .monotonic);
    }

    fn onGone(_: *anyopaque) void {
        _ = gone_calls.fetchAdd(1, .monotonic);
        gone.set(io_);
    }

    fn park(req: *dusty.Request, res: *dusty.Response) !void {
        try res.header("Content-Type", "text/event-stream");
        io_ = req.io;
        exec = dusty.placement.currentExecutor(req.io) orelse 0;
        parked = try res._park(req, .{ .gone = onGone, .ctx = &dummy });
        opened.set(req.io);
    }

    /// Waits first, as a handler that talks to a database before it parks:
    /// on its own task.
    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        try req.io.sleep(.fromMilliseconds(1), .awake);
        return park(req, res);
    }

    const Op = union(enum) {
        burst: struct { parts: []const []const u8, end: bool },
        begin_fails,
        release,
    };

    fn opTask(op: Op, result: *anyerror!void) std.Io.Cancelable!void {
        const p = parked.?;
        result.* = switch (op) {
            .burst => |b| blk: {
                if (!p.begin()) break :blk error.NoBurst;
                p.write(b.parts) catch |err| {
                    p.endBurst();
                    break :blk err;
                };
                if (b.end) p.end() else p.endBurst();
                break :blk {};
            },
            .begin_fails => if (p.begin()) blk: {
                p.endBurst();
                break :blk error.BurstStarted;
            } else {},
            .release => p.release(),
        };
    }

    /// Runs `op` on the request's executor and waits for it.
    fn on(io: std.Io, op: Op) !void {
        var group: std.Io.Group = .init;
        var result: anyerror!void = {};
        try dusty.placement.concurrent(&group, io, .{ .executor = exec }, opTask, .{ op, &result });
        try group.await(io);
        return result;
    }
};

/// Request streams the server still holds, on its one connection.
fn serverStreams(ep: *Endpoint) usize {
    ep.map_mutex.lockUncancelable(ep.io);
    defer ep.map_mutex.unlock(ep.io);
    var it = ep.conns.valueIterator();
    const conn = (it.next() orelse return 0).*;
    conn.mutex.lockUncancelable(ep.io);
    defer conn.mutex.unlock(ep.io);
    return conn.streams.count();
}

fn noServerStreams(ep: *Endpoint) bool {
    return serverStreams(ep) == 0;
}

test "parked h3: a handler that waited first parks; bursts arrive; end finishes the stream and release frees it" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    H3Park.reset();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    f.http.router.get("/live", H3Park.handle);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const s = try request(conn, "GET", "/live", .{});
    try H3Park.opened.wait(io);
    try H3Park.on(io, .{ .burst = .{ .parts = &.{ "id: 1\n", "data: a\n\n" }, .end = false } });
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    try H3Park.on(io, .{ .burst = .{ .parts = &.{"data: b\n\n"}, .end = true } });
    const body = try finish(s, gpa);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("id: 1\ndata: a\n\ndata: b\n\n", body);
    try H3Park.on(io, .begin_fails);
    try H3Park.on(io, .release);
    try std.testing.expectEqual(@as(u32, 0), H3Park.gone_calls.load(.monotonic));

    // The stream is freed, and the connection carries on.
    const hello_body = try get(conn, "/hello", gpa);
    defer gpa.free(hello_body);
    try std.testing.expectEqualStrings("hello over h3", hello_body);
    try wait.waitUntil(io, "noServerStreams", f.ep, noServerStreams);
}

test "parked h3: a stream reset tells the owner once; release frees the stream" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    H3Park.reset();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    f.http.router.get("/live", H3Park.handle);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const s = try request(conn, "GET", "/live", .{});
    try H3Park.opened.wait(io);
    try H3Park.on(io, .{ .burst = .{ .parts = &.{"data: a\n\n"}, .end = false } });
    try s.waitHead();
    s.cancel();
    s.release();
    try H3Park.gone.wait(io);
    try std.testing.expectEqual(@as(u32, 1), H3Park.gone_calls.load(.monotonic));
    try H3Park.on(io, .begin_fails);
    try H3Park.on(io, .release);

    const hello_body = try get(conn, "/hello", gpa);
    defer gpa.free(hello_body);
    try std.testing.expectEqualStrings("hello over h3", hello_body);
    try wait.waitUntil(io, "noServerStreams", f.ep, noServerStreams);
    try std.testing.expectEqual(@as(u32, 1), H3Park.gone_calls.load(.monotonic));
}

test "parked h3: a no_wait route parks on the endpoint task; the connection closing tells the owner, and its end waits for release" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    H3Park.reset();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    f.http.router.addRouteWith(.get, "/nw/live", H3Park.park, .{ .no_wait = true });
    const conn = try f.connect(gpa, io);

    const s = try request(conn, "GET", "/nw/live", .{});
    try H3Park.opened.wait(io);
    try H3Park.on(io, .{ .burst = .{ .parts = &.{"data: a\n\n"}, .end = false } });
    try s.waitHead();
    try std.testing.expectEqual(@as(u16, 200), s.status);
    s.release();
    conn.close();
    try H3Park.gone.wait(io);
    try std.testing.expectEqual(@as(u32, 1), H3Park.gone_calls.load(.monotonic));
    // The connection is not freed before the owner lets go.
    try std.testing.expect(!noConnections(f.ep));
    try H3Park.on(io, .begin_fails);
    try H3Park.on(io, .release);
    try wait.waitUntil(io, "noConnections", f.ep, noConnections);
}

/// A park that fails inside the handler (the peer reset the stream first):
/// the park finishes the exchange, the handler returns the error, and the
/// stream is let go exactly once, by `serve`'s caller. On the request's
/// task, which waits for the reset through the body reader.
const FailedPark = struct {
    var result: ?anyerror = null;
    var started: std.Io.Event = .unset;
    var done: std.Io.Event = .unset;

    fn reset() void {
        result = null;
        started = .unset;
        done = .unset;
    }

    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        const io = req.io;
        H3Park.io_ = io;
        started.set(io);
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        // The body never comes: the read ends with the reset, so the park
        // meets a reset stream.
        var buf: [1]u8 = undefined;
        _ = req._body_source.?.reader.readSliceShort(&buf) catch {};
        try res.header("Content-Type", "text/event-stream");
        const p = res._park(req, .{ .gone = H3Park.onGone, .ctx = &H3Park.dummy }) catch |err| {
            result = err;
            done.set(io);
            return err;
        };
        p.release();
        result = null;
        done.set(io);
    }

    fn isDone(_: void) bool {
        return done.isSet();
    }
};

test "parked h3: a park that fails on a reset stream lets go of the stream once" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    H3Park.reset();
    FailedPark.reset();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    f.http.router.post("/live", FailedPark.handle);
    const conn = try f.connect(gpa, io);
    defer conn.close();

    const s = try request(conn, "POST", "/live", .{ .body = true });
    try FailedPark.started.wait(io);
    s.cancel();
    s.release();
    try wait.waitUntil(io, "FailedPark.isDone", {}, FailedPark.isDone);
    try std.testing.expectEqual(@as(?anyerror, error.WriteFailed), FailedPark.result);

    // The connection serves on (a double release would have broken its
    // stream count), and the stream is freed once.
    const hello_body = try get(conn, "/hello", gpa);
    defer gpa.free(hello_body);
    try std.testing.expectEqualStrings("hello over h3", hello_body);
    try wait.waitUntil(io, "noServerStreams", f.ep, noServerStreams);
    try std.testing.expectEqual(@as(u32, 0), H3Park.gone_calls.load(.monotonic));
}

/// A `no_wait` handler (on the endpoint task) that parks, then sends,
/// ends and releases the park before it returns: the stream is let go
/// once, by `serve`'s caller, after the handler.
fn parkEndRelease(req: *dusty.Request, res: *dusty.Response) !void {
    try res.header("Content-Type", "text/event-stream");
    H3Park.io_ = req.io;
    const p = try res._park(req, .{ .gone = H3Park.onGone, .ctx = &H3Park.dummy });
    if (!p.begin()) {
        p.release();
        return error.NoBurst;
    }
    p.write(&.{"data: x\n\n"}) catch |err| {
        p.abort();
        p.release();
        return err;
    };
    p.end();
    p.release();
}

test "parked h3: a no_wait handler that ends and releases its park before it returns lets go of the stream once" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    H3Park.reset();
    var f = try Fixture.start(gpa, io);
    defer f.stop(gpa, io);
    f.http.router.addRouteWith(.get, "/nw/once", parkEndRelease, .{ .no_wait = true });
    const conn = try f.connect(gpa, io);
    defer conn.close();

    for (0..3) |_| {
        const s = try request(conn, "GET", "/nw/once", .{});
        const body = try finish(s, gpa);
        defer gpa.free(body);
        try std.testing.expectEqualStrings("data: x\n\n", body);
    }
    const hello_body = try get(conn, "/hello", gpa);
    defer gpa.free(hello_body);
    try std.testing.expectEqualStrings("hello over h3", hello_body);
    try wait.waitUntil(io, "noServerStreams", f.ep, noServerStreams);
    try std.testing.expectEqual(@as(u32, 0), H3Park.gone_calls.load(.monotonic));
}
