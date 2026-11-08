// Translated from nghttp2 (MIT, Copyright (c) 2012, 2014, 2015, 2016
// Tatsuhiro Tsujikawa; Copyright (c) 2012, 2014, 2015, 2016 nghttp2
// contributors), v1.70.0 via Anole's fork xuckless/nghttp2 0f8bc1c,
// lib/nghttp2_frame.c and lib/nghttp2_session.c. See LICENSE.nghttp2 and
// THIRD_PARTY_NOTICES.

//! HTTP/2 frames (RFC 9113 §4 and §6): parse one frame from the front of a
//! byte slice, and write frames into a caller's buffer. No allocation and no
//! copies: payloads, header block fragments and debug data are slices of the
//! input.
//!
//! `parse` makes the checks that need no connection state, in the order
//! nghttp2's `nghttp2_session_mem_recv2` makes them, so the first failing
//! check answers with nghttp2's error code: first those the frame header
//! alone decides (before the payload has arrived, as nghttp2 does), then
//! those on the payload. Stream states, CONTINUATION sequencing and the
//! stateful SETTINGS rules belong to the connection.

const std = @import("std");

/// The frame header's size.
pub const header_len = 9;
/// The smallest SETTINGS_MAX_FRAME_SIZE, and the default.
pub const min_max_frame_size = 1 << 14;
/// The largest SETTINGS_MAX_FRAME_SIZE.
pub const max_max_frame_size = (1 << 24) - 1;
/// The largest window (SETTINGS_INITIAL_WINDOW_SIZE, WINDOW_UPDATE sums).
pub const max_window_size = (1 << 31) - 1;
/// A SETTINGS entry's size.
pub const setting_len = 6;
/// The PRIORITY fields' size (in PRIORITY and in HEADERS).
pub const priority_len = 5;

pub const Type = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
    _,
};

/// Flag bits; which ones a type defines is in `definedFlags`.
pub const flags = struct {
    pub const end_stream: u8 = 0x1;
    pub const ack: u8 = 0x1;
    pub const end_headers: u8 = 0x4;
    pub const padded: u8 = 0x8;
    pub const priority: u8 = 0x20;
};

pub const ErrorCode = enum(u32) {
    no_error = 0,
    protocol_error = 1,
    internal_error = 2,
    flow_control_error = 3,
    settings_timeout = 4,
    stream_closed = 5,
    frame_size_error = 6,
    refused_stream = 7,
    cancel = 8,
    compression_error = 9,
    connect_error = 10,
    enhance_your_calm = 11,
    inadequate_security = 12,
    http_1_1_required = 13,
    _,
};

pub const SettingId = enum(u16) {
    header_table_size = 1,
    enable_push = 2,
    max_concurrent_streams = 3,
    initial_window_size = 4,
    max_frame_size = 5,
    max_header_list_size = 6,
    enable_connect_protocol = 8,
    no_rfc7540_priorities = 9,
    _,
};

pub const Setting = struct { id: SettingId, value: u32 };

pub const FrameHeader = struct {
    length: u24,
    type: Type,
    flags: u8,
    stream_id: u31,

    /// The reserved bit is ignored (RFC 9113 §4.1).
    pub fn parse(b: *const [header_len]u8) FrameHeader {
        return .{
            .length = std.mem.readInt(u24, b[0..3], .big),
            .type = @fromBackingInt(b[3]),
            .flags = b[4],
            .stream_id = readId(b[5..9]),
        };
    }

    /// Writes the reserved bit as 0.
    pub fn write(h: FrameHeader, b: *[header_len]u8) void {
        std.mem.writeInt(u24, b[0..3], h.length, .big);
        b[3] = @backingInt(h.type);
        b[4] = h.flags;
        std.mem.writeInt(u32, b[5..9], h.stream_id, .big);
    }
};

