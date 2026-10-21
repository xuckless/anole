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

pub const Config = struct {
    header: []const u8 = "X-Request-Id",
    /// Reuse an incoming ID. Only for a server reachable solely through a
    /// proxy that sets or strips the header, or a client picks its own.
    trust_incoming: bool = false,
};

header: []const u8,
trust_incoming: bool,

const RequestId = @This();

pub fn init(config: Config) RequestId {
    return .{ .header = config.header, .trust_incoming = config.trust_incoming };
}

pub fn execute(self: *const RequestId, req: *Request, res: *Response, executor: anytype) !void {
    req.id = if (self.trust_incoming) incoming(req, self.header) orelse try generate(req) else try generate(req);
    try res.header(self.header, req.id);
    return executor.next();
}

/// An incoming ID worth keeping: short, and visible ASCII only, so it
/// cannot smuggle anything into a log line or a header.
fn incoming(req: *const Request, header: []const u8) ?[]const u8 {
    const value = req.headers.get(header) orelse return null;
    if (value.len == 0 or value.len > 128) return null;
    for (value) |ch| if (ch < 0x21 or ch > 0x7e) return null;
    return value;
}

fn generate(req: *Request) ![]const u8 {
    var bytes: [16]u8 = undefined;
    req.io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return req.arena.dupe(u8, &hex);
}
