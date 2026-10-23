//! Tests of the S3 client against `testing.FakeServer`, which verifies
//! every signature and models what S3 checks. All deterministic: nothing
//! here depends on a task being scheduled within a time window.
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const db = @import("../db/root.zig");
const s3 = @import("root.zig");
const fake_ = @import("testing.zig");
const credentials = @import("credentials.zig");
const util = @import("util.zig");

const zio = @import("zio");

const testing = std.testing;

/// The runtime the current test runs on (dusty's server and the zio-aware
/// client want zio's `Io`, not `std.tio()`).
var current_rt: ?*zio.Runtime = null;

fn tio() std.Io {
    return current_rt.?.io();
}

const Rt = struct {
    fn start() !void {
        std.debug.assert(current_rt == null);
        current_rt = try zio.Runtime.init(testing.allocator, .{ .executors = .exact(2) });
    }
    fn stop() void {
        current_rt.?.deinit();
        current_rt = null;
    }
};
const FakeServer = fake_.FakeServer;
const mib: usize = 1024 * 1024;

const fast_retry: @import("../resilience/root.zig").Retry = .{
    .attempts = 3,
    .backoff = .{ .base = .fromMilliseconds(1), .max = .fromMilliseconds(2), .jitter = .none },
};

/// A fake server, a client on it, and a call context.
const Env = struct {
    fake: *FakeServer,
    client: *s3.Client,
    arena_state: std.heap.ArenaAllocator,
    ctx: db.Ctx,

    fn init(overrides: s3.Options) !*Env {
        try Rt.start();
        errdefer Rt.stop();
        const self = try testing.allocator.create(Env);
        errdefer testing.allocator.destroy(self);
        self.fake = try FakeServer.start(testing.allocator, tio());
        errdefer self.fake.stop();
        var o = overrides;
        o.endpoint = o.endpoint orelse self.fake.url();
        o.bucket = o.bucket orelse "b";
        if (o.credentials == .chain) o.credentials = self.fake.credentials();
        if (o.retry != null and o.retry.?.attempts == 3 and o.retry.?.backoff.base.nanoseconds == std.time.ns_per_ms * 100) o.retry = fast_retry;
        self.client = try s3.Client.init(testing.allocator, tio(), o);
        errdefer self.client.deinit();
        self.arena_state = .init(testing.allocator);
        self.ctx = .{ .io = tio(), .arena = self.arena_state.allocator() };
        return self;
    }

    fn deinit(self: *Env) void {
        self.client.deinit();
        self.fake.stop();
        self.arena_state.deinit();
        testing.allocator.destroy(self);
        Rt.stop();
    }

    fn c(self: *Env) *db.Ctx {
        return &self.ctx;
    }

    /// Prints the last error (for a failing test's output).
    fn why(self: *Env) void {
        if (db.lastError(&self.ctx)) |d| std.debug.print("last error: {f}\n", .{d});
    }

    fn lastCode(self: *Env) []const u8 {
        return if (db.lastError(&self.ctx)) |d| d.code else "";
    }
};

/// Keeps expected failures out of the test output.
const Quiet = struct {
    level: std.log.Level,
    fn on() Quiet {
        const level = testing.log_level;
        testing.log_level = .err;
        return .{ .level = level };
    }
    fn done(self: Quiet) void {
        testing.log_level = self.level;
    }
};

fn pattern(arena: std.mem.Allocator, n: usize, seed: u8) ![]u8 {
    const buf = try arena.alloc(u8, n);
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

fn code(resp: anytype) u16 {
    return @intCast(@intFromEnum(resp.status()));
}

test "s3: put, get, head, delete round trip; content type from the extension; metadata comes back" {
    const env = try Env.init(.{});
    defer env.deinit();
    errdefer env.why();
    const stored = try env.client.put(env.c(), "docs/readme.txt", .{ .bytes = "hello s3" }, .{ .metadata = &.{.{ "Owner", "ada" }} });
    try testing.expect(stored.etag.len > 2);
    const obj = try env.client.get(env.c(), "docs/readme.txt", .{});
    try testing.expectEqualStrings("hello s3", obj.body);
    try testing.expect(std.mem.startsWith(u8, obj.meta.content_type.?, "text/plain"));
    try testing.expectEqualStrings("ada", obj.meta.meta("owner").?);
    try testing.expectEqual(@as(u64, 8), obj.meta.size);
    const m = try env.client.head(env.c(), "docs/readme.txt", .{});
    try testing.expectEqual(@as(u64, 8), m.content_length);
    try testing.expect(try env.client.exists(env.c(), "docs/readme.txt"));
    try env.client.delete(env.c(), "docs/readme.txt", .{});
    try testing.expect(!(try env.client.exists(env.c(), "docs/readme.txt")));
    try testing.expectEqual(@as(u32, 0), env.fake.signature_failures);
}

test "s3: a key with spaces and unicode is signed and stored" {
    const env = try Env.init(.{});
    defer env.deinit();
    _ = try env.client.put(env.c(), "a b/é+c&d.bin", .{ .bytes = "x" }, .{});
    try testing.expectEqualStrings("x", env.fake.getObject("b", "a b/é+c&d.bin").?);
    try testing.expectEqualStrings("x", (try env.client.get(env.c(), "a b/é+c&d.bin", .{})).body);
    try testing.expectEqual(@as(u32, 0), env.fake.signature_failures);
}

test "s3: get of a missing key is NotFound with lastError NoSuchKey; optional returns null" {
    const env = try Env.init(.{});
    defer env.deinit();
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.NotFound, env.client.get(env.c(), "nope", .{}));
    try testing.expectEqualStrings("NoSuchKey", env.lastCode());
    try testing.expect((try env.client.optional(env.c(), "nope", .{})) == null);
}

