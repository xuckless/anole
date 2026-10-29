// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const Transport = @import("transport.zig").Transport;
const placement = @import("placement.zig");

const log = std.log.scoped(.anole);

/// Whether `req` is an HTTP/1.1 WebSocket handshake (RFC 6455 4.2.1): a GET
/// with `Upgrade: websocket`, `Connection: upgrade`, `Sec-WebSocket-Version:
/// 13` and a valid `Sec-WebSocket-Key`.
pub fn isHandshake(req: *const @import("request.zig").Request) bool {
    if (req.method != .get) return false;
    const upgrade = req.headers.get("Upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " \t"), "websocket")) return false;
    const connection = req.headers.get("Connection") orelse return false;
    if (std.ascii.findIgnoreCase(connection, "upgrade") == null) return false;
    const version = req.headers.get("Sec-WebSocket-Version") orelse return false;
    if (!std.mem.eql(u8, version, "13")) return false;
    const key = req.headers.get("Sec-WebSocket-Key") orelse return false;
    return WebSocket.validKey(key);
}

/// An established WebSocket connection (RFC 6455). Obtained from
/// `Response._upgradeWebSocket` on the server side and `Client.connectWebSocket`
/// on the client side; call `deinit` when done.
///
/// One task may call `receive`; any number of tasks may send concurrently.
///
/// Replies go out once per read: while the peer's next message is already
/// in the read buffer, what the reading task sends waits there too (see
/// `Batch`), so a peer that pipelines messages gets one write per batch
/// rather than one per message. Sends from any other task are written at
/// once, as are the reading task's when nothing more is waiting.
pub const WebSocket = struct {
    io: std.Io,
    /// The connection underneath, and the only thing that knows why a frame
    /// failed to go out or come in. Shared with both ends of the library,
    /// which hold unrelated `Connection` types.
    transport: Transport,
    msg_arena: std.heap.ArenaAllocator,
    is_client: bool = false,
    prng: std.Random.DefaultPrng,
    max_message_size: usize = default_max_message_size,
    closed: bool = false,
    auto_responded: bool = false,
    fragmented_type: ?MessageType = null,
    /// The message in pieces had RSV1 on its first frame.
    fragmented_compressed: bool = false,
    /// An extension that claims RSV1 (permessage-deflate, RFC 7692) was
    /// negotiated: RSV1 on a message's first frame is passed on as
    /// `Message.compressed` rather than refused. The extension itself is
    /// the caller's.
    rsv1_allowed: bool = false,
    fragmented_data: std.ArrayListUnmanaged(u8) = .empty,
    write_mutex: std.Io.Mutex = .init,
    /// When false, `send` and `ping` skip the flush after writing their
    /// frame, including when sent from other tasks, so frames collect in the
    /// write buffer until `flush`. Bytes still reach the transport whenever
    /// the buffer fills. Pongs sent by `receive` and close frames are always
    /// flushed, taking any buffered frames with them.
    autoflush: bool = true,
    /// Holds the reading task's replies while more of the peer's messages
    /// are buffered.
    batch: Batch = .{},
    /// The last control frame's payload: a ping's (answered from here) or a
    /// close's reason, valid as a message's data is.
    control_payload: [125]u8 = undefined,

    /// The largest message a socket accepts unless told otherwise: 16 MiB.
    pub const default_max_message_size: usize = 1024 * 1024; // 1 MiB

    /// A frame's opcode. Handlers see `.text` and `.binary` messages, and
    /// `.close` when the peer closes; pings are answered for them.
    pub const MessageType = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
        _, // Allow unknown opcodes
    };

    /// One whole message, reassembled from its fragments.
    pub const Message = struct {
        type: MessageType,
        /// The payload, valid until the next receive.
        data: []const u8,
        /// The peer's close code, for a `.close` message that has one.
        close_code: ?CloseCode = null,
        /// RSV1 was set (only with `rsv1_allowed`): `data` is still
        /// compressed, and a text message is not yet checked for UTF-8.
        compressed: bool = false,
    };

    /// A close frame's status code (RFC 6455 §7.4); codes 3000-4999 are
    /// free for applications.
    pub const CloseCode = enum(u16) {
        normal = 1000,
        going_away = 1001,
        protocol_error = 1002,
        unsupported = 1003,
        no_status = 1005,
        abnormal = 1006,
        invalid_payload = 1007,
        policy_violation = 1008,
        too_large = 1009,
        mandatory_extension = 1010,
        internal_error = 1011,
        _,

        /// Whether a peer may put this code in a close frame: RFC 6455
        /// §7.4 reserves 1005, 1006 and 1015 for local use, and anything
        /// below 1000 or between the registered range and 3000 is not a
        /// code at all.
        fn validOnTheWire(self: CloseCode) bool {
            const v = @backingInt(self);
            return (v >= 1000 and v <= 1003) or (v >= 1007 and v <= 1014) or (v >= 3000 and v <= 4999);
        }
    };

    /// Protocol violations a peer's frames can cause; the socket is
    /// closed with the matching code.
    pub const Error = error{
        ReservedFlags,
        LargeControlFrame,
        InvalidOpcode,
        UnexpectedContinuation,
        NestedFragment,
        InvalidUtf8,
        MessageTooLarge,
        UnmaskedClientFrame,
        MaskedServerFrame,
        FragmentedControlFrame,
        InvalidClosePayload,
    };

    const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    /// A socket over `transport`. Made by the server or the client on an
    /// upgrade; not for handlers.
    pub fn init(io: std.Io, transport: Transport, gpa: std.mem.Allocator, seed: u64) WebSocket {
        return .{
            .io = io,
            .transport = transport,
            .msg_arena = std.heap.ArenaAllocator.init(gpa),
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Free resources. Must be called when done with the WebSocket.
    pub fn deinit(self: *WebSocket) void {
        self.batch.deinit(self.io);
        self.msg_arena.deinit();
    }

    /// Receive next message. Blocks until message arrives.
    /// Ping frames are handled automatically (pong sent).
    /// Pong frames are ignored.
    /// The returned message data is valid until the next call to receive(),
    /// receiveMany() or tryReceive().
    pub fn receive(self: *WebSocket) !Message {
        self.resetMessages();
        // Inlined down to the frame, so a loop that reads gets one function
        // however many other paths share the parts (`receiveStarted`,
        // `tryReceive`, the pongs): a call for each layer costs an echo
        // about a tenth of its CPU.
        return @call(.always_inline, nextMessage, .{self});
    }

    /// Like `receive`, but also returns every further message already
    /// complete in the read buffer, without blocking for more. A close
    /// message comes in a batch of its own, so the messages before it can
    /// still be answered. The messages are valid until the next call to
    /// receive(), receiveMany() or tryReceive(). With more than one, the
    /// answers to them are a batch (`Batch`) until the next call.
    pub fn receiveMany(self: *WebSocket) ![]const Message {
        self.resetMessages();
        const arena = self.msg_arena.allocator();
        var msgs: std.ArrayListUnmanaged(Message) = .empty;
        try msgs.append(arena, try self.nextMessage());
        while (msgs.getLast().type != .close) {
            const msg = try self.nextBufferedMessage() orelse break;
            try msgs.append(arena, msg);
        }
        if (msgs.items.len > 1) self.batch.round(self.io, true);
        return msgs.items;
    }

    /// Like `receive`, but returns null instead of blocking when no whole
    /// message is in the read buffer. A null leaves the previously returned
    /// message valid.
    pub fn tryReceive(self: *WebSocket) !?Message {
        if (bufferedMessage(self.transport.reader.buffered()) == null) return null;
        self.resetMessages();
        return try self.nextMessage();
    }

    /// For a reading task that waits for the peer in its own way (a parked
    /// connection, `atRest`): the next message, read to its end, when one
    /// has begun in the read buffer; null once the buffer is empty, after
    /// answering the control frames in it (a ping gets its pong), so a peer
    /// that only pings does not hold the task. Part of a control frame is
    /// read to its end first. The message as `receive` returns it.
    pub fn receiveStarted(self: *WebSocket) !?Message {
        const r = self.transport.reader;
        while (true) {
            const bytes = r.buffered();
            if (bytes.len == 0) return null;
            const opcode = bytes[0] & 0x0F;
            if (opcode != @backingInt(MessageType.ping) and opcode != @backingInt(MessageType.pong)) return try self.receive();
            // A control frame is whole and at most 125 bytes: one whose
            // header says otherwise is not waited for, but read (and
            // refused) the way `receive` reads every frame.
            if (bytes.len >= 2 and (bytes[0] & 0x80 == 0 or bytes[1] & 0x7F > 125)) return try self.receive();
            if (bufferedFrame(bytes) == null) {
                // A window too small for the frame: `receive` streams it.
                if (r.bufferedLen() == r.buffer.len) return try self.receive();
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    error.ReadFailed => return self.transport.getReadError() orelse error.Unexpected,
                };
                continue;
            }
            self.resetMessages();
            self.takeControlFrame() catch |err| switch (err) {
                error.ReadFailed => return self.transport.getReadError() orelse error.Unexpected,
                else => |e| {
                    if (failureCloseCode(e)) |code| self.writeClose(code, "") catch {};
                    return e;
                },
            };
        }
    }

    /// One ping or pong, whole in the read buffer.
    fn takeControlFrame(self: *WebSocket) !void {
        const frame = try self.readFrame();
        if (frame.rsv1) return Error.ReservedFlags;
        if (frame.opcode != .ping) return;
        const after: Flush = if (self.autoflush and bufferedFrame(self.transport.reader.buffered()) != null) .batch else .now;
        try self.writeFrame(.pong, frame.payload, true, after);
    }

    /// Reading a close answers it, which ends sending, so a close is left
    /// for the next batch.
    fn nextBufferedMessage(self: *WebSocket) !?Message {
        if (bufferedMessage(self.transport.reader.buffered()) != .data) return null;
        return try self.nextMessage();
    }

    fn nextMessage(self: *WebSocket) !Message {
        const msg = @call(.always_inline, readMessageOrFail, .{self}) catch |err| {
            self.batch.endRound();
            return err;
        };
        // A batch lasts while the peer's next message is already here, or
        // begun: its header is buffered and bytes wait below the reader
        // (the TLS layer), so it needs no wait for the peer.
        self.batch.round(self.io, !self.wouldWait());
        return msg;
    }

    /// Whether reading the next message may have to wait for the peer: no
    /// whole message is buffered, and no frame has begun with bytes still
    /// waiting beneath the reader (a message bigger than its window).
    fn wouldWait(self: *WebSocket) bool {
        const buffered = self.transport.reader.buffered();
        if (bufferedMessage(buffered) != null) return false;
        return !(bufferedHeader(buffered) and self.transport.bufferedBelow());
    }

    /// Whether `bytes` holds the whole header of a frame.
    fn bufferedHeader(bytes: []const u8) bool {
        if (bytes.len < 2) return false;
        var header_len: usize = 2;
        const len7 = bytes[1] & 0x7F;
        if (len7 == 126) header_len = 4 else if (len7 == 127) header_len = 10;
        if (bytes[1] & 0x80 != 0) header_len += 4;
        return bytes.len >= header_len;
    }

    fn readMessageOrFail(self: *WebSocket) !Message {
        return @call(.always_inline, readMessage, .{self}) catch |err| switch (err) {
            // The reads inside can only report the sentinel; the transport
            // knows what actually happened.
            error.ReadFailed => self.transport.getReadError() orelse error.Unexpected,
            else => |e| {
                // A peer that broke the protocol is told why before the
                // connection ends (RFC 6455 §7.1.7), if sending is still
                // open; what it sent after is not read.
                if (failureCloseCode(e)) |code| self.writeClose(code, "") catch {};
                return e;
            },
        };
    }

    /// The close code that answers a receive failure, or null for one that
    /// is not the peer's doing (out of memory, say).
    fn failureCloseCode(err: anyerror) ?CloseCode {
        return switch (err) {
            Error.MessageTooLarge => .too_large,
            Error.InvalidUtf8 => .invalid_payload,
            Error.ReservedFlags,
            Error.LargeControlFrame,
            Error.InvalidOpcode,
            Error.UnexpectedContinuation,
            Error.NestedFragment,
            Error.UnmaskedClientFrame,
            Error.MaskedServerFrame,
            Error.FragmentedControlFrame,
            Error.InvalidClosePayload,
            => .protocol_error,
            else => null,
        };
    }

    /// The most message memory kept between messages: a socket that once
    /// received a keyframe does not hold it for good.
    const retained_message_max = 64 * 1024;

    fn resetMessages(self: *WebSocket) void {
        _ = self.msg_arena.reset(.{ .retain_with_limit = retained_message_max });
        self.auto_responded = false;
    }

    /// Whether `bytes` starts with a whole message, along with any control
    /// frames before or inside it, and which kind. For a layer that frames
    /// WebSocket messages itself (over HTTP/2, say) as much as for this one.
    pub fn bufferedMessage(bytes: []const u8) ?enum { data, close } {
        var rest = bytes;
        while (true) {
            const len = bufferedFrame(rest) orelse return null;
            const fin = rest[0] & 0x80 != 0;
            const opcode = rest[0] & 0x0F;
            rest = rest[len..];
            if (opcode & 0x8 == 0) {
                if (fin) return .data;
            } else if (opcode == @backingInt(MessageType.close)) {
                return .close;
            }
        }
    }

    /// The length of the frame `bytes` starts with, when all of it is
    /// there; null when it is not (or `bytes` is empty).
    pub fn bufferedFrame(bytes: []const u8) ?usize {
        if (bytes.len < 2) return null;
        var header_len: usize = 2;
        var payload_len: u64 = bytes[1] & 0x7F;
        if (payload_len == 126) {
            if (bytes.len < 4) return null;
            payload_len = std.mem.readInt(u16, bytes[2..4], .big);
            header_len = 4;
        } else if (payload_len == 127) {
            if (bytes.len < 10) return null;
            payload_len = std.mem.readInt(u64, bytes[2..10], .big);
            header_len = 10;
        }
        if (bytes[1] & 0x80 != 0) header_len += 4;
        if (bytes.len < header_len or bytes.len - header_len < payload_len) return null;
        return header_len + @as(usize, @intCast(payload_len));
    }

    fn readMessage(self: *WebSocket) !Message {
        self.fragmented_data = .empty;
        self.fragmented_type = null;
        self.fragmented_compressed = false;
        while (true) {
            // The batch ends where reading would wait for the peer: what
            // it held goes out first.
            if (self.batch.deferred.load(.monotonic) and bufferedFrame(self.transport.reader.buffered()) == null and
                !(bufferedHeader(self.transport.reader.buffered()) and self.transport.bufferedBelow()))
            {
                try self.flushDeferred();
            }
            const frame = try @call(.always_inline, readFrame, .{self});
            // RSV1 marks a compressed message on its first frame only.
            if (frame.rsv1 and (frame.opcode != .text and frame.opcode != .binary)) return Error.ReservedFlags;

            switch (frame.opcode) {
                .ping => {
                    // Auto-respond with pong, in the batch when the next
                    // frame is here already.
                    const after: Flush = if (self.autoflush and bufferedFrame(self.transport.reader.buffered()) != null) .batch else .now;
                    try self.writeFrame(.pong, frame.payload, true, after);
                    self.auto_responded = true;
                    continue;
                },
                .pong => {
                    // Ignore pong frames
                    continue;
                },
                .close => {
                    // A code is two bytes; one byte is neither a code nor
                    // nothing.
                    if (frame.payload.len == 1) return Error.InvalidClosePayload;
                    var close_code: ?CloseCode = null;
                    var reason: []const u8 = "";
                    if (frame.payload.len >= 2) {
                        const code = std.mem.readInt(u16, frame.payload[0..2], .big);
                        close_code = @fromBackingInt(@intCast(code));
                        reason = frame.payload[2..];
                    }
                    // Echo the close, unless the peer's code is one that
                    // must not go on the wire; that is answered as the
                    // protocol error it is, with nothing of the peer's
                    // reason behind it.
                    const valid = if (close_code) |code| code.validOnTheWire() else true;
                    if (!valid) {
                        try self.writeClose(.protocol_error, "");
                    } else if (!std.unicode.utf8ValidateSlice(reason)) {
                        // A reason is text, and this one is not.
                        try self.writeClose(.invalid_payload, "");
                        self.auto_responded = true;
                        return Error.InvalidUtf8;
                    } else {
                        try self.writeClose(close_code orelse .normal, reason);
                    }
                    self.auto_responded = true;
                    return .{ .type = .close, .data = reason, .close_code = close_code };
                },
                .continuation => {
                    if (self.fragmented_type == null) {
                        return Error.UnexpectedContinuation;
                    }
                    if (self.fragmented_data.items.len + frame.payload.len > self.max_message_size) {
                        return Error.MessageTooLarge;
                    }
                    try self.fragmented_data.appendSlice(self.msg_arena.allocator(), frame.payload);
                    if (frame.fin) {
                        const msg_type = self.fragmented_type.?;
                        const data = try self.fragmented_data.toOwnedSlice(self.msg_arena.allocator());
                        self.fragmented_type = null;
                        const compressed = self.fragmented_compressed;
                        if (!compressed and msg_type == .text and !std.unicode.utf8ValidateSlice(data)) {
                            return Error.InvalidUtf8;
                        }
                        return .{ .type = msg_type, .data = data, .compressed = compressed };
                    }
                },
                .text, .binary => {
                    // A message may not begin while another is still in
                    // pieces, whether or not the new one is whole.
                    if (self.fragmented_type != null) {
                        return Error.NestedFragment;
                    }
                    if (frame.fin) {
                        // Complete message in single frame
                        if (!frame.rsv1 and frame.opcode == .text and !std.unicode.utf8ValidateSlice(frame.payload)) {
                            return Error.InvalidUtf8;
                        }
                        return .{ .type = frame.opcode, .data = frame.payload, .compressed = frame.rsv1 };
                    } else {
                        // Start of fragmented message
                        if (frame.payload.len > self.max_message_size) {
                            return Error.MessageTooLarge;
                        }
                        self.fragmented_type = frame.opcode;
                        self.fragmented_compressed = frame.rsv1;
                        self.fragmented_data.clearRetainingCapacity();
                        try self.fragmented_data.appendSlice(self.msg_arena.allocator(), frame.payload);
                    }
                },
                _ => return Error.InvalidOpcode,
            }
        }
    }

    /// Send a text or binary message
    pub fn send(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        try self.writeSent(msg_type, data);
    }

    /// `writeFrame` for `send` and `ping`, with `sendFlush` decided under
    /// the write lock.
    fn writeSent(self: *WebSocket, opcode: MessageType, data: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameLocked(opcode, data, true, self.sendFlush(data.len)));
    }

    /// The biggest payload a batch holds back; a bigger frame goes out at
    /// once, so a socket never holds a big message in its buffer, or a
    /// task to flush it, waiting for the batch.
    const batch_payload_max = 4 * 1024;

    /// When a frame of `len` payload bytes that `send` writes leaves: with
    /// `autoflush` off, when the caller says; in a batch the calling task
    /// reads, with the batch, unless it is big or would not fit in the
    /// write buffer; otherwise now. Under the write lock.
    fn sendFlush(self: *WebSocket, len: usize) Flush {
        if (!self.autoflush) return .manual;
        if (len > batch_payload_max) return .now;
        // A borrowed buffer (none now) has room for one.
        const w = self.transport.writer;
        if (w.buffer.len != 0 and w.end + len + 14 > w.buffer.len) return .now;
        if (self.batch.holds(self.io)) return .batch;
        // Any other task, a reader in the middle of a batch of its own
        // included (a relay): now (#85, see `Batch`).
        return .now;
    }

    /// Like `send`, but the frame stays in the write buffer: the caller
    /// follows a run of them with one `flush`. For a task that sends many
    /// messages to this socket in a row (a broadcast, the C ABI's sender).
    pub fn sendNoFlush(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameRsv(msg_type, data, true, .manual, 0));
    }

    /// `sendNoFlush` for a message the negotiated extension compressed
    /// (`sendCompressed`).
    pub fn sendCompressedNoFlush(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        if (!self.rsv1_allowed) return Error.ReservedFlags;
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameRsv(msg_type, data, true, .manual, 0x40));
    }

    /// Sends `data`, already compressed by the negotiated extension, as one
    /// message with RSV1 set. Needs `rsv1_allowed`.
    pub fn sendCompressed(self: *WebSocket, msg_type: MessageType, data: []const u8) !void {
        if (msg_type != .text and msg_type != .binary) return Error.InvalidOpcode;
        if (!self.rsv1_allowed) return Error.ReservedFlags;
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameRsv(msg_type, data, true, self.sendFlush(data.len), 0x40));
    }

    /// Send a ping frame
    pub fn ping(self: *WebSocket, data: []const u8) !void {
        if (data.len > 125) return Error.LargeControlFrame;
        try self.writeSent(.ping, data);
    }

    /// Write out whatever is left in the write buffer. Safe to call from
    /// any task. A failure means the connection is unusable, not that a
    /// particular message was lost.
    pub fn flush(self: *WebSocket) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        errdefer self.closed = true;
        self.batch.flushing();
        try self.resolveWrite(self.transport.writer.flush());
        self.giveBackWriteBuffer();
    }

    /// Writes out what a batch held, if anything still holds it.
    fn flushDeferred(self: *WebSocket) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (!self.batch.deferred.load(.monotonic) or self.closed) return;
        errdefer self.closed = true;
        self.batch.flushing();
        try self.resolveWrite(self.transport.writer.flush());
        self.giveBackWriteBuffer();
    }

    /// Borrows a buffer for the writer from the connection, when it lends
    /// them (`Transport.write_buffers`) and the writer has none: the frames
    /// about to be sent are built in it. Under `write_mutex`.
    fn borrowWriteBuffer(self: *WebSocket) void {
        const lender = self.transport.write_buffers orelse return;
        lender.take(lender.context);
    }

    /// Gives a borrowed write buffer back once a flush left nothing in it,
    /// so a quiet socket holds none. Under `write_mutex`.
    fn giveBackWriteBuffer(self: *WebSocket) void {
        const lender = self.transport.write_buffers orelse return;
        lender.give(lender.context);
    }

    /// Writes out what a batch held, now: before the reading task waits
    /// for the peer some way other than through `receive`, which does this
    /// itself.
    pub fn flushBatch(self: *WebSocket) !void {
        return self.flushDeferred();
    }

    /// Whether the reading task holds nothing of the socket's: no byte of
    /// the next frame is buffered and no message is half assembled. Where it
    /// can stop reading (`detachBuffers`) until the peer sends again.
    pub fn atRest(self: *const WebSocket) bool {
        return self.fragmented_type == null and self.transport.reader.bufferedLen() == 0;
    }

    /// For a socket that waits with no task reading it (a parked
    /// connection): its batch's flusher task ends, anything left in the
    /// write buffer goes out, and the reader and the writer give up their
    /// buffers, so frames other tasks send meanwhile go out through a
    /// borrowed buffer (`Transport.write_buffers`), or unbuffered, one write
    /// each. The messages' memory goes back. By the reading task, at rest
    /// (`atRest`), with what a batch held flushed (`flushBatch`);
    /// `attachBuffers` undoes it.
    pub fn detachBuffers(self: *WebSocket) void {
        self.dropBuffers(false);
    }

    /// `detachBuffers` as the socket closes, from the reading side: sending
    /// is over too, so frames from other tasks fail (`error.EndOfStream`)
    /// without touching the connection.
    pub fn shut(self: *WebSocket) void {
        self.dropBuffers(true);
    }

    fn dropBuffers(self: *WebSocket, close_sending: bool) void {
        self.batch.stopFlusher(self.io);
        {
            self.write_mutex.lockUncancelable(self.io);
            defer self.write_mutex.unlock(self.io);
            const w = self.transport.writer;
            if (w.end != 0 and !self.closed) {
                self.batch.flushing();
                w.flush() catch {
                    self.closed = true;
                };
            }
            // A borrowed one back to the connection; what a failed flush
            // left in it, the connection takes back as it closes.
            self.giveBackWriteBuffer();
            if (w.end == 0) w.buffer = &.{};
            if (close_sending) self.closed = true;
        }
        const r = self.transport.reader;
        r.buffer = &.{};
        r.seek = 0;
        r.end = 0;
        self.fragmented_data = .empty;
        self.fragmented_type = null;
        _ = self.msg_arena.reset(.free_all);
    }

    /// The reader takes `read` as its buffer: a task reads the socket again
    /// after `detachBuffers`. It must outlive the reading until the next
    /// `detachBuffers` or `shut`. The writer borrows a buffer from the
    /// connection as it sends (`Transport.write_buffers`).
    pub fn attachBuffers(self: *WebSocket, read: []u8) void {
        const r = self.transport.reader;
        std.debug.assert(r.bufferedLen() == 0);
        r.buffer = read;
        r.seek = 0;
        r.end = 0;
    }

    /// The batch's flush, for its backstop (`Batch.hold`).
    fn flushHeld(batch: *Batch) std.Io.Cancelable!void {
        const self: *WebSocket = @alignCast(@fieldParentPtr("batch", batch));
        self.flushDeferred() catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The reader learns of it when its own read or write fails.
            else => {},
        };
    }

    /// Send close frame and mark connection as closed. Does nothing if a close
    /// frame has already been sent.
    pub fn close(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        return self.writeClose(code, reason);
    }

    const Frame = struct {
        fin: bool,
        /// Only with `rsv1_allowed`; refused otherwise.
        rsv1: bool = false,
        opcode: MessageType,
        payload: []const u8,
    };

    fn readFrame(self: *WebSocket) !Frame {
        // Read first 2 bytes (header)
        var header: [2]u8 = undefined;
        try self.transport.reader.readSliceAll(&header);

        const fin = (header[0] & 0x80) != 0;
        // RSV2 and RSV3 must be 0, and RSV1 too unless an extension claimed it.
        const allowed: u8 = if (self.rsv1_allowed) 0x40 else 0;
        if (header[0] & 0x70 & ~allowed != 0) {
            return Error.ReservedFlags;
        }
        const rsv1 = header[0] & 0x40 != 0;
        const opcode: MessageType = @fromBackingInt(@intCast(@as(u4, @truncate(header[0] & 0x0F))));
        const masked = (header[1] & 0x80) != 0;

        // RFC 6455 §5.1: server MUST close on unmasked frame from client;
        // client MUST close on masked frame from server.
        if (!self.is_client and !masked) return Error.UnmaskedClientFrame;
        if (self.is_client and masked) return Error.MaskedServerFrame;

        var payload_len: u64 = header[1] & 0x7F;

        // Control frames (close, ping, pong) must have payload <= 125 bytes
        const is_control = switch (opcode) {
            .close, .ping, .pong => true,
            else => false,
        };
        if (is_control and payload_len > 125) {
            return Error.LargeControlFrame;
        }
        if (is_control and !fin) {
            return Error.FragmentedControlFrame;
        }

        // Extended payload length
        if (payload_len == 126) {
            var len_buf: [2]u8 = undefined;
            try self.transport.reader.readSliceAll(&len_buf);
            payload_len = std.mem.readInt(u16, &len_buf, .big);
        } else if (payload_len == 127) {
            var len_buf: [8]u8 = undefined;
            try self.transport.reader.readSliceAll(&len_buf);
            payload_len = std.mem.readInt(u64, &len_buf, .big);
        }

        // Read masking key if present (client -> server messages are masked)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.transport.reader.readSliceAll(&mask_key);
        }

        // Read payload
        if (payload_len > self.max_message_size) {
            return Error.MessageTooLarge;
        }
        // A control frame's payload (at most 125 bytes, checked above) goes
        // in the socket's own buffer, so control frames between a message's
        // pieces take no memory of the message's.
        const payload = if (is_control)
            self.control_payload[0..@intCast(payload_len)]
        else
            try self.msg_arena.allocator().alloc(u8, @intCast(payload_len));
        try self.transport.reader.readSliceAll(payload);

        if (masked) applyMask(payload, mask_key);

        return .{
            .fin = fin,
            .rsv1 = rsv1,
            .opcode = opcode,
            .payload = payload,
        };
    }

    /// Turns the sentinel a `std.Io.Writer` reports into the cause the
    /// transport recorded. Every frame leaves through here.
    fn resolveWrite(self: *WebSocket, result: std.Io.Writer.Error!void) !void {
        result catch |err| switch (err) {
            error.WriteFailed => return self.transport.getWriteError() orelse error.Unexpected,
        };
    }

    /// What happens to the write buffer after a frame.
    const Flush = enum {
        /// Out now, with whatever else the buffer held.
        now,
        /// Held for the reading task's batch (`Batch`).
        batch,
        /// Left for `flush` (`autoflush` off).
        manual,
    };

    fn writeFrame(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool, after: Flush) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.EndOfStream;
        return self.resolveWrite(self.writeFrameLocked(opcode, data, fin, after));
    }

    fn writeFrameLocked(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool, after: Flush) std.Io.Writer.Error!void {
        return self.writeFrameRsv(opcode, data, fin, after, 0);
    }

    fn writeFrameRsv(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool, after: Flush, rsv: u8) std.Io.Writer.Error!void {
        // A half-written frame leaves the peer unable to find the next frame
        // boundary.
        errdefer self.closed = true;

        // No buffer to build the frame in. A small one that goes out now
        // is built on the stack, so the socket holds no buffer across the
        // write (which parks the task, even one that completes at once);
        // otherwise one is borrowed from the connection while there is
        // something to send, or, without one, there is no buffer at all.
        if (self.transport.writer.buffer.len == 0 and !self.is_client) {
            if (after == .now and data.len <= unbuffered_payload_max) return self.writeUnbuffered(opcode, data, fin, rsv);
            self.borrowWriteBuffer();
            if (self.transport.writer.buffer.len == 0) return self.writeUnbuffered(opcode, data, fin, rsv);
        }

        // First byte: FIN + RSV + opcode
        const byte0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | rsv | @backingInt(opcode);
        try self.transport.writer.writeByte(byte0);

        // Second byte: mask bit + payload length
        const mask_bit: u8 = if (self.is_client) 0x80 else 0x00;
        if (data.len < 126) {
            try self.transport.writer.writeByte(mask_bit | @as(u8, @intCast(data.len)));
        } else if (data.len <= 65535) {
            try self.transport.writer.writeByte(mask_bit | 126);
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(data.len), .big);
            try self.transport.writer.writeAll(&len_buf);
        } else {
            try self.transport.writer.writeByte(mask_bit | 127);
            var len_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &len_buf, @intCast(data.len), .big);
            try self.transport.writer.writeAll(&len_buf);
        }

        if (self.is_client) {
            // Client frames must be masked (RFC 6455)
            var mask_key: [4]u8 = undefined;
            self.prng.random().bytes(&mask_key);
            try self.transport.writer.writeAll(&mask_key);

            // XOR payload with mask key, a stack chunk at a time.
            var chunk: [512]u8 = undefined;
            var rest = data;
            while (rest.len > 0) {
                const n = @min(rest.len, chunk.len);
                @memcpy(chunk[0..n], rest[0..n]);
                applyMask(chunk[0..n], mask_key);
                try self.transport.writer.writeAll(chunk[0..n]);
                rest = rest[n..];
            }
        } else {
            try self.transport.writer.writeAll(data);
        }
        switch (after) {
            .now => {
                self.batch.flushing();
                try self.transport.writer.flush();
                self.giveBackWriteBuffer();
            },
            .batch => if (!self.batch.hold(self.io, flushHeld)) {
                // No backstop to be had: out now, as without a batch.
                self.batch.flushing();
                try self.transport.writer.flush();
                self.giveBackWriteBuffer();
            },
            .manual => {},
        }
    }

    /// The biggest payload `writeUnbuffered` builds its frame around on the
    /// stack, in one write; a bigger one goes out as a vectored write of
    /// the header and the payload, which a TLS layer may send as two
    /// records.
    const unbuffered_payload_max = 512;

    /// A server's frame through a writer with no buffer: one write for a
    /// small frame, built here, or the header and the payload in one
    /// vectored write. Out of line, so the scratch stays off the frames of
    /// the ordinary path.
    noinline fn writeUnbuffered(self: *WebSocket, opcode: MessageType, data: []const u8, fin: bool, rsv: u8) std.Io.Writer.Error!void {
        var frame: [unbuffered_payload_max + 10]u8 = undefined;
        frame[0] = (@as(u8, if (fin) 0x80 else 0x00)) | rsv | @backingInt(opcode);
        var head_len: usize = 2;
        if (data.len < 126) {
            frame[1] = @intCast(data.len);
        } else if (data.len <= 65535) {
            frame[1] = 126;
            std.mem.writeInt(u16, frame[2..4], @intCast(data.len), .big);
            head_len = 4;
        } else {
            frame[1] = 127;
            std.mem.writeInt(u64, frame[2..10], @intCast(data.len), .big);
            head_len = 10;
        }
        const w = self.transport.writer;
        self.batch.flushing();
        if (head_len + data.len <= frame.len) {
            @memcpy(frame[head_len..][0..data.len], data);
            return w.writeAll(frame[0 .. head_len + data.len]);
        }
        var parts = [_][]const u8{ frame[0..head_len], data };
        return w.writeVecAll(&parts);
    }

    fn writeClose(self: *WebSocket, code: CloseCode, reason: []const u8) !void {
        try self.write_mutex.lock(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return;
        self.closed = true;

        var buf: [127]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], @backingInt(code), .big);
        const reason_len = @min(reason.len, 123);
        @memcpy(buf[2..][0..reason_len], reason[0..reason_len]);
        try self.resolveWrite(self.writeFrameLocked(.close, buf[0 .. 2 + reason_len], true, .now));
    }

    /// Whether `key` is a `Sec-WebSocket-Key` as RFC 6455 §4.1 has it: 16
    /// bytes in base64 (24 characters, padding included).
    pub fn validKey(key: []const u8) bool {
        if (key.len != 24) return false;
        var raw: [18]u8 = undefined;
        const len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
        if (len != 16) return false;
        std.base64.standard.Decoder.decode(raw[0..len], key) catch return false;
        return true;
    }

    /// Compute Sec-WebSocket-Accept value from client key
    pub fn computeAcceptKey(client_key: []const u8, out: *[28]u8) void {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(client_key);
        hasher.update(GUID);
        const hash = hasher.finalResult();
        _ = std.base64.standard.Encoder.encode(out, &hash);
    }
};

