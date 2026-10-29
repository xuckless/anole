// Copied from vkiryakov/zefir src/validator/core.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The core that the rule files and the walker share: limits, violations,
//! rule kinds, the `Rule` type and the compile-time helpers that check
//! declarations. Only what `root.zig` re-exports is public API.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");

/// Rule constructors, declaration checks and walker functions share one
/// comptime branch counter per declaration, so the library raises the quota
/// itself: a DTO with many fields or rules never stops a build with
/// `evaluation exceeded 1000 backwards branches`.
pub const eval_quota = 10_000_000;

/// Longest code of `v.custom`, `v.fail` and a `validateSelf` result, in bytes.
pub const max_code_bytes = 128;
/// Longest message, in bytes (not code points).
pub const max_message_bytes = 512;
/// Most violations `checkAll` keeps; `Report.truncated` says when more existed.
pub const max_report_violations = 100;
/// Longest list whose uniqueness `uniqueItems` and `uniqueBy` check by
/// sorting on the stack: integer, string and non-exhaustive enum items or
/// keys need an earlier `maxItems(n)` with `n` at most this on a slice, and
/// `N` at most this on `[N]T`.
pub const max_unique_items = 1000;
/// Deepest nesting of `[` and `{` that `v.json` and `v.isJson` accept, the
/// top level included (`[]` is 1); a deeper document fails.
pub const max_json_depth = 64;

/// One failed rule. The library builds `code` and `message` at compile time:
/// they live as long as the program and never contain the checked value, so
/// a violation can be logged or sent to a client as it is. A hand-built
/// `validateSelf` result must use static strings too (literals or comptime
/// values); `v.fail` guarantees them.
pub const Violation = struct {
    /// `validation.<kind>` for a built-in rule (`validation.not_empty`), a
    /// precondition's code (`validation.finite`), `validation.invalid` for a
    /// malformed `validateSelf` result outside Debug builds, or the `code`
    /// argument of `v.custom` and `v.fail`.
    code: []const u8,
    /// What the value must be, without the field name: a built-in English
    /// message such as `must not be empty`, or the message given to
    /// `v.custom` or `v.fail`. Always 1-512 bytes of valid UTF-8.
    message: []const u8,
    /// The path of the value from the root, with each field under its
    /// outside name (`v.rename`, else its Zig name): `email`,
    /// `address.city`, `items[2].displayName`, `[1].email`. Null means the
    /// root value itself or, for `check` only, a path that did not fit
    /// `path_buf`. In the result of `v.fail` or a hand-built `validateSelf`
    /// result, it is the Zig name of a field of that struct instead, which
    /// the walk turns into the field's path.
    field: ?[]const u8 = null,
};

// ------------------------------------------------------------------ kinds

/// Every rule of the validator, 96 kinds, declared once: shipping a rule adds
/// its constructor, never a kind. The tag is the snake_case name used in
/// codes (`validation.<kind>`) and in compile errors.
pub const Kind = enum {
    // common
    equals,
    not_equals,
    one_of,
    none_of,
    empty,
    not_empty,
    // numbers
    min,
    max,
    range,
    positive,
    non_negative,
    negative,
    non_positive,
    divisible_by,
    finite,
    // strings
    min_length,
    max_length,
    length,
    min_bytes,
    max_bytes,
    utf8,
    not_blank,
    ascii,
    printable_ascii,
    alphanumeric,
    alpha,
    digits,
    lowercase,
    uppercase,
    multibyte,
    full_width,
    half_width,
    variable_width,
    contains,
    not_contains,
    strong_password,
    // formats: numbers in strings, network
    number_string,
    decimal,
    boolean_string,
    hexadecimal,
    octal,
    port,
    latitude,
    longitude,
    lat_long,
    email,
    http_url,
    fqdn,
    ip,
    ipv4,
    ipv6,
    mac_address,
    // formats: encodings and other formats
    json,
    jwt,
    base32,
    base58,
    base64,
    base64_url,
    data_uri,
    magnet_uri,
    mime_type,
    locale,
    sem_ver,
    hex_color,
    rgb_color,
    hsl_color,
    // identifiers
    uuid,
    mongo_id,
    firebase_push_id,
    hash,
    credit_card,
    isbn,
    isbn10,
    isbn13,
    issn,
    ean,
    isin,
    isrc,
    bic,
    iban,
    btc_address,
    ethereum_address,
    // dates
    date,
    rfc3339,
    iso8601,
    min_date,
    max_date,
    military_time,
    // lists
    min_items,
    max_items,
    unique_items,
    unique_by,
    contains_all,
    contains_none,
    each,
    // custom
    custom,
};

/// A kind and the name of its rule.
pub const KindInfo = struct {
    kind: Kind,
    /// The public name in the `validator` namespace: `notEmpty` for `v.notEmpty`.
    name: []const u8,
};

fn k(kind: Kind, name: []const u8) KindInfo {
    return .{ .kind = kind, .name = name };
}

/// One row per `Kind`, in declaration order (checked below).
pub const kinds = [_]KindInfo{
    k(.equals, "equals"),
    k(.not_equals, "notEquals"),
    k(.one_of, "oneOf"),
    k(.none_of, "noneOf"),
    k(.empty, "empty"),
    k(.not_empty, "notEmpty"),
    k(.min, "min"),
    k(.max, "max"),
    k(.range, "range"),
    k(.positive, "positive"),
    k(.non_negative, "nonNegative"),
    k(.negative, "negative"),
    k(.non_positive, "nonPositive"),
    k(.divisible_by, "divisibleBy"),
    k(.finite, "finite"),
    k(.min_length, "minLength"),
    k(.max_length, "maxLength"),
    k(.length, "length"),
    k(.min_bytes, "minBytes"),
    k(.max_bytes, "maxBytes"),
    k(.utf8, "utf8"),
    k(.not_blank, "notBlank"),
    k(.ascii, "ascii"),
    k(.printable_ascii, "printableAscii"),
    k(.alphanumeric, "alphanumeric"),
    k(.alpha, "alpha"),
    k(.digits, "digits"),
    k(.lowercase, "lowercase"),
    k(.uppercase, "uppercase"),
    k(.multibyte, "multibyte"),
    k(.full_width, "fullWidth"),
    k(.half_width, "halfWidth"),
    k(.variable_width, "variableWidth"),
    k(.contains, "contains"),
    k(.not_contains, "notContains"),
    k(.strong_password, "strongPassword"),
    k(.number_string, "numberString"),
    k(.decimal, "decimal"),
    k(.boolean_string, "booleanString"),
    k(.hexadecimal, "hexadecimal"),
    k(.octal, "octal"),
    k(.port, "port"),
    k(.latitude, "latitude"),
    k(.longitude, "longitude"),
    k(.lat_long, "latLong"),
    k(.email, "email"),
    k(.http_url, "httpUrl"),
    k(.fqdn, "fqdn"),
    k(.ip, "ip"),
    k(.ipv4, "ipv4"),
    k(.ipv6, "ipv6"),
    k(.mac_address, "macAddress"),
    k(.json, "json"),
    k(.jwt, "jwt"),
    k(.base32, "base32"),
    k(.base58, "base58"),
    k(.base64, "base64"),
    k(.base64_url, "base64Url"),
    k(.data_uri, "dataUri"),
    k(.magnet_uri, "magnetUri"),
    k(.mime_type, "mimeType"),
    k(.locale, "locale"),
    k(.sem_ver, "semVer"),
    k(.hex_color, "hexColor"),
    k(.rgb_color, "rgbColor"),
    k(.hsl_color, "hslColor"),
    k(.uuid, "uuid"),
    k(.mongo_id, "mongoId"),
    k(.firebase_push_id, "firebasePushId"),
    k(.hash, "hash"),
    k(.credit_card, "creditCard"),
    k(.isbn, "isbn"),
    k(.isbn10, "isbn10"),
    k(.isbn13, "isbn13"),
    k(.issn, "issn"),
    k(.ean, "ean"),
    k(.isin, "isin"),
    k(.isrc, "isrc"),
    k(.bic, "bic"),
    k(.iban, "iban"),
    k(.btc_address, "btcAddress"),
    k(.ethereum_address, "ethereumAddress"),
    k(.date, "date"),
    k(.rfc3339, "rfc3339"),
    k(.iso8601, "iso8601"),
    k(.min_date, "minDate"),
    k(.max_date, "maxDate"),
    k(.military_time, "militaryTime"),
    k(.min_items, "minItems"),
    k(.max_items, "maxItems"),
    k(.unique_items, "uniqueItems"),
    k(.unique_by, "uniqueBy"),
    k(.contains_all, "containsAll"),
    k(.contains_none, "containsNone"),
    k(.each, "each"),
    k(.custom, "custom"),
};

// The table matches `Kind`: one row per tag, in tag order, named by the tag
// in camelCase. A mismatch stops every build of the module.
comptime {
    @setEvalBranchQuota(eval_quota);
    if (kinds.len != @typeInfo(Kind).@"enum".field_names.len) @compileError("validator: internal: the kind table must list every Kind once");
    for (kinds, 0..) |row, i| {
        if (@backingInt(row.kind) != i) @compileError("validator: internal: kind table row " ++ row.name ++ " is out of order");
        if (!std.mem.eql(u8, snakeCase(row.name), @tagName(row.kind)))
            @compileError("validator: internal: kind " ++ @tagName(row.kind) ++ " does not match the public name " ++ row.name);
    }
}

/// The table row of `kind`.
pub fn info(comptime kind: Kind) KindInfo {
    return kinds[@backingInt(kind)];
}

/// `notEmpty` -> `not_empty`, `base64Url` -> `base64_url`, `isbn10` -> `isbn10`.
pub inline fn snakeCase(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (name) |c| out = out ++ if (std.ascii.isUpper(c)) "_" ++ [1]u8{std.ascii.toLower(c)} else [1]u8{c};
        return out;
    }
}

/// The code of a built-in rule: `validation.<kind>`, except `uniqueBy`,
/// which shares `validation.unique_items` with `uniqueItems`. `each` reports
/// through its inner rules and `custom` through the user's code.
pub fn codeOf(comptime kind: Kind) []const u8 {
    return switch (kind) {
        .unique_by => "validation.unique_items",
        .each, .custom => @compileError("validator: internal: " ++ @tagName(kind) ++ " has no code of its own"),
        else => "validation." ++ @tagName(kind),
    };
}

// ------------------------------------------------------------------ custom codes

/// Why a `v.custom` or `v.fail` code is not valid.
pub const CodeProblem = enum { too_long, empty_segment, bad_start, bad_char, one_segment, reserved };

/// Why `code` is not a valid custom code, or null. A valid code is segments
/// of `[a-z][a-z0-9_]*` joined by `.`: at least 2 segments, at most 128
/// bytes, not starting with `validation.` (the built-in rules) or `rpc.`
/// (zefir-rpc). The length is checked first. Usable at run time:
/// `validateSelf` results are checked with it.
pub fn codeProblem(code: []const u8) ?CodeProblem {
    if (code.len > max_code_bytes) return .too_long;
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, code, '.');
    while (it.next()) |segment| : (segments += 1) {
        if (segment.len == 0) return .empty_segment;
        for (segment, 0..) |c, i| switch (c) {
            'a'...'z' => {},
            '0'...'9', '_' => if (i == 0) return .bad_start,
            else => return .bad_char,
        };
    }
    if (segments < 2) return .one_segment;
    if (std.mem.startsWith(u8, code, "validation.") or std.mem.startsWith(u8, code, "rpc.")) return .reserved;
    return null;
}

const code_grammar = "use segments of [a-z][a-z0-9_]* joined by '.', e.g. 'users.name_taken'";

/// The error text for a code with `problem`; the code is shown escaped.
pub inline fn describeCodeProblem(comptime code: []const u8, comptime problem: CodeProblem) []const u8 {
    comptime {
        const head = "code '" ++ escape(code) ++ "' ";
        return head ++ switch (problem) {
            .too_long => std.fmt.comptimePrint("is longer than {d} bytes", .{max_code_bytes}),
            .empty_segment => "has an empty segment; " ++ code_grammar,
            .bad_start => "has a segment that does not start with a letter; " ++ code_grammar,
            .bad_char => "has a character outside [a-z0-9_.]; " ++ code_grammar,
            .one_segment => "needs at least 2 segments, e.g. 'users.name_taken'",
            .reserved => "uses a reserved prefix (validation., rpc.)",
        };
    }
}

/// Stops compilation with `validator: <where>: code '<code>' ...` when
/// `code` is not a valid custom code. `where` is the call: `custom("<code>", ...)`
/// or `fail(<Type>, .<field>)`.
pub fn checkCode(comptime where: []const u8, comptime code: []const u8) void {
    comptime {
        @setEvalBranchQuota(eval_quota);
        if (codeProblem(code)) |problem| @compileError("validator: " ++ where ++ ": " ++ describeCodeProblem(code, problem));
    }
}

// ------------------------------------------------------------------ messages

/// Why a message cannot be used.
pub const MessageProblem = enum { empty, too_long, invalid_utf8 };

/// Why `message` is not 1-512 bytes of valid UTF-8, or null. Bytes are
/// counted, not code points. Usable at run time.
pub fn messageProblem(message: []const u8) ?MessageProblem {
    if (message.len == 0) return .empty;
    if (message.len > max_message_bytes) return .too_long;
    if (!std.unicode.utf8ValidateSlice(message)) return .invalid_utf8;
    return null;
}

/// The error text for a message with `problem`.
pub fn describeMessageProblem(comptime problem: MessageProblem) []const u8 {
    return switch (problem) {
        .empty => "message must not be empty",
        .too_long => std.fmt.comptimePrint("message is longer than {d} bytes", .{max_message_bytes}),
        .invalid_utf8 => "message must be valid UTF-8",
    };
}

/// Stops compilation with `validator: <where>: message ...` when a
/// `v.custom` or `v.fail` message is not 1-512 bytes of valid UTF-8.
pub fn checkMessage(comptime where: []const u8, comptime message: []const u8) void {
    comptime {
        @setEvalBranchQuota(eval_quota);
        if (messageProblem(message)) |problem| @compileError("validator: " ++ where ++ ": " ++ describeMessageProblem(problem));
    }
}

/// `s` as it is written inside a Zig string literal (`std.zig.fmtString`):
/// `\n \r \t \\ "` are escaped; control bytes, invalid UTF-8, U+0085,
/// U+2028, U+2029 and U+FEFF are hex-encoded. Compile errors show codes
/// and arguments this way, so every text stays on one readable line.
pub inline fn escape(comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(eval_quota);
        return std.fmt.comptimePrint("{f}", .{std.zig.fmtString(s)});
    }
}

test "a public name in snake_case is the tag of its kind" {
    try std.testing.expectEqualStrings("not_empty", comptime snakeCase("notEmpty"));
    try std.testing.expectEqualStrings("base64_url", comptime snakeCase("base64Url"));
    try std.testing.expectEqualStrings("firebase_push_id", comptime snakeCase("firebasePushId"));
    try std.testing.expectEqualStrings("isbn13", comptime snakeCase("isbn13"));
}

test "a built-in rule's code is validation.<kind>, and uniqueBy shares uniqueItems' code" {
    try std.testing.expectEqualStrings("validation.not_empty", comptime codeOf(.not_empty));
    try std.testing.expectEqualStrings("validation.positive", comptime codeOf(.positive));
    try std.testing.expectEqualStrings("validation.unique_items", comptime codeOf(.unique_by));
}

test "a custom code is two or more lowercase segments without a reserved prefix" {
    try std.testing.expectEqual(null, codeProblem("users.name_taken"));
    try std.testing.expectEqual(null, codeProblem("a.b1_"));
    try std.testing.expectEqual(null, codeProblem("validationx.y"));
    try std.testing.expectEqual(null, codeProblem("rpcx.y"));
    try std.testing.expectEqual(CodeProblem.one_segment, codeProblem("users").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("a..b").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem(".a.b").?);
    try std.testing.expectEqual(CodeProblem.empty_segment, codeProblem("a.b.").?);
    try std.testing.expectEqual(CodeProblem.bad_start, codeProblem("a.1b").?);
    try std.testing.expectEqual(CodeProblem.bad_start, codeProblem("_a.b").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.B").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.b-c").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.b c").?);
    try std.testing.expectEqual(CodeProblem.bad_char, codeProblem("a.\u{e9}").?);
    try std.testing.expectEqual(CodeProblem.reserved, codeProblem("validation.x").?);
    try std.testing.expectEqual(CodeProblem.reserved, codeProblem("rpc.x").?);
    // The length is checked first, in bytes: 128 fit, 129 do not.
    try std.testing.expectEqual(null, codeProblem("a." ++ @as([126]u8, @splat('b'))));
    try std.testing.expectEqual(CodeProblem.too_long, codeProblem("a." ++ @as([127]u8, @splat('b'))).?);
    try std.testing.expectEqual(CodeProblem.too_long, codeProblem("A" ++ @as([128]u8, @splat('.'))).?);
}

test "a message is 1-512 bytes of valid UTF-8, counted in bytes" {
    try std.testing.expectEqual(MessageProblem.empty, messageProblem("").?);
    try std.testing.expectEqual(null, messageProblem("must be ok"));
    try std.testing.expectEqual(null, messageProblem(&@as([512]u8, @splat('m'))));
    try std.testing.expectEqual(MessageProblem.too_long, messageProblem(&@as([513]u8, @splat('m'))).?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("\xff").?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("\xc3").?);
    try std.testing.expectEqual(MessageProblem.invalid_utf8, messageProblem("caf\xc3").?);
    // "€" is 3 bytes: 509 bytes plus "€" fit, 510 bytes plus "€" do not.
    const filler: [509]u8 = @splat('m');
    try std.testing.expectEqual(null, messageProblem(filler ++ "\u{20ac}"));
    try std.testing.expectEqual(MessageProblem.too_long, messageProblem(filler ++ "m\u{20ac}").?);
    // Empty, then length, then UTF-8: 513 bytes of invalid UTF-8 are too long.
    try std.testing.expectEqual(MessageProblem.too_long, messageProblem(&@as([513]u8, @splat(0xff))).?);
}

test "code and message problems are described with the texts of the custom and fail errors" {
    const expect = std.testing.expectEqualStrings;
    const grammar = "; use segments of [a-z][a-z0-9_]* joined by '.', e.g. 'users.name_taken'";
    const long_code = "a." ++ @as([127]u8, @splat('b'));
    try expect("code '" ++ long_code ++ "' is longer than 128 bytes", comptime describeCodeProblem(long_code, .too_long));
    try expect("code 'users..taken' has an empty segment" ++ grammar, comptime describeCodeProblem("users..taken", .empty_segment));
    try expect("code 'users.Taken' has a character outside [a-z0-9_.]" ++ grammar, comptime describeCodeProblem("users.Taken", .bad_char));
    try expect("code 'users.1st' has a segment that does not start with a letter" ++ grammar, comptime describeCodeProblem("users.1st", .bad_start));
    try expect("code 'taken' needs at least 2 segments, e.g. 'users.name_taken'", comptime describeCodeProblem("taken", .one_segment));
    try expect("code 'validation.mine' uses a reserved prefix (validation., rpc.)", comptime describeCodeProblem("validation.mine", .reserved));
    // The code is escaped, so a control byte or invalid UTF-8 stays readable.
    try expect("code 'users.\\x00\\xff' has a character outside [a-z0-9_.]" ++ grammar, comptime describeCodeProblem("users.\x00\xff", .bad_char));
    try expect("message must not be empty", comptime describeMessageProblem(.empty));
    try expect("message is longer than 512 bytes", comptime describeMessageProblem(.too_long));
    try expect("message must be valid UTF-8", comptime describeMessageProblem(.invalid_utf8));
}

test "a valid code and message pass the compile-time checks" {
    comptime checkCode("custom(\"users.name_taken\", ...)", "users.name_taken");
    comptime checkMessage("custom(\"users.name_taken\", ...)", "is taken");
    comptime checkCode("custom(\"a.b\", ...)", "a." ++ @as([126]u8, @splat('b')));
    comptime checkMessage("custom(\"a.b\", ...)", &@as([512]u8, @splat('m')));
}

test "escape writes strings as Zig string literals do" {
    const expect = std.testing.expectEqualStrings;
    try expect("a\\\"b\\n\\x01\\xe2\\x80\\xa8\\xff", comptime escape("a\"b\n\x01\u{2028}\xff"));
    try expect("users.name_taken", comptime escape("users.name_taken"));
    try expect("caf\u{e9}", comptime escape("caf\u{e9}"));
}

test "the code, message and name helpers can be called outside a comptime block" {
    try std.testing.expectEqualStrings("not_empty", snakeCase("notEmpty"));
    try std.testing.expectEqualStrings("a\\nb", escape("a\nb"));
    try std.testing.expectEqualStrings("code 'taken' needs at least 2 segments, e.g. 'users.name_taken'", describeCodeProblem("taken", .one_segment));
    checkCode("custom(\"users.ok\", ...)", "users.ok");
    checkMessage("custom(\"users.ok\", ...)", "must be ok");
}

// ------------------------------------------------------------------ rendering

/// How the renderer and the rules with parameters treat a comptime value.
pub const ValueKind = enum { int, float, bool, tag, string, list, other };

/// The kind of a parameter of type `X`. A string is a slice of u8 (of any
/// constness and sentinel) or a pointer to an array of u8, as string
/// literals are. A list is a tuple or an array `[N]T` only (`[N]u8`
/// included: an array of numbers); a pointer to an array and a slice of
/// other items are `other`, so a list rule can reject them.
pub fn valueKind(comptime X: type) ValueKind {
    return switch (@typeInfo(X)) {
        .comptime_int, .int => .int,
        .comptime_float, .float => .float,
        .bool => .bool,
        .enum_literal, .@"enum" => .tag,
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .string else .other,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) .string else .other,
                else => .other,
            },
            else => .other,
        },
        .array => .list,
        .@"struct" => |s| if (s.is_tuple) .list else .other,
        else => .other,
    };
}

/// `x` is not a float NaN or infinity. `std.math.isFinite` does not take a
/// `comptime_float`, which holds an f128.
pub fn isFiniteNumber(comptime x: anytype) bool {
    return switch (@typeInfo(@TypeOf(x))) {
        .comptime_float => std.math.isFinite(@as(f128, x)),
        .float => std.math.isFinite(x),
        else => true,
    };
}

/// A parameter as messages and placeholders show it: integers in decimal;
/// floats as written (`renderFloat`); `true`/`false`; an enum tag by its
/// name, escaped as strings are (`@"a\nb"` shows as `a\nb`), an unnamed
/// value of a non-exhaustive enum as `@fromBackingInt(n)`; a string escaped
/// as `escape` does, without quotes, and the empty string as `""`; a list
/// as its items joined by `, `, never cut. Evaluate it at comptime; it
/// accepts only the kinds above.
pub fn renderValue(comptime x: anytype) []const u8 {
    @setEvalBranchQuota(eval_quota);
    return switch (comptime valueKind(@TypeOf(x))) {
        .int => std.fmt.comptimePrint("{d}", .{x}),
        .float => renderFloat(x),
        .bool => if (x) "true" else "false",
        .tag => if (tagName(x)) |name| escape(name) else unnamedTag(x),
        .string => if (x.len == 0) "\"\"" else escape(x),
        .list => blk: {
            var out: []const u8 = "";
            for (0..x.len) |i| out = out ++ (if (i == 0) "" else ", ") ++ renderValue(x[i]);
            break :blk out;
        },
        .other => @compileError("validator: internal: cannot render a value of type " ++ @typeName(@TypeOf(x))),
    };
}

/// A float as written: the shortest text that gives the value back in its
/// own type (a `comptime_float` is an f128), so `0.1` stays `0.1` whatever
/// the field type. Decimal when 1e-6 <= |x| < 1e21, scientific (`1e-7`,
/// `1e21`) otherwise, both bounds taken in the value's own type; `0` for
/// both zeros; `nan`, `inf` and `-inf` for the values only compile errors
/// show.
fn renderFloat(comptime x: anytype) []const u8 {
    const F = if (@TypeOf(x) == comptime_float) f128 else @TypeOf(x);
    const f: F = x;
    if (std.math.isNan(f)) return "nan";
    if (std.math.isInf(f)) return if (f > 0) "inf" else "-inf";
    if (f == 0) return "0";
    const magnitude = @abs(f);
    // f16 cannot hold 1e21: every finite f16 is below it.
    const below_1e21 = std.math.floatMax(F) < 1e21 or magnitude < @as(F, 1e21);
    return if (magnitude >= @as(F, 1e-6) and below_1e21)
        std.fmt.comptimePrint("{d}", .{f})
    else
        std.fmt.comptimePrint("{e}", .{f});
}

