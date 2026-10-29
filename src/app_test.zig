//! The short forms on `anole.App` / `anole.Server`: `listen`, `listenTls`,
//! handlers of either shape, function middleware and `with`, `ws`,
//! `staticDir`, `metrics`, `health`, `grpc`, `grpcHealth`, `tracing` and the
//! server's client, each over a real socket.
const std = @import("std");
const features = @import("build_options");
const http = @import("http/root.zig");
const server_mod = @import("server.zig");
const client_mod = @import("client.zig");
const handlers = @import("handlers.zig");
const websocket = if (features.websocket) @import("websocket/root.zig") else struct {
    pub const Socket = void;
};
const grpc = if (features.grpc) @import("grpc/root.zig") else struct {};
const h3 = if (features.http3) @import("h3/root.zig") else struct {};
const h2 = if (features.http2) @import("h2/root.zig") else struct {};

const App = server_mod.App;
const Server = server_mod.Server;
const Request = http.Request;
const Response = http.Response;
const alloc = std.testing.allocator;

/// `GET url` through the server's client: the status, and the body in
/// `arena`.
fn get(io: std.Io, arena: std.mem.Allocator, url: []const u8, headers: []const client_mod.Header) !struct { status: http.Status, body: []const u8, stamp: ?[]const u8 } {
    var resp = try client_mod.client(io).fetch(url, .{ .headers = headers });
    defer resp.deinit();
    return .{
        .status = resp.status(),
        .body = try arena.dupe(u8, try resp.body()),
        .stamp = if (resp.header("X-Stamp")) |v| try arena.dupe(u8, v) else null,
    };
}

fn post(io: std.Io, arena: std.mem.Allocator, url: []const u8, content_type: []const u8, body: []const u8) ![]const u8 {
    var resp = try client_mod.client(io).fetch(url, .{ .method = .post, .headers = &.{.{ "Content-Type", content_type }}, .body = body });
    defer resp.deinit();
    if (resp.status() != .ok) return error.UnexpectedStatus;
    return arena.dupe(u8, try resp.body());
}

/// The port the App test's server listens on, for its handler that calls
/// back into it.
var app_port: std.atomic.Value(u16) = .init(0);

const AppRoutes = struct {
    fn stamp(_: *Request, res: *Response, next: handlers.Next) !void {
        try res.header("X-Stamp", "fn-middleware");
        return next.call();
    }

    fn requireKey(req: *Request, res: *Response, next: handlers.Next) !void {
        if (req.headers.get("X-Api-Key") == null) return res.fail(.unauthorized, "no key");
        return next.call();
    }

    fn hello(_: *Request, res: *Response) !void {
        res.body = "hello";
    }

    fn secret(_: *Request, res: *Response) !void {
        res.body = "secret";
    }

    /// Calls `/hello` on this same server through `anole.client(req)`.
    fn via(req: *Request, res: *Response) !void {
        const url = try std.fmt.allocPrint(req.arena, "http://127.0.0.1:{d}/hello", .{app_port.load(.acquire)});
        var upstream = try client_mod.client(req).fetch(url, .{});
        defer upstream.deinit();
        res.body = try std.fmt.allocPrint(res.arena, "via: {s}", .{try upstream.body()});
    }

    fn echo(ws: *websocket.Socket, _: *Request) !void {
        while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
    }

    var spans_seen: std.Io.Event = .unset;

    fn collect(req: *Request, res: *Response) !void {
        const body = (try req.body()) orelse "";
        if (std.mem.indexOf(u8, body, "\"spans\"") != null) spans_seen.set(req.io);
        res.body = "{}";
    }
};

fn urlOf(arena: std.mem.Allocator, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ port, path });
}

