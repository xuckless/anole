//! Watching database changes: PostgreSQL LISTEN/NOTIFY, Redis pub/sub and
//! streams, and MongoDB change streams, fed straight into SSE and
//! WebSocket topics with no handler in between, into a handler, or read by
//! handlers and background tasks (p3/realtime, design-realtime.md).
//!
//!     _ = try app.watch(.{ .postgres = .{ .client = db, .channels = &.{"orders"} } }, .{
//!         .to = &.{.{ .sse = .{ .topics = live, .topic = "orders" } }},
//!     });
//!
//! One source connection feeds every output: PostgreSQL clients share one
//! LISTEN connection and Redis clients one SUBSCRIBE connection among all
//! their watches. A watch whose source loses events (a reconnect of a
//! PostgreSQL or Redis pub/sub connection, a Redis stream entry deleted
//! before it was read, a MongoDB oplog rolled past the resume token) says
//! so: its SSE topics get the `gap` event, its handlers a `.gap` event.

const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const dusty = @import("dusty");
const bson = if (features.mongodb) @import("bson") else struct {
    // Without MongoDB nothing makes a document: the shapes the events name.
    pub const Timestamp = struct { t: u32, i: u32 };
    pub const Value = union(enum) { document: Document };
    pub const Document = struct {
        bytes: []const u8 = "",
        pub fn get(_: Document, _: []const u8) ?Value {
            return null;
        }
        pub fn dupe(d: Document, arena: std.mem.Allocator) error{OutOfMemory}!Document {
            return .{ .bytes = try arena.dupe(u8, d.bytes) };
        }
    };
    pub fn decodeDocument(comptime T: type, _: std.mem.Allocator, _: Document, _: anytype) error{NotFound}!T {
        return error.NotFound;
    }
};
const placement = dusty.placement;
const sse = @import("../sse/root.zig");
const resilience = @import("../resilience/root.zig");
const observe_metrics = @import("../observe/metrics.zig");
pub const template = @import("template.zig");

const log = @import("../errors.zig").log;

const websocket = if (features.websocket) @import("../websocket/root.zig") else struct {
    const Kind_ = enum { text, binary };
    pub const MessageType = Kind_;
    pub const Rooms = struct {
        pub fn broadcast(_: *Rooms, _: []const u8, _: Kind_, _: []const u8, _: ?*anyopaque) usize {
            return 0;
        }
    };
};
pub const MessageType = websocket.MessageType;

const pg_mod = if (features.postgres) @import("../pg/root.zig") else struct {
    pub const Client = void;
};
const redis_mod = if (features.redis) @import("../redis/root.zig") else struct {
    pub const Client = void;
};
const mongodb_mod = if (features.mongodb) @import("../mongodb/root.zig") else struct {
    pub const Client = void;
    pub const FullDocument = enum { default };
    pub const FullDocumentBeforeChange = enum { off };
};

pub const Duration = std.Io.Duration;

pub const Kind = enum { postgres, redis, redis_stream, mongodb };
pub const Op = enum { message, entry, insert, update, replace, delete, drop, rename, drop_database, invalidate, other, gap };

pub const Source = union(Kind) {
    postgres: Postgres,
    redis: Redis,
    redis_stream: RedisStream,
    mongodb: MongoDb,
};

pub const Postgres = struct {
    client: *pg_mod.Client,
    /// 1-63 bytes each (PostgreSQL's NAMEDATALEN); at least one.
    channels: []const []const u8,
};

pub const Redis = struct {
    client: *redis_mod.Client,
    channels: []const []const u8 = &.{},
    /// PSUBSCRIBE patterns ("room:*"); at least one channel or pattern.
    patterns: []const []const u8 = &.{},
};

pub const RedisStream = struct {
    client: *redis_mod.Client,
    /// 1-16 stream keys, read together.
    keys: []const []const u8,
    start: StreamStart = .new,
    group: ?StreamGroup = null,
    /// Entries per read, at most.
    count: u32 = 128,
    /// One XREAD BLOCK's wait; the loop reads again after it.
    block: Duration = .fromSeconds(10),
};

pub const StreamStart = union(enum) {
    /// Entries added after the watch starts (`$`).
    new,
    /// The whole stream (`0`).
    all,
    /// After these entry IDs, one per key, in `keys` order (a saved `position`).
    after: []const []const u8,
};

pub const StreamGroup = struct {
    name: []const u8,
    /// Null: "<host name>-<pid>".
    consumer: ?[]const u8 = null,
    /// XGROUP CREATE ... MKSTREAM when it is missing (from `start`: new -> $, all -> 0).
    create: bool = true,
    ack: Ack = .auto,
};

pub const Ack = enum {
    /// XACK once every output took the entry (a handler: once it succeeded).
    auto,
    /// `Event.ack()` (ABI `anole_watch_ack`).
    manual,
};

pub const MongoDb = struct {
    client: *mongodb_mod.Client,
    /// Both null: the whole deployment (Client.watch). `collection` needs `database`
    /// or the client's default database.
    database: ?[]const u8 = null,
    collection: ?[]const u8 = null,
    /// Stages after $changeStream, as an Extended JSON array:
    /// `[{"$match": {"operationType": {"$in": ["insert", "update"]}}}]`.
    pipeline: []const u8 = "[]",
    full_document: mongodb_mod.FullDocument = .default,
    full_document_before_change: mongodb_mod.FullDocumentBeforeChange = .off,
    start: MongoStart = .now,
    /// A getMore's wait; null: the server's (1 s).
    max_await: ?Duration = null,
    batch_size: ?u32 = null,
    show_expanded_events: bool = false,
};

