//! SAFETY.md L5 (E1): no allocation inside a spin section.
//!
//! `SpinCheckedAllocator` wraps an allocator and, in Debug and test builds,
//! panics when the calling thread holds a `safety.SpinLock` at an allocator
//! call (alloc, resize, remap or free), naming where the call is and where
//! each held lock was taken (`lock.checkAllocation`). Outside those builds
//! `allocator()` is the wrapped allocator itself, so nothing is added.
//!
//! The test allocator (`std.testing.allocator`) is std's `SafeAllocator`,
//! whose calls can't be intercepted; a test that claims a site keeps
//! allocations out of a spin section wraps the allocator it hands the code
//! (`var checked: SpinCheckedAllocator = .init(std.testing.allocator)`).
const std = @import("std");
const lock = @import("lock.zig");
const enabled = @import("root.zig").enabled;
const Alignment = std.mem.Alignment;

pub const SpinCheckedAllocator = struct {
    child: std.mem.Allocator,

    pub fn init(wrapped: std.mem.Allocator) SpinCheckedAllocator {
        return .{ .child = wrapped };
    }

    pub fn allocator(self: *SpinCheckedAllocator) std.mem.Allocator {
        if (!enabled) return self.child;
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn from(ctx: *anyopaque) *SpinCheckedAllocator {
        // SAFETY: `allocator()` sets the context to a *SpinCheckedAllocator.
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        lock.checkAllocation(ra);
        return from(ctx).child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        lock.checkAllocation(ra);
        return from(ctx).child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        lock.checkAllocation(ra);
        return from(ctx).child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        lock.checkAllocation(ra);
        from(ctx).child.rawFree(memory, alignment, ra);
    }
};

/// A test fixture with the bug the check is for: a table that grows its
/// list under its spin lock, as `Table.alloc` in src/capi/nats.zig does.
const BadTable = struct {
    lock: lock.SpinLock(.leaf) = .init,
    items: std.ArrayList(u32) = .empty,

    /// Appends under the lock; returns the line of the `lock` call. With
    /// `run` false it only computes the line.
    fn add(t: *BadTable, gpa: std.mem.Allocator, v: u32, run: bool) !u32 {
        const line = @src().line + 1;
        if (run) t.lock.lock();
        defer if (run) t.lock.unlock();
        if (run) try t.items.append(gpa, v);
        return line;
    }

    /// The shape of the fix: the list grows outside the lock, and the
    /// append under it only uses capacity already there.
    fn addFixed(t: *BadTable, gpa: std.mem.Allocator, v: u32) !void {
        while (true) {
            t.lock.lock();
            if (t.items.items.len < t.items.capacity) {
                t.items.appendAssumeCapacity(v);
                t.lock.unlock();
                return;
            }
            const want = (t.items.capacity + 1) * 2;
            t.lock.unlock();
            var bigger = try std.ArrayList(u32).initCapacity(gpa, want);
            t.lock.lock();
            if (bigger.capacity > t.items.capacity and bigger.capacity >= t.items.items.len) {
                bigger.appendSliceAssumeCapacity(t.items.items);
                std.mem.swap(std.ArrayList(u32), &bigger, &t.items);
            }
            t.lock.unlock();
            bigger.deinit(gpa);
        }
    }

    fn deinit(t: *BadTable, gpa: std.mem.Allocator) void {
        t.items.deinit(gpa);
    }
};

const child_run = @import("child.zig");

test "spin check: an allocation under a spin lock panics, naming the lock's site" {
    if (!enabled) return error.SkipZigTest;
    const key = "an allocation under a spin lock panics, naming the lock's site";
    if (child_run.isChild(key)) {
        var checked: SpinCheckedAllocator = .init(std.testing.allocator);
        var t: BadTable = .{};
        _ = try t.add(checked.allocator(), 1, true);
        t.deinit(checked.allocator());
        return;
    }
    const out = try child_run.runPanicking(std.testing.allocator, key);
    defer std.testing.allocator.free(out);
    var t: BadTable = .{};
    const line = try t.add(std.testing.allocator, 0, false);
    try std.testing.expect(std.mem.indexOf(u8, out, "SAFETY.md L5: an allocation while holding a leaf spin lock") != null);
    // Where the lock was taken (Debug only: an optimized binary inlines
    // the lock call, as in lock.zig's expectSite).
    if (@import("builtin").mode == .debug) {
        var buf: [40]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "alloc_check.zig:{d}:", .{line});
        if (std.mem.indexOf(u8, out, needle) == null) {
            std.debug.print("expected {s} in the child's stderr:\n{s}\n", .{ needle, out });
            return error.SiteNotNamed;
        }
    }
}

test "spin check: a table that allocates outside its spin lock passes" {
    var checked: SpinCheckedAllocator = .init(std.testing.allocator);
    const gpa = checked.allocator();
    var t: BadTable = .{};
    defer t.deinit(gpa);
    for (0..100) |i| try t.addFixed(gpa, @intCast(i));
    try std.testing.expectEqual(@as(usize, 100), t.items.items.len);
    try std.testing.expectEqual(@as(u32, 99), t.items.items[99]);
}
