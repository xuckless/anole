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
const store = @import("store.zig");

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

    /// Who asks, by a header of the app's own.
    fn whoami(req: *Request, res: *Response) !void {
        count(13);
        try res.print(.text, "user {s}", .{req.headers.get("X-Session-Token") orelse "anonymous"});
    }

    fn noTenant(req: *const Request) bool {
        return req.headers.get("X-Tenant") == null;
    }

    fn tenant(req: *Request, res: *Response) !void {
        count(14);
        try res.print(.text, "tenant {s}", .{req.headers.get("X-Tenant") orelse "none"});
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

/// The connection a check talks over: the app's port and an arena for the
/// answers.
const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    port: u16,

    fn get(c: Ctx, method: http.Method, path: []const u8, headers: []const client_mod.Header) !Got {
        return fetch(c.io, c.arena, c.port, method, path, headers);
    }
};

/// Serves `app` on a loopback port and runs `check(ctx, extra...)` against
/// it; the app stops when the check returns.
fn serve(app: *App, comptime check: anytype, extra: anytype) !void {
    for (&runs) |*r| r.store(0, .monotonic);
    const Wrap = struct {
        fn run(a: *App, x: @TypeOf(extra)) !void {
            defer a.stop();
            try a.waitReady();
            var arena_state: std.heap.ArenaAllocator = .init(alloc);
            defer arena_state.deinit();
            const c: Ctx = .{ .io = a.io(), .arena = arena_state.allocator(), .port = a.addresses()[0].ip.getPort() };
            try @call(.auto, check, .{c} ++ x);
        }
    };
    var checking = try app.io().concurrent(Wrap.run, .{ app, extra });
    defer checking.cancel(app.io()) catch {};
    try app.listen("127.0.0.1:0");
    try checking.await(app.io());
}

const ttl = ResponseCache.Options{ .ttl = .fromSeconds(60) };

test "ResponseCache: a kept GET answers again without the handler, per query, for HEAD too, and never for a POST" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.use(Routes.stamp);
    app.get("/page", handlers.cached(ttl, Routes.page));
    app.get("/json", handlers.cached(ttl, Routes.json));
    // anole.cached on a POST route is a compile error with app.post; addRoute
    // (a run-time path) skips the check, to see that a POST is not the cache's.
    app.addRoute(.post, "/page", handlers.cached(ttl, Routes.post));
    const Check = struct {
        fn run(c: Ctx) !void {
            // Kept: the second answer is the first, with the route's
            // headers; the middleware before the cache still ran.
            const first = try c.get(.get, "/page?a=1", &.{});
            const second = try c.get(.get, "/page?a=1", &.{});
            try testing.expectEqualStrings("page /page?a=1 run 1", first.body);
            try testing.expectEqualStrings(first.body, second.body);
            try testing.expectEqualStrings("page", second.route.?);
            try testing.expectStringStartsWith(second.content_type.?, "text/html");
            try testing.expect(!std.mem.eql(u8, first.seq, second.seq));
            try testing.expectEqual(@as(u32, 1), ran(0));
            // Another query is another page; HEAD comes from the kept GET.
            _ = try c.get(.get, "/page?a=2", &.{});
            try testing.expectEqual(@as(u32, 2), ran(0));
            const head = try c.get(.head, "/page?a=1", &.{});
            try testing.expectEqual(http.Status.ok, head.status);
            try testing.expectEqualStrings(try std.fmt.allocPrint(c.arena, "{d}", .{first.body.len}), head.length.?);
            try testing.expectEqual(@as(u32, 2), ran(0));
            // A POST is not the cache's.
            _ = try c.get(.post, "/page?a=1", &.{});
            _ = try c.get(.post, "/page?a=1", &.{});
            try testing.expectEqual(@as(u32, 2), ran(11));
            // res.json: its Content-Type header is the route's.
            const j = try c.get(.get, "/json", &.{});
            const again = try c.get(.get, "/json", &.{});
            try testing.expectEqualStrings(j.body, again.body);
            try testing.expectStringStartsWith(again.content_type.?, "application/json");
            try testing.expectEqual(@as(u32, 1), ran(1));
        }
    };
    try serve(&app, Check.run, .{});
}

