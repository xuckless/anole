//! Raw TCP servers (p3/net, design-net.md §2.2 to §3): the application's own
//! protocol on Anole's listeners. The HTTP core's accept loops, connection
//! cap, PROXY protocol, TLS and parking do the work up to a ready
//! connection (`Listener.raw`); from there a `TcpConn` serves it, as the
//! WebSocket-callbacks adopter does: a task for each burst of input, no
//! task while the connection waits for the peer.
//!
//! Writing never waits on the peer, and takes no lock. `Conn.send` reserves
//! its bytes against `write_max` and returns: on the connection's executor
//! it appends to the outbox directly; from elsewhere its bytes go, as one
//! owned chunk, onto the connection's inbox (a sealable push list,
//! SAFETY.md L7). One *net driver* task per executor writes the outboxes
//! that were kicked since its last round, straight from the driver with a
//! non-blocking `sendmsg` on plain TCP, so every connection a consumer
//! answered in one round costs one syscall and no task switch. A TLS
//! connection, or one whose socket buffer filled, gets a flusher task.
//! Exactly one party is responsible for an outbox at any time (`sched`),
//! so bytes leave in send order.
//!
//! Lifetimes (SAFETY.md M2, T1, T4): a connection is a child of the core's
//! connection; its helper tasks (flusher, writable, drain) are children in
//! its own group, joined before it is freed. The driver reaches it only
//! through its kick slot, stable memory resolved on the driver's (and the
//! connection's) executor.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const anole_log = @import("anole_log");
const safety = @import("anole_safety");
const framing_mod = @import("framing.zig");
const net_metrics = @import("metrics.zig");

pub const Framing = framing_mod.Framing;
pub const FrameIterator = framing_mod.FrameIterator;

const placement = dusty.placement;
const push_list = dusty.push_list;
const Duration = std.Io.Duration;
const native_os = builtin.os.tag;

/// Winsock calls made directly (Windows, a development target): a shutdown
/// or a socket option is one synchronous call there as on POSIX, never an
/// Io wait, so it is no cancelation point and works from a consumer thread.
const ws = if (native_os == .windows) struct {
    const windows = @import("zio").os.windows;
    const SD_RECEIVE: i32 = 0;
    const SD_SEND: i32 = 1;
    const SD_BOTH: i32 = 2;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_LINGER: u32 = 0x0080;
    const Linger = extern struct { onoff: u16, linger: u16 };

    fn socket(fd: std.posix.fd_t) windows.SOCKET {
        return @ptrCast(fd);
    }
} else struct {};
const log = std.log.scoped(.anole);

/// How a connection ended.
pub const CloseReason = enum {
    /// The peer closed (FIN after its data, with nothing more owed).
    peer,
    /// The handler closed it (`close`, `end` once flushed, a task handler that returned).
    local,
    /// The peer reset it (RST), or it broke mid-write (EPIPE).
    reset,
    /// A read, write or TLS failure; a callback that failed (logged at warn).
    failed,
    idle,
    write_timeout,
    lifetime,
    /// A frame over its `max`, or a malformed length prefix.
    frame,
    /// The drain's deadline (`timeouts.shutdown`) or the server's stop.
    drain,
    /// Anole could not go on (out of memory).
    server,
};

pub const Tcp = struct {
    pub const Options = struct {
        /// How input is cut into messages: see `Framing`.
        framing: Framing = .none,
        /// After the peer ends its side (FIN), the connection stays open for
        /// writing until the handler ends it (`conn.end()`/`close()`). False:
        /// Anole ends this side once what is queued is out, and closes.
        half_open: bool = false,
        /// TCP_NODELAY: small writes go out at once (no Nagle).
        no_delay: bool = true,
        /// TCP keep-alive probes after this much silence (SO_KEEPALIVE,
        /// TCP_KEEPIDLE; 10 s apart, 6 tries), so a peer that vanished is
        /// found within about two minutes. Null: off.
        keepalive: ?Duration = .fromSeconds(60),
        /// The PROXY header and the TLS handshake, together.
        handshake_timeout: ?Duration = .fromSeconds(10),
        /// No input for this long closes the connection (reason `.idle`).
        /// Null: never (keep-alive still finds dead peers).
        idle_timeout: ?Duration = null,
        /// The longest a connection may stay open (reason `.lifetime`).
        lifetime: ?Duration = null,
        /// A flush the peer does not take for this long closes the
        /// connection (reason `.write_timeout`).
        write_timeout: ?Duration = .fromSeconds(30),
        /// Past this many queued bytes `send` answers `.busy` (and
        /// `writable` follows once under half).
        write_high_water: u32 = 256 * 1024,
        /// Past this many, `send` takes nothing (`error.QueueFull`).
        write_max: u32 = 8 * 1024 * 1024,
        /// The read buffer of each burst, on its task's stack (4 KiB to
        /// 64 KiB). A frame larger than it is gathered on the heap.
        read_window: u32 = 16 * 1024,
        /// C ABI: bytes of one connection posted and not yet polled, at most.
        read_ahead: u32 = 256 * 1024,
        /// Open connections on this listener, at most (the server's
        /// `limits.max_connections` still bounds them all). Null: no own cap.
        max_connections: ?u32 = null,
        /// One log line (scope `access`) per closed connection: listener,
        /// remote, duration, bytes in and out, reason.
        log_connections: bool = false,

        /// Why `options` cannot be served, if so.
        pub fn check(o: Options) error{InvalidFraming}!void {
            try o.framing.validate();
            if (o.read_window < 4096 or o.read_window > 65536) return error.InvalidFraming;
        }
    };
};

/// What one burst read: raw bytes (`Framing.none`), or whole frames.
pub const Input = union(enum) {
    bytes: []const u8,
    frames: *FrameIterator,
};

/// The callbacks behind plain function pointers, for the C ABI (as
/// `websocket.Table`). `task` set: the task form, the rest unused.
pub const TcpTable = struct {
    open: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    data: ?*const fn (state: ?*anyopaque, *Conn, Input) anyerror!void = null,
    end: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    writable: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    drain: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    close: ?*const fn (state: ?*anyopaque, *Conn, CloseReason) void = null,
    task: ?*const fn (state: ?*anyopaque, *Conn) anyerror!void = null,
    /// A borrowed write (`Conn.sendBorrowed`) was written or dropped.
    sent: ?*const fn (state: ?*anyopaque, *Conn, token: u64) void = null,
    /// Size and alignment of `Handler.State` (0: none) and its init/deinit.
    state_size: u32 = 0,
    state_align: u8 = 1,
    state_init: ?*const fn (*anyopaque) void = null,
    state_deinit: ?*const fn (*anyopaque) void = null,
    /// The callbacks never wait (the C ABI's post events): they may run on
    /// the net driver and in any order with one another, instead of on a
    /// task of their own one at a time.
    inline_events: bool = false,
};

/// A TCP service for `Listener.tcp`: what `app.tcp` builds.
pub const TcpService = struct {
    table: *const TcpTable,
    options: Tcp.Options,
    /// `@typeName(Ctx)`; the server refuses a mismatch (`NetHandlerContext`).
    ctx_type: []const u8,
    /// Set by the server: its `*Ctx`, or the C ABI's engine.
    state: ?*anyopaque = null,
};

/// A TCP service for `Listener.tcp`. `handler` is a callbacks type (see
/// docs/net.md) or a function `fn (*Conn) !void` that serves one
/// connection on a task of its own, either with the server's `*Ctx`
/// first. Callbacks run one at a time on a task on the connection's
/// executor, and may wait; an idle connection holds no task. Each callback
/// may take the server's `*Ctx` first; with a framing, `message(conn,
/// frame)` is called for each whole frame, else `data(conn, bytes)`.
pub fn tcp(comptime Ctx: type, comptime handler: anytype, comptime options: Tcp.Options) TcpService {
    comptime {
        options.check() catch @compileError("anole.net.tcp: the options are not valid: a framing max of 1 byte to 1 GiB, a read_window of 4 KiB to 64 KiB");
    }
    const H = Hooks(Ctx, handler, options.framing);
    return .{
        .table = &H.table,
        .options = options,
        .ctx_type = @typeName(Ctx),
    };
}

fn Hooks(comptime Ctx: type, comptime handler: anytype, comptime framing: Framing) type {
    const is_fn = @typeInfo(@TypeOf(handler)) == .@"fn";
    return struct {
        const table: TcpTable = build();

        fn build() TcpTable {
            var t: TcpTable = .{};
            if (is_fn) {
                t.task = task;
                return t;
            }
            const H = handler;
            if (framing == .none) {
                if (!@hasDecl(H, "data")) @compileError("anole.net.tcp: " ++ @typeName(H) ++ " has no data(conn, bytes), which framing .none calls");
            } else if (!@hasDecl(H, "message")) {
                @compileError("anole.net.tcp: " ++ @typeName(H) ++ " has no message(conn, frame), which framing ." ++ @tagName(framing) ++ " calls");
            }
            if (@hasDecl(H, "open")) t.open = open;
            t.data = data;
            if (@hasDecl(H, "end")) t.end = end;
            if (@hasDecl(H, "writable")) t.writable = writable;
            if (@hasDecl(H, "drain")) t.drain = drain;
            if (@hasDecl(H, "close")) t.close = close;
            if (@hasDecl(H, "State")) {
                t.state_size = @sizeOf(H.State);
                t.state_align = @alignOf(H.State);
                t.state_init = stateInit;
                if (@hasDecl(H.State, "deinit")) t.state_deinit = stateDeinit;
            }
            return t;
        }

        fn arity(comptime f: anytype, comptime plain: usize, comptime name: []const u8) bool {
            const n = @typeInfo(@TypeOf(f)).@"fn".param_types.len;
            if (n == plain) return false;
            if (n == plain + 1 and Ctx != void) return true;
            @compileError("anole.net callback " ++ name ++ " has the wrong parameters: " ++ @typeName(@TypeOf(f)));
        }

        fn ctxOf(state: ?*anyopaque) *Ctx {
            return @ptrCast(@alignCast(state.?));
        }

        fn task(state: ?*anyopaque, conn: *Conn) anyerror!void {
            return if (comptime arity(handler, 1, "task")) handler(ctxOf(state), conn) else handler(conn);
        }

        fn open(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.open;
            return if (comptime arity(f, 1, "open")) f(ctxOf(state), conn) else f(conn);
        }

        fn data(state: ?*anyopaque, conn: *Conn, input: Input) anyerror!void {
            switch (input) {
                .bytes => |b| {
                    if (comptime framing != .none) return;
                    const f = handler.data;
                    return if (comptime arity(f, 2, "data")) f(ctxOf(state), conn, b) else f(conn, b);
                },
                .frames => |it| {
                    if (comptime framing == .none) return;
                    const f = handler.message;
                    while (it.next()) |frame| {
                        try if (comptime arity(f, 2, "message")) f(ctxOf(state), conn, frame) else f(conn, frame);
                    }
                },
            }
        }

        fn end(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.end;
            return if (comptime arity(f, 1, "end")) f(ctxOf(state), conn) else f(conn);
        }

        fn writable(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.writable;
            return if (comptime arity(f, 1, "writable")) f(ctxOf(state), conn) else f(conn);
        }

        fn drain(state: ?*anyopaque, conn: *Conn) anyerror!void {
            const f = handler.drain;
            return if (comptime arity(f, 1, "drain")) f(ctxOf(state), conn) else f(conn);
        }

        fn close(state: ?*anyopaque, conn: *Conn, reason: CloseReason) void {
            const f = handler.close;
            return if (comptime arity(f, 2, "close")) f(ctxOf(state), conn, reason) else f(conn, reason);
        }

        fn stateInit(p: *anyopaque) void {
            const s: *handler.State = @ptrCast(@alignCast(p));
            s.* = .{};
        }

        fn stateDeinit(p: *anyopaque) void {
            const s: *handler.State = @ptrCast(@alignCast(p));
            s.deinit();
        }
    };
}

// ---------------------------------------------------------------------------
// The public connection

