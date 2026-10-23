//! The console as a pure state machine (design 4.4): keys and frames go in,
//! requests for the server and a screen come out. No I/O and no clock: the
//! caller passes the time. Golden-frame tests drive this and nothing else.
const std = @import("std");
const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const screen = @import("screen.zig");
const stats_window = @import("stats_window.zig");
const restart_plan = @import("restart_plan.zig");
const views = @import("views.zig");

pub const Mode = enum { attach, in_process };

pub const ViewId = enum { logs, requests, errors, conns, db, ws, h3, runtime, config, routes, tasks, help };

pub const Link = enum { live, not_answering, exited };

/// What the run loop does after a key.
pub const Effect = enum { none, quit, back, interrupt };

/// A request the run loop should send (it assigns the id and calls
/// `registerSent`). Strings in a filter point into the app and are valid until
/// the next call into it.
pub const Outgoing = union(enum) {
    ping,
    snapshot: protocol.View,
    subscribe_logs: protocol.Filter,
    subscribe_stats,
    subscribe_errors,
    unsubscribe: u32,
    op: struct { name: []const u8, confirm: ?[]const u8 },
    /// `/full-restart` when the app does not answer or with --kill (CLI only).
    full_restart_kill: struct { send_kill: bool, then: restart_plan.KillThen },
};

pub const Command = struct { name: []const u8, usage: []const u8, desc: []const u8 };

pub const commands = [_]Command{
    .{ .name = "config", .usage = "/config", .desc = "resolved settings, with secrets redacted" },
    .{ .name = "conns", .usage = "/conns", .desc = "connections, streams and tasks per executor" },
    .{ .name = "db", .usage = "/db [name]", .desc = "database pools and call latency" },
    .{ .name = "drain", .usage = "/drain", .desc = "stop accepting, finish open requests, then stop the server" },
    .{ .name = "errors", .usage = "/errors [route=<pattern>]", .desc = "the last 5xx answers" },
    .{ .name = "exit", .usage = "/exit", .desc = "leave the console" },
    .{ .name = "full-restart", .usage = "/full-restart [--kill]", .desc = "drop everything and restart the process" },
    .{ .name = "h3", .usage = "/h3", .desc = "HTTP/3 endpoints" },
    .{ .name = "help", .usage = "/help [command]", .desc = "this list, or one command" },
    .{ .name = "logs", .usage = "/logs [level=] [scope=] [route=] [id=] [grep=]", .desc = "live log tail with server-side filters" },
    .{ .name = "quit", .usage = "/quit", .desc = "leave the console" },
    .{ .name = "reload", .usage = "/reload", .desc = "reload TLS certificates from their files" },
    .{ .name = "requests", .usage = "/requests [sort=rps|p50|p99|errors|route] [window=10s|60s]", .desc = "req/s, p50 and p99 per route" },
    .{ .name = "restart", .usage = "/restart", .desc = "hand over to a new process without dropping connections" },
    .{ .name = "routes", .usage = "/routes [text]", .desc = "registered routes" },
    .{ .name = "runtime", .usage = "/runtime", .desc = "process, memory, descriptors and language metrics" },
    .{ .name = "tasks", .usage = "/tasks", .desc = "per-task view (needs a task registry in the runtime; not available yet)" },
    .{ .name = "ws", .usage = "/ws", .desc = "WebSockets, WebTransport, rooms and topics" },
};

pub const LogLine = struct {
    time: [12]u8, // HH:MM:SS.mmm
    level: Level,
    scope: []u8,
    request_id: []u8,
    text: []u8,
};

pub const Level = enum { err, warn, info, debug, other };

pub const ErrorLine = struct {
    time: [8]u8, // HH:MM:SS
    status: u16,
    method: []u8,
    path: []u8,
    route: []u8,
    err: []u8,
    request_id: []u8,
    duration_us: u64,
};

pub const Sort = enum { rps, p50, p99, errors, route };

const Expect = union(enum) { snapshot: protocol.View, sub_logs, sub_stats, sub_errors, op: []const u8, other };

pub const Pending = struct {
    prompt: []const u8,
    out: Outgoing,
};

pub const max_log_lines = 5000;
pub const max_error_lines = 256;
pub const history_max = 100;
pub const min_cols = 60;
pub const min_rows = 12;

