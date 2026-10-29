//! Connection URLs and the environment: `postgres://`, `mongodb://`,
//! `redis://`, `sqlite:`, read from `DATABASE_URL` and friends, and
//! printed without their passwords.
const std = @import("std");
const env_mod = @import("../env.zig");

/// A connection URL, parsed: `scheme://user:password@host:port,host2/path?key=value`.
/// Several hosts (MongoDB's seed list, libpq's fallbacks), IPv6 in
/// brackets, a host that is a Unix socket directory percent-encoded
/// (`postgres://%2Fvar%2Frun%2Fpostgresql/app`), and the authority-less
/// form (`sqlite:data/app.db`, `sqlite::memory:`).
///
/// Printed with `{f}`, the password and any parameter whose name contains
/// "password" come out as `***`: log a URL that way, never as text.
pub const Url = struct {
    /// As written ("postgres", "postgresql", "mongodb", "rediss"...).
    scheme: []const u8,
    /// Percent-decoded.
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// Empty when the URL names none (`postgres:///app`): the connector's
    /// default.
    hosts: []const Host = &.{},
    /// Percent-decoded, with its leading "/" when it follows an authority:
    /// "/app" in `postgres://h/app`, "data/app.db" in `sqlite:data/app.db`.
    /// See `database`.
    path: []const u8 = "",
    /// Query parameters in order, percent-decoded.
    params: []const Param = &.{},
    /// The text it was parsed from.
    raw: []const u8,

    /// One host of `hosts`.
    pub const Host = struct {
        /// Percent-decoded, without IPv6 brackets.
        name: []const u8,
        /// Null when the URL gives none: the connector's default port.
        port: ?u16 = null,
    };

    /// One query parameter of `params`.
    pub const Param = struct { name: []const u8, value: []const u8 };

    /// What `parse` fails with: text that is no URL (no scheme, a bad
    /// percent escape, an unclosed IPv6 bracket), or a port that is not a
    /// number up to 65535.
    pub const ParseError = error{ InvalidUrl, InvalidPort, OutOfMemory };

    /// Parses `text`; the result points into `text` and `arena`.
    pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Url {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidUrl;
        const scheme = text[0..colon];
        if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return error.InvalidUrl;
        for (scheme) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '-' or ch == '.')) return error.InvalidUrl;
        var url: Url = .{ .scheme = scheme, .raw = text };

        var rest = text[colon + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];
        const query_at = std.mem.indexOfScalar(u8, rest, '?');
        const query = if (query_at) |i| rest[i + 1 ..] else "";
        rest = if (query_at) |i| rest[0..i] else rest;

        if (std.mem.startsWith(u8, rest, "//")) {
            rest = rest[2..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const authority = rest[0..end];
            rest = rest[end..];
            var hosts_text = authority;
            // The last '@': a password may hold one unencoded.
            if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
                const userinfo = authority[0..at];
                hosts_text = authority[at + 1 ..];
                if (std.mem.indexOfScalar(u8, userinfo, ':')) |c| {
                    url.username = try decode(arena, userinfo[0..c]);
                    url.password = try decode(arena, userinfo[c + 1 ..]);
                } else {
                    url.username = try decode(arena, userinfo);
                }
            }
            url.hosts = try parseHosts(arena, hosts_text);
        }
        url.path = try decode(arena, rest);

        var params: std.ArrayList(Param) = .empty;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=');
            try params.append(arena, .{
                .name = try decode(arena, if (eq) |i| pair[0..i] else pair),
                .value = try decode(arena, if (eq) |i| pair[i + 1 ..] else ""),
            });
        }
        url.params = params.items;
        return url;
    }

    fn parseHosts(arena: std.mem.Allocator, text: []const u8) ParseError![]const Host {
        if (text.len == 0) return &.{};
        var hosts: std.ArrayList(Host) = .empty;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |item| {
            var name = item;
            var port_text: ?[]const u8 = null;
            if (std.mem.startsWith(u8, item, "[")) {
                const close = std.mem.indexOfScalar(u8, item, ']') orelse return error.InvalidUrl;
                name = item[1..close];
                const after = item[close + 1 ..];
                if (after.len > 0) {
                    if (after[0] != ':') return error.InvalidUrl;
                    port_text = after[1..];
                }
            } else if (std.mem.lastIndexOfScalar(u8, item, ':')) |c| {
                name = item[0..c];
                port_text = item[c + 1 ..];
            }
            var host: Host = .{ .name = try decode(arena, name) };
            if (port_text) |p| {
                if (p.len > 0) host.port = std.fmt.parseInt(u16, p, 10) catch return error.InvalidPort;
            }
            try hosts.append(arena, host);
        }
        return hosts.items;
    }

    /// The value of the first parameter called `name`, or null.
    pub fn param(self: Url, name: []const u8) ?[]const u8 {
        for (self.params) |p| if (std.mem.eql(u8, p.name, name)) return p.value;
        return null;
    }

    /// The path without the "/" an authority puts before it: the database
    /// for PostgreSQL and MongoDB ("app"), the file for SQLite.
    pub fn database(self: Url) []const u8 {
        return if (std.mem.startsWith(u8, self.path, "/")) self.path[1..] else self.path;
    }

    /// `raw`, with the password and password parameters as `***`.
    pub fn format(self: Url, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return redacted(self.raw).format(w);
    }
};

