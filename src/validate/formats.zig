// Copied from vkiryakov/zefir src/validator/formats.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Format rules: numbers, booleans and coordinates written as strings
//! (`numberString`, `decimal`, `booleanString`, `hexadecimal`, `octal`,
//! `port`, `latitude`, `longitude`, `latLong`) and network addresses and
//! names (`email`, `httpUrl`, `fqdn`, `ip`, `ipv4`, `ipv6`, `macAddress`),
//! each with its predicate (`isNumberString`, ...). Every grammar is ASCII
//! and is read byte by byte: nothing is trimmed or decoded, so invalid UTF-8
//! and any byte >= 0x80 fail under the rule's own code, and "" fails every
//! rule of this file. A predicate takes any bytes, never allocates, never
//! backtracks and runs in O(n); `v.isX(s)` is true exactly when the rule
//! `v.x` passes `s`.
//! `latitude` and `longitude` also take float fields, where they are range
//! checks behind the finite precondition; their predicates cover strings
//! only.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

/// How compile errors and hints show the options of a rule:
/// `decimal(.{...})`, `use v.each(v.decimal(.{...}))`, whatever the options.
const options_args = ".{...}";

// ------------------------------------------------------------------ options

/// The options of `v.decimal(.{ ... })` and `v.isDecimal`, the names of
/// validator.js `isDecimal` (en-US).
pub const DecimalOptions = struct {
    /// The point and at least `min_decimal_digits` digits after it are
    /// required: "12" fails.
    force_decimal: bool = false,
    /// The fewest digits after the point, when there is one; at least 1 in
    /// the rule.
    min_decimal_digits: usize = 1,
    /// The most digits after the point; null for no limit. When set, at
    /// least `min_decimal_digits` in the rule.
    max_decimal_digits: ?usize = null,
};

/// The options of `v.fqdn(.{ ... })` and `v.isFqdn`, with the names and
/// defaults of validator.js `isFQDN`. Every combination is valid.
pub const FqdnOptions = struct {
    /// At least two labels, and a last label (the top-level domain) of 2 or
    /// more ASCII letters, or "xn" in any case followed by 2 or more letters,
    /// digits or hyphens (an IDN TLD such as "xn--p1ai"). When false, one
    /// label is enough: "localhost".
    require_tld: bool = true,
    /// '_' may appear in labels, as in "_dmarc.example.com".
    allow_underscores: bool = false,
    /// One '.' may end the name, the absolute form "example.com.".
    allow_trailing_dot: bool = false,
    /// The name may start with "*.", as in "*.example.com".
    allow_wildcard: bool = false,
};

/// The options of `v.macAddress(.{ ... })` and `v.isMacAddress`, after
/// validator.js `isMACAddress`. Every combination is valid.
pub const MacAddressOptions = struct {
    /// The sizes that pass: `.any` for EUI-48 (6 octets) or EUI-64 (8
    /// octets), `.eui48` or `.eui64` for one of them.
    eui: Eui = .any,
    /// `.separated`: two-digit octets joined by ':', '-' or a space, the same
    /// one throughout, or groups of four digits joined by '.'. `.bare`: hex
    /// digits only.
    format: Format = .separated,

    pub const Eui = enum { any, eui48, eui64 };
    pub const Format = enum { separated, bare };
};

// ------------------------------------------------------------------ numbers in strings

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// The length of the run of ASCII digits at the start of `s`.
fn digitRun(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isDigit(s[i])) i += 1;
    return i;
}

/// `s` without one leading '+' or '-'.
fn skipSign(s: []const u8) []const u8 {
    return if (s.len != 0 and (s[0] == '+' or s[0] == '-')) s[1..] else s;
}

/// The value of 1-3 ASCII digits; callers check the length of the run.
fn smallValue(digits: []const u8) u16 {
    var value: u16 = 0;
    for (digits) |c| value = value * 10 + (c - '0');
    return value;
}

/// A number in decimal notation, as validator.js `isNumeric` reads it with
/// its default options: one optional leading '+' or '-', then 1 or more
/// ASCII digits, or 0 or more digits, '.', and 1 or more digits (".5" and
/// "-.5" pass). No exponent, digit grouping, '_' or whitespace; the
/// magnitude is not limited, so combine the rule with a length limit.
pub fn isNumberString(s: []const u8) bool {
    const r = skipSign(s);
    const whole = digitRun(r);
    if (whole == r.len) return whole != 0;
    if (r[whole] != '.') return false;
    const fraction = r[whole + 1 ..];
    return fraction.len != 0 and core.allDigits(fraction);
}

/// A decimal number, as validator.js `isDecimal` reads it with these
/// options and the en-US locale: one optional leading '+' or '-', a run of
/// ASCII digits, then either the end (when `force_decimal` is false and the
/// run is not empty) or '.' and only digits, from `min_decimal_digits` to
/// `max_decimal_digits` of them. The digits before the point may be absent
/// (".5"). With the default options it accepts exactly what
/// `isNumberString` accepts. The options are applied as given:
/// `min_decimal_digits = 0` accepts "1." and ".", which the rule refuses at
/// compile time.
pub fn isDecimal(s: []const u8, options: DecimalOptions) bool {
    const r = skipSign(s);
    const whole = digitRun(r);
    if (whole == r.len) return !options.force_decimal and whole != 0;
    if (r[whole] != '.') return false;
    const fraction = r[whole + 1 ..];
    if (!core.allDigits(fraction)) return false;
    if (fraction.len < options.min_decimal_digits) return false;
    if (options.max_decimal_digits) |most| {
        if (fraction.len > most) return false;
    }
    return true;
}

/// Exactly "true", "false", "1" or "0", as validator.js `isBoolean` with its
/// default options: case-sensitive, without "yes", "no" or "on".
pub fn isBooleanString(s: []const u8) bool {
    for ([_][]const u8{ "true", "false", "1", "0" }) |literal| {
        if (std.mem.eql(u8, s, literal)) return true;
    }
    return false;
}

