# Kafka

Up: [index](index.md). Related: [nats](nats.md), [jobs](jobs.md), [resilience](../storage-email-clients/resilience.md) (the consumer's `retry`).

`anole.kafka` is a pure Zig Kafka client on `std.Io` (no librdkafka): produce with acks 0/1/all, idempotent by default, batching, gzip/zstd/lz4; consumer groups (classic protocol, range and roundrobin assignors, static membership, commits, retry and a dead-letter topic); TLS and SASL PLAIN / SCRAM-SHA-256 / SCRAM-SHA-512. Kafka 2.8+ and Redpanda. Needs `-Dkafka`, which needs `-Dcompression` ([config-cli](../config-cli.md#feature-flags-and-profiles); build.zig refuses the combination otherwise). Full docs: docs/messaging.md#kafka.

Use:
- `anole.App.kafka` (src/server.zig): `app.kafka(.{})` returns `*anole.kafka.Client`, owned and freed by the server
- `anole.kafka.Client`: `send`, `produce`, `flush`, `writable`, `waitWritable`, `with`, `consume` (src/kafka/root.zig)
- `anole.kafka.Options`, `anole.kafka.Record`, `anole.kafka.Delivery`, `anole.kafka.Header` (src/kafka/root.zig)
- `anole.kafka.ConsumeOptions`, `anole.kafka.Msg` (`json`, `bind`, `header`, `log`) (src/kafka/consumer.zig)
- `anole.kafka.testing.FakeBroker` (src/kafka/testing.zig)

## Setup and consume

```zig
const kc = try app.kafka(.{});          // KAFKA_BOOTSTRAP_SERVERS, else KAFKA_URL, else localhost:9092
try kc.consume(&app, .{ .group = "workers", .topics = &.{"events"} }, onEvent);

fn onEvent(state: *State, msg: *anole.kafka.Msg) !void {
    const event = try msg.json(Event);
    _ = try state.db.exec(msg, "INSERT INTO events ...", .{event.id});
}
```

`msg.bind(Event)` validates with `Event`'s `field_rules`; a misfit returns `error.ValidationFailed` with one warning.

Options (`anole.kafka.Options`): `brokers`, `client_id`, `tls`, `sasl`, `timeout`, `connect_timeout`, `request_timeout`, `metadata_max_age`, `connect_at_start`, `producer` (`acks`, `idempotent`, `linger`, `batch_bytes`, `buffer_bytes`, `compression`, `delivery_timeout`, `metadata_wait`, `max_request_bytes`), `errors`, `readiness`.

`ConsumeOptions`: `group`, `topics`, `start` (`.latest` default, `.earliest`), `instance_id` (static membership), `members` (1; more for CPU-bound handlers), `assignor`, `session_timeout`, `rebalance_timeout`, `commit_interval` (5 s), `retry` (10 attempts, 100 ms to 10 s), `dead_letter`, `timeout`, `batch_handler`, `max_batch`, `on_assign`, `on_revoke`.

## send and produce

```zig
try kc.send(req, .{ .topic = "events", .key = "user-7", .value = try req.body() });
const d = try kc.produce(req, .{ .topic = "events", .value = body }); // waits for the ack
```

`send` queues and returns; a full buffer (`producer.buffer_bytes`, 32 MiB) is `error.ServiceUnavailable`, code `buffer_full`; `kc.waitWritable(req, timeout)` waits for room. A later delivery failure is only logged and counted. `produce` waits for the broker's ack (bounded by `timeout`, 30 s) and returns `Delivery` (`partition`, `offset`); a timeout is `error.GatewayTimeout`, code `delivery_pending` (the record may still arrive). `kc.flush(req)` sends what is buffered now.

Partitioning is Java's `murmur2(key) % partitions`; one producer per client, so one key keeps its order across executors.

Traps:
- `req.body()` returns `!?[]const u8`: write `.value = try req.body()`.
- Use `send` for fire-and-forget, `produce` only when the caller must know the record landed. Neither blocks a thread ([writes return once buffered](../runtime.md#writes-return-once-buffered)).
- At-least-once: a crash replays records since the last commit (every `commit_interval`). Make handlers idempotent (docs/messaging.md#consumer-groups).
- A failing handler is retried in place, then produced to `dead_letter` if set (headers `anole-dlt-topic`, `-partition`, `-offset`, `-error`), else logged and skipped. Set `dead_letter` if a poison record must not vanish.
- Each partition runs one record at a time, in order; one slow handler holds its partition. Never block it ([never block an executor](../runtime.md#never-block-an-executor)).
- Topics are not created on first use: create them first or rely on the broker's auto-create. Unknown topics wait up to `producer.metadata_wait` (5 s), then fail `UNKNOWN_TOPIC_OR_PARTITION`.
- Not in version one: transactions/exactly-once, KIP-848, cooperative-sticky, the admin API, OAUTHBEARER, GSSAPI, producing snappy (docs/messaging.md#what-version-one-leaves-out).
- Tests: `anole.kafka.testing.FakeBroker.start(gpa, io, .{})`, point `Options.brokers` at `broker.address()` ([testing](../testing.md)).
