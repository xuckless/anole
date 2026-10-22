//! The Fiber-style conveniences through `anole.Server`: status-carrying
//! errors and `res.fail`, `Options.errors` and `Options.error_handler`,
//! `req.bind`/`res.json`, request locals, and CORS in a group, over
//! HTTP/1.1 and h2c.
const std = @import("std");
const features = @import("build_options");
const anole = @import("root.zig");
const http = anole.http;
const Server = anole.Server;

fn get(io: std.Io, addr: std.Io.net.IpAddress, request: []const u8, out: []u8) ![]const u8 {
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch {};
    return fw.buffered();
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn bodyOf(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

fn teapotOrDefault(req: *http.Request, res: *http.Response, err: anyerror) void {
    if (err == error.Teapot) return res.fail(.im_a_teapot, "short and stout");
    anole.defaultError(req, res, err);
}

const Handlers = struct {
    fn requireKey(req: *http.Request, _: *http.Response) !void {
        if (req.headers.get("X-Api-Key") == null) return error.Unauthorized;
    }
    fn teapot(_: *http.Request, _: *http.Response) !void {
        return error.Teapot;
    }
    const NewUser = struct { name: []const u8 };
    fn create(req: *http.Request, res: *http.Response) !void {
        const in = try req.bind(NewUser);
        res.status = .created;
        try res.json(.{ .name = in.name, .tenant = req.local([]const u8, "tenant") orelse "-" });
    }
    fn ok(_: *http.Request, res: *http.Response) !void {
        res.body = "ok";
    }
};

const Tenant = struct {
    pub fn execute(_: *const Tenant, req: *http.Request, _: *http.Response, next: anytype) !void {
        try req.setLocal("tenant", @as([]const u8, "acme"));
        return next.call();
    }
};

test "anole.Server: status errors in JSON, an error_handler without a Ctx, bind, locals, CORS in a group (HTTP/1.1 and h2c)" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{
        .http = .{ .port = 0 },
        .executors = .exact(2),
        .errors = .json,
        .error_handler = teapotOrDefault,
    }, {});
    defer app.deinit();
    app.use(Tenant{});
    app.get("/key", Handlers.requireKey);
    app.get("/teapot", Handlers.teapot);
    const api = app.group("/api", .{http.middleware.Cors.init(.{})});
    api.post("/users", Handlers.create);
    api.get("/users", Handlers.ok);

    var client_future = try app.io().concurrent(struct {
        fn run(a: *Server(void)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const addr = a.addresses()[0].ip;
            var out: [2048]u8 = undefined;

            const unauthorized = try get(io_, addr, "GET /key HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expect(std.mem.startsWith(u8, unauthorized, "HTTP/1.1 401 "));
            try std.testing.expectEqualStrings("{\"error\":\"Unauthorized\"}", bodyOf(unauthorized));

            const teapot = try get(io_, addr, "GET /teapot HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expect(std.mem.startsWith(u8, teapot, "HTTP/1.1 418 "));
            try std.testing.expectEqualStrings("{\"error\":\"short and stout\"}", bodyOf(teapot));

            const missing = try get(io_, addr, "GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expectEqualStrings("{\"error\":\"Not Found\"}", bodyOf(missing));

            const body = "{\"name\":\"ann\",\"unknown\":true}";
            var req_buf: [512]u8 = undefined;
            const created = try get(io_, addr, try std.fmt.bufPrint(&req_buf, "POST /api/users HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }), &out);
            try std.testing.expect(std.mem.startsWith(u8, created, "HTTP/1.1 201 "));
            try std.testing.expect(has(created, "Access-Control-Allow-Origin: *\r\n"));
            try std.testing.expectEqualStrings("{\"name\":\"ann\",\"tenant\":\"acme\"}", bodyOf(created));

            const bad = try get(io_, addr, "POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nConnection: close\r\n\r\n{", &out);
            try std.testing.expect(std.mem.startsWith(u8, bad, "HTTP/1.1 400 "));
            try std.testing.expectEqualStrings("{\"error\":\"Bad Request\"}", bodyOf(bad));

            const preflight = try get(io_, addr, "OPTIONS /api/users HTTP/1.1\r\nHost: x\r\nOrigin: https://app.example\r\n" ++
                "Access-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expect(std.mem.startsWith(u8, preflight, "HTTP/1.1 204 "));
            try std.testing.expect(has(preflight, "Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE\r\n"));
            try std.testing.expect(has(preflight, "Access-Control-Allow-Headers: content-type\r\n"));

            // The same preflight over h2c, through the HTTP/2 engine's
            // dispatch.
            if (comptime features.http2) {
                const conn = try anole.h2.ClientConnection.connect(gpa, io_, .{ .host = "localhost", .address = addr, .port = addr.getPort() });
                defer conn.close();
                const s = try conn.request(&.{
                    .{ .name = ":method", .value = "OPTIONS" },                    .{ .name = ":path", .value = "/api/users" },
                    .{ .name = ":scheme", .value = "http" },                       .{ .name = ":authority", .value = "localhost" },
                    .{ .name = "origin", .value = "https://app.example" },         .{ .name = "access-control-request-method", .value = "POST" },
                    .{ .name = "access-control-request-headers", .value = "x-a" },
                }, .{});
                defer s.release();
                try s.waitHead();
                try std.testing.expectEqual(@as(u16, 204), s.status);
                try std.testing.expectEqualStrings("*", s.header("access-control-allow-origin").?);
                try std.testing.expectEqualStrings("x-a", s.header("access-control-allow-headers").?);

                const e = try conn.request(&.{
                    .{ .name = ":method", .value = "GET" },  .{ .name = ":path", .value = "/key" },
                    .{ .name = ":scheme", .value = "http" }, .{ .name = ":authority", .value = "localhost" },
                }, .{});
                defer e.release();
                try e.waitHead();
                try std.testing.expectEqual(@as(u16, 401), e.status);
                const err_body = try e.reader().allocRemaining(gpa, .unlimited);
                defer gpa.free(err_body);
                try std.testing.expectEqualStrings("{\"error\":\"Unauthorized\"}", err_body);
            }
        }
    }.run, .{&app});
    try app.run();
    try client_future.await(app.io());
}

test "anole.Server: Options.errors and error_handler reach the core's configuration" {
    const gpa = std.testing.allocator;
    {
        var app = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1), .errors = .text, .error_handler = teapotOrDefault }, {});
        defer app.deinit();
        try std.testing.expectEqual(http.ErrorFormat.text, app.server.config.errors);
        try std.testing.expect(app.server.config.error_handler.? == teapotOrDefault);
    }
    // Without `errors`, the default is `.auto`.
    var app = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1), .error_handler = teapotOrDefault }, {});
    defer app.deinit();
    try std.testing.expectEqual(http.ErrorFormat.auto, app.server.config.errors);
    try std.testing.expect(app.server.config.error_handler.? == teapotOrDefault);
}