/// A hexadecimal number, as validator.js `isHexadecimal`: an optional
/// prefix "0x", "0X", "0h" or "0H", then 1 or more digits 0-9, a-f, A-F in
/// any case. No sign, '#', 'h' suffix or separators; the prefix counts
/// toward length rules.
pub fn isHexadecimal(s: []const u8) bool {
    const prefixed = s.len >= 2 and s[0] == '0' and switch (s[1]) {
        'x', 'X', 'h', 'H' => true,
        else => false,
    };
    const digits = if (prefixed) s[2..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// An octal number, as validator.js `isOctal`: an optional prefix "0o" or
/// "0O", then 1 or more digits 0-7. No sign and no other prefix; "017" is
/// octal digits only.
pub fn isOctal(s: []const u8) bool {
    const prefixed = s.len >= 2 and s[0] == '0' and (s[1] == 'o' or s[1] == 'O');
    const digits = if (prefixed) s[2..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (c < '0' or c > '7') return false;
    }
    return true;
}

/// A TCP or UDP port as text, 0 to 65535: 1-5 ASCII digits without a
/// leading zero, unless the port is "0" itself. No sign (validator.js
/// `isPort` lets "+80" and "-0" through).
pub fn isPort(s: []const u8) bool {
    if (s.len == 0 or s.len > 5) return false;
    if (s.len > 1 and s[0] == '0') return false;
    var value: u32 = 0;
    for (s) |c| {
        if (!isDigit(c)) return false;
        value = value * 10 + (c - '0');
    }
    return value <= 65535;
}

// ------------------------------------------------------------------ coordinates

/// What follows the whole degrees of a coordinate: nothing, or '.' and 1 or
/// more ASCII digits, all '0' at the limit (90 or 180).
fn coordinateFraction(rest: []const u8, at_limit: bool) bool {
    if (rest.len == 0) return true;
    if (rest[0] != '.' or rest.len == 1) return false;
    for (rest[1..]) |c| {
        if (!isDigit(c)) return false;
        if (at_limit and c != '0') return false;
    }
    return true;
}

/// A latitude in decimal degrees, -90 to 90, as the latitude of validator.js
/// `isLatLong`: one optional leading '+' or '-', 1 or 2 digits of whole
/// degrees (2 digits do not start with '0': "05" fails), then nothing or
/// '.' and 1 or more digits, all '0' after 90. No ',', whitespace, exponent,
/// degree sign or hemisphere letter. The string form only: on a float field
/// the rule `v.latitude` is a range check.
pub fn isLatitude(s: []const u8) bool {
    const r = skipSign(s);
    const whole = digitRun(r);
    if (whole == 0 or whole > 2) return false;
    if (whole == 2 and r[0] == '0') return false;
    const degrees = smallValue(r[0..whole]);
    if (degrees > 90) return false;
    return coordinateFraction(r[whole..], degrees == 90);
}

/// A longitude in decimal degrees, -180 to 180, as the longitude of
/// validator.js `isLatLong`: one optional leading '+' or '-', 1 to 3 digits
/// of whole degrees (3 digits start with '1': "099" fails; 2 digits may start
/// with '0': "05" passes), then nothing or '.' and 1 or more digits, all '0'
/// after 180. No leading whitespace and no ','. The string form only, as
/// `isLatitude`.
pub fn isLongitude(s: []const u8) bool {
    const r = skipSign(s);
    const whole = digitRun(r);
    if (whole == 0 or whole > 3) return false;
    if (whole == 3 and r[0] != '1') return false;
    const degrees = smallValue(r[0..whole]);
    if (degrees > 180) return false;
    return coordinateFraction(r[whole..], degrees == 180);
}

/// A "latitude,longitude" pair, as validator.js `isLatLong` without DMS:
/// optionally in parentheses, "(lat,long)"; exactly one ',', and after it at
/// most one space (the byte 0x20). The order is not checked beyond the
/// ranges: a swapped pair passes when its longitude is within -90 to 90.
pub fn isLatLong(s: []const u8) bool {
    var pair = s;
    if (s.len != 0 and s[0] == '(') {
        if (s[s.len - 1] != ')') return false;
        // s.len >= 2 here: its first byte is '(' and its last is ')'.
        pair = s[1 .. s.len - 1];
    } else if (s.len != 0 and s[s.len - 1] == ')') return false;
    const comma = std.mem.findScalar(u8, pair, ',') orelse return false;
    var second = pair[comma + 1 ..];
    if (std.mem.findScalar(u8, second, ',') != null) return false;
    if (second.len != 0 and second[0] == ' ') second = second[1..];
    return isLatitude(pair[0..comma]) and isLongitude(second);
}

// ------------------------------------------------------------------ IP addresses

/// An IPv4 address in dotted decimal, as RFC 3986 `IPv4address` and
/// validator.js `isIP(s, 4)`: four numbers from 0 to 255 joined by '.', each
/// without leading zeros ("0" itself is fine). No shorthand ("127.1"),
/// single number, hex or octal parts, sign, prefix length, port or
/// whitespace.
pub fn isIpv4(s: []const u8) bool {
    // From "0.0.0.0" to "255.255.255.255".
    if (s.len < 7 or s.len > 15) return false;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        parts += 1;
        if (parts > 4 or !isDecOctet(part)) return false;
    }
    return parts == 4;
}

/// A number from 0 to 255 in 1-3 ASCII digits without a leading zero.
fn isDecOctet(part: []const u8) bool {
    if (part.len == 0 or part.len > 3) return false;
    if (part.len > 1 and part[0] == '0') return false;
    return core.allDigits(part) and smallValue(part) <= 255;
}

/// An IPv6 address in the text forms of RFC 4291 (RFC 3986 `IPv6address`):
/// 8 groups of 1-4 hex digits in any case joined by ':', or fewer around one
/// "::" that stands for one or more zero groups; the last 32 bits may be an
/// IPv4 address ("::ffff:192.0.2.1"). Leading zeros and uppercase pass. No
/// zone id ("fe80::1%eth0"), brackets or prefix length.
pub fn isIpv6(s: []const u8) bool {
    // From "::" to "0000:0000:0000:0000:0000:ffff:255.255.255.255".
    if (s.len < 2 or s.len > 45) return false;
    const gap = std.mem.find(u8, s, "::") orelse return (ipv6Groups(s, true) orelse return false) == 8;
    const head = s[0..gap];
    const tail = s[gap + 2 ..];
    if (std.mem.find(u8, tail, "::") != null) return false;
    const head_groups = if (head.len == 0) 0 else ipv6Groups(head, false) orelse return false;
    const tail_groups = if (tail.len == 0) 0 else ipv6Groups(tail, true) orelse return false;
    return head_groups + tail_groups <= 7;
}

/// The number of 16-bit groups in `s`, groups of 1-4 hex digits joined by
/// ':'; when `allow_ipv4`, the last one may be an IPv4 address, worth 2.
/// Null when a group is malformed.
fn ipv6Groups(s: []const u8, allow_ipv4: bool) ?usize {
    var groups: usize = 0;
    var it = std.mem.splitScalar(u8, s, ':');
    while (it.next()) |group| {
        if (allow_ipv4 and it.peek() == null and std.mem.findScalar(u8, group, '.') != null) {
            if (!isIpv4(group)) return null;
            groups += 2;
        } else {
            if (group.len == 0 or group.len > 4 or !core.allHex(group)) return null;
            groups += 1;
        }
    }
    return groups;
}

/// An IPv4 or an IPv6 address: `isIpv4(s) or isIpv6(s)`; no string is both.
pub fn isIp(s: []const u8) bool {
    return isIpv4(s) or isIpv6(s);
}

// ------------------------------------------------------------------ MAC addresses

/// A MAC address in the sizes and the format of `options`, as validator.js
/// `isMACAddress`: separated, "00:1A:2B:3C:4D:5E", "00-1a-2b-3c-4d-5e",
/// "00 1a 2b 3c 4d 5e" or "001a.2b3c.4d5e"; bare, "001A2B3C4D5E". Only the
/// byte 0x20 is a space: a tab or a line feed is not a separator. The
/// options are applied as given.
pub fn isMacAddress(s: []const u8, options: MacAddressOptions) bool {
    const sizes: []const usize = switch (options.eui) {
        .any => &.{ 6, 8 },
        .eui48 => &.{6},
        .eui64 => &.{8},
    };
    for (sizes) |octets| {
        const matches = switch (options.format) {
            .bare => s.len == 2 * octets and core.allHex(s),
            .separated => isGrouped(s, octets, 2, ":- ") or isGrouped(s, octets, 4, "."),
        };
        if (matches) return true;
    }
    return false;
}

/// `octets` written as groups of `digits` hex digits joined by one byte of
/// `separators`, the same byte throughout.
fn isGrouped(s: []const u8, octets: usize, digits: usize, separators: []const u8) bool {
    const count = 2 * octets / digits;
    if (s.len != count * digits + count - 1) return false;
    const separator = s[digits];
    if (std.mem.findScalar(u8, separators, separator) == null) return false;
    for (s, 0..) |c, i| {
        if ((i + 1) % (digits + 1) == 0) {
            if (c != separator) return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ domain names

/// The longest domain name without the trailing dot, in bytes: 255 octets
/// on the wire (RFC 1035) less the first length byte and the root's zero.
const max_domain_bytes = 253;

/// A domain name, as validator.js `isFQDN` reads it with these options, but
/// ASCII only and at most 253 bytes (254 with an allowed trailing dot):
/// labels of 1-63 letters, digits and hyphens (and '_' with
/// `allow_underscores`) joined by '.', without a hyphen at either end of a
/// label; the last label is not all digits, and with `require_tld` there are
/// at least two labels and the last one is a top-level domain (see
/// `FqdnOptions`). "xn--" labels are not checked as Punycode. The options
/// are applied as given.
pub fn isFqdn(s: []const u8, options: FqdnOptions) bool {
    var name = s;
    if (options.allow_trailing_dot and name.len != 0 and name[name.len - 1] == '.') name = name[0 .. name.len - 1];
    if (name.len == 0 or name.len > max_domain_bytes) return false;
    if (options.allow_wildcard and std.mem.startsWith(u8, name, "*.")) name = name[2..];
    var labels: usize = 0;
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (!isLabel(label, options.allow_underscores)) return false;
        labels += 1;
        last = label;
    }
    // `last` passed isLabel, so it is not empty.
    if (core.allDigits(last)) return false;
    if (options.require_tld) return labels >= 2 and isTld(last);
    return true;
}

/// A label of a host name: 1-63 letters, digits and hyphens (and '_' when
/// allowed), not starting or ending with '-'.
fn isLabel(label: []const u8, allow_underscores: bool) bool {
    if (label.len == 0 or label.len > 63) return false;
    if (label[0] == '-' or label[label.len - 1] == '-') return false;
    for (label) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-') continue;
        if (c == '_' and allow_underscores) continue;
        return false;
    }
    return true;
}

/// A top-level domain, as the TLD pattern of validator.js `isFQDN`: 2 or
/// more ASCII letters, or 'x' or 'X', 'n' or 'N' and 2 or more letters,
/// digits or hyphens. The registry writes IDN TLDs in uppercase
/// ("XN--P1AI"), so "xn" is matched in any case.
fn isTld(tld: []const u8) bool {
    if (tld.len < 2) return false;
    for (tld) |c| {
        if (!std.ascii.isAlphabetic(c)) break;
    } else return true;
    if (tld.len < 4 or std.ascii.toLower(tld[0]) != 'x' or std.ascii.toLower(tld[1]) != 'n') return false;
    for (tld[2..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

// ------------------------------------------------------------------ email

/// A byte of RFC 5322 `atext`: a letter, a digit or one of
/// ``!#$%&'*+-/=?^_`{|}~``.
fn isAtext(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

/// An email address, ASCII only: at most 254 bytes; before the first '@' a
/// local part of 1-64 bytes of `atext` and '.', without a '.' at either end
/// or two in a row; after it a domain that `isFqdn(domain, .{})` accepts, so
/// at least two labels and a top-level domain. No quoted local part, IP
/// literal or non-ASCII byte; a second '@' fails in the domain.
pub fn isEmail(s: []const u8) bool {
    // The longest path of RFC 5321, 256 bytes, less its "<" and ">".
    if (s.len > 254) return false;
    const at = std.mem.findScalar(u8, s, '@') orelse return false;
    const local = s[0..at];
    if (local.len == 0 or local.len > 64) return false;
    if (local[0] == '.' or local[local.len - 1] == '.') return false;
    var after_dot = false;
    for (local) |c| {
        if (c == '.') {
            if (after_dot) return false;
            after_dot = true;
        } else {
            if (!isAtext(c)) return false;
            after_dot = false;
        }
    }
    return isFqdn(s[at + 1 ..], .{});
}

// ------------------------------------------------------------------ HTTP URLs

/// A label that makes a host an IPv4 address in URLs: all digits, or "0x"
/// or "0X" and hex digits.
fn endsInNumber(label: []const u8) bool {
    if (label.len != 0 and core.allDigits(label)) return true;
    return label.len >= 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X') and core.allHex(label[2..]);
}

/// A host name or an IPv4 address in a URL: without one trailing '.', 1-253
/// bytes of labels of letters, digits and hyphens (one label is enough);
/// when its last label is a number, the host as written must be an IPv4
/// address.
fn isUrlHost(host: []const u8) bool {
    const name = if (host.len != 0 and host[host.len - 1] == '.') host[0 .. host.len - 1] else host;
    if (name.len == 0 or name.len > max_domain_bytes) return false;
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (!isLabel(label, false)) return false;
        last = label;
    }
    if (endsInNumber(last)) return isIpv4(host);
    return true;
}

/// A port in a URL: 1-5 ASCII digits, from 1 to 65535, leading zeros
/// allowed ("080"), unlike `isPort`.
fn isUrlPort(text: []const u8) bool {
    if (text.len == 0 or text.len > 5 or !core.allDigits(text)) return false;
    var value: u32 = 0;
    for (text) |c| value = value * 10 + (c - '0');
    return value >= 1 and value <= 65535;
}

/// The authority of a URL: `[IPv6]` or a host, then an optional ':' and
/// port; no userinfo.
fn isAuthority(authority: []const u8) bool {
    if (authority.len == 0) return false;
    if (std.mem.findScalar(u8, authority, '@') != null) return false;
    var port_text: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return false;
        if (!isIpv6(authority[1..close])) return false;
        const after = authority[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return false;
            port_text = after[1..];
        }
    } else {
        var host = authority;
        if (std.mem.findScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        }
        if (!isUrlHost(host)) return false;
    }
    if (port_text) |text| {
        if (!isUrlPort(text)) return false;
    }
    return true;
}

/// The path, query and fragment of a URL: bytes from 0x21 to 0x7E except
/// '"', '<', '>' and '\', '%' followed by 2 hex digits, at most one '#'.
fn isUrlTail(tail: []const u8) bool {
    var seen_hash = false;
    var i: usize = 0;
    while (i < tail.len) : (i += 1) {
        const c = tail[i];
        if (c < 0x21 or c > 0x7E or c == '"' or c == '<' or c == '>' or c == '\\') return false;
        if (c == '%') {
            if (tail.len - i < 3 or !std.ascii.isHex(tail[i + 1]) or !std.ascii.isHex(tail[i + 2])) return false;
            i += 2;
        } else if (c == '#') {
            if (seen_hash) return false;
            seen_hash = true;
        }
    }
    return true;
}

/// An http or https URL: "http://" or "https://" in any case, then the
/// authority up to the first '/', '?' or '#': `[IPv6]`, an IPv4 address or
/// a host name (one label is enough, a trailing dot is allowed, at most 253
/// bytes without it), an optional port from 1 to 65535 (leading zeros
/// allowed) and no userinfo; then the path, query and fragment: printable
/// ASCII without '"', '<', '>' and '\', '%' followed by 2 hex digits, at
/// most one '#'. The length is not limited. It checks syntax only:
/// "http://127.0.0.1" and "http://169.254.169.254" pass.
pub fn isHttpUrl(s: []const u8) bool {
    const rest = if (std.ascii.startsWithIgnoreCase(s, "https://"))
        s["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(s, "http://"))
        s["http://".len..]
    else
        return false;
    const end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
    return isAuthority(rest[0..end]) and isUrlTail(rest[end..]);
}

// ------------------------------------------------------------------ rules

/// The hint a rule of `kind` gives on the field type `T` that it does not
/// take, for the field types it has one for; the `[N]u8` and
/// `use v.each(...)` hints of `core.typeErrorText` come first.
fn typeHint(comptime kind: core.Kind, comptime T: type) ?[]const u8 {
    return switch (kind) {
        .number_string, .decimal, .hexadecimal, .octal => if (core.isNumber(T)) core.hints.already_a_number else null,
        .boolean_string => if (T == bool) core.hints.bool_needs_no_rule else if (core.isNumber(T)) core.hints.use_bool_field else null,
        .port => if (core.isNumber(T)) core.hints.port_on_number else null,
        .latitude => if (@typeInfo(T) == .int) core.hints.latitude_on_int else null,
        .longitude => if (@typeInfo(T) == .int) core.hints.longitude_on_int else null,
        .lat_long => if (core.isNumber(T)) core.hints.lat_long_on_number else null,
        else => null,
    };
}

/// The declaration error of a string rule of this file on the unwrapped
/// field type `T`, or null: the field is a string. The hint of `typeHint`
/// follows when it has one for `T`.
fn formatProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    return core.stringProblem(rule, T, where, typeHint(rule.kind, T));
}

/// The field-type check of the string rules of this file.
fn formatFits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (formatProblem(rule, T, where)) |text| @compileError(text);
}

/// A number in decimal notation, as `isNumberString` reads it: "-12.5" and
/// ".5" pass, "1e5", "1,000" and " 1" fail. class-validator `@IsNumberString()`.
pub const numberString: Rule = core.predicateRuleFits(.number_string, "must be a number", isNumberString, formatFits);

/// A decimal number with as many digits after the point as the options
/// allow, as `isDecimal` reads it. `v.decimal(.{})` accepts what
/// `v.numberString` accepts. `min_decimal_digits` is at least 1, and
/// `max_decimal_digits`, when set, is not less than it: other options are a
/// compile error at the call. The default message names the digits the
/// options require; its placeholders are `{min_decimal_digits}` and, when it
/// is set, `{max_decimal_digits}`. class-validator `@IsDecimal()`.
pub fn decimal(comptime options: DecimalOptions) Rule {
    @setEvalBranchQuota(core.eval_quota);
    if (decimalCallProblem(options)) |text| @compileError(text);
    return core.define(.decimal, .{
        .message = decimalMessage(options),
        .args = options_args,
        .params = decimalParams(options),
        .fits = formatFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isDecimal(value.*, options));
            }
        }.eval,
    });
}

