//! The static file cache (static_cache.zig) through `Static.serve`, on
//! `std.testing.io`: every read section is in lock mode (the domain's spin
//! lock), and the server allocates through `SpinCheckedAllocator`, so an
//! allocation inside a section panics (L5). The racy check's clock runs
//! 10 s ahead in test builds (`static_cache.test_hooks`), so a file written
//! by the test is cached at once. Linux only, as the cache is.
const std = @import("std");
const dusty = @import("../root.zig");
const safety = @import("anole_safety");
const qsbr = @import("../qsbr.zig");
const test_socket = @import("test_socket.zig");
const static_cache = dusty.static_cache;
const StaticCache = static_cache.StaticCache;

const io = std.testing.io;
const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}

fn requireCache() !void {
    if (!static_cache.supported) return error.SkipZigTest;
}

/// A server running in the background for several requests, each on a
/// connection of its own. Must not move after `init`.
const Live = struct {
    checked: safety.SpinCheckedAllocator,
    server: dusty.Server(void),
    future: ?std.Io.Future(anyerror!void),

    fn init(self: *Live, config: dusty.ServerConfig) void {
        self.checked = .init(std.testing.allocator);
        var c = config;
        c.listeners = loopback;
        self.server = .init(self.checked.allocator(), io, c, {});
        self.future = null;
    }

    fn run(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn start(self: *Live) !void {
        self.future = try io.concurrent(run, .{&self.server});
        try self.server.waitReady(io);
    }

    fn deinit(self: *Live) void {
        if (self.future) |*f| f.cancel(io) catch {};
        self.server.deinit();
    }

    fn cache(self: *Live) *StaticCache {
        return self.server.static_cache.?;
    }

    fn stats(self: *Live) static_cache.Stats {
        return self.cache().stats();
    }

    /// `GET path` (or `method`) with `headers` (each line ending in
    /// "\r\n"); the whole response, read until the server closes.
    fn send(self: *Live, method: []const u8, path: []const u8, headers: []const u8, out: []u8) ![]const u8 {
        var request_buf: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf, "{s} {s} HTTP/1.1\r\nHost: x\r\n{s}Connection: close\r\n\r\n", .{ method, path, headers });
        const stream = try self.server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll(request);
        try writer.interface.flush();
        var read_buf: [1024]u8 = undefined;
        var reader: test_socket.DeadlineReader = .init(stream, io, &read_buf);
        var sink: std.Io.Writer = .fixed(out);
        _ = reader.interface.streamRemaining(&sink) catch |err| switch (err) {
            error.ReadFailed => if (reader.err.? == error.ReadTimedOut) return error.ReadTimedOut,
            error.WriteFailed => return error.ResponseTooLong,
        };
        return sink.buffered();
    }

    fn get(self: *Live, path: []const u8, headers: []const u8, out: []u8) ![]const u8 {
        return self.send("GET", path, headers, out);
    }
};

fn status(response: []const u8) []const u8 {
    return if (response.len >= 12) response[9..12] else "";
}

fn header(response: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) return null;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn body(response: []const u8) []const u8 {
    const end = std.mem.find(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// Rewrites `path` in place with `data` (the same inode) and moves its
/// mtime one second on, so the mtime surely differs.
fn rewrite(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    const before = try dir.statFile(io, path, .{});
    try write(dir, path, data);
    try dir.setTimestamps(io, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = before.mtime.nanoseconds + std.time.ns_per_s } } });
}

const br = "Accept-Encoding: br\r\n";
const gzip = "Accept-Encoding: gzip\r\n";
const br_gzip = "Accept-Encoding: br, gzip\r\n";

