// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const Uri = std.Uri;
const tls = @import("tls");
/// A TLS module may load a CA bundle once into its own form
/// (`tls.TrustStore`: `init(bundle)`, `deinit()`), taken by each handshake
/// as `trust`, so none of them converts the bundle again. tls.zig has none.
const has_trust_store = build_options.use_tls and @hasDecl(tls, "TrustStore");
const TrustStore = if (has_trust_store) tls.TrustStore else void;
const build_options = @import("build_options");
/// An HTTP/2 client, injected as the `h2_client` import like `tls` and
/// `nghttp2` (src/h2_client_stub.zig lists what it must provide). With one,
/// `ClientOptions.http2` offers "h2" through ALPN, and a connection on which
/// the server picks it is handed to it after the handshake.
const h2_client = @import("h2_client");
const has_h2_client = build_options.use_tls and !@hasDecl(h2_client, "is_stub");

const unix_path_max = 108;

/// How long a request that failed to go out waits for the server's answer
/// anyway.
const early_response_wait: std.Io.Duration = .fromMilliseconds(50);

const config_mod = @import("config.zig");
const Cert = config_mod.Cert;
const Ca = config_mod.Ca;
const body_read_reserve = config_mod.body_read_reserve;

const http = @import("http.zig");
const Method = http.Method;
const Status = http.Status;
const Headers = http.Headers;
const ContentType = http.ContentType;
const ContentEncoding = http.ContentEncoding;

const WebSocket = @import("websocket.zig").WebSocket;
const placement = @import("placement.zig");

const ResponseParser = @import("parser.zig").ResponseParser;
const ParsedResponse = @import("parser.zig").ParsedResponse;
const ResponseBodyReader = @import("parser.zig").ResponseBodyReader;
const BodySource = @import("parser.zig").BodySource;
const Transport = @import("transport.zig").Transport;
const Deadline = @import("deadline.zig").Deadline;
const KeepAliveParams = @import("parser.zig").KeepAliveParams;
const resilience = @import("resilience_core");
const parseKeepAliveHeader = @import("parser.zig").parseKeepAliveHeader;

/// Protocol type for HTTP/HTTPS connections.
pub const Protocol = enum {
    http,
    https,

    pub fn defaultPort(self: Protocol) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }

    pub fn fromScheme(scheme: []const u8) error{UnsupportedScheme}!Protocol {
        if (std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "ws")) return .http;
        if (std.mem.eql(u8, scheme, "https") or std.mem.eql(u8, scheme, "wss")) return .https;
        return error.UnsupportedScheme;
    }
};

/// Negotiated HTTP wire version for a connection. Set after the TLS handshake
/// from the ALPN-selected protocol; defaults to HTTP/1.1 (cleartext, or TLS
/// without ALPN/with "http/1.1" selected).
pub const HttpVersion = enum {
    http_1_1,
    http_2,

    /// Maps a TLS ALPN protocol id ("h2", "http/1.1") to a version. An unknown
    /// or missing id falls back to HTTP/1.1.
    pub fn fromAlpn(alpn: ?[]const u8) HttpVersion {
        const id = alpn orelse return .http_1_1;
        if (std.mem.eql(u8, id, "h2")) return .http_2;
        return .http_1_1;
    }
};

test "nghttp2 links and reports a version" {
    // Only when built with HTTP/2: the `nghttp2` module doesn't exist otherwise,
    // and this comptime-false branch is skipped during analysis.
    if (build_options.use_http2) {
        const ng = @import("nghttp2");
        const info = ng.nghttp2_version(0);
        try std.testing.expect(info != null);
        try std.testing.expect(info.*.version_num != 0);
    }
}

/// Default User-Agent sent with requests unless overridden.
pub const default_user_agent = "anole/" ++ build_options.version;

/// Configuration for the HTTP client.
pub const ClientOptions = struct {
    /// Maximum number of redirects to follow (0 = disabled).
    max_redirects: u8 = 10,
    /// Maximum response body size in bytes.
    max_response_size: usize = 10_485_760, // 10MB
    /// Idle connections kept for reuse, in all, by each executor's pool
    /// (one pool per executor on zio, one in all elsewhere); 0 turns
    /// pooling off. Past it, the connection idle longest is closed.
    max_idle_connections: u16 = 1024,
    /// Idle connections kept for reuse to one host (scheme, host and port,
    /// or unix socket), by each executor's pool; 0 turns pooling off.
    ///
    /// Generous on purpose: when many requests fan in to one upstream,
    /// every connection beyond this that comes back is closed and the next
    /// request dials again, which costs a handshake, a socket in TIME_WAIT
    /// and memory churn on every round. Idle connections are only ever as
    /// many as were busy at once, and `idle_timeout` closes them after a
    /// burst. (Go's MaxIdleConnsPerHost of 2 is the cautionary tale; hyper
    /// and reqwest keep no per-host limit.)
    max_idle_per_host: u16 = 256,
    /// How long a pooled connection may sit unused before it is closed:
    /// by the pool's own task (one per executor, only while connections
    /// are idle), or when it is next looked at. A shorter `Keep-Alive:
    /// timeout=N` from the server wins. Null keeps idle connections until
    /// the server closes them or the pool evicts them. 90 s, as Go's
    /// IdleConnTimeout and hyper's default.
    idle_timeout: ?std.Io.Duration = .fromSeconds(90),
    /// Buffer size (bytes) for reading the response head: the status line
    /// and all headers. This is also the limit on it -- parsed header names
    /// and values are slices into this buffer rather than copies, so the head
    /// is held whole. A server that sends more gets error.HeadersTooLarge and
    /// its connection torn down.
    buffer_size: usize = 16384,
    /// TLS settings for https:// (and wss://) connections. Requires the
    /// `-Dtls` build option; with TLS compiled out any HTTPS request fails
    /// with error.TlsNotConfigured. Applies to every connection the client
    /// makes: connections are pooled and reused across requests, so the trust
    /// settings and client identity cannot be varied per request.
    tls: TlsOptions = .{},
    /// Maximum number of headers allowed in a response.
    max_response_header_count: usize = 64,
    /// Maximum time for `fetch`: connecting, the TLS handshake, sending,
    /// every redirect, and the response through the end of its body, or
    /// through the end of its head for a request that streams the body.
    /// Defaults to 30 seconds; set to null for no limit, or replace it for
    /// one request with `FetchOptions.timeout`.
    ///
    /// Costs a second task per request on any backend but zio, so on
    /// `std.Io.Threaded` a request with a timeout runs on a thread of its
    /// own, and where no second task can be had, as in a single-threaded
    /// build, the request fails with `error.ConcurrencyUnavailable`.
    timeout: ?std.Io.Duration = .fromSeconds(30),
    /// User-Agent header sent with requests. Set to null to omit it.
    /// A per-request User-Agent header takes precedence over this default.
    user_agent: ?[]const u8 = default_user_agent,
    /// Offer HTTP/2 ("h2") through TLS ALPN on HTTPS connections. Only
    /// effective with an injected HTTP/2 client (the `h2_client` import);
    /// ignored without one, and for cleartext (http://) connections. A
    /// connection on which the server picks h2 carries one request at a time
    /// and is pooled like an HTTP/1.1 one. Defaults off for now: without
    /// requests sharing a connection, h2 saves no connections, and its fixed
    /// 64 KiB stream window slows large downloads. Sharing comes in 0.4.
    http2: bool = false,
    /// Decides every redirect before it is followed (within
    /// `max_redirects`). Without one, redirects are followed, except one
    /// that would send the request's body (a 307 or 308) to another host,
    /// or to the same host over plain http from https: that response is
    /// returned as it is.
    check_redirect: ?RedirectPolicy = null,
    /// Refuse to talk to loopback, private, link-local (cloud metadata
    /// among them), shared, multicast and unspecified addresses, IPv4 and
    /// IPv6: `fetch` fails with `error.AddressNotAllowed` after the TCP
    /// connect, before any byte is sent, on the first hop and on every
    /// redirect. For clients that fetch URLs from untrusted input. Checks
    /// the address actually connected to, so a name that resolves to such
    /// an address is refused too. Unix sockets are not checked.
    deny_private_addresses: bool = false,
    /// Retries for fetches whose request may be repeated (see
    /// `FetchOptions.idempotent`); null: none beyond the transparent retry
    /// of a request lost on a reused connection, which stays. The
    /// whole-fetch `timeout` bounds all attempts together.
    retry: ?resilience.Retry = null,
    /// Statuses a retry is made for.
    retry_statuses: []const u16 = &.{ 408, 429, 502, 503, 504 },
    /// A circuit breaker per scheme, host and port; null: none.
    breaker: ?resilience.Breaker.Options = null,
};

/// A redirect about to be followed, as `RedirectPolicy.check` sees it.
pub const Redirect = struct {
    /// 301, 302, 303, 307 or 308.
    status: u16,
    /// The URL that answered with the redirect.
    from: Uri,
    /// Where the redirect points, resolved against `from`.
    to: Uri,
    /// The next request's method and whether it carries a body, after the
    /// change 301, 302 and 303 make to non-GET requests.
    method: Method,
    has_body: bool,
    /// Redirects already followed.
    hops: u8,
    /// `to` has another scheme, host or port than `from`.
    cross_origin: bool,
};

/// What to do with a redirect.
pub const RedirectAction = enum {
    /// Follow it.
    follow,
    /// Return the redirect response itself.
    stop,
    /// Fail the fetch with `error.RedirectRefused`.
    fail,
};

/// `ClientOptions.check_redirect`: `check(context, redirect)` decides each
/// redirect. It runs on the fetching task and must not block.
pub const RedirectPolicy = struct {
    context: ?*anyopaque = null,
    check: *const fn (context: ?*anyopaque, redirect: *const Redirect) RedirectAction,
};

/// TLS settings for the HTTP client.
pub const TlsOptions = struct {
    /// Certificate authorities used to verify the server's certificate chain.
    ca: Ca = .system,
    /// Certificate and key to present when the server asks the client to
    /// authenticate itself (mutual TLS). When null, a server that requires a
    /// client certificate rejects the handshake. `.fromFiles` reads PEM
    /// files (a key PKCS#8 or SEC1, without a passphrase) on the first HTTPS
    /// request; `.fromPem` takes them from memory.
    client_certificate: ?Cert = null,
    /// Accept any server certificate and skip host name checking. This makes
    /// the connection trivially interceptable; for testing only.
    insecure_skip_verify: bool = false,
};

/// Options for a single fetch request.
pub const FetchOptions = struct {
    method: Method = .get,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    /// Override default redirect limit for this request.
    max_redirects: ?u8 = null,
    /// Replaces `ClientOptions.timeout` for this request. Null inherits it;
    /// `.none` lifts it. A duration runs from the call to `fetch`, and a
    /// deadline is taken as given.
    timeout: ?std.Io.Timeout = null,
    /// Decompress response body automatically (sends Accept-Encoding header).
    decompress: bool = true,
    /// Leave the response body on the wire for the caller to read through
    /// `ClientResponse.reader`, rather than reading it whole inside `fetch`.
    /// Unbounded by `timeout`, and by `ClientOptions.max_response_size`.
    stream: bool = false,
    /// Connect over a Unix domain socket instead of TCP.
    /// Useful for communicating with Docker Engine (e.g. "/var/run/docker.sock").
    /// The URL host and path are still used for the HTTP request line and Host header.
    unix_socket_path: ?[]const u8 = null,
    /// `.inherit` (the client's), `.off`, or `.on` with a policy of its own.
    retry: resilience.Choice = .inherit,
    /// Whether this request may be sent twice. Null: by method (GET, HEAD,
    /// OPTIONS, TRACE, QUERY) or an Idempotency-Key header.
    idempotent: ?bool = null,
};

/// Options for a WebSocket upgrade request.
pub const WebSocketUpgradeOptions = struct {
    headers: ?*const Headers = null,
    /// Connect over a Unix domain socket instead of TCP.
    unix_socket_path: ?[]const u8 = null,
};

/// A WebSocket connection established via client upgrade.
pub const WebSocketClient = struct {
    ws: WebSocket,
    conn: *Connection,

    // Flushing only through `WebSocket`, which holds its write mutex; a flush
    // of the writer from out here would touch it unguarded.

    pub fn send(self: *WebSocketClient, msg_type: WebSocket.MessageType, data: []const u8) !void {
        return self.ws.send(msg_type, data);
    }

    pub fn receive(self: *WebSocketClient) !WebSocket.Message {
        return self.ws.receive();
    }

    pub fn receiveMany(self: *WebSocketClient) ![]const WebSocket.Message {
        return self.ws.receiveMany();
    }

    pub fn tryReceive(self: *WebSocketClient) !?WebSocket.Message {
        return self.ws.tryReceive();
    }

    pub fn ping(self: *WebSocketClient, data: []const u8) !void {
        return self.ws.ping(data);
    }

    pub fn flush(self: *WebSocketClient) !void {
        return self.ws.flush();
    }

    pub fn close(self: *WebSocketClient, code: WebSocket.CloseCode, reason: []const u8) !void {
        return self.ws.close(code, reason);
    }

    pub fn deinit(self: *WebSocketClient) void {
        self.ws.deinit();
        self.conn.deinit();
        self.conn.pool.allocator.destroy(self.conn);
    }
};

/// Borrowed view of the client-wide TLS material, handed to each HTTPS
/// connection. The pointers reference storage owned by the `Client`, which
/// outlives every connection it hands them to.
const TlsRef = struct {
    ca_bundle: *std.crypto.Certificate.Bundle,
    /// `ca_bundle` loaded once by the TLS module, when it offers that.
    trust: ?*const TrustStore,
    /// Client certificate for mutual TLS, null when none is configured.
    client_cert: ?*tls.config.CertKeyPair,
    insecure_skip_verify: bool,
};

/// Parse a URL string into a std.Uri.
fn parseUrl(url: []const u8) !Uri {
    const uri = Uri.parse(url) catch return error.InvalidUrl;
    try checkRequestTarget(uri);
    return uri;
}

/// The path and query go into the request line (or `:path`) as they are,
/// so they may hold only the visible ASCII a request target allows:
/// `std.Uri.parse` lets through spaces, controls (CR, LF) and bytes past
/// 0x7f. Percent-encode those. Checked when a URL is parsed and again
/// before every request line, for redirect targets too.
fn checkRequestTarget(uri: Uri) error{InvalidUrl}!void {
    if (!isTargetText(uri.path.percent_encoded)) return error.InvalidUrl;
    if (uri.query) |query| if (!isTargetText(query.percent_encoded)) return error.InvalidUrl;
}

fn isTargetText(bytes: []const u8) bool {
    for (bytes) |b| if (b <= 0x20 or b >= 0x7f) return false;
    return true;
}

/// Get port and protocol from URI.
fn uriPortAndProtocol(uri: Uri) error{UnsupportedScheme}!struct { port: u16, protocol: Protocol } {
    const protocol = try Protocol.fromScheme(uri.scheme);
    const port = uri.port orelse protocol.defaultPort();
    return .{ .port = port, .protocol = protocol };
}

