//! Connection-ID steering for per-core UDP sockets (Linux): one
//! SO_REUSEPORT socket per endpoint, all bound to one address, and a
//! classic BPF program on the group that sends each datagram to the socket
//! whose endpoint owns its connection.
//!
//! The server's connection IDs are `cid_len` bytes with the owning
//! endpoint's index in byte `index_byte` (the rest random). The program
//! reads that byte from the destination connection ID and returns it as the
//! socket's index in the group; the kernel numbers a group's sockets in the
//! order they were bound (socket(7)), so the endpoints bind in index order.
//! A long-header packet with no such ID (a client's first Initials and its
//! 0-RTT packets, with a connection ID of its own choosing) goes by that
//! ID's first byte, modulo the group's size: by the ID alone, not the
//! 4-tuple, so a client whose address changes before the server's first
//! reply reaches it (a NAT rebinding during the handshake) still reaches
//! the endpoint that holds its connection, rather than starting a second
//! one on another. Whatever else carries no ID of ours (a short header
//! naming another index, a truncated datagram) gets an index out of range,
//! and for that the kernel falls back to its usual 4-tuple hash. Linux 4.5
//! and later; without the program (an older kernel) the hash decides, and
//! the endpoints pass packets for each other on in user space instead, by
//! the same rules (`indexOf`).
//!
//! For classic BPF on a reuseport group the kernel moves the data past the
//! UDP header first (`run_bpf_filter` in net/core/sock_reuseport.c), so
//! absolute offset 0 is the first byte of the QUIC packet, and `len` the
//! UDP payload's length. In a long header the destination connection ID's
//! length is at offset 5 and the ID at 6; in a short header the ID starts at
//! offset 1, with no length (the receiver knows it).
const std = @import("std");
const builtin = @import("builtin");

/// The length of the server's connection IDs.
pub const cid_len = 18;
/// Which byte of them carries the endpoint's index.
pub const index_byte = 1;
/// Endpoints one group can steer to: one byte's worth.
pub const max_sockets = 255;

/// `struct sock_filter`.
pub const Insn = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

/// `struct sock_fprog`.
const Program = extern struct {
    len: u16,
    filter: [*]const Insn,
};

// Classic BPF opcodes (linux/bpf_common.h).
const LD = 0x00;
const JMP = 0x05;
const RET = 0x06;
const W = 0x00;
const B = 0x10;
const ABS = 0x20;
const LEN = 0x80;
const JEQ = 0x10;
const JGE = 0x30;
const JSET = 0x40;
const ALU = 0x04;
const MOD = 0x90;
const K = 0x00;
const A = 0x10;

/// "Not mine to say": out of range for any group, so the kernel hashes.
pub const no_index: u32 = 0xffffffff;

const long_index_at = 6 + index_byte;
const short_index_at = 1 + index_byte;

/// Where a long header's destination connection ID starts.
const long_dcid_at = 6;

/// The program for a group of `sockets` sockets.
pub fn program(sockets: u8) [15]Insn {
    const n: u32 = sockets;
    return .{
        // 0: Too short to hold the byte either way: hash.
        .{ .code = LD | W | LEN, .jt = 0, .jf = 0, .k = 0 },
        .{ .code = JMP | JGE | K, .jt = 0, .jf = 12, .k = long_index_at + 1 },
        // 2: Long header (the top bit) or short.
        .{ .code = LD | B | ABS, .jt = 0, .jf = 0, .k = 0 },
        .{ .code = JMP | JSET | K, .jt = 0, .jf = 7, .k = 0x80 },
        // 4: Long: an ID of our length naming a socket is ours.
        .{ .code = LD | B | ABS, .jt = 0, .jf = 0, .k = 5 },
        .{ .code = JMP | JEQ | K, .jt = 0, .jf = 2, .k = cid_len },
        .{ .code = LD | B | ABS, .jt = 0, .jf = 0, .k = long_index_at },
        .{ .code = JMP | JGE | K, .jt = 0, .jf = 5, .k = n },
        // 8: Long, the client's own ID: its first byte, modulo the group.
        .{ .code = LD | B | ABS, .jt = 0, .jf = 0, .k = long_dcid_at },
        .{ .code = ALU | MOD | K, .jt = 0, .jf = 0, .k = n },
        .{ .code = RET | A, .jt = 0, .jf = 0, .k = 0 },
        // 11: Short.
        .{ .code = LD | B | ABS, .jt = 0, .jf = 0, .k = short_index_at },
        .{ .code = JMP | JGE | K, .jt = 1, .jf = 0, .k = n },
        // 13: The socket.
        .{ .code = RET | A, .jt = 0, .jf = 0, .k = 0 },
        // 14: The hash.
        .{ .code = RET | K, .jt = 0, .jf = 0, .k = no_index },
    };
}

