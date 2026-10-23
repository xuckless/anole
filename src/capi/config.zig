//! The C ABI's configuration: one JSON document (`include/anole.schema.json`
//! is its schema) parsed by `anole_server_create`, and the Anole server it
//! describes, built on the server's own thread at start. Everything that
//! never needs the language (listeners, fixed responses, static files, the
//! response cache, compression, CORS, JWT, rate limits, request IDs, access
//! logs, health and metrics) is Anole's own middleware and handlers; the
//! ABI only configures them.
const std = @import("std");
const anole = @import("../root.zig");
const http = anole.http;
const features = anole.features;

/// The document. Unknown keys are an error, with the line and column.
pub const Config = struct {
    /// Executor threads: 0 for one per CPU (cgroup-aware).
    executors: u32 = 0,
    /// "development" or "production". Null: ANOLE_ENV, else production.
    environment: ?anole.Environment = null,
    /// What sits in front: "standalone", "behind_proxy", "anole_lb",
    /// "platform" or "lambda". Null: ANOLE_DEPLOYMENT, else standalone.
    deployment: ?anole.Deployment = null,
    /// A 500 answer for an error with no status names the error. Null: on in
    /// development.
    error_detail: ?bool = null,
    /// Logging, process-wide: the format and a service name.
    log: Log = .{},
    /// Print the startup banner when stderr is a terminal and the logs are
    /// text. Off by default under the ABI: a binding opts in.
    banner: bool = false,
    /// The live console (docs/console.md): a control socket for `anole
    /// console`, and `anole_console_*`.
    console: Console = .{},
    listeners: []const Listener = &.{.{}},
    timeouts: Timeouts = .{},
    limits: Limits = .{},
    /// Trust in proxies in front: `trusted_hops` of them for the client's
    /// address from `X-Forwarded-For` (PROXY protocol is per listener),
    /// and whether `X-Forwarded-Proto` / `X-Forwarded-Host` count.
    proxy: anole.ServerOptions.Proxy = .{},
    /// How requests are read.
    request: anole.ServerOptions.RequestOptions = .{},
    /// How responses are written.
    response: anole.ServerOptions.ResponseOptions = .{},
    /// HTTP/2 settings, for h2c and h2 over TLS.
    http2: anole.ServerOptions.Http2 = .{},
    http3: Http3 = .{},
    /// How the server writes its own error answers: "auto", "json", "text".
    errors: http.ErrorFormat = .auto,
    /// Middleware for every route, in order, before the route's own.
    middleware: []const Middleware = &.{},
    routes: []const Route = &.{},
    /// gRPC services whose methods a consumer implements (-Dgrpc).
    grpc: ?Grpc = null,
    observe: Observe = .{},
    /// Databases for `anole_db_*`, opened at start.
    databases: []const Database = &.{},
    /// Message brokers for `anole_nats_*`, opened at start.
    brokers: []const Broker = &.{},

    pub const Console = struct {
        /// The control socket. Null: on (off under deployment lambda, on
        /// Windows, with ANOLE_CONSOLE=0).
        enabled: ?bool = null,
        /// What `anole console <name>` finds the app by; bindings pass the
        /// package or module name.
        name: ?[]const u8 = null,
        socket: ?[]const u8 = null,
        /// Null: on in development, off in production.
        allow_restart: ?bool = null,
        read_only: bool = false,
        log_buffer: usize = 4 * 1024 * 1024,
        errors_kept: u16 = 256,
        max_routes: u16 = 256,
        /// Shown in the console's status line, e.g. "node 22.11.0".
        runtime: ?[]const u8 = null,
    };

    pub const Log = struct {
        /// "auto" (JSON Lines in production, else text), "text" or "json".
        format: anole.log.Format = .auto,
        /// Written as "service" in every JSON record; at most 64 bytes.
        service: ?[]const u8 = null,
    };

    pub const Listener = struct {
        /// Unique; "http-<port>" / "https-<port>" when left out. Requests
        /// carry it (`listener` in the record).
        name: ?[]const u8 = null,
        /// "127.0.0.1" (this machine), "" (every interface, IPv6 and IPv4),
        /// "0.0.0.0", "::".
        /// Null: the deployment's ("127.0.0.1"; "" for anole_lb and platform).
        address: ?[]const u8 = null,
        /// 0 picks a free port (`anole_server_listener`). Null: 8080, or
        /// $PORT under platform.
        port: ?u16 = null,
        /// A unix domain socket at this path instead of address and port.
        unix: ?[]const u8 = null,
        /// TLS with this certificate; cleartext when left out.
        tls: ?Tls = null,
        http1: bool = true,
        /// HTTP/2: h2 by ALPN over TLS, h2c (prior knowledge) in cleartext.
        http2: bool = true,
        /// HTTP/3 on the same port over UDP (a TLS listener; one per server).
        http3: bool = false,
        /// Connections start with a PROXY protocol header. Null: on under
        /// anole_lb, else off.
        proxy_protocol: ?bool = null,
        /// With proxy_protocol: the proxies allowed to send one (addresses
        /// or CIDR networks, "10.0.0.0/8"); empty: proxy.trusted when set,
        /// else any peer.
        proxy_protocol_from: []const []const u8 = &.{},
    };

    pub const Tls = struct {
        /// PEM files, read at start (and by anole_server_reload_tls with both arguments empty).
        cert_file: ?[]const u8 = null,
        key_file: ?[]const u8 = null,
        /// Or PEM text.
        cert_pem: ?[]const u8 = null,
        key_pem: ?[]const u8 = null,
        /// Or a fresh self-signed certificate for localhost (development).
        self_signed: bool = false,
        /// ALPN protocols in order; default "h2", "http/1.1".
        alpn: ?[]const []const u8 = null,
        /// Mutual TLS: "none", "request" (a certificate is asked for, and
        /// checked when sent) or "require" (a client without one is
        /// refused). Also over HTTP/3. Requests carry the certificate
        /// (ANOLE_REQ_PEER_CERT).
        client_auth: []const u8 = "none",
        /// The CAs (PEM) client certificates must chain to, as a file or as
        /// the PEM text: one of them with "request" and "require".
        client_ca_file: ?[]const u8 = null,
        client_ca_pem: ?[]const u8 = null,
        /// Or a directory of PEM files, or the system's trust store.
        client_ca_dir: ?[]const u8 = null,
        client_ca_system: bool = false,
    };

    pub const Limits = struct {
        /// The largest request body, inline or streamed: past it, 413.
        body_max: u64 = 1 << 20,
        /// The request line and headers: larger is 431. 1 KiB to 1 MiB.
        max_head_size: usize = 16 * 1024,
        max_header_count: usize = 32,
        max_param_count: usize = 8,
        max_query_count: usize = 32,
        max_form_count: usize = 32,
        max_multiform_count: usize = 32,
        /// Bodies up to this come inline in the request record; larger
        /// ones are read with anole_req_read. At most 1 GiB.
        inline_body_max: u32 = 64 * 1024,
        /// Requests handed to consumers and not yet answered, per executor;
        /// past it, 503.
        max_inflight: u32 = 1024,
        /// Events waiting for a consumer, per executor: 0 for twice
        /// max_inflight. A full queue holds requests back (backpressure).
        queue: u32 = 0,
        /// A streamed response or a WebSocket past this many bytes waiting
        /// to go out answers ANOLE_BUSY.
        stream_high_water: u32 = 256 * 1024,
        ws_high_water: u32 = 1 << 20,
        /// The largest WebSocket message, in or out (after inflating). At
        /// most 1 GiB.
        ws_max_message: u32 = 1 << 20,
        /// Open connections at most; 0 follows the open-file limit.
        max_connections: u32 = 0,
        /// Requests per keep-alive connection; null: no limit.
        max_requests_per_connection: ?u32 = null,
        /// The largest database answer, in bytes of its record: past it,
        /// the answer is ANOLE_E_TOOBIG.
        db_result_max: u32 = 16 << 20,
    };

    pub const Database = struct {
        /// What `anole_db_find` looks it up by: unique, 1-255 bytes.
        name: []const u8,
        /// Exactly one of `sqlite`, `postgres`, `redis` and `mongodb`.
        sqlite: ?Sqlite = null,
        postgres: ?Postgres = null,
        redis: ?Redis = null,
        mongodb: ?Mongodb = null,
        /// The bounds of the answers kept for queries with cache_ttl_ms,
        /// over every executor.
        cache: CacheBounds = .{},
        /// A bound on every query that has no timeout_ms of its own, in a
        /// request or not; past it the statement is interrupted
        /// (ANOLE_E_TIMEOUT). 0: none.
        timeout_ms: u32 = 30_000,
        /// A circuit breaker: after repeated connection failures calls fail
        /// fast with ANOLE_E_DB, class UNAVAILABLE, error_code
        /// "circuit_open" and http_status 503. null: none. Ignored for SQLite.
        breaker: ?Breaker = .{},
        /// What queries with ANOLE_DB_F_RETRY are retried with.
        retry: Retry = .{},
        /// What status each class of database error becomes, as
        /// `anole.db.ErrorMap`: a class name to "bad_request", "not_found",
        /// "conflict", "unprocessable_entity", "internal_server_error",
        /// "service_unavailable" or "gateway_timeout".
        errors: anole.db.ErrorMap = .{},
    };

    pub const Sqlite = struct {
        /// A file (created when missing), or ":memory:".
        path: []const u8,
        /// Take a path starting with "file:" as a SQLite URI.
        uri: bool = false,
        /// Read-only connections beside the writer; null: one per executor,
        /// at most 8; 0: everything on the writer.
        readers: ?u32 = null,
        /// How long a statement waits for a lock another process holds.
        busy_timeout_ms: u32 = 5000,
        /// Prepared statements kept per connection.
        statement_cache_size: u16 = 64,
        /// What /readyz waits for the database's answer.
        ping_timeout_ms: u32 = 2000,
        /// Run on every connection as it opens: "PRAGMA cache_size = -20000".
        pragmas: []const []const u8 = &.{},
        /// SQL run once at start, before the listeners open: a schema.
        init: ?[]const u8 = null,
    };

    /// A PostgreSQL database, as `anole.pg.Options` (docs/database.md).
    pub const Postgres = struct {
        /// postgres://user:password@host:port/database?params. Null:
        /// DATABASE_URL, else libpq's variables (PGHOST, PGUSER...).
        url: ?[]const u8 = null,
        /// libpq's sslmode: disable, allow, prefer, require, verify-ca,
        /// verify-full. Null: the URL's, else PGSSLMODE, else verify-full
        /// for a server on another host and prefer on this machine.
        sslmode: ?[]const u8 = null,
        /// The CA certificates (PEM) the server's certificate is checked
        /// against, as a file or as the PEM text: with one, the certificate
        /// is always checked (verify-full unless sslmode says verify-ca).
        /// Null: the URL's sslrootcert, else the system's store.
        ca_file: ?[]const u8 = null,
        ca_pem: ?[]const u8 = null,
        /// A client certificate and key (PEM), as files or as text, for
        /// servers that ask. Null: the URL's.
        client_cert_file: ?[]const u8 = null,
        client_key_file: ?[]const u8 = null,
        client_cert_pem: ?[]const u8 = null,
        client_key_pem: ?[]const u8 = null,
        /// TLS without checking the server's certificate. Refused with a CA
        /// and with a URL that verifies.
        insecure_skip_verify: bool = false,
        /// What /readyz waits for the server's answer.
        ping_timeout_ms: u32 = 2000,
        /// Connections in all, split between the executors. Null: the URL's
        /// pool_max_conns, else twice the executors, at least 4.
        max_connections: ?u32 = null,
        /// How long a query waits for a connection when all are busy.
        acquire_timeout_ms: u32 = 5000,
        /// How long opening a connection may take; 0: no limit.
        connect_timeout_ms: u32 = 10_000,
        /// Statements each connection keeps prepared; 0 behind PgBouncer
        /// before 1.21 in transaction mode.
        statement_cache_size: u16 = 256,
        /// Connections older than this are closed; 0: no limit.
        max_lifetime_ms: u32 = 60 * 60 * 1000,
        /// Connections idle this long are closed; 0: no limit.
        idle_timeout_ms: u32 = 30 * 60 * 1000,
        /// Open a connection per executor at start, and fail the start if
        /// that fails.
        connect_at_start: bool = false,
        application_name: ?[]const u8 = null,
        /// What happens to a connection's session when a query gives it
        /// back: "auto" resets it when what the query ran may have changed
        /// it, "always" on every release, "off" never.
        reset_session: ResetSession = .auto,
        /// SQL run once at start, before the listeners open: a schema.
        init: ?[]const u8 = null,
    };

    /// A Redis or Valkey server, as `anole.redis.Options` (docs/database.md).
    pub const Redis = struct {
        /// redis://user:password@host:6379/0, rediss:// for TLS, or
        /// unix:///path?db=0. Null: REDIS_URL, else redis://127.0.0.1:6379.
        url: ?[]const u8 = null,
        /// rediss://: the CA certificates (PEM) the server's certificate is
        /// checked against, as a file or as the PEM text. Null: the URL's
        /// ssl_ca_certs, else the system's store.
        ca_file: ?[]const u8 = null,
        ca_pem: ?[]const u8 = null,
        /// A client certificate and key (PEM), as files or as text, for
        /// servers that ask. Null: the URL's.
        client_cert_file: ?[]const u8 = null,
        client_key_file: ?[]const u8 = null,
        client_cert_pem: ?[]const u8 = null,
        client_key_pem: ?[]const u8 = null,
        /// TLS without checking the server's certificate. Refused with a CA
        /// and with a URL that verifies.
        insecure_skip_verify: bool = false,
        /// What /readyz waits for the server's answer.
        ping_timeout_ms: u32 = 2000,
        /// Connections in all, split between the executors. Null: ten per
        /// executor.
        max_connections: ?u32 = null,
        /// How long a command waits for a connection when all are busy.
        acquire_timeout_ms: u32 = 5000,
        /// How long opening a connection may take; 0: no limit.
        connect_timeout_ms: u32 = 10_000,
        /// Connections idle this long are closed; 0: no limit.
        idle_timeout_ms: u32 = 5 * 60 * 1000,
        /// Open a connection per executor at start, and fail the start if
        /// that fails.
        connect_at_start: bool = false,
    };

    /// A MongoDB deployment, as `anole.mongodb.Options` (docs/database.md).
    pub const Mongodb = struct {
        /// A mongodb:// connection string; its options win over the fields
        /// below. mongodb+srv:// is not supported yet (list the hosts with
        /// mongodb://). Null: MONGODB_URI, else mongodb://localhost:27017.
        url: ?[]const u8 = null,
        /// The database operations name no other for. Null: the URL's
        /// path, else "test".
        database: ?[]const u8 = null,
        /// The CA certificates (PEM) the server's certificate is checked
        /// against, as a file or as the PEM text: either turns TLS on, and a
        /// URL that turns it off or stops checking is refused.
        ca_file: ?[]const u8 = null,
        ca_pem: ?[]const u8 = null,
        /// A client certificate and key (PEM), as files or as text, for
        /// servers that ask. Null: the URL's.
        client_cert_file: ?[]const u8 = null,
        client_key_file: ?[]const u8 = null,
        client_cert_pem: ?[]const u8 = null,
        client_key_pem: ?[]const u8 = null,
        /// TLS without checking the server's certificate. Refused with a CA
        /// and with a URL that verifies.
        insecure_skip_verify: bool = false,
        /// What /readyz waits for the server's answer.
        ping_timeout_ms: u32 = 2000,
        /// Connections at most, split between the executors (maxPoolSize).
        /// Null: 100. 0 is refused.
        max_connections: ?u32 = null,
        /// How long an operation waits for a pooled connection.
        acquire_timeout_ms: u32 = 10_000,
        /// How long an operation waits for a server it can use (a primary).
        server_selection_timeout_ms: u32 = 30_000,
        /// TCP connect and TLS handshake; 0: no limit.
        connect_timeout_ms: u32 = 10_000,
        /// Idle connections older than this are closed; 0: never.
        idle_timeout_ms: u32 = 0,
        /// Between two checks of a server.
        heartbeat_ms: u32 = 10_000,
        /// Retry a read once after a network error or a primary change.
        retry_reads: bool = true,
        /// Retry a single-document write once, likewise.
        retry_writes: bool = true,
        /// Select a server and open a connection per executor at start, and
        /// fail the start if that fails.
        connect_at_start: bool = false,
    };

    pub const Breaker = struct {
        consecutive_failures: u32 = 5,
        failure_ratio: f32 = 0.5,
        min_calls: u32 = 20,
        window_ms: u32 = 10_000,
        open_ms: u32 = 5_000,
        max_open_ms: u32 = 60_000,
        half_open_calls: u8 = 1,
    };

    pub const Retry = struct {
        attempts: u8 = 3,
        base_ms: u32 = 50,
        max_ms: u32 = 1_000,
        multiplier: f32 = 2.0,
        attempt_timeout_ms: u32 = 0,
        max_retry_after_ms: u32 = 10_000,
    };

    pub const Broker = struct {
        /// What `anole_nats_find` looks it up by: unique, 1-255 bytes.
        name: []const u8,
        /// Exactly one of the kinds: `nats` or `kafka`.
        nats: ?Nats = null,
        kafka: ?Kafka = null,
        /// A bound on requests and JetStream calls that have no timeout_ms of
        /// their own. 0: none.
        timeout_ms: u32 = 30_000,
        /// What status each class of broker error becomes, as `anole.db.ErrorMap`.
        errors: anole.db.ErrorMap = .{},
        /// What requests with ANOLE_NATS_F_RETRY are retried with.
        retry: BrokerRetry = .{},
    };

    pub const BrokerRetry = struct {
        attempts: u8 = 5,
        base_ms: u32 = 100,
        max_ms: u32 = 2_000,
        multiplier: f32 = 2.0,
        attempt_timeout_ms: u32 = 0,
        max_retry_after_ms: u32 = 10_000,
    };

    pub const Nats = struct {
        /// nats://, tls:// or a comma-separated list; user:password@ or
        /// token@ in it log in. Null: NATS_URL, else nats://127.0.0.1:4222.
        url: ?[]const u8 = null,
        name: ?[]const u8 = null,
        token: ?[]const u8 = null,
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
        nkey_seed: ?[]const u8 = null,
        nkey_seed_file: ?[]const u8 = null,
        creds: ?[]const u8 = null,
        creds_file: ?[]const u8 = null,
        ca_file: ?[]const u8 = null,
        ca_pem: ?[]const u8 = null,
        client_cert_file: ?[]const u8 = null,
        client_key_file: ?[]const u8 = null,
        client_cert_pem: ?[]const u8 = null,
        client_key_pem: ?[]const u8 = null,
        insecure_skip_verify: bool = false,
        tls_first: bool = false,
        tls_required: bool = false,
        /// "one" or "per_executor".
        connections: []const u8 = "one",
        connect_timeout_ms: u32 = 5_000,
        connect_at_start: bool = false,
        ping_interval_ms: u32 = 30_000,
        max_outstanding_pings: u8 = 2,
        no_echo: bool = false,
        reconnect: Reconnect = .{},
        limits: NatsLimits = .{},
        jetstream: JetStream = .{},
    };

    pub const Kafka = struct {
        /// host:port entries. Null: KAFKA_BOOTSTRAP_SERVERS, else
        /// KAFKA_URL, else localhost:9092.
        brokers: ?[]const []const u8 = null,
        client_id: []const u8 = "anole",
        /// TLS to the brokers; any ca/client certificate key turns it on too.
        tls: bool = false,
        ca_file: ?[]const u8 = null,
        ca_pem: ?[]const u8 = null,
        client_cert_file: ?[]const u8 = null,
        client_key_file: ?[]const u8 = null,
        client_cert_pem: ?[]const u8 = null,
        client_key_pem: ?[]const u8 = null,
        insecure_skip_verify: bool = false,
        sasl: ?KafkaSasl = null,
        connect_timeout_ms: u32 = 10_000,
        request_timeout_ms: u32 = 30_000,
        metadata_max_age_ms: u32 = 300_000,
        connect_at_start: bool = false,
        producer: KafkaProducer = .{},
    };

    pub const KafkaSasl = struct {
        /// "PLAIN", "SCRAM-SHA-256" or "SCRAM-SHA-512".
        mechanism: []const u8,
        username: []const u8,
        password: []const u8,
    };

    pub const KafkaProducer = struct {
        /// "none", "leader" or "all".
        acks: []const u8 = "all",
        /// Needs acks "all".
        idempotent: bool = true,
        linger_ms: u32 = 5,
        batch_bytes: u32 = 16 * 1024,
        buffer_bytes: u32 = 32 * 1024 * 1024,
        /// "none", "gzip", "zstd" or "lz4".
        compression: []const u8 = "none",
        delivery_timeout_ms: u32 = 30_000,
        metadata_wait_ms: u32 = 5_000,
        max_request_bytes: u32 = 1024 * 1024,
    };

    pub const Reconnect = struct {
        enabled: bool = true,
        max_attempts: ?u32 = null,
        min_delay_ms: u32 = 500,
        max_delay_ms: u32 = 10_000,
        jitter: bool = true,
        buffer_bytes: u64 = 8 << 20,
        abort_on_auth_error: bool = true,
    };

    pub const NatsLimits = struct {
        outbound_bytes: u64 = 8 << 20,
        subscription_messages: u32 = 1024,
        subscription_bytes: u64 = 8 << 20,
        max_pending_requests: u32 = 65_536,
        max_subscriptions: u32 = 65_536,
        max_control_line_bytes: u32 = 4096,
        max_inbound_frame_bytes: u32 = 64 << 20,
        max_header_bytes: u32 = 64 << 10,
        max_event_queue: u32 = 1024,
    };

    pub const JetStream = struct {
        domain: ?[]const u8 = null,
        streams: []const JsStream = &.{},
        consumers: []const JsConsumer = &.{},
    };

    pub const JsStream = struct {
        name: []const u8,
        subjects: []const []const u8 = &.{},
        /// "limits", "interest" or "workqueue".
        retention: []const u8 = "limits",
        /// "file" or "memory".
        storage: []const u8 = "file",
        replicas: u8 = 1,
        max_age_ms: ?u64 = null,
        max_bytes: ?i64 = null,
        max_msgs: ?i64 = null,
        duplicate_window_ms: ?u64 = null,
        /// Any other keys of the stream configuration the server takes.
        extra: ?std.json.Value = null,
    };

    pub const JsConsumer = struct {
        stream: []const u8,
        durable: []const u8,
        filter_subjects: []const []const u8 = &.{},
        /// "all", "last", "new" or "last_per_subject".
        deliver_policy: []const u8 = "all",
        ack_wait_ms: u32 = 30_000,
        max_deliver: i32 = -1,
        max_ack_pending: i32 = 1000,
        backoff_ms: []const u32 = &.{},
        extra: ?std.json.Value = null,
    };

    pub const CacheBounds = struct {
        max_entries: u32 = 4096,
        max_bytes: u64 = 32 << 20,
    };

    /// A duration is null for none.
    pub const Timeouts = struct {
        /// The default deadline of a consumer request: 504 from Anole after
        /// it. A route's `timeout_ms` overrides it (at most 16 distinct
        /// values per server). Null: none.
        request_ms: ?u32 = 30_000,
        /// The request head on HTTP/1.x (Slowloris). Null: `request_ms` alone.
        read_header_ms: ?u32 = 10_000,
        /// A write the peer does not take for this long ends the response;
        /// once a stream or file body has started it replaces the request
        /// deadline. Null: none.
        write_ms: ?u32 = 30_000,
        /// An idle keep-alive connection is closed after this. Null: never.
        keepalive_ms: ?u32 = 75_000,
        /// An idle HTTP/1.1 connection gives up its task after this
        /// (parks). Null or 0: never parks.
        idle_park_ms: ?u32 = 1_000,
        /// How long the drain waits for requests in flight. Null: for all.
        shutdown_ms: ?u32 = 10_000,
        /// Ring a consumer's doorbell again when events wait and it has not
        /// polled for this long (a lost wake); 0 never.
        rewake_ms: u32 = 20,
    };

    pub const Http3 = struct {
        /// The UDP address and port; null: the TLS listener's.
        address: ?[]const u8 = null,
        port: ?u16 = null,
        max_streams_bidi: u64 = 100,
        /// Make every new client prove its address with a Retry first.
        validate_address: bool = false,
        idle_timeout_ms: u32 = 30_000,
        /// Advertise HTTP/3 with Alt-Svc on the TLS listener's responses.
        alt_svc: bool = true,
        /// Take 0-RTT from resuming clients (replayable: safe methods only
        /// run before the handshake completes).
        early_data: bool = false,
        /// Move clients that offer QUIC v2 to it.
        prefer_v2: bool = true,
        /// UDP sockets on Linux (1 to 255); null: one per executor.
        sockets: ?u16 = null,
        /// Extended CONNECT (RFC 9220): WebSockets over HTTP/3.
        enable_connect_protocol: bool = true,
        /// Run `no_wait` requests that arrive whole on the endpoint task.
        inline_no_wait: bool = true,
    };

    pub const Middleware = union(enum) {
        request_id: RequestId,
        access_log: AccessLog,
        compress: Compress,
        cors: Cors,
        jwt: Jwt,
        rate_limit: RateLimit,
    };

    pub const RequestId = struct {
        header: []const u8 = "X-Request-Id",
        trust_incoming: bool = false,
    };
    pub const AccessLog = struct {
        /// "auto" follows `log.format`.
        format: enum { auto, text, json } = .auto,
        /// Paths not logged: exact, or a prefix ending in "*".
        exclude: []const []const u8 = &.{},
    };
    pub const Compress = struct {};
    pub const Cors = struct {
        /// Empty allows every origin.
        origins: []const []const u8 = &.{},
        methods: ?[]const u8 = null,
        headers: ?[]const u8 = null,
        expose: ?[]const u8 = null,
        credentials: bool = false,
        max_age_ms: ?u32 = 600_000,
    };
    pub const Jwt = struct {
        /// The provider's JWK Set URL, fetched and refreshed; or
        jwks_url: ?[]const u8 = null,
        /// a JWK Set ({"keys": [...]}) given here.
        jwks: ?std.json.Value = null,
        issuer: ?[]const u8 = null,
        /// Required in the token's `aud`. With `jwks_url` it must be set (a
        /// provider's keys also sign tokens for its other clients), unless
        /// `allow_any_audience`.
        audience: ?[]const u8 = null,
        /// With `jwks_url` and no `audience`: only for keys that sign for
        /// this application alone.
        allow_any_audience: bool = false,
        leeway_ms: i64 = 60_000,
        require_exp: bool = true,
        /// String claims a token must carry.
        required_claims: []const []const u8 = &.{"sub"},
        /// Each must be in the `scope` claim; 403 otherwise.
        scopes: []const []const u8 = &.{},
        realm: ?[]const u8 = null,
    };
    pub const RateLimit = struct {
        /// Requests per window.
        limit: u32 = 100,
        window_ms: i64 = 60_000,
        /// How many at once; 0 means `limit`.
        burst: u32 = 0,
        /// "ip" (the client's address) or "header:<name>": the header's raw
        /// value, unverified, so only for a header a trusted proxy sets to a
        /// verified identity (a client that varies it gets a fresh limit).
        key: []const u8 = "ip",
        /// Keys remembered at most (least recently used out first).
        max_entries: u32 = 10_000,
    };

    pub const Observe = struct {
        /// Prometheus metrics, with HTTP request counts.
        metrics: ?Metrics = null,
        /// /healthz and /readyz (not ready while draining).
        health: ?Health = null,
    };
    pub const Metrics = struct { path: []const u8 = "/metrics" };
    pub const Health = struct {
        live: []const u8 = "/healthz",
        ready: []const u8 = "/readyz",
        /// Readiness flags (at most 16, 1-64 bytes, unique): each starts not
        /// ready, so /readyz answers 503 naming it until the consumer calls
        /// anole_server_set_ready.
        checks: []const []const u8 = &.{},
        /// Serve both routes only on this listener (404 on the others).
        listener: ?[]const u8 = null,
    };

    pub const Route = struct {
        /// "GET", "POST", ...; left out: every method.
        method: ?[]const u8 = null,
        /// "/users/:id", "/files/*rest".
        path: []const u8,
        /// Exactly one of these (`handler` and `websocket` may go together
        /// when the websocket's handshakes are the consumer's to decide):
        /// a consumer's route id: the request goes to a consumer;
        handler: ?u32 = null,
        /// a fixed response, served natively;
        respond: ?Fixed = null,
        /// files under a directory (the path is the prefix);
        static: ?Static = null,
        /// a WebSocket endpoint whose events go to a consumer (with
        /// `handler` too, plain requests of the path go to that handler:
        /// one app sees every request on a path);
        websocket: ?WebSocket = null,
        /// a WebTransport endpoint (HTTP/3) whose events go to a consumer.
        webtransport: ?WebTransport = null,
        /// This route's request deadline (consumer routes; a websocket
        /// route whose handshakes the consumer decides: the decision's).
        timeout_ms: ?u32 = null,
        /// Handler and respond routes run on the protocol's reader when
        /// they can (HTTP/2, HTTP/3: no task per request, the answer
        /// detached); false gives each request a task of its own.
        no_wait: bool = true,
        /// Keep GET answers (consumer and fixed routes) per executor.
        cache: ?Cache = null,
        /// After the global ones.
        middleware: []const Middleware = &.{},
    };
    pub const Fixed = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: std.json.ArrayHashMap([]const u8) = .{},
    };
    pub const Static = struct {
        dir: []const u8,
        index: ?[]const u8 = "index.html",
        /// Precompressed siblings to look for: "br", "zstd", "gzip".
        precompressed: []const []const u8 = &.{},
        cache_control: ?[]const u8 = null,
        hide_dotfiles: bool = true,
    };
    pub const WebSocket = struct {
        /// The consumer's route id for this endpoint's events.
        handler: u32,
        /// Who answers the handshake: "auto" (Anole: origins and
        /// subprotocols; the consumer hears ANOLE_EV_WS_OPEN) or "consumer"
        /// (ANOLE_EV_WS_UPGRADE, answered with anole_ws_accept or refused
        /// like any request).
        accept: Accept = .auto,
        /// "auto" only: the subprotocols this endpoint speaks, most
        /// preferred first; the first the client offered is selected and
        /// echoed (ANOLE_EV_WS_OPEN says which).
        subprotocols: []const []const u8 = &.{},
        /// permessage-deflate when the client offers it.
        compression: bool = true,
        /// Close 1001 when the server drains.
        close_on_drain: bool = true,
        /// Pages of other origins that may open the socket, besides the
        /// request's own host ("https://app.example.com"); "*" for any.
        origins: []const []const u8 = &.{},
    };
    pub const Accept = enum { auto, consumer };
    pub const Grpc = struct {
        /// The services' descriptors, a serialized FileDescriptorSet with
        /// its imports (`protoc --include_imports --descriptor_set_out`,
        /// `buf build -o`), as base64; or
        descriptor_set: ?[]const u8 = null,
        /// the path of that file, read by anole_server_create. Without
        /// descriptors, every service lists its methods, and only protobuf
        /// (not JSON) is served: no Connect JSON, no transcoding.
        descriptor_set_file: ?[]const u8 = null,
        services: []const GrpcService = &.{},
        /// grpc.health.v1.Health, served by Anole: the server ("") and
        /// every service here SERVING until anole_grpc_health_set says
        /// otherwise; NOT_SERVING once the server drains.
        health: bool = false,
    };
    pub const GrpcService = struct {
        /// The full name, "package.Service".
        name: []const u8,
        /// The consumer's route id for its calls.
        handler: u32,
        /// The methods served, in the order their ids follow; left out:
        /// all of the service's, in the descriptors' order.
        methods: ?[]const GrpcMethod = null,
        /// The largest request message (after inflating); a larger one ends
        /// the call with RESOURCE_EXHAUSTED.
        max_message_size: u32 = 4 << 20,
        /// The most request message bytes one call takes in all (each
        /// message counted at its size plus 64).
        max_received_bytes: u64 = 64 << 20,
        /// How long a request message may take to arrive once it started
        /// (and the first one of a unary or server-streaming call from the
        /// start of the call); 0 for no limit but the deadline.
        read_timeout_ms: u32 = 30_000,
        /// The longest a call may run, capping the client's deadline; 0 for
        /// none (calls without a client deadline run until they end).
        max_call_duration_ms: u32 = 0,
        /// When response messages are gzipped: "mirror" (when the request
        /// was), "accepted" (whenever the client accepts gzip), "never".
        response_compression: enum { mirror, accepted, never } = .mirror,
        /// Request messages of a client- or bidirectional-streaming call
        /// delivered before the consumer asks for more (anole_grpc_read).
        read_ahead: u32 = 8,
        /// REST routes for the methods annotated with google.api.http
        /// (needs descriptors).
        transcode: bool = true,
        /// Unary and server-streaming calls that arrive whole run on the
        /// protocol's reader, detached (as `no_wait` routes do).
        no_wait: bool = true,
        /// After the global ones; runs for the service's gRPC paths and its
        /// transcoded routes, as a route's `middleware` does.
        middleware: []const Middleware = &.{},
    };
    pub const GrpcMethod = struct {
        name: []const u8,
        /// The call mode; from the descriptors when left out (and checked
        /// against them when both say).
        kind: ?enum { unary, server_streaming, client_streaming, bidi_streaming } = null,
        /// A unary method without side effects is also served as Connect
        /// GET (descriptors: `idempotency_level = NO_SIDE_EFFECTS`).
        no_side_effects: ?bool = null,
    };
    pub const WebTransport = struct {
        /// The consumer's route id for this endpoint's events.
        handler: u32,
        /// Close each session (code 0) when the server drains, right after
        /// ANOLE_EV_WT_DRAIN; false leaves that to the consumer (until
        /// timeouts.shutdown_ms).
        close_on_drain: bool = true,
        /// Pages of other origins that may open a session, besides the
        /// request's own host; "*" for any.
        origins: []const []const u8 = &.{},
        /// Datagrams a session holds for sending; past it the oldest is
        /// dropped.
        datagram_queue: u32 = 64,
    };
    pub const Cache = struct {
        /// When the answer's Cache-Control does not say.
        ttl_ms: u32 = 10_000,
        /// Also keep answers to requests with credentials (only when the
        /// answer does not depend on who asks).
        authenticated: bool = false,
        max_entries: u32 = 1024,
        max_bytes: u64 = 16 << 20,
    };
};

