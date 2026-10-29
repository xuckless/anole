// lint-path: src/example/u3_undefined.zig
const std = @import("std");

var global: [4]u8 = undefined; // expect: U3

const S = struct {
    buf: [8]u8 = undefined, // expect: U3
    n: u32,
};

fn locals() void {
    var buf: [16]u8 = undefined;
    const arr: [2]u32 = undefined;
    var n: u32 = undefined; // expect: U3
    var s: S = undefined; // expect: U3
    // SAFETY: written before it is read.
    var t: S = undefined;
    var u: u64 = undefined; // SAFETY: written before it is read
    n = 1;
    s.n = 2;
    t.n = 3;
    u = 4;
    _ = .{ &buf, arr };
}

fn arg() void {
    take(undefined); // expect: U3
}

fn take(x: u32) void {
    _ = x;
}

fn nested(comptime n: usize) void {
    // A function inside an anonymous struct passed as a call argument.
    run(struct {
        fn check() void {
            var buf: [512]u8 = undefined;
            _ = &buf;
        }
    });
    comptime var out: [n][]const u8 = undefined;
    var kvs: [n]struct { []const u8, usize } = undefined;
    _ = .{ &out, &kvs };
}

fn run(comptime T: type) void {
    _ = T;
}
