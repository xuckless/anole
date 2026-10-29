//! C ABI tests for p3/net, imported from engine_test.zig: raw TCP and UDP
//! listeners through the engine, the way libanole's exports drive it.
//! Deterministic: every wait is on a record arriving or bytes read.
const std = @import("std");
const wait = @import("anole_test_wait");
const builtin = @import("builtin");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const config = @import("config.zig");
const parity = @import("parity.zig");
const abi = engine.abi;
const features = anole.features;
const ClientStream = anole.net.ClientStream;

const alloc = std.testing.allocator;

const Rec = struct {
    type: u32,
    handle: u64,
    bytes: []align(8) u8,

    fn span(r: Rec, s: abi.Span) []const u8 {
        return r.bytes[s.off..][0..s.len];
    }
};

/// An engine with one consumer thread that collects what it polls.
const Rig = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set: the thread leaves polling to the test (`takeOver`).
    manual: std.atomic.Value(bool) = .init(false),
    /// Set by the thread once it saw `manual`, out of its poll: one consumer
    /// is polled by one thread at a time.
    parked: std.atomic.Value(bool) = .init(false),
    /// Set with `stop`: wakes a thread parked by `takeOver`.
    stopped: std.Io.Event = .unset,
    lock: std.atomic.Mutex = .unlocked,
    recs: std.ArrayList(Rec) = .empty,

    fn create(json: []const u8) !*Rig {
        var why_buf: [400]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        const e = engine.Engine.create(json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer e.destroy();
        const c = try e.attach(null, null, false);
        const r = try alloc.create(Rig);
        errdefer alloc.destroy(r);
        r.* = .{ .e = e, .c = c, .thread = undefined };
        try e.start();
        r.thread = try std.Thread.spawn(.{}, loop, .{r});
        return r;
    }

    fn destroy(r: *Rig) void {
        r.stop.store(true, .release);
        r.stopped.set(std.testing.io);
        r.thread.join();
        r.e.drain() catch {};
        _ = r.e.wait(@intCast(wait.deadlineMs()));
        r.e.destroy();
        for (r.recs.items) |x| alloc.free(x.bytes);
        r.recs.deinit(alloc);
        alloc.destroy(r);
    }

    /// The test polls from now on: returns once the thread has left its
    /// poll (a poll still under way would overlap the test's).
    fn takeOver(r: *Rig) !void {
        r.manual.store(true, .release);
        try wait.waitFlag(std.testing.io, "the rig's thread left its poll", &r.parked);
    }

    fn lockIt(r: *Rig) void {
        while (!r.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn loop(r: *Rig) void {
        var buf: [1 << 20]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!r.stop.load(.acquire)) {
            if (r.manual.load(.acquire)) {
                r.parked.store(true, .release);
                // Parked until `destroy`; the loop then ends on `stop`.
                r.stopped.wait(std.testing.io) catch {};
                continue;
            }
            const n = engine.pollWait(r.c, &buf, 20, &need) catch continue;
            r.collect(buf[0..n]);
        }
    }

    fn collect(r: *Rig, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&bytes[off]));
            const copy = alloc.alignedAlloc(u8, .@"8", ev.len) catch return;
            @memcpy(copy, bytes[off..][0..ev.len]);
            r.lockIt();
            r.recs.append(alloc, .{ .type = ev.type, .handle = ev.handle, .bytes = copy }) catch {};
            r.lock.unlock();
            off += ev.len;
        }
    }

    /// The first record of `typ` not taken yet (waits).
    fn take(r: *Rig, typ: abi.EventType) !Rec {
        const Take = struct {
            r: *Rig,
            typ: abi.EventType,
            got: *?Rec,
            fn found(t: @This()) bool {
                t.r.lockIt();
                defer t.r.lock.unlock();
                for (t.r.recs.items, 0..) |x, i| if (x.type == @backingInt(t.typ)) {
                    t.got.* = t.r.recs.orderedRemove(i);
                    return true;
                };
                return false;
            }
        };
        var got: ?Rec = null;
        try wait.waitUntil(std.testing.io, "a record of the type came", Take{ .r = r, .typ = typ, .got = &got }, Take.found);
        return got.?;
    }

    /// How many records of `typ` are waiting.
    fn pending(r: *Rig, typ: abi.EventType) usize {
        r.lockIt();
        defer r.lock.unlock();
        var n: usize = 0;
        for (r.recs.items) |x| n += @intFromBool(x.type == @backingInt(typ));
        return n;
    }

    fn client(r: *Rig) !*ClientStream {
        return ClientStream.connect(alloc, std.testing.io, .{ .host = "127.0.0.1", .port = r.e.port(0), .address = .{ .ip4 = .loopback(r.e.port(0)) } });
    }
};