pub const ClientAuth = enum { none, request, require };

/// A listener's `tls.client_auth`, or null when it is none of the three.
pub fn clientAuth(text: []const u8) ?ClientAuth {
    return std.meta.stringToEnum(ClientAuth, text);
}

pub const max_timeouts = 16;

/// The most an inline body or a WebSocket message may be (one event each).
pub const max_record_payload: u32 = 1 << 30;

/// What `check` found wrong, for anole_last_error.
pub const Problem = error{Config};

/// The token for the last `parse` problem on this thread
/// (`anole_last_error_name`): SyntaxError, UnknownKey, MissingKey or
/// InvalidValue.
pub threadlocal var last_problem: []const u8 = "InvalidValue";

pub fn methodOf(name: []const u8) ?http.Method {
    var buf: [16]u8 = undefined;
    if (name.len == 0 or name.len > buf.len) return null;
    return std.meta.stringToEnum(http.Method, std.ascii.lowerString(&buf, name));
}

/// Parses `json` into `arena`, with "UnknownField at line L column C" and
/// the like in `why` on failure.
pub fn parse(arena: std.mem.Allocator, json: []const u8, why: *std.Io.Writer) Problem!Config {
    var diag: std.json.Diagnostics = .{};
    var scanner = std.json.Scanner.initCompleteInput(arena, json);
    scanner.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &scanner, .{ .allocate = .alloc_always }) catch |err| {
        why.print("config: {t} at line {d} column {d}", .{ err, diag.getLine(), diag.getColumn() }) catch {};
        last_problem = switch (err) {
            error.SyntaxError, error.UnexpectedEndOfInput => "SyntaxError",
            error.UnknownField => "UnknownKey",
            error.MissingField => "MissingKey",
            else => "InvalidValue",
        };
        return error.Config;
    };
    last_problem = "InvalidValue";
    try check(cfg, why);
    return cfg;
}