/// The name of an enum literal or enum value, or null for an unnamed value
/// of a non-exhaustive enum.
pub fn tagName(comptime x: anytype) ?[]const u8 {
    const X = @TypeOf(x);
    if (@typeInfo(X) == .enum_literal) return @tagName(x);
    const e = @typeInfo(X).@"enum";
    for (e.field_names, e.field_values) |field_name, value| {
        if (value == @backingInt(x)) return field_name;
    }
    return null;
}

/// An unnamed value of a non-exhaustive enum as Zig source writes it:
/// `@fromBackingInt(7)`.
fn unnamedTag(comptime x: anytype) []const u8 {
    return std.fmt.comptimePrint("@fromBackingInt({d})", .{@backingInt(x)});
}

/// A tag name as `zig fmt` writes it after a dot, for compile errors:
/// `admin`, `@"error"` for a keyword, `@"a\nb"` for a name that is no
/// identifier.
pub inline fn tagIdentifier(comptime name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(eval_quota);
        return std.fmt.comptimePrint("{f}", .{std.zig.fmtIdPU(name)});
    }
}

/// Compile errors show the items of a list argument while `.{ ` and the
/// items so far fit in this many bytes.
const max_args_text = 72;

/// A parameter as compile errors show it in a call, as `zig fmt` writes it
/// in source: numbers and bools as messages show them; `.admin` for a tag
/// (`.@"error"` for a keyword, as `tagIdentifier` writes names) and
/// `@fromBackingInt(n)` for an unnamed value; a string quoted and
/// escaped; a list as `.{ "a", "b" }`, one item as `.{"a"}`, none as `.{}`;
/// anything else (`null`, a struct, a pointer, a slice of other items) as
/// `...`. A long list keeps its items while `.{ ` and the items so far fit
/// in `max_args_text` bytes (the first item always) and ends with
/// `, ... }` after the last one that fits. Evaluate it at comptime.
pub fn renderArg(comptime x: anytype) []const u8 {
    @setEvalBranchQuota(eval_quota);
    return switch (comptime valueKind(@TypeOf(x))) {
        .int, .float, .bool => renderValue(x),
        .tag => if (tagName(x)) |name| "." ++ tagIdentifier(name) else unnamedTag(x),
        .string => "\"" ++ escape(x) ++ "\"",
        .list => renderArgList(x),
        .other => "...",
    };
}

fn renderArgList(comptime x: anytype) []const u8 {
    if (x.len == 0) return ".{}";
    if (x.len == 1) return ".{" ++ renderArg(x[0]) ++ "}";
    var out: []const u8 = ".{ " ++ renderArg(x[0]);
    for (1..x.len) |i| {
        const longer = out ++ ", " ++ renderArg(x[i]);
        if (longer.len > max_args_text) return out ++ ", ... }";
        out = longer;
    }
    return out ++ " }";
}

/// `n` and the noun for it: `1 item`, `2 items`, `0 items`.
pub fn plural(comptime n: comptime_int, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return std.fmt.comptimePrint("{d} ", .{n}) ++ if (n == 1) one else many;
}

/// A non-exhaustive enum for the renderer tests: `@fromBackingInt(7)` is a
/// value without a name.
const TestOpen = enum(u8) { a, b, _ };

/// An enum whose tags Zig source writes with `@"..."`: a keyword and a name
/// with a newline.
const TestQuoted = enum { @"error", @"a\nb", plain };

test "a parameter is a number, a bool, a tag, a string or a list; lists are tuples and arrays only" {
    const expectKind = struct {
        fn expectKind(expected: ValueKind, comptime types: anytype) !void {
            inline for (types) |T| {
                std.testing.expectEqual(expected, comptime valueKind(T)) catch |err| {
                    std.debug.print("valueKind({s})\n", .{@typeName(T)});
                    return err;
                };
            }
        }
    }.expectKind;
    try expectKind(.int, .{ comptime_int, u8, i128, usize, u0 });
    try expectKind(.float, .{ comptime_float, f16, f32, f64, f80, f128, c_longdouble });
    try expectKind(.bool, .{bool});
    try expectKind(.tag, .{ @TypeOf(.admin), TestOpen, Kind });
    // A string literal is a pointer to an array of u8; a u8 slice of any
    // constness and sentinel is a string too.
    try expectKind(.string, .{ *const [3:0]u8, *const [3]u8, *const [0:0]u8, []const u8, []u8, [:0]const u8 });
    // [N]u8 is an array of numbers, as on a field.
    try expectKind(.list, .{ @TypeOf(.{}), @TypeOf(.{ 1, 2 }), @TypeOf(.{"a"}), [2]u8, [3]i64, [2][]const u8, [0]u32 });
    // A pointer to an array, a slice of other items and anything else is no
    // list: the list rules reject them.
    try expectKind(.other, .{ *const [2]u32, []const u32, []const []const u8, *const @TypeOf(.{ 1, 2 }), @TypeOf(null), ?u8, void, type, struct { x: u8 }, [*]const u8 });
}

test "a number parameter is finite unless it is a float NaN or infinity" {
    try std.testing.expect(comptime isFiniteNumber(5));
    try std.testing.expect(comptime isFiniteNumber(std.math.maxInt(u128)));
    try std.testing.expect(comptime isFiniteNumber(1.5));
    try std.testing.expect(comptime isFiniteNumber(-0.0));
    try std.testing.expect(comptime isFiniteNumber(std.math.floatMax(f80)));
    try std.testing.expect(comptime isFiniteNumber(std.math.floatTrueMin(f16)));
    // A comptime_float is checked as an f128, so a literal beyond f64 is finite.
    try std.testing.expect(comptime isFiniteNumber(1e400));
    try std.testing.expect(!comptime isFiniteNumber(std.math.nan(f64)));
    try std.testing.expect(!comptime isFiniteNumber(std.math.inf(f32)));
    try std.testing.expect(!comptime isFiniteNumber(-std.math.inf(f128)));
    try std.testing.expect(!comptime isFiniteNumber(-std.math.inf(c_longdouble)));
    try std.testing.expect(!comptime isFiniteNumber(@as(comptime_float, std.math.inf(f64))));
}

test "messages show integers of every width in decimal" {
    const expect = std.testing.expectEqualStrings;
    try expect("5", comptime renderValue(5));
    try expect("0", comptime renderValue(@as(u8, 0)));
    try expect("255", comptime renderValue(@as(u8, std.math.maxInt(u8))));
    try expect("-128", comptime renderValue(@as(i8, std.math.minInt(i8))));
    try expect("18446744073709551615", comptime renderValue(@as(u64, std.math.maxInt(u64))));
    try expect("-9223372036854775808", comptime renderValue(@as(i64, std.math.minInt(i64))));
    try expect("340282366920938463463374607431768211455", comptime renderValue(@as(u128, std.math.maxInt(u128))));
    try expect("-170141183460469231731687303715884105728", comptime renderValue(@as(i128, std.math.minInt(i128))));
    try expect("42", comptime renderValue(@as(usize, 42)));
    try expect("-1", comptime renderValue(-1));
}

test "messages show floats as written: decimal from 1e-6 to below 1e21, scientific outside, 0 for both zeros" {
    const expect = std.testing.expectEqualStrings;
    try expect("0.5", comptime renderValue(0.5));
    try expect("0.1", comptime renderValue(0.1));
    try expect("2", comptime renderValue(2.0));
    try expect("-1.5", comptime renderValue(-1.5));
    try expect("0.000001", comptime renderValue(1e-6));
    try expect("-0.000001", comptime renderValue(-1e-6));
    try expect("9.99e-7", comptime renderValue(9.99e-7));
    try expect("100000000000000000000", comptime renderValue(1e20));
    try expect("1e21", comptime renderValue(1e21));
    try expect("-1e21", comptime renderValue(-1e21));
    try expect("1e-50", comptime renderValue(1e-50));
    try expect("-1.7976931348623157e308", comptime renderValue(-std.math.floatMax(f64)));
    try expect("5e-324", comptime renderValue(std.math.floatTrueMin(f64)));
    // A comptime_float is an f128: a literal beyond the range of f64, a bound
    // for an f80 or f128 field, keeps its value.
    try expect("1e400", comptime renderValue(1e400));
    try expect("1e-400", comptime renderValue(1e-400));
    try expect("0", comptime renderValue(0.0));
    try expect("0", comptime renderValue(-0.0));
    // A typed value shows the shortest text that gives it back in its own
    // type: 0.1 in f32, not 0.10000000149011612.
    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |F| {
        try expect("0.1", comptime renderValue(@as(F, 0.1)));
        try expect("-2.5", comptime renderValue(@as(F, -2.5)));
        try expect("0", comptime renderValue(@as(F, -0.0)));
        // The 1e-6 boundary is taken in the value's own type.
        try expect("0.000001", comptime renderValue(@as(F, 1e-6)));
    }
    try expect("1e-7", comptime renderValue(@as(f32, 1e-7)));
    try expect("1e21", comptime renderValue(@as(f32, 1e21)));
    // The largest f16, 65504, reads back from the shorter 65500.
    try expect("65500", comptime renderValue(std.math.floatMax(f16)));
    // Only compile errors show non-finite numbers: a non-finite bound is
    // itself an error.
    try expect("nan", comptime renderValue(std.math.nan(f64)));
    try expect("inf", comptime renderValue(std.math.inf(f32)));
    try expect("-inf", comptime renderValue(-std.math.inf(f128)));
}

test "messages show bools, tags by name, escaped strings without quotes and lists joined by commas" {
    const expect = std.testing.expectEqualStrings;
    try expect("true", comptime renderValue(true));
    try expect("false", comptime renderValue(false));
    try expect("admin", comptime renderValue(.admin));
    try expect("b", comptime renderValue(TestOpen.b));
    try expect("@fromBackingInt(7)", comptime renderValue(@as(TestOpen, @fromBackingInt(7))));
    try expect("tab\\there", comptime renderValue("tab\there"));
    try expect("say \\\"hi\\\"", comptime renderValue("say \"hi\""));
    try expect("a\\xe2\\x80\\xa8b", comptime renderValue("a\u{2028}b"));
    try expect("имя", comptime renderValue("имя"));
    try expect("\\xff", comptime renderValue("\xff"));
    try expect("\"\"", comptime renderValue(""));
    try expect("abc", comptime renderValue(@as([]const u8, "abc")));
    try expect("abc", comptime renderValue(@as(*const [3]u8, "abc")));
    try expect("a, b, \"\"", comptime renderValue(.{ "a", "b", "" }));
    try expect("x", comptime renderValue(.{"x"}));
    try expect("1, 2", comptime renderValue([_]u8{ 1, 2 }));
    try expect("admin, @fromBackingInt(7)", comptime renderValue(.{ .admin, @as(TestOpen, @fromBackingInt(7)) }));
    // A tag name is escaped as strings are, so a message stays on one line
    // and valid UTF-8.
    try expect("error", comptime renderValue(TestQuoted.@"error"));
    try expect("a\\nb, plain", comptime renderValue(.{ TestQuoted.@"a\nb", .plain }));
    try expect("\\xff", comptime renderValue(.@"\xff"));
    // A message never cuts a list; a default message that would be too long
    // falls back to a general one instead.
    const long = .{ "value_000", "value_001", "value_002", "value_003", "value_004", "value_005", "value_006", "value_007" };
    try expect("value_000, value_001, value_002, value_003, value_004, value_005, value_006, value_007", comptime renderValue(long));
}

test "compile errors show arguments as zig fmt writes them" {
    const expect = std.testing.expectEqualStrings;
    try expect("5", comptime renderArg(5));
    try expect("-170141183460469231731687303715884105728", comptime renderArg(@as(i128, std.math.minInt(i128))));
    try expect("340282366920938463463374607431768211455", comptime renderArg(@as(u128, std.math.maxInt(u128))));
    try expect("0.1", comptime renderArg(@as(f32, 0.1)));
    try expect("2", comptime renderArg(2.0));
    try expect("1e-50", comptime renderArg(1e-50));
    try expect("0", comptime renderArg(-0.0));
    try expect("nan", comptime renderArg(std.math.nan(f64)));
    try expect("inf", comptime renderArg(std.math.inf(f64)));
    try expect("-inf", comptime renderArg(-std.math.inf(f16)));
    try expect("inf", comptime renderArg(@as(comptime_float, std.math.inf(f64))));
    try expect("true", comptime renderArg(true));
    try expect(".admin", comptime renderArg(.admin));
    try expect(".b", comptime renderArg(TestOpen.b));
    try expect("@fromBackingInt(7)", comptime renderArg(@as(TestOpen, @fromBackingInt(7))));
    // A tag that is no plain identifier is quoted as zig fmt writes it.
    try expect(".@\"error\"", comptime renderArg(TestQuoted.@"error"));
    try expect(".@\"a\\nb\"", comptime renderArg(.@"a\nb"));
    try expect(".{ .@\"error\", .plain }", comptime renderArg(.{ .@"error", TestQuoted.plain }));
    try expect(".u8", comptime renderArg(.u8));
    try expect("\"a\\tb\"", comptime renderArg("a\tb"));
    try expect("\"\\\"\"", comptime renderArg("\""));
    try expect("\"\\xe2\\x80\\xa8\"", comptime renderArg("\u{2028}"));
    try expect("\"имя\"", comptime renderArg("имя"));
    try expect("\"\"", comptime renderArg(""));
    try expect("\"abc\"", comptime renderArg(@as([]const u8, "abc")));
    try expect("\"abc\"", comptime renderArg(@as(*const [3]u8, "abc")));
}

test "compile errors show lists as zig fmt writes them, one item without spaces" {
    const expect = std.testing.expectEqualStrings;
    try expect(".{}", comptime renderArg(.{}));
    try expect(".{\"a\"}", comptime renderArg(.{"a"}));
    try expect(".{true}", comptime renderArg(.{true}));
    try expect(".{.admin}", comptime renderArg(.{.admin}));
    try expect(".{@fromBackingInt(7)}", comptime renderArg(.{@as(TestOpen, @fromBackingInt(7))}));
    try expect(".{ \"a\", \"b\" }", comptime renderArg(.{ "a", "b" }));
    try expect(".{ \"a\", .b, 3 }", comptime renderArg(.{ "a", .b, 3 }));
    try expect(".{ .a, @fromBackingInt(7) }", comptime renderArg(.{ .a, @as(TestOpen, @fromBackingInt(7)) }));
    // An array is a list, [N]u8 included.
    try expect(".{ 1, 2 }", comptime renderArg([_]u8{ 1, 2 }));
    try expect(".{5}", comptime renderArg([_]i64{5}));
    try expect(".{ \"x\", \"y\" }", comptime renderArg([_][]const u8{ "x", "y" }));
}

test "compile errors show ... for what the renderer cannot show" {
    const expect = std.testing.expectEqualStrings;
    try expect("...", comptime renderArg(null));
    try expect("...", comptime renderArg(@as(?u8, 5)));
    try expect("...", comptime renderArg(.{ .x = 1 }));
    // A pointer to an array and a slice of non-u8 items are not lists.
    try expect("...", comptime renderArg(&[_]u32{ 1, 2 }));
    try expect("...", comptime renderArg(@as([]const u32, &.{ 1, 2 })));
    try expect(".{...}", comptime renderArg(.{null}));
    try expect(".{ ..., 1 }", comptime renderArg(.{ null, 1 }));
}

test "compile errors show the items of a list while they fit in 72 bytes, then , ... }" {
    const expect = std.testing.expectEqualStrings;
    const ten = .{ "value_000", "value_001", "value_002", "value_003", "value_004", "value_005", "value_006", "value_007", "value_008", "value_009" };
    try expect(".{ \"value_000\", \"value_001\", \"value_002\", \"value_003\", \"value_004\", ... }", comptime renderArg(ten));
    // An item is shown when `.{ ` and the items through it fit in 72 bytes.
    const a30: [30]u8 = @splat('a');
    const b33: [33]u8 = @splat('b');
    const b34: [34]u8 = @splat('b');
    try std.testing.expectEqual(72, (".{ \"" ++ a30 ++ "\", \"" ++ b33 ++ "\"").len);
    try expect(".{ \"" ++ a30 ++ "\", \"" ++ b33 ++ "\" }", comptime renderArg(.{ &a30, &b33 }));
    try expect(".{ \"" ++ a30 ++ "\", ... }", comptime renderArg(.{ &a30, &b34 }));
    // The first item stays even when it is longer than 72 bytes; a list of
    // one item has nothing to cut.
    const a80: [80]u8 = @splat('a');
    try expect(".{ \"" ++ a80 ++ "\", ... }", comptime renderArg(.{ &a80, "b" }));
    try expect(".{\"" ++ a80 ++ "\"}", comptime renderArg(.{&a80}));
    // Integers are cut the same way.
    const ints = .{ 1000000000, 2000000000, 3000000000, 4000000000, 5000000000, 6000000000, 7000000000 };
    try expect(".{ 1000000000, 2000000000, 3000000000, 4000000000, 5000000000, ... }", comptime renderArg(ints));
}

test "plural picks the noun for a count" {
    const expect = std.testing.expectEqualStrings;
    try expect("1 item", comptime plural(1, "item", "items"));
    try expect("2 items", comptime plural(2, "item", "items"));
    try expect("0 items", comptime plural(0, "item", "items"));
    try expect("1 byte", comptime plural(@as(usize, 1), "byte", "bytes"));
    try expect("512 bytes", comptime plural(@as(usize, 512), "byte", "bytes"));
}

// ------------------------------------------------------------------ parameters

/// A rule parameter as data: what `.withMessage` substitutes and a schema
/// export could show.
pub const Value = union(enum) {
    int: comptime_int,
    float: comptime_float,
    bool: bool,
    string: []const u8,
    /// An enum tag, without the leading dot.
    tag: []const u8,
    list: []const Value,
};

/// A parameter of a rule, named as its placeholder (`{min}` is the
/// parameter `min`).
pub const Param = struct {
    name: []const u8,
    value: Value,
    /// The value as messages show it (`renderValue`): `{name}` in a
    /// `.withMessage` template becomes this text.
    text: []const u8,
    /// `{name}` may appear in `.withMessage` templates.
    placeholder: bool = true,
};

/// A parameter that templates may use as `{name}`.
pub fn param(comptime name: []const u8, comptime x: anytype) Param {
    return .{ .name = name, .value = valueOf(x), .text = renderValue(x) };
}

/// A parameter kept as data only: `{name}` is not a placeholder.
pub fn dataParam(comptime name: []const u8, comptime x: anytype) Param {
    return .{ .name = name, .value = valueOf(x), .text = renderValue(x), .placeholder = false };
}

/// `x` as data. A rule checks its parameters before it keeps them: an
/// unnamed value of a non-exhaustive enum or a value of another kind stops
/// compilation here with an internal error.
pub fn valueOf(comptime x: anytype) Value {
    @setEvalBranchQuota(eval_quota);
    return switch (comptime valueKind(@TypeOf(x))) {
        .int => .{ .int = x },
        .float => .{ .float = x },
        .bool => .{ .bool = x },
        .tag => .{ .tag = tagName(x) orelse @compileError("validator: internal: " ++ unnamedTag(x) ++ " has no tag name") },
        .string => .{ .string = x },
        .list => blk: {
            var items: [x.len]Value = undefined;
            for (&items, 0..) |*slot, i| slot.* = valueOf(x[i]);
            const final = items;
            break :blk .{ .list = &final };
        },
        .other => @compileError("validator: internal: no parameter value of type " ++ @typeName(@TypeOf(x))),
    };
}

test "a parameter keeps its value as data: numbers, bools, tags without the dot, strings and lists" {
    const t = std.testing;
    try t.expect(comptime valueOf(5).int == 5);
    try t.expect(comptime valueOf(@as(i128, std.math.minInt(i128))).int == std.math.minInt(i128));
    try t.expect(comptime valueOf(0.5).float == 0.5);
    try t.expect(comptime valueOf(@as(f32, 0.1)).float == @as(f32, 0.1));
    try t.expect(comptime valueOf(true).bool);
    try t.expect(!comptime valueOf(false).bool);
    try t.expectEqualStrings("admin", comptime valueOf(.admin).tag);
    try t.expectEqualStrings("b", comptime valueOf(TestOpen.b).tag);
    try t.expectEqualStrings("a\tb", comptime valueOf("a\tb").string);
    try t.expectEqualStrings("", comptime valueOf("").string);
    const list = comptime valueOf(.{ "a", .b, 3 });
    try t.expectEqual(3, list.list.len);
    try t.expectEqualStrings("a", list.list[0].string);
    try t.expectEqualStrings("b", list.list[1].tag);
    try t.expect(comptime list.list[2].int == 3);
    const array = comptime valueOf([_]u8{ 1, 2 });
    try t.expectEqual(2, array.list.len);
    try t.expect(comptime array.list[1].int == 2);
}

test "a parameter has a name, its value and its text as messages show it; a data parameter is no placeholder" {
    const t = std.testing;
    const max = comptime param("max", 0.1);
    try t.expectEqualStrings("max", max.name);
    try t.expectEqualStrings("0.1", max.text);
    try t.expect(comptime max.value.float == 0.1);
    try t.expect(max.placeholder);
    const zero = comptime param("min", -0.0);
    try t.expectEqualStrings("0", zero.text);
    const values = comptime param("values", .{ "a", "" });
    try t.expectEqualStrings("a, \"\"", values.text);
    try t.expect(values.placeholder);
    const key = comptime dataParam("key", .id);
    try t.expectEqualStrings("key", key.name);
    try t.expectEqualStrings("id", key.text);
    try t.expectEqualStrings("id", key.value.tag);
    try t.expect(!key.placeholder);
}

test "define gives a rule the parameters of its spec" {
    const rule = comptime define(.min, .{
        .message = "must be at least 18",
        .args = "18",
        .params = &.{param("min", 18)},
        .fits = test_rules.fitsAnything,
        .eval = test_rules.evalPositive,
    });
    try std.testing.expectEqual(1, rule.params.len);
    try std.testing.expectEqualStrings("min", rule.params[0].name);
    try std.testing.expectEqualStrings("18", rule.params[0].text);
    try std.testing.expectEqual(0, test_rules.positive.params.len);
}

// ------------------------------------------------------------------ bounds

/// What a bound limits. A measure applies to some field types only: the
/// contradiction check compares bounds of one measure on a field type it
/// applies to, and bounds of different measures never.
pub const Measure = enum {
    /// The value of an integer or float field.
    value,
    /// The number of items of a slice, `null` items included.
    items,
    /// The number of bytes of a string.
    bytes,
    /// The number of code points of a string.
    code_points,
    /// The date of a string that is a full-date (`minDate` and `maxDate`
    /// with a date bound).
    date,
    /// The instant of a string that is a date-time (`minDate` and `maxDate`
    /// with a date-time bound).
    date_time,

    /// Bounds on this measure limit the values of the unwrapped field type `T`.
    pub fn applies(comptime measure: Measure, comptime T: type) bool {
        return switch (measure) {
            .value => isNumber(T),
            .items => isListSlice(T),
            .bytes, .code_points, .date, .date_time => isString(T),
        };
    }

    /// Which two rules a contradiction on this measure names: the first
    /// pair in tuple order for numbers and items; for strings and dates the
    /// rule with the largest lower bound and the rule with the smallest
    /// upper bound, the earlier one on ties.
    fn namesFirstPair(comptime measure: Measure) bool {
        return measure == .value or measure == .items;
    }
};

/// One side of the values a rule accepts on one measure: `min(5)` is
/// `value >= 5`, `positive` is `value > 0`, `maxItems(3)` is `items <= 3`.
pub const Bound = struct {
    measure: Measure,
    side: Side,
    /// The bound: `.int` or `.float` as written for numbers and counts; a
    /// derived integer for dates and date-times (see `scale`).
    value: Value,
    /// The bound is `value / 10^scale`: a date-time bound keeps every digit of
    /// its fraction of a second. An exclusive bound is a whole number.
    scale: comptime_int = 0,
    /// The bound itself passes (`>=`, `<=`) rather than not (`>`, `<`).
    inclusive: bool = true,

    pub const Side = enum { lower, upper };

    /// `measure >= x`.
    pub fn atLeast(comptime measure: Measure, comptime x: anytype) Bound {
        return .{ .measure = measure, .side = .lower, .value = valueOf(x) };
    }

    /// `measure <= x`.
    pub fn atMost(comptime measure: Measure, comptime x: anytype) Bound {
        return .{ .measure = measure, .side = .upper, .value = valueOf(x) };
    }

    /// `measure > x`.
    pub fn above(comptime measure: Measure, comptime x: anytype) Bound {
        return .{ .measure = measure, .side = .lower, .value = valueOf(x), .inclusive = false };
    }

    /// `measure < x`.
    pub fn below(comptime measure: Measure, comptime x: anytype) Bound {
        return .{ .measure = measure, .side = .upper, .value = valueOf(x), .inclusive = false };
    }
};

