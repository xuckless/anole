//! One connection to one server: a `ClientStream` (TCP or a Unix socket,
//! plain or TLS), the handshake (mongodb-handshake: legacy hello over
//! OP_MSG with `helloOk`, the client's metadata, mechanism negotiation and
//! speculative authentication), authentication (SCRAM-SHA-256,
//! SCRAM-SHA-1, PLAIN, MONGODB-X509), and one command at a time.
//!
//! A command's reply is read into the connection's buffer and points into
//! it until the next command: callers decode what they need first.
const std = @import("std");
const builtin = @import("builtin");
const bson = @import("bson");
const wire = @import("wire.zig");
const scram = @import("scram.zig");
const sdam = @import("sdam.zig");
const uri = @import("uri.zig");
const net = @import("../net/client_stream.zig");

const log = std.log.scoped(.anole);

/// The driver's name and version in the handshake's client metadata.
pub const driver_name = "anole";
pub const driver_version = "0.2.1";

/// Request IDs, unique in the process.
var next_request_id: std.atomic.Value(i32) = .init(1);

pub fn requestId() i32 {
    return next_request_id.fetchAdd(1, .monotonic);
}

/// Where a server is: a host and port, or a Unix socket.
pub const Address = struct {
    /// "host:port" (lower case) or the socket's path: the topology's key.
    text: []const u8,
    host: []const u8,
    port: u16 = 27017,
    unix: bool = false,

    /// Splits a topology address ("host:port", "[::1]:27017", a path).
    pub fn parse(text: []const u8) Address {
        if (std.mem.endsWith(u8, text, ".sock") and std.mem.indexOfScalar(u8, text, '/') != null)
            return .{ .text = text, .host = text, .unix = true };
        if (std.mem.startsWith(u8, text, "[")) {
            const close = std.mem.indexOfScalar(u8, text, ']') orelse return .{ .text = text, .host = text };
            const port = if (close + 2 <= text.len) std.fmt.parseInt(u16, text[close + 2 ..], 10) catch 27017 else 27017;
            return .{ .text = text, .host = text[1..close], .port = port };
        }
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return .{ .text = text, .host = text };
        return .{ .text = text, .host = text[0..colon], .port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch 27017 };
    }
};

/// What every connection of a client is opened with.
pub const Settings = struct {
    tls: ?net.ConnectOptions.Tls = null,
    connect_timeout: ?std.Io.Duration = .fromSeconds(10),
    /// For authenticated (pool) connections; monitors never authenticate.
    credential: ?uri.Credential = null,
    /// The client metadata document (`clientMetadata`).
    metadata: []const u8,
    scram_cache: *scram.Cache,
};

/// The client metadata of the handshake: the driver, the OS, the platform
/// and the application's name.
pub fn clientMetadata(gpa: std.mem.Allocator, app_name: ?[]const u8) ![]u8 {
    const os_type = switch (builtin.os.tag) {
        .linux => "Linux",
        .macos => "Darwin",
        .windows => "Windows",
        .freebsd, .openbsd, .netbsd => "BSD",
        else => "unknown",
    };
    var b: bson.Builder = .init(gpa);
    errdefer b.deinit();
    try b.begin();
    if (app_name) |name| {
        try b.beginDocument("application");
        // The server caps the whole document at 512 bytes; a name past
        // 128 is trimmed, on a character boundary.
        var n = @min(name.len, 128);
        while (n > 0 and n < name.len and (name[n] & 0xC0) == 0x80) n -= 1;
        try b.append("name", .{ .string = name[0..n] });
        try b.end();
    }
    try b.beginDocument("driver");
    try b.append("name", .{ .string = driver_name });
    try b.append("version", .{ .string = driver_version });
    try b.end();
    try b.beginDocument("os");
    try b.append("type", .{ .string = os_type });
    try b.append("architecture", .{ .string = @tagName(builtin.cpu.arch) });
    try b.end();
    try b.append("platform", .{ .string = "Zig " ++ builtin.zig_version_string });
    try b.end();
    return b.toOwnedSlice();
}

