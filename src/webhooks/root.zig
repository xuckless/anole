//! Webhooks (`-Dwebhooks`): Standard Webhooks delivery to customer
//! endpoints, run as jobs, and the `Verify` middleware for incoming ones
//! (p3/webhooks, design-jobs.md phase W).
//!
//! Out: Anole keeps endpoints (owner, URL, event filter, secrets), messages
//! and a delivery log in the jobs store; `publish` turns one event into one
//! job per matching endpoint. Every attempt is signed (`webhook-id`,
//! `webhook-timestamp`, `webhook-signature`), sent through a client that
//! refuses private addresses, retried with backoff for about three days,
//! and recorded. An endpoint that has failed for `disable_after` is
//! disabled and the app is told.
//!
//!     const hooks = try app.webhooks(.{ .jobs = jobs });
//!     const made = try hooks.createEndpoint(req, .{ .owner = "acme", .url = "https://acme.test/hook" });
//!     _ = try hooks.publish(req, .{ .owner = "acme", .type = "invoice.paid" }, .{ .id = 7 });
//!
//! In: `Verify`, see verify.zig.
const std = @import("std");
const dusty = @import("dusty");
const anole = @import("../root.zig");
const jobs = @import("../jobs/root.zig");
const resilience = @import("resilience_core");
const observe = @import("../observe/root.zig");
const env = @import("../env.zig");

pub const sign = @import("sign.zig");
pub const standard = sign;
pub const dedup = @import("dedup.zig");
pub const verify = @import("verify.zig");
pub const store = @import("store.zig");
pub const Verify = verify.Verify;
pub const inbound = verify.inbound;
pub const Inbound = verify.Inbound;

const log = std.log.scoped(.anole_webhooks);

pub const Duration = std.Io.Duration;
pub const Time = anole.db.Time;
pub const Error = jobs.Error;

/// The job kind a delivery runs as.
pub const job_kind = "anole.webhook";
const prune_kind = "anole.webhook.prune";

pub const EventHook = struct {
    context: ?*anyopaque = null,
    call: *const fn (context: ?*anyopaque, ev: *const StatusEvent) void,
};
pub const StatusEvent = struct {
    what: enum { delivery_dead, endpoint_disabled },
    owner: []const u8,
    endpoint: []const u8,
    message: []const u8,
    last_status: u16,
    @"error": []const u8,
};

pub const Options = struct {
    /// Holds endpoints, messages and attempts, and runs the deliveries.
    jobs: *jobs.Client,
    queue: []const u8 = "webhooks",
    timeout: Duration = .fromSeconds(15),
    /// Every try, the first included.
    attempts: u16 = 10,
    /// Ceilings 5 s, 25 s, 2 min, 10 min, 52 min, 4.3 h, 21.7 h, 24 h, 24 h.
    backoff: resilience.Backoff = .{ .base = .fromSeconds(5), .multiplier = 5, .max = .fromSeconds(24 * 3600), .jitter = .equal },
    /// Per endpoint origin; null: none.
    breaker: ?resilience.Breaker.Options = .{},
    /// Null: true in development, false in production.
    allow_private_addresses: ?bool = null,
    /// Null: false in development, true in production.
    require_https: ?bool = null,
    user_agent: []const u8 = "Anole-Webhooks",
    /// A larger `data` is refused (`error.InvalidJob`).
    max_payload: usize = 256 * 1024,
    response_kept: u32 = 4096,
    keep_messages: Duration = .fromSeconds(30 * 24 * 3600),
    keep_attempts: Duration = .fromSeconds(30 * 24 * 3600),
    disable_after: Duration = .fromSeconds(5 * 24 * 3600),
    /// 32 bytes, base64; encrypts stored secrets. Null: ANOLE_WEBHOOKS_KEY,
    /// else they are stored as they are.
    secrets_key: ?[]const u8 = null,
    max_endpoints_per_owner: u16 = 100,
    on_event: ?EventHook = null,
    /// Null: the real clock.
    clock: ?jobs.Clock = null,
};

pub const NewEndpoint = struct {
    /// Your tenant (an account id); "" for app-wide endpoints.
    owner: []const u8 = "",
    url: []const u8,
    /// Event types delivered: exact ("invoice.paid") or a prefix
    /// ("invoice.*"); empty: all.
    types: []const []const u8 = &.{},
    description: []const u8 = "",
    /// Null: a new `whsec_` secret.
    secret: ?[]const u8 = null,
    /// A JSON object kept with it.
    metadata: ?[]const u8 = null,
};
pub const EndpointPatch = struct {
    url: ?[]const u8 = null,
    types: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
};
pub const Endpoint = struct {
    id: []const u8,
    owner: []const u8,
    url: []const u8,
    types: []const []const u8,
    description: []const u8,
    enabled: bool,
    disabled_reason: ?[]const u8,
    failing_since: ?Time,
    created_at: Time,
    updated_at: Time,
    metadata: std.json.Value,
};
pub const Created = struct { endpoint: Endpoint, secret: []const u8 };
pub const Published = struct { message_id: []const u8, deliveries: u32, duplicate: bool };