/// One write per read: the frames the reading task sends while the peer's
/// next message is already in the read buffer stay in the write buffer
/// until the batch ends, when they go out together. A peer that sends
/// sixteen messages before it reads the answers gets them in one write,
/// not sixteen.
///
/// A batch belongs to the task that reads: `round`, as `receive` returns a
/// message, starts or extends it when another whole message is buffered
/// behind it, and ends it when none is. What it holds goes out at the
/// latest
///   - with the first frame its task sends once the batch has ended (the
///     answer to the last buffered message takes the others along),
///   - before a read would wait for the peer,
///   - when another task sends or flushes, or the write buffer fills, or
///   - when the reading task waits for anything else (a database, a timer,
///     another lock): the backstop flushes then.
/// Sends from any other task (a broadcast, say) never wait for a batch,
/// and neither do the reading task's sends to other sockets (a relay,
/// a fan-out from its handler): a batch holds only the reading socket's
/// own frames. Holding a relay on the receiver's batch (0.2.1) coalesced
/// a burst's relays per receiver, but it left them waiting for the
/// receiver's next flush, which under load is a whole run-queue cycle or
/// more away (the receiver's own reader, the next large send to it, or
/// its backstop and then a flusher task), and it took away the write
/// that ended the relaying reader's turn (#85). Rooms and the C ABI
/// coalesce their own way (`sendNoFlush`, then one `flush`).
///
/// The backstop is one task per executor (`Backstop`), shared by every
/// socket on it, rather than one per socket: each batch, as it starts
/// holding frames, is queued for it and wakes it. On zio's pinned
/// executors it runs only once the reading tasks that woke it have stopped
/// running, and by then a reader waiting for the peer has flushed: the
/// batch is dropped from the queue, which costs a wakeup shared by every
/// socket that read meanwhile, not a write or a task per socket. A batch
/// that still holds frames (its reader waits for something else) gets the
/// socket's own flusher task, started then and ended once the batch holds
/// nothing more, so that one socket's slow peer or busy lock never holds
/// up the others' and an idle socket keeps no task. Off zio's executors
/// (`std.Io.Threaded`) each socket keeps that flusher from its first batch
/// and wakes it for every batch.
///
/// Shared with layers that frame WebSocket messages themselves (over
/// HTTP/2 and HTTP/3): the owner gives it a flush function and calls
/// `flushing` under its write lock as every flush starts.

