//! C ABI tests for p3/jobs, imported from engine_test.zig: the configuration
//! and its parity with `anole.jobs`, enqueueing, workers and their jobs,
//! cancels, the admin operations. The engine is driven through its Zig entry
//! points on the memory store. Waits poll the consumer with generous bounds;
//! no assertion is about time.
const std = @import("std");
const dusty = @import("dusty");
const wait = @import("anole_test_wait");
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
        const started = std.Io.Clock.awake.now(engine.threadedIo());
        while (true) {
            var seen: usize = 0;
            for (ev.list.items, 0..) |r, i| if (r.typ == @backingInt(typ)) {
                if (seen == nth) return i;
                seen += 1;
            };
            if (pastDeadline(started, ms)) return error.TimedOut;
            try ev.pump(50);
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
        return r.createRouted(jobs_extra, "");
    }

    /// `create` with `routes` (the "routes" array's items).
    fn createRouted(r: *Rig, jobs_extra: []const u8, routes: []const u8) !void {
        return r.createWith(jobs_extra, routes, "");
    }

    /// `createRouted` with `top` spliced into the top-level object (after
    /// the jobs: `, "databases": [...]`).
    fn createWith(r: *Rig, jobs_extra: []const u8, routes: []const u8, top: []const u8) !void {
        r.json = try std.fmt.allocPrint(alloc,
            \\{{"executors": 1, "timeouts": {{"shutdown_ms": 200}},
            \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
            \\ "routes": [{s}],
            \\ "jobs": {{"store": "memory", "poll_ms": 100{s}}}{s}}}
        , .{ routes, jobs_extra, top });
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        // anole_server_open: the queue exists, workers may register.
        try r.e.open();
        r.ev = .{ .c = r.c };
    }

    fn start(r: *Rig) !void {
        try r.e.start();
    }

    fn deinit(r: *Rig) void {
        r.ev.deinit();
        r.e.drain() catch {};
        _ = r.e.wait(@intCast(wait.deadlineMs()));
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
    const started = std.Io.Clock.awake.now(engine.threadedIo());
    while (true) : (tries += 1) {
        user += 1;
        try engine.jobs.admin(r.e, r.c, "{\"op\":\"jobs.list\",\"state\":\"dead\"}", user);
        const i = try r.ev.waitFor(.jobs_result, tries, 5000);
        const rec = r.ev.as(abi.JobsResultEvent, i);
        try std.testing.expectEqual(abi.OK, rec.status);
        const json = r.ev.span(i, rec.json);
        if (std.mem.indexOf(u8, json, "not today") != null) break;
        if (pastDeadline(started, 0)) return error.TimedOut;
        try Io.sleep(engine.threadedIo(), .fromMilliseconds(20), .awake);
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

const HttpResult = struct { status: u16 = 0 };

/// A GET carrying a trace context the server does not record (no tracing
/// in the engine): `traceparent` unsampled, and a `tracestate`.
fn fetchTraced(io: std.Io, url: []const u8, out: *HttpResult) anyerror!void {
    var http = dusty.Client.init(alloc, io, .{});
    defer http.deinit();
    var keys: [2][]const u8 = undefined;
    var values: [2][]const u8 = undefined;
    var hashes: [2]u8 = undefined;
    var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    try h.add("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00");
    try h.add("tracestate", "congo=t61rcWkgMzE");
    var resp = try http.fetch(url, .{ .headers = &h });
    defer resp.deinit();
    out.status = @intCast(@backingInt(resp.status()));
}

test "capi jobs: enqueue with opts.req carries the request's traceparent, flags kept, and its tracestate" {
    if (comptime !features.jobs) return error.SkipZigTest;
    // Workers only: the test thread polls the consumer.
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(1), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    try r.createRouted(", \"kinds\": [{\"name\": \"t.work\"}]", "{\"path\": \"/x\", \"handler\": 1, \"timeout_ms\": 20000}");
    defer r.deinit();
    _ = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 5);
    try r.start();
    const io = rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{r.e.port(0)});
    var res: HttpResult = .{};
    var f = try io.concurrent(fetchTraced, .{ io, url, &res });
    // A failure below must not leave the fetch running against this frame
    // after the engine is gone; after the await this does nothing.
    defer f.cancel(io) catch {};
    const ri = try r.ev.waitFor(.request, 0, 10000);
    const req = r.ev.list.items[ri].handle;
    try engine.jobs.enqueue(r.e, r.c, &.{jobOut("t.work", "{}")}, .{ .size = @sizeOf(abi.JobsEnqueueOptions), .req = req }, 11);
    const ji = try r.ev.waitFor(.job, 0, 10000);
    const job = r.ev.as(abi.JobEvent, ji);
    // Both answered before anything is checked, so a failure ends cleanly.
    try engine.jobs.finish(r.e, r.ev.list.items[ji].handle, abi.JOB_DONE, 0, "");
    try engine.respond(r.e, req, 200, &.{}, "ok", false);
    try f.await(io);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00", r.ev.span(ji, job.traceparent));
    try std.testing.expect(std.mem.indexOf(u8, r.ev.span(ji, job.meta), "\"tracestate\":\"congo=t61rcWkgMzE\"") != null);
}