test "anole.Server: the HTTPS listener's startup line names HTTP/3" {
    if (comptime !features.http3) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{
        .https = .{ .port = 0, .cert = .dev_self_signed },
        .http3 = .{},
        .executors = .exact(1),
    }, {});
    defer app.deinit();
    const listeners = app.server.config.listeners;
    const tcp = listeners[listeners.len - 1];
    try std.testing.expectEqual(@as(usize, 1), tcp.extra_protocols.len);
    // Port 0: the UDP socket got a port of its own, so the line names it.
    try std.testing.expect(std.mem.startsWith(u8, tcp.extra_protocols[0], "HTTP/3"));
}

test "rateLimit: the 3rd request in a minute is 429, with Retry-After" {
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{ .http = .{ .port = 0 }, .executors = .exact(1) }, {});
    defer app.deinit();
    app.rateLimit(.{ .limit = 2 });
    app.get("/", Handlers.ok);
    var client_future = try app.io().concurrent(struct {
        fn run(a: *Server(void)) !void {
            defer a.stop();
            const io_ = a.io();
            try a.waitReady();
            const addr = a.addresses()[0].ip;
            var out: [1024]u8 = undefined;
            for (0..2) |_| {
                const ok = try get(io_, addr, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
                try std.testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200 "));
                try std.testing.expect(has(ok, "RateLimit-Limit: 2\r\n"));
            }
            const limited = try get(io_, addr, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
            try std.testing.expect(std.mem.startsWith(u8, limited, "HTTP/1.1 429 "));
            try std.testing.expect(has(limited, "Retry-After: "));
        }
    }.run, .{&app});
    try app.run();
    try client_future.await(app.io());
}

test "middleware: every built-in takes init(.{})" {
    _ = http.middleware.Compress.init(.{});
    _ = http.middleware.Logger.init(.{});
    _ = http.middleware.Cors.init(.{});
    _ = http.middleware.RequestId.init(.{});
    const gpa = std.testing.allocator;
    var store = anole.session.MemoryStore.init(gpa, std.testing.io, .{});
    defer store.deinit();
    var limited = anole.ratelimit.MemoryLimiter.init(gpa, std.testing.io, .{});
    defer limited.deinit();
    // Options, not Config, for a middleware's settings.
    comptime {
        if (@hasDecl(http.middleware.Cors, "Config") or @hasDecl(http.middleware.Logger, "Config") or
            @hasDecl(http.middleware.RequestId, "Config") or @hasDecl(anole.session, "Config"))
            @compileError("settings structs are named Options");
    }
}

test "api: Request and Response expose no engine fields without _" {
    const Allowed = struct {
        const request_fields = [_][]const u8{
            "method",         "url",         "version_major", "version_minor", "headers", "content_type",
            "content_encoding", "content_length", "route",       "params",        "query",   "remote_address",
            "listener",       "secure",      "protocol",      "forwarded_host", "peer_certificate", "id",
            "trace_id",       "span_id",     "drain",         "arena",         "io",      "session",
            "locals",
        };
        const request_decls = [_][]const u8{
            "host",    "peerCertificate", "setTimeout", "setDeadline", "reader",    "readerLimited", "body",
            "param",   "queryParam",      "bind",       "bindWith",    "json",      "jsonValue",     "jsonObject",
            "setLocal", "local",          "cookies",    "formData",    "multiFormData", "urlUnescape",
        };
        const response_fields = [_][]const u8{
            "status",      "body",      "headers",      "content_type", "arena",   "body_buffer", "io",
            "trailers",    "keepalive", "head",         "http10",       "content_length", "body_sent", "compress",
            "brotli_encoder", "file",   "detached",
        };
        const response_decls = [_][]const u8{
            "BodyFile",   "HeaderError", "SendError",   "WriteError",   "trailer",   "abort",   "headersSent",
            "peerGone",   "deinit",      "SendFileOptions", "SendFileError", "sendFile", "header", "addHeader",
            "writer",     "stream",      "clearWriter", "resetBody",    "json",      "jsonWith", "fail",
            "render",     "encode",      "print",       "setCookie",    "startEventStream", "canDetach", "isDetached",
            "detach",     "onFinish",    "adopt",       "write",        "memoryBodyLen", "copyBody",
        };
        fn listed(comptime list: []const []const u8, name: []const u8) bool {
            for (list) |n| if (std.mem.eql(u8, n, name)) return true;
            return false;
        }
        fn check(comptime T: type, comptime fields: []const []const u8, comptime decls: []const []const u8) void {
            comptime {
                @setEvalBranchQuota(100_000);
                const info = @typeInfo(T).@"struct";
                for (info.field_names) |name| {
                    if (name[0] == '_') continue;
                    if (!listed(fields, name)) @compileError(@typeName(T) ++ "." ++ name ++ " is public: prefix an engine field with _, or list a handler-facing one in this test on purpose");
                }
                for (info.decl_names) |name| {
                    if (name[0] == '_') continue;
                    if (!listed(decls, name)) @compileError(@typeName(T) ++ "." ++ name ++ " is public: prefix an engine declaration with _, or list a handler-facing one in this test on purpose");
                }
            }
        }
    };
    Allowed.check(http.Request, &Allowed.request_fields, &Allowed.request_decls);
    Allowed.check(http.Response, &Allowed.response_fields, &Allowed.response_decls);
}

test "doc comments: no dusty or core build-option names in public doc comments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var bad: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const text = dir.readFileAlloc(io, entry.path, gpa, .limited(16 << 20)) catch continue;
        defer gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |raw| {
            n += 1;
            const line = std.mem.trim(u8, raw, " \t");
            if (!std.mem.startsWith(u8, line, "///") and !std.mem.startsWith(u8, line, "//!")) continue;
            const names = std.mem.indexOf(u8, line, "dusty") != null or std.mem.indexOf(u8, line, "use_http2") != null or
                std.mem.indexOf(u8, line, "use_tls") != null;
            if (!names) continue;
            // Attribution, and identifiers that still carry the name.
            const allowed = [_][]const u8{ "Adapted from", "adapted from", "lalinsky/dusty", "xuckless/dusty", "LICENSE.dusty", "dusty_tls", "`dusty.", "dusty_mod", "`dusty`" };
            const ok = for (allowed) |a| {
                if (std.mem.indexOf(u8, line, a) != null) break true;
            } else false;
            if (ok) continue;
            std.debug.print("{s}:{d}: {s}\n", .{ entry.path, n, line });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
