//! Unix-socket connects through Anole's runtime (zio's `std.Io`), the path
//! the `.unix` listeners, the gRPC `unix:` client and `anole console` take.
//! On Windows a connect once failed with WSAEFAULT inside zio's IOCP backend
//! (#139); this connects at every path length the platform allows.
const std = @import("std");
const zio = @import("zio");

test "unix socket: a client connects to a listener at every path length up to the limit (#139)" {
    if (comptime !std.Io.net.has_unix_sockets or !zio.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(1) });
    defer rt.deinit();
    const io = rt.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative to the working directory, so the shortest name sits right
    // after the temporary directory and the longest at the limit.
    const max_len = @min(std.Io.net.UnixAddress.max_len, zio.net.UnixAddress.max_len);
    var buf: [max_len]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    @memset(buf[dir.len..], 'u');

    for (dir.len + 1..max_len + 1) |len| {
        connectAt(io, buf[0..len]) catch |err| {
            std.debug.print("unix socket path of {d} bytes ({s}): {t}\n", .{ len, buf[0..len], err });
            return err;
        };
    }
}

/// Listens at `path`, connects, accepts, and passes one byte across.
fn connectAt(io: std.Io, path: []const u8) !void {
    const addr = try std.Io.net.UnixAddress.init(path);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const client = try addr.connect(io);
    defer client.close(io);
    const peer = try server.accept(io);
    defer peer.close(io);

    var wbuf: [1]u8 = undefined;
    var writer = client.writer(io, &wbuf);
    try writer.interface.writeByte('u');
    try writer.interface.flush();
    var rbuf: [1]u8 = undefined;
    var reader = peer.reader(io, &rbuf);
    try std.testing.expectEqual(@as(u8, 'u'), try reader.interface.takeByte());
}
