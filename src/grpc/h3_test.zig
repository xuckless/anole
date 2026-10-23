//! gRPC over HTTP/3 (gRFC G2) end to end: Anole's server and client over
//! QUIC, the four call modes, statuses, big messages, deadlines and
//! cancellation, and the Alt-Svc switch of an `.auto` channel.
const std = @import("std");
const features = @import("build_options");
const pb = @import("anole_test_pb");
const h2c = @import("anole_h2_client");
const grpc = @import("root.zig");
const frame = @import("frame.zig");
const tls = @import("../tls/root.zig");
const h3 = @import("../h3/root.zig");
const server_mod = @import("../server.zig");

const Server = server_mod.Server;
const Echo = pb.Echo(grpc.Call, anyerror);

/// What the "hang" and "abort" calls tell the test.
const Probe = struct {
    var started: std.Io.Event = .unset;
    var canceled: std.Io.Event = .unset;
    var gate: std.Io.Event = .unset;

    fn reset() void {
        started = .unset;
        canceled = .unset;
        gate = .unset;
    }
};

fn unary(call: *grpc.Call, req: pb.EchoRequest) anyerror!pb.EchoResponse {
    if (std.mem.eql(u8, req.message, "fail")) return call.fail(.not_found, "no such thing: fail é");
    if (std.mem.eql(u8, req.message, "hang")) {
        Probe.started.set(call.io);
        Probe.gate.wait(call.io) catch |err| {
            Probe.canceled.set(call.io);
            return err;
        };
    }
    if (std.mem.eql(u8, req.message, "abort")) return call.res.abort();
    if (std.mem.eql(u8, req.message, "alt")) try call.res.header("alt-svc", "h3=\":1\"; ma=60");
    try call.addTrailer("x-echoed", "yes");
    return .{ .message = req.message, .index = 0 };
}

fn serverStream(call: *grpc.Call, req: pb.EchoRequest, out: *std.Io.Queue(pb.EchoResponse)) anyerror!void {
    for (0..@intCast(req.repeat)) |i| try out.putOne(call.io, .{ .message = req.message, .index = @intCast(i) });
}

fn clientStream(call: *grpc.Call, in: *std.Io.Queue(pb.EchoRequest)) anyerror!pb.EchoResponse {
    var joined: std.ArrayList(u8) = .empty;
    var n: i32 = 0;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => break,
            else => |e| return e,
        };
        // "early": the answer is complete after the first message.
        if (std.mem.eql(u8, req.message, "early")) return .{ .message = "early", .index = 1 };
        try joined.appendSlice(call.arena, req.message);
        n += 1;
    }
    return .{ .message = joined.items, .index = n };
}

fn bidi(call: *grpc.Call, in: *std.Io.Queue(pb.EchoRequest), out: *std.Io.Queue(pb.EchoResponse)) anyerror!void {
    var i: i32 = 0;
    while (true) {
        const req = in.getOne(call.io) catch |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        };
        try out.putOne(call.io, .{ .message = req.message, .index = i });
        i += 1;
    }
}

const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *Server(void),
    pem: *const tls.Pem,

    /// The server's TLS port (TCP) and its UDP port.
    fn tcpPort(e: *const Env) u16 {
        return e.app.addresses()[0].ip.getPort();
    }
    fn udp(e: *const Env) std.Io.net.IpAddress {
        return e.app.http3Address().?;
    }

    fn connectH3(e: *const Env) !*h3.ClientConnection {
        const q = e.udp();
        return h3.ClientConnection.connect(e.gpa, e.io, .{
            .host = "localhost",
            .address = q,
            .port = q.getPort(),
            .tls = .{ .ca = .{ .pem = e.pem.cert } },
        });
    }

    fn connectH2(e: *const Env) !*h2c.ClientConnection {
        return h2c.ClientConnection.connect(e.gpa, e.io, .{
            .host = "localhost",
            .port = e.tcpPort(),
            .tls = .{ .ca = .{ .pem = e.pem.cert } },
        });
    }

    /// For `Channel.connect`: the same server, over TLS.
    fn options(e: *const Env) h2c.ConnectOptions {
        return .{ .host = "localhost", .port = e.tcpPort(), .address = .{ .ip4 = .loopback(e.tcpPort()) }, .tls = .{ .ca = .{ .pem = e.pem.cert } } };
    }
};

