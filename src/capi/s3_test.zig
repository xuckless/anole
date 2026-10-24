//! C ABI tests for p3/s3: the engine's S3 calls against `anole.s3.testing.FakeServer`,
//! driven through the engine's Zig entry points as in nats_test.zig. Waits poll
//! the consumer with generous bounds; no assertion is about time.
const std = @import("std");
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
        var buf: [256 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        const n = try engine.pollWait(ev.c, &buf, ms, &need);
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
        var waited: u32 = 0;
        while (true) {
            for (ev.list.items[from..], from..) |r, i| if (r.typ == @backingInt(typ)) return i;
            if (waited >= ms) return error.TimedOut;
            try ev.pump(50);
            waited += 50;
        }
    }

    /// The S3 result with `user_data`.
    fn result(ev: *Events, user_data: u64) !*const abi.S3ResultEvent {
        var waited: u32 = 0;
        while (true) {
            for (ev.list.items) |r| if (r.typ == @backingInt(abi.EventType.s3_result)) {
                const rec: *const abi.S3ResultEvent = @ptrCast(@alignCast(r.bytes.ptr));
                if (rec.user_data == user_data) return rec;
            };
            if (waited >= 15000) {
                for (ev.list.items) |r| if (r.typ == @backingInt(abi.EventType.s3_result)) {
                    const rec: *const abi.S3ResultEvent = @ptrCast(@alignCast(r.bytes.ptr));
                    std.debug.print("result user_data {d} op {d} status {d} class {d}: {s} ({s})\n", .{ rec.user_data, rec.op, rec.status, rec.error_class, text(rec, rec.@"error"), text(rec, rec.error_code) });
                };
                return error.TimedOut;
            }
            try ev.pump(50);
            waited += 50;
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

    fn start(r: *Rig, route: bool) !void {
        // Workers only: the test thread polls the consumer and must not be an executor the fake needs.
        r.rt = try zio.Runtime.init(alloc, .{ .executors = .exact(2), .enable_main_executor = false });
        errdefer r.rt.deinit();
        r.fake = try anole.s3.testing.FakeServer.start(alloc, r.rt.io());
        errdefer r.fake.stop();
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 2, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "limits": {{"body_max": 33554432}},
            \\ "routes": [{s}],
            \\ "storage": [{{"name": "files", "s3": {{"endpoint": "{s}", "bucket": "b",
            \\   "access_key_id": "{s}", "secret_access_key": "{s}", "part_size": 5242880}},
            \\   "retry": {{"attempts": 1}}}}]}}
        , .{
            if (route) "{\"path\": \"/f/obj\", \"handler\": 1, \"timeout_ms\": 20000}, {\"path\": \"/f/up\", \"method\": \"POST\", \"handler\": 1, \"timeout_ms\": 20000}" else "",
            r.fake.url(),
            anole.s3.testing.access_key_id,
            anole.s3.testing.secret_access_key,
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
    // The handle is over.
    sleepMs(50);
    try std.testing.expectError(error.Gone, engine.s3.readMore(r.e, handle, 1));
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
    var waited: u32 = 0;
    while (r.fake.count("PUT", "partNumber=") == 0 and waited < 15000) : (waited += 20) sleepMs(20);
    try std.testing.expect(r.fake.count("PUT", "partNumber=") >= 1);
    try engine.s3.release(r.e, t);
    waited = 0;
    while (r.fake.openUploads() != 0 and waited < 15000) : (waited += 20) sleepMs(20);
    try std.testing.expectEqual(@as(usize, 0), r.fake.openUploads());
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
    out.status = @intCast(@intFromEnum(resp.status()));
    if (method != .head) out.body = try alloc.dupe(u8, (try resp.body()) orelse "");
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