/// The error of the call `decimal(options)`, or null: at least 1 digit after
/// the point, and a maximum, when set, not below the minimum.
fn decimalCallProblem(comptime options: DecimalOptions) ?[]const u8 {
    const head = "validator: decimal(" ++ options_args ++ "): ";
    if (options.min_decimal_digits == 0) return head ++ "min_decimal_digits must be at least 1 (0 would accept \"1.\" and \".\")";
    const most = options.max_decimal_digits orelse return null;
    if (most < options.min_decimal_digits)
        return head ++ std.fmt.comptimePrint("max_decimal_digits ({d}) is less than min_decimal_digits ({d})", .{ most, options.min_decimal_digits });
    return null;
}

/// The parameters of `decimal(options)`, in the order of the options:
/// `force_decimal` as data only, `{min_decimal_digits}`, and
/// `{max_decimal_digits}` only when it is set.
fn decimalParams(comptime options: DecimalOptions) []const core.Param {
    const force = core.dataParam("force_decimal", options.force_decimal);
    const fewest = core.param("min_decimal_digits", options.min_decimal_digits);
    const most = options.max_decimal_digits orelse return &.{ force, fewest };
    return &.{ force, fewest, core.param("max_decimal_digits", most) };
}

/// `n decimal places`, or `1 decimal place`.
fn places(comptime n: usize) []const u8 {
    return core.plural(n, "decimal place", "decimal places");
}

/// The default message of `decimal(options)`: one of 8 texts chosen by the
/// options.
fn decimalMessage(comptime options: DecimalOptions) []const u8 {
    const fewest = options.min_decimal_digits;
    if (!options.force_decimal) {
        const most = options.max_decimal_digits orelse {
            if (fewest == 1) return "must be a decimal number";
            return "must be a whole number or have at least " ++ places(fewest);
        };
        if (fewest == 1) return "must be a decimal number with at most " ++ places(most);
        if (fewest == most) return "must be a whole number or have exactly " ++ places(fewest);
        return std.fmt.comptimePrint("must be a whole number or have {d} to {d} decimal places", .{ fewest, most });
    }
    const most = options.max_decimal_digits orelse return "must be a decimal number with at least " ++ places(fewest);
    if (fewest == most) return "must be a decimal number with exactly " ++ places(fewest);
    return std.fmt.comptimePrint("must be a decimal number with {d} to {d} decimal places", .{ fewest, most });
}

/// Exactly "true", "false", "1" or "0", case-sensitive. On a `bool` field
/// the rule is a compile error: the field is already a boolean.
/// class-validator `@IsBooleanString()`.
pub const booleanString: Rule = core.predicateRuleFits(.boolean_string, "must be true, false, 1 or 0", isBooleanString, formatFits);

/// Hexadecimal digits with an optional "0x" or "0h" prefix in any case:
/// "0xDEADbeef" and "ff" pass, "0x" and "#ff" fail. class-validator
/// `@IsHexadecimal()`.
pub const hexadecimal: Rule = core.predicateRuleFits(.hexadecimal, "must be a hexadecimal number", isHexadecimal, formatFits);

/// Octal digits with an optional "0o" or "0O" prefix: "0o17" and "755" pass,
/// "8" and "0x17" fail. class-validator `@IsOctal()`.
pub const octal: Rule = core.predicateRuleFits(.octal, "must be an octal number", isOctal, formatFits);

/// A port number from 0 to 65535 as text, without a sign or leading zeros:
/// "0" and "8080" pass, "080", "+80" and "65536" fail. For a number, use a
/// `u16` field. class-validator `@IsPort()`.
pub const port: Rule = core.predicateRuleFits(.port, "must be a port number from 0 to 65535", isPort, formatFits);

/// A "latitude,longitude" pair, optionally in parentheses, with at most one
/// space after the comma: "40.7128,-74.0060" and "(40.7128, -74.0060)" pass.
/// class-validator `@IsLatLong()`.
pub const latLong: Rule = core.predicateRuleFits(.lat_long, "must be a latitude,longitude pair", isLatLong, formatFits);

fn isStringOrFloat(comptime T: type) bool {
    return core.isString(T) or core.isFloat(T);
}

/// The declaration error of `latitude` or `longitude` on the unwrapped field
/// type `T`, or null: the field is a string or a float.
fn coordinateProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    if (isStringOrFloat(T)) return null;
    return core.typeErrorText(rule, T, where, "a string or a float", isStringOrFloat, typeHint(rule.kind, T));
}

/// `latitude` or `longitude`: on a string the grammar of `predicate`; on a
/// float the finite precondition, then `-limit <= value <= limit` in the
/// field type.
fn coordinateRule(comptime kind: core.Kind, comptime message: []const u8, comptime limit: comptime_int, comptime predicate: fn ([]const u8) bool) Rule {
    return core.define(kind, .{
        .message = message,
        .precondition = core.preconditions.finite,
        .fits = struct {
            fn fits(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
                if (coordinateProblem(rule, T, where)) |text| @compileError(text);
            }
        }.fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                if (comptime core.isFloat(@TypeOf(value.*))) {
                    if (!std.math.isFinite(value.*)) return .precondition;
                    return core.passIf(value.* >= -limit and value.* <= limit);
                }
                return core.passIf(predicate(value.*));
            }
        }.eval,
    });
}

/// A latitude from -90 to 90. On a string field, decimal degrees as
/// `isLatitude` reads them: "-33.8688" passes, "05", "90.5" and "1,5" fail.
/// On a float field, NaN and infinities fail with the precondition
/// `validation.finite`, and the value must be within -90 to 90 (-0.0 and
/// 1e-7 pass). An integer field is a compile error: integer coordinates are
/// usually scaled, so use `v.range` in their unit. class-validator
/// `@IsLatitude()`.
pub const latitude: Rule = coordinateRule(.latitude, "must be a latitude from -90 to 90", 90, isLatitude);

/// A longitude from -180 to 180, as `latitude`: on a string field decimal
/// degrees as `isLongitude` reads them ("05" passes, "099" fails), on a float
/// field the finite precondition and the range. class-validator
/// `@IsLongitude()`.
pub const longitude: Rule = coordinateRule(.longitude, "must be a longitude from -180 to 180", 180, isLongitude);

/// An IPv4 or an IPv6 address, as `isIpv4` and `isIpv6` read them, without
/// a zone id, brackets, prefix length or port. class-validator `@IsIP()`.
pub const ip: Rule = core.predicateRuleFits(.ip, "must be a valid IP address", isIp, formatFits);

/// An IPv4 address in strict dotted decimal: "192.0.2.1" passes, "127.1",
/// "01.2.3.4" and "1.2.3.4:80" fail. class-validator `@IsIP(4)`.
pub const ipv4: Rule = core.predicateRuleFits(.ipv4, "must be a valid IPv4 address", isIpv4, formatFits);

/// An IPv6 address in any RFC 4291 text form, an embedded IPv4 address
/// included: "2001:db8::1" and "::ffff:192.0.2.1" pass, "fe80::1%eth0" and
/// "1::2::3" fail. class-validator `@IsIP(6)`.
pub const ipv6: Rule = core.predicateRuleFits(.ipv6, "must be a valid IPv6 address", isIpv6, formatFits);

