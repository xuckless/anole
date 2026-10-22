//! WebSocket routes of the C ABI: Anole's callback sockets
//! (`anole.websocket.serveTable`), whose open, message and close events go
//! to the consumer through the same rings as requests, and whose sends,
//! closes and topic changes come back by handle.
//!
//! Each executor keeps a table of socket slots, grown a chunk at a time and
//! never moved or freed while the engine lives, so a stale `anole_ws` handle
//! always lands on a slot whose generation tells it the socket is gone.
//! What a consumer sends waits in the slot's outbox; a sender task on the
//! socket's executor, started when the outbox goes from empty to not, takes
//! it out and writes it. Topics are Anole's `Rooms`: a publish fans out on
//! Anole's threads without entering the language.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const abi = @import("abi.zig");
const engine = @import("engine.zig");
const placement = dusty.placement;
const websocket = anole.websocket;
const Socket = websocket.Socket;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Route = engine.Route;
const Command = engine.Command;
const Handle = engine.Handle;
const gpa = engine.gpa;

const chunk_len = 256;
const max_chunks = 4096;

const State = enum(u32) { free, open };

fn pack(gen: u32, state: State) u64 {
    return (@as(u64, gen) << 32) | @intFromEnum(state);
}

const OutMsg = struct {
    type: websocket.MessageType,
    data: []const u8,
    owned: bool,
};

pub const WsSlot = struct {
    word: std.atomic.Value(u64) = .init(pack(1, .free)),
    /// Over the outbox fields; never held across a send.
    lock: std.atomic.Mutex = .unlocked,
    msgs: std.ArrayList(OutMsg) = .empty,
    /// Bytes queued or being sent.
    bytes: usize = 0,
    /// A send got ANOLE_BUSY: ANOLE_EV_WS_DRAIN when there is room again.
    want_event: bool = false,
    /// A sender task is running or about to.
    scheduled: bool = false,
    /// `kick` is in the executor's inbox (it may outlive the socket that
    /// posted it, so it is never posted twice).
    kick_pending: bool = false,
    /// `anole_ws_close` asked for this close.
    close_code: ?u16 = null,
    close_reason: []u8 = &.{},

    // Executor-local from here.
    socket: ?*Socket = null,
    route: *const Route = undefined,
    exec: *Exec = undefined,
    index: u32 = 0,
    topics: std.ArrayList([]u8) = .empty,
    kick: Command = .{ .run = runKick },
    sender: std.Io.Group = .init,
    next_free: u32 = engine.no_slot,

    fn acquire(s: *WsSlot) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(s: *WsSlot) void {
        s.lock.unlock();
    }
    fn gen(s: *const WsSlot) u32 {
        return @intCast(s.word.load(.acquire) >> 32);
    }
    fn live(s: *const WsSlot, g: u32) bool {
        return s.word.load(.acquire) == pack(g, .open);
    }
    fn handle(s: *const WsSlot, g: u32) u64 {
        return Handle.encode(.{ .gen = @intCast(g), .kind = .websocket, .slot = @intCast(s.index), .exec = s.exec.index });
    }
};

const Chunk = [chunk_len]WsSlot;

