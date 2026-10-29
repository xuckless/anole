//! The in-process console (design 9.2): the TUI as a client of the same
//! protocol over a socketpair, on its own OS thread with blocking I/O. While
//! it is open, descriptors 1 and 2 are captured into two pipes whose lines
//! become `/logs` records (scopes `stdout` and `stderr`); closing restores
//! them. The terminal itself is /dev/tty.
const std = @import("std");
const ui = @import("anole_console_ui");
const logging = @import("anole_log");
const os = @import("os.zig");
const logring = @import("logring.zig");
const service_mod = @import("service.zig");

const sys = ui.sys;

pub const CloseReason = enum(u32) { quit = 0, interrupt = 1, restarting = 2 };

pub const OpenError = error{ AlreadyOpen, NotRunning, Busy, SystemResources, OutOfMemory } || ui.term.OpenError;

pub const Closed = *const fn (ctx: ?*anyopaque, reason: CloseReason) void;

/// The one in-process console of the process (there is one terminal).
var active: std.atomic.Value(?*InProcess) = .init(null);

const Capture = struct {
    pipes: [2][2]sys.fd_t = .{ .{ -1, -1 }, .{ -1, -1 } },
    saved: [2]sys.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,
    stop: [2]sys.fd_t = .{ -1, -1 },
    restored: std.atomic.Value(bool) = .init(true),
};

pub const InProcess = struct {
    gpa: std.mem.Allocator,
    service: *service_mod.Service,
    logs: ?*logring.LogRing,
    on_closed: ?Closed,
    ctx: ?*anyopaque,
    thread: ?std.Thread = null,
    wake: [2]sys.fd_t = .{ -1, -1 },
    term: ui.term.Terminal = undefined,
    client_fd: sys.fd_t = -1,
    capture: Capture = .{},
    finished: std.atomic.Value(bool) = .init(false),
    interrupted: bool = false,
    reason: CloseReason = .quit,
    server_gone: bool = false,
};

pub fn isOpen() bool {
    return active.load(.acquire) != null;
}

/// Opens the console in this process's terminal. The caller keeps `svc`
/// alive until `close` returned.
pub fn open(gpa: std.mem.Allocator, svc: *service_mod.Service, logs: ?*logring.LogRing, on_closed: ?Closed, ctx: ?*anyopaque) OpenError!void {
    if (comptime !os.supported) return error.Unsupported;
    if (active.load(.acquire) != null) return error.AlreadyOpen;
    reapRetired();
    const self = try gpa.create(InProcess);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .service = svc, .logs = logs, .on_closed = on_closed, .ctx = ctx };
    if (active.cmpxchgStrong(null, self, .acq_rel, .acquire) != null) return error.AlreadyOpen;
    errdefer active.store(null, .release);

    self.term = try ui.term.Terminal.open();
    errdefer self.term.close();
    const pair = os.socketpair() catch return error.SystemResources;
    errdefer sys.close(pair[1]);
    self.service.adopt(pair[0], true) catch |e| {
        sys.close(pair[1]);
        return switch (e) {
            error.Busy => error.Busy,
            else => error.SystemResources,
        };
    };
    self.client_fd = pair[1];
    self.wake = sys.pipe() catch return error.SystemResources;
    try startCapture(self);
    self.thread = std.Thread.spawn(.{}, tuiMain, .{self}) catch {
        endCapture(self);
        return error.SystemResources;
    };
}

/// Idempotent; blocks until the terminal and the descriptors are back. Not
/// from the console's own thread.
pub fn close() void {
    if (active.load(.acquire)) |self| {
        _ = sys.write(self.wake[1], "x") catch {};
        // The thread ends after restoring everything.
        while (active.load(.acquire) != null) {
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 5);
        }
    }
    reapRetired();
}

/// The console that ended, waiting to be joined and freed.
var retired: std.atomic.Value(?*InProcess) = .init(null);

