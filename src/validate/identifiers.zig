// Copied from vkiryakov/zefir src/validator/identifiers.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Identifier rules: `uuid`, `mongoId`, `firebasePushId`, `hash`,
//! `creditCard`, `isin`, `bic`, `iban`, `isbn`, `isbn10`, `isbn13`, `issn`,
//! `ean`, `isrc`, `btcAddress` and `ethereumAddress`, each with its
//! predicate (`v.isUuid`, ..., `v.isEthereumAddress`). The rules take
//! strings only and read bytes, never code points: a byte outside a rule's
//! ASCII alphabet, invalid UTF-8 included, fails under the rule's own code,
//! and `""` fails every rule. Nothing is trimmed, case-folded or normalized:
//! a rule accepts the canonical form of its identifier only, and no rule
//! looks a country, an issuer or a bank up in a table. A predicate takes any
//! input, allocates nothing and reads each byte a bounded number of times.
const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const Rule = core.Rule;
const Outcome = core.Outcome;

// ------------------------------------------------------------------ uuid, mongoId, firebasePushId

/// A UUID in the string form of RFC 9562: 36 bytes, `-` at indexes 8, 13, 18
/// and 23 and hex digits of any case elsewhere. The version and the variant
/// are not checked, so the Nil and Max UUIDs pass; braces, `urn:uuid:` and
/// the 32-digit form fail.
pub const uuid: Rule = core.predicateRule(.uuid, "must be a valid UUID", isUuid);

/// `s` passes `v.uuid`.
pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const ok = switch (i) {
            8, 13, 18, 23 => c == '-',
            else => std.ascii.isHex(c),
        };
        if (!ok) return false;
    }
    return true;
}

/// A MongoDB ObjectId as text: 24 hex digits of any case, as bson's
/// `ObjectId.isValid` takes a string; no `0x` or `0h` prefix.
pub const mongoId: Rule = core.predicateRule(.mongo_id, "must be a valid MongoDB ObjectId", isMongoId);

/// `s` passes `v.mongoId`.
pub fn isMongoId(s: []const u8) bool {
    return s.len == 24 and core.allHex(s);
}

/// A Firebase push ID: 20 bytes of the alphabet `-`, `0-9`, `A-Z`, `_`,
/// `a-z`. The timestamp in its first 8 characters is not decoded.
pub const firebasePushId: Rule = core.predicateRule(.firebase_push_id, "must be a valid Firebase push ID", isFirebasePushId);

/// `s` passes `v.firebasePushId`.
pub fn isFirebasePushId(s: []const u8) bool {
    if (s.len != 20) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

// ------------------------------------------------------------------ hash

/// The algorithms of `v.hash` and `v.isHash`, in class-validator's order. A
/// later release may add tags, which breaks an exhaustive `switch` on this
/// enum; it never removes or renames one.
pub const HashAlgorithm = enum { md4, md5, sha1, sha256, sha384, sha512, ripemd128, ripemd160, tiger128, tiger160, tiger192, crc32, crc32b };

/// The number of hex digits of a digest of `algorithm`.
fn hexLength(algorithm: HashAlgorithm) usize {
    return switch (algorithm) {
        .crc32, .crc32b => 8,
        .md4, .md5, .ripemd128, .tiger128 => 32,
        .sha1, .ripemd160, .tiger160 => 40,
        .tiger192 => 48,
        .sha256 => 64,
        .sha384 => 96,
        .sha512 => 128,
    };
}

/// A hex digest of `algorithm`: exactly its number of hex digits (8 for
/// `crc32` and `crc32b`; 32 for `md4`, `md5`, `ripemd128` and `tiger128`; 40
/// for `sha1`, `ripemd160` and `tiger160`; 48 for `tiger192`; 64, 96 and 128
/// for `sha256`, `sha384` and `sha512`), any case, no `0x` prefix. Nothing is
/// hashed: digests of the same length, such as md4 and md5, look alike.
/// `{algorithm}` is the tag's name: "must be a valid sha256 hash".
pub fn hash(comptime algorithm: HashAlgorithm) Rule {
    return core.define(.hash, .{
        .message = "must be a valid " ++ @tagName(algorithm) ++ " hash",
        .args = core.renderArg(algorithm),
        .params = &.{core.param("algorithm", algorithm)},
        .fits = core.fitsString,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isHash(value.*, algorithm));
            }
        }.eval,
    });
}

/// `s` passes `v.hash(algorithm)`. The algorithm may be known at run time
/// only.
pub fn isHash(s: []const u8, algorithm: HashAlgorithm) bool {
    return s.len == hexLength(algorithm) and core.allHex(s);
}

/// The arguments the hints show for an uncalled constructor of this file:
/// `hash must be called, e.g. v.hash(.sha256)`.
pub const call_examples = .{ .hash = ".sha256", .btcAddress = ".mainnet" };

// ------------------------------------------------------------------ creditCard, isin, bic, iban

fn isUpperAlnum(c: u8) bool {
    return std.ascii.isUpper(c) or std.ascii.isDigit(c);
}

/// What the decimal digit `d` adds to a Luhn sum: itself, or, when
/// `double`, twice itself less 9 above 9.
fn luhnDigit(d: u8, double: bool) u32 {
    if (!double) return d;
    const twice = 2 * @as(u32, d);
    return if (twice > 9) twice - 9 else twice;
}

/// The Luhn check (ISO/IEC 7812-1, annex B) over ASCII digits: from the
/// right, every second digit is doubled, starting left of the check digit,
/// and the sum is a multiple of 10.
fn luhnOk(digits: []const u8) bool {
    var sum: u32 = 0;
    var double = false;
    var i = digits.len;
    while (i > 0) {
        i -= 1;
        sum += luhnDigit(digits[i] - '0', double);
        double = !double;
    }
    return sum % 10 == 0;
}

/// A payment card number: 12 to 19 ASCII digits whose Luhn check digit
/// (ISO/IEC 7812-1) holds. There is no table of issuers, so any prefix
/// passes, a leading 0 included; spaces and hyphens fail.
pub const creditCard: Rule = core.predicateRule(.credit_card, "must be a valid credit card number", isCreditCard);

/// `s` passes `v.creditCard`.
pub fn isCreditCard(s: []const u8) bool {
    return s.len >= 12 and s.len <= 19 and core.allDigits(s) and luhnOk(s);
}

/// An ISIN (ISO 6166): 12 bytes, two upper-case letters, nine upper-case
/// letters or digits and a check digit. With each letter written as its
/// two-digit value (`A` = 10 … `Z` = 35), the digits pass the Luhn check.
/// The country prefix is not looked up: `XS` passes.
pub const isin: Rule = core.predicateRule(.isin, "must be a valid ISIN", isIsin);

