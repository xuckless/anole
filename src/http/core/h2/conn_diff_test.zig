//! The session differential (PLAN §5.3): the same client byte stream into
//! an nghttp2 server session set up as today's engine sets it up
//! (server/h2_nghttp2.zig `initSession`: no automatic WINDOW_UPDATE, credit
//! given back as DATA arrives, the header-list limit in the header
//! callback) and into Conn(.server), each with a handler that answers
//! every complete request with 200 and "ok"; the output compared after
//! normalization, batch by batch. Intentional divergences: INTENTIONAL.md,
//! each matched by one named rule here and counted. Only with -Dhttp2 (the
//! bindings are the engine's).
//!
//! What a batch compares (each side's output for one chunk of input, parsed
//! with frame.zig, header blocks decoded by one nghttp2 inflater per side,
//! so HPACK bytes and frame sizes never matter): the connection's frames in
//! order
//! (SETTINGS entries sorted, GOAWAY's debug data left out), each stream's
//! frames in order (decoded HEADERS, DATA concatenated with END_STREAM's
//! place, RST_STREAM's code), and the order of the responses. Not
//! compared: DATA interleaving across streams, the place of DATA among the
//! control frames, and WINDOW_UPDATE amounts, which are a bound instead
//! (INTENTIONAL.md, session 2).
//!
//! Inputs: nghttp2's fuzz corpus (client streams recorded against nghttpd,
//! packed by tools/pack_h2_sessions.py), the 'fuzz: h2 conn recv' seeds,
//! and 5000 generated sessions. Each runs in lockstep whole (one chunk)
//! and on random cuts: Conn gets what it left over plus the next piece,
//! nghttp2 exactly the bytes Conn took, both drained after every frame
//! (`lockstep`), compared after every chunk. Then through Conn alone, whole
//! and on the same cuts with no drain until the end: the same bytes
//! (WINDOW_UPDATEs aside), however the input was cut.

const std = @import("std");
const c = @import("nghttp2");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const conn = @import("conn.zig");
const conn_test = @import("conn_test.zig");
const streams = @import("streams.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ErrorCode = frame.ErrorCode;
const Stream = conn.Stream;
const Field = hpack.Field;

// ---------------------------------------------------------------------------
// The two servers

/// A deliberate change to Conn's answers, to show the comparison
/// normalizes one (`split`) and catches the others: a 201 (`status`), a
/// 431 to a request under the limits (`status431`), and a PING after the
/// peer's GOAWAY (`goaway_ping`), which no rule may excuse.
const Plant = enum { none, status, split, status431, goaway_ping };

/// Conn's side: every complete request answered 200 + "ok" from inside the
/// callback, DATA credit given back at once.
const Handler = struct {
    c: *C = undefined,
    plant: Plant = .none,

    pub fn onStreamOpen(_: *Handler, _: *Stream) conn.Error!void {}
    pub fn onField(_: *Handler, _: *Stream, _: []const u8, _: []const u8) conn.Error!void {}

    pub fn onHeadersEnd(h: *Handler, s: *Stream, end_stream: bool) conn.Error!void {
        if (end_stream and s.canSend()) h.respond(s);
    }

    pub fn onData(h: *Handler, s: *Stream, bytes: []const u8, end_stream: bool) conn.Error!void {
        h.c.consumed(s, bytes.len) catch @panic("OOM");
        if (end_stream and s.canSend()) h.respond(s);
    }

    pub fn onStreamClose(_: *Handler, _: *Stream, _: ErrorCode) void {}
    pub fn onWindow(_: *Handler, _: ?*Stream) void {}
    pub fn onGoaway(h: *Handler, _: u31, _: ErrorCode) void {
        if (h.plant == .goaway_ping) h.c.ping(@splat(0xaa)) catch @panic("ping");
    }
    pub fn onPingAck(_: *Handler, _: [8]u8) void {}

    fn respond(h: *Handler, s: *Stream) void {
        if (h.plant == .status431) return h.c.submitHead(s, 431, &.{}, true) catch @panic("submitHead");
        h.c.submitHead(s, if (h.plant == .status) 201 else 200, &.{}, false) catch @panic("submitHead");
        if (h.plant == .split) {
            h.c.submitData(s, &.{"o"}, false) catch @panic("submitData");
            h.c.submitData(s, &.{"k"}, true) catch @panic("submitData");
        } else h.c.submitData(s, &.{"ok"}, true) catch @panic("submitData");
    }
};

const C = conn.Conn(.server, Handler);

/// nghttp2's side, configured from the same Options.
const Ng = struct {
    session: *c.nghttp2_session,
    opts: conn.Options,
    heads: std.AutoHashMapUnmanaged(i32, Head) = .empty,
    gpa: Allocator,
    /// mem_recv2's error, if it returned one (no GOAWAY is queued).
    fatal: ?c_int = null,

    /// production's `onHeader` limit, extended to Conn's answer
    /// (INTENTIONAL.md, limits 6): a request head past the list size or the
    /// field count is answered 431, trailers are reset.
    const Head = struct {
        size: u64 = 0,
        count: usize = 0,
        cookie: bool = false,
        over: bool = false,
        /// RST_STREAM(NO_ERROR) once the 431 is sent (queued before it,
        /// it would drop the HEADERS).
        rst_after: bool = false,
        /// "ok" bytes sent.
        body_off: u8 = 0,
    };

    fn init(ng: *Ng, gpa: Allocator, opts: conn.Options) !void {
        ng.* = .{ .session = undefined, .opts = opts, .gpa = gpa };
        var cbs: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&cbs) != 0) return error.OutOfMemory;
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, onBeginHeaders);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, onFrameRecv);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onDataChunk);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onStreamClose);
        c.nghttp2_session_callbacks_set_on_frame_send_callback(cbs, onFrameSend);
        var opt: ?*c.nghttp2_option = null;
        if (c.nghttp2_option_new(&opt) != 0) return error.OutOfMemory;
        defer c.nghttp2_option_del(opt);
        c.nghttp2_option_set_no_auto_window_update(opt, 1);
        c.nghttp2_option_set_stream_reset_rate_limit(opt, opts.stream_reset_burst, opts.stream_reset_rate);
        c.nghttp2_option_set_max_continuations(opt, opts.max_continuations);
        c.nghttp2_option_set_max_outbound_ack(opt, opts.limits.control_frame_budget);
        c.nghttp2_option_set_max_settings(opt, opts.limits.max_settings);
        c.nghttp2_option_set_glitch_rate_limit(opt, opts.limits.glitch_burst, opts.limits.glitch_rate);
        var s: ?*c.nghttp2_session = null;
        if (c.nghttp2_session_server_new2(&s, cbs, ng, opt) != 0) return error.OutOfMemory;
        ng.session = s.?;
        // The entries Conn.init sends, NO_RFC7540_PRIORITIES included
        // (D15 point 3; production nghttp2 doesn't send it yet).
        var iv: [6]c.nghttp2_settings_entry = undefined;
        var n: usize = 0;
        const entries = [_][2]u32{
            .{ c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, opts.max_concurrent_streams },
            .{ c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, opts.initial_window },
            .{ c.NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, opts.max_header_list_size },
            .{ c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
            .{ c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL, 1 },
            .{ c.NGHTTP2_SETTINGS_NO_RFC7540_PRIORITIES, 1 },
        };
        for (entries) |e| {
            if (e[0] == c.NGHTTP2_SETTINGS_MAX_FRAME_SIZE and opts.max_frame_size == frame.min_max_frame_size) continue;
            if (e[0] == c.NGHTTP2_SETTINGS_ENABLE_CONNECT_PROTOCOL and !opts.enable_connect_protocol) continue;
            iv[n] = .{ .settings_id = @intCast(e[0]), .value = e[1] };
            n += 1;
        }
        if (c.nghttp2_submit_settings(ng.session, c.NGHTTP2_FLAG_NONE, &iv, n) != 0) return error.OutOfMemory;
        if (opts.connection_window > conn.default_window)
            _ = c.nghttp2_session_set_local_window_size(ng.session, c.NGHTTP2_FLAG_NONE, 0, opts.connection_window);
    }

    fn deinit(ng: *Ng) void {
        c.nghttp2_session_del(ng.session);
        ng.heads.deinit(ng.gpa);
    }

    fn from(user: ?*anyopaque) *Ng {
        return @ptrCast(@alignCast(user.?));
    }

    fn onBeginHeaders(_: ?*c.nghttp2_session, fr: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(.c) c_int {
        const ng = from(user);
        const g = ng.heads.getOrPut(ng.gpa, fr.*.hd.stream_id) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        const off: u8 = if (g.found_existing) g.value_ptr.body_off else 0;
        g.value_ptr.* = .{ .body_off = off };
        return 0;
    }

    fn onHeader(
        _: ?*c.nghttp2_session,
        fr: [*c]const c.nghttp2_frame,
        name_ptr: [*c]const u8,
        name_len: usize,
        _: [*c]const u8,
        value_len: usize,
        _: u8,
        user: ?*anyopaque,
    ) callconv(.c) c_int {
        const ng = from(user);
        const h = ng.heads.getPtr(fr.*.hd.stream_id) orelse return 0;
        if (h.over) return 0;
        const request = fr.*.headers.cat == c.NGHTTP2_HCAT_REQUEST;
        h.size += name_len + value_len + 32;
        var over = h.size > ng.opts.max_header_list_size;
        const name = name_ptr[0..name_len];
        if (!over and name.len > 0 and name[0] != ':') {
            const crumb = std.mem.eql(u8, name, "cookie");
            if (!crumb or !h.cookie) h.count += 1;
            h.cookie = h.cookie or crumb;
            over = h.count > ng.opts.max_header_count;
        }
        if (!over) return 0;
        if (!request) return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        h.over = true;
        return 0;
    }

    fn onFrameRecv(session: ?*c.nghttp2_session, fr: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(.c) c_int {
        const ng = from(user);
        const hd = fr.*.hd;
        if (c.nghttp2_session_find_stream(session, hd.stream_id) == null) return 0;
        const es = hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0;
        switch (hd.type) {
            c.NGHTTP2_HEADERS => {
                const over = if (ng.heads.get(hd.stream_id)) |h| h.over else false;
                if (fr.*.headers.cat == c.NGHTTP2_HCAT_REQUEST and over) {
                    ng.respond(hd.stream_id, "431", false);
                    if (!es) ng.heads.getPtr(hd.stream_id).?.rst_after = true;
                } else if (es) ng.respond(hd.stream_id, "200", true);
            },
            c.NGHTTP2_DATA => if (es) ng.respond(hd.stream_id, "200", true),
            else => {},
        }
        return 0;
    }

    fn respond(ng: *Ng, id: i32, status: *const [3]u8, body: bool) void {
        var nv = [_]c.nghttp2_nv{.{
            .name = @constCast(":status".ptr),
            .namelen = 7,
            .value = @constCast(status),
            .valuelen = 3,
            .flags = c.NGHTTP2_NV_FLAG_NONE,
        }};
        var prov: c.nghttp2_data_provider2 = .{ .source = .{ .ptr = null }, .read_callback = provide };
        _ = c.nghttp2_submit_response2(ng.session, id, &nv, nv.len, if (body) &prov else null);
    }

    fn provide(_: ?*c.nghttp2_session, id: i32, buf: [*c]u8, len: usize, flags: [*c]u32, _: [*c]c.nghttp2_data_source, user: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const ng = from(user);
        const h = ng.heads.getPtr(id) orelse return c.NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
        const body = "ok";
        const n = @min(len, body.len - h.body_off);
        @memcpy(buf[0..n], body[h.body_off..][0..n]);
        h.body_off += @intCast(n);
        if (h.body_off == body.len) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        return @intCast(n);
    }

    fn onFrameSend(session: ?*c.nghttp2_session, fr: [*c]const c.nghttp2_frame, user: ?*anyopaque) callconv(.c) c_int {
        const ng = from(user);
        if (fr.*.hd.type != c.NGHTTP2_HEADERS) return 0;
        const h = ng.heads.getPtr(fr.*.hd.stream_id) orelse return 0;
        if (h.rst_after) _ = c.nghttp2_submit_rst_stream(session, c.NGHTTP2_FLAG_NONE, fr.*.hd.stream_id, c.NGHTTP2_NO_ERROR);
        h.rst_after = false;
        return 0;
    }

    fn onDataChunk(session: ?*c.nghttp2_session, _: u8, id: i32, _: [*c]const u8, len: usize, _: ?*anyopaque) callconv(.c) c_int {
        _ = c.nghttp2_session_consume(session, id, len);
        return 0;
    }

    fn onStreamClose(_: ?*c.nghttp2_session, id: i32, _: u32, user: ?*anyopaque) callconv(.c) c_int {
        _ = from(user).heads.remove(id);
        return 0;
    }

    fn recv(ng: *Ng, bytes: []const u8) void {
        if (ng.fatal != null or bytes.len == 0) return;
        const rv = c.nghttp2_session_mem_recv2(ng.session, bytes.ptr, bytes.len);
        if (rv < 0) ng.fatal = @intCast(rv) else std.debug.assert(@as(usize, @intCast(rv)) == bytes.len);
    }

    fn drain(ng: *Ng, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            var data: [*c]const u8 = undefined;
            const n = c.nghttp2_session_mem_send2(ng.session, &data);
            if (n < 0) return error.NgSendFailed;
            if (n == 0) break;
            try out.appendSlice(a, data[0..@intCast(n)]);
        }
        return out.items;
    }
};

