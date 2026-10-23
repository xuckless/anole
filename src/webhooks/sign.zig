//! Standard Webhooks signing and verification, as pure functions
//! (https://www.standardwebhooks.com, spec Apache-2.0): `webhook-id`,
//! `webhook-timestamp` and `webhook-signature` (`v1,<base64 HMAC-SHA256>`
//! of `id.timestamp.body`, or `v1a,<base64 Ed25519>`), secrets
//! `whsec_<base64>`, public keys `whpk_<base64>`. Also the ULID message
//! ids and the XChaCha20-Poly1305 sealing of stored secrets.
const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Ed = std.crypto.sign.Ed25519;
const Seal = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const b64 = std.base64.standard;

pub const secret_prefix = "whsec_";
pub const public_prefix = "whpk_";

pub const VerifyError = error{ InvalidSecret, MissingHeader, BadTimestamp, Stale, NoMatch };

/// "whsec_" + base64 of 32 random bytes.
pub fn newSecret(io: std.Io, out: *[6 + 44]u8) []const u8 {
    var raw: [32]u8 = undefined;
    io.random(&raw);
    @memcpy(out[0..6], secret_prefix);
    _ = b64.Encoder.encode(out[6..], &raw);
    return out;
}

/// The HMAC key bytes of a `whsec_` secret (the prefix is optional).
fn hmacKey(secret: []const u8, buf: *[64]u8) error{InvalidSecret}![]const u8 {
    const text = if (std.mem.startsWith(u8, secret, secret_prefix)) secret[secret_prefix.len..] else secret;
    const n = b64.Decoder.calcSizeForSlice(text) catch return error.InvalidSecret;
    if (n == 0 or n > buf.len) return error.InvalidSecret;
    b64.Decoder.decode(buf[0..n], text) catch return error.InvalidSecret;
    return buf[0..n];
}

fn mac(key: []const u8, id: []const u8, timestamp: []const u8, body: []const u8) [Hmac.mac_length]u8 {
    var h = Hmac.init(key);
    h.update(id);
    h.update(".");
    h.update(timestamp);
    h.update(".");
    h.update(body);
    var out: [Hmac.mac_length]u8 = undefined;
    h.final(&out);
    return out;
}

/// "v1,<base64>" for `secret` over id.timestamp.body.
pub fn sign(secret: []const u8, id: []const u8, timestamp: i64, body: []const u8, out: *[3 + 44]u8) error{InvalidSecret}![]const u8 {
    var kb: [64]u8 = undefined;
    const key = try hmacKey(secret, &kb);
    var ts: [24]u8 = undefined;
    const t = std.fmt.bufPrint(&ts, "{d}", .{timestamp}) catch unreachable;
    const m = mac(key, id, t, body);
    @memcpy(out[0..3], "v1,");
    _ = b64.Encoder.encode(out[3..], &m);
    return out;
}

/// Checks `signature_header` (space-separated `v1,..` / `v1a,..` entries)
/// against every secret: `whsec_...` (HMAC) or `whpk_...` (Ed25519 public
/// key). `timestamp` is the header's text; it must be within `tolerance_s`
/// of `now_s` in both directions.
pub fn verify(
    secrets: []const []const u8,
    id: []const u8,
    timestamp: []const u8,
    signature_header: []const u8,
    body: []const u8,
    now_s: i64,
    tolerance_s: i64,
) VerifyError!void {
    if (id.len == 0 or timestamp.len == 0 or signature_header.len == 0) return error.MissingHeader;
    const ts = std.fmt.parseInt(i64, timestamp, 10) catch return error.BadTimestamp;
    const diff = @abs(@as(i128, now_s) - ts);
    if (diff > @as(u128, @intCast(@max(tolerance_s, 0)))) return error.Stale;
    if (try matches(secrets, id, timestamp, signature_header, body)) return;
    return error.NoMatch;
}

