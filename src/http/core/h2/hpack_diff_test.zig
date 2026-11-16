//! Differential tests (PLAN §5.3 item 5): our HPACK decoder against what
//! nghttp2 1.70.0's inflater (nghttp2_hd_inflate_hd3) did with the same
//! blocks, one connection at a time: the same field lists, or both an
//! error, and the same dynamic table after every block; and our encoder's
//! output accepted by it. nghttp2's side was recorded while the library was
//! still linked (testdata/vectors/README.md; the recorder is in commit
//! 1012aa39) and is replayed here. Intentional divergences: INTENTIONAL.md.

const std = @import("std");
const hpack = @import("hpack.zig");
const vectors = @import("hpack_vectors.zig");
const golden = @import("vectors.zig");
const testing = std.testing;
const Buf = vectors.Buf;

/// Large enough that the list limit never fires on these inputs: every
/// field is emitted, as nghttp2 does. The second limit is a realistic one,
/// which refuses blocks (INTENTIONAL.md 1-3).
const scratch_len = 1 << 20;
const limits = [_]u32{ scratch_len, 4096 };

/// One connection: our decoder, and nghttp2's recorded answer to each block.
const Pair = struct {
    a: std.mem.Allocator,
    ours: *hpack.Decoder,
    scratch: []u8,
    /// The decoded list limit passed to `block`.
    limit: u32 = scratch_len,
    /// nghttp2's inflater on this connection, block by block.
    rec: golden.HpackConn,
    next: usize = 0,
    /// Both failed, or ours ended the connection (INTENTIONAL.md 2, 3).
    done: bool = false,
    blocks: usize = 0,
    /// Blocks our limit refused, and those whose `skipRest` completed
    /// (the tables then compared).
    refused: usize = 0,
    skipped: usize = 0,

    fn init(a: std.mem.Allocator, limit: u32, rec: golden.HpackConn) !Pair {
        const ours = try a.create(hpack.Decoder);
        ours.* = .init(.{});
        return .{ .a = a, .ours = ours, .scratch = try a.alloc(u8, scratch_len), .limit = limit, .rec = rec };
    }

    fn deinit(p: *Pair) void {
        p.a.destroy(p.ours);
        p.a.free(p.scratch);
    }

    /// Decodes the next block and compares with nghttp2's recorded answer,
    /// which must be for these bytes (`supplied` is null when the file has
    /// them).
    fn feed(p: *Pair, supplied: ?[]const u8) !void {
        if (p.done) return;
        if (p.next == p.rec.blocks.len) return error.RecordingExhausted;
        const theirs = p.rec.blocks[p.next];
        p.next += 1;
        const block = try theirs.block.resolve(supplied);
        p.blocks += 1;
        const ng_ok = theirs.ok;
        var arena: std.heap.ArenaAllocator = .init(p.a);
        defer arena.deinit();
        const a = arena.allocator();
        var mine: std.ArrayList(u32) = .empty;
        var size: u64 = 0;
        var crc: golden.FieldCrc = .{};
        var b = p.ours.block(block, p.scratch, p.limit);
        const our_err: ?hpack.Error = while (true) {
            const f = (b.next() catch |err| break err) orelse break null;
            try mine.append(a, crc.add(f.name, f.value, f.never_index));
            size += f.name.len + f.value.len + 32;
        };
        errdefer std.debug.print("hpack diff: block {d} of the pair, nghttp2 {s}, ours {?t}: \"{f}\"\n", .{ p.blocks, if (ng_ok) "ok" else "error", our_err, std.zig.fmtString(block) });
        if (if (our_err) |e| e == error.HeaderListTooLarge else false) {
            // Our limit (INTENTIONAL.md 1): our fields are a prefix of
            // nghttp2's, its list is over the limit (unless it failed inside
            // the refused field), and the rest of the block still decodes
            // for the table, or ends the connection (INTENTIONAL.md 2, 3).
            try testing.expect(mine.items.len <= theirs.crcs.len);
            try testing.expectEqualSlices(u32, theirs.crcs[0..mine.items.len], mine.items);
            if (ng_ok) {
                try testing.expect(theirs.list_size > p.limit);
                try testing.expect(mine.items.len < theirs.crcs.len);
            }
            p.refused += 1;
            const skip_ok = if (b.skipRest()) |_| true else |e| switch (e) {
                error.HeaderBlockTooCostly => {
                    p.done = true;
                    return;
                },
                error.CompressionError => false,
                else => return e,
            };
            try testing.expectEqual(ng_ok, skip_ok);
            if (skip_ok) p.skipped += 1;
        } else {
            if (our_err) |e| try testing.expectEqual(error.CompressionError, e);
            try testing.expectEqual(ng_ok, our_err == null);
            try testing.expectEqualSlices(u32, theirs.crcs, mine.items);
            if (our_err == null) try testing.expectEqual(theirs.list_size, size);
        }
        if (!ng_ok) {
            p.done = true;
            return;
        }
        try p.expectSameTable(theirs.table);
    }

    fn expectSameTable(p: *Pair, t: golden.Table) !void {
        const n = p.ours.tableLen();
        try testing.expectEqual(t.entries, n);
        try testing.expectEqual(t.size, p.ours.size);
        try testing.expectEqual(t.max_size, p.ours.max_size);
        // The entries, oldest first, as recorded.
        var h: std.hash.Crc32 = .init();
        var buf: [hpack.table_capacity]u8 = undefined;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const e = p.ours.tableEntry(i, &buf);
            golden.tableCrc(&h, e.name, e.value);
        }
        try testing.expectEqual(t.crc, h.final());
    }
};

