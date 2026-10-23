// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const Request = @import("request.zig").Request;
pub const WebSocket = @import("websocket.zig").WebSocket;
const WebSocketModule = @import("websocket.zig");
pub const CookieOpts = @import("cookie.zig").CookieOpts;
const serializeCookie = @import("cookie.zig").serializeCookie;
const Connection = @import("server.zig").Connection;
const Adopter = @import("server.zig").Adopter;
pub const Sink = @import("sink.zig").Sink;
pub const Detached = @import("detach.zig").Detached;
pub const Parked = @import("parked.zig").Parked;
const Parked_H1 = @import("parked.zig").H1Parked;
const zlib = @import("zlib");
const build_options = @import("build_options");
const ErrorFormat = @import("config.zig").ErrorFormat;
const statusBody = @import("middleware.zig").statusBody;
const zstd_io = if (build_options.use_zstd) @import("zstd_io.zig") else struct {};
const brotli_io = if (build_options.use_brotli) @import("brotli_io.zig") else struct {};
const block_cache = @import("block_cache.zig");
const json_out = @import("json_out.zig");

var no_buf: [0]u8 = .{};

pub const EventWriter = struct {
    body: *StreamingBodyWriter,
    line_in_progress: bool,
    /// The last write ended in a CR, so an LF that starts the next one
    /// belongs to it (one CRLF line break, split across the writes).
    pending_cr: bool = false,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed` that the
    /// `std.Io.Writer` interface has to return. An event long enough to
    /// outgrow the stream's buffer reaches the connection while it is
    /// being written, so a caller filling one from a template finds out
    /// here what went wrong rather than only that something did.
    ///
    /// Everything here writes through the stream underneath, so this is
    /// that writer's answer carried up rather than a second one.
    err: ?Error = null,

    /// What the stream underneath can fail with.
    pub const Error = StreamingBodyWriter.Error;

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *EventWriter = @fieldParentPtr("interface", w);
        const total = writeSegments(self, data, splat) catch |err| switch (err) {
            error.WriteFailed => {
                self.err = self.body.err;
                return error.WriteFailed;
            },
        };
        return w.consume(total);
    }

    fn writeSegments(self: *EventWriter, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |segment| {
            try writeLines(self, segment);
            total += segment.len;
        }
        if (splat > 0) {
            try writeLines(self, data[data.len - 1]);
            total += data[data.len - 1].len;
        }
        return total;
    }

    /// CR, LF and CRLF each end a line, as they do for the peer's parser
    /// (WHATWG HTML 9.2.6): data that could end one any other way would
    /// start a line of its own that is not `data:`.
    fn writeLines(self: *EventWriter, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const out = &self.body.interface;
        var rest = bytes;
        if (self.pending_cr) {
            self.pending_cr = false;
            if (rest[0] == '\n') rest = rest[1..];
        }
        while (std.mem.indexOfAny(u8, rest, "\r\n")) |idx| {
            if (!self.line_in_progress) try out.writeAll("data: ");
            try out.writeAll(rest[0..idx]);
            try out.writeAll("\n");
            self.line_in_progress = false;
            var next = idx + 1;
            if (rest[idx] == '\r') {
                if (next == rest.len) {
                    self.pending_cr = true;
                } else if (rest[next] == '\n') next += 1;
            }
            rest = rest[next..];
        }
        if (rest.len > 0) {
            if (!self.line_in_progress) {
                try out.writeAll("data: ");
                self.line_in_progress = true;
            }
            try out.writeAll(rest);
        }
    }

    /// Closes the event and puts it on the wire. Must be called before the
    /// stream is used again.
    pub fn end(self: *EventWriter) Error!void {
        self.finish() catch |err| switch (err) {
            // Nothing to store: `err` is for the cause `drain` cannot
            // return, and this one goes back to the caller.
            error.WriteFailed => return self.body.err orelse error.Unexpected,
        };
    }

    fn finish(self: *EventWriter) std.Io.Writer.Error!void {
        try self.interface.flush();
        const out = &self.body.interface;
        if (self.line_in_progress) try out.writeAll("\n");
        try out.writeAll("\n");
        return out.flush();
    }
};

/// A Server-Sent Events body. The length is not known up front, so the
/// body is chunked: one chunk per event, and a terminator at the end. The
/// peer can then tell a stream that finished from one that was cut, and
/// the connection outlives the stream.
pub const EventStream = struct {
    body: StreamingBodyWriter,

    /// What sending an event can fail with.
    pub const Error = StreamingBodyWriter.Error || error{InvalidEventField};

    pub const Options = struct {
        event: ?[]const u8 = null,
        id: ?[]const u8 = null,
        retry: ?u32 = null,

        /// A CR or LF in either field would close the line early and let
        /// whoever supplied it write the rest of the event itself.
        pub fn validate(self: Options) error{InvalidEventField}!void {
            if (self.event) |e| if (std.mem.indexOfAny(u8, e, "\r\n") != null) return error.InvalidEventField;
            if (self.id) |id| if (std.mem.indexOfAny(u8, id, "\r\n") != null) return error.InvalidEventField;
        }
    };

    /// Opens an event whose data is written as it is produced. Call `end`
    /// on the result before touching the stream again.
    pub fn startSend(self: *EventStream, opts: Options) Error!EventWriter {
        try opts.validate();
        try self.body.res.resolve(sendFields(&self.body.interface, opts));
        return .{
            .body = &self.body,
            .line_in_progress = false,
            // Unbuffered: the stream underneath is the buffer, and holding
            // bytes here would only copy them twice.
            .interface = .{ .buffer = &no_buf, .vtable = &.{ .drain = &EventWriter.drain } },
        };
    }

    /// A comment line (": text\n\n"): a heartbeat that keeps proxies from
    /// closing an idle stream; browsers ignore it.
    pub fn comment(self: *EventStream, text: []const u8) Error!void {
        if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidEventField;
        return self.body.res.resolve(sendComment(&self.body.interface, text));
    }

    fn sendComment(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        try w.print(": {s}\n\n", .{text});
        return w.flush();
    }

    /// Ends the stream (the body's last chunk). Call before returning.
    pub fn end(self: *EventStream) StreamingBodyWriter.Error!void {
        return self.body.end();
    }

    /// Whether the server is draining: send a last event and `end`.
    pub fn draining(self: *const EventStream) bool {
        const req = self.body.res._request orelse return false;
        const event = req.drain orelse return false;
        return event.isSet();
    }

    /// Sends one complete event.
    pub fn send(self: *EventStream, data: []const u8, opts: Options) Error!void {
        try opts.validate();
        return self.body.res.resolve(sendEvent(&self.body.interface, data, opts));
    }

    /// The fields that precede the data. Reports the sentinel, as anything
    /// writing to a `std.Io.Writer` does; the public entry points resolve it.
    pub fn sendFields(w: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
        if (opts.event) |e| try w.print("event: {s}\n", .{e});
        if (opts.id) |id| try w.print("id: {s}\n", .{id});
        if (opts.retry) |r| try w.print("retry: {d}\n", .{r});
    }

    fn sendEvent(w: *std.Io.Writer, data: []const u8, opts: Options) std.Io.Writer.Error!void {
        try writeEvent(w, data, opts);
        // One event, one write: an event held back is an event the peer
        // has not had, and the next one may be a long way off.
        return w.flush();
    }
};

/// One event as bytes: the fields (`event:`, `id:`, `retry:`), a `data:`
/// line per CR, LF or CRLF in `data`, and the blank line that ends it.
/// Nothing is flushed. The one encoder, for `EventStream` and `anole.sse`.
/// The fields must not hold CR or LF (`EventStream.Options.validate`).
pub fn writeEvent(w: *std.Io.Writer, data: []const u8, opts: EventStream.Options) std.Io.Writer.Error!void {
    try EventStream.sendFields(w, opts);
    // A line per CR, LF or CRLF in `data`, as `EventWriter` splits it.
    var rest = data;
    while (std.mem.indexOfAny(u8, rest, "\r\n")) |idx| {
        try w.print("data: {s}\n", .{rest[0..idx]});
        var next = idx + 1;
        if (rest[idx] == '\r' and next < rest.len and rest[next] == '\n') next += 1;
        rest = rest[next..];
    }
    try w.print("data: {s}\n", .{rest});
    try w.writeAll("\n");
}

/// A buffered response body: segments of the request arena, each allocated
/// when the last one fills and never moved. It is collected only so its
/// length is known before the headers go out, so it is never gathered into
/// one piece; it is sent a segment at a time.
///
/// The last segment belongs to whichever `BodyWriter` is open, and its
/// `len` catches up with it when that writer is flushed or ended, or moves
/// to the next segment.
const BodyBuffer = struct {
    segments: std.DoublyLinkedList = .{},
    /// The bytes in every segment but the last.
    sealed_len: usize = 0,

    const first_segment_len = 512;
    const max_segment_len = 64 * 1024;

    /// A segment's header, with its bytes right behind it in the same
    /// allocation.
    const Segment = struct {
        node: std.DoublyLinkedList.Node = .{},
        len: usize = 0,
        capacity: usize,

        fn create(arena: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!*Segment {
            const size = std.math.add(usize, @sizeOf(Segment), capacity) catch return error.OutOfMemory;
            const memory = try arena.alignedAlloc(u8, .of(Segment), size);
            const segment: *Segment = @ptrCast(memory.ptr);
            segment.* = .{ .capacity = capacity };
            return segment;
        }

        fn fromNode(node: *std.DoublyLinkedList.Node) *Segment {
            return @fieldParentPtr("node", node);
        }

        fn bytes(self: *Segment) []u8 {
            const base: [*]u8 = @ptrCast(self);
            return base[@sizeOf(Segment)..][0..self.capacity];
        }
    };

    /// With the first segment reserved up front: a short body then never
    /// reaches a writer's vtable, and a writer is never unbuffered, which
    /// `std.Io.Writer.sendFileAll` asserts against. The request arena keeps
    /// its memory between a connection's requests, so this is a bump.
    fn init(arena: std.mem.Allocator) std.mem.Allocator.Error!BodyBuffer {
        var self: BodyBuffer = .{};
        try self.reserveFirst(arena);
        return self;
    }

    /// `init`'s first segment, for a buffer that has none yet: before a
    /// writer is made over it.
    fn reserveFirst(self: *BodyBuffer, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.segments.first != null) return;
        self.segments.append(&(try Segment.create(arena, first_segment_len)).node);
    }

    fn last(self: *const BodyBuffer) ?*Segment {
        return if (self.segments.last) |node| Segment.fromNode(node) else null;
    }

    fn len(self: *const BodyBuffer) usize {
        return self.sealed_len + if (self.last()) |segment| segment.len else 0;
    }

    /// Sends the segments in order, up to `max_vecs` in one vectored write.
    fn writeTo(self: *const BodyBuffer, out: *std.Io.Writer) std.Io.Writer.Error!void {
        const max_vecs = 8;
        var vecs: [max_vecs][]const u8 = undefined;
        var n: usize = 0;
        var it = self.segments.first;
        while (it) |node| : (it = node.next) {
            const segment = Segment.fromNode(node);
            vecs[n] = segment.bytes()[0..segment.len];
            n += 1;
            if (n == max_vecs) {
                try out.writeVecAll(vecs[0..n]);
                n = 0;
            }
        }
        if (n > 0) try out.writeVecAll(vecs[0..n]);
    }

    /// Forgets the body, keeping the last segment to write into again.
    fn clear(self: *BodyBuffer) void {
        const segment = self.last() orelse return;
        segment.* = .{ .capacity = segment.capacity };
        self.segments = .{};
        self.segments.append(&segment.node);
        self.sealed_len = 0;
    }

    /// Seals what `w` holds, except its last `preserve` bytes, which start
    /// the next segment, and makes that next segment `w`'s buffer, with
    /// room for `needed` more.
    fn nextSegment(
        self: *BodyBuffer,
        arena: std.mem.Allocator,
        w: *std.Io.Writer,
        needed: usize,
        preserve: usize,
    ) std.mem.Allocator.Error!void {
        const filled = w.buffer[0..w.end];
        // Asking to keep more than is buffered keeps all of it, as the
        // default rebase does.
        const kept = @min(preserve, filled.len);
        const keep = filled[filled.len - kept ..];

        // Doubling, so a large body takes few segments, up to a size past
        // which a bigger one saves nothing. Sized by `preserve` rather than
        // what was kept of it: the caller asserts room for both, whatever
        // was actually buffered.
        const next_len = if (w.buffer.len == 0) first_segment_len else @min(max_segment_len, w.buffer.len * 2);
        const size = @max(next_len, std.math.add(usize, needed, preserve) catch return error.OutOfMemory);
        const next = try Segment.create(arena, size);

        if (self.last()) |current| {
            std.debug.assert(w.buffer.ptr == current.bytes().ptr);
            current.len = filled.len - kept;
            if (current.len == 0) {
                // Nothing of it stays: drop it rather than send it empty.
                self.segments.remove(&current.node);
            } else {
                self.sealed_len += current.len;
            }
        }
        @memcpy(next.bytes()[0..keep.len], keep);
        next.len = keep.len;
        self.segments.append(&next.node);
        w.buffer = next.bytes();
        w.end = keep.len;
    }
};

/// Collects a response body without touching the connection.
///
/// The headers are not sent until the whole response is, so middleware
/// running after the handler can still change them, and the body is sent
/// with a `Content-Length`. Storage comes from the response's arena, so
/// there is no size to pick and nothing for the caller to own.
///
/// `interface` writes straight into the response's current body segment,
/// so a short write is a copy and only a write that does not fit reaches
/// the vtable. As with any buffered writer, what was written reaches the
/// response when the writer is flushed, which `end` does. A failure is
/// recorded in `err`, since the interface can only report `WriteFailed`.
///
/// Bytes in earlier segments are no longer in `interface.buffer`, so
/// `std.Io.Writer.undo` can only take back what the current segment holds.
///
/// Use `StreamingBodyWriter` when the body should go out as it is
/// produced. Either way, `end` must be called before the handler returns.
pub const BodyWriter = struct {
    res: *Response,
    /// Where the bytes go: the response's body, or a buffer built beside it.
    buffer: *BodyBuffer,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed`. Nothing here
    /// talks to the connection, so this is an allocation failure.
    err: ?Error = null,

    pub const Error = std.mem.Allocator.Error;

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
        .rebase = rebase,
    };

    fn init(res: *Response) BodyWriter {
        return .into(res, &res.body_buffer);
    }

    fn into(res: *Response, buffer: *BodyBuffer) BodyWriter {
        const segment = buffer.last();
        return .{
            .res = res,
            .buffer = buffer,
            .interface = .{
                .buffer = if (segment) |seg| seg.bytes() else &.{},
                .end = if (segment) |seg| seg.len else 0,
                .vtable = &vtable,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BodyWriter = @alignCast(@fieldParentPtr("interface", w));
        const pattern = data[data.len - 1];
        var needed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            needed = std.math.add(usize, needed, bytes.len) catch return self.fail(error.OutOfMemory);
        }
        const splat_len = std.math.mul(usize, pattern.len, splat) catch return self.fail(error.OutOfMemory);
        needed = std.math.add(usize, needed, splat_len) catch return self.fail(error.OutOfMemory);
        // Called only when `data` does not fit in what is left, so move on
        // to a segment it does fit in.
        self.buffer.nextSegment(self.res.arena, w, needed, 0) catch |err| return self.fail(err);

        const start = w.end;
        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(w.buffer[w.end..][0..splat], pattern[0]);
                w.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return w.end - start;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        const self: *BodyWriter = @alignCast(@fieldParentPtr("interface", w));
        self.buffer.nextSegment(self.res.arena, w, minimum_len, preserve) catch |err| return self.fail(err);
    }

    /// The segments are the storage, so there is nothing to send: flushing
    /// tells the buffer how much of the current one is written.
    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *BodyWriter = @alignCast(@fieldParentPtr("interface", w));
        if (self.buffer.last()) |segment| segment.len = w.end;
    }

    fn fail(self: *BodyWriter, err: Error) std.Io.Writer.Error {
        self.err = err;
        return error.WriteFailed;
    }

    /// Marks the body complete. It is sent with the rest of the response,
    /// once the headers have settled.
    pub fn end(self: *BodyWriter) Error!void {
        // Idempotent, so `defer body.end() catch {}` alongside an explicit
        // `end` on the success path is harmless rather than a second body.
        if (!self.res._body_writer_open) return;
        self.res._body_writer_open = false;
        self.res._body_writer_buffering = false;
        // Cannot fail: see `flush`.
        self.interface.flush() catch unreachable;
        // A write that failed was reported then; the body is not complete
        // for having stopped.
        if (self.err) |err| return err;
    }
};

