//! `anole_webhooks_*`: webhooks out, delivered as jobs, and the
//! `webhook_verify` middleware's configuration (p3/webhooks, design-jobs.md
//! phase W). Events 109-110.
//!
//! `open` builds `app.webhooks(...)` from the configuration's "webhooks"
//! on the jobs client that p3/jobs opened. A publish copies the event and
//! becomes a command for one of the consumer's executors, whose task runs
//! `Client.publishJson` and queues `ANOLE_EV_WEBHOOK_PUBLISHED`. With a
//! transaction it is queued on the transaction (`TxWhat.webhook_publish`)
//! and runs in order on its connection: the deliveries are enqueued in the
//! same transaction. That answer comes as `ANOLE_EV_DB_RESULT` on the
//! transaction handle (`rows_affected` = deliveries), the one record kind a
//! transaction's calls answer with. Status events (`delivery_dead`,
//! `endpoint_disabled`) go to the consumer given to `anole_webhooks_watch`.
const std = @import("std");
const anole = @import("../root.zig");
const dusty = @import("dusty");
const engine = @import("engine.zig");
const abi = @import("abi.zig");
const config_mod = @import("config.zig");
const db = @import("db.zig");
const env = @import("../env.zig");

const features = anole.features;
const placement = dusty.placement;
const gpa = engine.gpa;
const Engine = engine.Engine;
const Exec = engine.Exec;
const Consumer = engine.Consumer;
const Command = engine.Command;
const AnswerError = engine.AnswerError;

const log = std.log.scoped(.anole);
const ms = std.Io.Duration.fromMilliseconds;

const Wh = if (features.webhooks) anole.webhooks else struct {
    pub const Client = void;
    pub const StatusEvent = void;
};

pub const CallError = error{ Invalid, State, OutOfMemory, Unsupported, Gone };

/// Engine-wide state (`Engine.webhooks_state`).
pub const State = struct {
    client: if (features.webhooks) ?*anole.webhooks.Client else void = if (features.webhooks) null else {},
    /// `anole_webhooks_watch`: guarded by `lock`.
    lock: std.atomic.Mutex = .unlocked,
    watcher: ?*Consumer = null,
    watcher_ud: u64 = 0,
    draining: std.atomic.Value(bool) = .init(false),

    pub fn init(s: *State, first_gen: u32) void {
        _ = first_gen;
        s.* = .{};
    }

    /// No handles of its own: nothing to bound.
    pub fn maxGen(s: *State) u32 {
        _ = s;
        return 0;
    }

    pub fn deinit(s: *State) void {
        s.client = if (features.webhooks) null else {};
    }
};

/// Per executor (`Exec.webhooks`): the publish tasks it runs are canceled at the stop.
pub const ExecState = struct {
    work: std.Io.Group = .init,

    pub fn cancel(st: *ExecState, io: std.Io) void {
        st.work.cancel(io);
    }

    pub fn maxGen(st: *const ExecState) u32 {
        _ = st;
        return 0;
    }

    pub fn deinit(st: *ExecState) void {
        _ = st;
    }
};

/// The jobs client p3/jobs opened (null until that area is merged).
fn jobsClient(e: *Engine) ?*anole.jobs.Client {
    if (comptime !features.jobs) return null;
    if (comptime !@hasField(@TypeOf(e.jobs_state), "client")) return null;
    return e.jobs_state.client;
}

