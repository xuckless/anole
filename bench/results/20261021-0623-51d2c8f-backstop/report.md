# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "51d2c8fda814ddd891385df3fa95b8786e8f79a0",
  "date": "2026-10-21T06:23:10Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "ea9074dd9cf0", "bun": "deaed1e11216", "loadgen": "0b6e5d504c67"}
}

```

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo c=512, 16 in flight | 48,659,232 | 3,243,516 | 2.50 | 2.75 | 2.98 | 0.0 | 18 | 1.00 |  |
| anole | /ws/echo c=4096, 16 in flight | 36,282,368 | 2,418,502 | 26.80 | 29.50 | 35.60 | 0.0 | 134 | 1.00 |  |
| anole | /ws/echo c=16384, 16 in flight | 31,826,624 | 2,121,492 | 118.90 | 132.90 | 135.00 | 0.0 | 532 | 1.00 |  |
| anole | /ws/echo c=512, 16 in flight | 125,590,128 | 8,372,117 | 0.94 | 1.12 | 1.27 | 0.0 | 20 | 3.99 |  |
| anole | /ws/echo c=4096, 16 in flight | 98,225,504 | 6,547,930 | 9.56 | 11.80 | 12.40 | 0.0 | 137 | 3.98 |  |
| anole | /ws/echo c=16384, 16 in flight | 72,722,992 | 4,847,553 | 54.10 | 55.50 | 57.70 | 0.0 | 539 | 3.98 |  |
| bun | /ws/echo c=512, 16 in flight | 47,863,632 | 3,190,271 | 2.54 | 2.86 | 3.45 | 0.0 | 30 | 1.00 |  |
| bun | /ws/echo c=4096, 16 in flight | 39,790,432 | 2,652,342 | 24.50 | 26.60 | 28.30 | 0.0 | 46 | 1.00 |  |
| bun | /ws/echo c=16384, 16 in flight | 38,687,680 | 2,578,663 | 56.80 | 64.60 | 66.50 | 0.0 | 74 | 1.00 |  |
| bun | /ws/echo c=512, 16 in flight | 126,870,960 | 8,457,500 | 0.94 | 1.18 | 1.90 | 0.0 | 93 | 3.99 |  |
| bun | /ws/echo c=4096, 16 in flight | 111,943,648 | 7,462,412 | 8.76 | 10.00 | 12.80 | 0.0 | 118 | 3.98 |  |
| bun | /ws/echo c=16384, 16 in flight | 107,549,664 | 7,169,022 | 36.30 | 38.90 | 40.60 | 0.0 | 188 | 3.97 |  |

