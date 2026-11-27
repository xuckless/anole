# Realtime

Push to browsers and peers with Anole's built-in WebSocket rooms, SSE topics, WebTransport and database change feeds; never hand-roll a socket registry, pub/sub map or event-stream writer.

Up: [SKILL.md](../../SKILL.md). Full docs: docs/websocket.md, docs/realtime.md, docs/webtransport.md. Examples: examples/websocket/main.zig, templates/realtime, templates/full.

| Need | Use | File |
| --- | --- | --- |
| Two-way messages over one connection (chat, games, collaborative editing) | `app.ws`, `app.wsCallbacks`, `anole.websocket.upgrade` | [websocket.md](websocket.md) |
| Broadcast to groups of WebSockets | `anole.websocket.Rooms` | [rooms.md](rooms.md) |
| Server-to-browser push (feeds, notifications, live dashboards) with replay after reconnect | `app.sseTopics`, `app.sse`, `anole.sse.Topics` | [sse.md](sse.md) |
| Many streams plus unreliable datagrams over HTTP/3 (games, media) | `app.webtransport`, `anole.webtransport.accept` | [webtransport.md](webtransport.md) |
| PostgreSQL / Redis / MongoDB changes into SSE topics or rooms, no handler | `app.watch`, `anole.watch` | [watch.md](watch.md) |

Pick SSE over WebSocket when the browser only listens: it reconnects and resumes by itself (`Last-Event-ID`), and an idle subscriber holds no task.

Shared runtime rules that apply to every handler here: [never block an executor](../runtime.md#never-block-an-executor), [re-raise error.Canceled](../runtime.md#re-raise-errorcanceled), [writes return once buffered](../runtime.md#writes-return-once-buffered), [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).

Related areas: [HTTP](../http/index.md) (routes, groups, `Server(App)`), [middleware and auth](../middleware-auth/index.md) (authenticate before a handshake), [databases](../databases/index.md) (`app.postgres`, `app.redis`, `app.mongodb` for watches), [testing](../testing.md), [observability](../observability.md) (`anole_sse_*`, `anole_watch_*` metrics).