test "s3: get with max_bytes smaller than the object fails object_too_large; open streams it" {
    const env = try Env.init(.{});
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 100_000, 3);
    _ = try env.client.put(env.c(), "big.bin", .{ .bytes = data }, .{});
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.BadRequest, env.client.get(env.c(), "big.bin", .{ .max_bytes = 1000 }));
    try testing.expectEqualStrings("object_too_large", env.lastCode());
    var dl = try env.client.open(env.c(), "big.bin", .{});
    defer dl.deinit();
    var out: std.Io.Writer.Allocating = .init(env.ctx.arena);
    const n = try dl.pipe(&out.writer);
    try testing.expectEqual(@as(u64, 100_000), n);
    try testing.expectEqualSlices(u8, data, out.written());
}

test "s3: range 0-9 gives 206 with the whole size; a range past the end is BadRequest" {
    const env = try Env.init(.{});
    defer env.deinit();
    _ = try env.client.put(env.c(), "r.txt", .{ .bytes = "0123456789abcdef" }, .{});
    const obj = try env.client.get(env.c(), "r.txt", .{ .range = .{ .start = 0, .end = 9 } });
    try testing.expectEqual(@as(u16, 206), obj.meta.status);
    try testing.expectEqualStrings("0123456789", obj.body);
    try testing.expectEqual(@as(u64, 10), obj.meta.content_length);
    try testing.expectEqual(@as(u64, 16), obj.meta.size);
    const tail = try env.client.get(env.c(), "r.txt", .{ .range = .{ .start = 10 } });
    try testing.expectEqualStrings("abcdef", tail.body);
    try testing.expectEqual(@as(u64, 10), tail.meta.range_start);
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.BadRequest, env.client.get(env.c(), "r.txt", .{ .range = .{ .start = 100 } }));
    try testing.expectEqualStrings("InvalidRange", env.lastCode());
}

test "s3: if_none_match with the current etag is not_modified; if_match with another is Conflict" {
    const env = try Env.init(.{});
    defer env.deinit();
    const stored = try env.client.put(env.c(), "c.txt", .{ .bytes = "x" }, .{});
    const same = try env.client.get(env.c(), "c.txt", .{ .if_none_match = stored.etag });
    try testing.expect(same.meta.not_modified);
    try testing.expectEqual(@as(u16, 304), same.meta.status);
    try testing.expectEqual(@as(usize, 0), same.body.len);
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.Conflict, env.client.get(env.c(), "c.txt", .{ .if_match = "\"other\"" }));
    try testing.expectEqualStrings("PreconditionFailed", env.lastCode());
}

test "s3: put if_absent twice: the second is Conflict" {
    const env = try Env.init(.{});
    defer env.deinit();
    _ = try env.client.put(env.c(), "once", .{ .bytes = "1" }, .{ .if_absent = true });
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.Conflict, env.client.put(env.c(), "once", .{ .bytes = "2" }, .{ .if_absent = true }));
    try testing.expectEqualStrings("1", env.fake.getObject("b", "once").?);
}

test "s3: put of 11 MiB goes up as three parts, completed in order" {
    const env = try Env.init(.{ .part_size = 5 * mib });
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 11 * mib, 7);
    const stored = try env.client.put(env.c(), "big/multi.bin", .{ .bytes = data }, .{});
    try testing.expectEqual(@as(u32, 3), stored.parts);
    try testing.expectEqual(@as(usize, 3), env.fake.count("PUT", "partNumber="));
    try testing.expectEqual(@as(usize, 1), env.fake.count("POST", "uploads"));
    try testing.expectEqual(@as(usize, 1), env.fake.count("POST", "uploadId="));
    try testing.expectEqualSlices(u8, data, env.fake.getObject("b", "big/multi.bin").?);
    try testing.expectEqual(@as(usize, 0), env.fake.openUploads());
    try testing.expectEqual(@as(u32, 0), env.fake.signature_failures);
}

