# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "d3c7ac3c1b823f10598812741d31c6f85c9148aa",
  "date": "2026-10-19T12:09:58Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "1cdf8a898eff", "loadgen": "e96af9ca5786"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: |
| anole | **209,744** p99 1.29 ms [17 MB, 1.00] | **722,472** mean 0.88 ms [13 MB, 1.00] | **684,971** mean 0.93 ms [21 MB, 1.00] | **328,308** mean 1.96 ms [63 MB, 1.00] |

### 1cpu, GET /json

| Server | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: |
| anole | **207,518** p99 1.47 ms [17 MB, 1.00] | **697,847** mean 0.91 ms [14 MB, 1.00] | **661,387** mean 0.96 ms [22 MB, 1.00] | **323,002** mean 1.99 ms [77 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: |
| anole | **531,881** p99 0.56 ms [17 MB, 3.99] | **2,023,765** mean 0.31 ms [14 MB, 3.99] | **1,899,555** mean 0.32 ms [23 MB, 3.99] | **1,064,722** mean 0.61 ms [60 MB, 3.99] |

### 4cpu, GET /json

| Server | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: |
| anole | **523,706** p99 0.59 ms [18 MB, 3.99] | **1,981,699** mean 0.31 ms [15 MB, 3.99] | **1,860,185** mean 0.33 ms [24 MB, 3.99] | **1,032,965** mean 0.62 ms [68 MB, 3.98] |

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 311 | 0.03 | 31.5 KB per socket (2 MB -> 309 MB) |
| anole | /ws/echo echo c=64 | 4,207,929 | 280,524 | 0.22 | 0.51 | 0.91 | 1.6 | 272 | 1.00 |  |
| anole | /ws/echo echo c=1024 | 3,519,704 | 234,579 | 4.31 | 5.14 | 6.31 | 8.4 | 280 | 1.00 |  |
| anole | /ws/feed fanout-100x1000hz | 100 | 100,000 | 0.17 | 0.57 | 1.03 | 1.5 | 5 | 0.37 | 100/100 connected, 100000 of 100000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-1000x1000hz | 1,000 | 281,099 | 1.80 | 3.65 | 4.43 | 6.0 | 36 | 1.00 | 1000/1000 connected, 281099 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-10000x100hz | 10,000 | 225,743 | 22.20 | 44.02 | 45.94 | 51.7 | 348 | 1.00 | 10000/10000 connected, 225743 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed trading-500bots | 500 | 100,001 | 0.90 | 1.89 | 3.15 | 3.9 | 21 | 0.37 | 500/500 connected, 100001 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.17 p99 0.40 p99.9 1.11 ms, 0 errors |
| anole | /ws/feed trading-2000bots | 2,000 | 257,255 | 3.94 | 8.39 | 9.33 | 10.1 | 78 | 1.00 | 2000/2000 connected, 257255 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 0.61 p99 1.09 p99.9 1.26 ms, 0 errors |

## gRPC

ghz, unary grpc.testing.TestService/UnaryCall (the interop semantics: a reply of response_size zero bytes) over plaintext HTTP/2, 8 connections with 64 calls in flight; ghz has no p99.9. Anole uses its interop server; the others the standard library of their language (grpc-go, tonic, @grpc/grpc-js, grpcio aio).

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | UnaryCall 1cpu, 0 B reply | 1,275,526 | 85,037 | 0.19 | 1.55 | 0.00 | 7.8 | 6 | 0.72 | load generator at 13.5 of 16 CPUs |
| anole | UnaryCall 1cpu, 1024 B reply | 1,236,268 | 82,418 | 0.21 | 1.59 | 0.00 | 6.9 | 7 | 0.73 | load generator at 13.5 of 16 CPUs |
| anole | UnaryCall 4cpu, 0 B reply | 1,231,196 | 82,083 | 0.15 | 1.57 | 0.00 | 6.4 | 8 | 1.10 | load generator at 13.5 of 16 CPUs |
| anole | UnaryCall 4cpu, 1024 B reply | 1,183,440 | 78,902 | 0.16 | 1.68 | 0.00 | 7.5 | 11 | 1.10 | load generator at 13.4 of 16 CPUs |

