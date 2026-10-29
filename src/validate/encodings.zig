// Copied from vkiryakov/zefir src/validator/encodings.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Encoding and other format rules for string fields, each with its
//! predicate: `v.base64` and `v.isBase64(s)`. Every rule here is a value
//! without parameters, placeholders or precondition, and passes exactly when
//! its predicate returns true. Nothing is trimmed and nothing is decoded into
//! memory. A byte of 0x80 or above fails under the rule's own code, except
//! inside a JSON string, where `v.json` takes valid UTF-8; so invalid UTF-8
//! needs no rule of its own. The predicates take any bytes, never allocate,
//! never backtrack and run in time linear in the input.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;

// ------------------------------------------------------------------ json, jwt

/// RFC 8259 JSON text whose top-level value is an object or an array (as
/// validator.js has it by default: `1`, `"text"`, `true` and `null` fail),
/// nested at most `v.max_json_depth` (64) levels of `[` and `{`, the top
/// level included: `[]` is 1 level. `std.json.Scanner` decides the grammar:
/// strings are valid UTF-8 with escaped control characters and paired
/// `\u` surrogates; whitespace is space, tab, LF and CR only; no BOM; only
/// whitespace after the value. Numbers are checked by their syntax alone
/// (`1e400` passes) and duplicate keys pass. Invalid UTF-8 inside a string
/// fails as `validation.json` too: this is the one rule here that takes
/// bytes above 0x7f, inside strings only. The nesting stack lives in a
/// buffer on the stack: no heap, and a document of any depth is rejected at
/// level 65 without recursion.
pub const json: Rule = core.predicateRule(.json, "must be a valid JSON object or array", isJson);

/// Bytes of the scanner's nesting stack: what `std.json.Scanner` asks its
/// allocator for when it reserves `max_json_depth + 1` levels (one bit per
/// level, rounded up to bytes and grown as std grows every list): 141 on
/// x86_64 and aarch64.
const json_stack_bytes = std.array_list.Aligned(u8, null).growCapacity((core.max_json_depth + 1 + 7) / 8);

/// Whether `v.json` passes `s`.
pub fn isJson(s: []const u8) bool {
    var buf: [json_stack_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), s);
    // The scanner's only allocation, which fits in `buf`; if a release
    // of std grew differently, every input would fail (the json tests below).
    scanner.ensureTotalStackCapacity(core.max_json_depth + 1) catch return false;
    var first = true;
    while (true) {
        const token = scanner.next() catch return false;
        switch (token) {
            // The scanner pushes a level before it returns its token, so
            // level 65 is seen here and rejected: the stack never grows.
            .object_begin, .array_begin => if (scanner.stackHeight() > core.max_json_depth) return false,
            .end_of_document => return true,
            // A top-level number, string, true, false or null.
            else => if (first) return false,
        }
        first = false;
    }
}

/// The shape of a JWT in JWS Compact Serialization (RFC 7515 §7.1, RFC
/// 7519): exactly three segments separated by `.`, each canonical base64url
/// without padding (`v.isBase64Url`), the header and the payload not empty.
/// An empty signature passes: an Unsecured JWT (RFC 7519 §6). Only the shape
/// is checked; nothing is decoded, and the claims and the signature are the
/// application's to verify. `Bearer <token>` and a JWE (5 segments) fail.
pub const jwt: Rule = core.predicateRule(.jwt, "must be a valid JWT", isJwt);

/// Whether `v.jwt` passes `s`.
pub fn isJwt(s: []const u8) bool {
    var segments = std.mem.splitScalar(u8, s, '.');
    const header = segments.first();
    const payload = segments.next() orelse return false;
    const signature = segments.next() orelse return false;
    if (segments.next() != null) return false;
    return header.len > 0 and payload.len > 0 and isBase64Url(header) and isBase64Url(payload) and isBase64Url(signature);
}

// ------------------------------------------------------------------ base64, base64Url

/// RFC 4648 §4 base64 with padding, in its canonical form: the length is a
/// multiple of 4, the data is `A-Z a-z 0-9 + /`, one or two `=` may end it,
/// and the bits the padding leaves unused are zero (RFC 4648 §3.5), so `Zg==`
/// passes and `Zh==` fails. It accepts exactly what
/// `std.base64.standard.Decoder` decodes: no line breaks, no whitespace, no
/// URL-safe alphabet, no missing padding. `""` passes (it encodes no bytes):
/// pair it with `v.notEmpty` to require content.
pub const base64: Rule = core.predicateRule(.base64, "must be valid base64", isBase64);

/// Whether `v.base64` passes `s`.
pub fn isBase64(s: []const u8) bool {
    if (s.len % 4 != 0) return false;
    var pad: usize = 0;
    if (s.len > 0 and s[s.len - 1] == '=') {
        pad = 1;
        // s.len is at least 4 here.
        if (s[s.len - 2] == '=') pad = 2;
    }
    var last: u6 = 0;
    for (s[0 .. s.len - pad]) |c| last = standardDigit(c) orelse return false;
    return switch (pad) {
        0 => true,
        // 3 symbols carry 18 bits for 16 data bits; 2 symbols 12 bits for 8.
        1 => last & 0b11 == 0,
        else => last & 0b1111 == 0,
    };
}

/// RFC 4648 §5 base64url without padding, as JWT segments use it (RFC 7515
/// §2), in its canonical form: the data is `A-Z a-z 0-9 - _`, `=` never
/// appears, the length is not 1 more than a multiple of 4, and the unused
/// bits of the last symbol are zero. It accepts exactly what
/// `std.base64.url_safe_no_pad.Decoder` decodes. `""` passes.
pub const base64Url: Rule = core.predicateRule(.base64_url, "must be valid base64url", isBase64Url);

/// Whether `v.base64Url` passes `s`.
pub fn isBase64Url(s: []const u8) bool {
    var last: u6 = 0;
    for (s) |c| last = urlSafeDigit(c) orelse return false;
    return switch (s.len % 4) {
        0 => true,
        // One symbol holds 6 bits: no whole byte.
        1 => false,
        2 => last & 0b1111 == 0,
        else => last & 0b11 == 0,
    };
}

/// The value of a symbol of the standard alphabet (RFC 4648 table 1).
fn standardDigit(c: u8) ?u6 {
    return switch (c) {
        '+' => 62,
        '/' => 63,
        else => alphanumericDigit(c),
    };
}

/// The value of a symbol of the URL and filename safe alphabet (RFC 4648
/// table 2).
fn urlSafeDigit(c: u8) ?u6 {
    return switch (c) {
        '-' => 62,
        '_' => 63,
        else => alphanumericDigit(c),
    };
}

/// The value of a letter or digit, shared by both base64 alphabets.
fn alphanumericDigit(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        else => null,
    };
}

// ------------------------------------------------------------------ base32, base58

/// RFC 4648 §6 base32 with padding, in its canonical form: the length is a
/// multiple of 8, the data is uppercase `A-Z 2-7`, it ends with 0, 1, 3, 4 or
/// 6 `=` (the only counts an encoder writes), and the bits the padding
/// leaves unused are zero (RFC 4648 §3.5). Not Crockford's base32 and not
/// the unpadded variant. `""` passes.
pub const base32: Rule = core.predicateRule(.base32, "must be valid base32", isBase32);

