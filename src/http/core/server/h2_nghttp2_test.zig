// Adapted from lalinsky/dusty (MIT, Copyright (c) 2025 Lukas Lalinsky and
// contributors), base d3cb485, via Anole's fork xuckless/dusty 86d152f.
// See LICENSE.dusty and THIRD_PARTY_NOTICES.

//! HTTP/2 tests tied to the nghttp2 engine: its reader/writer task model
//! (writer rounds and wakes, inline writes) and its body queue
//! (arena/heap/block allocations, queue length). They go with the engine
//! at M6; the behaviour tests are in h2_test.zig.
const std = @import("std");
const dusty = @import("../root.zig");
const c = @import("nghttp2");
const build_options = @import("build_options");
const tls = @import("tls");
const wait = @import("anole_test_wait");
const test_socket = @import("test_socket.zig");
const harness = @import("h2_harness_test.zig");
const awaitStreamsFreed = harness.awaitStreamsFreed;
const E = harness.Desc(.nghttp2);
const h2 = E.mod;
const Fixture = harness.Fixture(E.Server(void));

const loopback_addr = harness.loopback_addr;
const TestClient = harness.TestClient;
const Handlers = harness.Handlers;
const SentGate = harness.SentGate;
const default_window = harness.default_window;
const CountingAllocator = harness.CountingAllocator;
const preface = harness.preface;

/// `h2.test_writer_rounds` as the writer saw it each time it went to wait
/// (`h2.test_before_writer_wait`): once this reaches the count after a
/// round, the writer has passed its take after that round, so only a real
/// kick can wake it from here on.
var writer_idle_rounds: std.atomic.Value(u32) = .init(0);
fn noteWriterIdle(_: std.Io) void {
    writer_idle_rounds.store(h2.test_writer_rounds.load(.monotonic), .release);
}

/// A PING round on a warm connection, then until the writer has gone back
/// to its wait after it (`noteWriterIdle` must be the hook). Returns the
/// writer's rounds by then.
fn settleWriterAfterPing(io: std.Io, client: *TestClient) !u32 {
    const before_ping = h2.test_writer_rounds.load(.monotonic);
    _ = c.nghttp2_submit_ping(client.session, c.NGHTTP2_FLAG_NONE, null);
    try client.runUntilPingAck();
    // Counted before its write, so the PING's round is in by now.
    const rounds = h2.test_writer_rounds.load(.monotonic);
    try std.testing.expect(rounds > before_ping);
    try wait.waitAtLeast(io, "the writer went back to its wait after the PING's round", &writer_idle_rounds, rounds);
    return rounds;
}