/// Holds executor 0 (its capi task, so every task on it) until `end`:
/// what the consumer does meanwhile has all landed when it runs again,
/// as when a consumer enqueues and answers back to back before the
/// executor wakes.
const Hold = struct {
    cmd: engine.Command = .{ .run = run },
    started: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn run(cmd: *engine.Command, _: *engine.Exec) void {
        const h: *Hold = @fieldParentPtr("cmd", cmd);
        h.started.store(true, .release);
        while (!h.released.load(.acquire)) std.Thread.yield() catch {};
    }

    fn begin(h: *Hold, e: *engine.Engine) !void {
        e.execs[0].post(&h.cmd);
        errdefer h.end();
        try wait.waitFlag(engine.threadedIo(), "executor 0 runs the hold", &h.started);
    }

    fn end(h: *Hold) void {
        h.released.store(true, .release);
    }
};

const tp_unsampled = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00";

/// An HTTP/2 (h2c) GET of /x carrying a trace context the server does not
/// record; with `reset`, the stream is reset once `answered` is set (the
/// consumer has answered), and `reset_sent` says it went out.
const H2Get = struct {
    port: u16,
    reset: bool = false,
    answered: std.atomic.Value(bool) = .init(false),
    reset_sent: std.atomic.Value(bool) = .init(false),
    status: u16 = 0,

    fn run(g: *H2Get, io: std.Io) anyerror!void {
        const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = g.port });
        defer conn.close();
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "GET" },            .{ .name = ":path", .value = "/x" },
            .{ .name = ":scheme", .value = "http" },           .{ .name = ":authority", .value = "localhost" },
            .{ .name = "traceparent", .value = tp_unsampled }, .{ .name = "tracestate", .value = "congo=t61rcWkgMzE" },
        }, .{});
        defer s.release();
        if (g.reset) {
            try wait.waitFlag(io, "the consumer answered", &g.answered);
            s.cancel();
            g.reset_sent.store(true, .release);
            return;
        }
        try s.waitHead();
        g.status = s.status;
    }
};

