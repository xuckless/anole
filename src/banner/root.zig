//! The startup banner: the word "anole" drawn large (anole.txt), with the
//! version, the environment and the first listener's address below it. Only
//! for a person at a terminal: `show` says whether it is the case. Standard
//! library only, so the `anole` command line and the live console use it too.
//!
//! anole.txt is the art as drawn: U+2019 is the background, 'c' the yellow
//! inside of the O, every other character the green letters. It is turned
//! into three pictures at compile time, so printing parses nothing:
//!
//!   blocks     solid blocks, one per character of the art (98 x 15)
//!   glyphs     the art's own characters (98 x 15)
//!   halfblock  half blocks, two art rows per line and every other column
//!              (49 x 8), for terminals too narrow for the other two
//!
//! A wide terminal gets blocks or glyphs at random, a narrower one the half
//! blocks, and one narrower still only the title line.

const std = @import("std");
const builtin = @import("builtin");

// ------------------------------------------------------------------ the art

const art_text = @embedFile("anole.txt");
/// The background character of anole.txt.
const background: u21 = 0x2019;

/// What one character of the art is.
const Kind = enum { blank, body, inside };

/// The colour of a run of characters. The two `_over_` inks are half blocks
/// with the upper half in the first colour (foreground) and the lower half in
/// the second (background).
pub const Ink = enum { none, green, yellow, green_over_yellow, yellow_over_green };

/// A run of characters in one ink.
pub const Seg = struct { ink: Ink, text: []const u8 };

pub const Picture = struct {
    /// Columns of the widest line.
    width: usize,
    lines: []const []const Seg,
};

const max_w = 160;
const max_h = 40;

/// The art, trimmed to the letters' bounding box.
const Grid = struct {
    w: usize,
    h: usize,
    kinds: [max_h][max_w]Kind,
    glyphs: [max_h][max_w][]const u8,
};

const grid: Grid = blk: {
    @setEvalBranchQuota(2_000_000);
    var kinds: [max_h][max_w]Kind = @splat(@splat(.blank));
    var glyphs_: [max_h][max_w][]const u8 = @splat(@splat(" "));
    var h: usize = 0;
    var w: usize = 0;
    var lines = std.mem.splitScalar(u8, art_text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0 and lines.peek() == null) break;
        var it = (std.unicode.Utf8View.init(line) catch @compileError("anole.txt is not UTF-8")).iterator();
        var x: usize = 0;
        while (it.nextCodepointSlice()) |s| : (x += 1) {
            const cp = std.unicode.utf8Decode(s) catch unreachable;
            kinds[h][x] = if (cp == background or cp == ' ') .blank else if (cp == 'c') .inside else .body;
            glyphs_[h][x] = s;
        }
        w = @max(w, x);
        h += 1;
    }
    // The bounding box of everything that is not background.
    var top: usize = h;
    var bottom: usize = 0;
    var left: usize = w;
    var right: usize = 0;
    for (0..h) |y| for (0..w) |x| if (kinds[y][x] != .blank) {
        top = @min(top, y);
        bottom = @max(bottom, y + 1);
        left = @min(left, x);
        right = @max(right, x + 1);
    };
    if (top >= bottom) @compileError("anole.txt is empty");
    var g: Grid = .{ .w = right - left, .h = bottom - top, .kinds = @splat(@splat(.blank)), .glyphs = @splat(@splat(" ")) };
    for (0..g.h) |y| for (0..g.w) |x| {
        g.kinds[y][x] = kinds[top + y][left + x];
        g.glyphs[y][x] = glyphs_[top + y][left + x];
    };
    break :blk g;
};

const Form = enum { blocks, glyphs, halfblock };

/// The kind of a cell; without colour the yellow inside of the O is left
/// blank, so the O stays an O.
fn kindAt(comptime y: usize, comptime x: usize, comptime color: bool) Kind {
    if (y >= grid.h or x >= grid.w) return .blank;
    const k = grid.kinds[y][x];
    return if (k == .inside and !color) .blank else k;
}

fn inkOf(k: Kind) Ink {
    return switch (k) {
        .blank => .none,
        .body => .green,
        .inside => .yellow,
    };
}

const Cell = struct { ink: Ink, glyph: []const u8 };

