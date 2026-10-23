//! `anole_sse_*`: server-sent event topics for consumers (p3/realtime,
//! design-realtime.md §7). Handle kind 14 (`anole_sse`); events 112-113.
//!
//! The topics are Anole's (`anole.sse.Topics`): a publish fans out on
//! Anole's threads without entering the language, a subscriber's stream is
//! parked (no task while idle), and `Last-Event-ID` replay is native. A
//! route in the configuration is served natively (`"sse": {"topics": ...}`)
//! or decided by the consumer (`"handler"`: ANOLE_EV_SSE_SUBSCRIBE, then
//! `anole_sse_accept`).
//!
//! Each executor keeps a table of subscriber slots, grown a chunk at a time
//! and never moved or freed while the engine lives, so a stale handle always
//! lands on a slot whose generation tells it the subscriber is gone. What a
//! consumer asks of a subscriber (join, leave, send, close) is posted to
//! the slot's executor as a command and applied there, in order; before
//! the stream exists the commands wait in the slot.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const placement = dusty.placement;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Route = engine.Route;
const Command = engine.Command;
const Handle = engine.Handle;
const AnswerError = engine.AnswerError;
const gpa = engine.gpa;
const sse = anole.sse;

const log = std.log.scoped(.anole);

const chunk_len = 256;
const max_chunks = 4096;
comptime {
    std.debug.assert(chunk_len * max_chunks <= engine.max_slots);
}

const SlotState = enum(u32) { free, open, reserved };

fn pack(gen: u32, state: SlotState) u64 {
    return (@as(u64, gen) << 32) | @backingInt(state);
}

/// What a consumer asks of a subscriber.
const CmdKind = enum { subscribe, unsubscribe, send, close };

const SseCmd = struct {
    cmd: Command = .{ .run = run },
    handle: u64,
    kind: CmdKind,
    topic: []u8 = &.{},
    last: u32 = 0,
    /// `send`: the encoded event (one reference of this command's).
    payload: ?*sse.Payload = null,
    /// A subscribe or unsubscribe counts as a topic change until applied.
    counted: bool = false,
};

pub const SseSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// Bytes of `anole_sse_send` events not yet written (any thread).
    pending_bytes: std.atomic.Value(usize) = .init(0),
    /// A send got BUSY or AGAIN: ANOLE_EV_WRITABLE when there is room again.
    want_event: std.atomic.Value(bool) = .init(false),

    // Executor-local from here.
    sub: ?*sse.Subscriber = null,
    route: *const Route = undefined,
    exec: *Exec = undefined,
    index: u32 = 0,
    /// Commands taken before the stream exists.
    pending: std.ArrayList(*SseCmd) = .empty,
    /// The stream was set up (`onOpen`): after it the slot is the
    /// subscriber's, and `onClose` retires it.
    opened: bool = false,
    next_free: u32 = engine.no_slot,

    fn gen(s: *const SseSlot) u32 {
        return @intCast(s.word.load(.acquire) >> 32);
    }
    fn live(s: *const SseSlot, g: u32) bool {
        return s.word.load(.acquire) == pack(g, .open);
    }
    fn handle(s: *const SseSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .sse, .slot = @intCast(s.index), .exec = s.exec.index });
    }
};

const Chunk = [chunk_len]SseSlot;

/// Engine-wide state (`Engine.sse_state`).
pub const State = struct {
    /// The topics of the configuration's "sse" block, made by `create`.
    topics: ?*sse.Topics = null,
    first_gen: u32 = 1,
    /// Publishes taken and not yet fanned out, and their bytes.
    publishing: std.atomic.Value(usize) = .init(0),
    publish_bytes: std.atomic.Value(usize) = .init(0),
    publish_dropped: std.atomic.Value(u64) = .init(0),
    /// Joins and leaves taken, and applied: a publish waits for the ones
    /// taken before it.
    topic_changes: std.atomic.Value(u32) = .init(0),
    topic_changes_done: std.atomic.Value(u32) = .init(0),

    pub fn init(s: *State, first_gen: u32) void {
        s.first_gen = first_gen;
    }

    /// The highest generation handed out (`Engine.destroy`).
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        // The topics are the app's (`app.sseTopics`).
        s.topics = null;
    }
};

