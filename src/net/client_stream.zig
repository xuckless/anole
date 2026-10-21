//! An outbound byte stream for the database clients (PostgreSQL, MongoDB,
//! Redis): TCP or a Unix socket, plain or TLS on BoringSSL, read and
//! written through `std.Io.Reader`/`Writer` on `std.Io`, so a wait suspends
//! the calling coroutine, never its thread.
//!
//!     const s = try anole.net.ClientStream.connect(gpa, io, .{
//!         .host = "db.internal", .port = 27017, .tls = .{ .ca = .{ .file = .{ .path = "ca.pem" } } } });
//!     defer s.close();
//!     try s.writer().writeAll(request);
//!     try s.writer().flush();
//!     const reply = try s.reader().take(16);
//!
//! TLS takes the same options as Anole's other clients (`anole.http`,
//! `anole.h2`, `anole.h3`): `ca` (the system store by default),
//! `client_certificate`, `insecure_skip_verify`. A protocol that asks for
//! TLS in plaintext first (PostgreSQL's SSLRequest) connects plain and
//! calls `startTls`.
//!
//! One task may read while another writes; neither may overlap `close`.
const std = @import("std");
const features = @import("build_options");
const dusty = @import("dusty");
const tls = if (features.tls == .boringssl) @import("anole_dusty_tls") else struct {};

const has_tls = features.tls == .boringssl;

/// For `ClientStream.connect`.
pub const ConnectOptions = struct {
    /// The server's name or address; for TLS, also the name its
    /// certificate must carry (unless `Tls.server_name` says otherwise).
    host: []const u8 = "localhost",
    port: u16,
    /// Connect here instead of resolving `host`.
    address: ?std.Io.net.IpAddress = null,
    /// Connect to this Unix socket instead (`host` and `port` then only
    /// name the server, for TLS and for logs).
    unix_path: ?[]const u8 = null,
    /// TLS from the first byte; null for plain (or for `startTls` later).
    tls: ?Tls = null,
    /// For `connect`, and again for `startTls`: the TCP connection and the
    /// TLS handshake. Past it they fail with `error.Timeout`. Null for no
    /// limit.
    connect_timeout: ?std.Io.Duration = .fromSeconds(10),

    pub const Tls = struct {
        /// The certificate authorities the server's certificate must chain to.
        /// The system store (the default) is loaded once for the process; a
        /// file, directory or PEM is read on every handshake. `.none` only with
        /// `insecure_skip_verify`.
        ca: Ca = .system,
        /// A certificate to present when the server asks for one (mutual TLS):
        /// files or PEM in memory, read on every handshake.
        client_certificate: ?ClientCertificate = null,
        /// Accept any certificate, for any name: encryption without
        /// authentication (libpq's `sslmode=require` without a root
        /// certificate, MongoDB's `tlsInsecure`). For tests, or a network you
        /// trust anyway.
        insecure_skip_verify: bool = false,
        /// Verify the chain but not the name in it (`sslmode=verify-ca`,
        /// `tlsAllowInvalidHostnames`).
        skip_host_check: bool = false,
        /// The name to verify and to send as SNI, when it is not the host
        /// connected to (an IP address, a Unix socket, a tunnel).
        server_name: ?[]const u8 = null,
        /// ALPN protocols to offer, such as "postgresql" for PostgreSQL 17's
        /// direct TLS; empty for none. See `alpnProtocol`.
        alpn: []const []const u8 = &.{},

        pub const Ca = dusty.TlsCa;
        pub const ClientCertificate = dusty.TlsConfig.ClientCertificate;
    };
};