test "s3: a body of exactly one part is one PUT, not multipart" {
    const env = try Env.init(.{ .part_size = 5 * mib });
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 5 * mib, 1);
    var up = try env.client.upload(env.c(), "exact.bin", .{});
    defer up.deinit();
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(64 * 1024, data.len - off);
        _ = try up.write(env.c(), data[off..][0..n]);
        off += n;
        try up.waitWritable(env.c(), null);
    }
    const stored = try up.finish(env.c());
    try testing.expectEqual(@as(u32, 0), stored.parts);
    try testing.expectEqual(@as(usize, 0), env.fake.count("POST", "uploads"));
    try testing.expectEqualSlices(u8, data, env.fake.getObject("b", "exact.bin").?);
}

test "s3: put from a reader with a length: one PUT up to the threshold; a short body is short_body" {
    const env = try Env.init(.{});
    defer env.deinit();
    var r: std.Io.Reader = .fixed("twelve bytes");
    const stored = try env.client.put(env.c(), "r.txt", .{ .reader = .{ .reader = &r, .len = 12 } }, .{});
    try testing.expectEqual(@as(u32, 0), stored.parts);
    try testing.expectEqualStrings("twelve bytes", env.fake.getObject("b", "r.txt").?);
    var short: std.Io.Reader = .fixed("abc");
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.BadRequest, env.client.put(env.c(), "s.txt", .{ .reader = .{ .reader = &short, .len = 10 } }, .{}));
    try testing.expectEqualStrings("short_body", env.lastCode());
}

test "s3: put from a reader of unknown length streams it as parts" {
    const env = try Env.init(.{ .part_size = 5 * mib });
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 7 * mib, 21);
    var r: std.Io.Reader = .fixed(data);
    const stored = try env.client.put(env.c(), "stream.bin", .{ .reader = .{ .reader = &r } }, .{});
    try testing.expectEqual(@as(u32, 2), stored.parts);
    try testing.expectEqualSlices(u8, data, env.fake.getObject("b", "stream.bin").?);
}

test "s3: push upload: ok to one part, busy past it, upload_full a part more" {
    const env = try Env.init(.{ .part_size = 5 * mib, .concurrency = 1 });
    defer env.deinit();
    env.fake.hold_parts = true;
    var up = try env.client.upload(env.c(), "push.bin", .{});
    defer up.deinit();
    const chunk = try pattern(env.ctx.arena, mib, 5);
    // 5 MiB = concurrency * part_size: ok up to it.
    for (0..5) |_| try testing.expectEqual(s3.Upload.Written.ok, try up.write(env.c(), chunk));
    // Past it: taken, but busy (the full buffer becomes a part).
    try testing.expectEqual(s3.Upload.Written.busy, try up.write(env.c(), chunk));
    try testing.expect(!up.writable());
    // Up to 10 MiB is still taken; a byte more is refused.
    for (0..4) |_| try testing.expectEqual(s3.Upload.Written.busy, try up.write(env.c(), chunk));
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.ServiceUnavailable, up.write(env.c(), chunk));
    try testing.expectEqualStrings("upload_full", env.lastCode());
    env.fake.releaseParts();
    const stored = try up.finish(env.c());
    try testing.expectEqual(@as(u32, 2), stored.parts);
    try testing.expectEqual(10 * mib, env.fake.getObject("b", "push.bin").?.len);
}

test "s3: push upload: waitWritable returns after a part completes" {
    const env = try Env.init(.{ .part_size = 5 * mib, .concurrency = 1 });
    defer env.deinit();
    env.fake.hold_parts = true;
    var up = try env.client.upload(env.c(), "push2.bin", .{});
    defer up.deinit();
    const chunk = try pattern(env.ctx.arena, mib, 5);
    for (0..5) |_| _ = try up.write(env.c(), chunk);
    try testing.expectEqual(s3.Upload.Written.busy, try up.write(env.c(), chunk));
    try testing.expect(!up.writable());
    env.fake.releaseParts();
    try up.waitWritable(env.c(), null);
    try testing.expect(up.writable());
    const stored = try up.finish(env.c());
    try testing.expectEqual(@as(u32, 2), stored.parts);
    try testing.expectEqual(6 * mib, env.fake.getObject("b", "push2.bin").?.len);
    up.deinit();
    // Every part buffer was given back.
    try testing.expectEqual(@as(u64, 0), env.client.memory_used.load(.acquire));
    up = try env.client.upload(env.c(), "again", .{});
}

