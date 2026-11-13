// Tests translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// tests/nghttp2_session_test.c. See LICENSE.nghttp2 and THIRD_PARTY_NOTICES.

//! Tests for conn.zig. The ones named after an nghttp2 session test
//! (`h2 conn: <name>`, without its test_nghttp2_ prefix) port its
//! server-side scenario to the Conn API; the port and skip lists are in
//! research/s2/h2-m2/conn.md. Every test drains `out` and re-parses each
//! frame with frame.parse (`T.drain`).

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const conn = @import("conn.zig");
const fuzz = @import("../fuzz.zig");
const out_mod = @import("out.zig");

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

// ---------------------------------------------------------------------------
// The harness

pub const Event = union(enum) {
    open: u31,
    field: struct { id: u31, name: []const u8, value: []const u8, trailer: bool },
    end: struct { id: u31, end_stream: bool, trailers: bool },
    data: struct { id: u31, bytes: []const u8, end_stream: bool },
    close: struct { id: u31, code: ErrorCode },
    window: ?u31,
    goaway: struct { last: u31, code: ErrorCode },
    ping_ack: [8]u8,
};

/// The handler: logs every callback, and answers or fails as told.
pub const Rec = struct {
    gpa: Allocator,
    arena: Allocator,
    c: *C = undefined,
    events: std.ArrayList(Event) = .empty,
    record: bool = true,
    /// 200 + `body` when a request ends (inside the callback).
    answer: bool = false,
    body: []const []const u8 = &.{"ok"},
    /// Give DATA credit back at once.
    consume: bool = true,
    fail_open: bool = false,
    fail_field: ?[]const u8 = null,
    fail_end: bool = false,
    fail_data: bool = false,
    /// `reset(s, CANCEL)` from onField.
    reset_in_field: bool = false,

    pub fn log(r: *Rec, e: Event) void {
        if (r.record) r.events.append(r.gpa, e) catch @panic("OOM");
    }

    pub fn dupe(r: *Rec, b: []const u8) []const u8 {
        return if (r.record) r.arena.dupe(u8, b) catch @panic("OOM") else "";
    }

    pub fn onStreamOpen(r: *Rec, s: *Stream) conn.Error!void {
        r.log(.{ .open = s.id });
        if (r.fail_open) return error.ResetStream;
    }

    pub fn onField(r: *Rec, s: *Stream, name: []const u8, value: []const u8) conn.Error!void {
        r.log(.{ .field = .{ .id = s.id, .name = r.dupe(name), .value = r.dupe(value), .trailer = s.flags.in_trailers } });
        if (r.reset_in_field) r.c.reset(s, .cancel) catch @panic("OOM");
        if (r.fail_field) |f| if (std.mem.eql(u8, f, name)) return error.ResetStream;
    }

    pub fn onHeadersEnd(r: *Rec, s: *Stream, end_stream: bool) conn.Error!void {
        r.log(.{ .end = .{ .id = s.id, .end_stream = end_stream, .trailers = s.flags.in_trailers } });
        if (r.fail_end) return error.ResetStream;
        if (end_stream and r.answer and s.canSend()) r.respond(s);
    }

    pub fn onData(r: *Rec, s: *Stream, bytes: []const u8, end_stream: bool) conn.Error!void {
        r.log(.{ .data = .{ .id = s.id, .bytes = r.dupe(bytes), .end_stream = end_stream } });
        if (r.consume) r.c.consumed(s, bytes.len) catch @panic("OOM");
        if (r.fail_data) return error.ResetStream;
        if (end_stream and r.answer and s.canSend()) r.respond(s);
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

    pub fn respond(r: *Rec, s: *Stream) void {
        r.c.submitHead(s, 200, &.{}, false) catch @panic("submitHead");
        r.c.submitData(s, r.body, true) catch @panic("submitData");
    }

    pub fn count(r: *const Rec, comptime tag: std.meta.Tag(Event)) usize {
        var n: usize = 0;
        for (r.events.items) |e| {
            if (e == tag) n += 1;
        }
        return n;
    }

    pub fn closeCode(r: *const Rec, id: u31) ?ErrorCode {
        for (r.events.items) |e| switch (e) {
            .close => |x| if (x.id == id) return x.code,
            else => {},
        };
        return null;
    }
};

pub const C = conn.Conn(.server, Rec);

/// One frame we sent, re-parsed (HEADERS with its CONTINUATIONs, decoded).
pub const OutFrame = struct {
    type: frame.Type,
    flags: u8,
    id: u31,
    /// RST_STREAM's or GOAWAY's.
    code: ?ErrorCode = null,
    inc: u31 = 0,
    last_id: u31 = 0,
    data: []const u8 = "",
    fields: []const Field = &.{},
    settings: []const frame.Setting = &.{},
    /// HEADERS frames in the block (1 + CONTINUATIONs).
    frames: usize = 1,
};

pub const T = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    rec: Rec,
    c: C,
    scratch: []u8,
    inbuf: std.ArrayList(u8) = .empty,
    outbuf: std.ArrayList(u8) = .empty,
    bytewise: bool = false,
    /// The client's HPACK: our blocks decoded, its own encoded.
    dec: hpack.Decoder = .init(.{}),
    enc: hpack.Encoder = .{},
    now: u64 = 1,

    pub fn create(gpa: Allocator, opts: conn.Options) !*T {
        return createSplit(gpa, gpa, opts);
    }

    /// Conn's allocations on `conn_gpa`, the harness's on `gpa`.
    pub fn createSplit(gpa: Allocator, conn_gpa: Allocator, opts: conn.Options) !*T {
        const t = try gpa.create(T);
        errdefer gpa.destroy(t);
        t.* = .{
            .gpa = gpa,
            .arena_state = .init(gpa),
            .rec = undefined,
            .c = undefined,
            .scratch = undefined,
        };
        t.rec = .{ .gpa = gpa, .arena = t.arena_state.allocator() };
        t.scratch = try gpa.alloc(u8, @max(opts.max_header_list_size, hpack.table_capacity));
        errdefer gpa.free(t.scratch);
        t.c = try C.init(conn_gpa, &t.rec, opts);
        t.rec.c = &t.c;
        return t;
    }

    pub fn destroy(t: *T) void {
        t.c.deinit();
        t.rec.events.deinit(t.gpa);
        t.inbuf.deinit(t.gpa);
        t.outbuf.deinit(t.gpa);
        t.gpa.free(t.scratch);
        t.arena_state.deinit();
        t.gpa.destroy(t);
    }

    pub fn arena(t: *T) Allocator {
        return t.arena_state.allocator();
    }

    /// Feeds client bytes (one at a time when `bytewise`), keeping what
    /// recv leaves, as the engine's reader does.
    pub fn feed(t: *T, bytes: []const u8) !void {
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

    pub fn pump(t: *T) !void {
        const n = try t.c.recv(t.inbuf.items, t.now, t.scratch);
        std.debug.assert(n <= t.inbuf.items.len);
        const rest = t.inbuf.items.len - n;
        std.mem.copyForwards(u8, t.inbuf.items[0..rest], t.inbuf.items[n..]);
        t.inbuf.items.len = rest;
    }

    /// Takes everything Conn has to send (pending/advance in rounds, as a
    /// writer would) and parses it frame by frame.
    pub fn drain(t: *T) ![]OutFrame {
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
        var list: std.ArrayList(OutFrame) = .empty;
        var rest = t.outbuf.items;
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
                    var whole: std.ArrayList(u8) = .empty;
                    try whole.appendSlice(t.arena(), hd.fragment);
                    var end = hd.end_headers;
                    while (!end) {
                        const g = switch (frame.parse(rest, .{ .max_frame_size = frame.max_max_frame_size })) {
                            .frame => |g| g,
                            else => return error.BadOutputFrame,
                        };
                        try expectEqual(frame.Type.continuation, g.parsed.header.type);
                        try expectEqual(h.stream_id, g.parsed.header.stream_id);
                        rest = rest[g.len..];
                        try whole.appendSlice(t.arena(), g.parsed.frame.continuation.fragment);
                        end = g.parsed.frame.continuation.end_headers;
                        o.frames += 1;
                    }
                    o.fields = try t.decode(whole.items);
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
                    o.data = try t.arena().dupe(u8, g.debug);
                },
                .window_update => |inc| o.inc = inc,
                else => return error.UnexpectedOutputFrame,
            }
            try list.append(t.arena(), o);
        }
        t.outbuf.clearRetainingCapacity();
        return list.items;
    }

    pub fn decode(t: *T, bytes: []const u8) ![]const Field {
        var scratch: [65536]u8 = undefined;
        var blk = t.dec.block(bytes, &scratch, scratch.len);
        var l: std.ArrayList(Field) = .empty;
        while (try blk.next()) |f| try l.append(t.arena(), .{ .name = try t.arena().dupe(u8, f.name), .value = try t.arena().dupe(u8, f.value) });
        return l.items;
    }

    /// The client preface, an empty SETTINGS and the ACK of ours; our
    /// SETTINGS, WINDOW_UPDATE and SETTINGS ACK drained and checked.
    pub fn handshake(t: *T) !void {
        try t.feed(conn.client_magic);
        try t.feed(try t.settings(&.{}));
        try t.feed(try t.settingsAck());
        const out = try t.drain();
        try expect(out.len >= 2);
        try expectEqual(frame.Type.settings, out[0].type);
        try expectEqual(0, out[0].flags);
        try expectEqual(frame.Type.settings, out[out.len - 1].type);
        try expectEqual(F.ack, out[out.len - 1].flags);
    }

    // The client's frames.

    pub fn settings(t: *T, entries: []const frame.Setting) ![]const u8 {
        const b = try t.arena().alloc(u8, 9 + 6 * entries.len);
        return b[0..frame.writeSettings(b, false, entries)];
    }

    pub fn settingsAck(t: *T) ![]const u8 {
        const b = try t.arena().alloc(u8, 9);
        return b[0..frame.writeSettings(b, true, &.{})];
    }

    pub fn block(t: *T, fs: []const Field) ![]const u8 {
        const b = try t.arena().alloc(u8, hpack.Encoder.bound(fs));
        return b[0..try t.enc.encode(b, fs)];
    }

    pub fn headers(t: *T, id: u31, fs: []const Field, end_stream: bool) ![]const u8 {
        return t.headersFrame(id, .{ .end_stream = end_stream, .end_headers = true, .fragment = try t.block(fs) });
    }

    pub fn headersFrame(t: *T, id: u31, hd: frame.Headers) ![]const u8 {
        const b = try t.arena().alloc(u8, 9 + 6 + 256 + hd.fragment.len);
        return b[0..frame.writeHeaders(b, id, hd)];
    }

    pub fn continuation(t: *T, id: u31, end_headers: bool, fragment: []const u8) ![]const u8 {
        const b = try t.arena().alloc(u8, 9 + fragment.len);
        return b[0..frame.writeContinuation(b, id, end_headers, fragment)];
    }

    pub fn data(t: *T, id: u31, bytes: []const u8, end_stream: bool) ![]const u8 {
        return t.dataPadded(id, bytes, end_stream, null);
    }

    pub fn dataPadded(t: *T, id: u31, bytes: []const u8, end_stream: bool, pad: ?u8) ![]const u8 {
        const p: usize = if (pad) |x| x else 0;
        const b = try t.arena().alloc(u8, 10 + bytes.len + p);
        var n = frame.writeData(b, id, end_stream, bytes.len, pad);
        @memcpy(b[n..][0..bytes.len], bytes);
        n += bytes.len;
        @memset(b[n..][0..p], 0);
        return b[0 .. n + p];
    }

    pub fn rst(t: *T, id: u31, code: ErrorCode) ![]const u8 {
        const b = try t.arena().alloc(u8, 13);
        return b[0..frame.writeRstStream(b, id, code)];
    }

    pub fn windowUpdate(t: *T, id: u31, inc: u31) ![]const u8 {
        const b = try t.arena().alloc(u8, 13);
        return b[0..frame.writeWindowUpdate(b, id, inc)];
    }

    pub fn ping(t: *T, ack: bool, d: [8]u8) ![]const u8 {
        const b = try t.arena().alloc(u8, 17);
        return b[0..frame.writePing(b, ack, d)];
    }

    pub fn priority(t: *T, id: u31, dep: u31) ![]const u8 {
        const b = try t.arena().alloc(u8, 14);
        return b[0..frame.writePriority(b, id, .{ .exclusive = false, .dependency = dep, .weight = 15 })];
    }

    pub fn goaway(t: *T, last: u31, code: ErrorCode) ![]const u8 {
        const b = try t.arena().alloc(u8, 17);
        return b[0..frame.writeGoaway(b, last, code, "")];
    }

    pub fn raw(t: *T, ty: u8, fl: u8, id: u31, payload: []const u8) ![]const u8 {
        const b = try t.arena().alloc(u8, 9 + payload.len);
        _ = frame.writeHeader(b, .{ .length = @intCast(payload.len), .type = @fromBackingInt(ty), .flags = fl, .stream_id = id });
        @memcpy(b[9..], payload);
        return b;
    }

    pub fn pushPromise(t: *T, id: u31, promised: u31) ![]const u8 {
        const b = try t.arena().alloc(u8, 64);
        return b[0..frame.writePushPromise(b, id, .{ .end_headers = true, .promised_id = promised, .fragment = try t.block(&get) })];
    }

    pub fn stream(t: *T, id: u31) *Stream {
        return t.c.table.get(id).?;
    }
};

