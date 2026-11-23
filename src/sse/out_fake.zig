//! Test-only `Out`: records what is written, and can hold a write until
//! released. Imported only from tests (and from `out.zig` in a test build).

const std = @import("std");
const out_mod = @import("out.zig");

const Out = out_mod.Out;
const WriteError = out_mod.WriteError;

/// For tests: records what is written, and can hold a write until released.
pub const Fake = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Every `write` call, its parts concatenated.
    writes: std.ArrayList([]u8) = .empty,
    /// All bytes written, in order.
    bytes: std.ArrayList(u8) = .empty,
    ended: bool = false,
    aborted: bool = false,
    released: bool = false,
    bursts: u32 = 0,
    open_bursts: u32 = 0,
    /// While set, `write` waits (cancelably) before recording.
    hold: bool = false,
    held: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    /// The next `write` fails with this.
    fail_with: ?WriteError = null,
    /// Called once from inside the next `endBurst`, before it returns
    /// (what another task does while the sender ends its burst).
    on_end_burst: ?struct { f: *const fn (ctx: *anyopaque) void, ctx: *anyopaque } = null,
    writes_done: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Fake {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Fake) void {
        for (self.writes.items) |w| self.gpa.free(w);
        self.writes.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
    }

    pub fn out(self: *Fake) Out {
        return .{ .fake = self };
    }

    /// Lets a held write go on.
    pub fn open(self: *Fake) void {
        self.hold = false;
        self.gate.set(self.io);
    }

    pub fn begin(self: *Fake) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ended or self.aborted) return false;
        self.bursts += 1;
        self.open_bursts += 1;
        return true;
    }

    pub fn write(self: *Fake, parts: []const []const u8) WriteError!void {
        if (self.hold) {
            self.held.set(self.io);
            self.gate.wait(self.io) catch return error.Canceled;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.fail_with) |e| {
            self.fail_with = null;
            return e;
        }
        var total: usize = 0;
        for (parts) |p| total += p.len;
        const copy = self.gpa.alloc(u8, total) catch return error.SystemResources;
        var at: usize = 0;
        for (parts) |p| {
            @memcpy(copy[at..][0..p.len], p);
            at += p.len;
        }
        self.bytes.appendSlice(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.SystemResources;
        };
        self.writes.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return error.SystemResources;
        };
        _ = self.writes_done.fetchAdd(1, .release);
    }

    pub fn endBurst(self: *Fake) void {
        self.mutex.lockUncancelable(self.io);
        self.open_bursts -= 1;
        const hook = self.on_end_burst;
        self.on_end_burst = null;
        self.mutex.unlock(self.io);
        if (hook) |h| h.f(h.ctx);
    }

    pub fn end(self: *Fake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ended = true;
        self.open_bursts -|= 1;
    }

    pub fn abort(self: *Fake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.aborted = true;
        self.open_bursts -|= 1;
    }

    pub fn release(self: *Fake) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.released = true;
    }
};
