// Adapted from vkiryakov/zefir src/nats/engine/OwnedOptions.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! The client's own copy of the options: servers parsed, strings copied,
//! the credentials wiped when freed. `options.servers` is empty in the copy;
//! the parsed servers are in `servers`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("../Options.zig");
const ServerAddress = @import("../ServerAddress.zig");
const OwnedOptions = @This();

options: Options,
servers: []ServerAddress,

pub fn init(gpa: Allocator, options: Options) (Options.Error || Allocator.Error)!OwnedOptions {
    try options.validate();
    const servers = try gpa.alloc(ServerAddress, options.servers.len);
    errdefer gpa.free(servers);
    for (servers, options.servers) |*server, url| {
        server.* = ServerAddress.parse(url) catch return error.InvalidOptions;
    }

    var copy = options;
    copy.servers = &.{};
    copy.name = if (options.name) |name| try gpa.dupe(u8, name) else null;
    errdefer if (copy.name) |name| gpa.free(name);
    switch (options.auth) {
        .none => {},
        .user_password => |credentials| {
            const username = try gpa.dupe(u8, credentials.username);
            errdefer {
                std.crypto.secureZero(u8, username);
                gpa.free(username);
            }
            const password = try gpa.dupe(u8, credentials.password);
            copy.auth = .{ .user_password = .{ .username = username, .password = password } };
        },
        .token => |t| copy.auth = .{ .token = try gpa.dupe(u8, t) },
        .nkey => |k| copy.auth = .{ .nkey = .{ .seed = try gpa.dupe(u8, k.seed) } },
        .creds => |c| {
            const seed = try gpa.dupe(u8, c.seed);
            errdefer {
                std.crypto.secureZero(u8, seed);
                gpa.free(seed);
            }
            copy.auth = .{ .creds = .{ .jwt = try gpa.dupe(u8, c.jwt), .seed = seed } };
        },
    }
    return .{ .options = copy, .servers = servers };
}

pub fn deinit(owned: *OwnedOptions, gpa: Allocator) void {
    owned.wipeCredentials();
    switch (owned.options.auth) {
        .none => {},
        .user_password => |credentials| {
            gpa.free(credentials.password);
            gpa.free(credentials.username);
        },
        .token => |t| gpa.free(t),
        .nkey => |k| gpa.free(k.seed),
        .creds => |c| {
            gpa.free(c.jwt);
            gpa.free(c.seed);
        },
    }
    if (owned.options.name) |name| gpa.free(name);
    gpa.free(owned.servers);
    owned.* = undefined;
}

/// Overwrites the copies of the credentials, so they do not stay in freed
/// memory.
fn wipeCredentials(owned: *OwnedOptions) void {
    switch (owned.options.auth) {
        .none => {},
        .user_password => |credentials| {
            std.crypto.secureZero(u8, @constCast(credentials.username));
            std.crypto.secureZero(u8, @constCast(credentials.password));
        },
        .token => |t| std.crypto.secureZero(u8, @constCast(t)),
        .nkey => |k| std.crypto.secureZero(u8, @constCast(k.seed)),
        .creds => |c| std.crypto.secureZero(u8, @constCast(c.seed)),
    }
}

const testing = std.testing;
const one_server: []const []const u8 = &.{"nats://127.0.0.1:4222"};

test "the copy holds everything the caller may free" {
    var url = "nats://127.0.0.1:14222".*;
    var name = "orders".*;
    var username = "user".*;
    var password = "secret".*;
    var owned: OwnedOptions = try .init(testing.allocator, .{
        .servers = &.{&url},
        .name = &name,
        .auth = .{ .user_password = .{ .username = &username, .password = &password } },
    });
    defer owned.deinit(testing.allocator);
    @memset(&url, 'X');
    @memset(&name, 'X');
    @memset(&username, 'X');
    @memset(&password, 'X');
    try testing.expectEqual(1, owned.servers.len);
    try testing.expectEqualStrings("127.0.0.1", owned.servers[0].host());
    try testing.expectEqual(14222, owned.servers[0].port);
    try testing.expectEqualStrings("orders", owned.options.name.?);
    try testing.expectEqualStrings("user", owned.options.auth.user_password.username);
    try testing.expectEqualStrings("secret", owned.options.auth.user_password.password);
    try testing.expectEqual(0, owned.options.servers.len);
}

test "invalid options are refused before anything is copied" {
    try testing.expectError(error.InvalidOptions, OwnedOptions.init(testing.allocator, .{ .servers = &.{} }));
}

test "deinit wipes the copies of the credentials" {
    var owned: OwnedOptions = try .init(testing.allocator, .{ .servers = one_server, .auth = .{ .user_password = .{ .username = "user", .password = "secret" } } });
    defer owned.deinit(testing.allocator);
    // deinit wipes first; Allocator.free overwrites freed memory in Debug,
    // so the wipe is checked before it.
    owned.wipeCredentials();
    try testing.expect(std.mem.allEqual(u8, owned.options.auth.user_password.password, 0));
    try testing.expect(std.mem.allEqual(u8, owned.options.auth.user_password.username, 0));
}

fn initAndDeinit(gpa: Allocator, options: Options) !void {
    var owned: OwnedOptions = try .init(gpa, options);
    owned.deinit(gpa);
}

test "nothing leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(@import("../../../testing/no_resize.zig").allocator, initAndDeinit, .{Options{
        .servers = &.{ "a:1", "b:2" },
        .name = "n",
        .auth = .{ .user_password = .{ .username = "u", .password = "p" } },
    }});
}