test "s3: a part failing three times aborts the upload; later writes fail with its error" {
    const env = try Env.init(.{ .part_size = 5 * mib, .concurrency = 1 });
    defer env.deinit();
    try env.fake.addFault(.{ .method = "PUT", .query = "partNumber", .remaining = 1000, .status = 500, .code = "InternalError" });
    const q = Quiet.on();
    defer q.done();
    var up = try env.client.upload(env.c(), "fail.bin", .{});
    defer up.deinit();
    const chunk = try pattern(env.ctx.arena, mib, 2);
    var failed = false;
    for (0..9) |_| {
        if (up.write(env.c(), chunk)) |w| {
            if (w == .busy) {
                // Wait for the first part to be given up on, or for room.
                up.waitWritable(env.c(), null) catch {
                    failed = true;
                    break;
                };
            }
        } else |err| {
            failed = true;
            try testing.expect(err == error.ServiceUnavailable);
            break;
        }
    }
    if (!failed) try testing.expectError(error.ServiceUnavailable, up.finish(env.c()));
    try testing.expectEqualStrings("InternalError", env.lastCode());
    try testing.expectEqual(@as(usize, 3), env.fake.count("PUT", "partNumber="));
    try testing.expectError(error.ServiceUnavailable, up.write(env.c(), chunk));
    try testing.expect(env.fake.getObject("b", "fail.bin") == null);
    up.abort();
    try testing.expectEqual(@as(usize, 0), env.fake.openUploads());
}

test "s3: deinit before finish aborts the multipart upload" {
    const env = try Env.init(.{ .part_size = 5 * mib });
    defer env.deinit();
    var up = try env.client.upload(env.c(), "abandoned.bin", .{});
    const data = try pattern(env.ctx.arena, 6 * mib, 4);
    _ = try up.write(env.c(), data);
    // A part request means the server knows the upload and so do we.
    while (env.fake.count("PUT", "partNumber=") == 0) try tio().sleep(.fromMilliseconds(5), .awake);
    up.deinit();
    try testing.expectEqual(@as(usize, 0), env.fake.openUploads());
    try testing.expectEqual(@as(usize, 1), env.fake.count("DELETE", "uploadId="));
    try testing.expect(env.fake.getObject("b", "abandoned.bin") == null);
}

test "s3: upload_memory is shared: a second upload cannot take a buffer while the first holds it" {
    const env = try Env.init(.{ .part_size = 5 * mib, .upload_memory = 5 * mib });
    defer env.deinit();
    var a = try env.client.upload(env.c(), "a", .{});
    defer a.deinit();
    var b = try env.client.upload(env.c(), "b", .{});
    defer b.deinit();
    _ = try a.write(env.c(), "x");
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.ServiceUnavailable, b.write(env.c(), "y"));
    try testing.expectEqualStrings("upload_full", env.lastCode());
    _ = try a.finish(env.c());
    a.deinit();
    a = try env.client.upload(env.c(), "a2", .{});
    // The memory is back.
    _ = try b.write(env.c(), "y");
    _ = try b.finish(env.c());
}

test "s3: retry: 503 SlowDown twice then 200 is three requests; with retry false it is ServiceUnavailable after one" {
    const env = try Env.init(.{});
    defer env.deinit();
    try env.fake.addFault(.{ .method = "PUT", .remaining = 2 });
    _ = try env.client.put(env.c(), "k", .{ .bytes = "v" }, .{});
    try testing.expectEqual(@as(usize, 3), env.fake.count("PUT", "/b/k"));

    try env.fake.addFault(.{ .method = "PUT", .remaining = 1 });
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.ServiceUnavailable, env.client.with(.{ .retry = false }).put(env.c(), "k2", .{ .bytes = "v" }, .{}));
    try testing.expectEqual(@as(usize, 1), env.fake.count("PUT", "/b/k2"));
    try testing.expectEqualStrings("SlowDown", env.lastCode());
}

test "s3: RequestTimeTooSkewed teaches the clock and the call is repeated once" {
    const env = try Env.init(.{});
    defer env.deinit();
    var buf: [29]u8 = undefined;
    const ahead = util.formatHttpDate(&buf, util.nowSeconds(tio()) + 3600);
    try env.fake.addFault(.{ .remaining = 1, .status = 403, .code = "RequestTimeTooSkewed", .date = ahead });
    _ = try env.client.put(env.c(), "skew", .{ .bytes = "v" }, .{});
    try testing.expectEqual(@as(usize, 2), env.fake.count("PUT", "/b/skew"));
    try testing.expect(env.client.clock_offset.load(.monotonic) > 3000);
}

test "s3: refused connects open the breaker; the next call is ServiceUnavailable circuit_open with no dial" {
    const env = try Env.init(.{ .endpoint = "http://127.0.0.1:1", .retry = null, .breaker = .{ .consecutive_failures = 3 } });
    defer env.deinit();
    const q = Quiet.on();
    defer q.done();
    for (0..3) |_| {
        try testing.expectError(error.ServiceUnavailable, env.client.get(env.c(), "k", .{}));
        try testing.expectEqualStrings("transport", env.lastCode());
    }
    try testing.expectError(error.ServiceUnavailable, env.client.get(env.c(), "k", .{}));
    try testing.expectEqualStrings("circuit_open", env.lastCode());
}

