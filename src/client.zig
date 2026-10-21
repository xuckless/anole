//! The server's outbound HTTP client: one per `anole.Server`, made with it
//! and freed with it, its connections pooled across every handler.
//!
//!     fn handler(req: *anole.Request, res: *anole.Response) !void {
//!         var upstream = try anole.client(req).fetch("https://api.github.com/repos/ziglang/zig", .{
//!             .headers = &.{.{ "User-Agent", "anole" }},
//!         });
//!         defer upstream.deinit();
//!         const repo = try upstream.json(Repo, req.arena);
//!         ...
//!     }
//!
//! `anole.client` finds the server by the runtime of the `std.Io` it is
//! given (a request's, or `app.io()`), so it works from any handler and any
//! task of the server, with or without server state. It wraps dusty's
//! client (`anole.http.Client`, reachable as `.http`) with inline headers
//! and JSON decoding of the response.
const std = @import("std");
const zio = @import("zio");
const http = @import("http/root.zig");

/// A request header, as a pair: `.{ "User-Agent", "anole" }`.
pub const Header = [2][]const u8;

/// Headers a fetch takes inline; more go through `.http` and dusty's
/// `Headers`.
pub const max_inline_headers = 32;

/// What `Client.fetch` sends: method, headers, body, and limits.
pub const FetchOptions = struct {
    /// GET by default.
    method: http.Method = .get,
    /// Request headers as pairs, at most `max_inline_headers`.
    headers: []const Header = &.{},
    /// The request body, sent as it is; null for none.
    body: ?[]const u8 = null,
    /// The whole exchange, redirects included; null takes the client's
    /// (none by default).
    timeout: ?std.Io.Timeout = null,
    /// Redirects to follow; null takes the client's setting.
    max_redirects: ?u8 = null,
    /// Undo gzip, deflate or zstd on the response body.
    decompress: bool = true,
};

/// A handle on a server's outbound client (`anole.client(req)`,
/// `app.client()`): cheap to copy, valid while the server lives. What the
/// APIs that make requests take (`auth.Keyring`, `auth.oidc`,
/// `observe.trace.Exporter`); a core client of your own fits as
/// `.{ .http = &my_client }`.
pub const Client = struct {
    /// dusty's client, for everything `fetch` does not cover (streamed
    /// bodies, WebSocket, Unix sockets).
    http: *http.Client,

    /// Sends one request and reads the response head; the body is read on
    /// demand (`body`, `json`). `deinit` the response.
    pub fn fetch(self: Client, url: []const u8, options: FetchOptions) !Response {
        if (options.headers.len > max_inline_headers) return error.TooManyHeaders;
        var keys: [max_inline_headers][]const u8 = undefined;
        var values: [max_inline_headers][]const u8 = undefined;
        var hashes: [max_inline_headers]u8 = undefined;
        var headers: http.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
        for (options.headers) |h| try headers.put(h[0], h[1]);
        return .{ .inner = try self.http.fetch(url, .{
            .method = options.method,
            .headers = if (options.headers.len > 0) &headers else null,
            .body = options.body,
            .timeout = options.timeout,
            .max_redirects = options.max_redirects,
            .decompress = options.decompress,
        }) };
    }
};

/// A response from `Client.fetch`: status and headers at once, the body
/// read on demand. `deinit` it to hand the connection back.
pub const Response = struct {
    /// dusty's response, for streaming the body (`reader`) and the rest.
    inner: http.core.ClientResponse,

    /// The response's status.
    pub fn status(self: *const Response) http.Status {
        return self.inner.status();
    }

    /// The first value of response header `name` (case-insensitive), or
    /// null.
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        return self.inner.headers().get(name);
    }

    /// The whole body ("" when there is none), held by the response.
    pub fn body(self: *Response) ![]const u8 {
        return (try self.inner.body()) orelse "";
    }

    /// The body parsed as JSON into `T`, allocated with `allocator` (a
    /// request's arena, usually): it outlives the response. Fields `T` does
    /// not have are skipped. The status is not checked: look at `status`
    /// first where an error answer would not parse as `T`.
    pub fn json(self: *Response, comptime T: type, allocator: std.mem.Allocator) !T {
        return std.json.parseFromSliceLeaky(T, allocator, try self.body(), .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// Hands the connection back to the pool.
    pub fn deinit(self: *Response) void {
        self.inner.deinit();
    }
};

/// The client of the `anole.Server` whose runtime `source` belongs to: a
/// `*anole.Request` (its `io`) or a `std.Io`. Panics outside a server's
/// runtime, where there is no client to share.
pub fn client(source: anytype) Client {
    const io: std.Io = if (@TypeOf(source) == std.Io) source else source.io;
    return .{ .http = find(io) orelse @panic("anole.client: no anole.Server on this std.Io's runtime") };
}

/// A server's client and the runtime it serves, for `register`.
pub const Entry = struct { rt: *zio.Runtime, client: *http.Client };

/// The servers' clients by runtime; a handful at most (one per
/// `anole.Server`).
var registry: [8]std.atomic.Value(?*const Entry) = @splat(.init(null));

/// Makes `entry.client` what `client` finds on `entry.rt`, until
/// `unregister`. False when there are too many servers at once.
pub fn register(entry: *const Entry) bool {
    for (&registry) |*slot| {
        if (slot.cmpxchgStrong(null, entry, .acq_rel, .acquire) == null) return true;
    }
    return false;
}

/// Undoes `register`.
pub fn unregister(entry: *const Entry) void {
    for (&registry) |*slot| {
        if (slot.cmpxchgStrong(entry, null, .acq_rel, .acquire) == null) return;
    }
}

fn find(io: std.Io) ?*http.Client {
    const rt = zio.Runtime.fromIo(io) orelse return null;
    for (&registry) |*slot| {
        const entry = slot.load(.acquire) orelse continue;
        if (entry.rt == rt) return entry.client;
    }
    return null;
}

test "client: inline headers and JSON from the response" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var dusty_client = http.Client.init(gpa, io, .{});
    defer dusty_client.deinit();
    const entry: Entry = .{ .rt = rt, .client = &dusty_client };
    try std.testing.expect(register(&entry));
    defer unregister(&entry);

    const Echo = struct {
        fn handle(req: *http.Request, res: *http.Response) !void {
            try res.print(.json, "{{\"agent\":\"{s}\",\"n\":7,\"extra\":[1,2]}}", .{req.headers.get("User-Agent") orelse ""});
        }
    };
    var server = http.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/", Echo.handle);
    var serving = try io.concurrent(struct {
        fn run(s: *http.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer serving.cancel(io) catch {};
    try server.waitReady(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.address.ip.getPort()});
    var resp = try client(io).fetch(url, .{ .headers = &.{.{ "User-Agent", "anole-test" }} });
    defer resp.deinit();
    try std.testing.expectEqual(http.Status.ok, resp.status());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const got = try resp.json(struct { agent: []const u8, n: u32 }, arena.allocator());
    try std.testing.expectEqualStrings("anole-test", got.agent);
    try std.testing.expectEqual(@as(u32, 7), got.n);
    try std.testing.expect(std.mem.startsWith(u8, resp.header("Content-Type").?, "application/json"));
}
