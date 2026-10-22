//! PostgreSQL (`-Dpostgres`): `anole.db`'s verbs on Anole's fork of
//! karlseguin/pg.zig (xuckless/pg.zig, MIT), with a pool per executor,
//! rows decoded into the request's arena, prepared statements kept per
//! connection, and server errors turned into statuses.
//!
//!     const App = struct { db: *anole.pg.Client };
//!     var state: App = undefined;
//!     var app = try anole.Server(App).init(gpa, .{}, &state);
//!     state.db = try app.postgres(.{}); // DATABASE_URL, else PG* variables, else localhost
//!
//!     const Post = struct { id: i64, body: []const u8, created_at: anole.db.Time };
//!
//!     fn list(app: *App, req: *anole.Request, res: *anole.Response) !void {
//!         const limit = req.query.getInt(u32, "limit") orelse 20;
//!         try res.json(try app.db.all(Post, req, "SELECT id, body, created_at FROM posts ORDER BY id DESC LIMIT $1", .{limit}));
//!     }
//!
//! See `anole.db` for the contract every connector keeps (the verbs,
//! `with`, errors and `lastError`, cancellation). What is PostgreSQL's:
//!
//! - Connections: the URL (`Options.url`, else `DATABASE_URL`) as libpq
//!   reads it, the `PG*` variables filling in what it leaves out:
//!   `postgres://user:password@host:5432/db?sslmode=verify-full`. A host
//!   that is a directory is a Unix socket's (`postgres://%2Fvar%2Frun%2Fpostgresql/app`).
//!   Parameters libpq has: `sslmode` (disable, allow, prefer (the default),
//!   require, verify-ca, verify-full), `sslrootcert`, `sslcert`, `sslkey`,
//!   `sslnegotiation=direct` (PostgreSQL 17), `application_name`,
//!   `connect_timeout` (seconds), `options`, `host`, `port`; pgx's
//!   `pool_max_conns`; any other is a run-time parameter the server sets
//!   for each connection (`?search_path=app&timezone=UTC`).
//! - Pools: `max_connections` split between the executors; a connection
//!   opens when a call first needs one.
//! - Statements: each connection prepares a statement the first time it
//!   runs it and keeps it (`statement_cache_size`), so later runs take one
//!   round trip. Behind PgBouncer older than 1.21 in transaction mode set
//!   `statement_cache_size = 0`, or `.prepare = false` per call.
//! - Rows: a struct's fields take the columns by name (`AS` renames);
//!   any integer type from int2/int4/int8 (checked for range), floats from
//!   float4/float8/numeric, `bool`, `[]const u8` from text-like columns
//!   (uuid as its text, jsonb as JSON, numeric as its digits), `anole.db.Time`
//!   from timestamp, timestamptz and date, enums from their labels,
//!   slices from arrays, structs and `std.json.Value` from json/jsonb, and
//!   pg.zig's own types (`anole.pg.driver.Numeric`...). A single column
//!   also reads into a plain type: `try app.db.one(i64, req, "SELECT count(*) FROM posts", .{})`.
//! - Parameters: pg.zig's, plus `anole.db.Time` (as a timestamp).
//! - Errors: SQLSTATE 23505 and 23P01 are `Conflict`, 40001 and 40P01
//!   too (and `transaction` retries them), 57014 is `GatewayTimeout`,
//!   connection failures, class 08, 53300 and 57P0x are
//!   `ServiceUnavailable`; the rest go by `Options.errors`.
//! - Cancellation: a call canceled in flight (the request's deadline, an
//!   HTTP/2 reset, `QueryOptions.timeout`) sends a CancelRequest so the
//!   server stops the statement, and the connection is closed.
const std = @import("std");
const features = @import("build_options");
const dusty = @import("dusty");
const db = @import("../db/root.zig");
const internal = @import("../db/internal.zig");
const observe = @import("../observe/root.zig");

/// pg.zig itself (xuckless/pg.zig), for `acquire`'s connection, its
/// types (`Numeric`, `Cidr`) and `listener`.
pub const driver = @import("anole_pg");
const pg = driver;
const dusty_tls = if (has_tls) @import("anole_dusty_tls") else struct {};

const has_tls = features.tls == .boringssl;
const log = std.log.scoped(.anole);
const placement = dusty.placement;
const Duration = std.Io.Duration;

/// What every call fails with: `anole.db.Error`, a cancel, or memory.
pub const Error = db.Error || error{ Canceled, OutOfMemory };

/// `app.postgres(options)` and `Client.init`: where the database is, the
/// pool's bounds and timeouts, TLS, and how errors map to statuses. Every
/// field has a default, so `.{}` connects from the environment.
pub const Options = struct {
    /// A `postgres://` or `postgresql://` URL. Null: `DATABASE_URL`, else
    /// libpq's variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`,
    /// `PGDATABASE`, `PGSSLMODE`...), else `postgres://postgres@127.0.0.1:5432/postgres`.
    url: ?[]const u8 = null,
    /// The database's name in metrics (`db` label), spans, `/readyz` and
    /// logs. Must outlive the connector.
    name: []const u8 = "postgres",
    /// Connections in all, split between the executors (at least one
    /// each). Null: the URL's `pool_max_conns`, else twice the number of
    /// executors, at least 4. A URL's `pool_max_conns` wins over this.
    max_connections: ?u32 = null,
    /// How long a call waits for one of its executor's connections when
    /// all are busy; then `ServiceUnavailable`.
    acquire_timeout: Duration = .fromSeconds(5),
    /// How long opening a connection may take (TCP, TLS and login). A URL's
    /// `connect_timeout` wins over this. Null: no limit.
    connect_timeout: ?Duration = .fromSeconds(10),
    /// Statements each connection keeps prepared, by their SQL. 0 behind
    /// PgBouncer older than 1.21 in transaction mode.
    statement_cache_size: u16 = 256,
    /// A connection older than this is closed instead of reused (so they
    /// move to a new primary after a failover). Null: no limit.
    max_lifetime: ?Duration = .fromSeconds(60 * 60),
    /// A connection idle this long is closed. Null: no limit.
    idle_timeout: ?Duration = .fromSeconds(30 * 60),
    /// What each class of server error becomes (`anole.db.ErrorMap`).
    errors: db.ErrorMap = .{},
    /// Certificates for TLS; whether TLS is used is the URL's `sslmode`.
    tls: Tls = .{},
    /// Open one connection per executor before serving, and fail the
    /// start if that fails. Off: connections open as calls need them, and
    /// a database that is down shows in `/readyz` and as 503s.
    connect_at_start: bool = false,
    /// `application_name`, unless the URL sets it.
    application_name: ?[]const u8 = null,
    /// What `/readyz` waits for the database's answer.
    ping_timeout: Duration = .fromSeconds(2),
    /// The bounds of the results kept for calls with `.cache`
    /// (`anole.db.QueryOptions`).
    cache: db.CacheOptions = .{},
    /// Where `DATABASE_URL` and the `PG*` variables come from; null: the
    /// process's environment (`app.postgres` passes `ServerOptions.process`'s).
    environ: ?std.process.Environ = null,

    /// Certificates beyond what the URL names (`Options.tls`).
    pub const Tls = struct {
        /// What `sslmode=verify-ca`/`verify-full` trust; null: the URL's
        /// `sslrootcert`, else the system's store.
        ca: ?dusty.TlsCa = null,
        /// A client certificate for servers that ask (`clientcert` in
        /// pg_hba.conf); null: the URL's `sslcert` and `sslkey`.
        client_certificate: ?dusty.TlsConfig.ClientCertificate = null,
    };
};

/// libpq's `sslmode`.
const SslMode = enum {
    disable,
    /// As `prefer` here (libpq tries plain text first).
    allow,
    /// TLS when the server has it, without checking its certificate.
    prefer,
    /// TLS, without checking the certificate (unless a root certificate is
    /// named: then as `verify_ca`, as libpq does).
    require,
    verify_ca,
    verify_full,

    /// Whether the mode refuses a connection without TLS.
    pub fn needsTls(mode: SslMode) bool {
        return switch (mode) {
            .disable, .allow, .prefer => false,
            .require, .verify_ca, .verify_full => true,
        };
    }
};