/// libpq's sslmode names ("verify-full"), as `anole.pg.SslMode`'s tags.
pub const SslMode = enum { disable, allow, prefer, require, verify_ca, verify_full };

/// `databases[].postgres.reset_session`, as `anole.pg.Options.ResetSession`.
pub const ResetSession = enum { auto, always, off };

pub fn sslMode(text: []const u8) ?SslMode {
    var buf: [16]u8 = undefined;
    if (text.len > buf.len) return null;
    for (text, buf[0..text.len]) |ch, *o| o.* = if (ch == '-') '_' else ch;
    return std.meta.stringToEnum(SslMode, buf[0..text.len]);
}

fn fail(why: *std.Io.Writer, comptime fmt: []const u8, args: anytype) Problem {
    why.print("config: " ++ fmt, args) catch {};
    return error.Config;
}

/// What the types cannot say.
fn check(cfg: Config, why: *std.Io.Writer) Problem!void {
    if (cfg.listeners.len == 0) return fail(why, "listeners: at least one", .{});
    if (cfg.executors > 256) return fail(why, "executors: at most 256", .{});
    if (cfg.limits.max_head_size < 1024 or cfg.limits.max_head_size > 1 << 20) return fail(why, "limits.max_head_size: 1024 to 1048576", .{});
    if (cfg.response.write_buffer_size == 0) return fail(why, "response.write_buffer_size: at least 1", .{});
    if (cfg.response.brotli_quality > 11) return fail(why, "response.brotli_quality: 0 to 11", .{});
    if (cfg.http3.sockets) |n| if (n == 0 or n > 255) return fail(why, "http3.sockets: 1 to 255", .{});
    if (cfg.limits.max_inflight == 0 or cfg.limits.max_inflight > 1 << 20) return fail(why, "limits.max_inflight: 1 to 1048576", .{});
    if (cfg.limits.inline_body_max > cfg.limits.body_max) return fail(why, "limits.inline_body_max is above limits.body_max", .{});
    // Events carry their length in 32 bits: what goes inside one is bounded
    // well below that (the request head comes on top of an inline body).
    if (cfg.limits.inline_body_max > max_record_payload) return fail(why, "limits.inline_body_max: at most {d}", .{max_record_payload});
    if (cfg.limits.ws_max_message > max_record_payload) return fail(why, "limits.ws_max_message: at most {d}", .{max_record_payload});
    var http3_listeners: usize = 0;
    for (cfg.listeners, 0..) |l, i| {
        if (l.tls) |t| {
            if (comptime features.tls != .boringssl) return fail(why, "listeners[{d}].tls: TLS is not built in (-Dtls=boringssl)", .{i});
            const files = t.cert_file != null or t.key_file != null;
            const pem = t.cert_pem != null or t.key_pem != null;
            const n = @as(u8, @intFromBool(files)) + @intFromBool(pem) + @intFromBool(t.self_signed);
            if (n != 1) return fail(why, "listeners[{d}].tls: exactly one of cert_file/key_file, cert_pem/key_pem, self_signed", .{i});
            if (files and (t.cert_file == null or t.key_file == null)) return fail(why, "listeners[{d}].tls: cert_file and key_file go together", .{i});
            if (pem and (t.cert_pem == null or t.key_pem == null)) return fail(why, "listeners[{d}].tls: cert_pem and key_pem go together", .{i});
            const mode = clientAuth(t.client_auth) orelse return fail(why, "listeners[{d}].tls.client_auth: \"none\", \"request\" or \"require\"", .{i});
            const cas = @as(u8, @intFromBool(t.client_ca_file != null)) + @intFromBool(t.client_ca_pem != null) +
                @intFromBool(t.client_ca_dir != null) + @intFromBool(t.client_ca_system);
            if (mode != .none and cas != 1) return fail(why, "listeners[{d}].tls: client_auth \"{s}\" needs exactly one of client_ca_file, client_ca_pem, client_ca_dir, client_ca_system", .{ i, t.client_auth });
            if (mode == .none and cas != 0) return fail(why, "listeners[{d}].tls: the client_ca_* settings go with client_auth \"request\" or \"require\"", .{i});
        }
        if (l.proxy_protocol_from.len > 0 and l.proxy_protocol == false) return fail(why, "listeners[{d}].proxy_protocol_from: with proxy_protocol", .{i});
        if (l.http3) {
            if (comptime !features.http3) return fail(why, "listeners[{d}].http3: HTTP/3 is not built in (-Dhttp3)", .{i});
            if (l.tls == null) return fail(why, "listeners[{d}].http3 needs tls", .{i});
            http3_listeners += 1;
        }
        if (l.name) |n| if (n.len == 0 or n.len > 255 or std.mem.indexOfScalar(u8, n, ':') != null)
            return fail(why, "listeners[{d}].name: 1-255 bytes, no ':'", .{i});
        for (cfg.listeners[0..i]) |other| if (l.name != null and other.name != null and std.mem.eql(u8, l.name.?, other.name.?))
            return fail(why, "listeners[{d}].name \"{s}\" is taken", .{ i, l.name.? });
    }
    if (http3_listeners > 1) return fail(why, "listeners: http3 on one listener at most", .{});
    if (cfg.grpc) |g| try checkGrpc(g, why);
    for (cfg.databases, 0..) |d, i| {
        if (d.name.len == 0 or d.name.len > 255) return fail(why, "databases[{d}].name: 1-255 bytes", .{i});
        for (cfg.databases[0..i]) |other| if (std.mem.eql(u8, d.name, other.name))
            return fail(why, "databases[{d}].name \"{s}\" is taken", .{ i, d.name });
        const kinds = @as(u8, @intFromBool(d.sqlite != null)) + @intFromBool(d.postgres != null) + @intFromBool(d.redis != null) + @intFromBool(d.mongodb != null);
        if (kinds != 1) return fail(why, "databases[{d}]: exactly one of sqlite, postgres, redis and mongodb", .{i});
        if (d.sqlite) |sq| {
            if (comptime !features.sqlite) return fail(why, "databases[{d}].sqlite: SQLite is not built in (-Dsqlite)", .{i});
            if (sq.path.len == 0) return fail(why, "databases[{d}].sqlite.path: a file or \":memory:\"", .{i});
            if (sq.statement_cache_size == 0) return fail(why, "databases[{d}].sqlite.statement_cache_size: at least 1", .{i});
        }
        if (d.postgres) |p| {
            if (comptime !features.postgres) return fail(why, "databases[{d}].postgres: PostgreSQL is not built in (-Dpostgres)", .{i});
            if (p.sslmode) |m| {
                if (sslMode(m) == null) return fail(why, "databases[{d}].postgres.sslmode \"{s}\": one of disable, allow, prefer, require, verify-ca, verify-full", .{ i, m });
                if (p.url) |u| if (std.mem.indexOf(u8, u, "sslmode=") != null)
                    return fail(why, "databases[{d}].postgres: sslmode is given twice, in the url and beside it", .{i});
            }
            if (p.ca_file != null and p.ca_pem != null) return fail(why, "databases[{d}].postgres: ca_file or ca_pem, not both", .{i});
            try checkClientCert(p, "databases", "postgres", i, why);
            if (p.max_connections) |n| if (n == 0) return fail(why, "databases[{d}].postgres.max_connections: at least 1", .{i});
        }
        if (d.redis) |r| {
            if (comptime !features.redis) return fail(why, "databases[{d}].redis: Redis is not built in (-Dredis)", .{i});
            if (r.ca_file != null and r.ca_pem != null) return fail(why, "databases[{d}].redis: ca_file or ca_pem, not both", .{i});
            try checkClientCert(r, "databases", "redis", i, why);
            if (r.max_connections) |n| if (n == 0) return fail(why, "databases[{d}].redis.max_connections: at least 1", .{i});
        }
        if (d.mongodb) |m| {
            if (comptime !features.mongodb) return fail(why, "databases[{d}].mongodb: MongoDB is not built in (-Dmongodb)", .{i});
            if (m.ca_file != null and m.ca_pem != null) return fail(why, "databases[{d}].mongodb: ca_file or ca_pem, not both", .{i});
            try checkClientCert(m, "databases", "mongodb", i, why);
            if (m.max_connections) |n| if (n == 0) return fail(why, "databases[{d}].mongodb.max_connections: at least 1", .{i});
        }
    }
    for (cfg.brokers, 0..) |b, i| {
        if (b.name.len == 0 or b.name.len > 255) return fail(why, "brokers[{d}].name: 1-255 bytes", .{i});
        for (cfg.brokers[0..i]) |other| if (std.mem.eql(u8, b.name, other.name))
            return fail(why, "brokers[{d}].name \"{s}\" is taken", .{ i, b.name });
        if ((b.nats == null) == (b.kafka == null)) return fail(why, "brokers[{d}]: exactly one of nats or kafka", .{i});
        if (b.kafka) |k| {
            if (comptime !features.kafka) return fail(why, "brokers[{d}].kafka: Kafka is not built in (-Dkafka)", .{i});
            if (k.ca_file != null and k.ca_pem != null) return fail(why, "brokers[{d}].kafka: ca_file or ca_pem, not both", .{i});
            try checkClientCert(k, "brokers", "kafka", i, why);
            if (k.brokers) |list| {
                if (list.len == 0) return fail(why, "brokers[{d}].kafka.brokers: at least one host:port", .{i});
                for (list) |h| if (h.len == 0) return fail(why, "brokers[{d}].kafka.brokers: empty entry", .{i});
            }
            if (k.sasl) |sa| {
                if (!oneOf(sa.mechanism, &.{ "PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512" }))
                    return fail(why, "brokers[{d}].kafka.sasl.mechanism: PLAIN, SCRAM-SHA-256 or SCRAM-SHA-512", .{i});
            }
            const p = k.producer;
            if (!oneOf(p.acks, &.{ "none", "leader", "all" })) return fail(why, "brokers[{d}].kafka.producer.acks: none, leader or all", .{i});
            if (!oneOf(p.compression, &.{ "none", "gzip", "zstd", "lz4" })) return fail(why, "brokers[{d}].kafka.producer.compression: none, gzip, zstd or lz4", .{i});
            if (p.idempotent and !std.mem.eql(u8, p.acks, "all")) return fail(why, "brokers[{d}].kafka.producer.idempotent: needs acks \"all\"", .{i});
            if (p.batch_bytes == 0 or p.buffer_bytes < p.batch_bytes or p.max_request_bytes < 1024)
                return fail(why, "brokers[{d}].kafka.producer: batch_bytes, buffer_bytes or max_request_bytes", .{i});
        }
        if (b.nats) |n| {
            if (comptime !features.nats) return fail(why, "brokers[{d}].nats: NATS is not built in (-Dnats)", .{i});
            const logins = @as(u8, @intFromBool(n.token != null)) + @intFromBool(n.user != null or n.password != null) +
                @intFromBool(n.nkey_seed != null or n.nkey_seed_file != null) + @intFromBool(n.creds != null or n.creds_file != null);
            if (logins > 1) return fail(why, "brokers[{d}].nats: exactly one of token, user/password, nkey_seed(_file), creds(_file)", .{i});
            if ((n.user == null) != (n.password == null)) return fail(why, "brokers[{d}].nats: user and password go together", .{i});
            if (n.nkey_seed != null and n.nkey_seed_file != null) return fail(why, "brokers[{d}].nats: nkey_seed or nkey_seed_file, not both", .{i});
            if (n.creds != null and n.creds_file != null) return fail(why, "brokers[{d}].nats: creds or creds_file, not both", .{i});
            if (n.ca_file != null and n.ca_pem != null) return fail(why, "brokers[{d}].nats: ca_file or ca_pem, not both", .{i});
            try checkClientCert(n, "brokers", "nats", i, why);
            if (!std.mem.eql(u8, n.connections, "one") and !std.mem.eql(u8, n.connections, "per_executor"))
                return fail(why, "brokers[{d}].nats.connections: \"one\" or \"per_executor\"", .{i});
            for (n.jetstream.streams, 0..) |s, j| {
                if (s.name.len == 0) return fail(why, "brokers[{d}].nats.jetstream.streams[{d}].name: required", .{ i, j });
                if (!oneOf(s.retention, &.{ "limits", "interest", "workqueue" })) return fail(why, "brokers[{d}].nats.jetstream.streams[{d}].retention: limits, interest or workqueue", .{ i, j });
                if (!oneOf(s.storage, &.{ "file", "memory" })) return fail(why, "brokers[{d}].nats.jetstream.streams[{d}].storage: file or memory", .{ i, j });
            }
            for (n.jetstream.consumers, 0..) |k, j| {
                if (k.stream.len == 0 or k.durable.len == 0) return fail(why, "brokers[{d}].nats.jetstream.consumers[{d}]: stream and durable are required", .{ i, j });
                if (!oneOf(k.deliver_policy, &.{ "all", "last", "new", "last_per_subject" })) return fail(why, "brokers[{d}].nats.jetstream.consumers[{d}].deliver_policy: all, last, new or last_per_subject", .{ i, j });
            }
        }
    }
    if (cfg.observe.health) |h| {
        if (h.checks.len > 16) return fail(why, "observe.health.checks: at most 16", .{});
        for (h.checks, 0..) |name, i| {
            if (name.len == 0 or name.len > 64) return fail(why, "observe.health.checks[{d}]: 1-64 bytes", .{i});
            for (h.checks[0..i]) |other| if (std.mem.eql(u8, other, name))
                return fail(why, "observe.health.checks[{d}] \"{s}\" is listed twice", .{ i, name });
        }
        if (h.listener) |ln| {
            var found = false;
            for (cfg.listeners) |l| found = found or (l.name != null and std.mem.eql(u8, l.name.?, ln));
            if (!found) return fail(why, "observe.health.listener \"{s}\" names no listener (listeners[].name)", .{ln});
        }
    }
    try checkMiddleware(cfg.middleware, "middleware", why);
    var timeouts: [max_timeouts]u32 = undefined;
    var ntimeouts: usize = 1;
    timeouts[0] = cfg.timeouts.request_ms orelse std.math.maxInt(u32);
    for (cfg.routes, 0..) |r, i| {
        const kinds = @as(u8, @intFromBool(r.handler != null)) + @intFromBool(r.respond != null) +
            @intFromBool(r.static != null) + @intFromBool(r.websocket != null) + @intFromBool(r.webtransport != null);
        const combined = r.handler != null and r.websocket != null and r.websocket.?.accept == .consumer and kinds == 2;
        if (kinds != 1 and !combined) {
            if (r.handler != null and r.websocket != null and kinds == 2)
                return fail(why, "routes[{d}]: handler and websocket go together only with \"accept\": \"consumer\"", .{i});
            return fail(why, "routes[{d}]: exactly one of handler, respond, static, websocket, webtransport", .{i});
        }
        if (r.path.len == 0 or r.path[0] != '/') return fail(why, "routes[{d}].path must start with '/'", .{i});
        if (r.method) |m| if (methodOf(m) == null) return fail(why, "routes[{d}].method \"{s}\" is unknown", .{ i, m });
        if (r.respond) |f| {
            _ = http.Status.fromCode(f.status) catch return fail(why, "routes[{d}].respond.status {d} is not a status Anole knows", .{ i, f.status });
            var it = f.headers.map.iterator();
            while (it.next()) |h| {
                const name = h.key_ptr.*;
                http.core.validateHeaderName(name) catch return fail(why, "routes[{d}].respond.headers: \"{f}\" is not a header name", .{ i, std.zig.fmtString(name) });
                if (http.core.isReservedHeader(name)) return fail(why, "routes[{d}].respond.headers: {s} is the server's to set", .{ i, name });
                http.core.validateHeaderValue(h.value_ptr.*) catch return fail(why, "routes[{d}].respond.headers.{s}: the value holds CR, LF or NUL", .{ i, name });
            }
        }
        if (r.websocket != null) {
            if (comptime !features.websocket) return fail(why, "routes[{d}].websocket: WebSocket is not built in (-Dwebsocket)", .{i});
            if (!combined) if (r.method) |m| if (methodOf(m) != .get) return fail(why, "routes[{d}]: a websocket route is GET", .{i});
            const w = r.websocket.?;
            if (w.accept == .consumer and w.subprotocols.len != 0)
                return fail(why, "routes[{d}].websocket.subprotocols: only with \"accept\": \"auto\" (the consumer picks in anole_ws_accept)", .{i});
            for (w.subprotocols, 0..) |sp, k| {
                if (sp.len == 0 or sp.len > 255 or !anole.websocket.isToken(sp))
                    return fail(why, "routes[{d}].websocket.subprotocols[{d}]: a token of 1-255 bytes", .{ i, k });
            }
        }
        if (r.webtransport) |w| {
            if (comptime !features.http3) return fail(why, "routes[{d}].webtransport: HTTP/3 is not built in (-Dhttp3)", .{i});
            if (r.method != null) return fail(why, "routes[{d}]: a webtransport route takes no method (an extended CONNECT)", .{i});
            var h3 = false;
            for (cfg.listeners) |l| h3 = h3 or l.http3;
            if (!h3) return fail(why, "routes[{d}].webtransport: needs a listener with http3", .{i});
            if (w.datagram_queue == 0) return fail(why, "routes[{d}].webtransport.datagram_queue: at least 1", .{i});
        }
        if (r.static != null and r.method != null) return fail(why, "routes[{d}]: a static route takes no method (GET and HEAD)", .{i});
        if (r.cache != null and r.handler == null and r.respond == null) return fail(why, "routes[{d}].cache: on handler and respond routes", .{i});
        if (r.timeout_ms) |t| {
            const decides = r.websocket != null and r.websocket.?.accept == .consumer;
            if (r.handler == null and !decides) return fail(why, "routes[{d}].timeout_ms: on handler routes, and websocket routes whose handshakes the consumer decides", .{i});
            if (std.mem.indexOfScalar(u32, timeouts[0..ntimeouts], t) == null) {
                if (ntimeouts == max_timeouts) return fail(why, "routes: at most {d} distinct timeout_ms values", .{max_timeouts});
                timeouts[ntimeouts] = t;
                ntimeouts += 1;
            }
        }
        var buf: [32]u8 = undefined;
        try checkMiddleware(r.middleware, std.fmt.bufPrint(&buf, "routes[{d}].middleware", .{i}) catch "routes[].middleware", why);
    }
}