fn reapRetired() void {
    const old = retired.swap(null, .acq_rel) orelse return;
    // `finished` is its last act before the thread returns.
    while (!old.finished.load(.acquire)) {
        var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = sys.poll(&p, 1);
    }
    if (old.thread) |t| t.join();
    old.gpa.destroy(old);
}

fn tuiMain(self: *InProcess) void {
    run(self);
    cleanup(self);
}

fn run(self: *InProcess) void {
    const gpa = self.gpa;
    var conn = ui.client.Conn.init(gpa, self.client_fd, self.client_fd);
    defer conn.deinit();
    conn.handshake("anole in-process", 5000, sys.monotonicMs) catch return;
    const exit = ui.run.run(gpa, .{
        .mode = .in_process,
        .term = &self.term,
        .conn = &conn,
        .wake_fd = self.wake[0],
        .on_interrupt = onInterrupt,
        .ctx = self,
    }) catch .server_gone;
    switch (exit) {
        .quit, .back_to_logs => self.reason = .quit,
        .interrupt => {
            self.interrupted = true;
            self.reason = .interrupt;
        },
        .restarted => self.reason = .restarting,
        .server_gone => self.server_gone = true,
    }
    conn.close();
    self.client_fd = -1;
}

fn onInterrupt(ctx: ?*anyopaque) void {
    const self: *InProcess = @ptrCast(@alignCast(ctx.?));
    self.interrupted = true;
}

fn cleanup(self: *InProcess) void {
    // The terminal first, so what follows is written to the real screen.
    self.term.close();
    endCapture(self);
    if (self.client_fd >= 0) sys.close(self.client_fd);
    sys.close(self.wake[0]);
    sys.close(self.wake[1]);
    const cb = self.on_closed;
    const ctx = self.ctx;
    const reason = self.reason;
    const interrupted = self.interrupted;
    active.store(null, .release);
    if (cb) |f| f(ctx, reason);
    if (interrupted) _ = sys.kill(sys.getpid(), sys.Sig.int);
    // Joined and freed by the next open or close.
    if (retired.swap(self, .acq_rel)) |old| {
        // Two consoles ended without a reap in between: the older is done.
        while (!old.finished.load(.acquire)) {
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 1);
        }
        if (old.thread) |t| t.join();
        old.gpa.destroy(old);
    }
    self.finished.store(true, .release);
}

// ------------------------------------------------------------- capture

fn startCapture(self: *InProcess) OpenError!void {
    const cap = &self.capture;
    for (0..2) |i| cap.pipes[i] = sys.pipe() catch return error.SystemResources;
    cap.stop = sys.pipe() catch return error.SystemResources;
    sys.setNonblock(cap.pipes[0][0]);
    sys.setNonblock(cap.pipes[1][0]);
    cap.saved[0] = os.dup(1);
    cap.saved[1] = os.dup(2);
    cap.restored.store(false, .release);
    ui.term.after_restore = restoreFdsHook;
    capture_owner.store(self, .release);
    os.dup2(cap.pipes[0][1], 1);
    os.dup2(cap.pipes[1][1], 2);
    logging.suppressStderr(true);
    cap.thread = std.Thread.spawn(.{}, captureMain, .{self}) catch return error.SystemResources;
}

var capture_owner: std.atomic.Value(?*InProcess) = .init(null);

/// Puts descriptors 1 and 2 back (once). Also the terminal-restore hook the
/// panic path reaches.
pub fn restoreFds(self: *InProcess) void {
    const cap = &self.capture;
    if (cap.restored.swap(true, .acq_rel)) return;
    if (cap.saved[0] >= 0) os.dup2(cap.saved[0], 1);
    if (cap.saved[1] >= 0) os.dup2(cap.saved[1], 2);
    logging.suppressStderr(false);
}

fn restoreFdsHook() void {
    if (capture_owner.load(.acquire)) |s| restoreFds(s);
}

