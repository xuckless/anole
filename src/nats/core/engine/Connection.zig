// Adapted from vkiryakov/zefir src/nats/engine/Connection.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! One connection to one server: the handshake, then frames in and bytes
//! out. Each side stays with the task that owns it: the handshake runs in
//! the connect attempt, then `next` in the reader and `writeAll` in the
//! writer. What a frame means to the client is the reader's business.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Options = @import("../Options.zig");
const ClientStream = @import("../../../net/client_stream.zig").ClientStream;
const transport = @import("../../transport.zig");
const nkeys = @import("../../nkeys.zig");
const ServerInfo = @import("../ServerInfo.zig");
const Parser = @import("../protocol/Parser.zig");
const encoder = @import("../protocol/encoder.zig");
const server_error = @import("../protocol/server_error.zig");
const log = std.log.scoped(.nats);
const Connection = @This();

cs: *ClientStream,
reader: transport.Reader,
parser: Parser,
/// How the server refused the credentials, when the handshake failed with
/// AuthenticationFailed.
refused: ?server_error.Refusal = null,
/// Bytes the socket took so far, counted at each write: the heartbeat sees
/// whether a writer in the middle of a long batch gets anywhere.
sent: std.atomic.Value(u64) = .init(0),

/// `buffer` holds at least `Parser.bufferLen(limits)` bytes and outlives
/// the connection.
pub fn init(cs: *ClientStream, buffer: []u8, limits: Parser.Limits) Connection {
    return .{ .cs = cs, .reader = .init(cs, buffer), .parser = .init(limits) };
}

/// What a failed read or write on the stream (plain or TLS) comes to.
pub const TransportError = error{
    Canceled,
    ConnectionResetByPeer,
    BrokenPipe,
    Unexpected,
    /// The socket or the TLS layer failed (the log says how).
    TransportFailed,
};

fn transportError(err: anyerror) TransportError {
    inline for (@typeInfo(TransportError).error_set.error_names.?) |name| {
        if (err == @field(TransportError, name)) return @field(TransportError, name);
    }
    log.warn("connection failed: {t}", .{err});
    return error.TransportFailed;
}

/// What the client says in CONNECT.
pub const Hello = struct {
    verbose: bool = false,
    pedantic: bool = false,
    echo: bool = true,
    no_responders: bool = true,
    name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    auth_token: ?[]const u8 = null,
    /// A user JWT (`.creds`).
    jwt: ?[]const u8 = null,
    /// An NKey seed: the handshake signs the server's nonce with it.
    seed: ?[]const u8 = null,
    /// How to secure the connection when the server or the address asks
    /// for TLS; null: plain only (a server that requires TLS is refused).
    tls: ?*const Options.Tls = null,
    /// The server's address said `tls://`, or `Options.Tls.required`.
    want_tls: bool = false,

    pub fn init(options: *const Options) Hello {
        return .{
            .verbose = options.verbose,
            .pedantic = options.pedantic,
            .echo = !options.no_echo,
            .no_responders = options.no_responders,
            .name = options.name,
            .user = switch (options.auth) {
                .user_password => |credentials| credentials.username,
                else => null,
            },
            .pass = switch (options.auth) {
                .user_password => |credentials| credentials.password,
                else => null,
            },
            .auth_token = switch (options.auth) {
                .token => |t| t,
                else => null,
            },
            .jwt = switch (options.auth) {
                .creds => |c| c.jwt,
                else => null,
            },
            .seed = switch (options.auth) {
                .nkey => |k| k.seed,
                .creds => |c| c.seed,
                else => null,
            },
            .tls = options.tls,
            .want_tls = if (options.tls) |t| t.required or t.first else false,
        };
    }
};

/// What the handshake learned about the server.
pub const Greeting = struct {
    /// The JSON of the latest INFO; the caller frees it.
    info_json: []u8,
    /// CONNECT asked for headers, so HPUB and HMSG work, and so do
    /// no-responders; a later INFO does not change it.
    headers: bool,
    /// The largest message the server takes, headers included; 0 when it
    /// did not say.
    max_payload: i64,
    /// The server requires TLS, or the address or options ask for it.
    tls_wanted: bool = false,
    nonce_buf: [64]u8 = undefined,
    nonce_len: u8 = 0,

    /// The server's nonce, to sign for an NKey login.
    pub fn nonce(self: *const Greeting) []const u8 {
        return self.nonce_buf[0..self.nonce_len];
    }
};

