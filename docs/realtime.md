# Server-sent events and watching changes

`anole.sse` publishes once and every subscriber gets the event, with replay
after a reconnect, heartbeats and a policy for slow clients. `anole.watch`
turns database changes into those events with no handler in between.

```zig
const db = try app.postgres(.{});                    // DATABASE_URL
const live = try app.sseTopics(.{});                 // replay, heartbeats: on
app.sse("/orders/live", live, .{ .topics = &.{"orders"} });
_ = try app.watch(.{ .postgres = .{ .client = db, .channels = &.{"orders"} } }, .{
    .to = &.{.{ .sse = .{ .topics = live, .topic = "orders" } }},
});
try app.listen(":3000");
```

```sql
CREATE FUNCTION orders_notify() RETURNS trigger AS $$
BEGIN PERFORM pg_notify('orders', row_to_json(NEW)::text); RETURN NEW; END $$ LANGUAGE plpgsql;
CREATE TRIGGER orders_notify AFTER INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_notify();
```

```js
new EventSource("/orders/live").onmessage = (e) => render(JSON.parse(e.data));
```

## Topics

- `app.sseTopics(options)` makes a `Topics` the server owns (metrics, drain,
  freed with the server). `app.sse(path, topics, options)` serves a GET
  route; `{name}` in `options.topics` is the route parameter `name`, and a
  name the path lacks is a compile error. `topics.serve(req, res, .{...})`
  does the same from a handler that picks the topics itself (per-user
  topics after authentication); return right after it.
- `topics.publish(topic, .{ .data = ..., .event = "name" })` queues the event
  for every subscriber and returns the number reached. It never waits for a
  subscriber. `publishJson` encodes a value.
- An idle subscriber holds no task over HTTP/1.1, HTTP/2 and HTTP/3 (its
  stream is parked); a task exists only while it has events to write, and writes up to
  64 of them in one write. A middleware that is not detach-safe, or the
  in-memory test client, makes the handler's own task serve the stream
  instead, with the same behaviour.
- Browsers use HTTP/2 only over TLS. Over plain HTTP/1.1 each tab's stream
  takes one of the browser's six connections per host; serve `listenTls`
  in production. A development run with SSE routes and only plain listeners
  says so once at startup.

## Ids, resume and gaps

Every event gets the id `<epoch>-<seq>`; `seq` counts across all topics of
the `Topics`. A reconnecting browser sends the last id as `Last-Event-ID`
(a `lastEventId` query parameter does the same for polyfills) and gets what
it missed from the per-topic replay buffers (256 events or 256 KiB per topic,
64 MiB in all, five minutes; `Options.replay`; `null` turns replay and ids
off). When the buffers cannot cover it (another process's epoch, an event
already evicted, more than `max_per_resume` events), it gets one event named
`gap` (`Options.gap_event`) whose data lists the topics, and the stream goes
live: reload your state on it. `Event.replay = false` keeps an event (a typing
indicator) out of the buffers.

## Slow subscribers, heartbeats, drain

- Each subscriber has a queue of `max_queued_bytes` (256 KiB). With
  `on_full = .close` (default) a subscriber that does not keep up is sent what
  is queued and its stream ends; its browser reconnects and resumes from the
  replay. A sender stuck for `close_after` is aborted. `.drop` skips the
  event for it instead.
- A comment line goes to a subscriber idle for `heartbeat` (15 s), below
  every common idle timeout. The stream carries `X-Accel-Buffering: no`, so
  nginx does not buffer it.
- At the drain each subscriber gets a `retry:` spread over `drain_retry`
  (0.5 s to 5 s) and its stream ends, so the reconnects spread over the new
  process or the other instances.
- `Subscriber` (from `on_open`) can `join`, `leave`, `send` (to that
  subscriber only; `error.Full` past the queue) and `close`.

## Watching changes

| Source | Guarantee | Gap when | Position |
|---|---|---|---|
| PostgreSQL LISTEN/NOTIFY | at most once, commit order | any reconnect | none |
| Redis pub/sub | at most once | any reconnect | none |
| Redis stream | from the last seen id; with a group at least once | `max-deleted-entry-id` is past the position (Redis 7, Valkey 7.2) | entry ids |
| MongoDB change stream | oplog order, resumable | the oplog no longer holds the resume token | resume token |

- All watches of a `pg.Client` share one LISTEN connection, and all pub/sub
  watches of a `redis.Client` one SUBSCRIBE connection. A payload is at most
  8000 bytes in PostgreSQL: send the row id and read the row in a handler.
- Targets (`.to`): an SSE topic or a WebSocket room, fed with no handler. Both
  take templates: `{channel}`, `{op}`, `{data.<field>}` (a top-level member
  of a JSON payload) and for MongoDB `{db}`, `{collection}`, `{key}`.
  `"room:{data.room}"` sends each change to its own browsers. An event a
  template cannot be filled for is skipped and counted.
- A gap reaches an SSE target as the `gap` event, a WebSocket target whose
  room has no placeholders as its `gap_message` (a templated room such as
  `"room:{data.room}"` gets nothing), a handler as an event with
  `op = .gap` (`gaps = true`).
- `w.handle(app, .{}, handler)` runs a handler for each event
  (`fn (*watch.Event) !void`, or with the server's state first). Concurrency 1
  runs them in order; more spreads them over the executors. A handler on a
  shared connection runs behind an inbox of 4096 events, so a slow handler
  never holds the other watches up.
- `w.listen(req, .{})` reads events in a request handler or a background task;
  `next(req)` returns the event, a `.gap` event after a loss, or null at the
  drain. It is bounded and drops the oldest.
- Redis streams: `.group = .{ .name = ... }` reads with XREADGROUP, creating
  the group, reading this consumer's pending entries first, and XACKing once
  every output took the entry (a handler: once it succeeded). `.ack = .manual`
  leaves it to `Event.ack()`.
- MongoDB needs a replica set or a sharded cluster (a single-node replica set
  works: `mongod --replSet rs0` and `rs.initiate()` once). `full_document =
  .update_lookup` adds the document to updates. After an `invalidate` event the
  stream follows a collection that is dropped and made again.
  `Collection.watch`, `Database.watch` and `Client.watch` give the stream
  itself, with automatic resume.
- Each instance runs its own watches and serves its own subscribers. Topics
  shared across instances are not built yet; they are planned together with
  anole-lb.

Metrics: `anole_sse_*` (subscribers, topics, replay bytes, events, closed by
reason, resumes) and `anole_watch_*{watch}`.

## From the C ABI

`"sse"` routes and the `"sse"` block, `anole_sse_publish`, `anole_sse_gap`,
`anole_sse_accept` and the subscriber calls, `"watches"` with
`anole_watch_find` / `_listen` / `_unlisten` / `_ack`: see the C ABI guide.