/// Writes a response body straight to the connection as it is produced.
///
/// The headers are sent when this is created, so nothing can change them
/// afterwards -- `Response.header` and `Response.setCookie` will report
/// `error.HeadersAlreadySent`. Use `BodyWriter` unless the body really
/// should go out incrementally.
///
/// Framing is decided once, at construction: chunked, unless a
/// `Content-Length` header already says how long the body will be, in
/// which case it is streamed as-is.
pub const StreamingBodyWriter = struct {
    res: *Response,
    interface: std.Io.Writer,
    /// The real cause behind the generic `error.WriteFailed` that the
    /// `std.Io.Writer` interface has to return. Recorded when a write
    /// fails, so a handler that catches one can find out what happened
    /// instead of being told only that it did.
    err: ?Error = null,
    /// Set when the body goes out gzipped: what is written goes through it
    /// on the way to the framing.
    compressor: ?*StreamCompressor = null,
    /// Everything a write to the connection can fail with, resolved to its
    /// cause rather than the `std.Io.Writer` sentinel, and
    /// `ContentLengthMismatch` for a write past a declared Content-Length.
    pub const Error = Response.SendError || error{ContentLengthMismatch};

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
    };

    fn init(res: *Response, buf: []u8, compressor: ?*StreamCompressor) StreamingBodyWriter {
        return .{
            .res = res,
            .interface = .{ .buffer = buf, .vtable = &vtable },
            .compressor = compressor,
        };
    }

    /// Runs `result`, storing what actually went wrong. `drain` is the one
    /// path that cannot hand the cause back -- the `std.Io.Writer` vtable
    /// fixes its error set -- so this is the one place `err` is written.
    fn record(self: *StreamingBodyWriter, result: std.Io.Writer.Error!void) std.Io.Writer.Error!void {
        self.res.resolve(result) catch |cause| {
            self.err = cause;
            return error.WriteFailed;
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamingBodyWriter = @alignCast(@fieldParentPtr("interface", w));
        const pending = w.buffered();
        const total = pending.len + std.Io.Writer.countSplat(data, splat);
        // A zero length chunk is the terminator, so an empty drain must
        // send nothing rather than ending the body early.
        if (total == 0) return 0;

        // A HEAD reports the length its GET would have and sends none of
        // it. The handler still writes, and is still charged for what it
        // wrote, so a declared Content-Length is checked the same way.
        if (!self.res.sendsBody()) {
            self.res.body_sent += total;
            return w.consume(total);
        }

        self.res.armWrite();
        defer self.res.disarmWrite();
        if (self.compressor) |compressor| {
            // Charged by the compressor for what it sends instead.
            try self.record(compressor.write(pending, data, splat));
            return w.consume(total);
        }

        // Never past a declared length: the bytes after it would reach
        // the peer (or a proxy reusing the connection) as the start of the
        // next response. Nothing of this write goes out, and the
        // connection is not reused.
        if (self.res.content_length) |declared| if (!self.res._chunked and total > declared -| self.res.body_sent) {
            self.res.keepalive = false;
            self.err = error.ContentLengthMismatch;
            return error.WriteFailed;
        };

        try self.record(self.res.sendFramed(pending, data, splat, total));
        self.res.body_sent += total;
        return w.consume(total);
    }

    /// A flush of a gzipped body has to reach through zlib, which would
    /// otherwise hold on to what it was given until it had more.
    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *StreamingBodyWriter = @alignCast(@fieldParentPtr("interface", w));
        self.res.armWrite();
        defer self.res.disarmWrite();
        const compressor = self.compressor orelse return std.Io.Writer.defaultFlush(w);
        try self.record(compressor.flush(w.buffered()));
        w.end = 0;
    }

    /// Finishes the body: flushes what is left and, for a chunked body,
    /// writes the terminator. Must be called before the handler returns.
    pub fn end(self: *StreamingBodyWriter) (Error || error{ContentLengthMismatch})!void {
        const res = self.res;
        // Idempotent: a second `end` must not write a second terminator,
        // which the peer would read as the start of the next message.
        if (!res._body_writer_open) return;
        res._body_writer_open = false;
        // From here the bytes already sent are the response, whatever
        // happens next, so `write` must not add a terminator or a body to
        // them.
        res._written = true;
        // If this does not finish cleanly the body is not framed the way
        // its headers promised, and the connection cannot carry another
        // response.
        errdefer res.keepalive = false;
        res.armWrite();
        defer res.disarmWrite();

        if (self.compressor) |compressor| {
            try res.resolve(compressor.finish(self.interface.buffered()));
            self.interface.end = 0;
        } else {
            try res.resolve(self.interface.flush());
        }
        if (res._chunked and res.sendsBody()) try res.resolve(res._conn.?.writer.writeAll("0\r\n\r\n"));
        try res.resolve(res.finish(res.bodyOut()));
        // Sending the wrong number of bytes for a declared length leaves
        // the connection out of sync and the client waiting.
        if (res.content_length) |declared| {
            if (res.body_sent != declared) return error.ContentLengthMismatch;
        }
    }
};

/// Compresses a streamed body (gzip, zstd or Brotli) between the handler and the
/// framing: what the handler writes goes into the coder, and what that
/// produces collects in `out` until there is a chunk's worth. Allocated from
/// the arena, since the coder writes into `out` by pointer and the body
/// writer holding this is returned by value.
const StreamCompressor = struct {
    res: *Response,
    coder: Coder,
    out: std.Io.Writer,
    out_buffer: [out_buffer_len]u8,

    const Coder = union(enum) {
        gzip: zlib.Compress,
        zstd: if (build_options.use_zstd) zstd_io.Compress else void,
        br: if (build_options.use_brotli) brotli_io.Compress else void,
    };

    fn input(self: *StreamCompressor) *std.Io.Writer {
        return switch (self.coder) {
            .gzip => |*g| &g.writer,
            .zstd => |*z| if (build_options.use_zstd) &z.writer else unreachable,
            .br => |*z| if (build_options.use_brotli) &z.writer else unreachable,
        };
    }

    const out_buffer_len = 4096;

    /// The length is not known up front, so the window cannot be fitted
    /// to it: this is about 64K of arena, where zlib's defaults take 256K.
    const options: zlib.Options = .{
        .level = Response.compression_level,
        .window_bits = 13,
        .mem_level = 6,
    };

    fn create(res: *Response, coding: Response.Compression) error{ OutOfMemory, CompressFailed }!*StreamCompressor {
        const self = try res.arena.create(StreamCompressor);
        self.res = res;
        self.out = .{ .buffer = &self.out_buffer, .vtable = &.{ .drain = drainOut } };
        // Unbuffered: the body writer's buffer is in front of it already.
        switch (coding) {
            .zstd => if (build_options.use_zstd) {
                self.coder = .{ .zstd = undefined };
                try self.coder.zstd.init(res.arena, &self.out, &.{}, .{});
            } else unreachable,
            // Its memory is not the arena's: `finish` frees it, or
            // `Response.deinit` for a body never ended (`brotli_encoder`).
            .br => if (build_options.use_brotli) {
                self.coder = .{ .br = undefined };
                try self.coder.br.init(&self.out, &.{}, .{ .quality = res._brotli_quality });
                res.brotli_encoder = self.coder.br.state;
            } else unreachable,
            else => self.coder = .{ .gzip = try .init(res.arena, &self.out, &.{}, .gzip, options) },
        }
        return self;
    }

    /// Frees what is not the arena's (Brotli's encoder), and says so to
    /// the response.
    fn deinit(self: *StreamCompressor) void {
        switch (self.coder) {
            .br => |*z| if (build_options.use_brotli) {
                z.deinit();
                self.res.brotli_encoder = null;
            } else unreachable,
            else => {},
        }
    }

    fn write(self: *StreamCompressor, pending: []const u8, data: []const []const u8, splat: usize) std.Io.Writer.Error!void {
        const w = self.input();
        try w.writeAll(pending);
        for (data[0 .. data.len - 1]) |bytes| try w.writeAll(bytes);
        try w.splatBytesAll(data[data.len - 1], splat);
    }

    fn flush(self: *StreamCompressor, pending: []const u8) std.Io.Writer.Error!void {
        const w = self.input();
        try w.writeAll(pending);
        try w.flush();
        try self.out.flush();
    }

    fn finish(self: *StreamCompressor, pending: []const u8) std.Io.Writer.Error!void {
        try self.input().writeAll(pending);
        switch (self.coder) {
            .gzip => |*g| try g.finish(),
            .zstd => |*z| if (build_options.use_zstd) try z.finish() else unreachable,
            .br => |*z| if (build_options.use_brotli) try z.finish() else unreachable,
        }
        self.deinit();
        try self.out.flush();
    }

    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamCompressor = @alignCast(@fieldParentPtr("out", w));
        const pending = w.buffered();
        const total = pending.len + std.Io.Writer.countSplat(data, splat);
        if (total == 0) return 0;
        try self.res.sendFramed(pending, data, splat, total);
        self.res.body_sent += total;
        return w.consume(total);
    }
};

/// Framing fields the server writes itself (`Response.header` refuses
/// them).
pub fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or std.ascii.eqlIgnoreCase(name, "Connection");
}

/// Whether a response with this status carries a body at all. A 1xx, a
/// 204 and a 304 do not, so a peer reads whatever follows their head as
/// the next response.
fn statusHasBody(status: http.Status) bool {
    const code = @backingInt(status);
    return code >= 200 and status != .no_content and status != .not_modified;
}

