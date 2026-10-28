//! C ABI tests for p3/s3: the engine's S3 calls against `anole.s3.testing.FakeServer`,
//! driven through the engine's Zig entry points as in nats_test.zig. Waits poll
//! the consumer with generous bounds; no assertion is about time.
const std = @import("std");
const wait = @import("anole_test_wait");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const parity = @import("parity.zig");
const config = @import("config.zig");
const abi = engine.abi;
const features = anole.features;
const zio = anole.zio;

const alloc = std.testing.allocator;
const mib: usize = 1024 * 1024;

const Events = struct {
    c: *engine.Consumer,
    list: std.ArrayList(struct { typ: u32, handle: u64, bytes: []align(8) u8 }) = .empty,

    fn pump(ev: *Events, ms: i32) !void {
        var stack: [256 * 1024]u8 align(8) = undefined;
        var heap: []align(8) u8 = &.{};
        defer alloc.free(heap);
        var need: u32 = 0;
        var buf: []align(8) u8 = &stack;
        const n = engine.pollWait(ev.c, buf, ms, &need) catch |err| switch (err) {
            // A record larger than the stack buffer (a request with a big
            // inline body): once more into one that fits it.
            error.TooBig => blk: {
                heap = try alloc.alignedAlloc(u8, .@"8", need);
                buf = heap;
                break :blk try engine.pollWait(ev.c, buf, 0, &need);
            },
        };
        var off: usize = 0;
        while (off < n) {
            const head: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
            const copy = try alloc.alignedAlloc(u8, .@"8", head.len);
            @memcpy(copy, buf[off..][0..head.len]);
            try ev.list.append(alloc, .{ .typ = head.type, .handle = head.handle, .bytes = copy });
            off += head.len;
        }
    }

    /// The first record of `typ` at or after `from` (polling up to `ms`).
    fn waitFor(ev: *Events, typ: abi.EventType, from: usize, ms: u32) !usize {
        const started = std.Io.Clock.awake.now(engine.threadedIo());
        while (true) {
            for (ev.list.items[from..], from..) |r, i| if (r.typ == @backingInt(typ)) return i;
            if (pastDeadline(started, ms)) return error.TimedOut;
            try ev.pump(50);
        }
    }

    /// The S3 result with `user_data`.
    fn result(ev: *Events, user_data: u64) !*const abi.S3ResultEvent {
        const started = std.Io.Clock.awake.now(engine.threadedIo());
        while (true) {
            for (ev.list.items) |r| if (r.typ == @backingInt(abi.EventType.s3_result)) {
                const rec: *const abi.S3ResultEvent = @ptrCast(@alignCast(r.bytes.ptr));
                if (rec.user_data == user_data) return rec;
            };
            if (pastDeadline(started, 15000)) {
                for (ev.list.items) |r| if (r.typ == @backingInt(abi.EventType.s3_result)) {
                    const rec: *const abi.S3ResultEvent = @ptrCast(@alignCast(r.bytes.ptr));
                    std.debug.print("result user_data {d} op {d} status {d} class {d}: {s} ({s})\n", .{ rec.user_data, rec.op, rec.status, rec.error_class, text(rec, rec.@"error"), text(rec, rec.error_code) });
                };
                return error.TimedOut;
            }
            try ev.pump(50);
        }
    }

    fn deinit(ev: *Events) void {
        for (ev.list.items) |r| alloc.free(r.bytes);
        ev.list.deinit(alloc);
    }
};

fn text(rec: anytype, span: abi.Span) []const u8 {
    const bytes: [*]const u8 = @ptrCast(rec);
    return bytes[span.off..][0..span.len];
}

