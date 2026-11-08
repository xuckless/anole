// Tests translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// tests/nghttp2_frame_test.c and tests/nghttp2_session_test.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! Tests for frame.zig. The round trips use the values of nghttp2's
//! tests/nghttp2_frame_test.c (MIT, v1.70.0) pack_* tests; the rejections
//! follow nghttp2_session_mem_recv2's checks, one row each.

const std = @import("std");
const frame = @import("frame.zig");
const fuzz = @import("../fuzz.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Writes any parsed frame back (the fuzz target's and the round trips'
/// inverse of `parse`).
fn serialize(buf: []u8, p: frame.Parsed) usize {
    const sid = p.header.stream_id;
    return switch (p.frame) {
        .data => |d| blk: {
            var n = frame.writeData(buf, sid, d.end_stream, d.data.len, d.pad_len);
            @memcpy(buf[n..][0..d.data.len], d.data);
            n += d.data.len;
            const pad = d.pad_len orelse 0;
            @memcpy(buf[n..][0..pad], frame.padding[0..pad]);
            break :blk n + pad;
        },
        .headers => |h| frame.writeHeaders(buf, sid, h),
        .priority => |pr| frame.writePriority(buf, sid, pr),
        .rst_stream => |code| frame.writeRstStream(buf, sid, code),
        .settings => |s| blk: {
            var list: [64]frame.Setting = undefined;
            var it = s.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) list[i] = e;
            break :blk frame.writeSettings(buf, s.ack, list[0..i]);
        },
        .push_promise => |pp| frame.writePushPromise(buf, sid, pp),
        .ping => |pg| frame.writePing(buf, pg.ack, pg.data),
        .goaway => |g| frame.writeGoaway(buf, g.last_stream_id, g.code, g.debug),
        .window_update => |inc| frame.writeWindowUpdate(buf, sid, inc),
        .continuation => |c| frame.writeContinuation(buf, sid, c.end_headers, c.fragment),
        .unknown => |payload| blk: {
            var h = p.header;
            h.length = @intCast(payload.len);
            const n = frame.writeHeader(buf, h);
            @memcpy(buf[n..][0..payload.len], payload);
            break :blk n + payload.len;
        },
    };
}

fn parseOne(bytes: []const u8) !frame.Parsed {
    switch (frame.parse(bytes, .{})) {
        .frame => |f| {
            try expectEqual(bytes.len, f.len);
            return f.parsed;
        },
        .need => |n| {
            std.debug.print("need {d}\n", .{n});
            return error.TestUnexpectedResult;
        },
        .fault => |f| {
            std.debug.print("fault {t}: {s}\n", .{ f.code, f.reason });
            return error.TestUnexpectedResult;
        },
    }
}

/// Serializes `p`, checks the header it wrote, parses it back and expects
/// the same frame.
fn roundTrip(p: frame.Parsed, length: u24) !void {
    var buf: [1024]u8 = undefined;
    const n = serialize(&buf, p);
    try expectEqual(frame.header_len + @as(usize, length), n);
    const h = frame.FrameHeader.parse(buf[0..frame.header_len]);
    try expectEqualDeep(p.header, h);
    try expectEqualDeep(p, try parseOne(buf[0..n]));
}

fn hd(length: u24, t: frame.Type, f: u8, sid: u31) frame.FrameHeader {
    return .{ .length = length, .type = t, .flags = f, .stream_id = sid };
}

const F = frame.flags;

test "h2 frame: round trip DATA, with and without padding" {
    try roundTrip(.{ .header = hd(5, .data, F.end_stream, 1000000007), .frame = .{ .data = .{ .end_stream = true, .data = "hello" } } }, 5);
    try roundTrip(.{ .header = hd(5 + 1 + 3, .data, F.padded, 1), .frame = .{ .data = .{ .end_stream = false, .data = "hello", .pad_len = 3 } } }, 9);
    // All padding and no data is legal.
    try roundTrip(.{ .header = hd(1 + 255, .data, F.padded | F.end_stream, 3), .frame = .{ .data = .{ .end_stream = true, .data = "", .pad_len = 255 } } }, 256);
    try roundTrip(.{ .header = hd(0, .data, 0, 1), .frame = .{ .data = .{ .end_stream = false, .data = "" } } }, 0);
}

