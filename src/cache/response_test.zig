//! `ResponseCache` over a real socket: what is kept and what is not
//! (methods, statuses, `Cache-Control`, `Set-Cookie`, credentials), `Vary`,
//! HEAD from a kept GET, expiry, invalidation, the route option and
//! `app.responseCache`, and its metrics.
const std = @import("std");
const http = @import("../http/root.zig");
const server_mod = @import("../server.zig");
const client_mod = @import("../client.zig");
const handlers = @import("../handlers.zig");
const ResponseCache = @import("response.zig").ResponseCache;

const App = server_mod.App;
const Request = http.Request;
const Response = http.Response;
const alloc = std.testing.allocator;
const testing = std.testing;

/// How often each route's handler ran.
var runs: [16]std.atomic.Value(u32) = @splat(.init(0));
/// Bumped by the middleware before the cache, on every request.
var seq: std.atomic.Value(u32) = .init(0);

fn ran(i: usize) u32 {
    return runs[i].load(.monotonic);
}

const Routes = struct {
    fn count(i: usize) void {
        _ = runs[i].fetchAdd(1, .monotonic);
    }

    /// Before the cache: a fresh header on every response, hit or not.
    fn stamp(_: *Request, res: *Response, next: handlers.Next) !void {
        const n = seq.fetchAdd(1, .monotonic);
        try res.header("X-Seq", try std.fmt.allocPrint(res.arena, "{d}", .{n}));
        return next.call();
    }

    fn page(req: *Request, res: *Response) !void {
        count(0);
        try res.header("X-Route", "page");
        try res.print(.html, "page {s} run {d}", .{ req.url, ran(0) });
    }

    fn json(_: *Request, res: *Response) !void {
        count(1);
        try res.json(.{ .run = ran(1) });
    }

    fn noStore(_: *Request, res: *Response) !void {
        count(2);
        try res.header("Cache-Control", "no-store");
        res.body = "fresh";
    }

    fn private(_: *Request, res: *Response) !void {
        count(3);
        try res.header("Cache-Control", "private, max-age=60");
        res.body = "mine";
    }

    fn cookie(_: *Request, res: *Response) !void {
        count(4);
        try res.setCookie("sid", "abc", .{});
        res.body = "with a cookie";
    }

    fn short(_: *Request, res: *Response) !void {
        count(5);
        try res.header("Cache-Control", "max-age=60, s-maxage=1");
        try res.print(.text, "short {d}", .{ran(5)});
    }

    fn lang(req: *Request, res: *Response) !void {
        count(6);
        try res.header("Vary", "Accept-Language");
        try res.print(.text, "lang {s}", .{req.headers.get("Accept-Language") orelse "none"});
    }

    fn missing(_: *Request, res: *Response) !void {
        count(7);
        res.status = .not_found;
        res.body = "no such thing";
    }

    fn broken(_: *Request, res: *Response) !void {
        count(8);
        res.status = .internal_server_error;
        res.body = "broken";
    }

    fn plain(_: *Request, res: *Response) !void {
        count(9);
        res.body = "plain";
    }

    fn open(_: *Request, res: *Response) !void {
        count(10);
        res.body = "same for everyone";
    }

    fn post(_: *Request, res: *Response) !void {
        count(11);
        res.body = "posted";
    }

    fn shared(_: *Request, res: *Response) !void {
        count(12);
        try res.print(.text, "shared {d}", .{ran(12)});
    }
};

const Got = struct {
    status: http.Status,
    body: []const u8,
    seq: []const u8,
    route: ?[]const u8,
    content_type: ?[]const u8,
    length: ?[]const u8,
};

fn fetch(io: std.Io, arena: std.mem.Allocator, port: u16, method: http.Method, path: []const u8, headers: []const client_mod.Header) !Got {
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ port, path });
    var resp = try client_mod.client(io).fetch(url, .{ .method = method, .headers = headers });
    defer resp.deinit();
    const dupe = struct {
        fn f(a: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
            return if (v) |x| try a.dupe(u8, x) else null;
        }
    }.f;
    return .{
        .status = resp.status(),
        .body = if (method == .head) "" else try arena.dupe(u8, try resp.body()),
        .seq = (try dupe(arena, resp.header("X-Seq"))) orelse "",
        .route = try dupe(arena, resp.header("X-Route")),
        .content_type = try dupe(arena, resp.header("Content-Type")),
        .length = try dupe(arena, resp.header("Content-Length")),
    };
}

