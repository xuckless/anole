//! WebSocket for handlers, over HTTP/1.1 (RFC 6455 upgrade) and HTTP/2
//! (RFC 8441 extended CONNECT), behind one `Socket`. The short form is a
//! route of its own (`Server.ws`, through `route`):
//!
//!     fn echo(ws: *anole.websocket.Socket, _: *anole.Request) !void {
//!         while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
//!     }
//!     app.ws("/echo", echo);
//!
//! and from any handler, `upgrade`:
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
//!
//! The HTTP/2 engine advertises extended CONNECT, and a browser that sees it
//! (Firefox does) opens WebSockets over HTTP/2: answer upgrades with
//! `upgrade` here, not dusty's HTTP/1.1-only `res.upgradeWebSocket`, or turn
//! `http2.enable_connect_protocol` off.
//!
//! permessage-deflate (RFC 7692) is accepted when offered and
//! `-Dcompression` is on (`UpgradeOptions.compression`), on either version.
//!
//! When the server starts to drain, every open socket is closed with 1001
//! (going away) unless `UpgradeOptions.close_on_drain` is off: the peer's
//! answer arrives through `receive` as a `.close` message, and
//! `Socket.draining` says why.
const std = @import("std");
const dusty = @import("dusty");
const placement = dusty.placement;
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
    /// The largest message `receive` assembles (after inflating). A bigger
    /// one fails `receive` with `error.MessageTooLarge`, and the peer gets
    /// close 1009 first.
    max_message_size: usize = WebSocket.default_max_message_size,
    /// Replaces the request's timeout once the socket is open: a socket
    /// outlives `timeout.request`. Set a deadline here, or call
    /// `req.setTimeout` before each `receive` for an idle limit.
    timeout: std.Io.Timeout = .none,
    /// Accept permessage-deflate (RFC 7692) when the client offers it.
    /// Needs `-Dcompression`.
    compression: bool = features.compression,
    deflate: DeflateOptions = .{},
    /// When the server starts to drain, send close 1001 (going away) with
    /// `drain_reason`, so the peer answers and `receive` returns its
    /// `.close`. Off: the socket stays open until the handler ends it
    /// (`Socket.draining` tells it to) or `timeout.shutdown` cuts it.
    close_on_drain: bool = true,
    drain_reason: []const u8 = "server shutting down",
};

pub const DeflateOptions = if (features.compression) deflate_impl.Options else struct {};
const deflate_impl = if (features.compression) @import("deflate.zig") else struct {
    pub const Deflate = void;
};