/// An IPv6 literal keeps its brackets in the URI, in the pool key and in
/// the Host header, where they belong. The address parser wants them off.
fn unbracketed(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

/// Get host string from URI.
fn uriHost(uri: Uri, buffer: *[255]u8) ![]const u8 {
    const component = uri.host orelse return error.InvalidUrl;
    const hostname = component.toRaw(buffer) catch return error.InvalidUrl;
    // A host with nothing to decode is returned as is, not copied into
    // `buffer`, so its length is not bounded by it.
    if (hostname.len == 0 or hostname.len > buffer.len) return error.InvalidUrl;
    return hostname;
}

/// Get path for HTTP request line.
fn uriPath(uri: Uri) []const u8 {
    const path = uri.path.percent_encoded;
    if (path.len == 0) return "/";
    return path;
}

/// Pool of idle connections for reuse: one per executor (`Client.pools`).
///
/// `acquire`/`release` are safe to call from multiple tasks running in
/// parallel: `idle`/`idle_len` are guarded by `mutex`, and the critical
/// sections only touch the list, so they never suspend. Closing an evicted
/// connection does suspend, so that always happens after the lock has been
/// dropped. `init`/`deinit` are not part of that contract — they must not run
/// concurrently with `acquire`/`release`.
///
/// A connection released with its response body unread is handed to a task
/// in `drains`, which discards the rest of the body and then releases it.
/// While connections that can expire are idle, a task in `reaper` (`reap`)
/// closes them as they do. `deinit` cancels both, so a drain closes its
/// connection instead.
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    /// Oldest first: a released connection goes to the end, `acquire`
    /// takes the newest that matches, and eviction the oldest.
    idle: std.DoublyLinkedList,
    idle_len: usize,
    max_idle: u16,
    max_idle_per_host: u16,
    idle_timeout: ?std.Io.Duration,
    /// Whether `reap` is running or about to (guarded by `mutex`).
    reaping: bool = false,
    drains: std.Io.Group = .init,
    reaper: std.Io.Group = .init,

    /// Bounds on the unread body a background drain discards to keep a
    /// connection, the same as Go's net/http.
    const drain_max_bytes = 256 << 10;
    const drain_timeout: std.Io.Duration = .fromMilliseconds(50);
    /// The shortest `reap` sleeps, so expiries close together are closed
    /// in one round.
    const reap_min_sleep: std.Io.Duration = .fromMilliseconds(10);

    /// `ClientOptions`'s pool settings.
    pub const Limits = struct {
        max_idle: u16 = 1024,
        max_idle_per_host: u16 = 256,
        idle_timeout: ?std.Io.Duration = .fromSeconds(90),

        pub fn fromConfig(config: ClientOptions) Limits {
            return .{
                .max_idle = config.max_idle_connections,
                .max_idle_per_host = config.max_idle_per_host,
                .idle_timeout = config.idle_timeout,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, limits: Limits) ConnectionPool {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .idle = .{},
            .idle_len = 0,
            .max_idle = limits.max_idle,
            .max_idle_per_host = limits.max_idle_per_host,
            .idle_timeout = limits.idle_timeout,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        // A drain that completes during the cancel releases its connection
        // into `idle`; a canceled one closes its own.
        self.drains.cancel(self.io);
        self.reaper.cancel(self.io);

        // Close and free all idle connections
        while (self.idle.popFirst()) |node| destroy(self, fromNode(node));
    }

    /// Whether released connections are kept at all.
    pub fn pooling(self: *const ConnectionPool) bool {
        return self.max_idle != 0 and self.max_idle_per_host != 0;
    }

    fn fromNode(node: *std.DoublyLinkedList.Node) *Connection {
        return @alignCast(@fieldParentPtr("pool_node", node));
    }

    fn destroy(self: *ConnectionPool, conn: *Connection) void {
        conn.deinit();
        self.allocator.destroy(conn);
    }

    /// When idle `conn` is due to be closed: at the server's `Keep-Alive`
    /// timeout or `idle_timeout` after it was pooled, whichever is first;
    /// null for never.
    fn expiry(self: *const ConnectionPool, conn: *const Connection) ?std.Io.Timestamp {
        var at = conn.idle_deadline;
        if (self.idle_timeout) |timeout| {
            const ours = conn.pooled_at.addDuration(timeout);
            if (at == null or ours.nanoseconds < at.?.nanoseconds) at = ours;
        }
        return at;
    }

    fn expired(self: *const ConnectionPool, conn: *const Connection, now: std.Io.Timestamp) bool {
        const at = self.expiry(conn) orelse return false;
        return now.nanoseconds >= at.nanoseconds;
    }

    /// Try to acquire an existing connection for the given host:port, protocol, and optional unix socket path.
    pub fn acquire(self: *ConnectionPool, remote_host: []const u8, remote_port: u16, protocol: Protocol, unix_socket_path: ?[]const u8) ?*Connection {
        const io = self.io;
        const now = std.Io.Timestamp.now(io, .awake);

        // Connections found expired along the way. They are already out of the
        // pool and owned by us, so they get closed after the lock is dropped.
        var expired_list: std.DoublyLinkedList = .{};

        const found = found: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // Search from end (most recently used)
            var node = self.idle.last;
            while (node) |n| {
                const conn = fromNode(n);
                node = n.prev;

                if (conn.matches(remote_host, remote_port, protocol, unix_socket_path)) {
                    self.idle.remove(n);
                    self.idle_len -= 1;

                    if (self.expired(conn, now)) {
                        expired_list.append(n);
                        continue;
                    }

                    break :found conn;
                }
            }
            break :found null;
        };

        while (expired_list.popFirst()) |n| self.destroy(fromNode(n));

        return found;
    }

    /// Release a connection back to the pool, or close it if the pool is
    /// off or the connection is closing. A full pool (in all, or for the
    /// connection's host) closes its oldest idle connection to make room.
    pub fn release(self: *ConnectionPool, conn: *Connection) void {
        // Don't pool connections that are closing
        if (conn.closing or !self.pooling()) {
            self.destroy(conn);
            return;
        }

        // Reset before taking the lock; it only touches this connection.
        conn.reset() catch {
            self.destroy(conn);
            return;
        };
        conn.pooled_at = std.Io.Timestamp.now(self.io, .awake);

        var start_reaper = false;
        const evicted: ?*Connection = evicted: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // The oldest idle connection to the same place, and whether
            // the host already has its fill.
            var same: usize = 0;
            var oldest_same: ?*std.DoublyLinkedList.Node = null;
            var node = self.idle.first;
            while (node) |n| : (node = n.next) {
                const other = fromNode(n);
                if (!other.matches(conn.host(), conn.port, conn.protocol, conn.unixPath())) continue;
                if (oldest_same == null) oldest_same = n;
                same += 1;
                if (same >= self.max_idle_per_host) break;
            }

            var old: ?*std.DoublyLinkedList.Node = null;
            if (same >= self.max_idle_per_host) {
                old = oldest_same;
            } else if (self.idle_len >= self.max_idle) {
                old = self.idle.first;
            }
            if (old) |n| {
                self.idle.remove(n);
                self.idle_len -= 1;
            }

            self.idle.append(&conn.pool_node);
            self.idle_len += 1;

            if (!self.reaping and self.expiry(conn) != null) {
                self.reaping = true;
                start_reaper = true;
            }
            break :evicted if (old) |n| fromNode(n) else null;
        };

        // Closing suspends, so it must happen outside the critical section.
        if (evicted) |old| self.destroy(old);
        if (start_reaper) self.startReaper();
    }

    /// Closes every idle connection (the busy ones are not touched).
    pub fn closeIdle(self: *ConnectionPool) void {
        var taken: std.DoublyLinkedList = .{};
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.idle.popFirst()) |n| taken.append(n);
            self.idle_len = 0;
        }
        // Closing suspends, so it happens outside the critical section.
        while (taken.popFirst()) |n| self.destroy(fromNode(n));
    }

    /// Hands `conn` to a background drain, or returns false if no task
    /// could be had for it, in which case the caller still owns it.
    fn startDrain(self: *ConnectionPool, conn: *Connection) bool {
        placement.concurrent(&self.drains, self.io, .local, drain, .{ self, conn }) catch return false;
        return true;
    }

    fn drain(self: *ConnectionPool, conn: *Connection) std.Io.Cancelable!void {
        defer self.release(conn);
        const deadline: Deadline = .init(self.io, .{ .duration = .{ .raw = drain_timeout, .clock = .awake } });
        const complete = deadline.run(discardBody, .{conn}) catch |err| switch (err) {
            error.Canceled => {
                conn.closing = true;
                return error.Canceled;
            },
            else => false,
        };
        if (!complete) conn.closing = true;
    }

    /// No decoding: the body is being thrown away to keep the connection.
    fn discardBody(conn: *Connection) ResponseBodyReader.Error!bool {
        var buf: [1024]u8 = undefined;
        var body_reader = ResponseBodyReader.init(&conn.parser, conn.transport(), &buf);
        _ = body_reader.interface.discardShort(drain_max_bytes + 1) catch |err| switch (err) {
            error.ReadFailed => return body_reader.err orelse error.Unexpected,
        };
        return conn.parser.isBodyComplete();
    }

    /// Starts `reap`, on this executor. Without a task for it, idle
    /// connections still expire when `acquire` comes across them.
    fn startReaper(self: *ConnectionPool) void {
        placement.concurrent(&self.reaper, self.io, .local, reap, .{self}) catch {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.reaping = false;
        };
    }

    /// Closes idle connections as they expire, sleeping until the next one
    /// does, and ends when none left can (`release` starts it again).
    fn reap(self: *ConnectionPool) std.Io.Cancelable!void {
        while (true) {
            const now = std.Io.Timestamp.now(self.io, .awake);
            var expired_list: std.DoublyLinkedList = .{};
            const next: ?std.Io.Timestamp = next: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                var soonest: ?std.Io.Timestamp = null;
                var node = self.idle.first;
                while (node) |n| {
                    node = n.next;
                    const at = self.expiry(fromNode(n)) orelse continue;
                    if (now.nanoseconds >= at.nanoseconds) {
                        self.idle.remove(n);
                        self.idle_len -= 1;
                        expired_list.append(n);
                    } else if (soonest == null or at.nanoseconds < soonest.?.nanoseconds) {
                        soonest = at;
                    }
                }
                if (soonest == null) self.reaping = false;
                break :next soonest;
            };
            while (expired_list.popFirst()) |n| self.destroy(fromNode(n));
            const at = next orelse return;
            const wait = now.durationTo(at);
            try self.io.sleep(if (wait.nanoseconds < reap_min_sleep.nanoseconds) reap_min_sleep else wait, .awake);
        }
    }
};

