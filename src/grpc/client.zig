//! The gRPC client, over `anole.h2.ClientConnection`:
//!
//!     const conn = try anole.h2.ClientConnection.connect(gpa, io, .{ .host = "127.0.0.1", .port = 50051 });
//!     defer conn.close();
//!     var channel: anole.grpc.Channel = .{ .conn = conn, .authority = "localhost" };
//!     const client: anole.grpc.Client(echo_pb.Echo(anole.grpc.Call, anyerror)) = .{ .channel = &channel };
//!     const result = try client.unary("Unary", arena, .{ .message = "hi" }, .{});
//!     // result.status, result.message
//!
//!     var s = try client.stream("Bidi", arena, .{});
//!     defer s.deinit();
//!     try s.send(.{ .message = "a" });
//!     try s.closeSend();
//!     while (try s.receive()) |reply| { ... }
//!     const status = s.status.?;
//!
//! The method table is the generated service type the server side uses;
//! its handlers are not called here, only its names and message types.
const std = @import("std");
const h2 = @import("anole_h2_client");
const frame = @import("frame.zig");
const status_mod = @import("status.zig");
const deadline = @import("deadline.zig");
const Compression = @import("compression.zig").Compression;
const server = @import("server.zig");

/// A call's outcome: code and message.
pub const Status = status_mod.Status;
/// A gRPC status code.
pub const Code = status_mod.Code;

/// Where calls go: an HTTP/2 connection and the authority to name. Calls
/// on one channel share the connection, as concurrent streams.
pub const Channel = struct {
    /// The connection, which the caller opens and closes.
    conn: *h2.ClientConnection,
    /// `:authority` for every call.
    authority: []const u8,
    /// "https" over TLS.
    scheme: []const u8 = "http",
    /// The largest response message taken; a larger one ends the call
    /// with RESOURCE_EXHAUSTED.
    max_message_size: usize = 4 * 1024 * 1024,
};

/// Per call: deadline, metadata, compression.
pub const CallOptions = struct {
    /// Sent as grpc-timeout; the server ends the call past it, and the
    /// client resets the stream past it (DEADLINE_EXCEEDED either way).
    timeout: ?std.Io.Duration = null,
    /// Extra request metadata, lower-case names.
    metadata: []const h2.Header = &.{},
    /// Compress request messages (and accept compressed responses).
    compression: Compression = .identity,
};

/// What `Client.unary` returns: the status, and the response message when
/// the status is OK. A failed call is a status, not an error; errors are
/// for the call not being made at all.
pub fn UnaryResult(comptime Resp: type) type {
    return struct {
        status: Status,
        /// Null unless the status is OK.
        message: ?Resp,
        /// Response headers and trailers, as received.
        headers: []const h2.Header,
        trailers: []const h2.Header,
    };
}

/// A call in progress: requests out, responses in, then the status.
pub fn Stream(comptime Req: type, comptime Resp: type) type {
    return struct {
        const Self = @This();

        channel: *Channel,
        stream: *h2.Stream,
        arena: std.mem.Allocator,
        compression: Compression,
        /// Set once the response has ended: from the trailers, or from the
        /// headers of a trailers-only response.
        status: ?Status = null,
        head_checked: bool = false,
        /// The call's deadline, when it has one: a call that ends without a
        /// status past it ended for that reason.
        deadline: ?std.Io.Clock.Timestamp = null,

        /// The status for a call that ended abnormally: DEADLINE_EXCEEDED
        /// past the deadline (the server, or its proxy, reset it), else
        /// `fallback`.
        fn ended(self: *const Self, fallback: Status) Status {
            if (self.deadline) |d| {
                if (std.Io.Clock.Timestamp.now(self.channel.conn.io, .awake).compare(.gte, d))
                    return .init(.deadline_exceeded, "deadline exceeded");
            }
            return fallback;
        }

        /// Sends one request message. Fails with `error.StreamClosed`
        /// once the call has ended (read the status with `receive`).
        pub fn send(self: *Self, message: Req) !void {
            var encoded: std.Io.Writer.Allocating = .init(self.arena);
            try message.encode(&encoded.writer, self.arena);
            const framed = try frame.encodeWithCompression(self.arena, encoded.written(), self.compression);
            const w = self.stream.writer();
            w.writeAll(framed) catch return error.StreamClosed;
            w.flush() catch return error.StreamClosed;
        }

        /// No more requests (half-close).
        pub fn closeSend(self: *Self) !void {
            self.stream.closeSend() catch return error.StreamClosed;
        }

        /// The next response, or null at the end of the call, when `status`
        /// is set.
        pub fn receive(self: *Self) !?Resp {
            if (self.status != null) return null;
            if (!self.head_checked) {
                self.head_checked = true;
                self.stream.waitHead() catch |err| {
                    self.status = self.ended(.init(.unavailable, @errorName(err)));
                    return null;
                };
                if (self.stream.status != 200) {
                    self.status = .init(httpStatusCode(self.stream.status), "HTTP status");
                    return null;
                }
                // Trailers-only: the status is in the headers.
                if (self.stream.header("grpc-status")) |_| {
                    self.status = try statusFrom(self.arena, self.stream.headers.items);
                    return null;
                }
            }
            const encoding: Compression = if (self.stream.header("grpc-encoding")) |e| Compression.parse(e) orelse .identity else .identity;
            const msg = frame.readMessage(self.stream.reader(), self.arena, self.channel.max_message_size, encoding) catch |err| {
                self.status = switch (err) {
                    error.ReadFailed => self.ended(.init(.unavailable, "stream reset")),
                    error.MessageTooLarge => .init(.resource_exhausted, "message larger than the limit"),
                    else => .init(.internal, @errorName(err)),
                };
                return null;
            } orelse {
                self.status = try statusFrom(self.arena, self.stream.trailers.items);
                return null;
            };
            var reader: std.Io.Reader = .fixed(msg.payload);
            return Resp.decode(&reader, self.arena) catch {
                self.status = .init(.internal, "response did not decode");
                self.stream.cancel();
                return null;
            };
        }

        /// Drops the call, canceling it if it is still open.
        pub fn deinit(self: *Self) void {
            self.stream.release();
        }

        /// Cancels the call (RST_STREAM CANCEL); `deinit` still frees it.
        pub fn cancel(self: *Self) void {
            self.stream.cancel();
        }
    };
}

