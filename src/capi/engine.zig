//! The C ABI's engine (M17 spike): requests that a route hands to a
//! consumer (a language thread: Node, Python, a C program) cross through
//! a lock-free ring per executor, and the consumer answers by handle.
//!
//! Rules (research/c-abi-design-2026-10-21.md, recommendation 1):
//! - No executor ever runs consumer code. An executor fills a slot, pushes
//!   its handle onto the ring of the consumer it feeds, and rings the
//!   consumer's doorbell only when the consumer has said it is going to
//!   sleep (`awake` false). The doorbell is the consumer's own non-blocking
//!   callback (a threadsafe function, an eventfd write) or Anole's fd.
//! - The consumer drains a whole batch with one `poll` into its own
//!   buffer, and answers with `respond`, which copies the reply into the
//!   slot and wakes the waiting task (zio's remote wake).
//! - Handles are 64-bit: executor (8 bits), slot (24), generation (32).
//!   A slot's state and generation share one atomic word, so a stale
//!   handle can never claim a reused slot: it gets `error.Gone`.
//! - Anole enforces the deadline: the task stops waiting, answers 504 and
//!   frees the slot; a reply after that gets `error.Gone`.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const http = anole.http;
const zio = anole.zio;
const placement = dusty.placement;

/// The allocator for everything here: thread-safe, since consumers and
/// executors both use it.
pub const gpa = std.heap.smp_allocator;

// ---------------------------------------------------------------------------
// Slots and handles

pub const SlotState = enum(u32) {
    /// On the executor's free list.
    free,
    /// Filled, its handle in the consumer's ring.
    queued,
    /// `poll` is copying its head out (executor memory is being read).
    polling,
    /// Delivered: the consumer owes a reply.
    out,
    /// `respond` is copying the reply in.
    responding,
    /// The reply is in; the executor takes it.
    done,
    /// The executor gave up (deadline, cancel): no reply is taken.
    expired,
};

fn pack(gen: u32, state: SlotState) u64 {
    return (@as(u64, gen) << 32) | @intFromEnum(state);
}
fn genOf(word: u64) u32 {
    return @intCast(word >> 32);
}
fn stateOf(word: u64) SlotState {
    return @enumFromInt(@as(u32, @truncate(word)));
}

pub const Handle = packed struct(u64) {
    gen: u32,
    slot: u24,
    exec: u8,

    pub fn encode(h: Handle) u64 {
        return @bitCast(h);
    }
    pub fn decode(v: u64) Handle {
        return @bitCast(v);
    }
};

const ReplyHeader = struct { name_off: u32, name_len: u32, value_off: u32, value_len: u32 };

const Slot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    event: std.Io.Event = .unset,
    // Request side: set by the executor before the handle is queued, read
    // by `poll` while the state is `polling`.
    req: *http.Request = undefined,
    route_id: u32 = 0,
    body: []const u8 = "",
    // Reply side: written by `respond` while `responding`, read by the
    // executor once `done`. Owned by the slot (thread-safe allocator),
    // reused across requests.
    status: u16 = 0,
    headers: std.ArrayList(ReplyHeader) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    body_off: u32 = 0,
    body_len: u32 = 0,
    next_free: u32 = no_slot,
    // The executor's deadline list (executor-local): requests out with a
    // consumer, oldest first. The executor's sweeper task expires them.
    deadline: i96 = 0,
    prev: u32 = no_slot,
    next: u32 = no_slot,
    linked: bool = false,
    timed_out: bool = false,
    // The executor's done list (replies waiting for its capi task, which
    // wakes their tasks locally): one remote wake per burst of replies
    // rather than one per reply.
    next_done: u32 = no_slot,
    drained: std.atomic.Value(bool) = .init(false),

    /// Above this, a slot's reply buffer is freed after use.
    const keep_capacity = 64 * 1024;
};

const no_slot = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
// The SPSC ring: one executor produces, one consumer thread consumes.

const Ring = struct {
    head: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    tail: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    buf: []u64,
    mask: u64,

    fn init(capacity: usize) !Ring {
        const cap = std.math.ceilPowerOfTwo(usize, capacity) catch return error.OutOfMemory;
        return .{ .buf = try gpa.alloc(u64, cap), .mask = cap - 1 };
    }
    fn deinit(r: *Ring) void {
        gpa.free(r.buf);
    }
    /// Producer. False when full.
    fn push(r: *Ring, v: u64) bool {
        const tail = r.tail.raw;
        if (tail - r.head.load(.acquire) == r.buf.len) return false;
        r.buf[tail & r.mask] = v;
        // seq_cst: ordered before the producer's read of `awake` (Dekker
        // with the consumer's store of `awake` and read of `tail`).
        r.tail.store(tail + 1, .seq_cst);
        return true;
    }
    /// Consumer.
    fn peek(r: *Ring) ?u64 {
        const head = r.head.raw;
        if (head == r.tail.load(.seq_cst)) return null;
        return r.buf[head & r.mask];
    }
    fn pop(r: *Ring) void {
        r.head.store(r.head.raw + 1, .release);
    }
    fn isEmpty(r: *Ring) bool {
        return r.head.raw == r.tail.load(.seq_cst);
    }
};

