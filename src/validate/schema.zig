// Copied from vkiryakov/zefir src/validator/schema.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Rules as JSON Schema: `v.schemaOf` gives one element of `field_rules` as
//! the keywords that say what it checks, for a program that describes a DTO
//! to the outside, such as an OpenAPI document. Each rule file maps its own
//! kinds next to the rules (`schemaOf` there); this file holds the type, the
//! dispatch over every kind and the helpers that write JSON text.
//!
//! Regular expressions keep to what ECMA-262 (with the `u` flag) and RE2
//! read alike: no lookaround, no backreferences, no `\d`, `\s`, `\S`, `\w`
//! or `\b`, no repetition count above 1000. A character outside printable
//! ASCII stands in a pattern as itself, and JSON text escapes it, so that
//! both engines get the character and not a `\u` escape of their own.
const std = @import("std");
const core = @import("core.zig");
const common = @import("common.zig");
const numbers = @import("numbers.zig");
const strings = @import("strings.zig");
const formats = @import("formats.zig");
const encodings = @import("encodings.zig");
const identifiers = @import("identifiers.zig");
const dates = @import("dates.zig");
const lists = @import("lists.zig");
const custom_rules = @import("custom.zig");
const transforms = @import("transforms.zig");

/// The JSON Schema keywords of one element of `field_rules`, as data: what
/// `v.schemaOf` returns. The keywords never name the type (`"type"`): the
/// field's type gives it.
pub const RuleSchema = struct {
    /// How exactly the keywords say what the element checks.
    accuracy: Accuracy,
    /// In a fixed order per kind; `value` is JSON text: "200", "\"^[0-9]+$\"", "[\"a\",null]".
    keywords: []const Keyword = &.{},
    /// `each`: the schemas of its item transforms and item rules, in order; they apply to `items`.
    items: []const RuleSchema = &.{},
    /// One sentence for the description, ending with '.'; null when there is nothing to say.
    note: ?[]const u8 = null,

    pub const Accuracy = enum {
        /// A value passes the keywords exactly when it passes the rule; a
        /// float bound may differ in the last bit, as the rule compares in
        /// the field's type. Transforms are exact: they check nothing.
        exact,
        /// The keywords pass every value the rule passes, and some that it
        /// fails (a checksum, a long grammar): the note says what the server
        /// checks. `format`, a hint that tools may not check, is not counted.
        approximate,
        /// No keyword says it; the note does.
        none,
    };

    pub const Keyword = struct { name: []const u8, value: []const u8 };
};

/// The JSON Schema keywords of `element`, a rule or a transform of
/// `field_rules` (not `v.rename`: `v.nameOf` gives the name), on a field of
/// type `T` as declared, `?U` and `[]const U` included:
/// `v.schemaOf(v.maxLength(200), []const u8)` has `maxLength` with the value
/// `"200"`. Keyword values are JSON text, ready to write into a document.
///
/// The keywords describe the value as the client sends it, before
/// transforms; a transform has no keywords and a note for the description
/// ("Leading and trailing spaces are removed."). On `?U`, `null` passes
/// every rule, as in `v.check`: `const` becomes `enum` with `null`, and an
/// `enum` gets `null`. `v.each` has no keywords of its own: `items` holds
/// the schemas of its item transforms and rules, and its accuracy is the
/// least accurate of theirs. A rule or a transform on a type it does not
/// take is the declaration error that `v.check` gives, with `schemaOf(<T>)`
/// in place of the field's path.
pub fn schemaOf(comptime element: anytype, comptime T: type) RuleSchema {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        const U = core.Unwrap(T);
        const where = "schemaOf(" ++ @typeName(T) ++ ")";
        switch (@TypeOf(element)) {
            core.Rule => {
                element.fits(&element, U, where);
                const schema = ruleSchema(element, U);
                return if (U == T) schema else nullable(schema);
            },
            core.Transform => {
                element.fits(&element, U, where);
                return transforms.schemaOf(element);
            },
            core.Rename => @compileError("validator: " ++ where ++ ": rename(\"" ++ core.escape(element.name) ++
                "\") is a name, not a rule; v.nameOf gives the outside name of a field"),
            else => @compileError("validator: " ++ where ++ ": expected a rule or a transform, got " ++ @typeName(@TypeOf(element))),
        }
    }
}

