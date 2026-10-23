# Background jobs

`anole.jobs` runs work outside a request: sending an email, calling a slow
service, anything that may fail and must be tried again. It is built in
(`-Djobs`, on in the `web` and `full` profiles).

```zig
const SendWelcome = struct {
    user_id: i64,
    pub const job: anole.jobs.Kind = .{ .name = "email.welcome", .queue = "mail", .attempts = 8 };
};

state.jobs = try app.jobs(.{ .store = .memory, .queues = &.{ .{ .name = "default" }, .{ .name = "mail", .concurrency = 4 } } });
try state.jobs.handle(&app, SendWelcome, .{}, sendWelcome);

fn sendWelcome(app: *App, job: *anole.jobs.Job, args: SendWelcome) !void { ... }

_ = try app.jobs.enqueue(req, SendWelcome{ .user_id = 7 }, .{ .delay = .fromSeconds(30) });
```

## What a job is

A job runs **at least once**. A worker that dies, loses its lease or is cut
off at a deploy leaves the job to run again, so a handler must be safe to
repeat (check before sending, use idempotency keys with other services).

Each job has a kind (its name, queue, priority, attempts, backoff and
timeout, declared on the args type), JSON arguments, and a state:
`scheduled`, `available`, `running`, `retrying`, `completed`, `dead` or
`cancelled`.

## Stores

| Store | Status |
| --- | --- |
| `.memory` | in this process only; lost on restart. Tests and single-process apps. |
| `.{ .sqlite = client }` | durable; the tables are created at start (`migrate = false` and `anole.jobs.sql(.sqlite, prefix, arena)` if you migrate yourself). |
| `.{ .postgres = client }`, `.{ .redis = client }` | not built yet in this build; `app.jobs` refuses them with a message. |

The store client must come from the same app (`app.sqlite(...)`).

## Handlers

A handler returns an error to retry with backoff (default: 20 tries, 15 s
doubling to 6 h, equal jitter). Inside it:

- `job.snooze(d)`: run again after `d`, the attempt not counted;
- `job.discard(reason)`: dead now;
- `job.retryIn(d)`: a failed attempt, retried after `d`;
- `job.explain(fmt, args)`: a message stored with the error.

A timeout (15 minutes by default, per kind) cancels the handler and counts a
failed attempt. `job.bind(T)` validates the arguments with `T`'s
`field_rules`; a violation discards the job, since it can never pass.

## Unique jobs

`.unique = .{}` returns the existing job while one with the same kind and
arguments is waiting or running (`inserted = false`). `.key` replaces the
arguments in the key, `.period` makes it unique per time window, and
`.scope = .any` keeps the key after the job finished until it is pruned (an
idempotency key).

## Leases and maintenance

A claimed job holds a lease (30 s) that a heartbeat extends while it runs.
Any instance puts a job whose lease lapsed back (with the error
`LeaseExpired`), and a worker that lost its lease can no longer complete,
fail or snooze it: every write after the claim checks the attempt number.
One instance (the leader) prunes finished jobs (completed after 24 h, dead
after 30 d, cancelled after 7 d) and runs the cron schedules.

Instances need synchronized clocks (NTP); every time written comes from
`Options.clock`.

## Drain

At shutdown the workers stop claiming; running jobs get the drain
deadline, then are put back as available with the attempt not counted.
Under `deployment = lambda` the queue only enqueues.

## Admin

`jobs.get`, `list`, `counts`, `retry`, `cancel`, `delete`, `cronList` and
`cronTrigger` are plain calls. `jobs.adminRoutes(group)` mounts them as
JSON routes (`GET /jobs`, `GET /jobs/:id`, `POST /jobs/:id/retry`,
`POST /jobs/:id/cancel`, `DELETE /jobs/:id`, `GET /counts`, `GET /cron`,
`POST /cron/:name/trigger`). Mount them behind your own authentication; there
is no web page.

## Testing

Set `.run = .manual` and an `anole.jobs.testing.FakeClock`; `jobs.step(ctx)`
runs one round (leader, cron, stage, rescue, prune, then every due job) and
returns a report. Nothing waits for time to pass: advance the clock.

## Not built yet

`enqueueIn`/`completeIn` (transactional enqueue), the PostgreSQL and Redis
stores, metrics and traces for jobs, and most of the C ABI (`anole_jobs_get`
exists; enqueue, workers and admin do not).