test "static cache: a hit sends what the miss did (body, ETag, Last-Modified, Vary, Content-Encoding), with no allocation in a read section" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "style.css", "body { color: red }");
    try write(tmp.dir, "style.css.br", "brotli bytes");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{ .precompressed = &.{ .br, .gzip } });
    try live.start();

    for ([_][]const u8{ "", br }) |accept| {
        var miss_buf: [4096]u8 = undefined;
        var hit_buf: [4096]u8 = undefined;
        const fills = live.stats().fills;
        const hits = live.stats().hits;
        const miss = try live.get("/style.css", accept, &miss_buf);
        const hit = try live.get("/style.css", accept, &hit_buf);
        try std.testing.expectEqual(fills + 1, live.stats().fills);
        try std.testing.expectEqual(hits + 1, live.stats().hits);
        try std.testing.expectEqualStrings("200", status(hit));
        try std.testing.expectEqualStrings(body(miss), body(hit));
        for ([_][]const u8{ "ETag", "Last-Modified", "Vary", "Content-Encoding", "Content-Type", "Content-Length", "Accept-Ranges" }) |name| {
            const a = header(miss, name);
            const b = header(hit, name);
            try std.testing.expectEqual(a == null, b == null);
            if (a) |v| try std.testing.expectEqualStrings(v, b.?);
        }
    }
    // The br request found only the identity copy known.
    try std.testing.expectEqual(@as(u64, 1), live.stats().misses);
}

test "static cache: a file changed in place, replaced by a rename, or set back to its old mtime is served new" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "version 1");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;

    _ = try live.get("/a.txt", "", &out);
    try std.testing.expectEqualStrings("version 1", body(try live.get("/a.txt", "", &out)));
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);

    // The same length, the same inode, another mtime.
    try rewrite(tmp.dir, "a.txt", "version 2");
    try std.testing.expectEqualStrings("version 2", body(try live.get("/a.txt", "", &out)));
    try std.testing.expectEqualStrings("version 2", body(try live.get("/a.txt", "", &out)));

    // Another inode, by rename.
    try write(tmp.dir, "a.tmp", "version 3");
    try tmp.dir.rename("a.tmp", tmp.dir, "a.txt", io);
    try std.testing.expectEqualStrings("version 3", body(try live.get("/a.txt", "", &out)));
    try std.testing.expectEqualStrings("version 3", body(try live.get("/a.txt", "", &out)));

    // The same size and mtime as the cached copy: only ctime tells.
    const before = try tmp.dir.statFile(io, "a.txt", .{});
    try write(tmp.dir, "a.txt", "version 4");
    try tmp.dir.setTimestamps(io, "a.txt", .{ .modify_timestamp = .{ .new = before.mtime } });
    const after = try tmp.dir.statFile(io, "a.txt", .{});
    // A kernel without fine-grained ctime may give both writes one tick.
    if (after.ctime.nanoseconds == before.ctime.nanoseconds) return error.SkipZigTest;
    try std.testing.expectEqualStrings("version 4", body(try live.get("/a.txt", "", &out)));
}

test "static cache: each encoding is checked on its own, so a new .br leaves the cached gzip copy hitting" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "app.js", "plain");
    try write(tmp.dir, "app.js.br", "br v1");
    try write(tmp.dir, "app.js.gz", "gz v1");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{ .precompressed = &.{ .br, .gzip } });
    try live.start();
    var out: [4096]u8 = undefined;

    _ = try live.get("/app.js", br, &out);
    _ = try live.get("/app.js", gzip, &out);
    try rewrite(tmp.dir, "app.js.br", "br v2");
    const hits = live.stats().hits;
    try std.testing.expectEqualStrings("br v2", body(try live.get("/app.js", br, &out)));
    try std.testing.expectEqualStrings("gz v1", body(try live.get("/app.js", gzip, &out)));
    try std.testing.expectEqual(hits + 1, live.stats().hits);
}

/// root/ with app.css and its .gz, beside outside/ with copies.
fn fallbackTree() !struct { tmp: std.testing.TmpDir, root: std.Io.Dir } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    try write(tmp.dir, "outside/app.css", "outside plain");
    try write(tmp.dir, "outside/app.css.br", "outside br");
    const root = try tmp.dir.openDir(io, "root", .{});
    try write(root, "app.css", "inside plain");
    try write(root, "app.css.gz", "inside gz");
    return .{ .tmp = tmp, .root = root };
}