/// One terminal cell of a picture.
fn cellAt(comptime form: Form, comptime color: bool, comptime y: usize, comptime x: usize) Cell {
    switch (form) {
        .blocks => {
            const k = kindAt(y, x, color);
            return .{ .ink = inkOf(k), .glyph = if (k == .blank) " " else "█" };
        },
        .glyphs => {
            const k = kindAt(y, x, color);
            return .{ .ink = inkOf(k), .glyph = if (k == .blank) " " else grid.glyphs[y][x] };
        },
        .halfblock => {
            // Art rows 2y and 2y+1, column 2x (or 2x+1 when 2x is blank).
            const ty = 2 * y;
            const tx = 2 * x;
            const t = if (kindAt(ty, tx, color) != .blank) kindAt(ty, tx, color) else kindAt(ty, tx + 1, color);
            const b = if (kindAt(ty + 1, tx, color) != .blank) kindAt(ty + 1, tx, color) else kindAt(ty + 1, tx + 1, color);
            if (t == .blank and b == .blank) return .{ .ink = .none, .glyph = " " };
            if (b == .blank) return .{ .ink = inkOf(t), .glyph = "▀" };
            if (t == .blank) return .{ .ink = inkOf(b), .glyph = "▄" };
            if (t == b) return .{ .ink = inkOf(t), .glyph = "█" };
            return .{ .ink = if (t == .body) .green_over_yellow else .yellow_over_green, .glyph = "▀" };
        },
    }
}

fn build(comptime form: Form, comptime color: bool) Picture {
    @setEvalBranchQuota(2_000_000);
    const h = if (form == .halfblock) (grid.h + 1) / 2 else grid.h;
    const w = if (form == .halfblock) (grid.w + 1) / 2 else grid.w;
    var lines: []const []const Seg = &.{};
    var width: usize = 0;
    for (0..h) |y| {
        var segs: []const Seg = &.{};
        var ink: Ink = .none;
        var text: []const u8 = "";
        var used: usize = 0; // columns up to the end of the last inked run
        for (0..w) |x| {
            const c = cellAt(form, color, y, x);
            if (c.ink != ink and text.len > 0) {
                segs = segs ++ &[_]Seg{.{ .ink = ink, .text = text }};
                text = "";
            }
            ink = c.ink;
            text = text ++ c.glyph;
            if (c.ink != .none) used = x + 1;
        }
        // Trailing blanks are left out.
        if (text.len > 0 and ink != .none) segs = segs ++ &[_]Seg{.{ .ink = ink, .text = text }};
        width = @max(width, used);
        lines = lines ++ &[_][]const Seg{segs};
    }
    const result: Picture = .{ .width = width, .lines = lines };
    return result;
}

pub const blocks = build(.blocks, true);
pub const blocks_plain = build(.blocks, false);
pub const glyphs = build(.glyphs, true);
pub const glyphs_plain = build(.glyphs, false);
pub const halfblock = build(.halfblock, true);
pub const halfblock_plain = build(.halfblock, false);

// ------------------------------------------------------------- the banner

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

/// How colours are written.
pub const Palette = enum {
    /// No colour (`NO_COLOR`): the art in the terminal's own colour.
    none,
    /// The nearest of the 256 xterm colours.
    ansi256,
    /// 24-bit colour (`COLORTERM=truecolor` or `24bit`).
    truecolor,
};

/// Which picture is drawn above the title.
pub const Art = enum { blocks, glyphs, halfblock, none };

/// How the banner is drawn.
pub const Style = struct {
    palette: Palette = .truecolor,
    art: Art = .blocks,
};

/// Each line of the banner starts with this.
pub const indent = "  ";
/// The narrowest terminal that gets the blocks or the glyphs (110 columns).
pub const wide_columns = indent.len + blocks.width + 10;
/// The narrowest terminal that gets the half blocks; narrower ones get the
/// title line alone.
pub const narrow_columns = indent.len + halfblock.width + 4;

const reset = "\x1b[0m";
/// #ABEB62, the icon's green, and #FFD23F.
const green_rgb = "171;235;98";
const yellow_rgb = "255;210;63";
/// Their nearest xterm-256 colours: #afd75f and #ffd75f.
const green_256 = "149";
const yellow_256 = "221";

