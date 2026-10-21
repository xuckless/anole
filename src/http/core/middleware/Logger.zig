// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! One access-log line per request, after its handler: method, path,
//! status, time taken, client address and request ID (`req.id`, from the
//! RequestId middleware when it runs first), at info level in scope
//! `access`. A handler that fails is logged with its error.
const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const log = std.log.scoped(.access);

const Logger = @This();

/// The middleware: `app.use(anole.middleware.Logger.init())`. See also
/// `anole.observe.AccessLog`.
pub fn init() Logger {
    return .{};
}

pub fn execute(_: *const Logger, req: *Request, res: *Response, executor: anytype) !void {
    const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
    executor.next() catch |err| {
        line(req, res, start, err);
        return err;
    };
    line(req, res, start, null);
}

fn line(req: *const Request, res: *const Response, start: std.Io.Clock.Timestamp, err: ?anyerror) void {
    const micros = start.durationTo(.now(req.io, .awake)).raw.toMicroseconds();
    const id = if (req.id.len > 0) req.id else "-";
    if (err) |e| {
        log.info("{f} {s} error={t} {d}us {f} id={s}", .{ req.method, req.url, e, micros, req.remote_address, id });
    } else {
        log.info("{f} {s} {d} {d}us {f} id={s}", .{ req.method, req.url, @backingInt(res.status), micros, req.remote_address, id });
    }
}
