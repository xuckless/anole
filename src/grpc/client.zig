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
const dusty = @import("dusty");
const builtin = @import("builtin");
const h2 = @import("anole_h2_client");
const frame = @import("frame.zig");
const status_mod = @import("status.zig");
const deadline = @import("deadline.zig");
const Compression = @import("compression.zig").Compression;
const server = @import("server.zig");
const resilience = @import("resilience_core");
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
        /// Guards the fields below; never held across a dial.
        mutex: std.Io.Mutex = .init,
        /// `redial` is dialing: one at a time (a channel redials one
        /// transport; `.auto`'s HTTP/3 dial is `h3.gate`, which never makes a
        /// call wait). Calls that need the dial wait on `dialed`.
        redialing: bool = false,
        dialed: std.Io.Condition = .init,
        /// Connections replaced by a redial: they may still carry calls,
        /// so they close with the channel.
        retired: std.ArrayList(*h2.ClientConnection) = .empty,
        retired3: std.ArrayList(*H3Connection) = .empty,
        /// `.auto`: what is known about HTTP/3; every change is `H3State.next`.
        h3: if (features.http3) H3State else void = if (features.http3) .{} else {},
        /// HTTP/3 dials made (tests).
        h3_dials: u32 = 0,
        /// Tickets for resuming QUIC sessions on a redial; null on `.h2`.
        cache: if (features.http3) ?wire.h3.SessionCache else void = if (features.http3) null else {},

        /// When HTTP/3 may be tried again after a failure now.
        fn retryAt(owned: *const Owned, io: std.Io) std.Io.Timestamp {
            return std.Io.Timestamp.now(io, .awake).addDuration(owned.http3.retry_after);
        }
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
        };
        errdefer if (comptime features.http3) if (owned.cache) |*c| c.deinit();
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
            if (owned.cache) |*c| c.deinit();
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
            .h2 => return .{ .h2 = try self.redial(.h2) },
            .h3 => return .{ .h3 = try self.redial(.h3) },
            .auto => {
                if (comptime !features.http3) return .{ .h2 = try self.redial(.h2) };
                if (!prefer_h2) if (try self.autoH3()) |c| return .{ .h3 = c };
                return .{ .h2 = try self.redial(.h2) };
            },
        }
    }

    /// The connection of an owned channel on transport `t` (`.h2`, or
    /// `.h3` by prior knowledge): a fresh one when the current has gone.
    /// One dial at a time, with no lock held across it: the calls that find
    /// it running wait for it, then look again; a failed dial fails only its
    /// own call. `isOpen` takes the connection's own lock, so it is asked
    /// with the channel's let go.
    fn redial(self: *Channel, comptime t: Transport) !@FieldType(wire.Conn, @tagName(t)) {
        if (comptime t == .h3 and !features.http3) unreachable;
        const owned = self._owned.?;
        const slot = if (comptime t == .h2) &self.conn else &self.h3;
        const retired = if (comptime t == .h2) &owned.retired else &owned.retired3;
        const io_ = self.runtime();
        while (true) {
            const current = slot.*;
            if (current) |c| if (c.isOpen()) return c;
            owned.mutex.lockUncancelable(io_);
            defer owned.mutex.unlock(io_);
            // Another call is dialing, or has dialed since `current` was
            // read: look again once it is done.
            if (owned.redialing) {
                owned.dialed.waitUncancelable(io_, &owned.mutex);
                continue;
            }
            // The defer unlocks on `continue` and `break` alike; `slot`'s plain reads are D2's race.
            if (slot.* != current) continue;
            owned.redialing = true;
            break;
        }
        const dial = if (comptime t == .h2)
            h2.ClientConnection.connect(owned.gpa, io_, owned.options)
        else
            dialH3(owned, io_, owned.http3.port orelse owned.options.port);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        // Waiters are woken under the lock before `try dial`: a failed dial lets each dial in turn.
        owned.redialing = false;
        owned.dialed.broadcast(io_);
        const fresh = try dial;
        errdefer fresh.close();
        if (comptime t == .h3) owned.h3_dials += 1;
        if (slot.*) |old| try retired.append(owned.gpa, old);
        slot.* = fresh;
        return fresh;
    }

    /// `.auto`: the HTTP/3 connection if there is one to use, dialing it
    /// when Alt-Svc advertised it. Null: go over HTTP/2. Never waits for
    /// another call's dial.
    fn autoH3(self: *Channel) !?*H3Connection {
        const owned = self._owned.?;
        const io_ = self.runtime();
        // `isOpen` takes the connection's own lock: asked with the
        // channel's let go. Another call dialed meanwhile: its connection is
        // the one to use, once it is seen open (it may have gone too).
        while (true) {
            const current = self.h3;
            if (current) |c| if (c.isOpen()) return c;
            testAutoH3BeforeLock(self);
            owned.mutex.lockUncancelable(io_);
            if (self.h3 == current) break;
            owned.mutex.unlock(io_);
        }
        // Held from here: the connection is the one found gone, or none.
        // The decision and `dial_start` share this critical section, so
        // two calls never both dial.
        const port = owned.h3.dialPort(std.Io.Timestamp.now(io_, .awake)) orelse {
            owned.mutex.unlock(io_);
            return null;
        };
        owned.h3 = owned.h3.next(.dial_start);
        owned.h3_dials += 1;
        owned.mutex.unlock(io_);

        const dialed = dialH3(owned, io_, port);
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        // A connection that cannot be retired (out of memory) counts as a failed dial.
        const fresh: ?*H3Connection = if (dialed) |c| retire: {
            if (self.h3) |old| owned.retired3.append(owned.gpa, old) catch {
                c.close();
                break :retire null;
            };
            break :retire c;
        } else |_| null;
        owned.h3 = owned.h3.next(if (fresh != null) .{ .dial_ok = port } else .{ .dial_failed = owned.retryAt(io_) });
        self.h3 = fresh orelse return null;
        return fresh;
    }

    /// Tests: runs once in `autoH3`, after it found the HTTP/3 connection
    /// it read gone and before it takes the channel's lock, where another
    /// call's dial can come in between. Test builds only.
    pub var test_auto_h3_before_lock: if (builtin.is_test) ?*const fn (*Channel) void else void = if (builtin.is_test) null else {};

    fn testAutoH3BeforeLock(self: *Channel) void {
        if (comptime !builtin.is_test) return;
        const hook = test_auto_h3_before_lock orelse return;
        test_auto_h3_before_lock = null;
        hook(self);
    }

    /// The Alt-Svc of a response on an `.auto` channel.
    fn learn(self: *Channel, value: []const u8) void {
        if (comptime !features.http3) return;
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        const ev: H3State.Event = switch (alt_svc.parse(value, owned.options.host)) {
            .none => return,
            .clear => .alt_clear,
            .h3 => |a| .{ .alt_set = .{
                .port = a.port,
                .until = std.Io.Timestamp.now(io_, .awake).addDuration(.fromSeconds(a.max_age_s)),
            } },
        };
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.h3 = owned.h3.next(ev);
    }

    /// A call completed on the HTTP/3 connection (`.auto`).
    fn h3Worked(self: *Channel) void {
        if (comptime !features.http3) return;
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.h3 = owned.h3.next(.call_worked);
    }

    /// An HTTP/3 call could not be carried (`.auto`): until a call has
    /// worked on it, give HTTP/3 up for `retry_after`.
    fn h3Failed(self: *Channel) void {
        if (comptime !features.http3) return;
        const owned = self._owned orelse return;
        if (owned.http != .auto) return;
        const io_ = self.runtime();
        owned.mutex.lockUncancelable(io_);
        defer owned.mutex.unlock(io_);
        owned.h3 = owned.h3.next(.{ .call_failed = owned.retryAt(io_) });
    }
};

