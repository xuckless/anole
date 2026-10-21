# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "51d2c8fda814ddd891385df3fa95b8786e8f79a0",
  "date": "2026-10-21T06:28:42Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "ea9074dd9cf0", "bun": "deaed1e11216", "loadgen": "f435f838ed60"}
}

```

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo c=512, 16 in flight | 55,148,448 | 3,675,828 | 2.21 | 2.41 | 2.52 | 0.0 | 18 | 1.00 |  |
| anole | /ws/echo c=4096, 16 in flight | 37,284,080 | 2,485,274 | 26.00 | 31.40 | 32.00 | 0.0 | 134 | 1.00 |  |
| anole | /ws/echo c=16384, 16 in flight | 32,405,984 | 2,160,111 | 117.00 | 124.30 | 130.30 | 0.0 | 531 | 1.00 |  |
| anole | /ws/echo c=512, 16 in flight | 145,494,224 | 9,698,968 | 0.87 | 1.03 | 1.19 | 0.0 | 20 | 3.99 |  |
| anole | /ws/echo c=4096, 16 in flight | 111,777,568 | 7,450,844 | 8.81 | 9.37 | 10.50 | 0.0 | 136 | 3.98 |  |
| anole | /ws/echo c=16384, 16 in flight | 77,827,664 | 5,187,819 | 51.00 | 52.60 | 54.40 | 0.0 | 535 | 3.97 |  |
| bun | /ws/echo c=512, 16 in flight | 48,070,064 | 3,204,244 | 2.54 | 2.81 | 3.17 | 0.0 | 30 | 1.00 |  |
| bun | /ws/echo c=4096, 16 in flight | 40,222,656 | 2,680,974 | 24.20 | 26.30 | 28.60 | 0.0 | 46 | 1.00 |  |
| bun | /ws/echo c=16384, 16 in flight | 38,770,240 | 2,584,338 | 55.80 | 63.30 | 64.20 | 0.0 | 70 | 1.00 |  |
| bun | /ws/echo c=512, 16 in flight | 127,611,680 | 8,506,878 | 0.94 | 1.22 | 1.95 | 0.0 | 81 | 3.99 |  |
| bun | /ws/echo c=4096, 16 in flight | 113,160,816 | 7,543,049 | 8.71 | 10.00 | 11.40 | 0.0 | 102 | 3.97 |  |
| bun | /ws/echo c=16384, 16 in flight | 107,618,512 | 7,173,611 | 36.10 | 41.30 | 42.60 | 0.0 | 190 | 3.98 |  |