fn free(rec: Rec) void {
    alloc.free(rec.bytes);
}

const tcp_plain = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 500}, \"listeners\": [{\"name\": \"chat\", \"address\": \"127.0.0.1\", \"port\": 0, \"tcp\": {\"handler\": 7}}]}";
const tcp_lines = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 500}, \"listeners\": [{\"name\": \"chat\", \"address\": \"127.0.0.1\", \"port\": 0, \"tcp\": {\"handler\": 7, \"framing\": {\"lines\": {}}}}]}";

fn readExactly(s: *ClientStream, n: usize) ![]const u8 {
    return s.reader().take(n);
}

test "capi net: open, data and close records" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    const s = try rig.client();
    try s.writer().writeAll("hi");
    try s.writer().flush();

    const open = try rig.take(.net_open);
    defer free(open);
    const oe: *const abi.NetOpenEvent = @ptrCast(open.bytes.ptr);
    try std.testing.expectEqual(@as(u32, 7), oe.handler_id);
    try std.testing.expectEqual(@as(u32, abi.NET_FRAMING_NONE), oe.framing);
    try std.testing.expectEqualStrings("chat", open.span(oe.listener));
    try std.testing.expect(std.mem.startsWith(u8, open.span(oe.remote_text), "127.0.0.1:"));
    try std.testing.expectEqual(@as(u16, 4), oe.remote.family);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, oe.remote.addr[0..4]);
    try std.testing.expectEqual(rig.e.port(0), oe.local.port);

    const data = try rig.take(.net_data);
    defer free(data);
    const de: *const abi.NetDataEvent = @ptrCast(data.bytes.ptr);
    try std.testing.expectEqual(@as(u32, 1), de.nframes);
    try std.testing.expectEqual(@as(u32, 0), de.flags);
    const sp: *const abi.Span = @ptrCast(@alignCast(&data.bytes[de.frames_off]));
    try std.testing.expectEqualStrings("hi", data.span(sp.*));

    s.close();
    const close = try rig.take(.net_close);
    defer free(close);
    const ce: *const abi.NetCloseEvent = @ptrCast(close.bytes.ptr);
    try std.testing.expectEqual(@as(u32, abi.NET_CLOSED_PEER), ce.reason);
    try std.testing.expectEqual(@as(u64, 2), ce.bytes_in);
    try std.testing.expectEqual(open.handle, close.handle);
    // Over: the handle is stale, releasing it is fine, writing says gone.
    try std.testing.expectError(error.Gone, engine.net.write(rig.e, open.handle, "x", 0));
    engine.handleRelease(rig.e, open.handle) catch |err| try std.testing.expectEqual(error.Over, err);
}

test "capi net: line framing delivers each line as one frame, in order, with F_FRAMES" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_lines);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    try s.writer().writeAll("a\nbb\nccc\n");
    try s.writer().flush();
    const open = try rig.take(.net_open);
    defer free(open);
    // The kernel may split the write: take records until three frames.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var frames: usize = 0;
    while (frames < 3) {
        const data = try rig.take(.net_data);
        defer free(data);
        const de: *const abi.NetDataEvent = @ptrCast(data.bytes.ptr);
        try std.testing.expect(de.flags & abi.NET_DATA_F_FRAMES != 0);
        for (0..de.nframes) |i| {
            const sp: *const abi.Span = @ptrCast(@alignCast(&data.bytes[de.frames_off + i * @sizeOf(abi.Span)]));
            try got.appendSlice(alloc, data.span(sp.*));
            try got.append(alloc, '|');
        }
        frames += de.nframes;
    }
    try std.testing.expectEqualStrings("a|bb|ccc|", got.items);
}

