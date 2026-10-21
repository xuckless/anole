//! `ResponseCache`: whole responses kept per executor and answered from
//! memory, without running the handler (or the middleware after the
//! cache), until they expire or are invalidated. Opt-in per route:
//!
//!     app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed));
//!
//! or one cache for several routes, through `with`, `group` or `use`:
//!
//!     const pages = app.responseCache(.{ .ttl = .fromSeconds(30), .name = "pages" });
//!     app.with(.{pages}).get("/about", about);
//!     ...
//!     pages.invalidate(.{ .path = "/about" });
//!
//! What it keeps: answers to GET (HEAD is served from them, never stored
//! from) with a status RFC 9111 lets a cache keep without being told
//! (200, 203, 204, 300, 301, 308, 404, 410), a body in memory (not a
//! file, a stream or an upgrade) and no trailers. Never a response that
//! sets a cookie, nor one whose `Cache-Control` says `no-store`,
//! `no-cache` or `private`; `s-maxage`, else `max-age`, sets how long one
//! is kept (0: not kept), else `Options.ttl`. `Vary` is honoured: each
//! combination of the named request headers is kept apart (`Vary: *` is
//! not kept). Requests that carry credentials (`Authorization`, `Cookie`,
//! `X-API-Key`) neither read nor fill it unless `authenticated` says so.
//!
//! The key is the method (GET for HEAD), the scheme, the `Host` and the
//! target (path and query, as sent: `?a=1&b=2` and `?b=2&a=1` are two
//! entries). Headers set by middleware that ran before the cache are not
//! kept (that middleware runs again on a hit: a fresh request ID, CORS
//! for the request's origin); headers the route set are, and replayed.
//! The body is kept as the handler wrote it: with `Compress`, each hit is
//! compressed for its client again.
//!
//! Per executor, like the database caches: each executor fills its own, so
//! two executors may answer from responses up to a `ttl` apart, and
//! `invalidate` reaches every executor at once.
const std = @import("std");
const dusty = @import("dusty");
const store = @import("store.zig");
const observe = @import("../observe/root.zig");

const Request = dusty.Request;
const Response = dusty.Response;
const Generations = store.Generations;

