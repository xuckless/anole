//! PLAN §5.4's limits as conn.zig charges them (research/s2/h2-m2/connlimits.md):
//! one named test per row, on conn_test.zig's harness. Budgets are set small
//! through Options and time moves only through `T.now`.

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const conn = @import("conn.zig");
const ct = @import("conn_test.zig");
const Buf = @import("hpack_vectors.zig").Buf;

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const ErrorCode = frame.ErrorCode;
const Field = hpack.Field;
const F = frame.flags;
const T = ct.T;
const OutFrame = ct.OutFrame;
const expectFrames = ct.expectFrames;
const goawayWith = ct.goawayWith;
const rstWith = ct.rstWith;
const ready = ct.ready;
const get = ct.get;
const post = ct.post;
const postLen = ct.postLen;

fn count(out: []const OutFrame, ty: frame.Type) usize {
    var n: usize = 0;
    for (out) |o| {
        if (o.type == ty) n += 1;
    }
    return n;
}

fn find(out: []const OutFrame, ty: frame.Type, id: u31) ?OutFrame {
    for (out) |o| {
        if (o.type == ty and o.id == id) return o;
    }
    return null;
}

/// A POST head built by hand (the harness's encoder starts with a size
/// update to 0, which would empty the table these tests fill), then `extra`.
fn head(t: *T, extra: []const u8) ![]const u8 {
    var b: Buf = .init(t.arena());
    try b.indexed(3); // :method POST
    try b.indexed(7); // :scheme https
    try b.indexed(4); // :path /
    try b.literal(.without, 1, "", "example.org"); // :authority
    try b.bytes(extra);
    return b.take();
}

fn headFrame(t: *T, id: u31, block: []const u8, end_stream: bool) ![]const u8 {
    return t.headersFrame(id, .{ .end_stream = end_stream, .end_headers = true, .fragment = block });
}

/// DATA on a stream the peer reset: our RST_STREAM(STREAM_CLOSED), the
/// PLAN §5.2 behaviour 1, a provoked reset.
fn provoke(t: *T, id: u31) !void {
    try t.feed(try t.headers(id, &post, false));
    try t.feed(try t.rst(id, .cancel));
    try t.feed(try t.data(id, "x", false));
}

// ---------------------------------------------------------------------------

test "h2 limits: rapid reset closes the connection" {
    {
        const t = try ready(.{ .stream_reset_burst = 5, .stream_reset_rate = 1 });
        defer t.destroy();
        var id: u31 = 1;
        while (id < 11) : (id += 2) {
            try t.feed(try t.headers(id, &post, false));
            try t.feed(try t.rst(id, .cancel));
        }
        try expectFrames(try t.drain(), &.{});
        // A second later one more token; then the bucket is empty.
        t.now += 1;
        try t.feed(try t.headers(11, &post, false));
        try t.feed(try t.rst(11, .cancel));
        try t.feed(try t.headers(13, &post, false));
        try expectError(error.ConnectionError, t.feed(try t.rst(13, .cancel)));
        const out = try t.drain();
        try expectFrames(out, &.{goawayWith(.enhance_your_calm)});
        try expectEqual(13, out[0].last_id);
        // Nothing more is read.
        try expectError(error.ConnectionError, t.feed(try t.headers(15, &get, true)));
        try expectEqual(7, t.rec.count(.open));
    }
    {
        // D15 point 1: streams we answered (END_STREAM queued), then reset
        // by the peer, are ordinary traffic and never charged.
        const t = try ready(.{ .stream_reset_burst = 1, .stream_reset_rate = 1 });
        defer t.destroy();
        t.rec.answer = true;
        var id: u31 = 1;
        while (id < 21) : (id += 2) {
            try t.feed(try t.headers(id, &get, true));
            try expect(t.stream(id).flags.answered);
            try t.feed(try t.rst(id, .cancel));
        }
        const out = try t.drain();
        try expectEqual(0, count(out, .goaway));
        try expectEqual(10, count(out, .headers));
        // A reset of a stream no longer open costs nothing either.
        try t.feed(try t.rst(1, .cancel));
        try t.feed(try t.rst(1, .cancel));
        try expectFrames(try t.drain(), &.{});
    }
}

