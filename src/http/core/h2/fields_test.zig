// Tests translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// tests/nghttp2_helper_test.c, tests/nghttp2_http_test.c and
// tests/nghttp2_session_test.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! Tests for fields.zig, ported from nghttp2's (MIT, v1.70.0)
//! tests/nghttp2_helper_test.c, tests/nghttp2_http_test.c and the request
//! cases of tests/nghttp2_session_test.c (test_nghttp2_http_mandatory_headers
//! and the other pure field checks).

const std = @import("std");
const build_options = @import("build_options");
const fields = @import("fields.zig");
const fuzz = @import("../fuzz.zig");

const Request = fields.Request;
const Verdict = fields.Verdict;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Field = [2][]const u8;

/// What nghttp2's session makes of a request head: false when a field is
/// malformed or the head as a whole is.
fn accepts(list: []const Field, opts: fields.Opts) bool {
    var r: Request = .{};
    for (list) |f| if (r.field(f[0], f[1], opts) == .malformed) return false;
    return r.end();
}

fn verdict(r: *Request, name: []const u8, value: []const u8) Verdict {
    return r.field(name, value, .{});
}

const get: []const Field = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":path", "/" }, .{ ":authority", "localhost" } };

inline fn cat(comptime a: []const Field, comptime b: []const Field) []const Field {
    comptime {
        const out = a[0..a.len].* ++ b[0..b.len].*;
        return &out;
    }
}

test "h2 fields: check_header_name" {
    try expect(fields.validName(":path"));
    try expect(fields.validName("path"));
    try expect(fields.validName("!#$%&'*+-.^_`|~"));
    try expect(!fields.validName(":PATH"));
    try expect(!fields.validName("path:"));
    try expect(!fields.validName(""));
    try expect(!fields.validName(":"));
}

test "h2 fields: check_header_value" {
    try expect(fields.validValue(" !|}~"));
    try expect(fields.validValue("ab\x80c\xffd\t "));
    try expect(!fields.validValue("a\x1fb"));
    try expect(!fields.validValue("a\x7fb"));
    try expect(fields.validValue(""));
    try expect(fields.validValue(" "));
    try expect(fields.validValue("\t"));
}

test "h2 fields: check_header_value_rfc9113" {
    try expect(fields.validValueRfc9113("!|}~"));
    try expect(!fields.validValueRfc9113(" !|}~"));
    try expect(!fields.validValueRfc9113("!|}~ "));
    try expect(!fields.validValueRfc9113("\t!|}~"));
    try expect(!fields.validValueRfc9113("!|}~\t"));
    try expect(fields.validValueRfc9113("ab\x80c\xffd"));
    try expect(!fields.validValueRfc9113("a\x1fb"));
    try expect(!fields.validValueRfc9113("a\x7fb"));
    try expect(fields.validValueRfc9113(""));
    try expect(!fields.validValueRfc9113(" "));
    try expect(!fields.validValueRfc9113("\t"));
}

test "h2 fields: a plain request is ok" {
    var r: Request = .{};
    for (get) |f| try expectEqual(Verdict.ok, verdict(&r, f[0], f[1]));
    try expectEqual(Verdict.ok, verdict(&r, "user-agent", "curl/8"));
    try expect(r.end());
    try expect(r.content_length == null);
}

test "h2 fields: priority (test_nghttp2_http_on_header)" {
    var r: Request = .{};
    try expectEqual(Verdict.ok, verdict(&r, "priority", "u=1"));
    try expectEqual(Verdict.ignore, verdict(&r, "priority", "u=1\r\n"));
}

