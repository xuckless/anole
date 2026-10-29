//! The S3 client against a real S3-compatible server (MinIO in CI,
//! tests/s3/run.sh): `zig build test-s3 -Ds3-test-url=http://127.0.0.1:9000`.
//! Settings from the environment: ANOLE_S3_TEST_KEY / _SECRET (default
//! anole / anole-secret-1), ANOLE_S3_TEST_BUCKET (default anole-test, made
//! beforehand), ANOLE_S3_TEST_CA (a PEM file, for an https URL). Without
//! the URL every test here skips.
const std = @import("std");
const dusty = @import("dusty");
const build_options = @import("build_options");
const db = @import("../db/root.zig");
const s3 = @import("root.zig");
const zio = @import("zio");

const testing = std.testing;
const mib: usize = 1024 * 1024;

fn env(name: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(name) orelse return default;
    return std.mem.span(v);
}

const Live = struct {
    rt: *zio.Runtime,
    client: *s3.Client,
    arena_state: std.heap.ArenaAllocator,
    ctx: db.Ctx,

    fn init() !*Live {
        const url = build_options.s3_test_url orelse return error.SkipZigTest;
        const self = try testing.allocator.create(Live);
        errdefer testing.allocator.destroy(self);
        self.rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
        errdefer self.rt.deinit();
        const ca = env("ANOLE_S3_TEST_CA", "");
        self.client = try s3.Client.init(testing.allocator, self.rt.io(), .{
            .endpoint = url,
            .bucket = env("ANOLE_S3_TEST_BUCKET", "anole-test"),
            .credentials = .{ .static = .{ .access_key_id = env("ANOLE_S3_TEST_KEY", "anole"), .secret_access_key = env("ANOLE_S3_TEST_SECRET", "anole-secret-1") } },
            .part_size = 5 * mib,
            .tls = .{ .ca = if (ca.len > 0) .{ .file = ca } else null },
        });
        self.arena_state = .init(testing.allocator);
        self.ctx = .{ .io = self.rt.io(), .arena = self.arena_state.allocator() };
        return self;
    }

    fn deinit(self: *Live) void {
        self.client.deinit();
        self.arena_state.deinit();
        self.rt.deinit();
        testing.allocator.destroy(self);
    }

    fn c(self: *Live) *db.Ctx {
        return &self.ctx;
    }

    fn key(self: *Live, name: []const u8) ![]const u8 {
        var n: [4]u8 = undefined;
        self.rt.io().random(&n);
        return std.fmt.allocPrint(self.ctx.arena, "live/{x}/{s}", .{ n, name });
    }
};

