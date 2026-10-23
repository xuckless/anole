//! Downloads: a streamed GET with an idle bound, and `serve` (design-connectors.md S11).
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const root = @import("root.zig");
const fetch = @import("fetch.zig");
const util = @import("util.zig");

const Error = root.Error;
const Meta = root.Meta;
const Bucket = root.Bucket;
const Client = root.Client;
const Duration = std.Io.Duration;

/// Bytes the reader of a download buffers.
pub const read_buffer_len = 64 * 1024;

/// Wraps the body reader so that each read waits at most `timeout` for the
/// peer: past it the read fails (`error.GatewayTimeout`) and the connection
/// is dropped. The whole transfer has no total bound, only this idle one.
const IdleReader = struct {
    interface: std.Io.Reader,
    inner: *std.Io.Reader,
    io: std.Io,
    timeout: ?Duration,
    err: ?anyerror = null,

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *IdleReader = @alignCast(@fieldParentPtr("interface", r));
        const t = self.timeout orelse return self.inner.stream(w, limit);
        const deadline: dusty.Deadline = .init(self.io, .{ .duration = .{ .raw = t, .clock = .awake } });
        return deadline.run(innerStream, .{ self, w, limit }) catch |err| switch (err) {
            error.Timeout => {
                self.err = error.GatewayTimeout;
                return error.ReadFailed;
            },
            error.Canceled => {
                self.err = error.Canceled;
                return error.ReadFailed;
            },
            error.EndOfStream => return error.EndOfStream,
            error.WriteFailed => return error.WriteFailed,
            error.ReadFailed => return error.ReadFailed,
        };
    }

    fn innerStream(self: *IdleReader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        return self.inner.stream(w, limit);
    }
};

const State = struct {
    resp: dusty.ClientResponse,
    body: fetch.BodyReader,
    idle: IdleReader,
    empty: std.Io.Reader,
    no_body: bool,
    released: bool = false,
};

/// A body being read: `reader()` until the end, then `deinit()` (also on
/// error paths; an unread rest closes the connection).
pub const Download = struct {
    meta: Meta,
    state: *State,

    pub fn reader(self: *Download) *std.Io.Reader {
        if (self.state.no_body) return &self.state.empty;
        return &self.state.idle.interface;
    }

    /// What a failed read was: `error.GatewayTimeout` (idle past the
    /// timeout), `error.Canceled`, or a transport error's name.
    pub fn readError(self: *const Download) ?anyerror {
        return self.state.idle.err orelse self.state.body.err;
    }

    /// The whole rest into `w` (a response's stream writer).
    pub fn pipe(self: *Download, w: *std.Io.Writer) Error!u64 {
        const n = self.reader().streamRemaining(w) catch |err| switch (err) {
            error.ReadFailed => {
                if (self.state.idle.err) |e| {
                    if (e == error.Canceled) return error.Canceled;
                    if (e == error.GatewayTimeout) return error.GatewayTimeout;
                }
                return error.ServiceUnavailable;
            },
            error.WriteFailed => return error.ServiceUnavailable,
        };
        return n;
    }

    /// Gives the connection back (closing it when the body was not all read).
    pub fn deinit(self: *Download) void {
        if (self.state.released) return;
        self.state.released = true;
        self.state.resp.deinit();
    }
};

