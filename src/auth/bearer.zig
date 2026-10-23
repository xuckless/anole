//! JWT bearer tokens (RFC 6750): a middleware that requires
//! `Authorization: Bearer <JWT>`, verified with fixed keys or a `Keyring`
//! and checked against a claims policy, and hands the verified token to the
//! handler through the request's locals.
//!
//!     const api = app.group("/api", .{anole.auth.RequireJwt.init(.{ .keyring = &keyring }, .{ .issuer = iss, .audience = "api" }, .{})});
//!     api.get("/me", me);
//!     // in the handler: anole.auth.subject(req).?, or anole.auth.claims(req).?.string("email")
//!
//! Refusals follow RFC 6750 section 3: no token is 401 with a bare
//! `WWW-Authenticate: Bearer`, a bad one 401 `error="invalid_token"`, a
//! malformed header 400 `error="invalid_request"`, a token without the
//! required scopes 403 `error="insufficient_scope"`.
const std = @import("std");
const dusty = @import("dusty");
const declarations = @import("../openapi/declarations.zig");
const jws = @import("jws.zig");
const Keyring = @import("keyring.zig").Keyring;

const log = std.log.scoped(.anole_auth);

/// Where `RequireJwt` keeps the verified token in `req.locals`; read it
/// with `claims`.
pub const claims_key = "anole.auth.jwt";

/// The token `RequireJwt` verified for this request (its claims, header,
/// algorithm and key ID), or null on a route without it. Lives in the
/// request's arena.
pub fn claims(req: *const dusty.Request) ?*const jws.Verified {
    return req.locals.getPtr(jws.Verified, claims_key);
}

/// The verified token's `sub` claim: who the request is from.
pub fn subject(req: *const dusty.Request) ?[]const u8 {
    const v = claims(req) orelse return null;
    return v.string("sub");
}

/// Called with the verified token before the handler, for checks of your
/// own (array or object claims, a revocation list). Its claims live in
/// `req.arena`. An error refuses the request with 401 `invalid_token`.
pub const Hook = struct {
    ptr: ?*anyopaque = null,
    func: *const fn (ptr: ?*anyopaque, req: *dusty.Request, token: *const jws.Verified) anyerror!void,
};

/// The keys `RequireJwt` verifies with.
pub const Keys = union(enum) {
    /// Keys held by the application (each pinned to one algorithm).
    static: []const jws.Key,
    /// A provider's JWK Set, fetched and refreshed.
    keyring: *Keyring,
};

/// `RequireJwt` settings beyond the claims policy.
pub const Options = struct {
    /// String claims a token must carry; one without any of them is
    /// refused with 401 `invalid_token`. `sub` by default, so `subject(req)`
    /// is never null behind the middleware; `&.{}` requires none.
    required_claims: []const []const u8 = &.{"sub"},
    /// Every one of these must be in the token's `scope` claim (a
    /// space-separated string, RFC 8693); 403 otherwise.
    scopes: []const []const u8 = &.{},
    /// `realm` in `WWW-Authenticate`.
    realm: ?[]const u8 = null,
    /// Extra checks on the verified token; see `Hook`.
    hook: ?Hook = null,
};