pub const get = [_]Field{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":authority", .value = "example.org" },
};

pub const post = [_]Field{
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":path", .value = "/up" },
    .{ .name = ":authority", .value = "example.org" },
};

pub fn postLen(comptime n: []const u8) [5]Field {
    return post ++ [_]Field{.{ .name = "content-length", .value = n }};
}

/// What a frame must be; null fields aren't checked.
pub const Want = struct {
    type: frame.Type,
    id: ?u31 = null,
    code: ?ErrorCode = null,
    flags: ?u8 = null,
};

pub fn expectFrames(got: []const OutFrame, want: []const Want) !void {
    errdefer {
        std.debug.print("got {d} frames:\n", .{got.len});
        for (got) |g| std.debug.print("  {t} id={d} flags={x} code={any}\n", .{ g.type, g.id, g.flags, g.code });
    }
    try expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try expectEqual(w.type, g.type);
        if (w.id) |id| try expectEqual(id, g.id);
        if (w.code) |code| try expectEqual(code, g.code.?);
        if (w.flags) |fl| try expectEqual(fl, g.flags);
    }
}

pub fn goawayWith(code: ErrorCode) Want {
    return .{ .type = .goaway, .code = code };
}

pub fn rstWith(id: u31, code: ErrorCode) Want {
    return .{ .type = .rst_stream, .id = id, .code = code };
}

/// A connection after the handshake.
pub fn ready(opts: conn.Options) !*T {
    const t = try T.create(testing.allocator, opts);
    errdefer t.destroy();
    try t.handshake();
    return t;
}

/// The test body once with whole inputs and once byte by byte.
fn both(comptime body: fn (bool) anyerror!void) !void {
    try body(false);
    try body(true);
}

pub fn readyAs(bytewise: bool) !*T {
    const t = try ready(.{});
    t.bytewise = bytewise;
    return t;
}

// ---------------------------------------------------------------------------
// PLAN §5.2: the fork patch's RFC 9113 behaviours (its
// test_nghttp2_session_anole_strict_frames and the
// on_data_received_fail_fast hunks)

test "h2: DATA after the peer's RST_STREAM answers STREAM_CLOSED" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try t.feed(try t.headers(1, &post, false));
            try t.feed(try t.rst(1, .cancel));
            try expectEqual(ErrorCode.cancel, t.rec.closeCode(1).?);
            try t.feed(try t.data(1, "late", false));
            try expectFrames(try t.drain(), &.{rstWith(1, .stream_closed)});
            // The payload was ignored; the connection lives.
            try expectEqual(0, t.rec.count(.data));
            try t.feed(try t.headers(3, &get, true));
            try expectEqual(2, t.rec.count(.open));
        }
    }.f);
}

// The answer is a *connection* error STREAM_CLOSED, as the fork, stock
// nghttp2 and the diff harness give (RFC 9113 §5.1 allows it for closed
// streams; nghttp2 goes further for half-closed(remote) too). The name is
// PLAN's; the lead keeps or renames it (research/s2/h2-m2/conn.md, #2).
test "h2: frames after the peer's END_STREAM answer STREAM_CLOSED (stream error)" {
    try both(struct {
        fn f(bw: bool) !void {
            // Half-closed (remote): DATA, then HEADERS.
            inline for (.{ false, true }) |hdrs| {
                const t = try readyAs(bw);
                defer t.destroy();
                try t.feed(try t.headers(1, &get, true));
                const late = if (hdrs) try t.headers(1, &.{.{ .name = "x", .value = "y" }}, true) else try t.data(1, "x", false);
                try expectError(error.ConnectionError, t.feed(late));
                try expectFrames(try t.drain(), &.{goawayWith(.stream_closed)});
            }
            // Closed after END_STREAM both ways: remembered as PEER_END.
            inline for (.{ false, true }) |hdrs| {
                const t = try readyAs(bw);
                defer t.destroy();
                t.rec.answer = true;
                try t.feed(try t.headers(1, &get, true));
                _ = try t.drain();
                try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
                const late = if (hdrs) try t.headers(1, &.{.{ .name = "x", .value = "y" }}, true) else try t.data(1, "x", false);
                try expectError(error.ConnectionError, t.feed(late));
                try expectFrames(try t.drain(), &.{goawayWith(.stream_closed)});
            }
        }
    }.f);
}

test "h2: request HEADERS on a lower never-opened stream ID is a connection PROTOCOL_ERROR" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try t.feed(try t.headers(5, &get, false));
            try expectError(error.ConnectionError, t.feed(try t.headers(3, &get, false)));
            const out = try t.drain();
            try expectFrames(out, &.{goawayWith(.protocol_error)});
            try expectEqual(5, out[0].last_id);
            // So is DATA on it (the fork's fail-fast: NEVER_OPENED is
            // STREAM_CLOSED there).
            const u = try readyAs(bw);
            defer u.destroy();
            try u.feed(try u.headers(5, &get, false));
            try expectError(error.ConnectionError, u.feed(try u.data(3, "x", false)));
            try expectFrames(try u.drain(), &.{goawayWith(.stream_closed)});
        }
    }.f);
}

test "h2: frames on a stream this endpoint reset are ignored (in-flight crossing)" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try t.feed(try t.headers(1, &post, false));
            try t.c.reset(t.stream(1), .cancel);
            try expectFrames(try t.drain(), &.{rstWith(1, .cancel)});
            const before = t.c.recv_unacked;
            try t.feed(try t.data(1, "in flight", false));
            try t.feed(try t.headers(1, &.{.{ .name = "x-trailer", .value = "1" }}, true));
            try t.feed(try t.windowUpdate(1, 100));
            try t.feed(try t.rst(1, .cancel));
            try expectFrames(try t.drain(), &.{});
            // The ignored DATA was charged to the connection window and
            // consumed at once.
            try expectEqual(before + 9, t.c.recv_unacked);
            try expectEqual(0, t.rec.count(.data));
        }
    }.f);
}

test "h2: frames on a stream no longer remembered are ignored" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            t.rec.record = false;
            t.rec.answer = true;
            // Stream 1 closes; 256 more closes push it out of the ring.
            var id: u31 = 1;
            while (id <= 1 + 2 * 256) : (id += 2) {
                try t.feed(try t.headers(id, &get, true));
                _ = try t.drain();
            }
            try t.feed(try t.data(1, "x", false));
            try t.feed(try t.headers(1, &.{.{ .name = "x", .value = "y" }}, true));
            try t.feed(try t.priority(1, 0));
            try expectFrames(try t.drain(), &.{});
        }
    }.f);
}

test "h2: PRIORITY on stream 0 is a connection PROTOCOL_ERROR" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try expectError(error.ConnectionError, t.feed(try t.priority(0, 1)));
            try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
        }
    }.f);
}

test "h2: PRIORITY with a self-dependency is a PROTOCOL_ERROR (connection error on an idle stream)" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try t.feed(try t.headers(1, &post, false));
            try t.feed(try t.priority(1, 1));
            try expectFrames(try t.drain(), &.{rstWith(1, .protocol_error)});
            try expectEqual(ErrorCode.protocol_error, t.rec.closeCode(1).?);
            // A PRIORITY on another stream is only validated.
            try t.feed(try t.priority(3, 1));
            try expectFrames(try t.drain(), &.{});
            // Idle: no RST_STREAM may go there.
            try expectError(error.ConnectionError, t.feed(try t.priority(7, 7)));
            try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
        }
    }.f);
}

test "h2: stream window overflow (WINDOW_UPDATE past 2^31-1) is a stream FLOW_CONTROL_ERROR" {
    try both(struct {
        fn f(bw: bool) !void {
            const t = try readyAs(bw);
            defer t.destroy();
            try t.feed(try t.headers(1, &get, false));
            try t.feed(try t.windowUpdate(1, frame.max_window_size - 65535));
            try expectFrames(try t.drain(), &.{});
            try t.feed(try t.windowUpdate(1, 1));
            try expectFrames(try t.drain(), &.{rstWith(1, .flow_control_error)});
            // The connection lives; its own overflow is a connection error.
            try t.feed(try t.windowUpdate(0, frame.max_window_size - 65535));
            try expectError(error.ConnectionError, t.feed(try t.windowUpdate(0, 1)));
            try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
        }
    }.f);
}

// ---------------------------------------------------------------------------
// The handshake and the stream state table