/// Whether `v.base32` passes `s`.
pub fn isBase32(s: []const u8) bool {
    if (s.len % 8 != 0) return false;
    var pad: usize = 0;
    while (pad < s.len and s[s.len - 1 - pad] == '=') pad += 1;
    // The unused low bits of the last data symbol: 7 symbols carry 35 bits
    // for 32 data bits, 5 symbols 25 for 24, 4 symbols 20 for 16, 2 symbols
    // 10 for 8.
    const unused: u3 = switch (pad) {
        0 => 0,
        1 => 3,
        3 => 1,
        4 => 4,
        6 => 2,
        else => return false,
    };
    var last: u5 = 0;
    for (s[0 .. s.len - pad]) |c| {
        last = switch (c) {
            'A'...'Z' => @intCast(c - 'A'),
            '2'...'7' => @intCast(c - '2' + 26),
            else => return false,
        };
    }
    const mask: u5 = @intCast((@as(u8, 1) << unused) - 1);
    return last & mask == 0;
}

/// Bitcoin's base58 alphabet (draft-msporny-base58-03): `1-9 A-H J-N P-Z
/// a-k m-z`, without `0`, `O`, `I` and `l`. Every string over the alphabet
/// is the canonical encoding of some bytes (a leading `1` is a zero byte), so
/// only the alphabet is checked: no Base58Check checksum, no length (use
/// `v.btcAddress` for Bitcoin addresses). `""` passes.
pub const base58: Rule = core.predicateRule(.base58, "must be valid base58", isBase58);

/// Whether `v.base58` passes `s`.
pub fn isBase58(s: []const u8) bool {
    for (s) |c| switch (c) {
        '1'...'9', 'A'...'H', 'J'...'N', 'P'...'Z', 'a'...'k', 'm'...'z' => {},
        else => return false,
    };
    return true;
}

// ------------------------------------------------------------------ dataUri, magnetUri

/// An RFC 2397 data URL: `data:[<type>/<subtype>][;<attribute>=<value>]*[;base64],<data>`.
/// The scheme is lowercase `data:`; the media type, when present, passes the
/// type check of `v.mimeType` without `#` and `^`; an attribute and its value
/// are not empty and use `A-Z a-z 0-9 - . _ ~ ! $ & ' * +` or `%HH`;
/// `;base64` (in any case) comes last, and then the data must pass
/// `v.isBase64` (`data:;base64,` passes); otherwise the data is RFC 2396 URI
/// characters or `%HH`. No whitespace, no trimming; nothing is decoded.
pub const dataUri: Rule = core.predicateRule(.data_uri, "must be a valid data URI", isDataUri);

/// Whether `v.dataUri` passes `s`.
pub fn isDataUri(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "data:")) return false;
    const comma = std.mem.findScalar(u8, s, ',') orelse return false;
    var parts = std.mem.splitScalar(u8, s["data:".len..comma], ';');
    const media_type = parts.first();
    if (media_type.len != 0) {
        if (!isMediaTypeEssence(media_type)) return false;
        // Media type names may hold them, URIs may not.
        if (std.mem.findAny(u8, media_type, "#^") != null) return false;
    }
    var base64_data = false;
    while (parts.next()) |part| {
        // `;base64` must be the last part.
        if (base64_data) return false;
        if (std.ascii.eqlIgnoreCase(part, "base64")) {
            base64_data = true;
            continue;
        }
        const eq = std.mem.findScalar(u8, part, '=') orelse return false;
        const attribute = part[0..eq];
        const value = part[eq + 1 ..];
        if (attribute.len == 0 or value.len == 0) return false;
        if (!isEscaped(attribute, isDataParamChar) or !isEscaped(value, isDataParamChar)) return false;
    }
    const data = s[comma + 1 ..];
    return if (base64_data) isBase64(data) else isEscaped(data, isUric);
}

/// The URI characters of RFC 2396 (`uric`, what RFC 2397 allows in the data)
/// but `%`, which `isEscaped` checks.
fn isUric(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

/// The characters of a data URL attribute or value: RFC 2045 token
/// characters that are URI characters too, but `%`.
fn isDataParamChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', '!', '$', '&', '\'', '*', '+' => true,
        else => false,
    };
}

/// Every byte of `s` is `allowed` or starts a `%HH` escape.
fn isEscaped(s: []const u8, comptime allowed: fn (u8) bool) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            if (s.len - i < 3 or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        } else if (!allowed(s[i])) return false;
    }
    return true;
}

/// A magnet URI that names its content: lowercase `magnet:?`, then a query
/// of RFC 3986 query characters and valid `%HH` escapes (no spaces, no `#`,
/// ASCII only), split on `&`, with an `xt` or `xt.1` parameter (in any case)
/// whose raw value is an exact topic in one of the forms validator.js knows,
/// in any case: `urn:` and one of `aich`, `bitprint`, `btih`, `ed2k`,
/// `ed2khash`, `kzhash`, `md5`, `sha1`, `tree:tiger`, then `:` and 32 or 40
/// letters and digits, or `urn:btmh:1220` and 64 letters and digits. Empty
/// parameters and parameters without `=` are skipped; `xt.2` and later do
/// not count.
pub const magnetUri: Rule = core.predicateRule(.magnet_uri, "must be a valid magnet URI", isMagnetUri);

/// Whether `v.magnetUri` passes `s`.
pub fn isMagnetUri(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "magnet:?")) return false;
    const query = s["magnet:?".len..];
    if (!isEscaped(query, isQueryChar)) return false;
    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        if ((std.ascii.eqlIgnoreCase(key, "xt") or std.ascii.eqlIgnoreCase(key, "xt.1")) and isExactTopic(param[eq + 1 ..])) return true;
    }
    return false;
}

/// The query characters of RFC 3986 (`pchar`, `/` and `?`) but `%`.
fn isQueryChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?' => true,
        else => false,
    };
}

