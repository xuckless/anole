//! WebSocket for handlers, over HTTP/1.1 (RFC 6455 upgrade) and HTTP/2
//! (RFC 8441 extended CONNECT), behind one `Socket`:
//!
//!     fn chat(req: *anole.Request, res: *anole.Response) !void {
//!         var ws = (try anole.websocket.upgrade(req, res, .{})) orelse {
//!             res.status = .bad_request;
//!             return;
//!         };
//!         defer ws.deinit();
//!         while (true) {
//!             const msg = try ws.receive();
//!             switch (msg.type) {
//!                 .text, .binary => try ws.send(msg.type, msg.data),
//!                 .close => return,
//!                 else => {},
//!             }
//!         }
//!     }
//!
//! HTTP/1.1 runs on dusty's RFC 6455 implementation (MIT). HTTP/2 runs on
//! the sans-IO frame codec of xuckless/websocket-zig (a fork of
//! mattrobenolt/websocket-zig, MIT) over the stream's request body and
//! streamed response; this file is the message layer over it, with dusty's
//! semantics: pings are answered and pongs dropped inside `receive`, a close
//! is echoed and returned, a text message must be valid UTF-8.
const std = @import("std");
const dusty = @import("dusty");
const features = @import("build_options");
const codec = @import("anole_websocket_codec").server;

/// dusty's WebSocket over an HTTP/1.1 connection.
pub const WebSocket = dusty.WebSocket;
pub const Message = WebSocket.Message;
pub const MessageType = WebSocket.MessageType;
pub const CloseCode = WebSocket.CloseCode;
/// dusty's client for `ws://` URLs.
pub const Client = dusty.WebSocketClient;

pub const UpgradeOptions = struct {
    /// The largest message `receive` assembles; a bigger one is answered
    /// with close 1009.
    max_message_size: usize = WebSocket.default_max_message_size,
    /// Replaces the request's timeout once the socket is open: a socket
    /// outlives `timeout.request`. Set a deadline here, or call
    /// `req.setTimeout` before each `receive` for an idle limit.
    timeout: std.Io.Timeout = .none,
};

/// A WebSocket a handler holds, whichever HTTP version it arrived on.
pub const Socket = union(enum) {
    h1: WebSocket,
    h2: *H2Socket,

    /// The next text, binary or close message. Pings are answered and
    /// pongs dropped on the way.
    pub fn receive(self: *Socket) !Message {
        return switch (self.*) {
            .h1 => |*ws| ws.receive(),
            .h2 => |ws| ws.receive(),
        };
    }

    pub fn send(self: *Socket, msg_type: MessageType, data: []const u8) !void {
        return switch (self.*) {
            .h1 => |*ws| ws.send(msg_type, data),
            .h2 => |ws| ws.send(msg_type, data),
        };
    }

    pub fn ping(self: *Socket, data: []const u8) !void {
        return switch (self.*) {
            .h1 => |*ws| ws.ping(data),
            .h2 => |ws| ws.ping(data),
        };
    }

    /// Sends a close frame. The peer's answer still arrives through
    /// `receive`.
    pub fn close(self: *Socket, code: CloseCode, reason: []const u8) !void {
        return switch (self.*) {
            .h1 => |*ws| ws.close(code, reason),
            .h2 => |ws| ws.close(code, reason),
        };
    }

    pub fn deinit(self: *Socket) void {
        switch (self.*) {
            .h1 => |*ws| ws.deinit(),
            .h2 => |ws| ws.deinit(),
        }
    }
};

/// Accepts the WebSocket `req` asks for, on either HTTP version, and
/// answers the handshake. Null when `req` is not a WebSocket request (the
/// handler answers it as it sees fit). The socket lives as long as the
/// handler: the request's arena holds it.
pub fn upgrade(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions) !?Socket {
    if (req.protocol) |protocol| {
        if (!features.http2 or !std.ascii.eqlIgnoreCase(protocol, "websocket")) return null;
        const version = req.headers.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;
        const socket = try H2Socket.accept(req, res, options);
        req.setTimeout(options.timeout);
        return .{ .h2 = socket };
    }
    var ws = (try res.upgradeWebSocket(req)) orelse return null;
    ws.max_message_size = options.max_message_size;
    req.setTimeout(options.timeout);
    return .{ .h1 = ws };
}

