//! C ABI tests for p3/webhooks, imported from engine_test.zig.
const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const abi = @import("abi.zig");
const config = @import("config.zig");
const parity = @import("parity.zig");
const features = anole.features;

comptime {
    if (features.webhooks) {
        parity.checkCoverage(anole.webhooks.Options, &parity.webhooks_options);
        parity.checkCoverage(anole.webhooks.Verify.Options, &parity.webhook_verify_options);
    }
}

test "webhooks: the configuration parses, with defaults" {
    if (comptime !features.webhooks) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [400]u8 = undefined;
    var why: std.Io.Writer = .fixed(&buf);
    const c = try config.parse(arena.allocator(),
        \\{"webhooks": {"attempts": 5, "backoff": {"jitter": "none"}},
        \\ "middleware": [{"webhook_verify": {"preset": "stripe", "secrets": ["whsec_x"]}},
        \\                {"webhook_verify": {"preset": "hmac", "secrets_env": "K", "dedup": "none",
        \\                 "hmac": {"header": "X-Sig", "prefix": "sha256="}}}]}
    , &why);
    const w = c.webhooks.?;
    try std.testing.expectEqual(@as(u16, 5), w.attempts);
    try std.testing.expectEqualStrings("webhooks", w.queue);
    try std.testing.expectEqual(@as(u32, 5_000), w.backoff.base_ms);
    try std.testing.expect(w.backoff.jitter == .none);
    try std.testing.expect(w.breaker != null);
    const v = c.middleware[0].webhook_verify;
    try std.testing.expect(v.preset == .stripe);
    try std.testing.expectEqual(@as(u32, 300_000), v.tolerance_ms);
    try std.testing.expectEqualStrings("memory", v.dedup);
    const h = c.middleware[1].webhook_verify;
    try std.testing.expectEqualStrings("sha256=", h.hmac.?.prefix);
}

test "webhooks: bad webhook_verify settings are refused with the key named" {
    if (comptime !features.webhooks) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"stripe\"}}]}", .needle = "exactly one of secrets and secrets_env" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"hmac\", \"secrets\": [\"a\"]}}]}", .needle = "needs the hmac settings" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"github\", \"secrets\": [\"a\"], \"dedup\": \"disk\"}}]}", .needle = "dedup" },
        .{ .json = "{\"middleware\": [{\"webhook_verify\": {\"preset\": \"github\", \"secrets\": [\"a\"], \"hmac\": {\"header\": \"x\"}}}]}", .needle = "only with preset" },
    };
    for (cases) |case| {
        var buf: [400]u8 = undefined;
        var why: std.Io.Writer = .fixed(&buf);
        try std.testing.expectError(error.Config, config.parse(arena.allocator(), case.json, &why));
        try std.testing.expect(std.mem.indexOf(u8, why.buffered(), case.needle) != null);
    }
}

// ---------------------------------------------------------------------------
// Endpoint management through anole_jobs_admin ("webhooks.*")

const engine = @import("engine.zig");
const alloc = std.testing.allocator;

/// Runs one admin request and returns its answer (status, http status and
/// JSON copied into `arena`), polling the consumer until `wait.deadline()`.
const AdminRig = struct {
    e: *engine.Engine,
    c: *engine.Consumer,
    json: []u8,
    next_user: u64 = 1,

    fn create(r: *AdminRig) !void {
        r.json = try alloc.dupe(u8,
            \\{"executors": 1, "timeouts": {"shutdown_ms": 200},
            \\ "listeners": [{"address": "127.0.0.1", "port": 0}],
            \\ "databases": [{"name": "main", "sqlite": {"path": ":memory:"}}],
            \\ "jobs": {"store": "main", "poll_ms": 100},
            \\ "webhooks": {}}
        );
        errdefer alloc.free(r.json);
        var why_buf: [512]u8 = undefined;
        var why: std.Io.Writer = .fixed(&why_buf);
        r.e = engine.Engine.create(r.json, false, &why) catch |err| {
            std.debug.print("{s}\n", .{why.buffered()});
            return err;
        };
        errdefer r.e.destroy();
        r.c = try r.e.attach(null, null, false);
        try r.e.open();
        try r.e.start();
    }

    fn deinit(r: *AdminRig) void {
        r.e.drain() catch {};
        _ = r.e.wait(@intCast(wait.deadlineMs()));
        r.e.destroy();
        alloc.free(r.json);
    }

    const Answer = struct { status: i32, http: u16, json: std.json.Value, text: []const u8 };

    fn call(r: *AdminRig, arena: std.mem.Allocator, request: []const u8) !Answer {
        const user = r.next_user;
        r.next_user += 1;
        try engine.jobs.admin(r.e, r.c, request, user);
        var buf: [64 * 1024]u8 align(8) = undefined;
        const tio = engine.threadedIo();
        const started = std.Io.Clock.awake.now(tio);
        while (started.untilNow(tio, .awake).nanoseconds < wait.deadline().nanoseconds) {
            var need: u32 = 0;
            const n = try engine.pollWait(r.c, &buf, 50, &need);
            var off: usize = 0;
            while (off < n) {
                const head: *const abi.Event = @ptrCast(@alignCast(&buf[off]));
                defer off += head.len;
                if (head.type != @backingInt(abi.EventType.jobs_result)) continue;
                const rec: *const abi.JobsResultEvent = @ptrCast(@alignCast(&buf[off]));
                if (rec.user_data != user) continue;
                const text = try arena.dupe(u8, buf[off..][rec.json.off..][0..rec.json.len]);
                const value = if (text.len > 0) try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) else .null;
                return .{ .status = rec.status, .http = rec.http_status, .json = value, .text = text };
            }
        }
        std.debug.print("timed out waiting for the admin answer to: {s}\n", .{request});
        return error.TimedOut;
    }
};

