//! `Server.run` under `deployment = lambda` through the Lambda Runtime API
//! (design-lambda §6.2): the INIT phase's errors go to
//! `/runtime/init/error`, a no-op extension makes Lambda send SIGTERM,
//! and `concurrency` workers each poll `/next` and answer through the
//! router (`exchange.zig`). Nothing runs between invocations: spans are
//! flushed before the next `/next`, and idle connections are closed when
//! an invocation comes after a long gap (a frozen environment's sockets
//! may have been dropped by a NAT gateway).

const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const dusty = @import("dusty");
const lambda = @import("root.zig");
const runtime = @import("runtime.zig");
const exchange = @import("exchange.zig");
const modes = @import("../modes.zig");
const url = @import("../db/url.zig");

const log = std.log.scoped(.anole);

/// Tests: taken off `last_end` (ms) before the idle check, as if the gap
/// since the last invocation were that much longer.
pub var _test_clock_offset_ms: std.atomic.Value(i64) = .init(0);
/// Tests: stands for AWS_LAMBDA_INITIALIZATION_TYPE.
pub var _test_initialization_type: ?[]const u8 = null;

/// `/next` failing this many times in a row ends `run`.
const max_next_failures = 3;

fn realMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

/// The platform's own variables: the real environment only (a `.env`
/// line never changes them).
fn platformVar(name: []const u8) ?[]const u8 {
    return url.realEnv(null, name);
}

fn functionEnv() exchange.Env {
    return .{
        .function_name = platformVar("AWS_LAMBDA_FUNCTION_NAME") orelse "",
        .memory_mb = if (platformVar("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")) |v| std.fmt.parseInt(u32, v, 10) catch 0 else 0,
        .version = platformVar("AWS_LAMBDA_FUNCTION_VERSION") orelse "",
        .log_stream = platformVar("AWS_LAMBDA_LOG_STREAM_NAME") orelse "",
        .log_group = platformVar("AWS_LAMBDA_LOG_GROUP_NAME") orelse "",
    };
}

/// What the workers share with `serve`.
const Shared = struct {
    /// Set by a worker that hit a fatal Runtime API error.
    fatal: std.Io.Event = .unset,
    fatal_why: std.atomic.Value(?[*:0]const u8) = .init(null),
    /// No new `/next` after this.
    stopping: std.atomic.Value(bool) = .init(false),
    /// Workers inside an invocation.
    busy: std.atomic.Value(u32) = .init(0),

    fn fail(sh: *Shared, io: std.Io, why: [*:0]const u8) void {
        _ = sh.fatal_why.cmpxchgStrong(null, why, .acq_rel, .acquire);
        sh.fatal.set(io);
    }
};