/// One TCP connection, as a handler sees it.
pub const Conn = struct {
    /// Free for the handler: what it keeps per connection (`State`'s
    /// instance when the handler declares one).
    context: ?*anyopaque = null,

    fn tc(c: *const Conn) *TcpConn {
        return @alignCast(@constCast(@fieldParentPtr("conn", c)));
    }

    pub fn contextAs(c: *const Conn, comptime T: type) *T {
        return @ptrCast(@alignCast(c.context.?));
    }

    /// Unique in the process; never reused (log lines, maps).
    pub fn id(c: *const Conn) u64 {
        return c.tc().id;
    }

    /// The client: the PROXY header's source when proxied, else the peer.
    /// Null on a unix socket (and for a PROXY LOCAL health check over one).
    pub fn remote(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.info.listener.address == .unix) return t.connection.proxied_peer;
        return t.connection.peerAddress();
    }

    /// The socket's own peer (the proxy, when proxied).
    pub fn direct(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.info.listener.address == .unix) return null;
        return dusty.unmapIpv4(t.connection.stream.socket.address);
    }

    /// The address the client connected to (the PROXY header's destination
    /// when proxied).
    pub fn local(c: *const Conn) ?std.Io.net.IpAddress {
        const t = c.tc();
        if (t.connection.proxied_local) |a| return dusty.unmapIpv4(a);
        if (t.info.listener.address == .unix) return null;
        if (t.local_cache) |a| return a;
        t.local_cache = socketName(t.connection.stream.socket.handle);
        return t.local_cache;
    }

    pub fn listener(c: *const Conn) []const u8 {
        return c.tc().info.listener.name;
    }

    /// TLS on this listener, or (proxied) the PROXY v2 SSL TLV.
    pub fn secure(c: *const Conn) bool {
        const t = c.tc();
        return t.info.listener.tls != null or t.connection.proxied_secure;
    }

    pub fn alpn(c: *const Conn) ?[]const u8 {
        return c.tc().connection.negotiatedProtocol();
    }

    /// SNI: the name the client asked for in its TLS ClientHello.
    pub fn serverName(c: *const Conn) ?[]const u8 {
        return c.tc().connection.serverName();
    }

    /// Mutual TLS: the client's certificate (DER), verified.
    pub fn peerCertificate(c: *const Conn) ?[]const u8 {
        return c.tc().connection.peerCertificate();
    }

    /// TLS on this connection itself (not just the PROXY v2 SSL TLV).
    pub fn isTls(c: *const Conn) bool {
        return c.tc().connection.tls_conn != null;
    }

    /// Its addresses came from a PROXY header.
    pub fn proxied(c: *const Conn) bool {
        const t = c.tc();
        return t.connection.proxied_peer != null or t.connection.proxied_local != null;
    }

    pub fn isUnix(c: *const Conn) bool {
        return c.tc().info.listener.address == .unix;
    }

    /// What the connection moved so far, for the end-of-life records.
    pub const Totals = struct { bytes_in: u64, bytes_out: u64, duration_ms: u64, errno: i32 };

    pub fn totals(c: *const Conn) Totals {
        const t = c.tc();
        const now = std.Io.Clock.Timestamp.now(t.io, .awake);
        const ms = @divTrunc(t.opened_at.durationTo(now).raw.nanoseconds, std.time.ns_per_ms);
        return .{
            .bytes_in = t.bytes_in,
            .bytes_out = t.bytes_out.load(.monotonic),
            .duration_ms = @intCast(@max(0, ms)),
            .errno = t.errno_value.load(.monotonic),
        };
    }

    pub const Sent = enum { ok, busy };
    pub const SendError = error{
        /// The connection is over.
        Closed,
        /// This side was ended (`end`).
        Ended,
        /// No room now (the queue would pass `write_max`): nothing taken;
        /// `writable` / `waitWritable` follow.
        QueueFull,
        /// More than `write_max` bytes in one send (its framing included):
        /// never taken, now or later, so no `writable` follows for it.
        TooLarge,
        /// `sendFrame` with a payload over the framing's `max`.
        FrameTooLarge,
        /// `sendFrame` on a listener with `Framing.none`.
        NoFraming,
        OutOfMemory,
    };

    /// `queueChunk`'s answer: the wake to make once the caller's own lock
    /// is let go (null: none due), and whether the chunk was taken (an
    /// empty one is not: the caller frees it, after its lock).
    pub const Queued = struct { sent: Sent, kick: ?Kick, taken: bool = true };

    /// Queues `bytes` (copied) and returns: any task, any executor, any
    /// time; never waits. Sent in order with this connection's other sends.
    /// From a task on the connection's executor small sends share one
    /// allocation; from elsewhere each costs one.
    pub fn send(c: *Conn, bytes: []const u8) SendError!Sent {
        return c.tc().queue(&.{bytes}, 0);
    }

    /// `send` with the listener's framing around `payload`, in one piece
    /// (never interleaved with another task's send).
    pub fn sendFrame(c: *Conn, payload: []const u8) SendError!Sent {
        const t = c.tc();
        var pbuf: [Framing.max_prefix]u8 = undefined;
        const prefix = try t.service.options.framing.prefix(payload.len, &pbuf);
        return t.queue(&.{ prefix, payload, t.service.options.framing.suffix() }, 0);
    }

    /// `send` without a copy: `bytes` must stay valid until `sent` (the
    /// table's) says `token` was written or dropped. For the C ABI.
    pub fn sendBorrowed(c: *Conn, bytes: []const u8, token: u64) SendError!Sent {
        return c.tc().queue(&.{bytes}, token);
    }

    /// Bytes queued and not yet written.
    /// Test builds: the bytes the connection's spare send chunk holds (0:
    /// none). On its executor, with nothing being sent.
    pub fn testSpare(c: *const Conn) usize {
        if (!builtin.is_test) @compileError("Conn.testSpare is for tests");
        const t = c.tc();
        return if (t.spare) |sp| sp.capacity() else 0;
    }

    pub fn queued(c: *const Conn) usize {
        return c.tc().queued.load(.acquire);
    }

    /// Waits until fewer than half `write_high_water` bytes are queued.
    /// `error.Closed` when it closes meanwhile. Any task may call it until
    /// the `close` callback returns; one still waiting then answers Closed
    /// (the connection is freed only after it left). After Closed the
    /// caller must not touch the `Conn` again, and a call that starts after
    /// the close callback returned is a use-after-free (the caller's side
    /// of the contract).
    pub fn waitWritable(c: *Conn) error{ Closed, Canceled }!void {
        return c.tc().waitUnder(c.tc().service.options.write_high_water / 2);
    }

    /// Ends this side once what is queued is out (TLS close_notify, then
    /// FIN). Reading goes on until the peer ends too (or `close`).
    pub fn end(c: *Conn) void {
        c.tc().requestEnd(false);
    }

    /// Closes once what is queued is out: this side ends, input is read and
    /// dropped until the peer ends or 2 s pass, then the socket closes.
    pub fn close(c: *Conn) void {
        c.tc().requestEnd(true);
    }

    /// Closes now with a reset (SO_LINGER 0); what is queued is dropped.
    pub fn reset(c: *Conn) void {
        if (c.tc().resetKick()) |k| k.run();
    }

    /// For the C ABI: queues `chunk` (an `OutChunk.create` whose payload
    /// the caller filled, or an `OutChunk.borrowed`), with the listener's
    /// framing around it when `frame`. Takes the chunk on success (unless
    /// `taken` says otherwise); on an error it stays the caller's. Never
    /// allocates, frees or waits, so a caller may hold a spin lock (L5):
    /// it frees a chunk left to it, and makes the returned wake, after.
    pub fn queueChunk(c: *Conn, chunk: *OutChunk, frame: bool) SendError!Queued {
        const t = c.tc();
        const f = t.flags.load(.acquire);
        if (f & (Flag.closed | Flag.dead | Flag.ended) != 0) {
            return if (f & (Flag.closed | Flag.dead) != 0) error.Closed else error.Ended;
        }
        if (frame) {
            std.debug.assert(chunk.owned and chunk.off == Framing.max_prefix);
            const framing = t.service.options.framing;
            var pbuf: [Framing.max_prefix]u8 = undefined;
            const prefix = try framing.prefix(chunk.cap, &pbuf);
            const suffix = framing.suffix();
            chunk.off = Framing.max_prefix - prefix.len;
            @memcpy(chunk.region[chunk.off..][0..prefix.len], prefix);
            @memcpy(chunk.region[Framing.max_prefix + chunk.cap ..][0..suffix.len], suffix);
            chunk.len = prefix.len + chunk.cap + suffix.len;
        }
        if (chunk.len == 0) return .{ .sent = .ok, .kick = null, .taken = false };
        return t.pushChunk(chunk);
    }

    /// For the C ABI: `end`, `close` and `reset`, whose wake is returned
    /// (see `queueChunk`).
    pub fn endKick(c: *Conn) ?Kick {
        return c.tc().requestEndKick(false);
    }

    pub fn closeKick(c: *Conn) ?Kick {
        return c.tc().requestEndKick(true);
    }

    pub fn resetKick(c: *Conn) ?Kick {
        return c.tc().resetKick();
    }

    /// Stops reading (Anole leaves the input in the kernel: TCP flow
    /// control slows the peer) until `resumeReading`. Holds the connection's
    /// task while paused, and a paused connection never idles out
    /// (`idle_timeout` counts input it reads; `lifetime`, a reset, a close
    /// or the stop still end it). After the connection ended, nothing.
    pub fn pauseReading(c: *Conn) void {
        _ = c.tc().paused.cmpxchgStrong(Paused.reading, Paused.paused, .acq_rel, .monotonic);
    }

    pub fn resumeReading(c: *Conn) void {
        const t = c.tc();
        if (t.paused.cmpxchgStrong(Paused.paused, Paused.reading, .acq_rel, .monotonic) == null) t.wakeAll(&t.paused);
    }

    /// Replaces the listener's `idle_timeout` for this connection (null: none).
    pub fn setIdleTimeout(c: *Conn, timeout: ?Duration) void {
        c.tc().idle_ns.store(if (timeout) |d| @intCast(d.nanoseconds) else -1, .release);
    }

    /// The server is draining: say goodbye and close.
    pub fn draining(c: *const Conn) bool {
        return c.tc().info.draining.isSet();
    }

    /// The server's drain event (set once, never reset), for a task-form
    /// handler to wait on beside its reads.
    pub fn drainEvent(c: *const Conn) *std.Io.Event {
        return c.tc().info.draining;
    }

    // The task form only (`fn (*Conn) !void`), on the handler's own task.

    /// The connection's input, buffered (`read_window` bytes on the heap).
    pub fn reader(c: *Conn) *std.Io.Reader {
        return c.tc().connection.reader;
    }

    pub const ReadError = error{ Closed, FrameTooLarge, InvalidFrame, IdleTimeout, Canceled, NotTaskForm, OutOfMemory };

    /// The next frame by the listener's framing (valid until the next
    /// read), or null when the peer ended its side. `Framing.none`: what
    /// is buffered (at least one byte).
    pub fn readFrame(c: *Conn) ReadError!?[]const u8 {
        return c.tc().readFrameTask();
    }

    pub const WriteError = error{ Closed, Ended, WriteTimeout, Canceled, NotTaskForm, OutOfMemory, TooLarge };

    /// `send`, waiting first while past `write_high_water`: back-pressure by
    /// waiting, which only the connection's own task may do.
    pub fn write(c: *Conn, bytes: []const u8) WriteError!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitOpen(t.service.options.write_high_water);
        _ = t.queue(&.{bytes}, 0) catch |err| return sendToWrite(err);
    }

    pub fn writeFrame(c: *Conn, payload: []const u8) (WriteError || error{ FrameTooLarge, NoFraming })!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitOpen(t.service.options.write_high_water);
        var pbuf: [Framing.max_prefix]u8 = undefined;
        const prefix = try t.service.options.framing.prefix(payload.len, &pbuf);
        _ = t.queue(&.{ prefix, payload, t.service.options.framing.suffix() }, 0) catch |err| switch (err) {
            error.FrameTooLarge => return error.FrameTooLarge,
            error.NoFraming => return error.NoFraming,
            else => |e| return sendToWrite(e),
        };
    }

    /// Waits until everything queued is written (or `write_timeout`).
    pub fn flush(c: *Conn) WriteError!void {
        const t = c.tc();
        if (!t.task_form) return error.NotTaskForm;
        try t.waitUnder(1);
    }

    /// A buffered writer (`read_window` bytes) whose drains go to `send`:
    /// for `print`. A message longer than the buffer may interleave with
    /// sends from other tasks; `send` a whole message for that.
    pub fn writer(c: *Conn) *std.Io.Writer {
        return &c.tc().task_writer.interface;
    }
};

fn sendToWrite(err: Conn.SendError) Conn.WriteError {
    return switch (err) {
        error.Closed => error.Closed,
        error.Ended => error.Ended,
        error.OutOfMemory => error.OutOfMemory,
        // Full although the task waited under the high-water mark: sends
        // from other tasks or threads filled the queue in between (a race
        // with a foreign send), reported as WriteTimeout. A message that
        // can never fit is TooLarge.
        error.QueueFull => error.WriteTimeout,
        error.TooLarge => error.TooLarge,
        error.FrameTooLarge, error.NoFraming => error.Closed,
    };
}

// ---------------------------------------------------------------------------
// The listener

/// Counters over one TCP listener's connections.
pub const ListenerStats = struct {
    open: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    bytes_in: std.atomic.Value(u64) = .init(0),
    bytes_out: std.atomic.Value(u64) = .init(0),
    queue_full: std.atomic.Value(u64) = .init(0),
    closes: [std.enums.values(CloseReason).len]std.atomic.Value(u64) = @splat(.init(0)),
};

var next_conn_id: std.atomic.Value(u64) = .init(1);

