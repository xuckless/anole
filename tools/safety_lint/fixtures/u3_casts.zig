// lint-path: src/example/u3_casts.zig
const std = @import("std");

fn casts(p: *anyopaque, a: usize) void {
    const x: *u32 = @ptrCast(@alignCast(p)); // expect: U3
    const y: *u32 = @ptrFromInt(a); // expect: U3
    const z = @intFromPtr(x); // expect: U3
    const w: *u8 = @ptrFromInt(@intFromPtr(p)); // expect: U3 U3
    // SAFETY: p points at a u32 (the line above the statement).
    const ok1: *u32 = @ptrCast(@alignCast(p));
    const ok2: *u32 = @ptrCast(@alignCast(p)); // SAFETY: same line
    // A plain comment first.
    // SAFETY: two comment lines above.
    const ok3: *u32 = @ptrFromInt(a);
    _ = .{ y, z, w, ok1, ok2, ok3 };
}

fn multiLine(p: *anyopaque) *u32 {
    // SAFETY: the statement's comment covers its later lines.
    return @ptrCast(
        @alignCast(p),
    );
}

test "casts in test code are not linted" {
    var v: u32 = 0;
    const q: *u8 = @ptrCast(&v);
    _ = q;
}