/// The client certificate and key of a database: files or text, a
/// certificate with its key, and not with `insecure_skip_verify` and a CA.
fn checkClientCert(c: anytype, comptime root: []const u8, comptime kind: []const u8, i: usize, why: *std.Io.Writer) Problem!void {
    const files = c.client_cert_file != null or c.client_key_file != null;
    const pem = c.client_cert_pem != null or c.client_key_pem != null;
    if (files and pem) return fail(why, root ++ "[{d}]." ++ kind ++ ": client_cert_file/client_key_file or client_cert_pem/client_key_pem, not both", .{i});
    if (files and (c.client_cert_file == null or c.client_key_file == null)) return fail(why, root ++ "[{d}]." ++ kind ++ ": client_cert_file and client_key_file go together", .{i});
    if (pem and (c.client_cert_pem == null or c.client_key_pem == null)) return fail(why, root ++ "[{d}]." ++ kind ++ ": client_cert_pem and client_key_pem go together", .{i});
    if (c.insecure_skip_verify and (c.ca_file != null or c.ca_pem != null)) return fail(why, root ++ "[{d}]." ++ kind ++ ": insecure_skip_verify cannot be set with a CA", .{i});
}

fn oneOf(value: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |o| if (std.mem.eql(u8, value, o)) return true;
    return false;
}