test "h2 limits: provoked resets count toward the reset budget" {
    {
        const t = try ready(.{ .stream_reset_burst = 4, .stream_reset_rate = 1 });
        defer t.destroy();
        // The peer's RST (1), our STREAM_CLOSED answer (2).
        try provoke(t, 1);
        // A stream window overflow (3).
        try t.feed(try t.headers(3, &post, false));
        try t.feed(try t.windowUpdate(3, frame.max_window_size - 65535));
        try t.feed(try t.windowUpdate(3, 1));
        // DATA past the content-length (4).
        try t.feed(try t.headers(5, &postLen("1"), false));
        try t.feed(try t.data(5, "ab", false));
        try expectFrames(try t.drain(), &.{ rstWith(1, .stream_closed), rstWith(3, .flow_control_error), rstWith(5, .protocol_error) });
        // Answered or not, the fifth closes the connection.
        try t.feed(try t.headers(7, &postLen("1"), false));
        try t.c.submitHead(t.stream(7), 200, &.{}, true);
        try expect(t.stream(7).flags.answered);
        _ = try t.drain();
        try expectError(error.ConnectionError, t.feed(try t.data(7, "ab", true)));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    {
        // Resets the handler asks for, or causes by failing, aren't the
        // peer's doing.
        const t = try ready(.{ .stream_reset_burst = 1, .stream_reset_rate = 1 });
        defer t.destroy();
        var id: u31 = 1;
        while (id < 7) : (id += 2) {
            try t.feed(try t.headers(id, &post, false));
            try t.c.reset(t.stream(id), .cancel);
        }
        t.rec.fail_open = true;
        while (id < 13) : (id += 2) try t.feed(try t.headers(id, &post, false));
        const out = try t.drain();
        try expectEqual(6, count(out, .rst_stream));
        try expectEqual(0, count(out, .goaway));
    }
}

test "h2 limits: CONTINUATION flood" {
    // HEADERS plus `max_continuations` (8) CONTINUATIONs is a request.
    {
        const t = try ready(.{});
        defer t.destroy();
        const blk = try t.block(&get);
        try expect(blk.len > 10);
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..1] }));
        for (1..8) |i| try t.feed(try t.continuation(1, false, blk[i..][0..1]));
        try t.feed(try t.continuation(1, true, blk[8..]));
        try expectEqual(1, t.rec.count(.end));
        try expectFrames(try t.drain(), &.{});
    }
    // The ninth ends the connection before anything is decoded
    // (CVE-2024-27316).
    {
        const t = try ready(.{});
        defer t.destroy();
        const blk = try t.block(&get);
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..1] }));
        for (1..9) |i| try t.feed(try t.continuation(1, false, blk[i..][0..1]));
        try expectError(error.ConnectionError, t.feed(try t.continuation(1, true, blk[9..])));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
        try expectEqual(0, t.rec.count(.field));
    }
    // A block over max_header_list_size bytes on the wire, before any
    // decoding: the assembly buffer never grows past it, and is freed
    // (testing.allocator's leak check).
    {
        const t = try ready(.{ .max_header_list_size = 1024 });
        defer t.destroy();
        const junk: [600]u8 = @splat('~');
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = &junk }));
        try t.feed(try t.continuation(1, false, junk[0..424]));
        try expectError(error.ConnectionError, t.feed(try t.continuation(1, false, junk[0..1])));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
        try expect(t.c.block.?.buf.items.len <= 1024);
        try expectEqual(0, t.rec.count(.field));
    }
}

