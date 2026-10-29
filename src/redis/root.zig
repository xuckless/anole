//! Redis and Valkey (`-Dredis`): `anole.db`'s calling convention on a
//! client of Anole's own. hiredis (redis/hiredis, BSD-3-Clause) parses the
//! replies; the commands are written as RESP here, and the socket is an
//! `anole.net.ClientStream` (plain or TLS on BoringSSL), so waiting for the
//! server suspends the calling coroutine, never its thread.
//!
//!     const App = struct { redis: *anole.redis.Client };
//!     var state: App = undefined;
//!     var app = try anole.Server(App).init(gpa, .{}, &state);
//!     state.redis = try app.redis(.{}); // REDIS_URL, else redis://127.0.0.1:6379
//!
//!     fn hit(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         const hits = try app.redis.incr(req, "hits");
//!         try res.json(.{ .hits = hits });
//!     }
//!
//! See `anole.db` for the contract every connector keeps (the request
//! first, `with`, errors and `lastError`, cancellation). What is Redis's:
//!
//! - Commands: `command(c, args)` sends any command and returns its
//!   `Reply`; `one(T, c, args)`, `optional` and `all` read the reply into a
//!   `T` (nil, or a hash without fields for a struct: `error.NotFound`, a
//!   404); `pipeline(c, commands)` sends several in one round trip. `args`
//!   is a tuple: `.{ "SET", key, value, "EX", 60 }`. Strings go as they
//!   are, numbers in decimal, `bool` as 1 or 0, enums by their names, null
//!   not at all, slices and nested tuples item by item, and a struct as its
//!   field names and values (`HSET`, `XADD`). A `[]const []const u8` works
//!   too.
//! - Helpers for what most apps use: `get`, `set` (with a TTL, NX or XX),
//!   `del`, `incr`, `incrBy`, `expire`, hashes (`hget`, `hset` from a
//!   struct, `hgetAll` into one, `hdel`, `hincrBy`), lists (`lpush`,
//!   `rpush`, `lrange`), sets (`sadd`, `srem`, `smembers`, `sismember`),
//!   sorted sets (`zadd`, `zincrBy`, `zscore`, `zrem`, `zrange`,
//!   `zrangeWithScores`) and `publish`. Everything else goes through
//!   `command` and the typed calls.
//! - Replies into types: integers from integer replies and from numeric
//!   strings, floats likewise, `bool` from 1/0 and OK, `[]const u8` from
//!   strings (numbers formatted), enums from their names, slices from
//!   arrays, a struct from a hash (`HGETALL`, field by name: a missing one
//!   keeps its default, else `error.MissingColumn`), optionals for nil.
//!   Strings are copied into the context's arena.
//! - Connections: the URL (`Options.url`, else `REDIS_URL`) as go-redis and
//!   redis-py read it: `redis://user:password@host:6379/0` (AUTH with the
//!   ACL user, or the password alone; the path is the database for
//!   SELECT), `rediss://` for TLS, `unix:///run/redis.sock?db=0`. A pool
//!   per executor; a connection opens when a call first needs one. RESP2,
//!   which every Redis and Valkey speaks.
//! - Pipelines and transactions: MULTI ... EXEC can go in one `pipeline`;
//!   WATCH, and anything else that must stay on one connection across
//!   round trips, takes one with `acquire`. A connection that a call leaves
//!   inside MULTI or WATCH, on another database (SELECT) or subscribed is
//!   closed instead of going back to its pool.
//! - Pub/sub: `subscribe` and `psubscribe` open a connection of their own,
//!   outside the pools; `next` waits for the next message, and returns
//!   null once the server starts to drain (or after `stop`).
//! - Errors: a server error reply (`WRONGTYPE`, `ERR ...`, a script's) is
//!   `error.Database` (500), with the message in `lastError`; `LOADING`,
//!   `MASTERDOWN`, `BUSY`, `READONLY`, `OOM`, `TRYAGAIN`, `CLUSTERDOWN`,
//!   `NOREPLICAS`, `MISCONF`, a refused login and a server that cannot be
//!   reached are `ServiceUnavailable` (503); a call past
//!   `with(.{ .timeout })` is `GatewayTimeout` (504). `Options.errors`
//!   moves them. Only a pipeline's own replies are checked: errors inside
//!   an EXEC reply come back as `.err` replies.
//! - Caching: `with(.{ .coalesce = true })` and `with(.{ .cache = .{ .ttl,
//!   .tag } })` (`anole.db.QueryCache`) share or keep the reads made with
//!   `one`, `optional` and `all` and the read helpers (`get`, `hget`,
//!   `hgetAll`, `lrange`, `smembers`, `sismember`, `zscore`, `zrange`,
//!   `zrangeWithScores`), for read commands only (`GET`, `MGET`,
//!   `HGETALL`, `ZRANGE` and the like; `read_commands`). Other commands,
//!   `command`, pipelines, pub/sub and calls on an `acquire`d connection
//!   run as they are. Drop kept replies with `cache.invalidate(.{ .tag })`,
//!   or `cache.invalidateQuery("GET", .{key})` (the name, then the rest of
//!   the command). For cache-aside, `.keep_empty = false` keeps no nil (nor
//!   an empty list or set), so a key filled after a miss is read at once;
//!   `anole.db.lastSource(req)` says whether a call was a hit.
//! - Cancellation: a call canceled in flight (the request's deadline, an
//!   HTTP/2 reset, `with(.{ .timeout })`) closes its connection, whose
//!   reply may still be on its way.
//!
//! Outside an app: `Client.init(gpa, io, .{})` and `deinit`.
const std = @import("std");
const features = @import("build_options");
const dusty = @import("dusty");
const safety = @import("anole_safety");
const hiredis = @import("anole_hiredis_c");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");
const resilience = @import("../resilience/root.zig");
const client_stream = @import("../net/client_stream.zig");
const ClientStream = client_stream.ClientStream;
const PubSubHub = @import("../watch/redis.zig").PubSubHub;

const builtin = @import("builtin");

const has_tls = features.tls == .boringssl;
const log = @import("../errors.zig").log;
const Duration = std.Io.Duration;

/// A reply, as the server sent it. Strings point into the arena of the
/// call's context.
pub const Reply = union(enum) {
    nil,
    status: []const u8,
    /// A server error ("ERR ...", "WRONGTYPE ..."). A call fails on one of
    /// its own replies; this only appears inside another reply (EXEC's).
    err: []const u8,
    int: i64,
    string: []const u8,
    double: f64,
    boolean: bool,
    array: []Reply,
    /// RESP3 maps, as key, value, key, value...
    map: []Reply,

    /// The string of a bulk-string or status reply; null for nil.
    pub fn text(self: Reply) ?[]const u8 {
        return switch (self) {
            .string, .status => |s| s,
            else => null,
        };
    }
};

/// What every call fails with: `anole.db.Error`, a cancel, or memory.
pub const Error = db.Error || error{ Canceled, OutOfMemory };

/// `app.redis(options)` and `Client.init`. Every field has a default, so
/// `.{}` connects from `REDIS_URL`.
pub const Options = struct {
    /// A `redis://`, `rediss://` (TLS) or `unix://` URL. Null: `REDIS_URL`,
    /// else `redis://127.0.0.1:6379`. Parameters: `db` (or the path), and
    /// redis-py's `ssl_ca_certs`, `ssl_certfile`, `ssl_keyfile` and
    /// `ssl_cert_reqs=none` for `rediss://`.
    url: ?[]const u8 = null,
    /// The server's name in metrics (`db` label), spans, `/readyz` and
    /// logs. Must outlive the client. Null: "redis".
    name: ?[]const u8 = null,
    /// Connections in all, split between the executors (at least one
    /// each). Null: ten per executor (go-redis's default per CPU).
    max_connections: ?u32 = null,
    /// How long a call waits for one of its executor's connections when
    /// all are busy; then `ServiceUnavailable`.
    acquire_timeout: Duration = .fromSeconds(5),
    /// How long opening a connection may take (TCP, TLS, AUTH and
    /// SELECT). Null: no limit.
    connect_timeout: ?Duration = .fromSeconds(10),
    /// A connection idle this long is closed rather than reused (a proxy
    /// or a NAT may have dropped it). Null: no limit.
    idle_timeout: ?Duration = .fromSeconds(5 * 60),
    /// What each class of error becomes (`anole.db.ErrorMap`).
    errors: db.ErrorMap = .{},
    /// Certificates for `rediss://`, beyond what the URL names.
    tls: db.Tls = .{},
    /// Open one connection per executor before serving, and fail the
    /// start if that fails. Off: connections open as calls need them, and
    /// a server that is down shows in `/readyz` and as 503s.
    connect_at_start: bool = false,
    /// What `/readyz` waits for the server's PONG.
    ping_timeout: Duration = .fromSeconds(2),
    /// Fails calls fast (503, `lastError` code "circuit_open") after the
    /// server could not be reached repeatedly; null: never.
    breaker: ?resilience.Breaker.Options = .{},
    /// What `with(.{ .retry = true })` retries with.
    retry: resilience.Retry = .{ .attempts = 3, .backoff = .{ .base = .fromMilliseconds(50), .max = .fromSeconds(1) } },
    /// A bound on every call that has no `QueryOptions.timeout` of its own,
    /// in a request or not; past it the call is canceled and fails with
    /// `error.GatewayTimeout`. A request's deadline applies too, whichever
    /// comes first. Null: none. Calls on a connection from `acquire`
    /// (blocking commands, subscriptions) are not bounded by it.
    timeout: ?Duration = .fromSeconds(30),
    /// Where `REDIS_URL` comes from; null: the process's environment
    /// (`app.redis` passes `ServerOptions.process`'s).
    environ: ?std.process.Environ = null,
    /// The bounds of the replies kept for reads with `.cache`
    /// (`anole.db.QueryOptions`).
    cache: db.CacheOptions = .{},

    /// `Options.tls`.
    pub const Tls = db.Tls;
};

/// A connection's settings: the URL, the environment and `Options`,
/// resolved. Strings point into the arena `resolve` was given.
const Settings = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    unix_path: ?[]const u8 = null,
    /// AUTH's ACL user; null for the default user.
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// SELECT's database.
    database: u32 = 0,
    tls: bool = false,
    ca_file: ?[]const u8 = null,
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    verify: bool = true,

    /// Reads `opts.url`, else `REDIS_URL`. A URL that cannot be used is
    /// logged, with the reason, and fails with `error.InvalidDatabaseUrl`.
    pub fn resolve(arena: std.mem.Allocator, opts: Options) !Settings {
        var why: ?[]const u8 = null;
        return parse(arena, opts, &why) catch |err| {
            if (why) |text| log.err("redis: {s}", .{text});
            return err;
        };
    }

    fn refuse(why: *?[]const u8, arena: std.mem.Allocator, text: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidDatabaseUrl} {
        why.* = std.fmt.allocPrint(arena, "cannot use the URL {f}: " ++ fmt, .{db.redacted(text)} ++ args) catch null;
        return error.InvalidDatabaseUrl;
    }

    fn parse(arena: std.mem.Allocator, opts: Options, why: *?[]const u8) !Settings {
        var s: Settings = .{};
        const text = opts.url orelse db.env(opts.environ, "REDIS_URL") orelse return s;
        const url = db.Url.parse(arena, text) catch |err| return refuse(why, arena, text, "{t}", .{err});
        const unix = std.mem.eql(u8, url.scheme, "unix");
        if (std.mem.eql(u8, url.scheme, "rediss")) {
            s.tls = true;
        } else if (!unix and !std.mem.eql(u8, url.scheme, "redis")) {
            return refuse(why, arena, text, "the scheme is \"{s}\", not redis, rediss or unix", .{url.scheme});
        }
        if (url.hosts.len > 1) return refuse(why, arena, text, "it names {d} hosts; Redis Cluster and Sentinel are not supported", .{url.hosts.len});
        if (unix) {
            if (url.path.len == 0) return refuse(why, arena, text, "no socket path (unix:///path/to/redis.sock)", .{});
            s.unix_path = url.path;
            s.host = "localhost";
        } else {
            if (url.hosts.len > 0) {
                if (url.hosts[0].name.len > 0) s.host = url.hosts[0].name;
                if (url.hosts[0].port) |p| s.port = p;
            }
            const path = url.database();
            if (path.len > 0) s.database = std.fmt.parseInt(u32, path, 10) catch return refuse(why, arena, text, "the path \"/{s}\" is not a database number", .{path});
        }
        if (url.username) |u| if (u.len > 0) {
            s.username = u;
        };
        if (url.password) |p| if (p.len > 0) {
            s.password = p;
        };
        for (url.params) |p| {
            const name = p.name;
            if (std.mem.eql(u8, name, "db")) {
                s.database = std.fmt.parseInt(u32, p.value, 10) catch return refuse(why, arena, text, "db \"{s}\" is not a database number", .{p.value});
            } else if (std.mem.eql(u8, name, "password")) {
                s.password = p.value;
            } else if (std.mem.startsWith(u8, name, "ssl_") and !s.tls) {
                return refuse(why, arena, text, "{s} needs a rediss:// URL", .{name});
            } else if (std.mem.eql(u8, name, "ssl_ca_certs")) {
                s.ca_file = p.value;
            } else if (std.mem.eql(u8, name, "ssl_certfile")) {
                s.cert_file = p.value;
            } else if (std.mem.eql(u8, name, "ssl_keyfile")) {
                s.key_file = p.value;
            } else if (std.mem.eql(u8, name, "ssl_cert_reqs")) {
                if (std.ascii.eqlIgnoreCase(p.value, "none")) {
                    s.verify = false;
                } else if (!std.ascii.eqlIgnoreCase(p.value, "required")) {
                    return refuse(why, arena, text, "ssl_cert_reqs \"{s}\" is not none or required", .{p.value});
                }
            } else {
                return refuse(why, arena, text, "the parameter {s} is not supported", .{name});
            }
        }
        if (s.cert_file != null and s.key_file == null) return refuse(why, arena, text, "ssl_certfile is set but ssl_keyfile is not", .{});
        if (s.username != null and s.password == null) return refuse(why, arena, text, "it names a user without a password", .{});
        return s;
    }

    /// `redis://user@host:port/db`, without the password, for logs.
    pub fn format(s: Settings, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const user = s.username orelse "";
        const at = if (s.username != null) "@" else "";
        if (s.unix_path) |p| return w.print("unix://{s}{s}{s}?db={d}", .{ user, at, p, s.database });
        const ipv6 = std.mem.indexOfScalar(u8, s.host, ':') != null;
        try w.print("{s}://{s}{s}{s}{s}{s}:{d}/{d}", .{
            if (s.tls) "rediss" else "redis", user,       at,
            if (ipv6) "[" else "",            s.host,     if (ipv6) "]" else "",
            s.port,                           s.database,
        });
    }
};

/// For `set`.
pub const SetOptions = struct {
    /// Expire the key after this long (EX in seconds when whole, else PX).
    ttl: ?Duration = null,
    /// Set only when the key does not exist yet (NX).
    nx: bool = false,
    /// Set only when the key exists already (XX).
    xx: bool = false,
    /// Keep the key's time to live (KEEPTTL).
    keep_ttl: bool = false,
};

