//! The zip writer behind `zig build lambda` (std only: no `zip` binary, so
//! the build needs no system tool):
//!
//!   lambda_zip <out.zip> <archive-name>=<path>[:<octal mode>] ...
//!
//! Each entry is a file; a directory is expanded recursively, its files in
//! byte-sorted order, under the archive name. The mode is the Unix
//! permission bits Lambda's unpacker restores (default 644; `bootstrap`
//! needs 755). Entries keep the order given. Every file is deflated, or
//! stored when that is not smaller. The DOS time is fixed at 1980-01-01
//! 00:00, so the same inputs give the same bytes and a rebuild does not
//! trigger a redeploy. No zip64: Lambda caps a package at 250 MB unzipped.
//! Absolute archive names, `..` and backslashes are refused.
const std = @import("std");

pub const Entry = struct {
    /// The path in the archive, '/'-separated, relative.
    name: []const u8,
    data: []const u8,
    /// Permission bits, e.g. 0o755.
    mode: u16 = 0o644,
};

pub const Error = error{ BadName, TooLarge, TooManyEntries } || std.Io.Writer.Error || std.mem.Allocator.Error;

/// 1980-01-01 in MS-DOS date format; time 00:00:00.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
const dos_time: u16 = 0;

fn badName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return true;
    if (std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.indexOfScalar(u8, name, 0) != null) return true;
    if (name.len >= 2 and name[1] == ':') return true;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return true;
    }
    return false;
}

/// Raw deflate of `data`, or null when it would not be smaller.
fn deflate(gpa: std.mem.Allocator, data: []const u8) !?[]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, @max(64, data.len / 2));
    errdefer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&out.writer, window, .raw, .default);
    try c.writer.writeAll(data);
    try c.finish();
    const compressed = try out.toOwnedSlice();
    if (compressed.len >= data.len) {
        gpa.free(compressed);
        return null;
    }
    return compressed;
}

/// Writes the archive. `gpa` holds the compressed data while it is built.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, entries: []const Entry) Error!void {
    if (entries.len > std.math.maxInt(u16)) return error.TooManyEntries;
    var central: std.Io.Writer.Allocating = .init(gpa);
    defer central.deinit();
    var offset: u64 = 0;
    for (entries) |e| {
        if (badName(e.name)) return error.BadName;
        if (e.data.len > std.math.maxInt(u32) or e.name.len > std.math.maxInt(u16)) return error.TooLarge;
        const packed_data = try deflate(gpa, e.data);
        defer if (packed_data) |p| gpa.free(p);
        const body = packed_data orelse e.data;
        const method: u16 = if (packed_data != null) 8 else 0;
        const crc = std.hash.Crc32.hash(e.data);
        const header_offset: u32 = std.math.cast(u32, offset) orelse return error.TooLarge;

        try writeLocal(w, e, method, crc, @intCast(body.len));
        try w.writeAll(body);
        offset += 30 + e.name.len + body.len;

        const c = &central.writer;
        try c.writeInt(u32, 0x02014b50, .little);
        try c.writeInt(u16, (3 << 8) | 20, .little); // made by: Unix, 2.0
        try c.writeInt(u16, 20, .little); // needed
        try c.writeInt(u16, 0, .little); // flags
        try c.writeInt(u16, method, .little);
        try c.writeInt(u16, dos_time, .little);
        try c.writeInt(u16, dos_date, .little);
        try c.writeInt(u32, crc, .little);
        try c.writeInt(u32, @intCast(body.len), .little);
        try c.writeInt(u32, @intCast(e.data.len), .little);
        try c.writeInt(u16, @intCast(e.name.len), .little);
        try c.writeInt(u16, 0, .little); // extra
        try c.writeInt(u16, 0, .little); // comment
        try c.writeInt(u16, 0, .little); // disk
        try c.writeInt(u16, 0, .little); // internal attributes
        try c.writeInt(u32, (@as(u32, 0o100000) | e.mode) << 16, .little);
        try c.writeInt(u32, header_offset, .little);
        try c.writeAll(e.name);
    }
    const cd = central.written();
    const cd_offset = std.math.cast(u32, offset) orelse return error.TooLarge;
    try w.writeAll(cd);
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, @intCast(cd.len), .little);
    try w.writeInt(u32, cd_offset, .little);
    try w.writeInt(u16, 0, .little);
}