test "h2 conn: preface and SETTINGS handshake" {
    {
        const t = try T.create(testing.allocator, .{});
        defer t.destroy();
        // Ours first: SETTINGS, then the connection window.
        const first = try t.drain();
        try expectFrames(first, &.{ .{ .type = .settings, .flags = 0 }, .{ .type = .window_update, .id = 0 } });
        try expectEqual(16 * 1024 * 1024 - 65535, first[1].inc);
        const want = [_]frame.Setting{
            .{ .id = .max_concurrent_streams, .value = 250 },
            .{ .id = .initial_window_size, .value = 65536 },
            .{ .id = .max_header_list_size, .value = 65536 },
            .{ .id = .no_rfc7540_priorities, .value = 1 },
        };
        try testing.expectEqualDeep(@as([]const frame.Setting, &want), first[0].settings);
        // The client's preface split anywhere.
        t.bytewise = true;
        try t.feed(conn.client_magic);
        try t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 1000 }}));
        try expectFrames(try t.drain(), &.{.{ .type = .settings, .flags = F.ack }});
        try expectEqual(1000, t.c.remote.initial_window);
        // Our settings apply at the ACK.
        try expectEqual(65535, t.c.local.initial_window);
        try t.feed(try t.settingsAck());
        try expectEqual(65536, t.c.local.initial_window);
        try expectEqual(250, t.c.local.max_concurrent_streams);
        // A second ACK is unexpected.
        try expectError(error.ConnectionError, t.feed(try t.settingsAck()));
        try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
        try expectError(error.ConnectionError, t.feed(try t.ping(false, @splat(0))));
    }
    // Optional entries: MAX_FRAME_SIZE above the default, CONNECT.
    {
        const t = try T.create(testing.allocator, .{ .max_frame_size = 1 << 16, .enable_connect_protocol = true, .connection_window = 65535 });
        defer t.destroy();
        const first = try t.drain();
        try expectFrames(first, &.{.{ .type = .settings }});
        try expectEqual(6, first[0].settings.len);
        try expectEqual(frame.SettingId.max_frame_size, first[0].settings[3].id);
        try expectEqual(frame.SettingId.enable_connect_protocol, first[0].settings[4].id);
    }
    // Bad magic, the first frame not SETTINGS, an ACK first.
    {
        const t = try T.create(testing.allocator, .{});
        defer t.destroy();
        _ = try t.drain();
        try expectError(error.BadPreface, t.feed("PRI * HTTP/1.1\r\n"));
        try expectFrames(try t.drain(), &.{});
    }
    inline for (.{ false, true }) |ack| {
        const t = try T.create(testing.allocator, .{});
        defer t.destroy();
        _ = try t.drain();
        try t.feed(conn.client_magic);
        const first = if (ack) try t.settingsAck() else try t.ping(false, @splat(1));
        try expectError(error.ConnectionError, t.feed(first));
        const out = try t.drain();
        try expectFrames(out, &.{goawayWith(.protocol_error)});
        try expectEqualStrings("SETTINGS expected", out[0].data);
    }
}

const Shape = enum { idle, open, half_closed_remote, half_closed_local, closed_end_stream, rst_received, rst_sent, never_opened, forgotten };
const Probe = enum { data, headers, priority_self, rst_stream, window_update, continuation, push_promise, unknown };
const Answer = union(enum) { none, rst: ErrorCode, goaway: ErrorCode };

/// nghttp2's (and the fork's) answer for each probe on stream 5 in each
/// state: HEADERS carries a trailer-only block with END_STREAM, PRIORITY
/// depends on itself.
fn expected(shape: Shape, probe: Probe) Answer {
    return switch (probe) {
        .data => switch (shape) {
            .idle => .{ .goaway = .protocol_error },
            .open, .half_closed_local, .rst_sent, .forgotten => .none,
            .half_closed_remote, .closed_end_stream, .never_opened => .{ .goaway = .stream_closed },
            .rst_received => .{ .rst = .stream_closed },
        },
        .headers => switch (shape) {
            // A request without its pseudo-headers.
            .idle => .{ .rst = .protocol_error },
            .open, .half_closed_local, .rst_sent, .forgotten => .none,
            .half_closed_remote, .closed_end_stream => .{ .goaway = .stream_closed },
            .rst_received => .{ .rst = .stream_closed },
            .never_opened => .{ .goaway = .protocol_error },
        },
        .priority_self => if (shape == .idle) .{ .goaway = .protocol_error } else .{ .rst = .protocol_error },
        .rst_stream, .window_update => if (shape == .idle) .{ .goaway = .protocol_error } else .none,
        .continuation, .push_promise => .{ .goaway = .protocol_error },
        .unknown => .none,
    };
}

test "h2 conn: every frame on every stream state" {
    inline for (std.meta.tags(Shape)) |shape| {
        inline for (std.meta.tags(Probe)) |probe| {
            const t = try ready(.{});
            defer t.destroy();
            t.rec.record = shape != .forgotten;
            switch (shape) {
                .idle => {},
                .open => try t.feed(try t.headers(5, &post, false)),
                .half_closed_remote => try t.feed(try t.headers(5, &get, true)),
                .half_closed_local => {
                    try t.feed(try t.headers(5, &post, false));
                    try t.c.submitHead(t.stream(5), 204, &.{}, true);
                },
                .closed_end_stream => {
                    try t.feed(try t.headers(5, &post, false));
                    try t.c.submitHead(t.stream(5), 204, &.{}, true);
                    try t.feed(try t.data(5, "", true));
                },
                .rst_received => {
                    try t.feed(try t.headers(5, &post, false));
                    try t.feed(try t.rst(5, .cancel));
                },
                .rst_sent => {
                    try t.feed(try t.headers(5, &post, false));
                    try t.c.reset(t.stream(5), .cancel);
                },
                .never_opened => try t.feed(try t.headers(7, &get, false)),
                .forgotten => {
                    t.rec.answer = true;
                    try t.feed(try t.headers(5, &get, true));
                    _ = try t.drain();
                    var id: u31 = 7;
                    while (id < 7 + 2 * 256) : (id += 2) {
                        try t.feed(try t.headers(id, &get, true));
                        _ = try t.drain();
                    }
                },
            }
            _ = try t.drain();
            const st = t.c.table.get(5);
            switch (shape) {
                .open => try expectEqual(streams_state.open, st.?.state),
                .half_closed_remote => try expectEqual(streams_state.half_closed_remote, st.?.state),
                .half_closed_local => try expectEqual(streams_state.half_closed_local, st.?.state),
                else => try expect(st == null),
            }
            const bytes = switch (probe) {
                .data => try t.data(5, "x", false),
                .headers => try t.headers(5, &.{.{ .name = "x-t", .value = "1" }}, true),
                .priority_self => try t.priority(5, 5),
                .rst_stream => try t.rst(5, .cancel),
                .window_update => try t.windowUpdate(5, 1),
                .continuation => try t.continuation(5, true, ""),
                .push_promise => try t.pushPromise(5, 2),
                .unknown => try t.raw(0x20, 0, 5, "abc"),
            };
            const want = expected(shape, probe);
            switch (want) {
                .goaway => |code| {
                    try expectError(error.ConnectionError, t.feed(bytes));
                    try expectFrames(try t.drain(), &.{goawayWith(code)});
                },
                .rst => |code| {
                    try t.feed(bytes);
                    try expectFrames(try t.drain(), &.{rstWith(5, code)});
                },
                .none => {
                    try t.feed(bytes);
                    try expectFrames(try t.drain(), &.{});
                },
            }
        }
    }
}

const streams_state = @import("streams.zig").State;

// ---------------------------------------------------------------------------
// Header blocks

test "h2 conn: CONTINUATION assembly" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    const t = try T.createSplit(testing.allocator, counting.allocator(), .{});
    defer t.destroy();
    try t.handshake();
    const blk = try t.block(&get ++ [_]Field{ .{ .name = "x-a", .value = "aaaaaaaa" }, .{ .name = "x-b", .value = "bbbbbbbb" } });
    // Warm the stream slab and table with a first stream.
    try t.feed(try t.headers(1, &get, true));
    const frames = [_][]const u8{
        try t.headersFrame(3, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..5] }),
        try t.continuation(3, false, blk[5..9]),
        try t.continuation(3, false, ""),
        try t.continuation(3, true, blk[9..]),
    };
    const live = counting.allocated_bytes - counting.freed_bytes;
    try t.feed(frames[0]);
    try expect(t.c.block != null);
    try t.feed(frames[1]);
    try t.feed(frames[2]);
    try t.feed(frames[3]);
    try expect(t.c.block == null);
    // The assembly buffer is gone again.
    try expectEqual(live, counting.allocated_bytes - counting.freed_bytes);
    var n: usize = 0;
    for (t.rec.events.items) |e| switch (e) {
        .field => |x| if (x.id == 3) {
            n += 1;
        },
        else => {},
    };
    try expectEqual(6, n);
    try expectFrames(try t.drain(), &.{});
    // Another frame in the middle of a block ends the connection.
    try t.feed(try t.headersFrame(5, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..5] }));
    try expectError(error.ConnectionError, t.feed(try t.ping(false, @splat(0))));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqualStrings("unexpected non-CONTINUATION frame or stream_id is invalid", out[0].data);
}

test "h2 conn: a single-frame block allocates nothing" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    const t = try T.createSplit(testing.allocator, counting.allocator(), .{});
    defer t.destroy();
    try t.handshake();
    try t.feed(try t.headers(1, &get, true));
    const in = [_][]const u8{
        try t.headers(3, &get ++ [_]Field{.{ .name = "user-agent", .value = "test" }}, true),
        try t.headers(5, &post, false),
        try t.data(5, "body", true),
    };
    const before = counting.allocations;
    for (in) |b| try t.feed(b);
    try expectEqual(before, counting.allocations);
    try expectEqual(3, t.rec.count(.open));
}

test "h2 conn: block bytes over max_header_list_size and too many CONTINUATIONs" {
    {
        const t = try ready(.{ .max_header_list_size = 4096 });
        defer t.destroy();
        // '~' doesn't shrink with Huffman: the block is as long as the list.
        const big = @as([3000]u8, @splat('~'));
        const blk = try t.block(&get ++ [_]Field{ .{ .name = "x-a", .value = &big }, .{ .name = "x-b", .value = &big } });
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..3000] }));
        try expectError(error.ConnectionError, t.feed(try t.continuation(1, true, blk[3000..])));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
    {
        const t = try ready(.{ .max_continuations = 2 });
        defer t.destroy();
        const blk = try t.block(&get);
        try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..1] }));
        try t.feed(try t.continuation(1, false, blk[1..2]));
        try t.feed(try t.continuation(1, false, blk[2..3]));
        try expectError(error.ConnectionError, t.feed(try t.continuation(1, true, blk[3..])));
        try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
    }
}

test "h2 conn: a header list over the limit is refused" {
    const t = try ready(.{ .max_header_list_size = 4096 });
    defer t.destroy();
    // 4247 bytes decoded from a block under 4096.
    const big = @as([2000]u8, @splat('~'));
    try t.feed(try t.headers(1, &get ++ [_]Field{ .{ .name = "x-a", .value = &big }, .{ .name = "x-b", .value = &big } }, true));
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .headers, .id = 1, .flags = F.end_stream | F.end_headers }});
    try expectEqualStrings("431", out[0].fields[0].value);
    try expectEqual(0, t.rec.count(.end));
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(1, t.rec.count(.end));
}

