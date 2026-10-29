//! The client: the topology kept current by one monitor per server, a
//! connection pool per server per executor, implicit sessions, and the
//! loop every command goes through (select a server, check out a
//! connection, send, read, retry once when the specs allow, map errors).
//!
//! Specifications followed: server-discovery-and-monitoring and
//! server-monitoring (polling: `hello` every heartbeatFrequencyMS, at once
//! on request; the streaming protocol is not built), server-selection
//! (primary only), connection-monitoring-and-pooling (per executor, with
//! generations), driver-sessions (implicit only), retryable-writes and
//! retryable-reads (one retry), client-side-operations-timeout (a call's
//! timeout bounds it and becomes `maxTimeMS`).
const std = @import("std");
const builtin = @import("builtin");
const bson = @import("bson");
const dusty = @import("dusty");
const shared = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const resilience = @import("../resilience/root.zig");
const net = @import("../net/client_stream.zig");
const wire = @import("wire.zig");
const sdam = @import("sdam.zig");
const uri = @import("uri.zig");
const scram = @import("scram.zig");
const conn_mod = @import("connection.zig");
const dynamic_mod = @import("dynamic.zig");

const observe = @import("../observe/root.zig");
const coll_mod = @import("collection.zig");
const change_stream = @import("change_stream.zig");

const Connection = conn_mod.Connection;
pub const Database = coll_mod.Database;
pub const Collection = coll_mod.Collection;
const placement = dusty.placement;
const log = @import("../errors.zig").log;

/// `app.mongodb(options)` and `Client.init`. Every field has a
/// default, so `.{}` connects from `MONGODB_URI`.
pub const Options = struct {
    /// The connection string. Null: `MONGODB_URI` from the environment,
    /// else mongodb://localhost:27017. Options in it win over the fields
    /// below, as the connection-string spec recommends.
    url: ?[]const u8 = null,
    /// Where `MONGODB_URI` is read from (`std.process.Init.Minimal.environ`);
    /// null: the C library's environment.
    environ: ?std.process.Environ = null,
    /// The database `collection(name)` uses. Null: the URL's path, else
    /// "test" (as the official drivers do).
    database: ?[]const u8 = null,
    /// The name in metrics (`db` label), spans and `/readyz`. Null: "mongodb".
    name: ?[]const u8 = null,
    /// TLS beyond what the URL says: a CA or a client certificate in
    /// memory. Giving `ca` or `client_certificate` turns TLS on, and then a
    /// URL that turns TLS off (`tls=false`) or stops checking the
    /// certificate (`tlsInsecure`, `tlsAllowInvalidCertificates`,
    /// `tlsAllowInvalidHostnames`) is refused rather than obeyed.
    tls: shared.Tls = .{},
    /// Connections at most, split between the executors (`maxPoolSize`).
    /// Null: 100. 0 is refused.
    max_connections: ?u32 = null,
    /// How long a call waits for a pooled connection before
    /// `error.ServiceUnavailable` (`waitQueueTimeoutMS`).
    acquire_timeout: std.Io.Duration = .fromSeconds(10),
    /// How long a call waits for a server it can use (a primary) before
    /// `error.ServiceUnavailable` (`serverSelectionTimeoutMS`).
    server_selection_timeout: std.Io.Duration = .fromSeconds(30),
    /// TCP connect and TLS handshake (`connectTimeoutMS`).
    /// Null: no limit.
    connect_timeout: ?std.Io.Duration = .fromSeconds(10),
    /// Between two checks of a server (`heartbeatFrequencyMS`).
    heartbeat: std.Io.Duration = .fromSeconds(10),
    /// A bound on every call that has no `QueryOptions.timeout` of its own,
    /// also sent as `maxTimeMS` (`timeoutMS`). A request's deadline applies
    /// too, whichever comes first. Null: none.
    timeout: ?std.Io.Duration = .fromSeconds(30),
    /// Idle connections older than this are closed (`maxIdleTimeMS`).
    idle_timeout: ?std.Io.Duration = null,
    /// Select a server and open one connection per executor's pool before
    /// serving, and fail the start if that fails. Off: connections open as
    /// calls need them.
    connect_at_start: bool = false,
    /// What `/readyz` waits for the ping.
    ping_timeout: std.Io.Duration = .fromSeconds(2),
    /// Retry a read once after a network error or a primary change
    /// (`retryReads`).
    retry_reads: bool = true,
    /// Retry a single-document write once, likewise, on a replica set or
    /// sharded cluster (`retryWrites`).
    retry_writes: bool = true,
    /// Which error classes become which statuses.
    errors: shared.ErrorMap = .{},
    /// Fails calls fast (503, `lastError` code "circuit_open") after no
    /// server could be reached repeatedly; null: never.
    breaker: ?resilience.Breaker.Options = .{},
    /// Accepted for the same shape as the other connectors; MongoDB has
    /// the spec's retryable reads and writes (`retry_reads`,
    /// `retry_writes`) and ignores `QueryOptions.retry`.
    retry: resilience.Retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(50), .max = .fromSeconds(1) } },
    /// The bounds of the results kept for reads with `.cache`
    /// (`anole.db.QueryOptions`).
    cache: shared.CacheOptions = .{},
};

/// The connection string when neither `Options.url` nor `MONGODB_URI`
/// gives one.
pub const default_url = "mongodb://localhost:27017";

/// A connection pool for one server on one executor (CMAP, without the
/// background thread: connections open when a call needs one).
const Pool = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    /// Most recently used last.
    idle: std.ArrayList(*Connection) = .empty,
    /// Open, checked out, or being opened.
    total: usize = 0,
    /// 0: no limit.
    max: usize,
};

/// What the client keeps per server: its address, pools and monitor.
pub const Server = struct {
    client: *Client,
    address: conn_mod.Address,
    pools: internal.PerExecutor(Pool),
    /// Mirrors the topology's pool generation; connections of an older one
    /// are closed when they come back.
    generation: std.atomic.Value(u32) = .init(0),
    /// Wakes the monitor for a check now.
    check_now: std.Io.Event = .unset,
    /// The server left the topology: its monitor ends, its connections close.
    retired: std.atomic.Value(bool) = .init(false),
    /// The monitor's connection, for `close` to wake it.
    monitor_conn: std.atomic.Value(?*Connection) = .init(null),

    fn pool(s: *Server, io: std.Io) *Pool {
        return s.pools.get(io);
    }
};

/// Tests only (void outside test builds): runs right after a monitor is
/// spawned, with the client's `io`, once (the caller disarms it). It stands
/// for the spawn's own yield on a busy executor (zio task.zig, the run
/// queue's threshold).
pub var test_after_monitor_spawn: if (builtin.is_test) ?*const fn (std.Io) void else void = if (builtin.is_test) null else {};
/// Tests only: runs in `deinit` for a server whose monitor holds a
/// connection, once (the caller disarms it).
pub var test_close_hold: if (builtin.is_test) ?*const fn (*Server) void else void = if (builtin.is_test) null else {};
/// Tests only: runs as a monitor ends, after it closed its connection
/// (every monitor, until the test clears it).
pub var test_monitor_closed: if (builtin.is_test) ?*const fn (*Server) void else void = if (builtin.is_test) null else {};

