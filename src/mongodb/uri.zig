//! The connection string (specifications: connection-string,
//! uri-options, auth): `mongodb://user:pass@host:port,host2/db?key=value`.
//!
//! `parse` follows the specs' rules: a malformed string or a forbidden
//! combination of options is an error (`error.InvalidUri`, with the reason
//! in a `Diagnostic`); an option Anole does not know, or a value of the
//! wrong type, is a warning and is left out. `credential` derives what
//! authenticates the connections, with each mechanism's defaults and
//! rules. Both are pure: no I/O, everything in the arena given.
const std = @import("std");

pub const Scheme = enum { mongodb, mongodb_srv };

pub const Host = struct {
    /// Percent-decoded; an IP literal without its brackets; a Unix
    /// socket's path.
    name: []const u8,
    /// Null when the string names none (27017 for TCP).
    port: ?u16 = null,
    kind: Kind,

    pub const Kind = enum { hostname, ipv4, ip_literal, unix };
};

pub const Pair = struct { key: []const u8, value: []const u8 };

/// An option's value, typed as uri-options.md says.
pub const Value = union(enum) {
    boolean: bool,
    int: i64,
    string: []const u8,
    /// `compressors`.
    list: []const []const u8,
    /// `authMechanismProperties`.
    pairs: []const Pair,
    /// `readPreferenceTags`, one tag set per occurrence.
    tag_sets: []const []const Pair,
};

pub const Option = struct {
    /// The spec's name ("serverSelectionTimeoutMS"); keys match it
    /// whatever their case.
    name: []const u8,
    value: Value,
};

pub const ConnectionString = struct {
    scheme: Scheme,
    hosts: []const Host,
    /// The string had userinfo (an "@"), which asks for authentication
    /// even when the name is empty.
    userinfo: bool = false,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// The path: the default database, and the authentication source
    /// when `authSource` is not given.
    database: ?[]const u8 = null,
    options: []const Option = &.{},
    /// Options left out (unknown, or a value of the wrong type), and
    /// deprecated forms, for the log.
    warnings: []const []const u8 = &.{},

    /// The option called `name` (any case), or null.
    pub fn get(self: ConnectionString, name: []const u8) ?Value {
        for (self.options) |o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o.value;
        return null;
    }

    pub fn boolean(self: ConnectionString, name: []const u8) ?bool {
        return if (self.get(name)) |v| v.boolean else null;
    }

    pub fn int(self: ConnectionString, name: []const u8) ?i64 {
        return if (self.get(name)) |v| switch (v) {
            .int => |n| n,
            else => null,
        } else null;
    }

    pub fn string(self: ConnectionString, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;
    }
};

/// Why `parse` or `credential` refused a string.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{ InvalidUri, OutOfMemory };

const OptionKind = enum { boolean, int, string, list, pairs, tags, w };

const Spec = struct {
    name: []const u8,
    kind: OptionKind,
    min: i64 = 0,
    max: i64 = std.math.maxInt(i32),
    /// For strings: the values allowed (any when empty).
    choices: []const []const u8 = &.{},
};

