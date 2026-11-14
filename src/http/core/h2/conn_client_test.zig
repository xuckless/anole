// Tests translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// tests/nghttp2_session_test.c and tests/nghttp2_http_test.c. See
// LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! Tests for conn.zig's client role (M5). The ones named after an nghttp2
//! session test (`h2 client conn: <name>`, without its test_nghttp2_
//! prefix) port its client-side scenario to the Conn API. A server is
//! played by hand: its frames are built with conn_test.zig's `T` (a server
//! Conn used only for its encoders and arena), and what the client sends
//! is drained and re-parsed (`CT.drain`).

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const conn = @import("conn.zig");
const fuzz = @import("../fuzz.zig");
const ct = @import("conn_test.zig");

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const Allocator = std.mem.Allocator;
const ErrorCode = frame.ErrorCode;
const Stream = conn.Stream;
const Field = hpack.Field;
const F = frame.flags;
const OutFrame = ct.OutFrame;
const expectFrames = ct.expectFrames;
const goawayWith = ct.goawayWith;
const rstWith = ct.rstWith;

const Event = union(enum) {
    field: struct { id: u31, name: []const u8, value: []const u8, trailer: bool },
    /// `interim`: `s.flags.expect_final` after the head (a 1xx).
    end: struct { id: u31, end_stream: bool, trailers: bool, interim: bool },
    data: struct { id: u31, bytes: []const u8, end_stream: bool },
    close: struct { id: u31, code: ErrorCode },
    refused_head: u31,
    window: ?u31,
    goaway: struct { last: u31, code: ErrorCode },
    ping_ack: [8]u8,
};

/// The client's handler: logs every callback.
const Rec = struct {
    gpa: Allocator,
    arena: Allocator,
    c: *CC = undefined,
    events: std.ArrayList(Event) = .empty,
    record: bool = true,
    consume: bool = true,

    fn log(r: *Rec, e: Event) void {
        if (r.record) r.events.append(r.gpa, e) catch @panic("OOM");
    }

    fn dupe(r: *Rec, b: []const u8) []const u8 {
        return if (r.record) r.arena.dupe(u8, b) catch @panic("OOM") else "";
    }

    pub fn onHeadRefused(r: *Rec, s: *Stream) void {
        r.log(.{ .refused_head = s.id });
    }

    pub fn onField(r: *Rec, s: *Stream, name: []const u8, value: []const u8) conn.Error!void {
        r.log(.{ .field = .{ .id = s.id, .name = r.dupe(name), .value = r.dupe(value), .trailer = s.flags.in_trailers } });
    }

    pub fn onHeadersEnd(r: *Rec, s: *Stream, end_stream: bool) conn.Error!void {
        r.log(.{ .end = .{ .id = s.id, .end_stream = end_stream, .trailers = s.flags.in_trailers, .interim = s.flags.expect_final } });
    }

    pub fn onData(r: *Rec, s: *Stream, bytes: []const u8, end_stream: bool) conn.Error!void {
        r.log(.{ .data = .{ .id = s.id, .bytes = r.dupe(bytes), .end_stream = end_stream } });
        if (r.consume) r.c.consumed(s, bytes.len) catch @panic("OOM");
    }

    pub fn onStreamClose(r: *Rec, s: *Stream, code: ErrorCode) void {
        r.log(.{ .close = .{ .id = s.id, .code = code } });
    }

    pub fn onWindow(r: *Rec, s: ?*Stream) void {
        r.log(.{ .window = if (s) |x| x.id else null });
    }

    pub fn onGoaway(r: *Rec, last: u31, code: ErrorCode) void {
        r.log(.{ .goaway = .{ .last = last, .code = code } });
    }

    pub fn onPingAck(r: *Rec, data: [8]u8) void {
        r.log(.{ .ping_ack = data });
    }

    fn count(r: *const Rec, comptime tag: std.meta.Tag(Event)) usize {
        var n: usize = 0;
        for (r.events.items) |e| {
            if (e == tag) n += 1;
        }
        return n;
    }

    fn closeCode(r: *const Rec, id: u31) ?ErrorCode {
        for (r.events.items) |e| switch (e) {
            .close => |x| if (x.id == id) return x.code,
            else => {},
        };
        return null;
    }

    fn status(r: *const Rec, id: u31) ?[]const u8 {
        var last: ?[]const u8 = null;
        for (r.events.items) |e| switch (e) {
            .field => |f| if (f.id == id and std.mem.eql(u8, f.name, ":status")) {
                last = f.value;
            },
            else => {},
        };
        return last;
    }
};