/// For `zrange` and `zrangeWithScores`.
pub const RangeOptions = struct {
    /// Highest score first (REV; Redis 6.2+).
    rev: bool = false,
};

/// A sorted set's member and its score.
pub const Scored = struct {
    member: []const u8,
    score: f64,
};

/// A pub/sub message (`Subscriber.next`).
pub const Message = struct {
    channel: []const u8,
    payload: []const u8,
    /// The pattern it matched, for a `psubscribe`.
    pattern: ?[]const u8 = null,
};

/// Tests only: runs on every connection `takeFrom` hands out, with its
/// stream (to break it before the call writes).
pub var test_after_take: if (builtin.is_test) ?*const fn (*ClientStream) void else void = if (builtin.is_test) null else {};

/// The pool of one executor: idle connections, and how many are open.
const Pool = struct {
    mutex: safety.Mutex(.leaf) = .init,
    /// Signalled when a connection goes back, or a place frees up.
    returned: safety.Condition = .init,
    /// `max` slots; the first `idle_len` hold idle connections.
    idle: []*Connection,
    idle_len: usize = 0,
    /// Idle and in use.
    open: usize = 0,
    max: usize,
};

/// One connection to the server, and its RESP parser.
const Connection = struct {
    gpa: std.mem.Allocator,
    stream: *ClientStream,
    parser: *hiredis.redisReader,
    /// Null for a subscriber's.
    pool: ?*Pool,
    idle_since: std.Io.Clock.Timestamp = undefined,
    state: State = .{},
    /// Out of step with the server (a failure or a cancel mid-reply):
    /// closed when given back.
    broken: bool = false,
    /// Taken idle from the pool (not dialed for this call): the server may
    /// have closed it while it waited.
    reused: bool = false,
    /// `stream.bytesSent()` when it was taken: unchanged after a failure,
    /// nothing of the call reached the server.
    sent: u64 = 0,
    /// Bumped by every give-back, under its pool's `mutex`: a `Conn` from
    /// an earlier checkout gives nothing back (SAFETY.md M6, as pgxpool's
    /// idempotent `Release`). Read without the lock only by its holder.
    lease: u32 = 0,

    /// What the commands sent so far have left on the connection.
    const State = struct {
        multi: bool = false,
        watching: bool = false,
        /// Another database, a subscription, another user...
        tainted: bool = false,
    };

    /// Whether a call on it that failed can run once more on another
    /// connection, transparently: it came idle from the pool and not one
    /// byte of the call left on it. Once anything was sent the server may
    /// have run it, and a second run could repeat an INCR.
    fn untouched(self: *const Connection) bool {
        return self.reused and self.stream.bytesSent() == self.sent;
    }

    fn reusable(self: *const Connection) bool {
        return !self.broken and !self.state.multi and !self.state.watching and !self.state.tainted;
    }

    /// Sends `batch` and reads its replies into `arena`. Any failure leaves
    /// the connection broken.
    fn transfer(self: *Connection, arena: std.mem.Allocator, batch: *const Batch) ![]Reply {
        errdefer self.broken = true;
        try self.send(batch.bytes);
        const replies = try arena.alloc(Reply, batch.count);
        for (replies) |*r| r.* = try self.receive(arena);
        self.state = batch.effect.apply(self.state);
        return replies;
    }

    fn send(self: *Connection, bytes: []const u8) !void {
        const w = self.stream.writer();
        try w.writeAll(bytes);
        try w.flush();
    }

    fn receive(self: *Connection, arena: std.mem.Allocator) !Reply {
        while (true) {
            var raw: ?*anyopaque = null;
            if (hiredis.redisReaderGetReply(self.parser, &raw) != hiredis.REDIS_OK) return error.ProtocolError;
            if (raw) |p| {
                const reply: *hiredis.redisReply = @ptrCast(@alignCast(p));
                defer hiredis.freeReplyObject(reply);
                return convert(arena, reply);
            }
            // Not whole yet: feed more.
            const r = self.stream.reader();
            try r.fillMore();
            const bytes = r.buffered();
            if (hiredis.redisReaderFeed(self.parser, bytes.ptr, bytes.len) != hiredis.REDIS_OK) return error.ProtocolError;
            r.toss(bytes.len);
        }
    }

    fn close(self: *Connection) void {
        hiredis.redisReaderFree(self.parser);
        self.stream.close();
        self.gpa.destroy(self);
    }
};