/// What a handler writes its answer into, over any protocol. Set `status`,
/// `body` and headers and return; the server sends it after the handler
/// (and the middleware after it) have run. For a body built in pieces use
/// `writer`, `print`, `json` or `render`; to send while the handler is
/// still working, `stream` or `startEventStream`.
///
///     fn create(req: *anole.Request, res: *anole.Response) !void {
///         const in = try req.bind(NewUser);
///         res.status = .created;
///         try res.header("Location", "/users/7");
///         try res.json(.{ .id = 7, .name = in.name });
///     }
///
/// A handler can also answer by returning an error: `error.NotFound` and
/// the other status-named errors become that status, the rest a 500 (see
/// `anole.defaultError`), and `fail` writes an error answer directly.
pub const Response = struct {
    /// 200 unless set.
    status: http.Status = .ok,
    /// The body, when it is one slice: a literal, or something in the
    /// request's arena. It is sent after the handler returns, so it must
    /// outlive the handler.
    body: []const u8 = "",
    /// The response headers; set them through `header`, `addHeader` and
    /// `setCookie`, which check names and values. The table starts small
    /// and grows up to `max_headers`.
    headers: http.Headers = .{},
    /// Most headers the response can carry (`ServerConfig.response
    /// .max_header_count`).
    _max_headers: usize = 64,
    /// The `Content-Type` sent, when the handler sets it by name; `json`,
    /// `print` and the others set it for you.
    content_type: ?http.ContentType = null,
    /// The request's arena: freed after the response has gone out.
    arena: std.mem.Allocator,
    /// The body, when it is written rather than set with `body`.
    body_buffer: BodyBuffer = .{},
    /// The HTTP/1.x connection the response is written to. Unused, and
    /// undefined, when `sink` is set.
    _conn: ?*Connection = null,
    /// Set for a response that goes to a protocol engine rather than out as
    /// HTTP/1.x bytes: an HTTP/2 stream. See `initSink`.
    _sink: ?Sink = null,
    /// The connection's `Io`, for files.
    io: std.Io = undefined,
    /// Send a `Date` header (RFC 9110 6.6.1) unless the handler set one.
    /// Set by the server from `ServerConfig.response.date`.
    _send_date: bool = false,
    /// The Content-Type a buffered body goes out with when the handler set
    /// neither `content_type` nor the header. Set by the server from
    /// `ServerConfig.response.default_content_type`.
    _default_content_type: ?http.ContentType = null,
    /// How `fail` and the server's own error answers are written. Set by
    /// the server from `ServerConfig.errors`.
    _error_format: ErrorFormat = .auto,
    /// Trailer fields, sent after the body. Only a `sink` carries them
    /// (HTTP/2 does, for gRPC status among others); over HTTP/1.x they are
    /// dropped.
    trailers: ?http.Headers = null,
    _written: bool = false,
    _headers_written: bool = false,
    keepalive: bool = true,
    _chunked: bool = false,
    _streaming: bool = false,
    /// The request was a HEAD, so the headers go out describing the body
    /// a GET would have sent, and the body itself does not. Set by the
    /// server; a handler writes its body either way and does not have to
    /// know.
    head: bool = false,
    /// A body writer was handed out and has not been ended yet.
    _body_writer_open: bool = false,
    /// The open body writer is a `BodyWriter`, whose length the response
    /// only learns when it ends.
    _body_writer_buffering: bool = false,
    /// The request was HTTP/1.0, so the peer does not understand chunked
    /// encoding. Set by the server.
    http10: bool = false,
    /// Length declared before streaming, if any. On the response rather
    /// than the writer so that `write` can still tell whether the body
    /// that went out matched it, even if the writer was abandoned.
    content_length: ?usize = null,
    /// Body bytes handed to the connection by a streaming writer.
    body_sent: usize = 0,
    /// The request this answers, when the server built the pair. Set by the
    /// server.
    _request: ?*Request = null,
    /// From the engine: `timeouts.write`. Once a stream or file body has
    /// started, each write the peer does not take within it ends the
    /// response (`error.WriteTimeout`).
    _write_timeout: ?std.Io.Duration = null,
    /// `ServerConfig.error_detail`: `defaultError` names the error in a 500.
    _error_detail: bool = false,
    /// When the write in progress times out, if one is being timed.
    _write_deadline: ?std.Io.Clock.Timestamp = null,
    /// The request deadline was lifted for a stream or file body.
    _stream_mode: bool = false,
    /// Send the body compressed (zstd, Brotli or gzip, as the build has
    /// them) if the request's `Accept-Encoding` allows it.
    /// Settled with the headers: by `stream`, or by `write` for a buffered
    /// body, which goes out as it is when it is short or does not shrink.
    /// Ignored when the handler set its own `Content-Encoding`,
    /// `Content-Length` or `Content-Range`.
    ///
    /// A strong `ETag` goes out weakened, as `W/"..."`, since the bytes
    /// are no longer the ones it named, and that is the form a client
    /// sends back in `If-None-Match`. `Accept-Ranges` is dropped, since a
    /// range would be taken of the gzipped bytes.
    ///
    /// A 304 has no body, but gets the `Vary` and `ETag` of the 200 it
    /// stands in for, assuming that one was gzipped: a 200 short enough
    /// to go out as it was kept its `ETag` strong, which still matches the
    /// weak one under the weak comparison `If-None-Match` uses.
    compress: bool = false,
    /// Brotli's quality, 0 to 11, when `compress` picks `br`. Set by the
    /// server from `ServerConfig.response.brotli_quality`; a handler may
    /// change it for its own response before the headers go out.
    _brotli_quality: u4 = 5,
    /// A streamed body's Brotli encoder until the body ends: freed by
    /// `deinit` if it never does. Held here, not only in the compressor,
    /// which lives in the arena: the server may reset that before `deinit`.
    brotli_encoder: if (build_options.use_brotli) ?*brotli_io.State else void = if (build_options.use_brotli) null else {},
    /// The body, when it is a file: opened by `sendFile`, sent and closed
    /// by `write`.
    file: ?BodyFile = null,
    /// Set by an engine that can finish this response with no task waiting
    /// for it (HTTP/2 and HTTP/3 requests that run on the reader): see
    /// `detach`.
    _detach_engine: ?*const Detached.Engine = null,
    _detach_ctx: ?*anyopaque = null,
    /// A middleware that is not detach-safe ran (`Detached`): `detach` is
    /// refused.
    _detach_blocked: bool = false,
    /// Set by `detach`.
    detached: ?*Detached = null,
    /// The engine offers `detach` to `_park` only (an HTTP/2 stream on its
    /// own task): `canDetach` stays false, so the C ABI's detaching, which
    /// is for requests on the reader, is unchanged.
    _detach_park_only: bool = false,
    /// `_park` ran: the response is a parked stream's, and `write` does
    /// nothing more.
    _parked: bool = false,

    /// A file body set up by `sendFile`.
    pub const BodyFile = struct {
        handle: std.Io.File,
        /// Where in the file the body starts, and how much of it there is.
        offset: u64 = 0,
        size: usize,
    };

    /// What shaping a header can fail with. Nothing here touches the
    /// connection: a header set after the headers went out, a name or value
    /// that would not survive the wire, one header too many.
    pub const HeaderError = error{
        HeadersAlreadySent,
        InvalidHeaderName,
        InvalidHeaderValue,
        TooManyHeaders,
    };

    /// What sending bytes to the peer can fail with, resolved to the cause
    /// the connection recorded. `error.WriteFailed` is the `std.Io.Writer`
    /// vtable's sentinel and says nothing a caller can act on, so it does
    /// not appear here; a writer that failed without recording a cause --
    /// a fixed buffer running out, say -- comes back as `Unexpected`.
    pub const SendError = Connection.WriteError || error{ Unexpected, WriteTimeout };

    /// What `write` can fail with. `ContentLengthMismatch` is a body of
    /// another length than a handler-set Content-Length promises;
    /// `InvalidContentLength` is such a header that is not a number.
    pub const WriteError = HeaderError || SendError || error{ ContentLengthMismatch, InvalidContentLength };

    /// The headers a response starts with room for: enough for most, so
    /// that an ordinary one takes little of the arena. The table grows to
    /// `max_headers` for one with more.
    const initial_header_room = 16;

    /// A response written to an HTTP/1.x connection. Made by the server;
    /// handlers get theirs. The body buffer's first segment is taken once
    /// a body is written (`writer`), so a response whose body is a slice
    /// takes none.
    pub fn _init(arena: std.mem.Allocator, conn: *Connection, max_headers: usize) !Response {
        return .{
            .arena = arena,
            ._conn = conn,
            .io = conn.io,
            .headers = try http.Headers.init(arena, @min(max_headers, initial_header_room)),
            ._max_headers = max_headers,
        };
    }

    /// A response written to `sink` instead of a connection. Framing,
    /// keep-alive and the status line are the sink's business: the response
    /// hands over the head, the body bytes and the end.
    pub fn _initSink(arena: std.mem.Allocator, io: std.Io, sink: Sink, max_headers: usize) !Response {
        return .{
            .arena = arena,
            ._sink = sink,
            .io = io,
            .headers = try http.Headers.init(arena, @min(max_headers, initial_header_room)),
            ._max_headers = max_headers,
        };
    }

    /// Room for `n` more headers, the table grown if it must be. False
    /// past `max_headers`, or without the memory for a bigger table.
    fn headerRoom(self: *Response, n: usize) bool {
        while (self.headers.keys.len - self.headers.len < n) {
            if (!self.headers.grow(self.arena, self._max_headers)) return false;
        }
        return true;
    }

    /// `headers.put`, the table grown first if it is full.
    fn putHeader(self: *Response, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (self.headers.get(name) == null and !self.headerRoom(1)) return error.TooManyHeaders;
        try self.headers.put(name, value);
    }

    /// Adds a trailer field, sent after the body. Carried only by a sink
    /// (an HTTP/2 stream); an HTTP/1.x response drops it.
    pub fn trailer(self: *Response, name: []const u8, value: []const u8) HeaderError!void {
        try http.validateHeaderName(name);
        try http.validateHeaderValue(value);
        if (self.trailers == null) self.trailers = http.Headers.init(self.arena, 16) catch return error.TooManyHeaders;
        try self.trailers.?.put(name, value);
    }

    /// Ends the response unfinished, for a handler that cannot complete
    /// one it has started (a stream whose source failed part way): return
    /// what this returns. HTTP/2 resets the stream (CANCEL), and HTTP/1.x
    /// closes the connection without the rest of the body, so the peer
    /// sees a cut-short response rather than a complete one. With nothing
    /// sent yet, the peer gets the reset or the close alone. Not logged as
    /// a server error.
    pub fn abort(self: *Response) error{ResponseAborted} {
        self.keepalive = false;
        return error.ResponseAborted;
    }

    /// Whether the head has gone out, so the status and headers can no longer
    /// change (a stream, an event stream or a file has started).
    pub fn headersSent(self: *const Response) bool {
        return self._headers_written;
    }

    /// Whether the peer went away, so a failure is not the handler's fault.
    pub fn peerGone(self: *Response) bool {
        if (self._sink) |sink| return sink.peerGone();
        return self._conn.?.peerGone();
    }

    /// Where body bytes go: the sink's writer, or the connection, which
    /// takes its write buffer now.
    fn bodyOut(self: *Response) *std.Io.Writer {
        if (self._sink) |sink| return sink.body();
        self._conn.?.prepareWrite();
        return self._conn.?.writer;
    }

    /// Ends the message on `w`: a flush for HTTP/1.x; for a sink, a flush
    /// of its body writer and then the end, with any trailers.
    fn finish(self: *Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.flush();
        if (self._sink) |sink| try sink.end(if (self.trailers) |*t| t else null);
    }

    /// Closes a file body that `write` never got to send.
    pub fn deinit(self: *Response) void {
        self.closeFile();
        if (build_options.use_brotli) if (self.brotli_encoder) |state| brotli_io.destroy(state);
        if (build_options.use_brotli) self.brotli_encoder = null;
    }

    pub const SendFileOptions = struct {
        /// Also refuse a path that leaves `dir` through a symlink. See
        /// `std.Io.Dir.OpenFileOptions.resolve_beneath`: how far that holds
        /// depends on the platform and the `Io`.
        resolve_beneath: bool = false,
    };

    pub const SendFileError = std.Io.File.OpenError || std.Io.File.StatError || http.MisuseError || error{ FileTooBig, NotFile };

    /// Makes the file at `sub_path` in `dir` the body. The file is opened
    /// and checked now, so a missing one is reported here, where it can
    /// still become a 404; it goes out after the handler returns, with
    /// whatever headers the handler and middleware have set by then, and
    /// is closed once sent.
    ///
    /// `sub_path` stays inside `dir`: an absolute path, a `..` segment or
    /// a NUL byte (on Windows also a `\`-separated `..`, or a `:`) is
    /// `error.BadPathName`, which the server answers with 404, so request
    /// input such as `req.params.get("name")` cannot reach a file outside
    /// it. To send a file the program itself names elsewhere, open its
    /// directory and pass the name relative to that.
    ///
    /// A directory is `error.IsDir`, and anything else that is not a
    /// regular file, such as a device, is `error.NotFile`. Never compressed.
    pub fn sendFile(self: *Response, dir: std.Io.Dir, sub_path: []const u8, options: SendFileOptions) SendFileError!std.Io.File.Stat {
        try self.checkBodyNotStarted();
        if (!staysInside(sub_path)) return error.BadPathName;
        const io = self.io;
        const handle = try dir.openFile(io, sub_path, .{ .resolve_beneath = options.resolve_beneath });
        errdefer handle.close(io);
        const stat = try handle.stat(io);
        switch (stat.kind) {
            .file => {},
            .directory => return error.IsDir,
            else => return error.NotFile,
        }
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        self.closeFile();
        self.file = .{ .handle = handle, .size = size };
        return stat;
    }

    /// Whether `sub_path`, read as text, names something inside the
    /// directory it is opened in: relative, with no `..` segment and no NUL
    /// byte. On Windows `\` separates segments too, and a `:` (a drive or
    /// an alternate data stream) is refused.
    fn staysInside(sub_path: []const u8) bool {
        const windows = builtin.os.tag == .windows;
        if (std.mem.findScalar(u8, sub_path, 0) != null) return false;
        if (sub_path.len > 0 and (sub_path[0] == '/' or (windows and sub_path[0] == '\\'))) return false;
        if (windows and std.mem.findScalar(u8, sub_path, ':') != null) return false;
        var segments = std.mem.tokenizeAny(u8, sub_path, if (windows) "/\\" else "/");
        while (segments.next()) |segment| if (std.mem.eql(u8, segment, "..")) return false;
        return true;
    }

    fn closeFile(self: *Response) void {
        const body = self.file orelse return;
        body.handle.close(self.io);
        self.file = null;
    }

    /// Sets header `name` to `value`, replacing an earlier value under
    /// the same name (case-insensitive). Neither is copied: use literals
    /// or the arena. Fails once the headers have gone out, on a name or
    /// value that is not valid on the wire, and past
    /// `ServerConfig.response.max_header_count`.
    ///
    /// `Transfer-Encoding` and `Connection` are the server's, which frames
    /// the body and decides about keep-alive (`keepalive`): setting either
    /// is `error.InvalidHeaderName`.
    pub fn header(self: *Response, name: []const u8, value: []const u8) HeaderError!void {
        // Not a programmer error: middleware that runs after the handler
        // cannot know whether the handler chose to stream.
        if (self._headers_written) return error.HeadersAlreadySent;
        try http.validateHeaderName(name);
        if (isReservedHeader(name)) return error.InvalidHeaderName;
        try http.validateHeaderValue(value);
        try self.putHeader(name, value);
    }

    /// Adds a header even if the response has one by that name already:
    /// for a field that may repeat or lists its values, such as `Vary`.
    /// `Content-Length` never repeats: a second one replaces the first.
    /// The names `header` refuses, this refuses too.
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) HeaderError!void {
        if (self._headers_written) return error.HeadersAlreadySent;
        try http.validateHeaderName(name);
        if (isReservedHeader(name)) return error.InvalidHeaderName;
        try http.validateHeaderValue(value);
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) return self.putHeader(name, value);
        if (!self.headerRoom(1)) return error.TooManyHeaders;
        try self.headers.add(name, value);
    }

    /// A writer that collects the body without touching the connection.
    /// The headers are not sent until the whole response is, so anything
    /// running after the handler can still change them.
    ///
    /// Call `end` on the result before returning from the handler.
    pub fn writer(self: *Response) http.MisuseError!BodyWriter {
        try self.startBody();
        self._body_writer_buffering = true;
        // Without the memory, the first write fails the same way.
        self.body_buffer.reserveFirst(self.arena) catch {};
        return .init(self);
    }

    /// A writer that sends the headers now and streams the body as it is
    /// written. Chunked, unless a `Content-Length` header says how long the
    /// body will be, in which case it is streamed as-is. An HTTP/1.0 peer
    /// gets neither: the body is streamed as-is and the connection closed
    /// after it.
    ///
    /// The headers are on the wire when this returns, so nothing can change
    /// them afterwards. Call `end` on the result before returning.
    pub fn stream(self: *Response, buf: []u8) !StreamingBodyWriter {
        try self.startBody();
        // Everything that can fail comes before anything is committed: a
        // handler that gets an error from here still has open headers,
        // and the error response written in their place must not inherit
        // this one's framing or coding.
        var declared: ?usize = null;
        if (self.headers.get("Content-Length")) |v| {
            declared = std.fmt.parseInt(usize, v, 10) catch return error.InvalidContentLength;
        }
        try self.applyContentType();
        var compression = self.negotiateCompression();
        // Without the memory for a compressor the body goes out as it is,
        // as a buffered one does.
        const compressor: ?*StreamCompressor = if (compression.isCoding() and self.sendsBody())
            StreamCompressor.create(self, compression) catch blk: {
                compression = .identity;
                break :blk null;
            }
        else
            null;
        self._headers_written = true;

        if (compression != .off) self.addVary();
        if (compression.isCoding()) self.markCompressed(compression);
        if (declared) |len| {
            self.content_length = len;
        } else if (self._sink != null) {
            // The protocol under a sink frames the body itself.
            self._streaming = true;
        } else if (self.http10) {
            // Chunked encoding came with HTTP/1.1. Before it, a body of
            // unknown length ends when the connection does. A response
            // that sends no body needs no such end.
            self._streaming = true;
            if (self.sendsBody()) self.keepalive = false;
        } else {
            self._chunked = true;
        }
        try self.resolve(self.sendHeaderAlone(self.bodyOut()));
        self.liftDeadline();
        return .init(self, buf, compressor);
    }

    /// A body can be started: no writer open, no head sent, no body set.
    fn checkBodyNotStarted(self: *const Response) http.MisuseError!void {
        if (self._body_writer_open) return error.BodyWriterOpen;
        if (self._headers_written) return error.HeadersAlreadySent;
        if (self.body.len != 0 or self.body_buffer.len() != 0) return error.BodyAlreadySet;
    }

    fn startBody(self: *Response) http.MisuseError!void {
        try self.checkBodyNotStarted();
        self._body_writer_open = true;
    }

    /// Throws away the body written so far. Not while a body writer is
    /// open: its unflushed bytes are its own, and it would put them back.
    pub fn clearWriter(self: *Response) void {
        // A buffering writer is open: its bytes are its own.
        if (self._body_writer_buffering) return;
        self.body_buffer.clear();
    }

    /// Throws away a body that was started but never finished, so a
    /// replacement can be written in its place. `write` prefers the
    /// buffer over `body`, so without this an error response would be
    /// sent with whatever the failed handler had produced so far.
    ///
    /// Only usable while the headers are still open; once they are on the
    /// wire the framing is already promised and the body cannot be
    /// swapped.
    pub fn resetBody(self: *Response) error{HeadersAlreadySent}!void {
        if (self._headers_written) return error.HeadersAlreadySent;
        // An open writer is abandoned with the body: `end` on it does
        // nothing once it is no longer the open one.
        self._body_writer_open = false;
        self._body_writer_buffering = false;
        self.clearWriter();
        self.body = "";
        self.closeFile();
        // Everything that described the old body has to go with it.
        // `content_type` is the usual way to set one, but a handler can
        // write any of these directly, and then a stale Content-Length
        // is worse than a stale type: the headers go out with a length that
        // is already set left alone, so the peer would be told to read a body
        // of the wrong size and the connection would fall out of step.
        self.content_type = null;
        _ = self.headers.remove("Content-Type");
        _ = self.headers.remove("Content-Length");
        _ = self.headers.remove("Content-Encoding");
    }

    /// Writes `value` as the JSON body (`std.json`), with its content type:
    /// `res.json(user)`. `jsonWith` takes `std.json`'s options.
    pub fn json(self: *Response, value: anytype) !void {
        return self.jsonWith(value, .{});
    }

    /// `json` with `std.json`'s stringify options (whitespace, nulls left
    /// out, and so on). `encode` with json.zig's `json.encode` is
    /// considerably faster for types known at compile time.
    pub fn jsonWith(self: *Response, value: anytype, options: std.json.Stringify.Options) !void {
        // The open writer owns the segment being filled, and would write
        // over this, or publish a length past the end of it.
        if (self._body_writer_buffering) return error.BodyWriterOpen;
        var w: BodyWriter = .init(self);
        defer w.interface.flush() catch unreachable;
        // A type that renames a field (`v.rename`) is written by outside
        // names; every other type keeps the std.json path byte for byte.
        if (comptime json_out.hasOutsideNames(@TypeOf(value))) {
            try json_out.write(&w.interface, value, .{ .omit_null_fields = !options.emit_null_optional_fields });
        } else {
            const json_formatter = std.json.fmt(value, options);
            try json_formatter.format(&w.interface);
        }
        try self.header("Content-Type", "application/json; charset=UTF-8");
    }

    /// Answers with an RFC 9457 problem document (`application/problem+json`),
    /// in place of anything written so far; does nothing once the headers
    /// are out. Strings must outlive the response (literals, or the
    /// request's arena). Members in order: `type`, `title`, `status`,
    /// `detail`, `instance` (when set), `errors`:
    ///
    ///     res.problem(.{ .status = .conflict, .detail = "already exists" });
    ///
    /// The default `detail` of a problem with `errors` counts them.
    pub fn problem(self: *Response, p: http.Problem) void {
        if (self._headers_written) return;
        self.resetBody() catch return;
        self.status = p.status;
        self.content_type = .problem_json;
        var out: std.Io.Writer.Allocating = .init(self.arena);
        writeProblem(&out.writer, p) catch {
            self.body = "{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500}";
            self.status = .internal_server_error;
            return;
        };
        self.body = out.written();
    }

    /// Answers with `status` and `message`, in place of anything written
    /// so far: `return res.fail(.unauthorized, "missing API key");`. The
    /// body is `{"error":"<message>"}` when the request takes JSON or the
    /// server answers in JSON (`ServerConfig.errors`), else `message` as
    /// text. An empty `message` stands for the status line: "404 Not
    /// Found\n", or `{"error":"Not Found"}`. `message` must outlive the
    /// response (a literal, or the request's arena).
    ///
    /// Does nothing once the headers are on the wire: a started response
    /// cannot become another.
    pub fn fail(self: *Response, status: http.Status, message: []const u8) void {
        if (self._headers_written) return;
        self.resetBody() catch return;
        self.status = status;
        if (self.answersJson()) {
            const text = if (message.len > 0) message else status.phrase();
            self.content_type = .json;
            self.body = std.fmt.allocPrint(self.arena, "{{\"error\":{f}}}", .{std.json.fmt(text, .{})}) catch
                "{\"error\":\"\"}";
        } else {
            self.content_type = .text;
            self.body = if (message.len > 0) message else statusBody(status);
        }
    }

    /// Whether `fail` answers in JSON: always or never by `error_format`,
    /// else when the request's `Accept` names JSON, or it sent JSON itself.
    fn answersJson(self: *const Response) bool {
        switch (self._error_format) {
            .json => return true,
            .text => return false,
            .auto => {},
        }
        const req = self._request orelse return false;
        if (req.headers.get("Accept")) |accept| {
            if (std.ascii.findIgnoreCase(accept, "json") != null) return true;
        }
        return req.content_type == .json;
    }

    /// Renders a template into the body, sent as `content_type`, or as
    /// whatever the response already has when it is null.
    /// `template` is either a function whose last parameter is the
    /// `*std.Io.Writer`, called with `args` followed by the writer, or a type
    /// with `render(args, writer: *std.Io.Writer)`, called with `args` as its
    /// first parameter.
    ///
    /// If the template fails, what it wrote is discarded, so the handler can
    /// still send something else.
    pub fn render(self: *Response, content_type: ?http.ContentType, comptime template: anytype, args: RenderArgs(template)) !void {
        var w = try self.writer();
        const result = if (@TypeOf(template) == type)
            template.render(args, &w.interface)
        else
            @call(.auto, template, args ++ .{&w.interface});
        return self.endBody(&w, content_type, result);
    }

    /// Encodes `value` as the body, sent as `content_type`, or as whatever
    /// the response already has when it is null. `encodeFn` is a
    /// serializer's write-to-writer function, its parameters told apart by
    /// type: the `*std.Io.Writer` gets the body, a `std.mem.Allocator` the
    /// response's arena, and the one parameter left gets `value`. That takes
    /// json.zig's `json.encode`, msgpack.zig's `msgpack.encode` and
    /// serde.zig's `toWriter` as they are.
    ///
    /// If the encoding fails, what it wrote is discarded, so the handler can
    /// still send something else.
    pub fn encode(self: *Response, content_type: ?http.ContentType, comptime encodeFn: anytype, value: anytype) !void {
        const params = comptime encodeParams(@TypeOf(encodeFn));
        var w = try self.writer();
        // Built in place rather than field by field, so a value known only
        // at compile time, such as a struct literal, can be passed.
        const result = switch (params.len) {
            2 => @call(.auto, encodeFn, .{
                encodeArg(params[0], &w.interface, self.arena, value),
                encodeArg(params[1], &w.interface, self.arena, value),
            }),
            3 => @call(.auto, encodeFn, .{
                encodeArg(params[0], &w.interface, self.arena, value),
                encodeArg(params[1], &w.interface, self.arena, value),
                encodeArg(params[2], &w.interface, self.arena, value),
            }),
            else => unreachable,
        };
        return self.endBody(&w, content_type, result);
    }

    const EncodeParam = enum { writer, allocator, value };

    inline fn encodeArg(
        comptime param: EncodeParam,
        out: *std.Io.Writer,
        arena: std.mem.Allocator,
        value: anytype,
    ) switch (param) {
        .writer => *std.Io.Writer,
        .allocator => std.mem.Allocator,
        .value => @TypeOf(value),
    } {
        return switch (param) {
            .writer => out,
            .allocator => arena,
            .value => value,
        };
    }

    fn encodeParams(comptime F: type) []const EncodeParam {
        const types = paramTypes(F);
        var params: [types.len]EncodeParam = undefined;
        var writers = 0;
        var values = 0;
        for (types, &params) |T, *param| {
            param.* = if (T == *std.Io.Writer) .writer else if (T == std.mem.Allocator) .allocator else .value;
            switch (param.*) {
                .writer => writers += 1,
                .allocator => {},
                .value => values += 1,
            }
        }
        if (writers != 1 or values != 1 or types.len > 3) {
            @compileError("encode: expected a *std.Io.Writer parameter and one for the value, besides an optional std.mem.Allocator");
        }
        const final = params;
        return &final;
    }

    /// Ends a body a template or an encoder wrote, throwing it away if it
    /// failed.
    fn endBody(self: *Response, w: *BodyWriter, content_type: ?http.ContentType, result: anytype) !void {
        result catch |err| {
            const ended = w.end();
            self.clearWriter();
            if (err == error.WriteFailed) try ended;
            return err;
        };
        try w.end();
        if (content_type) |value| self.content_type = value;
    }

    /// Formats the body, sent as `content_type`, or as whatever the
    /// response already has when it is null.
    pub fn print(self: *Response, content_type: ?http.ContentType, comptime fmt: []const u8, args: anytype) (BodyWriter.Error || http.MisuseError)!void {
        var w = try self.writer();
        w.interface.print(fmt, args) catch {
            w.end() catch |err| {
                self.clearWriter();
                return err;
            };
            unreachable; // the body writer records every failure
        };
        try w.end();
        if (content_type) |value| self.content_type = value;
    }

    fn RenderArgs(comptime template: anytype) type {
        if (@TypeOf(template) == type) {
            const params = paramTypes(@TypeOf(template.render));
            if (params.len != 2) @compileError("render: expected " ++ @typeName(template) ++ ".render(args, writer)");
            return params[0] orelse @compileError("render: " ++ @typeName(template) ++ ".render takes anytype args");
        }
        const params = paramTypes(@TypeOf(template));
        if (params.len == 0 or params[params.len - 1] != *std.Io.Writer) {
            @compileError("render: the last parameter must be *std.Io.Writer");
        }
        var types: [params.len - 1]type = undefined;
        for (params[0 .. params.len - 1], &types) |param, *T| {
            T.* = param orelse @compileError("render: template parameters must not be anytype");
        }
        return @Tuple(&types);
    }

    /// Zig 0.17 replaced `params` with `param_types`.
    fn paramTypes(comptime F: type) []const ?type {
        const info = @typeInfo(F).@"fn";
        if (@hasField(@TypeOf(info), "param_types")) return info.param_types;
        var types: [info.params.len]?type = undefined;
        for (info.params, &types) |param, *T| T.* = param.type;
        const final = types;
        return &final;
    }

    /// Adds a `Set-Cookie` header: `try res.setCookie("theme", "dark",
    /// .{ .path = "/", .max_age = .fromSeconds(86400) })`. Fails once the
    /// headers have gone out, or on a name or value a cookie cannot carry.
    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, opts: CookieOpts) !void {
        if (self._headers_written) return error.HeadersAlreadySent;
        const serialized = try serializeCookie(self.arena, name, value, opts);
        try http.validateHeaderValue(serialized);
        if (!self.headerRoom(1)) return error.TooManyHeaders;
        try self.headers.add("Set-Cookie", serialized);
    }

    /// Opens a Server-Sent Events body.
    ///
    /// `buf` is what an event is assembled in before it goes at the
    /// connection, and since the body is chunked it is also the chunk size,
    /// unless the body is compressed. One write per event is the point, so
    /// size it so an ordinary event does not split across two.
    pub fn startEventStream(self: *Response, buf: []u8) !EventStream {
        try self.header("Content-Type", "text/event-stream");
        try self.header("Cache-Control", "no-cache");
        // Chunked, like any other body of unknown length. An event stream
        // could be delimited by closing the connection instead, but then a
        // peer cannot tell a stream that ended from one that was cut, and
        // the connection is spent either way.
        //
        // A HEAD gets the headers an event stream would have opened with
        // and none of the events; the body writer already drops what it is
        // given for a HEAD, so no send has to ask.
        return .{ .body = try self.stream(buf) };
    }

    /// Whether `detach` would work: the engine supports it, nothing has
    /// gone out, and every middleware the request passed is detach-safe.
    pub fn canDetach(self: *const Response) bool {
        return self._detach_engine != null and !self._detach_park_only and !self._detach_blocked and self.detached == null and !self._headers_written;
    }

    /// Whether `_park` would work: an engine that parks (HTTP/1.1 with a
    /// connection to adopt, HTTP/2) and no middleware on the way that is
    /// not detach-safe. Internal.
    pub fn _canPark(self: *const Response) bool {
        if (self._detach_blocked or self._parked or self._headers_written or self.detached != null) return false;
        if (self._sink != null) {
            const engine = self._detach_engine orelse return false;
            return engine.park != null;
        }
        const conn = self._conn orelse return false;
        return conn.adopter == null and !conn.upgraded and self.status != .switching_protocols;
    }

    /// Writes the head (status and headers as set; chunked over HTTP/1.1)
    /// and parks the response (see `Parked`). The handler returns right
    /// after; `write` at the handler's end does nothing for a parked
    /// response. `error.Unsupported` when `_canPark` is false (nothing
    /// written). Internal.
    pub fn _park(self: *Response, req: *Request, owner: Parked.Owner) error{ Unsupported, OutOfMemory, WriteFailed }!*Parked {
        if (!self._canPark()) return error.Unsupported;
        if (self._sink != null) {
            const d = try self.detachUnchecked(req, .{ .abort = parkedNoAbort, .ctx = self });
            // Detached already: on failure the engine ends the stream.
            return d.response.parkAfterHead(d, owner);
        }
        const conn = self._conn.?;
        // The request buffers' pages go back before anything is written,
        // as for an upgrade; nothing the handler may still read is lost.
        conn.shrinkForUpgrade();
        self.status = .ok;
        var w = self.stream(&.{}) catch return error.WriteFailed;
        _ = &w;
        // The head is out and the writer is the park's from here.
        self._body_writer_open = false;
        self._written = true;
        self._parked = true;
        conn.finishUpgrade();
        const chunked = self._chunked;
        // The connection is the parked stream's: the server hands it to
        // the adopter instead of waiting for a next request.
        self.keepalive = false;
        const h1 = Parked_H1.create(conn, chunked, owner) catch return error.OutOfMemory;
        conn.adopter = &h1.adopter;
        return &h1.parked;
    }

    /// `_park` for a response already detached (`detach`), such as the C
    /// ABI's requests on HTTP/2: the head goes out and the response parks,
    /// with `d` still owned by the engine. Internal.
    pub fn _parkDetached(d: *Detached, owner: Parked.Owner) error{ Unsupported, OutOfMemory, WriteFailed }!*Parked {
        if (d.response._sink == null or d.engine.park == null) return error.Unsupported;
        if (d.response._parked or d.response._headers_written) return error.Unsupported;
        return d.response.parkAfterHead(d, owner);
    }

    fn parkAfterHead(self: *Response, d: *Detached, owner: Parked.Owner) error{ OutOfMemory, WriteFailed }!*Parked {
        // The engine routes the body away from its ordinary queue first
        // (a parked stream has no buffer of its own), then the head is
        // recorded and goes out.
        const p = d.engine.park.?(d, owner) catch |err| {
            d.finish(err);
            return err;
        };
        var w = self.stream(&.{}) catch |err| {
            d.finish(err);
            p.release();
            return error.WriteFailed;
        };
        _ = &w;
        self._body_writer_open = false;
        self._parked = true;
        return p;
    }

    fn parkedNoAbort(ctx: *anyopaque) void {
        _ = ctx;
    }

    /// Whether the handler detached the response (`detach`): a detach-safe
    /// middleware that does work after `next.call()` puts it off with
    /// `onFinish` instead.
    pub fn isDetached(self: *const Response) bool {
        return self.detached != null;
    }

    /// Detaches the response from the handler (see `Detached`): the handler
    /// returns, and `finish` on the result, later and on this request's
    /// executor, writes the response. The engine moves the request and
    /// the response to memory that lives until then: from here on, use
    /// `d.request` and `d.response` (`req` and `self` go when the handler
    /// returns). `owner.abort` runs instead if the request goes away
    /// first. `error.Unsupported` when `canDetach` is false; the handler
    /// then answers as usual (waiting, if it must).
    pub fn detach(self: *Response, req: *Request, owner: Detached.Owner) error{ Unsupported, OutOfMemory }!*Detached {
        if (!self.canDetach()) return error.Unsupported;
        return self.detachUnchecked(req, owner);
    }

    fn detachUnchecked(self: *Response, req: *Request, owner: Detached.Owner) error{ OutOfMemory }!*Detached {
        const d = try self.arena.create(Detached);
        d.* = .{
            .request = req,
            .response = self,
            .engine = self._detach_engine.?,
            .engine_ctx = self._detach_ctx.?,
            .owner = owner,
        };
        self.detached = d;
        d.engine_ctx = d.engine.relocate(d) catch |err| {
            self.detached = null;
            return err;
        };
        return d;
    }

    /// For a detach-safe middleware whose `next.call()` returned with
    /// the response detached: `f` runs when the response is finished, in
    /// place of the work the middleware would have done after `next()`.
    /// `f` lives in the request's arena or longer.
    pub fn onFinish(self: *Response, f: *Detached.Finisher) void {
        const d = self.detached orelse return;
        f.next = null;
        if (d.last) |l| l.next = f else d.first = f;
        d.last = f;
    }

    /// Hands the connection over to `adopter` (see `Adopter`) once the
    /// handler returns, rather than closing it: for a protocol the request
    /// upgraded to that serves the connection without a task of its own
    /// while it is idle (a WebSocket with callbacks). Over HTTP/1.1 only,
    /// after the 101 went out (`_upgradeWebSocket`). From then on, whatever
    /// the handler does, `adopter.release` runs when the connection closes.
    /// The request and this response end with the handler.
    pub fn adopt(self: *Response, adopter: *Adopter) error{Unsupported}!void {
        if (self._sink != null or !self._headers_written) return error.Unsupported;
        // A 101, or a streamed 200 (a parked event stream).
        if (self.status != .switching_protocols and !(self._streaming or self._chunked)) return error.Unsupported;
        self._conn.?.adopter = adopter;
    }

    /// Upgrades an HTTP/1.1 connection to a WebSocket, or returns null when
    /// the request is not a valid upgrade. HTTP/1.1 only: `app.ws` and
    /// `anole.websocket.upgrade` also cover HTTP/2 and HTTP/3.
    pub fn _upgradeWebSocket(self: *Response, req: *Request) !?WebSocket {
        // An upgrade belongs to HTTP/1.1; HTTP/2 has its own way to carry a
        // WebSocket (RFC 8441), which a sink does not offer.
        if (self._sink != null) return null;
        // RFC 6455 §4.2.1: a GET, with a key of 16 bytes in base64.
        if (!WebSocketModule.isHandshake(req)) return null;
        const key = req.headers.get("Sec-WebSocket-Key").?;

        // Compute accept key
        var accept_key: [28]u8 = undefined;
        WebSocket.computeAcceptKey(key, &accept_key);

        // Send 101 Switching Protocols response
        self.status = .switching_protocols;
        try self.header("Upgrade", "websocket");
        try self.putHeader("Connection", "Upgrade");
        try self.header("Sec-WebSocket-Accept", &accept_key);
        self._streaming = true;
        // The connection is a WebSocket's from here: small windows, and the
        // request buffers' other pages back to the OS, the 101 included. It
        // cannot serve another request after that.
        self._conn.?.shrinkForUpgrade();
        errdefer self.keepalive = false;
        try self.writeHeader();
        self._conn.?.finishUpgrade();
        // The connection is the WebSocket's now, and whatever the peer sends
        // after the session is not an HTTP request.
        self.keepalive = false;

        var seed: u64 = undefined;
        req.io.random(std.mem.asBytes(&seed));
        return WebSocket.init(req.io, self._conn.?.transport(), self.arena, seed);
    }

    /// Turns the sentinel a `std.Io.Writer` reports into the cause the
    /// connection recorded. The one place that answer is worked out: every
    /// public entry point on the response and on the body writers over it
    /// funnels its writes through here, so the sentinel never reaches a
    /// caller. Only a `drain`, whose error set the vtable fixes, cannot --
    /// which is what the writers' `err` fields are for.
    fn resolve(self: *Response, result: std.Io.Writer.Error!void) SendError!void {
        result catch |err| switch (err) {
            error.WriteFailed => {
                const cause: SendError = if (self._sink) |sink|
                    (sink.writeError() orelse error.Unexpected)
                else
                    (self._conn.?.getWriteError() orelse error.Unexpected);
                // A write that was canceled after its own deadline passed
                // was the write timeout's doing (the cancel stays pending
                // for the engine, which closes the connection or the stream).
                if (cause == error.Canceled) if (self._write_deadline) |d| {
                    if (std.Io.Clock.Timestamp.now(self.io, .awake).compare(.gte, d)) {
                        self.keepalive = false;
                        return error.WriteTimeout;
                    }
                };
                return cause;
            },
        };
    }

    /// Ends the request deadline for a body that may take long to go out
    /// (a stream, a file): from now each write has `timeouts.write` instead.
    /// A deadline the handler set itself is kept.
    fn liftDeadline(self: *Response) void {
        const req = self._request orelse return;
        if (req._deadline_from_handler or self._stream_mode) return;
        req._applyDeadline(.none);
        self._stream_mode = true;
    }

    /// Starts timing one hand-off of bytes to the connection.
    fn armWrite(self: *Response) void {
        if (!self._stream_mode) return;
        const d = self._write_timeout orelse return;
        const req = self._request orelse return;
        self._write_deadline = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = d, .clock = .awake });
        req._applyDeadline(.{ .duration = .{ .raw = d, .clock = .awake } });
    }

    /// Stops timing it.
    fn disarmWrite(self: *Response) void {
        if (!self._stream_mode) return;
        const req = self._request orelse return;
        if (self._write_deadline == null) return;
        self._write_deadline = null;
        req._applyDeadline(.none);
    }

    /// Puts `content_type` into the headers. Before `headers_written` is
    /// set, so it goes through the same door as every other header rather
    /// than around it.
    fn applyContentType(self: *Response) HeaderError!void {
        if (self.content_type) |content_type| {
            try self.header("Content-Type", content_type.toContentType());
        }
    }

    /// A HEAD sends none of its body, and neither does a status that has
    /// none, whatever the handler wrote.
    fn sendsBody(self: *const Response) bool {
        return !self.head and statusHasBody(self.status);
    }

    const compression_level: zlib.Level = .default;

    /// A buffered body shorter than this is sent as it is, without trying:
    /// gzip adds 18 bytes of its own.
    const min_compress_len = 128;

    /// What `negotiateCompression` settled on.
    const Compression = enum {
        /// Not asked for, or not for this response.
        off,
        /// Applies, but this client takes no coding we have. The response
        /// still varies by `Accept-Encoding`.
        identity,
        gzip,
        zstd,
        br,

        fn isCoding(c: Compression) bool {
            return c == .gzip or c == .zstd or c == .br;
        }

        fn name(c: Compression) []const u8 {
            return @tagName(c);
        }
    };

    /// Whether compression applies to this response at all, and if so,
    /// which of our codings the client takes.
    ///
    /// Settles nothing: the headers that say so go on with `addVary` and
    /// `markCompressed`, which have their room reserved here, so that
    /// nothing fails after a response has started claiming a coding.
    fn negotiateCompression(self: *Response) Compression {
        if (!(build_options.use_zlib or build_options.use_zstd or build_options.use_brotli) or !self.compress) return .off;
        if (self.file != null) return .off;
        // A tunnel (RFC 8441), not a representation.
        if (self._request) |r| if (r.protocol != null) return .off;
        const not_modified = self.status == .not_modified;
        if (!not_modified and !statusHasBody(self.status)) return .off;
        if (self.status == .partial_content) return .off;
        // The handler framed, coded or cut the body itself.
        if (self.headers.get("Content-Encoding") != null) return .off;
        if (self.headers.get("Content-Length") != null) return .off;
        if (self.headers.get("Content-Range") != null) return .off;
        // Already compressed media gains nothing and costs CPU.
        const content_type = self.headers.get("Content-Type") orelse if (self.content_type) |ct| ct.toContentType() else null;
        if (!http.isCompressible(content_type)) return .off;

        // Content-Encoding, except on a 304, and Vary if it is not there
        // yet. Without the room the body goes out as it is, which no cache
        // can get wrong.
        var needed: usize = if (not_modified) 0 else 1;
        if (!self.variesByAcceptEncoding()) needed += 1;
        if (!self.headerRoom(needed)) return .off;

        const request = self._request orelse return .identity;
        // The client's q-values first; on a tie, zstd, then Brotli, then
        // gzip. zstd compresses about as well as gzip at a third of the
        // time; Brotli at quality 5 is 10-15% smaller than either on JSON
        // of a few KiB, at about twice gzip's time.
        const zstd_q: u16 = if (build_options.use_zstd) http.encodingQuality(&request.headers, "zstd") else 0;
        const br_q: u16 = if (build_options.use_brotli) http.encodingQuality(&request.headers, "br") else 0;
        const gzip_q: u16 = if (build_options.use_zlib) http.encodingQuality(&request.headers, "gzip") else 0;
        if (zstd_q == 0 and br_q == 0 and gzip_q == 0) return .identity;
        if (zstd_q >= br_q and zstd_q >= gzip_q) return .zstd;
        return if (br_q >= gzip_q) .br else .gzip;
    }

    /// `Vary: *` included, which says the response varies by anything.
    fn variesByAcceptEncoding(self: *const Response) bool {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            if (!std.ascii.eqlIgnoreCase(entry.key, "Vary")) continue;
            var names = std.mem.splitScalar(u8, entry.value, ',');
            while (names.next()) |item| {
                const name = std.mem.trim(u8, item, " \t");
                if (std.mem.eql(u8, name, "*") or std.ascii.eqlIgnoreCase(name, "Accept-Encoding")) return true;
            }
        }
        return false;
    }

    fn addVary(self: *Response) void {
        if (self.variesByAcceptEncoding()) return;
        self.headers.add("Vary", "Accept-Encoding") catch unreachable; // reserved
    }

    /// Says the body is gzipped. A strong `ETag` promises the same bytes as
    /// the uncompressed body would have, so it is weakened, or dropped if
    /// there is no memory to weaken it with. `Accept-Ranges` goes too: a
    /// range would be taken of the gzipped bytes, which the handler's own
    /// range support knows nothing about.
    ///
    /// A 304 gets the validators of the gzipped 200 it stands in for, but
    /// no `Content-Encoding`: RFC 9110 §15.4.5 leaves representation
    /// metadata off it.
    fn markCompressed(self: *Response, coding: Compression) void {
        _ = self.headers.remove("Accept-Ranges");
        if (self.headers.get("ETag")) |etag| {
            if (!std.mem.startsWith(u8, etag, "W/")) {
                if (std.fmt.allocPrint(self.arena, "W/{s}", .{etag})) |weak| {
                    self.headers.put("ETag", weak) catch unreachable; // replaces
                } else |_| {
                    _ = self.headers.remove("ETag");
                }
            }
        }
        if (self.status == .not_modified) return;
        self.headers.add("Content-Encoding", coding.name()) catch unreachable; // reserved
    }

    /// Replaces the buffered body with its gzipped form, unless it is short
    /// or would not shrink. A failure to allocate sends the body as it was.
    fn compressBody(self: *Response, coding: Compression) void {
        const len = self.bodyLen();
        if (len < min_compress_len) return;
        const compressed = switch (coding) {
            .zstd => if (build_options.use_zstd) self.zstdBody(len) catch return else unreachable,
            .br => if (build_options.use_brotli) self.brotliBody(len) catch return else unreachable,
            else => self.deflateBody(len) catch return,
        };
        if (compressed.len() >= len) return;
        self.body_buffer = compressed;
        self.body = "";
        self.markCompressed(coding);
    }

    /// The buffered body as one zstd frame. The window shrinks to the body
    /// on its own, since the length is known.
    fn zstdBody(self: *Response, len: usize) (std.mem.Allocator.Error || std.Io.Writer.Error || error{CompressFailed})!BodyBuffer {
        var compressed: BodyBuffer = try .init(self.arena);
        var out: BodyWriter = .into(self, &compressed);
        var z: zstd_io.Compress = undefined;
        try z.init(self.arena, &out.interface, &.{}, .{ .window_log = null, .pledged_size = len });
        if (self.body_buffer.len() > 0) try self.body_buffer.writeTo(&z.writer) else try z.writer.writeAll(self.body);
        try z.finish();
        try out.interface.flush();
        return compressed;
    }

    /// The buffered body as one Brotli stream, its window fitted to it.
    fn brotliBody(self: *Response, len: usize) (std.mem.Allocator.Error || std.Io.Writer.Error || error{CompressFailed})!BodyBuffer {
        var compressed: BodyBuffer = try .init(self.arena);
        var out: BodyWriter = .into(self, &compressed);
        var z: brotli_io.Compress = undefined;
        try z.init(&out.interface, &.{}, .{ .quality = self._brotli_quality, .lgwin = brotli_io.windowFor(len), .size_hint = len });
        defer z.deinit();
        if (self.body_buffer.len() > 0) try self.body_buffer.writeTo(&z.writer) else try z.writer.writeAll(self.body);
        try z.finish();
        try out.interface.flush();
        return compressed;
    }

    fn deflateBody(self: *Response, len: usize) (std.mem.Allocator.Error || std.Io.Writer.Error)!BodyBuffer {
        var compressed: BodyBuffer = try .init(self.arena);
        var out: BodyWriter = .into(self, &compressed);
        // Sized to the body, and zlib's memory with it: a window much past
        // the body finds nothing more to match. That memory (140 KiB and
        // more) comes from `block_cache`, not the arena: an HTTP/2 or
        // HTTP/3 stream's arena keeps less than that between requests, so
        // it would be mapped again for each one.
        const window_bits: u4 = @intCast(std.math.clamp(std.math.log2_int_ceil(usize, len), 9, 15));
        var gzip = try zlib.Compress.init(block_cache.allocator, &out.interface, &.{}, .gzip, .{
            .level = compression_level,
            .window_bits = window_bits,
            // Any less and the symbol buffer ends deflate blocks early
            // enough to cost a few percent on bodies of about 512 bytes.
            .mem_level = @min(window_bits - 6, 8),
        });
        defer gzip.deinit();
        if (self.body_buffer.len() > 0) try self.body_buffer.writeTo(&gzip.writer) else try gzip.writer.writeAll(self.body);
        try gzip.finish();
        try out.interface.flush();
        return compressed;
    }

    /// Body bytes on the wire, framed as the headers said: a chunk, or as
    /// they are.
    fn sendFramed(
        self: *Response,
        pending: []const u8,
        data: []const []const u8,
        splat: usize,
        total: usize,
    ) std.Io.Writer.Error!void {
        const out = self.bodyOut();
        if (self._chunked) {
            // 16 hex digits covers any usize, plus the CRLF.
            var size_buf: [18]u8 = undefined;
            try out.writeAll(std.fmt.bufPrint(&size_buf, "{x}\r\n", .{total}) catch unreachable);
        }
        try out.writeAll(pending);
        for (data[0 .. data.len - 1]) |bytes| try out.writeAll(bytes);
        try out.splatBytesAll(data[data.len - 1], splat);
        if (self._chunked) try out.writeAll("\r\n");
        try out.flush();
    }

    /// Sends the headers ahead of a body that is not buffered: a stream,
    /// or a protocol upgrade. A buffered body goes out with its headers in
    /// `write`, once its length is known.
    fn writeHeader(self: *Response) WriteError!void {
        if (self._headers_written) return;
        try self.applyContentType();
        self._headers_written = true;
        return self.resolve(self.sendHeaderAlone(self.bodyOut()));
    }

    /// The headers with nothing behind them. `write` sends them with a body
    /// and flushes once for both; everything else -- a streaming body, an
    /// event stream, a WebSocket -- has nothing queued, and the headers
    /// must not wait in the buffer for a body that may be seconds away, or
    /// that is the peer's turn to send.
    fn sendHeaderAlone(self: *Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.sendHeader(w);
        return w.flush();
    }

    /// The header block on the wire. Reports the sentinel, as anything
    /// writing to a `std.Io.Writer` does; the public entry point resolves it.
    fn sendHeader(self: *Response, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self._sink) |sink| {
            try self.addSinkDate();
            return sink.head(self.status, &self.headers, self.headLength());
        }

        // Plain writes rather than `print`: a head is on every response, and
        // these are copies into the write buffer, without format parsing.
        try w.writeAll("HTTP/1.1 ");
        try writeDecimal(w, @backingInt(self.status));
        try w.writeByte(' ');
        try w.writeAll(self.status.phrase());
        try w.writeAll("\r\n");
        if (self._send_date and self.headers.get("Date") == null) {
            try w.writeAll("Date: ");
            try w.writeAll(http.currentHttpDate(self.io));
            try w.writeAll("\r\n");
        }

        // Write headers
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            try w.writeAll(entry.key);
            try w.writeAll(": ");
            try w.writeAll(entry.value);
            try w.writeAll("\r\n");
        }

        // Write Connection header based on keepalive. HTTP/1.0 is
        // close-by-default, so a 1.0 peer that asked to keep the connection
        // only does so when told it was kept (RFC 9112 §9.3, appendix C.2.2);
        // without this it waits for an EOF that never comes.
        if (!self.keepalive) {
            try w.writeAll("Connection: close\r\n");
        } else if (self.http10) {
            try w.writeAll("Connection: keep-alive\r\n");
        }

        // Framing, for a status that has a body to frame. RFC 9112 §6.1
        // and RFC 9110 §8.6 forbid both headers on a 1xx or 204; a HEAD
        // still reports the length its GET would have.
        if (statusHasBody(self.status)) {
            if (self._chunked) {
                try w.writeAll("Transfer-Encoding: chunked\r\n");
            } else if (!self._streaming) {
                // Write Content-Length if not manually set (skip for streaming responses like SSE)
                const has_content_length = self.headers.get("Content-Length") != null;
                if (!has_content_length) {
                    try w.writeAll("Content-Length: ");
                    try writeDecimal(w, self.bodyLen());
                    try w.writeAll("\r\n");
                }
            }
        }

        // End of headers (applies to both chunked and non-chunked)
        try w.writeAll("\r\n");
    }

    /// Sends what the handler left: the headers, if they have not gone
    /// out, and the body. The server calls it after the handler; a
    /// second call does nothing.
    pub fn write(self: *Response) WriteError!void {
        if (self._written or self._parked) {
            return;
        }
        // An upgrade's 101 went out with it, and the connection is the
        // upgraded protocol's: its writer is not this response's to flush.
        if (self.status == .switching_protocols and self._sink == null and self._conn.?.upgraded) {
            self._written = true;
            return;
        }
        // A handler that failed part way through may never have called
        // `end`. Its buffer is gone, so whatever it held is lost either
        // way; recover rather than take the process down, and make sure a
        // started body is still framed correctly.
        if (self._body_writer_open) {
            self._body_writer_open = false;
            // A body writer that was never ended goes out as far as it was
            // last flushed, framed to match.
            self._body_writer_buffering = false;
            // Streaming under way with a declared length: whatever the
            // writer still held is gone with the handler's buffer, so the
            // body is short. Nothing can make it match the length we
            // promised, and the connection must not be reused -- the peer
            // would read the next response as this body. A chunked body
            // needs no such care: `sendBody` terminates it, and a
            // truncated but well framed body is one the peer can finish,
            // though a gzipped one will not decode to the end.
            if (self._headers_written and !self._chunked) {
                if (self.content_length) |declared| {
                    if (self.body_sent != declared) self.keepalive = false;
                }
            }
            // If nothing was sent yet, a buffered body lives in the arena
            // and is still good, so leave it be: an error handler that
            // built a replacement has already cleared it.
        }
        self._written = true;
        defer self.closeFile();

        // Already false for a chunked response: the streaming writer
        // settled the headers when it sent them.
        const send_header = !self._headers_written;
        if (send_header) {
            try self.applyContentType();
            if (self._default_content_type) |default| {
                if (self.file == null and self.bodyLen() > 0 and self.headers.get("Content-Type") == null) {
                    try self.header("Content-Type", default.toContentType());
                }
            }
            const compression = self.negotiateCompression();
            if (compression != .off) self.addVary();
            if (compression.isCoding()) {
                if (self.status == .not_modified) self.markCompressed(compression) else self.compressBody(compression);
            }
            self._headers_written = true;
        }

        // A length promised by a Content-Length the handler set itself: a
        // body of another length cannot be framed as promised, and the
        // connection cannot carry another response after it.
        // A streamed body is the streaming writer's to account for.
        if (self.sendsBody() and !self._chunked and !self._streaming and self.content_length == null) {
            if (try self.declaredLength()) |declared| {
                if (self.bodyLen() != declared) {
                    self.keepalive = false;
                    return error.ContentLengthMismatch;
                }
            }
        }
        if (self.file) |body| {
            if (send_header) try self.resolve(self.sendHeader(self.bodyOut()));
            self.liftDeadline();
            if (self.sendsBody()) try self.sendFileBody(body);
            self.armWrite();
            defer self.disarmWrite();
            return self.resolve(self.finish(self.bodyOut()));
        }
        // A whole body in memory goes to a sink that takes it in one call.
        if (send_header) if (self._sink) |sink| if (sink.canComplete()) {
            return self.resolve(self.completeSink(sink));
        };
        return self.resolve(self.sendBody(self.bodyOut(), send_header));
    }

    /// The head, a body in memory and the end, in one call to the sink.
    fn completeSink(self: *Response, sink: Sink) std.Io.Writer.Error!void {
        try self.addSinkDate();
        var parts: []const []const u8 = &.{};
        if (self.sendsBody()) {
            if (self.body_buffer.len() > 0) {
                var count: usize = 0;
                var it = self.body_buffer.segments.first;
                while (it) |node| : (it = node.next) count += 1;
                const list = self.arena.alloc([]const u8, count) catch return error.WriteFailed;
                var i: usize = 0;
                it = self.body_buffer.segments.first;
                while (it) |node| : (it = node.next) {
                    const segment = BodyBuffer.Segment.fromNode(node);
                    list[i] = segment.bytes()[0..segment.len];
                    i += 1;
                }
                parts = list;
            } else if (self.body.len > 0) {
                parts = (&self.body)[0..1];
            }
        }
        return sink.complete(self.status, &self.headers, self.headLength(), parts, if (self.trailers) |*t| t else null);
    }

    /// A sink's head carries a Date of its own: the cached one is per
    /// thread and short-lived, and the sink may send the head from another
    /// task.
    fn addSinkDate(self: *Response) std.Io.Writer.Error!void {
        if (self._send_date and self.headers.get("Date") == null) {
            const date = self.arena.dupe(u8, http.currentHttpDate(self.io)) catch return error.WriteFailed;
            self.putHeader("Date", date) catch {};
        }
    }

    /// How much of a file is handed to the connection at a time.
    const file_piece: usize = 1 << 20;

    fn sendFileBody(self: *Response, body: BodyFile) WriteError!void {
        if (body.size == 0) return;
        // Unbuffered: without a sendfile of its own, the `Io` reads the
        // file straight into the connection's write buffer.
        var reader = body.handle.reader(self.io, &.{});
        reader.seekTo(body.offset) catch unreachable; // a new reader is positional
        // In pieces, so that `timeouts.write` bounds each hand-off to the
        // peer rather than the whole download.
        var left = body.size;
        while (left > 0) {
            const piece = @min(left, file_piece);
            self.armWrite();
            defer self.disarmWrite();
            const sent = self.bodyOut().sendFileAll(&reader, .limited(piece)) catch |err| switch (err) {
                error.WriteFailed => {
                    self.keepalive = false;
                    return self.resolve(error.WriteFailed);
                },
                error.ReadFailed => {
                    self.keepalive = false;
                    if (reader.err) |e| if (e == error.Canceled) return error.Canceled;
                    return error.ContentLengthMismatch;
                },
            };
            // The file shrank since it was opened, and the length already
            // went out with the headers.
            if (sent != piece) {
                self.keepalive = false;
                return error.ContentLengthMismatch;
            }
            left -= piece;
        }
    }

    /// The Content-Length the handler set, if it did.
    fn declaredLength(self: *const Response) error{InvalidContentLength}!?usize {
        const value = self.headers.get("Content-Length") orelse return null;
        return std.fmt.parseInt(usize, value, 10) catch error.InvalidContentLength;
    }

    /// The length of a body held in memory, as it stands (what a body
    /// writer collected, else `body`), for middleware that keeps whole
    /// responses after the handler (`anole.middleware.ResponseCache`);
    /// `copyBody` takes its bytes. Null for any other: a file, a stream,
    /// a body writer still open, or headers already sent.
    pub fn memoryBodyLen(self: *const Response) ?usize {
        if (self.file != null or self._headers_written or self._body_writer_open or self._streaming or self._chunked) return null;
        return self.bodyLen();
    }

    /// Copies a body held in memory into `out`, `memoryBodyLen` bytes.
    pub fn copyBody(self: *const Response, out: []u8) void {
        if (self.body_buffer.len() == 0) return @memcpy(out[0..self.body.len], self.body);
        var at: usize = 0;
        var it = self.body_buffer.segments.first;
        while (it) |node| : (it = node.next) {
            const segment = BodyBuffer.Segment.fromNode(node);
            @memcpy(out[at..][0..segment.len], segment.bytes()[0..segment.len]);
            at += segment.len;
        }
    }

    /// The length of the body as set so far: what the body writer
    /// collected, else the `body` field.
    fn bodyLen(self: *const Response) usize {
        if (self.file) |body| return body.size;
        const written = self.body_buffer.len();
        return if (written > 0) written else self.body.len;
    }

    /// Whatever this response still owes the peer, on the wire. Reports the
    /// sentinel, as anything writing to a `std.Io.Writer` does; `write`
    /// resolves it.
    fn sendBody(self: *Response, w: *std.Io.Writer, send_header: bool) std.Io.Writer.Error!void {
        if (self._chunked) {
            // A streaming writer sent the headers; all that is left is the
            // terminator, which is body framing and so is not sent for a
            // HEAD either.
            if (self.sendsBody()) try w.writeAll("0\r\n\r\n");
            return self.finish(w);
        }

        if (send_header) try self.sendHeader(w);

        // Write body (either from buffer or body field). A HEAD response
        // has already reported its length and must stop here.
        if (self.sendsBody()) {
            if (self.body_buffer.len() > 0) {
                try self.body_buffer.writeTo(w);
            } else {
                try w.writeAll(self.body);
            }
        }

        return self.finish(w);
    }

    /// The body length the head announces to a sink: the length a buffered
    /// body or file has (a HEAD reports its GET's), a declared one for a
    /// stream, and null for a stream of unknown length or a status that has
    /// no body.
    fn headLength(self: *const Response) ?usize {
        if (!statusHasBody(self.status)) return null;
        if (self._streaming or self._chunked) return self.content_length;
        return self.bodyLen();
    }
};

