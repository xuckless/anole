//! Observability: Prometheus metrics, OpenTelemetry traces (OTLP/HTTP),
//! structured access logs, and health/readiness routes.
const std = @import("std");

pub const metrics = @import("metrics.zig");
pub const trace = @import("trace.zig");
pub const AccessLog = @import("access_log.zig").AccessLog;
pub const access_log = @import("access_log.zig");
pub const Health = @import("health.zig").Health;

test {
    _ = metrics;
    _ = trace;
    _ = access_log;
    _ = @import("health.zig");
    _ = @import("observe_test.zig");
}
