//! The console's run loop, shared by attach mode and the in-process mode
//! (design 4.4): polls the terminal, the connection and a wake descriptor,
//! feeds keys and frames to `App`, and renders.
const std = @import("std");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const sys = @import("sys.zig");
const term_mod = @import("term.zig");
const keys = @import("keys.zig");
const screen = @import("screen.zig");
const app_mod = @import("app.zig");
const restart_plan = @import("restart_plan.zig");

pub const Mode = app_mod.Mode;

pub const Exit = enum {
    /// /quit, /exit or Ctrl-C when attached.
    quit,
    /// Esc with nothing to close, in-process.
    back_to_logs,
    /// Ctrl-C in-process: the terminal is restored and `on_interrupt` has run.
    interrupt,
    /// The app announced a restart (hand-off or exec), or a kill restart was
    /// asked for (see `RunOptions.kill`). The CLI reattaches.
    restarted,
    /// The wake descriptor fired, or the in-process server went away.
    server_gone,
};

/// What `/full-restart` decided when the app doesn't answer (or --kill):
/// the CLI kills the pid and waits for the supervisor or relaunches.
pub const KillRequest = struct { send_kill: bool, then: restart_plan.KillThen };

pub const RunOptions = struct {
    mode: Mode,
    term: *term_mod.Terminal,
    conn: *client.Conn,
    /// In-process: called on Ctrl-C after the terminal is restored.
    on_interrupt: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    /// Written (from another thread) to stop the loop; -1 for none.
    wake_fd: sys.fd_t = -1,
    wedge_timeout_ms: u32 = 5000,
    clock: *const fn () i64 = sys.monotonicMs,
    wall_clock: *const fn () i64 = sys.wallMs,
    /// The CLI fetched `launch_info` before running.
    have_launch_info: bool = false,
    /// Set when a kill restart is chosen; the run returns `.restarted`.
    kill: ?*KillRequest = null,
    /// A frame is drawn at most this often (ms) unless a key was pressed.
    min_frame_ms: i64 = 30,
};

pub fn monotonicMs() i64 {
    return sys.monotonicMs();
}

const KeySink = struct {
    app: *app_mod.App,
    effect: app_mod.Effect = .none,
    suspend_requested: bool = false,
    keys_seen: bool = false,

    pub fn onKey(self: *KeySink, k: keys.Key) void {
        self.keys_seen = true;
        if (self.effect != .none) return;
        switch (k) {
            .ctrl => |c| if (c == 'z') {
                self.suspend_requested = true;
                return;
            },
            else => {},
        }
        self.effect = self.app.key(k);
    }
};