/// A client connection that owns all resources for a request/response cycle.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    arena: std.heap.ArenaAllocator,
    parser: ResponseParser,
    parsed_response: ParsedResponse,
    buffer_size: usize,
    max_response_headers: usize,
    pool: *ConnectionPool,

    // Protocol and TLS
    protocol: Protocol,
    // Negotiated wire version. For HTTPS this is set from TLS ALPN after the
    // handshake; otherwise it stays .http_1_1.
    http_version: HttpVersion = .http_1_1,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,

    // TLS TCP layer buffers (allocated from main allocator, persist across requests).
    // These hold the encrypted (ciphertext) data exchanged over the raw socket.
    tls_tcp_read_buffer: []u8,
    tls_tcp_write_buffer: []u8,
    tls_conn: ?tls.Connection,
    // Cleartext Reader/Writer adapters layered on top of tls_conn. They store a
    // pointer back to tls_conn, so the Connection must never be moved after init.
    tls_reader: tls.Connection.Reader,
    tls_writer: tls.Connection.Writer,
    tls_rng: std.Random.IoSource,

    // HTTP layer buffers (allocated from main allocator, persist across requests)
    read_buffer: []u8,
    write_buffer: []u8,

    // Pointers to the actual reader/writer interfaces used for HTTP I/O.
    //
    // Public, and bare interfaces, so they can only report
    // `ReadFailed`/`WriteFailed`. That is allowed here because there is no
    // layer above them to lose the answer: `getReadError`/`getWriteError`
    // beside them resolve what actually failed.
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    // Connection pool metadata
    pool_node: std.DoublyLinkedList.Node = .{},
    host_buffer: [255]u8 = undefined,
    host_len: u8 = 0,
    port: u16 = 0,
    closing: bool = false,
    // Unix socket path (empty means TCP connection)
    unix_path_buffer: [unix_path_max]u8 = undefined,
    unix_path_len: u8 = 0,

    // Keep-Alive tracking
    request_count: u16 = 0,
    keep_alive: KeepAliveParams = .{},
    /// When the server's `Keep-Alive: timeout` says the idle connection
    /// goes, if it said.
    idle_deadline: ?std.Io.Timestamp = null,
    /// When it last went back to the pool (`ConnectionPool.idle_timeout`).
    pooled_at: std.Io.Timestamp = .{ .nanoseconds = 0 },

    // When the handshake picked "h2": the session, which reads and writes the
    // connection from then on, and the stream of the request in flight.
    h2: if (has_h2_client) ?*h2_client.ClientConnection else void,
    h2_stream: if (has_h2_client) ?*h2_client.Stream else void,

    /// Initialize the connection in place (required because parser stores internal pointers).
    pub fn init(
        self: *Connection,
        allocator: std.mem.Allocator,
        io: std.Io,
        pool: *ConnectionPool,
        stream: std.Io.net.Stream,
        remote_host: []const u8,
        remote_port: u16,
        buffer_size: usize,
        max_response_headers: usize,
        protocol: Protocol,
        tls_config: ?TlsRef,
        unix_socket_path: ?[]const u8,
        advertise_http2: bool,
    ) !void {
        self.allocator = allocator;
        self.io = io;
        self.stream = stream;
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.pool = pool;
        self.closing = false;
        self.buffer_size = buffer_size;
        self.max_response_headers = max_response_headers;

        // Keep-Alive tracking
        self.request_count = 0;
        self.keep_alive = .{};
        self.idle_deadline = null;
        self.pooled_at = .{ .nanoseconds = 0 };

        // Store host for connection pooling
        const len: u8 = @intCast(@min(remote_host.len, self.host_buffer.len));
        @memcpy(self.host_buffer[0..len], remote_host[0..len]);
        self.host_len = len;
        self.port = remote_port;

        // Store unix socket path for connection pooling
        if (unix_socket_path) |path| {
            if (path.len > unix_path_max) return error.NameTooLong;
            const plen: u8 = @intCast(path.len);
            @memcpy(self.unix_path_buffer[0..plen], path[0..plen]);
            self.unix_path_len = plen;
        } else {
            self.unix_path_len = 0;
        }

        self.parsed_response = .{ .arena = self.arena.allocator() };
        try self.parser.init(&self.parsed_response, self.max_response_headers);

        // Protocol and TLS initialization
        self.protocol = protocol;
        self.http_version = .http_1_1;
        if (comptime has_h2_client) {
            self.h2 = null;
            self.h2_stream = null;
        }

        if (protocol == .https) {
            if (!build_options.use_tls) return error.TlsNotConfigured;
            const tls_cfg = tls_config orelse return error.MissingTlsConfig;

            // TCP-layer (ciphertext) buffers. tls.zig requires the input buffer to
            // fit a full TLS record; the output buffer caps the produced record size.
            self.tls_tcp_read_buffer = try allocator.alloc(u8, tls.input_buffer_len);
            errdefer allocator.free(self.tls_tcp_read_buffer);
            self.tls_tcp_write_buffer = try allocator.alloc(u8, tls.output_buffer_len);
            errdefer allocator.free(self.tls_tcp_write_buffer);

            // HTTP-layer (cleartext) buffers, used by the tls.Connection reader/writer.
            self.read_buffer = try allocator.alloc(u8, self.buffer_size + body_read_reserve);
            errdefer allocator.free(self.read_buffer);
            self.write_buffer = try allocator.alloc(u8, 1024);
            errdefer allocator.free(self.write_buffer);

            self.tcp_reader = stream.reader(io, self.tls_tcp_read_buffer);
            self.tcp_writer = stream.writer(io, self.tls_tcp_write_buffer);

            self.tls_rng = .{ .io = self.io };

            // Offer h2 (preferred) and http/1.1 via ALPN when HTTP/2 is enabled;
            // otherwise advertise nothing, preserving HTTP/1.1-only behavior.
            const alpn_protocols: []const []const u8 = if (advertise_http2)
                &.{ "h2", "http/1.1" }
            else
                &.{};

            var options: tls.config.Client = .{
                .host = remote_host,
                .root_ca = tls_cfg.ca_bundle.*,
                .insecure_skip_verify = tls_cfg.insecure_skip_verify,
                .auth = tls_cfg.client_cert,
                .now = std.Io.Clock.real.now(self.io),
                .rng = self.tls_rng.interface(),
                .alpn_protocols = alpn_protocols,
            };
            if (comptime has_trust_store) options.trust = tls_cfg.trust;
            self.tls_conn = tls.client(
                &self.tcp_reader.interface,
                &self.tcp_writer.interface,
                options,
            ) catch |err| {
                // tls.zig only ever saw the ciphertext reader or writer fail
                // generically, so for those the cause is a layer down.
                // Nothing is negotiated yet, so that layer is all there is.
                const ciphertext: Transport = .{
                    .reader = &self.tcp_reader.interface,
                    .writer = &self.tcp_writer.interface,
                    .tcp_reader = &self.tcp_reader,
                    .tcp_writer = &self.tcp_writer,
                };
                return switch (err) {
                    error.ReadFailed => ciphertext.getReadError() orelse error.Unexpected,
                    error.WriteFailed => ciphertext.getWriteError() orelse error.Unexpected,
                    else => |e| e,
                };
            };

            // Record the negotiated wire version from the ALPN selection.
            self.http_version = HttpVersion.fromAlpn(self.tls_conn.?.alpn_protocol);

            self.tls_reader = self.tls_conn.?.reader(self.read_buffer);
            self.tls_writer = self.tls_conn.?.writer(self.write_buffer);
            self.reader = &self.tls_reader.interface;
            self.writer = &self.tls_writer.interface;

            if (comptime has_h2_client) if (self.http_version == .http_2) {
                self.h2 = h2_client.ClientConnection.adopt(allocator, io, self.reader, self.writer, stream) catch |err| {
                    if (@hasDecl(tls.Connection, "deinit")) self.tls_conn.?.deinit();
                    return err;
                };
            };
        } else {
            self.tls_conn = null;
            self.tls_tcp_read_buffer = &.{};
            self.tls_tcp_write_buffer = &.{};

            self.read_buffer = try allocator.alloc(u8, self.buffer_size + body_read_reserve);
            errdefer allocator.free(self.read_buffer);
            self.write_buffer = try allocator.alloc(u8, 1024);
            errdefer allocator.free(self.write_buffer);

            self.tcp_reader = stream.reader(io, self.read_buffer);
            self.tcp_writer = stream.writer(io, self.write_buffer);

            self.reader = &self.tcp_reader.interface;
            self.writer = &self.tcp_writer.interface;
        }
    }

    /// A borrowed view of the reader/writer stack, and the one thing that
    /// knows how to say what a failed read or write actually was. Shared with
    /// the server rather than reimplemented, which is how the TLS layer's
    /// errors stopped being invisible here.
    pub fn transport(self: *Connection) Transport {
        const has_tls = build_options.use_tls and self.tls_conn != null;
        return .{
            .reader = self.reader,
            .writer = self.writer,
            .tcp_reader = &self.tcp_reader,
            .tcp_writer = &self.tcp_writer,
            .tls_reader = if (has_tls) &self.tls_reader else null,
            .tls_writer = if (has_tls) &self.tls_writer else null,
        };
    }

    pub const ReadError = Transport.ReadError;
    pub const WriteError = Transport.WriteError;

    /// The real error behind a generic `error.ReadFailed`, if any was recorded.
    pub fn getReadError(self: *Connection) ?ReadError {
        return self.transport().getReadError();
    }

    /// The real error behind a generic `error.WriteFailed`, if any was
    /// recorded.
    pub fn getWriteError(self: *Connection) ?WriteError {
        return self.transport().getWriteError();
    }

    pub fn deinit(self: *Connection) void {
        // The session's tasks use the TLS connection and the socket, so it
        // goes first.
        if (comptime has_h2_client) if (self.h2) |session| {
            if (self.h2_stream) |s| s.release();
            self.h2_stream = null;
            session.close();
            self.h2 = null;
        };
        if (build_options.use_tls) {
            // See server.zig `Connection.deinit`: only a TLS module that owns
            // per-connection state declares `deinit`.
            if (@hasDecl(tls.Connection, "deinit")) {
                if (self.tls_conn) |*c| c.deinit();
            }
            self.tls_conn = null;
        }
        self.stream.close(self.io);
        if (self.protocol == .https) {
            self.allocator.free(self.tls_tcp_read_buffer);
            self.allocator.free(self.tls_tcp_write_buffer);
        }
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        self.arena.deinit();
    }

    /// What a pooled connection's arena keeps of what a response took
    /// (the head's copies, a body read whole): enough for the usual JSON
    /// answer to come and go without the allocator, while one big body
    /// does not stay with the connection for as long as it is pooled.
    const arena_retain_limit = 32 * 1024;

    pub fn reset(self: *Connection) !void {
        // Reset for reuse (connection pooling)
        _ = self.arena.reset(.{ .retain_with_limit = arena_retain_limit });
        self.parsed_response = .{ .arena = self.arena.allocator() };
        self.parser.reset();
        try self.parser.init(&self.parsed_response, self.max_response_headers);
        self.closing = false;

        // HTTP/2: the stream goes (reset if its body is unread), and the
        // connection stays while the server takes requests on it. The
        // session owns the reader.
        if (comptime has_h2_client) if (self.h2) |session| {
            if (self.h2_stream) |st| st.release();
            self.h2_stream = null;
            if (!session.isOpen()) return error.ConnectionClosed;
            return;
        };

        // As part of reading body, we shrank the buffer
        const buffered = self.reader.buffered();
        @memmove(self.read_buffer[0..buffered.len], buffered);
        self.reader.buffer = self.read_buffer;
        self.reader.seek = 0;
        self.reader.end = buffered.len;
    }

    pub fn flush(self: *Connection) WriteError!void {
        // For HTTPS this drains the cleartext writer, which encrypts and flushes
        // the underlying TCP writer in one step; for HTTP it flushes the socket directly.
        self.writer.flush() catch |err| switch (err) {
            error.WriteFailed => return self.getWriteError() orelse error.Unexpected,
        };
    }

    fn parseHead(self: *Connection) !void {
        parseResponseHeaders(self.reader, &self.parser) catch |err| switch (err) {
            error.ReadFailed => return self.getReadError() orelse error.Unexpected,
            else => |e| return e,
        };
    }

    pub fn host(self: *const Connection) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    pub fn unixPath(self: *const Connection) ?[]const u8 {
        if (self.unix_path_len == 0) return null;
        return self.unix_path_buffer[0..self.unix_path_len];
    }

    /// Check if this connection matches the given host, port, protocol, and transport.
    pub fn matches(self: *const Connection, match_host: []const u8, match_port: u16, protocol: Protocol, unix_socket_path: ?[]const u8) bool {
        if (unix_socket_path) |path| {
            return self.protocol == protocol and std.mem.eql(u8, self.unixPath() orelse return false, path);
        }
        if (self.unix_path_len != 0) return false;
        return self.protocol == protocol and self.port == match_port and std.ascii.eqlIgnoreCase(self.host(), match_host);
    }

    /// Whether the response body may still be on the wire. Over HTTP/2 it
    /// never is in the way: releasing the stream resets it.
    fn bodyPending(self: *Connection) bool {
        if (comptime has_h2_client) if (self.h2 != null) return false;
        return !self.parser.isBodyComplete();
    }

    /// Release this connection back to its pool, handling keep-alive logic.
    /// A response body that wasn't fully read is drained in the background
    /// when it is small enough, and the connection closed otherwise.
    pub fn release(self: *Connection) void {
        // Increment request count
        self.request_count +|= 1;

        // HTTP/2: no keep-alive headers and no body to drain; `reset`
        // releases the stream.
        if (comptime has_h2_client) if (self.h2 != null) {
            self.pool.release(self);
            return;
        };

        // Check basic keep-alive from Connection header
        if (!self.parser.shouldKeepAlive()) {
            self.closing = true;
        } else {
            // Parse Keep-Alive header on first response
            if (self.request_count == 1) {
                if (self.parsed_response.headers.get("Keep-Alive")) |keep_alive| {
                    self.keep_alive = parseKeepAliveHeader(keep_alive);
                }
            }

            // Update idle deadline after each request
            if (self.keep_alive.timeout) |timeout| {
                self.idle_deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromSeconds(@as(i64, timeout)));
            }

            // Check if we've reached max requests
            if (self.keep_alive.max) |max| {
                if (self.request_count >= max) {
                    self.closing = true;
                }
            }
        }

        // The parser is always at the body's position on the wire, whatever
        // was read through a decoder: what the decoder holds was already
        // counted. A failed read leaves no such guarantee.
        if (!self.parser.isBodyComplete()) {
            const drainable = !self.closing and self.pool.pooling() and
                !self.parser.hasFailed() and self.getReadError() == null and
                (self.parsed_response.content_length orelse 0) <= ConnectionPool.drain_max_bytes;
            if (drainable and self.pool.startDrain(self)) return;
            self.closing = true;
        }

        self.pool.release(self);
    }
};

/// HTTP client response.
/// Call deinit() when done to release the connection.
pub const ClientResponse = struct {
    // Direct pointers for reading (testable without full connection)
    arena: std.mem.Allocator,
    parser: *ResponseParser,
    transport: Transport,
    parsed: *ParsedResponse,
    max_response_size: usize,
    decompress: bool = true,

    // Cached body (read lazily)
    _body: ?[]const u8 = null,
    _body_read: bool = false,

    // Set up on the first body read that calls for decoding, and kept so a
    // second `reader()` does not build a second decoder over the same body.
    _decode: ?*ResponseBodyReader.Decode = null,
    _body_reader_taken: bool = false,

    // Connection reference for cleanup (optional for testing)
    owner: ?*Connection = null,

    /// The body as an HTTP/2 stream delivers it, unframed, in place of
    /// `parser` and `transport`.
    raw: ?BodySource = null,

    /// Release the connection back to the pool (or close if not reusable).
    pub fn deinit(self: *ClientResponse) void {
        if (self.owner) |conn| {
            conn.release();
        }
    }

    /// Get response status.
    pub fn status(self: *const ClientResponse) Status {
        return self.parsed.status;
    }

    /// Get response headers.
    pub fn headers(self: *const ClientResponse) *const Headers {
        return &self.parsed.headers;
    }

    /// Get HTTP version.
    pub fn version(self: *const ClientResponse) struct { major: u8, minor: u8 } {
        return .{
            .major = self.parsed.version_major,
            .minor = self.parsed.version_minor,
        };
    }

    /// Get content type if present.
    pub fn contentType(self: *const ClientResponse) ?ContentType {
        return self.parsed.content_type;
    }

    /// The coding the body arrived in. Undone by the body reader unless
    /// `decompress` is off, in which case reading the body yields what the
    /// wire carried.
    ///
    /// Once it is being undone the `Content-Encoding` header is removed,
    /// because it would describe the body a caller is about to read as
    /// something it is not. This still says what arrived.
    pub fn contentEncoding(self: *const ClientResponse) ContentEncoding {
        return self.parsed.content_encoding;
    }

    /// How long the body was on the wire, when the headers said. Removed
    /// from the headers alongside the coding for the same reason, and kept
    /// here for the same one.
    pub fn contentLength(self: *const ClientResponse) ?usize {
        return self.parsed.content_length;
    }

    /// Both of these describe the body as it arrived, and it is not going
    /// to arrive that way any more: what the caller reads is decoded, and a
    /// longer or shorter number of bytes. Leaving them is how a proxy comes
    /// to forward plain bytes labelled `gzip`. `contentEncoding` and
    /// `contentLength` keep the answer for a caller that wants it.
    fn dropEncodedBodyHeaders(self: *ClientResponse) void {
        _ = self.parsed.headers.remove("Content-Encoding");
        _ = self.parsed.headers.remove("Content-Length");
    }

    /// What a failed body read can turn out to be, sentinels resolved. The
    /// reader `reader` hands out carries one of these in `.err`.
    pub const ReadError = ResponseBodyReader.Error;

    /// Read the entire response body into memory.
    /// Result is cached for subsequent calls.
    pub fn body(self: *ClientResponse) !?[]const u8 {
        if (self._body_read) {
            return self._body;
        }

        // Nothing to stage: `allocRemaining` streams straight into the arena.
        var no_buf: [0]u8 = .{};
        var r = try self.reader(&no_buf);
        const result = r.interface.allocRemaining(self.arena, .limited(self.max_response_size)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.ReadFailed => return r.err orelse error.Unexpected,
            else => |e| return e,
        };

        self._body_read = true;
        if (result.len == 0) {
            self._body = null;
            return null;
        }
        self._body = result;
        return result;
    }

    /// The response body: transfer framing undone, and the content coding
    /// too unless `decompress` is off. Read through `.interface`, and
    /// `.err` says what an `error.ReadFailed` from it actually was.
    ///
    /// `buffer` is where bytes wait between the connection and the caller,
    /// the way `Response.stream` takes one for the other direction. It is
    /// what `peek` and the `take` family read out of, so size it for the
    /// longest thing they need to see at once; an empty slice is fine for a
    /// caller that only ever streams.
    ///
    /// One per response. `body` takes it if you have not, so a caller that
    /// streams cannot then ask for the body whole.
    pub fn reader(self: *ClientResponse, buffer: []u8) !ResponseBodyReader {
        var r = ResponseBodyReader.init(self.parser, self.transport, buffer);
        r.raw = self.raw;

        // Once the body is in memory there is nothing left on the wire, and
        // what is cached has already been decoded.
        if (self._body_read) {
            r.interface = .fixed(self._body orelse &.{});
            return r;
        }

        // The buffer belongs to the caller, so a second reader starts empty
        // and whatever the first one had buffered is unreachable -- bytes off
        // the body, with nothing to say they went missing.
        std.debug.assert(!self._body_reader_taken); // one body reader per response

        // A message complete at the head has no body, whatever the coding
        // headers say -- a HEAD response, a 204, a Content-Length of zero.
        // A decoder started on nothing would report a body cut short.
        if (self._decode) |decode| {
            r.decode = decode;
        } else if (self.decompress and !self.parser.isBodyComplete()) {
            try r.startDecoding(self.arena, self.parsed.content_encoding);
            if (r.decode != null) self.dropEncodedBodyHeaders();
            self._decode = r.decode;
        }

        // Claimed only once there is a reader to claim it for. A coding we
        // cannot undo fails above, and nothing was read; a caller that
        // handles that error has to be able to ask again.
        self._body_reader_taken = true;
        return r;
    }
};