const tcp_length = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 500}, \"listeners\": [{\"name\": \"rpc\", \"address\": \"127.0.0.1\", \"port\": 0, \"tcp\": {\"handler\": 1, \"framing\": {\"length\": {\"bytes\": 2}}}}]}";

/// A connection on a 2-byte length-framed listener, opened by one frame
/// from the client; returns its handle.
fn openFramed(rig: *Rig, s: *ClientStream) !u64 {
    try s.writer().writeAll("\x00\x01x");
    try s.writer().flush();
    const open = try rig.take(.net_open);
    defer free(open);
    return open.handle;
}

test "capi net: plain and length-framed writes reach the client" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_length);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    const h = try openFramed(rig, s);
    try std.testing.expect(!(try engine.net.write(rig.e, h, "abc", 0)));
    try std.testing.expectEqualStrings("abc", try readExactly(s, 3));
    try std.testing.expect(!(try engine.net.write(rig.e, h, "hello", abi.NET_F_FRAME)));
    try std.testing.expectEqualStrings("\x00\x05hello", try readExactly(s, 7));
}

test "capi net: a borrowed write gets exactly one SENT with its pointer" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_length);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    const h = try openFramed(rig, s);
    // Its bytes stay valid until SENT.
    const body = try alloc.dupe(u8, "borrowed");
    defer alloc.free(body);
    _ = try engine.net.write(rig.e, h, body, abi.BODY_BORROW);
    try std.testing.expectEqualStrings("borrowed", try readExactly(s, 8));
    const sent = try rig.take(.sent);
    defer free(sent);
    const se: *const abi.SentEvent = @ptrCast(sent.bytes.ptr);
    try std.testing.expectEqual(@intFromPtr(body.ptr), se.data);
    try std.testing.expectEqual(h, sent.handle);
    try wait.expectStays(std.testing.io, "no second SENT", rig, struct {
        fn none(r: *Rig) bool {
            return r.pending(.sent) == 0;
        }
    }.none, wait.short_window);
}

test "capi net: F_END ends the stream: EOF at the client, a later write is Invalid/Ended" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_length);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    const h = try openFramed(rig, s);
    _ = try engine.net.write(rig.e, h, "", abi.NET_F_END);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), s.reader().readSliceShort(&buf) catch 0);
    try std.testing.expectError(error.Invalid, engine.net.write(rig.e, h, "late", 0));
    try std.testing.expectEqualStrings("Ended", engine.net.invalid_token);
}

test "capi net: a write on a handle of another kind is WrongKind" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_length);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    const h = engine.Handle.decode(try openFramed(rig, s));
    // The live connection's slot, named as a request.
    const other = engine.Handle.encode(.{ .gen = h.gen, .kind = .request, .slot = h.slot, .exec = h.exec });
    try std.testing.expectError(error.WrongKind, engine.net.write(rig.e, other, "x", 0));
}

test "capi net: close RESET resets the client" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    try s.writer().writeAll("x");
    try s.writer().flush();
    const open = try rig.take(.net_open);
    defer free(open);
    try engine.net.closeConn(rig.e, open.handle, abi.NET_CLOSE_RESET);
    const close = try rig.take(.net_close);
    defer free(close);
    const ce: *const abi.NetCloseEvent = @ptrCast(close.bytes.ptr);
    try std.testing.expectEqual(@as(u32, abi.NET_CLOSED_LOCAL), ce.reason);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), s.reader().readSliceShort(&buf) catch 0);
    // A cleanup call on a closed connection is fine.
    engine.net.closeConn(rig.e, open.handle, abi.NET_CLOSE_GRACEFUL) catch |err| try std.testing.expectEqual(error.Over, err);
}

