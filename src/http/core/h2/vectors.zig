//! The golden vectors of the HTTP/2 differential tests: what nghttp2 1.70.0
//! answered to each input, recorded once while it was still linked
//! (testdata/vectors/README.md), and the reader the tests replay them with.
//!
//! One file per test, all little-endian: a 4-byte magic, a u32 record
//! count, the records. Records are built from u8, u32, i32 and
//! length-prefixed byte strings only (`Reader`, `Writer`); every count and
//! length is checked against what is left, so a truncated or corrupted
//! file is `error.Truncated`, never a panic or a huge allocation.
//!
//!   conn_*.bin    `Group`s: one input fed to Conn and to nghttp2's server
//!                 session, with nghttp2's side of every run (whole and
//!                 cut) recorded as per-`Feed` raw output bytes and state.
//!   hpack_*.bin   `Conn`s: the blocks one connection's nghttp2 inflater
//!                 decoded, with what it emitted and its table after.
//!   fields.bin    One byte per string of fields_test.zig's enumeration,
//!                 one bit per nghttp2_check_* helper.
//!   encoder.bin   `EncCase`s: our encoder's output for field lists, which
//!                 nghttp2's inflater accepted under three table settings.

const std = @import("std");
const hpack = @import("hpack.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ Truncated, BadMagic, OutOfMemory };

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8, magic: *const [4]u8) Error!Reader {
        if (data.len < 4 or !std.mem.eql(u8, data[0..4], magic)) return error.BadMagic;
        return .{ .data = data, .pos = 4 };
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.data.len) return error.Truncated;
        r.pos += 1;
        return r.data[r.pos - 1];
    }

    pub fn int(r: *Reader) Error!u32 {
        if (r.data.len - r.pos < 4) return error.Truncated;
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    /// LEB128, at most 5 bytes.
    pub fn varint(r: *Reader) Error!u32 {
        var v: u64 = 0;
        for (0..5) |i| {
            const b = try r.byte();
            v |= @as(u64, b & 0x7f) << @intCast(7 * i);
            if (b & 0x80 == 0) return std.math.cast(u32, v) orelse error.Truncated;
        }
        return error.Truncated;
    }

    pub fn sint(r: *Reader) Error!i32 {
        return @bitCast(try r.int());
    }

    pub fn flag(r: *Reader) Error!bool {
        return (try r.byte()) != 0;
    }

    /// A length-prefixed byte string, borrowed from the file.
    pub fn bytes(r: *Reader) Error![]const u8 {
        const n = try r.int();
        if (n > r.data.len - r.pos) return error.Truncated;
        r.pos += n;
        return r.data[r.pos - n .. r.pos];
    }

    /// An element count: at most one element per byte left.
    pub fn count(r: *Reader) Error!usize {
        const n = try r.int();
        if (n > r.data.len - r.pos) return error.Truncated;
        return n;
    }

    /// The whole file was read.
    pub fn end(r: *const Reader) Error!void {
        if (r.pos != r.data.len) return error.Truncated;
    }
};

pub const Writer = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, magic: *const [4]u8) !Writer {
        var w: Writer = .{ .gpa = gpa };
        try w.list.appendSlice(gpa, magic);
        return w;
    }

    pub fn deinit(w: *Writer) void {
        w.list.deinit(w.gpa);
    }

    pub fn byte(w: *Writer, v: u8) !void {
        try w.list.append(w.gpa, v);
    }

    pub fn int(w: *Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.list.appendSlice(w.gpa, &b);
    }

    pub fn varint(w: *Writer, v: u32) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try w.byte(@as(u8, @truncate(x)) | 0x80);
        try w.byte(@intCast(x));
    }

    pub fn sint(w: *Writer, v: i32) !void {
        try w.int(@bitCast(v));
    }

    pub fn flag(w: *Writer, v: bool) !void {
        try w.byte(@intFromBool(v));
    }

    pub fn bytes(w: *Writer, v: []const u8) !void {
        try w.int(@intCast(v.len));
        try w.list.appendSlice(w.gpa, v);
    }

    pub fn len(w: *Writer, n: usize) !void {
        try w.int(@intCast(n));
    }
};

