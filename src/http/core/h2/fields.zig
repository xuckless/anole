// Translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_http.c and lib/nghttp2_helper.c. See LICENSE.nghttp2 and
// THIRD_PARTY_NOTICES.

//! A request's decoded header fields (`Request`) and a response's
//! (`Response`, the client role), checked one at a time against RFC 9113
//! §8.2-8.3 (and RFC 8441's `:protocol`), as nghttp2 checks them.
//! Each field gets one of three verdicts, nghttp2's:
//!
//!   * `ok`: pass it on;
//!   * `ignore`: drop it silently, the stream lives (nghttp2 is lenient with
//!     regular fields: bad bytes in a name or value, whitespace around a
//!     value);
//!   * `malformed`: the request is malformed (RFC 9113 §8.1.1), a stream
//!     error PROTOCOL_ERROR. One departure from nghttp2: an empty name is
//!     malformed here (PLAN §5.4), where nghttp2 drops the field.
//!
//! Then `end` checks the head as a whole (the mandatory pseudo-headers).
//! Nothing is allocated or kept: the slices are the caller's.

const std = @import("std");

pub const Verdict = enum { ok, ignore, malformed };

pub const Opts = struct {
    /// We advertised SETTINGS_ENABLE_CONNECT_PROTOCOL (`:protocol` allowed).
    connect_protocol: bool = false,
    /// The stream's id: CONNECT on an even (pushed) stream is refused.
    stream_id: u31 = 1,
};