test "capi net: RESET racing the connection's end, many times" {
    // The reset shuts the socket, the connection's task ends and releases
    // it, all while the consumer's call still holds the slot: the reset's
    // own wake-up of the writer must not reach a released connection (it
    // used to: the driver then spun on freed memory, at teardown).
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    for (0..200) |_| {
        const s = try rig.client();
        defer s.close();
        try s.writer().writeAll("x");
        try s.writer().flush();
        const open = try rig.take(.net_open);
        defer free(open);
        try engine.net.closeConn(rig.e, open.handle, abi.NET_CLOSE_RESET);
        const close = try rig.take(.net_close);
        defer free(close);
    }
}

/// Takes every record of `handle` the rig holds, and counts those of `typ`.
fn dropFor(r: *Rig, handle: u64, typ: abi.EventType) usize {
    r.lockIt();
    defer r.lock.unlock();
    var n: usize = 0;
    var i: usize = 0;
    while (i < r.recs.items.len) {
        const x = r.recs.items[i];
        if (x.handle != handle) {
            i += 1;
            continue;
        }
        if (x.type == @backingInt(typ)) n += 1;
        alloc.free(x.bytes);
        _ = r.recs.orderedRemove(i);
    }
    return n;
}

/// A borrowed write's bytes: valid for the process (until SENT, at least).
const lent: [256]u8 = @splat('b');

test "capi net: a borrowed write racing a RESET gets exactly one SENT, written or dropped" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    for (0..30) |_| {
        const s = try rig.client();
        defer s.close();
        try s.writer().writeAll("x");
        try s.writer().flush();
        const open = try rig.take(.net_open);
        defer free(open);
        _ = try engine.net.write(rig.e, open.handle, &lent, abi.BODY_BORROW);
        try engine.net.closeConn(rig.e, open.handle, abi.NET_CLOSE_RESET);
        const close = try rig.take(.net_close);
        defer free(close);
        // The connection's SENT records come before its CLOSE.
        try std.testing.expectEqual(@as(usize, 1), dropFor(rig, open.handle, .sent));
    }
}

/// `[stress]`: consumer threads writing to one connection while it is reset
/// or its peer goes.
const WriteStorm = struct {
    rig: *Rig,
    handle: u64,
    /// Borrowed writes the call took (OK or BUSY).
    borrowed_ok: std.atomic.Value(u32) = .init(0),
    bad: std.atomic.Value(u32) = .init(0),

    fn run(w: *WriteStorm, k: u32) void {
        for (0..16) |j| {
            const borrow = (j + k) % 2 == 0;
            const n = 1 + (j * 37 + k * 11) % lent.len;
            if (engine.net.write(w.rig.e, w.handle, lent[0..n], if (borrow) abi.BODY_BORROW else 0)) |_| {
                if (borrow) _ = w.borrowed_ok.fetchAdd(1, .release);
            } else |err| switch (err) {
                error.Gone, error.Again => {},
                error.Invalid => if (!std.mem.eql(u8, engine.net.invalid_token, "Ended")) {
                    _ = w.bad.fetchAdd(1, .release);
                },
                else => _ = w.bad.fetchAdd(1, .release),
            }
        }
    }
};

test "capi net: [stress] writes and borrowed writes racing RESET and peer close" {
    if (comptime !features.net) return error.SkipZigTest;
    try wait.requireStress();
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    var prng: std.Random.DefaultPrng = .init(0xca91_0002);
    for (0..5000) |round| {
        const s = try rig.client();
        var client_open = true;
        defer if (client_open) s.close();
        try s.writer().writeAll("x");
        try s.writer().flush();
        const open = try rig.take(.net_open);
        defer free(open);
        var ws: WriteStorm = .{ .rig = rig, .handle = open.handle };
        var threads: [4]std.Thread = undefined;
        for (&threads, 0..) |*t, k| t.* = try std.Thread.spawn(.{}, WriteStorm.run, .{ &ws, @as(u32, @intCast(k)) });
        if (prng.random().boolean()) {
            try engine.net.closeConn(rig.e, open.handle, abi.NET_CLOSE_RESET);
        } else {
            s.close();
            client_open = false;
        }
        for (threads) |t| t.join();
        const close = try rig.take(.net_close);
        defer free(close);
        // After its CLOSE was polled, a write is Gone, never OK.
        try std.testing.expectError(error.Gone, engine.net.write(rig.e, open.handle, "late", 0));
        const sent = dropFor(rig, open.handle, .sent);
        if (sent != ws.borrowed_ok.load(.acquire) or ws.bad.load(.acquire) != 0) {
            std.debug.print("round {d}: {d} borrowed writes taken, {d} SENT, {d} bad answers\n", .{ round, ws.borrowed_ok.load(.acquire), sent, ws.bad.load(.acquire) });
            return error.TestUnexpectedResult;
        }
    }
}

