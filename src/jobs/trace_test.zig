//! Tracing of job runs: one CONSUMER span per attempt, linked (not
//! parented) to the context the job was enqueued from, and the context a
//! job carries when it is enqueued. On the memory store with `run =
//! .manual`; the exporter is never started, so the spans stay in its queue.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const wait = @import("anole_test_wait");
const root = @import("root.zig");
const anole = @import("../root.zig");
const trace = anole.observe.trace;

const testing = std.testing;
const gpa = testing.allocator;

const enqueuer = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";

const Fx = struct {
    arena_state: std.heap.ArenaAllocator,
    http: dusty.Client,
    exporter: trace.Exporter,
    client: *root.Client,
    ctx: anole.db.Ctx,
    level: std.log.Level,

    fn init(fx: *Fx, sample_all: bool, run: *const fn (?*anyopaque, *root.Job) anyerror!void) !void {
        fx.level = testing.log_level;
        testing.log_level = .err;
        fx.arena_state = .init(gpa);
        fx.http = dusty.Client.init(gpa, testing.io, .{});
        fx.exporter = try trace.Exporter.init(gpa, testing.io, .{ .http = &fx.http }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .sample_all = sample_all });
        fx.client = try root.Client.init(gpa, testing.io, .{ .store = .memory, .run = .manual, .queues = &.{.{ .name = "mail" }} });
        try fx.client.addHandler(kind, null, run);
        try fx.client.addHandler(child_kind, null, ok);
        try fx.client.start(null, &fx.exporter, null);
        fx.ctx = .{ .io = testing.io, .arena = fx.arena_state.allocator() };
    }

    fn deinit(fx: *Fx) void {
        fx.client.deinit();
        fx.exporter.deinit();
        fx.http.deinit();
        fx.arena_state.deinit();
        testing.log_level = fx.level;
    }

    /// The spans queued so far, encoded as the collector gets them.
    fn sent(fx: *Fx, spans: []trace.Span) ![]const u8 {
        const n = try fx.exporter.queue.get(testing.io, spans, 0);
        defer for (spans[0..n]) |s| fx.exporter.release(s);
        if (n == 0) return "";
        return trace.encode(fx.ctx.arena, "t", spans[0..n]);
    }
};

const kind: root.Kind = .{ .name = "mail.send", .queue = "mail", .attempts = 3, .timeout = .max };
const child_kind: root.Kind = .{ .name = "mail.child", .queue = "mail", .timeout = .max };

fn ok(_: ?*anyopaque, _: *root.Job) anyerror!void {}

fn boom(_: ?*anyopaque, _: *root.Job) anyerror!void {
    return error.Boom;
}

