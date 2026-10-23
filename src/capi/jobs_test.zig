//! C ABI tests for p3/jobs, imported from engine_test.zig: the configuration
//! and its parity with `anole.jobs`, enqueueing, workers and their jobs,
//! cancels, the admin operations. The engine is driven through its Zig entry
//! points on the memory store. Waits poll the consumer with generous bounds;
//! no assertion is about time.
const std = @import("std");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const parity = @import("parity.zig");
const config = @import("config.zig");
const abi = engine.abi;
const features = anole.features;

const alloc = std.testing.allocator;
const Io = std.Io;

comptime {
    if (features.jobs) {
        parity.checkCoverage(anole.jobs.Options, &parity.jobs_options);
        parity.checkCoverage(anole.jobs.Kind, &parity.jobs_kind);
        parity.checkCoverage(anole.jobs.CronOptions, &parity.jobs_cron);
    }
}

test "capi jobs: the schema has every key, and the defaults agree with Zig's" {
    if (comptime !features.jobs) return error.SkipZigTest;
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try parity.checkSchemaAndDefaults(anole.jobs.Options, config.Config, &parity.jobs_options, root);
    try parity.checkSchemaAndDefaults(anole.jobs.Kind, config.Config, &parity.jobs_kind, root);
    try parity.checkSchemaAndDefaults(anole.jobs.CronOptions, config.Config, &parity.jobs_cron, root);
}

test "capi jobs: the configuration parses with its defaults" {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var why: Io.Writer = .fixed(&buf);
    const cfg = try config.parse(arena.allocator(),
        \\{"jobs":{"queues":[{"name":"mail","concurrency":4}],"kinds":[{"name":"email.welcome","queue":"mail","attempts":8}],
        \\ "cron":[{"name":"nightly","schedule":"0 3 * * *","kind":"report.nightly","args":{"full":true}}]}}
    , &why);
    const j = cfg.jobs.?;
    try std.testing.expectEqualStrings("memory", j.store);
    try std.testing.expectEqual(@as(u32, 30_000), j.lease_ms);
    try std.testing.expectEqual(@as(u16, 8), j.kinds[0].attempts);
    try std.testing.expectEqual(@as(u32, 4), j.queues[0].concurrency);
    try std.testing.expectEqualStrings("once", j.cron[0].missed);
    var w: Io.Writer = .fixed(&buf);
    try std.testing.expectError(error.Config, config.parse(arena.allocator(), "{\"jobs\":{\"leasee_ms\":1}}", &w));
}

/// The consumer's records, kept as they are polled.
const Events = struct {
    c: *engine.Consumer,
    list: std.ArrayList(struct { typ: u32, handle: u64, bytes: []align(8) u8 }) = .empty,

    fn pump(ev: *Events, ms: i32) !void {
        var buf: [64 * 1024]u8 align(8) = undefined;
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

    /// The index of the `nth` (0-based) record of `typ`, polling for up to `ms`.
    fn waitFor(ev: *Events, typ: abi.EventType, nth: usize, ms: u32) !usize {
        var waited: u32 = 0;
        while (true) {
            var seen: usize = 0;
            for (ev.list.items, 0..) |r, i| if (r.typ == @backingInt(typ)) {
                if (seen == nth) return i;
                seen += 1;
            };
            if (waited >= ms) return error.TimedOut;
            try ev.pump(50);
            waited += 50;
        }
    }

    fn count(ev: *const Events, typ: abi.EventType) usize {
        var n: usize = 0;
        for (ev.list.items) |r| if (r.typ == @backingInt(typ)) {
            n += 1;
        };
        return n;
    }

    fn as(ev: *const Events, comptime T: type, i: usize) *const T {
        return @ptrCast(@alignCast(ev.list.items[i].bytes.ptr));
    }

    fn span(ev: *const Events, i: usize, s: abi.Span) []const u8 {
        return ev.list.items[i].bytes[s.off..][0..s.len];
    }

    fn deinit(ev: *Events) void {
        for (ev.list.items) |r| alloc.free(r.bytes);
        ev.list.deinit(alloc);
    }
};

const Rig = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    ev: Events,
    json: []u8,

    /// `jobs_extra` is spliced into the "jobs" object after the store.
    fn create(r: *Rig, jobs_extra: []const u8) !void {
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 1, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "jobs": {{"store": "memory", "poll_ms": 100{s}}}}}
        , .{jobs_extra});
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        r.ev = .{ .c = r.c };
    }

    fn start(r: *Rig) !void {
        try r.e.start();
    }

    fn deinit(r: *Rig) void {
        r.ev.deinit();
        r.e.drain() catch {};
        _ = r.e.wait(5000);
        r.e.destroy();
        alloc.free(r.json);
    }
};

fn jobOut(kind: []const u8, args: []const u8) abi.JobOut {
    return .{ .size = @sizeOf(abi.JobOut), .kind = .of(kind), .args_json = .of(args) };
}

fn enq(r: *Rig, outs: []const abi.JobOut) !void {
    try engine.jobs.enqueue(r.e, r.c, outs, .{ .size = @sizeOf(abi.JobsEnqueueOptions) }, 11);
}

test "capi jobs: enqueue answers one JOB_ENQUEUED with an entry per job, in order" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create("");
    defer r.deinit();
    try r.start();
    try enq(&r, &.{ jobOut("a", "{}"), jobOut("b", "{\"x\":1}"), jobOut("c", "{}") });
    const i = try r.ev.waitFor(.job_enqueued, 0, 5000);
    const rec = r.ev.as(abi.JobEnqueuedEvent, i);
    try std.testing.expectEqual(abi.OK, rec.status);
    try std.testing.expectEqual(@as(u64, 11), rec.user_data);
    try std.testing.expectEqual(@as(u32, 3), rec.nentries);
    const entries: [*]const abi.JobEnqueuedEntry = @ptrCast(@alignCast(r.ev.list.items[i].bytes.ptr + rec.entries_off));
    try std.testing.expect(entries[0].id < entries[1].id and entries[1].id < entries[2].id);
    try std.testing.expectEqual(@as(u32, 1), entries[0].inserted);
}

