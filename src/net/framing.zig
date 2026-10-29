//! How a raw TCP listener cuts its input into messages, and how a message is
//! framed on the way out (design-net.md §2.1): lines, length prefixes and
//! varints. Sans-IO: a `Decoder` is fed the bytes of one read burst and
//! gives back every whole frame in it, keeping a partial one between bursts
//! in a heap buffer of its own, so a connection with nothing complete can
//! park with no stack and no reader window.
//!
//! The semantics follow Netty's `LineBasedFrameDecoder` and
//! `LengthFieldBasedFrameDecoder`, the reference for these two; nothing in
//! Zig's ecosystem decodes frames across reads.
const std = @import("std");

/// How a TCP listener cuts its input into messages (and `sendFrame` its
/// output). `.none`: bytes as they arrive (`data`).
pub const Framing = union(enum) {
    none,
    /// Lines ending in "\n"; the "\n" is not part of the frame, nor a "\r"
    /// before it with `strip_cr`. A line longer than `max` bytes (without
    /// its end) closes the connection (reason `.frame`). `sendFrame` appends
    /// "\n" (or "\r\n" with `crlf`).
    lines: Lines,
    /// A length before each frame: `bytes` of 1, 2 or 4, in `endian`;
    /// `includes_header`: the length counts its own bytes. A frame longer
    /// than `max` closes the connection. `sendFrame` writes the prefix.
    length: Length,
    /// A LEB128 varint length before each frame (protobuf's
    /// writeDelimitedTo, many game protocols). At most 5 bytes of length.
    varint: Varint,

    pub const Lines = struct { max: u32 = 64 * 1024, strip_cr: bool = true, crlf: bool = false };
    pub const Length = struct { bytes: u8 = 4, endian: std.builtin.Endian = .big, includes_header: bool = false, max: u32 = 1 << 20 };
    pub const Varint = struct { max: u32 = 1 << 20 };

    /// The most any framing's `max` may be.
    pub const max_limit: u32 = 1 << 30;

    pub const Error = error{InvalidFraming};

    /// Length `bytes` of 1, 2 or 4, and a `max` of 1 to 1 GiB.
    pub fn validate(f: Framing) Error!void {
        switch (f) {
            .none => {},
            .lines => |l| if (l.max == 0 or l.max > max_limit) return error.InvalidFraming,
            .length => |l| {
                if (l.bytes != 1 and l.bytes != 2 and l.bytes != 4) return error.InvalidFraming;
                if (l.max == 0 or l.max > max_limit) return error.InvalidFraming;
            },
            .varint => |v| if (v.max == 0 or v.max > max_limit) return error.InvalidFraming,
        }
    }

    /// The `max` of the framing (0 for `.none`).
    pub fn maxFrame(f: Framing) u32 {
        return switch (f) {
            .none => 0,
            .lines => |l| l.max,
            .length => |l| l.max,
            .varint => |v| v.max,
        };
    }

    /// The most bytes a frame's prefix takes.
    pub const max_prefix = 5;

    pub const EncodeError = error{ FrameTooLarge, NoFraming };

    /// What goes before a payload of `len` bytes, written into `buf`: the
    /// length prefix, or nothing for lines.
    pub fn prefix(f: Framing, len: usize, buf: *[max_prefix]u8) EncodeError![]const u8 {
        switch (f) {
            .none => return error.NoFraming,
            .lines => |l| {
                if (len > l.max) return error.FrameTooLarge;
                return buf[0..0];
            },
            .length => |l| {
                if (len > l.max) return error.FrameTooLarge;
                const total: u64 = len + @as(u64, if (l.includes_header) l.bytes else 0);
                switch (l.bytes) {
                    1 => {
                        if (total > std.math.maxInt(u8)) return error.FrameTooLarge;
                        buf[0] = @intCast(total);
                    },
                    2 => {
                        if (total > std.math.maxInt(u16)) return error.FrameTooLarge;
                        std.mem.writeInt(u16, buf[0..2], @intCast(total), l.endian);
                    },
                    else => {
                        if (total > std.math.maxInt(u32)) return error.FrameTooLarge;
                        std.mem.writeInt(u32, buf[0..4], @intCast(total), l.endian);
                    },
                }
                return buf[0..l.bytes];
            },
            .varint => |v| {
                if (len > v.max) return error.FrameTooLarge;
                var n: usize = 0;
                var rest: u64 = len;
                while (true) {
                    const low: u8 = @intCast(rest & 0x7f);
                    rest >>= 7;
                    if (rest == 0) {
                        buf[n] = low;
                        n += 1;
                        break;
                    }
                    buf[n] = low | 0x80;
                    n += 1;
                }
                return buf[0..n];
            },
        }
    }

    /// What goes after a payload: the line end, or nothing.
    pub fn suffix(f: Framing) []const u8 {
        return switch (f) {
            .lines => |l| if (l.crlf) "\r\n" else "\n",
            else => "",
        };
    }

    /// The bytes a frame of `len` payload bytes takes in all.
    pub fn framedLen(f: Framing, len: usize) usize {
        var buf: [max_prefix]u8 = undefined;
        const p = f.prefix(len, &buf) catch return len;
        return p.len + len + f.suffix().len;
    }
};