/// Per executor (`Exec.sse`): the slot table and the publish lane.
pub const ExecState = struct {
    chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
    nchunks: u32 = 0,
    free_head: u32 = engine.no_slot,
    /// The publish lane's task.
    work: std.Io.Group = .init,
    lane_head: ?*PublishCmd = null,
    lane_tail: ?*PublishCmd = null,
    lane_running: bool = false,

    fn slot(st: *ExecState, i: u32) ?*SseSlot {
        if (i / chunk_len >= max_chunks) return null;
        const c = st.chunks[i / chunk_len].load(.acquire) orelse return null;
        return &c[i % chunk_len];
    }

    fn alloc(st: *ExecState, x: *Exec) !*SseSlot {
        if (st.free_head == engine.no_slot) {
            if (st.nchunks == max_chunks) return error.TooManySubscribers;
            const c = try gpa.create(Chunk);
            const base = st.nchunks * chunk_len;
            for (c, 0..) |*s, j| s.* = .{
                .word = .init(pack(x.engine.first_gen, .free)),
                .exec = x,
                .index = @intCast(base + j),
                .next_free = if (j + 1 < chunk_len) @intCast(base + j + 1) else engine.no_slot,
            };
            st.chunks[st.nchunks].store(c, .release);
            st.nchunks += 1;
            st.free_head = base;
        }
        const s = st.slot(st.free_head).?;
        st.free_head = s.next_free;
        return s;
    }

    /// A slot for a subscription the consumer is deciding: not open, its
    /// handle not handed out.
    fn reserve(st: *ExecState, x: *Exec, route: *const Route) !*SseSlot {
        const s = try st.alloc(x);
        const g = s.gen();
        s.pending_bytes.store(0, .monotonic);
        s.want_event.store(false, .monotonic);
        s.sub = null;
        s.opened = false;
        s.route = route;
        s.word.store(pack(g, .reserved), .release);
        return s;
    }

    /// A reserved slot that was not used: back on the free list under a
    /// new generation.
    fn unreserve(st: *ExecState, s: *SseSlot) void {
        const g = s.gen();
        s.word.store(pack(engine.nextGen(g), .free), .release);
        s.next_free = st.free_head;
        st.free_head = s.index;
    }

    pub fn maxGen(st: *const ExecState) u32 {
        var max: u32 = 0;
        for (st.chunks[0..st.nchunks]) |*cv| {
            for (cv.load(.acquire).?) |*s| max = @max(max, s.gen());
        }
        return max;
    }

    pub fn deinit(st: *ExecState) void {
        st.dropLane();
        for (st.chunks[0..st.nchunks]) |*cv| {
            const c = cv.load(.acquire).?;
            for (c) |*s| {
                for (s.pending.items) |cmd| freeCmd(cmd);
                s.pending.deinit(gpa);
            }
            gpa.destroy(c);
        }
        st.nchunks = 0;
    }

    fn dropLane(st: *ExecState) void {
        while (st.lane_head) |p| {
            st.lane_head = p.next;
            p.free();
        }
        st.lane_tail = null;
    }

    /// Cancels the executor's SSE work (at the server's end).
    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }
};

fn slotOf(e: *Engine, hv: u64) engine.HandleError!struct { *SseSlot, u32 } {
    const h = Handle.decode(hv);
    if (hv == 0 or h.gen == 0 or h.kind != .sse) return error.WrongKind;
    if (h.exec >= e.execs.len) return error.Over;
    const s = e.execs[h.exec].sse.slot(h.slot) orelse return error.Over;
    return .{ s, h.gen };
}

/// `anole_sse_accept`: the reserved slot `i` of `x` becomes the open
/// subscriber of the subscription the consumer accepted; its handle. Any
/// thread.
pub fn openReserved(x: *Exec, i: u32) u64 {
    const s = x.sse.slot(i).?;
    const g = s.gen();
    s.word.store(pack(g, .open), .release);
    return s.handle(g);
}

// ---------------------------------------------------------------------------
// The configuration's topics

/// `anole_server_create`, after the configuration is parsed. The topics
/// themselves are made when the server opens (`openTopics`): they are the
/// app's, freed with it.
pub fn create(e: *Engine, why: *std.Io.Writer) !void {
    _ = e;
    _ = why;
}

