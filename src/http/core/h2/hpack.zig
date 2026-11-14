// Translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_hd.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! HPACK (RFC 7541): a decoder with the full dynamic table, and an encoder
//! that uses only the static table and literals, its short fields kept
//! encoded in a per-thread memo (`Memo`). No allocation.
//!
//! The decoder takes one complete header block (conn.zig concatenates
//! HEADERS and CONTINUATION first), so nghttp2's 17-state incremental
//! inflater is gone; what is left is its integer and string bounds, its
//! representations and its table. The table is a fixed 4 KiB byte ring
//! inside `Decoder`.
//!
//! **A field is valid until the next `next()`/`skipRest()` call**, as an
//! nghttp2 inflater's is until its next `inflate_hd` call: a table-sourced
//! string points into the ring, which a later insertion reuses. A literal's
//! raw string points into the input block, a Huffman string or a copied
//! table string into the caller's scratch, reused for every field.
//!
//! The decoded header list size (RFC 9113 §6.5.2: name + value + 32 per
//! field) is checked before each field is emitted or copied:
//! `error.HeaderListTooLarge` at the first field that crosses the limit,
//! then `skipRest()` decodes the rest of the block for its table effects
//! (RFC 9113 §4.3, §10.5.1), like Go's `SetEmitEnabled(false)`, up to a
//! cost of twice the limit (INTENTIONAL.md).

const std = @import("std");
const huffman = @import("huffman.zig");

const is_test = @import("builtin").is_test;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
    /// A literal never indexed (RFC 7541 §6.2.3): kept on decode, and asks
    /// the encoder for that representation.
    never_index: bool = false,
};

pub const Error = error{
    /// RFC 9113 §4.3: a connection error of type COMPRESSION_ERROR.
    CompressionError,
    /// The field that crosses `max_list_size`; nothing of it is emitted.
    /// Finish the block with `skipRest()` (the stream is refused, the
    /// connection lives).
    HeaderListTooLarge,
    /// `skipRest()`'s literals past twice `max_list_size`, or a field's
    /// strings larger than the scratch: a connection error
    /// (ENHANCE_YOUR_CALM). The decoder is then unusable.
    HeaderBlockTooCostly,
};

/// Our SETTINGS_HEADER_TABLE_SIZE: the default, never sent. The ring's size.
pub const table_capacity = 4096;
/// RFC 7541 §4.1.
pub const entry_overhead = 32;
/// The longest string literal accepted, before Huffman decoding
/// (NGHTTP2_HD_MAX_NV).
pub const max_string_len = 65536;
const max_entries = table_capacity / entry_overhead;

