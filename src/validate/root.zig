// Copied from vkiryakov/zefir src/validator/root.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! zefir-validator — validation rules declared on your structs: a struct
//! lists the rules of its fields in `pub const field_rules`, and `v.check`
//! returns the first violation of a value without allocating.
//!
//! ```zig
//! const SignUp = struct {
//!     name: []const u8,
//!     age: u8,
//!     tags: []const []const u8 = &.{},
//!
//!     pub const field_rules = .{
//!         .name = v.notEmpty,
//!         .age = v.positive,
//!         .tags = v.each(v.notEmpty),
//!     };
//! };
//!
//! var path_buf: [256]u8 = undefined;
//! if (v.check(&request, &path_buf)) |violation| {
//!     // violation.code, violation.message, violation.field ("tags[1]")
//!     std.debug.print("{s}: {s} ({s})\n", .{ violation.field orelse "(root)", violation.message, violation.code });
//! }
//! ```
//!
//! Rules are checked against their fields' types at compile time, when
//! `v.check`, `v.checkAll` or `v.assertRules` is instantiated for a type; a
//! mistake is a compile error that starts with "validator: ". Since Zig
//! compiles only code that is used, a DTO package calls
//! `comptime v.assertRules(T)` in a test. `v.checkAll` collects every
//! violation into a `Report`, `validateSelf` with `v.fail` checks across
//! fields, and `v.custom` turns a predicate of your own into a rule. The guide
//! is src/validator/examples/README.md.
//!
//! The entry of a field may also give it an outside name and transforms,
//! in this order before its rules:
//! `.user_name = .{ v.rename("userName"), v.trim, v.notBlank }`. The name is
//! what the paths of violations call the field; `v.nameOf` and
//! `v.fieldNamed` give it to a codec. `v.transform` runs the transforms
//! (`v.trim`, `v.toLower`, `v.transformWith(f)`, ...); call it before
//! `v.check` so that the rules check the transformed value.
//!
//! `v.schemaOf` gives an element of `field_rules` as JSON Schema keywords,
//! for a program that describes a DTO to its clients, such as an OpenAPI
//! document.

const std = @import("std");
const core = @import("core.zig");
const walk = @import("walk.zig");
const names = @import("names.zig");
const transforms = @import("transforms.zig");
const common = @import("common.zig");
const numbers = @import("numbers.zig");
const strings = @import("strings.zig");
const formats = @import("formats.zig");
const encodings = @import("encodings.zig");
const identifiers = @import("identifiers.zig");
const dates = @import("dates.zig");
const lists = @import("lists.zig");
const custom_rules = @import("custom.zig");
const schema = @import("schema.zig");

pub const Violation = core.Violation;
pub const Rule = core.Rule;
pub const Report = walk.Report;

pub const max_code_bytes = core.max_code_bytes;
pub const max_message_bytes = core.max_message_bytes;
pub const max_report_violations = core.max_report_violations;
pub const max_unique_items = core.max_unique_items;
pub const max_json_depth = core.max_json_depth;

pub const check = walk.check;
pub const checkAll = walk.checkAll;
pub const assertRules = walk.assertRules;
pub const fail = walk.fail;
pub const transform = walk.transform;
pub const TransformError = walk.TransformError;
/// The name among a list that a key is most likely a typo of, for the "did
/// you mean" of other modules' compile errors, by the rule of the
/// validator's own: `v.closest(&.{ "name", "email" }, "nmae")` is "name".
pub const closest = core.closest;

pub const rename = names.rename;
pub const nameOf = names.nameOf;
pub const fieldNamed = names.fieldNamed;
pub const trim = transforms.trim;
pub const trimStart = transforms.trimStart;
pub const trimEnd = transforms.trimEnd;
pub const toLower = transforms.toLower;
pub const toUpper = transforms.toUpper;
pub const transformWith = transforms.transformWith;