test "s3: a 200 answer to CopyObject whose body is an Error is that error" {
    const env = try Env.init(.{ .retry = null });
    defer env.deinit();
    _ = try env.client.put(env.c(), "src", .{ .bytes = "v" }, .{});
    try env.fake.addFault(.{ .method = "PUT", .remaining = 1, .status = 200, .code = "InternalError" });
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.ServiceUnavailable, env.client.copy(env.c(), .{ .key = "src" }, "dst", .{}));
    try testing.expectEqualStrings("InternalError", env.lastCode());
}

test "s3: list: pages through iterate, a delimiter gives prefixes, control characters survive" {
    const env = try Env.init(.{});
    defer env.deinit();
    for ([_][]const u8{ "a/1", "a/2", "b/1", "c", "d\ne" }) |k| try env.fake.putObject("b", k, "x", "text/plain");
    var it = env.client.iterate(env.c(), .{ .max_keys = 2 });
    var keys: std.ArrayList([]const u8) = .empty;
    while (try it.next(env.c())) |e| try keys.append(env.ctx.arena, e.key);
    try testing.expectEqual(@as(usize, 5), keys.items.len);
    try testing.expectEqualStrings("a/1", keys.items[0]);
    try testing.expectEqualStrings("d\ne", keys.items[4]);
    const page = try env.client.list(env.c(), .{ .delimiter = "/" });
    try testing.expectEqual(@as(usize, 2), page.prefixes.len);
    try testing.expectEqual(@as(usize, 2), page.entries.len);
    try testing.expectEqualStrings("a/", page.prefixes[0]);
    try testing.expect(page.next == null);
    const first = try env.client.list(env.c(), .{ .max_keys = 2 });
    try testing.expect(first.next != null);
    try testing.expectEqual(@as(usize, 2), first.entries.len);
}

test "s3: deleteMany sends 1000 keys per request with Content-MD5" {
    const env = try Env.init(.{});
    defer env.deinit();
    const keys = try env.ctx.arena.alloc([]const u8, 2500);
    for (keys, 0..) |*k, i| k.* = try std.fmt.allocPrint(env.ctx.arena, "k/{d}", .{i});
    try env.fake.putObject("b", "k/7", "x", "text/plain");
    const r = try env.client.deleteMany(env.c(), keys);
    try testing.expectEqual(@as(u32, 2500), r.deleted);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
    try testing.expectEqual(@as(usize, 3), env.fake.count("POST", "delete"));
    try testing.expect(env.fake.getObject("b", "k/7") == null);
}

test "s3: copy keeps the metadata unless replace_metadata is set" {
    const env = try Env.init(.{});
    defer env.deinit();
    _ = try env.client.put(env.c(), "orig", .{ .bytes = "payload" }, .{ .metadata = &.{.{ "tag", "one" }} });
    _ = try env.client.copy(env.c(), .{ .key = "orig" }, "copy1", .{});
    try testing.expectEqualStrings("one", (try env.client.head(env.c(), "copy1", .{})).meta("tag").?);
    _ = try env.client.copy(env.c(), .{ .key = "orig" }, "copy2", .{ .replace_metadata = true, .metadata = &.{.{ "tag", "two" }} });
    try testing.expectEqualStrings("two", (try env.client.head(env.c(), "copy2", .{})).meta("tag").?);
    try testing.expectEqualStrings("payload", env.fake.getObject("b", "copy2").?);
}

fn rawPut(url: []const u8, headers: []const [2][]const u8, body: []const u8) !u16 {
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    var keys: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    var hashes: [8]u8 = undefined;
    var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    for (headers) |p| try h.add(p[0], p[1]);
    var resp = try http.fetch(url, .{ .method = .put, .headers = &h, .body = body, .decompress = false });
    defer resp.deinit();
    return code(&resp);
}

test "s3: a presigned PUT with content_length accepts that length and refuses another" {
    const env = try Env.init(.{});
    defer env.deinit();
    const url = try env.client.presign(env.c(), .put, "up/presigned.txt", .{ .content_type = "text/plain", .content_length = 5 });
    try testing.expectEqual(@as(u16, 200), try rawPut(url, &.{.{ "Content-Type", "text/plain" }}, "12345"));
    try testing.expectEqualStrings("12345", env.fake.getObject("b", "up/presigned.txt").?);
    // The browser sends another length: the signature does not cover it.
    try testing.expectEqual(@as(u16, 403), try rawPut(url, &.{.{ "Content-Type", "text/plain" }}, "123456"));
    try testing.expect(env.fake.signature_failures >= 1);
}

test "s3: a presigned GET is usable by anyone; a zero expiry is refused" {
    const env = try Env.init(.{});
    defer env.deinit();
    _ = try env.client.put(env.c(), "pub.txt", .{ .bytes = "public" }, .{});
    const url = try env.client.presign(env.c(), .get, "pub.txt", .{ .expires = .fromSeconds(60), .response_content_type = "text/x-test" });
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    var resp = try http.fetch(url, .{});
    defer resp.deinit();
    try testing.expectEqual(@as(u16, 200), code(&resp));
    try testing.expectEqualStrings("public", (try resp.body()).?);
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.BadRequest, env.client.presign(env.c(), .get, "k", .{ .expires = .fromSeconds(0) }));
}