/// The frames of one burst, in order: what a callbacks handler's `message`
/// is called with, one by one (`Input.frames`).
pub const FrameIterator = struct {
    frames: []const []const u8 = &.{},
    at: usize = 0,

    pub fn next(it: *FrameIterator) ?[]const u8 {
        if (it.at >= it.frames.len) return null;
        defer it.at += 1;
        return it.frames[it.at];
    }

    /// Frames in this burst.
    pub fn count(it: *const FrameIterator) u32 {
        return @intCast(it.frames.len);
    }
};

/// Cuts a byte stream into frames, across bursts.
pub const Decoder = struct {
    framing: Framing,
    gpa: std.mem.Allocator,
    /// The start of the frame being gathered (its prefix included), when a
    /// burst ended inside one.
    carry: std.ArrayList(u8) = .empty,
    /// The frame `feed` last returned out of `carry`: dropped by the next
    /// call.
    carry_served: bool = false,
    /// Where the start of the next frame waits while `carry` still holds
    /// the frame just returned.
    spill: std.ArrayList(u8) = .empty,

    pub const Error = error{ FrameTooLarge, InvalidFrame, OutOfMemory };

    /// A carry buffer past this is freed once it empties.
    const keep_capacity = 4096;

    pub fn init(gpa: std.mem.Allocator, framing: Framing) Decoder {
        return .{ .framing = framing, .gpa = gpa };
    }

    pub fn deinit(d: *Decoder) void {
        d.carry.deinit(d.gpa);
        d.spill.deinit(d.gpa);
        d.* = undefined;
    }

    /// Whether a partial frame is held.
    pub fn pending(d: *const Decoder) bool {
        return d.pendingLen() != 0;
    }

    /// Bytes of the partial frame held.
    pub fn pendingLen(d: *const Decoder) usize {
        return if (d.carry_served) d.spill.items.len else d.carry.items.len;
    }

    /// Drops the frame returned last, and moves what waited behind it in.
    fn clearCarry(d: *Decoder) void {
        d.carry.clearRetainingCapacity();
        d.carry_served = false;
        std.mem.swap(std.ArrayList(u8), &d.carry, &d.spill);
        if (d.spill.capacity > keep_capacity) d.spill.shrinkAndFree(d.gpa, 0);
    }

    /// Where the unfinished start of a frame goes.
    fn stash(d: *Decoder) *std.ArrayList(u8) {
        return if (d.carry_served) &d.spill else &d.carry;
    }

    /// Appends every whole frame of `input` (the burst's bytes, after
    /// what an earlier call left unfinished) to `out`, and keeps the
    /// unfinished rest. The frames are slices of `input`, or for the first
    /// of them possibly of the decoder's own buffer; all are valid until
    /// the next `feed` or `deinit`. On an error `out` holds the frames
    /// before the bad one, and the decoder is not to be used again.
    pub fn feed(d: *Decoder, input: []const u8, out: *std.ArrayList([]const u8), out_gpa: std.mem.Allocator) Error!void {
        if (d.carry_served) d.clearCarry();
        var at: usize = 0;
        // Finish the frame a burst before left half done.
        if (d.carry.items.len != 0) {
            const used = try d.complete(input);
            at = used.consumed;
            if (used.frame) |f| {
                try out.append(out_gpa, f);
                d.carry_served = true;
            } else return; // all of `input` went into the carry
        }
        switch (d.framing) {
            .none => unreachable,
            .lines => |l| try feedLines(d, l, input, &at, out, out_gpa),
            .length, .varint => try feedPrefixed(d, input, &at, out, out_gpa),
        }
    }

    const Completed = struct { consumed: usize, frame: ?[]const u8 };

    /// Moves bytes of `input` into the carry until it holds a whole frame.
    fn complete(d: *Decoder, input: []const u8) Error!Completed {
        var at: usize = 0;
        switch (d.framing) {
            .none => unreachable,
            .lines => |l| {
                const limit: usize = @as(usize, l.max) + @intFromBool(l.strip_cr); // room for the "\r"
                if (std.mem.indexOfScalar(u8, input, '\n')) |nl| {
                    if (d.carry.items.len + nl > limit) return error.FrameTooLarge;
                    try d.carry.appendSlice(d.gpa, input[0..nl]);
                    var line = d.carry.items;
                    if (l.strip_cr and line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                    if (line.len > l.max) return error.FrameTooLarge;
                    return .{ .consumed = nl + 1, .frame = line };
                }
                if (d.carry.items.len + input.len > limit) return error.FrameTooLarge;
                try d.carry.appendSlice(d.gpa, input);
                return .{ .consumed = input.len, .frame = null };
            },
            .length, .varint => {
                while (true) {
                    switch (try parseHeader(d.framing, d.carry.items)) {
                        .need => |more| {
                            // Header bytes, one at a time for a varint.
                            const take = @min(more, input.len - at);
                            try d.carry.appendSlice(d.gpa, input[at..][0..take]);
                            at += take;
                            if (take < more) return .{ .consumed = at, .frame = null };
                        },
                        .frame => |h| {
                            const total = h.header + h.payload;
                            if (d.carry.items.len < total) {
                                try d.carry.ensureTotalCapacity(d.gpa, total);
                                const take = @min(total - d.carry.items.len, input.len - at);
                                d.carry.appendSliceAssumeCapacity(input[at..][0..take]);
                                at += take;
                            }
                            if (d.carry.items.len < total) return .{ .consumed = at, .frame = null };
                            return .{ .consumed = at, .frame = d.carry.items[h.header..total] };
                        },
                    }
                }
            },
        }
    }

    fn feedLines(d: *Decoder, l: Framing.Lines, input: []const u8, at: *usize, out: *std.ArrayList([]const u8), out_gpa: std.mem.Allocator) Error!void {
        const limit: usize = @as(usize, l.max) + @intFromBool(l.strip_cr);
        while (at.* < input.len) {
            const rest = input[at.*..];
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                if (rest.len > limit) return error.FrameTooLarge;
                try d.stash().appendSlice(d.gpa, rest);
                at.* = input.len;
                return;
            };
            var line = rest[0..nl];
            if (l.strip_cr and line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len > l.max) return error.FrameTooLarge;
            try out.append(out_gpa, line);
            at.* += nl + 1;
        }
    }

    fn feedPrefixed(d: *Decoder, input: []const u8, at: *usize, out: *std.ArrayList([]const u8), out_gpa: std.mem.Allocator) Error!void {
        while (at.* < input.len) {
            const rest = input[at.*..];
            switch (try parseHeader(d.framing, rest)) {
                .need => {
                    try d.stash().appendSlice(d.gpa, rest);
                    at.* = input.len;
                    return;
                },
                .frame => |h| {
                    const total = h.header + h.payload;
                    if (rest.len < total) {
                        const hold = d.stash();
                        try hold.ensureTotalCapacity(d.gpa, total);
                        hold.appendSliceAssumeCapacity(rest);
                        at.* = input.len;
                        return;
                    }
                    try out.append(out_gpa, rest[h.header..total]);
                    at.* += total;
                },
            }
        }
    }
};

