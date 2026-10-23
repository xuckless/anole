// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! The PROXY protocol (HAProxy, versions 1 and 2): the header a load
//! balancer such as HAProxy, nginx's stream module, AWS NLB or Envoy puts in
//! front of a connection to say who the client really is. Spec:
//! https://www.haproxy.org/download/3.0/doc/proxy-protocol.txt
//!
//! `read` takes the header off a freshly accepted socket, before TLS. It
//! reads exactly the header's bytes and no more, so what follows (a TLS
//! ClientHello, the first request) is still on the socket for whoever reads
//! next. The parsing is separate (`parseV1`, `parseV2`) and does no I/O.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;
/// CRC-32C, named differently in Zig 0.16 and 0.17.
const Crc32c = if (@hasDecl(std.hash.crc, "Crc32Iscsi")) std.hash.crc.Crc32Iscsi else std.hash.crc.@"CRC-32/ISCSI";

/// What the header says about the connection.
pub const Header = struct {
    /// The client's address. Null when the header carries none to use: a
    /// LOCAL command (the proxy's own health check), v1 UNKNOWN, an
    /// unspecified family, or a Unix socket. The socket peer stands then.
    source: ?IpAddress = null,
    destination: ?IpAddress = null,
    /// v2 only: the PP2_TYPE_SSL TLV says the client spoke TLS to the
    /// proxy.
    ssl: bool = false,
};

pub const Error = error{InvalidProxyHeader};

/// An address range in CIDR notation ("10.0.0.0/8", "2001:db8::/32", or a
/// single address), for `Listener.proxy_protocol_from`: the peers allowed
/// to send a PROXY header.
pub const Network = struct {
    /// Its first address (the bits past `prefix_len` are zero); the port
    /// is not used.
    address: IpAddress,
    prefix_len: u8,

    /// Parses "address/prefix" or a bare address (a /32 or /128). Host
    /// bits past the prefix are refused, as a likely typo.
    pub fn parse(text: []const u8) error{InvalidNetwork}!Network {
        const slash = std.mem.indexOfScalar(u8, text, '/');
        const address = IpAddress.parse(text[0 .. slash orelse text.len], 0) catch return error.InvalidNetwork;
        const bits: u8 = if (address == .ip4) 32 else 128;
        const prefix_len: u8 = if (slash) |at| blk: {
            const digits = text[at + 1 ..];
            if (digits.len == 0 or digits.len > 3) return error.InvalidNetwork;
            for (digits) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidNetwork;
            break :blk std.fmt.parseInt(u8, digits, 10) catch return error.InvalidNetwork;
        } else bits;
        if (prefix_len > bits) return error.InvalidNetwork;
        const net: Network = .{ .address = address, .prefix_len = prefix_len };
        const b = net.bytes();
        for (b, 0..) |byte, i| {
            if (byte & ~prefixMask(prefix_len, i) != 0) return error.InvalidNetwork;
        }
        return net;
    }

    /// Whether `peer` is inside the range. An IPv4-mapped IPv6 peer (from
    /// a dual-stack socket) is compared as IPv4.
    pub fn contains(self: Network, peer: IpAddress) bool {
        const p = unmap(peer);
        if ((p == .ip4) != (self.address == .ip4)) return false;
        const want = self.bytes();
        const have: []const u8 = switch (p) {
            .ip4 => |a| &a.bytes,
            .ip6 => |a| &a.bytes,
        };
        for (want, have, 0..) |w, h, i| {
            if ((w ^ h) & prefixMask(self.prefix_len, i) != 0) return false;
        }
        return true;
    }

    fn bytes(self: *const Network) []const u8 {
        return switch (self.address) {
            .ip4 => |*a| &a.bytes,
            .ip6 => |*a| &a.bytes,
        };
    }

    /// The mask of byte `i` under a prefix of `len` bits.
    fn prefixMask(len: u8, i: usize) u8 {
        const start = i * 8;
        if (len >= start + 8) return 0xff;
        if (len <= start) return 0;
        const keep: u3 = @intCast(len - start);
        return @as(u8, 0xff) << @intCast(@as(u4, 8) - keep);
    }

    /// "10.0.0.0/8", "::1/128".
    pub fn format(self: Network, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.address) {
            .ip4 => |a| try w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
            .ip6 => |a| {
                const plain: IpAddress = .{ .ip6 = .{ .bytes = a.bytes, .port = 0 } };
                // IpAddress prints "[addr]:port"; the network wants the bare address.
                var buf: [64]u8 = undefined;
                var fw: std.Io.Writer = .fixed(&buf);
                fw.print("{f}", .{plain}) catch {};
                const text = fw.buffered();
                const close = std.mem.indexOfScalar(u8, text, ']') orelse text.len;
                try w.writeAll(text[@min(1, close)..close]);
            },
        }
        try w.print("/{d}", .{self.prefix_len});
    }

    pub fn unmap(address: IpAddress) IpAddress {
        const a = switch (address) {
            .ip4 => return address,
            .ip6 => |a| a,
        };
        const prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
        if (!std.mem.eql(u8, a.bytes[0..12], &prefix)) return address;
        return .{ .ip4 = .{ .bytes = a.bytes[12..16].*, .port = a.port } };
    }
};

