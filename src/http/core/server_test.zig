// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

const std = @import("std");
const builtin = @import("builtin");
const dusty = @import("root.zig");
const loopback_addr: dusty.Address = .{ .ip = .{ .ip4 = .loopback(0) } };
const loopback: []const dusty.Listener = &.{.{ .address = loopback_addr }};

fn testClientServer(comptime Ctx: type, ctx: *Ctx) !void {
    const io = std.testing.io;
    const TestServer = dusty.Server(Ctx);

    var server = TestServer.init(std.testing.allocator, io, .{ .listeners = loopback }, ctx);
    defer server.deinit();

    try ctx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *TestServer) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *TestServer, test_ctx: *Ctx, _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            try test_ctx.makeRequest(&writer.interface);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const response = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{response});
        }
    }.run, .{ &server, ctx, io });

    try client_future.await(io);
}

test "Server: POST with body" {
    const TestContext = struct {
        const Self = @This();

        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/test", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            const request_body = "Hello from test!";
            try writer.print("POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ request_body.len, request_body });
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

            var writer = std.Io.Writer.fixed(&ctx.received_body);
            const n = try reader.interface.streamRemaining(&writer);

            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: a gzip request body reaches the handler decoded" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    const TestContext = struct {
        const Self = @This();

        // "Hello from test!", gzip compressed.
        const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xf3\x48\xcd\xc9\xc9\x57" ++
            "\x48\x2b\xca\xcf\x55\x28\x49\x2d\x2e\x51\x04\x00\x7c\xe6\xd9\x99\x10\x00\x00\x00";

        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/gzip", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.print(
                "POST /gzip HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ gzip_body.len, gzip_body },
            );
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);
            var writer = std.Io.Writer.fixed(&ctx.received_body);
            ctx.received_len = try reader.interface.streamRemaining(&writer);
            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expectEqualStrings("Hello from test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: POST with chunked encoding" {
    const TestContext = struct {
        const Self = @This();

        body_received: bool = false,
        received_body: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.post("/chunked", handlePost);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("POST /chunked HTTP/1.1\r\n");
            try writer.writeAll("Host: localhost\r\n");
            try writer.writeAll("Transfer-Encoding: chunked\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();

            try writer.writeAll("6\r\n");
            try writer.writeAll("Hello \r\n");
            try writer.flush();

            try writer.writeAll("5\r\n");
            try writer.writeAll("from \r\n");
            try writer.flush();

            try writer.writeAll("D\r\n");
            try writer.writeAll("chunked test!\r\n");
            try writer.flush();

            try writer.writeAll("0\r\n");
            try writer.writeAll("\r\n");
            try writer.flush();
        }

        fn handlePost(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

            var writer = std.Io.Writer.fixed(&ctx.received_body);
            const n = try reader.interface.streamRemaining(&writer);

            ctx.body_received = true;
            ctx.received_len = n;

            std.log.info("Received chunked body: {s}", .{ctx.received_body[0..n]});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.body_received);
    try std.testing.expectEqualStrings("Hello from chunked test!", ctx.received_body[0..ctx.received_len]);
}

test "Server: GET with no body" {
    const TestContext = struct {
        const Self = @This();

        reader_tested: bool = false,
        read_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/test", handleGet);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.flush();
        }

        fn handleGet(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);

            var body_buf: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&body_buf);
            const n = reader.interface.streamRemaining(&writer) catch |err| blk: {
                if (err == error.EndOfStream) break :blk 0;
                return err;
            };

            ctx.reader_tested = true;
            ctx.read_len = n;

            std.log.info("Read {d} bytes from GET request body", .{n});

            res.body = "OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.reader_tested);
    try std.testing.expectEqual(0, ctx.read_len);
}

test "Server: HTTP/1.0 GET request" {
    const TestContext = struct {
        const Self = @This();

        request_handled: bool = false,
        version_major: u16 = 0,
        version_minor: u16 = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/http10", handleGet);
        }

        pub fn makeRequest(ctx: *Self, writer: *std.Io.Writer) !void {
            _ = ctx;
            try writer.writeAll("GET /http10 HTTP/1.0\r\n\r\n");
            try writer.flush();
        }

        fn handleGet(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            ctx.request_handled = true;
            ctx.version_major = req.version_major;
            ctx.version_minor = req.version_minor;

            res.body = "HTTP/1.0 OK\n";
        }
    };

    var ctx: TestContext = .{};
    try testClientServer(TestContext, &ctx);

    try std.testing.expect(ctx.request_handled);
    try std.testing.expectEqual(1, ctx.version_major);
    try std.testing.expectEqual(0, ctx.version_minor);
}

test "Server: a streamed body to an HTTP/1.0 client is not chunked" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/stream", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            var buf: [64]u8 = undefined;
            var body = try res.stream(&buf);
            try body.interface.writeAll("hello ");
            try body.interface.flush();
            try body.interface.writeAll("world");
            try body.end();
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /stream HTTP/1.0\r\n\r\n");
    try writer.interface.flush();

    // The body ends when the connection does.
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const raw = try reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(raw);

    try std.testing.expect(std.mem.startsWith(u8, raw, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "Transfer-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, raw, "\r\n\r\nhello world"));
}

test "Server: an upgraded connection keeps what came with the handshake, and its head" {
    const io = std.testing.io;
    const big_len = 10_000;

    const TestContext = struct {
        const Self = @This();
        url_ok: bool = false,
        echoed: bool = false,

        fn handle(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var ws = try res.upgradeWebSocket(req) orelse {
                res.status = .bad_request;
                return;
            };
            defer ws.deinit();
            // Bigger than the windows the reader and writer shrank to.
            const msg = try ws.receive();
            try std.testing.expectEqual(big_len, msg.data.len);
            for (msg.data, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
            try ws.send(.binary, msg.data);
            // The request's head is still there after the upgrade.
            ctx.url_ok = std.mem.eql(u8, req.url, "/ws?room=a") and
                std.mem.eql(u8, req.headers.get("X-Tag") orelse "", "kept");
            @atomicStore(bool, &ctx.echoed, true, .release);
        }
    };

    var ctx: TestContext = .{};
    var server = dusty.Server(TestContext).init(std.testing.allocator, io, .{ .listeners = loopback }, &ctx);
    defer server.deinit();
    server.router.get("/ws", TestContext.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(TestContext)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);
    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // The handshake and a masked 10 000-byte frame in one write.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try out.appendSlice(a, "GET /ws?room=a HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-Tag: kept\r\n\r\n");
    const mask = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    try out.appendSlice(a, &.{ 0x82, 0x80 | 126, big_len >> 8, big_len & 0xff });
    try out.appendSlice(a, &mask);
    for (0..big_len) |i| try out.append(a, @as(u8, @truncate(i)) ^ mask[i % 4]);
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(out.items);
    try writer.interface.flush();

    var read_buf: [16384]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;
    const head = try r.takeDelimiterInclusive('\n');
    try std.testing.expect(std.mem.indexOf(u8, head, "101") != null);
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, line, "\r\n")) break;
    }
    const frame_head = try r.takeArray(4);
    try std.testing.expectEqual(0x82, frame_head[0]);
    try std.testing.expectEqual(126, frame_head[1]);
    try std.testing.expectEqual(big_len, std.mem.readInt(u16, frame_head[2..4], .big));
    const body = try r.take(big_len);
    for (body, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);
    // The handler checks the head after the echo, so wait for it.
    while (!@atomicLoad(bool, &ctx.echoed, .acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    try std.testing.expect(ctx.url_ok);
}

test "Server: WebSocket echo" {
    const io = std.testing.io;

    const TestContext = struct {
        const Self = @This();

        ws_upgraded: bool = false,
        message_received: bool = false,
        received_msg: [256]u8 = undefined,
        received_len: usize = 0,

        pub fn setup(ctx: *Self, server: *dusty.Server(Self)) !void {
            _ = ctx;
            server.router.get("/ws", handleWebSocket);
        }

        fn handleWebSocket(ctx: *Self, req: *dusty.Request, res: *dusty.Response) !void {
            var ws = try res.upgradeWebSocket(req) orelse {
                res.status = .bad_request;
                return;
            };

            ctx.ws_upgraded = true;

            try ws.send(.text, "Welcome!");

            const msg = ws.receive() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };

            if (msg.type == .text) {
                ctx.message_received = true;
                ctx.received_len = @min(msg.data.len, ctx.received_msg.len);
                @memcpy(ctx.received_msg[0..ctx.received_len], msg.data[0..ctx.received_len]);
                try ws.send(.text, msg.data);
            }
        }
    };

    var ctx: TestContext = .{};

    var server = dusty.Server(TestContext).init(std.testing.allocator, io, .{ .listeners = loopback }, &ctx);
    defer server.deinit();

    try ctx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(TestContext)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(TestContext), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            const w = &writer.interface;

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const r = &reader.interface;

            try w.writeAll("GET /ws HTTP/1.1\r\n");
            try w.writeAll("Host: localhost\r\n");
            try w.writeAll("Upgrade: websocket\r\n");
            try w.writeAll("Connection: Upgrade\r\n");
            try w.writeAll("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
            try w.writeAll("Sec-WebSocket-Version: 13\r\n");
            try w.writeAll("\r\n");
            try w.flush();

            var response_buf: [512]u8 = undefined;
            var response_len: usize = 0;
            while (response_len < response_buf.len - 1) {
                const buffered = r.buffered();
                if (buffered.len > 0) {
                    response_buf[response_len] = buffered[0];
                    r.toss(1);
                    response_len += 1;
                    if (response_len >= 4 and
                        response_buf[response_len - 4] == '\r' and
                        response_buf[response_len - 3] == '\n' and
                        response_buf[response_len - 2] == '\r' and
                        response_buf[response_len - 1] == '\n')
                    {
                        break;
                    }
                } else {
                    try r.fillMore();
                }
            }
            const response_str = response_buf[0..response_len];
            try std.testing.expect(std.mem.indexOf(u8, response_str, "101") != null);
            try std.testing.expect(std.mem.indexOf(u8, response_str, "Sec-WebSocket-Accept") != null);

            const readExact = struct {
                fn read(rdr: *std.Io.Reader, dest: []u8) !void {
                    var filled: usize = 0;
                    while (filled < dest.len) {
                        const buffered = rdr.buffered();
                        if (buffered.len > 0) {
                            const to_copy = @min(buffered.len, dest.len - filled);
                            @memcpy(dest[filled..][0..to_copy], buffered[0..to_copy]);
                            rdr.toss(to_copy);
                            filled += to_copy;
                        } else {
                            try rdr.fillMore();
                        }
                    }
                }
            }.read;

            var frame_header: [2]u8 = undefined;
            try readExact(r, &frame_header);
            try std.testing.expectEqual(0x81, frame_header[0]);
            const welcome_len = frame_header[1] & 0x7F;
            const welcome = try std.testing.allocator.alloc(u8, welcome_len);
            defer std.testing.allocator.free(welcome);
            try readExact(r, welcome);
            try std.testing.expectEqualStrings("Welcome!", welcome);

            const masked_hello = [_]u8{
                0x81,
                0x85,
                0x37,
                0xfa,
                0x21,
                0x3d,
                'H' ^ 0x37,
                'e' ^ 0xfa,
                'l' ^ 0x21,
                'l' ^ 0x3d,
                'o' ^ 0x37,
            };
            try w.writeAll(&masked_hello);
            try w.flush();

            try readExact(r, &frame_header);
            try std.testing.expectEqual(0x81, frame_header[0]);
            const echo_len = frame_header[1] & 0x7F;
            const echo = try std.testing.allocator.alloc(u8, echo_len);
            defer std.testing.allocator.free(echo);
            try readExact(r, echo);
            try std.testing.expectEqualStrings("Hello", echo);

            std.log.info("WebSocket test passed: received echo '{s}'", .{echo});
        }
    }.run, .{ &server, io });

    try client_future.await(io);

    try std.testing.expect(ctx.ws_upgraded);
    try std.testing.expect(ctx.message_received);
    try std.testing.expectEqualStrings("Hello", ctx.received_msg[0..ctx.received_len]);
}