/// The indexes, in tuple order, of two rules whose bounds on one measure let
/// no value of the unwrapped field type `T` pass, or null. The measures are
/// checked in their order, and `Measure.namesFirstPair` tells which pair a
/// contradiction names. Comparing pairs is enough: a set of lower and upper
/// bounds leaves a value exactly when every lower bound fits under every
/// upper bound, that is, when the largest lower bound fits under the
/// smallest upper bound.
pub fn contradiction(comptime rules: []const Rule, comptime T: type) ?[2]usize {
    @setEvalBranchQuota(eval_quota);
    inline for (comptime std.enums.values(Measure)) |measure| {
        if (!comptime measure.applies(T)) continue;
        const pair = if (measure.namesFirstPair()) firstContradiction(rules, measure, T) else extremeContradiction(rules, measure, T);
        if (pair != null) return pair;
    }
    return null;
}

/// The first two rules, in tuple order, whose bounds on `measure` let no
/// value of `T` pass, or null.
fn firstContradiction(comptime rules: []const Rule, comptime measure: Measure, comptime T: type) ?[2]usize {
    for (rules, 0..) |a, i| {
        for (rules[i + 1 ..], i + 1..) |b, j| {
            for (a.bounds) |x| {
                if (x.measure != measure) continue;
                for (b.bounds) |y| {
                    if (y.measure != measure or x.side == y.side) continue;
                    const lower = if (x.side == .lower) x else y;
                    const upper = if (x.side == .lower) y else x;
                    if (!satisfiable(lower, upper, T)) return .{ i, j };
                }
            }
        }
    }
    return null;
}

/// The rule with the largest lower bound on `measure` and the rule with the
/// smallest upper bound, each the earlier one on ties, in tuple order, when
/// the two bounds let no value of `T` pass; else null.
fn extremeContradiction(comptime rules: []const Rule, comptime measure: Measure, comptime T: type) ?[2]usize {
    comptime {
        const Extreme = struct { index: usize, bound: Bound };
        var lower: ?Extreme = null;
        var upper: ?Extreme = null;
        for (rules, 0..) |rule, i| {
            for (rule.bounds) |b| {
                if (b.measure != measure) continue;
                switch (b.side) {
                    .lower => if (lower == null or edgeOrder(b, lower.?.bound) == .gt) {
                        lower = .{ .index = i, .bound = b };
                    },
                    .upper => if (upper == null or edgeOrder(b, upper.?.bound) == .lt) {
                        upper = .{ .index = i, .bound = b };
                    },
                }
            }
        }
        const lo = lower orelse return null;
        const hi = upper orelse return null;
        if (satisfiable(lo.bound, hi.bound, T)) return null;
        return if (lo.index < hi.index) .{ lo.index, hi.index } else .{ hi.index, lo.index };
    }
}

/// Some value of the measure lies between `lower` and `upper`. A float field
/// compares the bounds in its own type, as its rules do; counts and integer
/// fields move an exclusive bound by one; other bounds compare exactly.
fn satisfiable(comptime lower: Bound, comptime upper: Bound, comptime T: type) bool {
    if (lower.measure == .value and isFloat(T)) {
        const lo = boundAs(T, lower.value);
        const hi = boundAs(T, upper.value);
        return lo < hi or (lo == hi and lower.inclusive and upper.inclusive);
    }
    return edgeOrder(lower, upper) != .gt;
}

/// The order of the least (lower bound) or largest (upper bound) values that
/// the whole-number or decimal bounds `a` and `b` let pass: an exclusive
/// bound moves by one.
fn edgeOrder(comptime a: Bound, comptime b: Bound) std.math.Order {
    return std.math.order(edge(a) * pow10(b.scale), edge(b) * pow10(a.scale));
}

/// The least (lower bound) or largest (upper bound) value that `bound` lets
/// pass, times `10^bound.scale`.
fn edge(comptime bound: Bound) comptime_int {
    const x = boundInt(bound.value);
    if (bound.inclusive) return x;
    if (bound.scale != 0) @compileError("validator: internal: an exclusive bound is a whole number");
    return if (bound.side == .lower) x + 1 else x - 1;
}

/// `10^n`.
fn pow10(comptime n: comptime_int) comptime_int {
    comptime {
        var result: comptime_int = 1;
        for (0..n) |_| result *= 10;
        return result;
    }
}

/// A bound as a value of the float field type `T`, as `numberAs` converts it.
fn boundAs(comptime T: type, comptime value: Value) T {
    return switch (value) {
        .int => |x| numberAs(T, x),
        .float => |x| numberAs(T, x),
        else => @compileError("validator: internal: a bound is a number"),
    };
}

/// A bound of an integer field or a count: the declaration checks accept
/// only integers there.
fn boundInt(comptime value: Value) comptime_int {
    return switch (value) {
        .int => |x| x,
        else => @compileError("validator: internal: a bound on an integer measure is an integer"),
    };
}

/// The declaration error of the rule list `rules` on the unwrapped field type
/// `T` for its first contradiction, or null.
pub fn contradictionText(comptime rules: []const Rule, comptime T: type, comptime where: []const u8) ?[]const u8 {
    const pair = contradiction(rules, T) orelse return null;
    return "validator: " ++ where ++ ": " ++ rules[pair[0]].label() ++ " and " ++ rules[pair[1]].label() ++ " contradict; no value can pass";
}

// ------------------------------------------------------------------ the rule

/// What a rule's run-time check returns.
pub const Outcome = enum {
    pass,
    /// Reported with the rule's own code and message.
    fail,
    /// Reported with the rule's `precondition` code and message, which are
    /// fixed: a float that is NaN or ±inf fails every number rule with
    /// `validation.finite` before the rule's own check runs.
    precondition,
};

/// `.pass` when `ok`, else `.fail`.
pub fn passIf(ok: bool) Outcome {
    return if (ok) .pass else .fail;
}

/// The fixed code and message of a precondition failure.
pub const Precondition = struct { code: []const u8, message: []const u8 };

/// The preconditions that rules report. Each code is also the code of the
/// rule of the same name (`v.finite`), whose `.withMessage` words the case
/// when that rule is put first.
pub const preconditions = struct {
    /// The rules that decode code points (`minLength`, `maxLength`,
    /// `length`, `notBlank`, the width rules and `strongPassword`), on a
    /// string that is not valid UTF-8.
    pub const utf8: Precondition = .{ .code = "validation.utf8", .message = "must be valid UTF-8" };
    /// Every number rule, `latitude` and `longitude` on a float field whose
    /// value is NaN, +inf or -inf.
    pub const finite: Precondition = .{ .code = "validation.finite", .message = "must be a finite number" };
    /// `minDate` and `maxDate` with a date bound, on a value that is not a
    /// date.
    pub const date: Precondition = .{ .code = "validation.date", .message = "must be a valid date in YYYY-MM-DD format" };
    /// `minDate` and `maxDate` with a date-time bound, on a value that is not
    /// an RFC 3339 date-time.
    pub const rfc3339: Precondition = .{ .code = "validation.rfc3339", .message = "must be a valid RFC 3339 date-time" };
};

/// A validation rule. Rules are values (`v.notEmpty`) or are built by
/// constructors (`v.custom(...)`), and are declared in a DTO's
/// `pub const field_rules`. A rule holds generic functions, so it is a
/// comptime-only value: keep it in a `const` or pass it as a `comptime`
/// parameter.
///
/// `code` and `message` are the stable public part, which applications and
/// tests may read (`v.notEmpty.code` is `"validation.not_empty"`), and
/// `withMessage` replaces the message. The other fields and methods are
/// internal to the module and may change.
pub const Rule = struct {
    kind: Kind,
    /// `validation.<kind>` for a built-in rule, the user's code for
    /// `v.custom`, and "" for `each`, which reports through its inner rules.
    code: []const u8,
    /// The message of this rule's own failure: the default one, its
    /// fallback, or the result of `.withMessage`; "" for `each`. A default
    /// message longer than 512 bytes without a fallback (a bound of hundreds
    /// of digits) stays here as built, and the declaration check of the field
    /// rejects it unless `.withMessage` replaced it.
    message: []const u8,
    /// The arguments as written (`"users.ok", ...` for `custom`, `...` for
    /// `each`), shown in compile errors and hints; null for a rule used as a
    /// value (`v.notEmpty`).
    args: ?[]const u8 = null,
    /// The parameters as data, in the order of the constructor's arguments;
    /// the placeholder ones are `{name}` in `.withMessage` templates.
    params: []const Param = &.{},
    /// The precondition this rule can report. Its run-time check returns
    /// `.precondition` only on the field types where it applies (`finite`
    /// on floats only).
    precondition: ?Precondition = null,
    /// `each` only: the rules applied to every item.
    inner: []const Rule = &.{},
    /// `each` only: the transforms of every item, which `v.transform` runs.
    item_transforms: []const Transform = &.{},
    /// `each` only: an element of its argument out of its place, reported
    /// by the declaration check of its field, where the path is known.
    item_problem: ?EntryProblem = null,
    /// The sides of the values the rule accepts (`min(5)`: value >= 5), for
    /// the contradiction check of the rule list.
    bounds: []const Bound = &.{},
    /// Compile-time check against the unwrapped field type (or the unwrapped
    /// item type inside `each`). `where` is `<Type>.field_rules.<field>`,
    /// with `[]` appended per `each` level. Reports problems with
    /// `@compileError`, usually through `typeError` or `ruleError`.
    fits: fn (comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void,
    /// The declaration check that also sees the other rules of the value,
    /// run after every rule's `fits`: `rules` is the value's tuple (a
    /// trailing `each` included) and `rules[index]` this rule; null for most
    /// rules. `uniqueItems` and `uniqueBy` find the `maxItems` before them
    /// with it, `minDate` and `maxDate` the date forms their neighbours need.
    check_list: ?ListCheck = null,
    /// Run-time check; receives `*const T`, with `T` unwrapped.
    eval: fn (value: anytype) Outcome,

    /// The public name: `notEmpty`.
    pub fn name(comptime rule: Rule) []const u8 {
        return comptime info(rule.kind).name;
    }

    /// The call as written in `field_rules`: `positive`, `custom("users.ok", ...)`.
    pub fn call(comptime rule: Rule) []const u8 {
        return comptime info(rule.kind).name ++ if (rule.args) |a| "(" ++ a ++ ")" else "";
    }

    /// The snake_case form that declaration errors use: `not_empty`,
    /// `custom("users.ok", ...)`.
    pub fn label(comptime rule: Rule) []const u8 {
        return comptime @tagName(rule.kind) ++ if (rule.args) |a| "(" ++ a ++ ")" else "";
    }

    /// The rule with another message for its own failure:
    /// `v.range(1, 100).withMessage("from {min} to {max} items")`. The code
    /// stays, and a precondition failure keeps its fixed code and message
    /// (NaN under `v.positive.withMessage(...)` still reports
    /// `validation.finite`). `{name}` is a placeholder of the rule: its
    /// parameter as the rule's page names it (`v.range(lo, hi)` has `{min}`
    /// and `{max}`), shown as the default message shows it. `{{` writes `{`,
    /// `}}` writes `}`, and any other `}` stays. On `v.custom` the template
    /// replaces its literal message: braces are syntax here, and custom has no
    /// placeholders. The message must be 1-512 bytes of valid UTF-8, in any
    /// language. A second `.withMessage` replaces the first; the rule it is
    /// called on keeps its message. `each` has no message of its own: give its
    /// inner rules theirs. A mistake is a compile error at the call.
    pub fn withMessage(comptime rule: Rule, comptime template: []const u8) Rule {
        switch (renderTemplate(rule, template)) {
            .message => |message| {
                var copy = rule;
                copy.message = message;
                return copy;
            },
            .problem => |text| @compileError(text),
        }
    }
};

/// Everything `define` needs to build a built-in rule.
pub const Spec = struct {
    /// The default message: 1-512 bytes of valid UTF-8; a longer one takes
    /// `fallback`, or, without one, stays and fails the field's declaration
    /// check (see `define`).
    message: []const u8,
    /// The general message that replaces `message` when the parameters shown
    /// in it make it longer than 512 bytes ("must be equal to the expected
    /// value"); a message of exactly 512 bytes stays. Null for a rule without
    /// one.
    fallback: ?[]const u8 = null,
    /// Replaces `codeOf(kind)`; only `v.custom` sets it.
    code: ?[]const u8 = null,
    args: ?[]const u8 = null,
    params: []const Param = &.{},
    precondition: ?Precondition = null,
    bounds: []const Bound = &.{},
    fits: fn (comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void,
    check_list: ?ListCheck = null,
    eval: fn (value: anytype) Outcome,
};

/// The type of `Rule.check_list`.
pub const ListCheck = fn (comptime rule: *const Rule, comptime rules: []const Rule, comptime index: usize, comptime T: type, comptime where: []const u8) void;

/// Builds a rule of `kind`: the code of its kind (or `spec.code`), the
/// default message (or `spec.fallback` when the default message is longer
/// than 512 bytes) and the checks. A longer default message without a
/// fallback is kept as it is: the declaration check of the field reports it
/// (`defaultMessageProblem`) unless `.withMessage` replaces it. `each` is
/// built by hand instead, since it has no code or message of its own.
pub fn define(comptime kind: Kind, comptime spec: Spec) Rule {
    @setEvalBranchQuota(eval_quota);
    const message = if (spec.message.len > max_message_bytes) spec.fallback orelse spec.message else spec.message;
    if (messageProblem(message)) |problem| {
        const kept = problem == .too_long and spec.fallback == null;
        if (!kept) @compileError("validator: internal: the default message of " ++ @tagName(kind) ++ ": " ++ describeMessageProblem(problem));
    }
    return .{
        .kind = kind,
        .code = spec.code orelse codeOf(kind),
        .message = message,
        .args = spec.args,
        .params = spec.params,
        .precondition = spec.precondition,
        .bounds = spec.bounds,
        .fits = spec.fits,
        .check_list = spec.check_list,
        .eval = spec.eval,
    };
}

/// For the tests of the rule files: `rule`'s run-time check on `value`
/// returns `expected`.
pub fn expectOutcome(expected: Outcome, comptime rule: Rule, value: anytype) !void {
    try std.testing.expectEqual(expected, rule.eval(&value));
}

// ------------------------------------------------------------------ names and transforms

/// The outside name of a field, built by `v.rename(name)`: the first
/// element of the field's entry in `field_rules`.
pub const Rename = struct {
    /// 1 to 64 bytes from `A-Z`, `a-z`, `0-9`, `_` and `-`, checked by
    /// `v.rename`.
    name: []const u8,
};

/// Every transform of the validator. The tag is the snake_case name that
/// declaration errors use.
pub const TransformKind = enum { trim, trim_start, trim_end, to_lower, to_upper, transform_with };

/// The public name of the transform of `kind`: `trimStart`.
pub fn transformName(comptime kind: TransformKind) []const u8 {
    return switch (kind) {
        .trim => "trim",
        .trim_start => "trimStart",
        .trim_end => "trimEnd",
        .to_lower => "toLower",
        .to_upper => "toUpper",
        .transform_with => "transformWith",
    };
}

/// A transform of `field_rules`: a value such as `v.trim`, or one built by
/// `v.transformWith(f)`. `v.transform` runs it on its field's value, and
/// `v.check` and `v.checkAll` skip it. It holds a type and a function, so it
/// is a comptime-only value, as a `Rule` is. Internal to the module.
pub const Transform = struct {
    kind: TransformKind,
    /// A namespace whose `call` is the function the transform runs:
    /// `fn (std.mem.Allocator, U) U` or `fn (std.mem.Allocator, U) E!U`,
    /// where `U` is the unwrapped field type (the unwrapped item type inside
    /// `each`).
    run: type,
    /// Compile-time check against the unwrapped field type (or the unwrapped
    /// item type inside `each`); `where` as for `Rule.fits`.
    fits: fn (comptime transform: *const Transform, comptime T: type, comptime where: []const u8) void,

    /// The public name: `trimStart`.
    pub fn name(comptime t: Transform) []const u8 {
        return transformName(t.kind);
    }

    /// The snake_case form that declaration errors use: `trim_start`, and
    /// `transform_with(...)`, since Zig cannot name a function value.
    pub fn label(comptime t: Transform) []const u8 {
        return comptime @tagName(t.kind) ++ if (t.kind == .transform_with) "(...)" else "";
    }

    /// The errors of its function, without `error.OutOfMemory` unless the
    /// function returns it: `error{}` for a function without an error union.
    pub fn Error(comptime t: Transform) type {
        const R = @typeInfo(@TypeOf(t.run.call)).@"fn".return_type.?;
        return switch (@typeInfo(R)) {
            .error_union => |e| e.error_set,
            else => error{},
        };
    }
};

// ------------------------------------------------------------------ message templates

/// What `.withMessage(template)` makes of a rule: its new message, or the
/// whole text of the compile error.
pub const Template = union(enum) { message: []const u8, problem: []const u8 };

/// Renders the `.withMessage` template of `rule`. `{name}` becomes the text
/// of the rule's placeholder `name`, `{{` becomes `{`, `}}` becomes `}`, and
/// any other `}` stays. The template is read left to right, and its first
/// unknown or unclosed placeholder is the problem; then the message must be
/// 1-512 bytes of valid UTF-8. `each` takes no template. An error text starts
/// with the call and the template: `validator: min(1).withMessage("..."): `.
pub fn renderTemplate(comptime rule: Rule, comptime template: []const u8) Template {
    comptime {
        @setEvalBranchQuota(eval_quota);
        if (rule.kind == .each) return .{ .problem = templateHead(rule, template) ++ "each has no message of its own; put .withMessage on the inner rules" };
        var out: []const u8 = "";
        // The first byte of the literal text not copied to `out` yet.
        var start: usize = 0;
        var i: usize = 0;
        while (i < template.len) {
            switch (template[i]) {
                '{' => {
                    out = out ++ template[start..i];
                    if (i + 1 < template.len and template[i + 1] == '{') {
                        out = out ++ "{";
                        i += 2;
                    } else {
                        const close = std.mem.findScalarPos(u8, template, i + 1, '}') orelse
                            return .{ .problem = templateHead(rule, template) ++ "'{' without a closing '}'; write '{{' for a literal '{'" };
                        const name = template[i + 1 .. close];
                        out = out ++ (placeholderText(rule, name) orelse return .{ .problem = templateHead(rule, template) ++ unknownPlaceholder(rule, name) });
                        i = close + 1;
                    }
                    start = i;
                },
                '}' => {
                    if (i + 1 < template.len and template[i + 1] == '}') {
                        out = out ++ template[start..i] ++ "}";
                        i += 2;
                        start = i;
                    } else {
                        i += 1;
                    }
                },
                else => i += 1,
            }
        }
        const message = out ++ template[start..];
        if (messageProblem(message)) |problem| return .{ .problem = templateHead(rule, template) ++ describeMessageProblem(problem) };
        return .{ .message = message };
    }
}

/// The start of a `.withMessage` error: `validator: min(1).withMessage("..."): `,
/// with the template escaped. Built only for an error: escaping every
/// template up front would slow down the analysis of every DTO with messages.
fn templateHead(comptime rule: Rule, comptime template: []const u8) []const u8 {
    return "validator: " ++ rule.call() ++ ".withMessage(\"" ++ escape(template) ++ "\"): ";
}

/// The text of the placeholder `name` of `rule`: its parameter as messages
/// show it. Null when the rule has no such placeholder.
pub fn placeholderText(comptime rule: Rule, comptime name: []const u8) ?[]const u8 {
    comptime {
        for (rule.params) |p| {
            if (p.placeholder and std.mem.eql(u8, p.name, name)) return p.text;
        }
        return null;
    }
}

/// The placeholders of `rule` in the order of its parameters, as error texts
/// list them: `{min}, {max}`; "" for a rule without placeholders.
pub fn placeholderList(comptime rule: Rule) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (rule.params) |p| {
            if (p.placeholder) out = out ++ (if (out.len == 0) "" else ", ") ++ "{" ++ p.name ++ "}";
        }
        return out;
    }
}

/// The problem of the placeholder `name`, which `rule` does not have. The
/// name is escaped as the template in the head is.
fn unknownPlaceholder(comptime rule: Rule, comptime name: []const u8) []const u8 {
    const available = placeholderList(rule);
    return "unknown placeholder {" ++ escape(name) ++ "}; " ++ if (available.len == 0) "this rule has no placeholders" else "available: " ++ available;
}

/// The declaration error of a rule whose default message is longer than 512
/// bytes, or null. Only a rule without a fallback keeps such a message (`min`,
/// `max`, `range` and `divisibleBy` with a bound of hundreds of digits), and
/// `.withMessage` replaces it with one of at most 512 bytes.
pub fn defaultMessageProblem(comptime rule: *const Rule, comptime where: []const u8) ?[]const u8 {
    if (rule.message.len <= max_message_bytes) return null;
    return ruleErrorText(rule, where, std.fmt.comptimePrint(": the default message would be {d} bytes (limit {d}); use .withMessage(...)", .{ rule.message.len, max_message_bytes }));
}

/// What `.withMessage(template)` gives `rule`, for the tests below: the new
/// message, or the whole text of the compile error.
fn withMessageText(comptime rule: Rule, comptime template: []const u8) []const u8 {
    return switch (comptime renderTemplate(rule, template)) {
        .message, .problem => |text| text,
    };
}

fn isEvenForTest(n: u32) bool {
    return n % 2 == 0;
}

test "the preconditions have their fixed codes and messages; each code is the code of the rule of the same name" {
    const expect = std.testing.expectEqualStrings;
    try expect("validation.utf8", preconditions.utf8.code);
    try expect("must be valid UTF-8", preconditions.utf8.message);
    try expect("validation.finite", preconditions.finite.code);
    try expect("must be a finite number", preconditions.finite.message);
    try expect("validation.date", preconditions.date.code);
    try expect("must be a valid date in YYYY-MM-DD format", preconditions.date.message);
    try expect("validation.rfc3339", preconditions.rfc3339.code);
    try expect("must be a valid RFC 3339 date-time", preconditions.rfc3339.message);
    try expect(comptime codeOf(.utf8), preconditions.utf8.code);
    try expect(comptime codeOf(.finite), preconditions.finite.code);
    try expect(comptime codeOf(.date), preconditions.date.code);
    try expect(comptime codeOf(.rfc3339), preconditions.rfc3339.code);
}