/// A MAC address in the sizes and the format of the options, as
/// `isMacAddress` reads it. `v.macAddress(.{})` takes EUI-48 and EUI-64 with
/// separators; the default message names the size and the format the
/// options allow. class-validator `@IsMACAddress()`.
pub fn macAddress(comptime options: MacAddressOptions) Rule {
    @setEvalBranchQuota(core.eval_quota);
    return core.define(.mac_address, .{
        .message = macAddressMessage(options),
        .args = options_args,
        .params = &.{ core.dataParam("eui", options.eui), core.dataParam("format", options.format) },
        .fits = formatFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isMacAddress(value.*, options));
            }
        }.eval,
    });
}

/// The default message of `macAddress(options)`: one of 6 texts.
fn macAddressMessage(comptime options: MacAddressOptions) []const u8 {
    return switch (options.format) {
        .separated => switch (options.eui) {
            .any => "must be a valid MAC address",
            .eui48 => "must be a valid 48-bit MAC address",
            .eui64 => "must be a valid 64-bit MAC address",
        },
        .bare => switch (options.eui) {
            .any => "must be a MAC address of 12 or 16 hex digits without separators",
            .eui48 => "must be a MAC address of 12 hex digits without separators",
            .eui64 => "must be a MAC address of 16 hex digits without separators",
        },
    };
}

/// An email address as `isEmail` reads it: "user@example.com" passes;
/// "user@localhost", "user@example.c" and `"a b"@example.com` fail. It
/// checks the syntax only, not that mail can be delivered. class-validator
/// `@IsEmail()`.
pub const email: Rule = core.predicateRuleFits(.email, "must be a valid email address", isEmail, formatFits);

/// An http or https URL as `isHttpUrl` reads it: "https://example.com/a?b#c"
/// and "http://localhost:8080" pass; "example.com", "ftp://example.com" and
/// "https://user@example.com" fail. Not a guard against server-side request
/// forgery: loopback and private addresses pass. Its length is not limited:
/// add a length rule. class-validator `@IsUrl()`.
pub const httpUrl: Rule = core.predicateRuleFits(.http_url, "must be a valid HTTP or HTTPS URL", isHttpUrl, formatFits);

/// A domain name as `isFqdn` reads it with these options: `v.fqdn(.{})`
/// takes "example.com" and rejects "localhost", which
/// `v.fqdn(.{ .require_tld = false })` takes. class-validator `@IsFQDN()`.
pub fn fqdn(comptime options: FqdnOptions) Rule {
    @setEvalBranchQuota(core.eval_quota);
    return core.define(.fqdn, .{
        .message = "must be a valid domain name",
        .args = options_args,
        .params = &.{
            core.dataParam("require_tld", options.require_tld),
            core.dataParam("allow_underscores", options.allow_underscores),
            core.dataParam("allow_trailing_dot", options.allow_trailing_dot),
            core.dataParam("allow_wildcard", options.allow_wildcard),
        },
        .fits = formatFits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isFqdn(value.*, options));
            }
        }.eval,
    });
}

// ------------------------------------------------------------------ schema

/// A latitude as `isLatitude` reads it, without anchors.
const latitude_pattern = "[+-]?(?:(?:[0-9]|[1-8][0-9])(?:\\.[0-9]+)?|90(?:\\.0+)?)";

/// A longitude as `isLongitude` reads it, without anchors.
const longitude_pattern = "[+-]?(?:(?:[0-9]{1,2}|1[0-7][0-9])(?:\\.[0-9]+)?|180(?:\\.0+)?)";

/// A number of `isIpv4`, 0 to 255 without a leading zero.
const octet_pattern = "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";

const ipv4_pattern = "^(?:" ++ octet_pattern ++ "\\.){3}" ++ octet_pattern ++ "$";

/// The characters and the length of the text forms of `isIpv6`: a pattern
/// for the approximate rules, which `format` completes.
const ipv6_shape_pattern = "^[0-9A-Fa-f:.]{2,45}$";

/// A top-level domain, as `isTld` takes it.
const tld_pattern = "(?:[A-Za-z]{2,63}|[Xx][Nn][0-9A-Za-z-]{1,60}[0-9A-Za-z])";

/// An address of `isEmail` but for the 64 bytes of its local part: the
/// atext of `isAtext` around single dots, `@` and a name of `isFqdn(.{})`,
/// whose 253 bytes the 254 of the address bound.
const email_pattern = "^[0-9A-Za-z!#$%&'*+/=?^_`{|}~-]+(?:\\.[0-9A-Za-z!#$%&'*+/=?^_`{|}~-]+)*@(?:" ++ labelPattern(false) ++ "\\.)+" ++ tld_pattern ++ "$";

/// A label of `isLabel`: 1-63 letters, digits and hyphens (and `_` when
/// `underscores`), without a hyphen at either end.
fn labelPattern(comptime underscores: bool) []const u8 {
    const edge = if (underscores) "[0-9A-Za-z_]" else "[0-9A-Za-z]";
    const inside = if (underscores) "[0-9A-Za-z_-]" else "[0-9A-Za-z-]";
    return edge ++ "(?:" ++ inside ++ "{0,61}" ++ edge ++ ")?";
}

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. The grammars are ASCII and regular, so most
/// rules are exact patterns; `email`, `httpUrl`, `ip` and `ipv6` would need
/// long ones and get `format` with a short pattern instead.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    return switch (rule.kind) {
        .number_string => schema.exact(&.{schema.pattern("^[+-]?(?:[0-9]+|[0-9]*\\.[0-9]+)$")}),
        .decimal => decimalSchema(rule),
        .boolean_string => schema.exact(&.{schema.keyword("enum", schema.array(&.{ schema.string("true"), schema.string("false"), schema.string("1"), schema.string("0") }))}),
        .hexadecimal => schema.exact(&.{schema.pattern("^(?:0[xXhH])?[0-9A-Fa-f]+$")}),
        .octal => schema.exact(&.{schema.pattern("^(?:0[oO])?[0-7]+$")}),
        .port => schema.exact(&.{schema.pattern("^(?:0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$")}),
        .latitude => coordinateSchema(T, latitude_pattern, 90),
        .longitude => coordinateSchema(T, longitude_pattern, 180),
        .lat_long => schema.exact(&.{schema.pattern("^(?:" ++ latitude_pattern ++ ", ?" ++ longitude_pattern ++
            "|\\(" ++ latitude_pattern ++ ", ?" ++ longitude_pattern ++ "\\))$")}),
        .email => schema.approximate(&.{ schema.format("email"), schema.count("maxLength", 254), schema.pattern(email_pattern) }, "a valid email address"),
        .http_url => schema.approximate(&.{ schema.format("uri"), schema.pattern("^[Hh][Tt][Tt][Pp][Ss]?://") }, "a valid HTTP or HTTPS URL"),
        .fqdn => fqdnSchema(.{
            .require_tld = rule.params[0].value.bool,
            .allow_underscores = rule.params[1].value.bool,
            .allow_trailing_dot = rule.params[2].value.bool,
            .allow_wildcard = rule.params[3].value.bool,
        }),
        .ip => schema.approximate(&.{schema.keyword("anyOf", schema.array(&.{
            schema.object(&.{ schema.format("ipv4"), schema.pattern(ipv4_pattern) }),
            schema.object(&.{ schema.format("ipv6"), schema.pattern(ipv6_shape_pattern) }),
        }))}, "a valid IPv4 or IPv6 address"),
        .ipv4 => schema.exact(&.{ schema.format("ipv4"), schema.pattern(ipv4_pattern) }),
        .ipv6 => schema.approximate(&.{ schema.format("ipv6"), schema.pattern(ipv6_shape_pattern) }, "a valid IPv6 address"),
        .mac_address => schema.exact(&.{schema.pattern(macAddressPattern(.{
            .eui = @field(MacAddressOptions.Eui, rule.params[0].value.tag),
            .format = @field(MacAddressOptions.Format, rule.params[1].value.tag),
        }))}),
        else => unreachable,
    };
}

/// `latitude` or `longitude`: the bounds on a float field, the pattern of
/// its string form otherwise.
fn coordinateSchema(comptime T: type, comptime pattern: []const u8, comptime limit: comptime_int) schema.RuleSchema {
    if (core.isFloat(T)) return schema.exact(&.{ schema.count("minimum", -limit), schema.count("maximum", limit) });
    return schema.exact(&.{schema.pattern("^" ++ pattern ++ "$")});
}

/// `decimal(options)`: a sign, digits, and a point with the digits the
/// options allow. A count above `schema.max_repeat` loosens the pattern to
/// one that RE2 reads, and the schema is approximate.
fn decimalSchema(comptime rule: Rule) schema.RuleSchema {
    const force = rule.params[0].value.bool;
    const fewest = rule.params[1].value.int;
    const most: ?comptime_int = if (rule.params.len > 2) rule.params[2].value.int else null;
    const capped = fewest > schema.max_repeat or (most != null and most.? > schema.max_repeat);
    const digits = if (capped) schema.repetition(@min(fewest, schema.max_repeat), null) else schema.repetition(fewest, most);
    const fraction = "[0-9]*\\.[0-9]" ++ digits;
    const regex = if (force) "^[+-]?" ++ fraction ++ "$" else "^[+-]?(?:[0-9]+|" ++ fraction ++ ")$";
    if (capped) return schema.approximate(&.{schema.pattern(regex)}, "the number of digits after the point");
    return schema.exact(&.{schema.pattern(regex)});
}

/// `fqdn(options)`: `hostname` for the names it covers (no `_`, no
/// wildcard), the length of `isFqdn`, the labels, and with `require_tld`
/// off a `not` for a last label of digits only.
fn fqdnSchema(comptime options: FqdnOptions) schema.RuleSchema {
    var keywords: []const schema.RuleSchema.Keyword = &.{};
    if (!options.allow_underscores and !options.allow_wildcard) keywords = keywords ++ &[_]schema.RuleSchema.Keyword{schema.format("hostname")};
    const label = labelPattern(options.allow_underscores);
    const name = if (options.require_tld) "(?:" ++ label ++ "\\.)+" ++ tld_pattern else "(?:" ++ label ++ "\\.)*" ++ label;
    const regex = "^" ++ (if (options.allow_wildcard) "(?:\\*\\.)?" else "") ++ name ++ (if (options.allow_trailing_dot) "\\.?" else "") ++ "$";
    keywords = keywords ++ &[_]schema.RuleSchema.Keyword{
        if (options.allow_trailing_dot)
            // The trailing dot does not count toward the 253 bytes.
            schema.keyword("anyOf", schema.array(&.{
                schema.object(&.{schema.count("maxLength", max_domain_bytes)}),
                schema.object(&.{ schema.count("maxLength", max_domain_bytes + 1), schema.pattern("\\.$") }),
            }))
        else
            schema.count("maxLength", max_domain_bytes),
        schema.pattern(regex),
    };
    if (!options.require_tld) keywords = keywords ++ &[_]schema.RuleSchema.Keyword{schema.keyword("not", schema.stringPattern("(?:^|\\.)[0-9]+\\.?$"))};
    return schema.exact(keywords);
}

