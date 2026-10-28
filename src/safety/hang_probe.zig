//! A deliberately hanging test, to see the test runner's hang dump work
//! (src/safety/test_runner.zig, TESTING.md D2). Never part of the suite:
//! `zig build test -Dhang-probe=true` adds it, `zig build hang-probe` runs it
//! alone. With `ANOLE_TEST_DUMP_AFTER=5` and `--test-timeout 20s` the output
//! shows the hung test by name, its log, every thread's backtrace (the main
//! thread and a helper, both in `blockForever`), the build runner's timeout
//! report; then the same for a test whose teardown hangs (the test Io's
//! deinit waits for a task it left behind); and then the last test passing
//! in a new process. The hung test
//! ignores SIGTERM, as a hung server test holding zio's drain handler
//! would: the runner must still die on the build runner's SIGTERM, or the
//! build waits for the 300 s backstop.
const std = @import("std");

/// Never changes, so a futex wait on it never returns.
var never: u32 = 0;

fn blockForever() void {
    while (true) std.Io.futexWaitUncancelable(std.testing.io, u32, &never, 0);
}

fn helperThread() void {
    blockForever();
}

test "hang probe: a test that never returns is named and dumped, then ended by --test-timeout" {
    std.log.warn("hang probe: this line shows in the dump (held while the test runs)", .{});
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &ignore, null);
    // A second thread, so the dump shows more than one.
    const helper = try std.Thread.spawn(.{}, helperThread, .{});
    helper.detach();
    blockForever();
}

test "hang probe: a hang in the test's teardown is dumped too" {
    std.log.warn("hang probe: this teardown line shows in the dump too", .{});
    // Returns at once, leaving a task that never ends: the runner's
    // `testing.io_instance.deinit()` after the test waits for it forever,
    // still inside the build runner's per-test limit.
    _ = try std.testing.io.concurrent(blockForever, .{});
}

test "hang probe: the run goes on with the next test" {
    try std.testing.expect(never == 0);
}
