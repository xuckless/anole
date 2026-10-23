// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Gives every request an ID (`req.id`) and echoes it on the response, so a
//! log line, a trace and a user's bug report can be matched up. The ID is
//! 128 random bits in hex, unless `trust_incoming` is set and the request
//! brings one in `header` already (from a proxy or gateway in front that
//! assigned it).
const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

/// `RequestId.init`'s settings.
pub const Options = struct {
    /// The header the ID is read from (with `trust_incoming`) and sent in.
    header: []const u8 = "X-Request-Id",
    /// Reuse an incoming ID. Only for a server reachable solely through a
    /// proxy that sets or strips the header, or a client picks its own. An
    /// ID of anything but 1 to 128 letters, digits and `. _ : -` is
    /// replaced by a fresh one.
    trust_incoming: bool = false,
};

header: []const u8,
trust_incoming: bool,

const RequestId = @This();

/// The middleware: `app.use(anole.middleware.RequestId.init(.{}))`.
pub fn init(config: Options) RequestId {
    return .{ .header = config.header, .trust_incoming = config.trust_incoming };
}

/// Only sets the ID before `next()`: requests behind it can detach
/// (`Detached`).
pub const detach_safe = true;

/// Never waits: no I/O, so `no_wait` routes may sit behind it.
pub const no_wait = true;

pub fn execute(self: *const RequestId, req: *Request, res: *Response, next: anytype) !void {
    req.id = if (self.trust_incoming) incoming(req, self.header) orelse try generate(req) else try generate(req);
    try res.header(self.header, req.id);
    return next.call();
}

/// An incoming ID worth keeping: one that `validIncoming` accepts.
fn incoming(req: *const Request, header: []const u8) ?[]const u8 {
    const value = req.headers.get(header) orelse return null;
    return if (validIncoming(value)) value else null;
}

/// 1 to 128 of letters, digits and `. _ : -`: what UUIDs, trace IDs and
/// proxies' request IDs are made of, and nothing that could mean
/// something in a log line, JSON or a header.
fn validIncoming(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', ':', '-' => {},
        else => return false,
    };
    return true;
}

fn generate(req: *Request) ![]const u8 {
    var bytes: [16]u8 = undefined;
    req.io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return req.arena.dupe(u8, &hex);
}

test "incoming: only IDs made of letters, digits and . _ : -" {
    try std.testing.expect(validIncoming("4bf92f35-77b3:4da6.a3ce_929d"));
    try std.testing.expect(!validIncoming(""));
    try std.testing.expect(!validIncoming("a\"b"));
    try std.testing.expect(!validIncoming("a\\b"));
    try std.testing.expect(!validIncoming("a b"));
    try std.testing.expect(!validIncoming("<script>"));
    try std.testing.expect(!validIncoming(&@as([129]u8, @splat('a'))));
}