pub const ClientStream = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    socket: std.Io.net.Stream,
    tcp_reader: std.Io.net.Stream.Reader,
    tcp_writer: std.Io.net.Stream.Writer,
    /// Set once the handshake is done.
    secure: if (has_tls) ?*Secure else void = if (has_tls) null else {},
    connect_timeout: ?std.Io.Duration,
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,

    /// The TLS side, allocated by the handshake so a plain stream does not
    /// carry it.
    const Secure = struct {
        conn: tls.Connection,
        reader: tls.Connection.Reader,
        writer: tls.Connection.Writer,
        read_buf: [16 * 1024]u8 = undefined,
        write_buf: [16 * 1024]u8 = undefined,
    };

    /// Connects within `connect_timeout` (TCP, then TLS when `tls` is set).
    /// `error.TlsNotBuilt` for TLS in a build without it (`-Dtls=none`).
    pub fn connect(gpa: std.mem.Allocator, io: std.Io, opts: ConnectOptions) !*ClientStream {
        if (opts.host.len > 255) return error.NameTooLong;
        if (opts.tls != null and !has_tls) return error.TlsNotBuilt;
        const self = try gpa.create(ClientStream);
        errdefer gpa.destroy(self);
        const deadline: dusty.Deadline = .init(io, timeoutFrom(opts.connect_timeout));
        const socket = try deadline.run(dial, .{ io, opts });
        errdefer socket.close(io);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .socket = socket,
            .tcp_reader = undefined,
            .tcp_writer = undefined,
            .connect_timeout = opts.connect_timeout,
            .host_len = opts.host.len,
        };
        @memcpy(self.host_buf[0..opts.host.len], opts.host);
        self.tcp_reader = socket.reader(io, &self.read_buf);
        self.tcp_writer = socket.writer(io, &self.write_buf);
        if (opts.tls) |t| try deadline.run(handshake, .{ self, t });
        return self;
    }

    fn dial(io: std.Io, opts: ConnectOptions) !std.Io.net.Stream {
        if (opts.unix_path) |path| return (try std.Io.net.UnixAddress.init(path)).connect(io);
        if (opts.address) |a| return a.connect(io, .{ .mode = .stream });
        if (std.Io.net.IpAddress.parse(opts.host, opts.port)) |a| return a.connect(io, .{ .mode = .stream }) else |_| {}
        return (try std.Io.net.HostName.init(opts.host)).connect(io, opts.port, .{ .mode = .stream });
    }

    /// Switches a plain stream to TLS, within `connect_timeout`: after
    /// PostgreSQL's SSLRequest is answered 'S'. Bytes the server sent
    /// before the handshake that the caller has not read are refused
    /// (`error.UnexpectedPlaintext`): a man in the middle could otherwise
    /// slip them in ahead of the encrypted stream (CVE-2021-23214).
    pub fn startTls(self: *ClientStream, t: ConnectOptions.Tls) !void {
        if (comptime !has_tls) return error.TlsNotBuilt;
        if (self.secure != null) return error.AlreadyTls;
        if (self.tcp_reader.interface.bufferedLen() != 0) return error.UnexpectedPlaintext;
        const deadline: dusty.Deadline = .init(self.io, timeoutFrom(self.connect_timeout));
        try deadline.run(handshake, .{ self, t });
    }

    fn handshake(self: *ClientStream, t: ConnectOptions.Tls) !void {
        if (comptime !has_tls) return error.TlsNotBuilt;
        const gpa = self.gpa;
        const io = self.io;
        const store = if (t.insecure_skip_verify)
            null
        else
            try tls.clientStore(gpa, io, t.ca) orelse return error.NoCertificateAuthority;
        defer if (store) |s| tls.releaseStore(s);
        var pair: ?tls.config.CertKeyPair = if (t.client_certificate) |cc| try loadCertificate(gpa, io, cc) else null;
        // The SSL takes its own references to the certificate and key.
        defer if (pair) |*p| p.deinit(gpa);

        const secure = try gpa.create(Secure);
        errdefer gpa.destroy(secure);
        var rng: std.Random.IoSource = .{ .io = io };
        secure.conn = tls.client(&self.tcp_reader.interface, &self.tcp_writer.interface, .{
            .host = t.server_name orelse self.host_buf[0..self.host_len],
            .root_ca = .empty,
            .store = store,
            .insecure_skip_verify = t.insecure_skip_verify,
            .skip_host_check = t.skip_host_check,
            .auth = if (pair) |*p| p else null,
            .now = std.Io.Clock.real.now(io),
            .rng = rng.interface(),
            .alpn_protocols = t.alpn,
        }) catch |err| return switch (err) {
            // The cause is a layer down, on the socket.
            error.ReadFailed => self.tcp_reader.err orelse error.ConnectionClosed,
            error.WriteFailed => self.tcp_writer.err orelse error.ConnectionClosed,
            else => |e| e,
        };
        secure.reader = secure.conn.reader(&secure.read_buf);
        secure.writer = secure.conn.writer(&secure.write_buf);
        self.secure = secure;
    }

    /// Where the server's bytes come in (decrypted, on TLS). An
    /// `error.ReadFailed` from it is explained by `readError`.
    pub fn reader(self: *ClientStream) *std.Io.Reader {
        if (comptime has_tls) if (self.secure) |s| return &s.reader.interface;
        return &self.tcp_reader.interface;
    }

    /// Where bytes for the server go; nothing leaves before `flush`. An
    /// `error.WriteFailed` from it is explained by `writeError`.
    pub fn writer(self: *ClientStream) *std.Io.Writer {
        if (comptime has_tls) if (self.secure) |s| return &s.writer.interface;
        return &self.tcp_writer.interface;
    }

    /// What the last `error.ReadFailed` from `reader` was: the socket's
    /// error (`error.Canceled` among them), else the TLS layer's.
    pub fn readError(self: *const ClientStream) ?anyerror {
        if (self.tcp_reader.err) |e| return e;
        if (comptime has_tls) if (self.secure) |s| if (s.reader.err) |e| return e;
        return null;
    }

    /// What the last `error.WriteFailed` from `writer` was, as `readError`.
    pub fn writeError(self: *const ClientStream) ?anyerror {
        if (self.tcp_writer.err) |e| return e;
        if (comptime has_tls) if (self.secure) |s| if (s.writer.err) |e| return e;
        return null;
    }

    pub fn isTls(self: *const ClientStream) bool {
        if (comptime has_tls) return self.secure != null;
        return false;
    }

    /// The ALPN protocol the server picked from `ConnectOptions.Tls.alpn`, or null.
    pub fn alpnProtocol(self: *const ClientStream) ?[]const u8 {
        if (comptime has_tls) if (self.secure) |s| return s.conn.alpn_protocol;
        return null;
    }

    /// The server's certificate (the leaf, DER), for SCRAM channel binding
    /// (`tls-server-end-point`, RFC 5929); null on a plain stream. Valid
    /// until `close`.
    pub fn serverCertificate(self: *const ClientStream) ?[]const u8 {
        if (comptime has_tls) if (self.secure) |s| return tls.peerLeaf(s.conn.shared.?.ssl);
        return null;
    }

    /// Ends both directions at the socket without freeing anything: a task
    /// waiting in `reader` (a monitor, say) wakes with an error. `close`
    /// still follows.
    pub fn shutdown(self: *ClientStream) void {
        self.socket.shutdown(self.io, .both) catch {};
    }

    /// Sends TLS close_notify (best effort), closes the socket and frees
    /// the stream.
    pub fn close(self: *ClientStream) void {
        if (comptime has_tls) if (self.secure) |s| {
            s.conn.close();
            s.conn.deinit();
            self.gpa.destroy(s);
        };
        self.socket.close(self.io);
        self.gpa.destroy(self);
    }
};