/// Whether `peer` may send a PROXY header: inside one of `trusted`, or
/// any peer when `trusted` is empty.
pub fn trustedPeer(trusted: []const Network, peer: IpAddress) bool {
    if (trusted.len == 0) return true;
    for (trusted) |net| if (net.contains(peer)) return true;
    return false;
}

fn v4net(a: u8, b: u8, c: u8, d: u8, len: u8) Network {
    return .{ .address = .{ .ip4 = .{ .bytes = .{ a, b, c, d }, .port = 0 } }, .prefix_len = len };
}

fn v6net(first: u16, len: u8) Network {
    var bytes: [16]u8 = @splat(0);
    bytes[0] = @intCast(first >> 8);
    bytes[1] = @intCast(first & 0xff);
    return .{ .address = .{ .ip6 = .{ .bytes = bytes, .port = 0 } }, .prefix_len = len };
}

fn v6loopback() Network {
    var bytes: [16]u8 = @splat(0);
    bytes[15] = 1;
    return .{ .address = .{ .ip6 = .{ .bytes = bytes, .port = 0 } }, .prefix_len = 128 };
}

/// The named groups of `proxy.trusted`.
pub const networks = struct {
    /// 127.0.0.0/8, ::1/128.
    pub const loopback = [_]Network{
        v4net(127, 0, 0, 0, 8),
        v6loopback(),
    };
    /// 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7.
    pub const private = [_]Network{ v4net(10, 0, 0, 0, 8), v4net(172, 16, 0, 0, 12), v4net(192, 168, 0, 0, 16), v6net(0xfc00, 7) };
    /// 169.254.0.0/16, fe80::/10.
    pub const link_local = [_]Network{ v4net(169, 254, 0, 0, 16), v6net(0xfe80, 10) };
};

/// Whether `peer` is in any of `nets` (an IPv4-mapped address is compared as IPv4).
pub fn containsAny(nets: []const Network, peer: IpAddress) bool {
    for (nets) |net| if (net.contains(peer)) return true;
    return false;
}

/// Not loopback, private, link-local, 100.64.0.0/10, unspecified or multicast.
pub fn isPublic(peer: IpAddress) bool {
    const p = Network.unmap(peer);
    switch (p) {
        .ip4 => |a| {
            if (a.bytes[0] == 0 or a.bytes[0] >= 224) return false; // unspecified/"this network", multicast and above
            if (a.bytes[0] == 100 and a.bytes[1] & 0xc0 == 64) return false; // 100.64.0.0/10
        },
        .ip6 => |a| {
            if (std.mem.allEqual(u8, &a.bytes, 0)) return false;
            if (a.bytes[0] == 0xff) return false; // multicast
        },
    }
    if (containsAny(&networks.loopback, p)) return false;
    if (containsAny(&networks.private, p)) return false;
    if (containsAny(&networks.link_local, p)) return false;
    return true;
}

/// The v2 signature, the first 12 bytes of every v2 header.
pub const v2_signature = "\r\n\r\n\x00\r\nQUIT\n";
/// RFC-style limit on a v1 line, CRLF included.
pub const v1_max_len = 107;
/// The most of a v2 header's body kept for parsing: addresses (216 bytes
/// at most) and the TLVs that fit. The rest is read and dropped, and a TLV
/// past it is not seen.
pub const v2_body_kept = 1024;

