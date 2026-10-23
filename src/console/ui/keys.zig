// The legacy CSI/SS3 key table is adapted from rockorager/libvaxis src/Parser.zig
// (MIT, Copyright (c) 2023 Tim Culverhouse), commit bb94364. See THIRD_PARTY_NOTICES.
//! Keyboard input: a byte-fed parser for the keys a command-line console
//! needs. No mouse, no kitty keyboard protocol, no capability queries.
const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    enter,
    tab,
    backtab,
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    f: u8,
    /// 'a'..'z' (Ctrl-C is .{ .ctrl = 'c' }); Tab, Enter and Backspace keep their own tags.
    ctrl: u8,
    /// Valid until the next feed.
    paste: []const u8,
};

pub const max_paste = 64 * 1024;
const paste_end = "\x1b[201~";

pub const Parser = struct {
    state: State = .ground,
    params: [32]u8 = undefined,
    params_len: u8 = 0,
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_want: u3 = 0,
    paste_buf: [max_paste + paste_end.len]u8 = undefined,
    paste_len: usize = 0,
    paste_over: bool = false,

    const State = enum { ground, esc, csi, ss3, utf8, paste };

    /// Feeds bytes; calls `sink.onKey(Key)` per key. An incomplete escape
    /// sequence stays pending.
    pub fn feed(self: *Parser, bytes: []const u8, sink: anytype) void {
        for (bytes) |b| self.byte(b, sink);
    }

    /// No more bytes came: a pending lone ESC is the Escape key; any other
    /// pending prefix is dropped. A paste in progress stays.
    pub fn flushPending(self: *Parser, sink: anytype) void {
        switch (self.state) {
            .esc => sink.onKey(.escape),
            .csi, .ss3, .utf8 => {},
            .ground, .paste => return,
        }
        self.state = .ground;
        self.params_len = 0;
    }

    fn byte(self: *Parser, b: u8, sink: anytype) void {
        switch (self.state) {
            .ground => self.ground(b, sink),
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.params_len = 0;
                },
                'O' => self.state = .ss3,
                0x1b => sink.onKey(.escape),
                else => {
                    // Alt+key: the modifier is ignored.
                    self.state = .ground;
                    self.ground(b, sink);
                },
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    self.state = .ground;
                    self.csi(b, sink);
                } else if (b >= 0x20 and b <= 0x3f) {
                    if (self.params_len < self.params.len) {
                        self.params[self.params_len] = b;
                        self.params_len += 1;
                    }
                } else {
                    // Malformed: drop the sequence, treat the byte as ground.
                    self.state = .ground;
                    self.ground(b, sink);
                }
            },
            .ss3 => {
                self.state = .ground;
                const k: ?Key = switch (b) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'F' => .end,
                    'H' => .home,
                    'P' => .{ .f = 1 },
                    'Q' => .{ .f = 2 },
                    'R' => .{ .f = 3 },
                    'S' => .{ .f = 4 },
                    else => null,
                };
                if (k) |key| sink.onKey(key);
            },
            .utf8 => {
                if (b & 0xc0 != 0x80) {
                    sink.onKey(.{ .char = 0xFFFD });
                    self.state = .ground;
                    self.ground(b, sink);
                    return;
                }
                self.utf8[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_want) {
                    self.state = .ground;
                    const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch 0xFFFD;
                    sink.onKey(.{ .char = cp });
                }
            },
            .paste => {
                if (self.paste_len < self.paste_buf.len) {
                    self.paste_buf[self.paste_len] = b;
                    self.paste_len += 1;
                } else {
                    self.paste_over = true;
                    // Keep the tail so the terminator is still seen.
                    std.mem.copyForwards(u8, self.paste_buf[max_paste .. max_paste + paste_end.len - 1], self.paste_buf[max_paste + 1 .. max_paste + paste_end.len]);
                    self.paste_buf[self.paste_buf.len - 1] = b;
                }
                if (b == '~' and self.paste_len >= paste_end.len and std.mem.endsWith(u8, self.paste_buf[0..self.paste_len], paste_end)) {
                    const n = @min(self.paste_len - paste_end.len, max_paste);
                    self.state = .ground;
                    sink.onKey(.{ .paste = self.paste_buf[0..n] });
                    self.paste_len = 0;
                    self.paste_over = false;
                }
            },
        }
    }

    fn ground(self: *Parser, b: u8, sink: anytype) void {
        switch (b) {
            0x1b => self.state = .esc,
            '\r', '\n' => sink.onKey(.enter),
            '\t' => sink.onKey(.tab),
            0x7f, 0x08 => sink.onKey(.backspace),
            0x00, 0x1c...0x1f => {},
            0x01...0x07, 0x0b...0x0c, 0x0e...0x1a => sink.onKey(.{ .ctrl = b + 'a' - 1 }),
            0x20...0x7e => sink.onKey(.{ .char = b }),
            0x80...0xff => {
                const want: u3 = if (b & 0xe0 == 0xc0) 2 else if (b & 0xf0 == 0xe0) 3 else if (b & 0xf8 == 0xf0) 4 else 0;
                if (want == 0) {
                    sink.onKey(.{ .char = 0xFFFD });
                } else {
                    self.utf8[0] = b;
                    self.utf8_len = 1;
                    self.utf8_want = want;
                    self.state = .utf8;
                }
            },
        }
    }

    fn csi(self: *Parser, final: u8, sink: anytype) void {
        const p = self.params[0..self.params_len];
        // First and second numeric parameter (the second may be "N:event").
        var it = std.mem.splitScalar(u8, p, ';');
        const first = it.next() orelse "";
        const n1: ?u32 = std.fmt.parseInt(u32, first, 10) catch null;
        switch (final) {
            'A' => sink.onKey(.up),
            'B' => sink.onKey(.down),
            'C' => sink.onKey(.right),
            'D' => sink.onKey(.left),
            'F' => sink.onKey(.end),
            'H' => sink.onKey(.home),
            'P' => sink.onKey(.{ .f = 1 }),
            'Q' => sink.onKey(.{ .f = 2 }),
            'S' => sink.onKey(.{ .f = 4 }),
            'Z' => sink.onKey(.backtab),
            '~' => {
                const n = n1 orelse return;
                const k: Key = switch (n) {
                    1, 7 => .home,
                    2 => .insert,
                    3 => .delete,
                    4, 8 => .end,
                    5 => .page_up,
                    6 => .page_down,
                    11 => .{ .f = 1 },
                    12 => .{ .f = 2 },
                    13 => .{ .f = 3 },
                    14 => .{ .f = 4 },
                    15 => .{ .f = 5 },
                    17 => .{ .f = 6 },
                    18 => .{ .f = 7 },
                    19 => .{ .f = 8 },
                    20 => .{ .f = 9 },
                    21 => .{ .f = 10 },
                    23 => .{ .f = 11 },
                    24 => .{ .f = 12 },
                    200 => {
                        self.state = .paste;
                        self.paste_len = 0;
                        self.paste_over = false;
                        return;
                    },
                    else => return,
                };
                sink.onKey(k);
            },
            else => {}, // 'R' (cursor reports), 'u', mouse and the rest: ignored
        }
    }
};