fn checkGrpc(g: Config.Grpc, why: *std.Io.Writer) Problem!void {
    if (comptime !features.grpc) return fail(why, "grpc: gRPC is not built in (-Dgrpc)", .{});
    if (g.descriptor_set != null and g.descriptor_set_file != null) return fail(why, "grpc: one of descriptor_set and descriptor_set_file", .{});
    const descriptors = g.descriptor_set != null or g.descriptor_set_file != null;
    if (g.services.len == 0) return fail(why, "grpc.services: at least one", .{});
    for (g.services, 0..) |svc, i| {
        if (svc.name.len == 0 or svc.name.len > 255) return fail(why, "grpc.services[{d}].name: 1-255 bytes", .{i});
        for (g.services[0..i]) |other| if (std.mem.eql(u8, other.name, svc.name)) return fail(why, "grpc.services[{d}]: {s} twice", .{ i, svc.name });
        if (svc.max_message_size == 0 or svc.max_message_size > max_record_payload) return fail(why, "grpc.services[{d}].max_message_size: 1 to {d}", .{ i, max_record_payload });
        var mw_buf: [48]u8 = undefined;
        try checkMiddleware(svc.middleware, std.fmt.bufPrint(&mw_buf, "grpc.services[{d}].middleware", .{i}) catch "grpc.services[].middleware", why);
        if (svc.methods == null and !descriptors) return fail(why, "grpc.services[{d}]: methods, or the descriptors (descriptor_set)", .{i});
        const methods = svc.methods orelse continue;
        if (methods.len > std.math.maxInt(u16)) return fail(why, "grpc.services[{d}].methods: too many", .{i});
        for (methods, 0..) |m, j| {
            if (m.name.len == 0 or std.mem.indexOfAny(u8, m.name, "/?# ") != null) return fail(why, "grpc.services[{d}].methods[{d}].name: a method name", .{ i, j });
            if (m.kind == null and !descriptors) return fail(why, "grpc.services[{d}].methods[{d}].kind: needed without descriptors", .{ i, j });
            for (methods[0..j]) |other| if (std.mem.eql(u8, other.name, m.name)) return fail(why, "grpc.services[{d}].methods: {s} twice", .{ i, m.name });
        }
    }
}