/// RFC 7541 Appendix A (nghttp2's static_table, in index order from 1).
pub const static_table = [_]Field{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

/// A name's first static index (1-based), as nghttp2's lookup_token gives
/// for the static range. Entries sharing a name are adjacent.
const static_names = blk: {
    @setEvalBranchQuota(10_000);
    // SAFETY: only the first `n`, set below, are used.
    var kvs: [static_table.len]struct { []const u8, u8 } = undefined;
    var n: usize = 0;
    for (static_table, 1..) |f, i| {
        if (n > 0 and std.mem.eql(u8, kvs[n - 1][0], f.name)) continue;
        kvs[n] = .{ f.name, i };
        n += 1;
    }
    const final = kvs[0..n].*;
    break :blk std.StaticStringMap(u8).initComptime(final);
};

/// Decodes an HPACK integer with an N-bit prefix (RFC 7541 §5.1) at
/// `in[pos.*]`, advancing `pos`: nghttp2's decode_length with its caps (a
/// u32 result, a shift of at most 28), for a complete block, so running
/// out of input is an error too.
pub fn decodeInt(in: []const u8, pos: *usize, comptime prefix: u4) error{CompressionError}!u32 {
    const k: u32 = (1 << prefix) - 1;
    var p = pos.*;
    if (p == in.len) return error.CompressionError;
    var n: u32 = in[p] & k;
    p += 1;
    if (n == k) {
        var shift: u32 = 0;
        while (true) : (shift += 7) {
            if (p == in.len) return error.CompressionError;
            const b = in[p];
            p += 1;
            var add: u32 = b & 0x7F;
            if (shift >= 32) return error.CompressionError;
            if ((@as(u32, std.math.maxInt(u32)) >> @intCast(shift)) < add) return error.CompressionError;
            add <<= @intCast(shift);
            if (@as(u32, std.math.maxInt(u32)) - add < n) return error.CompressionError;
            n += add;
            if (b & 0x80 == 0) break;
        }
    }
    pos.* = p;
    return n;
}

pub const Decoder = struct {
    /// The table's strings, name then value per entry, written at `head`;
    /// an entry may wrap past the end. The live bytes are fewer than
    /// `max_size` (RFC sizes count 32 more per entry), so a write never
    /// reaches a live entry once the insertion has evicted.
    /// SAFETY: only live entries' bytes and slots are read, and `insert`
    /// writes both before an entry is live.
    bytes: [table_capacity]u8 = undefined,
    /// SAFETY: as `bytes`.
    entries: [max_entries]Entry = undefined,
    /// The oldest entry's slot; `len` entries follow it, the newest last.
    first: u16 = 0,
    len: u16 = 0,
    head: u16 = 0,
    /// The table's RFC 7541 §4.1 size and maximum (hd_table_bufsize[_max]).
    size: u32 = 0,
    max_size: u32,
    /// The largest size update accepted: our SETTINGS_HEADER_TABLE_SIZE.
    settings_max: u32,
    state: enum { idle, busy, bad } = .idle,

    const Entry = struct { off: u16, name_len: u16, value_len: u16 };

    pub const Options = struct {
        /// ≤ table_capacity. Tests use 256 for RFC 7541 C.5/C.6.
        max_table_size: u32 = table_capacity,
    };

    pub fn init(opts: Options) Decoder {
        std.debug.assert(opts.max_table_size <= table_capacity);
        return .{ .max_size = opts.max_table_size, .settings_max = opts.max_table_size };
    }

    /// Starts decoding the complete header block `input`. `scratch` holds
    /// Huffman-decoded and copied table strings; it must be at least
    /// `max_list_size` and `table_capacity` bytes. A block started while
    /// the previous one is unfinished (it neither returned null nor
    /// completed `skipRest`), or after a CompressionError, fails with
    /// CompressionError, as an nghttp2 inflater stays bad (ctx.bad).
    pub fn block(d: *Decoder, input: []const u8, scratch: []u8, max_list_size: u32) Block {
        std.debug.assert(scratch.len >= max_list_size and scratch.len >= table_capacity);
        d.state = if (d.state == .idle) .busy else .bad;
        return .{ .d = d, .input = input, .scratch = scratch, .max_list_size = max_list_size };
    }

    /// The table's entry count (nghttp2's count less the 61 static ones).
    pub fn tableLen(d: *const Decoder) usize {
        return d.len;
    }

    /// Dynamic entry `i` (0 is the newest, index 62), copied into `buf`
    /// when it wraps. For tests and the differential harness.
    pub fn tableEntry(d: *const Decoder, i: usize, buf: []u8) Field {
        return d.entryField(d.slot(@intCast(i)), buf, true);
    }

    fn slot(d: *const Decoder, i: u16) Entry {
        std.debug.assert(i < d.len);
        return d.entries[(d.first + d.len - 1 - i) % max_entries];
    }

    /// The name and value of `e`: slices of the ring when it doesn't wrap
    /// (and `copy` is false), else copied into `buf`.
    fn entryField(d: *const Decoder, e: Entry, buf: []u8, copy: bool) Field {
        const n = @as(usize, e.name_len) + e.value_len;
        if (!copy and e.off + n <= table_capacity) {
            const s = d.bytes[e.off..][0..n];
            return .{ .name = s[0..e.name_len], .value = s[e.name_len..] };
        }
        d.ringRead(e.off, buf[0..n]);
        return .{ .name = buf[0..e.name_len], .value = buf[e.name_len..n] };
    }

    fn ringRead(d: *const Decoder, off: u16, dst: []u8) void {
        const a = @min(dst.len, table_capacity - off);
        @memcpy(dst[0..a], d.bytes[off..][0..a]);
        @memcpy(dst[a..], d.bytes[0 .. dst.len - a]);
    }

    fn ringWrite(d: *Decoder, src: []const u8) void {
        const a = @min(src.len, table_capacity - d.head);
        @memcpy(d.bytes[d.head..][0..a], src[0..a]);
        @memcpy(d.bytes[0 .. src.len - a], src[a..]);
        d.head = @intCast((d.head + src.len) % table_capacity);
    }

    fn evictOldest(d: *Decoder) void {
        const e = d.entries[d.first];
        d.size -= @as(u32, e.name_len) + e.value_len + entry_overhead;
        d.first = (d.first + 1) % max_entries;
        d.len -= 1;
    }

    /// hd_context_shrink_table_size.
    fn shrink(d: *Decoder) void {
        while (d.size > d.max_size) d.evictOldest();
    }

    /// What add_hd_table_incremental does with an entry larger than the
    /// maximum: evicts everything and inserts nothing.
    fn clear(d: *Decoder) void {
        while (d.len > 0) d.evictOldest();
    }

    /// add_hd_table_incremental: evicts from the oldest until the entry
    /// fits (`room` ≤ `max_size`, see `clear`). `name` and `value` must not
    /// point into the ring.
    fn insert(d: *Decoder, name: []const u8, value: []const u8) void {
        const room = name.len + value.len + entry_overhead;
        std.debug.assert(room <= d.max_size);
        while (d.size + room > d.max_size) d.evictOldest();
        if (d.len == 0) {
            d.first = 0;
            d.head = 0;
        }
        const off = d.head;
        d.ringWrite(name);
        d.ringWrite(value);
        d.entries[(d.first + d.len) % max_entries] = .{ .off = off, .name_len = @intCast(name.len), .value_len = @intCast(value.len) };
        d.len += 1;
        d.size += @intCast(room);
    }
};

pub const Block = struct {
    d: *Decoder,
    input: []const u8,
    scratch: []u8,
    max_list_size: u32,
    pos: usize = 0,
    /// RFC 9113 §6.5.2 size of the fields emitted, then of the literals
    /// skipped.
    list_size: u64 = 0,
    /// A field was decoded: no more size updates (RFC 7541 §4.2).
    fields: bool = false,

    /// The next field, or null at the end of the block (the table is then
    /// consistent and the decoder ready for the next block). Valid until
    /// the next call.
    pub fn next(b: *Block) Error!?Field {
        return b.step(true);
    }

    /// Decodes the rest of the block for its table effects only, from the
    /// field `next()` refused if it did (RFC 9113 §4.3).
    pub fn skipRest(b: *Block) Error!void {
        while (try b.step(false)) |_| {}
    }

    fn step(b: *Block, comptime emit: bool) Error!?Field {
        if (b.d.state != .busy) return error.CompressionError;
        const f = b.decode(emit) catch |err| {
            if (err != error.HeaderListTooLarge) b.d.state = .bad;
            return err;
        };
        if (f == null) b.d.state = .idle;
        return f;
    }

    /// One field (in skip mode: up to the end of the block). Moves `pos`
    /// only past what it fully decoded and applied, so a refused field is
    /// decoded again by `skipRest()`.
    fn decode(b: *Block, comptime emit: bool) Error!?Field {
        const d = b.d;
        const in = b.input;
        while (b.pos < in.len) {
            var p = b.pos;
            const c = in[p];
            if (c & 0xE0 == 0x20) {
                // Dynamic table size update (RFC 7541 §6.3), only at the
                // start of the block.
                if (b.fields) return error.CompressionError;
                const size = try decodeInt(in, &p, 5);
                if (size > d.settings_max) return error.CompressionError;
                d.max_size = size;
                d.shrink();
                b.pos = p;
                continue;
            }
            if (c & 0x80 != 0) {
                const idx = try decodeInt(in, &p, 7);
                const n, const v = try b.lens(idx);
                b.fields = true;
                // Skipping, a reference costs nothing: no copy, no change.
                if (!emit) {
                    b.pos = p;
                    continue;
                }
                try b.charge(n + v, emit);
                b.pos = p;
                return b.indexed(idx, 0);
            }
            // Literals. 0x40, 0x00 and 0x10 exactly are a new name: index 0.
            const indexing = c & 0x40 != 0;
            const never = c & 0xF0 == 0x10;
            const idx = if (indexing) try decodeInt(in, &p, 6) else try decodeInt(in, &p, 4);
            // The most string bytes the field may still take: in emit mode
            // its share of the list budget, in skip mode the scratch.
            const budget = if (emit) (std.math.sub(u64, b.max_list_size, b.list_size + entry_overhead) catch 0) else b.scratch.len;
            var used: usize = 0;
            // A new name, or (set below when needed) the indexed one.
            var name: []const u8 = if (idx == 0) try b.string(&p, &used, budget, emit) else "";
            const name_len = if (idx == 0) name.len else (try b.lens(idx))[0];
            const value = try b.string(&p, &used, budget -| name_len, emit);
            try b.charge(name_len + value.len, emit);
            // An entry larger than the table only empties it (RFC 7541 §4.4).
            const inserts = indexing and name_len + value.len + entry_overhead <= d.max_size;
            if (idx != 0 and (emit or inserts)) {
                // A dynamic name is copied before the insertion can evict
                // or overwrite it (RFC 7541 §4.4), and when it wraps.
                if (inserts and b.scratch.len - used < name_len) return error.HeaderBlockTooCostly;
                name = b.nameOf(idx, used, inserts);
            }
            if (inserts) d.insert(name, value) else if (indexing) d.clear();
            b.pos = p;
            b.fields = true;
            if (emit) return .{ .name = name, .value = value, .never_index = never };
        }
        return null;
    }

    /// An index's name and value lengths; index 0 and one past the table
    /// are errors (get_max_index).
    fn lens(b: *Block, idx: u32) Error!struct { usize, usize } {
        if (idx == 0 or idx > static_table.len + b.d.len) return error.CompressionError;
        if (idx <= static_table.len) {
            const f = static_table[idx - 1];
            return .{ f.name.len, f.value.len };
        }
        const e = b.d.slot(@intCast(idx - static_table.len - 1));
        return .{ e.name_len, e.value_len };
    }

    /// Adds one field's size. Emitting, a field past the limit is refused
    /// before anything of it is emitted or copied; skipping, the literals
    /// (which copy into the scratch and the table) may reach twice the
    /// limit: a 2-byte literal on a 4 KiB dynamic name copies 4 KiB.
    fn charge(b: *Block, strings: usize, comptime emit: bool) Error!void {
        const size = b.list_size + strings + entry_overhead;
        if (emit) {
            if (size > b.max_list_size) return error.HeaderListTooLarge;
        } else {
            if (size > 2 * @as(u64, b.max_list_size)) return error.HeaderBlockTooCostly;
        }
        b.list_size = size;
    }

    fn indexed(b: *Block, idx: u32, at: usize) Field {
        if (idx <= static_table.len) return static_table[idx - 1];
        const e = b.d.slot(@intCast(idx - static_table.len - 1));
        return b.d.entryField(e, b.scratch[at..], false);
    }

    fn nameOf(b: *Block, idx: u32, at: usize, copy: bool) []const u8 {
        if (idx <= static_table.len) return static_table[idx - 1].name;
        const e = b.d.slot(@intCast(idx - static_table.len - 1));
        const n: Decoder.Entry = .{ .off = e.off, .name_len = e.name_len, .value_len = 0 };
        return b.d.entryField(n, b.scratch[at..], copy).name;
    }

    /// A string literal (RFC 7541 §5.2): at most max_string_len bytes and
    /// inside the block; a Huffman one decoded into the scratch at `used`,
    /// at most `limit` bytes (past it the field is over its budget).
    fn string(b: *Block, p: *usize, used: *usize, limit: u64, comptime emit: bool) Error![]const u8 {
        const in = b.input;
        if (p.* == in.len) return error.CompressionError;
        const huff = in[p.*] & 0x80 != 0;
        const n = try decodeInt(in, p, 7);
        if (n > max_string_len or n > in.len - p.*) return error.CompressionError;
        const raw = in[p.*..][0..n];
        p.* += n;
        if (!huff) {
            if (emit and raw.len > limit) return error.HeaderListTooLarge;
            return raw;
        }
        const room = b.scratch[used.*..];
        const dst = room[0..@intCast(@min(room.len, limit))];
        const out = huffman.decode(dst, raw) catch |err| return switch (err) {
            error.InvalidHuffman => error.CompressionError,
            error.NoSpaceLeft => if (emit) error.HeaderListTooLarge else error.HeaderBlockTooCostly,
        };
        used.* += out.len;
        return out;
    }
};

/// The static-only encoder (RFC 7541 §2.3.2: an encoder may leave the
/// dynamic table unused): a static exact match is indexed, anything else a
/// literal without indexing, on a static name or a new one; never indexed
/// for nghttp2's sensitive fields; Huffman when shorter, as nghttp2's
/// emit_string decides.
pub const Encoder = struct {
    /// The connection's first block starts with a size update to 0: an
    /// nghttp2 peer that lowered its SETTINGS_HEADER_TABLE_SIZE requires a
    /// size update (nghttp2_hd.c, inflate_change_table_size), and after 0
    /// no SETTINGS can be below our table again (RFC 7541 §4.2, §6.3).
    size_update_pending: bool = true,

    /// An upper bound on `encode`'s output (nghttp2_hd_deflate_bound).
    pub fn bound(fields: []const Field) usize {
        var n: usize = 12 + 6 * 2 * fields.len;
        for (fields) |f| n += f.name.len + f.value.len;
        return n;
    }

    /// The block for `fields`. Each field's bytes are a pure function of
    /// (name, value, never), so short fields that may be indexed come from
    /// the thread's `memo` when seen before: the same bytes, without the
    /// static-table search and the Huffman passes.
    pub fn encode(e: *Encoder, out: []u8, fields: []const Field) error{NoSpaceLeft}!usize {
        return e.encodeBlock(out, fields, true);
    }

    /// `encode` without the memo, the reference its output is tested
    /// against.
    pub fn encodeUncached(e: *Encoder, out: []u8, fields: []const Field) error{NoSpaceLeft}!usize {
        return e.encodeBlock(out, fields, false);
    }

    /// A `:status` field on its own, the way `encode` writes it (with the
    /// first block's size update) without formatting the digits: the codes
    /// in the static table are one indexed byte (h2o's encode_status,
    /// nginx's ngx_http_v2_header_filter), the rest a literal on its name.
    pub fn encodeStatus(e: *Encoder, out: []u8, code: u16) error{NoSpaceLeft}!usize {
        std.debug.assert(code >= 100 and code <= 999);
        var w: usize = 0;
        if (e.size_update_pending) try putInt(out, &w, 0x20, 5, 0);
        const index: u8 = switch (code) {
            200 => 8,
            204 => 9,
            206 => 10,
            304 => 11,
            400 => 12,
            404 => 13,
            500 => 14,
            else => 0,
        };
        if (index != 0) {
            try putInt(out, &w, 0x80, 7, index);
        } else {
            const digits = [3]u8{ '0' + @as(u8, @intCast(code / 100)), '0' + @as(u8, @intCast(code / 10 % 10)), '0' + @as(u8, @intCast(code % 10)) };
            try putInt(out, &w, 0x00, 4, 8);
            try putString(out, &w, &digits);
        }
        e.size_update_pending = false;
        return w;
    }

    fn encodeBlock(e: *Encoder, out: []u8, fields: []const Field, comptime memoize: bool) error{NoSpaceLeft}!usize {
        var w: usize = 0;
        if (e.size_update_pending) try putInt(out, &w, 0x20, 5, 0);
        for (fields) |f| {
            // deflate_nv's rule, "the same criteria used in Firefox".
            const never = f.never_index or std.mem.eql(u8, f.name, "authorization") or
                (std.mem.eql(u8, f.name, "cookie") and f.value.len < 20);
            // Never-indexed fields (secrets among them) are not kept.
            if (!memoize or never or f.name.len + f.value.len > Memo.key_cap) {
                try encodeField(out, &w, f, never);
                continue;
            }
            const slot = &memo.slots[Memo.index(f)];
            if (slot.holds(f)) {
                if (is_test) memo.hits += 1;
                const enc = slot.enc[0..slot.enc_len];
                if (out.len - w < enc.len) return error.NoSpaceLeft;
                @memcpy(out[w..][0..enc.len], enc);
                w += enc.len;
                continue;
            }
            if (is_test) memo.misses += 1;
            const start = w;
            try encodeField(out, &w, f, never);
            slot.store(f, out[start..w]);
        }
        // Only once the block is whole: a NoSpaceLeft retry still sends it.
        e.size_update_pending = false;
        return w;
    }

    fn encodeField(out: []u8, w: *usize, f: Field, never: bool) error{NoSpaceLeft}!void {
        const first: usize = static_names.get(f.name) orelse 0;
        if (first != 0 and !never) {
            // search_static_table: the exact match among the entries that
            // share the name.
            var i = first;
            const match = while (i <= static_table.len and std.mem.eql(u8, static_table[i - 1].name, f.name)) : (i += 1) {
                if (std.mem.eql(u8, static_table[i - 1].value, f.value)) break i;
            } else 0;
            if (match != 0) return putInt(out, w, 0x80, 7, match);
        }
        try putInt(out, w, if (never) 0x10 else 0x00, 4, first);
        if (first == 0) try putString(out, w, f.name);
        try putString(out, w, f.value);
    }

    /// encode_length with the representation's bits in `first`.
    fn putInt(out: []u8, w: *usize, first: u8, comptime prefix: u4, value: usize) error{NoSpaceLeft}!void {
        const k: usize = (1 << prefix) - 1;
        if (w.* == out.len) return error.NoSpaceLeft;
        if (value < k) {
            out[w.*] = first | @as(u8, @intCast(value));
            w.* += 1;
            return;
        }
        out[w.*] = first | @as(u8, @intCast(k));
        w.* += 1;
        var v = value - k;
        while (true) {
            if (w.* == out.len) return error.NoSpaceLeft;
            if (v < 0x80) {
                out[w.*] = @intCast(v);
                w.* += 1;
                return;
            }
            out[w.*] = @as(u8, @truncate(v)) | 0x80;
            w.* += 1;
            v >>= 7;
        }
    }

    /// emit_string: Huffman iff strictly shorter.
    fn putString(out: []u8, w: *usize, s: []const u8) error{NoSpaceLeft}!void {
        const hlen = huffman.encodedLen(s);
        if (hlen < s.len) {
            try putInt(out, w, 0x80, 7, hlen);
            w.* += (try huffman.encode(out[w.*..], s)).len;
        } else {
            try putInt(out, w, 0x00, 7, s.len);
            if (out.len - w.* < s.len) return error.NoSpaceLeft;
            @memcpy(out[w.*..][0..s.len], s);
            w.* += s.len;
        }
    }
};

/// Encoded fields by (name, value), per thread: 32 direct-mapped slots of
/// about 210 bytes, zero (in .tbss, so resident only once used), shared by
/// every connection the thread serves; nothing is kept per connection. A
/// lookup checks the whole key, so a collision is a miss, never wrong
/// bytes. A miss always replaces the slot. Safe without a lock: `encode`
/// never yields, so one call has the thread's table to itself.
const Memo = struct {
    const slot_count = 32;
    /// name + value bytes of a field kept: the common response fields
    /// (content-type, date, grpc-*) fit, long one-off values don't.
    const key_cap = 96;
    /// A literal on a new name: one index byte, two length bytes (both
    /// lengths < 127) and the key's bytes at most (Huffman only shorter).
    const enc_cap = key_cap + 3;

    slots: [slot_count]Slot = @splat(.{}),
    hits: if (is_test) u32 else void = if (is_test) 0 else {},
    misses: if (is_test) u32 else void = if (is_test) 0 else {},
    stores: if (is_test) u32 else void = if (is_test) 0 else {},

    const Slot = struct {
        /// 0 while empty: a field encodes to at least one byte.
        enc_len: u8 = 0,
        name_len: u8 = 0,
        value_len: u8 = 0,
        key: [key_cap]u8 = @splat(0),
        enc: [enc_cap]u8 = @splat(0),

        fn holds(s: *const Slot, f: Field) bool {
            return s.enc_len != 0 and s.name_len == f.name.len and s.value_len == f.value.len and
                std.mem.eql(u8, s.key[0..s.name_len], f.name) and
                std.mem.eql(u8, s.key[s.name_len..][0..s.value_len], f.value);
        }

        fn store(s: *Slot, f: Field, enc: []const u8) void {
            if (is_test) memo.stores += 1;
            s.name_len = @intCast(f.name.len);
            s.value_len = @intCast(f.value.len);
            @memcpy(s.key[0..f.name.len], f.name);
            @memcpy(s.key[f.name.len..][0..f.value.len], f.value);
            @memcpy(s.enc[0..enc.len], enc);
            s.enc_len = @intCast(enc.len);
        }
    };

    fn index(f: Field) usize {
        const h = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, f.name), f.value);
        return @intCast(h % slot_count);
    }
};

threadlocal var memo: Memo = .{};

/// Tests: the thread's memo counters since the last `memoReset`.
pub fn memoStats() struct { hits: u32, misses: u32, stores: u32 } {
    comptime std.debug.assert(is_test);
    return .{ .hits = memo.hits, .misses = memo.misses, .stores = memo.stores };
}

/// Tests: empties the thread's memo and zeroes its counters.
pub fn memoReset() void {
    comptime std.debug.assert(is_test);
    memo = .{};
}
