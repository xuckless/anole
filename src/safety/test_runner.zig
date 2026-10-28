//! Zig 0.17.0's default test runner (lib/compiler/test_runner.zig, MIT,
//! Copyright (c) Zig contributors), with one change for SAFETY.md E1: the
//! test allocator of a unit test is backed by `never_reuse.allocator`, so
//! freed memory is never handed out again and a use after free faults at
//! once; a unit test fails when zio's `debug_cancel` reports a swallowed
//! cancellation during it (C3); a test that runs past 110 s is named and
//! every thread's backtrace is dumped before the build runner's
//! `--test-timeout` kills it (`watchdog`, TESTING.md D2), so a hang says
//! where it is; a test's log lines are printed only when it fails or
//! crashes (`captured`, flushed by the panic handler, `debug.handleSegfault`
//! and a SIGABRT handler); and a failed test names its error (the
//! server-mode runner printed only the trace). The fuzzing loops keep `std.heap.page_allocator`
//! (an mprotect per bucket costs a fuzzer's throughput). Re-copy it when moving to the next
//! Zig version and apply the change again (`ANOLE:` marks it).
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const testing = std.testing;
const assert = std.debug.assert;
// ANOLE: `panic` is the root panic handler below (it shows held log lines).
const panicf = std.debug.panic;
const fuzz_abi = std.Build.abi.fuzz;
// ANOLE: the test allocator's backing allocator.
const never_reuse = @import("anole_test_hooks").never_reuse;

/// ANOLE: zio's count of swallowed cancellations (`debug_cancel`); a test
/// during which it rises fails (SAFETY.md C3). build.zig gives every test
/// binary this import (src/safety/test_hooks.zig, or a stub without zio).
const hooks = @import("anole_test_hooks");

fn swallowedCancels() u64 {
    return hooks.swallowedCancels();
}

/// ANOLE: runs a test, failing it when zio reported a swallowed cancellation.
/// Its log lines are held back (`captured`) until the caller knows whether
/// the test failed. The caller arms `watchdog` around this and the test's
/// teardown (the test Io's and allocator's deinit), which the build runner
/// charges to the test too.
fn runTest(test_fn: @TypeOf(builtin.test_functions[0])) anyerror!void {
    captured.begin();
    const before = swallowedCancels();
    try test_fn.func();
    if (swallowedCancels() != before) return error.SwallowedCancel;
}

