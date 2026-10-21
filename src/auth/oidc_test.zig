//! OIDC end to end against a fake provider on loopback: discovery, the
//! authorization URL, the code exchange and the ID token checks.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const oidc = @import("oidc.zig");
const Keyring = @import("keyring.zig").Keyring;

const E = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const b64 = std.base64.url_safe_no_pad;

/// The fake provider's state.
var provider_key: E.KeyPair = undefined;
var provider_port: u16 = 0;
/// The nonce the next ID token carries (the provider took it from the
/// authorization request).
var next_nonce: [64]u8 = undefined;
var next_nonce_len: usize = 0;
var token_requests: usize = 0;

fn issuer(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{provider_port}) catch unreachable;
}

fn discovery(_: *dusty.Request, res: *dusty.Response) !void {
    var buf: [64]u8 = undefined;
    const iss = issuer(&buf);
    res.content_type = .json;
    res.body = try std.fmt.allocPrint(res.arena,
        \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token","jwks_uri":"{s}/jwks"}}
    , .{ iss, iss, iss, iss });
}

fn jwks(_: *dusty.Request, res: *dusty.Response) !void {
    const p = provider_key.public_key.toUncompressedSec1();
    var x: [43]u8 = undefined;
    var y: [43]u8 = undefined;
    res.content_type = .json;
    res.body = try std.fmt.allocPrint(res.arena,
        \\{{"keys":[{{"kty":"EC","crv":"P-256","kid":"k1","alg":"ES256","use":"sig","x":"{s}","y":"{s}"}}]}}
    , .{ b64.Encoder.encode(&x, p[1..33]), b64.Encoder.encode(&y, p[33..65]) });
}

fn token(req: *dusty.Request, res: *dusty.Response) !void {
    token_requests += 1;
    const body = (try req.body()) orelse "";
    // The code verifier must come along (PKCE).
    if (std.mem.indexOf(u8, body, "code_verifier=") == null or std.mem.indexOf(u8, body, "code=the-code") == null) {
        res.status = .bad_request;
        res.body = "{\"error\":\"invalid_grant\"}";
        return;
    }
    var buf: [64]u8 = undefined;
    const now = std.Io.Clock.real.now(req.io).toSeconds();
    const claims = try std.fmt.allocPrint(res.arena,
        \\{{"iss":"{s}","aud":"my-client","sub":"user-7","email":"u7@example.com","email_verified":true,"nonce":"{s}","iat":{d},"exp":{d}}}
    , .{ issuer(&buf), next_nonce[0..next_nonce_len], now, now + 600 });
    const header = "{\"alg\":\"ES256\",\"kid\":\"k1\"}";
    const h = try res.arena.alloc(u8, b64.Encoder.calcSize(header.len));
    const c = try res.arena.alloc(u8, b64.Encoder.calcSize(claims.len));
    const input = try std.fmt.allocPrint(res.arena, "{s}.{s}", .{ b64.Encoder.encode(h, header), b64.Encoder.encode(c, claims) });
    const sig = (try provider_key.sign(input, null)).toBytes();
    var s: [86]u8 = undefined;
    res.content_type = .json;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"access_token\":\"at\",\"id_token\":\"{s}.{s}\"}}", .{ input, b64.Encoder.encode(&s, &sig) });
}

test "OIDC: discovery, PKCE authorization URL, code exchange, ID token checks" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    provider_key = E.KeyPair.generate(io);

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/.well-known/openid-configuration", discovery);
    server.router.get("/jwks", jwks);
    server.router.post("/token", token);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    provider_port = server.address.ip.getPort();

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var buf: [64]u8 = undefined;
    var provider = try oidc.Provider.discover(gpa, .{ .http = &client }, issuer(&buf));
    defer provider.deinit(gpa);
    var keyring = Keyring.init(gpa, io, .{ .http = &client }, provider.jwks_uri);
    defer keyring.deinit();
    const rp: oidc.RelyingParty = .{
        .provider = &provider,
        .client_id = "my-client",
        .client_secret = "s3cret",
        .redirect_uri = "https://app.example/callback",
        .keyring = &keyring,
    };

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = try rp.begin(arena, io);
    try std.testing.expect(std.mem.indexOf(u8, start.url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, start.url, "redirect_uri=https%3A%2F%2Fapp.example%2Fcallback") != null);
    @memcpy(next_nonce[0..start.nonce.len], start.nonce);
    next_nonce_len = start.nonce.len;

    const id = try rp.finish(arena, io, .{ .http = &client }, .{ .code = "the-code", .state = start.state }, start);
    try std.testing.expectEqualStrings("user-7", id.subject);
    try std.testing.expectEqualStrings("u7@example.com", id.email.?);
    try std.testing.expect(id.email_verified);

    // A forged state never reaches the provider.
    const before = token_requests;
    try std.testing.expectError(error.StateMismatch, rp.finish(arena, io, .{ .http = &client }, .{ .code = "the-code", .state = "forged-state-forged-state-forged-state-1234" }, start));
    try std.testing.expectEqual(before, token_requests);

    // An ID token with another sign-in's nonce is refused (replay).
    const second = try rp.begin(arena, io);
    try std.testing.expectError(error.NonceMismatch, rp.finish(arena, io, .{ .http = &client }, .{ .code = "the-code", .state = second.state }, second));
}

test "Sign in with Apple: the client secret is an ES256 JWT our verifier accepts" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const kp = E.KeyPair.generate(io);

    // A .p8: PKCS#8 wrapping an RFC 5915 ECPrivateKey, as Apple issues them.
    var der: [67]u8 = undefined;
    const prefix = [_]u8{
        0x30, 0x41, 0x02, 0x01, 0x00, // SEQUENCE, version 0
        0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // ecPublicKey
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // prime256v1
        0x04, 0x27, 0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20, // OCTET STRING { SEQUENCE { 1, OCTET STRING(32)
    };
    @memcpy(der[0..prefix.len], &prefix);
    @memcpy(der[prefix.len..], &kp.secret_key.toBytes());
    const b64std = std.base64.standard.Encoder;
    const body = try arena.alloc(u8, b64std.calcSize(der.len));
    const pem = try std.fmt.allocPrint(arena, "-----BEGIN PRIVATE KEY-----\n{s}\n-----END PRIVATE KEY-----\n", .{b64std.encode(body, &der)});

    const secret: oidc.AppleSecret = .{ .team_id = "TEAM123456", .key_id = "KEY1234567", .private_key_pem = pem };
    const jwt = try secret.make(arena, io, "com.example.app");

    const jws = @import("jws.zig");
    const key: jws.Key = .{ .kid = "KEY1234567", .alg = .ES256, .material = .{ .p256 = kp.public_key.toUncompressedSec1() } };
    const v = try jws.verify(arena, jwt, &.{key}, .{ .issuer = "TEAM123456", .audience = "https://appleid.apple.com" }, std.Io.Clock.real.now(io).toSeconds());
    try std.testing.expectEqualStrings("com.example.app", v.string("sub").?);
}