/// One request's field state: a few bytes, kept with the stream.
pub const Request = struct {
    seen: Seen = .{},
    /// The parsed content-length, once one was seen.
    content_length: ?u63 = null,

    pub const Seen = packed struct(u16) {
        authority: bool = false,
        path: bool = false,
        method: bool = false,
        scheme: bool = false,
        host: bool = false,
        protocol: bool = false,
        /// A regular field (or an empty name) came: no more pseudo-headers.
        pseudo_disallowed: bool = false,
        connect: bool = false,
        options: bool = false,
        path_regular: bool = false,
        path_asterisk: bool = false,
        scheme_http: bool = false,
        _: u4 = 0,
    };

    /// One field of the request's head (nghttp2_http_on_header).
    pub fn field(r: *Request, name: []const u8, value: []const u8, opts: Opts) Verdict {
        return r.onField(name, value, false, opts);
    }

    /// One field of the request's trailers: pseudo-headers are malformed,
    /// the rest is checked as in the head.
    pub fn trailer(r: *Request, name: []const u8, value: []const u8, opts: Opts) Verdict {
        return r.onField(name, value, true, opts);
    }

    fn onField(r: *Request, name: []const u8, value: []const u8, is_trailer: bool, opts: Opts) Verdict {
        // Strict with pseudo-headers, lenient with regular fields (the
        // reasoning is nghttp2's: there are so many bad ones about).
        // An empty name is no token (RFC 9110 §5.1) and the request is
        // malformed (PLAN §5.4, CVE-2019-9516's case), as in Go's
        // x/net/http2 (validWireHeaderFieldName). nghttp2 drops the field
        // instead: an intentional divergence.
        if (name.len == 0) return .malformed;
        const tok = token(name);
        if (name[0] == ':') {
            if (tok == null or is_trailer or r.seen.pseudo_disallowed) return .malformed;
        } else {
            r.seen.pseudo_disallowed = true;
            // nghttp2_check_nonempty_header_name: the first byte that is
            // not a lowercase token byte decides.
            for (name) |ch| switch (name_chars[ch]) {
                1 => {},
                2 => return .malformed, // field names are lowercase, no exceptions
                else => return .ignore,
            };
        }
        return r.onRequestField(tok, name, value, opts);
    }

    /// http_request_on_header.
    /// (Its trailer flag matters only to nghttp2's priority parse.)
    fn onRequestField(r: *Request, tok: ?Token, name: []const u8, value: []const u8, opts: Opts) Verdict {
        const t = tok orelse {
            if (name[0] == ':') return .malformed;
            return if (validValueRfc9113(value)) .ok else .ignore;
        };
        switch (t) {
            .authority => if (!check(authority_chars_no_at, value) or !r.pseudo(value, .authority)) return .malformed,
            .method => {
                if (!validMethod(value) or !r.pseudo(value, .method)) return .malformed;
                if (std.mem.eql(u8, value, "CONNECT")) {
                    if (opts.stream_id % 2 == 0) return .malformed; // no CONNECT for push
                    r.seen.connect = true;
                } else if (std.mem.eql(u8, value, "OPTIONS")) {
                    r.seen.options = true;
                }
            },
            .path => {
                if (!validPath(value) or !r.pseudo(value, .path)) return .malformed;
                if (value[0] == '/') {
                    r.seen.path_regular = true;
                } else if (value.len == 1 and value[0] == '*') {
                    r.seen.path_asterisk = true;
                }
            },
            .scheme => {
                if (!validScheme(value) or !r.pseudo(value, .scheme)) return .malformed;
                if (std.ascii.eqlIgnoreCase(value, "http") or std.ascii.eqlIgnoreCase(value, "https")) r.seen.scheme_http = true;
            },
            .protocol => {
                if (!opts.connect_protocol or !r.pseudo(value, .protocol)) return .malformed;
                if (!validValueRfc9113(value)) return .malformed;
            },
            .host => {
                if (!check(authority_chars_no_at, value)) return .ignore;
                if (!r.pseudo(value, .host)) return .malformed;
            },
            .content_length => {
                if (r.content_length != null) return .malformed;
                r.content_length = parseContentLength(value) orelse return .malformed;
            },
            .connection, .keep_alive, .proxy_connection, .transfer_encoding, .upgrade => return .malformed,
            .te => if (!std.ascii.eqlIgnoreCase(value, "trailers")) return .malformed,
            // A response's pseudo-header (nghttp2's default case).
            .status => return .malformed,
            // RFC 9218. nghttp2 parses it for its scheduler; Anole
            // schedules nothing by it, so only its value is checked.
            .priority => if (!validValueRfc9113(value)) return .ignore,
        }
        return .ok;
    }

    /// check_pseudo_header: a pseudo-header (and host) at most once, never
    /// empty.
    fn pseudo(r: *Request, value: []const u8, comptime which: enum { authority, path, method, scheme, host, protocol }) bool {
        if (@field(r.seen, @tagName(which)) or value.len == 0) return false;
        @field(r.seen, @tagName(which)) = true;
        return true;
    }

    /// The head is complete (nghttp2_http_on_request_headers): false means
    /// it is malformed.
    pub fn end(r: *Request) bool {
        const s = r.seen;
        if (!s.protocol and s.connect) {
            // A plain CONNECT (RFC 9113 §8.5): :authority, no :scheme or
            // :path; its body is a tunnel, so content-length is moot.
            if (s.scheme or s.path or !s.authority) return false;
            r.content_length = null;
            return true;
        }
        if (!(s.method and s.path and s.scheme) or !(s.authority or s.host)) return false;
        // Extended CONNECT (RFC 8441 §4).
        if (s.protocol and (!s.connect or !s.authority)) return false;
        // check_path: for http(s), "*" only with OPTIONS, else "/...".
        return !s.scheme_http or s.path_regular or (s.options and s.path_asterisk);
    }
};