test "h2 fields: mandatory headers (test_nghttp2_http_mandatory_headers)" {
    const opts: fields.Opts = .{};
    // no :path
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":method", "GET" }, .{ ":authority", "localhost" } }, opts));
    // CONNECT followed by :scheme and :path
    try expect(!accepts(&.{ .{ ":method", "CONNECT" }, .{ ":scheme", "https" }, .{ ":path", "/" }, .{ ":authority", "localhost" } }, opts));
    // CONNECT after :scheme and :path
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":path", "/" }, .{ ":method", "CONNECT" }, .{ ":authority", "localhost" } }, opts));
    // :path twice
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":method", "GET" }, .{ ":authority", "localhost" }, .{ ":path", "/" }, .{ ":path", "/" } }, opts));
    // bad content-length, two content-lengths
    try expect(!accepts(cat(get, &.{.{ "content-length", "-1" }}), opts));
    try expect(!accepts(cat(get, &.{ .{ "content-length", "0" }, .{ "content-length", "0" } }), opts));
    // a connection-specific field
    try expect(!accepts(cat(get, &.{.{ "connection", "close" }}), opts));
    // :authority with CRLF
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":method", "GET" }, .{ ":authority", "\r\nlocalhost" }, .{ ":path", "/" } }, opts));
    // a bad regular field (ignored) still ends the pseudo-headers
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":method", "GET" }, .{ "foo", "\r\n" }, .{ ":authority", "localhost" }, .{ ":path", "/" } }, opts));
    // "*" with GET, either order; with OPTIONS, either order
    try expect(!accepts(&.{ .{ ":path", "*" }, .{ ":scheme", "https" }, .{ ":authority", "localhost" }, .{ ":method", "GET" } }, opts));
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":authority", "localhost" }, .{ ":method", "GET" }, .{ ":path", "*" } }, opts));
    try expect(accepts(&.{ .{ ":path", "*" }, .{ ":scheme", "https" }, .{ ":authority", "localhost" }, .{ ":method", "OPTIONS" } }, opts));
    try expect(accepts(&.{ .{ ":scheme", "https" }, .{ ":authority", "localhost" }, .{ ":method", "OPTIONS" }, .{ ":path", "*" } }, opts));

    const ws: []const Field = &.{ .{ ":scheme", "https" }, .{ ":path", "/" }, .{ ":method", "CONNECT" }, .{ ":authority", "localhost" }, .{ ":protocol", "websocket" } };
    // :protocol only when we enabled it
    try expect(!accepts(ws, opts));
    const ecp: fields.Opts = .{ .connect_protocol = true };
    try expect(accepts(ws, ecp));
    // :protocol only with CONNECT
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":path", "/" }, .{ ":method", "GET" }, .{ ":authority", "localhost" }, .{ ":protocol", "websocket" } }, ecp));
    // extended CONNECT needs :path, and :authority (host is not enough)
    try expect(!accepts(&.{ .{ ":scheme", "https" }, .{ ":method", "CONNECT" }, .{ ":authority", "localhost" }, .{ ":protocol", "websocket" } }, ecp));
    try expect(!accepts(&.{ .{ ":scheme", "http" }, .{ ":path", "/" }, .{ ":method", "CONNECT" }, .{ "host", "localhost" }, .{ ":protocol", "websocket" } }, ecp));
    // a plain CONNECT is fine either way
    try expect(accepts(&.{ .{ ":method", "CONNECT" }, .{ ":authority", "localhost" } }, ecp));
    try expect(accepts(&.{ .{ ":method", "CONNECT" }, .{ ":authority", "localhost" } }, opts));
    // ... but not without :authority, and not on a pushed stream
    try expect(!accepts(&.{ .{ ":method", "CONNECT" }, .{ "host", "localhost" } }, opts));
    try expect(!accepts(&.{ .{ ":method", "CONNECT" }, .{ ":authority", "localhost" } }, .{ .stream_id = 2 }));
}