/// Parses a v1 header line, CRLF included.
pub fn parseV1(line: []const u8) Error!Header {
    if (line.len > v1_max_len or !std.mem.startsWith(u8, line, "PROXY ") or !std.mem.endsWith(u8, line, "\r\n"))
        return error.InvalidProxyHeader;
    const fields_text = line["PROXY ".len .. line.len - 2];
    var fields = std.mem.splitScalar(u8, fields_text, ' ');
    const family = fields.next() orelse return error.InvalidProxyHeader;
    // UNKNOWN: whatever follows is to be ignored.
    if (std.mem.eql(u8, family, "UNKNOWN")) return .{};
    const want_ip6 = if (std.mem.eql(u8, family, "TCP4"))
        false
    else if (std.mem.eql(u8, family, "TCP6"))
        true
    else
        return error.InvalidProxyHeader;
    const src_text = fields.next() orelse return error.InvalidProxyHeader;
    const dst_text = fields.next() orelse return error.InvalidProxyHeader;
    const src_port = try parsePort(fields.next() orelse return error.InvalidProxyHeader);
    const dst_port = try parsePort(fields.next() orelse return error.InvalidProxyHeader);
    if (fields.next() != null) return error.InvalidProxyHeader;
    const src = IpAddress.parse(src_text, src_port) catch return error.InvalidProxyHeader;
    const dst = IpAddress.parse(dst_text, dst_port) catch return error.InvalidProxyHeader;
    if ((src == .ip6) != want_ip6 or (dst == .ip6) != want_ip6) return error.InvalidProxyHeader;
    return .{ .source = src, .destination = dst };
}

fn parsePort(text: []const u8) Error!u16 {
    if (text.len == 0 or text.len > 5) return error.InvalidProxyHeader;
    for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidProxyHeader;
    // No leading zeros, as the spec asks.
    if (text.len > 1 and text[0] == '0') return error.InvalidProxyHeader;
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidProxyHeader;
}

/// The length of the body after a v2 header's fixed 16 bytes, once those
/// are checked.
pub fn v2BodyLen(head: *const [16]u8) Error!u16 {
    if (!std.mem.eql(u8, head[0..12], v2_signature)) return error.InvalidProxyHeader;
    if (head[12] >> 4 != 2) return error.InvalidProxyHeader;
    if (head[12] & 0xf > 1) return error.InvalidProxyHeader;
    return std.mem.readInt(u16, head[14..16], .big);
}

const af_unspec = 0;
const af_inet = 1;
const af_inet6 = 2;
const af_unix = 3;

const pp2_type_crc32c = 0x03;
const pp2_type_ssl = 0x20;
const pp2_client_ssl = 0x01;

/// Parses a v2 header: its fixed 16 bytes and the body, or as much of it
/// as was kept (`complete` false when the body was cut at `v2_body_kept`).
pub fn parseV2(head: *const [16]u8, body: []const u8, complete: bool) Error!Header {
    const len = try v2BodyLen(head);
    if (complete and body.len != len) return error.InvalidProxyHeader;
    // LOCAL: the proxy speaking for itself; the body is to be ignored.
    if (head[12] & 0xf == 0) return .{};

    const family = head[13] >> 4;
    const transport = head[13] & 0xf;
    if (transport > 2 or family > 3) return error.InvalidProxyHeader;
    var header: Header = .{};
    const address_len: usize = switch (family) {
        af_unspec => 0,
        af_inet => 12,
        af_inet6 => 36,
        af_unix => 216,
        else => unreachable,
    };
    if (len < address_len or body.len < address_len) return error.InvalidProxyHeader;
    switch (family) {
        af_inet => {
            header.source = .{ .ip4 = .{ .bytes = body[0..4].*, .port = std.mem.readInt(u16, body[8..10], .big) } };
            header.destination = .{ .ip4 = .{ .bytes = body[4..8].*, .port = std.mem.readInt(u16, body[10..12], .big) } };
        },
        af_inet6 => {
            header.source = .{ .ip6 = .{ .bytes = body[0..16].*, .port = std.mem.readInt(u16, body[32..34], .big) } };
            header.destination = .{ .ip6 = .{ .bytes = body[16..32].*, .port = std.mem.readInt(u16, body[34..36], .big) } };
        },
        else => {},
    }

    // TLVs.
    var rest = body[address_len..];
    while (rest.len >= 3) {
        const kind = rest[0];
        // In usize: `3 + len` overflows a u16 for the largest lengths.
        const value_len: usize = std.mem.readInt(u16, rest[1..3], .big);
        if (rest.len - 3 < value_len) {
            // Cut off by the kept prefix is fine; by the header is not.
            if (complete) return error.InvalidProxyHeader;
            break;
        }
        const value = rest[3..][0..value_len];
        switch (kind) {
            pp2_type_ssl => {
                // client (1 byte), verify (4 bytes), then sub-TLVs.
                if (value.len < 5) return error.InvalidProxyHeader;
                header.ssl = value[0] & pp2_client_ssl != 0;
            },
            pp2_type_crc32c => {
                if (value.len != 4) return error.InvalidProxyHeader;
                if (complete) {
                    const at = @intFromPtr(value.ptr) - @intFromPtr(body.ptr);
                    if (crc32c(head, body, at) != std.mem.readInt(u32, value[0..4], .big)) return error.InvalidProxyHeader;
                }
            },
            else => {},
        }
        rest = rest[3 + value_len ..];
    }
    if (complete and rest.len != 0) return error.InvalidProxyHeader;
    return header;
}