/// `n` in decimal, as `print("{d}")` writes it.
fn writeDecimal(w: *std.Io.Writer, n: usize) std.Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = n;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    return w.writeAll(buf[i..]);
}

fn writeJsonString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(text, .{}, w);
}

/// The detail of a problem that has errors and no detail of its own.
fn problemDetail(w: *std.Io.Writer, p: http.Problem) std.Io.Writer.Error!void {
    if (p.truncated) return w.print("More than {d} fields are invalid; the first {d} are listed.", .{ p.errors.len, p.errors.len });
    if (p.errors.len == 1) return w.writeAll("1 field is invalid.");
    return w.print("{d} fields are invalid.", .{p.errors.len});
}

fn writeProblem(w: *std.Io.Writer, p: http.Problem) std.Io.Writer.Error!void {
    try w.writeAll("{\"type\":");
    try writeJsonString(w, p.type);
    try w.writeAll(",\"title\":");
    try writeJsonString(w, p.title orelse p.status.phrase());
    try w.print(",\"status\":{d}", .{@backingInt(p.status)});
    if (p.detail) |d| {
        try w.writeAll(",\"detail\":");
        try writeJsonString(w, d);
    } else if (p.errors.len > 0) {
        var buf: [96]u8 = undefined;
        var dw: std.Io.Writer = .fixed(&buf);
        try problemDetail(&dw, p);
        try w.writeAll(",\"detail\":");
        try writeJsonString(w, dw.buffered());
    }
    if (p.instance) |i| {
        try w.writeAll(",\"instance\":");
        try writeJsonString(w, i);
    }
    if (p.errors.len > 0) {
        try w.writeAll(",\"errors\":[");
        for (p.errors, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"in\":\"");
            try w.writeAll(@tagName(e.in));
            try w.writeByte('"');
            if (e.field) |f| {
                try w.writeAll(",\"field\":");
                try writeJsonString(w, f);
            }
            try w.writeAll(",\"code\":");
            try writeJsonString(w, e.code);
            try w.writeAll(",\"message\":");
            try writeJsonString(w, e.message);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

test writeDecimal {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for ([_]usize{ 0, 7, 10, 200, 404, 1234567890, std.math.maxInt(usize) }) |n| {
        w.end = 0;
        try writeDecimal(&w, n);
        var expected: [32]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d}", .{n}), w.buffered());
    }
}

/// The body a response has collected, in one piece, for comparing.
fn testBody(response: *const Response, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try response.body_buffer.writeTo(&w);
    return w.buffered();
}

test "Response: body used when buffer is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "body content";

    // Don't write to buffer
    try std.testing.expectEqual(0, response.body_buffer.len());

    // Body should be used
    try std.testing.expectEqualStrings("body content", response.body);
}