var child_id: root.Id = 0;
var parent_span: [16]u8 = undefined;
fn enqueueChild(_: ?*anyopaque, job: *root.Job) anyerror!void {
    if (job.span_id.len == 16) @memcpy(&parent_span, job.span_id);
    child_id = (try job.client.enqueueRaw(job, "mail.child", "{}", .{})).id;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "jobs: a run is one CONSUMER span 'process <queue>', linked to the enqueuer's traceparent and tracestate" {
    var fx: Fx = undefined;
    try fx.init(true, ok);
    defer fx.deinit();
    const e = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{ .meta = "{\"traceparent\":\"" ++ enqueuer ++ "\",\"tracestate\":\"congo=t61rcWkgMzE\"}" });
    _ = try fx.client.step(&fx.ctx);

    var spans: [4]trace.Span = undefined;
    const n = try fx.exporter.queue.get(testing.io, &spans, 0);
    defer for (spans[0..n]) |s| fx.exporter.release(s);
    try testing.expectEqual(@as(usize, 1), n);
    const s = spans[0];
    // A trace of its own: the enqueuer is a link, not the parent.
    try testing.expect(s.parent_span_id == null);
    try testing.expect(!std.mem.eql(u8, &s.trace_id, "0af7651916cd43dd8448eb211c80319c"));
    const body = try trace.encode(fx.ctx.arena, "t", spans[0..1]);
    try testing.expect(has(body, "\"name\":\"process mail\",\"kind\":5,"));
    try testing.expect(has(body, "\"links\":[{\"traceId\":\"0af7651916cd43dd8448eb211c80319c\",\"spanId\":\"b7ad6b7169203331\",\"traceState\":\"congo=t61rcWkgMzE\",\"flags\":1}]"));
    try testing.expect(has(body, "{\"key\":\"messaging.system\",\"value\":{\"stringValue\":\"anole\"}}"));
    try testing.expect(has(body, "{\"key\":\"messaging.destination.name\",\"value\":{\"stringValue\":\"mail\"}}"));
    const id_attr = try std.fmt.allocPrint(fx.ctx.arena, "{{\"key\":\"messaging.message.id\",\"value\":{{\"stringValue\":\"{d}\"}}}}", .{e.id});
    try testing.expect(has(body, id_attr));
    try testing.expect(has(body, "{\"key\":\"anole.job.attempt\",\"value\":{\"intValue\":\"1\"}}"));
    try testing.expect(has(body, "{\"key\":\"anole.job.max_attempts\",\"value\":{\"intValue\":\"3\"}}"));
    try testing.expect(has(body, "{\"key\":\"anole.job.kind\",\"value\":{\"stringValue\":\"mail.send\"}}"));
    try testing.expect(has(body, "{\"key\":\"anole.job.outcome\",\"value\":{\"stringValue\":\"completed\"}}"));
    try testing.expect(has(body, "\"status\":{\"code\":0}"));
}

test "jobs: a failed attempt's span has error.type, an ERROR status and the outcome retried" {
    var fx: Fx = undefined;
    try fx.init(true, boom);
    defer fx.deinit();
    _ = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{});
    _ = try fx.client.step(&fx.ctx);
    var spans: [4]trace.Span = undefined;
    const body = try fx.sent(&spans);
    try testing.expect(has(body, "{\"key\":\"error.type\",\"value\":{\"stringValue\":\"Boom\"}}"));
    try testing.expect(has(body, "{\"key\":\"anole.job.outcome\",\"value\":{\"stringValue\":\"retried\"}}"));
    try testing.expect(has(body, "\"status\":{\"code\":2}"));
    // Enqueued from nowhere traced: no link.
    try testing.expect(!has(body, "\"links\""));
}

test "jobs: a job enqueued from a traced run carries the run's span as its traceparent" {
    var fx: Fx = undefined;
    try fx.init(true, enqueueChild);
    defer fx.deinit();
    _ = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{ .meta = "{\"traceparent\":\"" ++ enqueuer ++ "\"}" });
    _ = try fx.client.step(&fx.ctx);
    var spans: [4]trace.Span = undefined;
    const n = try fx.exporter.queue.get(testing.io, &spans, 0);
    defer for (spans[0..n]) |s| fx.exporter.release(s);
    // The parent's run and the child's.
    try testing.expectEqual(@as(usize, 2), n);
    const child = (try fx.client.get(&fx.ctx, child_id)).?;
    const want = try std.fmt.allocPrint(fx.ctx.arena, "00-{s}-{s}-01", .{ &spans[0].trace_id, &parent_span });
    try testing.expectEqualStrings(&parent_span, &spans[0].span_id);
    try testing.expectEqualStrings(want, child.meta.object.get("traceparent").?.string);
}

test "jobs: with sample_all off, a run whose enqueuer was not sampled has no span" {
    var fx: Fx = undefined;
    try fx.init(false, ok);
    defer fx.deinit();
    _ = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{ .meta = "{\"traceparent\":\"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00\"}" });
    _ = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{ .meta = "{\"traceparent\":\"" ++ enqueuer ++ "\"}" });
    _ = try fx.client.step(&fx.ctx);
    var spans: [4]trace.Span = undefined;
    const n = try fx.exporter.queue.get(testing.io, &spans, 0);
    defer for (spans[0..n]) |s| fx.exporter.release(s);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(true, spans[0].job.?.link.?.sampled);
}

