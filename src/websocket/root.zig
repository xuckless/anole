//! WebSocket for handlers, over HTTP/1.1 (RFC 6455 upgrade), HTTP/2
//! (RFC 8441 extended CONNECT) and HTTP/3 (RFC 9220, the same over HTTP/3),
//! behind one `Socket`. The short form is a
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
//!         var ws = (try anole.websocket.upgrade(req, res, .{})) orelse
//!             return res.fail(.bad_request, "");
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
//! HTTP/1.1 runs on the HTTP core's RFC 6455 implementation (from
//! lalinsky/dusty, MIT). HTTP/2 and HTTP/3 run on the sans-IO frame codec
//! of xuckless/websocket-zig (a fork of mattrobenolt/websocket-zig, MIT)
//! over the stream's request body and streamed response; h2_socket.zig is
//! the message layer over it, with the same semantics: pings are answered
//! and pongs dropped inside `receive`, a close is echoed and returned, a
//! text message must be valid UTF-8.
//!
//! On every version, replies go out once per read: while the peer's next
//! message is already buffered, what the handler sends waits for the batch
//! to end (the answer to the last buffered message, a read that would
//! wait, or the handler waiting for anything else), so a client that
//! pipelines messages gets one write for them, not one each. Sends from
//! other tasks (`Rooms.broadcast`) go out at once. dusty's
//! `WebSocketBatch` has the rule.
//!
//! The HTTP/2 and HTTP/3 engines advertise extended CONNECT, and a browser
//! that sees it (Firefox does, over HTTP/2) opens WebSockets on it: answer
//! upgrades with `upgrade` here, not dusty's HTTP/1.1-only
//! `res.upgradeWebSocket`, or turn `http2.enable_connect_protocol` (and
//! `http3.enable_connect_protocol`) off.
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
/// The message layer over an HTTP/2 or HTTP/3 stream. Internal: its
/// `receive` hands over messages still compressed; `Socket` inflates.
const H2Socket = @import("h2_socket.zig").H2Socket;

/// The HTTP core's WebSocket over an HTTP/1.1 connection (`Socket.conn.h1`).
pub const WebSocket = dusty.WebSocket;
/// A message from `Socket.receive` or `Socket.next`: its `type`, its
/// `data`, and for a close its `close_code`. `data` is valid until the
/// next `receive` or `next`; copy what must outlive it.
pub const Message = WebSocket.Message;
/// `.text`, `.binary`, `.close`, `.ping` or `.pong` (and `.continuation`,
/// which `receive` never returns).
pub const MessageType = WebSocket.MessageType;
/// A close status code: `.normal` (1000), `.going_away` (1001),
/// `.policy_violation` (1008), `.too_large` (1009), `.internal_error`
/// (1011) and the rest of RFC 6455's; any other number fits too.
pub const CloseCode = WebSocket.CloseCode;
/// A client-side WebSocket, from
/// `anole.client(req).http.connectWebSocket(url, .{})` for a `ws://` or
/// `wss://` URL.
pub const Client = dusty.WebSocketClient;

/// How `upgrade` (and `app.wsWith`) accepts a socket. The defaults suit
/// most handlers: dusty's message limit, no timeout, compression when
/// built in, close 1001 on drain.
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
    /// The compressor's settings when permessage-deflate is in use.
    deflate: DeflateOptions = .{},
    /// When the server starts to drain, send close 1001 (going away) with
    /// `drain_reason`, so the peer answers and `receive` returns its
    /// `.close`. Off: the socket stays open until the handler ends it
    /// (`Socket.draining` tells it to) or `timeout.shutdown` cuts it.
    close_on_drain: bool = true,
    /// The reason sent with the drain's close 1001.
    drain_reason: []const u8 = "server shutting down",
};

/// permessage-deflate settings: window size, memory level, level, and the
/// shortest message worth compressing (64 bytes). Empty without
/// `-Dcompression`.
pub const DeflateOptions = if (features.compression) deflate_impl.Options else struct {};
const deflate_impl = if (features.compression) @import("deflate.zig") else struct {
    pub const Deflate = void;
};