/// A raw TCP listener's service and per-executor drivers: the object behind
/// `http.Listener.raw`. owner: the server, which makes it (`create`) and
/// frees it (`destroy`) after the core has stopped (M2: process-wide).
pub const TcpListener = struct {
    raw: dusty.Raw,
    gpa: std.mem.Allocator,
    service: TcpService,
    /// One per executor (on zio the core's accept loops map 1:1 onto them).
    drivers: []Driver,
    stats: ListenerStats = .{},
    /// The Prometheus series, set before serving when the app has metrics.
    series: ?*net_metrics.TcpSeries = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, service: TcpService) !*TcpListener {
        const self = try gpa.create(TcpListener);
        errdefer gpa.destroy(self);
        const n = @max(1, placement.executorCount(io) orelse 1);
        const drivers = try gpa.alloc(Driver, n);
        for (drivers) |*d| d.* = .{};
        self.* = .{ .raw = .{ .start = start }, .gpa = gpa, .service = service, .drivers = drivers };
        return self;
    }

    pub fn destroy(self: *TcpListener) void {
        const gpa = self.gpa;
        for (self.drivers) |*d| d.slots.deinit(gpa);
        gpa.free(self.drivers);
        gpa.destroy(self);
    }

    /// The driver of the caller's executor, started by its first
    /// connection. No lock (T3): only this executor's connections call it.
    /// `started` is set before the spawn, which can suspend (zio's spawn
    /// backpressure yields the spawner): a connection opening meanwhile
    /// finds the driver started, not a second one. A spawn that fails has
    /// not suspended (zio fails before it yields), so the rollback is seen
    /// by nobody.
    fn driverFor(self: *TcpListener, info: *const dusty.RawInfo) !*Driver {
        const d = &self.drivers[info.executor % self.drivers.len];
        if (d.started) {
            d.owner.check(info.io);
            return d;
        }
        d.io = info.io;
        d.owner = .here(info.io);
        d.started = true;
        placement.concurrent(info.group, info.io, .local, Driver.run, .{d}) catch |err| {
            d.started = false;
            return err;
        };
        testHold(info.io, .driver_start);
        return d;
    }

    fn start(raw: *const dusty.Raw, connection: *dusty.Connection, info: *const dusty.RawInfo) anyerror!?*dusty.Adopter {
        const self: *TcpListener = @alignCast(@constCast(@fieldParentPtr("raw", raw)));
        return TcpConn.open(self, connection, info);
    }
};

// ---------------------------------------------------------------------------
// The net driver

/// One per executor and listener: writes the outboxes kicked since its last
/// round, and starts the connections' drain callbacks. owner: its
/// `TcpListener` (process-wide memory); it runs on one executor and only
/// there (T3), set by the first `driverFor`. Its task lives in the server's
/// connection group and ends with it.
///
/// It reaches connections only through their kick slots (T4), which it
/// resolves on its own executor: a kick from any thread touches the slot,
/// never the connection.
const Driver = struct {
    owner: safety.Owner = .none,
    /// Started (`driverFor`, its executor only).
    started: bool = false,
    io: std.Io = undefined,
    /// The slots kicked from any thread; owner: `run`.
    kicks: push_list.PushList = .{},
    signal: placement.Signal = .{},
    /// Every wake of this driver, and of its connections' tasks, from off
    /// its executor goes through it (T5); closed when `run` ends.
    gate: safety.IoGate = .{},
    /// Its connections' kick slots (its executor only).
    slots: KickSlots = .{},

    /// Any thread: `s`'s connection wants the driver. A slot already
    /// waiting is not pushed again; a kick after the driver ended is
    /// dropped (its connections are being released).
    fn kick(d: *Driver, s: *KickSlot) void {
        if (s.kicked.swap(true, .seq_cst)) return;
        const was_empty = d.kicks.push(&s.node) catch return;
        if (was_empty) d.wake();
    }

    fn wake(d: *Driver) void {
        if (!d.gate.enter()) return;
        defer d.gate.leave();
        d.signal.set(d.io);
    }

    fn run(d: *Driver) std.Io.Cancelable!void {
        if (builtin.is_test) _ = test_driver_runs.fetchAdd(1, .monotonic);
        defer {
            // Waits out a kick inside the gate (libuv's `uv__async_spin`),
            // then refuses later ones. What is left is dropped: each
            // connection's `release` drops its own outbox.
            d.gate.close();
            _ = d.kicks.seal();
        }
        while (true) {
            try d.signal.wait(d.io);
            d.signal.reset(d.io);
            var it = d.kicks.takeAll();
            while (it) |n| {
                // Read before the slot can be pushed again.
                it = n.next;
                const s = KickSlot.of(n);
                s.kicked.store(false, .seq_cst);
                testHold(d.io, .driver_turn);
                const t = s.conn orelse continue;
                t.serviceKick();
                // Nothing of `t` after this: the service may have suspended
                // in a spawn, and `t` may be gone (it checks, `spawn`).
            }
        }
    }
};

/// A connection's place on its driver. It outlives the connection (nginx's
/// reusable connection with a stale-event check): a kick from any thread
/// touches only this, and the driver services whoever occupies it when it
/// pops it (an empty slot is skipped, a recycled one gets a harmless extra
/// round). owner: its driver's `KickSlots`; stable memory, freed only by
/// `TcpListener.destroy`.
const KickSlot = struct {
    node: push_list.Node = .{},
    /// On the driver's list, or about to be: never pushed twice.
    kicked: std.atomic.Value(bool) = .init(false),
    /// The connection in it (driver's executor only).
    conn: ?*TcpConn = null,
    /// Bumped each time the slot is emptied (driver's executor only): with
    /// `conn`, tells whether the connection seen before a suspension is
    /// still the one in it after (`TcpConn.spawn`), even when a new
    /// connection got the same address and the same slot.
    gen: u32 = 0,
    next_free: ?*KickSlot = null,

    fn of(n: *push_list.Node) *KickSlot {
        return @fieldParentPtr("node", n);
    }
};

/// A driver's kick slots, 64 to a chunk; its executor only.
const KickSlots = struct {
    chunks: ?*Chunk = null,
    free_list: ?*KickSlot = null,

    const Chunk = struct {
        slots: [64]KickSlot = @splat(.{}),
        next: ?*Chunk = null,
    };

    fn alloc(ks: *KickSlots, gpa: std.mem.Allocator) error{OutOfMemory}!*KickSlot {
        if (ks.free_list == null) {
            const c = try gpa.create(Chunk);
            c.* = .{ .next = ks.chunks };
            ks.chunks = c;
            for (&c.slots) |*s| {
                s.next_free = ks.free_list;
                ks.free_list = s;
            }
        }
        const s = ks.free_list.?;
        ks.free_list = s.next_free;
        s.next_free = null;
        return s;
    }

    /// Empties the slot; it may still be on the driver's list.
    fn free(ks: *KickSlots, s: *KickSlot) void {
        s.conn = null;
        s.gen +%= 1;
        s.next_free = ks.free_list;
        ks.free_list = s;
    }

    fn deinit(ks: *KickSlots, gpa: std.mem.Allocator) void {
        while (ks.chunks) |c| {
            ks.chunks = c.next;
            gpa.destroy(c);
        }
        ks.free_list = null;
    }
};

/// The wake a call made under its own lock leaves for its caller to make
/// after it lets go (the C ABI's slot lock): the connection's driver looks
/// at it. Touches only the driver and the kick slot (stable memory), so it
/// may run after the connection is gone.
pub const Kick = struct {
    driver: *Driver,
    slot: *KickSlot,

    pub fn run(k: Kick) void {
        k.driver.kick(k.slot);
    }
};

// ---------------------------------------------------------------------------
// One connection

/// One send's bytes, made before anything shared is touched (L5): what a
/// send copies into, or (borrowed) what the C ABI lends. An owned chunk is
/// one allocation: this header, then `Framing.max_prefix` bytes of room, the
/// payload, and room for a suffix, so a frame's prefix and suffix are
/// written around the payload later (`Conn.queueChunk`). owner: the sender
/// until a queue call takes it (on success; a refused one stays the
/// sender's, freed after any lock it holds); then the connection's outbox,
/// which frees it once written or dropped.
pub const OutChunk = struct {
    node: push_list.Node = .{},
    /// The outbox's order (the connection's executor).
    next: ?*OutChunk = null,
    gpa: std.mem.Allocator,
    /// Owned: the bytes after the header; borrowed: the lender's.
    region: [*]u8,
    /// Bytes of `region`.
    size: usize,
    /// The bytes not written yet: `region[off..][0..len]`.
    off: usize,
    len: usize,
    /// The payload's size (`payload`).
    cap: usize,
    owned: bool,
    /// Made by `fresh` (an owner-executor send): the only kind kept as a
    /// connection's spare, since only that path takes it back.
    local: bool = false,
    /// Borrowed: the `sent` token.
    token: u64 = 0,

    const max_suffix = 2;
    const header = std.mem.alignForward(usize, @sizeOf(OutChunk), @alignOf(OutChunk));
    /// The room of an owner-executor send's first chunk: 16 KiB of
    /// payload (plus the header and the frame room), so a 16 KiB message
    /// fits one.
    pub const standard_room = 16 * 1024;
    /// Its region (what `fresh` is asked for).
    const standard_region = Framing.max_prefix + standard_room + max_suffix;
    /// The largest chunk a connection keeps as its spare, by region size:
    /// the listener's high-water mark, at least a standard chunk, at most
    /// 64 KiB. A message bigger than the high-water mark makes the
    /// connection busy by itself, and past 64 KiB the copy costs more than
    /// the allocation, while every busy connection may hold one spare.
    pub fn spareMax(write_high_water: u32) usize {
        return @min(64 * 1024, @max(standard_region, write_high_water));
    }

    /// An owned chunk whose payload (`payload()`, `payload_len` bytes) the
    /// caller fills.
    pub fn create(gpa: std.mem.Allocator, payload_len: usize) error{OutOfMemory}!*OutChunk {
        return make(gpa, payload_len, Framing.max_prefix, payload_len);
    }

    /// An empty owned chunk with room for `room_len` bytes from its start
    /// (the owner executor's sends, coalesced into it): its region is
    /// `room_len` bytes (at least the frame room).
    fn fresh(gpa: std.mem.Allocator, room_len: usize) error{OutOfMemory}!*OutChunk {
        const c = try make(gpa, room_len -| (Framing.max_prefix + max_suffix), 0, 0);
        c.local = true;
        return c;
    }

    fn make(gpa: std.mem.Allocator, cap: usize, off: usize, len: usize) error{OutOfMemory}!*OutChunk {
        const size = Framing.max_prefix + cap + max_suffix;
        const bytes = try gpa.alignedAlloc(u8, .of(OutChunk), header + size);
        // SAFETY: `bytes` is aligned for an OutChunk and starts with `header` bytes for one.
        const c: *OutChunk = @ptrCast(bytes.ptr);
        c.* = .{ .gpa = gpa, .region = bytes[header..].ptr, .size = size, .off = off, .len = len, .cap = cap, .owned = true };
        return c;
    }

    /// A chunk over `bytes` without a copy: they stay valid until `sent`
    /// reports `token`.
    pub fn borrowed(gpa: std.mem.Allocator, bytes: []const u8, token: u64) error{OutOfMemory}!*OutChunk {
        const c = try gpa.create(OutChunk);
        c.* = .{ .gpa = gpa, .region = @constCast(bytes.ptr), .size = bytes.len, .off = 0, .len = bytes.len, .cap = bytes.len, .owned = false, .token = token };
        return c;
    }

    /// The payload of a chunk from `create`, to fill.
    pub fn payload(c: *OutChunk) []u8 {
        return c.region[Framing.max_prefix..][0..c.cap];
    }

    fn unsent(c: *const OutChunk) []const u8 {
        return c.region[c.off..][0..c.len];
    }

    /// Free room after the bytes (owned chunks only).
    fn room(c: *const OutChunk) usize {
        if (!c.owned) return 0;
        return c.size - (c.off + c.len);
    }

    fn append(c: *OutChunk, parts: []const []const u8) void {
        var at = c.off + c.len;
        for (parts) |p| {
            @memcpy(c.region[at..][0..p.len], p);
            at += p.len;
        }
        c.len = at - c.off;
    }

    pub fn destroy(c: *OutChunk) void {
        const gpa = c.gpa;
        if (!c.owned) return gpa.destroy(c);
        const total = header + c.size;
        // SAFETY: an owned chunk's header starts the allocation `make` made, `header + size` bytes aligned for an OutChunk.
        const base: [*]align(@alignOf(OutChunk)) u8 = @ptrCast(c);
        gpa.free(base[0..total]);
    }

    fn of(n: *push_list.Node) *OutChunk {
        return @fieldParentPtr("node", n);
    }

    /// The bytes an owned chunk holds from its start (`fresh` writes from
    /// offset 0): its whole region.
    fn capacity(c: *const OutChunk) usize {
        return c.size;
    }

    /// A written chunk, emptied for the next sends.
    fn reset(c: *OutChunk) void {
        c.node = .{};
        c.next = null;
        c.off = 0;
        c.len = 0;
        c.token = 0;
    }
};

