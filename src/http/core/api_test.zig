// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The conveniences on top of the core: status-carrying errors and
//! `Response.fail`, `Request.bind`, request locals, CORS (in groups too),
//! the startup line and the port-in-use check.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("root.zig");

const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };
const loopback: []const dusty.Listener = &.{.{ .address = loopback_addr }};

/// A void-context server on loopback, run on its own task.
fn Running(comptime Ctx: type) type {
    return struct {
        const Self = @This();
        server: dusty.Server(Ctx),
        future: std.Io.Future(anyerror!void) = undefined,

        fn start(self: *Self) !void {
            const io = std.testing.io;
            self.future = try io.concurrent(run, .{&self.server});
            self.server.waitReady(io) catch |err| {
                self.future.cancel(io) catch {};
                return err;
            };
        }

        fn run(s: *dusty.Server(Ctx)) anyerror!void {
            try s.run();
        }

        fn stop(self: *Self) void {
            self.future.cancel(std.testing.io) catch {};
            self.server.deinit();
        }

        /// The whole response to `request`, on a new connection.
        fn send(self: *Self, request: []const u8, out: []u8) ![]const u8 {
            const io = std.testing.io;
            const stream = try self.server.address.ip.connect(io, .{ .mode = .stream });
            defer stream.close(io);
            var wbuf: [1024]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            try w.interface.writeAll(request);
            try w.interface.flush();
            var rbuf: [1024]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var fw: std.Io.Writer = .fixed(out);
            _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
                error.WriteFailed => {},
                else => |e| return e,
            };
            return fw.buffered();
        }
    };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn bodyOf(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

const Handlers = struct {
    fn unauthorized(_: *dusty.Request, _: *dusty.Response) !void {
        return error.Unauthorized;
    }
    fn tooMany(_: *dusty.Request, _: *dusty.Response) !void {
        return error.TooManyRequests;
    }
    fn unprocessable(_: *dusty.Request, _: *dusty.Response) !void {
        return error.UnprocessableContent;
    }
    /// A JSON error from parsing something other than the request body.
    fn upstreamJson(req: *dusty.Request, _: *dusty.Response) !void {
        _ = try std.json.parseFromSliceLeaky(struct { a: u8 }, req.arena, "{not json", .{});
    }
    fn failText(_: *dusty.Request, res: *dusty.Response) !void {
        res.body = "half of something";
        return res.fail(.forbidden, "no entry");
    }
    fn failQuoted(_: *dusty.Request, res: *dusty.Response) !void {
        return res.fail(.conflict, "name \"x\" taken");
    }
    const NewUser = struct { name: []const u8, age: u8 = 0 };
    fn bind(req: *dusty.Request, res: *dusty.Response) !void {
        const in = try req.bind(NewUser);
        res.status = .created;
        try res.json(.{ .name = in.name, .age = in.age });
    }
};

fn startErrorServer(running: *Running(void), config: dusty.ServerConfig) !void {
    running.* = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, config, {}) };
    const r = &running.server.router;
    r.get("/unauthorized", Handlers.unauthorized);
    r.get("/too-many", Handlers.tooMany);
    r.get("/unprocessable", Handlers.unprocessable);
    r.get("/upstream-json", Handlers.upstreamJson);
    r.get("/fail", Handlers.failText);
    r.get("/fail-quoted", Handlers.failQuoted);
    r.post("/users", Handlers.bind);
    try running.start();
}