pub const ReadError = Parser.Error || error{EndOfStream} || TransportError;
pub const WriteError = TransportError;
pub const HandshakeError = error{
    /// The server wants TLS.
    UnsupportedSecurityFeature,
    /// `no_echo` on a server that cannot do it.
    UnsupportedFeature,
    AuthenticationFailed,
    /// The server sent something out of protocol, or said this client did.
    ProtocolError,
    /// The server closed the connection.
    Disconnected,
    /// The server gave up waiting for CONNECT.
    Timeout,
    /// The server takes no more connections.
    ConnectionRefused,
    /// The seed or creds of the login do not decode.
    InvalidOptions,
    OutOfMemory,
} || TransportError;

/// INFO, then CONNECT and PING in one write, then frames until PONG. A
/// PING from the server is answered at once; INFO replaces the one before.
/// nats-server answers the first PING with an INFO of this client's own
/// limits, such as its account's lower `max_payload`, right after the
/// PONG: when that INFO came with the PONG, it applies too.
pub fn handshake(conn: *Connection, io: Io, gpa: Allocator, hello: Hello) HandshakeError!Greeting {
    const first = switch (try conn.handshakeFrame()) {
        .info => |json| json,
        else => return error.ProtocolError,
    };
    var greeting = try greet(gpa, first, hello);
    errdefer gpa.free(greeting.info_json);

    // TLS: the server asks for it, the address says so, or the options
    // insist. The INFO line is consumed; anything else already read would
    // be plaintext slipped in ahead of the encrypted stream.
    if (greeting.tls_wanted and !conn.cs.isTls()) {
        const settings = hello.tls orelse return error.UnsupportedSecurityFeature;
        if (conn.reader.interface.bufferedLen() != 0) return error.ProtocolError;
        conn.cs.startTls(settings.settings) catch |err| {
            if (err == error.TlsNotBuilt) {
                log.warn("the NATS server requires TLS, which this build leaves out (-Dtls=none)", .{});
                return error.UnsupportedSecurityFeature;
            }
            return transportError(err);
        };
    }
    try conn.sendConnect(io, hello, greeting);
    while (true) switch (try conn.handshakeFrame()) {
        .pong => {
            while (try conn.bufferedInfo()) |json| {
                var newer = try greet(gpa, json, null);
                newer.headers = greeting.headers;
                gpa.free(greeting.info_json);
                greeting = newer;
            }
            return greeting;
        },
        .ping => {
            var sent: usize = 0;
            try conn.writeAll(io, &.{encoder.pong}, &sent);
        },
        .ok => {},
        .info => |json| {
            var newer = try greet(gpa, json, null);
            newer.headers = greeting.headers;
            gpa.free(greeting.info_json);
            greeting = newer;
        },
        .err => |text| if (refusal(text)) |err| {
            if (err == error.AuthenticationFailed) conn.refused = server_error.refusal(text);
            return err;
        },
        .msg, .body, .msg_end => return error.ProtocolError,
    };
}

/// The longest CONNECT frame, PING included: the options keep the JSON
/// within `Options.max_connect_json`.
const max_connect_frame = "CONNECT ".len + Options.max_connect_json + 2 + encoder.ping.len;