// ---------------------------------------------------------------------------
// Executors and consumers

pub const Exec = struct {
    index: u8,
    slots: []Slot,
    /// Only this executor touches the free list.
    free_head: u32,
    ring: Ring,
    consumer: ?*Consumer = null,
    /// The deadline list: every consumer request has the same timeout, so
    /// appending keeps it in deadline order, and one sleeping task per
    /// executor enforces them all (a timer per request cost ~20% of the
    /// executor's throughput here).
    dl_head: u32 = no_slot,
    dl_tail: u32 = no_slot,
    /// The sweeper sleeps a whole request timeout while nothing is out; the
    /// first request handed over wakes it (once per idle period) so that
    /// it watches for lost doorbells.
    sweeper_idle: bool = false,
    kick: std.Io.Event = .unset,
    /// Slots answered and not yet handed to their tasks (an intrusive
    /// stack, pushed by `respond` from any thread, taken whole by the
    /// executor's capi task).
    done_head: std.atomic.Value(u32) = .init(no_slot),

    fn link(x: *Exec, io: std.Io, i: u32, deadline: i96) void {
        if (x.dl_head == no_slot and x.sweeper_idle) {
            x.sweeper_idle = false;
            x.kick.set(io);
        }
        const s = &x.slots[i];
        s.deadline = deadline;
        s.timed_out = false;
        s.linked = true;
        s.next = no_slot;
        s.prev = x.dl_tail;
        if (x.dl_tail != no_slot) x.slots[x.dl_tail].next = i else x.dl_head = i;
        x.dl_tail = i;
    }

    fn unlink(x: *Exec, i: u32) void {
        const s = &x.slots[i];
        if (!s.linked) return;
        if (s.prev != no_slot) x.slots[s.prev].next = s.next else x.dl_head = s.next;
        if (s.next != no_slot) x.slots[s.next].prev = s.prev else x.dl_tail = s.prev;
        s.linked = false;
    }

    fn alloc(x: *Exec) ?u32 {
        const i = x.free_head;
        if (i == no_slot) return null;
        x.free_head = x.slots[i].next_free;
        return i;
    }
    fn release(x: *Exec, i: u32) void {
        x.unlink(i);
        const s = &x.slots[i];
        const gen = genOf(s.word.load(.monotonic));
        if (s.bytes.capacity > Slot.keep_capacity) {
            s.bytes.clearAndFree(gpa);
            s.headers.clearAndFree(gpa);
        }
        // A new generation: every handle to the old one is stale now. 0 is
        // skipped so that no handle is ever 0.
        const next = if (gen == std.math.maxInt(u32)) 1 else gen + 1;
        s.word.store(pack(next, .free), .release);
        s.next_free = x.free_head;
        x.free_head = i;
    }
};

pub const WakeFn = *const fn (?*anyopaque) callconv(.c) void;

const builtin = @import("builtin");
/// Windows has no pollable doorbell fd: consumers there pass a callback.
const have_fd = builtin.os.tag != .windows;
/// A doorbell fd (a plain int; unused on Windows).
pub const Fd = c_int;

