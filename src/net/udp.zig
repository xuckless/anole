//! UDP sockets on `std.Io`: `Udp` (control messages for ECN, the local
//! address of a wildcard socket, segmentation offload, batched receives and
//! sends), SO_REUSEPORT groups and the probe that keeps a second server off
//! a port in use. Shared by the HTTP/3 endpoint (src/h3) and raw UDP
//! listeners (`anole.net`); moved here from src/h3/net.zig.
const std = @import("std");

/// A UDP socket with SO_REUSEPORT, bound to `address`: one of a group that
/// share it (`steer`). Blocking; whoever adopts it makes it otherwise.
/// `ipv6_only` sets IPV6_V6ONLY on an IPv6 address (false: dual-stack).
pub fn bindReusePort(address: std.Io.net.IpAddress, ipv6_only: ?bool) !std.posix.fd_t {
    if (comptime @import("builtin").os.tag == .windows) return error.ReusePortFailed;
    const posix = std.posix;
    const family: c_int = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fd = std.c.socket(@intCast(family), posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    const one: c_int = 1;
    if (std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &one, @sizeOf(c_int)) != 0) return error.ReusePortFailed;
    try setIpv6Only(fd, address, ipv6_only);
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&address, &storage);
    if (std.c.bind(fd, &storage.any, len) != 0) return switch (std.posix.errno(@as(c_int, -1))) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .ACCES => error.AccessDenied,
        else => error.BindFailed,
    };
    return fd;
}

/// Fails with `error.AddressInUse` when some other UDP socket is bound to
/// `address`, which binding with SO_REUSEPORT (`bindReusePort`) would
/// otherwise join without a word, sharing the port's datagrams with a
/// second copy of the server. As the core's `checkAddressFree` for TCP; the
/// probe sets no option at all, since UDP has no TIME_WAIT to tolerate and
/// a probe with SO_REUSEADDR would join sockets that set it too. Port zero
/// is not checked, and nothing is when the probe cannot be had.
pub fn checkUdpAddressFree(address: std.Io.net.IpAddress, ipv6_only: ?bool) error{AddressInUse}!void {
    // Windows has no SO_REUSEPORT group to join: one socket, whose own
    // bind fails on a port in use.
    if (comptime @import("builtin").os.tag == .windows) return;
    if (address.getPort() == 0) return;
    const posix = std.posix;
    const family: c_int = switch (address) {
        .ip4 => posix.AF.INET,
        .ip6 => posix.AF.INET6,
    };
    const fd = std.c.socket(@intCast(family), posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    // The probe covers what the real socket will: both families for a
    // dual-stack one.
    setIpv6Only(fd, address, ipv6_only) catch return;
    var storage: std.Io.Threaded.PosixAddress = undefined;
    const len = std.Io.Threaded.addressToPosix(&address, &storage);
    if (std.c.bind(fd, &storage.any, len) != 0 and std.posix.errno(@as(c_int, -1)) == .ADDRINUSE) {
        const fmt = "UDP {f} is already in use: another process is bound to it";
        // Tests provoke it on purpose: logged there, even at warn, the build
        // runner prints the test's output under "failed command".
        if (!@import("builtin").is_test) log.err(fmt, .{address});
        return error.AddressInUse;
    }
}

/// Whether `address` is IPv4-mapped IPv6 (`::ffff:a.b.c.d`): how a
/// dual-stack socket names an IPv4 peer.
pub fn isIpv4Mapped(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => false,
        .ip6 => |a| std.mem.eql(u8, a.bytes[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }),
    };
}

/// IPV6_V6ONLY on `fd` as `ipv6_only` says, when `address` is IPv6.
fn setIpv6Only(fd: std.posix.fd_t, address: std.Io.net.IpAddress, ipv6_only: ?bool) error{Ipv6OnlyFailed}!void {
    const v6only = ipv6_only orelse return;
    if (address != .ip6) return;
    const value: c_int = @intFromBool(v6only);
    if (std.c.setsockopt(fd, std.posix.IPPROTO.IPV6, std.posix.IPV6.V6ONLY, &value, @sizeOf(c_int)) != 0) return error.Ipv6OnlyFailed;
}

