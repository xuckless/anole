//! Process-wide log rings for the live console (design 6.4). Producers (any
//! thread) copy a record into one of up to 16 byte rings under a spin lock
//! held for the copy only; readers copy a ring's live bytes out under it and
//! parse them after, keep cursors and learn how many records the rings
//! lapped. Nothing allocates under a ring's lock (SAFETY.md L5), and nothing
//! here ever waits for a console.
const std = @import("std");
const logging = @import("anole_log");
const ui = @import("anole_console_ui");
const safety = @import("anole_safety");

pub const ring_count = 16;
pub const header_len = 16;
pub const max_text = ui.protocol.max_log_text;

/// A record copied out of a ring (slices live in the caller's arena).
pub const Rec = struct {
    time_ns: i64,
    level: std.log.Level,
    json: bool,
    scope: []const u8,
    rid: []const u8,
    route: []const u8,
    text: []const u8,
};

pub const Cursor = struct { offset: u64 = 0, seq: u64 = 0 };
pub const Cursors = [ring_count]Cursor;

pub const Filter = struct {
    level: ?std.log.Level = null,
    scope: ?[]const u8 = null,
    route: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    grep: ?[]const u8 = null,

    pub fn matches(self: Filter, r: Rec) bool {
        if (self.level) |l| if (@backingInt(r.level) > @backingInt(l)) return false;
        if (self.scope) |s| if (!std.mem.eql(u8, s, r.scope)) return false;
        if (self.route) |p| {
            if (p.len > 0 and p[p.len - 1] == '*') {
                if (!std.mem.startsWith(u8, r.route, p[0 .. p.len - 1])) return false;
            } else if (!std.mem.eql(u8, p, r.route)) return false;
        }
        if (self.request_id) |id| if (!std.mem.eql(u8, id, r.rid)) return false;
        if (self.grep) |g| if (g.len > 0 and std.ascii.findIgnoreCase(r.text, g) == null) return false;
        return true;
    }
};

const Ring = struct {
    /// Over the fields below; held for a bounded copy only.
    lock: safety.SpinLock(.leaf) = .init,
    buf: []u8 = &.{},
    /// Absolute byte offsets: the next write, and the oldest intact record.
    head: u64 = 0,
    tail: u64 = 0,
    /// The sequence number of the record at `tail`, and of the next write.
    first_seq: u64 = 0,
    next_seq: u64 = 0,

    fn copyIn(self: *Ring, at: u64, bytes: []const u8) void {
        const size = self.buf.len;
        var off: usize = @intCast(at % size);
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, size - off);
            @memcpy(self.buf[off..][0..n], rest[0..n]);
            rest = rest[n..];
            off = 0;
        }
    }

    fn copyOut(self: *const Ring, at: u64, out: []u8) void {
        const size = self.buf.len;
        var off: usize = @intCast(at % size);
        var done: usize = 0;
        while (done < out.len) {
            const n = @min(out.len - done, size - off);
            @memcpy(out[done..][0..n], self.buf[off..][0..n]);
            done += n;
            off = 0;
        }
    }

    fn recLen(self: *const Ring, at: u64) usize {
        var h: [header_len]u8 = undefined;
        self.copyOut(at, &h);
        return header_len + h[10] + h[11] + std.mem.readInt(u16, h[12..14], .little) + std.mem.readInt(u16, h[14..16], .little);
    }
};

var next_ring: std.atomic.Value(u8) = .init(0);

fn myRing() usize {
    const S = struct {
        threadlocal var idx: u8 = 255;
    };
    if (S.idx == 255) S.idx = next_ring.fetchAdd(1, .monotonic) % ring_count;
    return S.idx;
}

