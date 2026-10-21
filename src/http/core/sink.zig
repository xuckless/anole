// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Where a `Response` goes when it does not go out as HTTP/1.x bytes on the
//! connection: an HTTP/2 stream, say. The protocol engine that owns the
//! stream implements this, and the response hands it the status and headers,
//! the body bytes and the end of the message instead of formatting them
//! itself. Everything above -- headers, body writers, compression, files,
//! middleware -- works the same either way.
const std = @import("std");
const http = @import("http.zig");
const Response = @import("response.zig").Response;

pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The response head, once. `content_length` is the body length
        /// when it is known up front (always for a buffered body or a file,
        /// and for a stream with a declared `Content-Length`); null for a
        /// body streamed to its end. The headers are the response's own,
        /// still in HTTP/1 case; dropping connection-specific ones and
        /// lowercasing names is the engine's job.
        head: *const fn (ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void,
        /// An informational response ahead of the head: `100 Continue`.
        interim: *const fn (ptr: *anyopaque, status: http.Status) std.Io.Writer.Error!void,
        /// The writer body bytes go to, unframed. Valid from `head` until
        /// `end`; its `flush` should push what is buffered towards the peer.
        body: *const fn (ptr: *anyopaque) *std.Io.Writer,
        /// The end of the message, with trailers if there are any. Called
        /// exactly once, after the head and any body.
        end: *const fn (ptr: *anyopaque, trailers: ?*const http.Headers) std.Io.Writer.Error!void,
        /// What a failed write actually was, as `Connection.getWriteError`
        /// says for HTTP/1. Null when nothing was recorded.
        writeError: *const fn (ptr: *anyopaque) ?Response.SendError,
        /// Whether the peer went away (closed the stream or the connection),
        /// so a failure is not the handler's fault.
        peerGone: *const fn (ptr: *anyopaque) bool,
        /// Optional: the whole message at once, for a response whose body
        /// is all in memory (a buffered body, not a file or a stream): the
        /// head as `head` gets it, the body as `parts` in order, and the
        /// trailers as `end` gets them. Replaces `head`, `body` and `end`
        /// for that response, so the engine can frame it in one go (the
        /// end of the message on the last body frame, or on the head when
        /// there is no body) without a body writer or queue. `parts` and
        /// what they point to stay valid until the request's arena is
        /// reset; the slice itself does not, so copy it.
        complete: ?*const fn (ptr: *anyopaque, status: http.Status, headers: *const http.Headers, content_length: ?usize, parts: []const []const u8, trailers: ?*const http.Headers) std.Io.Writer.Error!void = null,
    };

    pub fn head(self: Sink, status: http.Status, headers: *const http.Headers, content_length: ?usize) std.Io.Writer.Error!void {
        return self.vtable.head(self.ptr, status, headers, content_length);
    }
    pub fn interim(self: Sink, status: http.Status) std.Io.Writer.Error!void {
        return self.vtable.interim(self.ptr, status);
    }
    pub fn body(self: Sink) *std.Io.Writer {
        return self.vtable.body(self.ptr);
    }
    pub fn end(self: Sink, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
        return self.vtable.end(self.ptr, trailers);
    }
    pub fn writeError(self: Sink) ?Response.SendError {
        return self.vtable.writeError(self.ptr);
    }
    pub fn peerGone(self: Sink) bool {
        return self.vtable.peerGone(self.ptr);
    }
    pub fn canComplete(self: Sink) bool {
        return self.vtable.complete != null;
    }
    pub fn complete(self: Sink, status: http.Status, headers: *const http.Headers, content_length: ?usize, parts: []const []const u8, trailers: ?*const http.Headers) std.Io.Writer.Error!void {
        return self.vtable.complete.?(self.ptr, status, headers, content_length, parts, trailers);
    }
};