pub const MongoStart = union(enum) {
    now,
    /// A resume token as canonical Extended JSON (a saved `position`).
    resume_after: []const u8,
    start_after: []const u8,
    at: bson.Timestamp,
};

pub const Target = union(enum) {
    sse: struct { topics: *sse.Topics, topic: []const u8, event: ?[]const u8 = null },
    ws: struct {
        rooms: *websocket.Rooms,
        room: []const u8,
        type: MessageType = .text,
        /// Broadcast on a gap; null: nothing.
        gap_message: ?[]const u8 = null,
    },
};

/// What targets get as data.
pub const Data = enum {
    /// PostgreSQL and Redis: the payload as sent; a stream entry: its fields
    /// as a JSON object; MongoDB: the change event as relaxed Extended JSON.
    auto,
    /// MongoDB: `fullDocument` alone (relaxed Extended JSON; `{"_id": ...}` from
    /// documentKey when there is none, as for deletes). Others: as `auto`.
    document,
};

pub const Options = struct {
    /// In logs, metrics and the ABI; null: "<kind>:<first channel/key/collection>".
    name: ?[]const u8 = null,
    to: []const Target = &.{},
    data: Data = .auto,
    reconnect: resilience.Backoff = .{ .base = .fromMilliseconds(100), .max = .fromSeconds(5) },
};

pub const InitError = error{ OutOfMemory, InvalidWatch };

pub const Status = enum { starting, connected, reconnecting, stopped, failed };

pub const HandleOptions = struct {
    /// Events handled at once. 1: one after the other, in order, on the
    /// watch's executor. More: spread over the executors (order lost).
    concurrency: u32 = 1,
    /// A bound per event; past it the handler is canceled.
    timeout: ?Duration = .fromSeconds(30),
    /// Also call the handler with `op = .gap` events.
    gaps: bool = false,
};

pub const ListenOptions = struct { max_events: u32 = 1024, max_bytes: usize = 4 * 1024 * 1024 };

/// One event, a context like a request: `app.db.one(T, ev, ...)` works.
pub const Event = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    locals: dusty.Locals = .{},
    /// "watch-<n>", for logs.
    id: []const u8,
    watch: *Watch,
    source: Kind,
    op: Op,
    /// The raw operation name ("insert", "createIndexes"; "message", "entry", "gap").
    op_name: []const u8,
    /// PostgreSQL/Redis channel, stream key, or MongoDB "db.collection" ("db" for database-wide events).
    channel: []const u8,
    pattern: ?[]const u8 = null,
    /// See `Data.auto`.
    data: []const u8,
    position: ?[]const u8 = null,
    /// PostgreSQL: the notifying backend's process ID.
    pg_pid: i32 = 0,
    /// A stream entry's fields, in order.
    fields: []const [2][]const u8 = &.{},
    /// MongoDB: the change event as BSON.
    change: ?bson.Document = null,

    /// `data` as JSON into `T` (the arena).
    pub fn json(self: *const Event, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena, self.data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// MongoDB: `fullDocument` into `T`; error.NotFound when absent.
    pub fn document(self: *const Event, comptime T: type) !T {
        const change = self.change orelse return error.NotFound;
        const v = change.get("fullDocument") orelse return error.NotFound;
        if (v != .document) return error.NotFound;
        return bson.decodeDocument(T, self.arena, v.document, .{});
    }

    /// Redis stream group with `ack = .manual`: XACK this entry (queued;
    /// never waits).
    pub fn ack(self: *const Event) error{ OutOfMemory, Unsupported }!void {
        const hook = self.watch.ack_hook orelse return error.Unsupported;
        try hook.call(hook.ctx, self.channel, self.position orelse return error.Unsupported);
    }

    /// A copy of the event in `arena`, everything it points to included.
    pub fn clone(self: *const Event, arena: std.mem.Allocator) error{OutOfMemory}!Event {
        var out = self.*;
        out.arena = arena;
        out.locals = .{};
        out.id = try arena.dupe(u8, self.id);
        out.op_name = try arena.dupe(u8, self.op_name);
        out.channel = try arena.dupe(u8, self.channel);
        if (self.pattern) |p| out.pattern = try arena.dupe(u8, p);
        out.data = try arena.dupe(u8, self.data);
        if (self.position) |p| out.position = try arena.dupe(u8, p);
        if (self.fields.len > 0) {
            const f = try arena.alloc([2][]const u8, self.fields.len);
            for (self.fields, f) |src, *dst| dst.* = .{ try arena.dupe(u8, src[0]), try arena.dupe(u8, src[1]) };
            out.fields = f;
        }
        if (self.change) |c| out.change = try c.dupe(arena);
        return out;
    }

    /// The bytes the event holds, for the listeners' bounds.
    pub fn cost(self: *const Event) usize {
        var n: usize = 128 + self.data.len + self.channel.len + self.op_name.len;
        if (self.position) |p| n += p.len;
        for (self.fields) |f| n += f[0].len + f[1].len + 32;
        if (self.change) |c| n += c.bytes.len;
        return n;
    }
};

