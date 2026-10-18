//! What the observability middleware and routes share: serving a route
//! bound to an instance, the exclude lists, and the status a response is
//! recorded with.
const std = @import("std");
const dusty = @import("dusty");

/// Serves GET `path` with `handler(state, req, res)`. dusty's handlers carry
/// no state of their own, so `state` rides in a middleware of the route's
/// own, which answers and ends the chain; the global middleware still run
/// first. `state` must outlive the router.
pub fn serve(
    comptime Ctx: type,
    router: *dusty.Router(Ctx),
    path: []const u8,
    comptime T: type,
    state: *T,
    comptime handler: fn (*T, *dusty.Request, *dusty.Response) anyerror!void,
) void {
    const Bound = struct {
        state: *T,

        pub fn execute(self: *const @This(), req: *dusty.Request, res: *dusty.Response, _: anytype) !void {
            return handler(self.state, req, res);
        }
    };
    const arena = router.arena.allocator();
    const bound = arena.create(Bound) catch @panic("OOM");
    bound.* = .{ .state = state };
    const chain = arena.alloc(dusty.Middleware(Ctx), 1) catch @panic("OOM");
    chain[0] = .init(bound);
    // Never reached: the middleware above answers.
    const unreachable_handler = if (Ctx == void) struct {
        fn h(_: *dusty.Request, _: *dusty.Response) anyerror!void {}
    }.h else struct {
        fn h(_: *Ctx, _: *dusty.Request, _: *dusty.Response) anyerror!void {}
    }.h;
    router.group(path, chain).get("", unreachable_handler);
}

/// The routes Anole's probes and scrapes use, for `exclude` lists:
/// `.exclude = &anole.observe.probe_paths`.
pub const probe_paths = [_][]const u8{ "/healthz", "/readyz", "/metrics" };

/// Whether `req`'s path (its query aside) is on `list`: equal to an entry,
/// or starting with one that ends in `*` (`/internal/*`).
pub fn excluded(req: *const dusty.Request, list: []const []const u8) bool {
    if (list.len == 0) return false;
    const path = if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
    for (list) |entry| {
        if (entry.len > 0 and entry[entry.len - 1] == '*') {
            if (std.mem.startsWith(u8, path, entry[0 .. entry.len - 1])) return true;
        } else if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

/// The status the client got for this response: the handler's, or for an
/// error the one dusty answers it with (its 4xx for request faults, else
/// 500), unless the head had already gone out, which the error cannot
/// change. An HTTP/2 extended CONNECT (RFC 8441) answered with a 2xx opened
/// its tunnel, as an HTTP/1.1 upgrade does with a 101, and is recorded as
/// the 101, so a WebSocket reads the same on both. An app's own
/// `uncaughtError` may still choose another.
pub fn statusOf(req: *const dusty.Request, res: *const dusty.Response, result: anytype) u16 {
    if (result) |_| {} else |err| if (!res.headers_written) {
        const answer = dusty.clientError(err) orelse return 500;
        return @intCast(@backingInt(answer.status));
    }
    const status: u16 = @intCast(@backingInt(res.status));
    if (req.protocol != null and status >= 200 and status < 300) return 101;
    return status;
}

test "excluded: exact paths, prefixes, the query aside" {
    var req: dusty.Request = .{ .arena = std.testing.allocator, .parser = undefined, .transport = undefined };
    const list: []const []const u8 = &.{ "/healthz", "/internal/*" };
    req.url = "/healthz";
    try std.testing.expect(excluded(&req, list));
    req.url = "/healthz?verbose=1";
    try std.testing.expect(excluded(&req, list));
    req.url = "/healthz/x";
    try std.testing.expect(!excluded(&req, list));
    req.url = "/internal/a/b";
    try std.testing.expect(excluded(&req, list));
    req.url = "/internals";
    try std.testing.expect(!excluded(&req, list));
    req.url = "/users";
    try std.testing.expect(!excluded(&req, list));
    try std.testing.expect(!excluded(&req, &.{}));
    req.url = "/metrics";
    try std.testing.expect(excluded(&req, &probe_paths));
}
