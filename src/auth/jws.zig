//! Verifying signed JWTs (JWS compact form) against JWK keys, on Zig's own
//! crypto: HMAC, RSA PKCS#1 v1.5 and PSS (std.crypto.Certificate.rsa),
//! ECDSA P-256/P-384 and Ed25519.
//!
//! The rules (the risks AGENTS.md lists for JWT):
//! - one algorithm per key: a token whose `alg` is not its key's is
//!   refused, so an RSA public key can never be used as an HMAC secret;
//! - `none` and unknown algorithms are refused;
//! - `exp` is required (unless the policy says otherwise), and `nbf`,
//!   `iat`, `iss` and `aud` are checked, with leeway for clock skew.
const std = @import("std");

/// The JWS algorithms `verify` accepts, by their `alg` names. `none` is not
/// among them.
pub const Alg = enum {
    HS256,
    HS384,
    HS512,
    RS256,
    RS384,
    RS512,
    PS256,
    PS384,
    PS512,
    ES256,
    ES384,
    EdDSA,

    fn isHmac(a: Alg) bool {
        return a == .HS256 or a == .HS384 or a == .HS512;
    }
};

/// A verification key pinned to one algorithm. Build one by hand
/// (`.{ .alg = .HS256, .material = .{ .hmac = secret } }`) or get a list
/// from a JWK Set with `parseJwks`.
pub const Key = struct {
    /// Matched against the token's `kid` when both have one.
    kid: ?[]const u8 = null,
    /// The only algorithm this key verifies.
    alg: Alg,
    material: Material,

    /// The key itself, in the form its algorithm needs.
    pub const Material = union(enum) {
        /// The shared secret, for the HS algorithms: at least as long as
        /// the hash (32 bytes for HS256, 48 for HS384, 64 for HS512), as
        /// RFC 7518 3.2 requires. A shorter one verifies nothing:
        /// `verify` fails with `error.WeakKey`.
        hmac: []const u8,
        /// Big-endian modulus and exponent.
        rsa: struct { n: []const u8, e: []const u8 },
        /// Uncompressed SEC1 points (0x04 || X || Y).
        p256: [65]u8,
        p384: [97]u8,
        ed25519: [32]u8,
    };
};

/// What a token's claims must satisfy beyond a good signature. The
/// default requires `exp` and allows 60 seconds of clock skew.
///
/// Set `issuer` and `audience` whenever the keys also sign tokens for
/// others (any identity provider's): without `audience`, a token the
/// provider issued to another application verifies here too. `Keyring`
/// refuses a policy without one (`allow_any_audience` opts out).
pub const Policy = struct {
    /// Required `iss`.
    issuer: ?[]const u8 = null,
    /// Required in `aud` (a string or an array).
    audience: ?[]const u8 = null,
    /// Required header `typ`, compared without case and with or without
    /// an `application/` prefix: "at+jwt" for RFC 9068 access tokens, so
    /// an ID token from the same provider is not taken for one.
    typ: ?[]const u8 = null,
    /// Let a `Keyring` verify with no `audience`: only for keys that sign
    /// for this application alone.
    allow_any_audience: bool = false,
    /// Clock skew allowed on `exp`, `nbf` and `iat`.
    leeway: std.Io.Duration = .fromSeconds(60),
    /// Refuse a token without `exp` (`error.MissingExpiry`).
    require_exp: bool = true,
    /// Refuse a token without `iat` (`error.MissingIssuedAt`); OIDC ID
    /// tokens must carry one.
    require_iat: bool = false,
    /// A token older than this (by `iat`) is refused.
    max_age: ?std.Io.Duration = null,
};

/// Why `verify` refused a token. `NoMatchingKey`: no key has the token's
/// `alg` (and `kid`); `BadSignature`: one did, and the signature does not
/// match it; `WeakKey`: the key that would check it is an HMAC secret
/// shorter than its hash, which anyone could guess (the application's
/// configuration is wrong, not the token).
pub const Error = error{
    Malformed,
    UnsupportedAlgorithm,
    NoMatchingKey,
    BadSignature,
    WeakKey,
    Expired,
    NotYetValid,
    IssuedInFuture,
    MissingExpiry,
    WrongIssuer,
    WrongAudience,
    TooOld,
    MissingIssuedAt,
    WrongType,
    OutOfMemory,
};