/// ANOLE: hang detection (TESTING.md D2). A unit test still running after
/// `dump_after_ns` (110 s, or `ANOLE_TEST_DUMP_AFTER` seconds) is taken for a
/// hang: the watchdog thread names it, prints what it has logged so far and
/// every thread's backtrace (gdb on Linux, lldb on macOS) to stderr. That is
/// before the build runner's `--test-timeout 120s` (CI) fires: Zig 0.17's
/// runner (lib/compiler/Maker/Step/Run.zig) takes the child's stderr as it
/// stands at the timeout, reports "'<test>' timed out after ... with
/// stderr:", then SIGTERMs the child and blocks in wait4 until it exits, and
/// goes on with the next test in a new process. So the dump must already be
/// written when the limit hits, and the runner must die on that SIGTERM:
/// SIGTERM is reset to its default action at startup and again before a dump
/// (a hung server test may hold zio's SIGTERM handler, which drains instead
/// of exiting), and the watchdog thread never blocks it. Without
/// `--test-timeout` (a local run), the process aborts after 300 s.
/// Prior art: Go's test alarm (every goroutine's stack, then a panic),
/// CPython's faulthandler.dump_traceback_later, nextest's SIGTERM.
const watchdog = struct {
    const idle = std.math.maxInt(usize);
    const default_dump_after_ns: u64 = 110 * std.time.ns_per_s;
    const abort_after_ns: u64 = 300 * std.time.ns_per_s;
    /// gdb, lldb or sample gets this long, then SIGKILL (which detaches
    /// it). An attach stops every thread of this process, the watchdog's
    /// own included, so the limit is enforced from another process:
    /// coreutils' `timeout` on Linux, a /bin/sh supervisor on macOS
    /// (`supervise`). The watchdog's own deadline, a little later, covers
    /// a debugger that never attached.
    const debugger_limit_s = 60;
    const debugger_limit_arg = std.fmt.comptimePrint("{d}", .{debugger_limit_s});
    const own_deadline_ns: u64 = (debugger_limit_s + 15) * std.time.ns_per_s;
    /// `sh -c supervise sh LIMIT CMD...`: runs CMD and SIGKILLs it after
    /// LIMIT seconds; exits with CMD's status (137 when killed). The timer's
    /// subshell has no stdio, so a leftover `sleep` holds no pipe open.
    const supervise =
        \\limit=$1; shift
        \\"$@" & p=$!
        \\( sleep "$limit"; kill -9 "$p" ) </dev/null >/dev/null 2>&1 & w=$!
        \\wait "$p"; s=$?
        \\kill "$w" 2>/dev/null
        \\exit "$s"
    ;
    const sh_supervise = [_][]const u8{ "/bin/sh", "-c", supervise, "sh", debugger_limit_arg };
    const can_dump = switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    var dump_after_ns: u64 = default_dump_after_ns;
    /// For finding the debugger on PATH.
    var environ: std.process.Environ = undefined;
    var current: std.atomic.Value(usize) = .init(idle);
    var seq: std.atomic.Value(u32) = .init(0);
    var started_ns: std.atomic.Value(u64) = .init(0);
    var started = false;

    /// At runner start: the dump threshold, permission for a debugger child
    /// to attach (Linux's Yama `ptrace_scope=1`, Ubuntu's default, lets a
    /// process trace only its descendants; this test binary only, never
    /// libanole), and SIGTERM's default action.
    fn setup(env: std.process.Environ) void {
        if (comptime !can_dump) return;
        environ = env;
        if (env.getPosix("ANOLE_TEST_DUMP_AFTER")) |v| {
            if (std.fmt.parseUnsigned(u32, v, 10)) |secs| {
                dump_after_ns = @as(u64, secs) * std.time.ns_per_s;
            } else |_| {
                std.debug.print("ANOLE_TEST_DUMP_AFTER={s} is not a number of seconds; dumping hung tests after {d} s\n", .{ v, default_dump_after_ns / std.time.ns_per_s });
            }
        }
        if (comptime builtin.os.tag == .linux) {
            // EINVAL without Yama: nothing to allow (Breakpad and Crashpad
            // ignore the failure the same way).
            _ = std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_PTRACER), std.os.linux.PR.SET_PTRACER_ANY, 0, 0, 0);
        }
        dieOnSigterm();
    }

    fn now() u64 {
        return @intCast(Io.Clock.awake.now(runner_threaded_io).nanoseconds);
    }

    fn begin(index: usize) void {
        if (!started) {
            started = true;
            // The runner's own thread, for the life of the process.
            const t = std.Thread.spawn(.{}, run, .{}) catch return;
            t.detach();
        }
        started_ns.store(now(), .release);
        current.store(index, .release);
        _ = seq.fetchAdd(1, .acq_rel);
    }

    fn end() void {
        current.store(idle, .release);
    }

    fn run() void {
        if (comptime can_dump) dieOnSigterm();
        var dumped_seq: ?u32 = null;
        while (true) {
            Io.sleep(runner_threaded_io, .fromMilliseconds(250), .awake) catch {};
            const s = seq.load(.acquire);
            const i = current.load(.acquire);
            if (i == idle) continue;
            const elapsed = now() -| started_ns.load(.acquire);
            // A test that began after `s` was read: next round.
            if (seq.load(.acquire) != s) continue;
            const name = builtin.test_functions[i].name;
            if (elapsed >= dump_after_ns and dumped_seq != s) {
                dumped_seq = s;
                dump(name, elapsed);
            }
            if (elapsed >= abort_after_ns) {
                if (dumped_seq != s) dump(name, elapsed);
                std.debug.print("\ntest '{s}' has run for {d} s: taken for a hang, aborting\n", .{ name, elapsed / std.time.ns_per_s });
                std.process.abort();
            }
        }
    }

    /// The test's name, its log so far, then every thread's backtrace.
    fn dump(name: []const u8, elapsed: u64) void {
        std.debug.print("\ntest '{s}' has run for {d} s: taken for a hang\n", .{ name, elapsed / std.time.ns_per_s });
        captured.show("its log so far");
        if (comptime !can_dump) return;
        dieOnSigterm();
        const pid = getpid();
        var pid_buf: [16]u8 = undefined;
        const pid_s = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch unreachable;
        std.debug.print("all threads' backtraces (pid {d}):\n", .{pid});
        switch (builtin.os.tag) {
            .linux => _ = runDebugger("gdb", &.{ "timeout", "-s", "KILL", debugger_limit_arg, "gdb", "-batch", "-nx", "-iex", "set debuginfod enabled off", "-p", pid_s, "-ex", "thread apply all bt" }),
            .macos => {
                // lldb needs the right to debug: an interactive session or
                // Developer Mode, or root (GitHub's macOS runners have
                // passwordless sudo). `sample`, which needs neither for a
                // process of the same user, gives every thread's call graph
                // when lldb cannot attach.
                // Under sudo the supervisor runs as root too, so its
                // SIGKILL reaches a root lldb.
                const lldb = sh_supervise ++ [_][]const u8{ "lldb", "--batch", "-p", pid_s, "-o", "thread backtrace all" };
                if (runDebugger("lldb", &lldb)) return endDump(name);
                std.debug.print("hang dump: trying again with sudo -n\n", .{});
                if (runDebugger("sudo -n lldb", &(.{ "sudo", "-n" } ++ lldb))) return endDump(name);
                std.debug.print("hang dump: lldb could not attach; sampling every thread's stack for 1 s instead\n", .{});
                _ = runDebugger("sample", &(sh_supervise ++ [_][]const u8{ "/usr/bin/sample", pid_s, "1", "-mayDie", "-file", "/dev/stderr" }));
            },
            else => comptime unreachable,
        }
        endDump(name);
    }

    fn endDump(name: []const u8) void {
        std.debug.print("hang dump of '{s}' ends here; --test-timeout (SIGTERM) or the {d} s backstop ends the test\n", .{ name, abort_after_ns / std.time.ns_per_s });
    }

    /// Runs a debugger with its output on our stderr (stdout is the build
    /// runner's protocol pipe); false when it could not run or failed.
    fn runDebugger(what: []const u8, argv: []const []const u8) bool {
        // The runner's single-threaded Io has no allocator, which a spawn
        // needs (argv, the PATH search).
        var spawn_io: Io.Threaded = .init(std.heap.page_allocator, .{ .environ = environ });
        defer spawn_io.deinit();
        const child = std.process.spawn(spawn_io.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = Io.File.stderr() },
            .stderr = .inherit,
        }) catch |err| {
            switch (err) {
                error.FileNotFound => std.debug.print("hang dump: {s} is not installed (not on PATH), so no backtraces; install it to get them\n", .{argv[0]}),
                else => std.debug.print("hang dump: could not start {s}: {t}\n", .{ what, err }),
            }
            return false;
        };
        const pid = child.id.?;
        const deadline = now() + own_deadline_ns;
        while (true) {
            if (reap(pid, false)) |status| {
                if (exitedWith(status)) |code| {
                    if (code == 0) return true;
                    // 137 = 128 + SIGKILL: the supervisor's `wait` status.
                    if (code == 137 or code == 124) {
                        std.debug.print("hang dump: {s} took more than {d} s and was killed\n", .{ what, debugger_limit_s });
                        return false;
                    }
                    std.debug.print("hang dump: {s} exited with status {d}\n", .{ what, code });
                } else if (std.posix.W.IFSIGNALED(status) and (status & 0x7f) == 9) { // SIGKILL (Linux and macOS)
                    // `timeout -s KILL` sends the signal to its process
                    // group, itself included.
                    std.debug.print("hang dump: {s} took more than {d} s and was killed\n", .{ what, debugger_limit_s });
                } else {
                    std.debug.print("hang dump: {s} ended by a signal\n", .{what});
                }
                return false;
            }
            if (now() >= deadline) {
                std.posix.kill(pid, .KILL) catch {};
                _ = reap(pid, true);
                std.debug.print("hang dump: {s} took more than {d} s and was killed\n", .{ what, own_deadline_ns / std.time.ns_per_s });
                return false;
            }
            Io.sleep(runner_threaded_io, .fromMilliseconds(100), .awake) catch {};
        }
    }

    /// The wait status of `pid` once it has exited (waiting for it when
    /// `block`), or null while it runs.
    fn reap(pid: std.posix.pid_t, block: bool) ?u32 {
        const flags: u32 = if (block) 0 else std.posix.W.NOHANG;
        while (true) {
            if (builtin.link_libc) {
                var status: c_int = 0;
                const rc = std.c.waitpid(pid, &status, @intCast(flags));
                if (rc == pid) return @bitCast(status);
                if (rc == 0) return null;
                if (std.c.errno(rc) == .INTR) continue;
                return 0; // ECHILD: gone already
            } else {
                var status: i32 = 0;
                const rc = std.os.linux.waitpid(pid, &status, flags);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => return if (rc == 0) null else @bitCast(status),
                    .INTR => continue,
                    else => return 0,
                }
            }
        }
    }

    fn exitedWith(status: u32) ?u8 {
        return if (std.posix.W.IFEXITED(status)) std.posix.W.EXITSTATUS(status) else null;
    }

    fn getpid() std.posix.pid_t {
        return if (builtin.link_libc) std.c.getpid() else std.os.linux.getpid();
    }

    /// SIGTERM back to its default action (the process ends), and unblocked
    /// on the calling thread so that it is always deliverable.
    fn dieOnSigterm() void {
        const dfl: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &dfl, null);
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .TERM);
        std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &set, null);
    }
};

