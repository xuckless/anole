//! `include/anole.h` against `abi.zig`: the header translated by translate-c
//! (`anole_h`), every struct's size, alignment and field offsets, and every
//! constant, compared with the Zig side the library is built from. Run by
//! `zig build test` (and `zig build capi-test`).
const std = @import("std");
const abi = @import("capi_abi");
const c = @import("anole_h");

fn expectSameLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    try std.testing.expectEqual(@alignOf(C), @alignOf(Zig));
    const zi = @typeInfo(Zig).@"struct";
    const ci = @typeInfo(C).@"struct";
    try std.testing.expectEqual(ci.field_names.len, zi.field_names.len);
    inline for (zi.field_names, ci.field_names, zi.field_types, ci.field_types) |zn, cn, zt, ct| {
        std.testing.expectEqual(@offsetOf(C, cn), @offsetOf(Zig, zn)) catch |err| {
            std.debug.print("field {s} / {s}\n", .{ zn, cn });
            return err;
        };
        try std.testing.expectEqual(@sizeOf(ct), @sizeOf(zt));
    }
}

test "anole.h: every struct as abi.zig lays it out" {
    try expectSameLayout(abi.Str, c.anole_str);
    try expectSameLayout(abi.Header, c.anole_header);
    try expectSameLayout(abi.ServerOptions, c.anole_server_options);
    try expectSameLayout(abi.Stats, c.anole_stats);
    try expectSameLayout(abi.ConsumerOptions, c.anole_consumer_options);
    try expectSameLayout(abi.Event, c.anole_event);
    try expectSameLayout(abi.Span, c.anole_span);
    try expectSameLayout(abi.RequestEvent, c.anole_request_event);
    try expectSameLayout(abi.SentEvent, c.anole_sent_event);
    try expectSameLayout(abi.WsMessageEvent, c.anole_ws_message_event);
    try expectSameLayout(abi.WsCloseEvent, c.anole_ws_close_event);
    try expectSameLayout(abi.DbValue, c.anole_db_value);
    try expectSameLayout(abi.DbOptions, c.anole_db_options);
    try expectSameLayout(abi.DbResultEvent, c.anole_db_result_event);
    try expectSameLayout(abi.DbCell, c.anole_db_cell);
}

test "anole.h: every constant as abi.zig has it" {
    const eq = std.testing.expectEqual;
    try eq(abi.version_major, c.ANOLE_ABI_VERSION_MAJOR);
    try eq(abi.version_minor, c.ANOLE_ABI_VERSION_MINOR);
    try eq(abi.version, c.ANOLE_ABI_VERSION);
    try eq(abi.OK, c.ANOLE_OK);
    try eq(abi.BUSY, c.ANOLE_BUSY);
    try eq(abi.E_INVALID, c.ANOLE_E_INVALID);
    try eq(abi.E_GONE, c.ANOLE_E_GONE);
    try eq(abi.E_AGAIN, c.ANOLE_E_AGAIN);
    try eq(abi.E_NOMEM, c.ANOLE_E_NOMEM);
    try eq(abi.E_CONFIG, c.ANOLE_E_CONFIG);
    try eq(abi.E_STATE, c.ANOLE_E_STATE);
    try eq(abi.E_UNSUPPORTED, c.ANOLE_E_UNSUPPORTED);
    try eq(abi.E_TOOBIG, c.ANOLE_E_TOOBIG);
    try eq(abi.E_SYSTEM, c.ANOLE_E_SYSTEM);
    try eq(abi.E_TIMEOUT, c.ANOLE_E_TIMEOUT);
    try eq(abi.E_DB, c.ANOLE_E_DB);
    try eq(abi.DB_NULL, c.ANOLE_DB_NULL);
    try eq(abi.DB_INT, c.ANOLE_DB_INT);
    try eq(abi.DB_FLOAT, c.ANOLE_DB_FLOAT);
    try eq(abi.DB_TEXT, c.ANOLE_DB_TEXT);
    try eq(abi.DB_BLOB, c.ANOLE_DB_BLOB);
    try eq(abi.DB_WRITE, c.ANOLE_DB_WRITE);
    try eq(abi.DB_COALESCE, c.ANOLE_DB_COALESCE);
    try eq(abi.DB_NO_PREPARE, c.ANOLE_DB_NO_PREPARE);
    try eq(abi.DB_DROP_EMPTY, c.ANOLE_DB_DROP_EMPTY);
    try eq(abi.DB_FROM_DATABASE, c.ANOLE_DB_FROM_DATABASE);
    try eq(abi.DB_FROM_COALESCED, c.ANOLE_DB_FROM_COALESCED);
    try eq(abi.DB_FROM_CACHE, c.ANOLE_DB_FROM_CACHE);
    const classes = @typeInfo(abi.DbErrorClass).@"enum";
    inline for (classes.field_names, classes.field_values) |n, v| {
        const name = comptime blk: {
            var buf: [32]u8 = undefined;
            break :blk "ANOLE_DB_ERR_" ++ std.ascii.upperString(&buf, n);
        };
        try eq(v, @field(c, name));
    }
    try eq(abi.SERVER_SIGNALS, c.ANOLE_SERVER_SIGNALS);
    try eq(abi.LOG_ERROR, c.ANOLE_LOG_ERROR);
    try eq(abi.LOG_WARN, c.ANOLE_LOG_WARN);
    try eq(abi.LOG_INFO, c.ANOLE_LOG_INFO);
    try eq(abi.LOG_DEBUG, c.ANOLE_LOG_DEBUG);
    try eq(abi.CONSUMER_SHARED, c.ANOLE_CONSUMER_SHARED);
    try eq(abi.REQ_BODY_INLINE, c.ANOLE_REQ_BODY_INLINE);
    try eq(abi.REQ_BODY_STREAM, c.ANOLE_REQ_BODY_STREAM);
    try eq(abi.REQ_SECURE, c.ANOLE_REQ_SECURE);
    try eq(abi.REQ_EARLY_DATA, c.ANOLE_REQ_EARLY_DATA);
    try eq(abi.WS_TEXT, c.ANOLE_WS_TEXT);
    try eq(abi.WS_BINARY, c.ANOLE_WS_BINARY);
    try eq(abi.POLL_NOARM, c.ANOLE_POLL_NOARM);
    try eq(abi.BODY_BORROW, c.ANOLE_BODY_BORROW);
    const info = @typeInfo(abi.EventType).@"enum";
    inline for (info.field_names, info.field_values) |n, v| {
        const name = comptime blk: {
            var buf: [32]u8 = undefined;
            break :blk "ANOLE_EV_" ++ std.ascii.upperString(&buf, n);
        };
        try eq(v, @field(c, name));
    }
}