/// HTTP client for making requests.
///
/// A single client can be shared by tasks running in parallel: the connection
/// pool and the CA bundle are both internally synchronized. Sharing one client
/// is also what makes connection reuse and a single CA bundle scan possible.
/// `init`/`deinit` are not part of that contract — they must not run
/// concurrently with requests.
///
/// Connections are freed and reset from background tasks as well as from
/// requests, so `allocator` must be thread-safe whenever `io` runs tasks in
/// parallel.
///
/// On zio each executor has a pool of its own (`pools`), as `anole.db`'s
/// connectors do: a request takes and gives back connections on its own
/// executor, so a connection stays on one thread, and no lock is contended
/// across them. Elsewhere there is one pool.
/// `Client.upload`'s settings.
pub const UploadOptions = struct {
    method: Method = .post,
    headers: ?*const Headers = null,
    /// Trailer names announced in a `Trailer` header up front.
    trailer_names: []const []const u8 = &.{},
    /// Bounds opening the connection and sending the head, and (in
    /// `finish`) waiting for the response head. Writing the body is the
    /// caller's pace. Null inherits ClientOptions.timeout; .none lifts it.
    timeout: ?std.Io.Timeout = null,
    unix_socket_path: ?[]const u8 = null,
};

/// A request whose body is written as it goes (Transfer-Encoding:
/// chunked), over HTTP/1.1 only, with no redirects. `Client.upload` makes
/// one; end it with `finish` or `abort`.
pub const Upload = struct {
    /// Each flush (and each drain of its buffer) sends one chunk.
    writer: *std.Io.Writer,
    impl: *UploadImpl,

    /// Ends the body (the last chunk, then `trailers`) and reads the
    /// response head. The `Upload` is spent afterwards.
    pub fn finish(self: *Upload, trailers: ?*const Headers) !ClientResponse {
        return self.impl.finish(trailers);
    }

    /// Gives up: the connection is closed, not pooled. The `Upload` is
    /// spent afterwards.
    pub fn abort(self: *Upload) void {
        self.impl.abort();
    }
};

const UploadImpl = struct {
    client: *Client,
    conn: *Connection,
    timeout: std.Io.Timeout,
    write_err: ?Connection.WriteError = null,
    w: std.Io.Writer,
    buffer: [4096]u8 = undefined,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *UploadImpl = @alignCast(@fieldParentPtr("w", w));
        const buffered = w.buffered();
        var from_data: usize = 0;
        for (data[0 .. data.len - 1]) |d| from_data += d.len;
        from_data += data[data.len - 1].len * splat;
        const total = buffered.len + from_data;
        if (total == 0) return 0;
        const out = self.conn.writer;
        errdefer self.conn.closing = true;
        try out.print("{x}\r\n", .{total});
        try out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |d| try out.writeAll(d);
        try out.splatBytesAll(data[data.len - 1], splat);
        try out.writeAll("\r\n");
        w.end = 0;
        return from_data;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *UploadImpl = @alignCast(@fieldParentPtr("w", w));
        try std.Io.Writer.defaultFlush(w);
        self.conn.flush() catch |err| {
            self.conn.closing = true;
            self.write_err = err;
            return error.WriteFailed;
        };
    }

    fn finish(self: *UploadImpl, trailers: ?*const Headers) !ClientResponse {
        const client = self.client;
        const conn = self.conn;
        defer client.allocator.destroy(self);
        errdefer conn.pool.release(conn);
        self.w.flush() catch return self.writeError();
        conn.writer.writeAll("0\r\n") catch |err| return self.fail(err);
        if (trailers) |t| {
            var it = t.iterator();
            while (it.next()) |entry| {
                try http.validateHeaderName(entry.key);
                try http.validateHeaderValue(entry.value);
                conn.writer.print("{s}: {s}\r\n", .{ entry.key, entry.value }) catch |err| return self.fail(err);
            }
        }
        conn.writer.writeAll("\r\n") catch |err| return self.fail(err);
        conn.flush() catch |err| {
            conn.closing = true;
            return err;
        };
        const deadline: Deadline = .init(client.io, self.timeout);
        deadline.run(Connection.parseHead, .{conn}) catch |err| {
            conn.closing = true;
            return err;
        };
        return .{
            .arena = conn.arena.allocator(),
            .parser = &conn.parser,
            .transport = conn.transport(),
            .parsed = &conn.parsed_response,
            .max_response_size = client.config.max_response_size,
            .decompress = false,
            .owner = conn,
            .raw = null,
        };
    }

    fn writeError(self: *UploadImpl) anyerror {
        self.conn.closing = true;
        if (self.write_err) |e| return e;
        if (self.conn.getWriteError()) |e| return e;
        return error.WriteFailed;
    }

    fn fail(self: *UploadImpl, err: std.Io.Writer.Error) anyerror {
        self.conn.closing = true;
        return switch (err) {
            error.WriteFailed => self.conn.getWriteError() orelse error.WriteFailed,
        };
    }

    fn abort(self: *UploadImpl) void {
        self.conn.closing = true;
        self.conn.pool.release(self.conn);
        self.client.allocator.destroy(self);
    }
};