fn inkCode(ink: Ink, palette: Palette) []const u8 {
    return switch (palette) {
        .none => "",
        .truecolor => switch (ink) {
            .none => "",
            .green => "\x1b[38;2;" ++ green_rgb ++ "m",
            .yellow => "\x1b[38;2;" ++ yellow_rgb ++ "m",
            .green_over_yellow => "\x1b[38;2;" ++ green_rgb ++ ";48;2;" ++ yellow_rgb ++ "m",
            .yellow_over_green => "\x1b[38;2;" ++ yellow_rgb ++ ";48;2;" ++ green_rgb ++ "m",
        },
        .ansi256 => switch (ink) {
            .none => "",
            .green => "\x1b[38;5;" ++ green_256 ++ "m",
            .yellow => "\x1b[38;5;" ++ yellow_256 ++ "m",
            .green_over_yellow => "\x1b[38;5;" ++ green_256 ++ ";48;5;" ++ yellow_256 ++ "m",
            .yellow_over_green => "\x1b[38;5;" ++ yellow_256 ++ ";48;5;" ++ green_256 ++ "m",
        },
    };
}

/// The picture for `art` (null for `.none`), coloured or plain.
pub fn picture(art: Art, color: bool) ?Picture {
    return switch (art) {
        .blocks => if (color) blocks else blocks_plain,
        .glyphs => if (color) glyphs else glyphs_plain,
        .halfblock => if (color) halfblock else halfblock_plain,
        .none => null,
    };
}

/// Draws one picture, each line starting with `indent` and ending in a
/// newline.
pub fn writeArt(w: *std.Io.Writer, art: Art, palette: Palette) std.Io.Writer.Error!void {
    const pic = picture(art, palette != .none) orelse return;
    for (pic.lines) |line| {
        try w.writeAll(indent);
        for (line) |seg| {
            const code = inkCode(seg.ink, palette);
            try w.writeAll(code);
            try w.writeAll(seg.text);
            if (code.len > 0) try w.writeAll(reset);
        }
        try w.writeByte('\n');
    }
}

/// "anole 0.4.0 · development".
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

/// Draws the banner, each line ending in a newline: the picture, then the
/// title and the address under it; with `.art = .none`, the title alone.
pub fn write(w: *std.Io.Writer, info: Info, style: Style) std.Io.Writer.Error!void {
    if (style.art == .none) {
        try writeTitle(w, info);
        try w.writeByte('\n');
        return;
    }
    try writeArt(w, style.art, style.palette);
    try w.writeAll(indent);
    try writeTitle(w, info);
    try w.writeByte('\n');
    if (info.host.len > 0) {
        try w.writeAll(indent);
        try writeAddress(w, info);
        try w.writeByte('\n');
    }
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

/// The palette: none under a non-empty `NO_COLOR`, 24-bit when `COLORTERM`
/// says so, else the 256 colours.
pub fn paletteFor(env: anytype) Palette {
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return .none;
    if (env.get("COLORTERM")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "truecolor") or std.ascii.eqlIgnoreCase(v, "24bit")) return .truecolor;
    }
    return .ansi256;
}

/// The style for a terminal `columns` wide (null: unknown, then `COLUMNS`,
/// else taken as narrow). `pick` chooses between the blocks and the glyphs
/// on a wide terminal (a random bit from the caller, `coin`).
pub fn styleFor(columns: ?usize, env: anytype, pick: bool) Style {
    const cols: ?usize = columns orelse if (env.get("COLUMNS")) |v| (std.fmt.parseInt(usize, v, 10) catch null) else null;
    const art: Art = if (cols) |c|
        (if (c >= wide_columns) (if (pick) Art.glyphs else Art.blocks) else if (c >= narrow_columns) Art.halfblock else Art.none)
    else
        .halfblock;
    return .{ .palette = paletteFor(env), .art = art };
}

/// The width of the terminal `file` is, or null when unknown (not a
/// terminal, or Windows).
pub fn terminalColumns(io: std.Io, file: std.Io.File) ?usize {
    if (comptime builtin.os.tag == .windows) return null;
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = (io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return null).device_io_control;
    if (result < 0 or size.col == 0) return null;
    return size.col;
}