/// A Redis or Valkey server: the handle in the App state. Its calls take
/// the request (or an `anole.db.Ctx`) first; see `anole.db`.
pub const Client = struct {
    /// The console's `/db` "system" for this connector.
    pub const console_system = "redis";

    gpa: std.mem.Allocator,
    io: std.Io,
    /// The settings' strings and the login commands.
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    /// `Options.timeout`: the bound of a call without its own.
    timeout: ?Duration,
    settings: Settings,
    stream_options: client_stream.ConnectOptions,
    /// AUTH and SELECT, sent as a connection opens; empty when neither is
    /// needed.
    login: Batch,
    pools: internal.PerExecutor(Pool),
    errors: db.ErrorMap,
    /// The breaker and the retry policy (`Options.breaker`, `Options.retry`).
    guard: internal.Guard,
    observer: db.Observer,
    readiness: db.Readiness,
    acquire_timeout: Duration,
    connect_timeout: ?Duration,
    idle_timeout: ?Duration,
    ping_timeout: Duration,
    connect_at_start: bool,
    /// Reads with `.coalesce` or `.cache` (`with`), and `invalidate` for
    /// kept replies: `app.redis.cache.invalidate(.{ .tag = "profiles" })`.
    cache: db.QueryCache,
    /// The one SUBSCRIBE connection of this client's `anole.watch`es, made
    /// on first use (`_pubsubHub`).
    pubsub_hub: ?*PubSubHub = null,
    /// Init-once guard of `pubsub_hub`: held only to read it or make it
    /// (an allocation).
    pubsub_hub_mutex: safety.Mutex(.leaf) = .init,

    /// Resolves the settings and sets up a pool per executor of `io`'s
    /// runtime; no connection opens yet. `app.redis` calls it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        if (opts.max_connections) |n| if (n == 0) {
            log.err("redis: max_connections is 0; set at least 1, or leave it null for the default", .{});
            return error.InvalidOptions;
        };
        if (opts.tls.insecure_skip_verify and opts.tls.ca != null) {
            log.err("redis: tls.insecure_skip_verify cannot be set with tls.ca: one checks the server's certificate and the other does not", .{});
            return error.InvalidOptions;
        }
        if (opts.tls.client_certificate) |cc| if (cc == .dev_self_signed) {
            log.err("redis: tls.client_certificate cannot be .dev_self_signed", .{});
            return error.InvalidOptions;
        };
        const name = opts.name orelse "redis";
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .timeout = opts.timeout,
            .name = name,
            .settings = undefined,
            .stream_options = undefined,
            .login = .{},
            .pools = undefined,
            .errors = opts.errors,
            .guard = try .init(.redis, name, opts.breaker, opts.retry),
            .observer = .{ .system = .redis, .name = name },
            .readiness = .{ .io = io, .context = self, .ping = ping },
            .acquire_timeout = opts.acquire_timeout,
            .connect_timeout = opts.connect_timeout,
            .idle_timeout = opts.idle_timeout,
            .ping_timeout = opts.ping_timeout,
            .connect_at_start = opts.connect_at_start,
            .cache = try .init(gpa, io, .redis, name, opts.cache),
        };
        errdefer self.cache.deinit();
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const s = try Settings.resolve(a, opts);
        self.settings = s;
        if (s.host.len > 255) {
            log.err("redis: the host name is longer than 255 bytes", .{});
            return error.InvalidDatabaseUrl;
        }
        if (!s.tls and (opts.tls.ca != null or opts.tls.client_certificate != null)) {
            log.err("redis: tls.ca or tls.client_certificate is set, but the URL is not rediss://: it would be sent in plain text; use rediss://", .{});
            return error.InvalidOptions;
        }
        if (s.tls and !has_tls) {
            log.err("redis: {f} needs TLS, which this build leaves out (-Dtls=none)", .{s});
            return error.TlsNotBuilt;
        }
        if (s.tls and !s.verify) {
            // The URL often comes from the environment: it may not stop the
            // checks of a CA the code gives.
            if (opts.tls.ca != null) {
                log.warn("redis: the URL turns certificate checks off (ssl_cert_reqs=none), but Options.tls.ca asks for them; take it out of the URL", .{});
                return error.InvalidDatabaseUrl;
            }
            log.warn("redis: ssl_cert_reqs=none: the server's certificate is not checked, so whoever is between this process and {s} can read and change everything", .{s.host});
        }
        self.stream_options = .{
            .host = s.host,
            .port = s.port,
            .unix_path = s.unix_path,
            // `dial` bounds all of it, the login included.
            .connect_timeout = null,
            .tls = if (s.tls) .{
                .ca = opts.tls.ca orelse if (s.ca_file) |path| dusty.Ca{ .file = path } else .system,
                .client_certificate = opts.tls.client_certificate orelse if (s.cert_file) |cert| dusty.Cert.fromFiles(cert, s.key_file.?) else null,
                .insecure_skip_verify = opts.tls.insecure_skip_verify or !s.verify,
            } else null,
        };

        var login: Builder = try .init(a);
        if (s.password) |pw| {
            if (s.username) |u| try login.add(.{ "AUTH", u, pw }) else try login.add(.{ "AUTH", pw });
        }
        if (s.database != 0) try login.add(.{ "SELECT", s.database });
        self.login = login.finish();

        const executors = internal.executorCount(io);
        const total: usize = opts.max_connections orelse 10 * executors;
        self.pools = try .init(gpa, io);
        var made: usize = 0;
        errdefer {
            for (self.pools.pools[0..made]) |*p| gpa.free(p.idle);
            self.pools.deinit(gpa);
        }
        for (self.pools.pools, 0..) |*p, i| {
            const max = self.pools.share(total, i);
            p.* = .{ .idle = try gpa.alloc(*Connection, max), .max = max };
            made += 1;
        }
        log.info("redis \"{s}\": {f}, up to {d} connections over {d} executors", .{ self.name, s, @max(total, executors), executors });
        return self;
    }

    /// Closes every connection: after the server has drained (`app`'s
    /// `deinit` does it then).
    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        // First: the watches' SUBSCRIBE connection and its task.
        if (self.pubsub_hub) |h| h.destroy();
        // A read still running for the cache holds a connection.
        self.cache.deinit();
        self.guard.deinit();
        for (self.pools.pools) |*p| {
            for (p.idle[0..p.idle_len]) |conn| conn.close();
            if (p.open > p.idle_len) log.warn("redis \"{s}\": {d} connections were still taken at deinit", .{ self.name, p.open - p.idle_len });
            gpa.free(p.idle);
        }
        self.pools.deinit(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// What the server hands over when serving starts: the app's metrics
    /// registry, tracer and health checks, when it has them, so `app.redis`
    /// may come before or after `app.metrics`, `app.tracing` and
    /// `app.health`. With `connect_at_start`, it opens a connection per
    /// executor and fails if one cannot.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        self.observer = try .init(.redis, self.name, registry, tracer);
        try self.guard.observe(self.gpa, registry);
        try self.cache.observe(registry);
        if (health) |h| try self.readiness.register(h, self.name);
        if (!self.connect_at_start) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var c: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        const ctx = erase(&c);
        for (self.pools.pools) |*p| {
            const conn = self.takeFrom(&ctx, p) catch |err| {
                log.err("redis \"{s}\": not serving, the server is not reachable ({f})", .{ self.name, db.lastError(&c) orelse db.ErrorDetail{ .system = .redis, .class = .other, .message = @errorName(err) } });
                return err;
            };
            self.give(conn);
        }
    }

    /// The calls with `opts` (of which Redis takes `timeout`, `coalesce`
    /// and `cache`, the last two for reads only; see the top of this file):
    /// `app.redis.with(.{ .timeout = .fromMilliseconds(200) }).get(req, key)`.
    pub fn with(self: *Client, opts: db.QueryOptions) Query {
        return .{ .client = self, .opts = opts };
    }

    /// Sends one command and returns its reply; an error reply fails the
    /// call (see the top of this file).
    ///
    ///     const n = try app.redis.command(req, .{ "INCR", "hits" }); // .int
    pub fn command(self: *Client, c: anytype, args: anytype) Error!Reply {
        return self.with(.{}).command(c, args);
    }

    /// The reply as a `T`; nil (or a hash without fields, for a struct):
    /// `error.NotFound`, a 404.
    ///
    ///     const name = try app.redis.one([]const u8, req, .{ "HGET", key, "name" });
    pub fn one(self: *Client, comptime T: type, c: anytype, args: anytype) Error!T {
        return self.with(.{}).one(T, c, args);
    }

    /// The reply as a `T`, or null for nil (or a hash without fields).
    pub fn optional(self: *Client, comptime T: type, c: anytype, args: anytype) Error!?T {
        return self.with(.{}).optional(T, c, args);
    }

    /// An array reply as a `[]T` (nil: empty).
    ///
    ///     const names = try app.redis.all(?[]const u8, req, .{ "MGET", keys });
    pub fn all(self: *Client, comptime T: type, c: anytype, args: anytype) Error![]T {
        return self.with(.{}).all(T, c, args);
    }

    /// Several commands in one round trip, on one connection; their replies
    /// in order. A tuple of commands, or a slice of `[]const []const u8`:
    ///
    ///     const r = try app.redis.pipeline(req, .{ .{ "INCR", key }, .{ "EXPIRE", key, 60 } });
    ///     const n = r[0].int;
    ///
    /// When one of them fails, every reply is still read, and the call
    /// fails with the first error.
    pub fn pipeline(self: *Client, c: anytype, commands: anytype) Error![]Reply {
        return self.with(.{}).pipeline(c, commands);
    }

    /// A connection taken from the executor's pool until `release`, for
    /// WATCH and MULTI/EXEC across round trips, or anything else that must
    /// stay on one connection. It has the same calls.
    pub fn acquire(self: *Client, c: anytype) Error!Conn {
        const ctx = erase(c);
        const conn = self.take(&ctx) catch |err| return self.narrow(&ctx, err);
        return .{ .client = self, .conn = conn, .lease = conn.lease };
    }

    /// The shared SUBSCRIBE connection of `anole.watch` (internal): one per
    /// client, made on first use.
    pub fn _pubsubHub(self: *Client) !*PubSubHub {
        self.pubsub_hub_mutex.lockUncancelable(self.io);
        defer self.pubsub_hub_mutex.unlock(self.io);
        if (self.pubsub_hub) |h| return h;
        const h = try PubSubHub.create(self);
        self.pubsub_hub = h;
        return h;
    }

    /// A connection of its own subscribed to `channels` (a string, or a
    /// tuple or slice of them), confirmed by the server when this returns;
    /// `next` waits for messages. `close` it when done. Opened with a
    /// request, it ends (`next` returns null) when the server starts to
    /// drain, so an event stream or a WebSocket that forwards it winds down
    /// in time.
    ///
    ///     const sub = try app.redis.subscribe(req, "chat");
    ///     defer sub.close();
    ///     while (try sub.next(req)) |msg| try events.send(msg.payload, .{});
    pub fn subscribe(self: *Client, c: anytype, channels: anytype) Error!*Subscriber {
        return self.openSubscriber(c, "SUBSCRIBE", channels);
    }

    /// As `subscribe`, to the channels that match `patterns` (`news:*`).
    pub fn psubscribe(self: *Client, c: anytype, patterns: anytype) Error!*Subscriber {
        return self.openSubscriber(c, "PSUBSCRIBE", patterns);
    }

    fn openSubscriber(self: *Client, c: anytype, verb: []const u8, names: anytype) Error!*Subscriber {
        const ctx = erase(c);
        var b = Builder.init(ctx.arena) catch return error.OutOfMemory;
        b.add(.{ verb, names }) catch |err| return self.narrow(&ctx, err);
        const batch = b.finish();
        const conn = self.dial(&ctx, null) catch |err| return self.narrow(&ctx, err);
        const sub = self.gpa.create(Subscriber) catch {
            conn.close();
            return error.OutOfMemory;
        };
        sub.* = .{ .client = self, .conn = conn, .io = ctx.io, .arena = .init(self.gpa), .executor = dusty.placement.currentExecutor(ctx.io) };
        errdefer sub.close();
        // One confirmation per name; the server writes them all before
        // anything published after.
        if (batch.args > 1) {
            conn.send(batch.bytes) catch |err| return self.narrow(&ctx, self.broke(&ctx, conn, err));
            for (1..batch.args) |_| {
                const reply = conn.receive(ctx.arena) catch |err| return self.narrow(&ctx, self.broke(&ctx, conn, err));
                if (reply == .err) return self.serverError(&ctx, conn, reply.err);
            }
        }
        if (ctx.request) |req| if (req._drain_hooks) |hooks| {
            sub.hooks = hooks;
            hooks.add(ctx.io, &sub.hook);
        };
        return sub;
    }

    /// True when the server answers PING within `ping_timeout`: `/readyz`'s
    /// check. Its failures are not logged.
    fn ping(context: *anyopaque, io: std.Io) bool {
        const self: *Client = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const quiet: Ctx = .{ .io = io, .arena = arena.allocator(), .any = self, .record = keep, .last = noLast, .request = null };
        var b = Builder.init(quiet.arena) catch return false;
        b.add(.{"PING"}) catch return false;
        const batch = b.finish();
        // Not a call of the app's: no metrics, no span.
        const replies = self.bounded(&quiet, self.ping_timeout, null, &batch) catch return false;
        return replies[0] == .status;
    }

    fn noLast(_: *anyopaque) ?db.ErrorDetail {
        return null;
    }

    /// A context's `record` that keeps the failure to itself.
    fn keep(_: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
        return map.errorFor(detail.class);
    }

    /// GET `key`: its value, or null when it does not exist.
    pub const get = Commands(*Client).get;
    /// SET `key` to `value` (a string, a number...), with `opts` (a TTL,
    /// NX, XX, KEEPTTL). False when NX or XX kept it from being set.
    pub const set = Commands(*Client).set;
    /// DEL one key or several (a tuple or slice); how many existed.
    pub const del = Commands(*Client).del;
    /// INCR: the new value (a missing key counts from 0).
    pub const incr = Commands(*Client).incr;
    /// INCRBY `by`: the new value.
    pub const incrBy = Commands(*Client).incrBy;
    /// EXPIRE (PEXPIRE below whole seconds); false when the key does not
    /// exist.
    pub const expire = Commands(*Client).expire;
    /// HGET one field of a hash, or null.
    pub const hget = Commands(*Client).hget;
    /// HSET from a struct's fields (null ones left out), or from a tuple of
    /// field, value...; how many fields were new.
    pub const hset = Commands(*Client).hset;
    /// HGETALL into a `T`, a struct by field name. A hash without fields:
    /// `error.NotFound`.
    pub const hgetAll = Commands(*Client).hgetAll;
    /// HDEL one field or several; how many existed.
    pub const hdel = Commands(*Client).hdel;
    /// HINCRBY one field of a hash by `by`: its new value.
    pub const hincrBy = Commands(*Client).hincrBy;
    /// LPUSH one value or several; the list's length after.
    pub const lpush = Commands(*Client).lpush;
    /// RPUSH one value or several; the list's length after.
    pub const rpush = Commands(*Client).rpush;
    /// LRANGE from `start` to `stop`, both included (`-1` is the last item).
    pub const lrange = Commands(*Client).lrange;
    /// SADD one member or several; how many were new.
    pub const sadd = Commands(*Client).sadd;
    /// SREM one member or several; how many were there.
    pub const srem = Commands(*Client).srem;
    /// SMEMBERS: every member of the set.
    pub const smembers = Commands(*Client).smembers;
    /// SISMEMBER: whether `member` is in the set.
    pub const sismember = Commands(*Client).sismember;
    /// ZADD one member with `score`; true when it is new (else its score
    /// changed).
    pub const zadd = Commands(*Client).zadd;
    /// ZINCRBY: the member's new score.
    pub const zincrBy = Commands(*Client).zincrBy;
    /// ZSCORE: the member's score, or null when it is not in the set.
    pub const zscore = Commands(*Client).zscore;
    /// ZREM one member or several; how many were there.
    pub const zrem = Commands(*Client).zrem;
    /// ZRANGE by rank, `start` to `stop` included (`.rev` for the highest
    /// scores first).
    pub const zrange = Commands(*Client).zrange;
    /// `zrange` with the scores: a leaderboard's top ten is
    /// `zrangeWithScores(req, "board", 0, 9, .{ .rev = true })`.
    pub const zrangeWithScores = Commands(*Client).zrangeWithScores;
    /// PUBLISH `message` on `channel`: how many subscribers received it.
    pub const publish = Commands(*Client).publish;

    // -----------------------------------------------------------------------
    // The machinery under the calls.

    /// Runs `commands` as one call: on `held` (a connection from `acquire`)
    /// or one of the executor's pool, observed (metrics, a span), bounded
    /// by `timeout`, the reply read as `mode` says, the error narrowed to
    /// `Error`.
    fn call(self: *Client, c: anytype, timeout: ?Duration, retry: bool, held: ?*Connection, comptime T: type, comptime mode: Mode, commands: anytype) Error!Out(T, mode) {
        const ctx = erase(c);
        var b = Builder.init(ctx.arena) catch return error.OutOfMemory;
        (if (mode == .replies) b.addAll(commands) else b.add(commands)) catch |err| return self.narrow(&ctx, err);
        const batch = b.finish();
        const observed = self.observer.start(&ctx);
        const attempt = if (held == null)
            internal.guarded(&ctx, &self.guard, self.errors, retry, null, callOnFn(T, mode), .{ self, &ctx, timeout, held, &batch })
        else
            self.callOn(&ctx, timeout, held, &batch, T, mode);
        const result: Error!Out(T, mode) = if (attempt) |out| out else |err| self.narrow(&ctx, err);
        const failure: ?anyerror = if (result) |_| null else |e| e;
        if (ctx.request) |req| observed.end(req, batch.operation(), null, failure) else observed.end(&ctx, batch.operation(), null, failure);
        return result;
    }

    fn callOnFn(comptime T: type, comptime mode: Mode) fn (*Client, *const Ctx, ?Duration, ?*Connection, *const Batch) anyerror!Out(T, mode) {
        return struct {
            fn run(self: *Client, ctx: *const Ctx, timeout: ?Duration, held: ?*Connection, batch: *const Batch) anyerror!Out(T, mode) {
                return self.callOn(ctx, timeout, held, batch, T, mode);
            }
        }.run;
    }

    fn callOn(self: *Client, ctx: *const Ctx, timeout: ?Duration, held: ?*Connection, batch: *const Batch, comptime T: type, comptime mode: Mode) anyerror!Out(T, mode) {
        const replies = if (timeout) |t| try self.bounded(ctx, t, held, batch) else try self.exchange(ctx, held, batch);
        const d: Decoder = .{ .ctx = ctx, .map = self.errors, .name = batch.operation() };
        return switch (mode) {
            .reply => replies[0],
            .replies => replies,
            .one => if (none(T, replies[0])) error.NotFound else try decode(T, replies[0], &d),
            .optional => if (none(T, replies[0])) null else try decode(T, replies[0], &d),
            .all => try decode([]T, replies[0], &d),
        };
    }

    /// `exchange` within `timeout`: past it, the call is canceled where it
    /// waits (its connection closed) and fails with the `timeout` class
    /// (`GatewayTimeout`).
    fn bounded(self: *Client, ctx: *const Ctx, timeout: Duration, held: ?*Connection, batch: *const Batch) anyerror![]Reply {
        const deadline: dusty.Deadline = .init(ctx.io, .{ .duration = .{ .raw = timeout, .clock = .awake } });
        return deadline.run(exchange, .{ self, ctx, held, batch }) catch |err| switch (err) {
            error.Timeout => ctx.fail(self.errors, .{ .system = .redis, .class = .timeout, .message = "the call ran past its timeout" }),
            else => |e| e,
        };
    }

    /// Sends `batch` on `held` or a pooled connection and reads its
    /// replies; the first error reply fails the call.
    fn exchange(self: *Client, ctx: *const Ctx, held: ?*Connection, batch: *const Batch) anyerror![]Reply {
        var conn = held orelse try self.take(ctx);
        defer if (held == null) self.give(conn);
        if (conn.broken) return ctx.failf(self.errors, .unavailable, "the connection broke in an earlier call; release it and acquire another", .{});
        var stale_retries: u8 = 0;
        const replies = while (true) {
            break conn.transfer(ctx.arena, batch) catch |err| {
                // A call that broke before one byte of it left a connection
                // taken idle from the pool (the server or a proxy closed it
                // meanwhile) reached no one: once more on another
                // connection, not a failure of the call (and not counted by
                // the retry policy).
                if (held == null and conn.untouched() and err != error.Canceled and stale_retries < 4) {
                    stale_retries += 1;
                    self.give(conn);
                    conn = try self.take(ctx);
                    continue;
                }
                return self.broke(ctx, conn, err);
            };
        };
        for (replies) |r| if (r == .err) return self.serverError(ctx, conn, r.err);
        return replies;
    }

    /// A server's error reply, as `Error`.
    fn serverError(self: *Client, ctx: *const Ctx, conn: *Connection, message: []const u8) db.Error {
        const code = errorCode(message);
        // A replica now: a new connection may reach the new primary.
        if (std.mem.eql(u8, code, "READONLY")) conn.broken = true;
        return ctx.fail(self.errors, .{ .system = .redis, .class = classify(message), .code = code, .message = message });
    }

    /// What a connection that failed mid-call returns: a cancel, or
    /// `ServiceUnavailable` with the cause. It is closed when given back.
    fn broke(self: *Client, ctx: *const Ctx, conn: *Connection, err: anyerror) anyerror {
        conn.broken = true;
        const cause = switch (err) {
            error.ReadFailed => conn.stream.readError() orelse err,
            error.WriteFailed => conn.stream.writeError() orelse err,
            else => err,
        };
        return switch (cause) {
            error.Canceled, error.OutOfMemory => cause,
            error.EndOfStream => ctx.failf(self.errors, .unavailable, "{f} closed the connection", .{self.settings}),
            else => ctx.failf(self.errors, .unavailable, "the connection to {f} broke: {t}", .{ self.settings, cause }),
        };
    }

    /// `err` as one of `Error`; anything else is recorded as a 500.
    fn narrow(self: *Client, ctx: *const Ctx, err: anyerror) Error {
        inline for (@typeInfo(Error).error_set.error_names.?) |name| {
            if (err == @field(Error, name)) return @field(Error, name);
        }
        if (err == error.EmptyCommand) return ctx.failf(self.errors, .other, "an empty command", .{});
        return ctx.fail(self.errors, .{ .system = .redis, .class = .other, .message = @errorName(err) });
    }

    /// A connection from the calling executor's pool.
    fn take(self: *Client, ctx: *const Ctx) anyerror!*Connection {
        return self.takeFrom(ctx, self.pools.get(ctx.io));
    }

    /// An idle connection of `pool`, else a new one while it has room, else
    /// the first one given back within `acquire_timeout`.
    fn takeFrom(self: *Client, ctx: *const Ctx, pool: *Pool) anyerror!*Connection {
        const io = ctx.io;
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        const until: std.Io.Timeout = .{ .deadline = started.addDuration(.{ .raw = self.acquire_timeout, .clock = .awake }) };
        try pool.mutex.lock(io);
        while (true) {
            if (pool.idle_len > 0) {
                pool.idle_len -= 1;
                const conn = pool.idle[pool.idle_len];
                if (self.expired(conn, io)) {
                    pool.open -= 1;
                    pool.mutex.unlock(io);
                    self.observer.connections(-1, 0);
                    conn.close();
                    pool.mutex.lockUncancelable(io);
                    continue;
                }
                pool.mutex.unlock(io);
                self.observer.connections(-1, 1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                conn.reused = true;
                return handOut(conn);
            }
            if (pool.open < pool.max) {
                pool.open += 1;
                pool.mutex.unlock(io);
                const conn = self.dial(ctx, pool) catch |err| {
                    pool.mutex.lockUncancelable(io);
                    pool.open -= 1;
                    pool.returned.signal(io);
                    pool.mutex.unlock(io);
                    return err;
                };
                self.observer.connections(0, 1);
                self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
                return handOut(conn);
            }
            self.observer.waiting(1);
            pool.returned.waitTimeout(io, &pool.mutex, until) catch |err| {
                self.observer.waiting(-1);
                pool.mutex.unlock(io);
                return switch (err) {
                    error.Canceled => error.Canceled,
                    error.Timeout => ctx.fail(self.errors, .{ .system = .redis, .class = .unavailable, .code = "pool_timeout", .message = std.fmt.allocPrint(ctx.arena, "no connection within {d} ms: all {d} of this executor's connections were busy", .{ self.acquire_timeout.toMilliseconds(), pool.max }) catch "no connection within the acquire timeout" }),
                };
            };
            self.observer.waiting(-1);
        }
    }

    /// `conn` as `takeFrom` hands it out: what it has sent so far noted
    /// (see `Connection.untouched`).
    fn handOut(conn: *Connection) *Connection {
        conn.sent = conn.stream.bytesSent();
        if (builtin.is_test) if (test_after_take) |f| f(conn.stream);
        return conn;
    }

    /// Closes the idle pooled connections of every executor's pool; the
    /// next call dials a new one. Subscriptions keep their connections.
    /// The Lambda adapter calls it after a long freeze, when a NAT gateway
    /// may have dropped them without telling either end.
    pub fn closeIdle(self: *Client) void {
        const io = self.io;
        for (self.pools.pools) |*pool| {
            while (true) {
                pool.mutex.lockUncancelable(io);
                if (pool.idle_len == 0) {
                    pool.mutex.unlock(io);
                    break;
                }
                pool.idle_len -= 1;
                const conn = pool.idle[pool.idle_len];
                pool.open -= 1;
                pool.returned.signal(io);
                pool.mutex.unlock(io);
                self.observer.connections(-1, 0);
                conn.close();
            }
        }
    }

    fn expired(self: *const Client, conn: *const Connection, io: std.Io) bool {
        const limit = self.idle_timeout orelse return false;
        return conn.idle_since.durationTo(.now(io, .awake)).raw.nanoseconds > limit.nanoseconds;
    }

    /// Gives a connection the caller holds back to its pool, or closes it
    /// when it is broken or left in a state the next call must not inherit.
    fn give(self: *Client, conn: *Connection) void {
        self.giveLease(conn, conn.lease);
    }

    /// `give`, when `lease` is the checkout that holds `conn` now; a lease
    /// given back already (a second `release`, or one after the connection
    /// was taken again) gives nothing back and logs.
    fn giveLease(self: *Client, conn: *Connection, lease: u32) void {
        const io = self.io;
        const pool = conn.pool.?;
        pool.mutex.lockUncancelable(io);
        if (conn.lease != lease) {
            pool.mutex.unlock(io);
            log.err("redis \"{s}\": a connection from acquire() was released twice; the second release did nothing", .{self.name});
            return;
        }
        conn.lease +%= 1;
        // Read after the lease check: the connection is still this
        // caller's, no one else's.
        if (!conn.reusable()) {
            pool.open -= 1;
            pool.returned.signal(io);
            pool.mutex.unlock(io);
            self.observer.connections(0, -1);
            conn.close();
            return;
        }
        conn.idle_since = .now(io, .awake);
        pool.idle[pool.idle_len] = conn;
        pool.idle_len += 1;
        pool.returned.signal(io);
        pool.mutex.unlock(io);
        self.observer.connections(1, -1);
    }

    /// Opens a connection and logs in, within `connect_timeout`.
    fn dial(self: *Client, ctx: *const Ctx, pool: ?*Pool) anyerror!*Connection {
        const timeout: std.Io.Timeout = if (self.connect_timeout) |t| .{ .duration = .{ .raw = t, .clock = .awake } } else .none;
        const deadline: dusty.Deadline = .init(ctx.io, timeout);
        return deadline.run(open, .{ self, ctx, pool }) catch |err| {
            // Recorded already: the server refused the login.
            inline for (@typeInfo(db.Error).error_set.error_names.?) |name| {
                if (err == @field(db.Error, name)) return err;
            }
            return switch (err) {
                error.Canceled, error.OutOfMemory => err,
                error.Timeout => ctx.failf(self.errors, .unavailable, "{f} did not answer within {d} ms", .{ self.settings, if (self.connect_timeout) |t| t.toMilliseconds() else 0 }),
                else => ctx.failf(self.errors, .unavailable, "cannot connect to {f}: {t}", .{ self.settings, err }),
            };
        };
    }

    fn open(self: *Client, ctx: *const Ctx, pool: ?*Pool) anyerror!*Connection {
        const stream = try ClientStream.connect(self.gpa, ctx.io, self.stream_options);
        errdefer stream.close();
        const parser = hiredis.redisReaderCreate() orelse return error.OutOfMemory;
        errdefer hiredis.redisReaderFree(parser);
        // `convert` (and hiredis's freeReplyObject) recurse once per level.
        parser.*.maxdepth = max_reply_depth;
        const conn = try self.gpa.create(Connection);
        errdefer self.gpa.destroy(conn);
        conn.* = .{ .gpa = self.gpa, .stream = stream, .parser = parser, .pool = pool };
        if (self.login.count > 0) {
            const replies = conn.transfer(ctx.arena, &self.login) catch |err| return switch (err) {
                error.ReadFailed => stream.readError() orelse err,
                error.WriteFailed => stream.writeError() orelse err,
                else => err,
            };
            for (replies) |r| if (r == .err) {
                return ctx.fail(self.errors, .{ .system = .redis, .class = .unavailable, .code = errorCode(r.err), .message = r.err });
            };
            // The user and database every call expects.
            conn.state = .{};
        }
        return conn;
    }
};