/// The `Content-Length` and `Transfer-Encoding` of an upload are its own.
fn writeUploadField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(name, "Content-Length") or std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or std.ascii.eqlIgnoreCase(name, "Trailer")) return;
    return writeField(writer, name, value);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ClientOptions,
    /// One per executor of `io`'s runtime, up to `max_pools` (executors
    /// past it share, by index modulo); the first `pool_count` are used.
    pools: [max_pools]ConnectionPool,
    pool_count: usize,
    /// Connections opened so far (each a dial, and a handshake for
    /// HTTPS): with requests steady, it should stop growing once the
    /// pools hold what is busy at once.
    dials: std.atomic.Value(u64),
    tls_state: TlsState,
    tls_lock: std.Io.RwLock,
    tls_loaded: std.atomic.Value(bool),
    /// `ClientOptions.breaker`: one per scheme, host and port.
    _breakers: ?resilience.Breakers = null,
    /// `ClientOptions.retry`'s throttle (gRPC A6), shared by the client.
    _throttle: resilience.Throttle,
    resilience_metrics: ?*const resilience.Metrics = null,

    /// TLS material shared by every HTTPS connection. Reading the trust store
    /// and deriving the client key are expensive, so both are loaded once on
    /// the first HTTPS request and reused afterwards.
    const TlsState = struct {
        ca_bundle: std.crypto.Certificate.Bundle = .empty,
        trust: ?TrustStore = null,
        client_cert: ?tls.config.CertKeyPair = null,
    };

    /// The most pools a client has.
    pub const max_pools = 64;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ClientOptions) Client {
        const limits: ConnectionPool.Limits = .fromConfig(config);
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .pools = @splat(ConnectionPool.init(allocator, io, limits)),
            .pool_count = @min(@max(placement.executorCount(io) orelse 1, 1), max_pools),
            .dials = .init(0),
            .tls_state = .{},
            .tls_lock = .init,
            .tls_loaded = std.atomic.Value(bool).init(false),
            ._breakers = if (config.breaker) |o| resilience.Breakers.init(allocator, o, .http, 1024) else null,
            ._throttle = .init(if (config.retry) |r| (r.throttle orelse .{}) else .{}),
        };
    }

    /// Reports breakers and retries through `m` (`anole.resilience.Binding`).
    pub fn observeResilience(self: *Client, m: ?*const resilience.Metrics) void {
        self.resilience_metrics = m;
        if (self._breakers) |*b| b.observe(self.io, m);
    }

    fn ensureTlsState(self: *Client) !TlsRef {
        if (!self.tls_loaded.load(.acquire)) {
            try self.tls_lock.lock(self.io);
            defer self.tls_lock.unlock(self.io);
            if (!self.tls_loaded.load(.unordered)) {
                try self.loadTlsState();
                self.tls_loaded.store(true, .release);
            }
        }
        return .{
            .ca_bundle = &self.tls_state.ca_bundle,
            .trust = if (self.tls_state.trust) |*t| t else null,
            .client_cert = if (self.tls_state.client_cert) |*pair| pair else null,
            .insecure_skip_verify = self.config.tls.insecure_skip_verify,
        };
    }

    /// Builds the CA bundle and client certificate into locals and only commits
    /// them once both succeed, so a failure leaves `tls_state` empty and a later
    /// retry starts from a clean bundle instead of appending to a half-built one.
    fn loadTlsState(self: *Client) !void {
        const cfg = self.config.tls;
        if (cfg.ca == .none and !cfg.insecure_skip_verify) return error.NoCertificateAuthority;

        var ca_bundle = try cfg.ca.load(self.allocator, self.io);
        errdefer ca_bundle.deinit(self.allocator);
        var trust: ?TrustStore = null;
        if (comptime has_trust_store) if (cfg.ca != .none) {
            trust = try TrustStore.init(ca_bundle);
        };
        errdefer if (comptime has_trust_store) if (trust) |*t| t.deinit();

        var client_cert: ?tls.config.CertKeyPair = null;
        errdefer if (client_cert) |*pair| pair.deinit(self.allocator);
        if (cfg.client_certificate) |cc| {
            client_cert = switch (cc) {
                .pem => |pem| try tls.config.CertKeyPair.fromSlice(self.allocator, self.io, pem.cert, pem.key),
                .files => |f| try tls.config.CertKeyPair.fromFilePath(self.allocator, self.io, std.Io.Dir.cwd(), f.cert_path, f.key_path),
                // Anole's own clients make one with `tls.selfSigned`.
                .dev_self_signed => return error.DevCertificateUnavailable,
            };
        }

        self.tls_state = .{ .ca_bundle = ca_bundle, .trust = trust, .client_cert = client_cert };
    }

    pub fn deinit(self: *Client) void {
        for (self.pools[0..self.pool_count]) |*p| p.deinit();
        self.tls_state.ca_bundle.deinit(self.allocator);
        if (comptime has_trust_store) if (self.tls_state.trust) |*t| t.deinit();
        if (self.tls_state.client_cert) |*pair| pair.deinit(self.allocator);
        if (self._breakers) |*b| b.deinit();
    }

    /// Perform an HTTP request. With `ClientOptions.retry` (or the
    /// fetch's) and an idempotent request, a failure that may pass is
    /// retried; with `ClientOptions.breaker`, a host that keeps failing
    /// is `error.CircuitOpen` without a dial.
    pub fn fetch(
        self: *Client,
        url: []const u8,
        options: FetchOptions,
    ) !ClientResponse {
        const uri = try parseUrl(url);
        const info = try uriPortAndProtocol(uri);
        const max_redirects = options.max_redirects orelse self.config.max_redirects;
        // Pinned here, so every redirect and the body share one budget.
        const deadline: Deadline = .init(self.io, options.timeout orelse self.defaultTimeout());
        const state: FetchState = .{
            .uri = uri,
            .port = info.port,
            .protocol = info.protocol,
            .options = options,
            .redirects_remaining = max_redirects,
        };
        const retry: ?resilience.Retry = if (options.idempotent orelse isReplayable(options)) options.retry.resolve(self.config.retry) else null;
        if (retry == null and self._breakers == null) return deadline.run(fetchFollowing, .{ self, state });

        var key_buf: [300]u8 = undefined;
        var breaker: ?*resilience.Breaker = null;
        if (self._breakers) |*bs| {
            const key = breakerKey(&key_buf, uri, info.protocol, info.port, options.unix_socket_path);
            breaker = try bs.get(self.io, key);
        }
        var ctx: AttemptCtx = .{ .client = self, .state = state, .deadline = deadline, .attempt_timeout = if (retry) |r| r.attempt_timeout else null };
        const policy: resilience.Policy = .{
            .retry = retry,
            .breaker = breaker,
            .throttle = if (retry != null and retry.?.throttle != null) &self._throttle else null,
            .deadline = switch (deadline.timeout) {
                .deadline => |d| d,
                else => null,
            },
            .metrics = self.resilience_metrics,
            .kind = .http,
        };
        const attempt = try resilience.run(self.io, policy, &ctx, attemptFetch, FetchJudge);
        return attempt.result;
    }

    /// The breaker's key: scheme://host:port, lower-cased, of the first hop.
    fn breakerKey(buf: *[300]u8, uri: Uri, protocol: Protocol, port: u16, unix_path: ?[]const u8) []const u8 {
        if (unix_path) |p| return std.fmt.bufPrint(buf, "unix:{s}", .{p[0..@min(p.len, 290)]}) catch "unix:";
        var host_buf: [255]u8 = undefined;
        const host = uriHost(uri, &host_buf) catch "";
        const scheme = switch (protocol) {
            .http => "http",
            .https => "https",
        };
        const key = std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ scheme, host[0..@min(host.len, 255)], port }) catch return "";
        for (key) |*ch| ch.* = std.ascii.toLower(ch.*);
        return key;
    }

    const FetchOut = Deadline.Result(fetchFollowing);

    const AttemptCtx = struct {
        client: *Client,
        state: FetchState,
        deadline: Deadline,
        attempt_timeout: ?std.Io.Duration,
    };

    /// What one attempt leaves for the judge.
    const Attempt = struct {
        result: FetchOut,
        statuses: []const u16,
        /// Wall-clock seconds when the attempt ended (for Retry-After dates).
        now_s: i64 = 0,
    };

    /// A `Retry-After` value: delta-seconds, or an HTTP date (IMF-fixdate)
    /// counted from `now_s`; a date in the past is no wait.
    pub fn retryAfterValue(value: []const u8, now_s: i64) ?std.Io.Duration {
        const v = std.mem.trim(u8, value, " \t");
        if (std.fmt.parseInt(u32, v, 10)) |secs| return .fromSeconds(secs) else |_| {}
        const date = @import("server/static.zig").parseHttpDate(v) orelse return null;
        const secs = @max(0, date - now_s);
        return .fromSeconds(@min(secs, std.math.maxInt(u32)));
    }

    fn attemptFetch(ctx: *AttemptCtx, n: u32) Attempt {
        _ = n;
        var d = ctx.deadline;
        if (ctx.attempt_timeout) |at| {
            const own: Deadline = .init(ctx.client.io, .{ .duration = .{ .raw = at, .clock = .awake } });
            d = switch (d.timeout) {
                .none => own,
                .deadline => |overall| switch (own.timeout) {
                    .deadline => |mine| if (mine.raw.nanoseconds < overall.raw.nanoseconds) own else d,
                    else => d,
                },
                else => d,
            };
        }
        const result = d.run(fetchFollowing, .{ ctx.client, ctx.state });
        return .{ .result = result, .statuses = ctx.client.config.retry_statuses, .now_s = std.Io.Clock.real.now(ctx.client.io).toSeconds() };
    }

    fn transportVerdict(name: []const u8) resilience.Verdict {
        if (std.mem.eql(u8, name, "Canceled")) return .neutral;
        // SocketUnconnected: std's name for a send on a socket whose peer
        // or sending side is gone (EPIPE).
        const transient = [_][]const u8{ "Timeout", "ConnectionRefused", "ConnectionResetByPeer", "ConnectionTimedOut", "EndOfStream", "BrokenPipe", "SocketUnconnected", "NetworkUnreachable", "HostUnreachable", "UnknownHostName", "TemporaryNameServerFailure", "NameServerFailure" };
        for (transient) |t| if (std.mem.eql(u8, name, t)) return .transient;
        return .failure;
    }

    const FetchJudge = struct {
        pub fn verdict(a: *const Attempt) resilience.Verdict {
            const resp = a.result catch |err| return transportVerdict(@errorName(err));
            const code = @intFromEnum(resp.status());
            for (a.statuses) |s| if (s == code) return if (code == 429) .retryable else .transient;
            return switch (code) {
                408, 500, 502, 503, 504 => .failure,
                501, 505 => .neutral,
                400...407, 409...499 => .neutral,
                else => .success,
            };
        }
        pub fn retryAfter(a: *const Attempt) ?std.Io.Duration {
            const resp = a.result catch return null;
            const code = @intFromEnum(resp.status());
            if (code != 429 and code != 503) return null;
            const value = resp.headers().get("Retry-After") orelse return null;
            return retryAfterValue(value, a.now_s);
        }
        pub fn discard(a: *Attempt) void {
            if (a.result) |*resp| {
                var r = resp.*;
                r.deinit();
            } else |_| {}
        }
        pub fn reason(a: *const Attempt) []const u8 {
            _ = a.result catch |err| return if (err == error.Timeout) "timeout" else "transport";
            return "status";
        }
    };

    /// One request per hop, in a loop rather than a call per redirect, so
    /// the stack does not grow with `max_redirects`. A hop's URL and
    /// Referer live in `hops`, the two sets taking turns: the next hop
    /// reads the last one's while it writes its own.
    fn fetchFollowing(self: *Client, first: FetchState) !ClientResponse {
        var hops: [2]HopBuffers = undefined;
        var initial_host: [255]u8 = undefined;
        var state = first;
        var turn: u1 = 0;
        while (true) : (turn +%= 1) {
            switch (try self.fetchInternal(state, &hops[turn], &initial_host)) {
                .done => |response| return response,
                .next => |next| state = next,
            }
        }
    }

    /// Starts a request whose body is written as it goes (see `Upload`):
    /// the head is sent at once, over HTTP/1.1 only (also for https), with
    /// no redirects, retries or breaker. `url` must be http or https.
    pub fn upload(self: *Client, url: []const u8, options: UploadOptions) !Upload {
        const uri = try parseUrl(url);
        const info = try uriPortAndProtocol(uri);
        const timeout = options.timeout orelse self.defaultTimeout();
        const deadline: Deadline = .init(self.io, timeout);
        return deadline.run(openUpload, .{ self, uri, info.port, info.protocol, options, timeout });
    }

    fn openUpload(self: *Client, uri: Uri, port: u16, protocol: Protocol, options: UploadOptions, timeout: std.Io.Timeout) !Upload {
        var host_buffer: [255]u8 = undefined;
        const host = try uriHost(uri, &host_buffer);
        try http.validateHeaderValue(host);
        const tls_config: ?TlsRef = if (protocol == .https) blk: {
            if (!build_options.use_tls) return error.TlsNotConfigured;
            break :blk try self.ensureTlsState();
        } else null;
        const conn = try self.acquireConnection(host, port, protocol, tls_config, options.unix_socket_path, false);
        var armed = true;
        errdefer if (armed) {
            conn.closing = true;
            conn.pool.release(conn);
        };
        const impl = try self.allocator.create(UploadImpl);
        errdefer self.allocator.destroy(impl);
        impl.* = .{ .client = self, .conn = conn, .timeout = timeout, .w = .{ .vtable = &UploadImpl.vtable, .buffer = &.{} } };
        impl.w.buffer = &impl.buffer;

        conn.parser.head_request = options.method == .head;
        conn.parser.connect_request = false;
        const w = conn.writer;
        try http.validateHeaderValue(host);
        try checkRequestTarget(uri);
        const path = uriPath(uri);
        if (uri.query) |query| {
            try w.print("{s} {s}?{s} HTTP/1.1\r\n", .{ options.method.name(), path, query.percent_encoded });
        } else {
            try w.print("{s} {s} HTTP/1.1\r\n", .{ options.method.name(), path });
        }
        try requestFields(.{
            .method = options.method,
            .uri = uri,
            .host = host,
            .port = port,
            .protocol = protocol,
            .headers = options.headers,
            .body = null,
            .decompress = false,
            .user_agent = self.config.user_agent,
        }, w, writeUploadField);
        try w.writeAll("Transfer-Encoding: chunked\r\n");
        if (options.trailer_names.len > 0) {
            try w.writeAll("Trailer: ");
            for (options.trailer_names, 0..) |name, i| {
                try http.validateHeaderName(name);
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(name);
            }
            try w.writeAll("\r\n");
        }
        try w.writeAll("\r\n");
        conn.flush() catch |err| return err;
        armed = false;
        return .{ .writer = &impl.w, .impl = impl };
    }

    /// Closes the idle pooled connections of every executor's pool (busy
    /// ones are left alone): for a process that was frozen and thawed,
    /// whose idle sockets the network may have dropped.
    pub fn closeIdle(self: *Client) void {
        for (self.pools[0..self.pool_count]) |*p| p.closeIdle();
    }

    /// The pool of the executor the calling task runs on: the first one
    /// off zio's executors (`std.Io.Threaded`, a blocking-pool thread).
    pub fn pool(self: *Client) *ConnectionPool {
        const index = placement.currentExecutor(self.io) orelse 0;
        return &self.pools[index % self.pool_count];
    }

    fn defaultTimeout(self: *const Client) std.Io.Timeout {
        const duration = self.config.timeout orelse return .none;
        return .{ .duration = .{ .raw = duration, .clock = .awake } };
    }

    /// Acquire a connection from the pool or create a new one.
    fn acquireConnection(
        self: *Client,
        host: []const u8,
        port: u16,
        protocol: Protocol,
        tls_config: ?TlsRef,
        unix_socket_path: ?[]const u8,
        // Whether to offer HTTP/2 via TLS ALPN. Callers that can't speak h2
        // (e.g. the WebSocket upgrade path) must pass false.
        advertise_http2: bool,
    ) !*Connection {
        const p = self.pool();
        if (p.acquire(host, port, protocol, unix_socket_path)) |conn| {
            if (advertise_http2 or conn.http_version != .http_2) return conn;
            // An HTTP/2 connection cannot carry what this is for (a
            // WebSocket upgrade); it stays for the next fetch.
            p.release(conn);
        }
        return self.dialConnection(host, port, protocol, tls_config, unix_socket_path, advertise_http2);
    }

    /// Open a new connection, bypassing the pool.
    fn dialConnection(
        self: *Client,
        host: []const u8,
        port: u16,
        protocol: Protocol,
        tls_config: ?TlsRef,
        unix_socket_path: ?[]const u8,
        advertise_http2: bool,
    ) !*Connection {
        const stream = if (unix_socket_path) |path| unix: {
            const unix_addr = try std.Io.net.UnixAddress.init(path);
            break :unix try unix_addr.connect(self.io);
        } else if (std.Io.net.IpAddress.parse(unbracketed(host), port)) |addr| tcp: {
            break :tcp try addr.connect(self.io, .{ .mode = .stream });
        } else |_| try (try std.Io.net.HostName.init(host)).connect(self.io, port, .{ .mode = .stream });
        errdefer stream.close(self.io);
        if (self.config.deny_private_addresses and unix_socket_path == null and isPrivateAddress(stream.socket.address))
            return error.AddressNotAllowed;

        const conn = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(conn);
        try conn.init(
            self.allocator,
            self.io,
            self.pool(),
            stream,
            host,
            port,
            self.config.buffer_size,
            self.config.max_response_header_count,
            protocol,
            tls_config,
            unix_socket_path,
            advertise_http2,
        );
        _ = self.dials.fetchAdd(1, .monotonic);
        return conn;
    }

    /// Connect to a WebSocket server.
    pub fn connectWebSocket(
        self: *Client,
        url: []const u8,
        options: WebSocketUpgradeOptions,
    ) !WebSocketClient {
        const uri = try parseUrl(url);
        const info = try uriPortAndProtocol(uri);
        var host_buffer: [255]u8 = undefined;
        const host = try uriHost(uri, &host_buffer);

        // Load the shared TLS material for HTTPS
        const tls_config: ?TlsRef = if (info.protocol == .https) blk: {
            if (!build_options.use_tls) return error.TlsNotConfigured;
            break :blk try self.ensureTlsState();
        } else null;

        // Reject any CRLF/NUL smuggled in via the URL host.
        try http.validateHeaderValue(host);

        // Acquire or create a connection. WebSocket upgrades are HTTP/1.1 only,
        // so never advertise h2 here.
        const conn = try self.acquireConnection(host, info.port, info.protocol, tls_config, options.unix_socket_path, false);
        errdefer {
            conn.deinit();
            self.allocator.destroy(conn);
        }

        // Generate Sec-WebSocket-Key: 16 random bytes -> base64
        var key_bytes: [16]u8 = undefined;
        self.io.random(&key_bytes);
        var key_buf: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

        // Write upgrade request. Through a bare writer, so it can only report
        // the sentinel; resolved here, once, the way the response path is.
        writeUpgradeRequest(conn.writer, .{
            .uri = uri,
            .host = host,
            .port = info.port,
            .protocol = info.protocol,
            .key = &key_buf,
            .headers = options.headers,
        }) catch |err| {
            conn.closing = true;
            switch (err) {
                error.WriteFailed => return conn.getWriteError() orelse error.Unexpected,
                else => |e| return e,
            }
        };

        try conn.flush();

        // Parse response headers
        parseResponseHeaders(conn.reader, &conn.parser) catch |err| switch (err) {
            error.ReadFailed => return conn.getReadError() orelse error.Unexpected,
            else => |e| return e,
        };

        // Validate 101 Switching Protocols
        if (conn.parsed_response.status != .switching_protocols) {
            return error.WebSocketUpgradeFailed;
        }

        // Validate Sec-WebSocket-Accept
        const accept = conn.parsed_response.headers.get("Sec-WebSocket-Accept") orelse
            return error.WebSocketUpgradeFailed;
        var expected_accept: [28]u8 = undefined;
        WebSocket.computeAcceptKey(&key_buf, &expected_accept);
        if (!std.mem.eql(u8, accept, &expected_accept)) {
            return error.WebSocketUpgradeFailed;
        }

        var seed: u64 = undefined;
        self.io.random(std.mem.asBytes(&seed));
        var ws = WebSocket.init(self.io, conn.transport(), conn.allocator, seed);
        ws.is_client = true;
        return .{ .ws = ws, .conn = conn };
    }

    fn fetchInternal(self: *Client, state: FetchState, bufs: *HopBuffers, initial_host_buf: *[255]u8) !Hop {
        var host_buffer: [255]u8 = undefined;
        const host = try uriHost(state.uri, &host_buffer);

        // Load the shared TLS material for HTTPS
        const tls_config: ?TlsRef = if (state.protocol == .https) blk: {
            if (!build_options.use_tls) return error.TlsNotConfigured;
            break :blk try self.ensureTlsState();
        } else null;

        // Acquire or create a connection. The redirect path releases it early
        // and continues with fallible work, so the errdefer must be disarmed
        // after that release to avoid releasing the connection twice.
        const advertise_http2 = has_h2_client and self.config.http2 and state.protocol == .https;
        var reused = true;
        var conn = self.pool().acquire(host, state.port, state.protocol, state.options.unix_socket_path) orelse blk: {
            reused = false;
            break :blk try self.dialConnection(host, state.port, state.protocol, tls_config, state.options.unix_socket_path, advertise_http2);
        };
        var conn_released = false;
        errdefer if (!conn_released) conn.pool.release(conn);

        var lost = false;
        self.sendRequest(conn, state, host, &lost) catch |err| {
            // The server may have closed the idle connection just as it was
            // picked up. Retried on a new one under the same conditions as
            // Go's net/http.
            if (!lost or !reused or !isReplayable(state.options)) return err;
            conn.pool.release(conn);
            conn_released = true;
            conn = try self.dialConnection(host, state.port, state.protocol, tls_config, state.options.unix_socket_path, advertise_http2);
            conn_released = false;
            try self.sendRequest(conn, state, host, &lost);
        };

        // From here on an error leaves the body where it is, and the
        // errdefer above pools the connection. A body still on the wire
        // would be read as the next response, so it may not go back.
        errdefer if (!conn_released and conn.bodyPending()) {
            conn.closing = true;
        };

        // Check for unsupported content encoding
        if (state.options.decompress and conn.parsed_response.content_encoding == .unknown) {
            return error.UnsupportedContentEncoding;
        }

        // Check for redirects
        const status_code = @backingInt(conn.parsed_response.status);
        if (isRedirect(conn.parsed_response.status) and state.redirects_remaining > 0) redirect: {
            if (conn.parsed_response.headers.get("Location")) |location| {
                // Resolve redirect URL using RFC 3986
                if (location.len > bufs.resolve.len) return error.InvalidUrl;
                @memcpy(bufs.resolve[0..location.len], location);
                var aux_buf: []u8 = bufs.resolve[0..];
                const redirect_uri = Uri.resolveInPlace(state.uri, location.len, &aux_buf) catch return error.InvalidUrl;
                const redirect_info = try uriPortAndProtocol(redirect_uri);
                try checkRequestTarget(redirect_uri);

                // 301/302/303 with a non-GET/HEAD method: switch to GET and drop body.
                // QUERY keeps its method and body on 301/302 (RFC 10008, Section 2.5).
                // 307/308 preserve the original method and body.
                var redirect_options = state.options;
                if (status_code == 301 or status_code == 302 or status_code == 303) {
                    const method = redirect_options.method;
                    const keeps_method = method == .get or method == .head or
                        (method == .query and status_code != 303);
                    if (!keeps_method) {
                        redirect_options.method = .get;
                        redirect_options.body = null;
                    } else if (status_code == 303) {
                        redirect_options.body = null;
                    }
                }

                var redirect_host_buffer: [255]u8 = undefined;
                const redirect_host = try uriHost(redirect_uri, &redirect_host_buffer);
                const same_origin = redirect_info.protocol == state.protocol and redirect_info.port == state.port and
                    std.ascii.eqlIgnoreCase(redirect_host, host);

                // Whether to follow it: the policy hook decides when there is
                // one. Without one, a body goes only to the same host (or the
                // same host over https); a redirect that would carry it
                // elsewhere is returned as the response.
                const action: RedirectAction = if (self.config.check_redirect) |policy|
                    policy.check(policy.context, &.{
                        .status = @intCast(status_code),
                        .from = state.uri,
                        .to = redirect_uri,
                        .method = redirect_options.method,
                        .has_body = redirect_options.body != null,
                        .hops = (state.options.max_redirects orelse self.config.max_redirects) -| state.redirects_remaining,
                        .cross_origin = !same_origin,
                    })
                else if (redirect_options.body != null and !sameHostOrUpgrade(state.protocol, state.port, host, redirect_info.protocol, redirect_info.port, redirect_host))
                    .stop
                else
                    .follow;
                switch (action) {
                    .follow => {},
                    .stop => break :redirect,
                    .fail => return error.RedirectRefused,
                }

                if (!conn.parser.shouldKeepAlive() or !conn.pool.pooling()) conn.closing = true;

                // Drain small redirect bodies (up to 2KB) so the connection can
                // be returned to the pool rather than closed.
                if (!conn.closing and conn.bodyPending()) {
                    const max_drain = 2048;
                    var drain_buf: [1024]u8 = undefined;
                    // No decoding: this is throwing the body away to keep the
                    // connection, so what it would decode to does not matter.
                    var body_reader = ResponseBodyReader.init(&conn.parser, conn.transport(), &drain_buf);
                    _ = body_reader.interface.discardShort(max_drain + 1) catch |err| switch (err) {
                        error.ReadFailed => {
                            conn.closing = true;
                            return body_reader.err orelse error.Unexpected;
                        },
                    };
                    if (!conn.parser.isBodyComplete()) conn.closing = true;
                }
                conn.pool.release(conn);
                conn_released = true;

                // Strip sensitive headers when:
                //   - already stripping from a previous hop, OR
                //   - crossing to a different domain/host (same-domain and subdomain keep headers), OR
                //   - downgrading from https to http (credentials would travel in plaintext).
                // The first hop's host is kept for the hops after it.
                const effective_initial_host = if (state.initial_host.len == 0) blk: {
                    @memcpy(initial_host_buf[0..host.len], host);
                    break :blk initial_host_buf[0..host.len];
                } else state.initial_host;
                const redirect_strip_sensitive = state.strip_sensitive_headers or
                    !isDomainOrSubdomain(redirect_host, effective_initial_host) or
                    (state.protocol == .https and redirect_info.protocol == .http);

                // Strip body-related headers when there is no body to send.
                const redirect_strip_body = redirect_options.body == null;

                // Compute Referer for the next hop, as browsers' default
                // policy (strict-origin-when-cross-origin) does: the whole
                // URL within one origin, only the origin across origins, and
                // none on a downgrade from https to http. If the user already
                // set a Referer header, forward it as-is.
                const redirect_referer: ?[]const u8 = blk: {
                    if (state.protocol == .https and redirect_info.protocol == .http) break :blk null;
                    if (redirect_options.headers) |h| {
                        if (h.get("Referer")) |existing| break :blk existing;
                    }
                    var w = std.Io.Writer.fixed(&bufs.referer);
                    state.uri.writeToStream(&w, .{
                        .scheme = true,
                        .authority = true,
                        .authentication = false, // strip userinfo — never leak credentials in Referer
                        .path = same_origin,
                        .query = same_origin,
                        .fragment = false, // strip fragment — not sent to servers per RFC 7231
                        .port = true,
                    }) catch break :blk null;
                    if (!same_origin) w.writeByte('/') catch break :blk null;
                    break :blk w.buffered();
                };

                return .{ .next = .{
                    .uri = redirect_uri,
                    .port = redirect_info.port,
                    .protocol = redirect_info.protocol,
                    .options = redirect_options,
                    .redirects_remaining = state.redirects_remaining - 1,
                    .initial_host = effective_initial_host,
                    .strip_sensitive_headers = redirect_strip_sensitive,
                    .strip_body_headers = redirect_strip_body,
                    .referer = redirect_referer,
                } };
            }
        }

        // Build response with direct pointers for reading
        var response = ClientResponse{
            .arena = conn.arena.allocator(),
            .parser = &conn.parser,
            .transport = conn.transport(),
            .parsed = &conn.parsed_response,
            .max_response_size = self.config.max_response_size,
            .decompress = state.options.decompress,
            .owner = conn,
            .raw = if (comptime has_h2_client) if (conn.h2_stream) |st| .{ .reader = st.reader(), .err = h2BodyError } else null else null,
        };
        // Under the request's deadline, which ends with this call. A body
        // left on the wire is the caller's to read, on the caller's time.
        if (!state.options.stream) _ = try response.body();
        return .{ .done = response };
    }

    /// Writes the request on `conn` and reads the response head. `lost` is
    /// set when the connection failed before any of the response arrived.
    fn sendRequest(self: *Client, conn: *Connection, state: FetchState, host: []const u8, lost: *bool) !void {
        if (conn.http_version == .http_2) {
            if (comptime has_h2_client) return self.sendRequestH2(conn, state, host, lost);
            // Never offered without a client to speak it; and the TLS
            // connection is committed to h2, so it is not pooled.
            conn.closing = true;
            return error.Http2NotImplemented;
        }

        // Whatever the proxy answers, what follows a CONNECT on the wire
        // cannot be relied on to be the next response.
        if (state.options.method == .connect) conn.closing = true;

        conn.parser.head_request = state.options.method == .head;
        conn.parser.connect_request = state.options.method == .connect;

        // Send request. On write/flush failure the connection is dead or has
        // a partially written request, so mark it closing before the errdefer
        // releases it — otherwise it gets pooled again and poisons the pool.
        var write_err: ?Connection.WriteError = null;
        writeRequest(conn.writer, .{
            .method = state.options.method,
            .uri = state.uri,
            .host = host,
            .port = state.port,
            .protocol = state.protocol,
            .headers = state.options.headers,
            .body = state.options.body,
            .decompress = state.options.decompress,
            .strip_sensitive_headers = state.strip_sensitive_headers,
            .strip_body_headers = state.strip_body_headers,
            .referer = state.referer,
            .user_agent = self.config.user_agent,
        }) catch |err| {
            conn.closing = true;
            switch (err) {
                error.WriteFailed => write_err = conn.getWriteError() orelse error.Unexpected,
                else => |e| return e,
            }
        };

        if (write_err == null) conn.flush() catch |err| {
            conn.closing = true;
            write_err = err;
        };

        // A failed head read leaves whatever it got in the buffer, so an
        // empty one means none of the response arrived, unless an interim
        // response was read and dropped from it.
        if (write_err) |err| {
            if (err == error.Canceled) return err;
            // A server that rejects the request (413, 401, ...) may answer
            // and close before reading all of it. The fetch's own deadline
            // still applies on top of this one.
            const early: Deadline = .init(self.io, .{ .duration = .{ .raw = early_response_wait, .clock = .awake } });
            early.run(Connection.parseHead, .{conn}) catch |read_err| switch (read_err) {
                error.Canceled => return error.Canceled,
                else => {
                    lost.* = conn.reader.end == 0 and !conn.parser.state.saw_interim;
                    return err;
                },
            };
        } else {
            // Any failure leaves the connection at an unknown stream
            // position, so it must not be pooled.
            conn.parseHead() catch |err| {
                conn.closing = true;
                lost.* = err != error.Canceled and conn.reader.end == 0 and !conn.parser.state.saw_interim;
                return err;
            };
        }
    }

    /// `sendRequest` over HTTP/2: the request as one stream, and its
    /// response head in `conn.parsed_response` as the HTTP/1.1 parser
    /// leaves it. The body stays on the stream for `ClientResponse`.
    fn sendRequestH2(self: *Client, conn: *Connection, state: FetchState, host: []const u8, lost: *bool) !void {
        if (comptime !has_h2_client) unreachable;
        try http.validateHeaderValue(host);
        try checkRequestTarget(state.uri);
        const arena = conn.arena.allocator();
        const path = uriPath(state.uri);
        var fields: H2Fields = .{ .arena = arena };
        try fields.list.appendSlice(arena, &.{
            .{ .name = ":method", .value = state.options.method.name() },
            .{ .name = ":scheme", .value = "https" },
            .{ .name = ":path", .value = if (state.uri.query) |query|
                try std.fmt.allocPrint(arena, "{s}?{s}", .{ path, query.percent_encoded })
            else
                path },
        });
        try requestFields(.{
            .method = state.options.method,
            .uri = state.uri,
            .host = host,
            .port = state.port,
            .protocol = state.protocol,
            .headers = state.options.headers,
            .body = state.options.body,
            .decompress = state.options.decompress,
            .strip_sensitive_headers = state.strip_sensitive_headers,
            .strip_body_headers = state.strip_body_headers,
            .referer = state.referer,
            .user_agent = self.config.user_agent,
        }, &fields, H2Fields.add);

        // The fetch's deadline bounds every wait below; the stream has
        // none of its own. The body goes out as the server takes it while
        // this waits for the head, so a server that answers as it reads
        // cannot stall the request.
        const stream = conn.h2.?.request(fields.list.items, .{ .body_bytes = state.options.body, .timeout = .none }) catch |err| {
            // The server sent GOAWAY, or the connection failed, before
            // this request: none of it went out.
            conn.closing = true;
            lost.* = err == error.ConnectionClosed;
            return err;
        };
        conn.h2_stream = stream;
        stream.waitHead() catch |err| {
            // The connection went with nothing of the response: as an
            // HTTP/1.1 connection lost before the response, which a reused
            // one may retry.
            if (err == error.ConnectionClosed) {
                conn.closing = true;
                lost.* = true;
            }
            return err;
        };

        const parsed = &conn.parsed_response;
        parsed.status = try http.Status.fromCode(stream.status);
        parsed.version_major = 2;
        parsed.version_minor = 0;
        for (stream.headers.items) |h| try parsed.headers.add(try arena.dupe(u8, h.name), try arena.dupe(u8, h.value));
        // As the parser's `onHeadersComplete` reads them.
        if (parsed.headers.get("Content-Type")) |v| parsed.content_type = ContentType.fromContentType(v);
        if (parsed.headers.get("Content-Encoding")) |v| parsed.content_encoding = ContentEncoding.fromString(v);
        if (parsed.headers.get("Content-Length")) |v| parsed.content_length = std.fmt.parseInt(usize, v, 10) catch null;
        conn.parser.state.headers_complete = true;
        // A response that has no body whatever its headers say, so nothing
        // starts decoding one.
        conn.parser.state.message_complete = state.options.method == .head or
            parsed.status == .no_content or parsed.status == .not_modified or
            parsed.content_length == 0;
    }
};

