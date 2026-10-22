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
//! A socket that is mostly idle (a chat, notifications) can be served with
//! callbacks instead (`Server.wsCallbacks`, through `callbacks`): over
//! HTTP/1.1 it then holds no task while it waits for the peer, only a small
//! heap object, and a task is started for each burst of messages (see
//! `callbacks`):
//!
//!     const Chat = struct {
//!         pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void {
//!             try ws.send(msg.type, msg.data);
//!         }
//!     };
//!     app.wsCallbacks("/chat", Chat);
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
    /// What the socket's parts live in: the request's arena, or for a
    /// callback socket over HTTP/1.1 the server's allocator. Used only by
    /// the task that reads the socket; the compressor has an allocator of
    /// its own.
    allocator: std.mem.Allocator,
    /// The request's `std.Io`.
    io: std.Io,
    /// The executor the socket was opened on, where `Rooms` sends to it
    /// from; null off zio.
    executor: ?usize = null,
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
    /// Why the socket ended when it was not the peer's close (`next`
    /// returned null, or a callback socket's `close` ran): the error its
    /// read failed with, `error.EndOfStream` for a peer that left without
    /// a close frame.
    end_error: ?anyerror = null,
    /// The code of the peer's close, once one arrived (null for a close
    /// with no code, or none yet).
    close_code: ?CloseCode = null,
    /// The application's, for state it keeps per socket: a callback socket
    /// (`callbacks`) sets it in `open` and frees what it points at in
    /// `close`. See `contextAs`.
    context: ?*anyopaque = null,

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
    ///
    /// Its parts are inlined into it, and it into `next`, whoever else
    /// calls them (the callbacks): a message read in one function, rather
    /// than through a call for each layer, which costs an echo loop about a
    /// tenth of its CPU.
    pub fn receive(self: *Socket) !Message {
        return @call(.always_inline, finishMessage, .{ self, switch (self.conn) {
            inline else => |ws| try @call(.always_inline, @TypeOf(ws.*).receive, .{ws}),
        } });
    }

    /// Over HTTP/1.1, for a reading task that waits for the peer in its
    /// own way (`callbacks`): the next message once one has begun in the
    /// read buffer, null when it is empty (dusty's
    /// `WebSocket.receiveStarted`).
    fn receiveStarted(self: *Socket) !?Message {
        const msg = (try self.conn.h1.receiveStarted()) orelse return null;
        return try self.finishMessage(msg);
    }

    /// What `receive` does with a message the connection handed over:
    /// inflate, check, note a close.
    fn finishMessage(self: *Socket, received: Message) !Message {
        var msg = received;
        if (msg.type == .close) {
            self.close_code = msg.close_code;
            self.closed.store(true, .release);
        }
        if (!msg.compressed) return msg;
        if (comptime !features.compression) unreachable;
        const d = self.deflate orelse unreachable; // RSV1 is refused unless negotiated
        msg.data = d.decompress(msg.data, self.max_message_size) catch |err| {
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

    /// `context` as a `*T`.
    pub fn contextAs(self: *const Socket, comptime T: type) *T {
        return @ptrCast(@alignCast(self.context.?));
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
                const packed_data = try d.compress(data);
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
            const msg = @call(.always_inline, receive, .{self}) catch |err| {
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
        if (comptime features.compression) if (self.deflate) |d| d.deinit();
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
    return openSocket(req, res, options, null);
}

/// `upgrade`. With `owner`, the socket's parts that outlive the request
/// over HTTP/1.1 (the WebSocket, its messages' memory, the compressor, the
/// drain watch) come from it rather than from the request's arena, for a
/// socket served after its handler returned (`callbacks`); `freeParts`
/// gives them back.
fn openSocket(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions, owner: ?std.mem.Allocator) !?Socket {
    // An extended CONNECT, over HTTP/2 or HTTP/3.
    const h2 = req.protocol != null;
    if (h2) {
        if (!(features.http2 or features.http3) or !std.ascii.eqlIgnoreCase(req.protocol.?, "websocket")) return null;
        const version = req.headers.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;
    }

    // What lives as long as the socket.
    const alloc = if (h2) req.arena else owner orelse req.arena;

    // permessage-deflate: the first offer we can take, answered in the
    // handshake's response.
    var deflate: if (features.compression) ?*deflate_impl.Deflate else void = if (features.compression) null else {};
    errdefer if (comptime features.compression) if (owner != null and !h2) if (deflate) |d| alloc.destroy(d);
    if (comptime features.compression) if (options.compression) {
        if (req.headers.get("Sec-WebSocket-Extensions")) |offers| {
            var buf: [160]u8 = undefined;
            if (deflate_impl.negotiate(offers, options.deflate, &buf)) |accepted| {
                try res.header("Sec-WebSocket-Extensions", try req.arena.dupe(u8, accepted.response));
                const d = try alloc.create(deflate_impl.Deflate);
                // Its buffers apart from the request's arena, which is not
                // thread-safe over HTTP/1.1: other tasks compress what they
                // send (`Rooms`). The server's allocator there; over HTTP/2
                // and HTTP/3 the stream's arena is a `std.heap.ArenaAllocator`
                // over the server's allocator, which is thread-safe.
                d.* = .init(accepted.config, options.deflate, if (h2) req.arena else res.conn.allocator);
                deflate = d;
            }
        }
    };
    const negotiated = if (comptime features.compression) deflate != null else false;

    var socket: Socket = .{
        .conn = undefined,
        .deflate = deflate,
        .allocator = alloc,
        .io = req.io,
        .max_message_size = options.max_message_size,
        .drain = req.drain,
        .executor = placement.currentExecutor(req.io),
    };
    if (h2) {
        socket.conn = .{ .h2 = try H2Socket.accept(req, res, options.max_message_size, negotiated) };
    } else {
        const ws = try alloc.create(WebSocket);
        errdefer if (owner != null) alloc.destroy(ws);
        ws.* = (try res.upgradeWebSocket(req)) orelse {
            if (owner != null) alloc.destroy(ws);
            if (comptime features.compression) if (owner != null) if (deflate) |d| alloc.destroy(d);
            return null;
        };
        // Its messages' memory too, when the socket outlives the request
        // (empty yet).
        if (owner != null) ws.msg_arena = .init(alloc);
        ws.max_message_size = options.max_message_size;
        ws.rsv1_allowed = negotiated;
        socket.conn = .{ .h1 = ws };
    }
    req.setTimeout(options.timeout);
    if (options.close_on_drain) if (req.drain_hooks) |hooks| {
        const watch = try alloc.create(DrainWatch);
        watch.* = .{
            .hooks = hooks,
            .io = req.io,
            .conn = socket.conn,
            // Copied for a socket in the request's arena, where `options`
            // may be a caller's temporary; a socket that outlives the
            // request has comptime options.
            .reason = if (owner != null and !h2) options.drain_reason else try req.arena.dupe(u8, options.drain_reason),
            .executor = placement.currentExecutor(req.io),
        };
        hooks.add(req.io, &watch.hook);
        socket.drain_watch = watch;
    };
    return socket;
}

/// Deinitializes `socket` and frees what `openSocket` took from `owner`.
fn freeParts(owner: std.mem.Allocator, socket: *Socket) void {
    const ws = socket.conn.h1;
    socket.deinit();
    if (comptime features.compression) if (socket.deflate) |d| owner.destroy(d);
    if (socket.drain_watch) |w| owner.destroy(w);
    owner.destroy(ws);
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

/// A route handler for `Server.wsCallbacks`: a WebSocket served through
/// callbacks, which over HTTP/1.1 keeps no task while it waits for the
/// peer. `Handler` is a namespace with
///
///   - `message(ws: *Socket, msg: Message) !void`, required: each text or
///     binary message (inflated, UTF-8 checked), its data valid during the
///     call;
///   - `open(ws: *Socket, req: *Request) !void`, optional: right after the
///     handshake, with the request at hand for the last time. Copy what the
///     socket needs into `ws.context`, join rooms, send a greeting;
///   - `close(ws: *Socket) void`, optional: once, when the socket is done
///     (the peer closed it, `ws.close_code` says how; the connection
///     ended, `ws.end_error`; the server stopped or a callback failed).
///     Leave rooms and free `ws.context` here. The socket goes away after.
///
/// each with the server's state first when it has one (`*Ctx`). Callbacks
/// run one at a time on a task on the socket's executor and may wait (a
/// database, a lock); messages that arrive meanwhile wait for them. A
/// failing `open` or `message` closes the socket with 1011. Pings are
/// answered and replies batched as with `ws.next()`. `ws.send` works from
/// any task at any time, `ws.close` too, and the socket can be in `Rooms`.
///
/// Over HTTP/1.1 the connection is handed over to the socket once the
/// handshake is done (`anole.http.Response.adopt`): when it has had nothing to
/// read for `timeout.idle_park`, its task ends and it parks; the next
/// message starts a task again. What other tasks send meanwhile goes out
/// unbuffered. Over HTTP/2 and HTTP/3 the socket keeps its stream's task.
/// `options.timeout`, when set, closes the socket at that deadline.
pub fn callbacks(comptime Ctx: type, comptime Handler: type, comptime options: UpgradeOptions) dusty.Router(Ctx).Handler {
    const H = Hooks(Ctx, Handler);
    const S = struct {
        fn serve(ctx: if (Ctx == void) void else *Ctx, req: *dusty.Request, res: *dusty.Response) anyerror!void {
            const state: ?*anyopaque = if (Ctx == void) null else ctx;
            return serveTable(req, res, options, &H.table, state);
        }
    };
    return if (Ctx == void) struct {
        fn h(req: *dusty.Request, res: *dusty.Response) anyerror!void {
            return S.serve({}, req, res);
        }
    }.h else S.serve;
}

/// `callbacks` with the callbacks and options chosen at run time (the C
/// ABI's WebSocket routes): `table`'s functions get `state` first. Answers
/// 426 to a request that is not a WebSocket handshake.
pub fn serveTable(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions, table: *const Table, state: ?*anyopaque) anyerror!void {
    if (req.protocol != null) {
        var ws = (try upgrade(req, res, options)) orelse return refuse(res);
        defer ws.deinit();
        return serveOnTask(&ws, req, res, table, state);
    }
    const self = (try H1Callbacks.open(req, res, options, table, state)) orelse return refuse(res);
    // The connection is the socket's from here: a failure closes the
    // socket, not the request.
    table.open(state, &self.socket, req) catch |err| self.openFailed(req, err);
}

/// A callback socket's `Handler`, behind plain function pointers
/// (`serveTable`).
pub const Table = struct {
    open: *const fn (state: ?*anyopaque, *Socket, *dusty.Request) anyerror!void,
    message: *const fn (state: ?*anyopaque, *Socket, Message) anyerror!void,
    close: *const fn (state: ?*anyopaque, *Socket) void,
};

fn Hooks(comptime Ctx: type, comptime Handler: type) type {
    if (!@hasDecl(Handler, "message")) @compileError("a WebSocket callbacks type needs pub fn message(ws: *anole.websocket.Socket, msg: anole.websocket.Message) !void");
    return struct {
        const table: Table = .{ .open = open, .message = message, .close = close };

        fn arity(comptime f: anytype, comptime plain: usize, comptime name: []const u8) bool {
            const n = @typeInfo(@TypeOf(f)).@"fn".param_types.len;
            if (n == plain) return false;
            if (n == plain + 1 and Ctx != void) return true;
            @compileError("WebSocket callback " ++ name ++ " has the wrong parameters: " ++ @typeName(@TypeOf(f)));
        }

        fn ctxOf(state: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(state.?));
        }

        fn open(state: ?*anyopaque, ws: *Socket, req: *dusty.Request) anyerror!void {
            if (comptime !@hasDecl(Handler, "open")) return;
            const f = Handler.open;
            return if (comptime arity(f, 2, "open")) f(ctxOf(state), ws, req) else f(ws, req);
        }

        fn message(state: ?*anyopaque, ws: *Socket, msg: Message) anyerror!void {
            const f = Handler.message;
            return if (comptime arity(f, 2, "message")) f(ctxOf(state), ws, msg) else f(ws, msg);
        }

        fn close(state: ?*anyopaque, ws: *Socket) void {
            if (comptime !@hasDecl(Handler, "close")) return;
            const f = Handler.close;
            return if (comptime arity(f, 1, "close")) f(ctxOf(state), ws) else f(ws);
        }
    };
}

/// A callback socket on its stream's task (HTTP/2, HTTP/3): the callbacks
/// in a loop, as a `route` handler would run them.
fn serveOnTask(ws: *Socket, req: *dusty.Request, res: *dusty.Response, table: *const Table, state: ?*anyopaque) anyerror!void {
    defer table.close(state, ws);
    table.open(state, ws, req) catch |err| return failed(ws, req, res, err);
    while (try ws.next()) |msg| {
        table.message(state, ws, msg) catch |err| return failed(ws, req, res, err);
    }
}

/// A callback socket over HTTP/1.1, on the heap for its life. The HTTP core
/// hands the connection over to it after the handshake (`dusty.Adopter`),
/// and runs `serve` on a task each time the connection has something to
/// read; in between, the connection is parked and no task waits for it.
const H1Callbacks = struct {
    adopter: dusty.Adopter,
    socket: Socket,
    /// The server's allocator: this, and the socket's parts (`openSocket`).
    gpa: std.mem.Allocator,
    table: *const Table,
    state: ?*anyopaque,
    /// `open` failed: the socket ends at once, as a `route` handler's would.
    ending: bool = false,

    /// Each run's reader window, on its task's stack. A frame bigger than
    /// it is read straight into its message. The writer borrows a buffer
    /// from the connection while it has something to send.
    const window_len = 2048;

    fn open(req: *dusty.Request, res: *dusty.Response, options: UpgradeOptions, table: *const Table, state: ?*anyopaque) !?*H1Callbacks {
        const gpa = res.conn.allocator;
        const self = try gpa.create(H1Callbacks);
        errdefer gpa.destroy(self);
        var socket = (try openSocket(req, res, options, gpa)) orelse {
            gpa.destroy(self);
            return null;
        };
        errdefer freeParts(gpa, &socket);
        self.* = .{
            .adopter = .{ .serve = serve, .release = release, .deadline = deadline(req.io, options.timeout) },
            .socket = socket,
            .gpa = gpa,
            .table = table,
            .state = state,
        };
        // An HTTP/1.1 response whose 101 went out.
        try res.adopt(&self.adopter);
        return self;
    }

    /// `timeout` as a deadline on the awake clock, which is the one a
    /// parked connection's is kept on.
    fn deadline(io: std.Io, timeout: std.Io.Timeout) ?std.Io.Clock.Timestamp {
        const left = timeout.toDurationFromNow(io) orelse return null;
        return std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = left.raw, .clock = .awake });
    }

    fn openFailed(self: *H1Callbacks, req: *dusty.Request, err: anyerror) void {
        self.ending = true;
        if (err == error.Canceled) return;
        std.log.scoped(.anole).warn("WebSocket open for {s} failed: {t}", .{ req.url, err });
        if (!self.socket.closed.load(.acquire)) self.socket.close(.internal_error, "") catch {};
    }

    fn serve(a: *dusty.Adopter, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        const self: *H1Callbacks = @fieldParentPtr("adopter", a);
        const ws = self.socket.conn.h1;
        if (self.ending) return self.finish(null);
        // The core gives the request's buffers back before the first run,
        // unless the peer sent something behind the handshake already: then
        // that run keeps the window the upgrade left, in those buffers, and
        // the core gives them back once it returns.
        var read_window: [window_len]u8 = undefined;
        if (ws.transport.reader.buffer.len == 0) ws.attachBuffers(&read_window);
        while (true) {
            const started = self.socket.receiveStarted() catch |err| return self.finish(err);
            const msg = started orelse {
                // Nothing buffered: what a batch held goes out, and the
                // connection waits, here or parked.
                ws.flushBatch() catch |err| return self.finish(err);
                const input = burst.waitInput() catch |err| return self.finish(err);
                if (input == .idle) {
                    ws.detachBuffers();
                    return .park;
                }
                continue;
            };
            switch (msg.type) {
                .text, .binary => self.table.message(self.state, &self.socket, msg) catch |err| {
                    if (err != error.Canceled and !self.socket.closed.load(.acquire)) {
                        std.log.scoped(.anole).warn("WebSocket message handler failed: {t}", .{err});
                        self.socket.close(.internal_error, "") catch {};
                    }
                    return self.finish(err);
                },
                .close => return self.finish(null),
                else => {},
            }
        }
    }

    /// Ends the socket from its reading side: sending is over, and the
    /// windows are given up (`dusty.Adopter.serve`). `close` runs as the
    /// core releases it.
    fn finish(self: *H1Callbacks, err: ?anyerror) dusty.Burst.End {
        if (err) |e| if (self.socket.end_error == null and self.socket.close_code == null) {
            self.socket.end_error = e;
        };
        self.socket.closed.store(true, .release);
        self.socket.conn.h1.shut();
        return .close;
    }

    fn release(a: *dusty.Adopter) void {
        const self: *H1Callbacks = @fieldParentPtr("adopter", a);
        const gpa = self.gpa;
        // Closed by the server (a deadline, the stop) while parked, or
        // before its first run: no frame goes out from here on.
        self.socket.closed.store(true, .release);
        self.socket.conn.h1.shut();
        self.table.close(self.state, &self.socket);
        freeParts(gpa, &self.socket);
        gpa.destroy(self);
    }
};

/// Named groups of sockets for publish/subscribe: a handler joins its
/// socket to rooms, and anything may broadcast to a room. Safe from any task
/// or thread of the runtime.
///
/// A broadcast never waits for a member. It copies the message once and
/// queues it for every member, and each member with something queued has a
/// task of its own, on the socket's executor, that sends it in order. A
/// member that does not keep up (its client stopped reading) only fills its
/// own queue: past `Options.max_queued_bytes` the messages that do not fit
/// are skipped for it, and with `on_full = .close` (the default) a member
/// whose send has been stuck for `Options.close_after_ms` is closed: it
/// gets no more broadcasts, and the send under way to it is canceled, which
/// ends its sending side. A member whose send fails gets no more either;
/// its own `receive` sees the connection end.
pub const Rooms = struct {
    allocator: std.mem.Allocator,
    options: Options = .{},
    /// The runtime's `std.Io`, taken from the first socket to join, so
    /// `init` needs none (the rooms can be made before the server).
    io: std.Io = undefined,
    io_set: std.atomic.Value(bool) = .init(false),
    io_lock: std.atomic.Mutex = .unlocked,
    /// Over `rooms` and every member's queue and flags; never held across
    /// I/O.
    mutex: std.Io.Mutex = .init,
    /// Signalled when a member that left has no sender running.
    idle: std.Io.Condition = .init,
    rooms: std.StringHashMapUnmanaged(std.ArrayList(*Member)) = .empty,

    pub const Options = struct {
        /// The most broadcast bytes that may wait for one member (each
        /// message counts 64 bytes more). A message is always taken when
        /// nothing waits.
        max_queued_bytes: usize = 1024 * 1024,
        /// What a broadcast does with a member whose queue is full.
        on_full: OnFull = .close,
        /// With `.close`: how long the send under way to a full member must
        /// have been stuck before it is closed. Until then (a member that
        /// is only busy) the messages that do not fit are skipped.
        close_after_ms: u32 = 1000,
        /// How long `leave` lets a send under way to the leaving socket
        /// finish before it cancels it.
        leave_grace_ms: u32 = 1000,
    };

    pub const OnFull = enum {
        /// The message is skipped for that member, and a member whose send
        /// has been stuck for `close_after_ms` gets no more broadcasts: the
        /// send under way to it is canceled, which ends the socket's
        /// sending side (its handler's `receive` then ends when the peer
        /// goes or the socket's timeout passes).
        close,
        /// The message is skipped for that member; later ones are queued as
        /// room frees up.
        drop,
    };

    /// One copy of a broadcast message, shared by every queue it is in.
    const Payload = struct {
        refs: std.atomic.Value(u32),
        type: MessageType,
        len: usize,

        fn create(allocator: std.mem.Allocator, msg_type: MessageType, message: []const u8) !*Payload {
            const block = try allocator.alignedAlloc(u8, .of(Payload), @sizeOf(Payload) + message.len);
            const p: *Payload = @ptrCast(block.ptr);
            p.* = .{ .refs = .init(1), .type = msg_type, .len = message.len };
            @memcpy(block[@sizeOf(Payload)..], message);
            return p;
        }

        fn bytes(p: *const Payload) []const u8 {
            const base: [*]const u8 = @ptrCast(p);
            return base[@sizeOf(Payload)..][0..p.len];
        }

        fn cost(p: *const Payload) usize {
            return p.len + 64;
        }

        fn release(p: *Payload, allocator: std.mem.Allocator) void {
            if (p.refs.fetchSub(1, .acq_rel) != 1) return;
            const base: [*]align(@alignOf(Payload)) u8 = @ptrCast(p);
            allocator.free(base[0 .. @sizeOf(Payload) + p.len]);
        }
    };

    const Member = struct {
        socket: *Socket,
        /// Messages waiting, from `head` on.
        queue: std.ArrayList(*Payload) = .empty,
        head: usize = 0,
        queued_bytes: usize = 0,
        /// A sender task is started or running; it alone takes from the
        /// queue.
        running: bool = false,
        /// The running sender, for `cancel`; null before it starts.
        task: ?placement.Task = null,
        /// When the send under way started; null between sends.
        sending_since: ?std.Io.Clock.Timestamp = null,
        /// Its send failed, or it was closed for not keeping up: it gets
        /// nothing more.
        broken: bool = false,
        /// Out of its room, waiting for its sender to end.
        left: bool = false,
        sender: std.Io.Group = .init,

        fn pop(m: *Member) ?*Payload {
            if (m.head == m.queue.items.len) return null;
            const p = m.queue.items[m.head];
            m.head += 1;
            m.queued_bytes -= p.cost();
            if (m.head == m.queue.items.len) {
                m.queue.clearRetainingCapacity();
                m.head = 0;
            } else if (m.head >= 64 and m.head * 2 >= m.queue.items.len) {
                const rest = m.queue.items[m.head..];
                std.mem.copyForwards(*Payload, m.queue.items[0..rest.len], rest);
                m.queue.items.len = rest.len;
                m.head = 0;
            }
            return p;
        }

        fn dropQueue(m: *Member, allocator: std.mem.Allocator) void {
            for (m.queue.items[m.head..]) |p| p.release(allocator);
            m.queue.clearRetainingCapacity();
            m.head = 0;
            m.queued_bytes = 0;
        }

        /// Gets nothing more, and the send under way is canceled. Under
        /// the mutex.
        fn close(m: *Member, allocator: std.mem.Allocator) void {
            m.broken = true;
            m.dropQueue(allocator);
            if (m.running) if (m.task) |t| placement.cancelTask(t);
        }
    };

    /// Members a broadcast notes on the stack for starting their senders; a
    /// bigger room borrows from the allocator.
    const stack_snapshot = 64;

    /// No rooms yet. `allocator` holds the room names, members and queued
    /// messages; it must be thread-safe when sockets on several executors
    /// join.
    pub fn init(allocator: std.mem.Allocator) Rooms {
        return .{ .allocator = allocator };
    }

    /// `init` with options other than the defaults.
    pub fn initOptions(allocator: std.mem.Allocator, options: Options) Rooms {
        return .{ .allocator = allocator, .options = options };
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
            for (entry.value_ptr.items) |m| self.freeMember(m);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rooms.deinit(self.allocator);
    }

    fn freeMember(self: *Rooms, m: *Member) void {
        m.dropQueue(self.allocator);
        m.queue.deinit(self.allocator);
        self.allocator.destroy(m);
    }

    /// Adds `socket` to `room`; nothing when it is a member already. Leave
    /// before the socket goes away: `defer rooms.leave(room, &ws)`.
    pub fn join(self: *Rooms, room: []const u8, socket: *Socket) !void {
        const member = try self.allocator.create(Member);
        var used = false;
        defer if (!used) self.allocator.destroy(member);
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
        for (entry.value_ptr.items) |m| if (m.socket == socket) return;
        entry.value_ptr.append(self.allocator, member) catch |err| {
            if (entry.value_ptr.items.len == 0) {
                const key = entry.key_ptr.*;
                entry.value_ptr.deinit(self.allocator);
                self.rooms.removeByPtr(entry.key_ptr);
                self.allocator.free(key);
            }
            return err;
        };
        used = true;
    }

    /// Takes `socket` out of `room`. Messages still queued for it are
    /// dropped; a send under way is given `Options.leave_grace_ms` to finish
    /// and then canceled, so a socket is never sent to once `leave` returns.
    pub fn leave(self: *Rooms, room: []const u8, socket: *Socket) void {
        const io = self.bind(socket.io);
        self.mutex.lockUncancelable(io);
        const members = self.rooms.getPtr(room) orelse return self.mutex.unlock(io);
        const member = for (members.items, 0..) |m, i| {
            if (m.socket == socket) break members.swapRemove(i);
        } else return self.mutex.unlock(io);
        if (members.items.len == 0) {
            const key = self.rooms.getKey(room).?;
            members.deinit(self.allocator);
            _ = self.rooms.remove(room);
            self.allocator.free(key);
        }
        member.left = true;
        member.dropQueue(self.allocator);
        var canceled = false;
        if (member.running) {
            const grace: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(self.options.leave_grace_ms), .clock = .awake } };
            const deadline = grace.toDeadline(io);
            while (member.running) {
                self.idle.waitTimeout(io, &self.mutex, deadline) catch |err| {
                    if (err == error.Canceled) canceled = true;
                    break;
                };
            }
            if (member.running) if (member.task) |t| placement.cancelTask(t);
            while (member.running) self.idle.waitUncancelable(io, &self.mutex);
        }
        self.mutex.unlock(io);
        // The sender has ended: this only releases the group.
        member.sender.cancel(io);
        self.freeMember(member);
        if (canceled) io.recancel();
    }

    /// Queues one message for every member of `room` but `except`, and
    /// returns for how many. It does not wait for any of them to be sent
    /// (see `Rooms`). Members joining meanwhile do not get it.
    pub fn broadcast(self: *Rooms, room: []const u8, msg_type: MessageType, data: []const u8, except: ?*Socket) usize {
        const io = self.bound() orelse return 0;
        const payload = Payload.create(self.allocator, msg_type, data) catch return 0;
        // The broadcast's own reference; each queue holds one more.
        defer payload.release(self.allocator);

        var stack: [stack_snapshot]*Member = undefined;
        var heap: []*Member = &.{};
        defer self.allocator.free(heap);
        var start: []*Member = &.{};
        var reached: usize = 0;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const members = (self.rooms.get(room) orelse return 0).items;
            // The members whose sender has to be started, started once the
            // lock is let go. Without memory to note them, they are started
            // here.
            const buf: ?[]*Member = if (members.len <= stack.len) &stack else if (self.allocator.alloc(*Member, members.len)) |h| big: {
                heap = h;
                break :big h;
            } else |_| null;
            var n: usize = 0;
            for (members) |m| {
                if (m.socket == except or m.broken or m.left) continue;
                if (m.queued_bytes > 0 and m.queued_bytes + payload.cost() > self.options.max_queued_bytes) {
                    if (self.options.on_full == .close) if (m.sending_since) |since| {
                        const stuck = since.untilNow(io).raw.toMilliseconds();
                        if (stuck >= self.options.close_after_ms) m.close(self.allocator);
                    };
                    continue;
                }
                m.queue.append(self.allocator, payload) catch continue;
                _ = payload.refs.fetchAdd(1, .monotonic);
                m.queued_bytes += payload.cost();
                reached += 1;
                if (m.running) continue;
                m.running = true;
                if (buf) |b| {
                    b[n] = m;
                    n += 1;
                } else self.startSender(io, m);
            }
            if (buf) |b| start = b[0..n];
        }
        for (start) |m| self.startSender(io, m);
        return reached;
    }

    /// Starts `m`'s sender, `m.running` already set. Without a task to
    /// spare, what is queued waits for the next broadcast to try again.
    fn startSender(self: *Rooms, io: std.Io, m: *Member) void {
        const where: placement.Where = if (m.socket.executor) |i| .{ .executor = i } else .local;
        placement.concurrent(&m.sender, io, where, sendQueued, .{ self, m }) catch {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            m.running = false;
            if (m.left) self.idle.broadcast(io);
        };
    }

    /// A member's sender: sends what is queued for it, in order, until the
    /// queue is empty or the member is done.
    fn sendQueued(self: *Rooms, m: *Member) std.Io.Cancelable!void {
        const io = self.io;
        var canceled = false;
        self.mutex.lockUncancelable(io);
        m.task = placement.currentTask(io);
        while (!m.left and !m.broken) {
            const p = m.pop() orelse break;
            m.sending_since = .now(io, .awake);
            self.mutex.unlock(io);
            const sent = if (m.socket.send(p.type, p.bytes())) |_| true else |err| blk: {
                if (err == error.Canceled) canceled = true;
                break :blk false;
            };
            p.release(self.allocator);
            self.mutex.lockUncancelable(io);
            m.sending_since = null;
            if (!sent) {
                m.broken = true;
                m.dropQueue(self.allocator);
            }
        }
        m.running = false;
        m.task = null;
        if (m.left) self.idle.broadcast(io);
        self.mutex.unlock(io);
        if (canceled) return error.Canceled;
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
    // About parked callback sockets; idle parking is off on Windows.
    if (@import("builtin").os.tag != .windows) _ = @import("callbacks_test.zig");
    _ = @import("h2_fuzz_test.zig");
    if (features.http2) _ = @import("h2_test.zig");
    if (features.compression) _ = @import("deflate.zig");
}

test "WebSocket accept key matches RFC 6455 section 1.3" {
    var out: [28]u8 = undefined;
    WebSocket.computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}