/// `s` passes `v.isin`.
pub fn isIsin(s: []const u8) bool {
    if (s.len != 12) return false;
    if (!std.ascii.isUpper(s[0]) or !std.ascii.isUpper(s[1]) or !std.ascii.isDigit(s[11])) return false;
    for (s[2..11]) |c| {
        if (!isUpperAlnum(c)) return false;
    }
    // Luhn from the right over the digits that the letters expand to: a
    // letter adds its ones digit, then its tens digit.
    var sum: u32 = 0;
    var double = false;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isDigit(s[i])) {
            sum += luhnDigit(s[i] - '0', double);
            double = !double;
        } else {
            const value = s[i] - 'A' + 10;
            sum += luhnDigit(value % 10, double);
            sum += luhnDigit(value / 10, !double);
        }
    }
    return sum % 10 == 0;
}

/// A BIC (ISO 9362): 8 or 11 bytes; four upper-case letters for the
/// institution, two for the country, two upper-case letters or digits for
/// the location and, in 11 bytes, three more for the branch. The country is
/// not looked up: `DEUTXXFF` passes. Upper case only, no separators.
pub const bic: Rule = core.predicateRule(.bic, "must be a valid BIC", isBic);

/// `s` passes `v.bic`.
pub fn isBic(s: []const u8) bool {
    if (s.len != 8 and s.len != 11) return false;
    for (s[0..6]) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    for (s[6..]) |c| {
        if (!isUpperAlnum(c)) return false;
    }
    return true;
}

/// An IBAN in its electronic form (ISO 13616): 15 to 34 bytes; two
/// upper-case letters for the country, two check digits from 02 to 98 (00,
/// 01 and 99 would give one account a second spelling), then upper-case
/// letters and digits. With the first four bytes moved to the end and each
/// letter written as its value (`A` = 10 … `Z` = 35), the number leaves 1
/// modulo 97 (ISO 7064 MOD 97-10). The country is not looked up, and the
/// length is not checked per country. Upper case only, no spaces.
pub const iban: Rule = core.predicateRule(.iban, "must be a valid IBAN", isIban);

/// `s` passes `v.iban`.
pub fn isIban(s: []const u8) bool {
    if (s.len < 15 or s.len > 34) return false;
    if (!std.ascii.isUpper(s[0]) or !std.ascii.isUpper(s[1])) return false;
    if (!std.ascii.isDigit(s[2]) or !std.ascii.isDigit(s[3])) return false;
    const check = (s[2] - '0') * 10 + (s[3] - '0');
    if (check < 2 or check > 98) return false;
    for (s[4..]) |c| {
        if (!isUpperAlnum(c)) return false;
    }
    var remainder: u32 = 0;
    for (s[4..]) |c| remainder = mod97(remainder, c);
    for (s[0..4]) |c| remainder = mod97(remainder, c);
    return remainder == 1;
}

/// The MOD 97-10 remainder after the upper-case letter or digit `c`.
fn mod97(remainder: u32, c: u8) u32 {
    return if (std.ascii.isDigit(c)) (remainder * 10 + (c - '0')) % 97 else (remainder * 100 + (c - 'A' + 10)) % 97;
}

// ------------------------------------------------------------------ isbn, isbn10, isbn13, issn, ean, isrc

/// The GS1 check (EAN, GTIN, ISBN-13) over ASCII digits: from the right,
/// the check digit has weight 1, then 3, 1, 3, …, and the sum is a multiple
/// of 10.
fn gs1Ok(digits: []const u8) bool {
    var sum: u32 = 0;
    for (digits, 0..) |c, i| {
        const weight: u32 = if ((digits.len - 1 - i) % 2 == 1) 3 else 1;
        sum += weight * (c - '0');
    }
    return sum % 10 == 0;
}

/// An ISBN-10 or an ISBN-13, as `v.isbn10` and `v.isbn13` define them.
pub const isbn: Rule = core.predicateRule(.isbn, "must be a valid ISBN", isIsbn);

/// `s` passes `v.isbn`.
pub fn isIsbn(s: []const u8) bool {
    return isIsbn10(s) or isIsbn13(s);
}

/// An ISBN-10 without hyphens or spaces: nine digits and a check
/// character, a digit or an upper-case `X` for 10; the sum of each value
/// times its position (1 to 10) is a multiple of 11.
pub const isbn10: Rule = core.predicateRule(.isbn10, "must be a valid ISBN-10", isIsbn10);

/// `s` passes `v.isbn10`.
pub fn isIsbn10(s: []const u8) bool {
    if (s.len != 10) return false;
    var sum: u32 = 0;
    var position: u32 = 1;
    for (s[0..9]) |c| {
        if (!std.ascii.isDigit(c)) return false;
        sum += position * (c - '0');
        position += 1;
    }
    const check: u32 = if (s[9] == 'X') 10 else if (std.ascii.isDigit(s[9])) s[9] - '0' else return false;
    return (sum + 10 * check) % 11 == 0;
}

/// An ISBN-13 without hyphens or spaces: 13 digits with the GS1 check
/// digit, starting with 978, or with 979 and a digit other than 0 (979-0 is
/// the range of ISMN, the numbers of printed music).
pub const isbn13: Rule = core.predicateRule(.isbn13, "must be a valid ISBN-13", isIsbn13);

/// `s` passes `v.isbn13`.
pub fn isIsbn13(s: []const u8) bool {
    if (s.len != 13 or !core.allDigits(s)) return false;
    const prefix_ok = std.mem.startsWith(u8, s, "978") or (std.mem.startsWith(u8, s, "979") and s[3] != '0');
    return prefix_ok and gs1Ok(s);
}

/// An ISSN in its printed form `NNNN-NNNC` (ISO 3297): 9 bytes with one
/// hyphen, at index 4, and a check character, a digit or an upper-case `X`
/// for 10; the eight values weighted 8 down to 1 sum to a multiple of 11.
pub const issn: Rule = core.predicateRule(.issn, "must be a valid ISSN", isIssn);

/// `s` passes `v.issn`.
pub fn isIssn(s: []const u8) bool {
    if (s.len != 9 or s[4] != '-') return false;
    var sum: u32 = 0;
    var weight: u32 = 8;
    for (s, 0..) |c, i| {
        if (i == 4) continue;
        const value: u32 = if (std.ascii.isDigit(c)) c - '0' else if (i == 8 and c == 'X') 10 else return false;
        sum += weight * value;
        weight -= 1;
    }
    return sum % 11 == 0;
}

/// An EAN-8, EAN-13 or GTIN-14: 8, 13 or 14 digits with the GS1 check
/// digit. A 12-digit UPC-A fails: write it as an EAN-13 with a leading 0.
pub const ean: Rule = core.predicateRule(.ean, "must be a valid EAN", isEan);

/// `s` passes `v.ean`.
pub fn isEan(s: []const u8) bool {
    return (s.len == 8 or s.len == 13 or s.len == 14) and core.allDigits(s) and gs1Ok(s);
}

/// An ISRC (ISO 3901) without hyphens: 12 bytes; two upper-case letters for
/// the country, three upper-case letters or digits for the registrant, then
/// seven digits for the year and the recording. The country is not looked
/// up: `QM` passes. An ISRC has no check digit.
pub const isrc: Rule = core.predicateRule(.isrc, "must be a valid ISRC", isIsrc);