/// Whether a request may be sent again after a connection failure, by the
/// same rules as Go's net/http. A body is a slice, so it can always be resent.
fn isReplayable(options: FetchOptions) bool {
    switch (options.method) {
        .get, .head, .options, .trace, .query => return true,
        else => {},
    }
    const headers = options.headers orelse return false;
    return headers.get("Idempotency-Key") != null or headers.get("X-Idempotency-Key") != null;
}

/// Whether `address` is one `deny_private_addresses` refuses: anything
/// but a global unicast address. IPv4 inside IPv6 (mapped, compatible,
/// NAT64, 6to4) is judged by its IPv4 address.
pub fn isPrivateAddress(address: std.Io.net.IpAddress) bool {
    switch (address) {
        .ip4 => |a| return isPrivateIp4(a.bytes),
        .ip6 => |a| {
            const b = a.bytes;
            const zero10 = std.mem.allEqual(u8, b[0..10], 0);
            // ::ffff:a.b.c.d and the deprecated ::a.b.c.d (which covers ::
            // and ::1).
            if (zero10 and ((b[10] == 0xff and b[11] == 0xff) or (b[10] == 0 and b[11] == 0)))
                return isPrivateIp4(b[12..16].*);
            // 64:ff9b::/96, NAT64.
            if (std.mem.eql(u8, b[0..12], &.{ 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 })) return isPrivateIp4(b[12..16].*);
            // 2002::/16, 6to4.
            if (b[0] == 0x20 and b[1] == 0x02) return isPrivateIp4(b[2..6].*);
            // fc00::/7 unique local, fe80::/10 link-local, fec0::/10
            // site-local, ff00::/8 multicast.
            if (b[0] & 0xfe == 0xfc) return true;
            if (b[0] == 0xfe and b[1] & 0x80 != 0) return true;
            if (b[0] == 0xff) return true;
            return false;
        },
    }
}

fn isPrivateIp4(b: [4]u8) bool {
    return switch (b[0]) {
        0, 10, 127 => true, // this network, private, loopback
        100 => b[1] & 0xc0 == 64, // 100.64.0.0/10, shared (CGN)
        169 => b[1] == 254, // link-local, cloud metadata
        172 => b[1] & 0xf0 == 16, // 172.16.0.0/12
        192 => (b[1] == 168) or (b[1] == 0 and b[2] == 0), // 192.168.0.0/16, 192.0.0.0/24
        198 => b[1] & 0xfe == 18, // 198.18.0.0/15, benchmarking
        else => b[0] >= 224, // multicast, reserved, broadcast
    };
}

/// What one hop of `fetch` came to: the response, or the redirect to follow.
const Hop = union(enum) {
    done: ClientResponse,
    next: FetchState,
};

/// Where a hop resolves its redirect's URL and writes the Referer for the
/// next one.
const HopBuffers = struct {
    resolve: [2048]u8,
    referer: [2048]u8,
};

/// Whether a redirect keeps the request's body on one host: the same
/// scheme and port, or the same host moving from http to https.
fn sameHostOrUpgrade(from: Protocol, from_port: u16, from_host: []const u8, to: Protocol, to_port: u16, to_host: []const u8) bool {
    if (!std.ascii.eqlIgnoreCase(from_host, to_host)) return false;
    if (from == to) return from_port == to_port;
    return from == .http and to == .https;
}

const FetchState = struct {
    uri: Uri,
    port: u16,
    protocol: Protocol,
    options: FetchOptions,
    redirects_remaining: u8,
    initial_host: []const u8 = "",
    strip_sensitive_headers: bool = false,
    strip_body_headers: bool = false,
    referer: ?[]const u8 = null,
};

const WriteRequestOptions = struct {
    method: Method,
    uri: Uri,
    host: []const u8,
    port: u16,
    protocol: Protocol,
    headers: ?*const Headers = null,
    body: ?[]const u8 = null,
    decompress: bool = true,
    strip_sensitive_headers: bool = false,
    strip_body_headers: bool = false,
    referer: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

const WriteUpgradeRequestOptions = struct {
    uri: Uri,
    host: []const u8,
    port: u16,
    protocol: Protocol,
    key: []const u8,
    headers: ?*const Headers,
};

/// The WebSocket upgrade request, on the wire. Takes the writer rather than
/// the connection so it can only report the sentinel, which is the caller's
/// to resolve -- the same split `writeRequest` has.
fn writeUpgradeRequest(writer: *std.Io.Writer, opts: WriteUpgradeRequestOptions) !void {
    try checkRequestTarget(opts.uri);
    const path = uriPath(opts.uri);
    if (opts.uri.query) |query| {
        try writer.print("GET {s}?{s} HTTP/1.1\r\n", .{ path, query.percent_encoded });
    } else {
        try writer.print("GET {s} HTTP/1.1\r\n", .{path});
    }

    if ((opts.protocol == .http and opts.port == 80) or (opts.protocol == .https and opts.port == 443)) {
        try writer.print("Host: {s}\r\n", .{opts.host});
    } else {
        try writer.print("Host: {s}:{d}\r\n", .{ opts.host, opts.port });
    }

    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.print("Sec-WebSocket-Key: {s}\r\n", .{opts.key});
    try writer.writeAll("Sec-WebSocket-Version: 13\r\n");

    // User-provided headers, minus the ones the upgrade owns.
    if (opts.headers) |h| {
        var it = h.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key, "Host")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Upgrade")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Connection")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Sec-WebSocket-Key")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Sec-WebSocket-Version")) continue;
            try http.validateHeaderName(entry.key);
            try http.validateHeaderValue(entry.value);
            try writer.print("{s}: {s}\r\n", .{ entry.key, entry.value });
        }
    }

    return writer.writeAll("\r\n");
}

fn writeRequest(writer: *std.Io.Writer, opts: WriteRequestOptions) !void {
    // Reject any CRLF/NUL smuggled in via the URL host (a URL like
    // "http://foo%0d%0aX-Evil:1/" would otherwise inject a header).
    try http.validateHeaderValue(opts.host);

    // Request line - path with query
    try checkRequestTarget(opts.uri);
    const path = uriPath(opts.uri);
    if (opts.uri.query) |query| {
        try writer.print("{s} {s}?{s} HTTP/1.1\r\n", .{ opts.method.name(), path, query.percent_encoded });
    } else {
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ opts.method.name(), path });
    }

    try requestFields(opts, writer, writeField);

    // End of headers
    try writer.writeAll("\r\n");

    // Body
    if (opts.body) |b| {
        try writer.writeAll(b);
    }
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.print("{s}: {s}\r\n", .{ name, value });
}