test "errors: status-named errors answer with their status; other errors are 500" {
    var running: Running(void) = undefined;
    try startErrorServer(&running, .{ .listeners = loopback });
    defer running.stop();
    var out: [2048]u8 = undefined;

    const a = try running.send("GET /unauthorized HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, a, "HTTP/1.1 401 Unauthorized\r\n"));
    try std.testing.expectEqualStrings("401 Unauthorized\n", bodyOf(a));

    const b = try running.send("GET /too-many HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, b, "HTTP/1.1 429 "));

    const c = try running.send("GET /unprocessable HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, c, "HTTP/1.1 422 "));

    // Footgun: a SyntaxError that is not the request's was a 400.
    const d = try running.send("GET /upstream-json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, d, "HTTP/1.1 500 "));
}

test "errors: JSON answers for a client that takes JSON, or a server that speaks it" {
    var running: Running(void) = undefined;
    try startErrorServer(&running, .{ .listeners = loopback });
    defer running.stop();
    var out: [2048]u8 = undefined;

    const a = try running.send("GET /unauthorized HTTP/1.1\r\nHost: x\r\nAccept: application/json\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, a, "HTTP/1.1 401 "));
    try std.testing.expect(has(a, "Content-Type: application/json"));
    try std.testing.expectEqualStrings("{\"error\":\"Unauthorized\"}", bodyOf(a));

    // A 404 too, and `fail` with a message that needs escaping.
    const b = try running.send("GET /nowhere HTTP/1.1\r\nHost: x\r\nAccept: text/html, application/json;q=0.9\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqualStrings("{\"error\":\"Not Found\"}", bodyOf(b));
    const c = try running.send("GET /fail-quoted HTTP/1.1\r\nHost: x\r\nAccept: application/json\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, c, "HTTP/1.1 409 "));
    try std.testing.expectEqualStrings("{\"error\":\"name \\\"x\\\" taken\"}", bodyOf(c));

    // `fail` replaces what was written before it; text by default.
    const d = try running.send("GET /fail HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, d, "HTTP/1.1 403 "));
    try std.testing.expectEqualStrings("no entry", bodyOf(d));

    var json_server: Running(void) = undefined;
    try startErrorServer(&json_server, .{ .listeners = loopback, .errors = .json });
    defer json_server.stop();
    const e = try json_server.send("GET /nowhere HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, e, "HTTP/1.1 404 "));
    try std.testing.expectEqualStrings("{\"error\":\"Not Found\"}", bodyOf(e));
    const f = try json_server.send("POST /unauthorized HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, f, "HTTP/1.1 405 "));
    try std.testing.expectEqualStrings("{\"error\":\"Method Not Allowed\"}", bodyOf(f));
}

fn teapotOrDefault(req: *dusty.Request, res: *dusty.Response, err: anyerror) void {
    if (err == error.Teapot) return res.fail(.im_a_teapot, "short and stout");
    dusty.defaultError(req, res, err);
}

test "errors: an error_handler without a context, falling back to the default mapping" {
    var running: Running(void) = undefined;
    running = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{
        .listeners = loopback,
        .error_handler = teapotOrDefault,
    }, {}) };
    running.server.router.get("/teapot", struct {
        fn handle(_: *dusty.Request, _: *dusty.Response) !void {
            return error.Teapot;
        }
    }.handle);
    running.server.router.get("/unauthorized", Handlers.unauthorized);
    running.server.router.get("/upstream-json", Handlers.upstreamJson);
    try running.start();
    defer running.stop();
    var out: [2048]u8 = undefined;

    const a = try running.send("GET /teapot HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, a, "HTTP/1.1 418 "));
    try std.testing.expectEqualStrings("short and stout", bodyOf(a));
    // Footgun: a custom handler used to replace the whole mapping.
    const b = try running.send("GET /unauthorized HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, b, "HTTP/1.1 401 "));
    const c = try running.send("GET /upstream-json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, c, "HTTP/1.1 500 "));
}

test "errors: an uncaughtError can fall back to defaultError" {
    const App = struct {
        seen: usize = 0,
        pub fn uncaughtError(self: *@This(), req: *dusty.Request, res: *dusty.Response, err: anyerror) void {
            self.seen += 1;
            dusty.defaultError(req, res, err);
        }
        fn handle(_: *@This(), _: *dusty.Request, _: *dusty.Response) !void {
            return error.BodyTooBig;
        }
    };
    var app: App = .{};
    var running: Running(App) = .{ .server = dusty.Server(App).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, &app) };
    running.server.router.get("/big", App.handle);
    try running.start();
    defer running.stop();
    var out: [2048]u8 = undefined;
    const a = try running.send("GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, a, "HTTP/1.1 413 "));
    try std.testing.expectEqual(@as(usize, 1), app.seen);
}

test "bind: unknown fields ignored, a missing or malformed body is 400" {
    var running: Running(void) = undefined;
    try startErrorServer(&running, .{ .listeners = loopback });
    defer running.stop();
    var out: [2048]u8 = undefined;

    // Footgun: one field the server does not know was a 400.
    const body = "{\"name\":\"ann\",\"age\":30,\"extra\":{\"x\":[1,2]}}";
    var req_buf: [512]u8 = undefined;
    const created = try running.send(try std.fmt.bufPrint(&req_buf, "POST /users HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }), &out);
    try std.testing.expect(std.mem.startsWith(u8, created, "HTTP/1.1 201 "));
    try std.testing.expect(has(created, "Content-Type: application/json"));
    try std.testing.expectEqualStrings("{\"name\":\"ann\",\"age\":30}", bodyOf(created));

    const empty = try running.send("POST /users HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, empty, "HTTP/1.1 400 "));

    for ([_][]const u8{ "{\"age\":3}", "{\"name\":7}", "{\"name\":\"a\",\"age\":300}", "not json" }) |bad| {
        const sent = try std.fmt.bufPrint(&req_buf, "POST /users HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ bad.len, bad });
        const r = try running.send(sent, &out);
        try std.testing.expect(std.mem.startsWith(u8, r, "HTTP/1.1 400 "));
    }
}

const SetTenant = struct {
    pub fn execute(_: *const SetTenant, req: *dusty.Request, _: *dusty.Response, next: anytype) !void {
        try req.setLocal("tenant", @as([]const u8, req.headers.get("X-Tenant") orelse "none"));
        try req.setLocal("level", @as(u8, 3));
        return next.call();
    }
};

test "locals: a middleware hands typed values to the handler, per request" {
    var running: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {}) };
    var mw: SetTenant = .{};
    running.server.router.use(dusty.Middleware(void).init(&mw));
    running.server.router.get("/t", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try res.print(.text, "{s} {d} {}", .{ req.local([]const u8, "tenant").?, req.local(u8, "level").?, req.local(u16, "level") == null });
        }
    }.handle);
    try running.start();
    defer running.stop();
    var out: [2048]u8 = undefined;
    const a = try running.send("GET /t HTTP/1.1\r\nHost: x\r\nX-Tenant: acme\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqualStrings("acme 3 true", bodyOf(a));
}

test "locals: reset with the request on a keep-alive connection" {
    var req: dusty.Request = .{ .arena = std.testing.allocator, ._parser = undefined, ._transport = undefined };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    req.arena = arena.allocator();
    try req.setLocal("k", @as(u32, 1));
    try std.testing.expectEqual(@as(u32, 1), req.local(u32, "k").?);
    req._reset();
    try std.testing.expect(req.local(u32, "k") == null);
}

fn ok(_: *dusty.Request, res: *dusty.Response) !void {
    res.body = "ok";
}

fn startCors(running: *Running(void), cors: *dusty.middleware.Cors, in_group: bool) !void {
    running.* = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {}) };
    const r = &running.server.router;
    const handle = dusty.Middleware(void).init(cors);
    if (in_group) {
        const api = r.group("/api", &.{handle});
        api.post("/things", ok);
        api.get("/things", ok);
        r.post("/open", ok);
    } else {
        r.use(handle);
        r.post("/api/things", ok);
        r.get("/api/things", ok);
    }
    try running.start();
}

const preflight =
    "OPTIONS /api/things HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\n" ++
    "Access-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type, x-trace\r\nConnection: close\r\n\r\n";

test "Cors: the default answers preflights with methods, the asked headers and a max age" {
    var cors = dusty.middleware.Cors.init(.{});
    var running: Running(void) = undefined;
    try startCors(&running, &cors, false);
    defer running.stop();
    var out: [2048]u8 = undefined;

    // Footgun: a bare 204 without Allow-Methods/Allow-Headers blocked a
    // browser's JSON POST.
    const p = try running.send(preflight, &out);
    try std.testing.expect(std.mem.startsWith(u8, p, "HTTP/1.1 204 "));
    try std.testing.expect(has(p, "Access-Control-Allow-Origin: *\r\n"));
    try std.testing.expect(has(p, "Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE\r\n"));
    try std.testing.expect(has(p, "Access-Control-Allow-Headers: content-type, x-trace\r\n"));
    try std.testing.expect(has(p, "Access-Control-Max-Age: 600\r\n"));
    try std.testing.expect(!has(p, "Access-Control-Allow-Credentials"));

    const g = try running.send("GET /api/things HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, g, "HTTP/1.1 200 "));
    try std.testing.expect(has(g, "Access-Control-Allow-Origin: *\r\n"));
    try std.testing.expectEqualStrings("ok", bodyOf(g));
}

test "Cors: a list of origins with credentials echoes only listed ones, and varies by Origin" {
    var cors = dusty.middleware.Cors.init(.{
        .origins = &.{ "https://app.example", "https://admin.example" },
        .credentials = true,
        .expose = "X-Request-Id",
        .headers = "Content-Type",
    });
    var running: Running(void) = undefined;
    try startCors(&running, &cors, false);
    defer running.stop();
    var out: [2048]u8 = undefined;

    const p = try running.send(preflight, &out);
    try std.testing.expect(std.mem.startsWith(u8, p, "HTTP/1.1 204 "));
    try std.testing.expect(has(p, "Access-Control-Allow-Origin: https://app.example\r\n"));
    try std.testing.expect(has(p, "Access-Control-Allow-Credentials: true\r\n"));
    try std.testing.expect(has(p, "Access-Control-Allow-Headers: Content-Type\r\n"));
    try std.testing.expect(has(p, "Vary: Origin\r\n"));
    try std.testing.expect(!has(p, "Allow-Origin: *"));

    const g = try running.send("GET /api/things HTTP/1.1\r\nHost: x\r\nOrigin: https://admin.example\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(has(g, "Access-Control-Allow-Origin: https://admin.example\r\n"));
    try std.testing.expect(has(g, "Access-Control-Expose-Headers: X-Request-Id\r\n"));
    try std.testing.expect(has(g, "Vary: Origin\r\n"));

    // Not listed: served (CORS is the browser's to enforce), without the
    // headers that would let the page read it.
    const other = try running.send("GET /api/things HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, other, "HTTP/1.1 200 "));
    try std.testing.expect(!has(other, "Access-Control-Allow-Origin"));
    try std.testing.expect(!has(other, "Access-Control-Allow-Credentials"));
    try std.testing.expect(has(other, "Vary: Origin\r\n"));

    const bad_preflight = try running.send(
        "OPTIONS /api/things HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\nAccess-Control-Request-Method: POST\r\nConnection: close\r\n\r\n",
        &out,
    );
    try std.testing.expect(std.mem.startsWith(u8, bad_preflight, "HTTP/1.1 204 "));
    try std.testing.expect(!has(bad_preflight, "Access-Control-Allow"));
}

test "Cors: inside a group it answers the group's preflights" {
    var cors = dusty.middleware.Cors.init(.{});
    var running: Running(void) = undefined;
    try startCors(&running, &cors, true);
    defer running.stop();
    var out: [2048]u8 = undefined;

    // Footgun: this was a 405 with no CORS headers, since only the global
    // middleware ran for a method miss.
    const p = try running.send(preflight, &out);
    try std.testing.expect(std.mem.startsWith(u8, p, "HTTP/1.1 204 "));
    try std.testing.expect(has(p, "Access-Control-Allow-Origin: *\r\n"));
    try std.testing.expect(has(p, "Access-Control-Allow-Methods: "));

    // Outside the group nothing answers for CORS: a plain 405.
    const outside = try running.send(
        "OPTIONS /open HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\nAccess-Control-Request-Method: POST\r\nConnection: close\r\n\r\n",
        &out,
    );
    try std.testing.expect(std.mem.startsWith(u8, outside, "HTTP/1.1 405 "));
    try std.testing.expect(!has(outside, "Access-Control"));
    try std.testing.expect(has(outside, "Allow: POST\r\n"));

    // Any other method miss inside the group is still a 405.
    const put = try running.send("PUT /api/things HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, put, "HTTP/1.1 405 "));
}

test "Router.miss: the preflight runs the middleware of the route it asks about" {
    const Tag = struct {
        name: []const u8,
        pub fn execute(self: *const @This(), _: *dusty.Request, res: *dusty.Response, _: anytype) !void {
            res.status = .no_content;
            try res.header("X-Group", self.name);
        }
    };
    var a: Tag = .{ .name = "a" };
    var b: Tag = .{ .name = "b" };
    var running: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {}) };
    running.server.router.group("", &.{dusty.Middleware(void).init(&a)}).get("/x", ok);
    running.server.router.group("", &.{dusty.Middleware(void).init(&b)}).delete("/x", ok);
    try running.start();
    defer running.stop();
    var out: [2048]u8 = undefined;
    const del = try running.send("OPTIONS /x HTTP/1.1\r\nHost: x\r\nOrigin: o\r\nAccess-Control-Request-Method: DELETE\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(has(del, "X-Group: b\r\n"));
    const get = try running.send("OPTIONS /x HTTP/1.1\r\nHost: x\r\nOrigin: o\r\nAccess-Control-Request-Method: GET\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(has(get, "X-Group: a\r\n"));
}

test "listening line: scheme, address and protocols" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(3000) } };
    try dusty.describeListener(&w, &.{ .address = addr, .http2_prior_knowledge = true }, addr);
    const h2c = if (@import("build_options").use_http2) ", HTTP/2 cleartext" else "";
    try std.testing.expectEqualStrings("http://127.0.0.1:3000 (HTTP/1.1" ++ h2c ++ ")", w.buffered());

    w = .fixed(&buf);
    try dusty.describeListener(&w, &.{
        .address = addr,
        .tls = .{ .alpn_protocols = &.{ "h2", "http/1.1" } },
        .extra_protocols = &.{"HTTP/3"},
    }, addr);
    try std.testing.expectEqualStrings("https://127.0.0.1:3000 (HTTP/2, HTTP/1.1, HTTP/3)", w.buffered());

    w = .fixed(&buf);
    try dusty.describeListener(&w, &.{ .address = addr, .proxy_protocol = true }, addr);
    try std.testing.expectEqualStrings("http://127.0.0.1:3000 (HTTP/1.1; PROXY protocol)", w.buffered());
}

/// A port nothing listens on just now: bound, read back, closed.
fn freePort() !u16 {
    const io = std.testing.io;
    var s = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer s.deinit(io);
    return s.socket.address.getPort();
}

test "port in use: a second server on the same port fails instead of sharing it" {
    // std.Io.Threaded (std.testing.io) binds on Windows through AFD with the
    // address shared (its BIND_INFO mode 1 is AFD_SHARE_REUSE), so a second
    // listener there succeeds. src/http/root.zig checks this on zio.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Footgun: with SO_REUSEPORT both used to listen, splitting the traffic.
    const port = try freePort();
    const listeners: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(port) } } }};
    var first: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = listeners }, {}) };
    first.server.router.get("/", ok);
    try first.start();
    defer first.stop();

    try std.testing.expectError(error.AddressInUse, dusty.checkAddressFree(.{ .ip4 = .loopback(port) }, null));
    var second: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = listeners }, {}) };
    defer second.server.deinit();
    try std.testing.expectError(error.AddressInUse, second.start());

    // The first one is still the one answering.
    var out: [1024]u8 = undefined;
    const r = try first.send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expectEqualStrings("ok", bodyOf(r));
}

test "port in use: not tripped by the connections a stopped server left in TIME_WAIT" {
    const port = try freePort();
    const listeners: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(port) } } }};
    var out: [1024]u8 = undefined;
    for (0..2) |_| {
        var running: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = listeners }, {}) };
        running.server.router.get("/", ok);
        try running.start();
        // `Connection: close`: the server closes first, so the TIME_WAIT
        // is on its side of the port.
        for (0..3) |_| _ = try running.send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        running.stop();
    }
}

test "port in use: per-acceptor SO_REUSEPORT sockets of one server still bind" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const port = try freePort();
    var running: Running(void) = .{ .server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(port) } }, .acceptors = 4, .socket_per_acceptor = true }},
    }, {}) };
    running.server.router.get("/", ok);
    try running.start();
    defer running.stop();
    var out: [1024]u8 = undefined;
    for (0..8) |_| {
        const r = try running.send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expectEqualStrings("ok", bodyOf(r));
    }
}
