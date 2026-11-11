// Translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_session.c and lib/nghttp2_http.c. See LICENSE.nghttp2 and
// THIRD_PARTY_NOTICES. The output side (the submit functions, DATA framing
// in `pending`, the WINDOW_UPDATE batching) is Anole's own.

//! The sans-IO HTTP/2 protocol core (research/h2h3-takeover/PLAN.md §3.2):
//! `recv` takes the bytes the transport read, runs RFC 9113's connection
//! and stream state machines over them and calls the handler; the submit
//! functions queue output in `out`, which the transport drains with
//! `pending` and `advance`. Nothing here reads a clock, yields, takes a
//! lock or does I/O: one connection, on one executor.
//!
//! The inbound machine is nghttp2's `nghttp2_session_mem_recv2` with its
//! checks in nghttp2's order (each with its nghttp2 site and wording), and
//! the fork patch's RFC 9113 strictness (PLAN §5.2), collapsed from its
//! byte-at-a-time states to "whole frames, except that a DATA payload is
//! delivered as it arrives". The caller's buffer must hold
//! 9 + `Options.max_frame_size` bytes: a frame other than DATA is taken only
//! once it is whole.
//!
//! **The handler** (`H`, checked at comptime; `Error` is error.ResetStream,
//! which resets the stream with INTERNAL_ERROR):
//!
//!   * `onStreamOpen(h, s) Error!void`: a request's HEADERS began;
//!   * `onField(h, s, name, value) Error!void`: one field of its head, or of
//!     its trailers while `s.flags.in_trailers`. **`name` and `value` are
//!     valid only during the call** (they point into the read bytes, the
//!     HPACK table or the scratch): the handler copies what it keeps;
//!   * `onHeadersEnd(h, s, end_stream) Error!void`: the head (or trailers)
//!     is complete and valid; with `end_stream` the peer's half has already
//!     closed (`s.state` says so; `s` may even be closed, if we ended ours
//!     first, and stays valid until onStreamClose);
//!   * `onData(h, s, bytes, end_stream) Error!void`: request body bytes, a
//!     slice of the read bytes valid during the call. The handler gives the
//!     flow-control credit back with `consumed` once it is done with them,
//!     **also when it fails** (before returning, or later with `s` null):
//!     Conn gives back only the bytes it doesn't deliver;
//!   * `onStreamClose(h, s, code) void`: the stream is closed; `s` is
//!     invalid once it returns. It may come after onStreamOpen and some
//!     onField calls with no onHeadersEnd (a head past a limit, answered
//!     431 by Conn). Never runs inside another callback: closes
//!     are deferred to the end of the outermost Conn call. **On a normal
//!     end it runs inside the `pending` call that framed the last DATA,
//!     before the writer has written it**: the response's parts may still
//!     be borrowed by `out`, so their owner waits for `borrowing()` false
//!     or `out.sent_total >= out.mark()` (nghttp2 closes only once the
//!     frame is sent, after copying the body);
//!   * `onWindow(h, s) void`: send credit arrived for `s`, or for the
//!     connection or every stream at once (null);
//!   * `onGoaway(h, last_id, code) void`, `onPingAck(h, data) void`.
//!
//! A handler may call the submit functions, `reset` and `consumed` from
//! inside a callback; Conn re-checks the stream after each one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const fields = @import("fields.zig");
const limits = @import("limits.zig");
const streams = @import("streams.zig");
const Out = @import("out.zig").Out;
const config = @import("../config.zig");

pub const Stream = streams.Stream;
pub const ErrorCode = frame.ErrorCode;

pub const Role = enum { server, client };

/// What a handler callback may fail with: the stream is reset with
/// INTERNAL_ERROR (nghttp2's NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE).
pub const Error = error{ResetStream};

pub const RecvError = error{
    /// A GOAWAY is queued in `out` (`Conn.goaway_sent` has its code): flush
    /// `out`, then close. Every later `recv` fails the same way.
    ConnectionError,
    /// The client preface was wrong; nothing is queued (RFC 9113 §3.4
    /// allows the GOAWAY to be omitted, and nghttp2 sends none). Close.
    BadPreface,
    /// Fatal: close the connection.
    OutOfMemory,
};

pub const SubmitError = error{
    OutOfMemory,
    /// The stream can't take this: closed, our half already ended, or (for
    /// DATA and trailers) no response head yet.
    StreamClosed,
    /// The encoded header block is over `max_headers_len`.
    HeadersTooLarge,
};

/// RFC 9113 §3.4.
pub const client_magic = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
/// RFC 9113 §6.9.2: the windows before SETTINGS say otherwise.
pub const default_window = 65535;
/// The largest header block we send (nghttp2's NGHTTP2_MAX_HEADERSLEN).
pub const max_headers_len = 65536;

/// config.ServerConfig's defaults, so that every limit's default number
/// lives in one place (config.zig, or limits.Limits for those with no key).
const h2_defaults: config.ServerConfig.Http2 = .{};

/// The connection's limits. The defaults are config.ServerConfig.Http2's
/// and Request's (M3 maps the config into this), except `max_frame_size`,
/// which has no config key and is advertised only above 16384, and
/// `limits`, whose keys come with M3 (PLAN §5.4).
pub const Options = struct {
    /// SETTINGS_MAX_CONCURRENT_STREAMS (`max_concurrent_streams`); a
    /// request past it is refused (REFUSED_STREAM, the refused budget).
    max_concurrent_streams: u32 = h2_defaults.max_concurrent_streams,
    /// SETTINGS_INITIAL_WINDOW_SIZE (`stream_window`).
    initial_window: u31 = h2_defaults.stream_window,
    /// The connection's receive window (`connection_window`), at least
    /// 65535: raised with a WINDOW_UPDATE right after our SETTINGS.
    connection_window: u31 = h2_defaults.connection_window,
    /// SETTINGS_MAX_FRAME_SIZE.
    max_frame_size: u24 = frame.min_max_frame_size,
    /// SETTINGS_MAX_HEADER_LIST_SIZE (`max_header_list_size`); also the
    /// most a header block may take on the wire before it is decoded
    /// (PLAN §5.4).
    max_header_list_size: u32 = h2_defaults.max_header_list_size,
    /// Regular fields in a request head (`request.max_header_count`):
    /// more is answered 431. Cookie crumbs count once, pseudo-headers not.
    max_header_count: usize = (config.ServerConfig.Request{}).max_header_count,
    /// CONTINUATION frames after one HEADERS (`max_continuations`).
    max_continuations: u32 = h2_defaults.max_continuations,
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL (`enable_connect_protocol`).
    enable_connect_protocol: bool = false,
    /// The rapid-reset budget (`stream_reset_burst/rate`, D15 point 1).
    stream_reset_burst: u64 = h2_defaults.stream_reset_burst,
    stream_reset_rate: u64 = h2_defaults.stream_reset_rate,
    /// Streams refused before a handler saw them
    /// (`refused_stream_burst/rate`).
    refused_stream_burst: u64 = h2_defaults.refused_stream_burst,
    refused_stream_rate: u64 = h2_defaults.refused_stream_rate,
    limits: limits.Limits = .{},
    /// The stream table's hash seed: a CSPRNG value per connection in
    /// production (streams.StreamTable).
    seed: u64 = 0,
};

/// The settings one side enforces. Our own apply once the peer
/// acknowledges them (RFC 9113 §6.5.3); until then nghttp2's defaults.
const Local = struct {
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window: u31 = default_window,
    max_frame_size: u24 = frame.min_max_frame_size,
};

const Remote = struct {
    max_concurrent_streams: u32 = std.math.maxInt(u32),
    initial_window: u31 = default_window,
    max_frame_size: u24 = frame.min_max_frame_size,
    max_header_list_size: u32 = std.math.maxInt(u32),
    enable_connect_protocol: bool = false,
    /// Unset until the first SETTINGS; may not change after (RFC 9218 §2.1).
    no_rfc7540_priorities: ?bool = null,
};