/// Enqueue with `opts.req`, then answer the request at once, both landing
/// before the request's executor runs again; with `reset`, the client
/// resets the HTTP/2 stream after the answer, also before then.
fn enqueueThenRespond(comptime proto: enum { h1, h2 }, reset: bool) !void {
    if (comptime !features.jobs) return error.SkipZigTest;
    if (comptime proto == .h2 and !features.http2) return error.SkipZigTest;
    // Workers only: the test thread polls the consumer.
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(1), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    try r.createRouted(", \"kinds\": [{\"name\": \"t.work\"}]", "{\"path\": \"/x\", \"handler\": 1, \"timeout_ms\": 20000}");
    defer r.deinit();
    _ = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 5);
    try r.start();
    const io = rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{r.e.port(0)});
    var res: HttpResult = .{};
    var g: H2Get = .{ .port = r.e.port(0), .reset = reset };
    var f1: ?std.Io.Future(anyerror!void) = null;
    var f2: ?std.Io.Future(anyerror!void) = null;
    if (proto == .h1) f1 = try io.concurrent(fetchTraced, .{ io, url, &res }) else f2 = try io.concurrent(H2Get.run, .{ &g, io });
    // A failure below must not leave the client running against this
    // frame after the engine is gone; after the awaits these do nothing.
    defer if (f1) |*f| f.cancel(io) catch {};
    defer if (f2) |*f| f.cancel(io) catch {};
    const ri = try r.ev.waitFor(.request, 0, 10000);
    const req = r.ev.list.items[ri].handle;

    var hold: Hold = .{};
    try hold.begin(r.e);
    {
        errdefer hold.end();
        try engine.jobs.enqueue(r.e, r.c, &.{jobOut("t.work", "{}")}, .{ .size = @sizeOf(abi.JobsEnqueueOptions), .req = req }, 11);
        try engine.respond(r.e, req, 200, &.{}, "ok", false);
        if (reset) {
            g.answered.store(true, .release);
            try wait.waitFlag(engine.threadedIo(), "the client reset the stream", &g.reset_sent);
        }
    }
    hold.end();

    const ji = try r.ev.waitFor(.job, 0, 10000);
    const job = r.ev.as(abi.JobEvent, ji);
    // Answered before anything is checked, so a failure ends cleanly.
    try engine.jobs.finish(r.e, r.ev.list.items[ji].handle, abi.JOB_DONE, 0, "");
    if (f1) |*f| try f.await(io);
    if (f2) |*f| try f.await(io);
    if (!reset) try std.testing.expectEqual(@as(u16, 200), if (proto == .h1) res.status else g.status);
    try std.testing.expectEqualStrings(tp_unsampled, r.ev.span(ji, job.traceparent));
    try std.testing.expect(std.mem.indexOf(u8, r.ev.span(ji, job.meta), "\"tracestate\":\"congo=t61rcWkgMzE\"") != null);
}

test "capi jobs: enqueue with opts.req, then the answer at once: the job carries the context (HTTP/1.1)" {
    try enqueueThenRespond(.h1, false);
}

test "capi jobs: enqueue with opts.req, then the answer at once: the job carries the context (HTTP/2)" {
    try enqueueThenRespond(.h2, false);
}

test "capi jobs: enqueue with opts.req, the answer, then the client resets the HTTP/2 stream: nothing reads the request after" {
    try enqueueThenRespond(.h2, true);
}

/// Whether a wait that began at `started` has passed `ms`, or the wait
/// helper's deadline (10 s times ANOLE_TEST_TIMEOUT_FACTOR) if that is later:
/// a hang guard counted on the clock, not in polls.
fn pastDeadline(started: std.Io.Timestamp, ms: u32) bool {
    const limit: i64 = @max(ms, wait.deadlineMs());
    return started.untilNow(engine.threadedIo(), .awake).toMilliseconds() >= limit;
}

// ---------------------------------------------------------------------------
// enqueue(opts.req) pins the request while it copies its trace context:
// calls on the handle from other threads wait the pin out, never GONE.