/// The request's header fields, `Host` first, each validated and handed to
/// `emit(sink, name, value)`: what HTTP/1.1 writes after the request line
/// and HTTP/2 sends after its pseudo-headers. `value` may be a temporary.
fn requestFields(opts: WriteRequestOptions, sink: anytype, comptime emit: anytype) !void {
    // Host header
    var host_buf: [300]u8 = undefined;
    if ((opts.protocol == .http and opts.port == 80) or (opts.protocol == .https and opts.port == 443)) {
        try emit(sink, "Host", opts.host);
    } else {
        try emit(sink, "Host", try std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ opts.host, opts.port }));
    }

    // Content-Length for body. A method that usually carries one says so
    // even when there is none: some servers answer 411 otherwise.
    var length_buf: [24]u8 = undefined;
    if (opts.body) |b| {
        try emit(sink, "Content-Length", try std.fmt.bufPrint(&length_buf, "{d}", .{b.len}));
    } else if (opts.method == .post or opts.method == .put or opts.method == .patch) {
        try emit(sink, "Content-Length", "0");
    }

    // User-provided headers
    var has_accept_encoding = false;
    var has_referer = false;
    var has_user_agent = false;
    if (opts.headers) |h| {
        var it = h.iterator();
        while (it.next()) |entry| {
            // Skip headers we already set
            if (std.ascii.eqlIgnoreCase(entry.key, "Host")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Content-Length")) continue;
            if (std.ascii.eqlIgnoreCase(entry.key, "Accept-Encoding")) has_accept_encoding = true;
            if (std.ascii.eqlIgnoreCase(entry.key, "Referer")) has_referer = true;
            if (std.ascii.eqlIgnoreCase(entry.key, "User-Agent")) has_user_agent = true;

            if (opts.strip_sensitive_headers) {
                if (std.ascii.eqlIgnoreCase(entry.key, "Authorization")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Www-Authenticate")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Cookie")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Cookie2")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Proxy-Authorization")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Proxy-Authenticate")) continue;
            }
            if (opts.strip_body_headers) {
                if (std.ascii.eqlIgnoreCase(entry.key, "Content-Encoding")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Content-Language")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Content-Location")) continue;
                if (std.ascii.eqlIgnoreCase(entry.key, "Content-Type")) continue;
            }

            try http.validateHeaderName(entry.key);
            try http.validateHeaderValue(entry.value);
            try emit(sink, entry.key, entry.value);
        }
    }

    // Add auto-Referer from previous hop if user didn't provide one
    if (opts.referer) |referer| {
        if (!has_referer) {
            try http.validateHeaderValue(referer);
            try emit(sink, "Referer", referer);
        }
    }

    // Add default User-Agent if configured and user didn't provide one
    if (opts.user_agent) |ua| {
        if (!has_user_agent) {
            try http.validateHeaderValue(ua);
            try emit(sink, "User-Agent", ua);
        }
    }

    // Add default Accept-Encoding if decompress enabled and user didn't
    // provide one, and only for codings this build can undo.
    if (build_options.use_zlib and opts.decompress and !has_accept_encoding) {
        try emit(sink, "Accept-Encoding", "gzip, deflate");
    }
}

/// The request as HTTP/2 header fields: the pseudo-headers, then the
/// fields `requestFields` gives, `Host` as `:authority`, names in lower
/// case, without the fields HTTP/2 forbids (RFC 9113 §8.2.2). Copied into
/// `arena`.
const H2Fields = if (has_h2_client) struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(h2_client.Header) = .empty,

    fn add(self: *@This(), name: []const u8, value: []const u8) !void {
        const connection_specific = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" };
        for (connection_specific) |n| if (std.ascii.eqlIgnoreCase(name, n)) return;
        if (std.ascii.eqlIgnoreCase(name, "te") and !std.ascii.eqlIgnoreCase(value, "trailers")) return;
        const lower = if (std.ascii.eqlIgnoreCase(name, "host")) ":authority" else try std.ascii.allocLowerString(self.arena, name);
        try self.list.append(self.arena, .{ .name = lower, .value = try self.arena.dupe(u8, value) });
    }
} else void;

/// What a failed read of an HTTP/2 response body was, in the transport's
/// terms: a reset stream or a lost connection is the peer resetting it.
fn h2BodyError(reader: *std.Io.Reader) ?Transport.ReadError {
    if (comptime !has_h2_client) unreachable;
    const err = h2_client.Stream.ofReader(reader).readError() orelse return null;
    return switch (err) {
        error.Canceled => error.Canceled,
        error.Timeout => error.ConnectionTimedOut,
        else => error.ConnectionResetByPeer,
    };
}

/// Returns true if sub is the same domain as parent, or a subdomain of it.
/// Used to decide whether to forward sensitive headers on redirect.
/// Matches Go's net/http shouldCopyHeaderOnRedirect logic.
fn isDomainOrSubdomain(sub: []const u8, parent: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(sub, parent)) return true;
    // Don't treat IPv6 addresses (including zone IDs like "::1%25.evil.com") as subdomains.
    if (std.mem.indexOfAny(u8, sub, ":%") != null) return false;
    // sub must end with ".<parent>".
    if (sub.len <= parent.len + 1) return false;
    const dot_idx = sub.len - parent.len - 1;
    return sub[dot_idx] == '.' and std.ascii.eqlIgnoreCase(sub[dot_idx + 1 ..], parent);
}

/// The statuses a Location is followed for. The rest of 3xx are not
/// redirects: a 304 answers a conditional request, a 300 offers choices.
fn isRedirect(status: http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => true,
        else => false,
    };
}

/// How many interim responses may precede the final one. Go's limit, and
/// what keeps an endless stream of them from keeping a request open forever.
const max_interim_responses = 5;

/// 1xx, less 101: that one ends the HTTP exchange rather than preceding
/// the response to it.
fn isInterim(status: http.Status) bool {
    const code = @backingInt(status);
    return code >= 100 and code < 200 and status != .switching_protocols;
}

/// Parse HTTP response headers from a reader. Interim responses are read
/// and dropped on the way, so what is parsed on return is the final one.
fn parseResponseHeaders(reader: *std.Io.Reader, parser: *ResponseParser) !void {
    var parsed_len: usize = 0;
    var interim: usize = 0;
    while (true) {
        while (!parser.state.headers_complete) {
            const buffered = reader.buffered();
            const unparsed = buffered[parsed_len..];
            if (unparsed.len > 0) {
                parser.feed(unparsed) catch |err| switch (err) {
                    error.Paused => {
                        const consumed = parser.getConsumedBytes(unparsed.ptr);
                        parsed_len += consumed;
                        continue;
                    },
                    else => return err,
                };
                parsed_len += unparsed.len;
                continue;
            }
            // Same ceiling as the server's `parseHeaders`, and for the same
            // reason: the head is held whole, so a buffer with no room left is a
            // head that will never complete.
            if (reader.buffer.len - reader.end < body_read_reserve) return error.HeadersTooLarge;
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (parsed_len == 0) return error.EndOfStream;
                    return error.IncompleteResponse;
                },
                else => |e| return e,
            };
        }
        if (!isInterim(parser.response.status)) break;

        if (interim == max_interim_responses) return error.TooManyInterimResponses;
        interim += 1;

        // The interim head is thrown away, and so is the room it took: the
        // final head gets the whole buffer. Moved by hand because a fixed
        // reader refuses to rebase.
        reader.toss(parsed_len);
        parsed_len = 0;
        const rest = reader.buffered();
        @memmove(reader.buffer[0..rest.len], rest);
        reader.seek = 0;
        reader.end = rest.len;
        try parser.restart();
    }
    // And, as there, a fill may use every byte it was given room for, so the
    // head can finish inside the reserve without the check above ever
    // firing. The body reader gets what is left, and cannot read into
    // nothing.
    if (reader.buffer.len - parsed_len < body_read_reserve) return error.HeadersTooLarge;

    reader.toss(parsed_len);
    parser.resumeParsing();

    // Shorten buffer so body reading doesn't overwrite header data.
    // Headers remain valid in buffer[0..headers_len], body uses the rest.
    std.debug.assert(reader.seek == parsed_len);
    const headers_len = reader.seek;
    reader.buffer = reader.buffer[headers_len..];
    reader.end -= headers_len;
    reader.seek = 0;

    // Feed empty buffer to advance state machine for bodyless responses
    parser.feed(&.{}) catch |err| switch (err) {
        error.Paused => {},
        else => return err,
    };
}

// Tests

/// A reader over `raw` with `body_read_reserve` bytes of slack past it, the
/// way a connection's read buffer has slack past the head it just parsed.
/// `Reader.fixed` alone leaves none, and a head with nothing behind it is
/// rejected -- the body reader would have nowhere to read into.
fn fixedMessageReader(gpa: std.mem.Allocator, raw: []const u8) !std.Io.Reader {
    const backing = try gpa.alloc(u8, raw.len + body_read_reserve);
    @memcpy(backing[0..raw.len], raw);
    var r: std.Io.Reader = .fixed(backing);
    r.end = raw.len;
    return r;
}

test "unbracketed: takes the brackets off an IPv6 literal and nothing else" {
    try std.testing.expectEqualStrings("::1", unbracketed("[::1]"));
    try std.testing.expectEqualStrings("127.0.0.1", unbracketed("127.0.0.1"));
    try std.testing.expectEqualStrings("example.com", unbracketed("example.com"));
    try std.testing.expectEqualStrings("[", unbracketed("["));
}

test "parseUrl: IPv6 literal keeps its brackets" {
    const uri = try parseUrl("http://[::1]:8080/path");
    var host_buf: [255]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("[::1]", host);
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(8080, info.port);
}

test "uriHost: decodes escaped host and rejects a missing or oversized host" {
    var host_buf: [255]u8 = undefined;
    try std.testing.expectEqualStrings("example.com", try uriHost(try parseUrl("http://exam%70le.com/"), &host_buf));
    try std.testing.expectError(error.InvalidUrl, uriHost(try parseUrl("http:/path"), &host_buf));
    try std.testing.expectError(error.InvalidUrl, parseUrl("http://"));
    // Zig 0.17's Uri.parse already refuses a host this long; on 0.16 it is
    // uriHost that runs out of room for it.
    const long_host = "http://" ++ @as([256]u8, @splat('a'));
    if (parseUrl(long_host)) |uri| {
        try std.testing.expectError(error.InvalidUrl, uriHost(uri, &host_buf));
    } else |err| {
        try std.testing.expectEqual(error.InvalidUrl, err);
    }
}

test "parseUrl: basic URL" {
    const uri = try parseUrl("http://example.com/path");
    var host_buf: [255]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(80, info.port);
    try std.testing.expectEqual(Protocol.http, info.protocol);
    try std.testing.expectEqualStrings("/path", uriPath(uri));
}

test "parseUrl: URL with port" {
    const uri = try parseUrl("http://example.com:8080/path");
    var host_buf: [255]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(8080, info.port);
    try std.testing.expectEqual(Protocol.http, info.protocol);
    try std.testing.expectEqualStrings("/path", uriPath(uri));
}

test "parseUrl: URL without path" {
    const uri = try parseUrl("http://example.com");
    var host_buf: [255]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(80, info.port);
    try std.testing.expectEqual(Protocol.http, info.protocol);
    try std.testing.expectEqualStrings("/", uriPath(uri));
}

test "parseUrl: URL without scheme is invalid" {
    try std.testing.expectError(error.InvalidUrl, parseUrl("example.com/path"));
}

test "parseUrl: HTTPS returns port 443" {
    const uri = try parseUrl("https://example.com/path");
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(443, info.port);
    try std.testing.expectEqual(Protocol.https, info.protocol);
}

test "parseUrl: unknown scheme returns UnsupportedScheme" {
    const uri = try parseUrl("ftp://example.com/path");
    try std.testing.expectError(error.UnsupportedScheme, uriPortAndProtocol(uri));
}

test "parseUrl: URL with query string" {
    const uri = try parseUrl("http://example.com/path?foo=bar&baz=qux");
    var host_buf: [255]u8 = undefined;
    const host = try uriHost(uri, &host_buf);
    try std.testing.expectEqualStrings("example.com", host);
    try std.testing.expectEqualStrings("/path", uriPath(uri));
    try std.testing.expectEqualStrings("foo=bar&baz=qux", uri.query.?.percent_encoded);
}

test "Uri.resolveInPlace: relative path" {
    const base = try parseUrl("http://example.com/foo/bar");

    // Test absolute path redirect
    {
        var buf: [256]u8 = undefined;
        const location = "/new/path";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("example.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/new/path", resolved.path.percent_encoded);
    }

    // Test relative path redirect
    {
        var buf: [256]u8 = undefined;
        const location = "other";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("example.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/foo/other", resolved.path.percent_encoded);
    }

    // Test absolute URL redirect
    {
        var buf: [256]u8 = undefined;
        const location = "http://other.com/different";
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf[0..];
        const resolved = try Uri.resolveInPlace(base, location.len, &aux);
        try std.testing.expectEqualStrings("http", resolved.scheme);
        try std.testing.expectEqualStrings("other.com", resolved.host.?.percent_encoded);
        try std.testing.expectEqualStrings("/different", resolved.path.percent_encoded);
    }
}

test "ClientResponse.body: basic response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "ClientResponse.body: a corrupt gzip body reports the decompression failure" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++ ("not a gzip stream at all" ++ "12345678");
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    // The bytes arrived intact; it is the layer above the body reader that
    // could not make sense of them, so that is where the answer is.
    try std.testing.expectError(error.CorruptInput, response.body());
}

test "ClientResponse: a streaming read can be resolved without going through body" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 32\r\n\r\n" ++
        ("not a gzip stream at all" ++ "12345678");
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    // Streaming the body rather than calling `body`, which is the case with
    // no other way to find out what happened.
    var read_buf: [64]u8 = undefined;
    var r = try response.reader(&read_buf);
    var sink_buf: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buf);
    try std.testing.expectError(error.ReadFailed, r.interface.stream(&sink, .limited(64)));

    // Asked of the reader that was handed out, which is the point: a caller
    // holding it needs nothing else to find out what a failed read was.
    try std.testing.expectEqual(error.CorruptInput, r.err.?);
}

test "ClientResponse.body: a body read that failed before it started can be asked for again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    // Nothing was read, so nothing was taken -- the server picked the
    // encoding, and asking twice must not trip the one-reader assert.
    try std.testing.expectError(error.UnsupportedContentEncoding, response.body());
    try std.testing.expectError(error.UnsupportedContentEncoding, response.body());
}

test "ClientResponse: neither it nor its reader carries a buffer or a decoder" {
    // `fetch` returns a `ClientResponse` by value and `reader` returns the
    // body reader by value, so both are copied per response whether or not
    // anything was coded. The read buffer comes from the caller, and the
    // decoder is allocated when the headers call for it -- so neither of
    // these grows with either.
    try std.testing.expect(@sizeOf(ClientResponse) < @sizeOf(ResponseBodyReader.Decode));
    try std.testing.expect(@sizeOf(ResponseBodyReader) < @sizeOf(ResponseBodyReader.Decode));
}