pub fn run(gpa: std.mem.Allocator, opts: RunOptions) !Exit {
    const conn = opts.conn;
    const hello = conn.hello orelse return error.NoHello;
    const t = opts.term;

    var app = app_mod.App.init(gpa, opts.mode, hello);
    defer app.deinit();
    app.wedge_ms = opts.wedge_timeout_ms;
    app.have_launch_info = opts.have_launch_info;
    app.exec_supported = sys.supported;
    app.color = t.color;

    var size = t.querySize();
    var scr = try screen.Screen.init(gpa, size.cols, size.rows);
    defer scr.deinit(gpa);
    var rend = try screen.Renderer.init(gpa, size.cols, size.rows);
    defer rend.deinit();

    var parser = try gpa.create(keys.Parser);
    defer gpa.destroy(parser);
    parser.* = .{};

    try t.enter();
    defer t.leave();

    var frame_arena = std.heap.ArenaAllocator.init(gpa);
    defer frame_arena.deinit();

    var now = opts.clock();
    app.heard(now);
    app.tick(now, opts.wall_clock());
    app.start();
    _ = try sendOutbox(&app, conn);

    var full = true;
    var last_render: i64 = -1_000_000;
    var last_size_check = now;
    var last_ping = now;
    var dirty = true;
    var esc_pending = false;
    var exit: ?Exit = null;

    while (exit == null) {
        now = opts.clock();
        // Render when something changed, at a bounded rate.
        if (dirty and now - last_render >= opts.min_frame_ms) {
            try renderFrame(&app, &scr, &rend, t, full);
            full = false;
            dirty = false;
            last_render = now;
        }

        var fds: [4]sys.PollFd = undefined;
        var n: usize = 0;
        fds[n] = .{ .fd = t.read_fd, .events = sys.POLLIN, .revents = 0 };
        n += 1;
        const conn_idx = n;
        fds[n] = .{ .fd = conn.in_fd, .events = sys.POLLIN, .revents = 0 };
        n += 1;
        var wake_idx: ?usize = null;
        if (opts.wake_fd >= 0) {
            wake_idx = n;
            fds[n] = .{ .fd = opts.wake_fd, .events = sys.POLLIN, .revents = 0 };
            n += 1;
        }
        var out_idx: ?usize = null;
        if (conn.wantsWrite()) {
            out_idx = n;
            fds[n] = .{ .fd = conn.out_fd, .events = sys.POLLOUT, .revents = 0 };
            n += 1;
        }
        var timeout: i64 = 250;
        if (esc_pending) timeout = 25;
        if (dirty) timeout = @min(timeout, @max(opts.min_frame_ms - (now - last_render), 1));
        const ready = sys.poll(fds[0..n], @intCast(timeout));
        now = opts.clock();
        const wall = opts.wall_clock();

        var sink: KeySink = .{ .app = &app };
        if (ready == 0) {
            if (esc_pending) {
                parser.flushPending(&sink);
                esc_pending = false;
            }
        } else {
            if (fds[0].revents & (sys.POLLIN | sys.POLLHUP) != 0) {
                var buf: [1024]u8 = undefined;
                const got = sys.read(t.read_fd, &buf) catch 0;
                if (got == 0 and fds[0].revents & sys.POLLHUP != 0) {
                    exit = .quit;
                } else if (got > 0) {
                    parser.feed(buf[0..got], &sink);
                    esc_pending = parser.state == .esc;
                }
            }
            if (fds[conn_idx].revents & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) != 0) {
                const alive = conn.fill() catch false;
                app.heard(now);
                _ = frame_arena.reset(.retain_capacity);
                while (conn.nextFrame(frame_arena.allocator()) catch null) |f| app.frame(f);
                if (!alive) {
                    app.connectionClosed();
                    if (opts.mode == .in_process and exit == null) exit = if (app.restarting != null) .restarted else .server_gone;
                }
                dirty = true;
            }
            if (wake_idx) |i| if (fds[i].revents & sys.POLLIN != 0) {
                exit = .server_gone;
            };
            if (out_idx) |i| if (fds[i].revents & sys.POLLOUT != 0) {
                conn.flush() catch {};
            };
        }

        if (sink.keys_seen) {
            dirty = true;
            last_render = -1_000_000; // a key is answered at once
        }
        switch (sink.effect) {
            .none => {},
            .quit => exit = .quit,
            .back => exit = .back_to_logs,
            .interrupt => exit = .interrupt,
        }
        if (sink.suspend_requested and exit == null) {
            t.leave();
            sys.raise(sys.Sig.tstp);
            try t.enter();
            full = true;
            dirty = true;
        }
        if (app.want_full) {
            app.want_full = false;
            full = true;
            dirty = true;
        }

        // Frames the app queued (including those from the new key).
        app.tick(now, wall);
        if (try sendOutbox(&app, conn)) |kr| {
            if (opts.kill) |dst| dst.* = kr;
            if (exit == null) exit = .restarted;
        }
        conn.flush() catch {};

        if (app.restarting != null and exit == null) exit = .restarted;

        // Resize: polled, no SIGWINCH handler (D17).
        if (now - last_size_check >= 250) {
            last_size_check = now;
            const ns = t.querySize();
            if (ns.cols != size.cols or ns.rows != size.rows) {
                size = ns;
                try scr.resize(gpa, ns.cols, ns.rows);
                full = true;
                dirty = true;
            }
        }
        // Keep the link alive and notice a silent server.
        if (now - last_ping >= 1000 and !app.server_gone) {
            last_ping = now;
            _ = conn.ping() catch {};
        }
        if (app.link() != .live or now - last_render >= 1000) dirty = true;
        if (sink.keys_seen or ready > 0) dirty = true;
    }

    // Restore the terminal before anything else runs.
    t.leave();
    const result = exit.?;
    if (result == .interrupt) {
        if (opts.on_interrupt) |f| f(opts.ctx);
    }
    return result;
}

