// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Linux cgroup CPU limit detection, ported from zio's `cgroup.zig`, and
//! the cgroup v2 memory limit (`memoryLimit`), read the same way.
//!
//! Container CPU limits (Docker `--cpus`, Kubernetes `resources.limits.cpu`)
//! are enforced by the CFS bandwidth controller as a quota/period pair. That
//! limit is invisible to `sched_getaffinity()`, so sizing anything from the
//! CPU count alone overshoots what the quota allows. This mirrors Go's
//! container-aware GOMAXPROCS default: the effective CPU count is
//! `min(affinity, ceil(quota/period))`.

const std = @import("std");
const builtin = @import("builtin");

/// CPUs this process can use: the affinity count, lowered to the cgroup CPU
/// quota when there is a tighter one. At least 1.
pub fn cpuCount(io: std.Io) std.Io.Cancelable!usize {
    const affinity = std.Thread.getCpuCount() catch 1;
    const limit = try cpuLimit(io) orelse return affinity;
    return @min(affinity, limit);
}

/// CPU limit imposed by the current cgroup's CFS bandwidth controller, rounded
/// up to a whole number of CPUs, or null when there is no limit (or not Linux).
///
/// Following Go's `adjustCgroupGOMAXPROCS`, a fractional quota is rounded up
/// and a limit below 2 is raised to 2 to avoid pathological behavior under a
/// tight quota. Callers still take the min with the affinity-based CPU count,
/// so a genuinely single-CPU affinity mask still wins.
pub fn cpuLimit(io: std.Io) std.Io.Cancelable!?u32 {
    if (builtin.os.tag != .linux) return null;
    return roundRatio(try quotaRatio(io) orelse return null);
}

/// Round a quota/period ratio up to a whole CPU count, with a floor of 2 (see
/// `cpuLimit`). Split out from `cpuLimit` so it can be tested without a cgroup.
fn roundRatio(ratio: f64) u32 {
    // A quota far above the period (a misconfigured or hostile cgroup file)
    // means no real limit: clamp before the cast, which would not fit.
    const max: f64 = @floatFromInt(std.math.maxInt(u32));
    if (!(ratio <= max)) return std.math.maxInt(u32);
    const rounded: u32 = @intFromFloat(@ceil(ratio));
    return @max(rounded, 2);
}

/// The raw quota/period ratio from the cgroup, or null if unlimited/unavailable.
fn quotaRatio(io: std.Io) std.Io.Cancelable!?f64 {
    // cgroup v2 (unified hierarchy). Resolve the process's own cgroup path from
    // /proc/self/cgroup so we read the right cpu.max whether the limit lives at
    // the mount root (namespaced container) or in a leaf slice (systemd
    // CPUQuota=, or a container without a cgroup namespace).
    var path_buf: [512]u8 = undefined;
    if (try v2Path(io, "cpu.max", &path_buf)) |cpu_max_path| {
        var buf: [128]u8 = undefined;
        if (try readFile(io, cpu_max_path, &buf)) |content| {
            // cpu.max holds "<quota> <period>", with <quota> being the literal
            // "max" when there is no limit.
            return parseV2(content);
        }
    }

    // cgroup v1: separate quota and period files under the cpu controller. We
    // use the fixed well-known path, which covers namespaced v1 containers.
    // cpu.cfs_quota_us is -1 when there is no limit.
    var quota_buf: [32]u8 = undefined;
    const quota_str = try readFile(io, "/sys/fs/cgroup/cpu/cpu.cfs_quota_us", &quota_buf) orelse return null;
    const quota = std.fmt.parseInt(i64, std.mem.trim(u8, quota_str, " \n"), 10) catch return null;
    if (quota < 0) return null;

    var period_buf: [32]u8 = undefined;
    const period_str = try readFile(io, "/sys/fs/cgroup/cpu/cpu.cfs_period_us", &period_buf) orelse return null;
    const period = std.fmt.parseInt(i64, std.mem.trim(u8, period_str, " \n"), 10) catch return null;
    if (period <= 0) return null;

    return @as(f64, @floatFromInt(quota)) / @as(f64, @floatFromInt(period));
}