fn timeoutFrom(duration: ?std.Io.Duration) std.Io.Timeout {
    const d = duration orelse return .none;
    return .{ .duration = .{ .raw = d, .clock = .awake } };
}

fn loadCertificate(gpa: std.mem.Allocator, io: std.Io, cc: ConnectOptions.Tls.ClientCertificate) !tls.config.CertKeyPair {
    if (cc.pem) |pem| return tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key);
    return tls.config.CertKeyPair.fromFilePath(gpa, io, cc.dir orelse std.Io.Dir.cwd(), cc.cert_path, cc.key_path);
}

// ---------------------------------------------------------------------------
// Tests: a local server, plain or TLS with a certificate made for the test.

const testing = std.testing;
const zio = @import("zio");

/// What the test server does before it echoes.
const Opening = enum {
    /// TLS from the first byte.
    tls,
    /// Plain throughout.
    plain,
    /// PostgreSQL's way: an 8-byte SSLRequest answered 'S', then TLS.
    ssl_request,
    /// As `ssl_request`, but 'S' comes with a plaintext byte after it.
    ssl_request_injected,
};

const TestServer = struct {
    listener: std.Io.net.Server,
    auth: if (has_tls) tls.config.CertKeyPair else void,
    pem: if (has_tls) @import("../tls/root.zig").Pem else void,

    fn init(io: std.Io) !TestServer {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var self: TestServer = .{ .listener = try addr.listen(io, .{}), .auth = undefined, .pem = undefined };
        errdefer self.listener.deinit(io);
        if (comptime has_tls) {
            self.pem = try @import("../tls/root.zig").selfSigned(testing.allocator, .{});
            self.auth = try tls.config.CertKeyPair.fromSlice(testing.allocator, io, self.pem.cert, self.pem.key);
        }
        return self;
    }

    fn deinit(self: *TestServer, io: std.Io) void {
        if (comptime has_tls) {
            self.auth.deinit(testing.allocator);
            self.pem.deinit(testing.allocator);
        }
        self.listener.deinit(io);
    }

    fn port(self: *const TestServer) u16 {
        return self.listener.socket.address.getPort();
    }

    /// Serves one connection: the opening, then each line back until the
    /// client goes. A failed handshake ends it quietly.
    fn serveOne(self: *TestServer, io: std.Io, opening: Opening) !void {
        const conn = try self.listener.accept(io);
        defer conn.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var tcp_r = conn.reader(io, &rbuf);
        var tcp_w = conn.writer(io, &wbuf);
        if (opening == .plain) return echo(&tcp_r.interface, &tcp_w.interface);
        if (comptime !has_tls) return;
        if (opening != .tls) {
            _ = try tcp_r.interface.take(8);
            try tcp_w.interface.writeAll(if (opening == .ssl_request) "S" else "SX");
            try tcp_w.interface.flush();
            if (opening == .ssl_request_injected) return;
        }
        var rng: std.Random.IoSource = .{ .io = io };
        var t = tls.server(&tcp_r.interface, &tcp_w.interface, .{
            .auth = &self.auth,
            .now = std.Io.Clock.real.now(io),
            .rng = rng.interface(),
            .alpn_protocols = &.{"echo"},
        }) catch return;
        defer t.deinit();
        var plain_rbuf: [16384]u8 = undefined;
        var plain_wbuf: [4096]u8 = undefined;
        var r = t.reader(&plain_rbuf);
        var w = t.writer(&plain_wbuf);
        try echo(&r.interface, &w.interface);
    }

    fn echo(r: *std.Io.Reader, w: *std.Io.Writer) !void {
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch return;
            try w.writeAll(line);
            try w.flush();
        }
    }
};

