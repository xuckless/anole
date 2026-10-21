//! WebSocket over an HTTP/2 stream (RFC 8441) or an HTTP/3 one (RFC 9220):
//! the message layer `anole.websocket.Socket` runs over the sans-IO frame
//! codec of xuckless/websocket-zig (a fork of mattrobenolt/websocket-zig,
//! MIT). Internal to the WebSocket module: `receive` returns messages still
//! compressed when permessage-deflate is in use, and `Socket` inflates them.
const std = @import("std");
const dusty = @import("dusty");
const codec = @import("anole_websocket_codec").server;
const websocket = @import("root.zig");
const WebSocket = websocket.WebSocket;
const Message = websocket.Message;
const MessageType = websocket.MessageType;
const CloseCode = websocket.CloseCode;

/// A WebSocket on an HTTP/2 stream (RFC 8441) or an HTTP/3 one (RFC
/// 9220): frames arrive in the request body and leave in the streamed
/// response.
pub const H2Socket = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    body: dusty.RequestBodyReader,
    out: dusty.StreamingBodyWriter,
    in_buf: [buffer_len]u8,
    out_buf: [buffer_len]u8,
    frames: codec.FrameHandler,
    message: std.ArrayList(u8) = .empty,
    max_message_size: usize,
    /// Sending is over: a close went out.
    closed: bool = false,
    write_mutex: std.Io.Mutex = .init,
    /// One write per read, as over HTTP/1.1 (dusty's `WebSocket`): what
    /// the reading task sends while the peer's next message is already
    /// buffered goes out with the batch.
    batch: dusty.WebSocketBatch = .{},

    /// Each of the socket's buffers, for frames coming in and going out.
    /// Reads walk through the whole of one before they start over at its
    /// front, so all of it stays resident while the socket lives: a page,
    /// rather than four. A bigger message goes through in pieces, a frame
    /// with a bigger payload straight to the stream.
    pub const buffer_len = 4 * 1024;

    /// Answers the extended CONNECT and starts the socket on the request's
    /// body and a streamed response.
    pub fn accept(req: *dusty.Request, res: *dusty.Response, max_message_size: usize, deflate: bool) !*H2Socket {
        const self = try req.arena.create(H2Socket);
        self.* = .{
            .io = req.io,
            .arena = req.arena,
            .body = undefined,
            .out = undefined,
            .in_buf = undefined,
            .out_buf = undefined,
            // RSV1 is allowed once permessage-deflate is in use.
            .frames = .init(.{ .extension = if (deflate) .{ .permessage_deflate = .init } else null }),
            .max_message_size = max_message_size,
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

    /// Ends the response stream. `Socket.deinit` calls it.
    pub fn deinit(self: *H2Socket) void {
        self.batch.deinit(self.io);
        self.out.end() catch {};
    }

    /// The next message, as `Socket.receive` returns it, but not yet
    /// inflated: use `Socket.receive`.
    pub fn receive(self: *H2Socket) !Message {
        const msg = self.receiveMessage() catch |err| {
            self.batch.endRound();
            return err;
        };
        // A batch lasts while the peer's next message is already here (the
        // codec is between frames once it hands a message on).
        self.batch.round(self.io, WebSocket.bufferedMessage(self.body.interface.buffered()) != null);
        return msg;
    }

    fn receiveMessage(self: *H2Socket) !Message {
        self.message.clearRetainingCapacity();
        const reader = &self.body.interface;
        while (true) {
            // Fed even when nothing is buffered: the end of a frame whose
            // payload is already in arrives as its own event.
            const result = self.frames.feed(reader.buffered()) catch |err| {
                self.fail(.protocol_error);
                return err;
            };
            // A control frame's event comes at its end, so what follows
            // it starts the next frame.
            const next_frame = WebSocket.bufferedFrame(reader.buffered()[result.consumed..]) != null;
            const message = try self.handle(result.message, next_frame);
            reader.toss(result.consumed);
            if (message) |msg| return msg;
            if (result.message == .need_more) {
                // The batch ends where reading would wait for the peer.
                if (self.batch.deferred.load(.monotonic)) try self.flushDeferred();
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
    fn handle(self: *H2Socket, event: codec.FrameHandler.Message, next_frame: bool) !?Message {
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
                // A compressed text message is checked once inflated.
                if (!end.compressed and msg_type == .text and !std.unicode.utf8ValidateSlice(self.message.items)) {
                    self.fail(.invalid_payload);
                    return error.InvalidUtf8;
                }
                return .{ .type = msg_type, .data = self.message.items, .compressed = end.compressed };
            },
            .ping => |payload| {
                // In the batch when the next frame is here already.
                try self.writeFrameOpts(.{ .opcode = .pong }, payload, if (next_frame) .batch else .now);
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

    /// Sends one uncompressed message. `Socket.send` compresses.
    pub fn send(self: *H2Socket, msg_type: MessageType, data: []const u8) !void {
        return self.sendMessage(msg_type, data, false);
    }

    /// `send`, with RSV1 set when `compressed` (permessage-deflate).
    pub fn sendMessage(self: *H2Socket, msg_type: MessageType, data: []const u8, compressed: bool) !void {
        const opcode: codec.Opcode = switch (msg_type) {
            .text => .text,
            .binary => .binary,
            .ping => .ping,
            .pong => .pong,
            .close => return self.close(.normal, data),
            else => return error.InvalidOpcode,
        };
        try self.writeFrameOpts(.{ .opcode = opcode, .compressed = compressed }, data, self.sendFlush());
    }

    fn sendFlush(self: *H2Socket) Flush {
        return if (self.batch.holds(self.io)) .batch else .now;
    }

    /// Sends a ping. Fails with `error.LargeControlFrame` past 125 bytes.
    pub fn ping(self: *H2Socket, data: []const u8) !void {
        // As over HTTP/1.1; the codec asserts it rather than failing.
        if (data.len > codec.max_control_payload_len) return error.LargeControlFrame;
        try self.writeFrameOpts(.{ .opcode = .ping }, data, self.sendFlush());
    }

    /// Sends a close frame, once; the reason is cut to fit 125 bytes.
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
        return self.writeFrameOpts(.{ .opcode = opcode }, payload, .now);
    }

    /// What happens to the response buffer after a frame.
    const Flush = enum {
        /// Out now, with whatever else it held.
        now,
        /// Held for the reading task's batch.
        batch,
    };

    fn writeFrameOpts(self: *H2Socket, opts: codec.WriteFrameOptions, payload: []const u8, after: Flush) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.ConnectionClosed;
        const w = &self.out.interface;
        codec.writeFrame(w, payload, opts) catch return self.out.err orelse error.WriteFailed;
        if (after == .batch and self.batch.hold(self.io, flushHeld)) return;
        self.batch.flushing();
        w.flush() catch return self.out.err orelse error.WriteFailed;
    }

    /// Writes out what a batch held, if anything still holds it.
    fn flushDeferred(self: *H2Socket) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.batch.deferred.load(.monotonic) or self.closed) return;
        self.batch.flushing();
        self.out.interface.flush() catch return self.out.err orelse error.WriteFailed;
    }

    /// The batch's flush, for its backstop (`dusty.WebSocketBatch.hold`).
    fn flushHeld(batch: *dusty.WebSocketBatch) std.Io.Cancelable!void {
        const self: *H2Socket = @alignCast(@fieldParentPtr("batch", batch));
        self.flushDeferred() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The handler learns of it when its own read or write fails.
            else => {},
        };
    }
};