/// A response cache: a middleware (`execute`) that answers from memory
/// what it kept, and keeps what the routes behind it answer. Make one with
/// `app.responseCache(options)`, or `anole.cached` for one route.
pub const ResponseCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    locals: store.PerExecutor(Local),
    gens: Generations = .{},
    metrics: ?store.Metrics = null,

    /// Limits and policy. Nothing is cached until a cache is put on a route.
    pub const Options = struct {
        /// How long a response is kept when its `Cache-Control` does not
        /// say (`s-maxage`, else `max-age`, win).
        ttl: std.Io.Duration = .fromSeconds(10),
        /// Responses kept at most, over all executors.
        max_entries: usize = 1024,
        /// Bytes they take at most (bodies, headers, keys), over all
        /// executors.
        max_bytes: usize = 16 << 20,
        /// A response larger than this is not kept.
        max_entry_bytes: usize = 1 << 20,
        /// Also serve and keep answers to requests that carry credentials
        /// (`credential_headers`). Only for routes whose answer does not
        /// depend on who asks: the credentials are not part of the key,
        /// so one caller's answer is every caller's.
        authenticated: bool = false,
        /// The request headers that count as credentials.
        credential_headers: []const []const u8 = &.{ "Authorization", "Cookie", "X-API-Key" },
        /// The cache's name in metrics (`name` label), one per cache.
        /// Null: the route's path for `anole.cached`, else "http".
        name: ?[]const u8 = null,
    };

    /// What `invalidate` drops.
    pub const Target = union(enum) {
        /// Every response.
        all,
        /// The responses for this path, whatever their query, host or
        /// `Vary` headers: "/posts/7".
        path: []const u8,
    };

    const Local = struct {
        store: store.Store,
        /// Where a request's key is built: reused, never held across a wait.
        key: std.Io.Writer.Allocating,
    };

    /// Entries are responses, or markers that name the request headers a
    /// path's responses vary by.
    const response_kind: u8 = 0;
    const vary_kind: u8 = 1;

    /// A kept response: this head, then its headers (name length u16,
    /// value length u32, name, value), then its body.
    const Head = struct {
        status: dusty.Status,
        content_type: ?dusty.ContentType,
        compress: bool,
        header_count: u16,
        headers_len: usize,
        body_len: usize,
    };

    /// A cache with a store per executor of `io`'s runtime (the server's).
    /// `app.responseCache` calls it and frees the cache with the server;
    /// one made here is the caller's to `deinit`, after the server stops.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*ResponseCache {
        const self = try gpa.create(ResponseCache);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .options = options, .locals = try .init(gpa, io) };
        const n = self.locals.items.len;
        for (self.locals.items, 0..) |*l, i| l.* = .{
            .store = .init(gpa, if (options.max_entries == 0) 0 else store.share(options.max_entries, n, i), store.share(options.max_bytes, n, i)),
            .key = .init(gpa),
        };
        return self;
    }

    /// Frees every kept response and the cache.
    pub fn deinit(self: *ResponseCache) void {
        for (self.locals.items) |*l| {
            l.store.deinit();
            l.key.deinit();
        }
        self.locals.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Reports to `registry` (`anole_cache_*{kind="http",name}`). The
    /// server calls it when serving starts, with the app's registry, tracer
    /// and health checks, as it starts every connector; a response cache
    /// has no spans or health check of its own, so it uses only `registry`.
    pub fn start(self: *ResponseCache, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        _ = tracer;
        _ = health;
        const r = registry orelse return;
        if (self.metrics != null) return;
        self.metrics = try .init(r, "http", self.options.name orelse "http");
        for (self.locals.items) |*l| self.metrics.?.attach(&l.store);
    }

    /// Every executor's counters, added up.
    pub fn stats(self: *const ResponseCache) store.Totals {
        var t: store.Totals = .{};
        for (self.locals.items) |*l| t.add(&l.store.stats);
        return t;
    }

    /// Drops kept responses, on every executor at once: `.all`, or
    /// `.{ .path = "/posts/7" }` after a write that changes that page.
    pub fn invalidate(self: *ResponseCache, target: Target) void {
        switch (target) {
            .all => self.gens.invalidateAll(),
            .path => |p| self.gens.invalidateKey(std.hash.Wyhash.hash(0, p)),
        }
    }

    /// The middleware: a GET or HEAD with a fresh kept response gets it
    /// without going further; any other request runs on, and a GET's
    /// answer is kept when it may be.
    pub fn execute(self: *ResponseCache, req: *Request, res: *Response, executor: anytype) !void {
        if (req.method != .get and req.method != .head) return executor.next();
        if (!self.options.authenticated and self.credentials(req)) return executor.next();
        if (req.headers.get("Upgrade") != null) return executor.next();
        const local = self.locals.get(req.io) orelse return executor.next();

        const at = store.now(req.io);
        if (self.lookup(local, req, at) catch null) |entry| {
            local.store.count(.hit);
            return serve(entry, res);
        }
        local.store.count(.miss);

        // Taken before the handler runs: an invalidation while it does
        // leaves its answer unkept.
        const stamp = self.gens.stamp(Generations.untagged, Generations.keySlot(std.hash.Wyhash.hash(0, pathOf(req.url))));
        const before = res.headers.len;
        try executor.next();
        if (req.method == .head) return;
        self.keep(local, req, res, before, stamp) catch {};
    }

    fn credentials(self: *const ResponseCache, req: *const Request) bool {
        for (self.options.credential_headers) |name| if (req.headers.get(name) != null) return true;
        return false;
    }

    /// The fresh response for `req`, through the route's `Vary` marker
    /// when it has one.
    fn lookup(self: *ResponseCache, local: *Local, req: *const Request, at: i96) !?*store.Store.Entry {
        local.key.clearRetainingCapacity();
        try writeKey(&local.key.writer, req);
        const entry = local.store.get(local.key.written(), at, &self.gens) orelse return null;
        if (entry.kind == response_kind) return entry;
        try writeVariant(&local.key.writer, req, entry.value());
        return local.store.get(local.key.written(), at, &self.gens);
    }

    fn serve(entry: *store.Store.Entry, res: *Response) !void {
        const value = entry.value();
        const head: *const Head = entry.as(Head);
        // The entry may go while the response is written: the request's
        // own copy.
        const rest = try res.arena.dupe(u8, value[@sizeOf(Head)..][0 .. head.headers_len + head.body_len]);
        var it: usize = 0;
        for (0..head.header_count) |_| {
            const name_len = std.mem.readInt(u16, rest[it..][0..2], .little);
            const value_len = std.mem.readInt(u32, rest[it + 2 ..][0..4], .little);
            it += 6;
            const name = rest[it..][0..name_len];
            it += name_len;
            try res.headers.put(name, rest[it..][0..value_len]);
            it += value_len;
        }
        res.status = head.status;
        if (head.content_type) |ct| res.content_type = ct;
        if (head.compress) res.compress = true;
        res.body = rest[head.headers_len..];
    }

    /// Keeps what the route answered `req` with, when it may be kept.
    fn keep(self: *ResponseCache, local: *Local, req: *const Request, res: *Response, before: usize, stamp: store.Stamp) !void {
        if (!kept(res.status) or res.trailers != null) return;
        const body_len = res.memoryBodyLen() orelse return;
        if (res.headers.get("Set-Cookie") != null) return;
        const ttl = lifetime(res.headers.get("Cache-Control"), self.options.ttl) orelse return;
        const vary = res.headers.get("Vary");
        if (vary) |v| if (std.mem.indexOfScalar(u8, v, '*') != null) return;

        // The headers the route set, less those that describe this one
        // exchange rather than the response.
        var count: u16 = 0;
        var headers_len: usize = 0;
        for (before..res.headers.len) |i| {
            if (dropped(res.headers.keys[i])) continue;
            count += 1;
            headers_len += 6 + res.headers.keys[i].len + res.headers.values[i].len;
        }
        const len = @sizeOf(Head) + headers_len + body_len;
        if (len > self.options.max_entry_bytes) return;

        const at = store.now(req.io);
        const expires = at + ttl.nanoseconds;
        local.key.clearRetainingCapacity();
        try writeKey(&local.key.writer, req);
        if (vary) |v| {
            const names = try normalVary(req.arena, v);
            if (names.len > 0) {
                const marker = local.store.create(local.key.written(), names.len, .of(u8), expires, stamp) orelse return;
                marker.kind = vary_kind;
                @memcpy(marker.value(), names);
                local.store.insert(marker);
                try writeVariant(&local.key.writer, req, names);
            }
        }

        const entry = local.store.create(local.key.written(), len, .of(Head), expires, stamp) orelse return;
        const value = entry.value();
        entry.as(Head).* = .{
            .status = res.status,
            .content_type = res.content_type,
            .compress = res.compress,
            .header_count = count,
            .headers_len = headers_len,
            .body_len = body_len,
        };
        var it: usize = @sizeOf(Head);
        for (before..res.headers.len) |i| {
            const name = res.headers.keys[i];
            const v = res.headers.values[i];
            if (dropped(name)) continue;
            std.mem.writeInt(u16, value[it..][0..2], @intCast(name.len), .little);
            std.mem.writeInt(u32, value[it + 2 ..][0..4], @intCast(v.len), .little);
            it += 6;
            @memcpy(value[it..][0..name.len], name);
            it += name.len;
            @memcpy(value[it..][0..v.len], v);
            it += v.len;
        }
        res.copyBody(value[it..][0..body_len]);
        local.store.insert(entry);
    }
};

