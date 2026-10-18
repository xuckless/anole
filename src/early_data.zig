//! Early data (TLS 1.3 / QUIC 0-RTT) and replays, after RFC 8470.
//!
//! A request sent in early data can be replayed by anyone who recorded it,
//! until the handshake it came with completes. Two places mark such a
//! request with `Early-Data: 1`: a proxy that took it in early data and
//! forwards it (RFC 8470 §5.1), and Anole's HTTP/3 endpoint when it runs a
//! GET, HEAD or OPTIONS that came in 0-RTT before the handshake completed
//! (its other methods wait for the handshake, so they are never marked).
//! `isEarly` reads the mark.
//!
//! `Guard` answers 425 Too Early to unsafe requests that carry the mark,
//! as RFC 8470 §5.1 requires: waiting cannot make them safe, since the
//! early part happened on an earlier hop. `anole.Server` runs it on every
//! route. `TooEarly` answers 425 to any marked request, for a route whose
//! GET has effects that must not repeat; the client retries once its
//! handshake is done (RFC 8470 §5.2).
const std = @import("std");
const dusty = @import("dusty");

/// The request header that marks early data.
pub const header = "Early-Data";

/// Whether the request may be a replay of early data: it carries
/// `Early-Data` (only "1" is defined, and any value counts).
pub fn isEarly(req: *const dusty.Request) bool {
    return req.headers.get(header) != null;
}

/// GET, HEAD and OPTIONS: the methods Anole runs from early data.
pub fn isSafe(method: dusty.Method) bool {
    return switch (method) {
        .get, .head, .options => true,
        else => false,
    };
}

fn tooEarly(res: *dusty.Response) void {
    res.status = .too_early;
    res.content_type = .text;
    res.body = "425 Too Early\n";
}

/// 425 for unsafe requests marked as early data (RFC 8470 §5.1).
/// `anole.Server` adds it to every route.
pub const Guard = struct {
    pub fn execute(_: *const Guard, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        if (isEarly(req) and !isSafe(req.method)) return tooEarly(res);
        return executor.next();
    }
};

/// 425 for every request marked as early data: for routes that must not
/// run before the client's handshake completes, whatever the method.
///
///     const pay = app.group("/pay", .{anole.early_data.TooEarly{}});
pub const TooEarly = struct {
    pub fn execute(_: *const TooEarly, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        if (isEarly(req)) return tooEarly(res);
        return executor.next();
    }
};

test "early data: unsafe marked requests get 425, safe ones and unmarked ones go on" {
    const zio = @import("zio");
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();

    const Handlers = struct {
        fn ok(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "ran";
        }
    };
    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    var guard: Guard = .{};
    var too_early: TooEarly = .{};
    server.router.use(dusty.Middleware(void).init(&guard));
    server.router.get("/", Handlers.ok);
    server.router.post("/", Handlers.ok);
    const strict = server.router.group("/strict", &.{dusty.Middleware(void).init(&too_early)});
    strict.get("", Handlers.ok);

    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const cases = [_]struct { request: []const u8, status: []const u8 }{
        .{ .request = "GET / HTTP/1.1\r\nHost: x\r\nEarly-Data: 1\r\n\r\n", .status = "200" },
        .{ .request = "POST / HTTP/1.1\r\nHost: x\r\nEarly-Data: 1\r\nContent-Length: 0\r\n\r\n", .status = "425" },
        .{ .request = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .status = "200" },
        .{ .request = "GET /strict HTTP/1.1\r\nHost: x\r\nEarly-Data: 1\r\n\r\n", .status = "425" },
        .{ .request = "GET /strict HTTP/1.1\r\nHost: x\r\n\r\n", .status = "200" },
    };
    for (cases) |case| {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(case.request);
        try writer.interface.flush();
        var read_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        try std.testing.expectEqualStrings(case.status, line["HTTP/1.1 ".len..][0..3]);
    }
}