/// The configuration's topics, made on `app` (called by `watch.open`).
pub fn openTopics(e: *Engine, app: *anole.App) !void {
    const c = e.config.sse;
    const options: sse.Topics.Options = .{
        .heartbeat = if (c.heartbeat_ms) |ms| .fromMilliseconds(ms) else null,
        .retry = if (c.retry_ms) |ms| .fromMilliseconds(ms) else null,
        .replay = if (c.replay) |r| .{
            .events = r.events,
            .bytes = r.bytes,
            .total_bytes = std.math.cast(usize, r.total_bytes) orelse std.math.maxInt(usize),
            .max_age = .fromMilliseconds(r.max_age_ms),
            .max_per_resume = r.max_per_resume,
        } else null,
        .max_queued_bytes = c.max_queued_bytes,
        .on_full = switch (c.on_full) {
            .close => .close,
            .drop => .drop,
        },
        .close_after = .fromMilliseconds(c.close_after_ms),
        .leave_grace = .fromMilliseconds(c.leave_grace_ms),
        .max_topics_per_subscriber = c.max_topics_per_subscriber,
        .gap_event = c.gap_event,
        .drain_retry = if (c.drain_retry) |d| .{ .min = .fromMilliseconds(d.min_ms), .max = .fromMilliseconds(d.max_ms) } else null,
    };
    const t = try app.sseTopics(options);
    t.written_hook = onWritten;
    e.sse_state.topics = t;
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    _ = e;
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    _ = e;
}

/// `anole_handle_release` for the kind `sse` (a cleanup call: a handle that
/// is over answers `error.Over`, which is `ANOLE_OK`).
pub fn release(e: *Engine, hv: u64) AnswerError!void {
    return closeSub(e, hv);
}

// ---------------------------------------------------------------------------
// The routes (on the request's executor)