const Rig = struct {
    rt: *zio.Runtime,
    fake: *anole.s3.testing.FakeServer,
    e: *engine.Engine,
    c: *engine.Consumer,
    ev: Events,
    json: []u8,

    /// What a test changes in the rig's configuration.
    const Tuning = struct {
        /// `limits.inline_body_max` (0: the default).
        inline_body_max: u32 = 0,
        /// The storage's `concurrency`.
        concurrency: u8 = 2,
        /// The storage's `retry.attempts`.
        attempts: u8 = 1,
    };

    fn start(r: *Rig, route: bool) !void {
        return r.startWith(route, .{});
    }

    fn startWith(r: *Rig, route: bool, t: Tuning) !void {
        // Workers only: the test thread polls the consumer and must not be an executor the fake needs.
        r.rt = try zio.Runtime.init(alloc, .{ .executors = .exact(2), .enable_main_executor = false });
        errdefer r.rt.deinit();
        r.fake = try anole.s3.testing.FakeServer.start(alloc, r.rt.io());
        errdefer r.fake.stop();
        var inline_buf: [48]u8 = undefined;
        const inline_max = if (t.inline_body_max == 0) "" else try std.fmt.bufPrint(&inline_buf, ", \"inline_body_max\": {d}", .{t.inline_body_max});
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 2, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "limits": {{"body_max": 33554432{s}}},
            \\ "routes": [{s}],
            \\ "storage": [{{"name": "files", "s3": {{"endpoint": "{s}", "bucket": "b",
            \\   "access_key_id": "{s}", "secret_access_key": "{s}", "part_size": 5242880, "concurrency": {d}}},
            \\   "retry": {{"attempts": {d}, "base_ms": 1}}}}]}}
        , .{
            inline_max,
            if (route) "{\"path\": \"/f/obj\", \"handler\": 1, \"timeout_ms\": 20000}, {\"path\": \"/f/up\", \"method\": \"POST\", \"handler\": 1, \"timeout_ms\": 20000}" else "",
            r.fake.url(),
            anole.s3.testing.access_key_id,
            anole.s3.testing.secret_access_key,
            t.concurrency,
            t.attempts,
        });
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        try r.e.start();
        r.ev = .{ .c = r.c };
    }

    fn store(r: *Rig) *engine.s3.Store {
        return engine.s3.find(r.e, "files").?;
    }

    fn deinit(r: *Rig) void {
        r.ev.deinit();
        r.e.drain() catch {};
        _ = r.e.wait(5000);
        r.e.destroy();
        r.fake.stop();
        alloc.free(r.json);
        r.rt.deinit();
    }
};

fn pattern(buf: []u8, seed: u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
}

fn sleepMs(ms: i64) void {
    std.Io.sleep(engine.threadedIo(), .fromMilliseconds(ms), .awake) catch {};
}

test "capi s3: put then get whole: the RESULT has the body and the etag" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    const st = r.store();
    try engine.s3.put(st, r.c, .of("a.txt"), "hello", .{}, 1);
    const put = try r.ev.result(1);
    try std.testing.expectEqual(abi.OK, put.status);
    try std.testing.expectEqual(abi.S3_OP_PUT, put.op);
    try std.testing.expect(put.etag.len > 0);
    try engine.s3.get(st, r.c, .of("a.txt"), .{}, 2, false);
    const got = try r.ev.result(2);
    try std.testing.expectEqual(abi.OK, got.status);
    try std.testing.expectEqual(abi.S3_OP_GET, got.op);
    try std.testing.expectEqual(@as(u16, 200), got.s3_status);
    try std.testing.expectEqualStrings("hello", text(got, got.body));
    try std.testing.expectEqual(@as(u64, 5), got.object_size);
    try std.testing.expect(std.mem.startsWith(u8, text(got, got.content_type), "text/plain"));
}

test "capi s3: a missing key answers E_SERVICE, class NOT_FOUND, http 404, code NoSuchKey" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    try engine.s3.get(r.store(), r.c, .of("nope"), .{}, 3, false);
    const got = try r.ev.result(3);
    try std.testing.expectEqual(abi.E_SERVICE, got.status);
    try std.testing.expectEqual(@as(u8, @backingInt(abi.DbErrorClass.not_found)), got.error_class);
    try std.testing.expectEqual(@as(u16, 404), got.http_status);
    try std.testing.expectEqualStrings("NoSuchKey", text(got, got.error_code));
}