test "a rule's placeholders are its placeholder parameters, listed in the order of its arguments" {
    const expect = std.testing.expectEqualStrings;
    try expect("{min}, {max}", comptime placeholderList(root.range(1, 100)));
    try expect("{min}", comptime placeholderList(root.min(1)));
    try expect("{max}", comptime placeholderList(root.max(1)));
    try expect("{divisor}", comptime placeholderList(root.divisibleBy(5)));
    try expect("{expected}", comptime placeholderList(root.equals(5)));
    try expect("{forbidden}", comptime placeholderList(root.notEquals(5)));
    try expect("{values}", comptime placeholderList(root.oneOf(.{"a"})));
    try expect("{values}", comptime placeholderList(root.noneOf(.{"a"})));
    try expect("{min}", comptime placeholderList(root.minItems(1)));
    try expect("{max}", comptime placeholderList(root.maxItems(1)));
    try expect("", comptime placeholderList(root.notEmpty));
    try expect("", comptime placeholderList(root.custom("acme.even", "must be even", isEvenForTest)));
    try expect("1", comptime placeholderText(root.range(1, 100), "min").?);
    try expect("100", comptime placeholderText(root.range(1, 100), "max").?);
    try std.testing.expectEqual(null, comptime placeholderText(root.range(1, 100), "divisor"));
    try std.testing.expectEqual(null, comptime placeholderText(root.notEmpty, "value"));
    // A data parameter, such as an option of an options rule, is no placeholder.
    const with_option = comptime define(.fqdn, .{ .message = "must be a valid domain name", .args = ".{...}", .params = &.{dataParam("require_tld", true)}, .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try expect("", comptime placeholderList(with_option));
    try std.testing.expectEqual(null, comptime placeholderText(with_option, "require_tld"));
}

test "an unknown placeholder is an error at the call that lists the placeholders the rule has" {
    const expect = std.testing.expectEqualStrings;
    try expect(
        "validator: divisibleBy(5).withMessage(\"must be a multiple of {n}\"): unknown placeholder {n}; available: {divisor}",
        comptime withMessageText(root.divisibleBy(5), "must be a multiple of {n}"),
    );
    // {} has an empty name; the names are listed in the order of the arguments.
    try expect("validator: range(1, 100).withMessage(\"{}\"): unknown placeholder {}; available: {min}, {max}", comptime withMessageText(root.range(1, 100), "{}"));
    // Names are case-sensitive, and a placeholder of another rule is unknown here.
    try expect("validator: min(1).withMessage(\"{Min}\"): unknown placeholder {Min}; available: {min}", comptime withMessageText(root.min(1), "{Min}"));
    try expect("validator: maxItems(5).withMessage(\"{min}\"): unknown placeholder {min}; available: {max}", comptime withMessageText(root.maxItems(5), "{min}"));
    // {value} and {field} exist on no rule.
    try expect("validator: equals(5).withMessage(\"{value}\"): unknown placeholder {value}; available: {expected}", comptime withMessageText(root.equals(5), "{value}"));
    // The name is escaped as the template is, so the error stays on one line.
    try expect("validator: min(1).withMessage(\"{a\\nb}\"): unknown placeholder {a\\nb}; available: {min}", comptime withMessageText(root.min(1), "{a\nb}"));
    // In a chain, the head shows the rule's call and the template that fails,
    // not the earlier .withMessage.
    try expect(
        "validator: minItems(8).withMessage(\"{x}\"): unknown placeholder {x}; available: {min}",
        comptime withMessageText(root.minItems(8).withMessage("a {min}"), "{x}"),
    );
}

test "a placeholder on a rule without placeholders is an error, custom included" {
    const expect = std.testing.expectEqualStrings;
    try expect(
        "validator: negative.withMessage(\"{value} must be negative\"): unknown placeholder {value}; this rule has no placeholders",
        comptime withMessageText(root.negative, "{value} must be negative"),
    );
    try expect(
        "validator: custom(\"acme.even\", ...).withMessage(\"{odd}\"): unknown placeholder {odd}; this rule has no placeholders",
        comptime withMessageText(root.custom("acme.even", "must be even, not {odd}", isEvenForTest), "{odd}"),
    );
    try expect("validator: notEmpty.withMessage(\"{field} is required\"): unknown placeholder {field}; this rule has no placeholders", comptime withMessageText(root.notEmpty, "{field} is required"));
    try expect("validator: negative.withMessage(\"{\\xff}\"): unknown placeholder {\\xff}; this rule has no placeholders", comptime withMessageText(root.negative, "{\xff}"));
}

test "a { without a closing } is an error; {{ writes a literal {" {
    const expect = std.testing.expectEqualStrings;
    const unclosed = "'{' without a closing '}'; write '{{' for a literal '{'";
    try expect("validator: divisibleBy(5).withMessage(\"must be divisible by {divisor\"): " ++ unclosed, comptime withMessageText(root.divisibleBy(5), "must be divisible by {divisor"));
    try expect("validator: notEmpty.withMessage(\"{\"): " ++ unclosed, comptime withMessageText(root.notEmpty, "{"));
    try expect("validator: min(1).withMessage(\"{{min} {min\"): " ++ unclosed, comptime withMessageText(root.min(1), "{{min} {min"));
    try expect("{min} 1", comptime withMessageText(root.min(1), "{{min} {min}"));
}

test "the message of a template must not be empty, longer than 512 bytes or invalid UTF-8" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: notEmpty.withMessage(\"\"): message must not be empty", comptime withMessageText(root.notEmpty, ""));
    const long: [513]u8 = @splat('m');
    try expect("validator: maxItems(5).withMessage(\"" ++ long ++ "\"): message is longer than 512 bytes", comptime withMessageText(root.maxItems(5), &long));
    try expect("validator: min(1).withMessage(\"\\xc3\"): message must be valid UTF-8", comptime withMessageText(root.min(1), "\xc3"));
    try expect("validator: notEmpty.withMessage(\"caf\\xc3\"): message must be valid UTF-8", comptime withMessageText(root.notEmpty, "caf\xc3"));
    // The limit applies to the message after substitution: 511 bytes and {max} = 5 fit, 512 bytes and {max} do not.
    const fill: [511]u8 = @splat('m');
    try expect(fill ++ "5", comptime withMessageText(root.maxItems(5), fill ++ "{max}"));
    try expect("validator: maxItems(5).withMessage(\"" ++ fill ++ "m{max}\"): message is longer than 512 bytes", comptime withMessageText(root.maxItems(5), fill ++ "m{max}"));
    // A long placeholder can make a short template too long.
    const values = .{ &@as([300]u8, @splat('a')), &@as([300]u8, @splat('b')) };
    try std.testing.expect(std.mem.endsWith(u8, comptime withMessageText(root.oneOf(values), "{values}"), "\"): message is longer than 512 bytes"));
}

test "withMessage on each is an error: its inner rules carry the messages" {
    try std.testing.expectEqualStrings(
        "validator: each(...).withMessage(\"x\"): each has no message of its own; put .withMessage on the inner rules",
        comptime withMessageText(root.each(root.notEmpty), "x"),
    );
}

test "a template is read left to right: the first unknown or unclosed placeholder wins, then the message is checked" {
    const expect = std.testing.expectEqualStrings;
    try expect("validator: divisibleBy(5).withMessage(\"{n} {divisor\"): unknown placeholder {n}; available: {divisor}", comptime withMessageText(root.divisibleBy(5), "{n} {divisor"));
    try expect("validator: divisibleBy(5).withMessage(\"{divisor} {n}\"): unknown placeholder {n}; available: {divisor}", comptime withMessageText(root.divisibleBy(5), "{divisor} {n}"));
    // A placeholder name ends at the first }.
    try expect("validator: divisibleBy(5).withMessage(\"{x {divisor}\"): unknown placeholder {x {divisor}; available: {divisor}", comptime withMessageText(root.divisibleBy(5), "{x {divisor}"));
    // Placeholders come before the length: a long template with an unknown one names the placeholder.
    const long: [600]u8 = @splat('m');
    try expect("validator: min(1).withMessage(\"" ++ long ++ "{n}\"): unknown placeholder {n}; available: {min}", comptime withMessageText(root.min(1), long ++ "{n}"));
    // Then emptiness, length and UTF-8, in that order.
    const invalid: [513]u8 = @splat(0xff);
    try std.testing.expect(std.mem.endsWith(u8, comptime withMessageText(root.min(1), &invalid), "\"): message is longer than 512 bytes"));
}

test "withMessage replaces the message only: the code, the parameters and the precondition stay" {
    const t = std.testing;
    const base = root.range(1, 100);
    const custom_message = comptime base.withMessage("from {min} to {max} items");
    try t.expectEqualStrings("from 1 to 100 items", custom_message.message);
    try t.expectEqualStrings("validation.range", custom_message.code);
    try t.expectEqualStrings("1, 100", custom_message.args.?);
    try t.expectEqual(2, custom_message.params.len);
    try t.expectEqualStrings("validation.finite", custom_message.precondition.?.code);
    try t.expectEqualStrings("must be a finite number", custom_message.precondition.?.message);
    // The rule it was called on keeps its default message.
    try t.expectEqualStrings("must be from 1 to 100", base.message);
    // A second withMessage replaces the first, with the same placeholders.
    try t.expectEqualStrings("b 8", (comptime root.minItems(8).withMessage("a {min}").withMessage("b {min}")).message);
    // On custom the template replaces the literal message, and its braces are syntax.
    try t.expectEqualStrings("{x} } {", (comptime root.custom("acme.even", "{x} }} {{", isEvenForTest).withMessage("{{x}} }} {{")).message);
}

test "a default message over 512 bytes without a fallback stays in the rule, and the field's declaration check reports it" {
    const t = std.testing;
    const where = "Dto.field_rules.x";
    const longer: [513]u8 = @splat('m');
    const kept = comptime define(.min, .{ .message = &longer, .args = "5", .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try t.expectEqualStrings(&longer, kept.message);
    try t.expectEqualStrings(
        "validator: Dto.field_rules.x: min(5): the default message would be 513 bytes (limit 512); use .withMessage(...)",
        comptime defaultMessageProblem(&kept, where).?,
    );
    try t.expectEqualStrings(
        "validator: Dto.field_rules.x[]: min(5): the default message would be 513 bytes (limit 512); use .withMessage(...)",
        comptime defaultMessageProblem(&kept, where ++ "[]").?,
    );
    // withMessage replaces it, so the check passes.
    try t.expectEqual(null, comptime defaultMessageProblem(&kept.withMessage("too small"), where));
    // 512 bytes stay; a rule with a fallback never keeps a longer message.
    const exactly: [512]u8 = @splat('m');
    const fits = comptime define(.min, .{ .message = &exactly, .args = "5", .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try t.expectEqual(null, comptime defaultMessageProblem(&fits, where));
    const fallback = comptime define(.equals, .{ .message = &longer, .fallback = "must be equal to the expected value", .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try t.expectEqual(null, comptime defaultMessageProblem(&fallback, where));
    try t.expectEqual(null, comptime defaultMessageProblem(&test_rules.each_positive, where));
}

// ------------------------------------------------------------------ field types

/// A string: a slice of u8 of any constness, sentinel and alignment.
/// `volatile` and `allowzero` slices and slices outside the default address
/// space are not strings (rules read strings as `[]const u8`, which they do
/// not coerce to), and `[N]u8` is an array of numbers.
pub fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8 and !p.attrs.@"volatile" and !p.attrs.@"allowzero" and
            (p.attrs.@"addrspace" orelse .generic) == .generic,
        else => false,
    };
}

/// A slice that the walker treats as a list: its items are not u8, and it is
/// neither `volatile` nor `allowzero` nor aligned below the alignment of its
/// items (`[]align(1) const u32`) nor outside the default address space,
/// since a pointer to an item of such a slice does not coerce to the
/// `*const T` that rules take.
pub fn isListSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child != u8 and !p.attrs.@"volatile" and !p.attrs.@"allowzero" and
            (p.attrs.@"align" == null or p.attrs.@"align".? >= @alignOf(p.child)) and
            (p.attrs.@"addrspace" orelse .generic) == .generic,
        else => false,
    };
}

/// The item type of a list (a slice that `isListSlice` accepts, or an
/// array, `[N]u8` included), or null.
pub fn ListChild(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (isListSlice(T)) p.child else null,
        .array => |a| a.child,
        else => null,
    };
}

/// Strips every optional layer: `??T` -> `T`.
pub fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| Unwrap(o.child),
        else => T,
    };
}

/// `[N]u8` or `[N:s]u8`.
pub fn isU8Array(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |a| a.child == u8,
        else => false,
    };
}

/// An integer or a float type.
pub fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => true,
        else => false,
    };
}

/// `f16`, `f32`, `f64`, `f80`, `f128` or `c_longdouble`.
pub fn isFloat(comptime T: type) bool {
    return @typeInfo(T) == .float;
}

/// An enum without `_`: its values are its named tags.
pub fn isExhaustiveEnum(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| e.mode == .exhaustive,
        else => false,
    };
}

/// A signed integer or a float type: the field types of the sign rules.
pub fn isSignedNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |i| i.signedness == .signed,
        .float => true,
        else => false,
    };
}

/// `T` coerces to `P` without a cast: the conversions a field value may take
/// into the parameter of a `v.custom` predicate. Identical types; integers of
/// the same signedness that are not narrower, and unsigned integers into
/// strictly wider signed ones; floats that are not narrower; `?P` and `E!P`
/// when `T` coerces to `P`; pointers and slices of the same size and child
/// that only add `const` or drop a sentinel (`[]u8` and `[:0]const u8` to
/// `[]const u8`). A different `volatile`, `allowzero`, alignment or address
/// space never coerces here. Zig itself coerces a few more (an integer into a
/// float that holds it exactly, `*const [N]T` into `[]const T`, an explicitly
/// aligned pointer into one whose alignment is not larger); `v.custom` keeps
/// to this list.
pub fn coerces(comptime T: type, comptime P: type) bool {
    if (T == P) return true;
    const from = @typeInfo(T);
    return switch (@typeInfo(P)) {
        .optional => |o| coerces(T, o.child),
        .error_union => |e| coerces(T, e.payload),
        .int => |to| switch (from) {
            .int => |f| if (f.signedness == to.signedness) f.bits <= to.bits else f.signedness == .unsigned and f.bits < to.bits,
            else => false,
        },
        .float => |to| switch (from) {
            .float => |f| f.bits <= to.bits,
            else => false,
        },
        .pointer => |to| switch (from) {
            .pointer => |f| f.size == to.size and f.child == to.child and
                (!f.attrs.@"const" or to.attrs.@"const") and
                f.attrs.@"volatile" == to.attrs.@"volatile" and
                f.attrs.@"allowzero" == to.attrs.@"allowzero" and
                f.attrs.@"align" == to.attrs.@"align" and
                (f.attrs.@"addrspace" orelse .generic) == (to.attrs.@"addrspace" orelse .generic) and
                (to.sentinel_ptr == null or (f.sentinel_ptr != null and to.sentinel().? == f.sentinel().?)),
            else => false,
        },
        else => false,
    };
}

// ------------------------------------------------------------------ declaration errors

/// Every compile-error hint that names a rule lives here, so that one test
/// can check each `v.<name>` these texts mention against the public
/// namespace.
pub const hints = struct {
    pub const u8_array = "[N]u8 is an array of numbers, not a string: use []const u8";
    pub const one_each = "put all item rules into one v.each(.{ ... })";
    pub const wrap_predicate = "wrap a predicate in v.custom(code, message, f)";
    /// A function of your own shaped like a transform,
    /// `fn (std.mem.Allocator, T) ...`, where an element of `field_rules`
    /// is expected.
    pub const wrap_transform = "wrap a transform function in v.transformWith(f)";
    /// A Zig field name that would make paths ambiguous.
    pub const outside_name = "rename the field or give it an outside name with v.rename(\"...\")";
    /// `v.custom` on a list whose items its predicate would take.
    pub const use_each_custom = "use v.each(v.custom(...))";
    /// A rule on a slice that `isString` and `isListSlice` reject only for
    /// its attributes, when the rule would take the plain slice.
    pub const odd_slice = "volatile, allowzero and under-aligned slices are neither strings nor lists";
    /// A tuple inside the tuple of rules.
    pub const nested_tuple = "tuples are not flattened: join them with ++, e.g. name_rules ++ .{ v.notEmpty }, or use the tuple as the whole entry";
    /// `&.{ ... }` where a rule or a tuple of rules belongs.
    pub const tuple_pointer = "drop the &: write .{ ... }, not &.{ ... }";
    /// The rules of a struct field's own fields written as a struct literal.
    pub const struct_literal = "the rules of a nested struct's fields go into that struct's own field_rules";
    /// A rule that only 0 of the field type would pass.
    pub const use_equals_zero = "use v.equals(0)";
    /// `equals("")`: the empty string has its own rule.
    pub const use_empty = "use v.empty";
    /// `notEquals("")` and a `""` listed in `noneOf`.
    pub const use_not_empty = "use v.notEmpty";
    /// A bool listed in `oneOf` or `noneOf`.
    pub const use_equals_or_not_equals = "use v.equals or v.notEquals";
    /// `minItems` and `maxItems` on a string field.
    pub const min_items_on_string = "for strings use v.minLength or v.minBytes";
    pub const max_items_on_string = "for strings use v.maxLength or v.maxBytes";
    /// `uniqueItems` on struct items, and `uniqueBy` on items that are not structs.
    pub const use_unique_by = "use v.uniqueBy(.field)";
    pub const use_unique_items = "use v.uniqueItems";
    /// `uniqueItems` or `uniqueBy` on a slice that needs a cap and has none before it.
    pub const unique_cap = std.fmt.comptimePrint("needs an earlier v.maxItems(n) with n <= {d} (max_unique_items) in the same tuple", .{max_unique_items});
    /// `containsAll` and `containsNone` on a string field: the substring rules.
    pub const contains_all_on_string = "for a substring use v.contains";
    pub const contains_none_on_string = "for a substring use v.notContains";
    /// A `""` listed in `containsNone`.
    pub const reject_empty_items = "use v.each(v.notEmpty) to reject empty items";
    /// `digits`, `numberString`, `decimal`, `hexadecimal` and `octal` on a
    /// number field.
    pub const already_a_number = "the field is already a number: use v.min, v.max or v.range";
    /// `booleanString` on a bool field.
    pub const bool_needs_no_rule = "a bool field is already a boolean and needs no rule";
    /// `booleanString` on a number field.
    pub const use_bool_field = "use a bool field";
    /// `port` on a number field.
    pub const port_on_number = "a u16 field already holds 0-65535: add v.min(1) to exclude 0, or use v.range(0, 65535) on a wider type";
    /// `latitude` and `longitude` on an integer field.
    pub const latitude_on_int = "integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-90_000_000, 90_000_000) for E6";
    pub const longitude_on_int = "integer coordinates are usually scaled (E6, E7): use v.range in your unit, e.g. v.range(-180_000_000, 180_000_000) for E6";
    /// `latLong` on a number field.
    pub const lat_long_on_number = "use two float fields with v.latitude and v.longitude";
    /// `minLength(0)`, which every valid UTF-8 string passes.
    pub const use_utf8 = "use v.utf8 to require valid UTF-8";
    /// `contains` and `notContains` on a list of strings, after the `each`
    /// call (`searchItems`).
    pub const search_items = "to search inside each item, or v.containsAll(.{ ... }) to require whole items";
    pub const search_items_not = "to search inside each item, or v.containsNone(.{ ... }) to forbid whole items";
    /// `contains` and `notContains` on a list of other items.
    pub const require_items = "use v.containsAll(.{ ... }) to require list items";
    pub const forbid_items = "use v.containsNone(.{ ... }) to forbid list items";
    /// `minDate` and `maxDate` on a number field.
    pub const timestamp_min = "for a numeric timestamp use v.min";
    pub const timestamp_max = "for a numeric timestamp use v.max";
    /// A `minDate` or `maxDate` bound that every value of its form passes.
    pub const use_date = "use v.date";
    pub const use_rfc3339 = "use v.rfc3339";
    /// `iso8601` beside a `minDate` or `maxDate`, whose bound fixes the form.
    pub const iso8601_with_date = "use v.date instead of v.iso8601";
    pub const iso8601_with_date_time = "use v.rfc3339 instead of v.iso8601";
    /// `transformWith` on a list whose items its function would take.
    pub const use_each_transform_with = "use v.each(v.transformWith(...))";

    /// A rule written on a list whose items it would accept.
    pub fn useEach(comptime rule: Rule) []const u8 {
        return "use v.each(v." ++ rule.call() ++ ")";
    }

    /// A built-in transform written on a list of strings.
    pub fn useEachTransform(comptime transform: Transform) []const u8 {
        return "use v.each(v." ++ transform.name() ++ ")";
    }

    /// `contains` or `notContains` on a list of strings: the search inside
    /// each item, or the list rule for whole items.
    pub fn searchItems(comptime rule: Rule) []const u8 {
        return useEach(rule) ++ " " ++ if (rule.kind == .contains) search_items else search_items_not;
    }

    /// `minLength`, `maxLength` or `length` on a slice of other items: the
    /// list rules with the same counts.
    pub fn itemCount(comptime rule: Rule) []const u8 {
        return "for the number of items use " ++ switch (rule.kind) {
            .min_length => "v.minItems(" ++ rule.params[0].text ++ ")",
            .max_length => "v.maxItems(" ++ rule.params[0].text ++ ")",
            .length => "v.minItems(" ++ rule.params[0].text ++ ") and v.maxItems(" ++ rule.params[1].text ++ ")",
            else => @compileError("validator: internal: " ++ @tagName(rule.kind) ++ " counts no characters"),
        };
    }

    /// `length(0, max)`: the rule without a lower bound.
    pub fn useMaxLength(comptime max: usize) []const u8 {
        return "use v.maxLength(" ++ renderArg(max) ++ ")";
    }

    /// A rule constructor used without a call (`.tags = v.each`): its call
    /// with the arguments its rule file declares in `call_examples`, else
    /// `.{}` for an options struct, the first tag for an enum selector and
    /// `...` otherwise: `each must be called, e.g. v.each(v.notEmpty)`.
    pub fn mustBeCalled(comptime name: []const u8, comptime F: type) []const u8 {
        return name ++ " must be called, e.g. v." ++ name ++ "(" ++ exampleArgs(name, F) ++ ")";
    }

    /// A built-in predicate used where a rule is expected (`.day = v.isDate`).
    /// `Decl` is the type of the rule's public declaration: a rule value is
    /// named alone (`use the rule v.date`), a constructor is shown called, as
    /// `mustBeCalled` shows it (`use the rule v.hash(.sha256)`).
    pub fn predicateAsRule(comptime predicate: []const u8, comptime rule: []const u8, comptime Decl: type) []const u8 {
        const call = if (@typeInfo(Decl) == .@"fn") rule ++ "(" ++ exampleArgs(rule, Decl) ++ ")" else rule;
        return "expected a rule, got the predicate " ++ predicate ++ "; use the rule v." ++ call;
    }
};

/// The files that define rules, and those of the other elements of
/// `field_rules`. Each rule pull request adds its file here, so that its
/// `call_examples` reach the hints.
const rule_files = [_]type{ @import("common.zig"), @import("numbers.zig"), @import("strings.zig"), @import("formats.zig"), @import("encodings.zig"), @import("identifiers.zig"), @import("dates.zig"), @import("lists.zig"), @import("custom.zig"), @import("transforms.zig"), @import("names.zig") };

/// The arguments the hints show in a call of the constructor `name` of type
/// `F`: its `call_examples` entry, else `.{}` for an options struct, the
/// first tag for an enum selector, `...` otherwise.
fn exampleArgs(comptime name: []const u8, comptime F: type) []const u8 {
    if (callExample(name)) |example| return example;
    const params = @typeInfo(F).@"fn".param_types;
    if (params.len != 1) return "...";
    const P = params[0] orelse return "...";
    return switch (@typeInfo(P)) {
        .@"struct" => ".{}",
        .@"enum" => |e| "." ++ e.field_names[0],
        else => "...",
    };
}

/// The arguments a rule file shows for its constructor `name` in hints, from
/// its `pub const call_examples = .{ .<name> = "<arguments>" };`, or null.
fn callExample(comptime name: []const u8) ?[]const u8 {
    inline for (rule_files) |file| {
        if (@hasDecl(file, "call_examples") and @hasField(@TypeOf(file.call_examples), name)) return @field(file.call_examples, name);
    }
    return null;
}

/// Stops compilation because `rule` does not take the unwrapped field type
/// `T`: `validator: <where>: <kind> expects <expects>, field is <T>`, then
/// one hint after `; `. `accepts` tells which unwrapped types the rule takes
/// and picks the hint: the `[N]u8` hint when the rule would take a string,
/// `use v.each(v.<call>)` when it would take the list's unwrapped items, the
/// `volatile`/`allowzero`/alignment hint when it would take the slice as a
/// plain `[]const T`, else `hint`. A string is a slice of bytes but rules
/// treat it as one value, so when a rule that takes lists (its `accepts`
/// takes `[]const u32`) rejects a string and no hint follows, ` (a string)`
/// follows the type.
pub fn typeError(comptime rule: *const Rule, comptime T: type, comptime where: []const u8, comptime expects: []const u8, comptime accepts: fn (comptime type) bool, comptime hint: ?[]const u8) noreturn {
    @compileError(typeErrorText(rule, T, where, expects, accepts, hint));
}