const CC = conn.Conn(.client, Rec);

const CT = struct {
    gpa: Allocator,
    /// The server: its frames, its HPACK, its arena.
    srv: *ct.T,
    rec: Rec,
    c: CC,
    scratch: []u8,
    inbuf: std.ArrayList(u8) = .empty,
    outbuf: std.ArrayList(u8) = .empty,
    bytewise: bool = false,
    /// The client magic is drained once, ahead of the frames.
    magic_seen: bool = false,

    fn create(gpa: Allocator, opts: conn.Options) !*CT {
        return createSplit(gpa, gpa, opts);
    }

    fn createSplit(gpa: Allocator, conn_gpa: Allocator, opts: conn.Options) !*CT {
        const t = try gpa.create(CT);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .srv = undefined, .rec = undefined, .c = undefined, .scratch = undefined };
        t.srv = try ct.T.create(gpa, .{});
        errdefer t.srv.destroy();
        t.rec = .{ .gpa = gpa, .arena = t.srv.arena() };
        t.scratch = try gpa.alloc(u8, @max(opts.max_header_list_size, hpack.table_capacity));
        errdefer gpa.free(t.scratch);
        try t.c.initAt(conn_gpa, &t.rec, opts);
        t.rec.c = &t.c;
        return t;
    }

    fn destroy(t: *CT) void {
        t.c.deinit();
        t.rec.events.deinit(t.gpa);
        t.inbuf.deinit(t.gpa);
        t.outbuf.deinit(t.gpa);
        t.gpa.free(t.scratch);
        t.srv.destroy();
        t.gpa.destroy(t);
    }

    fn arena(t: *CT) Allocator {
        return t.srv.arena();
    }

    /// Feeds server bytes (one at a time when `bytewise`).
    fn feed(t: *CT, bytes: []const u8) !void {
        if (t.bytewise) {
            for (bytes) |b| {
                try t.inbuf.append(t.gpa, b);
                try t.pump();
            }
        } else {
            try t.inbuf.appendSlice(t.gpa, bytes);
            try t.pump();
        }
    }

    fn pump(t: *CT) !void {
        const n = try t.c.recv(t.inbuf.items, 1, t.scratch);
        const rest = t.inbuf.items.len - n;
        std.mem.copyForwards(u8, t.inbuf.items[0..rest], t.inbuf.items[n..]);
        t.inbuf.items.len = rest;
    }

    /// Everything the client has to send, parsed (HEADERS decoded with the
    /// server's HPACK), after the client magic, which must come first.
    fn drain(t: *CT) ![]OutFrame {
        var vecs: [8][]const u8 = undefined;
        while (true) {
            const v = try t.c.pending(&vecs);
            if (v.len == 0) break;
            var n: usize = 0;
            for (v) |b| {
                try t.outbuf.appendSlice(t.gpa, b);
                n += b.len;
            }
            t.c.advance(n);
        }
        try expect(t.c.out.idle());
        var rest = t.outbuf.items;
        if (!t.magic_seen and rest.len > 0) {
            try expect(std.mem.startsWith(u8, rest, conn.client_magic));
            rest = rest[conn.client_magic.len..];
            t.magic_seen = true;
        }
        var list: std.ArrayList(OutFrame) = .empty;
        while (rest.len > 0) {
            const f = switch (frame.parse(rest, .{ .max_frame_size = frame.max_max_frame_size })) {
                .frame => |f| f,
                else => return error.BadOutputFrame,
            };
            try expect(f.parsed.header.length <= t.c.remote.max_frame_size);
            rest = rest[f.len..];
            const h = f.parsed.header;
            var o: OutFrame = .{ .type = h.type, .flags = h.flags, .id = h.stream_id };
            switch (f.parsed.frame) {
                .data => |d| o.data = try t.arena().dupe(u8, d.data),
                .headers => |hd| {
                    try expect(hd.end_headers);
                    o.fields = try t.srv.decode(hd.fragment);
                },
                .rst_stream => |code| o.code = code,
                .settings => |st| {
                    var l: std.ArrayList(frame.Setting) = .empty;
                    var it = st.iterator();
                    while (it.next()) |e| try l.append(t.arena(), e);
                    o.settings = l.items;
                },
                .ping => |p| o.data = try t.arena().dupe(u8, &p.data),
                .goaway => |g| {
                    o.code = g.code;
                    o.last_id = g.last_stream_id;
                },
                .window_update => |inc| o.inc = inc,
                else => return error.UnexpectedOutputFrame,
            }
            try list.append(t.arena(), o);
        }
        t.outbuf.clearRetainingCapacity();
        return list.items;
    }

    /// The server's SETTINGS (`entries`) and its ACK of ours; what the
    /// client sent (preface, SETTINGS, ACK) drained.
    fn handshake(t: *CT, entries: []const frame.Setting) !void {
        try t.feed(try t.srv.settings(entries));
        try t.feed(try t.srv.settingsAck());
        const out = try t.drain();
        try expect(out.len >= 2);
        try expectEqual(frame.Type.settings, out[0].type);
        try expectEqual(F.ack, out[out.len - 1].flags);
    }

    fn request(t: *CT, hdrs: []const Field, end_stream: bool) !*Stream {
        return t.c.submitRequest(hdrs, end_stream, null);
    }

    fn head(t: *CT, id: u31, hdrs: []const Field, end_stream: bool) !void {
        try t.feed(try t.srv.headers(id, hdrs, end_stream));
    }

    fn data(t: *CT, id: u31, bytes: []const u8, end_stream: bool) !void {
        try t.feed(try t.srv.data(id, bytes, end_stream));
    }
};

