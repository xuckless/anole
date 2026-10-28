//! The live console, server side (docs/console.md, design-console.md): a
//! control socket that `anole console` attaches to, process-wide log and
//! 5xx rings, per-route statistics collected only while attached, the
//! mutating commands, and the in-process terminal console. The terminal UI,
//! the wire protocol and the restart logic are the std-only module
//! `anole_console_ui`.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("anole_console_ui");
const logging = @import("anole_log");
const features = @import("build_options");
const modes = @import("../modes.zig");
const panic_mod = @import("../panic.zig");

pub const os = @import("os.zig");
pub const stats = @import("stats.zig");
pub const logring = @import("logring.zig");
pub const collector = @import("collector.zig");
pub const procinfo = @import("procinfo.zig");
pub const reexec = @import("reexec.zig");
pub const supervisor = @import("supervisor.zig");
pub const config_text = @import("config_text.zig");
pub const service = @import("service.zig");
pub const inprocess = @import("inprocess.zig");
pub const keys_dev = @import("keys_dev.zig");

/// The terminal UI module, for tests and the C ABI.
pub const protocol = ui.protocol;

/// `ServerOptions.console` (docs/console.md).
pub const Options = struct {
    /// The control socket. Null: on, except in tests, under deployment
    /// lambda, on Windows (not available yet) and with ANOLE_CONSOLE=0.
    enabled: ?bool = null,
    /// What `anole console <name>` finds this server by ([A-Za-z0-9._-],
    /// at most 48). Null: ANOLE_CONSOLE_NAME, else the executable's name.
    name: ?[]const u8 = null,
    /// The socket's path. Null: <runtime dir>/anole/<name>.<pid>.sock
    /// (docs/console.md says which directory).
    socket: ?[]const u8 = null,
    /// /restart and /full-restart. Null: on in development, off in production.
    allow_restart: ?bool = null,
    /// Refuse /reload, /drain, /restart and /full-restart.
    read_only: bool = false,
    /// `c` + Enter opens the console in this terminal. Null: on in
    /// development when stdin and stderr are terminals, outside systemd,
    /// containers and CI. An app that reads stdin itself sets false.
    keys: ?bool = null,
    /// Bytes of recent log records kept: warnings and errors always, every
    /// level while a console shows logs. 0: none.
    log_buffer: usize = 4 * 1024 * 1024,
    /// 5xx answers kept for /errors (16..4096).
    errors_kept: u16 = 256,
    /// Routes with latency numbers of their own; the rest are counted
    /// together as "(other routes)".
    max_routes: u16 = 256,
};

pub const Resolved = struct {
    enabled: bool,
    allow_restart: bool,
    read_only: bool,
    /// `Options.keys`, not yet checked against the terminal.
    keys: ?bool,
    name: ?[]const u8,
    socket: ?[]const u8,
    log_buffer: usize,
    errors_kept: u16,
    max_routes: u16,
};

pub const ResolveError = error{InvalidEnvironmentVariable};

fn truthy(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false")) return false;
    return null;
}

/// Pure over `modes.Vars` and the build, so it tests without a process.
pub fn resolve(opts: Options, vars: modes.Vars, environment: modes.Environment, deployment: modes.Deployment, build: modes.Build, why: *std.Io.Writer) ResolveError!Resolved {
    var env_on: ?bool = null;
    if (vars.any(vars.ctx, "ANOLE_CONSOLE")) |v| {
        env_on = truthy(v) orelse {
            why.print("ANOLE_CONSOLE=\"{s}\": use 1 or 0", .{v}) catch {};
            return error.InvalidEnvironmentVariable;
        };
    }
    const default_on = !(build.is_test or deployment == .lambda or builtin.os.tag == .windows);
    const enabled = opts.enabled orelse (env_on orelse default_on);
    var name = opts.name;
    if (name == null) name = vars.any(vars.ctx, "ANOLE_CONSOLE_NAME");
    return .{
        .enabled = enabled and builtin.os.tag != .windows,
        .allow_restart = opts.allow_restart orelse (environment == .development),
        .read_only = opts.read_only,
        .keys = opts.keys,
        .name = name,
        .socket = opts.socket,
        .log_buffer = opts.log_buffer,
        .errors_kept = std.math.clamp(opts.errors_kept, 16, 4096),
        .max_routes = @max(opts.max_routes, 1),
    };
}

// ---------------------------------------------------------------- Console

pub const StartParams = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    resolved: Resolved,
    host: service.Host,
    executors: u32,
    environment: []const u8,
    deployment: []const u8,
    runtime: ?[]const u8 = null,
    features: []const []const u8,
    has_tls: bool,
    /// Why /restart cannot hand over listeners (null: it can).
    restart_unavailable: ?[]const u8,
    /// The environment lookups for the socket directory.
    vars: modes.Vars = .process,
    /// Embedded in another runtime (the C ABI): no startup hint and no keys.
    embedded: bool = false,
};