test "capi s3: list gives entries and prefixes; delete_many deletes" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    for ([_][]const u8{ "d/1", "d/2", "top" }) |k| try r.fake.putObject("b", k, "xyz", "text/plain");
    try engine.s3.listObjects(r.store(), r.c, .{ .delimiter = .of("/") }, 4);
    const page = try r.ev.result(4);
    try std.testing.expectEqual(abi.OK, page.status);
    try std.testing.expectEqual(@as(u32, 1), page.nentries);
    try std.testing.expectEqual(@as(u32, 1), page.nprefixes);
    const bytes: [*]const u8 = @ptrCast(page);
    const entry: *const abi.S3Entry = @ptrCast(@alignCast(bytes + page.entries_off));
    try std.testing.expectEqualStrings("top", text(page, entry.key));
    try std.testing.expectEqual(@as(u64, 3), entry.size);
    const prefixes: [*]const abi.Span = @ptrCast(@alignCast(bytes + page.prefixes_off));
    try std.testing.expectEqualStrings("d/", text(page, prefixes[0]));

    try engine.s3.deleteMany(r.store(), r.c, &.{ .of("d/1"), .of("d/2") }, .{}, 5);
    const del = try r.ev.result(5);
    try std.testing.expectEqual(abi.OK, del.status);
    try std.testing.expectEqual(@as(u32, 0), del.nentries);
    try std.testing.expect(r.fake.getObject("b", "d/1") == null);
}

test "capi s3: get STREAM with a 128 KiB window delivers DATA up to the window, read_more resumes, FIN ends" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    const data = try alloc.alloc(u8, 300 * 1024);
    defer alloc.free(data);
    pattern(data, 9);
    try r.fake.putObject("b", "big.bin", data, "application/octet-stream");
    try engine.s3.get(r.store(), r.c, .of("big.bin"), .{ .flags = abi.S3_F_STREAM, .window = 128 * 1024 }, 6, false);
    const head = try r.ev.result(6);
    try std.testing.expectEqual(abi.OK, head.status);
    const handle = head.ev.handle;
    try std.testing.expect(handle != 0);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var seen: usize = 0;
    var idle: u32 = 0;
    // Until the window is used up.
    while (got.items.len < 128 * 1024 and idle < 400) : (idle += 1) {
        try r.ev.pump(50);
        for (r.ev.list.items[seen..]) |rec| {
            if (rec.typ != @backingInt(abi.EventType.s3_data)) continue;
            const d: *const abi.S3DataEvent = @ptrCast(@alignCast(rec.bytes.ptr));
            try got.appendSlice(alloc, text(d, d.data));
        }
        seen = r.ev.list.items.len;
    }
    try std.testing.expectEqual(@as(usize, 128 * 1024), got.items.len);
    // Nothing beyond the window arrives until there is credit.
    try r.ev.pump(200);
    for (r.ev.list.items[seen..]) |rec| try std.testing.expect(rec.typ != @backingInt(abi.EventType.s3_data));
    try engine.s3.readMore(r.e, handle, 1 << 20);
    var fin = false;
    idle = 0;
    while (!fin and idle < 400) : (idle += 1) {
        try r.ev.pump(50);
        for (r.ev.list.items[seen..]) |rec| {
            if (rec.typ != @backingInt(abi.EventType.s3_data)) continue;
            const d: *const abi.S3DataEvent = @ptrCast(@alignCast(rec.bytes.ptr));
            try got.appendSlice(alloc, text(d, d.data));
            if (d.flags & abi.S3_DATA_F_FIN != 0) fin = true;
        }
        seen = r.ev.list.items.len;
    }
    try std.testing.expect(fin);
    try std.testing.expectEqualSlices(u8, data, got.items);
    // The handle is over (it goes once the FIN is out).
    const Over = struct {
        e: *engine.Engine,
        h: u64,
        fn gone(o: @This()) bool {
            _ = engine.s3.readMore(o.e, o.h, 1) catch |err| return err == error.Gone;
            return false;
        }
    };
    try wait.waitUntil(engine.threadedIo(), "the finished download's handle is gone", Over{ .e = r.e, .h = handle }, Over.gone);
}

