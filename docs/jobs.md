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

_ = try state.jobs.enqueue(req, SendWelcome{ .user_id = 7 }, .{ .delay = .fromSeconds(30) });
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
| `.{ .postgres = client }` | durable; the tables are created at start (or `anole.jobs.sql(.postgresql, prefix, arena)`). Workers wake through LISTEN/NOTIFY (`notify = false` behind PgBouncer's transaction pooling), and the cron leader holds an advisory lock. |
| `.{ .redis = client }` | durable as far as Redis persists; keys under `key_prefix` (`"anole:"`), one Lua script per state change, a single Redis node, no transactions. Workers wake through pub/sub. |

The store client must come from the same app (`app.postgres(...)`,
`app.sqlite(...)` or `app.redis(...)`); `app.jobs` refuses another one.

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
deadline (`drain_timeout`, 10 s), then their tasks are canceled and they are
put back as available with the attempt not counted. The queue waits its own
`drain_timeout` even when the HTTP side has finished draining sooner. A run
that finished before the cancel keeps its outcome: its state write goes on
for up to 3 s past the deadline. Under `deployment = lambda` the queue only
enqueues.

The cancel reaches a handler at its next wait (a database call, a request,
a sleep). A handler that catches `error.Canceled` and returns success anyway
is recorded as completed, so let the error go up, or return it.

The longest stop is the longer of `timeouts.shutdown` (the HTTP drain) and
`drain_timeout` + 3 s. Give the service manager more than that before it
kills the process: `TimeoutStopSec` in systemd (see
[server.md](server.md#zero-downtime-restart-and-socket-activation)), `terminationGracePeriodSeconds` in
Kubernetes (30 s by default), the stop timeout of `docker stop` (10 s by
default, `--time`). A process killed earlier leaves its running jobs held
until their lease lapses; they then run again.

The app frees nothing a job handler may use until every run has ended: at
teardown the queue's work stops first (the drain under way included), then
the connectors are closed, last made first. Outside an app, call the
client's `stopWork` before you free what your handlers use.

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

## Transactions

On SQLite and PostgreSQL a job can be enqueued or completed inside your own
transaction:

```zig
var tx = try app.db.begin(req, .{});
defer tx.deinit();
const id = try tx.one(i64, req, "INSERT INTO users (email) VALUES ($1) RETURNING id", .{email});
_ = try app.jobs.enqueueIn(&tx, req, SendWelcome{ .user_id = id }, .{});
try tx.commit(req);
```

The job exists only if the transaction commits. `jobs.completeIn(&tx, job)` inside
a handler completes the job with the handler's own writes; if the transaction
rolls back, the job runs again after its lease. The transaction must belong to
the jobs store's own database (`error.InvalidJob` otherwise, with the reason in
the log). A memory or Redis store has no transactions.

## Metrics and traces

With `app.metrics()` the queue reports `anole_jobs_enqueued_total`,
`anole_jobs_duplicates_total`, `anole_jobs_finished_total{outcome}`,
`anole_jobs_run_seconds`, `anole_jobs_running`, `anole_jobs_queued{state}` (the
leader, every 15 s), `anole_jobs_rescued_total`,
`anole_jobs_outcome_unsaved_total` (runs that finished but whose state could
not be saved: they run again after their lease), `anole_jobs_leader` and
`anole_cron_enqueued_total`. `kind` and `name` take 256 distinct values; later
ones read `other`.

A job keeps the trace context it was enqueued from in its `meta`:
`traceparent` (with the trace flags as they were: a context passed on
unsampled stays `-00`) and the caller's `tracestate` when there is one
(`job.traceparent()`, `job.tracestate()`). From a request that is the
request's span when the app traces it, else the caller's `traceparent`
header as it came; from a running job it is that run's span. A `meta` that
sets its own `traceparent` is left alone. Through the C ABI,
`anole_jobs_enqueue` with `opts.req` takes that request's context the same
way, read during the call (before the request is answered).

With `app.tracing()`, each run is one span, `process <queue>`, of kind
CONSUMER. It is **linked** to the enqueuer's context, not a child of it, as
OpenTelemetry's messaging conventions recommend and as River's otelriver,
Oban's and Sidekiq's instrumentations do by default: a job that runs an
hour later, or retries for a day, does not stretch the request's trace. The
link carries the stored `tracestate`. Each attempt is a span of its own, in
a trace of its own, with these attributes:

| Attribute | Value |
| --- | --- |
| `messaging.system` | `anole` |
| `messaging.destination.name` | the queue |
| `messaging.operation.type` | `process` |
| `messaging.message.id` | the job's id |
| `anole.job.kind` | the kind |
| `anole.job.attempt`, `anole.job.max_attempts` | the attempt (1 on the first run), and how many the job gets |
| `anole.job.outcome` | `completed`, `retried`, `dead`, `snoozed`, `interrupted` or `lost` |
| `error.type` | the handler's error (`Timeout` when the run's timeout expired); the span's status is then ERROR. None for a run interrupted by a drain or lost (its lease expired, or it was cancelled): the cancel it got is not a failure |

Handlers see the span as `job.trace_id` and `job.span_id`, and a job they
enqueue carries it. With `.sample_all = false` a run is recorded only when
its enqueuer's context was sampled. The messaging conventions are still in
Development at OpenTelemetry, so these names may change with them. Runs that
end after the app freed its exporter (a drain that outlasts the server)
have their spans dropped and counted in `exporter.dropped`.