/// `engine.jobs.enqueue` with `opts.req = req`, on a thread of its own,
/// its pin on the request held open by `engine.test_pin` until a call that
/// meets the pin (or `end`) lets it go.
const PinnedEnqueue = struct {
    r: *Rig,
    req: u64,
    pin: engine.TestPin = .{},
    done: std.atomic.Value(bool) = .init(false),
    result: ?anyerror = null,
    thread: ?std.Thread = null,

    fn run(p: *PinnedEnqueue) void {
        engine.jobs.enqueue(p.r.e, p.r.c, &.{jobOut("t.work", "{}")}, .{ .size = @sizeOf(abi.JobsEnqueueOptions), .req = p.req }, 12) catch |err| {
            p.result = err;
        };
        p.done.store(true, .release);
    }

    fn pinnedOrDone(p: *const PinnedEnqueue) bool {
        return p.pin.held.load(.acquire) or p.done.load(.acquire);
    }

    /// Starts the enqueue; returns once it holds the pin.
    fn begin(p: *PinnedEnqueue) !void {
        engine.test_pin = &p.pin;
        p.thread = try std.Thread.spawn(.{}, run, .{p});
        errdefer p.end();
        try wait.waitUntil(engine.threadedIo(), "the enqueue pins the request", p, pinnedOrDone);
        if (!p.pin.held.load(.acquire)) return p.result orelse error.NeverPinned;
    }

    /// Lets the pin go (when nothing met it) and joins the enqueue.
    fn end(p: *PinnedEnqueue) void {
        p.pin.release.store(true, .release);
        if (p.thread) |t| t.join();
        p.thread = null;
        engine.test_pin = null;
    }
};

test "capi jobs: while enqueue(opts.req) on another thread reads the request, a tied query and the answer are taken, not GONE" {
    if (comptime !features.jobs) return error.SkipZigTest;
    // Workers only: the test thread polls the consumer.
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(1), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    const dbs = if (features.sqlite) ", \"databases\": [{\"name\": \"main\", \"sqlite\": {\"path\": \":memory:\"}}]" else "";
    try r.createWith(", \"kinds\": [{\"name\": \"t.work\"}]", "{\"path\": \"/x\", \"handler\": 1, \"timeout_ms\": 20000}", dbs);
    defer r.deinit();
    try r.start();
    const io = rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{r.e.port(0)});
    var res: HttpResult = .{};
    var f = try io.concurrent(fetchTraced, .{ io, url, &res });
    defer f.cancel(io) catch {};
    const req = r.ev.list.items[try r.ev.waitFor(.request, 0, 10000)].handle;

    var pe: PinnedEnqueue = .{ .r = &r, .req = req };
    try pe.begin();
    defer pe.end();
    // A call tied to the request (anole_db_query with opts.req): the
    // request is still owed its answer.
    if (comptime features.sqlite) {
        try engine.db.submit(engine.db.find(r.e, "main").?, r.c, .query, "SELECT 1", &.{}, .{ .size = @sizeOf(abi.DbOptions), .req = req }, 21);
    }
    // The answer meets the pin, and waits it out.
    try engine.respond(r.e, req, 200, &.{}, "ok", false);
    pe.end();
    try std.testing.expectEqual(@as(?anyerror, null), pe.result);
    try f.await(io);
    try std.testing.expectEqual(@as(u16, 200), res.status);
    // The job still carries the request's context.
    const ei = try r.ev.waitFor(.job_enqueued, 0, 10000);
    try std.testing.expectEqual(abi.OK, r.ev.as(abi.JobEnqueuedEvent, ei).status);
}

const pb = if (features.grpc) @import("anole_test_pb") else struct {};

/// One unary anole.test.Echo/Unary call over h2c; its status in `code`.
fn grpcUnary(io: std.Io, port: u16, code: *std.atomic.Value(u32)) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = port });
    defer conn.close();
    var channel: anole.grpc.Channel = .{ .conn = conn, .authority = "localhost" };
    const client: anole.grpc.Client(pb.Echo(anole.grpc.Call, anyerror)) = .{ .channel = &channel };
    const reply = try client.unary("Unary", arena_state.allocator(), .{ .message = "hi" }, .{ .metadata = &.{
        .{ .name = "traceparent", .value = tp_unsampled },
    } });
    code.store(@backingInt(reply.status.code), .release);
}