fn checkMiddleware(list: []const Config.Middleware, where: []const u8, why: *std.Io.Writer) Problem!void {
    for (list, 0..) |m, i| switch (m) {
        .jwt => |j| {
            if (comptime !features.auth) return fail(why, "{s}[{d}].jwt: auth is not built in (-Dauth)", .{ where, i });
            if ((j.jwks_url == null) == (j.jwks == null)) return fail(why, "{s}[{d}].jwt: exactly one of jwks_url and jwks", .{ where, i });
            if (j.jwks_url != null and j.audience == null and !j.allow_any_audience)
                return fail(why, "{s}[{d}].jwt: jwks_url needs audience (this API's identifier at the provider), or allow_any_audience: true when the keys sign for this application alone", .{ where, i });
        },
        .rate_limit => |r| {
            if (!std.mem.eql(u8, r.key, "ip") and !std.mem.startsWith(u8, r.key, "header:"))
                return fail(why, "{s}[{d}].rate_limit.key: \"ip\" or \"header:<name>\"", .{ where, i });
            if (r.limit == 0 or r.window_ms <= 0) return fail(why, "{s}[{d}].rate_limit: limit and window_ms must be positive", .{ where, i });
        },
        .compress => if (comptime !features.compression) return fail(why, "{s}[{d}].compress: compression is not built in (-Dcompression)", .{ where, i }),
        else => {},
    };
}

/// Whether requests behind `list` can run on the protocol's reader and
/// detach (`anole.http.Detached`): none of it may wait. A JWT middleware
/// that fetches keys can.
pub fn neverWaits(list: []const Config.Middleware) bool {
    for (list) |m| switch (m) {
        .jwt => |j| if (j.jwks_url != null) return false,
        else => {},
    };
    return true;
}

// ---------------------------------------------------------------------------
// Building the server's middleware