/// The calls with `QueryOptions` (`Client.with`).
pub const Query = struct {
    client: *Client,
    opts: db.QueryOptions,

    /// `Client.command`, with the options.
    pub fn command(self: Query, c: anytype, args: anytype) Error!Reply {
        return self.client.call(c, internal.callTimeout(self.opts.timeout, self.client.timeout), self.opts.retry, null, Reply, .reply, args);
    }

    // The reads go through the cache, which shares them when `opts` asks
    // (`coalesce`, `cache`) and the command only reads.

    /// `Client.one`, with the options (`coalesce` and `cache` apply to read commands).
    pub fn one(self: Query, comptime T: type, c: anytype, args: anytype) Error!T {
        return self.read(T, .one, c, args);
    }

    /// `Client.optional`, with the options (`coalesce` and `cache` apply to read commands).
    pub fn optional(self: Query, comptime T: type, c: anytype, args: anytype) Error!?T {
        return self.read(T, .optional, c, args);
    }

    /// `Client.all`, with the options (`coalesce` and `cache` apply to read commands).
    pub fn all(self: Query, comptime T: type, c: anytype, args: anytype) Error![]T {
        return self.read(T, .all, c, args);
    }

    /// Sends `args`, the command's name and then its items, and returns
    /// the reply: for commands known only at run time (the C ABI, the
    /// language bindings). `coalesce` and `cache` apply when the name is
    /// one of `read_commands`; else, and for a server error, as `command`.
    pub fn reply(self: Query, c: anytype, args: []const []const u8) Error!Reply {
        if (args.len == 0 or (!self.opts.coalesce and self.opts.cache == null)) return self.command(c, args);
        var buf: [max_read_name]u8 = undefined;
        const name = readCommand(&buf, args[0]) orelse return self.command(c, args);
        return self.client.cache.read(Reply, c, self.opts, name, args[1..], ReplyRead{ .query = self });
    }

    /// `Client.pipeline`, with the options.
    pub fn pipeline(self: Query, c: anytype, commands: anytype) Error![]Reply {
        return self.client.call(c, internal.callTimeout(self.opts.timeout, self.client.timeout), self.opts.retry, null, Reply, .replies, commands);
    }

    /// Through the cache when `opts` asks for sharing and `args` is a
    /// tuple naming a read command (`read_commands`); the cache's key is
    /// the name in capitals, then the rest of the command. Else the plain
    /// call.
    fn read(self: Query, comptime T: type, comptime mode: Mode, c: anytype, args: anytype) Error!Out(T, mode) {
        if (comptime !splittable(@TypeOf(args))) return self.plain(T, mode, c, args);
        if (!self.opts.coalesce and self.opts.cache == null) return self.plain(T, mode, c, args);
        var buf: [max_read_name]u8 = undefined;
        const name = readCommand(&buf, args[0]) orelse return self.plain(T, mode, c, args);
        return self.client.cache.read(Out(T, mode), c, self.opts, name, rest(args), Read(T, mode){ .query = self });
    }

    fn plain(self: Query, comptime T: type, comptime mode: Mode, c: anytype, args: anytype) Error!Out(T, mode) {
        return self.client.call(c, internal.callTimeout(self.opts.timeout, self.client.timeout), self.opts.retry, null, T, mode, args);
    }

    /// `Client.get`, with the options.
    pub const get = Commands(Query).get;
    /// `Client.set`, with the options.
    pub const set = Commands(Query).set;
    /// `Client.del`, with the options.
    pub const del = Commands(Query).del;
    /// `Client.incr`, with the options.
    pub const incr = Commands(Query).incr;
    /// `Client.incrBy`, with the options.
    pub const incrBy = Commands(Query).incrBy;
    /// `Client.expire`, with the options.
    pub const expire = Commands(Query).expire;
    /// `Client.hget`, with the options.
    pub const hget = Commands(Query).hget;
    /// `Client.hset`, with the options.
    pub const hset = Commands(Query).hset;
    /// `Client.hgetAll`, with the options.
    pub const hgetAll = Commands(Query).hgetAll;
    /// `Client.hdel`, with the options.
    pub const hdel = Commands(Query).hdel;
    /// `Client.hincrBy`, with the options.
    pub const hincrBy = Commands(Query).hincrBy;
    /// `Client.lpush`, with the options.
    pub const lpush = Commands(Query).lpush;
    /// `Client.rpush`, with the options.
    pub const rpush = Commands(Query).rpush;
    /// `Client.lrange`, with the options.
    pub const lrange = Commands(Query).lrange;
    /// `Client.sadd`, with the options.
    pub const sadd = Commands(Query).sadd;
    /// `Client.srem`, with the options.
    pub const srem = Commands(Query).srem;
    /// `Client.smembers`, with the options.
    pub const smembers = Commands(Query).smembers;
    /// `Client.sismember`, with the options.
    pub const sismember = Commands(Query).sismember;
    /// `Client.zadd`, with the options.
    pub const zadd = Commands(Query).zadd;
    /// `Client.zincrBy`, with the options.
    pub const zincrBy = Commands(Query).zincrBy;
    /// `Client.zscore`, with the options.
    pub const zscore = Commands(Query).zscore;
    /// `Client.zrem`, with the options.
    pub const zrem = Commands(Query).zrem;
    /// `Client.zrange`, with the options.
    pub const zrange = Commands(Query).zrange;
    /// `Client.zrangeWithScores`, with the options.
    pub const zrangeWithScores = Commands(Query).zrangeWithScores;
    /// `Client.publish`, with the options.
    pub const publish = Commands(Query).publish;
};

/// A read as `anole.db.QueryCache` makes it: the plain call of `name`
/// with the rest of the command, with the caller's context or a shared
/// call's own.
fn Read(comptime T: type, comptime mode: Mode) type {
    return struct {
        query: Query,

        pub const shape = @field(db.ReadShape, @tagName(mode));

        pub fn run(r: @This(), c: anytype, name: []const u8, args: anytype) Error!Out(T, mode) {
            return r.query.plain(T, mode, c, .{ name, args });
        }
    };
}

/// `Query.reply`'s read through the cache.
const ReplyRead = struct {
    query: Query,

    pub const shape: db.ReadShape = .reply;

    pub fn run(r: ReplyRead, c: anytype, name: []const u8, items: []const []const u8) Error!Reply {
        return r.query.command(c, .{ name, items });
    }
};

/// The commands whose replies `coalesce` and `cache` may share: those
/// that only read and answer the same for the same data (not
/// `SRANDMEMBER`, `SCAN` or scripts).
pub const read_commands = std.StaticStringMap(void).initComptime(.{
    .{"GET"},         .{"MGET"},        .{"GETRANGE"},         .{"STRLEN"},
    .{"EXISTS"},      .{"TYPE"},        .{"TTL"},              .{"PTTL"},
    .{"EXPIRETIME"},  .{"PEXPIRETIME"}, .{"HGET"},             .{"HMGET"},
    .{"HGETALL"},     .{"HKEYS"},       .{"HVALS"},            .{"HLEN"},
    .{"HEXISTS"},     .{"HSTRLEN"},     .{"LRANGE"},           .{"LINDEX"},
    .{"LLEN"},        .{"LPOS"},        .{"SMEMBERS"},         .{"SISMEMBER"},
    .{"SMISMEMBER"},  .{"SCARD"},       .{"SINTER"},           .{"SUNION"},
    .{"SDIFF"},       .{"SINTERCARD"},  .{"ZRANGE"},           .{"ZRANGEBYSCORE"},
    .{"ZRANGEBYLEX"}, .{"ZREVRANGE"},   .{"ZREVRANGEBYSCORE"}, .{"ZREVRANGEBYLEX"},
    .{"ZSCORE"},      .{"ZMSCORE"},     .{"ZCARD"},            .{"ZCOUNT"},
    .{"ZLEXCOUNT"},   .{"ZRANK"},       .{"ZREVRANK"},         .{"ZINTER"},
    .{"ZUNION"},      .{"ZDIFF"},       .{"ZINTERCARD"},       .{"XRANGE"},
    .{"XREVRANGE"},   .{"XLEN"},        .{"GEOPOS"},           .{"GEODIST"},
    .{"GEOHASH"},     .{"GEOSEARCH"},   .{"BITCOUNT"},         .{"BITPOS"},
    .{"GETBIT"},      .{"SORT_RO"},     .{"DBSIZE"},
});

const max_read_name = 24;

/// Whether `A` is a tuple whose first item is a string: a command
/// `read` can split into its name and the rest.
fn splittable(comptime A: type) bool {
    const info = @typeInfo(A);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".field_types.len == 0) return false;
    return isString(info.@"struct".field_types[0]);
}