fn readU32(data: []const u8, pos: *usize) u32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

test "h2 hpack diff: RFC 7541 vectors and nghttp2's test blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conns = try golden.readHpack(a, @embedFile("testdata/vectors/hpack_vectors.bin"));
    var ci: usize = 0;
    for (vectors.rfc_groups) |g| {
        var p: Pair = try .init(testing.allocator, scratch_len, conns[ci]);
        ci += 1;
        defer p.deinit();
        for (g.vectors, 0..) |v, i| {
            var b: Buf = .init(a);
            // Both decoders start at 4096: C.5/C.6's 256 comes as an update.
            if (i == 0 and g.max_table_size != 4096) try b.sizeUpdate(g.max_table_size);
            const bytes = try a.alloc(u8, v.hex.len / 2);
            try b.bytes(try std.fmt.hexToBytes(bytes, v.hex));
            try p.feed(try b.take());
        }
        try testing.expect(p.done or p.next == p.rec.blocks.len);
    }
    for (try vectors.portedCases(a)) |case| {
        var p: Pair = try .init(testing.allocator, scratch_len, conns[ci]);
        ci += 1;
        defer p.deinit();
        for (case.blocks) |blk| try p.feed(blk);
        try testing.expect(p.done or p.next == p.rec.blocks.len);
    }
    try testing.expectEqual(conns.len, ci);
}

test "h2 hpack diff: real header blocks from nghttp2's fuzz corpus" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const conns = try golden.readHpack(arena.allocator(), @embedFile("testdata/vectors/hpack_corpus.bin"));
    // tools/extract_hpack_blocks.py: u32 connections; per connection a
    // u32 block count, then u32 length + bytes per block.
    const data = @embedFile("testdata/hpack_blocks.bin");
    var ci: usize = 0;
    for (limits) |limit| {
        var pos: usize = 0;
        const n_conns = readU32(data, &pos);
        var blocks: usize = 0;
        for (0..n_conns) |_| {
            var p: Pair = try .init(testing.allocator, limit, conns[ci]);
            ci += 1;
            defer p.deinit();
            try testing.expectEqual(limit, p.rec.limit);
            const n_blocks = readU32(data, &pos);
            for (0..n_blocks) |_| {
                const n = readU32(data, &pos);
                try p.feed(data[pos..][0..n]);
                pos += n;
                blocks += 1;
            }
            // The blocks after a failure were never fed, nor recorded.
            try testing.expect(p.done or p.next == p.rec.blocks.len);
        }
        try testing.expectEqual(data.len, pos);
        try testing.expect(blocks >= 300);
    }
    try testing.expectEqual(conns.len, ci);
}

