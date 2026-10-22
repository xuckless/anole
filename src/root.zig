//! Anole is one server core for Zig backends: HTTP/1.1, HTTP/2 and HTTP/3,
//! WebSocket, WebTransport and gRPC behind one router, with TLS on
//! BoringSSL, auth, database connectors (PostgreSQL, SQLite, MongoDB,
//! Redis) and observability built in. Every bundled library sits behind a
//! build flag (`-Dprofile=minimal|web|full`, `-Dhttp3=false`, ...), so the
//! parts an application does not use stay out of its binary.
//!
//! A server with two routes, on every interface at port 3000:
//!
//!     const std = @import("std");
//!     const anole = @import("anole");
//!
//!     fn hello(_: *anole.Request, res: *anole.Response) !void {
//!         res.body = "Hello, World!";
//!     }
//!
//!     fn user(req: *anole.Request, res: *anole.Response) !void {
//!         const id = req.params.getInt(u64, "id") orelse return error.NotFound;
//!         try res.json(.{ .id = id });
//!     }
//!
//!     pub fn main(init: std.process.Init) !void {
//!         var app = try anole.App.init(init.gpa, .{});
//!         defer app.deinit();
//!         app.get("/", hello);
//!         app.get("/users/:id", user);
//!         try app.listen(":3000");
//!     }
//!
//! `listen` serves until SIGINT or SIGTERM, then lets the requests in flight
//! finish. A handler answers by setting `res` or by returning an error:
//! `error.NotFound` is a 404, `error.Unauthorized` a 401, and anything
//! without a status a 500.
//!
//! Where to start:
//!
//! - `App` and `Server`: routes, middleware, listeners (`listen`,
//!   `listenTls`, `run`) and the one-line helpers (`app.postgres`,
//!   `app.metrics`, `app.ws`, `app.grpc`...). `ServerOptions` holds every
//!   setting, `Cert` and `Listener` the TLS and listener ones.
//! - `Request` and `Response`: what a handler reads and writes
//!   (`req.params`, `req.bind`, `res.json`, `res.fail`...).
//! - `middleware`, `func` and `Next`: built-in and hand-written middleware.
//! - `websocket`, `webtransport`, `grpc`: the other protocols.
//! - `db` and the connectors `pg`, `sqlite`, `mongodb`, `redis`.
//! - `auth`, `session`, `ratelimit`, `early_data`: access control.
//! - `observe`: metrics, traces, access logs and health checks.
//! - `client`, `h2`, `h3`: outbound HTTP; `tls`: certificates.
//! - `http`: the HTTP core underneath, for anything `Server` does not wrap.
//!
//! A namespace whose feature is off in this build (see `features`) is an
//! empty struct, and its C library is neither fetched nor compiled.
//!
//! Guides: https://xuckless.github.io/anole/ · Wiki:
//! https://github.com/xuckless/anole/wiki
const std = @import("std");

/// The feature flags this build was configured with (`-Dprofile`, `-Dtls`,
/// `-Dhttp2`, `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dpostgres`,
/// `-Dsqlite`, `-Dmongodb`...).
pub const features = @import("build_options");

/// The version of Anole this build is (`build.zig.zon`).
pub const version = features.version;

/// The async runtime underneath (lalinsky/zio). `Server` owns one; reach
/// for this only to run zio code of your own beside it. Anole needs
/// zio's pinned scheduling, which its build of zio uses by default: a root
/// file that declares `zio_options` must keep `.scheduling = .pinned`
/// (`pub const zio_options = anole.zio_options;`).
pub const zio = @import("zio");