const Header = union(enum) {
    /// This many more bytes are needed to read the header.
    need: usize,
    frame: struct { header: usize, payload: usize },
};

/// The header at the start of `bytes`: how long it is and how long the
/// payload, or how many more bytes it needs.
fn parseHeader(f: Framing, bytes: []const u8) Decoder.Error!Header {
    switch (f) {
        .length => |l| {
            if (bytes.len < l.bytes) return .{ .need = l.bytes - bytes.len };
            const value: u64 = switch (l.bytes) {
                1 => bytes[0],
                2 => std.mem.readInt(u16, bytes[0..2], l.endian),
                else => std.mem.readInt(u32, bytes[0..4], l.endian),
            };
            if (l.includes_header and value < l.bytes) return error.InvalidFrame;
            const payload = if (l.includes_header) value - l.bytes else value;
            if (payload > l.max) return error.FrameTooLarge;
            return .{ .frame = .{ .header = l.bytes, .payload = @intCast(payload) } };
        },
        .varint => |v| {
            var value: u64 = 0;
            var i: usize = 0;
            while (true) : (i += 1) {
                if (i >= bytes.len) return .{ .need = 1 };
                if (i >= 5) return error.InvalidFrame;
                const b = bytes[i];
                // The fifth byte holds bits 28 to 34; only 32 bits are used.
                if (i == 4 and b & 0x70 != 0) return error.InvalidFrame;
                value |= @as(u64, b & 0x7f) << @intCast(7 * i);
                if (b & 0x80 == 0) break;
            }
            if (value > v.max) return error.FrameTooLarge;
            return .{ .frame = .{ .header = i + 1, .payload = @intCast(value) } };
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Tests: no I/O, every split of the input.

const testing = std.testing;

/// Feeds `input` to a fresh decoder split at `cuts` (ascending), returning
/// the frames, copied, each followed by '|'.
fn run(gpa: std.mem.Allocator, framing: Framing, input: []const u8, cuts: []const usize) ![]u8 {
    var d: Decoder = .init(gpa, framing);
    defer d.deinit();
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    var at: usize = 0;
    for (cuts, 0..) |cut, i| {
        _ = i;
        const end = @min(cut, input.len);
        try feedPiece(&d, gpa, input[at..end], &frames, &joined);
        at = end;
    }
    try feedPiece(&d, gpa, input[at..], &frames, &joined);
    return joined.toOwnedSlice(gpa);
}

fn feedPiece(d: *Decoder, gpa: std.mem.Allocator, piece: []const u8, frames: *std.ArrayList([]const u8), joined: *std.ArrayList(u8)) !void {
    frames.clearRetainingCapacity();
    try d.feed(piece, frames, gpa);
    for (frames.items) |f| {
        try joined.appendSlice(gpa, f);
        try joined.append(gpa, '|');
    }
}

fn expectEverySplit(framing: Framing, input: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    // One piece, and every single cut and every pair of cuts.
    {
        const got = try run(gpa, framing, input, &.{});
        defer gpa.free(got);
        try testing.expectEqualStrings(expected, got);
    }
    for (0..input.len + 1) |a| {
        const got = try run(gpa, framing, input, &.{a});
        defer gpa.free(got);
        try testing.expectEqualStrings(expected, got);
        for (a..input.len + 1) |b| {
            const got2 = try run(gpa, framing, input, &.{ a, b });
            defer gpa.free(got2);
            try testing.expectEqualStrings(expected, got2);
        }
    }
}

test "framing: lines split at LF at any read boundary, CR stripped unless strip_cr is off" {
    try expectEverySplit(.{ .lines = .{} }, "a\nb\r\nc", "a|b|");
    try expectEverySplit(.{ .lines = .{} }, "a\n\nb\n", "a||b|");
    // Without strip_cr the "\r" stays.
    try expectEverySplit(.{ .lines = .{ .strip_cr = false } }, "a\nb\r\nc", "a|b\r|");
}

test "framing: a line over max closes" {
    const gpa = testing.allocator;
    var d: Decoder = .init(gpa, .{ .lines = .{ .max = 4 } });
    defer d.deinit();
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    try d.feed("abcde", &frames, gpa); // could still be "abcd\r"
    try testing.expectError(error.FrameTooLarge, d.feed("f", &frames, gpa));
    // A line of exactly max, with its "\r", is fine.
    var ok: Decoder = .init(gpa, .{ .lines = .{ .max = 4 } });
    defer ok.deinit();
    try ok.feed("abcd\r\n", &frames, gpa);
    try testing.expectEqualStrings("abcd", frames.items[0]);
    // Over max across pieces.
    var split: Decoder = .init(gpa, .{ .lines = .{ .max = 4 } });
    defer split.deinit();
    frames.clearRetainingCapacity();
    try split.feed("abc", &frames, gpa);
    try testing.expectError(error.FrameTooLarge, split.feed("def\n", &frames, gpa));
    var raw: Decoder = .init(gpa, .{ .lines = .{ .max = 4, .strip_cr = false } });
    defer raw.deinit();
    try testing.expectError(error.FrameTooLarge, raw.feed("abcde", &frames, gpa));
}

test "framing: length prefixes of 1, 2 and 4 bytes in either byte order decode at any split, with max and header-inclusive lengths enforced" {
    // Two frames and an empty one: 1-byte, big endian.
    try expectEverySplit(.{ .length = .{ .bytes = 1 } }, "\x02hi\x00\x03abc", "hi||abc|");
    try expectEverySplit(.{ .length = .{ .bytes = 2 } }, "\x00\x02hi\x00\x01x", "hi|x|");
    try expectEverySplit(.{ .length = .{ .bytes = 2, .endian = .little } }, "\x02\x00hi\x01\x00x", "hi|x|");
    try expectEverySplit(.{ .length = .{ .bytes = 4 } }, "\x00\x00\x00\x03abc\x00\x00\x00\x00", "abc||");
    try expectEverySplit(.{ .length = .{ .bytes = 4, .endian = .little } }, "\x03\x00\x00\x00abc", "abc|");
    // The length counts itself.
    try expectEverySplit(.{ .length = .{ .bytes = 2, .includes_header = true } }, "\x00\x04hi\x00\x02", "hi||");

    const gpa = testing.allocator;
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    // Over max.
    var big: Decoder = .init(gpa, .{ .length = .{ .bytes = 1, .max = 3 } });
    defer big.deinit();
    try testing.expectError(error.FrameTooLarge, big.feed("\x04abcd", &frames, gpa));
    // A length below its own header.
    var low: Decoder = .init(gpa, .{ .length = .{ .bytes = 2, .includes_header = true } });
    defer low.deinit();
    try testing.expectError(error.InvalidFrame, low.feed("\x00\x01", &frames, gpa));
}

test "framing: varint prefixes decode at any split, and a sixth length byte or a length over max is refused" {
    // 0, 1 byte "x", 127 would be long: test the prefixes through encoding.
    const gpa = testing.allocator;
    const f: Framing = .{ .varint = .{ .max = 1 << 22 } };
    for ([_]usize{ 0, 1, 127, 128, 16383, 16384, 1 << 21 }) |n| {
        var pbuf: [Framing.max_prefix]u8 = undefined;
        const prefix = try f.prefix(n, &pbuf);
        const wire = try gpa.alloc(u8, prefix.len + n);
        defer gpa.free(wire);
        @memcpy(wire[0..prefix.len], prefix);
        @memset(wire[prefix.len..], 'z');
        var d: Decoder = .init(gpa, f);
        defer d.deinit();
        var frames: std.ArrayList([]const u8) = .empty;
        defer frames.deinit(gpa);
        // In 7-byte pieces.
        var at: usize = 0;
        while (at < wire.len) {
            const end = @min(at + 7, wire.len);
            try d.feed(wire[at..end], &frames, gpa);
            at = end;
        }
        try testing.expectEqual(@as(usize, 1), frames.items.len);
        try testing.expectEqual(n, frames.items[0].len);
    }
    try expectEverySplit(.{ .varint = .{} }, "\x01a\x00\x02bc", "a||bc|");
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    // Six bytes of length.
    var d: Decoder = .init(gpa, .{ .varint = .{} });
    defer d.deinit();
    try testing.expectError(error.InvalidFrame, d.feed("\x80\x80\x80\x80\x80\x01", &frames, gpa));
    // Over max.
    var m: Decoder = .init(gpa, .{ .varint = .{ .max = 10 } });
    defer m.deinit();
    try testing.expectError(error.FrameTooLarge, m.feed("\x0b", &frames, gpa));
}

test "framing: a frame straddling bursts is carried, then delivered whole" {
    const gpa = testing.allocator;
    const f: Framing = .{ .length = .{ .bytes = 4 } };
    const payload = try gpa.alloc(u8, 40 * 1024);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try wire.appendSlice(gpa, &.{ 0, 0, 0xa0, 0 });
    try wire.appendSlice(gpa, payload);
    var d: Decoder = .init(gpa, f);
    defer d.deinit();
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    var at: usize = 0;
    while (at < wire.items.len) {
        const end = @min(at + 16 * 1024, wire.items.len);
        try d.feed(wire.items[at..end], &frames, gpa);
        at = end;
        if (at < wire.items.len) {
            try testing.expectEqual(@as(usize, 0), frames.items.len);
            try testing.expect(d.pending());
        }
    }
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    try testing.expectEqualSlices(u8, payload, frames.items[0]);
    // Dropped by the next feed, and the big buffer freed.
    frames.clearRetainingCapacity();
    try d.feed("", &frames, gpa);
    try testing.expect(!d.pending());
    try testing.expectEqual(@as(usize, 0), d.carry.capacity);
}

test "framing: encodePrefix round-trips through the decoder" {
    const gpa = testing.allocator;
    const all = [_]Framing{
        .{ .lines = .{} },
        .{ .lines = .{ .crlf = true } },
        .{ .length = .{ .bytes = 1, .max = 200 } },
        .{ .length = .{ .bytes = 2, .endian = .little } },
        .{ .length = .{ .bytes = 4, .includes_header = true } },
        .{ .varint = .{} },
    };
    for (all) |f| {
        try f.validate();
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(gpa);
        for ([_][]const u8{ "hello", "", "x" }) |payload| {
            var pbuf: [Framing.max_prefix]u8 = undefined;
            try wire.appendSlice(gpa, try f.prefix(payload.len, &pbuf));
            try wire.appendSlice(gpa, payload);
            try wire.appendSlice(gpa, f.suffix());
        }
        const got = try run(gpa, f, wire.items, &.{3});
        defer gpa.free(got);
        try testing.expectEqualStrings("hello||x|", got);
    }
}

test "framing: validate and encode limits" {
    try testing.expectError(error.InvalidFraming, (Framing{ .length = .{ .bytes = 3 } }).validate());
    try testing.expectError(error.InvalidFraming, (Framing{ .lines = .{ .max = 0 } }).validate());
    try testing.expectError(error.InvalidFraming, (Framing{ .varint = .{ .max = Framing.max_limit + 1 } }).validate());
    var pbuf: [Framing.max_prefix]u8 = undefined;
    try testing.expectError(error.FrameTooLarge, (Framing{ .length = .{ .bytes = 1, .max = 200 } }).prefix(201, &pbuf));
    try testing.expectError(error.NoFraming, (Framing{ .none = {} }).prefix(1, &pbuf));
}

fn fuzzCheck(input: []const u8) anyerror!void {
    const gpa = testing.allocator;
    if (input.len == 0) return;
    // The first byte picks the framing and the split.
    const pick = input[0];
    const data = input[1..];
    const f: Framing = switch (pick % 6) {
        0 => .{ .lines = .{ .max = 16 } },
        1 => .{ .lines = .{ .max = 16, .strip_cr = false } },
        2 => .{ .length = .{ .bytes = 1, .max = 16 } },
        3 => .{ .length = .{ .bytes = 2, .endian = .little, .includes_header = true, .max = 16 } },
        4 => .{ .varint = .{ .max = 16 } },
        else => .{ .length = .{ .bytes = 4, .max = 16 } },
    };
    const piece: usize = 1 + (pick / 6) % 9;
    var d: Decoder = .init(gpa, f);
    defer d.deinit();
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(gpa);
    var at: usize = 0;
    var delivered: usize = 0;
    while (at < data.len) {
        const end = @min(at + piece, data.len);
        frames.clearRetainingCapacity();
        d.feed(data[at..end], &frames, gpa) catch return; // an error ends it: fine
        for (frames.items) |fr| {
            // Never a frame over max.
            try testing.expect(fr.len <= f.maxFrame());
            var pbuf: [Framing.max_prefix]u8 = undefined;
            delivered += (f.prefix(fr.len, &pbuf) catch unreachable).len + fr.len + f.suffix().len;
        }
        at = end;
    }
    // Frames with their delimiters never come to more than the input.
    try testing.expect(delivered <= data.len);
}

test "fuzz: net framing" {
    const fuzz = @import("../fuzz.zig");
    try fuzz.bytes(fuzzCheck, &.{
        "\x00a\nb\r\nc\n",
        "\x02\x03abc\x00\x01z",
        "\x04\x02ab\x00\x03xyz",
        "\x01a\r\n\r\nlong line that goes past sixteen bytes\n",
        "\x05\x00\x00\x00\x02hi\x00\x00\x00\x00",
        "\x03\x00\x04\x00hi",
    });
}
