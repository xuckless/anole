//! What a failed area call (`CallError`) answers through the C ABI:
//! its code, its `anole_last_error_name` and its `anole_last_error` text.
//! lib.zig applies a `Reply`; the texts are data, one `Messages` per area.
//! A new error or area is a field or a value here, not a branch in lib.zig.
const std = @import("std");
const abi = @import("abi.zig");

/// What an area call refuses with (engine.zig re-exports it).
pub const CallError = error{ Invalid, State, Again, OutOfMemory, Unsupported, Gone };

/// The texts of one area. `null` is the bare code's own text and name
/// (`failCode`); a non-null `gone` also counts in `anole_stats.gone`.
/// OutOfMemory and Again are always bare.
pub const Messages = struct {
    invalid: []const u8,
    state: []const u8,
    unsupported: ?[]const u8,
    gone: ?[]const u8,
};

pub const Reply = struct {
    code: i32,
    name: []const u8,
    /// Null: the bare code.
    text: ?[]const u8,
    count_gone: bool = false,
};

/// `invalid_text` replaces the area's Invalid text (smtp's per-call reason).
pub fn resolve(err: CallError, comptime M: Messages, invalid_text: ?[]const u8) Reply {
    const name = @errorName(err);
    return switch (err) {
        error.Invalid => .{ .code = abi.E_INVALID, .name = name, .text = invalid_text orelse M.invalid },
        error.State => .{ .code = abi.E_STATE, .name = name, .text = M.state },
        error.Unsupported => .{ .code = abi.E_UNSUPPORTED, .name = name, .text = M.unsupported },
        error.Gone => .{ .code = abi.E_GONE, .name = name, .text = M.gone, .count_gone = M.gone != null },
        error.OutOfMemory => .{ .code = abi.E_NOMEM, .name = name, .text = null },
        error.Again => .{ .code = abi.E_AGAIN, .name = name, .text = null },
    };
}

const state_a = "the server is not open, or no executor feeds this consumer";
const state_broker = "the server is not open, the broker is not connected, or no executor feeds this consumer";

pub const nats: Messages = .{
    .invalid = "invalid argument (a subject, header, size, flag, or a consumer of another server or other than the request's)",
    .state = state_broker,
    .unsupported = null,
    .gone = "the request, message or subscription it served is over",
};
pub const kafka: Messages = .{
    .invalid = "invalid argument (a topic, partition, flag, size, group or topic list, or a consumer of another server)",
    .state = state_broker,
    .unsupported = null,
    .gone = "the batch it served is over",
};
pub const db: Messages = .{
    .invalid = "invalid argument (a value type, an option this call does not take, a consumer of another server or other than the request's, or a request handle of another kind)",
    .state = state_a,
    .unsupported = "this database or build has no transactions (SQLite and PostgreSQL only)",
    .gone = "the request or transaction it served is over",
};
pub const jobs: Messages = .{
    .invalid = "invalid argument (a job's kind, JSON, size or flag, a queue or kind the configuration or another worker does not allow, a transaction on another database than the jobs store)",
    .state = "the server is not open (workers: before the start only), or no executor feeds this consumer",
    .unsupported = "the configuration has no \"jobs\", or jobs are not built in (-Djobs)",
    .gone = "the job, request or transaction it served is over",
};
pub const webhooks: Messages = .{
    .invalid = "invalid argument (a type, a size field, data_json that is not JSON, or a consumer of another server)",
    .state = "the server is draining or stopped, the transaction is not open, or no executor feeds this consumer",
    .unsupported = "the configuration has no \"webhooks\" (it needs \"jobs\"), or -Dwebhooks is off",
    .gone = "the transaction it named is over",
};
/// Gone is bare and uncounted: kept as it was (S3 changes no behaviour);
/// docs/c-abi.md says every GONE counts, so this is an open inconsistency.
pub const s3: Messages = .{
    .invalid = "invalid argument (a key of 0 or over 1024 bytes, an option this call does not take, a consumer of another server or other than the request's, or a request handle of another kind)",
    .state = state_a,
    .unsupported = null,
    .gone = null,
};
pub const smtp: Messages = .{
    .invalid = "invalid argument (a flag, a size, or a consumer of another server or other than the request's)",
    .state = state_a,
    .unsupported = null,
    .gone = "the request it served is over",
};