/// `macAddress(options)`: each size and form that `isMacAddress` takes, as
/// alternatives; one separator throughout.
fn macAddressPattern(comptime options: MacAddressOptions) []const u8 {
    const pair = "[0-9A-Fa-f]{2}";
    const quad = "[0-9A-Fa-f]{4}";
    const sizes: []const comptime_int = switch (options.eui) {
        .any => &.{ 6, 8 },
        .eui48 => &.{6},
        .eui64 => &.{8},
    };
    var forms: []const []const u8 = &.{};
    for (sizes) |octets| {
        switch (options.format) {
            .bare => forms = forms ++ &[_][]const u8{"[0-9A-Fa-f]" ++ schema.repetition(2 * octets, 2 * octets)},
            .separated => {
                for ([_][]const u8{ ":", "-", " " }) |separator|
                    forms = forms ++ &[_][]const u8{pair ++ "(?:" ++ separator ++ pair ++ ")" ++ schema.repetition(octets - 1, octets - 1)};
                forms = forms ++ &[_][]const u8{quad ++ "(?:\\." ++ quad ++ ")" ++ schema.repetition(octets / 2 - 1, octets / 2 - 1)};
            },
        }
    }
    var out: []const u8 = "^(?:";
    for (forms, 0..) |form, i| out = out ++ (if (i == 0) "" else "|") ++ form;
    return out ++ ")$";
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `decimal must be called, e.g. v.decimal(.{})`.
pub const call_examples = .{ .decimal = ".{}", .fqdn = ".{}", .macAddress = ".{}" };

const expectOutcome = core.expectOutcome;
const test_where = "Dto.field_rules.x";

fn expectAll(predicate: fn ([]const u8) bool, expected: bool, inputs: []const []const u8) !void {
    for (inputs) |s| {
        std.testing.expectEqual(expected, predicate(s)) catch |err| {
            std.debug.print("input \"{f}\"\n", .{std.zig.fmtString(s)});
            return err;
        };
    }
}

fn decimalDefault(s: []const u8) bool {
    return isDecimal(s, .{});
}

test "numberString: an optional sign, digits, and an optional point with digits after it" {
    try expectAll(isNumberString, true, &.{ "0", "7", "+0", "-0", "007", ".5", "-.5", "+.5", "12.5", "-12.5", "1234567890123456789012345678901234567890" });
    try expectAll(isNumberString, false, &.{ "", "+", "-", ".", "+.", "5.", "-5.", "1e5", "1E5", "1,000", "1_000", "0x1F", " 1", "1 ", "--1", "+-1", "1.2.3", "..5", "1.5\x00", "\xd9\xa1", "\xff", "\xef\xbc\x91" });
}

test "decimal with the default options accepts what numberString accepts" {
    try expectAll(decimalDefault, true, &.{ "0", "+0", "007", ".5", "-.5", "12.5", "-12.5" });
    try expectAll(decimalDefault, false, &.{ "", "+", "-", ".", "1.", "1e5", "1,5", " 1", "1.2.3" });
}

test "decimal counts the digits after the point, and force_decimal requires them" {
    const t = std.testing;
    try t.expect(isDecimal("1.25", .{ .max_decimal_digits = 2 }));
    try t.expect(!isDecimal("1.255", .{ .max_decimal_digits = 2 }));
    try t.expect(isDecimal("12", .{ .max_decimal_digits = 2 }));
    try t.expect(!isDecimal("1.5", .{ .min_decimal_digits = 2 }));
    try t.expect(isDecimal("15", .{ .min_decimal_digits = 2 }));
    try t.expect(isDecimal("1.50", .{ .min_decimal_digits = 2, .max_decimal_digits = 2 }));
    try t.expect(!isDecimal("12", .{ .force_decimal = true }));
    try t.expect(isDecimal("-.75", .{ .force_decimal = true, .max_decimal_digits = 2 }));
    try t.expect(!isDecimal(".", .{ .force_decimal = true }));
    try t.expect(!isDecimal("1.2a", .{}));
    try t.expect(!isDecimal("a1.2", .{}));
    // The predicate applies its options as given, even those the rule refuses.
    try t.expect(isDecimal("1.", .{ .min_decimal_digits = 0 }));
    try t.expect(isDecimal(".", .{ .min_decimal_digits = 0 }));
    try t.expect(!isDecimal("1.25", .{ .min_decimal_digits = 3, .max_decimal_digits = 2 }));
    try t.expect(isDecimal("12", .{ .min_decimal_digits = 3, .max_decimal_digits = 2 }));
}

test "booleanString: exactly true, false, 1 or 0" {
    try expectAll(isBooleanString, true, &.{ "true", "false", "1", "0" });
    try expectAll(isBooleanString, false, &.{ "", "TRUE", "True", "FALSE", "yes", "no", "on", " true", "true ", "01", "00", "2", "tru", "truee" });
}

test "hexadecimal: an optional 0x or 0h prefix in any case, then hex digits" {
    // "0b1" is three hex digits, not a binary prefix.
    try expectAll(isHexadecimal, true, &.{ "0", "00", "f", "ff", "0x0", "0X1f", "0h1F", "0Hff", "deadBEEF", "0xDEADbeef", "123", "0b1" });
    try expectAll(isHexadecimal, false, &.{ "", "0x", "0X", "0h", "0H", "x1", "h1", "#ff", "-1", "+1", "0xg", "1h", "0x0x1", "ff ", "\xff" });
}

test "octal: an optional 0o prefix in any case, then digits 0-7" {
    try expectAll(isOctal, true, &.{ "0", "7", "017", "755", "0o17", "0O17", "0o0" });
    try expectAll(isOctal, false, &.{ "", "0o", "0O", "8", "19", "0x17", "0b1", "-7", "+7", "0o8", "1_0", "o17", "0o 1" });
}

test "port: 0 to 65535 without a sign or leading zeros" {
    try expectAll(isPort, true, &.{ "0", "1", "80", "443", "8080", "65535" });
    try expectAll(isPort, false, &.{ "", "65536", "99999", "123456", "080", "00", "0080", "+80", "-0", "-1", "1.0", " 80", "80 ", "8_0", "0x50", "1e3" });
}

test "latitude strings: 1 or 2 digits of degrees up to 90, and only zeros after 90" {
    try expectAll(isLatitude, true, &.{ "0", "-0", "+0", "5", "45.5", "0.5", "89.999999", "90", "-90", "+90", "90.0", "90.000", "-90.000", "9.99" });
    try expectAll(isLatitude, false, &.{ "", "+", "-", "05", "-05", "00", "90.1", "90.0001", "91", "-91", "100", "1,5", " 45", "45 ", "4e1", "45.", ".5", "45\xc2\xb0", "45N", "NaN", "Infinity", "--45", "(45" });
}

test "longitude strings: 1 to 3 digits of degrees up to 180, 3 digits start with 1, and only zeros after 180" {
    try expectAll(isLongitude, true, &.{ "0", "05", "00", "99", "100", "180", "-180", "+180", "180.0", "179.9999", "+45.5" });
    try expectAll(isLongitude, false, &.{ "", "099", "000", "181", "180.1", "200", "1000", " 45", "-180.5", "45.", "1,2", "45)", "1e2" });
}

test "latLong: latitude, a comma, at most one space and longitude, optionally in parentheses" {
    try expectAll(isLatLong, true, &.{ "40.7128,-74.0060", "40.7128, -74.0060", "(40.7128,-74.0060)", "(40.7128, -74.0060)", "90,180", "-90,-180", "0,0", "-74.0060,40.7128" });
    try expectAll(isLatLong, false, &.{
        "",                  "40.7128",         "40.7128,-74.0060)", "(40.7128,-74.0060", "40.7128,\t-74.0060", "40.7128,  -74.0060",
        "40.7128 ,-74.0060", "1,2,garbage",     "()",                "(,)",               ",",                  "(",
        ")",                 "-122.4194,37.77", "91,0",              "0,181",             "(0,0) ",             " (0,0)",
    });
}

test "the number and coordinate rules have their codes and default messages, and only latitude and longitude a precondition" {
    const t = std.testing;
    const rules = .{
        .{ numberString, core.Kind.number_string, "validation.number_string", "must be a number" },
        .{ booleanString, core.Kind.boolean_string, "validation.boolean_string", "must be true, false, 1 or 0" },
        .{ hexadecimal, core.Kind.hexadecimal, "validation.hexadecimal", "must be a hexadecimal number" },
        .{ octal, core.Kind.octal, "validation.octal", "must be an octal number" },
        .{ port, core.Kind.port, "validation.port", "must be a port number from 0 to 65535" },
        .{ latitude, core.Kind.latitude, "validation.latitude", "must be a latitude from -90 to 90" },
        .{ longitude, core.Kind.longitude, "validation.longitude", "must be a longitude from -180 to 180" },
        .{ latLong, core.Kind.lat_long, "validation.lat_long", "must be a latitude,longitude pair" },
    };
    inline for (rules) |row| {
        try t.expectEqual(row[1], row[0].kind);
        try t.expectEqualStrings(row[2], row[0].code);
        try t.expectEqualStrings(row[3], row[0].message);
        try t.expectEqual(null, row[0].args);
        try t.expectEqual(0, row[0].params.len);
        const coordinate = comptime (row[1] == .latitude or row[1] == .longitude);
        if (coordinate) {
            try t.expectEqualStrings("validation.finite", row[0].precondition.?.code);
            try t.expectEqualStrings("must be a finite number", row[0].precondition.?.message);
        } else {
            try t.expectEqual(null, row[0].precondition);
        }
    }
}

test "decimal shows its options as .{...} and keeps them as parameters: two placeholders at most" {
    const t = std.testing;
    const rule = decimal(.{ .force_decimal = true, .max_decimal_digits = 3 });
    try t.expectEqual(core.Kind.decimal, rule.kind);
    try t.expectEqualStrings("validation.decimal", rule.code);
    try t.expectEqualStrings(".{...}", rule.args.?);
    try t.expectEqualStrings("decimal(.{...})", comptime rule.call());
    try t.expectEqualStrings("decimal(.{...})", comptime rule.label());
    try t.expectEqual(null, rule.precondition);
    try t.expectEqual(3, rule.params.len);
    try t.expectEqualStrings("force_decimal", rule.params[0].name);
    try t.expect(!rule.params[0].placeholder);
    try t.expect(comptime rule.params[0].value.bool);
    try t.expectEqualStrings("min_decimal_digits", rule.params[1].name);
    try t.expectEqualStrings("1", rule.params[1].text);
    try t.expectEqualStrings("max_decimal_digits", rule.params[2].name);
    try t.expectEqualStrings("3", rule.params[2].text);
    try t.expectEqualStrings("{min_decimal_digits}, {max_decimal_digits}", comptime core.placeholderList(rule));
    // Without a maximum, {max_decimal_digits} is no placeholder.
    try t.expectEqualStrings("{min_decimal_digits}", comptime core.placeholderList(decimal(.{})));
    try t.expectEqual(2, decimal(.{}).params.len);
}

test "decimal picks one of 8 default messages from its options, a count of 1 in the singular" {
    const expect = std.testing.expectEqualStrings;
    try expect("must be a decimal number", decimal(.{}).message);
    try expect("must be a whole number or have at least 2 decimal places", decimal(.{ .min_decimal_digits = 2 }).message);
    try expect("must be a decimal number with at most 1 decimal place", decimal(.{ .max_decimal_digits = 1 }).message);
    try expect("must be a decimal number with at most 2 decimal places", decimal(.{ .max_decimal_digits = 2 }).message);
    try expect("must be a whole number or have exactly 2 decimal places", decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 2 }).message);
    try expect("must be a whole number or have 2 to 4 decimal places", decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 4 }).message);
    try expect("must be a decimal number with at least 1 decimal place", decimal(.{ .force_decimal = true }).message);
    try expect("must be a decimal number with at least 3 decimal places", decimal(.{ .force_decimal = true, .min_decimal_digits = 3 }).message);
    try expect("must be a decimal number with exactly 1 decimal place", decimal(.{ .force_decimal = true, .max_decimal_digits = 1 }).message);
    try expect("must be a decimal number with exactly 2 decimal places", decimal(.{ .force_decimal = true, .min_decimal_digits = 2, .max_decimal_digits = 2 }).message);
    try expect("must be a decimal number with 1 to 3 decimal places", decimal(.{ .force_decimal = true, .max_decimal_digits = 3 }).message);
    // The placeholders give the same texts.
    try expect("2..4 places", decimal(.{ .min_decimal_digits = 2, .max_decimal_digits = 4 }).withMessage("{min_decimal_digits}..{max_decimal_digits} places").message);
}

