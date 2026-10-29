//! The development hotkey (design 9.1): a thread reads stdin lines and opens
//! the console on `c`. Only where stdin and stderr are terminals, in
//! development, outside systemd, containers and CI, and never in tests.
const std = @import("std");
const ui = @import("anole_console_ui");
const os = @import("os.zig");

const sys = ui.sys;

/// Everything the decision looks at, so tests pass their own.
pub const Gate = struct {
    enabled: bool,
    development: bool,
    is_test: bool,
    stdin_tty: bool,
    stderr_tty: bool,
    term: ?[]const u8,
    invocation_id: bool,
    journal_stream: bool,
    ci: bool,
    container: bool,
    /// `console.keys = true` was set explicitly: the environment checks
    /// give way, the terminals do not.
    explicit: ?bool = null,
};

pub fn allowed(g: Gate) bool {
    if (!g.enabled or g.is_test or !os.supported) return false;
    if (g.explicit) |e| {
        if (!e) return false;
        return g.stdin_tty and g.stderr_tty;
    }
    if (!g.development) return false;
    if (!g.stdin_tty or !g.stderr_tty) return false;
    const t = g.term orelse return false;
    if (t.len == 0 or std.mem.eql(u8, t, "dumb")) return false;
    return !(g.invocation_id or g.journal_stream or g.ci or g.container);
}

pub const Opener = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) void,
    /// True while the console owns the terminal.
    is_open: *const fn () bool,
};

pub const KeyReader = struct {
    thread: ?std.Thread = null,
    wake: [2]sys.fd_t = .{ -1, -1 },
    opener: Opener,

    pub fn start(opener: Opener) !*KeyReader {
        const self = try std.heap.page_allocator.create(KeyReader);
        self.* = .{ .opener = opener };
        self.wake = try sys.pipe();
        self.thread = try std.Thread.spawn(.{}, main, .{self});
        return self;
    }

    pub fn stop(self: *KeyReader) void {
        _ = sys.write(self.wake[1], "x") catch {};
        if (self.thread) |t| t.join();
        sys.close(self.wake[0]);
        sys.close(self.wake[1]);
        std.heap.page_allocator.destroy(self);
    }
};

/// What a line typed in the terminal means.
pub const Command = enum { open, hint, ignore };

pub fn parseLine(line: []const u8) Command {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.eql(u8, t, "c") or std.mem.eql(u8, t, "C")) return .open;
    if (std.mem.eql(u8, t, "?") or std.mem.eql(u8, t, "help")) return .hint;
    return .ignore;
}

fn main(self: *KeyReader) void {
    var buf: [256]u8 = undefined;
    while (true) {
        if (self.opener.is_open()) {
            // The console reads the terminal itself; wait for it.
            var p = [1]sys.PollFd{.{ .fd = self.wake[0], .events = sys.POLLIN, .revents = 0 }};
            if (sys.poll(&p, 200) != 0) return;
            continue;
        }
        var fds = [2]sys.PollFd{
            .{ .fd = 0, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = self.wake[0], .events = sys.POLLIN, .revents = 0 },
        };
        _ = sys.poll(&fds, 500);
        if (fds[1].revents != 0) return;
        if (fds[0].revents == 0) continue;
        const n = sys.read(0, &buf) catch |e| switch (e) {
            error.WouldBlock => continue,
            else => return,
        };
        if (n == 0) return; // EOF on stdin
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            switch (parseLine(line)) {
                .open => self.opener.open(self.opener.ctx),
                .hint => std.log.scoped(.anole).info("press c + Enter for the live console", .{}),
                .ignore => {},
            }
        }
    }
}

test "keys_dev: c + Enter is offered only in development on two terminals outside systemd, CI and containers; an explicit setting still needs the terminals" {
    const base: Gate = .{ .enabled = true, .development = true, .is_test = false, .stdin_tty = true, .stderr_tty = true, .term = "xterm-256color", .invocation_id = false, .journal_stream = false, .ci = false, .container = false };
    if (!os.supported) {
        // Windows: the console is not available yet (docs/console.md), so
        // the hotkey is never offered, not even when set explicitly.
        try std.testing.expect(!allowed(base));
        var e = base;
        e.explicit = true;
        try std.testing.expect(!allowed(e));
        return;
    }
    try std.testing.expect(allowed(base));
    var g = base;
    g.development = false;
    try std.testing.expect(!allowed(g));
    g = base;
    g.is_test = true;
    try std.testing.expect(!allowed(g));
    g = base;
    g.stdin_tty = false;
    try std.testing.expect(!allowed(g));
    g = base;
    g.term = "dumb";
    try std.testing.expect(!allowed(g));
    g = base;
    g.term = null;
    try std.testing.expect(!allowed(g));
    for (0..4) |i| {
        g = base;
        switch (i) {
            0 => g.invocation_id = true,
            1 => g.journal_stream = true,
            2 => g.ci = true,
            else => g.container = true,
        }
        try std.testing.expect(!allowed(g));
    }
    g = base;
    g.development = false;
    g.explicit = true;
    try std.testing.expect(allowed(g));
    g.stderr_tty = false;
    try std.testing.expect(!allowed(g));
    g = base;
    g.explicit = false;
    try std.testing.expect(!allowed(g));
}

test "keys_dev: `c` opens the console, `help` or `?` gives the hint, other lines are ignored" {
    try std.testing.expect(parseLine("c\n") == .open);
    try std.testing.expect(parseLine(" C ") == .open);
    try std.testing.expect(parseLine("help") == .hint);
    try std.testing.expect(parseLine("?\n") == .hint);
    try std.testing.expect(parseLine("hello") == .ignore);
}