pub const ExecState = struct {
    chunks: [max_chunks]std.atomic.Value(?*Chunk) = @splat(.init(null)),
    nchunks: u32 = 0,
    free_head: u32 = engine.no_slot,
    /// Unsubscribes and publishes.
    work: std.Io.Group = .init,

    fn slot(st: *ExecState, i: u32) ?*WsSlot {
        // `i` may come from a made-up handle: past the table is no socket.
        if (i / chunk_len >= max_chunks) return null;
        const c = st.chunks[i / chunk_len].load(.acquire) orelse return null;
        return &c[i % chunk_len];
    }

    fn alloc(st: *ExecState, x: *Exec) !*WsSlot {
        if (st.free_head == engine.no_slot) {
            if (st.nchunks == max_chunks) return error.TooManyWebSockets;
            const c = try gpa.create(Chunk);
            const base = st.nchunks * chunk_len;
            for (c, 0..) |*s, j| s.* = .{
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

    pub fn deinit(st: *ExecState) void {
        for (st.chunks[0..st.nchunks]) |*cv| {
            const c = cv.load(.acquire).?;
            for (c) |*s| {
                for (s.msgs.items) |m| if (m.owned) gpa.free(m.data);
                s.msgs.deinit(gpa);
                gpa.free(s.close_reason);
                for (s.topics.items) |t| gpa.free(t);
                s.topics.deinit(gpa);
            }
            gpa.destroy(c);
        }
        st.nchunks = 0;
    }

    /// Cancels the executor's WebSocket work (at the server's end).
    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }
};

fn slotOf(e: *Engine, hv: u64) ?struct { *WsSlot, u32 } {
    const h = Handle.decode(hv);
    if (h.gen == 0 or h.kind != .websocket or h.exec >= e.execs.len) return null;
    const s = e.execs[h.exec].ws.slot(h.slot) orelse return null;
    return .{ s, h.gen };
}

// ---------------------------------------------------------------------------
// The route and its callbacks (on the socket's executor)

const table: websocket.Table = .{ .open = onOpen, .message = onMessage, .close = onClose };

pub fn handler(req: *dusty.Request, res: *dusty.Response) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(req.route.?.data.?));
    const e = route.engine;
    const xi = placement.currentExecutor(req.io) orelse return error.InternalServerError;
    if (e.execs[xi].consumer == null) {
        res.fail(.service_unavailable, "no consumer");
        return;
    }
    return websocket.serveTable(req, res, route.ws.?, &table, @constCast(route));
}

fn onOpen(state: ?*anyopaque, sock: *Socket, req: *dusty.Request) anyerror!void {
    const route: *const Route = @ptrCast(@alignCast(state.?));
    const e = route.engine;
    const x = &e.execs[placement.currentExecutor(req.io).?];
    const s = try x.ws.alloc(x);
    const g = s.gen();
    s.socket = sock;
    s.route = route;
    s.bytes = 0;
    s.want_event = false;
    s.close_code = null;
    sock.context = s;
    s.word.store(pack(g, .open), .release);
    _ = e.websockets.fetchAdd(1, .monotonic);

    var remote: [64]u8 = undefined;
    const head: engine.Head = .{
        .req = req,
        .route_id = route.id,
        .flags = if (req.secure) abi.REQ_SECURE else 0,
        .remote = remote[0..engine.remoteText(req, &remote)],
        .claims = engine.claimsOf(req),
    };
    const size = head.size();
    const rec = try gpa.alignedAlloc(u8, .@"8", size);
    _ = head.encode(.ws_open, s.handle(g), rec);
    x.postRecord(rec, true);
}

fn onMessage(_: ?*anyopaque, sock: *Socket, msg: websocket.Message) anyerror!void {
    const s: *WsSlot = @ptrCast(@alignCast(sock.context.?));
    const x = s.exec;
    _ = x.engine.ws_in.fetchAdd(1, .monotonic);
    const size = @sizeOf(abi.WsMessageEvent) + msg.data.len;
    const n = abi.alignUp(size);
    const rec = try gpa.alignedAlloc(u8, .@"8", n);
    const ev: *abi.WsMessageEvent = @ptrCast(rec.ptr);
    ev.* = .{
        .ev = .{ .type = @intFromEnum(abi.EventType.ws_message), .len = @intCast(n), .handle = s.handle(s.gen()) },
        .route_id = s.route.id,
        .type = if (msg.type == .text) @intCast(abi.WS_TEXT) else @intCast(abi.WS_BINARY),
        .data = .{ .off = @sizeOf(abi.WsMessageEvent), .len = @intCast(msg.data.len) },
    };
    @memcpy(rec[@sizeOf(abi.WsMessageEvent)..][0..msg.data.len], msg.data);
    @memset(rec[size..], 0);
    // A consumer far behind holds this socket's reading back.
    x.postRecord(rec, true);
}