/// What a source hands over before the watch builds the `Event`.
pub const Raw = struct {
    op: Op,
    op_name: []const u8,
    channel: []const u8,
    pattern: ?[]const u8 = null,
    data: []const u8 = "",
    position: ?[]const u8 = null,
    pg_pid: i32 = 0,
    fields: []const [2][]const u8 = &.{},
    change: ?bson.Document = null,
    /// MongoDB: for the `{db}`, `{collection}` and `{key}` placeholders.
    db: ?[]const u8 = null,
    collection: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

/// An output that is not a target or a handler: the Zig `Listener`, the
/// C ABI's listeners. Its calls must not wait.
pub const Sink = struct {
    ctx: *anyopaque,
    /// An event, valid only during the call: copy what must stay.
    deliver: *const fn (ctx: *anyopaque, ev: *const Event) void,
    /// Events were lost (a reconnect, a deleted entry).
    gap: *const fn (ctx: *anyopaque, detail: []const u8) void,
    /// The source connected or disconnected.
    status: *const fn (ctx: *anyopaque, connected: bool, detail: []const u8) void,
    /// The watch stopped: no more calls follow.
    ended: *const fn (ctx: *anyopaque, failed: bool, detail: []const u8) void,
    node: std.DoublyLinkedList.Node = .{},
};

pub const AckHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, key: []const u8, id: []const u8) error{ OutOfMemory, Unsupported }!void,
};

/// A handler for each event.
const HandlerSlot = struct {
    state: ?*anyopaque,
    run: *const fn (state: ?*anyopaque, ev: *Event) anyerror!void,
    opts: HandleOptions,
};

/// An event kept for a handler or a listener: its own arena.
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    ev: Event,
    node: std.DoublyLinkedList.Node = .{},

    fn create(gpa: std.mem.Allocator, src: *const Event) error{OutOfMemory}!*Owned {
        const o = try gpa.create(Owned);
        errdefer gpa.destroy(o);
        o.arena = .init(gpa);
        errdefer o.arena.deinit();
        o.ev = try src.clone(o.arena.allocator());
        return o;
    }

    fn destroy(o: *Owned, gpa: std.mem.Allocator) void {
        o.arena.deinit();
        gpa.destroy(o);
    }
};

/// What the outcome of one event for the reader says.
pub const Outcome = enum { ok, failed };

const TargetRt = struct {
    kind: union(enum) {
        sse: struct { topics: *sse.Topics, event: ?[]u8 },
        ws: struct { rooms: *websocket.Rooms, type: MessageType, gap_message: ?[]u8 },
    },
    tmpl: template.Template,
};

