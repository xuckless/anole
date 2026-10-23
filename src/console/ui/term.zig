//! The controlling terminal: raw mode, the alternate screen, size, and
//! restoring all of it on every way out (design 4.1). Windows is not
//! supported yet (D15).
const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const seq = @import("ctlseqs.zig");

pub const Size = struct { cols: u16, rows: u16 };

pub const OpenError = error{ NotATerminal, DumbTerminal, Unsupported, SystemResources };

// What `restoreNow` restores. Plain globals so it is async-signal-safe: no
// allocation, no locks, no pointers into a struct that could move.
var restore_fd: sys.fd_t = -1;
var restore_termios: std.c.termios = undefined;

/// Called (once) after the terminal is restored by `leave` or `restoreNow`;
/// the in-process console uses it to put fds 1 and 2 back (design 9.2).
pub var after_restore: ?*const fn () void = null;

pub const Terminal = struct {
    fd: sys.fd_t,
    saved: std.c.termios,
    /// false with NO_COLOR non-empty.
    color: bool,
    size: Size,
    entered: bool = false,

    /// Opens /dev/tty, checks TERM (unset or "dumb": DumbTerminal), saves the
    /// termios.
    pub fn open() OpenError!Terminal {
        if (!sys.supported) return error.Unsupported;
        const term = sys.getenv("TERM") orelse "";
        if (term.len == 0 or std.mem.eql(u8, term, "dumb")) return error.DumbTerminal;
        const fd = sys.openTty() orelse return error.NotATerminal;
        errdefer sys.close(fd);
        const saved = sys.getTermios(fd) orelse return error.NotATerminal;
        const no_color = sys.getenv("NO_COLOR") orelse "";
        var t: Terminal = .{ .fd = fd, .saved = saved, .color = no_color.len == 0, .size = .{ .cols = 80, .rows = 24 } };
        t.size = t.querySize();
        return t;
    }

    /// Raw mode (no echo, line editing, signals or flow control), alternate
    /// screen, hidden cursor, bracketed paste on. Registers itself as the
    /// process's restore target.
    pub fn enter(self: *Terminal) !void {
        if (self.entered) return;
        var raw = self.saved;
        sys.makeRaw(&raw);
        restore_termios = self.saved;
        restore_fd = self.fd;
        sys.setTermios(self.fd, &raw);
        self.entered = true;
        try sys.writeAll(self.fd, seq.smcup ++ seq.hide_cursor ++ seq.bp_set ++ seq.home ++ seq.erase_below_cursor);
    }

    /// Leaves the alternate screen, shows the cursor, bracketed paste off,
    /// restores the termios. Idempotent.
    pub fn leave(self: *Terminal) void {
        if (!self.entered) return;
        self.entered = false;
        restoreNow();
    }

    pub fn querySize(self: *Terminal) Size {
        if (sys.windowSize(self.fd)) |ws| return .{ .cols = ws.col, .rows = ws.row };
        return .{ .cols = 80, .rows = 24 };
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        try sys.writeAll(self.fd, bytes);
    }

    pub fn close(self: *Terminal) void {
        self.leave();
        sys.close(self.fd);
    }
};

/// The terminal to restore on exit or panic: set by `enter`, cleared by
/// `leave`. What the panic hook and the CLI's signal handlers call.
/// Async-signal-safe.
pub fn restoreNow() void {
    if (!sys.supported) return;
    const fd = restore_fd;
    if (fd < 0) return;
    restore_fd = -1;
    const msg = seq.sgr_reset ++ seq.bp_reset ++ seq.show_cursor ++ seq.rmcup;
    _ = sys.write(fd, msg) catch {};
    sys.setTermios(fd, &restore_termios);
    if (after_restore) |f| f();
}

test "term: restoreNow without an entered terminal does nothing" {
    restoreNow();
    restoreNow();
}