test "ResponseCache: no-store, private, Set-Cookie and a 5xx are not kept; a 404 is" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/no-store", handlers.cached(ttl, Routes.noStore));
    app.get("/private", handlers.cached(ttl, Routes.private));
    app.get("/cookie", handlers.cached(ttl, Routes.cookie));
    app.get("/missing", handlers.cached(ttl, Routes.missing));
    app.get("/broken", handlers.cached(ttl, Routes.broken));
    const Check = struct {
        fn run(c: Ctx) !void {
            for (0..2) |_| {
                _ = try c.get(.get, "/no-store", &.{});
                _ = try c.get(.get, "/private", &.{});
                _ = try c.get(.get, "/cookie", &.{});
                try testing.expectEqual(http.Status.internal_server_error, (try c.get(.get, "/broken", &.{})).status);
            }
            try testing.expectEqual(@as(u32, 2), ran(2));
            try testing.expectEqual(@as(u32, 2), ran(3));
            try testing.expectEqual(@as(u32, 2), ran(4));
            try testing.expectEqual(@as(u32, 2), ran(8));
            try testing.expectEqual(http.Status.not_found, (try c.get(.get, "/missing", &.{})).status);
            try testing.expectEqual(http.Status.not_found, (try c.get(.get, "/missing", &.{})).status);
            try testing.expectEqual(@as(u32, 1), ran(7));
        }
    };
    try serve(&app, Check.run, .{});
}

test "ResponseCache: a request with credentials is neither served nor kept unless the route is .authenticated" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/page", handlers.cached(ttl, Routes.page));
    app.get("/open", handlers.cached(.{ .ttl = .fromSeconds(60), .authenticated = true }, Routes.open));
    const Check = struct {
        fn run(c: Ctx) !void {
            _ = try c.get(.get, "/page?a=1", &.{});
            // Not served from the kept answer.
            _ = try c.get(.get, "/page?a=1", &.{.{ "Authorization", "Bearer x" }});
            try testing.expectEqual(@as(u32, 2), ran(0));
            // Not kept for the next anonymous request.
            _ = try c.get(.get, "/page?a=3", &.{.{ "Cookie", "sid=1" }});
            _ = try c.get(.get, "/page?a=3", &.{});
            try testing.expectEqual(@as(u32, 4), ran(0));
            _ = try c.get(.get, "/open", &.{.{ "Authorization", "Bearer x" }});
            _ = try c.get(.get, "/open", &.{});
            try testing.expectEqual(@as(u32, 1), ran(10));
        }
    };
    try serve(&app, Check.run, .{});
}

test "ResponseCache: Vary keeps one entry per header value" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/lang", handlers.cached(ttl, Routes.lang));
    const Check = struct {
        fn run(c: Ctx) !void {
            try testing.expectEqualStrings("lang en", (try c.get(.get, "/lang", &.{.{ "Accept-Language", "en" }})).body);
            try testing.expectEqualStrings("lang fr", (try c.get(.get, "/lang", &.{.{ "Accept-Language", "fr" }})).body);
            try testing.expectEqualStrings("lang en", (try c.get(.get, "/lang", &.{.{ "Accept-Language", "en" }})).body);
            try testing.expectEqualStrings("lang fr", (try c.get(.get, "/lang", &.{.{ "Accept-Language", "fr" }})).body);
            try testing.expectEqual(@as(u32, 2), ran(6));
        }
    };
    try serve(&app, Check.run, .{});
}

test "ResponseCache: s-maxage wins over max-age and the route's ttl" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    app.get("/short", handlers.cached(ttl, Routes.short));
    const Check = struct {
        fn run(c: Ctx) !void {
            // The cache's clock stands still until the test moves it.
            const t: i64 = @intCast(store.now(c.io));
            store.test_clock.store(t, .monotonic);
            defer store.test_clock.store(0, .monotonic);
            try testing.expectEqualStrings("short 1", (try c.get(.get, "/short", &.{})).body);
            try testing.expectEqualStrings("short 1", (try c.get(.get, "/short", &.{})).body);
            // Past s-maxage=1 (max-age=60 and the ttl of 60 s would keep it).
            store.test_clock.store(t + 2 * std.time.ns_per_s, .monotonic);
            try testing.expectEqualStrings("short 2", (try c.get(.get, "/short", &.{})).body);
            try testing.expectEqual(@as(u32, 2), ran(5));
        }
    };
    try serve(&app, Check.run, .{});
}

