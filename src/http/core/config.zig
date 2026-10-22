// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const ContentType = @import("http.zig").ContentType;
const HttpRequest = @import("request.zig").Request;
const HttpResponse = @import("response.zig").Response;
const proxy_protocol = @import("proxy_protocol.zig");

/// How the server's own error answers (a 404, a 500, `Response.fail`) are
/// written. `ServerConfig.errors`.
pub const ErrorFormat = enum {
    /// `{"error":"..."}` for a request that says it takes JSON (an
    /// `Accept` naming JSON, or a JSON body), plain text otherwise.
    auto,
    /// Always `{"error":"..."}`: an API server.
    json,
    /// Always plain text.
    text,
};

/// Answers a request whose handler or middleware failed with `err`, in
/// place of the default mapping (`ServerConfig.error_handler`). It can
/// fall back to that mapping with `defaultError(req, res, err)`.
pub const ErrorHandler = *const fn (req: *HttpRequest, res: *HttpResponse, err: anyerror) void;

/// Where a TLS peer's certificate authorities are loaded from. Shared by the
/// client (verifying server certificates) and the server (verifying client
/// certificates under mutual TLS).
pub const TlsCa = union(enum) {
    /// The platform trust store.
    system,
    /// A single PEM file holding one or more certificates.
    file: TlsPath,
    /// A directory of PEM files, each holding one or more certificates.
    dir: TlsPath,
    /// One or more PEM certificates in memory: a CA that comes from a secret
    /// store or the environment, or a development certificate made at
    /// startup. Read when the trust store is loaded (a client's first HTTPS
    /// request, a listener's start); it must stay alive until then.
    pem: []const u8,
    /// Trust nothing. Rejected unless the side using it says otherwise.
    none,

    /// Reads the certificates into a fresh bundle owned by the caller.
    pub fn load(self: TlsCa, allocator: std.mem.Allocator, io: std.Io) !std.crypto.Certificate.Bundle {
        const now = std.Io.Clock.real.now(io);

        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(allocator);
        switch (self) {
            .system => try bundle.rescan(allocator, io, now),
            .file => |src| try bundle.addCertsFromFilePath(
                allocator,
                io,
                now,
                src.dir orelse std.Io.Dir.cwd(),
                src.path,
            ),
            .dir => |src| try bundle.addCertsFromDirPath(
                allocator,
                io,
                src.dir orelse std.Io.Dir.cwd(),
                src.path,
            ),
            .pem => |text| try addCertsFromPem(&bundle, allocator, text, now.toSeconds()),
            .none => {},
        }
        return bundle;
    }
};

/// `std.crypto.Certificate.Bundle.addCertsFromFile` for PEM text in memory:
/// every `BEGIN CERTIFICATE` block, decoded and parsed; expired ones are
/// skipped, as there.
pub fn addCertsFromPem(
    bundle: *std.crypto.Certificate.Bundle,
    allocator: std.mem.Allocator,
    pem: []const u8,
    now_sec: i64,
) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin| {
        const cert_start = begin + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end_marker.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start = std.math.cast(u32, bundle.bytes.items.len) orelse
            return error.CertificateAuthorityBundleTooBig;
        try bundle.bytes.ensureUnusedCapacity(allocator, base64.calcSizeUpperBound(encoded.len));
        bundle.bytes.items.len += try base64.decode(bundle.bytes.unusedCapacitySlice(), encoded);
        try bundle.parseCert(allocator, decoded_start, now_sec);
    }
}

/// Kept free past the head in a request's read buffer, which is sized
/// `buffer_size + body_read_reserve`. `parseHeaders` gives the body reader
/// whatever the head did not use, and a body reader with no buffer cannot
/// read; refusing a head that would eat into this is what makes it a reserve
/// rather than a hope.
pub const body_read_reserve = 1024;

/// A file named by path, optionally relative to an open directory.
pub const TlsPath = struct {
    path: []const u8,
    /// Directory `path` is resolved against. Defaults to the current working
    /// directory.
    dir: ?std.Io.Dir = null,
};

