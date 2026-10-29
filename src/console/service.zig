//! The control socket and its clients (design section 5). One acceptor
//! thread and one thread per client, all with plain blocking POSIX I/O and a
//! 100 ms tick (deviation from the design's zio tasks: the console keeps
//! answering while every executor is busy or wedged, and never touches the
//! scheduler). Producers never talk to a client: logs and 5xx answers sit in
//! rings that each client reads at its own pace, and a client that stops
//! reading blocks only its own thread.
const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("dusty");
const ui = @import("anole_console_ui");
const logging = @import("anole_log");
const os = @import("os.zig");
const stats_mod = @import("stats.zig");
const logring = @import("logring.zig");
const procinfo = @import("procinfo.zig");
const reexec = @import("reexec.zig");
const safety = @import("anole_safety");

const protocol = ui.protocol;
const sys = ui.sys;

pub const tick_ms = 100;
pub const max_logs_per_tick = 2000;
pub const max_log_bytes_per_tick = 512 * 1024;
pub const stall_close_ms = 30_000;

pub const TaskStats = struct { tasks: u64, run_queue: u64 };

pub const RouteMeta = struct { method: []const u8, pattern: []const u8 };

pub const ReloadResult = union(enum) {
    ok: u32,
    unavailable: []const u8,
    failed: []const u8,
};

/// What the console asks of the server it is part of. All functions may be
/// called from console threads and must be safe from any thread.
pub const Host = struct {
    ctx: *anyopaque,
    executors: u32,
    reload: *const fn (ctx: *anyopaque, buf: []u8) ReloadResult,
    stop: *const fn (ctx: *anyopaque) void,
    /// Asks `run` for the zero-downtime hand-off; the outcome comes back
    /// through `Service.restartFinished`.
    restart: ?*const fn (ctx: *anyopaque) void = null,
    route_meta: ?*const fn (ctx: *anyopaque, index: u32) ?RouteMeta = null,
    /// Each writes the JSON value of its snapshot (an object or an array).
    listeners: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    databases: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    ws: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    h3: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    routes: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    /// Plain text (the `/config` view).
    config: ?*const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void = null,
    task_stats: ?*const fn (ctx: *anyopaque, executor: usize) ?TaskStats = null,
    stack_committed: ?*const fn (ctx: *anyopaque) u64 = null,
    /// Before the process execs itself: the in-process console restores the
    /// terminal and the captured descriptors.
    before_exec: ?*const fn (ctx: *anyopaque) void = null,
};

/// The static facts of the hello (design 5.3).
pub const Info = struct {
    anole: []const u8,
    name: []const u8,
    started_iso: []const u8,
    host: []const u8,
    environment: []const u8,
    deployment: []const u8,
    build: []const u8,
    executors: u32,
    runtime: []const u8,
    allow: protocol.Allow,
    why_not: protocol.WhyNot,
    supervisor: protocol.Supervisor,
    features: []const []const u8,
    started_ms: i64,
};

pub const Metric = struct { name: []const u8, value: f64, unit: []const u8 };

/// A language metric as the service keeps it: copied into fixed room, so
/// that `setMetrics` and `/runtime` copy it under the service's spin lock
/// without allocating (SAFETY.md L5).
const Stored = struct {
    name: [max_metric_name]u8 = @splat(0),
    name_len: u8 = 0,
    unit: [max_metric_unit]u8 = @splat(0),
    unit_len: u8 = 0,
    value: f64 = 0,
};

/// A language metric's name is 1 to 48 bytes (anole.h, `anole_console_report`).
pub const max_metric_name = 48;
pub const max_metric_unit = 16;
pub const max_metrics = 32;

/// Clients the service tracks at once: the ones attached and the ones whose
/// thread ended and is not joined yet (`reap`). A fixed list, so that adding
/// one under the spin lock never allocates.
const max_tracked = 2 * protocol.max_clients + 8;

pub const Options = struct {
    read_only: bool = false,
    /// The effective permission for /restart and /full-restart.
    allow_restart: bool = false,
    restart_wait_ms: u32 = 15_000,
};

const Client = struct {
    service: *Service,
    fd: sys.fd_t,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    in_process: bool = false,
    /// Broadcast sequence this client has flushed.
    seen_broadcast: std.atomic.Value(u32) = .init(0),

    reader: protocol.LineReader = .init(protocol.max_client_line),
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    hello_done: bool = false,

    // subscriptions
    next_sub: u32 = 1,
    logs: ?LogSub = null,
    stats: ?StatsSub = null,
    errors: ?ErrSub = null,
};

const LogSub = struct {
    sub: u32,
    filter: logring.Filter,
    /// Owned copies of the filter's strings.
    strings: [][]u8,
    cursors: logring.Cursors,
};
const StatsSub = struct { sub: u32, interval_ms: u32, next_due_ms: i64, seq: u64 = 0 };
const ErrSub = struct { sub: u32, last_seq: u64 };

