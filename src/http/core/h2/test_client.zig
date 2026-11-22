//! Tests only: the pieces a test's HTTP/2 client needs on the core's client
//! role (`conn.Conn(.client, H)`), where it used to drive an nghttp2
//! session: writing what the core queued, reading with the right scratch,
//! and a request body the test hands over as it goes. Each suite's client
//! is its own handler `H` with its own state (a response record, a
//! WebSocket buffer); the core does the protocol. The suites that talk to
//! a server over a socket: server/h2_harness_test.zig (the shared
//! `TestClient`), grpc/server_test.zig, websocket/h2_test.zig and
//! http/h2_wake_test.zig.
//!
//! What nghttp2's client did for them and Conn(.client) does the same:
//! the connection preface, SETTINGS and PING acknowledgements, and
//! WINDOW_UPDATEs (a handler gives credit back with `Conn.consumed` as DATA
//! arrives).

const std = @import("std");
const conn = @import("conn.zig");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");
const Allocator = std.mem.Allocator;

pub const Field = hpack.Field;
pub const ErrorCode = frame.ErrorCode;

pub fn nv(name: []const u8, value: []const u8) Field {
    return .{ .name = name, .value = value };
}

/// What a test client's connection is set up with: nghttp2's client
/// defaults (a 65535-byte window, nothing raised), so the flow-control
/// tests keep their numbers.
pub const default_options: conn.Options = .{
    .initial_window = conn.default_window,
    .connection_window = conn.default_window,
};

/// The HPACK scratch `Conn.recv` wants.
pub fn scratch(gpa: Allocator, opts: conn.Options) ![]u8 {
    return gpa.alloc(u8, @max(opts.max_header_list_size, hpack.table_capacity));
}

/// Writes everything the core has queued to `w` (not flushed), framing
/// DATA as the windows allow.
pub fn writePending(cn: anytype, w: *std.Io.Writer) !void {
    var vecs: [16][]const u8 = undefined;
    while (true) {
        const v = try cn.pending(&vecs);
        if (v.len == 0) break;
        var n: usize = 0;
        for (v) |b| {
            try w.writeAll(b);
            n += b.len;
        }
        cn.advance(n);
    }
}

/// Bytes read from the peer that the core has not taken: the front of a
/// frame cut short, which `recv` leaves for the next call.
pub const Rx = struct {
    tail: std.ArrayList(u8) = .empty,

    pub fn deinit(rx: *Rx, gpa: Allocator) void {
        rx.tail.deinit(gpa);
    }

    /// Gives the core `bytes` after what was left; the caller has read them
    /// all, whatever the core took.
    pub fn feed(rx: *Rx, gpa: Allocator, cn: anytype, bytes: []const u8, scr: []u8) !void {
        try rx.tail.appendSlice(gpa, bytes);
        const n = try cn.recv(rx.tail.items, 0, scr);
        rx.tail.replaceRangeAssumeCapacity(0, n, &.{});
    }
};

/// Queues a copy of `bytes` on `s` (with END_STREAM when `end`): the core
/// refers to it until it is framed, so it lives in `arena`.
pub fn queue(arena: Allocator, cn: anytype, s: *conn.Stream, bytes: []const u8, end: bool) !void {
    if (bytes.len == 0) return cn.submitData(s, &.{}, end);
    const parts = try arena.create([1][]const u8);
    parts[0] = try arena.dupe(u8, bytes);
    try cn.submitData(s, parts, end);
}

/// Bytes of `s`'s queued DATA not framed yet: what the peer's windows
/// have held back.
pub fn unframed(s: *const conn.Stream) u64 {
    var n: u64 = 0;
    var it = s.pending.first;
    while (it) |node| : (it = node.next) n += @as(*const conn.Pending, @fieldParentPtr("node", node)).left;
    return n;
}

/// The client role: whether `submitRequest` would find room under the
/// server's limit (and no GOAWAY).
pub fn canOpen(c: anytype) bool {
    return c.in != .dead and !c.goaway_recv and c.goaway_sent == null and c.table.size < c.remote.max_concurrent_streams;
}

/// An nghttp2 data provider: the request body as the test hands it over.
/// `data` may be replaced by a longer slice as the test goes (what
/// `nghttp2_session_resume_data` was for); each `poll` queues what is new,
/// by reference, so the bytes must outlive the connection. END_STREAM goes
/// with the last of it unless `keep_open` holds the request side open (a
/// tunnel the peer keeps). `sent` is how much the core has framed (the
/// peer's windows allowing), as nghttp2's read callback had read: updated
/// by `framed`, read by a test's helper thread (`SentGate`).
pub const Source = struct {
    data: []const u8 = "",
    keep_open: bool = false,
    /// Handed to the core, and whether that included END_STREAM.
    queued: usize = 0,
    ended: bool = false,
    sent: usize = 0,

    /// Queues what is new on `s`; `parts` owns the slices `submitData`
    /// keeps referring to until they are framed.
    pub fn poll(src: *Source, arena: Allocator, cn: anytype, s: *conn.Stream) !void {
        if (src.ended) return;
        const rest = src.data[src.queued..];
        const end = !src.keep_open;
        if (rest.len == 0 and !end) return;
        if (rest.len == 0) {
            try cn.submitData(s, &.{}, true);
        } else {
            const parts = try arena.create([1][]const u8);
            parts[0] = rest;
            try cn.submitData(s, parts, end);
        }
        src.queued = src.data.len;
        src.ended = end;
    }

    /// After a write: the bytes the core has taken out of `data`.
    pub fn framed(src: *Source, s: *const conn.Stream) void {
        @atomicStore(usize, &src.sent, src.queued - @as(usize, @intCast(unframed(s))), .release);
    }
};
