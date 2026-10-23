// Copied from vkiryakov/zefir src/confy/Diagnostics.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! Every problem found while loading configuration, not only the first one.
//!
//! Owns its memory: `add` copies every string, so problems stay valid after the
//! `load` call that reported them has freed its temporary memory.
//! Problems never contain configuration values, which may be secrets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Origin = @import("tree.zig").Origin;

const Diagnostics = @This();

arena: std.heap.ArenaAllocator,
problems: std.ArrayList(Problem) = .empty,

pub const Kind = enum { missing, invalid, unknown_key, duplicate_key, syntax, unreadable };

pub const Problem = struct {
    kind: Kind,
    /// Field path such as `db.port`; empty when the problem is not about one field.
    path: []const u8 = "",
    /// Where the offending value is; null when there is no value (`missing`).
    origin: ?Origin = null,
    /// What was expected or what to do. Never the value itself.
    detail: []const u8 = "",
};

/// Use it as `var diag: Diagnostics = .init(gpa); defer diag.deinit();` and pass
/// `&diag`; don't copy it after the first `add`.
pub fn init(gpa: Allocator) Diagnostics {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(diag: *Diagnostics) void {
    diag.arena.deinit();
    diag.* = undefined;
}

/// Records `problem`, copying all of its strings.
pub fn add(diag: *Diagnostics, problem: Problem) Allocator.Error!void {
    const arena = diag.arena.allocator();
    const origin: ?Origin = if (problem.origin) |origin| .{
        .file = if (origin.file) |file| try arena.dupe(u8, file) else null,
        .line = origin.line,
        .env_key = if (origin.env_key) |key| try arena.dupe(u8, key) else null,
    } else null;
    try diag.problems.append(arena, .{
        .kind = problem.kind,
        .path = try arena.dupe(u8, problem.path),
        .origin = origin,
        .detail = try arena.dupe(u8, problem.detail),
    });
}

/// Like `add`, with the detail formatted from `fmt` and `args`.
pub fn addFmt(
    diag: *Diagnostics,
    kind: Kind,
    path: []const u8,
    origin: ?Origin,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const detail = try std.fmt.allocPrint(diag.arena.allocator(), fmt, args);
    try diag.add(.{ .kind = kind, .path = path, .origin = origin, .detail = detail });
}

/// Writes one line per problem under a header; writes nothing when there are no problems.
pub fn format(diag: *const Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const problems = diag.problems.items;
    if (problems.len == 0) return;

    try w.print("{d} configuration problem{s}:", .{ problems.len, if (problems.len == 1) "" else "s" });
    for (problems) |problem| {
        try w.writeAll("\n  ");
        if (problem.origin) |origin| {
            if (origin.file) |file| {
                if (origin.line != 0) {
                    try w.print("{s}:{d}: ", .{ file, origin.line });
                } else {
                    try w.print("{s}: ", .{file});
                }
            } else {
                try w.writeAll("environment: ");
            }
        }
        const subject = if (problem.origin) |origin| origin.env_key orelse problem.path else problem.path;
        if (subject.len != 0) try w.print("{s}: ", .{subject});
        try w.writeAll(switch (problem.kind) {
            .missing => "missing",
            .invalid => "invalid",
            .unknown_key => "unknown key",
            .duplicate_key => "duplicate key",
            .syntax => "syntax error",
            .unreadable => "cannot read file",
        });
        if (problem.detail.len != 0) try w.print(" ({s})", .{problem.detail});
    }
}

test "add copies strings" {
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    var path_buf = "db.port".*;
    var file_buf = ".env".*;
    try diag.add(.{ .kind = .invalid, .path = &path_buf, .origin = .{ .file = &file_buf, .line = 2 } });
    @memset(&path_buf, 'x');
    @memset(&file_buf, 'x');

    const problem = diag.problems.items[0];
    try std.testing.expectEqualStrings("db.port", problem.path);
    try std.testing.expectEqualStrings(".env", problem.origin.?.file.?);
}

test "format lists every problem" {
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    try diag.add(.{ .kind = .missing, .path = "db.host", .detail = "set APP_DB_HOST, or \"db.host\" in a config file" });
    try diag.add(.{ .kind = .invalid, .path = "db.port", .origin = .{ .file = ".env", .line = 2, .env_key = "APP_DB_PORT" }, .detail = "expected an integer 0..65535" });
    try diag.add(.{ .kind = .invalid, .path = "log_level", .origin = .{ .env_key = "APP_LOG_LEVEL" }, .detail = "expected one of: debug, info" });
    try diag.addFmt(.unknown_key, "databse", .{ .file = "config.json", .line = 3 }, "did you mean \"{s}\"?", .{"database"});
    try diag.add(.{ .kind = .syntax, .origin = .{ .file = "config.ini", .line = 7 }, .detail = "expected key = value" });
    try diag.add(.{ .kind = .unreadable, .origin = .{ .file = "missing.json" }, .detail = "file not found" });

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\6 configuration problems:
        \\  db.host: missing (set APP_DB_HOST, or "db.host" in a config file)
        \\  .env:2: APP_DB_PORT: invalid (expected an integer 0..65535)
        \\  environment: APP_LOG_LEVEL: invalid (expected one of: debug, info)
        \\  config.json:3: databse: unknown key (did you mean "database"?)
        \\  config.ini:7: syntax error (expected key = value)
        \\  missing.json: cannot read file (file not found)
    , text);
}

test "format writes nothing without problems" {
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();

    const text = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{&diag});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}
