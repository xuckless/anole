//! Seams the live console (src/console) installs into the request path. The
//! core imports nothing of it: a function pointer and one counter. Nothing
//! installed (or no console attached) costs one load and a predicted branch
//! per request.
const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const RequestEnd = *const fn (req: *Request, res: *Response, err: ?anyerror, start_ns: u64) void;

/// Set once by the console before the server serves; null: no console.
pub var request_end: ?RequestEnd = null;

/// Consoles that subscribed to per-route statistics. Written on attach and
/// detach only.
pub var collecting: std.atomic.Value(u32) = .init(0);

pub inline fn now(io: std.Io) u64 {
    return @truncate(@as(u96, @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds))));
}

/// The start time of a request's handler, or 0 when nobody is collecting.
pub inline fn begin(io: std.Io) u64 {
    if (request_end == null) return 0;
    if (collecting.load(.monotonic) == 0) return 0;
    return now(io);
}

/// After the handler chain ran: `result` is what it returned.
pub inline fn end(req: *Request, res: *Response, result: anytype, start_ns: u64) void {
    const f = request_end orelse return;
    f(req, res, if (result) |_| null else |e| e, start_ns);
}