fn crc(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

/// An input the test already has (a corpus file, the fuzz seeds): the file
/// keeps its length and CRC-32 to check it against; the others
/// (generated, planted) keep the bytes.
pub const Blob = struct {
    len: u32,
    crc: u32,
    inline_bytes: ?[]const u8,

    pub fn make(bytes: []const u8, keep: bool) Blob {
        return .{ .len = @intCast(bytes.len), .crc = crc(bytes), .inline_bytes = if (keep) bytes else null };
    }

    /// The bytes: the file's own or `supplied`. If both exist they must be
    /// equal, and either must be the ones the vector was recorded for.
    pub fn resolve(b: Blob, supplied: ?[]const u8) error{WrongInput}![]const u8 {
        const bytes = b.inline_bytes orelse supplied orelse return error.WrongInput;
        if (bytes.len != b.len or crc(bytes) != b.crc) return error.WrongInput;
        if (b.inline_bytes != null) if (supplied) |x| if (!std.mem.eql(u8, bytes, x)) return error.WrongInput;
        return bytes;
    }

    fn write(b: Blob, w: *Writer) !void {
        try w.int(b.len);
        try w.int(b.crc);
        try w.flag(b.inline_bytes != null);
        if (b.inline_bytes) |x| try w.bytes(x);
    }

    fn read(r: *Reader) Error!Blob {
        const n = try r.int();
        const c = try r.int();
        return .{ .len = n, .crc = c, .inline_bytes = if (try r.flag()) try r.bytes() else null };
    }
};

// ---------------------------------------------------------------------------
// conn_*.bin

/// nghttp2's side after one `feed`: what it was given, drained, and the
/// state the comparison reads.
pub const Feed = struct {
    /// Bytes given to its mem_recv2 (those Conn consumed; all of them once
    /// Conn has failed).
    ng_in: u32,
    /// Its output, drained until empty.
    out: []const u8,
    /// mem_recv2's error, 0 for none.
    fatal: i32,
    /// nghttp2_session_want_read after the drain.
    want_read: bool,
    /// nghttp2_session_get_last_proc_stream_id after the drain.
    last_proc: u32,
};

/// One lockstep run: the chunk sizes of the input and the feeds they made.
/// A feed is a flags byte (bit 0 want_read, 1 `out` follows, 2 `fatal`
/// follows, 3 `last_proc` follows, as it changed from the feed before),
/// then `ng_in` as a varint: a run of byte-sized cuts makes thousands.
pub const Run = struct { cuts: []const u32, feeds: []const Feed };

/// One input under one profile (conn_diff_test.zig `profiles`), its whole
/// run first, then the cut runs.
pub const Group = struct { profile: u8, input: Blob, runs: []const Run };

pub const conn_magic = "H2VC";

pub fn writeConn(gpa: Allocator, groups: []const Group) ![]u8 {
    var w: Writer = try .init(gpa, conn_magic);
    errdefer w.deinit();
    try w.len(groups.len);
    for (groups) |g| {
        try w.byte(g.profile);
        try g.input.write(&w);
        try w.len(g.runs.len);
        for (g.runs) |run| {
            try w.len(run.cuts.len);
            for (run.cuts) |n| try w.varint(n);
            try w.len(run.feeds.len);
            var before: Feed = .{ .ng_in = 0, .out = "", .fatal = 0, .want_read = false, .last_proc = 0 };
            for (run.feeds) |f| {
                const flags: u8 = @as(u8, @intFromBool(f.want_read)) | @as(u8, @intFromBool(f.out.len > 0)) << 1 |
                    @as(u8, @intFromBool(f.fatal != before.fatal)) << 2 | @as(u8, @intFromBool(f.last_proc != before.last_proc)) << 3;
                try w.byte(flags);
                try w.varint(f.ng_in);
                if (flags & 2 != 0) try w.bytes(f.out);
                if (flags & 4 != 0) try w.sint(f.fatal);
                if (flags & 8 != 0) try w.varint(f.last_proc);
                before = f;
            }
        }
    }
    return w.list.toOwnedSlice(gpa);
}

pub fn readConn(a: Allocator, data: []const u8) Error![]const Group {
    var r: Reader = try .init(data, conn_magic);
    const groups = try a.alloc(Group, try r.count());
    for (groups) |*g| {
        g.profile = try r.byte();
        g.input = try .read(&r);
        const runs = try a.alloc(Run, try r.count());
        for (runs) |*run| {
            const cuts = try a.alloc(u32, try r.count());
            for (cuts) |*n| n.* = try r.varint();
            const feeds = try a.alloc(Feed, try r.count());
            var before: Feed = .{ .ng_in = 0, .out = "", .fatal = 0, .want_read = false, .last_proc = 0 };
            for (feeds) |*f| {
                const flags = try r.byte();
                f.* = before;
                f.want_read = flags & 1 != 0;
                f.ng_in = try r.varint();
                f.out = if (flags & 2 != 0) try r.bytes() else "";
                if (flags & 4 != 0) f.fatal = try r.sint();
                if (flags & 8 != 0) f.last_proc = try r.varint();
                before = f.*;
            }
            run.* = .{ .cuts = cuts, .feeds = feeds };
        }
        g.runs = runs;
    }
    try r.end();
    return groups;
}

// ---------------------------------------------------------------------------
// hpack_*.bin

/// nghttp2's dynamic table after a block that decoded: counts and sizes,
/// and a CRC-32 over the entries (`tableCrc`).
pub const Table = struct { entries: u32, size: u32, max_size: u32, crc: u32 };

/// One block fed to a connection's nghttp2 inflater.
pub const BlockRec = struct {
    block: Blob,
    /// The inflater ended without an error.
    ok: bool,
    /// Its emitted list's size as RFC 7541 §4.1 counts it (name + value +
    /// 32 each).
    list_size: u32,
    /// What it emitted, error or not, as the CRC-32 of the list after each
    /// field (`FieldCrc`): a field's name, value and never-index bit, and
    /// everything before. Long values make the lists the bulk of the file.
    crcs: []const u32,
    /// Only when `ok`.
    table: Table,
};

/// The running CRC-32 of a field list.
pub const FieldCrc = struct {
    h: std.hash.Crc32 = .init(),

    pub fn add(c: *FieldCrc, name: []const u8, value: []const u8, never_index: bool) u32 {
        tableCrc(&c.h, name, value);
        c.h.update(&.{@intFromBool(never_index)});
        return c.h.final();
    }
};

/// One connection: the decoded-list limit our decoder was given (the second
/// limit of hpack_diff_test.zig refuses blocks) and its blocks in order.
pub const HpackConn = struct { limit: u32, blocks: []const BlockRec };

pub const hpack_magic = "H2VH";

/// CRC-32 over a decoder's dynamic table, from its highest index (the oldest
/// entry) down to 0, and the base of `FieldCrc`: name length, name, value
/// length, value (little-endian u32 lengths) for each.
pub fn tableCrc(h: *std.hash.Crc32, name: []const u8, value: []const u8) void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(name.len), .little);
    h.update(&n);
    h.update(name);
    std.mem.writeInt(u32, &n, @intCast(value.len), .little);
    h.update(&n);
    h.update(value);
}