/// A command's failure as the server put it (`ok: 0`), or the first write
/// error, or a write concern error. Points into the reply.
pub const ServerError = struct {
    code: ?i64 = null,
    code_name: []const u8 = "",
    message: []const u8 = "",
    labels: ?bson.Array = null,
    /// The reply, for the topology's error handling.
    reply: bson.Document,
    kind: Kind = .command,

    pub const Kind = enum { command, write, write_concern };

    pub fn hasLabel(e: ServerError, label: []const u8) bool {
        const labels = e.labels orelse return false;
        var it = labels.iterator();
        while (it.next()) |v| if (v == .string and std.mem.eql(u8, v.string, label)) return true;
        return false;
    }

    fn fromDoc(doc: bson.Document, reply: bson.Document, kind: Kind) ServerError {
        return .{
            .code = sdam.intOf(doc.get("code")),
            .code_name = sdam.stringOf(doc.get("codeName")) orelse "",
            .message = sdam.stringOf(doc.get("errmsg")) orelse "",
            .labels = if (reply.get("errorLabels")) |v| switch (v) {
                .array => |a| a,
                else => null,
            } else null,
            .reply = reply,
            .kind = kind,
        };
    }
};

/// The failure a reply carries, if any: `ok: 0`, else the first of
/// `writeErrors`, else `writeConcernError`.
pub fn replyError(reply: bson.Document) ?ServerError {
    if (!sdam.okOf(reply)) return ServerError.fromDoc(reply, reply, .command);
    if (reply.get("writeErrors")) |v| if (v == .array) {
        if (v.array.at(0)) |first| if (first == .document) return ServerError.fromDoc(first.document, reply, .write);
    };
    if (reply.get("writeConcernError")) |v| if (v == .document) return ServerError.fromDoc(v.document, reply, .write_concern);
    return null;
}