pub const Watch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []u8,
    source: Source,
    reconnect: resilience.Backoff,
    data_mode: Data,
    targets: []TargetRt = &.{},
    /// Over the sinks, the position, the failure and the inbox.
    mutex: std.Io.Mutex = .init,
    sinks: std.DoublyLinkedList = .{},
    handler: ?HandlerSlot = null,
    status_value: std.atomic.Value(u8) = .init(@intFromEnum(Status.starting)),
    stopping: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    /// Not started under this deployment (lambda).
    disabled: bool = false,
    group: std.Io.Group = .init,
    reader_task: ?placement.Task = null,
    /// The per-event arena of the reader that delivers inline.
    arena: std.heap.ArenaAllocator,
    event_seq: std.atomic.Value(u64) = .init(0),
    position_text: ?[]u8 = null,
    ack_hook: ?AckHook = null,
    /// The server's drain.
    drain_hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
    drain_hooks: ?*dusty.DrainHooks = null,
    failure: ?[]u8 = null,
    // Handler inbox (hub-driven sources with a handler).
    inbox: std.DoublyLinkedList = .{},
    inbox_len: usize = 0,
    inbox_gap: bool = false,
    inbox_signal: std.Io.Event = .unset,
    slots: Slots = .{},
    // Counters.
    n_events: std.atomic.Value(u64) = .init(0),
    n_gaps: std.atomic.Value(u64) = .init(0),
    n_reconnects: std.atomic.Value(u64) = .init(0),
    n_listener_dropped: std.atomic.Value(u64) = .init(0),
    n_template_skipped: std.atomic.Value(u64) = .init(0),
    metrics: ?Metrics = null,
    /// Tests: no real source; `_inject` feeds it.
    fake: bool = false,

    const inbox_max = 4096;

    const Metrics = struct {
        events: *observe_metrics.Counter,
        gaps: *observe_metrics.Counter,
        reconnects: *observe_metrics.Counter,
        connected: *observe_metrics.Gauge,
        listener_dropped: *observe_metrics.Counter,
        template_skipped: *observe_metrics.Counter,
    };

    /// Concurrent handler slots.
    const Slots = struct {
        mutex: std.Io.Mutex = .init,
        freed: std.Io.Condition = .init,
        in_use: u32 = 0,
    };

    /// Outside `App` (`app.watch` does this). `InvalidWatch`: an empty
    /// channel list, a bad template, a channel over 63 bytes, a pipeline that
    /// is not an Extended JSON array, a template with `{key}` on a source
    /// that is not MongoDB...; the reason is logged.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, source: Source, options: Options) InitError!*Watch {
        try validate(source, options);
        const self = try gpa.create(Watch);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .name = try gpa.dupe(u8, options.name orelse defaultName(source)),
            .source = source,
            .reconnect = options.reconnect,
            .data_mode = options.data,
            .arena = .init(gpa),
        };
        errdefer gpa.free(self.name);
        errdefer self.arena.deinit();
        const mongo = source == .mongodb;
        const targets = try gpa.alloc(TargetRt, options.to.len);
        var made: usize = 0;
        errdefer {
            for (targets[0..made]) |t| freeTarget(gpa, t);
            gpa.free(targets);
        }
        for (options.to) |t| {
            switch (t) {
                .sse => |s| {
                    const tmpl = template.Template.parse(gpa, s.topic, mongo) catch |err| return templateFailed(self.name, s.topic, err);
                    errdefer tmpl.deinit(gpa);
                    const ev: ?[]u8 = if (s.event) |e| try gpa.dupe(u8, e) else null;
                    targets[made] = .{ .kind = .{ .sse = .{ .topics = s.topics, .event = ev } }, .tmpl = tmpl };
                },
                .ws => |w| {
                    const tmpl = template.Template.parse(gpa, w.room, mongo) catch |err| return templateFailed(self.name, w.room, err);
                    errdefer tmpl.deinit(gpa);
                    const msg: ?[]u8 = if (w.gap_message) |m| try gpa.dupe(u8, m) else null;
                    targets[made] = .{ .kind = .{ .ws = .{ .rooms = w.rooms, .type = w.type, .gap_message = msg } }, .tmpl = tmpl };
                },
            }
            made += 1;
        }
        self.targets = targets;
        return self;
    }

    fn defaultName(source: Source) []const u8 {
        return switch (source) {
            .postgres => |p| p.channels[0],
            .redis => |r| if (r.channels.len > 0) r.channels[0] else r.patterns[0],
            .redis_stream => |r| r.keys[0],
            .mongodb => |m| m.collection orelse m.database orelse "cluster",
        };
    }

    fn templateFailed(name: []const u8, text: []const u8, err: template.ParseError) InitError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.err("watch \"{s}\": the template \"{s}\" is not valid: use {{channel}}, {{op}}, {{data.<field>}} and, for MongoDB, {{db}}, {{collection}} and {{key}}", .{ name, text });
        return error.InvalidWatch;
    }

    fn validate(source: Source, options: Options) InitError!void {
        const label = options.name orelse "(unnamed)";
        switch (source) {
            .postgres => |p| {
                if (p.channels.len == 0) {
                    log.err("watch \"{s}\": a PostgreSQL watch names at least one channel", .{label});
                    return error.InvalidWatch;
                }
                for (p.channels) |c| if (c.len == 0 or c.len > 63) {
                    log.err("watch \"{s}\": the channel \"{s}\" is not 1 to 63 bytes (PostgreSQL's limit for names)", .{ label, c });
                    return error.InvalidWatch;
                };
            },
            .redis => |r| if (r.channels.len + r.patterns.len == 0) {
                log.err("watch \"{s}\": a Redis watch names at least one channel or pattern", .{label});
                return error.InvalidWatch;
            },
            .redis_stream => |r| {
                if (r.keys.len == 0 or r.keys.len > 16) {
                    log.err("watch \"{s}\": a Redis stream watch reads 1 to 16 keys", .{label});
                    return error.InvalidWatch;
                }
                if (r.start == .after and r.start.after.len != r.keys.len) {
                    log.err("watch \"{s}\": start.after names one entry ID per key ({d} keys)", .{ label, r.keys.len });
                    return error.InvalidWatch;
                }
                if (r.count == 0) {
                    log.err("watch \"{s}\": count is 0", .{label});
                    return error.InvalidWatch;
                }
            },
            .mongodb => |m| {
                if (comptime features.mongodb) {
                    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                    defer arena.deinit();
                    _ = mongodb_mod.change_stream.parsePipeline(arena.allocator(), m.pipeline) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidPipeline => {
                            log.err("watch \"{s}\": the pipeline is not an Extended JSON array of stage documents: [{{\"$match\": {{...}}}}]", .{label});
                            return error.InvalidWatch;
                        },
                    };
                }
            },
        }
    }

    fn freeTarget(gpa: std.mem.Allocator, t: TargetRt) void {
        t.tmpl.deinit(gpa);
        switch (t.kind) {
            .sse => |s| if (s.event) |e| gpa.free(e),
            .ws => |w| if (w.gap_message) |m| gpa.free(m),
        }
    }

    pub fn deinit(self: *Watch) void {
        self.stop();
        self.group.cancel(self.io);
        const gpa = self.gpa;
        while (self.inbox.popFirst()) |n| {
            const o: *Owned = @alignCast(@fieldParentPtr("node", n));
            o.destroy(gpa);
        }
        for (self.targets) |t| freeTarget(gpa, t);
        gpa.free(self.targets);
        if (self.position_text) |p| gpa.free(p);
        if (self.failure) |f| gpa.free(f);
        self.arena.deinit();
        gpa.free(self.name);
        gpa.destroy(self);
    }

    /// Registers the drain with `hooks`: the watch stops reading when the
    /// server starts to drain (W8).
    pub fn _registerDrain(self: *Watch, hooks: *dusty.DrainHooks) void {
        self.drain_hooks = hooks;
        hooks.add(self.io, &self.drain_hook);
    }

    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const self: *Watch = @alignCast(@fieldParentPtr("drain_hook", hook));
        // A task: stopping takes the hub's lock.
        placement.concurrent(&self.group, self.io, .local, stopTask, .{self}) catch self.stopping.store(true, .release);
    }

    fn stopTask(self: *Watch) std.Io.Cancelable!void {
        self.stop();
    }

    // -- starting and stopping --------------------------------------------

    /// Starts reading and registers the watch's metrics with `registry`
    /// (`anole_watch_*{watch}`); the server calls it when serving starts,
    /// after the database clients it reads. A watch made `disabled` (the
    /// lambda deployment) reads nothing.
    pub fn start(self: *Watch, registry: ?*observe_metrics.Registry, tracer: ?*anyopaque, health: ?*anyopaque) !void {
        _ = tracer;
        _ = health;
        if (registry) |r| try self.observe(r);
        if (self.started or self.disabled or self.fake) return;
        self.started = true;
        switch (self.source) {
            .postgres => if (comptime features.postgres) try @import("pg.zig").register(self),
            .redis => if (comptime features.redis) try @import("redis.zig").register(self),
            .redis_stream => if (comptime features.redis) try @import("redis.zig").startStream(self),
            .mongodb => if (comptime features.mongodb) try @import("mongo.zig").startStream(self),
        }
        if (self.handler != null and self.isHubDriven()) {
            placement.concurrent(&self.group, self.io, .local, inboxWorker, .{self}) catch return error.ServiceUnavailable;
        }
    }

    fn observe(self: *Watch, r: *observe_metrics.Registry) !void {
        if (self.metrics != null) return;
        const label: []const []const u8 = &.{self.name};
        self.metrics = .{
            .events = (try r.counter("anole_watch_events_total", "Changes read from the source.", &.{"watch"})).with(label),
            .gaps = (try r.counter("anole_watch_gaps_total", "Times the source may have lost events.", &.{"watch"})).with(label),
            .reconnects = (try r.counter("anole_watch_reconnects_total", "Reconnects of the source's connection.", &.{"watch"})).with(label),
            .connected = (try r.gauge("anole_watch_connected", "1 while the source's connection is up.", &.{"watch"})).with(label),
            .listener_dropped = (try r.counter("anole_watch_listener_dropped_total", "Events dropped for a listener that did not keep up.", &.{"watch"})).with(label),
            .template_skipped = (try r.counter("anole_watch_template_skipped_total", "Events a target's template could not be filled for.", &.{"watch"})).with(label),
        };
        self.syncMetrics();
    }

    fn syncMetrics(self: *Watch) void {
        const m = self.metrics orelse return;
        m.events.value.store(self.n_events.load(.monotonic), .monotonic);
        m.gaps.value.store(self.n_gaps.load(.monotonic), .monotonic);
        m.reconnects.value.store(self.n_reconnects.load(.monotonic), .monotonic);
        m.listener_dropped.value.store(self.n_listener_dropped.load(.monotonic), .monotonic);
        m.template_skipped.value.store(self.n_template_skipped.load(.monotonic), .monotonic);
        m.connected.set(if (self.status() == .connected) 1 else 0);
    }

    pub fn isHubDriven(self: *const Watch) bool {
        return self.source == .postgres or self.source == .redis;
    }

    /// Stops reading and ends handlers' work and listeners (W8). Does not wait.
    pub fn stop(self: *Watch) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        if (self.started and !self.fake) switch (self.source) {
            .postgres => if (comptime features.postgres) @import("pg.zig").unregister(self),
            .redis => if (comptime features.redis) @import("redis.zig").unregister(self),
            .redis_stream, .mongodb => {},
        };
        self.setStatus(.stopped);
        if (self.reader_task) |t| placement.cancelTask(t);
        self.inbox_signal.set(self.io);
        self.endSinks(false, "");
    }

    pub fn status(self: *const Watch) Status {
        return @enumFromInt(self.status_value.load(.acquire));
    }

    pub fn setStatus(self: *Watch, s: Status) void {
        const old: Status = @enumFromInt(self.status_value.swap(@intFromEnum(s), .acq_rel));
        if (old == s) return;
        if (self.metrics != null) self.syncMetrics();
        switch (s) {
            .connected => self.statusSinks(true, ""),
            .reconnecting => {
                _ = self.n_reconnects.fetchAdd(1, .monotonic);
                self.statusSinks(false, "");
            },
            else => {},
        }
    }

    pub fn isStopped(self: *const Watch) bool {
        return self.stopping.load(.acquire);
    }

    /// The source cannot go on: stopped with `status() == .failed`, one
    /// error line saying what to change.
    pub fn fail(self: *Watch, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        log.err("watch \"{s}\": {s}", .{ self.name, text });
        self.mutex.lockUncancelable(self.io);
        if (self.failure) |old| self.gpa.free(old);
        self.failure = text;
        self.mutex.unlock(self.io);
        self.stopping.store(true, .release);
        self.setStatus(.failed);
        self.endSinks(true, text);
    }

    // -- outputs ----------------------------------------------------------

    /// Runs `handler` for each event (`fn (*watch.Event) !void`, or with the
    /// server's state first). Before `start`.
    pub fn handle(self: *Watch, server: anytype, opts: HandleOptions, comptime handler: anytype) !void {
        const Info = @typeInfo(@TypeOf(handler)).@"fn";
        const with_state = Info.params.len == 2;
        const state: ?*anyopaque = if (with_state) @ptrCast(server.server.ctx) else null;
        const Tramp = struct {
            fn run(ctx: ?*anyopaque, ev: *Event) anyerror!void {
                if (with_state) {
                    const P = Info.params[0].type.?;
                    return handler(@as(P, @ptrCast(@alignCast(ctx.?))), ev);
                }
                return handler(ev);
            }
        };
        self.setHandler(state, opts, Tramp.run);
    }

    /// `handle` for a trampoline already made (the C ABI, tests).
    pub fn setHandler(self: *Watch, state: ?*anyopaque, opts: HandleOptions, run: *const fn (?*anyopaque, *Event) anyerror!void) void {
        var o = opts;
        o.concurrency = @max(1, o.concurrency);
        self.handler = .{ .state = state, .run = run, .opts = o };
    }

    pub fn addSink(self: *Watch, sink: *Sink) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sinks.append(&sink.node);
    }

    pub fn removeSink(self: *Watch, sink: *Sink) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.sinks.remove(&sink.node);
    }

    fn statusSinks(self: *Watch, connected: bool, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.sinks.first;
        while (it) |n| : (it = n.next) {
            const s: *Sink = @alignCast(@fieldParentPtr("node", n));
            s.status(s.ctx, connected, detail);
        }
    }

    fn endSinks(self: *Watch, failed: bool, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.sinks.first;
        while (it) |n| : (it = n.next) {
            const s: *Sink = @alignCast(@fieldParentPtr("node", n));
            s.ended(s.ctx, failed, detail);
        }
    }

    /// Events from now on, for a handler or a background task; `c` is a
    /// request (the listener ends at its drain) or an `anole.db.Ctx`.
    pub fn listen(self: *Watch, c: anytype, opts: ListenOptions) error{ OutOfMemory, Stopped }!*Listener {
        if (self.isStopped()) return error.Stopped;
        const l = try self.gpa.create(Listener);
        l.* = .{ .watch = self, .max_events = opts.max_events, .max_bytes = opts.max_bytes, .sink = undefined };
        l.sink = .{ .ctx = l, .deliver = Listener.sinkDeliver, .gap = Listener.sinkGap, .status = Listener.sinkStatus, .ended = Listener.sinkEnded };
        const C = @typeInfo(@TypeOf(c)).pointer.child;
        if (comptime @hasField(C, "_drain_hooks")) if (c._drain_hooks) |hooks| {
            l.hooks = hooks;
            hooks.add(self.io, &l.hook);
        };
        self.addSink(&l.sink);
        return l;
    }

    /// The last position handled (stream entry IDs joined by ',', or the resume
    /// token as canonical Extended JSON), copied into `arena`; null for PostgreSQL
    /// and Redis pub/sub, or before the first event.
    pub fn position(self: *Watch, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const p = self.position_text orelse return null;
        return try arena.dupe(u8, p);
    }

    pub fn setPosition(self: *Watch, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.position_text) |old| self.gpa.free(old);
        self.position_text = copy;
    }

    // -- delivering -------------------------------------------------------

    fn buildEvent(self: *Watch, arena: std.mem.Allocator, raw: Raw) Event {
        const seq = self.event_seq.fetchAdd(1, .monotonic);
        const id = std.fmt.allocPrint(arena, "watch-{d}", .{seq}) catch "watch";
        return .{
            .io = self.io,
            .arena = arena,
            .id = id,
            .watch = self,
            .source = std.meta.activeTag(self.source),
            .op = raw.op,
            .op_name = raw.op_name,
            .channel = raw.channel,
            .pattern = raw.pattern,
            .data = raw.data,
            .position = raw.position,
            .pg_pid = raw.pg_pid,
            .fields = raw.fields,
            .change = raw.change,
        };
    }

    /// An event from a source that reads on its own task: the targets and
    /// sinks (never waiting), then the handler on this task. `.failed` when
    /// the handler failed (a stream group leaves the entry pending).
    pub fn deliver(self: *Watch, raw: Raw) Outcome {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var ev = self.buildEvent(a, raw);
        _ = self.n_events.fetchAdd(1, .monotonic);
        self.outputs(&ev, raw);
        if (self.metrics != null) self.syncMetrics();
        const h = self.handler orelse return .ok;
        return self.runHandler(h, &ev);
    }

    /// An event from a shared connection (PostgreSQL, Redis pub/sub): the
    /// targets and sinks inline, and the handler's copy to its inbox so a
    /// slow handler never holds the shared reader up.
    pub fn onHubEvent(self: *Watch, raw: Raw) void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        var ev = self.buildEvent(a, raw);
        _ = self.n_events.fetchAdd(1, .monotonic);
        self.outputs(&ev, raw);
        if (self.metrics != null) self.syncMetrics();
        if (self.handler != null) self.enqueue(&ev);
    }

    /// Targets and sinks. Never waits.
    fn outputs(self: *Watch, ev: *const Event, raw: Raw) void {
        const a = ev.arena;
        for (self.targets) |*t| {
            const rendered = t.tmpl.render(a, .{
                .channel = ev.channel,
                .op = ev.op_name,
                .db = raw.db,
                .collection = raw.collection,
                .key = raw.key,
                .data = ev.data,
            }) catch null;
            const text = rendered orelse {
                _ = self.n_template_skipped.fetchAdd(1, .monotonic);
                continue;
            };
            switch (t.kind) {
                .sse => |s| _ = s.topics.publish(text, .{ .data = ev.data, .event = s.event }) catch {},
                .ws => |w| _ = w.rooms.broadcast(text, w.type, ev.data, null),
            }
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.sinks.first;
        while (it) |n| : (it = n.next) {
            const s: *Sink = @alignCast(@fieldParentPtr("node", n));
            s.deliver(s.ctx, ev);
        }
    }

    /// The source may have lost events: topics get their `gap` event,
    /// rooms their `gap_message`, sinks a gap, the handler a `.gap` event
    /// when it asks.
    pub fn gapped(self: *Watch, detail: []const u8) void {
        _ = self.n_gaps.fetchAdd(1, .monotonic);
        log.info("watch \"{s}\": events may have been lost ({s})", .{ self.name, detail });
        for (self.targets) |*t| switch (t.kind) {
            .sse => |s| if (t.tmpl.fixed) s.topics.gap(t.tmpl.segments[0].literal) else s.topics.gapPrefix(t.tmpl.prefix),
            .ws => |w| if (w.gap_message) |m| if (t.tmpl.fixed) {
                _ = w.rooms.broadcast(t.tmpl.segments[0].literal, w.type, m, null);
            },
        };
        self.mutex.lockUncancelable(self.io);
        var it = self.sinks.first;
        while (it) |n| : (it = n.next) {
            const s: *Sink = @alignCast(@fieldParentPtr("node", n));
            s.gap(s.ctx, detail);
        }
        self.mutex.unlock(self.io);
        if (self.metrics != null) self.syncMetrics();
        if (self.handler) |h| if (h.opts.gaps) {
            if (self.isHubDriven()) {
                self.mutex.lockUncancelable(self.io);
                self.inbox_gap = true;
                self.mutex.unlock(self.io);
                self.inbox_signal.set(self.io);
            } else {
                _ = self.arena.reset(.retain_capacity);
                var ev = self.buildEvent(self.arena.allocator(), .{ .op = .gap, .op_name = "gap", .channel = "", .data = detail });
                _ = self.runHandler(h, &ev);
            }
        };
    }

    // -- the handler ------------------------------------------------------

    fn runHandler(self: *Watch, h: HandlerSlot, ev: *Event) Outcome {
        if (h.opts.concurrency <= 1) return self.callHandler(h, ev);
        // Spread over the executors: a slot, a copy of the event, a task.
        self.slots.mutex.lockUncancelable(self.io);
        while (self.slots.in_use >= h.opts.concurrency and !self.isStopped()) self.slots.freed.waitUncancelable(self.io, &self.slots.mutex);
        self.slots.in_use += 1;
        self.slots.mutex.unlock(self.io);
        const owned = Owned.create(self.gpa, ev) catch {
            self.releaseSlot();
            return .failed;
        };
        const n = self.event_seq.load(.monotonic);
        placement.concurrent(&self.group, self.io, .{ .executor = n }, handlerTask, .{ self, h, owned }) catch {
            owned.destroy(self.gpa);
            self.releaseSlot();
            return .failed;
        };
        return .ok;
    }

    fn releaseSlot(self: *Watch) void {
        self.slots.mutex.lockUncancelable(self.io);
        self.slots.in_use -= 1;
        self.slots.freed.signal(self.io);
        self.slots.mutex.unlock(self.io);
    }

    fn handlerTask(self: *Watch, h: HandlerSlot, owned: *Owned) std.Io.Cancelable!void {
        defer {
            owned.destroy(self.gpa);
            self.releaseSlot();
        }
        _ = self.callHandler(h, &owned.ev);
    }

    fn callHandler(self: *Watch, h: HandlerSlot, ev: *Event) Outcome {
        const Run = struct {
            fn call(slot: HandlerSlot, e: *Event) anyerror!void {
                return slot.run(slot.state, e);
            }
        };
        const result: anyerror!void = if (h.opts.timeout) |d| blk: {
            const deadline: dusty.Deadline = .init(self.io, .{ .duration = .{ .raw = d, .clock = .awake } });
            break :blk deadline.run(Run.call, .{ h, ev });
        } else Run.call(h, ev);
        result catch |err| {
            if (err == error.Canceled) return .failed;
            log.warn("watch \"{s}\": the handler failed for {s}: {t}", .{ self.name, ev.id, err });
            return .failed;
        };
        return .ok;
    }

    fn enqueue(self: *Watch, ev: *const Event) void {
        const owned = Owned.create(self.gpa, ev) catch return;
        self.mutex.lockUncancelable(self.io);
        if (self.inbox_len >= inbox_max) {
            // The oldest goes; the handler learns of it as a gap.
            if (self.inbox.popFirst()) |old| {
                const o: *Owned = @alignCast(@fieldParentPtr("node", old));
                o.destroy(self.gpa);
                self.inbox_len -= 1;
                self.inbox_gap = true;
                _ = self.n_listener_dropped.fetchAdd(1, .monotonic);
            }
        }
        self.inbox.append(&owned.node);
        self.inbox_len += 1;
        self.mutex.unlock(self.io);
        self.inbox_signal.set(self.io);
    }

    /// The handler's task for a shared-connection source.
    fn inboxWorker(self: *Watch) std.Io.Cancelable!void {
        const h = self.handler.?;
        while (true) {
            try self.inbox_signal.wait(self.io);
            self.inbox_signal.reset();
            while (true) {
                self.mutex.lockUncancelable(self.io);
                const gap = self.inbox_gap;
                self.inbox_gap = false;
                const node = self.inbox.popFirst();
                if (node != null) self.inbox_len -= 1;
                self.mutex.unlock(self.io);
                if (gap and h.opts.gaps) {
                    var ev = self.buildEvent(self.arena.allocator(), .{ .op = .gap, .op_name = "gap", .channel = "", .data = "events were lost" });
                    _ = self.runHandler(h, &ev);
                }
                const n = node orelse break;
                const o: *Owned = @alignCast(@fieldParentPtr("node", n));
                _ = self.runHandler(h, &o.ev);
                o.destroy(self.gpa);
            }
            if (self.isStopped()) return;
        }
    }

    // -- test source ------------------------------------------------------

    /// Tests: a watch with no real source, fed by `_inject`.
    pub fn _fake(self: *Watch) void {
        self.fake = true;
        self.started = true;
        self.setStatus(.connected);
    }

    /// Tests: feeds one event as a shared-connection source would.
    pub fn _inject(self: *Watch, raw: Raw) void {
        self.onHubEvent(raw);
    }

    /// Tests: starts the handler's inbox worker of a fake watch.
    pub fn _startWorker(self: *Watch) !void {
        try placement.concurrent(&self.group, self.io, .local, inboxWorker, .{self});
    }
};