pub const Service = struct {
    gpa: std.mem.Allocator,
    host: Host,
    info: Info,
    opts: Options,
    stats: *stats_mod.Stats,
    logs: ?*logring.LogRing,
    launch: ?*const reexec.LaunchInfo,

    listener: sys.fd_t = -1,
    path: ?[]const u8 = null,
    acceptor: ?std.Thread = null,
    stop_pipe: [2]sys.fd_t = .{ -1, -1 },
    stopping: std.atomic.Value(bool) = .init(false),
    /// `stop` ran (the owner's thread only).
    stopped: bool = false,
    bye_reason: std.atomic.Value(u8) = .init(0),

    /// Over `clients`, the broadcast line and the language metrics; held
    /// for bounded copies only, never across an allocation (SAFETY.md L5).
    lock: safety.SpinLock(.leaf) = .init,
    /// In `clients_buf` (set by `init`).
    clients: std.ArrayList(*Client) = .empty,
    // SAFETY: only `clients.items` is read; `init` points `clients` here.
    clients_buf: [max_tracked]*Client = undefined,
    attached: std.atomic.Value(u32) = .init(0),
    euid: u32,

    // broadcast
    broadcast_seq: std.atomic.Value(u32) = .init(0),
    broadcast_buf: [512]u8 = undefined,
    broadcast_len: usize = 0,

    // restart handshake with `run`
    restart_state: std.atomic.Value(u8) = .init(0), // 0 idle, 1 requested, 2 ok, 3 failed
    restart_pid: std.atomic.Value(i32) = .init(0),

    metrics: [max_metrics]Stored = @splat(.{}),
    metric_count: usize = 0,
    runtime_name: []const u8,

    pub fn init(gpa: std.mem.Allocator, host: Host, info: Info, opts: Options, stats: *stats_mod.Stats, logs: ?*logring.LogRing, launch: ?*const reexec.LaunchInfo) !*Service {
        const self = try gpa.create(Service);
        self.* = .{
            .gpa = gpa,
            .host = host,
            .info = info,
            .opts = opts,
            .stats = stats,
            .logs = logs,
            .launch = launch,
            .euid = sys.geteuid(),
            .runtime_name = info.runtime,
        };
        self.clients = .initBuffer(&self.clients_buf);
        self.stop_pipe = try sys.pipe();
        return self;
    }

    /// Binds the socket and starts accepting. Failure leaves the service
    /// usable for the in-process console.
    pub fn listen(self: *Service, path: []const u8) !void {
        const fd = try os.listenUnix(path, 8);
        errdefer sys.close(fd);
        self.path = try self.gpa.dupe(u8, path);
        self.listener = fd;
        self.acceptor = try std.Thread.spawn(.{}, acceptMain, .{self});
    }

    pub fn attachedCount(self: *const Service) u32 {
        return self.attached.load(.monotonic);
    }

    /// `stop`, then `destroy`.
    pub fn deinit(self: *Service) void {
        self.stop();
        self.destroy();
    }

    /// Stops the threads, closes every client (with `bye`) and removes the
    /// socket file. The memory stays for callers that still hold the
    /// service (`setMetrics`, `attachedCount` from the C ABI's threads)
    /// until `destroy`.
    pub fn stop(self: *Service) void {
        if (self.stopped) return;
        self.stopped = true;
        self.stopping.store(true, .release);
        _ = sys.write(self.stop_pipe[1], "x") catch {};
        if (self.acceptor) |t| t.join();
        self.acceptor = null;
        // Clients join themselves in `reap`; wait for all of them.
        while (true) {
            self.lock.lock();
            const n = self.clients.items.len;
            self.lock.unlock();
            if (n == 0) break;
            self.reap();
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 5);
        }
        if (self.listener >= 0) sys.close(self.listener);
        if (self.path) |p| {
            os.unlink(p);
            self.gpa.free(p);
        }
        sys.close(self.stop_pipe[0]);
        sys.close(self.stop_pipe[1]);
    }

    /// Frees the service, once nothing can reach it any more (after `stop`).
    pub fn destroy(self: *Service) void {
        self.gpa.destroy(self);
    }

    /// Joins and frees every client whose thread ended.
    fn reap(self: *Service) void {
        while (true) {
            var finished: [8]*Client = undefined;
            var n: usize = 0;
            self.lock.lock();
            var i: usize = 0;
            while (i < self.clients.items.len and n < finished.len) {
                const c = self.clients.items[i];
                if (c.done.load(.acquire)) {
                    finished[n] = c;
                    n += 1;
                    _ = self.clients.swapRemove(i);
                } else i += 1;
            }
            self.lock.unlock();
            for (finished[0..n]) |c| {
                if (c.thread) |t| t.join();
                c.reader.deinit(self.gpa);
                c.out.deinit(self.gpa);
                self.gpa.destroy(c);
            }
            if (n < finished.len) return;
        }
    }

    /// Tells the peer on `fd` that the console is busy, and closes it.
    fn refuseBusy(fd: sys.fd_t) error{Busy} {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        protocol.encode(.{ .err = .{ .code = protocol.code_busy, .message = "4 consoles are attached already" } }, &w) catch {};
        sys.writeAll(fd, w.buffered()) catch {};
        sys.close(fd);
        return error.Busy;
    }

    fn liveCount(self: *Service) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var n: usize = 0;
        for (self.clients.items) |c| {
            if (!c.done.load(.acquire)) n += 1;
        }
        return n;
    }

    /// Adds an already connected stream (the in-process console's socketpair
    /// end, or an accepted socket). The service owns `fd` from here.
    pub fn adopt(self: *Service, fd: sys.fd_t, in_process: bool) !void {
        self.reap();
        if (self.liveCount() >= protocol.max_clients) return refuseBusy(fd);
        const c = try self.gpa.create(Client);
        c.* = .{ .service = self, .fd = fd, .in_process = in_process };
        errdefer self.gpa.destroy(c);
        sys.setNonblock(fd);
        self.lock.lock();
        self.clients.appendBounded(c) catch {
            // Clients whose thread ended faster than `reap` could join
            // them fill the list (U4): this one is told busy.
            self.lock.unlock();
            return refuseBusy(fd);
        };
        self.lock.unlock();
        _ = self.attached.fetchAdd(1, .monotonic);
        c.thread = std.Thread.spawn(.{}, clientMain, .{c}) catch {
            _ = self.attached.fetchSub(1, .monotonic);
            self.lock.lock();
            for (self.clients.items, 0..) |x, i| if (x == c) {
                _ = self.clients.swapRemove(i);
                break;
            };
            self.lock.unlock();
            sys.close(fd);
            return error.SystemResources;
        };
    }

    // ---------------------------------------------------------- acceptor

    var warned_peer: std.atomic.Value(bool) = .init(false);

    fn acceptMain(self: *Service) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [2]sys.PollFd{
                .{ .fd = self.listener, .events = sys.POLLIN, .revents = 0 },
                .{ .fd = self.stop_pipe[0], .events = sys.POLLIN, .revents = 0 },
            };
            _ = sys.poll(&fds, 1000);
            self.reap();
            if (fds[1].revents != 0) return;
            if (fds[0].revents & sys.POLLIN == 0) continue;
            const fd = os.accept(self.listener) orelse continue;
            const uid = os.peerUid(fd);
            if (uid == null or !os.peerAllowed(uid.?, self.euid)) {
                if (!warned_peer.swap(true, .monotonic)) {
                    std.log.scoped(.anole).info("console: refused a connection from another user", .{});
                }
                sys.close(fd);
                continue;
            }
            self.adopt(fd, false) catch {};
        }
    }

    // ----------------------------------------------------------- clients

    fn clientMain(c: *Client) void {
        defer {
            _ = c.service.attached.fetchSub(1, .monotonic);
            c.done.store(true, .release);
        }
        clientLoop(c) catch {};
        // Release what the subscriptions held.
        if (c.logs) |*l| {
            if (c.service.logs) |lr| lr.unwatch();
            freeLogSub(c.service.gpa, l);
            c.logs = null;
        }
        if (c.stats != null) {
            stats_mod.collectStop();
            c.stats = null;
        }
        sys.close(c.fd);
    }

    fn freeLogSub(gpa: std.mem.Allocator, l: *LogSub) void {
        for (l.strings) |s| gpa.free(s);
        gpa.free(l.strings);
    }

    fn clientLoop(c: *Client) !void {
        const self = c.service;
        try sendHello(c);
        try flush(c);
        var read_buf: [16 * 1024]u8 = undefined;
        var last_broadcast = self.broadcast_seq.load(.acquire);
        c.seen_broadcast.store(last_broadcast, .release);
        while (true) {
            var fds = [2]sys.PollFd{
                .{ .fd = c.fd, .events = sys.POLLIN, .revents = 0 },
                .{ .fd = self.stop_pipe[0], .events = sys.POLLIN, .revents = 0 },
            };
            _ = sys.poll(&fds, tick_ms);
            if (self.stopping.load(.acquire)) {
                const reason: []const u8 = if (self.bye_reason.load(.acquire) == 1) "drain" else "stop";
                try send(c, .{ .bye = .{ .reason = reason } });
                try flush(c);
                return;
            }
            if (fds[0].revents & (sys.POLLIN | sys.POLLHUP | sys.POLLERR) != 0) {
                const n = sys.read(c.fd, &read_buf) catch |e| switch (e) {
                    error.WouldBlock => 0,
                    else => return,
                };
                if (n == 0 and fds[0].revents & sys.POLLIN != 0) return; // closed
                if (n == 0 and fds[0].revents & (sys.POLLHUP | sys.POLLERR) != 0) return;
                try c.reader.feed(self.gpa, read_buf[0..n]);
                while (true) {
                    const line = c.reader.next() catch {
                        try send(c, .{ .err = .{ .code = protocol.code_too_big } });
                        try flush(c);
                        return;
                    } orelse break;
                    if (line.len == 0) continue;
                    try handleLine(c, line);
                }
            }
            const seq = self.broadcast_seq.load(.acquire);
            if (seq != last_broadcast) {
                var line: [@sizeOf(@TypeOf(self.broadcast_buf))]u8 = undefined;
                self.lock.lock();
                const len = self.broadcast_len;
                @memcpy(line[0..len], self.broadcast_buf[0..len]);
                self.lock.unlock();
                try c.out.appendSlice(self.gpa, line[0..len]);
                last_broadcast = seq;
            }
            try pump(c);
            try flush(c);
            c.seen_broadcast.store(last_broadcast, .release);
        }
    }

    fn sendHello(c: *Client) !void {
        const i = c.service.info;
        try send(c, .{ .hello = .{
            .proto = protocol.proto,
            .anole = i.anole,
            .app = .{ .name = i.name, .pid = sys.getpid(), .started = i.started_iso, .host = i.host, .environment = i.environment, .deployment = i.deployment, .build = i.build, .executors = i.executors, .runtime = i.runtime },
            .allow = i.allow,
            .why_not = i.why_not,
            .supervisor = i.supervisor,
            .features = i.features,
        } });
    }

    fn send(c: *Client, frame: protocol.Frame) !void {
        var aw: std.Io.Writer.Allocating = .fromArrayList(c.service.gpa, &c.out);
        defer c.out = aw.toArrayList();
        protocol.encode(frame, &aw.writer) catch return error.OutOfMemory;
    }

    /// Writes everything queued; a client that does not read for 30 s is
    /// closed.
    fn flush(c: *Client) !void {
        var stalled: u32 = 0;
        while (c.out_off < c.out.items.len) {
            const rest = c.out.items[c.out_off..];
            if (sys.write(c.fd, rest)) |n| {
                c.out_off += n;
                stalled = 0;
            } else |e| switch (e) {
                error.WouldBlock => {
                    var p = [1]sys.PollFd{.{ .fd = c.fd, .events = sys.POLLOUT, .revents = 0 }};
                    if (sys.poll(&p, 250) == 0) {
                        stalled += 250;
                        if (stalled >= stall_close_ms or c.service.stopping.load(.acquire)) return error.Stalled;
                    }
                },
                else => return error.Closed,
            }
        }
        c.out.clearRetainingCapacity();
        c.out_off = 0;
    }

    fn reply(c: *Client, id: u32, data: ?std.json.Value) !void {
        try send(c, .{ .res = .{ .id = id, .ok = true, .data = data } });
    }

    fn fail(c: *Client, id: u32, code: []const u8, message: []const u8) !void {
        try send(c, .{ .res = .{ .id = id, .ok = false, .code = code, .message = message } });
    }

    fn handleLine(c: *Client, line: []const u8) !void {
        var arena_s = std.heap.ArenaAllocator.init(c.service.gpa);
        defer arena_s.deinit();
        const a = arena_s.allocator();
        const frame = protocol.decode(a, line) catch {
            try send(c, .{ .err = .{ .code = protocol.code_invalid, .message = "not a frame" } });
            return;
        };
        switch (frame) {
            .hello => |h| {
                if (protocol.versionError(h)) |e| {
                    try send(c, .{ .err = e });
                    try flush(c);
                    return error.Version;
                }
                c.hello_done = true;
            },
            .req => |r| try handleRequest(c, a, r),
            else => {},
        }
    }

    fn handleRequest(c: *Client, a: std.mem.Allocator, r: protocol.Request) !void {
        const self = c.service;
        const op = protocol.Op.parse(r.op) orelse return fail(c, r.id, protocol.code_unknown_op, r.op);
        switch (op) {
            .ping => try reply(c, r.id, emptyObject()),
            .snapshot => {
                const what = r.what orelse return fail(c, r.id, protocol.code_invalid, "snapshot needs `what`");
                const view = std.meta.stringToEnum(protocol.View, what) orelse return fail(c, r.id, protocol.code_invalid, "unknown view");
                const data = self.snapshot(a, view) catch |e| switch (e) {
                    error.Unavailable => return fail(c, r.id, protocol.code_unavailable, self.unavailableText(view)),
                    else => return fail(c, r.id, protocol.code_failed, @errorName(e)),
                };
                try reply(c, r.id, data);
            },
            .subscribe => try subscribe(c, a, r),
            .unsubscribe => {
                const sub = r.sub orelse return fail(c, r.id, protocol.code_invalid, "unsubscribe needs `sub`");
                if (c.logs) |*l| if (l.sub == sub) {
                    if (self.logs) |lr| lr.unwatch();
                    freeLogSub(self.gpa, l);
                    c.logs = null;
                };
                if (c.stats) |s| if (s.sub == sub) {
                    stats_mod.collectStop();
                    c.stats = null;
                };
                if (c.errors) |e| if (e.sub == sub) {
                    c.errors = null;
                };
                try reply(c, r.id, emptyObject());
            },
            .reload => {
                if (self.opts.read_only) return fail(c, r.id, protocol.code_refused, "the console is read-only (console.read_only)");
                var buf: [512]u8 = undefined;
                switch (self.host.reload(self.host.ctx, &buf)) {
                    .ok => |n| {
                        var obj: std.json.ObjectMap = .empty;
                        try obj.put(a, "certificates", .{ .integer = n });
                        try reply(c, r.id, .{ .object = obj });
                    },
                    .unavailable => |m| try fail(c, r.id, protocol.code_unavailable, m),
                    .failed => |m| try fail(c, r.id, protocol.code_failed, m),
                }
            },
            .drain => {
                if (self.opts.read_only) return fail(c, r.id, protocol.code_refused, "the console is read-only (console.read_only)");
                if (!confirmed(r, protocol.confirm_drain)) return fail(c, r.id, protocol.code_confirm_required, "send confirm \"drain\"");
                std.log.scoped(.anole).info("console: drain requested", .{});
                self.bye_reason.store(1, .release);
                try reply(c, r.id, emptyObject());
                try flush(c);
                self.host.stop(self.host.ctx);
            },
            .restart => try handleRestart(c, a, r),
            .full_restart => try handleFullRestart(c, a, r),
            .launch_info => {
                if (!self.info.allow.full_restart) return fail(c, r.id, protocol.code_refused, self.info.why_not.full_restart orelse "not allowed");
                const l = self.launch orelse return fail(c, r.id, protocol.code_unavailable, "launch information was not recorded");
                var obj: std.json.ObjectMap = .empty;
                try obj.put(a, "exe", .{ .string = l.exe });
                try obj.put(a, "cwd", .{ .string = l.cwd });
                var argv: std.json.Array = .init(a);
                for (l.argv) |s| try argv.append(.{ .string = s });
                try obj.put(a, "argv", .{ .array = argv });
                var env: std.json.Array = .init(a);
                for (l.env) |s| try env.append(.{ .string = s });
                try obj.put(a, "env", .{ .array = env });
                try reply(c, r.id, .{ .object = obj });
            },
        }
    }

    fn emptyObject() std.json.Value {
        return .{ .object = .empty };
    }

    fn confirmed(r: protocol.Request, token: []const u8) bool {
        const got = r.confirm orelse return false;
        return std.mem.eql(u8, got, token);
    }

    fn handleRestart(c: *Client, a: std.mem.Allocator, r: protocol.Request) !void {
        const self = c.service;
        if (self.opts.read_only) return fail(c, r.id, protocol.code_refused, "the console is read-only (console.read_only)");
        if (!self.info.allow.restart) {
            const why = self.info.why_not.restart orelse "restart is not available";
            return fail(c, r.id, if (self.opts.allow_restart) protocol.code_unavailable else protocol.code_refused, why);
        }
        if (!confirmed(r, protocol.confirm_restart)) return fail(c, r.id, protocol.code_confirm_required, "send confirm \"restart\"");
        const restart = self.host.restart orelse return fail(c, r.id, protocol.code_unavailable, "no listener hand-off");
        if (self.restart_state.swap(1, .acq_rel) == 1) return fail(c, r.id, protocol.code_busy, "a restart is already in progress");
        std.log.scoped(.anole).info("console: restart requested", .{});
        restart(self.host.ctx);
        const deadline = sys.monotonicMs() + self.opts.restart_wait_ms;
        while (sys.monotonicMs() < deadline) {
            const st = self.restart_state.load(.acquire);
            if (st >= 2) break;
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 50);
        }
        const st = self.restart_state.swap(0, .acq_rel);
        if (st == 2) {
            const pid = self.restart_pid.load(.acquire);
            var buf: [128]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try protocol.encode(.{ .restarting = .{ .mode = "handoff", .successor_pid = pid } }, &w);
            _ = self.broadcastLine(w.buffered());
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "successor_pid", .{ .integer = pid });
            try reply(c, r.id, .{ .object = obj });
        } else {
            try fail(c, r.id, protocol.code_failed, "restart: the new process did not report serving; carrying on");
        }
    }

    /// Called by `run` after the hand-off attempt.
    pub fn restartFinished(self: *Service, ok: bool, successor_pid: i32) void {
        self.restart_pid.store(successor_pid, .release);
        self.restart_state.store(if (ok) 2 else 3, .release);
    }

    pub fn restartRequested(self: *const Service) bool {
        return self.restart_state.load(.acquire) == 1;
    }

    fn handleFullRestart(c: *Client, a: std.mem.Allocator, r: protocol.Request) !void {
        const self = c.service;
        if (self.opts.read_only) return fail(c, r.id, protocol.code_refused, "the console is read-only (console.read_only)");
        if (!self.info.allow.full_restart) return fail(c, r.id, protocol.code_refused, self.info.why_not.full_restart orelse "full restart is not allowed");
        if (!confirmed(r, protocol.confirm_full_restart)) return fail(c, r.id, protocol.code_confirm_required, "send confirm \"full-restart\"");
        const l = self.launch orelse return fail(c, r.id, protocol.code_unavailable, "launch information was not recorded");
        var plan_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer plan_arena.deinit();
        const plan = reexec.build(plan_arena.allocator(), l) catch return fail(c, r.id, protocol.code_failed, "out of memory");
        _ = a;
        // Tell every console, flush, then exec.
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try protocol.encode(.{ .restarting = .{ .mode = "exec", .pid = sys.getpid() } }, &w);
        const seq = self.broadcastLine(w.buffered());
        self.waitBroadcast(seq, 1000);
        if (self.host.before_exec) |f| f(self.host.ctx);
        std.log.scoped(.anole).warn("console: full restart requested: re-executing {s}; open connections are dropped", .{plan.exe});
        const err = reexec.execNow(&plan);
        std.log.scoped(.anole).err("console: full restart failed: {t}", .{err});
        try fail(c, r.id, protocol.code_failed, "full restart failed: exec did not start the program");
    }

    /// Queues a line for every client; returns its sequence.
    pub fn broadcastLine(self: *Service, line: []const u8) u32 {
        self.lock.lock();
        const n = @min(line.len, self.broadcast_buf.len);
        @memcpy(self.broadcast_buf[0..n], line[0..n]);
        self.broadcast_len = n;
        self.lock.unlock();
        return self.broadcast_seq.fetchAdd(1, .acq_rel) + 1;
    }

    /// Waits until every live client flushed broadcast `seq` (or the time
    /// is up).
    pub fn waitBroadcast(self: *Service, seq: u32, timeout_ms: i64) void {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (sys.monotonicMs() < deadline) {
            var all = true;
            self.lock.lock();
            for (self.clients.items) |c| {
                if (c.done.load(.acquire)) continue;
                if (c.seen_broadcast.load(.acquire) != seq) all = false;
            }
            self.lock.unlock();
            if (all) return;
            var p = [1]sys.PollFd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = sys.poll(&p, 10);
        }
    }

    /// The drain began with this reason ("drain" for a console's /drain).
    pub fn setStopping(self: *Service) void {
        self.stopping.store(true, .release);
        _ = sys.write(self.stop_pipe[1], "x") catch {};
    }

    fn unavailableText(self: *Service, view: protocol.View) []const u8 {
        _ = self;
        return switch (view) {
            .tasks => "needs a task registry in the runtime (zio); not available yet",
            .h3 => "HTTP/3 is not on",
            else => "not available in this build or setup",
        };
    }

    // ------------------------------------------------------ subscriptions

    fn subscribe(c: *Client, a: std.mem.Allocator, r: protocol.Request) !void {
        const self = c.service;
        const stream = r.stream orelse return fail(c, r.id, protocol.code_invalid, "subscribe needs `stream`");
        if (std.mem.eql(u8, stream, "logs")) {
            const lr = self.logs orelse return fail(c, r.id, protocol.code_unavailable, "log capture is off (console.log_buffer = 0)");
            if (c.logs) |*old| {
                lr.unwatch();
                freeLogSub(self.gpa, old);
                c.logs = null;
            }
            var strings: std.ArrayList([]u8) = .empty;
            errdefer {
                for (strings.items) |s| self.gpa.free(s);
                strings.deinit(self.gpa);
            }
            var filter: logring.Filter = .{};
            if (r.filter) |f| {
                if (f.level) |s| filter.level = logring.levelFromName(s);
                inline for (.{ "scope", "route", "request_id", "grep" }) |field| {
                    if (@field(f, field)) |s| {
                        const copy = try self.gpa.dupe(u8, s);
                        try strings.append(self.gpa, copy);
                        @field(filter, field) = copy;
                    }
                }
            }
            const sub = c.next_sub;
            c.next_sub += 1;
            var cursors: logring.Cursors = undefined;
            lr.watch();
            var backlog: std.ArrayList(logring.Rec) = .empty;
            try lr.readBacklogAndAttach(a, &cursors, &backlog);
            c.logs = .{ .sub = sub, .filter = filter, .strings = try strings.toOwnedSlice(self.gpa), .cursors = cursors };
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "sub", .{ .integer = sub });
            try reply(c, r.id, .{ .object = obj });
            // The last `backlog` matching records.
            const want: usize = r.backlog orelse 500;
            var picked: std.ArrayList(logring.Rec) = .empty;
            for (backlog.items) |rec| if (filter.matches(rec)) try picked.append(a, rec);
            const from = if (picked.items.len > want) picked.items.len - want else 0;
            for (picked.items[from..]) |rec| try sendLog(c, sub, rec);
        } else if (std.mem.eql(u8, stream, "stats")) {
            if (c.stats != null) {
                stats_mod.collectStop();
                c.stats = null;
            }
            stats_mod.collectStart(self.stats) catch return fail(c, r.id, protocol.code_failed, "out of memory");
            const sub = c.next_sub;
            c.next_sub += 1;
            const interval = std.math.clamp(r.interval_ms orelse 1000, 250, 10000);
            c.stats = .{ .sub = sub, .interval_ms = interval, .next_due_ms = sys.monotonicMs() };
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "sub", .{ .integer = sub });
            try obj.put(a, "buckets", .{ .integer = protocol.bucket_count });
            try reply(c, r.id, .{ .object = obj });
        } else if (std.mem.eql(u8, stream, "errors")) {
            const sub = c.next_sub;
            c.next_sub += 1;
            c.errors = .{ .sub = sub, .last_seq = self.stats.errors.current() };
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "sub", .{ .integer = sub });
            try reply(c, r.id, .{ .object = obj });
        } else {
            try fail(c, r.id, protocol.code_invalid, "unknown stream");
        }
    }

    fn sendLog(c: *Client, sub: u32, rec: logring.Rec) !void {
        var tb: [32]u8 = undefined;
        try send(c, .{ .log = .{
            .sub = sub,
            .time = isoNs(&tb, rec.time_ns),
            .level = logring.levelName(rec.level),
            .scope = rec.scope,
            .request_id = rec.rid,
            .route = rec.route,
            .json = rec.json,
            .text = rec.text,
        } });
    }

    /// Everything a client's subscriptions owe it this tick.
    fn pump(c: *Client) !void {
        const self = c.service;
        var arena_s = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_s.deinit();
        const a = arena_s.allocator();

        if (c.logs) |*l| {
            const lr = self.logs.?;
            var recs: std.ArrayList(logring.Rec) = .empty;
            var dropped: u64 = 0;
            try lr.readNew(a, &l.cursors, &recs, &dropped);
            var keep: std.ArrayList(logring.Rec) = .empty;
            for (recs.items) |rec| if (l.filter.matches(rec)) try keep.append(a, rec);
            // Past the budget the oldest are skipped and counted.
            var from: usize = 0;
            if (keep.items.len > max_logs_per_tick) from = keep.items.len - max_logs_per_tick;
            var bytes: usize = 0;
            var i = keep.items.len;
            while (i > from) {
                i -= 1;
                bytes += keep.items[i].text.len + 128;
                if (bytes > max_log_bytes_per_tick) {
                    from = i + 1;
                    break;
                }
            }
            dropped += from;
            if (dropped > 0) try send(c, .{ .dropped = .{ .sub = l.sub, .n = dropped } });
            for (keep.items[from..]) |rec| try sendLog(c, l.sub, rec);
        }

        if (c.errors) |*e| {
            var buf: [64]stats_mod.ErrorEntry = undefined;
            const n = self.stats.errors.copyAfter(e.last_seq, &buf);
            for (buf[0..n]) |*ent| {
                try send(c, .{ .error5xx = self.errorFrame(e.sub, ent) });
                e.last_seq = ent.seq;
            }
        }

        if (c.stats) |*s| {
            const now = sys.monotonicMs();
            if (now >= s.next_due_ms) {
                s.next_due_ms = now + s.interval_ms;
                s.seq += 1;
                try send(c, .{ .stats = try self.statsFrame(a, s.sub, s.seq, now) });
            }
        }
    }

    fn errorFrame(self: *Service, sub: u32, e: *const stats_mod.ErrorEntry) protocol.Error5xx {
        var tb: [32]u8 = undefined;
        const time = isoMs(&tb, e.time_ms);
        _ = time;
        return .{
            .sub = sub,
            .seq = e.seq,
            // The text lives in the entry's own copy below.
            .time = isoMsStatic(e.time_ms),
            .status = e.status,
            .method = e.methodStr(),
            .path = e.pathStr(),
            .route = self.routePattern(e.route_index),
            .@"error" = e.errStr(),
            .request_id = e.ridStr(),
            .duration_us = e.duration_us,
        };
    }

    fn routePattern(self: *Service, index: u32) []const u8 {
        if (index == 0) return "";
        const f = self.host.route_meta orelse return "";
        return (f(self.host.ctx, index) orelse return "").pattern;
    }

    fn statsFrame(self: *Service, a: std.mem.Allocator, sub: u32, seq: u64, now: i64) !protocol.Stats {
        var routes: std.ArrayList(protocol.RouteStat) = .empty;
        const st = self.stats;
        var slot: u32 = 0;
        while (slot < st.route_slots) : (slot += 1) {
            const s = st.sum(slot);
            if (s.n == 0) continue;
            var h: std.ArrayList([2]u32) = .empty;
            for (s.h, 0..) |count, b| if (count != 0) try h.append(a, .{ @intCast(b), count });
            var rs: protocol.RouteStat = .{ .i = slot, .n = s.n, .s2 = s.s2, .s3 = s.s3, .s4 = s.s4, .s5 = s.s5, .h = h.items };
            if (slot == 0) {
                rs.p = "(no route)";
            } else if (slot == st.max_routes + 1) {
                rs.p = "(other routes)";
            } else if (self.host.route_meta) |f| {
                if (f(self.host.ctx, slot)) |m| {
                    rs.m = try a.dupe(u8, m.method);
                    rs.p = try a.dupe(u8, m.pattern);
                }
            }
            try routes.append(a, rs);
        }
        const n_exec = @min(self.host.executors, dusty.gauges.max_executors);
        var execs = try a.alloc([2]u32, n_exec);
        var total: u32 = 0;
        for (0..n_exec) |i| {
            const conns: u32 = @intCast(@max(0, dusty.gauges.get(.connections, i)));
            const streams: u32 = @intCast(@max(0, dusty.gauges.get(.h2_streams, i) + dusty.gauges.get(.h3_streams, i)));
            execs[i] = .{ conns, streams };
            total +%= conns;
        }
        return .{
            .sub = sub,
            .seq = seq,
            .mono_ms = now,
            .routes = routes.items,
            .conns = .{ .total = total, .executors = execs },
            .err_seq = st.errors.current(),
        };
    }

    // ---------------------------------------------------------- snapshots

    pub const SnapshotError = error{ Unavailable, OutOfMemory, WriteFailed, InvalidJson };

    fn parse(a: std.mem.Allocator, text: []const u8) SnapshotError!std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidJson,
        };
    }

    fn hostJson(self: *Service, a: std.mem.Allocator, f: *const fn (*anyopaque, *std.Io.Writer) anyerror!void) SnapshotError!std.json.Value {
        var aw: std.Io.Writer.Allocating = .init(a);
        f(self.host.ctx, &aw.writer) catch return error.WriteFailed;
        return parse(a, aw.written());
    }

    pub fn snapshot(self: *Service, a: std.mem.Allocator, view: protocol.View) SnapshotError!std.json.Value {
        switch (view) {
            .tasks => return error.Unavailable,
            .errors => {
                var buf: [256]stats_mod.ErrorEntry = undefined;
                const n = self.stats.errors.copyRecent(&buf);
                var arr: std.json.Array = .init(a);
                for (buf[0..n]) |*e| {
                    var obj: std.json.ObjectMap = .empty;
                    try obj.put(a, "seq", .{ .integer = @intCast(e.seq) });
                    try obj.put(a, "time", .{ .string = try a.dupe(u8, isoMsStatic(e.time_ms)) });
                    try obj.put(a, "status", .{ .integer = e.status });
                    try obj.put(a, "method", .{ .string = try a.dupe(u8, e.methodStr()) });
                    try obj.put(a, "path", .{ .string = try a.dupe(u8, e.pathStr()) });
                    try obj.put(a, "route", .{ .string = try a.dupe(u8, self.routePattern(e.route_index)) });
                    try obj.put(a, "error", .{ .string = try a.dupe(u8, e.errStr()) });
                    try obj.put(a, "request_id", .{ .string = try a.dupe(u8, e.ridStr()) });
                    try obj.put(a, "duration_us", .{ .integer = @intCast(e.duration_us) });
                    try arr.append(.{ .object = obj });
                }
                var root: std.json.ObjectMap = .empty;
                try root.put(a, "entries", .{ .array = arr });
                return .{ .object = root };
            },
            .conns => {
                var root: std.json.ObjectMap = .empty;
                var execs: std.json.Array = .init(a);
                const n = @min(self.host.executors, dusty.gauges.max_executors);
                for (0..n) |i| {
                    var o: std.json.ObjectMap = .empty;
                    try o.put(a, "i", .{ .integer = @intCast(i) });
                    if (self.host.task_stats) |f| if (f(self.host.ctx, i)) |ts| {
                        try o.put(a, "tasks", .{ .integer = @intCast(ts.tasks) });
                        try o.put(a, "run_queue", .{ .integer = @intCast(ts.run_queue) });
                    };
                    try o.put(a, "connections", .{ .integer = dusty.gauges.get(.connections, i) });
                    var streams: std.json.ObjectMap = .empty;
                    try streams.put(a, "h2", .{ .integer = dusty.gauges.get(.h2_streams, i) });
                    try streams.put(a, "h3", .{ .integer = dusty.gauges.get(.h3_streams, i) });
                    try o.put(a, "streams", .{ .object = streams });
                    try execs.append(.{ .object = o });
                }
                try root.put(a, "executors", .{ .array = execs });
                if (self.host.listeners) |f| try root.put(a, "listeners", try self.hostJson(a, f));
                if (self.host.stack_committed) |f| try root.put(a, "stack_committed_bytes", .{ .integer = @intCast(f(self.host.ctx)) });
                return .{ .object = root };
            },
            .db => {
                const f = self.host.databases orelse return error.Unavailable;
                var root: std.json.ObjectMap = .empty;
                try root.put(a, "databases", try self.hostJson(a, f));
                return .{ .object = root };
            },
            .ws => return self.hostJson(a, self.host.ws orelse return error.Unavailable),
            .h3 => return self.hostJson(a, self.host.h3 orelse return error.Unavailable),
            .routes => {
                const f = self.host.routes orelse return error.Unavailable;
                var root: std.json.ObjectMap = .empty;
                try root.put(a, "routes", try self.hostJson(a, f));
                return .{ .object = root };
            },
            .config => {
                const f = self.host.config orelse return error.Unavailable;
                var aw: std.Io.Writer.Allocating = .init(a);
                f(self.host.ctx, &aw.writer) catch return error.WriteFailed;
                var root: std.json.ObjectMap = .empty;
                try root.put(a, "text", .{ .string = aw.written() });
                return .{ .object = root };
            },
            .runtime => {
                const p = procinfo.read();
                var root: std.json.ObjectMap = .empty;
                try root.put(a, "rss_bytes", .{ .integer = @intCast(p.rss_bytes) });
                try root.put(a, "cpu_ms", .{ .integer = @intCast(p.cpu_ms) });
                try root.put(a, "threads", .{ .integer = @intCast(p.threads) });
                try root.put(a, "fds", .{ .integer = @intCast(p.fds) });
                try root.put(a, "fd_limit", .{ .integer = @intCast(p.fd_limit) });
                try root.put(a, "uptime_ms", .{ .integer = @max(0, sys.wallMs() - self.info.started_ms) });
                try root.put(a, "build", .{ .string = self.info.build });
                try root.put(a, "anole", .{ .string = self.info.anole });
                try root.put(a, "runtime", .{ .string = self.runtime_name });
                var lang: std.json.Array = .init(a);
                // Copied under the lock, turned into JSON after it.
                var kept: [max_metrics]Stored = undefined;
                const n = n: {
                    self.lock.lock();
                    defer self.lock.unlock();
                    @memcpy(kept[0..self.metric_count], self.metrics[0..self.metric_count]);
                    break :n self.metric_count;
                };
                for (kept[0..n]) |*m| {
                    var o: std.json.ObjectMap = .empty;
                    try o.put(a, "name", .{ .string = try a.dupe(u8, m.name[0..m.name_len]) });
                    try o.put(a, "value", .{ .float = m.value });
                    try o.put(a, "unit", .{ .string = try a.dupe(u8, m.unit[0..m.unit_len]) });
                    try lang.append(.{ .object = o });
                }
                try root.put(a, "language", .{ .array = lang });
                return .{ .object = root };
            },
        }
    }

    /// The C ABI's `anole_console_report`: replaces the language metrics.
    /// At most `max_metrics` (`error.TooMany`); a name is 1 to
    /// `max_metric_name` bytes and a unit at most `max_metric_unit`
    /// (`error.Invalid`). Copied under the service's lock, with nothing
    /// allocated.
    pub fn setMetrics(self: *Service, items: []const Metric) !void {
        if (items.len > max_metrics) return error.TooMany;
        for (items) |m| {
            if (m.name.len == 0 or m.name.len > max_metric_name or m.unit.len > max_metric_unit) return error.Invalid;
        }
        self.lock.lock();
        defer self.lock.unlock();
        for (items, self.metrics[0..items.len]) |m, *d| {
            d.* = .{ .name_len = @intCast(m.name.len), .unit_len = @intCast(m.unit.len), .value = m.value };
            @memcpy(d.name[0..m.name.len], m.name);
            @memcpy(d.unit[0..m.unit.len], m.unit);
        }
        self.metric_count = items.len;
    }
};

// ------------------------------------------------------------- time text

/// `YYYY-MM-DDTHH:MM:SS.mmmZ` for epoch milliseconds, in `buf`.
pub fn isoMs(buf: *[32]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const rem: u64 = @intCast(@mod(ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        rem,
    }) catch "";
}

pub fn isoNs(buf: *[32]u8, ns: i64) []const u8 {
    return isoMs(buf, @divFloor(ns, std.time.ns_per_ms));
}

threadlocal var iso_tl: [4][32]u8 = undefined;
threadlocal var iso_next: u8 = 0;

/// A rotating thread-local buffer (the frame holds the slice until it is
/// encoded: at most four are live at once).
fn isoMsStatic(ms: i64) []const u8 {
    const i = iso_next % 4;
    iso_next +%= 1;
    return isoMs(&iso_tl[i], ms);
}

// ------------------------------------------------------------------ tests

test "service: isoMs writes UTC ISO 8601 with milliseconds that the client's parseIso reads" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-23T09:41:07.415Z", isoMs(&b, 1792748467415));
    try std.testing.expectEqual(@as(i64, 1792748467415), ui.app.parseIso("2026-10-23T09:41:07.415Z").?);
}
