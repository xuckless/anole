// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
// });

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .warn },
    },
    .logFn = customLogFn,
};

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const BORDER: []const u8 = &@as([80]u8, @splat('='));

// Log capture for suppressing logs in passing tests.
// The Io is stashed at startup so the global log callback can perform mutex
// operations without having to thread `Io` through every call site.
const LogCapture = struct {
    capture_writer: ?*std.Io.Writer = null,
    mutex: Io.Mutex = .init,
    io: ?Io = null,

    pub fn logFn(
        self: *@This(),
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.enum_literal),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const io = self.io orelse {
            // No Io available yet — fall back to raw stderr.
            const scope_prefix = "(" ++ @tagName(scope) ++ "/" ++ @tagName(level) ++ "): ";
            std.debug.print(scope_prefix ++ format ++ "\n", args);
            return;
        };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const scope_prefix = "(" ++ @tagName(scope) ++ "/" ++ @tagName(level) ++ "): ";

        if (self.capture_writer) |writer| {
            // Write to capture buffer
            writer.print(scope_prefix ++ format ++ "\n", args) catch return;
        } else {
            // Write to stderr (std.debug.print handles its own locking)
            std.debug.print(scope_prefix ++ format ++ "\n", args);
        }
    }

    pub fn startCapture(self: *@This(), io: Io, writer: *std.Io.Writer) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = writer;
    }

    pub fn stopCapture(self: *@This(), io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.capture_writer = null;
    }
};

var log_capture = LogCapture{};