test "capi s3: a push upload: write OK, BORROW refused, finish answers UPLOAD_FINISH with parts" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    try engine.s3.uploadOpen(r.store(), r.c, .of("up.bin"), .{}, 10);
    const opened = try r.ev.result(10);
    try std.testing.expectEqual(abi.OK, opened.status);
    try std.testing.expectEqual(abi.S3_OP_UPLOAD_OPEN, opened.op);
    const t = opened.ev.handle;
    try std.testing.expect(t != 0);
    try std.testing.expectError(error.Invalid, engine.s3.uploadWrite(r.e, t, "x", abi.BODY_BORROW));
    const chunk = try alloc.alloc(u8, mib);
    defer alloc.free(chunk);
    pattern(chunk, 3);
    var written: usize = 0;
    while (written < 6 * mib) {
        const busy = engine.s3.uploadWrite(r.e, t, chunk, 0) catch |err| switch (err) {
            error.Again => {
                // Room comes back with a WRITABLE on the handle.
                const before = r.ev.list.items.len;
                _ = try r.ev.waitFor(.writable, before, 15000);
                continue;
            },
            else => return err,
        };
        written += chunk.len;
        if (busy) {
            const before = r.ev.list.items.len;
            _ = try r.ev.waitFor(.writable, before, 15000);
        }
    }
    try engine.s3.uploadFinish(r.e, t, 11);
    errdefer for (r.fake.log.items) |l| std.debug.print("fake saw {s} {s} -> {d}\n", .{ l.method, l.target, l.status });
    const fin = try r.ev.result(11);
    try std.testing.expectEqual(abi.OK, fin.status);
    try std.testing.expectEqual(abi.S3_OP_UPLOAD_FINISH, fin.op);
    try std.testing.expectEqual(@as(u32, 2), fin.parts);
    try std.testing.expectEqual(6 * mib, r.fake.getObject("b", "up.bin").?.len);
}

test "capi s3: releasing an upload aborts it" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    try engine.s3.uploadOpen(r.store(), r.c, .of("gone.bin"), .{}, 12);
    const t = (try r.ev.result(12)).ev.handle;
    const chunk = try alloc.alloc(u8, mib);
    defer alloc.free(chunk);
    pattern(chunk, 5);
    for (0..6) |_| _ = try engine.s3.uploadWrite(r.e, t, chunk, 0);
    const tio = engine.threadedIo();
    try wait.waitUntil(tio, "a part reached the fake server", r.fake, struct {
        fn f(fake: *anole.s3.testing.FakeServer) bool {
            return fake.count("PUT", "partNumber=") >= 1;
        }
    }.f);
    try engine.s3.release(r.e, t);
    try wait.waitUntil(tio, "the released upload aborted on the server", r.fake, struct {
        fn f(fake: *anole.s3.testing.FakeServer) bool {
            return fake.openUploads() == 0;
        }
    }.f);
    try std.testing.expect(r.fake.getObject("b", "gone.bin") == null);
}

test "capi s3: presign returns the length; a small buffer gets nothing written" {
    if (comptime !features.s3) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(false);
    defer r.deinit();
    var big: [2048]u8 = undefined;
    const n = engine.s3.presign(r.store(), abi.S3_PRESIGN_GET, .of("pub.txt"), .{}, &big);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, big[0..@intCast(n)], "X-Amz-Signature=") != null);
    var small: [8]u8 = @splat(0xAA);
    try std.testing.expectEqual(n, engine.s3.presign(r.store(), abi.S3_PRESIGN_GET, .of("pub.txt"), .{}, &small));
    try std.testing.expectEqual(@as(u8, 0xAA), small[0]);
    try std.testing.expectEqual(@as(i64, abi.E_INVALID), engine.s3.presign(r.store(), 9, .of("k"), .{}, &big));
}

const HttpResult = struct { status: u16 = 0, body: []u8 = &.{} };

fn fetchTask(io: std.Io, url: []const u8, method: dusty.Method, body: ?[]const u8, out: *HttpResult) anyerror!void {
    var http = dusty.Client.init(alloc, io, .{});
    defer http.deinit();
    var resp = try http.fetch(url, .{ .method = method, .body = body, .decompress = false });
    defer resp.deinit();
    out.status = @intCast(@backingInt(resp.status()));
    if (method != .head) out.body = try alloc.dupe(u8, (try resp.body()) orelse "");
}

/// A GET with conditional headers (`names[i]: values[i]`).
fn fetchIfTask(io: std.Io, url: []const u8, names: []const []const u8, values_in: []const []const u8, out: *HttpResult) anyerror!void {
    var http = dusty.Client.init(alloc, io, .{});
    defer http.deinit();
    var keys: [4][]const u8 = undefined;
    var values: [4][]const u8 = undefined;
    var hashes: [4]u8 = undefined;
    var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    for (names, values_in) |n, v| try h.add(n, v);
    var resp = try http.fetch(url, .{ .headers = &h, .decompress = false });
    defer resp.deinit();
    out.status = @intCast(@backingInt(resp.status()));
    out.body = try alloc.dupe(u8, (try resp.body()) orelse "");
}