test "s3: multipart for browsers: create, presigned upload_part URLs, complete" {
    const env = try Env.init(.{});
    defer env.deinit();
    const mp = env.client.multipart();
    const id = try mp.create(env.c(), "browser.bin", .{ .content_type = "application/octet-stream" });
    const part1 = try pattern(env.ctx.arena, 5 * mib, 1);
    const part2 = "tail";
    var parts: [2]s3.Part = undefined;
    for ([_][]const u8{ part1, part2 }, 0..) |data, i| {
        const url = try env.client.presign(env.c(), .upload_part, "browser.bin", .{ .upload_id = id, .part_number = @intCast(i + 1) });
        var http = dusty.Client.init(testing.allocator, tio(), .{});
        defer http.deinit();
        var resp = try http.fetch(url, .{ .method = .put, .body = data, .decompress = false });
        defer resp.deinit();
        try testing.expectEqual(@as(u16, 200), code(&resp));
        parts[i] = .{ .number = @intCast(i + 1), .etag = try env.ctx.arena.dupe(u8, resp.headers().get("ETag").?) };
    }
    const stored = try mp.complete(env.c(), "browser.bin", id, &parts);
    try testing.expectEqual(@as(u32, 2), stored.parts);
    try testing.expectEqual(5 * mib + 4, env.fake.getObject("b", "browser.bin").?.len);
    const id2 = try mp.create(env.c(), "gone.bin", .{});
    try mp.abort(env.c(), "gone.bin", id2);
    try testing.expectEqual(@as(usize, 0), env.fake.openUploads());
}

test "s3: the download idle bound: a server that stops sending mid-body fails the read with GatewayTimeout" {
    const env = try Env.init(.{ .timeout = .fromMilliseconds(100) });
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 200_000, 8);
    try env.fake.putObject("b", "stall.bin", data, "application/octet-stream");
    env.fake.stall_gets = true;
    var dl = try env.client.open(env.c(), "stall.bin", .{});
    defer dl.deinit();
    var sink: std.Io.Writer.Allocating = .init(env.ctx.arena);
    try testing.expectError(error.GatewayTimeout, dl.pipe(&sink.writer));
    env.fake.releaseStall();
}

test "s3: the bound of a call that moves a body is timeout + bytes / min_throughput" {
    const env = try Env.init(.{ .timeout = .fromSeconds(30), .min_throughput = mib });
    defer env.deinit();
    const b = env.client.boundFor(.{}, 8 * mib).?;
    try testing.expectEqual(@as(i96, 38 * std.time.ns_per_s), b.nanoseconds);
    try testing.expect(env.client.boundFor(.{ .timeout = .max }, 1) == null);
}

test "s3: drain: a new upload is ServiceUnavailable (draining)" {
    const env = try Env.init(.{});
    defer env.deinit();
    env.client.drain(std.Io.Clock.Timestamp.now(tio(), .awake));
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.ServiceUnavailable, env.client.upload(env.c(), "k", .{}));
    try testing.expectEqualStrings("draining", env.lastCode());
}

test "s3: a call without a bucket is a BadRequest with a clear code; bucket(name) works" {
    try Rt.start();
    defer Rt.stop();
    const fake = try FakeServer.start(testing.allocator, tio());
    defer fake.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = try s3.Client.init(testing.allocator, tio(), .{ .endpoint = fake.url(), .credentials = fake.credentials() });
    defer client.deinit();
    var c: db.Ctx = .{ .io = tio(), .arena = arena.allocator() };
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.BadRequest, client.get(&c, "k", .{}));
    try testing.expectEqualStrings("no_bucket", db.lastError(&c).?.code);
    _ = try client.bucket("other").put(&c, "k", .{ .bytes = "v" }, .{});
    try testing.expectEqualStrings("v", fake.getObject("other", "k").?);
}

test "s3: bad options are refused at init" {
    try Rt.start();
    defer Rt.stop();
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.InvalidOptions, s3.Client.init(testing.allocator, tio(), .{ .part_size = 1024 }));
    try testing.expectError(error.InvalidOptions, s3.Client.init(testing.allocator, tio(), .{ .concurrency = 0 }));
    try testing.expectError(error.InvalidOptions, s3.Client.init(testing.allocator, tio(), .{ .endpoint = "ftp://x" }));
}

// ---- Through a running HTTP server: serve and put(.request) -------------------

