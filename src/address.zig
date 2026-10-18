//! Listen addresses in Go's notation, for `Server.listen` and `listenTls`:
//! ":3000" is every IPv4 interface, "127.0.0.1:3000" or "localhost:3000"
//! loopback only, "[::]:3000" every IPv6 interface (and IPv4 too where the
//! system maps it), "[::1]:3000" IPv6 loopback.
const std = @import("std");

pub const Parsed = struct {
    /// An IP literal, as `Options.Http.address` takes it.
    host: []const u8,
    port: u16,
};

pub const Error = error{InvalidListenAddress};

/// Splits `text` into an IP literal and a port. The only name taken is
/// "localhost" (127.0.0.1): a server binds addresses, not host names.
pub fn parse(text: []const u8) Error!Parsed {
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
    if (host.len == 0) host = "0.0.0.0";
    if (std.ascii.eqlIgnoreCase(host, "localhost")) host = "127.0.0.1";
    _ = std.Io.net.IpAddress.parse(host, port) catch return error.InvalidListenAddress;
    return .{ .host = host, .port = port };
}

test "listen addresses: Go's notation" {
    const cases = [_]struct { text: []const u8, host: []const u8, port: u16 }{
        .{ .text = ":3000", .host = "0.0.0.0", .port = 3000 },
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