/// The schema of `rule` on the unwrapped field type `U`, from the file that
/// defines its kind. The switch has no `else`: a new kind without a mapping
/// stops every build of the module.
fn ruleSchema(comptime rule: core.Rule, comptime U: type) RuleSchema {
    return switch (rule.kind) {
        .equals, .not_equals, .one_of, .none_of, .empty, .not_empty => common.schemaOf(rule, U),
        .min, .max, .range, .positive, .non_negative, .negative, .non_positive, .divisible_by, .finite => numbers.schemaOf(rule, U),
        .min_length,
        .max_length,
        .length,
        .min_bytes,
        .max_bytes,
        .utf8,
        .not_blank,
        .ascii,
        .printable_ascii,
        .alphanumeric,
        .alpha,
        .digits,
        .lowercase,
        .uppercase,
        .multibyte,
        .full_width,
        .half_width,
        .variable_width,
        .contains,
        .not_contains,
        .strong_password,
        => strings.schemaOf(rule, U),
        .number_string,
        .decimal,
        .boolean_string,
        .hexadecimal,
        .octal,
        .port,
        .latitude,
        .longitude,
        .lat_long,
        .email,
        .http_url,
        .fqdn,
        .ip,
        .ipv4,
        .ipv6,
        .mac_address,
        => formats.schemaOf(rule, U),
        .json,
        .jwt,
        .base32,
        .base58,
        .base64,
        .base64_url,
        .data_uri,
        .magnet_uri,
        .mime_type,
        .locale,
        .sem_ver,
        .hex_color,
        .rgb_color,
        .hsl_color,
        => encodings.schemaOf(rule, U),
        .uuid,
        .mongo_id,
        .firebase_push_id,
        .hash,
        .credit_card,
        .isbn,
        .isbn10,
        .isbn13,
        .issn,
        .ean,
        .isin,
        .isrc,
        .bic,
        .iban,
        .btc_address,
        .ethereum_address,
        => identifiers.schemaOf(rule, U),
        .date, .rfc3339, .iso8601, .min_date, .max_date, .military_time => dates.schemaOf(rule, U),
        .min_items, .max_items, .unique_items, .unique_by, .contains_all, .contains_none, .each => lists.schemaOf(rule, U),
        .custom => custom_rules.schemaOf(rule, U),
    };
}

/// The schema of a rule on `?U` from its schema on `U`. `null` passes every
/// rule, and of the keywords only `const` and `enum` look at it: `const`
/// becomes `enum` with `null`, and an `enum` gets `null`. A `not` that holds
/// a `pattern` carries `"type":"string"` on any field, so `null` passes it.
fn nullable(comptime schema: RuleSchema) RuleSchema {
    var keywords: []const RuleSchema.Keyword = &.{};
    for (schema.keywords) |k| {
        const with_null: RuleSchema.Keyword = if (std.mem.eql(u8, k.name, "const"))
            .{ .name = "enum", .value = "[" ++ k.value ++ ",null]" }
        else if (std.mem.eql(u8, k.name, "enum"))
            .{ .name = "enum", .value = k.value[0 .. k.value.len - 1] ++ ",null]" }
        else
            k;
        keywords = keywords ++ &[_]RuleSchema.Keyword{with_null};
    }
    var copy = schema;
    copy.keywords = keywords;
    return copy;
}

// ------------------------------------------------------------------ building schemas

/// An exact schema of `keywords`.
pub fn exact(comptime keywords: []const RuleSchema.Keyword) RuleSchema {
    return .{ .accuracy = .exact, .keywords = keywords };
}

/// An approximate schema of `keywords` whose note says what the server
/// checks: `checks` is the rest of "Checked by the server: <checks>.".
pub fn approximate(comptime keywords: []const RuleSchema.Keyword, comptime checks: []const u8) RuleSchema {
    return .{ .accuracy = .approximate, .keywords = keywords, .note = checkedNote(checks) };
}

