//! Access logs: one line per request, in text or JSON (one object per
//! line, for log shippers), with the request ID and trace ID when the
//! RequestId and tracing middleware run first. Each line is one write, so
//! lines from concurrent requests do not interleave.
//!
//!     app.use(anole.observe.AccessLog.init(.{ .format = .json }));
const std = @import("std");
const dusty = @import("dusty");

pub const Format = enum { text, json };

pub const Options = struct {
    format: Format = .text,
    /// Where lines go; stderr by default.
    file: ?std.Io.File = null,
};

pub const AccessLog = struct {
    options: Options,

    pub fn init(options: Options) AccessLog {
        return .{ .options = options };
    }

    pub fn execute(self: *const AccessLog, req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        const result = executor.next();
        const micros = start.durationTo(.now(req.io, .awake)).raw.toMicroseconds();
        const status = statusOf(res, result);
        const line = format(req.arena, self.options.format, req, status, micros, std.Io.Clock.real.now(req.io).toMilliseconds(), if (result) |_| null else |e| e) catch return result;
        const file = self.options.file orelse std.Io.File.stderr();
        file.writeStreamingAll(req.io, line) catch {};
        return result;
    }
};

/// The status the client gets for this response: the handler's, or for an
/// error the one dusty answers it with (its 4xx for request faults, else
/// 500). An app's own `uncaughtError` may still choose another.
pub fn statusOf(res: *const dusty.Response, result: anytype) u16 {
    if (result) |_| return @intCast(@backingInt(res.status)) else |err| {
        const answer = dusty.clientError(err) orelse return 500;
        return @intCast(@backingInt(answer.status));
    }
}

pub fn format(arena: std.mem.Allocator, fmt: Format, req: *const dusty.Request, status: u16, micros: i64, now_ms: i64, err: ?anyerror) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var mbuf: [16]u8 = undefined;
    const method = std.fmt.bufPrint(&mbuf, "{f}", .{req.method}) catch "?";
    var abuf: [64]u8 = undefined;
    const addr = std.fmt.bufPrint(&abuf, "{f}", .{req.remote_address}) catch "?";
    switch (fmt) {
        .text => {
            try w.print("{s} {s} {d} {d}us {s}", .{ method, req.url, status, micros, addr });
            if (req.id.len > 0) try w.print(" id={s}", .{req.id});
            if (req.trace_id.len > 0) try w.print(" trace={s}", .{req.trace_id});
            if (err) |e| try w.print(" error={t}", .{e});
        },
        .json => {
            try w.print("{{\"ts\":{d},\"method\":\"{s}\",\"path\":{f},\"status\":{d},\"duration_us\":{d},\"client\":\"{s}\"", .{ now_ms, method, std.json.fmt(req.url, .{}), status, micros, addr });
            if (req.route) |r| try w.print(",\"route\":{f}", .{std.json.fmt(r.path, .{})});
            if (req.id.len > 0) try w.print(",\"request_id\":\"{s}\"", .{req.id});
            if (req.trace_id.len > 0) try w.print(",\"trace_id\":\"{s}\",\"span_id\":\"{s}\"", .{ req.trace_id, req.span_id });
            if (err) |e| try w.print(",\"error\":\"{t}\"", .{e});
            try w.writeByte('}');
        },
    }
    try w.writeByte('\n');
    return out.written();
}