test "capi net: pause holds input until resume" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    try s.writer().writeAll("one");
    try s.writer().flush();
    const open = try rig.take(.net_open);
    defer free(open);
    const first = try rig.take(.net_data);
    free(first);
    try engine.net.pause(rig.e, open.handle, true);
    try s.writer().writeAll("two");
    try s.writer().flush();
    // Held: nothing arrives while paused.
    try wait.expectStays(std.testing.io, "no data record while paused", rig, struct {
        fn none(r: *Rig) bool {
            return r.pending(.net_data) == 0;
        }
    }.none, wait.short_window);
    try engine.net.pause(rig.e, open.handle, false);
    const second = try rig.take(.net_data);
    defer free(second);
    const de: *const abi.NetDataEvent = @ptrCast(second.bytes.ptr);
    const sp: *const abi.Span = @ptrCast(@alignCast(&second.bytes[de.frames_off]));
    try std.testing.expectEqualStrings("two", second.span(sp.*));
}

fn slotUnpolled(e: *engine.Engine, hv: u64) u32 {
    const h = engine.Handle.decode(hv);
    const x = &e.execs[h.exec];
    const chunk = x.net.chunks[h.slot / 256].load(.acquire).?;
    return chunk[h.slot % 256].unpolled.load(.acquire);
}

test "capi net: a connection never has more than read_ahead unpolled" {
    if (comptime !features.net) return error.SkipZigTest;
    const json = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 500}, \"listeners\": [{\"name\": \"flood\", \"address\": \"127.0.0.1\", \"port\": 0, \"tcp\": {\"handler\": 1, \"read_ahead\": 4096, \"read_window\": 4096}}]}";
    const rig = try Rig.create(json);
    defer rig.destroy();
    try rig.takeOver();
    const s = try rig.client();
    defer s.close();
    const chunk: [1024]u8 = @splat('q');
    // 64 KiB from the client, on a thread of its own so that the test can poll.
    const Sender = struct {
        fn run(st: *ClientStream, c: []const u8) void {
            for (0..64) |_| st.writer().writeAll(c) catch return;
            st.writer().flush() catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Sender.run, .{ s, &chunk });
    defer t.join();
    var small: [8192]u8 align(8) = undefined;
    var need: u32 = 0;
    var total: usize = 0;
    var max_unpolled: u32 = 0;
    const started = std.Io.Clock.awake.now(std.testing.io);
    while (total < 64 * 1024) {
        if (started.untilNow(std.testing.io, .awake).nanoseconds >= wait.deadline().nanoseconds) {
            std.debug.print("timed out with {d} of {d} bytes received\n", .{ total, 64 * 1024 });
            return error.WaitTimedOut;
        }
        const n = try engine.pollWait(rig.c, &small, 20, &need);
        var off: usize = 0;
        while (off < n) {
            const ev: *const abi.Event = @ptrCast(@alignCast(&small[off]));
            if (ev.type == @backingInt(abi.EventType.net_data)) {
                // Unpolled after this record left, plus the record itself.
                max_unpolled = @max(max_unpolled, slotUnpolled(rig.e, ev.handle) + ev.len);
                const de: *const abi.NetDataEvent = @ptrCast(@alignCast(&small[off]));
                const sp: *const abi.Span = @ptrCast(@alignCast(&small[off + de.frames_off]));
                total += sp.len;
            }
            off += ev.len;
        }
    }
    try std.testing.expectEqual(@as(usize, 64 * 1024), total);
    // What is unpolled is under the limit, or one record (a window and its
    // 40-byte header) posted when nothing was; plus the record just taken,
    // up to a window and its header too.
    try std.testing.expect(max_unpolled <= 2 * (4096 + 64));
}