/// CRC-32C over the whole header with the checksum's own 4 bytes, at
/// `at` in `body`, taken as zero.
fn crc32c(head: *const [16]u8, body: []const u8, at: usize) u32 {
    var h: Crc32c = .init();
    h.update(head);
    h.update(body[0..at]);
    h.update(&.{ 0, 0, 0, 0 });
    h.update(body[at + 4 ..]);
    return h.final();
}

pub const ReadError = Error || std.Io.net.Stream.Reader.Error || error{EndOfStream};

/// Reads a PROXY header, v1 or v2, off `stream` and parses it. Reads only
/// the header's bytes. A connection that does not start with one is an
/// `InvalidProxyHeader`.
pub noinline fn read(io: std.Io, stream: std.Io.net.Stream) ReadError!Header {
    // 12 bytes tell v2 from v1, and every v1 header is longer than that
    // ("PROXY UNKNOWN\r\n" is 15).
    var start: [16]u8 = undefined;
    try readExact(io, stream, start[0..12]);
    if (std.mem.eql(u8, start[0..12], v2_signature)) {
        try readExact(io, stream, start[12..16]);
        const len = try v2BodyLen(&start);
        var body: [v2_body_kept]u8 = undefined;
        const kept = @min(len, body.len);
        try readExact(io, stream, body[0..kept]);
        var left = len - kept;
        var scratch: [512]u8 = undefined;
        while (left > 0) {
            const n = @min(left, scratch.len);
            try readExact(io, stream, scratch[0..n]);
            left -= n;
        }
        return parseV2(&start, body[0..kept], kept == len);
    }

    if (!std.mem.startsWith(u8, start[0..12], "PROXY ")) return error.InvalidProxyHeader;
    var line: [v1_max_len]u8 = undefined;
    @memcpy(line[0..12], start[0..12]);
    // The line's end is unknown, so the rest comes a byte at a time, past
    // the 3 every line still has.
    try readExact(io, stream, line[12..15]);
    var len: usize = 15;
    while (!std.mem.endsWith(u8, line[0..len], "\r\n")) {
        if (len == line.len) return error.InvalidProxyHeader;
        try readExact(io, stream, line[len..][0..1]);
        len += 1;
    }
    return parseV1(line[0..len]);
}

/// Fills `buf` from `stream`, reading no more than its length.
fn readExact(io: std.Io, stream: std.Io.net.Stream, buf: []u8) ReadError!void {
    if (buf.len == 0) return;
    var reader = stream.reader(io, buf);
    reader.interface.fill(buf.len) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return reader.err orelse error.EndOfStream,
    };
}