/// A WebSocket a handler holds, whichever HTTP version it arrived on.
pub const Socket = struct {
    conn: Conn,
    /// permessage-deflate, when negotiated.
    deflate: if (features.compression) ?*deflate_impl.Deflate else void =
        if (features.compression) null else {},
    allocator: std.mem.Allocator,
    io: std.Io,
    max_message_size: usize,
    /// Held across compressing and sending a message, so tasks sending on
    /// one socket (a `Rooms.broadcast` beside the socket's own handler) do
    /// not interleave on the compressor.
    send_mutex: std.Io.Mutex = .init,
    /// The server's drain signal (`Request.drain`); null in a request the
    /// server did not build.
    drain: ?*std.Io.Event = null,
    /// The task that sends 1001 when the drain starts
    /// (`UpgradeOptions.close_on_drain`).
    drain_watch: ?*std.Io.Group = null,
    /// A close went out through `close`, or came in through `receive` (and
    /// was answered), or `next` saw the connection end.
    closed: std.atomic.Value(bool) = .init(false),
    /// Why `next` returned null when it was not the peer's close: the
    /// error `receive` failed with.
    end_error: ?anyerror = null,

    /// Both live in the request's arena, so a task beside the handler (the
    /// drain watch, a `Rooms.broadcast`) acts on the same one.
    pub const Conn = union(enum) {
        h1: *WebSocket,
        h2: *H2Socket,
    };

    /// Whether the server has started to drain. With `close_on_drain` the
    /// close is already on its way; without, the handler should end the
    /// socket (close 1001, then `receive` until the answer) soon.
    pub fn draining(self: *const Socket) bool {
        const d = self.drain orelse return false;
        return d.isSet();
    }

    /// The next text, binary or close message. Pings are answered and
    /// pongs dropped on the way; a compressed message is inflated.
    pub fn receive(self: *Socket) !Message {
        var msg = switch (self.conn) {
            inline else => |ws| try ws.receive(),
        };
        if (msg.type == .close) self.closed.store(true, .release);
        if (!msg.compressed) return msg;
        if (comptime !features.compression) unreachable;
        const d = self.deflate orelse unreachable; // RSV1 is refused unless negotiated
        msg.data = d.decompress(self.allocator, msg.data, self.max_message_size) catch |err| {
            self.close(if (err == error.MessageTooLarge) .too_large else .invalid_payload, "") catch {};
            return err;
        };
        msg.compressed = false;
        if (msg.type == .text and !std.unicode.utf8ValidateSlice(msg.data)) {
            self.close(.invalid_payload, "") catch {};
            return error.InvalidUtf8;
        }
        return msg;
    }

    pub fn send(self: *Socket, msg_type: MessageType, data: []const u8) !void {
        try self.send_mutex.lock(self.io);
        defer self.send_mutex.unlock(self.io);
        if (comptime features.compression) {
            if (self.deflate) |d| if ((msg_type == .text or msg_type == .binary) and data.len >= d.options.min_length) {
                const packed_data = try d.compress(self.allocator, data);
                return switch (self.conn) {
                    .h1 => |ws| ws.sendCompressed(msg_type, packed_data),
                    .h2 => |ws| ws.sendMessage(msg_type, packed_data, true),
                };
            };
        }
        return switch (self.conn) {
            inline else => |ws| ws.send(msg_type, data),
        };
    }

    pub fn ping(self: *Socket, data: []const u8) !void {
        return switch (self.conn) {
            inline else => |ws| ws.ping(data),
        };
    }

    /// The next text or binary message, or null once the socket is done:
    /// the peer closed it (the close is answered) or the connection ended
    /// (`end_error` says how). Pings, pongs and inflating are handled on the
    /// way, as in `receive`. Fails only for what is not the peer's doing: a
    /// cancel (the server stopping) or no memory.
    ///
    ///     while (try ws.next()) |msg| try ws.send(msg.type, msg.data);
    pub fn next(self: *Socket) anyerror!?Message {
        while (true) {
            const msg = self.receive() catch |err| {
                const e: anyerror = err;
                if (e == error.Canceled or e == error.OutOfMemory) return e;
                self.end_error = e;
                self.closed.store(true, .release);
                return null;
            };
            switch (msg.type) {
                .text, .binary => return msg,
                .close => return null,
                else => {},
            }
        }
    }

    /// Sends a close frame. The peer's answer still arrives through
    /// `receive`.
    pub fn close(self: *Socket, code: CloseCode, reason: []const u8) !void {
        self.closed.store(true, .release);
        return switch (self.conn) {
            inline else => |ws| ws.close(code, reason),
        };
    }

    pub fn deinit(self: *Socket) void {
        // First, so nothing sends on the socket once it is gone.
        if (self.drain_watch) |g| g.cancel(self.io);
        if (comptime features.compression) if (self.deflate) |d| d.deinit(self.allocator);
        switch (self.conn) {
            inline else => |ws| ws.deinit(),
        }
    }

    /// Sends close 1001 once the drain starts. Runs beside the handler, on
    /// its executor, until `deinit` cancels it.
    fn closeOnDrain(drain: *std.Io.Event, io: std.Io, conn: Conn, reason: []const u8) std.Io.Cancelable!void {
        try drain.wait(io);
        switch (conn) {
            inline else => |ws| ws.close(.going_away, reason) catch {},
        }
    }
};

