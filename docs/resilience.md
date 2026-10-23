# Retries and circuit breakers

`anole.resilience` is one set of policies that the HTTP and gRPC clients, the
database connectors and the brokers share: retries with backoff and jitter,
retry throttling, and circuit breakers. It is in every build.

## What they do

- **Backoff** (`Backoff`): the wait before retry `n` is a random time in
  `0 .. min(base * multiplier^(n-1), max)` (gRPC's A6 formula, "full jitter").
  The defaults are 100 ms, doubling, at most 2 s. `jitter = .none` and
  `.equal` are there for tests and for schedules stored elsewhere.
- **Retry** (`Retry`): `attempts` counts every attempt, the first included
  (2 to 10 to retry). `attempt_timeout` bounds one attempt inside the call's
  own timeout, which always bounds *all* attempts together: a retry whose
  wait would end past the call's deadline is not made.
- **Throttling** (`Retry.throttle`, on by default): gRPC A6's token bucket per
  target. Each failed attempt costs a token, each success earns 0.1 back,
  and a retry is made only while more than half the tokens are left, so a
  failing target sees about 10% extra load, never a storm.
- **Breaker** (`Breaker`): opens after 5 failures in a row, or when half of
  at least 20 calls in the last 10 s failed. It stays open 5 s, then lets one
  probe through (half-open); a success closes it, a failure opens it again
  for twice as long, up to 60 s. An open breaker fails a call at once, without
  touching the network.

Transitions are logged (opening at warn, half-open and closed at info) and
counted: `anole_breaker_state{client,target}` (0 closed, 1 half-open, 2 open),
`anole_breaker_opened_total`, `anole_breaker_rejected_total`,
`anole_retries_total{client,target,reason}` and
`anole_retries_throttled_total`. `target` is capped at 256 values per client.

## What is on by default

| | Retries | Breaker |
| --- | --- | --- |
| HTTP client | off | off |
| gRPC channel | off | off |
| PostgreSQL, Redis, MongoDB | only calls marked `retry` | **on** |
| SQLite | no | no (no network) |
| NATS requests | only with `retry` (on no-responders) | no |

Retries are opt-in: default-on retries multiply load during an outage. The
retries that are always safe stay on: an HTTP request lost on a reused
connection, a gRPC or HTTP/2 or HTTP/3 request the server provably did not
process (`REFUSED_STREAM`, `H3_REQUEST_REJECTED`, past a GOAWAY's last
stream), and a database statement that failed on a reused idle connection
before it was sent.

The database connectors' breaker is on because a database outage otherwise
holds every request for `acquire_timeout` or `connect_timeout` before its
503. Turn it off with `breaker = null` (`"breaker": null` in the C ABI).

## What counts as a failure

A breaker protects against a down or drowning target, not against bad
requests or the client's own pool size.

- **Failures**: connect refused or reset, TLS and DNS errors, attempt
  timeouts, HTTP 408, 500, 502, 503 and 504, gRPC `UNAVAILABLE`, and a
  database that cannot be reached.
- **Not failures**: HTTP 4xx and 429, gRPC application codes, any answer from
  a live database (a unique violation, a syntax error, a statement timeout),
  and a connector's pool-acquire timeout (`lastError` code `pool_timeout`:
  local overload, not a down server).

## HTTP client

```zig
var app = try anole.Server(State).init(gpa, .{
    .client = .{
        .retry = .{ .attempts = 3 },          // GET, HEAD, OPTIONS, TRACE, QUERY
        .breaker = .{},                       // one per scheme://host:port
    },
}, &state);
```

A fetch is retried only if its request may be repeated: by method, or an
`Idempotency-Key` header, or `FetchOptions.idempotent = true`. `retry_statuses`
(408, 429, 502, 503, 504) are retried; `Retry-After` (seconds) on 429 and 503
is obeyed up to `max_retry_after` and the fetch's remaining time. The fetch's
`timeout` bounds all attempts together. An open breaker is
`error.CircuitOpen`, which `errorStatus` maps to 503.

Per call: `FetchOptions.retry = .off` or `.{ .on = .{ .attempts = 5 } }`.

## gRPC client

`Channel.retry`, `Channel.retry_codes` (default `UNAVAILABLE`) and
`Channel.breaker` apply to unary calls. Each retry sends
`grpc-previous-rpc-attempts` and the remaining `grpc-timeout`; a trailer
`grpc-retry-pushback-ms` is obeyed (a negative or unreadable value stops the
retries). An open breaker answers `UNAVAILABLE "circuit open"`.

`Channel.connect(gpa, io, connect_options, .{ ... })` makes a channel that owns
its HTTP/2 connection and redials it when it closes (a GOAWAY, a failure): the
next call opens a new one.

## HTTP/2 and HTTP/3 connections

`Stream.unprocessed()` is true when the server provably did not run the
request: it refused the stream, or its GOAWAY's last stream ID is below this
one. Such a request can be sent again on another connection whatever its
method. The raw connections never retry on their own; wrap them with
`resilience.run` and a judge that calls `unprocessed()`.

## Databases

```zig
state.db = try app.postgres(.{
    .breaker = .{ .consecutive_failures = 3 },   // null: never fails fast
    .retry = .{ .attempts = 3 },                 // what `retry = true` uses
});
...
const row = try state.db.with(.{ .retry = true }).one(User, req, "SELECT ...", .{id});
```

`QueryOptions.retry` is for statements that are safe to repeat. MongoDB has
the spec's retryable reads and writes and ignores it; SQLite ignores it.
Transactions are never retried by it (`transaction(..., .retries)` reruns
one). An open breaker is `error.ServiceUnavailable` with `lastError` code
`circuit_open`.

In the C ABI each `databases[]` entry takes `"breaker"` and `"retry"`, and
`ANOLE_DB_F_RETRY` marks a query that may be retried (refused on
`anole_db_tx_*`).

## Your own code

```zig
const r = try anole.resilience.run(io, .{
    .retry = .{ .attempts = 3 },
    .breaker = &breaker,
}, &context, attempt, Judge);
```

`attempt(context, n)` does the work; `Judge.verdict(&result)` says
`success`, `transient` (retry it), `retryable` (retry it, but the target is
not failing), `failure` or `neutral` (return it, count nothing); optional
`retryAfter`, `discard` and `reason`. `Backoff.delay` is pure, for scheduling
stored retries.