const get = ct.get;
const head_req = [_]Field{
    .{ .name = ":method", .value = "HEAD" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":authority", .value = "example.org" },
};
const ok = [_]Field{.{ .name = ":status", .value = "200" }};

fn status(comptime code: []const u8) [1]Field {
    return .{.{ .name = ":status", .value = code }};
}

fn ready(opts: conn.Options) !*CT {
    const t = try CT.create(testing.allocator, opts);
    errdefer t.destroy();
    try t.handshake(&.{});
    return t;
}

// ---------------------------------------------------------------------------
// The preface and the requests

test "h2 client conn: the preface is the magic, then SETTINGS with ENABLE_PUSH=0 and no MAX_CONCURRENT_STREAMS" {
    const t = try CT.create(testing.allocator, .{ .initial_window = 1 << 20, .connection_window = 1 << 24, .max_header_list_size = 8192 });
    defer t.destroy();
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .settings, .flags = 0 }, .{ .type = .window_update, .id = 0 } });
    var push: ?u32 = null;
    for (out[0].settings) |e| switch (e.id) {
        .enable_push => push = e.value,
        .max_concurrent_streams => return error.TestUnexpectedResult,
        .initial_window_size => try expectEqual(1 << 20, e.value),
        .max_header_list_size => try expectEqual(8192, e.value),
        else => {},
    };
    try expectEqual(0, push.?);
    try expectEqual((1 << 24) - 65535, out[1].inc);
    // Nothing is read of a preface from the server: its first frame is
    // its SETTINGS.
    try t.feed(try t.srv.settings(&.{}));
    try expectFrames(try t.drain(), &.{.{ .type = .settings, .flags = F.ack }});
}

