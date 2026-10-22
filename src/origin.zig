//! Which web pages may open a WebSocket or a WebTransport session, by the
//! `Origin` header a browser sends with the handshake. A browser sends the
//! page's cookies with it whatever page asks, so without this check any
//! site a logged-in user visits could open a socket in that user's name.
const std = @import("std");
const dusty = @import("dusty");

/// The pages allowed to open the endpoint (`UpgradeOptions.allowed_origins`,
/// `AcceptOptions.allowed_origins`). A request without `Origin` (a client
/// that is not a browser) is always let through; a refused one gets 403.
pub const Origins = union(enum) {
    /// Pages on the request's own host and port, as `Host` (or HTTP/2's and
    /// HTTP/3's `:authority`, or a trusted proxy's `X-Forwarded-Host`) names
    /// them. The scheme is not compared, so a proxy that terminates TLS in
    /// front does not get in the way. A missing port is the scheme's
    /// default.
    same_origin,
    /// Pages on the request's own host, as with `.same_origin`, and these:
    /// each as the browser sends it, `scheme://host` or
    /// `scheme://host:port`, compared without regard to case (`"null"` for
    /// sandboxed pages and files, if those are welcome).
    list: []const []const u8,
    /// Any page. Only for an endpoint that does not trust cookies or other
    /// credentials the browser adds by itself (a token in the first message
    /// is fine).
    any,
};

/// Whether `req` may go on under `origins`.
pub fn allowed(req: *const dusty.Request, origins: Origins) bool {
    const origin = req.headers.get("Origin") orelse return true;
    return check(origin, req.host(), origins);
}

/// `allowed`, on the header values.
pub fn check(origin: []const u8, host: ?[]const u8, origins: Origins) bool {
    switch (origins) {
        .any => return true,
        .same_origin => {},
        .list => |list| for (list) |entry| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, origin, " \t"), entry)) return true;
        },
    }
    return sameOrigin(origin, host orelse return false);
}

fn sameOrigin(origin_value: []const u8, host_value: []const u8) bool {
    const origin = std.mem.trim(u8, origin_value, " \t");
    const sep = std.mem.indexOf(u8, origin, "://") orelse return false;
    const scheme = origin[0..sep];
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https"))
        443
    else if (std.ascii.eqlIgnoreCase(scheme, "http"))
        80
    else
        return false;
    const o = split(origin[sep + 3 ..], default_port) orelse return false;
    const h = split(std.mem.trim(u8, host_value, " \t"), default_port) orelse return false;
    return o.port == h.port and std.ascii.eqlIgnoreCase(o.host, h.host);
}

const Authority = struct { host: []const u8, port: u16 };

/// `host`, `host:port`, `[v6]` or `[v6]:port`; nothing else (no path, no
/// user info).
fn split(text: []const u8, default_port: u16) ?Authority {
    if (text.len == 0) return null;
    if (std.mem.indexOfAny(u8, text, "/?#@ \t") != null) return null;
    var host = text;
    var port_text: ?[]const u8 = null;
    if (text[0] == '[') {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse return null;
        host = text[0 .. end + 1];
        const rest = text[end + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return null;
            port_text = rest[1..];
        }
    } else if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| {
        host = text[0..colon];
        port_text = text[colon + 1 ..];
    }
    if (host.len == 0) return null;
    const port = if (port_text) |p| std.fmt.parseInt(u16, p, 10) catch return null else default_port;
    return .{ .host = host, .port = port };
}

test "origin: the request's own host and port, in any case, with or without the default port" {
    try std.testing.expect(check("https://example.com", "example.com", .same_origin));
    try std.testing.expect(check("https://Example.COM", "example.com:443", .same_origin));
    try std.testing.expect(check("http://example.com:8080", "EXAMPLE.com:8080", .same_origin));
    try std.testing.expect(check("http://example.com", "example.com", .same_origin));
    try std.testing.expect(check("https://[::1]:8443", "[::1]:8443", .same_origin));
    try std.testing.expect(check("http://127.0.0.1:3000", "127.0.0.1:3000", .same_origin));

    try std.testing.expect(!check("https://evil.example", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com.evil.example", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com:8443", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com", "example.com:8443", .same_origin));
    try std.testing.expect(!check("null", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com", null, .same_origin));
    try std.testing.expect(!check("file://", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com/path", "example.com", .same_origin));
    try std.testing.expect(!check("https://user@example.com", "example.com", .same_origin));
    try std.testing.expect(!check("https://example.com:99999", "example.com", .same_origin));
}

test "origin: a list adds origins to the request's own, and any lets everything through" {
    const list: Origins = .{ .list = &.{ "https://app.example.com", "null" } };
    try std.testing.expect(check("https://app.example.com", "api.example.com", list));
    try std.testing.expect(check("HTTPS://APP.example.com", "api.example.com", list));
    try std.testing.expect(check("null", "api.example.com", list));
    try std.testing.expect(check("https://api.example.com", "api.example.com", list));
    try std.testing.expect(!check("https://evil.example", "api.example.com", list));
    try std.testing.expect(!check("https://app.example.com:444", "api.example.com", list));
    try std.testing.expect(check("https://evil.example", "api.example.com", .any));
}

test "fuzz: origin checks" {
    try @import("fuzz.zig").bytes(struct {
        fn check_(input: []const u8) !void {
            const cut = if (input.len > 0) input[0] % (input.len + 1) else 0;
            const origin = input[0..@min(cut, input.len)];
            const host = input[@min(cut, input.len)..];
            // Same origin is symmetric in what it compares: an origin built
            // from a host that splits is always allowed for it.
            _ = check(origin, host, .same_origin);
            if (split(host, 443)) |a| {
                var buf: [4200]u8 = undefined;
                const built = try std.fmt.bufPrint(&buf, "https://{s}:{d}", .{ a.host, a.port });
                try std.testing.expect(check(built, host, .same_origin));
            }
        }
    }.check_, &.{ "\x13https://example.comexample.com", "\x05null\x00[::1]:80", "\x00example.com:8443" });
}