/// `text` (a URL, parsable or not) for a log line: printed with `{f}`,
/// its password and any parameter whose name contains "password" come
/// out as `***`.
pub fn redacted(text: []const u8) Redacted {
    return .{ .text = text };
}

/// What `redacted` returns: print it with `{f}`.
pub const Redacted = struct {
    text: []const u8,

    /// Writes `text` with its password and password parameters as `***`.
    pub fn format(self: Redacted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var text = self.text;
        // The userinfo's password: from the first ':' after "//" to the
        // last '@' of the whole text. A password with an unencoded '/', '?'
        // or '@' (a URL that does not parse, logged as such) has no
        // reliable end, so a query holding an '@' is hidden too: more than
        // the password at worst, never less.
        if (std.mem.indexOf(u8, text, "//")) |slashes| {
            const start = slashes + 2;
            if (std.mem.lastIndexOfScalar(u8, text[start..], '@')) |r| {
                const at = start + r;
                if (std.mem.indexOfScalarPos(u8, text[0..at], start, ':')) |c| {
                    try w.writeAll(text[0 .. c + 1]);
                    try w.writeAll("***");
                    text = text[at..];
                }
            }
        }
        var query: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, text, '?')) |i| {
            query = text[i + 1 ..];
            text = text[0..i];
        }
        try w.writeAll(text);
        const q = query orelse return;
        try w.writeByte('?');
        var it = std.mem.splitScalar(u8, q, '&');
        var first = true;
        while (it.next()) |pair| {
            if (!first) try w.writeByte('&');
            first = false;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                try w.writeAll(pair);
                continue;
            };
            if (containsIgnoreCase(pair[0..eq], "password")) {
                try w.print("{s}=***", .{pair[0..eq]});
            } else try w.writeAll(pair);
        }
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Percent-decodes `text` ("+" stays "+", as in libpq and MongoDB URIs);
/// returns `text` itself when there is nothing to decode.
fn decode(arena: std.mem.Allocator, text: []const u8) error{ InvalidUrl, OutOfMemory }![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len) return error.InvalidUrl;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.InvalidUrl;
            i += 3;
        } else {
            out[n] = text[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// The environment variable `name` (`DATABASE_URL`, `PGHOST`...), or null
/// when unset. From `environ` (`std.process.Init.Minimal.environ`, what
/// `ServerOptions.process` carries) when given, else from the C library's
/// environment, which Anole always links. On Windows always the C
/// library's: `Environ` holds UTF-16 there, with nothing to slice.
pub fn env(environ: ?std.process.Environ, name: []const u8) ?[]const u8 {
    if (realEnv(environ, name)) |v| return v;
    // The `.env` files read at startup (development), below the real environment.
    if (env_mod.loaded()) |files| return files.get(name);
    return null;
}

/// `env` without the `.env` entries: the process environment only.
pub fn realEnv(environ: ?std.process.Environ, name: []const u8) ?[]const u8 {
    if (comptime @import("builtin").os.tag != .windows) if (environ) |e| return e.getPosix(name);
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.c.getenv(buf[0..name.len :0]) orelse return null;
    return std.mem.span(value);
}

const testing = std.testing;

test "Url: PostgreSQL, MongoDB, Redis and SQLite URLs parse into hosts, credentials, database and parameters; malformed ones are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pg = try Url.parse(arena, "postgres://app:s%40cr3t@db.internal:6432/main?sslmode=verify-full&application_name=api");
    try testing.expectEqualStrings("postgres", pg.scheme);
    try testing.expectEqualStrings("app", pg.username.?);
    try testing.expectEqualStrings("s@cr3t", pg.password.?);
    try testing.expectEqual(@as(usize, 1), pg.hosts.len);
    try testing.expectEqualStrings("db.internal", pg.hosts[0].name);
    try testing.expectEqual(@as(?u16, 6432), pg.hosts[0].port);
    try testing.expectEqualStrings("main", pg.database());
    try testing.expectEqualStrings("verify-full", pg.param("sslmode").?);
    try testing.expectEqualStrings("api", pg.param("application_name").?);
    try testing.expect(pg.param("nope") == null);

    const sock = try Url.parse(arena, "postgresql://%2Fvar%2Frun%2Fpostgresql/app");
    try testing.expectEqualStrings("/var/run/postgresql", sock.hosts[0].name);
    try testing.expect(sock.hosts[0].port == null);
    try testing.expect(sock.username == null);

    const bare = try Url.parse(arena, "postgres:///app");
    try testing.expectEqual(@as(usize, 0), bare.hosts.len);
    try testing.expectEqualStrings("app", bare.database());

    const mongo = try Url.parse(arena, "mongodb://u:p@a.example:27017,[::1]:27018,c.example/?replicaSet=rs0&tls=true");
    try testing.expectEqual(@as(usize, 3), mongo.hosts.len);
    try testing.expectEqualStrings("::1", mongo.hosts[1].name);
    try testing.expectEqual(@as(?u16, 27018), mongo.hosts[1].port);
    try testing.expect(mongo.hosts[2].port == null);
    try testing.expectEqualStrings("", mongo.database());
    try testing.expectEqualStrings("rs0", mongo.param("replicaSet").?);

    const redis = try Url.parse(arena, "rediss://:only-a-password@cache:6380/2");
    try testing.expectEqualStrings("", redis.username.?);
    try testing.expectEqualStrings("only-a-password", redis.password.?);
    try testing.expectEqualStrings("2", redis.database());

    const file = try Url.parse(arena, "sqlite:data/app.db?mode=rwc");
    try testing.expectEqual(@as(usize, 0), file.hosts.len);
    try testing.expectEqualStrings("data/app.db", file.database());
    try testing.expectEqualStrings("rwc", file.param("mode").?);
    try testing.expectEqualStrings(":memory:", (try Url.parse(arena, "sqlite::memory:")).database());
    try testing.expectEqualStrings("/tmp/x.db", (try Url.parse(arena, "sqlite:///tmp/x.db")).path);

    for ([_][]const u8{ "", "no-scheme", "://x", "postgres://h:99999/db", "postgres://h:port/db", "postgres://[::1/db", "postgres://h/%zz" }) |bad| {
        if (Url.parse(arena, bad)) |_| return error.TestUnexpectedResult else |_| {}
    }
}

test "redacted: no password in what is printed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "postgres://app:s3cret@db:5432/main?sslmode=require", "postgres://app:***@db:5432/main?sslmode=require" },
        .{ "postgres://app:p@ss@word@db/main", "postgres://app:***@db/main" },
        .{ "postgres://app@db/main?password=s3cret&sslpassword=x&x=1", "postgres://app@db/main?password=***&sslpassword=***&x=1" },
        .{ "mongodb://db1,db2/?tlsCertificateKeyFilePassword=k", "mongodb://db1,db2/?tlsCertificateKeyFilePassword=***" },
        // a '/' or '?' in the password: the URL does not parse, and the
        // password stays hidden all the same
        .{ "postgres://app:pa/ss@db/main", "postgres://app:***@db/main" },
        .{ "postgres://app:pa?ss@db/main?sslmode=require", "postgres://app:***@db/main?sslmode=require" },
        .{ "postgres://app:pa/s?s@db/main?x=1", "postgres://app:***@db/main?x=1" },
        .{ "postgres://app:pa/ss@db/main?email=a@b", "postgres://app:***@b" },
        .{ "postgres://app:a@b?c@db/main", "postgres://app:***@db/main" },
        .{ "sqlite:data/app.db", "sqlite:data/app.db" },
        .{ "not a url at all", "not a url at all" },
    }) |case| {
        try testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buf, "{f}", .{redacted(case[0])}));
    }
    // Even when the password holds a '?', and the query an '@'.
    try testing.expect(std.mem.indexOf(u8, try std.fmt.bufPrint(&buf, "{f}", .{redacted("postgres://app:hunter2?x@db/main?email=a@b")}), "hunter2") == null);
    const url = try Url.parse(arena_state.allocator(), "redis://default:hunter2@cache:6379/0");
    try testing.expectEqualStrings("redis://default:***@cache:6379/0", try std.fmt.bufPrint(&buf, "{f}", .{url}));
}