/// Events read from a watch, copied (`Watch.listen`). Bounded and lossy: past
/// `max_events` or `max_bytes` the oldest are dropped and one `.gap` event
/// takes their place.
pub const Listener = struct {
    watch: *Watch,
    max_events: u32,
    max_bytes: usize,
    sink: Sink,
    mutex: std.Io.Mutex = .init,
    queue: std.DoublyLinkedList = .{},
    len: usize = 0,
    bytes: usize = 0,
    dropped: u64 = 0,
    closed: bool = false,
    signal: std.Io.Event = .unset,
    /// The request's drain.
    hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
    hooks: ?*dusty.DrainHooks = null,

    fn sinkDeliver(ctx: *anyopaque, ev: *const Event) void {
        const self: *Listener = @ptrCast(@alignCast(ctx));
        const io = self.watch.io;
        const o = Owned.create(self.watch.gpa, ev) catch return;
        self.mutex.lockUncancelable(io);
        if (self.closed) {
            self.mutex.unlock(io);
            o.destroy(self.watch.gpa);
            return;
        }
        self.queue.append(&o.node);
        self.len += 1;
        self.bytes += o.ev.cost();
        while (self.len > self.max_events or self.bytes > self.max_bytes) {
            const first = self.queue.first orelse break;
            // The newest is never the one dropped.
            if (first == &o.node) break;
            self.queue.remove(first);
            const old: *Owned = @alignCast(@fieldParentPtr("node", first));
            self.len -= 1;
            self.bytes -|= old.ev.cost();
            self.dropped += 1;
            _ = self.watch.n_listener_dropped.fetchAdd(1, .monotonic);
            old.destroy(self.watch.gpa);
        }
        self.mutex.unlock(io);
        self.signal.set(io);
    }

    fn sinkGap(ctx: *anyopaque, detail: []const u8) void {
        _ = detail;
        const self: *Listener = @ptrCast(@alignCast(ctx));
        const io = self.watch.io;
        self.mutex.lockUncancelable(io);
        self.dropped += 1;
        self.mutex.unlock(io);
        self.signal.set(io);
    }

    fn sinkStatus(_: *anyopaque, _: bool, _: []const u8) void {}

    fn sinkEnded(ctx: *anyopaque, _: bool, _: []const u8) void {
        const self: *Listener = @ptrCast(@alignCast(ctx));
        const io = self.watch.io;
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.signal.set(io);
    }

    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const self: *Listener = @alignCast(@fieldParentPtr("hook", hook));
        sinkEnded(self, false, "");
    }

    /// The next event (copied into `c`'s arena), a `.gap` event after a
    /// loss, or null once the watch stopped or the request's drain started.
    pub fn next(self: *Listener, c: anytype) error{ Canceled, OutOfMemory }!?*const Event {
        const w = self.watch;
        while (true) {
            self.mutex.lockUncancelable(w.io);
            if (self.dropped > 0) {
                self.dropped = 0;
                self.mutex.unlock(w.io);
                return try gapEvent(w, c);
            }
            if (self.queue.popFirst()) |n| {
                const o: *Owned = @alignCast(@fieldParentPtr("node", n));
                self.len -= 1;
                self.bytes -|= o.ev.cost();
                self.mutex.unlock(w.io);
                defer o.destroy(w.gpa);
                const out = try c.arena.create(Event);
                out.* = try o.ev.clone(c.arena);
                out.io = c.io;
                return out;
            }
            const closed = self.closed;
            self.mutex.unlock(w.io);
            if (closed) return null;
            try self.signal.wait(w.io);
            self.signal.reset();
        }
    }

    fn gapEvent(w: *Watch, c: anytype) error{OutOfMemory}!*const Event {
        const out = try c.arena.create(Event);
        out.* = .{
            .io = c.io,
            .arena = c.arena,
            .id = "watch-gap",
            .watch = w,
            .source = std.meta.activeTag(w.source),
            .op = .gap,
            .op_name = "gap",
            .channel = "",
            .data = "events were lost",
        };
        return out;
    }

    /// Stops listening; frees the listener. Not while a task waits in `next`.
    pub fn close(self: *Listener) void {
        const w = self.watch;
        w.removeSink(&self.sink);
        if (self.hooks) |h| h.remove(w.io, &self.hook);
        while (self.queue.popFirst()) |n| {
            const o: *Owned = @alignCast(@fieldParentPtr("node", n));
            o.destroy(w.gpa);
        }
        w.gpa.destroy(self);
    }
};