fn writeFields(w: *Writer, fields: []const hpack.Field) !void {
    try w.len(fields.len);
    for (fields) |f| {
        try w.bytes(f.name);
        try w.bytes(f.value);
        try w.flag(f.never_index);
    }
}

fn readFields(a: Allocator, r: *Reader) Error![]const hpack.Field {
    const fields = try a.alloc(hpack.Field, try r.count());
    for (fields) |*f| f.* = .{ .name = try r.bytes(), .value = try r.bytes(), .never_index = try r.flag() };
    return fields;
}

pub fn writeHpack(gpa: Allocator, conns: []const HpackConn) ![]u8 {
    var w: Writer = try .init(gpa, hpack_magic);
    errdefer w.deinit();
    try w.len(conns.len);
    for (conns) |c| {
        try w.int(c.limit);
        try w.len(c.blocks.len);
        for (c.blocks) |b| {
            try b.block.write(&w);
            try w.flag(b.ok);
            try w.int(b.list_size);
            try w.len(b.crcs.len);
            for (b.crcs) |x| try w.int(x);
            try w.int(b.table.entries);
            try w.int(b.table.size);
            try w.int(b.table.max_size);
            try w.int(b.table.crc);
        }
    }
    return w.list.toOwnedSlice(gpa);
}

pub fn readHpack(a: Allocator, data: []const u8) Error![]const HpackConn {
    var r: Reader = try .init(data, hpack_magic);
    const conns = try a.alloc(HpackConn, try r.count());
    for (conns) |*c| {
        c.limit = try r.int();
        const blocks = try a.alloc(BlockRec, try r.count());
        for (blocks) |*b| {
            b.block = try .read(&r);
            b.ok = try r.flag();
            b.list_size = try r.int();
            const crcs = try a.alloc(u32, try r.count());
            for (crcs) |*x| x.* = try r.int();
            b.crcs = crcs;
            b.table = .{ .entries = try r.int(), .size = try r.int(), .max_size = try r.int(), .crc = try r.int() };
        }
        c.blocks = blocks;
    }
    try r.end();
    return conns;
}