fn matches(secrets: []const []const u8, id: []const u8, timestamp: []const u8, header: []const u8, body: []const u8) VerifyError!bool {
    var found = false;
    for (secrets) |secret| {
        if (std.mem.startsWith(u8, secret, public_prefix)) {
            var pk: [Ed.PublicKey.encoded_length]u8 = undefined;
            const text = secret[public_prefix.len..];
            if ((b64.Decoder.calcSizeForSlice(text) catch return error.InvalidSecret) != pk.len) return error.InvalidSecret;
            b64.Decoder.decode(&pk, text) catch return error.InvalidSecret;
            const key = Ed.PublicKey.fromBytes(pk) catch return error.InvalidSecret;
            var it = std.mem.tokenizeScalar(u8, header, ' ');
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry, "v1a,")) continue;
                var sig: [Ed.Signature.encoded_length]u8 = undefined;
                const st = entry[4..];
                if ((b64.Decoder.calcSizeForSlice(st) catch continue) != sig.len) continue;
                b64.Decoder.decode(&sig, st) catch continue;
                var msg: std.ArrayList(u8) = .empty;
                defer msg.deinit(std.heap.page_allocator);
                msg.print(std.heap.page_allocator, "{s}.{s}.", .{ id, timestamp }) catch continue;
                msg.appendSlice(std.heap.page_allocator, body) catch continue;
                Ed.Signature.fromBytes(sig).verify(msg.items, key) catch continue;
                found = true;
            }
        } else {
            var kb: [64]u8 = undefined;
            const key = try hmacKey(secret, &kb);
            const want = mac(key, id, timestamp, body);
            var it = std.mem.tokenizeScalar(u8, header, ' ');
            while (it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry, "v1,")) continue;
                var got: [Hmac.mac_length]u8 = undefined;
                const st = entry[3..];
                if ((b64.Decoder.calcSizeForSlice(st) catch continue) != got.len) continue;
                b64.Decoder.decode(&got, st) catch continue;
                // Every entry is compared, so timing doesn't tell which one matched.
                if (std.crypto.timing_safe.eql([Hmac.mac_length]u8, got, want)) found = true;
            }
        }
    }
    return found;
}

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// "msg_" + a 26-character ULID (48-bit millisecond time, 80 random bits).
pub fn newUlid(io: std.Io, now_ms: i64, out: *[26]u8) []const u8 {
    var rnd: [10]u8 = undefined;
    io.random(&rnd);
    var v: u128 = @as(u128, @intCast(@max(now_ms, 0))) & 0xFFFF_FFFF_FFFF;
    v = (v << 80) | std.mem.readInt(u80, &rnd, .big);
    var i: usize = 26;
    while (i > 0) {
        i -= 1;
        out[i] = crockford[@intCast(v & 31)];
        v >>= 5;
    }
    return out;
}

pub fn newMessageId(io: std.Io, now_ms: i64, out: *[30]u8) []const u8 {
    @memcpy(out[0..4], "msg_");
    _ = newUlid(io, now_ms, out[4..30]);
    return out;
}

/// A secret sealed for storage: base64(nonce(24) || ciphertext || tag),
/// bound to `endpoint_id`. `key` is the 32 raw bytes.
pub fn seal(gpa: std.mem.Allocator, io: std.Io, key: [32]u8, plain: []const u8, endpoint_id: []const u8) std.mem.Allocator.Error![]u8 {
    const raw = try gpa.alloc(u8, Seal.nonce_length + plain.len + Seal.tag_length);
    defer gpa.free(raw);
    io.random(raw[0..Seal.nonce_length]);
    var tag: [Seal.tag_length]u8 = undefined;
    Seal.encrypt(raw[Seal.nonce_length..][0..plain.len], &tag, plain, endpoint_id, raw[0..Seal.nonce_length].*, key);
    @memcpy(raw[Seal.nonce_length + plain.len ..], &tag);
    const out = try gpa.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(out, raw);
    return out;
}

pub fn open(gpa: std.mem.Allocator, key: [32]u8, sealed: []const u8, endpoint_id: []const u8) error{ Decrypt, OutOfMemory }![]u8 {
    const n = b64.Decoder.calcSizeForSlice(sealed) catch return error.Decrypt;
    if (n < Seal.nonce_length + Seal.tag_length) return error.Decrypt;
    const raw = try gpa.alloc(u8, n);
    defer gpa.free(raw);
    b64.Decoder.decode(raw, sealed) catch return error.Decrypt;
    const clen = n - Seal.nonce_length - Seal.tag_length;
    const out = try gpa.alloc(u8, clen);
    errdefer gpa.free(out);
    Seal.decrypt(out, raw[Seal.nonce_length..][0..clen], raw[Seal.nonce_length + clen ..][0..Seal.tag_length].*, endpoint_id, raw[0..Seal.nonce_length].*, key) catch return error.Decrypt;
    return out;
}