test "capi webhooks: admin errors: a bad URL is 400 E_INVALID, an unknown endpoint 404, a broken request 400" {
    if (comptime !(features.webhooks and features.sqlite)) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: AdminRig = undefined;
    try r.create();
    defer r.deinit();
    const bad = try r.call(arena, "{\"op\":\"webhooks.endpoint.create\",\"url\":\"ftp://nope\"}");
    try std.testing.expectEqual(@as(u16, 400), bad.http);
    try std.testing.expectEqual(abi.E_INVALID, bad.status);
    const missing = try r.call(arena, "{\"op\":\"webhooks.endpoint.get\",\"id\":\"ep_nope\"}");
    try std.testing.expectEqual(@as(u16, 404), missing.http);
    try std.testing.expectEqual(abi.OK, missing.status);
    const not_json = try r.call(arena, "{\"op\":\"webhooks.endpoint.create\",");
    try std.testing.expectEqual(@as(u16, 400), not_json.http);
}

test "capi webhooks: endpoints are created, listed, updated, rotated and deleted through jobs admin" {
    if (comptime !(features.webhooks and features.sqlite)) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: AdminRig = undefined;
    try r.create();
    defer r.deinit();

    const made = try r.call(arena,
        \\{"op":"webhooks.endpoint.create","owner":"acme","url":"https://acme.example/hook",
        \\ "types":["invoice.*"],"description":"billing","metadata":{"tier":"gold"}}
    );
    try std.testing.expectEqual(abi.OK, made.status);
    try std.testing.expectEqual(@as(u16, 200), made.http);
    const id = made.json.object.get("endpoint").?.object.get("id").?.string;
    const secret = made.json.object.get("secret").?.string;
    try std.testing.expect(std.mem.startsWith(u8, id, "ep_"));
    try std.testing.expect(std.mem.startsWith(u8, secret, "whsec_"));

    const listed = try r.call(arena, "{\"op\":\"webhooks.endpoint.list\",\"owner\":\"acme\"}");
    try std.testing.expectEqual(@as(u16, 200), listed.http);
    const eps = listed.json.object.get("endpoints").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), eps.len);
    try std.testing.expectEqualStrings("https://acme.example/hook", eps[0].object.get("url").?.string);
    try std.testing.expectEqualStrings("gold", eps[0].object.get("metadata").?.object.get("tier").?.string);

    const upd_req = try std.fmt.allocPrint(arena, "{{\"op\":\"webhooks.endpoint.update\",\"id\":\"{s}\",\"url\":\"https://acme.example/v2\"}}", .{id});
    const updated = try r.call(arena, upd_req);
    try std.testing.expectEqual(@as(u16, 200), updated.http);
    try std.testing.expectEqualStrings("https://acme.example/v2", updated.json.object.get("url").?.string);
    try std.testing.expectEqualStrings("billing", updated.json.object.get("description").?.string);

    const rot_req = try std.fmt.allocPrint(arena, "{{\"op\":\"webhooks.endpoint.rotate_secret\",\"id\":\"{s}\",\"keep_old_ms\":1000}}", .{id});
    const rotated = try r.call(arena, rot_req);
    try std.testing.expectEqual(@as(u16, 200), rotated.http);
    const fresh = rotated.json.object.get("secret").?.string;
    try std.testing.expect(std.mem.startsWith(u8, fresh, "whsec_"));
    try std.testing.expect(!std.mem.eql(u8, fresh, secret));


    const del_req = try std.fmt.allocPrint(arena, "{{\"op\":\"webhooks.endpoint.delete\",\"id\":\"{s}\"}}", .{id});
    const deleted = try r.call(arena, del_req);
    try std.testing.expectEqual(@as(u16, 200), deleted.http);
    const again = try r.call(arena, del_req);
    try std.testing.expectEqual(@as(u16, 404), again.http);
    const empty = try r.call(arena, "{\"op\":\"webhooks.endpoint.list\",\"owner\":\"acme\"}");
    try std.testing.expectEqual(@as(usize, 0), empty.json.object.get("endpoints").?.array.items.len);
}