/// A WebSocket on an HTTP/2 stream (RFC 8441): frames arrive in the
/// request body and leave in the streamed response.
pub const H2Socket = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    body: dusty.RequestBodyReader,
    out: dusty.StreamingBodyWriter,
    in_buf: [16 * 1024]u8,
    out_buf: [16 * 1024]u8,
    frames: codec.FrameHandler,
    message: std.ArrayList(u8) = .empty,
    max_message_size: usize,
    /// Sending is over: a close went out.
    closed: bool = false,
    write_mutex: std.Io.Mutex = .init,

    fn accept(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions) !*H2Socket {
        const self = try req.arena.create(H2Socket);
        self.* = .{
            .io = req.io,
            .arena = req.arena,
            .body = undefined,
            .out = undefined,
            .in_buf = undefined,
            .out_buf = undefined,
            .frames = .init(.{}),
            .max_message_size = options.max_message_size,
        };
        // A 200 accepts the extended CONNECT (RFC 8441 §5); the stream
        // stays open both ways.
        res.status = .ok;
        self.out = try res.stream(&self.out_buf);
        // Out now, so the client may start sending frames.
        try self.out.interface.flush();
        self.body = try req.reader(&self.in_buf);
        return self;
    }

    pub fn deinit(self: *H2Socket) void {
        self.out.end() catch {};
    }

    pub fn receive(self: *H2Socket) !Message {
        self.message.clearRetainingCapacity();
        const reader = &self.body.interface;
        while (true) {
            // Fed even when nothing is buffered: the end of a frame whose
            // payload is already in arrives as its own event.
            const result = self.frames.feed(reader.buffered()) catch |err| {
                self.fail(.protocol_error);
                return err;
            };
            const message = try self.handle(result.message);
            reader.toss(result.consumed);
            if (message) |msg| return msg;
            if (result.message == .need_more) {
                reader.fillMore() catch |err| switch (err) {
                    // The stream ended without a close frame.
                    error.EndOfStream => return error.ConnectionClosed,
                    error.ReadFailed => return self.body.err orelse error.Unexpected,
                };
            }
        }
    }

    /// Acts on one codec event, before its bytes are let go (payloads are
    /// slices of the read buffer). A message for the caller, or null to
    /// keep reading.
    fn handle(self: *H2Socket, event: codec.FrameHandler.Message) !?Message {
        switch (event) {
            .data => |payload| {
                if (self.message.items.len + payload.len > self.max_message_size) {
                    self.fail(.too_large);
                    return error.MessageTooLarge;
                }
                try self.message.appendSlice(self.arena, payload);
                return null;
            },
            .data_end => |end| {
                const msg_type: MessageType = if (end.opcode == .text) .text else .binary;
                if (msg_type == .text and !std.unicode.utf8ValidateSlice(self.message.items)) {
                    self.fail(.invalid_payload);
                    return error.InvalidUtf8;
                }
                return .{ .type = msg_type, .data = self.message.items };
            },
            .ping => |payload| {
                try self.writeFrame(.pong, payload);
                return null;
            },
            .pong, .need_more => return null,
            .close => |payload| {
                const parsed = codec.parseClosePayload(payload) catch {
                    self.fail(.protocol_error);
                    return error.InvalidCloseFrame;
                };
                const code: ?CloseCode = if (parsed) |p| @fromBackingInt(@backingInt(p.code)) else null;
                const reason = if (parsed) |p| try self.arena.dupe(u8, p.reason) else "";
                if (!std.unicode.utf8ValidateSlice(reason)) {
                    self.fail(.invalid_payload);
                    return error.InvalidUtf8;
                }
                // Echo the code (RFC 6455 §5.5.1), or 1000 for none.
                try self.sendClose(code orelse .normal, "");
                return .{ .type = .close, .data = reason, .close_code = code };
            },
        }
    }

    pub fn send(self: *H2Socket, msg_type: MessageType, data: []const u8) !void {
        const opcode: codec.Opcode = switch (msg_type) {
            .text => .text,
            .binary => .binary,
            .ping => .ping,
            .pong => .pong,
            .close => return self.close(.normal, data),
            else => return error.InvalidOpcode,
        };
        try self.writeFrame(opcode, data);
    }

    pub fn ping(self: *H2Socket, data: []const u8) !void {
        try self.writeFrame(.ping, data);
    }

    pub fn close(self: *H2Socket, code: CloseCode, reason: []const u8) !void {
        try self.sendClose(code, reason);
    }

    fn sendClose(self: *H2Socket, code: CloseCode, reason: []const u8) !void {
        if (self.closed) return;
        var payload: [codec.max_control_payload_len]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], @backingInt(code), .big);
        const n = @min(reason.len, payload.len - 2);
        @memcpy(payload[2..][0..n], reason[0..n]);
        try self.writeFrame(.close, payload[0 .. 2 + n]);
        self.closed = true;
    }

    /// A protocol failure: close with `code` if sending is still open.
    fn fail(self: *H2Socket, code: CloseCode) void {
        self.sendClose(code, "") catch {};
    }

    fn writeFrame(self: *H2Socket, opcode: codec.Opcode, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.ConnectionClosed;
        const w = &self.out.interface;
        codec.writeFrame(w, payload, .{ .opcode = opcode }) catch return self.out.err orelse error.WriteFailed;
        w.flush() catch return self.out.err orelse error.WriteFailed;
    }
};

test {
    if (features.http2) _ = @import("h2_test.zig");
}

test "WebSocket accept key matches RFC 6455 section 1.3" {
    var out: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