fn onClose(_: ?*anyopaque, sock: *Socket) void {
    const s: *WsSlot = @ptrCast(@alignCast(sock.context orelse return));
    const x = s.exec;
    const e = x.engine;
    const g = s.gen();
    // Stale from here: the consumer's calls get ANOLE_E_GONE.
    const next = engine.nextGen(g);
    s.acquire();
    s.word.store(pack(next, .free), .release);
    s.release();
    s.sender.cancel(e.io);
    s.acquire();
    var rest = s.msgs;
    s.msgs = .empty;
    s.bytes = 0;
    s.scheduled = false;
    gpa.free(s.close_reason);
    s.close_reason = &.{};
    s.release();
    for (rest.items) |m| if (m.owned) gpa.free(m.data) else x.postSent(s.handle(g), m.data);
    rest.deinit(gpa);
    for (s.topics.items) |t| {
        e.rooms.leave(t, sock);
        gpa.free(t);
    }
    s.topics.clearRetainingCapacity();
    sock.context = null;
    s.socket = null;

    const code: u16 = if (sock.close_code) |c| @intFromEnum(c) else if (sock.end_error != null) 1006 else 1005;
    if (newRecord(@sizeOf(abi.WsCloseEvent), .ws_close, s.handle(g))) |rec| {
        const ev: *abi.WsCloseEvent = @ptrCast(rec.ptr);
        ev.route_id = s.route.id;
        ev.code = code;
        x.postRecord(rec, true);
    } else |_| {}
    _ = e.websockets.fetchSub(1, .monotonic);
    s.next_free = x.ws.free_head;
    x.ws.free_head = s.index;
}

fn newRecord(size: usize, typ: abi.EventType, h: u64) ![]align(8) u8 {
    const n = abi.alignUp(size);
    const rec = try gpa.alignedAlloc(u8, .@"8", n);
    @memset(rec, 0);
    const ev: *abi.Event = @ptrCast(rec.ptr);
    ev.* = .{ .type = @intFromEnum(typ), .len = @intCast(n), .handle = h };
    return rec;
}

// ---------------------------------------------------------------------------
// Sending (the slot's sender task)

fn runKick(cmd: *Command, x: *Exec) void {
    const s: *WsSlot = @fieldParentPtr("kick", cmd);
    s.acquire();
    s.kick_pending = false;
    s.release();
    if (s.socket == null) {
        s.acquire();
        s.scheduled = false;
        s.release();
        return;
    }
    placement.concurrent(&s.sender, x.engine.io, .local, sender, .{s}) catch {
        s.acquire();
        s.scheduled = false;
        s.release();
    };
}

fn sender(s: *WsSlot) std.Io.Cancelable!void {
    const x = s.exec;
    const e = x.engine;
    const sock = s.socket orelse return;
    const g = s.gen();
    const high = e.config.limits.ws_high_water;
    while (true) {
        s.acquire();
        if (!s.live(g)) {
            s.release();
            return;
        }
        const batch = s.msgs;
        s.msgs = .empty;
        const close_code = s.close_code;
        s.close_code = null;
        const reason = s.close_reason;
        s.close_reason = &.{};
        if (batch.items.len == 0 and close_code == null) {
            s.scheduled = false;
            s.release();
            return;
        }
        s.release();
        defer gpa.free(reason);
        var list = batch;
        defer list.deinit(gpa);
        var sent: usize = 0;
        var failed = false;
        for (list.items) |m| {
            if (!failed) {
                if (sock.send(m.type, m.data)) |_| {
                    _ = e.ws_out.fetchAdd(1, .monotonic);
                } else |_| failed = true;
            }
            sent += m.data.len;
            if (m.owned) gpa.free(m.data) else x.postSent(s.handle(g), m.data);
        }
        if (close_code) |c| sock.close(@enumFromInt(c), reason) catch {};
        s.acquire();
        s.bytes -|= sent;
        const drained = s.want_event and s.bytes <= high / 2;
        if (drained) s.want_event = false;
        s.release();
        if (drained) x.postEvent(.ws_drain, s.handle(g));
        if (failed) return;
    }
}