/// What `publish` sends besides `data`.
pub const EventHead = struct {
    owner: []const u8 = "",
    /// "invoice.paid": [A-Za-z0-9_.-], 1-128 bytes.
    type: []const u8,
    /// Idempotency: the same id (per owner) is published once. Null: a new
    /// msg_ id.
    id: ?[]const u8 = null,
    /// Null: now.
    timestamp: ?Time = null,
    /// Only this endpoint (it must belong to `owner`).
    endpoint: ?[]const u8 = null,
};

pub const Attempt = struct {
    id: i64,
    message_id: []const u8,
    endpoint_id: []const u8,
    attempt: u16,
    at: Time,
    duration_ms: u32,
    status: u16,
    outcome: []const u8,
    @"error": []const u8,
    response: []const u8,
};
pub const Message = struct { id: []const u8, owner: []const u8, type: []const u8, created_at: Time, body: []const u8 };
pub const AttemptFilter = struct { endpoint: ?[]const u8 = null, message: ?[]const u8 = null, limit: u16 = 50, before: ?i64 = null };
pub const MessageFilter = struct { owner: ?[]const u8 = null, type: ?[]const u8 = null, limit: u16 = 50, before: ?[]const u8 = null };

// ---- stored records (JSON)

const SecretRec = struct { secret: []const u8, until_ms: ?i64 = null, enc: bool = false };
const EndpointRec = struct {
    id: []const u8,
    owner: []const u8 = "",
    url: []const u8,
    types: []const []const u8 = &.{},
    description: []const u8 = "",
    secrets: []const SecretRec = &.{},
    enabled: bool = true,
    disabled_reason: ?[]const u8 = null,
    failing_since_ms: ?i64 = null,
    metadata: []const u8 = "{}",
    created_ms: i64 = 0,
    updated_ms: i64 = 0,
};
const MessageRec = struct { id: []const u8, owner: []const u8 = "", type: []const u8, created_ms: i64 = 0, body: []const u8 };
const AttemptRec = struct {
    message_id: []const u8,
    endpoint_id: []const u8,
    attempt: u16 = 0,
    at_ms: i64 = 0,
    duration_ms: u32 = 0,
    status: u16 = 0,
    outcome: []const u8 = "",
    @"error": []const u8 = "",
    response: []const u8 = "",
};
const DeliveryArgs = struct { message: []const u8, endpoint: []const u8 };

fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.InvalidJob;
}
fn toJson(arena: std.mem.Allocator, v: anytype) std.mem.Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