test "decimal takes at least 1 digit after the point and a maximum not below the minimum" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: decimal(.{...}): min_decimal_digits must be at least 1 (0 would accept \"1.\" and \".\")", comptime decimalCallProblem(.{ .min_decimal_digits = 0 }).?);
    try expect("validator: decimal(.{...}): min_decimal_digits must be at least 1 (0 would accept \"1.\" and \".\")", comptime decimalCallProblem(.{ .force_decimal = true, .min_decimal_digits = 0, .max_decimal_digits = 2 }).?);
    try expect("validator: decimal(.{...}): max_decimal_digits (2) is less than min_decimal_digits (3)", comptime decimalCallProblem(.{ .min_decimal_digits = 3, .max_decimal_digits = 2 }).?);
    try expect("validator: decimal(.{...}): max_decimal_digits (0) is less than min_decimal_digits (1)", comptime decimalCallProblem(.{ .max_decimal_digits = 0 }).?);
    try std.testing.expectEqual(null, comptime decimalCallProblem(.{}));
    try std.testing.expectEqual(null, comptime decimalCallProblem(.{ .min_decimal_digits = 2, .max_decimal_digits = 2 }));
    try std.testing.expectEqual(null, comptime decimalCallProblem(.{ .max_decimal_digits = std.math.maxInt(usize) }));
}

test "decimal's placeholder {max_decimal_digits} exists only when the maximum is set" {
    try std.testing.expectEqualStrings(
        "validator: decimal(.{...}).withMessage(\"at most {max_decimal_digits} places\"): unknown placeholder {max_decimal_digits}; available: {min_decimal_digits}",
        comptime switch (core.renderTemplate(decimal(.{}), "at most {max_decimal_digits} places")) {
            .message, .problem => |text| text,
        },
    );
}

/// The declaration error of the string rule `rule` on a field of type `T`.
fn stringText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return formatProblem(&rule, T, test_where);
}

fn coordinateText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return coordinateProblem(&rule, T, test_where);
}

test "the string rules take strings only, and a number field gets the rule's own hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const number = "; the field is already a number: use v.min, v.max or v.range";
    try expect(head ++ "number_string expects a string, field is u32" ++ number, comptime stringText(numberString, u32).?);
    try expect(head ++ "number_string expects a string, field is f64" ++ number, comptime stringText(numberString, f64).?);
    try expect(head ++ "decimal expects a string, field is f64" ++ number, comptime stringText(decimal(.{ .max_decimal_digits = 2 }), f64).?);
    try expect(head ++ "hexadecimal expects a string, field is u32" ++ number, comptime stringText(hexadecimal, u32).?);
    try expect(head ++ "octal expects a string, field is u16" ++ number, comptime stringText(octal, u16).?);
    try expect(head ++ "boolean_string expects a string, field is bool; a bool field is already a boolean and needs no rule", comptime stringText(booleanString, bool).?);
    try expect(head ++ "boolean_string expects a string, field is u8; use a bool field", comptime stringText(booleanString, u8).?);
    try expect(head ++ "boolean_string expects a string, field is f64; use a bool field", comptime stringText(booleanString, f64).?);
    try expect(
        head ++ "port expects a string, field is u16; a u16 field already holds 0-65535: add v.min(1) to exclude 0, or use v.range(0, 65535) on a wider type",
        comptime stringText(port, u16).?,
    );
    try expect(
        head ++ "port expects a string, field is f32; a u16 field already holds 0-65535: add v.min(1) to exclude 0, or use v.range(0, 65535) on a wider type",
        comptime stringText(port, f32).?,
    );
    try expect(head ++ "lat_long expects a string, field is f64; use two float fields with v.latitude and v.longitude", comptime stringText(latLong, f64).?);
    try expect(head ++ "lat_long expects a string, field is i32; use two float fields with v.latitude and v.longitude", comptime stringText(latLong, i32).?);
}

test "the string rules on [N]u8, on lists of strings and on other types" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const u8_array = "; [N]u8 is an array of numbers, not a string: use []const u8";
    try expect(head ++ "number_string expects a string, field is [8]u8" ++ u8_array, comptime stringText(numberString, [8]u8).?);
    try expect(head ++ "boolean_string expects a string, field is [4:0]u8" ++ u8_array, comptime stringText(booleanString, [4:0]u8).?);
    try expect(head ++ "number_string expects a string, field is []const []const u8; use v.each(v.numberString)", comptime stringText(numberString, []const []const u8).?);
    try expect(head ++ "decimal expects a string, field is []const []const u8; use v.each(v.decimal(.{...}))", comptime stringText(decimal(.{ .max_decimal_digits = 2 }), []const []const u8).?);
    try expect(head ++ "port expects a string, field is [2]?[]const u8; use v.each(v.port)", comptime stringText(port, [2]?[]const u8).?);
    // A list of items the rule rejects gets no hint, even a list of numbers.
    try expect(head ++ "number_string expects a string, field is []const u32", comptime stringText(numberString, []const u32).?);
    try expect(head ++ "boolean_string expects a string, field is []const bool", comptime stringText(booleanString, []const bool).?);
    try expect(head ++ "hexadecimal expects a string, field is core.Kind", comptime stringText(hexadecimal, core.Kind).?);
    try expect(head ++ "lat_long expects a string, field is bool", comptime stringText(latLong, bool).?);
    try expect(
        head ++ "octal expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime stringText(octal, []volatile u8).?,
    );
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expectEqual(null, comptime stringText(numberString, T));
        try std.testing.expectEqual(null, comptime stringText(decimal(.{}), T));
        try std.testing.expectEqual(null, comptime stringText(latLong, T));
    }
}

test "latitude and longitude take strings and floats; an integer field gets the scaled-coordinates hint" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(
        head ++ "latitude expects a string or a float, field is i32; integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-90_000_000, 90_000_000) for E6",
        comptime coordinateText(latitude, i32).?,
    );
    // The hint is the same on an unsigned field, where that range would not compile.
    try expect(
        head ++ "latitude expects a string or a float, field is u8; integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-90_000_000, 90_000_000) for E6",
        comptime coordinateText(latitude, u8).?,
    );
    try expect(
        head ++ "longitude expects a string or a float, field is i64; integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-180_000_000, 180_000_000) for E6",
        comptime coordinateText(longitude, i64).?,
    );
    try expect(head ++ "latitude expects a string or a float, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime coordinateText(latitude, [8]u8).?);
    try expect(head ++ "latitude expects a string or a float, field is []const f64; use v.each(v.latitude)", comptime coordinateText(latitude, []const f64).?);
    try expect(head ++ "longitude expects a string or a float, field is []const []const u8; use v.each(v.longitude)", comptime coordinateText(longitude, []const []const u8).?);
    try expect(head ++ "latitude expects a string or a float, field is bool", comptime coordinateText(latitude, bool).?);
    try expect(head ++ "longitude expects a string or a float, field is []const i32", comptime coordinateText(longitude, []const i32).?);
    inline for (.{ []const u8, [:0]u8, f16, f32, f64, f80, f128, c_longdouble }) |T| {
        try std.testing.expectEqual(null, comptime coordinateText(latitude, T));
        try std.testing.expectEqual(null, comptime coordinateText(longitude, T));
    }
}

test "an uncalled decimal gets an example call, and inside each the head is each(...)" {
    const expect = std.testing.expectEqualStrings;
    try expect("decimal must be called, e.g. v.decimal(.{})", comptime core.hints.mustBeCalled("decimal", @TypeOf(decimal)));
    try expect("expected a rule, got the predicate isDecimal; use the rule v.decimal(.{})", comptime core.hints.predicateAsRule("isDecimal", "decimal", @TypeOf(decimal)));
    try expect("expected a rule, got the predicate isPort; use the rule v.port", comptime core.hints.predicateAsRule("isPort", "port", Rule));
}