/// Accepts the WebSocket `req` asks for, on either HTTP version, and
/// answers the handshake. Null when `req` is not a WebSocket request (the
/// handler answers it as it sees fit). The socket lives as long as the
/// handler: the request's arena holds it.
pub fn upgrade(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions) !?Socket {
    const h2 = req.protocol != null;
    if (h2) {
        if (!features.http2 or !std.ascii.eqlIgnoreCase(req.protocol.?, "websocket")) return null;
        const version = req.headers.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;
    }

    // permessage-deflate: the first offer we can take, answered in the
    // handshake's response.
    var deflate: if (features.compression) ?*deflate_impl.Deflate else void = if (features.compression) null else {};
    if (comptime features.compression) if (options.compression) {
        if (req.headers.get("Sec-WebSocket-Extensions")) |offers| {
            var buf: [160]u8 = undefined;
            if (deflate_impl.negotiate(offers, options.deflate, &buf)) |accepted| {
                try res.header("Sec-WebSocket-Extensions", try req.arena.dupe(u8, accepted.response));
                const d = try req.arena.create(deflate_impl.Deflate);
                d.* = .init(accepted.config, options.deflate);
                deflate = d;
            }
        }
    };
    const negotiated = if (comptime features.compression) deflate != null else false;

    var socket: Socket = .{
        .conn = undefined,
        .deflate = deflate,
        .allocator = req.arena,
        .io = req.io,
        .max_message_size = options.max_message_size,
        .drain = req.drain,
    };
    if (h2) {
        socket.conn = .{ .h2 = try H2Socket.accept(req, res, options, negotiated) };
    } else {
        const ws = try req.arena.create(WebSocket);
        ws.* = (try res.upgradeWebSocket(req)) orelse return null;
        ws.max_message_size = options.max_message_size;
        ws.rsv1_allowed = negotiated;
        socket.conn = .{ .h1 = ws };
    }
    req.setTimeout(options.timeout);
    if (options.close_on_drain) if (req.drain) |drain| {
        const group = try req.arena.create(std.Io.Group);
        group.* = .init;
        const reason = try req.arena.dupe(u8, options.drain_reason);
        // Without a task to spare, the socket lives on until the handler
        // ends it or the drain's deadline does.
        if (placement.concurrent(group, req.io, .local, Socket.closeOnDrain, .{ drain, req.io, socket.conn, reason })) |_| {
            socket.drain_watch = group;
        } else |_| {}
    };
    return socket;
}

/// A route handler for `Server.ws`: upgrades, runs `handler` with the open
/// socket, and closes it when `handler` returns (1000, or 1011 when it
/// failed; nothing when the socket is already closed). A request that is
/// not a WebSocket handshake gets 426 Upgrade Required. `handler` is
/// `fn (*Socket) !void`, `fn (*Socket, *Request) !void`, or with the
/// server's state first, `fn (*Ctx, *Socket, *Request) !void`.
pub fn route(comptime Ctx: type, comptime handler: anytype, comptime options: UpgradeOptions) dusty.Router(Ctx).Handler {
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    switch (params.len) {
        1, 2 => {},
        3 => if (Ctx == void) @compileError("a WebSocket handler with three parameters takes the server's state first, but this server has none"),
        else => @compileError("a WebSocket handler takes (*anole.websocket.Socket) or (*anole.websocket.Socket, *anole.Request), got " ++ @typeName(@TypeOf(handler))),
    }
    const S = struct {
        fn serve(ctx: if (Ctx == void) void else *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            var ws = (try upgrade(req, res, options)) orelse {
                res.status = .upgrade_required;
                try res.header("Upgrade", "websocket");
                res.content_type = .text;
                res.body = "426 Upgrade Required: this endpoint speaks WebSocket\n";
                return;
            };
            defer ws.deinit();
            const result = switch (params.len) {
                1 => handler(&ws),
                2 => handler(&ws, req),
                3 => handler(ctx, &ws, req),
                else => unreachable,
            };
            result catch |err| {
                const e: anyerror = err;
                if (e == error.Canceled) return e;
                // The peer went away mid-send: not the handler's fault.
                if (res.peerGone()) return;
                std.log.scoped(.anole).warn("WebSocket handler for {s} failed: {t}", .{ req.url, e });
                if (!ws.closed.load(.acquire)) ws.close(.internal_error, "") catch {};
                return;
            };
            if (!ws.closed.load(.acquire)) ws.close(.normal, "") catch {};
        }
    };
    return if (Ctx == void) struct {
        fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return S.serve({}, req, res);
        }
    }.h else S.serve;
}