test "Client: no std.Io sentinel escapes its public API" {
    // Listing the names of these error sets takes more than the default
    // quota on Zig 0.16.
    @setEvalBranchQuota(10_000);
    // `ReadFailed`/`WriteFailed` say only that a read or write failed, which
    // the caller knew when it called. The client stacks more layers than the
    // server does -- socket, TLS, request and response framing,
    // decompression -- and any of them could drop its answer on the way up.
    const ErrorSetOf = struct {
        fn f(comptime func: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(func)).@"fn".return_type.?).error_union.error_set;
        }
    }.f;
    inline for (.{
        ErrorSetOf(ClientResponse.body),
        ErrorSetOf(Client.fetch),
        ErrorSetOf(Client.connectWebSocket),
        ErrorSetOf(WebSocketClient.send),
        ErrorSetOf(WebSocketClient.receive),
        ErrorSetOf(WebSocketClient.receiveMany),
        ErrorSetOf(WebSocketClient.tryReceive),
        // The wrapper a streaming caller resolves through, not just the
        // functions that resolve for them.
        ClientResponse.ReadError,
        ResponseBodyReader.Error,
    }) |Set| {
        inline for (comptime std.meta.fieldNames(Set)) |e_name| {
            try std.testing.expect(!std.mem.eql(u8, e_name, "ReadFailed"));
            try std.testing.expect(!std.mem.eql(u8, e_name, "WriteFailed"));
        }
    }

    // Not a sentinel, but not a cause either: reading a body, a stream that
    // stopped early is `IncompleteBody`, and `EndOfStream` here would be
    // read as the peer having hung up. `fetch` is excluded because a
    // connection-close-delimited response can end that way for real.
    inline for (.{ ClientResponse.ReadError, ResponseBodyReader.Error }) |Set| {
        inline for (comptime std.meta.fieldNames(Set)) |e_name| {
            try std.testing.expect(!std.mem.eql(u8, e_name, "EndOfStream"));
        }
    }
}

test "ClientResponse.body: large body over 128 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body_content = &@as([256]u8, @splat('A'));
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 256\r\n\r\n" ++ body_content;
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqual(256, body.?.len);
    try std.testing.expectEqualStrings(body_content, body.?);
}

test "ClientResponse.body: no body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqual(null, body);
    try std.testing.expectEqual(.no_content, response.status());
}

test "parseResponseHeaders: interim responses are dropped on the way to the final one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 100 Continue\r\n\r\n" ++
        "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    try std.testing.expectEqual(.ok, response.status());
    // Nothing of the interim heads survives.
    try std.testing.expectEqual(null, response.headers().get("Link"));
    try std.testing.expectEqualStrings("hello", (try response.body()).?);
}

test "parseResponseHeaders: an endless run of interim responses is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = repeat("HTTP/1.1 100 Continue\r\n\r\n", max_interim_responses + 1) ++
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try std.testing.expectError(error.TooManyInterimResponses, parseResponseHeaders(&reader, &parser));
}

test "ClientResponse.body: chunked trailers are not headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n0\r\nX-Trailer: value\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    try std.testing.expectEqualStrings("hello", (try response.body()).?);
    try std.testing.expectEqual(null, response.headers().get("X-Trailer"));
}

test "ClientResponse.body: a body cut short is IncompleteBody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Five bytes promised, two sent.
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhe";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    try std.testing.expectError(error.IncompleteBody, response.body());
}

test "ClientResponse.body: connection-close (EOF-delimited) body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // No Content-Length and no Transfer-Encoding: body is delimited by EOF.
    const body_content = "body delimited by connection close, not length.";
    const raw_response = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nconnection: close\r\n\r\n" ++ body_content;
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    const body = try response.body();
    try std.testing.expectEqualStrings(body_content, body.?);
    try std.testing.expectEqual(.forbidden, response.status());
}

test "ClientResponse.reader: streaming read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    var read_buf: [64]u8 = undefined;
    var body_reader = try response.reader(&read_buf);

    // Read in chunks
    var buf: [5]u8 = undefined;
    var n = try body_reader.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);

    n = try body_reader.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings(" worl", buf[0..n]);

    n = try body_reader.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings("d", buf[0..n]);
}

test "ClientResponse.reader: after body() returns cached data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    // First read body fully
    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);

    // Now reader should return cached body
    var read_buf: [64]u8 = undefined;
    var body_reader = try response.reader(&read_buf);
    const cached = try body_reader.interface.allocRemaining(arena.allocator(), .unlimited);
    try std.testing.expectEqualStrings("hello", cached);
}

test "ClientResponse.body: gzip decompression" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello" gzip compressed
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
        .decompress = true,
    };

    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);
}

test "ClientResponse: decoding takes the headers that described the encoded body" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    try std.testing.expectEqualStrings("gzip", response.headers().get("Content-Encoding").?);

    const body = try response.body();
    try std.testing.expectEqualStrings("hello", body.?);

    // A proxy forwarding these would send five plain bytes labelled as
    // twenty-five gzipped ones.
    try std.testing.expectEqual(@as(?[]const u8, null), response.headers().get("Content-Encoding"));
    try std.testing.expectEqual(@as(?[]const u8, null), response.headers().get("Content-Length"));

    // What arrived is still answerable, just not as a header.
    try std.testing.expectEqual(ContentEncoding.gzip, response.contentEncoding());
    try std.testing.expectEqual(@as(?usize, 25), response.contentLength());
}

test "ClientResponse.body: gzip decompression disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // "hello" gzip compressed
    const gzip_hello = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00";
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 25\r\n\r\n" ++ gzip_hello;
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
        .decompress = false,
    };

    // With decompress disabled, we should get the raw gzip bytes
    const body = try response.body();
    try std.testing.expectEqual(25, body.?.len);
    try std.testing.expectEqualStrings(gzip_hello, body.?);
}

test "ClientResponse.body: an empty body with a Content-Encoding is not decoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Not a gzip stream, not even an empty one; a decoder would call it cut short.
    const raw_response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n";
    var reader = try fixedMessageReader(arena.allocator(), raw_response);

    var parsed: ParsedResponse = .{ .arena = arena.allocator() };
    var parser: ResponseParser = undefined;
    try parser.init(&parsed, 64);

    try parseResponseHeaders(&reader, &parser);

    var response = ClientResponse{
        .arena = arena.allocator(),
        .parser = &parser,
        .transport = .{ .reader = &reader, .writer = undefined },
        .parsed = &parsed,
        .max_response_size = 1024,
    };

    try std.testing.expectEqual(null, try response.body());
    try std.testing.expectEqualStrings("gzip", response.headers().get("Content-Encoding").?);
}

test "Protocol.fromScheme: http" {
    const proto = try Protocol.fromScheme("http");
    try std.testing.expectEqual(Protocol.http, proto);
}

test "Protocol.fromScheme: https" {
    const proto = try Protocol.fromScheme("https");
    try std.testing.expectEqual(Protocol.https, proto);
}

test "Protocol.fromScheme: unsupported scheme" {
    try std.testing.expectError(error.UnsupportedScheme, Protocol.fromScheme("ftp"));
}

test "Protocol.defaultPort: http" {
    try std.testing.expectEqual(80, Protocol.http.defaultPort());
}

test "Protocol.defaultPort: https" {
    try std.testing.expectEqual(443, Protocol.https.defaultPort());
}

test "uriPortAndProtocol: https default" {
    const uri = try parseUrl("https://example.com/path");
    const info = try uriPortAndProtocol(uri);
    try std.testing.expectEqual(443, info.port);
    try std.testing.expectEqual(Protocol.https, info.protocol);
}

test "isDomainOrSubdomain: exact match" {
    try std.testing.expect(isDomainOrSubdomain("example.com", "example.com"));
    try std.testing.expect(isDomainOrSubdomain("EXAMPLE.COM", "example.com"));
}

test "isDomainOrSubdomain: subdomain" {
    try std.testing.expect(isDomainOrSubdomain("sub.example.com", "example.com"));
    try std.testing.expect(isDomainOrSubdomain("a.b.example.com", "example.com"));
}

test "isDomainOrSubdomain: different domain" {
    try std.testing.expect(!isDomainOrSubdomain("other.com", "example.com"));
    try std.testing.expect(!isDomainOrSubdomain("notexample.com", "example.com"));
    try std.testing.expect(!isDomainOrSubdomain("example.com.evil.com", "example.com"));
}

test "isDomainOrSubdomain: IPv6 never a subdomain" {
    try std.testing.expect(!isDomainOrSubdomain("::1", "example.com"));
    try std.testing.expect(!isDomainOrSubdomain("[::1]", "example.com"));
}

test "isDomainOrSubdomain: IPv6 zone ID never a subdomain" {
    try std.testing.expect(!isDomainOrSubdomain("::1%25.example.com", "example.com"));
    try std.testing.expect(!isDomainOrSubdomain("fe80::1%eth0.example.com", "example.com"));
}

test "writeRequest: sends default User-Agent" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const uri = try parseUrl("http://example.com/");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .user_agent = default_user_agent,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "User-Agent: " ++ default_user_agent ++ "\r\n") != null);
}

test "writeRequest: omits User-Agent when null" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const uri = try parseUrl("http://example.com/");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .user_agent = null,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "User-Agent:") == null);
}

test "writeRequest: user-provided User-Agent overrides default" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("User-Agent", "my-app/2.0");

    const uri = try parseUrl("http://example.com/");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .user_agent = default_user_agent,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "User-Agent: my-app/2.0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, default_user_agent) == null);
}

test "writeRequest: sets Referer on redirect" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const uri = try parseUrl("http://example.com/new");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .referer = "http://example.com/old",
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Referer: http://example.com/old\r\n") != null);
}

test "writeRequest: does not override user-provided Referer" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Referer", "http://custom.example.com/");

    const uri = try parseUrl("http://example.com/new");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .referer = "http://example.com/old",
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Referer: http://custom.example.com/\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "http://example.com/old") == null);
}

test "writeRequest: refuses a path or query with bytes a request target cannot hold" {
    const bad = [_][]const u8{
        "http://example.com/a\r\nX-Injected: 1",
        "http://example.com/search?q=a\r\n\r\nGET /admin HTTP/1.1",
        "http://example.com/a b",
        "http://example.com/?q=a b",
        "http://example.com/\x00",
        "http://example.com/\x7f",
        "http://example.com/caf\xc3\xa9",
    };
    for (bad) |url| {
        // Refused when parsed, or else when written.
        const uri = parseUrl(url) catch |err| {
            try std.testing.expectEqual(error.InvalidUrl, err);
            continue;
        };
        var buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try std.testing.expectError(error.InvalidUrl, writeRequest(&writer, .{
            .method = .get,
            .uri = uri,
            .host = "example.com",
            .port = 80,
            .protocol = .http,
        }));
    }
    // Percent-encoded, the same bytes are fine.
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeRequest(&writer, .{
        .method = .get,
        .uri = try parseUrl("http://example.com/caf%C3%A9?q=a%0D%0Ab+c"),
        .host = "example.com",
        .port = 80,
        .protocol = .http,
    });
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "GET /caf%C3%A9?q=a%0D%0Ab+c HTTP/1.1\r\n"));
}

test "writeUpgradeRequest: refuses a path or query with bytes a request target cannot hold" {
    const uri: Uri = .{ .scheme = "ws", .host = .{ .percent_encoded = "example.com" }, .path = .{ .percent_encoded = "/chat" }, .query = .{ .percent_encoded = "room=1\r\nX: y" } };
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(error.InvalidUrl, writeUpgradeRequest(&writer, .{
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .key = "dGhlIHNhbXBsZSBub25jZQ==",
        .headers = null,
    }));
}

test "redirect: Referer strips userinfo and fragment" {
    // Verify that writeToStream with authentication=false, fragment=false
    // produces a clean Referer without credentials or fragment.
    var referer_buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&referer_buf);
    const uri = try parseUrl("http://user:pass@example.com/path?q=1#section");
    try uri.writeToStream(&w, .{
        .scheme = true,
        .authority = true,
        .authentication = false,
        .path = true,
        .query = true,
        .fragment = false,
        .port = true,
    });
    const referer = w.buffered();
    try std.testing.expectEqualStrings("http://example.com/path?q=1", referer);
}

test "writeRequest: strips sensitive headers on cross-origin redirect" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Authorization", "Bearer secret");
    try headers.put("Cookie", "session=abc");
    try headers.put("X-Custom", "keep-me");

    const uri = try parseUrl("http://other.com/path");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "other.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .strip_sensitive_headers = true,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Cookie") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: keep-me") != null);
}

test "redirect: strips sensitive headers on https to http downgrade" {
    // Verify the stripping condition fires on scheme downgrade even when host is identical.
    // We exercise the flag directly since the full redirect loop requires a live server.
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Authorization", "Bearer secret");
    try headers.put("X-Custom", "keep-me");

    const uri = try parseUrl("http://example.com/path");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .strip_sensitive_headers = true,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: keep-me") != null);
}

test "redirect: once stripping triggered it persists across hops" {
    // strip_sensitive_headers=true should propagate even if a later hop passes the host check.
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Authorization", "Bearer secret");
    try headers.put("X-Custom", "keep-me");

    // Simulate a hop that is back on the original host but already has strip=true.
    const uri = try parseUrl("http://example.com/new-path");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .strip_sensitive_headers = true,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: keep-me") != null);
}

test "writeRequest: a bodyless POST says Content-Length: 0, a GET says nothing" {
    const uri = try parseUrl("http://example.com/path");
    inline for (.{ .post, .put, .patch }) |method| {
        var buf: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writeRequest(&writer, .{
            .method = method,
            .uri = uri,
            .host = "example.com",
            .port = 80,
            .protocol = .http,
        });
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Content-Length: 0\r\n") != null);
    }
    inline for (.{ .get, .head, .delete, .options }) |method| {
        var buf: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writeRequest(&writer, .{
            .method = method,
            .uri = uri,
            .host = "example.com",
            .port = 80,
            .protocol = .http,
        });
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Content-Length") == null);
    }
}

test "writeRequest: strips body headers when body removed" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    var headers = try Headers.init(std.testing.allocator, 4);
    defer headers.deinit(std.testing.allocator);
    try headers.put("Content-Type", "application/json");
    try headers.put("Content-Language", "en");
    try headers.put("X-Custom", "keep-me");

    const uri = try parseUrl("http://example.com/path");
    try writeRequest(&writer, .{
        .method = .get,
        .uri = uri,
        .host = "example.com",
        .port = 80,
        .protocol = .http,
        .headers = &headers,
        .strip_body_headers = true,
    });

    const written = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Type") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "Content-Language") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "X-Custom: keep-me") != null);
}

test "Connection.release: the Keep-Alive timeout is in seconds" {
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var peer_future = try io.concurrent(struct {
        fn run(l: *std.Io.net.Server, _io: std.Io) void {
            const s = l.accept(_io) catch return;
            defer s.close(_io);
            var rbuf: [4096]u8 = undefined;
            var rd = s.reader(_io, &rbuf);
            var wbuf: [256]u8 = undefined;
            var w = s.writer(_io, &wbuf);
            rd.interface.fillMore() catch return;
            w.interface.writeAll("HTTP/1.1 200 OK\r\nKeep-Alive: timeout=5, max=100\r\nContent-Length: 0\r\n\r\n") catch return;
            w.interface.flush() catch return;
            rd.interface.fillMore() catch {};
        }
    }.run, .{ &listener, io });
    defer peer_future.cancel(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});
    var client = Client.init(std.testing.allocator, io, .{});
    defer client.deinit();

    {
        var resp = try client.fetch(url, .{});
        defer resp.deinit();
        _ = try resp.body();
    }

    try std.testing.expectEqual(1, client.pool().idle_len);
    const conn: *Connection = @alignCast(@fieldParentPtr("pool_node", client.pool().idle.first.?));
    const now = std.Io.Timestamp.now(io, .awake);
    const left = conn.idle_deadline.?.nanoseconds - now.nanoseconds;
    // Five seconds, less however long the release took to get here.
    try std.testing.expect(left > 4 * std.time.ns_per_s);
    try std.testing.expect(left <= 5 * std.time.ns_per_s);
    peer_future.cancel(io);
}

/// `s` repeated `n` times, for test fixtures. Zig 0.17 removed `**`.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    return comptime blk: {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk &final;
    };
}