const Collector = struct {
    list: std.ArrayList(Key) = .empty,
    pastes: std.ArrayList([]u8) = .empty,
    fn onKey(self: *Collector, k: Key) void {
        switch (k) {
            .paste => |s| {
                const copy = std.testing.allocator.dupe(u8, s) catch @panic("oom");
                self.pastes.append(std.testing.allocator, copy) catch @panic("oom");
                self.list.append(std.testing.allocator, .{ .paste = copy }) catch @panic("oom");
            },
            else => self.list.append(std.testing.allocator, k) catch @panic("oom"),
        }
    }
    fn deinit(self: *Collector) void {
        for (self.pastes.items) |p| std.testing.allocator.free(p);
        self.pastes.deinit(std.testing.allocator);
        self.list.deinit(std.testing.allocator);
    }
};

fn expectKeys(input: []const u8, expected: []const Key) !void {
    const p = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    var c: Collector = .{};
    defer c.deinit();
    p.feed(input, &c);
    p.flushPending(&c);
    try std.testing.expectEqual(expected.len, c.list.items.len);
    for (expected, c.list.items) |e, g| try std.testing.expectEqualDeep(e, g);
}

test "keys: legacy sequences" {
    try expectKeys("\x1b[A\x1b[B\x1b[C\x1b[D", &.{ .up, .down, .right, .left });
    try expectKeys("\x1b[H\x1b[F\x1b[1~\x1b[4~\x1bOH\x1bOF", &.{ .home, .end, .home, .end, .home, .end });
    try expectKeys("\x1b[5~\x1b[6~\x1b[3~\x1b[2~", &.{ .page_up, .page_down, .delete, .insert });
    try expectKeys("\x1bOP\x1bOQ\x1bOR\x1bOS", &.{ .{ .f = 1 }, .{ .f = 2 }, .{ .f = 3 }, .{ .f = 4 } });
    try expectKeys("\x1b[15~\x1b[17~\x1b[18~\x1b[19~\x1b[20~\x1b[21~\x1b[23~\x1b[24~", &.{ .{ .f = 5 }, .{ .f = 6 }, .{ .f = 7 }, .{ .f = 8 }, .{ .f = 9 }, .{ .f = 10 }, .{ .f = 11 }, .{ .f = 12 } });
    try expectKeys("\x1b[1;5A\x1b[1;2H", &.{ .up, .home }); // modifiers map to the base key
    try expectKeys("\x1b[Z", &.{.backtab});
    try expectKeys("\x7f\x08\r\n\t", &.{ .backspace, .backspace, .enter, .enter, .tab });
    try expectKeys("\x03\x0c\x1a", &.{ .{ .ctrl = 'c' }, .{ .ctrl = 'l' }, .{ .ctrl = 'z' } });
    try expectKeys("a\xc3\xa9\xe4\xb8\xad", &.{ .{ .char = 'a' }, .{ .char = 0xe9 }, .{ .char = 0x4e2d } });
    try expectKeys("\xff", &.{.{ .char = 0xFFFD }});
}