/// The text of `typeError`, separate so that tests can read it.
pub fn typeErrorText(comptime rule: *const Rule, comptime T: type, comptime where: []const u8, comptime expects: []const u8, comptime accepts: fn (comptime type) bool, comptime hint: ?[]const u8) []const u8 {
    @setEvalBranchQuota(eval_quota);
    var extra: ?[]const u8 = hint;
    if (isU8Array(T) and accepts([]const u8)) {
        extra = hints.u8_array;
    } else if (ListChild(T)) |Item| {
        if (accepts(Unwrap(Item))) extra = hints.useEach(rule.*);
    } else if (plainSlice(T)) |Plain| {
        if (accepts(Plain)) extra = hints.odd_slice;
    }
    const note = if (extra == null and isString(T) and accepts([]const u32)) " (a string)" else "";
    return "validator: " ++ where ++ ": " ++ @tagName(rule.kind) ++ " expects " ++ expects ++ ", field is " ++ @typeName(T) ++ note ++
        (if (extra) |h| "; " ++ h else "");
}

/// `[]const T` for a slice of `T` that its `volatile`, `allowzero` or
/// alignment keeps from being a string or a list, else null. A slice outside
/// the default address space gets null too: the hint names only the other
/// three, and the type in the error shows the address space.
fn plainSlice(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and !isString(T) and !isListSlice(T) and
            (p.attrs.@"addrspace" orelse .generic) == .generic) []const p.child else null,
        else => null,
    };
}

/// A declaration error about one rule: `validator: <where>: <label><text>`.
pub fn ruleError(comptime rule: *const Rule, comptime where: []const u8, comptime text: []const u8) noreturn {
    @compileError(ruleErrorText(rule, where, text));
}

/// The text of `ruleError`, separate so that tests can read it.
pub fn ruleErrorText(comptime rule: *const Rule, comptime where: []const u8, comptime text: []const u8) []const u8 {
    return "validator: " ++ where ++ ": " ++ rule.label() ++ text;
}

// ------------------------------------------------------------------ string rules

/// The field-type check of a rule that takes strings only.
pub fn fitsString(comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void {
    if (stringProblem(rule, T, where, null)) |text| @compileError(text);
}

/// The declaration error of a rule that takes strings only on the unwrapped
/// field type `T`, or null: the field is a string. The error is
/// `<kind> expects a string, field is <T>` with the hints of `typeError`;
/// `hint` follows when none of those applies.
pub fn stringProblem(comptime rule: *const Rule, comptime T: type, comptime where: []const u8, comptime hint: ?[]const u8) ?[]const u8 {
    if (isString(T)) return null;
    return typeErrorText(rule, T, where, "a string", isString, hint);
}

/// A rule value for string fields that passes when `predicate` accepts the
/// value, as `v.json` passes when `v.isJson` does: no parameters, no
/// precondition, and the rule and its predicate always agree.
pub fn predicateRule(comptime kind: Kind, comptime message: []const u8, comptime predicate: fn ([]const u8) bool) Rule {
    return predicateRuleFits(kind, message, predicate, fitsString);
}

/// `predicateRule` with the field-type check `fits` instead of `fitsString`,
/// for a rule whose error adds a hint of its own (`v.digits` on a number
/// field: the field is already a number).
pub fn predicateRuleFits(comptime kind: Kind, comptime message: []const u8, comptime predicate: fn ([]const u8) bool, comptime fits: fn (comptime rule: *const Rule, comptime T: type, comptime where: []const u8) void) Rule {
    return define(kind, .{
        .message = message,
        .fits = fits,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return passIf(predicate(value.*));
            }
        }.eval,
    });
}

/// Every byte of `s` is an ASCII hex digit: `0-9`, `a-f` or `A-F`. True
/// for "": a predicate checks the length first.
pub fn allHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Every byte of `s` is an ASCII digit `0-9`. True for "": a predicate
/// checks the length first.
pub fn allDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "allHex and allDigits take the ASCII digits of their base and nothing else" {
    const t = std.testing;
    try t.expect(allHex("0123456789abcdefABCDEF"));
    try t.expect(allHex(""));
    inline for (.{ "g", "G", "/", ":", "@", "`", " ", "0x1f", "\xff", "\x00" }) |s| try t.expect(!allHex(s));
    try t.expect(allDigits("0123456789"));
    try t.expect(allDigits(""));
    inline for (.{ "a", "/", ":", " 1", "1.5", "-1", "\xd9\xa1", "\x00" }) |s| try t.expect(!allDigits(s));
}

// ------------------------------------------------------------------ number parameters

/// The range of an integer type as error texts show it: `0..255` for u8.
pub fn intRange(comptime T: type) []const u8 {
    return std.fmt.comptimePrint("{d}..{d}", .{ std.math.minInt(T), std.math.maxInt(T) });
}

/// The comptime number `x` as a value of the numeric field type `T`:
/// integers exactly, floats rounded to the nearest value of `T`, as a
/// decoder rounds the input. Call it at comptime, for a parameter that
/// `numberParamProblem` accepted for `T`.
pub fn numberAs(comptime T: type, comptime x: anytype) T {
    return switch (@typeInfo(T)) {
        .int => @intCast(x),
        .float => switch (@typeInfo(@TypeOf(x))) {
            .comptime_int, .int => @floatFromInt(x),
            else => @floatCast(x),
        },
        else => @compileError("validator: internal: numberAs needs a number type, got " ++ @typeName(T)),
    };
}

/// The parameter `x` as a value of the field type `T`: a number as
/// `numberAs` converts it, a tag as the tag of `T` with its name, a bool or
/// a string as it is. Call it at comptime, for a parameter that the rule's
/// checks accepted for `T`.
pub fn valueAs(comptime T: type, comptime x: anytype) T {
    return switch (@typeInfo(T)) {
        .int, .float => numberAs(T, x),
        .@"enum" => @field(T, tagName(x) orelse @compileError("validator: internal: " ++ unnamedTag(x) ++ " has no tag name")),
        else => x,
    };
}

/// The kind of a parameter of type `X` in error texts: `an integer`,
/// `a float (f64)`, `a bool`, `an enum tag`, `a string`, `a list`, or the
/// type's name for anything else.
pub fn describeValueType(comptime X: type) []const u8 {
    return switch (valueKind(X)) {
        .int => "an integer",
        .float => "a float (" ++ @typeName(X) ++ ")",
        .bool => "a bool",
        .tag => "an enum tag",
        .string => "a string",
        .list => "a list",
        .other => @typeName(X),
    };
}

/// Why the parameter `x` cannot be compared with values of the numeric field
/// type `T`, as the text after the rule's label (`: 300 is outside u8
/// (0..255)`), or null. An integer field takes an integer within its type;
/// any other parameter gets `use_integer` as the hint. A float field takes a
/// number that stays finite in it and, unless zero, does not round to 0, and
/// an integer it holds exactly; anything else gets `use a number`. A typed
/// float narrower than the field (`@as(f32, 0.1)` on f64) is taken only when
/// its value shows the same in the field type: its exact value there,
/// 0.10000000149011612, is what the rule would compare with. On a
/// `c_longdouble` field this depends on the target. `outside` follows the
/// texts about a parameter outside the type (`; the rule would never pass`).
/// The parameter is shown as it is written.
pub fn numberParamProblem(comptime x: anytype, comptime T: type, comptime use_integer: []const u8, comptime outside: []const u8) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    const X = @TypeOf(x);
    const shown = renderArg(x);
    const kind = comptime valueKind(X);
    switch (@typeInfo(T)) {
        .int => {
            if (kind != .int) return ": " ++ shown ++ " is " ++ describeValueType(X) ++ ", field is " ++ @typeName(T) ++ "; " ++ use_integer;
            const n: comptime_int = x;
            if (n < std.math.minInt(T) or n > std.math.maxInt(T))
                return ": " ++ shown ++ " is outside " ++ @typeName(T) ++ " (" ++ intRange(T) ++ ")" ++ outside;
            return null;
        },
        .float => switch (kind) {
            .int => {
                const f: T = @floatFromInt(x);
                if (std.math.isInf(f)) return ": " ++ shown ++ " is outside the finite range of " ++ @typeName(T) ++ outside;
                const nearest: comptime_int = @intFromFloat(f);
                if (nearest != x)
                    return ": " ++ shown ++ " is not exactly representable in " ++ @typeName(T) ++ std.fmt.comptimePrint(" (nearest: {d})", .{nearest});
                return null;
            },
            .float => {
                const f: T = @floatCast(x);
                if (std.math.isInf(f)) return ": " ++ shown ++ " is outside the finite range of " ++ @typeName(T) ++ outside;
                if (f == 0 and x != 0) return ": " ++ shown ++ " rounds to 0 in " ++ @typeName(T);
                // A narrower typed float widens exactly, so the rule would
                // compare with a value whose text differs from the one shown.
                if (X != comptime_float and std.math.floatFractionalBits(X) < std.math.floatFractionalBits(T)) {
                    const widened = renderValue(f);
                    if (!std.mem.eql(u8, widened, shown))
                        return ": " ++ shown ++ " is " ++ describeValueType(X) ++ ", " ++ widened ++ " in " ++ @typeName(T) ++ "; write it as a literal or as " ++ @typeName(T);
                }
                return null;
            },
            else => return ": " ++ shown ++ " is " ++ describeValueType(X) ++ ", field is " ++ @typeName(T) ++ "; use a number",
        },
        else => @compileError("validator: internal: numberParamProblem needs a number field type, got " ++ @typeName(T)),
    }
}

// ------------------------------------------------------------------ tag parameters

/// The tags of the enum `E` by name, as `tagIdentifier` writes them, joined
/// by `, `: `admin, user, guest`.
pub fn tagList(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".field_names, 0..) |tag, i| out = out ++ (if (i == 0) "" else ", ") ++ tagIdentifier(tag);
        return out;
    }
}

/// Why the tag parameter `x` (an enum literal or a named enum value) does
/// not stand for a tag of the enum field type `E`, as the text after the
/// rule's label (`: Role has no tag root; tags: admin, user, guest`), or
/// null. A value of another enum type is named with its type, even when `E`
/// has a tag of the same name; a literal must name a tag of `E`, and the
/// text lists the tags `E` has. Names are written as `tagIdentifier` writes
/// them. Constructors reject unnamed values first.
pub fn tagProblem(comptime x: anytype, comptime E: type) ?[]const u8 {
    return tagProblemOf(x, E, "the field is ");
}

/// `tagProblem` for a tag listed against the items of a list, whose item
/// type is the enum `E`: a value of another enum type says `the items are`.
pub fn itemTagProblem(comptime x: anytype, comptime E: type) ?[]const u8 {
    return tagProblemOf(x, E, "the items are ");
}

/// `tagProblem` with `holder` naming what has the type `E`.
fn tagProblemOf(comptime x: anytype, comptime E: type, comptime holder: []const u8) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    const X = @TypeOf(x);
    if (@typeInfo(X) == .@"enum" and X != E)
        return ": " ++ renderArg(x) ++ " is a tag of " ++ @typeName(X) ++ ", " ++ holder ++ @typeName(E);
    const name = tagName(x) orelse @compileError("validator: internal: " ++ unnamedTag(x) ++ " has no tag name");
    if (@hasField(E, name)) return null;
    const tags = tagList(E);
    return ": " ++ @typeName(E) ++ " has no tag " ++ tagIdentifier(name) ++ if (tags.len == 0) "" else "; tags: " ++ tags;
}

/// Enums for the tag tests: a field's enum, another enum with a tag of the
/// same name, and an enum without named tags.
const TestRole = enum { admin, user, guest };
const TestColor = enum { red, admin };
const TestNoTags = enum(u8) { _ };

test "an enum's tags are listed by name, joined by commas" {
    const expect = std.testing.expectEqualStrings;
    try expect("admin, user, guest", comptime tagList(TestRole));
    try expect("a, b", comptime tagList(TestOpen));
    try expect("", comptime tagList(TestNoTags));
    // Names are written as Zig source writes them.
    try expect("@\"error\", @\"a\\nb\", plain", comptime tagList(TestQuoted));
}

test "a tag parameter names a tag of the field's enum; a value of another enum is named with its type" {
    const expect = std.testing.expectEqualStrings;
    try std.testing.expectEqual(null, comptime tagProblem(.admin, TestRole));
    try std.testing.expectEqual(null, comptime tagProblem(TestRole.guest, TestRole));
    try std.testing.expectEqual(null, comptime tagProblem(.b, TestOpen));
    try expect(": core.TestRole has no tag root; tags: admin, user, guest", comptime tagProblem(.root, TestRole).?);
    try expect(": .red is a tag of core.TestColor, the field is core.TestRole", comptime tagProblem(TestColor.red, TestRole).?);
    // The type decides before the name: TestRole has a tag admin too.
    try expect(": .admin is a tag of core.TestColor, the field is core.TestRole", comptime tagProblem(TestColor.admin, TestRole).?);
    // An enum without named tags has no tags to list.
    try expect(": core.TestNoTags has no tag a", comptime tagProblem(.a, TestNoTags).?);
    // Names are written as Zig source writes them.
    try expect(": core.TestQuoted has no tag @\"a b\"; tags: @\"error\", @\"a\\nb\", plain", comptime tagProblem(.@"a b", TestQuoted).?);
    try std.testing.expectEqual(null, comptime tagProblem(.@"error", TestQuoted));
    // Against the items of a list, a value of another enum names the items' type.
    try expect(": .red is a tag of core.TestColor, the items are core.TestRole", comptime itemTagProblem(TestColor.red, TestRole).?);
    try expect(": core.TestRole has no tag root; tags: admin, user, guest", comptime itemTagProblem(.root, TestRole).?);
    try std.testing.expectEqual(null, comptime itemTagProblem(.admin, TestRole));
}

test "a checked parameter converts to the field type: numbers as numberAs does, bools as they are, tags by name" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 5), comptime valueAs(u8, 5));
    try t.expectEqual(@as(i64, 7), comptime valueAs(i64, @as(u8, 7)));
    try t.expectEqual(@as(f32, 0.1), comptime valueAs(f32, 0.1));
    try t.expectEqual(@as(f64, 2), comptime valueAs(f64, 2));
    try t.expectEqual(true, comptime valueAs(bool, true));
    try t.expectEqual(TestRole.guest, comptime valueAs(TestRole, .guest));
    try t.expectEqual(TestRole.guest, comptime valueAs(TestRole, TestRole.guest));
    try t.expectEqual(TestOpen.b, comptime valueAs(TestOpen, .b));
    try t.expectEqualStrings("abc", comptime valueAs([]const u8, "abc"));
}

// ------------------------------------------------------------------ value lists

/// The kind of the values a list parameter holds (`oneOf`, `noneOf`,
/// `containsAll`, `containsNone`): one kind per list.
pub const ListKind = enum {
    string,
    tag,
    int,
    bool,

    /// The kind as error texts name it: `strings`, `enum tags`.
    pub fn plural(comptime kind: ListKind) []const u8 {
        return switch (kind) {
            .string => "strings",
            .tag => "enum tags",
            .int => "integers",
            .bool => "bools",
        };
    }
};

/// A list parameter that `analyzeList` accepted.
pub const ValueList = struct {
    kind: ListKind,
    len: usize,
    /// The values as messages show them, joined by `, `: the text of
    /// `{values}`.
    text: []const u8,
    /// The list as compile errors show it: `.{ "a", "b" }`, cut after 72
    /// bytes.
    args: []const u8,
};

/// What a list rule accepts beyond a list of strings, enum tags or integers.
pub const ListOptions = struct {
    /// Bools may be listed; otherwise a listed bool is an error that points
    /// to `v.equals` and `v.notEquals`.
    allow_bool: bool = false,
    /// The error text for a listed `""` (after `<call>: `), or null when
    /// `""` may be listed.
    empty_string: ?[]const u8 = null,
};

/// Checks the list parameter of the rule `name` (`oneOf`) at the user's
/// call and describes it: a problem stops compilation with the text of
/// `listProblem`.
pub fn analyzeList(comptime name: []const u8, comptime values: anytype, comptime options: ListOptions) ValueList {
    @setEvalBranchQuota(eval_quota);
    if (listProblem(name, values, options)) |text| @compileError(text);
    return .{
        .kind = listKind(@TypeOf(values[0])) orelse @compileError("validator: internal: an accepted list has values of no list kind"),
        .len = values.len,
        .text = renderValue(values),
        .args = renderArg(values),
    };
}

/// The error of the call `name(values)` of a list rule, or null. `values`
/// is a tuple or an array `[N]T` (not a pointer to an array or a tuple, not
/// a slice) of at least one value; all of them strings, all enum tags or all
/// integers (or all bools, when `options` allows them); strings in valid
/// UTF-8 (and not empty, when `options` says so), tags named, and no value
/// listed twice: strings by bytes, tags by name, integers by value. The
/// values are checked left to right and the first problem wins.
pub fn listProblem(comptime name: []const u8, comptime values: anytype, comptime options: ListOptions) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(eval_quota);
        const V = @TypeOf(values);
        const head = "validator: " ++ name ++ "(" ++ renderArg(values) ++ "): ";
        if (valueKind(V) != .list) {
            // The generated type of a tuple repeats every value: name it instead.
            const got = if (isTuplePointer(V))
                "a pointer to a tuple; " ++ hints.tuple_pointer
            else
                @typeName(V) ++ if (isArrayPointer(V)) "; pass the array itself, not a pointer to it" else "";
            return head ++ "expected a tuple or an array of values, e.g. .{ \"a\", \"b\" }, got " ++ got;
        }
        if (values.len == 0) return head ++ "the list is empty";
        const duplicate = firstDuplicate(values);
        var first: ListKind = undefined;
        for (0..values.len) |i| {
            const item = values[i];
            const X = @TypeOf(item);
            const kind = listKind(X) orelse return head ++ switch (valueKind(X)) {
                .float => "floats cannot be listed: exact float equality is fragile",
                else => "cannot list a value of type " ++ @typeName(X),
            };
            if (kind == .bool and !options.allow_bool) return head ++ "bools cannot be listed; " ++ hints.use_equals_or_not_equals;
            if (i == 0) {
                first = kind;
            } else if (kind != first) {
                return head ++ "the list mixes " ++ first.plural() ++ " and " ++ kind.plural();
            }
            switch (kind) {
                .tag => if (tagName(item) == null) return head ++ renderArg(item) ++ " is not a named tag of " ++ @typeName(X),
                .string => {
                    if (item.len == 0) {
                        if (options.empty_string) |text| return head ++ text;
                    }
                    if (!std.unicode.utf8ValidateSlice(item)) return head ++ renderArg(item) ++ " is not valid UTF-8";
                },
                .int, .bool => {},
            }
            if (duplicate == i) return head ++ renderArg(item) ++ " is listed twice";
        }
        return null;
    }
}

/// The index of the first listed value that equals an earlier one (strings
/// by bytes, tags by name, integers and bools by value), or null. A value of
/// no list kind and an unnamed tag have no key and are skipped:
/// `listProblem` stops at them first. The keys are sorted, so the check
/// takes O(n log n) comparisons and a list of thousands of values stays
/// within the comptime branch quota.
fn firstDuplicate(comptime values: anytype) ?usize {
    comptime {
        @setEvalBranchQuota(eval_quota);
        const Entry = struct { key: []const u8, index: usize };
        var entries: [values.len]Entry = undefined;
        var n: usize = 0;
        for (0..values.len) |i| {
            const item = values[i];
            // The kind prefix keeps values of different kinds apart.
            entries[n] = .{ .index = i, .key = switch (listKind(@TypeOf(item)) orelse continue) {
                .string => "s" ++ item,
                .tag => "t" ++ (tagName(item) orelse continue),
                .int => std.fmt.comptimePrint("i{d}", .{item}),
                .bool => if (item) "b1" else "b0",
            } };
            n += 1;
        }
        // `for (1..n)` below needs n >= 1; a list without two keys has no duplicate.
        if (n < 2) return null;
        std.mem.sortUnstable(Entry, entries[0..n], {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return switch (std.mem.order(u8, a.key, b.key)) {
                    .lt => true,
                    .gt => false,
                    .eq => a.index < b.index,
                };
            }
        }.lessThan);
        // Equal keys are adjacent and ordered by index: the second of each run
        // repeats an earlier value, and the smallest such index comes first.
        var found: ?usize = null;
        for (1..n) |e| {
            if (std.mem.eql(u8, entries[e - 1].key, entries[e].key) and (found == null or entries[e].index < found.?))
                found = entries[e].index;
        }
        return found;
    }
}

/// The list kind of a value of type `X`, or null for a value no list holds.
fn listKind(comptime X: type) ?ListKind {
    return switch (valueKind(X)) {
        .string => .string,
        .tag => .tag,
        .int => .int,
        .bool => .bool,
        .float, .list, .other => null,
    };
}

/// A single-item pointer to an array of other items than u8 (a pointer to
/// `[N]u8` is a string): `&allowed` where the array itself was meant.
fn isArrayPointer(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child != u8,
        else => false,
    };
}

/// A single-item pointer to a tuple: `&.{ ... }` where the tuple was meant.
fn isTuplePointer(comptime V: type) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| p.size == .one and isTuple(p.child),
        else => false,
    };
}

/// The values of a checked list as an array of the field type `T`: `[]const
/// u8` for strings, an enum (each tag by its name) or an integer type, for
/// the run-time comparisons. Call it at comptime, for a list that the
/// rule's checks accepted for `T`.
pub fn listAs(comptime T: type, comptime values: anytype) [values.len]T {
    comptime {
        @setEvalBranchQuota(eval_quota);
        var out: [values.len]T = undefined;
        for (&out, 0..) |*slot, i| slot.* = valueAs(T, values[i]);
        return out;
    }
}

test "a list kind is named in the plural" {
    const expect = std.testing.expectEqualStrings;
    try expect("strings", comptime ListKind.string.plural());
    try expect("enum tags", comptime ListKind.tag.plural());
    try expect("integers", comptime ListKind.int.plural());
    try expect("bools", comptime ListKind.bool.plural());
}

test "a checked list keeps its kind, its length, its values as messages show them and its call as written" {
    const t = std.testing;
    const strings = comptime analyzeList("oneOf", .{ "a", "" }, .{});
    try t.expectEqual(ListKind.string, strings.kind);
    try t.expectEqual(2, strings.len);
    try t.expectEqualStrings("a, \"\"", strings.text);
    try t.expectEqualStrings(".{ \"a\", \"\" }", strings.args);
    const tags = comptime analyzeList("oneOf", .{ .admin, TestRole.user }, .{});
    try t.expectEqual(ListKind.tag, tags.kind);
    try t.expectEqualStrings("admin, user", tags.text);
    try t.expectEqualStrings(".{ .admin, .user }", tags.args);
    // An array is a list too, [N]u8 included: its items are integers.
    const bytes = comptime analyzeList("oneOf", [_]u8{ 1, 2 }, .{});
    try t.expectEqual(ListKind.int, bytes.kind);
    try t.expectEqualStrings("1, 2", bytes.text);
    try t.expectEqualStrings(".{ 1, 2 }", bytes.args);
    const one = comptime analyzeList("oneOf", [_][]const u8{"x"}, .{});
    try t.expectEqual(1, one.len);
    try t.expectEqualStrings(".{\"x\"}", one.args);
    const bools = comptime analyzeList("containsAll", .{ true, false }, .{ .allow_bool = true });
    try t.expectEqual(ListKind.bool, bools.kind);
    try t.expectEqualStrings("true, false", bools.text);
}

test "the list options allow bools and reject the empty string with the rule's own text" {
    const expect = std.testing.expectEqualStrings;
    try std.testing.expectEqual(null, comptime listProblem("containsAll", .{true}, .{ .allow_bool = true }));
    try expect("validator: oneOf(.{true}): bools cannot be listed; use v.equals or v.notEquals", comptime listProblem("oneOf", .{true}, .{}).?);
    try std.testing.expectEqual(null, comptime listProblem("oneOf", .{""}, .{}));
    try expect("validator: noneOf(.{\"\"}): no empty string", comptime listProblem("noneOf", .{""}, .{ .empty_string = "no empty string" }).?);
    // Mixed with bools, the first kind is named first.
    try expect("validator: containsAll(.{ true, 1 }): the list mixes bools and integers", comptime listProblem("containsAll", .{ true, 1 }, .{ .allow_bool = true }).?);
    try expect("validator: containsAll(.{ true, false, true }): true is listed twice", comptime listProblem("containsAll", .{ true, false, true }, .{ .allow_bool = true }).?);
}

/// `n` codes of the same width, `"SKU-000000"` to `"SKU-<n - 1>"`: a long list
/// of strings.
fn testCodes(comptime n: usize) [n][]const u8 {
    comptime {
        @setEvalBranchQuota(eval_quota);
        var out: [n][]const u8 = undefined;
        for (&out, 0..) |*slot, i| slot.* = std.fmt.comptimePrint("SKU-{d:0>6}", .{i});
        return out;
    }
}