test "capi jobs: a bad job is refused before anything is queued" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create("");
    defer r.deinit();
    try r.start();
    var bad = jobOut("", "{}");
    try std.testing.expectError(error.Invalid, enq(&r, &.{bad}));
    bad = jobOut("k", "{}");
    bad.delay_ms = 5;
    bad.run_at_ms = 5;
    try std.testing.expectError(error.Invalid, enq(&r, &.{bad}));
    bad = jobOut("k", "{}");
    bad.flags = 1;
    try std.testing.expectError(error.Invalid, enq(&r, &.{bad}));
}

test "capi jobs: a worker gets JOB events up to its concurrency, finishes free its credit" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create(", \"kinds\": [{\"name\": \"t.work\"}]");
    defer r.deinit();
    const kinds = [_]abi.Str{.of("t.work")};
    const wh = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions), .kinds = &kinds, .nkinds = 1, .concurrency = 2 }, 5);
    try r.start();
    try enq(&r, &.{ jobOut("t.work", "{\"n\":1}"), jobOut("t.work", "{\"n\":2}"), jobOut("t.work", "{\"n\":3}") });
    const a = try r.ev.waitFor(.job, 0, 5000);
    const b = try r.ev.waitFor(.job, 1, 5000);
    const ja = r.ev.as(abi.JobEvent, a);
    try std.testing.expectEqual(wh, ja.worker);
    try std.testing.expectEqual(@as(u64, 5), ja.user_data);
    try std.testing.expectEqual(@as(u16, 1), ja.attempt);
    try std.testing.expectEqualStrings("t.work", r.ev.span(a, ja.kind));
    // Two are out; the third waits for a finish.
    try r.ev.pump(100);
    try std.testing.expectEqual(@as(usize, 2), r.ev.count(.job));
    try engine.jobs.finish(r.e, r.ev.list.items[a].handle, abi.JOB_DONE, 0, "");
    const c3 = try r.ev.waitFor(.job, 2, 5000);
    // Finishing twice is GONE.
    try std.testing.expectError(error.Gone, engine.jobs.finish(r.e, r.ev.list.items[a].handle, abi.JOB_DONE, 0, ""));
    try engine.jobs.finish(r.e, r.ev.list.items[b].handle, abi.JOB_DISCARD, 0, "nope");
    try engine.jobs.finish(r.e, r.ev.list.items[c3].handle, abi.JOB_RETRY, 0, "later");
}

test "capi jobs: admin answers JSON, and a discarded job is dead with the reason" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create(", \"kinds\": [{\"name\": \"t.work\", \"attempts\": 1}]");
    defer r.deinit();
    _ = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 5);
    try r.start();
    try enq(&r, &.{jobOut("t.work", "{}")});
    const a = try r.ev.waitFor(.job, 0, 5000);
    try engine.jobs.finish(r.e, r.ev.list.items[a].handle, abi.JOB_DISCARD, 0, "not today");
    var user: u64 = 100;
    // Poll until the store write lands: the job turns dead.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        user += 1;
        try engine.jobs.admin(r.e, r.c, "{\"op\":\"jobs.list\",\"state\":\"dead\"}", user);
        const i = try r.ev.waitFor(.jobs_result, tries, 5000);
        const rec = r.ev.as(abi.JobsResultEvent, i);
        try std.testing.expectEqual(abi.OK, rec.status);
        const json = r.ev.span(i, rec.json);
        if (std.mem.indexOf(u8, json, "not today") != null) break;
        if (tries > 50) return error.TimedOut;
    }
    try engine.jobs.admin(r.e, r.c, "{\"op\":\"jobs.nope\"}", 1);
    const bad = try r.ev.waitFor(.jobs_result, tries + 1, 5000);
    try std.testing.expectEqual(abi.E_INVALID, r.ev.as(abi.JobsResultEvent, bad).status);
}

test "capi jobs: a run past its timeout ends with JOB_CANCEL TIMEOUT, and finish is GONE" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create(", \"kinds\": [{\"name\": \"t.slow\", \"timeout_ms\": 1, \"attempts\": 1}]");
    defer r.deinit();
    _ = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 5);
    try r.start();
    try enq(&r, &.{jobOut("t.slow", "{}")});
    const a = try r.ev.waitFor(.job, 0, 5000);
    const ci = try r.ev.waitFor(.job_cancel, 0, 5000);
    try std.testing.expectEqual(abi.JOB_CANCEL_TIMEOUT, r.ev.as(abi.JobCancelEvent, ci).reason);
    try std.testing.expectEqual(r.ev.list.items[a].handle, r.ev.list.items[ci].handle);
    try std.testing.expectError(error.Gone, engine.jobs.finish(r.e, r.ev.list.items[a].handle, abi.JOB_DONE, 0, ""));
}

test "capi jobs: stopping a worker with nothing out ends it" {
    if (comptime !features.jobs) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.create("");
    defer r.deinit();
    const wh = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 9);
    try r.start();
    engine.jobs.stop(r.e, wh);
    const i = try r.ev.waitFor(.job_worker_end, 0, 5000);
    try std.testing.expectEqual(abi.JOB_WORKER_STOPPED, r.ev.as(abi.JobWorkerEndEvent, i).reason);
    try std.testing.expectEqual(wh, r.ev.list.items[i].handle);
    // Over: a second stop is quiet.
    engine.jobs.stop(r.e, wh);
}