fn writeLocal(w: *std.Io.Writer, e: Entry, method: u16, crc: u32, packed_len: u32) !void {
    try w.writeInt(u32, 0x04034b50, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, method, .little);
    try w.writeInt(u16, dos_time, .little);
    try w.writeInt(u16, dos_date, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, packed_len, .little);
    try w.writeInt(u32, @intCast(e.data.len), .little);
    try w.writeInt(u16, @intCast(e.name.len), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeAll(e.name);
}

const Spec = struct { name: []const u8, path: []const u8, mode: u16 };

fn parseSpec(arg: []const u8) !Spec {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadArgument;
    var path = arg[eq + 1 ..];
    var mode: u16 = 0o644;
    if (std.mem.lastIndexOfScalar(u8, path, ':')) |colon| {
        // A trailing :octal; a Windows drive letter is not one (single char before).
        if (std.fmt.parseInt(u16, path[colon + 1 ..], 8)) |m| {
            if (colon > 1) {
                mode = m;
                path = path[0..colon];
            }
        } else |_| {}
    }
    return .{ .name = arg[0..eq], .path = path, .mode = mode };
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: lambda_zip <out.zip> <name>=<path>[:<octal mode>] ...\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    var entries: std.ArrayList(Entry) = .empty;
    for (args[2..]) |arg| {
        const spec = try parseSpec(arg);
        const stat = try cwd.statFile(io, spec.path, .{});
        if (stat.kind != .directory) {
            const data = try cwd.readFileAlloc(io, spec.path, arena, .unlimited);
            try entries.append(arena, .{ .name = spec.name, .data = data, .mode = spec.mode });
            continue;
        }
        var dir = try cwd.openDir(io, spec.path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        const first = entries.items.len;
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const data = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited);
            const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, spec.name, "/"), entry.path });
            try entries.append(arena, .{ .name = name, .data = data, .mode = spec.mode });
        }
        std.mem.sort(Entry, entries.items[first..], {}, lessThan);
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(arena, &out.writer, entries.items);
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = out.written() });
}

// ---- tests ----

const testing = std.testing;

fn build(entries: []const Entry) !std.Io.Writer.Allocating {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try write(testing.allocator, &out.writer, entries);
    return out;
}

test "lambda_zip: round trip through std.zip, with modes" {
    const io = testing.io;
    const text: []const u8 = &@as([2000]u8, @splat('a'));
    const noise = "\x00\x01\x02\xff";
    const entries = [_]Entry{
        .{ .name = "bootstrap", .data = text, .mode = 0o755 },
        .{ .name = "static/a.bin", .data = noise },
        .{ .name = "empty.txt", .data = "" },
    };
    var zip = try build(&entries);
    defer zip.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "out.zip", .data = zip.written() });
    var file = try tmp.dir.openFile(io, "out.zip", .{});
    defer file.close(io);
    var read_buf: [512]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var it = try std.zip.Iterator.init(&reader);
    var seen: usize = 0;
    while (try it.next()) |entry| : (seen += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try entry.getFilename(&reader, &name_buf, .{});
        try testing.expectEqualStrings(entries[seen].name, name);
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try entry.extractTo(&reader, &w);
        try testing.expectEqualStrings(entries[seen].data, w.buffered());
        // Unix mode in the central header's external attributes (offset 38).
        const attrs = std.mem.readInt(u32, zip.written()[entry.header_zip_offset + 38 ..][0..4], .little);
        try testing.expectEqual(@as(u32, 0o100000) | entries[seen].mode, attrs >> 16);
        // Compressible text is deflated; noise, empty and tiny files stored.
        try testing.expectEqual(if (seen == 0) std.zip.CompressionMethod.deflate else .store, entry.compression_method);
        try testing.expectEqual(@as(u16, 0), entry.last_modification_time);
    }
    try testing.expectEqual(entries.len, seen);
}

test "lambda_zip: two runs give identical bytes" {
    const entries = [_]Entry{
        .{ .name = "bootstrap", .data = &@as([1000]u8, @splat('x')), .mode = 0o755 },
        .{ .name = "b", .data = "bb" },
    };
    var a = try build(&entries);
    defer a.deinit();
    var b = try build(&entries);
    defer b.deinit();
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

test "lambda_zip: absolute names, .. and backslashes are refused" {
    for ([_][]const u8{ "/etc/passwd", "../x", "a/../b", "a\\b", "", "a//b", "./a", "C:/x" }) |name| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(error.BadName, write(testing.allocator, &out.writer, &.{.{ .name = name, .data = "x" }}));
    }
}

test "lambda_zip: spec parsing" {
    const a = try parseSpec("bootstrap=zig-out/bin/app:755");
    try testing.expectEqualStrings("bootstrap", a.name);
    try testing.expectEqualStrings("zig-out/bin/app", a.path);
    try testing.expectEqual(@as(u16, 0o755), a.mode);
    const b = try parseSpec("static=public");
    try testing.expectEqual(@as(u16, 0o644), b.mode);
    try testing.expectError(error.BadArgument, parseSpec("nothing"));
}