test "h2 limits: HPACK bomb through a connection" {
    const t = try ready(.{ .max_header_list_size = 16384 });
    defer t.destroy();
    const z: [3999]u8 = @splat('z');
    // One 4032-byte entry, then references to it: the list passes 16384 at
    // the fifth "b" field, from a block of about 4 KB.
    var b: Buf = .init(t.arena());
    try b.literal(.with, 0, "b", &z);
    for (0..10) |_| try b.indexed(62);
    const bomb = try b.take();
    // The request ended: 431 with END_STREAM, no handler head.
    try t.feed(try headFrame(t, 1, try head(t, bomb), true));
    var out = try t.drain();
    try expectFrames(out, &.{.{ .type = .headers, .id = 1, .flags = F.end_stream | F.end_headers }});
    try expectEqualStrings(":status", out[0].fields[0].name);
    try expectEqualStrings("431", out[0].fields[0].value);
    try expectEqual(0, t.rec.count(.end));
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
    // Still sending: 431, then RST_STREAM(NO_ERROR); the rest of its body
    // is ignored.
    try t.feed(try headFrame(t, 3, try head(t, bomb), false));
    out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers, .id = 3, .flags = F.end_stream | F.end_headers }, rstWith(3, .no_error) });
    try t.feed(try t.data(3, "late", true));
    try expectFrames(try t.drain(), &.{});
    // The blocks were decoded for the table: a reference to the entry
    // still means "b: zzz...".
    try t.feed(try headFrame(t, 5, try head(t, &.{0xbe}), true));
    try expectEqual(1, t.rec.count(.end));
    var seen = false;
    for (t.rec.events.items) |e| switch (e) {
        .field => |f| if (f.id == 5 and std.mem.eql(u8, f.name, "b")) {
            try expectEqualStrings(&z, f.value);
            seen = true;
        },
        else => {},
    };
    try expect(seen);
    // Literals that copy a 4000-byte name each: past twice the limit while
    // skipping, a connection error (INTENTIONAL.md, HPACK 2).
    var c: Buf = .init(t.arena());
    const n: [4000]u8 = @splat('n');
    try c.int(0x40, 6, 0);
    try c.str(&n, false);
    try c.str("", false);
    for (0..12) |_| try c.bytes(&.{ 0x7e, 0x00 });
    try expectError(error.ConnectionError, t.feed(try headFrame(t, 7, try head(t, try c.take()), true)));
    try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
}

test "h2 limits: too many fields" {
    const t = try ready(.{ .max_header_count = 4 });
    defer t.destroy();
    const four = [_]Field{
        .{ .name = "x-1", .value = "1" },
        .{ .name = "x-2", .value = "2" },
        .{ .name = "x-3", .value = "3" },
        .{ .name = "x-4", .value = "4" },
    };
    // Four regular fields (and four pseudo-headers, not counted) pass.
    try t.feed(try t.headers(1, &get ++ four, true));
    try expectEqual(1, t.rec.count(.end));
    try expectFrames(try t.drain(), &.{});
    // A fifth is 431.
    try t.feed(try t.headers(3, &get ++ four ++ [_]Field{.{ .name = "x-5", .value = "5" }}, true));
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .headers, .id = 3, .flags = F.end_stream | F.end_headers }});
    try expectEqualStrings("431", out[0].fields[0].value);
    try expectEqual(1, t.rec.count(.end));
    // 40 cookie crumbs count as one field (RFC 9113 §8.2.3).
    var fs: std.ArrayList(Field) = .empty;
    try fs.appendSlice(t.arena(), &get);
    for (0..40) |i| try fs.append(t.arena(), .{ .name = "cookie", .value = try std.fmt.allocPrint(t.arena(), "c{d}=v", .{i}) });
    try fs.appendSlice(t.arena(), four[0..3]);
    try t.feed(try t.headers(5, fs.items, true));
    try expectEqual(2, t.rec.count(.end));
    try expectFrames(try t.drain(), &.{});
}