const Row = struct { err: CallError, code: i32, text: ?[]const u8 };

fn expectArea(comptime M: Messages, rows: []const Row) !void {
    for (rows) |r| {
        const got = resolve(r.err, M, null);
        try std.testing.expectEqual(r.code, got.code);
        try std.testing.expectEqualStrings(@errorName(r.err), got.name);
        if (r.text) |t| try std.testing.expectEqualStrings(t, got.text.?) else try std.testing.expectEqual(@as(?[]const u8, null), got.text);
        try std.testing.expectEqual(r.err == error.Gone and r.text != null, got.count_gone);
    }
}

// The texts are copied from lib.zig's mappers at s3/batch1 (1e5e86c7).
test "failure: nats" {
    try expectArea(nats, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a subject, header, size, flag, or a consumer of another server or other than the request's)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open, the broker is not connected, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = null },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the request, message or subscription it served is over" },
    });
}

test "failure: kafka" {
    try expectArea(kafka, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a topic, partition, flag, size, group or topic list, or a consumer of another server)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open, the broker is not connected, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = null },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the batch it served is over" },
    });
}

test "failure: db" {
    try expectArea(db, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a value type, an option this call does not take, a consumer of another server or other than the request's, or a request handle of another kind)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = "this database or build has no transactions (SQLite and PostgreSQL only)" },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the request or transaction it served is over" },
    });
}

test "failure: jobs" {
    try expectArea(jobs, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a job's kind, JSON, size or flag, a queue or kind the configuration or another worker does not allow, a transaction on another database than the jobs store)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open (workers: before the start only), or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = "the configuration has no \"jobs\", or jobs are not built in (-Djobs)" },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the job, request or transaction it served is over" },
    });
}

test "failure: webhooks" {
    try expectArea(webhooks, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a type, a size field, data_json that is not JSON, or a consumer of another server)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is draining or stopped, the transaction is not open, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = "the configuration has no \"webhooks\" (it needs \"jobs\"), or -Dwebhooks is off" },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the transaction it named is over" },
    });
}

test "failure: s3 (Gone bare and uncounted)" {
    try expectArea(s3, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a key of 0 or over 1024 bytes, an option this call does not take, a consumer of another server or other than the request's, or a request handle of another kind)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = null },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = null },
    });
}

test "failure: smtp" {
    try expectArea(smtp, &.{
        .{ .err = error.Invalid, .code = abi.E_INVALID, .text = "invalid argument (a flag, a size, or a consumer of another server or other than the request's)" },
        .{ .err = error.State, .code = abi.E_STATE, .text = "the server is not open, or no executor feeds this consumer" },
        .{ .err = error.Again, .code = abi.E_AGAIN, .text = null },
        .{ .err = error.OutOfMemory, .code = abi.E_NOMEM, .text = null },
        .{ .err = error.Unsupported, .code = abi.E_UNSUPPORTED, .text = null },
        .{ .err = error.Gone, .code = abi.E_GONE, .text = "the request it served is over" },
    });
}

test "failure: a per-call Invalid text replaces the area's, other errors keep theirs" {
    const own = resolve(error.Invalid, smtp, "to: not an address");
    try std.testing.expectEqualStrings("to: not an address", own.text.?);
    try std.testing.expectEqual(@as(i32, abi.E_INVALID), own.code);
    try std.testing.expectEqualStrings("the server is not open, or no executor feeds this consumer", resolve(error.State, smtp, "x").text.?);
}
