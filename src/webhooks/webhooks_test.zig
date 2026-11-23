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
    const first = try c.publish(&cx, .{ .owner = "acme", .type = "invoice.paid", .id = "evt-1" }, .{ .n = 1 });
    const again = try c.publish(&cx, .{ .owner = "acme", .type = "invoice.paid", .id = "evt-1" }, .{ .n = 2 });
    try std.testing.expect(!first.duplicate and again.duplicate);
    try std.testing.expectEqualStrings(first.message_id, again.message_id);
    const msgs = try c.messages(&cx, .{ .owner = "acme" });
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings(first.message_id, msgs[0].id);
}

test "webhooks: createEndpoint gives a whsec_ secret and an ep_ id, refuses a non-http URL, and rotateSecret changes the secret" {
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

test "webhooks: messages on SQLite page by bytes, newest first, for one owner and for all" {
    if (comptime !anole.features.sqlite) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const sq = try anole.sqlite.Client.init(gpa, std.testing.io, .{ .path = ":memory:" });
    defer sq.deinit();
    const jc = try anole.jobs.Client.init(gpa, std.testing.io, .{ .store = .{ .sqlite = sq }, .table_prefix = "whtest_" });
    defer jc.deinit();
    const c = try wh.Client.init(gpa, std.testing.io, .{ .jobs = jc, .allow_private_addresses = true, .require_https = false });
    defer c.deinit();
    try c.start(null, null, null);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cx: anole.db.Ctx = .{ .io = std.testing.io, .arena = arena.allocator() };
    // Even ones to "acme", odd ones to "globex".
    for ([_][]const u8{ "msg_a", "msg_B", "msg_c", "msg_D" }, 0..) |id, i| {
        _ = try c.publish(&cx, .{ .owner = if (i % 2 == 0) "acme" else "globex", .type = "t", .id = id }, .{});
    }
    const Case = struct { owner: ?[]const u8, want: []const []const u8 };
    for ([_]Case{
        .{ .owner = null, .want = &.{ "msg_c", "msg_a", "msg_D", "msg_B" } },
        .{ .owner = "acme", .want = &.{ "msg_c", "msg_a" } },
        .{ .owner = "globex", .want = &.{ "msg_D", "msg_B" } },
    }) |case| {
        var got: std.ArrayList([]const u8) = .empty;
        var before: ?[]const u8 = null;
        while (got.items.len <= 4) { // more than every id: a page repeated
            const page = try c.messages(&cx, .{ .owner = case.owner, .before = before, .limit = 1 });
            if (page.len == 0) break;
            try got.append(cx.arena, page[0].id);
            before = page[0].id;
        }
        try std.testing.expectEqualDeep(case.want, got.items);
    }
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
    /// The webhooks client's clock: pruning ages messages by moving it, not by sleeping.
    var clock: anole.jobs.testing.FakeClock = undefined;

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
        // attempt go once the webhooks clock is 2 s on.
        clock.advance(.fromSeconds(2));
        _ = try jc.enqueueRaw(&cx, "anole.webhook.prune", "{}", .{ .queue = "webhooks" });
        // Postgres prunes messages and attempts in two statements, so wait
        // for both rather than reading the attempts between them.
        const Pruned = struct {
            hooks: *wh.Client,
            cx: *anole.db.Ctx,
            owner: []const u8,
            message: []const u8,
            fn gone(c: @This()) !bool {
                return (try c.hooks.messages(c.cx, .{ .owner = c.owner })).len == 0 and
                    (try c.hooks.attempts(c.cx, .{ .message = c.message })).len == 0;
            }
        };
        try wait.waitUntil(io, "the prune job removed the messages and attempts", Pruned{ .hooks = hooks, .cx = &cx, .owner = owner, .message = p.message_id }, Pruned.gone);
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
        // The jobs client keeps the real clock, so its background runner still delivers.
        clock = .init(anole.jobs.Time.fromMillis(now_ms));
        const store: anole.jobs.Store = if (pg) .{ .postgres = try app.postgres(.{ .url = build_options.postgres_test_url.?, .environ = .empty }) } else .memory;
        jc = try app.jobs(.{ .store = store, .table_prefix = "whtest_" });
        hooks = try app.webhooks(.{ .jobs = jc, .allow_private_addresses = true, .require_https = false, .keep_messages = .fromSeconds(1), .keep_attempts = .fromSeconds(1), .clock = clock.clock() });
        app.post("/hook", hook);
        var checking = try app.io().concurrent(check, .{&app});
        defer checking.cancel(app.io()) catch {};
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

// ---- Verify.check, pinned per preset through the middleware (status and handler runs).

const Kind = enum { stripe, github, slack, hmac_sha256, hmac_sha1, hmac_sha512, hmac_base64, standard };
const Fault = enum { none, second_secret, wrong_secret, body_altered, no_header, bad_prefix, truncated, bad_ts, v1_second, v1_fourth, v1_fifth };
const all_kinds = std.enums.values(Kind);
const windowed = [_]Kind{ .stripe, .slack, .standard };
/// Every Fault x Kind cell is listed here or skipped by `kinds`.
const fault_rows = [_]struct { fault: Fault, ok: bool, kinds: []const Kind = all_kinds }{
    .{ .fault = .none, .ok = true },
    .{ .fault = .second_secret, .ok = true },
    .{ .fault = .wrong_secret, .ok = false },
    .{ .fault = .body_altered, .ok = false },
    .{ .fault = .no_header, .ok = false },
    .{ .fault = .bad_prefix, .ok = false },
    .{ .fault = .truncated, .ok = false },
    .{ .fault = .bad_ts, .ok = false, .kinds = &windowed },
    .{ .fault = .v1_second, .ok = true, .kinds = &.{.stripe} },
    .{ .fault = .v1_fourth, .ok = true, .kinds = &.{.stripe} },
    .{ .fault = .v1_fifth, .ok = false, .kinds = &.{.stripe} },
};
const Route = struct { kind: Kind, tol: i64 };
const routes = blk: {
    var r: [14]Route = undefined;
    var n: usize = 0;
    for (all_kinds) |k| {
        r[n] = .{ .kind = k, .tol = 300 };
        n += 1;
    }
    for (windowed) |k| for ([_]i64{ 0, -5 }) |tol| {
        r[n] = .{ .kind = k, .tol = tol };
        n += 1;
    };
    break :blk r;
};
const keys = [3][]const u8{ "whsec_AAAAAAAAAAAAAAAAAAAAAAAAAAAA", "whsec_BBBBBBBBBBBBBBBBBBBBBBBBBBBB", "whsec_CCCCCCCCCCCCCCCCCCCCCCCCCCCC" };
const sig_names = std.EnumArray(Kind, []const u8).init(.{ .stripe = "Stripe-Signature", .github = "X-Hub-Signature-256", .slack = "X-Slack-Signature", .hmac_sha256 = "X-Sig", .hmac_sha1 = "X-Sig", .hmac_sha512 = "X-Sig", .hmac_base64 = "X-Sig", .standard = "webhook-signature" });
const epoch_s: i64 = 1_700_000_000;
var hits: std.atomic.Value(u32) = .init(0);

fn countHit(_: *anole.Request, res: *anole.Response) !void {
    _ = hits.fetchAdd(1, .acq_rel);
    res.body = "ok";
}

fn path(comptime k: Kind, comptime tol: i64) []const u8 {
    return std.fmt.comptimePrint("/{t}/{d}", .{ k, tol });
}

fn options(comptime kind: Kind, comptime tol: i64, d: wh.Verify.Dedup, clock: *anole.jobs.testing.FakeClock) wh.Verify.Options {
    const hm: ?wh.Verify.Hmac = comptime switch (kind) {
        .hmac_sha256 => .{ .header = "X-Sig", .prefix = "sig=" },
        .hmac_sha1 => .{ .header = "X-Sig", .prefix = "sig=", .algorithm = .sha1 },
        .hmac_sha512 => .{ .header = "X-Sig", .prefix = "sig=", .algorithm = .sha512 },
        .hmac_base64 => .{ .header = "X-Sig", .prefix = "sig=", .encoding = .base64 },
        else => null,
    };
    return .{ .preset = if (comptime hm != null) .hmac else @field(wh.Verify.Preset, @tagName(kind)), .secrets = keys[0..2], .tolerance = .fromSeconds(tol), .dedup = d, .hmac = hm, .clock = clock.clock() };
}

fn macText(a: std.mem.Allocator, comptime H: type, key: []const u8, parts: []const []const u8, b64: bool) ![]u8 {
    var h = H.init(key);
    for (parts) |p| h.update(p);
    var out: [H.mac_length]u8 = undefined;
    h.final(&out);
    if (b64) {
        var text: [std.base64.standard.Encoder.calcSize(H.mac_length)]u8 = undefined;
        return a.dupe(u8, std.base64.standard.Encoder.encode(&text, &out));
    }
    return std.fmt.allocPrint(a, "{x}", .{&out});
}

/// Posts a delivery of `kind` carrying `fault`, signed for `ts`; the status.
fn send(t: anytype, a: std.mem.Allocator, target: []const u8, kind: Kind, fault: Fault, ts: i64, body: []const u8) !u16 {
    const key = switch (fault) {
        .wrong_secret => keys[2],
        .second_secret => keys[1],
        else => keys[0],
    };
    const ts_text = if (fault == .bad_ts) "abc" else try std.fmt.allocPrint(a, "{d}", .{ts});
    const Sha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    const junk = "v1=0000000000000000000000000000000000000000000000000000000000000000," ++ "v1=0000000000000000000000000000000000000000000000000000000000000000," ++ "v1=0000000000000000000000000000000000000000000000000000000000000000," ++ "v1=0000000000000000000000000000000000000000000000000000000000000000,";
    const n_junk: usize = switch (fault) {
        .v1_second => 1,
        .v1_fourth => 3,
        .v1_fifth => 4,
        else => 0,
    };
    var sig: []u8 = switch (kind) {
        .stripe => try std.fmt.allocPrint(a, "t={s},{s}v1={s}", .{ ts_text, junk[0 .. n_junk * 68], try macText(a, Sha256, key, &.{ ts_text, ".", body }, false) }),
        .github => try std.fmt.allocPrint(a, "sha256={s}", .{try macText(a, Sha256, key, &.{body}, false)}),
        .slack => try std.fmt.allocPrint(a, "v0={s}", .{try macText(a, Sha256, key, &.{ "v0:", ts_text, ":", body }, false)}),
        .hmac_sha256 => try std.fmt.allocPrint(a, "sig={s}", .{try macText(a, Sha256, key, &.{body}, false)}),
        .hmac_sha1 => try std.fmt.allocPrint(a, "sig={s}", .{try macText(a, std.crypto.auth.hmac.HmacSha1, key, &.{body}, false)}),
        .hmac_sha512 => try std.fmt.allocPrint(a, "sig={s}", .{try macText(a, std.crypto.auth.hmac.sha2.HmacSha512, key, &.{body}, false)}),
        .hmac_base64 => try std.fmt.allocPrint(a, "sig={s}", .{try macText(a, Sha256, key, &.{body}, true)}),
        .standard => blk: {
            var buf: [47]u8 = undefined;
            break :blk try a.dupe(u8, try wh.sign.sign(key, "msg_1", ts, body, &buf));
        },
    };
    if (fault == .bad_prefix) sig[0] = 'x';
    if (fault == .truncated) sig = sig[0 .. sig.len - 1];
    var hs: std.ArrayList([2][]const u8) = .empty;
    if (fault != .no_header) try hs.append(a, .{ sig_names.get(kind), sig });
    switch (kind) {
        .slack => try hs.append(a, .{ "X-Slack-Request-Timestamp", ts_text }),
        .standard => try hs.appendSlice(a, &.{ .{ "webhook-id", "msg_1" }, .{ "webhook-timestamp", ts_text } }),
        else => {},
    }
    var res = try t.post(target, .{ .headers = hs.items, .body = if (fault == .body_altered) try std.fmt.allocPrint(a, "{s} ", .{body}) else body });
    defer res.deinit();
    return @intCast(@backingInt(res.status));
}

const body_1 = "{\"id\":\"evt_1\"}";

test "webhooks: Verify.check, every preset x fault and the window edge" {
    const gpa = std.testing.allocator;
    var clock = anole.jobs.testing.FakeClock.init(anole.db.Time.fromMillis(epoch_s * 1000));
    var app = try anole.App.init(gpa, .{ .executors = .exact(1) });
    defer app.deinit();
    inline for (routes) |r| app.with(.{app.webhookVerify(options(r.kind, r.tol, .none, &clock))}).post(path(r.kind, r.tol), countHit);
    var t = try anole.testing.client(&app);
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    inline for (routes) |r| {
        if (r.tol == 300) for (fault_rows) |row| {
            if (std.mem.indexOfScalar(Kind, row.kinds, r.kind) == null) continue;
            errdefer std.debug.print("\n{t} {t}\n", .{ r.kind, row.fault });
            const before = hits.load(.acquire);
            try std.testing.expectEqual(@as(u16, if (row.ok) 200 else 400), try send(&t, arena.allocator(), path(r.kind, r.tol), r.kind, row.fault, epoch_s, body_1));
            try std.testing.expectEqual(before + @intFromBool(row.ok), hits.load(.acquire));
        };
        if (comptime std.mem.indexOfScalar(Kind, &windowed, r.kind) != null) for ([_]i64{ -86400, -301, -300, -1, 0, 1, 300, 301, 86400 }) |off| {
            errdefer std.debug.print("\n{t} tol {d} offset {d}\n", .{ r.kind, r.tol, off });
            const accepted = @abs(off) <= @max(r.tol, 0);
            try std.testing.expectEqual(@as(u16, if (accepted) 200 else 400), try send(&t, arena.allocator(), path(r.kind, r.tol), r.kind, .none, epoch_s + off, body_1));
        };
    }
}

// A different assertion shape (two sends and a clock move), so its own test.
test "webhooks: Verify replay answers 200 without the handler, a valid old signature 400" {
    const gpa = std.testing.allocator;
    var clock = anole.jobs.testing.FakeClock.init(anole.db.Time.fromMillis(epoch_s * 1000));
    var app = try anole.App.init(gpa, .{ .executors = .exact(1) });
    defer app.deinit();
    app.with(.{app.webhookVerify(options(.stripe, 300, .{ .memory = .{} }, &clock))}).post(path(.stripe, 300), countHit);
    var t = try anole.testing.client(&app);
    defer t.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const start = hits.load(.acquire);
    const steps = [_]struct { body: []const u8 = body_1, status: u16 = 200, count: u32, after_s: i64 = 0 }{
        .{ .count = 1 },
        .{ .count = 1 },
        .{ .body = "{\"id\":\"evt_2\"}", .count = 2 },
        .{ .status = 400, .count = 2, .after_s = 301 },
    };
    for (steps) |s| {
        clock.advance(.fromSeconds(s.after_s));
        try std.testing.expectEqual(s.status, try send(&t, a, path(.stripe, 300), .stripe, .none, epoch_s, s.body));
        try std.testing.expectEqual(start + s.count, hits.load(.acquire));
    }
}