test "h2 limits: SETTINGS flood" {
    // More than 32 entries in one frame (frame.zig's check).
    {
        const t = try ready(.{});
        defer t.destroy();
        const entries: [33]frame.Setting = @splat(.{ .id = .max_frame_size, .value = 16384 });
        try expectError(error.ConnectionError, t.feed(try t.settings(&entries)));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    // Ten ACKs queued and none written: the eleventh SETTINGS ends the
    // connection, and its entries aren't applied (nghttp2 :5897).
    {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 10 } });
        defer t.destroy();
        for (0..10) |_| try t.feed(try t.settings(&.{}));
        try expectError(error.ConnectionError, t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 1000 }})));
        try expectEqual(conn.default_window, t.c.remote.initial_window);
        const out = try t.drain();
        try expectEqual(10, count(out, .settings));
        try expectEqual(frame.Type.goaway, out[out.len - 1].type);
        try expectEqual(ErrorCode.enhance_your_calm, out[out.len - 1].code.?);
    }
    // Written, the budget is whole again.
    {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 10 } });
        defer t.destroy();
        for (0..10) |_| try t.feed(try t.settings(&.{}));
        try expectEqual(10, (try t.drain()).len);
        for (0..10) |_| try t.feed(try t.settings(&.{}));
        try expectEqual(10, (try t.drain()).len);
    }
}

test "h2 limits: PING flood" {
    {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 10 } });
        defer t.destroy();
        // The peer's own ACKs are never counted.
        t.rec.record = false;
        for (0..1000) |_| try t.feed(try t.ping(true, @splat(7)));
        for (0..10) |_| try t.feed(try t.ping(false, @splat(1)));
        try expectError(error.ConnectionError, t.feed(try t.ping(false, @splat(1))));
        const out = try t.drain();
        try expectEqual(11, out.len);
        try expectEqual(10, count(out, .ping));
        try expectEqual(ErrorCode.enhance_your_calm, out[10].code.?);
    }
    // A write short of the last ACK releases nothing; past it, all.
    inline for (.{ false, true }) |whole| {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 2 } });
        defer t.destroy();
        try t.feed(try t.ping(false, @splat(1)));
        try t.feed(try t.ping(false, @splat(2)));
        var vecs: [4][]const u8 = undefined;
        const v = try t.c.pending(&vecs);
        try expectEqual(1, v.len);
        try expectEqual(34, v[0].len);
        t.c.advance(if (whole) 34 else 17);
        if (whole) {
            try t.feed(try t.ping(false, @splat(3)));
            try t.feed(try t.ping(false, @splat(4)));
            try expectEqual(2, (try t.drain()).len);
        } else {
            try expectError(error.ConnectionError, t.feed(try t.ping(false, @splat(3))));
            try expectFrames(try t.drain(), &.{ .{ .type = .ping, .flags = F.ack }, goawayWith(.enhance_your_calm) });
        }
    }
}

test "h2 limits: control answers released as they are written" {
    // A standing backlog: each ACK is written only after the next is
    // queued, so the writer never passes the newest one. The count follows
    // what is really unwritten (two answers), never the total (Go and
    // nghttp2 release per frame).
    const t = try ready(.{ .limits = .{ .control_frame_budget = 3 } });
    defer t.destroy();
    try t.feed(try t.ping(false, @splat(0)));
    for (1..100) |i| {
        try t.feed(try t.ping(false, @splat(@intCast(i))));
        t.c.advance(frame.header_len + 8);
    }
    try expectFrames(try t.drain(), &.{.{ .type = .ping, .flags = F.ack }});
}

test "h2 limits: reset flood" {
    {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 10 } });
        defer t.destroy();
        var id: u31 = 1;
        while (id < 21) : (id += 2) try provoke(t, id);
        try t.feed(try t.headers(21, &post, false));
        try t.feed(try t.rst(21, .cancel));
        try expectError(error.ConnectionError, t.feed(try t.data(21, "x", false)));
        const out = try t.drain();
        try expectEqual(10, count(out, .rst_stream));
        try expectEqual(ErrorCode.enhance_your_calm, out[out.len - 1].code.?);
    }
    {
        const t = try ready(.{ .limits = .{ .control_frame_budget = 10 } });
        defer t.destroy();
        var id: u31 = 1;
        while (id < 21) : (id += 2) try provoke(t, id);
        try expectEqual(10, (try t.drain()).len);
        while (id < 41) : (id += 2) try provoke(t, id);
        try expectEqual(10, (try t.drain()).len);
    }
}

