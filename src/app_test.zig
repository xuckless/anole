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

test "anole.App: listen, function middleware, with, staticDir, metrics, health, ws, grpcHealth, tracing and the client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.txt", .data = "static page" });
    const files = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(files);

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

    const registry = app.metrics(.{});
    try std.testing.expectEqual(registry, app.metrics(.{}));
    _ = try app.tracing(.{ .endpoint = endpoint, .service_name = "app-test", .interval_ms = 20 });
    app.use(AppRoutes.stamp);
    app.get("/hello", AppRoutes.hello);
    app.get("/via", AppRoutes.via);
    app.with(.{AppRoutes.requireKey}).get("/secret", AppRoutes.secret);
    try app.staticDir("/files", files, .{});
    _ = app.health(.{});
    if (features.websocket) app.ws("/echo", AppRoutes.echo);
    if (features.grpc) try app.grpcHealth().set("app.Svc", .NOT_SERVING);

    const Check = struct {
        fn run(a: *App) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();
            app_port.store(port, .release);
            const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port});
            const url = struct {
                fn f(ar: std.mem.Allocator, b: []const u8, path: []const u8) ![]const u8 {
                    return std.fmt.allocPrint(ar, "{s}{s}", .{ b, path });
                }
            }.f;

            const hello = try get(io_, arena, try url(arena, base, "/hello"), &.{});
            try std.testing.expectEqualStrings("hello", hello.body);
            try std.testing.expectEqualStrings("fn-middleware", hello.stamp.?);

            const via = try get(io_, arena, try url(arena, base, "/via"), &.{});
            try std.testing.expectEqualStrings("via: hello", via.body);

            // `with`: this route alone is behind the key check.
            const refused = try get(io_, arena, try url(arena, base, "/secret"), &.{});
            try std.testing.expectEqual(http.Status.unauthorized, refused.status);
            try std.testing.expectEqualStrings("fn-middleware", refused.stamp.?);
            const allowed = try get(io_, arena, try url(arena, base, "/secret"), &.{.{ "X-Api-Key", "k" }});
            try std.testing.expectEqualStrings("secret", allowed.body);

            try std.testing.expectEqualStrings("static page", (try get(io_, arena, try url(arena, base, "/files/page.txt"), &.{})).body);
            try std.testing.expectEqualStrings("ok\n", (try get(io_, arena, try url(arena, base, "/healthz"), &.{})).body);
            try std.testing.expectEqualStrings("ok\n", (try get(io_, arena, try url(arena, base, "/readyz"), &.{})).body);
            const scraped = (try get(io_, arena, try url(arena, base, "/metrics"), &.{})).body;
            try std.testing.expect(std.mem.indexOf(u8, scraped, "anole_http_requests_total{method=\"GET\",route=\"/hello\",status=\"200\"} 2") != null);

            if (features.websocket) {
                // A plain request to a WebSocket route.
                const plain = try get(io_, arena, try url(arena, base, "/echo"), &.{});
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

            if (features.grpc) {
                // Connect's unary JSON over HTTP/1.1.
                const check = try post(io_, arena, try url(arena, base, "/grpc.health.v1.Health/Check"), "application/json", "{\"service\":\"app.Svc\"}");
                try std.testing.expectEqualStrings("{\"status\":\"NOT_SERVING\"}", check);
                const whole = try post(io_, arena, try url(arena, base, "/grpc.health.v1.Health/Check"), "application/json", "{}");
                try std.testing.expectEqualStrings("{\"status\":\"SERVING\"}", whole);
            }

            // The spans of the requests above reach the collector.
            try AppRoutes.spans_seen.waitTimeout(io_, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        }
    };
    var checking = try io.concurrent(Check.run, .{&app});
    try app.listen("127.0.0.1:0");
    try checking.await(io);
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

test "anole.Server(State): (req, res) and (state, req, res) handlers, function middleware with state, grpc with methods on a value; listen refused beside init's listeners" {
    var state: State = .{};
    var app = try Server(State).init(alloc, .{ .http = .{ .port = 0, .h2c = false }, .executors = .exact(2) }, &state);
    defer app.deinit();
    app.use(StateRoutes.count);
    app.get("/plain", StateRoutes.plain);
    app.get("/stateful", StateRoutes.stateful);
    var impl: StateRoutes.Health = .{ .status = "known" };
    if (features.grpc) app.grpc(grpc.health.pb.Health, &impl);
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
    try app.run();
    try checking.await(app.io());
}

test "anole.Server(State): served" {
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
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

test "anole.App: listenTls serves HTTPS, and HTTP/3 advertised with Alt-Svc" {
    if (comptime features.tls != .boringssl) return error.SkipZigTest;
    var app = try App.init(alloc, .{ .executors = .exact(2) });
    defer app.deinit();
    app.get("/hello", AppRoutes.hello);
    app.post("/hello", AppRoutes.hello);

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
            {
                // With HTTP/3 on, early data's guard is too, on every
                // route: an unsafe request a proxy took early gets 425.
                var early = try http.Headers.init(alloc, 2);
                defer early.deinit(alloc);
                try early.put("Early-Data", "1");
                var too_early = try dc.fetch(try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/hello", .{port}), .{ .method = .post, .headers = &early, .body = "" });
                defer too_early.deinit();
                try std.testing.expectEqual(@as(u16, 425), @backingInt(too_early.status()));
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
    try app.listenTls("127.0.0.1:0", .dev_self_signed);
    try checking.await(app.io());
}

test "anole.App: an address listen cannot take fails listen, and waitReady with it" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    try std.testing.expectError(error.InvalidListenAddress, app.listen("example.com:80"));
    try std.testing.expectError(error.InvalidListenAddress, app.waitReady());
}
