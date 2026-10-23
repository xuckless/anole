// Adapted from vkiryakov/zefir src/nats/testing/FakeServer.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A NATS server for tests, on loopback. A test listens, starts its own
//! server function in a task (`io.concurrent`) and plays the server's side
//! of the protocol through a `Peer`:
//!
//! ```zig
//! var listener = try FakeServer.listen(io);
//! defer listener.deinit(io);
//! var server = try io.concurrent(serveHandshake, .{ io, &listener });
//! defer server.cancel(io) catch {};
//! ```
//!
//! The server function accepts one client with `Peer.accept` and closes the
//! socket itself when it returns; the test cancels it if it gets stuck.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ServerAddress = @import("../ServerAddress.zig");
const FakeServer = @This();

/// Listens on 127.0.0.1 on a free port.
pub fn listen(io: Io) !net.Server {
    const loopback: net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return loopback.listen(io, .{ .reuse_address = true });
}

/// The address a client dials to reach `listener`.
pub fn address(listener: *const net.Server) !ServerAddress {
    var buffer: [32]u8 = undefined;
    return ServerAddress.parse(try std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{listener.socket.address.getPort()}));
}

/// The `nats://` URL of `listener`, for `Options.servers`.
pub fn url(listener: *const net.Server, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "nats://127.0.0.1:{d}", .{listener.socket.address.getPort()});
}

/// The server's side of one client connection. It points into itself:
/// initialize it in place with `accept`.
pub const Peer = struct {
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    read_buffer: [16 * 1024]u8,
    write_buffer: [4096]u8,

    /// Waits for one client.
    pub fn accept(peer: *Peer, io: Io, listener: *net.Server) !void {
        const stream = try listener.accept(io);
        peer.io = io;
        peer.stream = stream;
        peer.reader = stream.reader(io, &peer.read_buffer);
        peer.writer = stream.writer(io, &peer.write_buffer);
    }

    pub fn close(peer: *Peer) void {
        peer.stream.close(peer.io);
    }

    /// Writes `bytes` at once.
    pub fn send(peer: *Peer, bytes: []const u8) !void {
        try peer.writer.interface.writeAll(bytes);
        try peer.writer.interface.flush();
    }

    /// The next line the client sent, without CR and LF. It stays valid
    /// until the next read.
    pub fn readLine(peer: *Peer) ![]const u8 {
        const line = try peer.reader.interface.takeDelimiterInclusive('\n');
        return std.mem.trimEnd(u8, line, "\r\n");
    }

    /// Like `readLine`, but null when the client has hung up.
    pub fn nextLine(peer: *Peer) !?[]const u8 {
        return peer.readLine() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => switch (peer.reader.err orelse error.Unexpected) {
                error.ConnectionResetByPeer => null,
                else => |e| e,
            },
            else => |e| e,
        };
    }

    pub fn expectLine(peer: *Peer, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, try peer.readLine());
    }

    /// Reads until the client closes the connection; returns how many
    /// bytes came.
    pub fn readToEnd(peer: *Peer) !usize {
        var total: usize = 0;
        while (true) {
            const n = peer.reader.interface.discard(.unlimited) catch |err| switch (err) {
                error.EndOfStream => return total,
                else => |e| return e,
            };
            total += n;
        }
    }

    /// Reads exactly `out.len` bytes.
    pub fn readExact(peer: *Peer, out: []u8) !void {
        try peer.reader.interface.readSliceAll(out);
    }
};
