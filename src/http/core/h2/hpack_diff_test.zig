//! Differential tests (PLAN §5.3 item 5): our HPACK decoder against
//! nghttp2's inflater (nghttp2_hd_inflate_hd3) in lockstep on the same
//! blocks, one pair per connection: the same field lists, or both an
//! error, and the same dynamic table after every block; and our encoder's
//! output through nghttp2's inflater. Intentional divergences:
//! INTENTIONAL.md. Only with -Dhttp2 (the bindings are the engine's).

const std = @import("std");
const c = @import("nghttp2");
const hpack = @import("hpack.zig");
const vectors = @import("hpack_vectors.zig");
const testing = std.testing;
const Field = hpack.Field;
const Buf = vectors.Buf;
const golden = @import("vectors.zig");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Recording (temporary: see conn_diff_test.zig)

/// Collects nghttp2's answers while H2_RECORD is set.
const Rec = struct {
    arena: Allocator,
    conns: std.ArrayList(golden.HpackConn) = .empty,
    blocks: std.ArrayList(golden.BlockRec) = .empty,
    /// Per pair: whether its blocks are kept in the file.
    keep_bytes: bool = true,

    fn begin(arena: Allocator) ?*Rec {
        if (!golden.recording()) return null;
        const r = arena.create(Rec) catch @panic("OOM");
        r.* = .{ .arena = arena };
        return r;
    }

    fn block(r: *Rec, p: *Pair, block_bytes: []const u8, ok: bool, theirs: []const Field) !void {
        var table: golden.Table = .{ .entries = 0, .size = 0, .max_size = 0, .crc = 0 };
        if (ok) {
            const n = c.nghttp2_hd_inflate_get_num_table_entries(p.ng) - hpack.static_table.len;
            var h: std.hash.Crc32 = .init();
            // Oldest entry first: the table entries are newest first.
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                const nv: *const c.nghttp2_nv = c.nghttp2_hd_inflate_get_table_entry(p.ng, hpack.static_table.len + 1 + i);
                golden.tableCrc(&h, nvSlice(nv.name, nv.namelen), nvSlice(nv.value, nv.valuelen));
            }
            table = .{
                .entries = @intCast(n),
                .size = @intCast(c.nghttp2_hd_inflate_get_dynamic_table_size(p.ng)),
                .max_size = @intCast(c.nghttp2_hd_inflate_get_max_dynamic_table_size(p.ng)),
                .crc = h.final(),
            };
        }
        const crcs = try r.arena.alloc(u32, theirs.len);
        var fc: golden.FieldCrc = .{};
        var size: u32 = 0;
        for (crcs, theirs) |*d, t| {
            d.* = fc.add(t.name, t.value, t.never_index);
            size += @intCast(t.name.len + t.value.len + 32);
        }
        try r.blocks.append(r.arena, .{
            .block = .make(if (r.keep_bytes) try r.arena.dupe(u8, block_bytes) else block_bytes, r.keep_bytes),
            .ok = ok,
            .list_size = size,
            .crcs = crcs,
            .table = table,
        });
    }

    fn endConn(r: *Rec, limit: u32) !void {
        try r.conns.append(r.arena, .{ .limit = limit, .blocks = try r.blocks.toOwnedSlice(r.arena) });
    }

    fn write(r: *Rec, conns: []const golden.HpackConn, name: []const u8) !void {
        _ = r;
        const bytes = try golden.writeHpack(testing.allocator, conns);
        defer testing.allocator.free(bytes);
        try golden.recordFile(name, bytes);
    }
};

/// Large enough that the list limit never fires on these inputs: every
/// field is emitted, as nghttp2 does. The second limit is a realistic one,
/// which refuses blocks (INTENTIONAL.md 1-3).
const scratch_len = 1 << 20;
const limits = [_]u32{ scratch_len, 4096 };

