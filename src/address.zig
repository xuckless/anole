//! Listen addresses in Go's notation, for `Server.listen` and `listenTls`:
//! ":3000" is every interface, IPv6 and IPv4 alike (one dual-stack socket
//! on `::`, or `0.0.0.0` where the system has no IPv6), "0.0.0.0:3000"
//! every IPv4 interface only, "127.0.0.1:3000" or "localhost:3000"
//! loopback only, "[::]:3000" every IPv6 interface (and IPv4 too where the
//! system maps it), "[::1]:3000" IPv6 loopback.
const std = @import("std");

pub const Parsed = struct {
    /// An IP literal, or "" for every interface (`any`), as
    /// `Options.Http.address` takes it.
    host: []const u8,
    port: u16,
};

pub const Error = error{InvalidListenAddress};

/// Splits `text` into an IP literal and a port. The only name taken is
/// "localhost" (127.0.0.1): a server binds addresses, not host names.
pub fn parse(text: []const u8) Error!Parsed {
    // "3000": every interface, as ":3000".
    if (text.len > 0 and allDigits(text)) return .{ .host = any, .port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidListenAddress };
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidListenAddress;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.InvalidListenAddress;
    var host = text[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
        // Brackets are for IPv6 only.
        if (std.mem.indexOfScalar(u8, host, ':') == null) return error.InvalidListenAddress;
    } else if (std.mem.indexOfScalar(u8, host, ':') != null) {
        // An IPv6 literal must be bracketed, or its last group would read
        // as the port.
        return error.InvalidListenAddress;
    }
    if (host.len == 0) return .{ .host = any, .port = port };
    if (std.ascii.eqlIgnoreCase(host, "localhost")) host = "127.0.0.1";
    _ = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidListenAddress;
    return .{ .host = host, .port = port };
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// Whether `ip` is a loopback address: 127.0.0.0/8, ::1 and ::ffff:127.0.0.0/104.
pub fn isLoopback(ip: std.Io.net.IpAddress) bool {
    switch (ip) {
        .ip4 => |a| return a.bytes[0] == 127,
        .ip6 => |a| {
            const b = a.bytes;
            const zeros: [15]u8 = @splat(0);
            if (std.mem.eql(u8, b[0..15], &zeros) and b[15] == 1) return true;
            const mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
            return std.mem.eql(u8, b[0..12], &mapped) and b[12] == 127;
        },
    }
}

/// The listener address that means every interface, IPv6 and IPv4 alike:
/// what ":3000" names.
pub const any = "";

/// What a listener binds: an IP address, and IPV6_V6ONLY for it
/// (`http.Listener.ipv6_only`; null leaves the system's default).
pub const Bind = struct {
    ip: std.Io.net.IpAddress,
    ipv6_only: ?bool = null,
};

/// The socket address for `host` (an IP literal, or `any`) and `port`.
/// `any` is `::` with IPV6_V6ONLY off, which takes both families on one
/// socket, when `dual_stack` (`dualStackAvailable`); else `0.0.0.0`. An
/// explicit address is bound as it is: "0.0.0.0" stays IPv4 only, "::"
/// keeps the system's default.
pub fn resolve(host: []const u8, port: u16, dual_stack: bool) error{InvalidListenAddress}!Bind {
    if (host.len == 0) return if (dual_stack)
        .{ .ip = .{ .ip6 = .unspecified(port) }, .ipv6_only = false }
    else
        .{ .ip = .{ .ip4 = .unspecified(port) } };
    return .{ .ip = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidListenAddress };
}

/// Whether this system can bind a dual-stack socket: an IPv6 one with
/// IPV6_V6ONLY off, on `::`. False where IPv6 is compiled out or turned
/// off at boot (EAFNOSUPPORT), in a container without it, and on Windows
/// (a development target, which binds IPv4). Asked once per server.
pub fn dualStackAvailable() bool {
    if (comptime @import("builtin").os.tag == .windows) return false;
    const posix = std.posix;
    const c = std.c;
    const fd = c.socket(posix.AF.INET6, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const off: c_int = 0;
    if (c.setsockopt(fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, &off, @sizeOf(c_int)) != 0) return false;
    const unspecified: std.Io.net.IpAddress = .{ .ip6 = .unspecified(0) };
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&unspecified, &storage);
    return c.bind(fd, &storage.any, len) == 0;
}

test "listen addresses: Go's notation" {
    const cases = [_]struct { text: []const u8, host: []const u8, port: u16 }{
        .{ .text = ":3000", .host = "", .port = 3000 },
        .{ .text = "0.0.0.0:3000", .host = "0.0.0.0", .port = 3000 },
        .{ .text = "127.0.0.1:8080", .host = "127.0.0.1", .port = 8080 },
        .{ .text = "localhost:443", .host = "127.0.0.1", .port = 443 },
        .{ .text = "LocalHost:1", .host = "127.0.0.1", .port = 1 },
        .{ .text = "[::]:3000", .host = "::", .port = 3000 },
        .{ .text = "[::1]:0", .host = "::1", .port = 0 },
        .{ .text = "10.1.2.3:65535", .host = "10.1.2.3", .port = 65535 },
    };
    for (cases) |c| {
        const p = try parse(c.text);
        try std.testing.expectEqualStrings(c.host, p.host);
        try std.testing.expectEqual(c.port, p.port);
    }
    for ([_][]const u8{ "3000", ":", ":65536", ":-1", "example.com:80", "::1:80", "[127.0.0.1]:80", "[::1]", "1.2.3:80", "" }) |bad| {
        try std.testing.expectError(error.InvalidListenAddress, parse(bad));
    }
}

test "listen addresses: every interface is dual-stack where it can be" {
    const dual = try resolve(any, 3000, true);
    try std.testing.expect(dual.ip == .ip6);
    try std.testing.expect(std.mem.allEqual(u8, &dual.ip.ip6.bytes, 0));
    try std.testing.expectEqual(@as(u16, 3000), dual.ip.getPort());
    try std.testing.expectEqual(@as(?bool, false), dual.ipv6_only);
    // No IPv6: every IPv4 interface.
    const v4 = try resolve(any, 3000, false);
    try std.testing.expect(v4.ip == .ip4);
    try std.testing.expectEqual(@as(?bool, null), v4.ipv6_only);
    // Explicit addresses as given.
    const explicit4 = try resolve("0.0.0.0", 80, true);
    try std.testing.expect(explicit4.ip == .ip4);
    try std.testing.expectEqual(@as(?bool, null), explicit4.ipv6_only);
    const explicit6 = try resolve("::", 80, true);
    try std.testing.expect(explicit6.ip == .ip6);
    try std.testing.expectEqual(@as(?bool, null), explicit6.ipv6_only);
    try std.testing.expectError(error.InvalidListenAddress, resolve("example.com", 80, true));
}

test "listen addresses: a bare port is every interface" {
    const p = try parse("3000");
    try std.testing.expectEqualStrings(any, p.host);
    try std.testing.expectEqual(@as(u16, 3000), p.port);
    try std.testing.expectEqual(@as(u16, 0), (try parse("0")).port);
    try std.testing.expectError(error.InvalidListenAddress, parse("65536"));
    try std.testing.expectError(error.InvalidListenAddress, parse("3000x"));
    try std.testing.expectError(error.InvalidListenAddress, parse(""));
}

test "address: isLoopback" {
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parse("127.0.0.1", 1)));
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parse("127.5.5.5", 1)));
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parse("::1", 1)));
    try std.testing.expect(isLoopback(try std.Io.net.IpAddress.parse("::ffff:127.0.0.1", 1)));
    try std.testing.expect(!isLoopback(try std.Io.net.IpAddress.parse("10.0.0.1", 1)));
    try std.testing.expect(!isLoopback(try std.Io.net.IpAddress.parse("::", 1)));
    try std.testing.expect(!isLoopback(try std.Io.net.IpAddress.parse("0.0.0.0", 1)));
}
