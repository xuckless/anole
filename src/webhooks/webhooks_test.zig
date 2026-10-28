//! End to end on the memory store: endpoints, publish fan-out, idempotency.
//! (Delivery itself runs inside the jobs worker; it is exercised by the
//! test round once the jobs engine is merged.)
const std = @import("std");
const wait = @import("anole_test_wait");
const anole = @import("../root.zig");
const wh = @import("root.zig");

test "Client: publish keeps one message per idempotency key" {
    const gpa = std.testing.allocator;
    const jc = try anole.jobs.Client.init(gpa, std.testing.io, .{ .store = .memory });
    defer jc.deinit();
    const c = try wh.Client.init(gpa, std.testing.io, .{ .jobs = jc, .allow_private_addresses = true, .require_https = false });
    defer c.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cx: anole.db.Ctx = .{ .io = std.testing.io, .arena = arena.allocator() };
    const made = try c.createEndpoint(&cx, .{ .owner = "acme", .url = "http://localhost:9/hook", .types = &.{"invoice.*"} });
    try std.testing.expect(std.mem.startsWith(u8, made.secret, "whsec_"));
    try std.testing.expect(std.mem.startsWith(u8, made.endpoint.id, "ep_"));
    const list = try c.listEndpoints(&cx, "acme");
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectError(error.InvalidJob, c.createEndpoint(&cx, .{ .url = "ftp://x" }));
    const rotated = try c.rotateSecret(&cx, made.endpoint.id, .fromSeconds(60));
    try std.testing.expect(!std.mem.eql(u8, rotated, made.secret));
}

// ---- delivery end to end: a real server receives, the job queue delivers,
// the delivery log records it, and the pruning job empties the log.
// Memory store always; PostgreSQL too with -Dpostgres-test-url.

const build_options = @import("build_options");
const App = @import("../server.zig").App;

const E2E = struct {
    const secret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    var hooks: *wh.Client = undefined;
    var jc: *anole.jobs.Client = undefined;
    var owner_buf: [32]u8 = undefined;
    var owner: []const u8 = "";
    var got: std.atomic.Value(u32) = .init(0);
    var bad: std.atomic.Value(u32) = .init(0);

    fn hook(req: *anole.Request, res: *anole.Response) !void {
        const body = (try req.body()) orelse "";
        const id = req.headers.get("webhook-id") orelse "";
        const ts = req.headers.get("webhook-timestamp") orelse "";
        const sig = req.headers.get("webhook-signature") orelse "";
        const now_s = std.fmt.parseInt(i64, ts, 10) catch 0;
        wh.sign.verify(&.{secret}, id, ts, sig, body, now_s, 0) catch {
            _ = bad.fetchAdd(1, .acq_rel);
            res.status = .bad_request;
            return;
        };
        if (std.mem.indexOf(u8, body, "\"data\":{\"id\":7}") == null) _ = bad.fetchAdd(1, .acq_rel);
        _ = got.fetchAdd(1, .acq_rel);
        res.body = "ok";
    }

    fn check(a: *App) !void {
        defer a.stop();
        try a.waitReady();
        const io = a.io();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var cx: anole.db.Ctx = .{ .io = io, .arena = arena.allocator() };
        const port = a.addresses()[0].ip.getPort();
        const url = try std.fmt.allocPrint(cx.arena, "http://127.0.0.1:{d}/hook", .{port});
        _ = try hooks.createEndpoint(&cx, .{ .owner = owner, .url = url, .types = &.{"invoice.*"}, .secret = secret });
        const p = try hooks.publish(&cx, .{ .owner = owner, .type = "invoice.paid" }, .{ .id = 7 });
        try std.testing.expectEqual(@as(u32, 1), p.deliveries);
        const p2 = try hooks.publish(&cx, .{ .owner = owner, .type = "user.created" }, .{ .id = 8 });
        try std.testing.expectEqual(@as(u32, 0), p2.deliveries);

        _ = try wait.waitNonZero(io, "the webhook arrived", &got);
        try std.testing.expectEqual(@as(u32, 1), got.load(.acquire));
        try std.testing.expectEqual(@as(u32, 0), bad.load(.acquire));
        // The attempt is logged once the response is read.
        const Logged = struct {
            hooks: *wh.Client,
            cx: *anole.db.Ctx,
            message: []const u8,
            att: *[]wh.Attempt,
            fn some(l: @This()) !bool {
                l.att.* = try l.hooks.attempts(l.cx, .{ .message = l.message });
                return l.att.len > 0;
            }
        };
        var att: []wh.Attempt = &.{};
        try wait.waitUntil(io, "the delivery attempt is logged", Logged{ .hooks = hooks, .cx = &cx, .message = p.message_id, .att = &att }, Logged.some);
        try std.testing.expectEqual(@as(usize, 1), att.len);
        try std.testing.expectEqualStrings("delivered", att[0].outcome);
        try std.testing.expectEqual(@as(u16, 200), att[0].status);
        try std.testing.expectEqual(@as(usize, 2), (try hooks.messages(&cx, .{ .owner = owner })).len);

        // Pruning through its job (keep is 1 s here): both messages and the
        // attempt go. The sleep only lets them age (a lower bound).
        try io.sleep(.fromMilliseconds(1100), .awake);
        _ = try jc.enqueueRaw(&cx, "anole.webhook.prune", "{}", .{ .queue = "webhooks" });
        const Pruned = struct {
            hooks: *wh.Client,
            cx: *anole.db.Ctx,
            owner: []const u8,
            fn gone(c: @This()) !bool {
                return (try c.hooks.messages(c.cx, .{ .owner = c.owner })).len == 0;
            }
        };
        try wait.waitUntil(io, "the prune job removed the messages", Pruned{ .hooks = hooks, .cx = &cx, .owner = owner }, Pruned.gone);
        try std.testing.expectEqual(@as(usize, 0), (try hooks.messages(&cx, .{ .owner = owner })).len);
        try std.testing.expectEqual(@as(usize, 0), (try hooks.attempts(&cx, .{ .message = p.message_id })).len);
    }

    fn run(comptime pg: bool) !void {
        got.store(0, .release);
        bad.store(0, .release);
        var app = try App.init(std.testing.allocator, .{ .executors = .exact(2), .listen_tls_http3 = false });
        defer app.deinit();
        const now_ms = std.Io.Timestamp.now(app.io(), .real).toMilliseconds();
        owner = try std.fmt.bufPrint(&owner_buf, "acme-{d}", .{now_ms});
        const store: anole.jobs.Store = if (pg) .{ .postgres = try app.postgres(.{ .url = build_options.postgres_test_url.?, .environ = .empty }) } else .memory;
        jc = try app.jobs(.{ .store = store, .table_prefix = "whtest_" });
        hooks = try app.webhooks(.{ .jobs = jc, .allow_private_addresses = true, .require_https = false, .keep_messages = .fromSeconds(1), .keep_attempts = .fromSeconds(1) });
        app.post("/hook", hook);
        var checking = try app.io().concurrent(check, .{&app});
        try app.listen("127.0.0.1:0");
        try checking.await(app.io());
    }
};

test "webhooks: delivery end to end on the memory store: signed POST, the log, pruning by its job" {
    try E2E.run(false);
}

test "webhooks: delivery end to end on PostgreSQL (live)" {
    if (comptime !anole.features.postgres) return error.SkipZigTest;
    if (build_options.postgres_test_url == null) return error.SkipZigTest;
    try E2E.run(true);
}