fn checkHandler(comptime H: type) void {
    const want = .{
        .{ "onStreamOpen", fn (*H, *Stream) Error!void },
        .{ "onField", fn (*H, *Stream, []const u8, []const u8) Error!void },
        .{ "onHeadersEnd", fn (*H, *Stream, bool) Error!void },
        .{ "onData", fn (*H, *Stream, []const u8, bool) Error!void },
        .{ "onStreamClose", fn (*H, *Stream, ErrorCode) void },
        .{ "onWindow", fn (*H, ?*Stream) void },
        .{ "onGoaway", fn (*H, u31, ErrorCode) void },
        .{ "onPingAck", fn (*H, [8]u8) void },
    };
    inline for (want) |w| {
        if (!@hasDecl(H, w[0])) @compileError("h2 conn: the handler " ++ @typeName(H) ++ " has no " ++ w[0]);
        if (@TypeOf(@field(H, w[0])) != w[1])
            @compileError("h2 conn: " ++ @typeName(H) ++ "." ++ w[0] ++ " must be " ++ @typeName(w[1]));
    }
}

/// The least `hdrs` can encode to with our static-only HPACK encoder: a
/// string no static entry has is a literal, and Huffman codes take at
/// least 5 bits an octet (RFC 7541 Appendix B).
fn minEncoded(hdrs: []const hpack.Field) usize {
    const longest = comptime blk: {
        var name: usize = 0;
        var value: usize = 0;
        for (hpack.static_table) |f| {
            name = @max(name, f.name.len);
            value = @max(value, f.value.len);
        }
        break :blk .{ name, value };
    };
    var n: usize = 0;
    for (hdrs) |f| {
        if (f.name.len > longest[0]) n += f.name.len;
        if (f.value.len > longest[1]) n += f.value.len;
    }
    return n * 5 / 8;
}

/// One queued submitData call: the caller's parts, by reference, framed
/// lazily by `pending`.
const Pending = struct {
    node: std.DoublyLinkedList.Node = .{},
    parts: []const []const u8,
    part: usize = 0,
    off: usize = 0,
    /// Bytes not yet framed.
    left: u64,
    end_stream: bool,
    /// Sent with END_STREAM after the parts (submitTrailers), by reference.
    trailers: ?[]const hpack.Field = null,
};