/// The client with `QueryOptions` (`Client.with`): the databases and
/// collections it leads to make their calls with them.
pub const Query = struct {
    client: *Client,
    options: shared.QueryOptions,

    /// `Client.db`, with the options.
    pub fn db(self: Query, name: []const u8) Database {
        return self.client.db(name).with(self.options);
    }

    /// `Client.collection`, with the options.
    pub fn collection(self: Query, name: []const u8) Collection {
        return self.client.collection(name).with(self.options);
    }

    /// Runs `op` ("find", "insertOne"... as `anole.mongodb.dynamic.Op`) on
    /// `collection_name` of the default database with documents known only at
    /// run time (what the C ABI passes), the context first like every other
    /// call: `anole.mongodb.dynamic.run` with these options.
    pub fn dynamic(self: Query, c: *shared.Ctx, op: dynamic_mod.Op, collection_name: []const u8, docs: []const bson.Document) Error!dynamic_mod.Result {
        const database = self.db(self.client.default_database);
        return dynamic_mod.run(database.collection(collection_name), database, c, op, docs);
    }
};

/// A server session (driver-sessions): its id and transaction number.
pub const Session = struct {
    id: [16]u8,
    last_used: std.Io.Clock.Timestamp,
    txn_number: i64 = 0,
    /// A network error happened while it was in use: the server may still
    /// hold it, so it is not reused.
    dirty: bool = false,
};

const SessionPool = struct {
    mutex: std.Io.Mutex = .init,
    list: std.ArrayList(*Session) = .empty,
};

