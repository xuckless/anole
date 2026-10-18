//! What the HTTP/3 server and client share: socket addresses as ngtcp2
//! takes them, connection IDs as map keys, and the clocks.
const std = @import("std");
const c = @import("ngtcp2.zig").c;

/// A socket address as ngtcp2 takes it.
pub const Addr = struct {
    storage: std.Io.Threaded.PosixAddress = undefined,
    len: std.posix.socklen_t = 0,

    pub fn from(address: std.Io.net.IpAddress) Addr {
        var a: Addr = .{};
        a.len = std.Io.Threaded.addressToPosix(&address, &a.storage);
        return a;
    }

    pub fn fromNgtcp2(addr: c.ngtcp2_addr) Addr {
        var a: Addr = .{};
        const len: usize = @intCast(addr.addrlen);
        @memcpy(std.mem.asBytes(&a.storage)[0..len], @as([*]const u8, @ptrCast(addr.addr))[0..len]);
        a.len = @intCast(len);
        return a;
    }

    pub fn ip(self: *const Addr) std.Io.net.IpAddress {
        return std.Io.Threaded.addressFromPosix(&self.storage);
    }

    pub fn ngtcp2Addr(self: *Addr) c.ngtcp2_addr {
        return .{ .addr = @ptrCast(&self.storage), .addrlen = @intCast(self.len) };
    }
};

/// A connection ID as a map key.
pub const CidKey = struct {
    len: u8,
    bytes: [c.NGTCP2_MAX_CIDLEN]u8,

    pub fn of(data: []const u8) CidKey {
        var k: CidKey = .{ .len = @intCast(data.len), .bytes = @splat(0) };
        @memcpy(k.bytes[0..data.len], data);
        return k;
    }

    pub fn ofCid(cid: *const c.ngtcp2_cid) CidKey {
        return of(cid.data[0..cid.datalen]);
    }
};

/// For nghttp3's `rand` callback, which gets no user data: the `Io` the
/// last endpoint or client was made with.
pub var rand_io: ?std.Io = null;

pub fn h3Rand(dest: [*c]u8, len: usize) callconv(.c) void {
    (rand_io orelse unreachable).random(dest[0..len]);
}

/// ngtcp2's monotonic timestamps, in nanoseconds.
pub fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// Wall-clock nanoseconds, for address validation tokens.
pub fn wallClock(io: std.Io) u64 {
    return @intCast(std.Io.Clock.real.now(io).nanoseconds);
}