/// Queues a message; true when the outbox is past its high-water mark.
pub fn send(e: *Engine, hv: u64, typ: c_int, data: []const u8, borrow: bool) engine.AnswerError!bool {
    const mt: websocket.MessageType = switch (typ) {
        abi.WS_TEXT => .text,
        abi.WS_BINARY => .binary,
        else => return error.Invalid,
    };
    if (data.len > e.config.limits.ws_max_message) return error.Invalid;
    const s, const g = slotOf(e, hv) orelse return e.gone();
    const owned: ?[]u8 = if (borrow) null else try gpa.dupe(u8, data);
    s.acquire();
    if (!s.live(g)) {
        s.release();
        if (owned) |o| gpa.free(o);
        return e.gone();
    }
    s.msgs.append(gpa, .{ .type = mt, .data = owned orelse data, .owned = !borrow }) catch {
        s.release();
        if (owned) |o| gpa.free(o);
        return error.OutOfMemory;
    };
    s.bytes += data.len;
    const busy = s.bytes > e.config.limits.ws_high_water;
    if (busy) s.want_event = true;
    const kick = !s.scheduled and !s.kick_pending;
    if (kick) s.kick_pending = true;
    s.scheduled = true;
    s.release();
    if (kick) s.exec.post(&s.kick);
    return busy;
}

pub fn close(e: *Engine, hv: u64, code: u16, reason: []const u8) engine.AnswerError!void {
    if (!(code >= 1000 and code <= 1003) and !(code >= 1007 and code <= 1014) and !(code >= 3000 and code <= 4999)) return error.Invalid;
    if (reason.len > 123) return error.Invalid;
    const s, const g = slotOf(e, hv) orelse return e.gone();
    const copy = try gpa.dupe(u8, reason);
    s.acquire();
    if (!s.live(g) or s.close_code != null) {
        s.release();
        gpa.free(copy);
        return e.gone();
    }
    s.close_code = code;
    gpa.free(s.close_reason);
    s.close_reason = copy;
    const kick = !s.scheduled and !s.kick_pending;
    if (kick) s.kick_pending = true;
    s.scheduled = true;
    s.release();
    if (kick) s.exec.post(&s.kick);
}

// ---------------------------------------------------------------------------
// Topics

const TopicCmd = struct {
    cmd: Command,
    handle: u64,
    topic: []u8,
    join: bool,
};

fn checkTopic(topic: []const u8) engine.AnswerError!void {
    if (topic.len == 0 or topic.len > 255) return error.Invalid;
}

pub fn subscribe(e: *Engine, hv: u64, topic: []const u8, join: bool) engine.AnswerError!void {
    try checkTopic(topic);
    const s, const g = slotOf(e, hv) orelse return e.gone();
    if (!s.live(g)) return e.gone();
    const c = try gpa.create(TopicCmd);
    c.* = .{ .cmd = .{ .run = runTopic }, .handle = hv, .topic = gpa.dupe(u8, topic) catch {
        gpa.destroy(c);
        return error.OutOfMemory;
    }, .join = join };
    s.exec.post(&c.cmd);
}

fn runTopic(cmd: *Command, x: *Exec) void {
    const c: *TopicCmd = @fieldParentPtr("cmd", cmd);
    const e = x.engine;
    const found = slotOf(e, c.handle);
    if (found == null or !found.?[0].live(found.?[1]) or found.?[0].socket == null or e.phase.load(.acquire) == .stopped) {
        gpa.free(c.topic);
        gpa.destroy(c);
        return;
    }
    const s = found.?[0];
    if (c.join) {
        for (s.topics.items) |t| if (std.mem.eql(u8, t, c.topic)) {
            gpa.free(c.topic);
            gpa.destroy(c);
            return;
        };
        s.topics.append(gpa, c.topic) catch {
            gpa.free(c.topic);
            gpa.destroy(c);
            return;
        };
        e.rooms.join(c.topic, s.socket.?) catch {
            gpa.free(s.topics.pop().?);
        };
        gpa.destroy(c);
        return;
    }
    // Leaving waits for broadcasts sending to the socket: on a task.
    for (s.topics.items, 0..) |t, i| if (std.mem.eql(u8, t, c.topic)) {
        const own = s.topics.swapRemove(i);
        gpa.free(c.topic);
        c.topic = own;
        placement.concurrent(&x.ws.work, e.io, .local, leaveTask, .{ e, s.socket.?, c }) catch {
            e.rooms.leave(own, s.socket.?);
            gpa.free(own);
            gpa.destroy(c);
        };
        return;
    };
    gpa.free(c.topic);
    gpa.destroy(c);
}

