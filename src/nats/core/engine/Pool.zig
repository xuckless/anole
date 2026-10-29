// Adapted from vkiryakov/zefir src/nats/engine/Pool.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The servers the client may connect to: those of the options, which
//! always stay, and those the cluster announces in the `connect_urls` of
//! its INFO, which go again once a later INFO no longer lists them. At most
//! `Options.max_servers` in all, each once: a host written two ways, such
//! as `[::1]` and `[0:0::1]`, is the same server. Connections go round the
//! pool, the next server after the one of the last attempt.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Options = @import("../Options.zig");
const ServerAddress = @import("../ServerAddress.zig");
const server_error = @import("../protocol/server_error.zig");
const safety = @import("anole_safety");
const log = std.log.scoped(.nats);
const Pool = @This();

pub const Entry = struct {
    address: ServerAddress,
    /// From the options: it stays whatever INFO says.
    explicit: bool,
    /// How the server refused the credentials the last time; null when the
    /// last attempt on it ended otherwise.
    refused: ?server_error.Refusal = null,
};

/// Guards everything below.
mutex: safety.Mutex(.leaf) = .init,
/// Room for `Options.max_servers` entries; the first `len` are the pool,
/// in the order connections try them.
entries: []Entry,
len: usize = 0,
/// The entry of the last attempt; null before the first.
current: ?usize = null,
/// Shuffle the servers, so that clients spread over a cluster.
randomize: bool,

/// A pool of `servers`, each once; shuffled with `randomize`.
pub fn init(gpa: Allocator, io: Io, servers: []const ServerAddress, randomize: bool) Allocator.Error!Pool {
    var pool: Pool = .{ .entries = try gpa.alloc(Entry, Options.max_servers), .randomize = randomize };
    for (servers) |address| {
        if (pool.find(&address) != null or pool.len == pool.entries.len) continue;
        pool.entries[pool.len] = .{ .address = address, .explicit = true };
        pool.len += 1;
    }
    if (randomize) pool.shuffle(io);
    return pool;
}

pub fn deinit(pool: *Pool, gpa: Allocator) void {
    gpa.free(pool.entries);
    pool.* = undefined;
}

/// The server to try next: the one after the server of the last attempt.
pub fn next(pool: *Pool, io: Io) ServerAddress {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    const index = if (pool.current) |c| (c + 1) % pool.len else 0;
    pool.current = index;
    return pool.entries[index].address;
}

/// The server of the last attempt; null before the first.
pub fn currentServer(pool: *Pool, io: Io) ?ServerAddress {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    const index = pool.current orelse return null;
    return pool.entries[index].address;
}

/// The attempt on the server of the last attempt ended: refused the way
/// `refused` says, or otherwise (null). True when the server refused the
/// credentials the same way the time before too.
pub fn noteAttempt(pool: *Pool, io: Io, refused: ?server_error.Refusal) bool {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    const index = pool.current orelse return false;
    const entry = &pool.entries[index];
    const again = refused != null and entry.refused == refused;
    entry.refused = refused;
    return again;
}

/// How many servers the pool holds.
pub fn count(pool: *Pool, io: Io) usize {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    return pool.len;
}

/// Takes the `connect_urls` of an INFO: servers it names for the first
/// time join the pool, as long as there is room, and discovered servers it
/// no longer names leave, but the current one. An empty list changes
/// nothing: a server outside a cluster sends none. `sink` hears of each
/// change: `sink.discovered(address)` and `sink.removed(address)`.
pub fn update(pool: *Pool, io: Io, urls: []const []const u8, sink: anytype) void {
    if (urls.len == 0) return;
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);

    // Discovered servers no longer named go, in order.
    var index: usize = 0;
    while (index < pool.len) {
        const entry = pool.entries[index];
        if (entry.explicit or pool.current == index or named(urls, &entry.address)) {
            index += 1;
            continue;
        }
        std.mem.copyForwards(Entry, pool.entries[index .. pool.len - 1], pool.entries[index + 1 .. pool.len]);
        pool.len -= 1;
        if (pool.current) |c| {
            if (c > index) pool.current = c - 1;
        }
        sink.removed(entry.address);
    }

    var added = false;
    for (urls) |url| {
        const address = ServerAddress.parse(url) catch {
            log.debug("ignoring a server the cluster announced that is no address: {f}", .{server_error.printable(url)});
            continue;
        };
        if (pool.find(&address) != null) continue;
        if (pool.len == pool.entries.len) {
            log.debug("the pool holds {d} servers: {f} not added", .{ pool.len, address });
            continue;
        }
        pool.entries[pool.len] = .{ .address = address, .explicit = false };
        pool.len += 1;
        added = true;
        sink.discovered(address);
    }
    if (added and pool.randomize) {
        const current = if (pool.current) |c| pool.entries[c].address else null;
        pool.shuffle(io);
        if (current) |address| pool.current = pool.find(&address);
    }
}