pub const Console = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    resolved: Resolved,
    stats: *stats.Stats,
    logs: ?*logring.LogRing = null,
    service: *service.Service,
    launch: reexec.LaunchInfo,
    keys: ?*keys_dev.KeyReader = null,
    /// Where the socket is, once listening.
    socket_path: ?[]const u8 = null,
    /// A notice for the startup lines: why there is no socket.
    warning: ?[]const u8 = null,
    name: []const u8,

    /// Starts the console. A socket that cannot be set up is a warning (in
    /// `warning`), not an error: the in-process console still works.
    pub fn start(p: StartParams) !*Console {
        const gpa = p.gpa;
        const self = try gpa.create(Console);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .resolved = p.resolved,
            .stats = undefined,
            .service = undefined,
            .launch = undefined,
            .name = "",
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        self.stats = try gpa.create(stats.Stats);
        errdefer gpa.destroy(self.stats);
        self.stats.* = try stats.Stats.init(gpa, p.executors, p.resolved.max_routes, p.resolved.errors_kept);
        errdefer self.stats.deinit();

        self.launch = reexec.record(a, p.io) catch .{ .exe = "", .argv = &.{}, .cwd = "/", .env = &.{} };

        // The name: console.name, ANOLE_CONSOLE_NAME, else the executable's.
        const raw_name = p.resolved.name orelse std.fs.path.basename(self.launch.exe);
        var name_buf: [ui.discover.max_name]u8 = undefined;
        self.name = try a.dupe(u8, ui.discover.sanitizeName(&name_buf, if (raw_name.len == 0) "app" else raw_name));

        if (p.resolved.log_buffer > 0) {
            const lr = try gpa.create(logring.LogRing);
            lr.* = logring.LogRing.init(gpa, p.resolved.log_buffer);
            self.logs = lr;
        }
        errdefer if (self.logs) |lr| {
            lr.deinit();
            gpa.destroy(lr);
        };

        // What the hello says (design 5.3).
        const ro = p.resolved.read_only;
        const ar = p.resolved.allow_restart;
        var why: protocol.WhyNot = .{};
        if (ro) {
            why.reload = "the console is read-only";
            why.drain = "the console is read-only";
            why.restart = "the console is read-only";
            why.full_restart = "the console is read-only";
        } else {
            if (!p.has_tls) why.reload = "no TLS listener";
            if (!ar) {
                why.restart = "allow_restart is off (production): set console.allow_restart = true";
                why.full_restart = why.restart;
            } else if (p.restart_unavailable) |r| why.restart = r;
            if (!os.supported) why.full_restart = "not on Windows";
        }
        var sup_buf: [512]u8 = undefined;
        const sup = supervisor.detect(&sup_buf);
        var host_buf: [128]u8 = undefined;
        const started_ms = ui.sys.wallMs();
        var iso_buf: [32]u8 = undefined;
        const info: service.Info = .{
            .anole = features.version,
            .name = self.name,
            .started_iso = try a.dupe(u8, service.isoMs(&iso_buf, started_ms)),
            .host = try a.dupe(u8, os.hostname(&host_buf)),
            .environment = p.environment,
            .deployment = p.deployment,
            .build = switch (builtin.mode) {
                .debug => "Debug",
                .safe => "ReleaseSafe",
                .fast => "ReleaseFast",
                .small => "ReleaseSmall",
            },
            .executors = p.executors,
            .runtime = p.runtime orelse "zig " ++ builtin.zig_version_string,
            .allow = .{
                .reload = !ro and p.has_tls,
                .drain = !ro,
                .restart = !ro and ar and p.restart_unavailable == null,
                .full_restart = !ro and ar and os.supported,
            },
            .why_not = why,
            .supervisor = .{ .kind = @tagName(sup.kind), .detail = try a.dupe(u8, sup.detail) },
            .features = p.features,
            .started_ms = started_ms,
        };
        self.service = try service.Service.init(gpa, p.host, info, .{
            .read_only = ro,
            .allow_restart = ar,
            .restart_wait_ms = 15_000,
        }, self.stats, self.logs, &self.launch);
        errdefer self.service.deinit();

        stats.install(self.stats);
        if (self.logs) |lr| lr.install();
        panic_mod.before_panic = ui.term.restoreNow;

        self.setupSocket(a, p) catch |e| {
            if (self.warning == null) self.warning = std.fmt.allocPrint(a, "console: not available: {t}", .{e}) catch "console: not available";
        };
        return self;
    }

    fn setupSocket(self: *Console, a: std.mem.Allocator, p: StartParams) !void {
        const pid = ui.sys.getpid();
        var path_buf: [256]u8 = undefined;
        var path: []const u8 = undefined;
        var dir_buf: [256]u8 = undefined;
        if (self.resolved.socket) |explicit| {
            path = explicit;
            if (std.fs.path.dirname(explicit)) |d| {
                if (os.lstat(d) == null) _ = os.ensurePrivateDir(d, ui.sys.geteuid());
            }
        } else {
            const vars: ui.discover.Vars = .{
                .xdg_runtime_dir = p.vars.real(p.vars.ctx, "XDG_RUNTIME_DIR"),
                .tmpdir = p.vars.real(p.vars.ctx, "TMPDIR"),
                .uid = ui.sys.geteuid(),
                .linux = builtin.os.tag == .linux,
                .macos = builtin.os.tag.isDarwin(),
            };
            var dir = ui.discover.defaultDir(&dir_buf, vars) catch ui.discover.fallbackDir(&dir_buf, vars.uid) catch return error.NoDirectory;
            path = ui.discover.socketPath(&path_buf, dir, self.name, pid) catch blk: {
                dir = ui.discover.fallbackDir(&dir_buf, vars.uid) catch return error.NoDirectory;
                break :blk ui.discover.socketPath(&path_buf, dir, self.name, pid) catch return error.PathTooLong;
            };
            switch (os.ensurePrivateDir(dir, ui.sys.geteuid())) {
                .ok, .created => {},
                .missing_parent => return error.MissingParent,
                else => {
                    self.warning = try std.fmt.allocPrint(a, "console: not available: {s} is not a private directory of this user; set console.socket to a path in one", .{dir});
                    return error.NotPrivate;
                },
            }
            // Sockets of processes that are gone.
            if (ui.discover.list(self.gpa, std.Options.debug_io, dir, .{ .alive = alive })) |entries| {
                ui.discover.freeEntries(self.gpa, entries);
            } else |_| {}
        }
        // A file at our exact path carries our pid, so it is stale.
        os.unlink(path);
        try self.service.listen(path);
        self.socket_path = self.service.path;
    }

    fn alive(_: ?*anyopaque, pid: i32) bool {
        return ui.sys.pidAlive(pid);
    }

    pub fn attached(self: *const Console) u32 {
        return self.service.attachedCount();
    }

    /// The tap for log records from outside Anole's logger (the C ABI's
    /// `anole_console_log`).
    pub fn logRecord(self: *Console, level: std.log.Level, scope: []const u8, rid: []const u8, route: []const u8, text: []const u8) void {
        const lr = self.logs orelse return;
        if (@intFromEnum(level) > lr.tap.min_level.load(.monotonic)) return;
        lr.push(level, scope, rid, route, false, text);
    }

    /// Opens the terminal console in this process.
    pub fn openInProcess(self: *Console, on_closed: ?inprocess.Closed, ctx: ?*anyopaque) inprocess.OpenError!void {
        return inprocess.open(self.gpa, self.service, self.logs, on_closed, ctx);
    }

    pub fn closeInProcess(self: *Console) void {
        _ = self;
        inprocess.close();
    }

    /// Starts the stdin reader of the development hotkey.
    pub fn startKeys(self: *Console) !void {
        if (self.keys != null) return;
        self.keys = try keys_dev.KeyReader.start(.{ .ctx = self, .open = openFromKeys, .is_open = inprocess.isOpen });
    }

    fn openFromKeys(ctx: *anyopaque) void {
        const self: *Console = @ptrCast(@alignCast(ctx));
        self.openInProcess(null, null) catch |e| {
            std.log.scoped(.anole).warn("console: cannot open here: {t}", .{e});
        };
    }

    /// The server is draining: consoles get `bye`, the terminal comes back
    /// before the last log lines, the socket file goes. The log tap and the
    /// request hook are removed, but their memory stays until `release`:
    /// the drain that follows still logs and ends requests on executors
    /// that may have loaded them just before.
    pub fn stop(self: *Console, reason_drain: bool) void {
        if (self.keys) |k| k.stop();
        self.keys = null;
        if (reason_drain) self.service.bye_reason.store(1, .release);
        inprocess.close();
        stats.uninstall();
        if (self.logs) |lr| lr.uninstall();
        panic_mod.before_panic = null;
        self.service.stop();
    }

    /// Frees the console after `stop`, once no executor runs (the runtime
    /// is gone) and no C ABI call can still hold it.
    pub fn release(self: *Console) void {
        self.service.destroy();
        if (self.logs) |lr| {
            lr.deinit();
            self.gpa.destroy(lr);
        }
        self.stats.deinit();
        self.gpa.destroy(self.stats);
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

test {
    _ = os;
    _ = stats;
    _ = logring;
    _ = procinfo;
    _ = reexec;
    _ = supervisor;
    _ = config_text;
    _ = service;
    _ = inprocess;
    _ = keys_dev;
    _ = @import("console_test.zig");
    _ = @import("collector_test.zig");
}