test "a list of thousands of values is checked within the comptime branch quota, a late duplicate included" {
    const t = std.testing;
    try t.expectEqual(null, comptime listProblem("oneOf", testCodes(1400), .{}));
    try t.expectEqual(null, comptime listProblem("noneOf", testCodes(2000), .{}));
    try t.expectEqualStrings(
        "validator: oneOf(.{ \"SKU-000000\", \"SKU-000001\", \"SKU-000002\", \"SKU-000003\", \"SKU-000004\", ... }): \"SKU-001999\" is listed twice",
        comptime listProblem("oneOf", testCodes(2000) ++ [_][]const u8{"SKU-001999"}, .{}).?,
    );
    // The value reported is the first one that repeats an earlier value.
    try t.expectEqualStrings("validator: oneOf(.{ \"a\", \"b\", \"b\", \"a\" }): \"b\" is listed twice", comptime listProblem("oneOf", .{ "a", "b", "b", "a" }, .{}).?);
    try t.expectEqualStrings("validator: oneOf(.{ 7, -7, 7, 7 }): 7 is listed twice", comptime listProblem("oneOf", .{ 7, -7, @as(i8, 7), 7 }, .{}).?);
}

test "a checked list converts to an array of the field type: strings, tags by name, integers" {
    const t = std.testing;
    const strings = comptime listAs([]const u8, .{ "a", @as([]const u8, "bc") });
    try t.expectEqual(2, strings.len);
    try t.expectEqualStrings("a", strings[0]);
    try t.expectEqualStrings("bc", strings[1]);
    const tags = comptime listAs(TestRole, .{ .guest, TestRole.admin });
    try t.expectEqual(TestRole.guest, tags[0]);
    try t.expectEqual(TestRole.admin, tags[1]);
    const ints = comptime listAs(i64, .{ @as(u8, 255), -1, std.math.minInt(i64) });
    try t.expectEqual(@as(i64, 255), ints[0]);
    try t.expectEqual(@as(i64, -1), ints[1]);
    try t.expectEqual(@as(i64, std.math.minInt(i64)), ints[2]);
    const from_array = comptime listAs(u16, [_]u8{ 7, 9 });
    try t.expectEqual(@as(u16, 9), from_array[1]);
}

// ------------------------------------------------------------------ entries

/// An entry of `field_rules`, or the argument of `each`, taken apart: its
/// outside name, its transforms and its rules, each in the order written.
pub const EntryParts = struct {
    name: ?[]const u8 = null,
    transforms: []const Transform = &.{},
    rules: []const Rule = &.{},
    /// The first element out of its place: the declaration check of the
    /// field reports it with the field's path.
    problem: ?EntryProblem = null,
};

/// An element out of its place. The order is at most one name, then the
/// transforms, then the rules (`each` among them, last).
pub const EntryProblem = union(enum) {
    /// A name after a transform or a rule.
    name_not_first,
    /// A second name.
    name_twice,
    /// A name in the argument of `each`: list items have none.
    name_in_each,
    /// A transform after a rule: the labels of both.
    transform_after_rule: struct { rule: []const u8, transform: []const u8 },
};

/// The error of `problem` in the entry at `where`.
pub fn entryProblemText(comptime problem: EntryProblem, comptime where: []const u8) []const u8 {
    return "validator: " ++ where ++ ": " ++ switch (problem) {
        .name_not_first => "rename comes first: name, then transforms, then rules",
        .name_twice => "rename appears twice; a field has one outside name",
        .name_in_each => "rename inside each: list items have no name",
        .transform_after_rule => |p| p.rule ++ " is a rule; transforms (" ++ p.transform ++ ") must come before the rules",
    };
}

/// One element, or a tuple of elements, taken apart; `in_each` for the
/// argument of `each`, where any name is a problem. An element is a name
/// (`v.rename`), a transform or a rule; anything else stops compilation,
/// and `where` (`<Type>.field_rules.<field>` or `each(...)`) starts the
/// error. A nested tuple is not flattened: it is an item that is not an
/// element. A problem of the order is kept in `problem`, not raised.
pub fn entryParts(comptime value: anytype, comptime where: []const u8, comptime in_each: bool) EntryParts {
    comptime {
        @setEvalBranchQuota(eval_quota);
        var entry: EntryParts = .{};
        const V = @TypeOf(value);
        if (isElement(V)) {
            addElement(&entry, value, in_each);
            return entry;
        }
        if (isTuple(V)) {
            for (0..value.len) |i| {
                if (!isElement(@TypeOf(value[i]))) notARule(value[i], where, std.fmt.comptimePrint("item {d} of the tuple is ", .{i}));
                addElement(&entry, value[i], in_each);
            }
            return entry;
        }
        notARule(value, where, if (in_each) "expected a transform or a rule, or a tuple of them, got " else "expected a name, a transform or a rule, or a tuple of them, got ");
    }
}

/// A name, a transform or a rule.
fn isElement(comptime E: type) bool {
    return E == Rename or E == Transform or E == Rule;
}

/// Adds `element` to `entry`, and its problem when it is the first one.
fn addElement(comptime entry: *EntryParts, comptime element: anytype, comptime in_each: bool) void {
    const E = @TypeOf(element);
    if (E == Rename) {
        if (entry.problem == null) {
            entry.problem = if (in_each) .name_in_each else if (entry.name != null) .name_twice else if (entry.transforms.len + entry.rules.len > 0) .name_not_first else null;
        }
        if (entry.name == null) entry.name = element.name;
    } else if (E == Transform) {
        if (entry.problem == null and entry.rules.len > 0)
            entry.problem = .{ .transform_after_rule = .{ .rule = entry.rules[entry.rules.len - 1].label(), .transform = element.label() } };
        entry.transforms = entry.transforms ++ &[_]Transform{element};
    } else {
        entry.rules = entry.rules ++ &[_]Rule{element};
    }
}

/// The type of a `field_rules` declaration that the walker reads: a struct
/// literal, or `.{}`. A rule, a transform or a name given as the whole
/// declaration is not one.
pub fn isFieldRulesTable(comptime R: type) bool {
    if (R == Rule or R == Transform or R == Rename) return false;
    return switch (@typeInfo(R)) {
        .@"struct" => |s| !s.is_tuple or s.field_names.len == 0,
        else => false,
    };
}

/// Raises the error for a value that is not an element. A built-in
/// predicate or constructor (a function that returns a `Rule`, a `Transform`
/// or a name) that `root.zig` exports is named, without the tuple item
/// prefix: a predicate gets the rule to use instead, a constructor the call
/// it needs. Any other function gets the prefixed text with a hint: a
/// function of your own shaped like a transform (see `isTransformShaped`)
/// to wrap it in `v.transformWith`, any other one, `v.check` and the other
/// entry points included, to wrap it in `v.custom`. A tuple, a pointer to a
/// tuple and a struct literal are named by what they are, with a hint, since
/// their type names are long or generated; any other value is named by its
/// type (`core.Rule` for a rule of another copy of the package).
fn notARule(comptime value: anytype, comptime where: []const u8, comptime prefix: []const u8) noreturn {
    const V = @TypeOf(value);
    if (@typeInfo(V) == .@"fn") {
        const exported = constructorName(value);
        if (exported) |name| {
            if (exportedPredicateRule(root, name)) |rule|
                @compileError("validator: " ++ where ++ ": " ++ hints.predicateAsRule(name, rule, @TypeOf(@field(root, rule))));
            const R = @typeInfo(V).@"fn".return_type orelse void;
            if (R == Rule or R == Transform or R == Rename)
                @compileError("validator: " ++ where ++ ": " ++ hints.mustBeCalled(name, V));
        }
        const hint = if (exported == null and isTransformShaped(V)) hints.wrap_transform else hints.wrap_predicate;
        @compileError("validator: " ++ where ++ ": " ++ prefix ++ @typeName(V) ++ "; " ++ hint);
    }
    if (isTuple(V)) @compileError("validator: " ++ where ++ ": " ++ prefix ++ "a tuple; " ++ hints.nested_tuple);
    if (isTuplePointer(V)) @compileError("validator: " ++ where ++ ": " ++ prefix ++ "a pointer to a tuple; " ++ hints.tuple_pointer);
    if (isAnonymous(V)) @compileError("validator: " ++ where ++ ": " ++ prefix ++ "a struct literal; " ++ hints.struct_literal);
    @compileError("validator: " ++ where ++ ": " ++ prefix ++ @typeName(V));
}

fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
}

/// A function of two parameters whose first is `std.mem.Allocator`: the
/// shape of the function that `v.transformWith` takes, whatever the rest of
/// its signature.
fn isTransformShaped(comptime F: type) bool {
    const f = @typeInfo(F).@"fn";
    if (f.param_types.len != 2) return false;
    return (f.param_types[0] orelse return false) == std.mem.Allocator;
}