/// A token that verified: its header and claims (JSON objects).
pub const Verified = struct {
    header: std.json.ObjectMap,
    claims: std.json.ObjectMap,
    alg: Alg,
    kid: ?[]const u8,

    /// The claim `name` when it is a string, else null.
    pub fn string(self: Verified, name: []const u8) ?[]const u8 {
        const v = self.claims.get(name) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// The claim `name` when it is a whole number that fits an `i64` (such as
    /// `exp`), else null.
    pub fn integer(self: Verified, name: []const u8) ?i64 {
        const v = self.claims.get(name) orelse return null;
        return switch (v) {
            .integer => |i| i,
            // A whole number that fits; 1e300 is whole and does not.
            .float => |f| if (@floor(f) == f and f >= -0x1p63 and f < 0x1p63) @intFromFloat(f) else null,
            else => null,
        };
    }
};

const b64 = std.base64.url_safe_no_pad;

fn decode(arena: std.mem.Allocator, part: []const u8) ![]u8 {
    const len = b64.Decoder.calcSizeForSlice(part) catch return error.Malformed;
    const out = try arena.alloc(u8, len);
    b64.Decoder.decode(out, part) catch return error.Malformed;
    return out;
}

/// Verifies `token` with one of `keys` and checks its claims against
/// `policy` at `now` (Unix seconds). Everything lives in `arena`.
pub fn verify(arena: std.mem.Allocator, token: []const u8, keys: []const Key, policy: Policy, now: i64) Error!Verified {
    var parts = std.mem.splitScalar(u8, token, '.');
    const h64 = parts.next() orelse return error.Malformed;
    const c64 = parts.next() orelse return error.Malformed;
    const s64 = parts.next() orelse return error.Malformed;
    if (parts.next() != null) return error.Malformed;

    const header_json = try decode(arena, h64);
    const header = (std.json.parseFromSliceLeaky(std.json.Value, arena, header_json, .{}) catch return error.Malformed);
    if (header != .object) return error.Malformed;
    const alg_v = header.object.get("alg") orelse return error.UnsupportedAlgorithm;
    if (alg_v != .string) return error.UnsupportedAlgorithm;
    const alg = std.meta.stringToEnum(Alg, alg_v.string) orelse return error.UnsupportedAlgorithm;
    const kid: ?[]const u8 = if (header.object.get("kid")) |k| (if (k == .string) k.string else null) else null;
    // Critical extensions we do not understand make the token unusable.
    if (header.object.get("crit") != null) return error.UnsupportedAlgorithm;

    const signing_input = token[0 .. h64.len + 1 + c64.len];
    const signature = try decode(arena, s64);

    var verified = false;
    var any_candidate = false;
    for (keys) |key| {
        if (key.alg != alg) continue;
        if (kid != null and key.kid != null and !std.mem.eql(u8, kid.?, key.kid.?)) continue;
        any_candidate = true;
        if (key.material == .hmac and key.material.hmac.len < minHmacKey(alg)) return error.WeakKey;
        if (verifySignature(key, alg, signing_input, signature)) {
            verified = true;
            break;
        }
    }
    if (!any_candidate) return error.NoMatchingKey;
    if (!verified) return error.BadSignature;

    const claims_json = try decode(arena, c64);
    const claims = (std.json.parseFromSliceLeaky(std.json.Value, arena, claims_json, .{}) catch return error.Malformed);
    if (claims != .object) return error.Malformed;
    const v: Verified = .{ .header = header.object, .claims = claims.object, .alg = alg, .kid = kid };
    if (policy.typ) |want| if (!typMatches(header.object, want)) return error.WrongType;
    try checkClaims(v, policy, now);
    return v;
}

/// The header's `typ` is `want`, ignoring case and an `application/`
/// prefix on either (RFC 7515 4.1.9).
fn typMatches(header: std.json.ObjectMap, want: []const u8) bool {
    const got = header.get("typ") orelse return false;
    if (got != .string) return false;
    return std.ascii.eqlIgnoreCase(mediaSubtype(got.string), mediaSubtype(want));
}

fn mediaSubtype(typ: []const u8) []const u8 {
    const prefix = "application/";
    return if (std.ascii.startsWithIgnoreCase(typ, prefix)) typ[prefix.len..] else typ;
}

fn checkClaims(v: Verified, policy: Policy, now: i64) Error!void {
    // Saturating: the claims are any i64 the issuer wrote.
    const leeway = policy.leeway.toSeconds();
    if (v.integer("exp")) |exp| {
        if (now -| leeway >= exp) return error.Expired;
    } else if (policy.require_exp) return error.MissingExpiry;
    if (v.integer("nbf")) |nbf| if (now +| leeway < nbf) return error.NotYetValid;
    if (v.integer("iat")) |iat| {
        if (now +| leeway < iat) return error.IssuedInFuture;
        if (policy.max_age) |max| if (now -| iat > max.toSeconds() +| leeway) return error.TooOld;
    } else if (policy.require_iat) {
        return error.MissingIssuedAt;
    } else if (policy.max_age != null) return error.TooOld;
    if (policy.issuer) |iss| {
        const got = v.string("iss") orelse return error.WrongIssuer;
        if (!std.mem.eql(u8, got, iss)) return error.WrongIssuer;
    }
    if (policy.audience) |aud| {
        const got = v.claims.get("aud") orelse return error.WrongAudience;
        const ok = switch (got) {
            .string => |s| std.mem.eql(u8, s, aud),
            .array => |a| for (a.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, aud)) break true;
            } else false,
            else => false,
        };
        if (!ok) return error.WrongAudience;
    }
}

