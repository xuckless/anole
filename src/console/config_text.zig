//! The redacted `/config` text (design 7.3): a comptime walk over the
//! server's options writing `field = value` lines, never a secret. Redacted:
//! types marked `anole_sensitive`, fields with a secret name, the password in
//! a URL, and certificate material (only its source is named). Skipped:
//! `process` (it holds the environment), function pointers, `_` fields.
const std = @import("std");
const redact = @import("anole_log").redact;

const max_depth = 4;
const redacted = "[REDACTED]";

/// `scheme://user:password@host` with the password replaced; other text
/// as it is.
pub fn writeUrlRedacted(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const scheme = std.mem.find(u8, s, "://") orelse return w.writeAll(s);
    const rest_at = scheme + 3;
    const end = std.mem.findAnyPos(u8, s, rest_at, "/?#") orelse s.len;
    const auth = s[rest_at..end];
    const at = std.mem.findScalarLast(u8, auth, '@') orelse return w.writeAll(s);
    const cred = auth[0..at];
    const colon = std.mem.findScalar(u8, cred, ':') orelse return w.writeAll(s);
    try w.writeAll(s[0 .. rest_at + colon + 1]);
    try w.writeAll(redacted);
    try w.writeAll(s[rest_at + at ..]);
}

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (std.mem.find(u8, s, "://") != null) {
        try w.writeByte('"');
        try writeUrlRedacted(w, s);
        try w.writeByte('"');
    } else try w.print("\"{s}\"", .{s});
}

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

/// Whether the last segment of `name` is a token (`token`, `bot_token`,
/// `tokens`): secret in options, though the logger leaves a bare `token`
/// alone (lexers and pagination use the word in log fields).
fn isTokenName(comptime name: []const u8) bool {
    const seg = if (std.mem.findScalarLast(u8, name, '.')) |i| name[i + 1 ..] else name;
    for ([_][]const u8{ "token", "tokens" }) |word| {
        if (std.ascii.eqlIgnoreCase(seg, word)) return true;
        if (seg.len > word.len and std.ascii.endsWithIgnoreCase(seg, word) and
            (seg[seg.len - word.len - 1] == '_' or seg[seg.len - word.len - 1] == '-')) return true;
    }
    return false;
}