const Setup = struct {
    no_wait: bool = false,
    /// Serve HTTP/3 (the default); off, the listener is HTTP/2 only.
    http3: bool = true,
};

fn withServer(comptime setup: Setup, comptime body: fn (*Env) anyerror!void) !void {
    if (comptime features.tls != .boringssl or !features.http2 or !features.http3 or !features.grpc) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pem = try tls.selfSigned(gpa, .{});
    defer pem.deinit(gpa);
    const cert: server_mod.Options.Cert = .fromPem(pem.cert, pem.key);
    var app = try Server(void).init(gpa, .{
        .listeners = &.{.{ .name = "tls", .port = 0, .tls = .{ .cert = cert }, .http3 = setup.http3 }},
        .executors = .exact(2),
        .limits = .{ .body_max = 64 << 20 },
    }, {});
    defer app.deinit();
    app.grpcWith(Echo, .{
        .Unary = unary,
        .ServerStream = serverStream,
        .ClientStream = clientStream,
        .Bidi = bidi,
    }, .{ .no_wait = setup.no_wait });
    const Check = struct {
        fn run(a: *Server(void), p: *const tls.Pem) !void {
            defer a.stop();
            try a.waitReady();
            var env: Env = .{ .gpa = std.testing.allocator, .io = a.io(), .app = a, .pem = p };
            try body(&env);
        }
    };
    var future = try app.io().concurrent(Check.run, .{ &app, &pem });
    try app.run();
    try future.await(app.io());
}

fn newArena() std.heap.ArenaAllocator {
    return .init(std.testing.allocator);
}

test "grpc over h3: the four call modes with the typed client" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const r = try client.unary("Unary", arena, .{ .message = "over h3" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqualStrings("over h3", r.message.?.message);
            try std.testing.expectEqual(grpc.Transport.h3, r.transport);
            {
                var s = try client.stream("ServerStream", arena, .{});
                defer s.deinit();
                try s.send(.{ .message = "n", .repeat = 5 });
                try s.closeSend();
                var n: usize = 0;
                while (try s.receive()) |m| : (n += 1) try std.testing.expectEqual(@as(i32, @intCast(n)), m.index);
                try std.testing.expectEqual(@as(usize, 5), n);
                try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
            }
            {
                var s = try client.stream("ClientStream", arena, .{});
                defer s.deinit();
                for ([_][]const u8{ "x", "y", "z" }) |m| try s.send(.{ .message = m });
                try s.closeSend();
                const reply = (try s.receive()).?;
                try std.testing.expectEqualStrings("xyz", reply.message);
                try std.testing.expect(try s.receive() == null);
                try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
            }
            {
                var s = try client.stream("Bidi", arena, .{});
                defer s.deinit();
                for ([_][]const u8{ "ping", "pong", "again" }, 0..) |m, i| {
                    try s.send(.{ .message = m });
                    const reply = (try s.receive()).?;
                    try std.testing.expectEqualStrings(m, reply.message);
                    try std.testing.expectEqual(@as(i32, @intCast(i)), reply.index);
                }
                try s.closeSend();
                try std.testing.expect(try s.receive() == null);
                try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
            }
        }
    }.run);
}

test "grpc over h3: status, grpc-message and trailing metadata; an error before any message" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const ok = try client.unary("Unary", arena, .{ .message = "t" }, .{});
            var echoed = false;
            for (ok.trailers) |t| if (std.mem.eql(u8, t.name, "x-echoed") and std.mem.eql(u8, t.value, "yes")) {
                echoed = true;
            };
            try std.testing.expect(echoed);

            const failed = try client.unary("Unary", arena, .{ .message = "fail" }, .{});
            try std.testing.expectEqual(grpc.Code.not_found, failed.status.code);
            try std.testing.expectEqualStrings("no such thing: fail é", failed.status.message);
            try std.testing.expect(failed.message == null);
        }
    }.run);
}

test "grpc over h3: 4 MiB messages both ways" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const big = try arena.alloc(u8, 4 * 1024 * 1024 - 64);
            for (big, 0..) |*b, i| b.* = @truncate('a' + i % 23);
            const r = try client.unary("Unary", arena, .{ .message = big }, .{ .timeout = .fromSeconds(60) });
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqualSlices(u8, big, r.message.?.message);
        }
    }.run);
}

