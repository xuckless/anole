# Cron schedules

Up: [index](index.md). Related: [jobs](jobs.md) (each tick is a job on the same client).

Schedules are a jobs feature: `jobs.cron` enqueues one job per tick across all instances (the tick is stored with the job, and the job carries a unique key of schedule name plus tick, so two racing instances produce one job). `anole.cron` exists when `-Djobs` is on. Full docs: docs/cron.md. Example: templates/full/src/main.zig (`Sweep`).

Use:
- `anole.jobs.Client.cron`, `anole.jobs.Client.cronRaw`, `anole.jobs.Client.cronList`, `anole.jobs.Client.cronTrigger` (src/jobs/client.zig)
- `anole.jobs.CronOptions` (`tz`, `missed`, `catch_up`, `job`) (src/jobs/root.zig)
- `anole.jobs.Job.cronName` (src/jobs/root.zig)
- `anole.cron.Schedule` (`parse`, `next`, `between`), `anole.cron.Diagnostic`, `anole.cron.Zone` (src/cron/root.zig, src/cron/zone.zig)

## A schedule

```zig
const Sweep = struct {
    pub const job: anole.jobs.Kind = .{ .name = "todos.sweep" };
};

fn sweep(app: *App, job: *anole.jobs.Job, _: Sweep) !void {
    const removed = try app.db.exec(job, "DELETE FROM todos WHERE done = 1", .{});
    _ = try app.live.publishJson("todos", "swept", .{ .removed = removed });
}

state.jobs = try app.jobs(.{ .store = .{ .sqlite = state.db } });
try state.jobs.handle(app, Sweep, .{}, sweep);
try state.jobs.cron("todos.sweep", "0 3 * * *", Sweep{}, .{});
```

With a time zone (docs/cron.md):

```zig
try state.jobs.cron("nightly", "0 3 * * *", Nightly{}, .{ .tz = "Europe/Berlin" });
```

The schedule needs a handler for its args type, like any job.

## Syntax

Five fields (minute hour day-of-month month day-of-week), or six with leading seconds. `*`, lists, ranges, steps (`*/15`, `10-40/5`), month and day names, `?` as `*`, `L` in day-of-month, `5L` and `MON#2` in day-of-week, `7` as Sunday. Nicknames `@yearly @annually @monthly @weekly @daily @midnight @hourly`; `@every 90s` (multiples of the interval from the Unix epoch, at least 1 s). When both day fields are restricted, either matching fires (Vixie cron).

## Without jobs

`anole.cron.Schedule.parse(text, &diagnostic)` and `schedule.next(after, &zone)` work on their own, for "next run" displays (src/cron/vectors_test.zig):

```zig
const s = try anole.cron.Schedule.parse("*/15 * * * *", null);
const next = s.next(after, &anole.cron.Zone.utc); // after: an anole.db.Time; null: no next run
```

Traps:
- Never write a sleep loop or a timer task for periodic work: it runs on every instance. `jobs.cron` runs once per tick across all of them.
- `W` is refused (`error.InvalidSchedule`).
- `tz` is an IANA name, `"UTC"` or an offset (`"+05:30"`); null is UTC. Names come from the system tzdata (`ZONEINFO`, /usr/share/zoneinfo); none is embedded. Distroless images and Windows need tzdata installed, or use UTC or an offset ([deployment](../deployment/index.md)).
- DST: a nonexistent wall time fires once at the end of the gap; a repeated one fires once, unless the hour field is `*` or a step.
- Missed ticks: `missed = .once` (default) enqueues the latest; `.skip` none; `.all` each within `catch_up` (24 h), at most 1000. A new or changed schedule does not backfill.
- The leader evaluates schedules, so on a `.memory` store each process is its own cluster: use a shared store when several instances run.