/// `s` passes `v.isrc`.
pub fn isIsrc(s: []const u8) bool {
    if (s.len != 12) return false;
    for (s, 0..) |c, i| {
        const ok = switch (i) {
            0, 1 => std.ascii.isUpper(c),
            2, 3, 4 => isUpperAlnum(c),
            else => std.ascii.isDigit(c),
        };
        if (!ok) return false;
    }
    return true;
}

// ------------------------------------------------------------------ btcAddress, ethereumAddress

/// The networks of `v.btcAddress` and `v.isBtcAddress`. `.testnet` also
/// takes the Base58 addresses of signet and regtest, which share its version
/// bytes, and signet's segwit addresses, which share its `tb1` prefix;
/// regtest's `bcrt1` addresses pass no network. `.any` is mainnet or
/// testnet.
pub const BtcNetwork = enum { mainnet, testnet, any };

/// A Bitcoin address of `network`, with its checksum verified, in one of
/// two forms. A segwit address (BIP-173, BIP-350), in lower case only: 10 to
/// 90 bytes, `bc1` on mainnet or `tb1` on testnet, then Bech32 symbols: the
/// witness version 0 to 16, the witness program and a checksum, Bech32 for
/// version 0 and Bech32m for the others; the program regroups into 2 to 40
/// bytes, 20 or 32 for version 0, with at most 4 padding bits, all zero. Or
/// a Base58Check address (P2PKH, P2SH): 1 to 35 bytes of the Base58
/// alphabet that decode to exactly 25 bytes, whose last 4 bytes are the
/// first 4 of SHA-256(SHA-256(the first 21)), and whose first byte, the
/// version, is 0x00 or 0x05 on mainnet and 0x6f or 0xc4 on testnet.
/// `{network}` is the tag's name; `.mainnet` and `.any` share the message
/// "must be a valid Bitcoin address".
pub fn btcAddress(comptime network: BtcNetwork) Rule {
    return core.define(.btc_address, .{
        .message = switch (network) {
            .mainnet, .any => "must be a valid Bitcoin address",
            .testnet => "must be a valid Bitcoin testnet address",
        },
        .args = core.renderArg(network),
        .params = &.{core.param("network", network)},
        .fits = core.fitsString,
        .eval = struct {
            fn eval(value: anytype) Outcome {
                return core.passIf(isBtcAddress(value.*, network));
            }
        }.eval,
    });
}

/// `s` passes `v.btcAddress(network)`. The network may be known at run time
/// only.
pub fn isBtcAddress(s: []const u8, network: BtcNetwork) bool {
    return isSegwitAddress(s, network) or isBase58Address(s, network);
}

const base58_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// The value of each byte in Base58, or 0xff for a byte outside the alphabet.
const base58_values: [256]u8 = blk: {
    var values: [256]u8 = @splat(0xff);
    for (base58_alphabet, 0..) |c, i| values[c] = i;
    break :blk values;
};

/// The Base58Check form of `v.btcAddress`. The number the symbols spell is
/// decoded into 25 bytes, big-endian; each leading `1` stands for one
/// leading zero byte, so the decoded length is 25 exactly when the leading
/// `1`s and the leading zero bytes are as many.
fn isBase58Address(s: []const u8, network: BtcNetwork) bool {
    if (s.len == 0 or s.len > 35) return false;
    var bytes: [25]u8 = @splat(0);
    var leading_ones: usize = 0;
    var in_prefix = true;
    for (s) |c| {
        const digit = base58_values[c];
        if (digit == 0xff) return false;
        if (in_prefix and digit == 0) leading_ones += 1 else in_prefix = false;
        // bytes = bytes * 58 + digit; a carry out of the first byte means
        // more than 25 bytes.
        var carry: u32 = digit;
        var i: usize = bytes.len;
        while (i > 0) {
            i -= 1;
            carry += @as(u32, bytes[i]) * 58;
            bytes[i] = @truncate(carry);
            carry >>= 8;
        }
        if (carry != 0) return false;
    }
    var leading_zeros: usize = 0;
    while (leading_zeros < bytes.len and bytes[leading_zeros] == 0) leading_zeros += 1;
    if (leading_zeros != leading_ones) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var first: [Sha256.digest_length]u8 = undefined;
    var second: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[0..21], &first, .{});
    Sha256.hash(&first, &second, .{});
    if (!std.mem.eql(u8, second[0..4], bytes[21..25])) return false;
    return switch (bytes[0]) {
        0x00, 0x05 => network != .testnet,
        0x6f, 0xc4 => network != .mainnet,
        else => false,
    };
}

const bech32_alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// The value of each byte in the lower-case Bech32 alphabet, or 0xff.
const bech32_values: [256]u8 = blk: {
    var values: [256]u8 = @splat(0xff);
    for (bech32_alphabet, 0..) |c, i| values[c] = i;
    break :blk values;
};

/// One step of the BIP-173 checksum over the 5-bit `value`.
fn polymodStep(checksum: u32, value: u8) u32 {
    const top = checksum >> 25;
    var next = ((checksum & 0x1ffffff) << 5) ^ value;
    const generators = [5]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
    inline for (generators, 0..) |generator, i| {
        if ((top >> i) & 1 != 0) next ^= generator;
    }
    return next;
}

/// The segwit form of `v.btcAddress`. Bech32 has no `1`, so the separator
/// is the `1` after the network's prefix, `bc` or `tb`; the checksum covers
/// the prefix too.
fn isSegwitAddress(s: []const u8, network: BtcNetwork) bool {
    if (s.len < 10 or s.len > 90) return false;
    const prefix: []const u8 = if (std.mem.startsWith(u8, s, "bc1") and network != .testnet)
        "bc"
    else if (std.mem.startsWith(u8, s, "tb1") and network != .mainnet)
        "tb"
    else
        return false;
    const data = s[3..];
    var checksum: u32 = 1;
    for (prefix) |c| checksum = polymodStep(checksum, c >> 5);
    checksum = polymodStep(checksum, 0);
    for (prefix) |c| checksum = polymodStep(checksum, c & 31);
    for (data) |c| {
        const value = bech32_values[c];
        if (value == 0xff) return false;
        checksum = polymodStep(checksum, value);
    }
    const version = bech32_values[data[0]];
    if (version > 16) return false;
    if (checksum != @as(u32, if (version == 0) 1 else 0x2bc830a3)) return false;
    // The program: the symbols between the version and the 6 of the
    // checksum, regrouped from 5 bits into bytes.
    var pending: u32 = 0;
    var bits: u5 = 0;
    var bytes: usize = 0;
    for (data[1 .. data.len - 6]) |c| {
        pending = ((pending << 5) | bech32_values[c]) & 0xfff;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            bytes += 1;
        }
    }
    if (bits > 4 or pending & ((@as(u32, 1) << bits) - 1) != 0) return false;
    if (bytes < 2 or bytes > 40) return false;
    return version != 0 or bytes == 20 or bytes == 32;
}