pub const App = struct {
    gpa: std.mem.Allocator,
    mode: Mode,
    hello: protocol.Hello,

    view: ViewId = .logs,
    // Time as the caller reports it.
    now_ms: i64 = 0,
    wall_ms: i64 = 0,
    started_wall_ms: ?i64 = null,
    last_heard_ms: i64 = 0,
    wedge_ms: u32 = 5000,
    server_gone: bool = false,
    gone_reason: []const u8 = "",
    restarting: ?[]const u8 = null,
    have_launch_info: bool = false,
    exec_supported: bool = true,
    /// The terminal shows colour (not NO_COLOR): picks the coloured or the
    /// plain anole for the splash.
    color: bool = true,

    // Subscriptions.
    logs_sub: ?u32 = null,
    stats_sub: ?u32 = null,
    errors_sub: ?u32 = null,
    expect: std.ArrayList(struct { id: u32, what: Expect }) = .empty,
    outbox: std.ArrayList(Outgoing) = .empty,
    last_snap_ms: i64 = -1_000_000,

    // Logs.
    lines: std.ArrayList(LogLine) = .empty,
    lines_head: usize = 0,
    dropped: u64 = 0,
    scroll: usize = 0,
    log_filter_storage: [5]?[]u8 = @splat(null), // level scope route id grep
    errors: std.ArrayList(ErrorLine) = .empty,
    err_sel: usize = 0,

    // Stats.
    window: stats_window.Window,
    sort: Sort = .rps,
    window_ms: i64 = 10_000,
    route_filter: ?[]u8 = null, // /errors route=, /routes text, /db name

    // Snapshots.
    arenas: [9]std.heap.ArenaAllocator,
    conns: ?protocol.ConnsData = null,
    db: ?protocol.DbData = null,
    ws: ?protocol.WsData = null,
    h3: ?views.H3Table = null,
    runtime: ?protocol.RuntimeData = null,
    config: ?protocol.ConfigData = null,
    routes: ?protocol.RoutesData = null,
    errors_snap_seen: bool = false,

    // Command line.
    input: std.ArrayList(u8) = .empty,
    history: std.ArrayList([]u8) = .empty,
    hist_pos: ?usize = null,
    popup_closed: bool = false,
    popup_sel: usize = 0,
    pending: ?Pending = null,
    notice: ?[]u8 = null,
    help_topic: ?[]u8 = null,
    want_full: bool = false,

    // Scratch for one draw.
    draw_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator, mode: Mode, hello: protocol.Hello) App {
        var a: App = .{
            .gpa = gpa,
            .mode = mode,
            .hello = hello,
            .window = stats_window.Window.init(gpa),
            .arenas = undefined,
            .draw_arena = .init(gpa),
        };
        for (&a.arenas) |*ar| ar.* = .init(gpa);
        if (hello.app) |ap| a.started_wall_ms = parseIso(ap.started);
        return a;
    }

    pub fn deinit(self: *App) void {
        const gpa = self.gpa;
        for (self.lines.items[self.lines_head..]) |l| freeLine(gpa, l);
        self.lines.deinit(gpa);
        for (self.errors.items) |e| freeError(gpa, e);
        self.errors.deinit(gpa);
        for (self.log_filter_storage) |f| if (f) |s| gpa.free(s);
        if (self.route_filter) |s| gpa.free(s);
        self.window.deinit();
        for (&self.arenas) |*ar| ar.deinit();
        self.expect.deinit(gpa);
        self.outbox.deinit(gpa);
        self.input.deinit(gpa);
        for (self.history.items) |h| gpa.free(h);
        self.history.deinit(gpa);
        if (self.notice) |n| gpa.free(n);
        if (self.help_topic) |n| gpa.free(n);
        self.draw_arena.deinit();
    }

    // ---------------------------------------------------------------- time

    /// The run loop calls this every turn. Refreshes the snapshot views.
    pub fn tick(self: *App, now_ms: i64, wall_ms: i64) void {
        self.now_ms = now_ms;
        self.wall_ms = wall_ms;
        if (self.server_gone) return;
        const snap: ?protocol.View = switch (self.view) {
            .conns => .conns,
            .db => .db,
            .ws => .ws,
            .h3 => .h3,
            .runtime => .runtime,
            else => null,
        };
        if (snap) |v| {
            if (now_ms - self.last_snap_ms >= 1000) {
                self.last_snap_ms = now_ms;
                self.queue(.{ .snapshot = v });
            }
        }
    }

    /// Something arrived from the server.
    pub fn heard(self: *App, now_ms: i64) void {
        self.last_heard_ms = now_ms;
        self.now_ms = now_ms;
    }

    pub fn link(self: *const App) Link {
        if (self.server_gone) return .exited;
        if (restart_plan.wedged(self.now_ms, self.last_heard_ms, self.wedge_ms)) return .not_answering;
        return .live;
    }

    /// Requests to send at attach, in order.
    pub fn start(self: *App) void {
        self.queue(.subscribe_stats);
        self.queue(.subscribe_errors);
        self.queue(.{ .subscribe_logs = self.logFilter() });
    }

    pub fn takeOutgoing(self: *App) []const Outgoing {
        // Valid until the next queue(): the caller sends them at once.
        return self.outbox.items;
    }

    pub fn clearOutgoing(self: *App) void {
        self.outbox.clearRetainingCapacity();
    }

    fn queue(self: *App, o: Outgoing) void {
        self.outbox.append(self.gpa, o) catch {};
    }

    /// The run loop reports the id it gave a request.
    pub fn registerSent(self: *App, id: u32, o: Outgoing) void {
        const what: Expect = switch (o) {
            .snapshot => |v| .{ .snapshot = v },
            .subscribe_logs => .sub_logs,
            .subscribe_stats => .sub_stats,
            .subscribe_errors => .sub_errors,
            .op => |op| .{ .op = op.name },
            else => .other,
        };
        if (self.expect.items.len >= 64) _ = self.expect.orderedRemove(0);
        self.expect.append(self.gpa, .{ .id = id, .what = what }) catch {};
    }

    // -------------------------------------------------------------- frames

    pub fn frame(self: *App, f: protocol.Frame) void {
        switch (f) {
            .res => |r| self.onResponse(r),
            .log => |l| if (self.logs_sub != null and l.sub == self.logs_sub.?) self.addLog(l),
            .dropped => |d| if (self.logs_sub != null and d.sub == self.logs_sub.?) {
                self.dropped += d.n;
            },
            .stats => |s| if (self.stats_sub != null and s.sub == self.stats_sub.?) {
                self.window.push(s) catch {};
            },
            .error5xx => |e| if (self.errors_sub != null and e.sub == self.errors_sub.?) self.addError(e),
            .restarting => |r| {
                self.restarting = r.mode;
                self.setNotice("restarting ({s})...", .{r.mode});
            },
            .bye => |b| {
                self.server_gone = true;
                self.gone_reason = if (std.mem.eql(u8, b.reason, "drain")) "drain" else "stop";
            },
            .err => |e| self.setNotice("{s}: {s}", .{ e.code, e.message orelse "" }),
            .hello, .req, .unknown => {},
        }
    }

    /// The connection ended without a bye.
    pub fn connectionClosed(self: *App) void {
        self.server_gone = true;
    }

    fn onResponse(self: *App, r: protocol.Response) void {
        var what: Expect = .other;
        for (self.expect.items, 0..) |e, i| {
            if (e.id == r.id) {
                what = e.what;
                _ = self.expect.orderedRemove(i);
                break;
            }
        }
        switch (what) {
            .snapshot => |v| {
                if (!r.ok) {
                    if (r.code != null and std.mem.eql(u8, r.code.?, protocol.code_unavailable)) {
                        self.setNotice("/{s}: {s}", .{ @tagName(v), r.message orelse "not available" });
                    }
                    return;
                }
                self.ingestSnapshot(v, r.data);
            },
            .sub_logs, .sub_stats, .sub_errors => {
                if (!r.ok) return self.setNotice("subscribe failed: {s}", .{r.message orelse r.code orelse ""});
                const sub = subOf(r.data) orelse return;
                switch (what) {
                    .sub_logs => self.logs_sub = sub,
                    .sub_stats => self.stats_sub = sub,
                    else => self.errors_sub = sub,
                }
            },
            .op => |name| {
                if (!r.ok) return self.setNotice("{s} refused: {s}", .{ name, r.message orelse r.code orelse "" });
                if (std.mem.eql(u8, name, "reload")) {
                    const n: i64 = if (r.data) |d| intField(d, "certificates") orelse 0 else 0;
                    self.setNotice("reloaded {d} certificate(s)", .{n});
                } else if (std.mem.eql(u8, name, "restart")) {
                    const n: i64 = if (r.data) |d| intField(d, "successor_pid") orelse 0 else 0;
                    self.setNotice("handed over to pid {d}", .{n});
                } else if (std.mem.eql(u8, name, "drain")) {
                    self.setNotice("draining: the server stops when open requests finish", .{});
                }
            },
            .other => {},
        }
    }

    fn ingestSnapshot(self: *App, v: protocol.View, data: ?std.json.Value) void {
        const idx = @intFromEnum(v);
        _ = self.arenas[idx].reset(.retain_capacity);
        const a = self.arenas[idx].allocator();
        switch (v) {
            .conns => self.conns = protocol.decodeData(protocol.ConnsData, a, data) catch null,
            .db => self.db = protocol.decodeData(protocol.DbData, a, data) catch null,
            .ws => self.ws = protocol.decodeData(protocol.WsData, a, data) catch null,
            .h3 => self.h3 = views.H3Table.fromData(a, data) catch null,
            .runtime => self.runtime = protocol.decodeData(protocol.RuntimeData, a, data) catch null,
            .config => self.config = protocol.decodeData(protocol.ConfigData, a, data) catch null,
            .routes => self.routes = protocol.decodeData(protocol.RoutesData, a, data) catch null,
            .errors => {
                const d = protocol.decodeData(protocol.ErrorsData, a, data) catch return;
                if (self.errors_snap_seen) return;
                self.errors_snap_seen = true;
                // Oldest first, so the newest ends up last.
                for (d.entries) |e| self.addError(e);
            },
            .tasks => {},
        }
    }

    fn addLog(self: *App, l: protocol.Log) void {
        const gpa = self.gpa;
        var line: LogLine = undefined;
        line.time = @splat(' ');
        if (l.time.len >= 23) @memcpy(&line.time, l.time[11..23]);
        line.level = levelOf(l.level);
        line.scope = gpa.dupe(u8, l.scope) catch return;
        line.request_id = gpa.dupe(u8, l.request_id) catch return;
        line.text = (if (l.json) jsonText(gpa, l.text) else gpa.dupe(u8, l.text)) catch return;
        self.lines.append(gpa, line) catch return;
        if (self.scroll > 0) self.scroll += 1; // keep what the user is reading in place
        const live = self.lines.items.len - self.lines_head;
        if (live > max_log_lines) {
            freeLine(gpa, self.lines.items[self.lines_head]);
            self.lines_head += 1;
            if (self.lines_head >= 1024) {
                const rest = self.lines.items[self.lines_head..];
                std.mem.copyForwards(LogLine, self.lines.items[0..rest.len], rest);
                self.lines.shrinkRetainingCapacity(rest.len);
                self.lines_head = 0;
            }
        }
    }

    pub fn logLines(self: *const App) []const LogLine {
        return self.lines.items[self.lines_head..];
    }

    fn addError(self: *App, e: protocol.Error5xx) void {
        const gpa = self.gpa;
        var line: ErrorLine = undefined;
        line.time = @splat(' ');
        if (e.time.len >= 19) @memcpy(&line.time, e.time[11..19]);
        line.status = e.status;
        line.duration_us = e.duration_us;
        line.method = gpa.dupe(u8, e.method) catch return;
        line.path = gpa.dupe(u8, e.path) catch return;
        line.route = gpa.dupe(u8, e.route) catch return;
        line.err = gpa.dupe(u8, e.@"error") catch return;
        line.request_id = gpa.dupe(u8, e.request_id) catch return;
        self.errors.append(gpa, line) catch return;
        if (self.errors.items.len > max_error_lines) {
            freeError(gpa, self.errors.orderedRemove(0));
            if (self.err_sel > 0) self.err_sel -= 1;
        }
    }

    // ---------------------------------------------------------------- keys

    pub fn key(self: *App, k: keys.Key) Effect {
        // A pending confirmation takes the next key.
        if (self.pending) |p| {
            self.pending = null;
            switch (k) {
                .char => |c| if (c == 'y' or c == 'Y') {
                    self.queue(p.out);
                    self.setNotice("sent", .{});
                    return .none;
                },
                else => {},
            }
            self.setNotice("cancelled", .{});
            return .none;
        }
        switch (k) {
            .ctrl => |c| switch (c) {
                'c' => return if (self.mode == .in_process) .interrupt else .quit,
                'l' => self.want_full = true,
                else => {},
            },
            .char => |c| {
                self.typed(c);
                self.clearNotice();
            },
            .paste => |text| {
                for (text) |b| if (b != '\n' and b != '\r') self.input.append(self.gpa, b) catch {};
                self.afterEdit();
            },
            .backspace => {
                self.popBack();
                self.afterEdit();
            },
            .tab => self.complete(),
            .enter => return self.enter(),
            .escape => {
                if (self.popupItems().len > 0) {
                    self.popup_closed = true;
                } else if (self.input.items.len > 0) {
                    self.input.clearRetainingCapacity();
                    self.afterEdit();
                } else if (self.mode == .in_process) return .back;
            },
            .up => {
                if (self.popupItems().len > 0) {
                    if (self.popup_sel > 0) self.popup_sel -= 1;
                } else self.historyMove(-1);
            },
            .down => {
                if (self.popupItems().len > 0) {
                    self.popup_sel += 1;
                } else self.historyMove(1);
            },
            .page_up => self.scrollBy(-1),
            .page_down => self.scrollBy(1),
            .home => self.scrollTo(true),
            .end => self.scrollTo(false),
            else => {},
        }
        return .none;
    }

    fn typed(self: *App, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        if (self.input.items.len + n > 4096) return;
        self.input.appendSlice(self.gpa, buf[0..n]) catch return;
        self.afterEdit();
    }

    fn popBack(self: *App) void {
        var n = self.input.items.len;
        if (n == 0) return;
        n -= 1;
        while (n > 0 and self.input.items[n] & 0xc0 == 0x80) n -= 1;
        self.input.shrinkRetainingCapacity(n);
    }

    fn afterEdit(self: *App) void {
        self.popup_closed = false;
        self.popup_sel = 0;
        self.hist_pos = null;
        self.scroll = 0;
    }

    fn scrollBy(self: *App, dir: i32) void {
        const page: usize = 10;
        switch (self.view) {
            .errors => {
                if (dir < 0) self.err_sel -|= 1 else if (self.err_sel + 1 < self.errors.items.len) self.err_sel += 1;
            },
            else => {
                if (dir < 0) self.scroll += page else self.scroll -|= page;
            },
        }
    }

    fn scrollTo(self: *App, top: bool) void {
        if (self.view == .errors) {
            self.err_sel = if (top) 0 else self.errors.items.len -| 1;
            return;
        }
        self.scroll = if (top) std.math.maxInt(usize) / 2 else 0;
    }

    fn historyMove(self: *App, dir: i32) void {
        const n = self.history.items.len;
        if (n == 0) return;
        var pos: usize = undefined;
        if (self.hist_pos) |p| {
            if (dir < 0) {
                pos = if (p > 0) p - 1 else 0;
            } else {
                if (p + 1 >= n) {
                    self.hist_pos = null;
                    self.input.clearRetainingCapacity();
                    self.popup_closed = false;
                    return;
                }
                pos = p + 1;
            }
        } else {
            if (dir > 0) return;
            pos = n - 1;
        }
        self.hist_pos = pos;
        self.input.clearRetainingCapacity();
        self.input.appendSlice(self.gpa, self.history.items[pos]) catch {};
        self.popup_closed = true; // a recalled line is not completed
    }

    // ------------------------------------------------------------ commands

    /// The commands the popup shows: those starting with what has been typed
    /// after the slash; none once there is a space or no slash.
    pub fn popupItems(self: *const App) []const Command {
        if (self.popup_closed) return &.{};
        const in = self.input.items;
        if (in.len == 0 or in[0] != '/') return &.{};
        if (std.mem.indexOfScalar(u8, in, ' ') != null) return &.{};
        const prefix = in[1..];
        var first: usize = commands.len;
        var end: usize = 0;
        for (commands, 0..) |c, i| {
            if (std.mem.startsWith(u8, c.name, prefix)) {
                if (first == commands.len) first = i;
                end = i + 1;
            }
        }
        if (first >= end) return &.{};
        return commands[first..end];
    }

    fn complete(self: *App) void {
        const items = self.popupItems();
        if (items.len == 0) return;
        const c = items[@min(self.popup_sel, items.len - 1)];
        self.input.clearRetainingCapacity();
        self.input.append(self.gpa, '/') catch return;
        self.input.appendSlice(self.gpa, c.name) catch return;
        self.input.append(self.gpa, ' ') catch return;
        self.popup_sel = 0;
    }

    fn enter(self: *App) Effect {
        // With the popup open, Enter on a partial command completes it first.
        const items = self.popupItems();
        if (items.len > 0) {
            var exact = false;
            for (items) |c| if (std.mem.eql(u8, self.input.items[1..], c.name)) {
                exact = true;
            };
            if (!exact) self.complete();
        }
        const line = std.mem.trim(u8, self.input.items, " ");
        if (line.len == 0) {
            if (self.view == .errors and self.err_sel < self.errors.items.len) {
                const e = self.errors.items[self.err_sel];
                if (e.request_id.len > 0) self.openLogs(.{ .request_id = e.request_id });
            }
            return .none;
        }
        // History (dedupe the last entry).
        if (self.history.items.len == 0 or !std.mem.eql(u8, self.history.items[self.history.items.len - 1], line)) {
            if (self.gpa.dupe(u8, line)) |copy| {
                self.history.append(self.gpa, copy) catch self.gpa.free(copy);
                if (self.history.items.len > history_max) self.gpa.free(self.history.orderedRemove(0));
            } else |_| {}
        }
        const owned = self.gpa.dupe(u8, line) catch return .none;
        defer self.gpa.free(owned);
        self.input.clearRetainingCapacity();
        self.hist_pos = null;
        self.popup_sel = 0;
        self.popup_closed = false;
        if (owned[0] != '/') {
            // Not a command: filter the current view.
            self.setFilterText(owned);
            return .none;
        }
        return self.run(owned[1..]);
    }

    fn setFilterText(self: *App, text: []const u8) void {
        if (self.route_filter) |s| self.gpa.free(s);
        self.route_filter = self.gpa.dupe(u8, text) catch null;
        self.setNotice("filter: {s} (/{s} clears it)", .{ text, @tagName(self.view) });
    }

    fn run(self: *App, cmd_line: []const u8) Effect {
        var it = std.mem.tokenizeScalar(u8, cmd_line, ' ');
        const name = it.next() orelse return .none;
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.gpa);
        while (it.next()) |a| args.append(self.gpa, a) catch {};
        const A = args.items;
        const eq = std.mem.eql;
        self.scroll = 0;
        self.clearNotice();
        if (eq(u8, name, "quit") or eq(u8, name, "exit")) return .quit;
        if (eq(u8, name, "logs")) {
            self.cmdLogs(A);
        } else if (eq(u8, name, "requests")) {
            self.cmdRequests(A);
        } else if (eq(u8, name, "errors")) {
            self.setFilterFromArgs(A, "route=");
            self.switchView(.errors);
            self.queue(.{ .snapshot = .errors });
        } else if (eq(u8, name, "conns")) {
            self.switchView(.conns);
        } else if (eq(u8, name, "db")) {
            self.setFilterFromArgs(A, "");
            self.switchView(.db);
        } else if (eq(u8, name, "ws")) {
            self.switchView(.ws);
        } else if (eq(u8, name, "h3")) {
            self.switchView(.h3);
        } else if (eq(u8, name, "runtime")) {
            self.switchView(.runtime);
        } else if (eq(u8, name, "config")) {
            self.switchView(.config);
            self.queue(.{ .snapshot = .config });
        } else if (eq(u8, name, "routes")) {
            self.setFilterFromArgs(A, "");
            self.switchView(.routes);
            self.queue(.{ .snapshot = .routes });
        } else if (eq(u8, name, "tasks")) {
            self.switchView(.tasks);
        } else if (eq(u8, name, "help")) {
            if (self.help_topic) |h| self.gpa.free(h);
            self.help_topic = if (A.len > 0) self.gpa.dupe(u8, std.mem.trimStart(u8, A[0], "/")) catch null else null;
            self.switchView(.help);
        } else if (eq(u8, name, "reload")) {
            if (self.denied("reload", self.hello.allow orelse .{}, self.hello.why_not)) return .none;
            self.queue(.{ .op = .{ .name = "reload", .confirm = null } });
        } else if (eq(u8, name, "drain")) {
            if (self.denied("drain", self.hello.allow orelse .{}, self.hello.why_not)) return .none;
            self.askConfirm("Drain and stop {s} (pid {d})? Open requests get up to 10 s. [y/N]", .{ .op = .{ .name = "drain", .confirm = protocol.confirm_drain } });
        } else if (eq(u8, name, "restart")) {
            if (self.denied("restart", self.hello.allow orelse .{}, self.hello.why_not)) return .none;
            self.askConfirm("Hand {s} (pid {d}) over to a new process without dropping connections? [y/N]", .{ .op = .{ .name = "restart", .confirm = protocol.confirm_restart } });
        } else if (eq(u8, name, "full-restart")) {
            self.cmdFullRestart(A);
        } else {
            self.setNotice("unknown command /{s}; /help lists them", .{name});
        }
        return .none;
    }

    fn denied(self: *App, op: []const u8, allow: protocol.Allow, why: ?protocol.WhyNot) bool {
        const ok = if (std.mem.eql(u8, op, "reload")) allow.reload else if (std.mem.eql(u8, op, "drain")) allow.drain else allow.restart;
        if (ok) return false;
        var reason: ?[]const u8 = null;
        if (why) |w| reason = if (std.mem.eql(u8, op, "restart")) w.restart else if (std.mem.eql(u8, op, "reload")) w.reload else w.drain;
        self.setNotice("/{s} is not available: {s}", .{ op, reason orelse "refused by the app (read-only console)" });
        return true;
    }

    fn appName(self: *const App) []const u8 {
        return if (self.hello.app) |a| a.name else "app";
    }

    fn appPid(self: *const App) i32 {
        return if (self.hello.app) |a| a.pid else 0;
    }

    fn askConfirm(self: *App, comptime fmt: []const u8, out: Outgoing) void {
        const text = std.fmt.allocPrint(self.draw_arena.allocator(), fmt, .{ self.appName(), self.appPid() }) catch return;
        // Keep the prompt past the next draw's arena reset.
        self.pending = .{ .prompt = self.persist(text), .out = out };
    }

    fn persist(self: *App, s: []const u8) []const u8 {
        // Prompts are short; keep them in the snapshot arena of `tasks` (unused).
        return self.arenas[@intFromEnum(protocol.View.tasks)].allocator().dupe(u8, s) catch "";
    }

    fn cmdFullRestart(self: *App, args: []const []const u8) void {
        var kill = false;
        for (args) |a| if (std.mem.eql(u8, a, "--kill")) {
            kill = true;
        };
        const allow = self.hello.allow orelse protocol.Allow{};
        const sup = self.hello.supervisor orelse protocol.Supervisor{};
        const plan = restart_plan.plan(.{
            .allowed = allow.full_restart,
            .in_process = self.mode == .in_process,
            .force_kill = kill,
            .responsive = self.link() == .live,
            .pid_alive = true,
            .supervisor = std.meta.stringToEnum(restart_plan.Supervisor, sup.kind) orelse .none,
            .have_launch_info = self.have_launch_info,
            .exec_supported = self.exec_supported,
        });
        switch (plan) {
            .refuse => |r| self.setNotice("/full-restart: {s}", .{restart_plan.refusalText(r)}),
            .exec_in_place => self.askConfirm("Drop every connection and restart {s} (pid {d}) in place? [y/N]", .{ .op = .{ .name = "full_restart", .confirm = protocol.confirm_full_restart } }),
            .kill => |k| self.askConfirm("Kill {s} (pid {d}) and start it again? Every connection is dropped. [y/N]", .{ .full_restart_kill = .{ .send_kill = k.send_kill, .then = k.then } }),
        }
    }

    const FilterKeys = struct { level: ?[]const u8 = null, scope: ?[]const u8 = null, route: ?[]const u8 = null, id: ?[]const u8 = null, grep: ?[]const u8 = null };

    fn cmdLogs(self: *App, args: []const []const u8) void {
        var f: FilterKeys = .{};
        for (args) |a| {
            const eqi = std.mem.indexOfScalar(u8, a, '=') orelse continue;
            const k = a[0..eqi];
            const v = a[eqi + 1 ..];
            if (std.mem.eql(u8, k, "level")) f.level = v else if (std.mem.eql(u8, k, "scope")) f.scope = v else if (std.mem.eql(u8, k, "route")) f.route = v else if (std.mem.eql(u8, k, "id")) f.id = v else if (std.mem.eql(u8, k, "grep")) f.grep = v;
        }
        self.openLogs(.{ .level = f.level, .scope = f.scope, .route = f.route, .request_id = f.id, .grep = f.grep });
    }

    /// Switches to /logs with a new server-side filter: unsubscribe, clear,
    /// subscribe again with a backlog.
    pub fn openLogs(self: *App, f: protocol.Filter) void {
        const gpa = self.gpa;
        var fresh: [5]?[]u8 = @splat(null);
        const src = [5]?[]const u8{ f.level, f.scope, f.route, f.request_id, f.grep };
        for (src, &fresh) |s, *d| if (s) |v| {
            d.* = gpa.dupe(u8, v) catch null;
        };
        for (self.log_filter_storage) |old| if (old) |o| gpa.free(o);
        self.log_filter_storage = fresh;
        if (self.logs_sub) |s| {
            self.queue(.{ .unsubscribe = s });
            self.logs_sub = null;
        }
        for (self.lines.items[self.lines_head..]) |l| freeLine(gpa, l);
        self.lines.clearRetainingCapacity();
        self.lines_head = 0;
        self.dropped = 0;
        if (self.route_filter) |s| self.gpa.free(s);
        self.route_filter = null;
        self.view = .logs;
        self.queue(.{ .subscribe_logs = self.logFilter() });
    }

    pub fn logFilter(self: *const App) protocol.Filter {
        const s = self.log_filter_storage;
        return .{ .level = s[0], .scope = s[1], .route = s[2], .request_id = s[3], .grep = s[4] };
    }

    fn cmdRequests(self: *App, args: []const []const u8) void {
        for (args) |a| {
            const eqi = std.mem.indexOfScalar(u8, a, '=') orelse continue;
            const k = a[0..eqi];
            const v = a[eqi + 1 ..];
            if (std.mem.eql(u8, k, "sort")) {
                if (std.meta.stringToEnum(Sort, v)) |s| self.sort = s;
            } else if (std.mem.eql(u8, k, "window")) {
                if (std.mem.eql(u8, v, "60s")) self.window_ms = 60_000 else if (std.mem.eql(u8, v, "10s")) self.window_ms = 10_000;
            }
        }
        self.switchView(.requests);
    }

    fn setFilterFromArgs(self: *App, args: []const []const u8, prefix: []const u8) void {
        if (self.route_filter) |s| self.gpa.free(s);
        self.route_filter = null;
        for (args) |a| {
            const v = if (prefix.len > 0) (if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else continue) else a;
            self.route_filter = self.gpa.dupe(u8, v) catch null;
            break;
        }
    }

    fn switchView(self: *App, v: ViewId) void {
        self.view = v;
        self.scroll = 0;
        self.last_snap_ms = -1_000_000; // refresh at the next tick
        if (v != .errors and v != .db and v != .routes) {
            if (self.route_filter) |s| self.gpa.free(s);
            self.route_filter = null;
        }
    }

    // ----------------------------------------------------------- notices

    pub fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        if (self.notice) |n| self.gpa.free(n);
        self.notice = text;
    }

    fn clearNotice(self: *App) void {
        if (self.notice) |n| self.gpa.free(n);
        self.notice = null;
    }

    // -------------------------------------------------------------- draw

    /// Draws the whole screen. Deterministic for a given state and time.
    pub fn draw(self: *App, scr: *screen.Screen) void {
        _ = self.draw_arena.reset(.retain_capacity);
        views.draw(self, scr);
    }

    /// Uptime in ms from the server's start time and the caller's wall clock.
    pub fn uptimeMs(self: *const App) ?i64 {
        const s = self.started_wall_ms orelse return null;
        if (self.wall_ms <= s) return null;
        return self.wall_ms - s;
    }
};