/// A MongoDB client: the handle in the App state. It monitors the
/// deployment's servers, keeps a connection pool per server and executor,
/// and runs every call on the primary. Safe to use from any task.
///
///     const users = app.db.collection("users");
///     const user = try users.findOne(User, req, .{ .email = email }, .{});
pub const Client = struct {
    /// The console's `/db` "system" for this connector.
    pub const console_system = "mongodb";

    gpa: std.mem.Allocator,
    io: std.Io,
    /// The connection string, the credential, the metadata: the client's
    /// configuration, freed with it.
    arena_state: std.heap.ArenaAllocator,
    settings: conn_mod.Settings,
    default_database: []const u8,
    options: Options,
    /// `Options.name`, resolved.
    name: []const u8,
    /// `Options.max_connections`, resolved.
    max_connections: u32,
    errors: shared.ErrorMap,
    /// The breaker (`Options.breaker`).
    guard: internal.Guard,
    /// Write and read concerns from the URL, as BSON (empty when unset).
    write_concern: ?[]const u8 = null,
    read_concern: ?[]const u8 = null,
    direct: bool,
    observer: shared.Observer,
    readiness: shared.Readiness = undefined,

    /// Guards the topology and the server list.
    mutex: std.Io.Mutex = .init,
    /// Broadcast when the topology changes (selection waits on it).
    changed: std.Io.Condition = .init,
    topology: sdam.Topology,
    servers: std.ArrayList(*Server) = .empty,
    /// Monitors.
    group: std.Io.Group = .init,
    closing: std.atomic.Value(bool) = .init(false),
    scram_cache: scram.Cache = .{},
    sessions: internal.PerExecutor(SessionPool),
    /// Reads with `.coalesce` or `.cache` (`with`), and `invalidate` for
    /// cached results: `app.db.cache.invalidate(.{ .tag = "users" })`.
    cache: shared.QueryCache,

    /// Parses the connection string (`opts.url`, else `MONGODB_URI`, else
    /// localhost) and starts monitoring its servers. Opens no connection
    /// for calls yet: those open when calls need them, per executor. Fails
    /// at once on a bad connection string or an option the client cannot
    /// honour (a read preference other than primary, `mongodb+srv://`,
    /// a load balancer).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        if (opts.max_connections) |n| if (n == 0) {
            log.err("mongodb: max_connections is 0; set at least 1, or leave it null for 100", .{});
            return error.InvalidOptions;
        };
        if (opts.tls.insecure_skip_verify and opts.tls.ca != null) {
            log.err("mongodb: tls.insecure_skip_verify cannot be set with tls.ca: one checks the server's certificate and the other does not", .{});
            return error.InvalidOptions;
        }
        if (opts.tls.client_certificate) |cc| if (cc == .dev_self_signed) {
            log.err("mongodb: tls.client_certificate cannot be .dev_self_signed", .{});
            return error.InvalidOptions;
        };
        const name = opts.name orelse "mongodb";
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena_state = .init(gpa),
            .name = name,
            .max_connections = opts.max_connections orelse 100,
            .settings = undefined,
            .default_database = undefined,
            .options = opts,
            .errors = opts.errors,
            .guard = try .init(.mongodb, name, opts.breaker, opts.retry),
            .direct = false,
            .observer = .{ .system = .mongodb, .name = name },
            .topology = undefined,
            .sessions = undefined,
            .cache = try .init(gpa, io, .mongodb, name, opts.cache),
        };
        errdefer self.cache.deinit();
        errdefer self.arena_state.deinit();
        const arena = self.arena_state.allocator();

        const text = try arena.dupe(u8, opts.url orelse shared.env(opts.environ, "MONGODB_URI") orelse default_url);
        var diag: uri.Diagnostic = .{};
        const cs = uri.parse(arena, text, &diag) catch |err| {
            log.warn("mongodb: {s}: {f}", .{ diag.message, shared.redacted(text) });
            return err;
        };
        for (cs.warnings) |w| log.warn("mongodb: {s}", .{w});
        const credential = uri.credential(arena, cs, &diag) catch |err| {
            log.warn("mongodb: {s}", .{diag.message});
            return err;
        };
        try self.configure(arena, cs, credential, opts);

        self.sessions = try .init(gpa, io);
        errdefer self.sessions.deinit(gpa);
        for (self.sessions.pools) |*p| p.* = .{};

        var seeds: std.ArrayList([]const u8) = .empty;
        for (cs.hosts) |h| try seeds.append(arena, try sdam.formatAddress(arena, h.name, h.port, h.kind == .unix));
        self.direct = cs.boolean("directConnection") orelse false;
        self.topology = try sdam.Topology.init(gpa, .{ .seeds = seeds.items, .set_name = cs.string("replicaSet"), .direct = self.direct });
        errdefer self.topology.deinit();

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.syncServers();
        return self;
    }

    /// The URL's options and `opts`, checked and made into settings.
    fn configure(self: *Client, arena: std.mem.Allocator, cs: uri.ConnectionString, credential: ?uri.Credential, opts: Options) !void {
        if (cs.scheme == .mongodb_srv) {
            log.warn("mongodb: mongodb+srv:// needs a DNS SRV lookup, which Anole does not do yet: use the standard connection string (mongodb://host1,host2,host3/?replicaSet=...&tls=true), which MongoDB Atlas shows under Connect > Drivers when you pick an older driver version", .{});
            return error.Unsupported;
        }
        if (cs.boolean("loadBalanced") orelse false) {
            log.warn("mongodb: loadBalanced=true is not supported", .{});
            return error.Unsupported;
        }
        if (cs.string("readPreference")) |mode| if (!std.mem.eql(u8, mode, "primary")) {
            log.warn("mongodb: readPreference={s} is not supported yet (primary only)", .{mode});
            return error.Unsupported;
        };
        if (cs.string("tlsCertificateKeyFilePassword") != null) {
            log.warn("mongodb: tlsCertificateKeyFilePassword: encrypted keys are not supported", .{});
            return error.Unsupported;
        }
        if (credential) |c| if (c.mechanism) |m| switch (m) {
            .scram_sha_1, .scram_sha_256, .plain, .x509 => {},
            else => {
                log.warn("mongodb: authMechanism={s} is not supported", .{m.name()});
                return error.Unsupported;
            },
        };

        var o = opts;
        if (cs.int("maxPoolSize")) |n| {
            if (n == 0) {
                log.err("mongodb: maxPoolSize=0 (no limit) is not supported; set a number", .{});
                return error.InvalidOptions;
            }
            self.max_connections = @intCast(n);
        }
        if (cs.int("waitQueueTimeoutMS")) |n| o.acquire_timeout = .fromMilliseconds(n);
        if (cs.int("serverSelectionTimeoutMS")) |n| o.server_selection_timeout = .fromMilliseconds(n);
        if (cs.int("connectTimeoutMS")) |n| o.connect_timeout = if (n == 0) null else .fromMilliseconds(n);
        if (cs.int("heartbeatFrequencyMS")) |n| o.heartbeat = .fromMilliseconds(n);
        if (cs.int("timeoutMS")) |n| o.timeout = if (n == 0) null else .fromMilliseconds(n);
        if (cs.int("maxIdleTimeMS")) |n| o.idle_timeout = if (n == 0) null else .fromMilliseconds(n);
        if (cs.boolean("retryReads")) |v| o.retry_reads = v;
        if (cs.boolean("retryWrites")) |v| o.retry_writes = v;
        self.options = o;

        // The URL often comes from the environment; it may not weaken TLS
        // that the code asks for, and weakening it otherwise is logged.
        const weakening = [_][]const u8{ "tlsInsecure", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames" };
        const tls_given = opts.tls.ca != null or opts.tls.client_certificate != null or opts.tls.insecure_skip_verify;
        if (tls_given) {
            if (cs.boolean("tls") == false) {
                log.warn("mongodb: the URL turns TLS off (tls=false), but Options.tls asks for it; take it out of the URL", .{});
                return error.InvalidUri;
            }
            for (weakening) |name| if (cs.boolean(name) orelse false) {
                log.warn("mongodb: the URL turns certificate checks off ({s}=true), but Options.tls asks for TLS; take it out of the URL, or set the check off in Options.tls", .{name});
                return error.InvalidUri;
            };
        } else for (weakening) |name| if (cs.boolean(name) orelse false) {
            log.warn("mongodb: {s}=true: the server's certificate is not fully checked, so whoever is between this process and the server can read and change everything", .{name});
        };

        // TLS: on with tls=true, with any tls* option, or with `opts.tls`.
        var tls: ?net.ConnectOptions.Tls = if (tls_given) .{
            .ca = opts.tls.ca orelse .system,
            .client_certificate = opts.tls.client_certificate,
            .insecure_skip_verify = opts.tls.insecure_skip_verify,
        } else null;
        const tls_on = cs.boolean("tls") orelse (tls != null or cs.string("tlsCAFile") != null or
            cs.string("tlsCertificateKeyFile") != null or cs.get("tlsInsecure") != null or
            cs.get("tlsAllowInvalidCertificates") != null or cs.get("tlsAllowInvalidHostnames") != null);
        if (tls_on) {
            var t = tls orelse net.ConnectOptions.Tls{};
            if (cs.string("tlsCAFile")) |path| t.ca = .{ .file = path };
            if (cs.string("tlsCertificateKeyFile")) |path| t.client_certificate = .fromFiles(path, path);
            if (cs.boolean("tlsInsecure") orelse false) t.insecure_skip_verify = true;
            if (cs.boolean("tlsAllowInvalidCertificates") orelse false) t.insecure_skip_verify = true;
            if (cs.boolean("tlsAllowInvalidHostnames") orelse false) t.skip_host_check = true;
            tls = t;
        } else tls = null;

        self.settings = .{
            .tls = tls,
            .connect_timeout = o.connect_timeout,
            .credential = credential,
            .metadata = try conn_mod.clientMetadata(arena, cs.string("appname")),
            .scram_cache = &self.scram_cache,
        };
        self.default_database = opts.database orelse cs.database orelse "test";

        // Write and read concerns, sent with every write or read.
        const w = cs.get("w");
        const j = cs.boolean("journal");
        const wtimeout = cs.int("wTimeoutMS");
        if (w != null or j != null or wtimeout != null) {
            var b: bson.Builder = .init(arena);
            try b.begin();
            if (w) |v| switch (v) {
                .int => |n| try b.append("w", .{ .int32 = @intCast(n) }),
                .string => |s| try b.append("w", .{ .string = s }),
                else => {},
            };
            if (j) |v| try b.append("j", .{ .boolean = v });
            if (wtimeout) |n| try b.append("wtimeout", .{ .int64 = n });
            try b.end();
            self.write_concern = b.bytes();
        }
        if (cs.string("readConcernLevel")) |level| {
            var b: bson.Builder = .init(arena);
            try b.begin();
            try b.append("level", .{ .string = level });
            try b.end();
            self.read_concern = b.bytes();
        }
    }

    /// A database: `client.db("app").collection("users")`.
    /// A change stream over the whole deployment (`allChangesForCluster`);
    /// see `Collection.watch`.
    pub fn watch(self: *Client, comptime T: type, c: anytype, pipeline: anytype, opts: change_stream.ChangeStreamOptions) Error!change_stream.ChangeStream(T) {
        return .{ .raw = try change_stream.open(self, c, .cluster, pipeline, opts) };
    }

    pub fn db(self: *Client, name: []const u8) Database {
        return .{ .client = self, .name = name };
    }

    /// A collection of the default database (the connection string's,
    /// else `Options.database`, else "test").
    pub fn collection(self: *Client, name: []const u8) Collection {
        return self.db(self.default_database).collection(name);
    }

    /// The calls with `opts`, as on the other connectors:
    /// `app.db.with(.{ .timeout = .fromSeconds(2) }).collection("users").find(...)`.
    /// A timeout bounds each call (server selection, the pool, the round
    /// trips) and goes to the server as `maxTimeMS`; `coalesce` and `cache`
    /// share or keep the reads (`anole.db.QueryOptions`).
    pub fn with(self: *Client, opts: shared.QueryOptions) Query {
        return .{ .client = self, .options = opts };
    }

    /// Asks the primary to answer (`ping`).
    pub fn ping(self: *Client, c: anytype) Error!void {
        _ = try self.db("admin").runCommand(c, .{ .ping = 1 });
    }

    /// What the server hands over when serving starts (`app.mongodb`): the
    /// app's metrics registry, tracer and health checks, when it has them.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        self.observer = try .init(.mongodb, self.name, registry, tracer);
        try self.guard.observe(self.gpa, registry);
        try self.cache.observe(registry);
        if (health) |h| {
            self.readiness = .{ .io = self.io, .context = self, .ping = readyPing };
            try self.readiness.register(h, self.name);
        }
        if (self.options.connect_at_start) self.warm() catch |err| {
            log.err("mongodb \"{s}\": not serving, no server is reachable ({t})", .{ self.name, err });
            return switch (err) {
                error.Canceled => error.Canceled,
                else => error.ServiceUnavailable,
            };
        };
    }

    /// `connect_at_start`: selects a server (within the server selection
    /// timeout) and opens one connection in each executor's pool.
    fn warm(self: *Client) !void {
        const io = self.io;
        const s = try self.select(io, null);
        for (s.pools.pools) |*p| {
            const generation = s.generation.load(.acquire);
            const c = try Connection.open(self.gpa, io, s.address, self.settings, true);
            c.generation = generation;
            c.server = s;
            try p.mutex.lock(io);
            defer p.mutex.unlock(io);
            p.idle.append(self.gpa, c) catch {
                c.close();
                return error.OutOfMemory;
            };
            p.total += 1;
            self.observer.connections(1, 0);
        }
    }

    /// The readiness check: a ping within `ping_timeout`.
    fn readyPing(context: *anyopaque, io: std.Io) bool {
        const self: *Client = @ptrCast(@alignCast(context));
        var buf: [2048]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var c: shared.Ctx = .{ .io = io, .arena = fba.allocator() };
        _ = self.db("admin").with(.{ .timeout = self.options.ping_timeout }).runCommand(&c, .{ .ping = 1 }) catch return false;
        return true;
    }

    /// Ends the sessions the server holds for this client, stops the
    /// monitors, closes every connection and frees the client. Calls must
    /// have finished.
    pub fn deinit(self: *Client) void {
        const io = self.io;
        // First: a read still running for the cache holds a connection.
        self.cache.deinit();
        self.guard.deinit();
        self.endSessions();
        self.closing.store(true, .release);
        self.mutex.lockUncancelable(io);
        for (self.servers.items) |s| {
            s.retired.store(true, .release);
            if (s.monitor_conn.load(.acquire)) |c| {
                if (builtin.is_test) if (test_close_hold) |f| {
                    test_close_hold = null;
                    f(s);
                };
                c.stream.shutdown();
            }
            s.check_now.set(io);
        }
        self.mutex.unlock(io);
        self.group.cancel(io);
        for (self.servers.items) |s| self.freeServer(s);
        self.servers.deinit(self.gpa);
        self.topology.deinit();
        for (self.sessions.pools) |*p| {
            for (p.list.items) |sess| self.gpa.destroy(sess);
            p.list.deinit(self.gpa);
        }
        self.sessions.deinit(self.gpa);
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    fn freeServer(self: *Client, s: *Server) void {
        for (s.pools.pools) |*p| {
            for (p.idle.items) |c| c.close();
            p.idle.deinit(self.gpa);
        }
        s.pools.deinit(self.gpa);
        self.gpa.free(s.address.text);
        self.gpa.destroy(s);
    }

    // -----------------------------------------------------------------------
    // Topology

    /// Under `mutex`: a `Server` and a monitor for every server of the
    /// topology that has none, retirement for those it dropped, checks it
    /// asked for, generations copied over.
    fn syncServers(self: *Client) !void {
        for (self.topology.servers.items) |*ts| {
            if (ts.context == null) {
                const s = try self.newServer(ts.description.address);
                ts.context = s;
                placement.concurrent(&self.group, self.io, .{ .executor = 0 }, monitor, .{s}) catch |err| {
                    log.warn("mongodb {s}: monitor not started: {t}", .{ s.address.text, err });
                };
                if (builtin.is_test) if (test_after_monitor_spawn) |f| {
                    test_after_monitor_spawn = null;
                    f(self.io);
                };
            }
            const s: *Server = @ptrCast(@alignCast(ts.context.?));
            s.generation.store(ts.generation, .release);
        }
        const removed = try self.topology.takeRemoved();
        defer self.gpa.free(removed);
        for (removed) |ctx| {
            const s: *Server = @ptrCast(@alignCast(ctx orelse continue));
            s.retired.store(true, .release);
            if (s.monitor_conn.load(.acquire)) |c| c.stream.shutdown();
            s.check_now.set(self.io);
        }
        const checks = try self.topology.takeCheckRequests();
        defer {
            for (checks) |c| self.gpa.free(c);
            self.gpa.free(checks);
        }
        for (checks) |address| if (self.topology.find(address)) |ts| {
            const s: *Server = @ptrCast(@alignCast(ts.context.?));
            s.check_now.set(self.io);
        };
        self.changed.broadcast(self.io);
    }

    fn newServer(self: *Client, address: []const u8) !*Server {
        const s = try self.gpa.create(Server);
        errdefer self.gpa.destroy(s);
        const text = try self.gpa.dupe(u8, address);
        errdefer self.gpa.free(text);
        var parsed = conn_mod.Address.parse(text);
        parsed.text = text;
        s.* = .{ .client = self, .address = parsed, .pools = try .init(self.gpa, self.io) };
        for (s.pools.pools, 0..) |*p, i| p.* = .{ .max = s.pools.share(self.max_connections, i) };
        try self.servers.append(self.gpa, s);
        return s;
    }

    /// Applies a description a monitor (or an error) produced.
    fn apply(self: *Client, d: *sdam.Description) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.topology.apply(d) catch |err| log.warn("mongodb: topology update: {t}", .{err});
        self.syncServers() catch |err| log.warn("mongodb: topology update: {t}", .{err});
    }

    /// The topology's error handling for an error a call met on `s`.
    fn handleError(self: *Client, s: *Server, e: sdam.AppError) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var err = e;
        err.address = s.address.text;
        _ = self.topology.handleError(err) catch return;
        self.syncServers() catch {};
    }

    /// The server writes and primary reads go to; waits for one up to the
    /// server selection timeout (or `deadline`, sooner), asking every
    /// monitor for a check meanwhile.
    fn select(self: *Client, io: std.Io, deadline: ?std.Io.Clock.Timestamp) !*Server {
        var limit = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = self.options.server_selection_timeout, .clock = .awake });
        if (deadline) |d| if (d.compare(.lt, limit)) {
            limit = d;
        };
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.topology.compatibilityError()) |msg| {
                log.warn("mongodb: {s}", .{msg});
                return error.IncompatibleServer;
            }
            if (self.topology.selectWritable()) |ts| return @ptrCast(@alignCast(ts.context.?));
            for (self.servers.items) |s| s.check_now.set(io);
            self.changed.waitTimeout(io, &self.mutex, .{ .deadline = limit }) catch |err| switch (err) {
                error.Timeout => return error.ServerSelectionTimeout,
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// The deployment's session timeout: null when it has no sessions.
    fn sessionTimeout(self: *Client) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.topology.logical_session_timeout_minutes;
    }

    /// Whether writes may be retried here: a replica set or a sharded
    /// cluster (a standalone has no retryable writes).
    fn retryableWritesSupported(self: *Client, s: *Server) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.topology.logical_session_timeout_minutes == null) return false;
        const ts = self.topology.find(s.address.text) orelse return false;
        return ts.description.type == .rs_primary or ts.description.type == .mongos;
    }

    /// The server is a mongos, or the topology Single (for $readPreference).
    fn topologyIs(self: *Client, t: sdam.TopologyType) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.topology.type == t;
    }

    // -----------------------------------------------------------------------
    // Monitoring (server-monitoring.md, polling)

    fn monitor(s: *Server) std.Io.Cancelable!void {
        const self = s.client;
        const io = self.io;
        var connection: ?*Connection = null;
        defer if (connection) |c| {
            s.monitor_conn.store(null, .release);
            c.close();
            if (builtin.is_test) if (test_monitor_closed) |f| f(s);
        };
        var known = false;
        while (!s.retired.load(.acquire)) {
            const started: std.Io.Clock.Timestamp = .now(io, .awake);
            var d = try self.check(s, &connection);
            // A server that was known gets one more try on a fresh
            // connection before it is called Unknown.
            if (d == null and known and !s.retired.load(.acquire)) d = try self.check(s, &connection);
            if (s.retired.load(.acquire)) return;
            const description = d orelse sdam.unknown(self.gpa, s.address.text, "server check failed", null) catch null;
            if (description) |desc| {
                known = desc.type != .unknown;
                self.apply(desc);
            }
            // Until the next check: the heartbeat, or a request for one now
            // (no sooner than 500 ms after the last).
            s.check_now.waitTimeout(io, .{ .duration = .{ .raw = self.options.heartbeat, .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Timeout => {},
            };
            s.check_now.reset();
            const next = started.addDuration(.{ .raw = .fromMilliseconds(500), .clock = .awake });
            if (std.Io.Clock.Timestamp.now(io, .awake).compare(.lt, next)) try next.wait(io);
        }
    }

    /// One check: a `hello` on the monitor's connection (opened, with the
    /// handshake, when there is none). Null when it failed.
    fn check(self: *Client, s: *Server, connection: *?*Connection) error{Canceled}!?*sdam.Description {
        const io = self.io;
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        if (connection.*) |c| {
            const reply = self.hello(c) catch |err| {
                s.monitor_conn.store(null, .release);
                c.close();
                connection.* = null;
                if (err == error.Canceled) return error.Canceled;
                log.debug("mongodb {s}: check failed: {t}", .{ s.address.text, err });
                return null;
            };
            const rtt: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).raw.nanoseconds));
            return sdam.describe(self.gpa, s.address.text, reply, rtt) catch null;
        }
        const c = Connection.open(self.gpa, io, s.address, self.settings, false) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            log.debug("mongodb {s}: check failed: {t}", .{ s.address.text, err });
            return null;
        };
        connection.* = c;
        s.monitor_conn.store(c, .release);
        // The handshake's reply is the first check's answer.
        const rtt: u64 = @intCast(@max(0, started.durationTo(.now(io, .awake)).raw.nanoseconds));
        const reply = wire.parse(c.read_buf.items) catch return null;
        return sdam.describe(self.gpa, s.address.text, reply.body, rtt) catch null;
    }

    fn hello(self: *Client, c: *Connection) !bson.Document {
        _ = self;
        var m = try c.begin();
        try m.b.append(if (c.hello_ok) "hello" else "isMaster", .{ .int32 = 1 });
        try m.b.append("$db", .{ .string = "admin" });
        try m.endBody();
        return (try c.roundTrip(&m)).body;
    }

    // -----------------------------------------------------------------------
    // Pools

    /// A connection to `s` from the calling executor's pool, opened when
    /// none is idle and the pool has room; waits up to `acquire_timeout`.
    fn acquire(self: *Client, s: *Server, io: std.Io, deadline: ?std.Io.Clock.Timestamp) !*Connection {
        const p = s.pool(io);
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        var limit = started.addDuration(.{ .raw = self.options.acquire_timeout, .clock = .awake });
        if (deadline) |d| if (d.compare(.lt, limit)) {
            limit = d;
        };
        try p.mutex.lock(io);
        var waited = false;
        while (true) {
            while (p.idle.pop()) |c| {
                if (self.stale(s, c, io)) {
                    p.total -= 1;
                    p.mutex.unlock(io);
                    self.observer.connections(-1, 0);
                    c.close();
                    try p.mutex.lock(io);
                    continue;
                }
                p.mutex.unlock(io);
                self.observer.connections(-1, 1);
                if (waited) self.observer.waiting(-1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                return c;
            }
            if (p.max == 0 or p.total < p.max) {
                p.total += 1;
                p.mutex.unlock(io);
                if (waited) self.observer.waiting(-1);
                const generation = s.generation.load(.acquire);
                const c = Connection.open(self.gpa, io, s.address, self.settings, true) catch |err| {
                    p.mutex.lockUncancelable(io);
                    p.total -= 1;
                    p.cond.signal(io);
                    p.mutex.unlock(io);
                    return err;
                };
                c.generation = generation;
                c.server = s;
                self.observer.connections(0, 1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                return c;
            }
            if (!waited) {
                waited = true;
                self.observer.waiting(1);
            }
            p.cond.waitTimeout(io, &p.mutex, .{ .deadline = limit }) catch |err| {
                // `waitTimeout` returns with the mutex held, either way.
                p.mutex.unlock(io);
                self.observer.waiting(-1);
                return switch (err) {
                    error.Timeout => error.PoolTimeout,
                    error.Canceled => error.Canceled,
                };
            };
        }
    }

    /// Closes the idle pooled connections of every server and executor;
    /// calls open new ones as they need them, and the monitors reconnect
    /// on their own. The Lambda adapter calls it after a long freeze, when
    /// a NAT gateway may have dropped them without telling either end.
    pub fn closeIdle(self: *Client) void {
        const io = self.io;
        self.mutex.lockUncancelable(io);
        const servers = self.gpa.dupe(*Server, self.servers.items) catch {
            self.mutex.unlock(io);
            return;
        };
        self.mutex.unlock(io);
        defer self.gpa.free(servers);
        for (servers) |s| for (s.pools.pools) |*p| {
            while (true) {
                p.mutex.lockUncancelable(io);
                const c = p.idle.pop() orelse {
                    p.mutex.unlock(io);
                    break;
                };
                p.total -= 1;
                p.cond.signal(io);
                p.mutex.unlock(io);
                self.observer.connections(-1, 0);
                c.close();
            }
        };
    }

    fn stale(self: *Client, s: *Server, c: *Connection, io: std.Io) bool {
        if (c.generation != s.generation.load(.acquire) or s.retired.load(.acquire)) return true;
        if (self.options.idle_timeout) |max| {
            if (c.last_used.durationTo(.now(io, .awake)).raw.nanoseconds > max.nanoseconds) return true;
        }
        return false;
    }

    /// Gives `c` back to its pool, or closes it when it is broken, stale,
    /// or the client is closing.
    fn release(self: *Client, s: *Server, c: *Connection, io: std.Io) void {
        const p = s.pool(io);
        const keep = !c.broken and !self.closing.load(.acquire) and !self.stale(s, c, io);
        p.mutex.lockUncancelable(io);
        if (keep) {
            p.idle.append(self.gpa, c) catch {
                p.total -= 1;
                p.cond.signal(io);
                p.mutex.unlock(io);
                self.observer.connections(0, -1);
                c.close();
                return;
            };
            p.cond.signal(io);
            p.mutex.unlock(io);
            self.observer.connections(1, -1);
            return;
        }
        p.total -= 1;
        p.cond.signal(io);
        p.mutex.unlock(io);
        self.observer.connections(0, -1);
        c.close();
    }

    // -----------------------------------------------------------------------
    // Sessions (driver-sessions.md, implicit)

    fn takeSession(self: *Client, io: std.Io, timeout_minutes: i64) !*Session {
        const p = self.sessions.get(io);
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        while (p.list.pop()) |sess| {
            if (!self.expiring(sess, io, timeout_minutes)) return sess;
            self.gpa.destroy(sess);
        }
        var id: [16]u8 = undefined;
        io.random(&id);
        // UUID version 4, variant 1.
        id[6] = (id[6] & 0x0f) | 0x40;
        id[8] = (id[8] & 0x3f) | 0x80;
        const sess = try self.gpa.create(Session);
        sess.* = .{ .id = id, .last_used = .now(io, .awake) };
        return sess;
    }

    /// Less than a minute of its timeout left: not worth reusing.
    fn expiring(self: *Client, sess: *const Session, io: std.Io, timeout_minutes: i64) bool {
        _ = self;
        const age = sess.last_used.durationTo(.now(io, .awake)).raw.nanoseconds;
        const limit = @as(i96, timeout_minutes - 1) * std.time.ns_per_min;
        return age >= limit;
    }

    /// Gives a server session back to the client's pool (a cursor's, when
    /// it ends); one that saw a network error is dropped instead.
    fn giveSession(self: *Client, sess: *Session, io: std.Io) void {
        if (sess.dirty) {
            self.gpa.destroy(sess);
            return;
        }
        sess.last_used = .now(io, .awake);
        const p = self.sessions.get(io);
        p.mutex.lockUncancelable(io);
        defer p.mutex.unlock(io);
        p.list.append(self.gpa, sess) catch self.gpa.destroy(sess);
    }

    /// Tells the primary to drop the client's pooled sessions (best
    /// effort, a second at most), as `close` should.
    fn endSessions(self: *Client) void {
        const io = self.io;
        var ids: std.ArrayList([16]u8) = .empty;
        defer ids.deinit(self.gpa);
        for (self.sessions.pools) |*p| for (p.list.items) |sess| ids.append(self.gpa, sess.id) catch {};
        if (ids.items.len == 0) return;
        const End = struct {
            fn run(client: *Client, list: []const [16]u8) !void {
                const server = try client.selectNow() orelse return;
                const c = try client.acquire(server, client.io, null);
                defer client.release(server, c, client.io);
                var m = try c.begin();
                try m.b.beginArray("endSessions");
                for (list[0..@min(list.len, 10_000)]) |id| {
                    try m.b.beginDocument("");
                    try m.b.append("id", .{ .binary = .{ .subtype = .uuid, .data = &id } });
                    try m.b.end();
                }
                try m.b.end();
                try m.b.append("$db", .{ .string = "admin" });
                try m.endBody();
                _ = try c.roundTrip(&m);
            }
        };
        const deadline: dusty.Deadline = .init(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
        deadline.run(End.run, .{ self, ids.items }) catch |err| log.debug("mongodb: endSessions: {t}", .{err});
    }

    /// The writable server if one is known now, without waiting.
    fn selectNow(self: *Client) !?*Server {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const ts = self.topology.selectWritable() orelse return null;
        return @ptrCast(@alignCast(ts.context.?));
    }

    // -----------------------------------------------------------------------
    // Running commands

    /// Sends the command `ctx` builds and returns what `ctx.result` reads
    /// from the reply, with everything the specs ask around it: server
    /// selection, a pooled connection, an implicit session, a retry,
    /// `maxTimeMS`, error mapping (`internal.fail`), metrics and a span.
    ///
    /// `ctx` is a pointer to a struct with
    ///     fn body(ctx, b: *bson.Builder, x: *Exchange) !void       the command's fields
    ///     fn result(ctx, x: *Exchange, reply: bson.Document) !R
    /// and optionally
    ///     fn sequences(ctx, m: *wire.Message, x: *Exchange) !void  kind-1 sections
    fn execute(self: *Client, c: *const Context, op: Operation, ctx: anytype) Error!@typeInfo(@TypeOf(ctx)).pointer.child.Result {
        const Ctx = @typeInfo(@TypeOf(ctx)).pointer.child;
        const timeout = internal.callTimeout(op.options.timeout, self.options.timeout);
        const deadline: ?std.Io.Clock.Timestamp = if (timeout) |t| .fromNow(c.io, .{ .raw = t, .clock = .awake }) else null;
        const call = self.observer.start(c);
        const result = internal.guarded(c, &self.guard, self.errors, false, deadline, boundedAttempt(Ctx), .{ self, c, op, ctx, timeout, deadline });
        if (c.request) |req| {
            call.end(req, op.name, op.collection, if (result) |_| null else |e| e);
        } else {
            var plain: shared.Ctx = .{ .io = c.io, .arena = c.arena };
            call.end(&plain, op.name, op.collection, if (result) |_| null else |e| e);
        }
        return result;
    }

    /// One run of the command loop under the call's timeout.
    fn boundedAttempt(comptime Ctx: type) fn (*Client, *const Context, Operation, *Ctx, ?std.Io.Duration, ?std.Io.Clock.Timestamp) Error!Ctx.Result {
        return struct {
            fn run(self: *Client, c: *const Context, op: Operation, ctx: *Ctx, timeout: ?std.Io.Duration, deadline: ?std.Io.Clock.Timestamp) Error!Ctx.Result {
                return if (timeout) |t| bounded: {
                    const d: dusty.Deadline = .init(c.io, .{ .duration = .{ .raw = t, .clock = .awake } });
                    break :bounded d.run(Run(Ctx).attempt, .{ self, c, op, ctx, deadline }) catch |err| switch (err) {
                        error.Timeout => c.fail(self.errors, .{ .system = .mongodb, .class = .timeout, .message = "the call ran past its timeout", .table = op.collection }),
                        else => |e| e,
                    };
                } else Run(Ctx).attempt(self, c, op, ctx, deadline);
            }
        }.run;
    }

    fn Run(comptime Ctx: type) type {
        return struct {
            fn attempt(self: *Client, c: *const Context, op: Operation, ctx: *Ctx, deadline: ?std.Io.Clock.Timestamp) Error!Ctx.Result {
                const io = c.io;
                var x: Exchange = .{ .client = self, .op = op, .server = op.server orelse undefined };
                if (op.session and op.lsid == null) if (self.sessionTimeout()) |minutes| {
                    x.session = try self.takeSession(io, minutes);
                };
                // The cursor takes the session when it stays open.
                defer if (x.session) |sess| if (!x.keep_session) self.giveSession(sess, io);

                var tries: u8 = 0;
                while (true) : (tries += 1) {
                    const retry_allowed = tries == 0 and switch (op.retry) {
                        .none => false,
                        .read => self.options.retry_reads,
                        .write => self.options.retry_writes,
                    };
                    if (op.server == null) x.server = self.select(io, deadline) catch |err| return switch (err) {
                        error.Canceled => error.Canceled,
                        // The call's own timeout came first: a 504, as when
                        // the deadline cancels it anywhere else.
                        else => if (err == error.ServerSelectionTimeout and past(io, deadline))
                            c.fail(self.errors, .{ .system = .mongodb, .class = .timeout, .message = "the call ran past its timeout waiting for a server", .table = op.collection })
                        else
                            c.fail(self.errors, .{ .system = .mongodb, .class = .unavailable, .message = switch (err) {
                                error.IncompatibleServer => "the server's wire version is outside the client's",
                                else => "no server to send the command to (server selection timed out)",
                            }, .table = op.collection }),
                    };
                    const server = x.server;
                    const connection = self.acquire(server, io, deadline) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        error.PoolTimeout => return c.fail(self.errors, .{ .system = .mongodb, .class = if (past(io, deadline)) .timeout else .unavailable, .code = "pool_timeout", .message = "no pooled connection free in time", .table = op.collection }),
                        else => {
                            // A failed handshake or authentication: the
                            // server is marked Unknown and its pools cleared.
                            const auth = err == error.AuthenticationFailed;
                            self.handleError(server, .{ .address = "", .when = .before_handshake, .kind = if (auth) .command else .network, .message = @errorName(err) });
                            if (retry_allowed and !auth) continue;
                            return c.fail(self.errors, .{ .system = .mongodb, .class = .unavailable, .message = if (auth) "authentication failed" else "could not connect to the server", .table = op.collection });
                        },
                    };
                    x.connection = connection;
                    // Retryable writes number the statement in the session.
                    x.txn_number = null;
                    if (op.retry == .write and self.options.retry_writes and x.session != null and self.retryableWritesSupported(server)) {
                        if (tries == 0) x.session.?.txn_number += 1;
                        x.txn_number = x.session.?.txn_number;
                    }
                    const reply = self.send(c, &x, ctx, deadline) catch |err| {
                        // Read before the release: a broken connection is
                        // closed and freed there.
                        const generation = connection.generation;
                        const max_wire_version = connection.max_wire_version;
                        self.release(server, connection, io);
                        switch (err) {
                            error.Canceled => {
                                if (x.session) |sess| sess.dirty = true;
                                return error.Canceled;
                            },
                            error.OutOfMemory => return error.OutOfMemory,
                            error.DocumentTooLarge => return c.fail(self.errors, .{ .system = .mongodb, .class = .other, .message = "a document is larger than the server's maxBsonObjectSize", .table = op.collection }),
                            error.InvalidDocument => return c.fail(self.errors, .{ .system = .mongodb, .class = .other, .message = "a value could not be encoded as BSON (a key with a NUL byte, text that is not UTF-8)", .table = op.collection }),
                            else => {},
                        }
                        // The exchange broke off: a network error (or a
                        // reply we could not read).
                        if (x.session) |sess| sess.dirty = true;
                        self.handleError(server, .{ .address = "", .generation = generation, .max_wire_version = max_wire_version, .kind = .network, .message = @errorName(err) });
                        if (retry_allowed and (op.retry == .read or x.txn_number != null)) continue;
                        return c.fail(self.errors, .{ .system = .mongodb, .class = .unavailable, .message = "the connection to the server failed mid-command", .table = op.collection });
                    };
                    if (conn_mod.replyError(reply.body)) |se| {
                        if (se.kind != .write) self.handleError(server, .{
                            .address = "",
                            .generation = connection.generation,
                            .max_wire_version = connection.max_wire_version,
                            .kind = .command,
                            .response = reply.body,
                        });
                        const retryable = switch (op.retry) {
                            .none => false,
                            .read => se.kind == .command and isRetryableRead(se),
                            .write => x.txn_number != null and se.kind != .write and isRetryableWrite(se, connection.max_wire_version),
                        };
                        if (retry_allowed and retryable) {
                            self.release(server, connection, io);
                            continue;
                        }
                        if (!accepts(ctx, se)) {
                            var code_buf: [24]u8 = undefined;
                            // Copied by `fail` before the connection is reused.
                            const err = c.fail(self.errors, .{
                                .system = .mongodb,
                                .class = classify(se),
                                .code = if (se.code) |code| std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "" else "",
                                .message = se.message,
                                .table = op.collection,
                            });
                            self.release(server, connection, io);
                            return err;
                        }
                    }
                    const out = ctx.result(&x, reply.body) catch |err| {
                        self.release(server, connection, io);
                        return switch (@as(anyerror, err)) {
                            error.OutOfMemory => error.OutOfMemory,
                            error.Canceled => error.Canceled,
                            error.MissingField => c.fail(self.errors, .{ .system = .mongodb, .class = .other, .message = "a document lacks a field the struct has no default for", .table = op.collection }),
                            else => c.fail(self.errors, .{ .system = .mongodb, .class = .other, .message = "a document does not fit the struct it is read into", .table = op.collection }),
                        };
                    };
                    self.release(server, connection, io);
                    return out;
                }
            }
        };
    }

    /// Builds the command in `x.connection` and sends it.
    fn send(self: *Client, c: *const Context, x: *Exchange, ctx: anytype, deadline: ?std.Io.Clock.Timestamp) !wire.Reply {
        const connection = x.connection;
        var m = try connection.begin();
        const b = m.b;
        ctx.body(b, x) catch |err| return mapBuildError(err);
        const op = x.op;
        try b.append("$db", .{ .string = op.database });
        if (op.lsid) |id| {
            try appendLsid(b, id);
        } else if (x.session) |sess| try appendLsid(b, sess.id);
        if (x.txn_number) |n| try b.append("txnNumber", .{ .int64 = n });
        if (op.kind == .write) {
            if (self.write_concern) |wc| try b.append("writeConcern", .{ .document = .{ .bytes = wc } });
        } else if (op.kind == .read) {
            if (self.read_concern) |rc| try b.append("readConcern", .{ .document = .{ .bytes = rc } });
            // A direct connection may be to a secondary: let it answer.
            if (self.direct and self.topologyIs(.single)) {
                try b.beginDocument("$readPreference");
                try b.append("mode", .{ .string = "primaryPreferred" });
                try b.end();
            }
        }
        if (op.max_time) if (deadline) |d| {
            const left = std.Io.Clock.Timestamp.now(c.io, .awake).durationTo(d).raw.toMilliseconds();
            try b.append("maxTimeMS", .{ .int64 = @max(left, 1) });
        };
        try m.endBody();
        if (m.body().bytes.len > connection.max_bson_object_size + 16 * 1024) return error.DocumentTooLarge;
        if (@hasDecl(@typeInfo(@TypeOf(ctx)).pointer.child, "sequences")) ctx.sequences(&m, x) catch |err| return mapBuildError(err);
        return connection.roundTrip(&m);
    }
};

/// `deadline` is set and has passed.
fn past(io: std.Io, deadline: ?std.Io.Clock.Timestamp) bool {
    const d = deadline orelse return false;
    return !std.Io.Clock.Timestamp.now(io, .awake).compare(.lt, d);
}

fn mapBuildError(err: anyerror) error{ OutOfMemory, DocumentTooLarge, InvalidDocument } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DocumentTooLarge, error.MessageTooLarge => error.DocumentTooLarge,
        else => error.InvalidDocument,
    };
}