test "latitude and longitude on floats: the finite precondition, then the range in the field type" {
    // Twelve unrolled bodies of float arithmetic at compile time: more
    // branches than a test allows by default on some targets (x86).
    @setEvalBranchQuota(10_000);
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        inline for (.{ .{ latitude, 90 }, .{ longitude, 180 } }) |row| {
            const rule = row[0];
            const limit: F = row[1];
            try expectOutcome(.pass, rule, limit);
            try expectOutcome(.pass, rule, -limit);
            try expectOutcome(.pass, rule, @as(F, -0.0));
            try expectOutcome(.pass, rule, std.math.floatTrueMin(F));
            try expectOutcome(.pass, rule, @as(F, 1e-7));
            try expectOutcome(.fail, rule, std.math.nextAfter(F, limit, std.math.inf(F)));
            try expectOutcome(.fail, rule, std.math.nextAfter(F, -limit, -std.math.inf(F)));
            try expectOutcome(.fail, rule, std.math.floatMax(F));
            try expectOutcome(.precondition, rule, std.math.nan(F));
            try expectOutcome(.precondition, rule, std.math.inf(F));
            try expectOutcome(.precondition, rule, -std.math.inf(F));
        }
    }
    // On a string, "NaN" is just not a coordinate.
    try expectOutcome(.fail, latitude, @as([]const u8, "NaN"));
    try expectOutcome(.pass, longitude, @as([]const u8, "-180"));
}

test "ipv4: four numbers from 0 to 255 joined by dots, without leading zeros" {
    try expectAll(isIpv4, true, &.{ "0.0.0.0", "255.255.255.255", "192.0.2.1", "127.0.0.1", "1.2.3.4", "10.0.0.255", "100.64.0.0" });
    try expectAll(isIpv4, false, &.{
        "",           "256.0.0.1",  "999.1.1.1",  "1.2.3",      "1.2.3.4.5",  "01.2.3.4",         "1.2.3.04",    "00.1.2.3",
        "127.1",      "2130706433", "0x7f.0.0.1", "1.2.3.4/24", "1.2.3.4:80", " 1.2.3.4",         "1.2.3.4 ",    "1..2.3",
        ".1.2.3",     "1.2.3.",     "1.2.3.4.",   "+1.2.3.4",   "-1.2.3.4",   "::ffff:192.0.2.1", "1.2.3.4\x00", "1.2.3.\xd9\xa1",
        "1.2.3.1000", "1.2.3.a",
    });
}

test "ipv6: 8 groups, or fewer around one ::, with an optional IPv4 tail; no zone id" {
    try expectAll(isIpv6, true, &.{
        "::",                                            "::1",                 "1::",                "2001:db8::1",                             "2001:DB8:0:0:0:0:0:0001",
        "fe80::",                                        "::ffff:192.0.2.1",    "64:ff9b::192.0.2.1", "1:2:3:4:5:6:7:8",                         "1:2:3:4:5:6:7::",
        "::2:3:4:5:6:7:8",                               "1:2:3:4:5:6:1.2.3.4", "::1.2.3.4",          "ABCD:ef01:2345:6789:abcd:EF01:2345:6789", "2001:db8:85a3:0000:0000:8a2e:0370:7334",
        "0000:0000:0000:0000:0000:ffff:255.255.255.255",
    });
    try expectAll(isIpv6, false, &.{
        "",                  ":",             ":::",                   "1::2::3",     "::1:2:3:4:5:6:7:8",
        "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "12345::",               "g::",         "fe80::1%eth0",
        "[::1]",             "::1/128",       "1:2:3:4:5:6:7:1.2.3.4", "1.2.3.4::",   "::1.2.3",
        "1:2:3:4:5:1.2.3.4", " ::1",          "::1 ",                  ":1::",        "1::2:",
        "1:::2",             "1.2.3.4",       "::256.0.0.1",           "::1.2.3.4:5", "0000:0000:0000:0000:0000:ffff:255.255.255.2550",
    });
}

test "ip: an IPv4 or an IPv6 address" {
    try expectAll(isIp, true, &.{ "192.0.2.1", "::1", "::ffff:192.0.2.1" });
    try expectAll(isIp, false, &.{ "", "fe80::1%eth0", "1.2.3", "localhost", "[::1]", "1.2.3.4:80" });
}

fn macDefault(s: []const u8) bool {
    return isMacAddress(s, .{});
}

test "macAddress with the default options: EUI-48 or EUI-64, one separator throughout or dotted groups of four" {
    try expectAll(macDefault, true, &.{
        "00:1A:2B:3C:4D:5E", "00-1a-2b-3c-4d-5e", "00 1a 2b 3c 4d 5e", "001a.2b3c.4d5e", "00:1a:2b:3c:4d:5e:6f:70", "0000.5eef.1000.0001",
        "00-00-5E-00-53-01",
    });
    try expectAll(macDefault, false, &.{
        "",                     "00:1a-2b:3c:4d:5e",                                    "0:1a:2b:3c:4d:5e", "001A2B3C4D5E",   "00\t00\t5e\t00\t53\t01", "00:1a:2b:3c:4d",
        "00:1a:2b:3c:4d:5e:6f", "00:1a:2b:3c:4d:5g",                                    "001a.2b3c.4d5e.",  "001a:2b3c:4d5e", "00.1a.2b.3c.4d.5e",      "00_1a_2b_3c_4d_5e",
        "00:1a:2b:3c:4d:5e ",   "00\xc2\xa01a\xc2\xa02b\xc2\xa03c\xc2\xa04d\xc2\xa05e",
    });
}

test "macAddress options pick the sizes and the format" {
    const t = std.testing;
    const eui48 = "00:00:5e:00:53:01";
    const eui64 = "00:00:5e:ef:10:00:00:01";
    try t.expect(isMacAddress(eui48, .{ .eui = .eui48 }));
    try t.expect(!isMacAddress(eui64, .{ .eui = .eui48 }));
    try t.expect(isMacAddress(eui64, .{ .eui = .eui64 }));
    try t.expect(!isMacAddress(eui48, .{ .eui = .eui64 }));
    try t.expect(isMacAddress("0000.5eef.1000.0001", .{ .eui = .eui64 }));
    try t.expect(isMacAddress("00005E005301", .{ .format = .bare }));
    try t.expect(isMacAddress("00005eef10000001", .{ .format = .bare }));
    try t.expect(!isMacAddress(eui48, .{ .format = .bare }));
    try t.expect(isMacAddress("00005e005301", .{ .eui = .eui48, .format = .bare }));
    try t.expect(!isMacAddress("00005eef10000001", .{ .eui = .eui48, .format = .bare }));
    try t.expect(isMacAddress("00005eef10000001", .{ .eui = .eui64, .format = .bare }));
    try t.expect(!isMacAddress("00005e005301", .{ .eui = .eui64, .format = .bare }));
    try t.expect(!isMacAddress("00005e00530g", .{ .format = .bare }));
}

test "ip, ipv4 and ipv6 have their codes and default messages and no precondition" {
    const t = std.testing;
    const rules = .{
        .{ ip, core.Kind.ip, "validation.ip", "must be a valid IP address" },
        .{ ipv4, core.Kind.ipv4, "validation.ipv4", "must be a valid IPv4 address" },
        .{ ipv6, core.Kind.ipv6, "validation.ipv6", "must be a valid IPv6 address" },
    };
    inline for (rules) |row| {
        try t.expectEqual(row[1], row[0].kind);
        try t.expectEqualStrings(row[2], row[0].code);
        try t.expectEqualStrings(row[3], row[0].message);
        try t.expectEqual(null, row[0].args);
        try t.expectEqual(0, row[0].params.len);
        try t.expectEqual(null, row[0].precondition);
    }
}

test "macAddress picks one of 6 default messages and keeps its options as data, no placeholders" {
    const t = std.testing;
    const expect = t.expectEqualStrings;
    try expect("must be a valid MAC address", macAddress(.{}).message);
    try expect("must be a valid 48-bit MAC address", macAddress(.{ .eui = .eui48 }).message);
    try expect("must be a valid 64-bit MAC address", macAddress(.{ .eui = .eui64 }).message);
    try expect("must be a MAC address of 12 or 16 hex digits without separators", macAddress(.{ .format = .bare }).message);
    try expect("must be a MAC address of 12 hex digits without separators", macAddress(.{ .eui = .eui48, .format = .bare }).message);
    try expect("must be a MAC address of 16 hex digits without separators", macAddress(.{ .eui = .eui64, .format = .bare }).message);
    const rule = macAddress(.{ .eui = .eui64, .format = .bare });
    try t.expectEqual(core.Kind.mac_address, rule.kind);
    try expect("validation.mac_address", rule.code);
    try expect("macAddress(.{...})", comptime rule.call());
    try expect("mac_address(.{...})", comptime rule.label());
    try t.expectEqual(null, rule.precondition);
    try t.expectEqual(2, rule.params.len);
    try expect("eui", rule.params[0].name);
    try expect("eui64", rule.params[0].text);
    try expect("format", rule.params[1].name);
    try expect("bare", rule.params[1].text);
    try expect("", comptime core.placeholderList(rule));
}