/// Listens on 127.0.0.1:0 and runs `check` against the server from a task
/// on its runtime; the server stops when `check` returns.
fn listenAndCheck(app: *App, comptime check: anytype) !void {
    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            try check(io_, arena_state.allocator(), a.addresses()[0].ip.getPort());
        }
    };
    var checking = try app.io().concurrent(Check.run, .{app});
    defer checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "anole.App: function middleware runs on every route, with() adds one to a single route, and a handler calls the server through anole.client" {
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.use(AppRoutes.stamp);
    app.get("/hello", AppRoutes.hello);
    app.get("/via", AppRoutes.via);
    app.with(.{AppRoutes.requireKey}).get("/secret", AppRoutes.secret);

    try listenAndCheck(&app, struct {
        fn check(io_: std.Io, arena: std.mem.Allocator, port: u16) !void {
            app_port.store(port, .release);
            const hello = try get(io_, arena, try urlOf(arena, port, "/hello"), &.{});
            try std.testing.expectEqualStrings("hello", hello.body);
            try std.testing.expectEqualStrings("fn-middleware", hello.stamp.?);

            const via = try get(io_, arena, try urlOf(arena, port, "/via"), &.{});
            try std.testing.expectEqualStrings("via: hello", via.body);

            // `with`: this route alone is behind the key check.
            const refused = try get(io_, arena, try urlOf(arena, port, "/secret"), &.{});
            try std.testing.expectEqual(http.Status.unauthorized, refused.status);
            try std.testing.expectEqualStrings("fn-middleware", refused.stamp.?);
            const allowed = try get(io_, arena, try urlOf(arena, port, "/secret"), &.{.{ "X-Api-Key", "k" }});
            try std.testing.expectEqualStrings("secret", allowed.body);
        }
    }.check);
}

test "anole.App: staticDir serves files, health answers /healthz and /readyz, and metrics counts requests per route" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.txt", .data = "static page" });
    const files = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(files);

    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    const registry = app.metrics(.{});
    try std.testing.expectEqual(registry, app.metrics(.{}));
    app.get("/hello", AppRoutes.hello);
    try app.staticDir("/files", files, .{});
    _ = app.health(.{});

    try listenAndCheck(&app, struct {
        fn check(io_: std.Io, arena: std.mem.Allocator, port: u16) !void {
            try std.testing.expectEqualStrings("static page", (try get(io_, arena, try urlOf(arena, port, "/files/page.txt"), &.{})).body);
            try std.testing.expectEqualStrings("ok\n", (try get(io_, arena, try urlOf(arena, port, "/healthz"), &.{})).body);
            try std.testing.expectEqualStrings("ok\n", (try get(io_, arena, try urlOf(arena, port, "/readyz"), &.{})).body);
            for (0..2) |_| try std.testing.expectEqualStrings("hello", (try get(io_, arena, try urlOf(arena, port, "/hello"), &.{})).body);
            const scraped = (try get(io_, arena, try urlOf(arena, port, "/metrics"), &.{})).body;
            try std.testing.expect(std.mem.indexOf(u8, scraped, "anole_http_requests_total{method=\"GET\",route=\"/hello\",status=\"200\"} 2") != null);
        }
    }.check);
}

test "anole.App: ws answers a plain GET with 426 and echoes over a WebSocket" {
    if (comptime !features.websocket) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.ws("/echo", AppRoutes.echo);

    try listenAndCheck(&app, struct {
        fn check(io_: std.Io, arena: std.mem.Allocator, port: u16) !void {
            const plain = try get(io_, arena, try urlOf(arena, port, "/echo"), &.{});
            try std.testing.expectEqual(http.Status.upgrade_required, plain.status);
            var dc = http.Client.init(alloc, io_, .{});
            defer dc.deinit();
            var ws = try dc.connectWebSocket(try std.fmt.allocPrint(arena, "ws://127.0.0.1:{d}/echo", .{port}), .{});
            defer ws.deinit();
            try ws.send(.text, "ping me back");
            try std.testing.expectEqualStrings("ping me back", (try ws.receive()).data);
            try ws.close(.normal, "");
            const answer = try ws.receive();
            try std.testing.expectEqual(http.core.WebSocket.MessageType.close, answer.type);
        }
    }.check);
}

test "anole.App: grpcHealth answers grpc.health.v1 Check over Connect's unary JSON, per service and whole" {
    if (comptime !features.grpc) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    try app.grpcHealth().set("app.Svc", .NOT_SERVING);

    try listenAndCheck(&app, struct {
        fn check(io_: std.Io, arena: std.mem.Allocator, port: u16) !void {
            const check_url = try urlOf(arena, port, "/grpc.health.v1.Health/Check");
            try std.testing.expectEqualStrings("{\"status\":\"NOT_SERVING\"}", try post(io_, arena, check_url, "application/json", "{\"service\":\"app.Svc\"}"));
            try std.testing.expectEqualStrings("{\"status\":\"SERVING\"}", try post(io_, arena, check_url, "application/json", "{}"));
        }
    }.check);
}