/// An exact topic value of a magnet URI in validator.js's forms, any case.
fn isExactTopic(value: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(value, "urn:")) return false;
    const rest = value["urn:".len..];
    if (std.ascii.startsWithIgnoreCase(rest, "btmh:1220")) {
        const digest = rest["btmh:1220".len..];
        return digest.len == 64 and allAlphanumeric(digest);
    }
    inline for (.{ "aich", "bitprint", "btih", "ed2k", "ed2khash", "kzhash", "md5", "sha1", "tree:tiger" }) |topic| {
        if (rest.len > topic.len and std.ascii.startsWithIgnoreCase(rest, topic) and rest[topic.len] == ':') {
            const digest = rest[topic.len + 1 ..];
            if ((digest.len == 32 or digest.len == 40) and allAlphanumeric(digest)) return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------ mimeType

/// A media type as `Content-Type` carries it: `<type>/<subtype>`, then
/// parameters. The type is one of the 11 top-level types of the IANA registry
/// (`application`, `audio`, `example`, `font`, `haptics`, `image`,
/// `message`, `model`, `multipart`, `text`, `video`) in any case; the subtype
/// is an RFC 6838 name of 1-127 bytes that starts with a letter or a digit
/// and uses `A-Z a-z 0-9 ! # $ & - ^ _ . +`. Each parameter (RFC 9110 §5.6.6)
/// is optional spaces or tabs, `;`, optional spaces or tabs, then
/// `name=value`: the name a token, the value a token or a quoted string
/// without obs-text (`charset=""` passes). A `;` needs a parameter after
/// it; there are no spaces around `=` or at the end. ASCII only, so CR and
/// LF never pass. Subtypes are not looked up in the registry.
pub const mimeType: Rule = core.predicateRule(.mime_type, "must be a valid MIME type", isMimeType);

/// Whether `v.mimeType` passes `s`.
pub fn isMimeType(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and s[i] != ';' and s[i] != ' ' and s[i] != '\t') i += 1;
    if (!isMediaTypeEssence(s[0..i])) return false;
    while (i < s.len) {
        i = skipOptionalSpace(s, i);
        if (i >= s.len or s[i] != ';') return false;
        i = skipOptionalSpace(s, i + 1);
        const name_start = i;
        while (i < s.len and isTokenChar(s[i])) i += 1;
        if (i == name_start or i >= s.len or s[i] != '=') return false;
        i += 1;
        if (i < s.len and s[i] == '"') {
            i = quotedStringEnd(s, i + 1) orelse return false;
        } else {
            const value_start = i;
            while (i < s.len and isTokenChar(s[i])) i += 1;
            if (i == value_start) return false;
        }
    }
    return true;
}

/// The index after the closing quote of the RFC 9110 quoted-string whose
/// content starts at `s[start]`, or null: `\` escapes a tab or a visible
/// ASCII character, and obs-text (bytes above 0x7e) is not allowed.
fn quotedStringEnd(s: []const u8, start: usize) ?usize {
    var i = start;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') return i + 1;
        if (c == '\\') {
            if (i + 1 >= s.len) return null;
            const escaped = s[i + 1];
            if (escaped != '\t' and (escaped < 0x20 or escaped > 0x7e)) return null;
            i += 2;
        } else if (c == '\t' or c == ' ' or c == 0x21 or (c >= 0x23 and c <= 0x5b) or (c >= 0x5d and c <= 0x7e)) {
            i += 1;
        } else return null;
    }
    return null;
}

/// The top-level media types of the IANA registry (updated 2025-03-18).
const top_level_types = [_][]const u8{ "application", "audio", "example", "font", "haptics", "image", "message", "model", "multipart", "text", "video" };

/// `<type>/<subtype>`: a top-level type of the registry and an RFC 6838
/// subtype name, the check `v.mimeType` and `v.dataUri` share.
fn isMediaTypeEssence(s: []const u8) bool {
    const slash = std.mem.findScalar(u8, s, '/') orelse return false;
    const type_name = s[0..slash];
    const subtype = s[slash + 1 ..];
    const known = for (top_level_types) |name| {
        if (std.ascii.eqlIgnoreCase(type_name, name)) break true;
    } else false;
    if (!known) return false;
    if (subtype.len == 0 or subtype.len > 127 or !std.ascii.isAlphanumeric(subtype[0])) return false;
    for (subtype) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "!#$&-^_.+", c) == null) return false;
    }
    return true;
}

/// An RFC 9110 `tchar`.
fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

/// The index of the first byte at or after `i` that is not a space or a tab.
fn skipOptionalSpace(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    return j;
}

// ------------------------------------------------------------------ locale

/// A well-formed BCP 47 language tag (RFC 5646 §2.2.9), checked by syntax in
/// any ASCII case: one of the 17 irregular grandfathered tags (`i-klingon`,
/// `en-GB-oed`, ...); a private-use tag (`x-` and subtags of 1-8 letters and
/// digits); or a language of 2-3 or 5-8 letters (4 letters fail, as in
/// validator.js), up to 3 extlangs of 3 letters after a 2-3 letter language,
/// an optional script of 4 letters, an optional region of 2 letters or 3
/// digits, variants (5-8 letters and digits, or 4 starting with a digit),
/// extensions (a singleton other than `x` and subtags of 2-8), and an
/// optional private-use part. Subtags are separated by `-` only (`en_US`
/// fails). Nothing is looked up in the registry, so `english` passes.
pub const locale: Rule = core.predicateRule(.locale, "must be a valid locale", isLocale);

/// Whether `v.locale` passes `s`.
pub fn isLocale(s: []const u8) bool {
    for (irregular_tags) |tag| {
        if (std.ascii.eqlIgnoreCase(s, tag)) return true;
    }
    var subtags = std.mem.splitScalar(u8, s, '-');
    const language = subtags.first();
    if (!isSubtag(language)) return false;
    if (std.ascii.eqlIgnoreCase(language, "x")) return isPrivateUseRest(&subtags);
    if (!allAlpha(language) or language.len < 2 or language.len == 4) return false;
    // What may come next, in the order of the grammar.
    const Stage = enum(u8) { extlang, script, region, variant };
    var stage: Stage = if (language.len <= 3) .extlang else .script;
    var extlangs: usize = 0;
    var in_extension = false;
    var extension_has_subtag = false;
    while (subtags.next()) |subtag| {
        if (!isSubtag(subtag)) return false;
        if (subtag.len == 1) {
            if (in_extension and !extension_has_subtag) return false;
            if (subtag[0] == 'x' or subtag[0] == 'X') return isPrivateUseRest(&subtags);
            in_extension = true;
            extension_has_subtag = false;
            continue;
        }
        if (in_extension) {
            extension_has_subtag = true;
            continue;
        }
        const at = @backingInt(stage);
        if (stage == .extlang and subtag.len == 3 and allAlpha(subtag) and extlangs < 3) {
            extlangs += 1;
        } else if (at <= @backingInt(Stage.script) and subtag.len == 4 and allAlpha(subtag)) {
            stage = .region;
        } else if (at <= @backingInt(Stage.region) and ((subtag.len == 2 and allAlpha(subtag)) or (subtag.len == 3 and core.allDigits(subtag)))) {
            stage = .variant;
        } else if (subtag.len >= 5 or (subtag.len == 4 and std.ascii.isDigit(subtag[0]))) {
            stage = .variant;
        } else return false;
    }
    return !in_extension or extension_has_subtag;
}

/// The irregular grandfathered tags of RFC 5646 §2.1, which the grammar of
/// language tags does not match.
const irregular_tags = [_][]const u8{
    "en-GB-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak",     "i-klingon", "i-lux",     "i-mingo",
    "i-navajo",  "i-pwn", "i-tao", "i-tay",     "i-tsu",      "sgn-BE-FR", "sgn-BE-NL", "sgn-CH-DE",
};

/// 1-8 letters and digits.
fn isSubtag(s: []const u8) bool {
    return s.len >= 1 and s.len <= 8 and allAlphanumeric(s);
}

/// The subtags after a private-use `x`: at least one, each of 1-8 letters
/// and digits.
fn isPrivateUseRest(subtags: *std.mem.SplitIterator(u8, .scalar)) bool {
    var count: usize = 0;
    while (subtags.next()) |subtag| : (count += 1) {
        if (!isSubtag(subtag)) return false;
    }
    return count > 0;
}

// ------------------------------------------------------------------ semVer

/// A version by the grammar of Semantic Versioning 2.0.0: `MAJOR.MINOR.PATCH`,
/// three numbers without leading zeros; then an optional pre-release after
/// `-` and optional build metadata after `+`, each made of non-empty
/// dot-separated identifiers of `0-9 A-Z a-z -` (in a pre-release, an
/// identifier of digits only has no leading zero). Numbers have no size
/// limit. No `v` prefix, no whitespace.
pub const semVer: Rule = core.predicateRule(.sem_ver, "must be a valid semantic version", isSemVer);