/// A struct declared in place: a field type (`address: struct { ... }`) or
/// the type of a struct literal (`.{ .city = v.notEmpty }`). Zig names it
/// after its parent with a generated suffix (`users.Request__struct_1234`,
/// `users.Request.field_rules__struct_1234`), and a struct declared in place
/// inside that one gets a second suffix, so the last suffix decides. The
/// suffix is a convention of the compiler, not of the language; the fixtures
/// `anonymous_struct_label` and `entry_struct_literal` fail if a Zig release
/// changes it.
pub fn isAnonymous(comptime T: type) bool {
    const name = @typeName(T);
    const at = std.mem.findLast(u8, name, "__struct_") orelse return false;
    const digits = name[at + "__struct_".len ..];
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The rule of a built-in predicate (`isDate` -> `date`, `isBase64Url` ->
/// `base64Url`), or null.
fn predicateRuleName(comptime name: []const u8) ?[]const u8 {
    if (name.len < 3 or !std.mem.startsWith(u8, name, "is") or !std.ascii.isUpper(name[2])) return null;
    const rule = [1]u8{std.ascii.toLower(name[2])} ++ name[3..];
    for (kinds) |row| {
        if (std.mem.eql(u8, row.name, rule)) return row.name;
    }
    return null;
}

/// The rule of the built-in predicate `name` when `ns` (`root.zig` in the
/// library) exports that rule, or null: a predicate exported before its rule
/// gets the text of any other function.
fn exportedPredicateRule(comptime ns: type, comptime name: []const u8) ?[]const u8 {
    const rule = predicateRuleName(name) orelse return null;
    return if (@hasDecl(ns, rule)) rule else null;
}

/// The name under which `root.zig` exports the function `f` (`v.each` ->
/// "each"), or null. Functions are compared by value at compile time.
fn constructorName(comptime f: anytype) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    const F = @TypeOf(f);
    for (@typeInfo(root).@"struct".decl_names) |decl| {
        if (@TypeOf(@field(root, decl)) == F and @field(root, decl) == f) return decl;
    }
    return null;
}

/// The rules that apply to the value itself (all but a trailing `each`).
pub fn ownRules(comptime rules: []const Rule) []const Rule {
    if (rules.len > 0 and rules[rules.len - 1].kind == .each) return rules[0 .. rules.len - 1];
    return rules;
}

/// The item rules of a trailing `each`, or none.
pub fn itemRules(comptime rules: []const Rule) []const Rule {
    if (rules.len > 0 and rules[rules.len - 1].kind == .each) return rules[rules.len - 1].inner;
    return &.{};
}

/// The item transforms of a trailing `each`, or none.
pub fn itemTransforms(comptime rules: []const Rule) []const Transform {
    if (rules.len > 0 and rules[rules.len - 1].kind == .each) return rules[rules.len - 1].item_transforms;
    return &.{};
}

/// A trailing `each`, or one nested in it, declares item transforms.
pub fn hasItemTransforms(comptime rules: []const Rule) bool {
    return itemTransforms(rules).len > 0 or (itemRules(rules).len > 0 and hasItemTransforms(itemRules(rules)));
}

/// `rules` check something: a rule of the value itself, or one for the
/// items at some depth of its `each`. An `each` with transforms alone
/// (`v.each(v.trim)`, `v.each(v.each(v.trim))`) checks nothing.
pub fn hasCheckRules(comptime rules: []const Rule) bool {
    return ownRules(rules).len > 0 or (itemRules(rules).len > 0 and hasCheckRules(itemRules(rules)));
}

/// The declaration check of one value's transforms: each one's `fits`
/// against `T`, the unwrapped field or item type, in tuple order.
pub fn checkTransforms(comptime transforms: []const Transform, comptime T: type, comptime where: []const u8) void {
    for (transforms) |*t| t.fits(t, T, where);
}

/// The declaration check of one value's rules: at most one `each`, placed
/// last; then, in tuple order, each rule's `fits` against `T`, the unwrapped
/// field or item type, and the size of its default message; then the
/// `check_list` of each rule that has one; then no two rules whose bounds on
/// one measure let no value pass.
pub fn checkRuleList(comptime rules: []const Rule, comptime T: type, comptime where: []const u8) void {
    @setEvalBranchQuota(eval_quota);
    var each_count: usize = 0;
    for (rules) |rule| {
        if (rule.kind == .each) each_count += 1;
    }
    if (each_count > 1) @compileError("validator: " ++ where ++ ": each appears twice; " ++ hints.one_each);
    if (each_count == 1 and rules[rules.len - 1].kind != .each) @compileError("validator: " ++ where ++ ": each must be the last rule");
    for (rules) |*rule| {
        rule.fits(rule, T, where);
        if (defaultMessageProblem(rule, where)) |text| @compileError(text);
    }
    for (rules, 0..) |*rule, i| {
        if (rule.check_list) |check| check(rule, rules, i, T, where);
    }
    if (contradictionText(rules, T, where)) |text| @compileError(text);
}

/// Stand-in rules for the self-tests below; the real rules live in the rule
/// files and are tested there.
const test_rules = struct {
    fn fitsAnything(comptime _: *const Rule, comptime _: type, comptime _: []const u8) void {}

    fn evalPositive(value: anytype) Outcome {
        return passIf(value.* > 0);
    }

    fn acceptsList(comptime T: type) bool {
        return ListChild(T) != null;
    }

    fn acceptsStringOrSlice(comptime T: type) bool {
        return isString(T) or isListSlice(T);
    }

    const positive = define(.positive, .{
        .message = "must be greater than 0",
        .precondition = preconditions.finite,
        .fits = fitsAnything,
        .eval = evalPositive,
    });
    const min_items = define(.min_items, .{ .message = "must have at least 3 items", .args = "3", .fits = fitsAnything, .eval = evalPositive });
    const custom = define(.custom, .{
        .code = "users.name_taken",
        .message = "is taken",
        .args = "\"users.name_taken\", ...",
        .fits = fitsAnything,
        .eval = evalPositive,
    });
    const not_empty = define(.not_empty, .{ .message = "must not be empty", .fits = fitsAnything, .eval = evalPositive });
    const email = define(.email, .{ .message = "must be an email address", .fits = fitsAnything, .eval = evalPositive });
    const unique_items = define(.unique_items, .{ .message = "must not contain duplicates", .fits = fitsAnything, .eval = evalPositive });
    const unique_by = define(.unique_by, .{ .message = "must not contain duplicates", .args = ".id", .fits = fitsAnything, .eval = evalPositive });
    /// Built by hand, as `v.each` builds it: no code and no message of its own.
    const each_positive: Rule = .{
        .kind = .each,
        .code = "",
        .message = "",
        .args = "...",
        .inner = &.{positive},
        .fits = fitsAnything,
        .eval = evalPositive,
    };
};

test "define gives a rule its kind's code, the message and the data" {
    const rule = test_rules.positive;
    try std.testing.expectEqual(Kind.positive, rule.kind);
    try std.testing.expectEqualStrings("validation.positive", rule.code);
    try std.testing.expectEqualStrings("must be greater than 0", rule.message);
    try std.testing.expectEqual(null, rule.args);
    try std.testing.expectEqualStrings("validation.finite", rule.precondition.?.code);
    try std.testing.expectEqualStrings("must be a finite number", rule.precondition.?.message);
    try std.testing.expectEqual(0, rule.inner.len);

    const custom_rule = test_rules.custom;
    try std.testing.expectEqual(Kind.custom, custom_rule.kind);
    try std.testing.expectEqualStrings("users.name_taken", custom_rule.code);
    try std.testing.expectEqualStrings("is taken", custom_rule.message);
    try std.testing.expectEqualStrings("\"users.name_taken\", ...", custom_rule.args.?);
    try std.testing.expectEqual(null, custom_rule.precondition);
}

test "define takes the fallback when the default message would be longer than 512 bytes; 512 bytes stay" {
    const t = std.testing;
    const exactly: [512]u8 = @splat('m');
    const longer: [513]u8 = @splat('m');
    const fallback = "must be equal to the expected value";
    const kept = comptime define(.equals, .{ .message = &exactly, .fallback = fallback, .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try t.expectEqualStrings(&exactly, kept.message);
    const replaced = comptime define(.equals, .{
        .message = &longer,
        .fallback = fallback,
        .params = &.{param("expected", 5)},
        .fits = test_rules.fitsAnything,
        .eval = test_rules.evalPositive,
    });
    try t.expectEqualStrings(fallback, replaced.message);
    // Only the message changes: the code and the parameters stay.
    try t.expectEqualStrings("validation.equals", replaced.code);
    try t.expectEqualStrings("5", replaced.params[0].text);
    const short = comptime define(.equals, .{ .message = "must be equal to 5", .fallback = fallback, .fits = test_rules.fitsAnything, .eval = test_rules.evalPositive });
    try t.expectEqualStrings("must be equal to 5", short.message);
}

test "a rule is named by its public name, its call and its snake_case label" {
    const expect = std.testing.expectEqualStrings;
    const r = test_rules;
    try expect("positive", comptime r.positive.name());
    try expect("positive", comptime r.positive.call());
    try expect("positive", comptime r.positive.label());
    try expect("minItems", comptime r.min_items.name());
    try expect("minItems(3)", comptime r.min_items.call());
    try expect("min_items(3)", comptime r.min_items.label());
    try expect("custom(\"users.name_taken\", ...)", comptime r.custom.call());
    try expect("custom(\"users.name_taken\", ...)", comptime r.custom.label());
    try expect("each(...)", comptime r.each_positive.call());
    try expect("each(...)", comptime r.each_positive.label());
}

test "a string is a u8 slice that is neither volatile nor allowzero" {
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expect(isString(T));
        try std.testing.expect(!isListSlice(T));
        try std.testing.expect(ListChild(T) == null);
    }
    inline for (.{ []volatile u8, []const volatile u8, []allowzero const u8, []allowzero u8, [*]u8, [*:0]const u8, *const [3]u8, *const [3:0]u8, [3]u8, ?[]const u8, u8, []const u32 }) |T| {
        try std.testing.expect(!isString(T));
    }
}

test "a list is a slice of non-u8 items that is neither volatile nor allowzero, or an array" {
    inline for (.{ []const u32, []u32, [:0]const u32, []const ?u32, []const []const u8, []align(8) const u32 }) |T| {
        try std.testing.expect(isListSlice(T));
    }
    inline for (.{ []const u8, []u8, []volatile u32, []const volatile u32, []allowzero const u32, []volatile u8, [*]u32, *const [3]u32, [3]u32, ?[]const u32, u32 }) |T| {
        try std.testing.expect(!isListSlice(T));
    }
    try std.testing.expect(ListChild([]const u32).? == u32);
    try std.testing.expect(ListChild([]u32).? == u32);
    try std.testing.expect(ListChild([]const ?u32).? == ?u32);
    try std.testing.expect(ListChild([3]u8).? == u8);
    try std.testing.expect(ListChild([0]u32).? == u32);
    try std.testing.expect(ListChild([2][]const u8).? == []const u8);
    inline for (.{ []const u8, []volatile u32, []allowzero const u32, [*]u32, *const [3]u32, ?[]const u32, u32 }) |T| {
        try std.testing.expect(ListChild(T) == null);
    }
}

test "a slice outside the default address space is neither a string nor a list" {
    // Of the targets CI runs, only x86_64 has an address space besides the
    // default; a pointer into it does not coerce to the `*const T` rules take.
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expect(!isString([]addrspace(.gs) const u8));
        try std.testing.expect(!isListSlice([]addrspace(.gs) const u32));
        try std.testing.expect(ListChild([]addrspace(.gs) const u32) == null);
        try std.testing.expect(plainSlice([]addrspace(.gs) const u32) == null);
    }
}

test "a slice aligned below the alignment of its items is not a list" {
    // `&items[i]` of such a slice does not coerce to the `*const T` that rules
    // and predicates take, so a rule on it reports its own type error.
    inline for (.{ []align(1) const u32, []align(2) u32, []align(1) const ?u64, []align(1) const []const u8 }) |T| {
        try std.testing.expect(!isListSlice(T));
        try std.testing.expect(ListChild(T) == null);
    }
    inline for (.{ []align(4) const u32, []align(16) u64 }) |T| {
        try std.testing.expect(isListSlice(T));
    }
    try std.testing.expect(ListChild([]align(4) const u32).? == u32);
    // One-byte items are never under-aligned: an aligned u8 slice is a string.
    inline for (.{ []align(1) const u8, [:0]align(1) u8 }) |T| {
        try std.testing.expect(isString(T));
    }
    const where = "Dto.field_rules.x";
    try std.testing.expectEqualStrings(
        "validator: Dto.field_rules.x: each expects a slice or an array, field is []align(1) const u32; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeErrorText(&test_rules.each_positive, []align(1) const u32, where, "a slice or an array", test_rules.acceptsList, null),
    );
    try std.testing.expectEqualStrings(
        "validator: Dto.field_rules.x: positive expects a number, field is []align(1) const u32",
        comptime typeErrorText(&test_rules.positive, []align(1) const u32, where, "a number", isNumber, null),
    );
}

test "optional layers unwrap, and number, float and u8-array types are recognized" {
    try std.testing.expect(Unwrap(u32) == u32);
    try std.testing.expect(Unwrap(?u32) == u32);
    try std.testing.expect(Unwrap(??u32) == u32);
    try std.testing.expect(Unwrap(?[]const ?u8) == []const ?u8);
    try std.testing.expect(Unwrap(?*const ?u32) == *const ?u32);

    inline for (.{ [4]u8, [4:0]u8, [0]u8 }) |T| try std.testing.expect(isU8Array(T));
    inline for (.{ [4]u16, [4]i8, []const u8, *const [4]u8, u8 }) |T| try std.testing.expect(!isU8Array(T));

    inline for (.{ u8, i64, u128, usize, f16, f32, f64, f80, f128, c_longdouble }) |T| try std.testing.expect(isNumber(T));
    inline for (.{ bool, Kind, []const u8, ?u32, [2]u32 }) |T| try std.testing.expect(!isNumber(T));

    inline for (.{ f16, f32, f64, f80, f128, c_longdouble }) |T| try std.testing.expect(isFloat(T));
    inline for (.{ u32, i64, ?f64, bool }) |T| try std.testing.expect(!isFloat(T));
}

test "a signed number is a signed integer or a float" {
    inline for (.{ i8, i64, i128, isize, i1, f16, f32, f64, f80, f128, c_longdouble }) |T| try std.testing.expect(isSignedNumber(T));
    inline for (.{ u8, u64, u128, usize, u0, bool, ?i32, []const u8, [2]i8 }) |T| try std.testing.expect(!isSignedNumber(T));
}

test "an integer type's range is written min..max" {
    const expect = std.testing.expectEqualStrings;
    try expect("0..255", comptime intRange(u8));
    try expect("-128..127", comptime intRange(i8));
    try expect("0..18446744073709551615", comptime intRange(u64));
    try expect("-170141183460469231731687303715884105728..170141183460469231731687303715884105727", comptime intRange(i128));
    try expect("0..0", comptime intRange(u0));
}

test "a checked number parameter converts to the field type: integers exactly, floats to the nearest value" {
    const t = std.testing;
    try t.expectEqual(@as(u8, 255), comptime numberAs(u8, 255));
    try t.expectEqual(@as(i8, 5), comptime numberAs(i8, @as(u8, 5)));
    try t.expectEqual(@as(i128, std.math.minInt(i128)), comptime numberAs(i128, std.math.minInt(i128)));
    try t.expectEqual(@as(f32, 0.1), comptime numberAs(f32, 0.1));
    try t.expectEqual(@as(f32, 0.1), comptime numberAs(f32, @as(f64, 0.1)));
    try t.expectEqual(@as(f32, 16777216), comptime numberAs(f32, 16777216));
    try t.expectEqual(@as(f64, 9007199254740992), comptime numberAs(f64, @as(u64, 9007199254740992)));
    try t.expectEqual(@as(f16, 0.5), comptime numberAs(f16, 0.5));
    try t.expectEqual(std.math.floatMax(f80), comptime numberAs(f80, std.math.floatMax(f80)));
    try t.expect(std.math.signbit(comptime numberAs(f32, -0.0)));
    try t.expectEqual(@as(c_longdouble, -1.5), comptime numberAs(c_longdouble, -1.5));
}

test "a parameter's type is described by its kind, a float with its type" {
    const expect = std.testing.expectEqualStrings;
    try expect("an integer", comptime describeValueType(comptime_int));
    try expect("an integer", comptime describeValueType(u8));
    try expect("a float (comptime_float)", comptime describeValueType(comptime_float));
    try expect("a float (f64)", comptime describeValueType(f64));
    try expect("a bool", comptime describeValueType(bool));
    try expect("an enum tag", comptime describeValueType(@TypeOf(.admin)));
    try expect("an enum tag", comptime describeValueType(TestOpen));
    try expect("a string", comptime describeValueType(*const [1:0]u8));
    try expect("a list", comptime describeValueType(@TypeOf(.{ 1, 2 })));
    try expect("@TypeOf(null)", comptime describeValueType(@TypeOf(null)));
    try expect("?u8", comptime describeValueType(?u8));
}

test "an integer field takes an integer parameter within its type" {
    const expect = std.testing.expectEqualStrings;
    const t = std.testing;
    try t.expectEqual(null, comptime numberParamProblem(0, u8, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(255, u8, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(u64, 7), i8, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(std.math.minInt(i128), i128, "use an integer bound", ""));
    try expect(": 1.5 is a float (comptime_float), field is u8; use an integer bound", comptime numberParamProblem(1.5, u8, "use an integer bound", "").?);
    // A float that holds an integer renders as one, so the text names its type.
    try expect(": 2 is a float (comptime_float), field is u8; use an integer bound", comptime numberParamProblem(2.0, u8, "use an integer bound", "").?);
    try expect(": 10 is a float (f64), field is u64; use an integer", comptime numberParamProblem(@as(f64, 10), u64, "use an integer", "").?);
    try expect(": -1 is outside u64 (0..18446744073709551615)", comptime numberParamProblem(-1, u64, "use an integer bound", "").?);
    try expect(": 300 is outside u8 (0..255); the rule would never pass", comptime numberParamProblem(300, u8, "use an integer", "; the rule would never pass").?);
    try expect(": -129 is outside i8 (-128..127)", comptime numberParamProblem(-129, i8, "use an integer bound", "").?);
    try expect(
        ": 170141183460469231731687303715884105728 is outside i128 (-170141183460469231731687303715884105728..170141183460469231731687303715884105727)",
        comptime numberParamProblem(std.math.maxInt(i128) + 1, i128, "use an integer bound", "").?,
    );
    // A parameter of another kind shows as it is written.
    try expect(": \"5\" is a string, field is i32; use an integer", comptime numberParamProblem("5", i32, "use an integer", "").?);
    try expect(": true is a bool, field is u8; use an integer", comptime numberParamProblem(true, u8, "use an integer", "").?);
    try expect(": .admin is an enum tag, field is u8; use an integer", comptime numberParamProblem(.admin, u8, "use an integer", "").?);
}

test "a float field takes a parameter that stays finite and, unless zero, non-zero, and an integer it holds exactly" {
    const expect = std.testing.expectEqualStrings;
    const t = std.testing;
    try t.expectEqual(null, comptime numberParamProblem(0.1, f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(-0.0, f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(0, f16, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(16777216, f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(65504, f16, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(std.math.maxInt(u64), f80, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(std.math.floatTrueMin(f32), f32, "use an integer bound", ""));
    // A float rounds to the nearest value of the field type; a subnormal result is kept.
    try t.expectEqual(null, comptime numberParamProblem(1e-40, f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f64, 0.1), f16, "use an integer bound", ""));
    try expect(": 16777217 is not exactly representable in f32 (nearest: 16777216)", comptime numberParamProblem(16777217, f32, "use an integer bound", "").?);
    try expect(
        ": 9007199254740993 is not exactly representable in f64 (nearest: 9007199254740992)",
        comptime numberParamProblem(9007199254740993, f64, "use an integer bound", "").?,
    );
    try expect(
        ": 18446744073709551615 is not exactly representable in f64 (nearest: 18446744073709551616)",
        comptime numberParamProblem(@as(u64, std.math.maxInt(u64)), f64, "use an integer bound", "").?,
    );
    try expect(": 65505 is not exactly representable in f16 (nearest: 65504)", comptime numberParamProblem(65505, f16, "use an integer bound", "").?);
    try expect(": 65520 is outside the finite range of f16", comptime numberParamProblem(65520, f16, "use an integer bound", "").?);
    try expect(
        ": 1606938044258990275541962092341162602522202993782792835301376 is outside the finite range of f32",
        comptime numberParamProblem(1 << 200, f32, "use an integer bound", "").?,
    );
    try expect(": 1e39 is outside the finite range of f32", comptime numberParamProblem(1e39, f32, "use an integer bound", "").?);
    try expect(": -1e39 is outside the finite range of f32", comptime numberParamProblem(-1e39, f32, "use an integer bound", "").?);
    try expect(": 1e300 is outside the finite range of f32; the rule would never pass", comptime numberParamProblem(1e300, f32, "use an integer", "; the rule would never pass").?);
    try expect(": 1e-50 rounds to 0 in f32", comptime numberParamProblem(1e-50, f32, "use an integer bound", "").?);
    try expect(": 5e-324 rounds to 0 in f32", comptime numberParamProblem(std.math.floatTrueMin(f64), f32, "use an integer bound", "").?);
    try expect(": true is a bool, field is f64; use a number", comptime numberParamProblem(true, f64, "use an integer", "").?);
}

test "a typed float narrower than a float field is an error when its value there has another shortest text" {
    const expect = std.testing.expectEqualStrings;
    const t = std.testing;
    const tail = "; write it as a literal or as ";
    try expect(": 0.1 is a float (f32), 0.10000000149011612 in f64" ++ tail ++ "f64", comptime numberParamProblem(@as(f32, 0.1), f64, "use an integer bound", "").?);
    try expect(": 0.7 is a float (f32), 0.699999988079071 in f64" ++ tail ++ "f64", comptime numberParamProblem(@as(f32, 0.7), f64, "use an integer", "; the rule would never pass").?);
    try expect(": 0.1 is a float (f32), 0.100000001490116119384765625 in f128" ++ tail ++ "f128", comptime numberParamProblem(@as(f32, 0.1), f128, "use an integer bound", "").?);
    try expect(": 0.1 is a float (f16), 0.099975586 in f32" ++ tail ++ "f32", comptime numberParamProblem(@as(f16, 0.1), f32, "use an integer bound", "").?);
    // The largest f16 shows as 65500, which reads back as 65504 in f16 only.
    try expect(": 65500 is a float (f16), 65504 in f32" ++ tail ++ "f32", comptime numberParamProblem(std.math.floatMax(f16), f32, "use an integer bound", "").?);
    try expect(": 0.1 is a float (f64), 0.10000000000000000555 in f80" ++ tail ++ "f80", comptime numberParamProblem(@as(f64, 0.1), f80, "use an integer bound", "").?);
    try expect(": 0.1 is a float (f64), 0.1000000000000000055511151231257827 in f128" ++ tail ++ "f128", comptime numberParamProblem(@as(f64, 0.1), f128, "use an integer bound", "").?);
    // A narrower value with the same text there, a literal, the field's own
    // type and a wider type are fine.
    try t.expectEqual(null, comptime numberParamProblem(@as(f32, 0.5), f64, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f16, 1), f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f32, -0.0), f64, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f32, 16777216), f128, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(0.1, f64, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(1.0 / 3.0, f64, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f32, 0.1), f32, "use an integer bound", ""));
    try t.expectEqual(null, comptime numberParamProblem(@as(f128, 0.1), f64, "use an integer bound", ""));
    // c_longdouble is f64 on some targets and wider on others.
    try t.expectEqual(std.math.floatFractionalBits(c_longdouble) <= 52, comptime numberParamProblem(@as(f64, 0.1), c_longdouble, "use an integer bound", "") == null);
}

test "a rule error names the field path and the rule with its arguments" {
    try std.testing.expectEqualStrings(
        "validator: Dto.field_rules.x: min_items(3) is always true",
        comptime ruleErrorText(&test_rules.min_items, "Dto.field_rules.x", " is always true"),
    );
    try std.testing.expectEqualStrings(
        "validator: Dto.field_rules.x[]: positive is wrong",
        comptime ruleErrorText(&test_rules.positive, "Dto.field_rules.x[]", " is wrong"),
    );
}

test "a type error names the rule and the field type, then the one hint that applies" {
    const expect = std.testing.expectEqualStrings;
    const where = "Dto.field_rules.x";
    const r = test_rules;
    // A rule that takes lists says that a string field is a string.
    try expect(
        "validator: Dto.field_rules.x: each expects a slice or an array, field is []const u8 (a string)",
        comptime typeErrorText(&r.each_positive, []const u8, where, "a slice or an array", r.acceptsList, null),
    );
    try expect(
        "validator: Dto.field_rules.x: each expects a slice or an array, field is [:0]const u8 (a string)",
        comptime typeErrorText(&r.each_positive, [:0]const u8, where, "a slice or an array", r.acceptsList, null),
    );
    try expect(
        "validator: Dto.field_rules.x: unique_items expects a slice or an array, field is []const u8 (a string)",
        comptime typeErrorText(&r.unique_items, []const u8, where, "a slice or an array", r.acceptsList, null),
    );
    try expect(
        "validator: Dto.field_rules.x: unique_by expects a slice or an array of structs, field is []const u8 (a string)",
        comptime typeErrorText(&r.unique_by, []const u8, where, "a slice or an array of structs", r.acceptsList, null),
    );
    try expect(
        "validator: Dto.field_rules.x: each expects a slice or an array, field is u32",
        comptime typeErrorText(&r.each_positive, u32, where, "a slice or an array", r.acceptsList, null),
    );
    // A rule that does not take lists, or one with its own hint, adds no note.
    try expect(
        "validator: Dto.field_rules.x: positive expects a number, field is []const u8",
        comptime typeErrorText(&r.positive, []const u8, where, "a number", isNumber, null),
    );
    try expect(
        "validator: Dto.field_rules.x: min_items expects a slice, field is []const u8; for strings use v.minLength or v.minBytes",
        comptime typeErrorText(&r.min_items, []const u8, where, "a slice", isListSlice, "for strings use v.minLength or v.minBytes"),
    );
    // A list whose unwrapped items the rule takes: use each.
    try expect(
        "validator: Dto.field_rules.x: positive expects a number, field is []const u32; use v.each(v.positive)",
        comptime typeErrorText(&r.positive, []const u32, where, "a number", isNumber, null),
    );
    try expect(
        "validator: Dto.field_rules.x: positive expects a number, field is [2]?u64; use v.each(v.positive)",
        comptime typeErrorText(&r.positive, [2]?u64, where, "a number", isNumber, null),
    );
    try expect(
        "validator: Dto.field_rules.x: email expects a string, field is []const []const u8; use v.each(v.email)",
        comptime typeErrorText(&r.email, []const []const u8, where, "a string", isString, null),
    );
    // [N]u8 where the rule would take a string.
    try expect(
        "validator: Dto.field_rules.x: email expects a string, field is [4]u8; [N]u8 is an array of numbers, not a string: use []const u8",
        comptime typeErrorText(&r.email, [4]u8, where, "a string", isString, null),
    );
    // volatile and allowzero slices are neither strings nor lists, and the hint
    // says so when the rule would take the plain slice.
    try expect(
        "validator: Dto.field_rules.x: email expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeErrorText(&r.email, []volatile u8, where, "a string", isString, null),
    );
    try expect(
        "validator: Dto.field_rules.x: email expects a string, field is []allowzero const u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeErrorText(&r.email, []allowzero const u8, where, "a string", isString, null),
    );
    try expect(
        "validator: Dto.field_rules.x: not_empty expects a string or a slice, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeErrorText(&r.not_empty, []volatile u8, where, "a string or a slice", r.acceptsStringOrSlice, null),
    );
    try expect(
        "validator: Dto.field_rules.x: each expects a slice or an array, field is []volatile u32; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeErrorText(&r.each_positive, []volatile u32, where, "a slice or an array", r.acceptsList, null),
    );
}

test "one rule or a tuple of rules becomes a list of rules" {
    const where = "Dto.field_rules.x";
    const one = comptime entryParts(test_rules.positive, where, false).rules;
    try std.testing.expectEqual(1, one.len);
    try std.testing.expectEqual(Kind.positive, one[0].kind);
    const two = comptime entryParts(.{ test_rules.positive, test_rules.custom }, where, false).rules;
    try std.testing.expectEqual(2, two.len);
    try std.testing.expectEqual(Kind.positive, two[0].kind);
    try std.testing.expectEqual(Kind.custom, two[1].kind);
    const none = comptime entryParts(.{}, where, false).rules;
    try std.testing.expectEqual(0, none.len);
}

test "an entry takes apart its outside name, transforms and rules, each in the order written" {
    const t = std.testing;
    const where = "Dto.field_rules.x";
    const r = root;
    const all = comptime entryParts(.{ r.rename("userName"), r.trim, r.toLower, r.notBlank, r.maxLength(10) }, where, false);
    try t.expectEqualStrings("userName", all.name.?);
    try t.expectEqual(2, all.transforms.len);
    try t.expectEqual(TransformKind.trim, all.transforms[0].kind);
    try t.expectEqual(TransformKind.to_lower, all.transforms[1].kind);
    try t.expectEqual(2, all.rules.len);
    try t.expectEqual(Kind.not_blank, all.rules[0].kind);
    try t.expectEqual(Kind.max_length, all.rules[1].kind);
    try t.expect(all.problem == null);
    // One element alone, of each kind.
    const name_only = comptime entryParts(r.rename("ID"), where, false);
    try t.expectEqualStrings("ID", name_only.name.?);
    try t.expectEqual(0, name_only.transforms.len + name_only.rules.len);
    const transform_only = comptime entryParts(r.trimEnd, where, false);
    try t.expectEqual(null, transform_only.name);
    try t.expectEqual(TransformKind.trim_end, transform_only.transforms[0].kind);
    try t.expectEqual(0, transform_only.rules.len);
    const rule_only = comptime entryParts(test_rules.positive, where, false);
    try t.expectEqual(1, rule_only.rules.len);
    try t.expectEqual(0, rule_only.transforms.len);
    // each is a rule; its argument is an entry of its own.
    const with_each = comptime entryParts(.{ r.trim, r.each(.{ r.trim, r.notBlank }) }, where, false);
    try t.expectEqual(1, with_each.transforms.len);
    try t.expectEqual(Kind.each, with_each.rules[0].kind);
    try t.expectEqual(TransformKind.trim, (comptime itemTransforms(with_each.rules))[0].kind);
    try t.expectEqual(Kind.not_blank, (comptime itemRules(with_each.rules))[0].kind);
    try t.expect(comptime hasItemTransforms(with_each.rules));
    try t.expect(!comptime hasItemTransforms(&.{test_rules.each_positive}));
    try t.expect(comptime hasItemTransforms(&.{r.each(r.each(r.trim))}));
    try t.expect(!comptime hasItemTransforms(&.{test_rules.positive}));
    // An each of transforms alone, at any depth, checks nothing.
    try t.expect(comptime hasCheckRules(&.{test_rules.positive}));
    try t.expect(comptime hasCheckRules(&.{test_rules.each_positive}));
    try t.expect(comptime hasCheckRules(&.{r.each(r.each(.{ r.trim, r.notBlank }))}));
    try t.expect(comptime hasCheckRules(&.{ test_rules.min_items, r.each(r.trim) }));
    try t.expect(!comptime hasCheckRules(&.{r.each(r.trim)}));
    try t.expect(!comptime hasCheckRules(&.{r.each(r.each(r.trim))}));
    try t.expect(!comptime hasCheckRules(&.{}));
}

/// The text of the problem of `value` as an entry of `field_rules` or, with
/// `in_each`, as the argument of `each`; "" when it has none.
fn entryProblemOf(comptime value: anytype, comptime in_each: bool) []const u8 {
    const where = "Dto.field_rules.x";
    const parts = comptime entryParts(value, where, in_each);
    return if (parts.problem) |problem| comptime entryProblemText(problem, where) else "";
}

test "the first element out of its place is the problem of the entry" {
    const expect = std.testing.expectEqualStrings;
    const r = root;
    const head = "validator: Dto.field_rules.x: ";
    try expect(head ++ "rename comes first: name, then transforms, then rules", entryProblemOf(.{ r.trim, r.rename("a") }, false));
    try expect(head ++ "rename comes first: name, then transforms, then rules", entryProblemOf(.{ r.notBlank, r.rename("a") }, false));
    try expect(head ++ "rename appears twice; a field has one outside name", entryProblemOf(.{ r.rename("a"), r.rename("b") }, false));
    try expect(head ++ "rename appears twice; a field has one outside name", entryProblemOf(.{ r.rename("a"), r.trim, r.rename("a") }, false));
    // The rule right before the transform is named, with its arguments.
    try expect(head ++ "not_blank is a rule; transforms (trim) must come before the rules", entryProblemOf(.{ r.rename("a"), r.notBlank, r.trim }, false));
    try expect(head ++ "max_length(100) is a rule; transforms (to_lower) must come before the rules", entryProblemOf(.{ r.trim, r.notBlank, r.maxLength(100), r.toLower }, false));
    try expect(head ++ "each(...) is a rule; transforms (transform_with(...)) must come before the rules", entryProblemOf(.{ r.each(r.trim), r.transformWith(test_transforms.same) }, false));
    // Left to right, the first one wins.
    try expect(head ++ "not_blank is a rule; transforms (trim) must come before the rules", entryProblemOf(.{ r.notBlank, r.trim, r.rename("a") }, false));
    // In the argument of each, any name is out of its place.
    try expect(head ++ "rename inside each: list items have no name", entryProblemOf(r.rename("a"), true));
    try expect(head ++ "rename inside each: list items have no name", entryProblemOf(.{ r.trim, r.rename("a") }, true));
    try expect(head ++ "not_blank is a rule; transforms (trim_start) must come before the rules", entryProblemOf(.{ r.notBlank, r.trimStart }, true));
    // In their order, no problem.
    try expect("", entryProblemOf(.{ r.rename("a"), r.trim, r.notBlank }, false));
    try expect("", entryProblemOf(.{ r.trim, r.toUpper }, true));
    // each keeps the problem of its argument for the declaration check of its field.
    try std.testing.expect((comptime r.each(.{ r.notBlank, r.trim }).item_problem) != null);
    try std.testing.expect((comptime r.each(.{ r.trim, r.notBlank }).item_problem) == null);
}

/// Stand-in functions for `transformWith` in the self-tests.
const test_transforms = struct {
    fn same(_: std.mem.Allocator, value: []const u8) []const u8 {
        return value;
    }
};

test "a field_rules table is a struct literal or .{}, not an element" {
    try std.testing.expect(isFieldRulesTable(@TypeOf(.{ .x = test_rules.positive })));
    try std.testing.expect(isFieldRulesTable(@TypeOf(.{})));
    try std.testing.expect(!isFieldRulesTable(Rule));
    try std.testing.expect(!isFieldRulesTable(Transform));
    try std.testing.expect(!isFieldRulesTable(Rename));
    try std.testing.expect(!isFieldRulesTable(@TypeOf(.{ test_rules.positive, test_rules.custom })));
    try std.testing.expect(!isFieldRulesTable(comptime_int));
}

test "a trailing each holds the item rules and the others apply to the value itself" {
    const where = "Dto.field_rules.x";
    const with_each = comptime entryParts(.{ test_rules.min_items, test_rules.each_positive }, where, false).rules;
    const own = comptime ownRules(with_each);
    try std.testing.expectEqual(1, own.len);
    try std.testing.expectEqual(Kind.min_items, own[0].kind);
    const items = comptime itemRules(with_each);
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqual(Kind.positive, items[0].kind);

    const only_each = comptime entryParts(test_rules.each_positive, where, false).rules;
    try std.testing.expectEqual(0, (comptime ownRules(only_each)).len);
    try std.testing.expectEqual(1, (comptime itemRules(only_each)).len);

    const without_each = comptime entryParts(.{ test_rules.positive, test_rules.custom }, where, false).rules;
    try std.testing.expectEqual(2, (comptime ownRules(without_each)).len);
    try std.testing.expectEqual(0, (comptime itemRules(without_each)).len);
}

test "a rule list with at most one each, placed last, passes the declaration check" {
    const where = "Dto.field_rules.x";
    comptime checkRuleList(&.{ test_rules.min_items, test_rules.each_positive }, []const u32, where);
    comptime checkRuleList(&.{test_rules.each_positive}, []const u32, where);
    comptime checkRuleList(&.{ test_rules.positive, test_rules.custom }, u32, where);
    comptime checkRuleList(&.{}, u32, where);
}

test "two rules whose bounds on one measure let no value pass contradict, named in tuple order" {
    const expect = std.testing.expectEqualStrings;
    const where = "Dto.field_rules.x";
    const r = root;
    const head = "validator: Dto.field_rules.x: ";
    const tail = " contradict; no value can pass";
    // The value of a number.
    try expect(head ++ "min(10) and max(5)" ++ tail, comptime contradictionText(&.{ r.min(10), r.max(5) }, i32, where).?);
    try expect(head ++ "max(5) and min(10)" ++ tail, comptime contradictionText(&.{ r.max(5), r.min(10) }, u8, where).?);
    try expect(head ++ "positive and max(0)" ++ tail, comptime contradictionText(&.{ r.positive, r.max(0) }, i32, where).?);
    try expect(head ++ "positive and max(0)" ++ tail, comptime contradictionText(&.{ r.positive, r.max(0) }, f64, where).?);
    try expect(head ++ "range(10, 20) and max(5)" ++ tail, comptime contradictionText(&.{ r.range(10, 20), r.max(5) }, i32, where).?);
    try expect(head ++ "range(0, 5) and range(6, 9)" ++ tail, comptime contradictionText(&.{ r.range(0, 5), r.range(6, 9) }, u8, where).?);
    try expect(head ++ "positive and non_positive" ++ tail, comptime contradictionText(&.{ r.positive, r.nonPositive }, f64, where).?);
    try expect(head ++ "non_negative and negative" ++ tail, comptime contradictionText(&.{ r.nonNegative, r.negative }, i32, where).?);
    try expect(head ++ "min(0) and negative" ++ tail, comptime contradictionText(&.{ r.min(0), r.negative }, f32, where).?);
    try expect(head ++ "positive and negative" ++ tail, comptime contradictionText(&.{ r.positive, r.negative }, i8, where).?);
    try expect(head ++ "min(0.5) and max(0.25)" ++ tail, comptime contradictionText(&.{ r.min(0.5), r.max(0.25) }, f16, where).?);
    // The items of a slice and the bytes of a string: empty and notEmpty share both.
    try expect(head ++ "min_items(5) and max_items(3)" ++ tail, comptime contradictionText(&.{ r.minItems(5), r.maxItems(3) }, []const u32, where).?);
    try expect(head ++ "empty and min_items(1)" ++ tail, comptime contradictionText(&.{ r.empty, r.minItems(1) }, []const u32, where).?);
    try expect(head ++ "not_empty and empty" ++ tail, comptime contradictionText(&.{ r.notEmpty, r.empty }, []const u8, where).?);
    try expect(head ++ "not_empty and empty" ++ tail, comptime contradictionText(&.{ r.notEmpty, r.empty }, []const []const u8, where).?);
    // The first pair wins: (0, 2) comes before (1, 2).
    try expect(head ++ "min(10) and max(1)" ++ tail, comptime contradictionText(&.{ r.min(10), r.min(5), r.max(1) }, i64, where).?);
    // A rule with its own message keeps its bounds.
    try expect(head ++ "min(3) and max(2)" ++ tail, comptime contradictionText(&.{ r.min(3).withMessage("too small"), r.max(2) }, u8, where).?);
}

test "equal bounds, redundant rules and bounds on different measures do not contradict" {
    const r = root;
    inline for (.{ i32, u8, f64, f16 }) |T| {
        try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(5), r.max(5) }, T));
        try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(1), r.positive }, T));
        try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(1), r.min(5), r.max(10) }, T));
        try std.testing.expectEqual(null, comptime contradiction(&.{ r.range(1, 5), r.range(5, 9) }, T));
    }
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.nonNegative, r.nonPositive }, i32));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.nonNegative, r.nonPositive }, f64));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(-0.0), r.max(0) }, f32));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.positive, r.max(1) }, i32));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minItems(3), r.maxItems(3) }, []const u32));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.notEmpty, r.minItems(2), r.maxItems(3) }, []const u32));
    // Floats compare in the field type: 1.00000001 is 1 in f32, but not in f64.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(1.00000001), r.max(1) }, f32));
    try std.testing.expectEqual([2]usize{ 0, 1 }, comptime contradiction(&.{ r.min(1.00000001), r.max(1) }, f64).?);
    // The smallest positive f32 passes both.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.positive, r.max(1e-45) }, f32));
    // Bounds of different measures are never compared.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minItems(5), r.max(3) }, []const u32));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.min(5), r.maxItems(3) }, u32));
    comptime checkRuleList(&.{ r.min(5), r.max(5) }, i32, "Dto.field_rules.x");
    comptime checkRuleList(&.{ r.notEmpty, r.maxItems(3), r.each(r.positive) }, []const u32, "Dto.field_rules.x");
}