test "jobs: enqueued from a request whose caller is not sampled, the job keeps the unsampled flag" {
    var fx: Fx = undefined;
    try fx.init(true, ok);
    defer fx.deinit();
    // As the middleware leaves a request it does not record (`sample_all`
    // off, caller unsampled): the caller's IDs, passed on as they came.
    var keys: [2][]const u8 = undefined;
    var values: [2][]const u8 = undefined;
    var hashes: [2]u8 = undefined;
    var req: dusty.Request = .{ .arena = fx.ctx.arena, .io = testing.io, ._parser = undefined, ._transport = undefined };
    req.headers = .{ .keys = &keys, .values = &values, .hashes = &hashes };
    try req.headers.add("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00");
    req.trace_id = "0af7651916cd43dd8448eb211c80319c";
    req.span_id = "b7ad6b7169203331";
    const e = try fx.client.enqueueRaw(&req, "mail.send", "{}", .{});
    const job = (try fx.client.get(&fx.ctx, e.id)).?;
    try testing.expectEqualStrings("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00", job.meta.object.get("traceparent").?.string);
}

/// A request as the middleware leaves it, or as it arrives untraced
/// (`trace_id` null: no tracing here), with the caller's `traceparent`.
fn requestWith(fx: *Fx, req: *dusty.Request, hdr: *[2][2][]const u8, hashes: *[2]u8, traceparent: []const u8, trace_id: ?[]const u8, span_id: ?[]const u8) !void {
    req.* = .{ .arena = fx.ctx.arena, .io = testing.io, ._parser = undefined, ._transport = undefined };
    req.headers = .{ .keys = &hdr[0], .values = &hdr[1], .hashes = hashes };
    try req.headers.add("traceparent", traceparent);
    if (trace_id) |t| req.trace_id = t;
    if (span_id) |sp| req.span_id = sp;
}

test "jobs: from a request that passes its caller's context on, the job keeps that traceparent as it came, flags 03 too" {
    var fx: Fx = undefined;
    try fx.init(true, ok);
    defer fx.deinit();
    // Sampled, and W3C Level 2's random trace ID flag (02).
    const caller = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-03";
    var hdr: [2][2][]const u8 = undefined;
    var hashes: [2]u8 = undefined;
    var req: dusty.Request = undefined;
    // No tracing here: the caller's header is all there is.
    try requestWith(&fx, &req, &hdr, &hashes, caller, null, null);
    const a = try fx.client.enqueueRaw(&req, "mail.send", "{}", .{});
    try testing.expectEqualStrings(caller, (try fx.client.get(&fx.ctx, a.id)).?.meta.object.get("traceparent").?.string);
    // Passed on unrecorded: the middleware kept the caller's IDs.
    try requestWith(&fx, &req, &hdr, &hashes, caller, "0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331");
    const b = try fx.client.enqueueRaw(&req, "mail.send", "{}", .{});
    try testing.expectEqualStrings(caller, (try fx.client.get(&fx.ctx, b.id)).?.meta.object.get("traceparent").?.string);
}

/// Waits until its run is canceled (a deadline, a drain).
const Waits = struct {
    var started: std.atomic.Value(bool) = .init(false);
    var never: std.Io.Event = .unset;

    fn reset() void {
        started.store(false, .release);
        never = .unset;
    }

    fn run(_: ?*anyopaque, job: *root.Job) anyerror!void {
        started.store(true, .release);
        try never.wait(job.io);
    }
};

