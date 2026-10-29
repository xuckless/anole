//! The in-memory screen the console draws into, and the renderer that turns
//! the difference between two screens into escape sequences. Golden-frame
//! tests read the grid; only `Renderer` knows about escape codes.
const std = @import("std");
const seq = @import("ctlseqs.zig");
const width_of = @import("width.zig").width;

/// The 16 basic ANSI colours (design D18), plus `default`: a u5. (The design's
/// list left out bright_cyan.)
pub const Color = enum(u5) {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

pub const Style = packed struct(u16) {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    reverse: bool = false,
    underline: bool = false,
    _: u2 = 0,

    pub fn eql(a: Style, b: Style) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    /// The right half of a wide character; never drawn on its own.
    wide_tail: bool = false,
    style: Style = .{},

    fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.wide_tail == b.wide_tail and a.style.eql(b.style);
    }
};

pub const Cursor = struct { x: u16, y: u16 };

pub const Screen = struct {
    cols: u16,
    rows: u16,
    cells: []Cell,
    cursor: ?Cursor = null,

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const cells = try gpa.alloc(Cell, @as(usize, cols) * rows);
        @memset(cells, .{});
        return .{ .cols = cols, .rows = rows, .cells = cells };
    }

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        self.* = undefined;
    }

    pub fn resize(self: *Screen, gpa: std.mem.Allocator, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        const cells = try gpa.alloc(Cell, @as(usize, cols) * rows);
        @memset(cells, .{});
        gpa.free(self.cells);
        self.cells = cells;
        self.cols = cols;
        self.rows = rows;
    }

    pub fn clear(self: *Screen) void {
        @memset(self.cells, .{});
        self.cursor = null;
    }

    pub fn at(self: *Screen, x: u16, y: u16) *Cell {
        return &self.cells[@as(usize, y) * self.cols + x];
    }

    pub fn get(self: *const Screen, x: u16, y: u16) Cell {
        return self.cells[@as(usize, y) * self.cols + x];
    }

    /// Writes UTF-8 text at (x, y), clipped at `max_x` (exclusive); returns the
    /// column after it. Invalid UTF-8 and control characters are drawn as
    /// U+FFFD, a tab as four spaces; a wide character that doesn't fit is
    /// left out whole.
    pub fn print(self: *Screen, x: u16, y: u16, max_x: u16, str: []const u8, style: Style) u16 {
        if (y >= self.rows) return x;
        const limit = @min(max_x, self.cols);
        var cx = x;
        var i: usize = 0;
        while (i < str.len and cx < limit) {
            var cp: u21 = undefined;
            const b = str[i];
            if (b < 0x80) {
                cp = b;
                i += 1;
            } else {
                const n = std.unicode.utf8ByteSequenceLength(b) catch {
                    cp = 0xFFFD;
                    i += 1;
                    cx = self.put(cx, y, limit, cp, style);
                    continue;
                };
                if (i + n > str.len) {
                    cp = 0xFFFD;
                    i = str.len;
                } else if (std.unicode.utf8Decode(str[i .. i + n])) |d| {
                    cp = d;
                    i += n;
                } else |_| {
                    cp = 0xFFFD;
                    i += 1;
                }
            }
            if (cp == '\t') {
                for (0..4) |_| cx = self.put(cx, y, limit, ' ', style);
                continue;
            }
            if (cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) cp = 0xFFFD;
            cx = self.put(cx, y, limit, cp, style);
        }
        return cx;
    }

    fn put(self: *Screen, x: u16, y: u16, limit: u16, cp: u21, style: Style) u16 {
        if (x >= limit) return x;
        const w = width_of(cp);
        if (w == 0) return x; // combining marks are not drawn (no grapheme clustering)
        if (w == 2) {
            if (x + 2 > limit) return limit; // never split a wide character
            self.at(x, y).* = .{ .cp = cp, .style = style };
            self.at(x + 1, y).* = .{ .cp = ' ', .wide_tail = true, .style = style };
            return x + 2;
        }
        self.at(x, y).* = .{ .cp = cp, .style = style };
        return x + 1;
    }

    /// Printing right-aligned so that the text ends at column `right` (exclusive).
    pub fn printRight(self: *Screen, right: u16, y: u16, min_x: u16, str: []const u8, style: Style) void {
        const w = textWidth(str);
        const start = if (right >= min_x + w) right - w else min_x;
        _ = self.print(start, y, right, str, style);
    }

    pub fn fill(self: *Screen, x: u16, y: u16, w: u16, h: u16, cp: u21, style: Style) void {
        var yy = y;
        while (yy < @min(y +| h, self.rows)) : (yy += 1) {
            var xx = x;
            while (xx < @min(x +| w, self.cols)) : (xx += 1) {
                self.at(xx, yy).* = .{ .cp = cp, .style = style };
            }
        }
    }

    /// Lines of characters, trailing spaces kept: for golden tests.
    pub fn text(self: *const Screen, w: *std.Io.Writer) !void {
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const c = self.get(x, y);
                if (c.wide_tail) continue;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.cp, &buf) catch blk: {
                    buf[0] = '?';
                    break :blk 1;
                };
                try w.writeAll(buf[0..n]);
            }
            try w.writeByte('\n');
        }
    }

    /// One style letter per cell for golden tests of colour: '.' default,
    /// 'b' bold, 'r' reverse, 'd' dim, 'u' underline, a colour initial for a
    /// foreground colour (uppercase for background-only).
    pub fn styles(self: *const Screen, w: *std.Io.Writer) !void {
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const s = self.get(x, y).style;
                const ch: u8 = if (s.reverse) 'r' else if (s.bold) 'b' else if (s.dim) 'd' else if (s.underline) 'u' else if (s.fg != .default) colorLetter(s.fg) else if (s.bg != .default) std.ascii.toUpper(colorLetter(s.bg)) else '.';
                try w.writeByte(ch);
            }
            try w.writeByte('\n');
        }
    }
};