test "parseV1: TCP4, TCP6 and UNKNOWN" {
    const h4 = try parseV1("PROXY TCP4 192.0.2.1 198.51.100.2 56324 443\r\n");
    try std.testing.expectEqual(@as(u16, 56324), h4.source.?.ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1 }, &h4.source.?.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 443), h4.destination.?.ip4.port);

    const h6 = try parseV1("PROXY TCP6 2001:db8::1 2001:db8::2 4000 80\r\n");
    try std.testing.expectEqual(@as(u16, 4000), h6.source.?.ip6.port);

    const unknown = try parseV1("PROXY UNKNOWN ffff::1 ffff::2 1 2\r\n");
    try std.testing.expect(unknown.source == null);
    try std.testing.expect((try parseV1("PROXY UNKNOWN\r\n")).source == null);
}

test "parseV1: malformed lines are refused" {
    const bad = [_][]const u8{
        "PROXY TCP4 192.0.2.1 198.51.100.2 56324 443\n",
        "PROXY TCP4 192.0.2.1 198.51.100.2 56324\r\n",
        "PROXY TCP4 192.0.2.1 198.51.100.2 56324 443 9\r\n",
        "PROXY TCP4 2001:db8::1 198.51.100.2 1 2\r\n",
        "PROXY TCP6 192.0.2.1 198.51.100.2 1 2\r\n",
        "PROXY TCP4 192.0.2.1 198.51.100.2 65536 2\r\n",
        "PROXY TCP4 192.0.2.1 198.51.100.2 01 2\r\n",
        "PROXY TCP4  192.0.2.1 198.51.100.2 1 2\r\n",
        "PROXY UDP4 192.0.2.1 198.51.100.2 1 2\r\n",
        "proxy TCP4 192.0.2.1 198.51.100.2 1 2\r\n",
    };
    for (bad) |line| try std.testing.expectError(error.InvalidProxyHeader, parseV1(line));
}

fn v2Head(cmd: u8, fam: u8, len: u16) [16]u8 {
    var head: [16]u8 = undefined;
    @memcpy(head[0..12], v2_signature);
    head[12] = 0x20 | cmd;
    head[13] = fam;
    std.mem.writeInt(u16, head[14..16], len, .big);
    return head;
}

test "parseV2: IPv4 and IPv6 PROXY, LOCAL, and the SSL TLV" {
    const body4 = [_]u8{ 192, 0, 2, 1, 198, 51, 100, 2, 0xdc, 0x04, 0x01, 0xbb };
    const h4 = try parseV2(&v2Head(1, 0x11, body4.len), &body4, true);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 1 }, &h4.source.?.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 56324), h4.source.?.ip4.port);
    try std.testing.expect(!h4.ssl);

    var body6: [36 + 3 + 5]u8 = @splat(0);
    body6[15] = 1; // ::1
    std.mem.writeInt(u16, body6[32..34], 4000, .big);
    body6[36] = pp2_type_ssl;
    std.mem.writeInt(u16, body6[37..39], 5, .big);
    body6[39] = pp2_client_ssl;
    const h6 = try parseV2(&v2Head(1, 0x21, body6.len), &body6, true);
    try std.testing.expectEqual(@as(u16, 4000), h6.source.?.ip6.port);
    try std.testing.expect(h6.ssl);

    // LOCAL ignores whatever follows.
    const local = try parseV2(&v2Head(0, 0x11, body4.len), &body4, true);
    try std.testing.expect(local.source == null);
}

test "parseV2: checksum, truncation and bad versions" {
    var body: [12 + 7]u8 = .{ 10, 0, 0, 1, 10, 0, 0, 2, 0, 80, 0, 81 } ++ [_]u8{ pp2_type_crc32c, 0, 4, 0, 0, 0, 0 };
    var head = v2Head(1, 0x11, body.len);
    const sum = crc32c(&head, &body, 15);
    std.mem.writeInt(u32, body[15..19], sum, .big);
    _ = try parseV2(&head, &body, true);
    body[0] = 11; // corrupt the source
    try std.testing.expectError(error.InvalidProxyHeader, parseV2(&head, &body, true));

    // A body shorter than the addresses its family needs.
    const short = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidProxyHeader, parseV2(&v2Head(1, 0x11, short.len), &short, true));
    // A TLV running past the header.
    const overrun = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0, 2, 0x20, 0, 9, 1 };
    try std.testing.expectError(error.InvalidProxyHeader, parseV2(&v2Head(1, 0x11, overrun.len), &overrun, true));
    // Version 1 in the v2 layout, and an unknown command.
    head = v2Head(1, 0x11, 12);
    head[12] = 0x11;
    try std.testing.expectError(error.InvalidProxyHeader, v2BodyLen(&head));
    head[12] = 0x22;
    try std.testing.expectError(error.InvalidProxyHeader, v2BodyLen(&head));
}