pub const Connection = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: *net.ClientStream,
    address: Address,
    /// The server's pool generation when this connection was opened.
    generation: u32 = 0,
    /// The client's per-server state this connection belongs to.
    server: ?*anyopaque = null,
    builder: bson.Builder,
    read_buf: std.ArrayList(u8) = .empty,
    /// From the handshake.
    max_bson_object_size: usize = 16 * 1024 * 1024,
    max_message_size: usize = 48_000_000,
    max_write_batch_size: usize = 100_000,
    max_wire_version: i32 = 0,
    hello_ok: bool = false,
    /// Logical sessions are supported (`logicalSessionTimeoutMinutes`).
    sessions: bool = false,
    /// The description the handshake's reply makes, for monitors.
    last_used: std.Io.Clock.Timestamp,
    /// A command did not complete (an I/O error or a cancel mid-reply):
    /// the stream is out of step, close it.
    broken: bool = false,

    /// Connects, sends the handshake, and authenticates when `settings`
    /// has a credential and `authenticate` is set. Returns the hello
    /// reply's description too when `describe_into` is given (monitors).
    pub fn open(gpa: std.mem.Allocator, io: std.Io, address: Address, settings: Settings, authenticate: bool) !*Connection {
        const stream = try net.ClientStream.connect(gpa, io, .{
            .host = address.host,
            .port = address.port,
            .unix_path = if (address.unix) address.host else null,
            .tls = settings.tls,
            .connect_timeout = settings.connect_timeout,
        });
        errdefer stream.close();
        const self = try gpa.create(Connection);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .address = address,
            .builder = .init(gpa),
            .last_used = .now(io, .awake),
        };
        errdefer {
            self.builder.deinit();
            self.read_buf.deinit(gpa);
        }
        try self.handshake(settings, authenticate);
        return self;
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
        self.builder.deinit();
        self.read_buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Starts a command in the connection's buffer: the body is open for
    /// its fields.
    pub fn begin(self: *Connection) wire.Error!wire.Message {
        return wire.Message.begin(&self.builder);
    }

    /// Sends the message `m` finished and waits for its reply, which
    /// points into the connection until the next command. Marks the
    /// connection broken when the exchange does not complete.
    pub fn roundTrip(self: *Connection, m: *wire.Message) !wire.Reply {
        const id = requestId();
        const bytes = try m.finish(id);
        if (bytes.len > self.max_message_size) return error.MessageTooLarge;
        errdefer self.broken = true;
        const w = self.stream.writer();
        w.writeAll(bytes) catch return self.stream.writeError() orelse error.ConnectionClosed;
        w.flush() catch return self.stream.writeError() orelse error.ConnectionClosed;
        const raw = wire.read(self.stream.reader(), self.gpa, &self.read_buf, @max(self.max_message_size, 48_000_000)) catch |err| return switch (err) {
            error.ReadFailed => self.stream.readError() orelse error.ConnectionClosed,
            error.EndOfStream => error.ConnectionClosed,
            else => |e| e,
        };
        const reply = try wire.parse(raw);
        if (reply.header.response_to != id) return error.InvalidMessage;
        self.last_used = .now(self.io, .awake);
        return reply;
    }

    /// The handshake's command: legacy hello with `helloOk`, the client
    /// metadata, and the authentication bits.
    fn handshake(self: *Connection, settings: Settings, authenticate: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const cred: ?uri.Credential = if (authenticate) settings.credential else null;

        var m = try self.begin();
        const b = &self.builder;
        try b.append("isMaster", .{ .int32 = 1 });
        try b.append("helloOk", .{ .boolean = true });
        try b.append("client", .{ .document = .{ .bytes = settings.metadata } });
        var conversation: ?scram.Conversation = null;
        var x509_speculative = false;
        if (cred) |c| {
            if (c.mechanism == null) {
                const mechs = try std.fmt.allocPrint(arena, "{s}.{s}", .{ c.source, c.username.? });
                try b.append("saslSupportedMechs", .{ .string = mechs });
            }
            const m_scram: ?scram.Mechanism = if (c.mechanism) |mech| switch (mech) {
                .scram_sha_1 => .sha1,
                .scram_sha_256 => .sha256,
                else => null,
            } else .sha256;
            if (m_scram) |sm| {
                conversation = try newConversation(arena, self.io, sm, c);
                try b.beginDocument("speculativeAuthenticate");
                try appendSaslStart(b, arena, &conversation.?, c.source);
                try b.append("db", .{ .string = c.source });
                try b.end();
            } else if (c.mechanism.? == .x509) {
                x509_speculative = true;
                try b.beginDocument("speculativeAuthenticate");
                try appendX509(b, c);
                try b.end();
            }
        }
        try b.append("$db", .{ .string = "admin" });
        try m.endBody();
        const reply = try self.roundTrip(&m);
        const hello = reply.body;
        if (!sdam.okOf(hello)) {
            log.warn("mongodb {s}: handshake refused: {s}", .{ self.address.text, sdam.stringOf(hello.get("errmsg")) orelse "" });
            return error.HandshakeFailed;
        }
        self.readLimits(hello);

        const c = cred orelse return;
        // An arbiter takes no authentication.
        if (sdam.boolOf(hello.get("arbiterOnly"))) return;
        const speculative: ?bson.Document = if (hello.get("speculativeAuthenticate")) |v| switch (v) {
            .document => |d| try d.dupe(arena),
            else => null,
        } else null;
        const mechanism = c.mechanism orelse negotiated: {
            const mechs = hello.get("saslSupportedMechs");
            if (mechs) |v| if (v == .array) {
                var it = v.array.iterator();
                while (it.next()) |item| if (item == .string and std.mem.eql(u8, item.string, "SCRAM-SHA-256")) break :negotiated uri.Mechanism.scram_sha_256;
            };
            break :negotiated uri.Mechanism.scram_sha_1;
        };
        switch (mechanism) {
            .scram_sha_1, .scram_sha_256 => {
                const sm: scram.Mechanism = if (mechanism == .scram_sha_1) .sha1 else .sha256;
                if (speculative) |spec| {
                    if (conversation != null and conversation.?.mechanism == sm) return self.scramContinue(arena, settings, c, &conversation.?, spec);
                }
                var conv = try newConversation(arena, self.io, sm, c);
                return self.scramFull(arena, settings, c, &conv);
            },
            .plain => return self.plain(c),
            .x509 => {
                if (x509_speculative and speculative != null) return;
                return self.x509(c);
            },
            else => return error.UnsupportedAuthMechanism,
        }
    }

    fn readLimits(self: *Connection, hello: bson.Document) void {
        if (sdam.intOf(hello.get("maxBsonObjectSize"))) |n| if (n > 0) {
            self.max_bson_object_size = @intCast(n);
        };
        if (sdam.intOf(hello.get("maxMessageSizeBytes"))) |n| if (n > 0) {
            self.max_message_size = @intCast(n);
        };
        if (sdam.intOf(hello.get("maxWriteBatchSize"))) |n| if (n > 0) {
            self.max_write_batch_size = @intCast(n);
        };
        self.max_wire_version = @intCast(std.math.clamp(sdam.intOf(hello.get("maxWireVersion")) orelse 0, 0, std.math.maxInt(i32)));
        self.hello_ok = sdam.boolOf(hello.get("helloOk"));
        self.sessions = hello.get("logicalSessionTimeoutMinutes") != null;
    }

    /// saslStart, then saslContinue until done.
    fn scramFull(self: *Connection, arena: std.mem.Allocator, settings: Settings, c: uri.Credential, conv: *scram.Conversation) !void {
        var m = try self.begin();
        try m.b.append("saslStart", .{ .int32 = 1 });
        try appendSaslStart(m.b, arena, conv, c.source);
        try m.b.append("$db", .{ .string = c.source });
        try m.endBody();
        const reply = try self.roundTrip(&m);
        if (!sdam.okOf(reply.body)) return authError(self, reply.body);
        return self.scramContinue(arena, settings, c, conv, try reply.body.dupe(arena));
    }

    /// From the server-first message on (`first` is the saslStart reply, or
    /// the hello's `speculativeAuthenticate`).
    fn scramContinue(self: *Connection, arena: std.mem.Allocator, settings: Settings, c: uri.Credential, conv: *scram.Conversation, first: bson.Document) !void {
        const conversation_id = first.get("conversationId") orelse return error.AuthenticationFailed;
        const server_first = payloadOf(first) orelse return error.AuthenticationFailed;
        const client_final = conv.clientFinal(arena, self.io, settings.scram_cache, server_first) catch |err| {
            log.warn("mongodb {s}: SCRAM: {t}", .{ self.address.text, err });
            return error.AuthenticationFailed;
        };
        var reply_doc = try self.saslContinue(arena, c.source, conversation_id, client_final);
        const server_final = payloadOf(reply_doc) orelse return error.AuthenticationFailed;
        conv.verifyServerFinal(server_final) catch |err| {
            log.warn("mongodb {s}: SCRAM: {t}", .{ self.address.text, err });
            return error.AuthenticationFailed;
        };
        // Servers that ignore skipEmptyExchange want one more round.
        var rounds: u8 = 0;
        while (!sdam.boolOf(reply_doc.get("done"))) : (rounds += 1) {
            if (rounds == 2) return error.AuthenticationFailed;
            reply_doc = try self.saslContinue(arena, c.source, conversation_id, "");
        }
    }

    fn saslContinue(self: *Connection, arena: std.mem.Allocator, source: []const u8, conversation_id: bson.Value, payload: []const u8) !bson.Document {
        var m = try self.begin();
        try m.b.append("saslContinue", .{ .int32 = 1 });
        try m.b.append("conversationId", conversation_id);
        try m.b.append("payload", .{ .binary = .{ .data = payload } });
        try m.b.append("$db", .{ .string = source });
        try m.endBody();
        const reply = try self.roundTrip(&m);
        if (!sdam.okOf(reply.body)) return authError(self, reply.body);
        return reply.body.dupe(arena);
    }

    fn plain(self: *Connection, c: uri.Credential) !void {
        var buf: [1024]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "\x00{s}\x00{s}", .{ c.username.?, c.password.? }) catch return error.CredentialTooLong;
        var m = try self.begin();
        try m.b.append("saslStart", .{ .int32 = 1 });
        try m.b.append("mechanism", .{ .string = "PLAIN" });
        try m.b.append("payload", .{ .binary = .{ .data = payload } });
        try m.b.append("autoAuthorize", .{ .int32 = 1 });
        try m.b.append("$db", .{ .string = c.source });
        try m.endBody();
        std.crypto.secureZero(u8, &buf);
        const reply = try self.roundTrip(&m);
        if (!sdam.okOf(reply.body)) return authError(self, reply.body);
    }

    fn x509(self: *Connection, c: uri.Credential) !void {
        var m = try self.begin();
        try appendX509(m.b, c);
        try m.b.append("$db", .{ .string = "$external" });
        try m.endBody();
        const reply = try self.roundTrip(&m);
        if (!sdam.okOf(reply.body)) return authError(self, reply.body);
    }
};

