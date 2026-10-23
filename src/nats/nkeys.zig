//! NATS NKeys: Ed25519 keys written in base32 with a type prefix and a
//! CRC-16 (the format of nats-io/nkeys). Enough for the client's login:
//! decode a seed ("SU..."), derive the public key ("U...") and sign the
//! server's nonce.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Error = error{ InvalidSeed, InvalidChecksum, InvalidPrefix };

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// The kind of key, as its prefix byte (the first letter of its public key).
pub const Kind = enum(u8) {
    server = 13 << 3,
    cluster = 2 << 3,
    operator = 14 << 3,
    account = 0,
    user = 20 << 3,
    curve = 23 << 3,
    _,
};

const seed_prefix: u8 = 18 << 3;

/// A decoded seed: the key pair and what kind it is.
pub const Seed = struct {
    kind: Kind,
    key_pair: Ed25519.KeyPair,

    /// The public key as text ("UA...", 56 bytes).
    pub fn publicKey(self: Seed, out: *[56]u8) []const u8 {
        var raw: [35]u8 = undefined;
        raw[0] = @intFromEnum(self.kind);
        @memcpy(raw[1..33], &self.key_pair.public_key.toBytes());
        const crc = crc16(raw[0..33]);
        std.mem.writeInt(u16, raw[33..35], crc, .little);
        return encode(out, &raw);
    }

    /// `message` signed, as the server's CONNECT wants it: base64 without
    /// padding, URL alphabet.
    pub fn signNonce(self: Seed, message: []const u8, out: *[86]u8) error{InvalidSeed}![]const u8 {
        const sig = self.key_pair.sign(message, null) catch return error.InvalidSeed;
        return std.base64.url_safe_no_pad.Encoder.encode(out, &sig.toBytes());
    }
};

/// Decodes a seed such as "SUAMK2FG4MI6UE3ACF3FK3OIQBCEIEZV7NSWFFEW63UXMRLFM2XLAXK4GY".
pub fn decodeSeed(text: []const u8) Error!Seed {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 58) return error.InvalidSeed;
    var raw: [36]u8 = undefined;
    decode(trimmed, &raw) catch return error.InvalidSeed;
    const crc = std.mem.readInt(u16, raw[34..36], .little);
    if (crc != crc16(raw[0..34])) return error.InvalidChecksum;
    const b1 = raw[0] & 248;
    const b2 = ((raw[0] & 7) << 5) | ((raw[1] & 248) >> 3);
    if (b1 != seed_prefix) return error.InvalidPrefix;
    const kind: Kind = @enumFromInt(b2);
    switch (kind) {
        .server, .cluster, .operator, .account, .user => {},
        else => return error.InvalidPrefix,
    }
    const key_pair = Ed25519.KeyPair.generateDeterministic(raw[2..34].*) catch return error.InvalidSeed;
    return .{ .kind = kind, .key_pair = key_pair };
}

/// A seed's text from its kind and 32 bytes (tests and tools).
pub fn encodeSeed(out: *[58]u8, kind: Kind, bytes: *const [32]u8) []const u8 {
    var raw: [36]u8 = undefined;
    const k = @intFromEnum(kind);
    raw[0] = seed_prefix | (k >> 5);
    raw[1] = (k & 31) << 3;
    @memcpy(raw[2..34], bytes);
    std.mem.writeInt(u16, raw[34..36], crc16(raw[0..34]), .little);
    return encode(out, &raw);
}

/// CRC-16/XMODEM (polynomial 0x1021, initial value 0).
pub fn crc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        crc ^= @as(u16, b) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x1021 else crc << 1;
    }
    return crc;
}

fn encode(out: []u8, raw: []const u8) []const u8 {
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var n: usize = 0;
    for (raw) |b| {
        bits = (bits << 8) | b;
        nbits += 8;
        while (nbits >= 5) {
            nbits -= 5;
            out[n] = alphabet[(bits >> nbits) & 31];
            n += 1;
        }
    }
    if (nbits > 0) {
        out[n] = alphabet[(bits << (5 - nbits)) & 31];
        n += 1;
    }
    return out[0..n];
}

fn decode(text: []const u8, out: []u8) error{InvalidCharacter}!void {
    var bits: u32 = 0;
    var nbits: u5 = 0;
    var n: usize = 0;
    for (text) |c| {
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            '2'...'7' => c - '2' + 26,
            else => return error.InvalidCharacter,
        };
        bits = (bits << 5) | v;
        nbits += 5;
        if (nbits >= 8) {
            nbits -= 8;
            if (n < out.len) {
                out[n] = @intCast((bits >> nbits) & 0xff);
                n += 1;
            }
        }
    }
}

const testing = std.testing;

test "crc16 xmodem: the standard check value" {
    try testing.expectEqual(@as(u16, 0x31C3), crc16("123456789"));
}

test "nkeys: a seed round trips, the public key starts with U, and a signature verifies" {
    var bytes: [32]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i * 7 + 1);
    var text_buf: [58]u8 = undefined;
    const text = encodeSeed(&text_buf, .user, &bytes);
    try testing.expectEqual(@as(usize, 58), text.len);
    try testing.expectEqualStrings("SU", text[0..2]);
    const seed = try decodeSeed(text);
    try testing.expectEqual(Kind.user, seed.kind);
    var pk_buf: [56]u8 = undefined;
    const public = seed.publicKey(&pk_buf);
    try testing.expectEqual(@as(usize, 56), public.len);
    try testing.expectEqual(@as(u8, 'U'), public[0]);

    var sig_buf: [86]u8 = undefined;
    const sig_text = try seed.signNonce("nonce-123", &sig_buf);
    var sig_bytes: [64]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&sig_bytes, sig_text);
    try Ed25519.Signature.fromBytes(sig_bytes).verify("nonce-123", seed.key_pair.public_key);
}

test "nkeys: a bad CRC, a wrong prefix and a bad length are refused" {
    var bytes: [32]u8 = @splat(9);
    var buf: [58]u8 = undefined;
    const text = encodeSeed(&buf, .account, &bytes);
    var broken: [58]u8 = buf;
    broken[10] = if (broken[10] == 'A') 'B' else 'A';
    try testing.expectError(error.InvalidChecksum, decodeSeed(&broken));
    try testing.expectError(error.InvalidSeed, decodeSeed(text[0..57]));
    try testing.expectError(error.InvalidSeed, decodeSeed("not a seed"));
    // A public key is not a seed.
    var pk_buf: [56]u8 = undefined;
    const seed = try decodeSeed(text);
    var as_seed: [58]u8 = @splat('A');
    @memcpy(as_seed[0..56], seed.publicKey(&pk_buf));
    try testing.expectError(error.InvalidChecksum, decodeSeed(&as_seed));
}
