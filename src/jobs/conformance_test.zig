//! Behaviour every store keeps, run here on the memory store (p3/jobs,
//! design-jobs.md §14). `FakeClock` and `run = .manual` with `step` make the
//! tests deterministic: nothing here waits for time to pass.
const std = @import("std");
const root = @import("root.zig");
const Time = root.Time;
const anole = @import("../root.zig");
const Backend = enum { memory, sqlite, postgres, redis };
const features = anole.features;
const build_options = @import("build_options");
const zio = @import("zio");

/// The Redis server of the live tests, or null.
const redis_url: ?[]const u8 = if (build_options.redis_test_url) |u| u else if (build_options.redis_test_port) |p| std.fmt.comptimePrint("redis://127.0.0.1:{d}", .{p}) else null;
const testing_mod = @import("../testing/root.zig");

fn Suite(comptime B: Backend) type {
    return struct {
        const Ctx = anole.db.Ctx;

        const Fx = struct {
            arena_state: std.heap.ArenaAllocator,
            clock: root.testing.FakeClock,
            client: *root.Client,
            ctx: Ctx,
            logs: testing_mod.LogCapture,
            level: std.log.Level,

            sq: if (B == .sqlite) *anole.sqlite.Client else void,
            /// PostgreSQL and Redis run on their own zio runtime, like the connectors' live tests.
            rt: if (B == .postgres or B == .redis) *zio.Runtime else void,
            pgc: if (B == .postgres) *anole.pg.Client else void,
            rdc: if (B == .redis) *anole.redis.Client else void,

            fn init(fx: *Fx, queues: []const root.QueueOptions) !void {
                // Live stores skip without a server (-Dpostgres-test-url, -Dredis-test-url).
                if (B == .postgres and (!features.postgres or build_options.postgres_test_url == null)) return error.SkipZigTest;
                if (B == .redis and (!features.redis or redis_url == null)) return error.SkipZigTest;
                var io = std.testing.io;
                if (B == .postgres or B == .redis) {
                    fx.rt = try zio.Runtime.init(std.testing.allocator, .{ .executors = .exact(1) });
                    io = fx.rt.io();
                }
                var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer scratch.deinit();
                var wipe: anole.db.Ctx = .{ .io = io, .arena = scratch.allocator() };
                if (B == .postgres) {
                    fx.pgc = try anole.pg.Client.init(std.testing.allocator, io, .{ .url = build_options.postgres_test_url.?, .environ = .empty });
                    try fx.pgc.execScript(&wipe, "DROP TABLE IF EXISTS jtest_jobs, jtest_cron, jtest_leader, jtest_schema");
                }
                if (B == .redis) {
                    fx.rdc = try anole.redis.Client.init(std.testing.allocator, io, .{ .url = redis_url.?, .environ = .empty });
                    _ = try fx.rdc.with(.{}).reply(&wipe, &.{ "EVAL", "for _, k in ipairs(redis.call('KEYS', ARGV[1] .. '*')) do redis.call('DEL', k) end", "0", "jtest:" });
                }
                fx.level = std.testing.log_level;
                std.testing.log_level = .err;
                fx.logs = .init(std.testing.allocator);
                fx.logs.start();
                fx.arena_state = .init(std.testing.allocator);
                if (B == .sqlite) fx.sq = try anole.sqlite.Client.init(std.testing.allocator, std.testing.io, .{ .path = ":memory:" });
                fx.clock = .init(Time.fromSeconds(1_800_000_000));
                fx.client = try root.Client.init(std.testing.allocator, io, .{
                    .store = switch (B) {
                        .sqlite => .{ .sqlite = fx.sq },
                        .postgres => .{ .postgres = fx.pgc },
                        .redis => .{ .redis = fx.rdc },
                        .memory => .memory,
                    },
                    .table_prefix = "jtest_",
                    .key_prefix = "jtest:",
                    .run = .manual,
                    .queues = queues,
                    .clock = fx.clock.clock(),
                    .name = "test",
                });
                fx.ctx = .{ .io = io, .arena = fx.arena_state.allocator() };
            }
            fn deinit(fx: *Fx) void {
                fx.client.deinit();
                if (B == .sqlite) fx.sq.deinit();
                if (B == .postgres) fx.pgc.deinit();
                if (B == .redis) fx.rdc.deinit();
                if (B == .postgres or B == .redis) fx.rt.deinit();
                fx.arena_state.deinit();
                fx.logs.deinit();
                std.testing.log_level = fx.level;
            }
        };

        const Probe = struct {
            var runs: u32 = 0;
            var order: [16]u8 = undefined;
            var n: usize = 0;
            var fail_times: u32 = 0;
            var mode: enum { ok, snooze, discard, retry_in } = .ok;
            fn reset() void {
                runs = 0;
                n = 0;
                fail_times = 0;
                mode = .ok;
            }
            fn run(_: ?*anyopaque, job: *root.Job) anyerror!void {
                runs += 1;
                if (n < order.len) {
                    var at = std.mem.indexOf(u8, job.args_json, ":").? + 1;
                    // jsonb writes `{"a": 1}`: skip the blank.
                    while (job.args_json[at] == ' ') at += 1;
                    order[n] = job.args_json[at];
                    n += 1;
                }
                if (fail_times > 0) {
                    fail_times -= 1;
                    return error.Boom;
                }
                switch (mode) {
                    .ok => {},
                    .snooze => job.snooze(.fromSeconds(300)),
                    .discard => job.discard("no thanks"),
                    .retry_in => job.retryIn(.fromSeconds(7)),
                }
            }
        };

        const plain: root.Kind = .{ .name = "t.plain", .attempts = 3, .backoff = .{ .base = .fromSeconds(15), .max = .fromSeconds(21600), .multiplier = 2, .jitter = .none }, .timeout = .max };

        fn setup(fx: *Fx) !void {
            Probe.reset();
            try fx.init(&.{.{ .name = "default" }});
            try fx.client.addHandler(plain, null, Probe.run);
            try fx.client.start(null, null, null);
        }

        test "jobs: enqueue then step runs it once and completes it" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            try std.testing.expect(e.inserted);
            const rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.completed);
            try std.testing.expectEqual(@as(u32, 1), Probe.runs);
            const info = (try fx.client.get(&fx.ctx, e.id)).?;
            try std.testing.expectEqual(root.State.completed, info.state);
            const rep2 = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 0), rep2.ran);
        }

        test "jobs: run_at in the future waits until the clock passes it" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .delay = .fromSeconds(60) });
            try std.testing.expectEqual(@as(u32, 0), (try fx.client.step(&fx.ctx)).ran);
            try std.testing.expectEqual(root.State.scheduled, (try fx.client.get(&fx.ctx, e.id)).?.state);
            fx.clock.advance(.fromSeconds(61));
            try std.testing.expectEqual(@as(u32, 1), (try fx.client.step(&fx.ctx)).completed);
        }

        test "jobs: priority order, then run_at, then id" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":\"L\"}", .{ .priority = .low });
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":\"N\"}", .{});
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":\"C\"}", .{ .priority = .critical });
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":\"H\"}", .{ .priority = .high });
            _ = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(usize, 4), Probe.n);
            // Args are `{"a":"X"}`: the probe records the byte after the colon, a quote; use the letter after it.
            try std.testing.expectEqualStrings("\"\"\"\"", Probe.order[0..4]);
        }

        test "jobs: an error retries with backoff and the last attempt makes it dead" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            Probe.fail_times = 10;
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            var rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.retried);
            var info = (try fx.client.get(&fx.ctx, e.id)).?;
            try std.testing.expectEqual(root.State.retrying, info.state);
            try std.testing.expectEqual(fx.clock.ms.load(.acquire) + 15_000, @divFloor(info.run_at.us, 1000));
            fx.clock.advance(.fromSeconds(15));
            rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.retried);
            info = (try fx.client.get(&fx.ctx, e.id)).?;
            try std.testing.expectEqual(fx.clock.ms.load(.acquire) + 30_000, @divFloor(info.run_at.us, 1000));
            fx.clock.advance(.fromSeconds(30));
            rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.dead);
            info = (try fx.client.get(&fx.ctx, e.id)).?;
            try std.testing.expectEqual(root.State.dead, info.state);
            try std.testing.expectEqual(@as(usize, 3), info.errors.len);
            try std.testing.expectEqualStrings("Boom", info.errors[0].@"error");
        }

        test "jobs: snooze keeps the attempt, discard is dead, retryIn uses its delay" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            Probe.mode = .snooze;
            const a = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            _ = try fx.client.step(&fx.ctx);
            var info = (try fx.client.get(&fx.ctx, a.id)).?;
            try std.testing.expectEqual(root.State.scheduled, info.state);
            try std.testing.expectEqual(@as(u16, 0), info.attempt);

            Probe.mode = .discard;
            const b = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":2}", .{});
            _ = try fx.client.step(&fx.ctx);
            info = (try fx.client.get(&fx.ctx, b.id)).?;
            try std.testing.expectEqual(root.State.dead, info.state);
            try std.testing.expectEqualStrings("no thanks", info.errors[0].message);

            Probe.mode = .retry_in;
            const c = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":3}", .{});
            _ = try fx.client.step(&fx.ctx);
            info = (try fx.client.get(&fx.ctx, c.id)).?;
            try std.testing.expectEqual(root.State.retrying, info.state);
            try std.testing.expectEqual(fx.clock.ms.load(.acquire) + 7_000, @divFloor(info.run_at.us, 1000));
        }

        test "jobs: unique unfinished returns the existing id; completion frees the key" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const u: root.Unique = .{};
            const a = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            const b = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            try std.testing.expect(a.inserted and !b.inserted);
            try std.testing.expectEqual(a.id, b.id);
            _ = try fx.client.step(&fx.ctx);
            const c = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            try std.testing.expect(c.inserted);
        }

        test "jobs: unique any blocks after completion until pruned" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const u: root.Unique = .{ .scope = .any, .key = "idem-1" };
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            _ = try fx.client.step(&fx.ctx);
            const again = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            try std.testing.expect(!again.inserted);
        }

        test "jobs: unique period: the next window inserts" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const u: root.Unique = .{ .period = .fromSeconds(600) };
            const a = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            const b = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            try std.testing.expect(a.inserted and !b.inserted);
            fx.clock.advance(.fromSeconds(660));
            const c = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{ .unique = u });
            try std.testing.expect(c.inserted);
        }

        test "jobs: a lapsed lease is rescued, the attempt counted, and the old holder's write changes nothing" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const be = fx.client.backend;
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            const t0 = Time.fromSeconds(1_800_000_000);
            const claimed = try be.vt.claim(be.ptr, fx.ctx.arena, .{ .queue = "default", .kinds = null, .limit = 1, .now = t0, .lease_until = .{ .us = t0.us + 30_000_000 }, .worker = "w1" });
            try std.testing.expectEqual(@as(usize, 1), claimed.len);
            fx.clock.advance(.fromSeconds(31));
            const rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.rescued);
            try std.testing.expectEqual(@as(u32, 1), rep.completed);
            const info = (try fx.client.get(&fx.ctx, e.id)).?;
            try std.testing.expectEqual(@as(u16, 2), info.attempt);
            try std.testing.expectEqualStrings("LeaseExpired", info.errors[0].@"error");
            // The first holder (attempt 1) tries to complete.
            const ok = try be.vt.finish(be.ptr, .{ .id = e.id, .attempt = 1, .to = .completed });
            try std.testing.expect(!ok);
        }

        test "jobs: kinds filter: a client never claims a kind it has no handler for" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const other = try fx.client.enqueueRaw(&fx.ctx, "t.other", "{}", .{});
            _ = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(root.State.available, (try fx.client.get(&fx.ctx, other.id)).?.state);
        }

        test "jobs: enqueueMany with duplicates" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            var items: [250]root.Client.Item = undefined;
            var bufs: [250][24]u8 = undefined;
            for (&items, 0..) |*it, i| {
                const args = std.fmt.bufPrint(&bufs[i], "{{\"n\":{d}}}", .{i % 200}) catch unreachable;
                it.* = .{ .kind = "t.plain", .args_json = args, .opts = .{ .unique = .{} } };
            }
            const out = try fx.client.enqueueMany(&fx.ctx, &items);
            var inserted: u32 = 0;
            for (out) |o| {
                if (o.inserted) inserted += 1;
            }
            try std.testing.expectEqual(@as(u32, 200), inserted);
            try std.testing.expectEqual(out[0].id, out[200].id);
        }

        test "jobs: admin retry, cancel and delete follow the state table" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            Probe.mode = .discard;
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            _ = try fx.client.step(&fx.ctx);
            try std.testing.expect(!(try fx.client.cancel(&fx.ctx, e.id)));
            try std.testing.expect(try fx.client.retry(&fx.ctx, e.id));
            try std.testing.expect(!(try fx.client.delete(&fx.ctx, e.id)));
            try std.testing.expect(try fx.client.cancel(&fx.ctx, e.id));
            try std.testing.expect(try fx.client.delete(&fx.ctx, e.id));
            try std.testing.expect((try fx.client.get(&fx.ctx, e.id)) == null);
            const counts = try fx.client.counts(&fx.ctx);
            try std.testing.expectEqual(@as(usize, 0), counts.len);
        }

        test "jobs: prune removes completed after keep" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            _ = try fx.client.step(&fx.ctx);
            fx.clock.advance(.fromSeconds(90000));
            fx.client.last_prune = 0;
            const rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.pruned);
            try std.testing.expect((try fx.client.get(&fx.ctx, e.id)) == null);
        }

        test "jobs: invalid enqueue arguments are refused" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            try std.testing.expectError(error.InvalidJob, fx.client.enqueueRaw(&fx.ctx, "t.plain", "{nope", .{}));
            try std.testing.expectError(error.InvalidJob, fx.client.enqueueRaw(&fx.ctx, "t.plain", "{}", .{ .delay = .fromSeconds(1), .run_at = Time.fromSeconds(5) }));
            try std.testing.expectError(error.InvalidJob, fx.client.enqueueRaw(&fx.ctx, "bad kind!", "{}", .{}));
            try std.testing.expectError(error.InvalidJob, fx.client.enqueueRaw(&fx.ctx, "t.plain", "{}", .{ .meta = "[1]" }));
        }

        test "jobs: leader: two clients on one store, exactly one leads" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const be = fx.client.backend;
            const t0 = Time.fromSeconds(1_800_000_000);
            try std.testing.expect(try be.vt.leaderTake(be.ptr, "a", t0, .fromSeconds(15)));
            try std.testing.expect(!(try be.vt.leaderTake(be.ptr, "b", t0, .fromSeconds(15))));
            try std.testing.expect(try be.vt.leaderTake(be.ptr, "a", t0, .fromSeconds(15)));
            try be.vt.leaderRelease(be.ptr, "a");
            try std.testing.expect(try be.vt.leaderTake(be.ptr, "b", t0, .fromSeconds(15)));
        }

        fn cronFx(fx: *Fx, missed: root.CronOptions.Missed) !void {
            Probe.reset();
            try fx.init(&.{.{ .name = "default" }});
            try fx.client.addHandler(plain, null, Probe.run);
            try fx.client.cronRaw("tick", "*/10 * * * *", "t.plain", "{\"a\":1}", .{ .missed = missed });
            try fx.client.start(null, null, null);
        }

        test "cron: a new schedule does not backfill; each due tick enqueues one job" {
            var fx: Fx = undefined;
            try cronFx(&fx, .once);
            defer fx.deinit();
            var rep = try fx.client.step(&fx.ctx); // first sight records now
            try std.testing.expectEqual(@as(u32, 0), rep.cron_enqueued);
            fx.clock.advance(.fromSeconds(600));
            rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.cron_enqueued);
            try std.testing.expectEqual(@as(u32, 1), rep.completed);
            // Same instant again: the tick was recorded, nothing more.
            rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 0), rep.cron_enqueued);
        }

        test "cron: missed once enqueues only the latest tick" {
            var fx: Fx = undefined;
            try cronFx(&fx, .once);
            defer fx.deinit();
            _ = try fx.client.step(&fx.ctx);
            fx.clock.advance(.fromSeconds(7200));
            const rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.cron_enqueued);
        }

        test "cron: missed skip enqueues none; missed all enqueues each tick inside catch_up" {
            // One fixture at a time: the live stores' fixtures each own a zio
            // runtime, and a thread can only use the one it made last.
            {
                var a: Fx = undefined;
                try cronFx(&a, .skip);
                defer a.deinit();
                _ = try a.client.step(&a.ctx);
                a.clock.advance(.fromSeconds(7620));
                try std.testing.expectEqual(@as(u32, 0), (try a.client.step(&a.ctx)).cron_enqueued);
            }
            var b: Fx = undefined;
            try cronFx(&b, .all);
            defer b.deinit();
            _ = try b.client.step(&b.ctx);
            b.clock.advance(.fromSeconds(3600));
            const rep = try b.client.step(&b.ctx);
            try std.testing.expect(rep.cron_enqueued >= 5 and rep.cron_enqueued <= 7);
        }

        test "cron: two clients sharing nothing still record one job per tick through the store" {
            var fx: Fx = undefined;
            try cronFx(&fx, .once);
            defer fx.deinit();
            _ = try fx.client.step(&fx.ctx);
            fx.clock.advance(.fromSeconds(600));
            const be = fx.client.backend;
            const t = fx.clock.clock().now(null orelse fx.clock.clock().context);
            // Two contenders record the same tick: only the first wins.
            const r1 = try be.vt.cronTick(be.ptr, t, "tick", "*/10 * * * *", t, null);
            const r2 = try be.vt.cronTick(be.ptr, t, "tick", "*/10 * * * *", t, null);
            try std.testing.expect(r1.recorded and !r2.recorded);
        }

        const Typed = struct {
            n: i64,
            pub const job: root.Kind = plain;
        };

        var tx_fx: *Fx = undefined;
        fn completingHandler(_: ?*anyopaque, job: *root.Job) anyerror!void {
            if (B != .sqlite and B != .postgres) unreachable;
            var tx = try txDb(tx_fx).begin(&tx_fx.ctx, .{});
            defer tx.deinit();
            try tx_fx.client.completeIn(&tx, job);
            try tx.commit(&tx_fx.ctx);
        }

        /// The store's own database, for the transactional calls (SQLite, PostgreSQL).
        fn txDb(fx: *Fx) if (B == .sqlite) *anole.sqlite.Client else if (B == .postgres) *anole.pg.Client else void {
            return switch (B) {
                .sqlite => fx.sq,
                .postgres => fx.pgc,
                else => {},
            };
        }

        test "jobs: enqueueIn rolls back with the transaction and commits with it" {
            if (B != .sqlite and B != .postgres) return error.SkipZigTest;
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            {
                var tx = try txDb(&fx).begin(&fx.ctx, .{});
                defer tx.deinit();
                _ = try fx.client.enqueueIn(&tx, &fx.ctx, Typed{ .n = 1 }, .{});
                try tx.rollback(&fx.ctx);
            }
            try std.testing.expectEqual(@as(u32, 0), (try fx.client.step(&fx.ctx)).ran);
            {
                var tx = try txDb(&fx).begin(&fx.ctx, .{});
                defer tx.deinit();
                _ = try fx.client.enqueueIn(&tx, &fx.ctx, Typed{ .n = 2 }, .{});
                try tx.commit(&fx.ctx);
            }
            try std.testing.expectEqual(@as(u32, 1), (try fx.client.step(&fx.ctx)).completed);
        }

        test "jobs: completeIn completes inside the handler's transaction" {
            if (B != .sqlite and B != .postgres) return error.SkipZigTest;
            var fx: Fx = undefined;
            Probe.reset();
            try fx.init(&.{.{ .name = "default" }});
            defer fx.deinit();
            tx_fx = &fx;
            try fx.client.addHandler(plain, null, completingHandler);
            try fx.client.start(null, null, null);
            const e = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            const rep = try fx.client.step(&fx.ctx);
            try std.testing.expectEqual(@as(u32, 1), rep.completed);
            try std.testing.expectEqual(root.State.completed, (try fx.client.get(&fx.ctx, e.id)).?.state);
        }

        test "jobs: enqueueIn on a memory store is refused" {
            if (B != .memory) return error.SkipZigTest;
            if (!anole.features.sqlite) return error.SkipZigTest;
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            const sq = try anole.sqlite.Client.init(std.testing.allocator, std.testing.io, .{ .path = ":memory:" });
            defer sq.deinit();
            var tx = try sq.begin(&fx.ctx, .{});
            defer tx.deinit();
            try std.testing.expectError(error.InvalidJob, fx.client.enqueueIn(&tx, &fx.ctx, Typed{ .n = 1 }, .{}));
        }

        var child_id: root.Id = 0;
        fn parentHandler(_: ?*anyopaque, job: *root.Job) anyerror!void {
            const r = try job.client.enqueueRaw(job, "t.child", "{}", .{});
            child_id = r.id;
        }

        test "jobs: a job enqueued from a job carries the traceparent of its parent" {
            var fx: Fx = undefined;
            Probe.reset();
            try fx.init(&.{.{ .name = "default" }});
            defer fx.deinit();
            try fx.client.addHandler(plain, null, parentHandler);
            try fx.client.start(null, null, null);
            const tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
            _ = try fx.client.enqueueRaw(&fx.ctx, "t.plain", "{}", .{ .meta = "{\"traceparent\":\"" ++ tp ++ "\"}" });
            _ = try fx.client.step(&fx.ctx);
            const child = (try fx.client.get(&fx.ctx, child_id)).?;
            try std.testing.expectEqualStrings(tp, child.meta.object.get("traceparent").?.string);
        }

        test "jobs: the series are rendered" {
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            var registry = anole.observe.metrics.Registry.init(std.testing.allocator, std.testing.io);
            defer registry.deinit();
            // `setup` started the client; a second client with a registry shows the series.
            const c2 = try root.Client.init(std.testing.allocator, std.testing.io, .{ .store = .memory, .run = .manual });
            defer c2.deinit();
            try c2.addHandler(plain, null, Probe.run);
            try c2.start(&registry, null, null);
            _ = try c2.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            _ = try c2.step(&fx.ctx);
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try registry.render(&out.writer);
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "anole_jobs_enqueued_total{queue=\"default\",kind=\"t.plain\"} 1") != null);
            try std.testing.expect(std.mem.indexOf(u8, out.written(), "anole_jobs_finished_total{queue=\"default\",kind=\"t.plain\",outcome=\"completed\"} 1") != null);
        }

        var bg_event: std.Io.Event = .unset;
        fn bgRun(_: ?*anyopaque, job: *root.Job) anyerror!void {
            _ = job;
            bg_event.set(std.testing.io);
        }

        test "jobs: the background runner claims and runs an enqueued job, and drains" {
            const io = std.testing.io;
            bg_event = .unset;
            const lvl = std.testing.log_level;
            std.testing.log_level = .err;
            defer std.testing.log_level = lvl;
            const client = try root.Client.init(std.testing.allocator, io, .{ .store = .memory });
            defer client.deinit();
            try client.addHandler(plain, null, bgRun);
            try client.start(null, null, null);
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var ctx: Ctx = .{ .io = io, .arena = arena.allocator() };
            const e = try client.enqueueRaw(&ctx, "t.plain", "{\"a\":1}", .{});
            try bg_event.wait(io);
            // The state write follows the handler's return; drain waits for the task.
            client.drain(std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(5), .clock = .awake }));
            const info = (try client.get(&ctx, e.id)).?;
            try std.testing.expectEqual(root.State.completed, info.state);
        }

        var wake_hits: std.atomic.Value(u32) = .init(0);
        fn wakeRun(_: ?*anyopaque, _: *root.Job) anyerror!void {
            _ = wake_hits.fetchAdd(1, .acq_rel);
        }

        test "jobs: live wake-up: a job another client enqueues runs long before the poll interval" {
            // PostgreSQL LISTEN/NOTIFY and Redis SUBSCRIBE/PUBLISH carry the wake-up.
            if (B != .postgres and B != .redis) return error.SkipZigTest;
            var fx: Fx = undefined;
            try fx.init(&.{.{ .name = "default" }});
            defer fx.deinit();
            const io = fx.ctx.io;
            const st: root.Store = switch (B) {
                .postgres => .{ .postgres = fx.pgc },
                .redis => .{ .redis = fx.rdc },
                else => unreachable,
            };
            wake_hits.store(0, .release);
            const worker = try root.Client.init(std.testing.allocator, io, .{ .store = st, .table_prefix = "jtest_", .key_prefix = "jtest:", .poll_interval = .fromSeconds(60), .name = "worker" });
            defer worker.deinit();
            try worker.addHandler(plain, null, wakeRun);
            try worker.start(null, null, null);
            defer worker.drain(std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .fromSeconds(5), .clock = .awake }));
            const producer = try root.Client.init(std.testing.allocator, io, .{ .store = st, .table_prefix = "jtest_", .key_prefix = "jtest:", .run = .enqueue_only, .name = "producer" });
            defer producer.deinit();
            try producer.start(null, null, null);
            // The worker's first claim found nothing; its fetcher now waits for a wake or the 60 s poll.
            try io.sleep(.fromMilliseconds(1500), .awake);
            _ = try producer.enqueueRaw(&fx.ctx, "t.plain", "{\"a\":1}", .{});
            var waited: u32 = 0;
            while (wake_hits.load(.acquire) == 0 and waited < 100) : (waited += 1) try io.sleep(.fromMilliseconds(50), .awake);
            try std.testing.expectEqual(@as(u32, 1), wake_hits.load(.acquire));
        }

        test "jobs: adminRoutes registers on a group" {
            // The live stores run on a runtime of their own; the server wants the thread for itself.
            if (B == .postgres or B == .redis) return error.SkipZigTest;
            const gpa = std.testing.allocator;
            var state: struct {} = .{};
            var app = try anole.Server(@TypeOf(state)).init(gpa, .{}, &state);
            defer app.deinit();
            var fx: Fx = undefined;
            try setup(&fx);
            defer fx.deinit();
            fx.client.adminRoutes(app.group("/admin", .{}));
        }
    };
}

test {
    _ = Suite(.memory);
    if (anole.features.sqlite) _ = Suite(.sqlite);
    if (anole.features.postgres) _ = Suite(.postgres);
    if (anole.features.redis) _ = Suite(.redis);
}
