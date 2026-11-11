// Anole code, written for the HTTP core after it left lalinsky/dusty; see
// LICENSE.dusty and THIRD_PARTY_NOTICES for the rest of src/http/core.

//! Parked streamed responses: a response whose head is out, whose handler
//! has returned, and that no task holds. Whatever task has something to
//! send writes to it in bursts, on the request's executor; between bursts
//! the stream costs a heap object, not a stack. Server-sent events use it
//! (`anole.sse`): a browser tab that is mostly idle holds a connection for
//! hours.
//!
//! The engines implement it: HTTP/1.1 here (`H1Parked`, on the `Adopter`
//! machinery a WebSocket with callbacks uses), HTTP/2 in server/h2_nghttp2.zig and
//! HTTP/3 in Anole's src/h3/server.zig (`H3Parked`).
//! `Response._park` writes the head and hands out the `Parked`.

const std = @import("std");
const builtin = @import("builtin");
const server_mod = @import("server.zig");
const Connection = server_mod.Connection;
const Adopter = server_mod.Adopter;
const Burst = server_mod.Burst;
const placement = @import("placement.zig");

/// A streamed response no task holds. Executor-local: every call runs on
/// the request's executor (a task placed there).
pub const Parked = struct {
    vtable: *const VTable,

    pub const Owner = struct {
        /// The peer went away (connection closed, stream reset). Called
        /// once, never during a burst (it is deferred to `endBurst`) and
        /// never after `end` or `abort`. Must not wait; the owner then
        /// calls `release` from a task, and nothing else.
        gone: *const fn (ctx: *anyopaque) void,
        ctx: *anyopaque,
    };

    pub const WriteError = error{ Gone, Canceled, SystemResources };

    pub const VTable = struct {
        begin: *const fn (p: *Parked) bool,
        write: *const fn (p: *Parked, parts: []const []const u8) WriteError!void,
        endBurst: *const fn (p: *Parked) void,
        end: *const fn (p: *Parked) void,
        abort: *const fn (p: *Parked) void,
        release: *const fn (p: *Parked) void,
    };

    /// Starts a burst: false when the stream is gone or ended (no burst).
    /// The calling task is noted, so a reset cancels it.
    pub fn begin(p: *Parked) bool {
        return p.vtable.begin(p);
    }
    /// Inside a burst: `parts` in order, in one transport write where the
    /// engine can (HTTP/1.1: one chunk). May wait for the peer.
    pub fn write(p: *Parked, parts: []const []const u8) WriteError!void {
        return p.vtable.write(p, parts);
    }
    /// Ends the burst; delivers a deferred `gone`.
    pub fn endBurst(p: *Parked) void {
        return p.vtable.endBurst(p);
    }
    /// Inside a burst, as its last call: the response's end after what was
    /// written (last chunk, END_STREAM); runs the middleware finishers.
    pub fn end(p: *Parked) void {
        return p.vtable.end(p);
    }
    /// Inside a burst, as its last call: reset or close now.
    pub fn abort(p: *Parked) void {
        return p.vtable.abort(p);
    }
    /// The owner is done (after `gone`, `end` or `abort`, outside a burst).
    /// The engine frees the stream once it is done with it too. The last
    /// call: `p` is invalid after it.
    pub fn release(p: *Parked) void {
        return p.vtable.release(p);
    }
};