test "Server: void context handlers" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/test", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "Hello from void context!\n";
        }
    }.handle);

    server.router.post("/echo", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var read_buf: [1024]u8 = undefined;
            var reader = try req.reader(&read_buf);
            const body = try reader.interface.allocRemaining(req.arena, .limited(1024));
            res.body = try std.fmt.allocPrint(res.arena, "Echo: {s}\n", .{body});
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            try writer.interface.writeAll("GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');

            std.log.info("Response: {s}", .{status_line});
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: graceful shutdown drain still blocks after an earlier connection closed" {
    const io = std.testing.io;

    const sync = struct {
        var slow_started: std.Io.Event = .unset;
    };
    sync.slow_started = .unset;

    // Short enough to expire long before the 2s handler finishes, so the
    // drain has to give up rather than wait it out.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .shutdown = .fromMilliseconds(100) },
    }, {});
    defer server.deinit();

    server.router.get("/fast", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.slow_started.set(req.io);
            try req.io.sleep(.fromMilliseconds(2000), .awake);
            res.body = "slow";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    // cancel() is idempotent, so this is a no-op after the expectError below
    // consumes the future; it only matters if the test fails early.
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    // A connection closes before shutdown begins.
    {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        defer stream.shutdown(io, .both) catch {};

        var write_buf: [1024]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        const status_line = try reader.interface.takeDelimiterExclusive('\n');
        try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
    }

    // Wait until the server has fully torn down that connection.
    while (server.active_connections.load(.acquire) != 0) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    // Park a slow handler so shutdown has an active connection to drain.
    const slow_stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer slow_stream.close(io);
    defer slow_stream.shutdown(io, .both) catch {};

    var slow_write_buf: [1024]u8 = undefined;
    var slow_writer = slow_stream.writer(io, &slow_write_buf);
    try slow_writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try slow_writer.interface.flush();

    try sync.slow_started.wait(io);

    // Graceful shutdown: the drain must block, and give up when its budget
    // runs out rather than wait out the 2s handler. The elapsed time is what
    // shows that -- before the fix the drain spun hot until the handler
    // finished, which took the full two seconds. `listen` reports the
    // cancellation either way; the drain no longer reports how it went.
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expect(elapsed_ns < 1500 * std.time.ns_per_ms);
}

test "Server: 100-continue" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/upload", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            const body = try req.body();
            res.body = body orelse "";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            const body = "Hello, World!";
            try writer.interface.print("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nExpect: 100-continue\r\n\r\n", .{body.len});
            try writer.interface.flush();

            const continue_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, continue_line, "100 Continue") != null);
            reader.interface.toss(1);
            _ = try reader.interface.takeDelimiterExclusive('\n');
            reader.interface.toss(1);

            try writer.interface.writeAll(body);
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, status_line, "200 OK") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: no 100 Continue once the response has started" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/upload", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var buf: [64]u8 = undefined;
            var body = try res.stream(&buf);
            try body.interface.writeAll("first;");
            try body.interface.flush();
            try body.interface.writeAll((try req.body()) orelse "");
            try body.end();
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("POST /upload HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var out: [1024]u8 = undefined;
    var out_writer = std.Io.Writer.fixed(&out);
    _ = try reader.interface.streamRemaining(&out_writer);
    const response = out_writer.buffered();

    try std.testing.expectStringStartsWith(response, "HTTP/1.1 200 ");
    try std.testing.expect(std.mem.indexOf(u8, response, "100 Continue") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "first;") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "hello") != null);
}

fn readResponse(r: *std.Io.Reader, status_buf: []u8, body_buf: []u8) !struct { status: []const u8, body: []const u8 } {
    const status_line = try r.takeDelimiterExclusive('\n');
    const status_len = @min(status_line.len, status_buf.len);
    @memcpy(status_buf[0..status_len], status_line[0..status_len]);
    r.toss(1);

    var content_length: usize = 0;
    while (true) {
        const line = try r.takeDelimiterExclusive('\n');
        r.toss(1);
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }

    const body_len = @min(content_length, body_buf.len);
    var got: usize = 0;
    while (got < body_len) {
        if (r.buffered().len == 0) try r.fillMore();
        const buffered = r.buffered();
        const to_copy = @min(buffered.len, body_len - got);
        @memcpy(body_buf[got..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        got += to_copy;
    }

    return .{ .status = status_buf[0..status_len], .body = body_buf[0..body_len] };
}

test "Server: keepalive after handler ignores request body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    server.router.get("/ping", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "second";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    const body = "this body is ignored";
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    try w.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("second", resp2.body);
}

test "Server: keepalive with request buffers given back between requests" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .request = .{ .keep_buffers_between_requests = false },
    }, {});
    defer server.deinit();

    server.router.post("/echo", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = (try req.body()) orelse "no body";
        }
    }.handle);
    server.router.get("/header", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = if (req.headers.get("X-Long")) |v| v[0..8] else "missing";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    var status: [64]u8 = undefined;
    var body: [32]u8 = undefined;

    try w.writeAll("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nfirst");
    try w.flush();
    const resp1 = try readResponse(r, &status, &body);
    try std.testing.expectEqualStrings("first", resp1.body);

    // A head longer than what a connection waits for a request in, so it
    // is read the rest of the way into the set taken again.
    const long_value = "abcdefgh" ++ &@as([2000]u8, @splat('x'));
    try w.writeAll("GET /header HTTP/1.1\r\nHost: localhost\r\nX-Long: " ++ long_value ++ "\r\n\r\n");
    try w.flush();
    const resp2 = try readResponse(r, &status, &body);
    try std.testing.expectEqualStrings("abcdefgh", resp2.body);

    try w.writeAll("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nthird");
    try w.flush();
    const resp3 = try readResponse(r, &status, &body);
    try std.testing.expectEqualStrings("third", resp3.body);
}

/// Serves `/a`, `/b` and `/c` with their names, `/b` from its request body
/// and `/a` for any method without reading one. What a pipelining test
/// needs: enough routes to tell the responses apart, and bodies read and
/// unread for the parser to get past.
const PipelineCtx = struct {
    fn setup(server: *dusty.Server(void)) void {
        server.router.any("/a", struct {
            fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                res.body = "a";
            }
        }.handle);
        server.router.post("/b", struct {
            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                res.body = (try req.body()) orelse "no body";
            }
        }.handle);
        server.router.get("/c", struct {
            fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                res.body = "c";
            }
        }.handle);
    }
};

/// Sends `requests` in a single write and checks that every response in
/// `expected` comes back, in order, on the same connection.
fn expectPipelinedResponses(
    server: *dusty.Server(void),
    requests: []const u8,
    expected: []const []const u8,
) !void {
    const io = std.testing.io;

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(requests);
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    for (expected) |want| {
        var status: [64]u8 = undefined;
        var body: [64]u8 = undefined;
        const resp = try readResponse(&reader.interface, &status, &body);
        try std.testing.expect(std.mem.indexOf(u8, resp.status, "200") != null);
        try std.testing.expectEqualStrings(want, resp.body);
    }
}

test "Server: pipelined requests are answered in order on one connection" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    try expectPipelinedResponses(
        &server,
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
            "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "a", "c", "a" },
    );
}

test "Server: a pipelined request behind a body is served after it" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    try expectPipelinedResponses(
        &server,
        "POST /b HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "hello", "c" },
    );
}

test "Server: a pipelined request behind an unread body is served after it is drained" {
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    // `/a` never reads its body, so the server has to skip it to find the
    // request behind it.
    try expectPipelinedResponses(
        &server,
        "POST /a HTTP/1.1\r\nHost: localhost\r\nContent-Length: 7\r\n\r\nignored" ++
            "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n",
        &.{ "a", "c" },
    );
}

test "Server: a pipelined head that needs the whole read buffer is served" {
    // Under a 1024-byte head limit the read buffer is 2048 bytes, so two
    // heads of 1000 bytes arrive in one read. The second parses only if the
    // first has been moved out of its way: what it left the reader would
    // be too small for the reserve the body reader is owed.
    var server = dusty.Server(void).init(std.testing.allocator, std.testing.io, .{
        .listeners = loopback,
        .request = .{ .buffer_size = 1024 },
    }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    var requests: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer requests.deinit();
    for (0..2) |_| {
        const prefix = "GET /c HTTP/1.1\r\nHost: localhost\r\nX-Pad: ";
        const suffix = "\r\n\r\n";
        try requests.writer.writeAll(prefix);
        try requests.writer.splatByteAll('A', 1000 - prefix.len - suffix.len);
        try requests.writer.writeAll(suffix);
    }

    try expectPipelinedResponses(&server, requests.written(), &.{ "c", "c" });
}

test "Server: a pipelined head that arrives in two parts is served" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // The start of the second head rides behind the first request, and the
    // rest only comes once the first has been answered.
    try w.writeAll("GET /a HTTP/1.1\r\nHost: localhost\r\n\r\nGET /c HTTP/1.1\r\nHo");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expectEqualStrings("a", resp1.body);

    try w.writeAll("st: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expectEqualStrings("c", resp2.body);
}

test "Server: Connection: close on a pipelined request ends the connection after it" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /a HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" ++
        "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expectEqualStrings("a", resp1.body);

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, readResponse(r, &status2, &body2));
}