/// One connection's decoders.
const Pair = struct {
    a: std.mem.Allocator,
    ng: *c.nghttp2_hd_inflater,
    ours: *hpack.Decoder,
    scratch: []u8,
    /// The decoded list limit passed to `block`.
    limit: u32 = scratch_len,
    /// Both failed, or ours ended the connection (INTENTIONAL.md 2, 3).
    done: bool = false,
    blocks: usize = 0,
    rec: ?*Rec = null,
    /// Blocks our limit refused, and those whose `skipRest` completed
    /// (the tables then compared).
    refused: usize = 0,
    skipped: usize = 0,

    fn init(a: std.mem.Allocator, limit: u32) !Pair {
        var ng: ?*c.nghttp2_hd_inflater = null;
        if (c.nghttp2_hd_inflate_new(&ng) != 0) return error.OutOfMemory;
        const ours = try a.create(hpack.Decoder);
        ours.* = .init(.{});
        return .{ .a = a, .ng = ng.?, .ours = ours, .scratch = try a.alloc(u8, scratch_len), .limit = limit };
    }

    fn deinit(p: *Pair) void {
        c.nghttp2_hd_inflate_del(p.ng);
        p.a.destroy(p.ours);
        p.a.free(p.scratch);
    }

    /// Decodes `block` on both sides and compares.
    fn feed(p: *Pair, block: []const u8) !void {
        if (p.done) return;
        p.blocks += 1;
        var arena: std.heap.ArenaAllocator = .init(p.a);
        defer arena.deinit();
        const a = arena.allocator();
        var theirs: std.ArrayList(Field) = .empty;
        const ng_ok = try p.ngDecode(a, block, &theirs);
        if (p.rec) |r| try r.block(p, block, ng_ok, theirs.items);
        var mine: std.ArrayList(Field) = .empty;
        var b = p.ours.block(block, p.scratch, p.limit);
        const our_err: ?hpack.Error = while (true) {
            const f = (b.next() catch |err| break err) orelse break null;
            try mine.append(a, .{ .name = try a.dupe(u8, f.name), .value = try a.dupe(u8, f.value), .never_index = f.never_index });
        };
        errdefer std.debug.print("hpack diff: block {d} of the pair, nghttp2 {s}, ours {?t}: \"{f}\"\n", .{ p.blocks, if (ng_ok) "ok" else "error", our_err, std.zig.fmtString(block) });
        if (if (our_err) |e| e == error.HeaderListTooLarge else false) {
            // Our limit (INTENTIONAL.md 1): our fields are a prefix of
            // nghttp2's, its list is over the limit (unless it failed inside
            // the refused field), and the rest of the block still decodes
            // for the table, or ends the connection (INTENTIONAL.md 2, 3).
            try testing.expect(mine.items.len <= theirs.items.len);
            try expectPrefix(theirs.items, mine.items);
            if (ng_ok) {
                var size: u64 = 0;
                for (theirs.items) |t| size += t.name.len + t.value.len + 32;
                try testing.expect(size > p.limit);
                try testing.expect(mine.items.len < theirs.items.len);
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
            try testing.expectEqual(theirs.items.len, mine.items.len);
            try expectPrefix(theirs.items, mine.items);
        }
        if (!ng_ok) {
            p.done = true;
            return;
        }
        try p.expectSameTable();
    }

    fn ngDecode(p: *Pair, a: std.mem.Allocator, block: []const u8, out: *std.ArrayList(Field)) !bool {
        var in = block;
        while (true) {
            var nv: c.nghttp2_nv = undefined;
            var flags: c_int = 0;
            const rv = c.nghttp2_hd_inflate_hd3(p.ng, &nv, &flags, in.ptr, in.len, 1);
            if (rv < 0) {
                try testing.expectEqual(c.NGHTTP2_ERR_HEADER_COMP, rv);
                return false;
            }
            in = in[@intCast(rv)..];
            if (flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) try out.append(a, .{
                .name = try a.dupe(u8, nvSlice(nv.name, nv.namelen)),
                .value = try a.dupe(u8, nvSlice(nv.value, nv.valuelen)),
                .never_index = nv.flags & c.NGHTTP2_NV_FLAG_NO_INDEX != 0,
            });
            if (flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
                _ = c.nghttp2_hd_inflate_end_headers(p.ng);
                return true;
            }
        }
    }

    fn expectSameTable(p: *Pair) !void {
        const n = c.nghttp2_hd_inflate_get_num_table_entries(p.ng) - hpack.static_table.len;
        try testing.expectEqual(n, p.ours.tableLen());
        try testing.expectEqual(c.nghttp2_hd_inflate_get_dynamic_table_size(p.ng), p.ours.size);
        try testing.expectEqual(c.nghttp2_hd_inflate_get_max_dynamic_table_size(p.ng), p.ours.max_size);
        var buf: [hpack.table_capacity]u8 = undefined;
        for (0..n) |i| {
            const nv: *const c.nghttp2_nv = c.nghttp2_hd_inflate_get_table_entry(p.ng, hpack.static_table.len + 1 + i);
            const e = p.ours.tableEntry(i, &buf);
            try testing.expectEqualStrings(nvSlice(nv.name, nv.namelen), e.name);
            try testing.expectEqualStrings(nvSlice(nv.value, nv.valuelen), e.value);
        }
    }
};

fn expectPrefix(theirs: []const Field, mine: []const Field) !void {
    for (theirs[0..mine.len], mine) |t, m| {
        try testing.expectEqualStrings(t.name, m.name);
        try testing.expectEqualStrings(t.value, m.value);
        try testing.expectEqual(t.never_index, m.never_index);
    }
}

fn nvSlice(ptr: [*c]u8, len: usize) []const u8 {
    return if (len == 0) "" else ptr[0..len];
}

test "h2 hpack diff: RFC 7541 vectors and nghttp2's test blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = Rec.begin(a);
    for (vectors.rfc_groups) |g| {
        var p: Pair = try .init(testing.allocator, scratch_len);
        defer p.deinit();
        p.rec = rec;
        defer if (rec) |x| x.endConn(scratch_len) catch @panic("record");
        for (g.vectors, 0..) |v, i| {
            var b: Buf = .init(a);
            // Both decoders start at 4096: C.5/C.6's 256 comes as an update.
            if (i == 0 and g.max_table_size != 4096) try b.sizeUpdate(g.max_table_size);
            const bytes = try a.alloc(u8, v.hex.len / 2);
            try b.bytes(try std.fmt.hexToBytes(bytes, v.hex));
            try p.feed(try b.take());
        }
    }
    for (try vectors.portedCases(a)) |case| {
        var p: Pair = try .init(testing.allocator, scratch_len);
        defer p.deinit();
        p.rec = rec;
        defer if (rec) |x| x.endConn(scratch_len) catch @panic("record");
        for (case.blocks) |blk| try p.feed(blk);
    }
    if (rec) |x| try x.write(x.conns.items, "hpack_vectors.bin");
}