/// Where a parked response is between its owner's bursts and the peer
/// leaving: whether a burst holds it, whether the owner was told `gone`
/// (or is to be, at the burst's end), whether it is over. The engines
/// (`H1Parked` here, `H3Parked` in src/h3/server.zig) hold one each and
/// call the transitions under the lock they already have; the
/// transitions only compute, and return what the caller must do.
///
///   idle --begin--> bursting --endBurst--> idle
///   idle --peerGone--> gone_told (tell the owner now)
///   bursting --peerGone--> bursting_gone --endBurst--> gone_told (tell then)
///   any --finish (end, abort)--> over
///
/// A pair not drawn changes nothing and tells nothing: `begin` outside
/// `idle` is refused, a second `peerGone` or one after `over` is dropped,
/// and `endBurst` after `over` delivers nothing (the owner ended the
/// response itself, so it is not told `gone` for it).
pub const Notice = enum {
    /// No burst; the peer is there (as far as the engine knows).
    idle,
    /// A burst holds the response.
    bursting,
    /// The peer left during the burst: the owner is told at `endBurst`.
    bursting_gone,
    /// The owner was told `gone` (once).
    gone_told,
    /// `end` or `abort` ran (or, on HTTP/1.1, a write failed with no
    /// notice pending): no more writes, no `gone`.
    over,

    /// Starts a burst: false (no burst) unless `idle`.
    pub fn begin(n: *Notice) bool {
        if (n.* != .idle) return false;
        n.* = .bursting;
        return true;
    }

    /// Ends the burst: true when the owner is to be told `gone` now.
    pub fn endBurst(n: *Notice) bool {
        switch (n.*) {
            .bursting => n.* = .idle,
            .bursting_gone => {
                n.* = .gone_told;
                return true;
            },
            .idle, .gone_told, .over => {},
        }
        return false;
    }

    pub const OnGone = enum {
        /// Nothing to do: told already, or over.
        none,
        /// A burst runs: the owner is told at its end (the engine may
        /// cancel the burst's task, whose write is for nobody now).
        deferred,
        /// Tell the owner now (outside the lock).
        tell,
    };

    /// The peer went away (connection closed, stream reset).
    pub fn peerGone(n: *Notice) OnGone {
        switch (n.*) {
            .idle => {
                n.* = .gone_told;
                return .tell;
            },
            .bursting => {
                n.* = .bursting_gone;
                return .deferred;
            },
            .bursting_gone, .gone_told, .over => return .none,
        }
    }

    /// `end` or `abort`: over from any state. True when it was over
    /// already (the end's work is not to be done twice).
    pub fn finish(n: *Notice) bool {
        const already = n.* == .over;
        n.* = .over;
        return already;
    }

    /// HTTP/1.1, a write failed (the connection is shut down): no more
    /// writes, as after `finish`, except that a notice pending from the
    /// peer leaving stays due at `endBurst`.
    pub fn writeFailed(n: *Notice) void {
        if (n.* != .bursting_gone) n.* = .over;
    }

    /// A burst holds the response.
    pub fn inBurst(n: Notice) bool {
        return n == .bursting or n == .bursting_gone;
    }
};