/// The memory limit of the current process's cgroup v2 (its `memory.max`),
/// in bytes, or null when there is none (or not Linux, or cgroup v1). Only
/// the process's own cgroup is read, as `cpuLimit` reads its `cpu.max`: a
/// limit set on an ancestor (a systemd slice) is not seen.
pub fn memoryLimit(io: std.Io) std.Io.Cancelable!?u64 {
    if (builtin.os.tag != .linux) return null;
    var path_buf: [512]u8 = undefined;
    const path = try v2Path(io, "memory.max", &path_buf) orelse return null;
    var buf: [64]u8 = undefined;
    return parseMemoryMax(try readFile(io, path, &buf) orelse return null);
}

/// A quarter of the cgroup's limit or of RAM, whichever is lower, at
/// least 64 MiB (as the JVM sizes its heap by default,
/// MaxRAMPercentage=25); 1 GiB when neither can be read. HTTP/3's send
/// memory and the server's buffer budget (`ServerConfig.buffer_budget`)
/// each default to it.
pub fn memoryQuarter(cgroup_max: ?u64, ram: ?u64) u64 {
    const min_limit: u64 = 64 << 20;
    const memory = if (cgroup_max) |cg| (if (ram) |r| @min(cg, r) else cg) else ram orelse return 1 << 30;
    return @max(min_limit, memory / 4);
}

/// What the process's memory map allows, for `ServerConfig.max_tasks`:
/// `vm.max_map_count` and the mappings in use now. Null off Linux, or when
/// either can't be read.
pub const MapCount = struct {
    max: u64,
    in_use: u64,
};

pub fn mapCount(io: std.Io) std.Io.Cancelable!?MapCount {
    if (builtin.os.tag != .linux) return null;
    var buf: [32]u8 = undefined;
    const max = parseCount(try readFile(io, "/proc/sys/vm/max_map_count", &buf) orelse return null) orelse return null;
    // One line per mapping; read in pieces, as a process may have
    // thousands.
    const file = std.Io.Dir.cwd().openFile(io, "/proc/self/maps", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer file.close(io);
    var maps_buf: [4096]u8 = undefined;
    var r = file.readerStreaming(io, &maps_buf);
    const in_use = countLines(&r.interface) catch |err| switch (err) {
        error.ReadFailed => if (r.err) |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => return null,
        } else return null,
    };
    return .{ .max = max, .in_use = in_use };
}

/// Request tasks per executor that `vm.max_map_count` leaves room for:
/// what the mappings in use and an eighth of headroom (malloc, TLS, the
/// tasks nothing counts) leave, at two mappings per coroutine stack (zio
/// maps a stack's guard and its committed part apart, slabs included),
/// over the executors; at least 1.
pub fn taskCap(m: MapCount, executors: usize) u32 {
    const free = m.max -| m.in_use -| m.max / 8;
    const per = free / 2 / @max(executors, 1);
    return @intCast(@max(1, @min(per, std.math.maxInt(u32) - 1)));
}

fn parseCount(content: []const u8) ?u64 {
    return std.fmt.parseInt(u64, std.mem.trim(u8, content, " \n"), 10) catch null;
}

fn countLines(r: *std.Io.Reader) error{ReadFailed}!u64 {
    var n: u64 = 0;
    while (true) {
        _ = r.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return n,
            error.ReadFailed => return error.ReadFailed,
        };
        n += 1;
    }
}