/// Every option of uri-options.md (plus `waitQueueTimeoutMS`), whether or
/// not the client acts on it: parsing them all is what keeps an option
/// meant for another driver from being taken for a typo, and a forbidden
/// combination from passing.
const specs = [_]Spec{
    .{ .name = "appname", .kind = .string },
    .{ .name = "authMechanism", .kind = .string },
    .{ .name = "authMechanismProperties", .kind = .pairs },
    .{ .name = "authSource", .kind = .string },
    .{ .name = "compressors", .kind = .list },
    .{ .name = "connectTimeoutMS", .kind = .int },
    .{ .name = "directConnection", .kind = .boolean },
    .{ .name = "enableOverloadRetargeting", .kind = .boolean },
    .{ .name = "heartbeatFrequencyMS", .kind = .int, .min = 500 },
    .{ .name = "journal", .kind = .boolean },
    .{ .name = "loadBalanced", .kind = .boolean },
    .{ .name = "localThresholdMS", .kind = .int },
    .{ .name = "maxAdaptiveRetries", .kind = .int },
    .{ .name = "maxConnecting", .kind = .int, .min = 1 },
    .{ .name = "maxIdleTimeMS", .kind = .int },
    .{ .name = "maxPoolSize", .kind = .int },
    .{ .name = "maxStalenessSeconds", .kind = .int, .min = -1 },
    .{ .name = "minPoolSize", .kind = .int },
    .{ .name = "proxyHost", .kind = .string },
    .{ .name = "proxyPort", .kind = .int, .max = 65535 },
    .{ .name = "proxyUsername", .kind = .string },
    .{ .name = "proxyPassword", .kind = .string },
    .{ .name = "readConcernLevel", .kind = .string },
    .{ .name = "readPreference", .kind = .string, .choices = &.{ "primary", "primaryPreferred", "secondary", "secondaryPreferred", "nearest" } },
    .{ .name = "readPreferenceTags", .kind = .tags },
    .{ .name = "replicaSet", .kind = .string },
    .{ .name = "retryReads", .kind = .boolean },
    .{ .name = "retryWrites", .kind = .boolean },
    .{ .name = "serverMonitoringMode", .kind = .string, .choices = &.{ "stream", "poll", "auto" } },
    .{ .name = "serverSelectionTimeoutMS", .kind = .int, .min = 1 },
    .{ .name = "serverSelectionTryOnce", .kind = .boolean },
    .{ .name = "socketTimeoutMS", .kind = .int },
    .{ .name = "srvAllowedHostsSuffix", .kind = .string },
    .{ .name = "srvMaxHosts", .kind = .int },
    .{ .name = "srvServiceName", .kind = .string },
    .{ .name = "timeoutMS", .kind = .int },
    .{ .name = "tls", .kind = .boolean },
    .{ .name = "tlsAllowInvalidCertificates", .kind = .boolean },
    .{ .name = "tlsAllowInvalidHostnames", .kind = .boolean },
    .{ .name = "tlsCAFile", .kind = .string },
    .{ .name = "tlsCertificateKeyFile", .kind = .string },
    .{ .name = "tlsCertificateKeyFilePassword", .kind = .string },
    .{ .name = "tlsDisableCertificateRevocationCheck", .kind = .boolean },
    .{ .name = "tlsDisableOCSPEndpointCheck", .kind = .boolean },
    .{ .name = "tlsInsecure", .kind = .boolean },
    .{ .name = "w", .kind = .w },
    .{ .name = "waitQueueTimeoutMS", .kind = .int, .min = 1 },
    .{ .name = "wTimeoutMS", .kind = .int, .max = std.math.maxInt(i64) },
    .{ .name = "zlibCompressionLevel", .kind = .int, .min = -1, .max = 9 },
};

fn specFor(key: []const u8) ?Spec {
    for (specs) |s| if (std.ascii.eqlIgnoreCase(s.name, key)) return s;
    return null;
}

/// TLS options no two of which may appear together (uri-options.md,
/// "Conflicting TLS options").
const tls_conflicts = [_][2][]const u8{
    .{ "tlsInsecure", "tlsAllowInvalidCertificates" },
    .{ "tlsInsecure", "tlsAllowInvalidHostnames" },
    .{ "tlsInsecure", "tlsDisableOCSPEndpointCheck" },
    .{ "tlsInsecure", "tlsDisableCertificateRevocationCheck" },
    .{ "tlsAllowInvalidCertificates", "tlsDisableOCSPEndpointCheck" },
    .{ "tlsAllowInvalidCertificates", "tlsDisableCertificateRevocationCheck" },
    .{ "tlsDisableOCSPEndpointCheck", "tlsDisableCertificateRevocationCheck" },
};

/// Parses `text`. The result points into `text` and `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) Error!ConnectionString {
    var p: Parser = .{ .arena = arena, .diag = diag };
    return p.run(text);
}