/// A schema without keywords whose note says what the server checks.
pub fn none(comptime checks: []const u8) RuleSchema {
    return .{ .accuracy = .none, .note = checkedNote(checks) };
}

/// "Checked by the server: <checks>.", without a second '.'.
fn checkedNote(comptime checks: []const u8) []const u8 {
    const stop = if (checks.len > 0 and checks[checks.len - 1] == '.') "" else ".";
    return "Checked by the server: " ++ checks ++ stop;
}

/// A keyword whose value is the JSON text `text`.
pub fn keyword(comptime name: []const u8, comptime text: []const u8) RuleSchema.Keyword {
    return .{ .name = name, .value = text };
}

/// `name` with an integer value: `"maxLength"` and `"200"`.
pub fn count(comptime name: []const u8, comptime n: comptime_int) RuleSchema.Keyword {
    return keyword(name, integer(n));
}

/// `pattern` with the regular expression `regex`.
pub fn pattern(comptime regex: []const u8) RuleSchema.Keyword {
    return keyword("pattern", string(regex));
}

/// `format` with a name from the format registry of OpenAPI: `"email"`.
pub fn format(comptime name: []const u8) RuleSchema.Keyword {
    return keyword("format", string(name));
}

/// `{"type":"string","pattern":...}`: a pattern to put inside `not`, where
/// the type lets `null` and other values pass the `not` of a nullable field.
pub fn stringPattern(comptime regex: []const u8) []const u8 {
    return object(&.{ keyword("type", string("string")), pattern(regex) });
}

/// `allOf` of one `pattern` per regular expression.
pub fn allPatterns(comptime regexes: []const []const u8) RuleSchema.Keyword {
    var items: []const []const u8 = &.{};
    for (regexes) |regex| items = items ++ &[_][]const u8{object(&.{pattern(regex)})};
    return keyword("allOf", array(items));
}

// ------------------------------------------------------------------ JSON text

/// `s`, valid UTF-8, as a JSON string, written as `std.json` writes it with
/// `.escape_unicode = true`: `"` and `\` escaped, `\b \f \n \r \t`, any other
/// control character, DEL and every code point above ASCII as `\u` and four
/// lowercase hex digits (a surrogate pair above U+FFFF). The text is ASCII,
/// and a reader gets every character back.
pub fn string(comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var out: []const u8 = "\"";
        // The start of the run of characters that need no escape.
        var start: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            const escaped: []const u8, const len: usize = switch (c) {
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => {
                    i += 1;
                    continue;
                },
                '"' => .{ "\\\"", 1 },
                '\\' => .{ "\\\\", 1 },
                0x08 => .{ "\\b", 1 },
                0x0c => .{ "\\f", 1 },
                '\n' => .{ "\\n", 1 },
                '\r' => .{ "\\r", 1 },
                '\t' => .{ "\\t", 1 },
                0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => .{ unicodeEscape(c), 1 },
                0x80...0xff => blk: {
                    const n = std.unicode.utf8ByteSequenceLength(c) catch @compileError("validator: internal: JSON text of invalid UTF-8");
                    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch @compileError("validator: internal: JSON text of invalid UTF-8");
                    break :blk .{ unicodeEscape(cp), n };
                },
            };
            out = out ++ s[start..i] ++ escaped;
            i += len;
            start = i;
        }
        return out ++ s[start..] ++ "\"";
    }
}

/// `\uxxxx` for `cp`, two of them for a code point above U+FFFF.
fn unicodeEscape(comptime cp: u21) []const u8 {
    if (cp <= 0xffff) return std.fmt.comptimePrint("\\u{x:0>4}", .{cp});
    const high = 0xd800 + ((cp - 0x10000) >> 10);
    const low = 0xdc00 + (cp & 0x3ff);
    return std.fmt.comptimePrint("\\u{x:0>4}\\u{x:0>4}", .{ high, low });
}

