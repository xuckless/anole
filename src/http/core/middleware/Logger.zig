// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! One access-log line per request, after its handler: method, path,
//! status, time taken, client address and request ID (`req.id`, from the
//! RequestId middleware when it runs first), at info level in scope
//! `access`. A handler that fails is logged with its error. The query
//! string is left out unless `log_query` (it carries tokens and codes).
const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

const log = std.log.scoped(.access);

const Logger = @This();

/// Log the query string with the path.
log_query: bool = false,

/// `init`'s settings.
pub const Options = struct {
    /// Log the query string with the path. Off by default: queries carry
    /// sign-in codes, reset tokens and API keys, which logs keep.
    log_query: bool = false,
};

/// The middleware: `app.use(anole.middleware.Logger.init(.{}))`;
/// `.{ .log_query = true }` logs the query string too. See also
/// `anole.observe.AccessLog`.
pub fn init(options: Options) Logger {
    return .{ .log_query = options.log_query };
}

pub fn execute(self: *const Logger, req: *Request, res: *Response, executor: anytype) !void {
    const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
    executor.next() catch |err| {
        self.line(req, res, start, err);
        return err;
    };
    self.line(req, res, start, null);
}

fn line(self: *const Logger, req: *const Request, res: *const Response, start: std.Io.Clock.Timestamp, err: ?anyerror) void {
    const micros = start.durationTo(.now(req.io, .awake)).raw.toMicroseconds();
    const id = if (req.id.len > 0) req.id else "-";
    const path = if (self.log_query) req.url else if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
    if (err) |e| {
        log.info("{f} {s} error={t} {d}us {f} id={s}", .{ req.method, path, e, micros, req.remote_address, id });
    } else {
        log.info("{f} {s} {d} {d}us {f} id={s}", .{ req.method, path, @backingInt(res.status), micros, req.remote_address, id });
    }
}