/// A rate limit keyed by the client's address or a header, on a memory
/// limiter of its own: `anole.ratelimit.Middleware`'s answers.
pub const RateLimitMw = struct {
    limiter: *anole.ratelimit.MemoryLimiter,
    header: ?[]const u8,
    policy: anole.ratelimit.Policy,

    pub const detach_safe = true;

    /// Never waits: no I/O, so `no_wait` routes may sit behind it.
    pub const no_wait = true;

    pub fn execute(self: *const RateLimitMw, req: *http.Request, res: *http.Response, next: anytype) !void {
        var key_buf: [128]u8 = undefined;
        const key = if (self.header) |h| req.headers.get(h) orelse "" else anole.ratelimit.clientAddress(req, &key_buf);
        const r = self.limiter.limiter().take(key, 1, self.policy) catch return next.call();
        try res.header("RateLimit-Limit", try std.fmt.allocPrint(res.arena, "{d}", .{r.limit}));
        try res.header("RateLimit-Remaining", try std.fmt.allocPrint(res.arena, "{d}", .{r.remaining}));
        try res.header("RateLimit-Reset", try std.fmt.allocPrint(res.arena, "{d}", .{r.reset_seconds}));
        if (!r.allowed) {
            try res.header("Retry-After", try std.fmt.allocPrint(res.arena, "{d}", .{r.retry_after_seconds}));
            res.status = .too_many_requests;
            res.content_type = .text;
            res.body = "429 Too Many Requests\n";
            return;
        }
        return next.call();
    }

    pub fn deinit(self: *RateLimitMw) void {
        self.limiter.deinit();
    }
};

/// Anole's middleware for one configuration entry, as a handle the server
/// owns. `keep` holds what must outlive the server's start (keyrings,
/// limiters), freed by the engine.
pub fn middleware(app: *anole.App, arena: std.mem.Allocator, m: Config.Middleware) !http.Middleware(void) {
    switch (m) {
        .request_id => |c| return app.middleware(http.middleware.RequestId.init(.{ .header = c.header, .trust_incoming = c.trust_incoming })),
        .access_log => |c| return app.middleware(anole.observe.AccessLog.init(.{
            .format = switch (c.format) {
                .auto => null,
                .text => .text,
                .json => .json,
            },
            .exclude = c.exclude,
        })),
        .compress => {
            if (comptime !features.compression) unreachable;
            return app.middleware(http.middleware.Compress.init(.{}));
        },
        .cors => |c| return app.middleware(http.middleware.Cors.init(.{
            .origins = c.origins,
            .methods = c.methods,
            .headers = c.headers,
            .expose = c.expose,
            .credentials = c.credentials,
            .max_age = if (c.max_age_ms) |ms| .fromMilliseconds(ms) else null,
        })),
        .jwt => |c| {
            if (comptime !features.auth) unreachable;
            const keys: anole.auth.bearer.Keys = if (c.jwks_url) |url| blk: {
                const ring = try arena.create(anole.auth.Keyring);
                ring.* = .init(app.gpa, app.io(), app.client(), url);
                break :blk .{ .keyring = ring };
            } else blk: {
                const text = try std.json.Stringify.valueAlloc(arena, c.jwks.?, .{});
                break :blk .{ .static = try anole.auth.parseJwks(arena, text) };
            };
            return app.middleware(anole.auth.RequireJwt.init(keys, .{
                .issuer = c.issuer,
                .audience = c.audience,
                .allow_any_audience = c.allow_any_audience,
                .leeway = .fromMilliseconds(c.leeway_ms),
                .require_exp = c.require_exp,
            }, .{ .required_claims = c.required_claims, .scopes = c.scopes, .realm = c.realm }));
        },
        .rate_limit => |c| {
            const limiter = try arena.create(anole.ratelimit.MemoryLimiter);
            limiter.* = .init(app.gpa, app.io(), .{ .max_entries = c.max_entries });
            return app.middleware(RateLimitMw{
                .limiter = limiter,
                .header = if (std.mem.startsWith(u8, c.key, "header:")) c.key["header:".len..] else null,
                .policy = .{ .limit = c.limit, .window = .fromMilliseconds(c.window_ms), .burst = c.burst },
            });
        },
    }
}

pub fn precompressed(arena: std.mem.Allocator, names: []const []const u8) ![]const http.core.Precompressed {
    const out = try arena.alloc(http.core.Precompressed, names.len);
    for (names, out) |n, *o| {
        o.* = std.meta.stringToEnum(http.core.Precompressed, n) orelse return error.Config;
    }
    return out;
}

/// A fixed response route's data.
pub const FixedRoute = struct {
    status: http.Status,
    body: []const u8,
    headers: []const [2][]const u8,

    pub fn handler(req: *http.Request, res: *http.Response) anyerror!void {
        const f: *const FixedRoute = @ptrCast(@alignCast(req.route.?.data.?));
        res.status = f.status;
        for (f.headers) |h| try res.header(h[0], h[1]);
        res.body = f.body;
    }
};

pub fn fixed(arena: std.mem.Allocator, f: Config.Fixed) !*FixedRoute {
    const hs = try arena.alloc([2][]const u8, f.headers.map.count());
    var it = f.headers.map.iterator();
    var j: usize = 0;
    while (it.next()) |kv| : (j += 1) hs[j] = .{ kv.key_ptr.*, kv.value_ptr.* };
    const out = try arena.create(FixedRoute);
    out.* = .{ .status = http.Status.fromCode(f.status) catch .internal_server_error, .body = f.body, .headers = hs };
    return out;
}

