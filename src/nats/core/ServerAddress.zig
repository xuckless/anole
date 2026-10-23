// Adapted from vkiryakov/zefir src/nats/ServerAddress.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A server address: a host of up to 255 bytes and a port,
//! stored inline, so the value can be copied and returned without an
//! allocator. An IPv6 host is stored without its brackets.

const std = @import("std");
const ServerAddress = @This();

pub const default_port: u16 = 4222;
pub const max_host_len = 255;

host_buffer: [max_host_len]u8,
host_len: u8,
port: u16,

pub const ParseError = error{InvalidOptions};

/// Parses `nats://host:port`, `host:port`, `[::1]:4222` or a bare host; the
/// port defaults to 4222. The `connect_urls` of INFO use the same forms
/// without a scheme. Other schemes (`tls://`, `ws://`, `wss://`), user and
/// password in the URL, paths and whitespace are InvalidOptions, the error
/// of such a server in the client's options.
pub fn parse(text: []const u8) ParseError!ServerAddress {
    var rest = text;
    if (std.mem.find(u8, rest, "://")) |scheme_end| {
        if (!std.ascii.eqlIgnoreCase(rest[0..scheme_end], "nats")) return error.InvalidOptions;
        rest = rest[scheme_end + 3 ..];
    }
    if (rest.len == 0) return error.InvalidOptions;
    for (rest) |c| switch (c) {
        '@', '/', '?', '#' => return error.InvalidOptions,
        else => if (c <= ' ' or c == 0x7f) return error.InvalidOptions,
    };

    var name: []const u8 = rest;
    var port_text: ?[]const u8 = null;
    if (rest[0] == '[') {
        const close = std.mem.findScalar(u8, rest, ']') orelse return error.InvalidOptions;
        name = rest[1..close];
        // Brackets hold an IPv6 literal, optionally with a zone: `fe80::1%en0`.
        if (name.len > max_host_len) return error.InvalidOptions;
        switch (std.Io.net.Ip6Address.Unresolved.parse(name)) {
            .success => {},
            else => return error.InvalidOptions,
        }
        const after = rest[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return error.InvalidOptions;
            port_text = after[1..];
        }
    } else if (std.mem.findScalar(u8, rest, ':')) |colon| {
        // A second colon means an IPv6 literal without brackets.
        if (std.mem.findScalarPos(u8, rest, colon + 1, ':') != null) return error.InvalidOptions;
        name = rest[0..colon];
        port_text = rest[colon + 1 ..];
    }
    if (name.len == 0 or name.len > max_host_len) return error.InvalidOptions;
    if (std.mem.findAny(u8, name, "[]") != null) return error.InvalidOptions;

    var address: ServerAddress = .{
        .host_buffer = undefined,
        .host_len = @intCast(name.len),
        .port = if (port_text) |p| try parsePort(p) else default_port,
    };
    @memcpy(address.host_buffer[0..name.len], name);
    return address;
}

fn parsePort(text: []const u8) ParseError!u16 {
    if (text.len == 0 or text.len > 5) return error.InvalidOptions;
    var port: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidOptions;
        port = port * 10 + (c - '0');
    }
    if (port == 0 or port > std.math.maxInt(u16)) return error.InvalidOptions;
    return @intCast(port);
}

pub fn host(address: *const ServerAddress) []const u8 {
    return address.host_buffer[0..address.host_len];
}

/// `host:port`, with brackets around an IPv6 host, as in `connect_urls`.
pub fn format(address: ServerAddress, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const h = address.host();
    if (std.mem.findScalar(u8, h, ':') != null) {
        try w.print("[{s}]:{d}", .{ h, address.port });
    } else {
        try w.print("{s}:{d}", .{ h, address.port });
    }
}

/// The same port and the same host, letters compared without case.
pub fn eql(a: ServerAddress, b: ServerAddress) bool {
    return a.port == b.port and std.ascii.eqlIgnoreCase(a.host(), b.host());
}

const testing = std.testing;

fn expectAddress(text: []const u8, expected_host: []const u8, expected_port: u16) !void {
    const address = try parse(text);
    try testing.expectEqualStrings(expected_host, address.host());
    try testing.expectEqual(expected_port, address.port);
}

test "accepted forms" {
    try expectAddress("nats://127.0.0.1:4222", "127.0.0.1", 4222);
    try expectAddress("NATS://demo.nats.io", "demo.nats.io", 4222);
    try expectAddress("localhost:14222", "localhost", 14222);
    try expectAddress("localhost", "localhost", 4222);
    try expectAddress("[::1]:4222", "::1", 4222);
    try expectAddress("nats://[::1]", "::1", 4222);
    try expectAddress("[fe80::1%en0]:65535", "fe80::1%en0", 65535);
    try expectAddress("[::ffff:127.0.0.1]:4222", "::ffff:127.0.0.1", 4222);
    try expectAddress("[2001:DB8::1]", "2001:DB8::1", 4222);
    try expectAddress("127.0.0.1:1", "127.0.0.1", 1);
    const long_host: [255]u8 = @splat('h');
    try expectAddress(&long_host, &long_host, 4222);
}

test "rejected forms" {
    const too_long: [256]u8 = @splat('h');
    for ([_][]const u8{
        "",                    "nats://",                    "tls://host:4222", "ws://host",           "wss://host",
        "http://host",         "nats://user:pass@host:4222", "user@host",       "host:",               "host:0",
        "host:65536",          "host:12a",                   "host:-1",         "::1",                 "::1:4222",
        "[::1",                "[::1]x",                     "[::1]:",          "[127.0.0.1]:4222",    "host:4222/path",
        "nats://host:4222?x",  "host name",                  "host\r\n",        "[]:4222",             &too_long,
        // Brackets hold an IPv6 literal and nothing else.
        "[:]:4222",            "[zz:zz]:4222",               "[::1::2]",        "[1:2:3:4:5:6:7:8:9]", "[fe80::1%]:4222",
        "[::ffff:1.2.3]:4222", "[localhost:1]",
    }) |text| {
        try testing.expectError(error.InvalidOptions, parse(text));
    }
}

test "format writes the connect_urls form and round-trips" {
    var buffer: [300]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1:4222", "[::1]:14222", "demo.nats.io:4222" }) |text| {
        var w: std.Io.Writer = .fixed(&buffer);
        try w.print("{f}", .{try parse(text)});
        try testing.expectEqualStrings(text, w.buffered());
    }
}

test "eql ignores the case of the host" {
    try testing.expect(eql(try parse("LocalHost:4222"), try parse("nats://localhost")));
    try testing.expect(!eql(try parse("localhost:4222"), try parse("localhost:4223")));
    try testing.expect(!eql(try parse("a:4222"), try parse("b:4222")));
}