fn subOf(data: ?std.json.Value) ?u32 {
    const d = data orelse return null;
    const v = intField(d, "sub") orelse return null;
    return std.math.cast(u32, v);
}

fn intField(v: std.json.Value, name: []const u8) ?i64 {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

fn levelOf(s: []const u8) Level {
    if (std.mem.eql(u8, s, "err") or std.mem.eql(u8, s, "error")) return .err;
    if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) return .warn;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    return .other;
}

/// The readable part of a JSON log record: its message, then key=value for
/// the other fields.
fn jsonText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return gpa.dupe(u8, text);
    if (v != .object) return gpa.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const skip = [_][]const u8{ "time", "ts", "level", "scope", "message", "msg", "request_id" };
    if (v.object.get("message") orelse v.object.get("msg")) |m| {
        if (m == .string) try out.appendSlice(gpa, m.string);
    }
    var it = v.object.iterator();
    outer: while (it.next()) |e| {
        for (skip) |s| if (std.mem.eql(u8, s, e.key_ptr.*)) continue :outer;
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, e.key_ptr.*);
        try out.append(gpa, '=');
        switch (e.value_ptr.*) {
            .string => |s| try out.appendSlice(gpa, s),
            .integer => |i| try out.print(gpa, "{d}", .{i}),
            .float => |x| try out.print(gpa, "{d}", .{x}),
            .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
            .null => try out.appendSlice(gpa, "null"),
            else => try out.appendSlice(gpa, "..."),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn freeLine(gpa: std.mem.Allocator, l: LogLine) void {
    gpa.free(l.scope);
    gpa.free(l.request_id);
    gpa.free(l.text);
}

fn freeError(gpa: std.mem.Allocator, e: ErrorLine) void {
    gpa.free(e.method);
    gpa.free(e.path);
    gpa.free(e.route);
    gpa.free(e.err);
    gpa.free(e.request_id);
}

/// "2026-10-23T09:37:02.004Z" as milliseconds since the Unix epoch.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    var ms: i64 = 0;
    if (s.len >= 23 and s[19] == '.') ms = std.fmt.parseInt(i64, s[20..23], 10) catch 0;
    // days_from_civil
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60_000 + se * 1000 + ms;
}

test "app: parseIso" {
    try std.testing.expectEqual(@as(i64, 0), parseIso("1970-01-01T00:00:00.000Z").?);
    try std.testing.expectEqual(@as(i64, 1_000_000_123), parseIso("1970-01-12T13:46:40.123Z").?);
    try std.testing.expectEqual(@as(i64, 1_792_748_222_004), parseIso("2026-10-23T09:37:02.004Z").?);
}
