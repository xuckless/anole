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