/// An integer as JSON text, exact at any size.
pub fn integer(comptime n: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// A parameter of a rule as JSON text: a float as written, in the shortest
/// form that reads back to the same value in its own type (its text, as
/// messages show it); anything else as `value` writes it.
pub fn param(comptime p: core.Param) []const u8 {
    return switch (p.value) {
        .float => p.text,
        else => value(p.value),
    };
}

/// A parameter value as JSON text: an integer, `true` or `false`, a string,
/// an enum tag by its name, or a list in brackets. A float is written from
/// its text, by `param`.
pub fn value(comptime x: core.Value) []const u8 {
    return switch (x) {
        .int => |n| integer(n),
        .float => @compileError("validator: internal: a float parameter is written from its text"),
        .bool => |b| if (b) "true" else "false",
        .string, .tag => |s| string(s),
        .list => |items| blk: {
            var texts: []const []const u8 = &.{};
            for (items) |item| texts = texts ++ &[_][]const u8{value(item)};
            break :blk array(texts);
        },
    };
}

/// A JSON object of `keywords`, in their order: `{"const":1}`.
pub fn object(comptime keywords: []const RuleSchema.Keyword) []const u8 {
    var out: []const u8 = "{";
    for (keywords, 0..) |k, i| out = out ++ (if (i == 0) "" else ",") ++ string(k.name) ++ ":" ++ k.value;
    return out ++ "}";
}

/// A JSON array of the JSON texts `items`: `["a","b"]`.
pub fn array(comptime items: []const []const u8) []const u8 {
    var out: []const u8 = "[";
    for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else ",") ++ item;
    return out ++ "]";
}

// ------------------------------------------------------------------ regular expressions

/// The most repetitions a count may ask for: RE2 refuses more than 1000.
pub const max_repeat = 1000;

/// `text` as a regular expression that matches it literally: the syntax
/// characters of ECMA-262 (`^ $ \ . * + ? ( ) [ ] { } |`) are escaped, as
/// both engines read them; every other character stands for itself.
pub fn literal(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var out: []const u8 = "";
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (std.mem.findScalar(u8, "^$\\.*+?()[]{}|", c) == null) continue;
            out = out ++ text[start..i] ++ "\\" ++ [1]u8{c};
            start = i + 1;
        }
        return out ++ text[start..];
    }
}