/// A connection's settings: the URL, the environment and `Options`,
/// resolved. Strings point into the arena `resolve` was given.
const Settings = struct {
    /// For TLS and logs; the socket's directory for a Unix socket.
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    /// The socket file, when `host` is a directory.
    unix_path: ?[]const u8 = null,
    user: []const u8 = "postgres",
    password: ?[]const u8 = null,
    database: []const u8 = "postgres",
    sslmode: SslMode = .prefer,
    sslrootcert: ?[]const u8 = null,
    sslcert: ?[]const u8 = null,
    sslkey: ?[]const u8 = null,
    direct_tls: bool = false,
    application_name: ?[]const u8 = null,
    connect_timeout: ?Duration = null,
    max_connections: ?u32 = null,
    /// Run-time parameters sent at login (`options` among them).
    parameters: []const db.Url.Param = &.{},

    /// Reads `opts.url` (else `DATABASE_URL`) over the `PG*` variables.
    /// A URL that cannot be used is logged, with the reason, and fails
    /// with `error.InvalidDatabaseUrl`.
    pub fn resolve(arena: std.mem.Allocator, opts: Options) !Settings {
        var why: Why = .{ .arena = arena };
        return parse(arena, opts, &why) catch |err| {
            if (why.text) |text| log.err("postgres: {s}", .{text});
            return err;
        };
    }

    /// Why `parse` refused the settings.
    const Why = struct {
        arena: std.mem.Allocator,
        text: ?[]const u8 = null,

        fn set(self: *Why, comptime fmt: []const u8, args: anytype) error{InvalidDatabaseUrl} {
            self.text = std.fmt.allocPrint(self.arena, fmt, args) catch null;
            return error.InvalidDatabaseUrl;
        }

        fn url(self: *Why, text: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidDatabaseUrl} {
            return self.set("cannot use the database URL {f}: " ++ fmt, .{db.redacted(text)} ++ args);
        }
    };

    fn parse(arena: std.mem.Allocator, opts: Options, why: *Why) !Settings {
        var s: Settings = .{};
        const env = opts.environ;
        if (db.env(env, "PGHOST")) |v| s.host = v;
        if (db.env(env, "PGPORT")) |v| s.port = std.fmt.parseInt(u16, v, 10) catch return why.set("PGPORT \"{s}\" is not a port number", .{v});
        if (db.env(env, "PGUSER")) |v| s.user = v;
        if (db.env(env, "PGPASSWORD")) |v| s.password = v;
        if (db.env(env, "PGDATABASE")) |v| s.database = v else s.database = s.user;
        if (db.env(env, "PGSSLMODE")) |v| s.sslmode = parseSslMode(v) catch return why.set("PGSSLMODE \"{s}\" is not one of disable, allow, prefer, require, verify-ca, verify-full", .{v});
        if (db.env(env, "PGSSLROOTCERT")) |v| s.sslrootcert = v;
        if (db.env(env, "PGSSLCERT")) |v| s.sslcert = v;
        if (db.env(env, "PGSSLKEY")) |v| s.sslkey = v;
        if (db.env(env, "PGSSLNEGOTIATION")) |v| s.direct_tls = parseNegotiation(v) catch return why.set("PGSSLNEGOTIATION \"{s}\" is not postgres or direct", .{v});
        if (db.env(env, "PGAPPNAME")) |v| s.application_name = v;
        if (db.env(env, "PGCONNECT_TIMEOUT")) |v| s.connect_timeout = parseSeconds(v) catch return why.set("PGCONNECT_TIMEOUT \"{s}\" is not a number of seconds", .{v});
        var parameters: std.ArrayList(db.Url.Param) = .empty;
        if (db.env(env, "PGOPTIONS")) |v| try parameters.append(arena, .{ .name = "options", .value = v });

        const text = opts.url orelse db.env(env, "DATABASE_URL") orelse {
            s.parameters = parameters.items;
            try s.finish(arena);
            return s;
        };
        const url = db.Url.parse(arena, text) catch |err| return why.url(text, "{t}", .{err});
        if (!std.mem.eql(u8, url.scheme, "postgres") and !std.mem.eql(u8, url.scheme, "postgresql"))
            return why.url(text, "the scheme is \"{s}\", not postgres or postgresql", .{url.scheme});
        if (url.hosts.len > 1) log.warn("postgres: the URL names {d} hosts; only the first is used", .{url.hosts.len});
        if (url.hosts.len > 0) {
            if (url.hosts[0].name.len > 0) s.host = url.hosts[0].name;
            if (url.hosts[0].port) |p| s.port = p;
        }
        const user = url.username orelse "";
        if (user.len > 0) {
            s.user = user;
            if (db.env(env, "PGDATABASE") == null) s.database = user;
        }
        if (url.password) |v| s.password = v;
        if (url.database().len > 0) s.database = url.database();
        for (url.params) |p| {
            const name = p.name;
            if (std.mem.eql(u8, name, "sslmode")) {
                s.sslmode = parseSslMode(p.value) catch return why.url(text, "sslmode \"{s}\" is not one of disable, allow, prefer, require, verify-ca, verify-full", .{p.value});
            } else if (std.mem.eql(u8, name, "sslrootcert")) {
                s.sslrootcert = p.value;
            } else if (std.mem.eql(u8, name, "sslcert")) {
                s.sslcert = p.value;
            } else if (std.mem.eql(u8, name, "sslkey")) {
                s.sslkey = p.value;
            } else if (std.mem.eql(u8, name, "sslnegotiation")) {
                s.direct_tls = parseNegotiation(p.value) catch return why.url(text, "sslnegotiation \"{s}\" is not postgres or direct", .{p.value});
            } else if (std.mem.eql(u8, name, "application_name")) {
                s.application_name = p.value;
            } else if (std.mem.eql(u8, name, "connect_timeout")) {
                s.connect_timeout = parseSeconds(p.value) catch return why.url(text, "connect_timeout \"{s}\" is not a number of seconds", .{p.value});
            } else if (std.mem.eql(u8, name, "pool_max_conns")) {
                s.max_connections = std.fmt.parseInt(u32, p.value, 10) catch return why.url(text, "pool_max_conns \"{s}\" is not a number", .{p.value});
                if (s.max_connections.? == 0) return why.url(text, "pool_max_conns is 0", .{});
            } else if (std.mem.eql(u8, name, "host")) {
                s.host = p.value;
            } else if (std.mem.eql(u8, name, "port")) {
                s.port = std.fmt.parseInt(u16, p.value, 10) catch return why.url(text, "port \"{s}\" is not a port number", .{p.value});
            } else if (std.mem.eql(u8, name, "user")) {
                s.user = p.value;
            } else if (std.mem.eql(u8, name, "password")) {
                s.password = p.value;
            } else if (std.mem.eql(u8, name, "dbname")) {
                s.database = p.value;
            } else if (std.mem.startsWith(u8, name, "ssl") or std.mem.eql(u8, name, "target_session_attrs") or
                std.mem.eql(u8, name, "gssencmode") or std.mem.eql(u8, name, "channel_binding"))
            {
                return why.url(text, "the parameter {s} is not supported", .{name});
            } else {
                try parameters.append(arena, p);
            }
        }
        s.parameters = parameters.items;
        try s.finish(arena);
        return s;
    }

    fn finish(s: *Settings, arena: std.mem.Allocator) !void {
        if (s.host.len > 0 and s.host[0] == '/') {
            s.unix_path = try std.fmt.allocPrint(arena, "{s}/.s.PGSQL.{d}", .{ std.mem.trimEnd(u8, s.host, "/"), s.port });
        }
        // libpq: `require` with a root certificate checks the chain.
        if (s.sslmode == .require and s.sslrootcert != null) s.sslmode = .verify_ca;
    }

    fn parseSeconds(text: []const u8) !?Duration {
        const n = try std.fmt.parseInt(u32, text, 10);
        // libpq: 0 means none.
        return if (n == 0) null else .fromSeconds(n);
    }

    fn parseSslMode(text: []const u8) !SslMode {
        var buf: [16]u8 = undefined;
        if (text.len > buf.len) return error.InvalidDatabaseUrl;
        for (text, buf[0..text.len]) |ch, *o| o.* = if (ch == '-') '_' else ch;
        return std.meta.stringToEnum(SslMode, buf[0..text.len]) orelse error.InvalidDatabaseUrl;
    }

    fn parseNegotiation(text: []const u8) !bool {
        if (std.mem.eql(u8, text, "direct")) return true;
        if (std.mem.eql(u8, text, "postgres")) return false;
        return error.InvalidDatabaseUrl;
    }

    /// `postgres://user@host:port/db`, without the password, for logs.
    pub fn format(s: Settings, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (s.unix_path) |p| return w.print("postgres://{s}@{s}/{s}", .{ s.user, p, s.database });
        const ipv6 = std.mem.indexOfScalar(u8, s.host, ':') != null;
        try w.print("postgres://{s}@{s}{s}{s}:{d}/{s}", .{ s.user, if (ipv6) "[" else "", s.host, if (ipv6) "]" else "", s.port, s.database });
    }
};

/// The pool of one executor, and what its gauges last reported.
const Shard = struct {
    pool: *pg.Pool,
    idle: std.atomic.Value(i64) = .init(0),
    in_use: std.atomic.Value(i64) = .init(0),
};

/// A connection taken for a call or a transaction.
const Lease = struct {
    shard: *Shard,
    conn: *pg.Conn,
};

