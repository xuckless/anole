//! The keyring against a slow fake JWKS endpoint on loopback: one fetch
//! however many requests need it, and requests the current keys serve do
//! not wait for a fetch in flight.
const std = @import("std");
const zio = @import("zio");
const dusty = @import("dusty");
const Keyring = @import("keyring.zig").Keyring;

const Ed = std.crypto.sign.Ed25519;
const b64 = std.base64.url_safe_no_pad;

/// The fake endpoint's state.
var keys: [3]Ed.KeyPair = undefined;
/// How many of `keys` it serves (k1, k2, ...).
var served: std.atomic.Value(usize) = .init(1);
var delay_ms: std.atomic.Value(u32) = .init(0);
var fetches: std.atomic.Value(usize) = .init(0);
/// The endpoint answers 503 while set (the provider is down).
var down: std.atomic.Value(bool) = .init(false);

fn jwks(req: *dusty.Request, res: *dusty.Response) !void {
    _ = fetches.fetchAdd(1, .monotonic);
    if (down.load(.monotonic)) {
        res.status = .service_unavailable;
        res.body = "down";
        return;
    }
    try req.io.sleep(.fromMilliseconds(delay_ms.load(.monotonic)), .awake);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(res.arena, "{\"keys\":[");
    for (keys[0..served.load(.monotonic)], 0..) |kp, i| {
        var x: [43]u8 = undefined;
        if (i > 0) try out.append(res.arena, ',');
        try out.print(res.arena, "{{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"k{d}\",\"x\":\"{s}\"}}", .{ i + 1, b64.Encoder.encode(&x, &kp.public_key.toBytes()) });
    }
    try out.appendSlice(res.arena, "]}");
    res.content_type = .json;
    res.body = out.items;
}

/// A token signed with key `n` (1-based) and named `k<n>`.
fn token(arena: std.mem.Allocator, io: std.Io, n: usize) ![]const u8 {
    const header = try std.fmt.allocPrint(arena, "{{\"alg\":\"EdDSA\",\"kid\":\"k{d}\"}}", .{n});
    const claims = try std.fmt.allocPrint(arena, "{{\"sub\":\"u{d}\",\"aud\":\"api\",\"exp\":{d}}}", .{ n, std.Io.Clock.real.now(io).toSeconds() + 600 });
    const h = try arena.alloc(u8, b64.Encoder.calcSize(header.len));
    const c = try arena.alloc(u8, b64.Encoder.calcSize(claims.len));
    const input = try std.fmt.allocPrint(arena, "{s}.{s}", .{ b64.Encoder.encode(h, header), b64.Encoder.encode(c, claims) });
    const sig = (try keys[n - 1].sign(input, null)).toBytes();
    const s = try arena.alloc(u8, b64.Encoder.calcSize(sig.len));
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ input, b64.Encoder.encode(s, &sig) });
}

/// Verifies `tok` and checks its subject; how long it took, in ms.
fn verifyTimed(keyring: *Keyring, io: std.Io, tok: []const u8, sub: []const u8) !i64 {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const start = std.Io.Clock.awake.now(io);
    const v = try keyring.verify(arena_state.allocator(), tok, .{ .audience = "api" });
    try std.testing.expectEqualStrings(sub, v.string("sub").?);
    return start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}

test "Keyring: one fetch for concurrent verifiers, and known keys never wait on a fetch" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    for (&keys) |*k| k.* = Ed.KeyPair.generate(io);
    served.store(1, .monotonic);
    fetches.store(0, .monotonic);

    var server = dusty.Server(void).init(gpa, io, .{ .listeners = &.{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }} }, {});
    defer server.deinit();
    server.router.get("/jwks", jwks);
    var future = try io.concurrent(struct {
        fn r(s: *dusty.Server(void)) !void {
            try s.run();
        }
    }.r, .{&server});
    defer future.cancel(io) catch {};
    try server.waitReady(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/jwks", .{server.address.ip.getPort()});
    var keyring = Keyring.init(gpa, io, .{ .http = &client }, url);
    defer keyring.deinit();
    keyring.min_refresh_seconds = 0;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t1 = try token(arena, io, 1);
    const t2 = try token(arena, io, 2);
    const t3 = try token(arena, io, 3);

    // A cold keyring and eight requests at once: one fetch, all verified.
    delay_ms.store(200, .monotonic);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    const Verifier = struct {
        fn run(k: *Keyring, io_: std.Io, tok: []const u8, sub: []const u8, failed: *std.atomic.Value(usize)) void {
            _ = verifyTimed(k, io_, tok, sub) catch {
                _ = failed.fetchAdd(1, .monotonic);
            };
        }
    };
    var failed: std.atomic.Value(usize) = .init(0);
    for (0..8) |_| try group.concurrent(io, Verifier.run, .{ &keyring, io, t1, "u1", &failed });
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 0), failed.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), fetches.load(.monotonic));

    // The provider rotates in k2, slowly. Four k2 tokens share one refetch;
    // a k1 token meanwhile verifies at once with the keys in hand.
    served.store(2, .monotonic);
    delay_ms.store(400, .monotonic);
    for (0..4) |_| try group.concurrent(io, Verifier.run, .{ &keyring, io, t2, "u2", &failed });
    while (fetches.load(.monotonic) < 2) try io.sleep(.fromMilliseconds(5), .awake);
    try std.testing.expect(try verifyTimed(&keyring, io, t1, "u1") < 200);
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 0), failed.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), fetches.load(.monotonic));

    // An unknown kid within `min_refresh_seconds` of the last fetch: no fetch.
    keyring.min_refresh_seconds = 60;
    delay_ms.store(0, .monotonic);
    try std.testing.expectError(error.NoMatchingKey, verifyTimed(&keyring, io, t3, "u3"));
    try std.testing.expectEqual(@as(usize, 2), fetches.load(.monotonic));

    // Past it, the unknown kid makes one refetch, which finds k3.
    keyring.min_refresh_seconds = 0;
    served.store(3, .monotonic);
    _ = try verifyTimed(&keyring, io, t3, "u3");
    try std.testing.expectEqual(@as(usize, 3), fetches.load(.monotonic));
}