test "h2 hpack diff: real header blocks from nghttp2's fuzz corpus" {
    // tools/extract_hpack_blocks.py: u32 connections; per connection a
    // u32 block count, then u32 length + bytes per block.
    const data = @embedFile("testdata/hpack_blocks.bin");
    var rec_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer rec_arena.deinit();
    const rec = Rec.begin(rec_arena.allocator());
    if (rec) |x| x.keep_bytes = false;
    for (limits) |limit| {
        var pos: usize = 0;
        const conns = readU32(data, &pos);
        var blocks: usize = 0;
        for (0..conns) |_| {
            var p: Pair = try .init(testing.allocator, limit);
            defer p.deinit();
            p.rec = rec;
            for (0..readU32(data, &pos)) |_| {
                const n = readU32(data, &pos);
                try p.feed(data[pos..][0..n]);
                pos += n;
                blocks += 1;
            }
            if (rec) |x| try x.endConn(limit);
        }
        try testing.expectEqual(data.len, pos);
        try testing.expect(blocks >= 300);
    }
    if (rec) |x| try x.write(x.conns.items, "hpack_corpus.bin");
}

fn readU32(data: []const u8, pos: *usize) u32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

/// A pool small enough that names and values repeat (dynamic-table hits).
const pool_names = [_][]const u8{ ":method", ":path", ":authority", "cookie", "user-agent", "x-trace", "accept", "content-type", "x-a", "x-bb" };
const pool_values = [_][]const u8{ "GET", "/", "/index.html", "example.com", "a=1; b=2", "curl/8.0", "text/html", "", "0123456789abcdef0123456789abcdef" };