/// A connection's chunks in write order (its executor only).
const Fifo = struct {
    head: ?*OutChunk = null,
    tail: ?*OutChunk = null,

    fn isEmpty(f: *const Fifo) bool {
        return f.head == null;
    }

    fn append(f: *Fifo, c: *OutChunk) void {
        c.next = null;
        if (f.tail) |t| t.next = c else f.head = c;
        f.tail = c;
    }

    fn pop(f: *Fifo) ?*OutChunk {
        const c = f.head orelse return null;
        f.head = c.next;
        if (f.head == null) f.tail = null;
        c.next = null;
        return c;
    }
};

/// `TcpConn.flags`.
const Flag = struct {
    /// Released: no send is taken, no helper spawned.
    const closed: u32 = 1 << 0;
    /// Reset or failed: nothing more is written.
    const dead: u32 = 1 << 1;
    /// This side was ended (`end`, `close`): no send is taken.
    const ended: u32 = 1 << 2;
    /// A send was told busy or QueueFull: `writable` follows the drain.
    const want_writable: u32 = 1 << 3;
    /// The server's drain reached it: the driver starts `drain`.
    const drain_pending: u32 = 1 << 4;
    /// Windows: the reading task is to be canceled (by the driver, on the
    /// connection's executor).
    const cancel_reader: u32 = 1 << 5;
};

/// `TcpConn.paused`. `ended` is sticky: set when the connection ends, it
/// makes a later `pauseReading` change nothing, so the task waiting for a
/// resume (`waitResumed`), which looked at `over` before it waits on this
/// word, sees the word changed and never sleeps on a connection that is
/// over.
const Paused = struct {
    const reading: u32 = 0;
    const paused: u32 = 1;
    const ended: u32 = 2;
};

/// `TcpConn.sched`: who is responsible for the outbox.
const Sched = struct {
    const none: u8 = 0;
    /// Kicked: the driver, on its next round.
    const driver: u8 = 1;
    /// A flusher task.
    const flusher: u8 = 2;
};