fn appendLsid(b: *bson.Builder, id: [16]u8) !void {
    try b.beginDocument("lsid");
    try b.append("id", .{ .binary = .{ .subtype = .uuid, .data = &id } });
    try b.end();
}

/// `Client.execute`, for collection.zig: kept off `Client`'s public
/// methods, since `anole.mongodb.Client` is API and this is the machinery
/// under it.
pub fn execute(client: *Client, c: *const Context, op: Operation, ctx: anytype) Error!@typeInfo(@TypeOf(ctx)).pointer.child.Result {
    return client.execute(c, op, ctx);
}

/// `Client.giveSession`, for a cursor that ends (collection.zig).
pub fn giveSession(client: *Client, sess: *Session, io: std.Io) void {
    client.giveSession(sess, io);
}

/// A call's context with its type erased: the request (or `anole.db.Ctx`)
/// a call was made with, so cursors can keep it and the command loop is
/// compiled once.
pub const Context = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    any: *anyopaque,
    record: *const fn (any: *anyopaque, map: shared.ErrorMap, detail: shared.ErrorDetail) shared.Error,
    /// For spans.
    request: ?*const dusty.Request,
    last: *const fn (any: *anyopaque) ?shared.ErrorDetail,

    /// The last error recorded on the context it stands for.
    pub fn lastDetail(self: *const Context) ?shared.ErrorDetail {
        return self.last(self.any);
    }

    /// `internal.fail` on the context it stands for.
    pub fn fail(self: *const Context, map: shared.ErrorMap, detail: shared.ErrorDetail) shared.Error {
        return self.record(self.any, map, detail);
    }
};