pub const Batch = struct {
    /// The reading task (`placement.taskId`) while the batch lasts; 0
    /// when there is none.
    owner: std.atomic.Value(usize) = .init(0),
    /// Frames sit in the write buffer for the batch. Set by the reading
    /// task, cleared by whichever flush sends them, as it starts; both
    /// under the owner's write lock.
    deferred: std.atomic.Value(bool) = .init(false),
    /// The socket's own flusher: one task, started when a batch needs it
    /// and, on zio's executors, ended when it has nothing more to flush
    /// (`endIfIdle`); off them it stays, parked between batches on `wake`.
    flusher: std.Io.Group = .init,
    /// Set when a held batch needs the flusher; it waits on it.
    wake: placement.Signal = .{},
    /// The flusher task is running. Under the owner's write lock off zio's
    /// executors, under `home`'s lock on them.
    started: bool = false,
    /// Starts the flusher with the owner's flush function (`hold`).
    start_flusher: ?*const fn (*Batch, std.Io) std.Io.ConcurrentError!void = null,
    /// The executor backstop this batch is queued on, from its first batch
    /// on zio's executors.
    home: ?*Backstop = null,
    /// In `home`'s queue. Under its lock.
    node: std.DoublyLinkedList.Node = .{},
    queued: bool = false,
    /// Off only for tests that count writes, where a backstop on another
    /// thread (`std.Io.Threaded`) would flush at a moment of its choosing.
    backstop_on: bool = true,

    /// The reading task, as it hands a message on: `more` when another
    /// whole message (or a close) is already buffered behind it.
    pub fn round(self: *Batch, io: std.Io, more: bool) void {
        self.owner.store(if (more) placement.taskId(io) else 0, .monotonic);
    }

    /// No batch: a read failed, or the reader is done.
    pub fn endRound(self: *Batch) void {
        self.owner.store(0, .monotonic);
    }

    /// Whether a frame the calling task sends belongs to the batch.
    pub fn holds(self: *const Batch, io: std.Io) bool {
        const owner = self.owner.load(.monotonic);
        return owner != 0 and owner == placement.taskId(io);
    }

    /// Under the owner's write lock, with a frame left in the buffer for
    /// the batch. The first frame of a batch queues it for the backstop,
    /// which has `flushFn(self)` flush what the batch still holds once the
    /// reading task stops running. False when there is no backstop to be
    /// had: the caller flushes now.
    pub fn hold(self: *Batch, io: std.Io, comptime flushFn: fn (*Batch) std.Io.Cancelable!void) bool {
        if (self.deferred.load(.monotonic)) return true;
        self.deferred.store(true, .monotonic);
        if (!self.backstop_on) return true;
        self.start_flusher = Flusher(flushFn).start;
        if (placement.currentExecutor(io) != null) {
            if (Backstop.queue(self, io)) return true;
        } else if (self.started or self.startFlusher(io)) {
            self.wake.set(io);
            return true;
        }
        self.deferred.store(false, .monotonic);
        return false;
    }

    fn startFlusher(self: *Batch, io: std.Io) bool {
        self.start_flusher.?(self, io) catch return false;
        self.started = true;
        return true;
    }

    fn Flusher(comptime flushFn: fn (*Batch) std.Io.Cancelable!void) type {
        return struct {
            /// Under `home`'s lock on zio's executors (`Backstop.run`),
            /// under the owner's write lock off them (`hold`).
            fn start(batch: *Batch, io: std.Io) std.Io.ConcurrentError!void {
                return placement.concurrent(&batch.flusher, io, .local, run, .{ batch, batch.home, io });
            }

            fn run(batch: *Batch, home: ?*Backstop, io: std.Io) std.Io.Cancelable!void {
                while (true) {
                    try batch.wake.wait(io);
                    // Before the flush, so a batch that starts during it
                    // wakes this again.
                    batch.wake.reset(io);
                    try flushFn(batch);
                    if (home) |h| if (batch.endIfIdle(h, io)) return;
                }
            }
        };
    }

    /// The flusher, after a flush on zio's executors: it ends when the
    /// batch holds nothing more, so a socket keeps no task between
    /// batches; the backstop starts one again for the next batch that
    /// needs it. Under `home`'s lock, which the backstop holds to see
    /// `started` and wake the flusher, so a batch that started holding
    /// meanwhile (`deferred`, set before it queues) keeps this one running.
    fn endIfIdle(self: *Batch, home: *Backstop, io: std.Io) bool {
        home.mutex.lockUncancelable(io);
        defer home.mutex.unlock(io);
        if (self.deferred.load(.monotonic)) return false;
        self.started = false;
        return true;
    }

    /// Under the owner's write lock, as a flush starts: what the batch
    /// held goes out with it. Before the flush, not after: a write parks
    /// the task (on zio, even one that completes at once), and the
    /// backstop, running then, must not take the frames on their way out
    /// for frames still held.
    pub fn flushing(self: *Batch) void {
        self.deferred.store(false, .monotonic);
    }

    /// Ends the socket's flusher task, if it has one: for a socket that
    /// waits with no task reading it. With nothing held (`deferred` clear),
    /// so no backstop starts it again meanwhile; started again with the
    /// next batch that needs it.
    pub fn stopFlusher(self: *Batch, io: std.Io) void {
        if (!self.started) return;
        self.flusher.cancel(io);
        if (self.home) |home| {
            home.mutex.lockUncancelable(io);
            defer home.mutex.unlock(io);
            self.started = false;
        } else self.started = false;
    }

    /// Takes the batch off its executor's backstop and stops its flusher.
    /// Before the owner goes away.
    pub fn deinit(self: *Batch, io: std.Io) void {
        if (self.home) |home| home.leave(self, io);
        self.flusher.cancel(io);
    }
};