/// The process's client, for the delivery handler.
var active: std.atomic.Value(?*Client) = .init(null);

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    jobs: *jobs.Client,
    store: *store.Store,
    http: *anole.http.Client,
    breakers: resilience.Breakers,
    key: ?[32]u8 = null,
    allow_private: bool,
    require_https: bool,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Client {
        if (options.attempts == 0 or options.attempts > 1000) return invalid("attempts", "must be 1 .. 1000");
        if (options.timeout.nanoseconds <= 0) return invalid("timeout", "must be positive");
        if (options.queue.len == 0) return invalid("queue", "is empty");
        if (options.max_payload == 0) return invalid("max_payload", "must be positive");
        if (options.breaker) |b| b.validate() catch return invalid("breaker", "is invalid");
        const dev = env.environment() == .development;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .jobs = options.jobs,
            .store = undefined,
            .http = undefined,
            .breakers = undefined,
            .allow_private = options.allow_private_addresses orelse dev,
            .require_https = options.require_https orelse !dev,
        };
        const key_text = options.secrets_key orelse env.get("ANOLE_WEBHOOKS_KEY");
        if (key_text) |t| {
            var k: [32]u8 = undefined;
            const n = std.base64.standard.Decoder.calcSizeForSlice(t) catch return invalid("secrets_key", "is not base64");
            if (n != 32) return invalid("secrets_key", "must be 32 bytes, base64");
            std.base64.standard.Decoder.decode(&k, t) catch return invalid("secrets_key", "is not base64");
            self.key = k;
        } else if (env.environment() == .production) {
            log.info("webhook secrets are stored as they are; set secrets_key or ANOLE_WEBHOOKS_KEY to encrypt them", .{});
        }
        const jo = options.jobs.options;
        self.store = try store.Store.init(gpa, io, jo.store, jo.table_prefix, jo.key_prefix);
        errdefer self.store.deinit(gpa);
        self.http = try gpa.create(anole.http.Client);
        errdefer gpa.destroy(self.http);
        self.http.* = anole.http.Client.init(gpa, io, .{
            .max_redirects = 0,
            .max_response_size = @max(options.response_kept, 1) * 16,
            .timeout = options.timeout,
            .user_agent = options.user_agent,
            .deny_private_addresses = !self.allow_private,
        });
        self.breakers = .init(gpa, options.breaker orelse .{}, .http, 1024);
        return self;
    }

    fn invalid(comptime field: []const u8, comptime why: []const u8) error{InvalidOptions} {
        log.err("webhooks: " ++ field ++ " " ++ why, .{});
        return error.InvalidOptions;
    }

    pub fn deinit(self: *Client) void {
        _ = active.cmpxchgStrong(self, null, .monotonic, .monotonic);
        self.breakers.deinit();
        self.http.deinit();
        self.gpa.destroy(self.http);
        self.store.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Creates the tables and makes this client the one deliveries use.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        _ = registry;
        _ = tracer;
        _ = health;
        if (self.jobs.options.migrate) {
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            var c: anole.db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
            try self.store.migrate(&c);
        }
        active.store(self, .release);
        const dev = env.environment() == .development;
        if (dev or self.allow_private) log.info("webhooks: private addresses {s}, https {s}", .{
            if (self.allow_private) "allowed" else "refused",
            if (self.require_https) "required" else "not required",
        });
    }

    /// Registers the delivery and pruning handlers on the jobs client
    /// (`app.webhooks` calls it with the server).
    pub fn register(self: *Client, server: anytype) !void {
        const o = self.options;
        // The delivery queue need not be listed in the jobs options.
        try self.jobs.addQueue(.{ .name = o.queue });
        try self.jobs.handleRaw(server, .{
            .name = job_kind,
            .queue = o.queue,
            .priority = .normal,
            .attempts = o.attempts,
            .backoff = o.backoff,
            .timeout = .fromSeconds(o.timeout.toSeconds() + 5),
        }, .{}, deliverJob);
        try self.jobs.handleRaw(server, .{
            .name = prune_kind,
            .queue = o.queue,
            .priority = .low,
            .attempts = 3,
            .backoff = .{ .base = .fromSeconds(60), .multiplier = 2, .max = .fromSeconds(3600), .jitter = .equal },
            .timeout = .fromSeconds(120),
        }, .{}, pruneJob);
        try self.jobs.cronRaw("anole.webhooks.prune", "17 * * * *", prune_kind, "{}", .{});
    }

    fn deliverJob(job: *jobs.Job) !void {
        const c = active.load(.acquire) orelse return error.WebhooksNotStarted;
        return c.deliver(job);
    }
    fn pruneJob(job: *jobs.Job) !void {
        const c = active.load(.acquire) orelse return error.WebhooksNotStarted;
        try c.prune(job);
    }

    /// Drops messages and attempts past `keep_messages` and `keep_attempts`.
    pub fn prune(self: *Client, c: anytype) Error!void {
        const now = self.nowMs(c);
        try self.store.prune(c, now - self.options.keep_messages.toMilliseconds(), now - self.options.keep_attempts.toMilliseconds());
    }

    fn nowMs(self: *const Client, c: anytype) i64 {
        _ = c;
        if (self.options.clock) |clk| return clk.now(clk.context).toMillis();
        return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
    }

    // ---- publishing

    /// `data` is any value std.json serializes (`.{ .id = 7 }`).
    pub fn publish(self: *Client, c: anytype, event: EventHead, data: anytype) Error!Published {
        const json = toJson(c.arena, data) catch return error.OutOfMemory;
        return self.publishCore({}, c, event, json);
    }
    pub fn publishJson(self: *Client, c: anytype, event: EventHead, data_json: []const u8) Error!Published {
        return self.publishCore({}, c, event, data_json);
    }
    /// The deliveries are enqueued in the caller's transaction, so they
    /// exist only if it commits (the message row itself is not part of it).
    pub fn publishIn(self: *Client, tx: anytype, c: anytype, event: EventHead, data: anytype) Error!Published {
        const json = toJson(c.arena, data) catch return error.OutOfMemory;
        return self.publishCore(tx, c, event, json);
    }

    fn publishCore(self: *Client, tx: anytype, c: anytype, event: EventHead, data_json: []const u8) Error!Published {
        if (!validType(event.type)) return error.InvalidJob;
        if (event.owner.len > 255) return error.InvalidJob;
        if (event.id) |i| if (i.len == 0 or i.len > 255) return error.InvalidJob;
        if (!validJson(c.arena, data_json)) return error.InvalidJob;
        const now = self.nowMs(c);
        const ts = event.timestamp orelse Time.fromMillis(now);
        const ts_json = toJson(c.arena, ts) catch return error.OutOfMemory;
        const type_json = toJson(c.arena, event.type) catch return error.OutOfMemory;
        const body = try std.fmt.allocPrint(c.arena, "{{\"type\":{s},\"timestamp\":{s},\"data\":{s}}}", .{ type_json, ts_json, data_json });
        if (body.len > self.options.max_payload) return error.InvalidJob;

        var id_buf: [30]u8 = undefined;
        const id: []const u8 = blk: {
            if (event.id) |i| if (std.mem.startsWith(u8, i, "msg_") and i.len <= 64 and validType(i)) break :blk i;
            break :blk try c.arena.dupe(u8, sign.newMessageId(self.io, now, &id_buf));
        };
        const rec: MessageRec = .{ .id = id, .owner = event.owner, .type = event.type, .created_ms = now, .body = body };
        const rec_json = toJson(c.arena, rec) catch return error.OutOfMemory;
        if (try self.store.msgPut(c, id, event.owner, event.id, now, rec_json)) |old| {
            const o = try parse(MessageRec, c.arena, old);
            return .{ .message_id = o.id, .deliveries = 0, .duplicate = true };
        }

        const targets = try self.matching(c, event.owner, event.type, event.endpoint);
        const n = try self.enqueueDeliveries(tx, c, id, targets);
        return .{ .message_id = id, .deliveries = n, .duplicate = false };
    }

    fn matching(self: *Client, c: anytype, owner: []const u8, ty: []const u8, only: ?[]const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (only) |eid| {
            const ep = (try self.loadEndpoint(c, eid)) orelse return error.InvalidJob;
            if (!std.mem.eql(u8, ep.owner, owner)) return error.InvalidJob;
            if (ep.enabled) try out.append(c.arena, ep.id);
            return out.items;
        }
        for (try self.store.epList(c, owner)) |body| {
            const ep = try parse(EndpointRec, c.arena, body);
            if (ep.enabled and typeMatches(ep.types, ty)) try out.append(c.arena, ep.id);
        }
        return out.items;
    }

    fn enqueueDeliveries(self: *Client, tx: anytype, c: anytype, message: []const u8, endpoints: []const []const u8) Error!u32 {
        if (endpoints.len == 0) return 0;
        const o = self.options;
        const timeout: Duration = .fromSeconds(o.timeout.toSeconds() + 5);
        const items = try c.arena.alloc(jobs.Client.Item, endpoints.len);
        for (endpoints, items) |eid, *it| {
            it.* = .{
                .kind = job_kind,
                .args_json = try std.fmt.allocPrint(c.arena, "{{\"message\":\"{s}\",\"endpoint\":\"{s}\"}}", .{ message, eid }),
                .opts = .{ .queue = o.queue, .attempts = o.attempts, .timeout = timeout },
            };
        }
        if (@TypeOf(tx) == void) {
            _ = try self.jobs.enqueueMany(c, items);
        } else {
            for (items) |it| _ = try self.jobs.enqueueRawIn(tx, c, it.kind, it.args_json, it.opts);
        }
        return @intCast(endpoints.len);
    }

    // ---- endpoints

    pub fn createEndpoint(self: *Client, c: anytype, e: NewEndpoint) Error!Created {
        try self.checkUrl(e.url);
        if (e.owner.len > 255) return error.InvalidJob;
        for (e.types) |t| if (!validTypePattern(t)) return error.InvalidJob;
        if (e.metadata) |m| if (!validJson(c.arena, m)) return error.InvalidJob;
        if (try self.store.epCount(c, e.owner) >= self.options.max_endpoints_per_owner) return error.InvalidJob;
        const now = self.nowMs(c);
        var sbuf: [50]u8 = undefined;
        const secret = e.secret orelse try c.arena.dupe(u8, sign.newSecret(self.io, &sbuf));
        var probe: [47]u8 = undefined;
        _ = sign.sign(secret, "msg_x", 0, "", &probe) catch return error.InvalidJob;
        var ub: [30]u8 = undefined;
        var idb: [30]u8 = undefined;
        _ = sign.newUlid(self.io, now, ub[0..26]);
        const id = try std.fmt.allocPrint(c.arena, "ep_{s}", .{ub[0..26]});
        _ = &idb;
        const sec = try self.sealSecret(c, secret, id);
        const secrets = try c.arena.dupe(SecretRec, &.{sec});
        const rec: EndpointRec = .{
            .id = id,
            .owner = e.owner,
            .url = e.url,
            .types = e.types,
            .description = e.description,
            .secrets = secrets,
            .metadata = e.metadata orelse "{}",
            .created_ms = now,
            .updated_ms = now,
        };
        try self.saveEndpoint(c, rec);
        return .{ .endpoint = try self.publicEndpoint(c, rec), .secret = secret };
    }

    pub fn updateEndpoint(self: *Client, c: anytype, id: []const u8, patch: EndpointPatch) Error!Endpoint {
        var rec = (try self.loadEndpoint(c, id)) orelse return error.NotFound;
        if (patch.url) |u| {
            try self.checkUrl(u);
            rec.url = u;
        }
        if (patch.types) |t| {
            for (t) |x| if (!validTypePattern(x)) return error.InvalidJob;
            rec.types = t;
        }
        if (patch.description) |d| rec.description = d;
        if (patch.metadata) |m| {
            if (!validJson(c.arena, m)) return error.InvalidJob;
            rec.metadata = m;
        }
        rec.updated_ms = self.nowMs(c);
        try self.saveEndpoint(c, rec);
        return self.publicEndpoint(c, rec);
    }

    pub fn deleteEndpoint(self: *Client, c: anytype, id: []const u8) Error!bool {
        return self.store.epDel(c, id);
    }

    pub fn getEndpoint(self: *Client, c: anytype, id: []const u8) Error!?Endpoint {
        const rec = (try self.loadEndpoint(c, id)) orelse return null;
        return try self.publicEndpoint(c, rec);
    }

    pub fn listEndpoints(self: *Client, c: anytype, owner: []const u8) Error![]Endpoint {
        const rows = try self.store.epList(c, owner);
        const out = try c.arena.alloc(Endpoint, rows.len);
        for (rows, out) |row, *o| o.* = try self.publicEndpoint(c, try parse(EndpointRec, c.arena, row));
        return out;
    }

    /// A new secret signs from now on; the old one keeps signing for
    /// `keep_old`, so receivers can switch over. Returns the new secret.
    pub fn rotateSecret(self: *Client, c: anytype, id: []const u8, keep_old: Duration) Error![]const u8 {
        var rec = (try self.loadEndpoint(c, id)) orelse return error.NotFound;
        const now = self.nowMs(c);
        var sbuf: [50]u8 = undefined;
        const secret = try c.arena.dupe(u8, sign.newSecret(self.io, &sbuf));
        var list: std.ArrayList(SecretRec) = .empty;
        try list.append(c.arena, try self.sealSecret(c, secret, id));
        for (rec.secrets) |s| {
            if (s.until_ms) |u| if (u <= now) continue;
            var old = s;
            const until = now + keep_old.toMilliseconds();
            old.until_ms = if (s.until_ms) |u| @min(u, until) else until;
            try list.append(c.arena, old);
        }
        rec.secrets = list.items;
        rec.updated_ms = now;
        try self.saveEndpoint(c, rec);
        return secret;
    }

    /// Puts a disabled endpoint back.
    pub fn enable(self: *Client, c: anytype, id: []const u8) Error!bool {
        var rec = (try self.loadEndpoint(c, id)) orelse return false;
        rec.enabled = true;
        rec.disabled_reason = null;
        rec.failing_since_ms = null;
        rec.updated_ms = self.nowMs(c);
        try self.saveEndpoint(c, rec);
        return true;
    }

    // ---- replay

    /// Re-sends one message (to one endpoint, or every endpoint it went to).
    pub fn replay(self: *Client, c: anytype, message_id: []const u8, endpoint: ?[]const u8) Error!u32 {
        _ = (try self.store.msgGet(c, message_id)) orelse return error.NotFound;
        if (endpoint) |e| return self.enqueueDeliveries({}, c, message_id, &.{e});
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (try self.store.attList(c, .{ .message = message_id, .limit = 1000 })) |row| {
            const a = try parse(AttemptRec, c.arena, row.body);
            try seen.put(c.arena, a.endpoint_id, {});
        }
        return self.enqueueDeliveries({}, c, message_id, seen.keys());
    }

    /// Re-sends every message whose latest delivery to `endpoint` since
    /// `since` did not succeed.
    pub fn recover(self: *Client, c: anytype, endpoint: []const u8, since: Time) Error!u32 {
        const since_ms = since.toMillis();
        var latest: std.StringArrayHashMapUnmanaged(bool) = .empty;
        var before: ?i64 = null;
        while (true) {
            const page = try self.store.attList(c, .{ .endpoint = endpoint, .before = before, .limit = 500 });
            if (page.len == 0) break;
            for (page) |row| {
                const a = try parse(AttemptRec, c.arena, row.body);
                if (a.at_ms < since_ms) continue;
                const gop = try latest.getOrPut(c.arena, a.message_id);
                if (!gop.found_existing) gop.value_ptr.* = std.mem.eql(u8, a.outcome, "delivered");
            }
            before = page[page.len - 1].id;
            if (page.len < 500 or latest.count() > 10_000) break;
        }
        var n: u32 = 0;
        for (latest.keys(), latest.values()) |mid, ok| {
            if (ok) continue;
            n += try self.enqueueDeliveries({}, c, mid, &.{endpoint});
        }
        return n;
    }

    pub fn attempts(self: *Client, c: anytype, filter: AttemptFilter) Error![]Attempt {
        const rows = try self.store.attList(c, .{ .endpoint = filter.endpoint, .message = filter.message, .before = filter.before, .limit = filter.limit });
        const out = try c.arena.alloc(Attempt, rows.len);
        for (rows, out) |row, *o| {
            const a = try parse(AttemptRec, c.arena, row.body);
            o.* = .{
                .id = row.id,
                .message_id = a.message_id,
                .endpoint_id = a.endpoint_id,
                .attempt = a.attempt,
                .at = Time.fromMillis(a.at_ms),
                .duration_ms = a.duration_ms,
                .status = a.status,
                .outcome = a.outcome,
                .@"error" = a.@"error",
                .response = a.response,
            };
        }
        return out;
    }

    /// Newest first. `type` filters after the page is read, so a page can hold fewer than `limit`.
    pub fn messages(self: *Client, c: anytype, filter: MessageFilter) Error![]Message {
        const rows = try self.store.msgList(c, filter.owner, filter.before, filter.limit);
        var out: std.ArrayList(Message) = .empty;
        for (rows) |row| {
            const m = try parse(MessageRec, c.arena, row);
            if (filter.type) |t| if (!std.mem.eql(u8, t, m.type)) continue;
            try out.append(c.arena, .{ .id = m.id, .owner = m.owner, .type = m.type, .created_at = Time.fromMillis(m.created_ms), .body = m.body });
        }
        return out.items;
    }

    // ---- delivery

    fn deliver(self: *Client, job: *jobs.Job) !void {
        const args = try job.args(DeliveryArgs);
        const now_ms = self.nowMs(job);
        const msg_text = (try self.store.msgGet(job, args.message)) orelse {
            job.discard("message gone");
            return;
        };
        const msg = try parse(MessageRec, job.arena, msg_text);
        var ep = (try self.loadEndpoint(job, args.endpoint)) orelse {
            job.discard("endpoint deleted");
            return;
        };
        if (!ep.enabled) {
            job.discard("endpoint disabled");
            return;
        }

        // The origin's breaker: while open, wait it out without an attempt.
        var origin_buf: [300]u8 = undefined;
        const origin = originOf(ep.url, &origin_buf);
        var permit: ?resilience.Breaker.Permit = null;
        var breaker: ?*resilience.Breaker = null;
        if (self.options.breaker != null and origin.len > 0) {
            breaker = try self.breakers.get(self.io, origin);
            const now_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
            permit = breaker.?.allow(now_ns);
            if (permit == null) {
                const until = breaker.?.openUntil() orelse now_ns + 5 * std.time.ns_per_s;
                const wait: i64 = @intCast(@max(until - now_ns, std.time.ns_per_s));
                try self.logAttempt(job, args, job.attempt, now_ms, 0, 0, "breaker_open", "circuit open", "");
                job.snooze(.fromNanoseconds(wait));
                return;
            }
        }
        const permit_finish = struct {
            fn done(b: ?*resilience.Breaker, p: ?resilience.Breaker.Permit, io: std.Io, o: resilience.Breaker.Outcome) void {
                if (b) |bk| if (p) |pp| bk.record(pp, o, std.Io.Timestamp.now(io, .awake).nanoseconds);
            }
        }.done;

        if (self.require_https and !std.mem.startsWith(u8, ep.url, "https://")) {
            permit_finish(breaker, permit, self.io, .neutral);
            try self.block(job, args, &ep, now_ms, "https required");
            return;
        }

        // Sign with every active secret.
        var sigs: std.ArrayList(u8) = .empty;
        for (ep.secrets) |s| {
            if (s.until_ms) |u| if (u <= now_ms) continue;
            const plain = self.openSecret(job, s, ep.id) catch {
                permit_finish(breaker, permit, self.io, .neutral);
                job.explain("cannot decrypt the endpoint's secret (ANOLE_WEBHOOKS_KEY changed?)", .{});
                try self.logAttempt(job, args, job.attempt, now_ms, 0, 0, "failed", "cannot decrypt the endpoint's secret", "");
                return error.CannotDecryptSecret;
            };
            var out: [47]u8 = undefined;
            const sig = sign.sign(plain, msg.id, @divFloor(now_ms, 1000), msg.body, &out) catch continue;
            if (sigs.items.len > 0) try sigs.append(job.arena, ' ');
            try sigs.appendSlice(job.arena, sig);
        }
        const ts_text = try std.fmt.allocPrint(job.arena, "{d}", .{@divFloor(now_ms, 1000)});

        const started = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const cl: anole.Client = .{ .http = self.http };
        var resp = cl.fetch(ep.url, .{
            .method = .post,
            .headers = &.{
                .{ "webhook-id", msg.id },
                .{ "webhook-timestamp", ts_text },
                .{ "webhook-signature", sigs.items },
                .{ "content-type", "application/json" },
            },
            .body = msg.body,
            .decompress = false,
            .retry = .off,
        }) catch |err| {
            const dur = elapsedMs(self.io, started);
            if (err == error.Canceled) {
                permit_finish(breaker, permit, self.io, .neutral);
                return err;
            }
            if (err == error.AddressNotAllowed or err == error.InvalidUri or err == error.UnsupportedUriScheme or err == error.UriMissingHost) {
                permit_finish(breaker, permit, self.io, .neutral);
                const why = if (err == error.AddressNotAllowed) "address not allowed" else "invalid url";
                try self.block(job, args, &ep, now_ms, why);
                return;
            }
            permit_finish(breaker, permit, self.io, .failure);
            try self.logAttempt(job, args, job.attempt, now_ms, dur, 0, "failed", @errorName(err), "");
            try self.noteFailure(job, &ep, now_ms);
            try self.maybeDead(job, args, &ep, 0, @errorName(err), now_ms);
            job.explain("{s}", .{@errorName(err)});
            return error.DeliveryFailed;
        };
        defer resp.deinit();
        const dur = elapsedMs(self.io, started);
        const code: u16 = @intCast(@intFromEnum(resp.status()));
        const kept = self.options.response_kept;
        const body_full = resp.body() catch "";
        const body_kept = body_full[0..@min(body_full.len, kept)];

        if (code >= 200 and code < 300) {
            permit_finish(breaker, permit, self.io, .success);
            try self.logAttempt(job, args, job.attempt, now_ms, dur, code, "delivered", "", body_kept);
            if (ep.failing_since_ms != null) {
                ep.failing_since_ms = null;
                ep.updated_ms = now_ms;
                try self.saveEndpoint(job, ep);
            }
            return;
        }
        if (code == 410) {
            permit_finish(breaker, permit, self.io, .neutral);
            try self.logAttempt(job, args, job.attempt, now_ms, dur, code, "gone", "410 Gone", body_kept);
            try self.disable(job, &ep, "410 Gone", now_ms);
            self.notify(.endpoint_disabled, ep, args.message, code, "410 Gone");
            job.discard("410 Gone");
            return;
        }
        const verdict: resilience.Breaker.Outcome = if (code == 408 or code >= 500) .failure else .neutral;
        permit_finish(breaker, permit, self.io, if (code == 429) .neutral else verdict);
        const err_text = try std.fmt.allocPrint(job.arena, "status {d}", .{code});
        try self.logAttempt(job, args, job.attempt, now_ms, dur, code, "failed", err_text, body_kept);
        try self.noteFailure(job, &ep, now_ms);
        try self.maybeDead(job, args, &ep, code, err_text, now_ms);
        if (code == 429 or code == 503) if (resp.header("Retry-After")) |ra| {
            if (anole.http.Client.retryAfterValue(ra, @divFloor(now_ms, 1000))) |d| {
                if (d.toSeconds() <= 24 * 3600) {
                    job.retryIn(d);
                    job.explain("{s}", .{err_text});
                    return error.DeliveryFailed;
                }
            }
        };
        job.explain("{s}", .{err_text});
        return error.DeliveryFailed;
    }

    fn block(self: *Client, job: *jobs.Job, args: DeliveryArgs, ep: *EndpointRec, now_ms: i64, why: []const u8) !void {
        try self.logAttempt(job, args, job.attempt, now_ms, 0, 0, "blocked", why, "");
        try self.disable(job, ep, why, now_ms);
        self.notify(.endpoint_disabled, ep.*, args.message, 0, why);
        job.discard(why);
    }

    fn disable(self: *Client, c: anytype, ep: *EndpointRec, reason: []const u8, now_ms: i64) !void {
        ep.enabled = false;
        ep.disabled_reason = reason;
        ep.updated_ms = now_ms;
        try self.saveEndpoint(c, ep.*);
    }

    fn noteFailure(self: *Client, c: anytype, ep: *EndpointRec, now_ms: i64) !void {
        if (ep.failing_since_ms != null) return;
        ep.failing_since_ms = now_ms;
        ep.updated_ms = now_ms;
        try self.saveEndpoint(c, ep.*);
    }

    /// On the last attempt: the delivery is dead; an endpoint failing for
    /// `disable_after` is disabled too.
    fn maybeDead(self: *Client, job: *jobs.Job, args: DeliveryArgs, ep: *EndpointRec, code: u16, err_text: []const u8, now_ms: i64) !void {
        if (job.attempt < job.max_attempts) return;
        self.notify(.delivery_dead, ep.*, args.message, code, err_text);
        if (ep.failing_since_ms) |since| {
            if (now_ms - since >= self.options.disable_after.toMilliseconds()) {
                const reason = try std.fmt.allocPrint(job.arena, "failing since {f}", .{Time.fromMillis(since)});
                try self.disable(job, ep, reason, now_ms);
                self.notify(.endpoint_disabled, ep.*, args.message, code, reason);
            }
        }
    }

    fn notify(self: *Client, what: @FieldType(StatusEvent, "what"), ep: EndpointRec, message: []const u8, status: u16, err_text: []const u8) void {
        log.warn("webhook {t}: endpoint {s} message {s} status {d}", .{ what, ep.id, message, status });
        if (self.options.on_event) |h| h.call(h.context, &.{
            .what = what,
            .owner = ep.owner,
            .endpoint = ep.id,
            .message = message,
            .last_status = status,
            .@"error" = err_text,
        });
    }

    fn logAttempt(self: *Client, c: anytype, args: DeliveryArgs, attempt: u16, at_ms: i64, dur_ms: u64, status: u16, outcome: []const u8, err_text: []const u8, response: []const u8) !void {
        const rec: AttemptRec = .{
            .message_id = args.message,
            .endpoint_id = args.endpoint,
            .attempt = attempt,
            .at_ms = at_ms,
            .duration_ms = @intCast(@min(dur_ms, std.math.maxInt(u32))),
            .status = status,
            .outcome = outcome,
            .@"error" = err_text,
            .response = response,
        };
        const body = try toJson(c.arena, rec);
        try self.store.attAdd(c, args.message, args.endpoint, at_ms, body);
        log.info("webhook delivery {s}: endpoint {s} message {s} status {d} attempt {d}", .{ outcome, args.endpoint, args.message, status, attempt });
    }

    // ---- helpers

    fn checkUrl(self: *Client, url: []const u8) Error!void {
        if (url.len == 0 or url.len > 2048) return error.InvalidJob;
        const uri = std.Uri.parse(url) catch return error.InvalidJob;
        const https = std.mem.eql(u8, uri.scheme, "https");
        if (!https and !std.mem.eql(u8, uri.scheme, "http")) return error.InvalidJob;
        if (uri.host == null) return error.InvalidJob;
        if (self.require_https and !https) return error.InvalidJob;
    }

    fn loadEndpoint(self: *Client, c: anytype, id: []const u8) Error!?EndpointRec {
        const text = (try self.store.epGet(c, id)) orelse return null;
        return try parse(EndpointRec, c.arena, text);
    }

    fn saveEndpoint(self: *Client, c: anytype, rec: EndpointRec) Error!void {
        const text = toJson(c.arena, rec) catch return error.OutOfMemory;
        try self.store.epPut(c, rec.id, rec.owner, text);
    }

    fn publicEndpoint(self: *Client, c: anytype, r: EndpointRec) Error!Endpoint {
        _ = self;
        const meta = std.json.parseFromSliceLeaky(std.json.Value, c.arena, r.metadata, .{}) catch std.json.Value{ .object = .empty };
        return .{
            .id = r.id,
            .owner = r.owner,
            .url = r.url,
            .types = r.types,
            .description = r.description,
            .enabled = r.enabled,
            .disabled_reason = r.disabled_reason,
            .failing_since = if (r.failing_since_ms) |m| Time.fromMillis(m) else null,
            .created_at = Time.fromMillis(r.created_ms),
            .updated_at = Time.fromMillis(r.updated_ms),
            .metadata = meta,
        };
    }

    fn sealSecret(self: *Client, c: anytype, secret: []const u8, endpoint_id: []const u8) Error!SecretRec {
        if (self.key) |k| {
            const sealed = try sign.seal(c.arena, self.io, k, secret, endpoint_id);
            return .{ .secret = sealed, .enc = true };
        }
        return .{ .secret = secret };
    }

    fn openSecret(self: *Client, c: anytype, s: SecretRec, endpoint_id: []const u8) ![]const u8 {
        if (!s.enc) return s.secret;
        const k = self.key orelse return error.Decrypt;
        return sign.open(c.arena, k, s.secret, endpoint_id);
    }
};

