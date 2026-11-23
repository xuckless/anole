//! Where a subscriber's bytes go (internal). The same six operations as
//! `dusty.Parked`: the real one (a parked stream), the fallback (the
//! handler's own task writes through the response's body writer, when the
//! stream cannot park), and, in test builds only, a fake.

const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");

const Parked = dusty.Parked;

pub const WriteError = Parked.WriteError;

/// The `fake` variant exists only in test builds (`noreturn` elsewhere), so
/// production dispatch is two arms.
const Fake = if (builtin.is_test) @import("out_fake.zig").Fake else noreturn;

pub const Out = union(enum) {
    parked: *Parked,
    fallback: *Fallback,
    fake: if (builtin.is_test) *Fake else noreturn,

    pub fn begin(o: Out) bool {
        return switch (o) {
            .parked => |p| p.begin(),
            .fallback => |f| f.state == .open,
            .fake => |f| if (comptime builtin.is_test) f.begin() else unreachable,
        };
    }
    pub fn write(o: Out, parts: []const []const u8) WriteError!void {
        return switch (o) {
            .parked => |p| p.write(parts),
            .fallback => |f| f.write(parts),
            .fake => |f| if (comptime builtin.is_test) f.write(parts) else unreachable,
        };
    }
    pub fn endBurst(o: Out) void {
        switch (o) {
            .parked => |p| p.endBurst(),
            .fallback => {},
            .fake => |f| if (comptime builtin.is_test) f.endBurst() else unreachable,
        }
    }
    pub fn end(o: Out) void {
        switch (o) {
            .parked => |p| p.end(),
            .fallback => |f| f.end(),
            .fake => |f| if (comptime builtin.is_test) f.end() else unreachable,
        }
    }
    pub fn abort(o: Out) void {
        switch (o) {
            .parked => |p| p.abort(),
            .fallback => |f| f.state = .aborted,
            .fake => |f| if (comptime builtin.is_test) f.abort() else unreachable,
        }
    }
    pub fn release(o: Out) void {
        switch (o) {
            .parked => |p| p.release(),
            .fallback => {},
            .fake => |f| if (comptime builtin.is_test) f.release() else unreachable,
        }
    }

    /// A parked stream.
    pub fn fromParked(p: *Parked) Out {
        return .{ .parked = p };
    }
};

/// The fallback: the handler's task writes through the response's body
/// writer. `end` ends the body; `abort` makes the handler return
/// `error.ResponseAborted` (`state == .aborted`).
///
/// One state: `open` (writing), `ended` (body ended: begin false, write Gone,
/// end a no-op), `aborted` (as ended; abort always lands here).
pub const Fallback = struct {
    body: dusty.StreamingBodyWriter,
    state: State = .open,

    pub const State = enum { open, ended, aborted };

    pub fn out(self: *Fallback) Out {
        return .{ .fallback = self };
    }

    fn write(self: *Fallback, parts: []const []const u8) WriteError!void {
        if (self.state != .open) return error.Gone;
        const w = &self.body.interface;
        for (parts) |part| w.writeAll(part) catch return error.Gone;
        w.flush() catch return error.Gone;
    }

    fn end(self: *Fallback) void {
        if (self.state != .open) return;
        self.state = .ended;
        self.body.end() catch {};
    }
};