pub const Consumer = struct {
    engine: *Engine,
    wake_fn: ?WakeFn,
    wake_ud: ?*anyopaque,
    /// Anole's own doorbell when the consumer gave no callback: an eventfd
    /// (Linux) or a pipe (elsewhere).
    fd_read: Fd = -1,
    fd_write: Fd = -1,
    /// True while the consumer will poll again without being woken.
    awake: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
    /// The executors this consumer is fed by (set at start).
    execs: std.ArrayList(*Exec) = .empty,
    next_exec: usize = 0,
    stopped_sent: bool = false,
    /// When `poll` last ran (awake clock, ns), for the lost-wake check.
    last_poll: std.atomic.Value(i64) = .init(0),
    // Counters, for the spike's report.
    wakes: std.atomic.Value(u64) = .init(0),
    rewakes: std.atomic.Value(u64) = .init(0),
    polls: u64 = 0,
    delivered: u64 = 0,

    pub fn wake(c: *Consumer) void {
        // Cheap when the consumer is busy: one load of a line it rarely
        // writes.
        if (c.awake.load(.seq_cst)) return;
        if (c.awake.swap(true, .seq_cst)) return;
        _ = c.wakes.fetchAdd(1, .monotonic);
        if (c.wake_fn) |f| return f(c.wake_ud);
        if (have_fd and c.fd_write >= 0) {
            if (comptime builtin.os.tag == .linux) {
                const one: u64 = 1;
                _ = std.c.write(c.fd_write, std.mem.asBytes(&one), 8);
            } else {
                const b: u8 = 1;
                _ = std.c.write(c.fd_write, @ptrCast(&b), 1);
            }
        }
    }

    /// Rings again although the doorbell is up: the runtime lost the
    /// first ring (Bun 1.3's threadsafe functions drop calls; a loop
    /// shutting down drops call_soon_threadsafe). Any executor's sweeper.
    fn rewake(c: *Consumer) void {
        _ = c.rewakes.fetchAdd(1, .monotonic);
        if (c.wake_fn) |f| return f(c.wake_ud);
        c.awake.store(false, .seq_cst);
        c.wake();
    }

    fn drainFd(c: *Consumer) void {
        if (!have_fd or c.fd_read < 0) return;
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.c.read(c.fd_read, &buf, buf.len);
            if (n <= 0) return;
            if (comptime builtin.os.tag == .linux) return;
        }
    }

    pub fn openFd(c: *Consumer) !void {
        if (comptime builtin.os.tag == .linux) {
            const fd = std.c.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
            if (fd < 0) return error.SystemResources;
            c.fd_read = fd;
            c.fd_write = fd;
        } else if (comptime !have_fd) {
            return error.Unsupported;
        } else {
            var fds: [2]std.c.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.SystemResources;
            for (fds) |fd| {
                const fl = std.c.fcntl(fd, std.c.F.GETFL);
                _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
                _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            }
            c.fd_read = fds[0];
            c.fd_write = fds[1];
        }
    }

    pub fn deinit(c: *Consumer) void {
        if (have_fd) {
            if (c.fd_read >= 0) _ = std.c.close(c.fd_read);
            if (c.fd_write >= 0 and c.fd_write != c.fd_read) _ = std.c.close(c.fd_write);
        }
        c.execs.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Configuration (one JSON document)

pub const Config = struct {
    listeners: []const ListenerCfg = &.{.{}},
    /// 0: one per CPU.
    executors: u32 = 0,
    limits: Limits = .{},
    timeouts: Timeouts = .{},
    routes: []const RouteCfg = &.{},

    pub const ListenerCfg = struct {
        name: ?[]const u8 = null,
        address: []const u8 = "127.0.0.1",
        port: u16 = 0,
        h2c: bool = true,
    };
    pub const Limits = struct {
        /// Request bodies up to this size are read before the request is
        /// handed over, and delivered inline. Larger ones get 413 (spike).
        inline_body_max: u32 = 65536,
        /// Requests in flight in a consumer per executor; past it, 503.
        max_inflight: u32 = 1024,
        body_max: u32 = 1048576,
    };
    pub const Timeouts = struct {
        /// The consumer's deadline: 504 from Anole after it.
        request_ms: u32 = 30_000,
        shutdown_ms: u32 = 10_000,
        keepalive_ms: u32 = 60_000,
        /// A consumer with events waiting that has not polled for this
        /// long is woken again (a doorbell the language runtime lost).
        /// 0: never.
        rewake_ms: u32 = 20,
    };
    pub const RouteCfg = struct {
        method: ?[]const u8 = null,
        path: []const u8,
        /// The consumer's route id: the request goes to a consumer.
        handler: ?u32 = null,
        /// A fixed response, served without the consumer.
        respond: ?Fixed = null,
        /// Fixed responses only: run them where the protocol engine reads
        /// (HTTP/2, HTTP/3) rather than on a task of their own. On by
        /// default; off only to measure what a task costs.
        no_wait: bool = true,
    };
    pub const Fixed = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: std.json.ArrayHashMap([]const u8) = .{},
    };
};

pub const Route = struct {
    engine: *Engine,
    kind: union(enum) {
        consumer: u32,
        fixed: struct { status: http.Status, body: []const u8, headers: []const [2][]const u8 },
    },
};

// ---------------------------------------------------------------------------
// The engine: one per process.

pub const Phase = enum(u8) { created, starting, running, draining, stopped, failed };