/// What a conditional GET of "obj.bin" (put now) is served with.
const Conditional = enum { if_unmodified_since_old, if_match_and_if_unmodified_since_old };

/// Serves "obj.bin" (put now) to one GET carrying the headers `which`
/// names; the status.
fn serveConditional(which: Conditional) !u16 {
    var r: Rig = undefined;
    try r.start(true);
    defer r.deinit();
    try r.fake.putObject("b", "obj.bin", "conditional", "text/plain");
    const old_date = "Sun, 06 Nov 1994 08:49:37 GMT";
    const names: []const []const u8, const values: []const []const u8 = switch (which) {
        .if_unmodified_since_old => .{ &.{"If-Unmodified-Since"}, &.{old_date} },
        .if_match_and_if_unmodified_since_old => .{ &.{ "If-Match", "If-Unmodified-Since" }, &.{ r.fake.getEtag("b", "obj.bin").?, old_date } },
    };
    const io = r.rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/f/obj", .{r.e.port(0)});
    var res: HttpResult = .{};
    defer alloc.free(res.body);
    var f = try io.concurrent(fetchIfTask, .{ io, url, names, values, &res });
    const i = try r.ev.waitFor(.request, 0, 15000);
    try engine.s3.serve(r.store(), r.ev.list.items[i].handle, .of("obj.bin"), .{}, 23);
    try f.await(io);
    return res.status;
}

test "capi s3: serve forwards If-Unmodified-Since: older than the object answers 412" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 412), try serveConditional(.if_unmodified_since_old));
}

test "capi s3: serve: a true If-Match wins over a false If-Unmodified-Since (200)" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u16, 200), try serveConditional(.if_match_and_if_unmodified_since_old));
}

test "capi s3: serve answers the request from the object; the body never enters the consumer" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(true);
    defer r.deinit();
    const data = try alloc.alloc(u8, 200_000);
    defer alloc.free(data);
    pattern(data, 7);
    try r.fake.putObject("b", "obj.bin", data, "application/x-test");
    const io = r.rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/f/obj", .{r.e.port(0)});
    var res: HttpResult = .{};
    defer alloc.free(res.body);
    var f = try io.concurrent(fetchTask, .{ io, url, dusty.Method.get, null, &res });
    const i = try r.ev.waitFor(.request, 0, 15000);
    try engine.s3.serve(r.store(), r.ev.list.items[i].handle, .of("obj.bin"), .{}, 20);
    try f.await(io);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualSlices(u8, data, res.body);
}

test "capi s3: serve with PASS_NOT_FOUND leaves the request owed and reports; the consumer answers" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(true);
    defer r.deinit();
    const io = r.rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/f/obj", .{r.e.port(0)});
    var res: HttpResult = .{};
    defer alloc.free(res.body);
    var f = try io.concurrent(fetchTask, .{ io, url, dusty.Method.get, null, &res });
    const i = try r.ev.waitFor(.request, 0, 15000);
    const req = r.ev.list.items[i].handle;
    try engine.s3.serve(r.store(), req, .of("missing.bin"), .{ .flags = abi.S3_F_PASS_NOT_FOUND }, 21);
    const rep = try r.ev.result(21);
    try std.testing.expectEqual(@as(u8, @backingInt(abi.DbErrorClass.not_found)), rep.error_class);
    try engine.respond(r.e, req, 404, &.{}, "custom not found", false);
    try f.await(io);
    try std.testing.expectEqual(@as(u16, 404), res.status);
    try std.testing.expectEqualStrings("custom not found", res.body);
}