const udp_json = "{\"executors\": 2, \"timeouts\": {\"shutdown_ms\": 500}, \"listeners\": [{\"name\": \"game\", \"address\": \"127.0.0.1\", \"port\": 0, \"udp\": {\"handler\": 3}}]}";

/// A UDP listener, a client socket, and the five datagrams it sent taken
/// as records: the socket's handle and the client's address as the engine
/// saw it.
const Udp = struct {
    rig: *Rig,
    c: std.Io.net.Socket,
    handle: u64 = 0,
    from: abi.NetAddr = .{},

    fn init() !Udp {
        const rig = try Rig.create(udp_json);
        errdefer rig.destroy();
        const io = std.testing.io;
        const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .rig = rig, .c = try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }) };
    }

    fn deinit(u: *Udp) void {
        u.c.close(std.testing.io);
        u.rig.destroy();
    }

    fn sendFive(u: *Udp) !void {
        const to: std.Io.net.IpAddress = .{ .ip4 = .loopback(u.rig.e.listeners[0].udp_port) };
        for (0..5) |i| {
            var b: [8]u8 = undefined;
            try u.c.send(std.testing.io, &to, try std.fmt.bufPrint(&b, "d{d}", .{i}));
        }
    }

    /// Takes records until the five datagrams came, checking each.
    fn takeFive(u: *Udp) !void {
        var seen: usize = 0;
        while (seen < 5) {
            const rec = try u.rig.take(.net_datagrams);
            defer free(rec);
            const ev: *const abi.NetDatagramsEvent = @ptrCast(rec.bytes.ptr);
            try std.testing.expectEqual(@as(u32, 3), ev.handler_id);
            u.handle = rec.handle;
            for (0..ev.ndatagrams) |i| {
                const d: *const abi.NetDatagramIn = @ptrCast(@alignCast(&rec.bytes[ev.datagrams_off + i * @sizeOf(abi.NetDatagramIn)]));
                try std.testing.expectEqual(@as(u16, 4), d.remote.family);
                try std.testing.expectEqual(u.c.address.getPort(), d.remote.port);
                u.from = d.remote;
            }
            seen += ev.ndatagrams;
        }
    }

    fn ready(u: *Udp) !void {
        try u.sendFive();
        try u.takeFive();
    }

    /// One datagram at the client, with a deadline: the receive runs as
    /// its own task (std.Io.Threaded has no receive timeout on Windows).
    fn receive(u: *Udp, out: []u8) ![]const u8 {
        const io = std.testing.io;
        const Recv = struct {
            c: *const std.Io.net.Socket,
            buf: [16]u8 = undefined,
            len: usize = 0,
            done: std.atomic.Value(bool) = .init(false),
            fn run(r: *@This(), rio: std.Io) anyerror!void {
                const msg = try r.c.receive(rio, &r.buf);
                r.len = msg.data.len;
                r.done.store(true, .release);
            }
        };
        var r: Recv = .{ .c = &u.c };
        var f = try io.concurrent(Recv.run, .{ &r, io });
        defer f.cancel(io) catch {};
        try wait.waitFlag(io, "a reply datagram reached the client", &r.done);
        try f.await(io);
        @memcpy(out[0..r.len], r.buf[0..r.len]);
        return out[0..r.len];
    }
};

const reply_texts = [_][]const u8{ "r0", "r1", "r2", "r3", "r4" };

fn replies(to: abi.NetAddr) [5]abi.NetDatagram {
    var out: [5]abi.NetDatagram = undefined;
    for (&out, reply_texts) |*r, t| r.* = .{ .to = to, .from = .{}, .data = t.ptr, .len = t.len };
    return out;
}