/// RFC 7540 §5.3's priority fields. Anole schedules nothing by them; they
/// are parsed for the checks (a stream depending on itself).
pub const Priority = struct {
    exclusive: bool,
    dependency: u31,
    /// As on the wire: 0..255 means a weight of 1..256.
    weight: u8,
};

pub const Data = struct { end_stream: bool, data: []const u8, pad_len: ?u8 = null };
pub const Headers = struct {
    end_stream: bool,
    end_headers: bool,
    priority: ?Priority = null,
    fragment: []const u8,
    pad_len: ?u8 = null,
};
pub const Settings = struct {
    ack: bool,
    /// The raw entries, a multiple of 6 bytes, every value checked.
    payload: []const u8,

    pub fn iterator(s: Settings) SettingsIterator {
        return .{ .payload = s.payload };
    }
};
pub const PushPromise = struct { end_headers: bool, promised_id: u31, fragment: []const u8, pad_len: ?u8 = null };
pub const Ping = struct { ack: bool, data: [8]u8 };
pub const Goaway = struct { last_stream_id: u31, code: ErrorCode, debug: []const u8 };
pub const Continuation = struct { end_headers: bool, fragment: []const u8 };

pub const Frame = union(enum) {
    data: Data,
    headers: Headers,
    /// `dependency == stream_id` is legal to parse; the connection decides
    /// its scope (a connection error on an idle stream, else a reset).
    priority: Priority,
    rst_stream: ErrorCode,
    settings: Settings,
    push_promise: PushPromise,
    ping: Ping,
    goaway: Goaway,
    /// The increment. 0 on a stream is returned as is: its error's scope
    /// depends on the stream's state, the connection's business.
    window_update: u31,
    continuation: Continuation,
    /// A type this endpoint doesn't know (RFC 9113 §4.1: ignored). The
    /// payload; the type and flags are in the header. Reported so the
    /// connection can charge it to its empty-frame budget.
    unknown: []const u8,
};

pub const Parsed = struct {
    /// With undefined flags cleared, as nghttp2 clears them (RFC 9113 §4.1:
    /// they MUST be ignored). An unknown type's flags are left as sent.
    header: FrameHeader,
    frame: Frame,
};

pub const Scope = enum { connection, stream };

pub const Fault = struct {
    code: ErrorCode,
    scope: Scope,
    /// For logs and GOAWAY debug data; nghttp2's wording where it has one.
    reason: []const u8,
};

pub const Options = struct {
    /// Our SETTINGS_MAX_FRAME_SIZE.
    max_frame_size: u24 = min_max_frame_size,
    /// nghttp2's `max_settings` (`NGHTTP2_DEFAULT_MAX_SETTINGS`).
    max_settings: u32 = 32,
};

pub const Result = union(enum) {
    /// Not a whole frame yet: this many more bytes, at least.
    need: usize,
    /// A frame, `len` bytes from the front of the input.
    frame: struct { parsed: Parsed, len: usize },
    fault: Fault,
};

/// Parses one frame from the front of `bytes`.
pub fn parse(bytes: []const u8, opts: Options) Result {
    if (bytes.len < header_len) return .{ .need = header_len - bytes.len };
    var h = FrameHeader.parse(bytes[0..header_len]);
    if (checkHeader(h, opts)) |f| return .{ .fault = f };
    const len = header_len + @as(usize, h.length);
    if (bytes.len < len) return .{ .need = len - bytes.len };
    h.flags &= definedFlags(h.type);
    const frame = switch (parsePayload(h, bytes[header_len..len])) {
        .frame => |fr| fr,
        .fault => |f| return .{ .fault = f },
    };
    return .{ .frame = .{ .parsed = .{ .header = h, .frame = frame }, .len = len } };
}

/// The flags each type defines; the rest are cleared.
pub fn definedFlags(t: Type) u8 {
    return switch (t) {
        .data => flags.end_stream | flags.padded,
        .headers => flags.end_stream | flags.end_headers | flags.padded | flags.priority,
        .settings, .ping => flags.ack,
        .push_promise => flags.end_headers | flags.padded,
        .continuation => flags.end_headers,
        .priority, .rst_stream, .goaway, .window_update => 0,
        _ => 0xff,
    };
}