fn sendConnect(conn: *Connection, io: Io, hello: Hello, greeting: Greeting) HandshakeError!void {
    var buffer: [max_connect_frame]u8 = undefined;
    // The frame holds the password.
    defer std.crypto.secureZero(u8, &buffer);
    var w: Writer = .fixed(&buffer);
    var key_buf: [56]u8 = undefined;
    var sig_buf: [86]u8 = undefined;
    var nkey: ?[]const u8 = null;
    var sig: ?[]const u8 = null;
    if (hello.seed) |text| {
        const seed = nkeys.decodeSeed(text) catch return error.InvalidOptions;
        nkey = seed.publicKey(&key_buf);
        sig = seed.signNonce(greeting.nonce(), &sig_buf) catch return error.InvalidOptions;
    }
    encoder.writeConnect(&w, .{
        .verbose = hello.verbose,
        .pedantic = hello.pedantic,
        .echo = hello.echo,
        .headers = greeting.headers,
        .no_responders = hello.no_responders,
        .name = hello.name,
        .user = hello.user,
        .pass = hello.pass,
        .auth_token = hello.auth_token,
        .jwt = hello.jwt,
        .nkey = nkey,
        .sig = sig,
    }) catch return error.ProtocolError;
    w.writeAll(encoder.ping) catch return error.ProtocolError;
    var sent: usize = 0;
    try conn.writeAll(io, &.{w.buffered()}, &sent);
}

/// A copy of the INFO JSON and what the client needs from it at once. The
/// first INFO, with the `hello` to send, must also allow that CONNECT.
fn greet(gpa: Allocator, json: []const u8, hello: ?Hello) HandshakeError!Greeting {
    const info = try parseInfo(gpa, json);
    defer info.deinit();
    if (hello) |h| {
        if (info.value.tls_required and h.tls == null) return error.UnsupportedSecurityFeature;
        if (!h.echo and info.value.proto < 1) return error.UnsupportedFeature;
    }
    var greeting: Greeting = .{
        .info_json = try gpa.dupe(u8, json),
        .headers = info.value.headers,
        .max_payload = info.value.max_payload,
        .tls_wanted = if (hello) |h| info.value.tls_required or h.want_tls else false,
    };
    const n = @min(info.value.nonce.len, greeting.nonce_buf.len);
    @memcpy(greeting.nonce_buf[0..n], info.value.nonce[0..n]);
    greeting.nonce_len = @intCast(n);
    return greeting;
}

fn parseInfo(gpa: Allocator, json: []const u8) HandshakeError!std.json.Parsed(ServerInfo) {
    return ServerInfo.parse(gpa, json);
}

/// The error a `-ERR` in the handshake ends it with; null for one that
/// leaves the connection open.
fn refusal(text: []const u8) ?HandshakeError {
    return switch (server_error.classify(text).kind) {
        .authentication_failed => error.AuthenticationFailed,
        .authentication_timeout => error.Timeout,
        .stale_connection => error.Disconnected,
        .tls_required => error.UnsupportedSecurityFeature,
        .max_connections, .refused => error.ConnectionRefused,
        .protocol => error.ProtocolError,
        .permissions_violation, .max_subscriptions, .invalid_subject, .unknown => {
            log.warn("server error during the handshake: {f}", .{server_error.printable(text)});
            return null;
        },
    };
}

/// The JSON of an INFO the reader holds already, without reading more;
/// null when the next frame is something else, or not all here: that is
/// the reader's.
fn bufferedInfo(conn: *Connection) HandshakeError!?[]const u8 {
    const r = &conn.reader.interface;
    var peek = conn.parser;
    const step = peek.next(r.buffered()) catch return null;
    const frame = step.frame orelse return null;
    if (frame != .info) return null;
    conn.parser = peek;
    r.toss(step.consumed);
    return frame.info;
}

fn handshakeFrame(conn: *Connection) HandshakeError!Parser.Frame {
    return conn.next() catch |err| switch (err) {
        error.LineTooLong, error.UnknownOperation, error.InvalidArguments, error.MissingTerminator => error.ProtocolError,
        error.EndOfStream => error.Disconnected,
        else => |e| e,
    };
}

/// The next frame from the server, read as needed. Its slices stay valid
/// until the next call.
pub fn next(conn: *Connection) ReadError!Parser.Frame {
    const r = &conn.reader.interface;
    while (true) {
        const step = try conn.parser.next(r.buffered());
        r.toss(step.consumed);
        if (step.frame) |frame| return frame;
        // The buffer holds the longest line, so the parser never waits
        // with it full.
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return transportError(conn.cs.readError() orelse error.Unexpected),
        };
    }
}