/// A natively served route (`"sse": {"topics": [...]}`) or one the consumer
/// decides (`"handler"`).
pub fn handler(req: *dusty.Request, res: *dusty.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const e = route.engine;
    const sr = route.sse.?;
    const topics = e.sse_state.topics orelse return error.InternalServerError;
    if (e.abandon.load(.acquire)) {
        res.fail(.service_unavailable, "the server is stopping");
        return;
    }
    const xi = placement.currentExecutor(req.io) orelse return error.InternalServerError;
    const x = &e.execs[xi];
    var names: std.ArrayList([]const u8) = .empty;
    for (sr.topics) |t| try names.append(req.arena, try sse.renderTopic(req, t));
    if (!sr.consumer) return topics.serve(req, res, .{ .topics = names.items, .last = sr.last });

    if (x.consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    const slot = x.sse.reserve(x, route) catch {
        res.fail(.service_unavailable, "too many subscribers");
        return;
    };
    var up: engine.Upgrade = .{ .ws_slot = slot.index, .sse = true };
    engine.serveUpgrade(route, req, res, &up) catch |err| {
        x.sse.unreserve(slot);
        return err;
    };
    if (!up.accepted) {
        x.sse.unreserve(slot);
        return;
    }
    // Accepted: the consumer holds the handle. If the stream cannot be
    // set up, it hears it end.
    const g = slot.gen();
    defer if (!slot.opened) retire(x, slot, g, abi.SSE_CLOSED_SERVER);
    for (up.sse_topics) |t| try names.append(req.arena, t);
    const hdrs = try req.arena.alloc([2][]const u8, up.headers.len);
    for (up.headers, hdrs) |h, *out| out.* = .{ h.name, h.value };
    return topics.serve(req, res, .{
        .topics = names.items,
        .last = @intCast(@min(if (up.sse_last > 0) up.sse_last else sr.last, std.math.maxInt(u16))),
        .headers = hdrs,
        .context = slot,
        .on_open = onOpen,
        .on_close = onClose,
    });
}

/// The stream is out (on the request's executor, before the replay): the
/// subscriber is the slot's, and what the consumer asked meanwhile applies.
fn onOpen(sub: *sse.Subscriber) void {
    const slot: *SseSlot = @ptrCast(@alignCast(sub.context.?));
    slot.sub = sub;
    slot.opened = true;
    var list = slot.pending;
    slot.pending = .empty;
    const e = slot.exec.engine;
    for (list.items) |cmd| applyCmd(e, slot, cmd);
    list.deinit(gpa);
}

/// The subscriber ended: its handle goes stale, and the consumer hears it.
fn onClose(sub: *sse.Subscriber, reason: sse.CloseReason) void {
    const slot: *SseSlot = @ptrCast(@alignCast(sub.context.?));
    slot.sub = null;
    retire(slot.exec, slot, slot.gen(), @intFromEnum(reason));
}

fn retire(x: *Exec, s: *SseSlot, g: u32, reason: u32) void {
    s.word.store(pack(engine.nextGen(g), .free), .release);
    s.sub = null;
    for (s.pending.items) |cmd| dropCmd(x.engine, cmd);
    s.pending.clearRetainingCapacity();
    if (engine.newRecord(@sizeOf(abi.SseCloseEvent), .sse_close, s.handle(g))) |rec| {
        const ev: *abi.SseCloseEvent = @ptrCast(rec.ptr);
        ev.route_id = s.route.id;
        ev.reason = reason;
        x.postRemote(rec);
    } else |_| {}
    s.next_free = x.sse.free_head;
    x.sse.free_head = s.index;
}

/// A sender wrote `bytes` of the subscriber's own events: room again?
fn onWritten(sub: *sse.Subscriber, bytes: usize) void {
    const ctx = sub.context orelse return;
    const slot: *SseSlot = @ptrCast(@alignCast(ctx));
    const before = slot.pending_bytes.fetchSub(bytes, .acq_rel);
    const left = before -| bytes;
    const cap = sub.hub.options.max_queued_bytes;
    if (left <= cap / 4 and slot.want_event.cmpxchgStrong(true, false, .acq_rel, .monotonic) == null) {
        slot.exec.postEvent(.writable, slot.handle(slot.gen()));
    }
}

// ---------------------------------------------------------------------------
// Commands

fn freeCmd(c: *SseCmd) void {
    gpa.free(c.topic);
    if (c.payload) |p| p.release(gpa);
    gpa.destroy(c);
}

fn changeDone(e: *Engine) void {
    _ = e.sse_state.topic_changes_done.fetchAdd(1, .acq_rel);
    if (e.phase.load(.acquire) == .stopped) return;
    e.io.futexWake(u32, &e.sse_state.topic_changes_done.raw, std.math.maxInt(u32));
}

fn run(cmd: *Command, x: *Exec) void {
    const c: *SseCmd = @alignCast(@fieldParentPtr("cmd", cmd));
    const e = x.engine;
    const found = slotOf(e, c.handle) catch null;
    if (found == null or !found.?[0].live(found.?[1]) or e.phase.load(.acquire) == .stopped) {
        dropCmd(e, c);
        return;
    }
    const s = found.?[0];
    // Before the stream exists: kept in order.
    if (s.sub == null) {
        s.pending.append(gpa, c) catch dropCmd(e, c);
        return;
    }
    applyCmd(e, s, c);
}

/// A command that will not run: what it counted is given back.
fn dropCmd(e: *Engine, c: *SseCmd) void {
    if (c.kind == .send) if (c.payload) |p| {
        if (slotOf(e, c.handle)) |found| {
            _ = found[0].pending_bytes.fetchSub(p.len, .acq_rel);
        } else |_| {}
    };
    const counted = c.counted;
    freeCmd(c);
    if (counted) changeDone(e);
}

fn applyCmd(e: *Engine, s: *SseSlot, c: *SseCmd) void {
    const sub = s.sub.?;
    switch (c.kind) {
        .subscribe => sub.join(c.topic, .{ .last = @intCast(@min(c.last, std.math.maxInt(u16))) }) catch |err| log.debug("sse: join \"{s}\" failed: {t}", .{ c.topic, err }),
        .unsubscribe => sub.leave(c.topic),
        .send => {
            const p = c.payload.?;
            sub._sendPayload(p) catch {
                _ = s.pending_bytes.fetchSub(p.len, .acq_rel);
            };
        },
        .close => sub.close(),
    }
    const counted = c.counted;
    freeCmd(c);
    if (counted) changeDone(e);
}

fn checkTopic(topic: []const u8) AnswerError!void {
    if (topic.len == 0 or topic.len > sse.max_topic_len) return error.Invalid;
}

/// `anole_sse_subscribe`: an answer call (`Gone` when the subscriber is over).
pub fn subscribe(e: *Engine, hv: u64, topic: []const u8, last: u32) AnswerError!void {
    try checkTopic(topic);
    const s, const g = slotOf(e, hv) catch |err| return e.badHandle(err);
    if (!s.live(g)) return e.gone();
    const c = try gpa.create(SseCmd);
    errdefer gpa.destroy(c);
    c.* = .{ .handle = hv, .kind = .subscribe, .topic = try gpa.dupe(u8, topic), .last = last, .counted = true };
    _ = e.sse_state.topic_changes.fetchAdd(1, .acq_rel);
    s.exec.post(&c.cmd);
}

/// `anole_sse_unsubscribe`: a cleanup call.
pub fn unsubscribe(e: *Engine, hv: u64, topic: []const u8) AnswerError!void {
    try checkTopic(topic);
    const s, const g = try slotOf(e, hv);
    if (!s.live(g)) return error.Over;
    const c = try gpa.create(SseCmd);
    errdefer gpa.destroy(c);
    c.* = .{ .handle = hv, .kind = .unsubscribe, .topic = try gpa.dupe(u8, topic), .counted = true };
    _ = e.sse_state.topic_changes.fetchAdd(1, .acq_rel);
    s.exec.post(&c.cmd);
}

/// `anole_sse_close`: a cleanup call.
pub fn closeSub(e: *Engine, hv: u64) AnswerError!void {
    const s, const g = try slotOf(e, hv);
    if (!s.live(g)) return error.Over;
    const c = try gpa.create(SseCmd);
    c.* = .{ .handle = hv, .kind = .close };
    s.exec.post(&c.cmd);
}

/// `anole_sse_send`: whether the call got BUSY (the event is taken).
/// `error.Again`: the queue is full, nothing was taken, and a WRITABLE
/// follows.
pub fn send(e: *Engine, hv: u64, event: []const u8, data: []const u8) AnswerError!bool {
    if (std.mem.indexOfAny(u8, event, "\r\n") != null) return error.Invalid;
    if (data.len > e.config.limits.sse_max_event) return error.Invalid;
    const s, const g = slotOf(e, hv) catch |err| return e.badHandle(err);
    if (!s.live(g)) return e.gone();
    const topics = e.sse_state.topics orelse return error.State;
    const p = topics._encode(.{ .data = data, .event = if (event.len > 0) event else null }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
    errdefer p.release(gpa);
    const cap = topics.options.max_queued_bytes;
    const before = s.pending_bytes.fetchAdd(p.len, .acq_rel);
    if (before > 0 and before + p.len > cap) {
        _ = s.pending_bytes.fetchSub(p.len, .acq_rel);
        s.want_event.store(true, .release);
        return error.Again;
    }
    const busy = before + p.len > cap / 2;
    if (busy) s.want_event.store(true, .release);
    const c = gpa.create(SseCmd) catch {
        _ = s.pending_bytes.fetchSub(p.len, .acq_rel);
        return error.OutOfMemory;
    };
    c.* = .{ .handle = hv, .kind = .send, .payload = p };
    s.exec.post(&c.cmd);
    return busy;
}

// ---------------------------------------------------------------------------
// Publishing

const PublishCmd = struct {
    cmd: Command = .{ .run = runPublish },
    engine: *Engine,
    topic: []u8,
    payload: *sse.Payload,
    record: bool,
    /// `Engine.sse_state.topic_changes` when it was taken.
    after: u32,
    next: ?*PublishCmd = null,

    fn free(p: *PublishCmd) void {
        const st = &p.engine.sse_state;
        _ = st.publishing.fetchSub(1, .monotonic);
        _ = st.publish_bytes.fetchSub(p.topic.len + p.payload.len, .monotonic);
        gpa.free(p.topic);
        p.payload.release(gpa);
        gpa.destroy(p);
    }
};

/// Publishes taken and not yet fanned out, at most; past either limit
/// `publish` refuses (`error.Again`).
pub fn publishLimits(e: *const Engine) struct { tasks: usize, bytes: usize } {
    const cap: usize = e.config.sse.max_queued_bytes;
    const max_event: usize = e.config.limits.sse_max_event;
    return .{
        .tasks = 64 * @max(e.execs.len, 1),
        .bytes = @max(16 * cap, 2 * max_event),
    };
}

/// `anole_sse_publish`.
pub fn publish(e: *Engine, topic: []const u8, event: []const u8, data: []const u8, flags: u32) AnswerError!void {
    if (flags & ~abi.SSE_F_NO_REPLAY != 0) return error.Invalid;
    try checkTopic(topic);
    if (std.mem.indexOfAny(u8, event, "\r\n") != null) return error.Invalid;
    if (data.len > e.config.limits.sse_max_event) return error.Invalid;
    if (e.phase.load(.acquire) != .running) return error.State;
    const st = &e.sse_state;
    const hub = st.topics orelse return error.State;
    const lim = publishLimits(e);
    const size = topic.len + data.len;
    const tasks = st.publishing.fetchAdd(1, .monotonic);
    const bytes = st.publish_bytes.fetchAdd(size, .monotonic);
    if (tasks >= lim.tasks or bytes + size > lim.bytes) {
        _ = st.publishing.fetchSub(1, .monotonic);
        _ = st.publish_bytes.fetchSub(size, .monotonic);
        _ = st.publish_dropped.fetchAdd(1, .monotonic);
        return error.Again;
    }
    errdefer {
        _ = st.publishing.fetchSub(1, .monotonic);
        _ = st.publish_bytes.fetchSub(size, .monotonic);
    }
    const p = try gpa.create(PublishCmd);
    errdefer gpa.destroy(p);
    const t = try gpa.dupe(u8, topic);
    errdefer gpa.free(t);
    const payload = hub._encode(.{ .data = data, .event = if (event.len > 0) event else null }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
    p.* = .{ .engine = e, .topic = t, .payload = payload, .record = flags & abi.SSE_F_NO_REPLAY == 0, .after = st.topic_changes.load(.acquire) };
    // One executor per topic, so publishes to a topic fan out in the order
    // they were taken.
    const xi: usize = @intCast(std.hash.Wyhash.hash(0, topic) % e.execs.len);
    e.execs[xi].post(&p.cmd);
}

fn runPublish(cmd: *Command, x: *Exec) void {
    const p: *PublishCmd = @alignCast(@fieldParentPtr("cmd", cmd));
    if (x.engine.phase.load(.acquire) == .stopped) return p.free();
    const st = &x.sse;
    p.next = null;
    if (st.lane_tail) |t| t.next = p else st.lane_head = p;
    st.lane_tail = p;
    if (st.lane_running) return;
    st.lane_running = true;
    placement.concurrent(&st.work, x.engine.io, .local, publishLane, .{ x.engine, x }) catch {
        st.lane_running = false;
        while (st.lane_head) |q| {
            st.lane_head = q.next;
            _ = x.engine.sse_state.publish_dropped.fetchAdd(1, .monotonic);
            q.free();
        }
        st.lane_tail = null;
    };
}

fn awaitTopicChanges(e: *Engine, want: u32) std.Io.Cancelable!void {
    const st = &e.sse_state;
    while (true) {
        const done = st.topic_changes_done.load(.acquire);
        if (@as(i32, @bitCast(done -% want)) >= 0) return;
        try e.io.futexWait(u32, &st.topic_changes_done.raw, done);
    }
}

fn publishLane(e: *Engine, x: *Exec) std.Io.Cancelable!void {
    const st = &x.sse;
    const hub = e.sse_state.topics orelse return;
    while (true) {
        const p = st.lane_head orelse {
            st.lane_running = false;
            return;
        };
        st.lane_head = p.next;
        if (st.lane_head == null) st.lane_tail = null;
        defer p.free();
        awaitTopicChanges(e, p.after) catch |err| {
            st.lane_running = false;
            st.dropLane();
            return err;
        };
        _ = hub._publishPayload(p.topic, p.payload, p.record);
    }
}

/// `anole_sse_gap`.
pub fn gap(e: *Engine, topic: []const u8, flags: u32) AnswerError!void {
    if (flags & ~abi.SSE_F_PREFIX != 0) return error.Invalid;
    if (flags & abi.SSE_F_PREFIX == 0) try checkTopic(topic);
    if (topic.len > sse.max_topic_len) return error.Invalid;
    if (e.phase.load(.acquire) != .running) return error.State;
    const hub = e.sse_state.topics orelse return error.State;
    if (flags & abi.SSE_F_PREFIX != 0) hub.gapPrefix(topic) else hub.gap(topic);
}

/// `anole_sse_accept`'s topics, validated, in `arena`.
pub fn acceptTopics(strs: []const abi.Str, arena: std.mem.Allocator) AnswerError![]const []const u8 {
    const out = try arena.alloc([]const u8, strs.len);
    for (strs, out) |s, *o| {
        o.* = s.slice();
        try checkTopic(o.*);
    }
    return out;
}