fn startFallback(live: *Live, root: std.Io.Dir) !void {
    live.init(.{});
    live.server.router.static("/", root, .{ .precompressed = &.{ .br, .gzip } });
    try live.start();
}

test "static cache: a .br it can't open (mode 0000, a link out, a directory) falls back to the next copy, which hits" {
    try requireCache();
    var fixture = try fallbackTree();
    defer fixture.tmp.cleanup();
    defer fixture.root.close(io);
    const root = fixture.root;
    var live: Live = undefined;
    try startFallback(&live, root);
    defer live.deinit();
    var out: [4096]u8 = undefined;

    // The hit opens each copy as today's path does, so it skips the .br
    // just as that does, and the gzip copy, filled once, hits.
    // Mode 0000 (unless the tests run as root, which can open it anyway).
    try write(root, "app.css.br", "unreadable br");
    const f = try root.openFile(io, "app.css.br", .{});
    try f.setPermissions(io, @fromBackingInt(0));
    f.close(io);
    const readable = if (root.openFile(io, "app.css.br", .{})) |g| blk: {
        g.close(io);
        break :blk true;
    } else |_| false;
    if (!readable) for (0..2) |_| {
        const got = try live.get("/app.css", br_gzip, &out);
        try std.testing.expectEqualStrings("200", status(got));
        try std.testing.expectEqualStrings("inside gz", body(got));
    };
    try root.deleteFile(io, "app.css.br");

    // A link out of the directory.
    try root.symLink(io, "../outside/app.css.br", "app.css.br", .{});
    for (0..2) |_| try std.testing.expectEqualStrings("inside gz", body(try live.get("/app.css", br_gzip, &out)));
    try root.deleteFile(io, "app.css.br");

    // A directory.
    try root.createDir(io, "app.css.br", .default_dir);
    for (0..2) |_| try std.testing.expectEqualStrings("inside gz", body(try live.get("/app.css", br_gzip, &out)));
    const s = live.stats();
    try std.testing.expectEqual(@as(u64, if (readable) 3 else 5), s.hits);
    try std.testing.expectEqual(@as(u64, 0), s.misses);
    try std.testing.expectEqual(@as(u64, 1), s.fills);
    try std.testing.expectEqual(@as(u32, 1), live.cache().fill_reads.load(.monotonic));
}

test "static cache: a cached file whose directory is moved out and linked back is a 404, as today, and the sweep drops it" {
    try requireCache();
    var fixture = try fallbackTree();
    defer fixture.tmp.cleanup();
    defer fixture.root.close(io);
    const root = fixture.root;
    try root.createDir(io, "sub", .default_dir);
    try write(root, "sub/app.css", "inside sub");
    var live: Live = undefined;
    try startFallback(&live, root);
    defer live.deinit();
    var out: [4096]u8 = undefined;

    _ = try live.get("/sub/app.css", "", &out);
    try std.testing.expectEqualStrings("inside sub", body(try live.get("/sub/app.css", "", &out)));
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);

    // The files in it keep their inode, size, mtime and ctime.
    try fixture.tmp.dir.rename("root/sub", fixture.tmp.dir, "outside/sub", io);
    try root.symLink(io, "../outside/sub", "sub", .{ .is_directory = true });
    try std.testing.expectEqualStrings("404", status(try live.get("/sub/app.css", "", &out)));
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);

    const cache = live.cache();
    try std.testing.expectEqual(@as(usize, 1), cache.testCount());
    try cache.sweep(io, cache.slots.len);
    try std.testing.expectEqual(@as(usize, 0), cache.testCount());
}

test "static cache: a plain file swapped for a link out while its .br is cached is a 404, as is a directory linked out" {
    try requireCache();
    var fixture = try fallbackTree();
    defer fixture.tmp.cleanup();
    defer fixture.root.close(io);
    const root = fixture.root;
    try write(root, "app.css.br", "inside br");
    try root.symLink(io, "../outside", "d", .{ .is_directory = true });
    var live: Live = undefined;
    try startFallback(&live, root);
    defer live.deinit();
    var out: [4096]u8 = undefined;

    _ = try live.get("/app.css", br, &out);
    try std.testing.expectEqualStrings("inside br", body(try live.get("/app.css", br, &out)));
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);

    try root.deleteFile(io, "app.css");
    try root.symLink(io, "../outside/app.css", "app.css", .{});
    try std.testing.expectEqualStrings("404", status(try live.get("/app.css", br, &out)));

    try std.testing.expectEqualStrings("404", status(try live.get("/d", "", &out)));
    try std.testing.expectEqualStrings("404", status(try live.get("/d/app.css", "", &out)));
}

