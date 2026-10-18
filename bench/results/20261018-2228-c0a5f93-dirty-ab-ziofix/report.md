# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "c0a5f9369f32d11666d50cf6f248c6ea13128716 (dirty)",
  "date": "2026-10-18T22:28:35Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@before-ziofix": "7b7cae5aec18", "anole@after-ziofix": "e904b7cd7136", "loadgen": "7b120f6c0150"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-ziofix | **234,380** p99 1.17 ms [12 MB, 1.00] | **181,008** p99 1.59 ms [22 MB, 1.00] | **317,403** mean 2.01 ms [40 MB, 1.00] | **260,877** mean 2.44 ms [47 MB, 1.00] | **154,440** mean 4.14 ms [55 MB, 1.00] |
| anole@before-ziofix | **234,975** p99 12.13 ms [12 MB, 1.00] | **178,366** p99 12.74 ms [22 MB, 1.00] | **316,711** mean 2.02 ms [40 MB, 1.00] | **279,634** mean 2.28 ms [49 MB, 1.00] | **157,778** mean 4.07 ms [63 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-ziofix | **224,615** p99 1.35 ms [12 MB, 1.00] | **176,830** p99 1.56 ms [22 MB, 1.00] | **313,923** mean 2.04 ms [56 MB, 1.00] | **277,099** mean 2.31 ms [59 MB, 1.00] | **145,112** mean 4.38 ms [76 MB, 1.00] |
| anole@before-ziofix | **224,627** p99 12.23 ms [12 MB, 1.00] | **176,929** p99 12.78 ms [22 MB, 1.00] | **312,739** mean 2.05 ms [58 MB, 1.00] | **274,709** mean 2.32 ms [62 MB, 1.00] | **144,760** mean 4.23 ms [74 MB, 1.00] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@after-ziofix | 244,682 / 0.3 / 4 | 221,515 / 1.3 / 12 | 208,394 / 111.6 / 42 | 152,440 / 6299.4 / 147 | 122,232 / 1977.1 / 227 |
| anole@before-ziofix | 261,236 / 0.3 / 4 | 218,868 / 12.4 / 12 | 195,339 / 145.0 / 42 | 203,112 / 5620.0 / 156 | 217,447 / 2584.5 / 248 |