/// Whether `v.semVer` passes `s`.
pub fn isSemVer(s: []const u8) bool {
    const plus = std.mem.findScalar(u8, s, '+');
    if (plus) |p| {
        var build = std.mem.splitScalar(u8, s[p + 1 ..], '.');
        while (build.next()) |identifier| {
            if (!isIdentifier(identifier)) return false;
        }
    }
    const version = s[0 .. plus orelse s.len];
    const dash = std.mem.findScalar(u8, version, '-');
    if (dash) |d| {
        var pre_release = std.mem.splitScalar(u8, version[d + 1 ..], '.');
        while (pre_release.next()) |identifier| {
            if (!isIdentifier(identifier)) return false;
            if (core.allDigits(identifier) and !isNumber(identifier)) return false;
        }
    }
    var numbers: usize = 0;
    var core_numbers = std.mem.splitScalar(u8, version[0 .. dash orelse version.len], '.');
    while (core_numbers.next()) |number| : (numbers += 1) {
        if (numbers == 3 or !isNumber(number)) return false;
    }
    return numbers == 3;
}

/// A numeric identifier: `0`, or digits that do not start with `0`.
fn isNumber(s: []const u8) bool {
    return s.len > 0 and core.allDigits(s) and (s.len == 1 or s[0] != '0');
}

/// A non-empty identifier of `0-9 A-Z a-z -`.
fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

// ------------------------------------------------------------------ hexColor, rgbColor, hslColor

/// A CSS hex color (CSS Color 4 §5.2): `#` and 3, 4, 6 or 8 hex digits in
/// any case: `#fff`, `#ffff`, `#ff0000`, `#ff000080`. The `#` is required,
/// so words such as `cafe` are not colors.
pub const hexColor: Rule = core.predicateRule(.hex_color, "must be a valid hex color", isHexColor);