/// A server whose handlers share state of type `Ctx`:
/// `anole.Server(Store).init(gpa, .{}, &store)`, handlers
/// `fn (store: *Store, req, res) !void`. It owns the runtime (one executor
/// per core), the listeners, signals and the drain on shutdown.
pub const Server = @import("server.zig").Server;
/// A server without state: `anole.App.init(gpa, .{})`, then routes and
/// middleware, then `app.listen(":3000")` or `app.listenTls(...)`.
/// Everything `Server` has, with `(req, res)` handlers.
pub const App = @import("server.zig").App;
/// What `App.init` and `Server(Ctx).init` take: listeners (`http`,
/// `https`, `http3`, `listeners`), executors, limits and timeouts
/// (`server`), error answers, the blocking pool. `.{}` is a working
/// default.
pub const ServerOptions = @import("server.zig").Options;
/// A TLS certificate for `listenTls` and `ServerOptions.https`:
/// `.fromFiles("cert.pem", "key.pem")`, `.fromPem(cert, key)` or
/// `.dev_self_signed`.
pub const Cert = ServerOptions.Cert;
/// Certificate authorities a peer's certificate must chain to
/// (`Ca.fromFile("ca.pem")`, `.system`, `.dir`, `.fromPem`).
pub const Ca = @import("http/root.zig").Ca;
/// Mutual TLS on a listener: `.{ .ca = .fromFile("clients-ca.pem") }`.
pub const ClientAuth = ServerOptions.ClientAuth;
/// A length of time: `.fromSeconds(30)`.
pub const Duration = @import("server.zig").Duration;
/// The outbound HTTP client's settings (`ServerOptions.client`).
pub const ClientOptions = @import("http/root.zig").ClientOptions;
/// Every way `init`, `listen`, `listenTls`, `run` and `waitReady` fail.
pub const ServerError = @import("errors.zig").ServerError;
/// What `reloadCertificates` and `setCertificate` fail with.
pub const TlsLoadError = @import("errors.zig").TlsLoadError;
/// Error-name helpers shared with the C ABI.
pub const errors = @import("errors.zig");
/// A listener in `ServerOptions.listeners`: address or unix socket, TLS,
/// protocols, name.
pub const Listener = ServerOptions.Listener;
/// Middleware that serves a group's routes on one listener alone (by
/// name), 404 on the others: `app.group("/admin", .{anole.onlyOn("admin")})`.
pub const onlyOn = @import("server.zig").onlyOn;
/// Middleware as a function, `fn (req, res, next: anole.Next) !void`;
/// `use`, `group` and `with` also take the bare function.
pub const func = @import("handlers.zig").func;
/// What a function middleware calls to go on: `return next.call();`.
pub const Next = @import("handlers.zig").Next;
/// Marks a handler that never waits on I/O, so HTTP/2 and HTTP/3 run it
/// without a task of its own: `app.get("/ping", anole.noWait(ping))`.
/// Not for handlers that query a database or call another service.
pub const noWait = @import("handlers.zig").noWait;
/// A route whose answers are kept per executor and served from memory:
/// `app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed))`.
/// See `middleware.ResponseCache`.
pub const cached = @import("handlers.zig").cached;
/// The server's outbound HTTP client, from a request or a `std.Io` of the
/// server's runtime: `anole.client(req).fetch(url, .{})`.
pub const client = @import("client.zig").client;
/// What `client` returns: `fetch(url, options)`.
pub const Client = @import("client.zig").Client;
/// A response from `Client.fetch`: `status`, `header`, `body`, `json`;
/// `deinit` it.
pub const ClientResponse = @import("client.zig").Response;
/// `Client.fetch`'s options: method, headers, body, timeout.
pub const FetchOptions = @import("client.zig").FetchOptions;
/// The zio options Anole needs (pinned scheduling). Optional, since
/// Anole's zio defaults to them; a root file that sets zio options of its
/// own declares `pub const zio_options = anole.zio_options;`.
pub const zio_options = @import("server.zig").zio_options;
/// Blocking or CPU-heavy work on a pool thread while the request's
/// coroutine waits (`Options.blocking`); password hashing uses it.
pub const blocking = @import("blocking.zig");
/// Optional, in the executable's root file: `pub const std_options =
/// anole.std_options;`. Keeps the runtime's per-thread start and stop lines
/// and Anole's per-connection debug lines out of a Debug build's output;
/// warnings, errors and info (the startup line, the access log) stay.
pub const std_options = @import("log.zig").std_options;
/// Optional, in the executable's root file: `pub const panic = anole.panic;`.
/// A panic is written as one error line (message and stack trace) through
/// the log function, so it lands where the logs go, then the process aborts.
pub const panic = @import("panic.zig").panic;
/// The logging half of `panic`, for a root file with a panic handler of its
/// own.
pub const logPanic = @import("panic.zig").log;
/// Anole's libraries log under Anole's own scopes (`anole`, `access`,
/// `anole_h2`, `anole_h3`); this log function is kept for programs that set
/// it, and renames the scopes older builds used.
pub const logFn = @import("log.zig").logFn;