/// Where a listener binds, or a server's bound address: an IP address
/// and port, or a Unix socket path.
pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: std.Io.net.UnixAddress,

    pub fn format(self: Address, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .ip => |ip| try ip.format(w),
            .unix => |unix| try w.writeAll(unix.path),
        }
    }
};

/// One socket a server accepts on. `ServerConfig.listeners` holds any number,
/// each with its own TLS, so one server can serve HTTPS on 443 and plain
/// HTTP on 80.
pub const Listener = struct {
    address: Address,
    /// When set, every connection accepted here is TLS. Requires the
    /// `use_tls` build option (enabled by default); with TLS compiled out,
    /// setting this fails `Server.run`.
    tls: ?ServerConfig.Tls = null,
    /// How many connections the kernel accepts on the server's behalf
    /// while it is not accepting itself. Past this, Linux drops the
    /// client's SYN, and the client waits a second or more before it
    /// tries again.
    ///
    /// Null asks for the most the system allows: `net.core.somaxconn` on
    /// Linux, read from /proc/sys/net/core/somaxconn, and the platform's
    /// `SOMAXCONN` elsewhere, as Go does. The kernel caps a larger value
    /// to that silently.
    kernel_backlog: ?u31 = null,
    /// Sets SO_REUSEADDR (and SO_REUSEPORT on POSIX) on an IP listener.
    /// Ignored on Windows, where SO_REUSEADDR would let another socket
    /// bind the same port.
    reuse_address: bool = true,
    /// IPV6_V6ONLY for a listener on an IPv6 address. False takes IPv4
    /// clients too on the same socket (`::` then serves both families):
    /// they arrive as IPv4-mapped addresses (`::ffff:127.0.0.1`), which
    /// requests report as plain IPv4. True takes IPv6 alone. Null leaves
    /// the system's default (IPv6 alone on macOS and Windows; on Linux,
    /// `net.ipv6.bindv6only`, normally both). Ignored for IPv4 addresses,
    /// and for an inherited socket (`fd`), which is bound already.
    ipv6_only: ?bool = null,
    /// Serve cleartext HTTP/2 to a client that opens with the HTTP/2
    /// connection preface ("prior knowledge", RFC 9113 §3.3), alongside
    /// HTTP/1.x on the same port. Needs the `use_http2` build option, and
    /// is ignored on a TLS listener, which negotiates "h2" through
    /// `Tls.alpn_protocols` instead. The deprecated `Upgrade: h2c` is not
    /// supported.
    http2_prior_knowledge: bool = false,
    /// Serve HTTP/1.x here. Off, the listener speaks HTTP/2 alone: on a
    /// cleartext listener (with `http2_prior_knowledge`) a connection that
    /// does not open with the HTTP/2 preface is closed, and on a TLS one a
    /// connection whose ALPN did not agree on "h2" is closed after the
    /// handshake (leave "http/1.1" out of `Tls.alpn_protocols` too).
    http1: bool = true,
    /// What the application calls this listener ("admin", "public"), for
    /// handlers and middleware that tell listeners apart through
    /// `Request.listener`. Not used by the server itself.
    name: []const u8 = "",
    /// Every connection here starts with a PROXY protocol header, v1 or v2
    /// (HAProxy, nginx `proxy_protocol on`, AWS NLB, Envoy), read before
    /// TLS: the client address it carries becomes `Request.remote_address`,
    /// and v2's SSL TLV marks the request secure. A connection without a
    /// valid header is closed. The header must arrive within
    /// `Timeout.read_header`.
    ///
    /// Only for a listener that nothing but the proxy can reach, since
    /// whoever connects chooses the address the header claims; or name
    /// the proxies in `proxy_protocol_from`.
    proxy_protocol: bool = false,
    /// With `proxy_protocol`: the peers allowed to connect and send the
    /// header (`proxy_protocol.Network.parse("10.0.0.0/8")`). A connection
    /// from anywhere else is closed before anything is read. Empty trusts
    /// every peer. Ignored on a unix socket listener.
    proxy_protocol_from: []const proxy_protocol.Network = &.{},
    /// An already listening socket to serve instead of binding `address`:
    /// one handed over by systemd socket activation (`LISTEN_FDS`) or by
    /// the process this one replaces. `address` should still say what it
    /// is bound to (it is read back from the socket where it can be).
    fd: ?std.posix.fd_t = null,
    /// How many accept loops share the socket. With io_uring, an accept
    /// completes at most once per trip through the event loop, so a single
    /// loop takes one connection per trip however many are queued, which
    /// limits a server taking many short connections. Several accepts
    /// waiting together let one trip take several. An idle one costs a
    /// parked task, and on Windows a socket created ahead for the
    /// connection it will get. Zero is taken as one.
    ///
    /// Null picks log2 of the CPUs the process may use, honoring a cgroup
    /// CPU quota, and at least two: 2 on 4 CPUs, 5 on 48, 7 on 128. Past
    /// that, more loops on one socket stop paying for themselves, and on
    /// short connections start to cost.
    acceptors: ?u16 = null,
    /// Gives each accept loop a socket of its own instead of sharing one,
    /// all bound to the same address with SO_REUSEPORT, so the kernel
    /// spreads connections over as many accept queues as there are loops.
    /// That scales further than a shared queue when nearly every request
    /// comes on a new connection. The kernel picks a socket by hashing the
    /// connection, not by which loop is free, so a busy loop keeps getting
    /// its share and tail latency is worse under load; and a connection
    /// still queued on a socket when it closes is reset rather than handed
    /// to another. Linux only, and needs an IP address with
    /// `reuse_address` set.
    socket_per_acceptor: bool = false,
    /// Protocols served on this address by something other than this
    /// server, such as HTTP/3 on the UDP port of the same number, named
    /// after its own in the line logged when it starts listening.
    extra_protocols: []const []const u8 = &.{},

    /// The number of accept loops, with `cpu_count` standing in for the
    /// CPUs the process may use when `acceptors` is null.
    pub fn acceptorCount(self: *const Listener, cpu_count: usize) u16 {
        if (self.acceptors) |n| return @max(1, n);
        return @intCast(@min(@max(2, std.math.log2_int(usize, @max(1, cpu_count))), std.math.maxInt(u16)));
    }

    /// `acceptorCount`, except that on a runtime with `executors` executors
    /// (zio, several of them) an unset `acceptors` means one accept loop per
    /// executor: each executor accepts its own connections and keeps them.
    pub fn acceptorCountFor(self: *const Listener, cpu_count: usize, executors: ?usize) u16 {
        if (self.acceptors == null) {
            if (executors) |n| if (n > 1) return @intCast(@min(n, std.math.maxInt(u16)));
        }
        return self.acceptorCount(cpu_count);
    }
};

