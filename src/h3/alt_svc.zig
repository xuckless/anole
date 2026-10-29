//! The `h3` alternative of an Alt-Svc header field value (RFC 7838 §3), for
//! clients that switch to HTTP/3 (the gRPC channel's `.auto`). Sans-IO.
const std = @import("std");

pub const Result = union(enum) {
    /// No usable `h3` alternative.
    none,
    /// `clear`: forget alternatives for this origin.
    clear,
    h3: struct { port: u16, max_age_s: u32 },
};

/// The first `h3` alternative whose host is empty (same host) or equals
/// `origin_host` (ASCII case-insensitive). `ma` defaults to 86400; `h3-NN`
/// drafts and other protocols are skipped; a malformed entry ends the parse
/// with what was found before it.
pub fn parse(value: []const u8, origin_host: []const u8) Result {
    var p: Parser = .{ .s = value };
    p.skipWs();
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "clear")) return .clear;
    while (true) {
        p.skipWs();
        if (p.eof()) return .none;
        const proto = p.token() orelse return .none;
        if (!p.eat('=')) return .none;
        var auth_buf: [256]u8 = undefined;
        const authority = p.quoted(&auth_buf) orelse return .none;
        var ma: u32 = 86400;
        while (true) {
            p.skipWs();
            if (!p.eat(';')) break;
            p.skipWs();
            const name = p.token() orelse return .none;
            if (!p.eat('=')) return .none;
            var val_buf: [256]u8 = undefined;
            const val = (if (p.peek() == '"') p.quoted(&val_buf) else p.token()) orelse return .none;
            if (std.ascii.eqlIgnoreCase(name, "ma")) ma = std.fmt.parseInt(u32, val, 10) catch 86400;
        }
        if (std.mem.eql(u8, proto, "h3")) if (authorityPort(authority, origin_host)) |port|
            return .{ .h3 = .{ .port = port, .max_age_s = ma } };
        p.skipWs();
        if (p.eof()) return .none;
        if (!p.eat(',')) return .none;
    }
}

/// `host:port` or `:port`: the port when the host is empty or the origin's.
fn authorityPort(authority: []const u8, origin_host: []const u8) ?u16 {
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
    var host = authority[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    var origin = origin_host;
    if (origin.len >= 2 and origin[0] == '[' and origin[origin.len - 1] == ']') origin = origin[1 .. origin.len - 1];
    if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, origin)) return null;
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    return if (port == 0) null else port;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn eof(p: *const Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }
    fn eat(p: *Parser, ch: u8) bool {
        if (p.peek() == ch) {
            p.i += 1;
            return true;
        }
        return false;
    }
    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }
    fn token(p: *Parser) ?[]const u8 {
        const start = p.i;
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            '=', ';', ',', '"', ' ', '\t' => break,
            else => {},
        };
        return if (p.i == start) null else p.s[start..p.i];
    }
    /// The quoted string at the cursor, unescaped into `buf` (each caller
    /// passes its own, so a later parameter can't overwrite the authority).
    fn quoted(p: *Parser, buf: []u8) ?[]const u8 {
        if (!p.eat('"')) return null;
        var n: usize = 0;
        while (p.i < p.s.len) {
            const ch = p.s[p.i];
            p.i += 1;
            switch (ch) {
                '"' => return buf[0..n],
                '\\' => {
                    if (p.i >= p.s.len) return null;
                    if (n >= buf.len) return null;
                    buf[n] = p.s[p.i];
                    n += 1;
                    p.i += 1;
                },
                else => {
                    if (n >= buf.len) return null;
                    buf[n] = ch;
                    n += 1;
                },
            }
        }
        return null;
    }
};

test "h3 with empty host" {
    const r = parse("h3=\":443\"", "example.com");
    try std.testing.expectEqual(@as(u16, 443), r.h3.port);
    try std.testing.expectEqual(@as(u32, 86400), r.h3.max_age_s);
}

test "alt_svc: ma sets the max age; other parameters are skipped" {
    const r = parse("h3=\":8443\"; ma=3600; persist=1", "x");
    try std.testing.expectEqual(@as(u16, 8443), r.h3.port);
    try std.testing.expectEqual(@as(u32, 3600), r.h3.max_age_s);
}

test "alt_svc: clear, in any case and with spaces, means forget the alternatives" {
    try std.testing.expect(parse(" clear ", "x") == .clear);
    try std.testing.expect(parse("CLEAR", "x") == .clear);
}

test "other host skipped, matching host taken" {
    const r = parse("h3=\"other.example:1\", h3=\"Example.COM:4433\"; ma=5", "example.com");
    try std.testing.expectEqual(@as(u16, 4433), r.h3.port);
    try std.testing.expect(parse("h3=\"other.example:1\"", "example.com") == .none);
    try std.testing.expectEqual(@as(u16, 7), parse("h3=\"[::1]:7\"", "::1").h3.port);
}

test "h3-29 and h2 skipped" {
    try std.testing.expect(parse("h3-29=\":443\", h2=\":443\"", "x") == .none);
    try std.testing.expectEqual(@as(u16, 444), parse("h3-29=\":443\", h2=\":443\", h3=\":444\"", "x").h3.port);
}

test "alt_svc: a quoted ma does not overwrite the quoted authority (escapes unescaped)" {
    const r = parse("h3=\":\\4\\43\"; ma=\"60\"", "x");
    try std.testing.expectEqual(@as(u16, 443), r.h3.port);
    try std.testing.expectEqual(@as(u32, 60), r.h3.max_age_s);
}

test "malformed entry ends the parse" {
    try std.testing.expect(parse("h3=:443", "x") == .none);
    try std.testing.expectEqual(@as(u16, 443), parse("h3=\":443\", h3", "x").h3.port);
    try std.testing.expect(parse("h2=\":1\", h3=\":0\"", "x") == .none);
    try std.testing.expect(parse("", "x") == .none);
}

fn fuzzCheck(input: []const u8) anyerror!void {
    switch (parse(input, "example.com")) {
        .h3 => |a| if (a.port == 0) return error.ZeroPort,
        else => {},
    }
}

test "fuzz: Alt-Svc header" {
    try @import("../fuzz.zig").bytes(fuzzCheck, &.{
        "h3=\":443\"; ma=86400",
        "clear",
        "h3-29=\":443\", h2=\"example.com:8443\"; persist=1, h3=\":4433\"",
        "h3=\"[::1]:443\"; ma=\"1\\\"",
    });
}