fn authError(self: *const Connection, reply: bson.Document) error{AuthenticationFailed} {
    log.warn("mongodb {s}: authentication failed: {s}", .{ self.address.text, sdam.stringOf(reply.get("errmsg")) orelse "" });
    return error.AuthenticationFailed;
}

fn newConversation(arena: std.mem.Allocator, io: std.Io, m: scram.Mechanism, c: uri.Credential) !scram.Conversation {
    var random: [24]u8 = undefined;
    io.random(&random);
    return scram.Conversation.init(arena, m, c.username.?, c.password orelse "", random);
}

fn appendSaslStart(b: *bson.Builder, arena: std.mem.Allocator, conv: *const scram.Conversation, source: []const u8) !void {
    _ = source;
    try b.append("saslStart", .{ .int32 = 1 });
    try b.append("mechanism", .{ .string = conv.mechanism.name() });
    try b.append("payload", .{ .binary = .{ .data = try conv.clientFirst(arena) } });
    try b.append("autoAuthorize", .{ .int32 = 1 });
    try b.beginDocument("options");
    try b.append("skipEmptyExchange", .{ .boolean = true });
    try b.end();
}

fn appendX509(b: *bson.Builder, c: uri.Credential) !void {
    try b.append("authenticate", .{ .int32 = 1 });
    try b.append("mechanism", .{ .string = "MONGODB-X509" });
    if (c.username) |u| try b.append("user", .{ .string = u });
}