/// A response's fields (nghttp2's http_response_on_header, with
/// nghttp2_http_on_header's common checks first), one header block at a
/// time: an informational (1xx) head, the final head, or trailers. `end`
/// checks a head as a whole; the caller (conn.zig) applies what follows
/// from its status (nghttp2_http_on_response_headers).
pub const Response = struct {
    /// A regular field came: no more pseudo-headers.
    pseudo_disallowed: bool = false,
    /// The head's `:status`, once seen.
    status: ?u16 = null,
    /// The parsed content-length, once one was seen (0 for a 204's,
    /// which is dropped).
    content_length: ?u63 = null,

    /// One field of a response head.
    pub fn field(r: *Response, name: []const u8, value: []const u8) Verdict {
        return r.onField(name, value, false);
    }

    /// One field of the response's trailers: pseudo-headers are
    /// malformed, the rest is checked as in the head.
    pub fn trailer(r: *Response, name: []const u8, value: []const u8) Verdict {
        return r.onField(name, value, true);
    }

    fn onField(r: *Response, name: []const u8, value: []const u8, is_trailer: bool) Verdict {
        // As in `Request.onField` (the empty name is the same divergence).
        if (name.len == 0) return .malformed;
        const tok = token(name);
        if (name[0] == ':') {
            if (tok == null or is_trailer or r.pseudo_disallowed) return .malformed;
        } else {
            r.pseudo_disallowed = true;
            for (name) |ch| switch (name_chars[ch]) {
                1 => {},
                2 => return .malformed,
                else => return .ignore,
            };
        }
        const t = tok orelse return if (validValueRfc9113(value)) .ok else .ignore;
        switch (t) {
            .status => {
                // check_pseudo_header, then parse_status_code; 101 has no
                // place in HTTP/2 (RFC 9113 §8.6).
                if (r.status != null) return .malformed;
                const code = parseStatus(value) orelse return .malformed;
                if (code == 101) return .malformed;
                r.status = code;
            },
            .content_length => {
                const status = r.status orelse 0;
                if (status == 204) {
                    // Prohibited (RFC 9110 §8.6), but widely sent as "0":
                    // nghttp2 drops that one.
                    if (r.content_length != null or !std.mem.eql(u8, value, "0")) return .malformed;
                    r.content_length = 0;
                    return .ignore;
                }
                if (status / 100 == 1) return .malformed;
                if (r.content_length != null) return .malformed;
                r.content_length = parseContentLength(value) orelse return .malformed;
            },
            .connection, .keep_alive, .proxy_connection, .transfer_encoding, .upgrade => return .malformed,
            .te => if (!std.ascii.eqlIgnoreCase(value, "trailers")) return .malformed,
            // The request's pseudo-headers.
            .authority, .method, .path, .scheme, .protocol => return .malformed,
            .host, .priority => if (!validValueRfc9113(value)) return .ignore,
        }
        return .ok;
    }

    /// The head is complete (nghttp2_http_on_response_headers' first
    /// check): false means it is malformed.
    pub fn end(r: *const Response) bool {
        return r.status != null;
    }
};

/// parse_status_code: three digits, the first not 0.
fn parseStatus(s: []const u8) ?u16 {
    if (s.len != 3 or s[0] < '1' or s[0] > '9') return null;
    for (s[1..]) |ch| if (ch < '0' or ch > '9') return null;
    return (@as(u16, s[0] - '0') * 100) + (s[1] - '0') * 10 + (s[2] - '0');
}

/// The names the checks care about (nghttp2's generated lookup_token, cut
/// down to them).
const Token = enum {
    status,
    authority,
    method,
    path,
    scheme,
    protocol,
    host,
    content_length,
    connection,
    keep_alive,
    proxy_connection,
    transfer_encoding,
    upgrade,
    te,
    priority,
};

fn token(name: []const u8) ?Token {
    const eql = std.mem.eql;
    return switch (name.len) {
        2 => if (eql(u8, name, "te")) .te else null,
        4 => if (eql(u8, name, "host")) .host else null,
        5 => if (eql(u8, name, ":path")) .path else null,
        7 => if (eql(u8, name, ":method")) .method else if (eql(u8, name, ":scheme")) .scheme else if (eql(u8, name, ":status")) .status else if (eql(u8, name, "upgrade")) .upgrade else null,
        8 => if (eql(u8, name, "priority")) .priority else null,
        9 => if (eql(u8, name, ":protocol")) .protocol else null,
        10 => if (eql(u8, name, ":authority")) .authority else if (eql(u8, name, "connection")) .connection else if (eql(u8, name, "keep-alive")) .keep_alive else null,
        14 => if (eql(u8, name, "content-length")) .content_length else null,
        16 => if (eql(u8, name, "proxy-connection")) .proxy_connection else null,
        17 => if (eql(u8, name, "transfer-encoding")) .transfer_encoding else null,
        else => null,
    };
}