test "capi jobs: while enqueue(opts.req) on another thread reads a gRPC call, its answer is taken, not GONE" {
    if (comptime !features.jobs or !features.grpc or !features.http2) return error.SkipZigTest;
    const set = @import("anole_test_descriptors").set;
    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(set.len));
    defer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, set);
    const top = try std.fmt.allocPrint(alloc, ", \"grpc\": {{\"descriptor_set\": \"{s}\", \"services\": [{{\"name\": \"anole.test.Echo\", \"handler\": 10}}]}}", .{b64});
    defer alloc.free(top);
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(1), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    try r.createWith(", \"kinds\": [{\"name\": \"t.work\"}]", "", top);
    defer r.deinit();
    try r.start();
    const io = rt.io();
    var code: std.atomic.Value(u32) = .init(std.math.maxInt(u32));
    var f = try io.concurrent(grpcUnary, .{ io, r.e.port(0), &code });
    defer f.cancel(io) catch {};
    const call = r.ev.list.items[try r.ev.waitFor(.grpc_call, 0, 10000)].handle;

    var pe: PinnedEnqueue = .{ .r = &r, .req = call };
    try pe.begin();
    defer pe.end();
    // The answer (an empty EchoResponse, then OK) meets the pin, and
    // waits it out.
    _ = try engine.grpc.send(r.e, call, "", false, true);
    pe.end();
    try std.testing.expectEqual(@as(?anyerror, null), pe.result);
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), code.load(.acquire));
}

/// A unary anole.test.Echo/Unary call over h2c carrying a traceparent,
/// whose stream the client resets once `go` is set.
const GrpcReset = struct {
    port: u16,
    go: std.atomic.Value(bool) = .init(false),

    fn run(g: *GrpcReset, io: std.Io) anyerror!void {
        const conn = try anole.h2.ClientConnection.connect(alloc, io, .{ .host = "127.0.0.1", .port = g.port });
        defer conn.close();
        // An empty EchoRequest in one gRPC frame.
        const s = try conn.request(&.{
            .{ .name = ":method", .value = "POST" },                  .{ .name = ":path", .value = "/anole.test.Echo/Unary" },
            .{ .name = ":scheme", .value = "http" },                  .{ .name = ":authority", .value = "localhost" },
            .{ .name = "content-type", .value = "application/grpc" }, .{ .name = "te", .value = "trailers" },
            .{ .name = "traceparent", .value = tp_unsampled },
        }, .{ .body_bytes = &.{ 0, 0, 0, 0, 0 } });
        defer s.release();
        try wait.waitFlag(io, "the answer call holds the call", &g.go);
        s.cancel();
    }
};

/// `engine.grpc.sendHeaders` on a thread of its own.
const SendHeaders = struct {
    r: *Rig,
    call: u64,
    result: ?anyerror = null,

    fn run(sh: *SendHeaders) void {
        engine.grpc.sendHeaders(sh.r.e, sh.call, &.{}) catch |err| {
            sh.result = err;
        };
    }
};

