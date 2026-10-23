//! SASL over Kafka's SaslHandshake (v1) and SaslAuthenticate (v1): PLAIN
//! and SCRAM-SHA-256/512 (the exchange itself is src/net/scram.zig).
//! Kafka sends the SCRAM password unprepared, as Java's ScramFormatter does.
const std = @import("std");
const protocol = @import("protocol.zig");
const scram = @import("../net/scram.zig");
const cluster = @import("cluster.zig");

const log = std.log.scoped(.anole);

pub const Mechanism = enum {
    plain,
    scram_sha_256,
    scram_sha_512,

    pub fn name(m: Mechanism) []const u8 {
        return switch (m) {
            .plain => "PLAIN",
            .scram_sha_256 => "SCRAM-SHA-256",
            .scram_sha_512 => "SCRAM-SHA-512",
        };
    }
};

pub const Credential = struct {
    mechanism: Mechanism,
    username: []const u8,
    password: []const u8,
};

/// PLAIN's message (RFC 4616): authzid (empty), user, password.
pub fn plainMessage(arena: std.mem.Allocator, username: []const u8, password: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "\x00{s}\x00{s}", .{ username, password });
}

/// Handshake and authenticate `conn`, which must have just connected.
pub fn authenticate(conn: *cluster.Conn, arena: std.mem.Allocator, cred: Credential, cache: *scram.Cache) cluster.ConnError!void {
    var e: protocol.Enc = .init(arena);
    try protocol.encodeSaslHandshake(&e, cred.mechanism.name());
    const reply = try conn.call(arena, .sasl_handshake, e.bytesWritten(), conn.settings.request_timeout);
    const hec = try protocol.decodeSimpleErrorFirst(reply);
    if (hec != 0) {
        log.warn("kafka {s}:{d}: SASL {s} refused: {s}", .{ conn.host, conn.port, cred.mechanism.name(), protocol.errorName(hec) });
        return error.AuthFailed;
    }
    switch (cred.mechanism) {
        .plain => {
            const msg = try plainMessage(arena, cred.username, cred.password);
            _ = try exchange(conn, arena, msg);
        },
        .scram_sha_256, .scram_sha_512 => {
            const m: scram.Mechanism = if (cred.mechanism == .scram_sha_256) .sha256 else .sha512;
            var random: [24]u8 = undefined;
            conn.io.random(&random);
            var conv = scram.Conversation.init(arena, m, cred.username, cred.password, random, .none) catch return error.AuthFailed;
            const first = conv.clientFirst(arena) catch return error.OutOfMemory;
            const server_first = try exchange(conn, arena, first);
            const final = conv.clientFinal(arena, conn.io, cache, server_first) catch |err| {
                log.warn("kafka {s}:{d}: SCRAM exchange failed: {t}", .{ conn.host, conn.port, err });
                return error.AuthFailed;
            };
            const server_final = try exchange(conn, arena, final);
            conv.verifyServerFinal(server_final) catch |err| {
                log.warn("kafka {s}:{d}: SCRAM server proof failed: {t}", .{ conn.host, conn.port, err });
                return error.AuthFailed;
            };
        },
    }
}

fn exchange(conn: *cluster.Conn, arena: std.mem.Allocator, message: []const u8) cluster.ConnError![]const u8 {
    var e: protocol.Enc = .init(arena);
    try protocol.encodeSaslAuthenticate(&e, message);
    const body = try conn.call(arena, .sasl_authenticate, e.bytesWritten(), conn.settings.request_timeout);
    const r = protocol.decodeSaslAuthenticate(arena, body) catch return error.ProtocolError;
    if (r.error_code != 0) {
        log.warn("kafka {s}:{d}: SASL authentication failed: {s}{s}{s}", .{ conn.host, conn.port, protocol.errorName(r.error_code), if (r.message != null) ": " else "", r.message orelse "" });
        return error.AuthFailed;
    }
    return r.auth;
}