pub fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    log_capture.logFn(level, scope, format, args);
}

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    log_capture.io = io;
    defer log_capture.io = null;

    var env = Env.init(gpa, init.environ_map);
    defer env.deinit(gpa);
    durations.setup(&env, gpa, init.minimal.args);

    var slowest = SlowTracker.init(io, 5);
    defer slowest.deinit(gpa);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    var log_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer log_buffer.deinit();

    var failed_tests: std.ArrayList([]const u8) = .empty;
    defer failed_tests.deinit(gpa);

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    // Count total tests to run
    const test_count = blk: {
        var count: usize = 0;
        for (builtin.test_functions, 0..) |t, ti| {
            if (isSetup(t) or isTeardown(t)) continue;
            if (!env.inShard(ti)) continue;
            const is_unnamed_test = isUnnamed(t);
            if (env.filters.items.len > 0) {
                if (is_unnamed_test) continue;
                var matches = false;
                for (env.filters.items) |f| {
                    if (std.mem.indexOf(u8, t.name, f) != null) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            count += 1;
        }
        break :blk count;
    };

    const root_node = if (env.verbose == .off) std.Progress.start(io, .{
        .root_name = "Running tests",
        .estimated_total_items = test_count,
    }) else std.Progress.Node.none;

    var test_index: usize = 0;

    for (builtin.test_functions, 0..) |t, ti| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }
        if (!env.inShard(ti)) continue;

        var status = Status.pass;
        slowest.startTiming(io);

        const is_unnamed_test = isUnnamed(t);
        if (env.filters.items.len > 0) {
            if (is_unnamed_test) {
                continue;
            }
            var matches = false;
            for (env.filters.items) |f| {
                if (std.mem.indexOf(u8, t.name, f) != null) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                continue;
            }
        }

        const friendly_name = t.name;

        // Update progress
        if (root_node.index != .none) {
            root_node.setCompletedItems(test_index);
            // Progress truncates at 40 chars, so show the end of long names
            const display_name = if (friendly_name.len <= std.Progress.Node.max_name_len)
                friendly_name
            else
                friendly_name[friendly_name.len - std.Progress.Node.max_name_len ..];
            root_node.setName(display_name);
        }

        test_index += 1;

        current_test = friendly_name;
        // Backed by memory that is never handed out again (SAFETY.md E1).
        std.testing.allocator_instance = if (comptime @hasDecl(std.heap, "SafeAllocator")) .init(@import("anole_safety").never_reuse_allocator, .{}) else .{};
        std.testing.io_instance = .init(gpa, .{
            .argv0 = .init(init.minimal.args),
            .environ = init.minimal.environ,
        });

        if (env.do_log_capture) {
            log_buffer.clearRetainingCapacity();
            log_capture.startCapture(io, &log_buffer.writer);
        }

        // Print test name before running (for debugging hangs)
        switch (env.verbose) {
            .naming => Printer.fmt("{s} .. ", .{friendly_name}),
            .tracing => Printer.fmt("{s}\n", .{friendly_name}),
            .off => {},
        }

        const result = t.func();

        if (env.do_log_capture) {
            log_capture.stopCapture(io);
        }

        current_test = null;

        const ns_taken = slowest.endTiming(io, gpa, friendly_name);

        const leaked = if (comptime @hasDecl(std.heap, "SafeAllocator"))
            std.testing.allocator_instance.deinit() != 0
        else
            std.testing.allocator_instance.deinit() == .leak;
        if (leaked) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        std.testing.io_instance.deinit();

        var fail_err: ?anyerror = null;
        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                fail_err = err;
                failed_tests.append(gpa, friendly_name) catch {};
            },
        }

        durations.record(&env, friendly_name, ns_taken, if (leaked) "leak" else @tagName(status));

        const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
        const status_str = switch (status) {
            .pass => "OK",
            .fail => "FAIL",
            .skip => "SKIP",
            .text => "",
        };
        switch (env.verbose) {
            .naming => {
                Printer.status(status, "{s}", .{status_str});
                Printer.fmt(" ({d:.2}ms)\n", .{ms});
            },
            .tracing => {
                Printer.fmt("  ", .{});
                Printer.status(status, "{s}", .{status_str});
                Printer.fmt(" ({d:.2}ms)\n", .{ms});
            },
            .off => {},
        }

        // Print error details for failures (in non-verbose mode, progress will show above this)
        if (fail_err) |err| {
            Printer.fmt("{s}\n", .{BORDER});
            Printer.status(.fail, "\"{s}\" - {s}\n", .{ friendly_name, @errorName(err) });

            // Print captured logs for failed tests
            if (log_buffer.written().len > 0) {
                Printer.fmt("Test output:\n{s}", .{log_buffer.written()});
            }

            Printer.fmt("{s}\n", .{BORDER});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
            if (env.fail_first) {
                break;
            }
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    // End progress before printing summary
    if (root_node.index != .none) {
        root_node.end();
    }

    const total_tests = pass + fail;
    const status = if (fail == 0 and leak == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    if (failed_tests.items.len > 0) {
        Printer.fmt("\n", .{});
        Printer.fmt("Failed tests:\n", .{});
        for (failed_tests.items) |name| {
            Printer.fmt("  {s}\n", .{name});
        }
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0 and leak == 0) 0 else 1);
}