/// One raw TCP connection. owner: the core's connection (an `Adopter`,
/// released by it, M2: a child of its owner); its executor is the
/// connection's (T3): every helper task is a child in `group`, spawned
/// there. Applications hold `*Conn` by contract until `close` returns
/// (docs/net.md §1), from any thread.
const TcpConn = struct {
    adopter: dusty.Adopter,
    conn: Conn = .{},
    listener: *TcpListener,
    service: *const TcpService,
    connection: *dusty.Connection,
    info: dusty.RawInfo,
    io: std.Io,
    gpa: std.mem.Allocator,
    driver: *Driver,
    owner: safety.Owner,
    /// The connection's executor, for the sends' fast path (null off zio:
    /// never taken).
    exec: ?usize,
    /// Its place on the driver (stable memory).
    kick: *KickSlot,
    id: u64,
    drain_hook: dusty.DrainHooks.Hook,
    state_buf: []align(16) u8 = &.{},
    task_form: bool,
    local_cache: ?std.Io.net.IpAddress = null,

    // Writing, from any thread: atomics and the inbox, no lock.
    /// `Flag` bits; fetchOr / load.
    flags: std.atomic.Value(u32) = .init(0),
    /// Bytes queued and not yet written (reserved, in the inbox, the outbox
    /// and the batch): reserved with a compare-and-swap bounded by
    /// `write_max`.
    queued: std.atomic.Value(u32) = .init(0),
    /// Writers in `waitUnder`, and the futex word they wait on: moved by
    /// `wakeWaiters` (bytes left, the connection ended), never by a send.
    waiters: std.atomic.Value(u32) = .init(0),
    epoch: std.atomic.Value(u32) = .init(0),
    /// Sends made off the connection's executor; owner: the responsible
    /// party, which moves them to `out`. Sealed by `release`.
    inbox: push_list.PushList = .{},
    /// `Sched`: one party at a time is responsible for the outbox, so
    /// bytes leave in send order.
    sched: std.atomic.Value(u8) = .init(Sched.none),
    // The connection's executor only (no lock: one executor, and nothing
    // between a check and its use suspends).
    /// Queued, not yet taken as a batch.
    out: Fifo = .{},
    /// The batch being written (the responsible party's).
    inflight: Fifo = .{},
    /// One written chunk kept for the next sends (an echo then allocates
    /// nothing): the biggest an owner send made, up to `OutChunk.spareMax`.
    /// owner: the connection (M2), its executor only, no atomics; freed
    /// when it parks (and not refilled while parked) and at `release`.
    /// Sends from other threads and the C ABI make their own chunks.
    spare: ?*OutChunk = null,
    /// Parked: no task, no spare (its executor only).
    parked: bool = false,
    /// The helper tasks (flusher, writable, drain): children of the
    /// connection (T1), canceled and joined by `release`.
    group: std.Io.Group = .init,

    // State flags.
    end_requested: std.atomic.Value(bool) = .init(false),
    end_done: std.atomic.Value(bool) = .init(false),
    close_graceful: std.atomic.Value(bool) = .init(false),
    peer_ended: std.atomic.Value(bool) = .init(false),
    reset_requested: std.atomic.Value(bool) = .init(false),
    /// Futex word: 1 once the connection's serving is to end.
    over: std.atomic.Value(u32) = .init(0),
    /// `Paused`; a futex word for the task waiting for `resumeReading`.
    paused: std.atomic.Value(u32) = .init(Paused.reading),

    /// 0: none yet; else `CloseReason` + 1.
    reason: std.atomic.Value(u8) = .init(0),
    errno_value: std.atomic.Value(i32) = .init(0),
    writable_pending: std.atomic.Value(bool) = .init(false),
    /// Serves callbacks one at a time on the Zig path (the C ABI's never
    /// wait and skip it): a callback serializer held across the callback,
    /// which may wait (an I/O lock, L2's exception, rank `io`: its takers
    /// hold no other lock). It goes once net gets a per-connection event
    /// mailbox run by one task (after S2, with the #85 relay work).
    cb_lock: safety.IoLock = .init,
    ending: bool = false,

    // Reading (its task).
    decoder: framing_mod.Decoder,
    frames: std.ArrayList([]const u8) = .empty,
    opened_at: std.Io.Clock.Timestamp,
    last_input: std.Io.Clock.Timestamp,
    idle_ns: std.atomic.Value(i64),
    bytes_in: u64 = 0,
    bytes_out: std.atomic.Value(u64) = .init(0),
    burst: ?*dusty.Burst = null,
    task_window: []u8 = &.{},
    task_frames_at: usize = 0,
    task_writer: TaskWriter = undefined,
    /// Windows: the task in `serve` (the connection's executor only). A
    /// shutdown there does not end a receive already waiting, so ending
    /// the connection also cancels this task (as `parked.zig` does).
    reader_task: if (native_os == .windows) ?placement.Task else void = if (native_os == .windows) null else {},

    const linger: Duration = .fromSeconds(2);

    /// `linger`, or in test builds `test_linger` when set (a graceful
    /// close's wait for the peer, cut short).
    fn lingerFor() Duration {
        if (builtin.is_test) if (test_linger) |d| return d;
        return linger;
    }

    // -- Start and release ---------------------------------------------------

    fn open(listener: *TcpListener, connection: *dusty.Connection, info: *const dusty.RawInfo) anyerror!?*dusty.Adopter {
        const service = &listener.service;
        const o = service.options;
        const gpa = listener.gpa;
        const driver = try listener.driverFor(info);
        const kick = try driver.slots.alloc(gpa);
        errdefer driver.slots.free(kick);
        const t = try gpa.create(TcpConn);
        errdefer gpa.destroy(t);
        const now = std.Io.Clock.Timestamp.now(info.io, .awake);
        t.* = .{
            .adopter = .{ .serve = serve, .release = release },
            .listener = listener,
            .service = service,
            .connection = connection,
            .info = info.*,
            .io = info.io,
            .gpa = gpa,
            .driver = driver,
            .owner = .here(info.io),
            .exec = placement.currentExecutor(info.io),
            .kick = kick,
            .id = next_conn_id.fetchAdd(1, .monotonic),
            .drain_hook = .{ .callback = onDrain },
            .task_form = service.table.task != null,
            .decoder = .init(gpa, o.framing),
            .opened_at = now,
            .last_input = now,
            .idle_ns = .init(if (o.idle_timeout) |d| @intCast(d.nanoseconds) else -1),
        };
        t.task_writer = .{ .conn = t, .interface = .{ .vtable = &.{ .drain = TaskWriter.drain }, .buffer = &.{} } };
        t.conn.context = null;
        t.tuneSocket(o);
        const table = service.table;
        if (table.state_size > 0) {
            std.debug.assert(table.state_align <= 16);
            t.state_buf = try gpa.alignedAlloc(u8, .@"16", table.state_size);
            table.state_init.?(t.state_buf.ptr);
            t.conn.context = t.state_buf.ptr;
        }
        kick.conn = t;
        t.adopter.deadline = t.lifetimeAt();
        _ = listener.stats.open.fetchAdd(1, .monotonic);
        _ = listener.stats.total.fetchAdd(1, .monotonic);
        if (listener.series) |m| {
            m.total.inc();
            m.open.add(1);
        }
        info.drain_hooks.add(info.io, &t.drain_hook);
        if (table.open) |f| {
            t.callLock();
            defer t.callUnlock();
            f(service.state, &t.conn) catch |err| {
                if (err != error.Canceled) log.warn("tcp {s}: open failed: {t}", .{ info.listener.name, err });
                t.setReason(.failed);
                t.ending = true;
            };
        }
        return &t.adopter;
    }

    /// The core is done with the connection (on its task, its executor).
    /// In this order (Go's `fd.Close` shape): no send is taken and no
    /// helper spawned from the first step on, the driver can't reach it,
    /// the helpers end (T1: cancel, join), what is still queued is
    /// dropped, and only then it is freed.
    fn release(a: *dusty.Adopter) void {
        const t: *TcpConn = @alignCast(@fieldParentPtr("adopter", a));
        const io = t.io;
        t.owner.check(io);
        // Every spawn site checks this and spawns without a suspension in
        // between, on this executor.
        _ = t.flags.fetchOr(Flag.closed, .seq_cst);
        // The driver resolves slots on this executor: from here a kick finds
        // the slot empty. A driver suspended in a spawn for `t` (zio's spawn
        // backpressure) finds the slot changed when it resumes and touches
        // nothing of `t` (`spawn`).
        t.driver.slots.free(t.kick);
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        io.futexWake(u32, &t.over.raw, std.math.maxInt(u32));
        t.unpause();
        t.wakeWaiters();
        // No drain hook runs for it after this (it runs under the drain's
        // lock, which `remove` takes).
        t.info.drain_hooks.remove(io, &t.drain_hook);
        // A writable or drain callback still running is canceled (C1).
        t.group.cancel(io);
        // A sender between its reservation and its push now gets Closed
        // (and frees its own chunk); what got in is dropped here.
        t.dropOutput();
        t.dropSpare();
        const reason = t.finalReason();
        const stats = &t.listener.stats;
        _ = stats.open.fetchSub(1, .monotonic);
        _ = stats.closes[@backingInt(reason)].fetchAdd(1, .monotonic);
        if (t.listener.series) |m| {
            m.open.add(-1);
            m.closes[@backingInt(reason)].inc();
        }
        _ = stats.bytes_in.fetchAdd(t.bytes_in, .monotonic);
        const out = t.bytes_out.load(.monotonic);
        _ = stats.bytes_out.fetchAdd(out, .monotonic);
        if (t.service.options.log_connections) t.logClosed(reason, out);
        if (t.service.table.close) |f| f(t.service.state, &t.conn, reason);
        if (t.state_buf.len > 0) {
            if (t.service.table.state_deinit) |f| f(t.state_buf.ptr);
            t.gpa.free(t.state_buf);
        }
        t.decoder.deinit();
        t.frames.deinit(t.gpa);
        // Writers still in `waitUnder` (a task outside the connection's,
        // woken above by `wakeWaiters`) leave before the memory goes (M2:
        // the owner frees after the join). Uncancelable, and short: they
        // are awake and only look at the flags on their way out.
        while (true) {
            const w = t.waiters.load(.seq_cst);
            if (w == 0) break;
            io.futexWaitUncancelable(u32, &t.waiters.raw, w);
        }
        t.gpa.destroy(t);
    }

    fn logClosed(t: *TcpConn, reason: CloseReason, bytes_out: u64) void {
        var buf: [96]u8 = undefined;
        var remote: []const u8 = "-";
        if (t.conn.remote()) |a| {
            var w: std.Io.Writer = .fixed(&buf);
            if (a.format(&w)) |_| remote = w.buffered() else |_| {}
        }
        const ms: u64 = @intCast(@max(0, @divTrunc(t.opened_at.durationTo(std.Io.Clock.Timestamp.now(t.io, .awake)).raw.nanoseconds, std.time.ns_per_ms)));
        anole_log.scoped(.access).info("tcp connection closed", .{
            .listener = t.info.listener.name,
            .remote = remote,
            .duration_ms = ms,
            .bytes_in = t.bytes_in,
            .bytes_out = bytes_out,
            .reason = @tagName(reason),
        });
    }

    fn setReason(t: *TcpConn, r: CloseReason) void {
        _ = t.reason.cmpxchgStrong(0, @backingInt(r) + 1, .acq_rel, .acquire);
    }

    fn finalReason(t: *TcpConn) CloseReason {
        const v = t.reason.load(.acquire);
        if (v != 0) return @fromBackingInt(@intCast(v - 1));
        const now = std.Io.Clock.Timestamp.now(t.io, .awake);
        if (t.lifetimeAt()) |d| if (now.compare(.gte, d)) return .lifetime;
        if (t.idleAt()) |d| if (now.compare(.gte, d)) return .idle;
        return .drain;
    }

    fn tuneSocket(t: *TcpConn, o: Tcp.Options) void {
        if (comptime native_os == .windows) return;
        if (t.info.listener.address == .unix) return;
        const fd = t.connection.stream.socket.handle;
        const one: c_int = 1;
        if (o.no_delay) _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &one, @sizeOf(c_int));
        if (comptime native_os.isDarwin()) _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        if (o.keepalive) |d| {
            _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, &one, @sizeOf(c_int));
            const secs: c_int = @intCast(@max(1, @divTrunc(d.nanoseconds, std.time.ns_per_s)));
            const interval: c_int = 10;
            const count: c_int = 6;
            if (comptime native_os == .linux) {
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 4, &secs, @sizeOf(c_int)); // TCP_KEEPIDLE
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 5, &interval, @sizeOf(c_int)); // TCP_KEEPINTVL
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 6, &count, @sizeOf(c_int)); // TCP_KEEPCNT
            } else if (comptime native_os.isDarwin()) {
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x10, &secs, @sizeOf(c_int)); // TCP_KEEPALIVE
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x101, &interval, @sizeOf(c_int)); // TCP_KEEPINTVL
                _ = std.c.setsockopt(fd, std.posix.IPPROTO.TCP, 0x102, &count, @sizeOf(c_int)); // TCP_KEEPCNT
            }
        }
    }

    // -- Small helpers -----------------------------------------------------------

    fn has(t: *const TcpConn, flag: u32) bool {
        return t.flags.load(.acquire) & flag != 0;
    }

    fn isClosed(t: *const TcpConn) bool {
        return t.has(Flag.closed);
    }

    fn isDead(t: *const TcpConn) bool {
        return t.has(Flag.dead);
    }

    /// The caller runs on the connection's executor. Off zio (`exec` null,
    /// as on `std.Io.Threaded`) never: the executor reasoning in this file
    /// (T3's owner checks, M3's "nothing suspends between a look and its
    /// use", the driver's slots) assumes zio's pinned executors, which
    /// every Anole server runs on; it does not hold elsewhere.
    fn onOwner(t: *const TcpConn) bool {
        const e = t.exec orelse return false;
        return placement.currentExecutor(t.io) == e;
    }

    /// Wakes every task waiting on `word`: directly on the connection's
    /// executor, else through its driver's gate (T5: the caller may be a
    /// thread that outlives the runtime).
    fn wakeAll(t: *TcpConn, word: *std.atomic.Value(u32)) void {
        if (t.onOwner()) return t.io.futexWake(u32, &word.raw, std.math.maxInt(u32));
        if (!t.driver.gate.enter()) return;
        defer t.driver.gate.leave();
        t.io.futexWake(u32, &word.raw, std.math.maxInt(u32));
    }

    /// Tells the writers waiting in `waitUnder`: bytes left the queue, or
    /// the connection ended. The caller changed `queued` or the flags
    /// (`.seq_cst`) before this `.seq_cst` look at `waiters`, which pairs
    /// with a waiter's count then look (store-buffering): either it sees
    /// the change, or the epoch moves after its look at it.
    fn wakeWaiters(t: *TcpConn) void {
        if (t.waiters.load(.seq_cst) == 0) return;
        _ = t.epoch.fetchAdd(1, .seq_cst);
        t.wakeAll(&t.epoch);
    }

    fn kickOf(t: *TcpConn) Kick {
        return .{ .driver = t.driver, .slot = t.kick };
    }

    // -- Callbacks -------------------------------------------------------------

    fn callLock(t: *TcpConn) void {
        if (t.service.table.inline_events) return;
        t.cb_lock.lockUncancelable(t.io);
    }

    fn callUnlock(t: *TcpConn) void {
        if (t.service.table.inline_events) return;
        t.cb_lock.unlock(t.io);
    }

    // -- Helpers (tasks that touch the connection) ----------------------------

    const Spawned = enum {
        started,
        /// No task: none could be had, or the connection is being released.
        refused,
        /// Started, but the spawn suspended and the connection was released
        /// meanwhile: the caller touches nothing of `t` any more.
        gone,
    };

    /// Runs `func(t)` on a task of the connection's group, on its executor.
    /// The spawn can suspend the caller: zio's spawn backpressure
    /// (`registerTask` -> `yieldForRound`) yields a spawner once the run
    /// queue is long. A caller outside the group (the driver) may then find
    /// `t` released and freed when it resumes; so the kick slot (stable
    /// memory) is read before and looked at after: `.gone` when another
    /// connection, or none, is in it now. A caller in the group (the
    /// flusher) is joined by `release` and would be safe, but stops too.
    /// `.refused` means no suspension happened (zio's `registerTask` fails
    /// only before `scheduleTask`, and its yield is `.no_cancel`), so the
    /// refusal paths go on with `t`; a zio whose spawn could yield and then
    /// fail would make them use-after-free (MAINTAINING.md, zio bumps).
    fn spawn(t: *TcpConn, comptime func: fn (*TcpConn) void, comptime point: ?TestPoint) Spawned {
        t.owner.check(t.io);
        if (t.isClosed()) return .refused;
        const slot = t.kick;
        const gen = slot.gen;
        placement.concurrent(&t.group, t.io, .local, func, .{t}) catch return .refused;
        if (point) |p| testHold(t.io, p);
        if (slot.conn != t or slot.gen != gen) return .gone;
        return .started;
    }

    // -- Writing: queue --------------------------------------------------------

    /// Appends `parts` as one piece of the outbox. `token` nonzero: one
    /// borrowed part, without a copy. Any thread; never waits.
    fn queue(t: *TcpConn, parts: []const []const u8, token: u64) Conn.SendError!Conn.Sent {
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const f = t.flags.load(.acquire);
        if (f & (Flag.closed | Flag.dead) != 0) return error.Closed;
        if (f & Flag.ended != 0) return error.Ended;
        if (total == 0) return .ok;
        if (total > t.service.options.write_max) return error.TooLarge;
        // On the connection's executor, with nothing from elsewhere ahead:
        // straight into the outbox (no lock, as nothing here suspends).
        if (t.onOwner() and t.inbox.isEmpty()) return t.queueLocal(parts, total, token);
        const c = if (token != 0) try OutChunk.borrowed(t.gpa, parts[0], token) else blk: {
            const c = try OutChunk.create(t.gpa, total);
            c.len = 0;
            c.append(parts);
            break :blk c;
        };
        const q = t.pushChunk(c) catch |err| {
            c.destroy();
            return err;
        };
        if (q.kick) |k| k.run();
        return q.sent;
    }

    /// The owner executor's send: into the last chunk when it has room
    /// (many small sends cost one allocation), else into the spare when it
    /// is big enough, else into a fresh chunk of 16 KiB (`standard_room`,
    /// its region `standard_region`) or exactly the send's size if larger, whatever `write_high_water` is: the
    /// limits count bytes queued, not chunk room, so a listener with a
    /// small high-water mark needs nothing; a connection with output
    /// pending holds 16 KiB at least.
    fn queueLocal(t: *TcpConn, parts: []const []const u8, total: usize, token: u64) Conn.SendError!Conn.Sent {
        var fresh: ?*OutChunk = null;
        if (token != 0) {
            fresh = try OutChunk.borrowed(t.gpa, parts[0], token);
        } else if (t.out.tail == null or t.out.tail.?.room() < total) {
            fresh = t.takeSpare(total) orelse try OutChunk.fresh(t.gpa, @max(total, OutChunk.standard_region));
        }
        const busy = t.reserve(total) catch {
            if (fresh) |c| t.recycle(c);
            return error.QueueFull;
        };
        if (fresh) |c| {
            if (token == 0) c.append(parts);
            t.out.append(c);
        } else t.out.tail.?.append(parts);
        if (t.claimDriver()) |k| k.run();
        return if (busy) .busy else .ok;
    }

    /// Takes `c` (whole, framed already) into the inbox: reserved, then
    /// pushed. On an error `c` stays the caller's (to free after any lock
    /// it holds, L5). The kick, if one is due, is the caller's to make.
    fn pushChunk(t: *TcpConn, c: *OutChunk) Conn.SendError!Conn.Queued {
        const n = c.len;
        if (n > t.service.options.write_max) return error.TooLarge;
        const busy = t.reserve(n) catch return error.QueueFull;
        // Checked again after the reservation, which `requestEnd`'s flag
        // pairs with (both `.seq_cst`): a send either sees the end, or is
        // counted in `queued` before the end's FIN is decided.
        const f = t.flags.load(.seq_cst);
        if (f & (Flag.closed | Flag.dead | Flag.ended) != 0) {
            t.unreserve(n);
            return if (f & Flag.ended != 0 and f & (Flag.closed | Flag.dead) == 0) error.Ended else error.Closed;
        }
        // (A refusal here is rare, a stop or end racing the send: its
        // `unreserve` wakes through the gate even under a caller's lock.)
        _ = t.inbox.push(&c.node) catch {
            t.unreserve(n);
            return error.Closed;
        };
        return .{ .sent = if (busy) .busy else .ok, .kick = t.claimDriver() };
    }

    /// Reserves `n` bytes of `write_max`: busy when past the high-water
    /// mark. QueueFull takes nothing, and a WRITABLE follows it.
    fn reserve(t: *TcpConn, n: usize) error{QueueFull}!bool {
        const o = &t.service.options;
        var q = t.queued.load(.monotonic);
        while (true) {
            if (@as(u64, q) + n > o.write_max) {
                testHold(t.io, .queue_full);
                // Asks for WRITABLE, then looks again (the store-buffering
                // pair with `consume`'s subtraction then flag load, all
                // `.seq_cst`): a write that emptied the queue after the look
                // above read the flag before it was set and sent nothing,
                // so the send is tried again. Still full: what is queued now
                // leaves later, and that `consume` sees the flag. (A retry
                // that fits leaves the flag set: one WRITABLE too many, which
                // the contract allows.)
                _ = t.flags.fetchOr(Flag.want_writable, .seq_cst);
                const again = t.queued.load(.seq_cst);
                if (@as(u64, again) + n <= o.write_max) {
                    q = again;
                    continue;
                }
                _ = t.listener.stats.queue_full.fetchAdd(1, .monotonic);
                if (t.listener.series) |m| m.queue_full.inc();
                return error.QueueFull;
            }
            q = t.queued.cmpxchgWeak(q, q + @as(u32, @intCast(n)), .seq_cst, .monotonic) orelse break;
        }
        // Busy: these bytes are in `queued`, and the `consume` that takes
        // them comes after the push that follows this flag (happens-before),
        // so it sees the flag.
        const busy = @as(u64, q) + n > o.write_high_water;
        if (busy) _ = t.flags.fetchOr(Flag.want_writable, .acq_rel);
        return busy;
    }

    /// A reservation given back unused (the send was refused after it):
    /// whoever waits on `queued` hears, and a party that left an end
    /// waiting for it looks again.
    fn unreserve(t: *TcpConn, n: usize) void {
        _ = t.queued.fetchSub(@intCast(n), .seq_cst);
        t.wakeWaiters();
        t.schedule();
    }

    /// Makes the driver responsible for the outbox if nobody is: the kick
    /// to make, or null.
    fn claimDriver(t: *TcpConn) ?Kick {
        if (t.sched.cmpxchgStrong(Sched.none, Sched.driver, .seq_cst, .seq_cst) != null) return null;
        return t.kickOf();
    }

    /// Makes sure someone looks at the outbox (and the end flags). Once the
    /// connection is released, nobody needs to: `release` drops it.
    fn schedule(t: *TcpConn) void {
        if (t.scheduleKick()) |k| k.run();
    }

    fn scheduleKick(t: *TcpConn) ?Kick {
        if (t.isClosed()) return null;
        return t.claimDriver();
    }

    fn requestEnd(t: *TcpConn, graceful: bool) void {
        if (t.requestEndKick(graceful)) |k| k.run();
    }

    fn requestEndKick(t: *TcpConn, graceful: bool) ?Kick {
        _ = t.flags.fetchOr(Flag.ended, .seq_cst);
        if (graceful) t.close_graceful.store(true, .release);
        t.end_requested.store(true, .seq_cst);
        return t.scheduleKick();
    }

    fn resetKick(t: *TcpConn) ?Kick {
        t.setReason(.local);
        t.reset_requested.store(true, .release);
        _ = t.flags.fetchOr(Flag.dead | Flag.ended, .seq_cst);
        if (comptime native_os == .windows) {
            const lg: ws.Linger = .{ .onoff = 1, .linger = 0 };
            _ = ws.windows.setsockopt(ws.socket(t.connection.stream.socket.handle), ws.SOL_SOCKET, ws.SO_LINGER, @ptrCast(&lg), @sizeOf(ws.Linger));
        } else {
            const lg: std.c.linger = .{ .onoff = 1, .linger = 0 };
            _ = std.c.setsockopt(t.connection.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, &lg, @sizeOf(@TypeOf(lg)));
        }
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        t.wakeAll(&t.over);
        t.unpause();
        t.wakeWaiters();
        const k = t.scheduleKick();
        // Windows off the executor: the driver also cancels the reader.
        if (comptime native_os == .windows) if (t.has(Flag.cancel_reader)) return t.kickOf();
        return k;
    }

    /// Ends the connection for `reason` (the first reason stands): nothing
    /// more is written, the socket is shut down and the reading side ends.
    fn abort(t: *TcpConn, reason: CloseReason) void {
        t.setReason(reason);
        _ = t.flags.fetchOr(Flag.dead | Flag.ended, .seq_cst);
        t.shutdownSocket(.both);
        t.over.store(1, .release);
        t.wakeAll(&t.over);
        t.unpause();
        t.wakeWaiters();
        if (comptime native_os == .windows) if (t.has(Flag.cancel_reader)) t.kickOf().run();
    }

    /// The end of a paused connection: its task, waiting for
    /// `resumeReading` (`waitResumed`), must hear it. The word it waits on
    /// changes, for good (`Paused.ended`): a wake alone, or a word a later
    /// `pauseReading` could set back, could fall between its look at
    /// `over` and its wait and be lost.
    fn unpause(t: *TcpConn) void {
        if (t.paused.swap(Paused.ended, .acq_rel) == Paused.paused) t.wakeAll(&t.paused);
    }

    fn shutdownSocket(t: *TcpConn, how: std.Io.net.ShutdownHow) void {
        if (comptime native_os == .windows) {
            const h: i32 = switch (how) {
                .recv => ws.SD_RECEIVE,
                .send => ws.SD_SEND,
                .both => ws.SD_BOTH,
            };
            _ = ws.windows.shutdown(ws.socket(t.connection.stream.socket.handle), h);
            if (how != .send) t.cancelReader();
            return;
        }
        const h: c_int = switch (how) {
            .recv => std.posix.SHUT.RD,
            .send => std.posix.SHUT.WR,
            .both => std.posix.SHUT.RDWR,
        };
        _ = std.c.shutdown(t.connection.stream.socket.handle, h);
    }

    /// Windows: wakes the reading task out of a receive the shutdown left
    /// waiting, unless it is the caller. On the connection's executor the
    /// task in `serve` is still running while `reader_task` names it;
    /// elsewhere the driver does it (`Flag.cancel_reader`), on that
    /// executor: the caller makes the kick.
    fn cancelReader(t: *TcpConn) void {
        if (comptime native_os != .windows) return;
        if (!t.onOwner()) {
            // `.seq_cst`: see `serviceKick`.
            _ = t.flags.fetchOr(Flag.cancel_reader, .seq_cst);
            return;
        }
        const me = placement.currentTask(t.io);
        if (t.reader_task) |task| if (me == null or me.? != task) placement.cancelTask(task);
    }

    // -- Writing: the responsible party ---------------------------------------

    /// Moves the inbox (sends from elsewhere, oldest first) to the outbox.
    fn takeInbox(t: *TcpConn) void {
        var it = t.inbox.takeAll();
        while (it) |n| {
            it = n.next;
            t.out.append(OutChunk.of(n));
        }
    }

    /// Takes the outbox as the batch to write. False when there is none.
    fn takeBatch(t: *TcpConn) bool {
        std.debug.assert(t.inflight.isEmpty());
        t.takeInbox();
        if (t.out.isEmpty()) return false;
        t.inflight = t.out;
        t.out = .{};
        return true;
    }

    /// The end is due: asked for, not done, and nothing queued or reserved.
    fn endDue(t: *TcpConn) bool {
        return t.end_requested.load(.seq_cst) and !t.end_done.load(.acquire) and t.queued.load(.seq_cst) == 0;
    }

    /// The responsible party (`mine`) lets go. True when it took the outbox
    /// back because work came meanwhile: it goes on. The `.seq_cst` store
    /// and the loads after it pair with a sender's push and its claim (the
    /// store-buffering pair): either the sender sees `none` and kicks the
    /// driver, or the party sees its chunk.
    fn letGo(t: *TcpConn, mine: u8) bool {
        t.sched.store(Sched.none, .seq_cst);
        const more = !t.inbox.isEmpty() or (!t.isDead() and (!t.out.isEmpty() or t.endDue()));
        if (!more) return false;
        return t.sched.cmpxchgStrong(Sched.none, mine, .seq_cst, .seq_cst) == null;
    }

    /// The driver's turn with a kicked connection, on its executor. It
    /// suspends only in a spawn (the drain's, WRITABLE's, the flusher's:
    /// zio's spawn backpressure), and `release`, on this executor too, may
    /// run and free `t` meanwhile (M3): after each spawn it goes on only
    /// when `spawn` says the connection is still the one in its slot, and
    /// after a spawn that ends its turn (`handOver`) it touches nothing.
    ///
    /// The flag loads here are `.seq_cst`: they pair with a setter's
    /// `.seq_cst` flag then `kicked` swap (`onDrain`, `cancelReader`)
    /// against the driver's `kicked` store then these loads, so a kick
    /// dropped because the slot was still listed finds its flag here.
    fn serviceKick(t: *TcpConn) void {
        t.owner.check(t.io);
        if (t.flags.load(.seq_cst) & Flag.drain_pending != 0) {
            const f = t.flags.fetchAnd(~Flag.drain_pending, .seq_cst);
            if (f & Flag.drain_pending != 0) {
                if (t.spawn(drainTask, .spawn_drain) == .gone) return;
            }
        }
        if (comptime native_os == .windows) if (t.flags.load(.seq_cst) & Flag.cancel_reader != 0) {
            _ = t.flags.fetchAnd(~Flag.cancel_reader, .seq_cst);
            if (t.reader_task) |task| placement.cancelTask(task);
        };
        // A kick for the drain, or a stale one: the outbox is someone else's.
        if (t.sched.load(.seq_cst) != Sched.driver) return;
        if (comptime native_os != .windows) {
            if (t.connection.tls_conn == null and !t.close_graceful.load(.acquire)) return t.serviceDirect();
        }
        t.handOver();
    }

    /// Passes the outbox to a flusher task. The caller's last touch of `t`
    /// (the spawn may suspend; see `spawn`).
    fn handOver(t: *TcpConn) void {
        t.sched.store(Sched.flusher, .seq_cst);
        // Refused without a suspension: `t` is still there.
        if (t.spawn(flusher, null) == .refused) t.failWrite(.server);
    }

    fn serviceDirect(t: *TcpConn) void {
        while (true) {
            if (t.isDead()) {
                t.discardAll();
                if (t.letGo(Sched.driver)) continue;
                return;
            }
            if (t.inflight.isEmpty()) {
                if (!t.takeBatch()) {
                    // Nothing queued: the end, if asked for.
                    if (t.endDue()) {
                        t.shutdownSocket(.send);
                        t.endFinished();
                    }
                    if (t.letGo(Sched.driver)) continue;
                    return;
                }
            }
            switch (t.writeNow()) {
                .done => {},
                .would_block => return t.handOver(),
                .gone => return,
                .failed => {
                    t.failWrite(.reset);
                    t.discardAll();
                    if (t.letGo(Sched.driver)) continue;
                    return;
                },
            }
        }
    }

    /// `gone`: released during a spawn of WRITABLE's task (see `spawn`).
    const NowResult = enum { done, would_block, failed, gone };

    /// Writes `inflight` without waiting: `sendmsg` with MSG_DONTWAIT.
    fn writeNow(t: *TcpConn) NowResult {
        const fd = t.connection.stream.socket.handle;
        var flags: u32 = std.c.MSG.DONTWAIT;
        if (comptime native_os == .linux) flags |= std.c.MSG.NOSIGNAL;
        while (t.inflight.head) |first| {
            var iov: [64]std.posix.iovec_const = undefined;
            var n: usize = 0;
            var it: ?*OutChunk = first;
            while (it) |c| : (it = c.next) {
                if (n == iov.len) break;
                iov[n] = .{ .base = c.unsent().ptr, .len = c.len };
                n += 1;
            }
            const msg: std.c.msghdr_const = .{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = @intCast(n),
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const rc = std.c.sendmsg(fd, &msg, flags);
            if (rc < 0) switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .would_block,
                else => |e| {
                    t.errno_value.store(@backingInt(e), .release);
                    return .failed;
                },
            };
            if (!t.consume(@intCast(rc))) return .gone;
        }
        return .done;
    }

    /// `n` bytes of the batch are written: frees what is whole, advances
    /// into the chunk that is not, and tells the writable waiters. False:
    /// the connection was released during WRITABLE's spawn (see `spawn`).
    fn consume(t: *TcpConn, n: usize) bool {
        var left = n;
        while (left > 0) {
            const c = t.inflight.head orelse break;
            if (left >= c.len) {
                left -= c.len;
                _ = t.inflight.pop();
                t.finishChunk(c);
            } else {
                c.off += left;
                c.len -= left;
                left = 0;
            }
        }
        _ = t.bytes_out.fetchAdd(n, .monotonic);
        if (t.listener.series) |m| m.bytes_out.add(n);
        const was = t.queued.fetchSub(@intCast(n), .seq_cst);
        const now_queued = was - @as(u32, @intCast(n));
        t.wakeWaiters();
        // The flag is read after the subtraction, both `.seq_cst`: they
        // pair with `reserve`'s refusal (flag, then a second look at
        // `queued`), so either it sees the flag or the sender sees room.
        const half = t.service.options.write_high_water / 2;
        if (now_queued < half and t.flags.load(.seq_cst) & Flag.want_writable != 0) {
            if (t.flags.fetchAnd(~Flag.want_writable, .seq_cst) & Flag.want_writable != 0) return t.notifyWritable();
        }
        return true;
    }

    /// A chunk leaves the connection, written or dropped: a borrowed one
    /// reports `sent`. The connection's executor (the responsible party,
    /// `release`).
    fn finishChunk(t: *TcpConn, c: *OutChunk) void {
        if (!c.owned and c.token != 0) {
            if (t.service.table.sent) |f| f(t.service.state, &t.conn, c.token);
        }
        t.recycle(c);
    }

    /// Keeps a chunk an owner send made (`local`), up to `spareMax`, as the
    /// spare when there is none or it is bigger than the one there (that
    /// one is freed), unless the connection is parked; else frees it.
    /// Other threads' and the C ABI's chunks are never kept: only the
    /// owner path takes the spare back. The connection's executor only.
    fn recycle(t: *TcpConn, c: *OutChunk) void {
        if (c.local and !t.parked and c.capacity() <= OutChunk.spareMax(t.service.options.write_high_water)) {
            const old = t.spare;
            if (old == null or old.?.capacity() < c.capacity()) {
                c.reset();
                t.spare = c;
                if (old) |o| o.destroy();
                return;
            }
        }
        c.destroy();
    }

    /// The spare when it holds `room` bytes; a smaller one is freed (the
    /// chunk made instead becomes the next spare).
    fn takeSpare(t: *TcpConn, room: usize) ?*OutChunk {
        const c = t.spare orelse return null;
        t.spare = null;
        if (c.capacity() >= room) return c;
        c.destroy();
        return null;
    }

    /// Frees the spare: the connection parks (an idle one holds no buffer;
    /// `recycle` keeps none while parked) or is released.
    fn dropSpare(t: *TcpConn) void {
        if (t.spare) |c| {
            t.spare = null;
            c.destroy();
        }
    }

    /// WRITABLE: the C ABI's table posts it from here; a Zig handler's
    /// `writable` runs on a task of its own. False: released during that
    /// task's spawn (see `spawn`).
    fn notifyWritable(t: *TcpConn) bool {
        const f = t.service.table.writable orelse return true;
        if (t.service.table.inline_events) {
            f(t.service.state, &t.conn) catch {};
            return true;
        }
        if (t.writable_pending.swap(true, .acq_rel)) return true;
        switch (t.spawn(writableTask, .spawn_writable)) {
            .started => {},
            .refused => t.writable_pending.store(false, .release),
            .gone => return false,
        }
        return true;
    }

    fn writableTask(t: *TcpConn) void {
        t.owner.check(t.io);
        t.writable_pending.store(false, .release);
        if (t.isClosed()) return;
        t.callLock();
        defer t.callUnlock();
        // Released while it waited for the lock: `release` joins it.
        if (t.isClosed()) return;
        const f = t.service.table.writable.?;
        f(t.service.state, &t.conn) catch |err| t.callbackFailed("writable", err);
    }

    /// Drops whatever is queued (a reset or a failed connection), by the
    /// responsible party: borrowed chunks report `sent`.
    fn discardAll(t: *TcpConn) void {
        t.takeInbox();
        const dropped = t.dropChunks(&t.inflight) + t.dropChunks(&t.out);
        if (dropped > 0) _ = t.queued.fetchSub(@intCast(dropped), .seq_cst);
        t.wakeWaiters();
    }

    fn dropChunks(t: *TcpConn, f: *Fifo) usize {
        var n: usize = 0;
        while (f.pop()) |c| {
            n += c.len;
            t.finishChunk(c);
        }
        return n;
    }

    /// At `release`: seals the inbox (a later push gets Closed) and drops
    /// everything left.
    fn dropOutput(t: *TcpConn) void {
        var it = t.inbox.seal();
        while (it) |n| {
            it = n.next;
            t.out.append(OutChunk.of(n));
        }
        _ = t.dropChunks(&t.inflight);
        _ = t.dropChunks(&t.out);
    }

    fn failWrite(t: *TcpConn, reason: CloseReason) void {
        const e = t.errno_value.load(.acquire);
        t.abort(if (reason == .reset and e != 0 and e != @backingInt(std.posix.E.PIPE) and e != @backingInt(std.posix.E.CONNRESET)) .failed else reason);
    }

    /// The local end is finished (FIN sent): the connection is over when
    /// the peer's side is too.
    fn endFinished(t: *TcpConn) void {
        t.end_done.store(true, .seq_cst);
        if (t.peer_ended.load(.seq_cst)) t.setOver();
    }

    fn setOver(t: *TcpConn) void {
        t.over.store(1, .release);
        t.wakeAll(&t.over);
        // A paused reader waits on `paused`, not `over`: every end moves it
        // to `ended` (a graceful close's end after its wait for the peer
        // included).
        t.unpause();
    }

    // -- The flusher task ------------------------------------------------------

    fn flusher(t: *TcpConn) void {
        const io = t.io;
        const o = &t.service.options;
        t.owner.check(io);
        while (true) {
            if (t.isDead()) {
                t.discardAll();
                if (t.letGo(Sched.flusher)) continue;
                return;
            }
            if (t.inflight.isEmpty()) {
                if (!t.takeBatch()) {
                    if (t.endDue()) {
                        t.finishOutput();
                        continue;
                    }
                    if (t.letGo(Sched.flusher)) continue;
                    return;
                }
            }
            // Direct first on plain TCP: the batch may go without a wait.
            if (comptime native_os != .windows) {
                if (t.connection.tls_conn == null) switch (t.writeNow()) {
                    .done => continue,
                    .would_block => {},
                    .gone => return,
                    .failed => {
                        t.failWrite(.reset);
                        continue;
                    },
                };
            }
            const timeout: std.Io.Timeout = if (o.write_timeout) |d| .{ .duration = .{ .raw = d, .clock = .awake } } else .none;
            const deadline = dusty.Deadline.init(io, timeout);
            const result = deadline.run(writeBatch, .{t});
            if (result) |_| {} else |err| switch (err) {
                error.Timeout => t.abort(.write_timeout),
                error.Canceled => {
                    // Released: `release` drops the output and reports the
                    // connection's own reason (idle, lifetime, ...), not the
                    // flusher's. Else the server stops: the connection task
                    // ends it.
                    io.recancel();
                    if (t.isClosed()) return;
                    t.abort(.drain);
                },
                error.Gone => return,
                else => t.failWrite(.reset),
            }
        }
    }

    /// Writes the batch through the connection's writer (TLS records
    /// included), waiting as the socket needs.
    fn writeBatch(t: *TcpConn) error{ WriteFailed, Gone }!void {
        const w = t.connection.writer;
        while (t.inflight.head) |first| {
            var slices: [32][]const u8 = undefined;
            var n: usize = 0;
            var bytes: usize = 0;
            var it: ?*OutChunk = first;
            while (it) |c| : (it = c.next) {
                if (n == slices.len) break;
                slices[n] = c.unsent();
                bytes += c.len;
                n += 1;
            }
            w.writeVecAll(slices[0..n]) catch return error.WriteFailed;
            w.flush() catch return error.WriteFailed;
            if (!t.consume(bytes)) return error.Gone;
        }
    }

    /// The end of the local side, by the flusher: TLS close_notify, FIN,
    /// and for a graceful close the wait for the peer's side to end.
    fn finishOutput(t: *TcpConn) void {
        const io = t.io;
        // A cancel (the server stopping) ends the wait for the peer early
        // and stays pending for the flusher's caller.
        var canceled = false;
        t.connection.closeNotify() catch {
            canceled = true;
        };
        t.shutdownSocket(.send);
        t.endFinished();
        if (canceled) io.recancel();
        if (!t.close_graceful.load(.acquire)) return;
        // The reading side drops input until the peer ends: a bound on it.
        if (!canceled and t.over.load(.acquire) == 0) {
            io.futexWaitTimeout(u32, &t.over.raw, 0, .{ .duration = .{ .raw = lingerFor(), .clock = .awake } }) catch io.recancel();
        }
        if (t.over.load(.acquire) == 0) {
            t.shutdownSocket(.both);
            t.setOver();
        }
    }

    // -- Waiting on the outbox -------------------------------------------------

    /// Waits until fewer than `below` bytes are queued. It waits on
    /// `epoch`, which every change it waits for moves (`wakeWaiters`), read
    /// before the looks: a change after them makes the wait return.
    fn waitUnder(t: *TcpConn, below: u32) error{ Closed, Canceled }!void {
        // Counted before `release` can run (the caller's `Conn` is valid
        // until the close callback returns); `release` waits for the count
        // to reach 0 before it frees the connection.
        _ = t.waiters.fetchAdd(1, .seq_cst);
        defer t.leaveWait();
        while (true) {
            const e = t.epoch.load(.seq_cst);
            if (t.flags.load(.seq_cst) & (Flag.closed | Flag.dead) != 0) return error.Closed;
            if (t.queued.load(.seq_cst) < below) return;
            if (builtin.is_test) _ = test_write_waits.fetchAdd(1, .release);
            try t.io.futexWait(u32, &t.epoch.raw, e);
            testHold(t.io, .waiter_woken);
        }
    }

    /// A writer leaves `waitUnder`. Its decrement is its last touch of
    /// `t`: at 0 `release` may free it. The wake after it uses only the
    /// word's address, taken before: zio's futex keys waiters by address
    /// and never reads it, so a wake that finds nobody, or a task waiting
    /// on memory reused at that address, is a spurious wake at most.
    fn leaveWait(t: *TcpConn) void {
        const io = t.io;
        const word = &t.waiters.raw;
        if (t.waiters.fetchSub(1, .seq_cst) == 1) io.futexWake(u32, word, 1);
    }

    fn waitOpen(t: *TcpConn, high: u32) Conn.WriteError!void {
        t.waitUnder(@max(1, high)) catch |err| return switch (err) {
            error.Closed => error.Closed,
            error.Canceled => error.Canceled,
        };
    }

    // -- The drain -------------------------------------------------------------

    /// Runs under the drain's lock, on any task: must not wait. The driver
    /// starts the callback on the connection's executor.
    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const t: *TcpConn = @alignCast(@fieldParentPtr("drain_hook", hook));
        if (t.service.table.drain == null) return;
        // `.seq_cst`: see `serviceKick`.
        _ = t.flags.fetchOr(Flag.drain_pending, .seq_cst);
        t.driver.kick(t.kick);
    }

    fn drainTask(t: *TcpConn) void {
        t.owner.check(t.io);
        if (t.isClosed()) return;
        t.callLock();
        defer t.callUnlock();
        if (t.isClosed()) return;
        const f = t.service.table.drain.?;
        f(t.service.state, &t.conn) catch |err| t.callbackFailed("drain", err);
    }

    /// A callback task's error. Canceled: released (`release` reports the
    /// connection's own reason: idle, lifetime, drain), or the server
    /// stops (drain), as the flusher does. Else the connection fails.
    fn callbackFailed(t: *TcpConn, comptime what: []const u8, err: anyerror) void {
        if (err == error.Canceled) {
            t.io.recancel();
            if (t.isClosed()) return;
            return t.abort(.drain);
        }
        log.warn("tcp {s}: " ++ what ++ " failed: {t}", .{ t.info.listener.name, err });
        t.abort(.failed);
    }

    // -- Deadlines ---------------------------------------------------------------

    fn lifetimeAt(t: *const TcpConn) ?std.Io.Clock.Timestamp {
        const d = t.service.options.lifetime orelse return null;
        return t.opened_at.addDuration(.{ .raw = d, .clock = .awake });
    }

    fn idleAt(t: *const TcpConn) ?std.Io.Clock.Timestamp {
        const ns = t.idle_ns.load(.acquire);
        if (ns < 0) return null;
        return t.last_input.addDuration(.{ .raw = .{ .nanoseconds = ns }, .clock = .awake });
    }

    fn sooner(a: ?std.Io.Clock.Timestamp, b: ?std.Io.Clock.Timestamp) ?std.Io.Clock.Timestamp {
        const x = a orelse return b;
        const y = b orelse return a;
        return if (x.compare(.lte, y)) x else y;
    }

    // -- Serving ---------------------------------------------------------------

    fn serve(a: *dusty.Adopter, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        const t: *TcpConn = @alignCast(@fieldParentPtr("adopter", a));
        t.parked = false;
        if (t.ending) return .close;
        if (comptime native_os == .windows) t.reader_task = placement.currentTask(t.io);
        defer if (comptime native_os == .windows) {
            t.reader_task = null;
        };
        if (t.task_form) return t.serveTask(burst);
        const w = t.service.options.read_window;
        if (w <= 4096) return t.serveCallbacks(4096, burst);
        if (w <= 16384) return t.serveCallbacks(16384, burst);
        return t.serveCallbacks(65536, burst);
    }

    fn serveCallbacks(t: *TcpConn, comptime window_len: usize, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        var window: [window_len]u8 = undefined;
        const r = burst.connection.reader;
        std.debug.assert(r.bufferedLen() == 0);
        r.buffer = &window;
        r.seek = 0;
        r.end = 0;
        defer {
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
        }
        return t.loop(burst, r);
    }

    fn loop(t: *TcpConn, burst: *dusty.Burst, r: *std.Io.Reader) anyerror!dusty.Burst.End {
        const o = &t.service.options;
        while (true) {
            if (t.over.load(.acquire) != 0) return .close;
            if (t.paused.load(.acquire) == Paused.paused) {
                // Paused: no idle deadline (no input is read), the lifetime
                // still holds; its timer ends the wait as a read's.
                burst.deadline = t.lifetimeAt();
                burst.armDeadline();
                t.waitResumed() catch |err| return t.readEnded(burst, err);
                continue;
            }
            if (t.close_graceful.load(.acquire) or t.ending) return t.finishGraceful(burst, r);
            burst.deadline = sooner(t.lifetimeAt(), t.idleAt());
            burst.armDeadline();
            const input = burst.waitInput() catch |err| return t.readEnded(burst, err);
            burst.deadline = t.lifetimeAt();
            burst.armDeadline();
            if (input == .idle) {
                t.adopter.deadline = sooner(t.lifetimeAt(), t.idleAt());
                t.parked = true;
                t.dropSpare();
                return .park;
            }
            if (t.paused.load(.acquire) == Paused.paused) continue; // the bytes wait in the reader
            const bytes = r.buffered();
            r.toss(bytes.len);
            r.seek = 0;
            r.end = 0;
            t.last_input = std.Io.Clock.Timestamp.now(t.io, .awake);
            t.bytes_in += bytes.len;
            if (t.listener.series) |m| m.bytes_in.add(bytes.len);
            if (t.close_graceful.load(.acquire)) continue; // input is dropped
            if (!(try t.deliver(bytes))) return .close;
            _ = o;
        }
    }

    /// Hands a burst's bytes to the handler. False when the connection
    /// ended meanwhile (a bad frame, a failed callback).
    fn deliver(t: *TcpConn, bytes: []const u8) anyerror!bool {
        t.owner.check(t.io);
        const table = t.service.table;
        const f = table.data orelse return true;
        const o = &t.service.options;
        var bad: ?anyerror = null;
        var it: FrameIterator = .{};
        var input: Input = .{ .bytes = bytes };
        if (o.framing != .none) {
            t.frames.clearRetainingCapacity();
            t.decoder.feed(bytes, &t.frames, t.gpa) catch |err| {
                bad = err;
            };
            it = .{ .frames = t.frames.items };
            input = .{ .frames = &it };
        }
        if (o.framing == .none or it.frames.len > 0) {
            t.callLock();
            defer t.callUnlock();
            f(t.service.state, &t.conn, input) catch |err| {
                if (err == error.Canceled) return err;
                if (!t.has(Flag.closed | Flag.dead)) log.warn("tcp {s}: handler failed: {t}", .{ t.info.listener.name, err });
                t.abort(.failed);
                return false;
            };
        }
        if (bad) |err| {
            t.abort(if (err == error.OutOfMemory) .server else .frame);
            return false;
        }
        return true;
    }

    fn waitResumed(t: *TcpConn) !void {
        while (t.paused.load(.acquire) == Paused.paused and t.over.load(.acquire) == 0) {
            if (builtin.is_test) _ = test_paused_waits.fetchAdd(1, .release);
            testHold(t.io, .paused_wait);
            try t.io.futexWait(u32, &t.paused.raw, Paused.paused);
        }
    }

    /// A wait for input failed or the peer ended.
    fn readEnded(t: *TcpConn, burst: *dusty.Burst, err: anyerror) anyerror!dusty.Burst.End {
        switch (err) {
            error.EndOfStream => return t.peerEnded(burst),
            error.Canceled => {
                if (burst.timer.fired()) {
                    const now = std.Io.Clock.Timestamp.now(t.io, .awake);
                    const life = t.lifetimeAt();
                    t.abort(if (life != null and now.compare(.gte, life.?)) .lifetime else .idle);
                    return .close;
                }
                return err;
            },
            else => {
                t.setReason(if (dusty.Connection.isPeerGone(err)) .reset else .failed);
                t.abort(.failed);
                return .close;
            },
        }
    }

    /// The peer's FIN. A half-open listener tells the handler (`end`) and
    /// waits for it to end its side; else this side ends once what is
    /// queued is out.
    fn peerEnded(t: *TcpConn, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        t.setReason(.peer);
        t.peer_ended.store(true, .seq_cst);
        const o = &t.service.options;
        if (o.half_open) {
            if (t.service.table.end) |f| {
                t.callLock();
                defer t.callUnlock();
                f(t.service.state, &t.conn) catch |err| {
                    if (err == error.Canceled) return err;
                    log.warn("tcp {s}: end failed: {t}", .{ t.info.listener.name, err });
                    t.abort(.failed);
                    return .close;
                };
            }
            if (t.end_done.load(.seq_cst)) t.setOver();
        } else {
            t.requestEnd(false);
            // Ended already (an `end` before the peer's): both sides are.
            if (t.end_done.load(.seq_cst)) t.setOver();
        }
        burst.deadline = t.lifetimeAt();
        burst.armDeadline();
        while (t.over.load(.acquire) == 0) {
            t.io.futexWait(u32, &t.over.raw, 0) catch |err| {
                if (burst.timer.fired()) {
                    t.abort(.lifetime);
                    return .close;
                }
                return err;
            };
        }
        return .close;
    }

    /// The local side closes: what is queued goes out, this side ends, and
    /// input is read and dropped until the peer ends or `linger` passes.
    fn finishGraceful(t: *TcpConn, burst: *dusty.Burst, r: *std.Io.Reader) anyerror!dusty.Burst.End {
        t.setReason(.local);
        if (!t.end_requested.load(.acquire)) {
            t.close_graceful.store(true, .release);
            t.requestEnd(true);
        }
        burst.deadline = std.Io.Clock.Timestamp.now(t.io, .awake).addDuration(.{ .raw = linger, .clock = .awake });
        burst.armDeadline();
        while (t.over.load(.acquire) == 0) {
            const input = burst.waitInput() catch |err| switch (err) {
                error.Canceled => {
                    if (burst.timer.fired()) return .close;
                    return err;
                },
                else => return .close,
            };
            if (input == .idle) {
                t.adopter.deadline = burst.deadline;
                t.parked = true;
                t.dropSpare();
                return .park;
            }
            const n = r.bufferedLen();
            r.toss(n);
            r.seek = 0;
            r.end = 0;
        }
        return .close;
    }

    // -- The task form -----------------------------------------------------------

    fn serveTask(t: *TcpConn, burst: *dusty.Burst) anyerror!dusty.Burst.End {
        const o = &t.service.options;
        const window = try t.gpa.alloc(u8, o.read_window);
        defer t.gpa.free(window);
        const r = burst.connection.reader;
        r.buffer = window;
        r.seek = 0;
        r.end = 0;
        t.task_window = window;
        t.burst = burst;
        t.task_writer.interface.buffer = try t.gpa.alloc(u8, o.read_window);
        defer {
            t.gpa.free(t.task_writer.interface.buffer);
            t.task_writer.interface.buffer = &.{};
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
            t.burst = null;
        }
        const task = t.service.table.task.?;
        task(t.service.state, &t.conn) catch |err| {
            switch (err) {
                error.Canceled => return err,
                error.Closed, error.EndOfStream, error.IdleTimeout, error.WriteTimeout => {},
                else => if (!t.has(Flag.closed | Flag.dead)) log.warn("tcp {s}: handler failed: {t}", .{ t.info.listener.name, err }),
            }
            t.abort(switch (err) {
                error.IdleTimeout => .idle,
                error.WriteTimeout => .write_timeout,
                error.FrameTooLarge, error.InvalidFrame => .frame,
                else => if (t.over.load(.acquire) != 0) .local else .failed,
            });
            return .close;
        };
        // Returned: closes, after what is queued is out.
        t.flushTaskWriter();
        return t.finishGraceful(burst, r);
    }

    fn flushTaskWriter(t: *TcpConn) void {
        t.task_writer.interface.flush() catch {};
    }

    fn readFrameTask(t: *TcpConn) Conn.ReadError!?[]const u8 {
        if (!t.task_form) return error.NotTaskForm;
        const burst = t.burst orelse return error.NotTaskForm;
        const o = &t.service.options;
        const r = burst.connection.reader;
        while (true) {
            // Frames from the last burst first.
            if (o.framing != .none) {
                if (t.task_frames_at < t.frames.items.len) {
                    defer t.task_frames_at += 1;
                    return t.frames.items[t.task_frames_at];
                }
                t.frames.clearRetainingCapacity();
                t.task_frames_at = 0;
            }
            if (t.over.load(.acquire) != 0 or t.isClosed()) return error.Closed;
            burst.deadline = sooner(t.lifetimeAt(), t.idleAt());
            burst.armDeadline();
            r.seek = 0;
            r.end = 0;
            r.fillMore() catch |err| {
                burst.deadline = t.lifetimeAt();
                burst.armDeadline();
                switch (err) {
                    error.EndOfStream => {
                        t.setReason(.peer);
                        t.peer_ended.store(true, .release);
                        return null;
                    },
                    error.ReadFailed => {
                        const cause = burst.connection.getReadError() orelse error.Unexpected;
                        if (cause == error.Canceled) {
                            if (burst.timer.fired()) {
                                burst.connection.clearReadError();
                                const now = std.Io.Clock.Timestamp.now(t.io, .awake);
                                const life = t.lifetimeAt();
                                if (life != null and now.compare(.gte, life.?)) {
                                    t.setReason(.lifetime);
                                    return error.Closed;
                                }
                                return error.IdleTimeout;
                            }
                            return error.Canceled;
                        }
                        if (dusty.Connection.isPeerGone(cause)) t.setReason(.reset);
                        return error.Closed;
                    },
                }
            };
            burst.deadline = t.lifetimeAt();
            burst.armDeadline();
            const bytes = r.buffered();
            r.toss(bytes.len);
            t.last_input = std.Io.Clock.Timestamp.now(t.io, .awake);
            t.bytes_in += bytes.len;
            if (t.listener.series) |m| m.bytes_in.add(bytes.len);
            if (o.framing == .none) return bytes;
            t.decoder.feed(bytes, &t.frames, t.gpa) catch |err| return switch (err) {
                error.FrameTooLarge => error.FrameTooLarge,
                error.InvalidFrame => error.InvalidFrame,
                error.OutOfMemory => error.OutOfMemory,
            };
            t.task_frames_at = 0;
        }
    }
};

