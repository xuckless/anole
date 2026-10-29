//! The gRPC client, over `anole.h2.ClientConnection` or, with `-Dhttp3`,
//! `anole.h3.ClientConnection` (gRFC G2):
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
//! Over HTTP/3 give the channel the connection instead (`.h3 = conn`), or
//! let `Channel.connect` own it (`.http = .h3`, or `.auto` to start on
//! HTTP/2 and switch once an `Alt-Svc` advertises HTTP/3).
//!
//! Over a Unix domain socket (gRPC between processes on one host) the
//! connection's host is a gRPC target: `.host = "unix:/run/app.sock"`; calls
//! run cleartext HTTP/2 and the authority is "localhost".
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
const resilience = @import("resilience_core");
const safety = @import("anole_safety");
const features = @import("build_options");
const wire = @import("wire.zig");
const alt_svc = @import("../h3/alt_svc.zig");

/// The transport a call went out on.
pub const Transport = wire.Transport;
/// `anole.h3.ClientConnection`, or an opaque type without `-Dhttp3`.
pub const H3Connection = wire.h3.ClientConnection;

/// A call's outcome: code and message.
pub const Status = status_mod.Status;
/// A gRPC status code.
pub const Code = status_mod.Code;

/// Which HTTP version calls use (`Channel.Options.http`).
pub const Http = enum {
    /// HTTP/2 only (h2c without `tls`, h2 over TLS).
    h2,
    /// HTTP/3 only, by prior knowledge: the server must serve HTTP/3 on
    /// `Http3.port` (default: the same port number over UDP). Needs `tls`.
    h3,
    /// HTTP/2 first; once a response's `Alt-Svc` advertises `h3` for this
    /// host, the next call dials HTTP/3 and later calls use it. If QUIC
    /// fails, calls go on over HTTP/2 and HTTP/3 is not tried again for
    /// `Http3.retry_after`. Needs `tls`.
    auto,
};

/// HTTP/3 settings for `.h3` and `.auto`.
pub const Http3 = struct {
    /// The UDP port for `.h3`; null: the same port as TCP. `.auto` takes
    /// the port from Alt-Svc.
    port: ?u16 = null,
    /// The receive window per call (QUIC stream data).
    stream_window: u31 = 1 << 20,
    /// For `.auto`: how long an HTTP/3 dial may take before the call goes
    /// over HTTP/2 instead (also bounded by the call's own deadline).
    connect_timeout: std.Io.Duration = .fromSeconds(3),
    /// For `.auto`: after a failed HTTP/3 dial or a connection that died
    /// before any call succeeded on it, HTTP/2 only for this long.
    retry_after: std.Io.Duration = .fromSeconds(300),
    /// QUIC idle timeout (the keep-alive covers open calls).
    idle_timeout: std.Io.Duration = .fromSeconds(30),
};

pub const ChannelError = error{
    /// Neither `conn` nor `h3` is set, or both are (a channel you built).
    ChannelConnection,
    /// `.http = .h3` or `.auto` with `tls == null` (or a Unix socket):
    /// HTTP/3 has no cleartext.
    Http3NeedsTls,
    /// `.http = .h3` or `.auto` in a build without `-Dhttp3`.
    Http3NotBuiltIn,
};