test "ResponseCache: what is kept, Vary, HEAD, expiry, invalidation and metrics" {
    for (&runs) |*r| r.store(0, .monotonic);
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const registry = app.metrics(.{ .http = false });
    app.use(Routes.stamp);
    const ttl = comptime ResponseCache.Options{ .ttl = .fromSeconds(60) };
    app.get("/page", handlers.cached(ttl, Routes.page));
    app.get("/json", handlers.cached(ttl, Routes.json));
    app.get("/no-store", handlers.cached(ttl, Routes.noStore));
    app.get("/private", handlers.cached(ttl, Routes.private));
    app.get("/cookie", handlers.cached(ttl, Routes.cookie));
    app.get("/short", handlers.cached(ttl, Routes.short));
    app.get("/lang", handlers.cached(ttl, Routes.lang));
    app.get("/missing", handlers.cached(ttl, Routes.missing));
    app.get("/broken", handlers.cached(ttl, Routes.broken));
    app.get("/plain", Routes.plain);
    app.get("/open", handlers.cached(.{ .ttl = .fromSeconds(60), .authenticated = true }, Routes.open));
    app.post("/page", handlers.cached(ttl, Routes.post));
    const pages = app.responseCache(.{ .name = "pages" });
    app.with(.{pages}).get("/shared/:n", Routes.shared);

    const Check = struct {
        fn run(a: *App, cache: *ResponseCache, reg: *@import("../observe/root.zig").metrics.Registry) !void {
            defer a.stop();
            const io = a.io();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const port = a.addresses()[0].ip.getPort();

            // Kept: the second answer is the first, with the route's
            // headers; the middleware before the cache still ran.
            const first = try fetch(io, arena, port, .get, "/page?a=1", &.{});
            const second = try fetch(io, arena, port, .get, "/page?a=1", &.{});
            try testing.expectEqualStrings("page /page?a=1 run 1", first.body);
            try testing.expectEqualStrings(first.body, second.body);
            try testing.expectEqualStrings("page", second.route.?);
            try testing.expectStringStartsWith(second.content_type.?, "text/html");
            try testing.expect(!std.mem.eql(u8, first.seq, second.seq));
            try testing.expectEqual(@as(u32, 1), ran(0));
            // Another query is another page; HEAD comes from the kept GET.
            _ = try fetch(io, arena, port, .get, "/page?a=2", &.{});
            try testing.expectEqual(@as(u32, 2), ran(0));
            const head = try fetch(io, arena, port, .head, "/page?a=1", &.{});
            try testing.expectEqual(http.Status.ok, head.status);
            try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{first.body.len}), head.length.?);
            try testing.expectEqual(@as(u32, 2), ran(0));
            // A POST is not the cache's.
            _ = try fetch(io, arena, port, .post, "/page?a=1", &.{});
            _ = try fetch(io, arena, port, .post, "/page?a=1", &.{});
            try testing.expectEqual(@as(u32, 2), ran(11));

            // res.json: its Content-Type header is the route's.
            const j = try fetch(io, arena, port, .get, "/json", &.{});
            try testing.expectEqualStrings(j.body, (try fetch(io, arena, port, .get, "/json", &.{})).body);
            try testing.expectStringStartsWith((try fetch(io, arena, port, .get, "/json", &.{})).content_type.?, "application/json");
            try testing.expectEqual(@as(u32, 1), ran(1));

            // Not kept: no-store, private, a cookie, a 500.
            for (0..2) |_| {
                _ = try fetch(io, arena, port, .get, "/no-store", &.{});
                _ = try fetch(io, arena, port, .get, "/private", &.{});
                _ = try fetch(io, arena, port, .get, "/cookie", &.{});
                try testing.expectEqual(http.Status.internal_server_error, (try fetch(io, arena, port, .get, "/broken", &.{})).status);
            }
            try testing.expectEqual(@as(u32, 2), ran(2));
            try testing.expectEqual(@as(u32, 2), ran(3));
            try testing.expectEqual(@as(u32, 2), ran(4));
            try testing.expectEqual(@as(u32, 2), ran(8));
            // A 404 is.
            try testing.expectEqual(http.Status.not_found, (try fetch(io, arena, port, .get, "/missing", &.{})).status);
            try testing.expectEqual(http.Status.not_found, (try fetch(io, arena, port, .get, "/missing", &.{})).status);
            try testing.expectEqual(@as(u32, 1), ran(7));

            // Credentials: neither read nor filled, unless the route says.
            _ = try fetch(io, arena, port, .get, "/page?a=1", &.{.{ "Authorization", "Bearer x" }});
            _ = try fetch(io, arena, port, .get, "/page?a=3", &.{.{ "Cookie", "sid=1" }});
            _ = try fetch(io, arena, port, .get, "/page?a=3", &.{});
            try testing.expectEqual(@as(u32, 5), ran(0));
            _ = try fetch(io, arena, port, .get, "/open", &.{.{ "Authorization", "Bearer x" }});
            _ = try fetch(io, arena, port, .get, "/open", &.{});
            try testing.expectEqual(@as(u32, 1), ran(10));

            // Vary: one entry per Accept-Language.
            try testing.expectEqualStrings("lang en", (try fetch(io, arena, port, .get, "/lang", &.{.{ "Accept-Language", "en" }})).body);
            try testing.expectEqualStrings("lang fr", (try fetch(io, arena, port, .get, "/lang", &.{.{ "Accept-Language", "fr" }})).body);
            try testing.expectEqualStrings("lang en", (try fetch(io, arena, port, .get, "/lang", &.{.{ "Accept-Language", "en" }})).body);
            try testing.expectEqualStrings("lang fr", (try fetch(io, arena, port, .get, "/lang", &.{.{ "Accept-Language", "fr" }})).body);
            try testing.expectEqual(@as(u32, 2), ran(6));

            // s-maxage=1 wins over max-age and the route's ttl.
            try testing.expectEqualStrings("short 1", (try fetch(io, arena, port, .get, "/short", &.{})).body);
            try testing.expectEqualStrings("short 1", (try fetch(io, arena, port, .get, "/short", &.{})).body);
            try io.sleep(.fromMilliseconds(1100), .awake);
            try testing.expectEqualStrings("short 2", (try fetch(io, arena, port, .get, "/short", &.{})).body);

            // A cache of the app's own, for a group of routes, and
            // invalidated by path (every query of it) and as a whole.
            try testing.expectEqualStrings("shared 1", (try fetch(io, arena, port, .get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 1", (try fetch(io, arena, port, .get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 2", (try fetch(io, arena, port, .get, "/shared/2", &.{})).body);
            cache.invalidate(.{ .path = "/shared/1" });
            try testing.expectEqualStrings("shared 3", (try fetch(io, arena, port, .get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 2", (try fetch(io, arena, port, .get, "/shared/2", &.{})).body);
            cache.invalidate(.all);
            try testing.expectEqualStrings("shared 4", (try fetch(io, arena, port, .get, "/shared/2", &.{})).body);
            const s = cache.stats();
            try testing.expectEqual(@as(u64, 2), s.hits);
            try testing.expectEqual(@as(u64, 4), s.misses);

            // A route without the cache does nothing of the cache's.
            const before = cache.stats();
            _ = try fetch(io, arena, port, .get, "/plain", &.{});
            _ = try fetch(io, arena, port, .get, "/plain", &.{});
            try testing.expectEqual(@as(u32, 2), ran(9));
            try testing.expectEqual(before, cache.stats());

            // Metrics, labelled by kind and name.
            var out: std.Io.Writer.Allocating = .init(arena);
            try reg.render(&out.writer);
            try testing.expect(std.mem.indexOf(u8, out.written(), "anole_cache_hits_total{kind=\"http\",name=\"pages\"} 2") != null);
            try testing.expect(std.mem.indexOf(u8, out.written(), "anole_cache_misses_total{kind=\"http\",name=\"pages\"} 4") != null);
        }
    };
    var checking = try app.io().concurrent(Check.run, .{ &app, pages, registry });
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}