/// The shortest HMAC secret `alg` takes: its hash's output (RFC 7518 3.2).
fn minHmacKey(alg: Alg) usize {
    return switch (alg) {
        .HS256 => 32,
        .HS384 => 48,
        .HS512 => 64,
        else => 0,
    };
}

fn verifySignature(key: Key, alg: Alg, input: []const u8, sig: []const u8) bool {
    return switch (alg) {
        .HS256 => hmac(std.crypto.auth.hmac.sha2.HmacSha256, key, input, sig),
        .HS384 => hmac(std.crypto.auth.hmac.sha2.HmacSha384, key, input, sig),
        .HS512 => hmac(std.crypto.auth.hmac.sha2.HmacSha512, key, input, sig),
        .RS256 => rsa(.pkcs1, std.crypto.hash.sha2.Sha256, key, input, sig),
        .RS384 => rsa(.pkcs1, std.crypto.hash.sha2.Sha384, key, input, sig),
        .RS512 => rsa(.pkcs1, std.crypto.hash.sha2.Sha512, key, input, sig),
        .PS256 => rsa(.pss, std.crypto.hash.sha2.Sha256, key, input, sig),
        .PS384 => rsa(.pss, std.crypto.hash.sha2.Sha384, key, input, sig),
        .PS512 => rsa(.pss, std.crypto.hash.sha2.Sha512, key, input, sig),
        .ES256 => ecdsa(std.crypto.sign.ecdsa.EcdsaP256Sha256, key, input, sig),
        .ES384 => ecdsa(std.crypto.sign.ecdsa.EcdsaP384Sha384, key, input, sig),
        .EdDSA => ed25519(key, input, sig),
    };
}

fn hmac(comptime H: type, key: Key, input: []const u8, sig: []const u8) bool {
    if (key.material != .hmac) return false;
    if (sig.len != H.mac_length) return false;
    var mac: [H.mac_length]u8 = undefined;
    H.create(&mac, input, key.material.hmac);
    return std.crypto.timing_safe.eql([H.mac_length]u8, mac, sig[0..H.mac_length].*);
}

fn rsa(comptime scheme: enum { pkcs1, pss }, comptime Hash: type, key: Key, input: []const u8, sig: []const u8) bool {
    if (key.material != .rsa) return false;
    const R = std.crypto.Certificate.rsa;
    const pk = R.PublicKey.fromBytes(key.material.rsa.e, key.material.rsa.n) catch return false;
    // The signature is as long as the modulus.
    inline for (.{ 256, 384, 512 }) |len| {
        if (sig.len == len) {
            const s = sig[0..len];
            const result = switch (scheme) {
                .pkcs1 => R.PKCS1v1_5Signature.verify(len, s, input, pk, Hash),
                .pss => R.PSSSignature.verify(len, s, input, pk, Hash),
            };
            return if (result) |_| true else |_| false;
        }
    }
    return false;
}

