// lint-path: src/example/skipped_test.zig
// A test file: the product rules skip it, DOC still runs.
const std = @import("std");

/// Talks to a dusty server. // expect: DOC
fn helper(p: *anyopaque) *u32 {
    return @ptrCast(@alignCast(p));
}
