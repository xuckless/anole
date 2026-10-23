//! Endpoint parsing, the provider quirks and URL building (design-connectors.md S4).
const std = @import("std");
const sigv4 = @import("sigv4.zig");

pub const Provider = enum { auto, aws, r2, b2, supabase, minio, generic };
pub const Addressing = enum { auto, path, virtual_host };

pub const Error = error{ InvalidEndpoint, InvalidKey, OutOfMemory };

pub const Endpoint = struct {
    https: bool,
    /// Without the port; an IPv6 literal keeps its brackets.
    host: []const u8,
    port: u16,
    /// Without a trailing slash: "" or "/storage/v1/s3".
    base_path: []const u8,
    provider: Provider,

    /// Parses "https://host[:port][/base]". `provider == .auto` is detected
    /// from the host.
    pub fn parse(arena: std.mem.Allocator, text: []const u8, provider: Provider) Error!Endpoint {
        const scheme_end = std.mem.find(u8, text, "://") orelse return error.InvalidEndpoint;
        const scheme = text[0..scheme_end];
        const https = std.ascii.eqlIgnoreCase(scheme, "https");
        if (!https and !std.ascii.eqlIgnoreCase(scheme, "http")) return error.InvalidEndpoint;
        const rest = text[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash];
        if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.InvalidEndpoint;
        var host = authority;
        var port: u16 = if (https) 443 else 80;
        if (authority[0] == '[') {
            const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidEndpoint;
            host = authority[0 .. close + 1];
            if (authority.len > close + 1) {
                if (authority[close + 1] != ':') return error.InvalidEndpoint;
                port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return error.InvalidEndpoint;
            }
        } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
            host = authority[0..c];
            port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.InvalidEndpoint;
        }
        if (host.len == 0) return error.InvalidEndpoint;
        const base = std.mem.trimEnd(u8, rest[slash..], "/");
        const lower = try std.ascii.allocLowerString(arena, host);
        return .{
            .https = https,
            .host = lower,
            .port = port,
            .base_path = try arena.dupe(u8, base),
            .provider = if (provider == .auto) detect(lower) else provider,
        };
    }

    /// The provider an endpoint's host belongs to.
    pub fn detect(host: []const u8) Provider {
        if (std.mem.endsWith(u8, host, ".amazonaws.com") or std.mem.endsWith(u8, host, ".amazonaws.com.cn")) return .aws;
        if (std.mem.endsWith(u8, host, ".r2.cloudflarestorage.com")) return .r2;
        if (std.mem.endsWith(u8, host, ".backblazeb2.com")) return .b2;
        if (std.mem.endsWith(u8, host, ".supabase.co")) return .supabase;
        return .generic;
    }

    /// The endpoint AWS S3 has in `region`.
    pub fn aws(arena: std.mem.Allocator, region: []const u8) Error!Endpoint {
        const host = try std.fmt.allocPrint(arena, "s3.{s}.amazonaws.com", .{region});
        return .{ .https = true, .host = host, .port = 443, .base_path = "", .provider = .aws };
    }

    /// The region a provider needs when none is given.
    pub fn defaultRegion(self: Endpoint) []const u8 {
        return switch (self.provider) {
            .r2 => "auto",
            else => "us-east-1",
        };
    }

    /// Whether `bucket` can be a host name label: lowercase letters,
    /// digits, hyphens, no dots, 3 to 63 characters, not an IP address.
    pub fn dnsSafe(bucket: []const u8) bool {
        if (bucket.len < 3 or bucket.len > 63) return false;
        for (bucket, 0..) |ch, i| {
            const ok = std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-';
            if (!ok) return false;
            if (ch == '-' and (i == 0 or i == bucket.len - 1)) return false;
        }
        return true;
    }

    /// Virtual-host addressing for this bucket, per `addressing` and the
    /// provider: AWS uses it for DNS-safe buckets, everything else path style.
    pub fn useVirtualHost(self: Endpoint, addressing: Addressing, bucket: []const u8) bool {
        return switch (addressing) {
            .path => false,
            .virtual_host => true,
            .auto => self.provider == .aws and dnsSafe(bucket),
        };
    }
};

/// Where one request goes.
pub const Target = struct {
    /// The Host header (and what the signature covers): host, and :port
    /// when it is not the scheme's own.
    host: []const u8,
    /// The encoded path, as sent and as signed: "/bucket/key".
    uri: []const u8,
    /// scheme://host + uri, without a query.
    url: []const u8,
};

/// Keys are 1 to 1024 bytes of UTF-8.
pub fn validKey(key: []const u8) bool {
    return key.len >= 1 and key.len <= 1024 and std.unicode.utf8ValidateSlice(key);
}