/// `Conn.writer`: a buffered writer whose drains go to the outbox.
const TaskWriter = struct {
    conn: *TcpConn,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TaskWriter = @alignCast(@fieldParentPtr("interface", w));
        const t = self.conn;
        if (w.end > 0) {
            _ = t.queue(&.{w.buffered()}, 0) catch return error.WriteFailed;
            w.end = 0;
        }
        var n: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |d| {
            if (d.len > 0) _ = t.queue(&.{d}, 0) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (last.len > 0) _ = t.queue(&.{last}, 0) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }
};

fn socketName(fd: std.posix.fd_t) ?std.Io.net.IpAddress {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    if (comptime native_os == .windows) {
        // zio sets SO_UPDATE_ACCEPT_CONTEXT on accepted sockets, which
        // getsockname needs.
        var wlen: i32 = @sizeOf(std.Io.Threaded.PosixAddress);
        if (ws.windows.getsockname(ws.socket(fd), @ptrCast(&storage.any), &wlen) != 0) return null;
        if (storage.any.family != std.posix.AF.INET and storage.any.family != std.posix.AF.INET6) return null;
        return dusty.unmapIpv4(std.Io.Threaded.addressFromPosix(&storage));
    }
    var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    if (std.c.getsockname(fd, &storage.any, &len) != 0) return null;
    if (storage.any.family != std.posix.AF.INET and storage.any.family != std.posix.AF.INET6) return null;
    return dusty.unmapIpv4(std.Io.Threaded.addressFromPosix(&storage));
}