/// One executor's backstop (`Batch`): the batches that started holding
/// frames since it last ran, and the task that looks at them once their
/// readers have stopped running. One per thread, which on zio's pinned
/// executors is one per executor; started with the first batch that holds
/// frames there, and ended (`leave`) when the last socket queued on it
/// goes away, so no task outlives the sockets.
///
/// A socket's reading task, its owner and this task share the executor,
/// so the lock is never contended there; it is for a socket whose reading
/// task the handler started elsewhere. Lock order: an owner's write lock,
/// then this one; nothing under this lock takes a write lock or waits.
const Backstop = struct {
    mutex: std.Io.Mutex = .init,
    /// Batches to look at, each queued once (`Batch.queued`).
    pending: std.DoublyLinkedList = .{},
    /// Batches that have queued here and not left.
    live: usize = 0,
    task: std.Io.Group = .init,
    wake: placement.Signal = .{},
    running: bool = false,
    /// `leave` is waiting for the task to end: nothing joins meanwhile.
    stopping: bool = false,

    threadlocal var local: Backstop = .{};

    /// Queues `batch` on the calling task's executor, or on the one it
    /// joined: false when there is no backstop to be had.
    fn queue(batch: *Batch, io: std.Io) bool {
        const self = batch.home orelse &local;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (batch.home == null) {
            if (self.stopping) return false;
            if (!self.running) {
                placement.concurrent(&self.task, io, .local, run, .{ self, io }) catch return false;
                self.running = true;
            }
            self.live += 1;
            batch.home = self;
        }
        if (!batch.queued) {
            self.pending.append(&batch.node);
            batch.queued = true;
            self.wake.set(io);
        }
        return true;
    }

    fn run(self: *Backstop, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            try self.wake.wait(io);
            self.wake.reset(io);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.pending.popFirst()) |node| {
                const batch: *Batch = @fieldParentPtr("node", node);
                batch.queued = false;
                // Flushed by its reader, as it went to read: the usual case.
                if (!batch.deferred.load(.monotonic)) continue;
                if (batch.started or batch.startFlusher(io)) {
                    batch.wake.set(io);
                } else {
                    // No task for it: what it holds goes out with its
                    // reader's next send or read.
                    log.debug("No task to flush a WebSocket batch", .{});
                }
            }
        }
    }

    fn leave(self: *Backstop, batch: *Batch, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (batch.queued) {
            self.pending.remove(&batch.node);
            batch.queued = false;
        }
        batch.home = null;
        self.live -= 1;
        const last = self.live == 0;
        if (last) self.stopping = true;
        self.mutex.unlock(io);
        if (!last) return;
        // Waits for the task to end; a batch that starts meanwhile flushes
        // at once (`queue`).
        self.task.cancel(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.running = false;
        self.stopping = false;
    }
};