test "h2 limits: empty frames" {
    const opts: conn.Options = .{ .limits = .{ .empty_frame_rate = 5, .empty_frame_burst = 5 } };
    // Empty DATA without END_STREAM counts, with it not. A payload of only
    // padding isn't empty (nghttp2 :6930 charges payloadleft == 0 after the
    // Pad Length; padding is flow-controlled), the Pad Length alone is.
    {
        const t = try ready(opts);
        defer t.destroy();
        try t.feed(try t.headers(1, &post, false));
        for (0..5) |_| try t.feed(try t.data(1, "", false));
        try t.feed(try t.data(1, "", true));
        try t.feed(try t.headers(3, &post, false));
        try t.feed(try t.dataPadded(3, "", false, 4));
        try expectError(error.ConnectionError, t.feed(try t.dataPadded(3, "", false, 0)));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    // Unknown frames count (D15 point 2), and the bucket refills by the
    // second.
    {
        const t = try ready(opts);
        defer t.destroy();
        for (0..5) |_| try t.feed(try t.raw(0x20, 0, 0, "x"));
        t.now += 1;
        for (0..5) |_| try t.feed(try t.raw(0x20, 0, 1, ""));
        try expectError(error.ConnectionError, t.feed(try t.raw(0x20, 0, 0, "x")));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    // So do empty CONTINUATIONs.
    {
        const t = try ready(opts);
        defer t.destroy();
        const blk = try t.block(&get);
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk }));
        for (0..5) |_| try t.feed(try t.continuation(1, false, ""));
        try expectError(error.ConnectionError, t.feed(try t.continuation(1, false, "")));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
}

test "h2 limits: every unknown frame type at once after the preface is ignored, and a PING answered" {
    // grpc's tools/http2_interop TestSoonUnknownFrameType: types 11 to 255,
    // empty, on stream 0, back to back, then a PING (RFC 9113 §4.1, §5.5).
    // Without PRIORITY_UPDATE, which RFC 9218 made known (empty, it is a
    // FRAME_SIZE_ERROR: "a malformed PRIORITY_UPDATE" below), as
    // tests/grpc/interop/run-http2.sh has the tool skip it.
    const t = try ready(.{});
    defer t.destroy();
    var ty: u8 = 11;
    while (true) : (ty += 1) {
        if (ty != 0x10) try t.feed(try t.raw(ty, 0, 0, ""));
        if (ty == 255) break;
    }
    try t.feed(try t.ping(false, "01234567".*));
    const out = try t.drain();
    try expectEqual(0, count(out, .goaway));
    try expectEqual(1, count(out, .ping));
}

test "h2 limits: refused-stream burst" {
    const t = try ready(.{ .max_concurrent_streams = 2, .refused_stream_burst = 3, .refused_stream_rate = 1 });
    defer t.destroy();
    try t.feed(try headFrame(t, 1, try head(t, ""), false));
    try t.feed(try headFrame(t, 3, try head(t, ""), false));
    // Refused before any handler sees them, but decoded: stream 5's block
    // adds "x-refused: 1" to the table.
    var b: Buf = .init(t.arena());
    try b.literal(.with, 0, "x-refused", "1");
    try t.feed(try headFrame(t, 5, try head(t, try b.take()), false));
    try t.feed(try headFrame(t, 7, try head(t, ""), false));
    try t.feed(try headFrame(t, 9, try head(t, ""), true));
    try expectFrames(try t.drain(), &.{ rstWith(5, .refused_stream), rstWith(7, .refused_stream), rstWith(9, .refused_stream) });
    try expectEqual(2, t.rec.count(.open));
    // A slot frees; the next stream uses the refused block's entry.
    try t.feed(try t.rst(1, .cancel));
    try t.feed(try headFrame(t, 11, try head(t, &.{0xbe}), false));
    try expectEqual(3, t.rec.count(.open));
    var seen = false;
    for (t.rec.events.items) |e| switch (e) {
        .field => |f| if (f.id == 11 and std.mem.eql(u8, f.name, "x-refused")) {
            seen = true;
        },
        else => {},
    };
    try expect(seen);
    // The fourth refusal ends the connection.
    try expectError(error.ConnectionError, t.feed(try headFrame(t, 13, try head(t, ""), false)));
    try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
}