fn ecdsa(comptime E: type, key: Key, input: []const u8, sig: []const u8) bool {
    const point: []const u8 = switch (key.material) {
        .p256 => |*p| if (E == std.crypto.sign.ecdsa.EcdsaP256Sha256) p else return false,
        .p384 => |*p| if (E == std.crypto.sign.ecdsa.EcdsaP384Sha384) p else return false,
        else => return false,
    };
    // JWS carries r || s, not DER.
    if (sig.len != E.Signature.encoded_length) return false;
    const pk = E.PublicKey.fromSec1(point) catch return false;
    const s = E.Signature.fromBytes(sig[0..E.Signature.encoded_length].*);
    s.verify(input, pk) catch return false;
    return true;
}

fn ed25519(key: Key, input: []const u8, sig: []const u8) bool {
    if (key.material != .ed25519) return false;
    const Ed = std.crypto.sign.Ed25519;
    if (sig.len != Ed.Signature.encoded_length) return false;
    const pk = Ed.PublicKey.fromBytes(key.material.ed25519) catch return false;
    const s = Ed.Signature.fromBytes(sig[0..Ed.Signature.encoded_length].*);
    s.verify(input, pk) catch return false;
    return true;
}

/// The keys of a JWK Set (`{"keys": [...]}`) that can verify signatures.
/// A key without `alg` gets the one its type implies (RSA: RS256, EC P-256:
/// ES256, P-384: ES384, OKP Ed25519: EdDSA); `use: enc` keys are skipped.
pub fn parseJwks(arena: std.mem.Allocator, json: []const u8) ![]Key {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.Malformed;
    if (root != .object) return error.Malformed;
    const keys_v = root.object.get("keys") orelse return error.Malformed;
    if (keys_v != .array) return error.Malformed;
    var out: std.ArrayList(Key) = .empty;
    for (keys_v.array.items) |k| {
        if (k != .object) continue;
        if (parseJwk(arena, k.object) catch null) |key| try out.append(arena, key);
    }
    return out.items;
}

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn parseJwk(arena: std.mem.Allocator, o: std.json.ObjectMap) !?Key {
    if (str(o, "use")) |use| if (!std.mem.eql(u8, use, "sig")) return null;
    const kty = str(o, "kty") orelse return null;
    const kid = str(o, "kid");
    const alg_name = str(o, "alg");
    if (std.mem.eql(u8, kty, "RSA")) {
        const alg = if (alg_name) |a| std.meta.stringToEnum(Alg, a) orelse return null else .RS256;
        return .{ .kid = kid, .alg = alg, .material = .{ .rsa = .{
            .n = try decode(arena, str(o, "n") orelse return null),
            .e = try decode(arena, str(o, "e") orelse return null),
        } } };
    }
    if (std.mem.eql(u8, kty, "EC")) {
        const crv = str(o, "crv") orelse return null;
        const x = try decode(arena, str(o, "x") orelse return null);
        const y = try decode(arena, str(o, "y") orelse return null);
        if (std.mem.eql(u8, crv, "P-256") and x.len == 32 and y.len == 32) {
            var p: [65]u8 = undefined;
            p[0] = 4;
            @memcpy(p[1..33], x);
            @memcpy(p[33..65], y);
            return .{ .kid = kid, .alg = .ES256, .material = .{ .p256 = p } };
        }
        if (std.mem.eql(u8, crv, "P-384") and x.len == 48 and y.len == 48) {
            var p: [97]u8 = undefined;
            p[0] = 4;
            @memcpy(p[1..49], x);
            @memcpy(p[49..97], y);
            return .{ .kid = kid, .alg = .ES384, .material = .{ .p384 = p } };
        }
        return null;
    }
    if (std.mem.eql(u8, kty, "OKP")) {
        const crv = str(o, "crv") orelse return null;
        if (!std.mem.eql(u8, crv, "Ed25519")) return null;
        const x = try decode(arena, str(o, "x") orelse return null);
        if (x.len != 32) return null;
        return .{ .kid = kid, .alg = .EdDSA, .material = .{ .ed25519 = x[0..32].* } };
    }
    return null;
}

// RFC 7515 A.1: an HS256 JWS, its key, and its claims (exp 1300819380).
const rfc_hs256_token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const rfc_hs256_key = "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow";

