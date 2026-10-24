//! What the HTTP/3 server and client share: socket addresses as ngtcp2
//! takes them, connection IDs as map keys, and the clocks.
const std = @import("std");
const c = @import("ngtcp2.zig").c;

/// A socket address as ngtcp2 takes it.
pub const Addr = struct {
    storage: std.Io.Threaded.PosixAddress = undefined,
    len: std.posix.socklen_t = 0,

    pub fn from(address: std.Io.net.IpAddress) Addr {
        var a: Addr = .{};
        a.len = std.Io.Threaded.addressToPosix(&address, &a.storage);
        return a;
    }

    pub fn fromNgtcp2(addr: c.ngtcp2_addr) Addr {
        var a: Addr = .{};
        const len: usize = @intCast(addr.addrlen);
        @memcpy(std.mem.asBytes(&a.storage)[0..len], @as([*]const u8, @ptrCast(addr.addr))[0..len]);
        a.len = @intCast(len);
        return a;
    }

    pub fn ip(self: *const Addr) std.Io.net.IpAddress {
        return std.Io.Threaded.addressFromPosix(&self.storage);
    }

    pub fn ngtcp2Addr(self: *Addr) c.ngtcp2_addr {
        return .{ .addr = @ptrCast(&self.storage), .addrlen = @intCast(self.len) };
    }
};

/// A connection ID as a map key.
pub const CidKey = struct {
    len: u8,
    bytes: [c.NGTCP2_MAX_CIDLEN]u8,

    /// Null when `data` is longer than any connection ID can be.
    pub fn of(data: []const u8) ?CidKey {
        if (data.len > c.NGTCP2_MAX_CIDLEN) return null;
        var k: CidKey = .{ .len = @intCast(data.len), .bytes = @splat(0) };
        @memcpy(k.bytes[0..data.len], data);
        return k;
    }

    /// An ID ngtcp2 made or decoded, so never over the limit.
    pub fn ofCid(cid: *const c.ngtcp2_cid) CidKey {
        return of(cid.data[0..@min(cid.datalen, c.NGTCP2_MAX_CIDLEN)]).?;
    }
};

/// What a server endpoint makes of a datagram from its first bytes.
pub const Incoming = union(enum) {
    /// Not for us: malformed, a Version Negotiation packet (servers never
    /// take one), or a long header with an ID longer than QUIC allows.
    drop,
    /// A long header with a version we do not speak.
    version_negotiation: c.ngtcp2_version_cid,
    /// A packet to look up by its destination ID.
    packet: struct { vc: c.ngtcp2_version_cid, dcid: CidKey },
};

/// Classifies `data` (one datagram); `short_dcidlen` is the length of the
/// server's own IDs.
pub fn classify(data: []const u8, short_dcidlen: usize) Incoming {
    if (data.len == 0) return .drop;
    var vc: c.ngtcp2_version_cid = undefined;
    switch (c.ngtcp2_pkt_decode_version_cid(&vc, data.ptr, data.len, short_dcidlen)) {
        0 => {},
        // Echoed back as they came, whatever their length (RFC 8999).
        c.NGTCP2_ERR_VERSION_NEGOTIATION => return .{ .version_negotiation = vc },
        else => return .drop,
    }
    // ngtcp2 checks the ID lengths only for the versions it speaks, and
    // reports a Version Negotiation packet (version 0) as a success.
    if (data[0] & 0x80 != 0 and vc.version == 0) return .drop;
    if (vc.scidlen > c.NGTCP2_MAX_CIDLEN) return .drop;
    const dcid = CidKey.of(vc.dcid[0..vc.dcidlen]) orelse return .drop;
    return .{ .packet = .{ .vc = vc, .dcid = dcid } };
}

/// For nghttp3's `rand` callback, which gets no user data: the `Io` the
/// last endpoint or client was made with.
pub var rand_io: ?std.Io = null;

pub fn h3Rand(dest: [*c]u8, len: usize) callconv(.c) void {
    (rand_io orelse unreachable).random(dest[0..len]);
}

/// ngtcp2's monotonic timestamps, in nanoseconds.
pub fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// Wall-clock nanoseconds, for address validation tokens.
pub fn wallClock(io: std.Io) u64 {
    return @intCast(std.Io.Clock.real.now(io).nanoseconds);
}