test "h2 limits: header blocks after our GOAWAY" {
    // Ignored, but decoded for the table: each is a glitch (nghttp2's
    // IGN_HEADER_BLOCK, :5811), so a drain can't be fed blocks forever.
    const t = try ready(.{ .limits = .{ .glitch_burst = 3, .glitch_rate = 1 } });
    defer t.destroy();
    try t.c.goaway(.no_error, "");
    _ = try t.drain();
    var id: u31 = 1;
    while (id < 7) : (id += 2) try t.feed(try t.headers(id, &get, true));
    try expectEqual(0, t.rec.count(.open));
    try expectFrames(try t.drain(), &.{});
    try expectError(error.ConnectionError, t.feed(try t.headers(7, &get, true)));
    try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
}

const big_body: [4096]u8 = @splat('b');
const big_parts = [_][]const u8{&big_body};

test "h2 limits: a peer that stops reading" {
    const t = try ready(.{ .limits = .{ .out_high = 1024 } });
    defer t.destroy();
    t.rec.answer = true;
    t.rec.body = &big_parts;
    try t.feed(try t.headers(1, &get, true));
    // Framed, not yet written: the DATA is borrowed and the writer is mid
    // write, which a reading peer must not pay for.
    var vecs: [8][]const u8 = undefined;
    _ = try t.c.pending(&vecs);
    try expect(t.c.out.queued_total - t.c.out.sent_total > 4096);
    try expect(t.c.out.ownedUnsent() < 1024);
    t.rec.answer = false;
    try t.feed(try t.headers(3, &post, false));
    try expectEqual(2, t.rec.count(.open));
    // What grows while the peer doesn't read is owned: a 2000-byte head.
    const v: [2000]u8 = @splat('~');
    try t.c.submitHead(t.stream(3), 200, &.{.{ .name = "x-big", .value = &v }}, false);
    try expect(t.c.out.ownedUnsent() > 1024);
    // New streams are refused...
    try t.feed(try t.headers(5, &get, true));
    try expectEqual(2, t.rec.count(.open));
    // ...while the rest is processed: credit, SETTINGS (ACKed), PING.
    const before = t.c.send_window;
    try t.feed(try t.windowUpdate(0, 1000));
    try expectEqual(before + 1000, t.c.send_window);
    try t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 70000 }}));
    try expectEqual(70000, t.c.remote.initial_window);
    try t.feed(try t.ping(false, @splat(9)));
    // The write timeout that would close this connection is M3's sweeper.
    const out = try t.drain();
    try expectEqual(ErrorCode.refused_stream, find(out, .rst_stream, 5).?.code.?);
    try expect(find(out, .data, 1) != null);
    try expect(find(out, .headers, 3) != null);
    try expectEqual(1, count(out, .ping));
    try expectEqual(1, count(out, .settings));
    // Written: streams are admitted again.
    try t.feed(try t.headers(7, &get, true));
    try expectEqual(3, t.rec.count(.open));
}

test "h2 limits: one large DATA frame in flight refuses nothing" {
    // A peer that reads at full speed with a 16 MiB frame size and big
    // windows: one pending() frames a 2 MiB DATA frame, and a request
    // arriving while it is written is admitted, uncharged.
    const t = try ready(.{ .refused_stream_burst = 1, .refused_stream_rate = 1 });
    defer t.destroy();
    try t.feed(try t.settings(&.{
        .{ .id = .max_frame_size, .value = frame.max_max_frame_size },
        .{ .id = .initial_window_size, .value = 8 << 20 },
    }));
    try t.feed(try t.windowUpdate(0, 8 << 20));
    _ = try t.drain();
    const body = try t.arena().alloc(u8, 2 << 20);
    @memset(body, 'd');
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{body}, true);
    var vecs: [8][]const u8 = undefined;
    _ = try t.c.pending(&vecs);
    try expect(t.c.out.queued_total - t.c.out.sent_total > 2 << 20);
    var id: u31 = 3;
    while (id < 9) : (id += 2) try t.feed(try t.headers(id, &post, false));
    try expectEqual(4, t.rec.count(.open));
    const out = try t.drain();
    try expectEqual(0, count(out, .rst_stream));
    try expectEqual(0, count(out, .goaway));
}