/// Where calls go: an HTTP/2 or HTTP/3 connection and the authority to
/// name. Calls on one channel share the connection, as concurrent streams.
pub const Channel = struct {
    /// The HTTP/2 connection calls go out on, which the caller opens and
    /// closes. Set this or `h3` (a channel from `connect` sets what it
    /// owns).
    conn: ?*h2.ClientConnection = null,
    /// The HTTP/3 connection calls go out on (`-Dhttp3`). Calls over it
    /// follow gRFC G2; `:scheme` is "https" whatever `scheme` says.
    h3: ?*H3Connection = null,
    /// `:authority` for every call.
    authority: []const u8,
    /// "https" over TLS.
    scheme: []const u8 = "http",
    /// The largest response message taken; a larger one ends the call
    /// with RESOURCE_EXHAUSTED.
    max_message_size: usize = 4 * 1024 * 1024,
    /// The most response message bytes one call takes in all, each message
    /// counted at its size plus 64: received messages live in the call's
    /// arena, so this bounds what a long server stream holds. Past it the
    /// call is canceled and ends with RESOURCE_EXHAUSTED.
    /// `CallOptions.max_received_bytes` overrides it per call.
    max_received_bytes: usize = 64 * 1024 * 1024,
    /// Retries for unary calls whose status is in `retry_codes`; null:
    /// none. Transparent retries of calls the server did not process
    /// (REFUSED_STREAM, past a GOAWAY) stay on.
    retry: ?resilience.Retry = null,
    retry_codes: []const Code = &.{.unavailable},
    /// A breaker for this channel's target; null: none. Set it with
    /// `.breaker = .init(.{}, .grpc, "billing:50051")`; the channel must
    /// not move after its first call.
    breaker: ?resilience.Breaker = null,
    /// The retry throttle (gRPC A6) of this channel.
    _throttle: resilience.Throttle = .init(.{}),
    /// Set by `Channel.connect`: the channel owns its connections and opens
    /// a new one when the old one is closed (GOAWAY, failure).
    _owned: ?*Owned = null,
    /// True when `connect` allocated `authority`.
    owns_authority: bool = false,

    const Owned = struct {
        gpa: std.mem.Allocator,
        options: h2.ConnectOptions,
        http: Http,
        http3: Http3,
        /// Guards the fields below; never held across a dial (SAFETY.md L2).
        mutex: safety.Mutex(.leaf) = .init,
        /// `activeH2`/`activeH3` are dialing (single flight: a channel uses
        /// one of them; `.auto`'s HTTP/3 dial is `h3_dialing`, which never
        /// makes a call wait). Calls that need the dial wait on `dialed`.
        redialing: bool = false,
        dialed: safety.Condition = .init,
        /// Connections replaced by a redial: they may still carry calls,
        /// so they close with the channel.
        retired: std.ArrayList(*h2.ClientConnection) = .empty,
        retired3: std.ArrayList(*H3Connection) = .empty,
        /// `.auto`: what Alt-Svc advertised, whether a dial is running, when
        /// HTTP/3 may be tried again, and whether a call ever completed on
        /// it (then a lost connection is redialed rather than given up on).
        alt: ?struct { port: u16, until: std.Io.Clock.Timestamp } = null,
        h3_dialing: bool = false,
        h3_broken_until: ?std.Io.Clock.Timestamp = null,
        h3_succeeded: bool = false,
        h3_port: u16 = 0,
        /// HTTP/3 dials made (tests).
        h3_dials: u32 = 0,
        /// Tickets for resuming QUIC sessions on a redial.
        cache: if (features.http3) wire.h3.SessionCache else void = undefined,
        has_cache: bool = false,
    };

    /// What `connect` takes besides the connection's options.
    pub const Options = struct {
        authority: ?[]const u8 = null, // null: host:port ("localhost" for a Unix socket)
        scheme: ?[]const u8 = null, // null: "https" with TLS, else "http"
        retry: ?resilience.Retry = null,
        retry_codes: []const Code = &.{.unavailable},
        breaker: ?resilience.Breaker.Options = null,
        max_message_size: usize = 4 * 1024 * 1024,
        max_received_bytes: usize = 64 * 1024 * 1024,
        /// Which HTTP version calls use.
        http: Http = .h2,
        /// HTTP/3 settings for `.h3` and `.auto`.
        http3: Http3 = .{},
    };

    /// A channel that owns its connection and redials it lazily: the next
    /// call after the connection closed opens a new one (one dial at a
    /// time; other calls wait for it). `options` (host and TLS slices
    /// included) must outlive the channel. A `host` of "unix:/path" dials a
    /// Unix socket. `close` it.
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, options: h2.ConnectOptions, channel: Options) !*Channel {
        if (channel.http != .h2) {
            if (comptime !features.http3) return error.Http3NotBuiltIn;
            if (options.tls == null or h2.unixTarget(options.host) != null) return error.Http3NeedsTls;
        }
        const self = try gpa.create(Channel);
        errdefer gpa.destroy(self);
        const owned = try gpa.create(Owned);
        errdefer gpa.destroy(owned);
        owned.* = .{ .gpa = gpa, .options = options, .http = channel.http, .http3 = channel.http3 };
        if (comptime features.http3) if (channel.http != .h2) {
            owned.cache = wire.h3.SessionCache.init(gpa, io);
            owned.has_cache = true;
        };
        errdefer if (comptime features.http3) if (owned.has_cache) owned.cache.deinit();
        const authority = channel.authority orelse if (h2.unixTarget(options.host) != null)
            "localhost"
        else
            try std.fmt.allocPrint(gpa, "{s}:{d}", .{ options.host, options.port });
        errdefer if (channel.authority == null and h2.unixTarget(options.host) == null) gpa.free(authority);
        self.* = .{
            .authority = authority,
            .scheme = channel.scheme orelse if (options.tls != null) "https" else "http",
            .max_message_size = channel.max_message_size,
            .max_received_bytes = channel.max_received_bytes,
            .retry = channel.retry,
            .retry_codes = channel.retry_codes,
            .breaker = if (channel.breaker) |o| resilience.Breaker.init(o, .grpc, authority) else null,
            ._throttle = .init(if (channel.retry) |r| (r.throttle orelse .{}) else .{}),
            ._owned = owned,
        };
        self.owns_authority = channel.authority == null and h2.unixTarget(options.host) == null;
        if (channel.http == .h3) {
            self.h3 = try dialH3(owned, io, channel.http3.port orelse options.port);
            owned.h3_dials += 1;
            owned.h3_port = channel.http3.port orelse options.port;
        } else {
            self.conn = try h2.ClientConnection.connect(gpa, io, options);
        }
        return self;
    }

    /// Closes the connections and frees the channel (from `connect`).
    pub fn close(self: *Channel) void {
        const owned = self._owned orelse return;
        const gpa = owned.gpa;
        if (self.conn) |c| c.close();
        if (comptime features.http3) {
            if (self.h3) |c| c.close();
            for (owned.retired3.items) |c| c.close();
            owned.retired3.deinit(gpa);
            if (owned.has_cache) owned.cache.deinit();
        }
        for (owned.retired.items) |c| c.close();
        owned.retired.deinit(gpa);
        if (self.owns_authority) gpa.free(self.authority);
        gpa.destroy(owned);
        gpa.destroy(self);
    }

    /// The runtime the channel's connections run on.
    pub fn runtime(self: *const Channel) std.Io {
        if (self.conn) |c| return c.io;
        if (comptime features.http3) if (self.h3) |c| return c.io;
        unreachable;
    }

    /// The transport the next call goes out on (a connection that is open;
    /// `.auto` may still switch at the call).
    pub fn transport(self: *Channel) Transport {
        if (self.h3) |c| if (comptime features.http3) {
            if (self.conn == null or c.isOpen()) return .h3;
        };
        return .h2;
    }

    /// HTTP/3 dials made (tests).
    pub fn h3DialCount(self: *Channel) u32 {
        const owned = self._owned orelse return 0;
        return owned.h3_dials;
    }

    /// The connection a call goes out on. `prefer_h2` is for the retry of
    /// a call HTTP/3 failed to carry (`.auto`).
    fn pick(self: *Channel, prefer_h2: bool) !wire.Conn {
        const owned = self._owned orelse {
            if ((self.conn == null) == (self.h3 == null)) return error.ChannelConnection;
            if (self.h3) |c| return .{ .h3 = c };
            return .{ .h2 = self.conn.? };
        };
        switch (owned.http) {
            .h2 => return .{ .h2 = try self.activeH2() },
            .h3 => return .{ .h3 = try self.activeH3() },
            .auto => {
                if (comptime !features.http3) return .{ .h2 = try self.activeH2() };
                if (!prefer_h2) if (try self.autoH3()) |c| return .{ .h3 = c };
                return .{ .h2 = try self.activeH2() };
            },
        }
    }

    /// The HTTP/2 connection of an owned channel: a fresh one when the
    /// current has gone. One dial at a time, with no lock held across it
    /// (SAFETY.md L2): the calls that find it running wait for it, then
    /// look again; a failed dial fails only its own call. `isOpen` takes
    /// the connection's own lock, so it is asked with the channel's let go.
    fn activeH2(self: *Channel) !*h2.ClientConnection {
        const owned = self._owned orelse return self.conn.?;
        const io_ = self.runtime();
        while (true) {
            const current = self.conn;
            if (current) |c| if (c.isOpen()) return c;
            owned.mutex.lockUncancelable(io_);
            defer owned.mutex.unlock(io_);
            // Another call is dialing, or has dialed since `current` was
            // read: look again once it is done.
            if (owned.redialing) {
                owned.dialed.waitUncancelable(io_, &owned.mutex);
                continue;
            }
            if (self.conn != current) continue;
            owned.redialing = true;
            break;
        }
        const dial = h2.ClientConnection.connect(owned.gpa, io_, owned.options);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.redialing = false;
        owned.dialed.broadcast(io_);
        const fresh = try dial;
        errdefer fresh.close();
        if (self.conn) |old| try owned.retired.append(owned.gpa, old);
        self.conn = fresh;
        return fresh;
    }

    /// The HTTP/3 connection of a `.h3` channel, redialed when it has gone,
    /// as `activeH2` does.
    fn activeH3(self: *Channel) !*H3Connection {
        if (comptime !features.http3) unreachable;
        const owned = self._owned.?;
        const io_ = self.runtime();
        while (true) {
            const current = self.h3;
            if (current) |c| if (c.isOpen()) return c;
            owned.mutex.lockUncancelable(io_);
            defer owned.mutex.unlock(io_);
            if (owned.redialing) {
                owned.dialed.waitUncancelable(io_, &owned.mutex);
                continue;
            }
            if (self.h3 != current) continue;
            owned.redialing = true;
            break;
        }
        const dial = dialH3(owned, io_, owned.h3_port);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.redialing = false;
        owned.dialed.broadcast(io_);
        const fresh = try dial;
        errdefer fresh.close();
        owned.h3_dials += 1;
        if (self.h3) |old| try owned.retired3.append(owned.gpa, old);
        self.h3 = fresh;
        return fresh;
    }

    /// `.auto`: the HTTP/3 connection if there is one to use, dialing it
    /// when Alt-Svc advertised it. Null: go over HTTP/2. Never waits for
    /// another call's dial.
    fn autoH3(self: *Channel) !?*H3Connection {
        const owned = self._owned.?;
        const io_ = self.runtime();
        // `isOpen` takes the connection's own lock: asked before the
        // channel's is taken.
        const current = self.h3;
        if (current) |c| if (c.isOpen()) return c;
        owned.mutex.lockUncancelable(io_);
        // Another call dialed meanwhile: its connection is the one to use.
        if (self.h3 != current) {
            const newer = self.h3;
            owned.mutex.unlock(io_);
            return newer;
        }
        const now = std.Io.Clock.Timestamp.now(io_, .awake);
        const port: u16 = blk: {
            if (owned.alt) |a| if (now.compare(.lt, a.until)) break :blk a.port;
            // Lost a connection that had worked: back to the same port.
            if (self.h3 != null and owned.h3_succeeded and owned.h3_port != 0) break :blk owned.h3_port;
            owned.mutex.unlock(io_);
            return null;
        };
        const broken = if (owned.h3_broken_until) |b| now.compare(.lt, b) else false;
        if (broken or owned.h3_dialing) {
            owned.mutex.unlock(io_);
            return null;
        }
        owned.h3_dialing = true;
        owned.h3_dials += 1;
        owned.mutex.unlock(io_);

        const dialed = dialH3(owned, io_, port);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.h3_dialing = false;
        const fresh = dialed catch {
            owned.h3_broken_until = std.Io.Clock.Timestamp.now(io_, .awake).addDuration(.{ .raw = owned.http3.retry_after, .clock = .awake });
            return null;
        };
        owned.h3_port = port;
        owned.h3_succeeded = false;
        if (self.h3) |old| owned.retired3.append(owned.gpa, old) catch {
            fresh.close();
            return null;
        };
        self.h3 = fresh;
        return fresh;
    }

    /// The Alt-Svc of a response on an `.auto` channel.
    fn learn(self: *Channel, value: []const u8) void {
        if (comptime !features.http3) return;
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        const found = alt_svc.parse(value, owned.options.host);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        switch (found) {
            .none => {},
            .clear => owned.alt = null,
            .h3 => |a| owned.alt = .{
                .port = a.port,
                .until = std.Io.Clock.Timestamp.now(io_, .awake).addDuration(.{ .raw = .fromSeconds(a.max_age_s), .clock = .awake }),
            },
        }
    }

    /// A call completed on the HTTP/3 connection (`.auto`).
    fn h3Worked(self: *Channel) void {
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        owned.mutex.lockUncancelable(io_);
        owned.h3_succeeded = true;
        owned.mutex.unlock(io_);
    }

    /// An HTTP/3 call could not be carried (`.auto`): until a call has
    /// worked on it, give HTTP/3 up for `retry_after`.
    fn h3Failed(self: *Channel) void {
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        if (owned.h3_succeeded) return;
        owned.h3_broken_until = std.Io.Clock.Timestamp.now(io_, .awake).addDuration(.{ .raw = owned.http3.retry_after, .clock = .awake });
    }
};

