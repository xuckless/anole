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
    try expectSameLayout(abi.GrpcCallEvent, c.anole_grpc_call_event);
    try expectSameLayout(abi.GrpcMessageEvent, c.anole_grpc_message_event);
    try expectSameLayout(abi.DbValue, c.anole_db_value);
    try expectSameLayout(abi.DbOptions, c.anole_db_options);
    try expectSameLayout(abi.DbResultEvent, c.anole_db_result_event);
    try expectSameLayout(abi.DbCell, c.anole_db_cell);
    try expectSameLayout(abi.WtStreamEvent, c.anole_wt_stream_event);
    try expectSameLayout(abi.WtDataEvent, c.anole_wt_data_event);
    try expectSameLayout(abi.WtCodeEvent, c.anole_wt_code_event);
    try expectSameLayout(abi.WtDatagramEvent, c.anole_wt_datagram_event);
    try expectSameLayout(abi.WtCloseEvent, c.anole_wt_close_event);
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
    try eq(abi.DB_BOOL, c.ANOLE_DB_BOOL);
    try eq(abi.DB_ARRAY, c.ANOLE_DB_ARRAY);
    try eq(abi.DB_MAP, c.ANOLE_DB_MAP);
    try eq(abi.DB_ERROR, c.ANOLE_DB_ERROR);
    try eq(abi.DB_BSON, c.ANOLE_DB_BSON);
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
            @setEvalBranchQuota(10_000);
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
    try eq(abi.GRPC_UNARY, c.ANOLE_GRPC_UNARY);
    try eq(abi.GRPC_SERVER_STREAMING, c.ANOLE_GRPC_SERVER_STREAMING);
    try eq(abi.GRPC_CLIENT_STREAMING, c.ANOLE_GRPC_CLIENT_STREAMING);
    try eq(abi.GRPC_BIDI_STREAMING, c.ANOLE_GRPC_BIDI_STREAMING);
    try eq(abi.GRPC_PROTOCOL_GRPC, c.ANOLE_GRPC_PROTOCOL_GRPC);
    try eq(abi.GRPC_PROTOCOL_GRPC_WEB, c.ANOLE_GRPC_PROTOCOL_GRPC_WEB);
    try eq(abi.GRPC_PROTOCOL_GRPC_WEB_TEXT, c.ANOLE_GRPC_PROTOCOL_GRPC_WEB_TEXT);
    try eq(abi.GRPC_PROTOCOL_CONNECT, c.ANOLE_GRPC_PROTOCOL_CONNECT);
    try eq(abi.GRPC_PROTOCOL_CONNECT_STREAM, c.ANOLE_GRPC_PROTOCOL_CONNECT_STREAM);
    try eq(abi.GRPC_PROTOCOL_HTTP_JSON, c.ANOLE_GRPC_PROTOCOL_HTTP_JSON);
    try eq(abi.GRPC_CALL_MESSAGE, c.ANOLE_GRPC_CALL_MESSAGE);
    try eq(abi.GRPC_CALL_SECURE, c.ANOLE_GRPC_CALL_SECURE);
    try eq(abi.GRPC_CALL_EARLY_DATA, c.ANOLE_GRPC_CALL_EARLY_DATA);
    try eq(abi.GRPC_CALL_JSON, c.ANOLE_GRPC_CALL_JSON);
    try eq(abi.GRPC_CALL_COMPRESSED, c.ANOLE_GRPC_CALL_COMPRESSED);
    try eq(abi.GRPC_SEND_FINISH, c.ANOLE_GRPC_SEND_FINISH);
    try eq(abi.GRPC_HEALTH_UNKNOWN, c.ANOLE_GRPC_HEALTH_UNKNOWN);
    try eq(abi.GRPC_HEALTH_SERVING, c.ANOLE_GRPC_HEALTH_SERVING);
    try eq(abi.GRPC_HEALTH_NOT_SERVING, c.ANOLE_GRPC_HEALTH_NOT_SERVING);
    try eq(abi.WT_UNI, c.ANOLE_WT_UNI);
    try eq(abi.WT_FIN, c.ANOLE_WT_FIN);
    try eq(abi.WT_CLOSED_LOCAL, c.ANOLE_WT_CLOSED_LOCAL);
    try eq(abi.WT_CLOSED_PEER, c.ANOLE_WT_CLOSED_PEER);
    try eq(abi.WT_CLOSED_CONNECTION, c.ANOLE_WT_CLOSED_CONNECTION);
    const info = @typeInfo(abi.EventType).@"enum";
    inline for (info.field_names, info.field_values) |n, v| {
        const name = comptime blk: {
            var buf: [32]u8 = undefined;
            break :blk "ANOLE_EV_" ++ std.ascii.upperString(&buf, n);
        };
        try eq(v, @field(c, name));
    }
}