/// The most one write asks of the socket. A blocking write of a large
/// batch may take long on a slow link, and `sent` grows only when it
/// returns: the heartbeat must see the writer get somewhere.
pub const max_write = 256 * 1024;

/// Writes all of `slices`, adding to `written` what the socket took, also
/// when it fails half way.
pub fn writeAll(conn: *Connection, io: Io, slices: []const []const u8, written: *usize) WriteError!void {
    if (conn.cs.isTls()) return conn.writeAllTls(slices, written);
    var window: [16][]const u8 = undefined;
    var index: usize = 0;
    while (index < slices.len) {
        const count = @min(window.len, slices.len - index);
        @memcpy(window[0..count], slices[index..][0..count]);
        index += count;
        var rest = window[0..count];
        while (rest.len > 0) {
            if (rest[0].len == 0) {
                rest = rest[1..];
                continue;
            }
            // At most `max_write` bytes in one call.
            var part: [16][]const u8 = undefined;
            var parts: usize = 0;
            var total: usize = 0;
            for (rest) |slice| {
                if (total == max_write) break;
                const take = @min(slice.len, max_write - total);
                part[parts] = slice[0..take];
                parts += 1;
                total += take;
            }
            const result = io.operate(.{ .net_write = .{ .socket_handle = conn.cs.socket.socket.handle, .data = part[0..parts] } }) catch |err| return transportError(err);
            var n = result.net_write catch |err| return transportError(err);
            // A blocking socket takes at least one byte or fails.
            if (n == 0) return error.Unexpected;
            written.* += n;
            _ = conn.sent.fetchAdd(n, .monotonic);
            while (n > 0) {
                if (n < rest[0].len) {
                    rest[0] = rest[0][n..];
                    n = 0;
                } else {
                    n -= rest[0].len;
                    rest = rest[1..];
                }
            }
        }
    }
}

/// Over TLS the socket's progress is not visible: the whole batch counts
/// as sent when a write fails, so nothing is ever sent twice.
fn writeAllTls(conn: *Connection, slices: []const []const u8, written: *usize) WriteError!void {
    const w = conn.cs.writer();
    var total: usize = 0;
    for (slices) |s| total += s.len;
    var done: usize = 0;
    for (slices) |s| {
        var rest = s;
        while (rest.len > 0) {
            const part = rest[0..@min(rest.len, max_write)];
            w.writeAll(part) catch {
                written.* += total;
                return transportError(conn.cs.writeError() orelse error.Unexpected);
            };
            done += part.len;
            rest = rest[part.len..];
            _ = conn.sent.fetchAdd(part.len, .monotonic);
        }
    }
    w.flush() catch {
        written.* += total;
        return transportError(conn.cs.writeError() orelse error.Unexpected);
    };
    written.* += done;
}

const testing = std.testing;
const golden = @import("../protocol/golden.zig");
const connect = @import("connect.zig");
const time = @import("time.zig");
const FakeServer = @import("../testing/FakeServer.zig");