test "h2 limits: window update zero and overflow" {
    // 0 on the connection (frame.zig) and on a stream (nghttp2 :4883): a
    // connection PROTOCOL_ERROR, so no stream reset can be provoked by it.
    {
        const t = try ready(.{});
        defer t.destroy();
        try expectError(error.ConnectionError, t.feed(try t.windowUpdate(0, 0)));
        try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
    }
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.headers(1, &post, false));
        try expectError(error.ConnectionError, t.feed(try t.windowUpdate(1, 0)));
        try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
    }
    // A stream overflow is a stream FLOW_CONTROL_ERROR, charged as a
    // provoked reset.
    {
        const t = try ready(.{ .stream_reset_burst = 1, .stream_reset_rate = 1 });
        defer t.destroy();
        inline for (.{ 1, 3 }) |id| {
            try t.feed(try t.headers(id, &post, false));
            try t.feed(try t.windowUpdate(id, frame.max_window_size - 65535));
        }
        try t.feed(try t.windowUpdate(1, 1));
        try expectFrames(try t.drain(), &.{rstWith(1, .flow_control_error)});
        try expectError(error.ConnectionError, t.feed(try t.windowUpdate(3, 1)));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    // The connection's own overflow.
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.windowUpdate(0, frame.max_window_size - 65535));
        try expectError(error.ConnectionError, t.feed(try t.windowUpdate(0, 1)));
        try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
    }
}

test "h2: PRIORITY frames have no effect beyond validation" {
    const t = try ready(.{ .limits = .{ .glitch_burst = 3, .glitch_rate = 1 } });
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    // On an idle stream, an open one, and depending on an idle one.
    try t.feed(try t.priority(5, 1));
    try t.feed(try t.priority(1, 3));
    try t.feed(try t.priority(3, 9));
    try expectFrames(try t.drain(), &.{});
    try expectEqual(1, t.c.last_recv);
    try expectEqual(1, t.c.table.size);
    // The idle stream opens as if no PRIORITY had come.
    try t.feed(try t.headers(5, &get, true));
    try expectEqual(2, t.rec.count(.open));
    // No budget moved (nghttp2 charges its glitch budget; INTENTIONAL.md,
    // limits 9).
    try t.feed(try t.priority(7, 1));
    try expectFrames(try t.drain(), &.{});
}

/// Budgets far below what a browser sends, so a charge would show.
const tight: conn.Options = .{ .limits = .{ .glitch_burst = 10, .glitch_rate = 1, .empty_frame_rate = 10, .empty_frame_burst = 10 } };

fn priorityUpdate(t: *T, id: u31, target: u32, value: []const u8) ![]const u8 {
    const p = try t.arena().alloc(u8, 4 + value.len);
    std.mem.writeInt(u32, p[0..4], target, .big);
    @memcpy(p[4..], value);
    return t.raw(0x10, 0, id, p);
}

test "h2 limits: PRIORITY frames from a page load are not charged" {
    // Chromium sends about one per subresource, 956/s on reloads
    // (bench/results/20261111-h2-limits-calibration).
    const t = try ready(tight);
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    var id: u31 = 3;
    for (0..2000) |_| {
        try t.feed(try t.priority(id, 1));
        id += 2;
    }
    try expectEqual(0, count(try t.drain(), .goaway));
    // The connection is still in use.
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(2, t.rec.count(.open));
}