/// What an `.auto` channel knows about HTTP/3: Alt-Svc advice, the last
/// connection dialed, and whether a dial may start. Every change is `next`,
/// under the channel's lock. `alt` moves only by `alt_set`/`alt_clear`;
/// `link` by `dial_ok` (set to `{port, worked = false}`) and `call_worked`
/// (`worked = true` when there is a link); `gate`, by this table (`t`: the
/// event's retry deadline; "worked": `link.worked`):
///
/// | gate \ event | dial_start    | dial_ok                | dial_failed(t) | call_worked | call_failed(t)                |
/// |--------------|---------------|------------------------|----------------|-------------|-------------------------------|
/// | idle         | dialing(null) | idle                   | broken(t)      | idle        | worked: idle; else broken(t)  |
/// | dialing(p)   | dialing(p)    | p: broken(p); else idle | broken(t)     | dialing(p)  | worked: dialing(p); else dialing(t) |
/// | broken(u)    | dialing(null) | broken(u)              | broken(t)      | broken(u)   | worked: broken(u); else broken(t) |
///
/// `dialing(p)`: a call failure while the dial runs is kept as `p` and
/// applies once the dial lands. dial_start while dialing and dial_ok while
/// not dialing cannot happen (`dialPort` guards `dial_start`). A lost
/// connection is not an event: `autoH3` finds it with `isOpen` and asks
/// `dialPort`, which redials a worked link on its port. Add behaviour as a
/// cell here, not as a branch in `autoH3`.
const H3State = struct {
    /// Alt-Svc advice (RFC 7838) and when it lapses.
    alt: ?Alt = null,
    /// The last HTTP/3 connection dialed: its UDP port, and whether a call
    /// completed on it. Null until a dial succeeds.
    link: ?Link = null,
    gate: Gate = .idle,

    /// On the awake clock.
    const Timestamp = std.Io.Timestamp;
    const Alt = struct { port: u16, until: Timestamp };
    const Link = struct { port: u16, worked: bool };
    const Gate = union(enum) {
        /// May dial when `dialPort` says so.
        idle,
        /// A dial is in flight (never waited for); the payload is a penalty
        /// a call failure recorded meanwhile.
        dialing: ?Timestamp,
        /// HTTP/2 only until then.
        broken: Timestamp,
    };
    const Event = union(enum) {
        alt_set: Alt,
        alt_clear,
        dial_start,
        /// The UDP port dialed.
        dial_ok: u16,
        /// No dial until then.
        dial_failed: Timestamp,
        call_worked,
        /// No dial until then, unless the link worked.
        call_failed: Timestamp,
    };

    /// The table above.
    fn next(s: H3State, ev: Event) H3State {
        var n = s;
        switch (ev) {
            .alt_set => |a| n.alt = a,
            .alt_clear => n.alt = null,
            .dial_start => n.gate = switch (s.gate) {
                .idle, .broken => .{ .dialing = null },
                .dialing => s.gate,
            },
            .dial_ok => |port| {
                n.link = .{ .port = port, .worked = false };
                n.gate = switch (s.gate) {
                    .dialing => |p| if (p) |u| .{ .broken = u } else .idle,
                    .idle, .broken => s.gate,
                };
            },
            .dial_failed => |t| n.gate = .{ .broken = t },
            .call_worked => if (s.link) |l| {
                n.link = .{ .port = l.port, .worked = true };
            },
            .call_failed => |t| {
                if (s.link) |l| if (l.worked) return s;
                n.gate = switch (s.gate) {
                    .idle, .broken => .{ .broken = t },
                    .dialing => .{ .dialing = t },
                };
            },
        }
        return n;
    }

    /// The port to dial at `now`, or null: none while dialing or broken;
    /// else fresh advice's port; else a worked link's (lost, redialed).
    fn dialPort(s: H3State, now: Timestamp) ?u16 {
        switch (s.gate) {
            .idle => {},
            .dialing => return null,
            .broken => |u| if (now.compare(.lt, u)) return null,
        }
        if (s.alt) |a| if (now.compare(.lt, a.until)) return a.port;
        const l = s.link orelse return null;
        return if (l.worked) l.port else null;
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
        .session_cache = if (owned.cache) |*c| c else null,
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
        /// is reset and ends CANCELLED, and the caller passes the cancel on.
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
            const message = if (message_text) |t| try self.arena.dupe(u8, try dusty.percentDecodeLenient(self.arena, t)) else "";
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

test "percentDecodeLenient undoes grpc-message encoding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a%b\né", try dusty.percentDecodeLenient(arena.allocator(), "a%25b%0A%C3%A9"));
    try std.testing.expectEqualStrings("plain", try dusty.percentDecodeLenient(arena.allocator(), "plain"));
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

test "grpc channel .auto: h3 state, every gate x event cell, and dialPort" {
    const at = struct {
        fn at(n: i96) H3State.Timestamp {
            return .fromNanoseconds(n);
        }
    }.at;
    const p = at(5);
    const u = at(6);
    const t = at(9);
    const events = [_]H3State.Event{ .dial_start, .{ .dial_ok = 443 }, .{ .dial_failed = t }, .call_worked, .{ .call_failed = t } };
    const unproven: H3State.Link = .{ .port = 80, .worked = false };
    const worked: H3State.Link = .{ .port = 80, .worked = true };
    // From each gate with an unproven link: the gate per the doc table, and the link each event leaves.
    const links = [events.len]H3State.Link{ unproven, .{ .port = 443, .worked = false }, unproven, worked, unproven };
    const rows = [_]struct { from: H3State.Gate, want: [5]H3State.Gate }{
        .{ .from = .idle, .want = .{ .{ .dialing = null }, .idle, .{ .broken = t }, .idle, .{ .broken = t } } },
        .{ .from = .{ .dialing = null }, .want = .{ .{ .dialing = null }, .idle, .{ .broken = t }, .{ .dialing = null }, .{ .dialing = t } } },
        .{ .from = .{ .dialing = p }, .want = .{ .{ .dialing = p }, .{ .broken = p }, .{ .broken = t }, .{ .dialing = p }, .{ .dialing = t } } },
        .{ .from = .{ .broken = u }, .want = .{ .{ .dialing = null }, .{ .broken = u }, .{ .broken = t }, .{ .broken = u }, .{ .broken = t } } },
    };
    try std.testing.expectEqual(std.enums.values(std.meta.Tag(H3State.Gate)).len + 1, rows.len);
    const alt: H3State.Alt = .{ .port = 443, .until = t };
    for (rows) |r| {
        errdefer std.debug.print("gate: {any}\n", .{r.from});
        for (events, r.want, links) |ev, want, link| {
            errdefer std.debug.print("event: {s}\n", .{@tagName(ev)});
            const from: H3State = .{ .link = unproven, .gate = r.from };
            try std.testing.expectEqual(H3State{ .link = link, .gate = want }, from.next(ev));
        }
        // A worked link: a call failure is a no-op and a dial resets it;
        // no link: call_worked is a no-op; Alt-Svc moves only `alt`.
        const w: H3State = .{ .link = worked, .gate = r.from };
        try std.testing.expectEqual(w, w.next(.{ .call_failed = t }));
        try std.testing.expectEqual(@as(?H3State.Link, .{ .port = 443, .worked = false }), w.next(.{ .dial_ok = 443 }).link);
        const none: H3State = .{ .gate = r.from };
        try std.testing.expectEqual(none, none.next(.call_worked));
        try std.testing.expectEqual(H3State{ .alt = alt, .link = worked, .gate = r.from }, w.next(.{ .alt_set = alt }));
        try std.testing.expectEqual(w, w.next(.{ .alt_set = alt }).next(.alt_clear));
    }

    const ports = [_]struct { s: H3State, now: i96, want: ?u16 }{
        .{ .s = .{}, .now = 1, .want = null },
        .{ .s = .{ .alt = alt }, .now = 1, .want = 443 },
        .{ .s = .{ .alt = alt }, .now = 9, .want = null }, // advice lapses at `until`
        .{ .s = .{ .alt = alt, .link = worked }, .now = 10, .want = 80 }, // lost, worked: same port
        .{ .s = .{ .alt = alt, .link = unproven }, .now = 10, .want = null },
        .{ .s = .{ .alt = alt, .link = worked }, .now = 1, .want = 443 },
        .{ .s = .{ .alt = alt, .gate = .{ .dialing = null } }, .now = 1, .want = null },
        .{ .s = .{ .alt = alt, .gate = .{ .broken = u } }, .now = 1, .want = null },
        .{ .s = .{ .alt = alt, .gate = .{ .broken = u } }, .now = 6, .want = 443 }, // penalty passed
        .{ .s = .{ .link = worked, .gate = .{ .broken = u } }, .now = 7, .want = 80 },
    };
    for (ports, 0..) |r, i| {
        errdefer std.debug.print("dialPort row {d}\n", .{i});
        try std.testing.expectEqual(r.want, r.s.dialPort(at(r.now)));
    }
}