test "Response: write() with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "Hello World";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 11") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello World") != null);
}

test "Response: write() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "First";

    try response.write();
    const first_len = conn_writer.end;

    // Try writing again with different body
    response.body = "Second";
    try response.write();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: writeHeader() basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.header("X-Custom", "value");
    response.body = "Hello";

    try response.writeHeader();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: value") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    // Body should not be written yet
    try std.testing.expect(std.mem.indexOf(u8, written, "Hello") == null);
}

test "Response: writeHeader() only writes once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "Test";

    try response.writeHeader();
    const first_len = conn_writer.end;

    // Try writing header again with different status
    response.status = .bad_request;
    try response.writeHeader();

    // Should still be the same length (no second write)
    try std.testing.expectEqual(first_len, conn_writer.end);
}

test "Response: write() after writeHeader() doesn't duplicate headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "Body content";

    // Write headers first
    try response.writeHeader();
    const header_len = conn_writer.end;

    // Now write the full response (should only add body)
    try response.write();
    const full_len = conn_writer.end;

    // Check that body was added
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Body content") != null);

    // Length should have increased by body length only
    try std.testing.expect(full_len > header_len);
    try std.testing.expectEqual(header_len + "Body content".len, full_len);
}

test "Response: keepalive defaults to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectEqual(true, response.keepalive);

    response.body = "test";
    try response.write();

    const written = conn_writer.buffered();
    // Should not have Connection: close header when keepalive is true
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") == null);
}