test "h2 client conn: the server's first frame must be SETTINGS" {
    const t = try CT.create(testing.allocator, .{});
    defer t.destroy();
    _ = try t.drain();
    try expectError(error.ConnectionError, t.feed(try t.srv.ping(false, @splat(0))));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 client conn: requests open odd IDs in order, and HEADERS carry the request head" {
    const t = try ready(.{});
    defer t.destroy();
    const a = try t.request(&get, true);
    const b = try t.request(&ct.post, false);
    try expectEqual(1, a.id);
    try expectEqual(3, b.id);
    try expectEqual(.half_closed_local, a.state);
    try expectEqual(.open, b.state);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers, .id = 1, .flags = F.end_headers | F.end_stream }, .{ .type = .headers, .id = 3, .flags = F.end_headers } });
    try expectEqual(get.len, out[0].fields.len);
    for (get, out[0].fields) |w, g| {
        try expectEqualStrings(w.name, g.name);
        try expectEqualStrings(w.value, g.value);
    }
    // The body, then its end riding on the last DATA.
    const parts = [_][]const u8{"hello"};
    try t.c.submitData(b, &parts, false);
    try t.c.submitData(b, &.{}, true);
    try expectFrames(try t.drain(), &.{.{ .type = .data, .id = 3, .flags = F.end_stream }});
}

test "h2 client conn: on_response_headers_received: a head, DATA, END_STREAM" {
    const t = try ready(.{});
    defer t.destroy();
    const s = try t.request(&get, true);
    _ = try t.drain();
    try t.head(s.id, &(ok ++ [_]Field{.{ .name = "content-length", .value = "5" }}), false);
    try expectEqualStrings("200", t.rec.status(1).?);
    try expect(s.flags.headers_received and !s.flags.expect_final);
    try t.data(1, "hel", false);
    try t.data(1, "lo", true);
    try expectEqual(.no_error, t.rec.closeCode(1).?);
    try expectEqual(2, t.rec.count(.data));
    try expectEqual(0, t.c.table.size);
}

test "h2 client conn: informational heads, then the final one, then trailers" {
    const t = try ready(.{});
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.drain();
    try t.head(1, &status("100"), false);
    try t.head(1, &status("103"), false);
    try t.head(1, &ok, false);
    var ends: [3]bool = undefined;
    var k: usize = 0;
    for (t.rec.events.items) |e| if (e == .end) {
        ends[k] = e.end.interim;
        k += 1;
    };
    try expectEqual(3, k);
    try expect(ends[0] and ends[1] and !ends[2]);
    try t.data(1, "body", false);
    try t.head(1, &.{.{ .name = "grpc-status", .value = "0" }}, true);
    try expectEqual(.no_error, t.rec.closeCode(1).?);
    const last = t.rec.events.items[t.rec.events.items.len - 2];
    try expect(last.end.trailers and last.end.end_stream);
}

test "h2 client conn: trailers without END_STREAM, DATA before the final head and END_STREAM on a 1xx reset the stream" {
    const t = try ready(.{});
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.request(&get, true);
    _ = try t.request(&get, true);
    _ = try t.drain();
    try t.head(1, &ok, false);
    try t.head(1, &.{.{ .name = "x", .value = "y" }}, false);
    try t.data(3, "early", false);
    try t.head(5, &status("100"), true);
    try expectFrames(try t.drain(), &.{ rstWith(1, .protocol_error), rstWith(3, .protocol_error), rstWith(5, .protocol_error) });
}

test "h2 client conn: no body for HEAD, 204 or 304, and content-length must add up" {
    const t = try ready(.{});
    defer t.destroy();
    const h = try t.request(&head_req, true);
    try expect(h.flags.head_request);
    _ = try t.request(&get, true); // 3: 204
    _ = try t.request(&get, true); // 5: 304
    _ = try t.request(&get, true); // 7: more than content-length
    _ = try t.request(&get, true); // 9: less than content-length
    _ = try t.request(&head_req, true); // 11: HEAD, ended on the head
    _ = try t.drain();
    try t.head(1, &(ok ++ [_]Field{.{ .name = "content-length", .value = "100" }}), false);
    try t.data(1, "x", true);
    try t.head(3, &status("204"), false);
    try t.data(3, "x", true);
    try t.head(5, &status("304"), false);
    try t.data(5, "x", true);
    try t.head(7, &(ok ++ [_]Field{.{ .name = "content-length", .value = "2" }}), false);
    try t.data(7, "xyz", true);
    try t.head(9, &(ok ++ [_]Field{.{ .name = "content-length", .value = "4" }}), false);
    try t.data(9, "xyz", true);
    try t.head(11, &(ok ++ [_]Field{.{ .name = "content-length", .value = "100" }}), true);
    try expectFrames(try t.drain(), &.{
        rstWith(1, .protocol_error), rstWith(3, .protocol_error), rstWith(5, .protocol_error),
        rstWith(7, .protocol_error), rstWith(9, .protocol_error),
    });
    try expectEqual(.no_error, t.rec.closeCode(11).?);
}

