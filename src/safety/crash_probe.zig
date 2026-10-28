//! Tests that crash on purpose, to check that the test runner prints a
//! crashing test's held log lines (src/safety/test_runner.zig, `captured`).
//! Never part of the suite: `zig build crash-probe` builds this file twice,
//! once per test (a crash ends the process), runs each binary and passes
//! when the process died of the expected signal and its stderr holds the
//! line the test logged before crashing. Without the runner's fatal-signal
//! flush the line stays in the ring and is lost with the process.
const std = @import("std");
const builtin = @import("builtin");

test "crash probe: segfault" {
    std.log.warn("crash probe: held line before the segfault", .{});
    // A page with no access: the store faults like a use after free under
    // never_reuse does (SIGSEGV; SIGBUS on some macOS mappings).
    const page = try std.posix.mmap(null, std.heap.pageSize(), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    const p: *volatile u8 = @ptrCast(page.ptr);
    p.* = 1;
    unreachable;
}

test "crash probe: abort" {
    std.log.warn("crash probe: held line before the abort", .{});
    // What a bundled C library's failed assert() does.
    std.c.abort();
}