/// The statuses kept without being told (RFC 9111 4.2.2's heuristically
/// cacheable ones, less 405, 414 and 501, which say more about the
/// request than the resource).
fn kept(status: dusty.Status) bool {
    return switch (status) {
        .ok, .non_authoritative_information, .no_content, .multiple_choices, .moved_permanently, .permanent_redirect, .not_found, .gone => true,
        else => false,
    };
}

/// Headers about this exchange, not the response: the server sets them
/// again, or they must not be repeated.
fn dropped(name: []const u8) bool {
    for ([_][]const u8{ "Date", "Content-Length", "Transfer-Encoding", "Connection", "Keep-Alive", "Age", "Set-Cookie" }) |d| {
        if (std.ascii.eqlIgnoreCase(name, d)) return true;
    }
    return false;
}

/// How long a response may be kept, by its `Cache-Control`: `s-maxage`,
/// else `max-age`, else `default`; null when it must not be kept.
fn lifetime(cache_control: ?[]const u8, default: std.Io.Duration) ?std.Io.Duration {
    const value = cache_control orelse return if (default.nanoseconds > 0) default else null;
    var max_age: ?i64 = null;
    var s_maxage: ?i64 = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const d = std.mem.trim(u8, raw, " \t");
        const name = d[0 .. std.mem.indexOfScalar(u8, d, '=') orelse d.len];
        const arg = if (name.len < d.len) std.mem.trim(u8, d[name.len + 1 ..], " \t\"") else "";
        if (std.ascii.eqlIgnoreCase(name, "no-store") or std.ascii.eqlIgnoreCase(name, "no-cache") or std.ascii.eqlIgnoreCase(name, "private")) return null;
        if (std.ascii.eqlIgnoreCase(name, "max-age")) max_age = std.fmt.parseInt(i64, arg, 10) catch return null;
        if (std.ascii.eqlIgnoreCase(name, "s-maxage")) s_maxage = std.fmt.parseInt(i64, arg, 10) catch return null;
    }
    if (s_maxage orelse max_age) |seconds| return if (seconds > 0) .fromSeconds(seconds) else null;
    return if (default.nanoseconds > 0) default else null;
}