/// The index the program would pick for `sockets` sockets, by the same
/// rules, for user space: the endpoint a datagram belongs to, or null when
/// the kernel's hash decides.
pub fn indexOf(packet: []const u8, sockets: usize) ?u8 {
    if (packet.len < long_index_at + 1) return null;
    if (packet[0] & 0x80 != 0) {
        if (packet[5] == cid_len and packet[long_index_at] < sockets) return packet[long_index_at];
        return @intCast(packet[long_dcid_at] % sockets);
    }
    const i = packet[short_index_at];
    return if (i < sockets) i else null;
}

/// Attaches the program for `sockets` sockets to the group `fd` belongs to
/// (any one of its sockets will do; it applies to all, and replaces any
/// program there). Linux only.
pub fn attach(fd: std.posix.fd_t, sockets: u8) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const insns = program(sockets);
    const prog: Program = .{ .len = insns.len, .filter = &insns };
    const linux = std.os.linux;
    const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.ATTACH_REUSEPORT_CBPF, std.mem.asBytes(&prog), @sizeOf(Program));
    if (linux.errno(rc) != .SUCCESS) return error.SteeringUnavailable;
}

/// Takes the program off the group again (Linux 5.3 and later): the kernel
/// hashes from then on. For tests of the user-space fallback.
pub fn detach(fd: std.posix.fd_t) !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const zero: c_int = 0;
    const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.DETACH_REUSEPORT_BPF, std.mem.asBytes(&zero), @sizeOf(c_int));
    if (linux.errno(rc) != .SUCCESS) return error.SteeringUnavailable;
}

/// Runs a classic BPF program over `packet` as the kernel would, for the
/// instructions `program` uses; a load past the end returns 0, as there.
fn interpret(insns: []const Insn, packet: []const u8) u32 {
    var a: u32 = 0;
    var pc: usize = 0;
    while (pc < insns.len) {
        const i = insns[pc];
        pc += 1;
        switch (i.code) {
            LD | W | LEN => a = @intCast(packet.len),
            LD | B | ABS => {
                if (i.k >= packet.len) return 0;
                a = packet[i.k];
            },
            JMP | JGE | K => pc += if (a >= i.k) i.jt else i.jf,
            JMP | JEQ | K => pc += if (a == i.k) i.jt else i.jf,
            JMP | JSET | K => pc += if (a & i.k != 0) i.jt else i.jf,
            ALU | MOD | K => a %= i.k,
            RET | A => return a,
            RET | K => return i.k,
            else => unreachable,
        }
    }
    unreachable;
}

/// A long-header packet with this destination connection ID.
fn longPacket(buf: []u8, dcid: []const u8) []const u8 {
    buf[0] = 0xc0;
    std.mem.writeInt(u32, buf[1..5], 1, .big);
    buf[5] = @intCast(dcid.len);
    @memcpy(buf[6..][0..dcid.len], dcid);
    // An SCID, a token length, a payload: what follows does not matter.
    @memset(buf[6 + dcid.len ..][0..40], 0x55);
    return buf[0 .. 6 + dcid.len + 40];
}

fn shortPacket(buf: []u8, dcid: []const u8) []const u8 {
    buf[0] = 0x40;
    @memcpy(buf[1..][0..dcid.len], dcid);
    @memset(buf[1 + dcid.len ..][0..30], 0xaa);
    return buf[0 .. 1 + dcid.len + 30];
}

fn ourCid(index: u8) [cid_len]u8 {
    var cid: [cid_len]u8 = @splat(0x9c);
    cid[index_byte] = index;
    return cid;
}