test "keys: lone ESC" {
    try expectKeys("\x1b", &.{.escape});
    try expectKeys("\x1b\x1b", &.{ .escape, .escape });
}

test "keys: sequence split across feeds" {
    const p = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    var c: Collector = .{};
    defer c.deinit();
    p.feed("\x1b", &c);
    p.feed("[", &c);
    try std.testing.expectEqual(@as(usize, 0), c.list.items.len);
    p.feed("A", &c);
    try std.testing.expectEqual(@as(usize, 1), c.list.items.len);
    try std.testing.expectEqualDeep(Key.up, c.list.items[0]);
}

test "keys: bracketed paste" {
    const p = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    var c: Collector = .{};
    defer c.deinit();
    p.feed("\x1b[200~hello\nworld", &c);
    p.feed("\x1b[201~x", &c);
    try std.testing.expectEqual(@as(usize, 2), c.list.items.len);
    try std.testing.expectEqualStrings("hello\nworld", c.list.items[0].paste);
    try std.testing.expectEqualDeep(Key{ .char = 'x' }, c.list.items[1]);

    // Capped at 64 KiB.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    try big.appendSlice(std.testing.allocator, "\x1b[200~");
    try big.appendNTimes(std.testing.allocator, 'z', max_paste + 1000);
    try big.appendSlice(std.testing.allocator, "\x1b[201~");
    p.feed(big.items, &c);
    try std.testing.expectEqual(@as(usize, 3), c.list.items.len);
    try std.testing.expectEqual(@as(usize, max_paste), c.list.items[2].paste.len);
}

fn fuzzKeys(input: []const u8) anyerror!void {
    const p = try std.testing.allocator.create(Parser);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    var c: Collector = .{};
    defer c.deinit();
    p.feed(input, &c);
    p.flushPending(&c);
    // Bounded: never more keys than bytes.
    try std.testing.expect(c.list.items.len <= input.len);
    try std.testing.expect(p.params_len <= p.params.len);
}

test "fuzz: console key parser" {
    const fuzz = @import("fuzz");
    try fuzz.bytes(fuzzKeys, &.{ "\x1b[A", "\x1b[200~abc\x1b[201~", "\x1bOP", "\x1b[1;5H\x03", "\xe4\xb8\xad" });
}