test "static cache: a plain file moved and linked back by an absolute path is answered as without the cache (a 404 where the kernel confines opens)" {
    try requireCache();
    var fixture = try fallbackTree();
    defer fixture.tmp.cleanup();
    defer fixture.root.close(io);
    const root = fixture.root;
    var live: Live = undefined;
    try startFallback(&live, root);
    defer live.deinit();
    var out: [4096]u8 = undefined;

    _ = try live.get("/app.css", "", &out);
    try std.testing.expectEqualStrings("inside plain", body(try live.get("/app.css", "", &out)));
    const before = try root.statFile(io, "app.css", .{});
    try root.rename("app.css", root, "moved.css", io);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try root.realPath(io, &buf);
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/moved.css", .{buf[0..n]});
    defer std.testing.allocator.free(target);
    try root.symLink(io, target, "app.css", .{});
    // The same inode, size and mtime: the rename's ctime is what differs,
    // unless the kernel gave both one tick.
    const after = try root.statFile(io, "app.css", .{});
    if (after.ctime.nanoseconds == before.ctime.nanoseconds) return error.SkipZigTest;
    // std.Io.Threaded ignores the kernel's confinement: the real-path
    // check then serves a link that points back inside.
    const got = try live.get("/app.css", "", &out);
    if (live.server.beneath == .kernel) {
        try std.testing.expectEqualStrings("404", status(got));
    } else {
        try std.testing.expectEqualStrings("inside plain", body(got));
        // The cache's own open is kernel-confined, so it misses each
        // time; the fill finds those bytes held and reads nothing.
        const reads = live.cache().fill_reads.load(.monotonic);
        try std.testing.expectEqualStrings("inside plain", body(try live.get("/app.css", "", &out)));
        try std.testing.expectEqual(reads, live.cache().fill_reads.load(.monotonic));
        try std.testing.expectEqual(@as(u64, 2), live.stats().misses);
        return;
    }
    try std.testing.expectEqual(@as(u64, 1), live.stats().misses);
}

test "static cache: a path it doesn't hold costs no stat, and a hit two (the plain file and the copy served)" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "a");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{ .precompressed = &.{.br} });
    try live.start();
    var out: [4096]u8 = undefined;

    for (0..3) |_| try std.testing.expectEqualStrings("404", status(try live.get("/missing.txt", "", &out)));
    _ = try live.get("/a.txt", br, &out);
    try std.testing.expectEqual(@as(u32, 0), live.cache().inline_stats.load(.monotonic));
    _ = try live.get("/a.txt", br, &out);
    // The plain file, then a.txt.br (missing): identity is served.
    try std.testing.expectEqual(@as(u32, 2), live.cache().inline_stats.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);
}

test "static cache: a file changed within the last 2 s is served but not cached" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "fresh");
    const saved = static_cache.test_hooks.clock_offset_ns;
    static_cache.test_hooks.clock_offset_ns = 0;
    defer static_cache.test_hooks.clock_offset_ns = saved;
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;

    for (0..2) |_| try std.testing.expectEqualStrings("fresh", body(try live.get("/a.txt", "", &out)));
    const s = live.stats();
    try std.testing.expectEqual(@as(u64, 0), s.fills);
    try std.testing.expectEqual(@as(u64, 2), s.skipped[@backingInt(static_cache.Skip.racy)]);
}