/// ANOLE: quiet logs. A test's log lines are held here while it runs and
/// printed only when it fails, leaks or logs an error (Rust's libtest and
/// Go's t.Log do the same), so a passing test prints nothing: the build
/// runner keeps a passing test's stderr and shows it under the next failure,
/// or under "failed command:" at the end (ziglang/zig#31077, "working as
/// designed: unit tests should avoid printing to stderr in success cases").
/// A ring of the last 256 KiB; what `std.debug.print` and C code write
/// goes straight to stderr as before. A panic prints the held lines first;
/// so do a fatal signal (SIGSEGV, SIGBUS, SIGILL and SIGFPE through the root
/// `debug.handleSegfault`, which zio's stack-fault handler chains to as
/// well; SIGABRT through `onAbort`, for a C assert or `std.process.abort`)
/// with `crashFlush`, before the default handling.
const captured = struct {
    const size = 256 * 1024;
    var ring: [size]u8 = undefined;
    /// For `show` while the test runs: the ring, copied under the lock.
    var copy: [size]u8 = undefined;
    /// Bytes written since `begin`; the ring holds the last `size`.
    var total: usize = 0;
    var on: std.atomic.Value(bool) = .init(false);
    /// Guards `ring`, `total` and `on`'s changes: a spin lock around a
    /// bounded memcpy (SAFETY.md L5); nothing under it prints or waits.
    var lock: std.atomic.Value(bool) = .init(false);

    fn acquire() void {
        @disableInstrumentation();
        while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release() void {
        @disableInstrumentation();
        lock.store(false, .release);
    }

    fn active() bool {
        @disableInstrumentation();
        return on.load(.acquire);
    }

    fn begin() void {
        acquire();
        defer release();
        total = 0;
        on.store(true, .release);
    }

    /// Appends `bytes` when a test is capturing; false when not (the caller
    /// prints them).
    fn append(bytes: []const u8) bool {
        @disableInstrumentation();
        acquire();
        defer release();
        if (!on.load(.monotonic)) return false;
        // Only the last `size` bytes of `bytes` can survive.
        const tail = bytes[bytes.len -| size..];
        var pos = (total + (bytes.len - tail.len)) % size;
        var rest = tail;
        while (rest.len > 0) {
            const n = @min(rest.len, size - pos);
            @memcpy(ring[pos..][0..n], rest[0..n]);
            rest = rest[n..];
            pos = (pos + n) % size;
        }
        total += bytes.len;
        return true;
    }

    /// Ends the capture; prints what was held when `show_it`.
    fn end(show_it: bool) void {
        @disableInstrumentation();
        acquire();
        const was_on = on.load(.monotonic);
        on.store(false, .release);
        release();
        // No writer touches the ring once `on` is false.
        if (was_on and show_it) print(&ring, total, "its log");
    }

    /// Prints what the running test has logged so far, and keeps capturing
    /// (the hang dump).
    fn show(what: []const u8) void {
        acquire();
        const was_on = on.load(.monotonic);
        const n = total;
        if (was_on) @memcpy(&copy, &ring);
        release();
        if (was_on) print(&copy, n, what);
    }

    /// What `n` bytes written into `buf` leave to print, oldest first: when
    /// the ring wrapped, from after the oldest whole line.
    const Held = struct { dropped: usize, first: []const u8, second: []const u8 };

    fn held(buf: *const [size]u8, n: usize) Held {
        @disableInstrumentation();
        if (n <= size) return .{ .dropped = 0, .first = buf[0..n], .second = "" };
        const pos = n % size;
        const old = buf[pos..];
        const skip = if (std.mem.findScalar(u8, old, '\n')) |nl| nl + 1 else old.len;
        return .{ .dropped = n - size + skip, .first = old[skip..], .second = buf[0..pos] };
    }

    fn print(buf: *const [size]u8, n: usize, what: []const u8) void {
        @disableInstrumentation();
        if (n == 0) return;
        const h = held(buf, n);
        if (h.dropped == 0) {
            std.debug.print("--- {s}:\n{s}{s}--- end of {s}\n", .{ what, h.first, h.second, what });
        } else {
            std.debug.print("--- {s} (the first {d} bytes dropped):\n{s}{s}--- end of {s}\n", .{ what, h.dropped, h.first, h.second, what });
        }
    }

    /// Fatal signals reach `crashFlush` on these (`onAbort`, write(2)).
    const can_flush_on_crash = switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    /// At a fatal signal (`signal` names it): ends the capture and writes
    /// what was held with write(2), which a signal handler may call
    /// (std.debug.print takes stderr's lock, which the crashing thread may
    /// hold). The lock is tried once, never waited for: the crash may be
    /// inside `append` on this very thread. A second call (the segfault
    /// handler ends in abort) finds the capture over and writes nothing.
    fn crashFlush(signal: []const u8) void {
        @disableInstrumentation();
        if (comptime !can_flush_on_crash) return;
        if (lock.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            rawWrite("\n--- the test's held log lines are lost: a log line was being stored when it crashed\n");
            return;
        }
        const was_on = on.load(.monotonic);
        on.store(false, .release);
        const n = total;
        release();
        // No writer touches the ring once `on` is false.
        if (!was_on or n == 0) return;
        const h = held(&ring, n);
        var head: [160]u8 = undefined;
        rawWrite(if (h.dropped == 0)
            std.fmt.bufPrint(&head, "\n--- its log (held when it crashed: {s}):\n", .{signal}) catch "--- its log:\n"
        else
            std.fmt.bufPrint(&head, "\n--- its log (held when it crashed: {s}; the first {d} bytes dropped):\n", .{ signal, h.dropped }) catch "--- its log:\n");
        rawWrite(h.first);
        rawWrite(h.second);
        rawWrite("--- end of its log\n");
    }

    /// write(2) to stderr until done or an error other than EINTR.
    fn rawWrite(bytes: []const u8) void {
        @disableInstrumentation();
        var rest = bytes;
        while (rest.len > 0) {
            if (builtin.link_libc) {
                const rc = std.c.write(std.posix.STDERR_FILENO, rest.ptr, rest.len);
                if (rc < 0) {
                    if (std.c.errno(rc) == .INTR) continue;
                    return;
                }
                if (rc == 0) return;
                rest = rest[@intCast(rc)..];
            } else {
                const rc = std.os.linux.write(std.posix.STDERR_FILENO, rest.ptr, rest.len);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => {
                        if (rc == 0) return;
                        rest = rest[rc..];
                    },
                    .INTR => continue,
                    else => return,
                }
            }
        }
    }

    /// At runner start: SIGABRT flushes the held lines, then kills the
    /// process as it would have (`onAbort`).
    fn setup() void {
        if (comptime !can_flush_on_crash) return;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onAbort },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.ONSTACK,
        };
        std.posix.sigaction(.ABRT, &act, null);
    }

    /// The held lines, then SIGABRT again with its default action (so the
    /// process still dies of SIGABRT, with a core dump where enabled), as
    /// CPython's faulthandler and Breakpad do after writing their report.
    fn onAbort(_: std.posix.SIG) callconv(.c) void {
        @disableInstrumentation();
        crashFlush("SIGABRT");
        const dfl: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.ABRT, &dfl, null);
        var set = std.posix.sigemptyset();
        std.posix.sigaddset(&set, .ABRT);
        std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &set, null);
        std.posix.raise(.ABRT) catch {};
    }
};