test "Network: parse and contains" {
    const ten = try Network.parse("10.0.0.0/8");
    try std.testing.expect(ten.contains(try IpAddress.parse("10.200.3.4", 1)));
    try std.testing.expect(!ten.contains(try IpAddress.parse("11.0.0.1", 1)));
    // IPv4-mapped peers from a dual-stack socket count as IPv4.
    try std.testing.expect(ten.contains(try IpAddress.parse("::ffff:10.1.2.3", 1)));
    try std.testing.expect(!ten.contains(try IpAddress.parse("2001:db8::1", 1)));

    const odd = try Network.parse("192.168.4.0/22");
    try std.testing.expect(odd.contains(try IpAddress.parse("192.168.7.255", 0)));
    try std.testing.expect(!odd.contains(try IpAddress.parse("192.168.8.0", 0)));

    const one = try Network.parse("192.0.2.7");
    try std.testing.expectEqual(@as(u8, 32), one.prefix_len);
    try std.testing.expect(one.contains(try IpAddress.parse("192.0.2.7", 9)));
    try std.testing.expect(!one.contains(try IpAddress.parse("192.0.2.8", 9)));

    const v6 = try Network.parse("2001:db8::/32");
    try std.testing.expect(v6.contains(try IpAddress.parse("2001:db8:ffff::1", 0)));
    try std.testing.expect(!v6.contains(try IpAddress.parse("2001:db9::1", 0)));
    try std.testing.expect(!v6.contains(try IpAddress.parse("10.0.0.1", 0)));

    const any = try Network.parse("0.0.0.0/0");
    try std.testing.expect(any.contains(try IpAddress.parse("203.0.113.9", 0)));

    for ([_][]const u8{ "10.0.0.1/8", "10.0.0.0/33", "10.0.0.0/", "10.0.0.0/+8", "nope", "::/129", "10.0.0.0/0008" }) |bad| {
        try std.testing.expectError(error.InvalidNetwork, Network.parse(bad));
    }

    try std.testing.expect(trustedPeer(&.{}, try IpAddress.parse("203.0.113.9", 0)));
    try std.testing.expect(trustedPeer(&.{ one, ten }, try IpAddress.parse("10.9.9.9", 0)));
    try std.testing.expect(!trustedPeer(&.{ one, ten }, try IpAddress.parse("203.0.113.9", 0)));
}

test "parseV2: a TLV length near the top of u16 is refused, not wrapped" {
    // An IPv4 body and one TLV header claiming 0xfffc..0xffff bytes, the
    // lengths where `3 + len` no longer fits in a u16.
    for ([_]u16{ 0xfffc, 0xfffd, 0xfffe, 0xffff }) |tlv_len| {
        var body: [12 + 3 + 4]u8 = .{ 10, 0, 0, 1, 10, 0, 0, 2, 0, 80, 0, 81, 0x20, 0, 0, 1, 0, 0, 0 };
        std.mem.writeInt(u16, body[13..15], tlv_len, .big);
        const head = v2Head(1, 0x11, body.len);
        try std.testing.expectError(error.InvalidProxyHeader, parseV2(&head, &body, true));
        // Cut at the kept prefix: the addresses stand, the TLV is not seen.
        const cut = try parseV2(&head, &body, false);
        try std.testing.expect(!cut.ssl);
    }
}

test "parse: random and mutated input never crashes" {
    // dusty's test runner has no fuzzer; this is the poor man's version:
    // random bytes, and valid headers with random bytes flipped.
    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const random = prng.random();
    var buf: [600]u8 = undefined;
    const seeds = [_][]const u8{
        "PROXY TCP4 192.0.2.1 198.51.100.2 56324 443\r\n",
        "PROXY TCP6 2001:db8::1 2001:db8::2 4000 80\r\n",
        v2_signature ++ "\x21\x11\x00\x13" ++ "\x0a\x00\x00\x01\x0a\x00\x00\x02\x00\x50\x00\x51" ++ "\x20\x00\x05\x01\x00\x00\x00\x00" ++ "\x00",
    };
    for (0..50_000) |i| {
        var input: []u8 = undefined;
        if (i % 2 == 0) {
            input = buf[0..random.uintAtMost(usize, buf.len)];
            random.bytes(input);
        } else {
            const seed = seeds[i % seeds.len];
            input = buf[0..seed.len];
            @memcpy(input, seed);
            for (0..random.uintAtMost(usize, 3)) |_| input[random.uintLessThan(usize, input.len)] = random.int(u8);
        }
        _ = parseV1(input) catch {};
        if (input.len >= 16) {
            const head: *const [16]u8 = input[0..16];
            _ = parseV2(head, input[16..], true) catch {};
            _ = parseV2(head, input[16..], false) catch {};
        }
    }
}