fn payloadOf(doc: bson.Document) ?[]const u8 {
    return switch (doc.get("payload") orelse return null) {
        .binary => |bin| bin.data,
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "Address: host and port, IPv6, Unix sockets" {
    const a = Address.parse("db.example:27018");
    try testing.expectEqualStrings("db.example", a.host);
    try testing.expectEqual(@as(u16, 27018), a.port);
    const v6 = Address.parse("[::1]:27019");
    try testing.expectEqualStrings("::1", v6.host);
    try testing.expectEqual(@as(u16, 27019), v6.port);
    const sock = Address.parse("/tmp/mongodb-27017.sock");
    try testing.expect(sock.unix);
}

test "clientMetadata: driver, os, platform, application" {
    const doc = try clientMetadata(testing.allocator, "my-api");
    defer testing.allocator.free(doc);
    const d = try bson.Document.init(doc);
    try testing.expectEqualStrings("anole", d.getPath("driver.name").?.string);
    try testing.expectEqualStrings("my-api", d.getPath("application.name").?.string);
    try testing.expect(d.getPath("os.type") != null);
}

test "replyError: ok 0, write errors, write concern errors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const failed = try bson.Document.init(try bson.encode(arena, .{ .ok = 0.0, .errmsg = "not primary", .code = 10107, .codeName = "NotWritablePrimary", .errorLabels = .{"RetryableWriteError"} }, .{}));
    const e = replyError(failed).?;
    try testing.expectEqual(@as(?i64, 10107), e.code);
    try testing.expect(e.hasLabel("RetryableWriteError"));
    const dup = try bson.Document.init(try bson.encode(arena, .{ .ok = 1, .n = 0, .writeErrors = .{.{ .index = 0, .code = 11000, .errmsg = "E11000 duplicate key" }} }, .{}));
    try testing.expectEqual(@as(?i64, 11000), replyError(dup).?.code);
    try testing.expectEqual(ServerError.Kind.write, replyError(dup).?.kind);
    const fine = try bson.Document.init(try bson.encode(arena, .{ .ok = 1, .n = 1 }, .{}));
    try testing.expect(replyError(fine) == null);
}