fn isString(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// `name` in capitals, in `buf`, when it is one of `read_commands`.
fn readCommand(buf: *[max_read_name]u8, name: anytype) ?[]const u8 {
    const s: []const u8 = name;
    if (s.len > buf.len) return null;
    const upper = std.ascii.upperString(buf[0..s.len], s);
    return if (read_commands.has(upper)) upper else null;
}

/// A command's items after its name, as a tuple whose items can be kept
/// (literals made runtime values: integers as `i64`, floats as `f64`).
fn Rest(comptime A: type) type {
    const all_types = @typeInfo(A).@"struct".field_types;
    var types: [all_types.len - 1]type = undefined;
    for (all_types[1..], &types) |F, *R| R.* = switch (@typeInfo(F)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .null => ?u8,
        .enum_literal => []const u8,
        else => F,
    };
    const final = types;
    return @Tuple(&final);
}

fn rest(args: anytype) Rest(@TypeOf(args)) {
    const A = @TypeOf(args);
    var out: Rest(A) = undefined;
    inline for (@typeInfo(A).@"struct".field_types[1..], 1..) |F, i| out[i - 1] = switch (@typeInfo(F)) {
        .enum_literal => @tagName(args[i]),
        else => args[i],
    };
    return out;
}

/// A connection taken with `Client.acquire`: the same calls, all on it,
/// until `release`.
///
///     var conn = try app.redis.acquire(req);
///     defer conn.release();
///     _ = try conn.command(req, .{ "WATCH", key });
///     const stock = try conn.one(i64, req, .{ "GET", key });
///     const r = try conn.pipeline(req, .{ .{"MULTI"}, .{ "SET", key, stock - 1 }, .{"EXEC"} });
///     if (r[2] == .nil) return error.Conflict; // the key changed: EXEC did nothing
pub const Conn = struct {
    client: *Client,
    conn: *Connection,
    /// `conn.lease` when it was acquired.
    lease: u32,

    /// Gives the connection back; one left inside MULTI or WATCH, on
    /// another database or subscribed, or broken, is closed instead. A
    /// second call does nothing (it logs). Don't call anything on it after
    /// `release`.
    pub fn release(self: *const Conn) void {
        self.client.giveLease(self.conn, self.lease);
    }

    /// `Client.command`, on this connection.
    pub fn command(self: *Conn, c: anytype, args: anytype) Error!Reply {
        return self.client.call(c, null, false, self.conn, Reply, .reply, args);
    }

    /// `Client.one`, on this connection.
    pub fn one(self: *Conn, comptime T: type, c: anytype, args: anytype) Error!T {
        return self.client.call(c, null, false, self.conn, T, .one, args);
    }

    /// `Client.optional`, on this connection.
    pub fn optional(self: *Conn, comptime T: type, c: anytype, args: anytype) Error!?T {
        return self.client.call(c, null, false, self.conn, T, .optional, args);
    }

    /// `Client.all`, on this connection.
    pub fn all(self: *Conn, comptime T: type, c: anytype, args: anytype) Error![]T {
        return self.client.call(c, null, false, self.conn, T, .all, args);
    }

    /// `Client.pipeline`, on this connection.
    pub fn pipeline(self: *Conn, c: anytype, commands: anytype) Error![]Reply {
        return self.client.call(c, null, false, self.conn, Reply, .replies, commands);
    }

    /// `Client.get`, on this connection.
    pub const get = Commands(*Conn).get;
    /// `Client.set`, on this connection.
    pub const set = Commands(*Conn).set;
    /// `Client.del`, on this connection.
    pub const del = Commands(*Conn).del;
    /// `Client.incr`, on this connection.
    pub const incr = Commands(*Conn).incr;
    /// `Client.incrBy`, on this connection.
    pub const incrBy = Commands(*Conn).incrBy;
    /// `Client.expire`, on this connection.
    pub const expire = Commands(*Conn).expire;
    /// `Client.hget`, on this connection.
    pub const hget = Commands(*Conn).hget;
    /// `Client.hset`, on this connection.
    pub const hset = Commands(*Conn).hset;
    /// `Client.hgetAll`, on this connection.
    pub const hgetAll = Commands(*Conn).hgetAll;
    /// `Client.hdel`, on this connection.
    pub const hdel = Commands(*Conn).hdel;
    /// `Client.hincrBy`, on this connection.
    pub const hincrBy = Commands(*Conn).hincrBy;
    /// `Client.lpush`, on this connection.
    pub const lpush = Commands(*Conn).lpush;
    /// `Client.rpush`, on this connection.
    pub const rpush = Commands(*Conn).rpush;
    /// `Client.lrange`, on this connection.
    pub const lrange = Commands(*Conn).lrange;
    /// `Client.sadd`, on this connection.
    pub const sadd = Commands(*Conn).sadd;
    /// `Client.srem`, on this connection.
    pub const srem = Commands(*Conn).srem;
    /// `Client.smembers`, on this connection.
    pub const smembers = Commands(*Conn).smembers;
    /// `Client.sismember`, on this connection.
    pub const sismember = Commands(*Conn).sismember;
    /// `Client.zadd`, on this connection.
    pub const zadd = Commands(*Conn).zadd;
    /// `Client.zincrBy`, on this connection.
    pub const zincrBy = Commands(*Conn).zincrBy;
    /// `Client.zscore`, on this connection.
    pub const zscore = Commands(*Conn).zscore;
    /// `Client.zrem`, on this connection.
    pub const zrem = Commands(*Conn).zrem;
    /// `Client.zrange`, on this connection.
    pub const zrange = Commands(*Conn).zrange;
    /// `Client.zrangeWithScores`, on this connection.
    pub const zrangeWithScores = Commands(*Conn).zrangeWithScores;
    /// `Client.publish`, on this connection.
    pub const publish = Commands(*Conn).publish;
};

/// A connection in pub/sub mode (`Client.subscribe`, `psubscribe`), its
/// own, outside the pools.
pub const Subscriber = struct {
    client: *Client,
    conn: *Connection,
    io: std.Io,
    /// The current message's.
    arena: std.heap.ArenaAllocator,
    /// Set by `stop`: `next` returns null.
    stopped: std.atomic.Value(bool) = .init(false),
    /// The drain hooks of the request it was opened with.
    hooks: ?*dusty.DrainHooks = null,
    hook: dusty.DrainHooks.Hook = .{ .callback = onDrain },
    /// The executor it was opened on, where the drain's `stop` runs.
    executor: ?usize,
    stopper: std.Io.Group = .init,

    /// The next message, or null once it is stopped (`stop`, the server's
    /// drain) or nothing is subscribed any more (after unsubscribing from
    /// everything). The message is valid until the next call; copy what
    /// must outlive it. Waits as long as it takes; a cancel of the calling
    /// task (the request's end) stops it, and leaves the subscriber to be
    /// closed.
    pub fn next(self: *Subscriber, c: anytype) Error!?Message {
        const ctx = erase(c);
        const cl = self.client;
        while (true) {
            if (self.stopped.load(.acquire)) return null;
            if (self.conn.broken) return cl.narrow(&ctx, ctx.failf(cl.errors, .unavailable, "the subscription's connection broke earlier", .{}));
            _ = self.arena.reset(.retain_capacity);
            const reply = self.conn.receive(self.arena.allocator()) catch |err| {
                if (self.stopped.load(.acquire)) return null;
                return cl.narrow(&ctx, cl.broke(&ctx, self.conn, err));
            };
            const items = switch (reply) {
                .array => |a| a,
                .err => |e| return cl.serverError(&ctx, self.conn, e),
                else => continue,
            };
            if (items.len < 2) continue;
            const kind = items[0].text() orelse continue;
            if (std.mem.eql(u8, kind, "message") and items.len == 3) {
                return .{ .channel = items[1].text() orelse "", .payload = items[2].text() orelse "" };
            } else if (std.mem.eql(u8, kind, "pmessage") and items.len == 4) {
                return .{ .pattern = items[1].text() orelse "", .channel = items[2].text() orelse "", .payload = items[3].text() orelse "" };
            } else if ((std.mem.eql(u8, kind, "unsubscribe") or std.mem.eql(u8, kind, "punsubscribe")) and items.len == 3) {
                if (items[2] == .int and items[2].int == 0) return null;
            }
            // Confirmations, and PING's answer.
        }
    }

    /// Adds channels. Their confirmations come through `next`, which skips
    /// them, so this does not wait for them: it may run while another task
    /// waits in `next`.
    pub fn subscribe(self: *Subscriber, c: anytype, channels: anytype) Error!void {
        return self.send(c, "SUBSCRIBE", channels);
    }

    /// Adds patterns (`news.*`), as `subscribe` adds channels; their
    /// messages carry the `pattern` they matched.
    pub fn psubscribe(self: *Subscriber, c: anytype, patterns: anytype) Error!void {
        return self.send(c, "PSUBSCRIBE", patterns);
    }

    /// Drops channels; `.{}` drops every one, after which `next` returns
    /// null (unless patterns remain).
    pub fn unsubscribe(self: *Subscriber, c: anytype, channels: anytype) Error!void {
        return self.send(c, "UNSUBSCRIBE", channels);
    }

    /// Drops patterns, as `unsubscribe` drops channels.
    pub fn punsubscribe(self: *Subscriber, c: anytype, patterns: anytype) Error!void {
        return self.send(c, "PUNSUBSCRIBE", patterns);
    }

    fn send(self: *Subscriber, c: anytype, verb: []const u8, names: anytype) Error!void {
        const ctx = erase(c);
        var b = Builder.init(ctx.arena) catch return error.OutOfMemory;
        b.add(.{ verb, names }) catch |err| return self.client.narrow(&ctx, err);
        const batch = b.finish();
        self.conn.send(batch.bytes) catch |err| return self.client.narrow(&ctx, self.client.broke(&ctx, self.conn, err));
    }

    /// Ends the subscription: a `next` waiting in another task, and every
    /// later one, returns null. It does not wait, and may run on any task
    /// until `close`.
    pub fn stop(self: *Subscriber) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.conn.stream.shutdown();
    }

    fn onDrain(hook: *dusty.DrainHooks.Hook) void {
        const self: *Subscriber = @fieldParentPtr("hook", hook);
        // The hook must not wait; the socket's shutdown goes to a task on
        // the subscriber's executor.
        const where: dusty.placement.Where = if (self.executor) |i| .{ .executor = i } else .local;
        dusty.placement.concurrent(&self.stopper, self.io, where, stopTask, .{self}) catch {};
    }

    fn stopTask(self: *Subscriber) std.Io.Cancelable!void {
        self.stop();
    }

    /// Closes the connection. Not while another task waits in `next`.
    pub fn close(self: *Subscriber) void {
        if (self.hooks) |h| h.remove(self.io, &self.hook);
        self.stopper.cancel(self.io);
        self.conn.close();
        self.arena.deinit();
        self.client.gpa.destroy(self);
    }
};

/// The helpers, for `Client`, `Query` and `Conn` alike.
fn Commands(comptime Self: type) type {
    return struct {
        /// GET: the value, or null.
        pub fn get(self: Self, c: anytype, key: []const u8) Error!?[]const u8 {
            return self.optional([]const u8, c, .{ "GET", key });
        }

        /// SET `value` (any argument: a string, a number...). False when
        /// `nx` or `xx` kept it from being set.
        ///
        ///     _ = try app.redis.set(req, "page:/", html, .{ .ttl = .fromSeconds(30) });
        ///     const mine = try app.redis.set(req, "lock:job", "1", .{ .nx = true, .ttl = .fromSeconds(30) });
        pub fn set(self: Self, c: anytype, key: []const u8, value: anytype, opts: SetOptions) Error!bool {
            const Word = ?[]const u8;
            const ttl = opts.ttl;
            const whole = if (ttl) |t| @rem(t.nanoseconds, std.time.ns_per_s) == 0 else false;
            const unit: Word = if (ttl == null) null else if (whole) "EX" else "PX";
            const amount: ?i64 = if (ttl) |t| (if (whole) t.toSeconds() else @max(1, t.toMilliseconds())) else null;
            const nx: Word = if (opts.nx) "NX" else null;
            const xx: Word = if (opts.xx) "XX" else null;
            const keep_ttl: Word = if (opts.keep_ttl) "KEEPTTL" else null;
            const reply = try self.command(c, .{ "SET", key, value, unit, amount, nx, xx, keep_ttl });
            return reply != .nil;
        }

        /// DEL one key or several (a tuple or slice); how many existed.
        pub fn del(self: Self, c: anytype, keys: anytype) Error!u64 {
            return self.one(u64, c, .{ "DEL", keys });
        }

        /// INCR: the new value (a missing key counts from 0).
        pub fn incr(self: Self, c: anytype, key: []const u8) Error!i64 {
            return self.one(i64, c, .{ "INCR", key });
        }

        /// INCRBY `by`: the new value.
        pub fn incrBy(self: Self, c: anytype, key: []const u8, by: i64) Error!i64 {
            return self.one(i64, c, .{ "INCRBY", key, by });
        }

        /// EXPIRE (PEXPIRE below whole seconds); false when the key does
        /// not exist.
        pub fn expire(self: Self, c: anytype, key: []const u8, ttl: Duration) Error!bool {
            if (@rem(ttl.nanoseconds, std.time.ns_per_s) == 0) return self.one(bool, c, .{ "EXPIRE", key, ttl.toSeconds() });
            return self.one(bool, c, .{ "PEXPIRE", key, @max(1, ttl.toMilliseconds()) });
        }

        /// HGET one field, or null.
        pub fn hget(self: Self, c: anytype, key: []const u8, field: []const u8) Error!?[]const u8 {
            return self.optional([]const u8, c, .{ "HGET", key, field });
        }

        /// HSET from a struct's fields (null ones left out), or from a
        /// tuple of field, value...; how many fields were new.
        ///
        ///     _ = try app.redis.hset(req, "user:42", .{ .name = "Ada", .visits = 1 });
        pub fn hset(self: Self, c: anytype, key: []const u8, fields: anytype) Error!u64 {
            return self.one(u64, c, .{ "HSET", key, fields });
        }

        /// HGETALL into a `T`, a struct by field name. A hash without
        /// fields: `error.NotFound`.
        pub fn hgetAll(self: Self, comptime T: type, c: anytype, key: []const u8) Error!T {
            return self.one(T, c, .{ "HGETALL", key });
        }

        /// HDEL one field or several; how many existed.
        pub fn hdel(self: Self, c: anytype, key: []const u8, fields: anytype) Error!u64 {
            return self.one(u64, c, .{ "HDEL", key, fields });
        }

        /// HINCRBY: the field's new value.
        pub fn hincrBy(self: Self, c: anytype, key: []const u8, field: []const u8, by: i64) Error!i64 {
            return self.one(i64, c, .{ "HINCRBY", key, field, by });
        }

        /// LPUSH one value or several; the list's length after.
        pub fn lpush(self: Self, c: anytype, key: []const u8, values: anytype) Error!u64 {
            return self.one(u64, c, .{ "LPUSH", key, values });
        }

        /// RPUSH one value or several; the list's length after.
        pub fn rpush(self: Self, c: anytype, key: []const u8, values: anytype) Error!u64 {
            return self.one(u64, c, .{ "RPUSH", key, values });
        }

        /// LRANGE (`-1` is the last item).
        pub fn lrange(self: Self, c: anytype, key: []const u8, start: i64, stop: i64) Error![][]const u8 {
            return self.all([]const u8, c, .{ "LRANGE", key, start, stop });
        }

        /// SADD one member or several; how many were new.
        pub fn sadd(self: Self, c: anytype, key: []const u8, members: anytype) Error!u64 {
            return self.one(u64, c, .{ "SADD", key, members });
        }

        /// SREM one member or several; how many were there.
        pub fn srem(self: Self, c: anytype, key: []const u8, members: anytype) Error!u64 {
            return self.one(u64, c, .{ "SREM", key, members });
        }

        /// SMEMBERS: every member.
        pub fn smembers(self: Self, c: anytype, key: []const u8) Error![][]const u8 {
            return self.all([]const u8, c, .{ "SMEMBERS", key });
        }

        /// SISMEMBER: whether `member` is in the set.
        pub fn sismember(self: Self, c: anytype, key: []const u8, member: anytype) Error!bool {
            return self.one(bool, c, .{ "SISMEMBER", key, member });
        }

        /// ZADD one member; true when it is new (else its score changed).
        pub fn zadd(self: Self, c: anytype, key: []const u8, score: f64, member: anytype) Error!bool {
            return self.one(bool, c, .{ "ZADD", key, score, member });
        }

        /// ZINCRBY: the member's new score.
        pub fn zincrBy(self: Self, c: anytype, key: []const u8, by: f64, member: anytype) Error!f64 {
            return self.one(f64, c, .{ "ZINCRBY", key, by, member });
        }

        /// ZSCORE: the member's score, or null.
        pub fn zscore(self: Self, c: anytype, key: []const u8, member: anytype) Error!?f64 {
            return self.optional(f64, c, .{ "ZSCORE", key, member });
        }

        /// ZREM one member or several; how many were there.
        pub fn zrem(self: Self, c: anytype, key: []const u8, members: anytype) Error!u64 {
            return self.one(u64, c, .{ "ZREM", key, members });
        }

        /// ZRANGE by rank (`.rev` for the highest scores first).
        pub fn zrange(self: Self, c: anytype, key: []const u8, start: i64, stop: i64, opts: RangeOptions) Error![][]const u8 {
            const rev: ?[]const u8 = if (opts.rev) "REV" else null;
            return self.all([]const u8, c, .{ "ZRANGE", key, start, stop, rev });
        }

        /// As `zrange`, with the scores: a leaderboard's top ten is
        /// `zrangeWithScores(req, "board", 0, 9, .{ .rev = true })`.
        pub fn zrangeWithScores(self: Self, c: anytype, key: []const u8, start: i64, stop: i64, opts: RangeOptions) Error![]Scored {
            const rev: ?[]const u8 = if (opts.rev) "REV" else null;
            const flat = try self.all([]const u8, c, .{ "ZRANGE", key, start, stop, rev, "WITHSCORES" });
            const out = try c.arena.alloc(Scored, flat.len / 2);
            for (out, 0..) |*o, i| o.* = .{
                .member = flat[2 * i],
                .score = std.fmt.parseFloat(f64, flat[2 * i + 1]) catch std.math.nan(f64),
            };
            return out;
        }

        /// PUBLISH: how many subscribers received it.
        pub fn publish(self: Self, c: anytype, channel: []const u8, message: anytype) Error!u64 {
            return self.one(u64, c, .{ "PUBLISH", channel, message });
        }
    };
}

