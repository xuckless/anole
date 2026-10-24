//! M5: teardown runs exactly once. An object with a teardown carries a
//! `Teardown`; its teardown calls `begin` first (alive -> closing) and
//! `end` last (closing -> dead), and its operations may call `assertAlive`.
//! A second teardown, or a use after `end`, panics in debug builds.
//!
//! After `end` the object is usually freed: a second teardown then reads
//! freed memory, which the test allocator never hands out again (it
//! faults), and a Debug build's allocator poisons (not a valid state:
//! `begin` panics).
const std = @import("std");
const enabled = @import("root.zig").enabled;

pub const State = enum(u8) { alive = 0x5a, closing = 0xc1, dead = 0xde };

pub const Teardown = struct {
    state: if (enabled) std.atomic.Value(State) else void = if (enabled) .init(.alive) else {},

    pub const init: Teardown = .{};

    /// The teardown starts: alive -> closing. Panics if it already started.
    pub fn begin(self: *Teardown) void {
        if (!enabled) return;
        const was = self.state.cmpxchgStrong(.alive, .closing, .acq_rel, .acquire) orelse return;
        panicState("teardown started twice", was);
    }

    /// The teardown ends: closing -> dead. Panics unless `begin` ran.
    pub fn end(self: *Teardown) void {
        if (!enabled) return;
        const was = self.state.cmpxchgStrong(.closing, .dead, .acq_rel, .acquire) orelse return;
        panicState("teardown ended without starting", was);
    }

    /// Panics unless the object is alive (no teardown has started).
    pub fn assertAlive(self: *const Teardown) void {
        if (!enabled) return;
        const s = self.state.load(.acquire);
        if (s != .alive) panicState("used after its teardown started", s);
    }

    /// Panics once the teardown has ended (closing is still usable: the
    /// teardown itself runs then).
    pub fn assertNotDead(self: *const Teardown) void {
        if (!enabled) return;
        const s = self.state.load(.acquire);
        if (s != .alive and s != .closing) panicState("used after its teardown", s);
    }

    /// Whether the teardown has started (debug builds only; false otherwise).
    pub fn closing(self: *const Teardown) bool {
        if (!enabled) return false;
        return self.state.load(.acquire) != .alive;
    }

    fn panicState(comptime what: []const u8, s: State) noreturn {
        const name = std.enums.tagName(State, s) orelse "freed or never initialized";
        std.debug.panic("SAFETY.md M5: object " ++ what ++ " (state: {s})", .{name});
    }
};

test "teardown: begin then end" {
    var t: Teardown = .init;
    t.assertAlive();
    t.begin();
    try std.testing.expect(t.closing() or !enabled);
    t.assertNotDead();
    t.end();
}

test "teardown: zero-sized outside debug builds" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Teardown));
}
