//! What the SQL job stores (store_pg.zig, store_sqlite.zig) share: the `{p}`
//! table prefix in a statement, a result row as a job, and a copy of a job in
//! the caller's arena.
const std = @import("std");
const root = @import("root.zig");
const store = @import("store.zig");

const State = root.State;
const Time = root.Time;

/// `fmt` with every `{p}` replaced by `prefix`.
pub fn expandPrefix(a: std.mem.Allocator, prefix: []const u8, comptime fmt: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest: []const u8 = fmt;
    while (std.mem.indexOf(u8, rest, "{p}")) |i| {
        try out.appendSlice(a, rest[0..i]);
        try out.appendSlice(a, prefix);
        rest = rest[i + 3 ..];
    }
    try out.appendSlice(a, rest);
    return out.items;
}

/// The job in a `row_cols` row. `Conv` is the store's type, which reads its
/// driver's values: `int`, `optInt`, `str`, `optTime`.
pub fn rowFrom(comptime Conv: type, a: std.mem.Allocator, r: anytype) !store.Row {
    const errors = std.json.parseFromSliceLeaky([]root.ErrorEntry, a, Conv.str(r[14]), .{ .ignore_unknown_fields = true }) catch &[_]root.ErrorEntry{};
    const state = std.meta.stringToEnum(State, Conv.str(r[3])) orelse .available;
    return .{
        .id = Conv.int(r[0]),
        .queue = Conv.str(r[1]),
        .kind = Conv.str(r[2]),
        .state = state,
        .priority = @fromBackingInt(@intCast(@as(u8, @intCast(@min(3, @max(0, Conv.int(r[4]))))))),
        .attempt = @intCast(Conv.int(r[5])),
        .max_attempts = @intCast(Conv.int(r[6])),
        .args_json = Conv.str(r[7]),
        .meta_json = Conv.str(r[8]),
        .run_at = Time.fromMillis(Conv.int(r[9])),
        .created_at = Time.fromMillis(Conv.int(r[10])),
        .attempted_at = Conv.optTime(r[11]),
        .finished_at = Conv.optTime(r[12]),
        .worker = if (r[13] == .null) null else Conv.str(r[13]),
        .errors = errors,
        .timeout_ms = if (Conv.optInt(r[15])) |t| @intCast(t) else null,
    };
}
