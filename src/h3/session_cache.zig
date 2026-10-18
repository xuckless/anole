//! Session tickets for `ClientConnection`, kept by server: the TLS session
//! a ticket resumes, and the transport parameters the server had, which
//! QUIC needs to send 0-RTT (RFC 9000 §7.4.1). A connection takes the
//! newest ticket for its server and drops it (tickets are single-use, RFC
//! 8446 §C.4); the server sends fresh ones on every connection.
//!
//!     var cache: anole.h3.SessionCache = .init(gpa, io);
//!     defer cache.deinit();
//!     const conn = try anole.h3.ClientConnection.connect(gpa, io, .{
//!         .host = "example.com", .port = 443,
//!         .session_cache = &cache, .early_data = true,
//!     });
//!
//! One cache may serve any number of connections at once, on any
//! executor. Tickets are filed by host, port and the connection's TLS
//! settings (its CAs, whether it verifies, its client certificate), so a
//! connection never resumes a session that was set up under other ones.
const std = @import("std");
const c = @import("ngtcp2.zig").c;

pub const SessionCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Servers remembered at most; tickets for more are not kept.
    max_entries: u32 = 256,

    pub const Entry = struct {
        session: *c.SSL_SESSION,
        /// `ngtcp2_conn_encode_0rtt_transport_params2`'s output.
        params: []u8,

        pub fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
            c.SSL_SESSION_free(e.session);
            gpa.free(e.params);
            e.* = undefined;
        }
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) SessionCache {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *SessionCache) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many servers have a ticket here.
    pub fn count(self: *SessionCache) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.entries.count();
    }

    /// The ticket for `key`, taken out: the caller owns it.
    pub fn take(self: *SessionCache, key: []const u8) ?Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const kv = self.entries.fetchRemove(key) orelse return null;
        self.gpa.free(kv.key);
        return kv.value;
    }

    /// Files `session` (whose reference the cache takes on success) and a
    /// copy of `params` under `key`, in place of any ticket there.
    pub fn put(self: *SessionCache, key: []const u8, session: *c.SSL_SESSION, params: []const u8) !void {
        const copy = try self.gpa.dupe(u8, params);
        errdefer self.gpa.free(copy);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const gop = try self.entries.getOrPut(self.gpa, key);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.gpa);
        } else {
            if (self.entries.count() > self.max_entries) {
                _ = self.entries.remove(key);
                return error.CacheFull;
            }
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                _ = self.entries.remove(key);
                return err;
            };
        }
        gop.value_ptr.* = .{ .session = session, .params = copy };
    }
};

test "session cache: one ticket per server, taken once, newest kept, bounded" {
    const gpa = std.testing.allocator;
    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse return error.OutOfMemory;
    defer c.SSL_CTX_free(ctx);
    var cache: SessionCache = .init(gpa, std.testing.io);
    defer cache.deinit();
    cache.max_entries = 2;

    const first = c.SSL_SESSION_new(ctx) orelse return error.OutOfMemory;
    try cache.put("a|443|0", first, "params 1");
    const second = c.SSL_SESSION_new(ctx) orelse return error.OutOfMemory;
    try cache.put("a|443|0", second, "params 2");
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    var got = cache.take("a|443|0").?;
    defer got.deinit(gpa);
    try std.testing.expectEqual(second, got.session);
    try std.testing.expectEqualStrings("params 2", got.params);
    try std.testing.expect(cache.take("a|443|0") == null);

    for ([_][]const u8{ "b", "c", "d" }, 0..) |key, i| {
        const s = c.SSL_SESSION_new(ctx) orelse return error.OutOfMemory;
        cache.put(key, s, "p") catch |err| {
            try std.testing.expectEqual(error.CacheFull, err);
            try std.testing.expectEqual(@as(usize, 2), i);
            c.SSL_SESSION_free(s);
        };
    }
    try std.testing.expectEqual(@as(usize, 2), cache.count());
}