/// The client's end of a test connection. Its calls run with a deadline,
/// so a mistake fails the test instead of hanging it.
const TestClient = struct {
    buffer: []u8,
    conn: Connection,
    open: bool,

    const deadline: Io.Duration = .fromSeconds(5);

    fn dial(io: Io, listener: *const net.Server) !TestClient {
        const buffer = try testing.allocator.alloc(u8, Parser.bufferLen(.{}));
        errdefer testing.allocator.free(buffer);
        const address = try FakeServer.address(listener);
        const stream = try connect.dial(io, testing.allocator, &address);
        return .{ .buffer = buffer, .conn = .init(stream, buffer, .{}), .open = true };
    }

    fn handshake(client: *TestClient, io: Io, hello: Hello) !Greeting {
        return connect.race(io, time.after(io, deadline), handshakeTask, .{ &client.conn, io, hello }, freeGreeting, null);
    }

    fn next(client: *TestClient, io: Io) !Parser.Frame {
        return connect.race(io, time.after(io, deadline), nextTask, .{&client.conn}, keep(Parser.Frame), null);
    }

    fn writeAll(client: *TestClient, io: Io, slices: []const []const u8, written: *usize) !void {
        return connect.race(io, time.after(io, deadline), writeAllTask, .{ &client.conn, io, slices, written }, keep(void), null);
    }

    /// Closes the socket: the server reads the end of the stream.
    fn hangUp(client: *TestClient, io: Io) void {
        _ = io;
        if (client.open) client.conn.cs.close();
        client.open = false;
    }

    fn deinit(client: *TestClient, io: Io) void {
        client.hangUp(io);
        testing.allocator.free(client.buffer);
    }

    fn handshakeTask(conn: *Connection, io: Io, hello: Hello) HandshakeError!Greeting {
        return conn.handshake(io, testing.allocator, hello);
    }

    fn nextTask(conn: *Connection) ReadError!Parser.Frame {
        return conn.next();
    }

    fn writeAllTask(conn: *Connection, io: Io, slices: []const []const u8, written: *usize) WriteError!void {
        return conn.writeAll(io, slices, written);
    }

    fn freeGreeting(io: Io, greeting: Greeting) void {
        _ = io;
        testing.allocator.free(greeting.info_json);
    }

    fn keep(comptime T: type) fn (Io, T) void {
        return struct {
            fn release(io: Io, value: T) void {
                _ = io;
                _ = value;
            }
        }.release;
    }
};

fn expectInfo(frame: Parser.Frame, json: []const u8) !void {
    switch (frame) {
        .info => |text| try testing.expectEqualStrings(json, text),
        else => return error.TestUnexpectedFrame,
    }
}

/// The fields of CONNECT a test looks at.
const ConnectFields = struct {
    verbose: bool,
    pedantic: bool,
    echo: bool,
    lang: []const u8,
    protocol: u8,
    headers: ?bool = null,
    no_responders: ?bool = null,
    name: ?[]const u8 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
};

fn parseConnect(line: []const u8) !std.json.Parsed(ConnectFields) {
    if (!std.mem.startsWith(u8, line, "CONNECT ")) return error.TestNotConnect;
    return std.json.parseFromSlice(ConnectFields, testing.allocator, line["CONNECT ".len..], .{ .ignore_unknown_fields = true });
}

fn serveHandshake(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(golden.info_default);
    const connect_fields = try parseConnect(try peer.readLine());
    defer connect_fields.deinit();
    const fields = connect_fields.value;
    try testing.expect(!fields.verbose and !fields.pedantic and fields.echo);
    try testing.expectEqualStrings("zig", fields.lang);
    try testing.expectEqual(1, fields.protocol);
    try testing.expectEqual(true, fields.headers);
    try testing.expectEqual(true, fields.no_responders);
    try testing.expect(fields.user == null and fields.pass == null);
    try peer.expectLine("PING");
    // A second INFO follows the first PONG; then the server PINGs.
    try peer.send(golden.pong ++ golden.info_connected ++ golden.ping);
    try peer.expectLine("PONG");
}

test "the handshake ends at PONG, takes an INFO that came with it, and leaves later frames for the reader" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveHandshake, .{ io, &listener });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);

    const greeting = try client.handshake(io, .{});
    defer testing.allocator.free(greeting.info_json);
    try testing.expect(greeting.headers);
    try testing.expectEqual(1_048_576, greeting.max_payload);
    // One write holds PONG, INFO and PING; should the socket split it, the
    // INFO is the reader's.
    if (!std.mem.eql(u8, golden.info_connected_json, greeting.info_json)) {
        try testing.expectEqualStrings(golden.info_default_json, greeting.info_json);
        try expectInfo(try client.next(io), golden.info_connected_json);
    }
    try testing.expect(try client.next(io) == .ping);
    var sent: usize = 0;
    try client.writeAll(io, &.{encoder.pong}, &sent);
    try testing.expectEqual(encoder.pong.len, sent);
    client.hangUp(io);
    try server.await(io);
}

fn servePingDuringHandshake(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(golden.ping);
    try peer.expectLine("PONG");
    try peer.send(golden.pong);
}