test "h2 client conn: test_nghttp2_http_on_header's response cases: each malformed head resets its stream, charged to no budget" {
    const cases = [_][]const Field{
        &.{.{ .name = "x", .value = "y" }},
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = ":status", .value = "200" } },
        &.{.{ .name = ":status", .value = "101" }},
        &.{.{ .name = ":status", .value = "20" }},
        &.{.{ .name = ":status", .value = "099" }},
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = ":path", .value = "/" } },
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = "X-Up", .value = "1" } },
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = "connection", .value = "close" } },
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = "transfer-encoding", .value = "chunked" } },
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = "te", .value = "gzip" } },
        &.{ .{ .name = ":status", .value = "204" }, .{ .name = "content-length", .value = "1" } },
        &.{ .{ .name = ":status", .value = "100" }, .{ .name = "content-length", .value = "0" } },
        &.{ .{ .name = ":status", .value = "200" }, .{ .name = "content-length", .value = "1" }, .{ .name = "content-length", .value = "1" } },
        &.{ .{ .name = "x", .value = "y" }, .{ .name = ":status", .value = "200" } },
    };
    // Past the server's reset budget (burst 1000): a client charges none.
    const t = try ready(.{ .stream_reset_burst = 4, .stream_reset_rate = 0 });
    defer t.destroy();
    for (0..4) |_| for (cases) |fs| {
        const s = try t.request(&get, true);
        const id = s.id;
        _ = try t.drain();
        try t.head(id, fs, false);
        try expectFrames(try t.drain(), &.{rstWith(id, .protocol_error)});
    };
    try expect(t.c.goaway_sent == null);
}

test "h2 client conn: a 204's content-length 0 is dropped, and lenient fields are ignored" {
    const t = try ready(.{});
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.drain();
    try t.head(1, &.{ .{ .name = ":status", .value = "204" }, .{ .name = "content-length", .value = "0" }, .{ .name = "x", .value = " padded " }, .{ .name = "ok", .value = "1" } }, true);
    try expectEqual(.no_error, t.rec.closeCode(1).?);
    var names: usize = 0;
    for (t.rec.events.items) |e| if (e == .field) {
        names += 1;
        try expect(!std.mem.eql(u8, e.field.name, "content-length") and !std.mem.eql(u8, e.field.name, "x"));
    };
    try expectEqual(2, names);
}

test "h2 client conn: a head past max_header_list_size is refused and reset" {
    const t = try ready(.{ .max_header_list_size = 4096 });
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.drain();
    // Small on the wire, past the limit decoded (each field counts 32
    // more): the block is taken, then refused.
    const many: [151]Field = .{ok[0]} ++ @as([150]Field, @splat(.{ .name = "a", .value = "" }));
    try t.head(1, &many, false);
    try expectFrames(try t.drain(), &.{rstWith(1, .internal_error)});
    try expectEqual(1, t.rec.count(.refused_head));
    try expectEqual(.internal_error, t.rec.closeCode(1).?);
}

// ---------------------------------------------------------------------------
// Frames on streams that aren't ours, or are gone

test "h2 client conn: on_push_promise_received: PUSH_PROMISE is a connection error" {
    const t = try ready(.{});
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.drain();
    try expectError(error.ConnectionError, t.feed(try t.srv.pushPromise(1, 2)));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    // A client processed none of the server's streams.
    try expectEqual(0, out[0].last_id);
}

