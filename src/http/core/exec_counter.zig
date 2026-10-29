//! Counters kept per executor and summed when read (SAFETY.md L6/L7: the
//! "counters and gauges" pattern), as Linux's `percpu_counter` and folly's
//! `ThreadCachedInt` do: a task adds to its executor's slot, each slot on a
//! cache line of its own, so a counter written on every request moves no
//! cache line between cores; `/metrics` and the console sum the slots.
//!
//! Off the executors (a thread of the blocking pool, a C ABI consumer,
//! `std.Io.Threaded`, the core's stub zio) and on executors past
//! `max_executors`, adds go to one shared slot. Every add is a relaxed
//! `fetchAdd`: a slot has one writer per runtime, and the atomic add keeps
//! it right when two runtimes in a process (tests, mostly) both have an
//! executor with the same index. An uncontended add on a line only one
//! core writes costs about what a plain store does.
//!
//! A value added on one executor and taken away on another leaves one slot
//! high and one low; only `sum` is meaningful, and it is exact once the
//! adds it should see have happened (relaxed reads: a sum taken while
//! tasks add is a snapshot, not a linearizable read).
const std = @import("std");
const placement = @import("placement.zig");

/// Executors with a slot of their own; the rest share the foreign slot.
pub const max_executors = 64;

pub fn PerExecutor(comptime T: type) type {
    if (@typeInfo(T) != .int) @compileError("PerExecutor needs an integer type, not " ++ @typeName(T));
    return struct {
        slots: [max_executors]Slot = @splat(.{}),
        /// Off the executors, and executors past `max_executors`.
        foreign: Slot = .{},

        const Self = @This();
        pub const init: Self = .{};

        const Slot = struct {
            value: std.atomic.Value(T) align(std.atomic.cache_line) = .init(0),
        };

        /// Adds `delta` (wrapping; negative to take away) on the calling
        /// task's executor.
        pub fn add(self: *Self, io: std.Io, delta: T) void {
            _ = self.slot(io).fetchAdd(delta, .monotonic);
        }

        fn slot(self: *Self, io: std.Io) *std.atomic.Value(T) {
            if (placement.currentExecutor(io)) |i| if (i < max_executors) return &self.slots[i].value;
            return &self.foreign.value;
        }

        /// The total over every slot (wrapping).
        pub fn sum(self: *const Self) T {
            var total: T = self.foreign.value.load(.monotonic);
            for (&self.slots) |*s| total +%= s.value.load(.monotonic);
            return total;
        }

        /// Executor `index`'s slot alone (0 past `max_executors`), for a
        /// per-executor gauge.
        pub fn get(self: *const Self, index: usize) T {
            if (index >= max_executors) return 0;
            return self.slots[index].value.load(.monotonic);
        }

        /// The foreign slot alone.
        pub fn getForeign(self: *const Self) T {
            return self.foreign.value.load(.monotonic);
        }
    };
}

test "PerExecutor: adds off zio land in the foreign slot and in the sum" {
    var c: PerExecutor(i64) = .init;
    const io = std.testing.io;
    c.add(io, 5);
    c.add(io, -2);
    try std.testing.expectEqual(@as(i64, 3), c.sum());
    try std.testing.expectEqual(@as(i64, 3), c.getForeign());
    try std.testing.expectEqual(@as(i64, 0), c.get(0));
}
