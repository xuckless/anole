# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "c0a5f9369f32d11666d50cf6f248c6ea13128716 (dirty)",
  "date": "2026-10-18T22:50:43Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@after-accept": "e30371e747f9", "loadgen": "7b120f6c0150"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-accept | **232,175** p99 1.36 ms [12 MB, 1.00] | **179,933** p99 1.56 ms [22 MB, 1.00] | **408,105** mean 1.56 ms [41 MB, 1.00] | **336,472** mean 1.85 ms [51 MB, 1.00] | **161,420** mean 3.92 ms [75 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-accept | **192,966** p99 1.49 ms [12 MB, 1.00] | **143,593** p99 2.07 ms [22 MB, 1.00] | **406,665** mean 1.57 ms [58 MB, 1.00] | **371,133** mean 1.72 ms [67 MB, 1.00] | **155,974** mean 4.07 ms [91 MB, 1.00] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-accept | 250,241 / 0.3 / 4 | 229,327 / 1.3 / 12 | 199,017 / 6.6 / 42 | 137,680 / 32.9 / 165 | 114,970 / 702.9 / 401 |

