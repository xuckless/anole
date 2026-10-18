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

/// OpenID Connect sign-in (relying party): PKCE, state, nonce, ID tokens;
/// Google and Apple presets.
pub const oidc = @import("oidc.zig");

test {
    _ = jws;
    _ = oidc;
    _ = @import("oidc_test.zig");
}