test "capi jobs: enqueue(opts.req) on a gRPC call reset while send_headers held it: the job has no context, the freed call is not read" {
    if (comptime !features.jobs or !features.grpc or !features.http2) return error.SkipZigTest;
    const set = @import("anole_test_descriptors").set;
    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(set.len));
    defer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, set);
    const top = try std.fmt.allocPrint(alloc, ", \"grpc\": {{\"descriptor_set\": \"{s}\", \"services\": [{{\"name\": \"anole.test.Echo\", \"handler\": 10}}]}}", .{b64});
    defer alloc.free(top);
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(1), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    try r.createWith(", \"kinds\": [{\"name\": \"t.work\"}]", "", top);
    defer r.deinit();
    _ = try engine.jobs.work(r.e, r.c, .{ .size = @sizeOf(abi.JobsWorkOptions) }, 5);
    try r.start();
    const io = rt.io();
    const tio = engine.threadedIo();
    var g: GrpcReset = .{ .port = r.e.port(0) };
    var f = try io.concurrent(GrpcReset.run, .{ &g, io });
    defer f.cancel(io) catch {};
    const call = r.ev.list.items[try r.ev.waitFor(.grpc_call, 0, 10000)].handle;
    const aborted = r.e.aborted_count.load(.monotonic);

    // Another thread's send_headers holds the call in `responding` while
    // the client resets the stream: the executor lets the call's memory
    // go and leaves the slot to that call, which then hands it back to
    // `out`.
    var hold: engine.TestPin = .{};
    engine.test_answer_hold = &hold;
    var sh: SendHeaders = .{ .r = &r, .call = call };
    var t: ?std.Thread = try std.Thread.spawn(.{}, SendHeaders.run, .{&sh});
    defer if (t) |th| {
        hold.release.store(true, .release);
        th.join();
        engine.test_answer_hold = null;
    };
    try wait.waitFlag(tio, "send_headers holds the call", &hold.held);
    g.go.store(true, .release);
    try wait.waitAtLeast(tio, "the executor lets the reset call go", &r.e.aborted_count, aborted + 1);
    hold.release.store(true, .release);
    t.?.join();
    t = null;
    engine.test_answer_hold = null;
    try std.testing.expectEqual(@as(?anyerror, null), sh.result);

    // The call is still owed its answer, but its memory is gone: the job
    // is enqueued without the call's context.
    try engine.jobs.enqueue(r.e, r.c, &.{jobOut("t.work", "{}")}, .{ .size = @sizeOf(abi.JobsEnqueueOptions), .req = call }, 14);
    const ji = try r.ev.waitFor(.job, 0, 10000);
    const job = r.ev.as(abi.JobEvent, ji);
    try engine.jobs.finish(r.e, r.ev.list.items[ji].handle, abi.JOB_DONE, 0, "");
    // The consumer's answer ends the orphaned call (nobody hears it).
    _ = try engine.grpc.send(r.e, call, "", false, true);
    try std.testing.expectEqualStrings("", r.ev.span(ji, job.traceparent));
}

/// Handles handed by the polling thread, in order, to the two racing
/// threads.
const Handed = struct {
    handles: []u64,
    published: std.atomic.Value(usize) = .init(0),
    /// No more handles come.
    stopped: std.atomic.Value(bool) = .init(false),

    /// Handle `i`, once published; null once stopped short of it, or
    /// past the wait helper's deadline.
    fn get(hd: *Handed, i: usize) ?u64 {
        const started = std.Io.Clock.awake.now(engine.threadedIo());
        var spins: usize = 0;
        while (hd.published.load(.acquire) <= i) : (spins += 1) {
            if (hd.stopped.load(.acquire) and hd.published.load(.acquire) <= i) return null;
            if (spins % 1024 == 1023 and pastDeadline(started, 0)) return null;
            std.Thread.yield() catch {};
        }
        return hd.handles[i];
    }

    fn stop(hd: *Handed) void {
        hd.stopped.store(true, .release);
    }
};

const Racer = struct {
    r: *Rig,
    hd: *Handed,
    enqueuer: bool,
    gone: u32 = 0,
    failed: ?anyerror = null,

    fn run(rc: *Racer) void {
        for (0..rc.hd.handles.len) |i| {
            const h = rc.hd.get(i) orelse {
                rc.failed = error.NeverPublished;
                return;
            };
            if (rc.enqueuer) {
                engine.jobs.enqueue(rc.r.e, rc.r.c, &.{jobOut("t.work", "{}")}, .{ .size = @sizeOf(abi.JobsEnqueueOptions), .req = h }, 13) catch |err| switch (err) {
                    // The answer came first: the request is over.
                    error.Gone => rc.gone += 1,
                    else => if (rc.failed == null) {
                        rc.failed = err;
                    },
                };
                continue;
            }
            // A GONE answer is the bug: counted, then the answer is given
            // again so the request still ends.
            const started = std.Io.Clock.awake.now(engine.threadedIo());
            while (true) {
                engine.respond(rc.r.e, h, 200, &.{}, "ok", false) catch |err| switch (err) {
                    error.Gone => {
                        rc.gone += 1;
                        if (pastDeadline(started, 0)) break;
                        std.Thread.yield() catch {};
                        continue;
                    },
                    else => if (rc.failed == null) {
                        rc.failed = err;
                    },
                };
                break;
            }
        }
    }
};

