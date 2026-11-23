# NATS

Up: [index](index.md). Related: [kafka](kafka.md), [jobs](jobs.md) (durable work instead of at-most-once core NATS).

`anole.nats` is a pure Zig NATS client on `std.Io`: publish, request/reply, handlers on subjects with queue groups, TLS, token, user/password, NKey and `.creds` logins, and JetStream (publish with ack, streams, durable pull consumers). Needs `-Dnats` ([config-cli](../config-cli.md#feature-flags-and-profiles)). Full docs: docs/messaging.md#nats.

Use:
- `anole.App.nats` (src/server.zig): `app.nats(.{})` returns `*anole.nats.Client`, owned and freed by the server
- `anole.nats.Client`: `publish`, `publishMsg`, `request`, `requestMsg`, `handle`, `subscribe`, `with`, `js`, `writable`, `waitWritable`, `flush` (src/nats/root.zig)
- `anole.nats.Options`, `anole.nats.HandleOptions`, `anole.nats.CallOptions`, `anole.nats.OutMsg`, `anole.nats.Reply`, `anole.nats.Msg`, `anole.nats.Subscription` (src/nats/root.zig)
- `anole.nats.JetStream`: `publish`, `consume`, `ensureStream`, `ensureConsumer`; `anole.nats.jetstream.JsMsg`: `ack`, `nak`, `term`, `inProgress` (src/nats/jetstream.zig)

## Setup and handlers

```zig
const nc = try app.nats(.{});           // NATS_URL, else nats://127.0.0.1:4222
try nc.handle(&app, "orders.created", .{ .queue = "billing" }, onOrder);

fn onOrder(state: *State, msg: *anole.nats.Msg) !void {
    const order = try msg.json(Order);
    _ = try state.db.exec(msg, "INSERT INTO ...", .{order.id});
    if (msg.reply_to != null) try msg.respond("ok");
}
```

A handler is `fn (*Msg) !void` or `fn (*App, *Msg) !void`. `Msg` has `io`, `arena` and `locals` like a request, so pass `msg` where a connector wants the request. `msg.bind(T)` is `msg.json(T)` plus `T`'s `field_rules`. `HandleOptions`: `queue` (each message to one member of the group, across processes), `concurrency` (64, over all executors), `pending`, `overflow` (`drop_newest`, `drop_oldest`, `close_subscription`), `timeout` (30 s per message).

Options (`anole.nats.Options`): `url` (`nats://`, `tls://`, comma-separated list; `user:password@` or `token@`), `auth` (`.token`, `.user_password`, `.nkey`, `.creds`), `tls`, `connections` (`.one` default, `.per_executor`), `timeout`, `connect_at_start`, `reconnect`, `limits`, `retry`, `jetstream`, `readiness`.

## Publish never waits

```zig
try nc.publish(req, "orders.created", body);
```

Returns once the frame is queued. A full outbound queue (`limits.outbound_bytes`, 8 MiB; `reconnect.buffer_bytes` while reconnecting) is `error.ServiceUnavailable`, `lastError` code `outbound_full`. Wait explicitly with `nc.writable(req)` / `nc.waitWritable(req, timeout)`. See [writes return once buffered](../runtime.md#writes-return-once-buffered).

## Request/reply

```zig
const reply = try nc.request(req, "users.get", id);
const user = try reply.json(User, req.arena);
```

No subscriber: `error.ServiceUnavailable` (code `no_responders`). Past the timeout (30 s, or `nc.with(.{ .timeout = ... })`): `error.GatewayTimeout`. `nc.with(.{ .retry = true })` retries only no-responders (the request was never delivered), with `Options.retry`. A handler that fails while answering replies with `Nats-Service-Error` headers; `reply.serviceError()` reads them.

A subscription read by hand: `nc.subscribe(c, subject, .{})`, then `sub.next(c, timeout)` and `sub.deinit()`.

## JetStream

```zig
const nc = try app.nats(.{ .jetstream = .{
    .streams = &.{.{ .name = "ORDERS", .subjects = &.{"orders.>"} }},
    .consumers = &.{.{ .stream = "ORDERS", .durable = "billing" }},
} });
try nc.js().consume(&app, "ORDERS", "billing", .{}, onOrder);   // fn (*JsMsg) !void

const ack = try nc.js().publish(req, "orders.created", body, .{ .msg_id = "order-42" });
```

Streams and consumers in `Options.jetstream` are created, or updated when their configuration differs, before the listeners open. `publish` waits for the stream's ack (`PubAck.duplicate` when `msg_id` was seen in the duplicate window). `consume` pulls with credit (`ConsumeOptions.max_inflight`, 64), so nothing is dropped. The handler's return acks; an error NAKs with a delay from `nak_backoff` by delivery count; `term()` stops redelivery; `inProgress()` extends `ack_wait`.

Traps:
- Register handlers (`handle`, `js().consume`) before `run` (docs/messaging.md#setup).
- Core NATS is at-most-once: a failed handler is logged, never redelivered. Use JetStream or [jobs](jobs.md) when a message must not be lost.
- Default `connect_at_start = false`: the app starts without the server and `/readyz` reports not ready until connected. Set it `true` to fail the start instead.
- `connections = .one` (default) keeps publish order across the whole app; `.per_executor` can reorder publishes made on different cores (docs/messaging.md#ordering-and-connections).
- Key-value and the object store are not implemented (docs/messaging.md#jetstream).
- docs/messaging.md#testing names `anole.nats.core.testing.FakeServer`, but `anole.nats.core` does not export `testing` on this branch: an app cannot reach it. Test against a real `nats-server -js` ([testing](../testing.md)).