test "h2 conn: content-length" {
    // Over, under at END_STREAM, exact, and a plain CONNECT (no length).
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.headers(1, &postLen("3"), false));
        try t.feed(try t.data(1, "abcd", true));
        try expectFrames(try t.drain(), &.{rstWith(1, .protocol_error)});
        try t.feed(try t.headers(3, &postLen("3"), false));
        try t.feed(try t.data(3, "ab", true));
        try expectFrames(try t.drain(), &.{rstWith(3, .protocol_error)});
        try t.feed(try t.headers(5, &postLen("3"), false));
        try t.feed(try t.data(5, "ab", false));
        try t.feed(try t.data(5, "c", true));
        try expectFrames(try t.drain(), &.{});
        try expectEqual(streams_state.half_closed_remote, t.stream(5).state);
        // HEADERS with END_STREAM and a length > 0.
        try t.feed(try t.headers(7, &postLen("1"), true));
        try expectFrames(try t.drain(), &.{rstWith(7, .protocol_error)});
    }
}

test "h2 conn: trailers" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, "abc", false));
    try t.feed(try t.headers(1, &.{.{ .name = "x-sum", .value = "1" }}, true));
    const ev = t.rec.events.items;
    try expectEqual(Event{ .end = .{ .id = 1, .end_stream = true, .trailers = true } }, ev[ev.len - 1]);
    try expect(ev[ev.len - 2].field.trailer);
    try expectFrames(try t.drain(), &.{});
    // Trailers without END_STREAM, and pseudo-headers in trailers.
    try t.feed(try t.headers(3, &post, false));
    try t.feed(try t.headers(3, &.{.{ .name = "x-sum", .value = "1" }}, false));
    try t.feed(try t.headers(5, &post, false));
    try t.feed(try t.headers(5, &.{.{ .name = ":path", .value = "/" }}, true));
    try expectFrames(try t.drain(), &.{ rstWith(3, .protocol_error), rstWith(5, .protocol_error) });
}

// ---------------------------------------------------------------------------
// Flow control

test "h2 conn: SETTINGS_INITIAL_WINDOW_SIZE applied to open streams" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(65535, t.stream(1).send_window);
    // Down: windows go negative (RFC 9113 §6.9.2) and DATA waits.
    try t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 10 }}));
    _ = try t.drain();
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{"0123456789abcdef"}, true);
    var out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers }, .{ .type = .data, .flags = 0 } });
    try expectEqual(10, out[1].data.len);
    try expectEqual(0, t.stream(1).send_window);
    try t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 0 }}));
    try expectEqual(-10, t.stream(1).send_window);
    // Up: credit, onWindow(null), and the rest goes.
    try t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 100 }}));
    try expectEqual(Event{ .window = null }, t.rec.events.items[t.rec.events.items.len - 1]);
    out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .settings }, .{ .type = .settings }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqualStrings("abcdef", out[2].data);
    // Past 2^31-1 on any stream: connection FLOW_CONTROL_ERROR.
    try t.feed(try t.windowUpdate(3, frame.max_window_size - 100));
    try expectError(error.ConnectionError, t.feed(try t.settings(&.{.{ .id = .initial_window_size, .value = 101 }})));
    try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
}

test "h2 conn: our INITIAL_WINDOW_SIZE applies at the ACK" {
    const t = try T.create(testing.allocator, .{ .initial_window = 100_000 });
    defer t.destroy();
    _ = try t.drain();
    try t.feed(conn.client_magic);
    try t.feed(try t.settings(&.{}));
    // Before the ACK, the peer may send only 65535.
    try t.feed(try t.headers(1, &post, false));
    try expectEqual(65535, t.stream(1).recv_window);
    try t.feed(try t.settingsAck());
    try expectEqual(100_000, t.stream(1).recv_window);
    _ = try t.drain();
    // And DATA past the stream window is a connection FLOW_CONTROL_ERROR.
    t.rec.consume = false;
    const chunk = @as([16384]u8, @splat(0));
    for (0..6) |_| try t.feed(try t.data(1, &chunk, false));
    try expectError(error.ConnectionError, t.feed(try t.data(1, &chunk, false)));
    try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
}

test "h2 conn: consumed batches WINDOW_UPDATE" {
    const t = try ready(.{ .initial_window = 1000, .connection_window = 65535 });
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, &(@as([600]u8, @splat(1))), false));
    try t.c.consumed(t.stream(1), 400);
    try expectFrames(try t.drain(), &.{});
    // Half the stream window: one WINDOW_UPDATE for all consumed so far.
    try t.c.consumed(t.stream(1), 200);
    var out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    try expectEqual(600, out[0].inc);
    // The connection's at half its window.
    try t.feed(try t.data(1, &(@as([1000]u8, @splat(1))), false));
    try t.c.consumed(t.stream(1), 1000);
    out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    for (0..40) |_| {
        try t.feed(try t.data(1, &(@as([1000]u8, @splat(1))), false));
        try t.c.consumed(t.stream(1), 1000);
    }
    var conn_updates: usize = 0;
    for (try t.drain()) |f| {
        if (f.type == .window_update and f.id == 0) conn_updates += 1;
    }
    try expectEqual(1, conn_updates);
    // None for a stream whose peer half ended.
    try t.feed(try t.data(1, "z", true));
    try t.c.consumed(t.stream(1), 1);
    for (try t.drain()) |f| try expect(f.id == 0);
}

test "h2 conn: raiseWindow sends the difference and moves recv_window" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.consume = false;
    t.rec.record = false;
    try t.feed(try t.headers(1, &post, false));
    const before = t.stream(1).recv_window;
    try t.c.raiseWindow(t.stream(1), 1000);
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    try expectEqual(1000, out[0].inc);
    try expectEqual(before + 1000, t.stream(1).recv_window);
    // The peer may now send the old window and the raise, unconsumed,
    // without a FLOW_CONTROL_ERROR.
    const chunk: [16384]u8 = @splat(7);
    var left: usize = @intCast(before + 1000);
    while (left > 0) {
        const n = @min(left, chunk.len);
        try t.feed(try t.data(1, chunk[0..n], false));
        left -= n;
    }
    try expectFrames(try t.drain(), &.{});
    try expectEqual(0, t.stream(1).recv_window);
    // Once the peer's half ends there is nothing to raise.
    try t.feed(try t.data(1, "", true));
    try t.c.raiseWindow(t.stream(1), 1000);
    try expectFrames(try t.drain(), &.{});
}

test "h2 conn: DATA cut to windows and max_frame_size" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const body = try t.arena().alloc(u8, 40000);
    for (body, 0..) |*b, i| b.* = @truncate(i);
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{ body[0..100], body[100..30000], body[30000..] }, true);
    var out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers }, .{ .type = .data }, .{ .type = .data }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqual(16384, out[1].data.len);
    try expectEqual(16384, out[2].data.len);
    try expectEqual(40000 - 32768, out[3].data.len);
    var joined: std.ArrayList(u8) = .empty;
    for (out[1..]) |f| try joined.appendSlice(t.arena(), f.data);
    try testing.expectEqualSlices(u8, body, joined.items);
    // The peer's larger frames, and the connection window.
    try t.feed(try t.settings(&.{.{ .id = .max_frame_size, .value = 1 << 20 }}));
    try t.feed(try t.headers(3, &get, true));
    try t.c.submitHead(t.stream(3), 200, &.{}, false);
    try t.c.submitData(t.stream(3), &.{body}, true);
    out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .settings }, .{ .type = .headers }, .{ .type = .data } });
    try expectEqual(65535 - 40000, out[2].data.len);
    try expectEqual(0, t.c.send_window);
    try t.feed(try t.windowUpdate(0, 1 << 20));
    out = try t.drain();
    try expectFrames(out, &.{.{ .type = .data, .flags = F.end_stream }});
    try expectEqual(40000 - 25535, out[0].data.len);
}

test "h2 conn: HEADERS split into CONTINUATION at the peer's max_frame_size" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.headers(3, &get, true));
    const v = try t.arena().alloc(u8, 40000);
    @memset(v, '~'); // Huffman doesn't shorten '~'
    const hdrs = [_]Field{ .{ .name = "x-a", .value = v[0..20000] }, .{ .name = "x-b", .value = v[0..20000] } };
    try t.c.submitHead(t.stream(1), 200, &hdrs, true);
    const out = try t.drain();
    // The first frame's flags: END_HEADERS is on the last CONTINUATION.
    try expectFrames(out, &.{.{ .type = .headers, .flags = F.end_stream }});
    try expectEqual(3, out[0].frames);
    try expectEqual(3, out[0].fields.len);
    try expectEqualStrings("200", out[0].fields[0].value);
    try expectEqual(20000, out[0].fields[2].value.len);
    // Over 64 KiB encoded: refused, nothing queued, and the next block
    // still decodes.
    const huge = [_]Field{ .{ .name = "x-a", .value = v }, .{ .name = "x-b", .value = v } };
    try expectError(error.HeadersTooLarge, t.c.submitHead(t.stream(3), 200, &huge, true));
    try expectFrames(try t.drain(), &.{});
    try t.c.submitHead(t.stream(3), 404, &.{}, true);
    const o2 = try t.drain();
    try expectEqualStrings("404", o2[0].fields[0].value);
}

// ---------------------------------------------------------------------------
// Handler errors, GOAWAY, PING

test "h2 conn: handler errors reset the stream" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.fail_open = true;
    try t.feed(try t.headers(1, &get, true));
    t.rec.fail_open = false;
    t.rec.fail_field = ":path";
    try t.feed(try t.headers(3, &get, true));
    t.rec.fail_field = null;
    t.rec.fail_end = true;
    try t.feed(try t.headers(5, &get, true));
    t.rec.fail_end = false;
    t.rec.fail_data = true;
    try t.feed(try t.headers(7, &post, false));
    try t.feed(try t.data(7, "x", false));
    try t.feed(try t.data(7, "y", true));
    // Stream 5's error came after its END_STREAM: still ours to answer, so
    // it was reset too; stream 7's second DATA was ignored.
    try expectFrames(try t.drain(), &.{ rstWith(1, .internal_error), rstWith(3, .internal_error), rstWith(5, .internal_error), rstWith(7, .internal_error) });
    try expectEqual(ErrorCode.internal_error, t.rec.closeCode(1).?);
    try expectEqual(ErrorCode.internal_error, t.rec.closeCode(3).?);
    try expectEqual(ErrorCode.internal_error, t.rec.closeCode(7).?);
    // The rest of a reset stream's block was decoded: the table is in step.
    t.rec.fail_data = false;
    try t.feed(try t.headers(9, &get, true));
    try expectEqual(@as(?ErrorCode, null), t.rec.closeCode(9));
}

test "h2 conn: GOAWAY in and out" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.goaway(0, .no_error));
    try expectEqual(Event{ .goaway = .{ .last = 0, .code = .no_error } }, t.rec.events.items[t.rec.events.items.len - 1]);
    // Ours: the last stream processed; later streams are ignored.
    try t.c.goaway(.no_error, "bye");
    var out = try t.drain();
    try expectFrames(out, &.{goawayWith(.no_error)});
    try expectEqual(1, out[0].last_id);
    try expectEqualStrings("bye", out[0].data);
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(1, t.rec.count(.open));
    // The peer's last stream ID may not be ours-odd, nor rise.
    try expectError(error.ConnectionError, t.feed(try t.goaway(1, .no_error)));
    out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqual(1, out[0].last_id);
}