/// A UDP socket set up for QUIC, after ngtcp2's examples/shared.cc and
/// server.cc (MIT): ECN codepoints in and out, the local address of each
/// datagram when bound to a wildcard address (PKTINFO, so replies leave
/// from the address the peer wrote to), don't-fragment so path MTU
/// discovery measures the real path, and on Linux segmentation offload
/// both ways (GSO, GRO). Every option is best-effort: without it QUIC still
/// works, just with less information.
pub const Udp = struct {
    socket: std.Io.net.Socket,
    ip6: bool,
    /// Bound to 0.0.0.0 or ::: datagrams say where they arrived.
    wildcard: bool,
    /// Linux only; turned off for good if the kernel or NIC refuses it.
    gso: std.atomic.Value(bool) = .init(false),
    gro: bool = false,

    const posix = std.posix;
    const native_os = @import("builtin").os.tag;
    const linux = std.os.linux;
    const cmsg = std.Io.net.cmsg;

    /// Room for the control messages either way.
    pub const control_len = 128;
    pub const Control = [control_len]u8;

    pub fn init(socket: std.Io.net.Socket) Udp {
        const ip6 = socket.address == .ip6;
        const wildcard = switch (socket.address) {
            .ip4 => |a| std.mem.eql(u8, &a.bytes, &.{ 0, 0, 0, 0 }),
            .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
        };
        var self: Udp = .{ .socket = socket, .ip6 = ip6, .wildcard = wildcard };
        const fd = socket.handle;
        if (ip6) {
            _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.RECVTCLASS, 1);
            if (wildcard) _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.RECVPKTINFO, 1);
        } else {
            _ = setOption(fd, posix.IPPROTO.IP, posix.IP.RECVTOS, 1);
            if (wildcard) _ = setOption(fd, posix.IPPROTO.IP, posix.IP.PKTINFO, 1);
        }
        if (native_os == .linux) {
            // DF set, and the kernel's path MTU cache ignored: ngtcp2 probes.
            if (ip6)
                _ = setOption(fd, posix.IPPROTO.IPV6, linux.IPV6.MTU_DISCOVER, linux.IPV6.PMTUDISC_PROBE)
            else
                _ = setOption(fd, posix.IPPROTO.IP, linux.IP.MTU_DISCOVER, linux.IP.PMTUDISC_PROBE);
            self.gro = setOption(fd, posix.IPPROTO.UDP, linux.UDP.GRO, 1);
            self.gso.store(true, .monotonic);
        } else {
            if (ip6)
                _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.DONTFRAG, 1)
            else
                _ = setOption(fd, posix.IPPROTO.IP, posix.IP.DONTFRAG, 1);
        }
        return self;
    }

    fn setOption(fd: posix.socket_t, level: i32, name: u32, value: c_int) bool {
        const ok = std.c.setsockopt(fd, level, name, &value, @sizeOf(c_int)) == 0;
        if (!ok) log.debug("setsockopt({d}, {d}) failed", .{ level, name });
        return ok;
    }

    pub const Datagram = struct {
        from: std.Io.net.IpAddress,
        /// The address it was sent to, when the socket is bound to a
        /// wildcard address (and the system said).
        local: ?std.Io.net.IpAddress,
        /// The ECN codepoint (the low two bits of TOS / traffic class).
        ecn: u8,
        /// One datagram, or with GRO several of `segment` bytes each (the
        /// last may be shorter).
        data: []u8,
        segment: usize,

        /// The datagrams one at a time.
        pub fn next(d: *Datagram) ?[]u8 {
            if (d.data.len == 0) return null;
            const n = @min(d.segment, d.data.len);
            defer d.data = d.data[n..];
            return d.data[0..n];
        }
    };

    pub const ReceiveError = std.Io.net.Socket.ReceiveTimeoutError;

    pub fn receive(self: *const Udp, io: std.Io, buf: []u8, control: *align(cmsg_align) Control, timeout: std.Io.Timeout) ReceiveError!Datagram {
        var msg: std.Io.net.IncomingMessage = .init;
        msg.control = control;
        const err, const count = self.socket.receiveManyTimeout(io, (&msg)[0..1], buf, .{}, timeout);
        if (err) |e| return e;
        std.debug.assert(count == 1);
        var d: Datagram = .{ .from = msg.from, .local = null, .ecn = 0, .data = msg.data, .segment = msg.data.len };
        var it: cmsg.Iterator = .{ .control = @alignCast(msg.control) };
        while (it.next()) |m| {
            const level = m.header.level;
            const kind = m.header.type;
            if (level == posix.IPPROTO.IP) {
                // macOS reports the TOS byte as IP_RECVTOS, Linux as IP_TOS.
                if ((kind == posix.IP.TOS or kind == posix.IP.RECVTOS) and m.data.len >= 1) {
                    d.ecn = m.data[0] & 0x3;
                } else if (kind == posix.IP.PKTINFO and m.data.len >= @sizeOf(std.c.in_pktinfo)) {
                    const pi = std.mem.bytesToValue(std.c.in_pktinfo, m.data[0..@sizeOf(std.c.in_pktinfo)]);
                    d.local = .{ .ip4 = .{ .bytes = std.mem.toBytes(pi.addr), .port = self.socket.address.getPort() } };
                }
            } else if (level == posix.IPPROTO.IPV6) {
                if (kind == posix.IPV6.TCLASS and m.data.len >= @sizeOf(c_int)) {
                    d.ecn = @intCast(std.mem.readInt(c_int, m.data[0..@sizeOf(c_int)], native_endian) & 0x3);
                } else if (kind == posix.IPV6.PKTINFO and m.data.len >= @sizeOf(std.c.in6_pktinfo)) {
                    const pi = std.mem.bytesToValue(std.c.in6_pktinfo, m.data[0..@sizeOf(std.c.in6_pktinfo)]);
                    d.local = .{ .ip6 = .{ .bytes = pi.addr, .port = self.socket.address.getPort() } };
                }
            } else if (native_os == .linux and level == posix.IPPROTO.UDP and kind == linux.UDP.GRO and m.data.len >= @sizeOf(c_int)) {
                const size = std.mem.readInt(c_int, m.data[0..@sizeOf(c_int)], native_endian);
                if (size > 0) d.segment = @intCast(size);
            }
        }
        return d;
    }

    /// Sends `data`: one datagram, or when `segment` is less than its
    /// length, datagrams of `segment` bytes (the last may be shorter) -- in
    /// one call with GSO, one call each otherwise. `local` (a wildcard
    /// socket's address for this path) picks the source address. Errors are
    /// dropped: QUIC treats an unsent packet as lost.
    pub fn send(self: *Udp, io: std.Io, to: std.Io.net.IpAddress, local: ?std.Io.net.IpAddress, ecn: u8, data: []const u8, segment: usize) void {
        const seg = if (segment == 0) data.len else segment;
        if (data.len > seg and !(native_os == .linux and self.gso.load(.monotonic))) {
            var rest = data;
            while (rest.len > 0) {
                const n = @min(seg, rest.len);
                self.send(io, to, local, ecn, rest[0..n], n);
                rest = rest[n..];
            }
            return;
        }
        var control: Control align(cmsg_align) = undefined;
        var w: usize = 0;
        if (self.wildcard) if (local) |l| switch (l) {
            .ip4 => |a| {
                var pi = std.mem.zeroes(std.c.in_pktinfo);
                pi.spec_dst = std.mem.bytesToValue(u32, &a.bytes);
                w += put(control[w..], posix.IPPROTO.IP, posix.IP.PKTINFO, std.mem.asBytes(&pi));
            },
            .ip6 => |a| {
                var pi = std.mem.zeroes(std.c.in6_pktinfo);
                pi.addr = a.bytes;
                w += put(control[w..], posix.IPPROTO.IPV6, posix.IPV6.PKTINFO, std.mem.asBytes(&pi));
            },
        };
        const tos: c_int = ecn;
        if (self.ip6)
            w += put(control[w..], posix.IPPROTO.IPV6, posix.IPV6.TCLASS, std.mem.asBytes(&tos))
        else
            w += put(control[w..], posix.IPPROTO.IP, posix.IP.TOS, std.mem.asBytes(&tos));
        if (native_os == .linux and data.len > seg) {
            const size: u16 = @intCast(seg);
            w += put(control[w..], posix.IPPROTO.UDP, linux.UDP.SEGMENT, std.mem.asBytes(&size));
        }
        var msg: std.Io.net.OutgoingMessage = .{ .address = &to, .data_ptr = data.ptr, .data_len = data.len, .control = control[0..w] };
        const err, _ = self.socket.sendManyTimeout(io, (&msg)[0..1], .{}, .none);
        if (err) |e| {
            // A datagram may be lost, the cancelation may not: callers go
            // on to a cancelation point (the endpoint's next receive) that
            // must see it, or a canceled task never ends.
            if (e == error.Canceled) return io.recancel();
            if (data.len > seg) {
                // The kernel or the NIC refused GSO: per datagram from now on.
                log.debug("UDP GSO off: {t}", .{e});
                self.gso.store(false, .monotonic);
                return self.send(io, to, local, ecn, data, seg);
            }
            log.debug("UDP send: {t}", .{e});
        }
    }

    /// Appends one control message; returns the bytes used.
    fn put(dest: []u8, level: i32, kind: i32, payload: []const u8) usize {
        const space = cmsg.space(payload.len);
        @memset(dest[0..space], 0);
        const header: *align(1) std.posix.cmsghdr = @ptrCast(dest.ptr);
        header.len = cmsg.len(@intCast(payload.len));
        header.level = level;
        header.type = kind;
        const offset = std.mem.alignForward(usize, @sizeOf(std.posix.cmsghdr), cmsg_align);
        @memcpy(dest[offset..][0..payload.len], payload);
        return space;
    }
};