/// The server's main thread, before the listeners open (after `db.open`,
/// `nats.open` and `kafka.open`).
pub fn open(e: *Engine, app: *anole.App) !void {
    if (comptime !features.webhooks) return;
    const w = e.config.webhooks orelse return;
    const jc = jobsClient(e) orelse {
        log.err("webhooks: the \"webhooks\" configuration needs \"jobs\"", .{});
        return error.Config;
    };
    var opts: anole.webhooks.Options = .{
        .jobs = jc,
        .queue = w.queue,
        .timeout = ms(w.timeout_ms),
        .attempts = w.attempts,
        .backoff = .{
            .base = ms(w.backoff.base_ms),
            .max = ms(w.backoff.max_ms),
            .multiplier = w.backoff.multiplier,
            .jitter = switch (w.backoff.jitter) {
                .full => .full,
                .equal => .equal,
                .none => .none,
            },
        },
        .breaker = if (w.breaker) |b| .{
            .consecutive_failures = b.consecutive_failures,
            .failure_ratio = b.failure_ratio,
            .min_calls = b.min_calls,
            .window = ms(b.window_ms),
            .open_for = ms(b.open_ms),
            .max_open_for = ms(b.max_open_ms),
            .half_open_calls = b.half_open_calls,
        } else null,
        .allow_private_addresses = w.allow_private_addresses,
        .require_https = w.require_https,
        .user_agent = w.user_agent,
        .max_payload = w.max_payload,
        .response_kept = w.response_kept,
        .keep_messages = ms(w.keep_messages_ms),
        .keep_attempts = ms(w.keep_attempts_ms),
        .disable_after = ms(w.disable_after_ms),
        .max_endpoints_per_owner = w.max_endpoints_per_owner,
        .on_event = .{ .context = e, .call = onEvent },
    };
    if (w.secrets_key_env.len > 0) opts.secrets_key = env.get(w.secrets_key_env);
    e.webhooks_state.client = try app.webhooks(opts);
}

/// The drain started (`anole_server_drain`, once).
pub fn draining(e: *Engine) void {
    e.webhooks_state.draining.store(true, .release);
}

/// The server stops: nothing new starts from here.
pub fn close(e: *Engine) void {
    e.webhooks_state.draining.store(true, .release);
}

/// `anole_server_destroy`: frees what a stopped server still holds.
pub fn destroy(e: *Engine) void {
    e.webhooks_state.client = if (features.webhooks) null else {};
}

// ---------------------------------------------------------------------------
// Records

const Writer = struct {
    rec: []u8,
    at: usize,

    fn put(w: *Writer, bytes: []const u8) abi.Span {
        if (bytes.len == 0) return .{};
        @memcpy(w.rec[w.at..][0..bytes.len], bytes);
        defer w.at += bytes.len;
        return .{ .off = @intCast(w.at), .len = @intCast(bytes.len) };
    }
};

const PublishedData = struct {
    user_data: u64,
    status: i32 = abi.OK,
    http_status: u16 = 200,
    error_class: abi.DbErrorClass = .none,
    duplicate: bool = false,
    deliveries: u32 = 0,
    message_id: []const u8 = "",
    message: []const u8 = "",
};

fn publishedRecord(d: PublishedData) ![]align(8) u8 {
    const Ev = abi.WebhookPublishedEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + d.message_id.len + d.message.len, .webhook_published, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = d.user_data;
    ev.status = d.status;
    ev.http_status = d.http_status;
    ev.error_class = @backingInt(d.error_class);
    ev.duplicate = @intFromBool(d.duplicate);
    ev.deliveries = d.deliveries;
    ev.message_id = w.put(d.message_id);
    ev.@"error" = w.put(d.message);
    return rec;
}

fn statusRecord(user_data: u64, what: u32, last_status: u16, owner: []const u8, endpoint: []const u8, message: []const u8, err_text: []const u8) ![]align(8) u8 {
    const Ev = abi.WebhookStatusEvent;
    const rec = try engine.newRecord(@sizeOf(Ev) + owner.len + endpoint.len + message.len + err_text.len, .webhook_status, 0);
    const ev: *Ev = @ptrCast(rec.ptr);
    var w: Writer = .{ .rec = rec, .at = @sizeOf(Ev) };
    ev.user_data = user_data;
    ev.what = what;
    ev.last_status = last_status;
    ev.owner = w.put(owner);
    ev.endpoint = w.put(endpoint);
    ev.message = w.put(message);
    ev.@"error" = w.put(err_text);
    return rec;
}

// ---------------------------------------------------------------------------
// Status events

/// `anole_webhooks_watch`: from now on the status events go to `c`.
pub fn watch(e: *Engine, c: *Consumer, user_data: u64) CallError!void {
    if (comptime !features.webhooks) return error.Unsupported;
    if (e.webhooks_state.client == null) return error.Unsupported;
    if (c.engine != e) return error.Invalid;
    const st = &e.webhooks_state;
    while (!st.lock.tryLock()) std.atomic.spinLoopHint();
    defer st.lock.unlock();
    st.watcher = c;
    st.watcher_ud = user_data;
}