/// Dials HTTP/3 with the channel's options: the same host and TLS, the
/// UDP `port`.
fn dialH3(owned: *Channel.Owned, io: std.Io, port: u16) !*H3Connection {
    if (comptime !features.http3) unreachable;
    const o = owned.options;
    const t = o.tls.?;
    var address = o.address;
    if (address) |*a| switch (a.*) {
        inline else => |*x| x.port = port,
    };
    var timeout = o.connect_timeout;
    if (owned.http == .auto) timeout = owned.http3.connect_timeout;
    return wire.h3.ClientConnection.connect(owned.gpa, io, .{
        .host = o.host,
        .port = port,
        .address = address,
        .tls = .{ .ca = t.ca, .insecure_skip_verify = t.insecure_skip_verify, .client_certificate = t.client_certificate },
        .stream_window = owned.http3.stream_window,
        .max_data = o.max_data,
        .idle_timeout = owned.http3.idle_timeout,
        .connect_timeout = timeout,
        .timeout = o.timeout,
        .max_header_list_size = o.max_header_list_size,
        .session_cache = if (owned.has_cache) &owned.cache else null,
    });
}

/// Per call: deadline, metadata, compression.
pub const CallOptions = struct {
    /// Sent as grpc-timeout; the server ends the call past it, and the
    /// client resets the stream past it (DEADLINE_EXCEEDED either way).
    timeout: ?std.Io.Duration = null,
    /// Extra request metadata, lower-case names.
    metadata: []const h2.Header = &.{},
    /// Compress request messages (and accept compressed responses).
    compression: Compression = .identity,
    /// The channel's `max_received_bytes` for this call, when set.
    max_received_bytes: ?usize = null,
    /// `.inherit` (the channel's), `.off`, or `.on` with a policy of its
    /// own. Unary calls only.
    retry: resilience.Choice = .inherit,
};

