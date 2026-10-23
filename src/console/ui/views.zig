//! Drawing for the console's screen: the status line, the panels of every
//! view, the popup, the command line and the footer. Reads `App`, writes a
//! `Screen`; nothing here has side effects.
const std = @import("std");
const protocol = @import("protocol.zig");
const screen = @import("screen.zig");
const app_mod = @import("app.zig");
const stats_window = @import("stats_window.zig");
const width_of = @import("width.zig").width;

const App = app_mod.App;
const Screen = screen.Screen;
const Style = screen.Style;

const s_bold: Style = .{ .bold = true };
const s_dim: Style = .{ .dim = true };
const s_head: Style = .{ .bold = true, .underline = true };
const s_red: Style = .{ .fg = .red, .bold = true };
const s_yellow: Style = .{ .fg = .yellow };
const s_green: Style = .{ .fg = .green };
const s_sel: Style = .{ .reverse = true };

/// The HTTP/3 snapshot as a table (its fields are free-form numbers).
pub const H3Table = struct {
    enabled: bool,
    headers: []const []const u8,
    rows: []const []const []const u8,

    pub fn fromData(a: std.mem.Allocator, data: ?std.json.Value) !H3Table {
        const d = data orelse return error.InvalidFrame;
        if (d != .object) return error.InvalidFrame;
        const enabled = if (d.object.get("enabled")) |e| (e == .bool and e.bool) else false;
        var headers: std.ArrayList([]const u8) = .empty;
        var rows: std.ArrayList([]const []const u8) = .empty;
        if (d.object.get("endpoints")) |eps| if (eps == .array) {
            for (eps.array.items, 0..) |ep, i| {
                if (ep != .object) continue;
                if (i == 0) {
                    var it = ep.object.iterator();
                    while (it.next()) |e| try headers.append(a, try a.dupe(u8, e.key_ptr.*));
                }
                var cells: std.ArrayList([]const u8) = .empty;
                for (headers.items) |h| {
                    const v = ep.object.get(h);
                    try cells.append(a, if (v) |vv| try valueText(a, vv) else "");
                }
                try rows.append(a, try cells.toOwnedSlice(a));
            }
        };
        return .{ .enabled = enabled, .headers = try headers.toOwnedSlice(a), .rows = try rows.toOwnedSlice(a) };
    }
};

fn valueText(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d:.1}", .{f}),
        .string => |s| try a.dupe(u8, s),
        .bool => |b| if (b) "true" else "false",
        .null => "-",
        else => "...",
    };
}

fn fmt(app: *App, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(app.draw_arena.allocator(), f, args) catch "";
}

pub fn fmtLatency(app: *App, us: ?f64) []const u8 {
    const v = us orelse return "-";
    if (v < 1000) return fmt(app, "{d:.0} us", .{v});
    if (v < 1_000_000) return fmt(app, "{d:.1} ms", .{v / 1000});
    return fmt(app, "{d:.1} s", .{v / 1_000_000});
}

fn fmtRate(app: *App, r: f64) []const u8 {
    if (r >= 10) return fmt(app, "{d:.0}", .{r});
    return fmt(app, "{d:.1}", .{r});
}

fn fmtBytes(app: *App, b: u64) []const u8 {
    const f: f64 = @floatFromInt(b);
    if (b < 1024) return fmt(app, "{d} B", .{b});
    if (b < 1024 * 1024) return fmt(app, "{d:.1} KiB", .{f / 1024});
    if (b < 1024 * 1024 * 1024) return fmt(app, "{d:.1} MiB", .{f / (1024 * 1024)});
    return fmt(app, "{d:.2} GiB", .{f / (1024 * 1024 * 1024)});
}

fn fmtDuration(app: *App, ms: i64) []const u8 {
    const s = @divFloor(ms, 1000);
    if (s < 60) return fmt(app, "{d}s", .{s});
    const u: u64 = @intCast(@max(s, 0));
    if (u < 3600) return fmt(app, "{d}m{d:0>2}s", .{ u / 60, u % 60 });
    if (u < 86400) return fmt(app, "{d}h{d:0>2}m", .{ u / 3600, (u / 60) % 60 });
    return fmt(app, "{d}d{d:0>2}h", .{ u / 86400, (u / 3600) % 24 });
}