pub const equals = common.equals;
pub const notEquals = common.notEquals;
pub const oneOf = common.oneOf;
pub const noneOf = common.noneOf;
pub const empty = common.empty;
pub const notEmpty = common.notEmpty;
pub const min = numbers.min;
pub const max = numbers.max;
pub const range = numbers.range;
pub const positive = numbers.positive;
pub const nonNegative = numbers.nonNegative;
pub const negative = numbers.negative;
pub const nonPositive = numbers.nonPositive;
pub const divisibleBy = numbers.divisibleBy;
pub const finite = numbers.finite;
pub const minLength = strings.minLength;
pub const maxLength = strings.maxLength;
pub const length = strings.length;
pub const minBytes = strings.minBytes;
pub const maxBytes = strings.maxBytes;
pub const utf8 = strings.utf8;
pub const notBlank = strings.notBlank;
pub const ascii = strings.ascii;
pub const printableAscii = strings.printableAscii;
pub const alphanumeric = strings.alphanumeric;
pub const alpha = strings.alpha;
pub const digits = strings.digits;
pub const lowercase = strings.lowercase;
pub const uppercase = strings.uppercase;
pub const multibyte = strings.multibyte;
pub const fullWidth = strings.fullWidth;
pub const halfWidth = strings.halfWidth;
pub const variableWidth = strings.variableWidth;
pub const contains = strings.contains;
pub const notContains = strings.notContains;
pub const strongPassword = strings.strongPassword;
pub const StrongPasswordOptions = strings.StrongPasswordOptions;
pub const isUtf8 = strings.isUtf8;
pub const isNotBlank = strings.isNotBlank;
pub const isAscii = strings.isAscii;
pub const isPrintableAscii = strings.isPrintableAscii;
pub const isAlphanumeric = strings.isAlphanumeric;
pub const isAlpha = strings.isAlpha;
pub const isDigits = strings.isDigits;
pub const isLowercase = strings.isLowercase;
pub const isUppercase = strings.isUppercase;
pub const isMultibyte = strings.isMultibyte;
pub const isFullWidth = strings.isFullWidth;
pub const isHalfWidth = strings.isHalfWidth;
pub const isVariableWidth = strings.isVariableWidth;
pub const isStrongPassword = strings.isStrongPassword;
pub const numberString = formats.numberString;
pub const decimal = formats.decimal;
pub const booleanString = formats.booleanString;
pub const hexadecimal = formats.hexadecimal;
pub const octal = formats.octal;
pub const port = formats.port;
pub const latitude = formats.latitude;
pub const longitude = formats.longitude;
pub const latLong = formats.latLong;
pub const email = formats.email;
pub const httpUrl = formats.httpUrl;
pub const fqdn = formats.fqdn;
pub const ip = formats.ip;
pub const ipv4 = formats.ipv4;
pub const ipv6 = formats.ipv6;
pub const macAddress = formats.macAddress;
pub const DecimalOptions = formats.DecimalOptions;
pub const FqdnOptions = formats.FqdnOptions;
pub const MacAddressOptions = formats.MacAddressOptions;
pub const isNumberString = formats.isNumberString;
pub const isDecimal = formats.isDecimal;
pub const isBooleanString = formats.isBooleanString;
pub const isHexadecimal = formats.isHexadecimal;
pub const isOctal = formats.isOctal;
pub const isPort = formats.isPort;
pub const isLatitude = formats.isLatitude;
pub const isLongitude = formats.isLongitude;
pub const isLatLong = formats.isLatLong;
pub const isEmail = formats.isEmail;
pub const isHttpUrl = formats.isHttpUrl;
pub const isFqdn = formats.isFqdn;
pub const isIp = formats.isIp;
pub const isIpv4 = formats.isIpv4;
pub const isIpv6 = formats.isIpv6;
pub const isMacAddress = formats.isMacAddress;
pub const json = encodings.json;
pub const isJson = encodings.isJson;
pub const jwt = encodings.jwt;
pub const isJwt = encodings.isJwt;
pub const base32 = encodings.base32;
pub const isBase32 = encodings.isBase32;
pub const base58 = encodings.base58;
pub const isBase58 = encodings.isBase58;
pub const base64 = encodings.base64;
pub const isBase64 = encodings.isBase64;
pub const base64Url = encodings.base64Url;
pub const isBase64Url = encodings.isBase64Url;
pub const dataUri = encodings.dataUri;
pub const isDataUri = encodings.isDataUri;
pub const magnetUri = encodings.magnetUri;
pub const isMagnetUri = encodings.isMagnetUri;
pub const mimeType = encodings.mimeType;
pub const isMimeType = encodings.isMimeType;
pub const locale = encodings.locale;
pub const isLocale = encodings.isLocale;
pub const semVer = encodings.semVer;
pub const isSemVer = encodings.isSemVer;
pub const hexColor = encodings.hexColor;
pub const isHexColor = encodings.isHexColor;
pub const rgbColor = encodings.rgbColor;
pub const isRgbColor = encodings.isRgbColor;
pub const hslColor = encodings.hslColor;
pub const isHslColor = encodings.isHslColor;
pub const uuid = identifiers.uuid;
pub const mongoId = identifiers.mongoId;
pub const firebasePushId = identifiers.firebasePushId;
pub const hash = identifiers.hash;
pub const creditCard = identifiers.creditCard;
pub const isbn = identifiers.isbn;
pub const isbn10 = identifiers.isbn10;
pub const isbn13 = identifiers.isbn13;
pub const issn = identifiers.issn;
pub const ean = identifiers.ean;
pub const isin = identifiers.isin;
pub const isrc = identifiers.isrc;
pub const bic = identifiers.bic;
pub const iban = identifiers.iban;
pub const btcAddress = identifiers.btcAddress;
pub const ethereumAddress = identifiers.ethereumAddress;
pub const isUuid = identifiers.isUuid;
pub const isMongoId = identifiers.isMongoId;
pub const isFirebasePushId = identifiers.isFirebasePushId;
pub const isHash = identifiers.isHash;
pub const isCreditCard = identifiers.isCreditCard;
pub const isIsbn = identifiers.isIsbn;
pub const isIsbn10 = identifiers.isIsbn10;
pub const isIsbn13 = identifiers.isIsbn13;
pub const isIssn = identifiers.isIssn;
pub const isEan = identifiers.isEan;
pub const isIsin = identifiers.isIsin;
pub const isIsrc = identifiers.isIsrc;
pub const isBic = identifiers.isBic;
pub const isIban = identifiers.isIban;
pub const isBtcAddress = identifiers.isBtcAddress;
pub const isEthereumAddress = identifiers.isEthereumAddress;
pub const HashAlgorithm = identifiers.HashAlgorithm;
pub const BtcNetwork = identifiers.BtcNetwork;
pub const date = dates.date;
pub const isDate = dates.isDate;
pub const rfc3339 = dates.rfc3339;
pub const isRfc3339 = dates.isRfc3339;
pub const iso8601 = dates.iso8601;
pub const isIso8601 = dates.isIso8601;
pub const minDate = dates.minDate;
pub const maxDate = dates.maxDate;
pub const militaryTime = dates.militaryTime;
pub const isMilitaryTime = dates.isMilitaryTime;
pub const minItems = lists.minItems;
pub const maxItems = lists.maxItems;
pub const uniqueItems = lists.uniqueItems;
pub const uniqueBy = lists.uniqueBy;
pub const containsAll = lists.containsAll;
pub const containsNone = lists.containsNone;
pub const each = lists.each;
pub const custom = custom_rules.custom;