test "h2 hpack diff: generated blocks with table churn, and nghttp2's deflater" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The blocks of a few connections (a connection that ended was
    // replaced), made half by nghttp2's deflater, with a mutation now and
    // then; recorded at the first limit. nghttp2's answers don't depend on
    // ours, so the second limit replays them too (the blocks it refuses are
    // the point).
    const conns = try golden.readHpack(arena.allocator(), @embedFile("testdata/vectors/hpack_generated.bin"));
    var total: usize = 0;
    for (conns) |c| total += c.blocks.len;
    try testing.expect(conns.len >= 3);
    try testing.expect(total >= 300);
    for (limits) |limit| {
        var fed: usize = 0;
        var errors: usize = 0;
        var long: usize = 0;
        var refused: usize = 0;
        var skipped: usize = 0;
        for (conns) |c| {
            var p: Pair = try .init(testing.allocator, limit, c);
            defer p.deinit();
            for (c.blocks) |_| {
                if (p.done) break;
                try p.feed(null);
                fed += 1;
            }
            if (p.done) errors += 1;
            if (p.blocks >= 20) long += 1;
            refused += p.refused;
            skipped += p.skipped;
        }
        errdefer std.debug.print("hpack diff: limit {d}, fed {d} of {d}, ended {d}, long {d}, refused {d}, skipped {d}\n", .{ limit, fed, total, errors, long, refused, skipped });
        // Without the limit firing every block ran, some connections ended
        // in an error and many went a long way on one decoder; with it,
        // blocks were refused and some of them completed skipRest and
        // compared tables (most of the rest end in HeaderBlockTooCostly).
        if (limit == scratch_len) {
            try testing.expectEqual(total, fed);
            try testing.expectEqual(0, refused);
            try testing.expect(errors >= 3);
            try testing.expect(long >= 3);
        } else try testing.expect(refused >= 10 and skipped >= 8);
    }
}

test "h2 hpack diff: our encoder through nghttp2's inflater" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 40 lists under three settings of the peer: the default, one that
    // lowered SETTINGS_HEADER_TABLE_SIZE to 0 and one at 1024 (nghttp2 then
    // requires a size update first). These are the bytes nghttp2 accepted
    // (INTENTIONAL.md HPACK 4: the first block opens with a size update to
    // 0); the test checks that our encoder still writes them, and that our
    // decoder, under the same settings, reads them back as nghttp2 did.
    const cases = try golden.readEncoder(a, @embedFile("testdata/vectors/encoder.bin"));
    try testing.expectEqual(3, cases.len);
    try testing.expectEqual(.{ -1, 0, 1024 }, .{ cases[0].setting, cases[1].setting, cases[2].setting });
    const scratch = try a.alloc(u8, scratch_len);
    for (cases) |case| {
        try testing.expect(case.lists.len >= 30);
        var e: hpack.Encoder = .{};
        var uncached: hpack.Encoder = .{};
        var d: hpack.Decoder = .init(.{ .max_table_size = if (case.setting < 0) hpack.table_capacity else @intCast(case.setting) });
        for (case.lists, case.blocks, case.never, 0..) |fields, want, never, li| {
            const out = try a.alloc(u8, hpack.Encoder.bound(fields));
            try testing.expectEqualSlices(u8, want, out[0..try e.encode(out, fields)]);
            try testing.expectEqualSlices(u8, want, out[0..try uncached.encodeUncached(out, fields)]);
            // The first block opens with a size update to 0.
            if (li == 0) try testing.expectEqual(0x20, want[0]);
            var b = d.block(want, scratch, scratch_len);
            for (fields, 0..) |f, i| {
                const got = (try b.next()).?;
                try testing.expectEqualStrings(f.name, got.name);
                try testing.expectEqualStrings(f.value, got.value);
                // Never-indexed as nghttp2 saw it, and exactly when its
                // deflater would.
                try testing.expectEqual((never >> @intCast(i)) & 1 != 0, got.never_index);
                const rule = f.never_index or std.mem.eql(u8, f.name, "authorization") or
                    (std.mem.eql(u8, f.name, "cookie") and f.value.len < 20);
                try testing.expectEqual(rule, got.never_index);
            }
            try testing.expectEqual(null, try b.next());
            // Nothing was ever inserted.
            try testing.expectEqual(0, d.tableLen());
        }
        try testing.expectEqual(0, d.max_size);
    }
}
