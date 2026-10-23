//! One `main` that runs as a server and as an AWS Lambda function:
//! `zig build run-lambda` serves it on port 3000; built with
//! `zig build lambda` (addApp's `.lambda`) or run with
//! `ANOLE_DEPLOYMENT=lambda`, the same routes answer Lambda invocations
//! (Function URLs, API Gateway, ALB), and events that are not HTTP
//! requests (SQS, EventBridge schedules) arrive as a POST to
//! `anole.lambda.default_event_path`. examples/lambda/README.md has the
//! deploy commands; docs/lambda.md the rest.
const std = @import("std");
const anole = @import("anole");

pub const std_options = anole.std_options;
pub const panic = anole.panic;

fn hello(_: *anole.Request, res: *anole.Response) !void {
    try res.json(.{ .message = "Hello from Anole" });
}

/// An SQS batch, as Lambda's event source mapping sends it (only the
/// fields used here; the rest are ignored).
const Batch = struct {
    Records: []const struct { messageId: []const u8, body: []const u8 } = &.{},
};

const Failure = struct { itemIdentifier: []const u8 };

/// Every record is processed; one that fails would be listed in
/// `batchItemFailures` (with ReportBatchItemFailures on the mapping), so
/// SQS retries that record alone.
fn onQueue(req: *anole.Request, res: *anole.Response) !void {
    const batch = try req.bind(Batch);
    for (batch.Records) |r| std.log.info("message {s}: {d} bytes", .{ r.messageId, r.body.len });
    try res.json(.{ .batchItemFailures = &[_]Failure{} });
}

pub fn main(init: std.process.Init) !void {
    var app = try anole.App.init(init.gpa, .{});
    defer app.deinit();
    app.get("/", hello);
    app.post(anole.lambda.default_event_path, onQueue);
    // Under deployment lambda no listener opens: invocations come from
    // the Lambda Runtime API instead, and a startup line says so.
    try app.listen(":3000");
}