fn randomString(a: std.mem.Allocator, r: std.Random, pool: []const []const u8) ![]const u8 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => blk: {
            const s = try a.alloc(u8, r.uintAtMost(usize, 300));
            r.bytes(s);
            break :blk s;
        },
        1 => blk: {
            const s = try a.alloc(u8, 1500 + r.uintAtMost(usize, 3000));
            @memset(s, 'a' + r.uintLessThan(u8, 26));
            break :blk s;
        },
        else => pool[r.uintLessThan(usize, pool.len)],
    };
}

/// A block of random representations against a table of `table_len`
/// entries: indexed, literals of the three kinds on static, dynamic or new
/// names, Huffman or raw, size updates at the start. About one in 200 is
/// invalid (an index of 0 or past the table, a size update past 4096 or
/// after a field), so most connections run many blocks. Dynamic indexes
/// are only used while the table is known not to have shrunk: before any
/// size update or insertion in the block.
fn generate(a: std.mem.Allocator, r: std.Random, table_len: usize) ![]u8 {
    var b: Buf = .init(a);
    var dynamic = table_len;
    if (r.uintLessThan(u8, 6) == 0) {
        for (0..1 + r.uintLessThan(usize, 2)) |_| {
            try b.sizeUpdate(if (rare(r)) 4097 + r.uintAtMost(u64, 100) else r.uintAtMost(u64, 4096));
        }
        dynamic = 0;
    }
    for (0..r.uintAtMost(usize, 12)) |_| {
        const max_idx = hpack.static_table.len + dynamic;
        const idx: u64 = if (rare(r)) (if (r.boolean()) 0 else max_idx + 1 + r.uintAtMost(u64, 3)) else 1 + r.uintLessThan(u64, max_idx);
        if (r.uintLessThan(u8, 5) < 2) {
            try b.indexed(idx);
        } else {
            const mode: Buf.Mode = @fromBackingInt(@intCast(r.uintLessThan(u2, 3)));
            const name_idx = if (r.boolean()) 0 else idx;
            try b.literal(mode, name_idx, try randomString(a, r, &pool_names), try randomString(a, r, &pool_values));
            if (mode == .with) dynamic = 0;
        }
        if (rare(r)) try b.sizeUpdate(r.uintAtMost(u64, 4096));
    }
    return b.take();
}

fn rare(r: std.Random) bool {
    return r.uintLessThan(u8, 200) == 0;
}

/// Bit flips, a byte set, truncation, an extra byte, as fuzz.zig's.
fn mutate(r: std.Random, block: []u8) []u8 {
    if (block.len == 0) return block;
    switch (r.uintLessThan(u8, 4)) {
        0 => block[r.uintLessThan(usize, block.len)] ^= @as(u8, 1) << r.int(u3),
        1 => block[r.uintLessThan(usize, block.len)] = r.int(u8),
        2 => return block[0..r.uintLessThan(usize, block.len)],
        else => block[block.len - 1] = 0xff,
    }
    return block;
}

/// Slots of the 50 recorded, at the first limit only: nghttp2's answers don't
/// depend on ours (temporary).
const frozen_slots = 3;