test "h2 fields: host and :authority" {
    const opts: fields.Opts = .{};
    const base: []const Field = &.{ .{ ":method", "GET" }, .{ ":scheme", "https" }, .{ ":path", "/" } };
    try expect(accepts(cat(base, &.{.{ ":authority", "a.example" }}), opts));
    try expect(accepts(cat(base, &.{.{ "host", "a.example" }}), opts));
    try expect(!accepts(base, opts));
    // Both, and different: nghttp2 doesn't compare them (RFC 9113 §8.3.1
    // only says SHOULD).
    try expect(accepts(cat(base, &.{ .{ ":authority", "a.example" }, .{ "host", "b.example" } }), opts));
    var r: Request = .{};
    // A bad host is dropped, a second one is malformed, an empty one too.
    try expectEqual(Verdict.ignore, verdict(&r, "host", "user@a.example"));
    try expectEqual(Verdict.ok, verdict(&r, "host", "a.example"));
    try expectEqual(Verdict.malformed, verdict(&r, "host", "a.example"));
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, "host", ""));
    // No userinfo in :authority.
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, ":authority", "user@a.example"));
    // Empty pseudo-header values are malformed.
    for ([_][]const u8{ ":method", ":scheme", ":path", ":authority" }) |name| {
        r = .{};
        try expectEqual(Verdict.malformed, verdict(&r, name, ""));
    }
}

test "h2 fields: content-length" {
    try expectEqual(@as(?u63, 0), fields.parseContentLength("0"));
    try expectEqual(@as(?u63, 1234), fields.parseContentLength("01234"));
    try expectEqual(@as(?u63, std.math.maxInt(i64)), fields.parseContentLength("9223372036854775807"));
    for ([_][]const u8{ "", "-1", "+1", " 1", "1 ", "1,1", "0x10", "9223372036854775808", "99999999999999999999" }) |s|
        try expect(fields.parseContentLength(s) == null);
    var r: Request = .{};
    try expectEqual(Verdict.ok, verdict(&r, "content-length", "100"));
    try expectEqual(@as(?u63, 100), r.content_length);
    try expectEqual(Verdict.malformed, verdict(&r, "content-length", "100"));
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, "content-length", "9223372036854775808"));
    // A plain CONNECT drops it (its body is a tunnel).
    r = .{};
    for ([_]Field{ .{ ":method", "CONNECT" }, .{ ":authority", "a:443" }, .{ "content-length", "5" } }) |f| try expectEqual(Verdict.ok, verdict(&r, f[0], f[1]));
    try expect(r.end());
    try expect(r.content_length == null);
}

test "h2 fields: te and the connection-specific fields" {
    var r: Request = .{};
    try expectEqual(Verdict.ok, verdict(&r, "te", "trailers"));
    try expectEqual(Verdict.ok, verdict(&r, "te", "TraiLers"));
    try expectEqual(Verdict.malformed, verdict(&r, "te", "gzip"));
    try expectEqual(Verdict.malformed, verdict(&r, "te", "trailers, gzip"));
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade" }) |name| {
        r = .{};
        try expectEqual(Verdict.malformed, verdict(&r, name, "x"));
    }
}

test "h2 fields: empty name" {
    // CVE-2019-9516 was a leak of 0-length names; nothing is allocated
    // here. PLAN §5.4: the request is malformed (a stream reset), in the
    // head and in trailers, whatever came before (nghttp2 drops the field).
    var r: Request = .{};
    try expectEqual(Verdict.ok, verdict(&r, ":method", "GET"));
    try expectEqual(Verdict.malformed, verdict(&r, "", "x"));
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, "", ""));
    r = .{};
    try expectEqual(Verdict.malformed, r.trailer("", "x", .{}));
    try expect(!accepts(cat(get, &.{.{ "", "x" }}), .{}));
}