/// Requires a valid JWT bearer token: `RequireJwt.init(keys, policy, options)`.
/// `policy` sets the required issuer and audience, leeway and `exp`
/// rules (`anole.auth.Policy`).
pub const RequireJwt = struct {
    /// What the OpenAPI document says of a route behind it.
    pub const openapi: declarations.MiddlewareDoc = .{
        .security_schemes = &.{.{ .name = "bearerAuth", .kind = .{ .http = .{ .scheme = "bearer", .bearer_format = "JWT" } } }},
        .security = .any,
        .responses = .{ .unauthorized = .{ .description = "Missing, expired or invalid token" } },
    };

    keys: Keys,
    policy: jws.Policy,
    options: Options = .{},

    /// The middleware, verifying with `keys` (which must outlive it) against
    /// `policy`.
    pub fn init(keys: Keys, policy: jws.Policy, options: Options) RequireJwt {
        return .{ .keys = keys, .policy = policy, .options = options };
    }

    /// Does nothing after `next()`: requests behind it can detach.
    pub const detach_safe = true;

    /// Static keys and no hook: verification is CPU only. A keyring may
    /// fetch the provider's key set, and a hook may do anything.
    pub fn noWait(self: *const RequireJwt) bool {
        return self.keys == .static and self.options.hook == null;
    }

    pub fn execute(self: *const RequireJwt, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        const header = req.headers.get("Authorization") orelse return self.refuse(res, .missing);
        const space = std.mem.indexOfScalar(u8, header, ' ') orelse return self.refuse(res, .missing);
        // Another scheme (Basic, ...) is no bearer token.
        if (!std.ascii.eqlIgnoreCase(header[0..space], "Bearer")) return self.refuse(res, .missing);
        const token = std.mem.trim(u8, header[space + 1 ..], " ");
        if (token.len == 0 or std.mem.indexOfScalar(u8, token, ' ') != null) return self.refuse(res, .invalid_request);

        const v = self.verify(req, token) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |e| return e,
            error.Expired => return self.refuse(res, .expired),
            error.Malformed,
            error.UnsupportedAlgorithm,
            error.NoMatchingKey,
            error.BadSignature,
            error.NotYetValid,
            error.IssuedInFuture,
            error.MissingExpiry,
            error.WrongIssuer,
            error.WrongAudience,
            error.TooOld,
            error.MissingIssuedAt,
            error.WrongType,
            => {
                log.debug("bearer token refused: {t}", .{err});
                return self.refuse(res, .invalid_token);
            },
            // The server's configuration, which no token can get past: an
            // HMAC secret too short to be safe, or a keyring with no
            // audience to check.
            error.WeakKey, error.AudienceRequired => |e| {
                if (e == error.WeakKey) {
                    log.err("bearer token not verified: the HMAC key is shorter than its hash (32 bytes for HS256, 48 for HS384, 64 for HS512)", .{});
                } else {
                    log.err("bearer token not verified: a keyring's policy needs .audience (this API's identifier at the provider), or .allow_any_audience = true when its keys sign for this application alone", .{});
                }
                res.status = .internal_server_error;
                res.content_type = .text;
                res.body = "500 Internal Server Error\n";
                return;
            },
            // The keys could not be had (the provider is down): not the
            // token's fault, so not a 401 that would make the client drop it.
            else => {
                log.warn("bearer token not verified: {t}", .{err});
                res.status = .service_unavailable;
                res.content_type = .text;
                res.body = "503 Service Unavailable\n";
                return;
            },
        };

        for (self.options.required_claims) |name| {
            if (v.string(name) == null) return self.refuse(res, .invalid_token);
        }
        if (self.options.scopes.len > 0) {
            const granted = v.string("scope") orelse "";
            for (self.options.scopes) |want| {
                var it = std.mem.tokenizeScalar(u8, granted, ' ');
                const found = while (it.next()) |s| {
                    if (std.mem.eql(u8, s, want)) break true;
                } else false;
                if (!found) return self.refuse(res, .insufficient_scope);
            }
        }

        try req.setLocal(claims_key, v);
        if (self.options.hook) |h| h.func(h.ptr, req, &v) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |e| return e,
            else => {
                log.debug("bearer token refused by the hook: {t}", .{err});
                return self.refuse(res, .invalid_token);
            },
        };
        return next.call();
    }

    fn verify(self: *const RequireJwt, req: *dusty.Request, token: []const u8) !jws.Verified {
        return switch (self.keys) {
            .static => |keys| jws.verify(req.arena, token, keys, self.policy, std.Io.Clock.real.now(req.io).toSeconds()),
            .keyring => |k| k.verify(req.arena, token, self.policy),
        };
    }

    const Refusal = enum { missing, invalid_request, invalid_token, expired, insufficient_scope };

    fn refuse(self: *const RequireJwt, res: *dusty.Response, why: Refusal) !void {
        res.status = switch (why) {
            .missing, .invalid_token, .expired => .unauthorized,
            .invalid_request => .bad_request,
            .insufficient_scope => .forbidden,
        };
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("Bearer") catch {};
        var sep: []const u8 = " ";
        if (self.options.realm) |realm| {
            w.print("{s}realm=\"{s}\"", .{ sep, realm }) catch {};
            sep = ", ";
        }
        switch (why) {
            .missing => {},
            .invalid_request => w.print("{s}error=\"invalid_request\"", .{sep}) catch {},
            .invalid_token => w.print("{s}error=\"invalid_token\"", .{sep}) catch {},
            .expired => w.print("{s}error=\"invalid_token\", error_description=\"The access token expired\"", .{sep}) catch {},
            .insufficient_scope => {
                w.print("{s}error=\"insufficient_scope\", scope=\"", .{sep}) catch {};
                for (self.options.scopes, 0..) |s, i| w.print("{s}{s}", .{ if (i > 0) " " else "", s }) catch {};
                w.writeAll("\"") catch {};
            },
        }
        try res.header("WWW-Authenticate", try res.arena.dupe(u8, w.buffered()));
        res.content_type = .text;
        res.body = switch (res.status) {
            .bad_request => "400 Bad Request\n",
            .forbidden => "403 Forbidden\n",
            else => "401 Unauthorized\n",
        };
    }
};

test {
    _ = @import("bearer_test.zig");
}
