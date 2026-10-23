//! `anole_watch_*`: watches over PostgreSQL LISTEN/NOTIFY, Redis pub/sub
//! and streams and MongoDB change streams (p3/realtime, design-realtime.md).
//! Handle kind 15 (`anole_watch_sub`); events 116-118.
//!
//! The configuration's "watches" are made when the server opens (after the
//! databases they read) and read from `anole_server_start` until the drain.
//! Their targets (SSE topics, WebSocket rooms) are fed on Anole's threads;
//! a consumer that wants the events too listens (`anole_watch_listen`):
//! every event is copied into a record and queued for the consumer's ring,
//! at most `max_events` / `max_bytes` of them at a time. Past that the
//! events are dropped and the consumer hears one GAP status, with how many.
const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const anole = @import("../root.zig");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const db_mod = @import("db.zig");
const config_mod = @import("config.zig");
const sse_mod = @import("sse.zig");
const redis_feed = if (features.redis) @import("../watch/redis.zig") else struct {};

const Engine = engine.Engine;
const Exec = engine.Exec;
const Handle = engine.Handle;
const AnswerError = engine.AnswerError;
const gpa = engine.gpa;
const aw = anole.watch;

const log = @import("../errors.zig").log;

/// A configured watch (`anole_watch *` in C).
pub const Entry = struct {
    index: u32,
    name: []const u8,
    w: *aw.Watch,
    source: u32,
    /// Stream groups with manual acks: the keys.
    manual_ack: bool = false,
    keys: []const []const u8 = &.{},
};

/// One listener (`anole_watch_sub`).
const Sub = struct {
    sink: aw.Sink,
    e: *Engine,
    entry: *Entry,
    home: *Exec,
    user_data: u64,
    format: u32,
    max_events: u32,
    max_bytes: u32,
    queued_events: std.atomic.Value(u32) = .init(0),
    queued_bytes: std.atomic.Value(u32) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    slot: u32,
    gen: u32,
    /// Ended (by `unlisten` or the watch): no more records.
    ended: std.atomic.Value(bool) = .init(false),

    fn handle(s: *const Sub) u64 {
        return Handle.encode(.{ .gen = @intCast(s.gen), .kind = .watch_sub, .slot = @intCast(s.slot), .exec = s.home.index });
    }
};

/// Engine-wide state (`Engine.watch_state`).
pub const State = struct {
    lock: std.atomic.Mutex = .unlocked,
    entries: []Entry = &.{},
    /// The allocation behind `entries` (which `close` empties), freed by
    /// `deinit`.
    owned: []Entry = &.{},
    /// By slot: the live listener, and the generation the next one gets.
    subs: std.ArrayList(?*Sub) = .empty,
    gens: std.ArrayList(u32) = .empty,
    free: std.ArrayList(u32) = .empty,
    /// Every listener made, to free at `destroy`.
    all: std.ArrayList(*Sub) = .empty,
    first_gen: u32 = 1,
    started: bool = false,

    pub fn init(s: *State, first_gen: u32) void {
        s.first_gen = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        var max: u32 = 0;
        for (s.gens.items) |g| max = @max(max, g);
        return max;
    }

    pub fn deinit(s: *State) void {
        for (s.all.items) |sub| gpa.destroy(sub);
        s.all.deinit(gpa);
        s.subs.deinit(gpa);
        s.gens.deinit(gpa);
        s.free.deinit(gpa);
        for (s.owned) |en| if (en.keys.len > 0) gpa.free(en.keys);
        if (s.owned.len > 0) gpa.free(s.owned);
        s.owned = &.{};
        s.entries = &.{};
    }

    fn acquire(s: *State) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(s: *State) void {
        s.lock.unlock();
    }
};