/// A repetition count, `{n}`, `{n,}` or `{n,m}`, for `min` to `max` (null:
/// no upper bound) repetitions.
pub fn repetition(comptime min: comptime_int, comptime max: ?comptime_int) []const u8 {
    const m = max orelse return "{" ++ integer(min) ++ ",}";
    if (m == min) return "{" ++ integer(min) ++ "}";
    return "{" ++ integer(min) ++ "," ++ integer(m) ++ "}";
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectStdJson(comptime s: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.encodeJsonString(s, .{ .escape_unicode = true }, &w);
    try testing.expectEqualStrings(w.buffered(), comptime string(s));
}

test "JSON strings are written as std.json writes them with escape_unicode" {
    inline for (.{
        "",
        "plain text",
        "\"quoted\" and \\back\\slashes",
        "\x00\x01\x07\x08\t\n\x0b\x0c\r\x0e\x1f\x7f",
        "/ and ' stay",
        "é ß \u{85} \u{a0} \u{3000} \u{ffff}",
        "😀 \u{10000} \u{10ffff}",
    }) |s| try expectStdJson(s);
}

test "a non-ASCII character becomes a \\u escape that std.json reads back" {
    const text = comptime string("a\u{85}b\u{3000}c😀");
    try testing.expectEqualStrings("\"a\\u0085b\\u3000c\\ud83d\\ude00\"", text);
    const parsed = try std.json.parseFromSlice([]const u8, testing.allocator, text, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\u{85}b\u{3000}c😀", parsed.value);
}

test "values are written as JSON: integers exact, floats from their text, tags and strings as strings, lists in brackets" {
    try testing.expectEqualStrings("-170141183460469231731687303715884105728", comptime integer(std.math.minInt(i128)));
    try testing.expectEqualStrings("0.1", comptime param(core.param("min", @as(f32, 0.1))));
    try testing.expectEqualStrings("1e-7", comptime param(core.param("min", 1e-7)));
    try testing.expectEqualStrings("1e21", comptime param(core.param("max", 1e21)));
    try testing.expectEqualStrings("2.5", comptime param(core.param("max", 2.5)));
    try testing.expectEqualStrings("0", comptime param(core.param("max", -0.0)));
    try testing.expectEqualStrings("12", comptime param(core.param("max", 12)));
    try testing.expectEqualStrings("true", comptime value(core.valueOf(true)));
    try testing.expectEqualStrings("\"admin\"", comptime value(core.valueOf(.admin)));
    try testing.expectEqualStrings("[\"a\",\"\\\"b\\\"\"]", comptime value(core.valueOf(.{ "a", "\"b\"" })));
    try testing.expectEqualStrings("[1,-2,3]", comptime value(core.valueOf(.{ 1, -2, 3 })));
    try testing.expectEqualStrings("[]", comptime array(&.{}));
    try testing.expectEqualStrings("{}", comptime object(&.{}));
    try testing.expectEqualStrings("{\"const\":1,\"not\":{\"enum\":[2]}}", comptime object(&.{
        keyword("const", "1"),
        keyword("not", object(&.{keyword("enum", "[2]")})),
    }));
}

test "a literal escapes the syntax characters of ECMA-262 and nothing else" {
    try testing.expectEqualStrings("a\\.b\\*c\\+d\\?e", comptime literal("a.b*c+d?e"));
    try testing.expectEqualStrings("\\^\\$\\\\\\(\\)\\[\\]\\{\\}\\|", comptime literal("^$\\()[]{}|"));
    try testing.expectEqualStrings("-/,:@#\"' é\n", comptime literal("-/,:@#\"' é\n"));
}

test "repetition counts" {
    try testing.expectEqualStrings("{3}", comptime repetition(3, 3));
    try testing.expectEqualStrings("{1,4}", comptime repetition(1, 4));
    try testing.expectEqualStrings("{2,}", comptime repetition(2, null));
}

test "the note of an approximate or unexpressed rule says what the server checks, ending with one '.'" {
    const s = comptime approximate(&.{format("email")}, "a valid email address");
    try testing.expectEqual(RuleSchema.Accuracy.approximate, s.accuracy);
    try testing.expectEqualStrings("Checked by the server: a valid email address.", s.note.?);
    try testing.expectEqualStrings("Checked by the server: is even.", comptime none("is even.").note.?);
    try testing.expectEqual(null, comptime exact(&.{}).note);
}

test "on ?U, const becomes an enum with null and an enum gets null; other keywords stay" {
    const s = comptime nullable(exact(&.{
        keyword("const", "\"x\""),
        keyword("enum", "[1,2]"),
        keyword("not", object(&.{keyword("const", "3")})),
        pattern("^a"),
    }));
    try testing.expectEqualStrings("enum", s.keywords[0].name);
    try testing.expectEqualStrings("[\"x\",null]", s.keywords[0].value);
    try testing.expectEqualStrings("[1,2,null]", s.keywords[1].value);
    try testing.expectEqualStrings("{\"const\":3}", s.keywords[2].value);
    try testing.expectEqualStrings("\"^a\"", s.keywords[3].value);
}

/// A rule of `kind` and a field type it takes, for the census. The switch
/// has no `else`: a new kind needs its row here too.
fn sample(comptime kind: core.Kind) struct { rule: core.Rule, T: type } {
    const v = @import("root.zig");
    const Keyed = struct { id: u32 };
    const S = []const u8;
    return switch (kind) {
        .equals => .{ .rule = v.equals(1), .T = u32 },
        .not_equals => .{ .rule = v.notEquals(1), .T = u32 },
        .one_of => .{ .rule = v.oneOf(.{"a"}), .T = S },
        .none_of => .{ .rule = v.noneOf(.{"a"}), .T = S },
        .empty => .{ .rule = v.empty, .T = S },
        .not_empty => .{ .rule = v.notEmpty, .T = S },
        .min => .{ .rule = v.min(1), .T = u32 },
        .max => .{ .rule = v.max(1), .T = u32 },
        .range => .{ .rule = v.range(1, 2), .T = u32 },
        .positive => .{ .rule = v.positive, .T = u32 },
        .non_negative => .{ .rule = v.nonNegative, .T = i32 },
        .negative => .{ .rule = v.negative, .T = i32 },
        .non_positive => .{ .rule = v.nonPositive, .T = i32 },
        .divisible_by => .{ .rule = v.divisibleBy(2), .T = u32 },
        .finite => .{ .rule = v.finite, .T = f64 },
        .min_length => .{ .rule = v.minLength(1), .T = S },
        .max_length => .{ .rule = v.maxLength(1), .T = S },
        .length => .{ .rule = v.length(1, 2), .T = S },
        .min_bytes => .{ .rule = v.minBytes(1), .T = S },
        .max_bytes => .{ .rule = v.maxBytes(1), .T = S },
        .utf8 => .{ .rule = v.utf8, .T = S },
        .not_blank => .{ .rule = v.notBlank, .T = S },
        .ascii => .{ .rule = v.ascii, .T = S },
        .printable_ascii => .{ .rule = v.printableAscii, .T = S },
        .alphanumeric => .{ .rule = v.alphanumeric, .T = S },
        .alpha => .{ .rule = v.alpha, .T = S },
        .digits => .{ .rule = v.digits, .T = S },
        .lowercase => .{ .rule = v.lowercase, .T = S },
        .uppercase => .{ .rule = v.uppercase, .T = S },
        .multibyte => .{ .rule = v.multibyte, .T = S },
        .full_width => .{ .rule = v.fullWidth, .T = S },
        .half_width => .{ .rule = v.halfWidth, .T = S },
        .variable_width => .{ .rule = v.variableWidth, .T = S },
        .contains => .{ .rule = v.contains("a"), .T = S },
        .not_contains => .{ .rule = v.notContains("a"), .T = S },
        .strong_password => .{ .rule = v.strongPassword(.{}), .T = S },
        .number_string => .{ .rule = v.numberString, .T = S },
        .decimal => .{ .rule = v.decimal(.{}), .T = S },
        .boolean_string => .{ .rule = v.booleanString, .T = S },
        .hexadecimal => .{ .rule = v.hexadecimal, .T = S },
        .octal => .{ .rule = v.octal, .T = S },
        .port => .{ .rule = v.port, .T = S },
        .latitude => .{ .rule = v.latitude, .T = S },
        .longitude => .{ .rule = v.longitude, .T = S },
        .lat_long => .{ .rule = v.latLong, .T = S },
        .email => .{ .rule = v.email, .T = S },
        .http_url => .{ .rule = v.httpUrl, .T = S },
        .fqdn => .{ .rule = v.fqdn(.{}), .T = S },
        .ip => .{ .rule = v.ip, .T = S },
        .ipv4 => .{ .rule = v.ipv4, .T = S },
        .ipv6 => .{ .rule = v.ipv6, .T = S },
        .mac_address => .{ .rule = v.macAddress(.{}), .T = S },
        .json => .{ .rule = v.json, .T = S },
        .jwt => .{ .rule = v.jwt, .T = S },
        .base32 => .{ .rule = v.base32, .T = S },
        .base58 => .{ .rule = v.base58, .T = S },
        .base64 => .{ .rule = v.base64, .T = S },
        .base64_url => .{ .rule = v.base64Url, .T = S },
        .data_uri => .{ .rule = v.dataUri, .T = S },
        .magnet_uri => .{ .rule = v.magnetUri, .T = S },
        .mime_type => .{ .rule = v.mimeType, .T = S },
        .locale => .{ .rule = v.locale, .T = S },
        .sem_ver => .{ .rule = v.semVer, .T = S },
        .hex_color => .{ .rule = v.hexColor, .T = S },
        .rgb_color => .{ .rule = v.rgbColor, .T = S },
        .hsl_color => .{ .rule = v.hslColor, .T = S },
        .uuid => .{ .rule = v.uuid, .T = S },
        .mongo_id => .{ .rule = v.mongoId, .T = S },
        .firebase_push_id => .{ .rule = v.firebasePushId, .T = S },
        .hash => .{ .rule = v.hash(.sha256), .T = S },
        .credit_card => .{ .rule = v.creditCard, .T = S },
        .isbn => .{ .rule = v.isbn, .T = S },
        .isbn10 => .{ .rule = v.isbn10, .T = S },
        .isbn13 => .{ .rule = v.isbn13, .T = S },
        .issn => .{ .rule = v.issn, .T = S },
        .ean => .{ .rule = v.ean, .T = S },
        .isin => .{ .rule = v.isin, .T = S },
        .isrc => .{ .rule = v.isrc, .T = S },
        .bic => .{ .rule = v.bic, .T = S },
        .iban => .{ .rule = v.iban, .T = S },
        .btc_address => .{ .rule = v.btcAddress(.mainnet), .T = S },
        .ethereum_address => .{ .rule = v.ethereumAddress, .T = S },
        .date => .{ .rule = v.date, .T = S },
        .rfc3339 => .{ .rule = v.rfc3339, .T = S },
        .iso8601 => .{ .rule = v.iso8601, .T = S },
        .min_date => .{ .rule = v.minDate("2020-01-01"), .T = S },
        .max_date => .{ .rule = v.maxDate("2020-01-01"), .T = S },
        .military_time => .{ .rule = v.militaryTime, .T = S },
        .min_items => .{ .rule = v.minItems(1), .T = []const u32 },
        .max_items => .{ .rule = v.maxItems(1), .T = []const u32 },
        .unique_items => .{ .rule = v.uniqueItems, .T = []const bool },
        .unique_by => .{ .rule = v.uniqueBy(.id), .T = []const Keyed },
        .contains_all => .{ .rule = v.containsAll(.{1}), .T = []const u32 },
        .contains_none => .{ .rule = v.containsNone(.{1}), .T = []const u32 },
        .each => .{ .rule = v.each(v.notEmpty), .T = []const S },
        .custom => .{ .rule = v.custom("users.ok", "must be ok", isOk), .T = u32 },
    };
}

fn isOk(_: u32) bool {
    return true;
}

/// The census over every kind: how many are exact, and which are
/// approximate and which have no keyword, in the order of `core.kinds`;
/// and every keyword of every sample, for the checks of their texts.
fn census() struct { exact: usize, approximate: []const u8, none: []const u8, keywords: []const RuleSchema.Keyword } {
    comptime {
        @setEvalBranchQuota(core.eval_quota);
        var exact_count: usize = 0;
        var approximate_names: []const u8 = "";
        var none_names: []const u8 = "";
        var keywords: []const RuleSchema.Keyword = &.{};
        for (core.kinds) |row| {
            const s = sample(row.kind);
            const schema = schemaOf(s.rule, s.T);
            switch (schema.accuracy) {
                .exact => exact_count += 1,
                .approximate => approximate_names = approximate_names ++ " " ++ row.name,
                .none => none_names = none_names ++ " " ++ row.name,
            }
            keywords = keywords ++ schema.keywords;
            for (schema.items) |item| keywords = keywords ++ item.keywords;
        }
        return .{ .exact = exact_count, .approximate = approximate_names, .none = none_names, .keywords = keywords };
    }
}

test "the census over the kinds: 66 exact, 26 approximate, 4 without a keyword" {
    const c = comptime census();
    try testing.expectEqual(66, c.exact);
    try testing.expectEqualStrings(" minBytes maxBytes email httpUrl ip ipv6 json jwt dataUri magnetUri mimeType locale rgbColor hslColor" ++
        " creditCard isbn isbn10 isbn13 issn ean isin iban btcAddress ethereumAddress rfc3339 iso8601", c.approximate);
    try testing.expectEqualStrings(" minDate maxDate uniqueBy custom", c.none);
}

test "every keyword is standard and its value is JSON text" {
    const c = comptime census();
    for (c.keywords) |k| {
        try testing.expect(!std.mem.startsWith(u8, k.name, "x-"));
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, k.value, .{});
        parsed.deinit();
    }
}