fn conn(code: ErrorCode, reason: []const u8) Fault {
    return .{ .code = code, .scope = .connection, .reason = reason };
}

fn frameSize(reason: []const u8) Fault {
    // nghttp2 makes every FRAME_SIZE_ERROR a connection error
    // (session_handle_frame_size_error).
    return conn(.frame_size_error, reason);
}

/// The checks nghttp2 makes at NGHTTP2_IB_READ_HEAD, before the payload.
fn checkHeader(h: FrameHeader, opts: Options) ?Fault {
    if (h.length > opts.max_frame_size) return frameSize("too large frame size");
    const padded = h.flags & flags.padded != 0;
    switch (h.type) {
        .data => {
            // session_on_data_received_fail_fast, before the padding.
            if (h.stream_id == 0) return conn(.protocol_error, "DATA: stream_id == 0");
            if (padded and h.length < 1) return conn(.protocol_error, "DATA: insufficient padding space");
        },
        .headers => {
            if (padded) {
                if (h.length < 1) return conn(.protocol_error, "HEADERS: insufficient padding space");
            } else if (h.flags & flags.priority != 0 and h.length < priority_len) {
                return frameSize("HEADERS: too short for the priority fields");
            }
        },
        .priority => if (h.length != priority_len) return frameSize("PRIORITY: length != 5"),
        .rst_stream => if (h.length != 4) return frameSize("RST_STREAM: length != 4"),
        .window_update => if (h.length != 4) return frameSize("WINDOW_UPDATE: length != 4"),
        .settings => {
            if (h.length % setting_len != 0 or (h.flags & flags.ack != 0 and h.length > 0))
                return frameSize("SETTINGS: invalid length");
            if (h.length / setting_len > opts.max_settings)
                return conn(.enhance_your_calm, "SETTINGS: too many setting entries");
        },
        .push_promise => {
            if (padded) {
                if (h.length < 1) return conn(.protocol_error, "PUSH_PROMISE: insufficient padding space");
            } else if (h.length < 4) {
                return frameSize("PUSH_PROMISE: length < 4");
            }
        },
        .ping => if (h.length != 8) return frameSize("PING: length != 8"),
        .goaway => if (h.length < 8) return frameSize("GOAWAY: length < 8"),
        // Not in nghttp2's READ_HEAD (an unexpected CONTINUATION is the
        // connection's check, which also catches stream 0 as a stream
        // mismatch); the same code and scope, decided earlier.
        .continuation => if (h.stream_id == 0) return conn(.protocol_error, "CONTINUATION: stream_id == 0"),
        _ => {},
    }
    return null;
}

const PayloadResult = union(enum) { frame: Frame, fault: Fault };

fn fault(code: ErrorCode, reason: []const u8) PayloadResult {
    return .{ .fault = conn(code, reason) };
}