test "h2 conn: PING ACK" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.ping(false, "abcdefgh".*));
    try t.c.ping("12345678".*);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .ping, .flags = F.ack }, .{ .type = .ping, .flags = 0 } });
    try expectEqualStrings("abcdefgh", out[0].data);
    try t.feed(try t.ping(true, "12345678".*));
    try expectEqual(Event{ .ping_ack = "12345678".* }, t.rec.events.items[t.rec.events.items.len - 1]);
    try expectFrames(try t.drain(), &.{});
}

// ---------------------------------------------------------------------------
// The M2 review's findings

fn connCredit(c: *const C) i64 {
    return @as(i64, c.recv_window) + c.recv_unacked;
}

test "h2 conn: a stream reset over its DATA gives the connection credit back" {
    const t = try ready(.{});
    defer t.destroy();
    const before = connCredit(&t.c);
    // Past the content-length mid-stream, short of it at END_STREAM, and a
    // failing handler (which still gives back what it was given).
    try t.feed(try t.headers(1, &postLen("3"), false));
    try t.feed(try t.data(1, "abcd", false));
    try t.feed(try t.headers(3, &postLen("100"), false));
    try t.feed(try t.data(3, "abcdefgh", true));
    t.rec.fail_data = true;
    try t.feed(try t.headers(5, &post, false));
    try t.feed(try t.data(5, "xyz", false));
    try expectFrames(try t.drain(), &.{ rstWith(1, .protocol_error), rstWith(3, .protocol_error), rstWith(5, .internal_error) });
    try expectEqual(before, connCredit(&t.c));
}

test "h2 conn: a DATA frame past the window is a FLOW_CONTROL_ERROR however the reads cut it" {
    // Found by the session differential (nghttp2's corpus, tight profile):
    // charged per chunk, credit the handler gave back for the frame's first
    // bytes made room for the rest when they arrived a few at a time, and
    // the 2000-byte frame on a 1024-byte window was taken.
    for ([_]bool{ false, true }) |bytewise| {
        const t = try ready(.{ .initial_window = 1024 });
        defer t.destroy();
        t.bytewise = bytewise;
        try t.feed(try t.headers(1, &post, false));
        const big: [2000]u8 = @splat('x');
        try expectError(error.ConnectionError, t.feed(try t.data(1, &big, true)));
        try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
        try expectEqual(0, t.rec.count(.data));
    }
}

test "h2 conn: DATA on a stream this end reset is skipped whole, its padding unchecked" {
    // Found by the session differential: a Pad Length past the payload of
    // such a frame was a connection PROTOCOL_ERROR; nghttp2 ignores the
    // frame before it reads the padding.
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.c.reset(t.stream(1), .cancel);
    try expectFrames(try t.drain(), &.{rstWith(1, .cancel)});
    const before = connCredit(&t.c);
    try t.feed(try t.raw(0, F.padded, 1, "\x08ppppppp"));
    try expectFrames(try t.drain(), &.{});
    try expectEqual(0, t.rec.count(.data));
    try expectEqual(before, connCredit(&t.c));
}

test "h2 conn: interim responses before the final one" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    const s = t.stream(1);
    try t.c.submitHead(s, 100, &.{}, false);
    try t.c.submitHead(s, 103, &.{.{ .name = "link", .value = "</a.css>; rel=preload" }}, false);
    try t.c.submitHead(s, 200, &.{}, false);
    try t.c.submitData(s, &.{"done"}, true);
    try expectError(error.StreamClosed, t.c.submitHead(s, 200, &.{}, false));
    const out = try t.drain();
    try expectFrames(out, &.{
        .{ .type = .headers, .id = 1, .flags = F.end_headers },
        .{ .type = .headers, .id = 1, .flags = F.end_headers },
        .{ .type = .headers, .id = 1, .flags = F.end_headers },
        .{ .type = .data, .id = 1, .flags = F.end_stream },
    });
    try expectEqualStrings("100", out[0].fields[0].value);
    try expectEqualStrings("103", out[1].fields[0].value);
    try expectEqualStrings("link", out[1].fields[1].name);
    try expectEqualStrings("200", out[2].fields[0].value);
    try expectEqualStrings("done", out[3].data);
}

test "h2 conn: out slices stay put while more is queued" {
    // PLAN §3.3: the flush-token holder writes what `pending` returned
    // while the reader and stream tasks queue more.
    var o: out_mod.Out = .init(testing.allocator);
    defer o.deinit();
    const a = try o.writable(100);
    @memset(a, 'a');
    o.commit(100);
    try o.borrow("borrowed");
    var vecs: [4][]const u8 = undefined;
    const v = o.iovecs(&vecs);
    try expectEqual(2, v.len);
    const first = v[0];
    // "The write is in flight": queue several blocks' worth.
    for (0..8) |_| {
        const b = try o.writable(10000);
        @memset(b, 'b');
        o.commit(10000);
    }
    for (first) |x| try expectEqual('a', x);
    try expectEqual(100, first.len);
    o.advance(first.len + v[1].len);
    var sent: usize = 0;
    while (!o.idle()) {
        const w = o.iovecs(&vecs);
        var n: usize = 0;
        for (w) |b| {
            for (b) |x| try expectEqual('b', x);
            n += b.len;
        }
        o.advance(n);
        sent += n;
    }
    try expectEqual(80000, sent);
}

test "h2 conn: running out of memory while framing DATA queues nothing" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const t = try T.createSplit(testing.allocator, failing.allocator(), .{});
    defer t.destroy();
    try t.handshake();
    t.c.out.release();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    // 64 parts: one DATA frame over 64 borrowed segments.
    var parts: [64][]const u8 = undefined;
    for (&parts) |*p| p.* = "x";
    try t.c.submitData(t.stream(1), &parts, true);
    const queued = t.c.out.queued_total;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var vecs: [128][]const u8 = undefined;
    try expectError(error.OutOfMemory, t.c.pending(&vecs));
    try expectEqual(queued, t.c.out.queued_total);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqual(64, out[1].data.len);
}

test "h2 conn: a graceful drain's shutdown notice still admits streams" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.shutdownNotice();
    var out = try t.drain();
    try expectFrames(out, &.{goawayWith(.no_error)});
    try expectEqual(std.math.maxInt(u31), out[0].last_id);
    // A request already in flight is still served.
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(2, t.rec.count(.open));
    try t.c.goaway(.no_error, "");
    out = try t.drain();
    try expectFrames(out, &.{goawayWith(.no_error)});
    try expectEqual(3, out[0].last_id);
    try t.feed(try t.headers(5, &get, true));
    try expectEqual(2, t.rec.count(.open));
}

test "h2 conn: a warm connection's request and response allocate nothing" {
    var counting: testing.FailingAllocator = .init(testing.allocator, .{});
    const t = try T.createSplit(testing.allocator, counting.allocator(), .{});
    defer t.destroy();
    t.rec.answer = true;
    t.rec.record = false;
    try t.handshake();
    // Two at once warm it up for two at once.
    const warm = [_][]const u8{ try t.headers(1, &get, true), try t.headers(3, &get, true) };
    try t.feed(try std.mem.concat(t.arena(), u8, &warm));
    _ = try t.drain();
    const in = [_][]const u8{ try t.headers(5, &get, true), try t.headers(7, &post, false), try t.data(7, "body", true) };
    const before = counting.allocations;
    for (in) |b| try t.feed(b);
    const out = try t.drain();
    try expectEqual(before, counting.allocations);
    try expectFrames(out, &.{ .{ .type = .headers, .id = 5 }, .{ .type = .headers, .id = 7 }, .{ .type = .data, .id = 5 }, .{ .type = .data, .id = 7 } });
}

test "h2 conn: a head that can't fit 64 KiB is refused before the buffer grows" {
    var peak: Peak = .{ .child = testing.allocator };
    const t = try T.createSplit(testing.allocator, peak.allocator(), .{});
    defer t.destroy();
    try t.handshake();
    try t.feed(try t.headers(1, &get, true));
    const v = try t.arena().alloc(u8, 200 * 1024);
    @memset(v, 'a');
    const before = peak.peak;
    try expectError(error.HeadersTooLarge, t.c.submitHead(t.stream(1), 200, &.{.{ .name = "x-debug", .value = v }}, true));
    try expectError(error.HeadersTooLarge, t.c.submitHead(t.stream(1), 200, &.{.{ .name = v[0..120000], .value = "1" }}, true));
    try expectEqual(before, peak.peak);
    // Static entries' strings cost nothing toward it.
    try t.c.submitHead(t.stream(1), 200, &.{.{ .name = "accept-encoding", .value = "gzip, deflate" }}, true);
    try expectFrames(try t.drain(), &.{.{ .type = .headers }});
}

// ---------------------------------------------------------------------------
// PLAN §8.2 item 2: no flow-control deadlock

test "h2 conn: a large upload and a large download at once with small windows" {
    const total = 4 << 20;
    const t = try ready(.{ .initial_window = 65535, .connection_window = 65535 });
    defer t.destroy();
    t.rec.record = false;
    const body = try t.arena().alloc(u8, total);
    @memset(body, 'd');
    const up = try t.arena().alloc(u8, 16384);
    @memset(up, 'u');
    try t.feed(try t.headers(1, &post, false)); // the upload
    try t.feed(try t.headers(3, &get, true)); // the download
    try t.c.submitHead(t.stream(3), 200, &.{}, false);
    try t.c.submitData(t.stream(3), &.{body}, true);
    // The client: its send windows (ours to it start at 65535 until it
    // sees our SETTINGS, which have the same value here) and what it got.
    var csend_conn: i64 = 65535;
    var csend_stream: i64 = 65535;
    var sent: usize = 0;
    var got: usize = 0;
    var done = false;
    var rounds: usize = 0;
    while (sent < total or !done) : (rounds += 1) {
        try expect(rounds < 10_000);
        var progress = false;
        // The client sends what its windows allow.
        while (sent < total) {
            const n: usize = @intCast(@min(@as(i64, @intCast(up.len)), csend_conn, csend_stream, @as(i64, @intCast(total - sent))));
            if (n == 0) break;
            sent += n;
            try t.feed(try t.data(1, up[0..n], sent == total));
            csend_conn -= @intCast(n);
            csend_stream -= @intCast(n);
            progress = true;
        }
        // The server's output: our DATA and WINDOW_UPDATEs.
        var dl: usize = 0;
        for (try t.drain()) |f| switch (f.type) {
            .data => {
                try expectEqual(3, f.id);
                dl += f.data.len;
                if (f.flags & F.end_stream != 0) done = true;
            },
            .window_update => if (f.id == 0) {
                csend_conn += f.inc;
            } else {
                try expectEqual(1, f.id);
                csend_stream += f.inc;
            },
            else => {},
        };
        got += dl;
        if (dl > 0) {
            progress = true;
            // The client consumes and gives the credit back at once.
            try t.feed(try t.windowUpdate(0, @intCast(dl)));
            try t.feed(try t.windowUpdate(3, @intCast(dl)));
        }
        try expect(progress);
    }
    try expectEqual(total, got);
}