test "Server: a CONNECT ends the connection, its body unserved" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    PipelineCtx.setup(&server);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    // llhttp ends a CONNECT at its head, so the "body" is what follows it.
    const smuggled = "GET /c HTTP/1.1\r\nHost: localhost\r\n\r\n";
    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nContent-Length: {d}\r\n\r\n{s}", .{ smuggled.len, smuggled });
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "404") != null);

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, readResponse(r, &status2, &body2));
}

test "Server: a handler's own EndOfStream is a 500, not a vanished peer" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/eof", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            var buf: [64]u8 = undefined;
            var r = try req.reader(&buf);
            // Nothing to read, so the std helper reports the end of the
            // body the way a peer hanging up is spelled.
            _ = try r.interface.takeDelimiterExclusive('\n');
            res.body = "unreachable";
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    try w.writeAll("GET /eof HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [64]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "500") != null);

    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
}

test "Server: handler error yields 500 and keeps the connection alive" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/boom", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            _ = res;
            return error.Boom;
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // A handler that returns an error must still produce a written 500 response,
    // not tear down the connection with no reply.
    try w.writeAll("GET /boom HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [64]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "500") != null);

    // The connection stays alive, so a subsequent request still works.
    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("ok", resp2.body);
}

test "Server: an event stream is chunked and leaves the connection reusable" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/events", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            var event_buf: [4096]u8 = undefined;
            var events = try res.startEventStream(&event_buf);
            try events.send("first", .{ .event = "tick", .id = "1" });
            try events.send("second", .{});
        }
    }.handle);

    server.router.get("/ok", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    try w.writeAll("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    // Read up to the chunked terminator, which is where the stream ends and
    // the connection becomes free for the next request.
    var got: [1024]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, got[0..len], "0\r\n\r\n") == null) {
        r.fillMore() catch break;
        const buffered = r.buffered();
        if (buffered.len == 0) break;
        const to_copy = @min(buffered.len, got.len - len);
        @memcpy(got[len..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        len += to_copy;
    }
    const reply = got[0..len];

    try std.testing.expect(std.mem.indexOf(u8, reply, "Content-Type: text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Content-Length") == null);
    // Each event sits between a chunk header and its trailing CRLF, so it
    // reached the peer on its own rather than when a buffer filled.
    try std.testing.expect(std.mem.indexOf(u8, reply, "\r\nevent: tick\nid: 1\ndata: first\n\n\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\r\ndata: second\n\n\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "0\r\n\r\n"));

    // Chunks end the stream without ending the connection, so the next
    // request on it is still answered.
    try w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [64]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("ok", resp2.body);
}

test "Server: handler error after streaming started aborts the connection" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/bad-stream", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            // Start streaming, then fail - the headers and first chunk are
            // already on the wire, so the error can't be turned into a 500.
            var body_buf: [64]u8 = undefined;
            var body = try res.stream(&body_buf);
            try body.interface.writeAll("partial");
            try body.interface.flush();
            return error.Boom;
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    try w.writeAll("GET /bad-stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    // Read everything the server sends before closing the connection.
    var received: [256]u8 = undefined;
    var received_len: usize = 0;
    while (received_len < received.len) {
        r.fillMore() catch break;
        const buffered = r.buffered();
        if (buffered.len == 0) break;
        const to_copy = @min(buffered.len, received.len - received_len);
        @memcpy(received[received_len..][0..to_copy], buffered[0..to_copy]);
        r.toss(to_copy);
        received_len += to_copy;
    }
    const got = received[0..received_len];

    // The partial chunk was already flushed before the handler errored...
    try std.testing.expect(std.mem.indexOf(u8, got, "partial") != null);
    // ...but the chunked terminator must be absent: the connection was
    // aborted instead of silently completing a truncated, "successful" body.
    try std.testing.expect(std.mem.indexOf(u8, got, "0\r\n\r\n") == null);

    // The connection must not stay alive for reuse.
    w.writeAll("GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {};
    w.flush() catch {};
    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    _ = readResponse(r, &status2, &body2) catch return;
    return error.TestExpectedConnectionToBeClosed;
}

test "Server: keepalive after handler ignores a compressed request body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    server.router.get("/ping", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "second";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // The handler never reads it, so the drain has to throw away the wire
    // bytes -- and the header saying how many there are is one decoding
    // would have removed, had anything asked it to.
    const gzip_body = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x2b\xc9\xc8\x2c\x56\x48" ++
        "\xca\x4f\xa9\x54\x00\xd2\x99\xe9\x79\xf9\x45\xa9\x29\x00\x79\xf5\xd8\x44\x14\x00\x00\x00";
    try w.print(
        "POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ gzip_body.len, gzip_body },
    );
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    try w.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("second", resp2.body);
}

test "Server: closes connection when unread body exceeds max_body_size" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(
        std.testing.allocator,
        io,
        .{ .listeners = loopback, .request = .{ .max_body_size = 100 } },
        {},
    );
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    const body = &@as([200]u8, @splat('x'));
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    w.writeAll("GET /ignore HTTP/1.1\r\nHost: localhost\r\n\r\n") catch {};
    w.flush() catch {};

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    _ = readResponse(r, &status2, &body2) catch return;
    return error.TestExpectedSecondResponseToFail;
}

test "Server: 417 Expectation Failed for unknown Expect value" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/upload", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            const body = try req.body();
            res.body = body orelse "";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            try writer.interface.writeAll("POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nExpect: unknown-value\r\n\r\n");
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expect(std.mem.indexOf(u8, status_line, "417") != null);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}
/// Sends `raw` to a server with one GET route at `/` and returns the status
/// line it answers with.
fn statusLineFor(raw: []const u8, out: []u8) ![]const u8 {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, request: []const u8, status_out: []u8) ![]const u8 {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            try writer.interface.writeAll(request);
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            @memcpy(status_out[0..status_line.len], status_line);
            return status_out[0..status_line.len];
        }
    }.run, .{ &server, io, raw, out });

    return client_future.await(io);
}

test "Server: a bad percent escape in the query is a 400, not a dropped connection" {
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET /?q=100% HTTP/1.1\r\nHost: localhost\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 400 ");
}

/// Sends `head`, then `body_len` bytes of body the server will not read, and
/// returns the status line of the answer. The rest of the answer must end
/// with a FIN: a close with the body unread would be a reset, and the peer
/// could lose the answer to it.
fn statusLineWithUnreadBody(head: []const u8, body_len: usize, chunked: bool, timeouts: bool, out: []u8) ![]const u8 {
    const io = std.testing.io;

    var config: dusty.ServerConfig = .{ .listeners = loopback, .request = .{ .max_body_size = 100 } };
    if (!timeouts) config.timeout = .{ .request = null, .keepalive = null };
    var server = dusty.Server(void).init(std.testing.allocator, io, config, {});
    defer server.deinit();

    const ignore = struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle;
    server.router.get("/", ignore);
    server.router.post("/", ignore);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io, request_head: []const u8, len: usize, is_chunked: bool, status_out: []u8) ![]const u8 {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            // All of it in one send, so it is all queued at the server
            // before the answer: a reset then shows up in the reads below
            // rather than in a write.
            var write_buf: [64 * 1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);

            try writer.interface.writeAll(request_head);
            if (is_chunked) try writer.interface.print("{x}\r\n", .{len});
            try writer.interface.splatByteAll('x', len);
            if (is_chunked) try writer.interface.writeAll("\r\n0\r\n\r\n");
            try writer.interface.flush();

            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            @memcpy(status_out[0..status_line.len], status_line);
            _ = try reader.interface.discardRemaining();
            return status_out[0..status_line.len];
        }
    }.run, .{ &server, io, head, body_len, chunked, out });

    return client_future.await(io);
}

test "Server: a body too large to drain is not answered with a reset" {
    var buf: [256]u8 = undefined;
    for ([_]bool{ true, false }) |timeouts| {
        const status = try statusLineWithUnreadBody("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 32768\r\n\r\n", 32768, false, timeouts, &buf);
        try std.testing.expectStringStartsWith(status, "HTTP/1.1 200 ");
    }
}

test "Server: an unread chunked body is not answered with a reset" {
    var buf: [256]u8 = undefined;
    for ([_]bool{ true, false }) |timeouts| {
        const status = try statusLineWithUnreadBody("POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n", 32768, true, timeouts, &buf);
        try std.testing.expectStringStartsWith(status, "HTTP/1.1 200 ");
    }
}

test "Server: a 417 before an unread body is not answered with a reset" {
    var buf: [256]u8 = undefined;
    for ([_]bool{ true, false }) |timeouts| {
        const status = try statusLineWithUnreadBody("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 32768\r\nExpect: unknown-value\r\n\r\n", 32768, false, timeouts, &buf);
        try std.testing.expectStringStartsWith(status, "HTTP/1.1 417 ");
    }
}

test "Server: a 400 before an unread body is not answered with a reset" {
    var buf: [256]u8 = undefined;
    for ([_]bool{ true, false }) |timeouts| {
        const status = try statusLineWithUnreadBody("POST /?q=100% HTTP/1.1\r\nHost: localhost\r\nContent-Length: 32768\r\n\r\n", 32768, false, timeouts, &buf);
        try std.testing.expectStringStartsWith(status, "HTTP/1.1 400 ");
    }
}

test "Server: too many query parameters is a 400, not a dropped connection" {
    // One past the default limit of 32, each under its own name.
    const query = comptime blk: {
        var q: []const u8 = "";
        for (0..33) |i| q = q ++ std.fmt.comptimePrint("k{d}=v&", .{i});
        break :blk q;
    };
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET /?" ++ query ++ " HTTP/1.1\r\nHost: localhost\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 400 ");
}

test "Server: more headers than the limit is a 431, not a dropped connection" {
    // One past the default limit of 32.
    const headers = comptime blk: {
        var h: []const u8 = "";
        for (0..33) |i| h = h ++ std.fmt.comptimePrint("X-H{d}: v\r\n", .{i});
        break :blk h;
    };
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("GET / HTTP/1.1\r\nHost: localhost\r\n" ++ headers ++ "\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 431 ");
}