/// XORs `payload` with the 4-byte mask `key` (RFC 6455 §5.3), from the
/// key's first byte: a vector at a time, the tail a word and then a byte
/// at a time. About ten times the byte loop's speed from 64 bytes up.
pub fn applyMask(payload: []u8, key: [4]u8) void {
    const n = comptime @max(16, std.simd.suggestVectorLength(u8) orelse 16);
    comptime std.debug.assert(n % 4 == 0);
    const V = @Vector(n, u8);
    var i: usize = 0;
    if (payload.len >= n) {
        const mask: V = @bitCast(@as(@Vector(n / 4, u32), @splat(@bitCast(key))));
        while (payload.len - i >= n) : (i += n) {
            const chunk: *[n]u8 = payload[i..][0..n];
            chunk.* = @as(V, chunk.*) ^ mask;
        }
    }
    // Then a word at a time, which also keeps a short message quick.
    const word: u32 = @bitCast(key);
    while (payload.len - i >= 4) : (i += 4) {
        const w: *align(1) u32 = @ptrCast(payload[i..][0..4]);
        w.* ^= word;
    }
    while (i < payload.len) : (i += 1) payload[i] ^= key[i % 4];
}

// Tests
test "WebSocket: computeAcceptKey" {
    // Test vector from RFC 6455
    var accept: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "WebSocket: writeFrame text" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    try ws.writeFrame(.text, "Hello", true, .now);

    const written = conn_writer.buffered();
    // FIN + text opcode
    try std.testing.expectEqual(0x81, written[0]);
    // Length = 5
    try std.testing.expectEqual(5, written[1]);
    // Payload
    try std.testing.expectEqualStrings("Hello", written[2..7]);
}

test "WebSocket: writeFrame binary with medium length" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();

    const payload = &@as([200]u8, @splat('x'));
    try ws.writeFrame(.binary, payload, true, .now);

    const written = conn_writer.buffered();
    // FIN + binary opcode
    try std.testing.expectEqual(0x82, written[0]);
    // Extended length indicator
    try std.testing.expectEqual(126, written[1]);
    // 2-byte length
    try std.testing.expectEqual(200, std.mem.readInt(u16, written[2..4], .big));
}

test "WebSocket: writeClose" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    try ws.writeClose(.normal, "goodbye");

    const written = conn_writer.buffered();
    // FIN + close opcode
    try std.testing.expectEqual(0x88, written[0]);
    // Length = 2 (code) + 7 (reason)
    try std.testing.expectEqual(9, written[1]);
    // Close code 1000
    try std.testing.expectEqual(1000, std.mem.readInt(u16, written[2..4], .big));
    // Reason
    try std.testing.expectEqualStrings("goodbye", written[4..11]);
}