// ---------------------------------------------------------------------------
// Ported from tests/nghttp2_session_test.c (server side)

test "h2 conn: session_recv" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, "hello", true));
    const ev = t.rec.events.items;
    try expectEqual(Event{ .open = 1 }, ev[0]);
    try expectEqual(7, ev.len);
    try expectEqualStrings("hello", ev[6].data.bytes);
    try expect(ev[6].data.end_stream);
}

test "h2 conn: recv_invalid_stream_id" {
    const t = try ready(.{});
    defer t.destroy();
    try expectError(error.ConnectionError, t.feed(try t.headers(2, &get, true)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: recv_invalid_frame" {
    const t = try ready(.{});
    defer t.destroy();
    // A SETTINGS on a stream: frame.zig's check, the connection's answer.
    try expectError(error.ConnectionError, t.feed(try t.raw(4, 0, 1, "")));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: recv_data" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, &(@as([4096]u8, @splat(0))), false));
    try expectEqual(65536 - 4096, t.stream(1).recv_window);
    try expectEqual(16 * 1024 * 1024 - 4096, t.c.recv_window);
    // DATA on an idle stream.
    try expectError(error.ConnectionError, t.feed(try t.data(3, "x", false)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: recv_data_no_auto_flow_control" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, &(@as([16384]u8, @splat(0))), false));
    try t.feed(try t.data(1, &(@as([16384]u8, @splat(0))), false));
    try t.feed(try t.data(1, &(@as([16384]u8, @splat(0))), false));
    try expectFrames(try t.drain(), &.{});
    try t.c.consumed(t.stream(1), 3 * 16384);
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    try expectEqual(3 * 16384, out[0].inc);
}

test "h2 conn: recv_continuation" {
    const t = try ready(.{});
    defer t.destroy();
    const blk = try t.block(&get);
    try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..2] }));
    try t.feed(try t.continuation(1, true, blk[2..]));
    try expectEqual(4, t.rec.count(.field));
    // A CONTINUATION for another stream.
    try t.feed(try t.headersFrame(3, .{ .end_stream = true, .end_headers = false, .fragment = blk[0..2] }));
    try expectError(error.ConnectionError, t.feed(try t.continuation(5, true, blk[2..])));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: recv_headers_with_priority" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = true, .priority = .{ .exclusive = true, .dependency = 0, .weight = 99 }, .fragment = try t.block(&get) }));
    try expectEqual(1, t.rec.count(.end));
    try expectError(error.ConnectionError, t.feed(try t.headersFrame(3, .{ .end_stream = true, .end_headers = true, .priority = .{ .exclusive = false, .dependency = 3, .weight = 1 }, .fragment = try t.block(&get) })));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: recv_headers_with_padding" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = true, .pad_len = 200, .fragment = try t.block(&get) }));
    try expectEqual(1, t.rec.count(.end));
    try expectFrames(try t.drain(), &.{});
}

test "h2 conn: recv_headers_early_response" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.c.submitHead(t.stream(1), 413, &.{}, true);
    try expectEqual(streams_state.half_closed_local, t.stream(1).state);
    try t.feed(try t.data(1, "rest", true));
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
    try expectFrames(try t.drain(), &.{.{ .type = .headers, .flags = F.end_stream | F.end_headers }});
}

test "h2 conn: recv_headers_for_closed_stream" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.answer = true;
    try t.feed(try t.headers(1, &get, false));
    try t.c.reset(t.stream(1), .refused_stream);
    _ = try t.drain();
    try t.feed(try t.headers(1, &.{.{ .name = "x", .value = "1" }}, true));
    try expectFrames(try t.drain(), &.{});
}

test "h2 conn: server_recv_push_response" {
    const t = try ready(.{});
    defer t.destroy();
    try expectError(error.ConnectionError, t.feed(try t.pushPromise(1, 2)));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqualStrings("PUSH_PROMISE: push disabled", out[0].data);
}

test "h2 conn: recv_premature_headers" {
    const t = try ready(.{});
    defer t.destroy();
    const blk = try t.block(&get);
    // The block ends inside a representation.
    try expectError(error.ConnectionError, t.feed(try t.headersFrame(1, .{ .end_stream = true, .end_headers = true, .fragment = blk[0 .. blk.len - 1] })));
    try expectFrames(try t.drain(), &.{ rstWith(1, .compression_error), goawayWith(.compression_error) });
}

test "h2 conn: recv_unknown_frame" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.raw(0xfa, 0xff, 0, "unknown"));
    try t.feed(try t.raw(0x20, 0, 3, "extension"));
    try expectFrames(try t.drain(), &.{});
    try t.feed(try t.headers(1, &get, true));
    try expectEqual(1, t.rec.count(.end));
}

test "h2 conn: recv_unexpected_continuation" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try expectError(error.ConnectionError, t.feed(try t.continuation(1, true, try t.block(&.{.{ .name = "x", .value = "1" }}))));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqualStrings("CONTINUATION: unexpected", out[0].data);
}

test "h2 conn: recv_settings_header_table_size" {
    const t = try ready(.{});
    defer t.destroy();
    t.dec = .init(.{ .max_table_size = 256 });
    try t.feed(try t.settings(&.{.{ .id = .header_table_size, .value = 0 }}));
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{.{ .name = "server", .value = "anole" }}, true);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .settings, .flags = F.ack }, .{ .type = .headers } });
    try expectEqual(2, out[1].fields.len);
}

test "h2 conn: recv_too_large_frame_length" {
    const t = try ready(.{});
    defer t.destroy();
    const b = try t.arena().alloc(u8, 9);
    _ = frame.writeHeader(b, .{ .length = 16385, .type = .headers, .flags = 0, .stream_id = 1 });
    try expectError(error.ConnectionError, t.feed(b));
    try expectFrames(try t.drain(), &.{goawayWith(.frame_size_error)});
}

test "h2 conn: on_request_headers_received" {
    // Opens, updates the last stream IDs.
    {
        const t = try ready(.{});
        defer t.destroy();
        try t.feed(try t.headers(3, &get, false));
        try expectEqual(3, t.c.last_recv);
        try expectEqual(3, t.c.last_proc);
        try expectEqual(1, t.c.table.size);
    }
    // Over the maximum sent but not yet acknowledged: REFUSED_STREAM.
    {
        const t = try T.create(testing.allocator, .{ .max_concurrent_streams = 1 });
        defer t.destroy();
        try t.feed(conn.client_magic);
        try t.feed(try t.settings(&.{}));
        try t.feed(try t.headers(1, &get, false));
        _ = try t.drain();
        try t.feed(try t.headers(3, &get, false));
        try expectFrames(try t.drain(), &.{rstWith(3, .refused_stream)});
        try expectEqual(1, t.c.last_proc);
        // Acknowledged: nghttp2 makes it a connection error; Anole still
        // refuses it (PLAN §5.4, INTENTIONAL.md, limits 7).
        try t.feed(try t.settingsAck());
        try t.feed(try t.headers(5, &get, false));
        try expectFrames(try t.drain(), &.{rstWith(5, .refused_stream)});
    }
}

test "h2 conn: on_headers_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.headers(1, &.{.{ .name = "x-t", .value = "1" }}, true));
    try expectEqual(streams_state.half_closed_remote, t.stream(1).state);
    try expectError(error.ConnectionError, t.feed(try t.headers(1, &.{.{ .name = "x-t", .value = "1" }}, true)));
    try expectFrames(try t.drain(), &.{goawayWith(.stream_closed)});
}

test "h2 conn: on_rst_stream_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, false));
    try t.feed(try t.rst(1, .internal_error));
    try expectEqual(ErrorCode.internal_error, t.rec.closeCode(1).?);
    try expectEqual(0, t.c.table.size);
    try expectError(error.ConnectionError, t.feed(try t.rst(3, .cancel)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: on_settings_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.settings(&.{
        .{ .id = .max_concurrent_streams, .value = 1 },
        .{ .id = .max_frame_size, .value = 20000 },
        .{ .id = .max_header_list_size, .value = 1000 },
        .{ .id = .enable_connect_protocol, .value = 1 },
        .{ .id = @fromBackingInt(0x77), .value = 5 },
    }));
    try expectEqual(1, t.c.remote.max_concurrent_streams);
    try expectEqual(20000, t.c.remote.max_frame_size);
    try expectEqual(1000, t.c.remote.max_header_list_size);
    try expect(t.c.remote.enable_connect_protocol);
    try expectFrames(try t.drain(), &.{.{ .type = .settings, .flags = F.ack }});
    // Invalid values are frame.zig's: a connection error.
    try expectError(error.ConnectionError, t.feed(try t.settings(&.{.{ .id = .enable_push, .value = 2 }})));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: on_push_promise_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, false));
    try expectError(error.ConnectionError, t.feed(try t.pushPromise(1, 2)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: on_ping_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.ping(false, @splat(7)));
    try t.feed(try t.ping(true, @splat(9)));
    try expectEqual(1, t.rec.count(.ping_ack));
    try expectFrames(try t.drain(), &.{.{ .type = .ping, .flags = F.ack, .id = 0 }});
}

test "h2 conn: on_goaway_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.goaway(4, .enhance_your_calm));
    try expectEqual(1, t.rec.count(.goaway));
    try t.feed(try t.goaway(2, .no_error));
    try expectError(error.ConnectionError, t.feed(try t.goaway(4, .no_error)));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqualStrings("GOAWAY: invalid last_stream_id", out[0].data);
}

test "h2 conn: on_window_update_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, false));
    try t.feed(try t.windowUpdate(1, 1000));
    try expectEqual(65535 + 1000, t.stream(1).send_window);
    try t.feed(try t.windowUpdate(0, 1000));
    try expectEqual(65535 + 1000, t.c.send_window);
    const ev = t.rec.events.items;
    try expectEqual(Event{ .window = 1 }, ev[ev.len - 2]);
    try expectEqual(Event{ .window = null }, ev[ev.len - 1]);
    // Unknown (closed) streams are ignored; an increment of 0 on a stream
    // is a connection error.
    try t.feed(try t.headers(3, &get, false));
    try t.feed(try t.rst(3, .cancel));
    try t.feed(try t.windowUpdate(3, 0));
    try expectFrames(try t.drain(), &.{});
    try expectError(error.ConnectionError, t.feed(try t.windowUpdate(1, 0)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: on_data_received" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, "a", false));
    try expectEqual(streams_state.open, t.stream(1).state);
    try t.feed(try t.data(1, "", true));
    try expectEqual(streams_state.half_closed_remote, t.stream(1).state);
    const ev = t.rec.events.items;
    try expect(ev[ev.len - 1].data.end_stream);
    try expectEqual(0, ev[ev.len - 1].data.bytes.len);
}

test "h2 conn: on_data_received_fail_fast" {
    const t = try ready(.{});
    defer t.destroy();
    // Stream 0 is frame.zig's check.
    try expectError(error.ConnectionError, t.feed(try t.data(0, "x", false)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: send_headers_reply" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{.{ .name = "content-type", .value = "text/plain" }}, false);
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .headers, .flags = F.end_headers, .id = 1 }});
    try expectEqualStrings(":status", out[0].fields[0].name);
    try expectEqualStrings("text/plain", out[0].fields[1].value);
    try expectEqual(streams_state.half_closed_remote, t.stream(1).state);
}

