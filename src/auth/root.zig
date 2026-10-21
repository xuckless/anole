//! Auth (-Dauth): verifying JWTs (JWS) against keys and JWK sets, signing
//! them through the patched zig-jwt fork, OIDC sign-in, CSRF, passwords,
//! API keys and roles. Sessions are `anole.session`, rate limits
//! `anole.ratelimit`.
//!
//! Where to start: `RequireJwt` for an API that takes bearer tokens (with
//! `Keyring` when a provider publishes its keys), `oidc.RelyingParty` for
//! "Sign in with Google/Apple", `password` for your own logins,
//! `apikey.Middleware` for machine clients, `rbac.Require` for
//! permissions. Each middleware answers its own 401, 403 or 503, and
//! leaves who the caller is in the request's locals (`claims(req)`,
//! `subject(req)`, `apikey.owner(req)`).
const std = @import("std");

/// JWS verification with pinned algorithms and a claims policy.
pub const jws = @import("jws.zig");
/// A verification key, pinned to one algorithm.
pub const Key = jws.Key;
/// The JWS algorithms accepted (`none` never is).
pub const Alg = jws.Alg;
/// The claims a token must satisfy: issuer, audience, `exp`, leeway, age.
pub const Policy = jws.Policy;
/// A token that verified: its header and claims.
pub const Verified = jws.Verified;
/// Verifies a token against fixed keys: `verify(arena, token, keys, policy,
/// now)`, with `now` in Unix seconds. For a provider's JWK Set, use
/// `Keyring.verify`.
pub const verify = jws.verify;
/// The keys of a JWK Set document.
pub const parseJwks = jws.parseJwks;

/// xuckless/zig-jwt (MIT, patched): building and signing tokens.
pub const jwt = @import("anole_jwt");

/// A JWK Set fetched from a URL and kept, refreshed on rotation.
pub const Keyring = @import("keyring.zig").Keyring;

/// JWT bearer tokens (RFC 6750): `RequireJwt`, a middleware.
pub const bearer = @import("bearer.zig");
/// A middleware that requires a valid JWT bearer token (401/403 per RFC
/// 6750 otherwise):
///
///     app.use(anole.auth.RequireJwt.init(.{ .static = &keys }, .{ .audience = "api" }, .{}));
pub const RequireJwt = bearer.RequireJwt;
/// The token `RequireJwt` verified for this request, or null on a route
/// without it: `anole.auth.claims(req).?.string("email")`.
pub const claims = bearer.claims;
/// The verified token's `sub` claim (who the request is from), or null.
pub const subject = bearer.subject;

/// OpenID Connect sign-in (relying party): PKCE, state, nonce, ID tokens;
/// Google and Apple presets.
pub const oidc = @import("oidc.zig");

/// CSRF tokens in the session, checked on unsafe methods.
pub const csrf = @import("csrf.zig");
/// Argon2id password hashes (bcrypt accepted on verify).
pub const password = @import("password.zig");
/// Prefixed random API keys stored as SHA-256, and a middleware.
pub const apikey = @import("apikey.zig");
/// Roles, permissions and a middleware that requires one.
pub const rbac = @import("rbac.zig");

test {
    _ = jws;
    _ = @import("keyring.zig");
    _ = bearer;
    _ = csrf;
    _ = password;
    _ = apikey;
    _ = rbac;
    _ = @import("csrf_test.zig");
    _ = oidc;
    _ = @import("oidc_test.zig");
}