/// `n` traced GETs of /x, one after another on one connection.
fn fetchMany(io: std.Io, url: []const u8, n: usize, ok: *std.atomic.Value(usize)) anyerror!void {
    var http = dusty.Client.init(alloc, io, .{});
    defer http.deinit();
    for (0..n) |_| {
        var keys: [2][]const u8 = undefined;
        var values: [2][]const u8 = undefined;
        var hashes: [2]u8 = undefined;
        var h: dusty.Headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
        try h.add("traceparent", tp_unsampled);
        try h.add("tracestate", "congo=t61rcWkgMzE");
        var resp = try http.fetch(url, .{ .headers = &h });
        defer resp.deinit();
        if (resp.status() == .ok) _ = ok.fetchAdd(1, .monotonic);
    }
}

// SAFETY.md L6's multi-thread stress test of the pin; TESTING.md W3 keeps
// it out of the unit suite (`zig build test-stress`). The deterministic
// claims are the pin-hook tests above.
test "capi jobs: enqueue(opts.req) and the answer racing on two threads, many requests: no answer is GONE [stress]" {
    if (comptime !features.jobs) return error.SkipZigTest;
    try wait.requireStress();
    const clients = 4;
    const each = 50;
    const total = clients * each;
    const rt = try anole.zio.Runtime.init(alloc, .{ .executors = .exact(2), .enable_main_executor = false });
    defer rt.deinit();
    var r: Rig = undefined;
    try r.createRouted(", \"kinds\": [{\"name\": \"t.work\"}]", "{\"path\": \"/x\", \"handler\": 1, \"timeout_ms\": 20000}");
    defer r.deinit();
    try r.start();
    const io = rt.io();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{r.e.port(0)});

    var handles: [total]u64 = undefined;
    var hd: Handed = .{ .handles = &handles };
    var enq_racer: Racer = .{ .r = &r, .hd = &hd, .enqueuer = true };
    var resp_racer: Racer = .{ .r = &r, .hd = &hd, .enqueuer = false };
    var ok: std.atomic.Value(usize) = .init(0);
    var fetches: [clients]std.Io.Future(anyerror!void) = undefined;
    var spawned: usize = 0;
    defer for (fetches[0..spawned]) |*fu| fu.cancel(io) catch {};
    {
        const t1 = try std.Thread.spawn(.{}, Racer.run, .{&enq_racer});
        const t2 = std.Thread.spawn(.{}, Racer.run, .{&resp_racer}) catch |err| {
            hd.stop();
            t1.join();
            return err;
        };
        // Both racers are done before anything is checked.
        defer {
            hd.stop();
            t1.join();
            t2.join();
        }
        for (&fetches) |*fu| {
            fu.* = try io.concurrent(fetchMany, .{ io, url, each, &ok });
            spawned += 1;
        }
        var seen: usize = 0;
        while (seen < total) {
            const i = try r.ev.waitFor(.request, seen, 10000);
            handles[seen] = r.ev.list.items[i].handle;
            seen += 1;
            hd.published.store(seen, .release);
        }
    }
    for (&fetches) |*fu| try fu.await(io);
    try std.testing.expectEqual(@as(?anyerror, null), resp_racer.failed);
    try std.testing.expectEqual(@as(?anyerror, null), enq_racer.failed);
    try std.testing.expectEqual(@as(u32, 0), resp_racer.gone);
    try std.testing.expectEqual(@as(usize, total), ok.load(.acquire));
}