test "static cache: past its budget, or with both of a key's slots taken, a file is served from disk and not kept" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "aaaa");
    try write(tmp.dir, "b.txt", "bbbb");
    {
        var live: Live = undefined;
        live.init(.{ .static_cache = .{ .bytes = 64 } });
        defer live.deinit();
        live.server.router.static("/", tmp.dir, .{});
        try live.start();
        var out: [4096]u8 = undefined;
        for (0..2) |_| try std.testing.expectEqualStrings("aaaa", body(try live.get("/a.txt", "", &out)));
        try std.testing.expectEqual(@as(u64, 2), live.stats().skipped[@backingInt(static_cache.Skip.budget)]);
        try std.testing.expectEqual(@as(usize, 0), live.stats().bytes);
    }
    {
        var live: Live = undefined;
        live.init(.{});
        defer live.deinit();
        live.server.router.static("/", tmp.dir, .{});
        try live.start();
        const owner = live.server.router.statics.items[0];
        try live.cache().testOccupy(owner, "b.txt", null);
        var out: [4096]u8 = undefined;
        for (0..2) |_| try std.testing.expectEqualStrings("bbbb", body(try live.get("/b.txt", "", &out)));
        try std.testing.expectEqual(@as(u64, 2), live.stats().skipped[@backingInt(static_cache.Skip.table)]);
        try std.testing.expectEqual(@as(u64, 0), live.stats().fills);
        // Known to have no room before the file is read.
        try std.testing.expectEqual(@as(u32, 0), live.cache().fill_reads.load(.monotonic));
    }
}

test "static cache: what entries charge comes back when they are replaced, swept and freed" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "aaaa");
    try write(tmp.dir, "b.txt", "bbbbbbbb");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;
    const cache = live.cache();

    _ = try live.get("/a.txt", "", &out);
    _ = try live.get("/b.txt", "", &out);
    try rewrite(tmp.dir, "a.txt", "AAAA");
    try std.testing.expectEqualStrings("AAAA", body(try live.get("/a.txt", "", &out)));
    try std.testing.expectEqual(@as(u64, 3), live.stats().fills);
    try std.testing.expectEqual(@as(usize, 2), cache.testCount());

    // Unchanged: the sweep keeps it.
    try cache.sweep(io, cache.slots.len);
    try std.testing.expectEqual(@as(usize, 2), cache.testCount());
    try tmp.dir.deleteFile(io, "a.txt");
    try tmp.dir.deleteFile(io, "b.txt");
    try cache.sweep(io, cache.slots.len);
    try std.testing.expectEqual(@as(usize, 0), cache.testCount());
    try std.testing.expectEqual(@as(u64, 2), live.stats().swept);
    try cache.domain.synchronize(io);
    try std.testing.expectEqual(@as(usize, 0), live.stats().bytes);
}

test "static cache: content-hashed names replaced on every deploy keep the budget bounded, and the new names hit" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;
    const cache = live.cache();

    var name_buf: [32]u8 = undefined;
    var path_buf: [32]u8 = undefined;
    var most: usize = 0;
    for (0..100) |round| {
        const name = try std.fmt.bufPrint(&name_buf, "app.{d}.js", .{round});
        try write(tmp.dir, name, "console.log('a deploy')");
        if (round > 0) {
            const old = try std.fmt.bufPrint(&path_buf, "app.{d}.js", .{round - 1});
            try tmp.dir.deleteFile(io, old);
        }
        const path = try std.fmt.bufPrint(&path_buf, "/{s}", .{name});
        _ = try live.get(path, "", &out);
        const hits = live.stats().hits;
        _ = try live.get(path, "", &out);
        try std.testing.expectEqual(hits + 1, live.stats().hits);
        try cache.sweep(io, cache.slots.len);
        try cache.domain.synchronize(io);
        most = @max(most, live.stats().bytes);
        try std.testing.expectEqual(@as(usize, 1), cache.testCount());
    }
    // One entry's worth, never a hundred.
    try std.testing.expect(most < 1024);
}