test "WebSocket: readFrame unmasked (client mode)" {

    // A simple unmasked text frame with "Hi" — only valid server-to-client.
    const frame_data = [_]u8{
        0x81, // FIN + text
        0x02, // length = 2
        'H',
        'i',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: readFrame rejects unmasked client frame (server mode)" {
    const frame_data = [_]u8{ 0x81, 0x02, 'H', 'i' };
    var reader: std.Io.Reader = .fixed(&frame_data);
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    // is_client = false (default) — must reject unmasked input per RFC 6455 §5.1.
    try std.testing.expectError(WebSocket.Error.UnmaskedClientFrame, ws.readFrame());
}

test "WebSocket: readFrame rejects masked server frame (client mode)" {
    const frame_data = [_]u8{
        0x81, 0x82, // FIN + text, masked + length = 2
        0x12, 0x34, 0x56, 0x78, // mask key
        0x5A, 0x5D, // masked payload
    };
    var reader: std.Io.Reader = .fixed(&frame_data);
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try std.testing.expectError(WebSocket.Error.MaskedServerFrame, ws.readFrame());
}

test "WebSocket: readFrame masked" {

    // A masked text frame with "Hi"
    // Mask key: 0x12, 0x34, 0x56, 0x78
    // 'H' ^ 0x12 = 0x5A, 'i' ^ 0x34 = 0x5D
    const frame_data = [_]u8{
        0x81, // FIN + text
        0x82, // masked + length = 2
        0x12, 0x34, 0x56, 0x78, // mask key
        0x5A, 0x5D, // masked payload
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    const frame = try ws.readFrame();

    try std.testing.expect(frame.fin);
    try std.testing.expectEqual(.text, frame.opcode);
    try std.testing.expectEqualStrings("Hi", frame.payload);
}

test "WebSocket: receive handles ping automatically" {

    // Masked ping + masked text (client->server frames per RFC 6455).
    // Mask key: 0x00, 0x00, 0x00, 0x00 — payload bytes therefore equal plaintext.
    const frame_data = [_]u8{
        // Ping frame: FIN+ping, mask+len=4, mask key, masked payload
        0x89, 0x84, 0x00, 0x00, 0x00, 0x00, 'p', 'i', 'n', 'g',
        // Text frame: FIN+text, mask+len=5, mask key, masked payload
        0x81, 0x85, 0x00, 0x00, 0x00, 0x00, 'H', 'e', 'l', 'l',
        'o',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    const msg = try ws.receive();

    // Should skip ping and return text message
    try std.testing.expectEqual(.text, msg.type);
    try std.testing.expectEqualStrings("Hello", msg.data);

    // Check that pong was sent
    const written = conn_writer.buffered();
    try std.testing.expectEqual(0x8A, written[0]); // FIN + pong
    try std.testing.expectEqual(4, written[1]); // length
    try std.testing.expectEqualStrings("ping", written[2..6]);
}

/// A server-side socket fed `frames`, with what it writes in `out`.
fn serverSocketOver(frames: []const u8, reader: *std.Io.Reader, out: *std.Io.Writer) WebSocket {
    reader.* = .fixed(frames);
    return WebSocket.init(std.testing.io, .{ .writer = out, .reader = reader }, std.testing.allocator, 0);
}

test "WebSocket: a whole message in the middle of a fragmented one is a protocol error" {
    // Masked with a zero key, so the payload bytes are the plaintext.
    const frames = [_]u8{
        // Text, FIN clear: the first piece of a message.
        0x01, 0x82, 0x00, 0x00, 0x00, 0x00, 'h', 'i',
        // Text, FIN set: a whole new message before the first is done.
        0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 'n', 'o',
    };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    try std.testing.expectError(WebSocket.Error.NestedFragment, ws.receive());
}

test "WebSocket: a fragmented control frame is a protocol error" {
    // Ping with FIN clear.
    const frames = [_]u8{ 0x09, 0x80, 0x00, 0x00, 0x00, 0x00 };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    try std.testing.expectError(WebSocket.Error.FragmentedControlFrame, ws.receive());
}

test "WebSocket: a close frame with a one-byte payload is a protocol error" {
    const frames = [_]u8{ 0x88, 0x81, 0x00, 0x00, 0x00, 0x00, 0x03 };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    try std.testing.expectError(WebSocket.Error.InvalidClosePayload, ws.receive());
}

test "WebSocket: a close code that may not be sent is answered with 1002, not echoed" {
    // 1005: reserved for a close with no code, never for the wire. With a
    // reason behind it that is not even UTF-8.
    const frames = [_]u8{ 0x88, 0x83, 0x00, 0x00, 0x00, 0x00, 0x03, 0xED, 0xFF };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    const msg = try ws.receive();
    try std.testing.expectEqual(.close, msg.type);
    // What arrived is still reported as it was.
    try std.testing.expectEqual(1005, @backingInt(msg.close_code.?));
    // What went back is 1002, and none of the peer's reason.
    const written = out.buffered();
    try std.testing.expectEqual(0x88, written[0]);
    try std.testing.expectEqual(2, written[1]);
    try std.testing.expectEqual(1002, std.mem.readInt(u16, written[2..4], .big));
}

test "WebSocket: a close reason that is not UTF-8 is answered with 1007" {
    // 1000 with a reason of one stray continuation byte.
    const frames = [_]u8{ 0x88, 0x83, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8, 0x80 };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    try std.testing.expectError(WebSocket.Error.InvalidUtf8, ws.receive());
    const written = out.buffered();
    try std.testing.expectEqual(0x88, written[0]);
    try std.testing.expectEqual(2, written[1]);
    try std.testing.expectEqual(1007, std.mem.readInt(u16, written[2..4], .big));
}

/// What a server socket fed `frames` fails with, and the close code it
/// sends first.
fn expectFailureClose(frames: []const u8, max_message_size: usize, expected: anyerror, code: u16) !void {
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(frames, &reader, &out);
    defer ws.deinit();
    ws.max_message_size = max_message_size;

    try std.testing.expectError(expected, ws.receive());
    const written = out.buffered();
    try std.testing.expectEqual(4, written.len);
    try std.testing.expectEqual(0x88, written[0]);
    try std.testing.expectEqual(2, written[1]);
    try std.testing.expectEqual(code, std.mem.readInt(u16, written[2..4], .big));
    // Sending is over.
    try std.testing.expectError(error.EndOfStream, ws.send(.text, "late"));
}

test "WebSocket: a failed receive sends the close code that says why" {
    // Masked with a zero key. A text message that is not UTF-8: 1007.
    try expectFailureClose(&.{ 0x81, 0x81, 0x00, 0x00, 0x00, 0x00, 0xFF }, 1024, WebSocket.Error.InvalidUtf8, 1007);
    // The same in two pieces, checked once whole.
    try expectFailureClose(&.{ 0x01, 0x81, 0x00, 0x00, 0x00, 0x00, 0xC3, 0x80, 0x81, 0x00, 0x00, 0x00, 0x00, 0xFF }, 1024, WebSocket.Error.InvalidUtf8, 1007);
    // One frame over `max_message_size`: 1009, before its payload is read.
    try expectFailureClose(&.{ 0x82, 0x84, 0x00, 0x00, 0x00, 0x00 }, 3, WebSocket.Error.MessageTooLarge, 1009);
    // Pieces that add up to more: 1009.
    try expectFailureClose(&.{ 0x02, 0x82, 0x00, 0x00, 0x00, 0x00, 1, 2, 0x80, 0x82, 0x00, 0x00, 0x00, 0x00, 3, 4 }, 3, WebSocket.Error.MessageTooLarge, 1009);
    // A protocol error (an unmasked client frame): 1002.
    try expectFailureClose(&.{ 0x81, 0x01, 'a' }, 1024, WebSocket.Error.UnmaskedClientFrame, 1002);
}

test "WebSocket: a receive that fails on the transport sends no close" {
    // Cut off inside a frame header.
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&.{0x81}, &reader, &out);
    defer ws.deinit();
    try std.testing.expect(std.meta.isError(ws.receive()));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "WebSocket: readFrame rejects RSV bits" {

    // Frame with RSV1 bit set (0x40)
    const frame_data = [_]u8{
        0xC1, // FIN + RSV1 + text opcode
        0x02,
        'H',
        'i',
    };
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    try std.testing.expectError(WebSocket.Error.ReservedFlags, ws.readFrame());
}

test "WebSocket: readFrame rejects large control frame" {

    // Ping frame with 126-byte payload (uses extended length).
    // Test the size limit independent of masking — use client mode so the
    // unmasked frame is otherwise valid.
    const frame_data = [_]u8{
        0x89, // FIN + ping
        126, // extended length indicator
        0x00, 0x7E, // 126 bytes
    } ++ @as([126]u8, @splat(0));
    var reader: std.Io.Reader = .fixed(&frame_data);

    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try std.testing.expectError(WebSocket.Error.LargeControlFrame, ws.readFrame());
}

test "WebSocket: writeFrame masked (client mode)" {
    var buf: [1024]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(std.testing.io, .{ .writer = &conn_writer, .reader = &reader }, std.testing.allocator, 0);
    defer ws.deinit();
    ws.is_client = true;
    try ws.writeFrame(.text, "Hello", true, .now);

    const written = conn_writer.buffered();
    // FIN + text opcode
    try std.testing.expectEqual(0x81, written[0]);
    // Mask bit set + length = 5
    try std.testing.expectEqual(0x85, written[1]);
    // Bytes 2-5 are the mask key
    const mask_key = written[2..6];
    // Bytes 6-10 are the masked payload
    const masked_payload = written[6..11];
    // Unmask and verify
    var unmasked: [5]u8 = undefined;
    for (&unmasked, 0..) |*byte, i| {
        byte.* = masked_payload[i] ^ mask_key[i % 4];
    }
    try std.testing.expectEqualStrings("Hello", &unmasked);
    // Total length: 1 (header) + 1 (len) + 4 (mask) + 5 (payload) = 11
    try std.testing.expectEqual(11, written.len);
}

/// Collects everything written, suspending on each drain so another task gets
/// a chance to write into the middle of a frame.
const InterleaveProbe = struct {
    interface: std.Io.Writer,
    io: std.Io,
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,
    buf: [8]u8 = undefined,

    fn init(gpa: std.mem.Allocator, io: std.Io) InterleaveProbe {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            .io = io,
            .gpa = gpa,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *InterleaveProbe = @alignCast(@fieldParentPtr("interface", w));
        self.io.sleep(.fromNanoseconds(1), .awake) catch {};
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.out.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.out.appendSlice(self.gpa, pattern) catch return error.WriteFailed;
            n += pattern.len;
        }
        return n;
    }
};

test "WebSocket: concurrent sends do not interleave within a frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var probe = InterleaveProbe.init(gpa, io);
    defer probe.out.deinit(gpa);
    var reader: std.Io.Reader = .fixed("");

    var ws = WebSocket.init(io, .{ .writer = &probe.interface, .reader = &reader }, gpa, 0);
    defer ws.deinit();

    const a = &@as([300]u8, @splat('a'));
    const b = &@as([300]u8, @splat('b'));

    var fa = try io.concurrent(struct {
        fn run(s: *WebSocket, payload: []const u8) !void {
            try s.send(.text, payload);
        }
    }.run, .{ &ws, a });
    var fb = try io.concurrent(struct {
        fn run(s: *WebSocket, payload: []const u8) !void {
            try s.send(.text, payload);
        }
    }.run, .{ &ws, b });
    try fa.await(io);
    try fb.await(io);

    // Each payload goes out in one write, so it stays contiguous even when
    // interleaved; only the header gets separated from it. Compare whole frames.
    const header = [_]u8{ 0x80 | @as(u8, @backingInt(WebSocket.MessageType.text)), 126, 0x01, 0x2C };
    const frame_a = header ++ a.*;
    const frame_b = header ++ b.*;
    const written = probe.out.items;
    const ab = frame_a ++ frame_b;
    const ba = frame_b ++ frame_a;
    if (!std.mem.eql(u8, written, &ab) and !std.mem.eql(u8, written, &ba)) {
        return error.FrameInterleaved;
    }
}

/// A buffered writer whose drained bytes, what reached the socket, land in `out`.
const SocketProbe = struct {
    interface: std.Io.Writer,
    out: std.ArrayListUnmanaged(u8) = .empty,
    gpa: std.mem.Allocator,
    /// How many writes reached the socket.
    writes: usize = 0,

    fn init(gpa: std.mem.Allocator, buffer: []u8) SocketProbe {
        return .{
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .gpa = gpa,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SocketProbe = @alignCast(@fieldParentPtr("interface", w));
        self.writes += 1;
        self.out.appendSlice(self.gpa, w.buffered()) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.out.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.out.appendSlice(self.gpa, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "WebSocket: autoflush off leaves frames in the buffer until flush or a pong" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);

    // Masked ping, then masked text; zero mask keys leave the payloads readable.
    const frames = [_]u8{
        0x89, 0x84, 0, 0, 0, 0, 'p', 'i', 'n', 'g',
        0x81, 0x82, 0, 0, 0, 0, 'h', 'i',
    };
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.autoflush = false;

    try ws.send(.text, "a");
    try ws.send(.text, "b");
    try std.testing.expectEqual(0, probe.out.items.len);
    try ws.flush();
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'a', 0x81, 1, 'b' }, probe.out.items);

    probe.out.clearRetainingCapacity();
    try ws.send(.text, "c");
    _ = try ws.receive();
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'c', 0x8A, 4, 'p', 'i', 'n', 'g' }, probe.out.items);
}

test "WebSocket: receiveMany returns the buffered messages and stops at a partial one" {
    // Masked frames with zero mask keys: "a", a ping, "b" + "c" in two
    // fragments, then the start of a frame whose payload has not arrived.
    const frames = [_]u8{ 0x81, 0x81, 0, 0, 0, 0, 'a' } ++
        [_]u8{ 0x89, 0x80, 0, 0, 0, 0 } ++
        [_]u8{ 0x01, 0x81, 0, 0, 0, 0, 'b' } ++
        [_]u8{ 0x80, 0x81, 0, 0, 0, 0, 'c' } ++
        [_]u8{ 0x81, 0x85, 0, 0 };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    const msgs = try ws.receiveMany();
    try std.testing.expectEqual(2, msgs.len);
    try std.testing.expectEqualStrings("a", msgs[0].data);
    try std.testing.expectEqualStrings("bc", msgs[1].data);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 0 }, out.buffered());

    try std.testing.expectError(error.EndOfStream, ws.receiveMany());
}

test "WebSocket: receiveMany leaves a close for the next batch" {
    // Masked frames with zero mask keys: "a", then a close with code 1000.
    const frames = [_]u8{ 0x81, 0x81, 0, 0, 0, 0, 'a' } ++
        [_]u8{ 0x88, 0x82, 0, 0, 0, 0, 0x03, 0xE8 };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    const msgs = try ws.receiveMany();
    try std.testing.expectEqual(1, msgs.len);
    try ws.send(.text, msgs[0].data);

    const close = try ws.receiveMany();
    try std.testing.expectEqual(1, close.len);
    try std.testing.expectEqual(.close, close[0].type);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'a', 0x88, 2, 0x03, 0xE8 }, out.buffered());
}

test "WebSocket: tryReceive returns null at a partial message and keeps the last one" {
    // Masked frames with zero mask keys: "a", then the first fragment of a
    // message whose last fragment has not arrived.
    const frames = [_]u8{ 0x81, 0x81, 0, 0, 0, 0, 'a' } ++
        [_]u8{ 0x01, 0x81, 0, 0, 0, 0, 'b' };
    var reader: std.Io.Reader = undefined;
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var ws = serverSocketOver(&frames, &reader, &out);
    defer ws.deinit();

    const msg = (try ws.tryReceive()).?;
    try std.testing.expectEqualStrings("a", msg.data);
    try std.testing.expectEqual(null, try ws.tryReceive());
    try std.testing.expectEqualStrings("a", msg.data);
}