test "h2 conn: send_headers_frame_size_error" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const v = try t.arena().alloc(u8, 70000);
    @memset(v, '~');
    try expectError(error.HeadersTooLarge, t.c.submitHead(t.stream(1), 200, &.{.{ .name = "x", .value = v }}, true));
    try expect(t.c.out.idle());
}

test "h2 conn: send_rst_stream" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.reset(t.stream(1), .cancel);
    try expectFrames(try t.drain(), &.{rstWith(1, .cancel)});
    try expectEqual(ErrorCode.cancel, t.rec.closeCode(1).?);
    try expectEqual(0, t.c.table.size);
}

test "h2 conn: is_my_stream_id" {
    const t = try ready(.{});
    defer t.destroy();
    // Even IDs are ours, and we opened none: idle.
    try expectError(error.ConnectionError, t.feed(try t.windowUpdate(2, 1)));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: submit_data" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try expectError(error.StreamClosed, t.c.submitData(t.stream(1), &.{"x"}, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{ "hel", "", "lo" }, true);
    try expect(t.c.borrowing());
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqualStrings("hello", out[1].data);
    try expect(!t.c.borrowing());
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
}

test "h2 conn: submit_data_read_length_too_large" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.settings(&.{.{ .id = .max_frame_size, .value = 32768 }}));
    try t.feed(try t.windowUpdate(0, 1 << 20));
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.windowUpdate(1, 1 << 20));
    const body = try t.arena().alloc(u8, 70000);
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{body}, true);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .settings }, .{ .type = .headers }, .{ .type = .data }, .{ .type = .data }, .{ .type = .data } });
    try expectEqual(32768, out[2].data.len);
    try expectEqual(70000 - 65536, out[4].data.len);
}

test "h2 conn: submit_data_twice" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{"first "}, false);
    try t.c.submitData(t.stream(1), &.{"second"}, true);
    try expectError(error.StreamClosed, t.c.submitData(t.stream(1), &.{"third"}, true));
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers }, .{ .type = .data, .flags = 0 }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqualStrings("first ", out[1].data);
    try expectEqualStrings("second", out[2].data);
}

test "h2 conn: submit_response_with_data" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.answer = true;
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.data(1, "q", true));
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers, .flags = F.end_headers }, .{ .type = .data, .flags = F.end_stream } });
    try expectEqualStrings("ok", out[1].data);
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
}

test "h2 conn: submit_response_without_data" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 204, &.{}, true);
    try expectEqual(ErrorCode.no_error, t.rec.closeCode(1).?);
    try expectFrames(try t.drain(), &.{.{ .type = .headers, .flags = F.end_headers | F.end_stream }});
}

test "h2 conn: submit_trailer" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.headers(3, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{"body"}, false);
    try t.c.submitTrailers(t.stream(1), &.{.{ .name = "grpc-status", .value = "0" }});
    // Without DATA, at once.
    try t.c.submitHead(t.stream(3), 200, &.{}, false);
    try t.c.submitTrailers(t.stream(3), &.{.{ .name = "grpc-status", .value = "1" }});
    const out = try t.drain();
    try expectFrames(out, &.{
        .{ .type = .headers, .id = 1 },
        .{ .type = .headers, .id = 3 },
        .{ .type = .headers, .id = 3, .flags = F.end_stream | F.end_headers },
        .{ .type = .data, .id = 1, .flags = 0 },
        .{ .type = .headers, .id = 1, .flags = F.end_stream | F.end_headers },
    });
    try expectEqualStrings("0", out[4].fields[0].value);
}

test "h2 conn: submit_headers_reply" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try expectError(error.StreamClosed, t.c.submitHead(t.stream(1), 200, &.{}, false));
}

test "h2 conn: submit_headers_continuation" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const v = try t.arena().alloc(u8, 4096);
    @memset(v, '~');
    try t.c.submitHead(t.stream(1), 200, &.{ .{ .name = "a", .value = v }, .{ .name = "b", .value = v }, .{ .name = "c", .value = v }, .{ .name = "d", .value = v }, .{ .name = "e", .value = v } }, false);
    const out = try t.drain();
    try expectEqual(2, out[0].frames);
    try expectEqual(6, out[0].fields.len);
}

test "h2 conn: submit_headers_continuation_extra_large" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.settings(&.{.{ .id = .max_frame_size, .value = frame.max_max_frame_size }}));
    try t.feed(try t.headers(1, &get, true));
    const v = try t.arena().alloc(u8, 60000);
    @memset(v, '~');
    try t.c.submitHead(t.stream(1), 200, &.{.{ .name = "a", .value = v }}, false);
    const out = try t.drain();
    try expectEqual(1, out[1].frames);
}

test "h2 conn: submit_settings_update_local_window_size" {
    const t = try T.create(testing.allocator, .{ .initial_window = 16 * 1024 });
    defer t.destroy();
    _ = try t.drain();
    try t.feed(conn.client_magic);
    try t.feed(try t.settings(&.{}));
    try t.feed(try t.headers(1, &post, false));
    t.rec.consume = false;
    try t.feed(try t.data(1, &(@as([10000]u8, @splat(0))), false));
    try t.c.consumed(t.stream(1), 10000);
    _ = try t.drain();
    // 10000 consumed is under half of 65535; at the ACK the window shrinks
    // to 16384 less what is outstanding, and the consumed bytes are now
    // over half of it.
    try t.feed(try t.settingsAck());
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    try expectEqual(10000, out[0].inc);
    try expectEqual(16 * 1024, t.stream(1).recv_window);
}

test "h2 conn: submit_window_update" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    for ([_]usize{ 16384, 16384, 7232 }) |n| try t.feed(try t.data(1, (&@as([16384]u8, @splat(0)))[0..n], false));
    try t.c.consumed(t.stream(1), 40000);
    try t.c.consumed(null, 0);
    const out = try t.drain();
    try expectFrames(out, &.{.{ .type = .window_update, .id = 1 }});
    try expectEqual(65536, t.stream(1).recv_window);
}

test "h2 conn: submit_rst_stream" {
    const t = try ready(.{});
    defer t.destroy();
    // Reset from onField, then the callback fails: the closed stream is
    // left alone, one RST_STREAM.
    t.rec.reset_in_field = true;
    t.rec.fail_field = ":method";
    try t.feed(try t.headers(1, &get, false));
    try expectFrames(try t.drain(), &.{rstWith(1, .cancel)});
    try expectEqual(1, t.rec.count(.close));
}

test "h2 conn: max_concurrent_streams" {
    const t = try ready(.{ .max_concurrent_streams = 2 });
    defer t.destroy();
    try t.feed(try t.headers(1, &get, false));
    try t.feed(try t.headers(3, &get, false));
    // Refused, where nghttp2 gives a connection PROTOCOL_ERROR
    // (INTENTIONAL.md, limits 7).
    try t.feed(try t.headers(5, &get, false));
    try expectFrames(try t.drain(), &.{rstWith(5, .refused_stream)});
    try expectEqual(2, t.rec.count(.open));
}

test "h2 conn: stop_data_with_rst_stream" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const body = try t.arena().alloc(u8, 100_000);
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{body}, true);
    var vecs: [2][]const u8 = undefined;
    _ = try t.c.pending(&vecs);
    try t.feed(try t.rst(1, .cancel));
    try expect(t.c.pending_nodes == 0);
    var data: usize = 0;
    for (try t.drain()) |f| {
        if (f.type == .data) data += 1;
    }
    try expect(data <= 1);
}

test "h2 conn: flow_control" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const body = try t.arena().alloc(u8, 100_000);
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{body}, true);
    var n: usize = 0;
    for (try t.drain()) |f| n += f.data.len;
    try expectEqual(65535, n);
    try expectEqual(0, t.stream(1).send_window);
    // A stream credit alone isn't enough: the connection's is spent too.
    try t.feed(try t.windowUpdate(1, 10_000));
    try expectFrames(try t.drain(), &.{});
    try t.feed(try t.windowUpdate(0, 5_000));
    n = 0;
    for (try t.drain()) |f| n += f.data.len;
    try expectEqual(5_000, n);
}

test "h2 conn: flow_control_data_recv" {
    const t = try ready(.{ .initial_window = 65535 });
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    for (0..3) |_| try t.feed(try t.data(1, &(@as([16384]u8, @splat(0))), false));
    try t.feed(try t.data(1, &(@as([16383]u8, @splat(0))), false));
    try expectEqual(0, t.stream(1).recv_window);
    try expectError(error.ConnectionError, t.feed(try t.data(1, "x", false)));
    try expectFrames(try t.drain(), &.{goawayWith(.flow_control_error)});
}

test "h2 conn: flow_control_data_with_padding_recv" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.consume = false;
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.dataPadded(1, "abc", false, 100));
    // 1 + 3 + 100 charged; the padding (101) consumed at once.
    try expectEqual(65536 - 104, t.stream(1).recv_window);
    try expectEqual(101, t.stream(1).recv_unacked);
    try expectEqual(101, t.c.recv_unacked);
    const ev = t.rec.events.items;
    try expectEqualStrings("abc", ev[ev.len - 1].data.bytes);
    // Padding longer than the payload.
    try expectError(error.ConnectionError, t.feed(try t.raw(0, F.padded, 1, "\x05ab")));
    try expectFrames(try t.drain(), &.{goawayWith(.protocol_error)});
}

test "h2 conn: on_stream_close" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.answer = true;
    try t.feed(try t.headers(1, &get, true));
    // Answered inside onHeadersEnd; the stream closes once its DATA is
    // framed, then onStreamClose, once.
    try expectEqual(0, t.rec.count(.close));
    _ = try t.drain();
    const ev = t.rec.events.items;
    try expectEqual(Event{ .close = .{ .id = 1, .code = .no_error } }, ev[ev.len - 1]);
    try expectEqual(1, t.rec.count(.close));
}

test "h2 conn: data_backoff_by_high_pri_frame" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    const body = try t.arena().alloc(u8, 60000);
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{body}, true);
    // The PING ACK is queued before any DATA is framed.
    try t.feed(try t.ping(false, @splat(3)));
    const out = try t.drain();
    try expectEqual(frame.Type.ping, out[1].type);
    try expectEqual(frame.Type.data, out[2].type);
}

test "h2 conn: stream_get_state" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    const s = t.stream(1);
    try expectEqual(streams_state.open, s.state);
    try t.feed(try t.data(1, "", true));
    try expectEqual(streams_state.half_closed_remote, s.state);
    try t.c.submitHead(s, 200, &.{}, true);
    try expect(t.c.table.get(1) == null);
}

test "h2 conn: on_header_temporal_failure" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.fail_field = ":method";
    try t.feed(try t.headers(1, &get, true));
    try expectEqual(1, t.rec.count(.field));
    try expectFrames(try t.drain(), &.{rstWith(1, .internal_error)});
    t.rec.reset_in_field = true;
    t.rec.fail_field = null;
    try t.feed(try t.headers(3, &get, true));
    try expectEqual(2, t.rec.count(.field));
    try expectFrames(try t.drain(), &.{rstWith(3, .cancel)});
}

