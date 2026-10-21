//! Observability: Prometheus metrics, OpenTelemetry traces (OTLP/HTTP),
//! structured access logs, and health/readiness routes. An app turns each
//! on with one call, before its routes:
//!
//!     app.use(anole.middleware.RequestId.init(.{}));
//!     app.use(anole.observe.AccessLog.init(.{ .format = .json }));
//!     _ = app.metrics(.{}); // the registry, for metrics of your own
//!     _ = try app.tracing(.{ .service_name = "api" });
//!     _ = app.health(.{});
//!
//! The database connectors made through the app (`app.postgres` and the
//! rest) report to whichever of these exist when serving starts.
const std = @import("std");

/// Prometheus metrics: `Registry`, counters, gauges, histograms and the
/// HTTP middleware. `app.metrics(.{})` sets them up.
pub const metrics = @import("metrics.zig");
/// OpenTelemetry tracing: the OTLP/HTTP `Exporter` and the per-request
/// span middleware. `app.tracing(.{})` sets them up.
pub const trace = @import("trace.zig");
/// The access log middleware: `app.use(anole.observe.AccessLog.init(.{}))`.
pub const AccessLog = @import("access_log.zig").AccessLog;
/// The access log's options, formats and line formatter.
pub const access_log = @import("access_log.zig");
/// `/healthz` and `/readyz` with readiness checks. `app.health(.{})` sets
/// them up.
pub const Health = @import("health.zig").Health;
/// `/healthz`, `/readyz` and `/metrics`, for the middleware's `exclude`.
pub const probe_paths = @import("common.zig").probe_paths;

test {
    _ = metrics;
    _ = trace;
    _ = access_log;
    _ = @import("health.zig");
    _ = @import("common.zig");
    _ = @import("observe_test.zig");
}