/// Copies the servers the cluster announced into `buffer`, as many as fit.
pub fn discovered(pool: *Pool, io: Io, buffer: []ServerAddress) []ServerAddress {
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    var filled: usize = 0;
    for (pool.entries[0..pool.len]) |entry| {
        if (entry.explicit) continue;
        if (filled == buffer.len) break;
        buffer[filled] = entry.address;
        filled += 1;
    }
    return buffer[0..filled];
}

/// A sink that ignores the changes of `update`.
pub const ignore_changes: IgnoreChanges = .{};

pub const IgnoreChanges = struct {
    pub fn discovered(_: IgnoreChanges, _: ServerAddress) void {}
    pub fn removed(_: IgnoreChanges, _: ServerAddress) void {}
};

fn find(pool: *const Pool, address: *const ServerAddress) ?usize {
    for (pool.entries[0..pool.len], 0..) |*entry, index| {
        if (same(&entry.address, address)) return index;
    }
    return null;
}

fn named(urls: []const []const u8, address: *const ServerAddress) bool {
    for (urls) |url| {
        const other = ServerAddress.parse(url) catch continue;
        if (same(&other, address)) return true;
    }
    return false;
}

fn shuffle(pool: *Pool, io: Io) void {
    var source: std.Random.IoSource = .{ .io = io };
    source.interface().shuffle(Entry, pool.entries[0..pool.len]);
}

/// The same port and the same host: an IP address by its bytes, whichever
/// way it is written, a name without regard to case.
pub fn same(a: *const ServerAddress, b: *const ServerAddress) bool {
    if (a.port != b.port) return false;
    const x = a.host();
    const y = b.host();
    if (std.ascii.eqlIgnoreCase(x, y)) return true;
    if (Io.net.Ip4Address.parse(x, 0)) |ip_x| {
        const ip_y = Io.net.Ip4Address.parse(y, 0) catch return false;
        return std.mem.eql(u8, &ip_x.bytes, &ip_y.bytes);
    } else |_| {}
    const ip_x = switch (Io.net.Ip6Address.Unresolved.parse(x)) {
        .success => |ip| ip,
        else => return false,
    };
    const ip_y = switch (Io.net.Ip6Address.Unresolved.parse(y)) {
        .success => |ip| ip,
        else => return false,
    };
    if (!std.mem.eql(u8, &ip_x.bytes, &ip_y.bytes)) return false;
    const zone_x = ip_x.interface_name orelse return ip_y.interface_name == null;
    const zone_y = ip_y.interface_name orelse return false;
    return std.mem.eql(u8, zone_x, zone_y);
}

const testing = std.testing;

fn parsed(text: []const u8) ServerAddress {
    return ServerAddress.parse(text) catch unreachable;
}

fn parsedAll(comptime texts: []const []const u8) [texts.len]ServerAddress {
    var result: [texts.len]ServerAddress = undefined;
    for (texts, &result) |text, *a| a.* = parsed(text);
    return result;
}

/// Records the changes of `update`, as `+host:port` and `-host:port`.
const Recorder = struct {
    text: std.ArrayList(u8) = .empty,

    fn discovered(r: *Recorder, a: ServerAddress) void {
        r.text.print(testing.allocator, "+{f} ", .{a}) catch unreachable;
    }

    fn removed(r: *Recorder, a: ServerAddress) void {
        r.text.print(testing.allocator, "-{f} ", .{a}) catch unreachable;
    }

    fn deinit(r: *Recorder) void {
        r.text.deinit(testing.allocator);
    }
};