/// The checks nghttp2 makes once the payload (or its fixed part) is in;
/// `h.flags` are the defined ones.
fn parsePayload(h: FrameHeader, p: []const u8) PayloadResult {
    const has = struct {
        fn f(x: FrameHeader, bit: u8) bool {
            return x.flags & bit != 0;
        }
    }.f;
    switch (h.type) {
        .data => {
            var d: Data = .{ .end_stream = has(h, flags.end_stream), .data = p };
            if (has(h, flags.padded)) {
                const pad = p[0];
                // inbound_frame_compute_pad: all padding and no data is fine.
                if (pad > p.len - 1) return fault(.protocol_error, "DATA: invalid padding");
                d.pad_len = pad;
                d.data = p[1 .. p.len - pad];
            }
            return .{ .frame = .{ .data = d } };
        },
        .headers => {
            const pri_len: usize = if (has(h, flags.priority)) priority_len else 0;
            var rest = p;
            var hd: Headers = .{ .end_stream = has(h, flags.end_stream), .end_headers = has(h, flags.end_headers), .fragment = p };
            if (has(h, flags.padded)) {
                const pad = p[0];
                if (@as(usize, pad) + 1 + pri_len > p.len) return fault(.protocol_error, "HEADERS: invalid padding");
                hd.pad_len = pad;
                rest = p[1 .. p.len - pad];
            }
            if (pri_len > 0) {
                hd.priority = readPriority(rest[0..priority_len]);
                rest = rest[priority_len..];
            }
            hd.fragment = rest;
            if (h.stream_id == 0) return fault(.protocol_error, "HEADERS: stream_id == 0");
            return .{ .frame = .{ .headers = hd } };
        },
        .priority => {
            // Anole's nghttp2 patch (RFC 9113 §6.3).
            if (h.stream_id == 0) return fault(.protocol_error, "PRIORITY: stream_id == 0");
            return .{ .frame = .{ .priority = readPriority(p[0..priority_len]) } };
        },
        .rst_stream => {
            if (h.stream_id == 0) return fault(.protocol_error, "RST_STREAM: stream_id == 0");
            return .{ .frame = .{ .rst_stream = @fromBackingInt(std.mem.readInt(u32, p[0..4], .big)) } };
        },
        .settings => {
            if (h.stream_id != 0) return fault(.protocol_error, "SETTINGS: stream_id != 0");
            var it: SettingsIterator = .{ .payload = p };
            while (it.next()) |s| if (validateSetting(s)) |f| return .{ .fault = f };
            return .{ .frame = .{ .settings = .{ .ack = has(h, flags.ack), .payload = p } } };
        },
        .push_promise => {
            var rest = p;
            var pp: PushPromise = .{ .end_headers = has(h, flags.end_headers), .promised_id = 0, .fragment = p };
            if (has(h, flags.padded)) {
                const pad = p[0];
                if (@as(usize, pad) + 1 + 4 > p.len) return fault(.protocol_error, "PUSH_PROMISE: invalid padding");
                pp.pad_len = pad;
                rest = p[1 .. p.len - pad];
            }
            pp.promised_id = readId(rest[0..4]);
            pp.fragment = rest[4..];
            if (h.stream_id == 0) return fault(.protocol_error, "PUSH_PROMISE: stream_id == 0");
            return .{ .frame = .{ .push_promise = pp } };
        },
        .ping => {
            if (h.stream_id != 0) return fault(.protocol_error, "PING: stream_id != 0");
            return .{ .frame = .{ .ping = .{ .ack = has(h, flags.ack), .data = p[0..8].* } } };
        },
        .goaway => {
            if (h.stream_id != 0) return fault(.protocol_error, "GOAWAY: stream_id != 0");
            return .{ .frame = .{ .goaway = .{
                .last_stream_id = readId(p[0..4]),
                .code = @fromBackingInt(std.mem.readInt(u32, p[4..8], .big)),
                .debug = p[8..],
            } } };
        },
        .window_update => {
            const inc = readId(p[0..4]);
            if (inc == 0 and h.stream_id == 0) return fault(.protocol_error, "WINDOW_UPDATE: window_size_increment == 0");
            return .{ .frame = .{ .window_update = inc } };
        },
        .continuation => return .{ .frame = .{ .continuation = .{ .end_headers = has(h, flags.end_headers), .fragment = p } } },
        _ => return .{ .frame = .{ .unknown = p } },
    }
}

