// Adapted from vkiryakov/zefir src/confy/Secret.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! A string that is never printed: `{f}` writes `[REDACTED]`, `{s}` doesn't
//! compile, and `{any}` shows only an address and a length. Anole's JSON Lines logger
//! writes it as `[REDACTED]` wherever it sits in a logged value. Read the value
//! with `expose()`, so every place that uses it is easy to find.
//!
//! It guards against accidental logging, not against code that wants the
//! value: Zig has no private fields. `anole.config.free` wipes it before freeing.

const std = @import("std");

const Secret = @This();

// A many-item pointer instead of a slice: `{any}` can't print what it points to.
ptr: [*]const u8,
len: usize,

/// Marks the type as sensitive (`anole_sensitive`): the logger writes
/// `[REDACTED]` for it, and for `?Secret`, `[]const Secret` and the like.
pub const anole_sensitive = true;

pub fn init(value: []const u8) Secret {
    return .{ .ptr = value.ptr, .len = value.len };
}

/// The secret itself. Don't log it.
pub fn expose(secret: Secret) []const u8 {
    return secret.ptr[0..secret.len];
}

pub fn format(_: Secret, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("[REDACTED]");
}

test "printing never shows the value" {
    const Config = struct { host: []const u8, password: Secret };
    const config: Config = .{ .host = "db", .password = .init("s3cret") };

    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{config.password});
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("[REDACTED]", formatted);

    const debug = try std.fmt.allocPrint(std.testing.allocator, "{any}", .{config});
    defer std.testing.allocator.free(debug);
    try std.testing.expect(std.mem.find(u8, debug, "s3cret") == null);
    try std.testing.expect(std.mem.find(u8, debug, "115, 51") == null); // "s3" as bytes

    try std.testing.expectEqualStrings("s3cret", config.password.expose());
}

test "the anole_sensitive marker is set, so the logger writes [REDACTED]" {
    try std.testing.expect(@hasDecl(Secret, "anole_sensitive") and Secret.anole_sensitive);
}