pub var global: ?*Engine = null;

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    config: Config,
    routes: []Route,
    signals: bool,
    consumers: std.ArrayList(*Consumer) = .empty,
    execs: []Exec = &.{},
    thread: ?std.Thread = null,
    phase: std.atomic.Value(Phase) = .init(.created),
    /// Set by the anole main thread once listening (or failed); waited on
    /// by `start` with a plain threaded Io (no runtime yet).
    started: std.Io.Event = .unset,
    start_error: ?anyerror = null,
    stopped: std.Io.Event = .unset,
    app: ?*anole.App = null,
    /// The runtime's Io, for waking executor tasks from consumer threads
    /// (zio's futex wake is process-wide and works from any thread).
    io: std.Io = undefined,
    ports: std.ArrayList(u16) = .empty,
    /// One deadline sweeper per executor.
    sweepers: std.Io.Group = .init,
    deadline: std.Io.Duration,
    inline_body_max: u32,
    // Counters, for the spike's report.
    expired_count: std.atomic.Value(u64) = .init(0),
    gone_count: std.atomic.Value(u64) = .init(0),
    busy_count: std.atomic.Value(u64) = .init(0),

    pub fn create(json: []const u8, signals: bool, why: *std.Io.Writer) !*Engine {
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{
            .arena = .init(gpa),
            .config = undefined,
            .routes = &.{},
            .signals = signals,
            .deadline = undefined,
            .inline_body_max = 0,
        };
        errdefer e.arena.deinit();
        const a = e.arena.allocator();
        var diag: std.json.Diagnostics = .{};
        var scanner = std.json.Scanner.initCompleteInput(a, json);
        scanner.enableDiagnostics(&diag);
        e.config = std.json.parseFromTokenSourceLeaky(Config, a, &scanner, .{ .allocate = .alloc_always }) catch |err| {
            why.print("config: {t} at line {d} column {d}", .{ err, diag.getLine(), diag.getColumn() }) catch {};
            return error.Config;
        };
        if (e.config.listeners.len == 0) {
            why.writeAll("config: no listeners") catch {};
            return error.Config;
        }
        e.deadline = .fromMilliseconds(e.config.timeouts.request_ms);
        e.inline_body_max = e.config.limits.inline_body_max;
        e.routes = try a.alloc(Route, e.config.routes.len);
        for (e.config.routes, e.routes, 0..) |rc, *r, i| {
            if ((rc.handler == null) == (rc.respond == null)) {
                why.print("config: routes[{d}] needs exactly one of \"handler\" and \"respond\"", .{i}) catch {};
                return error.Config;
            }
            if (rc.method) |m| if (methodOf(m) == null) {
                why.print("config: routes[{d}].method \"{s}\" is unknown", .{ i, m }) catch {};
                return error.Config;
            };
            if (rc.handler) |id| {
                r.* = .{ .engine = e, .kind = .{ .consumer = id } };
            } else {
                const f = rc.respond.?;
                const status = http.Status.fromCode(f.status) catch {
                    why.print("config: routes[{d}].respond.status {d} is invalid", .{ i, f.status }) catch {};
                    return error.Config;
                };
                const hs = try a.alloc([2][]const u8, f.headers.map.count());
                var it = f.headers.map.iterator();
                var j: usize = 0;
                while (it.next()) |kv| : (j += 1) hs[j] = .{ kv.key_ptr.*, kv.value_ptr.* };
                r.* = .{ .engine = e, .kind = .{ .fixed = .{ .status = status, .body = f.body, .headers = hs } } };
            }
        }
        // One per process: the handlers and `respond` find it here.
        global = e;
        return e;
    }

    fn methodOf(name: []const u8) ?http.Method {
        var buf: [16]u8 = undefined;
        if (name.len > buf.len) return null;
        return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&buf, name));
    }

    pub fn attach(e: *Engine, wake_fn: ?WakeFn, wake_ud: ?*anyopaque) !*Consumer {
        if (e.phase.load(.acquire) != .created) return error.State;
        if (e.consumers.items.len >= 256) return error.State;
        const c = try gpa.create(Consumer);
        errdefer gpa.destroy(c);
        c.* = .{ .engine = e, .wake_fn = wake_fn, .wake_ud = wake_ud };
        if (wake_fn == null) try c.openFd();
        errdefer c.deinit();
        try e.consumers.append(gpa, c);
        return c;
    }

    pub fn start(e: *Engine) !void {
        if (e.phase.cmpxchgStrong(.created, .starting, .acq_rel, .acquire) != null) return error.State;
        e.thread = std.Thread.spawn(.{}, mainThread, .{e}) catch |err| {
            e.phase.store(.failed, .release);
            return err;
        };
        const tio = std.Io.Threaded.global_single_threaded.io();
        e.started.waitUncancelable(tio);
        if (e.start_error) |err| {
            e.thread.?.join();
            e.thread = null;
            return err;
        }
    }

    /// The anole main thread: owns the runtime (it becomes executor 0),
    /// serves until `drain`, then frees the server.
    fn mainThread(e: *Engine) void {
        const tio = std.Io.Threaded.global_single_threaded.io();
        const cfg = e.config;
        const a = e.arena.allocator();
        const listeners = a.alloc(anole.ServerOptions.Listener, cfg.listeners.len) catch |err| return e.failStart(err);
        for (cfg.listeners, listeners, 0..) |l, *out, i| out.* = .{
            .name = l.name orelse (std.fmt.allocPrint(a, "http{d}", .{i}) catch |err| return e.failStart(err)),
            .address = l.address,
            .port = l.port,
            .http2 = l.h2c and anole.features.http2,
        };
        var server_cfg: http.ServerConfig = .{};
        // Anole's own backstop, past the consumer deadline.
        server_cfg.timeout.request = .fromMilliseconds(@as(i64, cfg.timeouts.request_ms) + 5000);
        server_cfg.timeout.shutdown = .fromMilliseconds(cfg.timeouts.shutdown_ms);
        server_cfg.timeout.keepalive = .fromMilliseconds(cfg.timeouts.keepalive_ms);
        server_cfg.request.max_body_size = cfg.limits.body_max;
        var app = anole.App.init(gpa, .{
            .listeners = listeners,
            .executors = if (cfg.executors == 0) .auto else .exact(@intCast(cfg.executors)),
            .signals = e.signals,
            .raise_fd_limit = true,
            .server = server_cfg,
        }) catch |err| return e.failStart(err);
        e.app = &app;
        e.io = app.io();
        const nexec = app.rt.executors.items.len;
        if (nexec > 256) return e.failStartDeinit(&app, error.TooManyExecutors);
        e.setupExecs(nexec) catch |err| return e.failStartDeinit(&app, err);
        for (e.config.routes, e.routes) |rc, *r| {
            const method: ?http.Method = if (rc.method) |m| methodOf(m) else null;
            if (r.kind == .fixed)
                app.router.addRouteWith(method, rc.path, fixedHandler, .{ .data = r, .no_wait = rc.no_wait })
            else
                app.router.addRouteWith(method, rc.path, consumerHandler, .{ .data = r });
        }
        for (e.execs, 0..) |*x, i| placement.concurrent(&e.sweepers, app.io(), .{ .executor = i }, sweeper, .{ e, x, app.io() }) catch |err| {
            e.sweepers.cancel(app.io());
            return e.failStartDeinit(&app, err);
        };
        var watcher = app.io().concurrent(watchReady, .{ e, &app }) catch |err| return e.failStartDeinit(&app, err);
        e.phase.store(.running, .release);
        const result = app.run();
        watcher.cancel(app.io());
        e.sweepers.cancel(app.io());
        if (result) |_| {} else |err| {
            if (!e.started.isSet()) {
                e.start_error = err;
                e.started.set(tio);
            } else std.log.scoped(.anole).err("server stopped: {t}", .{err});
        }
        e.phase.store(.stopped, .release);
        e.app = null;
        app.deinit();
        // Every consumer hears of the stop (ANOLE_EV_STOPPED).
        for (e.consumers.items) |c| {
            c.awake.store(false, .seq_cst);
            c.wake();
        }
        e.stopped.set(tio);
    }

    fn watchReady(e: *Engine, app: *anole.App) void {
        const tio = std.Io.Threaded.global_single_threaded.io();
        app.waitReady() catch |err| {
            e.start_error = err;
            e.started.set(tio);
            return;
        };
        for (app.addresses()) |addr| e.ports.append(gpa, switch (addr) {
            .ip => |ip| ip.getPort(),
            else => 0,
        }) catch {};
        e.started.set(tio);
    }

    fn failStart(e: *Engine, err: anyerror) void {
        e.start_error = err;
        e.phase.store(.failed, .release);
        e.started.set(std.Io.Threaded.global_single_threaded.io());
    }

    fn failStartDeinit(e: *Engine, app: *anole.App, err: anyerror) void {
        e.app = null;
        app.deinit();
        e.failStart(err);
    }

    fn setupExecs(e: *Engine, n: usize) !void {
        const per = e.config.limits.max_inflight;
        e.execs = try gpa.alloc(Exec, n);
        for (e.execs, 0..) |*x, i| {
            x.* = .{ .index = @intCast(i), .slots = try gpa.alloc(Slot, per), .free_head = 0, .ring = try Ring.init(per * 2) };
            for (x.slots, 0..) |*s, j| s.* = .{ .next_free = if (j + 1 < per) @intCast(j + 1) else no_slot };
            if (e.consumers.items.len > 0) {
                const c = e.consumers.items[i % e.consumers.items.len];
                x.consumer = c;
                try c.execs.append(gpa, x);
            }
        }
    }

    pub fn drain(e: *Engine) !void {
        const p = e.phase.load(.acquire);
        if (p != .running) return if (p == .draining or p == .stopped) {} else error.State;
        e.phase.store(.draining, .release);
        if (e.app) |app| app.stop();
    }

    pub fn wait(e: *Engine) void {
        if (e.thread == null) return;
        e.stopped.waitUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn destroy(e: *Engine) void {
        if (e.thread) |t| {
            const p = e.phase.load(.acquire);
            if (p == .running) e.drain() catch {};
            t.join();
        }
        if (global == e) global = null;
        for (e.execs) |*x| {
            for (x.slots) |*s| {
                s.bytes.deinit(gpa);
                s.headers.deinit(gpa);
            }
            gpa.free(x.slots);
            x.ring.deinit();
        }
        gpa.free(e.execs);
        for (e.consumers.items) |c| {
            c.deinit();
            gpa.destroy(c);
        }
        e.consumers.deinit(gpa);
        e.ports.deinit(gpa);
        e.arena.deinit();
        gpa.destroy(e);
    }
};