pub fn Conn(comptime role: Role, comptime H: type) type {
    comptime {
        if (role != .server) @compileError("h2 conn: the client role comes with M5");
        checkHandler(H);
    }
    return struct {
        const Self = @This();

        gpa: Allocator,
        handler: *H,
        opts: Options,
        out: Out,
        decoder: hpack.Decoder,
        encoder: hpack.Encoder = .{},
        slab: streams.Slab,
        table: streams.StreamTable,
        closed: streams.ClosedRing = .{},
        opened: streams.OpenedBitmap = .{},
        /// Our settings, as acknowledged; the ones sent are in `opts`.
        local: Local = .{},
        settings_in_flight: bool = true,
        remote: Remote = .{},
        /// The highest stream ID the peer opened (nghttp2's
        /// last_recv_stream_id), and the highest we processed
        /// (last_proc_stream_id, GOAWAY's last-stream-id).
        last_recv: u31 = 0,
        last_proc: u31 = 0,
        /// The connection's windows: the peer's credit for us, and ours for
        /// the peer (consumed bytes not yet announced in `recv_unacked`).
        send_window: i32 = default_window,
        recv_window: i32,
        recv_unacked: u32 = 0,
        /// Client preface bytes still expected.
        magic_left: u8 = client_magic.len,
        /// The next frame must be the client's first SETTINGS.
        first_settings: bool = true,
        /// The DATA frame whose payload is arriving.
        data_in: ?DataIn = null,
        /// The header block being assembled (HEADERS without END_HEADERS).
        block: ?Block = null,
        /// One request's (or trailers') field checks, per block.
        req: fields.Request = .{},
        /// The GOAWAY we sent, and the last stream ID of the peer's.
        goaway_sent: ?ErrorCode = null,
        remote_last: u31 = std.math.maxInt(u31),
        /// A connection error was answered: nothing more is read
        /// (nghttp2's IB_IGN_ALL).
        dead: bool = false,
        /// Nesting of public calls; closes run when the outermost returns.
        depth: u32 = 0,
        closing: std.SinglyLinkedList = .{},
        closing_last: ?*std.SinglyLinkedList.Node = null,
        /// Pending nodes alive (borrowed parts not yet framed).
        pending_nodes: usize = 0,
        /// Spare Pending nodes, at most `max_spare`, so that a warm
        /// connection's responses allocate nothing (PLAN §2.2, K1/K2).
        spare: std.DoublyLinkedList = .{},
        spare_len: u8 = 0,
        /// The caller's time in whole seconds, for the flood budgets.
        now_s: u64 = 0,
        /// PLAN §5.4's flood budgets: rapid and provoked resets (D15 point
        /// 1), streams refused before a handler saw them, empty and unknown
        /// frames (D15 point 2), and nghttp2's glitch limiter (PRIORITY,
        /// header blocks decoded only for the table). One of the last two
        /// goes after the D15 point 5 calibration.
        reset_budget: limits.TokenBucket,
        refused_budget: limits.TokenBucket,
        empty_budget: limits.TokenBucket,
        glitch_budget: limits.TokenBucket,
        /// Control answers queued (PING ACK, SETTINGS ACK, RST_STREAM) and
        /// not yet written, in two epochs, each with `out`'s byte position
        /// just past its last answer: `sealed` was queued before the
        /// writer's last `advance`, `open` since. `advance` past `sealed`'s
        /// mark releases it and seals `open`, so the count follows the
        /// writer to within one epoch under a standing backlog.
        control_sealed: ControlEpoch = .{},
        control_open: ControlEpoch = .{},

        const max_spare = 32;

        const ControlEpoch = struct {
            n: u32 = 0,
            mark: u64 = 0,
        };

        const DataIn = struct {
            stream_id: u31,
            /// Payload bytes still to come, padding included.
            left: u32,
            /// The trailing padding; null until the Pad Length byte is in.
            pad: ?u8,
            end_stream: bool,
            /// Delivered to the handler, else only accounted.
            deliver: bool,
        };

        const Kind = enum { request, trailers, ignore };

        const Block = struct {
            stream_id: u31,
            kind: Kind,
            end_stream: bool,
            buf: std.ArrayList(u8) = .empty,
            continuations: u32 = 0,
        };

        /// Queues our SETTINGS and the connection window's WINDOW_UPDATE
        /// (the server preface, as today's engine sends it, plus D15's
        /// SETTINGS_NO_RFC7540_PRIORITIES).
        pub fn init(gpa: Allocator, handler: *H, opts: Options) Allocator.Error!Self {
            const cw: u31 = @max(default_window, opts.connection_window);
            var c: Self = .{
                .gpa = gpa,
                .handler = handler,
                .opts = opts,
                .out = .init(gpa),
                .decoder = .init(.{}),
                .slab = .init(gpa),
                .table = .init(gpa, opts.max_concurrent_streams, opts.seed),
                .recv_window = cw,
                .reset_budget = .init(opts.stream_reset_burst, opts.stream_reset_rate),
                .refused_budget = .init(opts.refused_stream_burst, opts.refused_stream_rate),
                .empty_budget = .init(opts.limits.empty_frame_rate, opts.limits.empty_frame_rate),
                .glitch_budget = .init(opts.limits.glitch_burst, opts.limits.glitch_rate),
            };
            errdefer c.out.deinit();
            var entries: [6]frame.Setting = undefined;
            var n: usize = 0;
            for ([_]frame.Setting{
                .{ .id = .max_concurrent_streams, .value = opts.max_concurrent_streams },
                .{ .id = .initial_window_size, .value = opts.initial_window },
                .{ .id = .max_header_list_size, .value = opts.max_header_list_size },
            }) |e| {
                entries[n] = e;
                n += 1;
            }
            if (opts.max_frame_size > frame.min_max_frame_size) {
                entries[n] = .{ .id = .max_frame_size, .value = opts.max_frame_size };
                n += 1;
            }
            if (opts.enable_connect_protocol) {
                entries[n] = .{ .id = .enable_connect_protocol, .value = 1 };
                n += 1;
            }
            entries[n] = .{ .id = .no_rfc7540_priorities, .value = 1 };
            n += 1;
            const b = try c.out.writable(frame.header_len + n * frame.setting_len);
            c.out.commit(frame.writeSettings(b, false, entries[0..n]));
            if (cw > default_window) try c.queueWindowUpdate(0, cw - default_window);
            return c;
        }

        /// Frees everything. No onStreamClose for the streams still open:
        /// the caller (M3's engine) ends its own side of them.
        pub fn deinit(c: *Self) void {
            std.debug.assert(c.depth == 0 and c.closing.first == null);
            var i: usize = 0;
            while (c.table.next(&i)) |s| c.dropPending(s);
            if (c.block) |*b| b.buf.deinit(c.gpa);
            while (c.spare.popFirst()) |node| c.gpa.destroy(@as(*Pending, @fieldParentPtr("node", node)));
            c.table.deinit();
            c.slab.deinit();
            c.out.deinit();
        }

        fn enter(c: *Self) void {
            c.depth += 1;
        }

        /// At the outermost call's end: the deferred closes, oldest first.
        /// One may queue more (the handler submits from onStreamClose).
        fn leave(c: *Self) void {
            if (c.depth == 1) {
                while (c.closing.popFirst()) |node| {
                    if (c.closing.first == null) c.closing_last = null;
                    const s: *Stream = @fieldParentPtr("link", node);
                    c.handler.onStreamClose(s, s.code);
                    c.slab.destroy(s);
                }
            }
            c.depth -= 1;
        }

        // ---------------------------------------------------------------
        // Inbound

        /// Consumes the client preface, whole frames and DATA payloads as
        /// they arrive, from the front of `bytes`; returns how many bytes
        /// were taken (the caller keeps the rest and calls again with more).
        /// `now_s` is a monotonic time in whole seconds; `scratch` is the
        /// HPACK scratch, at least max(max_header_list_size,
        /// hpack.table_capacity) bytes, used only during the call (one per
        /// executor will do: recv never yields).
        pub fn recv(c: *Self, bytes: []const u8, now_s: u64, scratch: []u8) RecvError!usize {
            std.debug.assert(scratch.len >= @max(c.opts.max_header_list_size, hpack.table_capacity));
            if (c.dead) return error.ConnectionError;
            c.enter();
            defer c.leave();
            c.now_s = now_s;
            var pos: usize = 0;
            c.recvFrames(bytes, &pos, scratch) catch |err| {
                c.dead = true;
                return err;
            };
            return pos;
        }

        fn recvFrames(c: *Self, bytes: []const u8, pos: *usize, scratch: []u8) RecvError!void {
            // NGHTTP2_IB_READ_CLIENT_MAGIC.
            while (c.magic_left > 0) {
                const rest = bytes[pos.*..];
                if (rest.len == 0) return;
                const n = @min(rest.len, c.magic_left);
                const at = client_magic.len - c.magic_left;
                if (!std.mem.eql(u8, rest[0..n], client_magic[at..][0..n])) return error.BadPreface;
                pos.* += n;
                c.magic_left -= @intCast(n);
            }
            while (true) {
                const opts: frame.Options = .{ .max_frame_size = c.local.max_frame_size, .max_settings = c.opts.limits.max_settings };
                if (c.data_in != null) {
                    try c.dataPayload(bytes, pos);
                    if (c.data_in != null) return;
                    continue;
                }
                const rest = bytes[pos.*..];
                if (rest.len < frame.header_len) return;
                const raw = frame.FrameHeader.parse(rest[0..frame.header_len]);
                // NGHTTP2_IB_EXPECT_CONTINUATION, before the frame's own
                // checks.
                if (c.block) |b| if (raw.type != .continuation or raw.stream_id != b.stream_id)
                    return c.terminate(.protocol_error, "unexpected non-CONTINUATION frame or stream_id is invalid");
                // NGHTTP2_IB_READ_FIRST_SETTINGS.
                if (c.first_settings and (raw.type != .settings or raw.flags & frame.flags.ack != 0))
                    return c.terminate(.protocol_error, "SETTINGS expected");
                if (raw.type == .data) {
                    const h = switch (frame.parseHead(rest, opts)) {
                        .head => |h| h,
                        .fault => |f| return c.terminate(f.code, f.reason),
                        .need => unreachable,
                    };
                    pos.* += frame.header_len;
                    try c.dataHead(h);
                    continue;
                }
                switch (frame.parse(rest, opts)) {
                    .need => return,
                    .fault => |f| return c.terminate(f.code, f.reason),
                    .frame => |f| {
                        pos.* += f.len;
                        try c.dispatch(f.parsed, scratch);
                    },
                }
            }
        }

        fn dispatch(c: *Self, p: frame.Parsed, scratch: []u8) RecvError!void {
            const id = p.header.stream_id;
            switch (p.frame) {
                .data => unreachable,
                .headers => |hd| try c.onHeaders(id, hd, scratch),
                .continuation => |ct| try c.onContinuation(ct, scratch),
                .priority => |pr| try c.onPriority(id, pr),
                .rst_stream => |code| try c.onRstStream(id, code),
                .settings => |st| try c.onSettings(st),
                // nghttp2_session_on_push_promise_received: a server never
                // takes one.
                .push_promise => return c.terminate(.protocol_error, "PUSH_PROMISE: push disabled"),
                .ping => |pg| try c.onPing(pg),
                .goaway => |g| try c.onGoaway(g),
                .window_update => |inc| try c.onWindowUpdate(id, inc),
                // RFC 9113 §4.1: ignored; D15 point 2 counts it as empty.
                .unknown => try c.chargeEmptyFrame(),
            }
        }

        /// session_detect_idle_stream for a server: the client's IDs above
        /// the highest it opened, and every ID of ours (we open none).
        fn idle(c: *const Self, id: u31) bool {
            return id & 1 == 0 or id > c.last_recv;
        }

        fn peerFate(c: *const Self, id: u31) streams.Fate {
            return streams.peerFate(&c.closed, &c.opened, 1, c.last_recv, id);
        }

        /// nghttp2_session_terminate_session_with_reason: GOAWAY with the
        /// last processed stream, and nothing more is read.
        fn terminate(c: *Self, code: ErrorCode, reason: []const u8) RecvError {
            if (!c.dead) {
                c.dead = true;
                c.goaway_sent = code;
                c.queueGoaway(code, reason) catch return error.OutOfMemory;
            }
            return error.ConnectionError;
        }

        // DATA ----------------------------------------------------------

        /// session_on_data_received_fail_fast, at the frame header.
        fn dataHead(c: *Self, h: frame.FrameHeader) RecvError!void {
            const id = h.stream_id;
            var deliver = false;
            if (c.idle(id)) return c.terminate(.protocol_error, "DATA: stream in idle");
            if (c.table.get(id)) |s| {
                if (s.state == .half_closed_remote) return c.terminate(.stream_closed, "DATA: stream in half-closed(remote)");
                deliver = true;
            } else switch (c.peerFate(id)) {
                // The fork patch: answer what is known to be the peer's
                // mistake (PLAN §5.2 behaviours 1, 2).
                .rst_received => try c.provokedRst(id, .stream_closed),
                .end_stream, .never_opened => return c.terminate(.stream_closed, "DATA: stream closed"),
                // Reset by us, or forgotten: ignored (behaviours 4, 5).
                .rst_sent, .unknown => {},
            }
            const end_stream = h.flags & frame.flags.end_stream != 0;
            const padded = h.flags & frame.flags.padded != 0;
            // Ignored DATA is skipped whole, its padding unread: nghttp2
            // goes to NGHTTP2_IB_IGN_DATA before inbound_frame_handle_pad
            // (found by the session differential).
            c.data_in = .{ .stream_id = id, .left = h.length, .pad = if (padded and deliver) null else 0, .end_stream = end_stream, .deliver = deliver };
            try c.recvWindows(&c.data_in.?, h.length);
            if (h.length == 0) {
                if (!end_stream) try c.chargeEmptyFrame();
                var none: usize = 0;
                try c.dataPayload("", &none);
            }
        }

        /// NGHTTP2_IB_READ_PAD_DATA, NGHTTP2_IB_READ_DATA and
        /// NGHTTP2_IB_IGN_DATA: as much of the payload as `bytes` holds.
        fn dataPayload(c: *Self, bytes: []const u8, pos: *usize) RecvError!void {
            const d = &c.data_in.?;
            if (d.pad == null) {
                if (pos.* == bytes.len) return;
                const pad = bytes[pos.*];
                pos.* += 1;
                d.left -= 1;
                // The Pad Length byte is consumed at once.
                try c.consumeNow(if (d.deliver) c.table.get(d.stream_id) else null, 1);
                if (pad > d.left) return c.terminate(.protocol_error, "DATA: invalid padding");
                d.pad = pad;
                if (d.left == 0 and !d.end_stream) try c.chargeEmptyFrame();
            }
            const n: u32 = @intCast(@min(bytes.len - pos.*, d.left));
            if (n == 0 and d.left > 0) return;
            const chunk = bytes[pos.*..][0..n];
            pos.* += n;
            // The data still to come: none once only padding is left.
            const data_left = d.left -| d.pad.?;
            const dn = @min(n, data_left);
            d.left -= n;
            const last = d.left == 0;
            const s = (if (d.deliver) c.table.get(d.stream_id) else null) orelse {
                d.deliver = false;
                // Ignored DATA is consumed at once (nghttp2's IB_IGN_DATA).
                try c.consumeNow(null, n);
                if (last) c.data_in = null;
                return;
            };
            // Padding is consumed at once.
            if (n > dn) try c.consumeNow(s, n - dn);
            if (dn > 0) {
                // nghttp2_http_on_data_chunk: past the content-length the
                // connection credit is given back and the stream reset.
                s.onDataChunk(dn) catch {
                    try c.consumeNow(null, dn);
                    d.deliver = false;
                    try c.provokedReset(s, .protocol_error);
                    if (last) c.data_in = null;
                    return;
                };
            }
            const end = last and d.end_stream;
            if (last) c.data_in = null;
            if (dn == 0 and !end) return;
            if (end) {
                // nghttp2_session_on_data_received: the content-length must
                // add up at END_STREAM. The half closes before the callback,
                // so the handler's `consumed` earns the stream no
                // WINDOW_UPDATE.
                // The chunk isn't delivered: its connection credit goes
                // back, as past the content-length above.
                s.onRemoteEnd() catch {
                    try c.consumeNow(null, dn);
                    return c.provokedReset(s, .protocol_error);
                };
                c.endRemote(s);
            }
            c.handler.onData(s, chunk[0..dn], end) catch return c.handlerReset(s);
        }

        /// nghttp2_session_update_recv_{connection,stream}_window_size: DATA
        /// past a window is a connection FLOW_CONTROL_ERROR. Charged for the
        /// whole frame at its header (RFC 9113 §6.9.1: the frame's length is
        /// what must fit), where nghttp2 charges each chunk as it is read, so
        /// that credit the handler gives back while a frame is still
        /// arriving can't make room for it: the answer doesn't depend on how
        /// the reads cut the frame (INTENTIONAL.md, session 5).
        fn recvWindows(c: *Self, d: *DataIn, n: u32) RecvError!void {
            if (n > c.recv_window) return c.terminate(.flow_control_error, "");
            c.recv_window -= @intCast(n);
            if (!d.deliver) return;
            const s = c.table.get(d.stream_id) orelse return;
            if (n > s.recv_window) return c.terminate(.flow_control_error, "");
            s.recv_window -= @intCast(n);
        }

        // HEADERS and CONTINUATION ---------------------------------------

        fn onHeaders(c: *Self, id: u31, hd: frame.Headers, scratch: []u8) RecvError!void {
            if (hd.fragment.len == 0 and !hd.end_stream) try c.chargeEmptyFrame();
            const kind = try c.headersKind(id, hd);
            try c.chargeHeaderBlock(hd.fragment.len);
            if (hd.end_headers) return c.decodeBlock(id, kind, hd.end_stream, hd.fragment, scratch);
            // A block that spans frames is assembled in a buffer taken only
            // while it is open (h2o's _continuation.buf).
            var b: Block = .{ .stream_id = id, .kind = kind, .end_stream = hd.end_stream };
            try b.buf.appendSlice(c.gpa, hd.fragment);
            c.block = b;
        }

        /// session_process_headers_frame: nghttp2_session_on_headers_received
        /// for a stream we have, else nghttp2_session_on_request_headers_received.
        /// The stream opens here, before its block is decoded, as nghttp2's
        /// on_begin_headers runs.
        fn headersKind(c: *Self, id: u31, hd: frame.Headers) RecvError!Kind {
            if (c.table.get(id)) |s| {
                if (s.state == .half_closed_remote) return c.terminate(.stream_closed, "HEADERS: stream closed");
                s.flags.in_trailers = true;
                return .trailers;
            }
            if (id & 1 == 0) return c.terminate(.protocol_error, "request HEADERS: invalid stream_id");
            if (id <= c.last_recv) {
                switch (c.peerFate(id)) {
                    .never_opened => return c.terminate(.protocol_error, "request HEADERS: stream_id smaller than a previous one"),
                    .rst_received => try c.provokedRst(id, .stream_closed),
                    .end_stream => return c.terminate(.stream_closed, "HEADERS: stream closed after END_STREAM"),
                    .rst_sent, .unknown => {},
                }
                try c.chargeGlitch();
                return .ignore;
            }
            c.opened.markOpened(c.last_recv, id);
            c.last_recv = id;
            if (try c.admitStream(id, hd)) |kind| return kind;
            const s = try c.slab.create(id, c.remote.initial_window, c.local.initial_window);
            c.table.insert(s) catch |err| {
                c.slab.destroy(s);
                return err;
            };
            s.state = .open;
            c.last_proc = id;
            c.handler.onStreamOpen(s) catch {
                try c.handlerReset(s);
                return .ignore;
            };
            return if (s.state == .closed) .ignore else .request;
        }

        /// A new stream's admission; null opens it. Past
        /// max_concurrent_streams, or while the peer isn't reading what we
        /// queued, the stream is refused (PLAN §5.4), and its block is still
        /// decoded for the table. nghttp2 makes a stream past the
        /// acknowledged maximum a connection PROTOCOL_ERROR
        /// (nghttp2_session_on_request_headers_received :3998) and refuses
        /// only past one not yet acknowledged (:4014); INTENTIONAL.md,
        /// limits 7 and 8.
        fn admitStream(c: *Self, id: u31, hd: frame.Headers) RecvError!?Kind {
            // After our GOAWAY: ignored, and its block decoded only for the
            // table (nghttp2 :5811).
            if (c.goaway_sent != null) {
                try c.chargeGlitch();
                return .ignore;
            }
            if (hd.priority) |p| if (p.dependency == id)
                return c.terminate(.protocol_error, "request HEADERS: depend on itself");
            // The slow reader (CVE-2019-9517): above out_high owned bytes
            // unwritten, new streams are refused while everything else is
            // still processed (credit and ACKs can only shrink the queue;
            // DATA on open streams goes on). Borrowed DATA isn't counted: it
            // is framed only at `pending`, a writev's worth at a time, so its
            // size follows the peer's frame size and the writer's iovecs,
            // not a stalled reader. The other half, closing a connection
            // whose flushes stall, is M3's sweeper (`timeouts.write`, PLAN
            // §3.3).
            if (c.table.size >= c.opts.max_concurrent_streams or c.out.ownedUnsent() > c.opts.limits.out_high) {
                try c.refuse(id);
                return .ignore;
            }
            return null;
        }

        fn onContinuation(c: *Self, ct: frame.Continuation, scratch: []u8) RecvError!void {
            const b = if (c.block) |*b| b else return c.terminate(.protocol_error, "CONTINUATION: unexpected");
            // nghttp2_session_mem_recv2 :6831 (CVE-2024-28182), with a
            // GOAWAY where nghttp2 returns a fatal error (INTENTIONAL.md,
            // limits 4).
            b.continuations += 1;
            if (b.continuations > c.opts.max_continuations)
                return c.terminate(.enhance_your_calm, "too many CONTINUATION frames");
            if (ct.fragment.len == 0 and !ct.end_headers) try c.chargeEmptyFrame();
            try c.chargeHeaderBlock(b.buf.items.len + ct.fragment.len);
            try b.buf.appendSlice(c.gpa, ct.fragment);
            if (!ct.end_headers) return;
            var done = b.*;
            c.block = null;
            defer done.buf.deinit(c.gpa);
            try c.decodeBlock(done.stream_id, done.kind, done.end_stream, done.buf.items, scratch);
        }

        /// inflate_header_block and session_after_header_block_received over
        /// one complete block. An ignored block is still decoded, for the
        /// HPACK table (nghttp2's IB_IGN_HEADER_BLOCK).
        fn decodeBlock(c: *Self, id: u31, kind: Kind, end_stream: bool, input: []const u8, scratch: []u8) RecvError!void {
            var blk = c.decoder.block(input, scratch, c.opts.max_header_list_size);
            const s = (if (kind == .ignore) null else c.table.get(id)) orelse return c.skipBlock(null, &blk);
            if (s.state == .closed) return c.skipBlock(null, &blk);
            const trailers = kind == .trailers;
            c.req = .{};
            const fo: fields.Opts = .{ .connect_protocol = c.opts.enable_connect_protocol, .stream_id = id };
            // Regular fields, the cookie's crumbs once (RFC 9113 §8.2.3: a
            // browser sends one crumb a cookie, joined again for the handler).
            var count: usize = 0;
            var cookie = false;
            while (true) {
                const f = (blk.next() catch |err| switch (err) {
                    error.HeaderListTooLarge => return c.refuseHead(s, &blk, trailers, end_stream),
                    else => return c.blockError(s, err),
                }) orelse break;
                const v = if (trailers) c.req.trailer(f.name, f.value, fo) else c.req.field(f.name, f.value, fo);
                switch (v) {
                    .ok => {},
                    .ignore => continue,
                    .malformed => {
                        try c.provokedReset(s, .protocol_error);
                        return c.skipBlock(s, &blk);
                    },
                }
                if (f.name[0] != ':') {
                    const crumb = std.mem.eql(u8, f.name, "cookie");
                    if (!crumb or !cookie) count += 1;
                    cookie = cookie or crumb;
                    if (count > c.opts.max_header_count) return c.refuseHead(s, &blk, trailers, end_stream);
                }
                c.handler.onField(s, f.name, f.value) catch {
                    try c.handlerReset(s);
                    return c.skipBlock(s, &blk);
                };
                if (s.state == .closed) return c.skipBlock(s, &blk);
            }
            // nghttp2_http_on_request_headers / on_trailer_headers (trailers
            // must end the stream) / on_remote_end_stream.
            const valid = if (trailers) end_stream else c.req.end();
            if (!valid) return c.provokedReset(s, .protocol_error);
            if (!trailers) {
                s.content_left = if (c.req.content_length) |n| @intCast(n) else -1;
                s.flags.headers_received = true;
            }
            if (end_stream) {
                s.onRemoteEnd() catch return c.provokedReset(s, .protocol_error);
                c.endRemote(s);
            }
            c.handler.onHeadersEnd(s, end_stream) catch return c.handlerReset(s);
            s.flags.in_trailers = false;
        }

        fn skipBlock(c: *Self, s: ?*Stream, blk: *hpack.Block) RecvError!void {
            blk.skipRest() catch |err| return c.blockError(s, err);
        }

        fn blockError(c: *Self, s: ?*Stream, err: hpack.Error) RecvError!void {
            switch (err) {
                // Only `next` gives it (decodeBlock's refuseHead).
                error.HeaderListTooLarge => unreachable,
                // inflate_header_block: RST_STREAM, then GOAWAY.
                error.CompressionError => {
                    if (s) |x| if (x.state != .closed) try c.resetStream(x, .compression_error);
                    return c.terminate(.compression_error, "");
                },
                error.HeaderBlockTooCostly => return c.terminate(.enhance_your_calm, "header block too costly"),
            }
        }

        /// A head past max_header_list_size (the HPACK bomb) or
        /// max_header_count (PLAN §5.4): the rest of the block is decoded for
        /// the table only (RFC 9113 §4.3), and the request answered 431 with
        /// END_STREAM, then RST_STREAM(NO_ERROR) if the peer's half is still
        /// open (RFC 9113 §8.1), as Go's handleHeaderListTooLong answers 431.
        /// No handler saw a whole head: the refused budget. Trailers past a
        /// limit reset the stream instead (the handler has the head).
        /// Today's engine resets with INTERNAL_ERROR (INTENTIONAL.md,
        /// limits 6).
        fn refuseHead(c: *Self, s: *Stream, blk: *hpack.Block, trailers: bool, end_stream: bool) RecvError!void {
            try c.skipBlock(s, blk);
            if (s.state == .closed) return;
            if (trailers or s.flags.head_sent) return c.provokedReset(s, .internal_error);
            try c.chargeRefused();
            c.writeHeaders(s.id, 431, &.{}, true) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.HeadersTooLarge, error.StreamClosed => unreachable,
            };
            s.flags.head_sent = true;
            s.flags.answered = true;
            c.endLocal(s);
            if (end_stream) return c.endRemote(s);
            try c.chargeControl(frame.header_len + 4);
            try c.resetStream(s, .no_error);
        }

        // The other frames --------------------------------------------------

        /// The fork patch's PRIORITY handling (RFC 9113 §6.3): validated,
        /// otherwise ignored. Stream 0 is frame.zig's check.
        /// No tree (D15 point 3, SETTINGS_NO_RFC7540_PRIORITIES): nothing
        /// changes but nghttp2's glitch budget (:5843; CVE-2019-9513 has
        /// nothing to loop over).
        fn onPriority(c: *Self, id: u31, p: frame.Priority) RecvError!void {
            try c.chargeGlitch();
            if (p.dependency != id) return;
            // A stream error, except that RST_STREAM must not be sent on an
            // idle stream, which leaves a connection error.
            if (c.idle(id)) return c.terminate(.protocol_error, "PRIORITY: stream depends on itself");
            try c.provokedRst(id, .protocol_error);
        }

        /// nghttp2_session_on_rst_stream_received.
        fn onRstStream(c: *Self, id: u31, code: ErrorCode) RecvError!void {
            if (c.idle(id)) return c.terminate(.protocol_error, "RST_STREAM: stream in idle");
            const s = c.table.get(id) orelse return;
            const answered = s.flags.answered;
            c.closeStream(s, code, .rst_received);
            // session_update_stream_reset_ratelim (:4186) charges every
            // RST_STREAM; D15 point 1 only those on streams we hadn't
            // answered (a browser's navigation or a gRPC cancel after the
            // response is ordinary traffic). INTENTIONAL.md, limits 1.
            if (!answered) try c.chargeReset();
        }

        /// nghttp2_session_on_settings_received.
        fn onSettings(c: *Self, st: frame.Settings) RecvError!void {
            if (st.ack) {
                if (!c.settings_in_flight) return c.terminate(.protocol_error, "SETTINGS: unexpected ACK");
                c.settings_in_flight = false;
                return c.applyLocalSettings();
            }
            c.first_settings = false;
            // nghttp2's early flood check (:5897): with the budget spent,
            // the entries aren't applied.
            try c.chargeControl(frame.header_len);
            var grew = false;
            var it = st.iterator();
            while (it.next()) |e| switch (e.id) {
                // The encoder is static-only (INTENTIONAL.md, HPACK 4).
                .header_table_size, .enable_push => {},
                .max_concurrent_streams => c.remote.max_concurrent_streams = e.value,
                .initial_window_size => {
                    const new: u31 = @intCast(e.value);
                    if (new > c.remote.initial_window) grew = true;
                    try c.remoteInitialWindow(new);
                },
                .max_frame_size => c.remote.max_frame_size = @intCast(e.value),
                .max_header_list_size => c.remote.max_header_list_size = e.value,
                .enable_connect_protocol => c.remote.enable_connect_protocol = e.value == 1,
                .no_rfc7540_priorities => {
                    const v = e.value == 1;
                    if (c.remote.no_rfc7540_priorities) |old| if (old != v)
                        return c.terminate(.protocol_error, "SETTINGS: SETTINGS_NO_RFC7540_PRIORITIES cannot be changed");
                    c.remote.no_rfc7540_priorities = v;
                },
                _ => {},
            };
            if (c.remote.no_rfc7540_priorities == null) c.remote.no_rfc7540_priorities = false;
            const b = try c.out.writable(frame.header_len);
            c.out.commit(frame.writeSettings(b, true, &.{}));
            if (grew) c.handler.onWindow(null);
        }

        /// session_update_remote_initial_window_size: every stream's send
        /// window moves by the change (RFC 9113 §6.9.2).
        fn remoteInitialWindow(c: *Self, new: u31) RecvError!void {
            var i: usize = 0;
            while (c.table.next(&i)) |s| {
                streams.updateInitialWindow(&s.send_window, new, c.remote.initial_window) catch
                    return c.terminate(.flow_control_error, "");
                if (s.send_window > 0 and s.pending.first != null) try c.makeReady(s);
            }
            c.remote.initial_window = new;
        }

        /// nghttp2_session_update_local_settings at the ACK of our SETTINGS:
        /// every stream's receive window moves by the change, and may now be
        /// due a WINDOW_UPDATE.
        fn applyLocalSettings(c: *Self) RecvError!void {
            const old = c.local.initial_window;
            c.local = .{
                .max_concurrent_streams = c.opts.max_concurrent_streams,
                .initial_window = c.opts.initial_window,
                .max_frame_size = c.opts.max_frame_size,
            };
            var i: usize = 0;
            while (c.table.next(&i)) |s| {
                streams.updateInitialWindow(&s.recv_window, c.local.initial_window, old) catch
                    return c.terminate(.flow_control_error, "");
                try c.creditStream(s);
            }
        }

        fn onPing(c: *Self, p: frame.Ping) RecvError!void {
            if (p.ack) return c.handler.onPingAck(p.data);
            try c.chargeControl(frame.header_len + 8);
            const b = try c.out.writable(frame.header_len + 8);
            c.out.commit(frame.writePing(b, true, p.data));
        }

        /// nghttp2_session_on_goaway_received. A server opens no streams,
        /// so none close.
        fn onGoaway(c: *Self, g: frame.Goaway) RecvError!void {
            if ((g.last_stream_id > 0 and g.last_stream_id & 1 == 1) or g.last_stream_id > c.remote_last)
                return c.terminate(.protocol_error, "GOAWAY: invalid last_stream_id");
            c.remote_last = g.last_stream_id;
            c.handler.onGoaway(g.last_stream_id, g.code);
        }

        /// nghttp2_session_on_window_update_received.
        fn onWindowUpdate(c: *Self, id: u31, inc: u31) RecvError!void {
            if (id == 0) {
                // An increment of 0 is frame.zig's check.
                if (@as(i64, c.send_window) + inc > frame.max_window_size) return c.terminate(.flow_control_error, "");
                c.send_window += inc;
                c.handler.onWindow(null);
                return;
            }
            if (c.idle(id)) return c.terminate(.protocol_error, "WINDOW_UPDATE to idle stream");
            const s = c.table.get(id) orelse return;
            if (inc == 0) return c.terminate(.protocol_error, "WINDOW_UPDATE: window_size_increment == 0");
            // The fork patch: a stream window overflow ends the stream, not
            // the connection (RFC 9113 §6.9.1; PLAN §5.2 behaviour 8).
            if (@as(i64, s.send_window) + inc > frame.max_window_size) return c.provokedReset(s, .flow_control_error);
            s.send_window += inc;
            if (s.send_window > 0 and s.pending.first != null) try c.makeReady(s);
            c.handler.onWindow(s);
        }

        // ---------------------------------------------------------------
        // Stream ends

        /// The peer's END_STREAM.
        fn endRemote(c: *Self, s: *Stream) void {
            s.recvEnd();
            if (s.state == .closed) c.closeStream(s, .no_error, .end_stream);
        }

        /// Our END_STREAM was queued.
        fn endLocal(c: *Self, s: *Stream) void {
            s.sendEnd();
            if (s.state == .closed) c.closeStream(s, .no_error, .end_stream);
        }

        /// nghttp2_session_close_stream: out of the table and into the
        /// closed-stream memory now; onStreamClose and the slab at the end
        /// of the outermost call.
        fn closeStream(c: *Self, s: *Stream, code: ErrorCode, fate: streams.Fate) void {
            std.debug.assert(c.depth > 0);
            const removed = c.table.remove(s.id);
            std.debug.assert(removed);
            c.closed.record(1, s.id, fate);
            c.dropPending(s);
            s.state = .closed;
            s.code = code;
            s.link = .{};
            if (c.closing_last) |l| l.insertAfter(&s.link) else c.closing.prepend(&s.link);
            c.closing_last = &s.link;
        }

        fn dropPending(c: *Self, s: *Stream) void {
            while (s.pending.popFirst()) |node| c.freePending(@fieldParentPtr("node", node));
        }

        fn newPending(c: *Self) Allocator.Error!*Pending {
            const p: *Pending = if (c.spare.popFirst()) |node| blk: {
                c.spare_len -= 1;
                break :blk @fieldParentPtr("node", node);
            } else try c.gpa.create(Pending);
            c.pending_nodes += 1;
            return p;
        }

        /// `p` is off its stream's list.
        fn freePending(c: *Self, p: *Pending) void {
            c.pending_nodes -= 1;
            if (c.spare_len == max_spare) return c.gpa.destroy(p);
            p.node = .{};
            c.spare.prepend(&p.node);
            c.spare_len += 1;
        }

        /// RST_STREAM now; the stream is closed at once (no CLOSING state),
        /// and remembered as reset by us, so the peer's frames still in
        /// flight are ignored (PLAN §5.2 behaviour 4).
        fn resetStream(c: *Self, s: *Stream, code: ErrorCode) Allocator.Error!void {
            try c.queueRst(s.id, code);
            c.closeStream(s, code, .rst_sent);
        }

        /// A reset the peer's frames caused: STREAM_CLOSED answers, overflows,
        /// a broken content-length or head (MadeYouReset, CVE-2025-8671,
        /// whose advice is to count what the server sends). Charged to the
        /// reset budget whether answered or not (D15 point 1); nghttp2
        /// charges these to its glitch budget (:3747, :3884, :5130).
        fn provokedReset(c: *Self, s: *Stream, code: ErrorCode) RecvError!void {
            try c.chargeReset();
            try c.chargeControl(frame.header_len + 4);
            try c.resetStream(s, code);
        }

        /// session_handle_invalid_stream on an ID: the stream if we have
        /// it, else just the frame.
        fn provokedRst(c: *Self, id: u31, code: ErrorCode) RecvError!void {
            if (c.table.get(id)) |s| return c.provokedReset(s, code);
            try c.chargeReset();
            try c.chargeControl(frame.header_len + 4);
            try c.queueRst(id, code);
        }

        /// A stream refused before any handler saw it (REFUSED_STREAM): the
        /// refused budget, today's engine's `refusedHead` rule.
        fn refuse(c: *Self, id: u31) RecvError!void {
            try c.chargeRefused();
            try c.chargeControl(frame.header_len + 4);
            try c.queueRst(id, .refused_stream);
        }

        /// A handler callback failed: not the peer's doing, so only the
        /// control budget.
        fn handlerReset(c: *Self, s: *Stream) RecvError!void {
            if (s.state == .closed) return;
            try c.chargeControl(frame.header_len + 4);
            try c.resetStream(s, .internal_error);
        }

        // ---------------------------------------------------------------
        // PLAN §5.4's flood budgets (D15). Each ends the connection with
        // GOAWAY ENHANCE_YOUR_CALM once spent; nothing is allocated.

        /// nghttp2's ratelim pattern (session_update_glitch_ratelim :3497):
        /// refill for the time passed, take one.
        fn charge(c: *Self, b: *limits.TokenBucket, reason: []const u8) RecvError!void {
            b.update(c.now_s);
            if (!b.drain(1)) return c.terminate(.enhance_your_calm, reason);
        }

        /// Rapid reset (CVE-2023-44487) and provoked resets. nghttp2 answers
        /// a graceful GOAWAY INTERNAL_ERROR (:4196); PLAN §5.4 and
        /// INTENTIONAL.md, limits 2: ENHANCE_YOUR_CALM, and close.
        fn chargeReset(c: *Self) RecvError!void {
            return c.charge(&c.reset_budget, "too many stream resets");
        }

        fn chargeRefused(c: *Self) RecvError!void {
            return c.charge(&c.refused_budget, "too many refused streams");
        }

        /// An empty DATA or HEADERS without END_STREAM, an empty
        /// CONTINUATION without END_HEADERS, or any unknown or extension frame
        /// (CVE-2019-9518, D15 point 2). nghttp2 charges both to its glitch
        /// budget (:5721, :6930, :6025); INTENTIONAL.md, limits 3.
        fn chargeEmptyFrame(c: *Self) RecvError!void {
            return c.charge(&c.empty_budget, "too many empty frames");
        }

        /// nghttp2's glitch limiter for what PLAN's empty-frame row doesn't
        /// name: PRIORITY (:5843) and header blocks decoded only for the
        /// table (:5811, :6332).
        fn chargeGlitch(c: *Self) RecvError!void {
            return c.charge(&c.glitch_budget, "too many glitches");
        }

        /// A control answer of `len` bytes is about to be queued
        /// (CVE-2019-9512 PING, 9514 reset, 9515 SETTINGS): nghttp2's
        /// obq_flood_counter_ against max_outbound_ack (nghttp2_session_add_ping
        /// :7343, nghttp2_submit_settings :7493), which counts only the ACKs
        /// and is released as each is packed (:2244); here the RST_STREAMs
        /// recv queues count too, and they are released an epoch at a time
        /// as `advance` passes them (Go's queuedControlFrames, released per
        /// frame in wroteFrame). INTENTIONAL.md, limits 4.
        fn chargeControl(c: *Self, len: usize) RecvError!void {
            if (c.control_sealed.n + c.control_open.n >= c.opts.limits.control_frame_budget)
                return c.terminate(.enhance_your_calm, "too many control frames queued");
            c.control_open.n += 1;
            c.control_open.mark = c.out.mark() + len;
        }

        /// A header block of `len` bytes so far, before decoding: past
        /// max_header_list_size the connection can't keep its HPACK state
        /// without holding the block, so it ends (PLAN §5.4; nghttp2 inflates
        /// as it reads and has no such cap: INTENTIONAL.md, limits 5).
        inline fn chargeHeaderBlock(c: *Self, len: usize) RecvError!void {
            if (len > c.opts.max_header_list_size) return c.terminate(.enhance_your_calm, "header block too large");
        }

        // ---------------------------------------------------------------
        // Outbound

        fn queueRst(c: *Self, id: u31, code: ErrorCode) Allocator.Error!void {
            const b = try c.out.writable(frame.header_len + 4);
            c.out.commit(frame.writeRstStream(b, id, code));
        }

        fn queueGoaway(c: *Self, code: ErrorCode, debug: []const u8) Allocator.Error!void {
            const b = try c.out.writable(frame.header_len + 8 + debug.len);
            c.out.commit(frame.writeGoaway(b, c.last_proc, code, debug));
        }

        fn queueWindowUpdate(c: *Self, id: u31, inc: u31) Allocator.Error!void {
            const b = try c.out.writable(frame.header_len + 4);
            c.out.commit(frame.writeWindowUpdate(b, id, inc));
        }

        /// Credit consumed at once (padding, ignored DATA): the connection,
        /// and the stream when given.
        fn consumeNow(c: *Self, s: ?*Stream, n: u32) Allocator.Error!void {
            c.recv_unacked += n;
            try c.creditConn();
            if (s) |x| if (x.canRecv()) {
                x.recv_unacked += n;
                try c.creditStream(x);
            };
        }

        /// The WINDOW_UPDATE batching: once the consumed bytes reach half
        /// the window (nghttp2_should_send_window_update), or the window is
        /// spent and some were consumed (python-hyper/h2's
        /// WindowManager._maybe_update_window, so a handler consuming in
        /// small steps doesn't stall the peer).
        fn due(window: u31, credit: i32, unacked: u32) bool {
            if (unacked == 0) return false;
            return unacked >= window / 2 or (credit <= 0 and unacked > @min(1024, window / 4));
        }

        fn creditConn(c: *Self) Allocator.Error!void {
            const w = @max(default_window, c.opts.connection_window);
            if (!due(w, c.recv_window, c.recv_unacked)) return;
            try c.queueWindowUpdate(0, @intCast(c.recv_unacked));
            c.recv_window += @intCast(c.recv_unacked);
            c.recv_unacked = 0;
        }

        /// None for a stream whose peer half ended (PLAN §2.2): nothing more
        /// can arrive on it.
        fn creditStream(c: *Self, s: *Stream) Allocator.Error!void {
            if (!s.canRecv() or !due(c.local.initial_window, s.recv_window, s.recv_unacked)) return;
            try c.queueWindowUpdate(s.id, @intCast(s.recv_unacked));
            s.recv_window += @intCast(s.recv_unacked);
            s.recv_unacked = 0;
        }

        fn makeReady(c: *Self, s: *Stream) Allocator.Error!void {
            if (s.flags.ready) return;
            try c.out.pushReady(s.id);
            s.flags.ready = true;
        }

        /// The handler is done with `n` bytes of DATA it was given (on `s`,
        /// or with `s` null on the connection only): flow-control credit,
        /// announced in WINDOW_UPDATEs once enough has gathered.
        pub fn consumed(c: *Self, s: ?*Stream, n: usize) Allocator.Error!void {
            c.enter();
            defer c.leave();
            const k: u32 = @intCast(n);
            c.recv_unacked += k;
            try c.creditConn();
            if (s) |x| if (x.state != .closed and x.canRecv()) {
                x.recv_unacked += k;
                std.debug.assert(@as(i64, x.recv_window) + x.recv_unacked <= frame.max_window_size);
                try c.creditStream(x);
            };
        }

        /// The response head: `:status` then `hdrs`, HEADERS split into
        /// CONTINUATIONs at the peer's SETTINGS_MAX_FRAME_SIZE, encoded now.
        /// With `end_stream` the stream may close (and `s` go) before this
        /// returns, unless called from a callback. An interim (1xx) head may
        /// come any number of times before the final one, never with
        /// `end_stream` (RFC 9113 §8.1; today's engine sends 100 Continue).
        pub fn submitHead(c: *Self, s: *Stream, status: u16, hdrs: []const hpack.Field, end_stream: bool) SubmitError!void {
            c.enter();
            defer c.leave();
            if (!s.canSend() or s.flags.head_sent) return error.StreamClosed;
            const interim = status < 200;
            std.debug.assert(!(interim and end_stream));
            try c.writeHeaders(s.id, status, hdrs, end_stream and !interim);
            if (interim) return;
            s.flags.head_sent = true;
            if (end_stream) {
                s.flags.answered = true;
                c.endLocal(s);
            }
        }

        /// Body bytes, by reference: `parts` (the slice and every part)
        /// must stay valid until `out` no longer borrows them (`borrowing()`
        /// false, or `out.sent_total` past a `mark()` taken once the
        /// stream's queue is empty). Framed by `pending` as the windows
        /// allow.
        pub fn submitData(c: *Self, s: *Stream, parts: []const []const u8, end_stream: bool) SubmitError!void {
            c.enter();
            defer c.leave();
            if (!s.canSend() or !s.flags.head_sent or s.flags.answered) return error.StreamClosed;
            var total: u64 = 0;
            for (parts) |p| total += p.len;
            const p = try c.newPending();
            p.* = .{ .parts = parts, .left = total, .end_stream = end_stream };
            s.pending.append(&p.node);
            if (total == 0 or s.send_window > 0) c.makeReady(s) catch |err| {
                s.pending.remove(&p.node);
                c.freePending(p);
                return err;
            };
            if (end_stream) s.flags.answered = true;
        }

        /// Trailers, by reference, sent with END_STREAM once the queued
        /// DATA has gone (now, if none is queued).
        pub fn submitTrailers(c: *Self, s: *Stream, hdrs: []const hpack.Field) SubmitError!void {
            c.enter();
            defer c.leave();
            if (!s.canSend() or !s.flags.head_sent or s.flags.answered) return error.StreamClosed;
            if (minEncoded(hdrs) > max_headers_len) return error.HeadersTooLarge;
            if (s.pending.last) |node| {
                const p: *Pending = @fieldParentPtr("node", node);
                p.trailers = hdrs;
            } else {
                try c.writeHeaders(s.id, null, hdrs, true);
                c.endLocal(s);
            }
            s.flags.answered = true;
        }

        /// RST_STREAM(code); the stream closes (onStreamClose at the end of
        /// the outermost call). A closed stream is left alone.
        pub fn reset(c: *Self, s: *Stream, code: ErrorCode) Allocator.Error!void {
            c.enter();
            defer c.leave();
            if (s.state == .closed) return;
            try c.resetStream(s, code);
        }

        /// GOAWAY with the last stream processed; new streams are then
        /// ignored. The connection still reads.
        pub fn goaway(c: *Self, code: ErrorCode, debug: []const u8) Allocator.Error!void {
            c.enter();
            defer c.leave();
            try c.queueGoaway(code, debug);
            c.goaway_sent = code;
        }

        /// The first GOAWAY of a graceful drain (RFC 9113 §6.8;
        /// nghttp2_submit_shutdown_notice, which today's engine sends):
        /// last-stream-id 2^31-1 and NO_ERROR, and new streams are still
        /// admitted, so requests already in flight aren't lost. The final
        /// `goaway` follows at least one round trip later.
        pub fn shutdownNotice(c: *Self) Allocator.Error!void {
            const b = try c.out.writable(frame.header_len + 8);
            c.out.commit(frame.writeGoaway(b, std.math.maxInt(u31), .no_error, ""));
        }

        pub fn ping(c: *Self, data: [8]u8) Allocator.Error!void {
            const b = try c.out.writable(frame.header_len + 8);
            c.out.commit(frame.writePing(b, false, data));
        }

        /// What to write now: queued frames, plus DATA framed from the
        /// ready streams round-robin, a frame each per pass, cut to the
        /// windows and the peer's SETTINGS_MAX_FRAME_SIZE, until about
        /// `vecs.len` segments are queued. Write them, then `advance`; the
        /// slices stay valid until then, whatever else is queued meanwhile.
        /// OutOfMemory leaves whole frames queued, but the connection
        /// should still be closed.
        pub fn pending(c: *Self, vecs: [][]const u8) Allocator.Error![]const []const u8 {
            c.enter();
            defer c.leave();
            if (!c.dead) try c.frameData(vecs.len);
            return c.out.iovecs(vecs);
        }

        /// `n` bytes of what `pending` returned were written. The control
        /// answers written give their budget back (`chargeControl`): past
        /// the sealed epoch's last one, it goes, and the open one is sealed
        /// (or goes too, if also written).
        pub fn advance(c: *Self, n: usize) void {
            c.out.advance(n);
            const sent = c.out.sent_total;
            if (sent >= c.control_sealed.mark) {
                c.control_sealed = if (sent >= c.control_open.mark) .{} else c.control_open;
                c.control_open = .{};
            }
        }

        /// Borrowed DATA parts or trailers are still referenced, framed or
        /// not (M3's batch arena waits for false).
        pub fn borrowing(c: *const Self) bool {
            return c.pending_nodes != 0 or c.out.borrowing();
        }

        fn frameData(c: *Self, max_segs: usize) Allocator.Error!void {
            while (c.out.unsent() < max_segs) {
                const id = c.out.peekReady() orelse return;
                const s = c.table.get(id) orelse {
                    c.out.popReady();
                    continue;
                };
                const first = s.pending.first orelse {
                    c.out.popReady();
                    s.flags.ready = false;
                    continue;
                };
                const p: *Pending = @fieldParentPtr("node", first);
                var n: usize = 0;
                if (p.left > 0) {
                    // Off the queue until a WINDOW_UPDATE or SETTINGS gives
                    // the stream credit; the connection's blocks everyone.
                    if (s.send_window <= 0) {
                        c.out.popReady();
                        s.flags.ready = false;
                        continue;
                    }
                    if (c.send_window <= 0) return;
                    n = @intCast(@min(p.left, @as(u64, @intCast(s.send_window)), @as(u64, @intCast(c.send_window)), c.remote.max_frame_size));
                }
                // Still queued if it fails: nothing was framed.
                try c.frameOne(s, p, n);
                c.out.popReady();
                s.flags.ready = false;
                if (s.state != .closed and s.pending.first != null) try c.makeReady(s);
            }
        }

        /// One DATA frame of `n` bytes of `p` (a header of ours, then the
        /// parts' bytes by reference), and what ends the stream after it.
        fn frameOne(c: *Self, s: *Stream, p: *Pending, n: usize) Allocator.Error!void {
            const exhausted = n == p.left;
            const end = exhausted and p.end_stream and p.trailers == null;
            if (n > 0 or end) {
                // Every segment the frame takes, before its header: a frame
                // is queued whole or not at all.
                var segs: usize = 1;
                var rem_parts = n;
                var at = p.part;
                var off = p.off;
                while (rem_parts > 0) : (at += 1) {
                    rem_parts -= @min(p.parts[at].len - off, rem_parts);
                    off = 0;
                    segs += 1;
                }
                try c.out.reserve(segs);
                const b = try c.out.writable(frame.header_len);
                c.out.commit(frame.writeData(b, s.id, end, n, null));
                var rem = n;
                while (rem > 0) {
                    const part = p.parts[p.part];
                    const take = @min(part.len - p.off, rem);
                    c.out.borrow(part[p.off..][0..take]) catch unreachable; // reserved
                    p.off += take;
                    rem -= take;
                    if (p.off == part.len) {
                        p.part += 1;
                        p.off = 0;
                    }
                }
                p.left -= n;
                s.send_window -= @intCast(n);
                c.send_window -= @intCast(n);
            }
            if (!exhausted) return;
            const trailers = p.trailers;
            const end_stream = p.end_stream;
            s.pending.remove(&p.node);
            c.freePending(p);
            if (trailers) |t| {
                c.writeHeaders(s.id, null, t, true) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.HeadersTooLarge => return c.resetStream(s, .internal_error),
                    error.StreamClosed => unreachable,
                };
                c.endLocal(s);
            } else if (end_stream) c.endLocal(s);
        }

        /// HEADERS (+ CONTINUATION) with `:status` first when given: the
        /// block is encoded in place, then cut at the peer's maximum frame
        /// size with the frame headers moved in between.
        fn writeHeaders(c: *Self, id: u31, status: ?u16, hdrs: []const hpack.Field, end_stream: bool) SubmitError!void {
            var digits: [3]u8 = undefined;
            var st_buf: [1]hpack.Field = undefined;
            var st: []const hpack.Field = &.{};
            if (status) |code| {
                std.debug.assert(code >= 100 and code <= 999);
                _ = std.fmt.bufPrint(&digits, "{d}", .{code}) catch unreachable;
                st_buf[0] = .{ .name = ":status", .value = &digits };
                st = &st_buf;
            }
            // Past what could encode under the limit: refused before the
            // buffer is sized for it.
            if (minEncoded(hdrs) > max_headers_len) return error.HeadersTooLarge;
            const bound = hpack.Encoder.bound(st) + hpack.Encoder.bound(hdrs);
            const mfs: usize = c.remote.max_frame_size;
            const room = bound + frame.header_len * (bound / mfs + 1);
            const buf = try c.out.writable(room);
            const size_update = c.encoder.size_update_pending;
            var len = c.encoder.encode(buf[frame.header_len..], st) catch unreachable;
            len += c.encoder.encode(buf[frame.header_len + len ..], hdrs) catch unreachable;
            if (len > max_headers_len) {
                // Not queued: the next block still starts with the size
                // update.
                c.encoder.size_update_pending = size_update;
                return error.HeadersTooLarge;
            }
            const k = if (len == 0) 1 else (len + mfs - 1) / mfs;
            // Chunk i moves from 9 + i*mfs to 9 + i*(9 + mfs); last first.
            var i = k;
            while (i > 1) {
                i -= 1;
                const n = @min(mfs, len - i * mfs);
                const src = frame.header_len + i * mfs;
                const dst = i * (frame.header_len + mfs) + frame.header_len;
                std.mem.copyBackwards(u8, buf[dst..][0..n], buf[src..][0..n]);
            }
            for (0..k) |j| {
                const n = @min(mfs, len - j * mfs);
                const last = j == k - 1;
                var fl: u8 = if (last) frame.flags.end_headers else 0;
                if (j == 0 and end_stream) fl |= frame.flags.end_stream;
                _ = frame.writeHeader(buf[j * (frame.header_len + mfs) ..], .{
                    .length = @intCast(n),
                    .type = if (j == 0) .headers else .continuation,
                    .flags = fl,
                    .stream_id = id,
                });
            }
            c.out.commit(len + k * frame.header_len);
        }
    };
}