/// Used when `ServerConfig.listeners` is empty.
pub const default_listeners = [_]Listener{.{
    .address = .{ .ip = .{ .ip4 = .loopback(8080) } },
}};

test "Listener.acceptorCount: log2 of the CPUs, at least two, unless given" {
    const auto: Listener = .{ .address = undefined };
    try std.testing.expectEqual(2, auto.acceptorCount(1));
    try std.testing.expectEqual(2, auto.acceptorCount(4));
    try std.testing.expectEqual(3, auto.acceptorCount(8));
    try std.testing.expectEqual(5, auto.acceptorCount(48));
    try std.testing.expectEqual(7, auto.acceptorCount(128));

    const given: Listener = .{ .address = undefined, .acceptors = 9 };
    try std.testing.expectEqual(9, given.acceptorCount(128));
    const zero: Listener = .{ .address = undefined, .acceptors = 0 };
    try std.testing.expectEqual(1, zero.acceptorCount(128));
}

/// The HTTP core's settings; through Anole, `anole.ServerOptions.server`
/// (whose `listeners`, `http2`, `errors` and `error_handler` Anole sets
/// from its own fields):
///
///     var app = try anole.App.init(gpa, .{ .server = .{
///         .timeout = .{ .request = .fromSeconds(60) },
///         .request = .{ .max_body_size = 8 * 1024 * 1024 },
///     } });
pub const ServerConfig = struct {
    /// Request, header, keep-alive and shutdown time limits.
    timeout: Timeout = .{},
    /// Limits on what a request may bring: body size, header and
    /// parameter counts, the head's buffer.
    request: Request = .{},
    /// How responses are written: buffer size, `Date`, the default
    /// content type, header count, Brotli quality.
    response: Response = .{},
    /// HTTP/2 connections (with the `use_http2` build option): reached
    /// through ALPN "h2" on a TLS listener or `Listener.http2_prior_knowledge`.
    http2: Http2 = .{},
    /// Where the server accepts connections. `Server.run` serves all of
    /// them. An empty list uses the default, 127.0.0.1:8080. Borrowed for
    /// the server's life, and requests point back into it through
    /// `Request.listener`.
    listeners: []const Listener = &default_listeners,
    /// Number of reverse-proxy hops between the server and the client. Zero
    /// reports the socket peer and ignores `X-Forwarded-For`. A positive
    /// value selects that address from the right of the forwarding chain:
    /// one trusts the directly connected proxy, two trusts it and the proxy
    /// before it, and so on.
    ///
    /// Only enable this when the server is unreachable except through that
    /// many trusted proxies. Otherwise a client can supply the header itself
    /// and choose the address reported to handlers.
    ///
    /// Only the selected entry is read; the ones left of it are the
    /// client's own. One that is not an address gives `remote_address`
    /// 0.0.0.0, never the proxy's address.
    trusted_proxy_hops: usize = 0,
    /// With `trusted_proxy_hops`: the last `X-Forwarded-Proto` value sets
    /// `Request.secure`. The nearest proxy must set (overwrite) the header
    /// on every request, as nginx does only with `proxy_set_header
    /// X-Forwarded-Proto $scheme`; otherwise the client's own value passes
    /// through.
    trust_forwarded_proto: bool = true,
    /// With `trusted_proxy_hops`: the last `X-Forwarded-Host` value is what
    /// `Request.host` returns. Off by default: a proxy that does not
    /// overwrite the header lets a client choose the host that links,
    /// redirects and cache keys are built from. Turn it on only when the
    /// nearest proxy sets the header on every request.
    trust_forwarded_host: bool = false,
    /// How many connections may be open at once. At the cap the server stops
    /// accepting; what arrives meanwhile waits in the kernel's accept queue,
    /// `Listener.kernel_backlog` deep. Null lifts the cap.
    ///
    /// The default, `max_connections_from_fd_limit`, is worked out when the
    /// server starts, from the process's open-file limit (the soft
    /// RLIMIT_NOFILE) less what is kept back for other descriptors (see
    /// `fd_limit.maxConnections`): past that limit `accept` fails anyway.
    /// 10,000 on Windows, which has no such limit.
    ///
    /// An idle connection costs a few kilobytes, about 9K under TLS on Linux
    /// once parked (`timeout.idle_park`; about 20K while it keeps its task),
    /// and
    /// `request.buffer_size + 12K` more while a request is being served, or
    /// for as long as it is open with `request.keep_buffers_between_requests`
    /// on, of which an ordinary request touches one page; and
    /// `response.write_buffer_size` more while its response is being
    /// written. A request with a body with a `Content-Encoding` takes 70K
    /// more while `request.decompress` is on.
    max_connections: ?u32 = max_connections_from_fd_limit,
    /// How the server's own error answers are written: a 404, a 405, the
    /// status an error maps to, `Response.fail`. See `ErrorFormat`.
    errors: ErrorFormat = .auto,
    /// Answers handler and middleware errors in place of the default
    /// mapping (status-named errors such as `error.Unauthorized` to their
    /// status, request-body faults to 4xx, the rest to 500), for an app
    /// without a context of its own. A context's `uncaughtError` comes
    /// first.
    error_handler: ?ErrorHandler = null,
    /// `max_connections`'s default: worked out from the open-file limit
    /// when the server starts.
    pub const max_connections_from_fd_limit: u32 = std.math.maxInt(u32);

    /// TLS is per listener: see `Listener.tls`.
    pub const Tls = struct {
        /// Path to the PEM certificate (chain) file, resolved against `dir`.
        /// Ignored when `pem` is set.
        cert_path: []const u8 = "",
        /// Path to the PEM private key file, resolved against `dir`.
        /// Ignored when `pem` is set.
        key_path: []const u8 = "",
        /// The certificate (chain) and private key as PEM text in memory,
        /// in place of `cert_path`/`key_path`: for keys that come from a
        /// secret store or the environment, or are generated at startup, and
        /// should never be written to disk. Read once by listen(); it does
        /// not need to outlive that.
        pem: ?Pem = null,
        /// Directory the cert/key paths are resolved against. Defaults to the
        /// current working directory.
        dir: ?std.Io.Dir = null,
        /// Ask connecting clients to authenticate with a certificate (mutual
        /// TLS). Null means client certificates are never requested.
        client_auth: ?ClientAuth = null,
        /// Protocols offered through ALPN, in server preference order, for
        /// example `&.{ "h2", "http/1.1" }`. Empty means no ALPN; a client
        /// whose offer shares nothing with a non-empty list is handled by the
        /// TLS module (tls.zig refuses it).
        alpn_protocols: []const []const u8 = &.{},

        /// A certificate chain and private key as PEM text.
        pub const Pem = struct {
            cert: []const u8,
            key: []const u8,
        };

        /// Mutual TLS: which CAs a client certificate must chain to, and
        /// whether one is required.
        pub const ClientAuth = struct {
            /// Certificate authorities used to verify client certificates.
            /// `.none` is rejected by listen().
            ca: TlsCa,
            /// `.require` rejects a client that sends no certificate;
            /// `.request` asks for one but accepts an empty reply.
            mode: Mode = .require,

            pub const Mode = enum { request, require };
        };
    };

    /// HTTP/2 limits and windows (`anole.ServerOptions.http2`).
    pub const Http2 = struct {
        /// SETTINGS_MAX_CONCURRENT_STREAMS: streams a client may have open
        /// at once. Each costs a task and, once it sends a body, a buffer
        /// of `stream_window` bytes.
        max_concurrent_streams: u32 = 100,
        /// SETTINGS_INITIAL_WINDOW_SIZE: request body bytes a client may
        /// send on a stream before the handler reads them, which is also
        /// the stream's body buffer.
        stream_window: u31 = 64 * 1024,
        /// The stream's window (and body buffer) from the handler's first
        /// read of the body: a handler that takes the body gets it at a
        /// pace the round trip does not throttle (64 KiB a round trip is
        /// 6.5 MB/s at 10 ms), while one that never reads holds only
        /// `stream_window`. No larger than `stream_window`: stays as is.
        stream_window_reading: u31 = 1024 * 1024,
        /// Request body bytes in flight across all streams of a
        /// connection. It holds no memory of its own (the streams' body
        /// buffers do), so it is generous: several uploads at once share
        /// the round trip rather than wait for each other.
        connection_window: u31 = 16 * 1024 * 1024,
        /// SETTINGS_MAX_HEADER_LIST_SIZE: the decoded size of a request's
        /// header block (names, values and 32 bytes each, RFC 9113 §6.5.2).
        max_header_list_size: u32 = 64 * 1024,
        /// RST_STREAM a client may send in a burst, refilled at
        /// `stream_reset_rate` per second, before the connection is closed
        /// (CVE-2023-44487, "rapid reset").
        stream_reset_burst: u64 = 1000,
        stream_reset_rate: u64 = 33,
        /// CONTINUATION frames allowed after one HEADERS (CVE-2024-28182).
        max_continuations: usize = 8,
        /// Streams the server may refuse before they reach a handler (a
        /// header list past `max_header_list_size`, or one nghttp2's checks
        /// reject) in a burst, refilled at `refused_stream_rate` per
        /// second, before the connection is closed with
        /// GOAWAY(ENHANCE_YOUR_CALM).
        refused_stream_burst: u64 = 100,
        refused_stream_rate: u64 = 10,
        /// Advertise SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 8441), so a
        /// client may open a WebSocket, or another protocol, on a stream
        /// with an extended CONNECT. Such a request reaches the router as a
        /// GET, as the HTTP/1.1 upgrade it replaces does, with
        /// `Request.protocol` set.
        enable_connect_protocol: bool = true,
        /// Requests for routes registered `no_wait` (`RouteOptions`) that
        /// arrive whole (their end, body included, in the read that brought
        /// their HEADERS) run on the
        /// connection's reader, right after the read that brought them,
        /// rather than on a task each: no task to start, switch to and
        /// tear down, and their responses go out in the read's one write.
        inline_no_wait: bool = true,
    };

    /// `ServerConfig.timeout`.
    pub const Timeout = struct {
        /// Maximum time to complete a request, including handler work and the
        /// response. TLS handshakes use the same timeout as a separate phase.
        /// Defaults to 30 seconds; set to null for long-lived handlers, or
        /// replace it from a handler with `Request.setTimeout`.
        ///
        /// HTTP/2 also bounds what follows the handler with it (or with
        /// `keepalive` when this is null): a response not all sent this
        /// long after its handler returned (a peer that gives no flow
        /// control window) is reset, and a single write the peer does not
        /// read for this long closes the connection.
        ///
        /// Costs a second task per connection on any backend but zio, so on
        /// `std.Io.Threaded` setting either timeout means two threads per
        /// connection.
        request: ?std.Io.Duration = .fromSeconds(30),
        /// Maximum time for a request's head to arrive, counted from the
        /// same point as `request` (accept for the first request, its first
        /// byte for later ones): a peer that trickles a request line and
        /// headers (Slowloris) is cut off sooner than the whole-request
        /// limit allows. Null leaves the head to `request`. HTTP/1.x only:
        /// an HTTP/2 stream reaches the server with its head complete.
        read_header: ?std.Io.Duration = .fromSeconds(10),
        /// Maximum time to keep idle connections open. Defaults to 60 seconds;
        /// set to null to keep them open indefinitely.
        keepalive: ?std.Io.Duration = .fromSeconds(60),
        /// Maximum number of requests per keepalive connection
        request_count: ?usize = null,
        /// How long an HTTP/1.1 connection waits for its next request on a
        /// task of its own before it parks: the task ends, and the
        /// connection waits as a small heap object until its socket is
        /// readable, when a new task is started on the same executor to
        /// serve it. A connection that sends again sooner keeps its task,
        /// so a busy one never pays for parking. One that was parked this
        /// long or longer parks again as soon as it has answered what woke
        /// it, so that waking many mostly idle connections at once needs
        /// tasks for about as many as are being served at a time. Only with something to
        /// park: nothing buffered, and on TLS nothing pending in either
        /// direction. A parked connection's `keepalive` (or first
        /// `request`) deadline is kept to about a second. Null or zero
        /// keeps idle connections on their task. Only on zio with pinned
        /// executors; elsewhere connections never park.
        idle_park: ?std.Io.Duration = .fromSeconds(1),
        /// Maximum time a graceful shutdown waits for the connections still
        /// in flight. Null waits for all of them, however long they take --
        /// which for a connection that never closes on its own, such as a
        /// WebSocket or an event stream, is forever.
        shutdown: ?std.Io.Duration = .fromSeconds(30),
    };

    /// `ServerConfig.request`.
    pub const Request = struct {
        /// Maximum size (bytes) for request body. Applies to the body a
        /// handler sees, so for a compressed request it bounds what was
        /// decoded rather than what arrived.
        ///
        /// Which is the limit worth enforcing, but note what it costs: a
        /// request can grow its arena by this much, the pooled arena keeps
        /// it, and a compressed request reaches it for a fraction of the
        /// bytes on the wire. Size memory for `max_connections` of these,
        /// not for what a peer has to send to get one.
        max_body_size: usize = 1_048_576, // 1MB default
        /// A request that declares a longer body in `Content-Length` is
        /// answered 413 before its handler runs, without reading the body,
        /// and before any 100 Continue. Unlike `max_body_size` this bounds
        /// streamed bodies too. Null leaves it to `max_body_size`.
        max_content_length: ?usize = null,
        /// An HTTP/1.1 request without a `Host` field, or any request with
        /// more than one, is answered 400 (RFC 9112 §3.2), so every part
        /// of the server and any cache in front agree on the host. False
        /// accepts them, for old clients that omit it.
        require_host: bool = true,
        /// Undo `Content-Encoding` on request bodies. A coding we cannot
        /// undo fails the read with `error.UnsupportedContentEncoding`
        /// rather than handing the handler bytes it would misread.
        ///
        /// Turn off to read what the wire carried, whatever it is;
        /// `Request.content_encoding` says what that was.
        ///
        /// Costs about 70K from the request's arena -- a 64K sliding
        /// window and the decoder -- on the requests that actually have a
        /// coded body.
        decompress: bool = true,
        /// Buffer size (bytes) for reading the request head: the request
        /// line and all headers. This is also the limit on it -- the parsed
        /// header names and values are slices into this buffer rather than
        /// copies, so the head is held whole and cannot be read in pieces.
        /// A head that does not fit is answered with 431.
        buffer_size: usize = 16384,
        /// Whether a keep-alive connection keeps the buffer its requests
        /// are read into, and their arena, while it waits for the next one.
        /// Off (the default), it gives them back between requests and takes
        /// a set again when the next one arrives: an idle connection then
        /// holds only its own 2K rather than every page its requests
        /// dirtied in the set. Under zio the trip is to a free list of the
        /// executor's own, with no lock; elsewhere it takes a sharded lock,
        /// which on a server with many cores costs some throughput.
        keep_buffers_between_requests: bool = false,
        /// Maximum number of headers allowed in a request
        max_header_count: usize = 32,
        /// Maximum number of route parameters (e.g., /user/:id/:action)
        max_param_count: usize = 8,
        /// Maximum number of query string parameters
        max_query_count: usize = 32,
        /// Maximum number of form fields (application/x-www-form-urlencoded)
        max_form_count: usize = 32,
        /// Maximum number of multipart form fields
        max_multiform_count: usize = 32,
    };

    /// `ServerConfig.response`.
    pub const Response = struct {
        /// Buffer size (bytes) for writing to the connection while a request
        /// is served. A response head and a body that fits behind it go out
        /// in one write; a streamed chunk, an event or a WebSocket frame is
        /// assembled in it and sent as it is finished. Taken from a pool at
        /// the response's first write, and given back once it is out, so a
        /// request still waiting to answer holds none. Must not be 0.
        ///
        /// 16K is the most a TLS record carries, so under TLS a smaller
        /// buffer sends what passes through it, a file or a body written in
        /// pieces, in more, smaller records.
        write_buffer_size: usize = 16384,
        /// Send a `Date` header on every response (RFC 9110 6.6.1 requires
        /// it of an origin server with a clock), unless the handler set one.
        date: bool = true,
        /// The Content-Type of a buffered body whose handler set none, as
        /// Fiber does. Null sends such a body without one.
        default_content_type: ?ContentType = .text,
        /// Most headers a response can carry, those the server adds
        /// (`Date`, `Content-Encoding`, `Vary`, ...) included. Past it,
        /// `Response.header` fails with `error.TooManyHeaders`.
        max_header_count: usize = 64,
        /// Brotli's quality (0 to 11) for responses compressed as `br`
        /// (`res.compress` with `-Dbrotli`). 5, the usual on-the-fly
        /// choice: on JSON of 1.5 to 12 KB it is 8-13% smaller than 4 and
        /// 10-15% smaller than gzip, at about 1.3x the time of 4; 6 adds
        /// under 1%. 11 is for precompressed files, not responses.
        brotli_quality: u4 = 5,
    };
};

test "ServerConfig: connection timeouts are finite by default" {
    const cfg: ServerConfig = .{};
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(30), cfg.timeout.request.?);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(60), cfg.timeout.keepalive.?);
    try std.testing.expectEqual(@as(usize, 0), cfg.trusted_proxy_hops);
}

test "ServerConfig: the default listener is 127.0.0.1:8080" {
    const cfg: ServerConfig = .{};
    try std.testing.expectEqual(@as(usize, 1), cfg.listeners.len);
    const ip = cfg.listeners[0].address.ip;
    try std.testing.expect(ip == .ip4);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 8080), ip.ip4.port);
}