/// How many bytes of `input` a PROXY header takes, by its framing alone;
/// null when it does not start with a whole one.
fn headerLen(input: []const u8) ?usize {
    if (input.len >= 16 and std.mem.startsWith(u8, input, v2_signature)) {
        const len = v2BodyLen(input[0..16]) catch return null;
        return if (input.len >= 16 + @as(usize, len)) 16 + @as(usize, len) else null;
    }
    if (!std.mem.startsWith(u8, input, "PROXY ")) return null;
    const end = std.mem.indexOfPos(u8, input, 12, "\r\n") orelse return null;
    return if (end + 2 <= v1_max_len) end + 2 else null;
}

fn sameAddress(a: ?IpAddress, b: ?IpAddress) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(&b.?);
}

test "fuzz: PROXY protocol headers, parsed and read off a socket" {
    try @import("fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            if (parseV1(input)) |h| {
                // A line that parses says the same once written back out.
                if (h.source) |src| {
                    var buf: [v1_max_len + 32]u8 = undefined;
                    const line = try std.fmt.bufPrint(&buf, "PROXY {s} {f} {f} {d} {d}\r\n", .{
                        if (src == .ip6) "TCP6" else "TCP4",
                        Host{ .address = src },
                        Host{ .address = h.destination.? },
                        src.getPort(),
                        h.destination.?.getPort(),
                    });
                    const again = try parseV1(line);
                    try std.testing.expect(sameAddress(h.source, again.source));
                    try std.testing.expect(sameAddress(h.destination, again.destination));
                }
            } else |_| {}

            if (input.len >= 16) {
                const head: *const [16]u8 = input[0..16];
                if (parseV2(head, input[16..], true)) |h| {
                    // Keeping only a prefix of the body never loses the
                    // addresses of a header that parses whole.
                    const address_len: usize = switch (head[13] >> 4) {
                        af_inet => 12,
                        af_inet6 => 36,
                        af_unix => 216,
                        else => 0,
                    };
                    var kept = address_len;
                    while (kept <= input.len - 16) : (kept += 7) {
                        const cut = try parseV2(head, input[16..][0..kept], false);
                        try std.testing.expect(sameAddress(h.source, cut.source));
                        try std.testing.expect(sameAddress(h.destination, cut.destination));
                    }
                } else |_| {}
                _ = parseV2(head, input[16..], false) catch {};
            }

            // `read` takes exactly the header off the socket, and says
            // what parsing it says. Not on Windows, which has no
            // socketpair(2).
            if (comptime @import("builtin").os.tag == .windows) return;
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
            defer _ = std.c.close(fds[0]);
            {
                defer _ = std.c.close(fds[1]);
                var written: usize = 0;
                while (written < input.len) {
                    const n = std.c.write(fds[1], input[written..].ptr, input.len - written);
                    if (n <= 0) return error.WriteFailed;
                    written += @intCast(n);
                }
            }
            const io = std.testing.io;
            const stream: std.Io.net.Stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .loopback(0) } } };
            const result = read(io, stream);
            const len = headerLen(input) orelse {
                if (result) |_| return error.TestUnexpectedResult else |_| return;
            };
            const parsed: Error!Header = if (len >= 16 and std.mem.startsWith(u8, input, v2_signature))
                parseV2(input[0..16], input[16..len][0..@min(len - 16, v2_body_kept)], len - 16 <= v2_body_kept)
            else
                parseV1(input[0..len]);
            const want = parsed catch {
                // The connection is refused; how much of it was read no
                // longer matters.
                if (result) |_| return error.TestUnexpectedResult else |_| return;
            };
            const got = try result;
            try std.testing.expect(sameAddress(want.source, got.source));
            try std.testing.expect(sameAddress(want.destination, got.destination));
            try std.testing.expectEqual(want.ssl, got.ssl);
            var rest: [fuzz_max]u8 = undefined;
            var got_rest: usize = 0;
            while (true) {
                const n = std.c.read(fds[0], rest[got_rest..].ptr, rest.len - got_rest);
                if (n <= 0) break;
                got_rest += @intCast(n);
            }
            try std.testing.expectEqualSlices(u8, input[len..], rest[0..got_rest]);
        }
    }.check, &.{
        "PROXY TCP4 192.0.2.1 198.51.100.2 56324 443\r\nGET / HTTP/1.1\r\n\r\n",
        "PROXY TCP6 2001:db8::1 2001:db8::2 4000 80\r\n\x16\x03\x01",
        "PROXY UNKNOWN ffff::1 ffff::2 1 2\r\n",
        "PROXY TCP4 10.0.0.1 10.0.0.2 080 443\r\n",
        v2_signature ++ "\x21\x11\x00\x13" ++ "\x0a\x00\x00\x01\x0a\x00\x00\x02\x00\x50\x00\x51" ++ "\x20\x00\x05\x01\x00\x00\x00\x00" ++ "\x00" ++ "after",
        v2_signature ++ "\x21\x21\x00\x24" ++ "\x20\x01\x0d\xb8" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x01" ++ "\x20\x01\x0d\xb8" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x02" ++ "\x01\xbb\x00\x50",
        v2_signature ++ "\x20\x00\x00\x00",
        v2_signature ++ "\x21\x11\x00\x13" ++ "\x0a\x00\x00\x01\x0a\x00\x00\x02\x00\x50\x00\x51" ++ "\x03\x00\x04\x00\x00\x00\x00",
        // TLV lengths at the top of the u16 range.
        v2_signature ++ "\x21\x11\x00\x13" ++ "\x0a\x00\x00\x01\x0a\x00\x00\x02\x00\x50\x00\x51" ++ "\x20\xff\xff\x01\x00\x00\x00",
        v2_signature ++ "\x21\x11\x00\x0f" ++ "\x0a\x00\x00\x01\x0a\x00\x00\x02\x00\x50\x00\x51" ++ "\x04\xff\xfd",
    });
}