/// nghttp2's character tables, built at comptime: `bytes` and, with
/// `high`, 0x80-0xff.
fn table(comptime bytes: anytype, comptime high: bool) [256]u8 {
    var t: [256]u8 = @splat(0);
    for (bytes) |ch| t[ch] = 1;
    if (high) for (0x80..0x100) |ch| {
        t[ch] = 1;
    };
    return t;
}

fn range(comptime lo: u8, comptime hi: u8) [hi - lo + 1]u8 {
    var s: [hi - lo + 1]u8 = undefined;
    for (&s, lo..) |*ch, v| ch.* = @intCast(v);
    return s;
}

const tchar_symbols = "!#$%&'*+-.^_`|~";
const digits = range('0', '9');
const lower = range('a', 'z');
const upper = range('A', 'Z');

/// VALID_HD_NAME_CHARS: 1 for a token byte, 2 for an uppercase letter.
const name_chars = blk: {
    var t = table(tchar_symbols ++ digits ++ lower, false);
    for (upper) |ch| t[ch] = 2;
    break :blk t;
};
/// VALID_HD_VALUE_CHARS: HTAB, SP, VCHAR, obs-text.
const value_chars = table("\t" ++ range(' ', '~'), true);
/// VALID_METHOD_CHARS: tchar.
const method_chars = table(tchar_symbols ++ digits ++ lower ++ upper, false);
/// VALID_PATH_CHARS: VCHAR, obs-text.
const path_chars = table(range('!', '~'), true);
const authority_symbols = "!$%&'()*+,-.:;=[]_~";
/// VALID_AUTHORITY_CHARS (nghttp2_helper.c).
const authority_chars = table(authority_symbols ++ "@" ++ digits ++ lower ++ upper, false);
/// nghttp2_http.c's copy, without '@' (no userinfo in :authority or host).
const authority_chars_no_at = table(authority_symbols ++ digits ++ lower ++ upper, false);

fn check(comptime t: [256]u8, s: []const u8) bool {
    for (s) |ch| if (t[ch] == 0) return false;
    return true;
}

/// nghttp2_check_header_name: a token, all lowercase, optionally after one
/// ':'; not empty, not ":".
pub fn validName(name: []const u8) bool {
    var s = name;
    if (s.len == 0) return false;
    if (s[0] == ':') {
        if (s.len == 1) return false;
        s = s[1..];
    }
    for (s) |ch| if (name_chars[ch] != 1) return false;
    return true;
}

/// nghttp2_check_header_value: HTAB, SP, VCHAR and obs-text.
pub fn validValue(value: []const u8) bool {
    return check(value_chars, value);
}

/// nghttp2_check_header_value_rfc9113: `validValue`, and no leading or
/// trailing SP or HTAB (RFC 9113 §8.2.1).
pub fn validValueRfc9113(value: []const u8) bool {
    if (value.len == 0) return true;
    const ws = struct {
        fn f(ch: u8) bool {
            return ch == ' ' or ch == '\t';
        }
    }.f;
    if (ws(value[0]) or ws(value[value.len - 1])) return false;
    return validValue(value);
}

/// nghttp2_check_method: a non-empty token.
pub fn validMethod(value: []const u8) bool {
    return value.len > 0 and check(method_chars, value);
}

/// nghttp2_check_path: VCHAR and obs-text (empty passes; `:path` being
/// non-empty is checked with the pseudo-header).
pub fn validPath(value: []const u8) bool {
    return check(path_chars, value);
}

/// nghttp2_check_authority (nghttp2_helper.c, '@' allowed).
pub fn validAuthority(value: []const u8) bool {
    return check(authority_chars, value);
}

/// check_scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) (RFC 3986 §3.1).
fn validScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

/// parse_uint: digits only, at most INT64_MAX; no sign, no whitespace.
pub fn parseContentLength(s: []const u8) ?u63 {
    if (s.len == 0) return null;
    var n: u63 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        n = std.math.mul(u63, n, 10) catch return null;
        n = std.math.add(u63, n, ch - '0') catch return null;
    }
    return n;
}
