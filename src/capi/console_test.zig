//! The live console through the C ABI: `anole_console_log` records, as a
//! console attached over the control socket gets them.
const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const engine = @import("engine.zig");
const abi = engine.abi;
const zio = anole.zio;
const alloc = std.testing.allocator;
const features = anole.features;
const ui = @import("anole_console_ui");

/// Answers every request, first logging one line for it through
/// `anole_console_log` with its handle; later logs one with a stale handle.
const Logger = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    stop: std.atomic.Value(bool) = .init(false),
    failures: std.atomic.Value(u32) = .init(0),
    answered: std.atomic.Value(u32) = .init(0),
    last: std.atomic.Value(u64) = .init(0),

    fn run(self: *Logger) void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        var need: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const n = engine.pollWait(self.c, &buf, 50, &need) catch unreachable;
            var off: usize = 0;
            while (off < n) {
                const ev: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                if (ev.type == @backingInt(abi.EventType.request)) {
                    self.e.consoleLog(.warn, "app", "charging the card", ev.handle);
                    if (engine.respond(self.e, ev.handle, 200, &.{}, "ok", false)) |_| {
                        self.last.store(ev.handle, .release);
                        _ = self.answered.fetchAdd(1, .release);
                    } else |_| _ = self.failures.fetchAdd(1, .monotonic);
                }
                off += ev.len;
            }
        }
    }
};

fn get(io: std.Io, port: u16, path: []const u8, request_id: []const u8) !void {
    const stream = try (try std.Io.net.IpAddress.parse("127.0.0.1", port)).connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nX-Request-Id: {s}\r\nConnection: close\r\n\r\n", .{ path, request_id });
    try w.interface.flush();
    var rbuf: [512]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var out: [512]u8 = undefined;
    var ow: std.Io.Writer = .fixed(&out);
    _ = r.interface.streamRemaining(&ow) catch {};
    if (!std.mem.startsWith(u8, ow.buffered(), "HTTP/1.1 200")) return error.NotOk;
}

fn check(a: *Logger, port: u16, io: std.Io) !void {
    try get(io, port, "/charges/42", "req-7f3a");
    try wait.waitAtLeast(io, "the consumer answered the request", &a.answered, 1);
    // The request is answered and its slot released: its handle tags
    // nothing now.
    a.e.consoleLog(.warn, "app", "late line", a.last.load(.acquire));
}

test "capi engine: anole_console_log tags a record with its request's id and route, and a stale handle with nothing" {
    if (comptime !features.console) return error.SkipZigTest;
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var json_buf: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf,
        \\{{"executors": 1, "timeouts": {{"shutdown_ms": 500}},
        \\ "console": {{"enabled": true, "socket": "{s}/c.sock", "log_buffer": 65536}},
        \\ "middleware": [{{"request_id": {{"trust_incoming": true}}}}],
        \\ "listeners": [{{"address": "127.0.0.1", "port": 0}}],
        \\ "routes": [{{"path": "/charges/:id", "handler": 7}}]}}
    , .{dir_buf[0..dir_len]});
    var why_buf: [256]u8 = undefined;
    var why: std.Io.Writer = .fixed(&why_buf);
    const e = engine.Engine.create(json, false, &why) catch |err| {
        std.debug.print("{s}\n", .{why.buffered()});
        return err;
    };
    defer e.destroy();
    const c = try e.attach(null, null, true);
    try e.start();
    var a: Logger = .{ .e = e, .c = c };
    const t = try std.Thread.spawn(.{}, Logger.run, .{&a});
    defer {
        a.stop.store(true, .release);
        t.join();
    }
    const rt = try zio.Runtime.init(alloc, .{});
    defer rt.deinit();
    const io = rt.io();
    var f = try io.concurrent(check, .{ &a, e.port(0), io });
    try f.await(io);
    try std.testing.expectEqual(@as(u32, 0), a.failures.load(.acquire));

    // What a console attached over the control socket gets, as `anole
    // console` attaches: the two records from the backlog of a logs
    // subscription.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/c.sock", .{dir_buf[0..dir_len]});
    const stream = try (try std.Io.net.UnixAddress.init(path)).connect(std.testing.io);
    const fd: ui.sys.fd_t = @intCast(stream.socket.handle);
    var conn = ui.client.Conn.init(alloc, fd, fd);
    defer {
        conn.close();
        conn.deinit();
    }
    const deadline = ui.sys.monotonicMs() + 10_000;
    try conn.handshake("capi console test", 10_000, ui.sys.monotonicMs);
    _ = try conn.subscribeLogs(.{ .scope = "app" }, 10);
    try conn.flush();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var tagged = false;
    var late = false;
    while (!(tagged and late)) {
        while (try conn.nextFrame(arena.allocator())) |frame| switch (frame) {
            .log => |r| if (std.mem.eql(u8, r.text, "charging the card")) {
                try std.testing.expectEqualStrings("req-7f3a", r.request_id);
                try std.testing.expectEqualStrings("/charges/:id", r.route);
                tagged = true;
            } else if (std.mem.eql(u8, r.text, "late line")) {
                try std.testing.expectEqualStrings("", r.request_id);
                try std.testing.expectEqualStrings("", r.route);
                late = true;
            },
            else => {},
        };
        if (tagged and late) break;
        const left = deadline - ui.sys.monotonicMs();
        if (left <= 0) return if (!tagged) error.NoTaggedRecord else error.NoLateRecord;
        var p = [1]ui.sys.PollFd{.{ .fd = fd, .events = ui.sys.POLLIN, .revents = 0 }};
        if (ui.sys.poll(&p, @intCast(@min(left, 1000))) > 0) {
            if (!try conn.fill()) return error.ConsoleClosed;
        }
    }
    try e.drain();
    try std.testing.expect(e.wait(@intCast(wait.deadlineMs())));
}