test "the address rules take strings only, with the [N]u8 and each hints" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "ip expects a string, field is u32", comptime stringText(ip, u32).?);
    try expect(head ++ "ipv4 expects a string, field is u32", comptime stringText(ipv4, u32).?);
    try expect(head ++ "ipv6 expects a string, field is u128", comptime stringText(ipv6, u128).?);
    try expect(head ++ "mac_address expects a string, field is u64", comptime stringText(macAddress(.{}), u64).?);
    try expect(head ++ "ip expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime stringText(ip, [8]u8).?);
    try expect(head ++ "mac_address expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime stringText(macAddress(.{}), [8]u8).?);
    try expect(head ++ "ipv4 expects a string, field is []const []const u8; use v.each(v.ipv4)", comptime stringText(ipv4, []const []const u8).?);
    try expect(head ++ "mac_address expects a string, field is []const []const u8; use v.each(v.macAddress(.{...}))", comptime stringText(macAddress(.{ .eui = .eui48 }), []const []const u8).?);
    try expect("macAddress must be called, e.g. v.macAddress(.{})", comptime core.hints.mustBeCalled("macAddress", @TypeOf(macAddress)));
    try expect("expected a rule, got the predicate isMacAddress; use the rule v.macAddress(.{})", comptime core.hints.predicateAsRule("isMacAddress", "macAddress", @TypeOf(macAddress)));
}

fn fqdnDefault(s: []const u8) bool {
    return isFqdn(s, .{});
}

/// A label of 63 bytes, and a domain name of exactly 253 bytes.
const label63: [63]u8 = @splat('a');
const name253 = label63 ++ "." ++ label63 ++ "." ++ label63 ++ "." ++ @as([57]u8, @splat('b')) ++ ".com";

test "fqdn with the default options: LDH labels, at least two, and a top-level domain" {
    try std.testing.expectEqual(253, name253.len);
    try expectAll(fqdnDefault, true, &.{
        "example.com", "a.b.co",       "sub.example.co.uk",  "a-b.com",     "1example.com", "example.XN--P1AI", "example.Xn--p1ai", "example.xN--P1AI",
        "example.xn",  "example.xn1a", "xn--80ak6aa92e.com", "EXAMPLE.COM", name253,        label63 ++ ".com",
    });
    try expectAll(fqdnDefault, false, &.{
        "",                  "localhost",       "example",      "example.c",    "example.com1", "example.c-m",  "example.0x1f",     "example.xn1",
        "example.123",       "-example.com",    "example-.com", "exa_mple.com", "example..com", ".example.com", "example.com.",     "*.example.com",
        "m\xc3\xbcnchen.de", "ex\xffample.com", "example.com ", " example.com", "example .com", "a" ++ name253, label63 ++ "a.com", "1.2.3.4",
        "example.x-",        "example.xn-",     "example.c_m",
    });
}

test "fqdn options: one label, underscores, a trailing dot and a wildcard, each on its own and together" {
    const t = std.testing;
    try t.expect(isFqdn("localhost", .{ .require_tld = false }));
    try t.expect(isFqdn("a.b", .{ .require_tld = false }));
    try t.expect(isFqdn("a.c1", .{ .require_tld = false }));
    try t.expect(!isFqdn("a.123", .{ .require_tld = false }));
    try t.expect(!isFqdn("123", .{ .require_tld = false }));
    try t.expect(isFqdn("_dmarc.example.com", .{ .allow_underscores = true }));
    try t.expect(isFqdn("a_b.example.com", .{ .allow_underscores = true }));
    try t.expect(!isFqdn("_dmarc.example.com", .{}));
    try t.expect(isFqdn("example.com.", .{ .allow_trailing_dot = true }));
    try t.expect(!isFqdn("example.com..", .{ .allow_trailing_dot = true }));
    try t.expect(!isFqdn(".", .{ .allow_trailing_dot = true }));
    try t.expect(isFqdn("*.example.com", .{ .allow_wildcard = true }));
    try t.expect(!isFqdn("*.com", .{ .allow_wildcard = true }));
    try t.expect(!isFqdn("*.*.example.com", .{ .allow_wildcard = true }));
    try t.expect(!isFqdn("*example.com", .{ .allow_wildcard = true }));
    try t.expect(!isFqdn("*.", .{ .allow_wildcard = true }));
    try t.expect(isFqdn("*._svc.", .{ .require_tld = false, .allow_underscores = true, .allow_trailing_dot = true, .allow_wildcard = true }));
    // 253 bytes pass, 254 fail; an allowed trailing dot is the 254th byte.
    try t.expect(isFqdn(name253 ++ ".", .{ .allow_trailing_dot = true }));
    try t.expect(!isFqdn("a" ++ name253 ++ ".", .{ .allow_trailing_dot = true }));
    try t.expect(!isFqdn(name253 ++ ".", .{}));
}

test "email: a local part of atext and dots, then a domain that fqdn accepts" {
    const local64: [64]u8 = @splat('l');
    // 4 + 250 = 254 bytes in all.
    const domain250 = label63 ++ "." ++ label63 ++ "." ++ label63 ++ "." ++ @as([54]u8, @splat('d')) ++ ".com";
    try std.testing.expectEqual(250, domain250.len);
    try expectAll(isEmail, true, &.{
        "user@example.com",      "first.last@example.co.uk", "x+tag@example.com",     "!#$%&'*+-/=?^_`{|}~@example.com", "user@example.XN--P1AI",
        "user@example.xn--p1ai", "user@example.Xn--p1ai",    "user@example.xN--P1AI", "user@example.xn",                 "user@example.xn12",
        "a@b.co",                local64 ++ "@example.com",  "abc@" ++ domain250,     "USER@EXAMPLE.COM",                "1@2.co",
    });
    try expectAll(isEmail, false, &.{
        "",                                 "user",                 "@example.com",          "user@",                     "user@example.c",         "user@example.com1",
        "user@example.c-m",                 "user@example.0x1f",    "user@example.xn1",      "user@localhost",            "user@example.com.",      "a@b@example.com",
        ".user@example.com",                "user.@example.com",    "us..er@example.com",    "\"a b\"@example.com",       "\"quoted\"@example.com", "j\xc3\xb6s\xc3\xa9@example.com",
        "user@\xe4\xbe\x8b\xe3\x81\x88.jp", "user@ex\xffample.com", "user name@example.com", "user@[192.0.2.1]",          "user@192.0.2.1",         local64 ++ "l@example.com",
        "abcd@" ++ domain250,               "user@-example.com",    "user@example..com",     "user(comment)@example.com", "user@example.com ",      " user@example.com",
    });
}

test "httpUrl: the scheme, a host or [IPv6] with an optional port, and a tail of printable ASCII" {
    const host253 = name253;
    try expectAll(isHttpUrl, true, &.{
        "http://example.com",                                       "https://example.com/",                                          "HTTP://EXAMPLE.COM:080/a{b}^c`d",
        "https://fonts.googleapis.com/css?family=Roboto|Open+Sans", "https://api.example.com/articles?page[number]=2&page[size]=10", "https://example.com/search?ids[]=1&ids[]=2",
        "http://example.com/a|b",                                   "http://example.com/[x]",                                        "http://localhost",
        "http://api:8080",                                          "https://googlecom",                                             "https://example.com./",
        "http://[::1]",                                             "http://[::1]:65535/",                                           "http://[2001:db8::1]:8443/",
        "http://[::ffff:1.2.3.4]/",                                 "http://192.0.2.1/%00",                                          "http://127.0.0.1/",
        "http://169.254.169.254/latest/meta-data/",                 "http://example.com:080/",                                       "https://example.com/%00",
        "http://example.com#frag?with/slash",                       "https://example.com?q=1",                                       "http://xn--80ak6aa92e.com/",
        "http://example.com/a%2Fb",                                 "http://1.2.3.4:80/",                                            "http://" ++ host253 ++ "/",
        "http://" ++ host253 ++ "./",                               "https://example.com:65535",
    });
    try expectAll(isHttpUrl, false, &.{
        "",                                 "http://",                    "https://",                        "http:///path",                "example.com",
        "ftp://example.com/",               "http:example.com",           "http:/example.com",               "http://example.com/a\"b",     "http://example.com/a\\b",
        "http://example.com/a<b>",          "http://example.com/a b",     "http://example.com/a\x7fb",       "http://example.com/a\x01b",   "http://example.com/%zz",
        "http://example.com/%2",            "http://example.com/%",       "http://example.com/#a#b",         "http://example.com:0/",       "http://example.com:65536/",
        "http://example.com:/",             "http://example.com:000080/", "http://example.com:00000/",       "http://user@example.com/",    "https://example.com@evil.example",
        "http://1.2.3/",                    "http://0x7f.1/",             "http://[fe80::1%25eth0]/",        "http://exa_mple.com/",        "http://-example.com/",
        "http://example-.com/",             "https://m\xc3\xbcnchen.de/", "https://example.com/\xc3\xbcber", "http://[::1",                 "http://[::1]x/",
        "http://[1.2.3.4]/",                "http://1.2.3.4./",           "http://256.1.1.1/",               "http://example.com:8080:90/", "http://exa mple.com/",
        "http://example..com/",             "http://.example.com/",       "http://example.com../",           "http://a.b.c.0x/",            "http://example.123/",
        "http://" ++ "a" ++ host253 ++ "/", "http://[::1]:/",             "http://[]/",                      "http://:80/",                 " http://example.com",
    });
}

test "email, httpUrl and fqdn have their codes and default messages and no precondition; fqdn keeps its options as data" {
    const t = std.testing;
    try t.expectEqual(core.Kind.email, email.kind);
    try t.expectEqualStrings("validation.email", email.code);
    try t.expectEqualStrings("must be a valid email address", email.message);
    try t.expectEqual(null, email.args);
    try t.expectEqual(null, email.precondition);
    try t.expectEqual(core.Kind.http_url, httpUrl.kind);
    try t.expectEqualStrings("validation.http_url", httpUrl.code);
    try t.expectEqualStrings("must be a valid HTTP or HTTPS URL", httpUrl.message);
    try t.expectEqual(null, httpUrl.args);
    try t.expectEqual(null, httpUrl.precondition);
    const rule = fqdn(.{ .allow_wildcard = true });
    try t.expectEqual(core.Kind.fqdn, rule.kind);
    try t.expectEqualStrings("validation.fqdn", rule.code);
    try t.expectEqualStrings("must be a valid domain name", rule.message);
    try t.expectEqualStrings("fqdn(.{...})", comptime rule.call());
    try t.expectEqual(null, rule.precondition);
    try t.expectEqual(4, rule.params.len);
    try t.expectEqualStrings("require_tld", rule.params[0].name);
    try t.expectEqualStrings("true", rule.params[0].text);
    try t.expectEqualStrings("allow_wildcard", rule.params[3].name);
    try t.expectEqualStrings("true", rule.params[3].text);
    try t.expectEqualStrings("", comptime core.placeholderList(rule));
}

test "email, httpUrl and fqdn take strings only, with the [N]u8 and each hints" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "email expects a string, field is u64", comptime stringText(email, u64).?);
    try expect(head ++ "http_url expects a string, field is bool", comptime stringText(httpUrl, bool).?);
    try expect(head ++ "fqdn expects a string, field is bool", comptime stringText(fqdn(.{}), bool).?);
    try expect(head ++ "email expects a string, field is [8]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime stringText(email, [8]u8).?);
    try expect(head ++ "http_url expects a string, field is []const []const u8; use v.each(v.httpUrl)", comptime stringText(httpUrl, []const []const u8).?);
    try expect(head ++ "fqdn expects a string, field is []const []const u8; use v.each(v.fqdn(.{...}))", comptime stringText(fqdn(.{}), []const []const u8).?);
    try expect(head ++ "fqdn expects a string, field is [8:0]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime stringText(fqdn(.{}), [8:0]u8).?);
    try expect("fqdn must be called, e.g. v.fqdn(.{})", comptime core.hints.mustBeCalled("fqdn", @TypeOf(fqdn)));
    try expect("expected a rule, got the predicate isEmail; use the rule v.email", comptime core.hints.predicateAsRule("isEmail", "email", Rule));
    try expect("expected a rule, got the predicate isFqdn; use the rule v.fqdn(.{})", comptime core.hints.predicateAsRule("isFqdn", "fqdn", @TypeOf(fqdn)));
}