/// Serves Lambda invocations until SIGTERM, SIGINT or `stop`, or a fatal
/// Runtime API error. `app` is a `*anole.Server(Ctx)`.
pub fn serve(comptime Ctx: type, app: anytype) anyerror!void {
    const io = app.rt.io();
    const gpa = app.gpa;
    const l = app.mode.lambda.?;
    const opts = app.lambda_options;

    var rt = runtime.Runtime.init(gpa, io, l.endpoint) catch |err| {
        app.lambda_failure = @errorName(err);
        return error.LambdaRuntimeApiFailed;
    };
    defer rt.deinit();

    // 2. SnapStart: refused until the random-state audit exists.
    const init_type = _test_initialization_type orelse platformVar("AWS_LAMBDA_INITIALIZATION_TYPE");
    if (init_type) |t| if (std.mem.eql(u8, t, "snap-start")) {
        rt.initError("Function.SnapStartUnsupported", "lambda: SnapStart is not supported yet (restored copies would share random-number state); publish without SnapStart") catch {};
        return error.SnapStartUnsupported;
    };

    // 3. What `run` does before serving; a failure is Lambda's to show.
    app._lambdaPrepare() catch |err| {
        var why_buf: [1024]u8 = undefined;
        const why = app.explainStart(&why_buf, err);
        var type_buf: [128]u8 = undefined;
        const error_type = std.fmt.bufPrint(&type_buf, "Function.{s}", .{@errorName(err)}) catch "Function.InitError";
        rt.initError(error_type, if (why.len > 0) why else @errorName(err)) catch {};
        return err;
    };

    // 4. The SIGTERM extension (not on Managed Instances: no freeze, no
    // extension needed).
    var ext_group: std.Io.Group = .init;
    defer ext_group.cancel(io);
    var ext_arena: std.heap.ArenaAllocator = .init(gpa);
    defer ext_arena.deinit();
    const managed = if (init_type) |t| std.mem.eql(u8, t, "lambda-managed-instances") else false;
    var sigterm = false;
    if (opts.sigterm and l.concurrency == 1 and !managed) {
        if (rt.registerExtension(ext_arena.allocator())) |id| {
            ext_group.concurrent(io, holdExtension, .{ &rt, id }) catch {};
            sigterm = true;
        } else |err| {
            if (err == error.Canceled) return err;
            log.warn("lambda: could not register the SIGTERM extension ({t}); shutdown will be a kill", .{err});
        }
    }

    // 5. The deployment line, with the time since `init`.
    const nexec = app.rt.executors.items.len;
    {
        const ready_ns = std.Io.Clock.real.now(io).nanoseconds - app.init_started_ns;
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        modes.writeLambdaLine(app.mode, .{
            .executors = nexec,
            .event_path = opts.event_path,
            .sigterm = sigterm,
            .ready_ms = @as(f64, @floatFromInt(ready_ns)) / std.time.ns_per_ms,
        }, &w) catch {};
        log.info("{s}", .{std.mem.trimEnd(u8, w.buffered(), "\n")});
    }

    // 6. Ready: `waitReady` (and the C ABI's start) return; nothing is bound.
    app.server.ready.set(io);
    app.server.settled.set(io);

    // 7. The workers.
    const cfg: exchange.Config = .{
        .parse = .{ .base_path = opts.base_path, .keep_stage = opts.keep_stage },
        .event_path = opts.event_path,
        .context_headers = opts.context_headers,
        .stream = l.invoke_mode == .response_stream,
        .request_timeout = app.server.config.timeout.request,
        .deadline_margin = opts.deadline_margin,
        .trusted_proxies = app.mode.trusted != null,
        .env = functionEnv(),
    };
    var shared: Shared = .{};
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);
    const W = Worker(Ctx, @TypeOf(app));
    for (0..l.concurrency) |i| {
        dusty.placement.concurrent(&workers, io, .{ .executor = i % nexec }, W.run, .{ app, &rt, &cfg, &shared }) catch |err| {
            shared.stopping.store(true, .release);
            return err;
        };
    }

    // 8. Until a signal, `stop` or a fatal error.
    const Done = union(enum) {
        int: anyerror!void,
        term: anyerror!void,
        stop: anyerror!void,
        fatal: anyerror!void,
    };
    var done_buf: [4]Done = undefined;
    var sel = std.Io.Select(Done).init(io, &done_buf);
    if (app.signals) {
        try sel.concurrent(.int, waitForSignal, .{.interrupt});
        try sel.concurrent(.term, waitForSignal, .{.terminate});
    }
    try sel.concurrent(.stop, waitEvent, .{ app.stopped, io });
    try sel.concurrent(.fatal, waitEvent, .{ &shared.fatal, io });
    const first = try sel.await();
    sel.cancelDiscard();

    // Stop polling; an invocation in flight may finish within the budget.
    shared.stopping.store(true, .release);
    app.server.draining.set(io);
    const started = std.Io.Clock.awake.now(io);
    const budget = opts.shutdown_timeout;
    while (shared.busy.load(.acquire) > 0) {
        if (std.Io.Clock.awake.now(io).nanoseconds - started.nanoseconds >= budget.nanoseconds) break;
        io.sleep(.fromMilliseconds(5), .awake) catch break;
    }
    workers.cancel(io);
    ext_group.cancel(io);
    // What the workers' spans left queued, in what remains of the budget.
    if (app.extras.exporter) |e| {
        const spent = std.Io.Clock.awake.now(io).nanoseconds - started.nanoseconds;
        const left: i96 = budget.nanoseconds - spent;
        if (left > 0) e.flush(.{ .nanoseconds = @intCast(left) });
    }

    switch (first) {
        .int, .term => log.info("signal received ({t}); stopped serving Lambda invocations", .{first}),
        .stop => {},
        .fatal => {
            const why = shared.fatal_why.load(.acquire) orelse "it failed";
            app.lambda_failure = std.mem.span(why);
            var buf: [1024]u8 = undefined;
            const text = app.explainStart(&buf, error.LambdaRuntimeApiFailed);
            const line = if (text.len > 0) text else "lambda: the Runtime API failed";
            // As errors.logExplained: a test expecting this must not fail on it.
            if (builtin.is_test) log.warn("{s}", .{line}) else log.err("{s}", .{line});
            return error.LambdaRuntimeApiFailed;
        },
    }
}