/// `c` (a `*anole.Request` or a `*anole.db.Ctx`) as a `Context`.
pub fn erase(c: anytype) Context {
    const C = @TypeOf(c);
    if (C == *Context or C == *const Context) return c.*;
    const R = struct {
        fn record(any: *anyopaque, map: shared.ErrorMap, detail: shared.ErrorDetail) shared.Error {
            return internal.fail(@as(C, @ptrCast(@alignCast(any))), map, detail);
        }
        fn last(any: *anyopaque) ?shared.ErrorDetail {
            return internal.lastError(@as(C, @ptrCast(@alignCast(any))));
        }
    };
    return .{ .io = c.io, .arena = c.arena, .any = @ptrCast(@constCast(c)), .record = R.record, .last = R.last, .request = internal.requestOf(c) };
}

/// What every call can fail with: the shared errors (`anole.db.Error`),
/// a cancel, memory.
pub const Error = shared.Error || error{ Canceled, OutOfMemory };

/// A command as `execute` runs it.
pub const Operation = struct {
    /// The command's name, for spans and metrics ("find", "insert").
    name: []const u8,
    database: []const u8,
    /// The collection, for spans and error details.
    collection: ?[]const u8 = null,
    kind: Kind = .read,
    retry: Retry = .none,
    /// Send `maxTimeMS` when the call has a timeout (not for getMore).
    max_time: bool = true,
    /// Attach an implicit session.
    session: bool = true,
    /// Use this session id (a cursor's getMore and killCursors).
    lsid: ?[16]u8 = null,
    /// Send to this server, without selection (a cursor's).
    server: ?*Server = null,
    options: shared.QueryOptions = .{},

    pub const Kind = enum { read, write, command };
    pub const Retry = enum { none, read, write };
};