test "Server: a response written without reading the body does not wait for one held back by Expect" {
    // No POST route (only GET), so the 405 is written by nothing that
    // reads the body, and the peer never sends it: it is waiting for 100
    // Continue.
    var buf: [256]u8 = undefined;
    const status = try statusLineFor("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n", &buf);
    try std.testing.expectStringStartsWith(status, "HTTP/1.1 405 ");
}

test "Server: a body sent without waiting for 100 Continue is drained and the connection kept" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.post("/ignore", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "first";
        }
    }.handle);

    server.router.get("/ping", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "second";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    const w = &writer.interface;

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const r = &reader.interface;

    // Expect, and the body right behind it: the peer is not waiting.
    const body = "this body is ignored";
    try w.print("POST /ignore HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nExpect: 100-continue\r\n\r\n{s}", .{ body.len, body });
    try w.flush();

    var status1: [64]u8 = undefined;
    var body1: [32]u8 = undefined;
    const resp1 = try readResponse(r, &status1, &body1);
    try std.testing.expect(std.mem.indexOf(u8, resp1.status, "200") != null);
    try std.testing.expectEqualStrings("first", resp1.body);

    try w.writeAll("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try w.flush();

    var status2: [64]u8 = undefined;
    var body2: [32]u8 = undefined;
    const resp2 = try readResponse(r, &status2, &body2);
    try std.testing.expect(std.mem.indexOf(u8, resp2.status, "200") != null);
    try std.testing.expectEqualStrings("second", resp2.body);
}

test "Server: HEAD is answered by the GET route with no body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/thing", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.content_type = .text;
            res.body = "0123456789";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var conn_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &conn_buf);

            try writer.interface.writeAll("HEAD /thing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();

            var rest: [2048]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&rest);
            _ = reader.interface.streamRemaining(&sink) catch {};
            const got = sink.buffered();

            try std.testing.expect(std.mem.indexOf(u8, got, "HTTP/1.1 200") != null);
            // The length a GET would have reported...
            try std.testing.expect(std.mem.indexOf(u8, got, "Content-Length: 10") != null);
            // ...and none of those bytes.
            try std.testing.expect(std.mem.indexOf(u8, got, "0123456789") == null);
            try std.testing.expect(std.mem.endsWith(u8, got, "\r\n\r\n"));
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: graceful shutdown waits for a connection that finishes in time" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
        var finished: bool = false;
    };
    sync.started = .unset;
    sync.finished = false;

    // Comfortably longer than the handler, so the drain has no reason to
    // give up on it.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .shutdown = .fromMilliseconds(5000) },
    }, {});
    defer server.deinit();

    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.started.set(req.io);
            try req.io.sleep(.fromMilliseconds(200), .awake);
            sync.finished = true;
            res.body = "slow";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    try sync.started.wait(io);

    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;

    // Waited for the handler rather than abandoning it, and stopped as soon
    // as it was done rather than sitting out the rest of the budget.
    try std.testing.expect(sync.finished);
    try std.testing.expect(elapsed_ns >= 100 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 2000 * std.time.ns_per_ms);
}
/// Leaves one connection idle after a request and one that never sent any,
/// shuts the server down with a budget long enough that waiting it out would
/// be unmistakable, and checks that both were closed at once.
fn expectIdleConnectionsClosedOnShutdown(timeout: dusty.ServerConfig.Timeout) !void {
    const io = std.testing.io;

    var config: dusty.ServerConfig = .{ .listeners = loopback, .timeout = timeout };
    config.timeout.shutdown = .fromMilliseconds(5000);
    var server = dusty.Server(void).init(std.testing.allocator, io, config, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    // One connection idle after a request, one that never sent any.
    const used = try server.address.ip.connect(io, .{ .mode = .stream });
    defer used.close(io);
    const fresh = try server.address.ip.connect(io, .{ .mode = .stream });
    defer fresh.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = used.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = used.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectEqualStrings("OK", resp.body);

    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds;
    try std.testing.expect(elapsed_ns < 1000 * std.time.ns_per_ms);

    // Both were closed by the server, not abandoned to the cancel.
    try std.testing.expectError(error.EndOfStream, reader.interface.fillMore());
    var fresh_buf: [64]u8 = undefined;
    var fresh_reader = fresh.reader(io, &fresh_buf);
    try std.testing.expectError(error.EndOfStream, fresh_reader.interface.fillMore());
}

test "Server: a request arriving during the shutdown drain is refused, not served" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
        var release: std.Io.Event = .unset;
    };
    sync.started = .unset;
    sync.release = .unset;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .shutdown = .fromMilliseconds(5000) },
    }, {});
    defer server.deinit();

    // Holds the drain open until the test lets it go.
    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.started.set(req.io);
            try sync.release.wait(req.io);
            res.body = "slow";
        }
    }.handle);
    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = req;
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        // Spelled out so the future can be named below.
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const slow = try server.address.ip.connect(io, .{ .mode = .stream });
    defer slow.close(io);
    var slow_write_buf: [256]u8 = undefined;
    var slow_writer = slow.writer(io, &slow_write_buf);
    try slow_writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try slow_writer.interface.flush();
    try sync.started.wait(io);

    // Idle by the time the drain starts.
    const idle = try server.address.ip.connect(io, .{ .mode = .stream });
    defer idle.close(io);

    // The drain blocks on the slow handler, so it runs on a task of its own.
    var shutdown_future = try io.concurrent(struct {
        fn run(f: *std.Io.Future(anyerror!void), _io: std.Io) !void {
            try std.testing.expectError(error.Canceled, f.cancel(_io));
        }
    }.run, .{ &server_future, io });
    defer shutdown_future.cancel(io) catch {};
    while (!server.busy.load(.acquire).draining) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    var write_buf: [256]u8 = undefined;
    var writer = idle.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [1024]u8 = undefined;
    var reader = idle.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 503 ");
    try std.testing.expectError(error.EndOfStream, reader.interface.fillMore());

    sync.release.set(io);
    try shutdown_future.await(io);
}

test "Server: a long-lived handler learns of the drain through req.drain and ends it early" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
    };
    sync.started = .unset;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .shutdown = .fromSeconds(30) },
    }, {});
    defer server.deinit();

    // Would hold the drain for its whole budget if it did not listen.
    server.router.get("/stream", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try std.testing.expect(!req.drain.?.isSet());
            sync.started.set(req.io);
            try req.drain.?.wait(req.io);
            res.body = "drained";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) anyerror!void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};
    try server.ready.wait(io);

    const conn = try server.address.ip.connect(io, .{ .mode = .stream });
    defer conn.close(io);
    var write_buf: [256]u8 = undefined;
    var writer = conn.writer(io, &write_buf);
    try writer.interface.writeAll("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();
    try sync.started.wait(io);

    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    try std.testing.expect(start.durationTo(.now(io, .awake)).raw.toMilliseconds() < 5000);

    var read_buf: [1024]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 200 ");
    try std.testing.expectEqualStrings("drained", resp.body);
}

test "Server: graceful shutdown closes idle connections without waiting out the budget" {
    try expectIdleConnectionsClosedOnShutdown(.{});
}

test "Server: graceful shutdown closes idle connections with no deadlines configured" {
    try expectIdleConnectionsClosedOnShutdown(.{ .request = null, .keepalive = null });
}

test "Server: request resolves the client through a trusted proxy" {
    const io = std.testing.io;

    const Ctx = struct {
        seen: [2]?std.Io.net.IpAddress = @splat(null),
        count: usize = 0,
    };
    var ctx: Ctx = .{};

    var server = dusty.Server(Ctx).init(std.testing.allocator, io, .{ .listeners = loopback, .trusted_proxy_hops = 1 }, &ctx);
    defer server.deinit();

    server.router.get("/whoami", struct {
        fn handle(c: *Ctx, req: *dusty.Request, res: *dusty.Response) !void {
            if (c.count < c.seen.len) c.seen[c.count] = req.remote_address;
            c.count += 1;
            res.body = "OK\n";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(Ctx)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(Ctx), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            defer stream.shutdown(_io, .both) catch {};

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            var conn_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &conn_buf);

            // Two requests on one connection. The first has no forwarding
            // chain and therefore falls back to the peer. The second must be
            // resolved afresh rather than inheriting the first request's
            // address through the keepalive reset.
            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\n\r\n");
            try writer.interface.flush();
            try readOneResponse(&reader.interface);

            try writer.interface.writeAll("GET /whoami HTTP/1.1\r\nHost: localhost\r\nX-Forwarded-For: 192.0.2.25\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            var rest: [2048]u8 = undefined;
            var sink: std.Io.Writer = .fixed(&rest);
            _ = reader.interface.streamRemaining(&sink) catch {};
            try std.testing.expect(std.mem.indexOf(u8, sink.buffered(), "HTTP/1.1 200") != null);
        }

        fn readOneResponse(r: *std.Io.Reader) !void {
            var content_length: usize = 0;
            while (true) {
                const line = std.mem.trimEnd(u8, try r.takeDelimiterExclusive('\n'), "\r");
                if (line.len == 0) break;
                const prefix = "Content-Length: ";
                if (std.ascii.startsWithIgnoreCase(line, prefix)) {
                    content_length = try std.fmt.parseInt(usize, line[prefix.len..], 10);
                }
            }
            _ = try r.take(content_length);
        }
    }.run, .{ &server, io });

    try client_future.await(io);

    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    const peer = ctx.seen[0] orelse return error.HandlerNeverRan;
    try std.testing.expect(peer == .ip4);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, peer.ip4.bytes);
    try std.testing.expect(peer.ip4.port != 0);

    const forwarded = ctx.seen[1] orelse return error.HandlerNeverRan;
    try std.testing.expect(forwarded == .ip4);
    try std.testing.expectEqual([4]u8{ 192, 0, 2, 25 }, forwarded.ip4.bytes);
    try std.testing.expectEqual(@as(u16, 0), forwarded.ip4.port);
}

test "Server: client_auth with ca .none is rejected by run" {
    if (!@import("build_options").use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{
            .address = loopback_addr,
            .tls = .{
                .cert_path = "certs/cert.pem",
                .key_path = "certs/key.pem",
                .client_auth = .{ .ca = .none },
            },
        }},
    }, {});
    defer server.deinit();

    try std.testing.expectError(error.NoCertificateAuthority, server.run());
}