/// The pool's servers in order, as `host:port` separated by spaces.
fn expectPool(pool: *Pool, expected: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (pool.entries[0..pool.len]) |entry| try text.print(testing.allocator, "{f}{s} ", .{ entry.address, if (entry.explicit) "" else "*" });
    try testing.expectEqualStrings(expected, text.items);
}

test "the same server written two ways is one server" {
    try testing.expect(same(&parsed("LOCALHOST:4222"), &parsed("localhost")));
    try testing.expect(same(&parsed("[::1]:4222"), &parsed("[0:0::1]:4222")));
    try testing.expect(same(&parsed("[0:0:0:0:0:0:0:1]"), &parsed("[::1]")));
    try testing.expect(same(&parsed("[fe80::1%en0]"), &parsed("[FE80:0::1%en0]")));
    try testing.expect(!same(&parsed("[fe80::1%en0]"), &parsed("[fe80::1%en1]")));
    try testing.expect(!same(&parsed("[fe80::1%en0]"), &parsed("[fe80::1]")));
    try testing.expect(!same(&parsed("127.0.0.1:4222"), &parsed("127.0.0.1:4223")));
    try testing.expect(!same(&parsed("127.0.0.1"), &parsed("[::ffff:127.0.0.1]")));
    try testing.expect(!same(&parsed("localhost"), &parsed("127.0.0.1")));
    try testing.expect(!same(&parsed("a.example"), &parsed("b.example")));
}

test "the servers of the options come in order, each once, and go round" {
    const io = testing.io;
    const servers = parsedAll(&.{ "a:1", "b:2", "A:1", "c:3" });
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    try expectPool(&pool, "a:1 b:2 c:3 ");
    try testing.expect(pool.currentServer(io) == null);
    for ([_][]const u8{ "a", "b", "c", "a", "b" }) |host| {
        try testing.expectEqualStrings(host, pool.next(io).host());
    }
    try testing.expectEqualStrings("b", pool.currentServer(io).?.host());
}

test "randomize_servers shuffles the servers, and every one stays" {
    const io = testing.io;
    var texts: [Options.max_servers][8]u8 = undefined;
    var servers: [Options.max_servers]ServerAddress = undefined;
    for (&servers, &texts, 0..) |*s, *t, i| s.* = parsed(try std.fmt.bufPrint(t, "h{d}", .{i}));
    var pool: Pool = try .init(testing.allocator, io, &servers, true);
    defer pool.deinit(testing.allocator);
    try testing.expectEqual(Options.max_servers, pool.len);
    var moved = false;
    for (servers, 0..) |s, i| {
        const at = pool.find(&s) orelse return error.TestServerLost;
        if (at != i) moved = true;
    }
    // 64 servers left in place by chance: 1 in 64!.
    try testing.expect(moved);
}

test "INFO adds the servers it names and removes the discovered ones it no longer names" {
    const io = testing.io;
    const servers = parsedAll(&.{"127.0.0.1:14226"});
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    var recorder: Recorder = .{};
    defer recorder.deinit();

    _ = pool.next(io);
    pool.update(io, &.{ "127.0.0.1:14226", "127.0.0.1:14227", "127.0.0.1:14228", "[::1]:14229" }, &recorder);
    try expectPool(&pool, "127.0.0.1:14226 127.0.0.1:14227* 127.0.0.1:14228* [::1]:14229* ");
    try testing.expectEqualStrings("+127.0.0.1:14227 +127.0.0.1:14228 +[::1]:14229 ", recorder.text.items);

    // The same servers again, written otherwise: nothing changes.
    recorder.text.clearRetainingCapacity();
    pool.update(io, &.{ "127.0.0.1:14227", "127.0.0.1:14228", "[0:0::1]:14229" }, &recorder);
    try expectPool(&pool, "127.0.0.1:14226 127.0.0.1:14227* 127.0.0.1:14228* [::1]:14229* ");
    try testing.expectEqualStrings("", recorder.text.items);

    // A node left the cluster; the explicit server stays though unnamed.
    pool.update(io, &.{ "127.0.0.1:14227", "[::1]:14229" }, &recorder);
    try expectPool(&pool, "127.0.0.1:14226 127.0.0.1:14227* [::1]:14229* ");
    try testing.expectEqualStrings("-127.0.0.1:14228 ", recorder.text.items);

    // An empty list, as from a server outside a cluster, removes nothing.
    recorder.text.clearRetainingCapacity();
    pool.update(io, &.{}, &recorder);
    try expectPool(&pool, "127.0.0.1:14226 127.0.0.1:14227* [::1]:14229* ");
    try testing.expectEqualStrings("", recorder.text.items);
}