/// An Ethereum address: `0x` (with a lower-case `x`) and 40 hex digits.
/// Digits whose letters are all lower case or all upper case carry no
/// checksum and pass; in mixed case they follow the EIP-55 checksum: a
/// letter is upper case exactly when the matching hex digit of the
/// Keccak-256 hash of the 40 digits in lower case is 8 or more. Keccak-256
/// is Ethereum's hash, not SHA3-256.
pub const ethereumAddress: Rule = core.predicateRule(.ethereum_address, "must be a valid Ethereum address", isEthereumAddress);

/// `s` passes `v.ethereumAddress`.
pub fn isEthereumAddress(s: []const u8) bool {
    if (s.len != 42 or s[0] != '0' or s[1] != 'x') return false;
    const digits = s[2..];
    var has_lower = false;
    var has_upper = false;
    for (digits) |c| {
        switch (c) {
            '0'...'9' => {},
            'a'...'f' => has_lower = true,
            'A'...'F' => has_upper = true,
            else => return false,
        }
    }
    if (!has_lower or !has_upper) return true;
    var lower: [40]u8 = undefined;
    for (digits, &lower) |c, *l| l.* = std.ascii.toLower(c);
    var digest: [std.crypto.hash.sha3.Keccak256.digest_length]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&lower, &digest, .{});
    for (digits, 0..) |c, i| {
        if (std.ascii.isDigit(c)) continue;
        const nibble = if (i % 2 == 0) digest[i / 2] >> 4 else digest[i / 2] & 0x0f;
        if ((nibble >= 8) != std.ascii.isUpper(c)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ schema

/// The JSON Schema keywords of a rule of this file on the unwrapped field
/// type `T`, for `v.schemaOf`. An identifier without a check digit is an
/// exact pattern; a checksum is beyond a pattern, so the rules with one get
/// the form of the identifier, approximate.
pub fn schemaOf(comptime rule: Rule, comptime T: type) schema.RuleSchema {
    _ = T;
    return switch (rule.kind) {
        .uuid => schema.exact(&.{ schema.format("uuid"), schema.pattern("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$") }),
        .mongo_id => schema.exact(&.{schema.pattern("^[0-9A-Fa-f]{24}$")}),
        .firebase_push_id => schema.exact(&.{schema.pattern("^[0-9A-Za-z_-]{20}$")}),
        .hash => blk: {
            const digits = hexLength(@field(HashAlgorithm, rule.params[0].value.tag));
            break :blk schema.exact(&.{schema.pattern("^[0-9A-Fa-f]" ++ schema.repetition(digits, digits) ++ "$")});
        },
        .credit_card => schema.approximate(&.{schema.pattern("^[0-9]{12,19}$")}, "a valid credit card number, with its Luhn check digit"),
        .isbn => schema.approximate(&.{schema.pattern("^(?:[0-9]{9}[0-9X]|97(?:8[0-9]|9[1-9])[0-9]{9})$")}, "a valid ISBN-10 or ISBN-13, with its check digit"),
        .isbn10 => schema.approximate(&.{schema.pattern("^[0-9]{9}[0-9X]$")}, "a valid ISBN-10, with its check digit"),
        .isbn13 => schema.approximate(&.{schema.pattern("^97(?:8[0-9]|9[1-9])[0-9]{9}$")}, "a valid ISBN-13, with its check digit"),
        .issn => schema.approximate(&.{schema.pattern("^[0-9]{4}-[0-9]{3}[0-9X]$")}, "a valid ISSN, with its check digit"),
        .ean => schema.approximate(&.{schema.pattern("^(?:[0-9]{8}|[0-9]{13,14})$")}, "a valid EAN, with its check digit"),
        .isin => schema.approximate(&.{schema.pattern("^[A-Z]{2}[0-9A-Z]{9}[0-9]$")}, "a valid ISIN, with its check digit"),
        .isrc => schema.exact(&.{schema.pattern("^[A-Z]{2}[0-9A-Z]{3}[0-9]{7}$")}),
        .bic => schema.exact(&.{schema.pattern("^[A-Z]{6}[0-9A-Z]{2}(?:[0-9A-Z]{3})?$")}),
        .iban => schema.approximate(&.{schema.pattern("^[A-Z]{2}(?:0[2-9]|[1-8][0-9]|9[0-8])[0-9A-Z]{11,30}$")}, "a valid IBAN, with its MOD 97-10 check digits"),
        .btc_address => btcAddressSchema(@field(BtcNetwork, rule.params[0].value.tag)),
        .ethereum_address => schema.approximate(&.{schema.pattern("^0x[0-9A-Fa-f]{40}$")}, "a valid Ethereum address, with the EIP-55 checksum when the letters mix cases"),
        else => unreachable,
    };
}

/// `btcAddress(network)`: the prefix, the alphabet and the length of each
/// form; the checksums are beyond a pattern. A Base58Check address of
/// mainnet starts with `1` (version 0x00) or `3` (0x05), one of testnet with
/// `m` or `n` (0x6f) or `2` (0xc4).
fn btcAddressSchema(comptime network: BtcNetwork) schema.RuleSchema {
    const segwit, const base58, const name = switch (network) {
        .mainnet => .{ "bc1", "[13]", "Bitcoin address" },
        .testnet => .{ "tb1", "[2mn]", "Bitcoin testnet address" },
        .any => .{ "(?:bc|tb)1", "[123mn]", "Bitcoin mainnet or testnet address" },
    };
    // Bech32 has no 1, b, i or o; Base58 no 0, O, I or l.
    const regex = "^(?:" ++ segwit ++ "[02-9ac-hj-np-z]{7,87}|" ++ base58 ++ "[1-9A-HJ-NP-Za-km-z]{0,34})$";
    return schema.approximate(&.{schema.pattern(regex)}, "a valid " ++ name ++ ", with its checksum");
}

// ------------------------------------------------------------------ tests

const expectOutcome = core.expectOutcome;

const test_where = "Dto.field_rules.x";

/// The declaration error of `rule` on a field whose unwrapped type is `T`,
/// or null.
fn typeText(comptime rule: Rule, comptime T: type) ?[]const u8 {
    return core.stringProblem(&rule, T, test_where, null);
}

/// `predicate` accepts every string of `good` and rejects every one of `bad`.
fn expectPredicate(predicate: fn ([]const u8) bool, good: []const []const u8, bad: []const []const u8) !void {
    for (good) |s| {
        if (!predicate(s)) {
            std.debug.print("expected a pass: \"{f}\"\n", .{std.zig.fmtString(s)});
            return error.TestExpectedPass;
        }
    }
    for (bad) |s| {
        if (predicate(s)) {
            std.debug.print("expected a failure: \"{f}\"\n", .{std.zig.fmtString(s)});
            return error.TestExpectedFailure;
        }
    }
}

test "the rules without parameters have their documented codes and messages and no precondition" {
    const t = std.testing;
    const rules = .{
        .{ uuid, core.Kind.uuid, "validation.uuid", "must be a valid UUID" },
        .{ mongoId, core.Kind.mongo_id, "validation.mongo_id", "must be a valid MongoDB ObjectId" },
        .{ firebasePushId, core.Kind.firebase_push_id, "validation.firebase_push_id", "must be a valid Firebase push ID" },
        .{ creditCard, core.Kind.credit_card, "validation.credit_card", "must be a valid credit card number" },
        .{ isin, core.Kind.isin, "validation.isin", "must be a valid ISIN" },
        .{ bic, core.Kind.bic, "validation.bic", "must be a valid BIC" },
        .{ iban, core.Kind.iban, "validation.iban", "must be a valid IBAN" },
        .{ isbn, core.Kind.isbn, "validation.isbn", "must be a valid ISBN" },
        .{ isbn10, core.Kind.isbn10, "validation.isbn10", "must be a valid ISBN-10" },
        .{ isbn13, core.Kind.isbn13, "validation.isbn13", "must be a valid ISBN-13" },
        .{ issn, core.Kind.issn, "validation.issn", "must be a valid ISSN" },
        .{ ean, core.Kind.ean, "validation.ean", "must be a valid EAN" },
        .{ isrc, core.Kind.isrc, "validation.isrc", "must be a valid ISRC" },
        .{ ethereumAddress, core.Kind.ethereum_address, "validation.ethereum_address", "must be a valid Ethereum address" },
    };
    inline for (rules) |row| {
        try t.expectEqual(row[1], row[0].kind);
        try t.expectEqualStrings(row[2], row[0].code);
        try t.expectEqualStrings(row[3], row[0].message);
        try t.expectEqual(null, row[0].args);
        try t.expectEqual(0, row[0].params.len);
        try t.expectEqual(null, row[0].precondition);
    }
    try t.expectEqualStrings("firebasePushId", comptime firebasePushId.call());
    try t.expectEqualStrings("firebase_push_id", comptime firebasePushId.label());
}

test "hash names its algorithm in the message and in the placeholder {algorithm}" {
    const t = std.testing;
    const sha = hash(.sha256);
    try t.expectEqual(core.Kind.hash, sha.kind);
    try t.expectEqualStrings("validation.hash", sha.code);
    try t.expectEqualStrings("must be a valid sha256 hash", sha.message);
    try t.expectEqualStrings(".sha256", sha.args.?);
    try t.expectEqual(1, sha.params.len);
    try t.expectEqualStrings("algorithm", sha.params[0].name);
    try t.expectEqualStrings("sha256", sha.params[0].text);
    try t.expectEqualStrings("sha256", sha.params[0].value.tag);
    try t.expect(sha.params[0].placeholder);
    try t.expectEqual(null, sha.precondition);
    try t.expectEqualStrings("hash(.sha256)", comptime sha.call());
    try t.expectEqualStrings("hash(.crc32b)", comptime hash(.crc32b).label());
    inline for (comptime std.enums.values(HashAlgorithm)) |algorithm| {
        try t.expectEqualStrings("must be a valid " ++ @tagName(algorithm) ++ " hash", hash(algorithm).message);
    }
}

test "btcAddress names its network in the placeholder {network}; testnet has its own message" {
    const t = std.testing;
    const main = btcAddress(.mainnet);
    try t.expectEqual(core.Kind.btc_address, main.kind);
    try t.expectEqualStrings("validation.btc_address", main.code);
    try t.expectEqualStrings("must be a valid Bitcoin address", main.message);
    try t.expectEqualStrings(".mainnet", main.args.?);
    try t.expectEqual(1, main.params.len);
    try t.expectEqualStrings("network", main.params[0].name);
    try t.expectEqualStrings("mainnet", main.params[0].text);
    try t.expect(main.params[0].placeholder);
    try t.expectEqual(null, main.precondition);
    try t.expectEqualStrings("must be a valid Bitcoin testnet address", btcAddress(.testnet).message);
    try t.expectEqualStrings("must be a valid Bitcoin address", btcAddress(.any).message);
    try t.expectEqualStrings("any", btcAddress(.any).params[0].text);
    try t.expectEqualStrings("btcAddress(.any)", comptime btcAddress(.any).call());
    try t.expectEqualStrings("btc_address(.testnet)", comptime btcAddress(.testnet).label());
}

test "the rules take strings only: [N]u8 and lists of strings get hints, other types none" {
    const expect = std.testing.expectEqualStrings;
    const head = "validator: Dto.field_rules.x: ";
    const u8_array = "; [N]u8 is an array of numbers, not a string: use []const u8";
    try expect(head ++ "uuid expects a string, field is u128", comptime typeText(uuid, u128).?);
    try expect(head ++ "uuid expects a string, field is [16]u8" ++ u8_array, comptime typeText(uuid, [16]u8).?);
    try expect(head ++ "uuid expects a string, field is []const []const u8; use v.each(v.uuid)", comptime typeText(uuid, []const []const u8).?);
    try expect(head ++ "mongo_id expects a string, field is u96", comptime typeText(mongoId, u96).?);
    try expect(head ++ "mongo_id expects a string, field is [12]u8" ++ u8_array, comptime typeText(mongoId, [12]u8).?);
    try expect(head ++ "mongo_id expects a string, field is []const []const u8; use v.each(v.mongoId)", comptime typeText(mongoId, []const []const u8).?);
    try expect(head ++ "firebase_push_id expects a string, field is u64", comptime typeText(firebasePushId, u64).?);
    try expect(head ++ "firebase_push_id expects a string, field is [20:0]u8" ++ u8_array, comptime typeText(firebasePushId, [20:0]u8).?);
    try expect(head ++ "firebase_push_id expects a string, field is [2]?[]const u8; use v.each(v.firebasePushId)", comptime typeText(firebasePushId, [2]?[]const u8).?);
    try expect(head ++ "hash expects a string, field is u256", comptime typeText(hash(.sha256), u256).?);
    try expect(head ++ "hash expects a string, field is [32]u8" ++ u8_array, comptime typeText(hash(.sha256), [32]u8).?);
    try expect(head ++ "hash expects a string, field is []const []const u8; use v.each(v.hash(.sha256))", comptime typeText(hash(.sha256), []const []const u8).?);
    try expect(head ++ "credit_card expects a string, field is u64", comptime typeText(creditCard, u64).?);
    try expect(head ++ "credit_card expects a string, field is [16]u8" ++ u8_array, comptime typeText(creditCard, [16]u8).?);
    try expect(head ++ "credit_card expects a string, field is []const []const u8; use v.each(v.creditCard)", comptime typeText(creditCard, []const []const u8).?);
    try expect(head ++ "isin expects a string, field is u64", comptime typeText(isin, u64).?);
    try expect(head ++ "isin expects a string, field is [12]u8" ++ u8_array, comptime typeText(isin, [12]u8).?);
    try expect(head ++ "isin expects a string, field is []const []const u8; use v.each(v.isin)", comptime typeText(isin, []const []const u8).?);
    try expect(head ++ "bic expects a string, field is u64", comptime typeText(bic, u64).?);
    try expect(head ++ "bic expects a string, field is [11]u8" ++ u8_array, comptime typeText(bic, [11]u8).?);
    try expect(head ++ "bic expects a string, field is []const []const u8; use v.each(v.bic)", comptime typeText(bic, []const []const u8).?);
    try expect(head ++ "iban expects a string, field is u128", comptime typeText(iban, u128).?);
    try expect(head ++ "iban expects a string, field is [34]u8" ++ u8_array, comptime typeText(iban, [34]u8).?);
    try expect(head ++ "iban expects a string, field is []const []const u8; use v.each(v.iban)", comptime typeText(iban, []const []const u8).?);
    try expect(head ++ "isbn expects a string, field is u64", comptime typeText(isbn, u64).?);
    try expect(head ++ "isbn expects a string, field is [13]u8" ++ u8_array, comptime typeText(isbn, [13]u8).?);
    try expect(head ++ "isbn expects a string, field is []const []const u8; use v.each(v.isbn)", comptime typeText(isbn, []const []const u8).?);
    try expect(head ++ "isbn10 expects a string, field is u64", comptime typeText(isbn10, u64).?);
    try expect(head ++ "isbn10 expects a string, field is [10]u8" ++ u8_array, comptime typeText(isbn10, [10]u8).?);
    try expect(head ++ "isbn10 expects a string, field is []const []const u8; use v.each(v.isbn10)", comptime typeText(isbn10, []const []const u8).?);
    try expect(head ++ "isbn13 expects a string, field is u64", comptime typeText(isbn13, u64).?);
    try expect(head ++ "isbn13 expects a string, field is [13]u8" ++ u8_array, comptime typeText(isbn13, [13]u8).?);
    try expect(head ++ "isbn13 expects a string, field is []const []const u8; use v.each(v.isbn13)", comptime typeText(isbn13, []const []const u8).?);
    try expect(head ++ "issn expects a string, field is u32", comptime typeText(issn, u32).?);
    try expect(head ++ "issn expects a string, field is [9]u8" ++ u8_array, comptime typeText(issn, [9]u8).?);
    try expect(head ++ "issn expects a string, field is []const []const u8; use v.each(v.issn)", comptime typeText(issn, []const []const u8).?);
    try expect(head ++ "ean expects a string, field is u64", comptime typeText(ean, u64).?);
    try expect(head ++ "ean expects a string, field is [13]u8" ++ u8_array, comptime typeText(ean, [13]u8).?);
    try expect(head ++ "ean expects a string, field is []const []const u8; use v.each(v.ean)", comptime typeText(ean, []const []const u8).?);
    try expect(head ++ "isrc expects a string, field is u64", comptime typeText(isrc, u64).?);
    try expect(head ++ "isrc expects a string, field is [12]u8" ++ u8_array, comptime typeText(isrc, [12]u8).?);
    try expect(head ++ "isrc expects a string, field is []const []const u8; use v.each(v.isrc)", comptime typeText(isrc, []const []const u8).?);
    try expect(head ++ "btc_address expects a string, field is u160", comptime typeText(btcAddress(.mainnet), u160).?);
    try expect(head ++ "btc_address expects a string, field is [25]u8" ++ u8_array, comptime typeText(btcAddress(.mainnet), [25]u8).?);
    try expect(head ++ "btc_address expects a string, field is []const []const u8; use v.each(v.btcAddress(.mainnet))", comptime typeText(btcAddress(.mainnet), []const []const u8).?);
    try expect(head ++ "btc_address expects a string, field is []const []const u8; use v.each(v.btcAddress(.any))", comptime typeText(btcAddress(.any), []const []const u8).?);
    try expect(head ++ "ethereum_address expects a string, field is u160", comptime typeText(ethereumAddress, u160).?);
    try expect(head ++ "ethereum_address expects a string, field is [20]u8" ++ u8_array, comptime typeText(ethereumAddress, [20]u8).?);
    try expect(head ++ "ethereum_address expects a string, field is []const []const u8; use v.each(v.ethereumAddress)", comptime typeText(ethereumAddress, []const []const u8).?);
    try expect(
        head ++ "uuid expects a string, field is []volatile u8; volatile, allowzero and under-aligned slices are neither strings nor lists",
        comptime typeText(uuid, []volatile u8).?,
    );
    inline for (.{ []const u8, []u8, [:0]const u8, [:0]u8, []align(4) const u8 }) |T| {
        try std.testing.expectEqual(null, comptime typeText(uuid, T));
        try std.testing.expectEqual(null, comptime typeText(hash(.md5), T));
    }
}

test "an uncalled hash or btcAddress shows a call; their predicates in place of a rule name that call" {
    const expect = std.testing.expectEqualStrings;
    try expect("hash must be called, e.g. v.hash(.sha256)", comptime core.hints.mustBeCalled("hash", @TypeOf(hash)));
    try expect("btcAddress must be called, e.g. v.btcAddress(.mainnet)", comptime core.hints.mustBeCalled("btcAddress", @TypeOf(btcAddress)));
    try expect("expected a rule, got the predicate isHash; use the rule v.hash(.sha256)", comptime core.hints.predicateAsRule("isHash", "hash", @TypeOf(hash)));
    try expect("expected a rule, got the predicate isBtcAddress; use the rule v.btcAddress(.mainnet)", comptime core.hints.predicateAsRule("isBtcAddress", "btcAddress", @TypeOf(btcAddress)));
    try expect("expected a rule, got the predicate isUuid; use the rule v.uuid", comptime core.hints.predicateAsRule("isUuid", "uuid", Rule));
}

test "the rules pass what their predicates accept" {
    try expectOutcome(.pass, uuid, @as([]const u8, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6"));
    try expectOutcome(.fail, uuid, @as([]const u8, "f81d4fae7dec11d0a76500a0c91e6bf6"));
    var buffer = "507f1f77bcf86cd799439011".*;
    try expectOutcome(.pass, mongoId, @as([]u8, &buffer));
    try expectOutcome(.fail, mongoId, @as([:0]const u8, "507f1f77bcf86cd79943901"));
    try expectOutcome(.pass, firebasePushId, @as([:0]const u8, "-JhLeOlGIEjaIOFHR0xd"));
    try expectOutcome(.pass, hash(.md5), @as([]const u8, "d41d8cd98f00b204e9800998ecf8427e"));
    try expectOutcome(.fail, hash(.sha256), @as([]const u8, "d41d8cd98f00b204e9800998ecf8427e"));
}

test "uuid: 8-4-4-4-12 hex digits of any case, version and variant unchecked" {
    try expectPredicate(isUuid, &.{
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        "f81D4fae-7DEC-11d0-A765-00a0C91e6bf6",
        "017f22e2-79b0-7cc3-98c4-dc0c0c07398f",
        "00000000-0000-0000-0000-000000000000",
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "00000000-0000-0000-c000-000000000046",
        "919108f7-52d1-3320-5bac-f847db4148a8",
    }, &.{
        "",
        "f81d4fae7dec11d0a76500a0c91e6bf6",
        "{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
        "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf60",
        "f81d4fa-e7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765_00a0c91e6bf6",
        "g81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        " f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6\n",
        "f81d4fae\u{2013}7dec-11d0-a765-00a0c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0-c91e6bf6",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf\xff",
    });
}

test "mongoId: 24 hex digits of any case, no prefix" {
    try expectPredicate(isMongoId, &.{
        "507f1f77bcf86cd799439011",
        "507F1F77BCF86CD799439011",
        "000000000000000000000000",
    }, &.{
        "",
        "507f1f77bcf86cd79943901",
        "507f1f77bcf86cd7994390111",
        "507f1f77bcf86cd79943901g",
        "0xaaaaaaaaaaaaaaaaaaaaaa",
        "0haaaaaaaaaaaaaaaaaaaaaa",
        " 07f1f77bcf86cd799439011",
        "507f1f77-bcf8-6cd7-9943-9011",
        "ObjectId(\"507f1f77bcf86cd799439011\")",
        "507f1f77bcf86cd79943901\u{ff11}",
    });
}

test "firebasePushId: 20 bytes of -0-9A-Z_a-z" {
    try expectPredicate(isFirebasePushId, &.{
        "-JhLeOlGIEjaIOFHR0xd",
        "_JhLeOlGIEjaIOFHR0xd",
        "--------------------",
        "abcdefghijklmnopqrst",
    }, &.{
        "",
        "-JhLeOlGIEjaIOFHR0x",
        "-JhLeOlGIEjaIOFHR0xdd",
        "-JhLeOlGIEjaIOFHR0x.",
        "-JhLeOlGIEjaIOFHR0x+",
        "-JhLeOlGIEjaIOFHR0x ",
        "-JhLeOlGIEjaIOFHR0x\u{e9}",
    });
}

test "hash: each algorithm takes exactly its number of hex digits, any case" {
    const t = std.testing;
    const lengths = .{ .{ .md4, 32 }, .{ .md5, 32 }, .{ .sha1, 40 }, .{ .sha256, 64 }, .{ .sha384, 96 }, .{ .sha512, 128 }, .{ .ripemd128, 32 }, .{ .ripemd160, 40 }, .{ .tiger128, 32 }, .{ .tiger160, 40 }, .{ .tiger192, 48 }, .{ .crc32, 8 }, .{ .crc32b, 8 } };
    try t.expectEqual(std.enums.values(HashAlgorithm).len, lengths.len);
    inline for (lengths) |row| {
        const algorithm: HashAlgorithm = row[0];
        const n = row[1];
        try t.expect(isHash(&@as([n]u8, @splat('F')), algorithm));
        try t.expect(isHash(&@as([n]u8, @splat('9')), algorithm));
        try t.expect(!isHash(&@as([n - 1]u8, @splat('a')), algorithm));
        try t.expect(!isHash(&@as([n + 1]u8, @splat('a')), algorithm));
        try t.expect(!isHash("0x" ++ &@as([n - 2]u8, @splat('a')), algorithm));
        try t.expect(!isHash("g" ++ &@as([n - 1]u8, @splat('a')), algorithm));
    }
    try t.expect(isHash("d41d8cd98f00b204e9800998ecf8427e", .md5));
    try t.expect(isHash("D41D8CD98F00B204E9800998ECF8427E", .md5));
    try t.expect(isHash("31d6cfe0d16ae931b73c59d7e0c089c0", .md4));
    try t.expect(isHash("da39a3ee5e6b4b0d3255bfef95601890afd80709", .sha1));
    try t.expect(isHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", .sha256));
    try t.expect(isHash("38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b", .sha384));
    try t.expect(isHash("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e", .sha512));
    try t.expect(isHash("31d6cfe0d16ae931b73c59d7e0c089c0", .ripemd128));
    try t.expect(isHash("9c1185a5c5e9fc54612808977ee8f548b2258d31", .ripemd160));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e1616", .tiger128));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e16167a4e5849", .tiger160));
    try t.expect(isHash("3293ac630c13f0245f92bbb1766e16167a4e58492dde73f3", .tiger192));
    try t.expect(isHash("cbf43926", .crc32) and isHash("CBF43926", .crc32b));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427e", .sha256));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427", .md5));
    try t.expect(!isHash("d41d8cd98f00b204e9800998ecf8427g", .md5));
    try t.expect(!isHash("0xd41d8cd98f00b204e9800998ecf842", .md5));
    try t.expect(!isHash(" da39a3ee5e6b4b0d3255bfef95601890afd8070", .sha1));
    try t.expect(!isHash("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", .sha256));
    try t.expect(!isHash("", .crc32));
}

test "creditCard: 12 to 19 digits with a valid Luhn check digit, any issuer, no separators" {
    try expectPredicate(isCreditCard, &.{
        "4111111111111111",
        "4222222222222",
        "4000000000000000006",
        "378282246310005",
        "5555555555554444",
        "2221000000000009",
        "30569309025904",
        "6011111111111117",
        "3530111333300000",
        "6200000000000005",
        "2200700000000009",
        "675900000000",
        "6440000000000005",
        "9792000000000003",
        "0000000000000",
    }, &.{
        "",
        "4111111111111112",
        "4111 1111 1111 1111",
        "4111-1111-1111-1111",
        " 4111111111111111 ",
        "4111\t1111111111111",
        "4111111111111111\n",
        "12345678903",
        "51000008",
        "510000000000000000000008",
        "99992221000000000003",
        "\u{ff14}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}\u{ff11}",
    });
}

test "isin: two letters, nine letters or digits and a Luhn check digit over the letters' values" {
    try expectPredicate(isIsin, &.{
        "US0378331005",
        "AU0000XVGZA3",
        "GB0002634946",
        "DE000BAY0017",
        "XS2021832634",
    }, &.{
        "",
        "US0378331006",
        "us0378331005",
        "US037833100",
        "US03783310055",
        "US-037833100-5",
        "1S0378331005",
        "US037833100X",
    });
}

test "bic: 4 + 2 letters, 2 letters or digits, an optional branch of 3; any country code" {
    try expectPredicate(isBic, &.{
        "DEUTDEFF",
        "DEUTDEFF500",
        "DEUTDEFFXXX",
        "NEDSZAJJ",
        "ABCDXK22",
        "DEUTXXFF",
        "DEUTUKFF",
    }, &.{
        "",
        "deutdeff",
        "DEUTDEff",
        "DEUTDEF",
        "DEUTDEFF5",
        "DEUTDEFF50",
        "DEU1DEFF",
        "DEUT DE FF",
        "DEUT12FF",
        "DEUTDEFF500X",
    });
}

test "iban: 15 to 34 bytes, check digits 02 to 98 and MOD 97-10, any country, upper case only" {
    try expectPredicate(isIban, &.{
        "DE89370400440532013000",
        "GB82WEST12345698765432",
        "NO9386011117947",
        "RU0304452522540817810538091310419",
        "BY13NBRB3600900000002Z00AB00",
        "DE98370400441000000008",
        "DE02370400440000000024",
        "DZ910001234567890123456789",
        "XX46370400440532013000",
        "XX0812345678901",
        "XX621234567890ABCDEFGHIJ1234567890",
    }, &.{
        "",
        "DE01370400441000000008",
        "DE00370400441000000026",
        "DE99370400441000000087",
        "DE89 3704 0044 0532 0130 00",
        "de89370400440532013000",
        "GB82west12345698765432",
        "GB82-WEST-1234-5698-7654-32",
        "DE89370400440532013001",
        "DE8937040044053201300",
        "XX89370400440532013000",
        "GB82WE\u{17f}T12345698765432",
        "XX361234567890",
        "XX851234567890ABCDEFGHIJ1234567890X",
    });
}

test "isbn, isbn10 and isbn13: the canonical digits with their check digit, X only as the ISBN-10 check" {
    try expectPredicate(isIsbn, &.{
        "9780306406157",
        "0306406152",
        "080442957X",
        "9791090636071",
    }, &.{
        "",
        "080442957x",
        "978-0-306-40615-7",
        "0-306-40615-2",
        "978 0306406157",
        "978\u{a0}0306406157",
        "9780306406158",
        "0306406153",
        "4006381333931",
        "9790060115615",
        "97803064061570",
    });
    try expectPredicate(isIsbn10, &.{ "0306406152", "080442957X", "0000000000" }, &.{ "", "9780306406157", "08044295X7", "X306406152", "030640615" });
    try expectPredicate(isIsbn13, &.{ "9780306406157", "9791090636071" }, &.{ "", "0306406152", "080442957X", "4006381333931", "9790060115615", "978030640615X" });
}

test "issn: NNNN-NNNC with the hyphen at index 4 and an upper-case X as the only letter" {
    try expectPredicate(isIssn, &.{
        "0317-8471",
        "2434-561X",
        "1050-124X",
        "0000-0000",
    }, &.{
        "",
        "2434-561x",
        "03178471",
        "0317-8472",
        "0317 8471",
        "0317--8471",
        " 0317-8471",
        "X317-8471",
        "0317-847",
        "03178-471",
    });
}

test "ean: 8, 13 or 14 digits with the GS1 check digit; 12-digit UPC-A fails" {
    try expectPredicate(isEan, &.{
        "4006381333931",
        "73513537",
        "12345678901231",
        "0036000291452",
        "00000000",
    }, &.{
        "",
        "4006381333932",
        "036000291452",
        "12345678901232",
        "4006-381333931",
        "abcdefgh",
    });
}

test "isrc: country, registrant, year and designation without hyphens; no check digit" {
    try expectPredicate(isIsrc, &.{
        "USRC17607839",
        "GBAYE6800011",
        "QMDA71418090",
        "USRCX7607839",
    }, &.{
        "",
        "US-RC1-76-07839",
        "usrc17607839",
        "USRC1760783",
        "USRC176078390",
        "U1RC17607839",
        "USRC1X607839",
        "USRC1760783A",
    });
}

/// `isBtcAddress` gives `s` these verdicts on mainnet and on testnet, and
/// their `or` on `.any`.
fn expectBtc(s: []const u8, mainnet: bool, testnet: bool) !void {
    const got = [3]bool{ isBtcAddress(s, .mainnet), isBtcAddress(s, .testnet), isBtcAddress(s, .any) };
    const want = [3]bool{ mainnet, testnet, mainnet or testnet };
    if (!std.mem.eql(bool, &got, &want)) {
        std.debug.print("\"{f}\": mainnet, testnet, any expected {any}, got {any}\n", .{ std.zig.fmtString(s), want, got });
        return error.TestUnexpectedResult;
    }
}

test "btcAddress: segwit and Base58Check addresses with valid checksums, by network" {
    try expectBtc("1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", true, false);
    try expectBtc("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", true, false);
    try expectBtc("1111111111111111111114oLvT2", true, false);
    try expectBtc("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", true, false);
    try expectBtc("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3", true, false);
    try expectBtc("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", true, false);
    try expectBtc("bc1z2rksukkjr8", true, false);
    try expectBtc("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", false, true);
    try expectBtc("2NC2hEhe28ULKAJkW5MjZ3jtTMJdvXmByvK", false, true);
    try expectBtc("n4YNbYuFdPwFrxSP8sjHFbAhUbLMUiY9jE", false, true);
    try expectBtc("mzK2FFDEhxqHcmrJw1ysqFkVyhUULo45hZ", false, true);
    // A wrong checksum, the wrong Bech32 variant for the version, a symbol
    // outside the alphabet, no data, upper case, regtest, a trailing space.
    for ([_][]const u8{
        "",
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",
        "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3",
        "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4",
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd",
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh",
        "bc1p38j9r5y49hruaue7wxjce0updqjuyyx0kh56v8s25huc6995vvpql3jow4",
        "bc1gmk9yu",
        "bcrt1qdavt4j2sd7dlhqsavtnfxvzppw6k7qy97tmnu9",
        "1FsSia9rv4NeEwvJ2GvXrX7LyxYspbN2mo ",
        "11111111111111111111111111111111111",
    }) |s| try expectBtc(s, false, false);
}

test "btcAddress: the BIP-350 test vectors, in lower case only" {
    // The valid vectors in lower case; BIP-350 also lists two of them in
    // upper case, which fail here.
    for ([_][]const u8{
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
        "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y",
        "bc1sw50qgdz25j",
        "bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs",
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
    }) |s| try expectBtc(s, true, false);
    for ([_][]const u8{
        "tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7",
        "tb1qqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesrxh6hy",
        "tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c",
    }) |s| try expectBtc(s, false, true);
    for ([_][]const u8{
        "BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4",
        "BC1SW50QGDZ25J",
        "tc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq5zuyut",
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd",
        "tb1z0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqglt7rf",
        "BC1S0XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ54WELL",
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh",
        "tb1q0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq24jc47",
        "bc1p38j9r5y49hruaue7wxjce0updqjuyyx0kh56v8s25huc6995vvpql3jow4",
        "BC130XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ7ZWS8R",
        "bc1pw5dgrnzv",
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v8n0nx0muaewav253zgeav",
        "BC1QR508D6QEJXTDG4Y5R3ZARVARYV98GJ9P",
        "tb1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq47Zagq",
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v07qwwzcrf",
        "tb1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vpggkg4j",
        "bc1gmk9yu",
    }) |s| try expectBtc(s, false, false);
}

test "ethereumAddress: 0x and 40 hex digits; the EIP-55 checksum when the letters mix cases" {
    try expectPredicate(isEthereumAddress, &.{
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        "0x52908400098527886E0F7030069857D2E4169EE7",
        "0xde709f2102306220921060314715629080e2fb77",
        "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
        "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED",
        "0x0000000000000000000000000000000000000000",
    }, &.{
        "",
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD",
        "0X5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
        "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
        "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beae",
        "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaedd",
        "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaeg",
        " 0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
    });
}

test "ethereumAddress: flipping the case of any one letter of a checksummed address fails" {
    var flips: usize = 0;
    for ([_][]const u8{
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    }) |address| {
        var buf: [42]u8 = undefined;
        for (2..42) |i| {
            if (!std.ascii.isAlphabetic(address[i])) continue;
            @memcpy(&buf, address);
            buf[i] = if (std.ascii.isUpper(address[i])) std.ascii.toLower(address[i]) else std.ascii.toUpper(address[i]);
            try std.testing.expect(!isEthereumAddress(&buf));
            flips += 1;
        }
    }
    try std.testing.expectEqual(74, flips);
}