test "ResponseCache: invalidation by path drops every query of it, .all drops everything; stats count hits and misses" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const pages = app.responseCache(.{ .name = "pages" });
    app.with(.{pages}).get("/shared/:n", Routes.shared);
    app.get("/plain", Routes.plain);
    const Check = struct {
        fn run(c: Ctx, cache: *ResponseCache) !void {
            try testing.expectEqualStrings("shared 1", (try c.get(.get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 1", (try c.get(.get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 2", (try c.get(.get, "/shared/2", &.{})).body);
            cache.invalidate(.{ .path = "/shared/1" });
            try testing.expectEqualStrings("shared 3", (try c.get(.get, "/shared/1?x=1", &.{})).body);
            try testing.expectEqualStrings("shared 2", (try c.get(.get, "/shared/2", &.{})).body);
            cache.invalidate(.all);
            try testing.expectEqualStrings("shared 4", (try c.get(.get, "/shared/2", &.{})).body);
            const s = cache.stats();
            try testing.expectEqual(@as(u64, 2), s.hits);
            try testing.expectEqual(@as(u64, 4), s.misses);
            // A route without the cache counts nothing.
            _ = try c.get(.get, "/plain", &.{});
            _ = try c.get(.get, "/plain", &.{});
            try testing.expectEqual(@as(u32, 2), ran(9));
            try testing.expectEqual(s, cache.stats());
        }
    };
    try serve(&app, Check.run, .{pages});
}

test "ResponseCache: hits and misses metrics carry the kind and name labels" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const registry = app.metrics(.{ .http = false });
    const pages = app.responseCache(.{ .name = "pages" });
    app.with(.{pages}).get("/shared/:n", Routes.shared);
    const Check = struct {
        fn run(c: Ctx, reg: *@import("../observe/root.zig").metrics.Registry) !void {
            _ = try c.get(.get, "/shared/1", &.{});
            _ = try c.get(.get, "/shared/1", &.{});
            var out: std.Io.Writer.Allocating = .init(c.arena);
            try reg.render(&out.writer);
            try testing.expect(std.mem.indexOf(u8, out.written(), "anole_cache_hits_total{kind=\"http\",name=\"pages\"} 1") != null);
            try testing.expect(std.mem.indexOf(u8, out.written(), "anole_cache_misses_total{kind=\"http\",name=\"pages\"} 1") != null);
        }
    };
    try serve(&app, Check.run, .{registry});
}

test "ResponseCache: credential_headers and cacheable keep per-user answers out" {
    var app = try App.init(alloc, .{ .executors = .exact(1) });
    defer app.deinit();
    const by_token = comptime ResponseCache.Options{ .ttl = .fromSeconds(60), .credential_headers = &.{ "Authorization", "Cookie", "X-API-Key", "X-Session-Token" } };
    app.get("/whoami", handlers.cached(by_token, Routes.whoami));
    app.get("/tenant", handlers.cached(.{ .ttl = .fromSeconds(60), .cacheable = Routes.noTenant }, Routes.tenant));

    const Check = struct {
        fn run(c: Ctx) !void {
            try testing.expectEqualStrings("user alice", (try c.get(.get, "/whoami", &.{.{ "X-Session-Token", "alice" }})).body);
            try testing.expectEqualStrings("user bob", (try c.get(.get, "/whoami", &.{.{ "X-Session-Token", "bob" }})).body);
            // Without the header the answer is everyone's, and kept.
            _ = try c.get(.get, "/whoami", &.{});
            const before = ran(13);
            try testing.expectEqualStrings("user anonymous", (try c.get(.get, "/whoami", &.{})).body);
            try testing.expectEqual(before, ran(13));

            try testing.expectEqualStrings("tenant a", (try c.get(.get, "/tenant", &.{.{ "X-Tenant", "a" }})).body);
            try testing.expectEqualStrings("tenant b", (try c.get(.get, "/tenant", &.{.{ "X-Tenant", "b" }})).body);
            try testing.expectEqualStrings("tenant none", (try c.get(.get, "/tenant", &.{})).body);
        }
    };
    try serve(&app, Check.run, .{});
}
