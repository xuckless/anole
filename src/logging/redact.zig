// Adapted from vkiryakov/zefir src/log/redact.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Redaction by field name: a field named like a secret is written as
//! "[REDACTED]", whatever its value. Decided at compile time, so it costs
//! nothing at run time.

const std = @import("std");

/// What a redacted value is written as.
pub const placeholder = "[REDACTED]";

/// The secret names. A field name counts when its last words spell one of
/// them, in any case and with or without '_' and '-': `api_key`, `apiKey`,
/// `X-Api-Key`, `stripe_api_key` and the plural `api_keys` all count. A
/// bare `token` is left out on purpose: lexers and pagination use it.
/// examples/README.md lists these names; keep the two in step.
const names = [_][]const u8{
    "password",              "passwd",      "secret",        "client_secret",
    "api_key",               "apikey",      "access_token",  "refresh_token",
    "id_token",              "auth_token",  "authorization", "cookie",
    "set_cookie",            "private_key", "secret_key",    "secret_access_key",
    "aws_secret_access_key",
};

/// Whether `T` declares `pub const anole_sensitive = true;` (anole.Secret
/// does). Only structs, unions, enums and opaque types can; a marker that
/// is not a `bool` is a compile error.
pub fn isSensitiveType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "anole_sensitive")) return false;
    const marker = T.anole_sensitive;
    if (@TypeOf(marker) != bool)
        @compileError("anole.log: " ++ @typeName(T) ++ ".anole_sensitive must be a bool: pub const anole_sensitive = true;");
    return marker;
}

/// Whether a field called `name` is redacted. Every dot-separated segment
/// is checked, so `db.password` is redacted as a nested `password` would
/// be. A segment counts when it ends with a listed name, or its plural,
/// and that name starts a word: `db_password` and `newPassword` count,
/// `password_hash` and `dbpassword` do not.
pub fn isSensitiveName(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    var segments = std.mem.splitScalar(u8, name, '.');
    while (segments.next()) |segment| {
        const singular = withoutPlural(segment);
        for (names) |sensitive| {
            if (endsWithName(segment, sensitive) or endsWithName(singular, sensitive)) return true;
        }
    }
    return false;
}

/// `segment` without a final 's' or 'S' (and the '_' or '-' after it), so
/// a plural is matched as its singular.
fn withoutPlural(segment: []const u8) []const u8 {
    var end = segment.len;
    while (end > 0 and isSeparator(segment[end - 1])) end -= 1;
    if (end > 0 and std.ascii.toLower(segment[end - 1]) == 's') end -= 1;
    return segment[0..end];
}

/// Whether `segment` ends with `sensitive` (lowercase) in any case, with or
/// without '_' and '-', and that ending starts a word.
fn endsWithName(segment: []const u8, sensitive: []const u8) bool {
    var a = segment.len;
    var b = sensitive.len;
    while (true) {
        while (b > 0 and isSeparator(sensitive[b - 1])) b -= 1;
        if (b == 0) return isWordStart(segment, a);
        while (a > 0 and isSeparator(segment[a - 1])) a -= 1;
        if (a == 0 or std.ascii.toLower(segment[a - 1]) != sensitive[b - 1]) return false;
        a -= 1;
        b -= 1;
    }
}

/// Whether a word starts at `segment[i]`: at the start, after '_' or '-',
/// at a capital after a small letter or a digit (`newPassword`), or at the
/// last capital of a run that a small letter follows (`XApiKey`).
fn isWordStart(segment: []const u8, i: usize) bool {
    if (i == 0 or isSeparator(segment[i - 1])) return true;
    if (!std.ascii.isUpper(segment[i])) return false;
    const prev = segment[i - 1];
    if (std.ascii.isLower(prev) or std.ascii.isDigit(prev)) return true;
    return std.ascii.isUpper(prev) and i + 1 < segment.len and std.ascii.isLower(segment[i + 1]);
}

fn isSeparator(c: u8) bool {
    return c == '_' or c == '-';
}

test "secret names are redacted whatever their case or dashes" {
    try std.testing.expect(comptime isSensitiveName("password"));
    try std.testing.expect(comptime isSensitiveName("Api-Key"));
    try std.testing.expect(comptime isSensitiveName("APIKEY"));
    try std.testing.expect(comptime isSensitiveName("set-cookie"));
    try std.testing.expect(comptime isSensitiveName("private_key"));
}

test "any segment of a dotted name counts" {
    try std.testing.expect(comptime isSensitiveName("db.password"));
    try std.testing.expect(comptime isSensitiveName("http.authorization.scheme"));
}

test "camelCase and SCREAMING_CASE spellings count too" {
    inline for (.{ "apiKey", "accessToken", "refreshToken", "idToken", "authToken", "clientSecret", "privateKey", "setCookie", "API_KEY", "Pass-Word" }) |name| {
        try std.testing.expect(comptime isSensitiveName(name));
    }
}

test "the names std.crypto and AWS give secret keys count too" {
    inline for (.{ "secret_key", "secretKey", "SECRET_KEY", "kp.secret_key", "secret_access_key", "SecretAccessKey", "aws_secret_access_key", "AWS_SECRET_ACCESS_KEY" }) |name| {
        try std.testing.expect(comptime isSensitiveName(name));
    }
}

test "a name that ends in a secret name counts" {
    inline for (.{ "db_password", "smtp_password", "new_password", "newPassword", "OLD-PASSWORD", "x_api_key", "X-Api-Key", "xApiKey", "stripe_api_key", "jwt_secret", "oauth_token_secret", "session_cookie", "proxy_authorization", "ProxyAuthorization", "github_access_token", "db.root_password" }) |name| {
        try std.testing.expect(comptime isSensitiveName(name));
    }
}

test "a plural counts too" {
    inline for (.{ "passwords", "api_keys", "apiKeys", "API_KEYS", "secrets", "cookies", "access_tokens" }) |name| {
        try std.testing.expect(comptime isSensitiveName(name));
    }
}

test "similar names are written as they are" {
    inline for (.{ "token", "tokens_used", "user_id", "password_hash", "password_min_length", "passwordless", "secretary", "secret_name", "cookie_domain", "authorization_url", "api_key_id", "private_key_path" }) |name| {
        try std.testing.expect(comptime !isSensitiveName(name));
    }
    // The secret name must start a word: at the start, after '_' or '-', or
    // at a capital letter.
    try std.testing.expect(comptime !isSensitiveName("dbpassword"));
    try std.testing.expect(comptime !isSensitiveName("DBPASSWORD"));
    // A dot separates names, and each part is matched alone.
    try std.testing.expect(comptime !isSensitiveName("api.key"));
}