test "h2 conn: on_begin_headers_temporal_failure" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.fail_open = true;
    try t.feed(try t.headers(1, &get, true));
    try expectEqual(0, t.rec.count(.field));
    try expectFrames(try t.drain(), &.{rstWith(1, .internal_error)});
}

test "h2 conn: recv_client_magic" {
    const t = try T.create(testing.allocator, .{});
    defer t.destroy();
    _ = try t.drain();
    try t.feed(conn.client_magic[0..10]);
    try t.feed(conn.client_magic[10..]);
    try t.feed(try t.settings(&.{}));
    try expectFrames(try t.drain(), &.{.{ .type = .settings, .flags = F.ack }});
    const u = try T.create(testing.allocator, .{});
    defer u.destroy();
    try expectError(error.BadPreface, u.feed("PRI * HTTP/2.0\r\n\r\nXX"));
    try expectError(error.ConnectionError, u.feed(conn.client_magic));
}

test "h2 conn: reset_pending_headers" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{"x"}, true);
    try t.c.reset(t.stream(1), .internal_error);
    // HEADERS was queued at once; the DATA, not yet framed, is dropped.
    try expectFrames(try t.drain(), &.{ .{ .type = .headers }, rstWith(1, .internal_error) });
}

test "h2 conn: detach_item_from_closed_stream" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &get, true));
    try t.feed(try t.headers(3, &get, true));
    try t.c.submitHead(t.stream(1), 200, &.{}, false);
    try t.c.submitData(t.stream(1), &.{"a"}, true);
    try t.c.submitHead(t.stream(3), 200, &.{}, false);
    try t.c.submitData(t.stream(3), &.{"b"}, true);
    try t.feed(try t.rst(1, .cancel));
    try expectEqual(1, t.c.pending_nodes);
    const out = try t.drain();
    try expectFrames(out, &.{ .{ .type = .headers, .id = 1 }, .{ .type = .headers, .id = 3 }, .{ .type = .data, .id = 3 } });
}

test "h2 conn: too_many_settings" {
    const t = try ready(.{});
    defer t.destroy();
    const entries: [33]frame.Setting = @splat(.{ .id = .max_concurrent_streams, .value = 1 });
    try expectError(error.ConnectionError, t.feed(try t.settings(&entries)));
    try expectFrames(try t.drain(), &.{goawayWith(.enhance_your_calm)});
}

test "h2 conn: removed_closed_stream" {
    const t = try ready(.{});
    defer t.destroy();
    t.rec.answer = true;
    var id: u31 = 1;
    while (id < 40) : (id += 2) try t.feed(try t.headers(id, &get, true));
    try expectEqual(20, t.c.table.size);
    _ = try t.drain();
    try expectEqual(0, t.c.table.size);
    try expectEqual(20, t.rec.count(.close));
}

test "h2 conn: no_rfc7540_priorities" {
    const t = try ready(.{});
    defer t.destroy();
    try expectEqual(false, t.c.remote.no_rfc7540_priorities.?);
    // The first SETTINGS set it (to the default 0); it can't change.
    try expectError(error.ConnectionError, t.feed(try t.settings(&.{.{ .id = .no_rfc7540_priorities, .value = 1 }})));
    const out = try t.drain();
    try expectFrames(out, &.{goawayWith(.protocol_error)});
    try expectEqualStrings("SETTINGS: SETTINGS_NO_RFC7540_PRIORITIES cannot be changed", out[0].data);
}

test "h2 conn: http_mandatory_headers" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &.{ .{ .name = ":method", .value = "GET" }, .{ .name = ":scheme", .value = "https" }, .{ .name = ":authority", .value = "x" } }, true));
    try t.feed(try t.headers(3, &(get ++ [_]Field{.{ .name = ":method", .value = "GET" }}), true));
    try t.feed(try t.headers(5, &(get ++ [_]Field{.{ .name = "connection", .value = "close" }}), true));
    try expectFrames(try t.drain(), &.{ rstWith(1, .protocol_error), rstWith(3, .protocol_error), rstWith(5, .protocol_error) });
    try expectEqual(0, t.rec.count(.end));
}

test "h2 conn: http_content_length" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &postLen("4"), false));
    try t.feed(try t.data(1, "abcd", true));
    try expectFrames(try t.drain(), &.{});
    try t.feed(try t.headers(3, &(postLen("4") ++ [_]Field{.{ .name = "content-length", .value = "4" }}), false));
    try expectFrames(try t.drain(), &.{rstWith(3, .protocol_error)});
}

test "h2 conn: http_content_length_mismatch" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &postLen("5"), false));
    try t.feed(try t.data(1, "abcd", true));
    try t.feed(try t.headers(3, &postLen("1"), false));
    try t.feed(try t.data(3, "ab", false));
    try expectFrames(try t.drain(), &.{ rstWith(1, .protocol_error), rstWith(3, .protocol_error) });
}

test "h2 conn: http_trailer_headers" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &post, false));
    try t.feed(try t.headers(1, &.{.{ .name = "x-t", .value = "v" }}, true));
    try expectFrames(try t.drain(), &.{});
    try t.feed(try t.headers(3, &post, false));
    try t.feed(try t.headers(3, &.{.{ .name = ":status", .value = "200" }}, true));
    try expectFrames(try t.drain(), &.{rstWith(3, .protocol_error)});
}

test "h2 conn: http_ignore_regular_header" {
    const t = try ready(.{});
    defer t.destroy();
    try t.feed(try t.headers(1, &(get ++ [_]Field{ .{ .name = "foo", .value = " bar" }, .{ .name = "x-ok", .value = "1" } }), true));
    var names: usize = 0;
    for (t.rec.events.items) |e| switch (e) {
        .field => |f| {
            try expect(!std.mem.eql(u8, f.name, "foo"));
            names += 1;
        },
        else => {},
    };
    try expectEqual(5, names);
    try expectFrames(try t.drain(), &.{});
}

// ---------------------------------------------------------------------------
// Fuzz

/// Tracks the bytes live and the most ever live.
const Peak = struct {
    child: Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(p: *Peak) Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grow(p: *Peak, old: usize, new: usize) void {
        p.live = p.live - old + new;
        p.peak = @max(p.peak, p.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const r = p.child.rawAlloc(len, a, ra) orelse return null;
        p.grow(0, len);
        return r;
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        if (!p.child.rawResize(mem, a, new_len, ra)) return false;
        p.grow(mem.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        const r = p.child.rawRemap(mem, a, new_len, ra) orelse return null;
        p.grow(mem.len, new_len);
        return r;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const p: *Peak = @ptrCast(@alignCast(ctx));
        p.child.rawFree(mem, a, ra);
        p.live -= mem.len;
    }
};

/// The fuzz target: a valid preface, then the input's bytes (its first
/// byte picks the split) to a connection whose handler answers every
/// complete request with 200 and "ok" from inside its callbacks.
fn fuzzOne(input: []const u8) anyerror!void {
    var peak: Peak = .{ .child = testing.allocator };
    {
        const t = try T.createSplit(testing.allocator, peak.allocator(), .{ .max_header_list_size = 4096, .initial_window = 1024, .connection_window = 65535, .max_concurrent_streams = 16 });
        defer t.destroy();
        t.rec.record = false;
        t.rec.answer = true;
        try t.handshake();
        if (input.len == 0) return;
        const stride = 1 + @as(usize, input[0] % 64);
        var rest = input[1..];
        while (rest.len > 0) {
            const n = @min(stride, rest.len);
            t.feed(rest[0..n]) catch |err| switch (err) {
                error.ConnectionError, error.BadPreface => {
                    _ = try t.drain();
                    break;
                },
                else => return err,
            };
            rest = rest[n..];
            _ = try t.drain();
            _ = t.arena_state.reset(.retain_capacity);
            // Window and stream invariants (RFC 9113 §6.9).
            const c = &t.c;
            try expect(c.recv_window >= 0 and c.recv_window <= 65535);
            // The send side: DATA framed within the connection window (the
            // drain checked each frame against the peer's max_frame_size).
            try expect(c.send_window >= 0 and c.send_window <= frame.max_window_size);
            try expect(c.table.size <= 16);
            var i: usize = 0;
            while (c.table.next(&i)) |s| {
                try expect(s.send_window <= frame.max_window_size);
                try expect(s.recv_window >= 0 and @as(i64, s.recv_window) + s.recv_unacked <= 1024);
                try expect(s.state != .closed and s.state != .idle);
            }
        }
    }
    // Bounded: the input is at most fuzz.max_len, and the most a block or
    // the out queue takes is linear in it.
    try expect(peak.peak <= 256 * 1024);
    try expectEqual(0, peak.live);
}

/// The 'fuzz: h2 conn recv' seeds, owned by `alloc`: each a split byte
/// (fuzzOne's stride) and then frames sent after the handshake. The
/// session differential (conn_diff_test.zig) runs them too.
pub fn fuzzSeeds(alloc: Allocator) ![][]u8 {
    var seeds: std.ArrayList([]u8) = .empty;
    errdefer {
        for (seeds.items) |s| alloc.free(s);
        seeds.deinit(alloc);
    }
    const t = try T.create(alloc, .{});
    defer t.destroy();
    const shapes = [_][]const []const u8{
        &.{ try t.headers(1, &get, true), try t.headers(3, &post, false), try t.data(3, "abc", true) },
        &.{ try t.headers(1, &post, false), try t.rst(1, .cancel), try t.data(1, "x", false) },
        &.{ try t.headers(1, &get, true), try t.data(1, "x", false), try t.headers(3, &get, false), try t.headers(1, &get, false) },
        &.{ try t.headersFrame(1, .{ .end_stream = true, .end_headers = false, .fragment = (try t.block(&get))[0..3] }), try t.continuation(1, true, (try t.block(&get))[3..]) },
        &.{ try t.headers(1, &post, false), try t.dataPadded(1, "padded", true, 10) },
        &.{ try t.ping(false, @splat(1)), try t.windowUpdate(0, 100), try t.priority(1, 1), try t.settings(&.{.{ .id = .initial_window_size, .value = 1 }}) },
        &.{ try t.headers(5, &get, false), try t.headers(3, &get, false) },
        &.{ try t.headers(1, &postLen("2"), false), try t.data(1, "abc", true), try t.goaway(0, .no_error) },
    };
    for (shapes, 0..) |frames, k| {
        var b: std.ArrayList(u8) = .empty;
        errdefer b.deinit(alloc);
        try b.append(alloc, @intCast(k * 7));
        for (frames) |f| try b.appendSlice(alloc, f);
        try seeds.append(alloc, try b.toOwnedSlice(alloc));
    }
    return seeds.toOwnedSlice(alloc);
}

test "fuzz: h2 conn recv" {
    const alloc = testing.allocator;
    const seeds = try fuzzSeeds(alloc);
    defer {
        for (seeds) |s| alloc.free(s);
        alloc.free(seeds);
    }
    try fuzz.bytes(fuzzOne, seeds);
}
