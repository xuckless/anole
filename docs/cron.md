# Cron schedules

```zig
try state.jobs.cron("nightly", "0 3 * * *", Nightly{}, .{ .tz = "Europe/Berlin" });
```

One job per tick is enqueued across all instances: the tick is recorded in the
store together with the job, and a job carries a unique key made of the
schedule's name and the tick, so two instances racing produce one job. The
leader evaluates schedules; correctness does not depend on it.

## Syntax

Five fields (minute hour day-of-month month day-of-week), or six with a
leading seconds field. `*`, lists, ranges, steps (`*/15`, `10-40/5`), month
and day names, `?` as `*`, `L` (last day of the month) in day-of-month, `5L`
(last Friday) and `MON#2` (second Monday) in day-of-week, `7` as Sunday.
Nicknames: `@yearly @annually @monthly @weekly @daily @midnight @hourly`.
`@every 90s` runs at multiples of the interval from the Unix epoch (at least
1 s). `W` is refused. When day-of-month and day-of-week are both restricted,
either matching is enough (Vixie cron).

## Time zones

`tz` is an IANA name, `"UTC"` or an offset (`"+05:30"`). Names are read from the
system's tzdata (`ZONEINFO`, then /usr/share/zoneinfo and the like); there is
none embedded. In a distroless image or on Windows install tzdata, or use UTC
or an offset.

Daylight saving time: a wall time that does not exist (spring forward) fires
once, at the end of the gap; a wall time that happens twice (fall back) fires
once, at its first occurrence, unless the hour field is `*` or a step
(`*/30`), in which case both fire.

## Missed ticks

If nobody led while a tick was due: `missed = .once` (default) enqueues the
latest one; `.skip` enqueues none; `.all` enqueues each inside `catch_up`
(24 h), at most 1000. A new schedule, or one whose text changed, does not
backfill.

## Without jobs

`anole.cron.Schedule.parse(text, &diagnostic)` and `next(after, &zone)` work
on their own, for "next run" displays.