// ---------------------------------------------------------------------------
// encoder.bin

/// Our encoder's bytes for `lists`, one block per list in one encoder's
/// life, that nghttp2's inflater accepted with its table limit lowered to
/// `setting` first (-1: left at the default), and what it decoded.
pub const EncCase = struct {
    setting: i32,
    lists: []const []const hpack.Field,
    blocks: []const []const u8,
    /// Which fields nghttp2 decoded as never-indexed, one bit per field
    /// (names and values came back as sent).
    never: []const u32,
};

pub const encoder_magic = "H2VE";

pub fn writeEncoder(gpa: Allocator, cases: []const EncCase) ![]u8 {
    var w: Writer = try .init(gpa, encoder_magic);
    errdefer w.deinit();
    try w.len(cases.len);
    for (cases) |c| {
        try w.sint(c.setting);
        try w.len(c.lists.len);
        for (c.lists, c.blocks, c.never) |l, b, m| {
            try writeFields(&w, l);
            try w.bytes(b);
            try w.int(m);
        }
    }
    return w.list.toOwnedSlice(gpa);
}

pub fn readEncoder(a: Allocator, data: []const u8) Error![]const EncCase {
    var r: Reader = try .init(data, encoder_magic);
    const cases = try a.alloc(EncCase, try r.count());
    for (cases) |*c| {
        c.setting = try r.sint();
        const n = try r.count();
        const lists = try a.alloc([]const hpack.Field, n);
        const blocks = try a.alloc([]const u8, n);
        const never = try a.alloc(u32, n);
        for (lists, blocks, never) |*l, *b, *m| {
            l.* = try readFields(a, &r);
            b.* = try r.bytes();
            m.* = try r.int();
        }
        c.lists = lists;
        c.blocks = blocks;
        c.never = never;
    }
    try r.end();
    return cases;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "h2 vectors: reader and writer round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feeds = [_]Feed{
        .{ .ng_in = 3, .out = "abc", .fatal = 0, .want_read = true, .last_proc = 1 },
        .{ .ng_in = 0, .out = "", .fatal = -903, .want_read = false, .last_proc = 0 },
    };
    const groups = [_]Group{
        .{ .profile = 1, .input = .make("hello", true), .runs = &.{
            .{ .cuts = &.{5}, .feeds = feeds[0..1] },
            .{ .cuts = &.{ 2, 3 }, .feeds = &feeds },
        } },
        .{ .profile = 0, .input = .make("by reference", false), .runs = &.{} },
    };
    const file = try writeConn(testing.allocator, &groups);
    defer testing.allocator.free(file);
    const back = try readConn(a, file);
    try testing.expectEqual(2, back.len);
    try testing.expectEqual(1, back[0].profile);
    try testing.expectEqualStrings("hello", try back[0].input.resolve(null));
    try testing.expectEqual(2, back[0].runs.len);
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, back[0].runs[1].cuts);
    try testing.expectEqualStrings("abc", back[0].runs[1].feeds[0].out);
    try testing.expectEqual(-903, back[0].runs[1].feeds[1].fatal);
    try testing.expect(!back[0].runs[1].feeds[1].want_read);
    // A file-less input must be the one the vector was recorded for.
    try testing.expectEqualStrings("by reference", try back[1].input.resolve("by reference"));
    try testing.expectError(error.WrongInput, back[1].input.resolve("by reference!"));
    try testing.expectError(error.WrongInput, back[1].input.resolve("by referencd"));
    try testing.expectError(error.WrongInput, back[1].input.resolve(null));
    // And a supplied input that is not the recorded inline one.
    try testing.expectEqualStrings("hello", try back[0].input.resolve("hello"));
    try testing.expectError(error.WrongInput, back[0].input.resolve("hellp"));
}

