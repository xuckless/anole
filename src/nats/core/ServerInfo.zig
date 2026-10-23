// Adapted from vkiryakov/zefir src/nats/ServerInfo.zig (MIT, Copyright (c) 2026 vkiryakov),
// commit dbcc967. See src/LICENSE.zefir and THIRD_PARTY_NOTICES.
//! What a server says about itself in INFO. Servers keep adding
//! fields, so unknown ones are ignored; a missing field keeps its default.

const std = @import("std");
const ServerInfo = @This();

server_id: []const u8 = "",
server_name: []const u8 = "",
version: []const u8 = "",
go: []const u8 = "",
host: []const u8 = "",
port: u16 = 0,
/// 1 on every current server: INFO may come at any time, CONNECT may set `echo`.
proto: i32 = 0,
/// HPUB and HMSG are available: needed for headers and for no-responders.
headers: bool = false,
/// The largest message, headers included, the server takes from this
/// client. 0 when the server did not say: the client then caps a message
/// only at 999 999 999 bytes, the most its protocol line can carry.
max_payload: i64 = 0,
client_id: u64 = 0,
client_ip: []const u8 = "",
auth_required: bool = false,
/// The server wants TLS, which this client does not do.
tls_required: bool = false,
tls_verify: bool = false,
tls_available: bool = false,
/// The cluster's servers as `host:port`, without a scheme.
connect_urls: []const []const u8 = &.{},
/// Lame duck mode: the server is about to go away.
ldm: bool = false,
git_commit: []const u8 = "",
jetstream: bool = false,
nonce: []const u8 = "",
cluster: []const u8 = "",
domain: []const u8 = "",

pub const ParseError = error{ ProtocolError, OutOfMemory };

/// Parses the JSON of an INFO line. The result owns copies of every string,
/// so `json` may be reused at once; free it with `deinit()`. JSON that is
/// not an INFO, or has a known field of another type, is ProtocolError.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) ParseError!std.json.Parsed(ServerInfo) {
    return std.json.parseFromSlice(ServerInfo, gpa, json, .{
        .ignore_unknown_fields = true,
        // The default would point strings into `json`: the read buffer.
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolError,
    };
}

const testing = std.testing;
const golden = @import("protocol/golden.zig");

test "the INFO of a plain server" {
    const info = try parse(testing.allocator, golden.info_default_json);
    defer info.deinit();
    try testing.expectEqualStrings("2.15.1", info.value.version);
    try testing.expectEqual(1, info.value.proto);
    try testing.expect(info.value.headers);
    try testing.expectEqual(1_048_576, info.value.max_payload);
    try testing.expectEqual(14222, info.value.port);
    try testing.expectEqual(6, info.value.client_id);
    try testing.expect(!info.value.auth_required and !info.value.tls_required and !info.value.ldm);
    try testing.expectEqual(0, info.value.connect_urls.len);
}

test "INFO after CONNECT, with auth, with TLS" {
    const connected = try parse(testing.allocator, golden.info_connected_json);
    defer connected.deinit();
    try testing.expect(connected.value.headers);

    const auth = try parse(testing.allocator, golden.info_auth_json);
    defer auth.deinit();
    try testing.expect(auth.value.auth_required);

    const tls = try parse(testing.allocator, golden.info_tls_json);
    defer tls.deinit();
    try testing.expect(tls.value.tls_required);
}

test "cluster topology and lame duck mode" {
    const cluster = try parse(testing.allocator, golden.info_cluster_json);
    defer cluster.deinit();
    try testing.expectEqualStrings("spike", cluster.value.cluster);
    try testing.expectEqual(2, cluster.value.connect_urls.len);
    try testing.expectEqualStrings("127.0.0.1:14234", cluster.value.connect_urls[0]);
    try testing.expectEqualStrings("127.0.0.1:14235", cluster.value.connect_urls[1]);

    const ldm = try parse(testing.allocator, golden.info_ldm_json);
    defer ldm.deinit();
    try testing.expect(ldm.value.ldm);
    try testing.expectEqual(1, ldm.value.connect_urls.len);
}

test "strings are copied out of the input" {
    var json = golden.info_cluster_json.*;
    const info = try parse(testing.allocator, &json);
    defer info.deinit();
    @memset(&json, 'X');
    try testing.expectEqualStrings("A", info.value.server_name);
    try testing.expectEqualStrings("127.0.0.1:14234", info.value.connect_urls[0]);
}

test "malformed INFO" {
    for ([_][]const u8{ "", "not json", "[1]", "{\"port\":70000}", "{\"port\":-1}", "{\"headers\":1}", "{\"port\":1,\"port\":2}" }) |json| {
        try testing.expectError(error.ProtocolError, parse(testing.allocator, json));
    }
    const empty = try parse(testing.allocator, "{}");
    defer empty.deinit();
    try testing.expect(!empty.value.headers);
}

fn parseAndFree(gpa: std.mem.Allocator, json: []const u8) !void {
    const info = try parse(gpa, json);
    info.deinit();
}

test "no leaks when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{golden.info_cluster_json});
}
