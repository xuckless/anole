# Database change feeds

Up: [index](index.md). Related: [sse](sse.md) (topics), [rooms](rooms.md) (WebSocket rooms), [databases](../databases/index.md) (`app.postgres`, `app.redis`, `app.mongodb`).

`app.watch` turns PostgreSQL LISTEN/NOTIFY, Redis pub/sub, Redis streams and MongoDB change streams into SSE topic events or WebSocket room broadcasts with no handler in between, or runs a handler per change. Do not write your own LISTEN loop, SUBSCRIBE connection or change-stream resume logic. `anole.watch` is always compiled in; each source needs its connector's build flag.

Use:
- `anole.App.watch` (src/server.zig; also on `Server(App)`), returns `*anole.watch.Watch`
- `anole.watch.Source` (`.postgres`, `.redis`, `.redis_stream`, `.mongodb`), `anole.watch.Postgres` (`client`, `channels`), `anole.watch.Redis` (`client`, `channels`, `patterns`), `anole.watch.RedisStream` (`client`, `keys`, `start`, `group`, `count`, `block`), `anole.watch.StreamGroup` (`name`, `consumer`, `create`, `ack`), `anole.watch.Ack` (`.auto`, `.manual`), `anole.watch.MongoDb` (`client`, `database`, `collection`, `pipeline`, `full_document`, `start`, ...) (src/watch/root.zig)
- `anole.watch.Options` (`name`, `to`, `data`, `reconnect`), `anole.watch.Target` (`.sse`: `topics`, `topic`, `event`; `.ws`: `rooms`, `room`, `type`, `gap_message`), `anole.watch.Data` (`.auto`, `.document`) (src/watch/root.zig)
- `anole.watch.Watch.handle`, `anole.watch.HandleOptions` (`concurrency`, `timeout`, `gaps`), `anole.watch.Watch.listen`, `anole.watch.ListenOptions`, `anole.watch.Listener` (`next`, `close`), `anole.watch.Event` (`op`, `channel`, `data`, `json`, `document`, `ack`), `anole.watch.Op` (src/watch/root.zig)

## PostgreSQL into an SSE topic (docs/realtime.md)

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

## Into a WebSocket room (docs/websocket.md)

```zig
_ = try app.watch(source, .{ .to = &.{.{ .ws = .{ .rooms = &state.rooms, .room = "orders" } }} });
```

Targets take templates: `{channel}`, `{op}`, `{data.<field>}` (a top-level member of a JSON payload) and for MongoDB `{db}`, `{collection}`, `{key}`. `"room:{data.room}"` sends each change only to that room's clients. An event a template cannot be filled for is skipped and counted.

## A handler, or reading in a request

- `try w.handle(&app, .{}, onChange)` with `fn (ev: *anole.watch.Event) !void` (or the server's state first). Concurrency 1 runs in order; more spreads over executors and loses order. Each event is bounded by `timeout` (30 s), then canceled.
- `const l = try w.listen(req, .{}); defer l.close();` then `while (try l.next(req)) |ev| ...`: a `.gap` event after a loss, null at the drain or when the watch stops. Bounded (`max_events` 1024, `max_bytes` 4 MiB); drops the oldest.

## Guarantees

| Source | Guarantee | Gap when | Position |
|---|---|---|---|
| PostgreSQL LISTEN/NOTIFY | at most once, commit order | any reconnect | none |
| Redis pub/sub | at most once | any reconnect | none |
| Redis stream | from the last seen id; with a group at least once | `max-deleted-entry-id` is past the position (Redis 7, Valkey 7.2) | entry ids |
| MongoDB change stream | oplog order, resumable | the oplog no longer holds the resume token | resume token |

Traps:
- A PostgreSQL NOTIFY payload is at most 8000 bytes: send the row id and read the row in a handler.
- Gaps: an SSE target gets the `gap` event; a WebSocket target with a fixed room gets `gap_message` (null: nothing); a templated room (`"room:{data.room}"`) gets nothing; a handler gets `op = .gap` only with `.gaps = true`. Clients must reload state on a gap.
- Rooms passed as a target must outlive the watch: the server stops watches at the drain and frees them in `app.deinit()`, so free your `Rooms` after `app.deinit()` ([rooms](rooms.md)).
- The server starts a watch when serving starts (after the database clients it reads) and stops it at the drain; one made after serving started starts in the call, and a failed start is that call's error. Under the lambda deployment watches do not start.
- All watches of one `pg.Client` share one LISTEN connection, and pub/sub watches of one `redis.Client` one SUBSCRIBE connection. A handler on a shared connection runs behind an inbox of 4096 events, so a slow handler does not hold up the others, but do not block it: [never block an executor](../runtime.md#never-block-an-executor).
- Redis stream groups: XREADGROUP, the group created if missing, this consumer's pending entries first, XACK once every output took the entry (a handler: once it succeeded). `.ack = .manual` leaves it to `ev.ack()`.
- MongoDB needs a replica set or sharded cluster (a single-node replica set works: `mongod --replSet rs0`, `rs.initiate()` once). `full_document = .update_lookup` adds the document to updates.
- Each instance runs its own watches and serves its own subscribers; topics shared across instances are not built yet.