test "h2 hpack diff: 5000 generated blocks with table churn, and nghttp2's deflater" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x6870616b);
    const r = prng.random();
    var rec_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer rec_arena.deinit();
    const rec = Rec.begin(rec_arena.allocator());
    for (limits) |limit| {
        // Per kind (0 nghttp2's deflater, 1 the generator): blocks fed,
        // connections that ended, and those that ran 20 blocks or more.
        var fed: [2]usize = .{ 0, 0 };
        var errors: [2]usize = .{ 0, 0 };
        var long: [2]usize = .{ 0, 0 };
        var refused: usize = 0;
        var skipped: usize = 0;
        for (0..50) |slot| {
            const kind = slot % 2;
            // 100 blocks per slot: a connection that ends is replaced.
            var left: usize = 100;
            while (left > 0) {
                var p: Pair = try .init(testing.allocator, limit);
                defer p.deinit();
                if (slot < frozen_slots and limit == scratch_len) p.rec = rec;
                defer if (p.rec) |x| x.endConn(limit) catch @panic("record");
                var deflater: ?*c.nghttp2_hd_deflater = null;
                try testing.expectEqual(0, c.nghttp2_hd_deflate_new(&deflater, 4096));
                defer c.nghttp2_hd_deflate_del(deflater);
                while (left > 0 and !p.done) : (left -= 1) {
                    _ = arena.reset(.retain_capacity);
                    const a = arena.allocator();
                    // nghttp2's deflater (with indexing, the dynamic table
                    // churning) with a mutation now and then, or ours.
                    const block = if (kind == 0) blk: {
                        if (r.uintLessThan(u8, 20) == 0) try testing.expectEqual(0, c.nghttp2_hd_deflate_change_table_size(deflater, r.uintAtMost(usize, 4096)));
                        var nva: [16]c.nghttp2_nv = undefined;
                        const n = r.uintAtMost(usize, nva.len);
                        for (nva[0..n]) |*nv| {
                            const name = try randomString(a, r, &pool_names);
                            const value = try randomString(a, r, &pool_values);
                            nv.* = .{ .name = @constCast(name.ptr), .namelen = name.len, .value = @constCast(value.ptr), .valuelen = value.len, .flags = @intCast(if (r.uintLessThan(u8, 10) == 0) c.NGHTTP2_NV_FLAG_NO_INDEX else c.NGHTTP2_NV_FLAG_NONE) };
                        }
                        const out = try a.alloc(u8, c.nghttp2_hd_deflate_bound(deflater, &nva[0], n));
                        const rv = c.nghttp2_hd_deflate_hd(deflater, out.ptr, out.len, &nva[0], n);
                        try testing.expect(rv >= 0);
                        const enc = out[0..@intCast(rv)];
                        break :blk if (r.uintLessThan(u8, 25) == 0) mutate(r, enc) else enc;
                    } else blk: {
                        const g = try generate(a, r, p.ours.tableLen());
                        break :blk if (r.uintLessThan(u8, 20) == 0) mutate(r, g) else g;
                    };
                    try p.feed(block);
                    fed[kind] += 1;
                }
                if (p.done) errors[kind] += 1;
                if (p.blocks >= 20) long[kind] += 1;
                refused += p.refused;
                skipped += p.skipped;
            }
        }
        errdefer std.debug.print("hpack diff: limit {d}, fed {any}, ended {any}, long {any}, refused {d}, skipped {d}\n", .{ limit, fed, errors, long, refused, skipped });
        // Every block ran and both kinds hit errors. Without the limit
        // firing, many connections went a long way on one decoder; with
        // it, blocks were refused and some of them completed skipRest and
        // compared tables (most of the rest end in HeaderBlockTooCostly).
        try testing.expectEqual(.{ 2500, 2500 }, fed);
        for (errors) |e| try testing.expect(e > 0);
        if (limit == scratch_len) {
            try testing.expectEqual(0, refused);
            for (long) |l| try testing.expect(l >= 30);
        } else try testing.expect(refused >= 1000 and skipped >= 500);
    }
    if (rec) |x| try x.write(x.conns.items, "hpack_generated.bin");
}

