# Video-call benchmark

A realistic load-bearing test: the same small 1:1 video-call app
([SPEC.md](SPEC.md)) written in four stacks the way a normal developer would
write it. It's ramped one user at a time on 1 CPU and 2 GB (no swap) until
the server crashes or its calls collapse.

| app | stack | WebTransport | deflate |
|---|---|---|---|
| [anole](servers/anole) | Zig 0.17, Anole v0.1.3 (`zig fetch`), ReleaseSafe | Anole | zlib-ng (`anole.compression.zlib`) |
| [bun](servers/bun) | Bun 1.4.3, TypeScript, `Bun.serve` | @fails-components/webtransport 1.6.8 (QUICHE addon) | node:zlib `deflateRawSync` |
| [fiber](servers/fiber) | Go 1.27.2, Fiber v3.6.1, gofiber/contrib websocket | webtransport-go v0.10.0 (quic-go) | compress/flate |
| [axum](servers/axum) | Rust 1.99.1, axum 0.8.9, axum-server (rustls) | wtransport 0.7.2 (quinn) | flate2 (miniz_oxide) |

Every app compresses each media packet it relays: raw DEFLATE at the
library's default level (6), one stream per message. Each server's NOTES.md
lists its choices and its deviations from the spec.

## What a user does

[vcload](../tools/vcload) simulates the users:

1. **Sign up and connect.** Each user signs up (`POST /api/users`), opens a
   realtime connection (WebSocket, or a WebTransport session), and waits to
   be paired.
2. **Start the call.** Once paired, it loads the call's chat history over
   HTTP.
3. **Stream media.** It streams the clip to its peer at real time:
   - 1080p30 H.264 High at 4 Mbit/s, with a keyframe every 2 s and no
     B-frames;
   - 20 ms Opus packets at 64 kbit/s.
   - The video starts at a keyframe of a random GOP for each call.
4. **Chat.** It sends a chat message every 3 s.
5. **Receive.** Every received packet is inflated and CRC-checked, and its
   one-way latency is measured against its capture time. Time spent queued
   behind backpressure therefore counts.
   - **Video:** a frame shows if it arrived within 200 ms and every frame
     since its keyframe showed.
   - **Audio:** a packet plays if it arrived within 150 ms.

One user is added every 5 s. The run stops when the server's container
exits or is OOM-killed, when under 10% of video frames show for 30 s
("collapsed"), or when users are refused for 30 s.

**Quality:** users 0 and 1 are the probe call. Afterwards,
[quality.py](media/quality.py) rebuilds what their screens and speakers
played, step by step:
- frozen frames are compared with what should have shown, giving PSNR and
  VMAF (Netflix's vmaf 3.0.0);
- lost or late audio is silence, giving audio SNR against the clip.

## Running it

```sh
docker build -f bench/videocall/media/Dockerfile -t anole-bench/vc-media .
docker build -f bench/loadgen/Dockerfile -t anole-bench/loadgen .
for s in anole bun fiber axum; do docker build -f bench/videocall/servers/$s/Dockerfile -t anole-bench/vc-$s .; done
bench/videocall/run.sh 20261022-videocall      # results/<id>/videocall/index.html
```

`vcload -smoke -transport ws|wt -url https://127.0.0.1:8443` checks an app
against the spec. The interactive page (`index.html`) has a slider for
concurrent users that drives the bar charts, and charts each metric across
the whole ramp.
