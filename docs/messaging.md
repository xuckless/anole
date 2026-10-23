# Messaging

Anole speaks to message brokers with clients written on `std.Io`, so a wait
suspends the calling coroutine and never its thread. The same shape as the
database connectors: the client is a handle in your App state, calls take the
request (or a message) first, errors are `anole.db.Error` (a handler's `try`
gives the right status), and the connection is checked by `/readyz`.

| Broker | Flag | Profiles | Handle |
| --- | --- | --- | --- |
| [NATS](#nats) | `-Dnats` | `full` | `anole.nats.Client`, from `app.nats(.{})` |
| [Kafka](#kafka) | `-Dkafka` (needs `-Dcompression`) | `full` | `anole.kafka.Client`, from `app.kafka(.{})` |

## NATS

`anole.nats` covers publish, request and reply, handlers on subjects with
queue groups, TLS, token, user and password, NKey and `.creds` logins, and
JetStream (publish with ack, streams, durable pull consumers). The protocol
engine is adapted from [zefir](https://github.com/vkiryakov/zefir) (MIT, see
THIRD_PARTY_NOTICES); the rest is Anole's.

### Setup

```zig
const nc = try app.nats(.{});           // NATS_URL, else nats://127.0.0.1:4222
try nc.handle(&app, "orders.created", .{ .queue = "billing" }, onOrder);

fn onOrder(state: *State, msg: *anole.nats.Msg) !void {
    const order = try msg.json(Order);
    _ = try state.db.exec(msg, "INSERT INTO ...", .{order.id});
    if (msg.reply_to != null) try msg.respond("ok");
}
```

`app.nats` connects when serving starts. With the default
`connect_at_start = false` the client keeps trying in the background and
`/readyz` says not ready until it is connected; with `true` the start fails
if the server cannot be reached. Handlers must be registered before `run`.

Options (`anole.nats.Options`): `url` (`nats://`, `tls://`, a comma-separated
list; `user:password@` or `token@` log in), `auth` (`.token`,
`.user_password`, `.nkey`, `.creds`; the last two as text or a file), `tls`
(`ca`, `client_certificate`, `insecure_skip_verify`, `first`, `required`),
`connections`, `timeout`, `reconnect`, `limits`, `retry`, `jetstream`. The C
ABI's `"brokers"` takes the same names, with `_ms` on durations (see
[c-abi.md](c-abi.md#brokers)).

### Publishing never waits

```zig
try nc.publish(req, "orders.created", body);
```

returns once the frame is queued. When the outbound queue is full
(`limits.outbound_bytes`, 8 MiB; while reconnecting, `reconnect.buffer_bytes`)
it fails with `error.ServiceUnavailable` and `lastError` code `outbound_full`.
A send that blocks on the network would stall whatever lock the caller holds,
so waiting is explicit: `nc.writable(req)` and `nc.waitWritable(req, timeout)`.

### Ordering and connections

NATS orders messages per connection only. With one connection per executor,
two publishes made on different cores could arrive reversed, so the default
(`connections = .one`) keeps one connection: publishes keep their order across
the whole app. One connection carries millions of messages a second.
`connections = .per_executor` opts into one per executor; then a queue-group
handler subscribes on each and a handler without a queue group on one of them.
Handlers run on every executor either way.

### Requests

```zig
const reply = try nc.request(req, "users.get", id);
const user = try reply.json(User, req.arena);
```

No one listening is `error.ServiceUnavailable` with code `no_responders`;
past the timeout (30 s, or `with(.{ .timeout = ... })`) `error.GatewayTimeout`.
`nc.with(.{ .retry = true })` retries no-responders (the request was never
delivered) with `Options.retry`. A handler that fails while answering a
request replies with the NATS micro error headers `Nats-Service-Error` and
`Nats-Service-Error-Code` (`errorStatus(err)`, 500 by default); `Reply.serviceError()`
reads them.

### Handlers

`nc.handle(&app, subject, opts, fn)` runs `fn (*Msg) !void` or
`fn (*App, *Msg) !void` for each message. `Msg` has `io`, `arena` and
`locals` like a request, so `app.db.one(T, msg, ...)` works. `opts`:
`queue` (each message goes to one member of the group, across processes),
`concurrency` (64, over all executors), `pending` and `overflow` (the
subscription's own queue: `drop_newest`, `drop_oldest`, `close_subscription`),
`timeout` per message. A message whose handler fails is logged (warn for 5xx);
core NATS is at-most-once, so it is not redelivered.

A subscription you read by hand: `nc.subscribe(c, subject, .{})`, then
`sub.next(c, timeout)` and `sub.deinit()`.

### JetStream

```zig
const nc = try app.nats(.{ .jetstream = .{
    .streams = &.{.{ .name = "ORDERS", .subjects = &.{"orders.>"} }},
    .consumers = &.{.{ .stream = "ORDERS", .durable = "billing" }},
} });
try nc.js().consume(&app, "ORDERS", "billing", .{}, onOrder);   // fn (*JsMsg) !void

const ack = try nc.js().publish(req, "orders.created", body, .{ .msg_id = "order-42" });
```

Streams and consumers are created, or updated when the configuration differs,
before the listeners open. A publish waits for the stream's ack
(`Nats-Msg-Id` deduplicates within the duplicate window; `PubAck.duplicate`).
A consume pulls with credit: it fetches only while fewer than `max_inflight`
messages are unacked, so nothing is dropped. The handler's return acks the
message; an error NAKs it with a delay from `nak_backoff` by delivery count;
`term()` ends redelivery and `inProgress()` extends `ack_wait`. Acks are
publishes and never wait. Key-value and the object store are later.

### Tracing and metrics

A publish from a traced request carries `traceparent`; calls make
`messaging` spans (`publish`, `request`, `process`) with
`messaging.system = "nats"`. Breaker and retry metrics are in
[resilience.md](resilience.md).

### Errors

| Condition | class | `lastError` code | Error |
| --- | --- | --- | --- |
| no responders | unavailable | `no_responders` | `ServiceUnavailable` (503) |
| not connected, queue full | unavailable | `disconnected`, `outbound_full` | `ServiceUnavailable` |
| past the timeout | timeout | `timeout` | `GatewayTimeout` (504) |
| permission denied, bad subject or header, payload too large, login refused | other | `permission_denied`, `invalid_subject`, `payload_too_large`, `authentication_failed` | `Database` (500: the backing service refused) |
| a JetStream API error | by its code | its `err_code` | by class |

### Testing

`anole.nats.core.testing.FakeServer` plays the server's side of the protocol
for unit tests. Against a real server: `tests/nats/run.sh`, or
`zig build test -Dnats-test-url=nats://127.0.0.1:4222` (a nats-server started
with `-js`).

## Kafka

`anole.kafka` is a client written for Anole on `std.Io`, from Kafka's protocol
specification: no librdkafka, which starts threads of its own and links
OpenSSL (it would clash with the bundled BoringSSL). Version one covers
produce (acks 0, 1 or all, idempotent by default, batching with `linger`,
gzip, zstd and lz4 compression), consumer groups (the classic protocol, eager
rebalance, range and roundrobin assignors, static membership, commit of
processed offsets, retry and a dead-letter topic), TLS (BoringSSL, mutual TLS)
and SASL PLAIN, SCRAM-SHA-256 and SCRAM-SHA-512. It runs against Apache Kafka
2.8 and later (tested on 4.1) and Redpanda.

### Setup

```zig
const kc = try app.kafka(.{});          // KAFKA_BOOTSTRAP_SERVERS, else KAFKA_URL, else localhost:9092
try kc.consume(&app, .{ .group = "workers", .topics = &.{"events"} }, onEvent);

fn onEvent(state: *State, msg: *anole.kafka.Msg) !void {
    const event = try msg.json(Event);
    _ = try state.db.exec(msg, "INSERT INTO events ...", .{event.id});
}
```

`msg.bind(Event)` is `msg.json` with the validator: the value mapped field by
field and checked by `Event`'s `field_rules`; a value that does not fit logs
one warning (the count and the first problem) and returns
`error.ValidationFailed`, as NATS's `Msg.bind` does.

`app.kafka` connects when serving starts (`connect_at_start = true` fails the
start if no broker answers; `/readyz` reports the cluster either way).
Options (`anole.kafka.Options`): `brokers`, `client_id`, `tls`, `sasl`,
`timeout`, `connect_timeout`, `request_timeout`, `metadata_max_age`,
`producer` (`acks`, `idempotent`, `linger`, `batch_bytes`, `buffer_bytes`,
`compression`, `delivery_timeout`, `max_request_bytes`) and `errors`. The C
ABI's `"brokers"` takes the same names with `_ms` on durations (see
[c-abi.md](c-abi.md#kafka)). `-Dkafka` needs `-Dcompression`, and builds lz4.

### send and produce

```zig
try kc.send(req, .{ .topic = "events", .key = "user-7", .value = req.body() });
const d = try kc.produce(req, .{ .topic = "events", .value = body }); // waits for the ack
```

`send` queues the record and returns; a full buffer (`producer.buffer_bytes`,
32 MiB) is `error.ServiceUnavailable` with `lastError` code `buffer_full`, and
`kc.waitWritable(req, timeout)` waits for room. A delivery that fails later is
logged and counted. `produce` waits for the broker's acknowledgement, bounded
by `timeout` (30 s); on a timeout it fails with `GatewayTimeout` (code
`delivery_pending`: the record may still arrive). `kc.flush(req)` sends what
is buffered at once.

### Partitioning and ordering

The partitioner is Java's: `murmur2(key) % partitions`, so a key lands where
Java producers put it (librdkafka's default differs). Records without a key
stick to one partition per batch. There is one producer per client, not one
per executor, and its accumulators are shared: the records of one key keep
their order across requests served on different cores. With `idempotent`
(the default, needs `acks = .all`) a retry never duplicates a record.

### Consumer groups

`kc.consume(&app, opts, handler)` joins `opts.group` once serving starts.
Each partition is handled by one task at a time, in order, on executor
`partition % executors`; `members` (default 1) adds more group members in the
process for CPU-bound handlers. Offsets of finished records are committed
every `commit_interval` (5 s) and when the group is left; a crash replays at
most the records since the last commit, so handlers should be idempotent.
`start` picks where a partition without a committed offset begins (`.latest`
or `.earliest`); `instance_id` makes the membership static, so a restart
within `session_timeout` keeps its partitions.

A handler that fails is retried in place (`opts.retry`: 10 attempts, 100 ms to
10 s) and then, if `dead_letter` names a topic, produced there with the
headers `anole-dlt-topic`, `-partition`, `-offset` and `-error`; without one it
is logged and skipped, so a poison record never stops a partition. A
rebalance lets the record in progress finish (up to `rebalance_timeout`),
commits, and rejoins. Metrics have the client, group and topic in their
labels (below).

### Tracing and metrics

A produce from a traced request carries `traceparent`; calls make
`messaging` spans with `messaging.system = "kafka"`, the topic as
`messaging.destination.name`, and for consumed records the offset and group.
Record keys are not put in spans (they can be personal data). Metrics:
`anole_kafka_produced_total`, `anole_kafka_produce_errors_total`,
`anole_kafka_buffer_bytes`, `anole_kafka_consumed_total`,
`anole_kafka_consumer_lag`, `anole_kafka_rebalances_total` and
`anole_kafka_dead_lettered_total`.

### Errors

| Condition | class | `lastError` code | Error |
| --- | --- | --- | --- |
| no broker reachable, buffer full, shutting down | unavailable | `no_broker`, `buffer_full`, `closing` | `ServiceUnavailable` (503) |
| no acknowledgement within the timeout | timeout | `delivery_pending` | `GatewayTimeout` (504) |
| record too large, unknown topic, bad partition, login refused | other | `MESSAGE_TOO_LARGE`, `UNKNOWN_TOPIC_OR_PARTITION`, `invalid_partition`, `SASL_AUTHENTICATION_FAILED` | `Database` (500: the backing service refused) |

### What version one leaves out

Transactions and exactly-once, the KIP-848 consumer protocol, cooperative-sticky
assignment, the admin API, OAUTHBEARER and GSSAPI, fetch from followers, and
producing with snappy (a consumer reads it). A topic is not created on first
use: create it first (or let the broker's auto-create do it).

### Testing

`anole.kafka.testing.FakeBroker` is an in-process broker for tests (point
`Options.brokers` at `broker.address()`): one node, no replication, topics made
on first use. Against real brokers: `zig build test -Dkafka-test-url=host:9092`
with Apache Kafka 4.x (KRaft) or Redpanda; CI runs both, each with a plain
listener and a SASL SCRAM + TLS one.