/// ANOLE: per-test durations, the same lines as src/safety/test_runner.zig
/// writes (`<ns>\t<result>\t<name>\t<binary>`, one O_APPEND write each,
/// so shards share the file); tools/test_durations.py summarizes them.
/// Local only, POSIX only.
const durations = struct {
    fn setup(env: *Env, gpa: Allocator, args: std.process.Args) void {
        if (env.durations_path == null) return;
        var it = args.iterateAllocator(gpa) catch return;
        defer it.deinit();
        const argv0 = it.next() orelse "core-test";
        const base = std.fs.path.basename(argv0);
        env.binary = if (env.shard_label.len == 0)
            std.heap.page_allocator.dupe(u8, base) catch "core-test"
        else
            std.fmt.allocPrint(std.heap.page_allocator, "{s}#{s}", .{ base, env.shard_label }) catch "core-test";
    }

    fn record(env: *Env, name: []const u8, ns: u64, result: []const u8) void {
        if (comptime builtin.os.tag == .windows) return;
        const p = env.durations_path orelse return;
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d}\t{s}\t{s}\t{s}\n", .{ ns, result, name, env.binary }) catch return;
        const fd = std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch |err| {
            std.debug.print("ANOLE_TEST_DURATIONS={s}: cannot open it ({t}); no durations recorded\n", .{ p, err });
            env.durations_path = null;
            return;
        };
        defer _ = std.posix.system.close(fd);
        var rest: []const u8 = line;
        while (rest.len > 0) {
            const rc = std.posix.system.write(fd, rest.ptr, rest.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return;
                    rest = rest[@intCast(rc)..];
                },
                .INTR => continue,
                else => return,
            }
        }
    }
};

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    started: Io.Clock.Timestamp,

    fn init(io: Io, count: u32) SlowTracker {
        return .{
            .max = count,
            .started = .now(io, .awake),
            .slowest = SlowestQueue.initContext({}),
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: Allocator) void {
        self.slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker, io: Io) void {
        self.started = .now(io, .awake);
    }

    fn endTiming(self: *SlowTracker, io: Io, allocator: Allocator, test_name: []const u8) u64 {
        const now = Io.Clock.Timestamp.now(io, .awake);
        const ns: u64 = @intCast(self.started.durationTo(now).raw.nanoseconds);

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    const Verbose = enum { off, naming, tracing };

    verbose: Verbose,
    fail_first: bool,
    filters: std.ArrayList([]const u8),
    do_log_capture: bool,
    /// ANOLE_TEST_SHARD=i/n: only the tests whose index in
    /// `builtin.test_functions` is i modulo n (build.zig's
    /// `-Dtest-shards`; the same protocol as src/safety/test_runner.zig).
    shard_index: usize = 0,
    shard_count: usize = 1,
    shard_label: []const u8 = "",
    /// ANOLE_TEST_DURATIONS=<path> (see `durations`).
    durations_path: ?[]const u8 = null,
    binary: []const u8 = "",

    fn init(allocator: Allocator, environ_map: *std.process.Environ.Map) Env {
        var filters: std.ArrayList([]const u8) = .empty;

        if (environ_map.get("TEST_FILTER")) |filter_str| {
            var iter = std.mem.splitScalar(u8, filter_str, '|');
            while (iter.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (trimmed.len > 0) {
                    const owned = allocator.dupe(u8, trimmed) catch @panic("OOM");
                    filters.append(allocator, owned) catch @panic("OOM");
                }
            }
        }

        var env: Env = .{
            .verbose = readEnvVerbose(environ_map),
            .fail_first = readEnvBool(environ_map, "TEST_FAIL_FIRST", false),
            .filters = filters,
            .do_log_capture = readEnvBool(environ_map, "TEST_LOG_CAPTURE", true),
            .durations_path = if (environ_map.get("ANOLE_TEST_DURATIONS")) |p| (if (p.len > 0) p else null) else null,
        };
        if (environ_map.get("ANOLE_TEST_SHARD")) |v| if (v.len > 0) {
            const slash = std.mem.indexOfScalar(u8, v, '/') orelse badShard(v);
            env.shard_index = std.fmt.parseUnsigned(usize, v[0..slash], 10) catch badShard(v);
            env.shard_count = std.fmt.parseUnsigned(usize, v[slash + 1 ..], 10) catch badShard(v);
            if (env.shard_count == 0 or env.shard_index >= env.shard_count) badShard(v);
            env.shard_label = v;
        };
        return env;
    }

    fn badShard(v: []const u8) noreturn {
        std.debug.print("ANOLE_TEST_SHARD={s}: expected <index>/<count> with index < count\n", .{v});
        std.process.exit(1);
    }

    fn inShard(self: *const Env, index: usize) bool {
        return index % self.shard_count == self.shard_index;
    }

    fn deinit(self: *Env, allocator: Allocator) void {
        for (self.filters.items) |f| {
            allocator.free(f);
        }
        self.filters.deinit(allocator);
    }

    fn readEnvBool(environ_map: *std.process.Environ.Map, key: []const u8, deflt: bool) bool {
        const value = environ_map.get(key) orelse return deflt;
        return std.ascii.eqlIgnoreCase(value, "true");
    }

    fn readEnvVerbose(environ_map: *std.process.Environ.Map) Verbose {
        const value = environ_map.get("TEST_VERBOSE") orelse return .off;
        if (std.ascii.eqlIgnoreCase(value, "2")) return .tracing;
        if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "1")) return .naming;
        return .off;
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
