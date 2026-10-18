//! OpenID Connect sign-in, as a relying party (never a provider): the
//! authorization code flow with PKCE (S256), state and nonce, and the ID
//! token checks of OIDC Core 3.1.3.7. The logic follows liboauth2's
//! relying-party code (OpenIDC/liboauth2, Apache-2.0), rewritten on dusty's
//! HTTP client, the JWS verifier and std.crypto.
//!
//!     var provider = try oidc.Provider.discover(client, gpa, "https://accounts.google.com");
//!     var rp: oidc.RelyingParty = .{ .provider = &provider, .client_id = id, .client_secret = secret,
//!                                    .redirect_uri = "https://app.example/callback", .keyring = &keyring };
//!     // /login:    const start = try rp.begin(arena, io);  keep start.state/nonce/verifier (session), redirect to start.url
//!     // /callback: const id = try rp.finish(arena, io, client, .{ .code = code, .state = state }, saved);
const std = @import("std");
const dusty = @import("dusty");
const jws = @import("jws.zig");
const Keyring = @import("keyring.zig").Keyring;
const zig_jwt = @import("anole_jwt");

const b64 = std.base64.url_safe_no_pad;

/// What a provider's discovery document says, owned by `arena`.
pub const Provider = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    jwks_uri: []const u8,
    userinfo_endpoint: ?[]const u8 = null,
    arena: ?*std.heap.ArenaAllocator = null,

    /// Fetches `issuer/.well-known/openid-configuration`; its `issuer`
    /// must be `issuer` exactly (OIDC Discovery 4.3).
    pub fn discover(client: *dusty.Client, gpa: std.mem.Allocator, issuer: []const u8) !Provider {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        const url = try std.fmt.allocPrint(a, "{s}/.well-known/openid-configuration", .{std.mem.trimEnd(u8, issuer, "/")});
        var response = try client.fetch(url, .{});
        defer response.deinit();
        if (response.status() != .ok) return error.DiscoveryFailed;
        const body = try a.dupe(u8, (try response.body()) orelse return error.DiscoveryFailed);
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.DiscoveryFailed;
        if (doc != .object) return error.DiscoveryFailed;
        const o = doc.object;
        const got_issuer = str(o, "issuer") orelse return error.DiscoveryFailed;
        if (!std.mem.eql(u8, got_issuer, issuer)) return error.IssuerMismatch;
        return .{
            .issuer = got_issuer,
            .authorization_endpoint = str(o, "authorization_endpoint") orelse return error.DiscoveryFailed,
            .token_endpoint = str(o, "token_endpoint") orelse return error.DiscoveryFailed,
            .jwks_uri = str(o, "jwks_uri") orelse return error.DiscoveryFailed,
            .userinfo_endpoint = str(o, "userinfo_endpoint"),
            .arena = arena,
        };
    }

    pub fn deinit(self: *Provider, gpa: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            gpa.destroy(a);
        }
    }

    /// Google's endpoints (what its discovery document says).
    pub const google: Provider = .{
        .issuer = "https://accounts.google.com",
        .authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth",
        .token_endpoint = "https://oauth2.googleapis.com/token",
        .jwks_uri = "https://www.googleapis.com/oauth2/v3/certs",
        .userinfo_endpoint = "https://openidconnect.googleapis.com/v1/userinfo",
    };

    /// Sign in with Apple's endpoints.
    pub const apple: Provider = .{
        .issuer = "https://appleid.apple.com",
        .authorization_endpoint = "https://appleid.apple.com/auth/authorize",
        .token_endpoint = "https://appleid.apple.com/auth/token",
        .jwks_uri = "https://appleid.apple.com/auth/keys",
    };
};