test "Server: run serves every listener and tells the handler which one" {
    const io = std.testing.io;

    const listeners = [_]dusty.Listener{
        .{ .address = loopback_addr },
        .{ .address = loopback_addr },
    };
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = &listeners }, {});
    defer server.deinit();

    const Handler = struct {
        var first: *const dusty.Listener = undefined;
        var second: *const dusty.Listener = undefined;

        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try std.testing.expect(!req.secure);
            if (req.listener == first) {
                res.body = "first";
            } else {
                try std.testing.expect(req.listener == second);
                res.body = "second";
            }
        }
    };
    Handler.first = &listeners[0];
    Handler.second = &listeners[1];
    server.router.get("/", Handler.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);
    try std.testing.expectEqual(2, server.addresses.len);
    try std.testing.expect(server.addresses[0].ip.getPort() != server.addresses[1].ip.getPort());
    try std.testing.expectEqual(server.addresses[0].ip.getPort(), server.address.ip.getPort());

    for (server.addresses, [_][]const u8{ "first", "second" }) |address, expected| {
        const stream = try address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        defer stream.shutdown(io, .both) catch {};

        var write_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var status: [64]u8 = undefined;
        var body: [16]u8 = undefined;
        const resp = try readResponse(&reader.interface, &status, &body);
        try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 200 ");
        try std.testing.expectEqualStrings(expected, resp.body);
    }

    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    try std.testing.expectEqual(0, server.addresses.len);
}

test "Server: socket_per_acceptor binds every socket to one port and serves them all" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .acceptors = 4, .socket_per_acceptor = true }},
    }, {});
    defer server.deinit();

    const Handler = struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "ok";
        }
    };
    server.router.get("/", Handler.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);
    try std.testing.expectEqual(1, server.addresses.len);
    try std.testing.expect(server.address.ip.getPort() != 0);

    // The kernel hashes each connection to one of the four sockets, so
    // enough of them reach every one; a socket without a loop would leave
    // some unanswered.
    for (0..64) |_| {
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        defer stream.shutdown(io, .both) catch {};

        var write_buf: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();

        var read_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var status: [64]u8 = undefined;
        var body: [16]u8 = undefined;
        const resp = try readResponse(&reader.interface, &status, &body);
        try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 200 ");
        try std.testing.expectEqualStrings("ok", resp.body);
    }

    try std.testing.expectError(error.Canceled, server_future.cancel(io));
}

test "Server: socket_per_acceptor is refused without SO_REUSEPORT or on a unix socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;

    {
        var server = dusty.Server(void).init(std.testing.allocator, io, .{
            .listeners = &.{.{ .address = loopback_addr, .socket_per_acceptor = true, .reuse_address = false }},
        }, {});
        defer server.deinit();
        try std.testing.expectError(error.SocketPerAcceptorUnsupported, server.run());
    }
    {
        const unix = try std.Io.net.UnixAddress.init("/tmp/dusty-socket-per-acceptor.sock");
        var server = dusty.Server(void).init(std.testing.allocator, io, .{
            .listeners = &.{.{ .address = .{ .unix = unix }, .socket_per_acceptor = true }},
        }, {});
        defer server.deinit();
        try std.testing.expectError(error.SocketPerAcceptorUnsupported, server.run());
    }
}

test "Server: a listener that fails to open releases the ones opened before it" {
    if (!@import("build_options").use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    // A fixed port, so the second attempt to bind it below proves the first
    // listener's socket was closed when the second listener failed.
    var probe = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{ .reuse_address = true });
    const addr: dusty.Address = .{ .ip = probe.socket.address };
    probe.deinit(io);

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{
            .{ .address = addr },
            .{
                .address = loopback_addr,
                .tls = .{ .cert_path = "certs/missing.pem", .key_path = "certs/key.pem" },
            },
        },
    }, {});
    defer server.deinit();

    try std.testing.expectError(error.FileNotFound, server.run());

    var again = try addr.ip.listen(io, .{ .reuse_address = true });
    again.deinit(io);
}

test "Server: a task waiting for the server to listen is told when it never will" {
    if (!@import("build_options").use_tls) return error.SkipZigTest;
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{
            .address = loopback_addr,
            .tls = .{ .cert_path = "certs/missing.pem", .key_path = "certs/key.pem" },
        }},
    }, {});
    defer server.deinit();

    var waiter = try io.concurrent(struct {
        fn wait(s: *dusty.Server(void), _io: std.Io) anyerror!void {
            try s.waitReady(_io);
        }
    }.wait, .{ &server, io });
    defer waiter.cancel(io) catch {};
    try std.testing.expectError(error.FileNotFound, server.run());
    try std.testing.expectError(error.FileNotFound, waiter.await(io));
    // `ready` still means listening, which it never was.
    try std.testing.expect(!server.ready.isSet());
}

test "Server: a listener with tls set is refused when TLS is compiled out" {
    if (@import("build_options").use_tls) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{
            .address = loopback_addr,
            .tls = .{ .cert_path = "certs/cert.pem", .key_path = "certs/key.pem" },
        }},
    }, {});
    defer server.deinit();

    try std.testing.expectError(error.TlsNotConfigured, server.run());
}

test "Server: graceful shutdown waits for a request in flight on a later listener" {
    const io = std.testing.io;

    const sync = struct {
        var started: std.Io.Event = .unset;
        var finished: bool = false;
    };
    sync.started = .unset;
    sync.finished = false;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{ .{ .address = loopback_addr }, .{ .address = loopback_addr } },
        .timeout = .{ .shutdown = .fromMilliseconds(5000) },
    }, {});
    defer server.deinit();

    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            sync.started.set(req.io);
            try req.io.sleep(.fromMilliseconds(200), .awake);
            sync.finished = true;
            res.body = "slow";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.addresses[1].ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    defer stream.shutdown(io, .both) catch {};

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    try sync.started.wait(io);
    try std.testing.expectError(error.Canceled, server_future.cancel(io));
    try std.testing.expect(sync.finished);

    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var status: [64]u8 = undefined;
    var body: [16]u8 = undefined;
    const resp = try readResponse(&reader.interface, &status, &body);
    try std.testing.expectStringStartsWith(resp.status, "HTTP/1.1 200 ");
    try std.testing.expectEqualStrings("slow", resp.body);
}

test "Server: a request head too large for the buffer gets 431, not a panic" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            // Comfortably past the default buffer_size + body_read_reserve,
            // in one header so max_header_count is not what rejects it. The
            // server answers and hangs up part way through, without reading
            // the rest, so these writes are allowed to fail; what is asserted
            // is the response.
            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ") catch {};
            writer.interface.splatByteAll('A', 20000) catch {};
            writer.interface.writeAll("\r\n\r\n") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(
                "HTTP/1.1 431 Request Header Fields Too Large\r",
                status_line,
            );
            // The server hangs up with a FIN, not a reset, although it
            // never read the whole head: the rest of the answer arrives
            // and the end of it is clean.
            _ = try reader.interface.discardRemaining();
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: a head that is not HTTP/1.x gets a 400 and a clean close, an HTTP/2 preface the close alone" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);
            for ([_][]const u8{ "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "GET / HTTP/1.1\r\nBad Header\r\n\r\n", "\x16\x03\x01\x02\x00" }) |head| {
                const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
                defer stream.close(_io);

                // The head, then more than the server reads with it (an
                // HTTP/2 client's SETTINGS and the like): closing with it
                // unread would reset the connection under the answer.
                var write_buf: [1024]u8 = undefined;
                var writer = stream.writer(_io, &write_buf);
                writer.interface.writeAll(head) catch {};
                writer.interface.splatByteAll(0, 20000) catch {};
                writer.interface.flush() catch {};

                var read_buf: [1024]u8 = undefined;
                var reader = stream.reader(_io, &read_buf);
                // The end is a FIN, not a reset.
                const answer = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
                defer std.testing.allocator.free(answer);
                if (std.mem.startsWith(u8, head, "PRI ")) {
                    try std.testing.expectEqualStrings("", answer);
                } else {
                    try std.testing.expectStringStartsWith(answer, "HTTP/1.1 400 Bad Request\r\n");
                }
            }
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: on an h2c listener, a first line with no method is an invalid HTTP/2 preface: closed without a 400" {
    // h2spec http2/3.5 sends "INVALID CONNECTION PREFACE" and wants the
    // connection closed (RFC 9113 section 3.4), with nothing read first.
    if (!@import("build_options").use_http2) return error.SkipZigTest;
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);
            const cases = [_]struct { []const u8, bool }{
                .{ "INVALID CONNECTION PREFACE\r\n\r\n", false },
                .{ "PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n", false },
                // Still HTTP/1.1 enough for a 400.
                .{ "GET / HTTP/1.1\r\nBad Header\r\n\r\n", true },
                .{ "GET / HTTP/9.9\r\nHost: x\r\n\r\n", true },
            };
            for (cases) |c| {
                const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
                defer stream.close(_io);
                var write_buf: [256]u8 = undefined;
                var writer = stream.writer(_io, &write_buf);
                try writer.interface.writeAll(c[0]);
                try writer.interface.flush();
                var read_buf: [1024]u8 = undefined;
                var reader = stream.reader(_io, &read_buf);
                // A FIN, not a reset, and nothing before it but the 400.
                const answer = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
                defer std.testing.allocator.free(answer);
                if (c[1]) {
                    try std.testing.expectStringStartsWith(answer, "HTTP/1.1 400 Bad Request\r\n");
                } else {
                    try std.testing.expectEqualStrings("", answer);
                }
            }
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: Response.abort closes the connection under a streamed body" {
    const io = std.testing.io;

    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            var buf: [64]u8 = undefined;
            var w = try res.stream(&buf);
            try w.interface.writeAll("[1,");
            try w.interface.flush();
            return res.abort();
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
            try writer.interface.flush();
            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const answer = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
            defer std.testing.allocator.free(answer);
            // The chunk that went out, and no terminating chunk.
            try std.testing.expect(std.mem.endsWith(u8, answer, "\r\n\r\n3\r\n[1,\r\n"));
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: a peer that will not hang up after a 431 is hung up on anyway" {
    const io = std.testing.io;

    // No request deadline, so the drain's own is what ends it.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback, .timeout = .{ .request = null } }, {});
    defer server.deinit();

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ") catch {};
            writer.interface.splatByteAll('A', 20000) catch {};
            writer.interface.writeAll("\r\n\r\n") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(
                "HTTP/1.1 431 Request Header Fields Too Large\r",
                status_line,
            );
            // The server's half-close is the end of what it sends.
            _ = try reader.interface.discardRemaining();
            // Keep the connection open and keep sending: a write is taken
            // while the server is still draining, and refused once the
            // drain deadline has passed and the server has closed.
            var probes: usize = 0;
            while (probes < 100) : (probes += 1) {
                try _io.sleep(.fromMilliseconds(50), .awake);
                writer.interface.writeByte('B') catch break;
                writer.interface.flush() catch break;
            }
            try std.testing.expect(probes < 100);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