/// Builds the target for `bucket` and `key` (an empty key: the bucket itself).
pub fn target(arena: std.mem.Allocator, ep: Endpoint, addressing: Addressing, bucket: []const u8, key: []const u8) Error!Target {
    return targetInner(arena, ep, addressing, bucket, key) catch error.OutOfMemory;
}

fn targetInner(arena: std.mem.Allocator, ep: Endpoint, addressing: Addressing, bucket: []const u8, key: []const u8) !Target {
    const virtual = ep.useVirtualHost(addressing, bucket);
    var host_buf: std.Io.Writer.Allocating = .init(arena);
    if (virtual) try host_buf.writer.print("{s}.", .{bucket});
    try host_buf.writer.writeAll(ep.host);
    const default_port: u16 = if (ep.https) 443 else 80;
    if (ep.port != default_port) try host_buf.writer.print(":{d}", .{ep.port});
    const host = host_buf.written();

    var uri: std.Io.Writer.Allocating = .init(arena);
    const w = &uri.writer;
    try w.writeAll(ep.base_path);
    if (!virtual) {
        try w.writeByte('/');
        try sigv4.uriEncode(w, bucket, false);
    }
    if (key.len > 0) {
        try w.writeByte('/');
        try sigv4.uriEncode(w, key, true);
    } else if (virtual and ep.base_path.len == 0) {
        try w.writeByte('/');
    } else if (!virtual) {
        try w.writeByte('/');
    }
    const path = uri.written();
    const url = try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ if (ep.https) "https" else "http", host, path });
    return .{ .host = host, .uri = path, .url = url };
}

const testing = std.testing;

test "endpoint: AWS virtual host for a DNS-safe bucket, path for one with dots" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ep = try Endpoint.aws(a.allocator(), "eu-west-1");
    const t1 = try target(a.allocator(), ep, .auto, "my-bucket", "dir/a b.txt");
    try testing.expectEqualStrings("my-bucket.s3.eu-west-1.amazonaws.com", t1.host);
    try testing.expectEqualStrings("/dir/a%20b.txt", t1.uri);
    try testing.expectEqualStrings("https://my-bucket.s3.eu-west-1.amazonaws.com/dir/a%20b.txt", t1.url);
    const t2 = try target(a.allocator(), ep, .auto, "my.bucket", "k");
    try testing.expectEqualStrings("s3.eu-west-1.amazonaws.com", t2.host);
    try testing.expectEqualStrings("/my.bucket/k", t2.uri);
    const t3 = try target(a.allocator(), ep, .auto, "my-bucket", "");
    try testing.expectEqualStrings("/", t3.uri);
}

test "endpoint: R2 is region auto and path style; Supabase keeps its base path; a port stays in the host" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const r2 = try Endpoint.parse(a.allocator(), "https://acct.r2.cloudflarestorage.com", .auto);
    try testing.expectEqual(Provider.r2, r2.provider);
    try testing.expectEqualStrings("auto", r2.defaultRegion());
    const t = try target(a.allocator(), r2, .auto, "uploads", "k");
    try testing.expectEqualStrings("/uploads/k", t.uri);

    const sb = try Endpoint.parse(a.allocator(), "https://ref.supabase.co/storage/v1/s3/", .auto);
    try testing.expectEqual(Provider.supabase, sb.provider);
    const t2 = try target(a.allocator(), sb, .auto, "avatars", "a.png");
    try testing.expectEqualStrings("/storage/v1/s3/avatars/a.png", t2.uri);
    try testing.expectEqualStrings("https://ref.supabase.co/storage/v1/s3/avatars/a.png", t2.url);

    const minio = try Endpoint.parse(a.allocator(), "http://127.0.0.1:9000", .auto);
    try testing.expectEqual(Provider.generic, minio.provider);
    const t3 = try target(a.allocator(), minio, .auto, "b", "k");
    try testing.expectEqualStrings("127.0.0.1:9000", t3.host);
    try testing.expectEqualStrings("http://127.0.0.1:9000/b/k", t3.url);
    const t4 = try target(a.allocator(), minio, .virtual_host, "bucket", "k");
    try testing.expectEqualStrings("bucket.127.0.0.1:9000", t4.host);
    try testing.expectError(error.InvalidEndpoint, Endpoint.parse(a.allocator(), "ftp://x", .auto));
    try testing.expectError(error.InvalidEndpoint, Endpoint.parse(a.allocator(), "http://u:p@x", .auto));
}

test "endpoint: keys are 1 to 1024 bytes of UTF-8" {
    try testing.expect(validKey("a"));
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("\xff"));
    const long: [1025]u8 = @splat('a');
    try testing.expect(!validKey(&long));
}
