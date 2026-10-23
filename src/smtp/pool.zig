//! The connections of one executor: idle sessions, how many are open, and
//! the closing of idle ones (after `idle_timeout`, by `closeIdle`, at the
//! drain). Taking and giving back are `Client`'s, which has the options
//! and the observer; this is the shared state and the parts that only
//! touch it.
const std = @import("std");
const db = @import("../db/root.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// The pool of one executor.
pub const Pool = struct {
    mutex: std.Io.Mutex = .init,
    /// Signalled when a session goes back, or a place frees up.
    returned: std.Io.Condition = .init,
    /// `max` slots; the first `idle_len` hold idle sessions.
    idle: []*Session,
    idle_len: usize = 0,
    /// Idle and in use (and being opened).
    open: usize = 0,
    max: usize,

    pub fn init(slots: []*Session, max: usize) Pool {
        return .{ .idle = slots, .max = max };
    }

    /// Closes the idle sessions that have been idle longer than `limit`
    /// (all of them when null): QUIT, close, and their places freed.
    /// Returns how many.
    pub fn closeIdle(self: *Pool, gpa: std.mem.Allocator, io: std.Io, observer: *const db.Observer, limit: ?std.Io.Duration) usize {
        var victims: std.ArrayList(*Session) = .empty;
        defer victims.deinit(gpa);
        self.mutex.lockUncancelable(io);
        var i: usize = 0;
        while (i < self.idle_len) {
            const s = self.idle[i];
            const old = if (limit) |l| s.idle_since.durationTo(.now(io, .awake)).raw.nanoseconds > l.nanoseconds else true;
            if (old) {
                // Keep the order of the rest: the youngest stay at the end.
                std.mem.copyForwards(*Session, self.idle[i .. self.idle_len - 1], self.idle[i + 1 .. self.idle_len]);
                self.idle_len -= 1;
                self.open -= 1;
                victims.append(gpa, s) catch {
                    // Out of memory: close it here, under the lock.
                    s.close(true);
                    observer.connections(-1, 0);
                    continue;
                };
            } else i += 1;
        }
        self.returned.broadcast(io);
        self.mutex.unlock(io);
        for (victims.items) |s| {
            s.close(true);
            observer.connections(-1, 0);
        }
        return victims.items.len;
    }

    /// How many sessions are idle now.
    pub fn idleCount(self: *Pool, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.idle_len;
    }
};
