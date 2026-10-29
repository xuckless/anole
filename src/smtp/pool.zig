//! The connections of one executor: idle sessions, how many are open, and
//! the closing of idle ones (after `idle_timeout`, by `closeIdle`, at the
//! drain). Taking and giving back are `Client`'s, which has the options
//! and the observer; this is the shared state and the parts that only
//! touch it.
const std = @import("std");
const safety = @import("anole_safety");
const db = @import("../db/root.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

/// The pool of one executor.
pub const Pool = struct {
    mutex: safety.Mutex(.leaf) = .init,
    /// Signalled when a session goes back, or a place frees up.
    returned: safety.Condition = .init,
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
    /// Takes up to 16 per lock section and closes them after the unlock
    /// (SAFETY.md L2, L3); allocates nothing. Returns how many.
    pub fn closeIdle(self: *Pool, io: std.Io, observer: *const db.Observer, limit: ?std.Io.Duration) usize {
        const batch_len = 16;
        var total: usize = 0;
        while (true) {
            var batch: [batch_len]*Session = undefined;
            var n: usize = 0;
            self.mutex.lockUncancelable(io);
            var i: usize = 0;
            while (i < self.idle_len and n < batch_len) {
                const s = self.idle[i];
                const old = if (limit) |l| s.idle_since.durationTo(.now(io, .awake)).raw.nanoseconds > l.nanoseconds else true;
                if (old) {
                    // Keep the order of the rest: the youngest stay at the end.
                    std.mem.copyForwards(*Session, self.idle[i .. self.idle_len - 1], self.idle[i + 1 .. self.idle_len]);
                    self.idle_len -= 1;
                    self.open -= 1;
                    batch[n] = s;
                    n += 1;
                } else i += 1;
            }
            if (n > 0) self.returned.broadcast(io);
            self.mutex.unlock(io);
            for (batch[0..n]) |s| {
                s.close(true);
                observer.connections(-1, 0);
            }
            total += n;
            if (n < batch_len) return total;
        }
    }

    /// Sessions open (idle, in use or being opened), read under the lock:
    /// for the console.
    pub fn openCount(self: *Pool, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.open;
    }

    /// How many sessions are idle now.
    pub fn idleCount(self: *Pool, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.idle_len;
    }
};
