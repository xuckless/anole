# Messaging

Anole speaks to message brokers with clients written on `std.Io`, so a wait
suspends the calling coroutine and never its thread. The same shape as the
database connectors: the client is a handle in your App state, calls take the
request (or a message) first, errors are `anole.db.Error` (a handler's `try`
gives the right status), and the connection is checked by `/readyz`.

| Broker | Flag | Profiles | Handle |
| --- | --- | --- | --- |
| [NATS](#nats) | `-Dnats` | `full` | `anole.nats.Client`, from `app.nats(.{})` |

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
