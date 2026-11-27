# Background jobs

Up: [index](index.md). Related: [cron](cron.md) (schedules on the same client), [webhooks](webhooks.md) (deliveries run as jobs), [smtp](../storage-email-clients/smtp.md) (mail from a job).

`anole.jobs` runs work outside a request: an email, a slow call, anything that may fail and must be tried again. Stores: memory, SQLite, PostgreSQL, Redis. Retries with backoff, delays, priorities, unique jobs, leases with heartbeats, a leader for maintenance and cron, a drain at shutdown. Needs `-Djobs` ([config-cli](../config-cli.md#feature-flags-and-profiles)). Full docs: docs/jobs.md. Example: templates/full/src/main.zig (`services`).

Use:
- `anole.App.jobs` (src/server.zig): `app.jobs(options)` returns `*anole.jobs.Client`, owned by the server
- `anole.jobs.Client`: `handle`, `handleRaw`, `enqueue`, `enqueueRaw`, `enqueueIn`, `enqueueMany`, `completeIn`, `cron`, `get`, `list`, `counts`, `retry`, `cancel`, `delete`, `cronList`, `cronTrigger`, `adminRoutes`, `step`, `stopWork` (src/jobs/client.zig)
- `anole.jobs.Kind`, `anole.jobs.Options`, `anole.jobs.Store`, `anole.jobs.QueueOptions`, `anole.jobs.EnqueueOptions`, `anole.jobs.Unique`, `anole.jobs.Enqueued`, `anole.jobs.Priority`, `anole.jobs.State`, `anole.jobs.sql` (src/jobs/root.zig)
- `anole.jobs.Job`: `args`, `bind`, `snooze`, `discard`, `retryIn`, `explain`, `stopReason`, `traceparent`, `cronName`; fields `id`, `id_text`, `attempt`, `max_attempts`, `io`, `arena` (src/jobs/root.zig)
- `anole.jobs.testing.FakeClock` (src/jobs/root.zig)

## Declare, register, enqueue

```zig
const SendWelcome = struct {
    user_id: i64,
    pub const job: anole.jobs.Kind = .{ .name = "email.welcome", .queue = "mail", .attempts = 8 };
};

state.jobs = try app.jobs(.{ .store = .memory, .queues = &.{ .{ .name = "default" }, .{ .name = "mail", .concurrency = 4 } } });
try state.jobs.handle(&app, SendWelcome, .{}, sendWelcome);

fn sendWelcome(app: *App, job: *anole.jobs.Job, args: SendWelcome) !void { ... }

_ = try state.jobs.enqueue(req, SendWelcome{ .user_id = 7 }, .{ .delay = .fromSeconds(30) });
```

The args type is the job: its `pub const job: anole.jobs.Kind` sets `name`, `queue` ("default"), `priority`, `attempts` (20), `backoff` (15 s doubling to 6 h, equal jitter) and `timeout` (15 min). Handler shapes: `fn (*Job, Args) !void` or `fn (*App, *Job, Args) !void`. A `*Job` is a context like a request: `app.db.exec(job, ...)`, `app.mail.send(job, ...)`.

`EnqueueOptions`: `queue`, `priority`, `run_at` or `delay` (not both), `attempts`, `timeout`, `unique`, `meta`.

## Stores

```zig
state.jobs = try app.jobs(.{ .store = .{ .sqlite = state.db } });   // templates/full
const jobs = try app.jobs(.{ .store = .{ .postgres = pg } });       // docs/webhooks.md
```

`.memory` is lost on restart (tests, single process). `.sqlite`, `.postgres`, `.redis` are durable; tables are made at start (`migrate = false` plus `anole.jobs.sql(.postgresql, prefix, arena)` to migrate yourself). PostgreSQL wakes workers by LISTEN/NOTIFY (`notify = false` behind PgBouncer transaction pooling); Redis by pub/sub.

## Inside a handler

- Return an error: a failed attempt, retried with the kind's backoff.
- `job.snooze(d)`: run again after `d`, attempt not counted.
- `job.discard(reason)`: dead now. `job.retryIn(d)`: failed, retry after `d`. `job.explain(fmt, args)`: a message stored with the error.
- `job.bind(T)` validates args with `T`'s `field_rules`; a violation discards (it can never pass). `handle` already binds for you.

## Unique jobs and transactions

`.unique = .{}` returns the existing job (`Enqueued.inserted = false`) while one with the same kind and args is waiting or running. `.key` replaces the args in the key, `.period` makes it unique per window, `.scope` is `.pending`, `.unfinished` (default) or `.any` (an idempotency key kept until pruned).

```zig
var tx = try app.db.begin(req, .{});
defer tx.deinit();
const id = try tx.one(i64, req, "INSERT INTO users (email) VALUES ($1) RETURNING id", .{email});
_ = try app.jobs.enqueueIn(&tx, req, SendWelcome{ .user_id = id }, .{});
try tx.commit(req);
```

SQLite and PostgreSQL only: the job exists only if the transaction commits. `jobs.completeIn(&tx, job)` completes the job with the handler's own writes. The transaction must be on the jobs store's database (else `error.InvalidJob`).

## Admin and tests

`jobs.adminRoutes(group)` mounts `GET /jobs`, `GET /jobs/:id`, `POST /jobs/:id/retry`, `POST /jobs/:id/cancel`, `DELETE /jobs/:id`, `GET /counts`, `GET /cron`, `POST /cron/:name/trigger`. Put the group behind your own auth ([middleware and auth](../middleware-auth/index.md)). Tests: `.run = .manual` plus `anole.jobs.testing.FakeClock`; `jobs.step(ctx)` runs one round, advance the clock instead of sleeping ([testing](../testing.md)).

Traps:
- A job runs **at least once**: a lost lease or a deploy runs it again. Make the handler safe to repeat (check before sending, idempotency keys) (docs/jobs.md#what-a-job-is).
- The drain cancels a running handler at its next wait. A handler that catches `error.Canceled` and returns success is recorded **completed**; let it go up ([re-raise error.Canceled](../runtime.md#re-raise-errorcanceled), docs/jobs.md#drain).
- A handler runs on an executor: CPU-heavy or blocking work goes through [anole.blocking](../runtime.md#never-block-an-executor). The kind's `timeout` cancels a stuck handler and counts a failed attempt.
- The store client must come from the same app (`app.postgres`, `app.sqlite`, `app.redis`); `app.jobs` refuses another with `error.InvalidOptions` (src/server.zig `jobs`).
- Give the service manager more stop time than `max(timeouts.shutdown, drain_timeout + 3 s)` (`drain_timeout` 10 s), or running jobs stay held until their lease (30 s) lapses ([deployment](../deployment/lifecycle.md#graceful-drain)).
- Instances need synchronized clocks (NTP).
- Outside an app, call `stopWork` before freeing what handlers use.