test "WebSocket: send reports the real error, not error.WriteFailed" {
    // Too small to hold the frame, so the payload has nowhere to go.
    var buf: [4]u8 = undefined;
    var conn_writer: std.Io.Writer = .fixed(&buf);
    var reader: std.Io.Reader = .fixed("");

    // No socket, but something beneath the writer that recorded a cause --
    // which is all the transport is consulted for.
    var tcp_writer: std.Io.net.Stream.Writer = undefined;
    tcp_writer.err = error.ConnectionResetByPeer;

    var ws = WebSocket.init(std.testing.io, .{
        .writer = &conn_writer,
        .reader = &reader,
        .tcp_writer = &tcp_writer,
    }, std.testing.allocator, 0);
    defer ws.deinit();

    try std.testing.expectError(error.ConnectionResetByPeer, ws.send(.text, &@as([64]u8, @splat('x'))));
}

test "WebSocket: no std.Io sentinel escapes its public API" {
    // `ReadFailed`/`WriteFailed` say only that a read or write failed, which
    // the caller knew when it called. Neither may leave these.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        ErrorSetOf(WebSocket.send),
        ErrorSetOf(WebSocket.ping),
        ErrorSetOf(WebSocket.flush),
        ErrorSetOf(WebSocket.close),
        ErrorSetOf(WebSocket.receive),
        ErrorSetOf(WebSocket.receiveMany),
        ErrorSetOf(WebSocket.tryReceive),
    }) |Set| {
        inline for (comptime std.meta.fieldNames(Set)) |e_name| {
            try std.testing.expect(!std.mem.eql(u8, e_name, "WriteFailed"));
            try std.testing.expect(!std.mem.eql(u8, e_name, "ReadFailed"));
        }
    }
}

test "WebSocket: RSV1 is passed on as compressed once allowed, and only on a data message's first frame" {
    // A masked text frame with RSV1 (0xC1), then a ping with RSV1 (0xC9).
    const frames = [_]u8{ 0xC1, 0x82, 0, 0, 0, 0, 'h', 'i', 0xC9, 0x80, 0, 0, 0, 0 };
    var reader: std.Io.Reader = .fixed(&frames);
    var out: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    var ws = WebSocket.init(std.testing.io, .{ .reader = &reader, .writer = &writer }, std.testing.allocator, 1);
    defer ws.deinit();

    // Not negotiated: refused, with close 1002.
    try std.testing.expectError(WebSocket.Error.ReservedFlags, ws.receive());
    try std.testing.expectEqualSlices(u8, &.{ 0x88, 2, 0x03, 0xEA }, writer.buffered());

    reader = .fixed(&frames);
    writer = .fixed(&out);
    var ws2 = WebSocket.init(std.testing.io, .{ .reader = &reader, .writer = &writer }, std.testing.allocator, 1);
    defer ws2.deinit();
    ws2.rsv1_allowed = true;
    const msg = try ws2.receive();
    try std.testing.expect(msg.compressed);
    try std.testing.expectEqualStrings("hi", msg.data);
    try ws2.sendCompressed(.text, "x");
    try std.testing.expectEqual(@as(u8, 0xC1), out[0]);
    // RSV1 on a control frame is still an error.
    try std.testing.expectError(WebSocket.Error.ReservedFlags, ws2.receive());
}

/// A masked client frame (zero mask key, so the payload reads as is).
fn maskedFrame(comptime opcode: u8, comptime payload: []const u8) [6 + payload.len]u8 {
    return [_]u8{ 0x80 | opcode, 0x80 | @as(u8, payload.len), 0, 0, 0, 0 } ++ payload[0..payload.len].*;
}

test "WebSocket: messages read together are answered in one write" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b") ++ maskedFrame(0x1, "c");
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.batch.backstop_on = false;

    for (0..3) |i| {
        const msg = try ws.receive();
        try ws.send(.text, msg.data);
        // Held while the next message is here; the last answer takes all.
        try std.testing.expectEqual(@as(usize, if (i < 2) 0 else 1), probe.writes);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'a', 0x81, 1, 'b', 0x81, 1, 'c' }, probe.out.items);
    try std.testing.expectError(error.EndOfStream, ws.receive());
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
}

test "WebSocket: a message not all here ends the batch, and held answers go out before receive waits" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    // "a", "b", then half a frame.
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b") ++ [_]u8{ 0x81, 0x85, 0, 0 };
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.batch.backstop_on = false;

    _ = try ws.receive();
    try ws.send(.text, "A");
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    // "b" is the last whole message: its handler sends nothing, and the
    // next receive flushes "A" before it waits for the rest.
    _ = try ws.receive();
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    try std.testing.expectError(error.EndOfStream, ws.receive());
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'A' }, probe.out.items);
}

test "WebSocket: a send from another task is not held by the reader's batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b");
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.batch.backstop_on = false;

    _ = try ws.receive();
    try ws.send(.text, "A");
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    var other = try io.concurrent(struct {
        fn run(s: *WebSocket) !void {
            try s.send(.text, "X");
        }
    }.run, .{&ws});
    try other.await(io);
    // Out at once, and the held "A" with it, ahead of it.
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'A', 0x81, 1, 'X' }, probe.out.items);
}

test "WebSocket: a send to another socket leaves at once, also from a reader in the middle of its batch" {
    // #85: a relay from inside the reader's batch reaches the receiver now,
    // not with the receiver's next flush or its backstop.
    const gpa = std.testing.allocator;
    // The reading socket A: two messages buffered, so reading the first
    // starts a batch for this task.
    var a_buf: [256]u8 = undefined;
    var a_probe = SocketProbe.init(gpa, &a_buf);
    defer a_probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b");
    var reader: std.Io.Reader = undefined;
    var a = serverSocketOver(&frames, &reader, &a_probe.interface);
    defer a.deinit();
    a.batch.backstop_on = false;

    // The receiver B, a socket of its own with a write buffer.
    var b_buf: [256]u8 = undefined;
    var b_probe = SocketProbe.init(gpa, &b_buf);
    defer b_probe.out.deinit(gpa);
    var b_reader: std.Io.Reader = .fixed("");
    var b = WebSocket.init(std.testing.io, .{ .writer = &b_probe.interface, .reader = &b_reader }, gpa, 0);
    defer b.deinit();
    b.batch.backstop_on = false;

    // Outside a batch: one write per message.
    try b.send(.text, "1");
    try b.send(.text, "2");
    try std.testing.expectEqual(@as(usize, 2), b_probe.writes);

    // In A's batch (another whole message is buffered behind this one):
    // each relay to B is written as it is sent, and B holds nothing.
    _ = try a.receive();
    try std.testing.expect(a.batch.holds(std.testing.io));
    try b.send(.text, "x");
    try std.testing.expectEqual(@as(usize, 3), b_probe.writes);
    try b.send(.text, "y");
    try std.testing.expectEqual(@as(usize, 4), b_probe.writes);
    try std.testing.expect(!b.batch.deferred.load(.monotonic));
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, '1', 0x81, 1, '2', 0x81, 1, 'x', 0x81, 1, 'y' }, b_probe.out.items);
    // A's own answer still waits for A's batch.
    try a.send(.text, "A");
    try std.testing.expectEqual(@as(usize, 0), a_probe.writes);
    try std.testing.expect(a.batch.deferred.load(.monotonic));
}

test "WebSocket: in the reader's batch, a big answer, or one the buffer has no room for, leaves at once" {
    const gpa = std.testing.allocator;
    // Room for the frames below, with less than a 250-byte frame left
    // behind the first.
    var a_buf: [256]u8 = undefined;
    var a_probe = SocketProbe.init(gpa, &a_buf);
    defer a_probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b");
    var reader: std.Io.Reader = undefined;
    var a = serverSocketOver(&frames, &reader, &a_probe.interface);
    defer a.deinit();
    a.batch.backstop_on = false;

    // In the batch: a small answer waits for it.
    _ = try a.receive();
    try a.send(.text, "x");
    try std.testing.expectEqual(@as(usize, 0), a_probe.writes);
    // One that would not fit behind it goes now, the held one ahead of it.
    const mid: [250]u8 = @splat('m');
    try a.send(.binary, &mid);
    try std.testing.expect(a_probe.writes > 0);
    try std.testing.expectEqual(@as(usize, 3 + 4 + mid.len), a_probe.out.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'x' }, a_probe.out.items[0..3]);
    // A big one goes now whatever the buffer holds, and the socket keeps
    // nothing of it.
    const writes = a_probe.writes;
    const big: [5000]u8 = @splat('k');
    try a.send(.binary, &big);
    try std.testing.expect(a_probe.writes > writes);
    try std.testing.expectEqual(@as(usize, 0), a_probe.interface.end);
    try std.testing.expectEqual(@as(usize, 3 + 4 + mid.len + 4 + big.len), a_probe.out.items.len);
    try std.testing.expect(!a.batch.deferred.load(.monotonic));
}

test "WebSocket: sendNoFlush leaves frames for one flush, in order" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    var reader: std.Io.Reader = .fixed("");
    var ws = WebSocket.init(std.testing.io, .{ .writer = &probe.interface, .reader = &reader }, gpa, 0);
    defer ws.deinit();
    ws.batch.backstop_on = false;
    for (0..10) |_| try ws.sendNoFlush(.text, "m");
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    try ws.flush();
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqual(@as(usize, 30), probe.out.items.len);
}

test "WebSocket: a frame header with its payload still below the reader keeps the batch" {
    try std.testing.expect(WebSocket.bufferedHeader(&[_]u8{ 0x82, 0x7E, 0x10, 0x00, 0, 0, 0, 0 }));
    try std.testing.expect(!WebSocket.bufferedHeader(&[_]u8{ 0x82, 0x7E, 0x10 }));
    try std.testing.expect(!WebSocket.bufferedHeader(&[_]u8{0x82}));
    // A masked header needs its 4 key bytes too.
    try std.testing.expect(!WebSocket.bufferedHeader(&[_]u8{ 0x82, 0x85, 0, 0, 0 }));
    try std.testing.expect(WebSocket.bufferedHeader(&[_]u8{ 0x82, 0x85, 0, 0, 0, 0 }));
}

