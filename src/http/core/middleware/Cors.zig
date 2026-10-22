// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Cross-origin resource sharing (the Fetch standard's CORS protocol).
//! `Cors.init(.{})` lets any origin call the API without credentials, and
//! answers preflights with the common methods and whatever request headers
//! the browser asks for, as Fiber's `cors.New()` does:
//!
//!     app.use(Cors.init(.{}));
//!     app.use(Cors.init(.{ .origins = &.{"https://app.example"}, .credentials = true, .expose = "X-Request-Id" }));
//!
//! A preflight (an OPTIONS with `Origin` and `Access-Control-Request-Method`)
//! is answered here with 204 and never reaches a route. In a group it still
//! works: the router runs a group's middleware for an OPTIONS to the
//! group's paths (`Router.miss`). Put `Cors` before middleware that refuses
//! requests (authentication), since a preflight carries no credentials.
const std = @import("std");
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;

/// `Cors.init`'s settings.
pub const Options = struct {
    /// The origins allowed, each as the browser sends it: scheme and host,
    /// and the port when it is not the default (`https://app.example`).
    /// Empty, with `origin` unset, allows every origin.
    origins: []const []const u8 = &.{},
    /// One origin, or "*" for any: the earlier single-origin form, kept,
    /// and allowed beside `origins`.
    origin: ?[]const u8 = null,
    /// `Access-Control-Allow-Methods` in a preflight answer. Null: GET,
    /// HEAD, POST, PUT, PATCH, DELETE.
    methods: ?[]const u8 = null,
    /// `Access-Control-Allow-Headers` in a preflight answer. Null: the
    /// headers the preflight asks for (`Access-Control-Request-Headers`),
    /// whatever they are.
    headers: ?[]const u8 = null,
    /// `Access-Control-Expose-Headers`: response headers beyond the
    /// CORS-safelisted ones that a page's script may read
    /// (`"X-Request-Id, ETag"`).
    expose: ?[]const u8 = null,
    /// Let the browser send cookies and HTTP authentication, and the page
    /// read the answer (`Access-Control-Allow-Credentials: true`). Needs a
    /// list of origins: with every origin allowed, `init` panics, since
    /// that would let any site act as the signed-in user.
    credentials: bool = false,
    /// How long a browser may reuse a preflight answer
    /// (`Access-Control-Max-Age`). Browsers cap it (Chromium at two
    /// hours); null sends none, which leaves their default of 5 seconds.
    max_age: ?std.Io.Duration = .fromSeconds(600),
};

pub const default_methods = "GET, HEAD, POST, PUT, PATCH, DELETE";

origins: []const []const u8,
extra_origin: ?[]const u8,
any_origin: bool,
methods: []const u8,
headers: ?[]const u8,
expose: ?[]const u8,
credentials: bool,
max_age_buf: [10]u8 = undefined,
max_age_len: u8 = 0,

const Cors = @This();

/// Panics on a configuration that cannot be served safely: credentials
/// with every origin allowed.
pub fn init(config: Options) Cors {
    var any = config.origins.len == 0 and config.origin == null;
    for (config.origins) |o| {
        if (std.mem.eql(u8, o, "*")) any = true;
    }
    if (config.origin) |o| {
        if (std.mem.eql(u8, o, "*")) any = true;
    }
    if (config.credentials and any) {
        @panic("Cors: .credentials = true needs a list of origins, not every origin: a browser refuses \"*\" with " ++
            "credentials, and echoing any origin would let every site act as the signed-in user");
    }
    var self: Cors = .{
        .origins = config.origins,
        .extra_origin = config.origin,
        .any_origin = any,
        .methods = config.methods orelse default_methods,
        .headers = config.headers,
        .expose = config.expose,
        .credentials = config.credentials,
    };
    if (config.max_age) |seconds| {
        self.max_age_len = @intCast((std.fmt.bufPrint(&self.max_age_buf, "{d}", .{@max(0, seconds.toSeconds())}) catch unreachable).len);
    }
    return self;
}

/// Only sets headers before `next()`: requests behind it can detach
/// (`Detached`).
pub const detach_safe = true;

pub fn execute(self: *const Cors, req: *Request, res: *Response, next: anytype) !void {
    const origin = req.headers.get("Origin");
    const preflight = req.method == .options and origin != null and
        req.headers.get("Access-Control-Request-Method") != null;

    const allowed = try self.allowOrigin(res, origin);

    if (!preflight) {
        if (allowed and origin != null) if (self.expose) |expose| try res.header("Access-Control-Expose-Headers", expose);
        return next.call();
    }

    // A preflight is answered here, allowed or not: no route serves it. An
    // origin not allowed gets no CORS headers, and the browser stops there.
    res.status = .no_content;
    if (!allowed) return;
    try res.header("Access-Control-Allow-Methods", self.methods);
    if (self.headers) |headers| {
        try res.header("Access-Control-Allow-Headers", headers);
    } else if (req.headers.get("Access-Control-Request-Headers")) |asked| {
        try res.header("Access-Control-Allow-Headers", asked);
        try res.addHeader("Vary", "Access-Control-Request-Headers");
    }
    if (self.max_age_len > 0) try res.header("Access-Control-Max-Age", self.max_age_buf[0..self.max_age_len]);
}

/// Sets `Access-Control-Allow-Origin` (and `-Credentials`) for an allowed
/// origin, and `Vary: Origin` when the answer depends on the origin.
/// Whether the origin is allowed.
fn allowOrigin(self: *const Cors, res: *Response, origin: ?[]const u8) !bool {
    if (self.any_origin) {
        // The same answer for every origin, so nothing to vary on.
        try res.header("Access-Control-Allow-Origin", "*");
        return true;
    }
    try res.addHeader("Vary", "Origin");
    const o = origin orelse return false;
    if (!self.listed(o)) return false;
    // Echoed only once it matched a configured origin byte for byte.
    try res.header("Access-Control-Allow-Origin", o);
    if (self.credentials) try res.header("Access-Control-Allow-Credentials", "true");
    return true;
}

fn listed(self: *const Cors, origin: []const u8) bool {
    if (self.extra_origin) |o| if (std.mem.eql(u8, o, origin)) return true;
    for (self.origins) |o| if (std.mem.eql(u8, o, origin)) return true;
    return false;
}