const Gateway = struct {
    files: *s3.Client,

    fn serve(self: *Gateway, req: *dusty.Request, res: *dusty.Response) !void {
        _ = self.files.serve(req, res, req.params.get("rest") orelse "", .{}) catch |err| {
            if (err == error.NotFound) {
                res.status = .not_found;
                res.body = "no such file";
                return;
            }
            return err;
        };
    }

    fn upload(self: *Gateway, req: *dusty.Request, res: *dusty.Response) !void {
        const stored = try self.files.put(req, "uploaded.bin", .request, .{});
        res.body = stored.etag;
    }
};

fn runGateway(server: *dusty.Server(Gateway)) anyerror!void {
    try server.run();
}

test "s3: serve answers from the object: headers, Range, If-None-Match, HEAD and the handler's 404" {
    const env = try Env.init(.{});
    defer env.deinit();
    const data = try pattern(env.ctx.arena, 100_000, 6);
    try env.fake.putObject("b", "pics/cat.png", data, "image/png");

    var gw: Gateway = .{ .files = env.client };
    const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};
    var server = dusty.Server(Gateway).init(testing.allocator, tio(), .{ .listeners = loopback }, &gw);
    defer server.deinit();
    server.router.get("/f/*rest", Gateway.serve);
    server.router.head("/f/*rest", Gateway.serve);
    var fut = try tio().concurrent(runGateway, .{&server});
    defer _ = fut.cancel(tio()) catch {};
    try server.waitReady(tio());

    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    const base = try std.fmt.allocPrint(env.ctx.arena, "http://127.0.0.1:{d}/f/pics/cat.png", .{server.address.ip.getPort()});

    var keys: [4][]const u8 = undefined;
    var values: [4][]const u8 = undefined;
    var hashes: [4]u8 = undefined;
    var etag: []const u8 = "";
    {
        var resp = try http.fetch(base, .{});
        defer resp.deinit();
        try testing.expectEqual(@as(u16, 200), code(&resp));
        try testing.expectEqualStrings("image/png", resp.headers().get("Content-Type").?);
        try testing.expectEqualStrings("bytes", resp.headers().get("Accept-Ranges").?);
        etag = try env.ctx.arena.dupe(u8, resp.headers().get("ETag").?);
        try testing.expectEqualSlices(u8, data, (try resp.body()).?);
    }
    {
        var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
        try h.add("If-None-Match", etag);
        var r304 = try http.fetch(base, .{ .headers = &h });
        defer r304.deinit();
        try testing.expectEqual(@as(u16, 304), code(&r304));
    }
    {
        var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
        try h.add("Range", "bytes=10-19");
        var part = try http.fetch(base, .{ .headers = &h });
        defer part.deinit();
        try testing.expectEqual(@as(u16, 206), code(&part));
        try testing.expectEqualStrings("bytes 10-19/100000", part.headers().get("Content-Range").?);
        try testing.expectEqualSlices(u8, data[10..20], (try part.body()).?);
    }
    {
        var head = try http.fetch(base, .{ .method = .head });
        defer head.deinit();
        try testing.expectEqual(@as(u16, 200), code(&head));
        try testing.expectEqualStrings("100000", head.headers().get("Content-Length").?);
    }
    {
        const missing = try std.fmt.allocPrint(env.ctx.arena, "http://127.0.0.1:{d}/f/nope.png", .{server.address.ip.getPort()});
        var resp = try http.fetch(missing, .{});
        defer resp.deinit();
        try testing.expectEqual(@as(u16, 404), code(&resp));
        try testing.expectEqualStrings("no such file", (try resp.body()).?);
    }
}

test "s3: put(.request) sends the request body to the object without the handler reading it" {
    const env = try Env.init(.{ .part_size = 5 * mib });
    defer env.deinit();
    var gw: Gateway = .{ .files = env.client };
    const loopback: []const dusty.Listener = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};
    var server = dusty.Server(Gateway).init(testing.allocator, tio(), .{ .listeners = loopback, .request = .{ .max_body_size = 64 * mib } }, &gw);
    defer server.deinit();
    server.router.post("/upload", Gateway.upload);
    var fut = try tio().concurrent(runGateway, .{&server});
    defer _ = fut.cancel(tio()) catch {};
    try server.waitReady(tio());

    const body = try pattern(env.ctx.arena, 12 * mib, 11);
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    const url = try std.fmt.allocPrint(env.ctx.arena, "http://127.0.0.1:{d}/upload", .{server.address.ip.getPort()});
    var resp = try http.fetch(url, .{ .method = .post, .body = body, .decompress = false });
    defer resp.deinit();
    try testing.expectEqual(@as(u16, 200), code(&resp));
    try testing.expectEqualSlices(u8, body, env.fake.getObject("b", "uploaded.bin").?);
    try testing.expect(env.fake.count("PUT", "partNumber=") >= 3);
}

// ---- Credentials against the fake ------------------------------------------------

const MapEnv = struct {
    pairs: []const [2][]const u8,
    fn get(context: ?*const anyopaque, _: ?std.process.Environ, name: []const u8, _: bool) ?[]const u8 {
        const self: *const MapEnv = @ptrCast(@alignCast(context.?));
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }
};