test "capi s3: put_body stores the request body without the consumer reading it; the request stays owed" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(true);
    defer r.deinit();
    const body = try alloc.alloc(u8, 12 * mib);
    defer alloc.free(body);
    pattern(body, 2);
    const io = r.rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/f/up", .{r.e.port(0)});
    var res: HttpResult = .{};
    defer alloc.free(res.body);
    var f = try io.concurrent(fetchTask, .{ io, url, dusty.Method.post, body, &res });
    const i = try r.ev.waitFor(.request, 0, 15000);
    const req = r.ev.list.items[i].handle;
    try engine.s3.putBody(r.store(), req, .of("posted.bin"), .{}, 22);
    const rep = try r.ev.result(22);
    try std.testing.expectEqual(abi.OK, rep.status);
    try std.testing.expectEqual(abi.S3_OP_PUT_BODY, rep.op);
    try std.testing.expectEqualSlices(u8, body, r.fake.getObject("b", "posted.bin").?);
    try engine.respond(r.e, req, 201, &.{}, "stored", false);
    try f.await(io);
    try std.testing.expectEqual(@as(u16, 201), res.status);
}

/// One request over h2c (a detached request in the engine), whose stream
/// the client resets once `go` is set.
const H2Reset = struct {
    port: u16,
    method: []const u8,
    path: []const u8,
    /// One more request header (a conditional one the serve reads).
    extra: ?anole.h2.Header = null,
    body: ?[]const u8 = null,
    go: std.atomic.Value(bool) = .init(false),

    fn run(g: *H2Reset, io: std.Io) anyerror!void {
        const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = g.port });
        defer conn.close();
        var headers: [5]anole.h2.Header = .{
            .{ .name = ":method", .value = g.method }, .{ .name = ":path", .value = g.path },
            .{ .name = ":scheme", .value = "http" },   .{ .name = ":authority", .value = "localhost" },
            undefined,
        };
        var n: usize = 4;
        if (g.extra) |x| {
            headers[4] = x;
            n = 5;
        }
        const s = try conn.request(headers[0..n], .{ .body_bytes = g.body, .timeout = .none });
        defer s.release();
        try wait.waitFlag(io, "the test lets the client reset its stream", &g.go);
        s.cancel();
    }
};

/// `engine.sseAccept` on a plain request, on a thread of its own: it claims
/// the request, then fails (`error.State`, not a subscription) and hands
/// the slot back to `out`.
const FailedAccept = struct {
    r: *Rig,
    req: u64,
    result: ?anyerror = null,

    fn run(fa: *FailedAccept) void {
        _ = engine.sseAccept(fa.r.e, fa.req, &.{}, &.{}, 0) catch |err| {
            fa.result = err;
        };
    }
};

test "capi s3: serve on a request reset while a failed answer call held it answers GONE and reads nothing of the request" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.start(true);
    defer r.deinit();
    try r.fake.putObject("b", "obj.bin", "served", "text/plain");
    const io = r.rt.io();
    const tio = engine.threadedIo();
    var g: H2Reset = .{ .port = r.e.port(0), .method = "GET", .path = "/f/obj", .extra = .{ .name = "if-none-match", .value = "\"an-etag\"" } };
    var f = try io.concurrent(H2Reset.run, .{ &g, io });
    defer f.cancel(io) catch {};
    const req = r.ev.list.items[try r.ev.waitFor(.request, 0, 15000)].handle;
    const aborted = r.e.aborted_count.load(.monotonic);

    // An answer call holds the request in `responding` while the client
    // resets the stream: the executor lets the request's memory go and
    // leaves the slot to that call, which fails and hands it back to `out`.
    var hold: engine.TestPin = .{};
    engine.test_answer_hold = &hold;
    var fa: FailedAccept = .{ .r = &r, .req = req };
    var t: ?std.Thread = try std.Thread.spawn(.{}, FailedAccept.run, .{&fa});
    defer if (t) |th| {
        hold.release.store(true, .release);
        th.join();
        engine.test_answer_hold = null;
    };
    try wait.waitFlag(tio, "the answer call holds the request", &hold.held);
    g.go.store(true, .release);
    try wait.waitAtLeast(tio, "the executor lets the reset request go", &r.e.aborted_count, aborted + 1);
    hold.release.store(true, .release);
    t.?.join();
    t = null;
    engine.test_answer_hold = null;
    try std.testing.expectEqual(@as(?anyerror, error.State), fa.result);

    // The serve finds no request to read or answer.
    try engine.s3.serve(r.store(), req, .of("obj.bin"), .{}, 30);
    const rep = try r.ev.result(30);
    try std.testing.expectEqual(abi.E_GONE, rep.status);
    // The consumer's answer ends the orphaned request (nobody hears it).
    try engine.respond(r.e, req, 200, &.{}, "", false);
}

