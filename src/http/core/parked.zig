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
//! machinery a WebSocket with callbacks uses), HTTP/2 in server/h2.zig and
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
    /// Guards the flags below. A spin lock: nothing under it waits.
    lock: std.atomic.Mutex = .unlocked,
    burst: bool = false,
    burst_task: ?placement.Task = null,
    reader_task: ?placement.Task = null,
    gone_pending: bool = false,
    gone_sent: bool = false,
    /// `end` or `abort` ran: no more writes.
    over: bool = false,
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
        if (self.over or self.gone_sent or self.gone_pending) return false;
        self.burst = true;
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
        const over = self.over;
        self.lock.unlock();
        if (over) return error.Gone;
        const result = self.chunkOut(parts);
        result catch |err| {
            self.lockFlags();
            self.over = true;
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
        self.burst = false;
        self.burst_task = null;
        const deliver = self.gone_pending and !self.gone_sent;
        if (deliver) {
            self.gone_pending = false;
            self.gone_sent = true;
        }
        self.lock.unlock();
        if (deliver) self.owner.gone(self.owner.ctx);
    }

    fn end(p: *Parked) void {
        const self = fromParked(p);
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        self.lockFlags();
        const already = self.over;
        self.over = true;
        self.burst = false;
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
        self.over = true;
        self.burst = false;
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
        if (self.gone_sent or self.over) {
            self.lock.unlock();
            return;
        }
        if (self.burst) {
            self.gone_pending = true;
            const task = self.burst_task;
            self.lock.unlock();
            // The write under way is for nobody.
            if (task) |t| placement.cancelTask(t);
            return;
        }
        self.gone_sent = true;
        self.lock.unlock();
        self.owner.gone(self.owner.ctx);
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
            const over = self.over;
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