test "HTTP/2: the reader writes the responses of its no_wait requests itself, without waking the writer" {
    const io = std.testing.io;
    writer_idle_rounds.store(0, .release);
    h2.test_before_writer_wait = noteWriterIdle;
    defer h2.test_before_writer_wait = null;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    // Warm: SETTINGS both ways, then a PING, which only the writer answers
    // (no no_wait request in its read). Its round is counted before its
    // write, so once the ACK is in, the writer has nothing more coming.
    const warm = try client.request("GET", "/nw/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(warm).body.items);
    // The batch goes only once the writer is past its take after the
    // PING's round: sent sooner, it could meet a writer still on its way
    // there, which would take the batch's responses or defer to the
    // reader's round and be woken at its end.
    const rounds = try settleWriterAfterPing(io, &client);
    const wakes = h2.test_writer_wakes.load(.monotonic);

    var ids: [8]i32 = undefined;
    for (&ids) |*id| id.* = try client.request("GET", "/nw/hello", null);
    try client.run();
    for (ids) |id| try std.testing.expectEqualStrings("hello", client.get(id).body.items);
    try std.testing.expectEqual(rounds, h2.test_writer_rounds.load(.monotonic));
    // Nor woken for nothing: the reader's round covers the kicks of its
    // requests (their heads, their streams closing).
    try std.testing.expectEqual(wakes, h2.test_writer_wakes.load(.monotonic));
}

test "HTTP/2: a reader whose inline write fails ends the connection, and the writer writes nothing more" {
    // As when the writer's own write fails: both directions shut, and the
    // round the reader took is not written again by the writer (a second
    // write would hold the connection for another write timeout, and a
    // round half written would go out twice).
    const io = std.testing.io;
    writer_idle_rounds.store(0, .release);
    h2.test_before_writer_wait = noteWriterIdle;
    defer h2.test_before_writer_wait = null;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const warm = try client.request("GET", "/nw/hello", null);
    try client.run();
    try std.testing.expectEqualStrings("hello", client.get(warm).body.items);
    // The writer is asleep, so the next request's response is the
    // reader's round alone.
    const rounds = try settleWriterAfterPing(io, &client);

    h2.test_inline_write_fails.store(true, .release);
    defer h2.test_inline_write_fails.store(false, .release);
    const id = try client.request("GET", "/nw/hello", null);
    try client.runUntilClosed();
    // The response the failed write held never went out.
    try std.testing.expectEqual(@as(u16, 0), client.get(id).status);
    try std.testing.expectEqual(rounds, h2.test_writer_rounds.load(.monotonic));
}

test "HTTP/2: a small body's queue comes from the stream's arena, with or without content-length" {
    const io = std.testing.io;
    const safety = @import("anole_safety");
    safety.arena_poisoning.store(false, .monotonic);
    defer safety.arena_poisoning.store(true, .monotonic);
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    var server = E.Server(void).init(counting.allocator(), io, .{
        .listeners = &.{.{ .address = loopback_addr, .http2_prior_knowledge = true }},
    }, {});
    defer server.deinit();
    server.router.post("/sum", Handlers.sum);
    var future = try io.concurrent(Fixture.run, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, server.address.ip);
    defer client.deinit();
    const body = "123456789";
    var expect: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) });
    // With content-length, and as gRPC clients send it: without, the one
    // DATA frame carrying END_STREAM (`onBeginFrame`).
    const with_length = [_]c.nghttp2_nv{TestClient.nv("content-length", "9")};
    for (0..5) |i| {
        _ = try client.requestHeaders("POST", "/sum", if (i % 2 == 0) &with_length else &.{}, body);
        try client.run();
        try awaitStreamsFreed(&server, io);
    }
    const before = counting.count.load(.monotonic);
    const arena_before = h2.test_body_allocs.arena.load(.monotonic);
    const heap_before = h2.test_body_allocs.heap.load(.monotonic);
    const block_before = h2.test_body_allocs.block.load(.monotonic);
    for (0..20) |i| {
        const id = try client.requestHeaders("POST", "/sum", if (i % 2 == 0) &with_length else &.{}, body);
        try client.run();
        try std.testing.expectEqualStrings(want, client.get(id).body.items);
        try awaitStreamsFreed(&server, io);
    }
    // Nothing allocated: the queue fit in the arena's kept node.
    try std.testing.expectEqual(before, counting.count.load(.monotonic));
    try std.testing.expectEqual(arena_before + 20, h2.test_body_allocs.arena.load(.monotonic));
    try std.testing.expectEqual(heap_before, h2.test_body_allocs.heap.load(.monotonic));
    try std.testing.expectEqual(block_before, h2.test_body_allocs.block.load(.monotonic));
}

test "HTTP/2: a body of unknown length over several frames gets a window from block_cache" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    const body = try std.testing.allocator.alloc(u8, 20 * 1000);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 17);
    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    const block_before = h2.test_body_allocs.block.load(.monotonic);
    const id = try client.request("POST", "/nw/sum", body);
    try client.run();
    var expect: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(id).body.items);
    // Past one frame (16 KiB), the first carries no END_STREAM: a whole
    // window, the 64 KiB class.
    try std.testing.expectEqual(block_before + 1, h2.test_body_allocs.block.load(.monotonic));
}

test "HTTP/2: a body that overflows its queue resets only its stream, with INTERNAL_ERROR" {
    const io = std.testing.io;
    var fx: Fixture = undefined;
    try fx.start(io);
    defer fx.stop(io);

    var client: TestClient = undefined;
    try client.init(std.testing.allocator, io, fx.server.address.ip);
    defer client.deinit();
    // Impossible by the queue's sizing: forced with a queue too short.
    h2.test_body_queue_len = 4;
    const id = blk: {
        defer h2.test_body_queue_len = null;
        const id = try client.request("POST", "/nw/sum", "123456789");
        try client.run();
        break :blk id;
    };
    try std.testing.expectEqual(@as(u32, c.NGHTTP2_INTERNAL_ERROR), client.get(id).error_code);
    try std.testing.expect(client.get(id).rsts >= 1);
    // The connection carries on, its window intact.
    const body = try std.testing.allocator.alloc(u8, 200 * 1024);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 5);
    const after = try client.request("POST", "/nw/sum", body);
    try client.run();
    var expect: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expect, "{d} {x}", .{ body.len, std.hash.Wyhash.hash(0, body) }), client.get(after).body.items);
}
