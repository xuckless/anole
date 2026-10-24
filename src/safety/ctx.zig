//! U3: the callback-context casts. A C library or a type-erased callback
//! takes `*anyopaque` user data and hands it back; `toCtx` makes it and
//! `fromCtx` recovers the pointer, the one place these casts live.
//!
//! In debug builds `toCtx` records the pointer's type in a small table and
//! `fromCtx` checks it, so a callback that recovers the wrong type panics
//! instead of reading the object as something else. The table is bounded
//! (U4): a later pointer may evict an entry, and a pointer the table no
//! longer knows (or never saw: one made by a plain coercion) is checked
//! for null and alignment only.
const std = @import("std");
const enabled = @import("root.zig").enabled;

/// `ptr` as user data for a callback that `fromCtx` will recover.
pub fn toCtx(ptr: anytype) *anyopaque {
    const P = @TypeOf(ptr);
    comptime checkPointer(P);
    // SAFETY: a single-item pointer coerces to *anyopaque; only constness is dropped.
    const out: *anyopaque = @ptrCast(@constCast(ptr));
    if (enabled) table.put(@intFromPtr(out), typeId(std.meta.Child(P)));
    return out;
}

/// The `*T` that `toCtx` made `ctx` from. Panics on null, on a misaligned
/// pointer, and in debug builds on a pointer recorded with another type.
pub fn fromCtx(comptime T: type, ctx: ?*anyopaque) *T {
    const p = ctx orelse std.debug.panic("SAFETY.md U3: null callback context for {s}", .{@typeName(T)});
    if (enabled) {
        if (table.get(@intFromPtr(p))) |id| if (id != typeId(T))
            std.debug.panic("SAFETY.md U3: a callback context recovered as {s} was made from another type", .{@typeName(T)});
    }
    // SAFETY: the caller made `ctx` from a *T (checked above when recorded); @alignCast checks the alignment.
    return @ptrCast(@alignCast(p));
}

fn checkPointer(comptime P: type) void {
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one) @compileError("toCtx takes a single-item pointer, not " ++ @typeName(P));
}

/// A number per type: the address of a per-type constant.
fn typeId(comptime T: type) usize {
    const Holder = struct {
        const T_ = T;
        var byte: u8 = 0;
    };
    return @intFromPtr(&Holder.byte);
}

/// Pointer -> type id over a fixed array, one slot per hash; a collision
/// overwrites. Lossy on purpose: it is a check, not a registry. Each slot
/// has its own spin lock, so a key and its type id change together; a
/// reader that finds the slot busy skips the check.
const table = struct {
    const bits = 14;
    const Slot = struct { lock: std.atomic.Mutex = .unlocked, key: usize = 0, val: usize = 0 };
    var slots: [1 << bits]Slot = @splat(.{});

    fn index(key: usize) usize {
        return @truncate(((key >> 4) *% 0x9E3779B97F4A7C15) >> (@bitSizeOf(usize) - bits));
    }

    fn put(key: usize, val: usize) void {
        const s = &slots[index(key)];
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
        defer s.lock.unlock();
        s.key = key;
        s.val = val;
    }

    fn get(key: usize) ?usize {
        const s = &slots[index(key)];
        if (!s.lock.tryLock()) return null;
        defer s.lock.unlock();
        return if (s.key == key) s.val else null;
    }
};

test "ctx: round trip" {
    const S = struct { x: u32 };
    var s: S = .{ .x = 7 };
    const c = toCtx(&s);
    try std.testing.expectEqual(@as(u32, 7), fromCtx(S, c).x);
}

test "ctx: a const pointer round-trips too" {
    const S = struct { x: u32 };
    const s: S = .{ .x = 9 };
    try std.testing.expectEqual(@as(u32, 9), fromCtx(S, toCtx(&s)).x);
}