/// memory.max holds a byte count, or the literal "max" when there is no limit.
fn parseMemoryMax(content: []const u8) ?u64 {
    const s = std.mem.trim(u8, content, " \n");
    if (std.mem.eql(u8, s, "max")) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// Build the path to the current process's cgroup v2 `file` into `out`, or
/// null if the process is not on a unified (v2) hierarchy. The v2 line in
/// /proc/self/cgroup has the form "0::<path>"; the file lives at
/// /sys/fs/cgroup<path>/<file>.
fn v2Path(io: std.Io, file: []const u8, out: []u8) std.Io.Cancelable!?[]const u8 {
    var buf: [1024]u8 = undefined;
    const content = try readFile(io, "/proc/self/cgroup", &buf) orelse return null;
    return buildV2Path(content, file, out);
}

/// Parse /proc/self/cgroup `content` and build the v2 path of `file` into `out`.
fn buildV2Path(content: []const u8, file: []const u8, out: []u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const rel = line["0::".len..];
        return std.fmt.bufPrint(out, "/sys/fs/cgroup{s}/{s}", .{ rel, file }) catch return null;
    }
    return null;
}

fn parseV2(content: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    const quota_str = it.next() orelse return null;
    if (std.mem.eql(u8, quota_str, "max")) return null;
    const period_str = it.next() orelse return null;

    const quota = std.fmt.parseInt(i64, quota_str, 10) catch return null;
    const period = std.fmt.parseInt(i64, period_str, 10) catch return null;
    if (quota < 0 or period <= 0) return null;

    return @as(f64, @floatFromInt(quota)) / @as(f64, @floatFromInt(period));
}

/// Read a small pseudo-file into `buf`, returning the bytes read, or null on
/// any other error (missing controller, permission, etc.) so detection
/// degrades to the affinity-only path. A cancel is not such an error: the
/// caller is being stopped, and hears about it.
fn readFile(io: std.Io, path: []const u8, buf: []u8) std.Io.Cancelable!?[]const u8 {
    const content = std.Io.Dir.cwd().readFile(io, path, buf) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return null,
    };
    if (content.len == 0) return null;
    return content;
}

test "parseV2: explicit limit" {
    try std.testing.expectEqual(@as(?f64, 2.0), parseV2("200000 100000\n"));
    try std.testing.expectEqual(@as(?f64, 1.5), parseV2("150000 100000"));
}

test "parseV2: unlimited" {
    try std.testing.expectEqual(@as(?f64, null), parseV2("max 100000\n"));
}

test "parseV2: malformed" {
    try std.testing.expectEqual(@as(?f64, null), parseV2(""));
    try std.testing.expectEqual(@as(?f64, null), parseV2("200000"));
    try std.testing.expectEqual(@as(?f64, null), parseV2("abc 100000"));
    try std.testing.expectEqual(@as(?f64, null), parseV2("200000 0"));
}

test "buildV2Path: root and leaf" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/sys/fs/cgroup//cpu.max", buildV2Path("0::/\n", "cpu.max", &out).?);
    try std.testing.expectEqualStrings(
        "/sys/fs/cgroup/app.slice/my.service/cpu.max",
        buildV2Path("0::/app.slice/my.service\n", "cpu.max", &out).?,
    );
    // Hybrid layout: v1 controller lines precede the unified "0::" line.
    try std.testing.expectEqualStrings(
        "/sys/fs/cgroup/foo/cpu.max",
        buildV2Path("3:cpu,cpuacct:/foo\n0::/foo\n", "cpu.max", &out).?,
    );
}

test "buildV2Path: memory.max" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/sys/fs/cgroup/app.slice/my.service/memory.max",
        buildV2Path("0::/app.slice/my.service\n", "memory.max", &out).?,
    );
}

test "parseMemoryMax: a limit, none, malformed" {
    try std.testing.expectEqual(@as(?u64, 536870912), parseMemoryMax("536870912\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemoryMax("max\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemoryMax(""));
    try std.testing.expectEqual(@as(?u64, null), parseMemoryMax("12abc"));
    try std.testing.expectEqual(@as(?u64, null), parseMemoryMax("-1"));
}

test "buildV2Path: no unified hierarchy" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), buildV2Path("3:cpu,cpuacct:/foo\n", "cpu.max", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), buildV2Path("", "cpu.max", &out));
}

