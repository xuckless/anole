//! Anole: one Zig server core for REST, WebSockets and gRPC.
//!
//! Pre-alpha. `Server` is the entry point: HTTP/1.1, HTTP/2 (h2c and over
//! TLS) and HTTPS on BoringSSL, with routing, middleware and compression from
//! the dusty fork. Each namespace below wraps a library built under Zig 0.17;
//! one whose feature is turned off at build time is an empty struct, and its
//! C library is neither fetched nor compiled.
const std = @import("std");

/// The feature flags this build was configured with (`-Dprofile`, `-Dtls`,
/// `-Dhttp2`, `-Dhttp3`, `-Dgrpc`, `-Dwebsocket`, `-Dauth`, `-Dpostgres`,
/// `-Dsqlite`, `-Dmongodb`...).
pub const features = @import("build_options");

/// The async runtime (lalinsky/zio). Executables pick the scheduling mode with
/// `pub const zio_options: anole.zio.Options = .{ .scheduling = .pinned };`
/// in their root file.
pub const zio = @import("zio");

/// The server: runtime, listeners, signals and drain in one call. See
/// `server.zig`.
pub const Server = @import("server.zig").Server;
/// A server without state: `anole.App.init(gpa, .{})`, then routes, then
/// `app.listen(":3000")`.
pub const App = @import("server.zig").App;
pub const ServerOptions = @import("server.zig").Options;
/// A TLS certificate for `listenTls` and `ServerOptions.https`:
/// `.fromFiles("cert.pem", "key.pem")`, `.fromPem(cert, key)` or
/// `.dev_self_signed`.
pub const Cert = ServerOptions.Cert;
/// A listener in `ServerOptions.listeners`: address or unix socket, TLS,
/// protocols, name.
pub const Listener = ServerOptions.Listener;
/// Middleware that serves a group's routes on one listener alone (by
/// name), 404 on the others: `app.group("/admin", .{anole.onlyOn("admin")})`.
pub const onlyOn = @import("server.zig").onlyOn;
/// Middleware as a function, `fn (req, res, next: anole.Next) !void`;
/// `use`, `group` and `with` also take the bare function.
pub const func = @import("handlers.zig").func;
pub const Next = @import("handlers.zig").Next;
pub const noWait = @import("handlers.zig").noWait;
/// A route whose answers are kept per executor and served from memory:
/// `app.get("/feed", anole.cached(.{ .ttl = .fromSeconds(5) }, feed))`.
/// See `middleware.ResponseCache`.
pub const cached = @import("handlers.zig").cached;
/// The server's outbound HTTP client, from a request or a `std.Io` of the
/// server's runtime: `anole.client(req).fetch(url, .{})`.
pub const client = @import("client.zig").client;
pub const Client = @import("client.zig").Client;
pub const ClientResponse = @import("client.zig").Response;
pub const FetchOptions = @import("client.zig").FetchOptions;
/// Declare in the executable's root file: `pub const zio_options =
/// anole.zio_options;` (pinned scheduling).
pub const zio_options = @import("server.zig").zio_options;
/// Blocking or CPU-heavy work on a pool thread while the request's
/// coroutine waits (`Options.blocking`); password hashing uses it.
pub const blocking = @import("blocking.zig");
/// Optional, in the executable's root file: `pub const std_options =
/// anole.std_options;`. Keeps the runtime's per-thread start and stop lines
/// and Anole's per-connection debug lines out of a Debug build's output;
/// warnings, errors and info (the startup line, the access log) stay.
pub const std_options = @import("log.zig").std_options;
/// Anole's libraries log under Anole's own scopes (`anole`, `access`,
/// `anole_h2`, `anole_h3`); this log function is kept for programs that set
/// it, and renames the scopes older builds used.
pub const logFn = @import("log.zig").logFn;

/// HTTP/1.1 and HTTP/2 server, router and client (the xuckless/dusty fork of
/// lalinsky/dusty, on zio), for everything `Server` does not wrap.
pub const http = @import("http/root.zig");
pub const Request = http.Request;
pub const Response = http.Response;
/// The built-in middleware: the HTTP core's (`Cors`, `Compress`,
/// `RequestId`, `Logger`, `Session`) and `ResponseCache`.
pub const middleware = struct {
    pub const Cors = http.middleware.Cors;
    pub const Compress = http.middleware.Compress;
    pub const RequestId = http.middleware.RequestId;
    pub const Logger = http.middleware.Logger;
    pub const Session = http.middleware.Session;
    /// Whole responses kept per executor and served without running the
    /// handler; `anole.cached` puts one on a route, `app.responseCache`
    /// makes one for several.
    pub const ResponseCache = @import("cache/response.zig").ResponseCache;
};
pub const Middleware = http.Middleware;
/// The answer the server gives a handler error when nothing else does
/// (status-named errors such as `error.Unauthorized` to their status,
/// request-body faults to 4xx, the rest to 500), for an `uncaughtError` or
/// `Options.error_handler` to fall back on.
pub const defaultError = http.defaultError;
/// The status a handler error stands for, or null for a 500.
pub const errorStatus = http.errorStatus;

