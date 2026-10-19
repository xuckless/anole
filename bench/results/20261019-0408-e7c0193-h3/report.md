# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "e7c019327bbcf930dd689b92386657d067442dbb",
  "date": "2026-10-19T04:10:02Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "9a56f4781d0b", "fiber": "8e5f66a160d8", "gohttp": "9ad658cb5624", "axum": "bd66830683f6", "express": "1d4bcf0d5e69", "fastify": "378067d992ac", "fastapi": "eef6cec895c3", "nginx": "6f4c687d31a4", "gohttp-wt": "b71f8fab8b9c", "axum-wt": "5d1cb4993bce", "fastify-wt": "f85fb74f37fd", "fastapi-wt": "bf0d6a4cc457", "loadgen": "4b0738a9d98f"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h3 |
| --- | ---: |
| anole | **279,598** mean 2.28 ms [55 MB, 1.00] |
| gohttp | **84,008** mean 7.59 ms [20 MB, 1.00] |
| axum | **112,640** mean 5.68 ms [14 MB, 1.00] |
| fastapi | **2,630** mean 182.82 ms [93 MB, 0.99] |
| nginx | **437,270** mean 1.47 ms [71 MB, 1.00] |

### 1cpu, GET /json

| Server | h3 |
| --- | ---: |
| anole | **273,347** mean 2.34 ms [66 MB, 1.00] |
| gohttp | **83,429** mean 7.67 ms [21 MB, 1.00] |
| axum | **117,582** mean 5.44 ms [15 MB, 1.00] |
| fastapi | **2,525** mean 194.30 ms [108 MB, 0.99] |
| nginx | **419,043** mean 1.57 ms [73 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h3 |
| --- | ---: |
| anole | **907,593** mean 0.71 ms [59 MB, 3.99] |
| gohttp | **201,323** mean 3.17 ms [24 MB, 3.86] |
| axum | **273,727** mean 2.34 ms [17 MB, 3.89] |
| fastapi | **8,878** mean 45.45 ms [328 MB, 3.89] |
| nginx | **1,267,491** mean 0.50 ms [148 MB, 3.99] |

### 4cpu, GET /json

| Server | h3 |
| --- | ---: |
| anole | **875,209** mean 0.73 ms [67 MB, 3.99] |
| gohttp | **199,681** mean 3.20 ms [24 MB, 3.85] |
| axum | **284,911** mean 2.25 ms [17 MB, 3.89] |
| fastapi | **8,589** mean 48.92 ms [337 MB, 3.92] |
| nginx | **1,260,572** mean 0.51 ms [150 MB, 3.99] |

## WebTransport (draft-02)

wtload (webtransport-go v0.10.0, the last draft-02 release) against /wt/echo. Sessions: QUIC handshake plus extended CONNECT, 64 at a time; the latency columns are the handshake. Streams: 16 sessions with 4 bidirectional streams each in flight, 16 KiB echoed per stream; rate is streams/s. Datagrams: 64 sessions each sending 1000 64-byte datagrams/s, echoed back; rate is received/s, loss in the notes. Anole serves it from its own HTTP/3; Go from webtransport-go, Rust from wtransport, Node from @fails-components/webtransport (Chromium's QUICHE), Python from aioquic.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /wt/echo sessions n=2000 c=64 | 2,000 | 3,197 | 6.10 | 206.66 | 214.30 | 601.9 | 95 | 0.59 |  |
| anole | /wt/echo streams 16 sessions x 4, 16 KiB | 427,492 | 28,453 | 1.03 | 29.09 | 81.14 | 187.2 | 95 | 1.00 |  |
| anole | /wt/echo datagrams 64 sessions x 1000/s, 64 B | 959,916 | 63,994 | 0.27 | 1.42 | 1.74 | 4.8 | 95 | 0.29 | loss 0.00% (20 of 959936) |
| gohttp-wt | /wt/echo sessions n=2000 c=64 | 2,000 | 2,819 | 21.90 | 37.38 | 45.48 | 47.7 | 16 | 1.00 |  |
| gohttp-wt | /wt/echo streams 16 sessions x 4, 16 KiB | 273,805 | 18,251 | 3.69 | 5.54 | 6.14 | 7.8 | 17 | 1.00 |  |
| gohttp-wt | /wt/echo datagrams 64 sessions x 1000/s, 64 B | 959,936 | 63,996 | 0.58 | 2.49 | 3.32 | 4.6 | 17 | 0.64 | loss 0.00% (0 of 959936) |
| axum-wt | /wt/echo sessions n=2000 c=64 | 2,000 | 3,481 | 9.82 | 201.90 | 212.01 | 212.1 | 26 | 0.67 |  |
| axum-wt | /wt/echo streams 16 sessions x 4, 16 KiB | 431,347 | 28,731 | 1.39 | 28.61 | 80.86 | 395.1 | 25 | 1.00 |  |
| axum-wt | /wt/echo datagrams 64 sessions x 1000/s, 64 B | 959,936 | 63,996 | 0.47 | 1.35 | 1.68 | 3.6 | 25 | 0.56 | loss 0.00% (0 of 959936) |
| fastify-wt | /wt/echo sessions n=2000 c=64 | 2,000 | 1,668 | 14.75 | 259.09 | 636.03 | 675.5 | 104 | 0.88 |  |
| fastify-wt | /wt/echo streams 16 sessions x 4, 16 KiB | 35,021 | 2,319 | 16.37 | 185.75 | 376.94 | 1798.4 | 150 | 0.99 |  |
| fastify-wt | /wt/echo datagrams 64 sessions x 1000/s, 64 B | 531,788 | 35,453 | 3.96 | 16.72 | 19.33 | 463.6 | 199 | 0.93 | loss 44.60% (428148 of 959936) |
| fastapi-wt | /wt/echo sessions n=2000 c=64 | 1,999 | 398 | 42.83 | 718.97 | 3052.96 | 3054.3 | 123 | 0.62 | 1x timeout: no recent network activity |
| fastapi-wt | /wt/echo streams 16 sessions x 4, 16 KiB | 9,501 | 402 | 67.64 | 429.78 | 638.35 | 720.2 | 124 | 0.64 | 4x read: deadline exceeded |
| fastapi-wt | /wt/echo datagrams 64 sessions x 1000/s, 64 B | 190,735 | 12,716 | 13.45 | 315.69 | 2823.44 | 12200.2 | 124 | 0.71 | loss 72.26% (496888 of 687623) |