/// A UDP socket set up for QUIC, after ngtcp2's examples/shared.cc and
/// server.cc (MIT): ECN codepoints in and out, the local address of each
/// datagram when bound to a wildcard address (PKTINFO, so replies leave
/// from the address the peer wrote to), don't-fragment so path MTU
/// discovery measures the real path, and on Linux segmentation offload
/// both ways (GSO, GRO). Every option is best-effort: without it QUIC still
/// works, just with less information. On Windows (a development target)
/// none is set and no control messages pass: no ECN, and replies leave a
/// wildcard socket from the address the system picks.
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

    /// Whether datagrams carry control messages (ECN, PKTINFO, GSO/GRO):
    /// not on Windows.
    pub const has_control = native_os != .windows;

    /// Room for the control messages either way.
    pub const control_len = 128;
    pub const Control = [control_len]u8;

    /// What `init` sets up; each option is best-effort.
    pub const Options = struct {
        /// ECN codepoints in (IP_RECVTOS / IPV6_RECVTCLASS).
        ecn: bool = true,
        /// Linux: receive offload (UDP_GRO).
        gro: bool = true,
        /// Linux: send offload (UDP_SEGMENT).
        gso: bool = true,
        /// Don't fragment, and probe the path MTU (Linux:
        /// IP_PMTUDISC_PROBE; elsewhere DONTFRAG).
        pmtu_probe: bool = true,
        /// Linux: the kernel's count of datagrams it dropped for want of
        /// receive buffer arrives with each datagram (SO_RXQ_OVFL), as
        /// `Datagram.dropped`.
        rxq_ovfl: bool = false,
    };

    /// HTTP/3 takes `.{}`: everything on.
    pub fn init(socket: std.Io.net.Socket, options: Options) Udp {
        const ip6 = socket.address == .ip6;
        const wildcard = switch (socket.address) {
            .ip4 => |a| std.mem.eql(u8, &a.bytes, &.{ 0, 0, 0, 0 }),
            .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
        };
        var self: Udp = .{ .socket = socket, .ip6 = ip6, .wildcard = wildcard };
        if (comptime !has_control) return self;
        const fd = socket.handle;
        if (ip6) {
            if (options.ecn) _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.RECVTCLASS, 1);
            if (wildcard) _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.RECVPKTINFO, 1);
            // A dual-stack socket's IPv4 datagrams carry their TOS byte as
            // IP_TOS, asked for at the IPv4 level (Linux); their local
            // address comes as an IPv4-mapped IPV6_PKTINFO.
            if (options.ecn and native_os == .linux and !ipv6Only(fd)) _ = setOption(fd, posix.IPPROTO.IP, posix.IP.RECVTOS, 1);
        } else {
            if (options.ecn) _ = setOption(fd, posix.IPPROTO.IP, posix.IP.RECVTOS, 1);
            if (wildcard) _ = setOption(fd, posix.IPPROTO.IP, posix.IP.PKTINFO, 1);
        }
        if (native_os == .linux) {
            if (options.rxq_ovfl) _ = setOption(fd, posix.SOL.SOCKET, posix.SO.RXQ_OVFL, 1);
            // DF set, and the kernel's path MTU cache ignored: ngtcp2 probes.
            if (options.pmtu_probe) {
                if (ip6)
                    _ = setOption(fd, posix.IPPROTO.IPV6, linux.IPV6.MTU_DISCOVER, linux.IPV6.PMTUDISC_PROBE)
                else
                    _ = setOption(fd, posix.IPPROTO.IP, linux.IP.MTU_DISCOVER, linux.IP.PMTUDISC_PROBE);
            }
            if (options.gro) self.gro = setOption(fd, posix.IPPROTO.UDP, linux.UDP.GRO, 1);
            if (options.gso) self.gso.store(true, .monotonic);
        } else if (options.pmtu_probe) {
            if (ip6)
                _ = setOption(fd, posix.IPPROTO.IPV6, posix.IPV6.DONTFRAG, 1)
            else
                _ = setOption(fd, posix.IPPROTO.IP, posix.IP.DONTFRAG, 1);
        }
        return self;
    }

    /// Whether an IPv6 socket takes IPv6 alone (IPV6_V6ONLY).
    fn ipv6Only(fd: posix.socket_t) bool {
        var value: c_int = 1;
        var len: posix.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, @ptrCast(&value), &len) != 0) return true;
        return value != 0;
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
        /// With `Options.rxq_ovfl` (Linux): the kernel's running count of
        /// datagrams dropped on this socket, as of this one.
        dropped: u32 = 0,

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
        if (comptime has_control) msg.control = control;
        const err, const count = self.socket.receiveManyTimeout(io, (&msg)[0..1], buf, .{}, timeout);
        if (err) |e| return e;
        std.debug.assert(count == 1);
        return self.datagramOf(&msg);
    }

    /// Room for `Batch.len` datagrams of the largest size (a GRO batch is
    /// up to 64 KiB): what a receive buffer for `receiveBatch` needs, so
    /// that no datagram is ever cut short.
    pub const batch_buffer_len = Batch.len * 65535;

    /// Several datagrams in one wait: what the kernel already holds, up to
    /// `len`, in one `recvmmsg` on Linux (each with its control messages:
    /// ECN, PKTINFO, the GRO segment size), one non-blocking `recvmsg` each
    /// elsewhere. The task yields once for them all, so whatever they ask
    /// of a connection goes out in one flush rather than one per datagram.
    pub const Batch = struct {
        pub const len = 32;
        msgs: [len]std.Io.net.IncomingMessage = @splat(.init),
        controls: [len]Control align(cmsg_align) = undefined,
        count: usize = 0,

        pub fn datagram(b: *Batch, udp: *const Udp, i: usize) Datagram {
            return udp.datagramOf(&b.msgs[i]);
        }
    };

    /// Fills `batch` with at least one datagram; `buf` is
    /// `batch_buffer_len` bytes or more. Returns how many came.
    pub fn receiveBatch(self: *const Udp, io: std.Io, buf: []u8, batch: *Batch, timeout: std.Io.Timeout) ReceiveError!usize {
        std.debug.assert(buf.len >= batch_buffer_len);
        for (&batch.msgs, &batch.controls) |*m, *ctl| {
            m.* = .init;
            if (comptime has_control) m.control = ctl;
        }
        const err, const count = self.socket.receiveManyTimeout(io, &batch.msgs, buf, .{}, timeout);
        batch.count = count;
        // What came before a failure is handled; the failure, if it lasts,
        // comes back on the next call.
        if (count > 0) return count;
        return err orelse error.Unexpected;
    }

    /// Receives into `msgs` (up to its length datagrams, in one `recvmmsg`
    /// on Linux) with `controls[i]` as each one's control buffer; `buf` is
    /// divided evenly among the messages, so a datagram larger than its
    /// share comes back with the `trunc` flag. At least one datagram, or an
    /// error. For raw UDP listeners, whose batch is not HTTP/3's.
    pub fn receiveInto(self: *const Udp, io: std.Io, msgs: []std.Io.net.IncomingMessage, controls: []align(cmsg_align) Control, buf: []u8, timeout: std.Io.Timeout) ReceiveError!usize {
        std.debug.assert(msgs.len == controls.len);
        for (msgs, controls) |*m, *ctl| {
            m.* = .init;
            if (comptime has_control) m.control = ctl;
        }
        const err, const count = self.socket.receiveManyTimeout(io, msgs, buf, .{}, timeout);
        if (count > 0) return count;
        return err orelse error.Unexpected;
    }

    /// A received message as a `Datagram`.
    pub fn datagramFrom(self: *const Udp, msg: *const std.Io.net.IncomingMessage) Datagram {
        return self.datagramOf(msg);
    }

    fn datagramOf(self: *const Udp, msg: *const std.Io.net.IncomingMessage) Datagram {
        var d: Datagram = .{ .from = msg.from, .local = null, .ecn = 0, .data = msg.data, .segment = msg.data.len };
        if (comptime !has_control) return d;
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
            } else if (native_os == .linux and level == posix.SOL.SOCKET and kind == posix.SO.RXQ_OVFL and m.data.len >= @sizeOf(u32)) {
                d.dropped = std.mem.readInt(u32, m.data[0..@sizeOf(u32)], native_endian);
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
        const w = self.controlFor(&control, to, local, ecn, data.len, seg);
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

    /// The control messages a datagram of `len` bytes (several of
    /// `segment` each, with GSO, when longer) to `to` goes out with: its
    /// source address on a wildcard socket, its ECN codepoint, the segment
    /// size. Returns the bytes used.
    ///
    /// An IPv4 peer of a dual-stack socket has an IPv4-mapped address:
    /// Linux sends to it through its IPv4 path, which takes the source as
    /// a mapped IPV6_PKTINFO and the ECN codepoint as IP_TOS (not
    /// IPV6_TCLASS). Other systems get neither for such a peer, and pick
    /// the source themselves (ngtcp2 then finds ECN does not get through
    /// and stops marking).
    fn controlFor(self: *const Udp, control: *align(cmsg_align) Control, to: std.Io.net.IpAddress, local: ?std.Io.net.IpAddress, ecn: u8, len: usize, segment: usize) usize {
        if (comptime !has_control) return 0;
        var w: usize = 0;
        const mapped = self.ip6 and isIpv4Mapped(to);
        if (mapped and native_os != .linux) return 0;
        if (self.wildcard) if (local) |l| switch (l) {
            .ip4 => |a| {
                var pi = std.mem.zeroes(std.c.in_pktinfo);
                pi.spec_dst = std.mem.bytesToValue(u32, &a.bytes);
                w += put(control[w..], posix.IPPROTO.IP, posix.IP.PKTINFO, std.mem.asBytes(&pi));
            },
            // Linux refuses a mapped peer's source unless it is mapped too.
            .ip6 => |a| if (!mapped or isIpv4Mapped(l)) {
                var pi = std.mem.zeroes(std.c.in6_pktinfo);
                pi.addr = a.bytes;
                w += put(control[w..], posix.IPPROTO.IPV6, posix.IPV6.PKTINFO, std.mem.asBytes(&pi));
            },
        };
        const tos: c_int = ecn;
        if (self.ip6 and !mapped)
            w += put(control[w..], posix.IPPROTO.IPV6, posix.IPV6.TCLASS, std.mem.asBytes(&tos))
        else
            w += put(control[w..], posix.IPPROTO.IP, posix.IP.TOS, std.mem.asBytes(&tos));
        if (native_os == .linux and len > segment) {
            const size: u16 = @intCast(segment);
            w += put(control[w..], posix.IPPROTO.UDP, linux.UDP.SEGMENT, std.mem.asBytes(&size));
        }
        return w;
    }

    /// Packets written by several connections, to go out together: one
    /// `sendmmsg` for all of them on Linux (`send`), each connection's run
    /// of packets one GSO message within it. A connection writes its
    /// packets straight into `space` and `commit`s them.
    pub const Outbox = struct {
        buf: []u8,
        len: usize = 0,
        msgs: []std.Io.net.OutgoingMessage,
        /// Where each message goes; `msgs[i].address` points here.
        addrs: []std.Io.net.IpAddress,
        /// Each message's source address and ECN codepoint, for when it
        /// must go again without GSO.
        locals: []?std.Io.net.IpAddress,
        ecns: []u8,
        controls: []align(cmsg_align) Control,
        count: usize = 0,
        /// Datagrams in all the messages.
        datagrams: usize = 0,

        pub const buf_len = 128 * 1024;
        pub const max_msgs = 128;

        pub fn init(gpa: std.mem.Allocator) !Outbox {
            const buf = try gpa.alloc(u8, buf_len);
            errdefer gpa.free(buf);
            const msgs = try gpa.alloc(std.Io.net.OutgoingMessage, max_msgs);
            errdefer gpa.free(msgs);
            const addrs = try gpa.alloc(std.Io.net.IpAddress, max_msgs);
            errdefer gpa.free(addrs);
            const locals = try gpa.alloc(?std.Io.net.IpAddress, max_msgs);
            errdefer gpa.free(locals);
            const ecns = try gpa.alloc(u8, max_msgs);
            errdefer gpa.free(ecns);
            const controls = try gpa.alignedAlloc(Control, .fromByteUnits(cmsg_align), max_msgs);
            return .{ .buf = buf, .msgs = msgs, .addrs = addrs, .locals = locals, .ecns = ecns, .controls = controls };
        }

        pub fn deinit(o: *Outbox, gpa: std.mem.Allocator) void {
            gpa.free(o.buf);
            gpa.free(o.msgs);
            gpa.free(o.addrs);
            gpa.free(o.locals);
            gpa.free(o.ecns);
            gpa.free(o.controls);
        }

        /// Room for `bytes` more, in up to `datagrams` messages.
        pub fn fits(o: *const Outbox, bytes: usize, datagrams: usize) bool {
            return o.buf.len - o.len >= bytes and o.msgs.len - o.count >= datagrams;
        }

        /// Where the next packets are written.
        pub fn space(o: *Outbox) []u8 {
            return o.buf[o.len..];
        }

        /// The first `n` bytes of `space`, written: one datagram, or with
        /// `segment` less than `n` several of `segment` bytes (the last
        /// may be shorter), to `to` from `local`. One GSO message where
        /// the socket has GSO, one message each otherwise; `fits` must
        /// have said there is room for that many.
        pub fn commit(o: *Outbox, udp: *const Udp, to: std.Io.net.IpAddress, local: ?std.Io.net.IpAddress, ecn: u8, n: usize, segment: usize) void {
            const seg = if (segment == 0 or segment > n) n else segment;
            const gso = native_os == .linux and udp.gso.load(.monotonic);
            var at = o.len;
            const end = o.len + n;
            while (at < end) {
                const len = if (gso) end - at else @min(seg, end - at);
                const i = o.count;
                o.addrs[i] = to;
                o.locals[i] = local;
                o.ecns[i] = ecn;
                const w = udp.controlFor(&o.controls[i], to, local, ecn, len, seg);
                o.msgs[i] = .{ .address = &o.addrs[i], .data_ptr = o.buf[at..].ptr, .data_len = len, .control = o.controls[i][0..w] };
                o.count += 1;
                o.datagrams += std.math.divCeil(usize, len, seg) catch unreachable;
                at += len;
            }
            o.len = end;
        }

        pub fn clear(o: *Outbox) void {
            o.len = 0;
            o.count = 0;
            o.datagrams = 0;
        }
    };

    /// Sends what `outbox` holds and empties it. A message the kernel
    /// refuses is dropped (QUIC takes it as lost), unless it was refused
    /// for its GSO segments: then GSO goes off and its datagrams go one by
    /// one.
    pub fn sendOutbox(self: *Udp, io: std.Io, outbox: *Outbox) void {
        defer outbox.clear();
        var rest = outbox.msgs[0..outbox.count];
        while (rest.len > 0) {
            const err, const sent = self.socket.sendManyTimeout(io, rest, .{}, .none);
            rest = rest[sent..];
            const e = err orelse continue;
            if (e == error.Canceled) return io.recancel();
            if (rest.len == 0) break;
            const i = outbox.count - rest.len;
            const failed = rest[0];
            rest = rest[1..];
            const seg = segmentOf(failed.control);
            if (seg != 0 and failed.data_len > seg) {
                log.debug("UDP GSO off: {t}", .{e});
                self.gso.store(false, .monotonic);
                self.send(io, failed.address.*, outbox.locals[i], outbox.ecns[i], failed.data_ptr[0..failed.data_len], seg);
                continue;
            }
            log.debug("UDP send: {t}", .{e});
        }
    }

    /// The UDP_SEGMENT size among a message's control messages; 0 for none.
    fn segmentOf(control: []const u8) usize {
        if (comptime native_os != .linux) return 0;
        if (control.len == 0) return 0;
        var it: cmsg.Iterator = .{ .control = @alignCast(@constCast(control)) };
        while (it.next()) |m| if (m.header.level == posix.IPPROTO.UDP and m.header.type == linux.UDP.SEGMENT and m.data.len >= 2)
            return std.mem.readInt(u16, m.data[0..2], native_endian);
        return 0;
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
// HTTP/3's scope, as before the move; p3/net may give raw listeners their own.
const log = std.log.scoped(.anole_h3);

test "UDP: a send that a cancelation interrupts leaves it for the next cancelation point" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var sink: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer sink.socket.close(io);
    var udp: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
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
    if (comptime !Udp.has_control) return error.SkipZigTest; // no control messages on Windows
    const zio = @import("zio");
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    const any: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    var server: Udp = .init(try any.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer server.socket.close(io);
    try std.testing.expect(server.wildcard);
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var client: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
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

test "UDP: SO_REUSEPORT sockets share a port, and the probe sees any socket on it" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest; // no SO_REUSEPORT on Windows
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const first = try bindReusePort(lo, null);
    var first_open = true;
    defer if (first_open) {
        _ = std.c.close(first);
    };
    var storage: std.Io.Threaded.PosixAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockname(first, &storage.any, &len));
    const taken = std.Io.Threaded.addressFromPosix(&storage);
    // The probe refuses the port, SO_REUSEPORT or not.
    try std.testing.expectError(error.AddressInUse, checkUdpAddressFree(taken, null));
    // A second member of the group binds all the same.
    const second = try bindReusePort(taken, null);
    _ = std.c.close(second);
    // Free again once both are closed; port zero is never checked.
    _ = std.c.close(first);
    first_open = false;
    try checkUdpAddressFree(taken, null);
    try checkUdpAddressFree(lo, null);
}

test "UDP: an outbox sends several destinations' packets at once, a run of them as one GSO message" {
    const zio = @import("zio");
    const rt = try zio.Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();
    const io = rt.io();
    const lo: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var a: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer a.socket.close(io);
    var b: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer b.socket.close(io);
    var sender: Udp = .init(try lo.bind(io, .{ .mode = .dgram, .protocol = .udp }), .{});
    defer sender.socket.close(io);

    var outbox: Udp.Outbox = try .init(std.testing.allocator);
    defer outbox.deinit(std.testing.allocator);
    try std.testing.expect(outbox.fits(10, 3));
    // Three datagrams of 4, 4 and 2 bytes for `a`, one for `b`.
    @memcpy(outbox.space()[0..10], "aaaabbbbcc");
    outbox.commit(&sender, a.socket.address, null, 2, 10, 4);
    @memcpy(outbox.space()[0..4], "dddd");
    outbox.commit(&sender, b.socket.address, null, 1, 4, 0);
    try std.testing.expectEqual(@as(usize, 4), outbox.datagrams);
    const gso = @import("builtin").os.tag == .linux and sender.gso.load(.monotonic);
    try std.testing.expectEqual(@as(usize, if (gso) 2 else 4), outbox.count);
    sender.sendOutbox(io, &outbox);
    try std.testing.expectEqual(@as(usize, 0), outbox.count);
    try std.testing.expect(outbox.fits(Udp.Outbox.buf_len, Udp.Outbox.max_msgs));

    var buf: [2048]u8 = undefined;
    var control: Udp.Control align(cmsg_align) = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } };
    var got: usize = 0;
    while (got < 3) {
        var dg = try a.receive(io, &buf, &control, timeout);
        try std.testing.expectEqual(@as(u8, if (Udp.has_control) 2 else 0), dg.ecn);
        while (dg.next()) |d| {
            try std.testing.expectEqualStrings(([_][]const u8{ "aaaa", "bbbb", "cc" })[got], d);
            got += 1;
        }
    }
    const dg = try b.receive(io, &buf, &control, timeout);
    try std.testing.expectEqualStrings("dddd", dg.data);
    try std.testing.expectEqual(@as(u8, if (Udp.has_control) 1 else 0), dg.ecn);
}