test "capi net: a UDP listener reports the UDP flag, port 0 and its bound udp_port" {
    if (comptime !features.net) return error.SkipZigTest;
    var u: Udp = try .init();
    defer u.deinit();
    const l = &u.rig.e.listeners[0];
    try std.testing.expectEqual(abi.LISTENER_F_UDP, l.flags & abi.LISTENER_F_UDP);
    try std.testing.expectEqual(@as(u16, 0), l.port);
    try std.testing.expect(l.udp_port != 0);
}

test "capi net: datagrams arrive with their handler id and the sender's address" {
    if (comptime !features.net) return error.SkipZigTest;
    var u: Udp = try .init();
    defer u.deinit();
    try u.sendFive();
    // takeFive checks the handler id and the address of each.
    try u.takeFive();
    try std.testing.expect(u.handle != 0);
}

test "capi net: udp_send sends five replies in one call" {
    if (comptime !features.net) return error.SkipZigTest;
    var u: Udp = try .init();
    defer u.deinit();
    try u.ready();
    var r = replies(u.from);
    _ = try engine.net.udpSend(u.rig.e, u.handle, &r, 0);
    for (reply_texts) |t| {
        var buf: [16]u8 = undefined;
        try std.testing.expectEqualStrings(t, try u.receive(&buf));
    }
}

test "capi net: udp_find finds a UDP listener's socket by name, and it sends" {
    if (comptime !features.net) return error.SkipZigTest;
    var u: Udp = try .init();
    defer u.deinit();
    try u.ready();
    // The listener's first socket, the one the datagrams came on unless
    // Linux has a socket per executor.
    const found = try engine.net.udpFind(u.rig.e, "game");
    if (builtin.os.tag != .linux) try std.testing.expectEqual(u.handle, found);
    var r = replies(u.from);
    _ = try engine.net.udpSend(u.rig.e, found, r[0..1], 0);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("r0", try u.receive(&buf));
}

test "capi net: udp_find and udp_send refuse an unknown name, an oversized datagram and unknown flags" {
    if (comptime !features.net) return error.SkipZigTest;
    var u: Udp = try .init();
    defer u.deinit();
    try u.ready();
    try std.testing.expectError(error.Invalid, engine.net.udpFind(u.rig.e, "nope"));
    var big: [1]abi.NetDatagram = .{.{ .to = u.from, .from = .{}, .data = reply_texts[0].ptr, .len = 70000 }};
    try std.testing.expectError(error.Invalid, engine.net.udpSend(u.rig.e, u.handle, &big, 0));
    var r = replies(u.from);
    try std.testing.expectError(error.Invalid, engine.net.udpSend(u.rig.e, u.handle, &r, 1));
}

test "capi net: drain closes a connection the consumer leaves open" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_plain);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    try s.writer().writeAll("x");
    try s.writer().flush();
    const open = try rig.take(.net_open);
    defer free(open);
    try rig.e.drain();
    const draining = try rig.take(.draining);
    free(draining);
    const close = try rig.take(.net_close);
    defer free(close);
    const ce: *const abi.NetCloseEvent = @ptrCast(close.bytes.ptr);
    try std.testing.expectEqual(@as(u32, abi.NET_CLOSED_DRAIN), ce.reason);
}

