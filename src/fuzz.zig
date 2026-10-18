//! Fuzz targets' plumbing. A target is a check over one byte string that
//! fails only when a property breaks (a crash, a leak, a wrong answer), never
//! because the input is malformed.
//!
//! Under `zig build test --fuzz` each target is a real fuzz test, seeded with
//! its seeds. In a plain `zig build test` it runs on the seeds and on a few
//! thousand mutations of them from a fixed PRNG seed, so every CI run
//! explores past the seeds, reproducibly.
const std = @import("std");
const builtin = @import("builtin");

/// The largest input a target gets.
pub const max_len = 4096;
/// Mutated inputs per target in a plain test run.
pub const iterations = 3000;

pub fn bytes(comptime check: fn ([]const u8) anyerror!void, seeds: []const []const u8) !void {
    // Seeds as Smith reads a slice: a 4-byte little-endian length, then
    // the bytes. A fuzzing run keeps them for its whole life.
    const a = if (builtin.fuzz) std.heap.page_allocator else std.testing.allocator;
    const corpus = try a.alloc([]const u8, seeds.len);
    for (seeds, corpus) |s, *e| {
        const enc = try a.alloc(u8, 4 + s.len);
        std.mem.writeInt(u32, enc[0..4], @intCast(s.len), .little);
        @memcpy(enc[4..], s);
        e.* = enc;
    }
    defer if (!builtin.fuzz) {
        for (corpus) |e| a.free(e);
        a.free(corpus);
    };
    // Also how the build runner learns this is a fuzz test.
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [max_len]u8 = undefined;
            const n = smith.slice(&buf);
            try run(check, buf[0..n]);
        }
    }.one, .{ .corpus = corpus });
    if (builtin.fuzz) return;

    var prng: std.Random.DefaultPrng = .init(0x616e6f6c65);
    const r = prng.random();
    var buf: [max_len]u8 = undefined;
    for (0..iterations) |_| {
        const n = mutate(r, &buf, seeds);
        try run(check, buf[0..n]);
    }
}

fn run(comptime check: fn ([]const u8) anyerror!void, input: []const u8) !void {
    check(input) catch |err| {
        std.debug.print("fuzz target failed ({t}) on {d} bytes: \"{f}\"\n", .{ err, input.len, std.zig.fmtString(input) });
        return err;
    };
}

/// A seed (or nothing) with a few random edits: bit flips, interesting
/// bytes, insertions, deletions, repeats, truncation, splices.
fn mutate(r: std.Random, buf: *[max_len]u8, seeds: []const []const u8) usize {
    const seed = if (seeds.len > 0) seeds[r.uintLessThan(usize, seeds.len)] else "";
    var len: usize = @min(seed.len, buf.len);
    @memcpy(buf[0..len], seed[0..len]);
    const interesting = [_]u8{ 0, 1, 0x7f, 0x80, 0xff, '\r', '\n', ' ', ',', ';', '=', '"', '.', '-', '0', '9', 'a', 'z', '{', '}' };
    const edits = 1 + r.uintLessThan(usize, 8);
    for (0..edits) |_| {
        switch (r.uintLessThan(u8, 8)) {
            0 => if (len > 0) {
                buf[r.uintLessThan(usize, len)] ^= @as(u8, 1) << r.int(u3);
            },
            1 => if (len > 0) {
                buf[r.uintLessThan(usize, len)] = interesting[r.uintLessThan(usize, interesting.len)];
            },
            2 => if (len < buf.len) {
                const at = r.uintLessThanBiased(usize, len + 1);
                std.mem.copyBackwards(u8, buf[at + 1 .. len + 1], buf[at..len]);
                buf[at] = if (r.boolean()) r.int(u8) else interesting[r.uintLessThan(usize, interesting.len)];
                len += 1;
            },
            3 => if (len > 0) {
                const at = r.uintLessThan(usize, len);
                const n = 1 + r.uintLessThan(usize, @min(len - at, 16));
                std.mem.copyForwards(u8, buf[at .. len - n], buf[at + n .. len]);
                len -= n;
            },
            4 => if (len > 0) {
                // Repeat a chunk.
                const at = r.uintLessThan(usize, len);
                const n = @min(1 + r.uintLessThan(usize, @min(len - at, 64)), buf.len - len);
                std.mem.copyBackwards(u8, buf[at + n .. len + n], buf[at..len]);
                len += n;
            },
            5 => len = r.uintLessThanBiased(usize, len + 1),
            6 => if (seeds.len > 0) {
                // Splice in part of another seed.
                const other = seeds[r.uintLessThan(usize, seeds.len)];
                if (other.len > 0) {
                    const from = r.uintLessThan(usize, other.len);
                    const at = r.uintLessThanBiased(usize, len + 1);
                    const n = @min(other.len - from, buf.len - at);
                    @memcpy(buf[at..][0..n], other[from..][0..n]);
                    len = @max(len, at + n);
                }
            },
            else => if (len < buf.len) {
                buf[len] = r.int(u8);
                len += 1;
            },
        }
    }
    return len;
}

test "mutations stay in bounds" {
    var prng: std.Random.DefaultPrng = .init(1);
    var buf: [max_len]u8 = undefined;
    const big: [max_len]u8 = @splat('x');
    for (0..20000) |_| {
        const n = mutate(prng.random(), &buf, &.{ "", "abc", &big });
        try std.testing.expect(n <= max_len);
    }
}

// Zig 0.17's fuzz mode also instruments C sources compiled into a module
// (dusty's llhttp), and clang's instrumentation calls comparison and switch
// hooks that Zig's fuzzer runtime does not define. They only steer
// libFuzzer's value profiling, so empty ones keep the link working; the C
// code then contributes no comparison feedback.
comptime {
    if (builtin.fuzz) {
        const hooks = struct {
            fn cmp1(_: u8, _: u8) callconv(.c) void {}
            fn cmp2(_: u16, _: u16) callconv(.c) void {}
            fn cmp4(_: u32, _: u32) callconv(.c) void {}
            fn cmp8(_: u64, _: u64) callconv(.c) void {}
            fn switch_(_: u64, _: [*]const u64) callconv(.c) void {}
        };
        @export(&hooks.cmp1, .{ .name = "__sanitizer_cov_trace_cmp1" });
        @export(&hooks.cmp2, .{ .name = "__sanitizer_cov_trace_cmp2" });
        @export(&hooks.cmp4, .{ .name = "__sanitizer_cov_trace_cmp4" });
        @export(&hooks.cmp8, .{ .name = "__sanitizer_cov_trace_cmp8" });
        @export(&hooks.cmp1, .{ .name = "__sanitizer_cov_trace_const_cmp1" });
        @export(&hooks.cmp2, .{ .name = "__sanitizer_cov_trace_const_cmp2" });
        @export(&hooks.cmp4, .{ .name = "__sanitizer_cov_trace_const_cmp4" });
        @export(&hooks.cmp8, .{ .name = "__sanitizer_cov_trace_const_cmp8" });
        @export(&hooks.switch_, .{ .name = "__sanitizer_cov_trace_switch" });
    }
}