fn pathOf(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, '?') orelse url.len];
}

/// GET (for HEAD too), the scheme, the host and the target.
fn writeKey(w: *std.Io.Writer, req: *const Request) !void {
    try w.writeAll(if (req.secure) "GET https " else "GET http ");
    try w.writeAll(req.headers.get("Host") orelse "");
    try w.writeByte(' ');
    try w.writeAll(req.url);
}

/// After the key: the request's values of the headers `names` lists, for
/// a response that varies by them.
fn writeVariant(w: *std.Io.Writer, req: *const Request, names: []const u8) !void {
    try w.writeByte(0);
    var it = std.mem.splitScalar(u8, names, '\n');
    while (it.next()) |name| {
        try w.writeAll(name);
        try w.writeByte(':');
        try w.writeAll(std.mem.trim(u8, req.headers.get(name) orelse "", " \t"));
        try w.writeByte('\n');
    }
}

/// A `Vary` value as names, lower case, one per line.
fn normalVary(arena: std.mem.Allocator, vary: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, vary, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        for (name) |ch| try out.append(arena, std.ascii.toLower(ch));
    }
    return out.items;
}

test "lifetime: Cache-Control's say, else the default" {
    const ten: std.Io.Duration = .fromSeconds(10);
    try std.testing.expectEqual(ten, lifetime(null, ten).?);
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime(null, .fromSeconds(0)));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(60), lifetime("public, max-age=60", ten).?);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(5), lifetime("max-age=60, s-maxage=5", ten).?);
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime("max-age=0", ten));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime("no-store", ten));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime("private, max-age=60", ten));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime("No-Cache", ten));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), lifetime("max-age=soon", ten));
    try std.testing.expectEqual(ten, lifetime("public", ten).?);
}