/// `Options.on_event`: any thread.
fn onEvent(context: ?*anyopaque, ev: *const Wh.StatusEvent) void {
    if (comptime !features.webhooks) return;
    const e: *Engine = @ptrCast(@alignCast(context.?));
    const st = &e.webhooks_state;
    while (!st.lock.tryLock()) std.atomic.spinLoopHint();
    const c = st.watcher;
    const ud = st.watcher_ud;
    st.lock.unlock();
    const target = c orelse return;
    if (target.execs.items.len == 0) return;
    const what: u32 = switch (ev.what) {
        .delivery_dead => abi.WEBHOOK_DELIVERY_DEAD,
        .endpoint_disabled => abi.WEBHOOK_ENDPOINT_DISABLED,
    };
    const rec = statusRecord(ud, what, ev.last_status, ev.owner, ev.endpoint, ev.message, ev.@"error") catch return;
    target.execs.items[0].postRecord(rec, false);
}

// ---------------------------------------------------------------------------
// Publishing

/// A publish waiting for an executor: one allocation holding the command and
/// the copied pieces.
const Pub = struct {
    cmd: Command = .{ .run = run },
    e: *Engine,
    user_data: u64,
    owner: []const u8,
    type: []const u8,
    data_json: []const u8,
    id: ?[]const u8,
    endpoint: ?[]const u8,
    timestamp_ms: i64,
    arena: std.heap.ArenaAllocator,

    fn free(q: *Pub) void {
        var arena = q.arena;
        arena.deinit();
    }

    fn run(cmd: *Command, x: *Exec) void {
        const q: *Pub = @fieldParentPtr("cmd", cmd);
        if (x.engine.phase.load(.acquire) == .stopped) return q.free();
        placement.concurrent(&x.webhooks.work, x.engine.io, .local, task, .{ x, q }) catch q.free();
    }
};

fn task(x: *Exec, q: *Pub) std.Io.Cancelable!void {
    defer q.free();
    if (comptime !features.webhooks) return;
    const client = q.e.webhooks_state.client orelse return;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: anole.db.Ctx = .{ .io = x.engine.io, .arena = arena.allocator() };
    var data: PublishedData = .{ .user_data = q.user_data };
    const head: anole.webhooks.EventHead = .{
        .owner = q.owner,
        .type = q.type,
        .id = q.id,
        .timestamp = if (q.timestamp_ms != 0) anole.db.Time.fromMillis(q.timestamp_ms) else null,
        .endpoint = q.endpoint,
    };
    if (client.publishJson(&ctx, head, q.data_json)) |p| {
        data.message_id = p.message_id;
        data.deliveries = p.deliveries;
        data.duplicate = p.duplicate;
    } else |err| {
        if (err == error.Canceled) return error.Canceled;
        switch (err) {
            error.InvalidJob => {
                data.status = abi.E_INVALID;
                data.http_status = 400;
                data.message = "the event or its endpoint is invalid (type, owner, id, data JSON, size or endpoint)";
            },
            error.NotFound => {
                data.status = abi.E_DB;
                data.http_status = 404;
                data.message = "not found";
            },
            else => {
                data.status = abi.E_DB;
                data.http_status = switch (err) {
                    error.Conflict => 409,
                    error.ServiceUnavailable => 503,
                    error.GatewayTimeout => 504,
                    else => 500,
                };
                if (err == error.GatewayTimeout) data.status = abi.E_TIMEOUT;
                data.error_class = switch (err) {
                    error.ServiceUnavailable => .unavailable,
                    error.GatewayTimeout => .timeout,
                    else => .other,
                };
                data.message = if (anole.db.lastError(&ctx)) |d| d.message else @errorName(err);
            },
        }
    }
    const rec = publishedRecord(data) catch return;
    x.postRecord(rec, true);
}