const Parser = struct {
    arena: std.mem.Allocator,
    diag: ?*Diagnostic,
    warnings: std.ArrayList([]const u8) = .empty,

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (p.diag) |d| d.message = std.fmt.allocPrint(p.arena, fmt, args) catch "invalid connection string";
        return error.InvalidUri;
    }

    fn warn(p: *Parser, comptime fmt: []const u8, args: anytype) Error!void {
        try p.warnings.append(p.arena, try std.fmt.allocPrint(p.arena, fmt, args));
    }

    fn run(p: *Parser, text: []const u8) Error!ConnectionString {
        var cs: ConnectionString = .{ .scheme = .mongodb, .hosts = &.{} };
        var rest: []const u8 = undefined;
        if (std.mem.startsWith(u8, text, "mongodb://")) {
            rest = text["mongodb://".len..];
        } else if (std.mem.startsWith(u8, text, "mongodb+srv://")) {
            cs.scheme = .mongodb_srv;
            rest = text["mongodb+srv://".len..];
        } else return p.fail("a connection string starts with mongodb:// or mongodb+srv://", .{});

        // Hosts end at the first "/", or at "?" when there is no path.
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const question = std.mem.indexOfScalar(u8, rest, '?');
        var authority = rest;
        var path: []const u8 = "";
        var query: []const u8 = "";
        if (slash != null and (question == null or slash.? < question.?)) {
            authority = rest[0..slash.?];
            const tail = rest[slash.? + 1 ..];
            if (std.mem.indexOfScalar(u8, tail, '?')) |q| {
                path = tail[0..q];
                query = tail[q + 1 ..];
            } else path = tail;
        } else if (question) |q| {
            authority = rest[0..q];
            query = rest[q + 1 ..];
        }

        var hosts_text = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
            const info = authority[0..at];
            hosts_text = authority[at + 1 ..];
            if (std.mem.indexOfScalar(u8, info, '@') != null) return p.fail("an '@' in the username or password must be percent-encoded", .{});
            cs.userinfo = true;
            if (std.mem.indexOfScalar(u8, info, ':')) |c| {
                if (std.mem.indexOfScalarPos(u8, info, c + 1, ':') != null) return p.fail("a ':' in the password must be percent-encoded", .{});
                cs.username = try p.decode(info[0..c], "the username");
                cs.password = try p.decode(info[c + 1 ..], "the password");
            } else cs.username = try p.decode(info, "the username");
        }
        cs.hosts = try p.parseHosts(hosts_text);

        if (path.len > 0) {
            const db = try p.decode(path, "the database");
            for (db) |ch| if (std.mem.indexOfScalar(u8, "/\\ \"$", ch) != null)
                return p.fail("the database name holds a character a database name cannot (/, \\, space, \" or $)", .{});
            cs.database = db;
        }

        cs.options = try p.parseOptions(query, &cs);
        cs.warnings = p.warnings.items;
        return cs;
    }

    fn decode(p: *Parser, text: []const u8, what: []const u8) Error![]const u8 {
        return percentDecode(p.arena, text) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidEncoding => p.fail("{s} has a '%' that is not percent-encoding", .{what}),
        };
    }

    fn parseHosts(p: *Parser, text: []const u8) Error![]const Host {
        if (text.len == 0) return p.fail("no host", .{});
        var hosts: std.ArrayList(Host) = .empty;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |item| {
            if (item.len == 0) return p.fail("an empty host in the host list", .{});
            var name_text = item;
            var port_text: ?[]const u8 = null;
            var kind: Host.Kind = .hostname;
            if (item[0] == '[') {
                const close = std.mem.indexOfScalar(u8, item, ']') orelse return p.fail("an IP literal without its ']'", .{});
                name_text = item[1..close];
                kind = .ip_literal;
                const after = item[close + 1 ..];
                if (after.len > 0) {
                    if (after[0] != ':') return p.fail("an IP literal not followed by :port", .{});
                    port_text = after[1..];
                }
            } else if (std.mem.indexOfScalar(u8, item, ':')) |c| {
                if (std.mem.indexOfScalarPos(u8, item, c + 1, ':') != null)
                    return p.fail("a host with more than one ':' (an IPv6 address goes in brackets, [::1]:27017, and a ':' or '/' in the password must be percent-encoded)", .{});
                name_text = item[0..c];
                port_text = item[c + 1 ..];
            }
            const name = try p.decode(name_text, "a host");
            if (name.len == 0) return p.fail("an empty host name", .{});
            if (kind == .hostname) {
                if (std.mem.indexOfScalar(u8, name, '/') != null) {
                    if (!std.mem.endsWith(u8, name, ".sock")) return p.fail("a host with a '/' that is not a Unix socket path ending in .sock (a '/' in the password must be percent-encoded)", .{});
                    kind = .unix;
                } else if (isIpv4(name)) kind = .ipv4;
            }
            var host: Host = .{ .name = name, .kind = kind };
            if (port_text) |pt| {
                const n = std.fmt.parseInt(u32, pt, 10) catch return p.fail("a port that is not a number (a '/', '?' or ':' in the password must be percent-encoded)", .{});
                if (n == 0 or n > 65535 or pt[0] == '+') return p.fail("a port outside 1-65535", .{});
                host.port = @intCast(n);
            }
            try hosts.append(p.arena, host);
        }
        return hosts.items;
    }

    fn parseOptions(p: *Parser, query: []const u8, cs: *const ConnectionString) Error![]const Option {
        var options: std.ArrayList(Option) = .empty;
        // Which options appeared at all, valid values or not: the
        // conflict rules go by presence.
        var seen: std.ArrayList([]const u8) = .empty;
        var tls_values: [2]?bool = .{ null, null };
        var deprecated_wtimeout: ?i64 = null;
        var tag_sets: std.ArrayList([]const Pair) = .empty;

        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return p.fail("an option with no value (no '=')", .{});
            const key = try p.decode(pair[0..eq], "an option name");
            const value = try p.decode(pair[eq + 1 ..], "an option value");

            if (std.ascii.eqlIgnoreCase(key, "wtimeout")) {
                try p.warn("wtimeout is deprecated: use wTimeoutMS", .{});
                deprecated_wtimeout = std.fmt.parseInt(i64, value, 10) catch null;
                continue;
            }
            const is_ssl = std.ascii.eqlIgnoreCase(key, "ssl");
            const spec = if (is_ssl) specFor("tls").? else specFor(key) orelse {
                try p.warn("unsupported option \"{s}\" left out", .{key});
                continue;
            };
            for (seen.items) |s| if (std.ascii.eqlIgnoreCase(s, key)) {
                if (std.mem.startsWith(u8, spec.name, "proxy")) return p.fail("{s} appears twice", .{spec.name});
                if (spec.kind != .tags and !std.mem.eql(u8, spec.name, "tls")) try p.warn("{s} appears twice; the last one counts", .{spec.name});
                break;
            };
            try seen.append(p.arena, if (is_ssl) "ssl" else spec.name);

            if (std.ascii.eqlIgnoreCase(spec.name, "authSource") and value.len == 0) return p.fail("authSource is empty", .{});
            const typed = try p.typedValue(spec, value) orelse continue;
            if (spec.kind == .tags) {
                try tag_sets.append(p.arena, typed.pairs);
                continue;
            }
            if (std.mem.eql(u8, spec.name, "tls")) {
                const slot = &tls_values[@intFromBool(is_ssl)];
                if (slot.*) |prev| if (prev != typed.boolean) return p.fail("tls (or ssl) is given both true and false", .{});
                slot.* = typed.boolean;
            }
            try put(p.arena, &options, spec.name, typed);
        }
        if (tls_values[0] != null and tls_values[1] != null and tls_values[0].? != tls_values[1].?)
            return p.fail("tls and ssl disagree", .{});
        if (tag_sets.items.len > 0) try put(p.arena, &options, "readPreferenceTags", .{ .tag_sets = tag_sets.items });
        if (deprecated_wtimeout) |v| {
            if (findOption(options.items, "wTimeoutMS") == null) {
                try put(p.arena, &options, "wTimeoutMS", .{ .int = v });
            } else try p.warn("wtimeout ignored: wTimeoutMS is given", .{});
        }

        const has = struct {
            fn f(list: []const []const u8, name: []const u8) bool {
                for (list) |s| if (std.ascii.eqlIgnoreCase(s, name)) return true;
                return false;
            }
        }.f;
        for (tls_conflicts) |pair| {
            if (has(seen.items, pair[0]) and has(seen.items, pair[1])) return p.fail("{s} and {s} cannot be used together", .{ pair[0], pair[1] });
        }
        const direct = if (findOption(options.items, "directConnection")) |v| v.boolean else false;
        const balanced = if (findOption(options.items, "loadBalanced")) |v| v.boolean else false;
        const replica_set = findOption(options.items, "replicaSet") != null;
        if (direct and cs.hosts.len > 1) return p.fail("directConnection=true with several hosts", .{});
        if (direct and cs.scheme == .mongodb_srv) return p.fail("directConnection=true with mongodb+srv://", .{});
        if (balanced and cs.hosts.len > 1) return p.fail("loadBalanced=true with several hosts", .{});
        if (balanced and direct) return p.fail("loadBalanced=true with directConnection=true", .{});
        if (balanced and replica_set) return p.fail("loadBalanced=true with replicaSet", .{});
        for ([_][]const u8{ "srvServiceName", "srvMaxHosts", "srvAllowedHostsSuffix" }) |name| {
            if (has(seen.items, name) and cs.scheme != .mongodb_srv) return p.fail("{s} needs mongodb+srv://", .{name});
        }
        if (cs.scheme == .mongodb_srv) {
            if (cs.hosts.len != 1) return p.fail("mongodb+srv:// takes exactly one host", .{});
            if (cs.hosts[0].port != null) return p.fail("mongodb+srv:// takes no port", .{});
            if (cs.hosts[0].kind == .unix) return p.fail("mongodb+srv:// takes a host name", .{});
            if (findOption(options.items, "srvMaxHosts")) |v| if (v.int > 0) {
                if (replica_set) return p.fail("srvMaxHosts with replicaSet", .{});
                if (balanced) return p.fail("srvMaxHosts with loadBalanced=true", .{});
            };
        }
        if (!has(seen.items, "proxyHost")) {
            for ([_][]const u8{ "proxyPort", "proxyUsername", "proxyPassword" }) |name| {
                if (has(seen.items, name)) return p.fail("{s} without proxyHost", .{name});
            }
        }
        if (has(seen.items, "proxyUsername") != has(seen.items, "proxyPassword")) return p.fail("proxyUsername and proxyPassword go together", .{});
        return options.items;
    }

    /// `value` as `spec` types it; null, with a warning, when it does not fit.
    fn typedValue(p: *Parser, spec: Spec, value: []const u8) Error!?Value {
        switch (spec.kind) {
            .boolean => {
                if (value.len == 0) return p.dropped(spec, value);
                if (std.mem.eql(u8, value, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, value, "false")) return .{ .boolean = false };
                for ([_][]const u8{ "1", "yes", "y", "t" }) |s| if (std.mem.eql(u8, value, s)) {
                    try p.warn("deprecated boolean \"{s}\" for {s}: use true", .{ value, spec.name });
                    return .{ .boolean = true };
                };
                for ([_][]const u8{ "0", "-1", "no", "n", "f" }) |s| if (std.mem.eql(u8, value, s)) {
                    try p.warn("deprecated boolean \"{s}\" for {s}: use false", .{ value, spec.name });
                    return .{ .boolean = false };
                };
                return p.dropped(spec, value);
            },
            .int => {
                const n = std.fmt.parseInt(i64, value, 10) catch return p.dropped(spec, value);
                if (n < spec.min or n > spec.max) return p.dropped(spec, value);
                return .{ .int = n };
            },
            .w => {
                if (value.len == 0) return p.dropped(spec, value);
                if (std.fmt.parseInt(i64, value, 10)) |n| {
                    if (n < 0) return p.dropped(spec, value);
                    return .{ .int = n };
                } else |_| return .{ .string = value };
            },
            .string => {
                if (spec.choices.len > 0) {
                    for (spec.choices) |c| if (std.mem.eql(u8, c, value)) return .{ .string = value };
                    return p.dropped(spec, value);
                }
                return .{ .string = value };
            },
            .list => {
                var items: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |item| {
                    if (std.mem.eql(u8, spec.name, "compressors") and !(std.mem.eql(u8, item, "zlib") or
                        std.mem.eql(u8, item, "zstd") or std.mem.eql(u8, item, "snappy")))
                    {
                        try p.warn("unknown compressor \"{s}\" left out", .{item});
                        continue;
                    }
                    try items.append(p.arena, item);
                }
                return .{ .list = items.items };
            },
            .pairs, .tags => {
                var pairs: std.ArrayList(Pair) = .empty;
                if (value.len > 0) {
                    var it = std.mem.splitScalar(u8, value, ',');
                    while (it.next()) |item| {
                        const c = std.mem.indexOfScalar(u8, item, ':') orelse {
                            try p.warn("\"{s}\" in {s} is not key:value", .{ item, spec.name });
                            if (spec.kind == .tags) return null;
                            continue;
                        };
                        try pairs.append(p.arena, .{ .key = item[0..c], .value = item[c + 1 ..] });
                    }
                }
                return .{ .pairs = pairs.items };
            },
        }
    }

    fn dropped(p: *Parser, spec: Spec, value: []const u8) Error!?Value {
        try p.warn("\"{s}\" is not a valid {s}; left out", .{ value, spec.name });
        return null;
    }
};