/// Whether `v.hexColor` passes `s`.
pub fn isHexColor(s: []const u8) bool {
    if (s.len == 0 or s[0] != '#') return false;
    switch (s.len - 1) {
        3, 4, 6, 8 => {},
        else => return false,
    }
    for (s[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// A CSS `rgb()` or `rgba()` color in the legacy comma syntax, with
/// validator.js's grammar of values: `rgb(R, G, B)` or `rgba(R, G, B, A)`,
/// the function name in lowercase. R, G and B are all integers 0-255 or all
/// percentages 0%-100%, without leading zeros; A is `0`, `1`, or a decimal
/// from 0 to 1 such as `0.5`, `.5` or `1.00`. CSS whitespace (space, tab,
/// LF, CR, FF) may surround each value. `rgb` takes no alpha and `rgba`
/// needs one; the space-separated syntax fails (`v.hslColor` takes it).
pub const rgbColor: Rule = core.predicateRule(.rgb_color, "must be a valid RGB color", isRgbColor);

/// Whether `v.rgbColor` passes `s`.
pub fn isRgbColor(s: []const u8) bool {
    const with_alpha = std.mem.startsWith(u8, s, "rgba(");
    if (!with_alpha and !std.mem.startsWith(u8, s, "rgb(")) return false;
    var i: usize = if (with_alpha) "rgba(".len else "rgb(".len;
    // Whether the channels are percentages: the first channel decides.
    var percent: ?bool = null;
    for (0..3) |channel| {
        i = skipCssSpace(s, i);
        const value = channelValue(s, &i) orelse return false;
        const is_percent = i < s.len and s[i] == '%';
        if (is_percent) i += 1;
        if ((percent orelse is_percent) != is_percent) return false;
        percent = is_percent;
        if (value > @as(u16, if (is_percent) 100 else 255)) return false;
        i = skipCssSpace(s, i);
        if (channel < 2 or with_alpha) {
            if (i >= s.len or s[i] != ',') return false;
            i += 1;
        }
    }
    if (with_alpha) {
        i = skipCssSpace(s, i);
        if (!legacyAlpha(s, &i)) return false;
        i = skipCssSpace(s, i);
    }
    return i + 1 == s.len and s[i] == ')';
}

/// The value of the 1-3 digits at `s[i.*]`, `0` or without a leading zero,
/// advancing `i.*` past them; null when malformed.
fn channelValue(s: []const u8, i: *usize) ?u16 {
    const start = i.*;
    var value: u16 = 0;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) {
        if (i.* - start == 3) return null;
        value = value * 10 + (s[i.*] - '0');
    }
    const len = i.* - start;
    if (len == 0 or (len > 1 and s[start] == '0')) return null;
    return value;
}

/// The alpha of the legacy syntax at `s[i.*]`: `0`, `1`, `0.` and digits,
/// `.` and digits, or `1.` and zeros; advances `i.*` past it.
fn legacyAlpha(s: []const u8, i: *usize) bool {
    var j = i.*;
    var integer: ?u8 = null;
    if (j < s.len and (s[j] == '0' or s[j] == '1')) {
        integer = s[j];
        j += 1;
    }
    if (j < s.len and s[j] == '.') {
        j += 1;
        const fraction_start = j;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {
            if (integer == '1' and s[j] != '0') return false;
        }
        if (j == fraction_start) return false;
    } else if (integer == null) return false;
    i.* = j;
    return true;
}

/// A CSS `hsl()` or `hsla()` color with validator.js's grammar, the name in
/// any case: legacy `hsl(H, S%, L%[, A])` or modern `hsl(H S% L%[ / A])`,
/// either name with or without an alpha. H is a number with an optional unit
/// `deg`, `grad`, `rad` or `turn` (any case); S and L are numbers with `%`;
/// A is a number with an optional `%`. A number is
/// `[+-](digits[.digits] | .digits)[(e | E)[+-]digits]`. Ranges are not checked:
/// CSS clamps them. CSS whitespace (space, tab, LF, CR, FF) inside the
/// parentheses only; nothing before the name or after `)`.
pub const hslColor: Rule = core.predicateRule(.hsl_color, "must be a valid HSL color", isHslColor);

/// Whether `v.hslColor` passes `s`.
pub fn isHslColor(s: []const u8) bool {
    var i: usize = if (std.ascii.startsWithIgnoreCase(s, "hsla("))
        "hsla(".len
    else if (std.ascii.startsWithIgnoreCase(s, "hsl("))
        "hsl(".len
    else
        return false;
    i = skipCssSpace(s, i);
    if (!cssNumber(s, &i)) return false;
    i += hueUnitLength(s[i..]);
    const after_hue = i;
    i = skipCssSpace(s, i);
    if (i < s.len and s[i] == ',') {
        // Legacy: H, S%, L%[, A]
        i = skipCssSpace(s, i + 1);
        if (!cssPercentage(s, &i)) return false;
        i = skipCssSpace(s, i);
        if (i >= s.len or s[i] != ',') return false;
        i = skipCssSpace(s, i + 1);
        if (!cssPercentage(s, &i)) return false;
        i = skipCssSpace(s, i);
        if (i < s.len and s[i] == ',') {
            i = skipCssSpace(s, i + 1);
            if (!cssAlpha(s, &i)) return false;
            i = skipCssSpace(s, i);
        }
    } else {
        // Modern: H S% L%[ / A], whitespace between the first three.
        if (i == after_hue) return false;
        if (!cssPercentage(s, &i)) return false;
        const after_saturation = i;
        i = skipCssSpace(s, i);
        if (i == after_saturation) return false;
        if (!cssPercentage(s, &i)) return false;
        i = skipCssSpace(s, i);
        if (i < s.len and s[i] == '/') {
            i = skipCssSpace(s, i + 1);
            if (!cssAlpha(s, &i)) return false;
            i = skipCssSpace(s, i);
        }
    }
    return i + 1 == s.len and s[i] == ')';
}

/// The index of the first byte at or after `i` that is not CSS whitespace
/// (CSS Syntax 3 §4.2: space, tab, LF, CR, FF).
fn skipCssSpace(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len) : (j += 1) {
        switch (s[j]) {
            ' ', '\t', '\n', '\r', 0x0c => {},
            else => break,
        }
    }
    return j;
}

/// A CSS number at `s[i.*]` as validator.js reads it; advances `i.*` past
/// it. An exponent without digits is left unread.
fn cssNumber(s: []const u8, i: *usize) bool {
    var j = i.*;
    if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
    const integer_start = j;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    const has_integer = j > integer_start;
    if (j + 1 < s.len and s[j] == '.' and std.ascii.isDigit(s[j + 1])) {
        j += 1;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    } else if (!has_integer) return false;
    if (j < s.len and (s[j] == 'e' or s[j] == 'E')) {
        var k = j + 1;
        if (k < s.len and (s[k] == '+' or s[k] == '-')) k += 1;
        const exponent_start = k;
        while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
        if (k > exponent_start) j = k;
    }
    i.* = j;
    return true;
}

/// The length of the angle unit that `s` starts with, in any case, or 0.
fn hueUnitLength(s: []const u8) usize {
    inline for (.{ "deg", "grad", "rad", "turn" }) |unit| {
        if (std.ascii.startsWithIgnoreCase(s, unit)) return unit.len;
    }
    return 0;
}

/// A CSS number and `%`.
fn cssPercentage(s: []const u8, i: *usize) bool {
    if (!cssNumber(s, i)) return false;
    if (i.* >= s.len or s[i.*] != '%') return false;
    i.* += 1;
    return true;
}

/// A CSS number and an optional `%`.
fn cssAlpha(s: []const u8, i: *usize) bool {
    if (!cssNumber(s, i)) return false;
    if (i.* < s.len and s[i.*] == '%') i.* += 1;
    return true;
}

// ------------------------------------------------------------------ schema

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. The base encodings, `semVer` and `hexColor`
/// are exact patterns, the canonical bits of base32 and base64 included;
/// the others would need long or unbounded ones and get `format` (when the
/// registry of OpenAPI has one) with a short pattern instead.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    _ = T;
    return switch (rule.kind) {
        .json => schema.approximate(&.{
            schema.keyword("contentMediaType", schema.string("application/json")),
            schema.pattern("^[\t\n\r ]*[\\[{]"),
        }, "a JSON object or array"),
        .jwt => schema.approximate(&.{schema.pattern("^[0-9A-Za-z_-]+\\.[0-9A-Za-z_-]+\\.[0-9A-Za-z_-]*$")}, "a JWT of three base64url segments"),
        .base32 => schema.exact(&.{schema.pattern("^(?:[A-Z2-7]{8})*(?:[A-Z2-7][AEIMQUY4]======|[A-Z2-7]{3}[AQ]====|[A-Z2-7]{4}[ACEGIKMOQSUWY246]===|[A-Z2-7]{6}[AIQY]=)?$")}),
        .base58 => schema.exact(&.{schema.pattern("^[1-9A-HJ-NP-Za-km-z]*$")}),
        .base64 => schema.exact(&.{
            schema.keyword("contentEncoding", schema.string("base64")),
            schema.pattern("^(?:[0-9A-Za-z+/]{4})*(?:[0-9A-Za-z+/][AQgw]==|[0-9A-Za-z+/]{2}[AEIMQUYcgkosw048]=)?$"),
        }),
        .base64_url => schema.exact(&.{
            schema.keyword("contentEncoding", schema.string("base64url")),
            schema.pattern("^(?:[0-9A-Za-z_-]{4})*(?:[0-9A-Za-z_-][AQgw]|[0-9A-Za-z_-]{2}[AEIMQUYcgkosw048])?$"),
        }),
        .data_uri => schema.approximate(&.{ schema.format("uri"), schema.pattern("^data:") }, "a valid data URI"),
        .magnet_uri => schema.approximate(&.{ schema.format("uri"), schema.pattern("^magnet:\\?") }, "a valid magnet URI"),
        .mime_type => schema.approximate(&.{ schema.format("media-range"), schema.pattern("^[A-Za-z]+/[0-9A-Za-z]") }, "a valid MIME type"),
        .locale => schema.approximate(&.{ schema.format("language"), schema.pattern("^[A-Za-z]{1,8}(?:-[0-9A-Za-z]{1,8})*$") }, "a well-formed BCP 47 language tag"),
        .sem_ver => schema.exact(&.{schema.pattern("^(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)" ++
            "(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?" ++
            "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$")}),
        .hex_color => schema.exact(&.{schema.pattern("^#(?:[0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")}),
        .rgb_color => schema.approximate(&.{schema.pattern("^rgba?\\([^)]*\\)$")}, "a valid CSS rgb() or rgba() color"),
        .hsl_color => schema.approximate(&.{schema.pattern("^[Hh][Ss][Ll][Aa]?\\([^)]*\\)$")}, "a valid CSS hsl() or hsla() color"),
        else => unreachable,
    };
}

// ------------------------------------------------------------------ byte classes

fn allAlpha(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphabetic(c)) return false;
    }
    return true;
}

fn allAlphanumeric(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ tests

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// Field types for the tests below.
const TestContentType = enum { json, html };
const TestVersion = struct { major: u32, minor: u32, patch: u32 };

/// The declaration error of `rule` on a field of type `T`, or null.
fn fieldText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return core.stringProblem(&rule, T, test_where, null);
}

test "the encoding rules are values with their documented codes and messages, without parameters or precondition" {
    const t = std.testing;
    const rules = .{ json, jwt, base64, base64Url, base32, base58, dataUri, magnetUri, mimeType, locale, semVer, hexColor, rgbColor, hslColor };
    const kinds = [_]core.Kind{ .json, .jwt, .base64, .base64_url, .base32, .base58, .data_uri, .magnet_uri, .mime_type, .locale, .sem_ver, .hex_color, .rgb_color, .hsl_color };
    const codes = [_][]const u8{ "validation.json", "validation.jwt", "validation.base64", "validation.base64_url", "validation.base32", "validation.base58", "validation.data_uri", "validation.magnet_uri", "validation.mime_type", "validation.locale", "validation.sem_ver", "validation.hex_color", "validation.rgb_color", "validation.hsl_color" };
    const messages = [_][]const u8{ "must be a valid JSON object or array", "must be a valid JWT", "must be valid base64", "must be valid base64url", "must be valid base32", "must be valid base58", "must be a valid data URI", "must be a valid magnet URI", "must be a valid MIME type", "must be a valid locale", "must be a valid semantic version", "must be a valid hex color", "must be a valid RGB color", "must be a valid HSL color" };
    inline for (rules, kinds, codes, messages) |rule, kind, code, message| {
        try t.expectEqual(kind, rule.kind);
        try t.expectEqualStrings(code, rule.code);
        try t.expectEqualStrings(message, rule.message);
        try t.expectEqual(null, rule.args);
        try t.expectEqual(0, rule.params.len);
        try t.expectEqual(null, rule.precondition);
    }
}