fn str(o: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = o.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Sign in with Apple's client secret: a short-lived ES256 JWT signed with
/// the developer's key (the `.p8` file), made per token request.
pub const AppleSecret = struct {
    team_id: []const u8,
    key_id: []const u8,
    /// The `.p8` key: PEM PKCS#8, EC P-256.
    private_key_pem: []const u8,
    lifetime_seconds: i64 = 300,

    /// A fresh client secret for `client_id` (the Services ID).
    pub fn make(self: AppleSecret, arena: std.mem.Allocator, io: std.Io, client_id: []const u8) ![]const u8 {
        const der = try pemBody(arena, self.private_key_pem);
        const key = zig_jwt.ecdsa.ParseP256Sha256Der.parseSecretKeyPKCS8Der(der) catch return error.InvalidAppleKey;
        var signer = zig_jwt.SigningMethodES256.init(arena);
        var rng: std.Random.IoSource = .{ .io = io };
        signer.withRandom(rng.interface());
        const now = std.Io.Clock.real.now(io).toSeconds();
        return signer.signWithHeader(.{ .alg = "ES256", .kid = self.key_id }, .{
            .iss = self.team_id,
            .iat = now,
            .exp = now + self.lifetime_seconds,
            .aud = "https://appleid.apple.com",
            .sub = client_id,
        }, key);
    }
};

fn pemBody(arena: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return error.InvalidPem;
    const start = (std.mem.indexOfScalarPos(u8, pem, begin, '\n') orelse return error.InvalidPem) + 1;
    const stop = std.mem.indexOfPos(u8, pem, start, "-----END") orelse return error.InvalidPem;
    var text: std.ArrayList(u8) = .empty;
    for (pem[start..stop]) |ch| if (ch != '\n' and ch != '\r' and ch != ' ') try text.append(arena, ch);
    const out = try arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(text.items) catch return error.InvalidPem);
    std.base64.standard.Decoder.decode(out, text.items) catch return error.InvalidPem;
    return out;
}

/// What `begin` hands out: the URL to send the user to, and the values to
/// keep (in the session) until the callback.
pub const Start = struct {
    url: []const u8,
    state: []const u8,
    nonce: []const u8,
    code_verifier: []const u8,
};

/// What came back to the redirect URI.
pub const Callback = struct {
    code: []const u8,
    state: []const u8,
};

/// The signed-in user, from the verified ID token.
pub const Identity = struct {
    subject: []const u8,
    email: ?[]const u8,
    email_verified: bool,
    name: ?[]const u8,
    /// Every claim of the ID token.
    claims: jws.Verified,
    access_token: ?[]const u8,
    refresh_token: ?[]const u8,
};

