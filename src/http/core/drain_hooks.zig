// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! Callbacks a server runs once, when it starts to drain. A request that
//! outlives ordinary ones (a WebSocket, an event stream) registers one to
//! hear about the drain, rather than keeping a task of its own waiting on
//! `Request.drain` for its whole life: a waiting task holds a stack.

const std = @import("std");

pub const DrainHooks = struct {
    mutex: std.Io.Mutex = .init,
    list: std.DoublyLinkedList = .{},
    fired: bool = false,

    pub const Hook = struct {
        /// Runs once, when the drain starts (or at `add`, when it already
        /// has), on the task that started it and under the registry's
        /// lock: it must not wait. Anything that might (a write to a peer)
        /// goes to a task it spawns.
        callback: *const fn (*Hook) void,
        node: std.DoublyLinkedList.Node = .{},
        linked: bool = false,
    };

    /// Registers `hook`, or runs it at once when the drain has started.
    /// `hook` must stay put until `remove`.
    pub fn add(self: *DrainHooks, io: std.Io, hook: *Hook) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fired) return hook.callback(hook);
        self.list.append(&hook.node);
        hook.linked = true;
    }

    /// Takes `hook` out. Once this returns its callback is not running,
    /// and will not run.
    pub fn remove(self: *DrainHooks, io: std.Io, hook: *Hook) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!hook.linked) return;
        self.list.remove(&hook.node);
        hook.linked = false;
    }

    /// Runs every registered hook, once; a hook added later runs as it is
    /// added. The second call does nothing.
    pub fn fire(self: *DrainHooks, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.fired) return;
        self.fired = true;
        while (self.list.popFirst()) |node| {
            const hook: *Hook = @fieldParentPtr("node", node);
            hook.linked = false;
            hook.callback(hook);
        }
    }
};

test "DrainHooks: each hook runs once, a late one at once, a removed one never" {
    const io = std.testing.io;
    const Counted = struct {
        hook: DrainHooks.Hook = .{ .callback = run },
        runs: usize = 0,
        fn run(h: *DrainHooks.Hook) void {
            const self: *@This() = @fieldParentPtr("hook", h);
            self.runs += 1;
        }
    };
    var hooks: DrainHooks = .{};
    var a: Counted = .{};
    var b: Counted = .{};
    var gone: Counted = .{};
    hooks.add(io, &a.hook);
    hooks.add(io, &gone.hook);
    hooks.add(io, &b.hook);
    hooks.remove(io, &gone.hook);
    hooks.fire(io);
    hooks.fire(io);
    try std.testing.expectEqual(1, a.runs);
    try std.testing.expectEqual(1, b.runs);
    try std.testing.expectEqual(0, gone.runs);
    // Removing after the drain ran it is harmless.
    hooks.remove(io, &a.hook);

    var late: Counted = .{};
    hooks.add(io, &late.hook);
    try std.testing.expectEqual(1, late.runs);
    hooks.remove(io, &late.hook);
}