test {
    _ = template;
    _ = @import("watch_test.zig");
    _ = @import("live_test.zig");
    if (features.redis) _ = @import("redis.zig");
}

test "watch: the feeds and the change stream compile" {
    // Never run: the bodies are only analyzed when something calls them.
    var never = false;
    _ = &never;
    if (never) {
        const w: *Watch = undefined;
        try w.start(null, null, null);
        if (features.postgres) {
            try @import("pg.zig").register(w);
            @import("pg.zig").unregister(w);
        }
        if (features.redis) {
            try @import("redis.zig").register(w);
            @import("redis.zig").unregister(w);
            try @import("redis.zig").startStream(w);
        }
        if (features.mongodb) {
            try @import("mongo.zig").startStream(w);
            const client: *mongodb_mod.Client = undefined;
            var ctx: @import("../db/root.zig").Ctx = undefined;
            var stream = try client.watch(bson.Document, &ctx, .{}, .{});
            _ = try stream.next();
            _ = try stream.tryNext();
            _ = try stream.resumeToken(ctx.arena);
            stream.deinit();
            var db_stream = try client.db("x").watch(mongodb_mod.ChangeEvent, &ctx, .{}, .{});
            db_stream.deinit();
            var c_stream = try client.collection("x").watch(bson.Document, &ctx, .{.{ .@"$match" = .{ .operationType = "insert" } }}, .{});
            c_stream.deinit();
        }
    }
}
