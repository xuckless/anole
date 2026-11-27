# Retries and circuit breakers

Up: [index](index.md). Related: [http client](http-client.md), [s3](s3.md), [smtp](smtp.md), [jobs](../messaging/jobs.md) (job backoff is a `resilience.Backoff`), [databases](../databases/index.md).

`anole.resilience` is the one set of policies every client shares: backoff with jitter, retries bounded by the call's deadline, gRPC A6 retry throttling, and circuit breakers. It is in every build. Configure the clients' options; never write a `while (attempt < n)` sleep loop around a call. Full docs: docs/resilience.md.

Use:
- `anole.resilience.Backoff` (`base`, `max`, `multiplier`, `jitter`: `.full`, `.equal`, `.none`; `delay`) (src/resilience/core.zig)
- `anole.resilience.Retry` (`attempts`, `backoff`, `attempt_timeout`, `max_retry_after`, `throttle`) (src/resilience/core.zig)
- `anole.resilience.Choice` (`.inherit`, `.off`, `.on`), what `anole.FetchOptions.retry` takes (src/resilience/core.zig)
- `anole.resilience.Breaker`, `anole.resilience.Breaker.Options` (`consecutive_failures`, `failure_ratio`, `min_calls`, `window`, `open_for`, `max_open_for`, `half_open_calls`), `anole.resilience.Breakers` (src/resilience/core.zig)
- `anole.resilience.run`, `anole.resilience.Policy`, `anole.resilience.Verdict`, `anole.resilience.Throttle` (src/resilience/core.zig)

## What each client does by default

| Client | Retries | Breaker | Where to set |
| --- | --- | --- | --- |
| HTTP client (`anole.client`) | off | off | `ServerOptions.client.retry`, `.breaker`; per call `FetchOptions.retry` |
| S3 | **on** (3, 100 ms to 2 s) | **on** | `anole.s3.Options.retry`, `.breaker`; per call `with(.{ .retry = false })` |
| SMTP | opt-in per call | **on** | `anole.smtp.Options.retry`; `with(.{ .retry = true })` |
| NATS requests | only `with(.{ .retry = true })`, on no-responders | no | `anole.nats.Options.retry` |
| Kafka consumer | per record, 10 attempts | no | `anole.kafka.ConsumeOptions.retry` |
| Jobs | the kind's `attempts` and `backoff` | no | `anole.jobs.Kind` |
| Webhook deliveries | 10 attempts, about 3 days | one per origin | `anole.webhooks.Options` |
| PostgreSQL, Redis, MongoDB | calls marked `retry` | **on** | [databases](../databases/index.md) |

Sources: docs/resilience.md#what-is-on-by-default, src/s3/root.zig, src/smtp/root.zig, src/kafka/consumer.zig, src/webhooks/root.zig.

## HTTP client

```zig
var app = try anole.Server(State).init(gpa, .{
    .client = .{
        .retry = .{ .attempts = 3 },          // GET, HEAD, OPTIONS, TRACE, QUERY
        .breaker = .{},                       // one per scheme://host:port
    },
}, &state);
```

Only requests that may be repeated are retried (by method, an `Idempotency-Key` header, or `FetchOptions.idempotent = true`). `retry_statuses` (408, 429, 502, 503, 504) are retried; `Retry-After` on 429/503 is obeyed up to `max_retry_after` and the fetch's remaining time. An open breaker is `error.CircuitOpen` (503). Per call: `.retry = .off` or `.retry = .{ .on = .{ .attempts = 5 } }`.

## Your own code

```zig
const r = try anole.resilience.run(io, .{
    .retry = .{ .attempts = 3 },
    .breaker = &breaker,
}, &context, attempt, Judge);
```

`attempt(context, n)` does the work (n = 1, 2, ...) and returns a value or an error union. `Judge.verdict(&result)` returns `.success`, `.transient` (retry; the breaker counts a failure), `.retryable` (retry; the breaker counts nothing, e.g. a 429), `.failure` or `.neutral` (return it; a 404 or unique violation). Optional `pub fn retryAfter`, `discard`, `reason`. `run` adds `error.CircuitOpen` and `error.Canceled`. A breaker of your own: `anole.resilience.Breaker.init(.{}, .http, "label")`. `Policy` also takes `throttle`, `deadline`, `metrics`, `kind`, `target`.

Behaviour: backoff is a random wait in `0 .. min(base * multiplier^(n-1), max)` (100 ms, doubling, at most 2 s); throttling costs a token per failure and earns 0.1 per success, retrying only while more than half are left; the breaker opens after 5 failures in a row or half of 20+ calls in 10 s, stays open 5 s, probes once, doubles up to 60 s.

Traps:
- `attempts` counts every attempt, the first included: 1 is no retry, at most 10 (`error.InvalidOptions` at init) (src/resilience/core.zig `Retry.validate`).
- The call's own timeout bounds all attempts together; a retry whose wait ends past the deadline is not made. Use `attempt_timeout` for a per-attempt bound, applied by your attempt function (`run` cannot cancel it).
- `Judge` is used from another file, so `verdict` and the optional hooks must be `pub` (src/resilience/core.zig `run` doc comment: `@hasDecl` sees only `pub` ones).
- 4xx and 429, gRPC application codes and pool-acquire timeouts are not breaker failures; do not judge them `.transient` in your own `Judge` unless the target is down.
- Retries multiply load in an outage; that is why HTTP retries are opt-in. Turn them on only for idempotent calls.
- `run` waits with `io.sleep`: a cancel ends it with `error.Canceled`; pass it on ([re-raise error.Canceled](../runtime.md#re-raise-errorcanceled)).
- Metrics: `anole_breaker_state`, `anole_breaker_opened_total`, `anole_breaker_rejected_total`, `anole_retries_total`, `anole_retries_throttled_total` ([observability](../observability.md)).