test "capi net: config tcp and udp keys parse, and each refusal says why" {
    if (comptime !features.net) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const ok = try config.parse(arena.allocator(),
        \\{"listeners": [{"port": 0, "tcp": {"handler": 2, "framing": {"length": {"bytes": 2, "endian": "little"}}, "idle_timeout_ms": 5000}}, {"port": 0, "udp": {"handler": 3, "batch": 8}}]}
    , &why);
    try std.testing.expectEqual(@as(u32, 2), ok.listeners[0].tcp.?.handler);
    try std.testing.expectEqual(@as(?u32, 5000), ok.listeners[0].tcp.?.idle_timeout_ms);
    try std.testing.expectEqual(@as(u8, 8), ok.listeners[1].udp.?.batch);
    const f = config.netFraming(ok.listeners[0].tcp.?.framing);
    try std.testing.expectEqual(std.builtin.Endian.little, f.length.endian);

    const bad = [_]struct { json: []const u8, text: []const u8 }{
        .{ .json = "{\"listeners\": [{\"port\": 0, \"tcp\": {\"handler\": 1}, \"udp\": {\"handler\": 1}}]}", .text = "tcp and udp together" },
        .{ .json = "{\"listeners\": [{\"tcp\": {\"handler\": 1}}]}", .text = "needs a port" },
        .{ .json = "{\"listeners\": [{\"port\": 0, \"udp\": {\"handler\": 1}, \"proxy_protocol\": true}]}", .text = "proxy_protocol" },
        .{ .json = "{\"listeners\": [{\"port\": 0, \"tcp\": {\"handler\": 1, \"framing\": {\"lines\": {}, \"varint\": {}}}}]}", .text = "exactly one of" },
        .{ .json = "{\"listeners\": [{\"port\": 0, \"tcp\": {}}]}", .text = "MissingField" },
        .{ .json = "{\"listeners\": [{\"port\": 0, \"tcp\": {\"handler\": 1, \"framing\": {\"length\": {\"bytes\": 3}}}}]}", .text = "1, 2 or 4" },
    };
    for (bad) |b| {
        var w: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), b.json, &w));
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), b.text) != null);
    }
}

test "capi net: parity, the net options have a C ABI key with the same default" {
    comptime parity.checkCoverage(anole.net.Tcp.Options, &parity.net_tcp);
    comptime parity.checkCoverage(anole.net.Udp.Options, &parity.net_udp);
    const text = @import("anole_capi_schema").text;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{});
    try parity.checkSchemaAndDefaults(anole.net.Tcp.Options, config.Config, &parity.net_tcp, root);
    try parity.checkSchemaAndDefaults(anole.net.Udp.Options, config.Config, &parity.net_udp, root);
}

// Audit row lane11 net_test.zig:523 (Q3, W5), recorded as infra: this fuzz
// reaches std.Io.net.IpAddress only, not the abi.NetAddr conversion in
// anole_net_addr_parse/format (lib.zig), which lives inside the export
// bodies of the library root and is not importable here. Fuzzing the glue
// needs that conversion moved into a function the tests can call (a product
// refactor), so the test stays as it is until then.
fn addrFuzz(input: []const u8) anyerror!void {
    // What anole_net_addr_parse accepts, formats and parses back to itself.
    const ip = std.Io.net.IpAddress.parseLiteral(input) catch return;
    var buf: [96]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ip.format(&w) catch return;
    const again = std.Io.net.IpAddress.parseLiteral(w.buffered()) catch return error.RoundTripFailed;
    try std.testing.expect(std.meta.eql(ip, again));
}

test "fuzz: net addr parse" {
    const fuzz = @import("../fuzz.zig");
    try fuzz.bytes(addrFuzz, &.{ "10.0.0.1:53", "[::1]:53", "[2001:db8::1]:443", "127.0.0.1", "[::ffff:1.2.3.4]:80", "1.2.3.4:99999", "[fe80::1%eth0]:1", "" });
}

test "capi net: writes refused after F_END free their chunks after the slot lock (L5)" {
    if (comptime !features.net) return error.SkipZigTest;
    const rig = try Rig.create(tcp_length);
    defer rig.destroy();
    const s = try rig.client();
    defer s.close();
    const h = try openFramed(rig, s);
    _ = try engine.net.write(rig.e, h, "", abi.NET_F_END);
    // Copied, borrowed and framed: each made its chunk before the lock and
    // gets it back refused; the chunk allocator panics at a free under it.
    for ([_]u32{ 0, abi.BODY_BORROW, abi.NET_F_FRAME }) |f| {
        try std.testing.expectError(error.Invalid, engine.net.write(rig.e, h, "late", f));
        try std.testing.expectEqualStrings("Ended", engine.net.invalid_token);
    }
}