/// The HTTP core under `Server` (HTTP/1.1, the HTTP/2 engine, router,
/// middleware, static files, client; adapted from lalinsky/dusty), for
/// everything `Server` does not wrap.
pub const http = @import("http/root.zig");
/// The engine under the C ABI (`include/anole.h`, `zig build capi`): the
/// queues, handles and lifecycle that libanole's exported functions wrap.
/// For bindings' builds, not for Zig applications.
pub const capi = @import("capi/engine.zig");
/// What a handler reads: `req.params`, `req.query`, `req.headers`,
/// `req.bind(T)`, `req.body()`, `req.arena`, `req.io`.
pub const Request = http.Request;
/// What a handler writes: `res.status`, `res.body`, `res.json(value)`,
/// `res.header(name, value)`, `res.fail(status, message)`.
pub const Response = http.Response;
/// The built-in middleware: the HTTP core's (`Cors`, `Compress`,
/// `RequestId`, `Logger`) and `ResponseCache`. Sessions are
/// `anole.session.Middleware`, rate limits `anole.ratelimit.Middleware`,
/// auth in `anole.auth`.
///
///     app.use(anole.middleware.RequestId.init(.{}));
///     app.use(anole.middleware.Cors.init(.{}));
///     app.use(anole.middleware.Compress.init());
pub const middleware = struct {
    /// Cross-origin requests: `Cors.init(.{})` allows any origin.
    pub const Cors = http.middleware.Cors;
    /// Compresses responses (zstd, Brotli, gzip) the client accepts.
    pub const Compress = http.middleware.Compress;
    /// An ID per request, in `req.id` and `X-Request-Id`.
    pub const RequestId = http.middleware.RequestId;
    /// A log line per request (scope `access`); `anole.observe.AccessLog`
    /// has more formats.
    pub const Logger = http.middleware.Logger;
    /// Whole responses kept per executor and served without running the
    /// handler; `anole.cached` puts one on a route, `app.responseCache`
    /// makes one for several.
    pub const ResponseCache = @import("cache/response.zig").ResponseCache;
};
/// A middleware handle for `Server(Ctx)`: `anole.Middleware(Ctx).init(&value)`
/// for a middleware value you keep alive yourself (`use` and `group` copy
/// values otherwise).
pub const Middleware = http.Middleware;
/// The answer the server gives a handler error when nothing else does
/// (status-named errors such as `error.Unauthorized` to their status,
/// request-body faults to 4xx, the rest to 500), for an `uncaughtError` or
/// `Options.error_handler` to fall back on.
pub const defaultError = http.defaultError;
/// The status a handler error stands for, or null for a 500.
pub const errorStatus = http.errorStatus;

/// TLS on BoringSSL (`-Dtls=boringssl`): `selfSigned` for development
/// certificates and `version()`. Listener certificates are `Cert`; the
/// clients take their TLS options inline.
pub const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};

/// HTTP/2 (`-Dhttp2`): a client (`ClientConnection`, the same API as
/// `h3`'s) and `version()`. The server side is built into `Server` (h2 by
/// ALPN, h2c on cleartext listeners).
pub const h2 = if (features.http2) @import("h2/root.zig") else struct {};

/// HTTP/3 over QUIC on ngtcp2 + nghttp3 (`-Dhttp3`): the endpoint `Server`
/// runs beside a TLS listener (`listenTls`, `ServerOptions.http3`), a
/// client (`ClientConnection`, the same API as `h2`'s) and `version()`.
pub const h3 = if (features.http3) @import("h3/root.zig") else struct {};

/// gzip and deflate on zlib-ng, and zstd (`-Dcompression`), as the server
/// uses them for response compression and request decoding; for code of
/// your own that compresses or decompresses.
pub const compression = if (features.compression) @import("compression/root.zig") else struct {};

/// WebSockets (`-Dwebsocket`): RFC 6455 over HTTP/1.1, RFC 8441 over
/// HTTP/2 and RFC 9220 over HTTP/3 behind one `upgrade` (or `app.ws`),
/// permessage-deflate, and `Rooms`.
pub const websocket = if (features.websocket) @import("websocket/root.zig") else struct {};

/// WebTransport over HTTP/3 (`-Dhttp3`; draft-02, what Chrome and Firefox
/// speak): sessions with streams and datagrams, `accept` from a handler or
/// `Server.webtransport` for a route.
pub const webtransport = if (features.http3) @import("webtransport.zig") else struct {};

/// JSON on yyjson (`-Djson`): parse into and stringify Zig types.
pub const json = if (features.json) @import("json/root.zig") else struct {};

/// Redis and Valkey (`-Dredis`): `state.redis = try app.redis(.{})`
/// (REDIS_URL), then `state.redis.get(req, key)`,
/// `state.redis.command(req, .{ "INCR", key })`, pipelines and pub/sub, with the `anole.db` calling convention and a pool per
/// executor.
pub const redis = if (features.redis) @import("redis/root.zig") else struct {};

/// What the database connectors share: calls that take the request, a
/// pool per executor, errors that are statuses (`NotFound` 404, `Conflict`
/// 409...), `Time`, connection URLs from the environment, and the health,
/// metrics and tracing hooks.
pub const db = @import("db/root.zig");

/// PostgreSQL (`-Dpostgres`): `state.db = try app.postgres(.{})`
/// (DATABASE_URL), then `state.db.all(Post, req, sql, .{args})` and the other `anole.db` verbs,
/// on Anole's fork of pg.zig with a pool per executor.
pub const pg = if (features.postgres) @import("pg/root.zig") else struct {};