test "Notice: every (state, event) pair" {
    const S = Notice;
    const E = enum { begin, endBurst, peerGone, finish, writeFailed };
    const Row = struct {
        from: S,
        event: E,
        to: S,
        /// begin: started; endBurst: tell; finish: already. Unused otherwise.
        ret: bool = false,
        gone: S.OnGone = .none,
    };
    const rows = [_]Row{
        .{ .from = .idle, .event = .begin, .to = .bursting, .ret = true },
        .{ .from = .bursting, .event = .begin, .to = .bursting },
        .{ .from = .bursting_gone, .event = .begin, .to = .bursting_gone },
        .{ .from = .gone_told, .event = .begin, .to = .gone_told },
        .{ .from = .over, .event = .begin, .to = .over },

        .{ .from = .idle, .event = .endBurst, .to = .idle },
        .{ .from = .bursting, .event = .endBurst, .to = .idle },
        .{ .from = .bursting_gone, .event = .endBurst, .to = .gone_told, .ret = true },
        .{ .from = .gone_told, .event = .endBurst, .to = .gone_told },
        .{ .from = .over, .event = .endBurst, .to = .over },

        .{ .from = .idle, .event = .peerGone, .to = .gone_told, .gone = .tell },
        .{ .from = .bursting, .event = .peerGone, .to = .bursting_gone, .gone = .deferred },
        .{ .from = .bursting_gone, .event = .peerGone, .to = .bursting_gone },
        .{ .from = .gone_told, .event = .peerGone, .to = .gone_told },
        .{ .from = .over, .event = .peerGone, .to = .over },

        .{ .from = .idle, .event = .finish, .to = .over },
        .{ .from = .bursting, .event = .finish, .to = .over },
        .{ .from = .bursting_gone, .event = .finish, .to = .over },
        .{ .from = .gone_told, .event = .finish, .to = .over },
        .{ .from = .over, .event = .finish, .to = .over, .ret = true },

        .{ .from = .idle, .event = .writeFailed, .to = .over },
        .{ .from = .bursting, .event = .writeFailed, .to = .over },
        .{ .from = .bursting_gone, .event = .writeFailed, .to = .bursting_gone },
        .{ .from = .gone_told, .event = .writeFailed, .to = .over },
        .{ .from = .over, .event = .writeFailed, .to = .over },
    };
    // Every pair exactly once.
    for (std.enums.values(S)) |s| {
        for (std.enums.values(E)) |e| {
            var count: usize = 0;
            for (rows) |r| {
                if (r.from == s and r.event == e) count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
    }
    for (rows) |r| {
        var n = r.from;
        switch (r.event) {
            .begin => try std.testing.expectEqual(r.ret, n.begin()),
            .endBurst => try std.testing.expectEqual(r.ret, n.endBurst()),
            .peerGone => try std.testing.expectEqual(r.gone, n.peerGone()),
            .finish => try std.testing.expectEqual(r.ret, n.finish()),
            .writeFailed => n.writeFailed(),
        }
        try std.testing.expectEqual(r.to, n);
        try std.testing.expectEqual(r.to == .bursting or r.to == .bursting_gone, n.inBurst());
    }
}

/// Windows: a TCP shutdown does not end a receive already waiting on the
/// socket, so an abort also cancels the task that reads the connection.
const abort_cancels_reader = builtin.os.tag == .windows;

/// A parked HTTP/1.1 response: the connection is handed to the server as
/// an `Adopter`, so while it waits for the peer (who sends nothing on an
/// event stream) it is parked on its executor's shelf like an idle
/// WebSocket, and a task is started for it only when it has input (the
/// peer closing).
pub const H1Parked = struct {
    parked: Parked = .{ .vtable = &vtable },
    adopter: Adopter,
    connection: *Connection,
    gpa: std.mem.Allocator,
    io: std.Io,
    owner: Parked.Owner,
    chunked: bool,
    /// Serializes writes (and `end`, `abort`) with each other; never held
    /// by the reading side.
    write_mutex: std.Io.Mutex = .init,
    /// Guards the fields below. A spin lock: nothing under it waits.
    lock: std.atomic.Mutex = .unlocked,
    notice: Notice = .idle,
    burst_task: ?placement.Task = null,
    reader_task: ?placement.Task = null,
    /// The owner called `release`.
    released: std.Io.Event = .unset,
    owner_released: bool = false,

    const vtable: Parked.VTable = .{
        .begin = begin,
        .write = write,
        .endBurst = endBurst,
        .end = end,
        .abort = abort,
        .release = ownerRelease,
    };

    /// Each run's reader window, on its task's stack: an event stream's
    /// peer sends nothing, so this only has to take what arrives before it
    /// is thrown away.
    const window_len = 512;

    /// Called by `Response._park` once the head is out and the connection
    /// has been shrunk (`Connection.shrinkForUpgrade`, `finishUpgrade`).
    pub fn create(connection: *Connection, chunked: bool, owner: Parked.Owner) error{OutOfMemory}!*H1Parked {
        const gpa = connection.allocator;
        const self = try gpa.create(H1Parked);
        self.* = .{
            .adopter = .{ .serve = serve, .release = release },
            .connection = connection,
            .gpa = gpa,
            .io = connection.io,
            .owner = owner,
            .chunked = chunked,
        };
        return self;
    }

    fn fromParked(p: *Parked) *H1Parked {
        return @alignCast(@fieldParentPtr("parked", p));
    }

    fn lockFlags(self: *H1Parked) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn begin(p: *Parked) bool {
        const self = fromParked(p);
        self.lockFlags();
        defer self.lock.unlock();
        if (!self.notice.begin()) return false;
        self.burst_task = placement.currentTask(self.io);
        return true;
    }

    fn write(p: *Parked, parts: []const []const u8) Parked.WriteError!void {
        const self = fromParked(p);
        try self.writeLocked(parts);
    }

    fn writeLocked(self: *H1Parked, parts: []const []const u8) Parked.WriteError!void {
        self.write_mutex.lock(self.io) catch return error.Canceled;
        defer self.write_mutex.unlock(self.io);
        self.lockFlags();
        const over = self.notice == .over;
        self.lock.unlock();
        if (over) return error.Gone;
        const result = self.chunkOut(parts);
        result catch |err| {
            self.lockFlags();
            self.notice.writeFailed();
            self.lock.unlock();
            self.shutdownBoth();
            return err;
        };
    }

    /// One chunk (or raw bytes over HTTP/1.0), one flush.
    fn chunkOut(self: *H1Parked, parts: []const []const u8) Parked.WriteError!void {
        var total: usize = 0;
        for (parts) |part| total += part.len;
        if (total == 0) return;
        const t = self.connection.transport();
        const lender = t.write_buffers;
        if (lender) |l| l.take(l.context);
        defer if (lender) |l| l.give(l.context);
        const w = self.connection.writer;
        if (self.chunked) {
            var head: [20]u8 = undefined;
            const text = std.fmt.bufPrint(&head, "{x}\r\n", .{total}) catch unreachable;
            w.writeAll(text) catch return self.writeFailed();
        }
        for (parts) |part| w.writeAll(part) catch return self.writeFailed();
        if (self.chunked) w.writeAll("\r\n") catch return self.writeFailed();
        w.flush() catch return self.writeFailed();
    }

    fn writeFailed(self: *H1Parked) Parked.WriteError {
        if (self.connection.getWriteError()) |e| {
            if (e == error.Canceled) return error.Canceled;
        }
        return error.Gone;
    }

    fn endBurst(p: *Parked) void {
        const self = fromParked(p);
        self.lockFlags();
        self.burst_task = null;
        const deliver = self.notice.endBurst();
        self.lock.unlock();
        if (deliver) self.owner.gone(self.owner.ctx);
    }

    fn end(p: *Parked) void {
        const self = fromParked(p);
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.lockFlags();
        const already = self.notice.finish();
        self.burst_task = null;
        self.lock.unlock();
        if (already) return;
        // The terminator, a close_notify under TLS, and the end of both
        // directions: the browser sees a finished stream and reconnects
        // after its retry delay.
        const t = self.connection.transport();
        const lender = t.write_buffers;
        if (lender) |l| l.take(l.context);
        defer if (lender) |l| l.give(l.context);
        if (self.chunked) {
            self.connection.writer.writeAll("0\r\n\r\n") catch {};
        }
        self.connection.writer.flush() catch {};
        self.connection.closeNotify() catch {};
        self.shutdownBoth();
    }

    fn abort(p: *Parked) void {
        const self = fromParked(p);
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.lockFlags();
        _ = self.notice.finish();
        self.burst_task = null;
        self.lock.unlock();
        self.shutdownBoth();
    }

    fn shutdownBoth(self: *H1Parked) void {
        // Not a cancelation point: a cancel meant for the stuck write may
        // still be pending here, and is kept for later.
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.connection.stream.shutdown(self.io, .both) catch {};
        if (comptime abort_cancels_reader) {
            self.lockFlags();
            const task = self.reader_task;
            self.lock.unlock();
            if (task) |t| placement.cancelTask(t);
        }
    }

    fn ownerRelease(p: *Parked) void {
        const self = fromParked(p);
        self.lockFlags();
        self.owner_released = true;
        self.lock.unlock();
        self.released.set(self.io);
    }

    /// `gone`, once, now or after the running burst.
    fn deliverGone(self: *H1Parked) void {
        self.lockFlags();
        const what = self.notice.peerGone();
        const task = self.burst_task;
        self.lock.unlock();
        switch (what) {
            .none => {},
            // The write under way is for nobody.
            .deferred => if (task) |t| placement.cancelTask(t),
            .tell => self.owner.gone(self.owner.ctx),
        }
    }

    /// The core's runs: the first right after the handler returned, then
    /// one each time the parked connection has input. There is nothing to
    /// serve, only the peer to notice leaving.
    fn serve(a: *Adopter, b: *Burst) anyerror!Burst.End {
        const self: *H1Parked = @alignCast(@fieldParentPtr("adopter", a));
        const r = self.connection.reader;
        var window: [window_len]u8 = undefined;
        if (r.buffer.len == 0) {
            r.buffer = &window;
            r.seek = 0;
            r.end = 0;
        }
        defer {
            r.buffer = &.{};
            r.seek = 0;
            r.end = 0;
        }
        if (comptime abort_cancels_reader) {
            self.lockFlags();
            self.reader_task = placement.currentTask(self.io);
            self.lock.unlock();
        }
        while (true) {
            // A client sends nothing on an event stream: what comes is
            // thrown away.
            r.tossBuffered();
            self.lockFlags();
            const over = self.notice == .over;
            self.lock.unlock();
            if (over) return .close;
            const input = b.waitInput() catch {
                self.deliverGone();
                return .close;
            };
            if (input == .idle) return .park;
        }
    }

    /// The connection is closing (peer gone, deadline, the server's end,
    /// or after `end`): tells the owner if it is not told yet, and waits
    /// for its `release`, so nothing the owner still touches is freed.
    fn release(a: *Adopter) void {
        const self: *H1Parked = @alignCast(@fieldParentPtr("adopter", a));
        self.deliverGone();
        // A burst running: its write fails now (the socket is closing).
        self.shutdownBoth();
        self.lockFlags();
        const task = self.burst_task;
        self.lock.unlock();
        if (task) |t| placement.cancelTask(t);
        // `gone` was called (or the owner ended the stream itself): the
        // owner's end task releases. Uncancelable: the connection's task
        // is the one closing it.
        self.released.waitUncancelable(self.io);
        // A burst's last call (`endBurst`) may still be running on its
        // task: the flags are not touched after `release`.
        self.write_mutex.lockUncancelable(self.io);
        self.write_mutex.unlock(self.io);
        self.gpa.destroy(self);
    }
};