test "the server of the current connection stays, though INFO no longer names it" {
    const io = testing.io;
    const servers = parsedAll(&.{"a:1"});
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    pool.update(io, &.{ "b:2", "c:3" }, &ignore_changes);
    _ = pool.next(io);
    try testing.expectEqualStrings("b", pool.next(io).host());
    // A lame duck announces the others only.
    pool.update(io, &.{"c:3"}, &ignore_changes);
    try expectPool(&pool, "a:1 b:2* c:3* ");
    try testing.expectEqualStrings("c", pool.next(io).host());
    pool.update(io, &.{"c:3"}, &ignore_changes);
    try expectPool(&pool, "a:1 c:3* ");
    try testing.expectEqualStrings("c", pool.currentServer(io).?.host());
    try testing.expectEqualStrings("a", pool.next(io).host());
}

test "the pool holds 64 servers at most; addresses that do not parse are skipped" {
    const io = testing.io;
    const servers = parsedAll(&.{"a:1"});
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    var texts: [Options.max_servers + 10][8]u8 = undefined;
    var urls: [Options.max_servers + 10][]const u8 = undefined;
    for (&urls, &texts, 0..) |*u, *t, i| u.* = try std.fmt.bufPrint(t, "h{d}", .{i});
    urls[3] = "ws://h3";
    pool.update(io, &urls, &ignore_changes);
    try testing.expectEqual(Options.max_servers, pool.count(io));
    try testing.expect(pool.find(&parsed("h3")) == null);
}

test "discovered servers fill as much of a buffer as there is" {
    const io = testing.io;
    const servers = parsedAll(&.{"a:1"});
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    var buffer: [4]ServerAddress = undefined;
    try testing.expectEqual(0, pool.discovered(io, &buffer).len);
    pool.update(io, &.{ "b:2", "c:3", "d:4" }, &ignore_changes);
    const all = pool.discovered(io, &buffer);
    try testing.expectEqual(3, all.len);
    try testing.expectEqualStrings("b", all[0].host());
    try testing.expectEqualStrings("d", all[2].host());
    try testing.expectEqual(2, pool.discovered(io, buffer[0..2]).len);
}

test "with randomize_servers new servers join anywhere, and the current one stays current" {
    const io = testing.io;
    const servers = parsedAll(&.{ "a:1", "b:2" });
    var pool: Pool = try .init(testing.allocator, io, &servers, true);
    defer pool.deinit(testing.allocator);
    const first = pool.next(io);
    var texts: [40][8]u8 = undefined;
    var urls: [40][]const u8 = undefined;
    for (&urls, &texts, 0..) |*u, *t, i| u.* = try std.fmt.bufPrint(t, "n{d}", .{i});
    pool.update(io, &urls, &ignore_changes);
    try testing.expectEqual(42, pool.count(io));
    try testing.expect(same(&pool.currentServer(io).?, &first));
}

test "a server that refuses the credentials the same way twice in a row is noted so" {
    const io = testing.io;
    const servers = parsedAll(&.{ "a:1", "b:2" });
    var pool: Pool = try .init(testing.allocator, io, &servers, false);
    defer pool.deinit(testing.allocator);
    try testing.expect(!pool.noteAttempt(io, .authorization_violation));
    _ = pool.next(io);
    try testing.expect(!pool.noteAttempt(io, .authorization_violation));
    // Another server between two attempts on this one changes nothing.
    _ = pool.next(io);
    try testing.expect(!pool.noteAttempt(io, null));
    _ = pool.next(io);
    try testing.expect(pool.noteAttempt(io, .authorization_violation));
    // Another refusal, or an attempt that ended otherwise, starts over.
    try testing.expect(!pool.noteAttempt(io, .user_authentication_expired));
    try testing.expect(!pool.noteAttempt(io, null));
    try testing.expect(!pool.noteAttempt(io, .user_authentication_expired));
}