test "static cache: a key found in both of its slots (two fills raced) is left in one by the next fill, and nothing leaks" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "one");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;
    const cache = live.cache();

    _ = try live.get("/a.txt", "", &out);
    try cache.testDuplicate(live.server.router.statics.items[0], "a.txt", null);
    try std.testing.expectEqual(@as(usize, 2), cache.testCount());
    try rewrite(tmp.dir, "a.txt", "two");
    try std.testing.expectEqualStrings("two", body(try live.get("/a.txt", "", &out)));
    try std.testing.expectEqual(@as(usize, 1), cache.testCount());
    try std.testing.expectEqualStrings("two", body(try live.get("/a.txt", "", &out)));
    try tmp.dir.deleteFile(io, "a.txt");
    try cache.sweep(io, cache.slots.len);
    try cache.domain.synchronize(io);
    try std.testing.expectEqual(@as(usize, 0), live.stats().bytes);
}

test "static cache: conditional and range requests on a hit (304, 412, 206, If-Range)" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "a.txt", "0123456789");
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var first_buf: [4096]u8 = undefined;
    var out: [4096]u8 = undefined;

    const first = try live.get("/a.txt", "", &first_buf);
    const etag = header(first, "ETag").?;
    const last_modified = header(first, "Last-Modified").?;
    var h: [256]u8 = undefined;

    var got = try live.get("/a.txt", try std.fmt.bufPrint(&h, "If-None-Match: {s}\r\n", .{etag}), &out);
    try std.testing.expectEqualStrings("304", status(got));
    try std.testing.expectEqualStrings(etag, header(got, "ETag").?);
    try std.testing.expectEqualStrings("", body(got));

    got = try live.get("/a.txt", "If-Match: \"other\"\r\n", &out);
    try std.testing.expectEqualStrings("412", status(got));
    got = try live.get("/a.txt", "If-Unmodified-Since: Sun, 06 Nov 1994 08:49:37 GMT\r\n", &out);
    try std.testing.expectEqualStrings("412", status(got));
    got = try live.get("/a.txt", try std.fmt.bufPrint(&h, "If-Match: {s}\r\n", .{etag}), &out);
    try std.testing.expectEqualStrings("200", status(got));

    got = try live.get("/a.txt", "Range: bytes=2-5\r\n", &out);
    try std.testing.expectEqualStrings("206", status(got));
    try std.testing.expectEqualStrings("2345", body(got));
    try std.testing.expectEqualStrings("bytes 2-5/10", header(got, "Content-Range").?);

    got = try live.get("/a.txt", try std.fmt.bufPrint(&h, "Range: bytes=-3\r\nIf-Range: {s}\r\n", .{last_modified}), &out);
    try std.testing.expectEqualStrings("789", body(got));
    got = try live.get("/a.txt", "Range: bytes=-3\r\nIf-Range: \"other\"\r\n", &out);
    try std.testing.expectEqualStrings("200", status(got));
    try std.testing.expectEqualStrings("0123456789", body(got));

    // Everything after the first request was a hit.
    try std.testing.expectEqual(@as(u64, 7), live.stats().hits);
    try std.testing.expectEqual(@as(u64, 1), live.stats().fills);
}

test "static cache: keys are per mount (a hidden dotfile stays hidden), and a relative link inside keeps hitting" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, ".env", "SECRET=1");
    try write(tmp.dir, "a.txt", "a");
    try tmp.dir.symLink(io, "a.txt", "link.txt", .{});
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/open", tmp.dir, .{ .hide_dotfiles = false });
    live.server.router.static("/hidden", tmp.dir, .{});
    try live.start();
    var out: [4096]u8 = undefined;

    for (0..2) |_| try std.testing.expectEqualStrings("SECRET=1", body(try live.get("/open/.env", "", &out)));
    try std.testing.expectEqualStrings("404", status(try live.get("/hidden/.env", "", &out)));
    try std.testing.expectEqualStrings("404", status(try live.get("/hidden/%2Eenv", "", &out)));

    for (0..3) |_| try std.testing.expectEqualStrings("a", body(try live.get("/hidden/link.txt", "", &out)));
    try std.testing.expectEqual(@as(u64, 3), live.stats().hits);
}