test "h2 frame: round trip HEADERS, with priority and padding" {
    const block = "\x82\x86\x84\x41\x8a\x08\x9d\x5c\x0b\x81\x70\xdc\x78\x0f\x03";
    try roundTrip(.{
        .header = hd(block.len, .headers, F.end_stream | F.end_headers, 1000000007),
        .frame = .{ .headers = .{ .end_stream = true, .end_headers = true, .fragment = block } },
    }, block.len);
    // nghttp2_frame_test.c: depends on 1000000009, weight 12, exclusive.
    const pri: frame.Priority = .{ .exclusive = true, .dependency = 1000000009, .weight = 11 };
    try roundTrip(.{
        .header = hd(block.len + 5, .headers, F.end_headers | F.priority, 1000000007),
        .frame = .{ .headers = .{ .end_stream = false, .end_headers = true, .priority = pri, .fragment = block } },
    }, block.len + 5);
    try roundTrip(.{
        .header = hd(block.len + 5 + 1 + 7, .headers, F.padded | F.priority, 1),
        .frame = .{ .headers = .{ .end_stream = false, .end_headers = false, .priority = pri, .fragment = block, .pad_len = 7 } },
    }, block.len + 13);
}

test "h2 frame: round trip PRIORITY, RST_STREAM, WINDOW_UPDATE" {
    try roundTrip(.{ .header = hd(5, .priority, 0, 1000000007), .frame = .{ .priority = .{ .exclusive = true, .dependency = 1000000009, .weight = 11 } } }, 5);
    try roundTrip(.{ .header = hd(4, .rst_stream, 0, 1000000007), .frame = .{ .rst_stream = .protocol_error } }, 4);
    // An error code we don't know is kept as is.
    try roundTrip(.{ .header = hd(4, .rst_stream, 0, 1000000007), .frame = .{ .rst_stream = @fromBackingInt(1000000009) } }, 4);
    try roundTrip(.{ .header = hd(4, .window_update, 0, 1000000007), .frame = .{ .window_update = 4096 } }, 4);
    try roundTrip(.{ .header = hd(4, .window_update, 0, 0), .frame = .{ .window_update = frame.max_window_size } }, 4);
}

test "h2 frame: round trip SETTINGS" {
    const iv = [_]frame.Setting{
        .{ .id = .max_concurrent_streams, .value = 256 },
        .{ .id = .initial_window_size, .value = 16384 },
        .{ .id = .header_table_size, .value = 4096 },
    };
    var buf: [64]u8 = undefined;
    const n = frame.writeSettings(&buf, false, &iv);
    try expectEqual(frame.header_len + 3 * 6, n);
    const p = try parseOne(buf[0..n]);
    try expectEqualDeep(hd(18, .settings, 0, 0), p.header);
    try expect(!p.frame.settings.ack);
    var it = p.frame.settings.iterator();
    for (iv) |want| try expectEqualDeep(want, it.next().?);
    try expect(it.next() == null);
    try roundTrip(p, 18);
    // The ACK, empty.
    try roundTrip(.{ .header = hd(0, .settings, F.ack, 0), .frame = .{ .settings = .{ .ack = true, .payload = "" } } }, 0);
}

test "h2 frame: round trip PUSH_PROMISE" {
    const block = "\x82\x86";
    try roundTrip(.{
        .header = hd(4 + block.len, .push_promise, F.end_headers, 1000000007),
        .frame = .{ .push_promise = .{ .end_headers = true, .promised_id = (1 << 31) - 1, .fragment = block } },
    }, 4 + block.len);
    try roundTrip(.{
        .header = hd(1 + 4 + block.len + 2, .push_promise, F.padded, 3),
        .frame = .{ .push_promise = .{ .end_headers = false, .promised_id = 2, .fragment = block, .pad_len = 2 } },
    }, 1 + 4 + block.len + 2);
}