fn colorLetter(c: Color) u8 {
    return switch (c) {
        .default => '.',
        .black, .bright_black => 'k',
        .red, .bright_red => 'r',
        .green, .bright_green => 'g',
        .yellow, .bright_yellow => 'y',
        .blue, .bright_blue => 'l',
        .magenta, .bright_magenta => 'm',
        .cyan, .bright_cyan => 'c',
        .white, .bright_white => 'w',
    };
}

/// Columns the text would take.
pub fn textWidth(text: []const u8) u16 {
    var n: u16 = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| n +|= if (cp == '\t') 4 else width_of(cp);
    return n;
}

pub const Renderer = struct {
    /// What the terminal shows.
    prev: Screen,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Renderer {
        return .{ .prev = try Screen.init(gpa, cols, rows), .gpa = gpa };
    }

    pub fn deinit(self: *Renderer) void {
        self.prev.deinit(self.gpa);
    }

    /// Writes the escape sequences that turn `prev` into `next` (cursor moves,
    /// SGR changes, characters), inside ?2026h/?2026l, then copies next into
    /// prev. `full` redraws everything (resize, Ctrl-L).
    pub fn render(self: *Renderer, next: *const Screen, color: bool, full_redraw: bool, w: *std.Io.Writer) !void {
        var full = full_redraw;
        if (self.prev.cols != next.cols or self.prev.rows != next.rows) {
            try self.prev.resize(self.gpa, next.cols, next.rows);
            full = true;
        }
        try w.writeAll(seq.sync_set);
        try w.writeAll(seq.hide_cursor);
        var cur_style: Style = .{};
        var cx: u32 = std.math.maxInt(u32);
        var cy: u32 = std.math.maxInt(u32);
        if (full) {
            try w.writeAll(seq.sgr_reset);
            try w.writeAll(seq.home);
            try w.writeAll(seq.erase_below_cursor);
            cx = 0;
            cy = 0;
        }
        var y: u16 = 0;
        while (y < next.rows) : (y += 1) {
            var x: u16 = 0;
            while (x < next.cols) : (x += 1) {
                const n = next.get(x, y);
                if (n.wide_tail) continue;
                if (!full and n.eql(self.prev.get(x, y))) continue;
                if (cx != x or cy != y) {
                    try w.print(seq.cup, .{ y + 1, x + 1 });
                    cx = x;
                    cy = y;
                }
                if (!n.style.eql(cur_style)) {
                    try writeStyle(w, n.style, color);
                    cur_style = n.style;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(n.cp, &buf) catch blk: {
                    buf[0] = '?';
                    break :blk 1;
                };
                try w.writeAll(buf[0..len]);
                cx += if (x + 1 < next.cols and next.get(x + 1, y).wide_tail) 2 else 1;
            }
        }
        if (!cur_style.eql(.{})) try w.writeAll(seq.sgr_reset);
        if (next.cursor) |c| {
            try w.print(seq.cup, .{ c.y + 1, c.x + 1 });
            try w.writeAll(seq.show_cursor);
        }
        try w.writeAll(seq.sync_reset);
        @memcpy(self.prev.cells, next.cells);
        self.prev.cursor = next.cursor;
    }
};

fn writeStyle(w: *std.Io.Writer, s: Style, color: bool) !void {
    try w.writeAll(seq.sgr_reset);
    if (s.bold) try w.writeAll(seq.bold_set);
    if (s.dim) try w.writeAll(seq.dim_set);
    if (s.reverse) try w.writeAll(seq.reverse_set);
    if (s.underline) try w.writeAll(seq.ul_single);
    if (!color) return;
    if (s.fg != .default) {
        const n: u8 = @backingInt(s.fg) - 1;
        if (n < 8) try w.print(seq.fg_base, .{n}) else try w.print(seq.fg_bright, .{n - 8});
    }
    if (s.bg != .default) {
        const n: u8 = @backingInt(s.bg) - 1;
        if (n < 8) try w.print(seq.bg_base, .{n}) else try w.print(seq.bg_bright, .{n - 8});
    }
}

test "screen: print clips at max_x and never splits a wide character" {
    var s = try Screen.init(std.testing.allocator, 8, 2);
    defer s.deinit(std.testing.allocator);
    const end = s.print(0, 0, 5, "abcdefgh", .{});
    try std.testing.expectEqual(@as(u16, 5), end);
    // "a中中" in 4 columns: the second wide character doesn't fit in column 3.
    _ = s.print(0, 1, 4, "a\u{4E2D}\u{4E2D}", .{});
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.text(&w);
    try std.testing.expectEqualStrings("abcde   \na\u{4E2D}     \n", w.buffered());
    // Control characters and bad UTF-8 are replaced; tabs expand.
    s.clear();
    _ = s.print(0, 0, 8, "a\x01\xff\tb", .{});
    var w2: std.Io.Writer = .fixed(&buf);
    try s.text(&w2);
    try std.testing.expectEqualStrings("a\u{FFFD}\u{FFFD}    b\n        \n"[0..], w2.buffered()[0..w2.buffered().len]);
}

test "screen: renderer writes only changed cells" {
    var r = try Renderer.init(std.testing.allocator, 4, 2);
    defer r.deinit();
    var next = try Screen.init(std.testing.allocator, 4, 2);
    defer next.deinit(std.testing.allocator);
    _ = next.print(0, 0, 4, "hi", .{});
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&next, true, false, &w);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[1;1Hhi\x1b[?2026l", w.buffered());
    // The same screen again: nothing but the frame marks.
    var w2: std.Io.Writer = .fixed(&buf);
    try r.render(&next, true, false, &w2);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[?2026l", w2.buffered());
    // One cell changes.
    _ = next.print(1, 1, 4, "x", .{ .bold = true });
    var w3: std.Io.Writer = .fixed(&buf);
    try r.render(&next, true, false, &w3);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[2;2H\x1b[m\x1b[1mx\x1b[m\x1b[?2026l", w3.buffered());
}

test "screen: full redraw after resize" {
    var r = try Renderer.init(std.testing.allocator, 2, 1);
    defer r.deinit();
    var next = try Screen.init(std.testing.allocator, 3, 1);
    defer next.deinit(std.testing.allocator);
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&next, true, false, &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[H\x1b[J") != null);
    // The renderer adopted the new size: the same screen again draws
    // nothing but the frame marks.
    var w2: std.Io.Writer = .fixed(&buf);
    try r.render(&next, true, false, &w2);
    try std.testing.expectEqualStrings("\x1b[?2026h\x1b[?25l\x1b[?2026l", w2.buffered());
}

test "screen: NO_COLOR frame has no colour SGR" {
    var r = try Renderer.init(std.testing.allocator, 3, 1);
    defer r.deinit();
    var next = try Screen.init(std.testing.allocator, 3, 1);
    defer next.deinit(std.testing.allocator);
    _ = next.print(0, 0, 3, "ok", .{ .fg = .green, .bold = true });
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&next, false, false, &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[32m") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[1m") != null);
}