fn holdExtension(rt: *runtime.Runtime, id: []const u8) std.Io.Cancelable!void {
    rt.holdExtension(id);
}

fn waitForSignal(kind: zio.SignalKind) anyerror!void {
    var sig = try zio.Signal.init(kind);
    defer sig.deinit();
    try sig.wait();
}

fn waitEvent(event: *std.Io.Event, io: std.Io) anyerror!void {
    try event.wait(io);
}

fn Worker(comptime Ctx: type, comptime App: type) type {
    return struct {
        const E = exchange.Exchange(Ctx);

        /// One `/next` loop.
        fn run(app: App, rt: *runtime.Runtime, cfg: *const exchange.Config, shared: *Shared) void {
            const io = app.rt.io();
            const opts = app.lambda_options;
            var arena: std.heap.ArenaAllocator = .init(app.gpa);
            defer arena.deinit();
            var last_end: ?i64 = null;
            var failures: u8 = 0;
            while (!shared.stopping.load(.acquire)) {
                _ = arena.reset(.{ .retain_with_limit = 256 * 1024 });
                const inv = rt.next(arena.allocator()) catch |err| switch (err) {
                    error.Canceled => return,
                    error.OutOfMemory, error.RuntimeApiFailed => {
                        failures += 1;
                        if (failures >= max_next_failures) {
                            shared.fail(io, "GET /next failed 3 times in a row");
                            return;
                        }
                        io.sleep(.fromMilliseconds(100), .awake) catch return;
                        continue;
                    },
                };
                failures = 0;
                _ = shared.busy.fetchAdd(1, .acq_rel);
                defer _ = shared.busy.fetchSub(1, .acq_rel);

                // A long gap: the environment was frozen, and its idle
                // sockets may be dead without either end knowing.
                const now = realMs(io);
                if (opts.idle_reset) |d| if (last_end) |t| {
                    const gap = now - t;
                    if (gap > d.toMilliseconds()) {
                        app.closeIdleConnections();
                        log.debug("lambda: {d} s since the last invocation; closed idle connections", .{@divTrunc(gap, 1000)});
                    }
                };

                E.answer(app.server, rt, &inv, arena.allocator(), cfg) catch |err| switch (err) {
                    error.Canceled => return,
                    error.RuntimeApiFailed => {
                        shared.fail(io, "it answered with an error that leaves this environment unusable");
                        return;
                    },
                    error.OutOfMemory => log.err("lambda: out of memory answering an invocation", .{}),
                };
                // Spans go out now, before the freeze; the client has its
                // answer already.
                if (app.extras.exporter) |e| e.flush(opts.flush_timeout);
                last_end = realMs(io) - _test_clock_offset_ms.load(.monotonic);
            }
        }
    };
}