/// ANOLE: a fatal signal (SIGSEGV, SIGBUS, SIGILL, SIGFPE) prints the test's
/// held log lines first, then Zig's default report (which ends in abort).
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?std.debug.CpuContextPtr) noreturn {
        captured.crashFlush(name);
        std.debug.defaultHandleSegfault(addr, name, opt_ctx);
    }
};

/// ANOLE: a panic prints the test's held log lines first.
pub const panic = std.debug.FullPanic(panicWithLog);

fn panicWithLog(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    captured.end(true);
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var stdout_writer: Io.File.Writer = undefined;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

/// Keep in sync with logic in `std.Build.addRunArtifact` which decides whether
/// the test runner will communicate with the build runner via `std.zig.Server`.
const need_simple = switch (builtin.zig_backend) {
    .stage2_aarch64,
    .stage2_loongarch,
    .stage2_powerpc,
    .stage2_riscv64,
    => true,
    else => false,
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    if (builtin.cpu.arch.isSpirV()) {
        // SPIR-V needs an special test-runner
        return;
    }

    if (need_simple) {
        return mainSimple() catch |err| panicf("test failure: {t}", .{err});
    }

    const args = init.args.toSlice(fba.allocator()) catch |err| panicf("unable to parse command line args: {t}", .{err});

    var listen = false;
    var opt_cache_dir: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir")) {
            opt_cache_dir = arg["--cache-dir=".len..];
        } else {
            panicf("unrecognized command line argument: {s}", .{arg});
        }
    }

    if (builtin.fuzz) {
        const cache_dir = opt_cache_dir orelse @panic("missing --cache-dir=[path] argument");
        fuzz_abi.fuzzer_init(.fromSlice(cache_dir));
    }

    watchdog.setup(init.environ); // ANOLE
    captured.setup(); // ANOLE

    if (listen) {
        return mainServer(init) catch |err| panicf("internal test runner failure: {t}", .{err});
    } else {
        return mainTerminal(init);
    }
}

