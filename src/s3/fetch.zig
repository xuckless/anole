//! Thin helpers over the core HTTP client for the S3 connector.
const std = @import("std");
const dusty = @import("dusty");

pub const Pair = [2][]const u8;

/// Room for the headers of one request.
pub const HeaderStorage = struct {
    pub const max = 48;
    keys: [max][]const u8 = undefined,
    values: [max][]const u8 = undefined,
    hashes: [max]u8 = undefined,

    pub fn headers(self: *HeaderStorage, pairs: []const Pair) error{TooManyHeaders}!dusty.Headers {
        var h: dusty.Headers = .{ .keys = &self.keys, .values = &self.values, .hashes = &self.hashes };
        for (pairs) |p| try h.add(p[0], p[1]);
        return h;
    }
};

pub const BodyReader = blk: {
    const R = @typeInfo(@TypeOf(dusty.ClientResponse.reader)).@"fn".return_type.?;
    break :blk @typeInfo(R).error_union.payload;
};

pub const Method = dusty.Method;

/// One request, the whole response read into `arena` (at most `max_bytes`).
pub const Simple = struct {
    status: u16,
    body: []const u8,
};

pub fn simple(
    client: *dusty.Client,
    arena: std.mem.Allocator,
    url: []const u8,
    method: Method,
    pairs: []const Pair,
    body: ?[]const u8,
    timeout: std.Io.Timeout,
    max_bytes: usize,
) !Simple {
    var st: HeaderStorage = .{};
    const h = try st.headers(pairs);
    var resp = try client.fetch(url, .{
        .method = method,
        .headers = &h,
        .body = body,
        .decompress = false,
        .max_redirects = 0,
        .timeout = timeout,
    });
    defer resp.deinit();
    var buf: [0]u8 = .{};
    var r = try resp.reader(&buf);
    const bytes = r.interface.allocRemaining(arena, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return r.err orelse error.Unexpected,
        else => |e| return e,
    };
    return .{ .status = @intCast(@intFromEnum(resp.status())), .body = bytes };
}