test "jobs: a run past its timeout has error.type Timeout" {
    Waits.reset();
    var fx: Fx = undefined;
    try fx.init(true, Waits.run);
    defer fx.deinit();
    _ = try fx.client.enqueueRaw(&fx.ctx, "mail.send", "{}", .{ .timeout = .fromMilliseconds(10) });
    _ = try fx.client.step(&fx.ctx);
    var spans: [4]trace.Span = undefined;
    const body = try fx.sent(&spans);
    try testing.expect(has(body, "{\"key\":\"error.type\",\"value\":{\"stringValue\":\"Timeout\"}}"));
    try testing.expect(has(body, "{\"key\":\"anole.job.outcome\",\"value\":{\"stringValue\":\"retried\"}}"));
    try testing.expect(has(body, "\"status\":{\"code\":2}"));
}

fn interruptedCheck(io: std.Io) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var http = dusty.Client.init(gpa, io, .{});
    defer http.deinit();
    var exporter = try trace.Exporter.init(gpa, io, .{ .http = &http }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .sample_all = true });
    defer exporter.deinit();
    const client = try root.Client.init(gpa, io, .{ .store = .memory, .queues = &.{.{ .name = "mail" }} });
    defer client.deinit();
    try client.addHandler(kind, null, Waits.run);
    try client.start(null, &exporter, null);
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try client.enqueueRaw(&ctx, "mail.send", "{}", .{});
    for (0..5000) |_| {
        if (Waits.started.load(.acquire)) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    } else return error.NeverRan;
    // A drain whose deadline has passed: the run is canceled and put back.
    client.drain(std.Io.Clock.Timestamp.now(io, .awake));
    var spans: [4]trace.Span = undefined;
    const n = try exporter.queue.get(io, &spans, 0);
    defer for (spans[0..n]) |sp| exporter.release(sp);
    try testing.expectEqual(@as(usize, 1), n);
    const body = try trace.encode(ctx.arena, "t", spans[0..n]);
    try testing.expect(has(body, "{\"key\":\"anole.job.outcome\",\"value\":{\"stringValue\":\"interrupted\"}}"));
    // Stopped from outside: the handler did not fail.
    try testing.expect(!has(body, "error.type"));
    try testing.expect(has(body, "\"status\":{\"code\":0}"));
}

test "jobs: a run interrupted by a drain has no error.type and an OK status" {
    Waits.reset();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(interruptedCheck, .{io});
    try f.await(io);
}

/// App.deinit's order: the exporter is closed first (it sends through the
/// server's client), then the server and the jobs client stop, a run
/// settling on the way, and the exporter's memory goes last.
fn appOrderCheck(io: std.Io) !void {
    var http = dusty.Client.init(gpa, io, .{});
    defer http.deinit();
    // Counts what the exporter allocates.
    var counting: std.testing.FailingAllocator = .init(gpa, .{});
    var exporter = try trace.Exporter.init(counting.allocator(), io, .{ .http = &http }, .{ .endpoint = "http://127.0.0.1:9", .service_name = "t", .sample_all = true });
    defer exporter.deinit();
    const client = try root.Client.init(gpa, io, .{ .store = .memory, .queues = &.{.{ .name = "mail" }} });
    defer client.deinit();
    try client.addHandler(kind, null, Waits.run);
    try client.start(null, &exporter, null);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var ctx: anole.db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    _ = try client.enqueueRaw(&ctx, "mail.send", "{}", .{});
    try wait.waitFlag(io, "the job's run started", &Waits.started);

    exporter.close();
    const allocations = counting.allocations;
    // The drain cancels the run, which settles on the closed exporter.
    client.drain(std.Io.Clock.Timestamp.now(io, .awake));
    try testing.expectEqual(@as(u64, 1), exporter.dropped.load(.acquire));
    try testing.expectEqual(allocations, counting.allocations);
}

test "jobs: a run settling after the app has closed its exporter drops its span, counted, allocating nothing" {
    Waits.reset();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(appOrderCheck, .{io});
    try f.await(io);
}
