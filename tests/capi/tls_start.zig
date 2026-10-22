//! Runs tests/capi/tls_start.c's program (built against libanole.a with
//! dead-stripping by `zig build capi-test`), makes one HTTPS request to its
//! self-signed listener with std's TLS client, and checks the answer and a
//! clean exit after the drain.
//!
//!   tls_start <path-to-capi-tls-start>
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;

    var child = try std.process.spawn(io, .{ .argv = &.{args[1]}, .stdin = .pipe, .stdout = .pipe });
    errdefer child.kill(io);

    var line_buf: [64]u8 = undefined;
    var out = child.stdout.?.reader(io, &line_buf);
    const line = out.interface.takeDelimiterExclusive('\n') catch |err| {
        const term = try child.wait(io);
        std.log.err("tls_start ended before listening ({t}): {any}", .{ err, term });
        std.process.exit(1);
    };
    const port = try std.fmt.parseInt(u16, std.mem.trim(u8, line, " \r"), 10);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var sock_rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sock_wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sock_r = stream.reader(io, &sock_rbuf);
    var sock_w = stream.writer(io, &sock_wbuf);
    var tls_rbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_wbuf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    var tls = try std.crypto.tls.Client.init(&sock_r.interface, &sock_w.interface, .{
        .host = .no_verification,
        .ca = .no_verification,
        .read_buffer = &tls_rbuf,
        .write_buffer = &tls_wbuf,
        .entropy = &entropy,
        .realtime_now = std.Io.Clock.real.now(io),
    });
    try tls.writer.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try tls.writer.flush();
    try sock_w.interface.flush();
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(init.gpa);
    tls.reader.appendRemainingUnlimited(init.gpa, &response) catch |err| switch (err) {
        error.ReadFailed => if (response.items.len == 0) return err,
        else => return err,
    };
    if (!std.mem.startsWith(u8, response.items, "HTTP/1.1 200") or !std.mem.endsWith(u8, response.items, "dead-strip ok")) {
        std.log.err("unexpected answer: {s}", .{response.items});
        return error.BadAnswer;
    }

    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        std.log.err("tls_start ended with {any}", .{term});
        return error.ChildFailed;
    }
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &.{});
    try stdout.interface.print("tls_start: HTTPS over a dead-stripped libanole.a link, ok\n", .{});
}