test "Response: Connection close header when keepalive is false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.keepalive = false;
    response.body = "test";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") != null);
}

test "Response: chunked flag defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    const response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectEqual(false, response._chunked);
}

test "BodyWriter: sends nothing until the response is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body = try response.writer();
    try body.interface.writeAll("Hello, ");
    try body.interface.writeAll("World!");
    try body.end();

    // The headers are still open: nothing has gone out yet.
    try std.testing.expectEqual(@as(usize, 0), conn_writer.end);
    try std.testing.expect(!response._headers_written);
    try response.header("X-Late", "still allowed");

    try response.write();
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Late: still allowed") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "Hello, World!"));
    try std.testing.expect(!response._chunked);
}

test "BodyWriter: a body larger than one write still arrives whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body = try response.writer();
    for (0..100) |i| try body.interface.print("{d},", .{i});
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "97,98,99,"));
    try std.testing.expect(!response._chunked);
}

test "StreamingBodyWriter: sends the headers immediately and chunks the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try std.testing.expect(response._headers_written);
    // Too late for anyone to change them now.
    try std.testing.expectError(error.HeadersAlreadySent, response.header("X-Late", "no"));

    try body.interface.writeAll("first");
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "\r\n" ++
            "5\r\nfirst\r\n" ++
            "6\r\nsecond\r\n" ++
            "0\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "StreamingBodyWriter: writes between flushes are framed as one chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("aaa");
    try body.interface.writeAll("bbb");
    try body.interface.print("{d}", .{42});
    try body.end();

    // One chunk for all three writes, not three.
    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "8\r\naaabbb42\r\n0\r\n\r\n"));
}

test "StreamingBodyWriter: an empty flush does not terminate the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [1024]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("first");
    try body.interface.flush();
    // Nothing buffered: a zero length chunk here would end the body early.
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    try std.testing.expect(std.mem.endsWith(
        u8,
        conn_writer.buffered(),
        "5\r\nfirst\r\n6\r\nsecond\r\n0\r\n\r\n",
    ));
}

test "StreamingBodyWriter: a declared Content-Length streams without chunk framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [4]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello ");
    try body.interface.writeAll("world");
    try body.end();

    try std.testing.expect(!response._chunked);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 11\r\n" ++
            "\r\n" ++
            "hello world",
        conn_writer.buffered(),
    );
}

test "StreamingBodyWriter: reports a body that does not match the declared length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("short");
    try std.testing.expectError(error.ContentLengthMismatch, body.end());
}

test "StreamingBodyWriter: never writes past a declared Content-Length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "5");

    var body_buf: [4]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hel");
    // Past the length: refused, and nothing of it reaches the wire, which
    // would carry the extra bytes as the start of the next response.
    try std.testing.expectError(error.WriteFailed, body.interface.writeAll("lo, and then some"));
    try std.testing.expectEqual(@as(?StreamingBodyWriter.Error, error.ContentLengthMismatch), body.err);
    try std.testing.expect(!response.keepalive);
    try std.testing.expect(std.mem.indexOf(u8, conn_writer.buffered(), "then") == null);
}

test "Response: framing headers are the server's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderName, response.header("Transfer-Encoding", "chunked"));
    try std.testing.expectError(error.InvalidHeaderName, response.addHeader("transfer-encoding", "chunked"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("Connection", "keep-alive"));
    try std.testing.expectError(error.InvalidHeaderName, response.addHeader("Connection", "close"));
    // A second Content-Length replaces the first rather than joining it.
    try response.addHeader("Content-Length", "5");
    try response.addHeader("Content-Length", "2");
    response.body = "hi";
    try response.write();
    const written = conn_writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "Content-Length"));
    try std.testing.expect(std.mem.endsWith(u8, written, "Content-Length: 2\r\n\r\nhi"));
}

test "StreamingBodyWriter: rejects a Content-Length it cannot parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    // A proxy can forward whatever an upstream sent.
    try response.header("Content-Length", "99999999999999999999999999");

    var body_buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidContentLength, response.stream(&body_buf));
}

test "StreamingBodyWriter: stream reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Too small to hold the headers, so streaming fails at the start.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body_buf: [64]u8 = undefined;
    try std.testing.expectError(error.ConnectionResetByPeer, response.stream(&body_buf));
}

test "StreamingBodyWriter: end reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // What a successful stream puts on the wire before `end` appends the
    // terminator. The failing pass below gets exactly that much room, so the
    // terminator is the first write with nowhere to go.
    const upto_end = blk: {
        var buf: [1024]u8 = undefined;
        var conn_writer: std.Io.Writer = .fixed(&buf);

        var connection: Connection = undefined;
        connection.initWriterForTesting(&conn_writer);

        var response = try Response._init(arena.allocator(), &connection, 32);
        var body_buf: [64]u8 = undefined;
        var body = try response.stream(&body_buf);
        try body.interface.writeAll("hello");
        try body.interface.flush();
        break :blk conn_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..upto_end]);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.interface.flush();

    try std.testing.expectError(error.ConnectionResetByPeer, body.end());
    // A body that could not be framed as promised cannot share the connection.
    try std.testing.expectEqual(false, response.keepalive);
}

test "Response: write reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Too small to hold the status line, so the first write has nowhere to go.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "hello";

    try std.testing.expectError(error.ConnectionResetByPeer, response.write());
}

test "Response: writeHeader reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.ConnectionResetByPeer, response.writeHeader());
}

test "Response: a write that recorded no cause reports Unexpected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The buffer fills with nothing behind it to blame, so there is no
    // cause to resolve to.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "hello";

    try std.testing.expectError(error.Unexpected, response.write());
}

test "Response: no std.Io.Writer sentinel escapes the public write API" {
    // `error.WriteFailed` says only that a write failed, which the caller
    // already knew when it called us. Everything below reaches the
    // connection, and none of it may report the sentinel.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        Response.WriteError,
        ErrorSetOf(Response.writeHeader),
        ErrorSetOf(Response.write),
        ErrorSetOf(Response.stream),
        ErrorSetOf(Response.startEventStream),
        ErrorSetOf(Response._upgradeWebSocket),
        EventStream.Error,
        EventWriter.Error,
    }) |Set| {
        inline for (comptime std.meta.fieldNames(Set)) |e_name| {
            try std.testing.expect(!std.mem.eql(u8, e_name, "WriteFailed"));
        }
    }
}

test "BodyWriter: end is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body = try response.writer();
    try body.interface.writeAll("hello");
    try body.end();
    // The `defer body.end() catch {}` that pairs with the line above.
    try body.end();
    try response.write();

    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "\r\n\r\nhello"));
}

test "StreamingBodyWriter: end does not write a second terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.end();
    try body.end();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "5\r\nhello\r\n0\r\n\r\n"));
    // Exactly one terminator.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOfPos(u8, written, std.mem.indexOf(u8, written, "0\r\n\r\n").? + 1, "0\r\n\r\n"),
    );
}

test "Response: an abandoned buffered body goes out as far as it was flushed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body = try response.writer();
    try body.interface.writeAll("hello");
    try body.interface.flush();
    try body.interface.writeAll(" world");
    // Handler returns without calling end, or flushing again.
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\nhello"));
}

test "Response: an abandoned short body closes the connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello world");
    // Handler returns without end, so the body never leaves its buffer.
    try response.write();

    try std.testing.expectEqual(@as(usize, 0), response.body_sent);
    // The peer would read the next response as this body, so the
    // connection must not be reused.
    try std.testing.expect(!response.keepalive);
}

test "Response: an abandoned chunked body is still terminated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.interface.flush();
    // Handler returns without end.
    try response.write();

    // Truncated, but framed: the peer knows where the body ended.
    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "0\r\n\r\n"));
    try std.testing.expect(response.keepalive);
}

test "StreamingBodyWriter: a failed end does not let write add to the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "11");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    // What an error handler would leave behind after the body started.
    response.body = "error body";
    try body.interface.writeAll("short");
    try std.testing.expectError(error.ContentLengthMismatch, body.end());

    const after_end = conn_writer.end;
    // The `catch {}` half of `defer body.end() catch {}`: the response is
    // finished either way, so this must add nothing.
    try response.write();
    try std.testing.expectEqual(after_end, conn_writer.end);
    try std.testing.expect(!response.keepalive);
}

test "StreamingBodyWriter: a failed end does not leave a second terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("hello");
    try body.end();

    const written = conn_writer.buffered();
    try response.write();
    // Already finished, so nothing more goes out.
    try std.testing.expectEqualStrings(written, conn_writer.buffered());
}

test "Response: json() with simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.json(.{ .name = "Alice", .age = 30 });

    var body_buf: [256]u8 = undefined;
    const buffered = try testBody(&response, &body_buf);
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", buffered);

    // Check that Content-Type was set
    const content_type = response.headers.get("Content-Type");
    try std.testing.expect(content_type != null);
    try std.testing.expectEqualStrings("application/json; charset=UTF-8", content_type.?);
}

test "Response: json() writes complete response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.status = .created;
    try response.json(.{ .id = 123, .message = "Created" });
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 201") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: application/json; charset=UTF-8") != null);
    // Check the actual JSON content length: {"id":123,"message":"Created"}
    const expected_json = "{\"id\":123,\"message\":\"Created\"}";
    try std.testing.expect(std.mem.indexOf(u8, written, expected_json) != null);

    // Build expected content-length string
    var cl_buf: [32]u8 = undefined;
    const cl_str = try std.fmt.bufPrint(&cl_buf, "Content-Length: {d}", .{expected_json.len});
    try std.testing.expect(std.mem.indexOf(u8, written, cl_str) != null);
}

test "Response: json() with array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    const items = [_]i32{ 1, 2, 3, 4, 5 };
    try response.json(items);

    var body_buf: [256]u8 = undefined;
    const buffered = try testBody(&response, &body_buf);
    try std.testing.expectEqualStrings("[1,2,3,4,5]", buffered);
}

test "Response: json() with nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.json(.{
        .user = .{
            .name = "Bob",
            .id = 42,
        },
        .active = true,
    });

    var body_buf: [256]u8 = undefined;
    const buffered = try testBody(&response, &body_buf);
    try std.testing.expectEqualStrings("{\"user\":{\"name\":\"Bob\",\"id\":42},\"active\":true}", buffered);
}

/// An event stream over a fixed buffer. Built in place: the response points
/// at the connection and the stream at the response, so none of it can be
/// moved once it exists. `events` is what a test is actually after -- what
/// went out behind the headers.
const TestEventStream = struct {
    arena: std.heap.ArenaAllocator,
    conn_writer: std.Io.Writer,
    connection: Connection,
    response: Response,
    stream: EventStream,
    header_end: usize,
    decoded: [1024]u8,
    event_buf: [4096]u8 = undefined,

    fn init(self: *TestEventStream, buf: []u8) !void {
        self.arena = .init(std.testing.allocator);
        self.conn_writer = .fixed(buf);
        self.connection.initWriterForTesting(&self.conn_writer);
        self.response = try Response._init(self.arena.allocator(), &self.connection, 32);
        self.stream = try self.response.startEventStream(&self.event_buf);
        self.header_end = self.conn_writer.end;
    }

    fn deinit(self: *TestEventStream) void {
        self.arena.deinit();
    }

    /// What went out behind the headers, still chunk-framed.
    fn raw(self: *TestEventStream) []const u8 {
        return self.conn_writer.buffered()[self.header_end..];
    }

    /// The events with the chunk framing peeled off, so a test about how an
    /// event is formatted does not have to spell out chunk sizes. That the
    /// framing is there at all is asserted on its own, below.
    fn events(self: *TestEventStream) ![]const u8 {
        var rest = self.raw();
        var n: usize = 0;
        while (rest.len > 0) {
            const size_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.TruncatedChunk;
            const size = try std.fmt.parseInt(usize, rest[0..size_end], 16);
            if (size == 0) break;
            const body = rest[size_end + 2 ..];
            if (body.len < size + 2) return error.TruncatedChunk;
            @memcpy(self.decoded[n..][0..size], body[0..size]);
            n += size;
            rest = body[size + 2 ..];
        }
        return self.decoded[0..n];
    }
};

test "EventStream: send with data only" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("hello world", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: hello world\n\n", written);
}

test "EventStream: send with event name" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("payload", .{ .event = "update" });

    const written = try t.events();
    try std.testing.expectEqualStrings("event: update\ndata: payload\n\n", written);
}

test "EventStream: send with all options" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("payload", .{ .event = "update", .id = "42", .retry = 5000 });

    const written = try t.events();
    try std.testing.expectEqualStrings("event: update\nid: 42\nretry: 5000\ndata: payload\n\n", written);
}

test "EventStream: multiple sends" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("first", .{});
    try t.stream.send("second", .{ .event = "msg" });

    const written = try t.events();
    try std.testing.expectEqualStrings("data: first\n\nevent: msg\ndata: second\n\n", written);
}

test "Response: startEventStream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    try stream.send("connected", .{});

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "HTTP/1.1 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Cache-Control: no-cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "data: connected\n\n") != null);
    // The stream has no length to declare, so it is chunked -- which is
    // what lets the peer tell a stream that ended from one that was cut,
    // and lets the connection outlive it.
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expectEqual(true, response.keepalive);
}

test "EventStream: each event is one chunk" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("hi", .{});
    try t.stream.send("there", .{ .event = "msg" });

    // One chunk per event, so a peer sees each one whole and as soon as it
    // is sent rather than when the buffer happens to fill.
    try std.testing.expectEqualStrings(
        "a\r\ndata: hi\n\n\r\n" ++
            "18\r\nevent: msg\ndata: there\n\n\r\n",
        t.raw(),
    );
}

test "EventStream: send reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // What opening the stream puts on the wire. The failing pass below gets
    // exactly that much room, so the first event has nowhere to go.
    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response._init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    try std.testing.expectError(error.ConnectionResetByPeer, stream.send("hello", .{}));
    try std.testing.expectEqual(error.ConnectionResetByPeer, stream.body.err.?);
}

test "EventWriter: end reports the real error, not error.WriteFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response._init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);

    // The event is held in the stream's buffer, so nothing reaches the
    // connection until `end` closes it.
    var w = try stream.startSend(.{});
    try w.interface.writeAll("hello");
    try std.testing.expectError(error.ConnectionResetByPeer, w.end());
}

test "EventWriter: an event too long for the buffer reports the real error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const header_len = blk: {
        var probe: [1024]u8 = undefined;
        var probe_writer: std.Io.Writer = .fixed(&probe);
        var probe_conn: Connection = undefined;
        probe_conn.initWriterForTesting(&probe_writer);
        var probe_res = try Response._init(arena.allocator(), &probe_conn, 32);
        var event_buf: [4096]u8 = undefined;
        _ = try probe_res.startEventStream(&event_buf);
        break :blk probe_writer.end;
    };

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(buf[0..header_len]);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    connection.tcp_writer.err = error.ConnectionResetByPeer;

    var response = try Response._init(arena.allocator(), &connection, 32);
    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);
    var w = try stream.startSend(.{});

    // Longer than the stream holds, so it reaches the connection while it
    // is still being written rather than at `end`. That is what a caller
    // filling an event from a template does, and the interface can only
    // tell them the sentinel.
    const long = try arena.allocator().alloc(u8, event_buf.len + 1);
    @memset(long, 'x');

    try std.testing.expectError(error.WriteFailed, w.interface.writeAll(long));
    try std.testing.expectEqual(error.ConnectionResetByPeer, w.err.?);
    // The stream underneath resolved it, and both copies agree.
    try std.testing.expectEqual(error.ConnectionResetByPeer, stream.body.err.?);
}

test "Response: setCookie basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.setCookie("session", "abc123", .{});
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: session=abc123\r\n") != null);
}

test "Response: setCookie with options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.setCookie("auth", "token123", .{
        .path = "/",
        .http_only = true,
        .secure = true,
        .same_site = .strict,
    });
    response.body = "OK";

    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Set-Cookie: auth=token123; Path=/; HttpOnly; Secure; SameSite=Strict\r\n") != null);
}

test "Response: header() rejects CRLF in value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderValue, response.header("Location", "/ok\r\nX-Evil: 1"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\nbaz"));
    try std.testing.expectError(error.InvalidHeaderValue, response.header("X-Foo", "bar\x00baz"));
}

test "Response: header() rejects invalid name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.InvalidHeaderName, response.header("", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X-Bad\r\n", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X: Bad", "value"));
    try std.testing.expectError(error.InvalidHeaderName, response.header("X Bad", "value"));
}

test "Response: setCookie rejects a value that would inject a header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    // Caught as a bad cookie value now, which is the earlier and narrower
    // of the two checks -- CRLF is not a cookie-octet in the first place.
    try std.testing.expectError(error.InvalidCookieValue, response.setCookie("session", "abc\r\nSet-Cookie: evil=1", .{}));
    try std.testing.expectError(error.InvalidCookieName, response.setCookie("a;Path=/", "v", .{}));
}