/// `anole_webhooks_publish`.
pub fn publish(e: *Engine, c: *Consumer, m: abi.WebhookOut, user_data: u64) CallError!void {
    if (comptime !features.webhooks) return error.Unsupported;
    if (e.webhooks_state.client == null) return error.Unsupported;
    if (c.engine != e) return error.Invalid;
    if (e.webhooks_state.draining.load(.acquire) or e.phase.load(.acquire) == .stopped) return error.State;
    if (m.type.len == 0 or m.data_json.len == 0) return error.Invalid;
    if (m.req != 0) return error.Invalid;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const owner = try a.dupe(u8, m.owner.slice());
    const ty = try a.dupe(u8, m.type.slice());
    const data_json = try a.dupe(u8, m.data_json.slice());
    const id: ?[]const u8 = if (m.id.len == 0) null else try a.dupe(u8, m.id.slice());
    const endpoint: ?[]const u8 = if (m.endpoint.len == 0) null else try a.dupe(u8, m.endpoint.slice());

    if (m.tx != 0) {
        // On the transaction: queued in order with its other calls.
        const T = struct { owner: []const u8, type: []const u8, data: std.json.Value, id: ?[]const u8, endpoint: ?[]const u8, timestamp_ms: i64 };
        const data_value = std.json.parseFromSliceLeaky(std.json.Value, a, data_json, .{}) catch return error.Invalid;
        const text = std.json.Stringify.valueAlloc(a, T{
            .owner = owner,
            .type = ty,
            .data = data_value,
            .id = id,
            .endpoint = endpoint,
            .timestamp_ms = m.timestamp_ms,
        }, .{}) catch return error.OutOfMemory;
        db.txSubmit(e, m.tx, .webhook_publish, text, &.{}, .{ .size = @sizeOf(abi.DbOptions) }, user_data) catch |err| return switch (err) {
            error.Invalid => error.Invalid,
            error.State => error.State,
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => error.Unsupported,
            error.Gone => error.Gone,
        };
        arena.deinit();
        return;
    }

    if (c.execs.items.len == 0) return error.State;
    const i = c.next_db.fetchAdd(1, .monotonic) % c.execs.items.len;
    const q = try a.create(Pub);
    q.* = .{
        .e = e,
        .user_data = user_data,
        .owner = owner,
        .type = ty,
        .data_json = data_json,
        .id = id,
        .endpoint = endpoint,
        .timestamp_ms = m.timestamp_ms,
        .arena = arena,
    };
    c.execs.items[i].post(&q.cmd);
}