fn newDownload(client: *Client, c: anytype, reply: root.Reply) Error!Download {
    const st = try c.arena.create(State);
    st.* = .{
        .resp = reply.resp.?,
        .body = undefined,
        .idle = undefined,
        .empty = std.Io.Reader.fixed(""),
        .no_body = reply.meta.not_modified,
    };
    if (!st.no_body) {
        var none: [0]u8 = .{};
        st.body = st.resp.reader(&none) catch |err| {
            st.resp.deinit();
            return client.failOur(c, .unavailable, "transport", @errorName(err));
        };
        const buf = try c.arena.alloc(u8, read_buffer_len);
        st.idle = .{
            .interface = .{
                .vtable = &.{ .stream = IdleReader.streamFn },
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
            .inner = &st.body.interface,
            .io = client.io,
            .timeout = internal.callTimeout(null, client.timeout),
        };
    } else {
        st.body = undefined;
        st.idle = undefined;
    }
    return .{ .meta = reply.meta, .state = st };
}

pub fn open(b: Bucket, c: anytype, key: []const u8, opts: root.GetOptions) Error!Download {
    const bucket = try b.bucketName(c);
    const cl = b.client;
    var hl: root.Headers = .{};
    try cl.getHeaders(c, &hl, opts);
    const query: []const root.Header = if (opts.version_id) |v| try c.arena.dupe(root.Header, &.{.{ "versionId", v }}) else &.{};
    const reply = try cl.execute(c, .{
        .name = "GetObject",
        .method = .get,
        .bucket = bucket,
        .key = key,
        .query = query,
        .headers = hl.slice(),
        .want = .stream,
        .allow_304 = true,
    }, b.call);
    return newDownload(cl, c, reply);
}

/// Headers of the request that go to S3 as they are.
const forwarded = [_][]const u8{ "If-None-Match", "If-Match", "If-Modified-Since", "If-Unmodified-Since" };

pub fn serve(b: Bucket, req: *anole.Request, res: *anole.Response, key: []const u8, opts: root.ServeOptions) Error!Meta {
    const bucket = try b.bucketName(req);
    const cl = b.client;
    var hl: root.Headers = .{};
    const is_head = req.method == .head;
    if (opts.conditional) {
        const has_if_range = req.headers.get("If-Range") != null;
        if (!has_if_range) if (req.headers.get("Range")) |r| hl.add("Range", r) catch return error.OutOfMemory;
        for (forwarded) |name| if (req.headers.get(name)) |v| hl.add(name, v) catch return error.OutOfMemory;
    }
    const query: []const root.Header = if (opts.version_id) |v| try req.arena.dupe(root.Header, &.{.{ "versionId", v }}) else &.{};
    const reply = cl.execute(req, .{
        .name = if (is_head) "HeadObject" else "GetObject",
        .method = if (is_head) .head else .get,
        .bucket = bucket,
        .key = key,
        .query = query,
        .headers = hl.slice(),
        .want = if (is_head) .none else .stream,
        .allow_304 = true,
    }, b.call) catch |err| {
        // The service's own refusals of a conditional or ranged request go
        // through to the client as they are.
        if (internal.lastError(req)) |d| {
            if (d.class == .precondition and std.mem.eql(u8, d.code, "PreconditionFailed")) {
                res.status = .precondition_failed;
                return .{ .status = 412 };
            }
            if (d.class == .invalid and std.mem.eql(u8, d.code, "InvalidRange")) {
                res.status = .range_not_satisfiable;
                return .{ .status = 416 };
            }
        }
        return err;
    };
    var dl: ?Download = if (is_head) null else try newDownload(cl, req, reply);
    defer if (dl) |*d| d.deinit();
    const meta = reply.meta;

    res.status = if (meta.status == 206) .partial_content else if (meta.status == 304) .not_modified else .ok;
    if (opts.content_type orelse meta.content_type) |v| try hdr(res, "Content-Type", v);
    if (opts.cache_control orelse meta.cache_control) |v| try hdr(res, "Cache-Control", v);
    if (opts.content_disposition orelse meta.content_disposition) |v| try hdr(res, "Content-Disposition", v);
    if (meta.content_encoding) |v| try hdr(res, "Content-Encoding", v);
    if (meta.etag.len > 0) try hdr(res, "ETag", meta.etag);
    if (meta.last_modified) |t| {
        var buf: [29]u8 = undefined;
        try hdr(res, "Last-Modified", try req.arena.dupe(u8, util.formatHttpDate(&buf, t.toSeconds())));
    }
    try hdr(res, "Accept-Ranges", "bytes");
    if (meta.status == 206 and meta.content_length > 0) {
        const text = try std.fmt.allocPrint(req.arena, "bytes {d}-{d}/{d}", .{ meta.range_start, meta.range_start + meta.content_length - 1, meta.size });
        try hdr(res, "Content-Range", text);
    }
    if (meta.not_modified) {
        res.body = "";
        return meta;
    }
    try hdr(res, "Content-Length", try std.fmt.allocPrint(req.arena, "{d}", .{meta.content_length}));
    if (is_head) {
        res.body = "";
        return meta;
    }
    const buf = try req.arena.alloc(u8, 64 * 1024);
    var w = res.stream(buf) catch |err| return mapRespErr(err);
    if (dl) |*d| {
        _ = d.pipe(&w.interface) catch |err| {
            // The head is out: the only honest end is to drop the connection.
            _ = res.abort() catch {};
            return err;
        };
    }
    w.end() catch |err| return mapRespErr(err);
    return meta;
}

fn hdr(res: *anole.Response, name: []const u8, value: []const u8) Error!void {
    res.header(name, value) catch return error.OutOfMemory;
}

fn mapRespErr(_: anyerror) Error {
    return error.ServiceUnavailable;
}
