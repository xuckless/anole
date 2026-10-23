//! gRPC between processes on one host: a Unix domain socket, cleartext
//! HTTP/2 (prior knowledge), no TLS. The server's `unix` listener serves
//! h2c by default, so a registered service answers there; the client
//! dials "unix:/path".
const std = @import("std");
const builtin = @import("builtin");
const features = @import("build_options");
const pb = @import("anole_test_pb");
const h2c = @import("anole_h2_client");
const grpc = @import("root.zig");
const common = @import("h3_test.zig");
const server_mod = @import("../server.zig");

const Server = server_mod.Server;
const Echo = pb.Echo(grpc.Call, anyerror);

fn newArena() std.heap.ArenaAllocator {
    return .init(std.testing.allocator);
}

test "grpc over a unix socket: all four call modes, socket mode 0660, a stale socket file replaced" {
    if (comptime builtin.os.tag == .windows or !features.http2 or !features.grpc) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative: a unix socket path has room for about 104 bytes.
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/g.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const target = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(target);

    var app = try Server(void).init(gpa, .{ .listeners = &.{.{ .unix = path }}, .executors = .exact(2) }, {});
    defer app.deinit();
    app.grpc(Echo, .{
        .Unary = common.unary,
        .ServerStream = common.serverStream,
        .ClientStream = common.clientStream,
        .Bidi = common.bidi,
    });
    const Check = struct {
        fn run(a: *Server(void), sock: []const u8, host: []const u8) !void {
            defer a.stop();
            try a.waitReady();
            const io = a.io();
            // Owner and group only.
            const stat = try std.Io.Dir.cwd().statFile(io, sock, .{});
            try std.testing.expectEqual(@as(u32, 0o660), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));

            const channel = try grpc.Channel.connect(std.testing.allocator, io, .{ .host = host, .port = 0 }, .{});
            defer channel.close();
            try std.testing.expectEqualStrings("localhost", channel.authority);
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const r = try client.unary("Unary", arena, .{ .message = "ipc" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqualStrings("ipc", r.message.?.message);
            try std.testing.expectEqual(grpc.Transport.h2, r.transport);
            {
                var s = try client.stream("ServerStream", arena, .{});
                defer s.deinit();
                try s.send(.{ .message = "n", .repeat = 4 });
                try s.closeSend();
                var n: usize = 0;
                while (try s.receive()) |_| n += 1;
                try std.testing.expectEqual(@as(usize, 4), n);
                try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
            }
            {
                var s = try client.stream("ClientStream", arena, .{});
                defer s.deinit();
                for ([_][]const u8{ "a", "b", "c" }) |m| try s.send(.{ .message = m });
                try s.closeSend();
                try std.testing.expectEqualStrings("abc", (try s.receive()).?.message);
                try std.testing.expect(try s.receive() == null);
            }
            {
                var s = try client.stream("Bidi", arena, .{});
                defer s.deinit();
                for ([_][]const u8{ "ping", "pong" }) |m| {
                    try s.send(.{ .message = m });
                    try std.testing.expectEqualStrings(m, (try s.receive()).?.message);
                }
                try s.closeSend();
                try std.testing.expect(try s.receive() == null);
                try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
            }
            // "unix:///path" is the same socket.
            var url_buf: [160]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "unix://{s}", .{sock});
            const second = try grpc.Channel.connect(std.testing.allocator, io, .{ .host = url, .port = 0 }, .{});
            defer second.close();
            const c2: grpc.Client(Echo) = .{ .channel = second };
            try std.testing.expectEqual(grpc.Code.ok, (try c2.unary("Unary", arena, .{ .message = "x" }, .{})).status.code);
            // TLS has no place on a socket.
            try std.testing.expectError(error.TlsOnUnixSocket, h2c.ClientConnection.connect(std.testing.allocator, io, .{
                .host = host,
                .port = 0,
                .tls = .{ .insecure_skip_verify = true },
            }));
        }
    };

    // A socket file left behind by a server that is gone.
    {
        const io = app.io();
        const addr = try std.Io.net.UnixAddress.init(path);
        var stale = try addr.listen(io, .{});
        stale.deinit(io);
    }
    var future = try app.io().concurrent(Check.run, .{ &app, path, target });
    try app.run();
    try future.await(app.io());
}