// ---------------------------------------------------------------------------
// Test hooks (test builds only)

/// Where a test stops a task or a sender to force an interleaving the
/// scheduler makes only sometimes (TESTING.md D5).
pub const TestPoint = enum {
    /// `spawn`, right after a WRITABLE task was started: where zio's spawn
    /// backpressure (`registerTask` -> `yieldForRound`) can suspend the
    /// spawner.
    spawn_writable,
    /// `spawn`, right after a drain task was started (the same yield).
    spawn_drain,
    /// `driverFor`, right after the driver's task was started (the same
    /// yield).
    driver_start,
    /// `reserve`: a send found the queue full and has not yet asked for
    /// WRITABLE. Never armed from a C ABI test: under `anole_net_write` it
    /// sits inside the slot's spin lock.
    queue_full,
    /// `waitResumed`: the paused task looked at `paused` and `over` and has
    /// not yet waited.
    paused_wait,
    /// `Driver.run`: a kick slot taken off the list, not yet resolved.
    driver_turn,
    /// `waitUnder`: a writer's wait returned, before its next look.
    waiter_woken,
};

/// One stop: armed through `test_hold`, taken once by the first caller at
/// `point`, which sets `held` and waits until the test calls `let`. A task
/// waits on the futex (other tasks of its executor run meanwhile); a
/// thread yields. Past `limit` it panics: a hang check, not an ordering.
pub const TestHold = struct {
    point: TestPoint,
    held: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(u32) = .init(0),
    limit: Duration = .fromSeconds(30),

    /// Lets the held caller go (any task or thread of the runtime of `io`).
    pub fn let(h: *TestHold, io: std.Io) void {
        h.released.store(1, .release);
        io.futexWake(u32, &h.released.raw, 1);
    }

    fn stay(h: *TestHold, io: std.Io) void {
        // A hold stands for a point that can't be canceled (zio's spawn
        // yield is `.no_cancel`), and the caller may be a task `release`
        // cancels meanwhile (the flusher): the wait must not swallow it.
        const prot = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prot);
        h.held.store(true, .release);
        const start = std.Io.Clock.awake.now(io);
        const on_task = placement.currentExecutor(io) != null;
        while (h.released.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds > h.limit.nanoseconds) {
                std.debug.panic("tcp test hold at {t}: never let go", .{h.point});
            }
            if (on_task) {
                io.futexWaitTimeout(u32, &h.released.raw, 0, .{ .duration = .{ .raw = h.limit, .clock = .awake } }) catch {};
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

pub var test_hold: if (builtin.is_test) std.atomic.Value(?*TestHold) else void = if (builtin.is_test) .init(null) else {};
/// Waits of a paused connection's task for `resumeReading` (test builds only).
pub var test_paused_waits: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {};
/// Test builds: replaces the 2 s a graceful close waits for the peer.
pub var test_linger: if (builtin.is_test) ?Duration else void = if (builtin.is_test) null else {};
/// Waits of a writer in `waitUnder` (test builds only).
pub var test_write_waits: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {};
/// Driver tasks started (test builds only).
pub var test_driver_runs: if (builtin.is_test) std.atomic.Value(u32) else void = if (builtin.is_test) .init(0) else {};

fn testHold(io: std.Io, comptime point: TestPoint) void {
    if (comptime !builtin.is_test) return;
    const h = test_hold.load(.acquire) orelse return;
    if (h.point != point) return;
    if (test_hold.cmpxchgStrong(h, null, .acq_rel, .monotonic) != null) return;
    h.stay(io);
}