test "parse: the defaults, a full document, and what is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);

    const d = try parse(a, "{}", &why);
    try std.testing.expectEqual(@as(usize, 1), d.listeners.len);
    try std.testing.expectEqual(@as(u32, 30_000), d.timeouts.request_ms.?);

    const full_doc =
        \\{"executors": 2,
        \\ "listeners": [{"name": "web", "address": "127.0.0.1", "port": 0}],
        \\ "limits": {"inline_body_max": 1024, "max_inflight": 8},
        \\ "middleware": [{"request_id": {}}, {"cors": {"origins": ["https://a.example"]}},
        \\                {"rate_limit": {"limit": 5, "key": "header:X-Key"}}],
        \\ "routes": [
        \\   {"method": "GET", "path": "/a", "handler": 1, "timeout_ms": 500, "cache": {"ttl_ms": 1000}},
        \\   {"path": "/b", "respond": {"status": 201, "body": "x", "headers": {"x-y": "z"}}}
    ;
    const ws_route = ",\n   {\"path\": \"/ws\", \"websocket\": {\"handler\": 2}}";
    const end = "\n ],\n \"observe\": {\"metrics\": {}, \"health\": {}}}";
    // The WebSocket route only where WebSocket is built in.
    const full = if (features.websocket) full_doc ++ ws_route ++ end else full_doc ++ end;
    const f = try parse(a, full, &why);
    try std.testing.expectEqual(@as(usize, if (features.websocket) 3 else 2), f.routes.len);
    try std.testing.expectEqual(@as(?u32, 500), f.routes[0].timeout_ms);
    try std.testing.expect(f.middleware[2] == .rate_limit);

    const bad = [_][]const u8{
        "{\"nope\": 1}",
        "{\"routes\": [{\"path\": \"/x\"}]}",
        "{\"routes\": [{\"path\": \"/x\", \"handler\": 1, \"respond\": {}}]}",
        "{\"routes\": [{\"path\": \"x\", \"handler\": 1}]}",
        "{\"routes\": [{\"method\": \"FETCH\", \"path\": \"/x\", \"handler\": 1}]}",
        "{\"listeners\": []}",
        "{\"middleware\": [{\"rate_limit\": {\"key\": \"cookie\"}}]}",
        // Framing fields are the server's; names and values must go on the wire.
        "{\"routes\": [{\"path\": \"/x\", \"respond\": {\"headers\": {\"Connection\": \"close\"}}}]}",
        "{\"routes\": [{\"path\": \"/x\", \"respond\": {\"headers\": {\"transfer-encoding\": \"chunked\"}}}]}",
        "{\"routes\": [{\"path\": \"/x\", \"respond\": {\"headers\": {\"x bad\": \"1\"}}}]}",
        "{\"routes\": [{\"path\": \"/x\", \"respond\": {\"headers\": {\"x-ok\": \"a\\r\\nb\"}}}]}",
        // A provider's keys sign for its other clients too.
        "{\"middleware\": [{\"jwt\": {\"jwks_url\": \"https://issuer.example/jwks\"}}]}",
        "{\"limits\": {\"inline_body_max\": 10, \"body_max\": 5}}",
        // A record carries its length in 32 bits.
        "{\"limits\": {\"inline_body_max\": 4294967295, \"body_max\": 8589934592}}",
        "{\"limits\": {\"ws_max_message\": 4294967295}}",
        // A database is one kind, named once, with a known sslmode given once.
        "{\"databases\": [{\"name\": \"d\"}]}",
        "{\"databases\": [{\"name\": \"d\", \"sqlite\": {\"path\": \"x\"}, \"postgres\": {}}]}",
        "{\"databases\": [{\"name\": \"d\", \"postgres\": {\"sslmode\": \"maybe\"}}]}",
        "{\"databases\": [{\"name\": \"d\", \"postgres\": {\"sslmode\": \"disable\", \"url\": \"postgres://h/d?sslmode=require\"}}]}",
        "{\"databases\": [{\"name\": \"d\", \"postgres\": {\"ca_file\": \"a\", \"ca_pem\": \"b\"}}]}",
        "{\"databases\": [{\"name\": \"d\", \"redis\": {}, \"postgres\": {}}]}",
        "{\"databases\": [{\"name\": \"d\", \"redis\": {\"max_connections\": 0}}]}",
        "{\"databases\": [{\"name\": \"d\", \"mongodb\": {\"ca_file\": \"a\", \"ca_pem\": \"b\"}}]}",
        "{\"routes\": [{\"path\": \"/wt\", \"webtransport\": {\"handler\": 1}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true}, \"http3\": true}], \"routes\": [{\"method\": \"GET\", \"path\": \"/wt\", \"webtransport\": {\"handler\": 1}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true}, \"http3\": true}], \"routes\": [{\"path\": \"/wt\", \"webtransport\": {\"handler\": 1, \"datagram_queue\": 0}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_auth\": \"always\"}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_auth\": \"require\"}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_auth\": \"request\", \"client_ca_file\": \"a\", \"client_ca_pem\": \"b\"}}]}",
        "{\"listeners\": [{\"tls\": {\"self_signed\": true, \"client_ca_pem\": \"b\"}}]}",
        "{\"listeners\": [{\"proxy_protocol\": false, \"proxy_protocol_from\": [\"10.0.0.0/8\"]}]}",
        "{\"deployment\": \"cloud\"}",
        "{\"environment\": \"staging\"}",
    };
    for (bad) |doc| {
        why.end = 0;
        try std.testing.expectError(error.Config, parse(a, doc, &why));
        try std.testing.expect(why.buffered().len > 0);
    }

    if (features.postgres) {
        why.end = 0;
        const p = try parse(a, "{\"databases\": [{\"name\": \"d\", \"postgres\": {\"url\": \"postgres://db.internal/app\", \"sslmode\": \"verify-ca\", \"ca_pem\": \"-----BEGIN CERTIFICATE-----\"}}]}", &why);
        try std.testing.expectEqual(SslMode.verify_ca, sslMode(p.databases[0].postgres.?.sslmode.?).?);
        try std.testing.expectEqual(ResetSession.auto, p.databases[0].postgres.?.reset_session);
        why.end = 0;
        const always = try parse(a, "{\"databases\": [{\"name\": \"d\", \"postgres\": {\"url\": \"postgres://localhost/app\", \"reset_session\": \"always\"}}]}", &why);
        try std.testing.expectEqual(ResetSession.always, always.databases[0].postgres.?.reset_session);
    }
    if (features.auth) {
        why.end = 0;
        _ = try parse(a, "{\"middleware\": [{\"jwt\": {\"jwks_url\": \"https://issuer.example/jwks\", \"audience\": \"api\"}}]}", &why);
        _ = try parse(a, "{\"middleware\": [{\"jwt\": {\"jwks_url\": \"https://issuer.example/jwks\", \"allow_any_audience\": true}}]}", &why);
        // Inline keys are the application's own: no audience needed.
        _ = try parse(a, "{\"middleware\": [{\"jwt\": {\"jwks\": {\"keys\": []}}}]}", &why);
    }
}

test "parse: a gRPC service takes middleware; one that fetches keys keeps its calls attached" {
    if (!features.grpc) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [512]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const cfg = try parse(a,
        \\{"grpc": {"services": [{"name": "a.B", "handler": 1, "methods": [{"name": "M", "kind": "unary"}],
        \\  "middleware": [{"rate_limit": {"limit": 5}}]}]}}
    , &why);
    try std.testing.expectEqual(@as(usize, 1), cfg.grpc.?.services[0].middleware.len);
    try std.testing.expect(neverWaits(cfg.grpc.?.services[0].middleware));
    if (features.auth) {
        const waits = try parse(a,
            \\{"grpc": {"services": [{"name": "a.B", "handler": 1, "methods": [{"name": "M", "kind": "unary"}],
            \\  "middleware": [{"jwt": {"jwks_url": "https://issuer.example/jwks", "audience": "api"}}]}]}}
        , &why);
        try std.testing.expect(!neverWaits(waits.grpc.?.services[0].middleware));
        // Checked like a route's: both key sources is a config error naming the service.
        why.end = 0;
        try std.testing.expectError(error.Config, parse(a,
            \\{"grpc": {"services": [{"name": "a.B", "handler": 1, "methods": [{"name": "M", "kind": "unary"}],
            \\  "middleware": [{"jwt": {"jwks_url": "https://i/jwks", "jwks": {"keys": []}}}]}]}}
        , &why));
        try std.testing.expect(std.mem.indexOf(u8, why.buffered(), "grpc.services[0].middleware") != null);
    }
}

test "parse: include/anole.schema.json names every field Config has, and no other" {
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    const defs = root.object.get("$defs").?.object;
    try SchemaCheck.walk(Config, root, defs);
}

const SchemaCheck = struct {
    fn resolve(node: std.json.Value, defs: std.json.ObjectMap) std.json.Value {
        var n = node;
        while (true) {
            if (n.object.get("$ref")) |r| {
                n = defs.get(r.string["#/$defs/".len..]).?;
                continue;
            }
            if (n.object.get("anyOf")) |any| {
                n = any.array.items[0];
                continue;
            }
            return n;
        }
    }

    /// The `default` a property states: its own, or its first `anyOf` branch's.
    fn defaultOf(prop: std.json.Value) ?std.json.Value {
        if (prop != .object) return null;
        if (prop.object.get("default")) |d| return d;
        if (prop.object.get("anyOf")) |any| return any.array.items[0].object.get("default");
        return null;
    }

    /// Whether a type's default is something the schema states as a scalar,
    /// a string or a list of strings.
    fn scalarDefault(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .int, .bool, .@"enum" => true,
            .optional => |o| scalarDefault(o.child),
            .pointer => |p| p.size == .slice and (p.child == u8 or (@typeInfo(p.child) == .pointer and @typeInfo(p.child).pointer.child == u8)),
            else => false,
        };
    }

    /// Whether the schema's `have` is `value`, the Zig default.
    fn sameDefault(comptime T: type, value: T, have: std.json.Value) bool {
        switch (@typeInfo(T)) {
            .int => return have == .integer and have.integer == value,
            .bool => return have == .bool and have.bool == value,
            .@"enum" => return have == .string and std.mem.eql(u8, have.string, @tagName(value)),
            .optional => |o| return if (value) |v| sameDefault(o.child, v, have) else have == .null,
            .pointer => |p| {
                if (p.child == u8) return have == .string and std.mem.eql(u8, have.string, value);
                if (have != .array or have.array.items.len != value.len) return false;
                for (value, have.array.items) |a, b| if (b != .string or !std.mem.eql(u8, a, b.string)) return false;
                return true;
            },
            else => return true,
        }
    }

    /// The groups whose every key states its default in the schema.
    fn requiresDefaults(comptime T: type) bool {
        return T == Config.Timeouts or T == Config.Limits or T == Config.Http3 or
            T == anole.ServerOptions.Proxy or T == anole.ServerOptions.RequestOptions or
            T == anole.ServerOptions.ResponseOptions or T == anole.ServerOptions.Http2;
    }

    fn walk(comptime T: type, node_in: std.json.Value, defs: std.json.ObjectMap) error{SchemaOutOfDate}!void {
        if (T == std.json.Value) return;
        const node = resolve(node_in, defs);
        switch (@typeInfo(T)) {
            .optional => |o| return walk(o.child, node, defs),
            .pointer => |p| if (p.child != u8) return walk(p.child, node.object.get("items").?, defs),
            .@"struct" => |s| {
                if (T == std.json.Value or T == std.json.ArrayHashMap([]const u8)) return;
                const props = node.object.get("properties") orelse {
                    std.debug.print("schema: no properties for {s}\n", .{@typeName(T)});
                    return error.SchemaOutOfDate;
                };
                if (props.object.count() != s.field_names.len) {
                    std.debug.print("schema: {s} has {d} fields, the schema {d}\n", .{ @typeName(T), s.field_names.len, props.object.count() });
                    return error.SchemaOutOfDate;
                }
                inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attrs| {
                    const p = props.object.get(name) orelse {
                        std.debug.print("schema: {s}.{s} missing\n", .{ @typeName(T), name });
                        return error.SchemaOutOfDate;
                    };
                    if (comptime scalarDefault(FT)) if (comptime attrs.defaultValue(FT)) |dv| {
                        if (defaultOf(p)) |have| {
                            if (!sameDefault(FT, dv, have)) {
                                std.debug.print("schema: {s}.{s}: the schema's default differs from the code's\n", .{ @typeName(T), name });
                                return error.SchemaOutOfDate;
                            }
                        } else if (comptime requiresDefaults(T)) {
                            std.debug.print("schema: {s}.{s} states no default\n", .{ @typeName(T), name });
                            return error.SchemaOutOfDate;
                        }
                    };
                    try walk(FT, p, defs);
                }
            },
            .@"union" => |u| {
                const variants = node.object.get("oneOf").?.array.items;
                if (variants.len != u.field_names.len) return error.SchemaOutOfDate;
                inline for (u.field_names, u.field_types) |name, FT| {
                    const v = for (variants) |v| {
                        if (v.object.get("properties").?.object.get(name)) |p| break p;
                    } else {
                        std.debug.print("schema: middleware {s} missing\n", .{name});
                        return error.SchemaOutOfDate;
                    };
                    try walk(FT, v, defs);
                }
            },
            else => {},
        }
    }
};

test "config: modes keys" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const c = try parse(a,
        \\{"environment": "development", "deployment": "behind_proxy", "error_detail": false,
        \\ "proxy": {"trusted": ["private", "203.0.113.7"]},
        \\ "listeners": [{"proxy_protocol_from": ["10.0.0.0/8"]}, {"port": 0}]}
    , &why);
    try std.testing.expectEqual(anole.Environment.development, c.environment.?);
    try std.testing.expectEqual(anole.Deployment.behind_proxy, c.deployment.?);
    try std.testing.expectEqual(false, c.error_detail.?);
    try std.testing.expectEqual(@as(usize, 2), c.proxy.trusted.?.len);
    try std.testing.expect(c.listeners[0].address == null and c.listeners[0].port == null and c.listeners[0].proxy_protocol == null);
    try std.testing.expectEqual(@as(?u16, 0), c.listeners[1].port);
    const d = try parse(a, "{}", &why);
    try std.testing.expect(d.environment == null and d.deployment == null and d.error_detail == null);
    try std.testing.expectEqual(@as(?u32, 75_000), d.timeouts.keepalive_ms);
}

test "config: log.format and log.service parse; the access log's format defaults to auto" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const c = try parse(a,
        \\{"log": {"format": "json", "service": "api"}, "banner": true,
        \\ "middleware": [{"access_log": {}}, {"access_log": {"format": "text"}}]}
    , &why);
    try std.testing.expectEqual(anole.log.Format.json, c.log.format);
    try std.testing.expectEqualStrings("api", c.log.service.?);
    try std.testing.expect(c.banner);
    try std.testing.expect(c.middleware[0].access_log.format == .auto);
    try std.testing.expect(c.middleware[1].access_log.format == .text);
    const d = try parse(a, "{}", &why);
    try std.testing.expectEqual(anole.log.Format.auto, d.log.format);
    try std.testing.expect(d.log.service == null and !d.banner);
    try std.testing.expect(std.mem.indexOf(u8, @import("anole_capi_schema").text, "\"log\"") != null);
}