/// A client for `Service`, a zig-protobuf service type (any instantiation:
/// only its names and message types are used).
pub fn Client(comptime Service: type) type {
    return struct {
        const Self = @This();
        channel: *Channel,

        fn MethodOf(comptime name: []const u8) type {
            return server.MethodOf(@FieldType(Service, name));
        }

        fn path(comptime name: []const u8) []const u8 {
            _ = @FieldType(Service, name); // a method of this service
            return "/" ++ Service.package ++ "." ++ Service.service_name ++ "/" ++ name;
        }

        /// Opens a call to `method`: any of the four kinds; send, close the
        /// sending side, then receive.
        pub fn stream(self: Self, comptime method: []const u8, arena: std.mem.Allocator, options: CallOptions) !Stream(MethodOf(method).Request, MethodOf(method).Response) {
            return open(MethodOf(method).Request, MethodOf(method).Response, self.channel, path(method), arena, options);
        }

        /// A unary call (or a server-streaming one's first response).
        pub fn unary(self: Self, comptime method: []const u8, arena: std.mem.Allocator, request: MethodOf(method).Request, options: CallOptions) !UnaryResult(MethodOf(method).Response) {
            const M = MethodOf(method);
            var s = try open(M.Request, M.Response, self.channel, path(method), arena, options);
            defer s.deinit();
            try s.send(request);
            try s.closeSend();
            const message = try s.receive();
            // Drain to the trailers.
            if (message != null) while (try s.receive()) |_| {};
            const st = s.status orelse Status.init(.internal, "no status");
            return .{
                .status = st,
                .message = if (st.code == .ok) message else null,
                // Copied out: the stream (and what it received) is freed
                // on return.
                .headers = try copyHeaders(s.arena, s.stream.headers.items),
                .trailers = try copyHeaders(s.arena, s.stream.trailers.items),
            };
        }
    };
}

/// Opens a call by path, for code without a generated service type.
pub fn open(comptime Req: type, comptime Resp: type, channel: *Channel, method_path: []const u8, arena: std.mem.Allocator, options: CallOptions) !Stream(Req, Resp) {
    var headers: std.ArrayList(h2.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = channel.scheme },
        .{ .name = ":path", .value = method_path },
        .{ .name = ":authority", .value = channel.authority },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "te", .value = "trailers" },
        .{ .name = "grpc-accept-encoding", .value = "identity,gzip" },
    });
    if (options.compression == .gzip) try headers.append(arena, .{ .name = "grpc-encoding", .value = "gzip" });
    if (options.timeout) |t| {
        var buf: [32]u8 = undefined;
        const ns: u64 = @intCast(@max(0, t.nanoseconds));
        try headers.append(arena, .{ .name = "grpc-timeout", .value = try arena.dupe(u8, deadline.formatTimeout(&buf, ns)) });
    }
    try headers.appendSlice(arena, options.metadata);
    const io = channel.conn.io;
    const call_deadline: ?std.Io.Clock.Timestamp = if (options.timeout) |t|
        std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = t, .clock = .awake })
    else
        null;
    // The deadline bounds the stream on this side too; a call without one
    // may stream for as long as it likes.
    const s = try channel.conn.request(headers.items, .{
        .body = true,
        .timeout = if (call_deadline) |d| .{ .deadline = d } else .none,
    });
    return .{
        .channel = channel,
        .stream = s,
        .arena = arena,
        .compression = options.compression,
        .deadline = call_deadline,
    };
}

fn copyHeaders(arena: std.mem.Allocator, fields: []const h2.Header) ![]h2.Header {
    const out = try arena.alloc(h2.Header, fields.len);
    for (fields, out) |f, *o| o.* = .{ .name = try arena.dupe(u8, f.name), .value = try arena.dupe(u8, f.value) };
    return out;
}

fn statusFrom(arena: std.mem.Allocator, fields: []const h2.Header) !Status {
    var code: ?Code = null;
    var message: []const u8 = "";
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "grpc-status")) code = Code.fromInt(std.fmt.parseInt(u32, f.value, 10) catch 2);
        if (std.mem.eql(u8, f.name, "grpc-message")) message = try arena.dupe(u8, try percentDecode(arena, f.value));
    }
    return .init(code orelse .internal, if (code == null) "missing grpc-status" else message);
}

fn percentDecode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, text[i]);
    }
    return out.items;
}

/// gRPC's mapping of a non-200 HTTP status (a proxy's answer, say).
fn httpStatusCode(http: u16) Code {
    return switch (http) {
        400 => .internal,
        401 => .unauthenticated,
        403 => .permission_denied,
        404 => .unimplemented,
        429, 502, 503, 504 => .unavailable,
        else => .unknown,
    };
}

test "percentDecode undoes grpc-message encoding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%b\né", try percentDecode(arena.allocator(), "a%25b%0A%C3%A9"));
    try std.testing.expectEqualStrings("plain", try percentDecode(arena.allocator(), "plain"));
}