test "a server PING during the handshake is answered at once" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(servePingDuringHandshake, .{ io, &listener });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    const greeting = try client.handshake(io, .{});
    testing.allocator.free(greeting.info_json);
    client.hangUp(io);
    try server.await(io);
}

const info_without_headers = "INFO {\"server_id\":\"old\",\"proto\":1,\"max_payload\":1024} \r\n";

fn serveWithoutHeaders(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(info_without_headers);
    const connect_fields = try parseConnect(try peer.readLine());
    defer connect_fields.deinit();
    const fields = connect_fields.value;
    try testing.expect(fields.headers == null and fields.no_responders == null);
    try testing.expect(fields.verbose and fields.pedantic and !fields.echo);
    try testing.expectEqualStrings("orders", fields.name orelse "");
    try testing.expectEqualStrings("alice", fields.user orelse "");
    try testing.expectEqualStrings("p\"w\\ü", fields.pass orelse "");
    try peer.expectLine("PING");
    try peer.send(golden.pong);
}

test "CONNECT asks for headers only when INFO offers them, and carries the credentials" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveWithoutHeaders, .{ io, &listener });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    const greeting = try client.handshake(io, .{
        .verbose = true,
        .pedantic = true,
        .echo = false,
        .name = "orders",
        .user = "alice",
        .pass = "p\"w\\ü",
    });
    defer testing.allocator.free(greeting.info_json);
    try testing.expect(!greeting.headers);
    try testing.expectEqual(1024, greeting.max_payload);
    client.hangUp(io);
    try server.await(io);
}

fn serveInfoWithoutHeadersLater(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(golden.info_default);
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(info_without_headers ++ golden.pong);
}

test "headers stay as CONNECT asked for them; a later INFO brings its max_payload" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveInfoWithoutHeadersLater, .{ io, &listener });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    const greeting = try client.handshake(io, .{});
    defer testing.allocator.free(greeting.info_json);
    try testing.expect(greeting.headers);
    try testing.expectEqual(1024, greeting.max_payload);
    try testing.expectEqualStrings(info_without_headers["INFO ".len .. info_without_headers.len - " \r\n".len], greeting.info_json);
    client.hangUp(io);
    try server.await(io);
}

fn serveAndCount(io: Io, listener: *net.Server, first: []const u8, received: *usize) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(first);
    received.* = try peer.readToEnd();
}

/// Runs a handshake against a server that sends `first`; returns how many
/// bytes the client sent before it hung up.
fn expectRefusal(expected: anyerror, first: []const u8, hello: Hello) !usize {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var received: usize = std.math.maxInt(usize);
    var server = try io.concurrent(serveAndCount, .{ io, &listener, first, &received });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    try testing.expectError(expected, client.handshake(io, hello));
    client.hangUp(io);
    try server.await(io);
    return received;
}

test "a server that wants TLS gets no CONNECT, and no password" {
    const sent = try expectRefusal(error.UnsupportedSecurityFeature, "INFO " ++ golden.info_tls_json ++ " \r\n", .{ .user = "u", .pass = "secret" });
    try testing.expectEqual(0, sent);
}

test "no_echo needs a server with protocol 1" {
    const sent = try expectRefusal(error.UnsupportedFeature, "INFO {\"server_id\":\"ancient\",\"proto\":0} \r\n", .{ .echo = false });
    try testing.expectEqual(0, sent);
}

test "a first frame other than a valid INFO is a protocol error" {
    _ = try expectRefusal(error.ProtocolError, golden.ping, .{});
    _ = try expectRefusal(error.ProtocolError, "INFO {\"port\":\"not a number\"}\r\n", .{});
    _ = try expectRefusal(error.ProtocolError, "FOO\r\n", .{});
}

fn serveRejection(io: Io, listener: *net.Server, rejection: []const u8) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send("INFO " ++ golden.info_auth_json ++ " \r\n");
    _ = try peer.readLine();
    try peer.expectLine("PING");
    try peer.send(rejection);
}

fn expectRejection(expected: anyerror, rejection: []const u8) !void {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveRejection, .{ io, &listener, rejection });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    try testing.expectError(expected, client.handshake(io, .{ .user = "u", .pass = "wrong" }));
    client.hangUp(io);
    try server.await(io);
}