test "EventStream: rejects newline in event and id fields" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try std.testing.expectError(error.InvalidEventField, t.stream.send("ok", .{ .event = "bad\nevent" }));
    try std.testing.expectError(error.InvalidEventField, t.stream.send("ok", .{ .id = "bad\rid" }));
}

test "EventStream: multi-line data splits into multiple data lines" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("line1\nline2", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventStream: CRLF line endings stripped in data" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("line1\r\nline2", .{});

    const written = try t.events();
    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", written);
}

test "EventWriter: basic write" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("hello");
    try ew.end();

    try std.testing.expectEqualStrings("data: hello\n\n", try t.events());
}

test "EventWriter: multi-line" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("line1\nline2");
    try ew.end();

    try std.testing.expectEqualStrings("data: line1\ndata: line2\n\n", try t.events());
}

test "EventWriter: print" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.print("count: {d}", .{42});
    try ew.end();

    try std.testing.expectEqualStrings("data: count: 42\n\n", try t.events());
}

test "EventWriter: with options" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{ .event = "update", .id = "42" });
    try ew.interface.writeAll("payload");
    try ew.end();

    try std.testing.expectEqualStrings("event: update\nid: 42\ndata: payload\n\n", try t.events());
}

test "EventWriter: multiple writes merged into one event" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("foo");
    try ew.interface.writeAll("bar");
    try ew.end();

    try std.testing.expectEqualStrings("data: foobar\n\n", try t.events());
}

test "EventWriter: writeByte" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeByte('A');
    try ew.interface.writeByte('B');
    try ew.interface.writeByte('C');
    try ew.end();

    try std.testing.expectEqualStrings("data: ABC\n\n", try t.events());
}

test "EventWriter: splatBytesAll" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.splatBytesAll("ab", 3);
    try ew.end();

    try std.testing.expectEqualStrings("data: ababab\n\n", try t.events());
}

test "EventStream: a bare CR in data is a line break, never the start of a field" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    try t.stream.send("hi\revent: admin\rid: 9\r\rdata: x\r\ny\nz", .{});

    try std.testing.expectEqualStrings(
        "data: hi\ndata: event: admin\ndata: id: 9\ndata: \ndata: data: x\ndata: y\ndata: z\n\n",
        try t.events(),
    );
}

test "EventWriter: a bare CR is a line break, and a CRLF split across writes is one" {
    var buf: [1024]u8 = undefined;
    var t: TestEventStream = undefined;
    try t.init(&buf);
    defer t.deinit();

    var ew = try t.stream.startSend(.{});
    try ew.interface.writeAll("a\revent: x\r");
    try ew.interface.writeAll("\nb\r");
    try ew.interface.writeAll("c\r");
    try ew.end();

    try std.testing.expectEqualStrings("data: a\ndata: event: x\ndata: b\ndata: c\n\n", try t.events());
}

test "fuzz: SSE data never adds a line that is not data" {
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var buf: [8192]u8 = undefined;
            var t: TestEventStream = undefined;
            try t.init(&buf);
            defer t.deinit();
            // What one event can expand to fits the test stream's buffers.
            const data = input[0..@min(input.len, 64)];
            const half = data.len / 2;
            var ew = try t.stream.startSend(.{});
            try ew.interface.writeAll(data[0..half]);
            try ew.interface.writeAll(data[half..]);
            try ew.end();
            try t.stream.send(data, .{});
            try expectOnlyData(try t.events());
        }

        /// Every line the WHATWG parser would see (CR, LF and CRLF end
        /// one) is a `data:` line or the blank line ending an event.
        fn expectOnlyData(out: []const u8) !void {
            var i: usize = 0;
            var start: usize = 0;
            while (i < out.len) : (i += 1) {
                if (out[i] != '\r' and out[i] != '\n') continue;
                const line = out[start..i];
                if (line.len > 0 and !std.mem.startsWith(u8, line, "data: ")) return error.InjectedField;
                if (out[i] == '\r' and i + 1 < out.len and out[i + 1] == '\n') i += 1;
                start = i + 1;
            }
        }
    }.check, &.{ "", "a\rb", "a\r\nb\n", "\r\r\r", "x\revent: y\rid: 1\r\rdata: z" });
}

test "Response: resetBody replaces a half written body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.content_type = .json;
    var body = try response.writer();
    try body.interface.writeAll("{\"half\":");
    // The handler fails here, without ever calling `end`.

    try response.resetBody();
    response.status = .internal_server_error;
    response.content_type = .text;
    response.body = "500 Internal Server Error\n";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "500") != null);
    // The fragment must not survive as the body, nor its length as the
    // Content-Length, nor its content type as the type.
    try std.testing.expect(std.mem.indexOf(u8, written, "half") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 26") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "500 Internal Server Error\n"));
}

test "Response: resetBody drops the headers that described the old body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    // Set directly rather than through `content_type`, which is the case
    // clearing that field alone does not cover.
    try response.header("Content-Type", "application/json");
    try response.header("Content-Length", "8");
    try response.header("X-Request-Id", "abc");
    var body = try response.writer();
    try body.interface.writeAll("{\"half\":");

    try response.resetBody();
    response.status = .internal_server_error;
    response.body = "oops\n";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "application/json") == null);
    // The stale length is the dangerous one: the headers go out with a
    // length that is already set left alone, so the peer would read 8 bytes of a 5
    // byte body and take the rest from the next response.
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 8") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    // Headers that say nothing about the body are left alone.
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Request-Id: abc") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "oops\n"));
}

test "Response: a stream to an HTTP/1.0 peer is delimited by closing, not chunked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.http10 = true;
    var stream_buf: [64]u8 = undefined;
    var body = try response.stream(&stream_buf);
    try body.interface.writeAll("hello ");
    try body.interface.writeAll("world");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\nhello world"));
    try std.testing.expect(!response.keepalive);
}

test "Response: a HEAD streamed to an HTTP/1.0 peer keeps the connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.http10 = true;
    response.head = true;
    var stream_buf: [64]u8 = undefined;
    var body = try response.stream(&stream_buf);
    try body.interface.writeAll("hello");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: close") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    try std.testing.expect(response.keepalive);
}

test "Response: a kept HTTP/1.0 connection is announced with Connection: keep-alive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.http10 = true;
    response.body = "hello";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5\r\n") != null);
    try std.testing.expect(response.keepalive);
}

test "Response: an HTTP/1.1 response that keeps the connection sends no Connection header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "hello";
    try response.write();

    try std.testing.expect(std.mem.indexOf(u8, conn_writer.buffered(), "Connection:") == null);
}

test "BodyWriter: a body over many segments goes out whole, with its length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [32 * 1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var expected: [10_000]u8 = undefined;
    for (&expected, 0..) |*b, i| b.* = @intCast('a' + i % 26);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    // Short writes, as an encoder makes, crossing every segment boundary.
    var i: usize = 0;
    while (i < expected.len) : (i += 7) {
        try body.interface.writeAll(expected[i..@min(i + 7, expected.len)]);
    }
    try body.end();
    try std.testing.expect(response.body_buffer.segments.len() > 1);
    try std.testing.expectEqual(expected.len, response.body_buffer.len());
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 10000\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n" ++ expected));
}

test "BodyWriter: a body of more segments than one vectored write takes goes out in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const total = 600 * 1000;
    const out_buf = try arena.allocator().alloc(u8, total + 1024);
    var conn_writer: std.Io.Writer = .fixed(out_buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    var chunk: [1000]u8 = undefined;
    for (0..total / chunk.len) |i| {
        @memset(&chunk, @intCast('a' + i % 26));
        try body.interface.writeAll(&chunk);
    }
    try body.end();
    try std.testing.expect(response.body_buffer.segments.len() > 8);
    try response.write();

    const written = conn_writer.buffered();
    const start = std.mem.indexOf(u8, written, "\r\n\r\n").? + 4;
    try std.testing.expect(std.mem.indexOf(u8, written[0..start], "Content-Length: 600000\r\n") != null);
    const sent = written[start..];
    try std.testing.expectEqual(total, sent.len);
    for (0..total / chunk.len) |i| {
        try std.testing.expect(std.mem.allEqual(u8, sent[i * chunk.len ..][0..chunk.len], @intCast('a' + i % 26)));
    }
}

test "BodyWriter: a write bigger than any segment, and a long splat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [256 * 1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    const big: [100 * 1024]u8 = @splat('x');
    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    try body.interface.writeAll("<");
    try body.interface.writeAll(&big);
    try body.interface.splatByteAll('y', 70 * 1024);
    try body.interface.writeAll(">");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    const start = std.mem.indexOf(u8, written, "\r\n\r\n").? + 4;
    try std.testing.expect(std.mem.indexOf(u8, written[0..start], "Content-Length: 174082\r\n") != null);
    const sent = written[start..];
    try std.testing.expectEqual(174082, sent.len);
    try std.testing.expectEqualStrings("<", sent[0..1]);
    try std.testing.expect(std.mem.allEqual(u8, sent[1..][0..big.len], 'x'));
    try std.testing.expect(std.mem.allEqual(u8, sent[1 + big.len ..][0 .. 70 * 1024], 'y'));
    try std.testing.expectEqualStrings(">", sent[sent.len - 1 ..]);
}

test "BodyWriter: rebase keeps the bytes it was asked to preserve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [8 * 1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    const head: [500]u8 = @splat('h');
    try body.interface.writeAll(&head);
    // Asks for more room than the first segment has left, keeping the last
    // four bytes contiguous with it.
    const slice = try body.interface.writableSliceGreedyPreserve(4, 1000);
    try std.testing.expect(slice.len >= 1000);
    try std.testing.expectEqualStrings("hhhh", body.interface.buffer[body.interface.end - 4 .. body.interface.end]);
    @memset(slice[0..1000], 't');
    body.interface.advance(1000);
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    const start = std.mem.indexOf(u8, written, "\r\n\r\n").? + 4;
    const sent = written[start..];
    try std.testing.expectEqual(1500, sent.len);
    try std.testing.expect(std.mem.allEqual(u8, sent[0..500], 'h'));
    try std.testing.expect(std.mem.allEqual(u8, sent[500..], 't'));
}

test "BodyWriter: a file streamed into the body arrives whole" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var content: [3000]u8 = undefined;
    for (&content, 0..) |*b, i| b.* = @intCast('0' + i % 10);
    try tmp.dir.writeFile(io, .{ .sub_path = "body.txt", .data = &content });

    var buf: [8 * 1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    const file = try tmp.dir.openFile(io, "body.txt", .{});
    defer file.close(io);
    var read_buf: [256]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    // Asserts a buffered writer, which a fresh body writer must be.
    _ = try body.interface.sendFileAll(&file_reader, .unlimited);
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 3000\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n" ++ content));
}

test "BodyWriter: rebase asked to preserve more than is buffered keeps it all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [4 * 1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    try body.interface.writeAll("abc");
    const slice = try body.interface.writableSliceGreedyPreserve(100, 1000);
    try std.testing.expect(slice.len >= 1000);
    try std.testing.expectEqualStrings("abc", body.interface.buffered());
    @memcpy(slice[0..3], "def");
    body.interface.advance(3);
    try body.end();
    try response.write();

    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "Content-Length: 6\r\n\r\nabcdef"));
}

test "Response: json is refused while a body writer is open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    try body.interface.writeAll("[");
    try std.testing.expectError(error.BodyWriterOpen, response.json(.{ .a = 1 }));
    try body.interface.writeAll("]");
    try body.end();
    try response.write();

    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "Content-Length: 2\r\n\r\n[]"));
}

test "BodyWriter: resetBody after several segments leaves only the replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    var body = try response.writer();
    try body.interface.splatByteAll('y', 300);
    try body.interface.splatByteAll('z', 5000);
    try body.interface.flush();
    try std.testing.expect(response.body_buffer.segments.len() > 1);
    try std.testing.expectEqual(5300, response.body_buffer.len());
    try response.resetBody();
    var again = try response.writer();
    try again.interface.writeAll("fresh");
    try again.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\nfresh"));
}

test "Response: a handler's own Content-Length must match the buffered body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "10");
    response.body = "hello";
    try std.testing.expectError(error.ContentLengthMismatch, response.write());
    try std.testing.expect(!response.keepalive);
    try std.testing.expectEqual(0, conn_writer.buffered().len);
}

test "Response: a handler's Content-Length that is not a number is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.header("Content-Length", "five");
    response.body = "hello";
    try std.testing.expectError(error.InvalidContentLength, response.write());
    try std.testing.expectEqual(0, conn_writer.buffered().len);
}

test "Response: a 204 carries no Content-Length and no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.status = .no_content;
    // A handler's mistake, which must not reach the wire.
    response.body = "hello";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 204 "));
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "Response: a 204 streamed is neither chunked nor terminated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.status = .no_content;
    var stream_buf: [64]u8 = undefined;
    var body = try response.stream(&stream_buf);
    try body.interface.writeAll("hello");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    // The head, and nothing after it: no chunk and no terminator.
    try std.testing.expectEqual(written.len, std.mem.indexOf(u8, written, "\r\n\r\n").? + 4);
}

test "Response: a 304 sends no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.status = .not_modified;
    response.body = "hello";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "Response: a HEAD reports the length but sends no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.head = true;
    response.content_type = .text;
    response.body = "hello";
    try response.write();

    const written = conn_writer.buffered();
    // The headers are the ones a GET would have got.
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "text/plain") != null);
    // The body is not.
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
}

test "Response: a HEAD sends no body written through the writer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.head = true;
    var body = try response.writer();
    try body.interface.writeAll("hello");
    try body.end();
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "Response: a streamed HEAD sends the framing headers and nothing after" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.head = true;

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try body.interface.writeAll("first");
    try body.interface.flush();
    try body.interface.writeAll("second");
    try body.end();

    // Chunked is what a GET would have been, so it is still announced --
    // but no chunk and no terminator follow it.
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "Response: a streamed HEAD still checks a declared length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.head = true;
    try response.header("Content-Length", "5");

    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    // The handler wrote what a GET would have, and is held to the length
    // it promised even though none of it went out.
    try body.interface.writeAll("hello");
    try body.end();

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n",
        conn_writer.buffered(),
    );
}

test "Response: a HEAD event stream sends the headers and no events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    response.head = true;

    var event_buf: [4096]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);
    try stream.send("hello", .{});
    var w = try stream.startSend(.{ .event = "tick" });
    try w.interface.writeAll("more");
    try w.end();

    // The headers a GET would have opened the stream with, and nothing
    // after them.
    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "text/event-stream") != null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tick") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "data:") == null);
}

fn testGzipRequest(arena: std.mem.Allocator) !Request {
    var request: Request = .{ .arena = arena, ._parser = undefined, ._transport = undefined };
    request.headers = try http.Headers.init(arena, 4);
    try request.headers.put("Accept-Encoding", "gzip");
    return request;
}

test "Response: a stream refused at the headers leaves nothing for the error response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var request = try testGzipRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 2);
    response._request = &request;
    response.compress = true;
    response.content_type = .text;
    try response.header("X-A", "1");
    try response.header("X-B", "2");

    var stream_buf: [64]u8 = undefined;
    try std.testing.expectError(error.TooManyHeaders, response.stream(&stream_buf));

    // What `handleError` does with headers that are still open.
    try response.resetBody();
    response.status = .internal_server_error;
    response.body = "oops";
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 500"));
    try std.testing.expect(std.mem.indexOf(u8, written, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Encoding") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\noops"));
}

test "Response: compress without room for its headers sends the body as it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var request = try testGzipRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 1);
    response._request = &request;
    response.compress = true;
    response.body = &@as([300]u8, @splat('a'));
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Vary") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n" ++ &@as([300]u8, @splat('a'))));
}

test "Response: a gzipped body weakens its ETag and drops Accept-Ranges" {
    if (!build_options.use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var request = try testGzipRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 8);
    response._request = &request;
    response.compress = true;
    try response.header("ETag", "\"v1\"");
    try response.header("Accept-Ranges", "bytes");
    response.body = &@as([300]u8, @splat('a'));
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Encoding: gzip\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ETag: W/\"v1\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Accept-Ranges") == null);
}

test "Response: a 304 gets the Vary and ETag of a gzipped 200, without its coding" {
    if (!build_options.use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var request = try testGzipRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 8);
    response._request = &request;
    response.compress = true;
    response.status = .not_modified;
    try response.header("ETag", "\"v1\"");
    try response.write();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Vary: Accept-Encoding\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ETag: W/\"v1\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Encoding") == null);
}

test "Response: variesByAcceptEncoding matches whole names, and *" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection: Connection = undefined;

    const cases = [_]struct { []const u8, bool }{
        .{ "Origin, accept-encoding", true },
        .{ "*", true },
        .{ "X-Accept-Encoding-Hint", false },
    };
    for (cases) |case| {
        var response = try Response._init(arena.allocator(), &connection, 2);
        try response.header("Vary", case[0]);
        try std.testing.expectEqual(case[1], response.variesByAcceptEncoding());
    }
}