test "h2 frame: round trip PING, GOAWAY, CONTINUATION, unknown" {
    try roundTrip(.{ .header = hd(8, .ping, F.ack, 0), .frame = .{ .ping = .{ .ack = true, .data = "01234567".* } } }, 8);
    try roundTrip(.{ .header = hd(8, .ping, 0, 0), .frame = .{ .ping = .{ .ack = false, .data = "\x00\xff\x00\xff\x00\xff\x00\xff".* } } }, 8);
    try roundTrip(.{ .header = hd(8 + 16, .goaway, 0, 0), .frame = .{ .goaway = .{ .last_stream_id = 1000000007, .code = .protocol_error, .debug = "0123456789abcdef" } } }, 24);
    try roundTrip(.{ .header = hd(8, .goaway, 0, 0), .frame = .{ .goaway = .{ .last_stream_id = 0, .code = @fromBackingInt(1000000009), .debug = "" } } }, 8);
    try roundTrip(.{ .header = hd(3, .continuation, F.end_headers, 5), .frame = .{ .continuation = .{ .end_headers = true, .fragment = "abc" } } }, 3);
    try roundTrip(.{ .header = hd(0, .continuation, 0, 5), .frame = .{ .continuation = .{ .end_headers = false, .fragment = "" } } }, 0);
    // An unknown type keeps its flags (ALTSVC's type, which Anole doesn't enable).
    try roundTrip(.{ .header = hd(4, @fromBackingInt(0x0a), 0xff, 0), .frame = .{ .unknown = "abcd" } }, 4);
    try roundTrip(.{ .header = hd(0, @fromBackingInt(0xff), 0x3, 7), .frame = .{ .unknown = "" } }, 0);
}

/// A frame header with any length and a payload (which may be shorter:
/// checks the header alone decides answer before the payload is in).
inline fn raw(comptime length: u24, comptime t: u8, comptime f: u8, comptime sid: u32, comptime payload: []const u8) []const u8 {
    comptime {
        var h: [9]u8 = undefined;
        std.mem.writeInt(u24, h[0..3], length, .big);
        h[3] = t;
        h[4] = f;
        std.mem.writeInt(u32, h[5..9], sid, .big);
        const out = h ++ payload[0..payload.len].*;
        return &out;
    }
}

fn entry(comptime id: u16, comptime v: u32) [6]u8 {
    var e: [6]u8 = undefined;
    std.mem.writeInt(u16, e[0..2], id, .big);
    std.mem.writeInt(u32, e[2..6], v, .big);
    return e;
}

/// 32 MAX_CONCURRENT_STREAMS entries.
const entries32 = blk: {
    var out: [32 * 6]u8 = undefined;
    for (0..32) |i| out[i * 6 ..][0..6].* = entry(3, 100);
    break :blk out;
};

const Row = struct {
    name: []const u8,
    bytes: []const u8,
    code: frame.ErrorCode,
    reason: []const u8,
};

const T = struct {
    const data = 0;
    const headers = 1;
    const priority = 2;
    const rst = 3;
    const settings = 4;
    const push = 5;
    const ping = 6;
    const goaway = 7;
    const wu = 8;
    const cont = 9;
};