pub fn draw(app: *App, scr: *Screen) void {
    scr.clear();
    const cols = scr.cols;
    const rows = scr.rows;
    if (cols < app_mod.min_cols or rows < app_mod.min_rows) {
        const msg = "make the window at least 60x12";
        const y = rows / 2;
        const x: u16 = if (cols > msg.len) @intCast((cols - msg.len) / 2) else 0;
        _ = scr.print(x, y, cols, msg, .{});
        return;
    }
    drawStatus(app, scr);
    hrule(scr, 1);
    const panel_h = rows - 5;
    drawPanel(app, scr, 0, 2, cols, panel_h);
    hrule(scr, rows - 3);
    drawPopup(app, scr);
    drawCommandLine(app, scr);
    drawFooter(app, scr);
}

fn hrule(scr: *Screen, y: u16) void {
    scr.fill(0, y, scr.cols, 1, 0x2500, s_dim);
}

fn drawStatus(app: *App, scr: *Screen) void {
    const a = app.hello.app orelse protocol.App{};
    const env = if (a.environment.len > 0) a.environment else "?";
    var x = scr.print(1, 0, scr.cols, a.name, s_bold);
    const up = if (app.uptimeMs()) |u| fmtDuration(app, u) else "?";
    x = scr.print(x, 0, scr.cols, fmt(app, " \u{00b7} pid {d} \u{00b7} {s} \u{00b7} up {s}", .{ a.pid, env, up }), .{});
    // Right side: numbers, then the link state.
    const t = app.window.totals(10_000);
    const link = app.link();
    const link_text: []const u8 = switch (link) {
        .live => "\u{25cf} live",
        .not_answering => fmt(app, "\u{25cc} not answering {d}s", .{@divFloor(@max(app.now_ms - app.last_heard_ms, 0), 1000)}),
        .exited => "\u{2715} exited",
    };
    const link_style: Style = switch (link) {
        .live => s_green,
        .not_answering => s_yellow,
        .exited => s_red,
    };
    const lw = screen.textWidth(link_text);
    const right_edge = scr.cols - 1;
    if (right_edge > lw) scr.printRight(right_edge, 0, x, link_text, link_style);
    const drop: []const u8 = if (app.dropped > 0) fmt(app, "dropped {d}   ", .{app.dropped}) else "";
    const room: u16 = if (right_edge > lw + x + 1) right_edge - lw - x - 1 else 0;
    // The numbers that fit, most complete first.
    const full = fmt(app, "{s}{s} req/s   p99 {s}   {d:.0} err/min   conns {d}   ", .{ drop, fmtRate(app, t.rps), fmtLatency(app, t.p99_us), t.err_per_min, t.conns });
    const mid = fmt(app, "{s}{s} req/s   p99 {s}   ", .{ drop, fmtRate(app, t.rps), fmtLatency(app, t.p99_us) });
    const small = fmt(app, "{s} req/s   ", .{fmtRate(app, t.rps)});
    for ([_][]const u8{ full, mid, small }) |nums| {
        if (screen.textWidth(nums) <= room) {
            scr.printRight(right_edge - lw, 0, x, nums, .{});
            break;
        }
    }
}

fn drawPanel(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    switch (app.view) {
        .logs => drawLogs(app, scr, x, y, w, h),
        .requests => drawRequests(app, scr, x, y, w, h),
        .errors => drawErrors(app, scr, x, y, w, h),
        .conns => drawConns(app, scr, x, y, w, h),
        .db => drawDb(app, scr, x, y, w, h),
        .ws => drawWs(app, scr, x, y, w, h),
        .h3 => drawH3(app, scr, x, y, w, h),
        .runtime => drawRuntime(app, scr, x, y, w, h),
        .config => drawConfig(app, scr, x, y, w, h),
        .routes => drawRoutes(app, scr, x, y, w, h),
        .tasks => drawText(scr, x, y, w, "/tasks needs a task registry in the runtime (zio); not available yet.", &.{}),
        .help => drawHelp(app, scr, x, y, w, h),
    }
}

// ------------------------------------------------------------------- table

const Col = struct { title: []const u8, w: u16 = 0, right: bool = false };