fn leaveTask(e: *Engine, sock: *Socket, c: *TopicCmd) std.Io.Cancelable!void {
    e.rooms.leave(c.topic, sock);
    gpa.free(c.topic);
    gpa.destroy(c);
}

const PublishCmd = struct {
    cmd: Command,
    engine: *Engine,
    except: u64,
    type: websocket.MessageType,
    topic: []u8,
    data: []u8,

    fn free(p: *PublishCmd) void {
        _ = p.engine.publishing.fetchSub(1, .monotonic);
        _ = p.engine.publish_bytes.fetchSub(p.topic.len + p.data.len, .monotonic);
        gpa.free(p.topic);
        gpa.free(p.data);
        gpa.destroy(p);
    }
};

/// Publishes taken and not yet fanned out, at most: a member that stops
/// reading holds up the publishes sending to it, and they must not pile up
/// without end. Past either limit `publish` refuses (`error.Again`).
pub fn publishLimits(e: *const Engine) struct { tasks: usize, bytes: usize } {
    const hw: usize = e.config.limits.ws_high_water;
    const max_msg: usize = e.config.limits.ws_max_message;
    return .{
        .tasks = 64 * @max(e.execs.len, 1),
        .bytes = @max(16 * hw, 2 * max_msg),
    };
}

var next_publisher: std.atomic.Value(usize) = .init(0);

pub fn publish(e: *Engine, topic: []const u8, typ: c_int, data: []const u8, except: u64) engine.AnswerError!void {
    try checkTopic(topic);
    const mt: websocket.MessageType = switch (typ) {
        abi.WS_TEXT => .text,
        abi.WS_BINARY => .binary,
        else => return error.Invalid,
    };
    if (data.len > e.config.limits.ws_max_message) return error.Invalid;
    if (e.phase.load(.acquire) != .running) return error.Gone;
    // Counted before anything is copied; `free` gives it back.
    const lim = publishLimits(e);
    const size = topic.len + data.len;
    const tasks = e.publishing.fetchAdd(1, .monotonic);
    const bytes = e.publish_bytes.fetchAdd(size, .monotonic);
    if (tasks >= lim.tasks or bytes + size > lim.bytes) {
        _ = e.publishing.fetchSub(1, .monotonic);
        _ = e.publish_bytes.fetchSub(size, .monotonic);
        _ = e.publish_dropped.fetchAdd(1, .monotonic);
        return error.Again;
    }
    errdefer {
        _ = e.publishing.fetchSub(1, .monotonic);
        _ = e.publish_bytes.fetchSub(size, .monotonic);
    }
    const p = try gpa.create(PublishCmd);
    errdefer gpa.destroy(p);
    const t = try gpa.dupe(u8, topic);
    errdefer gpa.free(t);
    p.* = .{ .cmd = .{ .run = runPublish }, .engine = e, .except = except, .type = mt, .topic = t, .data = try gpa.dupe(u8, data) };
    // Spread over the executors.
    const xi = next_publisher.fetchAdd(1, .monotonic) % e.execs.len;
    e.execs[xi].post(&p.cmd);
}

fn runPublish(cmd: *Command, x: *Exec) void {
    const p: *PublishCmd = @fieldParentPtr("cmd", cmd);
    if (x.engine.phase.load(.acquire) == .stopped) return p.free();
    placement.concurrent(&x.ws.work, x.engine.io, .local, publishTask, .{ x.engine, p }) catch p.free();
}

fn publishTask(e: *Engine, p: *PublishCmd) std.Io.Cancelable!void {
    defer p.free();
    // Only compared, never followed: a stale handle names no member.
    var except: ?*Socket = null;
    if (p.except != 0) if (slotOf(e, p.except)) |found| {
        if (found[0].live(found[1])) except = found[0].socket;
    };
    const reached = e.rooms.broadcast(p.topic, p.type, p.data, except);
    _ = e.ws_out.fetchAdd(reached, .monotonic);
}