test "Server: a head that just fits is still served" {
    const io = std.testing.io;

    // 8 KB of header against the 16 KB default: comfortably under, so the
    // guard must not fire early.
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    server.router.get("/", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = req.headers.get("X-Big") orelse "missing";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.waitReady(_io);

            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\nX-Big: ");
            try writer.interface.splatByteAll('A', 8192);
            try writer.interface.writeAll("\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);
        }
    }.run, .{ &server, io });

    try client_future.await(io);
}

/// What the handler saw, so a test can tell a head that was accepted from
/// one that was accepted and then could not read its body.
const HeadBoundaryCtx = struct {
    body: [16]u8 = undefined,
    body_len: usize = 0,

    pub fn handle(ctx: *HeadBoundaryCtx, req: *dusty.Request, res: *dusty.Response) !void {
        const b = (try req.body()) orelse "";
        ctx.body_len = @min(b.len, ctx.body.len);
        @memcpy(ctx.body[0..ctx.body_len], b[0..ctx.body_len]);
        res.body = "OK";
    }
};

/// Sends a request whose head is exactly `head_len` bytes -- a header value
/// padded so the terminating CRLFCRLF lands on the byte asked for -- with a
/// body behind it, and checks the status line that comes back.
///
/// The body is the point. What the head does not use of the read buffer is
/// all the body reader gets, so a head that parses but leaves nothing behind
/// it fails only once something tries to read one.
fn expectStatusForHeadOfLength(
    head_len: usize,
    expected_status: []const u8,
    expected_body: ?[]const u8,
) !void {
    const io = std.testing.io;
    const S = dusty.Server(HeadBoundaryCtx);

    var ctx: HeadBoundaryCtx = .{};
    var server = S.init(std.testing.allocator, io, .{ .listeners = loopback }, &ctx);
    defer server.deinit();
    server.router.post("/", HeadBoundaryCtx.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *S, len: usize, want: []const u8, _io: std.Io) !void {
            try s.waitReady(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            const prefix = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nX-Pad: ";
            const suffix = "\r\n\r\n";
            std.debug.assert(len >= prefix.len + suffix.len);

            // A rejected head is answered part way through and the rest of it
            // never read, so these writes are allowed to fail.
            var write_buf: [1024]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            writer.interface.writeAll(prefix) catch {};
            writer.interface.splatByteAll('A', len - prefix.len - suffix.len) catch {};
            writer.interface.writeAll(suffix) catch {};
            writer.interface.writeAll("hello") catch {};
            writer.interface.flush() catch {};

            var read_buf: [1024]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings(want, status_line);
        }
    }.run, .{ &server, head_len, expected_status, io });

    try client_future.await(io);

    if (expected_body) |want| {
        try std.testing.expectEqualStrings(want, ctx.body[0..ctx.body_len]);
    }
}

// The read buffer is buffer_size + body_read_reserve, and the head is
// accepted exactly when it fits in buffer_size -- leaving the reserve for the
// body reader that inherits the rest.
const head_limit = 16384;
const head_buffer_len = head_limit + 1024;

test "Server: a head of exactly the limit is served, body and all" {
    try expectStatusForHeadOfLength(head_limit, "HTTP/1.1 200 OK\r", "hello");
}

test "Server: a head one byte over the limit gets 431" {
    try expectStatusForHeadOfLength(head_limit + 1, "HTTP/1.1 431 Request Header Fields Too Large\r", null);
}

test "Server: a head ending exactly at the buffer end gets 431, not a panic" {
    // The head parses cleanly and consumes the reserve with it, so nothing
    // during parsing objects -- the body reader is left a zero-length buffer
    // and panics on the first fill.
    try expectStatusForHeadOfLength(head_buffer_len, "HTTP/1.1 431 Request Header Fields Too Large\r", null);
}

/// Counts how many handlers are in flight at once, so a test can see whether
/// the cap held.
const ConcurrencyCtx = struct {
    active: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),
    served: std.atomic.Value(u32) = .init(0),

    pub fn handle(ctx: *ConcurrencyCtx, req: *dusty.Request, res: *dusty.Response) !void {
        const now = ctx.active.fetchAdd(1, .acq_rel) + 1;
        _ = ctx.peak.fetchMax(now, .acq_rel);
        // Long enough that the others are all waiting, so the cap is what
        // limits overlap rather than the handlers being too brief to overlap.
        try req.io.sleep(.fromMilliseconds(30), .awake);
        _ = ctx.active.fetchSub(1, .acq_rel);
        _ = ctx.served.fetchAdd(1, .acq_rel);
        res.body = "OK";
    }
};

test "Server: max_connections caps overlap without dropping anyone" {
    const io = std.testing.io;
    const S = dusty.Server(ConcurrencyCtx);
    const clients = 8;
    const cap = 2;

    var ctx: ConcurrencyCtx = .{};
    var server = S.init(std.testing.allocator, io, .{ .listeners = loopback, .max_connections = cap }, &ctx);
    defer server.deinit();
    server.router.get("/", ConcurrencyCtx.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const One = struct {
        fn run(s: *S, _io: std.Io) !void {
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            // Closing is what frees the slot.
            defer stream.close(_io);

            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [256]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);
        }
    };

    const Fut = @TypeOf(try io.concurrent(One.run, .{ &server, io }));
    var futures: [clients]Fut = undefined;
    for (&futures) |*f| f.* = try io.concurrent(One.run, .{ &server, io });
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };
    if (first_err) |err| return err;

    try std.testing.expectEqual(@as(u32, clients), ctx.served.load(.acquire));
    // Equality rather than <=, so this cannot pass by nothing overlapping.
    try std.testing.expectEqual(@as(u32, cap), ctx.peak.load(.acquire));
}

test "Server: a slot freed on one listener reaches a connection waiting on another" {
    const io = std.testing.io;
    const listeners = [_]dusty.Listener{
        .{ .address = loopback_addr },
        .{ .address = loopback_addr },
    };
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = &listeners, .max_connections = 1 }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const Get = struct {
        fn run(address: dusty.Address, _io: std.Io, served: *std.atomic.Value(bool), hold: ?*std.Io.Event) !void {
            const stream = try address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);

            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
            try writer.interface.flush();

            var read_buf: [256]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            const status_line = try reader.interface.takeDelimiterExclusive('\n');
            try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);
            served.store(true, .release);

            if (hold) |event| try event.wait(_io);
        }
    };

    // The first connection takes the only slot and keeps it, so the first
    // listener's accept loop goes to wait for one.
    var first_served: std.atomic.Value(bool) = .init(false);
    var release_first: std.Io.Event = .unset;
    var first = try io.concurrent(Get.run, .{ server.addresses[0], io, &first_served, &release_first });
    defer first.cancel(io) catch {};
    while (!first_served.load(.acquire)) try io.sleep(.fromMilliseconds(10), .awake);
    try io.sleep(.fromMilliseconds(100), .awake);

    // Accepted on the second listener, and held there until a slot frees.
    var second_served: std.atomic.Value(bool) = .init(false);
    var second = try io.concurrent(Get.run, .{ server.addresses[1], io, &second_served, null });
    defer second.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(100), .awake);

    release_first.set(io);
    try first.await(io);

    var waited: usize = 0;
    while (!second_served.load(.acquire) and waited < 200) : (waited += 1) {
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(second_served.load(.acquire));
    try second.await(io);
}

test "Server: a max_connections of zero is refused by run" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback, .max_connections = 0 }, {});
    defer server.deinit();
    try std.testing.expectError(error.NoConnectionsAllowed, server.run());
}

/// Sends `head` and then stops, holding the connection open, and reports how
/// long the server took to hang up on it. Returns null if the server answered
/// instead of hanging up.
fn millisUntilServerHangsUp(config: dusty.ServerConfig, head: []const u8) !?i64 {
    var cfg = config;
    cfg.listeners = loopback;
    const io = std.testing.io;
    const S = dusty.Server(void);

    var server = S.init(std.testing.allocator, io, cfg, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(head);
    try writer.interface.flush();

    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};

    if (sink.written().len != 0) return null;
    const ended = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return @intCast(@divTrunc(ended - started, std.time.ns_per_ms));
}

test "Server: a stalled request head is cut off by timeout.request" {
    // A head that never terminates.
    const elapsed = try millisUntilServerHangsUp(
        .{ .timeout = .{ .request = .fromMilliseconds(150) } },
        "GET / HTTP/1.1\r\nHost: a\r\n",
    ) orelse return error.ServerAnsweredInstead;

    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 3000);
}

test "Server: an idle keepalive connection is cut off by timeout.keepalive" {
    const io = std.testing.io;
    const S = dusty.Server(void);

    var server = S.init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .keepalive = .fromMilliseconds(150) },
    }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "OK";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *S) !void {
            s.run() catch |err| {
                if (err != error.Canceled) return err;
            };
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: a\r\n\r\n");
    try writer.interface.flush();

    var read_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const status_line = try reader.interface.takeDelimiterExclusive('\n');
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r", status_line);

    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var sink = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};
    const elapsed = @divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - started, std.time.ns_per_ms);

    try std.testing.expect(elapsed >= 100);
    try std.testing.expect(elapsed < 3000);
}