pub const LogRing = struct {
    gpa: std.mem.Allocator,
    size_each: usize,
    rings: [ring_count]Ring = @splat(.{}),
    tap: logging.Tap,
    /// Consoles showing logs.
    watchers: std.atomic.Value(u32) = .init(0),

    /// `total` bytes split over the rings. The tap is not installed here.
    pub fn init(gpa: std.mem.Allocator, total: usize) LogRing {
        return .{
            .gpa = gpa,
            .size_each = total / ring_count,
            .tap = .{ .func = tapFn },
        };
    }

    pub fn deinit(self: *LogRing) void {
        for (&self.rings) |*r| if (r.buf.len > 0) self.gpa.free(r.buf);
    }

    pub fn install(self: *LogRing) void {
        self.tap.ud = self;
        logging.setTap(&self.tap);
    }

    pub fn uninstall(self: *LogRing) void {
        _ = self;
        logging.setTap(null);
    }

    /// A console starts or stops showing logs: info and debug are kept only
    /// meanwhile.
    pub fn watch(self: *LogRing) void {
        if (self.watchers.fetchAdd(1, .monotonic) == 0) self.tap.min_level.store(@backingInt(std.log.Level.debug), .monotonic);
    }

    pub fn unwatch(self: *LogRing) void {
        if (self.watchers.fetchSub(1, .monotonic) == 1) self.tap.min_level.store(@backingInt(std.log.Level.warn), .monotonic);
    }

    fn tapFn(ud: ?*anyopaque, level: std.log.Level, scope: []const u8, ctx: logging.Context, json: bool, text: []const u8) void {
        const self: *LogRing = @ptrCast(@alignCast(ud.?));
        self.push(level, scope, ctx.request_id, ctx.route, json, text);
    }

    /// Adds a record whatever the tap's level (the in-process console's
    /// captured stdout and stderr).
    pub fn push(self: *LogRing, level: std.log.Level, scope: []const u8, rid: []const u8, route: []const u8, json: bool, text_in: []const u8) void {
        const scope_c = scope[0..@min(scope.len, 255)];
        const rid_c = rid[0..@min(rid.len, 255)];
        const route_c = route[0..@min(route.len, 512)];
        var text_n = @min(text_in.len, max_text);
        while (text_n > 0 and text_n < text_in.len and (text_in[text_n] & 0xc0) == 0x80) text_n -= 1;
        const text = text_in[0..text_n];
        const n = header_len + scope_c.len + rid_c.len + route_c.len + text.len;
        if (n > self.size_each) return;
        const now_ns: i64 = @intCast(@min(std.Io.Clock.real.now(std.Options.debug_io).nanoseconds, std.math.maxInt(i64)));
        var h: [header_len]u8 = undefined;
        std.mem.writeInt(i64, h[0..8], now_ns, .little);
        h[8] = @backingInt(level);
        h[9] = @intFromBool(json);
        h[10] = @intCast(scope_c.len);
        h[11] = @intCast(rid_c.len);
        std.mem.writeInt(u16, h[12..14], @intCast(route_c.len), .little);
        std.mem.writeInt(u16, h[14..16], @intCast(text.len), .little);

        const r = &self.rings[myRing()];
        // The first record of a ring allocates it, before the lock; when
        // another thread installed one meanwhile, this copy is freed after
        // the lock is let go.
        var spare: []u8 = &.{};
        defer if (spare.len > 0) self.gpa.free(spare);
        r.lock.lock();
        defer r.lock.unlock();
        if (r.buf.len == 0) {
            r.lock.unlock();
            const fresh = self.gpa.alloc(u8, self.size_each) catch {
                r.lock.lock();
                return;
            };
            r.lock.lock();
            if (r.buf.len == 0) r.buf = fresh else spare = fresh;
        }
        while (r.head + n - r.tail > r.buf.len) {
            r.tail += r.recLen(r.tail);
            r.first_seq += 1;
        }
        var at = r.head;
        r.copyIn(at, &h);
        at += header_len;
        inline for (.{ scope_c, rid_c, route_c, text }) |part| {
            r.copyIn(at, part);
            at += part.len;
        }
        r.head += n;
        r.next_seq += 1;
    }

    /// The record at the start of `bytes` (records copied out of a ring,
    /// whole), its strings copied into `arena`.
    fn readOne(bytes: []const u8, arena: std.mem.Allocator) !struct { rec: Rec, len: usize } {
        const h = bytes[0..header_len];
        const sl: usize = h[10];
        const il: usize = h[11];
        const rl: usize = std.mem.readInt(u16, h[12..14], .little);
        const tl: usize = std.mem.readInt(u16, h[14..16], .little);
        const body = try arena.dupe(u8, bytes[header_len..][0 .. sl + il + rl + tl]);
        return .{
            .rec = .{
                .time_ns = std.mem.readInt(i64, h[0..8], .little),
                .level = @fromBackingInt(@intCast(h[8])),
                .json = h[9] != 0,
                .scope = body[0..sl],
                .rid = body[sl..][0..il],
                .route = body[sl + il ..][0..rl],
                .text = body[sl + il + rl ..][0..tl],
            },
            .len = header_len + sl + il + rl + tl,
        };
    }

    /// Positions every cursor at the end (what a subscription without
    /// backlog starts from).
    pub fn attachAtEnd(self: *LogRing, cursors: *Cursors) void {
        for (&self.rings, cursors) |*r, *c| {
            r.lock.lock();
            c.* = .{ .offset = r.head, .seq = r.next_seq };
            r.lock.unlock();
        }
    }

    /// The records after `cursors`, oldest first by time, advancing the
    /// cursors; `dropped` counts records the rings lapped.
    pub fn readNew(self: *LogRing, arena: std.mem.Allocator, cursors: *Cursors, out: *std.ArrayList(Rec), dropped: *u64) !void {
        const start = out.items.len;
        const scratch = try arena.alloc(u8, self.size_each);
        for (&self.rings, cursors) |*r, *c| {
            const live = live: {
                r.lock.lock();
                defer r.lock.unlock();
                if (r.buf.len == 0) continue;
                if (c.offset < r.tail) {
                    dropped.* += r.first_seq - c.seq;
                    c.* = .{ .offset = r.tail, .seq = r.first_seq };
                }
                const n: usize = @intCast(r.head - c.offset);
                r.copyOut(c.offset, scratch[0..n]);
                c.* = .{ .offset = r.head, .seq = r.next_seq };
                break :live scratch[0..n];
            };
            try parseInto(live, arena, out);
        }
        sortByTime(out.items[start..]);
    }

    /// The records still in the rings (oldest first by time) while moving the
    /// cursors to the end: a new subscription's backlog.
    pub fn readBacklogAndAttach(self: *LogRing, arena: std.mem.Allocator, cursors: *Cursors, out: *std.ArrayList(Rec)) !void {
        const start = out.items.len;
        const scratch = try arena.alloc(u8, self.size_each);
        for (&self.rings, cursors) |*r, *c| {
            const live = live: {
                r.lock.lock();
                defer r.lock.unlock();
                c.* = .{ .offset = r.head, .seq = r.next_seq };
                if (r.buf.len == 0) continue;
                const n: usize = @intCast(r.head - r.tail);
                r.copyOut(r.tail, scratch[0..n]);
                break :live scratch[0..n];
            };
            try parseInto(live, arena, out);
        }
        sortByTime(out.items[start..]);
    }

    /// Appends the whole records in `bytes` (copied out of one ring) to
    /// `out`, their strings in `arena`.
    fn parseInto(bytes: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(Rec)) !void {
        var at: usize = 0;
        while (at < bytes.len) {
            const one = try readOne(bytes[at..], arena);
            try out.append(arena, one.rec);
            at += one.len;
        }
    }
};