fn mainServer(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    stdin_reader = .initStreaming(.stdin(), runner_threaded_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_threaded_io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                return std.process.exit(0);
            },
            .query_test_metadata => {
                var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
                defer if (sa.deinit() != 0) @panic("internal test runner memory leak");
                const gpa = sa.allocator();

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0); // Reserve 0 for null.

                const test_fns = builtin.test_functions;
                const names = try gpa.alloc(u32, test_fns.len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, test_fns.len);
                defer gpa.free(expected_panic_msgs);

                for (test_fns, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.ensureUnusedCapacity(gpa, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },

            .run_test => {
                testing.environ = init.environ;
                testing.allocator_instance = .init(never_reuse.allocator, .{ // ANOLE
                    .canary = 0xc3a701ba,
                    .check_write_after_free = true,
                });
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];
                is_fuzz_test = false;

                // let the build server know we're starting the test now
                try server.serveStringMessage(.test_started, &.{});
                // ANOLE: from here to the results, as the build runner's
                // per-test limit counts it.
                watchdog.begin(index);

                const TestResults = std.zig.Server.Message.TestResults;
                const status: TestResults.Status = if (runTest(test_fn)) |v| s: { // ANOLE
                    v;
                    break :s .pass;
                } else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        captured.end(true); // ANOLE
                        // ANOLE: the error's name, which the trace alone
                        // does not say (a bare `expect` is
                        // TestUnexpectedResult; a bounded wait TimedOut).
                        std.debug.print("failed with error.{t}\n", .{err});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                        break :s .fail;
                    },
                };
                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.deinit();
                // ANOLE: the build runner shows stderr for a leak or an
                // error logged too; held lines go with it, else nowhere.
                captured.end(leak_count != 0 or log_err_count != 0);
                watchdog.end(); // ANOLE
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        .fuzz = is_fuzz_test,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                        .leak_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "leak_count"),
                            leak_count,
                        ),
                    },
                });
            },
            .start_fuzzing => {
                // This ensures that this code won't be analyzed and hence reference fuzzer symbols
                // since they are not present.
                if (!builtin.fuzz) unreachable;

                var gpa_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
                defer if (gpa_instance.deinit() != 0) {
                    @panic("internal test runner memory leak");
                };
                const gpa = gpa_instance.allocator();
                var io_instance: Io.Threaded = .init(gpa, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                defer io_instance.deinit();

                const mode: fuzz_abi.LimitKind = @fromBackingInt(@intCast(try server.receiveBody_u8()));
                const amount_or_instance = try server.receiveBody_u64();
                const main_instance = mode == .iterations or amount_or_instance == 0;

                if (main_instance) {
                    const coverage = fuzz_abi.fuzzer_coverage();
                    try server.serveCoverageIdMessage(
                        coverage.id,
                        coverage.runs,
                        coverage.unique,
                        coverage.seen,
                    );
                }

                const n_tests: u32 = try server.receiveBody_u32();
                const test_indexes = try gpa.alloc(u32, n_tests);
                defer gpa.free(test_indexes);
                fuzz_runner = .{
                    .indexes = test_indexes,
                    .server = &server,
                    .gpa = gpa,
                    .threaded_io = &io_instance,
                    .input_poller = undefined,
                };

                {
                    var large_name_buf: std.ArrayList(u8) = .empty;
                    defer large_name_buf.deinit(gpa);
                    for (test_indexes) |*i| {
                        const name_len = try server.receiveBody_u32();
                        const name = if (name_len <= server.in.buffer.len)
                            try server.in.take(name_len)
                        else large_name: {
                            try large_name_buf.resize(gpa, name_len);
                            try server.in.readSliceAll(large_name_buf.items);
                            break :large_name large_name_buf.items;
                        };

                        for (0.., builtin.test_functions) |test_i, test_fn| {
                            if (std.mem.eql(u8, name, test_fn.name)) {
                                i.* = @intCast(test_i);
                                break;
                            }
                        } else {
                            panicf("fuzz test {s} no longer exists", .{name});
                        }

                        if (main_instance) {
                            const relocated_entry_addr = @intFromPtr(builtin.test_functions[i.*].func);
                            const entry_addr = fuzz_abi.fuzzer_unslide_address(relocated_entry_addr);
                            try server.serveU64Message(.fuzz_start_addr, entry_addr);
                        }
                    }
                }

                fuzz_abi.fuzzer_main(n_tests, testing.random_seed, mode, amount_or_instance);

                assert(mode != .forever);
                std.process.exit(0);
            },

            else => {
                std.debug.print("unsupported message: {x}\n", .{@backingInt(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("fuzz test requires server");

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var fuzz_count: usize = 0;
    const root_node = if (builtin.fuzz) std.Progress.Node.none else std.Progress.start(runner_threaded_io, .{
        .root_name = "Test",
        .estimated_total_items = test_fn_list.len,
    });
    const have_tty = Io.File.stderr().isTty(runner_threaded_io) catch unreachable;

    var leaks: usize = 0;
    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .init(never_reuse.allocator, .{ // ANOLE
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        // ANOLE: the watchdog covers the teardown too, and the capture ends
        // after it, so a leak shows the test's held lines (as in server
        // mode).
        watchdog.begin(i);
        const errs_before = log_err_count;
        defer {
            testing.io_instance.deinit();
            const leaked = testing.allocator_instance.deinit() != 0;
            if (leaked) leaks += 1;
            captured.end(leaked or log_err_count != errs_before);
            watchdog.end();
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        const test_node = root_node.start(test_fn.name, 0);
        if (!have_tty) {
            std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        }
        is_fuzz_test = false;
        if (runTest(test_fn)) |_| { // ANOLE
            ok_count += 1;
            test_node.end();
            if (!have_tty) std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...SKIP\n", .{ i + 1, test_fn_list.len, test_fn.name });
                } else {
                    std.debug.print("SKIP\n", .{});
                }
                test_node.end();
            },
            else => {
                fail_count += 1;
                captured.end(true); // ANOLE
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...FAIL ({t})\n", .{
                        i + 1, test_fn_list.len, test_fn.name, err,
                    });
                } else {
                    std.debug.print("FAIL ({t})\n", .{err});
                }
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                test_node.end();
            },
        }
        fuzz_count += @intFromBool(is_fuzz_test);
    }
    root_node.end();
    if (ok_count == test_fn_list.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (fuzz_count != 0) {
        std.debug.print("{d} fuzz tests found.\n", .{fuzz_count});
    }
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        const line_format = "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n";
        // ANOLE: held while a test runs (`captured`), at most 4 KiB a line.
        if (captured.active()) {
            var line: [4096]u8 = undefined;
            var w: Io.Writer = .fixed(&line);
            w.print(line_format, args) catch {
                const mark = "...(cut at 4 KiB)\n";
                @memcpy(line[line.len - mark.len ..], mark);
                w.end = line.len;
            };
            if (captured.append(w.buffered())) return;
            std.debug.print("{s}", .{w.buffered()});
            return;
        }
        std.debug.print(line_format, args);
    }
}

/// Simpler main(), exercising fewer language features, so that
/// work-in-progress backends can handle it.
pub fn mainSimple() anyerror!void {
    @disableInstrumentation();
    // is the backend capable of calling `Io.File.writeAll`?
    const enable_write = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };
    // is the backend capable of calling `Io.Writer.print`?
    const enable_print = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };

    testing.allocator_instance = .init(std.heap.page_allocator, .{});
    testing.io_instance = .init(testing.allocator, .{});

    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;

    // we don't want to bring in File and Writer if the backend doesn't support it
    const stdout = if (enable_write) Io.File.stdout() else {};

    for (builtin.test_functions) |test_fn| {
        if (enable_write) {
            stdout.writeStreamingAll(runner_threaded_io, test_fn.name) catch {};
            stdout.writeStreamingAll(runner_threaded_io, "... ") catch {};
        }
        if (test_fn.func()) |_| {
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "PASS\n") catch {};
        } else |err| {
            if (err != error.SkipZigTest) {
                if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "FAIL\n") catch {};
                failed += 1;
                if (!enable_write) return err;
                continue;
            }
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "SKIP\n") catch {};
            skipped += 1;
            continue;
        }
        passed += 1;
    }
    if (enable_print) {
        var unbuffered_stdout_writer = stdout.writer(runner_threaded_io, &.{});
        unbuffered_stdout_writer.interface.print(
            "{} passed, {} skipped, {} failed\n",
            .{ passed, skipped, failed },
        ) catch {};
    }
    if (failed != 0) std.process.exit(1);
}