test "the server's answer to CONNECT decides the handshake" {
    try expectRejection(error.AuthenticationFailed, "-ERR 'Authorization Violation'\r\n");
    try expectRejection(error.ConnectionRefused, "-ERR 'maximum connections exceeded'\r\n");
    try expectRejection(error.UnsupportedSecurityFeature, "-ERR 'Secure Connection - TLS Required'\r\n");
    try expectRejection(error.ProtocolError, "-ERR 'Unknown Protocol Operation'\r\n");
    // The server closes the connection without a word.
    try expectRejection(error.Disconnected, "");
    // A message cannot come before the subscription that asks for it.
    try expectRejection(error.ProtocolError, golden.msg_plain);
}

fn serveCloseAtOnce(io: Io, listener: *net.Server) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    peer.close();
}

test "a server that closes before INFO" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveCloseAtOnce, .{ io, &listener });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    try testing.expectError(error.Disconnected, client.handshake(io, .{}));
    client.hangUp(io);
    try server.await(io);
}

fn serveFrames(io: Io, listener: *net.Server, frames: []const u8) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    try peer.send(frames);
}

test "next reports frames, then a malformed one or the end of the stream" {
    const io = testing.io;
    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    {
        var server = try io.concurrent(serveFrames, .{ io, &listener, "PING\r\nFOO bar\r\n" });
        defer server.cancel(io) catch {};
        var client = try TestClient.dial(io, &listener);
        defer client.deinit(io);
        try testing.expect(try client.next(io) == .ping);
        try testing.expectError(error.UnknownOperation, client.next(io));
        client.hangUp(io);
        try server.await(io);
    }
    {
        var server = try io.concurrent(serveFrames, .{ io, &listener, "PONG\r\n" });
        defer server.cancel(io) catch {};
        var client = try TestClient.dial(io, &listener);
        defer client.deinit(io);
        try testing.expect(try client.next(io) == .pong);
        try testing.expectError(error.EndOfStream, client.next(io));
        client.hangUp(io);
        try server.await(io);
    }
}

fn serveRead(io: Io, listener: *net.Server, expected: []const u8) !void {
    var peer: FakeServer.Peer = undefined;
    try peer.accept(io, listener);
    defer peer.close();
    const got = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(got);
    try peer.readExact(got);
    try testing.expectEqualSlices(u8, expected, got);
}

test "writeAll sends every slice, however the socket splits them" {
    const io = testing.io;
    const data = try testing.allocator.alloc(u8, 3 * 1024 * 1024);
    defer testing.allocator.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 7919);
    var slices: [20][]const u8 = undefined;
    const piece = data.len / slices.len;
    for (&slices, 0..) |*slice, i| slice.* = data[i * piece .. if (i + 1 == slices.len) data.len else (i + 1) * piece];

    var listener = try FakeServer.listen(io);
    defer listener.deinit(io);
    var server = try io.concurrent(serveRead, .{ io, &listener, data });
    defer server.cancel(io) catch {};
    var client = try TestClient.dial(io, &listener);
    defer client.deinit(io);
    var sent: usize = 0;
    try client.writeAll(io, &slices, &sent);
    try testing.expectEqual(data.len, sent);
    client.hangUp(io);
    try server.await(io);
}

test "Hello takes the CONNECT fields of the options" {
    const plain: Hello = .init(&.{ .servers = &.{"a"} });
    try testing.expectEqual(Hello{}, plain);
    const custom: Hello = .init(&.{
        .servers = &.{"a"},
        .name = "svc",
        .verbose = true,
        .pedantic = true,
        .no_echo = true,
        .no_responders = false,
        .auth = .{ .user_password = .{ .username = "u", .password = "p" } },
    });
    try testing.expect(custom.verbose and custom.pedantic and !custom.echo and !custom.no_responders);
    try testing.expectEqualStrings("svc", custom.name orelse "");
    try testing.expectEqualStrings("u", custom.user orelse "");
    try testing.expectEqualStrings("p", custom.pass orelse "");
}
