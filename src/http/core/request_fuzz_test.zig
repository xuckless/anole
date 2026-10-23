// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Fuzzing an HTTP/1.x request from the bytes up: llhttp through
//! `parseHeaders`, the body (Content-Length, chunked, a content coding), and
//! what a handler reads off the request (the route and its parameters, the
//! query, form fields, multipart fields, cookies). The bytes go in whole
//! and a few at a time, as a socket might hand them over, and what comes out
//! must be the same either way.
const std = @import("std");
const request_mod = @import("request.zig");
const Request = request_mod.Request;
const RequestParser = @import("parser.zig").RequestParser;
const Response = @import("response.zig").Response;
const Router = @import("router.zig").Router;
const body_read_reserve = @import("config.zig").body_read_reserve;

/// Hands over `source` at most `step` bytes per fill.
const SourceReader = struct {
    source: []const u8,
    pos: usize = 0,
    step: usize,
    interface: std.Io.Reader,

    fn init(source: []const u8, step: usize, buffer: []u8) SourceReader {
        return .{
            .source = source,
            .step = step,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        const self: *SourceReader = @alignCast(@fieldParentPtr("interface", r));
        const rest = self.source[self.pos..];
        if (rest.len == 0) return error.EndOfStream;
        const dest = r.buffer[r.end..];
        const n = @min(dest.len, rest.len, self.step);
        @memcpy(dest[0..n], rest[0..n]);
        r.end += n;
        self.pos += n;
        return 0;
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = r;
        _ = w;
        _ = limit;
        return error.EndOfStream;
    }
};

fn handler(_: *Request, _: *Response) anyerror!void {}

/// Everything the request said, written out.
fn transcript(arena: std.mem.Allocator, raw: []const u8, step: usize, buf_len: usize, router: *const Router(void)) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const buffer = try arena.alloc(u8, buf_len);
    var source = SourceReader.init(raw, step, buffer);
    var req: Request = .{
        .arena = arena,
        ._transport = .{ .reader = &source.interface, .writer = undefined },
        ._parser = undefined,
    };
    var parser: RequestParser = undefined;
    try parser.init(&req);
    defer parser.deinit();
    req._parser = &parser;

    request_mod.parseHeaders(&source.interface, &parser) catch |err| {
        try w.print("head: {t}", .{err});
        return out.written();
    };
    try w.print("{t} {s} {d}.{d}\n", .{ req.method, req.url, req.version_major, req.version_minor });
    for (req.headers.keys[0..req.headers.len], req.headers.values[0..req.headers.len]) |k, v| {
        // What llhttp let through is a token and a field value.
        for (k) |ch| if (ch <= ' ' or ch == ':' or ch >= 0x7f) return error.BadHeaderName;
        for (v) |ch| if (ch == '\r' or ch == '\n' or ch == 0) return error.BadHeaderValue;
        try w.print("{s}: {s}\n", .{ k, v });
    }

    if (req.body()) |body| {
        if (body) |b| try std.testing.expect(b.len <= req._config.max_body_size);
        try w.print("body {?s}\n", .{body});
    } else |err| {
        try w.print("body: {t}\n", .{err});
        return out.written();
    }
    // What the next request on the connection would start with.
    try w.print("rest {s}{s}\n", .{ source.interface.buffered(), source.source[source.pos..] });

    if (req.formData()) |fields| {
        try w.print("form {d}\n", .{fields.count()});
    } else |err| try w.print("form: {t}\n", .{err});
    if (req.multiFormData()) |fields| {
        try w.print("multipart {d}\n", .{fields.count()});
    } else |err| try w.print("multipart: {t}\n", .{err});
    var cookies = req.cookies().iterator();
    while (cookies.next()) |c| try w.print("cookie {s}={s}\n", .{ c.name, c.value });

    if (router.findHandler(&req)) |route| {
        try w.print("route {}\n", .{route != null});
        var params = req.params.map.iterator();
        while (params.next()) |e| {
            // A parameter is a piece of the path.
            try std.testing.expect(std.mem.indexOf(u8, req.url, e.value_ptr.*) != null);
        }
        try w.print("query {d}\n", .{req.query.count()});
    } else |err| try w.print("route: {t}\n", .{err});
    return out.written();
}

test "fuzz: requests through llhttp, whole and a few bytes at a time" {
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var router: Router(void) = .init(std.testing.allocator);
            defer router.deinit();
            router.get("/", handler);
            router.get("/users/:id", handler);
            router.post("/users/:id/posts/:post", handler);
            router.get("/static/*path", handler);

            // The first byte picks the delivery and the buffer, the rest is
            // the connection's bytes.
            const knobs = input[0];
            const raw = input[1..];
            const step = 1 + (knobs & 0x0f);
            const buf_len: usize = body_read_reserve + @as(usize, if (knobs & 0x10 != 0) 256 else 4096);

            const whole = try transcript(arena, raw, raw.len + 1, buf_len, &router);
            const pieces = try transcript(arena, raw, step, buf_len, &router);
            try std.testing.expectEqualStrings(whole, pieces);
        }
    }.check, &.{
        "\x00GET /users/42?debug=true&page=1&q=%41+b HTTP/1.1\r\nHost: example.com\r\nCookie: a=1; b=2\r\n\r\nGET / HTTP/1.1\r\n\r\n",
        "\x03POST /users/7/posts/9 HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 27\r\n\r\ncode=abc&state=xyz%20&x=+1",
        "\x15POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n",
        "\x07POST /static/a/b/c HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=XyZ\r\nContent-Length: 64\r\n\r\n--XyZ\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--XyZ--\r\n",
        "\x02POST / HTTP/1.1\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcbH\xcd\xc9\xc9\x07\x00\x86\xa6\x106\x05\x00\x00\x00",
        "\x01GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
        "\x09PUT /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
    });
}