fn drainConn(cn: *C, a: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var vecs: [16][]const u8 = undefined;
    while (true) {
        const v = try cn.pending(&vecs);
        if (v.len == 0) break;
        var n: usize = 0;
        for (v) |b| {
            try out.appendSlice(a, b);
            n += b.len;
        }
        cn.advance(n);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// The normalized trace

const Goaway = struct { last: u31, code: ErrorCode, debug: []const u8 };

/// One stream's frame in a batch; consecutive DATA merged.
const SLine = struct {
    id: u31,
    kind: enum { headers, data, rst },
    text: std.ArrayList(u8) = .empty,
    es: bool = false,

    fn render(l: SLine, a: Allocator) ![]const u8 {
        return switch (l.kind) {
            .headers => std.fmt.allocPrint(a, "HEADERS {s} es={d}", .{ l.text.items, @intFromBool(l.es) }),
            .data => std.fmt.allocPrint(a, "DATA \"{f}\" es={d}", .{ std.zig.fmtString(l.text.items), @intFromBool(l.es) }),
            .rst => std.fmt.allocPrint(a, "RST_STREAM {s}", .{l.text.items}),
        };
    }
};

const Batch = struct {
    conn: std.ArrayList([]const u8) = .empty,
    lines: std.ArrayList(SLine) = .empty,
    /// Streams in the order of their first HEADERS.
    order: std.ArrayList(u31) = .empty,
    goaway: ?Goaway = null,
    /// Some RST_STREAM(REFUSED_STREAM), or a 431 answer, per stream.
    refused: bool = false,
    status431: std.ArrayList(u31) = .empty,

    fn render(b: *const Batch, a: Allocator, excused: *const Excused) ![]const u8 {
        var o: std.ArrayList(u8) = .empty;
        for (b.conn.items) |l| try o.print(a, "  {s}\n", .{l});
        const sorted = try a.dupe(SLine, b.lines.items);
        std.mem.sort(SLine, sorted, {}, struct {
            fn lt(_: void, x: SLine, y: SLine) bool {
                return x.id < y.id;
            }
        }.lt);
        // std.mem.sort isn't stable: put each stream's lines back in order.
        var i: usize = 0;
        while (i < sorted.len) {
            const id = sorted[i].id;
            var j = i;
            for (b.lines.items) |l| if (l.id == id) {
                sorted[j] = l;
                j += 1;
            };
            i = j;
        }
        for (sorted) |l| if (!excused.contains(l.id)) try o.print(a, "  s{d} {s}\n", .{ l.id, try l.render(a) });
        try o.appendSlice(a, "  order");
        for (b.order.items) |id| if (!excused.contains(id)) try o.print(a, " {d}", .{id});
        try o.append(a, '\n');
        return o.items;
    }
};

const Excused = std.AutoHashMapUnmanaged(u31, void);

/// One side's output, batch after batch.
const Tracer = struct {
    inflater: *c.nghttp2_hd_inflater,
    /// WINDOW_UPDATE increments so far, per stream (0 the connection).
    granted: std.AutoHashMapUnmanaged(u31, u64) = .empty,
    /// The last GOAWAY sent.
    goaway: ?Goaway = null,

    fn init() !Tracer {
        var inf: ?*c.nghttp2_hd_inflater = null;
        if (c.nghttp2_hd_inflate_new(&inf) != 0) return error.OutOfMemory;
        return .{ .inflater = inf.? };
    }

    fn deinit(t: *Tracer) void {
        c.nghttp2_hd_inflate_del(t.inflater);
    }

    fn batch(t: *Tracer, a: Allocator, bytes: []const u8) !Batch {
        var b: Batch = .{};
        var rest = bytes;
        const po: frame.Options = .{ .max_frame_size = frame.max_max_frame_size, .max_settings = 255 };
        while (rest.len > 0) {
            const f = switch (frame.parse(rest, po)) {
                .frame => |f| f,
                else => return error.BadOutputFrame,
            };
            rest = rest[f.len..];
            const id = f.parsed.header.stream_id;
            switch (f.parsed.frame) {
                .settings => |st| {
                    if (st.ack) {
                        try b.conn.append(a, "SETTINGS ACK");
                        continue;
                    }
                    var l: std.ArrayList(frame.Setting) = .empty;
                    var it = st.iterator();
                    while (it.next()) |e| try l.append(a, e);
                    std.mem.sort(frame.Setting, l.items, {}, struct {
                        fn lt(_: void, x: frame.Setting, y: frame.Setting) bool {
                            return @backingInt(x.id) < @backingInt(y.id);
                        }
                    }.lt);
                    var o: std.ArrayList(u8) = .empty;
                    try o.appendSlice(a, "SETTINGS");
                    for (l.items) |e| try o.print(a, " {t}={d}", .{ e.id, e.value });
                    try b.conn.append(a, o.items);
                },
                .ping => |p| try b.conn.append(a, try std.fmt.allocPrint(a, "PING ack={d} {x}", .{ @intFromBool(p.ack), @as([]const u8, &p.data) })),
                .goaway => |g| {
                    try b.conn.append(a, try std.fmt.allocPrint(a, "GOAWAY last={d} code={t}", .{ g.last_stream_id, g.code }));
                    const gw: Goaway = .{ .last = g.last_stream_id, .code = g.code, .debug = try a.dupe(u8, g.debug) };
                    b.goaway = gw;
                    t.goaway = gw;
                },
                .window_update => |inc| {
                    if (inc == 0) return error.ZeroWindowUpdate;
                    const e = try t.granted.getOrPutValue(a, id, 0);
                    e.value_ptr.* += inc;
                    if (e.value_ptr.* > 2 * @as(u64, frame.max_window_size)) return error.WindowOverflow;
                },
                .rst_stream => |code| {
                    var l: SLine = .{ .id = id, .kind = .rst };
                    try l.text.print(a, "{t}", .{code});
                    try b.lines.append(a, l);
                    if (code == .refused_stream) b.refused = true;
                },
                .data => |d| {
                    const last = lastFor(&b, id);
                    if (last) |l| if (l.kind == .data and !l.es) {
                        try l.text.appendSlice(a, d.data);
                        l.es = d.end_stream;
                        continue;
                    };
                    var l: SLine = .{ .id = id, .kind = .data, .es = d.end_stream };
                    try l.text.appendSlice(a, d.data);
                    try b.lines.append(a, l);
                },
                .headers => |hd| {
                    var block: std.ArrayList(u8) = .empty;
                    try block.appendSlice(a, hd.fragment);
                    var end = hd.end_headers;
                    while (!end) {
                        const g = switch (frame.parse(rest, po)) {
                            .frame => |g| g,
                            else => return error.BadOutputFrame,
                        };
                        if (g.parsed.header.type != .continuation or g.parsed.header.stream_id != id) return error.BadOutputFrame;
                        rest = rest[g.len..];
                        try block.appendSlice(a, g.parsed.frame.continuation.fragment);
                        end = g.parsed.frame.continuation.end_headers;
                    }
                    var l: SLine = .{ .id = id, .kind = .headers, .es = hd.end_stream };
                    try t.decode(a, block.items, &l.text);
                    if (std.mem.eql(u8, l.text.items, ":status=431")) try b.status431.append(a, id);
                    try b.lines.append(a, l);
                    for (b.order.items) |o| {
                        if (o == id) break;
                    } else try b.order.append(a, id);
                },
                else => return error.UnexpectedOutputFrame,
            }
        }
        return b;
    }

    fn lastFor(b: *Batch, id: u31) ?*SLine {
        var i = b.lines.items.len;
        while (i > 0) {
            i -= 1;
            if (b.lines.items[i].id == id) return &b.lines.items[i];
        }
        return null;
    }

    fn decode(t: *Tracer, a: Allocator, block: []const u8, out: *std.ArrayList(u8)) !void {
        var in = block;
        var first = true;
        while (true) {
            var nv: c.nghttp2_nv = undefined;
            var flags: c_int = 0;
            const rv = c.nghttp2_hd_inflate_hd3(t.inflater, &nv, &flags, in.ptr, in.len, 1);
            if (rv < 0) return error.BadOutputBlock;
            in = in[@intCast(rv)..];
            if (flags & c.NGHTTP2_HD_INFLATE_EMIT != 0) {
                if (!first) try out.append(a, ',');
                first = false;
                try out.print(a, "{s}={s}", .{ nv.name[0..nv.namelen], nv.value[0..nv.valuelen] });
            }
            if (flags & c.NGHTTP2_HD_INFLATE_FINAL != 0) {
                _ = c.nghttp2_hd_inflate_end_headers(t.inflater);
                return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Accepted divergences

/// One per INTENTIONAL.md entry the comparison can meet; nothing else is
/// accepted.
const Rule = enum {
    /// Session 3: our output already queued when the connection or its
    /// stream ends is still sent; nghttp2 drops it.
    queued_output,
    /// Limits 1, 2: the reset budget's charges and answer.
    reset_budget,
    /// Limits 3: empty and unknown frames, and the glitch budget.
    empty_budget,
    /// Limits 4: too many CONTINUATIONs (nghttp2's fatal error).
    continuations,
    /// Limits 5: a header block's bytes before decoding.
    block_bytes,
    /// HPACK 2, 3: the skip-mode cost cap and the scratch.
    hpack_cost,
    /// Limits 7, 8: the refused budget, and REFUSED_STREAM past the
    /// acknowledged maximum.
    refused,
    /// Limits 6: a head past a limit answered 431 where nghttp2 resets
    /// the stream for a field it checks first.
    head_431,
    /// Session 4: nghttp2 is done after the peer's GOAWAY.
    peer_goaway,
    /// Session 5: DATA charged to the windows per frame, not per chunk.
    window_per_frame,
};

const n_rules = @typeInfo(Rule).@"enum".field_names.len;

/// nghttp2 ended the connection with `code`, and we didn't, or later or
/// otherwise.
fn theirsFirst(og: ?Goaway, tg: ?Goaway, code: ErrorCode) bool {
    const t = tg orelse return false;
    return t.code == code and (if (og) |o| o.last > t.last or o.code != code else true);
}

fn reasonIs(g: ?Goaway, reason: []const u8) bool {
    const x = g orelse return false;
    return std.mem.eql(u8, x.debug, reason);
}

/// The rule that explains why `ours` and `theirs` differ, if any, and
/// whether it ends the comparison (true) or lets it go on.
fn classify(p: *Pair, a: Allocator, ours: *const Batch, theirs: *const Batch) !?struct { Rule, bool } {
    const og = ours.goaway;
    const tg = theirs.goaway;
    // Our limits by the reason they put in GOAWAY's debug data, nghttp2's
    // by its answer: one side's budget ran out first. The rest of the input
    // isn't compared.
    if (reasonIs(og, "too many stream resets") or (tg != null and tg.?.code == .internal_error)) return .{ .reset_budget, true };
    if (reasonIs(og, "too many empty frames") or reasonIs(og, "too many glitches") or
        theirsFirst(og, tg, .enhance_your_calm)) return .{ .empty_budget, true };
    if (reasonIs(og, "too many CONTINUATION frames") or p.ng.fatal == c.NGHTTP2_ERR_TOO_MANY_CONTINUATIONS) return .{ .continuations, true };
    // A frame past a window that nghttp2, charging chunk by chunk, took
    // because credit given back for its first chunks made room (only when
    // the input was cut).
    if (p.cut and og != null and og.?.code == .flow_control_error and (tg == null or tg.?.code != .flow_control_error))
        return .{ .window_per_frame, true };
    if (reasonIs(og, "header block too large")) return .{ .block_bytes, true };
    if (reasonIs(og, "header block too costly")) return .{ .hpack_cost, true };
    if (reasonIs(og, "too many refused streams") or
        (ours.refused and theirsFirst(og, tg, .protocol_error))) return .{ .refused, true };
    // Both ended the connection the same way, and nghttp2 dropped what it
    // had queued while handling the frame (session_is_closing): every line
    // it sent we sent too, and ours has only such frames besides.
    if (og != null and tg != null and og.?.code == tg.?.code and og.?.last == tg.?.last) {
        if (try within(a, theirs, ours, &p.excused, .queued)) return .{ .queued_output, false };
    }
    return null;
}

/// What `big` may have that `small` lacks: the frames nghttp2 drops while
/// `session_is_closing` (INTENTIONAL.md, session 4: PING and SETTINGS
/// ACKs, RST_STREAM), and at a connection error also the handler's
/// responses it had queued (session 3), on streams it sent nothing on.
const Extra = enum { closing, queued };

/// Every line of `small` is in `big` (the connection's in order, and each
/// stream's in order), and every other line of `big` is one `extra` allows.
fn within(a: Allocator, small: *const Batch, big: *const Batch, excused: *const Excused, extra: Extra) !bool {
    if (!inOrder(small.conn.items, big.conn.items, extra, false)) return false;
    var ids: std.AutoArrayHashMapUnmanaged(u31, void) = .empty;
    for (big.lines.items) |l| try ids.put(a, l.id, {});
    for (small.lines.items) |l| try ids.put(a, l.id, {});
    for (ids.keys()) |id| {
        if (excused.contains(id)) continue;
        const sl = try streamLines(a, small, id);
        if (!inOrder(sl, try streamLines(a, big, id), extra, sl.len == 0)) return false;
    }
    return true;
}

fn allowed(line: []const u8, extra: Extra, unanswered: bool) bool {
    if (std.mem.startsWith(u8, line, "PING ack=1 ") or std.mem.eql(u8, line, "SETTINGS ACK") or
        std.mem.startsWith(u8, line, "RST_STREAM ")) return true;
    if (extra != .queued or !unanswered) return false;
    for ([_][]const u8{ "HEADERS :status=200 es=0", "HEADERS :status=431 es=1", "DATA \"ok\" es=1" }) |r| {
        if (std.mem.eql(u8, line, r)) return true;
    }
    return false;
}

fn streamLines(a: Allocator, b: *const Batch, id: u31) ![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    for (b.lines.items) |x| if (x.id == id) try l.append(a, try x.render(a));
    return l.items;
}

/// `small` is a subsequence of `big`, whose other lines `extra` allows
/// (`unanswered`: `small` has none for this stream). The lines skipped are
/// `big` less `small` whatever the alignment, so the greedy one will do.
fn inOrder(small: []const []const u8, big: []const []const u8, extra: Extra, unanswered: bool) bool {
    var j: usize = 0;
    for (small) |line| {
        while (j < big.len and !std.mem.eql(u8, big[j], line)) : (j += 1) {
            if (!allowed(big[j], extra, unanswered)) return false;
        }
        if (j == big.len) return false;
        j += 1;
    }
    for (big[j..]) |line| if (!allowed(line, extra, unanswered)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// One run

const Outcome = enum { open, goaway, fatal };

const Result = struct {
    rule: ?Rule = null,
    /// Rules met that let the comparison go on.
    soft: [n_rules]usize = @splat(0),
    outcome: Outcome = .open,
};

const Pair = struct {
    gpa: Allocator,
    h: Handler = .{},
    cn: C,
    ng: Ng,
    ours: Tracer,
    theirs: Tracer,
    scratch: []u8,
    tail: std.ArrayList(u8) = .empty,
    dead: ?conn.RecvError = null,
    excused: Excused = .empty,
    opts: conn.Options,
    /// Fed in more than one chunk.
    cut: bool = false,
    /// Both sides' output since the last comparison (arena).
    ours_out: std.ArrayList(u8) = .empty,
    ng_out: std.ArrayList(u8) = .empty,

    fn create(gpa: Allocator, opts: conn.Options, plant: Plant) !*Pair {
        const p = try gpa.create(Pair);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .cn = undefined, .ng = undefined, .ours = try .init(), .theirs = try .init(), .scratch = undefined, .opts = opts };
        p.h.plant = plant;
        p.scratch = try gpa.alloc(u8, @max(opts.max_header_list_size, hpack.table_capacity));
        p.cn = try C.init(gpa, &p.h, opts);
        p.h.c = &p.cn;
        try p.ng.init(gpa, opts);
        return p;
    }

    fn destroy(p: *Pair) void {
        p.cn.deinit();
        p.ng.deinit();
        p.ours.deinit();
        p.theirs.deinit();
        p.tail.deinit(p.gpa);
        p.excused.deinit(p.gpa);
        p.gpa.free(p.scratch);
        p.gpa.destroy(p);
    }

    fn badPreface(p: *const Pair) bool {
        return if (p.dead) |e| e == error.BadPreface else false;
    }

    /// One piece: Conn takes what it can of its leftover plus `piece`,
    /// nghttp2 exactly those bytes (all of them once Conn has failed); then
    /// both are drained into the batch.
    fn feed(p: *Pair, a: Allocator, piece: []const u8) !void {
        if (p.dead != null) {
            p.ng.recv(piece);
        } else {
            try p.tail.appendSlice(p.gpa, piece);
            if (p.cn.recv(p.tail.items, 0, p.scratch)) |n| {
                p.ng.recv(p.tail.items[0..n]);
                const rest = p.tail.items.len - n;
                std.mem.copyForwards(u8, p.tail.items[0..rest], p.tail.items[n..]);
                p.tail.items.len = rest;
            } else |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    p.dead = err;
                    p.ng.recv(p.tail.items);
                    p.tail.clearRetainingCapacity();
                },
            }
        }
        try p.ours_out.appendSlice(a, try drainConn(&p.cn, a));
        try p.ng_out.appendSlice(a, try p.ng.drain(a));
    }

    /// After the peer's GOAWAY with no stream active nghttp2 wants to read
    /// no more, and the engine closes the connection.
    fn ngDone(p: *const Pair) bool {
        return p.ng.fatal == null and p.theirs.goaway == null and c.nghttp2_session_want_read(p.ng.session) == 0;
    }

    /// Drains both and compares the batch; a rule that stops returns it.
    fn compare(p: *Pair, a: Allocator, res: *Result) !bool {
        const ours = try p.ours.batch(a, p.ours_out.items);
        const theirs = try p.theirs.batch(a, p.ng_out.items);
        p.ours_out = .empty;
        p.ng_out = .empty;
        // A 431 of ours where nghttp2 reset the stream for a field it
        // checks before the list limit (INTENTIONAL.md, limits 6), or
        // answered 431 too: that stream is left out from now on. Any other
        // answer of nghttp2's is a divergence.
        for (ours.status431.items) |id| {
            if (p.excused.contains(id)) continue;
            const x = try streamLines(a, &ours, id);
            const y = try streamLines(a, &theirs, id);
            const same = x.len == y.len and for (x, y) |l, m| {
                if (!std.mem.eql(u8, l, m)) break false;
            } else true;
            if (same) continue;
            var reset = false;
            var answered = false;
            for (y) |l| {
                reset = reset or std.mem.eql(u8, l, "RST_STREAM protocol_error");
                if (std.mem.startsWith(u8, l, "HEADERS :status=")) answered = answered or !std.mem.startsWith(u8, l, "HEADERS :status=431");
            }
            if (answered or !(reset or std.mem.indexOfScalar(u31, theirs.status431.items, id) != null)) continue;
            try p.excused.put(p.gpa, id, {});
            res.soft[@backingInt(Rule.head_431)] += 1;
        }
        const ro = try ours.render(a, &p.excused);
        const rt = try theirs.render(a, &p.excused);
        const windows = try p.checkWindows(a);
        // After the peer's GOAWAY with no stream open nghttp2 is done
        // (want_read is 0, and want_write once its queue is empty; on the
        // way it drops the last frame it pops, session_is_closing), and the
        // engine closes the connection (INTENTIONAL.md, session 4):
        // `lockstep` feeds no more, what nghttp2 sent must be in ours, and
        // ours may have besides only what nghttp2 drops while closing.
        if (p.ngDone() and ours.goaway == null and try within(a, &theirs, &ours, &p.excused, .closing)) {
            res.rule = .peer_goaway;
            return true;
        }
        if (std.mem.eql(u8, ro, rt) and windows == null) return false;
        const r = (if (std.mem.eql(u8, ro, rt)) null else try classify(p, a, &ours, &theirs)) orelse {
            std.debug.print("h2 conn diff: unclassified divergence (ours fatal {?t}, nghttp2's {?d}){s}\n--- ours\n{s}--- nghttp2\n{s}", .{ p.dead, p.ng.fatal, windows orelse "", ro, rt });
            return error.Divergence;
        };
        if (r[1]) {
            res.rule = r[0];
            return true;
        }
        res.soft[@backingInt(r[0])] += 1;
        if (windows) |w| {
            std.debug.print("h2 conn diff: {s}\n", .{w});
            return error.Divergence;
        }
        return false;
    }

    /// INTENTIONAL.md, session 2: WINDOW_UPDATE amounts may differ (our
    /// batching), within half a window either way while both sides are
    /// alive and the stream can still receive. A description of the first
    /// total out of bounds, or null.
    fn checkWindows(p: *Pair, a: Allocator) !?[]const u8 {
        if (p.dead != null or p.ng.fatal != null or p.ours.goaway != null or p.theirs.goaway != null) return null;
        const conn_half: u64 = @max(conn.default_window, p.opts.connection_window) / 2;
        const stream_half: u64 = @max(conn.default_window, p.opts.initial_window) / 2;
        var ids: std.AutoHashMapUnmanaged(u31, void) = .empty;
        for ([_]*Tracer{ &p.ours, &p.theirs }) |t| {
            var it = t.granted.keyIterator();
            while (it.next()) |k| try ids.put(a, k.*, {});
        }
        var it = ids.keyIterator();
        while (it.next()) |k| {
            const id = k.*;
            const o = p.ours.granted.get(id) orelse 0;
            const t = p.theirs.granted.get(id) orelse 0;
            const half = if (id == 0) conn_half else stream_half;
            // Never more than nghttp2 by half a window, nor less, unless we
            // stopped crediting a stream that can't receive any more.
            const live = id == 0 or if (p.cn.table.get(id)) |s| s.canRecv() else false;
            if (o > t + half or (live and t > o + half))
                return try std.fmt.allocPrint(a, "; WINDOW_UPDATE totals for {d}: ours {d}, nghttp2 {d}", .{ id, o, t });
        }
        return null;
    }
};

/// Both sides in lockstep on `cuts` (one chunk: the whole input).
fn lockstep(gpa: Allocator, a: Allocator, opts: conn.Options, input: []const u8, cuts: []const usize, plant: Plant) !Result {
    const p = try Pair.create(gpa, opts, plant);
    defer p.destroy();
    p.cut = cuts.len > 1;
    var res: Result = .{};
    // Both drained after every frame, as if the writers kept up: nghttp2
    // closes a stream once its last frame is written (CLOSING until then,
    // and judged by its earlier state), Conn once that frame is queued and
    // frames DATA only when drained, so otherwise each side's answers would
    // depend on when its writer ran.
    const ends = try frameEnds(a, input);
    var e: usize = 0;
    var at: usize = 0;
    for (cuts) |n| {
        const stop = at + n;
        while (at < stop) {
            while (e < ends.len and ends[e] <= at) e += 1;
            const next = if (e < ends.len) @min(ends[e], stop) else stop;
            try p.feed(a, input[at..next]);
            at = next;
            if (p.ngDone()) break;
        }
        if (try p.compare(a, &res) or p.ngDone()) return res;
    }
    // The final state: open, GOAWAY (in the trace) or a fatal error, and
    // the last stream processed.
    errdefer std.debug.print("h2 conn diff: final state: ours {?t} last {d}, nghttp2 {?d} last {d}\n", .{ p.dead, p.cn.last_proc, p.ng.fatal, c.nghttp2_session_get_last_proc_stream_id(p.ng.session) });
    try testing.expectEqual(p.badPreface(), p.ng.fatal == c.NGHTTP2_ERR_BAD_CLIENT_MAGIC);
    if (p.ng.fatal) |f| try testing.expectEqual(c.NGHTTP2_ERR_BAD_CLIENT_MAGIC, f);
    if (p.ours.goaway == null) try testing.expectEqual(c.nghttp2_session_get_last_proc_stream_id(p.ng.session), p.cn.last_proc);
    res.outcome = if (p.badPreface()) .fatal else if (p.ours.goaway != null) .goaway else .open;
    return res;
}

/// Where each frame of `input` ends (the preface first), as far as the
/// lengths go.
fn frameEnds(a: Allocator, input: []const u8) ![]usize {
    var l: std.ArrayList(usize) = .empty;
    var pos: usize = @min(input.len, conn.client_magic.len);
    try l.append(a, pos);
    while (pos + frame.header_len <= input.len) {
        pos += frame.header_len + std.mem.readInt(u24, input[pos..][0..3], .big);
        if (pos > input.len) break;
        try l.append(a, pos);
    }
    return l.items;
}

/// Conn alone on `cuts`, drained once at the end.
fn alone(gpa: Allocator, a: Allocator, opts: conn.Options, input: []const u8, cuts: []const usize) ![]const u8 {
    var h: Handler = .{};
    var cn: C = try .init(gpa, &h, opts);
    defer cn.deinit();
    h.c = &cn;
    const scratch = try gpa.alloc(u8, @max(opts.max_header_list_size, hpack.table_capacity));
    defer gpa.free(scratch);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    var at: usize = 0;
    for (cuts) |n| {
        try tail.appendSlice(gpa, input[at..][0..n]);
        at += n;
        const k = cn.recv(tail.items, 0, scratch) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => break,
        };
        const rest = tail.items.len - k;
        std.mem.copyForwards(u8, tail.items[0..rest], tail.items[k..]);
        tail.items.len = rest;
    }
    return drainConn(&cn, a);
}

/// Split invariance: the same frames whole and cut, WINDOW_UPDATE aside, whose
/// totals per stream stay within half a window (the batching follows how
/// DATA payloads were cut).
fn expectSameOutput(a: Allocator, opts: conn.Options, one: []const u8, split: []const u8) !void {
    const x = try withoutWindowUpdates(a, one);
    const y = try withoutWindowUpdates(a, split);
    try testing.expectEqualSlices(u8, x.bytes, y.bytes);
    var it = x.granted.iterator();
    while (it.next()) |e| {
        const half: u64 = @max(conn.default_window, if (e.key_ptr.* == 0) opts.connection_window else opts.initial_window) / 2;
        const o = y.granted.get(e.key_ptr.*) orelse 0;
        try testing.expect(@max(o, e.value_ptr.*) - @min(o, e.value_ptr.*) <= half);
    }
}

fn withoutWindowUpdates(a: Allocator, bytes: []const u8) !struct { bytes: []const u8, granted: std.AutoHashMapUnmanaged(u31, u64) } {
    var out: std.ArrayList(u8) = .empty;
    var granted: std.AutoHashMapUnmanaged(u31, u64) = .empty;
    var rest = bytes;
    while (rest.len > 0) {
        const f = switch (frame.parse(rest, .{ .max_frame_size = frame.max_max_frame_size, .max_settings = 255 })) {
            .frame => |f| f,
            else => return error.BadOutputFrame,
        };
        if (f.parsed.frame == .window_update) {
            const e = try granted.getOrPutValue(a, f.parsed.header.stream_id, 0);
            e.value_ptr.* += f.parsed.frame.window_update;
        } else try out.appendSlice(a, rest[0..f.len]);
        rest = rest[f.len..];
    }
    return .{ .bytes = out.items, .granted = granted };
}

// ---------------------------------------------------------------------------
// Inputs and counts

const Profile = struct { name: []const u8, opts: conn.Options };

/// Config defaults, and limits small enough to fire within short inputs,
/// with rates of 0 so that nghttp2's wall clock never matters.
const profiles = [_]Profile{
    .{ .name = "default", .opts = .{} },
    .{ .name = "tight", .opts = .{
        .max_concurrent_streams = 4,
        .initial_window = 1024,
        .connection_window = conn.default_window,
        .max_header_list_size = 512,
        .max_header_count = 8,
        .max_continuations = 2,
        .stream_reset_burst = 10,
        .stream_reset_rate = 0,
        .refused_stream_burst = 5,
        .refused_stream_rate = 0,
        .limits = .{ .control_frame_budget = 20, .empty_frame_rate = 10, .glitch_burst = 10, .glitch_rate = 0 },
    } },
};

const Stats = struct {
    inputs: usize = 0,
    runs: usize = 0,
    /// Lockstep runs compared to the end with no rule needed.
    identical: usize = 0,
    rules: [n_rules]usize = @splat(0),
    outcomes: [3]usize = @splat(0),

    fn print(s: *const Stats, what: []const u8, profile: []const u8) void {
        std.debug.print("h2 conn diff: {s}, {s}: {d} inputs, {d} lockstep runs, {d} identical; outcomes open {d}, goaway {d}, fatal {d}; rules", .{ what, profile, s.inputs, s.runs, s.identical, s.outcomes[0], s.outcomes[1], s.outcomes[2] });
        inline for (@typeInfo(Rule).@"enum".field_names, 0..) |name, i| std.debug.print(" {s}={d}", .{ name, s.rules[i] });
        std.debug.print("\n", .{});
    }
};

/// Chunk sizes summing to `len`: byte runs, small or large random pieces.
fn randomCuts(a: Allocator, r: std.Random, len: usize) ![]usize {
    var cuts: std.ArrayList(usize) = .empty;
    const max: usize = switch (r.uintLessThan(u8, 3)) {
        0 => 8,
        1 => 200,
        else => @max(1, len / 3),
    };
    var left = len;
    while (left > 0) {
        const n = @min(left, 1 + r.uintLessThan(usize, max));
        try cuts.append(a, n);
        left -= n;
    }
    return cuts.items;
}

/// One input: lockstep whole and on `lockstep_runs` random cuts, then Conn
/// alone whole and on the last cuts.
fn runInput(gpa: Allocator, r: std.Random, opts: conn.Options, input: []const u8, lockstep_runs: usize, stats: *Stats) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    errdefer std.debug.print("h2 conn diff: input ({d} bytes): \"{f}\"\n", .{ input.len, std.zig.fmtString(input) });
    stats.inputs += 1;
    const whole = [_]usize{input.len};
    const one = try lockstep(gpa, a, opts, input, if (input.len == 0) &.{} else &whole, .none);
    try count(stats, one);
    stats.outcomes[@backingInt(one.outcome)] += 1;
    var cuts: []usize = &.{};
    for (0..lockstep_runs) |_| {
        cuts = try randomCuts(a, r, input.len);
        errdefer std.debug.print("h2 conn diff: cuts {any}\n", .{cuts});
        try count(stats, try lockstep(gpa, a, opts, input, cuts, .none));
    }
    errdefer std.debug.print("h2 conn diff: Conn alone on cuts {any}\n", .{cuts});
    try expectSameOutput(a, opts, try alone(gpa, a, opts, input, &whole), try alone(gpa, a, opts, input, cuts));
}

fn count(stats: *Stats, res: Result) !void {
    stats.runs += 1;
    for (res.soft, 0..) |n, i| stats.rules[i] += @intFromBool(n > 0);
    if (res.rule) |r| stats.rules[@backingInt(r)] += 1 else if (std.mem.allEqual(usize, &res.soft, 0)) {
        stats.identical += 1;
    }
}

fn readU32(data: []const u8, pos: *usize) u32 {
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

test "h2 conn diff: nghttp2's fuzz corpus" {
    // tools/pack_h2_sessions.py: u32 count, then u32 length + bytes each.
    const data = @embedFile("testdata/h2_sessions.bin");
    var prng: std.Random.DefaultPrng = .init(0x68326466);
    for (profiles) |pf| {
        var stats: Stats = .{};
        var pos: usize = 0;
        for (0..readU32(data, &pos)) |_| {
            const n = readU32(data, &pos);
            try runInput(testing.allocator, prng.random(), pf.opts, data[pos..][0..n], 2, &stats);
            pos += n;
        }
        try testing.expectEqual(data.len, pos);
        stats.print("nghttp2's corpus", pf.name);
        try testing.expectEqual(136, stats.inputs);
        try testing.expect(stats.identical >= 130 * 3 / 2);
    }
}

test "h2 conn diff: the conn recv fuzz seeds" {
    const seeds = try conn_test.fuzzSeeds(testing.allocator);
    defer {
        for (seeds) |s| testing.allocator.free(s);
        testing.allocator.free(seeds);
    }
    var prng: std.Random.DefaultPrng = .init(0x73656564);
    for (profiles) |pf| {
        var stats: Stats = .{};
        for (seeds) |seed| {
            // fuzzOne's handshake, then the frames (the split byte dropped).
            var input: std.ArrayList(u8) = .empty;
            defer input.deinit(testing.allocator);
            try input.appendSlice(testing.allocator, conn.client_magic ++ "\x00\x00\x00\x04\x00\x00\x00\x00\x00" ++ "\x00\x00\x00\x04\x01\x00\x00\x00\x00");
            try input.appendSlice(testing.allocator, seed[1..]);
            try runInput(testing.allocator, prng.random(), pf.opts, input.items, 2, &stats);
        }
        stats.print("conn recv seeds", pf.name);
        try testing.expectEqual(seeds.len, stats.inputs);
    }
}

test "h2 conn diff: the harness catches a planted divergence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try conn_test.T.create(testing.allocator, .{});
    defer t.destroy();
    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(a, conn.client_magic);
    for ([_][]const u8{ try t.settings(&.{}), try t.settingsAck(), try t.headers(1, &conn_test.get, true), try t.headers(3, &conn_test.post, false), try t.data(3, "abc", true) }) |f|
        try input.appendSlice(a, f);
    const whole = [_]usize{input.items.len};
    // Two DATA frames for one: normalized away.
    const split = try lockstep(testing.allocator, a, .{}, input.items, &whole, .split);
    try testing.expectEqual(null, split.rule);
    try testing.expectEqual(Outcome.open, split.outcome);
    // 201 for 200, and a 431 to requests under the limits: caught.
    std.debug.print("h2 conn diff: planted divergences follow\n", .{});
    try testing.expectError(error.Divergence, lockstep(testing.allocator, a, .{}, input.items, &whole, .status));
    try testing.expectError(error.Divergence, lockstep(testing.allocator, a, .{}, input.items, &whole, .status431));
    // A PING of ours after the peer's GOAWAY, while a stream is open and
    // once nghttp2 is done: neither peer_goaway nor its stop excuses a
    // frame nghttp2 never drops.
    const head = [_][]const u8{ conn.client_magic, try t.settings(&.{}), try t.settingsAck() };
    for ([_][]const []const u8{
        &.{ try t.headers(1, &conn_test.post, false), try t.goaway(0, .no_error), try t.data(1, "abc", true) },
        &.{ try t.headers(1, &conn_test.get, true), try t.goaway(0, .no_error), try t.ping(false, @splat(1)) },
    }) |frames| {
        var in: std.ArrayList(u8) = .empty;
        for (head) |f| try in.appendSlice(a, f);
        for (frames) |f| try in.appendSlice(a, f);
        const one = [_]usize{in.items.len};
        const clean = try lockstep(testing.allocator, a, .{}, in.items, &one, .none);
        try testing.expectEqual(Outcome.open, clean.outcome);
        try testing.expectError(error.Divergence, lockstep(testing.allocator, a, .{}, in.items, &one, .goaway_ping));
    }
}

// ---------------------------------------------------------------------------
// The generator

/// Frames by type, as written (10: unknown types).
const Types = [11]usize;

/// A client session written frame by frame from a small model of its own
/// streams, so that most frames are legal and the sessions run long; about
/// one action in 30 is a mutation (every frame type, CONTINUATION runs,
/// window games, resets, invalid lengths, IDs and fields). In the default
/// profile it stays under every budget, so that nghttp2's wall clock never
/// matters (its limiters refill per second; Conn's time is fixed).
const Gen = struct {
    a: Allocator,
    r: std.Random,
    opts: conn.Options,
    bounded: bool,
    types: *Types,
    out: std.ArrayList(u8) = .empty,
    /// The client's HPACK: nghttp2's deflater (indexing) or our encoder.
    deflater: ?*c.nghttp2_hd_deflater = null,
    enc: hpack.Encoder = .{},
    next_id: u31 = 1,
    streams: std.ArrayList(GStream) = .empty,
    acked: bool = false,
    /// Frames Conn's empty-frame budget counts.
    empties: usize = 0,

    const GStream = struct { id: u31, ended: bool = false };

    fn rawLen(g: *Gen, ty: u8, fl: u8, id: u32, len: u24, payload: []const u8) !void {
        var h: [frame.header_len]u8 = undefined;
        std.mem.writeInt(u24, h[0..3], len, .big);
        h[3] = ty;
        h[4] = fl;
        std.mem.writeInt(u32, h[5..9], id & 0x7fffffff, .big);
        try g.out.appendSlice(g.a, &h);
        try g.out.appendSlice(g.a, payload);
        g.types[@min(ty, 10)] += 1;
        if (ty > 9) g.empties += 1;
    }

    fn raw(g: *Gen, ty: u8, fl: u8, id: u32, payload: []const u8) !void {
        return g.rawLen(ty, fl, id, @intCast(payload.len), payload);
    }

    fn chance(g: *Gen, n: u32) bool {
        return g.r.uintLessThan(u32, n) == 0;
    }

    fn block(g: *Gen, fs: []const Field) ![]const u8 {
        if (g.deflater) |d| {
            const nva = try g.a.alloc(c.nghttp2_nv, fs.len);
            for (fs, nva) |f, *nv| nv.* = .{ .name = @constCast(f.name.ptr), .namelen = f.name.len, .value = @constCast(f.value.ptr), .valuelen = f.value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
            const buf = try g.a.alloc(u8, c.nghttp2_hd_deflate_bound(d, nva.ptr, nva.len));
            const rv = c.nghttp2_hd_deflate_hd(d, buf.ptr, buf.len, nva.ptr, nva.len);
            if (rv < 0) return error.DeflateFailed;
            return buf[0..@intCast(rv)];
        }
        const buf = try g.a.alloc(u8, hpack.Encoder.bound(fs));
        return buf[0..try g.enc.encode(buf, fs)];
    }

    /// A request head; `bad` breaks one rule of RFC 9113 §8.2-8.3.
    fn request(g: *Gen, post: bool, cl: ?usize, bad: bool) ![]const Field {
        var l: std.ArrayList(Field) = .empty;
        try l.append(g.a, .{ .name = ":method", .value = if (post) "POST" else "GET" });
        try l.append(g.a, .{ .name = ":scheme", .value = "https" });
        try l.append(g.a, .{ .name = ":path", .value = if (g.chance(3)) "/" else try std.fmt.allocPrint(g.a, "/p/{d}", .{g.r.int(u16)}) });
        try l.append(g.a, .{ .name = ":authority", .value = "example.org" });
        if (cl) |n| try l.append(g.a, .{ .name = "content-length", .value = try std.fmt.allocPrint(g.a, "{d}", .{n}) });
        const pool = [_][2][]const u8{ .{ "user-agent", "gen/1" }, .{ "accept", "*/*" }, .{ "cookie", "a=1" }, .{ "cookie", "b=2" }, .{ "x-trace", "0123456789abcdef" } };
        const more = if (g.chance(8)) 4 + g.r.uintLessThan(usize, 9) else g.r.uintLessThan(usize, 4);
        for (0..more) |_| {
            if (g.chance(10)) {
                // Large enough for the tight profile's list limit.
                const v = try g.a.alloc(u8, g.r.uintAtMost(usize, 600));
                @memset(v, 'v');
                try l.append(g.a, .{ .name = "x-big", .value = v });
            } else {
                const e = pool[g.r.uintLessThan(usize, pool.len)];
                try l.append(g.a, .{ .name = e[0], .value = e[1] });
            }
        }
        if (bad) switch (g.r.uintLessThan(u8, 6)) {
            0 => try l.append(g.a, .{ .name = "X-Upper", .value = "1" }),
            1 => try l.append(g.a, .{ .name = "connection", .value = "close" }),
            2 => _ = l.orderedRemove(2),
            3 => try l.append(g.a, .{ .name = ":method", .value = "GET" }),
            4 => try l.append(g.a, .{ .name = "te", .value = "gzip" }),
            else => try l.append(g.a, .{ .name = ":authority", .value = "late.example" }),
        };
        return l.items;
    }

    /// HEADERS (and `cont` CONTINUATIONs) carrying `frag`.
    fn headers(g: *Gen, id: u31, frag: []const u8, es: bool, cont: usize, pad: ?u8, prio: bool) !void {
        var cuts: [16]usize = undefined;
        for (cuts[0..cont]) |*x| x.* = g.r.uintAtMost(usize, frag.len);
        std.mem.sort(usize, cuts[0..cont], {}, std.sort.asc(usize));
        const first_end = if (cont > 0) cuts[0] else frag.len;
        var p: std.ArrayList(u8) = .empty;
        if (pad) |n| try p.append(g.a, n);
        if (prio) {
            var dep: [4]u8 = undefined;
            std.mem.writeInt(u32, &dep, if (g.chance(2)) 0 else g.r.uintAtMost(u32, g.next_id) & ~@as(u32, 1) | 1, .big);
            if (dep[3] == @as(u8, @truncate(id)) and std.mem.readInt(u32, &dep, .big) == id) dep[3] -%= 2;
            try p.appendSlice(g.a, &dep);
            try p.append(g.a, g.r.int(u8));
        }
        try p.appendSlice(g.a, frag[0..first_end]);
        if (pad) |n| try p.appendNTimes(g.a, 0, n);
        var fl: u8 = 0;
        if (es) fl |= frame.flags.end_stream;
        if (cont == 0) fl |= frame.flags.end_headers;
        if (pad != null) fl |= frame.flags.padded;
        if (prio) fl |= frame.flags.priority;
        if (frag.len == 0 and !es) g.empties += 1;
        try g.raw(1, fl, id, p.items);
        var at = first_end;
        for (0..cont) |i| {
            const end = if (i + 1 < cont) cuts[i + 1] else frag.len;
            if (end == at and i + 1 < cont) g.empties += 1;
            try g.raw(9, if (i + 1 == cont) frame.flags.end_headers else 0, id, frag[at..end]);
            at = end;
        }
    }

    fn newRequest(g: *Gen, cont: usize) !void {
        const id = g.next_id;
        g.next_id += 2;
        const post = g.r.boolean();
        const es = !post or g.chance(4);
        const cl: ?usize = if (post and g.chance(3)) g.r.uintAtMost(usize, 300) else null;
        const frag = try g.block(try g.request(post, cl, false));
        try g.headers(id, frag, es, cont, if (g.chance(10)) g.r.uintLessThan(u8, 32) else null, g.chance(10));
        try g.streams.append(g.a, .{ .id = id, .ended = es });
    }

    fn pick(g: *Gen, open_only: bool) ?*GStream {
        var n: usize = 0;
        for (g.streams.items) |s| n += @intFromBool(!open_only or !s.ended);
        if (n == 0) return null;
        var k = g.r.uintLessThan(usize, n);
        for (g.streams.items) |*s| if (!open_only or !s.ended) {
            if (k == 0) return s;
            k -= 1;
        };
        unreachable;
    }

    fn data(g: *Gen, id: u31, len: usize, es: bool, pad: ?u8) !void {
        var p: std.ArrayList(u8) = .empty;
        if (pad) |n| try p.append(g.a, n);
        try p.appendNTimes(g.a, 'd', len);
        if (pad) |n| try p.appendNTimes(g.a, 0, n);
        if (p.items.len == 0 and !es) g.empties += 1;
        var fl: u8 = if (es) frame.flags.end_stream else 0;
        if (pad != null) fl |= frame.flags.padded;
        try g.raw(0, fl, id, p.items);
    }

    fn dataLen(g: *Gen) usize {
        return if (g.chance(12)) 300 + g.r.uintAtMost(usize, 3000) else g.r.uintAtMost(usize, 300);
    }

    fn rst(g: *Gen, id: u32, code: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, code, .big);
        try g.raw(3, 0, id, &b);
    }

    fn windowUpdate(g: *Gen, id: u32, inc: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, inc, .big);
        try g.raw(8, 0, id, &b);
    }

    fn ping(g: *Gen, ack: bool) !void {
        var b: [8]u8 = undefined;
        g.r.bytes(&b);
        try g.raw(6, if (ack) frame.flags.ack else 0, 0, &b);
    }

    fn priority(g: *Gen, id: u32, dep: u32) !void {
        var b: [5]u8 = undefined;
        std.mem.writeInt(u32, b[0..4], dep | (if (g.chance(4)) @as(u32, 1) << 31 else 0), .big);
        b[4] = g.r.int(u8);
        try g.raw(2, 0, id, &b);
    }

    fn settings(g: *Gen, first: bool) !void {
        var p: std.ArrayList(u8) = .empty;
        for (0..g.r.uintAtMost(usize, 3)) |_| {
            const e: [2]u32 = switch (g.r.uintLessThan(u8, 8)) {
                0 => .{ 1, g.r.uintAtMost(u32, 8192) },
                1 => .{ 2, 0 },
                2 => .{ 3, g.r.uintAtMost(u32, 1000) },
                3 => .{ 4, switch (g.r.uintLessThan(u8, 6)) {
                    0 => 0,
                    1 => 1,
                    2 => 100,
                    3 => 65535,
                    4 => 1 << 20,
                    else => g.r.uintAtMost(u32, 1 << 17),
                } },
                4 => .{ 5, frame.min_max_frame_size + g.r.uintAtMost(u32, 1 << 15) },
                5 => .{ 6, g.r.int(u32) },
                6 => .{ 9, if (first) 1 else 0 },
                else => .{ 0x10 + g.r.uintAtMost(u32, 0xff), g.r.int(u32) },
            };
            // NO_RFC7540_PRIORITIES only in the first SETTINGS (it can't change).
            if (e[0] == 9 and !first) continue;
            var b: [6]u8 = undefined;
            std.mem.writeInt(u16, b[0..2], @intCast(e[0]), .big);
            std.mem.writeInt(u32, b[2..6], e[1], .big);
            try p.appendSlice(g.a, &b);
        }
        try g.raw(4, 0, 0, p.items);
    }

    fn action(g: *Gen) !void {
        const roll = g.r.uintLessThan(u8, 100);
        switch (roll) {
            0...29 => try g.newRequest(0),
            30...47 => if (g.pick(true)) |s| {
                const es = g.chance(3);
                try g.data(s.id, g.dataLen(), es, if (g.chance(10)) g.r.uintLessThan(u8, 20) else null);
                s.ended = es;
            } else try g.newRequest(0),
            48...54 => if (!g.acked) {
                try g.raw(4, frame.flags.ack, 0, "");
                g.acked = true;
            } else try g.ping(false),
            55...59 => if (g.pick(false)) |s| {
                try g.rst(s.id, g.r.uintLessThan(u32, 14));
                s.ended = true;
            },
            60...65 => try g.windowUpdate(if (g.chance(3)) 0 else if (g.pick(false)) |s| s.id else 0, 1 + g.r.uintLessThan(u32, 70000)),
            66...70 => try g.ping(g.chance(10)),
            71...74 => {
                const id: u31 = if (g.pick(false)) |s| s.id else g.next_id + 2 * g.r.uintLessThan(u31, 4);
                try g.priority(id, if (g.chance(2)) 0 else id +% 2);
            },
            75...78 => try g.settings(false),
            79...82 => if (g.pick(true)) |s| {
                try g.headers(s.id, try g.block(&.{.{ .name = "x-trailer", .value = "t" }}), true, 0, null, false);
                s.ended = true;
            },
            83...85 => if (!g.bounded or g.empties < 60) {
                const len = g.r.uintAtMost(usize, 16);
                const p = try g.a.alloc(u8, len);
                g.r.bytes(p);
                try g.raw(0x0a + g.r.uintLessThan(u8, 0xf6), g.r.int(u8), g.r.uintAtMost(u32, 9), p);
            },
            86 => try g.raw(7, 0, 0, "\x00\x00\x00\x00\x00\x00\x00\x00bye"),
            // Past max_continuations now and then.
            87...92 => try g.newRequest(if (g.chance(20)) g.opts.max_continuations + 1 else 1 + g.r.uintLessThan(usize, g.opts.max_continuations)),
            93...95 => if (g.pick(true)) |s| if (!g.bounded or g.empties < 60) try g.data(s.id, 0, false, null),
            else => try g.ping(true),
        }
    }

    fn mutation(g: *Gen) !void {
        const s = g.pick(false);
        const any_id: u31 = if (s) |x| x.id else 1;
        switch (g.r.uintLessThan(u8, 26)) {
            0 => try g.headers(g.next_id + 1, try g.block(try g.request(false, null, false)), true, 0, null, false),
            1 => try g.headers(if (g.next_id > 3) g.next_id - 4 else 1, try g.block(try g.request(false, null, false)), true, 0, null, false),
            2 => try g.data(g.next_id + 2, 10, false, null),
            3 => for (g.streams.items) |x| if (x.ended) break try g.data(x.id, 5, g.r.boolean(), null) else {} else try g.data(any_id, 5, false, null),
            4 => try g.windowUpdate(if (g.r.boolean()) 0 else any_id, 0),
            5 => {
                try g.windowUpdate(if (g.r.boolean()) 0 else any_id, 0x7fffffff);
                try g.windowUpdate(if (g.r.boolean()) 0 else any_id, 0x7fffffff);
            },
            6 => {
                const shapes = [_][2]u8{ .{ 3, 3 }, .{ 3, 5 }, .{ 6, 7 }, .{ 8, 3 }, .{ 2, 4 }, .{ 4, 5 } };
                const sh = shapes[g.r.uintLessThan(usize, shapes.len)];
                const p: [8]u8 = @splat(0);
                try g.raw(sh[0], 0, if (sh[0] == 6 or sh[0] == 4) 0 else any_id, p[0..sh[1]]);
            },
            7 => {
                const n = frame.min_max_frame_size + 1 + g.r.uintAtMost(usize, 100);
                const p = try g.a.alloc(u8, n);
                @memset(p, 'o');
                try g.raw(0, 0, any_id, p);
            },
            8 => {
                const bad = [_][2]u32{ .{ 2, 2 }, .{ 4, 0x80000000 }, .{ 5, 100 }, .{ 5, 1 << 24 } };
                const e = bad[g.r.uintLessThan(usize, bad.len)];
                var b: [6]u8 = undefined;
                std.mem.writeInt(u16, b[0..2], @intCast(e[0]), .big);
                std.mem.writeInt(u32, b[2..6], e[1], .big);
                try g.raw(4, 0, 0, &b);
            },
            9 => try g.raw(9, frame.flags.end_headers, any_id, try g.block(&.{.{ .name = "x", .value = "y" }})),
            10 => {
                const frag = try g.block(try g.request(false, null, false));
                try g.raw(1, frame.flags.end_stream, g.next_id, frag[0 .. frag.len / 2]);
                g.next_id += 2;
                if (g.r.boolean()) try g.ping(false) else try g.raw(9, frame.flags.end_headers, g.next_id, frag[frag.len / 2 ..]);
            },
            11 => {
                var p: std.ArrayList(u8) = .empty;
                try p.appendSlice(g.a, &.{ 0, 0, 0, 2 });
                try p.appendSlice(g.a, try g.block(try g.request(false, null, false)));
                try g.raw(5, frame.flags.end_headers, any_id, p.items);
            },
            12 => try g.priority(any_id, any_id),
            13 => if (g.pick(true)) |x| {
                const n = if (g.bounded) @min(30, 60 -| g.empties) else 5 + g.r.uintLessThan(usize, 25);
                for (0..n) |_| try g.data(x.id, 0, false, null);
            },
            14 => if (g.pick(true)) |x| {
                // Padding as long as the payload, or longer.
                const n = g.r.uintAtMost(u8, 10);
                var p: std.ArrayList(u8) = .empty;
                try p.append(g.a, n + g.r.uintAtMost(u8, 2));
                try p.appendNTimes(g.a, 'p', n);
                try g.raw(0, frame.flags.padded, x.id, p.items);
            },
            15 => {
                const frag = try g.block(try g.request(false, null, false));
                try g.headers(g.next_id, frag[0..g.r.uintLessThan(usize, @max(1, frag.len))], true, 0, null, false);
                g.next_id += 2;
            },
            16 => {
                try g.headers(g.next_id, try g.block(try g.request(g.r.boolean(), null, true)), true, 0, null, false);
                try g.streams.append(g.a, .{ .id = g.next_id, .ended = true });
                g.next_id += 2;
            },
            17 => {
                const id = g.next_id;
                g.next_id += 2;
                const cl = g.r.uintAtMost(usize, 20);
                try g.headers(id, try g.block(try g.request(true, cl, false)), false, 0, null, false);
                try g.data(id, cl + 1 + g.r.uintAtMost(usize, 5) -| (if (g.r.boolean()) 2 * cl + 2 else 0), true, null);
                try g.streams.append(g.a, .{ .id = id, .ended = true });
            },
            18 => try g.raw(4, frame.flags.ack, 0, ""),
            19 => if (g.out.items.len > conn.client_magic.len) {
                const i = conn.client_magic.len + g.r.uintLessThan(usize, g.out.items.len - conn.client_magic.len);
                g.out.items[i] ^= @as(u8, 1) << g.r.int(u3);
            },
            20 => try g.rst(g.next_id + 2, 8),
            21 => try g.data(0, 3, false, null),
            22 => try g.windowUpdate(g.next_id + 4, 10),
            23 => for (0..10 + g.r.uintLessThan(usize, 30)) |_| try g.ping(false),
            24 => for (0..5 + g.r.uintLessThan(usize, 10)) |_| {
                try g.newRequest(0);
                try g.rst(g.next_id - 2, 8);
                g.streams.items[g.streams.items.len - 1].ended = true;
            },
            else => for (0..6 + g.r.uintLessThan(usize, 5)) |_| {
                const id = g.next_id;
                g.next_id += 2;
                try g.headers(id, try g.block(try g.request(true, null, false)), false, 0, null, false);
                try g.streams.append(g.a, .{ .id = id });
            },
        }
    }
};

fn generate(a: Allocator, r: std.Random, opts: conn.Options, bounded: bool, types: *Types) ![]const u8 {
    var g: Gen = .{ .a = a, .r = r, .opts = opts, .bounded = bounded, .types = types };
    if (r.boolean()) {
        var d: ?*c.nghttp2_hd_deflater = null;
        if (c.nghttp2_hd_deflate_new(&d, 4096) != 0) return error.OutOfMemory;
        g.deflater = d;
    }
    defer if (g.deflater) |d| c.nghttp2_hd_deflate_del(d);
    try g.out.appendSlice(a, conn.client_magic);
    if (g.chance(100)) g.out.items[r.uintLessThan(usize, conn.client_magic.len)] ^= 0x20;
    if (g.chance(40)) try g.ping(false) else try g.settings(true);
    for (0..1 + r.uintLessThan(usize, 40)) |_| {
        if (g.chance(30)) try g.mutation() else try g.action();
    }
    return g.out.items;
}

test "h2 conn diff: 5000 generated sessions" {
    var prng: std.Random.DefaultPrng = .init(0x68326d32);
    const r = prng.random();
    var types: Types = @splat(0);
    for (profiles, 0..) |pf, i| {
        var stats: Stats = .{};
        for (0..2500) |_| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const input = try generate(arena.allocator(), r, pf.opts, i == 0, &types);
            try runInput(testing.allocator, r, pf.opts, input, 1, &stats);
        }
        stats.print("generated sessions", pf.name);
        // Every session ran, most compared to the end, ending in each way;
        // in the tight profile every rule was needed at least once (one
        // that never fires shows here).
        try testing.expectEqual(2500, stats.inputs);
        try testing.expect(stats.identical >= 2000);
        try testing.expect(stats.outcomes[0] >= 1000 and stats.outcomes[1] >= 400 and stats.outcomes[2] >= 10);
        if (i == 1) for (stats.rules) |n| try testing.expect(n > 0);
    }
    std.debug.print("h2 conn diff: generated frames by type {any}\n", .{types});
    for (types) |n| try testing.expect(n >= 100);
}