/// What `Client.unary` returns: the status, and the response message when
/// the status is OK. A failed call is a status, not an error; errors are
/// for the call not being made at all, and `error.Canceled` when the
/// calling task is canceled (the call is then reset).
pub fn UnaryResult(comptime Resp: type) type {
    return struct {
        status: Status,
        /// Null unless the status is OK.
        message: ?Resp,
        /// Response headers and trailers, as received.
        headers: []const h2.Header,
        trailers: []const h2.Header,
        /// The HTTP version that carried the call.
        transport: Transport = .h2,
    };
}

/// A call in progress: requests out, responses in, then the status.
pub fn Stream(comptime Req: type, comptime Resp: type) type {
    return struct {
        const Self = @This();

        channel: *Channel,
        stream: wire.Stream,
        arena: std.mem.Allocator,
        compression: Compression,
        /// Set once the response has ended: from the trailers, or from the
        /// headers of a trailers-only response.
        status: ?Status = null,
        head_checked: bool = false,
        /// The call's deadline, when it has one: a call that ends without a
        /// status past it ended for that reason.
        deadline: ?std.Io.Clock.Timestamp = null,
        /// The limit on response bytes for the call, and what it has
        /// received so far.
        max_received_bytes: usize = std.math.maxInt(usize),
        received: usize = 0,
        /// The connection went before any response head came.
        lost_before_head: bool = false,

        /// The HTTP version that carries this call.
        pub fn transport(self: *const Self) Transport {
            return std.meta.activeTag(self.stream);
        }

        fn pastDeadline(self: *const Self) bool {
            const d = self.deadline orelse return false;
            return std.Io.Clock.Timestamp.now(self.channel.runtime(), .awake).compare(.gte, d);
        }

        /// What a call that ended without a status reports. Past the
        /// deadline: DEADLINE_EXCEEDED. Canceled here: CANCELLED. Reset by
        /// the server: by its code (gRFC G2's HTTP/3 table,
        /// PROTOCOL-HTTP2.md's HTTP/2 table). Connection gone, no code:
        /// UNAVAILABLE.
        fn transportStatus(self: *const Self, err: h2.StreamError) Status {
            switch (err) {
                error.Timeout => return .init(.deadline_exceeded, "deadline exceeded"),
                error.Canceled => return .init(.cancelled, "cancelled"),
                error.HeadersTooLarge, error.TooManyInterimResponses => return .init(.internal, @errorName(err)),
                error.StreamReset, error.ConnectionClosed => {
                    if (self.pastDeadline()) return .init(.deadline_exceeded, "deadline exceeded");
                    if (err == error.ConnectionClosed) return .init(.unavailable, "connection closed");
                    if (self.stream.resetCode()) |code| return resetStatus(self.arena, code);
                    return .init(.unavailable, "stream reset");
                },
            }
        }

        /// A cancel of the calling task (not `cancel`/`release`): the call
        /// is reset and ends CANCELLED, and the caller passes the cancel on
        /// (SAFETY.md C3).
        fn taskCanceled(self: *Self, err: h2.StreamError) bool {
            if (err != error.Canceled or self.stream.canceledLocally()) return false;
            self.status = .init(.cancelled, "cancelled");
            // RST_STREAM CANCEL / H3_REQUEST_CANCELLED, as grpc aio and Go do.
            self.stream.cancel();
            return true;
        }

        /// What a failed write returns: `error.Canceled` when the calling
        /// task was canceled, else `error.StreamClosed`.
        fn writeFailed(self: *Self) error{ Canceled, StreamClosed } {
            if (self.stream.writeError()) |e| if (self.taskCanceled(e)) return error.Canceled;
            return error.StreamClosed;
        }

        /// Sends one request message. Fails with `error.StreamClosed`
        /// once the call has ended (read the status with `receive`), and
        /// with `error.Canceled` when the calling task is canceled (the
        /// call is reset).
        pub fn send(self: *Self, message: Req) !void {
            var encoded: std.Io.Writer.Allocating = .init(self.arena);
            try message.encode(&encoded.writer, self.arena);
            const framed = try frame.encodeWithCompression(self.arena, encoded.written(), self.compression);
            const w = self.stream.writer();
            w.writeAll(framed) catch return self.writeFailed();
            w.flush() catch return self.writeFailed();
        }

        /// No more requests (half-close).
        pub fn closeSend(self: *Self) !void {
            self.stream.closeSend() catch return self.writeFailed();
        }

        /// The next response, or null at the end of the call, when `status`
        /// is set. `error.Canceled` when the calling task is canceled: the
        /// call is reset, and `status` is CANCELLED.
        pub fn receive(self: *Self) !?Resp {
            if (self.status != null) return null;
            if (!self.head_checked) {
                self.head_checked = true;
                self.stream.waitHead() catch |err| {
                    if (self.taskCanceled(err)) return error.Canceled;
                    self.lost_before_head = err == error.ConnectionClosed;
                    self.status = self.transportStatus(err);
                    return null;
                };
                switch (self.stream) {
                    .h2 => if (self.stream.header("alt-svc")) |v| self.channel.learn(v),
                    .h3 => self.channel.h3Worked(),
                }
                if (self.stream.status() != 200) {
                    self.status = .init(httpStatusCode(self.stream.status()), "HTTP status");
                    return null;
                }
                // Trailers-only: the status is in the headers.
                if (self.stream.header("grpc-status")) |_| {
                    self.status = try self.statusFromFields(.headers);
                    return null;
                }
            }
            const encoding: Compression = if (self.stream.header("grpc-encoding")) |e| Compression.parse(e) orelse .identity else .identity;
            // Read and inflated outside the arena, freed once decoded.
            const msg = frame.readMessage(self.stream.reader(), server.scratch, self.channel.max_message_size, encoding) catch |err| {
                if (err == error.ReadFailed) if (self.stream.readError()) |e| if (self.taskCanceled(e)) return error.Canceled;
                self.status = switch (err) {
                    error.ReadFailed => if (self.stream.readError()) |e| self.transportStatus(e) else self.transportStatus(error.StreamReset),
                    error.MessageTooLarge => .init(.resource_exhausted, "message larger than the limit"),
                    else => .init(.internal, @errorName(err)),
                };
                return null;
            } orelse {
                self.status = try self.statusFromFields(.trailers);
                return null;
            };
            defer server.scratch.free(msg.payload);
            self.received +|= msg.payload.len + server.per_message_charge;
            if (self.received > self.max_received_bytes) {
                self.status = .init(.resource_exhausted, "response messages over the call's limit");
                self.stream.cancel();
                return null;
            }
            var reader: std.Io.Reader = .fixed(msg.payload);
            return Resp.decode(&reader, self.arena) catch {
                self.status = .init(.internal, "response did not decode");
                self.stream.cancel();
                return null;
            };
        }

        fn statusFromFields(self: *Self, which: enum { headers, trailers }) !Status {
            const code_text = if (which == .headers) self.stream.header("grpc-status") else self.stream.trailer("grpc-status");
            const message_text = if (which == .headers) self.stream.header("grpc-message") else self.stream.trailer("grpc-message");
            const code: ?Code = if (code_text) |t| Code.fromInt(std.fmt.parseInt(u32, t, 10) catch 2) else null;
            const message = if (message_text) |t| try self.arena.dupe(u8, try percentDecode(self.arena, t)) else "";
            return .init(code orelse .internal, if (code == null) "missing grpc-status" else message);
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

        /// A unary call (or a server-streaming one's first response). With
        /// a retry policy (the channel's, or `options.retry`) a status in
        /// `retry_codes` is retried within the call's `timeout`; with a
        /// breaker, a target that keeps failing answers UNAVAILABLE
        /// "circuit open" without a call.
        pub fn unary(self: Self, comptime method: []const u8, arena: std.mem.Allocator, request: MethodOf(method).Request, options: CallOptions) !UnaryResult(MethodOf(method).Response) {
            const M = MethodOf(method);
            const ch = self.channel;
            const policy_retry = options.retry.resolve(ch.retry);
            if (policy_retry == null and ch.breaker == null) {
                const once = try unaryOnce(M, ch, path(method), arena, request, options);
                return once.result;
            }
            const Ctx = struct {
                ch: *Channel,
                arena: std.mem.Allocator,
                request: M.Request,
                options: CallOptions,
                started: std.Io.Clock.Timestamp,
                attempt_timeout: ?std.Io.Duration = null,
            };
            const Judge = UnaryJudge(M.Response);
            const A = Judge.Attempt;
            const attempt = struct {
                fn run(ctx: *Ctx, n: u32) A {
                    var opts = ctx.options;
                    if (n > 1) {
                        const extra = ctx.arena.alloc(h2.Header, opts.metadata.len + 1) catch
                            return .{ .result = error.OutOfMemory, .codes = ctx.ch.retry_codes };
                        @memcpy(extra[0..opts.metadata.len], opts.metadata);
                        extra[opts.metadata.len] = .{ .name = "grpc-previous-rpc-attempts", .value = std.fmt.allocPrint(ctx.arena, "{d}", .{n - 1}) catch "1" };
                        opts.metadata = extra;
                        if (ctx.options.timeout) |t| {
                            const spent = ctx.started.durationTo(std.Io.Clock.Timestamp.now(ctx.ch.runtime(), .awake)).raw.nanoseconds;
                            opts.timeout = .{ .nanoseconds = @max(1_000_000, t.nanoseconds - spent) };
                        }
                    }
                    // One attempt's own bound (`Retry.attempt_timeout`), within
                    // what is left of the call's.
                    if (ctx.attempt_timeout) |at| {
                        opts.timeout = if (opts.timeout) |t| .{ .nanoseconds = @min(t.nanoseconds, at.nanoseconds) } else at;
                    }
                    var out = unaryOnce(M, ctx.ch, path(method), ctx.arena, ctx.request, opts);
                    // Not processed by the server: once more, not counted.
                    if (out) |o| {
                        if (o.unprocessed) out = unaryOnce(M, ctx.ch, path(method), ctx.arena, ctx.request, opts);
                    } else |_| {}
                    return .{ .result = if (out) |o| o.result else |e| e, .codes = ctx.ch.retry_codes };
                }
            }.run;
            const now = std.Io.Clock.Timestamp.now(ch.runtime(), .awake);
            var ctx: Ctx = .{ .ch = ch, .arena = arena, .request = request, .options = options, .started = now, .attempt_timeout = if (policy_retry) |r| r.attempt_timeout else null };
            const rp: resilience.Policy = .{
                .retry = policy_retry,
                .breaker = if (ch.breaker) |*b| b else null,
                .throttle = if (policy_retry != null and policy_retry.?.throttle != null) &ch._throttle else null,
                .deadline = if (options.timeout) |t| now.addDuration(.{ .raw = t, .clock = .awake }) else null,
                .kind = .grpc,
                .target = ch.authority,
            };
            const res = resilience.run(ch.runtime(), rp, &ctx, attempt, Judge) catch |err| switch (err) {
                error.CircuitOpen => return .{
                    .status = .init(.unavailable, "circuit open"),
                    .message = null,
                    .headers = &.{},
                    .trailers = &.{},
                },
                else => |e| return e,
            };
            return res.result;
        }
    };
}

/// One unary attempt, and whether the server provably did not process it.
/// On an `.auto` channel, a call HTTP/3 failed to carry (never processed,
/// or the connection lost before a response) goes once more over HTTP/2.
fn unaryOnce(comptime M: type, channel: *Channel, method_path: []const u8, arena: std.mem.Allocator, request: M.Request, options: CallOptions) !struct { result: UnaryResult(M.Response), unprocessed: bool } {
    const first = try unaryTry(M, channel, method_path, arena, request, options, false);
    if (first.transport == .h3 and (first.unprocessed or first.lost_before_head)) if (channel._owned) |o| if (o.http == .auto) {
        channel.h3Failed();
        const second = try unaryTry(M, channel, method_path, arena, request, options, true);
        return .{ .result = second.result, .unprocessed = second.unprocessed };
    };
    return .{ .result = first.result, .unprocessed = first.unprocessed };
}

fn unaryTry(comptime M: type, channel: *Channel, method_path: []const u8, arena: std.mem.Allocator, request: M.Request, options: CallOptions, prefer_h2: bool) !struct { result: UnaryResult(M.Response), unprocessed: bool, transport: Transport, lost_before_head: bool } {
    var s = try openOn(M.Request, M.Response, channel, method_path, arena, options, prefer_h2);
    defer s.deinit();
    try s.send(request);
    try s.closeSend();
    const message = try s.receive();
    // Drain to the trailers.
    if (message != null) while (try s.receive()) |_| {};
    const st = s.status orelse Status.init(.internal, "no status");
    return .{
        .result = .{
            .status = st,
            .message = if (st.code == .ok) message else null,
            // Copied out: the stream (and what it received) is freed
            // on return.
            .headers = try s.stream.copyHeaders(s.arena),
            .trailers = try s.stream.copyTrailers(s.arena),
            .transport = s.transport(),
        },
        .unprocessed = st.code == .unavailable and s.stream.unprocessed(),
        .transport = s.transport(),
        .lost_before_head = s.lost_before_head,
    };
}

/// How `resilience.run` judges a unary attempt (gRPC A6).
fn UnaryJudge(comptime Resp: type) type {
    return struct {
        pub const Attempt = struct {
            result: anyerror!UnaryResult(Resp),
            codes: []const Code,
        };

        fn pushback(r: UnaryResult(Resp)) ?union(enum) { ms: u32, stop } {
            for (r.trailers) |t| {
                if (std.mem.eql(u8, t.name, "grpc-retry-pushback-ms")) {
                    const ms = std.fmt.parseInt(u32, std.mem.trim(u8, t.value, " "), 10) catch return .stop;
                    return .{ .ms = ms };
                }
            }
            return null;
        }

        pub fn verdict(a: *const Attempt) resilience.Verdict {
            // The caller's own cancel says nothing about the target.
            const r = a.result catch |e| return if (e == error.Canceled) .neutral else .failure;
            if (r.status.code == .ok) return .success;
            var retryable = false;
            for (a.codes) |c| if (c == r.status.code) {
                retryable = true;
            };
            if (retryable) {
                if (pushback(r)) |p| switch (p) {
                    .stop => return .failure,
                    .ms => {},
                };
                return .transient;
            }
            return if (r.status.code == .unavailable) .failure else .neutral;
        }

        pub fn retryAfter(a: *const Attempt) ?std.Io.Duration {
            const r = a.result catch return null;
            if (pushback(r)) |p| switch (p) {
                .ms => |ms| return .fromMilliseconds(ms),
                .stop => {},
            };
            return null;
        }

        pub fn reason(_: *const Attempt) []const u8 {
            return "code";
        }
    };
}

/// Opens a call by path, for code without a generated service type.
pub fn open(comptime Req: type, comptime Resp: type, channel: *Channel, method_path: []const u8, arena: std.mem.Allocator, options: CallOptions) !Stream(Req, Resp) {
    return openOn(Req, Resp, channel, method_path, arena, options, false);
}

fn openOn(comptime Req: type, comptime Resp: type, channel: *Channel, method_path: []const u8, arena: std.mem.Allocator, options: CallOptions, prefer_h2: bool) !Stream(Req, Resp) {
    const conn = try channel.pick(prefer_h2);
    var headers: std.ArrayList(h2.Header) = .empty;
    try headers.appendSlice(arena, &.{
        .{ .name = ":method", .value = "POST" },
        // gRFC G2: HTTP/3 is always TLS.
        .{ .name = ":scheme", .value = if (conn == .h3) "https" else channel.scheme },
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
    const io = conn.io();
    const call_deadline: ?std.Io.Clock.Timestamp = if (options.timeout) |t|
        std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = t, .clock = .awake })
    else
        null;
    // The deadline bounds the stream on this side too; a call without one
    // may stream for as long as it likes.
    const s = try conn.request(arena, headers.items, if (call_deadline) |d| .{ .deadline = d } else .none, call_send_buffer);
    return .{
        .channel = channel,
        .stream = s,
        .arena = arena,
        .compression = options.compression,
        .deadline = call_deadline,
        .max_received_bytes = options.max_received_bytes orelse channel.max_received_bytes,
    };
}

/// How much request data a call may have unacknowledged over HTTP/3.
const call_send_buffer = 1 << 20;

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

/// What a server's reset of a call's stream means (PROTOCOL-HTTP2.md for
/// HTTP/2, gRFC G2 for HTTP/3; the two code ranges do not overlap).
/// `arena` formats the message of an unlisted code.
pub fn resetStatus(arena: std.mem.Allocator, code: u64) Status {
    return switch (code) {
        // REFUSED_STREAM, H3_REQUEST_REJECTED: never processed.
        0x7, 0x10b => .init(.unavailable, "the server refused the stream"),
        // CANCEL, H3_REQUEST_CANCELLED.
        0x8, 0x10c => .init(.cancelled, "the server canceled the call"),
        // ENHANCE_YOUR_CALM, H3_EXCESSIVE_LOAD.
        0xb, 0x107 => .init(.resource_exhausted, "the server reports excessive load (bandwidth)"),
        // INADEQUATE_SECURITY.
        0xc => .init(.permission_denied, "the connection is not secure enough for the call"),
        else => .init(.internal, std.fmt.allocPrint(arena, "stream reset by the server (code 0x{x})", .{code}) catch "stream reset by the server"),
    };
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
pub const ChannelOptions = Channel.Options;

test "resetStatus maps HTTP/2 and HTTP/3 codes (G2, PROTOCOL-HTTP2)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_]struct { code: u64, want: Code }{
        .{ .code = 0x7, .want = .unavailable },
        .{ .code = 0x10b, .want = .unavailable },
        .{ .code = 0x8, .want = .cancelled },
        .{ .code = 0x10c, .want = .cancelled },
        .{ .code = 0xb, .want = .resource_exhausted },
        .{ .code = 0x107, .want = .resource_exhausted },
        .{ .code = 0xc, .want = .permission_denied },
        .{ .code = 0x0, .want = .internal },
        .{ .code = 0x2, .want = .internal },
        .{ .code = 0x100, .want = .internal },
        .{ .code = 0x110, .want = .internal },
        .{ .code = 0x52e4a40fa8db, .want = .internal },
    };
    for (rows) |r| try std.testing.expectEqual(r.want, resetStatus(a, r.code).code);
    try std.testing.expectEqualStrings("stream reset by the server (code 0x52e4a40fa8db)", resetStatus(a, 0x52e4a40fa8db).message);
}