test "Server.dispatch: a request over a sink is routed through the middleware to its handler" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = dusty.Server(void).init(std.testing.allocator, io, .{}, {});
    defer server.deinit();
    server.router.get("/users/:id", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try res.print(.text, "user {s}", .{req.params.get("id").?});
            try res.trailer("x-done", "yes");
        }
    }.handle);

    const Capture = struct {
        status: ?dusty.Status = null,
        ended: bool = false,
        trailer: []const u8 = "",
        buf: [64]u8 = undefined,
        w: std.Io.Writer = undefined,
        fn sink(self: *@This()) dusty.Sink {
            return .{ .ptr = self, .vtable = &.{
                .head = head,
                .interim = interim,
                .body = body,
                .end = end,
                .writeError = writeError,
                .peerGone = peerGone,
            } };
        }
        fn head(ptr: *anyopaque, status: dusty.Status, _: *const dusty.Headers, _: ?usize) std.Io.Writer.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.status = status;
        }
        fn interim(_: *anyopaque, _: dusty.Status) std.Io.Writer.Error!void {}
        fn body(ptr: *anyopaque) *std.Io.Writer {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return &self.w;
        }
        fn end(ptr: *anyopaque, trailers: ?*const dusty.Headers) std.Io.Writer.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.ended = true;
            if (trailers) |t| self.trailer = t.get("x-done") orelse "";
        }
        fn writeError(_: *anyopaque) ?dusty.Response.SendError {
            return null;
        }
        fn peerGone(_: *anyopaque) bool {
            return false;
        }
    };
    var cap: Capture = .{};
    cap.w = .fixed(&cap.buf);

    var req: dusty.Request = .{ .arena = arena, .io = io, .parser = undefined, .transport = undefined };
    req.headers = try dusty.Headers.init(arena, 8);
    req.method = .get;
    req.url = "/users/42";
    var res = try dusty.Response.initSink(arena, io, cap.sink(), 16);
    req.response = &res;
    res.request = &req;

    try server.dispatch(&req, &res);
    try res.write();

    try std.testing.expectEqual(dusty.Status.ok, cap.status.?);
    try std.testing.expectEqualStrings("user 42", cap.w.buffered());
    try std.testing.expect(cap.ended);
    try std.testing.expectEqualStrings("yes", cap.trailer);
}

/// One HTTP/1.1 request over loopback; returns the raw response head.
fn rawHead(io: std.Io, server: *dusty.Server(void), request: []const u8, out: []u8) ![]const u8 {
    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.WriteFailed => {},
        else => |e| return e,
    };
    const all = fw.buffered();
    return all[0 .. std.mem.indexOf(u8, all, "\r\n\r\n") orelse all.len];
}

test "Server: responses carry a Date header, RFC reason phrases and a default Content-Type" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/plain", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "no type set";
        }
    }.handle);
    server.router.get("/typed", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            try res.header("Content-Type", "application/octet-stream");
            res.body = "typed";
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [1024]u8 = undefined;
    const plain = try rawHead(io, &server, "GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, plain, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "\r\nDate: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(plain[std.mem.indexOf(u8, plain, "\r\nDate: ").? + 8 ..], '\r'), " GMT"));
    try std.testing.expect(std.mem.indexOf(u8, plain, "Content-Type: text/plain; charset=UTF-8") != null);

    var buf2: [1024]u8 = undefined;
    const typed = try rawHead(io, &server, "GET /typed HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, typed, "Content-Type: application/octet-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed, "text/plain") == null);

    var buf3: [1024]u8 = undefined;
    const missing = try rawHead(io, &server, "GET /nope HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf3);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));
}

test "Server: a body over max_body_size is 413, a declared one over max_content_length is 413 unread" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .request = .{ .max_body_size = 16, .max_content_length = 1000 },
    }, {});
    defer server.deinit();
    server.router.post("/buffer", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            _ = try req.body();
            res.body = "read";
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [1024]u8 = undefined;
    const too_big = try rawHead(io, &server, "POST /buffer HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\nConnection: close\r\n\r\n01234567890123456789", &buf);
    try std.testing.expect(std.mem.startsWith(u8, too_big, "HTTP/1.1 413 Content Too Large\r\n"));

    var buf2: [1024]u8 = undefined;
    const declared = try rawHead(io, &server, "POST /buffer HTTP/1.1\r\nHost: x\r\nContent-Length: 5000\r\nExpect: 100-continue\r\n\r\n", &buf2);
    try std.testing.expect(std.mem.startsWith(u8, declared, "HTTP/1.1 413 Content Too Large\r\n"));
}

test "Server: a head that does not arrive within read_header closes the connection; a slow body does not" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .timeout = .{ .request = .fromSeconds(5), .read_header = .fromMilliseconds(200) },
    }, {});
    defer server.deinit();
    server.router.post("/echo", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = (try req.body()) orelse "";
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    { // Slowloris: half a head, then nothing.
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var wbuf: [64]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\n");
        try w.interface.flush();
        const start: std.Io.Clock.Timestamp = .now(io, .awake);
        var rbuf: [64]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        // The server hangs up: end of stream, or a reset.
        _ = r.interface.peekByte() catch {};
        const waited = start.durationTo(.now(io, .awake)).raw.toMilliseconds();
        try std.testing.expect(waited < 2000);
    }
    { // A whole head at once, then a body slower than read_header.
        const stream = try server.address.ip.connect(io, .{ .mode = .stream });
        defer stream.close(io);
        var wbuf: [128]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        try w.interface.writeAll("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nConnection: close\r\n\r\n");
        try w.interface.flush();
        try io.sleep(.fromMilliseconds(400), .awake);
        try w.interface.writeAll("late");
        try w.interface.flush();
        var rbuf: [512]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var out: [512]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&out);
        _ = r.interface.streamRemaining(&fw) catch {};
        try std.testing.expect(std.mem.startsWith(u8, fw.buffered(), "HTTP/1.1 200 OK\r\n"));
        try std.testing.expect(std.mem.endsWith(u8, fw.buffered(), "late"));
    }
}

test "Server: a keep-alive request outlives the keepalive timeout; a half head on one does not outlive read_header" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        // No request deadline: a whole head buffered at once runs without a
        // timer, and the keepalive one armed for the wait must not carry
        // into the handler.
        .timeout = .{ .request = null, .keepalive = .fromMilliseconds(200), .read_header = .fromMilliseconds(200) },
    }, {});
    defer server.deinit();
    server.router.get("/slow", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try req.io.sleep(.fromMilliseconds(500), .awake);
            res.body = "slow";
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    for (0..2) |_| {
        try w.interface.writeAll("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n");
        try w.interface.flush();
        const head = try r.interface.takeDelimiterInclusive('\n');
        try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\n", head);
        // The rest of the head, then the four-byte body.
        while (!std.mem.eql(u8, try r.interface.takeDelimiterInclusive('\n'), "\r\n")) {}
        try std.testing.expectEqualStrings("slow", try r.interface.take(4));
    }
    // Half a head on the kept connection: closed at read_header.
    try w.interface.writeAll("GET /slow HTTP/1.1\r\nHost: x\r\n");
    try w.interface.flush();
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    _ = r.interface.peekByte() catch {};
    const waited = start.durationTo(.now(io, .awake)).raw.toMilliseconds();
    try std.testing.expect(waited < 2000);
}

test "Server: a zstd request body is refused with 415 when built without zstd" {
    if (@import("build_options").use_zstd) return error.SkipZigTest;
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.post("/body", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = (try req.body()) orelse "";
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [1024]u8 = undefined;
    const head = try rawHead(io, &server, "POST /body HTTP/1.1\r\nHost: x\r\nContent-Encoding: zstd\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc", &buf);
    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 415 Unsupported Media Type\r\n"));
}

test "Server: the Compress middleware gzips text and leaves images alone" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    var compress = dusty.middleware.Compress.init();
    const mws = [_]dusty.Middleware(void){dusty.Middleware(void).init(&compress)};
    server.router.middlewares = &mws;
    server.router.get("/text", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.content_type = .text;
            res.body = comptime repeat("compressible ", 40);
        }
    }.handle);
    server.router.get("/image", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.content_type = .png;
            res.body = comptime repeat("pretend png bytes ", 40);
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [4096]u8 = undefined;
    const text = try rawHead(io, &server, "GET /text HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "Content-Encoding: gzip") != null);
    var buf2: [4096]u8 = undefined;
    const image = try rawHead(io, &server, "GET /image HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, image, "Content-Encoding") == null);
}

/// `s` `n` times, at compile time.
fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}

test "Server: router.use with RequestId and Logger, and nested groups" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();

    var request_id = dusty.middleware.RequestId.init(.{});
    var logger = dusty.middleware.Logger.init();
    server.router.use(dusty.Middleware(void).init(&request_id));
    server.router.use(dusty.Middleware(void).init(&logger));

    const Tag = struct {
        value: []const u8,
        pub fn execute(self: *const @This(), req: *dusty.Request, res: *dusty.Response, executor: anytype) !void {
            _ = req;
            try res.header("X-Group", self.value);
            return executor.next();
        }
    };
    var outer_tag: Tag = .{ .value = "outer" };
    var inner_tag: Tag = .{ .value = "inner" };
    const outer_mws = [_]dusty.Middleware(void){dusty.Middleware(void).init(&outer_tag)};
    const inner_mws = [_]dusty.Middleware(void){dusty.Middleware(void).init(&inner_tag)};
    const api = server.router.group("/api", &outer_mws);
    const v1 = api.group("/v1", &inner_mws);
    v1.get("/id", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            res.body = req.id;
        }
    }.handle);

    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /api/v1/id HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var out: [2048]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&out);
    _ = r.interface.streamRemaining(&fw) catch {};
    const resp = fw.buffered();

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    // Both groups' middleware ran, outer first (the later header wins).
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Group: inner") != null);
    const id_at = std.mem.indexOf(u8, resp, "X-Request-Id: ").? + "X-Request-Id: ".len;
    const id = resp[id_at..][0..32];
    for (id) |ch| try std.testing.expect(std.ascii.isHex(ch));
    // The handler saw the same ID.
    try std.testing.expect(std.mem.endsWith(u8, resp, id));
}

/// The whole response to `request`, sent on a new connection.
fn rawAll(io: std.Io, server: *dusty.Server(void), request: []const u8, out: []u8) ![]const u8 {
    return rawAllTo(io, server.address.ip, request, out);
}

fn rawAllTo(io: std.Io, address: std.Io.net.IpAddress, request: []const u8, out: []u8) ![]const u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var fw: std.Io.Writer = .fixed(out);
    _ = r.interface.streamRemaining(&fw) catch |err| switch (err) {
        error.WriteFailed => {},
        else => |e| return e,
    };
    return fw.buffered();
}

const WhoHandler = struct {
    fn handle(req: *dusty.Request, res: *dusty.Response) !void {
        try res.print(.text, "{f} secure={} host={s}", .{ req.remote_address, req.secure, req.host() orelse "-" });
    }
};