fn lessByTime(_: void, a: Rec, b: Rec) bool {
    return a.time_ns < b.time_ns;
}

fn sortByTime(items: []Rec) void {
    std.mem.sort(Rec, items, {}, lessByTime);
}

pub fn levelFromName(name: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, name, "error") or std.mem.eql(u8, name, "err")) return .err;
    if (std.mem.eql(u8, name, "warn")) return .warn;
    if (std.mem.eql(u8, name, "info")) return .info;
    if (std.mem.eql(u8, name, "debug")) return .debug;
    return null;
}

pub fn levelName(l: std.log.Level) []const u8 {
    return switch (l) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

// ------------------------------------------------------------------ tests

test "logring: records come back in time order with ids and routes" {
    var lr = LogRing.init(std.testing.allocator, 16 * 1024);
    defer lr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    var cur: Cursors = undefined;
    lr.attachAtEnd(&cur);
    lr.push(.warn, "billing", "rid1", "/charges", false, "first");
    lr.push(.info, "access", "", "", true, "{\"a\":1}");
    var out: std.ArrayList(Rec) = .empty;
    var dropped: u64 = 0;
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("first", out.items[0].text);
    try std.testing.expectEqualStrings("rid1", out.items[0].rid);
    try std.testing.expectEqualStrings("/charges", out.items[0].route);
    try std.testing.expect(out.items[1].json);
    try std.testing.expectEqual(@as(u64, 0), dropped);
    out.clearRetainingCapacity();
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "logring: a lapped reader gets a dropped count and the newest records" {
    var lr = LogRing.init(std.testing.allocator, 16 * 256);
    defer lr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    var cur: Cursors = undefined;
    lr.attachAtEnd(&cur);
    var i: usize = 0;
    while (i < 100) : (i += 1) lr.push(.warn, "s", "", "", false, "0123456789012345678901234567890123456789");
    var out: std.ArrayList(Rec) = .empty;
    var dropped: u64 = 0;
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expect(dropped > 0);
    try std.testing.expectEqual(@as(u64, 100), dropped + out.items.len);
}

test "logring: a long record is cut at 16 KiB and one too big for the ring is skipped" {
    var lr = LogRing.init(std.testing.allocator, 16 * 64 * 1024);
    defer lr.deinit();
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    var cur: Cursors = undefined;
    lr.attachAtEnd(&cur);
    const big = try std.testing.allocator.alloc(u8, 40 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    lr.push(.err, "s", "", "", false, big);
    var out: std.ArrayList(Rec) = .empty;
    var dropped: u64 = 0;
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(usize, max_text), out.items[0].text.len);

    // A ring whose share per executor is below one cut record: the record
    // is skipped, not stored or counted as dropped.
    var small = LogRing.init(std.testing.allocator, ring_count * 1024);
    defer small.deinit();
    var small_cur: Cursors = undefined;
    small.attachAtEnd(&small_cur);
    small.push(.err, "s", "", "", false, big);
    var small_out: std.ArrayList(Rec) = .empty;
    var small_dropped: u64 = 0;
    try small.readNew(a, &small_cur, &small_out, &small_dropped);
    try std.testing.expectEqual(@as(usize, 0), small_out.items.len);
    try std.testing.expectEqual(@as(u64, 0), small_dropped);
}

test "logring: the tap keeps warn and error until a console watches, then every level" {
    var lr = LogRing.init(std.testing.allocator, 16 * 1024);
    defer lr.deinit();
    lr.install();
    defer lr.uninstall();
    logging.setFormat(.text);
    var arena_s = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_s.deinit();
    const a = arena_s.allocator();
    var cur: Cursors = undefined;
    lr.attachAtEnd(&cur);
    const sink = struct {
        fn f(_: ?*anyopaque, _: std.log.Level, _: []const u8, _: []const u8) void {}
    };
    var cb: logging.Callback = .{ .func = sink.f };
    logging.setSink(&cb);
    defer logging.setSink(null);
    logging.info("quiet", .{});
    logging.warn("loud", .{});
    var out: std.ArrayList(Rec) = .empty;
    var dropped: u64 = 0;
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("loud", out.items[0].text);
    lr.watch();
    logging.info("now kept", .{});
    lr.unwatch();
    logging.info("dropped again", .{});
    out.clearRetainingCapacity();
    try lr.readNew(a, &cur, &out, &dropped);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("now kept", out.items[0].text);
}

test "logring: a filter matches by minimum level, scope, case-insensitive grep, route pattern and request id" {
    const r: Rec = .{ .time_ns = 0, .level = .warn, .json = false, .scope = "billing", .rid = "r1", .route = "/charges/:id", .text = "Retrying charge" };
    try std.testing.expect((Filter{ .level = .warn }).matches(r));
    try std.testing.expect(!(Filter{ .level = .err }).matches(r));
    try std.testing.expect((Filter{ .scope = "billing", .grep = "retrying" }).matches(r));
    try std.testing.expect(!(Filter{ .scope = "other" }).matches(r));
    try std.testing.expect((Filter{ .route = "/charges/*" }).matches(r));
    try std.testing.expect((Filter{ .request_id = "r1" }).matches(r));
}