test "verify: RFC 7515 A.1 HS256, claims policy, and algorithm pinning" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = try decode(arena, rfc_hs256_key);
    const key: Key = .{ .alg = .HS256, .material = .{ .hmac = secret } };
    const before = 1300819000;
    const v = try verify(arena, rfc_hs256_token, &.{key}, .{ .issuer = "joe" }, before);
    try std.testing.expectEqualStrings("joe", v.string("iss").?);

    try std.testing.expectError(error.Expired, verify(arena, rfc_hs256_token, &.{key}, .{}, 1300819380 + 61));
    try std.testing.expectError(error.WrongIssuer, verify(arena, rfc_hs256_token, &.{key}, .{ .issuer = "bob" }, before));
    try std.testing.expectError(error.WrongAudience, verify(arena, rfc_hs256_token, &.{key}, .{ .audience = "api" }, before));
    // The same secret pinned to another algorithm does not verify it.
    const other: Key = .{ .alg = .HS512, .material = .{ .hmac = secret } };
    try std.testing.expectError(error.NoMatchingKey, verify(arena, rfc_hs256_token, &.{other}, .{}, before));
    // A wrong secret.
    const wrong: Key = .{ .alg = .HS256, .material = .{ .hmac = "a wrong secret, 32 bytes or more" } };
    try std.testing.expectError(error.BadSignature, verify(arena, rfc_hs256_token, &.{wrong}, .{}, before));
    // A secret shorter than the hash verifies nothing (RFC 7518 3.2), not
    // even a token signed with it.
    const short: Key = .{ .alg = .HS256, .material = .{ .hmac = "nope" } };
    try std.testing.expectError(error.WeakKey, verify(arena, rfc_hs256_token, &.{short}, .{}, before));
    try std.testing.expectError(error.WeakKey, verify(arena, rfc_hs256_token, &.{.{ .alg = .HS256, .material = .{ .hmac = "" } }}, .{}, before));
    // alg none.
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(arena, "eyJhbGciOiJub25lIn0.eyJleHAiOjF9.", &.{key}, .{}, 0));
}

test "verify: ES256 and EdDSA signed here, keys from a JWKS" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const E = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const kp = E.KeyPair.generate(io);
    const Ed = std.crypto.sign.Ed25519;
    const ekp = Ed.KeyPair.generate(io);

    const claims = "{\"sub\":\"u1\",\"exp\":2000000000,\"aud\":[\"x\",\"api\"]}";
    const pub_point = kp.public_key.toUncompressedSec1();
    var x_b64: [43]u8 = undefined;
    var y_b64: [43]u8 = undefined;
    var ed_b64: [43]u8 = undefined;
    const jwks = try std.fmt.allocPrint(arena,
        \\{{"keys":[{{"kty":"EC","crv":"P-256","kid":"ec1","x":"{s}","y":"{s}"}},
        \\ {{"kty":"OKP","crv":"Ed25519","kid":"ed1","x":"{s}"}},
        \\ {{"kty":"RSA","use":"enc","n":"AQAB","e":"AQAB"}}]}}
    , .{ b64.Encoder.encode(&x_b64, pub_point[1..33]), b64.Encoder.encode(&y_b64, pub_point[33..65]), b64.Encoder.encode(&ed_b64, &ekp.public_key.toBytes()) });
    const keys = try parseJwks(arena, jwks);
    try std.testing.expectEqual(@as(usize, 2), keys.len);

    inline for (.{ .{ "ES256", "ec1" }, .{ "EdDSA", "ed1" } }) |case| {
        const header = "{\"alg\":\"" ++ case[0] ++ "\",\"kid\":\"" ++ case[1] ++ "\"}";
        var h_buf: [128]u8 = undefined;
        var c_buf: [128]u8 = undefined;
        const signing_input = try std.fmt.allocPrint(arena, "{s}.{s}", .{ b64.Encoder.encode(&h_buf, header), b64.Encoder.encode(&c_buf, claims) });
        const sig_bytes: []const u8 = if (comptime std.mem.eql(u8, case[0], "ES256"))
            &(try kp.sign(signing_input, null)).toBytes()
        else
            &(try ekp.sign(signing_input, null)).toBytes();
        var s_buf: [128]u8 = undefined;
        const token = try std.fmt.allocPrint(arena, "{s}.{s}", .{ signing_input, b64.Encoder.encode(&s_buf, sig_bytes) });
        const v = try verify(arena, token, keys, .{ .audience = "api" }, 1700000000);
        try std.testing.expectEqualStrings("u1", v.string("sub").?);
        try std.testing.expectEqualStrings(case[1], v.kid.?);
    }
}