test "h2 client conn: on_headers_received: frames on an even or a never-opened ID are connection errors" {
    const frames = [_][]const u8{ "headers2", "headers5", "data2", "data5", "rst5", "wu5", "rst2" };
    for (frames) |which| {
        const t = try ready(.{});
        defer t.destroy();
        _ = try t.request(&get, true);
        _ = try t.request(&get, true);
        _ = try t.drain();
        const f = if (std.mem.eql(u8, which, "headers2"))
            try t.srv.headers(2, &ok, false)
        else if (std.mem.eql(u8, which, "headers5"))
            try t.srv.headers(5, &ok, false)
        else if (std.mem.eql(u8, which, "data2"))
            try t.srv.data(2, "x", false)
        else if (std.mem.eql(u8, which, "data5"))
            try t.srv.data(5, "x", false)
        else if (std.mem.eql(u8, which, "rst5"))
            try t.srv.rst(5, .cancel)
        else if (std.mem.eql(u8, which, "wu5"))
            try t.srv.windowUpdate(5, 1)
        else
            try t.srv.rst(2, .cancel);
        try expectError(error.ConnectionError, t.feed(f));
        try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
    }
}

test "h2 client conn: what the server sends on a stream we reset is ignored" {
    const t = try ready(.{});
    defer t.destroy();
    const s = try t.request(&get, true);
    _ = try t.drain();
    const window = t.c.recv_window;
    try t.c.reset(s, .cancel);
    try expectFrames(try t.drain(), &.{rstWith(1, .cancel)});
    try t.head(1, &ok, false);
    try t.data(1, "late", false);
    try t.feed(try t.srv.windowUpdate(1, 10));
    try t.feed(try t.srv.rst(1, .cancel));
    try expectFrames(try t.drain(), &.{});
    // The ignored DATA's connection credit came back unannounced (below
    // half the window).
    try expectEqual(window, t.c.recv_window + @as(i32, @intCast(t.c.recv_unacked)));
}

test "h2 client conn: a server's RST_STREAMs are charged to no budget" {
    const t = try ready(.{ .stream_reset_burst = 2, .stream_reset_rate = 0 });
    defer t.destroy();
    for (0..10) |_| {
        const s = try t.request(&get, false);
        const id = s.id;
        _ = try t.drain();
        try t.feed(try t.srv.rst(id, .refused_stream));
        try expectEqual(.refused_stream, t.rec.closeCode(id).?);
    }
    try expect(t.c.goaway_sent == null);
}

// ---------------------------------------------------------------------------
// GOAWAY, limits, settings

