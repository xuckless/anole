//! Tests whose claim is a panic. A panic ends the process, so the test runs
//! its own binary again with `ANOLE_TEST_CHILD` set to a part of its name:
//! the runner (src/safety/test_runner.zig) then runs only the tests whose
//! names contain it, and the test, seeing `isChild`, does the thing that
//! panics. The parent checks how the child ended and what it wrote to
//! stderr.
//!
//!     test "x: a double release panics" {
//!         if (child.isChild("a double release panics")) return doubleRelease();
//!         const out = try child.runPanicking(std.testing.allocator, "a double release panics");
//!         defer std.testing.allocator.free(out);
//!         try std.testing.expect(std.mem.indexOf(u8, out, "...") != null);
//!     }
//!
//! Only binaries built with src/safety/test_runner.zig (`addSafeTest` in
//! build.zig) know the variable.
const std = @import("std");
const builtin = @import("builtin");

/// The environment variable the runner filters on (keep in sync with
/// src/safety/test_runner.zig).
pub const env_key = "ANOLE_TEST_CHILD";

/// Whether this process is the child started by `runPanicking(key)`.
pub fn isChild(key: []const u8) bool {
    const gpa = std.heap.page_allocator;
    // `getAlloc` copies the whole environment into a map first, so the
    // allocator must hold all of it: a small fixed buffer fails on an
    // ordinary shell environment and would make every child a parent.
    const v = std.testing.environ.getAlloc(gpa, env_key) catch return false;
    defer gpa.free(v);
    if (!std.mem.eql(u8, v, key)) return false;
    noCoreDump();
    return true;
}

/// The child's panic is the test's claim, not a crash to keep: no core file
/// (systemd-coredump or a core in the working directory) per test run.
fn noCoreDump() void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
}

/// Whether this process is any child run (`env_key` set at all).
fn inChild() bool {
    const gpa = std.heap.page_allocator;
    const v = std.testing.environ.getAlloc(gpa, env_key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        // Unknown: refuse to spawn rather than risk a chain of children.
        else => return true,
    };
    gpa.free(v);
    return true;
}

/// Runs this test binary again with only the tests whose names contain
/// `key`, and returns what the child wrote to stderr (the caller frees it).
/// Fails with `error.ChildDidNotPanic` when the child ended normally, and
/// with `error.NestedChild` when called inside a child: a child never starts
/// another one, so a test that fails to panic (or a runner that fails to
/// filter) costs one extra process, not an unbounded chain (SAFETY.md U4).
pub fn runPanicking(gpa: std.mem.Allocator, key: []const u8) ![]u8 {
    if (inChild()) return error.NestedChild;
    const io = std.testing.io;
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    // The child reports no progress into the parent's build runner.
    _ = env.swapRemove("ZIG_PROGRESS");
    try env.put(env_key, key);
    const result = try std.process.run(gpa, io, .{
        .argv = &.{exe},
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    gpa.free(result.stdout);
    if (result.term.success()) {
        std.debug.print("the child exited normally; its stderr:\n{s}\n", .{result.stderr});
        gpa.free(result.stderr);
        return error.ChildDidNotPanic;
    }
    return result.stderr;
}