test "claims: times past what an i64 holds are refused, not a crash" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const claims = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"exp":1e300,"nbf":-1e300,"iat":-9223372036854775808,"big":9.3e18,"whole":1.7e9}
    , .{});
    const v: Verified = .{ .header = .empty, .claims = claims.object, .alg = .HS256, .kid = null };
    try std.testing.expectEqual(@as(?i64, null), v.integer("exp"));
    try std.testing.expectEqual(@as(?i64, null), v.integer("big"));
    try std.testing.expectEqual(@as(?i64, 1700000000), v.integer("whole"));
    try std.testing.expectError(error.MissingExpiry, checkClaims(v, .{}, 1700000000));
    try std.testing.expectError(error.TooOld, checkClaims(v, .{ .require_exp = false, .max_age = .fromSeconds(60) }, 1700000000));
}

test "fuzz: JWS verification and JWK Sets" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const secret = try decode(arena, rfc_hs256_key);
            const keys = [_]Key{
                .{ .alg = .HS256, .material = .{ .hmac = secret } },
                .{ .alg = .HS512, .kid = "k2", .material = .{ .hmac = "another secret, for HS512 at least sixty-four bytes long, so: pad" } },
            };
            if (verify(arena, input, &keys, .{}, 1300819000)) |v| {
                // Only a signature over exactly this input verifies.
                try std.testing.expect(v.alg == .HS256 or v.alg == .HS512);
            } else |_| {}
            _ = parseJwks(arena, input) catch {};
        }
    }.check, &.{
        rfc_hs256_token,
        "eyJhbGciOiJub25lIn0.eyJleHAiOjF9.",
        "eyJhbGciOiJIUzI1NiIsImNyaXQiOlsiYiJdfQ.e30.AAAA",
        \\{"keys":[{"kty":"oct","alg":"HS256","k":"AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"}]}
        ,
        \\{"keys":[{"kty":"EC","crv":"P-256","kid":"ec1","x":"MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4","y":"4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM"},{"kty":"RSA","n":"0vx7","e":"AQAB","alg":"RS256"},{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}]}
        ,
    });
}

test "verify: an optional typ check, and require_iat" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = "typ-test-secret-typ-test-secret-";
    const key: Key = .{ .alg = .HS256, .material = .{ .hmac = secret } };
    const Sign = struct {
        fn token(a: std.mem.Allocator, header: []const u8, claims: []const u8) ![]const u8 {
            const h = b64.Encoder.encode(try a.alloc(u8, b64.Encoder.calcSize(header.len)), header);
            const c = b64.Encoder.encode(try a.alloc(u8, b64.Encoder.calcSize(claims.len)), claims);
            const input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h, c });
            var mac: [32]u8 = undefined;
            std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, input, secret);
            return std.fmt.allocPrint(a, "{s}.{s}", .{ input, b64.Encoder.encode(try a.alloc(u8, 43), &mac) });
        }
    };
    const claims = "{\"exp\":2000000000}";
    const at = try Sign.token(arena, "{\"alg\":\"HS256\",\"typ\":\"at+jwt\"}", claims);
    const at_long = try Sign.token(arena, "{\"alg\":\"HS256\",\"typ\":\"application/AT+JWT\"}", claims);
    const id = try Sign.token(arena, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", claims);
    const none = try Sign.token(arena, "{\"alg\":\"HS256\"}", claims);
    _ = try verify(arena, at, &.{key}, .{ .typ = "at+jwt" }, 1700000000);
    _ = try verify(arena, at_long, &.{key}, .{ .typ = "at+jwt" }, 1700000000);
    try std.testing.expectError(error.WrongType, verify(arena, id, &.{key}, .{ .typ = "at+jwt" }, 1700000000));
    try std.testing.expectError(error.WrongType, verify(arena, none, &.{key}, .{ .typ = "at+jwt" }, 1700000000));
    _ = try verify(arena, none, &.{key}, .{}, 1700000000);
    try std.testing.expectError(error.MissingIssuedAt, verify(arena, none, &.{key}, .{ .require_iat = true }, 1700000000));
}
