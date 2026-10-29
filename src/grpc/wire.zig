//! The gRPC client's transport: a request stream over `anole.h2` or
//! `anole.h3`, which share their API. Internal.
const std = @import("std");
const h2 = @import("anole_h2_client");
const features = @import("build_options");

/// The HTTP/3 client, or stand-ins that are never used without `-Dhttp3`.
pub const h3 = if (features.http3) @import("../h3/client.zig") else struct {
    pub const ClientConnection = opaque {};
    pub const Stream = opaque {};
    pub const Header = h2.Header;
};

pub const Transport = enum { h2, h3 };

const have_h3 = features.http3;

pub const Conn = union(Transport) {
    h2: *h2.ClientConnection,
    h3: *h3.ClientConnection,

    pub fn io(c: Conn) std.Io {
        return switch (c) {
            .h2 => |x| x.io,
            .h3 => |x| if (comptime have_h3) x.io else unreachable,
        };
    }

    /// Opens a request stream with a body. `headers` are copied into the
    /// other transport's header type when needed.
    pub fn request(c: Conn, arena: std.mem.Allocator, headers: []const h2.Header, timeout: std.Io.Timeout, send_buffer: usize) !Stream {
        switch (c) {
            .h2 => |x| return .{ .h2 = try x.request(headers, .{ .body = true, .timeout = timeout }) },
            .h3 => |x| {
                if (comptime !have_h3) unreachable;
                const copy = try arena.alloc(h3.Header, headers.len);
                for (headers, copy) |f, *o| o.* = .{ .name = f.name, .value = f.value };
                return .{ .h3 = try x.request(copy, .{ .body = true, .timeout = timeout, .send_buffer = send_buffer }) };
            },
        }
    }

    /// No new streams (GOAWAY, failure, close).
    pub fn closing(c: Conn) bool {
        return switch (c) {
            .h2 => |x| !x.isOpen(),
            .h3 => |x| if (comptime have_h3) !x.isOpen() else true,
        };
    }
};

pub const Stream = union(Transport) {
    h2: *h2.Stream,
    h3: *h3.Stream,

    pub fn writer(s: Stream) *std.Io.Writer {
        return switch (s) {
            .h2 => |x| x.writer(),
            .h3 => |x| if (comptime have_h3) x.writer() else unreachable,
        };
    }

    pub fn reader(s: Stream) *std.Io.Reader {
        return switch (s) {
            .h2 => |x| x.reader(),
            .h3 => |x| if (comptime have_h3) x.reader() else unreachable,
        };
    }

    pub fn closeSend(s: Stream) !void {
        switch (s) {
            .h2 => |x| try x.closeSend(),
            .h3 => |x| if (comptime have_h3) try x.closeSend() else unreachable,
        }
    }

    /// The error sets of the two clients are equal (tested in src/root.zig).
    pub fn waitHead(s: Stream) h2.StreamError!void {
        switch (s) {
            .h2 => |x| try x.waitHead(),
            .h3 => |x| if (comptime have_h3) try x.waitHead() else unreachable,
        }
    }

    pub fn status(s: Stream) u16 {
        return switch (s) {
            .h2 => |x| x.status,
            .h3 => |x| if (comptime have_h3) x.status else unreachable,
        };
    }

    pub fn header(s: Stream, name: []const u8) ?[]const u8 {
        return switch (s) {
            .h2 => |x| x.header(name),
            .h3 => |x| if (comptime have_h3) x.header(name) else unreachable,
        };
    }

    pub fn readError(s: Stream) ?h2.StreamError {
        return switch (s) {
            .h2 => |x| x.readError(),
            .h3 => |x| if (comptime have_h3) x.readError() else unreachable,
        };
    }

    pub fn writeError(s: Stream) ?h2.StreamError {
        return switch (s) {
            .h2 => |x| x.writeError(),
            .h3 => |x| if (comptime have_h3) x.writeError() else unreachable,
        };
    }

    /// `cancel` or `release` ended the stream (not a cancel of the task
    /// waiting on it).
    pub fn canceledLocally(s: Stream) bool {
        return switch (s) {
            .h2 => |x| x.canceledLocally(),
            .h3 => |x| if (comptime have_h3) x.canceledLocally() else unreachable,
        };
    }

    pub fn resetCode(s: Stream) ?u64 {
        return switch (s) {
            .h2 => |x| x.resetCode(),
            .h3 => |x| if (comptime have_h3) x.resetCode() else unreachable,
        };
    }

    pub fn unprocessed(s: Stream) bool {
        return switch (s) {
            .h2 => |x| x.unprocessed(),
            .h3 => |x| if (comptime have_h3) x.unprocessed() else unreachable,
        };
    }

    pub fn cancel(s: Stream) void {
        switch (s) {
            .h2 => |x| x.cancel(),
            .h3 => |x| if (comptime have_h3) x.cancel() else unreachable,
        }
    }

    pub fn release(s: Stream) void {
        switch (s) {
            .h2 => |x| x.release(),
            .h3 => |x| if (comptime have_h3) x.release() else unreachable,
        }
    }

    /// The response header fields in the caller's `arena`, as h2.Header.
    pub fn copyHeaders(s: Stream, arena: std.mem.Allocator) ![]h2.Header {
        return switch (s) {
            .h2 => |x| try copyFields(arena, x.headers.items),
            .h3 => |x| if (comptime have_h3) try copyFields(arena, x.headers.items) else unreachable,
        };
    }

    /// The trailers, copied the same way.
    pub fn copyTrailers(s: Stream, arena: std.mem.Allocator) ![]h2.Header {
        return switch (s) {
            .h2 => |x| try copyFields(arena, x.trailers.items),
            .h3 => |x| if (comptime have_h3) try copyFields(arena, x.trailers.items) else unreachable,
        };
    }

    pub fn trailer(s: Stream, name: []const u8) ?[]const u8 {
        return switch (s) {
            .h2 => |x| x.trailer(name),
            .h3 => |x| if (comptime have_h3) x.trailer(name) else unreachable,
        };
    }
};

fn copyFields(arena: std.mem.Allocator, fields: anytype) ![]h2.Header {
    const out = try arena.alloc(h2.Header, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = try arena.dupe(u8, f.name), .value = try arena.dupe(u8, f.value) };
    return out;
}
