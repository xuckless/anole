# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "7c3a586fef5aad09f9b6052f99776dba7f8e8736",
  "date": "2026-10-21T17:23:39Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@b": "c6e0bad83571", "loadgen": "75b50004f33c"}
}

```

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@b | /ws/echo c=512, 16 in flight | 51,969,776 | 3,464,190 | 2.34 | 2.64 | 2.78 | 0.0 | 15 | 1.00 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 36,381,696 | 2,425,123 | 26.90 | 28.80 | 31.70 | 0.0 | 110 | 1.00 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 31,832,384 | 2,122,017 | 117.80 | 134.30 | 135.20 | 0.0 | 426 | 1.00 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 54,449,584 | 3,629,488 | 2.24 | 2.46 | 2.58 | 0.0 | 14 | 1.00 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 33,350,208 | 2,222,903 | 29.20 | 31.40 | 33.80 | 0.0 | 129 | 1.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 24,967,728 | 1,664,293 | 135.80 | 144.90 | 146.10 | 0.0 | 563 | 1.00 |  |