fn listBytes(fields: []const Field) usize {
    var n: usize = 0;
    for (fields) |f| n += f.name.len + f.value.len;
    return n;
}

test "h2 hpack diff: our encoder through nghttp2's inflater" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x656e63);
    const r = prng.random();
    var cases: std.ArrayList(golden.EncCase) = .empty;
    const record = golden.recording();
    // A peer at the default, one that lowered SETTINGS_HEADER_TABLE_SIZE
    // to 0 and one at 1024: nghttp2 then requires a size update first.
    for ([_]?usize{ null, 0, 1024 }) |settings| {
        var ng: ?*c.nghttp2_hd_inflater = null;
        try testing.expectEqual(0, c.nghttp2_hd_inflate_new(&ng));
        defer c.nghttp2_hd_inflate_del(ng);
        if (settings) |s| try testing.expectEqual(0, c.nghttp2_hd_inflate_change_table_size(ng, s));
        var p: Pair = .{ .a = testing.allocator, .ng = ng.?, .ours = undefined, .scratch = undefined };
        var e: hpack.Encoder = .{};
        var lists: std.ArrayList([]const Field) = .empty;
        const a = arena.allocator();
        for (vectors.rfc_groups) |g| for (g.vectors) |v| try lists.append(a, v.fields);
        for (0..300) |_| {
            const fields = try a.alloc(Field, r.uintAtMost(usize, 10));
            for (fields) |*f| f.* = .{
                .name = try randomString(a, r, &pool_names),
                .value = try randomString(a, r, &pool_values),
                .never_index = r.uintLessThan(u8, 8) == 0,
            };
            try lists.append(a, fields);
        }
        var rec_blocks: std.ArrayList([]const u8) = .empty;
        var rec_never: std.ArrayList(u32) = .empty;
        var rec_lists: std.ArrayList([]const Field) = .empty;
        // Twice: the second pass encodes the memoized fields from the
        // thread's memo.
        for (0..2) |pass| for (lists.items) |fields| {
            const out = try a.alloc(u8, hpack.Encoder.bound(fields));
            const n = try e.encode(out, fields);
            var got: std.ArrayList(Field) = .empty;
            try testing.expect(try p.ngDecode(a, out[0..n], &got));
            if (record and pass == 0 and rec_lists.items.len < 40 and listBytes(fields) <= 1200) {
                try rec_lists.append(a, fields);
                try rec_blocks.append(a, try a.dupe(u8, out[0..n]));
                var mask: u32 = 0;
                for (got.items, 0..) |g, i| mask |= @as(u32, @intFromBool(g.never_index)) << @intCast(i);
                try rec_never.append(a, mask);
            }
            try testing.expectEqual(fields.len, got.items.len);
            for (fields, got.items) |w, g| {
                try testing.expectEqualStrings(w.name, g.name);
                try testing.expectEqualStrings(w.value, g.value);
                // Never-indexed exactly when nghttp2's deflater would.
                const never = w.never_index or std.mem.eql(u8, w.name, "authorization") or
                    (std.mem.eql(u8, w.name, "cookie") and w.value.len < 20);
                try testing.expectEqual(never, g.never_index);
            }
            // Nothing was ever inserted.
            try testing.expectEqual(hpack.static_table.len, c.nghttp2_hd_inflate_get_num_table_entries(ng));
        };
        try testing.expectEqual(0, c.nghttp2_hd_inflate_get_max_dynamic_table_size(ng));
        if (record) try cases.append(a, .{
            .setting = if (settings) |s| @intCast(s) else -1,
            .lists = rec_lists.items,
            .blocks = rec_blocks.items,
            .never = rec_never.items,
        });
    }
    if (record) {
        const bytes = try golden.writeEncoder(testing.allocator, cases.items);
        defer testing.allocator.free(bytes);
        try golden.recordFile("encoder.bin", bytes);
    }
}