// ---------------------------------------------------------------------------
// Commands as RESP.

/// Commands encoded, ready to send.
const Batch = struct {
    bytes: []const u8 = "",
    count: usize = 0,
    /// The last command's arguments, its name among them.
    args: usize = 0,
    /// The first command's name, upper-cased: the span's operation.
    name_buf: [16]u8 = undefined,
    name_len: usize = 0,
    effect: Effect = .{},

    fn operation(self: *const Batch) []const u8 {
        if (self.count > 1) return "PIPELINE";
        return if (self.name_len == 0) "COMMAND" else self.name_buf[0..self.name_len];
    }
};

/// What a batch of commands does to a connection's `State`: each flag is
/// left alone, set or cleared by the last command that touches it.
const Effect = struct {
    multi: Change = .keep,
    watching: Change = .keep,
    tainted: Change = .keep,

    const Change = enum { keep, set, clear };

    /// Commands after which a connection must not serve another call as it
    /// is.
    const tainting = [_][]const u8{ "SELECT", "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "HELLO", "AUTH", "RESET", "READONLY", "READWRITE" };
    /// CLIENT's subcommands that change the connection.
    const tainting_client = [_][]const u8{ "SETNAME", "SETINFO", "TRACKING", "CACHING", "REPLY", "NO-EVICT", "NO-TOUCH" };

    fn apply(self: Effect, s: Connection.State) Connection.State {
        return .{
            .multi = change(self.multi, s.multi),
            .watching = change(self.watching, s.watching),
            .tainted = change(self.tainted, s.tainted),
        };
    }

    fn change(ch: Change, v: bool) bool {
        return switch (ch) {
            .keep => v,
            .set => true,
            .clear => false,
        };
    }

    /// The command named `name` comes next, `sub` its first argument (both
    /// upper-cased).
    fn add(self: *Effect, name: []const u8, sub: []const u8) void {
        const eql = std.mem.eql;
        if (eql(u8, name, "MULTI")) {
            self.multi = .set;
        } else if (eql(u8, name, "EXEC") or eql(u8, name, "DISCARD")) {
            self.multi = .clear;
            self.watching = .clear;
        } else if (eql(u8, name, "WATCH")) {
            self.watching = .set;
        } else if (eql(u8, name, "UNWATCH")) {
            self.watching = .clear;
        } else if (eql(u8, name, "CLIENT")) {
            for (tainting_client) |t| if (eql(u8, sub, t)) {
                self.tainted = .set;
            };
        } else for (tainting) |t| {
            if (eql(u8, name, t)) self.tainted = .set;
        }
    }
};

/// Writes commands as RESP into an arena.
const Builder = struct {
    out: std.Io.Writer.Allocating,
    batch: Batch = .{},

    fn init(arena: std.mem.Allocator) error{OutOfMemory}!Builder {
        return .{ .out = try .initCapacity(arena, 64) };
    }

    /// One command: a tuple of arguments, or a slice of strings.
    fn add(self: *Builder, args: anytype) error{ WriteFailed, EmptyCommand }!void {
        var scan: Scan = .{};
        try eachArg(args, &scan);
        if (scan.n == 0) return error.EmptyCommand;
        const w = &self.out.writer;
        try w.print("*{d}\r\n", .{scan.n});
        var enc: Encode = .{ .w = w };
        try eachArg(args, &enc);
        const b = &self.batch;
        if (b.count == 0) {
            b.name_buf = scan.name;
            b.name_len = scan.name_len;
        }
        b.count += 1;
        b.args = scan.n;
        b.effect.add(scan.name[0..scan.name_len], scan.sub[0..scan.sub_len]);
    }

    /// Several commands: a tuple of them, or a slice.
    fn addAll(self: *Builder, commands: anytype) error{ WriteFailed, EmptyCommand }!void {
        const T = @TypeOf(commands);
        const wrong = "anole.redis: a pipeline is a tuple or slice of commands, not " ++ @typeName(T);
        switch (@typeInfo(T)) {
            .pointer => |p| switch (p.size) {
                .one => return self.addAll(commands.*),
                .slice => for (commands) |cmd| try self.add(cmd),
                else => @compileError(wrong),
            },
            .array => for (commands) |cmd| try self.add(cmd),
            .@"struct" => |s| {
                if (!s.is_tuple) @compileError(wrong);
                inline for (s.field_types, 0..) |_, i| try self.add(commands[i]);
            },
            else => @compileError(wrong),
        }
        if (self.batch.count == 0) return error.EmptyCommand;
    }

    fn finish(self: *Builder) Batch {
        var b = self.batch;
        b.bytes = self.out.written();
        return b;
    }
};

/// Counts a command's arguments and keeps its name and first argument
/// (a subcommand's name), upper-cased.
const Scan = struct {
    n: usize = 0,
    name: [16]u8 = undefined,
    name_len: usize = 0,
    sub: [16]u8 = undefined,
    sub_len: usize = 0,

    fn arg(self: *Scan, bytes: []const u8) error{WriteFailed}!void {
        if (self.n == 0) self.name_len = upper(&self.name, bytes);
        if (self.n == 1) self.sub_len = upper(&self.sub, bytes);
        self.n += 1;
    }

    fn upper(out: *[16]u8, bytes: []const u8) usize {
        const n = @min(bytes.len, out.len);
        for (bytes[0..n], out[0..n]) |ch, *o| o.* = std.ascii.toUpper(ch);
        return n;
    }
};

const Encode = struct {
    w: *std.Io.Writer,

    fn arg(self: *Encode, bytes: []const u8) error{WriteFailed}!void {
        try self.w.print("${d}\r\n", .{bytes.len});
        try self.w.writeAll(bytes);
        try self.w.writeAll("\r\n");
    }
};

/// Calls `visitor.arg` with each argument `v` makes, as text: strings as
/// they are, numbers in decimal, bools as 1 or 0, enums by name, nulls
/// not at all, slices, arrays and tuples item by item, a struct as its
/// field names and values (null fields left out).
fn eachArg(v: anytype, visitor: anytype) error{WriteFailed}!void {
    const T = @TypeOf(v);
    const wrong = "anole.redis: cannot send " ++ @typeName(T) ++ " as an argument";
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) return visitor.arg(v) else for (v) |x| try eachArg(x, visitor),
                else => return eachArg(v.*, visitor),
            },
            .slice => if (p.child == u8) return visitor.arg(v) else for (v) |x| try eachArg(x, visitor),
            else => @compileError(wrong),
        },
        .array => |a| if (a.child == u8) return visitor.arg(&v) else for (v) |x| try eachArg(x, visitor),
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_types, 0..) |_, i| try eachArg(v[i], visitor);
        } else {
            inline for (s.field_names, s.field_types) |name, F| {
                const value = @field(v, name);
                if (@typeInfo(F) != .optional or value != null) {
                    try visitor.arg(name);
                    try eachArg(value, visitor);
                }
            }
        },
        .int, .comptime_int => {
            var buf: [48]u8 = undefined;
            return visitor.arg(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
        },
        .float, .comptime_float => {
            const x: f64 = v;
            if (std.math.isInf(x)) return visitor.arg(if (x > 0) "+inf" else "-inf");
            var buf: [512]u8 = undefined;
            return visitor.arg(std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable);
        },
        .bool => return visitor.arg(if (v) "1" else "0"),
        .@"enum", .enum_literal => return visitor.arg(@tagName(v)),
        .optional => if (v) |x| try eachArg(x, visitor),
        .null => {},
        else => @compileError(wrong),
    }
}

// ---------------------------------------------------------------------------
// Replies.

/// How deep replies may nest (hiredis allows 1024); deeper is a protocol
/// error. Redis's own replies nest a few levels.
const max_reply_depth = 32;

fn convert(arena: std.mem.Allocator, r: *hiredis.redisReply) error{ ProtocolError, OutOfMemory }!Reply {
    const bytes = if (r.str) |s| s[0..r.len] else "";
    return switch (r.type) {
        hiredis.REDIS_REPLY_NIL => .nil,
        hiredis.REDIS_REPLY_STATUS => .{ .status = try arena.dupe(u8, bytes) },
        hiredis.REDIS_REPLY_ERROR => .{ .err = try arena.dupe(u8, bytes) },
        hiredis.REDIS_REPLY_INTEGER => .{ .int = r.integer },
        hiredis.REDIS_REPLY_STRING, hiredis.REDIS_REPLY_VERB, hiredis.REDIS_REPLY_BIGNUM => .{ .string = try arena.dupe(u8, bytes) },
        hiredis.REDIS_REPLY_DOUBLE => .{ .double = r.dval },
        hiredis.REDIS_REPLY_BOOL => .{ .boolean = r.integer != 0 },
        hiredis.REDIS_REPLY_ARRAY, hiredis.REDIS_REPLY_SET, hiredis.REDIS_REPLY_PUSH, hiredis.REDIS_REPLY_MAP, hiredis.REDIS_REPLY_ATTR => blk: {
            const items = try arena.alloc(Reply, r.elements);
            for (items, 0..) |*item, i| item.* = try convert(arena, r.element[i]);
            break :blk if (r.type == hiredis.REDIS_REPLY_MAP or r.type == hiredis.REDIS_REPLY_ATTR) .{ .map = items } else .{ .array = items };
        },
        else => error.ProtocolError,
    };
}

/// How `call` reads the replies.
const Mode = enum { reply, replies, one, optional, all };

fn Out(comptime T: type, comptime mode: Mode) type {
    return switch (mode) {
        .reply => Reply,
        .replies => []Reply,
        .one => T,
        .optional => ?T,
        .all => []T,
    };
}

/// Whether `r` is no value for a `T`: nil, or a hash without fields for a
/// struct.
fn none(comptime T: type, r: Reply) bool {
    if (r == .nil) return true;
    if (comptime T != Reply and @typeInfo(T) == .@"struct") return switch (r) {
        .array, .map => |a| a.len == 0,
        else => false,
    };
    return false;
}

/// Where a reply is read into a type, for the message when it does not fit.
const Decoder = struct {
    ctx: *const Ctx,
    map: db.ErrorMap,
    /// The command.
    name: []const u8,

    fn mismatch(self: *const Decoder, comptime T: type, r: Reply) db.Error {
        return self.ctx.failf(self.map, .other, "{s} replied {s}, which {s} cannot hold", .{ self.name, describe(r), @typeName(T) });
    }
};

fn describe(r: Reply) []const u8 {
    return switch (r) {
        .nil => "nil (read it into an optional)",
        .status => "a status",
        .err => "an error",
        .int => "an integer",
        .string => "a string",
        .double => "a double",
        .boolean => "a boolean",
        .array => "an array",
        .map => "a map",
    };
}

/// `r` as a `T`; strings copied (or formatted) into the context's arena.
fn decode(comptime T: type, r: Reply, d: *const Decoder) Error!T {
    if (T == Reply) return r;
    const arena = d.ctx.arena;
    switch (@typeInfo(T)) {
        .optional => |o| return if (r == .nil) null else try decode(o.child, r, d),
        .void => return,
        .bool => return switch (r) {
            .int => |n| n != 0,
            .boolean => |b| b,
            .status => |s| std.mem.eql(u8, s, "OK"),
            .string => |s| if (std.mem.eql(u8, s, "1")) true else if (std.mem.eql(u8, s, "0")) false else d.mismatch(T, r),
            else => d.mismatch(T, r),
        },
        .int => return switch (r) {
            .int => |n| std.math.cast(T, n) orelse d.mismatch(T, r),
            .string, .status => |s| std.fmt.parseInt(T, s, 10) catch d.mismatch(T, r),
            .boolean => |b| @intFromBool(b),
            else => d.mismatch(T, r),
        },
        .float => return switch (r) {
            .double => |x| @floatCast(x),
            .int => |n| @floatFromInt(n),
            .string, .status => |s| std.fmt.parseFloat(T, s) catch d.mismatch(T, r),
            else => d.mismatch(T, r),
        },
        .@"enum" => {
            const s = r.text() orelse return d.mismatch(T, r);
            return std.meta.stringToEnum(T, s) orelse d.mismatch(T, r);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("anole.redis: cannot read a reply into " ++ @typeName(T));
            if (p.child == u8) return switch (r) {
                .string, .status => |s| s,
                .int => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
                .double => |x| try std.fmt.allocPrint(arena, "{d}", .{x}),
                else => d.mismatch(T, r),
            };
            const items = switch (r) {
                .array, .map => |a| a,
                .nil => &[_]Reply{},
                else => return d.mismatch(T, r),
            };
            const out = try arena.alloc(p.child, items.len);
            for (out, items) |*o, item| o.* = try decode(p.child, item, d);
            return out;
        },
        .@"struct" => |s| {
            if (s.is_tuple) @compileError("anole.redis: cannot read a reply into a tuple; use a struct or []Reply");
            // A hash: field, value, field, value... (RESP2 HGETALL, or a
            // RESP3 map).
            const pairs = switch (r) {
                .array, .map => |a| a,
                else => return d.mismatch(T, r),
            };
            if (pairs.len % 2 != 0) return d.mismatch(T, r);
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                var found: ?Reply = null;
                var i: usize = 0;
                while (i < pairs.len) : (i += 2) {
                    if (std.mem.eql(u8, pairs[i].text() orelse "", name)) {
                        found = pairs[i + 1];
                        break;
                    }
                }
                if (found) |v| {
                    @field(out, name) = try decode(F, v, d);
                } else if (attrs.default_value_ptr != null) {
                    @field(out, name) = attrs.defaultValue(F).?;
                } else {
                    // Kept for `lastError` and logged as a 500; the error is its own.
                    _ = @intFromError(d.ctx.failf(d.map, .other, "{s}: the hash has no field \"{s}\", and {s} has no default for it", .{ d.name, name, @typeName(T) }));
                    return error.MissingColumn;
                }
            }
            return out;
        },
        else => @compileError("anole.redis: cannot read a reply into " ++ @typeName(T)),
    }
}

/// An error reply's code: its first word ("WRONGTYPE", "ERR").
fn errorCode(message: []const u8) []const u8 {
    return message[0 .. std.mem.indexOfScalar(u8, message, ' ') orelse message.len];
}