pub const RuleSchema = schema.RuleSchema;
pub const schemaOf = schema.schemaOf;

// Anole: what req.invalid and the typed-handler checks need from the core.
/// The compile-time check `v.custom` and `v.fail` apply to a code.
pub const checkCode = core.checkCode;
/// Why a code is malformed, or null.
pub const codeProblem = core.codeProblem;
/// Why a message is malformed (empty, > 512 bytes, invalid UTF-8), or null.
pub const messageProblem = core.messageProblem;
/// The compile error text for a message problem.
pub const describeMessageProblem = core.describeMessageProblem;

test {
    _ = core;
    _ = walk;
    _ = names;
    _ = transforms;
    _ = common;
    _ = numbers;
    _ = strings;
    _ = formats;
    _ = encodings;
    _ = identifiers;
    _ = dates;
    _ = lists;
    _ = custom_rules;
    _ = schema;
}

test "limits have their documented values" {
    try std.testing.expectEqual(128, max_code_bytes);
    try std.testing.expectEqual(512, max_message_bytes);
    try std.testing.expectEqual(100, max_report_violations);
    try std.testing.expectEqual(1000, max_unique_items);
    try std.testing.expectEqual(64, max_json_depth);
    // comptime_int, so a limit sizes an array or compares with any integer type.
    try std.testing.expect(@TypeOf(max_code_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_message_bytes) == comptime_int);
    try std.testing.expect(@TypeOf(max_report_violations) == comptime_int);
    try std.testing.expect(@TypeOf(max_unique_items) == comptime_int);
    try std.testing.expect(@TypeOf(max_json_depth) == comptime_int);
}

test "a violation has no field unless one is given" {
    const at_root: Violation = .{ .code = "users.name_taken", .message = "is taken" };
    try std.testing.expectEqual(null, at_root.field);
    const at_field: Violation = .{ .code = "users.name_taken", .message = "is taken", .field = "name" };
    try std.testing.expectEqualStrings("name", at_field.field.?);
}