/// SQLite, built in (`-Dsqlite`): a file or `:memory:`, writes on a writer
/// thread, reads on the blocking pool; `state.db = try app.sqlite("app.db")`,
/// then the same `anole.db` verbs as `pg`.
pub const sqlite = if (features.sqlite) @import("sqlite/root.zig") else struct {};

/// A MongoDB client on std.Io (`-Dmongodb`): OP_MSG, SCRAM, TLS, replica
/// sets, a pool per executor, CRUD, aggregation and cursors, retryable
/// reads and writes. `app.mongodb(.{})` connects from `MONGODB_URI`.
pub const mongodb = if (features.mongodb) @import("mongodb/root.zig") else struct {};

/// BSON (`-Dmongodb`): documents, the struct mapping, ObjectId, Decimal128
/// and Extended JSON, as the MongoDB client reads and writes them.
pub const bson = if (features.mongodb) @import("bson") else struct {};

/// Outbound connections for the database clients: `ClientStream`, TCP or
/// a Unix socket, plain or TLS on BoringSSL.
pub const net = struct {
    /// A connected stream: `connect`, then its reader and writer.
    pub const ClientStream = @import("net/client_stream.zig").ClientStream;
    /// Where and how `ClientStream.connect` connects.
    pub const ConnectOptions = @import("net/client_stream.zig").ConnectOptions;
};

/// Sessions: server-side stores (memory, Redis) or an encrypted cookie.
pub const session = @import("session/root.zig");

/// Early data (0-RTT) and replays (RFC 8470): `isEarly`, and the 425 Too
/// Early middleware.
pub const early_data = @import("early_data.zig");

/// Rate limiting: token buckets in memory or Redis, and a 429 middleware.
pub const ratelimit = @import("ratelimit/root.zig");

/// Observability: Prometheus metrics, OpenTelemetry traces, access logs,
/// health and readiness.
pub const observe = @import("observe/root.zig");

/// gRPC (`-Dgrpc`): services generated by zig-protobuf, served with
/// `app.grpc(Service, impl)` over gRPC, gRPC-Web, Connect and JSON
/// transcoding; `Call` for metadata, deadlines and status; and a client.
pub const grpc = if (features.grpc) @import("grpc/root.zig") else struct {};

/// Auth (`-Dauth`): JWT/JWKS verification and signing, OIDC, CSRF,
/// passwords, API keys, roles.
pub const auth = if (features.auth) @import("auth/root.zig") else struct {};

test {
    _ = @import("server.zig");
    _ = @import("api_test.zig");
    _ = @import("address.zig");
    _ = @import("handlers.zig");
    _ = @import("client.zig");
    _ = @import("app_test.zig");
    _ = @import("handoff.zig");
    _ = @import("cache/response.zig");
    _ = @import("cache/response_test.zig");
    _ = blocking;
    _ = @import("sd_notify.zig");
    _ = @import("panic.zig");
    _ = @import("fuzz.zig");
    _ = @import("log.zig");
    _ = http;
    _ = tls;
    _ = h2;
    _ = h3;
    _ = websocket;
    _ = webtransport;
    _ = compression;
    _ = grpc;
    _ = json;
    _ = redis;
    _ = sqlite;
    _ = db;
    _ = pg;
    _ = mongodb;
    _ = @import("net/client_stream.zig");
    _ = session;
    _ = early_data;
    _ = ratelimit;
    _ = auth;
    _ = observe;
    _ = capi;
}

test "feature constraints hold" {
    if (features.grpc) try std.testing.expect(features.http2);
    if (features.http3) try std.testing.expect(features.tls != .none);
}

test "anole.h2 and anole.h3 export the same client names" {
    if (!features.http2 or !features.http3) return error.SkipZigTest;
    inline for (.{ "ClientConnection", "Stream", "Header", "ConnectOptions", "RequestOptions", "StreamError", "version" }) |name| {
        try std.testing.expect(@hasDecl(h2, name) and @hasDecl(h3, name));
    }
    // One error set for both, so code over either handles the same causes.
    try std.testing.expect(h2.StreamError == h3.StreamError);
    inline for (.{ "ca", "insecure_skip_verify" }) |field| {
        try std.testing.expect(@FieldType(h2.ConnectOptions.Tls, field) == @FieldType(h3.ConnectOptions.Tls, field));
    }
    inline for (.{ "connect_timeout", "timeout", "address", "host", "port", "stream_window", "max_data", "max_header_list_size" }) |field| {
        try std.testing.expect(@FieldType(h2.ConnectOptions, field) == @FieldType(h3.ConnectOptions, field));
    }
    inline for (.{ "body", "timeout" }) |field| {
        try std.testing.expect(@FieldType(h2.RequestOptions, field) == @FieldType(h3.RequestOptions, field));
    }
    try std.testing.expect(@TypeOf(h2.version) == @TypeOf(h3.version));
}