/// One SETTINGS value's check (nghttp2_iv_check, with the codes
/// nghttp2_session_on_settings_received answers). Unknown ids are fine.
pub fn validateSetting(s: Setting) ?Fault {
    switch (s.id) {
        .enable_push => if (s.value > 1) return conn(.protocol_error, "SETTINGS: invalid SETTINGS_ENABLE_PUSH"),
        .initial_window_size => if (s.value > max_window_size)
            return conn(.flow_control_error, "SETTINGS: too large SETTINGS_INITIAL_WINDOW_SIZE"),
        .max_frame_size => if (s.value < min_max_frame_size or s.value > max_max_frame_size)
            return conn(.protocol_error, "SETTINGS: invalid SETTINGS_MAX_FRAME_SIZE"),
        .enable_connect_protocol => if (s.value > 1)
            return conn(.protocol_error, "SETTINGS: invalid SETTINGS_ENABLE_CONNECT_PROTOCOL"),
        .no_rfc7540_priorities => if (s.value > 1)
            return conn(.protocol_error, "SETTINGS: invalid SETTINGS_NO_RFC7540_PRIORITIES"),
        .header_table_size, .max_concurrent_streams, .max_header_list_size, _ => {},
    }
    return null;
}

/// The entries of a SETTINGS payload, in order.
pub const SettingsIterator = struct {
    payload: []const u8,
    pos: usize = 0,

    pub fn next(it: *SettingsIterator) ?Setting {
        if (it.payload.len - it.pos < setting_len) return null;
        const e = it.payload[it.pos..][0..setting_len];
        it.pos += setting_len;
        return .{ .id = @fromBackingInt(std.mem.readInt(u16, e[0..2], .big)), .value = std.mem.readInt(u32, e[2..6], .big) };
    }
};

fn readId(b: *const [4]u8) u31 {
    return @truncate(std.mem.readInt(u32, b, .big));
}

fn readPriority(b: *const [priority_len]u8) Priority {
    const v = std.mem.readInt(u32, b[0..4], .big);
    return .{ .exclusive = v & 0x8000_0000 != 0, .dependency = @truncate(v), .weight = b[4] };
}

fn writePriorityFields(b: *[priority_len]u8, p: Priority) void {
    std.mem.writeInt(u32, b[0..4], @as(u32, p.dependency) | @as(u32, if (p.exclusive) 0x8000_0000 else 0), .big);
    b[4] = p.weight;
}

// Serializers. Each writes one whole frame at the front of `buf` (which
// must have room: asserted) and returns its size. Padding is written as
// zeros, on DATA and HEADERS only (tests and the client).

pub fn writeHeader(buf: []u8, h: FrameHeader) usize {
    h.write(buf[0..header_len]);
    return header_len;
}

/// DATA's frame header and, with `pad`, its Pad Length byte: the data goes
/// out by reference after it, then `pad` zero bytes (`padding`).
pub fn writeData(buf: []u8, stream_id: u31, end_stream: bool, data_len: usize, pad: ?u8) usize {
    const extra: usize = if (pad) |p| 1 + @as(usize, p) else 0;
    const f: u8 = (if (end_stream) flags.end_stream else 0) | (if (pad != null) flags.padded else 0);
    var n = writeHeader(buf, .{ .length = @intCast(data_len + extra), .type = .data, .flags = f, .stream_id = stream_id });
    if (pad) |p| {
        buf[n] = p;
        n += 1;
    }
    return n;
}

/// The padding after a padded DATA frame's data.
pub const padding: [256]u8 = @splat(0);

pub fn writeHeaders(buf: []u8, stream_id: u31, hd: Headers) usize {
    const extra: usize = (if (hd.pad_len) |p| 1 + @as(usize, p) else 0) + @as(usize, if (hd.priority != null) priority_len else 0);
    const f: u8 = (if (hd.end_stream) flags.end_stream else 0) | (if (hd.end_headers) flags.end_headers else 0) |
        (if (hd.pad_len != null) flags.padded else 0) | (if (hd.priority != null) flags.priority else 0);
    var n = writeHeader(buf, .{ .length = @intCast(hd.fragment.len + extra), .type = .headers, .flags = f, .stream_id = stream_id });
    if (hd.pad_len) |p| {
        buf[n] = p;
        n += 1;
    }
    if (hd.priority) |p| {
        writePriorityFields(buf[n..][0..priority_len], p);
        n += priority_len;
    }
    @memcpy(buf[n..][0..hd.fragment.len], hd.fragment);
    n += hd.fragment.len;
    if (hd.pad_len) |p| {
        @memset(buf[n..][0..p], 0);
        n += p;
    }
    return n;
}