fn provider(http: *dusty.Client, envp: *const MapEnv) credentials.Provider {
    return .{
        .gpa = testing.allocator,
        .io = tio(),
        .http = http,
        .label = "t",
        .environ = null,
        .is_aws = true,
        .region = "us-east-1",
        .file_path = "/nonexistent/anole/credentials",
        .env = .{ .context = envp, .get_fn = MapEnv.get },
    };
}

test "s3: credentials: the container endpoint with an authorization token" {
    try Rt.start();
    defer Rt.stop();
    const fake = try FakeServer.start(testing.allocator, tio());
    defer fake.stop();
    try fake.answer(.{ .path = "/creds", .body = "{\"AccessKeyId\":\"AKCONT\",\"SecretAccessKey\":\"scont\",\"Token\":\"tcont\",\"Expiration\":\"2099-01-01T00:00:00Z\"}" });
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/creds", .{fake.url()});
    defer testing.allocator.free(full);
    const envp: MapEnv = .{ .pairs = &.{ .{ "AWS_CONTAINER_CREDENTIALS_FULL_URI", full }, .{ "AWS_CONTAINER_AUTHORIZATION_TOKEN", "secret-token" } } };
    var p = provider(&http, &envp);
    defer p.deinit();
    try p.resolve(0);
    const s = p.acquire().?;
    defer p.release(s);
    try testing.expectEqualStrings("AKCONT", s.access_key_id);
    try testing.expectEqualStrings("tcont", s.token.?);
    try testing.expect(s.expires.? > util.nowSeconds(tio()));
}

test "s3: credentials: IMDSv2 asks for a token, then the role, then its credentials" {
    try Rt.start();
    defer Rt.stop();
    const fake = try FakeServer.start(testing.allocator, tio());
    defer fake.stop();
    try fake.answer(.{ .method = "PUT", .path = "/latest/api/token", .body = "imds-token" });
    try fake.answer(.{ .method = "GET", .path = "/latest/meta-data/iam/security-credentials/", .body = "my-role\n" });
    try fake.answer(.{ .method = "GET", .path = "/latest/meta-data/iam/security-credentials/my-role", .body = "{\"Code\":\"Success\",\"AccessKeyId\":\"AKIMDS\",\"SecretAccessKey\":\"simds\",\"Token\":\"timds\",\"Expiration\":\"2099-01-01T00:00:00Z\"}" });
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    const envp: MapEnv = .{ .pairs = &.{} };
    var p = provider(&http, &envp);
    p.imds_base = fake.url();
    defer p.deinit();
    try p.resolve(0);
    const s = p.acquire().?;
    defer p.release(s);
    try testing.expectEqualStrings("AKIMDS", s.access_key_id);
    try testing.expectEqual(@as(usize, 3), fake.count(null, "/latest/"));
}

test "s3: credentials: web identity calls STS with the token file's content" {
    try Rt.start();
    defer Rt.stop();
    const fake = try FakeServer.start(testing.allocator, tio());
    defer fake.stop();
    try fake.answer(.{ .method = "POST", .path = "/sts", .body = "<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>AKSTS</AccessKeyId><SecretAccessKey>ssts</SecretAccessKey><SessionToken>tsts</SessionToken><Expiration>2099-01-01T00:00:00Z</Expiration></Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>" });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "token", .data = "jwt-from-kubernetes\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, "token", &buf);
    var http = dusty.Client.init(testing.allocator, tio(), .{});
    defer http.deinit();
    const envp: MapEnv = .{ .pairs = &.{ .{ "AWS_WEB_IDENTITY_TOKEN_FILE", buf[0..n] }, .{ "AWS_ROLE_ARN", "arn:aws:iam::123:role/r" } } };
    var p = provider(&http, &envp);
    const sts = try std.fmt.allocPrint(testing.allocator, "{s}/sts", .{fake.url()});
    defer testing.allocator.free(sts);
    p.sts_url = sts;
    defer p.deinit();
    try p.resolve(0);
    const s = p.acquire().?;
    defer p.release(s);
    try testing.expectEqualStrings("AKSTS", s.access_key_id);
    try testing.expectEqualStrings("tsts", s.token.?);
}

test "s3: anonymous credentials send unsigned requests (the fake refuses them)" {
    try Rt.start();
    defer Rt.stop();
    const fake = try FakeServer.start(testing.allocator, tio());
    defer fake.stop();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const client = try s3.Client.init(testing.allocator, tio(), .{ .endpoint = fake.url(), .bucket = "b", .credentials = .anonymous, .retry = null });
    defer client.deinit();
    var c: db.Ctx = .{ .io = tio(), .arena = arena.allocator() };
    const q = Quiet.on();
    defer q.done();
    try testing.expectError(error.Database, client.get(&c, "k", .{}));
    try testing.expectEqualStrings("SignatureDoesNotMatch", db.lastError(&c).?.code);
}