/// One row per check, in nghttp2's order; every fault is a connection error.
const rejects = [_]Row{
    // The size comes first, before anything about the type.
    .{ .name = "17 KiB DATA on stream 0", .bytes = raw(17 * 1024, T.data, 0, 0, ""), .code = .frame_size_error, .reason = "too large frame size" },
    .{ .name = "17 KiB PING", .bytes = raw(17 * 1024, T.ping, 0, 0, ""), .code = .frame_size_error, .reason = "too large frame size" },
    .{ .name = "DATA on stream 0", .bytes = raw(0, T.data, 0, 0, ""), .code = .protocol_error, .reason = "DATA: stream_id == 0" },
    .{ .name = "DATA on stream 0 with bad padding", .bytes = raw(0, T.data, F.padded, 0, ""), .code = .protocol_error, .reason = "DATA: stream_id == 0" },
    .{ .name = "padded DATA, no room", .bytes = raw(0, T.data, F.padded, 1, ""), .code = .protocol_error, .reason = "DATA: insufficient padding space" },
    .{ .name = "DATA padding past the payload", .bytes = raw(3, T.data, F.padded, 1, "\x03ab"), .code = .protocol_error, .reason = "DATA: invalid padding" },
    .{ .name = "padded HEADERS, no room", .bytes = raw(0, T.headers, F.padded, 1, ""), .code = .protocol_error, .reason = "HEADERS: insufficient padding space" },
    .{ .name = "HEADERS padding past the payload", .bytes = raw(2, T.headers, F.padded, 1, "\x02a"), .code = .protocol_error, .reason = "HEADERS: invalid padding" },
    .{ .name = "HEADERS padding over the priority fields", .bytes = raw(5, T.headers, F.padded | F.priority, 1, "\x00abcd"), .code = .protocol_error, .reason = "HEADERS: invalid padding" },
    .{ .name = "HEADERS too short for priority", .bytes = raw(4, T.headers, F.priority, 1, ""), .code = .frame_size_error, .reason = "HEADERS: too short for the priority fields" },
    .{ .name = "HEADERS on stream 0", .bytes = raw(1, T.headers, F.end_headers, 0, "\x82"), .code = .protocol_error, .reason = "HEADERS: stream_id == 0" },
    .{ .name = "HEADERS on stream 0 with bad padding", .bytes = raw(1, T.headers, F.padded, 0, "\x01"), .code = .protocol_error, .reason = "HEADERS: invalid padding" },
    .{ .name = "PRIORITY of 4 bytes", .bytes = raw(4, T.priority, 0, 1, ""), .code = .frame_size_error, .reason = "PRIORITY: length != 5" },
    .{ .name = "PRIORITY of 6 bytes", .bytes = raw(6, T.priority, 0, 1, ""), .code = .frame_size_error, .reason = "PRIORITY: length != 5" },
    .{ .name = "PRIORITY on stream 0", .bytes = raw(5, T.priority, 0, 0, "\x00\x00\x00\x01\x10"), .code = .protocol_error, .reason = "PRIORITY: stream_id == 0" },
    .{ .name = "RST_STREAM of 3 bytes", .bytes = raw(3, T.rst, 0, 1, ""), .code = .frame_size_error, .reason = "RST_STREAM: length != 4" },
    .{ .name = "RST_STREAM on stream 0", .bytes = raw(4, T.rst, 0, 0, "\x00\x00\x00\x08"), .code = .protocol_error, .reason = "RST_STREAM: stream_id == 0" },
    .{ .name = "SETTINGS of 5 bytes", .bytes = raw(5, T.settings, 0, 0, ""), .code = .frame_size_error, .reason = "SETTINGS: invalid length" },
    .{ .name = "SETTINGS ACK with an entry", .bytes = raw(6, T.settings, F.ack, 0, ""), .code = .frame_size_error, .reason = "SETTINGS: invalid length" },
    .{ .name = "SETTINGS with 33 entries", .bytes = raw(33 * 6, T.settings, 0, 0, ""), .code = .enhance_your_calm, .reason = "SETTINGS: too many setting entries" },
    .{ .name = "SETTINGS on stream 1", .bytes = raw(0, T.settings, 0, 1, ""), .code = .protocol_error, .reason = "SETTINGS: stream_id != 0" },
    .{ .name = "SETTINGS ENABLE_PUSH 2", .bytes = raw(6, T.settings, 0, 0, &entry(2, 2)), .code = .protocol_error, .reason = "SETTINGS: invalid SETTINGS_ENABLE_PUSH" },
    .{ .name = "SETTINGS INITIAL_WINDOW_SIZE 2^31", .bytes = raw(6, T.settings, 0, 0, &entry(4, 1 << 31)), .code = .flow_control_error, .reason = "SETTINGS: too large SETTINGS_INITIAL_WINDOW_SIZE" },
    .{ .name = "SETTINGS MAX_FRAME_SIZE 16383", .bytes = raw(6, T.settings, 0, 0, &entry(5, 16383)), .code = .protocol_error, .reason = "SETTINGS: invalid SETTINGS_MAX_FRAME_SIZE" },
    .{ .name = "SETTINGS MAX_FRAME_SIZE 2^24", .bytes = raw(6, T.settings, 0, 0, &entry(5, 1 << 24)), .code = .protocol_error, .reason = "SETTINGS: invalid SETTINGS_MAX_FRAME_SIZE" },
    .{ .name = "SETTINGS ENABLE_CONNECT_PROTOCOL 2", .bytes = raw(6, T.settings, 0, 0, &entry(8, 2)), .code = .protocol_error, .reason = "SETTINGS: invalid SETTINGS_ENABLE_CONNECT_PROTOCOL" },
    .{ .name = "SETTINGS NO_RFC7540_PRIORITIES 2", .bytes = raw(6, T.settings, 0, 0, &entry(9, 2)), .code = .protocol_error, .reason = "SETTINGS: invalid SETTINGS_NO_RFC7540_PRIORITIES" },
    .{ .name = "SETTINGS, a bad entry after good ones", .bytes = raw(18, T.settings, 0, 0, &(entry(1, 0) ++ entry(1000, 7) ++ entry(4, 0xffff_ffff))), .code = .flow_control_error, .reason = "SETTINGS: too large SETTINGS_INITIAL_WINDOW_SIZE" },
    .{ .name = "padded PUSH_PROMISE, no room", .bytes = raw(0, T.push, F.padded, 1, ""), .code = .protocol_error, .reason = "PUSH_PROMISE: insufficient padding space" },
    .{ .name = "PUSH_PROMISE of 3 bytes", .bytes = raw(3, T.push, 0, 1, ""), .code = .frame_size_error, .reason = "PUSH_PROMISE: length < 4" },
    .{ .name = "PUSH_PROMISE padding over the promised id", .bytes = raw(5, T.push, F.padded, 1, "\x01\x00\x00\x00\x02"), .code = .protocol_error, .reason = "PUSH_PROMISE: invalid padding" },
    .{ .name = "PUSH_PROMISE on stream 0", .bytes = raw(4, T.push, 0, 0, "\x00\x00\x00\x02"), .code = .protocol_error, .reason = "PUSH_PROMISE: stream_id == 0" },
    .{ .name = "PING of 7 bytes", .bytes = raw(7, T.ping, 0, 0, ""), .code = .frame_size_error, .reason = "PING: length != 8" },
    .{ .name = "PING on stream 1", .bytes = raw(8, T.ping, 0, 1, "01234567"), .code = .protocol_error, .reason = "PING: stream_id != 0" },
    .{ .name = "GOAWAY of 7 bytes", .bytes = raw(7, T.goaway, 0, 0, ""), .code = .frame_size_error, .reason = "GOAWAY: length < 8" },
    .{ .name = "GOAWAY on stream 1", .bytes = raw(8, T.goaway, 0, 1, "\x00\x00\x00\x00\x00\x00\x00\x00"), .code = .protocol_error, .reason = "GOAWAY: stream_id != 0" },
    .{ .name = "WINDOW_UPDATE of 5 bytes", .bytes = raw(5, T.wu, 0, 1, ""), .code = .frame_size_error, .reason = "WINDOW_UPDATE: length != 4" },
    .{ .name = "WINDOW_UPDATE 0 on the connection", .bytes = raw(4, T.wu, 0, 0, "\x00\x00\x00\x00"), .code = .protocol_error, .reason = "WINDOW_UPDATE: window_size_increment == 0" },
    .{ .name = "WINDOW_UPDATE 0 with the R bit on the connection", .bytes = raw(4, T.wu, 0, 0, "\x80\x00\x00\x00"), .code = .protocol_error, .reason = "WINDOW_UPDATE: window_size_increment == 0" },
    .{ .name = "CONTINUATION on stream 0", .bytes = raw(0, T.cont, 0, 0, ""), .code = .protocol_error, .reason = "CONTINUATION: stream_id == 0" },
};