/// Header at `y`, rows below; `skip` rows are scrolled off the top; `sel`
/// highlights one row (an index into `rows`, before skipping).
fn drawTable(scr: *Screen, x: u16, y: u16, w: u16, h: u16, cols: []const Col, rows: []const []const []const u8, skip: usize, sel: ?usize, row_style: ?[]const Style) void {
    if (h == 0 or cols.len == 0) return;
    var widths: [16]u16 = undefined;
    const gap: u16 = 2;
    var fixed: u16 = 0;
    var flex: u16 = 0;
    for (cols, 0..) |c, i| {
        if (i >= widths.len) break;
        if (c.w > 0) fixed += c.w else flex += 1;
    }
    const gaps: u16 = gap * @as(u16, @intCast(cols.len -| 1));
    const rest = w -| fixed -| gaps;
    const flex_w: u16 = if (flex > 0) @max(rest / flex, 6) else 0;
    for (cols, 0..) |c, i| {
        if (i >= widths.len) break;
        widths[i] = if (c.w > 0) c.w else flex_w;
    }
    // Header.
    var cx = x;
    for (cols, 0..) |c, i| {
        if (i >= widths.len) break;
        const end = @min(cx +| widths[i], x +| w);
        if (c.right) scr.printRight(end, y, cx, c.title, s_head) else _ = scr.print(cx, y, end, c.title, s_head);
        cx = end +| gap;
        if (cx >= x +| w) break;
    }
    var r: u16 = 0;
    while (r + 1 < h and skip + r < rows.len) : (r += 1) {
        const idx = skip + r;
        const row = rows[idx];
        const is_sel = sel != null and sel.? == idx;
        const base: Style = if (is_sel) s_sel else if (row_style) |rs| (if (idx < rs.len) rs[idx] else .{}) else .{};
        if (is_sel) scr.fill(x, y + 1 + r, w, 1, ' ', base);
        cx = x;
        for (cols, 0..) |c, i| {
            if (i >= widths.len) break;
            const end = @min(cx +| widths[i], x +| w);
            const cell = if (i < row.len) row[i] else "";
            if (c.right) scr.printRight(end, y + 1 + r, cx, cell, base) else _ = scr.print(cx, y + 1 + r, end, cell, base);
            cx = end +| gap;
            if (cx >= x +| w) break;
        }
    }
}