test "Response: a stream without the memory for a compressor goes out as it is" {
    if (!build_options.use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var request = try testGzipRequest(arena.allocator());
    var response = try Response._init(failing.allocator(), &connection, 8);
    response._request = &request;
    response.compress = true;
    failing.fail_index = failing.alloc_index;

    var stream_buf: [64]u8 = undefined;
    var w = try response.stream(&stream_buf);
    try w.interface.writeAll("hello");
    try w.end();

    const written = conn_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Vary: Accept-Encoding\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Encoding") == null);
    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n5\r\nhello\r\n0\r\n\r\n"));
}

test "Response: Accept-Encoding picks zstd, br or gzip by q-value, then in that order" {
    if (!(build_options.use_zlib and build_options.use_zstd and build_options.use_brotli)) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection: Connection = undefined;
    const cases = [_]struct { []const u8, Response.Compression }{
        // HttpArena's json-comp and Safari: br over gzip on a tie.
        .{ "gzip, br", .br },
        .{ "br", .br },
        // Chrome and Firefox: zstd first on a tie.
        .{ "gzip, deflate, br, zstd", .zstd },
        .{ "br;q=1.0, zstd;q=0.9, gzip", .br },
        .{ "br;q=0.5, gzip", .gzip },
        .{ "gzip;q=0.2, br;q=0.8, zstd;q=0.5", .br },
        .{ "*", .zstd },
        .{ "*;q=0.1, br", .br },
        .{ "*, zstd;q=0, gzip;q=0.5", .br },
        .{ "br;q=0, gzip", .gzip },
        .{ "br;q=0", .identity },
        .{ "identity", .identity },
        .{ "deflate", .identity },
        .{ "", .identity },
    };
    for (cases) |case| {
        var request: Request = .{ .arena = arena.allocator(), ._parser = undefined, ._transport = undefined };
        request.headers = try http.Headers.init(arena.allocator(), 4);
        try request.headers.put("Accept-Encoding", case[0]);
        var response = try Response._init(arena.allocator(), &connection, 8);
        response._request = &request;
        response.compress = true;
        std.testing.expectEqual(case[1], response.negotiateCompression()) catch |err| {
            std.debug.print("Accept-Encoding: {s}\n", .{case[0]});
            return err;
        };
    }
}

fn testBrRequest(arena: std.mem.Allocator) !Request {
    var request: Request = .{ .arena = arena, ._parser = undefined, ._transport = undefined };
    request.headers = try http.Headers.init(arena, 4);
    try request.headers.put("Accept-Encoding", "gzip, br");
    return request;
}

fn testBrotliDecode(arena: std.mem.Allocator, encoded: []const u8, max: usize) ![]u8 {
    const c = @import("brotli");
    const out = try arena.alloc(u8, max);
    var len: usize = max;
    if (c.BrotliDecoderDecompress(encoded.len, encoded.ptr, &len, out.ptr) != c.BROTLI_DECODER_RESULT_SUCCESS) return error.InvalidBrotli;
    return out[0..len];
}

test "Response: a buffered body goes out as br, at the configured quality" {
    if (!build_options.use_brotli) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var text: std.Io.Writer.Allocating = .init(arena.allocator());
    for (0..100) |i| try text.writer.print("{{\"id\":{d},\"name\":\"Widget {d}\",\"price\":{d}}},", .{ i, i % 9, i * 37 % 500 });
    const body = text.written();

    var sizes: [2]usize = undefined;
    for ([_]u4{ 1, 9 }, &sizes) |quality, *size| {
        var buf: [8192]u8 = undefined;
        var conn_writer: std.Io.Writer = .fixed(&buf);
        var connection: Connection = undefined;
        connection.initWriterForTesting(&conn_writer);
        var request = try testBrRequest(arena.allocator());
        var response = try Response._init(arena.allocator(), &connection, 8);
        defer response.deinit();
        response._request = &request;
        response.compress = true;
        response._brotli_quality = quality;
        response.content_type = .json;
        response.body = body;
        try response.write();

        const written = conn_writer.buffered();
        const split = std.mem.indexOf(u8, written, "\r\n\r\n").?;
        const head = written[0 .. split + 2];
        try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: br\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, head, "Vary: Accept-Encoding\r\n") != null);
        const encoded = written[split + 4 ..];
        try std.testing.expect(std.mem.indexOf(u8, head, try std.fmt.allocPrint(arena.allocator(), "Content-Length: {d}\r\n", .{encoded.len})) != null);
        try std.testing.expectEqualStrings(body, try testBrotliDecode(arena.allocator(), encoded, body.len));
        size.* = encoded.len;
    }
    try std.testing.expect(sizes[1] < sizes[0]);
}

test "Response: a streamed body goes out as br, each flush decodable" {
    if (!build_options.use_brotli) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [16384]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var request = try testBrRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 8);
    defer response.deinit();
    response._request = &request;
    response.compress = true;
    response.content_type = .text;

    var stream_buf: [128]u8 = undefined;
    var w = try response.stream(&stream_buf);
    var plain: std.Io.Writer.Allocating = .init(arena.allocator());
    for (0..50) |i| {
        try w.interface.print("event {d}: something happened, and then something else happened\n", .{i});
        try plain.writer.print("event {d}: something happened, and then something else happened\n", .{i});
        if (i % 10 == 9) try w.interface.flush();
    }
    try w.end();

    const written = conn_writer.buffered();
    const split = std.mem.indexOf(u8, written, "\r\n\r\n").?;
    const head = written[0 .. split + 2];
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: br\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Transfer-Encoding: chunked\r\n") != null);
    // Undo the chunking: several chunks, one per flush and the end.
    var encoded: std.Io.Writer.Allocating = .init(arena.allocator());
    var rest = written[split + 4 ..];
    var chunks: usize = 0;
    while (true) {
        const eol = std.mem.indexOf(u8, rest, "\r\n").?;
        const size = try std.fmt.parseInt(usize, rest[0..eol], 16);
        if (size == 0) break;
        try encoded.writer.writeAll(rest[eol + 2 ..][0..size]);
        rest = rest[eol + 2 + size + 2 ..];
        chunks += 1;
    }
    try std.testing.expect(chunks >= 5);
    try std.testing.expectEqualStrings(plain.written(), try testBrotliDecode(arena.allocator(), encoded.written(), plain.written().len));
    // The encoder's memory went back when the body ended.
    try std.testing.expect(response.brotli_encoder == null);
}

test "Response.deinit frees the Brotli encoder of a stream never ended" {
    if (!build_options.use_brotli) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var request = try testBrRequest(arena.allocator());
    var response = try Response._init(arena.allocator(), &connection, 8);
    response._request = &request;
    response.compress = true;
    var stream_buf: [64]u8 = undefined;
    var w = try response.stream(&stream_buf);
    try w.interface.writeAll("abandoned half way");
    try std.testing.expect(response.brotli_encoder != null);
    // As the HTTP/1.1 loop does: the arena (where the compressor is) goes
    // before the response.
    _ = arena.reset(.free_all);
    response.deinit();
    try std.testing.expect(response.brotli_encoder == null);
}

const test_templates = struct {
    fn greeting(name: []const u8, count: u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("<p>{s} x{d}</p>", .{ name, count });
    }

    const Page = struct {
        const Args = struct { []const u8 };

        fn render(args: Args, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("<h1>{s}</h1>", .{args[0]});
        }
    };

    fn failing(w: *std.Io.Writer) (std.Io.Writer.Error || error{Broken})!void {
        try w.writeAll("partial");
        return error.Broken;
    }
};

test "Response: render calls a function or a template type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.render(.html, test_templates.greeting, .{ "hi", 3 });
    var body_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("<p>hi x3</p>", try testBody(&response, &body_buf));
    try std.testing.expectEqual(.html, response.content_type);

    var page = try Response._init(arena.allocator(), &connection, 32);
    page.content_type = .xml;
    try page.render(null, test_templates.Page, .{"Title"});
    try std.testing.expectEqualStrings("<h1>Title</h1>", try testBody(&page, &body_buf));
    try std.testing.expectEqual(.xml, page.content_type);
}

const test_encoders = struct {
    /// The value first, as json.zig's `json.encode`.
    fn valueFirst(value: anytype, w: *std.Io.Writer) !void {
        try w.print("[{d}]", .{value});
    }

    /// An allocator and the writer first, as serde.zig's `msgpack.toWriter`.
    fn writerFirst(allocator: std.mem.Allocator, w: *std.Io.Writer, value: anytype) !void {
        try w.writeAll(try std.fmt.allocPrint(allocator, "<{d}>", .{value}));
    }
};

test "Response: encode finds the writer, the allocator and the value by type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var body_buf: [256]u8 = undefined;

    var first = try Response._init(arena.allocator(), &connection, 32);
    try first.encode(.json, test_encoders.valueFirst, 42);
    try std.testing.expectEqualStrings("[42]", try testBody(&first, &body_buf));
    try std.testing.expectEqual(.json, first.content_type);

    var second = try Response._init(arena.allocator(), &connection, 32);
    try second.encode(.msgpack, test_encoders.writerFirst, @as(u32, 7));
    try std.testing.expectEqualStrings("<7>", try testBody(&second, &body_buf));
    try std.testing.expectEqual(.msgpack, second.content_type);
}

test "Response: a failed render can be replaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try std.testing.expectError(error.Broken, response.render(.html, test_templates.failing, .{}));
    try response.render(.html, test_templates.Page, .{"Fallback"});
    var body_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("<h1>Fallback</h1>", try testBody(&response, &body_buf));
}

test "Response: print formats the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);

    var response = try Response._init(arena.allocator(), &connection, 32);
    try response.print(.text, "{s} x{d}", .{ "hi", 3 });
    try response.write();

    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "Content-Type: text/plain; charset=UTF-8\r\nContent-Length: 5\r\n\r\nhi x3"));
}

/// A sink that records what a response hands it, for the tests below.
const TestSink = struct {
    status: ?http.Status = null,
    content_length: ?usize = null,
    content_type: []const u8 = "",
    interim: ?http.Status = null,
    heads: usize = 0,
    ends: usize = 0,
    trailer_grpc_status: []const u8 = "",
    body_buf: [4096]u8 = undefined,
    body_writer: std.Io.Writer = undefined,

    fn init(self: *TestSink) void {
        self.* = .{};
        self.body_writer = .fixed(&self.body_buf);
    }

    fn sink(self: *TestSink) Sink {
        return .{ .ptr = self, .vtable = &.{
            .head = head,
            .interim = interimFn,
            .body = bodyFn,
            .end = end,
            .writeError = writeError,
            .peerGone = peerGone,
        } };
    }

    fn body(self: *TestSink) []const u8 {
        return self.body_writer.buffered();
    }

    fn head(ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        self.heads += 1;
        self.status = status;
        self.content_length = content_length;
        self.content_type = headers.get("Content-Type") orelse "";
    }
    fn interimFn(ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        self.interim = status;
    }
    fn bodyFn(ptr: *anyopaque) *std.Io.Writer {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        return &self.body_writer;
    }
    fn end(ptr: *anyopaque, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
        const self: *TestSink = @ptrCast(@alignCast(ptr));
        self.ends += 1;
        if (trailers) |t| self.trailer_grpc_status = t.get("grpc-status") orelse "";
    }
    fn writeError(_: *anyopaque) ?Response.SendError {
        return null;
    }
    fn peerGone(_: *anyopaque) bool {
        return false;
    }
};

test "Response sink: a buffered body goes to the sink with its length, and no HTTP/1 framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    try response.print(.text, "hello {s}", .{"sink"});
    try response.write();

    try std.testing.expectEqual(http.Status.ok, ts.status.?);
    try std.testing.expectEqual(@as(?usize, 10), ts.content_length);
    try std.testing.expectEqualStrings("hello sink", ts.body());
    try std.testing.expect(std.mem.startsWith(u8, ts.content_type, "text/plain"));
    try std.testing.expectEqual(@as(usize, 1), ts.heads);
    try std.testing.expectEqual(@as(usize, 1), ts.ends);
}

test "Response sink: a streamed body is unframed, of unknown length, and ends once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    var buf: [8]u8 = undefined;
    var body = try response.stream(&buf);
    try std.testing.expectEqual(@as(usize, 1), ts.heads);
    try std.testing.expectEqual(@as(?usize, null), ts.content_length);
    try body.interface.writeAll("hello ");
    try body.interface.writeAll("streamed world");
    try body.end();
    try response.write(); // the server's call after the handler: nothing more

    try std.testing.expectEqualStrings("hello streamed world", ts.body());
    try std.testing.expect(!response._chunked);
    try std.testing.expectEqual(@as(usize, 1), ts.ends);
}

test "Response sink: trailers reach the end of the message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    response.body = "payload";
    try response.trailer("grpc-status", "0");
    try response.write();

    try std.testing.expectEqualStrings("payload", ts.body());
    try std.testing.expectEqualStrings("0", ts.trailer_grpc_status);
}

test "Response sink: a HEAD reports the length and sends no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    response.head = true;
    response.body = "not sent";
    try response.write();

    try std.testing.expectEqual(@as(?usize, 8), ts.content_length);
    try std.testing.expectEqualStrings("", ts.body());
    try std.testing.expectEqual(@as(usize, 1), ts.ends);
}

test "Response sink: 204 announces no length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    response.status = .no_content;
    try response.write();

    try std.testing.expectEqual(http.Status.no_content, ts.status.?);
    try std.testing.expectEqual(@as(?usize, null), ts.content_length);
    try std.testing.expectEqual(@as(usize, 1), ts.ends);
}

test "Response sink: no WebSocket upgrade over a sink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts: TestSink = undefined;
    ts.init();

    var response = try Response._initSink(arena.allocator(), std.testing.io, ts.sink(), 32);
    var request: Request = .{ .arena = arena.allocator(), ._parser = undefined, ._transport = undefined, .headers = try http.Headers.init(arena.allocator(), 8) };
    try request.headers.put("Upgrade", "websocket");
    try request.headers.put("Connection", "Upgrade");
    try request.headers.put("Sec-WebSocket-Version", "13");
    try request.headers.put("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expect((try response._upgradeWebSocket(&request)) == null);
    try std.testing.expectEqual(@as(usize, 0), ts.heads);
}

test "sendFile: a path that would leave the directory is refused as text" {
    for ([_][]const u8{ "a.txt", "./a.txt", "dir/a.txt", "a..b", "..a", "a/...", "" }) |path| {
        try std.testing.expect(Response.staysInside(path));
    }
    for ([_][]const u8{ "..", "../a", "a/../b", "a/..", "./../a", "/etc/passwd", "//x", "a\x00b" }) |path| {
        try std.testing.expect(!Response.staysInside(path));
    }
    if (builtin.os.tag == .windows) {
        for ([_][]const u8{ "..\\a", "a\\..\\b", "\\\\server\\share", "C:\\x", "C:x", "a:stream" }) |path| {
            try std.testing.expect(!Response.staysInside(path));
        }
    }
}

test "EventStream: comment, end and draining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var request: Request = .{ .arena = arena.allocator(), ._parser = undefined, ._transport = undefined };
    var drain: std.Io.Event = .unset;
    request.drain = &drain;
    var response = try Response._init(arena.allocator(), &connection, 8);
    response._request = &request;
    var event_buf: [256]u8 = undefined;
    var stream = try response.startEventStream(&event_buf);
    try std.testing.expect(!stream.draining());
    try stream.comment("keep-alive");
    try stream.send("x", .{});
    drain.set(std.testing.io);
    try std.testing.expect(stream.draining());
    try stream.end();
    try std.testing.expect(std.mem.endsWith(u8, conn_writer.buffered(), "e\r\n: keep-alive\n\n\r\n9\r\ndata: x\n\n\r\n0\r\n\r\n"));
    try std.testing.expectError(error.InvalidEventField, stream.comment("a\nb"));
}

test "misuse: stream after res.body is BodyAlreadySet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 8);
    response.body = "already";
    var body_buf: [64]u8 = undefined;
    try std.testing.expectError(error.BodyAlreadySet, response.stream(&body_buf));
    try std.testing.expectError(error.BodyAlreadySet, response.writer());
    // Nothing went out, and the response is as it was.
    try std.testing.expect(!response.headersSent());
}

test "misuse: writer after the head is HeadersAlreadySent, resetBody too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 8);
    var body_buf: [64]u8 = undefined;
    var body = try response.stream(&body_buf);
    try std.testing.expectError(error.BodyWriterOpen, response.writer());
    try body.end();
    try std.testing.expectError(error.HeadersAlreadySent, response.writer());
    try std.testing.expectError(error.HeadersAlreadySent, response.resetBody());
}

fn expectProblemBody(p: http.Problem, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "stale";
    response.problem(p);
    try std.testing.expectEqual(http.ContentType.problem_json, response.content_type.?);
    try std.testing.expectEqualStrings(expected, response.body);
}

test "problem: member order, content type, field left out for the root, detail for 1 / N / truncated" {
    try expectProblemBody(.{ .errors = &.{.{ .in = .body, .code = "validation.not_blank", .message = "must not be blank" }} },
        \\{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"1 field is invalid.","errors":[{"in":"body","code":"validation.not_blank","message":"must not be blank"}]}
    );
    try expectProblemBody(.{ .errors = &.{
        .{ .in = .query, .field = "page", .code = "http.invalid_type", .message = "must be an integer" },
        .{ .in = .header, .field = "X-Id", .code = "http.missing_field", .message = "is required" },
    } },
        \\{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"2 fields are invalid.","errors":[{"in":"query","field":"page","code":"http.invalid_type","message":"must be an integer"},{"in":"header","field":"X-Id","code":"http.missing_field","message":"is required"}]}
    );
    try expectProblemBody(.{ .status = .conflict, .detail = "exists", .instance = "/todos/1" },
        \\{"type":"about:blank","title":"Conflict","status":409,"detail":"exists","instance":"/todos/1"}
    );
    try expectProblemBody(.{ .truncated = true, .errors = &.{.{ .code = "a.b", .message = "m" }} },
        \\{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"More than 1 fields are invalid; the first 1 are listed.","errors":[{"in":"body","code":"a.b","message":"m"}]}
    );
}

test "problem: does nothing once headers are out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 32);
    response.body = "kept";
    response._headers_written = true;
    response.problem(.{});
    try std.testing.expectEqualStrings("kept", response.body);
}

test "json: renamed fields by outside names, nested and in slices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 32);
    const validate = @import("validate");
    const Line = struct {
        display_name: []const u8,
        pub const field_rules = .{ .display_name = validate.rename("displayName") };
    };
    try response.json(.{ .lines = [_]Line{.{ .display_name = "a" }}, .n = 1 });
    var all: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer all.deinit();
    try response.write();
    try std.testing.expect(std.mem.indexOf(u8, conn_writer.buffered(), "{\"lines\":[{\"displayName\":\"a\"}],\"n\":1}") != null);
}

test "json: a type without renames writes exactly what std.json writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var connection: Connection = undefined;
    connection.initWriterForTesting(&conn_writer);
    var response = try Response._init(arena.allocator(), &connection, 32);
    const Plain = struct { id: u32, name: []const u8, opt: ?u8 = null };
    const value: Plain = .{ .id = 1, .name = "x" };
    try response.json(value);
    try response.write();
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try expected.writer.print("{f}", .{std.json.fmt(value, .{})});
    try std.testing.expect(std.mem.indexOf(u8, conn_writer.buffered(), expected.written()) != null);
}