test "h2 client conn: on_goaway_received: streams above last-stream-id close REFUSED_STREAM, and no new ones open" {
    const t = try ready(.{});
    defer t.destroy();
    for (0..3) |_| _ = try t.request(&get, false);
    _ = try t.drain();
    try t.feed(try t.srv.goaway(3, .no_error));
    try expectEqual(.refused_stream, t.rec.closeCode(5).?);
    try expect(t.rec.closeCode(1) == null and t.rec.closeCode(3) == null);
    try expectEqual(2, t.c.table.size);
    try expect(!t.c.canOpen());
    try expectError(error.GoawayReceived, t.c.submitRequest(&get, true, null));
    // No RST_STREAM for them: the server already let them go.
    try expectFrames(try t.drain(), &.{});
    // Late frames on 5 are ignored; 1 and 3 finish.
    try t.head(5, &ok, true);
    try t.head(1, &ok, true);
    try expectEqual(.half_closed_remote, t.c.table.get(1).?.state);
    try expectEqual(2, t.c.table.size);
    // A lower last-stream-id is fine; a higher one is not.
    try t.feed(try t.srv.goaway(1, .no_error));
    try expectEqual(.refused_stream, t.rec.closeCode(3).?);
    try expectError(error.ConnectionError, t.feed(try t.srv.goaway(3, .no_error)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 client conn: a GOAWAY whose last-stream-id is the server's parity is a connection error" {
    const t = try ready(.{});
    defer t.destroy();
    _ = try t.request(&get, true);
    _ = try t.drain();
    try expectError(error.ConnectionError, t.feed(try t.srv.goaway(2, .no_error)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 client conn: max_concurrent_streams: 100 until the server's SETTINGS, then its value, and a closed stream makes room" {
    const t = try CT.create(testing.allocator, .{});
    defer t.destroy();
    for (0..conn.client_initial_peer_streams) |_| _ = try t.request(&get, false);
    try expectError(error.StreamLimit, t.c.submitRequest(&get, true, null));
    try t.handshake(&.{.{ .id = .max_concurrent_streams, .value = 101 }});
    _ = try t.request(&get, false);
    try expectError(error.StreamLimit, t.c.submitRequest(&get, true, null));
    try t.head(1, &ok, true);
    // Still open: our half isn't ended.
    try expect(!t.c.canOpen());
    try t.c.submitData(t.c.table.get(1).?, &.{}, true);
    _ = try t.drain();
    try expect(t.c.canOpen());
    const s = try t.request(&get, true);
    try expectEqual(203, s.id);
}

test "h2 client conn: the server's SETTINGS_INITIAL_WINDOW_SIZE moves open streams' send windows" {
    const t = try CT.create(testing.allocator, .{});
    defer t.destroy();
    const s = try t.request(&ct.post, false);
    try expectEqual(conn.default_window, s.send_window);
    try t.handshake(&.{.{ .id = .initial_window_size, .value = 100 }});
    try expectEqual(100, s.send_window);
    const bytes: [150]u8 = @splat('x');
    const body = [_][]const u8{&bytes};
    try t.c.submitData(s, &body, true);
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .data, .id = 1, .flags = 0 }});
    try expectEqual(100, out[0].data.len);
    try t.feed(try t.srv.settings(&.{.{ .id = .initial_window_size, .value = 200 }}));
    const more = try t.drain();
    try expectFrames(more, &.{ .{ .type = .settings, .flags = F.ack }, .{ .type = .data, .id = 1, .flags = F.end_stream } });
    try expectEqual(50, more[1].data.len);
}

test "h2 client conn: a server enabling push is a connection error" {
    const t = try CT.create(testing.allocator, .{});
    defer t.destroy();
    _ = try t.drain();
    try expectError(error.ConnectionError, t.feed(try t.srv.settings(&.{.{ .id = .enable_push, .value = 1 }})));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 client conn: stream IDs run out at 2^31-1" {
    const t = try ready(.{});
    defer t.destroy();
    t.c.last_sent = std.math.maxInt(u31) - 2;
    const s = try t.request(&get, true);
    try expectEqual(std.math.maxInt(u31), s.id);
    try expectError(error.StreamIdsExhausted, t.c.submitRequest(&get, true, null));
}

test "h2 client conn: a request head too large to send is refused and opens no stream" {
    const t = try ready(.{});
    defer t.destroy();
    // '~' is longer in Huffman than raw, so the literal is raw.
    const big = try t.arena().alloc(u8, conn.max_headers_len + 10);
    @memset(big, '~');
    const hdrs = [_]Field{ get[0], get[1], get[2], get[3], .{ .name = "x-big", .value = big } };
    try expectError(error.HeadersTooLarge, t.c.submitRequest(&hdrs, true, null));
    try expectEqual(0, t.c.table.size);
    const s = try t.request(&get, true);
    try expectEqual(1, s.id);
}

test "h2 client conn: recv_headers_early_response: the response ends while the request body is still going" {
    const t = try ready(.{});
    defer t.destroy();
    const s = try t.request(&ct.post, false);
    const parts = [_][]const u8{"part"};
    try t.c.submitData(s, &parts, false);
    _ = try t.drain();
    try t.head(1, &ok, true);
    try expectEqual(.half_closed_remote, s.state);
    try expect(t.rec.closeCode(1) == null);
    // Our end closes it (RFC 9113 §8.1 also lets the client stop with
    // RST_STREAM(NO_ERROR); that is the caller's choice).
    try t.c.submitData(s, &.{}, true);
    try expectFrames(try t.drain(), &.{.{ .type = .data, .id = 1, .flags = F.end_stream }});
    try expectEqual(.no_error, t.rec.closeCode(1).?);
}

test "h2 client conn: a GOAWAY of ours, then no new streams" {
    const t = try ready(.{});
    defer t.destroy();
    try t.c.goaway(.no_error, "");
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.no_error)});
    try expectEqual(0, out[0].last_id);
    try expectError(error.GoawayReceived, t.c.submitRequest(&get, true, null));
}

// ---------------------------------------------------------------------------
// Fuzzing