test "anole.App: tracing exports the spans of served requests to an OTLP collector" {
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    const io = app.io();

    // An OTLP collector beside the server, on its runtime.
    AppRoutes.spans_seen = .unset;
    var collector = http.Server(void).init(alloc, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer collector.deinit();
    collector.router.post("/v1/traces", AppRoutes.collect);
    var collecting = try io.concurrent(struct {
        fn run(s: *http.Server(void)) !void {
            try s.run();
        }
    }.run, .{&collector});
    defer collecting.cancel(io) catch {};
    try collector.waitReady(io);
    const endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{collector.address.ip.getPort()});
    defer alloc.free(endpoint);

    _ = try app.tracing(.{ .endpoint = endpoint, .service_name = "app-test", .interval = .fromMilliseconds(20) });
    app.get("/hello", AppRoutes.hello);

    try listenAndCheck(&app, struct {
        fn check(io_: std.Io, arena: std.mem.Allocator, port: u16) !void {
            try std.testing.expectEqualStrings("hello", (try get(io_, arena, try urlOf(arena, port, "/hello"), &.{})).body);
            try @import("anole_test_wait").waitEvent(io_, "the request's span reaches the collector", &AppRoutes.spans_seen);
        }
    }.check);
}

const State = struct {
    seen: std.atomic.Value(u32) = .init(0),
};

const StateRoutes = struct {
    fn count(state: *State, _: *Request, _: *Response, next: handlers.Next) !void {
        _ = state.seen.fetchAdd(1, .monotonic);
        return next.call();
    }

    fn plain(_: *Request, res: *Response) !void {
        res.body = "plain";
    }

    fn stateful(state: *State, _: *Request, res: *Response) !void {
        try res.print(.text, "seen {d}", .{state.seen.load(.monotonic)});
    }

    /// grpc.health.v1.Health as methods on a value.
    const Health = struct {
        status: []const u8,

        const pb = grpc.health.pb;

        pub fn Check(self: *Health, call: *grpc.Call, req: pb.HealthCheckRequest) !pb.HealthCheckResponse {
            if (!std.mem.eql(u8, req.service, self.status)) return call.fail(.not_found, "unknown");
            return .{ .status = .SERVING };
        }
        pub fn List(_: *Health, _: *grpc.Call, _: pb.HealthListRequest) !pb.HealthListResponse {
            return .{};
        }
        pub fn Watch(_: *Health, _: *grpc.Call, _: pb.HealthCheckRequest, out: *std.Io.Queue(pb.HealthCheckResponse)) !void {
            _ = out;
        }
    };
};

