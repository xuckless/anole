# Server-sent events

Up: [index](index.md). Related: [watch](watch.md) (feed topics from database changes), [rooms](rooms.md) (the WebSocket equivalent).

`anole.sse.Topics` is a pub/sub hub for event streams: publish once, every subscriber of the topic gets it, with ids, `Last-Event-ID` replay, heartbeats, a slow-client policy and a spread-out drain. Do not write `text/event-stream` responses or keep subscriber lists by hand. `anole.sse` is always compiled in (no build flag).

Use:
- `anole.App.sseTopics`, `anole.App.sse` (src/server.zig; also on `Server(App)`; groups have `sse`)
- `anole.sse.Topics`: `publish`, `publishJson`, `serve`, `gap`, `count`, `stats`; `anole.sse.Topics.Options`, `anole.sse.Topics.Replay` (src/sse/root.zig)
- `anole.sse.Event` (`data`, `event`, `replay`), `anole.sse.RouteOptions` (`topics`, `last`), `anole.sse.ServeOptions` (`topics`, `last`, `headers`, `context`, `on_open`, `on_close`), `anole.sse.Subscriber` (`join`, `leave`, `send`, `close`), `anole.sse.CloseReason` (src/sse/root.zig)
- `anole.sse.Parser` (src/sse/parser.zig) to read another server's stream

## A topic and a route (docs/realtime.md, templates/full)

```zig
const live = try app.sseTopics(.{});                 // replay, heartbeats: on
app.sse("/orders/live", live, .{ .topics = &.{"orders"} });
app.sse("/rooms/:room/events", live, .{ .topics = &.{ "news", "room:{room}" } });

// anywhere (a handler, a job, a watch handler); templates/full/src/main.zig:
_ = try app.live.publishJson("todos", "created", todo);
```

```js
new EventSource("/orders/live").onmessage = (e) => render(JSON.parse(e.data));
```

- `app.sseTopics(options)` returns a `*Topics` the server owns: metrics, drain, freed with the server. Keep the pointer in your state struct (`live: *anole.sse.Topics`).
- `app.sse(path, topics, .{ .topics = ... })` serves a GET route. `{name}` in a topic is the route parameter `name`; a name the path lacks is a compile error.
- A handler that picks topics itself (per-user topics after authentication) calls `topics.serve(req, res, .{ .topics = ... })` and returns right after it.
- `publish` returns the number of subscribers reached and never waits for any of them. An event with `.event = null` reaches the browser's `onmessage`. `topics.publish(topic, .{ .data = ..., .event = "name" })` sends a named one.

## Ids, replay and gaps

Every event gets the id `<epoch>-<seq>`. A reconnecting browser sends `Last-Event-ID` (or a `lastEventId` query parameter for polyfills) and gets what it missed from per-topic replay buffers. `Topics.Replay` defaults: 256 events or 256 KiB per topic, 64 MiB in all, `max_age` 5 min, `max_per_resume` 1024. When the buffers cannot cover it, the client gets one event named `gap` (`Options.gap_event`) listing the topics, then live events: reload state on it. `.replay = null` turns ids, replay and gaps off. `Event.replay = false` keeps one event (a typing indicator) out of the buffers. `ServeOptions.last` / `RouteOptions.last` sends the newest N events of each topic to a fresh subscriber.

## Slow subscribers, heartbeats, drain (`Topics.Options`)

| Field | Default | Meaning |
| --- | --- | --- |
| `heartbeat` | 15 s | Comment line to an idle subscriber; null: none. |
| `retry` | null | `retry:` at stream start; null: browser default. |
| `max_queued_bytes` | 256 KiB | Queue per subscriber (each event counts 64 more). |
| `on_full` | `.close` | `.close`: the subscriber gets what is queued, its stream ends, the browser reconnects and resumes from replay. `.drop`: skip the event for it. |
| `close_after` | 1 s | A sender stuck this long on a full subscriber aborts its stream. |
| `leave_grace` | 1 s | How long `leave` or an end lets a write under way finish. |
| `max_topics_per_subscriber` | 64 | |
| `gap_event` | `"gap"` | Null: no gap events. |
| `drain_retry` | 0.5 s to 5 s | At the drain each subscriber gets a spread `retry:` and its stream ends. |

## Reading a stream (an LLM API, a feed)

```zig
var response = try client.fetch(url, .{ .stream = true });
defer response.deinit();
var buf: [16 * 1024]u8 = undefined;
var body = try response.reader(&buf);
var events = anole.sse.Parser.init(gpa, &body.interface, .{});
defer events.deinit();
while (try events.next()) |e| {
    if (std.mem.eql(u8, e.data, "[DONE]")) break;
    try handle(e.event, e.data);
}
```

`next()` slices are valid until the next `next`. `Options.max_event_size` (16 MiB) bounds one event (`error.EventTooLarge`). After an error the parser is spent. Reconnecting (with `parser.retry` and the last `id`) is the caller's.

Traps:
- Prefer `app.sseTopics` over `anole.sse.Topics.init`/`create`: the server's hub gets the drain and metrics and is freed for you. A hub you `init` yourself takes the runtime's `app.io()` (src/sse/root.zig, field `io`), and its `deinit` is for after the server stopped, with no subscriber left (src/sse/root.zig `Topics.deinit`): free it after `app.deinit()`, as with [Rooms](rooms.md).
- Browsers use HTTP/2 only over TLS. Over plain HTTP/1.1 each tab's stream takes one of six connections per host; serve with TLS in production (a development run with SSE routes and only plain listeners logs this once).
- Event `data` must be UTF-8; `event` and `gap_event` may not contain CR or LF (`error.InvalidEventField`). A topic name is 1 to 255 bytes (`error.InvalidTopic`).
- `ServeOptions.on_close` must not wait; the `*Subscriber` is invalid after it returns. `Subscriber.send` fails with `error.Full` past the queue (back-pressure is signalled, not waited out; see [writes return once buffered](../runtime.md#writes-return-once-buffered)).
- An idle subscriber holds no task. A middleware that is not detach-safe (or the in-memory test client) makes the handler's own task serve the stream instead.
- Topics are per instance: each instance serves its own subscribers; shared topics across instances are not built yet.
- The stream carries `X-Accel-Buffering: no`, so nginx does not buffer it.