fn endCapture(self: *InProcess) void {
    const cap = &self.capture;
    restoreFds(self);
    if (cap.thread) |t| {
        _ = sys.write(cap.stop[1], "x") catch {};
        t.join();
        cap.thread = null;
    }
    ui.term.after_restore = null;
    capture_owner.store(null, .release);
    for (cap.saved) |fd| if (fd >= 0) sys.close(fd);
    for (cap.pipes) |p| for (p) |fd| if (fd >= 0) sys.close(fd);
    for (cap.stop) |fd| if (fd >= 0) sys.close(fd);
    cap.* = .{};
}

fn captureMain(self: *InProcess) void {
    const cap = &self.capture;
    var lines: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&lines) |*l| l.deinit(self.gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds = [3]sys.PollFd{
            .{ .fd = cap.pipes[0][0], .events = sys.POLLIN, .revents = 0 },
            .{ .fd = cap.pipes[1][0], .events = sys.POLLIN, .revents = 0 },
            .{ .fd = cap.stop[0], .events = sys.POLLIN, .revents = 0 },
        };
        _ = sys.poll(&fds, 500);
        const stop = fds[2].revents != 0;
        for (0..2) |i| {
            while (true) {
                const n = sys.read(cap.pipes[i][0], &buf) catch break;
                if (n == 0) break;
                feedLines(self, &lines[i], if (i == 0) "stdout" else "stderr", buf[0..n]);
            }
        }
        if (stop) break;
    }
    for (0..2) |i| if (lines[i].items.len > 0) emitLine(self, if (i == 0) "stdout" else "stderr", lines[i].items);
}

fn feedLines(self: *InProcess, acc: *std.ArrayList(u8), scope: []const u8, bytes: []const u8) void {
    var rest = bytes;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        acc.appendSlice(self.gpa, rest[0..nl]) catch {};
        emitLine(self, scope, acc.items);
        acc.clearRetainingCapacity();
        rest = rest[nl + 1 ..];
    }
    acc.appendSlice(self.gpa, rest) catch {};
    if (acc.items.len > logring.max_text) {
        emitLine(self, scope, acc.items);
        acc.clearRetainingCapacity();
    }
}

fn emitLine(self: *InProcess, scope: []const u8, line: []const u8) void {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0) return;
    if (self.logs) |lr| lr.push(.info, scope, "", "", false, trimmed);
}

// ------------------------------------------------------------------ tests

test "inprocess: captured output becomes one log record per line, CR trimmed, empty lines skipped, a line over the log limit cut" {
    const gpa = std.testing.allocator;
    var lr = logring.LogRing.init(gpa, 1024 * 1024);
    defer lr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(gpa);
    defer arena_s.deinit();
    var cur: logring.Cursors = undefined;
    lr.attachAtEnd(&cur);
    // The capture thread's line splitter (feedLines/emitLine), fed the way
    // captureMain feeds it: reads that split lines anywhere.
    var self: InProcess = .{ .gpa = gpa, .service = undefined, .logs = &lr, .on_closed = null, .ctx = null };
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    feedLines(&self, &acc, "stdout", "one\r\ntw");
    feedLines(&self, &acc, "stdout", "o\n\n\r\n");
    const long = try gpa.alloc(u8, logring.max_text + 10);
    defer gpa.free(long);
    @memset(long, 'x');
    feedLines(&self, &acc, "stderr", long);
    try std.testing.expectEqual(@as(usize, 0), acc.items.len);

    var out: std.ArrayList(logring.Rec) = .empty;
    var dropped: u64 = 0;
    try lr.readNew(arena_s.allocator(), &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("stdout", out.items[0].scope);
    try std.testing.expectEqualStrings("one", out.items[0].text);
    try std.testing.expectEqualStrings("two", out.items[1].text);
    try std.testing.expectEqualStrings("stderr", out.items[2].scope);
    try std.testing.expectEqual(@as(usize, logring.max_text), out.items[2].text.len);
}