fn validJson(arena: std.mem.Allocator, text: []const u8) bool {
    return std.json.Scanner.validate(arena, text) catch false;
}

fn elapsedMs(io: std.Io, started_ns: i96) u64 {
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
    return @intCast(@max(@divFloor(now - started_ns, std.time.ns_per_ms), 0));
}

fn originOf(url: []const u8, buf: []u8) []const u8 {
    const uri = std.Uri.parse(url) catch return "";
    const host = uri.host orelse return "";
    var hb: [255]u8 = undefined;
    const h = host.toRaw(&hb) catch return "";
    const https = std.mem.eql(u8, uri.scheme, "https");
    const port = uri.port orelse if (https) @as(u16, 443) else 80;
    return std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ uri.scheme, h, port }) catch "";
}

fn validType(t: []const u8) bool {
    if (t.len == 0 or t.len > 128) return false;
    for (t) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-' => {},
        else => return false,
    };
    return true;
}

fn validTypePattern(t: []const u8) bool {
    if (t.len > 1 and t[t.len - 1] == '*') return validType(t[0 .. t.len - 1]);
    return validType(t);
}

fn typeMatches(patterns: []const []const u8, ty: []const u8) bool {
    if (patterns.len == 0) return true;
    for (patterns) |p| {
        if (p.len > 0 and p[p.len - 1] == '*') {
            if (std.mem.startsWith(u8, ty, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, p, ty)) return true;
    }
    return false;
}

test "event type matching" {
    try std.testing.expect(typeMatches(&.{}, "a.b"));
    try std.testing.expect(typeMatches(&.{"invoice.*"}, "invoice.paid"));
    try std.testing.expect(!typeMatches(&.{"invoice.*"}, "user.created"));
    try std.testing.expect(typeMatches(&.{ "x", "invoice.paid" }, "invoice.paid"));
    try std.testing.expect(!typeMatches(&.{"invoice"}, "invoice.paid"));
    try std.testing.expect(validTypePattern("invoice.*"));
    try std.testing.expect(!validType("bad type"));
}

test {
    _ = sign;
    _ = dedup;
    _ = verify;
    _ = store;
    _ = @import("webhooks_test.zig");
}