/// Named groups of sockets for publish/subscribe: a handler joins its
/// socket to rooms, and anything may broadcast to a room. Safe from any task
/// or thread of the runtime.
///
/// A broadcast takes a snapshot of the room's members under the lock and
/// sends outside it, so a slow member holds up only the broadcasts that
/// reach it, never another room's or a join or leave elsewhere. A member
/// that leaves waits for the sends to it that are under way, so a socket is
/// never sent to after its handler has left and returned. A member's send
/// failing is that member's affair: its own `receive` sees the connection
/// end.
pub const Rooms = struct {
    allocator: std.mem.Allocator,
    /// The runtime's `std.Io`, taken from the first socket to join, so
    /// `init` needs none (the rooms can be made before the server).
    io: std.Io = undefined,
    io_set: std.atomic.Value(bool) = .init(false),
    io_lock: std.atomic.Mutex = .unlocked,
    /// Over `rooms` and every member's `sends`; never held across I/O.
    mutex: std.Io.Mutex = .init,
    /// Signalled when a member that left has no sends left.
    idle: std.Io.Condition = .init,
    rooms: std.StringHashMapUnmanaged(std.ArrayList(*Member)) = .empty,

    const Member = struct {
        socket: *Socket,
        /// Broadcasts sending to this member right now.
        sends: u32 = 0,
        /// Out of its room, waiting for `sends` to reach zero.
        left: bool = false,
    };

    /// Members a broadcast snapshots on the stack; a bigger room borrows
    /// from the allocator.
    const stack_snapshot = 64;

    pub fn init(allocator: std.mem.Allocator) Rooms {
        return .{ .allocator = allocator };
    }

    /// The `std.Io` to lock with: `io` (a joining or leaving socket's)
    /// unless an earlier one was taken.
    fn bind(self: *Rooms, io: std.Io) std.Io {
        if (!self.io_set.load(.acquire)) {
            while (!self.io_lock.tryLock()) std.atomic.spinLoopHint();
            defer self.io_lock.unlock();
            if (!self.io_set.load(.monotonic)) {
                self.io = io;
                self.io_set.store(true, .release);
            }
        }
        return self.io;
    }

    /// Null until a socket has joined: until then every room is empty.
    fn bound(self: *Rooms) ?std.Io {
        return if (self.io_set.load(.acquire)) self.io else null;
    }

    pub fn deinit(self: *Rooms) void {
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |m| self.allocator.destroy(m);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rooms.deinit(self.allocator);
    }

    /// Adds `socket` to `room`. Leave before the socket goes away:
    /// `defer rooms.leave(room, &ws)`.
    pub fn join(self: *Rooms, room: []const u8, socket: *Socket) !void {
        const member = try self.allocator.create(Member);
        errdefer self.allocator.destroy(member);
        member.* = .{ .socket = socket };
        const io = self.bind(socket.io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = try self.rooms.getOrPut(self.allocator, room);
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, room) catch |err| {
                self.rooms.removeByPtr(entry.key_ptr);
                return err;
            };
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, member);
    }

    /// Takes `socket` out of `room`, once any broadcast sending to it has
    /// finished with it.
    pub fn leave(self: *Rooms, room: []const u8, socket: *Socket) void {
        const io = self.bind(socket.io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const members = self.rooms.getPtr(room) orelse return;
        const member = for (members.items, 0..) |m, i| {
            if (m.socket == socket) break members.swapRemove(i);
        } else return;
        if (members.items.len == 0) {
            const key = self.rooms.getKey(room).?;
            members.deinit(self.allocator);
            _ = self.rooms.remove(room);
            self.allocator.free(key);
        }
        member.left = true;
        while (member.sends > 0) self.idle.waitUncancelable(io, &self.mutex);
        self.allocator.destroy(member);
    }

    /// Sends one message to every member of `room` but `except`. Returns
    /// how many it reached. Members joining meanwhile are not sent to.
    pub fn broadcast(self: *Rooms, room: []const u8, msg_type: MessageType, data: []const u8, except: ?*Socket) usize {
        const io = self.bound() orelse return 0;
        var stack: [stack_snapshot]*Member = undefined;
        var heap: []*Member = &.{};
        defer self.allocator.free(heap);
        const snapshot = snap: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const members = (self.rooms.get(room) orelse return 0).items;
            const buf: []*Member = if (members.len <= stack.len) &stack else big: {
                heap = self.allocator.alloc(*Member, members.len) catch {
                    // No memory for a snapshot: send under the lock
                    // instead, which only makes this broadcast hold up the
                    // others.
                    return sendAll(members, msg_type, data, except);
                };
                break :big heap;
            };
            var n: usize = 0;
            for (members) |m| {
                if (m.socket == except) continue;
                m.sends += 1;
                buf[n] = m;
                n += 1;
            }
            break :snap buf[0..n];
        };
        var reached: usize = 0;
        for (snapshot) |m| {
            if (m.socket.send(msg_type, data)) |_| reached += 1 else |_| {}
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            m.sends -= 1;
            if (m.sends == 0 and m.left) self.idle.broadcast(io);
        }
        return reached;
    }

    fn sendAll(members: []const *Member, msg_type: MessageType, data: []const u8, except: ?*Socket) usize {
        var reached: usize = 0;
        for (members) |m| {
            if (m.socket == except) continue;
            m.socket.send(msg_type, data) catch continue;
            reached += 1;
        }
        return reached;
    }

    /// How many sockets are in `room`.
    pub fn count(self: *Rooms, room: []const u8) usize {
        const io = self.bound() orelse return 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return if (self.rooms.get(room)) |m| m.items.len else 0;
    }
};

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

    fn accept(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions, deflate: bool) !*H2Socket {
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
                // A compressed text message is checked once inflated.
                if (!end.compressed and msg_type == .text and !std.unicode.utf8ValidateSlice(self.message.items)) {
                    self.fail(.invalid_payload);
                    return error.InvalidUtf8;
                }
                return .{ .type = msg_type, .data = self.message.items, .compressed = end.compressed };
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
        try self.writeFrameOpts(.{ .opcode = opcode, .compressed = compressed }, data);
    }

    pub fn ping(self: *H2Socket, data: []const u8) !void {
        // As over HTTP/1.1; the codec asserts it rather than failing.
        if (data.len > codec.max_control_payload_len) return error.LargeControlFrame;
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
        return self.writeFrameOpts(.{ .opcode = opcode }, payload);
    }

    fn writeFrameOpts(self: *H2Socket, opts: codec.WriteFrameOptions, payload: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.closed) return error.ConnectionClosed;
        const w = &self.out.interface;
        codec.writeFrame(w, payload, opts) catch return self.out.err orelse error.WriteFailed;
        w.flush() catch return self.out.err orelse error.WriteFailed;
    }
};

test {
    _ = @import("rooms_test.zig");
    _ = @import("h1_test.zig");
    _ = @import("h2_fuzz_test.zig");
    if (features.http2) _ = @import("h2_test.zig");
    if (features.compression) _ = @import("deflate.zig");
}

test "WebSocket accept key matches RFC 6455 section 1.3" {
    var out: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