test "roundRatio: ceil with floor of 2" {
    try std.testing.expectEqual(2, roundRatio(0.5));
    try std.testing.expectEqual(2, roundRatio(1.0));
    try std.testing.expectEqual(2, roundRatio(1.5));
    try std.testing.expectEqual(2, roundRatio(2.0));
    try std.testing.expectEqual(3, roundRatio(2.1));
    try std.testing.expectEqual(4, roundRatio(4.0));
    // A quota far above the period does not fit a u32: no real limit.
    try std.testing.expectEqual(std.math.maxInt(u32), roundRatio(9.2e18));
    try std.testing.expectEqual(std.math.maxInt(u32), roundRatio(parseV2("9223372036854775807 1").?));
}

test "memoryQuarter: a quarter of the lower of the cgroup's and RAM, at least 64 MiB" {
    const MiB: u64 = 1 << 20;
    const GiB: u64 = 1 << 30;
    // A quarter of RAM with no cgroup limit; of the cgroup's when lower.
    try std.testing.expectEqual(8 * GiB, memoryQuarter(null, 32 * GiB));
    try std.testing.expectEqual(512 * MiB, memoryQuarter(2 * GiB, 32 * GiB));
    // A cgroup limit above RAM (or a huge one) leaves RAM's.
    try std.testing.expectEqual(8 * GiB, memoryQuarter(1 << 62, 32 * GiB));
    try std.testing.expectEqual(GiB, memoryQuarter(4 * GiB, null));
    // At least 64 MiB; 1 GiB when neither is known.
    try std.testing.expectEqual(64 * MiB, memoryQuarter(128 * MiB, 32 * GiB));
    try std.testing.expectEqual(GiB, memoryQuarter(null, null));
    // Split per executor, as the buffer budget is.
    try std.testing.expectEqual(256 * MiB, memoryQuarter(null, 32 * GiB) / 32);
}

test "taskCap: the room vm.max_map_count leaves, two mappings a task, per executor" {
    // 65530 - 1500 - 8191 = 55839 mappings; 27919 tasks; 6979 each of 4.
    try std.testing.expectEqual(@as(u32, 6979), taskCap(.{ .max = 65530, .in_use = 1500 }, 4));
    try std.testing.expectEqual(@as(u32, 27919), taskCap(.{ .max = 65530, .in_use = 1500 }, 0));
    // Nothing left still lets one through.
    try std.testing.expectEqual(@as(u32, 1), taskCap(.{ .max = 1000, .in_use = 5000 }, 4));
    // A huge limit stays below "no cap".
    try std.testing.expect(taskCap(.{ .max = 1 << 62, .in_use = 0 }, 1) < std.math.maxInt(u32));
}

test "mapCount parsing: the sysctl's number and one mapping per line" {
    try std.testing.expectEqual(@as(?u64, 65530), parseCount("65530\n"));
    try std.testing.expectEqual(@as(?u64, null), parseCount("lots\n"));
    var r: std.Io.Reader = .fixed(
        \\55d0c8a00000-55d0c8a01000 r--p 00000000 00:1f 123 /usr/bin/x
        \\55d0c8a01000-55d0c8a02000 r-xp 00001000 00:1f 123 /usr/bin/x
        \\7ffc1a000000-7ffc1a021000 rw-p 00000000 00:00 0 [stack]
        \\
    );
    try std.testing.expectEqual(@as(u64, 3), try countLines(&r));
    var empty: std.Io.Reader = .fixed("");
    try std.testing.expectEqual(@as(u64, 0), try countLines(&empty));
    // The running process has some, on Linux.
    if (builtin.os.tag == .linux) {
        const m = (try mapCount(std.testing.io)) orelse return;
        try std.testing.expect(m.max > 0 and m.in_use > 0);
    }
}