fn pattern(arena: std.mem.Allocator, n: usize, seed: u8) ![]u8 {
    const buf = try arena.alloc(u8, n);
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

test "s3: live: put, get, head, range, conditional, copy, delete" {
    const l = try Live.init();
    defer l.deinit();
    const k = try l.key("a.txt");
    const stored = try l.client.put(l.c(), k, .{ .bytes = "hello live" }, .{ .metadata = &.{.{ "owner", "ada" }} });
    const obj = try l.client.get(l.c(), k, .{});
    try testing.expectEqualStrings("hello live", obj.body);
    try testing.expectEqualStrings("ada", obj.meta.meta("owner").?);
    const part = try l.client.get(l.c(), k, .{ .range = .{ .start = 0, .end = 4 } });
    try testing.expectEqualStrings("hello", part.body);
    try testing.expectEqual(@as(u16, 206), part.meta.status);
    try testing.expect((try l.client.get(l.c(), k, .{ .if_none_match = stored.etag })).meta.not_modified);
    try testing.expectError(error.Conflict, l.client.put(l.c(), k, .{ .bytes = "again" }, .{ .if_absent = true }));
    const copy = try l.key("copy.txt");
    _ = try l.client.copy(l.c(), .{ .key = k }, copy, .{});
    try testing.expectEqualStrings("hello live", (try l.client.get(l.c(), copy, .{})).body);
    try l.client.delete(l.c(), k, .{});
    try l.client.delete(l.c(), copy, .{});
    try testing.expect(!(try l.client.exists(l.c(), k)));
    try testing.expectError(error.NotFound, l.client.get(l.c(), k, .{}));
}

test "s3: live: 40 MiB multipart from a reader, and a push upload" {
    const l = try Live.init();
    defer l.deinit();
    const data = try pattern(l.ctx.arena, 40 * mib, 5);
    const k = try l.key("big.bin");
    var r: std.Io.Reader = .fixed(data);
    const stored = try l.client.put(l.c(), k, .{ .reader = .{ .reader = &r } }, .{});
    try testing.expect(stored.parts >= 8);
    var dl = try l.client.open(l.c(), k, .{});
    defer dl.deinit();
    var out: std.Io.Writer.Allocating = .init(l.ctx.arena);
    try testing.expectEqual(@as(u64, data.len), try dl.pipe(&out.writer));
    try testing.expectEqualSlices(u8, data, out.written());
    try l.client.delete(l.c(), k, .{});

    const pk = try l.key("push.bin");
    var up = try l.client.upload(l.c(), pk, .{});
    defer up.deinit();
    var off: usize = 0;
    while (off < 12 * mib) : (off += mib) {
        if (try up.write(l.c(), data[off..][0..mib]) == .busy) try up.waitWritable(l.c(), null);
    }
    _ = try up.finish(l.c());
    try testing.expectEqualSlices(u8, data[0 .. 12 * mib], (try l.client.get(l.c(), pk, .{ .max_bytes = 16 * mib })).body);
    try l.client.delete(l.c(), pk, .{});
}

test "s3: live: list 2500 keys, deleteMany" {
    const l = try Live.init();
    defer l.deinit();
    const prefix = try l.key("many/");
    const keys = try l.ctx.arena.alloc([]const u8, 2500);
    for (keys, 0..) |*k, i| {
        k.* = try std.fmt.allocPrint(l.ctx.arena, "{s}{d:0>5}", .{ prefix, i });
        _ = try l.client.put(l.c(), k.*, .{ .bytes = "x" }, .{});
    }
    var it = l.client.iterate(l.c(), .{ .prefix = prefix });
    var n: usize = 0;
    while (try it.next(l.c())) |_| n += 1;
    try testing.expectEqual(@as(usize, 2500), n);
    const r = try l.client.deleteMany(l.c(), keys);
    try testing.expectEqual(@as(u32, 2500), r.deleted);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
}

test "s3: live: presigned GET and PUT work for the core client, and browser-style multipart" {
    const l = try Live.init();
    defer l.deinit();
    const k = try l.key("presigned.txt");
    const put_url = try l.client.presign(l.c(), .put, k, .{ .content_length = 5 });
    var http = dusty.Client.init(testing.allocator, l.rt.io(), .{ .tls = .{ .ca = if (env("ANOLE_S3_TEST_CA", "").len > 0) .{ .file = env("ANOLE_S3_TEST_CA", "") } else .system } });
    defer http.deinit();
    {
        var resp = try http.fetch(put_url, .{ .method = .put, .body = "12345", .decompress = false });
        defer resp.deinit();
        try testing.expectEqual(@as(u32, 200), @backingInt(resp.status()));
    }
    const get_url = try l.client.presign(l.c(), .get, k, .{});
    {
        var resp = try http.fetch(get_url, .{});
        defer resp.deinit();
        try testing.expectEqualStrings("12345", (try resp.body()).?);
    }
    const mk = try l.key("browser.bin");
    const mp = l.client.multipart();
    const id = try mp.create(l.c(), mk, .{});
    const part1 = try pattern(l.ctx.arena, 5 * mib, 1);
    var parts: [2]s3.Part = undefined;
    for ([_][]const u8{ part1, "tail" }, 0..) |bytes, i| {
        const url = try l.client.presign(l.c(), .upload_part, mk, .{ .upload_id = id, .part_number = @intCast(i + 1) });
        var resp = try http.fetch(url, .{ .method = .put, .body = bytes, .decompress = false });
        defer resp.deinit();
        parts[i] = .{ .number = @intCast(i + 1), .etag = try l.ctx.arena.dupe(u8, resp.headers().get("ETag").?) };
    }
    _ = try mp.complete(l.c(), mk, id, &parts);
    try testing.expectEqual(5 * mib + 4, (try l.client.head(l.c(), mk, .{})).size);
    try l.client.delete(l.c(), k, .{});
    try l.client.delete(l.c(), mk, .{});
}