test "steering program: our IDs go to their socket, anything else to the hash" {
    var buf: [128]u8 = undefined;
    const prog = program(4);
    for (0..4) |i| {
        const cid = ourCid(@intCast(i));
        try std.testing.expectEqual(@as(u32, @intCast(i)), interpret(&prog, shortPacket(&buf, &cid)));
        try std.testing.expectEqual(@as(u32, @intCast(i)), interpret(&prog, longPacket(&buf, &cid)));
        try std.testing.expectEqual(@as(?u8, @intCast(i)), indexOf(shortPacket(&buf, &cid), 4));
        try std.testing.expectEqual(@as(?u8, @intCast(i)), indexOf(longPacket(&buf, &cid), 4));
    }
    // A short header naming an index past the group's last socket: the
    // hash. A long one: its first byte (0x9c) modulo the group.
    const beyond = ourCid(4);
    try std.testing.expectEqual(no_index, interpret(&prog, shortPacket(&buf, &beyond)));
    try std.testing.expectEqual(@as(u32, 0x9c % 4), interpret(&prog, longPacket(&buf, &beyond)));
    try std.testing.expectEqual(@as(?u8, null), indexOf(shortPacket(&buf, &beyond), 4));
    try std.testing.expectEqual(@as(?u8, 0x9c % 4), indexOf(longPacket(&buf, &beyond), 4));
    // A client's first Initial: its own 8-byte ID, by its first byte, so
    // the same socket whatever address the client sends from.
    for ([_]u8{ 0, 1, 6, 255 }) |first| {
        const client_cid = [_]u8{ first, 1, 2, 3, 4, 5, 6, 7 };
        try std.testing.expectEqual(@as(u32, first % 4), interpret(&prog, longPacket(&buf, &client_cid)));
        try std.testing.expectEqual(@as(?u8, first % 4), indexOf(longPacket(&buf, &client_cid), 4));
        try std.testing.expectEqual(@as(u32, first % 3), interpret(&program(3), longPacket(&buf, &client_cid)));
    }
    // A 20-byte ID: not ours either.
    var twenty: [20]u8 = @splat(1);
    try std.testing.expectEqual(@as(u32, 1), interpret(&prog, longPacket(&buf, &twenty)));
    twenty = @splat(7);
    try std.testing.expectEqual(@as(u32, 3), interpret(&prog, longPacket(&buf, &twenty)));
    // Truncated before the byte, both ways, and empty.
    const cid = ourCid(2);
    const long = longPacket(&buf, &cid);
    try std.testing.expectEqual(no_index, interpret(&prog, long[0..long_index_at]));
    try std.testing.expectEqual(@as(u32, 2), interpret(&prog, long[0 .. long_index_at + 1]));
    try std.testing.expectEqual(@as(?u8, null), indexOf(long[0..long_index_at], 4));
    try std.testing.expectEqual(no_index, interpret(&prog, &.{}));
    try std.testing.expectEqual(no_index, interpret(&prog, &.{0x40}));
    // One socket: there is nothing to choose.
    try std.testing.expectEqual(no_index, interpret(&program(1), shortPacket(&buf, &ourCid(1))));
    try std.testing.expectEqual(@as(u32, 0), interpret(&program(1), shortPacket(&buf, &ourCid(0))));
    try std.testing.expectEqual(@as(u32, 0), interpret(&program(1), longPacket(&buf, &[_]u8{ 9, 9, 9, 9, 9, 9, 9, 9 })));
}

test "fuzz: the steering program and indexOf agree, and never pick a socket past the group" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (input.len == 0) return;
            // The first byte picks the group size, the rest is the packet.
            const sockets: u8 = @max(1, input[0]);
            const packet = input[1..];
            const got = interpret(&program(sockets), packet);
            const want = indexOf(packet, sockets);
            if (want) |i| {
                try std.testing.expectEqual(@as(u32, i), got);
            } else {
                try std.testing.expectEqual(no_index, got);
            }
        }
    }.check, &.{
        "\x04\x40\x00\x02aaaaaaaaaaaaaaaaaaaaaaaa",
        "\x04\xc0\x00\x00\x00\x01\x12\x00\x03aaaaaaaaaaaaaaaaaaaaaaaa",
        "\x04\xc0\x00\x00\x00\x01\x08\x00\x03aaaaaaaaaaaaaaaaaaaaaaaa",
        "\x02\xc0\x00",
        "\x01",
    });
}

