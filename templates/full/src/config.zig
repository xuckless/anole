//! The app's settings, typed. Loaded once in `main` by `anole.config.load`:
//! the defaults below, then the `.env` file (development only), then the
//! environment; a missing required value or a bad one stops the start with
//! every problem listed. `Secret`s never print.
const anole = @import("anole");

pub const Config = struct {
    port: u16 = 3000,
    /// Signs the demo bearer tokens (HS256). 32 characters or more; set it
    /// from your secret store in production.
    jwt_secret: anole.Secret,
    /// The sealed session cookie's key: 32 random bytes in base64
    /// (`openssl rand -base64 32`). Without one, a random key is made at
    /// start (sessions then end on restart).
    session_key: ?anole.Secret = null,
    /// What GET /upstream calls, through the client with retry and a breaker.
    upstream_url: []const u8 = "http://127.0.0.1:3000/healthz",

    // Switched on by setting the setting (here, in .env or the environment).
    database_url: ?anole.Secret = null, // PostgreSQL
    redis_url: ?anole.Secret = null,
    nats_url: ?anole.Secret = null,
    kafka_bootstrap_servers: ?[]const u8 = null,
    s3_bucket: ?[]const u8 = null, // S3 or compatible; the AWS_* variables say where and who
    smtp_url: ?anole.Secret = null, // outgoing mail
    otel_exporter_otlp_endpoint: ?[]const u8 = null, // OpenTelemetry traces
};