/// A ``webhook_publish`` call queued on an open transaction (`db.TxWhat`), run in
/// order on the transaction's connection.
pub fn txOp(any: *db.AnyTx, ctx: *anole.db.Ctx, op: *const db.TxOp, answer: *db.Answer) anyerror!void {
    if (comptime !features.webhooks) return error.Unsupported;
    const e = engine.global orelse return error.Unsupported;
    const client = e.webhooks_state.client orelse return error.Unsupported;
    const T = struct { owner: []const u8 = "", type: []const u8, data: std.json.Value, id: ?[]const u8 = null, endpoint: ?[]const u8 = null, timestamp_ms: i64 = 0 };
    const req = try std.json.parseFromSliceLeaky(T, ctx.arena, op.sql, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const head: anole.webhooks.EventHead = .{
        .owner = req.owner,
        .type = req.type,
        .id = req.id,
        .timestamp = if (req.timestamp_ms != 0) anole.db.Time.fromMillis(req.timestamp_ms) else null,
        .endpoint = req.endpoint,
    };
    const published = switch (any.*) {
        inline else => |*tx, tag| if (comptime @field(features, @tagName(tag)))
            try client.publishIn(tx, ctx, head, req.data)
        else
            unreachable,
    };
    answer.changes = .{ .changes = published.deliveries };
    answer.message = published.message_id;
}

// ---------------------------------------------------------------------------
// The webhook_verify middleware

/// Config check (`config.zig`'s `checkMiddleware`).
pub fn checkVerify(c: config_mod.Config.WebhookVerify, where: []const u8, i: usize, why: *std.Io.Writer) error{Config}!void {
    const fail = struct {
        fn f(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{Config} {
            w.print("config: " ++ fmt, args) catch {};
            return error.Config;
        }
    }.f;
    if (comptime !features.webhooks) return fail(why, "{s}[{d}].webhook_verify: webhooks are not built in (-Dwebhooks)", .{ where, i });
    if ((c.secrets == null) == (c.secrets_env == null)) return fail(why, "{s}[{d}].webhook_verify: exactly one of secrets and secrets_env", .{ where, i });
    if (c.secrets) |l| {
        if (l.len == 0) return fail(why, "{s}[{d}].webhook_verify.secrets: at least one", .{ where, i });
        for (l) |s| if (s.len == 0) return fail(why, "{s}[{d}].webhook_verify.secrets: a secret is empty", .{ where, i });
    }
    if (c.tolerance_ms == 0) return fail(why, "{s}[{d}].webhook_verify.tolerance_ms: must be positive", .{ where, i });
    if (c.preset == .hmac) {
        const h = c.hmac orelse return fail(why, "{s}[{d}].webhook_verify: preset \"hmac\" needs the hmac settings", .{ where, i });
        if (h.header.len == 0) return fail(why, "{s}[{d}].webhook_verify.hmac.header: a header name", .{ where, i });
    } else if (c.hmac != null) return fail(why, "{s}[{d}].webhook_verify.hmac: only with preset \"hmac\"", .{ where, i });
    if (!std.mem.eql(u8, c.dedup, "memory") and !std.mem.eql(u8, c.dedup, "none") and !std.mem.startsWith(u8, c.dedup, "redis:"))
        return fail(why, "{s}[{d}].webhook_verify.dedup: \"memory\", \"none\" or \"redis:<database>\"", .{ where, i });
    if (std.mem.startsWith(u8, c.dedup, "redis:") and c.dedup.len == "redis:".len)
        return fail(why, "{s}[{d}].webhook_verify.dedup: \"redis:\" needs a database name", .{ where, i });
}

/// Builds the middleware (`config.zig`'s `middleware`).
pub fn verifyMiddleware(app: *anole.App, arena: std.mem.Allocator, c: config_mod.Config.WebhookVerify) !anole.http.Middleware(void) {
    if (comptime !features.webhooks) unreachable;
    var secrets: std.ArrayList([]const u8) = .empty;
    if (c.secrets) |l| {
        for (l) |s| try secrets.append(arena, s);
    } else {
        const name = c.secrets_env.?;
        const value = env.get(name) orelse {
            log.err("webhook_verify: the environment variable {s} is not set", .{name});
            return error.Config;
        };
        var it = std.mem.tokenizeScalar(u8, value, ' ');
        while (it.next()) |tok| try secrets.append(arena, tok);
    }
    const ttl = ms(c.dedup_ttl_ms);
    var opts: anole.webhooks.Verify.Options = .{
        .preset = switch (c.preset) {
            .standard => .standard,
            .stripe => .stripe,
            .github => .github,
            .slack => .slack,
            .hmac => .hmac,
        },
        .secrets = secrets.items,
        .tolerance = ms(c.tolerance_ms),
        .on_store_error = switch (c.on_store_error) {
            .reject => .reject,
            .process => .process,
        },
    };
    if (c.hmac) |h| opts.hmac = .{
        .header = h.header,
        .algorithm = switch (h.algorithm) {
            .sha1 => .sha1,
            .sha256 => .sha256,
            .sha512 => .sha512,
        },
        .encoding = switch (h.encoding) {
            .hex => .hex,
            .base64 => .base64,
        },
        .prefix = h.prefix,
        .id_header = h.id_header,
    };
    if (std.mem.eql(u8, c.dedup, "none")) {
        opts.dedup = .none;
    } else if (std.mem.startsWith(u8, c.dedup, "redis:")) {
        const e = engine.global orelse return error.Config;
        const d = db.find(e, c.dedup["redis:".len..]) orelse {
            log.err("webhook_verify.dedup: no database named \"{s}\"", .{c.dedup["redis:".len..]});
            return error.Config;
        };
        switch (d.client) {
            .redis => |r| if (comptime features.redis) {
                opts.dedup = .{ .redis = .{ .client = r, .ttl = ttl } };
            } else unreachable,
            else => {
                log.err("webhook_verify.dedup: database \"{s}\" is not Redis", .{c.dedup["redis:".len..]});
                return error.Config;
            },
        }
    } else {
        opts.dedup = .{ .memory = .{ .ttl = ttl } };
    }
    return app.middleware(app.webhookVerify(opts));
}