fn roundTrip(s: *ClientStream, text: []const u8) !void {
    try s.writer().writeAll(text);
    try s.writer().flush();
    try testing.expectEqualStrings(text, try s.reader().takeDelimiterInclusive('\n'));
}

test "ClientStream: plain TCP" {
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = try TestServer.init(io);
    defer server.deinit(io);
    var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .plain });
    defer serving.cancel(io) catch {};

    const s = try ClientStream.connect(testing.allocator, io, .{ .host = "127.0.0.1", .port = server.port() });
    defer s.close();
    try testing.expect(!s.isTls());
    try testing.expect(s.serverCertificate() == null);
    try roundTrip(s, "hello\n");
    try roundTrip(s, "again\n");
}

test "ClientStream: TLS without TLS built in is refused" {
    if (comptime has_tls) return error.SkipZigTest;
    try testing.expectError(error.TlsNotBuilt, ClientStream.connect(testing.allocator, testing.io, .{ .port = 1, .tls = .{} }));
}

test "ClientStream: TLS, verified against the server's CA, with ALPN" {
    if (comptime !has_tls) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = try TestServer.init(io);
    defer server.deinit(io);
    var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .tls });
    defer serving.cancel(io) catch {};

    const s = try ClientStream.connect(testing.allocator, io, .{
        .host = "localhost",
        .port = server.port(),
        .address = .{ .ip4 = .loopback(server.port()) },
        .tls = .{ .ca = .{ .pem = server.pem.cert }, .alpn = &.{ "other", "echo" } },
    });
    defer s.close();
    try testing.expect(s.isTls());
    try testing.expectEqualStrings("echo", s.alpnProtocol().?);
    // The leaf the server sent: what channel binding hashes.
    const der = s.serverCertificate().?;
    try testing.expect(der.len > 100 and der[0] == 0x30);
    try roundTrip(s, "over tls\n");
    // Several TLS records' worth.
    const long: [12001]u8 = @as([12000]u8, @splat('x')) ++ "\n".*;
    try roundTrip(s, &long);
}