// The reference vector from the Standard Webhooks libraries' tests
// (github.com/standard-webhooks/standard-webhooks, libraries/python/tests/test_webhooks.py).
test "sign and verify: the reference vector" {
    const secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    const id = "msg_p5jXN8AQM9LWM0D4loKWxJek";
    const body = "{\"test\": 2432232314}";
    var out: [47]u8 = undefined;
    const sig = try sign(secret, id, 1614265330, body, &out);
    try std.testing.expectEqualStrings("v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=", sig);
    try verify(&.{secret}, id, "1614265330", sig, body, 1614265330 + 200, 300);
    try std.testing.expectError(error.Stale, verify(&.{secret}, id, "1614265330", sig, body, 1614265330 + 301, 300));
    try std.testing.expectError(error.Stale, verify(&.{secret}, id, "1614265330", sig, body, 1614265330 - 301, 300));
    try std.testing.expectError(error.NoMatch, verify(&.{secret}, id, "1614265330", sig, "{}", 1614265330, 300));
    try std.testing.expectError(error.BadTimestamp, verify(&.{secret}, id, "abc", sig, body, 0, 300));
}

test "several signatures and secrets (rotation)" {
    const a = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    const b = "whsec_dGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRlc3Q=";
    var o1: [47]u8 = undefined;
    var o2: [47]u8 = undefined;
    const s1 = try sign(a, "msg_1", 10, "x", &o1);
    const s2 = try sign(b, "msg_1", 10, "x", &o2);
    var hdr: [100]u8 = undefined;
    const both = try std.fmt.bufPrint(&hdr, "{s} {s}", .{ s1, s2 });
    try verify(&.{b}, "msg_1", "10", both, "x", 10, 300);
    try verify(&.{a}, "msg_1", "10", both, "x", 10, 300);
    try std.testing.expectError(error.NoMatch, verify(&.{"whsec_AAAAAAAAAAAAAAAAAAAAAA=="}, "msg_1", "10", both, "x", 10, 300));
}

test "v1a: Ed25519" {
    const kp = Ed.KeyPair.generateDeterministic(@as([32]u8, @splat(7))) catch unreachable;
    var msg: [64]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, "msg_1.10.{s}", .{"body"}) catch unreachable;
    const sig = try kp.sign(m, null);
    var sb: [88]u8 = undefined;
    _ = b64.Encoder.encode(&sb, &sig.toBytes());
    var pkb: [44]u8 = undefined;
    _ = b64.Encoder.encode(&pkb, &kp.public_key.toBytes());
    var key: [49]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "whpk_{s}", .{pkb}) catch unreachable;
    var hdr: [95]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "v1a,{s}", .{sb}) catch unreachable;
    try verify(&.{k}, "msg_1", "10", h, "body", 10, 300);
    try std.testing.expectError(error.NoMatch, verify(&.{k}, "msg_1", "10", h, "bodz", 10, 300));
}

test "ULID ids are 26 Crockford characters and sort by time" {
    var a: [26]u8 = undefined;
    var b: [26]u8 = undefined;
    _ = newUlid(std.testing.io, 1_000_000, &a);
    _ = newUlid(std.testing.io, 2_000_000, &b);
    for (a) |c| try std.testing.expect(std.mem.indexOfScalar(u8, crockford, c) != null);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
}

test "sealing round trip, bound to the endpoint" {
    const gpa = std.testing.allocator;
    const key = @as([32]u8, @splat(3));
    const sealed = try seal(gpa, std.testing.io, key, "whsec_abc", "ep_1");
    defer gpa.free(sealed);
    const plain = try open(gpa, key, sealed, "ep_1");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("whsec_abc", plain);
    try std.testing.expectError(error.Decrypt, open(gpa, key, sealed, "ep_2"));
    try std.testing.expectError(error.Decrypt, open(gpa, @as([32]u8, @splat(4)), sealed, "ep_1"));
}

test "fuzz: verify never crashes on arbitrary headers" {
    const fuzz = @import("../fuzz.zig");
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            const half = input.len / 2;
            verify(&.{"whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"}, "msg_1", "10", input[0..half], input[half..], 10, 300) catch {};
        }
    }.check, &.{ "v1,AAAA v1a,BBBB body", "" });
}
