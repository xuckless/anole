# {{name}}

A WebSocket chat on [Anole](https://github.com/xuckless/anole).

```
zig build run          # http://localhost:3000: open it in two tabs
zig build test         # two clients on a loopback socket
zig build openapi      # writes openapi.json (the REST part: /rooms)
```

- `src/main.zig`: `/ws?room=lobby` joins a room (`anole.websocket.Rooms`) and
  sends each message to everyone in it; `GET /rooms` is a typed REST route.
- `public/index.html`: the page, served as static files.

The same handler serves WebSocket over HTTP/1.1 and HTTP/2. A chat that
outgrows one process publishes through Redis or NATS (see the messaging guide).
Release builds run in production mode; see
[the server guide](https://github.com/xuckless/anole/blob/main/docs/server.md).