test "Keyring: requests waiting on a fetch that fails get an error, and nothing is left behind" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    for (&keys) |*k| k.* = Ed.KeyPair.generate(io);
    served.store(1, .monotonic);

    // Nothing listens at this address once the listener is gone.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try addr.listen(io, .{});
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var client = dusty.Client.init(gpa, io, .{});
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/jwks", .{port});
    var keyring = Keyring.init(gpa, io, .{ .http = &client }, url);
    defer keyring.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const t1 = try token(arena_state.allocator(), io, 1);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var failed: std.atomic.Value(usize) = .init(0);
    for (0..4) |_| try group.concurrent(io, struct {
        fn run(k: *Keyring, io_: std.Io, tok: []const u8, f: *std.atomic.Value(usize)) void {
            _ = verifyTimed(k, io_, tok, "u1") catch {
                _ = f.fetchAdd(1, .monotonic);
            };
        }
    }.run, .{ &keyring, io, t1, &failed });
    try group.await(io);
    try std.testing.expectEqual(@as(usize, 4), failed.load(.monotonic));
    try std.testing.expect(!keyring.fetching);
    try std.testing.expect(keyring.current == null);
}

/// A keyring on the fake endpoint, which serves k1.
const Fixture = struct {
    /// Static: the server keeps the slice.
    const loopback = [_]dusty.Listener{.{ .address = .{ .ip = .{ .ip4 = .loopback(0) } } }};

    server: dusty.Server(void),
    future: std.Io.Future(anyerror!void),
    client: dusty.Client,
    url_buf: [64]u8,
    keyring: Keyring,

    fn serve(s: *dusty.Server(void)) anyerror!void {
        try s.run();
    }

    fn init(f: *Fixture, gpa: std.mem.Allocator, io: std.Io) !void {
        f.server = dusty.Server(void).init(gpa, io, .{ .listeners = &loopback }, {});
        errdefer f.server.deinit();
        f.server.router.get("/jwks", jwks);
        f.future = try io.concurrent(serve, .{&f.server});
        try f.server.waitReady(io);
        f.client = dusty.Client.init(gpa, io, .{});
        const url = try std.fmt.bufPrint(&f.url_buf, "http://127.0.0.1:{d}/jwks", .{f.server.address.ip.getPort()});
        f.keyring = Keyring.init(gpa, io, .{ .http = &f.client }, url);
    }

    fn deinit(f: *Fixture, io: std.Io) void {
        f.keyring.deinit();
        f.client.deinit();
        f.future.cancel(io) catch {};
        f.server.deinit();
    }
};

test "Keyring: a policy without an audience is refused" {
    const gpa = std.testing.allocator;
    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(2) });
    defer rt.deinit();
    const io = rt.io();
    for (&keys) |*k| k.* = Ed.KeyPair.generate(io);
    served.store(1, .monotonic);
    delay_ms.store(0, .monotonic);

    var f: Fixture = undefined;
    try f.init(gpa, io);
    defer f.deinit(io);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const t1 = try token(arena, io, 1);
    // A provider's keys sign tokens for every one of its clients.
    try std.testing.expectError(error.AudienceRequired, f.keyring.verify(arena, t1, .{}));
    _ = try f.keyring.verify(arena, t1, .{ .audience = "api" });
}
