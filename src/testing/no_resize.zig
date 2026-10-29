//! The test allocator with every resize and remap refused, for
//! `std.testing.checkAllAllocationFailures`. The test allocator grows a
//! block in place only while it is the last one in its bucket, so whether a
//! growing ArrayList, `toOwnedSlice` or `allocPrint` allocates again depends
//! on what ran before; checkAllAllocationFailures needs the same count of
//! allocations on every run (TESTING.md D4, D5). Here every growth is a new
//! allocation, so the count is fixed.
//!
//!     try std.testing.checkAllAllocationFailures(no_resize.allocator, exercise, .{});
const std = @import("std");

pub const allocator: std.mem.Allocator = .{
    // SAFETY: the vtable never reads its context pointer.
    .ptr = undefined,
    .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free },
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    return std.testing.allocator.rawAlloc(len, alignment, ra);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    std.testing.allocator.rawFree(memory, alignment, ra);
}

test "no_resize: growing a list allocates again and leaks nothing" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.append(allocator, 1);
    const first = list.items.ptr;
    try list.appendNTimes(allocator, 2, list.capacity);
    try std.testing.expect(list.items.ptr != first);
}
