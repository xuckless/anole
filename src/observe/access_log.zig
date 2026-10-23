//! Access logs: one line per request, in text or JSON (one object per
//! line, for log shippers), with the request ID and trace ID when the
//! RequestId and tracing middleware run first. Each line is one write, so
//! lines from concurrent requests do not interleave. The JSON line is the
//! same record the rest of Anole's logs are (`time`, `level`, `scope`,
//! `message`, `request_id`, `trace_id`, `span_id`), plus `method`, `path`,
//! `route`, `status`, `duration_us`, `client` and `error`. Without a file,
//! lines go where the logs go: stderr, or the C ABI's log callback.
//!
//!     app.use(anole.observe.AccessLog.init(.{}));   // the log format follows the environment
const std = @import("std");
const dusty = @import("dusty");
const anole_log = @import("anole_log");
const common = @import("common.zig");

/// `text`: `GET /users/42 200 153us 10.0.0.7:51234 id=...`; `json`: one
/// record per line with the same fields.
pub const Format = enum { text, json };

/// `AccessLog` settings.
pub const Options = struct {
    /// Null: follows `anole.log`'s format (JSON in production by default).
    format: ?Format = null,
    /// Where lines go; stderr by default.
    file: ?std.Io.File = null,
    /// Paths not logged: exact, or a prefix when the entry ends in `*`.
    /// `&anole.observe.probe_paths` leaves out health checks and scrapes.
    exclude: []const []const u8 = &.{},
    /// Log the query string with the path. Off by default: queries carry
    /// sign-in codes, reset tokens and API keys, which logs keep.
    log_query: bool = false,
};

/// The access log middleware. Put it first among `use` calls (after
/// `RequestId`) so the time it records covers the rest.
pub const AccessLog = struct {
    options: Options,

    /// The middleware for `options`.
    pub fn init(options: Options) AccessLog {
        return .{ .options = options };
    }

    /// A detached response (`dusty.Detached`) is logged when it is
    /// finished.
    pub const detach_safe = true;

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const AccessLog, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        if (common.excluded(req, self.options.exclude)) return next.call();
        const start: std.Io.Clock.Timestamp = .now(req.io, .awake);
        const result = next.call();
        if (res.isDetached()) {
            const later = try req.arena.create(Later);
            later.* = .{ .log = self, .start = start };
            res.onFinish(&later.finisher);
            return result;
        }
        return self.write(req, res, result, start);
    }

    /// The line of a detached response, written once it is finished.
    const Later = struct {
        finisher: dusty.Detached.Finisher = .{ .func = run },
        log: *const AccessLog,
        start: std.Io.Clock.Timestamp,

        fn run(f: *dusty.Detached.Finisher, req: *dusty.Request, res: *dusty.Response, result: anyerror!void) void {
            const later: *Later = @alignCast(@fieldParentPtr("finisher", f));
            later.log.write(req, res, result, later.start) catch {};
        }
    };

    fn write(self: *const AccessLog, req: *dusty.Request, res: *dusty.Response, result: anyerror!void, start: std.Io.Clock.Timestamp) anyerror!void {
        const micros = start.durationTo(.now(req.io, .awake)).raw.toMicroseconds();
        const status = statusOf(req, res, result);
        const fmt: Format = self.options.format orelse (if (anole_log.currentFormat() == .json) .json else .text);
        const line = formatLine(req.arena, .{ .format = fmt, .log_query = self.options.log_query }, req, status, micros, std.Io.Clock.real.now(req.io).toMilliseconds(), if (result) |_| null else |e| e) catch return result;
        if (self.options.file) |file| {
            file.writeStreamingAll(req.io, line) catch |err| switch (err) {
                // The request's cancel (its deadline, the drain) is for what runs next.
                error.Canceled => req.io.recancel(),
                else => {},
            };
        } else {
            // To the log sink (stderr, or the C ABI's callback), one line.
            anole_log.writeRaw(.info, "access", std.mem.trimEnd(u8, line, "\n"));
        }
        return result;
    }
};

/// The status the client got, as the access log records it:
/// `statusOf(req, res, result)` with `result` what the rest of the chain
/// returned. For an error, the status the server answers it with
/// (`anole.errorStatus`, else 500), unless the head had already gone out.
pub const statusOf = common.statusOf;

/// One log line for `req`, ending in a newline, in `arena`: what the
/// middleware writes, for a logger of your own. The query is left out
/// (`formatLine` with `log_query` keeps it).
pub fn format(arena: std.mem.Allocator, fmt: Format, req: *const dusty.Request, status: u16, micros: i64, now_ms: i64, err: ?anyerror) ![]const u8 {
    return formatLine(arena, .{ .format = fmt }, req, status, micros, now_ms, err);
}

/// `formatLine`'s settings.
pub const LineOptions = struct {
    format: Format = .text,
    /// Keep the query string after the path.
    log_query: bool = false,
};

/// `req`'s target as logged: the path, and the query only with
/// `log_query`.
pub fn target(req: *const dusty.Request, log_query: bool) []const u8 {
    if (log_query) return req.url;
    return if (std.mem.indexOfScalar(u8, req.url, '?')) |q| req.url[0..q] else req.url;
}

/// `format` with `LineOptions`.
pub fn formatLine(arena: std.mem.Allocator, opts: LineOptions, req: *const dusty.Request, status: u16, micros: i64, now_ms: i64, err: ?anyerror) ![]const u8 {
    const fmt = opts.format;
    const path = target(req, opts.log_query);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var mbuf: [16]u8 = undefined;
    const method = std.fmt.bufPrint(&mbuf, "{f}", .{req.method}) catch "?";
    var abuf: [64]u8 = undefined;
    const addr = std.fmt.bufPrint(&abuf, "{f}", .{req.remote_address}) catch "?";
    switch (fmt) {
        .text => {
            try w.print("{s} {s} {d} {d}us {s}", .{ method, path, status, micros, addr });
            if (req.id.len > 0) try w.print(" id={s}", .{req.id});
            if (req.trace_id.len > 0) try w.print(" trace={s}", .{req.trace_id});
            if (err) |e| try w.print(" error={t}", .{e});
        },
        .json => {
            // The record's own members after its head: what the request was.
            var frag: std.Io.Writer.Allocating = .init(arena);
            const fw = &frag.writer;
            try fw.print(",\"method\":\"{s}\",\"path\":{f}", .{ method, std.json.fmt(path, .{}) });
            if (req.route) |r| try fw.print(",\"route\":{f}", .{std.json.fmt(r.path, .{})});
            try fw.print(",\"status\":{d},\"duration_us\":{d},\"client\":\"{s}\"", .{ status, micros, addr });
            if (err) |e| try fw.print(",\"error\":\"{t}\"", .{e});
            const message = try std.fmt.allocPrint(arena, "{s} {s} {d}", .{ method, path, status });
            const ctx: anole_log.Context = .{ .request_id = req.id, .trace_id = req.trace_id, .span_id = req.span_id };
            // Room for the head, with every string escaped at its worst.
            const cap = frag.written().len + 6 * (message.len + req.id.len + req.trace_id.len + req.span_id.len) + 512;
            const buf = try arena.alloc(u8, @min(cap, 64 * 1024));
            try w.writeAll(anole_log.renderJson(buf, now_ms, .info, "access", ctx, message, frag.written()));
        },
    }
    try w.writeByte('\n');
    return out.written();
}