fn fuzzOne(input: []const u8) anyerror!void {
    var peak: ct.Peak = .{ .child = testing.allocator };
    {
        const t = try CT.createSplit(testing.allocator, peak.allocator(), .{ .max_header_list_size = 4096, .initial_window = 1024, .connection_window = 65535 });
        defer t.destroy();
        t.rec.record = false;
        // Three requests, one with a body, before the server's bytes.
        for (0..2) |_| _ = try t.request(&get, true);
        const s = try t.request(&ct.post, false);
        const bytes: [100]u8 = @splat('x');
        const body = [_][]const u8{&bytes};
        try t.c.submitData(s, &body, true);
        if (input.len == 0) return;
        const stride = 1 + @as(usize, input[0] % 64);
        var rest = input[1..];
        while (rest.len > 0) {
            const n = @min(stride, rest.len);
            t.feed(rest[0..n]) catch |err| switch (err) {
                error.ConnectionError => {
                    _ = try t.drain();
                    break;
                },
                else => return err,
            };
            rest = rest[n..];
            _ = try t.drain();
            const c = &t.c;
            try expect(c.recv_window >= 0 and c.recv_window <= 65535);
            try expect(c.send_window >= 0 and c.send_window <= frame.max_window_size);
            try expect(c.table.size <= 3);
            var i: usize = 0;
            while (c.table.next(&i)) |x| {
                try expect(x.id & 1 == 1 and x.id <= 5);
                // Our window applies once the server acknowledges it; the
                // streams opened before have 65535 until then.
                const window: i64 = if (c.settings_in_flight) conn.default_window else 1024;
                try expect(x.recv_window >= 0 and @as(i64, x.recv_window) + x.recv_unacked <= window);
                try expect(x.state != .closed and x.state != .idle);
            }
        }
    }
    try expect(peak.peak <= 256 * 1024);
    try expectEqual(0, peak.live);
}

fn fuzzSeeds(alloc: Allocator) ![][]u8 {
    var seeds: std.ArrayList([]u8) = .empty;
    errdefer {
        for (seeds.items) |s| alloc.free(s);
        seeds.deinit(alloc);
    }
    const t = try ct.T.create(alloc, .{});
    defer t.destroy();
    const pre = [_][]const u8{ try t.settings(&.{}), try t.settingsAck() };
    const shapes = [_][]const []const u8{
        &.{ try t.headers(1, &ok, false), try t.data(1, "abc", true), try t.headers(3, &status("204"), true) },
        &.{ try t.headers(1, &status("100"), false), try t.headers(1, &ok, false), try t.data(1, "x", false), try t.headers(1, &.{.{ .name = "t", .value = "1" }}, true) },
        &.{ try t.headers(5, &ok, false), try t.windowUpdate(5, 100), try t.goaway(3, .no_error), try t.data(5, "late", true) },
        &.{ try t.rst(3, .refused_stream), try t.headers(3, &ok, true), try t.data(2, "x", false) },
        &.{ try t.headersFrame(1, .{ .end_stream = false, .end_headers = false, .fragment = (try t.block(&ok))[0..1] }), try t.continuation(1, true, (try t.block(&ok))[1..]) },
        &.{ try t.ping(false, @splat(1)), try t.settings(&.{.{ .id = .initial_window_size, .value = 1 }}), try t.windowUpdate(0, 100), try t.pushPromise(1, 2) },
    };
    for (shapes, 0..) |frames, k| {
        var b: std.ArrayList(u8) = .empty;
        errdefer b.deinit(alloc);
        try b.append(alloc, @intCast(k * 7));
        for (pre) |f| try b.appendSlice(alloc, f);
        for (frames) |f| try b.appendSlice(alloc, f);
        try seeds.append(alloc, try b.toOwnedSlice(alloc));
    }
    return seeds.toOwnedSlice(alloc);
}

test "fuzz: h2 client conn recv" {
    const alloc = testing.allocator;
    const seeds = try fuzzSeeds(alloc);
    defer {
        for (seeds) |s| alloc.free(s);
        alloc.free(seeds);
    }
    try fuzz.bytes(fuzzOne, seeds);
}