fn drawText(scr: *Screen, x: u16, y: u16, w: u16, first: []const u8, rest: []const []const u8) void {
    _ = scr.print(x + 1, y, x + w, first, .{});
    for (rest, 0..) |l, i| _ = scr.print(x + 1, y + 1 + @as(u16, @intCast(i)), x + w, l, .{});
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

// -------------------------------------------------------------------- logs

fn drawLogs(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const all = app.logLines();
    const filter = app.route_filter orelse "";
    var idx: std.ArrayList(usize) = .empty;
    for (all, 0..) |l, i| {
        if (filter.len == 0 or contains(l.text, filter) or contains(l.scope, filter)) idx.append(a, i) catch break;
    }
    if (idx.items.len == 0) {
        const f = app.logFilter();
        const msg = if (filter.len > 0) "no log lines match the filter" else if (f.level != null or f.scope != null or f.route != null or f.request_id != null or f.grep != null) "no log lines match yet" else "waiting for log lines...";
        _ = scr.print(x + 1, y, x + w, msg, s_dim);
        return;
    }
    const n = idx.items.len;
    const hh: usize = h;
    const scroll = @min(app.scroll, n -| hh);
    const end = n - scroll;
    const start = end -| hh;
    var row: u16 = 0;
    for (idx.items[start..end]) |i| {
        const l = all[i];
        const yy = y + row;
        row += 1;
        const level_style: Style = switch (l.level) {
            .err => s_red,
            .warn => s_yellow,
            .debug => s_dim,
            else => .{},
        };
        var cx = scr.print(x + 1, yy, x + w, &l.time, s_dim);
        cx = scr.print(cx + 1, yy, x + w, levelName(l.level), level_style);
        cx = x + 1 + 12 + 1 + 5 + 1;
        const scope_w: u16 = 10;
        _ = scr.print(cx, yy, x + w, l.scope, s_dim);
        cx += scope_w + 1;
        var text_end = x + w;
        if (l.request_id.len > 0) {
            const rid = fmt(app, "req {s}{s}", .{ l.request_id[0..@min(l.request_id.len, 4)], if (l.request_id.len > 4) "\u{2026}" else "" });
            const rw = screen.textWidth(rid);
            if (w > rw + 2) {
                scr.printRight(x + w, yy, cx, rid, s_dim);
                text_end = x + w - rw - 1;
            }
        }
        _ = scr.print(cx, yy, text_end, l.text, level_style);
    }
    if (scroll > 0) {
        const tag = fmt(app, " {d} more below (End) ", .{scroll});
        scr.printRight(x + w, y + h - 1, x, tag, s_sel);
    }
}

fn levelName(l: app_mod.Level) []const u8 {
    return switch (l) {
        .err => "error",
        .warn => "warn ",
        .info => "info ",
        .debug => "debug",
        .other => "     ",
    };
}

// ---------------------------------------------------------------- requests

fn drawRequests(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const note = fmt(app, "window {d}s \u{00b7} sort {s} \u{00b7} numbers start when the console attaches", .{ @divFloor(app.window_ms, 1000), @tagName(app.sort) });
    _ = scr.print(x + 1, y, x + w, note, s_dim);
    const rows_data = app.window.rows(a, app.window_ms) catch return;
    const SortCtx = struct {
        sort: app_mod.Sort,
        fn less(c: @This(), p: stats_window.Row, q: stats_window.Row) bool {
            return switch (c.sort) {
                .rps => p.rps > q.rps,
                .p50 => (p.p50_us orelse 0) > (q.p50_us orelse 0),
                .p99 => (p.p99_us orelse 0) > (q.p99_us orelse 0),
                .errors => (p.r5 + p.r4) > (q.r5 + q.r4),
                .route => std.mem.lessThan(u8, p.pattern, q.pattern),
            };
        }
    };
    std.mem.sort(stats_window.Row, rows_data, SortCtx{ .sort = app.sort }, SortCtx.less);
    const filter = app.route_filter orelse "";
    var table: std.ArrayList([]const []const u8) = .empty;
    var tot_rps: f64 = 0;
    var tot4: f64 = 0;
    var tot5: f64 = 0;
    for (rows_data) |r| {
        if (filter.len > 0 and !contains(r.pattern, filter)) continue;
        tot_rps += r.rps;
        tot4 += r.r4;
        tot5 += r.r5;
        const cells = a.alloc([]const u8, 7) catch break;
        cells[0] = r.method;
        cells[1] = if (r.i == 0) "(no route)" else r.pattern;
        cells[2] = fmtRate(app, r.rps);
        cells[3] = fmtLatency(app, r.p50_us);
        cells[4] = fmtLatency(app, r.p99_us);
        cells[5] = fmtRate(app, r.r4);
        cells[6] = fmtRate(app, r.r5);
        table.append(a, cells) catch break;
    }
    if (table.items.len == 0) {
        _ = scr.print(x + 1, y + 2, x + w, "no requests in the window", s_dim);
        return;
    }
    const tot = a.alloc([]const u8, 7) catch return;
    tot[0] = "";
    tot[1] = "total";
    tot[2] = fmtRate(app, tot_rps);
    tot[3] = "";
    tot[4] = "";
    tot[5] = fmtRate(app, tot4);
    tot[6] = fmtRate(app, tot5);
    table.append(a, tot) catch {};
    const cols = [_]Col{ .{ .title = "METHOD", .w = 7 }, .{ .title = "ROUTE" }, .{ .title = "REQ/S", .w = 8, .right = true }, .{ .title = "P50", .w = 9, .right = true }, .{ .title = "P99", .w = 9, .right = true }, .{ .title = "4XX/S", .w = 7, .right = true }, .{ .title = "5XX/S", .w = 7, .right = true } };
    drawTable(scr, x + 1, y + 1, w -| 2, h -| 1, &cols, table.items, app.scroll, null, null);
}

// ------------------------------------------------------------------ errors

fn drawErrors(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const filter = app.route_filter orelse "";
    var table: std.ArrayList([]const []const u8) = .empty;
    var i = app.errors.items.len;
    var sel_row: ?usize = null;
    while (i > 0) {
        i -= 1;
        const e = app.errors.items[i];
        if (filter.len > 0 and !contains(e.route, filter) and !contains(e.path, filter) and !contains(e.err, filter)) continue;
        if (i == app.err_sel) sel_row = table.items.len;
        const cells = a.alloc([]const u8, 8) catch break;
        cells[0] = fmt(app, "{s}", .{&e.time});
        cells[1] = fmt(app, "{d}", .{e.status});
        cells[2] = e.method;
        cells[3] = e.path;
        cells[4] = e.route;
        cells[5] = e.err;
        cells[6] = e.request_id[0..@min(e.request_id.len, 8)];
        cells[7] = fmtLatency(app, @floatFromInt(e.duration_us));
        table.append(a, cells) catch break;
    }
    if (table.items.len == 0) {
        _ = scr.print(x + 1, y, x + w, "no 5xx answers recorded", s_dim);
        return;
    }
    const cols = [_]Col{ .{ .title = "TIME", .w = 8 }, .{ .title = "STATUS", .w = 6 }, .{ .title = "METHOD", .w = 7 }, .{ .title = "PATH" }, .{ .title = "ROUTE" }, .{ .title = "ERROR" }, .{ .title = "REQUEST", .w = 8 }, .{ .title = "DURATION", .w = 9, .right = true } };
    const visible: usize = h -| 1;
    var skip: usize = 0;
    if (sel_row) |s| {
        if (s >= visible) skip = s + 1 - visible;
    }
    drawTable(scr, x + 1, y, w -| 2, h, &cols, table.items, skip, sel_row, null);
}

// ------------------------------------------------------------------- conns

fn drawConns(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const d = app.conns orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    var table: std.ArrayList([]const []const u8) = .empty;
    var tot: [9]u64 = @splat(0);
    for (d.executors) |e| {
        const s = e.streams orelse protocol.StreamCounts{};
        const vals = [_]u64{ e.connections orelse 0, s.h1, s.h2, s.h3, s.ws, s.wt, s.grpc, e.tasks orelse 0, e.run_queue orelse 0 };
        const cells = a.alloc([]const u8, 10) catch break;
        cells[0] = fmt(app, "{d}", .{e.i});
        for (vals, 0..) |v, k| {
            tot[k] += v;
            cells[k + 1] = fmt(app, "{d}", .{v});
        }
        table.append(a, cells) catch break;
    }
    if (d.executors.len > 1) {
        const cells = a.alloc([]const u8, 10) catch return;
        cells[0] = "all";
        for (tot, 0..) |v, k| cells[k + 1] = fmt(app, "{d}", .{v});
        table.append(a, cells) catch {};
    }
    const cols = [_]Col{ .{ .title = "EXEC", .w = 5 }, .{ .title = "CONNS", .w = 7, .right = true }, .{ .title = "H1", .w = 6, .right = true }, .{ .title = "H2", .w = 6, .right = true }, .{ .title = "H3", .w = 6, .right = true }, .{ .title = "WS", .w = 6, .right = true }, .{ .title = "WT", .w = 6, .right = true }, .{ .title = "GRPC", .w = 6, .right = true }, .{ .title = "TASKS", .w = 7, .right = true }, .{ .title = "RUNQ", .w = 6, .right = true } };
    const used: u16 = @intCast(@min(table.items.len + 1, h));
    drawTable(scr, x + 1, y, w -| 2, used, &cols, table.items, 0, null, null);
    var row: u16 = used + 1;
    if (d.stack_committed_bytes) |b| {
        if (row < h) _ = scr.print(x + 1, y + row, x + w, fmt(app, "stack memory committed: {s}", .{fmtBytes(app, b)}), .{});
        row += 1;
    }
    if (row < h) _ = scr.print(x + 1, y + row, x + w, "listeners", s_head);
    row += 1;
    for (d.listeners) |l| {
        if (row >= h) break;
        var protos: std.ArrayList(u8) = .empty;
        for (l.protocols, 0..) |p, k| {
            if (k > 0) protos.appendSlice(a, ", ") catch {};
            protos.appendSlice(a, p) catch {};
        }
        _ = scr.print(x + 1, y + row, x + w, fmt(app, "{s}  {s}  ({s})", .{ l.name, l.url, protos.items }), .{});
        row += 1;
    }
}

// ---------------------------------------------------------------------- db

fn drawDb(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const d = app.db orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    if (d.databases.len == 0) {
        _ = scr.print(x + 1, y, x + w, "no database connectors are configured", s_dim);
        return;
    }
    const drows = app.window.dbRows(a, 10_000) catch &.{};
    const filter = app.route_filter orelse "";
    var table: std.ArrayList([]const []const u8) = .empty;
    for (d.databases) |db| {
        if (filter.len > 0 and !contains(db.name, filter) and !contains(db.system, filter)) continue;
        var p = protocol.PoolStat{};
        for (db.pools) |q| {
            p.max += q.max;
            p.open += q.open;
            p.idle += q.idle;
            p.in_use += q.in_use;
            p.waiting += q.waiting;
        }
        var rps: ?f64 = null;
        var p50: ?f64 = null;
        var p99: ?f64 = null;
        var eps: ?f64 = null;
        for (drows) |r| if (r.i == db.i) {
            rps = r.rps;
            p50 = r.p50_us;
            p99 = r.p99_us;
            eps = r.eps;
        };
        const cells = a.alloc([]const u8, 11) catch break;
        cells[0] = db.system;
        cells[1] = db.name;
        cells[2] = db.target;
        cells[3] = fmt(app, "{d}", .{p.max});
        cells[4] = fmt(app, "{d}", .{p.open});
        cells[5] = fmt(app, "{d}", .{p.idle});
        cells[6] = fmt(app, "{d}", .{p.in_use});
        cells[7] = fmt(app, "{d}", .{p.waiting});
        cells[8] = if (rps) |r| fmtRate(app, r) else "-";
        cells[9] = fmtLatency(app, p50);
        cells[10] = fmtLatency(app, p99);
        table.append(a, cells) catch break;
    }
    const cols = [_]Col{ .{ .title = "SYSTEM", .w = 11 }, .{ .title = "NAME", .w = 10 }, .{ .title = "TARGET" }, .{ .title = "MAX", .w = 5, .right = true }, .{ .title = "OPEN", .w = 5, .right = true }, .{ .title = "IDLE", .w = 5, .right = true }, .{ .title = "USED", .w = 5, .right = true }, .{ .title = "WAIT", .w = 5, .right = true }, .{ .title = "CALLS/S", .w = 8, .right = true }, .{ .title = "P50", .w = 8, .right = true }, .{ .title = "P99", .w = 8, .right = true } };
    drawTable(scr, x + 1, y, w -| 2, h, &cols, table.items, app.scroll, null, null);
}

// ---------------------------------------------------------------------- ws

fn drawWs(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const a = app.draw_arena.allocator();
    const d = app.ws orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    _ = scr.print(x + 1, y, x + w, fmt(app, "WebSockets  h1 {d}  h2 {d}  h3 {d}      WebTransport sessions {d}", .{ d.sockets.h1, d.sockets.h2, d.sockets.h3, d.webtransport }), .{});
    var table: std.ArrayList([]const []const u8) = .empty;
    for (d.rooms) |r| {
        const cells = a.alloc([]const u8, 5) catch break;
        cells[0] = "room";
        cells[1] = r.name;
        cells[2] = fmt(app, "{d}", .{r.members});
        cells[3] = fmtBytes(app, r.queued_bytes);
        cells[4] = fmt(app, "{d}", .{r.closed_slow});
        table.append(a, cells) catch break;
    }
    for (d.topics) |t| {
        const cells = a.alloc([]const u8, 5) catch break;
        cells[0] = "topic";
        cells[1] = t.name;
        cells[2] = fmt(app, "{d}", .{t.subscribers});
        cells[3] = "";
        cells[4] = "";
        table.append(a, cells) catch break;
    }
    if (table.items.len == 0) {
        _ = scr.print(x + 1, y + 2, x + w, "no rooms or topics", s_dim);
        return;
    }
    const cols = [_]Col{ .{ .title = "KIND", .w = 6 }, .{ .title = "NAME" }, .{ .title = "MEMBERS", .w = 8, .right = true }, .{ .title = "QUEUED", .w = 11, .right = true }, .{ .title = "CLOSED SLOW", .w = 11, .right = true } };
    drawTable(scr, x + 1, y + 2, w -| 2, h -| 2, &cols, table.items, app.scroll, null, null);
}

// ---------------------------------------------------------------------- h3

fn drawH3(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const d = app.h3 orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    if (!d.enabled) {
        _ = scr.print(x + 1, y, x + w, "HTTP/3 is not on", s_dim);
        return;
    }
    const a = app.draw_arena.allocator();
    const cols = a.alloc(Col, d.headers.len) catch return;
    for (cols, d.headers) |*c, hd| c.* = .{ .title = hd, .w = @intCast(@min(@max(hd.len + 1, 8), 16)), .right = true };
    if (cols.len > 0) cols[0].right = false;
    drawTable(scr, x + 1, y, w -| 2, h, cols, d.rows, app.scroll, null, null);
}

// ----------------------------------------------------------------- runtime

fn drawRuntime(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const d = app.runtime orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    const lines = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "memory (RSS)", .v = fmtBytes(app, d.rss_bytes) },
        .{ .k = "CPU time", .v = fmtDuration(app, @intCast(d.cpu_ms)) },
        .{ .k = "threads", .v = fmt(app, "{d}", .{d.threads}) },
        .{ .k = "open fds", .v = fmt(app, "{d} of {d}", .{ d.fds, d.fd_limit }) },
        .{ .k = "uptime", .v = fmtDuration(app, @intCast(d.uptime_ms)) },
        .{ .k = "build", .v = d.build },
        .{ .k = "anole", .v = d.anole },
        .{ .k = "runtime", .v = d.runtime },
    };
    var row: u16 = 0;
    for (lines) |l| {
        if (row >= h) return;
        _ = scr.print(x + 1, y + row, x + w, l.k, s_dim);
        _ = scr.print(x + 1 + 16, y + row, x + w, l.v, .{});
        row += 1;
    }
    if (d.language.len > 0) {
        row += 1;
        if (row < h) _ = scr.print(x + 1, y + row, x + w, if (d.runtime.len > 0) d.runtime else "language", s_head);
        row += 1;
        for (d.language) |m| {
            if (row >= h) return;
            _ = scr.print(x + 1, y + row, x + w, m.name, s_dim);
            const v = if (std.mem.eql(u8, m.unit, "bytes")) fmtBytes(app, @intFromFloat(@max(m.value, 0))) else if (std.mem.eql(u8, m.unit, "seconds")) fmtLatency(app, m.value * 1_000_000) else fmt(app, "{d:.1}{s}", .{ m.value, if (std.mem.eql(u8, m.unit, "percent")) "%" else "" });
            _ = scr.print(x + 1 + 28, y + row, x + w, v, .{});
            row += 1;
        }
    }
}