fn sendOutbox(app: *app_mod.App, conn: *client.Conn) !?KillRequest {
    var kill: ?KillRequest = null;
    const out = app.takeOutgoing();
    for (out) |o| {
        const id: u32 = switch (o) {
            .ping => try conn.ping(),
            .snapshot => |v| try conn.snapshot(v),
            .subscribe_logs => |f| try conn.subscribeLogs(f, 500),
            .subscribe_stats => try conn.subscribeStats(1000),
            .subscribe_errors => try conn.subscribeErrors(),
            .unsubscribe => |s| try conn.unsubscribe(s),
            .op => |op| try conn.op(op.name, op.confirm),
            .full_restart_kill => |k| {
                kill = .{ .send_kill = k.send_kill, .then = k.then };
                continue;
            },
        };
        app.registerSent(id, o);
    }
    app.clearOutgoing();
    return kill;
}

fn renderFrame(app: *app_mod.App, scr: *screen.Screen, rend: *screen.Renderer, t: *term_mod.Terminal, full: bool) !void {
    app.draw(scr);
    var aw: std.Io.Writer.Allocating = .init(app.gpa);
    defer aw.deinit();
    try rend.render(scr, t.color, full, &aw.writer);
    try t.write(aw.written());
}

fn fixedNow() i64 {
    return 1000;
}

test "run: a scripted session over pipes quits on /quit" {
    // The console's terminal side is not on Windows yet (design D15): no pipes, no clock.
    if (!sys.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const tty_in = try sys.pipe();
    const tty_out = try sys.pipe();
    const to_client = try sys.pipe();
    const to_server = try sys.pipe();
    defer for ([_]sys.fd_t{ tty_in[0], tty_in[1], tty_out[0], tty_out[1], to_client[0], to_client[1], to_server[0], to_server[1] }) |fd| sys.close(fd);

    try sys.writeAll(to_client[1], "{\"t\":\"hello\",\"proto\":1,\"app\":{\"name\":\"api\",\"pid\":9,\"environment\":\"development\"},\"allow\":{\"reload\":true}}\n");
    var conn = client.Conn.init(gpa, to_client[0], to_server[1]);
    defer conn.deinit();
    try conn.handshake("test", 200, sys.monotonicMs);

    try sys.writeAll(tty_in[1], "/quit\r");
    var t = term_mod.Terminal.fromFds(tty_in[0], tty_out[1], .{ .cols = 80, .rows = 24 }, false);
    const exit = try run(gpa, .{ .mode = .attach, .term = &t, .conn = &conn, .clock = sys.monotonicMs });
    try std.testing.expectEqual(Exit.quit, exit);

    // The terminal got the alternate screen, a frame with the app's name, and was restored.
    var buf: [16 * 1024]u8 = undefined;
    var p = [1]sys.PollFd{.{ .fd = tty_out[0], .events = sys.POLLIN, .revents = 0 }};
    try std.testing.expect(sys.poll(&p, 100) == 1);
    const n = try sys.read(tty_out[0], &buf);
    const out = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "api") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[?1049l"));

    // And it asked the server for its streams.
    var rbuf: [4096]u8 = undefined;
    var q = [1]sys.PollFd{.{ .fd = to_server[0], .events = sys.POLLIN, .revents = 0 }};
    try std.testing.expect(sys.poll(&q, 100) == 1);
    const m = try sys.read(to_server[0], &rbuf);
    try std.testing.expect(std.mem.indexOf(u8, rbuf[0..m], "\"stream\":\"logs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rbuf[0..m], "\"stream\":\"stats\"") != null);
}