test "Server: a PROXY protocol listener takes the client address from v1 and v2 headers" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = loopback_addr, .proxy_protocol = true }},
    }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    const v1 = try rawAll(io, &server, "PROXY TCP4 192.0.2.7 198.51.100.2 56324 443\r\nGET /who HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, v1, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, v1, "192.0.2.7:56324 secure=false host=example.com"));

    // v2, IPv6, with the SSL TLV: the client spoke TLS to the proxy.
    var v2: [16 + 36 + 8]u8 = @splat(0);
    @memcpy(v2[0..12], "\r\n\r\n\x00\r\nQUIT\n");
    v2[12] = 0x21;
    v2[13] = 0x21;
    std.mem.writeInt(u16, v2[14..16], 36 + 8, .big);
    v2[16 + 15] = 9; // ::9
    std.mem.writeInt(u16, v2[16 + 32 ..][0..2], 4000, .big);
    v2[16 + 36] = 0x20;
    std.mem.writeInt(u16, v2[16 + 37 ..][0..2], 5, .big);
    v2[16 + 39] = 0x01;
    var req_buf: [256]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&req_buf);
    try rw.writeAll(&v2);
    try rw.writeAll("GET /who HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n");
    const resp2 = try rawAll(io, &server, rw.buffered(), &out);
    try std.testing.expect(std.mem.endsWith(u8, resp2, "[::9]:4000 secure=true host=example.com"));

    // No header: the connection is closed without an answer (a reset,
    // since the request was left unread, or a plain close).
    if (rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n", &out)) |none| {
        try std.testing.expectEqual(@as(usize, 0), none.len);
    } else |err| switch (err) {
        error.ReadFailed => {},
        else => |e| return e,
    }
}

test "Server: a PROXY protocol listener with proxy_protocol_from serves only those peers" {
    const io = std.testing.io;
    const trusted = [_]dusty.ProxyNetwork{try .parse("127.0.0.0/8")};
    const elsewhere = [_]dusty.ProxyNetwork{try .parse("192.0.2.0/24")};
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{
            .{ .address = loopback_addr, .proxy_protocol = true, .proxy_protocol_from = &trusted },
            .{ .address = loopback_addr, .proxy_protocol = true, .proxy_protocol_from = &elsewhere },
        },
    }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const request = "PROXY TCP4 192.0.2.7 198.51.100.2 56324 443\r\nGET /who HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    var out: [2048]u8 = undefined;
    const ok = try rawAllTo(io, server.addresses[0].ip, request, &out);
    try std.testing.expect(std.mem.endsWith(u8, ok, "192.0.2.7:56324 secure=false host=example.com"));

    // 127.0.0.1 is not among the second listener's proxies: closed unanswered.
    if (rawAllTo(io, server.addresses[1].ip, request, &out)) |none| {
        try std.testing.expectEqual(@as(usize, 0), none.len);
    } else |err| switch (err) {
        error.ReadFailed => {},
        else => |e| return e,
    }
}

test "Server: X-Forwarded-Proto and X-Forwarded-Host from a trusted proxy" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback, .trusted_proxy_hops = 1, .trust_forwarded_host = true }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    const resp = try rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: internal:8080\r\nX-Forwarded-For: 203.0.113.9\r\nX-Forwarded-Proto: http, https\r\nX-Forwarded-Host: shop.example.com\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, resp, "203.0.113.9:0 secure=true host=shop.example.com"));

    // A host with characters no host has is ignored.
    const bad = try rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: internal:8080\r\nX-Forwarded-Host: evil.com/x y\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, bad, "secure=false host=internal:8080"));
}

test "Server: X-Forwarded-Host is ignored unless trusted, X-Forwarded-Proto when turned off" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback, .trusted_proxy_hops = 1 }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    const request = "GET /who HTTP/1.1\r\nHost: internal:8080\r\nX-Forwarded-For: 203.0.113.9\r\nX-Forwarded-Proto: https\r\nX-Forwarded-Host: evil.example\r\nConnection: close\r\n\r\n";
    const resp = try rawAll(io, &server, request, &out);
    try std.testing.expect(std.mem.endsWith(u8, resp, "203.0.113.9:0 secure=true host=internal:8080"));

    server.config.trust_forwarded_proto = false;
    const no_proto = try rawAll(io, &server, request, &out);
    try std.testing.expect(std.mem.endsWith(u8, no_proto, "203.0.113.9:0 secure=false host=internal:8080"));
}

test "Server: an HTTP/1.1 request needs exactly one Host" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    const none = try rawAll(io, &server, "GET /who HTTP/1.1\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, none, "HTTP/1.1 400 "));
    const two = try rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, two, "HTTP/1.1 400 "));
    const one = try rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: a.example\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, one, "host=a.example"));
    // HTTP/1.0 had no Host requirement.
    const old = try rawAll(io, &server, "GET /who HTTP/1.0\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, old, " 200 OK\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, old, "host=-"));
}

test "Server: a request body with broken framing is a 400, and the connection closes" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.post("/take", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            const body = try req.body();
            try res.print(.text, "{d}", .{if (body) |b| b.len else 0});
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    // A chunk size that is not hex, then a pipelined request that must
    // not be served from the broken stream.
    const resp = try rawAll(io, &server, "POST /take HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\nzz\r\nxx\r\n0\r\n\r\nPOST /take HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 400 "));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, resp, "HTTP/1.1 "));
}

test "Server: forwarding headers are ignored without trusted hops" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/who", WhoHandler.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var out: [2048]u8 = undefined;
    const resp = try rawAll(io, &server, "GET /who HTTP/1.1\r\nHost: internal:8080\r\nX-Forwarded-For: 203.0.113.9\r\nX-Forwarded-Proto: https\r\nX-Forwarded-Host: shop.example.com\r\nConnection: close\r\n\r\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, resp, "127.0.0.1:") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "secure=false host=internal:8080"));
}

test "Server: a path with routes for other methods answers 405 with Allow" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    const H = struct {
        fn ok(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "ok";
        }
    };
    server.router.get("/items/:id", H.ok);
    server.router.put("/items/:id", H.ok);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [1024]u8 = undefined;
    const head = try rawHead(io, &server, "POST /items/7 HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "\r\nAllow: GET, PUT, HEAD") != null);
    var buf2: [1024]u8 = undefined;
    const missing = try rawHead(io, &server, "POST /nothing HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", &buf2);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));
}

test "Server: compression follows the client's q-values over the server's preference" {
    if (!@import("build_options").use_zlib) return error.SkipZigTest;
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{ .listeners = loopback }, {});
    defer server.deinit();
    server.router.get("/text", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            res.compress = true;
            res.content_type = .text;
            res.body = comptime repeat("compressible ", 40);
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var buf: [4096]u8 = undefined;
    const head = try rawHead(io, &server, "GET /text HTTP/1.1\r\nHost: x\r\nAccept-Encoding: zstd;q=0.2, gzip;q=0.9\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Encoding: gzip") != null);
    var buf2: [4096]u8 = undefined;
    const none = try rawHead(io, &server, "GET /text HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip;q=0, *;q=0\r\nConnection: close\r\n\r\n", &buf2);
    try std.testing.expect(std.mem.indexOf(u8, none, "Content-Encoding") == null);
}

/// Counts allocations through it, for the hot-path test below.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    count: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.count.fetchAdd(1, .monotonic);
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};

test "Server: a warm HTTP/1.1 keepalive connection serves requests without allocating" {
    const io = std.testing.io;
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    var server = dusty.Server(void).init(counting.allocator(), io, .{ .listeners = loopback }, {});
    defer server.deinit();
    var request_id = dusty.middleware.RequestId.init(.{});
    server.router.use(dusty.Middleware(void).init(&request_id));
    server.router.get("/users/:id", struct {
        fn handle(req: *dusty.Request, res: *dusty.Response) !void {
            try res.print(.text, "user {s}", .{req.params.get("id").?});
        }
    }.handle);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    const stream = try server.address.ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var rbuf: [2048]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var status: [64]u8 = undefined;
    var body: [64]u8 = undefined;
    const request = "GET /users/2 HTTP/1.1\r\nHost: x\r\nUser-Agent: test\r\nAccept: */*\r\n\r\n";

    // Warm up: the request buffers, arena and maps grow to what a request
    // needs.
    for (0..5) |_| {
        try w.interface.writeAll(request);
        try w.interface.flush();
        _ = try readResponse(&r.interface, &status, &body);
    }
    const before = counting.count.load(.monotonic);
    for (0..20) |_| {
        try w.interface.writeAll(request);
        try w.interface.flush();
        try std.testing.expectEqualStrings("user 2", (try readResponse(&r.interface, &status, &body)).body);
    }
    try std.testing.expectEqual(before, counting.count.load(.monotonic));
}

test "Server: serves on an inherited listening socket (fd)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // inherited sockets (hand-off, socket activation) are Unix only
    const io = std.testing.io;
    // Opened elsewhere, as systemd or a previous process would have.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{});
    const fd = listener.socket.handle;
    const port = listener.socket.address.getPort();

    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(port) } }, .fd = fd }},
    }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn h(_: *dusty.Request, res: *dusty.Response) !void {
            res.body = "inherited";
        }
    }.h);
    var future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);
    try std.testing.expectEqual(port, server.address.ip.getPort());

    var buf: [1024]u8 = undefined;
    const resp = try rawAll(io, &server, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
    try std.testing.expect(std.mem.endsWith(u8, resp, "inherited"));
}

test "Server: a response can carry more headers than a request may" {
    const io = std.testing.io;
    var server = dusty.Server(void).init(std.testing.allocator, io, .{
        .listeners = loopback,
        .request = .{ .max_header_count = 4 },
    }, {});
    defer server.deinit();
    server.router.get("/", struct {
        fn handle(_: *dusty.Request, res: *dusty.Response) !void {
            inline for (0..40) |i| try res.header(std.fmt.comptimePrint("X-Header-{d}", .{i}), "v");
            res.body = "ok";
        }
    }.handle);

    var server_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.run, .{&server});
    defer server_future.cancel(io) catch {};

    var client_future = try io.concurrent(struct {
        fn run(s: *dusty.Server(void), _io: std.Io) !void {
            try s.ready.wait(_io);
            const stream = try s.address.ip.connect(_io, .{ .mode = .stream });
            defer stream.close(_io);
            var write_buf: [256]u8 = undefined;
            var writer = stream.writer(_io, &write_buf);
            try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(_io, &read_buf);
            var out: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out);
            _ = reader.interface.streamRemaining(&w) catch {};
            const resp = w.buffered();
            try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
            try std.testing.expect(std.mem.indexOf(u8, resp, "X-Header-39: v\r\n") != null);
        }
    }.run, .{ &server, io });
    try client_future.await(io);
}