// ------------------------------------------------------------------ config

fn drawConfig(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const d = app.config orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    const a = app.draw_arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, d.text, '\n');
    while (it.next()) |l| lines.append(a, l) catch break;
    const hh: usize = h;
    const scroll = @min(app.scroll, lines.items.len -| hh);
    const start = scroll;
    var row: u16 = 0;
    for (lines.items[start..]) |l| {
        if (row >= h) break;
        _ = scr.print(x + 1, y + row, x + w, l, .{});
        row += 1;
    }
}

// ------------------------------------------------------------------ routes

fn drawRoutes(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    const d = app.routes orelse {
        _ = scr.print(x + 1, y, x + w, "waiting for the server...", s_dim);
        return;
    };
    const a = app.draw_arena.allocator();
    const filter = app.route_filter orelse "";
    var table: std.ArrayList([]const []const u8) = .empty;
    for (d.routes) |r| {
        if (filter.len > 0 and !contains(r.pattern, filter) and !contains(r.method, filter)) continue;
        var flags: std.ArrayList(u8) = .empty;
        const parts = [_]struct { on: bool, s: []const u8 }{
            .{ .on = !std.mem.eql(u8, r.kind, "http"), .s = r.kind },
            .{ .on = r.no_wait, .s = "noWait" },
            .{ .on = r.cached, .s = "cached" },
        };
        for (parts) |p| if (p.on) {
            if (flags.items.len > 0) flags.append(a, ',') catch {};
            flags.appendSlice(a, p.s) catch {};
        };
        const cells = a.alloc([]const u8, 4) catch break;
        cells[0] = r.method;
        cells[1] = r.pattern;
        cells[2] = flags.items;
        cells[3] = fmt(app, "{d}", .{r.middleware});
        table.append(a, cells) catch break;
    }
    if (table.items.len == 0) {
        _ = scr.print(x + 1, y, x + w, "no routes match", s_dim);
        return;
    }
    const cols = [_]Col{ .{ .title = "METHOD", .w = 7 }, .{ .title = "PATTERN" }, .{ .title = "FLAGS", .w = 20 }, .{ .title = "MIDDLEWARE", .w = 10, .right = true } };
    drawTable(scr, x + 1, y, w -| 2, h, &cols, table.items, app.scroll, null, null);
}