test "string lengths, byte counts and dates contradict by the largest lower and the smallest upper bound, named in tuple order" {
    const expect = std.testing.expectEqualStrings;
    const where = "Dto.field_rules.x";
    const r = root;
    const S = []const u8;
    const head = "validator: Dto.field_rules.x: ";
    const tail = " contradict; no value can pass";
    // Code points: minLength, maxLength, length and strongPassword's min_length.
    try expect(head ++ "min_length(10) and max_length(5)" ++ tail, comptime contradictionText(&.{ r.minLength(10), r.maxLength(5) }, S, where).?);
    try expect(head ++ "min_length(10) and length(1, 5)" ++ tail, comptime contradictionText(&.{ r.minLength(10), r.length(1, 5) }, S, where).?);
    try expect(head ++ "length(6, 10) and max_length(5)" ++ tail, comptime contradictionText(&.{ r.length(6, 10), r.maxLength(5) }, S, where).?);
    try expect(head ++ "length(1, 3) and length(5, 8)" ++ tail, comptime contradictionText(&.{ r.length(1, 3), r.length(5, 8) }, S, where).?);
    try expect(head ++ "max_length(8) and strong_password(.{...})" ++ tail, comptime contradictionText(&.{ r.maxLength(8), r.strongPassword(.{ .min_length = 12 }) }, S, where).?);
    try expect(head ++ "length(4, 10) and strong_password(.{...})" ++ tail, comptime contradictionText(&.{ r.length(4, 10), r.strongPassword(.{ .min_length = 12 }) }, S, where).?);
    // Bytes: minBytes and maxBytes, and empty and notEmpty on a string.
    try expect(head ++ "min_bytes(10) and max_bytes(5)" ++ tail, comptime contradictionText(&.{ r.minBytes(10), r.maxBytes(5) }, S, where).?);
    try expect(head ++ "empty and min_bytes(1)" ++ tail, comptime contradictionText(&.{ r.empty, r.minBytes(1) }, S, where).?);
    try expect(head ++ "min_bytes(1) and empty" ++ tail, comptime contradictionText(&.{ r.minBytes(1), r.empty }, S, where).?);
    // Dates byte-wise, date-times as UTC instants.
    try expect(head ++ "min_date(\"2021-01-01\") and max_date(\"2020-12-31\")" ++ tail, comptime contradictionText(&.{ r.minDate("2021-01-01"), r.maxDate("2020-12-31") }, S, where).?);
    try expect(head ++ "min_date(\"2020-01-01T00:00:00+01:00\") and max_date(\"2019-12-31T22:59:59Z\")" ++ tail, comptime contradictionText(&.{ r.minDate("2020-01-01T00:00:00+01:00"), r.maxDate("2019-12-31T22:59:59Z") }, S, where).?);
    // The largest lower bound and the smallest upper bound, not the first pair.
    try expect(head ++ "min_length(10) and max_length(2)" ++ tail, comptime contradictionText(&.{ r.minLength(6), r.maxLength(5), r.minLength(10), r.maxLength(2) }, S, where).?);
    try expect(head ++ "max_date(\"2019-06-30\") and min_date(\"2020-01-01\")" ++ tail, comptime contradictionText(&.{ r.minDate("2019-07-01"), r.maxDate("2019-06-30"), r.minDate("2020-01-01") }, S, where).?);
    // On ties the earlier rule: minLength(10) before length(10, 20), the first maxLength(5).
    try expect(head ++ "max_length(5) and min_length(10)" ++ tail, comptime contradictionText(&.{ r.maxLength(5), r.minLength(10), r.length(10, 20), r.maxLength(5) }, S, where).?);
    // Inside each, whose declaration check runs on its rules with the item's path.
    const each_rule = comptime r.each(.{ r.minLength(10), r.maxLength(5) });
    try expect("validator: Dto.field_rules.x[]: min_length(10) and max_length(5)" ++ tail, comptime contradictionText(each_rule.inner, S, where ++ "[]").?);
}

test "equal bounds, every digit of a fraction, and bounds of different measures or forms on strings" {
    const r = root;
    const S = []const u8;
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minLength(5), r.maxLength(5) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.length(1, 5), r.length(5, 8) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.maxLength(128), r.strongPassword(.{ .min_length = 12 }) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.notEmpty, r.minBytes(5), r.maxBytes(5) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2020-01-01"), r.maxDate("2020-01-01") }, S));
    // Equal instants: .5 is .50, and 01:00+01:00 is 00:00Z.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2020-01-01T00:00:00.5Z"), r.maxDate("2020-01-01T00:00:00.50Z") }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2020-01-01T01:00:00+01:00"), r.maxDate("2020-01-01T00:00:00Z") }, S));
    // Every digit of the fraction counts, the tenth too.
    try std.testing.expectEqual([2]usize{ 0, 1 }, comptime contradiction(&.{ r.minDate("2020-01-01T00:00:00.0000000001Z"), r.maxDate("2020-01-01T00:00:00Z") }, S).?);
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2020-01-01T00:00:00.0000000001Z"), r.maxDate("2020-01-01T00:00:00.00000000010Z") }, S));
    // The leap second 23:59:60 comes after 23:59:59 and before the next day.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2016-12-31T23:59:60Z"), r.maxDate("2016-12-31T23:59:60.5Z") }, S));
    try std.testing.expectEqual([2]usize{ 0, 1 }, comptime contradiction(&.{ r.minDate("2016-12-31T23:59:60Z"), r.maxDate("2016-12-31T23:59:59.9Z") }, S).?);
    try std.testing.expectEqual([2]usize{ 0, 1 }, comptime contradiction(&.{ r.minDate("2017-01-01T00:00:00Z"), r.maxDate("2016-12-31T23:59:60Z") }, S).?);
    // Before 1970 the day count is negative, and fractions still order as after it.
    try std.testing.expectEqual([2]usize{ 0, 1 }, comptime contradiction(&.{ r.minDate("1969-12-31T23:59:59.5Z"), r.maxDate("1969-12-31T23:59:59.25Z") }, S).?);
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("1969-12-31T23:59:59.5Z"), r.maxDate("1969-12-31T23:59:59.50Z") }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("1900-01-01T00:00:00.10Z"), r.maxDate("1900-01-01T00:00:00.9Z") }, S));
    // Different measures and forms are never compared.
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minLength(10), r.maxBytes(5) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.empty, r.minLength(1) }, S));
    try std.testing.expectEqual(null, comptime contradiction(&.{ r.minDate("2021-01-01"), r.maxDate("2020-12-31T00:00:00Z") }, S));
    comptime checkRuleList(&.{ r.minLength(5), r.maxLength(5), r.maxBytes(20) }, S, "Dto.field_rules.x");
}

test "coerces accepts the conversions v.custom documents and nothing else" {
    const accepted = [_][2]type{
        .{ u32, u32 },           .{ u8, u32 },              .{ u32, u64 },         .{ i8, i64 },
        .{ u32, i64 },           .{ f32, f64 },             .{ f16, f128 },        .{ u32, ?u32 },
        .{ u32, anyerror!u32 },  .{ u32, ?anyerror!u32 },   .{ []u8, []const u8 }, .{ [:0]const u8, []const u8 },
        .{ [:0]u8, []const u8 }, .{ [:0]u8, [:0]const u8 }, .{ *u32, *const u32 }, .{ []const u32, ?[]const u32 },
    };
    // Equal volatile and allowzero, with const added.
    const same_attributes = [_][2]type{
        .{ []volatile u8, []const volatile u8 }, .{ []allowzero u8, []allowzero const u8 }, .{ *allowzero u32, *allowzero const u32 },
    };
    // Distinct types of the same width.
    const same_width = [_][2]type{
        .{ c_uint, u32 }, .{ i32, c_int }, .{ usize, u64 }, .{ c_longdouble, std.meta.Float(@bitSizeOf(c_longdouble)) },
    };
    const rejected = [_][2]type{
        .{ u64, u32 },                  .{ i32, u64 },                   .{ u32, i32 },                          .{ i8, u8 },
        .{ f64, f32 },                  .{ []const u8, []u8 },           .{ []const u8, [:0]const u8 },          .{ *const u32, *u32 },
        .{ []volatile u8, []const u8 }, .{ []allowzero u8, []const u8 }, .{ []align(1) const u32, []const u32 }, .{ [3]u8, []const u8 },
        .{ []const u32, []const u64 },  .{ ?u32, u32 },                  .{ *allowzero const u32, *const u32 },
    };
    // Zig coerces these as well, but v.custom keeps to the documented set.
    const narrower_than_zig = [_][2]type{
        .{ u32, f64 }, .{ *const [3]u8, []const u8 }, .{ []align(1) const u8, []const u8 }, .{ []const u8, []allowzero const u8 },
    };
    const wrong = comptime blk: {
        var out: []const u8 = "";
        for (accepted ++ same_attributes ++ same_width) |pair| {
            if (!coerces(pair[0], pair[1])) out = out ++ @typeName(pair[0]) ++ " should coerce to " ++ @typeName(pair[1]) ++ "\n";
        }
        for (rejected ++ narrower_than_zig) |pair| {
            if (coerces(pair[0], pair[1])) out = out ++ @typeName(pair[0]) ++ " should not coerce to " ++ @typeName(pair[1]) ++ "\n";
        }
        break :blk out;
    };
    try std.testing.expectEqualStrings("", wrong);
    // The address space must match as well. Of the targets CI runs, only
    // x86_64 has one besides the default.
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expect(!coerces(*addrspace(.gs) const u32, *const u32));
        try std.testing.expect(!coerces(*const u32, *addrspace(.gs) const u32));
        try std.testing.expect(coerces(*addrspace(.gs) u32, *addrspace(.gs) const u32));
    }
}

/// `; did you mean "name"?` for a likely typo of a non-comptime field of the
/// struct `T`, or "": the field that `closest` names among them.
pub fn suggestion(comptime T: type, comptime key: []const u8) []const u8 {
    @setEvalBranchQuota(eval_quota);
    var fields: []const []const u8 = &.{};
    for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_attrs) |name, attrs| {
        if (!attrs.@"comptime") fields = fields ++ &[_][]const u8{name};
    }
    return if (closest(fields, key)) |name| "; did you mean \"" ++ name ++ "\"?" else "";
}

/// The name among `names` that `key` is most likely a typo of, or null. The
/// rule is confy's: the closest name by edit distance, ignoring ASCII case,
/// when that distance is below 3 and below the key's length; on a tie the
/// first name wins. Runs at compile time.
pub fn closest(comptime names: []const []const u8, comptime key: []const u8) ?[]const u8 {
    return comptime closestName(names, key);
}

fn closestName(comptime names: []const []const u8, comptime key: []const u8) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (names) |name| {
        const distance = editDistance(key, name) orelse continue;
        if (distance < best_distance and distance < key.len) {
            best = name;
            best_distance = distance;
        }
    }
    return best;
}

/// Levenshtein distance ignoring ASCII case; null when a name is longer than
/// 64 bytes (no suggestion for such names).
fn editDistance(comptime a: []const u8, comptime b: []const u8) ?usize {
    @setEvalBranchQuota(eval_quota);
    if (a.len > 64 or b.len > 64) return null;
    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (previous[0 .. b.len + 1], 0..) |*cell, j| cell.* = j;
    for (a, 0..) |char_a, i| {
        current[0] = i + 1;
        for (b, 0..) |char_b, j| {
            const cost: usize = if (std.ascii.toLower(char_a) == std.ascii.toLower(char_b)) 0 else 1;
            current[j + 1] = @min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

test "suggestion needs a distance below 3 and below the key's length, and never names a comptime field" {
    const S = struct { ab: u32, address: []const u8, comptime version: u32 = 1 };
    try std.testing.expectEqualStrings("", comptime suggestion(S, "versoin"));
    try std.testing.expectEqualStrings("", comptime suggestion(S, "adrs"));
    try std.testing.expectEqualStrings("", comptime suggestion(S, "a"));
    try std.testing.expectEqualStrings("; did you mean \"ab\"?", comptime suggestion(S, "abc"));
}

test "suggestion prefers the first field in declaration order on a tie" {
    const S = struct { cat: u32, car: u32 };
    try std.testing.expectEqualStrings("; did you mean \"cat\"?", comptime suggestion(S, "cax"));
}

test "closest names the nearest name within 2 edits, ignoring ASCII case" {
    const names: []const []const u8 = &.{ "name", "email", "age" };
    try std.testing.expectEqualStrings("name", root.closest(names, "nmae").?);
    try std.testing.expectEqualStrings("name", root.closest(names, "NAME").?);
    try std.testing.expectEqualStrings("email", root.closest(names, "emial").?);
    try std.testing.expectEqual(null, root.closest(names, "zzz"));
    // "age" is 2 edits away, which is not below the key's length.
    try std.testing.expectEqual(null, root.closest(names, "a"));
    try std.testing.expectEqualStrings("ab", root.closest(&.{"ab"}, "abc").?);
    // On a tie the first name wins.
    try std.testing.expectEqualStrings("cat", root.closest(&.{ "cat", "car" }, "cax").?);
}

test "editDistance counts edits ignoring ASCII case and gives up over 64 bytes" {
    try std.testing.expectEqual(@as(?usize, 3), comptime editDistance("kitten", "sitting"));
    try std.testing.expectEqual(@as(?usize, 0), comptime editDistance("Email", "eMAIL"));
    try std.testing.expectEqual(@as(?usize, 1), comptime editDistance(&@as([64]u8, @splat('a')), &@as([63]u8, @splat('a'))));
    try std.testing.expectEqual(@as(?usize, null), comptime editDistance(&@as([65]u8, @splat('a')), "a"));
}

/// The first problem of the public names of `ns` (`root.zig` in the library)
/// against the kind table rows `rows`, or null: each kind is exported under
/// its public name, as a `Rule` of that kind or as a function that returns a
/// `Rule`.
fn exportProblem(comptime ns: type, comptime rows: []const KindInfo) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    for (rows) |row| {
        if (!@hasDecl(ns, row.name)) return "v." ++ row.name ++ " is not exported";
        const decl = @field(ns, row.name);
        const D = @TypeOf(decl);
        if (D == Rule) {
            if (decl.kind != row.kind) return "v." ++ row.name ++ " is a rule of another kind";
        } else if (@typeInfo(D) != .@"fn" or (@typeInfo(D).@"fn".return_type orelse void) != Rule) {
            return "v." ++ row.name ++ " is not a rule";
        }
    }
    return null;
}

/// The texts of the hints that may name rules: the non-function declarations
/// of `hints` and the `call_examples` of every rule file.
fn hintTexts() []const []const u8 {
    comptime {
        var texts: []const []const u8 = &.{};
        for (@typeInfo(hints).@"struct".decl_names) |decl| {
            const value = @field(hints, decl);
            if (@typeInfo(@TypeOf(value)) != .@"fn") texts = texts ++ &[_][]const u8{value};
        }
        for (rule_files) |file| {
            if (!@hasDecl(file, "call_examples")) continue;
            const examples = file.call_examples;
            for (@typeInfo(@TypeOf(examples)).@"struct".field_names) |name| texts = texts ++ &[_][]const u8{@field(examples, name)};
        }
        return texts;
    }
}

/// The first `v.<name>` in `texts` that `root.zig` does not export, or null.
fn unknownHintName(comptime texts: []const []const u8) ?[]const u8 {
    @setEvalBranchQuota(eval_quota);
    for (texts) |text| {
        var i: usize = 0;
        while (std.mem.findPos(u8, text, i, "v.")) |at| {
            var end = at + 2;
            while (end < text.len and std.ascii.isAlphanumeric(text[end])) end += 1;
            i = end;
            if (at > 0 and std.ascii.isAlphanumeric(text[at - 1])) continue;
            const name = text[at + 2 .. end];
            if (name.len == 0 or @hasDecl(root, name)) continue;
            return name;
        }
    }
    return null;
}

/// The kind table rows of `list`, for the self-test below.
fn rowsOf(comptime list: []const Kind) []const KindInfo {
    comptime {
        var out: []const KindInfo = &.{};
        for (list) |kind| out = out ++ &[_]KindInfo{info(kind)};
        return out;
    }
}

test "every kind is exported under its public name as a rule of that kind" {
    try std.testing.expectEqualStrings("", comptime exportProblem(root, &kinds) orelse "");

    // The check itself, on a namespace that exports two rules.
    const Two = struct {
        pub const notEmpty = root.notEmpty;
        pub const positive = root.positive;
    };
    try std.testing.expectEqual(null, comptime exportProblem(Two, rowsOf(&.{ .not_empty, .positive })));
    try std.testing.expectEqualStrings("v.each is not exported", comptime exportProblem(Two, rowsOf(&.{ .not_empty, .positive, .each })).?);
    const OtherKind = struct {
        pub const notEmpty = root.positive;
        pub const positive = root.positive;
    };
    try std.testing.expectEqualStrings("v.notEmpty is a rule of another kind", comptime exportProblem(OtherKind, rowsOf(&.{ .not_empty, .positive })).?);
    const NotARule = struct {
        pub const notEmpty = root.notEmpty;
        pub const positive = root.check;
    };
    try std.testing.expectEqualStrings("v.positive is not a rule", comptime exportProblem(NotARule, rowsOf(&.{ .not_empty, .positive })).?);
}

test "every rule name a hint mentions is exported" {
    try std.testing.expectEqualStrings("", comptime unknownHintName(hintTexts()) orelse "");
    // The texts come from both sources: the hints and the rule files' call_examples.
    const collected = comptime hintTexts();
    for ([_][]const u8{ hints.wrap_predicate, "v.notEmpty" }) |expected| {
        const found = for (collected) |text| {
            if (std.mem.eql(u8, text, expected)) break true;
        } else false;
        try std.testing.expect(found);
    }
    const texts = [_][]const u8{
        "use v.each(v.notEmpty)",
        "e.g. v.minItems(1)",
        "codes such as dev.ops name no rule",
        "use v.nonEmpty",
    };
    try std.testing.expectEqualStrings("nonEmpty", comptime unknownHintName(&texts).?);
}

test "hint for a constructor used without a call" {
    const S = struct {
        const Options = struct { strict: bool = false };
        const Algorithm = enum { md5, sha1 };
        fn withOptions(comptime _: Options) void {}
        fn withSelector(comptime _: Algorithm) void {}
        fn withCount(comptime _: usize) void {}
        fn plain(_: u32) bool {
            return true;
        }
    };
    try std.testing.expectEqualStrings("layout must be called, e.g. v.layout(.{})", comptime hints.mustBeCalled("layout", @TypeOf(S.withOptions)));
    try std.testing.expectEqualStrings("digest must be called, e.g. v.digest(.md5)", comptime hints.mustBeCalled("digest", @TypeOf(S.withSelector)));
    try std.testing.expectEqualStrings("atLeast must be called, e.g. v.atLeast(...)", comptime hints.mustBeCalled("atLeast", @TypeOf(S.withCount)));
    try std.testing.expectEqualStrings("each must be called, e.g. v.each(v.notEmpty)", comptime hints.mustBeCalled("each", @TypeOf(root.each)));
    try std.testing.expectEqualStrings(
        "custom must be called, e.g. v.custom(\"users.name_taken\", \"is taken\", isFree)",
        comptime hints.mustBeCalled("custom", @TypeOf(root.custom)),
    );
    try std.testing.expectEqualStrings("each", comptime constructorName(root.each).?);
    try std.testing.expectEqualStrings("custom", comptime constructorName(root.custom).?);
    // The constructors of a transform and of a name.
    try std.testing.expectEqualStrings("transformWith must be called, e.g. v.transformWith(normalizePhone)", comptime hints.mustBeCalled("transformWith", @TypeOf(root.transformWith)));
    try std.testing.expectEqualStrings("rename must be called, e.g. v.rename(\"userName\")", comptime hints.mustBeCalled("rename", @TypeOf(root.rename)));
    try std.testing.expectEqualStrings("rename", comptime constructorName(root.rename).?);
    // Every exported function is named, not only constructors: a built-in
    // predicate used as a rule is recognized by its name.
    try std.testing.expectEqualStrings("check", comptime constructorName(root.check).?);
    try std.testing.expectEqual(null, comptime constructorName(S.plain));
}

test "every exported constructor of a rule, a transform or a name shows a real call in its must-be-called hint" {
    const missing = comptime blk: {
        var out: []const u8 = "";
        for (@typeInfo(root).@"struct".decl_names) |decl| {
            const D = @TypeOf(@field(root, decl));
            if (@typeInfo(D) != .@"fn") continue;
            const R = @typeInfo(D).@"fn".return_type orelse void;
            if ((R == Rule or R == Transform or R == Rename) and std.mem.eql(u8, exampleArgs(decl, D), "..."))
                out = out ++ decl ++ " needs a call_examples entry\n";
        }
        break :blk out;
    };
    try std.testing.expectEqualStrings("", missing);
}

test "every transform is exported under its public name, the camelCase of its kind" {
    inline for (@typeInfo(TransformKind).@"enum".field_names) |tag| {
        const kind = @field(TransformKind, tag);
        const name = comptime transformName(kind);
        try std.testing.expectEqualStrings(tag, comptime snakeCase(name));
        const exported = @field(root, name);
        if (kind == .transform_with) {
            try std.testing.expectEqual(kind, (comptime exported(test_transforms.same)).kind);
        } else {
            try std.testing.expectEqual(kind, exported.kind);
        }
    }
}

test "hint for a predicate used as a rule" {
    const S = struct {
        const Options = struct { strict: bool = false };
        const Algorithm = enum { md5, sha1 };
        fn withOptions(comptime _: Options) void {}
        fn withSelector(comptime _: Algorithm) void {}
    };
    try std.testing.expectEqualStrings("expected a rule, got the predicate isPlain; use the rule v.plain", comptime hints.predicateAsRule("isPlain", "plain", Rule));
    try std.testing.expectEqualStrings("expected a rule, got the predicate isLayout; use the rule v.layout(.{})", comptime hints.predicateAsRule("isLayout", "layout", @TypeOf(S.withOptions)));
    try std.testing.expectEqualStrings("expected a rule, got the predicate isDigest; use the rule v.digest(.md5)", comptime hints.predicateAsRule("isDigest", "digest", @TypeOf(S.withSelector)));
    try std.testing.expectEqualStrings("date", comptime predicateRuleName("isDate").?);
    try std.testing.expectEqualStrings("base64Url", comptime predicateRuleName("isBase64Url").?);
    try std.testing.expectEqual(null, comptime predicateRuleName("isEven"));
    try std.testing.expectEqual(null, comptime predicateRuleName("isdate"));
    try std.testing.expectEqual(null, comptime predicateRuleName("each"));
    // The hint names a rule only when it is exported.
    const Exports = struct {
        pub const date = root.notEmpty;
    };
    try std.testing.expectEqualStrings("date", comptime exportedPredicateRule(Exports, "isDate").?);
    try std.testing.expectEqual(null, comptime exportedPredicateRule(Exports, "isEquals"));
    try std.testing.expectEqual(null, comptime exportedPredicateRule(Exports, "isEven"));
}