test "WebSocket: a pong in a batch keeps its place, and a close ends the batch" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    const frames = maskedFrame(0x9, "p") ++ maskedFrame(0x1, "a") ++ maskedFrame(0x8, &.{ 0x03, 0xE8 });
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.batch.backstop_on = false;

    const msg = try ws.receive();
    try std.testing.expectEqualStrings("a", msg.data);
    try ws.send(.text, msg.data);
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    const close = try ws.receive();
    try std.testing.expectEqual(.close, close.type);
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqualSlices(u8, &.{ 0x8A, 1, 'p', 0x81, 1, 'a', 0x88, 2, 0x03, 0xE8 }, probe.out.items);
}

test "WebSocket: what a batch holds goes out when the reader waits for something else" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b");
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();

    _ = try ws.receive();
    try ws.send(.text, "A");
    // The handler goes off to wait for something, "b" still unread: the
    // backstop sends "A" meanwhile (it writes under the write lock).
    const Sent = struct {
        ws: *WebSocket,
        probe: *SocketProbe,
        io: std.Io,
        fn written(c: @This()) !bool {
            try c.ws.write_mutex.lock(c.io);
            defer c.ws.write_mutex.unlock(c.io);
            return c.probe.writes != 0;
        }
    };
    try @import("anole_test_wait").waitUntil(io, "the backstop wrote the held frame", Sent{ .ws = &ws, .probe = &probe, .io = io }, Sent.written);
    try ws.write_mutex.lock(io);
    defer ws.write_mutex.unlock(io);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'A' }, probe.out.items);
}

test "applyMask: matches the byte-by-byte XOR at every length and through the tail" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var buf: [300]u8 = undefined;
    var expected: [300]u8 = undefined;
    for (0..buf.len) |len| {
        var key: [4]u8 = undefined;
        random.bytes(&key);
        random.bytes(buf[0..len]);
        for (buf[0..len], expected[0..len], 0..) |b, *e, i| e.* = b ^ key[i % 4];
        applyMask(buf[0..len], key);
        try std.testing.expectEqualSlices(u8, expected[0..len], buf[0..len]);
    }
}

test "WebSocket: a long payload masked by the client reads back on the server" {
    const gpa = std.testing.allocator;
    var payload: [1500]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var none: std.Io.Reader = .fixed("");
    var client = WebSocket.init(std.testing.io, .{ .writer = &w, .reader = &none }, gpa, 3);
    defer client.deinit();
    client.is_client = true;
    try client.send(.binary, &payload);

    var r: std.Io.Reader = .fixed(w.buffered());
    var out: [16]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out);
    var server = WebSocket.init(std.testing.io, .{ .writer = &ow, .reader = &r }, gpa, 4);
    defer server.deinit();
    const msg = try server.receive();
    try std.testing.expectEqualSlices(u8, &payload, msg.data);
}

test "WebSocket: the answers to what receiveMany returns leave in one write" {
    const gpa = std.testing.allocator;
    var wbuf: [256]u8 = undefined;
    var probe = SocketProbe.init(gpa, &wbuf);
    defer probe.out.deinit(gpa);
    const frames = maskedFrame(0x1, "a") ++ maskedFrame(0x1, "b") ++ maskedFrame(0x1, "c");
    var reader: std.Io.Reader = undefined;
    var ws = serverSocketOver(&frames, &reader, &probe.interface);
    defer ws.deinit();
    ws.batch.backstop_on = false;

    const msgs = try ws.receiveMany();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    for (msgs) |m| try ws.send(.text, m.data);
    try std.testing.expectEqual(@as(usize, 0), probe.writes);
    // Out before the next call waits for the peer.
    try std.testing.expectError(error.EndOfStream, ws.receiveMany());
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 1, 'a', 0x81, 1, 'b', 0x81, 1, 'c' }, probe.out.items);
}

/// A connection's reader, as a callback socket's run sees it: `data`
/// handed over through a buffer of its own (the run's window), `step`
/// bytes at a time.
const Trickle = struct {
    interface: std.Io.Reader,
    data: []const u8,
    pos: usize = 0,
    step: usize,

    fn init(data: []const u8, window: []u8, step: usize) Trickle {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = window, .seek = 0, .end = 0 },
            .data = data,
            .step = step,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos == self.data.len) return error.EndOfStream;
        const n = limit.minInt(@min(self.step, self.data.len - self.pos));
        const written = try w.write(self.data[self.pos..][0..n]);
        self.pos += written;
        return written;
    }
};

test "WebSocket: receiveStarted refuses a ping whose header claims more than a control frame may carry" {
    const gpa = std.testing.allocator;
    // A ping with a 16-bit length, and enough bytes behind it to fill the
    // reader's window, and with a 64-bit one.
    for ([_][]const u8{ &.{ 0x89, 0xFE, 0xFF, 0xFF }, &.{ 0x89, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0 } }) |head| {
        var input: [4096]u8 = @splat('x');
        @memcpy(input[0..head.len], head);
        @memset(input[head.len..][0..4], 0); // mask key
        var window: [2048]u8 = undefined;
        var trickle: Trickle = .init(&input, &window, 512);
        var out_buf: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        var ws = WebSocket.init(std.testing.io, .{ .writer = &out, .reader = &trickle.interface }, gpa, 0);
        defer ws.deinit();
        try trickle.interface.fillMore();
        try std.testing.expectError(WebSocket.Error.LargeControlFrame, ws.receiveStarted());
        // Told why: close 1002.
        try std.testing.expectEqualSlices(u8, &.{ 0x88, 2, 0x03, 0xEA }, out.buffered());
    }
}

test "WebSocket: receiveStarted refuses a fragmented ping before its payload" {
    const gpa = std.testing.allocator;
    const input = [_]u8{ 0x09, 0x80 | 100, 0, 0, 0, 0 } ++ @as([100]u8, @splat('p'));
    var window: [2048]u8 = undefined;
    var trickle: Trickle = .init(&input, &window, 2);
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var ws = WebSocket.init(std.testing.io, .{ .writer = &out, .reader = &trickle.interface }, gpa, 0);
    defer ws.deinit();
    try trickle.interface.fillMore();
    try std.testing.expectError(WebSocket.Error.FragmentedControlFrame, ws.receiveStarted());
}

test "WebSocket: receiveStarted with a window smaller than a ping still reads it" {
    const gpa = std.testing.allocator;
    const input = maskedFrame(0x9, "a ping of some length, longer than the window it is read through") ++ maskedFrame(0x1, "hi");
    var window: [16]u8 = undefined;
    var trickle: Trickle = .init(&input, &window, 16);
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var ws = WebSocket.init(std.testing.io, .{ .writer = &out, .reader = &trickle.interface }, gpa, 0);
    defer ws.deinit();
    try trickle.interface.fillMore();
    const msg = (try ws.receiveStarted()).?;
    try std.testing.expectEqualStrings("hi", msg.data);
    try std.testing.expectEqual(@as(u8, 0x8A), out.buffered()[0]);
}

test "WebSocket: control frames inside a message take no memory of their own" {
    const gpa = std.testing.allocator;
    const pong = maskedFrame(0xA, &@as([125]u8, @splat('p')));
    const count = 4000;
    const first = [_]u8{ 0x01, 0x81, 0, 0, 0, 0, 'a' };
    const last = [_]u8{ 0x80, 0x81, 0, 0, 0, 0, 'b' };
    const input = try gpa.alloc(u8, first.len + count * pong.len + last.len);
    defer gpa.free(input);
    @memcpy(input[0..first.len], &first);
    for (0..count) |i| @memcpy(input[first.len + i * pong.len ..][0..pong.len], &pong);
    @memcpy(input[input.len - last.len ..], &last);

    var reader: std.Io.Reader = .fixed(input);
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var ws = WebSocket.init(std.testing.io, .{ .writer = &out, .reader = &reader }, gpa, 0);
    defer ws.deinit();
    const msg = try ws.receive();
    try std.testing.expectEqualStrings("ab", msg.data);
    // 4000 pongs of 125 bytes are half a megabyte; the message is two bytes.
    try std.testing.expect(ws.msg_arena.queryCapacity() < 4096);
}

test "fuzz: a peer's frames, read as a callback socket and as a reading task do" {
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            const gpa = std.testing.allocator;
            // The first byte picks the window, the step, and which of the
            // two ways a message is read first.
            const how = input[0];
            const frames = input[1..];
            var window_buf: [2048]u8 = undefined;
            const window = window_buf[0..if (how & 1 != 0) window_buf.len else 64];
            var trickle: Trickle = .init(frames, window, @as(usize, how >> 2) + 1);
            var out_buf: [8192]u8 = undefined;
            var out: std.Io.Writer = .fixed(&out_buf);
            var ws = WebSocket.init(std.testing.io, .{ .writer = &out, .reader = &trickle.interface }, gpa, 0);
            defer ws.deinit();
            ws.max_message_size = 1024;
            ws.batch.backstop_on = false;
            var started = how & 2 != 0;
            var rounds: usize = 0;
            while (rounds < 64) : (rounds += 1) {
                const msg = if (started) blk: {
                    trickle.interface.fillMore() catch break;
                    break :blk (ws.receiveStarted() catch break) orelse continue;
                } else ws.receive() catch break;
                started = !started;
                try std.testing.expect(msg.data.len <= ws.max_message_size);
                try std.testing.expect(msg.type == .text or msg.type == .binary or msg.type == .close);
                if (msg.type == .close) break;
                // Control frames cost the message nothing.
                try std.testing.expect(ws.msg_arena.queryCapacity() <= 16 * 1024);
            }
        }
    }.check, &.{
        "\x03" ++ maskedFrame(0x9, "ping") ++ maskedFrame(0x1, "hello"),
        "\x01\x89\xfe\xff\xff\x00\x00\x00\x00" ++ @as([64]u8, @splat('x')),
        "\x02\x89\xff\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00",
        "\x07\x01\x81\x00\x00\x00\x00a" ++ maskedFrame(0xA, &@as([125]u8, @splat('p'))) ++ maskedFrame(0xA, "") ++ "\x80\x81\x00\x00\x00\x00b",
        "\x00\x09\x80\x00\x00\x00\x00",
        "\x05" ++ maskedFrame(0x8, "\x03\xe8bye"),
    });
}

test "WebSocket: validKey takes 16 bytes in base64 and nothing else" {
    try std.testing.expect(WebSocket.validKey("dGhlIHNhbXBsZSBub25jZQ=="));
    try std.testing.expect(!WebSocket.validKey(""));
    try std.testing.expect(!WebSocket.validKey("dGhlIHNhbXBsZSBub25jZQ"));
    try std.testing.expect(!WebSocket.validKey("dGhlIHNhbXBsZSBub25jZQ=")); // 23
    try std.testing.expect(!WebSocket.validKey("dGhlIHNhbXBsZSBub25j!!=="));
    try std.testing.expect(!WebSocket.validKey("dGhlIHNhbXBsZSBub25jZXM=")); // 17 bytes
}