// -------------------------------------------------------------------- help

fn drawHelp(app: *App, scr: *Screen, x: u16, y: u16, w: u16, h: u16) void {
    var row: u16 = 0;
    if (app.help_topic) |t| {
        for (app_mod.commands) |c| if (std.mem.eql(u8, c.name, t)) {
            _ = scr.print(x + 1, y, x + w, c.usage, s_bold);
            _ = scr.print(x + 1, y + 1, x + w, c.desc, .{});
            return;
        };
        _ = scr.print(x + 1, y, x + w, fmt(app, "no command /{s}", .{t}), s_dim);
        row = 2;
    }
    for (app_mod.commands) |c| {
        if (row >= h) break;
        _ = scr.print(x + 1, y + row, x + 19, c.usage, s_bold);
        _ = scr.print(x + 21, y + row, x + w, c.desc, .{});
        row += 1;
    }
    row += 1;
    if (row < h) _ = scr.print(x + 1, y + row, x + w, "Anything without a leading / filters the current view.", s_dim);
}

// ------------------------------------------------------------ chrome below

fn drawPopup(app: *App, scr: *Screen) void {
    const items = app.popupItems();
    if (items.len == 0) return;
    const n: u16 = @intCast(@min(items.len, 8));
    const bottom = scr.rows - 3; // the row above the command line
    const top = bottom + 1 - n;
    const sel = @min(app.popup_sel, items.len - 1);
    // Scroll the list so the selection is visible.
    const first = if (sel >= n) sel + 1 - n else 0;
    var r: u16 = 0;
    while (r < n) : (r += 1) {
        const c = items[first + r];
        const is_sel = first + r == sel;
        scr.fill(0, top + r, scr.cols, 1, ' ', if (is_sel) s_sel else .{});
        const label = fmt(app, "/{s}", .{c.name});
        _ = scr.print(2, top + r, scr.cols, label, if (is_sel) s_sel else s_bold);
        _ = scr.print(18, top + r, scr.cols - 1, c.desc, if (is_sel) s_sel else s_dim);
    }
}

