//! CSRF protection with a synchronizer token kept in the session (after
//! jetzig's src/jetzig/middleware/AntiCsrfMiddleware.zig, MIT, Copyright
//! 2023-2024 Robert Farrell): forms and scripts send the token back on
//! unsafe methods, in the `_csrf` form field or the `X-CSRF-Token` header,
//! and it is compared in constant time. Needs the session middleware ahead
//! of it.
//!
//!     app.use(anole.session.Middleware.init(...));
//!     app.use(anole.auth.csrf.Middleware.init(.{}));
//!     // in a form: <input type="hidden" name="_csrf" value="{token}">, token = try anole.auth.csrf.token(req)
const std = @import("std");
const dusty = @import("dusty");
const declarations = @import("../openapi/declarations.zig");

/// The session key the token is kept under.
pub const session_key = @import("../session/root.zig").csrf_key;
/// The form field a urlencoded form sends the token back in.
pub const field_name = "_csrf";
/// The header a script sends the token back in.
pub const header_name = "X-CSRF-Token";
const token_len = 43; // 256 bits, base64url

/// The session's token, made on first use.
pub fn token(req: *dusty.Request) ![]const u8 {
    if (req.session.get(session_key)) |t| return t;
    var bytes: [32]u8 = undefined;
    req.io.random(&bytes);
    const t = try req.arena.alloc(u8, token_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(t, &bytes);
    try req.session.set(session_key, t);
    return t;
}

/// `Middleware` settings.
pub const Options = struct {
    /// JSON bodies are skipped as jetzig does: a browser cannot send
    /// `application/json` across sites without a CORS preflight. Turn this
    /// on to check them too.
    check_json: bool = false,
};

/// Checks the token on POST, PUT, PATCH and DELETE (header first, then the
/// form field) and answers 403 when it is missing or wrong. Other methods
/// pass through.
pub const Middleware = struct {
    /// What the OpenAPI document says of a route behind it.
    pub const openapi: declarations.MiddlewareDoc = .{
        .responses = .{ .forbidden = .{ .description = "Missing or wrong CSRF token" } },
    };

    config: Options,

    pub fn init(config: Options) Middleware {
        return .{ .config = config };
    }

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const Middleware, req: *dusty.Request, res: *dusty.Response, next: anytype) !void {
        switch (req.method) {
            .post, .put, .patch, .delete => {},
            else => return next.call(),
        }
        const content_type = req.headers.get("Content-Type") orelse "";
        if (!self.config.check_json and std.mem.startsWith(u8, content_type, "application/json")) return next.call();

        const expected = req.session.get(session_key) orelse return reject(res);
        const sent = req.headers.get(header_name) orelse blk: {
            if (!std.mem.startsWith(u8, content_type, "application/x-www-form-urlencoded")) break :blk null;
            const form = req.formData() catch break :blk null;
            break :blk form.get(field_name);
        } orelse return reject(res);
        if (sent.len != token_len or expected.len != token_len) return reject(res);
        if (!std.crypto.timing_safe.eql([token_len]u8, sent[0..token_len].*, expected[0..token_len].*)) return reject(res);
        return next.call();
    }

    fn reject(res: *dusty.Response) void {
        res.status = .forbidden;
        res.content_type = .text;
        res.body = "403 Forbidden: CSRF token missing or wrong\n";
    }
};