test "anole.Server(State): listen after init's listeners is ListenersAlreadySet, and run serves init's listeners" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    var state: State = .{};
    var app = try Server(State).init(alloc, .{ .http = .{ .port = 0, .h2c = false }, .executors = .exact(2) }, &state);
    defer app.deinit();
    // The listeners came from init's options...
    try std.testing.expectError(error.ListenersAlreadySet, app.listen(":0"));
    // ...and `run` still serves them.
    const Check = struct {
        fn run(a: *Server(State)) !void {
            defer a.stop();
            try a.waitReady();
            try std.testing.expect(a.addresses()[0].ip.getPort() != 0);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.run();
    try checking.await(app.io());
}

test "anole.Server(State): (req, res) and (state, req, res) handlers, state middleware and gRPC methods on a value are served" {
    var state: State = .{};
    var app = try Server(State).init(alloc, .{ .executors = .exact(2) }, &state);
    defer app.deinit();
    app.use(StateRoutes.count);
    app.get("/plain", StateRoutes.plain);
    app.get("/stateful", StateRoutes.stateful);
    var impl: StateRoutes.Health = .{ .status = "known" };
    if (features.grpc) app.grpc(grpc.health.pb.Health, &impl);

    const Check = struct {
        fn run(a: *Server(State)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();
            try std.testing.expectEqualStrings("plain", (try get(io_, arena, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/plain", .{port}), &.{})).body);
            try std.testing.expectEqualStrings("seen 2", (try get(io_, arena, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/stateful", .{port}), &.{})).body);
            if (features.grpc) {
                const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/grpc.health.v1.Health/Check", .{port});
                try std.testing.expectEqualStrings("{\"status\":\"SERVING\"}", try post(io_, arena, url, "application/json", "{\"service\":\"known\"}"));
                try std.testing.expectError(error.UnexpectedStatus, post(io_, arena, url, "application/json", "{\"service\":\"other\"}"));
            }
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    // `run` sets up what `init` left: 127.0.0.1:8080 by default, so a
    // port of our own here.
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "anole.noWait: a marked route answers over HTTP/1.1 and HTTP/2, beside a waiting one" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/quick/:n", handlers.noWait(struct {
        fn h(req: *Request, res: *Response) !void {
            try res.print(.text, "quick {s}", .{req.params.get("n").?});
        }
    }.h));
    app.get("/slow", struct {
        fn h(req: *Request, res: *Response) !void {
            try req.io.sleep(.fromMilliseconds(20), .awake);
            res.body = "slow";
        }
    }.h);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();
            try std.testing.expectEqualStrings("quick 1", (try get(io_, arena, try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/quick/1", .{port}), &.{})).body);
            if (comptime !features.http2) return;
            const conn = try h2.ClientConnection.connect(alloc, io_, .{ .host = "127.0.0.1", .port = port });
            defer conn.close();
            var streams: [8]*h2.Stream = undefined;
            for (&streams, 0..) |*st, i| {
                const path = if (i == 3) "/slow" else try std.fmt.allocPrint(arena, "/quick/{d}", .{i});
                st.* = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = path },
                    .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
            }
            for (streams, 0..) |st, i| {
                defer st.release();
                try st.waitHead();
                try std.testing.expectEqual(@as(u16, 200), st.status);
                const body = try st.reader().allocRemaining(arena, .unlimited);
                if (i == 3) {
                    try std.testing.expectEqualStrings("slow", body);
                } else {
                    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "quick {d}", .{i}), body);
                }
            }
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "anole.App: listenTls serves HTTPS, and HTTP/3 advertised with Alt-Svc" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.get("/hello", AppRoutes.hello);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            var dc = http.Client.init(alloc, io_, .{ .tls = .{ .insecure_skip_verify = true } });
            defer dc.deinit();
            var url_buf: [64]u8 = undefined;
            var resp = try dc.fetch(try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hello", .{port}), .{});
            defer resp.deinit();
            try std.testing.expectEqualStrings("hello", (try resp.body()).?);
            if (comptime !features.http3) {
                try std.testing.expect(resp.headers().get("Alt-Svc") == null);
                return;
            }
            const q = a.http3Address().?;
            var alt_buf: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&alt_buf, "h3=\":{d}\"; ma=86400", .{q.getPort()}), resp.headers().get("Alt-Svc").?);
            const conn = try h3.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .address = q,
                .port = q.getPort(),
                .tls = .{ .insecure_skip_verify = true },
                .connect_timeout = .fromSeconds(3),
            });
            defer conn.close();
            const s = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/hello" },
                .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            defer s.release();
            try s.waitHead();
            try std.testing.expectEqual(@as(u16, 200), s.status);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listenTls("127.0.0.1:0", .dev_self_signed);
    try checking.await(app.io());
}

test "anole.App: an address listen cannot take fails listen, and waitReady with it" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try std.testing.expectError(error.InvalidListenAddress, app.listen("example.com:80"));
    try std.testing.expectError(error.InvalidListenAddress, app.waitReady());
}

/// What the handler saw as the client's address, without the port: one
/// client is one address whichever family its socket was.
fn remoteAddressBody(req: *Request, res: *Response) !void {
    var addr = req.remote_address;
    addr.setPort(0);
    // "127.0.0.1:0" or "[::1]:0": the host alone.
    const text = try std.fmt.allocPrint(res.arena, "{f}", .{addr});
    var host = text[0 .. text.len - ":0".len];
    if (host.len >= 2 and host[0] == '[') host = host[1 .. host.len - 1];
    res.body = host;
}

/// Whether this machine has IPv6 loopback (`::1`): not in a container
/// with IPv6 off.
fn haveIpv6Loopback() bool {
    // Through std.Io, which binds on Windows too.
    const io = std.testing.io;
    const lo: std.Io.net.IpAddress = .{ .ip6 = .loopback(0) };
    const socket = lo.bind(io, .{ .mode = .dgram }) catch return false;
    socket.close(io);
    return true;
}

/// `GET /addr` over a fresh TCP connection to `to`: the body.
fn rawGet(io: std.Io, to: std.Io.net.IpAddress, out: []u8) ![]const u8 {
    const stream = try to.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /addr HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    if (r.interface.streamRemaining(&fw)) |_| {} else |_| {
        // A cancel is handed on (SAFETY.md C3); anything else ends the read.
        if (r.err) |e| if (e == error.Canceled) return error.Canceled;
    }
    const resp = fw.buffered();
    if (!std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n")) return error.UnexpectedStatus;
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.NoBody;
    return resp[head_end + 4 ..];
}

test "anole.App: listen(\":0\") takes IPv4 and IPv6 on one dual-stack socket; handlers see plain IPv4" {
    const address_mod = @import("address.zig");
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.get("/addr", remoteAddressBody);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const bound = a.addresses()[0].ip;
            const port = bound.getPort();
            var out: [1024]u8 = undefined;
            if (!address_mod.dualStackAvailable()) {
                // No IPv6 here: every IPv4 interface instead.
                try std.testing.expect(bound == .ip4);
                try std.testing.expectEqualStrings("127.0.0.1", try rawGet(io_, .{ .ip4 = .loopback(port) }, &out));
                return;
            }
            try std.testing.expect(bound == .ip6 and std.mem.allEqual(u8, &bound.ip6.bytes, 0));
            // An IPv4 client arrives IPv4-mapped and is reported as IPv4.
            try std.testing.expectEqualStrings("127.0.0.1", try rawGet(io_, .{ .ip4 = .loopback(port) }, &out));
            if (haveIpv6Loopback()) try std.testing.expectEqualStrings("::1", try rawGet(io_, .{ .ip6 = .loopback(port) }, &out));
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listen(":0");
    try checking.await(app.io());
}

test "anole.App: an explicit 0.0.0.0 stays IPv4 only" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/addr", remoteAddressBody);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const bound = a.addresses()[0].ip;
            try std.testing.expect(bound == .ip4);
            const port = bound.getPort();
            var out: [1024]u8 = undefined;
            try std.testing.expectEqualStrings("127.0.0.1", try rawGet(io_, .{ .ip4 = .loopback(port) }, &out));
            if (!haveIpv6Loopback()) return;
            if (rawGet(io_, .{ .ip6 = .loopback(port) }, &out)) |_| {
                return error.ServedOverIpv6;
            } else |err| try std.testing.expectEqual(error.ConnectionRefused, err);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listen("0.0.0.0:0");
    try checking.await(app.io());
}

test "anole.App: metrics and health only on the listener named for them" {
    var app = try App.init(alloc, .{
        .listeners = &.{
            .{ .name = "public", .port = 0 },
            .{ .name = "admin", .port = 0 },
        },
        .executors = .exact(1),
    });
    defer app.deinit();
    _ = app.metrics(.{ .listener = "admin" });
    _ = app.health(.{ .listener = "admin" });
    app.get("/", struct {
        fn h(_: *Request, res: *Response) !void {
            res.body = "hi";
        }
    }.h);

    const Check = struct {
        fn status(io: std.Io, port: u16, path: []const u8) !u16 {
            const to: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            const stream = try to.connect(io, .{ .mode = .stream });
            defer stream.close(io);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
            try w.interface.flush();
            var rbuf: [4096]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var out: [8192]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&out);
            if (r.interface.streamRemaining(&fw)) |_| {} else |_| {
                if (r.err) |e| if (e == error.Canceled) return error.Canceled;
            }
            return std.fmt.parseInt(u16, fw.buffered()[9..12], 10);
        }

        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const public = a.addresses()[0].ip.getPort();
            const admin = a.addresses()[1].ip.getPort();
            try std.testing.expectEqual(@as(u16, 200), try status(io_, public, "/"));
            try std.testing.expectEqual(@as(u16, 404), try status(io_, public, "/metrics"));
            try std.testing.expectEqual(@as(u16, 404), try status(io_, public, "/readyz"));
            try std.testing.expectEqual(@as(u16, 200), try status(io_, admin, "/metrics"));
            try std.testing.expectEqual(@as(u16, 200), try status(io_, admin, "/readyz"));
            try std.testing.expectEqual(@as(u16, 200), try status(io_, admin, "/healthz"));
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.run();
    try checking.await(app.io());
}

test "anole.App: an unsafe request marked as early data gets 425, HTTP/3 or not" {
    // No HTTP/3 here (a build without it does the same): the mark can come
    // from a proxy in front.
    var app = try App.init(alloc, .{ .executors = .exact(1), .listen_tls_http3 = false });
    defer app.deinit();
    app.post("/pay", struct {
        fn h(_: *Request, res: *Response) !void {
            res.body = "paid";
        }
    }.h);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const port = a.addresses()[0].ip.getPort();
            const to: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
            const stream = try to.connect(io_, .{ .mode = .stream });
            defer stream.close(io_);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io_, &wbuf);
            // As a proxy that took the request in TLS early data forwards it.
            try w.interface.writeAll("POST /pay HTTP/1.1\r\nHost: x\r\nEarly-Data: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io_, &rbuf);
            var out: [1024]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&out);
            if (r.interface.streamRemaining(&fw)) |_| {} else |_| {
                if (r.err) |e| if (e == error.Canceled) return error.Canceled;
            }
            try std.testing.expect(std.mem.startsWith(u8, fw.buffered(), "HTTP/1.1 425 "));
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "anole.App: listenTls(\":0\") serves HTTP/3 to 127.0.0.1 and ::1 on one socket, through Retry" {
    if (comptime !features.http3) return error.SkipZigTest;
    const address_mod = @import("address.zig");
    // Every new connection proves its address with a Retry token first,
    // which binds the token to the (IPv4-mapped) address it came from.
    var app = try App.init(alloc, .{ .executors = .exact(2), .http3 = .{ .alt_svc = false, .validate_address = true } });
    defer app.deinit();
    app.get("/addr", remoteAddressBody);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const q = a.http3Address().?;
            const dual = address_mod.dualStackAvailable();
            try std.testing.expectEqual(dual, q == .ip6);
            const port = q.getPort();
            try std.testing.expectEqualStrings("127.0.0.1", try h3Get(io_, .{ .ip4 = .loopback(port) }));
            if (dual and haveIpv6Loopback()) try std.testing.expectEqualStrings("::1", try h3Get(io_, .{ .ip6 = .loopback(port) }));
        }

        var body_buf: [64]u8 = undefined;

        fn h3Get(io_: std.Io, to: std.Io.net.IpAddress) ![]const u8 {
            const conn = try h3.ClientConnection.connect(alloc, io_, .{
                .host = "localhost",
                .address = to,
                .port = to.getPort(),
                .tls = .{ .insecure_skip_verify = true },
                .connect_timeout = .fromSeconds(3),
            });
            defer conn.close();
            const s = try conn.request(&.{
                .{ .name = ":method", .value = "GET" },   .{ .name = ":path", .value = "/addr" },
                .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "localhost" },
            }, .{});
            defer s.release();
            try s.waitHead();
            if (s.status != 200) return error.UnexpectedStatus;
            const body = try s.reader().allocRemaining(alloc, .unlimited);
            defer alloc.free(body);
            @memcpy(body_buf[0..body.len], body);
            return body_buf[0..body.len];
        }
    };
    var checking = try app.io().concurrent(Check.run, .{&app});
    defer checking.cancel(app.io()) catch {};
    try app.listenTls(":0", .dev_self_signed);
    try checking.await(app.io());
}