test "grpc over h3: a client stream the server finishes early" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var s = try client.stream("ClientStream", arena, .{ .timeout = .fromSeconds(30) });
            defer s.deinit();
            try s.send(.{ .message = "early" });
            const chunk = try arena.alloc(u8, 64 * 1024);
            @memset(chunk, 'x');
            // The server answered after the first message and stopped
            // reading: a later send fails once STOP_SENDING arrives.
            var failed = false;
            for (0..2000) |_| {
                s.send(.{ .message = chunk }) catch |err| {
                    try std.testing.expectEqual(error.StreamClosed, err);
                    failed = true;
                    break;
                };
            }
            try std.testing.expect(failed);
            const reply = (try s.receive()).?;
            try std.testing.expectEqualStrings("early", reply.message);
            try std.testing.expect(try s.receive() == null);
            try std.testing.expectEqual(grpc.Code.ok, s.status.?.code);
        }
    }.run);
}

test "grpc over h3: client deadline gives DEADLINE_EXCEEDED and the handler's wait is canceled" {
    Probe.reset();
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "hang" }, .{ .timeout = .fromMilliseconds(200) });
            try std.testing.expectEqual(grpc.Code.deadline_exceeded, r.status.code);
            // The handler's wait ended with Canceled (no time bound).
            try Probe.canceled.wait(env.io);
        }
    }.run);
}

test "grpc over h3: client cancel cancels the handler" {
    Probe.reset();
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            var s = try client.stream("Unary", arena_state.allocator(), .{});
            defer s.deinit();
            try s.send(.{ .message = "hang" });
            try s.closeSend();
            try Probe.started.wait(env.io);
            s.cancel();
            try Probe.canceled.wait(env.io);
            try std.testing.expect(try s.receive() == null);
            try std.testing.expectEqual(grpc.Code.cancelled, s.status.?.code);
        }
    }.run);
}

test "grpc over h3: a handler's abort reaches the client as CANCELLED" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "abort" }, .{});
            try std.testing.expectEqual(grpc.Code.cancelled, r.status.code);
            try std.testing.expectEqualStrings("the server canceled the call", r.status.message);
        }
    }.run);
}

test "grpc over h3: no_wait unary calls run inline" {
    try withServer(.{ .no_wait = true }, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH3();
            defer conn.close();
            var channel: grpc.Channel = .{ .h3 = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            for (0..20) |_| {
                const r = try client.unary("Unary", arena, .{ .message = "inline" }, .{});
                try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            }
            try std.testing.expect(env.app.h3.?.stats.served_inline.load(.monotonic) > 0);
        }
    }.run);
}

fn rawPost(env: *Env, content_type: []const u8, body: []const u8) !struct { head: []const u8, body: []u8 } {
    const conn = try env.connectH3();
    defer conn.close();
    const s = try conn.request(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/anole.test.Echo/Unary" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "localhost" },
        .{ .name = "content-type", .value = content_type },
    }, .{ .body = true });
    defer s.release();
    try s.writer().writeAll(body);
    try s.closeSend();
    try s.waitHead();
    const got = try s.reader().allocRemaining(env.gpa, .unlimited);
    return .{ .head = "", .body = got };
}

test "grpc over h3: gRPC-Web and Connect unary" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            var req_buf: std.Io.Writer.Allocating = .init(env.gpa);
            defer req_buf.deinit();
            const request: pb.EchoRequest = .{ .message = "web" };
            try request.encode(&req_buf.writer, env.gpa);
            const framed = try frame.encode(env.gpa, req_buf.written());
            defer env.gpa.free(framed);

            const web = try rawPost(env, "application/grpc-web+proto", framed);
            defer env.gpa.free(web.body);
            // A data frame, then a trailer frame (0x80) with the status.
            try std.testing.expect(web.body.len > 5 and web.body[0] == 0);
            try std.testing.expect(std.mem.indexOf(u8, web.body, "grpc-status: 0") != null or std.mem.indexOf(u8, web.body, "grpc-status:0") != null);

            const connect = try rawPost(env, "application/proto", req_buf.written());
            defer env.gpa.free(connect.body);
            var reader: std.Io.Reader = .fixed(connect.body);
            var arena_state = newArena();
            defer arena_state.deinit();
            const reply = try pb.EchoResponse.decode(&reader, arena_state.allocator());
            try std.testing.expectEqualStrings("web", reply.message);
        }
    }.run);
}

