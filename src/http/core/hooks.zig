//! Seams the live console (src/console) installs into the request path. The
//! core imports nothing of it: a function pointer and one counter. With no
//! console collecting (none installed, or one with nobody attached) a
//! request costs one relaxed load in `begin` and, in `end`, a test of the
//! status the handler left (the result's error test the caller makes
//! anyway): only an answer that may be a 5xx reaches the console then, for
//! its always-on 5xx ring (design D10).
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
/// One relaxed load: `collecting` is non-zero only after the console
/// installed `request_end`.
pub inline fn begin(io: std.Io) u64 {
    if (collecting.load(.monotonic) == 0) return 0;
    return now(io);
}

/// After the handler chain ran: `result` is what it returned. `start_ns`
/// is `begin`'s: non-zero only while a console collects.
pub inline fn end(req: *Request, res: *Response, result: anytype, start_ns: u64) void {
    // Nobody collecting and no possible 5xx: the common path, before
    // anything else is loaded. A detached response left here keeps its
    // `console_start_ns` of 0, which is `start_ns`.
    if (start_ns == 0 and !mayBe5xx(res, result)) return;
    // A detached response has no answer yet: `finished` reports it.
    if (res.detached) |d| {
        d.console_start_ns = start_ns;
        return;
    }
    const f = request_end orelse return;
    f(req, res, if (result) |_| null else |e| e, start_ns);
}

/// A detached response's answer is known (`Detached.finish`, after its
/// `onFinish` work): as `end` would have reported it.
pub inline fn finished(d: anytype, result: anyerror!void) void {
    const start_ns: u64 = d.console_start_ns;
    if (start_ns == 0 and !mayBe5xx(d.response, result)) return;
    const f = request_end orelse return;
    f(d.request, d.response, if (result) |_| null else |e| e, start_ns);
}

inline fn mayBe5xx(res: *const Response, result: anytype) bool {
    if (result) |_| {} else |_| return true;
    return @backingInt(res.status) >= 500;
}