test "a rule of this file takes strings; [N]u8 and lists of strings get their hints, other types none" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "json expects a string, field is u32", comptime fieldText(json, u32).?);
    try expect(head ++ "json expects a string, field is [64]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(json, [64]u8).?);
    try expect(head ++ "json expects a string, field is []const []const u8; use v.each(v.json)", comptime fieldText(json, []const []const u8).?);
    try expect(head ++ "jwt expects a string, field is u64", comptime fieldText(jwt, u64).?);
    try expect(head ++ "data_uri expects a string, field is []const u32", comptime fieldText(dataUri, []const u32).?);
    try expect(head ++ "magnet_uri expects a string, field is [60]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(magnetUri, [60]u8).?);
    try expect(head ++ "mime_type expects a string, field is encodings.TestContentType", comptime fieldText(mimeType, TestContentType).?);
    try expect(head ++ "locale expects a string, field is []const []const u8; use v.each(v.locale)", comptime fieldText(locale, []const []const u8).?);
    try expect(head ++ "sem_ver expects a string, field is encodings.TestVersion", comptime fieldText(semVer, TestVersion).?);
    try expect(head ++ "hex_color expects a string, field is [7]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(hexColor, [7]u8).?);
    try expect(head ++ "rgb_color expects a string, field is [3]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(rgbColor, [3]u8).?);
    try expect(head ++ "hsl_color expects a string, field is f32", comptime fieldText(hslColor, f32).?);
    try expect(head ++ "base64 expects a string, field is u32", comptime fieldText(base64, u32).?);
    try expect(head ++ "base64_url expects a string, field is [64]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(base64Url, [64]u8).?);
    try expect(head ++ "base32 expects a string, field is [4:0]u8; [N]u8 is an array of numbers, not a string: use []const u8", comptime fieldText(base32, [4:0]u8).?);
    try expect(head ++ "base58 expects a string, field is []const []const u8; use v.each(v.base58)", comptime fieldText(base58, []const []const u8).?);
    try expect(head ++ "base64 expects a string, field is [2]?[]const u8; use v.each(v.base64)", comptime fieldText(base64, [2]?[]const u8).?);
    try expect(head ++ "base64 expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists", comptime fieldText(base64, []volatile u8).?);
    try expect(head ++ "base64 expects a string, field is []const u32", comptime fieldText(base64, []const u32).?);
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expectEqual(null, comptime fieldText(base64, T));
    }
}

test "base64 accepts canonical padded RFC 4648 base64 and the empty string" {
    const t = std.testing;
    for ([_][]const u8{ "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy", "AA==", "+/+/", "SGVsbG8sIHdvcmxkIQ==" }) |s| {
        t.expect(isBase64(s)) catch |err| {
            std.debug.print("isBase64 rejected \"{s}\"\n", .{s});
            return err;
        };
    }
    // Wrong length, missing or misplaced padding, non-zero pad bits, other
    // alphabets, whitespace and line breaks.
    for ([_][]const u8{ "Zg", "Zg=", "Zh==", "Zm9=", "AB==", "=Zg=", "Z===", "====", "Zg==Zg==", "-_-_", "Zm9v\nYmFy", " Zm9v", "Zm9v ", "Zm 9v", "Zm9v\x00", "Zm9\xff" }) |s| {
        t.expect(!isBase64(s)) catch |err| {
            std.debug.print("isBase64 accepted \"{s}\"\n", .{s});
            return err;
        };
    }
    try expectOutcome(.pass, base64, @as([]const u8, "Zm9v"));
    try expectOutcome(.fail, base64, @as([:0]const u8, "Zh=="));
}

test "base64Url accepts canonical unpadded base64url and the empty string" {
    const t = std.testing;
    for ([_][]const u8{ "", "Zg", "Zm8", "Zm9v", "-_-_", "eyJhbGciOiJIUzI1NiJ9", "AA" }) |s| try t.expect(isBase64Url(s));
    for ([_][]const u8{ "Z", "Zm9vY", "Zh", "Zm9", "Zg==", "Zm8=", "+/+/", "Zm9v\n", " Zg" }) |s| try t.expect(!isBase64Url(s));
    try expectOutcome(.fail, base64Url, @as([]const u8, "Zg=="));
}

test "base32 accepts canonical padded uppercase RFC 4648 base32 and the empty string" {
    const t = std.testing;
    // RFC 4648 §10 test vectors.
    for ([_][]const u8{ "", "MY======", "MZXQ====", "MZXW6===", "MZXW6YQ=", "MZXW6YTB", "MZXW6YTBOI======" }) |s| {
        t.expect(isBase32(s)) catch |err| {
            std.debug.print("isBase32 rejected \"{s}\"\n", .{s});
            return err;
        };
    }
    // Lowercase, no padding, a length that is not a multiple of 8, pad
    // counts 2, 7 and 8, non-zero unused bits (`MZ======`, `MZXW6YTBOJ======`),
    // padding inside the data, digits outside 2-7.
    for ([_][]const u8{ "my======", "MZXW6YTBOI", "MY=====", "MZXW6Y==", "A=======", "========", "MZ======", "MZXW6YTBOJ======", "MZXQ=A==", "MZXW6YT1", "MZXW6YT0", "MZXW6YT8" }) |s| {
        t.expect(!isBase32(s)) catch |err| {
            std.debug.print("isBase32 accepted \"{s}\"\n", .{s});
            return err;
        };
    }
}

test "base58 accepts the Bitcoin alphabet only, without 0, O, I and l" {
    const t = std.testing;
    for ([_][]const u8{ "", "1", "111", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "z", "9" }) |s| try t.expect(isBase58(s));
    for ([_][]const u8{ "0", "O", "I", "l", "1 1", "+", "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa\n", "\xc3\xa9" }) |s| try t.expect(!isBase58(s));
}

test "json passes an object or an array at the top level, with whitespace around it" {
    const t = std.testing;
    for ([_][]const u8{
        "{}",                "[]",                               " [1] ",                "\t\r\n{\"a\":1}\n",
        "{\"a\":1,\"a\":2}", "[1e400,-0.0e+0]",                  "[\"\\uD83D\\uDE00\"]", "[\"\\ud83d\\ude00\"]",
        "[\"\x7f\"]",        "[\"\u{2028}\"]",                   "[\"caf\xc3\xa9\"]",    "{\"a\":[true,false,null,\"x\"]}",
        "[[],{}]",           "[\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"]",
    }) |s| {
        t.expect(isJson(s)) catch |err| {
            std.debug.print("isJson rejected \"{f}\"\n", .{std.zig.fmtString(s)});
            return err;
        };
    }
}

test "json fails top-level scalars, broken syntax, invalid UTF-8 and lone surrogates" {
    const t = std.testing;
    for ([_][]const u8{
        "",               " ",             "1",                    "\"str\"",
        "true",           "null",          "{\"a\":1,}",           "{'a':1}",
        "[01]",           "[NaN]",         "[1] [2]",              "\xef\xbb\xbf[]",
        "[\"\\ud800\"]",  "[\"\\udc00\"]", "[\"\\ud800\\u0041\"]", "[\"\xed\xa0\x80\"]",
        "[\"\xc0\xaf\"]", "[\"\xff\"]",    "{\"a\":1}\x00",        "[\xc3\xa9]",
        "[\"a\nb\"]",     "[\"\x01\"]",    "[1,]",                 "{\"a\"}",
        "[",              "]",             "{\"a\":1",             "[\"\\x41\"]",
        "\x0b[]",         "\x0c[]",        "[] \xc2\xa0",          "[.5]",
    }) |s| {
        t.expect(!isJson(s)) catch |err| {
            std.debug.print("isJson accepted \"{f}\"\n", .{std.zig.fmtString(s)});
            return err;
        };
    }
}

test "json counts nesting across arrays and objects: 64 levels pass, 65 fail, 100000 fail without the heap" {
    const t = std.testing;
    const depth = core.max_json_depth;
    var arrays: [2 * (depth + 1)]u8 = undefined;
    @memset(arrays[0..depth], '[');
    @memset(arrays[depth .. 2 * depth], ']');
    try t.expect(isJson(arrays[0 .. 2 * depth]));
    @memset(arrays[0 .. depth + 1], '[');
    @memset(arrays[depth + 1 ..], ']');
    try t.expect(!isJson(&arrays));
    // 65 unclosed levels fail at level 65, before the end of the input.
    try t.expect(!isJson(arrays[0 .. depth + 1]));
    // {"a":[ 32 times is 64 levels; 33 times is 66.
    const open = "{\"a\":[";
    const close = "]}";
    var mixed: [33 * (open.len + close.len)]u8 = undefined;
    for (0..2) |extra| {
        const n = 32 + extra;
        var len: usize = 0;
        for (0..n) |_| {
            @memcpy(mixed[len..][0..open.len], open);
            len += open.len;
        }
        for (0..n) |_| {
            @memcpy(mixed[len..][0..close.len], close);
            len += close.len;
        }
        try t.expectEqual(extra == 0, isJson(mixed[0..len]));
    }
    var huge: [100_000]u8 = @splat('[');
    try t.expect(!isJson(&huge));
}

test "jwt passes three canonical base64url segments with a header and a payload" {
    const t = std.testing;
    for ([_][]const u8{
        // The example of RFC 7519 §3.1.
        "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        // An Unsecured JWT: the signature is empty.
        "eyJhbGciOiJub25lIn0.eyJzdWIiOiIxIn0.",
        // Nothing is decoded: {} as header and payload is a shape like any other.
        "e30.e30.e30",
    }) |s| try t.expect(isJwt(s));
    for ([_][]const u8{
        "",          "..",          ".e30.",              "e30..",           "e30.e30",
        "e30",       "a.b.c",       "e30.e31.e30",        "e30.e30.e30.e30", "e30.e30.e30.e30.e30",
        "e30=.e30.", "e30.e+0.e30", "Bearer e30.e30.e30", "e30.e30.e30 ",    "e30.e30.e30\n",
    }) |s| {
        t.expect(!isJwt(s)) catch |err| {
            std.debug.print("isJwt accepted \"{f}\"\n", .{std.zig.fmtString(s)});
            return err;
        };
    }
}

/// Runs `predicate` on each string and fails with the first that it does not
/// answer with `expected`.
fn expectAll(comptime name: []const u8, predicate: fn ([]const u8) bool, expected: bool, inputs: []const []const u8) !void {
    for (inputs) |s| {
        if (predicate(s) != expected) {
            std.debug.print("{s} {s} \"{f}\"\n", .{ name, if (expected) "rejected" else "accepted", std.zig.fmtString(s) });
            return error.TestUnexpectedResult;
        }
    }
}

const btih = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a";

test "dataUri passes RFC 2397 data URLs with a known media type, parameters and checked base64" {
    try expectAll("isDataUri", isDataUri, true, &.{
        "data:,",
        "data:,A%20brief%20note",
        "data:text/plain;BASE64,SGVsbG8=",
        "data:;base64,",
        "data:application/pdf;name=report.pdf;base64,JVBERi0=",
        "data:text/plain;charset=utf-8,hello,world",
        "data:image/svg+xml,%3Csvg%3E%3C/svg%3E",
        "data:text/plain;charset=US-ASCII;x=%41,a",
    });
    try expectAll("isDataUri", isDataUri, false, &.{
        "",                              "data:",                                    "data:text/plain",
        "DATA:,x",                       "data:,a b",                                " data:,x",
        "data:,x ",                      "data:,%zz",                                "data:,%fg",
        "data:,%2",                      "data:text/plain;base64,!!!",               "data:;base64,SGVsbG8",
        "data:foo/bar,x",                "data:image/png;base64;charset=utf-8,AAAA", "data:image/svg+xml;utf8,<svg></svg>",
        "data:,a#b",                     "data:text/plain;charset=,x",               "data:text/plain;=utf-8,x",
        "data:text/plain;base64,SGk%3D", "data:image/a#b,x",                         "data:image/a^b,x",
        "data:,caf\xc3\xa9",             "data:text/plain;;base64,",                 "data:text/plain;charset=a=b,x",
    });
}

test "magnetUri passes a magnet URI whose xt or xt.1 is an exact topic validator.js knows" {
    try expectAll("isMagnetUri", isMagnetUri, true, &.{
        "magnet:?xt=urn:btih:" ++ btih,
        "magnet:?xt=urn:btih:" ++ btih ++ "&",
        "magnet:?dn&xt=urn:btih:" ++ btih,
        "magnet:?&xt=urn:btih:" ++ btih,
        "magnet:?XT=URN:BTIH:C12FE1C06BBA254A9DC9F519B335AA7C1367A88A",
        "magnet:?dn=file.txt&xt.1=urn:sha1:" ++ btih ++ "&tr=udp%3A%2F%2Ftracker",
        "magnet:?xt=urn:btih:" ++ btih[0..32],
        "magnet:?xt=urn:tree:tiger:" ++ btih[0..32],
        "magnet:?xt=urn:btmh:1220" ++ btih ++ btih[0..24],
    });
    try expectAll("isMagnetUri", isMagnetUri, false, &.{
        "",
        "magnet:?",
        "magnet:",
        "MAGNET:?xt=urn:btih:" ++ btih,
        "magnet:?xt=urn:btih:" ++ btih ++ "&dn=a b",
        "magnet:?xt=urn:btih:" ++ btih ++ "&dn=%ZZ",
        "magnet:?xt=urn:btih:" ++ btih ++ "#top",
        "magnet:?xt.2=urn:btih:" ++ btih,
        "magnet:?xt=urn:tree:tiger:" ++ btih[0..39],
        "magnet:?xt=urn:btih:" ++ btih[0..33],
        "magnet:?xt=urn:sha256:" ++ btih,
        "magnet:?xt=urn:btmh:1220" ++ btih,
        "magnet:?xt=urn:btih:" ++ btih[0..39] ++ "-",
        "magnet:?dn=urn:btih:" ++ btih,
    });
}

test "mimeType passes an IANA top-level type, an RFC 6838 subtype and RFC 9110 parameters" {
    try expectAll("isMimeType", isMimeType, true, &.{
        "text/plain",
        "application/json; charset=utf-8",
        "example/foo",
        "haptics/ivs",
        "IMAGE/PNG",
        "application/vnd.api+json",
        "text/plain; charset=\"\"",
        "text/plain ;charset=utf-8",
        "text/plain;a=b;c=d",
        "multipart/form-data; boundary=\"a b\\\"c\"",
        "text/plain;\tcharset=utf-8",
        "font/woff2",
        "model/gltf+json",
    });
    try expectAll("isMimeType", isMimeType, false, &.{
        "",                                    "text",                             "text/",
        "/plain",                              "foo/bar",                          "image/.png",
        "image/png;",                          "text/plain; charset=",             "text/plain; charset = utf-8",
        "text/plain; charset=utf-8 ",          "text/plain; charset=\"\xc3\xa9\"", "text/plain; charset=utf-8 (comment)",
        "text/plain\r\n",                      "text/plain; charset=\"open",       "text/plain; =utf-8",
        "text/plain charset=utf-8",            "text/pl ain",                      "text/plain;charset=\"a\\\x01\"",
        "image/" ++ @as([128]u8, @splat('a')),
    });
    try std.testing.expect(isMimeType("image/" ++ @as([127]u8, @splat('a'))));
}

test "locale passes well-formed BCP 47 tags in any case, grandfathered and private-use ones included" {
    try expectAll("isLocale", isLocale, true, &.{
        "en",              "en-US",          "zh-Hant-TW", "de-CH-1901", "zh-min-nan",     "SGN-be-FR",
        "i-klingon",       "I-KLINGON",      "x-private",  "X-PRIVATE",  "english",        "en-a-bbb-a-ccc",
        "en-US-x-twain",   "sl-rozaj-biske", "es-419",     "en-GB-oed",  "zh-yue-cmn-ara", "de-1996",
        "en-u-ca-gregory", "x-a",
    });
    try expectAll("isLocale", isLocale, false, &.{
        "",             "x",        "en_US",      "abcd",               "e",          "en-",
        "-en",          "de-1---",  "en-a",       "en-x",               "en-a-x-foo", "i-foo",
        "123",          "en-US-",   "toolongtag", "en-abc-abc-abc-abc", "en US",      "en-US\n",
        "en-Latn-Latn", "en-US-DE", "en-a-b",     "e\xc3\xa9",
    });
}

test "semVer passes the grammar of Semantic Versioning 2.0.0, numbers of any size" {
    try expectAll("isSemVer", isSemVer, true, &.{
        "0.0.0",                       "1.2.3",                       "1.0.0-alpha", "1.0.0-alpha.1",
        "1.0.0-0.3.7",                 "1.0.0-x.7.z.92",              "1.0.0+001",   "1.0.0-01a",
        "1.0.0-alpha+exp.sha.5114f85", "99999999999999999999999.0.0", "1.0.0--",     "1.0.0-a-b+c-d",
    });
    try expectAll("isSemVer", isSemVer, false, &.{
        "",         "v1.2.3",         "1.2",           "1.2.3.4",   "01.2.3",     "1.02.3",
        "1.2.3-01", "1.2.3-alpha..1", "1.2.3-alpha_1", "1.0.0+a+b", "1.0.0+",     "1.0.0-",
        " 1.2.3",   "1.2.3 ",         "1..3",          "1.2.3-",    "1.2.3+a..b", "a.b.c",
    });
}

test "hexColor passes # and 3, 4, 6 or 8 hex digits in any case" {
    try expectAll("isHexColor", isHexColor, true, &.{ "#fff", "#FFFF", "#ff0000", "#Ff000080", "#000", "#abcdef" });
    try expectAll("isHexColor", isHexColor, false, &.{
        "",     "#",           "fff",   "ff0000", "#ff",   "#fffff", "#fffffff",
        "#ggg", "#ff00000080", " #fff", "#fff ",  "##fff", "#ff 0",  "#\xc3\xa9f",
    });
}

test "rgbColor passes the legacy comma syntax: all integers or all percentages, and an alpha for rgba only" {
    try expectAll("isRgbColor", isRgbColor, true, &.{
        "rgb(255,0,0)",        "rgb(255, 0, 0)",       "rgb( 0 , 0 , 0 )",    "rgb(100%,0%,50%)",
        "rgba(0,0,0,0)",       "rgba(0, 0, 0, 0.004)", "rgba(0,0,0,1.00)",    "rgba(0,0,0,.5)",
        "rgba(255,255,255,1)", "rgb(255,\r\n0,\x0c0)", "rgba(1%,2%,3%,0.25)",
    });
    try expectAll("isRgbColor", isRgbColor, false, &.{
        "",                "rgb(256,0,0)",   "rgb(255,0%,0)",   "rgb(101%,0%,0%)",
        "rgb(255 0 0)",    "RGB(255,0,0)",   "rgb(255,0,0,1)",  "rgba(255,0,0)",
        "rgba(0,0,0,1.5)", "rgba(0,0,0,01)", "rgba(0,0,0,50%)", "rgb(01,0,0)",
        "rgb(1000,0,0)",   " rgb(0,0,0)",    "rgb(0,0,0) ",     "rgb(255,\x0b0,0)",
        "rgb(0,0,0",       "rgb(,0,0)",      "rgba(0,0,0,)",    "rgba(0,0,0,1.01)",
        "rgb(-1,0,0)",     "rgb(0,0,0)x",    "rgb(0.5,0,0)",    "rgba(0,0,0,0.5%)",
        "rgba(0,0,0,0.)",
    });
}

test "hslColor passes the legacy and modern syntaxes with units, exponents and any range" {
    try expectAll("isHslColor", isHslColor, true, &.{
        "hsl(120,100%,50%)",       "hsl(120, 100%, 50%, 0.5)",  "hsla(120,100%,50%,.5)",
        "hsl(120 100% 50%)",       "hsl(120 100% 50% / 0.5)",   "hsl(120 100% 50%/0.5)",
        "hsla(120 100% 50%)",      "HSL(120,100%,50%)",         "hsl(120deg,100%,50%)",
        "hsl(0.5TURN 100% 50%)",   "hsl(-120, 200%, -5%)",      "hsl(1e2, 1e1%, 5E-1%)",
        "hsl(+.5rad 0% 0% / 50%)", "hsl(\t120\n100%\r50%\x0c)", "hsl(100grad,1%,1%)",
    });
    try expectAll("isHslColor", isHslColor, false, &.{
        "",                      " hsl(120,100%,50%)",  "hsl(120,100%,50%) ",       "hsl(120,100,50%)",
        "hsl(120 100% 50% 0.5)", "hsl(120,100% 50%)",   "hsl(120deggrad,100%,50%)", "hsl(120\xc2\xa0100% 50%)",
        "hsl(120\x0b100% 50%)",  "hsl(120 100%50%)",    "hsl(120100% 50%)",         "hsl(1.,100%,50%)",
        "hsl(120,100%,50%,)",    "hsl(120 100% 50% /)", "hsl()",                    "hsl(120,100%,50%",
        "hsb(120,100%,50%)",     "hsl(e1,100%,50%)",    "hsl(120,100%,50%,0.5,1)",  "hsl(1e,100%,50%)",
    });
}