/// TLS on BoringSSL (-Dtls=boringssl): the bindings, the module dusty uses for
/// HTTPS, and `selfSigned` for development certificates.
pub const tls = if (features.tls == .boringssl) @import("tls/root.zig") else struct {};

/// nghttp2 bindings (-Dhttp2). The HTTP/2 server engine lives in the dusty
/// fork and serves through `Server`.
pub const h2 = if (features.http2) @import("h2/root.zig") else struct {};

/// HTTP/3 over QUIC on ngtcp2 + nghttp3 (-Dhttp3): the endpoint `Server`
/// runs when `Options.http3` is set, and a client (`ClientConnection`).
pub const h3 = if (features.http3) @import("h3/root.zig") else struct {};

/// gzip/deflate on zlib-ng and zstd (-Dcompression). dusty uses the zlib
/// side for response compression and request decoding.
pub const compression = if (features.compression) @import("compression/root.zig") else struct {};

/// WebSockets (-Dwebsocket): RFC 6455 over HTTP/1.1 (dusty's) and RFC 8441
/// over HTTP/2 behind one `upgrade`, permessage-deflate, and `Rooms`.
pub const websocket = if (features.websocket) @import("websocket/root.zig") else struct {};

/// WebTransport over HTTP/3 (-Dhttp3; draft-02, what Chrome and Firefox
/// speak): sessions with streams and datagrams, `accept` from a handler or
/// `Server.webtransport` for a route.
pub const webtransport = if (features.http3) @import("webtransport.zig") else struct {};

/// JSON on yyjson (-Djson): parse into and stringify Zig types.
pub const json = if (features.json) @import("json/root.zig") else struct {};

/// A Redis/Valkey client on std.Io (-Dredis), with hiredis's RESP parser.
pub const redis = if (features.redis) @import("redis/root.zig") else struct {};

/// What the database connectors share: calls that take the request, a
/// pool per executor, errors that are statuses (`NotFound` 404, `Conflict`
/// 409...), `Time`, connection URLs from the environment, and the health,
/// metrics and tracing hooks.
pub const db = @import("db/root.zig");

/// PostgreSQL (-Dpostgres): `app.postgres(.{})` (DATABASE_URL), then
/// `app.db.all(Post, req, sql, .{args})` and the other `anole.db` verbs,
/// on Anole's fork of pg.zig with a pool per executor.
pub const pg = if (features.postgres) @import("pg/root.zig") else struct {};

/// SQLite, built in (-Dsqlite): a file or `:memory:`, writes on a writer
/// thread, reads on the blocking pool; `app.sqlite("app.db")`.
pub const sqlite = if (features.sqlite) @import("sqlite/root.zig") else struct {};

/// A MongoDB client on std.Io (-Dmongodb): OP_MSG, SCRAM, TLS, replica
/// sets, a pool per executor, CRUD, aggregation and cursors, retryable
/// reads and writes. `app.mongodb(.{})` connects from `MONGODB_URI`.
pub const mongodb = if (features.mongodb) @import("mongodb/root.zig") else struct {};

/// BSON (-Dmongodb): documents, the struct mapping, ObjectId, Decimal128
/// and Extended JSON, as the MongoDB client reads and writes them.
pub const bson = if (features.mongodb) @import("bson") else struct {};

/// Outbound connections for the database clients: `ClientStream`, TCP or
/// a Unix socket, plain or TLS on BoringSSL.
pub const net = struct {
    pub const ClientStream = @import("net/client_stream.zig").ClientStream;
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

/// gRPC over HTTP/2 (-Dgrpc): wire pieces, and services generated by
/// zig-protobuf served through the router.
pub const grpc = if (features.grpc) @import("grpc/root.zig") else struct {};

/// Auth (-Dauth): JWT/JWKS verification and signing, OIDC, CSRF,
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
}

test "feature constraints hold" {
    if (features.grpc) try std.testing.expect(features.http2);
    if (features.http3) try std.testing.expect(features.tls != .none);
}

test "anole.h2 and anole.h3 export the same client names" {
    if (!features.http2 or !features.http3) return error.SkipZigTest;
    inline for (.{ "ClientConnection", "Stream", "ClientStream", "Header", "ConnectOptions", "RequestOptions", "StreamError" }) |name| {
        try std.testing.expect(@hasDecl(h2, name) and @hasDecl(h3, name));
    }
    // One error set for both, so code over either handles the same causes.
    try std.testing.expect(h2.StreamError == h3.StreamError);
    inline for (.{ "ca", "insecure_skip_verify" }) |field| {
        try std.testing.expect(@FieldType(h2.ConnectOptions.Tls, field) == @FieldType(h3.ConnectOptions.Tls, field));
    }
    inline for (.{ "connect_timeout", "timeout", "address", "host", "port" }) |field| {
        try std.testing.expect(@FieldType(h2.ConnectOptions, field) == @FieldType(h3.ConnectOptions, field));
    }
    try std.testing.expect(@FieldType(h2.RequestOptions, "timeout") == @FieldType(h3.RequestOptions, "timeout"));
}