fn findOption(options: []const Option, name: []const u8) ?Value {
    for (options) |o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o.value;
    return null;
}

/// Sets `name`, replacing an earlier value.
fn put(arena: std.mem.Allocator, options: *std.ArrayList(Option), name: []const u8, value: Value) error{OutOfMemory}!void {
    for (options.items) |*o| if (std.ascii.eqlIgnoreCase(o.name, name)) {
        o.value = value;
        return;
    };
    try options.append(arena, .{ .name = name, .value = value });
}

fn isIpv4(name: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |part| : (parts += 1) {
        if (part.len == 0 or part.len > 3) return false;
        const n = std.fmt.parseInt(u16, part, 10) catch return false;
        if (n > 255) return false;
    }
    return parts == 4;
}

/// `text` with its %XX sequences decoded; `text` itself when there are
/// none.
pub fn percentDecode(arena: std.mem.Allocator, text: []const u8) error{ InvalidEncoding, OutOfMemory }![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (text[i] == '%') {
            if (i + 3 > text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return error.InvalidEncoding;
            out[n] = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch unreachable;
            i += 3;
        } else {
            out[n] = text[i];
            i += 1;
        }
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Credentials

pub const Mechanism = enum {
    scram_sha_1,
    scram_sha_256,
    plain,
    gssapi,
    x509,
    aws,
    oidc,

    /// The name the server and the connection string use.
    pub fn name(m: Mechanism) []const u8 {
        return switch (m) {
            .scram_sha_1 => "SCRAM-SHA-1",
            .scram_sha_256 => "SCRAM-SHA-256",
            .plain => "PLAIN",
            .gssapi => "GSSAPI",
            .x509 => "MONGODB-X509",
            .aws => "MONGODB-AWS",
            .oidc => "MONGODB-OIDC",
        };
    }

    pub fn fromName(text: []const u8) ?Mechanism {
        inline for (@typeInfo(Mechanism).@"enum".field_names) |field| {
            const m: Mechanism = @field(Mechanism, field);
            if (std.mem.eql(u8, text, m.name())) return m;
        }
        return null;
    }
};

/// What authenticates the client's connections (auth.md, MongoCredential).
pub const Credential = struct {
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// The database the authentication commands go to.
    source: []const u8,
    /// Null: negotiated on the handshake (SCRAM-SHA-256 when the server
    /// lists it for the user, else SCRAM-SHA-1).
    mechanism: ?Mechanism = null,
    properties: []const Pair = &.{},

    pub fn property(self: Credential, key: []const u8) ?[]const u8 {
        for (self.properties) |p| if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
        return null;
    }
};

/// The credential `cs` asks for, or null when it asks for none (no
/// userinfo and no `authMechanism`: a database or `authSource` alone does
/// not). Errors when a mechanism's rules are broken: a missing username,
/// a password X.509 cannot take, a wrong source.
pub fn credential(arena: std.mem.Allocator, cs: ConnectionString, diag: ?*Diagnostic) Error!?Credential {
    var p: Parser = .{ .arena = arena, .diag = diag };
    const mech_text = cs.string("authMechanism");
    if (!cs.userinfo and mech_text == null) return null;
    const mechanism: ?Mechanism = if (mech_text) |t| Mechanism.fromName(t) orelse return p.fail("unknown authMechanism \"{s}\"", .{t}) else null;
    const source_opt = cs.string("authSource");
    const props: []const Pair = if (cs.get("authMechanismProperties")) |v| v.pairs else &.{};
    var cred: Credential = .{
        .username = if (cs.userinfo) cs.username else null,
        .password = cs.password,
        .source = "admin",
        .mechanism = mechanism,
        .properties = props,
    };
    const m = mechanism orelse {
        try needUsername(&p, cred, "the default mechanism (SCRAM)");
        if (props.len > 0) return p.fail("authMechanismProperties need an authMechanism that takes them", .{});
        cred.source = source_opt orelse cs.database orelse "admin";
        return cred;
    };
    switch (m) {
        .scram_sha_1, .scram_sha_256 => {
            try needUsername(&p, cred, m.name());
            if (props.len > 0) return p.fail("{s} takes no authMechanismProperties", .{m.name()});
            cred.source = source_opt orelse cs.database orelse "admin";
        },
        .plain => {
            try needUsername(&p, cred, m.name());
            if (cred.password == null) return p.fail("PLAIN needs a password", .{});
            cred.source = source_opt orelse cs.database orelse "$external";
        },
        .x509 => {
            if (cred.password != null) return p.fail("MONGODB-X509 takes no password", .{});
            if (cred.username) |u| if (u.len == 0) {
                cred.username = null;
            };
            cred.source = try external(&p, source_opt, m);
        },
        .gssapi => {
            try needUsername(&p, cred, m.name());
            cred.source = try external(&p, source_opt, m);
            var list: std.ArrayList(Pair) = .empty;
            var service_name = false;
            for (props) |prop| {
                const known = [_][]const u8{ "SERVICE_NAME", "CANONICALIZE_HOST_NAME", "SERVICE_REALM", "SERVICE_HOST" };
                var ok = false;
                for (known) |k| ok = ok or std.ascii.eqlIgnoreCase(k, prop.key);
                if (!ok) return p.fail("GSSAPI does not take the property {s}", .{prop.key});
                if (std.ascii.eqlIgnoreCase(prop.key, "SERVICE_NAME")) service_name = true;
                if (std.ascii.eqlIgnoreCase(prop.key, "CANONICALIZE_HOST_NAME")) {
                    const allowed = [_][]const u8{ "none", "forward", "forwardAndReverse", "true", "false" };
                    var good = false;
                    for (allowed) |a| good = good or std.mem.eql(u8, a, prop.value);
                    if (!good) return p.fail("CANONICALIZE_HOST_NAME \"{s}\" is not none, forward or forwardAndReverse", .{prop.value});
                }
                try list.append(arena, prop);
            }
            if (!service_name) try list.append(arena, .{ .key = "SERVICE_NAME", .value = "mongodb" });
            cred.properties = list.items;
        },
        .aws => {
            cred.source = try external(&p, source_opt, m);
            if ((cred.username != null) != (cred.password != null)) return p.fail("MONGODB-AWS takes both an access key ID and a secret, or neither", .{});
            if (cred.property("AWS_SESSION_TOKEN") != null and cred.username == null)
                return p.fail("AWS_SESSION_TOKEN needs an access key ID and a secret", .{});
        },
        .oidc => {
            cred.source = try external(&p, source_opt, m);
            if (cred.password != null) return p.fail("MONGODB-OIDC takes no password", .{});
            for (props) |prop| {
                const known = [_][]const u8{ "ENVIRONMENT", "TOKEN_RESOURCE", "ALLOWED_HOSTS" };
                var ok = false;
                for (known) |k| ok = ok or std.mem.eql(u8, k, prop.key);
                if (!ok) return p.fail("MONGODB-OIDC does not take the property {s}", .{prop.key});
            }
            const environment = cred.property("ENVIRONMENT") orelse return p.fail("MONGODB-OIDC needs ENVIRONMENT (or a callback)", .{});
            const resource = cred.property("TOKEN_RESOURCE");
            if (std.mem.eql(u8, environment, "test") or std.mem.eql(u8, environment, "k8s")) {
                if (cred.username != null) return p.fail("MONGODB-OIDC ENVIRONMENT:{s} takes no username", .{environment});
                if (resource != null) return p.fail("MONGODB-OIDC ENVIRONMENT:{s} takes no TOKEN_RESOURCE", .{environment});
            } else if (std.mem.eql(u8, environment, "azure")) {
                if (resource == null) return p.fail("MONGODB-OIDC ENVIRONMENT:azure needs TOKEN_RESOURCE", .{});
            } else if (std.mem.eql(u8, environment, "gcp")) {
                if (resource == null) return p.fail("MONGODB-OIDC ENVIRONMENT:gcp needs TOKEN_RESOURCE", .{});
                if (cred.username != null) return p.fail("MONGODB-OIDC ENVIRONMENT:gcp takes no username", .{});
            } else return p.fail("MONGODB-OIDC ENVIRONMENT \"{s}\" is not test, azure, gcp or k8s", .{environment});
        },
    }
    return cred;
}

fn needUsername(p: *Parser, cred: Credential, what: []const u8) Error!void {
    const u = cred.username orelse return p.fail("{s} needs a username", .{what});
    if (u.len == 0) return p.fail("{s} needs a username", .{what});
}

fn external(p: *Parser, source: ?[]const u8, m: Mechanism) Error![]const u8 {
    const s = source orelse return "$external";
    if (!std.mem.eql(u8, s, "$external")) return p.fail("{s} authenticates against $external, not {s}", .{ m.name(), s });
    return s;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parse: hosts, credentials, database and typed options" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs = try parse(arena, "mongodb://app:s%40cret@db1.example:27018,[::1],%2Ftmp%2Fm.sock/shop?replicaSet=rs0&retryWrites=false&serverSelectionTimeoutMS=5000&readPreferenceTags=dc:ny&readPreferenceTags=", null);
    try testing.expectEqual(3, cs.hosts.len);
    try testing.expectEqual(Host.Kind.hostname, cs.hosts[0].kind);
    try testing.expectEqual(@as(?u16, 27018), cs.hosts[0].port);
    try testing.expectEqualStrings("::1", cs.hosts[1].name);
    try testing.expectEqual(Host.Kind.unix, cs.hosts[2].kind);
    try testing.expectEqualStrings("/tmp/m.sock", cs.hosts[2].name);
    try testing.expectEqualStrings("s@cret", cs.password.?);
    try testing.expectEqualStrings("shop", cs.database.?);
    try testing.expectEqualStrings("rs0", cs.string("replicaset").?);
    try testing.expectEqual(false, cs.boolean("retryWrites").?);
    try testing.expectEqual(@as(?i64, 5000), cs.int("serverSelectionTimeoutMS"));
    const tags = cs.get("readPreferenceTags").?.tag_sets;
    try testing.expectEqual(2, tags.len);
    try testing.expectEqualStrings("ny", tags[0][0].value);
    try testing.expectEqual(0, tags[1].len);
    try testing.expectEqual(0, cs.warnings.len);

    const cred = (try credential(arena, cs, null)).?;
    try testing.expectEqualStrings("shop", cred.source);
    try testing.expect(cred.mechanism == null);
    try testing.expect(try credential(arena, try parse(arena, "mongodb://localhost/app?authSource=admin", null), null) == null);
}

test "parse: warnings for what is left out, errors for what is wrong" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cs = try parse(arena, "mongodb://h/?foo=bar&maxPoolSize=-1&journal=yes", null);
    try testing.expectEqual(3, cs.warnings.len);
    try testing.expect(cs.get("maxPoolSize") == null);
    try testing.expectEqual(true, cs.boolean("journal").?);

    var diag: Diagnostic = .{};
    for ([_][]const u8{
        "mongodb://",
        "mongodb://h:0",
        "mongodb://a:b:c@h",
        "mongodb://h/?w",
        "mongodb://h1,h2/?directConnection=true",
        "mongodb://h/?tlsInsecure=true&tlsAllowInvalidHostnames=false",
        "mongodb://h/?tls=true&ssl=false",
        "mongodb://h/db$x",
    }) |bad| {
        try testing.expectError(error.InvalidUri, parse(arena, bad, &diag));
        try testing.expect(diag.message.len > 0);
    }

    // A password with a character it should have percent-encoded: refused,
    // without the password in the message.
    for ([_][]const u8{
        "mongodb://u:hunter2/x@h/db",
        "mongodb://u:hunter2?x@h/db",
        "mongodb://u:hunter2/@h",
        "mongodb://u:hunter2:x@h",
        "mongodb://u:x/hunter2@h/db",
        "mongodb://u:x?hunter2@h",
        "mongodb://u:hunter2/x.sock@h/db",
    }) |bad| {
        diag = .{};
        if (parse(arena, bad, &diag)) |_| return error.TestUnexpectedResult else |_| {}
        try testing.expect(std.mem.indexOf(u8, diag.message, "hunter2") == null);
    }
}