test "steering in the kernel: each datagram reaches the socket its ID names" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // SO_ATTACH_REUSEPORT_CBPF is Linux only (steering is off elsewhere)
    const wait = @import("anole_test_wait");
    const net = @import("net.zig");
    const posix = std.posix;
    const sockets = 4;
    var fds: [sockets]posix.fd_t = undefined;
    var bound: usize = 0;
    defer for (fds[0..bound]) |fd| {
        _ = std.c.close(fd);
    };
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    for (&fds) |*fd| {
        fd.* = try net.bindReusePort(address, null);
        bound += 1;
        address = boundAddress(fd.*);
    }
    try attach(fds[0], sockets);
    const client = try net.bindReusePort(.{ .ip4 = .loopback(0) }, null);
    defer _ = std.c.close(client);

    var buf: [128]u8 = undefined;
    var rx: [256]u8 = undefined;
    for (0..4) |round| {
        for (0..sockets) |i| {
            const cid = ourCid(@intCast(i));
            // Round 3: a client's own ID, by its first byte.
            const client_cid = [_]u8{ @intCast(i + sockets), 0xee, 2, 3, 4, 5, 6, 7 };
            const packet = switch (round) {
                1 => longPacket(&buf, &cid),
                3 => longPacket(&buf, &client_cid),
                else => shortPacket(&buf, &cid),
            };
            try sendTo(client, address, packet);
            // Socket i has it (the wait is a hang guard: a datagram steered
            // elsewhere never reaches i, and the wait fails)...
            try std.testing.expect(receiveOurs(fds[i], &rx, packet, @intCast(wait.deadlineMs())));
            // ...and, delivered once, no other socket has it as well.
            for (fds, 0..) |fd, j| {
                if (j == i) continue;
                try std.testing.expect(!receiveOurs(fd, &rx, packet, 0));
            }
        }
    }
    // Detached: the hash decides; exactly one socket receives it.
    try detach(fds[0]);
    const cid = ourCid(3);
    const last = shortPacket(&buf, &cid);
    try sendTo(client, address, last);
    const first = receiveOursAny(&fds, &rx, last, @intCast(wait.deadlineMs())) orelse return error.TestUnexpectedResult;
    for (fds, 0..) |fd, j| {
        if (j == first) continue;
        try std.testing.expect(!receiveOurs(fd, &rx, last, 0));
    }
}

fn boundAddress(fd: std.posix.fd_t) std.Io.net.IpAddress {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    std.debug.assert(std.c.getsockname(fd, &storage.any, &len) == 0);
    return std.Io.Threaded.addressFromPosix(&storage);
}

fn sendTo(fd: std.posix.fd_t, to: std.Io.net.IpAddress, data: []const u8) !void {
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&to, &storage);
    if (std.c.sendto(fd, data.ptr, data.len, 0, &storage.any, len) != @as(isize, @intCast(data.len))) return error.SendFailed;
}

/// Whether `packet` reached `fd` within `timeout_ms` (0: already queued).
/// The sockets sit on an ephemeral loopback port, which another test's
/// QUIC client may still be sending to (a 1200-byte datagram, cut to
/// `buf`'s length): datagrams that are not `packet` are skipped, not
/// counted.
fn receiveOurs(fd: std.posix.fd_t, buf: []u8, packet: []const u8, timeout_ms: i32) bool {
    while (receiveWithin(fd, buf, timeout_ms)) |n| {
        if (std.mem.eql(u8, buf[0..n], packet)) return true;
    }
    return false;
}

/// The index of the first of `fds` that `packet` reaches within
/// `timeout_ms`, or null; other datagrams are skipped as in `receiveOurs`.
fn receiveOursAny(fds: []const std.posix.fd_t, buf: []u8, packet: []const u8, timeout_ms: i32) ?usize {
    var pfds: [8]std.c.pollfd = undefined;
    for (fds, pfds[0..fds.len]) |fd, *p| p.* = .{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 };
    while (true) {
        for (pfds[0..fds.len]) |*p| p.revents = 0;
        if (std.c.poll(&pfds, @intCast(fds.len), timeout_ms) <= 0) return null;
        for (pfds[0..fds.len], 0..) |p, i| {
            if (p.revents & std.c.POLL.IN == 0) continue;
            const n = std.c.recv(p.fd, buf.ptr, buf.len, 0);
            if (n >= 0 and std.mem.eql(u8, buf[0..@intCast(n)], packet)) return i;
        }
    }
}

/// A datagram waiting on `fd` within `timeout_ms`, or null.
fn receiveWithin(fd: std.posix.fd_t, buf: []u8, timeout_ms: i32) ?usize {
    var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&pfd, 1, timeout_ms) <= 0) return null;
    const n = std.c.recv(fd, buf.ptr, buf.len, 0);
    return if (n < 0) null else @intCast(n);
}
