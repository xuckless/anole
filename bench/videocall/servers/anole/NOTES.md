# Anole video-call app: notes

- **Build:** Anole v0.1.3 from `zig fetch --save git+https://github.com/xuckless/anole#v0.1.3`, built with `addApp`, as docs/getting-started.md does. ReleaseSafe, the build mode the docs tell servers to use, with `-Dcpu=baseline`. The default `full` profile includes BoringSSL TLS, HTTP/3 and zlib-ng.
- **Server:** `anole.Server(App)` with `.errors = .json`, `.https` on PORT, and `.http3 = .{ .webtransport = true }` on the same port over UDP. Everything else, timeouts and limits included, is at its defaults.
- **Upgrades:** `/ws` and `/wt` are GET handlers. They check the token (401) and the one-connection rule (409) first, then call `anole.websocket.upgrade` or `anole.webtransport.accept`. This is the documented path when a handler needs checks before the upgrade.
  - WebSocket: permessage-deflate off, since the app does its own compression; origins `.any`; max message 24 B + 1 MiB, with close 1009 above that.
- **Shared state:** users, tokens, the lobby and calls sit behind one `std.Io.Mutex`. Messages are collected under it and sent after it's released.
- **Relay:** media goes to the peer with `ws.send`, or as frames on a uni stream the app opens lazily for each kind. Each user has a `send_mutex`, which serialises sends and guards the connection's lifetime: a closing connection clears `conn` and releases its streams under that mutex.
- **Compression:** one `anole.compression.zlib.Compress` per connection (raw, default options: level 6, 15-bit window, memLevel 8), reset for each message. Each message is its own DEFLATE stream.