test "env: from the C environment, or from an Environ" {
    try testing.expect(env(null, "ANOLE_SURELY_UNSET_VARIABLE") == null);
    try testing.expect(env(null, "PATH") != null);
    // Windows reads the C library's environment whatever it is given.
    if (comptime @import("builtin").os.tag != .windows) try testing.expect(env(.empty, "PATH") == null);
}

test "fuzz: redacted never shows the password" {
    try @import("../fuzz.zig").bytes(struct {
        fn check(input: []const u8) !void {
            // The input is the password, whatever bytes it holds; a short one
            // may also be a piece of the rest of the URL.
            if (input.len < 6) return;
            var text_buf: [512]u8 = undefined;
            var out_buf: [1024]u8 = undefined;
            for ([_][2][]const u8{
                .{ "postgres://app:", "@db.example/main?sslmode=require" },
                .{ "mongodb://app:", "@h1:27017,h2/admin?authSource=admin&email=a@b" },
                .{ "rediss://default:", "@cache:6380/0" },
            }) |parts| {
                const text = std.fmt.bufPrint(&text_buf, "{s}{s}{s}", .{ parts[0], input, parts[1] }) catch return;
                const out = std.fmt.bufPrint(&out_buf, "{f}", .{redacted(text)}) catch return;
                const scaffold = std.fmt.bufPrint(out_buf[out.len..], "{s}***{s}", .{ parts[0], parts[1] }) catch return;
                if (std.mem.indexOf(u8, scaffold, input) != null) continue;
                if (std.mem.indexOf(u8, out, input) != null) return error.PasswordShown;
            }
        }
    }.check, &.{ "hunter2", "pa/ss?x", "a@b?c", "p@ss/w?rd", "x?y=z&password=1" });
}