test "h2 limits: PRIORITY_UPDATE is not counted as an unknown frame" {
    const t = try ready(tight);
    defer t.destroy();
    var id: u31 = 1;
    for (0..2000) |_| {
        try t.feed(try priorityUpdate(t, 0, id, "u=1, i"));
        id += 2;
    }
    try t.feed(try priorityUpdate(t, 0, 1 << 31 | 5, ""));
    try expectEqual(0, count(try t.drain(), .goaway));
    try t.feed(try t.headers(1, &get, true));
    try expectEqual(1, t.rec.count(.open));
    // Any other unknown type still counts (D15 point 2).
    for (0..10) |_| try t.feed(try t.raw(0xfa, 0, 0, "x"));
    try expectError(error.ConnectionError, t.feed(try t.raw(0xfa, 0, 0, "x")));
    try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
}

test "h2 limits: a malformed PRIORITY_UPDATE is a connection error" {
    const Case = struct { id: u31, payload: []const u8, code: ErrorCode };
    const cases = [_]Case{
        // RFC 9113 §4.2: too short for the Prioritized Stream ID.
        .{ .id = 0, .payload = "\x00\x00\x01", .code = .frame_size_error },
        .{ .id = 0, .payload = "", .code = .frame_size_error },
        // RFC 9218 §7.1: on a stream, for stream 0, for a push stream.
        .{ .id = 1, .payload = "\x00\x00\x00\x01", .code = .protocol_error },
        .{ .id = 0, .payload = "\x00\x00\x00\x00u=1", .code = .protocol_error },
        .{ .id = 0, .payload = "\x80\x00\x00\x00", .code = .protocol_error },
        .{ .id = 0, .payload = "\x00\x00\x00\x02", .code = .protocol_error },
    };
    for (cases) |cs| {
        const t = try ready(.{});
        defer t.destroy();
        try expectError(error.ConnectionError, t.feed(try t.raw(0x10, 0, cs.id, cs.payload)));
        try expectFrames(try t.drain(), &.{goawayWith(cs.code)});
    }
}

test "h2: body over the limit" {
    // Past the stream's window: a connection FLOW_CONTROL_ERROR, as nghttp2
    // (nghttp2_session_update_recv_stream_window_size :5202).
    {
        const t = try ready(.{ .initial_window = 1024 });
        defer t.destroy();
        t.rec.consume = false;
        try t.feed(try t.headers(1, &post, false));
        const body: [1025]u8 = @splat('x');
        try expectError(error.ConnectionError, t.feed(try t.data(1, &body, false)));
        try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
    }
    // Past the connection's.
    {
        const t = try ready(.{ .connection_window = 65535, .initial_window = 65536 });
        defer t.destroy();
        t.rec.consume = false;
        try t.feed(try t.headers(1, &post, false));
        const body: [16384]u8 = @splat('x');
        for (0..3) |_| try t.feed(try t.data(1, &body, false));
        try expectError(error.ConnectionError, t.feed(try t.data(1, &body, false)));
        try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
    }
    // Past the content-length: the stream (RFC 9113 §8.1.1).
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.headers(1, &postLen("3"), false));
        try t.feed(try t.data(1, "abcd", false));
        try expectFrames(try t.drain(), &.{rstWith(1, .protocol_error)});
    }
    // An early answer (413, the engine's max_body_size): END_STREAM, then
    // RST_STREAM(NO_ERROR) from the engine (RFC 9113 §8.1); DATA still on
    // its way is dropped, and its connection credit given back.
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.headers(1, &post, false));
        try t.c.submitHead(t.stream(1), 413, &.{}, true);
        try t.c.reset(t.stream(1), .no_error);
        try expectFrames(try t.drain(), &.{ .{ .type = .headers, .id = 1, .flags = F.end_stream | F.end_headers }, rstWith(1, .no_error) });
        const before = t.c.recv_unacked;
        const body: [1000]u8 = @splat('x');
        try t.feed(try t.data(1, &body, false));
        try expectEqual(before + 1000, t.c.recv_unacked);
        try expectEqual(0, t.rec.count(.data));
        try expectFrames(try t.drain(), &.{});
    }
}
