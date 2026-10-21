# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "498284a78237afc05f096a6e4628f8436e38b2e0",
  "date": "2026-10-21T13:57:13Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@a": "ef0d75a3a5d3", "loadgen": "1d997e2543f1"}
}

```

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /ws/echo c=512, 16 in flight | 129,761,280 | 8,650,175 | 0.96 | 1.08 | 1.11 | 0.0 | 20 | 3.99 |  |
| anole@b | /ws/echo c=512, 16 in flight | 128,241,904 | 8,548,890 | 0.91 | 1.18 | 1.20 | 0.0 | 17 | 3.99 |  |