const cmsg_align = std.Io.net.cmsg_align;
const native_endian = @import("builtin").cpu.arch.endian();
const log = std.log.scoped(.anole_h3);

test "UDP: a send that a cancelation interrupts leaves it for the next cancelation point" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var sink: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }));
    defer sink.socket.close(io);
    var udp: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }));
    defer udp.socket.close(io);
    const Task = struct {
        fn run(u: *Udp, to: std.Io.net.IpAddress, tio: std.Io) std.Io.Cancelable!void {
            // Protected until the cancelation has surely been asked for,
            // so that the send is the first point to see it.
            const protection = tio.swapCancelProtection(.blocked);
            tio.sleep(.fromMilliseconds(200), .awake) catch {};
            _ = tio.swapCancelProtection(protection);
            u.send(tio, to, null, 0, "ping", 4);
            // As the endpoint's receive loop: it must still see it.
            return tio.checkCancel();
        }
    };
    var future = try io.concurrent(Task.run, .{ &udp, sink.socket.address, io });
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

test "UDP: ECN codepoints and the local address of a wildcard socket come through" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    const any: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    var server: Udp = .init(try any.bind(io, .{ .mode = .dgram, .protocol = .udp }));
    defer server.socket.close(io);
    try std.testing.expect(server.wildcard);
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var client: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }));
    defer client.socket.close(io);
    try std.testing.expect(!client.wildcard);

    var to = lo;
    to.setPort(server.socket.address.getPort());
    var buf: [2048]u8 = undefined;
    var control: Udp.Control align(cmsg_align) = undefined;
    for ([_]u8{ 0, 1, 2, 3 }) |ecn| {
        client.send(io, to, null, ecn, "ping", 4);
        const dg = try server.receive(io, &buf, &control, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        try std.testing.expectEqualStrings("ping", dg.data);
        try std.testing.expectEqual(ecn, dg.ecn);
        try std.testing.expectEqual(dg.data.len, dg.segment);
        try std.testing.expect(dg.local != null);
        try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &dg.local.?.ip4.bytes);
        // The reply leaves from the address the client wrote to.
        server.send(io, dg.from, dg.local, ecn, "pong", 4);
        const back = try client.receive(io, &buf, &control, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        try std.testing.expectEqualStrings("pong", back.data);
        try std.testing.expectEqual(ecn, back.ecn);
        try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &back.from.ip4.bytes);
    }
    // Three datagrams in one call: GSO on Linux, one by one elsewhere.
    client.send(io, to, null, 2, "aaaabbbbcc", 4);
    var got: usize = 0;
    while (got < 3) {
        var dg = try server.receive(io, &buf, &control, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
        while (dg.next()) |d| {
            try std.testing.expectEqualStrings(([_][]const u8{ "aaaa", "bbbb", "cc" })[got], d);
            got += 1;
        }
    }
}