test "ClientStream: a certificate for another name fails, unless only the chain is checked" {
    if (comptime !has_tls) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = try TestServer.init(io);
    defer server.deinit(io);

    const opts: ConnectOptions = .{
        .host = "127.0.0.1",
        .port = server.port(),
        .tls = .{ .ca = .{ .pem = server.pem.cert }, .server_name = "db.example.com" },
    };
    {
        var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .tls });
        defer serving.cancel(io) catch {};
        if (ClientStream.connect(testing.allocator, io, opts)) |s| {
            s.close();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    {
        var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .tls });
        defer serving.cancel(io) catch {};
        var chain_only = opts;
        chain_only.tls.?.skip_host_check = true;
        const s = try ClientStream.connect(testing.allocator, io, chain_only);
        defer s.close();
        try roundTrip(s, "chain only\n");
    }
    {
        // Another CA: refused even without the name check.
        var other = try @import("../tls/root.zig").selfSigned(testing.allocator, .{});
        defer other.deinit(testing.allocator);
        var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .tls });
        defer serving.cancel(io) catch {};
        var wrong_ca = opts;
        wrong_ca.tls.?.ca = .{ .pem = other.cert };
        wrong_ca.tls.?.skip_host_check = true;
        if (ClientStream.connect(testing.allocator, io, wrong_ca)) |s| {
            s.close();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "ClientStream: startTls after an SSLRequest, and plaintext slipped in before it refused" {
    if (comptime !has_tls) return error.SkipZigTest;
    const rt = try zio.Runtime.init(testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    var server = try TestServer.init(io);
    defer server.deinit(io);
    const ssl_request = [_]u8{ 0, 0, 0, 8, 4, 0xd2, 0x16, 0x2f };
    {
        var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .ssl_request });
        defer serving.cancel(io) catch {};
        const s = try ClientStream.connect(testing.allocator, io, .{ .host = "localhost", .port = server.port(), .address = .{ .ip4 = .loopback(server.port()) } });
        defer s.close();
        try s.writer().writeAll(&ssl_request);
        try s.writer().flush();
        try testing.expectEqual('S', try s.reader().takeByte());
        try s.startTls(.{ .ca = .{ .pem = server.pem.cert } });
        try testing.expect(s.isTls());
        try roundTrip(s, "upgraded\n");
    }
    {
        var serving = try io.concurrent(TestServer.serveOne, .{ &server, io, .ssl_request_injected });
        defer serving.cancel(io) catch {};
        const s = try ClientStream.connect(testing.allocator, io, .{ .host = "localhost", .port = server.port(), .address = .{ .ip4 = .loopback(server.port()) } });
        defer s.close();
        try s.writer().writeAll(&ssl_request);
        try s.writer().flush();
        // Both bytes are in by the time the second is seen.
        _ = try s.reader().peek(2);
        try testing.expectEqual('S', try s.reader().takeByte());
        try testing.expectError(error.UnexpectedPlaintext, s.startTls(.{ .ca = .{ .pem = server.pem.cert } }));
    }
}
