//! Auth (-Dauth): verifying JWTs (JWS) against keys and JWK sets, signing
//! them through the patched zig-jwt fork, OIDC sign-in, CSRF, passwords,
//! API keys and roles.
const std = @import("std");

/// JWS verification with pinned algorithms and a claims policy.
pub const jws = @import("jws.zig");
pub const Key = jws.Key;
pub const Alg = jws.Alg;
pub const Policy = jws.Policy;
pub const Verified = jws.Verified;
pub const verify = jws.verify;
pub const parseJwks = jws.parseJwks;

/// xuckless/zig-jwt (MIT, patched): building and signing tokens.
pub const jwt = @import("anole_jwt");

/// A JWK Set fetched from a URL and kept, refreshed on rotation.
pub const Keyring = @import("keyring.zig").Keyring;

/// JWT bearer tokens (RFC 6750): `RequireJwt`, a middleware.
pub const bearer = @import("bearer.zig");
pub const RequireJwt = bearer.RequireJwt;
/// The token `RequireJwt` verified for this request, and its `sub`.
pub const claims = bearer.claims;
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