// ---------------------------------------------------------------------------
// Handlers (on executors)

fn fixedHandler(req: *http.Request, res: *http.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const f = route.kind.fixed;
    res.status = f.status;
    for (f.headers) |h| try res.header(h[0], h[1]);
    res.body = f.body;
}

fn consumerHandler(req: *http.Request, res: *http.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const e = route.engine;
    const io = req.io;
    const xi = placement.currentExecutor(io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    const consumer = x.consumer orelse {
        res.fail(.service_unavailable, "no consumer");
        return;
    };
    // Small bodies come whole, read here on the executor.
    var body: []const u8 = "";
    if (req.content_length) |len| if (len > e.inline_body_max) {
        res.fail(.payload_too_large, "body too large for the spike's inline delivery");
        return;
    };
    if (try req.body()) |b| {
        if (b.len > e.inline_body_max) {
            res.fail(.payload_too_large, "body too large for the spike's inline delivery");
            return;
        }
        body = b;
    }
    const si = x.alloc() orelse {
        _ = e.busy_count.fetchAdd(1, .monotonic);
        res.fail(.service_unavailable, "too many requests in flight");
        return;
    };
    const slot = &x.slots[si];
    const gen = genOf(slot.word.load(.monotonic));
    slot.req = req;
    slot.route_id = route.kind.consumer;
    slot.body = body;
    slot.event.reset();
    slot.drained.store(false, .monotonic);
    slot.word.store(pack(gen, .queued), .release);
    const handle: Handle = .{ .gen = gen, .slot = @intCast(si), .exec = @intCast(xi) };
    x.link(io, si, std.Io.Clock.awake.now(io).nanoseconds + e.deadline.nanoseconds);

    // Hand over. A full ring (consumer far behind) is backpressure: wait
    // for room, up to the deadline.
    var canceled = false;
    while (!x.ring.push(handle.encode())) {
        if (slot.timed_out) break;
        zio.yield() catch {
            canceled = true;
            break;
        };
    }
    consumer.wake();

    // Wait for the reply, the deadline, or a cancel.
    const outcome: enum { done, expired } = while (true) {
        const w = slot.word.load(.acquire);
        std.debug.assert(genOf(w) == gen);
        switch (stateOf(w)) {
            .done => break .done,
            // Short windows on the consumer thread: let them finish.
            .polling, .responding => {
                zio.yield() catch {
                    canceled = true;
                };
                continue;
            },
            .queued, .out => {
                if (canceled or slot.timed_out) {
                    if (slot.word.cmpxchgStrong(w, pack(gen, .expired), .acq_rel, .acquire) == null) break .expired;
                    continue;
                }
                // No timer of its own: the executor's sweeper sets the
                // event at the deadline.
                slot.event.wait(io) catch {
                    canceled = true;
                };
            },
            .free, .expired => unreachable,
        }
    };

    switch (outcome) {
        .expired => {
            x.release(si);
            _ = e.expired_count.fetchAdd(1, .monotonic);
            if (canceled) return error.Canceled;
            res.fail(.gateway_timeout, "the application did not answer in time");
            return;
        },
        .done => {
            // Woken some other way (deadline, cancel) just as the reply
            // came: the slot is still on the done list, so it may not be
            // reused until the capi task has taken it.
            while (!slot.drained.load(.acquire)) zio.yield() catch {
                canceled = true;
            };
            if (canceled) io.recancel();
            defer x.release(si);
            res.status = http.Status.fromCode(slot.status) catch .internal_server_error;
            const bytes = slot.bytes.items;
            for (slot.headers.items) |h| {
                const name = try req.arena.dupe(u8, bytes[h.name_off..][0..h.name_len]);
                const value = try req.arena.dupe(u8, bytes[h.value_off..][0..h.value_len]);
                res.addHeader(name, value) catch {};
            }
            res.body = try req.arena.dupe(u8, bytes[slot.body_off..][0..slot.body_len]);
        },
    }
}

/// One per executor: sleeps until the oldest request out with a consumer
/// reaches its deadline, and wakes it to answer 504. With nothing out it
/// sleeps one request timeout: anything handed over meanwhile has a later
/// deadline than that.
fn sweeper(e: *Engine, x: *Exec, io: std.Io) void {
    while (true) {
        x.kick.reset();
        // Replies: wake their tasks (local wakes, no syscalls).
        var list = x.done_head.swap(no_slot, .acquire);
        while (list != no_slot) {
            const s = &x.slots[list];
            list = s.next_done;
            s.drained.store(true, .release);
            s.event.set(io);
        }
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        while (x.dl_head != no_slot) {
            const i = x.dl_head;
            const s = &x.slots[i];
            if (s.deadline > now) break;
            x.unlink(i);
            s.timed_out = true;
            s.event.set(io);
        }
        var until: i96 = if (x.dl_head != no_slot) x.slots[x.dl_head].deadline else now + e.deadline.nanoseconds;
        // Requests out: also watch for a lost doorbell, every rewake_ms.
        const rewake: i96 = @as(i96, e.config.timeouts.rewake_ms) * std.time.ns_per_ms;
        if (rewake > 0 and x.dl_head != no_slot) if (x.consumer) |c| {
            if (!x.ring.isEmpty() and c.awake.load(.acquire) and now - c.last_poll.load(.monotonic) > rewake) c.rewake();
            until = @min(until, now + rewake);
        };
        x.sweeper_idle = x.dl_head == no_slot;
        x.kick.waitTimeout(io, .{ .duration = .{ .raw = .{ .nanoseconds = until - now }, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return,
        };
    }
}

// ---------------------------------------------------------------------------
// Consumer side: poll and respond (on the consumer's thread)

pub const EventType = enum(u32) { request = 1, stopped = 11 };

pub const EventHeader = extern struct { type: u32, len: u32, handle: u64 };
pub const Span = extern struct { off: u32, len: u32 };
pub const RequestRecord = extern struct {
    ev: EventHeader,
    route_id: u32,
    method: u8,
    version: u8,
    flags: u16,
    method_name: Span,
    path: Span,
    query: Span,
    body: Span,
    nheaders: u16,
    nparams: u16,
    reserved: u32 = 0,
};
comptime {
    std.debug.assert(@sizeOf(EventHeader) == 16);
    std.debug.assert(@sizeOf(RequestRecord) == 64);
}

pub const req_flag_body_inline: u16 = 1;
pub const req_flag_secure: u16 = 4;

fn methodCode(m: http.Method) u8 {
    return switch (m) {
        .get => 1,
        .head => 2,
        .post => 3,
        .put => 4,
        .delete => 5,
        .connect => 6,
        .options => 7,
        .trace => 8,
        .patch => 9,
        else => 0,
    };
}

fn alignUp(n: usize) usize {
    return (n + 7) & ~@as(usize, 7);
}

/// The size of `slot`'s request record.
fn recordSize(slot: *const Slot) usize {
    const req = slot.req;
    var n: usize = @sizeOf(RequestRecord);
    const nh = req.headers.len;
    n += nh * 2 * @sizeOf(Span);
    n += req.params.count() * 2 * @sizeOf(Span);
    n += req.method.name().len + req.url.len + slot.body.len;
    for (req.headers.keys[0..nh], req.headers.values[0..nh]) |k, v| n += k.len + v.len;
    var it = req.params.map.iterator();
    while (it.next()) |kv| n += kv.key_ptr.len + kv.value_ptr.len;
    return alignUp(n);
}

fn encode(slot: *const Slot, handle: u64, out: []u8) usize {
    const req = slot.req;
    const size = out.len;
    const nh = req.headers.len;
    const np = req.params.count();
    var spans: [*]align(1) Span = @ptrCast(out[@sizeOf(RequestRecord)..].ptr);
    var pos: usize = @sizeOf(RequestRecord) + (nh + np) * 2 * @sizeOf(Span);
    const put = struct {
        fn f(buf: []u8, p: *usize, s: []const u8, lower: bool) Span {
            const at = p.*;
            if (lower) {
                for (s, buf[at..][0..s.len]) |ch, *d| d.* = std.ascii.toLower(ch);
            } else @memcpy(buf[at..][0..s.len], s);
            p.* += s.len;
            return .{ .off = @intCast(at), .len = @intCast(s.len) };
        }
    }.f;
    const url = req.url;
    const q = std.mem.indexOfScalar(u8, url, '?');
    const method_name = put(out, &pos, req.method.name(), false);
    const url_span = put(out, &pos, url, false);
    const path: Span = .{ .off = url_span.off, .len = @intCast(q orelse url.len) };
    const query: Span = if (q) |i| .{ .off = url_span.off + @as(u32, @intCast(i + 1)), .len = @intCast(url.len - i - 1) } else .{ .off = 0, .len = 0 };
    var k: usize = 0;
    for (req.headers.keys[0..nh], req.headers.values[0..nh]) |hk, hv| {
        spans[k] = put(out, &pos, hk, true);
        spans[k + 1] = put(out, &pos, hv, false);
        k += 2;
    }
    var it = req.params.map.iterator();
    while (it.next()) |kv| {
        spans[k] = put(out, &pos, kv.key_ptr.*, false);
        spans[k + 1] = put(out, &pos, kv.value_ptr.*, false);
        k += 2;
    }
    const body = put(out, &pos, slot.body, false);
    std.debug.assert(alignUp(pos) == size);
    @memset(out[pos..size], 0);
    const rec: *align(1) RequestRecord = @ptrCast(out.ptr);
    rec.* = .{
        .ev = .{ .type = @intFromEnum(EventType.request), .len = @intCast(size), .handle = handle },
        .route_id = slot.route_id,
        .method = methodCode(req.method),
        .version = req.version_major * 10 + req.version_minor,
        .flags = req_flag_body_inline | (if (req.secure) req_flag_secure else 0),
        .method_name = method_name,
        .path = path,
        .query = query,
        .body = body,
        .nheaders = @intCast(nh),
        .nparams = @intCast(np),
    };
    return size;
}

pub const PollError = error{ TooBig, State };

/// Drains up to `out.len` bytes of events. 0: nothing pending, and the
/// doorbell is armed again.
pub fn poll(c: *Consumer, out: []u8, arm: bool) PollError!usize {
    const e = c.engine;
    c.polls += 1;
    c.last_poll.store(@intCast(std.Io.Clock.awake.now(e.io).nanoseconds), .monotonic);
    var pos: usize = 0;
    var rechecked = false;
    outer: while (true) {
        var progressed = false;
        var i: usize = 0;
        while (i < c.execs.items.len) : (i += 1) {
            const x = c.execs.items[(c.next_exec + i) % c.execs.items.len];
            while (x.ring.peek()) |hv| {
                const h = Handle.decode(hv);
                const slot = &x.slots[h.slot];
                const queued = pack(h.gen, .queued);
                if (slot.word.cmpxchgStrong(queued, pack(h.gen, .polling), .acquire, .monotonic) != null) {
                    // Expired (or reused since): skip it.
                    x.ring.pop();
                    continue;
                }
                const size = recordSize(slot);
                if (size > out.len - pos) {
                    slot.word.store(queued, .release);
                    if (pos == 0) return error.TooBig;
                    c.next_exec = (c.next_exec + i) % c.execs.items.len;
                    break :outer;
                }
                pos += encode(slot, hv, out[pos..][0..size]);
                slot.word.store(pack(h.gen, .out), .release);
                x.ring.pop();
                c.delivered += 1;
                progressed = true;
            }
        }
        c.next_exec = (c.next_exec + 1) % @max(c.execs.items.len, 1);
        if (pos > 0 or progressed) break;
        if (e.phase.load(.acquire) == .stopped and !c.stopped_sent) {
            if (out.len < @sizeOf(EventHeader)) return error.TooBig;
            const hdr: *align(1) EventHeader = @ptrCast(out.ptr);
            hdr.* = .{ .type = @intFromEnum(EventType.stopped), .len = @sizeOf(EventHeader), .handle = 0 };
            c.stopped_sent = true;
            return @sizeOf(EventHeader);
        }
        if (rechecked or !arm) break;
        // Nothing: arm the doorbell, then look once more (a producer that
        // pushed before seeing `awake` false is found here).
        c.drainFd();
        c.awake.store(false, .seq_cst);
        rechecked = true;
        var any = false;
        for (c.execs.items) |x| if (!x.ring.isEmpty()) {
            any = true;
        };
        if (!any) break;
        // Found work: take the doorbell back (a wake may still come; it is
        // harmless).
        c.awake.store(true, .seq_cst);
        continue :outer;
    }
    return pos;
}

pub const RespondError = error{ Gone, Invalid, OutOfMemory };

pub const CHeader = extern struct { name: CStr, value: CStr };
pub const CStr = extern struct { ptr: ?[*]const u8, len: usize };

fn cslice(s: CStr) []const u8 {
    return if (s.ptr) |p| p[0..s.len] else "";
}

pub fn slotOf(e: *Engine, hv: u64) ?struct { *Slot, Handle } {
    const h = Handle.decode(hv);
    if (h.gen == 0 or h.exec >= e.execs.len) return null;
    const x = &e.execs[h.exec];
    if (h.slot >= x.slots.len) return null;
    return .{ &x.slots[h.slot], h };
}

pub fn respond(e: *Engine, hv: u64, status: u16, headers: []const CHeader, body: []const u8) RespondError!void {
    if (status < 100 or status > 999) return error.Invalid;
    const slot, const h = slotOf(e, hv) orelse return error.Gone;
    const out = pack(h.gen, .out);
    if (slot.word.cmpxchgStrong(out, pack(h.gen, .responding), .acquire, .monotonic) != null) {
        _ = e.gone_count.fetchAdd(1, .monotonic);
        return error.Gone;
    }
    errdefer slot.word.store(out, .release);
    var total: usize = body.len;
    for (headers) |hd| {
        total += hd.name.len + hd.value.len;
        dusty.validateHeaderName(cslice(hd.name)) catch return error.Invalid;
        dusty.validateHeaderValue(cslice(hd.value)) catch return error.Invalid;
    }
    if (total > std.math.maxInt(u32)) return error.Invalid;
    slot.bytes.clearRetainingCapacity();
    slot.headers.clearRetainingCapacity();
    try slot.bytes.ensureTotalCapacity(gpa, total);
    try slot.headers.ensureTotalCapacity(gpa, headers.len);
    for (headers) |hd| {
        const no: u32 = @intCast(slot.bytes.items.len);
        slot.bytes.appendSliceAssumeCapacity(cslice(hd.name));
        const vo: u32 = @intCast(slot.bytes.items.len);
        slot.bytes.appendSliceAssumeCapacity(cslice(hd.value));
        slot.headers.appendAssumeCapacity(.{ .name_off = no, .name_len = @intCast(hd.name.len), .value_off = vo, .value_len = @intCast(hd.value.len) });
    }
    slot.body_off = @intCast(slot.bytes.items.len);
    slot.body_len = @intCast(body.len);
    slot.bytes.appendSliceAssumeCapacity(body);
    slot.status = status;
    slot.word.store(pack(h.gen, .done), .release);
    // Onto the executor's done list; only the push that finds it empty
    // wakes the executor's capi task (one remote wake per burst).
    const x = &e.execs[h.exec];
    var old = x.done_head.load(.monotonic);
    while (true) {
        slot.next_done = old;
        old = x.done_head.cmpxchgWeak(old, h.slot, .release, .monotonic) orelse break;
    }
    if (old == no_slot) x.kick.set(e.io);
}