test "h2 vectors: hpack and encoder files round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]hpack.Field{ .{ .name = "a", .value = "b" }, .{ .name = "c", .value = "", .never_index = true } };
    var fc: FieldCrc = .{};
    const crcs = [_]u32{ fc.add("a", "b", false), fc.add("c", "", true) };
    const conns = [_]HpackConn{.{ .limit = 4096, .blocks = &.{.{
        .block = .make("\x82", true),
        .ok = true,
        .list_size = 66,
        .crcs = &crcs,
        .table = .{ .entries = 1, .size = 40, .max_size = 256, .crc = 7 },
    }} }};
    const f1 = try writeHpack(testing.allocator, &conns);
    defer testing.allocator.free(f1);
    const c1 = try readHpack(a, f1);
    try testing.expectEqual(1, c1.len);
    try testing.expectEqualSlices(u32, &crcs, c1[0].blocks[0].crcs);
    try testing.expect(crcs[0] != crcs[1]);
    try testing.expectEqual(66, c1[0].blocks[0].list_size);
    try testing.expectEqual(7, c1[0].blocks[0].table.crc);

    const lists = [_][]const hpack.Field{&fields};
    const cases = [_]EncCase{.{ .setting = 0, .lists = &lists, .blocks = &.{"\x20\x82"}, .never = &.{2} }};
    const f2 = try writeEncoder(testing.allocator, &cases);
    defer testing.allocator.free(f2);
    const c2 = try readEncoder(a, f2);
    try testing.expectEqual(0, c2[0].setting);
    try testing.expectEqualStrings("\x20\x82", c2[0].blocks[0]);
}

test "h2 vectors: a damaged file is an error, not a panic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const groups = [_]Group{.{ .profile = 0, .input = .make("x", true), .runs = &.{
        .{ .cuts = &.{1}, .feeds = &.{.{ .ng_in = 1, .out = "yy", .fatal = 0, .want_read = true, .last_proc = 0 }} },
    } }};
    const file = try writeConn(testing.allocator, &groups);
    defer testing.allocator.free(file);
    try testing.expectError(error.BadMagic, readConn(a, "H2V"));
    try testing.expectError(error.BadMagic, readConn(a, "XXXX\x00\x00\x00\x00"));
    // Every truncation fails.
    for (4..file.len) |n| try testing.expectError(error.Truncated, readConn(a, file[0..n]));
    // Trailing bytes too.
    try testing.expectError(error.Truncated, readConn(a, try std.mem.concat(a, u8, &.{ file, "z" })));
    // A length that runs past the file (the output string's, then a count).
    const bad = try a.dupe(u8, file);
    const out_len_at = std.mem.indexOf(u8, bad, "yy").? - 4;
    std.mem.writeInt(u32, bad[out_len_at..][0..4], 0xffff_fff0, .little);
    try testing.expectError(error.Truncated, readConn(a, bad));
    const huge = try a.dupe(u8, file);
    std.mem.writeInt(u32, huge[4..8], 0xffff_ffff, .little);
    try testing.expectError(error.Truncated, readConn(a, huge));
}
