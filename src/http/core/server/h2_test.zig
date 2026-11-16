// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! HTTP/2 engine behaviour tests: a core server with cleartext HTTP/2
//! (prior knowledge) on loopback, driven by a minimal client on the core's
//! own client role (h2/test_client.zig).
//! Everything here is observable on the wire (status, bytes, frames, flow
//! control, resets, drain, limits, timeouts), so the same tests run on
//! every engine in `harness.engines` (one now).
const std = @import("std");
const dusty = @import("../root.zig");
const build_options = @import("build_options");
const tls = @import("tls");
const wait = @import("anole_test_wait");
const test_socket = @import("test_socket.zig");
const harness = @import("h2_harness_test.zig");
const ErrorCode = harness.ErrorCode;
const anole_h2 = @import("../h2/server.zig");

const loopback_addr = harness.loopback_addr;
const TestClient = harness.TestClient;
const Handlers = harness.Handlers;
const SentGate = harness.SentGate;
const default_window = harness.default_window;
const CountingAllocator = harness.CountingAllocator;
const preface = harness.preface;
const awaitStreamsFreed = harness.awaitStreamsFreed;

test {
    inline for (harness.engines) |e| _ = Behaviour(e);
}

pub fn Behaviour(comptime e: harness.Engine) type {
    return struct {
        const E = harness.Desc(e);
        const Fixture = harness.Fixture(E);

        test "HTTP/2: GET over prior-knowledge h2c reaches the router" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const ok = try client.request("GET", "/hello", null);
            const head = try client.request("HEAD", "/hello", null);
            const missing = try client.request("GET", "/nope", null);
            try client.run();

            try std.testing.expectEqual(@as(u16, 200), client.get(ok).status);
            try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
            try std.testing.expect(client.get(ok).has_date);
            try std.testing.expectEqual(@as(u16, 200), client.get(head).status);
            try std.testing.expectEqualStrings("5", client.get(head).content_length.?);
            try std.testing.expectEqualStrings("", client.get(head).body.items);
            try std.testing.expectEqual(@as(u16, 404), client.get(missing).status);
        }

        test "HTTP/2: a whole body ends on its DATA frame, an empty one on HEADERS" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const ok = try client.request("GET", "/hello", null);
            const head = try client.request("HEAD", "/hello", null);
            const inline_ok = try client.request("GET", "/nw/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
            try std.testing.expectEqualStrings("hello", client.get(inline_ok).body.items);
            try std.testing.expectEqual(@as(u16, 200), client.get(head).status);
            try std.testing.expectEqual(@as(usize, 0), client.empty_ends);
        }

        test "HTTP/2: no_wait routes answer from the reader, beside tasks, past the window" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            try std.testing.expect(fx.server.router.has_no_wait);

            const body = try std.testing.allocator.alloc(u8, 300 * 1024 + 7);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 13);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            var ids: [16]i32 = undefined;
            var paths: [16][16]u8 = undefined;
            for (&ids, 0..) |*id, i| {
                const path = try std.fmt.bufPrint(&paths[i], "/nw/users/{d}", .{i});
                id.* = try client.request("GET", path, null);
            }
            const task = try client.request("GET", "/users/x", null);
            const trailers = try client.request("GET", "/nw/trailers", null);
            // Streamed from the reader far past the client's stream window: the
            // reader must not wait for the writer, which waits for WINDOW_UPDATEs
            // only the reader takes in.
            const big = try client.request("GET", "/nw/big", null);
            // With a body: not whole on its HEADERS, so it gets a task.
            const echoed = try client.request("POST", "/nw/echo", body);
            const head = try client.request("HEAD", "/nw/hello", null);
            const query = try client.request("GET", "/nw/hello?x=1", null);
            try client.run();

            for (ids, 0..) |id, i| {
                var expect: [16]u8 = undefined;
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "user {d}", .{i}), client.get(id).body.items);
            }
            try std.testing.expectEqualStrings("user x", client.get(task).body.items);
            try std.testing.expectEqualStrings("with trailers", client.get(trailers).body.items);
            try std.testing.expectEqualStrings("yes", client.get(trailers).trailer.?);
            try std.testing.expectEqual(@as(usize, Handlers.big_len), client.get(big).body.items.len);
            try std.testing.expect(std.mem.endsWith(u8, client.get(big).body.items, "999\n"));
            try std.testing.expect(std.mem.eql(u8, body, client.get(echoed).body.items));
            try std.testing.expectEqualStrings("5", client.get(head).content_length.?);
            try std.testing.expectEqualStrings("", client.get(head).body.items);
            try std.testing.expectEqualStrings("hello", client.get(query).body.items);
        }

        test "HTTP/2: a no_wait request with a body runs inline when it came whole, else on a task" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            const body = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 + 5);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 77 +% (i >> 13));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            var ids: [8]i32 = undefined;
            for (&ids, 0..) |*id, i| id.* = try client.request("POST", "/nw/sum", body[0 .. i * 100]);
            // Past the stream window: it cannot come whole before someone reads.
            const big = try client.request("POST", "/nw/sum", body);
            try client.run();
            var expect: [64]u8 = undefined;
            for (ids, 0..) |id, i| {
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ i * 100, std.hash.Wyhash.hash(0, body[0 .. i * 100]) }), client.get(id).body.items);
            }
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(big).body.items);
        }

        test "HTTP/2: a no_wait request reset with its body half sent lets its handler go, and the connection carries on" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var body: [1000]u8 = undefined;
            for (&body, 0..) |*b, i| b.* = @truncate(i *% 77 +% (i >> 13));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            var expect: [64]u8 = undefined;
            const sums = Handlers.sum_entered.load(.acquire);
            const cut = try client.request("POST", "/nw/sum", body[0..1000]);
            client.get(cut).src.keep_open = true;
            try client.sendPending();
            // The server has the stream: its handler runs (and waits for the rest).
            try wait.waitAtLeast(io, "the half-sent request's handler runs", &Handlers.sum_entered, sums + 1);
            try client.reset(cut, .cancel);
            const after = try client.request("POST", "/nw/sum", body[0..10]);
            try client.run();
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ 10, std.hash.Wyhash.hash(0, body[0..10]) }), client.get(after).body.items);
        }

        test "HTTP/2: a body window raised before the client acknowledged SETTINGS never outgrows its buffer" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            const body = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024 + 5);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("POST", "/stall", body);
            // The handler stops after `stall_credit` until the client has sent
            // that plus the window's first raised step (256 KiB): that window
            // filled again behind a handler that does not read (a window raised
            // further meanwhile only opens the gate sooner).
            Handlers.stall_gate = .unset;
            const resps = [_]*const TestClient.Resp{client.get(id)};
            const gate: SentGate = .{ .resps = &resps, .n = Handlers.stall_credit + 256 * 1024 };
            var releaser = try io.concurrent(SentGate.release, .{ io, &gate, &Handlers.stall_gate });
            defer releaser.cancel(io) catch {};
            // The preface, SETTINGS, the head and a default window of the body,
            // then nothing until the handler's first read has raised the stream's
            // window: the client's ACK of the server's SETTINGS (whose initial
            // window differs from the default) arrives after the raise.
            try client.sendPending();
            try client.recvUntilStreamWindowUpdate();
            try client.run();
            try releaser.await(io);
            var expect: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(id).body.items);
        }

        test "HTTP/2: the window a handler's read raises is sent even when the handler writes nothing" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            Handlers.raise_gate = .unset;
            Handlers.raise_rest_gate = .unset;
            // Last in, first out: a failed wait below lets the handler go
            // before the server stops.
            defer Handlers.raise_gate.set(io);
            defer Handlers.raise_rest_gate.set(io);

            const body = try std.testing.allocator.alloc(u8, 256 * 1024 + 3);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("POST", "/raise", body);
            // The default window of the body, and a PING answered after the
            // server's SETTINGS (whose stream window is one byte more).
            try client.ping();
            try client.runUntilPingAck();
            // That byte, then a PING behind it: its answer means the server
            // has read the whole window, so the handler's first read raises it.
            try client.sendPending();
            try std.testing.expectEqual(@as(usize, 65536), client.get(id).src.sent);
            try client.ping();
            try client.runUntilPingAck();
            try std.testing.expectEqual(@as(usize, 0), client.stream_window_updates);
            // The handler reads one byte and waits: no write of its own, no
            // credit due for one byte, and nothing more from the client,
            // whose window is spent. Only the raise can move it.
            Handlers.raise_gate.set(io);
            try client.recvUntilStreamWindowUpdate();
            Handlers.raise_rest_gate.set(io);
            try client.run();
            var expect: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(id).body.items);
        }

        test "HTTP/2: a handler waiting for its body gets a DATA frame's first bytes before the rest of the frame" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const warm = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);

            // A head without END_STREAM; the body goes by hand below, so a frame
            // can stop in the middle.
            Handlers.reader_got.store(0, .release);
            const entered = Handlers.reader_entered.load(.acquire);
            const id = try client.requestOpen("POST", "/reader", &.{});
            const resp = client.get(id);
            try client.sendPending();
            try wait.waitAtLeast(io, "the body reader's handler runs", &Handlers.reader_entered, entered + 1);

            var body: [100]u8 = undefined;
            for (&body, 0..) |*b, i| b.* = @truncate(i *% 13 +% 7);
            const sid: u32 = @intCast(id);
            // A DATA frame of 100 bytes, of which only the first 10 are sent.
            const data_head = [9]u8{ 0, 0, body.len, 0x0, 0x0, @truncate(sid >> 24), @truncate(sid >> 16), @truncate(sid >> 8), @truncate(sid) };
            try client.w.writeAll(&data_head);
            try client.w.writeAll(body[0..10]);
            try client.w.flush();
            try wait.waitAtLeast(io, "the handler read the first bytes of the unfinished frame", &Handlers.reader_got, 10);
            // The rest of the frame, then an empty one that ends the body.
            const end_head = [9]u8{ 0, 0, 0, 0x0, 0x1, @truncate(sid >> 24), @truncate(sid >> 16), @truncate(sid >> 8), @truncate(sid) };
            try client.w.writeAll(body[10..]);
            try client.w.writeAll(&end_head);
            try client.w.flush();
            try client.runUntilAnswered(id);
            var expect: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, &body) }), resp.body.items);
        }

        test "HTTP/2: a connection counts once in the server's in-flight requests, however many streams it has open" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            Handlers.held_gate = .unset;
            const entered = Handlers.held_entered.load(.acquire);
            var ids: [5]i32 = undefined;
            for (&ids) |*id| id.* = try client.request("GET", "/held", null);
            try client.sendPending();
            try wait.waitAtLeast(io, "every held request is in its handler", &Handlers.held_entered, entered + @as(u32, ids.len));
            try std.testing.expectEqual(@as(u31, 1), fx.server.busy.load(.acquire).count);
            Handlers.held_gate.set(io);
            try client.run();
            for (ids) |id| try std.testing.expectEqualStrings("held but whole", client.get(id).body.items);
            // Given back once the last response is flushed.
            try wait.waitUntil(io, "the connection's count went back", &fx.server, struct {
                fn idle(server: *E.Server(void)) bool {
                    return server.busy.load(.acquire).count == 0;
                }
            }.idle);
        }

        test "HTTP/2: a no_wait handler that waits anyway still answers, holding up its connection" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const slow = try client.request("GET", "/nw/slow", null);
            const hello = try client.request("GET", "/nw/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("slow but whole", client.get(slow).body.items);
            try std.testing.expectEqualStrings("hello", client.get(hello).body.items);
            // Run in turn on the reader, so the quick one waited for the slow one.
            try std.testing.expect(client.get(slow).close_seq < client.get(hello).close_seq);

            // On tasks, the quick one does not wait: it is answered while the
            // other is still held (a gate, not a race against a sleep).
            Handlers.held_gate = .unset;
            const held_task = try client.request("GET", "/held", null);
            const hello_task = try client.request("GET", "/hello", null);
            try client.runUntilDone(hello_task);
            try std.testing.expect(!client.get(held_task).closed);
            Handlers.held_gate.set(io);
            try client.run();
            try std.testing.expectEqualStrings("held but whole", client.get(held_task).body.items);
            try std.testing.expect(client.get(hello_task).close_seq < client.get(held_task).close_seq);
        }

        test "HTTP/2: many streams multiplexed on one connection" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            var ids: [32]i32 = undefined;
            var paths: [32][16]u8 = undefined;
            for (&ids, 0..) |*id, i| {
                const path = try std.fmt.bufPrint(&paths[i], "/users/{d}", .{i});
                id.* = try client.request("GET", path, null);
            }
            try client.run();
            for (ids, 0..) |id, i| {
                var expect: [16]u8 = undefined;
                try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "user {d}", .{i}), client.get(id).body.items);
            }
        }

        test "HTTP/2: a request body larger than the windows is echoed back whole" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            const body = try std.testing.allocator.alloc(u8, 1024 * 1024 + 123);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 11));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("POST", "/echo", body);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqual(body.len, client.get(id).body.items.len);
            try std.testing.expect(std.mem.eql(u8, body, client.get(id).body.items));
        }

        test "HTTP/2: a body read late moves to the bigger window whole and in order" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            // A stream window's worth queues before the handler reads; the rest
            // comes through the window the first read raises.
            const body = try std.testing.allocator.alloc(u8, 3 * 1024 * 1024 + 17);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 131 +% (i >> 9));

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const a = try client.request("POST", "/late", body);
            const b = try client.request("POST", "/late", body[0 .. 70 * 1024]);
            Handlers.late_gate = .unset;
            const resps = [_]*const TestClient.Resp{ client.get(a), client.get(b) };
            const gate: SentGate = .{
                .resps = &resps,
                .n = default_window,
                .entered = &Handlers.late_entered,
                .want = Handlers.late_entered.load(.acquire) + 2,
            };
            var releaser = try io.concurrent(SentGate.release, .{ io, &gate, &Handlers.late_gate });
            defer releaser.cancel(io) catch {};
            try client.run();
            try releaser.await(io);
            var expect: [64]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(a).body.items);
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ 70 * 1024, std.hash.Wyhash.hash(0, body[0 .. 70 * 1024]) }), client.get(b).body.items);
        }

        test "HTTP/2: trailers follow the body" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/trailers", null);
            try client.run();
            try std.testing.expectEqualStrings("with trailers", client.get(id).body.items);
            try std.testing.expectEqualStrings("yes", client.get(id).trailer.?);
        }

        test "HTTP/2: a small unread request body is read and dropped, and the stream ends cleanly" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            const body = try std.testing.allocator.alloc(u8, 20 * 1024);
            defer std.testing.allocator.free(body);
            @memset(body, 'y');

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("POST", "/ignore", body);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualStrings("not reading that", client.get(id).body.items);
            try std.testing.expectEqual(ErrorCode.no_error, client.get(id).error_code);
            // Ended by both sides' END_STREAM: the client's went out with the
            // whole body, and no RST_STREAM came.
            try std.testing.expectEqual(body.len, client.get(id).src.sent);
            try std.testing.expectEqual(@as(usize, 0), client.get(id).rsts);
        }

        test "HTTP/2: an unread request body gets the whole response, then RST_STREAM(NO_ERROR)" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            const body = try std.testing.allocator.alloc(u8, 300 * 1024);
            defer std.testing.allocator.free(body);
            @memset(body, 'x');

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("POST", "/ignore", body);
            try client.run();
            const resp = client.get(id);
            try std.testing.expectEqual(@as(u16, 200), resp.status);
            try std.testing.expectEqualStrings("not reading that", resp.body.items);
            // One RST_STREAM, with NO_ERROR, once the whole response was in.
            try std.testing.expectEqual(@as(usize, 1), resp.rsts);
            try std.testing.expectEqual(resp.body.items.len, resp.body_at_rst);
            try std.testing.expectEqual(ErrorCode.no_error, resp.error_code);
        }

        test "HTTP/2: HTTP/1.1 still works on a prior-knowledge listener" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client = dusty.Client.init(std.testing.allocator, io, .{});
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/hello", .{fx.server.address.ip.getPort()});
            var response = try client.fetch(url, .{});
            defer response.deinit();
            try std.testing.expectEqual(.ok, response.status());
            try std.testing.expectEqualStrings("hello", (try response.body()).?);
        }

        test "HTTP/2: over TLS, chosen through ALPN" {
            if (!build_options.use_tls) return error.SkipZigTest;
            const io = std.testing.io;
            // The self-signed test certificate made at build time, as in client_test.zig.
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .tls = .{
                    .cert_path = "certs/cert.pem",
                    .key_path = "certs/key.pem",
                    .alpn_protocols = &.{ "h2", "http/1.1" },
                } }},
            }, {});
            defer server.deinit();
            server.router.get("/hello", Handlers.hello);
            server.router.post("/echo", Handlers.echo);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            const ca: dusty.Ca = .{ .file = "certs/cert.pem" };
            var bundle = try ca.load(std.testing.allocator, io);
            defer bundle.deinit(std.testing.allocator);

            const body = try std.testing.allocator.alloc(u8, 200 * 1024);
            defer std.testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 7);

            var client: TestClient = undefined;
            try client.initTls(std.testing.allocator, io, server.address.ip, &bundle);
            defer client.deinit();
            const hello = try client.request("GET", "/hello", null);
            const echoed = try client.request("POST", "/echo", body);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(hello).body.items);
            try std.testing.expect(std.mem.eql(u8, body, client.get(echoed).body.items));
        }

        test "HTTP/2: a body past its content-length resets only its stream" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const short = [_]TestClient.Field{TestClient.nv("content-length", "5")};
            const id = try client.requestHeaders("POST", "/nw/sum", &short, "123456789");
            try client.run();
            try std.testing.expectEqual(ErrorCode.protocol_error, client.get(id).error_code);
            const after = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(after).body.items);
        }

        test "HTTP/2: a body the buffer budget can't hold gets 503 on its stream, and the connection carries on" {
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                .buffer_budget = 1024,
            }, {});
            defer server.deinit();
            server.router.get("/hello", Handlers.hello);
            server.router.post("/len", struct {
                fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                    const b = try req.body();
                    try res.print(.text, "{d}", .{if (b) |x| x.len else 0});
                }
            }.handle);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, server.address.ip);
            defer client.deinit();
            // Another holder fills the executor's budget (the slow senders of the
            // HTTP/1.1 test, src/http/core/budget_test.zig).
            const row = &server.admission.rows[0];
            row.held_bytes.store(1024, .monotonic);
            const len = [_]TestClient.Field{TestClient.nv("content-length", "9")};
            const refused = try client.requestHeaders("POST", "/len", &len, "123456789");
            try client.run();
            try std.testing.expectEqual(@as(u16, 503), client.get(refused).status);
            try std.testing.expectEqual(@as(u64, 1), server.admission.refused_memory.load(.monotonic));
            const after = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(after).body.items);
            // With the budget free, the same body passes and gives its share back.
            row.held_bytes.store(0, .monotonic);
            const ok = try client.requestHeaders("POST", "/len", &len, "123456789");
            try client.run();
            try std.testing.expectEqualStrings("9", client.get(ok).body.items);
            try std.testing.expectEqual(@as(usize, 0), row.held_bytes.load(.monotonic));
        }

        /// A no_wait handler that detaches, then reads the body from the moved
        /// request and finishes from inside the handler: the body is first
        /// collected by the copy, after the original's chain has nothing to give
        /// back.
        const DetachedBody = struct {
            var ctx: u8 = 0;
            fn abort(_: *anyopaque) void {}
            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                const d = try res.detach(req, .{ .abort = abort, .ctx = &ctx });
                const b = try d.request.body();
                try d.response.print(.text, "{d}", .{if (b) |x| x.len else 0});
                d.finish({});
            }
        };

        test "HTTP/2: a body read from a detached request gives its share of the buffer budget back when the exchange ends" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.addRouteWith(.post, "/nw/detached-body", DetachedBody.handle, .{ .no_wait = true });

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const len = [_]TestClient.Field{TestClient.nv("content-length", "9")};
            const id = try client.requestHeaders("POST", "/nw/detached-body", &len, "123456789");
            try client.run();
            try std.testing.expectEqualStrings("9", client.get(id).body.items);
            try std.testing.expectEqual(@as(usize, 0), fx.server.admission.rows[0].held_bytes.load(.monotonic));
        }

        fn tasksAre(server: *E.Server(void), n: u32) bool {
            return server.admission.rows[0].tasks.load(.monotonic) == n;
        }

        fn waitTasks(io: std.Io, server: *E.Server(void), n: u32) !void {
            const S = struct { s: *E.Server(void), n: u32 };
            try wait.waitUntil(io, "the executor's request tasks", S{ .s = server, .n = n }, struct {
                fn f(x: S) bool {
                    return tasksAre(x.s, x.n);
                }
            }.f);
        }

        test "HTTP/2: idle connections leave the task cap's last quarter to streams; past the cap a stream is refused, and served once a slot frees" {
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                // Accepts stop at 2: one HTTP/2 connection's reader and the slot
                // its run holds for a flusher.
                .max_tasks = 3,
            }, {});
            defer server.deinit();
            server.router.get("/hello", Handlers.hello);
            server.router.get("/wait", Waiter.handle);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, server.address.ip);
            defer client.deinit();
            const first = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(first).body.items);
            try waitTasks(io, &server, 2);

            // A second connection waits at the accept: it can't take the slot
            // the first connection's streams need.
            var idle: TestClient = undefined;
            try idle.init(std.testing.allocator, io, server.address.ip);
            defer idle.deinit();
            try wait.waitAtLeast(io, "the accept waiting below the task cap", &server.admission.refused_tasks, 1);

            // So a stream still gets a task...
            const waiting = try client.request("GET", "/wait", null);
            try Waiter.start(&client, io);
            try std.testing.expect(tasksAre(&server, 3));
            // ...and one past the cap is refused, safe to retry.
            const refused = try client.request("GET", "/hello", null);
            try client.runUntilDone(refused);
            try std.testing.expectEqual(ErrorCode.refused_stream, client.get(refused).error_code);
            try std.testing.expectEqual(@as(u64, 2), server.admission.refused_tasks.load(.monotonic));

            try client.reset(waiting, .cancel);
            try client.runUntilDone(waiting);
            try Waiter.expectLetGo(io);
            try waitTasks(io, &server, 2);
            const again = try client.request("GET", "/hello", null);
            try client.runUntilDone(again);
            try std.testing.expectEqualStrings("hello", client.get(again).body.items);
        }

        /// `count` held requests at once on `client`, all in their handlers
        /// before any answers: the connection needs that many streams.
        fn heldBurst(client: *TestClient, io: std.Io, count: u32) !void {
            Handlers.held_gate = .unset;
            const entered = Handlers.held_entered.load(.acquire);
            var ids: [128]i32 = undefined;
            for (ids[0..count]) |*id| id.* = try client.request("GET", "/held", null);
            try client.sendPending();
            // The test client reads nothing meanwhile: the server's frames wait in
            // the socket, and none of the requests can finish before the gate.
            try wait.waitAtLeast(io, "every held request is in its handler", &Handlers.held_entered, entered + count);
            Handlers.held_gate.set(io);
            try client.run();
            for (ids[0..count]) |id| try std.testing.expectEqualStrings("held but whole", client.get(id).body.items);
        }

        test "HTTP/2: a burst's spare streams go after two quiet trim intervals, down to 16" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            try heldBurst(&client, io, 40);
            try awaitStreamsFreed(&fx.server, io);
            try std.testing.expectEqual(@as(usize, 40), @field(fx.server, E.registry).sparesForTest());
            // Each round: a trim interval passes, and one request makes the
            // reader look (its idle check). The first trim sets the low-water
            // mark; the next frees what sat unused since. Three rounds hold two
            // trims after the burst, whichever idle check the first one lands on.
            for (0..3) |_| {
                _ = E.mod.test_trim_epoch.fetchAdd(1, .monotonic);
                const id = try client.request("GET", "/hello", null);
                try client.run();
                try std.testing.expectEqualStrings("hello", client.get(id).body.items);
                // One reader takes the connection's input in order, so the
                // ACK of a second PING, sent once the first one's is in, means
                // the reader went through its idle check after the request.
                for (0..2) |_| {
                    try client.ping();
                    try client.runUntilPingAck();
                }
                try awaitStreamsFreed(&fx.server, io);
            }
            // The floor, plus the one stream a round's request may have held
            // while the trim ran.
            const left = @field(fx.server, E.registry).sparesForTest();
            try std.testing.expect(left >= 16 and left <= 17);
        }

        /// Sets `gate` once `client` has taken both of the drain's GOAWAYs: a
        /// response held until then is in flight through the whole drain, however
        /// slow the machine. Not on the first: the test is over when the stream
        /// closes, and a response that closed it before the final GOAWAY arrived
        /// would leave that GOAWAY unread.
        fn releaseOnFinalGoaway(io: std.Io, client: *const TestClient, gate: *std.Io.Event) std.Io.Cancelable!void {
            defer gate.set(io);
            wait.waitUntil(io, "the client took the drain's final GOAWAY", client, struct {
                fn f(cl: *const TestClient) bool {
                    return @atomicLoad(usize, &cl.goaway_count, .acquire) >= 2;
                }
            }.f) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.WaitTimedOut => {},
            };
        }

        fn stopFixture(f: *Fixture, io: std.Io) void {
            f.future.cancel(io) catch {};
        }

        test "HTTP/2: a drain closes an idle connection with GOAWAY at once" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.server.deinit();

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);

            const started: std.Io.Clock.Timestamp = .now(io, .awake);
            var stopper = try io.concurrent(stopFixture, .{ &fx, io });
            defer stopper.await(io);

            // A client with nothing open takes the GOAWAY notice as the end and
            // closes; the server's side ends with it, well before the notice's
            // one-second fallback.
            try client.runUntilClosed();
            try std.testing.expect(client.goaway_count >= 1);
            try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
            if (wait.timing()) try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 900);
        }

        test "HTTP/2: a drain with a stream in flight sends a two-phase GOAWAY and finishes the stream" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.server.deinit();

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const warm = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);

            // Start a request held until both of the drain's GOAWAYs reached the
            // client, then shut down while it runs.
            Handlers.held_gate = .unset;
            const helds = Handlers.held_entered.load(.acquire);
            const id = try client.request("GET", "/held", null);
            try client.sendPending();
            try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
            var releaser = try io.concurrent(releaseOnFinalGoaway, .{ io, &client, &Handlers.held_gate });
            defer releaser.cancel(io) catch {};
            var stopper = try io.concurrent(stopFixture, .{ &fx, io });
            defer stopper.await(io);

            try client.runUntilClosed();
            // The notice (the largest stream ID), answered with the PING ack,
            // then the final GOAWAY naming the slow stream as the last one taken.
            try std.testing.expectEqual(@as(usize, 2), client.goaway_count);
            try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), client.goaways[0]);
            try std.testing.expectEqual(id, client.goaways[1]);
            const resp = client.get(id);
            try std.testing.expectEqual(@as(u16, 200), resp.status);
            try std.testing.expectEqualStrings("held but whole", resp.body.items);
        }

        test "HTTP/2: a drain resets an answered stream whose client keeps its request side open" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.server.deinit();

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            // Answered without reading the body; the client never ends its side,
            // so the stream is left discarding when the drain starts.
            const id = try client.request("POST", "/ignore", "x");
            client.get(id).src.keep_open = true;
            try client.runUntilAnswered(id);
            try std.testing.expect(!client.get(id).closed);

            var stopper = try io.concurrent(stopFixture, .{ &fx, io });
            defer stopper.await(io);
            // The stream ends with the server's RST_STREAM(NO_ERROR), not with the
            // connection at the drain's deadline (#141).
            try client.runUntilClosed();
            const resp = client.get(id);
            try std.testing.expectEqualStrings("not reading that", resp.body.items);
            try std.testing.expect(resp.closed);
            try std.testing.expectEqual(@as(usize, 1), resp.rsts);
            try std.testing.expectEqual(ErrorCode.no_error, resp.error_code);
        }

        test "HTTP/2: a stream answered during a drain whose client keeps its request side open is reset" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.server.deinit();

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            // A request whose client never ends its side, held until both of the
            // drain's GOAWAYs reached the client: its handler answers during the
            // drain without reading the body.
            Handlers.held_gate = .unset;
            const helds = Handlers.held_entered.load(.acquire);
            const id = try client.request("GET", "/held", "x");
            client.get(id).src.keep_open = true;
            try client.sendPending();
            try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
            var releaser = try io.concurrent(releaseOnFinalGoaway, .{ io, &client, &Handlers.held_gate });
            defer releaser.cancel(io) catch {};
            var stopper = try io.concurrent(stopFixture, .{ &fx, io });
            defer stopper.await(io);

            // The stream ends with the server's RST_STREAM(NO_ERROR) right after
            // the response, not with the connection at the drain's deadline (#141).
            try client.runUntilClosed();
            const resp = client.get(id);
            try std.testing.expectEqualStrings("held but whole", resp.body.items);
            try std.testing.expect(resp.closed);
            try std.testing.expectEqual(@as(usize, 1), resp.rsts);
            try std.testing.expectEqual(ErrorCode.no_error, resp.error_code);
        }

        test "HTTP/2: a PROXY protocol header ahead of TLS names the client of an h2 stream" {
            if (!build_options.use_tls) return error.SkipZigTest;
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .proxy_protocol = true, .tls = .{
                    .cert_path = "certs/cert.pem",
                    .key_path = "certs/key.pem",
                    .alpn_protocols = &.{ "h2", "http/1.1" },
                } }},
            }, {});
            defer server.deinit();
            server.router.get("/who", Handlers.who);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            const ca: dusty.Ca = .{ .file = "certs/cert.pem" };
            var bundle = try ca.load(std.testing.allocator, io);
            defer bundle.deinit(std.testing.allocator);

            // The header is read to its last byte and no further: the ClientHello
            // right behind it still reaches the handshake whole.
            var client: TestClient = undefined;
            try client.initTlsAfter(std.testing.allocator, io, server.address.ip, &bundle, "PROXY TCP4 192.0.2.44 198.51.100.2 40000 443\r\n");
            defer client.deinit();
            const id = try client.request("GET", "/who", null);
            try client.run();
            try std.testing.expectEqualStrings("192.0.2.44:40000 secure=true", client.get(id).body.items);
        }

        test "HTTP/2: an extended CONNECT (RFC 8441) reaches a GET route with Request.protocol set" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/tunnel", struct {
                fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                    try std.testing.expectEqualStrings("websocket", req.protocol.?);
                    res.compress = true; // never applies to a tunnel
                    try Handlers.echo(req, res);
                }
            }.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            // The server's SETTINGS (with ENABLE_CONNECT_PROTOCOL) must be in before
            // a client may send :protocol.
            const warm = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);
            try std.testing.expect(client.connectProtocolAllowed());

            const id = try client.requestProtocol("CONNECT", "/tunnel", "websocket", "tunnelled bytes");
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualStrings("tunnelled bytes", client.get(id).body.items);
        }

        test "HTTP/2: a file body goes out whole" {
            // The engine's body writer takes its first block only when bytes come;
            // `sendFileAll` asserts a buffered writer (Response.sendFileBody gives
            // it one first).
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var content: [100 * 1024 + 7]u8 = undefined;
            for (&content, 0..) |*b, i| b.* = @truncate(i *% 7 +% (i >> 8));
            try tmp.dir.writeFile(io, .{ .sub_path = "body.bin", .data = &content });
            harness.file_dir = tmp.dir;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/file", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualSlices(u8, &content, client.get(id).body.items);
        }

        test "HTTP/2: a file body goes out whole on an extended CONNECT" {
            // An extended CONNECT is served as a GET, its body copied to the
            // stream's chain, whose writer keeps no buffer: Response.sendFileBody
            // copies the file through one of its own (`rebase` refuses there).
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var content: [40 * 1024 + 3]u8 = undefined;
            for (&content, 0..) |*b, i| b.* = @truncate(i *% 5 +% (i >> 7));
            try tmp.dir.writeFile(io, .{ .sub_path = "body.bin", .data = &content });
            harness.file_dir = tmp.dir;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            // The server's SETTINGS (with ENABLE_CONNECT_PROTOCOL) must be in before
            // a client may send :protocol.
            const warm = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);
            const id = try client.requestProtocol("CONNECT", "/file", "websocket", null);
            try client.runUntilDone(id);
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualSlices(u8, &content, client.get(id).body.items);
        }

        test "HTTP/2: a client that half-closes still gets the responses in flight, past the server's probe" {
            // The engine that serves has no `test_after_peer_end`: its half-close
            // probe (a PING, once it has read the EOF with a handler running) is
            // the sync point, and the handler answers only after it.
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            Handlers.held_gate = .unset;
            const helds = Handlers.held_entered.load(.acquire);
            const id = try client.request("GET", "/held", null);
            try client.sendPending();
            try wait.waitAtLeast(io, "the held request's handler runs", &Handlers.held_entered, helds + 1);
            try client.stream.shutdown(io, .send);
            var gate_open = false;
            while (!client.get(id).closed) {
                try client.pump();
                if (!gate_open and client.pings > 0) {
                    Handlers.held_gate.set(io);
                    gate_open = true;
                }
            }
            try std.testing.expect(gate_open);
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualStrings("held but whole", client.get(id).body.items);
        }

        test "HTTP/2: a finished tunnel is reset even when the peer keeps its side open" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/brief", struct {
                fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                    _ = req;
                    res.body = "done";
                }
            }.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const warm = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(warm).status);
            const id = try client.requestProtocol("CONNECT", "/brief", "websocket", "x");
            client.get(id).src.keep_open = true;
            // Returns once the stream closes: the response ends it from the
            // server's side, and an RST_STREAM(NO_ERROR) from the client's.
            try client.run();
            try std.testing.expectEqualStrings("done", client.get(id).body.items);
            try std.testing.expectEqual(ErrorCode.no_error, client.get(id).error_code);
        }

        /// A handler that waits up to 60 s for its client to leave. On zio the
        /// wait itself is canceled; elsewhere `peerGone` tells. `let_go` says the
        /// client's leaving ended it, not the end of its wait.
        const Waiter = struct {
            var done: std.atomic.Value(bool) = .init(false);
            var started: std.atomic.Value(bool) = .init(false);
            var let_go: std.atomic.Value(bool) = .init(false);

            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                started.store(true, .release);
                defer done.store(true, .release);
                for (0..1200) |_| {
                    req.io.sleep(.fromMilliseconds(50), .awake) catch |err| {
                        let_go.store(true, .release);
                        return err;
                    };
                    if (res.peerGone()) {
                        let_go.store(true, .release);
                        return;
                    }
                }
                res.body = "nobody asked";
            }

            /// Sends what the client has queued (the request) and waits until the
            /// handler is running (a fixed sleep was not enough on a busy Windows
            /// runner: the reset then came before the handler started, so it never
            /// ran and never set `done`).
            fn start(client: *TestClient, io: std.Io) !void {
                done.store(false, .release);
                started.store(false, .release);
                let_go.store(false, .release);
                try client.sendPending();
                try wait.waitFlag(io, "the waiting handler started", &started);
                try std.testing.expect(!done.load(.acquire));
            }

            /// The handler ended because its client left.
            fn expectLetGo(io: std.Io) !void {
                try wait.waitFlag(io, "the waiting handler ended", &done);
                try std.testing.expect(let_go.load(.acquire));
            }
        };

        test "HTTP/2: a handler is let go when the client resets its stream, and the connection carries on" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/wait", Waiter.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/wait", null);
            try Waiter.start(&client, io);

            try client.reset(id, .cancel);
            try client.run();
            try std.testing.expectEqual(ErrorCode.cancel, client.get(id).error_code);
            try Waiter.expectLetGo(io);

            // The same connection still serves.
            const next = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(next).body.items);
        }

        test "HTTP/2: Response.abort resets the stream, and the connection carries on" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/abort", struct {
                fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                    var buf: [64]u8 = undefined;
                    var w = try res.stream(&buf);
                    try w.interface.writeAll("[1,");
                    try w.interface.flush();
                    return res.abort();
                }
            }.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/abort", null);
            try client.run();
            try std.testing.expectEqual(ErrorCode.cancel, client.get(id).error_code);

            const next = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(next).body.items);
        }

        test "HTTP/2: a handler is let go when the client closes the connection" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/wait", Waiter.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            _ = try client.request("GET", "/wait", null);
            try Waiter.start(&client, io);
            // The request is whole, so the end of the connection could be a
            // half-close: the server learns otherwise from its probe's failure.
            client.deinit();
            try Waiter.expectLetGo(io);
        }

        test "HTTP/2: cookie crumbs are joined with \"; \" and other repeated fields kept" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.requestWith("/fields", "localhost", &.{
                TestClient.nv("cookie", "a=1"),
                TestClient.nv("accept", "text/html"),
                TestClient.nv("cookie", "anole_session=x"),
                TestClient.nv("accept", "application/json"),
                TestClient.nv("cookie", "c=3"),
            });
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualStrings("cookie=a=1; anole_session=x; c=3 accepts=2 host=localhost", client.get(id).body.items);
        }

        test "HTTP/2: :authority is the host; a host field that differs from it is refused" {
            const io = std.testing.io;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const same = try client.requestWith("/fields", "example.com", &.{TestClient.nv("host", "example.com")});
            const differs = try client.requestWith("/fields", "example.com", &.{TestClient.nv("host", "evil.example")});
            const host_only = try client.requestWith("/fields", null, &.{TestClient.nv("host", "example.org")});
            const two_hosts = try client.requestWith("/fields", null, &.{ TestClient.nv("host", "example.org"), TestClient.nv("host", "evil.example") });
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(same).status);
            try std.testing.expectEqualStrings("cookie=- accepts=0 host=example.com", client.get(same).body.items);
            try std.testing.expectEqual(@as(u16, 400), client.get(differs).status);
            try std.testing.expectEqual(@as(u16, 200), client.get(host_only).status);
            try std.testing.expectEqualStrings("cookie=- accepts=0 host=example.org", client.get(host_only).body.items);
            // Two host fields: the server resets the stream.
            try std.testing.expectEqual(@as(u16, 0), client.get(two_hosts).status);
            try std.testing.expectEqual(ErrorCode.protocol_error, client.get(two_hosts).error_code);
        }

        /// Counts the bytes allocated and not yet freed.
        const LiveAllocator = struct {
            inner: std.mem.Allocator,
            live: std.atomic.Value(isize) = .init(0),
            peak: std.atomic.Value(isize) = .init(0),

            fn grew(self: *LiveAllocator, by: isize) void {
                const now = self.live.fetchAdd(by, .monotonic) + by;
                _ = self.peak.fetchMax(now, .monotonic);
            }

            fn allocator(self: *LiveAllocator) std.mem.Allocator {
                return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
            }
            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
                const p = self.inner.rawAlloc(len, alignment, ra) orelse return null;
                self.grew(@intCast(len));
                return p;
            }
            fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
                const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
                if (!self.inner.rawResize(memory, alignment, new_len, ra)) return false;
                self.grew(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
                return true;
            }
            fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
                const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
                const p = self.inner.rawRemap(memory, alignment, new_len, ra) orelse return null;
                self.grew(@as(isize, @intCast(new_len)) - @as(isize, @intCast(memory.len)));
                return p;
            }
            fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
                const self: *LiveAllocator = @ptrCast(@alignCast(ctx));
                self.inner.rawFree(memory, alignment, ra);
                _ = self.live.fetchSub(@intCast(memory.len), .monotonic);
            }
        };

        /// Streams whose head the server refuses: a header list past the limit,
        /// and two host fields (refused by the engine's own checks). With a
        /// `max_header_list_size` of 2048, two 1000-byte fields are past it
        /// decoded (each costs its length + 32) but not on the wire (Huffman,
        /// about 875 bytes each): a block over the limit on the wire ends the
        /// connection on the engine that serves (INTENTIONAL.md, limits 5).
        fn sendRefusedHeads(client: *TestClient, n: usize) !void {
            const big: [1000]u8 = @splat('x');
            for (0..n) |i| {
                if (i % 2 == 0) {
                    _ = try client.requestWith("/hello", "localhost", &.{ TestClient.nv("x-a", &big), TestClient.nv("x-b", &big) });
                } else {
                    _ = try client.requestWith("/hello", null, &.{ TestClient.nv("host", "a.example"), TestClient.nv("x-a", &big), TestClient.nv("host", "b.example") });
                }
            }
            try client.run();
        }

        test "HTTP/2: a stream whose head is refused is freed when it closes, not with the connection" {
            const io = std.testing.io;
            var live: LiveAllocator = .{ .inner = std.testing.allocator };
            var server = E.Server(void).init(live.allocator(), io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                // The refusal budget is the next test's.
                .http2 = .{ .max_header_list_size = 2048, .refused_stream_burst = 1000 },
            }, {});
            defer server.deinit();
            server.router.get("/hello", Handlers.hello);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, server.address.ip);
            defer client.deinit();
            // The first round fills the connection's spare streams.
            try sendRefusedHeads(&client, 40);
            const before = live.live.load(.monotonic);
            try sendRefusedHeads(&client, 80);
            const after = live.live.load(.monotonic);
            try std.testing.expect(after - before < 32 * 1024);
            // The connection still serves.
            const ok = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(ok).body.items);
        }

        test "HTTP/2: a peer whose streams keep being refused is sent GOAWAY(ENHANCE_YOUR_CALM)" {
            // Windows: skipped, not pending (#229). core-test runs on the zio
            // stub (no timer, so no lingering close, h2/server.zig
            // lingeringClose), so the engine closes with a few KB of the
            // peer's heads unread and the OS resets the connection on every
            // platform. On Linux the client reads the GOAWAY first, the reset
            // is reported once and swallowed by `sendRefusedHeads(..) catch {}`;
            // on Windows the read in runUntilClosed fails instead (GOAWAY
            // discarded or the reset reported on every read: not yet told
            // apart). Under zio the lingering close runs (h2.client_test's
            // GOAWAY test, anole-test), and the refusal budget itself is tested
            // without sockets in h2/conn_limits_test.zig.
            if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                .http2 = .{ .max_header_list_size = 2048, .refused_stream_burst = 20, .refused_stream_rate = 1 },
            }, {});
            defer server.deinit();
            server.router.get("/hello", Handlers.hello);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, server.address.ip);
            defer client.deinit();
            // Only the oversized heads (every other request) are charged to
            // the refusal budget of 20: 44 requests make 22 of them. The
            // client's HPACK never indexes, so a head costs about 1.75 KiB on
            // the wire; the little left unread when the server hangs up stays
            // under its linger limit (64 KiB), and the GOAWAY is read before
            // the close.
            // A peer that sends past the limit may lose the GOAWAY to the
            // reset (INTENTIONAL.md, server engine 8).
            sendRefusedHeads(&client, 44) catch {};
            try client.runUntilClosed();
            try std.testing.expect(client.goaway_count >= 1);
            try std.testing.expectEqual(ErrorCode.enhance_your_calm, client.goaway_error);
        }

        test "HTTP/2: a finished response the peer never takes is reset at the request timeout" {
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                .timeout = .{ .request = .fromMilliseconds(300) },
            }, {});
            defer server.deinit();
            server.router.get("/whole", struct {
                const body: [100 * 1024]u8 = @splat('z');
                fn handle(_: *dusty.Request, res: *dusty.Response) !void {
                    res.body = &body;
                }
            }.handle);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            // A stream window of zero (the client's SETTINGS): the server may
            // send the head, never the body.
            var client: TestClient = undefined;
            try client.initOptions(std.testing.allocator, io, server.address.ip, .{ .initial_window = 0, .connection_window = harness.default_window });
            defer client.deinit();
            // The request timeout (300 ms) ends the stream; without it, only the
            // keep-alive timeout (60 s) would, which only test-timing tells apart.
            const started: std.Io.Clock.Timestamp = .now(io, .awake);
            const id = try client.request("GET", "/whole", null);
            try client.run();
            try std.testing.expectEqual(ErrorCode.cancel, client.get(id).error_code);
            if (wait.timing()) try std.testing.expect(started.durationTo(.now(io, .awake)).raw.toMilliseconds() < 3000);
            try awaitStreamsFreed(&server, io);
        }

        test "HTTP/2: an event stream outlives timeouts.request" {
            const io = std.testing.io;
            var server = E.Server(void).init(std.testing.allocator, io, .{
                .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
                .timeout = .{ .request = .fromMilliseconds(100), .write = .fromSeconds(5) },
            }, {});
            defer server.deinit();
            server.router.get("/slow", struct {
                // Time passing on purpose (TESTING.md D1, margin >= 5x): sleeps are
                // lower bounds, so the stream lives at least 6 x 100 ms = 600 ms,
                // 6x the 100 ms request timeout, on any machine.
                fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                    var buf: [256]u8 = undefined;
                    var events = try res.startEventStream(&buf);
                    for (0..6) |_| {
                        try events.send("tick", .{});
                        try req.io.sleep(.fromMilliseconds(100), .awake);
                    }
                    try events.end();
                }
            }.handle);
            var future = try io.concurrent(Fixture.run, .{&server});
            defer future.cancel(io) catch {};
            try server.waitReady(io);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/slow", null);
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, client.get(id).body.items, "data: tick"));
        }

        /// A parked response (`Response._park`): the handler returns, and bursts
        /// from any task write DATA.
        const ParkProbe = struct {
            var parked: ?*dusty.Parked = null;
            var opened: std.Io.Event = .unset;
            var gone: std.Io.Event = .unset;
            var gone_calls: std.atomic.Value(u32) = .init(0);

            fn reset() void {
                parked = null;
                opened = .unset;
                gone = .unset;
                gone_calls.store(0, .monotonic);
            }

            fn onGone(_: *anyopaque) void {
                _ = gone_calls.fetchAdd(1, .monotonic);
                gone.set(std.testing.io);
            }

            /// Waits first, as a handler that talks to a database before it parks.
            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                try req.io.sleep(.fromMilliseconds(1), .awake);
                try res.header("Content-Type", "text/event-stream");
                var dummy: u8 = 0;
                parked = try res._park(req, .{ .gone = onGone, .ctx = &dummy });
                opened.set(req.io);
            }

            fn flushClient(client: *TestClient) !void {
                try client.sendPending();
            }
        };

        test "parked h2: a handler that waited first parks; bursts arrive as DATA; end finishes the stream and release frees it" {
            const io = std.testing.io;
            ParkProbe.reset();
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/live", ParkProbe.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/live", null);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
            const p = ParkProbe.parked.?;
            try std.testing.expect(p.begin());
            try p.write(&.{ "id: 1\n", "data: a\n\n" });
            p.endBurst();
            try std.testing.expect(p.begin());
            try p.write(&.{"data: b\n\n"});
            p.end();
            try client.run();
            try std.testing.expectEqual(@as(u16, 200), client.get(id).status);
            try std.testing.expectEqualStrings("id: 1\ndata: a\n\ndata: b\n\n", client.get(id).body.items);
            try std.testing.expectEqual(ErrorCode.no_error, client.get(id).error_code);
            try std.testing.expect(!p.begin());
            p.release();
            // The stream is freed (the fixture's allocator checks the rest).
            const next = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(next).body.items);
            try std.testing.expectEqual(@as(u32, 0), ParkProbe.gone_calls.load(.monotonic));
        }

        test "parked h2: RST_STREAM tells the owner once; release frees the stream" {
            const io = std.testing.io;
            ParkProbe.reset();
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/live", ParkProbe.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/live", null);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
            try client.reset(id, .cancel);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
            try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
            try std.testing.expect(!ParkProbe.parked.?.begin());
            ParkProbe.parked.?.release();
            const next = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(next).body.items);
        }

        test "parked h2: the connection closing with a parked stream tells the owner, and teardown waits for release" {
            const io = std.testing.io;
            ParkProbe.reset();
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/live", ParkProbe.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            _ = try client.request("GET", "/live", null);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);
            client.deinit();
            try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
            try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
            ParkProbe.parked.?.release();
        }

        test "parked h2: the connection closing with a burst blocked on a full outbox: the burst fails, gone comes after it, teardown waits for release" {
            const io = std.testing.io;
            ParkProbe.reset();
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/live", ParkProbe.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            _ = try client.request("GET", "/live", null);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the handler parked", &ParkProbe.opened);

            // The client reads nothing: no WINDOW_UPDATE, so past the stream's
            // window and the 1 MiB outbox the burst waits for room.
            const Writer = struct {
                written: std.atomic.Value(u32) = .init(0),
                failed: ?dusty.Parked.WriteError = null,
                gone_before_end: u32 = 0,
                /// The burst is over (set last, on every way out).
                done: std.atomic.Value(bool) = .init(false),
                fn run(self: *@This(), p: *dusty.Parked) void {
                    defer self.done.store(true, .release);
                    if (!p.begin()) return;
                    const chunk: [16 * 1024]u8 = @splat('x');
                    while (true) {
                        p.write(&.{&chunk}) catch |err| {
                            self.failed = err;
                            break;
                        };
                        _ = self.written.fetchAdd(1, .release);
                    }
                    // No `gone` during the burst: it is deferred to its end.
                    self.gone_before_end = ParkProbe.gone_calls.load(.acquire);
                    p.endBurst();
                }
            };
            var w: Writer = .{};
            var writing = try io.concurrent(Writer.run, .{ &w, ParkProbe.parked.? });
            // A failed wait ends the burst (its write is cancelable) before `w`
            // goes; after the await below this does nothing.
            defer writing.cancel(io);
            // 1 MiB + 64 KiB fills the outbox and the window: wait until most of it
            // is written, then close the connection under the waiting burst.
            try wait.waitAtLeast(io, "most of the burst written", &w.written, 66);
            client.deinit();
            try wait.waitFlag(io, "the blocked burst failed and ended", &w.done);
            writing.await(io);
            try std.testing.expect(w.failed != null);
            try std.testing.expectEqual(@as(u32, 0), w.gone_before_end);
            try wait.waitEvent(io, "the parked stream's owner was told it is gone", &ParkProbe.gone);
            try std.testing.expectEqual(@as(u32, 1), ParkProbe.gone_calls.load(.monotonic));
            try std.testing.expect(!ParkProbe.parked.?.begin());
            ParkProbe.parked.?.release();
        }

        /// A park that fails inside the handler (the peer reset the stream first):
        /// the park finishes the exchange, the handler returns the error, and the
        /// stream is let go exactly once, by `serveStream`'s caller.
        const FailedPark = struct {
            var result: ?anyerror = null;
            var started: std.Io.Event = .unset;
            var done: std.Io.Event = .unset;

            fn handle(req: *dusty.Request, res: *dusty.Response) !void {
                const io = req.io;
                started.set(io);
                const prev = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(prev);
                // Wait for the reset (the body reader reports it), so the park
                // meets a reset stream.
                const body = req._body_source.?.reader;
                wait.waitUntil(io, "the body reader reports the reset", body, struct {
                    fn f(r: *std.Io.Reader) bool {
                        var buf: [1]u8 = undefined;
                        _ = r.readSliceShort(&buf) catch return true;
                        return false;
                    }
                }.f) catch |err| {
                    result = err;
                    done.set(io);
                    return err;
                };
                try res.header("Content-Type", "text/event-stream");
                var dummy: u8 = 0;
                const p = res._park(req, .{ .gone = ParkProbe.onGone, .ctx = &dummy }) catch |err| {
                    result = err;
                    done.set(io);
                    return err;
                };
                p.release();
                result = null;
                done.set(io);
            }
        };

        test "parked h2: a park that fails on a reset stream lets go of the stream once" {
            const io = std.testing.io;
            ParkProbe.reset();
            FailedPark.result = null;
            FailedPark.done = .unset;
            FailedPark.started = .unset;
            var fx: Fixture = undefined;
            try fx.start(io);
            defer fx.stop(io);
            fx.server.router.get("/live", FailedPark.handle);

            var client: TestClient = undefined;
            try client.init(std.testing.allocator, io, fx.server.address.ip);
            defer client.deinit();
            const id = try client.request("GET", "/live", null);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the failing park's handler started", &FailedPark.started);
            try client.reset(id, .cancel);
            try ParkProbe.flushClient(&client);
            try wait.waitEvent(io, "the failing park's handler finished", &FailedPark.done);
            try std.testing.expectEqual(@as(?anyerror, error.WriteFailed), FailedPark.result);
            // The connection serves on (a double release would have broken its
            // stream count), and the fixture's allocator checks the rest.
            const next = try client.request("GET", "/hello", null);
            try client.run();
            try std.testing.expectEqualStrings("hello", client.get(next).body.items);
            try std.testing.expectEqual(@as(u32, 0), ParkProbe.gone_calls.load(.monotonic));
        }
    };
}

test "HTTP/2: a server serves h2 by default" {
    const io = std.testing.io;
    var fx: harness.Fixture(harness.Desc(.anole)) = undefined;
    try fx.start(io);
    defer fx.stop(io);
    const reads = anole_h2.test_reads.load(.monotonic);
    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const id = try client.request("GET", "/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(id).body.items);
    try std.testing.expect(anole_h2.test_reads.load(.monotonic) > reads);
}