const fuzz_max = @import("fuzz.zig").max_len;

/// An address without its port, as a v1 line spells it.
const Host = struct {
    address: IpAddress,
    pub fn format(self: Host, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.address) {
            .ip4 => |a| try w.print("{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }),
            .ip6 => |a| for (0..8) |i| {
                if (i > 0) try w.writeByte(':');
                try w.print("{x}", .{std.mem.readInt(u16, a.bytes[i * 2 ..][0..2], .big)});
            },
        }
    }
};

test "isPublic table" {
    for ([_][]const u8{ "8.8.8.8", "2001:4860::8888" }) |t| try std.testing.expect(isPublic(try IpAddress.parse(t, 0)));
    for ([_][]const u8{ "127.0.0.1", "::1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "fc00::1", "169.254.1.1", "fe80::1", "100.64.0.1", "0.0.0.0", "224.0.0.1" }) |t| {
        try std.testing.expect(!isPublic(try IpAddress.parse(t, 0)));
    }
}

test "named networks and Network.format" {
    try std.testing.expect(containsAny(&networks.private, try IpAddress.parse("172.31.255.255", 0)));
    try std.testing.expect(!containsAny(&networks.private, try IpAddress.parse("172.32.0.1", 0)));
    try std.testing.expect(containsAny(&networks.loopback, try IpAddress.parse("::ffff:127.0.0.1", 0)));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try networks.private[1].format(&w);
    try std.testing.expectEqualStrings("172.16.0.0/12", w.buffered());
    w = .fixed(&buf);
    try networks.loopback[1].format(&w);
    try std.testing.expectEqualStrings("::1/128", w.buffered());
    w = .fixed(&buf);
    try networks.private[3].format(&w);
    try std.testing.expectEqualStrings("fc00::/7", w.buffered());
    const parsed = try Network.parse("10.0.0.0/8");
    try std.testing.expect(parsed.contains(try IpAddress.parse("10.9.9.9", 0)));
}