/// The class of an error reply (`anole.db.Class`): `unavailable` when the
/// server cannot serve now (loading, a replica, out of memory, a script
/// running, a login refused), else `other`.
fn classify(message: []const u8) db.Class {
    const code = errorCode(message);
    for ([_][]const u8{ "LOADING", "MASTERDOWN", "BUSY", "TRYAGAIN", "CLUSTERDOWN", "READONLY", "NOREPLICAS", "MISCONF", "OOM", "NOAUTH", "WRONGPASS" }) |u| {
        if (std.mem.eql(u8, code, u)) return .unavailable;
    }
    return .other;
}

// The caller's context, type-erased: a request or an `anole.db.Ctx`.
const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    any: *anyopaque,
    record: *const fn (any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error,
    request: ?*const dusty.Request,
    last: *const fn (any: *anyopaque) ?db.ErrorDetail,

    /// The last error recorded on the context it stands for.
    pub fn lastDetail(self: *const Ctx) ?db.ErrorDetail {
        return self.last(self.any);
    }

    /// `internal.fail` on the context it stands for.
    pub fn fail(self: *const Ctx, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
        return self.record(self.any, map, detail);
    }

    fn failf(self: *const Ctx, map: db.ErrorMap, class: db.Class, comptime fmt: []const u8, args: anytype) db.Error {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch "(message lost: out of memory)";
        return self.fail(map, .{ .system = .redis, .class = class, .message = message });
    }
};

fn erase(c: anytype) Ctx {
    const C = @TypeOf(c);
    if (C == *Ctx or C == *const Ctx) return c.*;
    const R = struct {
        fn record(any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
            return internal.fail(@as(C, @ptrCast(@alignCast(any))), map, detail);
        }
        fn last(any: *anyopaque) ?db.ErrorDetail {
            return internal.lastError(@as(C, @ptrCast(@alignCast(any))));
        }
    };
    return .{ .io = c.io, .arena = c.arena, .any = @ptrCast(c), .record = R.record, .last = R.last, .request = internal.requestOf(c) };
}

// ---------------------------------------------------------------------------
// Tests. Those against a live server are in live_test.zig
// (`-Dredis-test-url=redis://...`, or `-Dredis-test-port`;
// tests/redis/run.sh).

const testing = std.testing;

test {
    _ = @import("live_test.zig");
}

/// What `args` encodes to.
fn encoded(arena: std.mem.Allocator, args: anytype) ![]const u8 {
    var b: Builder = try .init(arena);
    try b.add(args);
    return b.finish().bytes;
}

/// An environment of `vars` ("NAME=value").
fn environ(comptime vars: []const [:0]const u8) std.process.Environ {
    const block = comptime blk: {
        var out: [vars.len:null]?[*:0]const u8 = undefined;
        for (vars, 0..) |v, i| out[i] = v.ptr;
        break :blk out;
    };
    const S = struct {
        const kept = block;
    };
    return .{ .block = .{ .slice = &S.kept } };
}

test "redis: arguments encode as RESP (numbers, bools, enums, nulls, binary, flattened slices and structs)" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", try encoded(a, .{ "GET", "k" }));
    // A slice of strings, and a pointer to a tuple.
    const slice: []const []const u8 = &.{ "GET", "k" };
    try testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", try encoded(a, slice));
    try testing.expectEqualStrings("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n", try encoded(a, &.{ "GET", "k" }));
    // Numbers, bools, enums, nulls, binary.
    const Color = enum { red };
    const no: ?[]const u8 = null;
    try testing.expectEqualStrings(
        "*8\r\n$3\r\nSET\r\n$3\r\na\x00b\r\n$2\r\n-7\r\n$3\r\n1.5\r\n$4\r\n+inf\r\n$1\r\n1\r\n$3\r\nred\r\n$2\r\nNX\r\n",
        try encoded(a, .{ "SET", "a\x00b", @as(i32, -7), @as(f64, 1.5), std.math.inf(f64), true, Color.red, no, "NX" }),
    );
    // Slices and tuples flatten; a struct is its fields and values.
    const keys: []const []const u8 = &.{ "a", "b" };
    try testing.expectEqualStrings("*4\r\n$3\r\nDEL\r\n$1\r\na\r\n$1\r\nb\r\n$1\r\nc\r\n", try encoded(a, .{ "DEL", keys, .{"c"} }));
    const User = struct { name: []const u8, age: u8, nick: ?[]const u8 = null };
    try testing.expectEqualStrings(
        "*6\r\n$4\r\nHSET\r\n$1\r\nu\r\n$4\r\nname\r\n$3\r\nAda\r\n$3\r\nage\r\n$2\r\n36\r\n",
        try encoded(a, .{ "HSET", "u", User{ .name = "Ada", .age = 36 } }),
    );
    try testing.expectError(error.EmptyCommand, encoded(a, .{ no, .{} }));
}

test "redis: a batch that leaves MULTI open or changes the session taints its connection" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var b: Builder = try .init(a);
    try b.addAll(.{ .{ "watch", "k" }, .{"MULTI"}, .{ "INCR", "k" }, .{"EXEC"} });
    const batch = b.finish();
    try testing.expectEqual(@as(usize, 4), batch.count);
    try testing.expectEqualStrings("PIPELINE", batch.operation());
    const after = batch.effect.apply(.{});
    try testing.expect(!after.multi and !after.watching and !after.tainted);
    var b2: Builder = try .init(a);
    try b2.addAll(@as([]const []const []const u8, &.{ &.{"MULTI"}, &.{ "SELECT", "2" } }));
    const left = b2.finish().effect.apply(.{});
    try testing.expect(left.multi and left.tainted);
    var b3: Builder = try .init(a);
    try b3.add(.{ "CLIENT", "ID" });
    try testing.expect(!b3.finish().effect.apply(.{}).tainted);
    try b3.add(.{ "client", "setname", "worker" });
    try testing.expect(b3.finish().effect.apply(.{}).tainted);
}

test "redis: settings from a URL and REDIS_URL" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;

    const defaults = try Settings.resolve(a, .{ .environ = .empty });
    try testing.expectEqualStrings("redis://127.0.0.1:6379/0", try std.fmt.bufPrint(&buf, "{f}", .{defaults}));

    const full = try Settings.resolve(a, .{ .url = "rediss://app:s3cret@cache.internal:6380/2?ssl_ca_certs=/etc/ca.pem", .environ = .empty });
    try testing.expect(full.tls and full.verify);
    try testing.expectEqualStrings("app", full.username.?);
    try testing.expectEqualStrings("s3cret", full.password.?);
    try testing.expectEqual(@as(u32, 2), full.database);
    try testing.expectEqualStrings("/etc/ca.pem", full.ca_file.?);
    try testing.expectEqualStrings("rediss://app@cache.internal:6380/2", try std.fmt.bufPrint(&buf, "{f}", .{full}));

    // The password alone (the default user), and a self-signed managed server.
    const managed = try Settings.resolve(a, .{ .url = "rediss://:pw@ec2.example.com:6380?ssl_cert_reqs=none", .environ = .empty });
    try testing.expect(managed.username == null and !managed.verify);
    try testing.expectEqualStrings("pw", managed.password.?);

    const unix = try Settings.resolve(a, .{ .url = "unix:///run/redis.sock?db=3", .environ = .empty });
    try testing.expectEqualStrings("/run/redis.sock", unix.unix_path.?);
    try testing.expectEqual(@as(u32, 3), unix.database);

    const ipv6 = try Settings.resolve(a, .{ .url = "redis://[::1]:7000", .environ = .empty });
    try testing.expectEqualStrings("redis://[::1]:7000/0", try std.fmt.bufPrint(&buf, "{f}", .{ipv6}));

    if (@TypeOf(std.process.Environ.empty.block) == std.process.Environ.PosixBlock) {
        const from_env = try Settings.resolve(a, .{ .environ = environ(&.{"REDIS_URL=redis://from-env:6390/1"}) });
        try testing.expectEqualStrings("from-env", from_env.host);
        try testing.expectEqual(@as(u16, 6390), from_env.port);
        try testing.expectEqual(@as(u32, 1), from_env.database);
    }

    // Refused with a reason (which `resolve` logs).
    for ([_][]const u8{
        "http://localhost",
        "redis://a,b",
        "redis://localhost/zero",
        "redis://localhost?ssl_ca_certs=/x",
        "rediss://localhost?ssl_cert_reqs=maybe",
        "rediss://localhost?ssl_certfile=/c",
        "redis://localhost?pool_size=3",
        "redis://someone@localhost",
        "unix://",
    }) |url| {
        var why: ?[]const u8 = null;
        if (Settings.parse(a, .{ .url = url, .environ = .empty }, &why)) |_| {
            std.debug.print("accepted: {s}\n", .{url});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.InvalidDatabaseUrl, err);
        try testing.expectStringStartsWith(why.?, "cannot use the URL ");
    }
}

test "redis: error replies by class" {
    try testing.expectEqual(db.Class.unavailable, classify("LOADING Redis is loading the dataset in memory"));
    try testing.expectEqual(db.Class.unavailable, classify("MASTERDOWN Link with MASTER is down"));
    try testing.expectEqual(db.Class.unavailable, classify("READONLY You can't write against a read only replica."));
    try testing.expectEqual(db.Class.unavailable, classify("WRONGPASS invalid username-password pair"));
    try testing.expectEqual(db.Class.other, classify("WRONGTYPE Operation against a key holding the wrong kind of value"));
    try testing.expectEqual(db.Class.other, classify("BUSYKEY Target key name already exists."));
    try testing.expectEqual(db.Class.other, classify("ERR unknown command"));
    try testing.expectEqualStrings("ERR", errorCode("ERR unknown command"));
    try testing.expectEqualStrings("OOM", errorCode("OOM"));
}

test "redis: replies into types" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = testing.io, .arena = arena_state.allocator() };
    const ctx = erase(&c);
    const d: Decoder = .{ .ctx = &ctx, .map = .{}, .name = "TEST" };

    try testing.expectEqual(@as(i64, 42), try decode(i64, .{ .int = 42 }, &d));
    try testing.expectEqual(@as(u16, 7), try decode(u16, .{ .string = "7" }, &d));
    try testing.expectEqual(@as(f64, 2.5), try decode(f64, .{ .string = "2.5" }, &d));
    try testing.expect(std.math.isInf(try decode(f64, .{ .string = "inf" }, &d)));
    try testing.expect(try decode(bool, .{ .status = "OK" }, &d));
    try testing.expect(!try decode(bool, .{ .int = 0 }, &d));
    try testing.expectEqualStrings("12", try decode([]const u8, .{ .int = 12 }, &d));
    try testing.expectEqual(@as(?[]const u8, null), try decode(?[]const u8, .nil, &d));
    var items = [_]Reply{ .{ .string = "a" }, .nil, .{ .string = "c" } };
    const got = try decode([]const ?[]const u8, .{ .array = &items }, &d);
    try testing.expectEqualStrings("c", got[2].?);
    try testing.expect(got[1] == null);

    const Plan = enum { free, pro };
    const Profile = struct { name: []const u8, visits: u32, plan: Plan = .free, bio: ?[]const u8 = null };
    var pairs = [_]Reply{ .{ .string = "visits" }, .{ .string = "3" }, .{ .string = "name" }, .{ .string = "Ada" }, .{ .string = "extra" }, .{ .string = "x" } };
    const p = try decode(Profile, .{ .array = &pairs }, &d);
    try testing.expectEqualStrings("Ada", p.name);
    try testing.expectEqual(@as(u32, 3), p.visits);
    try testing.expectEqual(Plan.free, p.plan);
    try testing.expect(p.bio == null);
    try testing.expect(none(Profile, .{ .array = &.{} }));
    try testing.expect(!none([]const []const u8, .{ .array = &.{} }));

    // What does not fit is a 500, with the reason kept.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.Database, decode(u8, .{ .int = 300 }, &d));
    try testing.expectError(error.Database, decode(i64, .{ .string = "abc" }, &d));
    try testing.expectStringStartsWith(db.lastError(&c).?.message, "TEST replied a string");
    var missing = [_]Reply{ .{ .string = "name" }, .{ .string = "x" } };
    try testing.expectError(error.MissingColumn, decode(Profile, .{ .array = &missing }, &d));
}

/// A fake server: answers each RESP command it reads with a canned reply,
/// and counts the connections it accepted.
/// `depth` arrays, each the only element of the one before, around an
/// integer.
fn nested(comptime depth: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    var out: []const u8 = "";
    for (0..depth) |_| out = out ++ "*1\r\n";
    return out ++ ":1\r\n";
}

const Fake = struct {
    listener: std.Io.net.Server,
    accepted: std.atomic.Value(u32) = .init(0),
    /// GETs and INCRs answered; while `shared_gate` is set to an event, a
    /// GET of "shared" waits for it first.
    gets: std.atomic.Value(u32) = .init(0),
    shared_gate: std.atomic.Value(?*std.Io.Event) = .init(null),
    incrs: std.atomic.Value(u32) = .init(0),
    /// "filled" is nil to GET until a SET of it.
    filled: std.atomic.Value(bool) = .init(false),
    /// PINGs read; while `ping_gate` is set to an event, a PING waits for
    /// it before the answer.
    pings: std.atomic.Value(u32) = .init(0),
    ping_gate: std.atomic.Value(?*std.Io.Event) = .init(null),

    fn port(self: *Fake) u16 {
        return self.listener.socket.address.getPort();
    }

    fn serve(self: *Fake, io: std.Io) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const conn = try self.listener.accept(io);
            _ = self.accepted.fetchAdd(1, .monotonic);
            group.concurrent(io, session, .{ self, conn, io }) catch conn.close(io);
        }
    }

    fn session(self: *Fake, conn: std.Io.net.Stream, io: std.Io) void {
        defer conn.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        var w = conn.writer(io, &wbuf);
        while (true) {
            // "*<n>\r\n" then n bulk strings.
            const head = r.interface.takeDelimiterInclusive('\n') catch return;
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, head[1..], "\r\n"), 10) catch return;
            var words: [2][32]u8 = undefined;
            var lens: [2]usize = @splat(0);
            for (0..n) |i| {
                const len_line = r.interface.takeDelimiterInclusive('\n') catch return;
                const len = std.fmt.parseInt(usize, std.mem.trim(u8, len_line[1..], "\r\n"), 10) catch return;
                const arg = r.interface.take(len + 2) catch return;
                if (i < words.len) {
                    lens[i] = @min(len, 32);
                    @memcpy(words[i][0..lens[i]], arg[0..lens[i]]);
                }
            }
            const cmd = words[0][0..lens[0]];
            const eql = std.mem.eql;
            if (eql(u8, cmd, "GET")) {
                _ = self.gets.fetchAdd(1, .monotonic);
                if (eql(u8, words[1][0..lens[1]], "shared")) if (self.shared_gate.load(.acquire)) |gate| gate.wait(io) catch return;
            }
            if (eql(u8, cmd, "INCR")) _ = self.incrs.fetchAdd(1, .monotonic);
            if (eql(u8, cmd, "PING")) {
                _ = self.pings.fetchAdd(1, .release);
                if (self.ping_gate.load(.acquire)) |gate| gate.wait(io) catch return;
            }
            const key = words[1][0..lens[1]];
            if (eql(u8, cmd, "SET") and eql(u8, key, "filled")) self.filled.store(true, .monotonic);
            const nil = eql(u8, key, "missing") or (eql(u8, key, "filled") and !self.filled.load(.monotonic));
            const reply: []const u8 = if (eql(u8, cmd, "SET") or eql(u8, cmd, "MULTI"))
                "+OK\r\n"
            else if (eql(u8, cmd, "GET"))
                (if (nil) "$-1\r\n" else "$5\r\nvalue\r\n")
            else if (eql(u8, cmd, "INCR"))
                ":42\r\n"
            else if (eql(u8, cmd, "HGETALL"))
                "*4\r\n$4\r\nname\r\n$3\r\nAda\r\n$6\r\nvisits\r\n$1\r\n3\r\n"
            else if (eql(u8, cmd, "KEYS"))
                "*2\r\n$1\r\na\r\n$1\r\nb\r\n"
            else if (eql(u8, cmd, "LPUSH"))
                "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
            else if (eql(u8, cmd, "DEBUG"))
                "-LOADING Redis is loading the dataset in memory\r\n"
            else if (eql(u8, cmd, "PING"))
                "+PONG\r\n"
            else if (eql(u8, cmd, "NESTED"))
                comptime nested(30)
            else if (eql(u8, cmd, "DEEP"))
                comptime nested(1000)
            else if (eql(u8, cmd, "SLOW")) blk: {
                io.sleep(.fromSeconds(5), .awake) catch return;
                break :blk "+late\r\n";
            } else "-ERR unknown command\r\n";
            w.interface.writeAll(reply) catch return;
            w.interface.flush() catch return;
        }
    }
};