test "h2 fields: an uppercase name is malformed, other bad bytes are dropped" {
    var r: Request = .{};
    try expectEqual(Verdict.malformed, verdict(&r, "User-Agent", "x"));
    try expectEqual(Verdict.ignore, verdict(&r, "user agent", "x"));
    try expectEqual(Verdict.ignore, verdict(&r, "a\x00", "x"));
    // The first bad byte decides.
    try expectEqual(Verdict.ignore, verdict(&r, "a:B", "x"));
    try expectEqual(Verdict.malformed, verdict(&r, "aB:", "x"));
    // Pseudo-headers: unknown, uppercase, a response's, or after a field.
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, ":foo", "x"));
    try expectEqual(Verdict.malformed, verdict(&r, ":PATH", "/"));
    try expectEqual(Verdict.malformed, verdict(&r, ":status", "200"));
    try expectEqual(Verdict.malformed, verdict(&r, ":", "x"));
    try expectEqual(Verdict.ok, verdict(&r, "accept", "*/*"));
    try expectEqual(Verdict.malformed, verdict(&r, ":method", "GET"));
}

test "h2 fields: whitespace around a value" {
    var r: Request = .{};
    // RFC 9113 §8.2.1: dropped on a regular field ...
    try expectEqual(Verdict.ignore, verdict(&r, "accept", " */*"));
    try expectEqual(Verdict.ignore, verdict(&r, "accept", "*/*\t"));
    try expectEqual(Verdict.ok, verdict(&r, "accept", "*/* ,  x"));
    try expectEqual(Verdict.ok, verdict(&r, "accept", ""));
    // ... malformed on :protocol (and on the other pseudo-headers, whose
    // character sets have no whitespace).
    const ecp: fields.Opts = .{ .connect_protocol = true };
    r = .{};
    try expectEqual(Verdict.malformed, r.field(":protocol", "websocket ", ecp));
    r = .{};
    try expectEqual(Verdict.malformed, r.field(":protocol", "", ecp));
    r = .{};
    try expectEqual(Verdict.ok, r.field(":protocol", "websocket", ecp));
    try expectEqual(Verdict.malformed, r.field(":protocol", "websocket", ecp));
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, ":path", "/ a"));
    try expectEqual(Verdict.malformed, verdict(&r, ":method", "GET "));
}

test "h2 fields: :scheme and :method characters" {
    var r: Request = .{};
    try expectEqual(Verdict.ok, verdict(&r, ":scheme", "coap+tcp-1.0"));
    try expect(!r.seen.scheme_http);
    r = .{};
    try expectEqual(Verdict.ok, verdict(&r, ":scheme", "HTTPS"));
    try expect(r.seen.scheme_http);
    for ([_][]const u8{ "1http", "+a", "ht tp", "http:" }) |s| {
        r = .{};
        try expectEqual(Verdict.malformed, verdict(&r, ":scheme", s));
    }
    r = .{};
    try expectEqual(Verdict.ok, verdict(&r, ":method", "M-SEARCH"));
    r = .{};
    try expectEqual(Verdict.malformed, verdict(&r, ":method", "GE(T"));
    // A non-http scheme takes any :path.
    try expect(accepts(&.{ .{ ":method", "GET" }, .{ ":scheme", "foo" }, .{ ":path", "x" }, .{ ":authority", "a" } }, .{}));
    try expect(!accepts(&.{ .{ ":method", "GET" }, .{ ":scheme", "http" }, .{ ":path", "x" }, .{ ":authority", "a" } }, .{}));
}

test "h2 fields: trailers" {
    var r: Request = .{};
    for (get) |f| _ = verdict(&r, f[0], f[1]);
    try expect(r.end());
    try expectEqual(Verdict.ok, r.trailer("grpc-status", "0", .{}));
    try expectEqual(Verdict.malformed, r.trailer(":path", "/", .{}));
    try expectEqual(Verdict.malformed, r.trailer("connection", "close", .{}));
    try expectEqual(Verdict.ignore, r.trailer("x", " y", .{}));
    // A fresh request's trailer refuses pseudo-headers too.
    r = .{};
    try expectEqual(Verdict.malformed, r.trailer(":method", "GET", .{}));
}

