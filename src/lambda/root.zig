//! The AWS Lambda adapter (`-Dlambda`): the same app served through the
//! Lambda Runtime API under `deployment = lambda` (docs/lambda.md).
//!
//! `event` turns the invocation's JSON into a request, `encode` turns the
//! answer back into the shape each front door expects, `runtime` speaks the
//! Runtime API, and `exchange` runs one request through the router.

const std = @import("std");
const dusty = @import("dusty");

pub const event = @import("event.zig");
pub const encode = @import("encode.zig");
pub const runtime = @import("runtime.zig");
pub const exchange = @import("exchange.zig");

/// `ServerOptions.lambda`: where invocations come from and how answers go back.
pub const Options = @import("../server.zig").Options.Lambda;

/// What the invocation came from.
pub const Source = enum { rest_api, http_api, function_url, alb, vpc_lattice, event };

/// The invocation behind a request, for a request served under
/// `deployment = .lambda` through the Runtime API; null otherwise
/// (including Web Functions, which have no invocation).
pub const Context = struct {
    /// Lambda-Runtime-Aws-Request-Id (also `req.id`).
    request_id: []const u8,
    /// Lambda-Runtime-Invocation-Id, empty when Lambda sent none.
    invocation_id: []const u8,
    /// Lambda-Runtime-Deadline-Ms: Unix milliseconds.
    deadline_ms: i64,
    /// Lambda-Runtime-Invoked-Function-Arn.
    function_arn: []const u8,
    /// Lambda-Runtime-Trace-Id ("Root=...;Parent=...;Sampled=1"), empty
    /// when none. Not exported as _X_AMZN_TRACE_ID (Anole never changes
    /// the process environment).
    trace_id: []const u8,
    source: Source,
    /// API Gateway's stage, null for other sources.
    stage: ?[]const u8,
    /// The event's `requestContext` (authorizer claims, identity, API IDs)
    /// as parsed, null for non-HTTP events.
    request_context: ?std.json.Value,
    /// The whole event as Lambda sent it.
    event: []const u8,
    /// Lambda-Runtime-Client-Context / -Cognito-Identity (mobile SDKs),
    /// empty when absent.
    client_context: []const u8,
    cognito_identity: []const u8,
};

/// The request-local key the adapter stores the `*const Context` under.
pub const local_key = "anole.lambda";

/// The invocation behind `req`; null when it was not served from a Lambda
/// invocation.
pub fn context(req: *const dusty.Request) ?*const Context {
    return req.local(*const Context, local_key);
}

/// The default `Options.event_path`.
pub const default_event_path = "/_lambda/event";

/// Response sizes Lambda accepts, encoded (buffered).
pub const max_response_bytes: usize = 6_291_556;
pub const max_alb_response_bytes: usize = 1_048_576;

test {
    _ = event;
    _ = encode;
    _ = runtime;
    _ = exchange;
    _ = @import("fake_runtime_test.zig");
}