/// Per executor (`Exec.watch`): the tasks it runs are canceled at the stop.
pub const ExecState = struct {
    pub fn cancel(st: *ExecState, io: std.Io) void {
        _ = st;
        _ = io;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(st: *const ExecState) u32 {
        _ = st;
        return 0;
    }

    pub fn deinit(st: *ExecState) void {
        _ = st;
    }
};

// ---------------------------------------------------------------------------
// Opening, starting, stopping

fn sourceOf(e: *Engine, a: std.mem.Allocator, cfg: config_mod.Config.Watch, manual_ack: *bool) !aw.Source {
    const d = db_mod.find(e, cfg.database) orelse return error.UnknownDatabase;
    if (cfg.postgres) |p| {
        if (comptime !features.postgres) unreachable;
        return .{ .postgres = .{ .client = d.client.postgres, .channels = p.channels } };
    }
    if (cfg.redis) |r| {
        if (comptime !features.redis) unreachable;
        return .{ .redis = .{ .client = d.client.redis, .channels = r.channels, .patterns = r.patterns } };
    }
    if (cfg.redis_stream) |r| {
        if (comptime !features.redis) unreachable;
        var from: aw.StreamStart = .new;
        if (r.start) |v| switch (v) {
            .string => |s| {
                if (std.mem.eql(u8, s, "all")) from = .all else if (!std.mem.eql(u8, s, "new")) return error.InvalidStart;
            },
            .object => |o| {
                const after = o.get("after") orelse return error.InvalidStart;
                if (after != .array) return error.InvalidStart;
                const ids = try a.alloc([]const u8, after.array.items.len);
                for (after.array.items, ids) |item, *out| {
                    if (item != .string) return error.InvalidStart;
                    out.* = item.string;
                }
                from = .{ .after = ids };
            },
            else => return error.InvalidStart,
        };
        var group: ?aw.StreamGroup = null;
        if (r.group) |g| {
            manual_ack.* = std.mem.eql(u8, g.ack, "manual");
            group = .{ .name = g.name, .consumer = g.consumer, .create = g.create, .ack = if (manual_ack.*) .manual else .auto };
        }
        return .{ .redis_stream = .{
            .client = d.client.redis,
            .keys = r.keys,
            .start = from,
            .group = group,
            .count = r.count,
            .block = .fromMilliseconds(r.block_ms),
        } };
    }
    if (comptime !features.mongodb) unreachable;
    return mongoSource(d, a, cfg.mongodb.?);
}

fn mongoSource(d: *db_mod.Db, a: std.mem.Allocator, m: config_mod.Config.WatchMongo) !aw.Source {
    var from: aw.MongoStart = .now;
    if (m.start) |v| switch (v) {
        .string => |s| if (!std.mem.eql(u8, s, "now")) return error.InvalidStart,
        .object => |o| {
            if (o.get("resume_after")) |t| {
                from = .{ .resume_after = try std.json.Stringify.valueAlloc(a, t, .{}) };
            } else if (o.get("start_after")) |t| {
                from = .{ .start_after = try std.json.Stringify.valueAlloc(a, t, .{}) };
            } else if (o.get("at")) |t| {
                if (t != .object) return error.InvalidStart;
                const ts = t.object.get("t") orelse return error.InvalidStart;
                const ix = t.object.get("i") orelse return error.InvalidStart;
                if (ts != .integer or ix != .integer) return error.InvalidStart;
                from = .{ .at = .{ .t = @intCast(ts.integer), .i = @intCast(ix.integer) } };
            } else return error.InvalidStart;
        },
        else => return error.InvalidStart,
    };
    const full: anole.mongodb.FullDocument = if (std.mem.eql(u8, m.full_document, "update_lookup")) .update_lookup else if (std.mem.eql(u8, m.full_document, "when_available")) .when_available else if (std.mem.eql(u8, m.full_document, "required")) .required else .default;
    const before: anole.mongodb.FullDocumentBeforeChange = if (std.mem.eql(u8, m.full_document_before_change, "when_available")) .when_available else if (std.mem.eql(u8, m.full_document_before_change, "required")) .required else .off;
    return .{ .mongodb = .{
        .client = d.client.mongodb,
        .database = m.database,
        .collection = m.collection,
        .pipeline = if (m.pipeline) |p| try std.json.Stringify.valueAlloc(a, p, .{}) else "[]",
        .full_document = full,
        .full_document_before_change = before,
        .start = from,
        .max_await = if (m.max_await_ms) |ms| .fromMilliseconds(ms) else null,
        .batch_size = m.batch_size,
        .show_expanded_events = m.show_expanded_events,
    } };
}

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`): the SSE topics, then each configured watch.
pub fn open(e: *Engine, app: *anole.App) !void {
    try sse_mod.openTopics(e, app);
    const cfgs = e.config.watches;
    if (cfgs.len == 0) return;
    const a = e.arena.allocator();
    const entries = try gpa.alloc(Entry, cfgs.len);
    var made: usize = 0;
    errdefer {
        for (entries[0..made]) |en| {
            en.w.deinit();
            if (en.keys.len > 0) gpa.free(en.keys);
        }
        gpa.free(entries);
    }
    for (cfgs, entries, 0..) |cfg, *en, i| {
        var manual = false;
        const source = sourceOf(e, a, cfg, &manual) catch |err| {
            log.err("watches[{d}] \"{s}\": {t}", .{ i, cfg.name, err });
            return err;
        };
        var targets: std.ArrayList(aw.Target) = .empty;
        for (cfg.to) |t| {
            if (t.sse) |topic| {
                try targets.append(a, .{ .sse = .{ .topics = e.sse_state.topics.?, .topic = topic, .event = t.event } });
            } else if (t.ws) |room| {
                if (comptime !anole.features.websocket) {
                    log.err("watches[{d}] \"{s}\": a ws target needs WebSocket support (-Dwebsocket)", .{ i, cfg.name });
                    return error.Unsupported;
                } else {
                    try targets.append(a, .{ .ws = .{
                        .rooms = &e.rooms,
                        .room = room,
                        .type = if (std.mem.eql(u8, t.type, "binary")) .binary else .text,
                        .gap_message = t.gap_message,
                    } });
                }
            }
        }
        const keys: []const []const u8 = if (cfg.redis_stream) |r| try gpa.dupe([]const u8, r.keys) else &.{};
        errdefer if (keys.len > 0) gpa.free(keys);
        const w = aw.Watch.init(gpa, app.io(), source, .{
            .name = cfg.name,
            .to = targets.items,
            .data = if (cfg.data == .document) .document else .auto,
            .reconnect = if (cfg.reconnect) |r| .{ .base = .fromMilliseconds(r.base_ms), .max = .fromMilliseconds(r.max_ms) } else .{ .base = .fromMilliseconds(100), .max = .fromSeconds(5) },
        }) catch |err| return err;
        if (app.mode.deployment == .lambda) {
            w.disabled = true;
            log.info("watch \"{s}\": not started under the lambda deployment (a function holds no long-lived connection to a database)", .{cfg.name});
        }
        w._registerDrain(&app.server.drain_hooks);
        en.* = .{
            .index = @intCast(i),
            .name = cfg.name,
            .w = w,
            .source = switch (source) {
                .postgres => abi.WATCH_SRC_POSTGRES,
                .redis => abi.WATCH_SRC_REDIS,
                .redis_stream => abi.WATCH_SRC_REDIS_STREAM,
                .mongodb => abi.WATCH_SRC_MONGODB,
            },
            .manual_ack = manual,
            .keys = keys,
        };
        made += 1;
    }
    e.watch_state.entries = entries;
    e.watch_state.owned = entries;
}

/// `anole_server_start`: serving begins.
pub fn start(e: *Engine, app: *anole.App) !void {
    e.watch_state.started = true;
    for (e.watch_state.entries) |en| {
        en.w.start(app.extras.metrics, null, null) catch |err| {
            log.err("watch \"{s}\": cannot start: {t}", .{ en.name, err });
            return err;
        };
    }
}

/// The drain started (`anole_server_drain`, once): the watches stop reading;
/// their listeners end after what is queued.
pub fn draining(e: *Engine) void {
    for (e.watch_state.entries) |en| en.w.stop();
}

/// The server stops: the watches are stopped and freed (their tasks are on
/// the runtime, which is still up), their listeners end.
pub fn close(e: *Engine) void {
    for (e.watch_state.entries) |en| en.w.stop();
    for (e.watch_state.entries) |en| en.w.deinit();
    // The watches are gone: their entries stay (for stale lookups) but are
    // not used again.
    for (e.watch_state.entries) |*en| en.w = undefined;
    e.watch_state.entries = e.watch_state.entries[0..0];
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    _ = e;
}

/// `anole_handle_release` for the kind `watch_sub` (a cleanup call: a handle
/// that is over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    return unlisten(e, hv);
}

// ---------------------------------------------------------------------------
// Listeners

fn subOf(e: *Engine, hv: u64) engine.HandleError!*Sub {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .watch_sub) return error.WrongKind;
    const st = &e.watch_state;
    st.acquire();
    defer st.release();
    if (h.slot >= st.subs.items.len) return error.Over;
    const sub = st.subs.items[h.slot] orelse return error.Over;
    if (sub.gen != h.gen) return error.Over;
    return sub;
}

/// `anole_watch_find`.
pub fn find(e: *Engine, name: []const u8) ?*Entry {
    for (e.watch_state.entries) |*en| if (std.mem.eql(u8, en.name, name)) return en;
    return null;
}

/// `anole_watch_listen`: events of `entry` from now on, to `home`'s
/// consumer; the handle.
pub fn listen(e: *Engine, entry: *Entry, c: *engine.Consumer, opts: abi.WatchListenOptions, user_data: u64) AnswerError!u64 {
    if (opts.format > abi.WATCH_JSON or opts.reserved != 0) return error.Invalid;
    if (e.phase.load(.acquire) != .running or entry.w.isStopped()) return error.State;
    if (c.execs.items.len == 0) return error.State;
    const home = c.execs.items[0];
    const sub = try gpa.create(Sub);
    errdefer gpa.destroy(sub);
    const st = &e.watch_state;
    st.acquire();
    var slot: u32 = undefined;
    var gen: u32 = undefined;
    if (st.free.pop()) |s| {
        slot = s;
        gen = st.gens.items[s];
    } else {
        slot = @intCast(st.subs.items.len);
        if (slot >= engine.max_slots) {
            st.release();
            return error.OutOfMemory;
        }
        gen = e.first_gen;
        st.subs.append(gpa, null) catch {
            st.release();
            return error.OutOfMemory;
        };
        st.gens.append(gpa, gen) catch {
            _ = st.subs.pop();
            st.release();
            return error.OutOfMemory;
        };
    }
    sub.* = .{
        .sink = .{ .ctx = sub, .deliver = sinkDeliver, .gap = sinkGap, .status = sinkStatus, .ended = sinkEnded },
        .e = e,
        .entry = entry,
        .home = home,
        .user_data = user_data,
        .format = opts.format,
        .max_events = if (opts.max_events == 0) 1024 else opts.max_events,
        .max_bytes = if (opts.max_bytes == 0) 4 * 1024 * 1024 else opts.max_bytes,
        .slot = slot,
        .gen = gen,
    };
    st.subs.items[slot] = sub;
    st.all.append(gpa, sub) catch {};
    st.release();
    entry.w.addSink(&sub.sink);
    // A connected source says so at once.
    if (entry.w.status() == .connected) postStatus(sub, abi.WATCH_CONNECTED, 0, "");
    return sub.handle();
}

/// Retires the listener's slot: its handle is stale from here.
fn retire(sub: *Sub) void {
    const st = &sub.e.watch_state;
    st.acquire();
    defer st.release();
    if (sub.slot < st.subs.items.len and st.subs.items[sub.slot] == sub) {
        st.subs.items[sub.slot] = null;
        st.gens.items[sub.slot] = engine.nextGen(sub.gen);
        st.free.append(gpa, sub.slot) catch {};
    }
}

/// `anole_watch_unlisten`: a cleanup call.
pub fn unlisten(e: *Engine, hv: u64) AnswerError!void {
    const sub = try subOf(e, hv);
    if (sub.ended.swap(true, .acq_rel)) return error.Over;
    sub.entry.w.removeSink(&sub.sink);
    postEnd(sub, abi.WATCH_END_UNLISTENED, "");
    retire(sub);
}

/// `anole_watch_ack`: XACKs `position` on the stream key(s) of the watch.
pub fn ack(e: *Engine, hv: u64, position: []const u8) AnswerError!void {
    const sub = subOf(e, hv) catch |err| return e.badHandle(err);
    const en = sub.entry;
    if (!en.manual_ack) return error.State;
    const hook = en.w.ack_hook orelse return error.State;
    if (position.len == 0) return error.Invalid;
    for (en.keys) |key| hook.call(hook.ctx, key, position) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => return error.State,
    };
}

/// A watch event record was copied out by `poll`: room in the listener's
/// bound again. (Called by the engine, once per record.)
pub fn polled(e: *Engine, rec: *const abi.WatchEvent) void {
    const h = Handle.decode(rec.ev.handle);
    const st = &e.watch_state;
    st.acquire();
    const sub = if (h.slot < st.subs.items.len) st.subs.items[h.slot] else null;
    st.release();
    const s = sub orelse return;
    if (s.gen != h.gen) return;
    _ = s.queued_events.fetchSub(1, .acq_rel);
    _ = s.queued_bytes.fetchSub(rec.ev.len, .acq_rel);
}

// ---------------------------------------------------------------------------
// The sink: records for the consumer

fn sinkDeliver(ctx: *anyopaque, ev: *const aw.Event) void {
    const sub: *Sub = @ptrCast(@alignCast(ctx));
    if (sub.ended.load(.acquire)) return;
    const rec = buildEvent(sub, ev) catch return;
    const len: u32 = @intCast(rec.len);
    // Over the bound: dropped, and counted for one GAP before the next.
    if (sub.queued_events.load(.acquire) >= sub.max_events or sub.queued_bytes.load(.acquire) + len > sub.max_bytes) {
        _ = sub.dropped.fetchAdd(1, .monotonic);
        engine.freeRecord(rec.ptr);
        return;
    }
    const lost = sub.dropped.swap(0, .acq_rel);
    if (lost > 0) postStatus(sub, abi.WATCH_GAP, lost, "");
    _ = sub.queued_events.fetchAdd(1, .acq_rel);
    _ = sub.queued_bytes.fetchAdd(len, .acq_rel);
    sub.home.postRemote(rec);
}

fn sinkGap(ctx: *anyopaque, detail: []const u8) void {
    const sub: *Sub = @ptrCast(@alignCast(ctx));
    if (sub.ended.load(.acquire)) return;
    postStatus(sub, abi.WATCH_GAP, 0, detail);
}

fn sinkStatus(ctx: *anyopaque, connected: bool, detail: []const u8) void {
    const sub: *Sub = @ptrCast(@alignCast(ctx));
    if (sub.ended.load(.acquire)) return;
    postStatus(sub, if (connected) abi.WATCH_CONNECTED else abi.WATCH_DISCONNECTED, 0, detail);
}

/// The watch stopped (drained, failed, closed): the listener ends. Called
/// under the watch's lock, so it only posts.
fn sinkEnded(ctx: *anyopaque, failed: bool, detail: []const u8) void {
    const sub: *Sub = @ptrCast(@alignCast(ctx));
    if (sub.ended.swap(true, .acq_rel)) return;
    postEnd(sub, if (failed) abi.WATCH_END_FAILED else abi.WATCH_END_DRAINED, detail);
    retire(sub);
}

fn postStatus(sub: *Sub, status: u32, dropped: u64, detail: []const u8) void {
    const size = abi.alignUp(@sizeOf(abi.WatchStatusEvent) + detail.len);
    const rec = engine.newRecord(size, .watch_status, sub.handle()) catch return;
    const ev: *abi.WatchStatusEvent = @ptrCast(rec.ptr);
    ev.user_data = sub.user_data;
    ev.watch = sub.entry.index;
    ev.status = status;
    ev.dropped = dropped;
    ev.detail = .{ .off = @sizeOf(abi.WatchStatusEvent), .len = @intCast(detail.len) };
    @memcpy(rec[@sizeOf(abi.WatchStatusEvent)..][0..detail.len], detail);
    sub.home.postRemote(rec);
}

fn postEnd(sub: *Sub, reason: u32, detail: []const u8) void {
    const size = abi.alignUp(@sizeOf(abi.WatchEndEvent) + detail.len);
    const rec = engine.newRecord(size, .watch_end, sub.handle()) catch return;
    const ev: *abi.WatchEndEvent = @ptrCast(rec.ptr);
    ev.user_data = sub.user_data;
    ev.watch = sub.entry.index;
    ev.reason = reason;
    ev.detail = .{ .off = @sizeOf(abi.WatchEndEvent), .len = @intCast(detail.len) };
    @memcpy(rec[@sizeOf(abi.WatchEndEvent)..][0..detail.len], detail);
    sub.home.postRemote(rec);
}

fn opOf(op: aw.Op) u16 {
    return switch (op) {
        .message => abi.WATCH_OP_MESSAGE,
        .entry => abi.WATCH_OP_ENTRY,
        .insert => abi.WATCH_OP_INSERT,
        .update => abi.WATCH_OP_UPDATE,
        .replace => abi.WATCH_OP_REPLACE,
        .delete => abi.WATCH_OP_DELETE,
        .drop => abi.WATCH_OP_DROP,
        .rename => abi.WATCH_OP_RENAME,
        .drop_database => abi.WATCH_OP_DROP_DATABASE,
        .invalidate => abi.WATCH_OP_INVALIDATE,
        .other, .gap => abi.WATCH_OP_OTHER,
    };
}

/// An event as a record: the header, the fields' spans, then the bytes.
fn buildEvent(sub: *Sub, ev: *const aw.Event) ![]align(8) u8 {
    const json = sub.format == abi.WATCH_JSON;
    const format: u32 = switch (ev.source) {
        .postgres, .redis => abi.WATCH_FMT_TEXT,
        .redis_stream => if (json) abi.WATCH_FMT_JSON else abi.WATCH_FMT_FIELDS,
        .mongodb => if (json or ev.change == null) abi.WATCH_FMT_JSON else abi.WATCH_FMT_BSON,
    };
    const data: []const u8 = switch (format) {
        abi.WATCH_FMT_FIELDS => "",
        abi.WATCH_FMT_BSON => ev.change.?.bytes,
        else => ev.data,
    };
    const nfields: usize = if (format == abi.WATCH_FMT_FIELDS) ev.fields.len else 0;
    var size: usize = @sizeOf(abi.WatchEvent) + nfields * 2 * @sizeOf(abi.Span);
    const pattern = ev.pattern orelse "";
    const position = ev.position orelse "";
    size += ev.channel.len + pattern.len + ev.op_name.len + position.len + data.len;
    if (nfields > 0) for (ev.fields) |f| {
        size += f[0].len + f[1].len;
    };
    const n = abi.alignUp(size);
    const rec = try engine.newRecord(n, .watch_event, sub.handle());
    const out: *abi.WatchEvent = @ptrCast(rec.ptr);
    var pos: usize = @sizeOf(abi.WatchEvent) + nfields * 2 * @sizeOf(abi.Span);
    const put = struct {
        fn f(buf: []u8, p: *usize, s: []const u8) abi.Span {
            const at = p.*;
            @memcpy(buf[at..][0..s.len], s);
            p.* += s.len;
            return .{ .off = @intCast(at), .len = @intCast(s.len) };
        }
    }.f;
    out.user_data = sub.user_data;
    out.watch = sub.entry.index;
    out.source = @intCast(sub.entry.source);
    out.op = opOf(ev.op);
    out.format = format;
    out.pg_pid = ev.pg_pid;
    out.channel = put(rec, &pos, ev.channel);
    out.pattern = put(rec, &pos, pattern);
    out.op_name = put(rec, &pos, ev.op_name);
    out.position = put(rec, &pos, position);
    out.data = put(rec, &pos, data);
    out.nfields = @intCast(nfields);
    out.fields_off = @sizeOf(abi.WatchEvent);
    if (nfields > 0) {
        const spans: [*]align(1) abi.Span = @ptrCast(rec[@sizeOf(abi.WatchEvent)..].ptr);
        for (ev.fields, 0..) |f, i| {
            spans[2 * i] = put(rec, &pos, f[0]);
            spans[2 * i + 1] = put(rec, &pos, f[1]);
        }
    }
    @memset(rec[pos..n], 0);
    return rec;
}