test "h2 fields: matches nghttp2's helpers" {
    if (build_options.use_http2) try Ng.differential() else return error.SkipZigTest;
}

/// nghttp2's six public checks, when it is linked.
const Ng = struct {
    const c = if (build_options.use_http2) @import("nghttp2") else struct {};

    fn differential() !void {
        var buf: [3]u8 = undefined;
        // Every string of up to two bytes, then seeded longer ones.
        try same("");
        for (0..256) |a| {
            buf[0] = @intCast(a);
            try same(buf[0..1]);
            for (0..256) |b| {
                buf[1] = @intCast(b);
                try same(buf[0..2]);
            }
        }
        var prng: std.Random.DefaultPrng = .init(0x6832666c64);
        const r = prng.random();
        const alphabet = " \t:@*/+-.!azAZ09\x00\x1f\x7f\x80\xff\r\n";
        var s: [12]u8 = undefined;
        for (0..20000) |_| {
            const n = r.uintAtMost(usize, s.len);
            for (s[0..n]) |*ch| ch.* = if (r.boolean()) alphabet[r.uintLessThan(usize, alphabet.len)] else r.int(u8);
            try same(s[0..n]);
        }
    }

    fn same(s: []const u8) !void {
        errdefer std.debug.print("differs on \"{f}\"\n", .{std.zig.fmtString(s)});
        try expectEqual(c.nghttp2_check_header_name(s.ptr, s.len) != 0, fields.validName(s));
        try expectEqual(c.nghttp2_check_header_value(s.ptr, s.len) != 0, fields.validValue(s));
        try expectEqual(c.nghttp2_check_header_value_rfc9113(s.ptr, s.len) != 0, fields.validValueRfc9113(s));
        try expectEqual(c.nghttp2_check_method(s.ptr, s.len) != 0, fields.validMethod(s));
        try expectEqual(c.nghttp2_check_path(s.ptr, s.len) != 0, fields.validPath(s));
        try expectEqual(c.nghttp2_check_authority(s.ptr, s.len) != 0, fields.validAuthority(s));
    }
};

test "fuzz: h2 fields" {
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            if (input.len == 0) return;
            const opts: fields.Opts = .{ .connect_protocol = input[0] & 1 != 0, .stream_id = if (input[0] & 2 != 0) 2 else 1 };
            var r: Request = .{};
            // Length-prefixed name, value, name, value, ...
            var rest = input[1..];
            while (rest.len > 0) {
                const name = take(&rest);
                const value = take(&rest);
                const v = if (opts.stream_id == 2) r.trailer(name, value, opts) else r.field(name, value, opts);
                if (v == .ok) {
                    if (name.len == 0) return error.EmptyNameOk;
                    if (!fields.validName(name)) return error.BadNameOk;
                    if (name[0] != ':' and !fields.validValue(value)) return error.BadValueOk;
                }
                if (build_options.use_http2) {
                    try Ng.same(name);
                    try Ng.same(value);
                }
            }
            _ = r.end();
        }

        fn take(rest: *[]const u8) []const u8 {
            if (rest.len == 0) return "";
            const n: usize = @min(rest.*[0], rest.len - 1);
            const s = rest.*[1..][0..n];
            rest.* = rest.*[1 + n ..];
            return s;
        }
    }.check, &.{
        "\x00\x07:method\x03GET\x07:scheme\x05https\x05:path\x01/\x0a:authority\x09localhost",
        "\x01\x07:method\x07CONNECT\x0a:authority\x03a:1\x09:protocol\x09websocket\x05:path\x01/\x07:scheme\x04http",
        "\x00\x00\x01x\x05:path\x01*\x04host\x05a@b.c\x0econtent-length\x02-1\x02te\x04gzip",
        "\x02\x0bgrpc-status\x010\x05:path\x01/\x0aConnection\x05close\x06accept\x02 x",
    });
}