test "grpc: gRPC over HTTP/1.1 is still 505" {
    if (comptime features.tls != .boringssl or !features.http2 or !features.grpc) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var app = try Server(void).init(gpa, .{ .listeners = &.{.{ .name = "plain", .port = 0 }}, .executors = .exact(1) }, {});
    defer app.deinit();
    app.grpc(Echo, .{ .Unary = unary, .ServerStream = serverStream, .ClientStream = clientStream, .Bidi = bidi });
    const Check = struct {
        fn run(a: *Server(void)) !void {
            defer a.stop();
            try a.waitReady();
            const io = a.io();
            const stream = try a.addresses()[0].ip.connect(io, .{ .mode = .stream });
            defer stream.close(io);
            var wbuf: [256]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            try w.interface.writeAll("POST /anole.test.Echo/Unary HTTP/1.1\r\nHost: x\r\ncontent-type: application/grpc\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
            try w.interface.flush();
            var rbuf: [512]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            const line = try r.interface.takeDelimiterExclusive('\r');
            try std.testing.expectEqualStrings("HTTP/1.1 505 HTTP Version Not Supported", line);
        }
    };
    var future = try app.io().concurrent(Check.run, .{&app});
    try app.run();
    try future.await(app.io());
}

test "grpc over h2: Alt-Svc on gRPC responses" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const conn = try env.connectH2();
            defer conn.close();
            var channel: grpc.Channel = .{ .conn = conn, .authority = "localhost", .scheme = "https" };
            const client: grpc.Client(Echo) = .{ .channel = &channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "x" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqual(grpc.Transport.h2, r.transport);
            var want_buf: [64]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "h3=\":{d}\"; ma=86400", .{env.udp().getPort()});
            var found = false;
            for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "alt-svc")) {
                try std.testing.expectEqualStrings(want, h.value);
                found = true;
            };
            try std.testing.expect(found);
        }
    }.run);
}

test "grpc channel .auto: the first call goes over h2, the next over h3" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            const channel = try grpc.Channel.connect(env.gpa, env.io, env.options(), .{ .http = .auto });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const first = try client.unary("Unary", arena, .{ .message = "1" }, .{});
            try std.testing.expectEqual(grpc.Transport.h2, first.transport);
            const second = try client.unary("Unary", arena, .{ .message = "2" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, second.status.code);
            try std.testing.expectEqual(grpc.Transport.h3, second.transport);
            try std.testing.expectEqual(grpc.Transport.h3, channel.transport());
        }
    }.run);
}

test "grpc channel .auto: HTTP/3 unreachable, calls stay on h2" {
    // The listener has no HTTP/3; the "alt" call advertises UDP port 1.
    try withServer(.{ .http3 = false }, struct {
        fn run(env: *Env) !void {
            const channel = try grpc.Channel.connect(env.gpa, env.io, env.options(), .{
                .http = .auto,
                .http3 = .{ .connect_timeout = .fromMilliseconds(300) },
            });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const first = try client.unary("Unary", arena, .{ .message = "alt" }, .{});
            try std.testing.expectEqual(grpc.Transport.h2, first.transport);
            for (0..2) |_| {
                const r = try client.unary("Unary", arena, .{ .message = "again" }, .{});
                try std.testing.expectEqual(grpc.Code.ok, r.status.code);
                try std.testing.expectEqual(grpc.Transport.h2, r.transport);
            }
            // One dial attempt, then HTTP/3 is given up on for a while.
            try std.testing.expectEqual(@as(u32, 1), channel.h3DialCount());
        }
    }.run);
}

test "grpc channel .h3: prior knowledge over a channel that owns its connection" {
    try withServer(.{}, struct {
        fn run(env: *Env) !void {
            var opts = env.options();
            opts.port = env.udp().getPort();
            opts.address = env.udp();
            const channel = try grpc.Channel.connect(env.gpa, env.io, opts, .{ .http = .h3 });
            defer channel.close();
            const client: grpc.Client(Echo) = .{ .channel = channel };
            var arena_state = newArena();
            defer arena_state.deinit();
            const r = try client.unary("Unary", arena_state.allocator(), .{ .message = "pk" }, .{});
            try std.testing.expectEqual(grpc.Code.ok, r.status.code);
            try std.testing.expectEqual(grpc.Transport.h3, r.transport);
        }
    }.run);
}