/// One command in flight, for the builder and reader of `execute`.
pub const Exchange = struct {
    client: *Client,
    op: Operation,
    server: *Server,
    connection: *Connection = undefined,
    session: ?*Session = null,
    txn_number: ?i64 = null,
    /// Set by `result` when a cursor stays open and keeps the session.
    keep_session: bool = false,
};

/// Whether the command's reader takes this server error as an answer
/// (a `drop` of a collection that is not there, say) rather than a failure.
fn accepts(ctx: anytype, se: conn_mod.ServerError) bool {
    const Ctx = @typeInfo(@TypeOf(ctx)).pointer.child;
    if (comptime @hasDecl(Ctx, "accepts")) return ctx.accepts(se);
    return false;
}

/// A server error's class (`anole.db.Class`), from its code.
pub fn classify(se: conn_mod.ServerError) shared.Class {
    const code = se.code orelse return if (sdam.isStateChange(null, se.message)) .unavailable else .other;
    return switch (code) {
        // DuplicateKey (and its legacy forms).
        11000, 11001, 12582 => .unique,
        // DocumentValidationFailure.
        121 => .check,
        // MaxTimeMSExpired, ExceededTimeLimit, WriteConcernFailed (wtimeout).
        50, 262, 64 => .timeout,
        // WriteConflict, NoSuchTransaction.
        112, 251 => .serialization,
        // Unauthorized, AuthenticationFailed: the client's configuration.
        13, 18 => .unavailable,
        else => if (sdam.isStateChange(code, se.message)) .unavailable else .other,
    };
}