/// A PostgreSQL database: the handle in the App state. Its calls take the
/// request (or an `anole.db.Ctx`) first; see `anole.db`.
pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The settings' strings and the startup parameters.
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    settings: Settings,
    pools: internal.PerExecutor(Shard),
    errors: db.ErrorMap,
    observer: db.Observer,
    readiness: db.Readiness,
    acquire_timeout: Duration,
    connect_timeout: ?Duration,
    ping_timeout: Duration,
    connect_at_start: bool,
    /// Calls with `.coalesce` or `.cache` (`with`), and `invalidate` for
    /// cached results: `app.db.cache.invalidate(.{ .tag = "posts" })`.
    cache: db.QueryCache,
    /// What verify-ca and verify-full trust, when not the system's store.
    store: if (has_tls) @FieldType(pg.TlsConfig, "store") else void = if (has_tls) null else {},
    /// The client certificate, when there is one.
    cert: if (has_tls) ?*dusty_tls.config.CertKeyPair else void = if (has_tls) null else {},

    /// Resolves the settings and sets up a pool per executor of `io`'s
    /// runtime; no connection opens yet. `app.postgres` calls it.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Client {
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = .init(gpa),
            .name = opts.name,
            .settings = undefined,
            .pools = undefined,
            .errors = opts.errors,
            .observer = .{ .system = .postgresql, .name = opts.name },
            .readiness = .{ .io = io, .context = self, .ping = ping },
            .acquire_timeout = opts.acquire_timeout,
            .connect_timeout = undefined,
            .ping_timeout = opts.ping_timeout,
            .connect_at_start = opts.connect_at_start,
            .cache = try .init(gpa, io, .postgresql, opts.name, opts.cache),
        };
        errdefer self.cache.deinit();
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const s = try Settings.resolve(a, opts);
        self.settings = s;
        self.connect_timeout = s.connect_timeout orelse opts.connect_timeout;

        var tls_config: pg.TlsConfig = .{};
        if (comptime has_tls) {
            errdefer self.freeTls();
            if (s.sslmode == .verify_ca or s.sslmode == .verify_full) {
                const ca: ?dusty.TlsCa = opts.tls.ca orelse if (s.sslrootcert) |path|
                    (if (std.mem.eql(u8, path, "system")) null else dusty.TlsCa{ .file = .{ .path = path } })
                else
                    null;
                if (ca) |source| {
                    self.store = dusty_tls.clientStore(gpa, io, source) catch |err| {
                        log.err("postgres: cannot load the root certificates for sslmode={t}: {t}", .{ s.sslmode, err });
                        return err;
                    };
                }
            }
            const client_cert: ?dusty.TlsConfig.ClientCertificate = opts.tls.client_certificate orelse if (s.sslcert) |cert_path|
                .{ .cert_path = cert_path, .key_path = s.sslkey orelse {
                    log.err("postgres: sslcert is set but sslkey is not", .{});
                    return error.InvalidDatabaseUrl;
                } }
            else
                null;
            if (client_cert) |cc| {
                const pair = try gpa.create(dusty_tls.config.CertKeyPair);
                errdefer gpa.destroy(pair);
                pair.* = (if (cc.pem) |pem|
                    dusty_tls.config.CertKeyPair.fromSlice(gpa, io, pem.cert, pem.key)
                else
                    dusty_tls.config.CertKeyPair.fromFilePath(gpa, io, cc.dir orelse std.Io.Dir.cwd(), cc.cert_path, cc.key_path)) catch |err| {
                    log.err("postgres: cannot load the client certificate: {t}", .{err});
                    return err;
                };
                self.cert = pair;
            }
            tls_config = .{ .store = self.store, .auth = self.cert };
        } else if (s.sslmode.needsTls()) {
            log.err("postgres: sslmode={t} needs TLS, which this build leaves out (-Dtls=none)", .{s.sslmode});
            return error.TlsNotBuilt;
        }
        errdefer if (comptime has_tls) self.freeTls();

        var startup: ?std.StringHashMap([]const u8) = null;
        if (s.parameters.len > 0) {
            startup = .init(a);
            for (s.parameters) |p| try startup.?.put(p.name, p.value);
        }
        const executors = internal.executorCount(io);
        const total: usize = s.max_connections orelse opts.max_connections orelse @max(4, 2 * executors);
        const pool_opts: pg.Pool.Opts = .{
            .size = 1,
            .auth = .{
                .username = s.user,
                .password = s.password,
                .database = s.database,
                .application_name = s.application_name orelse opts.application_name,
                .startup_parameters = startup,
                .timeout = millis(self.connect_timeout orelse .fromSeconds(60)),
            },
            .connect = .{
                .host = s.unix_path orelse s.host,
                .port = s.port,
                .tls = switch (s.sslmode) {
                    .disable => .off,
                    .allow, .prefer => .prefer,
                    .require => .require,
                    .verify_ca => .{ .verify_ca = null },
                    .verify_full => .{ .verify_full = null },
                },
                .tls_direct = s.direct_tls,
                .tls_config = tls_config,
                .statement_cache_size = opts.statement_cache_size,
            },
            .timeout = millis(opts.acquire_timeout),
            .connect_on_init_count = 0,
            .max_lifetime = if (opts.max_lifetime) |d| millis(d) else null,
            .idle_timeout = if (opts.idle_timeout) |d| millis(d) else null,
        };

        self.pools = try .init(gpa, io);
        var made: usize = 0;
        errdefer {
            for (self.pools.pools[0..made]) |*shard| shard.pool.deinit();
            self.pools.deinit(gpa);
        }
        for (self.pools.pools, 0..) |*shard, i| {
            var o = pool_opts;
            o.size = @intCast(@min(self.pools.share(total, i), std.math.maxInt(u16)));
            shard.* = .{ .pool = try pg.Pool.init(io, gpa, o) };
            made += 1;
        }
        log.info("postgres \"{s}\": {f} (sslmode={t}), up to {d} connections over {d} executors", .{ self.name, s, s.sslmode, @max(total, executors), executors });
        return self;
    }

    /// Closes every connection: after the server has drained (`app`'s
    /// `deinit` does it then).
    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        // First: a statement still running for the cache holds a connection.
        self.cache.deinit();
        for (self.pools.pools) |*shard| shard.pool.deinit();
        self.pools.deinit(gpa);
        if (comptime has_tls) self.freeTls();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn freeTls(self: *Client) void {
        if (self.store) |s| dusty_tls.releaseStore(s);
        self.store = null;
        if (self.cert) |pair| {
            pair.deinit(self.gpa);
            self.gpa.destroy(pair);
        }
        self.cert = null;
    }

    /// What the server hands over when serving starts: the app's metrics
    /// registry, tracer and health checks, when it has them, so
    /// `app.postgres` may come before or after `app.metrics`,
    /// `app.tracing` and `app.health`. With `connect_at_start`, it opens
    /// a connection per executor and fails if one cannot.
    pub fn start(self: *Client, registry: ?*observe.metrics.Registry, tracer: ?*observe.trace.Exporter, health: ?*observe.Health) !void {
        self.observer = try .init(.postgresql, self.name, registry, tracer);
        try self.cache.observe(registry);
        if (health) |h| try self.readiness.register(h, self.name);
        if (!self.connect_at_start) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var c: db.Ctx = .{ .io = self.io, .arena = arena.allocator() };
        var ctx = erase(&c);
        for (self.pools.pools) |*shard| {
            const lease = self.takeFrom(&ctx, shard) catch |err| {
                log.err("postgres \"{s}\": not serving, the database is not reachable ({f})", .{ self.name, db.lastError(&c) orelse db.ErrorDetail{ .system = .postgresql, .class = .other, .message = @errorName(err) } });
                return err;
            };
            self.give(lease);
        }
    }

    /// The verbs with `opts`: `app.db.with(.{ .timeout = .fromSeconds(2) }).all(...)`.
    pub fn with(self: *Client, opts: db.QueryOptions) Query {
        return .{ .db = self, .opts = opts };
    }

    /// Runs `sql`; the rows it changed (inserted, updated, deleted). Without
    /// `args`, several statements may go in one call (a migration).
    pub fn exec(self: *Client, c: anytype, sql: []const u8, args: anytype) Error!u64 {
        return self.with(.{}).exec(c, sql, args);
    }

    /// The first row as a `T`; none: `error.NotFound` (a 404).
    pub fn one(self: *Client, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!T {
        return self.with(.{}).one(T, c, sql, args);
    }

    /// The first row as a `T`, or null.
    pub fn optional(self: *Client, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!?T {
        return self.with(.{}).optional(T, c, sql, args);
    }

    /// Every row, in `c`'s arena.
    pub fn all(self: *Client, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error![]T {
        return self.with(.{}).all(T, c, sql, args);
    }

    /// The rows one at a time, for results too large to hold at once; the
    /// connection is the caller's until `deinit`.
    pub fn iterate(self: *Client, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!Rows(T) {
        return self.with(.{}).iterate(T, c, sql, args);
    }

    /// A transaction on one connection: `defer tx.deinit()` (it rolls
    /// back unless committed), the verbs on `tx`, then `tx.commit(c)`.
    pub fn begin(self: *Client, c: anytype, opts: db.TxOptions) Error!Tx {
        return self.beginWith(c, opts, if (opts.timeout) |t| dusty.Deadline.init(c.io, .{ .duration = .{ .raw = t, .clock = .awake } }) else null);
    }

    fn beginWith(self: *Client, c: anytype, opts: db.TxOptions, deadline: ?dusty.Deadline) Error!Tx {
        var tx: Tx = .{ .db = self, .io = c.io, .lease = undefined, .deadline = deadline };
        var buf: [96]u8 = undefined;
        const sql = beginSql(&buf, opts);
        tx.lease = try self.call(c, null, &tx, sql, Begin{});
        return tx;
    }

    const Begin = struct {
        const Out = Lease;
        fn run(_: *Begin, d: *Client, ctx: *Ctx, tx: ?*Tx, sql: []const u8) Error!Lease {
            const lease = try d.take(ctx);
            _ = lease.conn.execOpts(sql, .{}, .{}) catch |err| {
                const e = d.failed(ctx, lease, err, null);
                d.give(lease);
                return e;
            };
            _ = tx;
            return lease;
        }
    };

    /// `func(&tx, args...)` in a transaction, committed when it returns;
    /// rolled back when it fails, and run again (up to `opts.retries` more
    /// times) when it lost to a concurrent one (`anole.db.retryable`).
    /// `opts.timeout` bounds every attempt together.
    ///
    ///     try app.db.transaction(req, .{ .isolation = .serializable, .retries = 3 }, transfer, .{ req, from, to, cents });
    ///
    ///     fn transfer(tx: *anole.pg.Tx, req: *anole.Request, from: i64, to: i64, cents: i64) !void {
    ///         _ = try tx.exec(req, "UPDATE accounts SET cents = cents - $1 WHERE id = $2", .{ cents, from });
    ///         _ = try tx.exec(req, "UPDATE accounts SET cents = cents + $1 WHERE id = $2", .{ cents, to });
    ///     }
    pub fn transaction(self: *Client, c: anytype, opts: db.TxOptions, comptime func: anytype, args: anytype) internal.Bounded(Retry(func, @TypeOf(c), @TypeOf(args)).run) {
        return internal.bounded(c, .postgresql, opts.timeout, Retry(func, @TypeOf(c), @TypeOf(args)).run, .{ self, c, opts, args });
    }

    fn Retry(comptime func: anytype, comptime C: type, comptime Args: type) type {
        const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Out = switch (@typeInfo(R)) {
            .error_union => |eu| (eu.error_set || Error)!eu.payload,
            else => Error!R,
        };
        return struct {
            fn run(d: *Client, c: C, opts: db.TxOptions, args: Args) Out {
                var inner = opts;
                inner.timeout = null;
                var attempt: u8 = 0;
                while (true) : (attempt += 1) {
                    var tx = try d.beginWith(c, inner, null);
                    defer tx.deinit();
                    const out = @call(.auto, func, .{&tx} ++ args) catch |err| {
                        if (attempt < opts.retries and db.retryable(c, err)) continue;
                        return err;
                    };
                    tx.commit(c) catch |err| {
                        if (attempt < opts.retries and db.retryable(c, err)) continue;
                        return err;
                    };
                    return out;
                }
            }
        };
    }

    /// A connection of pg.zig's own, for what the verbs do not cover
    /// (COPY, a cursor, `LISTEN` on the pool's connection...); give it
    /// back with `release`. Failures of its calls are pg.zig's errors.
    pub fn acquire(self: *Client, c: anytype) Error!Conn {
        var ctx = erase(c);
        const lease = try self.take(&ctx);
        return .{ .db = self, .io = c.io, .lease = lease, .raw = lease.conn };
    }

    /// A connection for `LISTEN`/`NOTIFY`, outside the pools (pg.zig's
    /// `Listener`): it waits for notifications as long as it is open.
    pub fn listener(self: *Client) !pg.Listener {
        return self.pools.pools[0].pool.newListener();
    }

    /// True when the database answers `SELECT 1` within `ping_timeout`:
    /// `/readyz`'s check.
    fn ping(context: *anyopaque, io: std.Io) bool {
        const self: *Client = @ptrCast(@alignCast(context));
        const deadline: dusty.Deadline = .init(io, .{ .duration = .{ .raw = self.ping_timeout, .clock = .awake } });
        return deadline.run(pingOnce, .{ self, io }) catch false;
    }

    fn pingOnce(self: *Client, io: std.Io) !bool {
        const shard = self.pools.get(io);
        const conn = try shard.pool.acquire();
        defer {
            shard.pool.release(conn);
            self.report(shard);
        }
        _ = try conn.execOpts("SELECT 1", .{}, .{});
        return true;
    }

    // -----------------------------------------------------------------------
    // The machinery under the verbs.

    /// Runs `job` (a struct with `Out` and `run`) as one database call:
    /// observed (metrics, a span), bounded by `timeout` or the
    /// transaction's deadline, its error narrowed to `Error`.
    fn call(self: *Client, c: anytype, timeout: ?Duration, tx: ?*Tx, sql: []const u8, job: anytype) Error!@TypeOf(job).Out {
        var ctx = erase(c);
        var j = job;
        const J = @TypeOf(j);
        const observed = self.observer.start(&ctx);
        const deadline: ?dusty.Deadline = if (tx) |t|
            t.deadline
        else if (timeout) |t|
            .init(ctx.io, .{ .duration = .{ .raw = t, .clock = .awake } })
        else
            null;
        const result = self.guarded(&ctx, deadline, J.run, .{ &j, self, &ctx, tx, sql });
        var op: [16]u8 = undefined;
        const failure: ?anyerror = if (result) |_| null else |e| e;
        // A span when the call came from a traced request.
        if (ctx.request) |req| observed.end(req, operation(&op, sql), null, failure) else observed.end(&ctx, operation(&op, sql), null, failure);
        return result catch |err| self.narrow(&ctx, err);
    }

    /// `func(args...)` before `deadline`, as `internal.bounded` (whose
    /// timeout, `QueryOptions.timeout`, a call's deadline is), or a
    /// transaction's: past it, the call is canceled where it waits and
    /// fails with the `timeout` class (`GatewayTimeout`).
    fn guarded(self: *Client, ctx: *const Ctx, deadline: ?dusty.Deadline, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) internal.Bounded(func) {
        const d = deadline orelse return @call(.auto, func, args);
        return d.run(func, args) catch |err| switch (err) {
            error.Timeout => ctx.fail(self.errors, .{ .system = .postgresql, .class = .timeout, .message = "the call ran past its timeout" }),
            else => |e| e,
        };
    }

    /// `err` as one of `Error`; anything else is recorded as a 500.
    fn narrow(self: *Client, ctx: *const Ctx, err: anyerror) Error {
        inline for (@typeInfo(Error).error_set.error_names.?) |name| {
            if (err == @field(Error, name)) return @field(Error, name);
        }
        return ctx.fail(self.errors, .{ .system = .postgresql, .class = .other, .message = @errorName(err) });
    }

    /// A connection from the calling executor's pool.
    fn take(self: *Client, ctx: *Ctx) Error!Lease {
        return self.takeFrom(ctx, self.pools.get(ctx.io));
    }

    fn takeFrom(self: *Client, ctx: *Ctx, shard: *Shard) Error!Lease {
        const io = ctx.io;
        var refused: pg.Pool.ConnectError = .{ .allocator = ctx.arena };
        const timeout: std.Io.Timeout = if (self.connect_timeout) |ct|
            .{ .duration = .{ .raw = .{ .nanoseconds = self.acquire_timeout.nanoseconds + ct.nanoseconds }, .clock = .awake } }
        else
            .none;
        self.observer.waiting(1);
        const started: std.Io.Clock.Timestamp = .now(io, .awake);
        const got = dusty.Deadline.init(io, timeout).run(pg.Pool.acquireOpts, .{ shard.pool, .{ .connect_error = &refused } });
        self.observer.waiting(-1);
        const conn = got catch |err| return self.unavailable(ctx, shard, err, refused.err);
        self.observer.acquired(started.durationTo(.now(io, .awake)).raw);
        self.report(shard);
        return .{ .shard = shard, .conn = conn };
    }

    /// Why no connection could be had, as `ServiceUnavailable`.
    fn unavailable(self: *Client, ctx: *const Ctx, shard: *Shard, err: anyerror, refused: ?pg.Error) Error {
        const s = &self.settings;
        switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => return ctx.failf(self.errors, .unavailable, "no connection within {d} ms: all {d} of this executor's connections were busy, or the server did not answer", .{ millis(self.acquire_timeout), shard.pool._conns.len }),
            error.PG => {
                const e = refused orelse return ctx.failf(self.errors, .unavailable, "{f} refused the connection", .{s.*});
                return ctx.fail(self.errors, .{ .system = .postgresql, .class = .unavailable, .code = e.code, .message = e.message });
            },
            error.TlsNotSupportedByServer => return ctx.failf(self.errors, .unavailable, "{f} does not accept TLS, and sslmode={t} requires it", .{ s.*, s.sslmode }),
            else => return ctx.failf(self.errors, .unavailable, "cannot connect to {f}: {t}", .{ s.*, err }),
        }
    }

    fn give(self: *Client, lease: Lease) void {
        lease.shard.pool.release(lease.conn);
        self.report(lease.shard);
    }

    /// Brings the pool gauges up to date with `shard`.
    fn report(self: *Client, shard: *Shard) void {
        if (self.observer.metrics == null) return;
        const stats = shard.pool.stats();
        const idle: i64 = @intCast(stats.available);
        const in_use: i64 = @intCast(stats.in_use);
        self.observer.connections(idle - shard.idle.swap(idle, .monotonic), in_use - shard.in_use.swap(in_use, .monotonic));
    }

    /// What a failed call on `lease` returns: the server's error by its
    /// SQLSTATE, a cancel (after telling the server to stop), or a broken
    /// connection. The lease is still the caller's to give back; one left
    /// mid-protocol is closed then.
    fn failed(self: *Client, ctx: *const Ctx, lease: Lease, err: anyerror, tx: ?*Tx) Error {
        const conn = lease.conn;
        switch (err) {
            error.PG => {
                // An error in the middle of the rows: the server's
                // ReadyForQuery is still to come.
                if (conn._state == .query) conn.recoverFromError() catch return self.canceled(ctx, conn, tx);
                const e = conn.err orelse return ctx.fail(self.errors, .{ .system = .postgresql, .class = .other, .message = "server error" });
                return ctx.fail(self.errors, .{
                    .system = .postgresql,
                    .class = classify(e.code),
                    .code = e.code,
                    .message = e.message,
                    .constraint = e.constraint,
                    .table = e.table,
                });
            },
            error.Canceled => return self.canceled(ctx, conn, tx),
            error.OutOfMemory => return error.OutOfMemory,
            error.WrongNumberOfParameters => return ctx.fail(self.errors, .{ .system = .postgresql, .class = .other, .message = "the statement's parameters ($1, $2...) and the arguments given differ in number" }),
            else => {
                if (tx) |t| t.state = .broken;
                if (brokenConnection(err)) return ctx.failf(self.errors, .unavailable, "the connection to {f} broke: {t}", .{ self.settings, err });
                return ctx.failf(self.errors, .other, "{t}", .{err});
            },
        }
    }

    fn canceled(_: *Client, ctx: *const Ctx, conn: *pg.Conn, tx: ?*Tx) Error {
        stopBackend(ctx.io, conn);
        if (tx) |t| t.state = .broken;
        return error.Canceled;
    }
};

/// Asks the server to stop what `conn` runs (CancelRequest on a
/// connection of its own), within a second, whatever cancels the caller:
/// its own call was canceled mid-statement, and the statement would
/// otherwise run on. `conn` is closed when it is given back.
fn stopBackend(io: std.Io, conn: *pg.Conn) void {
    conn._state = .fail;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var group: std.Io.Group = .init;
    placement.concurrent(&group, io, .local, sendCancel, .{ io, conn }) catch return;
    group.await(io) catch {};
}

fn sendCancel(io: std.Io, conn: *pg.Conn) void {
    const deadline: dusty.Deadline = .init(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    deadline.run(pg.Conn.cancel, .{conn}) catch |err| log.debug("postgres: CancelRequest: {t}", .{err});
}

fn brokenConnection(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream, error.Closed, error.ConnectionResetByPeer, error.BrokenPipe, error.ConnectionTimedOut, error.Timeout, error.NotOpenForReading, error.TlsReadFailed, error.TlsWriteFailed, error.UnexpectedDBMessage, error.ConnectionBusy => true,
        else => false,
    };
}

/// The class of a SQLSTATE (`anole.db.Class`).
fn classify(code: []const u8) db.Class {
    const Entry = struct { []const u8, db.Class };
    for ([_]Entry{
        .{ "23505", .unique },
        .{ "23P01", .exclusion },
        .{ "23503", .foreign_key },
        .{ "23502", .not_null },
        .{ "23514", .check },
        .{ "40001", .serialization },
        .{ "40P01", .deadlock },
        .{ "57014", .timeout },
        // too_many_connections, admin_shutdown, crash_shutdown,
        // cannot_connect_now (starting up, a standby being promoted).
        .{ "53300", .unavailable },
        .{ "57P01", .unavailable },
        .{ "57P02", .unavailable },
        .{ "57P03", .unavailable },
    }) |e| if (std.mem.eql(u8, code, e[0])) return e[1];
    // Class 08: connection exception.
    if (std.mem.startsWith(u8, code, "08")) return .unavailable;
    return .other;
}

/// The statement's first keyword, upper-cased into `buf` (a span's
/// operation): "SELECT", "INSERT", "WITH"...
fn operation(buf: *[16]u8, sql: []const u8) []const u8 {
    const text = std.mem.trimStart(u8, sql, " \t\r\n(");
    var n: usize = 0;
    while (n < text.len and n < buf.len and std.ascii.isAlphabetic(text[n])) : (n += 1) buf[n] = std.ascii.toUpper(text[n]);
    return if (n == 0) "QUERY" else buf[0..n];
}

fn beginSql(buf: *[96]u8, opts: db.TxOptions) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("BEGIN") catch unreachable;
    if (opts.isolation) |level| w.writeAll(switch (level) {
        .read_uncommitted => " ISOLATION LEVEL READ UNCOMMITTED",
        .read_committed => " ISOLATION LEVEL READ COMMITTED",
        .repeatable_read => " ISOLATION LEVEL REPEATABLE READ",
        .serializable => " ISOLATION LEVEL SERIALIZABLE",
    }) catch unreachable;
    if (opts.read_only) w.writeAll(" READ ONLY") catch unreachable;
    return w.buffered();
}

fn millis(d: Duration) u32 {
    return @intCast(std.math.clamp(d.toMilliseconds(), 0, std.math.maxInt(u32)));
}

/// The verbs, with `QueryOptions` (`Client.with`).
pub const Query = struct {
    db: *Client,
    opts: db.QueryOptions,

    /// `Client.exec`, with the options' `timeout` and `prepare`.
    pub fn exec(self: Query, c: anytype, sql: []const u8, args: anytype) Error!u64 {
        return self.db.call(c, self.opts.timeout, null, sql, Exec(@TypeOf(args)){ .args = args, .prepare = self.opts.prepare });
    }

    // The reads go through the cache, which shares them when `opts`
    // asks (`coalesce`, `cache`) and makes the plain call otherwise.

    /// `Client.one`, with the options (`coalesce` and `cache` apply).
    pub fn one(self: Query, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!T {
        return self.db.cache.read(T, c, self.opts, sql, args, Read(T, .one){ .query = self });
    }

    /// `Client.optional`, with the options (`coalesce` and `cache` apply).
    pub fn optional(self: Query, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!?T {
        return self.db.cache.read(?T, c, self.opts, sql, args, Read(T, .optional){ .query = self });
    }

    /// `Client.all`, with the options (`coalesce` and `cache` apply).
    pub fn all(self: Query, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error![]T {
        return self.db.cache.read([]T, c, self.opts, sql, args, Read(T, .all){ .query = self });
    }

    /// The timeout bounds the statement until its first rows; reading the
    /// rest is the caller's.
    pub fn iterate(self: Query, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!Rows(T) {
        return self.db.call(c, self.opts.timeout, null, sql, Fetch(T, .iterate, @TypeOf(args)){ .args = args, .prepare = self.opts.prepare });
    }
};

/// A read as `anole.db.QueryCache` makes it: the plain call, with the
/// caller's context or a shared call's own.
fn Read(comptime T: type, comptime mode: Mode) type {
    return struct {
        query: Query,

        pub const shape = @field(db.ReadShape, @tagName(mode));

        pub fn run(r: @This(), c: anytype, sql: []const u8, args: anytype) Error!Fetch(T, mode, @TypeOf(args)).Out {
            const q = r.query;
            return q.db.call(c, q.opts.timeout, null, sql, Fetch(T, mode, @TypeOf(args)){ .args = args, .prepare = q.opts.prepare });
        }
    };
}

/// A transaction (`Client.begin`): the verbs on its one connection, then
/// `commit`, or `rollback`; `deinit` rolls back unless one of them ran,
/// and gives the connection back.
pub const Tx = struct {
    db: *Client,
    /// For the rollback of `deinit`.
    io: std.Io,
    lease: Lease,
    deadline: ?dusty.Deadline,
    state: enum { open, done, broken } = .open,

    /// `Client.exec` on the transaction's connection.
    pub fn exec(self: *Tx, c: anytype, sql: []const u8, args: anytype) Error!u64 {
        try self.usable(c);
        return self.db.call(c, null, self, sql, Exec(@TypeOf(args)){ .args = args, .prepare = true });
    }

    /// `Client.one` on the transaction's connection.
    pub fn one(self: *Tx, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!T {
        try self.usable(c);
        return self.db.call(c, null, self, sql, Fetch(T, .one, @TypeOf(args)){ .args = args, .prepare = true });
    }

    /// `Client.optional` on the transaction's connection.
    pub fn optional(self: *Tx, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!?T {
        try self.usable(c);
        return self.db.call(c, null, self, sql, Fetch(T, .optional, @TypeOf(args)){ .args = args, .prepare = true });
    }

    /// `Client.all` on the transaction's connection.
    pub fn all(self: *Tx, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error![]T {
        try self.usable(c);
        return self.db.call(c, null, self, sql, Fetch(T, .all, @TypeOf(args)){ .args = args, .prepare = true });
    }

    /// The rows one at a time; finish with them (`deinit`) before the
    /// next call on the transaction.
    pub fn iterate(self: *Tx, comptime T: type, c: anytype, sql: []const u8, args: anytype) Error!Rows(T) {
        try self.usable(c);
        return self.db.call(c, null, self, sql, Fetch(T, .iterate, @TypeOf(args)){ .args = args, .prepare = true });
    }

    /// Commits. A transaction that already failed (a statement of it
    /// errored) cannot: it is rolled back and this fails, as does a commit
    /// the server refuses (a serialization failure: `Conflict`). `c` is the
    /// request (or `anole.db.Ctx`) the commit waits for, under its
    /// deadline and the transaction's `TxOptions.timeout`.
    pub fn commit(self: *Tx, c: anytype) Error!void {
        try self.usable(c);
        if (self.lease.conn._state == .fail) {
            self.rollbackQuietly();
            var ctx = erase(c);
            return ctx.failf(self.db.errors, .other, "the transaction had failed, so it was rolled back instead of committed", .{});
        }
        _ = try self.db.call(c, null, self, "COMMIT", Exec(@TypeOf(.{})){ .args = .{}, .prepare = false });
        self.state = .done;
    }

    /// Rolls back. `deinit` does it too when neither this nor `commit`
    /// ran; call it for the error a failed rollback returns.
    pub fn rollback(self: *Tx, c: anytype) Error!void {
        try self.usable(c);
        _ = try self.db.call(c, null, self, "ROLLBACK", Rollback{});
        self.state = .done;
    }

    /// Rolls back unless committed or rolled back, and gives the
    /// connection back (closed if it is not in a clean state).
    pub fn deinit(self: *Tx) void {
        if (self.state == .open) self.rollbackQuietly();
        self.db.give(self.lease);
        self.* = undefined;
    }

    fn rollbackQuietly(self: *Tx) void {
        self.state = .done;
        const io = self.io;
        // A canceled request still rolls back what it started.
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        self.lease.conn.rollback() catch {
            self.lease.conn._state = .fail;
        };
    }

    fn usable(self: *const Tx, c: anytype) Error!void {
        if (self.state == .open) return;
        var ctx = erase(c);
        return ctx.failf(self.db.errors, .other, "the transaction is over ({s}); begin another", .{if (self.state == .done) "committed or rolled back" else "its connection failed"});
    }

    const Rollback = struct {
        const Out = void;
        fn run(_: *Rollback, d: *Client, ctx: *Ctx, tx: ?*Tx, _: []const u8) Error!void {
            const t = tx.?;
            t.lease.conn.rollback() catch |err| return d.failed(ctx, t.lease, err, t);
        }
    };
};

/// A connection of pg.zig's own (`Client.acquire`).
pub const Conn = struct {
    db: *Client,
    io: std.Io,
    lease: Lease,
    /// pg.zig's connection: `query`, `row`, `exec`, `prepare`...
    raw: *pg.Conn,

    /// Gives the connection back; a statement it left running is
    /// canceled, and the connection closed.
    pub fn release(self: *const Conn) void {
        if (self.lease.conn._state == .query) stopBackend(self.io, self.lease.conn);
        self.db.give(self.lease);
    }
};

/// The rows of `iterate`, decoded one at a time into the context's arena.
pub fn Rows(comptime T: type) type {
    return struct {
        const Self = @This();

        db: *Client,
        ctx: Ctx,
        /// Null in a transaction (the transaction's connection).
        lease: ?Lease,
        tx: ?*Tx,
        conn: *pg.Conn,
        result: *pg.Result,
        columns: Columns(T),
        done: bool = false,

        /// The next row, or null after the last.
        pub fn next(self: *Self) Error!?T {
            if (self.done) return null;
            const row = self.result.next() catch |err| {
                self.done = true;
                return self.db.failed(&self.ctx, self.leased(), err, self.tx);
            } orelse {
                self.done = true;
                return null;
            };
            return decodeRow(T, &row, &self.columns, &self.ctx, self.db.errors) catch |err| {
                self.finish();
                return err;
            };
        }

        /// Reads past the rows not taken and gives the connection back.
        pub fn deinit(self: *Self) void {
            self.finish();
            self.result.deinit();
            if (self.lease) |l| self.db.give(l);
            self.* = undefined;
        }

        fn finish(self: *Self) void {
            if (self.done) return;
            self.done = true;
            self.result.drain() catch |err| {
                if (err == error.Canceled) stopBackend(self.ctx.io, self.conn);
                self.conn._state = .fail;
            };
        }

        fn leased(self: *const Self) Lease {
            return self.lease orelse self.tx.?.lease;
        }
    };
}

// ---------------------------------------------------------------------------
// The calls' jobs: what runs under `Client.call`.

fn Exec(comptime Args: type) type {
    return struct {
        args: Args,
        prepare: bool,

        const Out = u64;

        fn run(job: *@This(), d: *Client, ctx: *Ctx, tx: ?*Tx, sql: []const u8) Error!u64 {
            const lease = if (tx) |t| t.lease else try d.take(ctx);
            defer if (tx == null) d.give(lease);
            const n = lease.conn.execOpts(sql, params(job.args), .{ .statement_cache = job.prepare }) catch |err| return d.failed(ctx, lease, err, tx);
            return @intCast(@max(n orelse 0, 0));
        }
    };
}

const Mode = enum { one, optional, all, iterate };

fn Fetch(comptime T: type, comptime mode: Mode, comptime Args: type) type {
    return struct {
        args: Args,
        prepare: bool,

        const Out = switch (mode) {
            .one => T,
            .optional => ?T,
            .all => []T,
            .iterate => Rows(T),
        };

        fn run(job: *@This(), d: *Client, ctx: *Ctx, tx: ?*Tx, sql: []const u8) Error!Out {
            const lease = if (tx) |t| t.lease else try d.take(ctx);
            var given = false;
            defer if (tx == null and !given) d.give(lease);
            var result = lease.conn.queryOpts(sql, params(job.args), .{
                .statement_cache = job.prepare,
                .column_names = comptime isRow(T),
            }) catch |err| return d.failed(ctx, lease, err, tx);
            var rows: Rows(T) = .{
                .db = d,
                .ctx = ctx.*,
                .lease = if (tx == null) lease else null,
                .tx = tx,
                .conn = lease.conn,
                .result = result,
                .columns = undefined,
            };
            rows.columns = columns(T, result, ctx, d.errors) catch |err| {
                rows.finish();
                result.deinit();
                return err;
            };
            if (mode == .iterate) {
                given = true;
                return rows;
            }
            defer result.deinit();
            switch (mode) {
                .all => {
                    var list: std.ArrayList(T) = .empty;
                    while (try rows.next()) |row| try list.append(ctx.arena, row);
                    return list.items;
                },
                .one, .optional => {
                    const first = try rows.next();
                    rows.finish();
                    if (mode == .one) return first orelse error.NotFound;
                    return first;
                },
                .iterate => unreachable,
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Parameters

/// `args` as pg.zig binds them: `anole.db.Time` as a timestamp's
/// microseconds, number literals as i64 and f64.
fn params(args: anytype) Params(@TypeOf(args)) {
    const A = @TypeOf(args);
    var out: Params(A) = undefined;
    inline for (@typeInfo(A).@"struct".field_types, 0..) |F, i| {
        out[i] = if (F == db.Time) args[i].us else if (F == ?db.Time) (if (args[i]) |t| t.us else null) else args[i];
    }
    return out;
}

fn Params(comptime A: type) type {
    const info = @typeInfo(A).@"struct";
    if (info.field_types.len == 0) return A;
    if (!info.is_tuple) @compileError("anole.pg: the arguments are a tuple, `.{ a, b }`, not " ++ @typeName(A));
    var out: [info.field_types.len]type = undefined;
    for (info.field_types, 0..) |F, i| out[i] = switch (F) {
        db.Time => i64,
        ?db.Time => ?i64,
        // Literals: `.{ 42, 2.5 }`.
        comptime_int => i64,
        comptime_float => f64,
        else => F,
    };
    return @Tuple(&out);
}

// ---------------------------------------------------------------------------
// Rows

/// Whether `T` takes a row's columns by name (a plain struct), rather
/// than one column's value.
fn isRow(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !isValue(T);
}

/// Structs that are one column's value.
fn isValue(comptime T: type) bool {
    return T == db.Time or T == pg.Numeric or T == pg.Cidr or @hasDecl(T, "fromPgzRow");
}

/// Where each of `T`'s fields finds its column; one entry, column 0, for
/// a single value.
fn Columns(comptime T: type) type {
    return [if (isRow(T)) @typeInfo(T).@"struct".field_names.len else 1]?usize;
}

fn columns(comptime T: type, result: *const pg.Result, ctx: *const Ctx, map: db.ErrorMap) Error!Columns(T) {
    var out: Columns(T) = undefined;
    if (comptime !isRow(T)) {
        if (result.number_of_columns == 0) return missing(ctx, map, "the statement returns no column for a " ++ @typeName(T));
        out[0] = 0;
        return out;
    }
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_attrs, 0..) |name, attrs, i| {
        out[i] = result.columnIndex(name);
        if (out[i] == null and attrs.default_value_ptr == null)
            return missing(ctx, map, "the result has no column \"" ++ name ++ "\" for " ++ @typeName(T) ++ "." ++ name ++ ": select it (or rename one with AS), or give the field a default");
    }
    return out;
}

fn missing(ctx: *const Ctx, map: db.ErrorMap, message: []const u8) error{MissingColumn} {
    // Kept for `lastError` and logged as a 500; the error is its own.
    _ = @intFromError(ctx.fail(map, .{ .system = .postgresql, .class = .other, .message = message }));
    return error.MissingColumn;
}

fn decodeRow(comptime T: type, row: *const pg.Row, cols: *const Columns(T), ctx: *const Ctx, map: db.ErrorMap) Error!T {
    if (comptime !isRow(T)) {
        return decode(T, row.values[0], row.oids[0], ctx.arena) catch |err| decodeFailed(ctx, map, "", T, row.oids[0], err);
    }
    const info = @typeInfo(T).@"struct";
    var out: T = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
        if (cols[i]) |col| {
            @field(out, name) = decode(F, row.values[col], row.oids[col], ctx.arena) catch |err| return decodeFailed(ctx, map, name, F, row.oids[col], err);
        } else {
            @field(out, name) = attrs.defaultValue(F).?;
        }
    }
    return out;
}

fn decodeFailed(ctx: *const Ctx, map: db.ErrorMap, name: []const u8, comptime F: type, oid: i32, err: anyerror) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const column = if (name.len > 0) name else "the value";
    return switch (err) {
        error.UnexpectedNull => ctx.failf(map, .other, "column \"{s}\" is NULL, and {s} cannot hold it; make the field optional (?{s})", .{ column, @typeName(F), @typeName(F) }),
        error.OutOfRange => ctx.failf(map, .other, "column \"{s}\": the value does not fit in {s}", .{ column, @typeName(F) }),
        error.InvalidType => ctx.failf(map, .other, "column \"{s}\" ({s}) cannot be read into {s}; cast it in the SQL (::text, ::bigint...)", .{ column, pg.types.oidToString(oid), @typeName(F) }),
        else => ctx.failf(map, .other, "column \"{s}\" ({s}) into {s}: {t}", .{ column, pg.types.oidToString(oid), @typeName(F), err }),
    };
}

const Value = pg.Result.State.Value;

/// Type OIDs the decoders below look at.
const Oid = struct {
    const @"bool" = 16;
    const bytea = 17;
    const char = 18;
    const name = 19;
    const int8 = 20;
    const int2 = 21;
    const int4 = 23;
    const text = 25;
    const oid_ = 26;
    const xid = 28;
    const json = 114;
    const float4 = 700;
    const float8 = 701;
    const date = 1082;
    const time = 1083;
    const timestamp = 1114;
    const timestamptz = 1184;
    const interval = 1186;
    const timetz = 1266;
    const numeric = 1700;
    const uuid = 2950;
    const jsonb = 3802;
};

/// One column's value as `F`, its memory in `arena`.
fn decode(comptime F: type, value: Value, type_oid: i32, arena: std.mem.Allocator) !F {
    if (@typeInfo(F) == .optional) {
        if (value.is_null) return null;
        return try decode(@typeInfo(F).optional.child, value, type_oid, arena);
    }
    if (value.is_null) return error.UnexpectedNull;
    const data = value.data;
    if (F == db.Time) return decodeTime(data, type_oid);
    if (F == []const u8 or F == []u8) return decodeText(arena, data, type_oid);
    if (F == std.json.Value) return decodeJson(F, arena, data, type_oid);
    switch (@typeInfo(F)) {
        .int => return decodeInt(F, data, type_oid),
        .float => return decodeFloat(F, data, type_oid),
        .bool => {
            if (type_oid != Oid.bool or data.len != 1) return error.InvalidType;
            return data[0] == 1;
        },
        .@"enum" => return std.meta.stringToEnum(F, data) orelse error.InvalidType,
        .pointer => |p| {
            if (p.size != .slice) @compileError("anole.pg: a column cannot be read into " ++ @typeName(F));
            return decodeArray(p.child, value, type_oid, arena);
        },
        .@"struct" => {
            if (comptime @hasDecl(F, "fromPgzRow")) {
                const v = try F.fromPgzRow(value, type_oid);
                if (comptime std.meta.hasFn(F, "pgzMoveOwner")) return v.pgzMoveOwner(arena);
                return v;
            }
            if (F == pg.Numeric) return (try pg.Numeric.decode(.safe, data, type_oid)).pgzMoveOwner(arena);
            if (F == pg.Cidr) return pg.Cidr.decode(.safe, data, type_oid);
            return decodeJson(F, arena, data, type_oid);
        },
        else => @compileError("anole.pg: a column cannot be read into " ++ @typeName(F)),
    }
}

fn decodeInt(comptime F: type, data: []const u8, type_oid: i32) !F {
    const wide: i128 = switch (type_oid) {
        Oid.int2 => if (data.len == 2) std.mem.readInt(i16, data[0..2], .big) else return error.InvalidType,
        Oid.int4 => if (data.len == 4) std.mem.readInt(i32, data[0..4], .big) else return error.InvalidType,
        Oid.int8 => if (data.len == 8) std.mem.readInt(i64, data[0..8], .big) else return error.InvalidType,
        Oid.oid_, Oid.xid => if (data.len == 4) std.mem.readInt(u32, data[0..4], .big) else return error.InvalidType,
        else => return error.InvalidType,
    };
    return std.math.cast(F, wide) orelse error.OutOfRange;
}

fn decodeFloat(comptime F: type, data: []const u8, type_oid: i32) !F {
    return switch (type_oid) {
        Oid.float4 => if (data.len == 4) @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, data[0..4], .big)))) else error.InvalidType,
        Oid.float8 => if (data.len == 8) @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, data[0..8], .big)))) else error.InvalidType,
        Oid.numeric => if (data.len >= 8) @floatCast(pg.Numeric.decodeKnownToFloat(data)) else error.InvalidType,
        Oid.int2, Oid.int4, Oid.int8 => @floatFromInt(try decodeInt(i64, data, type_oid)),
        else => error.InvalidType,
    };
}

/// timestamp and timestamptz (microseconds since 2000-01-01), and date
/// (days since then), as UTC. ±infinity are the ends of the range.
fn decodeTime(data: []const u8, type_oid: i32) !db.Time {
    const y2k_us: i64 = 946_684_800 * std.time.us_per_s;
    switch (type_oid) {
        Oid.timestamp, Oid.timestamptz => {
            if (data.len != 8) return error.InvalidType;
            const v = std.mem.readInt(i64, data[0..8], .big);
            if (v == std.math.maxInt(i64) or v == std.math.minInt(i64)) return .{ .us = v };
            return .{ .us = v +| y2k_us };
        },
        Oid.date => {
            if (data.len != 4) return error.InvalidType;
            const days = std.mem.readInt(i32, data[0..4], .big);
            if (days == std.math.maxInt(i32)) return .{ .us = std.math.maxInt(i64) };
            if (days == std.math.minInt(i32)) return .{ .us = std.math.minInt(i64) };
            return .{ .us = @as(i64, days) * std.time.us_per_day + y2k_us };
        },
        // text, as SQLite and hand-written SQL give it
        Oid.text, 1043, 705 => return db.Time.parse(data) catch error.InvalidType,
        else => return error.InvalidType,
    }
}

/// The text of a text-like column, copied: jsonb without its version
/// byte, uuid and numeric as their text. Other binary types are refused
/// (cast them to text in the SQL).
fn decodeText(arena: std.mem.Allocator, data: []const u8, type_oid: i32) ![]u8 {
    switch (type_oid) {
        Oid.jsonb => {
            if (data.len == 0 or data[0] != 1) return error.InvalidType;
            return arena.dupe(u8, data[1..]);
        },
        Oid.uuid => {
            const text = pg.types.UUID.toString(data) catch return error.InvalidType;
            return arena.dupe(u8, &text);
        },
        Oid.numeric => {
            if (data.len < 8) return error.InvalidType;
            const n = pg.Numeric.decodeKnown(data);
            const buf = try arena.alloc(u8, n.estimatedStringLen());
            return n.toString(buf) catch error.InvalidType;
        },
        Oid.bool, Oid.int8, Oid.int2, Oid.int4, Oid.oid_, Oid.xid, Oid.float4, Oid.float8, Oid.date, Oid.time, Oid.timestamp, Oid.timestamptz, Oid.interval, Oid.timetz => return error.InvalidType,
        else => return arena.dupe(u8, data),
    }
}

fn decodeJson(comptime F: type, arena: std.mem.Allocator, data: []const u8, type_oid: i32) !F {
    const text = switch (type_oid) {
        Oid.json, Oid.text, 1043 => data,
        Oid.jsonb => if (data.len > 0 and data[0] == 1) data[1..] else return error.InvalidType,
        else => return error.InvalidType,
    };
    return std.json.parseFromSliceLeaky(F, arena, text, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

fn decodeArray(comptime E: type, value: Value, type_oid: i32, arena: std.mem.Allocator) ![]E {
    if (E == db.Time or E == ?db.Time) {
        const Raw = if (E == db.Time) i64 else ?i64;
        const raw = try decodeArray(Raw, value, type_oid, arena);
        const out = try arena.alloc(E, raw.len);
        for (raw, out) |r, *o| o.* = if (E == db.Time) .{ .us = r } else if (r) |v| db.Time{ .us = v } else null;
        return out;
    }
    var it = pg.Iterator(E).fromPgzRow(value, type_oid) catch return error.InvalidType;
    const out = try it.alloc(arena);
    // pg.zig copies strings, but not optional ones.
    if (E == ?[]const u8 or E == ?[]u8) {
        for (out) |*s| if (s.*) |v| {
            s.* = try arena.dupe(u8, v);
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// The caller's context, type-erased: a request or an `anole.db.Ctx`.

const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    any: *anyopaque,
    record: *const fn (any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error,
    request: ?*const dusty.Request,

    /// `internal.fail` on the context it stands for.
    fn fail(self: *const Ctx, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
        return self.record(self.any, map, detail);
    }

    fn failf(self: *const Ctx, map: db.ErrorMap, class: db.Class, comptime fmt: []const u8, args: anytype) db.Error {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch "(message lost: out of memory)";
        return self.fail(map, .{ .system = .postgresql, .class = class, .message = message });
    }
};

fn erase(c: anytype) Ctx {
    const C = @TypeOf(c);
    if (C == *Ctx or C == *const Ctx) return c.*;
    const R = struct {
        fn record(any: *anyopaque, map: db.ErrorMap, detail: db.ErrorDetail) db.Error {
            return internal.fail(@as(C, @ptrCast(@alignCast(any))), map, detail);
        }
    };
    return .{ .io = c.io, .arena = c.arena, .any = @ptrCast(c), .record = R.record, .request = internal.requestOf(c) };
}

// ---------------------------------------------------------------------------
// Tests. Those against a live server are in live_test.zig
// (`-Dpostgres-test-url=postgres://...`, tests/postgres/run.sh).

const testing = std.testing;

test {
    _ = @import("live_test.zig");
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

test "pg: settings from a URL, the PG* variables and the defaults" {
    if (@TypeOf(std.process.Environ.empty.block) != std.process.Environ.PosixBlock) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [256]u8 = undefined;

    // Nothing set: libpq's defaults, as a local server takes them.
    const none = try Settings.resolve(arena, .{ .environ = .empty });
    try testing.expectEqualStrings("postgres://postgres@127.0.0.1:5432/postgres", try std.fmt.bufPrint(&buf, "{f}", .{none}));
    try testing.expectEqual(SslMode.prefer, none.sslmode);
    try testing.expect(none.password == null and none.unix_path == null and none.connect_timeout == null);

    // A full URL; what libpq does not know becomes a run-time parameter.
    const full = try Settings.resolve(arena, .{ .environ = .empty, .url = "postgresql://app:p%40ss@db.internal:6432/main?sslmode=verify-full&sslrootcert=ca.pem" ++
        "&application_name=api&connect_timeout=3&pool_max_conns=12&search_path=app,public&options=-c%20statement_timeout%3D5s" });
    try testing.expectEqualStrings("db.internal", full.host);
    try testing.expectEqual(@as(u16, 6432), full.port);
    try testing.expectEqualStrings("app", full.user);
    try testing.expectEqualStrings("p@ss", full.password.?);
    try testing.expectEqualStrings("main", full.database);
    try testing.expectEqual(SslMode.verify_full, full.sslmode);
    try testing.expectEqualStrings("ca.pem", full.sslrootcert.?);
    try testing.expectEqualStrings("api", full.application_name.?);
    try testing.expectEqual(@as(i64, 3), full.connect_timeout.?.toSeconds());
    try testing.expectEqual(@as(?u32, 12), full.max_connections);
    try testing.expectEqual(@as(usize, 2), full.parameters.len);
    try testing.expectEqualStrings("search_path", full.parameters[0].name);
    try testing.expectEqualStrings("app,public", full.parameters[0].value);
    try testing.expectEqualStrings("-c statement_timeout=5s", full.parameters[1].value);
    // The password stays out of logs.
    try testing.expectEqualStrings("postgres://app@db.internal:6432/main", try std.fmt.bufPrint(&buf, "{f}", .{full}));

    // A Unix socket's directory; the database defaults to the user's name.
    const sock = try Settings.resolve(arena, .{ .environ = .empty, .url = "postgres://worker@%2Fvar%2Frun%2Fpostgresql:5433" });
    try testing.expectEqualStrings("/var/run/postgresql/.s.PGSQL.5433", sock.unix_path.?);
    try testing.expectEqualStrings("worker", sock.database);
    try testing.expectEqualStrings("postgres://worker@/var/run/postgresql/.s.PGSQL.5433/worker", try std.fmt.bufPrint(&buf, "{f}", .{sock}));

    // require with a root certificate checks the chain, as in libpq.
    try testing.expectEqual(SslMode.verify_ca, (try Settings.resolve(arena, .{ .environ = .empty, .url = "postgres://h/d?sslmode=require&sslrootcert=ca.pem" })).sslmode);
    try testing.expect((try Settings.resolve(arena, .{ .environ = .empty, .url = "postgres://h/d?sslnegotiation=direct" })).direct_tls);
    try testing.expectEqualStrings("::1", (try Settings.resolve(arena, .{ .environ = .empty, .url = "postgres://[::1]:7/d" })).host);

    // The variables fill in what the URL leaves out; DATABASE_URL is the URL.
    const env = environ(&.{ "PGHOST=pg.local", "PGPORT=6000", "PGUSER=svc", "PGPASSWORD=secret", "PGSSLMODE=require", "PGAPPNAME=batch" });
    const from_env = try Settings.resolve(arena, .{ .environ = env });
    try testing.expectEqualStrings("postgres://svc@pg.local:6000/svc", try std.fmt.bufPrint(&buf, "{f}", .{from_env}));
    try testing.expectEqualStrings("secret", from_env.password.?);
    try testing.expectEqual(SslMode.require, from_env.sslmode);
    try testing.expectEqualStrings("batch", from_env.application_name.?);
    const mixed = try Settings.resolve(arena, .{ .environ = env, .url = "postgres://other@db/app?sslmode=disable" });
    try testing.expectEqualStrings("postgres://other@db:6000/app", try std.fmt.bufPrint(&buf, "{f}", .{mixed}));
    try testing.expectEqualStrings("secret", mixed.password.?);
    try testing.expectEqual(SslMode.disable, mixed.sslmode);
    const url_env = try Settings.resolve(arena, .{ .environ = environ(&.{"DATABASE_URL=postgres://u:pw@from-env:5544/x"}) });
    try testing.expectEqualStrings("postgres://u@from-env:5544/x", try std.fmt.bufPrint(&buf, "{f}", .{url_env}));

    // Refused, with the reason (logged by `resolve`).
    const Bad = struct { []const u8, []const u8 };
    for ([_]Bad{
        .{ "mysql://h/d", "the scheme is \"mysql\"" },
        .{ "postgres://u:hunter2@h/d?sslmode=verify", "sslmode \"verify\" is not one of" },
        .{ "postgres://h/d?connect_timeout=soon", "connect_timeout \"soon\"" },
        .{ "postgres://h/d?pool_max_conns=0", "pool_max_conns is 0" },
        .{ "postgres://h/d?sslpassword=x", "the parameter sslpassword is not supported" },
        .{ "postgres://h:99999/d", "InvalidPort" },
        .{ "host=localhost dbname=app", "InvalidUrl" },
    }) |bad| {
        var why: Settings.Why = .{ .arena = arena };
        try testing.expectError(error.InvalidDatabaseUrl, Settings.parse(arena, .{ .environ = .empty, .url = bad[0] }, &why));
        try testing.expect(std.mem.indexOf(u8, why.text.?, bad[1]) != null);
        try testing.expect(std.mem.indexOf(u8, why.text.?, "hunter2") == null);
    }
    var why: Settings.Why = .{ .arena = arena };
    try testing.expectError(error.InvalidDatabaseUrl, Settings.parse(arena, .{ .environ = environ(&.{"PGPORT=x"}) }, &why));
    try testing.expectEqualStrings("PGPORT \"x\" is not a port number", why.text.?);
}

test "pg: SQLSTATEs to classes" {
    const Case = struct { []const u8, db.Class };
    for ([_]Case{
        .{ "23505", .unique },
        .{ "23P01", .exclusion },
        .{ "23503", .foreign_key },
        .{ "23502", .not_null },
        .{ "23514", .check },
        .{ "40001", .serialization },
        .{ "40P01", .deadlock },
        .{ "57014", .timeout },
        .{ "08006", .unavailable },
        .{ "53300", .unavailable },
        .{ "57P01", .unavailable },
        .{ "42P01", .other },
        .{ "22012", .other },
        .{ "", .other },
    }) |case| try testing.expectEqual(case[1], classify(case[0]));
}

test "pg: column values into Zig types" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const V = struct {
        fn of(data: []const u8) Value {
            return .{ .is_null = false, .data = data };
        }
    };
    const null_value: Value = .{ .is_null = true, .data = &.{} };

    // Integers widen and narrow with a range check.
    const int4 = std.mem.toBytes(std.mem.nativeToBig(i32, 300));
    try testing.expectEqual(@as(i64, 300), try decode(i64, V.of(&int4), Oid.int4, arena));
    try testing.expectEqual(@as(u16, 300), try decode(u16, V.of(&int4), Oid.int4, arena));
    try testing.expectError(error.OutOfRange, decode(u8, V.of(&int4), Oid.int4, arena));
    const int8 = std.mem.toBytes(std.mem.nativeToBig(i64, -5));
    try testing.expectError(error.OutOfRange, decode(u32, V.of(&int8), Oid.int8, arena));
    try testing.expectEqual(@as(f64, -5), try decode(f64, V.of(&int8), Oid.int8, arena));
    try testing.expectError(error.InvalidType, decode(i64, V.of("12"), Oid.text, arena));

    // NULL: an optional, or an error.
    try testing.expectEqual(@as(?i64, null), try decode(?i64, null_value, Oid.int8, arena));
    try testing.expectError(error.UnexpectedNull, decode(i64, null_value, Oid.int8, arena));

    const float8 = std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(@as(f64, 2.5))));
    try testing.expectEqual(@as(f32, 2.5), try decode(f32, V.of(&float8), Oid.float8, arena));
    try testing.expect(try decode(bool, V.of(&.{1}), Oid.bool, arena));

    // numeric 1234.5: 2 digits of base 10000, weight 0, positive, scale 1.
    const numeric = [_]u8{ 0, 2, 0, 0, 0, 0, 0, 1, 0x04, 0xd2, 0x13, 0x88 };
    try testing.expectEqual(@as(f64, 1234.5), try decode(f64, V.of(&numeric), Oid.numeric, arena));
    try testing.expectEqualStrings("1234.5", try decode([]const u8, V.of(&numeric), Oid.numeric, arena));

    // Times: timestamp(tz) from PostgreSQL's epoch, date in days.
    const ts = std.mem.toBytes(std.mem.nativeToBig(i64, 0));
    try testing.expectEqual(@as(i64, 946_684_800_000_000), (try decode(db.Time, V.of(&ts), Oid.timestamptz, arena)).us);
    const day = std.mem.toBytes(std.mem.nativeToBig(i32, 1));
    try testing.expectEqual(@as(i64, 946_771_200_000_000), (try decode(db.Time, V.of(&day), Oid.date, arena)).us);
    const infinity = std.mem.toBytes(std.mem.nativeToBig(i64, std.math.maxInt(i64)));
    try testing.expectEqual(std.math.maxInt(i64), (try decode(db.Time, V.of(&infinity), Oid.timestamp, arena)).us);
    try testing.expectError(error.InvalidType, decode(db.Time, V.of(&int4), Oid.int4, arena));

    // Text: copied, so the row's buffer can go; uuid as its text, jsonb
    // without its version byte; numbers refused.
    var row_buffer = "hello".*;
    const text = try decode([]const u8, V.of(&row_buffer), Oid.text, arena);
    @memset(&row_buffer, 'x');
    try testing.expectEqualStrings("hello", text);
    const uuid = [_]u8{ 0x16, 0x6b, 0x47, 0x51, 0xd7, 0x02, 0x4f, 0xb9, 0x9a, 0x2a, 0xcd, 0x6b, 0x69, 0xed, 0x18, 0xd6 };
    try testing.expectEqualStrings("166b4751-d702-4fb9-9a2a-cd6b69ed18d6", try decode([]const u8, V.of(&uuid), Oid.uuid, arena));
    try testing.expectEqualStrings("{\"a\":1}", try decode([]const u8, V.of("\x01{\"a\":1}"), Oid.jsonb, arena));
    try testing.expectError(error.InvalidType, decode([]const u8, V.of(&int4), Oid.int4, arena));

    // Enums by label, structs and std.json.Value from JSON.
    const Color = enum { red, green };
    try testing.expectEqual(Color.green, try decode(Color, V.of("green"), 16384, arena));
    try testing.expectError(error.InvalidType, decode(Color, V.of("blue"), 16384, arena));
    const Point = struct { x: i32, y: i32 = 0 };
    const p = try decode(Point, V.of("\x01{\"x\":3,\"z\":true}"), Oid.jsonb, arena);
    try testing.expectEqual(Point{ .x = 3 }, p);
    const any = try decode(std.json.Value, V.of("[1,\"two\"]"), Oid.json, arena);
    try testing.expectEqualStrings("two", any.array.items[1].string);
    try testing.expectError(error.InvalidType, decode(Point, V.of(&int4), Oid.int4, arena));

    // Arrays: int4[] {7,8}.
    const array = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 7, 0, 0, 0, 4, 0, 0, 0, 8 };
    try testing.expectEqualSlices(i32, &.{ 7, 8 }, try decode([]i32, V.of(&array), 1007, arena));
}

test "pg: parameters, operation names, BEGIN" {
    const P = Params(@TypeOf(.{ @as(i64, 1), db.Time.fromSeconds(1), @as(?db.Time, null), "x" }));
    try testing.expect(@typeInfo(P).@"struct".field_types[1] == i64);
    try testing.expect(@typeInfo(P).@"struct".field_types[2] == ?i64);
    const p = params(.{ @as(i64, 1), db.Time.fromSeconds(1), @as(?db.Time, db.Time.fromMicros(5)), "x" });
    try testing.expectEqual(@as(i64, 1_000_000), p[1]);
    try testing.expectEqual(@as(?i64, 5), p[2]);
    _ = params(.{});

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("SELECT", operation(&buf, "  select id FROM posts"));
    try testing.expectEqualStrings("WITH", operation(&buf, "\n(with x AS (SELECT 1) SELECT * FROM x)"));
    try testing.expectEqualStrings("QUERY", operation(&buf, "-- comment\nSELECT 1"));

    var sql: [96]u8 = undefined;
    try testing.expectEqualStrings("BEGIN", beginSql(&sql, .{}));
    try testing.expectEqualStrings("BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY", beginSql(&sql, .{ .isolation = .serializable, .read_only = true }));
}

test "pg: no connection before a call, and a refused one is a 503 with its reason" {
    const zio = @import("zio");
    const gpa = testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;

    // Port 1: nothing listens there.
    const d = try Client.init(gpa, io, .{ .url = "postgres://u@127.0.0.1:1/x?sslmode=disable", .environ = .empty, .max_connections = 3 });
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.pools.pools.len);
    try testing.expectEqual(@as(usize, 2), d.pools.pools[0].pool._conns.len);
    try testing.expectEqual(@as(usize, 1), d.pools.pools[1].pool._conns.len);
    for (d.pools.pools) |*s| try testing.expectEqual(@as(usize, 0), s.pool.stats().in_use);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var c: db.Ctx = .{ .io = io, .arena = arena_state.allocator() };
    try testing.expectError(error.ServiceUnavailable, d.exec(&c, "SELECT 1", .{}));
    const detail = db.lastError(&c).?;
    try testing.expectEqual(db.Class.unavailable, detail.class);
    try testing.expectStringStartsWith(detail.message, "cannot connect to postgres://u@127.0.0.1:1/x: ");
    try testing.expectError(error.ServiceUnavailable, d.one(i64, &c, "SELECT $1::int8", .{@as(i64, 1)}));
    // The slots the failed connects reserved were given back.
    for (d.pools.pools) |*s| try testing.expectEqual(@as(usize, 0), s.pool.stats().in_use);
    try testing.expect(!Client.ping(d, io));

    // Without TLS built in, `init` refuses these (and logs why).
    try testing.expect(!SslMode.prefer.needsTls() and SslMode.require.needsTls() and SslMode.verify_full.needsTls());
}