var is_fuzz_test: bool = undefined;
var fuzz_runner: if (builtin.fuzz) struct {
    indexes: []u32,
    server: *std.zig.Server,
    gpa: std.mem.Allocator,
    threaded_io: *Io.Threaded,
    input_poller: Io.Future(Io.Cancelable!void),

    comptime {
        assert(builtin.fuzz); // `fuzz_runner` was analyzed in non-fuzzing compilation
    }

    export fn runner_test_run(i: u32) void {
        @disableInstrumentation();

        fuzz_runner.server.serveU32Message(.fuzz_test_change, i) catch |e| switch (e) {
            error.WriteFailed => panicf("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };

        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
        is_fuzz_test = false;

        testing.io_instance = .init(testing.allocator, .{
            .argv0 = fuzz_runner.threaded_io.argv0,
            .environ = fuzz_runner.threaded_io.environ.process_environ,
        });
        defer testing.io_instance.deinit();

        builtin.test_functions[fuzz_runner.indexes[i]].func() catch |err| switch (err) {
            error.SkipZigTest => return,
            else => {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                std.debug.print("failed with error.{t}\n", .{err});
                std.process.exit(1);
            },
        };

        if (!is_fuzz_test) @panic("missed call to std.testing.fuzz");
        if (log_err_count != 0) @panic("error logs detected");
    }

    export fn runner_test_name(i: u32) fuzz_abi.Slice {
        @disableInstrumentation();
        return .fromSlice(builtin.test_functions[fuzz_runner.indexes[i]].name);
    }

    export fn runner_broadcast_input(test_i: u32, bytes_slice: fuzz_abi.Slice) void {
        @disableInstrumentation();
        const bytes = bytes_slice.toSlice();
        fuzz_runner.server.serveBroadcastFuzzInputMessage(test_i, bytes) catch |e| switch (e) {
            error.WriteFailed => panicf("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };
    }

    export fn runner_start_input_poller() void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        const future = io.concurrent(inputPoller, .{}) catch |e| switch (e) {
            error.ConcurrencyUnavailable => @panic("failed to spawn concurrent fuzz input poller"),
        };
        fuzz_runner.input_poller = future;
    }

    export fn runner_stop_input_poller() void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        assert(fuzz_runner.input_poller.cancel(io) == error.Canceled);
    }

    export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        return io.futexWait(u32, ptr, expected) == error.Canceled;
    }

    export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        io.futexWake(u32, ptr, waiters);
    }

    fn inputPoller() Io.Cancelable!void {
        @disableInstrumentation();
        switch (inputPollerInner()) {
            error.Canceled => |e| return e,
            error.ReadFailed => {
                if (stdin_reader.err.? == error.Canceled) return error.Canceled;
                panicf("failed to read from stdin: {t}", .{stdin_reader.err.?});
            },
            error.EndOfStream => @panic("unexpected end of stdin"),
        }
    }

    fn inputPollerInner() (Io.Cancelable || Io.Reader.Error) {
        @disableInstrumentation();
        const server = fuzz_runner.server;
        var large_bytes_list: std.ArrayList(u8) = .empty;
        defer large_bytes_list.deinit(fuzz_runner.gpa);
        while (true) {
            const hdr = try server.receiveMessage();
            if (hdr.tag != .new_fuzz_input) {
                panicf("unexpected message: {x}\n", .{@backingInt(hdr.tag)});
            }
            const test_i = try server.receiveBody_u32();
            const input_len = hdr.bytes_len - 4;
            const bytes = if (input_len <= server.in.buffer.len)
                try server.in.take(input_len)
            else bytes: {
                large_bytes_list.resize(fuzz_runner.gpa, @intCast(input_len)) catch @panic("OOM");
                try server.in.readSliceAll(large_bytes_list.items);
                break :bytes large_bytes_list.items;
            };
            if (fuzz_abi.fuzzer_receive_input(test_i, .fromSlice(bytes))) {
                return error.Canceled;
            }
        }
    }
} else void = undefined;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    // Prevent this function from confusing the fuzzer by omitting its own code
    // coverage from being considered.
    @disableInstrumentation();

    // Some compiler backends are not capable of handling fuzz testing yet but
    // we still want CI test coverage enabled.
    if (need_simple) return;

    // Smoke test to ensure the test did not use conditional compilation to
    // contradict itself by making it not actually be a fuzz test when the test
    // is built in fuzz mode.
    is_fuzz_test = true;

    // Ensure no test failure occurred before starting fuzzing.
    if (log_err_count != 0) @panic("error logs detected");

    // libfuzzer is in a separate compilation unit so that its own code can be
    // excluded from code coverage instrumentation. It needs a function pointer
    // it can call for checking exactly one input. Inside this function we do
    // our standard unit test checks such as memory leaks, and interaction with
    // error logs.
    const global = struct {
        var ctx: @TypeOf(context) = undefined;

        fn test_one() callconv(.c) bool {
            @disableInstrumentation();
            testing.allocator_instance = .init(std.heap.page_allocator, .{
                .canary = 0xcacce5e0,
                .check_write_after_free = true,
            });
            defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
            log_err_count = 0;
            testOne(ctx, @constCast(&testing.Smith{ .in = null })) catch |err| switch (err) {
                error.SkipZigTest => return true,
                else => {
                    const stderr = std.debug.lockStderr(&.{}).terminal();
                    p: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.writeErrorReturnTrace(trace, stderr) catch break :p;
                        }
                        stderr.writer.print("failed with error.{t}\n", .{err}) catch break :p;
                    }
                    std.process.exit(1);
                },
            };
            if (log_err_count != 0) {
                const stderr = std.debug.lockStderr(&.{}).terminal();
                stderr.writer.print("error logs detected\n", .{}) catch {};
                std.process.exit(1);
            }
            return false;
        }
    };

    if (builtin.fuzz) {
        // Preserve the calling test's allocator state
        const prev_allocator_state = testing.allocator_instance;
        defer testing.allocator_instance = prev_allocator_state;

        global.ctx = context;
        fuzz_abi.fuzzer_set_test(&global.test_one);
        for (options.corpus) |elem|
            fuzz_abi.fuzzer_new_input(.fromSlice(elem));
        fuzz_abi.fuzzer_start_test();
        return;
    }

    // When the unit test executable is not built in fuzz mode, only run the
    // provided corpus.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }

    // In case there is no provided corpus, also use an empty
    // string as a smoke test.
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