const retryable_codes = [_]i64{ 11600, 11602, 10107, 13435, 13436, 189, 91, 7, 6, 89, 9001, 262 };

fn isRetryableWrite(se: conn_mod.ServerError, max_wire_version: i32) bool {
    // 4.4 and later label what may be retried.
    if (max_wire_version >= 9) return se.hasLabel("RetryableWriteError");
    const code = se.code orelse return false;
    return std.mem.indexOfScalar(i64, &retryable_codes, code) != null;
}

fn isRetryableRead(se: conn_mod.ServerError) bool {
    const code = se.code orelse return false;
    return code == 134 or std.mem.indexOfScalar(i64, &retryable_codes, code) != null;
}

const testing = std.testing;

test "classify: codes to classes" {
    const doc: bson.Document = .empty;
    const Case = struct { ?i64, []const u8, shared.Class };
    for ([_]Case{
        .{ 11000, "E11000 duplicate key", .unique },
        .{ 121, "Document failed validation", .check },
        .{ 50, "operation exceeded time limit", .timeout },
        .{ 10107, "not primary", .unavailable },
        .{ 91, "shutdown in progress", .unavailable },
        .{ 2, "bad value", .other },
        .{ null, "not master", .unavailable },
        .{ null, "something", .other },
    }) |case| try testing.expectEqual(case[2], classify(.{ .code = case[0], .message = case[1], .reply = doc }));
}