test "static cache: files over max_file, a cached file grown past it, an index, HEAD and a cache = false mount take the old path" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "small.txt", "small");
    try write(tmp.dir, "big.txt", comptime repeat("x", 40));
    try tmp.dir.createDir(io, "docs", .default_dir);
    try write(tmp.dir, "docs/index.html", "<h1>docs</h1>");
    var live: Live = undefined;
    live.init(.{ .static_cache = .{ .max_file = 32 } });
    defer live.deinit();
    live.server.router.static("/on", tmp.dir, .{});
    live.server.router.static("/off", tmp.dir, .{ .cache = false });
    try live.start();
    var out: [4096]u8 = undefined;

    for (0..2) |_| try std.testing.expectEqualStrings(comptime repeat("x", 40), body(try live.get("/on/big.txt", "", &out)));
    for (0..2) |_| try std.testing.expectEqualStrings("<h1>docs</h1>", body(try live.get("/on/docs/", "", &out)));
    for (0..2) |_| {
        const got = try live.send("HEAD", "/on/small.txt", "", &out);
        try std.testing.expectEqualStrings("5", header(got, "Content-Length").?);
    }
    for (0..2) |_| try std.testing.expectEqualStrings("small", body(try live.get("/off/small.txt", "", &out)));
    try std.testing.expectEqual(@as(u64, 0), live.stats().fills);
    try std.testing.expectEqual(@as(u64, 0), live.stats().hits);

    _ = try live.get("/on/small.txt", "", &out);
    try std.testing.expectEqual(@as(u64, 1), live.stats().fills);
    try write(tmp.dir, "small.txt", comptime repeat("y", 48));
    const misses = live.stats().misses;
    try std.testing.expectEqualStrings(comptime repeat("y", 48), body(try live.get("/on/small.txt", "", &out)));
    try std.testing.expectEqual(misses + 1, live.stats().misses);
}

test "static cache: behind Compress a hit goes out as the file did, uncompressed with a strong ETag" {
    try requireCache();
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "page.css", comptime repeat("body { color: red } ", 100));
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    var compress = dusty.middleware.Compress.init(.{});
    live.server.router.use(dusty.Middleware(void).init(&compress));
    live.server.router.static("/", tmp.dir, .{});
    try live.start();
    var miss_buf: [8192]u8 = undefined;
    var out: [8192]u8 = undefined;

    const miss = try live.get("/page.css", gzip, &miss_buf);
    const hit = try live.get("/page.css", gzip, &out);
    try std.testing.expectEqual(@as(u64, 1), live.stats().hits);
    try std.testing.expectEqual(null, header(hit, "Content-Encoding"));
    try std.testing.expectEqualStrings(header(miss, "ETag").?, header(hit, "ETag").?);
    try std.testing.expect(!std.mem.startsWith(u8, header(hit, "ETag").?, "W/"));
    try std.testing.expectEqualStrings(body(miss), body(hit));
}

test "static cache: prepareStatic run twice makes one cache, and its domain is registered once" {
    try requireCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var live: Live = undefined;
    live.init(.{});
    defer live.deinit();
    live.server.router.static("/", tmp.dir, .{});
    try live.server.prepareStatic();
    const first = live.server.static_cache.?;
    try live.server.prepareStatic();
    try std.testing.expectEqual(first, live.server.static_cache.?);
    // A domain linked twice would loop the registry: this returns.
    qsbr.pollAll();
}

test "static cache: none without a static mount, with every mount at cache = false, or at bytes = 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var live: Live = undefined;
        live.init(.{});
        defer live.deinit();
        try live.server.prepareStatic();
        try std.testing.expectEqual(null, live.server.static_cache);
    }
    {
        var live: Live = undefined;
        live.init(.{});
        defer live.deinit();
        live.server.router.static("/", tmp.dir, .{ .cache = false });
        try live.server.prepareStatic();
        try std.testing.expectEqual(null, live.server.static_cache);
    }
    {
        var live: Live = undefined;
        live.init(.{ .static_cache = .{ .bytes = 0 } });
        defer live.deinit();
        live.server.router.static("/", tmp.dir, .{});
        try live.server.prepareStatic();
        try std.testing.expectEqual(null, live.server.static_cache);
    }
}