pub const RelyingParty = struct {
    provider: *const Provider,
    client_id: []const u8,
    /// client_secret_post; null with `apple_secret` or for a public client.
    client_secret: ?[]const u8 = null,
    apple_secret: ?AppleSecret = null,
    redirect_uri: []const u8,
    scope: []const u8 = "openid email profile",
    /// Apple asks for form_post when name or email is in scope.
    response_mode: ?[]const u8 = null,
    keyring: *Keyring,
    /// Clock skew allowed on the ID token's times.
    leeway_seconds: i64 = 60,

    /// A fresh state, nonce and PKCE verifier, and the authorization URL.
    pub fn begin(self: *const RelyingParty, arena: std.mem.Allocator, io: std.Io) !Start {
        const state = try randomToken(arena, io);
        const nonce = try randomToken(arena, io);
        const verifier = try randomToken(arena, io);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var challenge_buf: [43]u8 = undefined;
        const challenge = b64.Encoder.encode(&challenge_buf, &digest);

        var url: std.Io.Writer.Allocating = .init(arena);
        const w = &url.writer;
        try w.print("{s}{s}response_type=code", .{ self.provider.authorization_endpoint, if (std.mem.indexOfScalar(u8, self.provider.authorization_endpoint, '?') != null) "&" else "?" });
        try param(w, "client_id", self.client_id);
        try param(w, "redirect_uri", self.redirect_uri);
        try param(w, "scope", self.scope);
        try param(w, "state", state);
        try param(w, "nonce", nonce);
        try param(w, "code_challenge", challenge);
        try param(w, "code_challenge_method", "S256");
        if (self.response_mode) |m| try param(w, "response_mode", m);
        return .{ .url = url.written(), .state = state, .nonce = nonce, .code_verifier = verifier };
    }

    /// Checks the callback against what `begin` handed out, exchanges the
    /// code, and verifies the ID token.
    pub fn finish(self: *const RelyingParty, arena: std.mem.Allocator, io: std.Io, client: *dusty.Client, callback: Callback, saved: Start) !Identity {
        // state: the response is to our request (CSRF, RFC 6749 10.12).
        if (callback.state.len != saved.state.len or !constTimeEql(callback.state, saved.state)) return error.StateMismatch;

        var form: std.Io.Writer.Allocating = .init(arena);
        const w = &form.writer;
        try w.writeAll("grant_type=authorization_code");
        try param(w, "code", callback.code);
        try param(w, "redirect_uri", self.redirect_uri);
        try param(w, "code_verifier", saved.code_verifier);
        try param(w, "client_id", self.client_id);
        if (self.apple_secret) |apple| {
            try param(w, "client_secret", try apple.make(arena, io, self.client_id));
        } else if (self.client_secret) |secret| {
            try param(w, "client_secret", secret);
        }
        var headers = try dusty.Headers.init(arena, 4);
        try headers.put("Content-Type", "application/x-www-form-urlencoded");
        try headers.put("Accept", "application/json");
        var response = try client.fetch(self.provider.token_endpoint, .{ .method = .post, .headers = &headers, .body = form.written() });
        defer response.deinit();
        const body = try arena.dupe(u8, (try response.body()) orelse "");
        if (response.status() != .ok) {
            std.log.scoped(.anole_oidc).info("token endpoint said {d}: {s}", .{ @backingInt(response.status()), body[0..@min(body.len, 200)] });
            return error.TokenRequestFailed;
        }
        const tokens = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.TokenRequestFailed;
        if (tokens != .object) return error.TokenRequestFailed;
        const id_token = str(tokens.object, "id_token") orelse return error.NoIdToken;

        // OIDC Core 3.1.3.7: signature, iss, aud, exp, iat; then azp and nonce.
        const v = try self.keyring.verify(arena, id_token, .{
            .issuer = self.provider.issuer,
            .audience = self.client_id,
            .leeway_seconds = self.leeway_seconds,
        });
        if (v.claims.get("aud")) |aud| if (aud == .array and aud.array.items.len > 1) {
            const azp = v.string("azp") orelse return error.AzpMismatch;
            if (!std.mem.eql(u8, azp, self.client_id)) return error.AzpMismatch;
        };
        const nonce = v.string("nonce") orelse return error.NonceMismatch;
        if (nonce.len != saved.nonce.len or !constTimeEql(nonce, saved.nonce)) return error.NonceMismatch;

        const verified_email = if (v.claims.get("email_verified")) |e| switch (e) {
            .bool => |b| b,
            // Apple sends it as a string.
            .string => |s| std.mem.eql(u8, s, "true"),
            else => false,
        } else false;
        return .{
            .subject = v.string("sub") orelse return error.NoSubject,
            .email = v.string("email"),
            .email_verified = verified_email,
            .name = v.string("name"),
            .claims = v,
            .access_token = str(tokens.object, "access_token"),
            .refresh_token = str(tokens.object, "refresh_token"),
        };
    }
};

fn constTimeEql(a: []const u8, b: []const u8) bool {
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

/// 256 random bits, base64url (43 characters).
fn randomToken(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    const out = try arena.alloc(u8, 43);
    return b64.Encoder.encode(out, &bytes);
}

/// `&name=value`, the value percent-encoded (RFC 3986 unreserved kept).
fn param(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try w.print("&{s}=", .{name});
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}