/// The UDP socket and its helpers live in src/net/udp.zig (shared with raw
/// UDP listeners); these names stay for the HTTP/3 code.
const udp = @import("../net/udp.zig");
pub const Udp = udp.Udp;
pub const bindReusePort = udp.bindReusePort;
pub const checkUdpAddressFree = udp.checkUdpAddressFree;
pub const isIpv4Mapped = udp.isIpv4Mapped;

const cmsg_align = std.Io.net.cmsg_align;
const native_endian = @import("builtin").cpu.arch.endian();
const log = std.log.scoped(.anole_h3);

fn rep(comptime ch: u8, comptime n: usize) *const [n]u8 {
    const a: [n]u8 = @splat(ch);
    return &a;
}

fn longHeader(buf: []u8, version: u32, dcidlen: u8, len: usize) []u8 {
    @memset(buf[0..len], 0xab);
    buf[0] = 0xc0;
    std.mem.writeInt(u32, buf[1..5], version, .big);
    buf[5] = dcidlen;
    buf[6 + @as(usize, dcidlen)] = 0;
    return buf[0..len];
}

test "classify: long-header IDs over 20 bytes, and Version Negotiation packets, are dropped" {
    var buf: [1300]u8 = undefined;
    // Version 0 with a 200-byte ID: ngtcp2 decodes it as a success.
    try std.testing.expect(classify(longHeader(&buf, 0, 200, 208), 18) == .drop);
    try std.testing.expect(classify(longHeader(&buf, 0, 21, 28), 18) == .drop);
    // Version 0 with a valid ID length: still not for a server.
    try std.testing.expect(classify(longHeader(&buf, 0, 8, 16), 18) == .drop);
    // Version 1 with a 21-byte ID.
    try std.testing.expect(classify(longHeader(&buf, 1, 21, 1300), 18) == .drop);
    // Version 1 with a 20-byte ID: looked up.
    switch (classify(longHeader(&buf, 1, 20, 1300), 18)) {
        .packet => |p| try std.testing.expectEqual(@as(u8, 20), p.dcid.len),
        else => return error.TestUnexpectedResult,
    }
    // An unknown version, padded: answered with Version Negotiation.
    try std.testing.expect(classify(longHeader(&buf, 0x1a2a3a4a, 200, 1300), 18) == .version_negotiation);
    // Short header: our ID length, version 0 as ngtcp2 reports it.
    @memset(&buf, 0x41);
    buf[0] = 0x40;
    switch (classify(buf[0..40], 18)) {
        .packet => |p| try std.testing.expectEqual(@as(u8, 18), p.dcid.len),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(classify(buf[0..5], 18) == .drop);
    try std.testing.expect(classify(buf[0..0], 18) == .drop);
    try std.testing.expect(CidKey.of(&@as([21]u8, @splat(0))) == null);
}

test "fuzz: the endpoint's first look at a datagram never yields an ID over 20 bytes" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            switch (classify(input, 18)) {
                .drop => {},
                .version_negotiation => |vc| {
                    // Echoed back: a reply must fit the largest UDP payload.
                    var out: [c.NGTCP2_MAX_UDP_PAYLOAD_SIZE]u8 = undefined;
                    const versions = [_]u32{ 0x0a0a0a0a, c.NGTCP2_PROTO_VER_V1 };
                    _ = c.ngtcp2_pkt_write_version_negotiation(&out, out.len, 0, vc.scid, vc.scidlen, vc.dcid, vc.dcidlen, &versions, versions.len);
                },
                .packet => |p| {
                    try std.testing.expect(p.dcid.len <= c.NGTCP2_MAX_CIDLEN);
                    try std.testing.expect(p.vc.scidlen <= c.NGTCP2_MAX_CIDLEN);
                    try std.testing.expectEqualSlices(u8, p.vc.dcid[0..p.vc.dcidlen], p.dcid.bytes[0..p.dcid.len]);
                },
            }
        }
    }.check, &.{
        "\xc0\x00\x00\x00\x00\xc8" ++ rep('a', 200) ++ "\x00",
        "\xc0\x00\x00\x00\x00\x15" ++ rep('a', 21) ++ "\x00",
        "\xc0\x00\x00\x00\x01\x14" ++ rep('a', 20) ++ "\x08" ++ rep('b', 8) ++ rep('c', 1200),
        "\xc0\x1a\x2a\x3a\x4a\xc8" ++ rep('a', 200) ++ "\x00" ++ rep('c', 1100),
        "\x40" ++ rep('a', 30),
    });
}