/// One random bit for `styleFor`.
pub fn coin(io: std.Io) bool {
    var b: [1]u8 = undefined;
    io.random(&b);
    return b[0] & 1 == 1;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const FakeEnv = struct {
    pairs: []const [2][]const u8 = &.{},
    pub fn get(self: FakeEnv, name: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

test "pictures: sizes, and plain text with no escapes" {
    try testing.expectEqual(@as(usize, 98), blocks.width);
    try testing.expectEqual(@as(usize, 15), blocks.lines.len);
    try testing.expectEqual(blocks.width, glyphs.width);
    try testing.expectEqual(@as(usize, 49), halfblock.width);
    try testing.expectEqual(@as(usize, 8), halfblock.lines.len);
    try testing.expectEqual(@as(usize, 110), wide_columns);
    try testing.expect(narrow_columns <= 60);
    inline for (.{ Art.blocks, Art.glyphs, Art.halfblock }) |art| {
        var buf: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeArt(&w, art, .none);
        const out = w.buffered();
        try testing.expect(std.mem.indexOfScalar(u8, out, 0x1b) == null);
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
        var n: usize = 0;
        while (lines.next()) |line| : (n += 1) {
            try testing.expect(std.mem.startsWith(u8, line, indent));
            try testing.expect(try std.unicode.utf8CountCodepoints(line) <= indent.len + picture(art, false).?.width);
            try testing.expect(!std.mem.endsWith(u8, line, " "));
        }
        try testing.expectEqual(picture(art, false).?.lines.len, n);
    }
}

test "pictures: the O's yellow inside only in colour" {
    var buf: [32 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeArt(&w, .blocks, .truecolor);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;2;171;235;98m█") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;2;255;210;63m█") != null);
    w = .fixed(&buf);
    try writeArt(&w, .glyphs, .ansi256);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;5;221mccc") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;5;149mÕ") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;2;") == null);
    w = .fixed(&buf);
    try writeArt(&w, .halfblock, .truecolor);
    // A half block with green above and yellow below: the top of the O.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[38;2;171;235;98;48;2;255;210;63m▀") != null);
    w = .fixed(&buf);
    try writeArt(&w, .glyphs, .none);
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), 'c') == null);
}

test "write: the picture with the title and the address under it" {
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .version = "0.4.0", .environment = "development", .host = "localhost", .port = 3000, .h2 = true, .h3 = true }, .{ .palette = .none, .art = .halfblock });
    const out = w.buffered();
    try testing.expect(std.mem.endsWith(u8, out, "\n  anole 0.4.0 · development\n  http://localhost:3000  h1 · h2 · h3\n"));
    try testing.expectEqual(halfblock.lines.len + 2, std.mem.count(u8, out, "\n"));
    w = .fixed(&buf);
    try write(&w, .{ .version = "0.4.0" }, .{ .palette = .none, .art = .blocks });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "█\n  anole 0.4.0\n"));
}

test "write: a very narrow terminal gets one line" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, .{ .version = "0.4.0", .environment = "development", .host = "localhost", .port = 1 }, .{ .art = .none });
    try testing.expectEqualStrings("anole 0.4.0 · development\n", w.buffered());
}

test "banner: a test build never shows the banner" {
    try testing.expect(!show(true, true, true, FakeEnv{}));
}

test "styleFor: width, COLUMNS, NO_COLOR and COLORTERM pick the art and palette" {
    const env: FakeEnv = .{};
    try testing.expectEqual(Art.blocks, styleFor(110, env, false).art);
    try testing.expectEqual(Art.glyphs, styleFor(200, env, true).art);
    try testing.expectEqual(Art.halfblock, styleFor(109, env, true).art);
    try testing.expectEqual(Art.halfblock, styleFor(narrow_columns, env, false).art);
    try testing.expectEqual(Art.none, styleFor(narrow_columns - 1, env, false).art);
    // Unknown: COLUMNS, else narrow.
    try testing.expectEqual(Art.halfblock, styleFor(null, env, false).art);
    try testing.expectEqual(Art.blocks, styleFor(null, FakeEnv{ .pairs = &.{.{ "COLUMNS", "120" }} }, false).art);
    try testing.expectEqual(Art.none, styleFor(null, FakeEnv{ .pairs = &.{.{ "COLUMNS", "40" }} }, false).art);
    try testing.expectEqual(Palette.none, styleFor(120, FakeEnv{ .pairs = &.{.{ "NO_COLOR", "1" }} }, false).palette);
    try testing.expectEqual(Palette.ansi256, styleFor(120, env, false).palette);
    try testing.expectEqual(Palette.truecolor, styleFor(120, FakeEnv{ .pairs = &.{.{ "COLORTERM", "truecolor" }} }, false).palette);
    try testing.expectEqual(Palette.truecolor, styleFor(120, FakeEnv{ .pairs = &.{.{ "COLORTERM", "24bit" }} }, false).palette);
    try testing.expectEqual(Palette.none, styleFor(120, FakeEnv{ .pairs = &.{ .{ "NO_COLOR", "1" }, .{ "COLORTERM", "truecolor" } } }, false).palette);
}