test "h2 frame: rejects each violation with nghttp2's code" {
    for (rejects) |row| {
        errdefer std.debug.print("row: {s}\n", .{row.name});
        switch (frame.parse(row.bytes, .{})) {
            .fault => |f| {
                try expectEqual(row.code, f.code);
                try expectEqual(frame.Scope.connection, f.scope);
                try expectEqualStrings(row.reason, f.reason);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "h2 frame: settings values" {
    // test_nghttp2_iv_check.
    const ok = [_]frame.Setting{
        .{ .id = .max_concurrent_streams, .value = 100 },
        .{ .id = .header_table_size, .value = 1024 },
        .{ .id = .initial_window_size, .value = frame.max_window_size },
        .{ .id = .enable_push, .value = 0 },
        .{ .id = .enable_push, .value = 1 },
        .{ .id = @fromBackingInt(10000), .value = 0 },
        .{ .id = @fromBackingInt(0), .value = 0xffff_ffff },
        .{ .id = .header_table_size, .value = 0xffff_ffff },
        .{ .id = .max_header_list_size, .value = 0xffff_ffff },
        .{ .id = .max_frame_size, .value = frame.min_max_frame_size },
        .{ .id = .max_frame_size, .value = frame.max_max_frame_size },
        .{ .id = .enable_connect_protocol, .value = 1 },
        .{ .id = .no_rfc7540_priorities, .value = 1 },
    };
    for (ok) |s| try expect(frame.validateSetting(s) == null);
    const bad = [_]frame.Setting{
        .{ .id = .initial_window_size, .value = frame.max_window_size + 1 },
        .{ .id = .enable_push, .value = 3 },
        .{ .id = .max_frame_size, .value = frame.min_max_frame_size - 1 },
        .{ .id = .max_frame_size, .value = frame.max_max_frame_size + 1 },
        .{ .id = .enable_connect_protocol, .value = 2 },
        .{ .id = .no_rfc7540_priorities, .value = 2 },
    };
    for (bad) |s| try expect(frame.validateSetting(s) != null);
    // nghttp2 accepts the undefined id 1000000009 (a u32 there); on the
    // wire an id is 16 bits, so its low half stands in.
    try expect(frame.validateSetting(.{ .id = @fromBackingInt(@as(u16, @truncate(1000000009))), .value = 0 }) == null);
    // And 32 entries is the limit, not over it.
    const many = raw(32 * 6, T.settings, 0, 0, &entries32);
    const p = try parseOne(many);
    var it = p.frame.settings.iterator();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try expectEqual(32, n);
    // A lower limit is the caller's.
    try expectEqual(frame.ErrorCode.enhance_your_calm, frame.parse(many, .{ .max_settings = 31 }).fault.code);
}

test "h2 frame: R bit ignored" {
    const sid_r = 0x8000_0001;
    try expectEqual(1, (try parseOne(raw(1, T.data, 0, sid_r, "x"))).header.stream_id);
    try expectEqual(1, (try parseOne(raw(4, T.wu, 0, 3, "\x80\x00\x00\x01"))).frame.window_update);
    const g = (try parseOne(raw(8, T.goaway, 0, 0, "\xff\xff\xff\xff\x00\x00\x00\x00"))).frame.goaway;
    try expectEqual((1 << 31) - 1, g.last_stream_id);
    const pr = (try parseOne(raw(5, T.priority, 0, 1, "\xff\xff\xff\xff\x10"))).frame.priority;
    try expect(pr.exclusive);
    try expectEqual((1 << 31) - 1, pr.dependency);
    try expectEqual(0x10, pr.weight);
    const pp = (try parseOne(raw(4, T.push, 0, 1, "\x80\x00\x00\x02"))).frame.push_promise;
    try expectEqual(2, pp.promised_id);
    // Written as 0.
    var buf: [9]u8 = undefined;
    frame.FrameHeader.write(hd(0, .data, 0, (1 << 31) - 1), &buf);
    try expectEqual(0x7f, buf[5]);
}

test "h2 frame: undefined flags masked" {
    const all = 0xff;
    try expectEqual(F.end_stream | F.padded, (try parseOne(raw(1, T.data, all, 1, "\x00"))).header.flags);
    try expectEqual(F.end_stream | F.end_headers | F.padded | F.priority, (try parseOne(raw(6, T.headers, all, 1, "\x00\x00\x00\x00\x03\x10"))).header.flags);
    try expectEqual(0, (try parseOne(raw(5, T.priority, all, 1, "\x00\x00\x00\x03\x10"))).header.flags);
    try expectEqual(0, (try parseOne(raw(4, T.rst, all, 1, "\x00\x00\x00\x08"))).header.flags);
    try expectEqual(F.ack, (try parseOne(raw(0, T.settings, all, 0, ""))).header.flags);
    try expectEqual(F.end_headers | F.padded, (try parseOne(raw(5, T.push, all, 1, "\x00\x00\x00\x00\x02"))).header.flags);
    try expectEqual(F.ack, (try parseOne(raw(8, T.ping, all, 0, "01234567"))).header.flags);
    try expectEqual(0, (try parseOne(raw(8, T.goaway, all, 0, "\x00\x00\x00\x00\x00\x00\x00\x00"))).header.flags);
    try expectEqual(0, (try parseOne(raw(4, T.wu, all, 1, "\x00\x00\x00\x01"))).header.flags);
    try expectEqual(F.end_headers, (try parseOne(raw(0, T.cont, all, 1, ""))).header.flags);
    // A bit a type doesn't define changes nothing: PRIORITY's 0x20 on DATA.
    const d = (try parseOne(raw(2, T.data, F.priority, 1, "ab"))).frame.data;
    try expectEqualStrings("ab", d.data);
    try expect(d.pad_len == null);
}

test "h2 frame: need returns the exact byte counts" {
    const ping = raw(8, T.ping, 0, 0, "01234567");
    for (0..ping.len) |n| {
        const want = if (n < frame.header_len) frame.header_len - n else ping.len - n;
        try expectEqual(want, frame.parse(ping[0..n], .{}).need);
    }
    // A frame and the start of the next: only the first.
    const two = ping ++ ping[0..4];
    const r = frame.parse(two, .{}).frame;
    try expectEqual(ping.len, r.len);
    try expectEqual(5, frame.parse(two[r.len..], .{}).need);
}

test "h2 frame: parseHead takes a DATA head before its payload" {
    // A max-size DATA frame split by a read: the head alone is checked and
    // handed out (flags masked), so the payload can be taken as it arrives.
    const split = raw(16384, T.data, F.padded | F.end_stream | 0x40, 1, "\x03abc");
    const h = frame.parseHead(split, .{}).head;
    try expectEqual(16384, h.length);
    try expectEqual(frame.Type.data, h.type);
    try expectEqual(F.padded | F.end_stream, h.flags);
    try expectEqual(1, h.stream_id);
    try expectEqual(16384 + frame.header_len - split.len, frame.parse(split, .{}).need);
    // The header-stage faults are the same as parse's.
    try expectEqual(3, frame.parseHead(split[0..6], .{}).need);
    const zero = raw(5, T.data, 0, 0, "");
    try expectEqualDeep(frame.parse(zero, .{}).fault, frame.parseHead(zero, .{}).fault);
    const big = raw(16385, T.data, 0, 1, "");
    try expectEqual(frame.ErrorCode.frame_size_error, frame.parseHead(big, .{}).fault.code);
}

test "h2 frame: a larger max_frame_size is the caller's" {
    const big = raw(17 * 1024, T.data, 0, 1, "");
    try expectEqual(17 * 1024, frame.parse(big, .{ .max_frame_size = frame.max_max_frame_size }).need);
}

test "h2 frame: PRIORITY self-dependency is exposed" {
    // Its scope (idle stream: connection; else RST_STREAM) is the
    // connection's, so it parses.
    const p = try parseOne(raw(5, T.priority, 0, 3, "\x00\x00\x00\x03\x10"));
    try expectEqual(p.header.stream_id, p.frame.priority.dependency);
    const h = try parseOne(raw(6, T.headers, F.priority, 3, "\x00\x00\x00\x03\x10\x82"));
    try expectEqual(3, h.frame.headers.priority.?.dependency);
    try expectEqualStrings("\x82", h.frame.headers.fragment);
}

test "h2 frame: WINDOW_UPDATE 0 on a stream is the connection's to judge" {
    try expectEqual(0, (try parseOne(raw(4, T.wu, 0, 1, "\x00\x00\x00\x00"))).frame.window_update);
}

test "h2 frame: payload slices point into the input" {
    const bytes = raw(9, T.data, F.padded, 1, "\x02abcdef\x00\x00");
    const d = (try parseOne(bytes)).frame.data;
    try expectEqualStrings("abcdef", d.data);
    try expectEqual(@as([*]const u8, bytes.ptr + 10), d.data.ptr);
}

fn within(input: []const u8, s: []const u8) bool {
    if (s.len == 0) return true;
    const lo = @intFromPtr(input.ptr);
    const p = @intFromPtr(s.ptr);
    return p >= lo and p + s.len <= lo + input.len;
}

fn slices(fr: frame.Frame) []const u8 {
    return switch (fr) {
        .data => |d| d.data,
        .headers => |h| h.fragment,
        .settings => |s| s.payload,
        .push_promise => |pp| pp.fragment,
        .goaway => |g| g.debug,
        .continuation => |c| c.fragment,
        .unknown => |u| u,
        .priority, .rst_stream, .ping, .window_update => "",
    };
}

test "fuzz: h2 frame parse" {
    var seeds: [rejects.len + 12][]const u8 = undefined;
    for (rejects, 0..) |row, i| seeds[i] = row.bytes;
    const valid = [_][]const u8{
        raw(6, T.data, F.padded | F.end_stream, 1, "\x02abc\x00\x00"),
        raw(11, T.headers, F.padded | F.priority | F.end_headers, 1, "\x02\x80\x00\x00\x03\x10\x82\x86\x84\x00\x00"),
        raw(5, T.priority, 0, 1, "\x00\x00\x00\x03\x10"),
        raw(4, T.rst, 0, 1, "\x00\x00\x00\x08"),
        raw(12, T.settings, 0, 0, &(entry(4, 65535) ++ entry(8, 1))),
        raw(0, T.settings, F.ack, 0, ""),
        raw(6, T.push, F.end_headers, 1, "\x00\x00\x00\x02\x82\x86"),
        raw(8, T.ping, 0, 0, "01234567"),
        raw(10, T.goaway, 0, 0, "\x00\x00\x00\x07\x00\x00\x00\x0bhi"),
        raw(4, T.wu, 0, 0, "\x00\x00\xff\xff"),
        raw(2, T.cont, F.end_headers, 1, "\x82\x86"),
        raw(3, 0x10, 0x5a, 9, "xyz") ++ raw(8, T.ping, F.ack, 0, "abcdefgh"),
    };
    for (valid, rejects.len..) |v, i| seeds[i] = v;
    try fuzz.bytes(struct {
        fn check(input: []const u8) anyerror!void {
            var rest = input;
            while (true) switch (frame.parse(rest, .{})) {
                .need => |n| {
                    if (n == 0) return error.NeedZero;
                    return;
                },
                .fault => return,
                .frame => |f| {
                    if (f.len < frame.header_len or f.len > rest.len) return error.BadLen;
                    if (!within(rest[0..f.len], slices(f.parsed.frame))) return error.SliceOutside;
                    var buf: [fuzz.max_len + 64]u8 = undefined;
                    const n = serialize(&buf, f.parsed);
                    if (n != f.len) return error.SerializedLen;
                    switch (frame.parse(buf[0..n], .{})) {
                        .frame => |g| {
                            if (g.len != n) return error.ReparsedLen;
                            try expectEqualDeep(f.parsed, g.parsed);
                        },
                        else => return error.ReparseFailed,
                    }
                    rest = rest[f.len..];
                },
            };
        }
    }.check, &seeds);
}