test "redis: cache-aside: keep_empty = false asks again after nil; lastSource for X-Cache" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    // nil is not kept: each GET goes to the server until the value is
    // there, and then the value is kept.
    const aside = client.with(.{ .cache = .{ .ttl = .fromSeconds(60), .keep_empty = false } });
    try testing.expect(try aside.get(&c, "filled") == null);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expect(try aside.get(&c, "filled") == null);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    // The miss filled in, as cache-aside does: no invalidation needed.
    _ = try client.set(&c, "filled", "value", .{});
    try testing.expectEqualStrings("value", (try aside.get(&c, "filled")).?);
    try testing.expectEqual(@as(?db.Source, .database), db.lastSource(&c));
    try testing.expectEqualStrings("value", (try aside.get(&c, "filled")).?);
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 3), fake.gets.load(.monotonic));

    // By default nil is kept like any reply.
    const keeping = client.with(.{ .cache = .{ .ttl = .fromSeconds(60) } });
    try testing.expect(try keeping.get(&c, "missing") == null);
    try testing.expect(try keeping.get(&c, "missing") == null);
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
    try testing.expectEqual(@as(u32, 4), fake.gets.load(.monotonic));
    // A plain call leaves the last source as it was.
    _ = try client.get(&c, "missing");
    try testing.expectEqual(@as(?db.Source, .cache), db.lastSource(&c));
}

test "redis: calls over a fake server: replies decode into the asked types, all on one connection" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    try testing.expectEqualStrings("OK", (try client.command(&c, .{ "SET", "k", "value" })).status);
    try testing.expectEqualStrings("value", (try client.get(&c, "k")).?);
    try testing.expect(try client.get(&c, "missing") == null);
    try testing.expectError(error.NotFound, client.one([]const u8, &c, .{ "GET", "missing" }));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expect(try client.set(&c, "k", 5, .{ .ttl = .fromMilliseconds(1500), .nx = true }));
    const Profile = struct { name: []const u8, visits: u32 };
    try testing.expectEqual(@as(u32, 3), (try client.hgetAll(Profile, &c, "u")).visits);
    const keys = try client.all([]const u8, &c, .{"KEYS"});
    try testing.expectEqualStrings("b", keys[1]);
    const replies = try client.pipeline(&c, .{ .{"KEYS"}, .{ "INCR", "n" } });
    try testing.expectEqual(@as(i64, 42), replies[1].int);
    // All of it on one connection, opened once.
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
}

test "redis: a server error is a 500 (LOADING a 503) and keeps the connection; a pipeline fails with its first error; a reply of the wrong type is a 500" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    // A server error: a 500, the message for the logs; the connection is fine.
    try testing.expectError(error.Database, client.lpush(&c, "k", "x"));
    try testing.expectEqualStrings("WRONGTYPE", db.lastError(&c).?.code);
    try testing.expectError(error.ServiceUnavailable, client.command(&c, .{"DEBUG"}));
    // A pipeline reads every reply, then fails with the first error.
    try testing.expectError(error.Database, client.pipeline(&c, .{ .{ "LPUSH", "k", "x" }, .{ "INCR", "n" } }));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
    // A reply of the wrong type for what was asked: a 500.
    try testing.expectError(error.Database, client.one(i64, &c, .{"KEYS"}));
}

test "redis: replies nested as deep as Redis's own decode; deeper is a broken connection, refused before recursing" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var r = try client.command(&c, .{"NESTED"});
    for (0..30) |_| r = r.array[0];
    try testing.expectEqual(@as(i64, 1), r.int);
    try testing.expectError(error.ServiceUnavailable, client.command(&c, .{"DEEP"}));
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: a call past its timeout is a 504, and its connection is closed rather than reused" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    // The reply is still to come when the timeout ends the call.
    try testing.expectError(error.GatewayTimeout, client.with(.{ .timeout = .fromMilliseconds(50) }).command(&c, .{"SLOW"}));
    try testing.expectEqual(db.Class.timeout, db.lastError(&c).?.class);
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: a connection left in MULTI is not reused" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    try testing.expectEqual(@as(i64, 42), try client.incr(&c, "n"));
    _ = try client.command(&c, .{"MULTI"});
    _ = try client.incr(&c, "n");
    try testing.expectEqual(@as(u32, 2), fake.accepted.load(.monotonic));
}

test "redis: acquire runs its calls on one connection and gives it back" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 1 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    var conn = try client.acquire(&c);
    _ = try conn.incr(&c, "n");
    _ = try conn.get(&c, "k");
    conn.release();
    _ = try client.incr(&c, "n");
    try testing.expectEqual(@as(u32, 1), fake.accepted.load(.monotonic));
    try testing.expect(Client.ping(client, io));
}

test "redis: a connection released twice is never handed to two holders" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const expected_log = @import("../errors.zig").expectLog();
    defer expected_log.deinit();
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .max_connections = 2 });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };

    const first = try client.acquire(&c);
    first.release();
    // A second release of the same checkout gives nothing back.
    first.release();
    // Two holders at once: two connections, the second one dialed.
    var x = try client.acquire(&c);
    var y = try client.acquire(&c);
    try testing.expect(x.conn != y.conn);
    _ = try x.incr(&c, "n");
    _ = try y.incr(&c, "n");
    x.release();
    y.release();
}

/// A probe of `/readyz` on its own task: the task it runs on, the answer,
/// and whether it ended.
const ReadyProbe = struct {
    task: std.atomic.Value(?dusty.placement.Task) = .init(null),
    answer: ?bool = null,
    ended: std.atomic.Value(bool) = .init(false),

    /// `check`, then (`hold`) a wait an hour long that only a cancel ends.
    fn run(p: *ReadyProbe, io: std.Io, client: *Client, hold: bool) std.Io.Cancelable!void {
        defer p.ended.store(true, .release);
        p.task.store(dusty.placement.currentTask(io), .release);
        p.answer = db.Readiness.check(&client.readiness);
        if (hold) try io.sleep(.fromSeconds(3600), .awake);
    }

    fn hasEnded(p: *ReadyProbe) bool {
        return p.ended.load(.acquire);
    }
};

fn pinged(fake: *Fake) bool {
    return fake.pings.load(.acquire) >= 1;
}

test "redis: a readiness probe canceled mid-ping stays canceled" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const wait = @import("anole_test_wait");

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var gate: std.Io.Event = .unset;
    fake.ping_gate.store(&gate, .release);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};
    defer gate.set(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .ping_timeout = .fromSeconds(3600) });
    defer client.deinit();

    var probe: ReadyProbe = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ReadyProbe.run, .{ &probe, io, client, true });
    try wait.waitUntil(io, "the probe's PING at the server", &fake, pinged);
    dusty.placement.cancelTask(probe.task.load(.acquire).?);
    // The cancel ends the ping, and the probe's task stays canceled: its
    // wait after the check ends at once.
    try wait.waitUntil(io, "the canceled probe's task ended", &probe, ReadyProbe.hasEnded);
}

test "redis: a readiness probe canceled mid-ping leaves no answer behind" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    const wait = @import("anole_test_wait");

    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var gate: std.Io.Event = .unset;
    fake.ping_gate.store(&gate, .release);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};
    defer gate.set(io);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()});
    const client = try Client.init(gpa, io, .{ .url = url, .environ = .empty, .ping_timeout = .fromSeconds(3600) });
    defer client.deinit();
    // An answer, once given, is kept for longer than any run of the test.
    client.readiness.ttl = .fromSeconds(3600);

    var probe: ReadyProbe = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ReadyProbe.run, .{ &probe, io, client, false });
    try wait.waitUntil(io, "the probe's PING at the server", &fake, pinged);
    dusty.placement.cancelTask(probe.task.load(.acquire).?);
    try wait.waitUntil(io, "the canceled probe's task ended", &probe, ReadyProbe.hasEnded);
    // The server answers from now on: the next probe pings again and is
    // ready, as nothing was kept from the canceled one.
    gate.set(io);
    try testing.expect(db.Readiness.check(&client.readiness));
    try testing.expectEqual(@as(u32, 2), fake.pings.load(.monotonic));
}

test "redis: a server that cannot be reached is a 503, and /readyz says so" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();
    // A port nothing listens on: one just closed.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{});
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{port}), .environ = .empty });
    defer client.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    try testing.expectError(error.ServiceUnavailable, client.get(&c, "k"));
    try testing.expectStringStartsWith(db.lastError(&c).?.message, "cannot connect to redis://127.0.0.1:");
    try testing.expect(!Client.ping(client, io));

    // A URL may not turn off the checks of a CA the code gives.
    if (has_tls) try testing.expectError(error.InvalidDatabaseUrl, Client.init(gpa, io, .{ .url = "rediss://cache.example.com?ssl_cert_reqs=none", .environ = .empty, .tls = .{ .ca = .system } }));
}

test "redis: a pool per executor" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(4) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty, .max_connections = 4 });
    defer client.deinit();

    const Worker = struct {
        fn run(cl: *Client, _io: std.Io, failed: *std.atomic.Value(u32)) void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var c: db.Ctx = .{ .io = _io, .arena = arena_state.allocator() };
            for (0..10) |_| _ = cl.incr(&c, "n") catch {
                _ = failed.fetchAdd(1, .monotonic);
            };
        }
    };
    var failed: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..8) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 4 }, Worker.run, .{ client, io, &failed });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failed.load(.monotonic));
    // Each executor's pool has a share of one, and opened it.
    try testing.expectEqual(@as(u32, 4), fake.accepted.load(.monotonic));
}

test "redis: coalesced and cached reads, invalidation" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: Fake = .{ .listener = try addr.listen(io, .{}) };
    defer fake.listener.deinit(io);
    var serving = try io.concurrent(Fake.serve, .{ &fake, io });
    defer serving.cancel(io) catch {};

    var url_buf: [64]u8 = undefined;
    const client = try Client.init(gpa, io, .{ .url = try std.fmt.bufPrint(&url_buf, "redis://127.0.0.1:{d}", .{fake.port()}), .environ = .empty });
    defer client.deinit();

    // 8 callers on each of 2 executors: one GET per executor.
    const Worker = struct {
        fn run(q: Query, io_: std.Io, bad: *std.atomic.Value(u32)) void {
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var c: db.Ctx = .{ .io = io_, .arena = arena_state.allocator() };
            const v = q.get(&c, "shared") catch null;
            if (v == null or !std.mem.eql(u8, v.?, "value")) _ = bad.fetchAdd(1, .monotonic);
        }
    };
    var bad: std.atomic.Value(u32) = .init(0);
    {
        // The GETs wait at the gate until the other 14 callers joined them,
        // however slow the machine is.
        var gate: std.Io.Event = .unset;
        defer gate.set(io);
        fake.shared_gate.store(&gate, .release);
        defer fake.shared_gate.store(null, .release);
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..16) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 2 }, Worker.run, .{ client.with(.{ .coalesce = true }), io, &bad });
        const Joined = struct {
            fn f(cl: *Client) bool {
                return cl.cache.stats().coalesced >= 14;
            }
        };
        try @import("anole_test_wait").waitUntil(io, "the 14 identical GETs joined the two in flight", client, Joined.f);
        gate.set(io);
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    try testing.expectEqual(@as(u64, 14), client.cache.stats().coalesced);

    // Cached: one GET per executor until invalidated by its tag.
    const cached = client.with(.{ .cache = .{ .ttl = .fromSeconds(60), .tag = "values" } });
    fake.gets.store(0, .monotonic);
    for (0..2) |_| {
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (0..8) |i| try dusty.placement.concurrent(&group, io, .{ .executor = i % 2 }, Worker.run, .{ cached, io, &bad });
        try group.await(io);
    }
    try testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    // The command's name in any case is one key; another key is another.
    _ = try cached.optional([]const u8, &c, .{ "get", "shared" });
    try testing.expectEqual(@as(u32, 2), fake.gets.load(.monotonic));
    _ = try cached.get(&c, "k");
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 3), fake.gets.load(.monotonic));
    // nil is a reply, and kept.
    try testing.expect(try cached.get(&c, "missing") == null);
    try testing.expect(try cached.get(&c, "missing") == null);
    try testing.expectEqual(@as(u32, 4), fake.gets.load(.monotonic));
    // A struct from HGETALL, kept as one.
    const Profile = struct { name: []const u8, visits: u32 };
    _ = try cached.hgetAll(Profile, &c, "u");
    try testing.expectEqualStrings("Ada", (try cached.hgetAll(Profile, &c, "u")).name);

    client.cache.invalidate(.{ .tag = "values" });
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 5), fake.gets.load(.monotonic));
    client.cache.invalidateQuery("GET", .{"k"});
    _ = try cached.get(&c, "k");
    try testing.expectEqual(@as(u32, 6), fake.gets.load(.monotonic));

    // Writes, `command`, pipelines and acquired connections never share.
    for (0..3) |_| _ = try cached.incr(&c, "n");
    try testing.expectEqual(@as(u32, 3), fake.incrs.load(.monotonic));
    _ = try cached.command(&c, .{ "GET", "k" });
    _ = try cached.pipeline(&c, .{.{ "GET", "k" }});
    var conn = try client.acquire(&c);
    _ = try conn.get(&c, "k");
    conn.release();
    _ = try client.get(&c, "k");
    try testing.expectEqual(@as(u32, 10), fake.gets.load(.monotonic));
}
