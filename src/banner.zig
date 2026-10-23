//! The startup banner: the anole, with the version and environment and the
//! first listener's address beside it. Only for a person at a terminal:
//! `show` says whether it is the case. Standard library only, so the `anole`
//! command line uses it too (`anole new`).
//!
//!                                        _____
//!                    ___________________/  o  \____
//!   ~~~~~~~~~~~~~~~~(____________________        __>   anole 0.3.0 · development
//!                      /_/ /_/      \_\ \_\ (__)       http://localhost:3000  h1 · h2 · h3

const std = @import("std");
const builtin = @import("builtin");

/// What the banner says.
pub const Info = struct {
    version: []const u8,
    /// "development" or "production"; empty to leave it out.
    environment: []const u8 = "",
    /// The first listener: empty `host` leaves the address line out.
    scheme: []const u8 = "http",
    host: []const u8 = "",
    port: u16 = 0,
    h1: bool = true,
    h2: bool = false,
    h3: bool = false,
};

/// How it is drawn.
pub const Style = struct {
    /// Green body and pink dewlap (`NO_COLOR` turns it off; the art stays).
    color: bool = true,
    /// The terminal is at least 80 columns wide; otherwise one line.
    wide: bool = true,
};

const green = "\x1b[32m";
const pink = "\x1b[95m";
const reset = "\x1b[0m";

fn paint(w: *std.Io.Writer, style: Style, comptime color: []const u8, text: []const u8) std.Io.Writer.Error!void {
    if (style.color) try w.writeAll(color);
    try w.writeAll(text);
    if (style.color) try w.writeAll(reset);
}

/// "anole 0.3.0 · development".
fn writeTitle(w: *std.Io.Writer, info: Info) std.Io.Writer.Error!void {
    try w.print("anole {s}", .{info.version});
    if (info.environment.len > 0) try w.print(" · {s}", .{info.environment});
}

/// "http://localhost:3000  h1 · h2 · h3".
fn writeAddress(w: *std.Io.Writer, info: Info) std.Io.Writer.Error!void {
    try w.print("{s}://{s}:{d} ", .{ info.scheme, info.host, info.port });
    var first = true;
    inline for (.{ .{ info.h1, "h1" }, .{ info.h2, "h2" }, .{ info.h3, "h3" } }) |p| {
        if (p[0]) {
            try w.writeAll(if (first) " " else " · ");
            try w.writeAll(p[1]);
            first = false;
        }
    }
}

/// Draws the banner, each line ending in a newline: the art, or one line
/// when the terminal is narrow.
pub fn write(w: *std.Io.Writer, info: Info, style: Style) std.Io.Writer.Error!void {
    if (!style.wide) {
        try writeTitle(w, info);
        try w.writeByte('\n');
        return;
    }
    try paint(w, style, green, "                                       _____");
    try w.writeByte('\n');
    try paint(w, style, green, "                   ___________________/  o  \\____");
    try w.writeByte('\n');
    try paint(w, style, green, "  ~~~~~~~~~~~~~~~~(____________________        __>");
    try w.writeAll("   ");
    try writeTitle(w, info);
    try w.writeByte('\n');
    try paint(w, style, green, "                     /_/ /_/      \\_\\ \\_\\ ");
    try paint(w, style, pink, "(__)");
    if (info.host.len > 0) {
        try w.writeAll("       ");
        try writeAddress(w, info);
    }
    try w.writeByte('\n');
}

/// Whether the banner may be shown: the program asked for it (`wanted`,
/// `ServerOptions.banner`), `ANOLE_NO_BANNER` is not "1", the log format is
/// text (`text_logs`), not a test build, not under systemd
/// (`INVOCATION_ID`, `NOTIFY_SOCKET`), and the output is a terminal
/// (`is_tty`). `env` looks a variable up in the process environment.
pub fn show(wanted: bool, text_logs: bool, is_tty: bool, env: anytype) bool {
    if (!wanted or !text_logs or !is_tty) return false;
    if (builtin.is_test) return false;
    if (env.get("ANOLE_NO_BANNER")) |v| if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) return false;
    if (env.get("INVOCATION_ID") != null or env.get("NOTIFY_SOCKET") != null) return false;
    return true;
}

/// The style for a terminal `columns` wide (null: unknown, taken as wide
/// enough), with colour unless `NO_COLOR` is set and non-empty.
pub fn styleFor(columns: ?usize, env: anytype) Style {
    const no_color = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
    return .{ .color = !no_color, .wide = (columns orelse 80) >= 80 };
}

const testing = std.testing;

const FakeEnv = struct {
    pairs: []const [2][]const u8 = &.{},
    pub fn get(self: FakeEnv, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "write: the art with the title and the address, in colour or not" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .version = "0.3.0", .environment = "development", .host = "localhost", .port = 3000, .h2 = true, .h3 = true }, .{ .color = false });
    try testing.expectEqualStrings(
        \\                                       _____
        \\                   ___________________/  o  \____
        \\  ~~~~~~~~~~~~~~~~(____________________        __>   anole 0.3.0 · development
        \\                     /_/ /_/      \_\ \_\ (__)       http://localhost:3000  h1 · h2 · h3
        \\
    , w.buffered());
    w = .fixed(&buf);
    try write(&w, .{ .version = "0.3.0", .host = "localhost", .port = 1 }, .{});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[32m") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[95m(__)\x1b[0m") != null);
}

test "write: a narrow terminal gets one line" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .version = "0.3.0", .environment = "development" }, .{ .wide = false });
    try testing.expectEqualStrings("anole 0.3.0 · development\n", w.buffered());
}

test "show: never in tests; styleFor reads NO_COLOR and the width" {
    // A test build never shows it, whatever else holds.
    try testing.expect(!show(true, true, true, FakeEnv{}));
    try testing.expect(!styleFor(100, FakeEnv{ .pairs = &.{.{ "NO_COLOR", "1" }} }).color);
    try testing.expect(styleFor(100, FakeEnv{}).color);
    try testing.expect(!styleFor(79, FakeEnv{}).wide);
    try testing.expect(styleFor(null, FakeEnv{}).wide);
}