pub fn writePriority(buf: []u8, stream_id: u31, p: Priority) usize {
    const n = writeHeader(buf, .{ .length = priority_len, .type = .priority, .flags = 0, .stream_id = stream_id });
    writePriorityFields(buf[n..][0..priority_len], p);
    return n + priority_len;
}

pub fn writeRstStream(buf: []u8, stream_id: u31, code: ErrorCode) usize {
    const n = writeHeader(buf, .{ .length = 4, .type = .rst_stream, .flags = 0, .stream_id = stream_id });
    std.mem.writeInt(u32, buf[n..][0..4], @backingInt(code), .big);
    return n + 4;
}

pub fn writeSettings(buf: []u8, ack: bool, settings: []const Setting) usize {
    var n = writeHeader(buf, .{
        .length = @intCast(settings.len * setting_len),
        .type = .settings,
        .flags = if (ack) flags.ack else 0,
        .stream_id = 0,
    });
    for (settings) |s| {
        std.mem.writeInt(u16, buf[n..][0..2], @backingInt(s.id), .big);
        std.mem.writeInt(u32, buf[n + 2 ..][0..4], s.value, .big);
        n += setting_len;
    }
    return n;
}

pub fn writePushPromise(buf: []u8, stream_id: u31, pp: PushPromise) usize {
    const extra: usize = (if (pp.pad_len) |p| 1 + @as(usize, p) else 0) + 4;
    const f: u8 = (if (pp.end_headers) flags.end_headers else 0) | (if (pp.pad_len != null) flags.padded else 0);
    var n = writeHeader(buf, .{ .length = @intCast(pp.fragment.len + extra), .type = .push_promise, .flags = f, .stream_id = stream_id });
    if (pp.pad_len) |p| {
        buf[n] = p;
        n += 1;
    }
    std.mem.writeInt(u32, buf[n..][0..4], pp.promised_id, .big);
    n += 4;
    @memcpy(buf[n..][0..pp.fragment.len], pp.fragment);
    n += pp.fragment.len;
    if (pp.pad_len) |p| {
        @memset(buf[n..][0..p], 0);
        n += p;
    }
    return n;
}

pub fn writePing(buf: []u8, ack: bool, data: [8]u8) usize {
    const n = writeHeader(buf, .{ .length = 8, .type = .ping, .flags = if (ack) flags.ack else 0, .stream_id = 0 });
    buf[n..][0..8].* = data;
    return n + 8;
}

pub fn writeGoaway(buf: []u8, last_stream_id: u31, code: ErrorCode, debug: []const u8) usize {
    const n = writeHeader(buf, .{ .length = @intCast(8 + debug.len), .type = .goaway, .flags = 0, .stream_id = 0 });
    std.mem.writeInt(u32, buf[n..][0..4], last_stream_id, .big);
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], @backingInt(code), .big);
    @memcpy(buf[n + 8 ..][0..debug.len], debug);
    return n + 8 + debug.len;
}

pub fn writeWindowUpdate(buf: []u8, stream_id: u31, increment: u31) usize {
    const n = writeHeader(buf, .{ .length = 4, .type = .window_update, .flags = 0, .stream_id = stream_id });
    std.mem.writeInt(u32, buf[n..][0..4], increment, .big);
    return n + 4;
}

pub fn writeContinuation(buf: []u8, stream_id: u31, end_headers: bool, fragment: []const u8) usize {
    const n = writeHeader(buf, .{
        .length = @intCast(fragment.len),
        .type = .continuation,
        .flags = if (end_headers) flags.end_headers else 0,
        .stream_id = stream_id,
    });
    @memcpy(buf[n..][0..fragment.len], fragment);
    return n + fragment.len;
}