test "route conflicts in a test build: run fails with RouteConflict and routeConflict() has the message" {
    const expected_log = @import("errors.zig").expectLog();
    defer expected_log.deinit();
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/a/:id", AppRoutes.hello);
    app.get("/a/:name", AppRoutes.hello);
    const message = app.routeConflict() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, ":name conflicts with :id") != null);
    try std.testing.expectError(error.RouteConflict, app.run());
}

test "addRoute takes a run-time path and checks it at registration" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    var good: []const u8 = "/dyn/:id";
    var bad: []const u8 = "/x/*a/b";
    std.mem.doNotOptimizeAway(&good);
    std.mem.doNotOptimizeAway(&bad);
    app.addRoute(.get, good, AppRoutes.hello);
    try std.testing.expect(app.routeConflict() == null);
    app.addRoute(null, bad, AppRoutes.hello);
    const message = app.routeConflict() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("route ANY /x/*a/b: a wildcard (*a) must be the last segment", message);
}

test "In path fields under a group prefix are checked at registration" {
    const anole = @import("root.zig");
    const Ins = struct {
        fn show(_: *Request, in: anole.In(.{ .path = struct { uid: u64 } })) !void {
            _ = in;
        }
    };
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const v1 = app.group("/v1", .{});
    v1.get("/users/:id", Ins.show);
    const message = app.routeConflict() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, message, "route GET /v1/users/:id") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "\"uid\"") != null);
}