/// A WebSocket a handler holds, whichever HTTP version it arrived on.
pub const Socket = struct {
    /// The protocol underneath, to tell which you got: `.h1` (the HTTP
    /// core's HTTP/1.1 WebSocket) or `.h2` (a stream of HTTP/2 or HTTP/3).
    /// Send and receive through `Socket`'s methods, not through it; see
    /// `Conn`.
    conn: Conn,
    /// permessage-deflate, when negotiated.
    deflate: if (features.compression) ?*deflate_impl.Deflate else void =
        if (features.compression) null else {},
    /// The request's arena.
    allocator: std.mem.Allocator,
    /// The request's `std.Io`.
    io: std.Io,
    /// `UpgradeOptions.max_message_size`.
    max_message_size: usize,
    /// Held across compressing and sending a message, so tasks sending on
    /// one socket (a `Rooms.broadcast` beside the socket's own handler) do
    /// not interleave on the compressor.
    send_mutex: std.Io.Mutex = .init,
    /// The server's drain signal (`Request.drain`); null in a request the
    /// server did not build.
    drain: ?*std.Io.Event = null,
    /// Sends 1001 when the drain starts (`UpgradeOptions.close_on_drain`).
    drain_watch: ?*DrainWatch = null,
    /// A close went out through `close`, or came in through `receive` (and
    /// was answered), or `next` saw the connection end.
    closed: std.atomic.Value(bool) = .init(false),
    /// Why `next` returned null when it was not the peer's close: the
    /// error `receive` failed with.
    end_error: ?anyerror = null,

    /// Which protocol a socket runs on. The sockets it points at are
    /// internal: they hand over permessage-deflate messages still
    /// compressed, which `Socket`'s methods inflate. Both live in the
    /// request's arena, so a task beside the handler (the drain watch, a
    /// `Rooms.broadcast`) acts on the same one.
    pub const Conn = union(enum) {
        h1: *WebSocket,
        /// An HTTP/2 or an HTTP/3 stream (RFC 8441, RFC 9220).
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

    /// Sends one message (`.text` or `.binary`, usually), compressed when
    /// permessage-deflate is in use and `data` is long enough. Safe beside
    /// the socket's own handler from other tasks (`Rooms.broadcast`).
    /// A text message must be valid UTF-8; that is the caller's to keep.
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

    /// Sends a ping with `data`: at most 125 bytes, else
    /// `error.LargeControlFrame`. The pong is dropped inside `receive`.
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
    pub noinline fn close(self: *Socket, code: CloseCode, reason: []const u8) !void {
        self.closed.store(true, .release);
        return switch (self.conn) {
            inline else => |ws| ws.close(code, reason),
        };
    }

    /// Releases the socket: the drain watch, the compressor, and the
    /// stream or connection's WebSocket state. It sends no close; `close`
    /// first for a clean end. `app.ws` routes do both for you.
    pub fn deinit(self: *Socket) void {
        // First, so nothing sends on the socket once it is gone.
        if (self.drain_watch) |w| w.stop();
        if (comptime features.compression) if (self.deflate) |d| d.deinit(self.allocator);
        switch (self.conn) {
            inline else => |ws| ws.deinit(),
        }
    }
};

/// Sends close 1001 when the server starts to drain, through the server's
/// drain hooks (`Request.drain_hooks`): a socket keeps no task of its own
/// waiting for the drain, only this, in the request's arena. The close is
/// sent from a task started when the drain does, on the socket's executor,
/// so a peer that does not read holds up only its own.
const DrainWatch = struct {
    hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
    hooks: *dusty.DrainHooks,
    io: std.Io,
    conn: Socket.Conn,
    reason: []const u8,
    /// The socket's executor, where the close goes.
    executor: ?usize,
    sender: std.Io.Group = .init,

    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const self: *DrainWatch = @fieldParentPtr("hook", hook);
        const where: placement.Where = if (self.executor) |i| .{ .executor = i } else .local;
        // Without a task to spare, the socket lives on until the handler
        // ends it or the drain's deadline does.
        placement.concurrent(&self.sender, self.io, where, send, .{self}) catch {};
    }

    fn send(self: *DrainWatch) std.Io.Cancelable!void {
        switch (self.conn) {
            inline else => |ws| ws.close(.going_away, self.reason) catch {},
        }
    }

    /// Out of the hooks, and any close under way finished or canceled.
    fn stop(self: *DrainWatch) void {
        self.hooks.remove(self.io, &self.hook);
        self.sender.cancel(self.io);
    }
};

/// Accepts the WebSocket `req` asks for, on either HTTP version, and
/// answers the handshake. Null when `req` is not a WebSocket request (the
/// handler answers it as it sees fit). The socket lives as long as the
/// handler: the request's arena holds it.
pub fn upgrade(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions) !?Socket {
    // An extended CONNECT, over HTTP/2 or HTTP/3.
    const h2 = req.protocol != null;
    if (h2) {
        if (!(features.http2 or features.http3) or !std.ascii.eqlIgnoreCase(req.protocol.?, "websocket")) return null;
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
        socket.conn = .{ .h2 = try H2Socket.accept(req, res, options.max_message_size, negotiated) };
    } else {
        const ws = try req.arena.create(WebSocket);
        ws.* = (try res.upgradeWebSocket(req)) orelse return null;
        ws.max_message_size = options.max_message_size;
        ws.rsv1_allowed = negotiated;
        socket.conn = .{ .h1 = ws };
    }
    req.setTimeout(options.timeout);
    if (options.close_on_drain) if (req.drain_hooks) |hooks| {
        const watch = try req.arena.create(DrainWatch);
        watch.* = .{
            .hooks = hooks,
            .io = req.io,
            .conn = socket.conn,
            .reason = try req.arena.dupe(u8, options.drain_reason),
            .executor = placement.currentExecutor(req.io),
        };
        hooks.add(req.io, &watch.hook);
        socket.drain_watch = watch;
    };
    return socket;
}

// Out of line, like everything a socket's handler does not run while it
// waits: `serve`'s frame is under every wait of an open socket, and its
// pages stay with the task.
noinline fn refuse(res: *dusty.Response) anyerror!void {
    res.fail(.upgrade_required, "this endpoint speaks WebSocket");
    return res.header("Upgrade", "websocket");
}

noinline fn failed(ws: *Socket, req: *dusty.Request, res: *dusty.Response, err: anyerror) anyerror!void {
    if (err == error.Canceled) return err;
    // The peer went away mid-send: not the handler's fault.
    if (res.peerGone()) return;
    std.log.scoped(.anole).warn("WebSocket handler for {s} failed: {t}", .{ req.url, err });
    if (!ws.closed.load(.acquire)) ws.close(.internal_error, "") catch {};
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
            var ws = (try upgrade(req, res, options)) orelse return refuse(res);
            defer ws.deinit();
            const result = switch (params.len) {
                1 => handler(&ws),
                2 => handler(&ws, req),
                3 => handler(ctx, &ws, req),
                else => unreachable,
            };
            result catch |err| return failed(&ws, req, res, err);
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

    /// No rooms yet. `allocator` holds the room names and members; it must
    /// be thread-safe when sockets on several executors join.
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

    /// Frees every room. Call it once no socket is a member any more.
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
