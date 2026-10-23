//! `anole.resilience`: retries with backoff and jitter, retry throttling
//! and circuit breakers, shared by the HTTP and gRPC clients, the database
//! connectors and the brokers. See docs/resilience.md.
//!
//! The types live in `core.zig` (nothing but `std`, so the HTTP core can
//! use them too); this file adds the Prometheus binding.
const core = @import("resilience_core");

pub const Duration = core.Duration;
pub const Kind = core.Kind;
pub const Backoff = core.Backoff;
pub const Retry = core.Retry;
pub const Choice = core.Choice;
pub const Throttle = core.Throttle;
pub const Breaker = core.Breaker;
pub const Breakers = core.Breakers;
pub const Verdict = core.Verdict;
pub const Policy = core.Policy;
pub const Error = core.Error;
pub const Run = core.Run;
pub const run = core.run;
/// The hooks a breaker or policy reports through.
pub const Metrics = core.Metrics;

/// A Prometheus registry's breaker and retry series.
pub const Binding = @import("metrics.zig").Binding;

test {
    _ = @import("metrics.zig");
    _ = core;
}