test "capi s3: put_body stores the whole inline body when the client resets the stream during the upload" {
    if (comptime !features.s3 or !features.http2) return error.SkipZigTest;
    var r: Rig = undefined;
    // An inline body of two parts, uploaded one part at a time: the second
    // part is read from the body only after the first is stored.
    try r.startWith(true, .{ .inline_body_max = 6 * mib, .concurrency = 1 });
    defer r.deinit();
    const body = try alloc.alloc(u8, 5 * mib + 256 * 1024);
    defer alloc.free(body);
    pattern(body, 9);
    r.fake.hold_parts = true;
    const io = r.rt.io();
    const tio = engine.threadedIo();
    var g: H2Reset = .{ .port = r.e.port(0), .method = "POST", .path = "/f/up", .body = body };
    var f = try io.concurrent(H2Reset.run, .{ &g, io });
    defer f.cancel(io) catch {};
    const i = try r.ev.waitFor(.request, 0, 15000);
    const req = r.ev.list.items[i].handle;
    const rec: *const abi.RequestEvent = @ptrCast(@alignCast(r.ev.list.items[i].bytes.ptr));
    try std.testing.expect(rec.flags & abi.REQ_BODY_INLINE != 0);
    const aborted = r.e.aborted_count.load(.monotonic);
    try engine.s3.putBody(r.store(), req, .of("posted.bin"), .{}, 31);
    // The first part is at the storage; the request ends under the upload.
    try wait.waitAtLeast(tio, "the first part reaches the storage", &r.fake.held_parts, 1);
    g.go.store(true, .release);
    try wait.waitAtLeast(tio, "the executor lets the reset request go", &r.e.aborted_count, aborted + 1);
    r.fake.releaseParts();
    const rep = try r.ev.result(31);
    try std.testing.expectEqual(abi.OK, rep.status);
    try std.testing.expectEqualSlices(u8, body, r.fake.getObject("b", "posted.bin").?);
}

test "capi s3: config: storage parses, validates and maps every Options leaf" {
    if (comptime !features.s3) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const cfg = try config.parse(arena.allocator(),
        \\{"storage": [{"name": "files", "s3": {"endpoint": "http://127.0.0.1:9000", "bucket": "b", "provider": "minio"}}]}
    , &why);
    try std.testing.expectEqual(@as(usize, 1), cfg.storage.len);
    try std.testing.expectEqual(@as(u32, 30_000), cfg.storage[0].timeout_ms);
    try std.testing.expectEqual(@as(u8, 3), cfg.storage[0].retry.?.attempts);
    try std.testing.expectEqual(@as(u32, 100), cfg.storage[0].retry.?.base_ms);
    try std.testing.expect(cfg.storage[0].breaker != null);

    const bad = [_]struct { json: []const u8, msg: []const u8 }{
        .{ .json = "{\"storage\": [{\"name\": \"a\", \"s3\": {\"access_key_id\": \"k\"}}]}", .msg = "both or neither" },
        .{ .json = "{\"storage\": [{\"name\": \"a\", \"s3\": {\"part_size\": 1024}}]}", .msg = "part_size" },
        .{ .json = "{\"storage\": [{\"name\": \"a\", \"s3\": {}}, {\"name\": \"a\", \"s3\": {}}]}", .msg = "is taken" },
        .{ .json = "{\"storage\": [{\"name\": \"a\", \"s3\": {\"provider\": \"nope\"}}]}", .msg = "provider" },
    };
    for (bad) |b| {
        var w: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), b.json, &w));
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), b.msg) != null);
    }

    comptime parity.checkCoverage(anole.s3.Options, &parity.s3_options);
    const schema_text = @import("anole_capi_schema").text;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), schema_text, .{});
    try parity.checkSchemaAndDefaults(anole.s3.Options, config.Config, &parity.s3_options, root);
}

/// Whether a wait that began at `started` has passed `ms`, or the wait
/// helper's deadline (10 s times ANOLE_TEST_TIMEOUT_FACTOR) if that is later:
/// a hang guard counted on the clock, not in polls.
fn pastDeadline(started: std.Io.Timestamp, ms: u32) bool {
    const limit: i64 = @max(ms, wait.deadlineMs());
    return started.untilNow(engine.threadedIo(), .awake).toMilliseconds() >= limit;
}