/// One value at `name` (with its dotted prefix), recursing into structs.
pub fn writeField(w: *std.Io.Writer, comptime name: []const u8, value: anytype, comptime depth: u8) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    // Certificate and key bytes in memory: only that they are there.
    if (comptime std.mem.endsWith(u8, name, "pem") or std.mem.endsWith(u8, name, ".pem")) {
        if (comptime @typeInfo(T) == .optional) {
            return w.print("{s} = {s}\n", .{ name, if (value == null) "(unset)" else "(in memory)" });
        }
        return w.print("{s} = (in memory)\n", .{name});
    }
    if (comptime redact.isSensitiveType(T) or redact.isSensitiveName(name) or isTokenName(name)) {
        // A secret that is unset or empty is not worth hiding.
        return w.print("{s} = {s}\n", .{ name, redacted });
    }
    switch (@typeInfo(T)) {
        .bool => try w.print("{s} = {}\n", .{ name, value }),
        .int, .comptime_int, .float, .comptime_float => try w.print("{s} = {d}\n", .{ name, value }),
        .@"enum" => try w.print("{s} = {s}\n", .{ name, std.enums.tagName(T, value) orelse "(unset)" }),
        .optional => if (value) |v| try writeField(w, name, v, depth) else try w.print("{s} = (unset)\n", .{name}),
        .pointer => {
            if (comptime isString(T)) {
                try w.print("{s} = ", .{name});
                try writeString(w, value);
                try w.writeByte('\n');
            } else if (comptime @typeInfo(T).pointer.size == .slice and isString(@typeInfo(T).pointer.child)) {
                try w.print("{s} = [", .{name});
                for (value, 0..) |s, i| {
                    if (i > 0) try w.writeAll(", ");
                    try writeString(w, s);
                }
                try w.writeAll("]\n");
            } else if (comptime @typeInfo(T).pointer.size == .slice) {
                try w.print("{s} = ({d} entries)\n", .{ name, value.len });
            }
        },
        .@"union" => {
            // Certificates and the like: which kind, never the material.
            switch (value) {
                inline else => |_, tag| {
                    if (comptime std.mem.find(u8, @typeName(T), "Cert") != null) {
                        try w.print("{s} = {s}\n", .{ name, @tagName(tag) });
                    } else try w.print("{s} = .{s}\n", .{ name, @tagName(tag) });
                },
            }
        },
        .@"struct" => |st| {
            if (comptime std.mem.find(u8, @typeName(T), "Duration") != null) {
                try w.print("{s} = {d} ms\n", .{ name, @divTrunc(value.nanoseconds, std.time.ns_per_ms) });
                return;
            }
            if (comptime std.mem.find(u8, @typeName(T), "Cert") != null) {
                try w.print("{s} = (certificate: see the listener)\n", .{name});
                return;
            }
            if (depth >= max_depth) return;
            inline for (st.field_names) |fname| {
                if (comptime fname.len > 0 and fname[0] == '_') continue;
                if (comptime std.mem.eql(u8, fname, "process")) continue;
                const FT = @TypeOf(@field(value, fname));
                if (comptime @typeInfo(FT) == .pointer and @typeInfo(@typeInfo(FT).pointer.child) == .@"fn") continue;
                if (comptime @typeInfo(FT) == .optional and @typeInfo(@typeInfo(FT).optional.child) == .pointer and @typeInfo(@typeInfo(@typeInfo(FT).optional.child).pointer.child) == .@"fn") continue;
                try writeField(w, if (name.len == 0) fname else name ++ "." ++ fname, @field(value, fname), depth + 1);
            }
        },
        else => {},
    }
}

/// All of `options` as lines.
pub fn writeOptions(w: *std.Io.Writer, options: anytype) std.Io.Writer.Error!void {
    try writeField(w, "", options, 0);
}

test "config_text: URL passwords are replaced, other text is untouched" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUrlRedacted(&w, "postgres://app:hunter2@db:5432/app?sslmode=require");
    try std.testing.expectEqualStrings("postgres://app:[REDACTED]@db:5432/app?sslmode=require", w.buffered());
    w = .fixed(&buf);
    try writeUrlRedacted(&w, "redis://cache:6379");
    try std.testing.expectEqualStrings("redis://cache:6379", w.buffered());
    w = .fixed(&buf);
    try writeUrlRedacted(&w, "redis://:pw@cache:6379/0");
    try std.testing.expectEqualStrings("redis://:[REDACTED]@cache:6379/0", w.buffered());
}

const Secret = struct {
    pub const anole_sensitive = true;
    value: []const u8,
};

test "config_text: secrets, secret-named fields, URL passwords and certificate bytes are not written" {
    const Cert = union(enum) { files: struct { cert_path: []const u8, key_path: []const u8 }, pem: struct { cert: []const u8, key: []const u8 } };
    const Opts = struct {
        port: u16 = 3000,
        token: []const u8 = "tok-fixture-123",
        key: Secret = .{ .value = "secret-fixture-456" },
        database_url: []const u8 = "postgres://u:pw-fixture-789@db/x",
        cert: Cert = .{ .pem = .{ .cert = "-----BEGIN CERTIFICATE-----fixture", .key = "-----BEGIN PRIVATE KEY-----fixture" } },
        process: ?u8 = 5,
        _hidden: u8 = 1,
        name: []const u8 = "api",
    };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeOptions(&w, Opts{});
    const text = w.buffered();
    for ([_][]const u8{ "tok-fixture", "secret-fixture", "pw-fixture", "BEGIN", "hidden", "process" }) |bad| {
        try std.testing.expect(std.mem.find(u8, text, bad) == null);
    }
    try std.testing.expect(std.mem.find(u8, text, "port = 3000") != null);
    try std.testing.expect(std.mem.find(u8, text, "name = \"api\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "cert = pem") != null);
}