fn drawCommandLine(app: *App, scr: *Screen) void {
    const y = scr.rows - 2;
    if (app.pending) |p| {
        _ = scr.print(1, y, scr.cols, p.prompt, s_bold);
        return;
    }
    _ = scr.print(1, y, scr.cols, ">", s_bold);
    const text = app.input.items;
    const avail: u16 = scr.cols - 4;
    var shown = text;
    while (screen.textWidth(shown) > avail and shown.len > 0) {
        // Drop leading code points until the tail fits.
        var k: usize = 1;
        while (k < shown.len and shown[k] & 0xc0 == 0x80) k += 1;
        shown = shown[k..];
    }
    const end = scr.print(3, y, scr.cols, shown, .{});
    scr.cursor = .{ .x = @min(end, scr.cols - 1), .y = y };
}

fn drawFooter(app: *App, scr: *Screen) void {
    const y = scr.rows - 1;
    if (app.pending != null) {
        _ = scr.print(1, y, scr.cols, "y confirms; any other key cancels", s_yellow);
        return;
    }
    if (app.notice) |n| {
        _ = scr.print(1, y, scr.cols, n, s_yellow);
        return;
    }
    if (app.link() == .exited) {
        const why = if (app.restarting != null) "the app is restarting" else "the app has stopped";
        _ = scr.print(1, y, scr.cols, fmt(app, "{s}; Ctrl-C leaves the console", .{why}), s_red);
        return;
    }
    const hint = if (app.mode == .in_process)
        "Esc back to plain logs \u{00b7} Tab complete \u{00b7} \u{2191}\u{2193} history \u{00b7} PgUp/PgDn scroll \u{00b7} Ctrl-C stop the server"
    else
        "Tab complete \u{00b7} \u{2191}\u{2193} history \u{00b7} PgUp/PgDn scroll \u{00b7} /quit or Ctrl-C leave (the app keeps running)";
    _ = scr.print(1, y, scr.cols, hint, s_dim);
}
