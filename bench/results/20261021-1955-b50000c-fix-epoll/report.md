# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "b50000c42ead00a20c3e6087816af22884791972",
  "date": "2026-10-21T19:55:50Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@main2": "7a960dcbfa0a", "anole@fix": "700a68dd861d", "loadgen": "75b50004f33c"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **247,240** p99 1.10 ms [7 MB, 1.00] | **204,035** p99 1.35 ms [15 MB, 1.00] | **688,789** mean 0.92 ms [17 MB, 1.00] |
| anole@main2 | **242,246** p99 1.12 ms [8 MB, 1.00] | **206,848** p99 1.32 ms [17 MB, 1.00] | **679,516** mean 0.94 ms [22 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **240,656** p99 1.11 ms [7 MB, 1.00] | **191,983** p99 1.42 ms [16 MB, 1.00] | **656,839** mean 0.97 ms [15 MB, 1.00] |
| anole@main2 | **242,426** p99 1.12 ms [8 MB, 1.00] | **202,000** p99 1.38 ms [17 MB, 1.00] | **664,247** mean 0.96 ms [21 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **600,439** p99 0.48 ms [8 MB, 3.99] | **525,689** p99 0.61 ms [15 MB, 3.99] | **1,987,557** mean 0.31 ms [20 MB, 3.99] |
| anole@main2 | **595,951** p99 0.48 ms [10 MB, 3.99] | **523,657** p99 0.57 ms [16 MB, 4.00] | **1,967,367** mean 0.31 ms [21 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **591,219** p99 0.51 ms [8 MB, 3.99] | **516,236** p99 0.60 ms [15 MB, 3.99] | **1,926,989** mean 0.32 ms [20 MB, 3.99] |
| anole@main2 | **598,552** p99 0.48 ms [9 MB, 3.99] | **516,565** p99 0.57 ms [16 MB, 3.99] | **1,917,622** mean 0.32 ms [23 MB, 3.99] |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@main2 | /ws/echo c=512, 16 in flight | 52,952,832 | 3,529,953 | 2.31 | 2.47 | 2.55 | 0.0 | 18 | 1.00 |  |
| anole@main2 | /ws/echo c=4096, 16 in flight | 37,046,800 | 2,469,622 | 26.30 | 28.60 | 33.90 | 0.0 | 134 | 1.00 |  |
| anole@main2 | /ws/echo c=16384, 16 in flight | 32,390,352 | 2,159,069 | 117.00 | 121.20 | 121.50 | 0.0 | 531 | 1.00 |  |
| anole@fix | /ws/echo c=512, 16 in flight | 52,458,208 | 3,496,748 | 2.33 | 2.52 | 2.62 | 0.0 | 15 | 1.00 |  |
| anole@fix | /ws/echo c=4096, 16 in flight | 36,351,344 | 2,423,100 | 26.80 | 29.30 | 35.70 | 0.0 | 110 | 1.00 |  |
| anole@fix | /ws/echo c=16384, 16 in flight | 32,097,680 | 2,139,703 | 117.90 | 122.50 | 127.40 | 0.0 | 426 | 1.00 |  |
| anole@fix | /ws/echo-cb c=512, 16 in flight | 53,963,952 | 3,597,117 | 2.27 | 2.48 | 2.58 | 0.0 | 14 | 1.00 |  |
| anole@fix | /ws/echo-cb c=4096, 16 in flight | 37,806,048 | 2,519,899 | 25.80 | 28.20 | 31.50 | 0.0 | 103 | 1.00 |  |
| anole@fix | /ws/echo-cb c=16384, 16 in flight | 33,160,016 | 2,210,520 | 113.20 | 118.70 | 130.00 | 0.0 | 368 | 1.00 |  |
| anole@main2 | /ws/echo c=512, 16 in flight | 135,459,392 | 9,030,024 | 0.93 | 1.05 | 1.11 | 0.0 | 20 | 3.99 |  |
| anole@main2 | /ws/echo c=4096, 16 in flight | 104,179,712 | 6,944,851 | 9.59 | 10.00 | 10.30 | 0.0 | 136 | 3.98 |  |
| anole@main2 | /ws/echo c=16384, 16 in flight | 73,195,744 | 4,879,066 | 54.00 | 55.90 | 56.20 | 0.0 | 537 | 3.98 |  |
| anole@fix | /ws/echo c=512, 16 in flight | 130,295,360 | 8,685,778 | 0.92 | 1.12 | 1.15 | 0.0 | 17 | 3.99 |  |
| anole@fix | /ws/echo c=4096, 16 in flight | 104,505,600 | 6,966,576 | 9.37 | 9.86 | 10.10 | 0.0 | 111 | 3.98 |  |
| anole@fix | /ws/echo c=16384, 16 in flight | 72,879,760 | 4,858,003 | 53.60 | 56.50 | 56.90 | 0.0 | 436 | 3.98 |  |
| anole@fix | /ws/echo-cb c=512, 16 in flight | 133,753,168 | 8,916,283 | 0.94 | 1.01 | 1.12 | 0.0 | 16 | 3.99 |  |
| anole@fix | /ws/echo-cb c=4096, 16 in flight | 106,066,704 | 7,070,171 | 9.31 | 9.89 | 10.50 | 0.0 | 103 | 3.98 |  |
| anole@fix | /ws/echo-cb c=16384, 16 in flight | 73,056,816 | 4,869,805 | 52.80 | 61.30 | 62.80 | 0.0 | 402 | 3.98 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 15.0 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 85 MB, kernel 0 -> 63 MB, current 3 -> 149 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 470 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 269 MB, kernel 0 -> 201 MB, current 2 -> 471 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,285 | 0.02 | 0.08 | 0.18 | 0.3 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 127,347 | 1.99 | 2.17 | 2.81 | 3.0 | 0 | 0.00 |  |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 186 | 0.00 | 18.9 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 123 MB, kernel 0 -> 63 MB, current 3 -> 186 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 589 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 388 MB, kernel 0 -> 201 MB, current 3 -> 590 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 50,490 | 0.02 | 0.08 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 91,703 | 2.74 | 3.76 | 5.89 | 6.0 | 0 | 0.00 |  |
| anole@main2 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 290 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 226 MB, kernel 0 -> 64 MB, current 3 -> 290 MB |
| anole@main2 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 923 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 720 MB, kernel 0 -> 203 MB, current 3 -> 924 MB |
| anole@main2 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 49,841 | 0.02 | 0.04 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /ws/echo wake all 32000, 256 at a time | 32,000 | 116,351 | 2.18 | 2.32 | 2.36 | 2.4 | 0 | 0.00 |  |
| anole@main2 | /ws/echo burst n=16000 | 16,000 | 44,641 | 0.00 | 0.00 | 0.00 | 0.0 | 524 | 0.21 | peak 33.4 KB per connection (523 MB over the idle server's 2 MB) while connecting in 0.4 s; 29.4 KB per connection (anon 22.9 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 360 MB, kernel 0 -> 102 MB, current 3 -> 463 MB 30 s later |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 53 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 15 MB, kernel 0 -> 38 MB, current 3 -> 54 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.4 + kernel 3.8, of which sock 0.0; memory.current 5.2); anon 1 -> 44 MB, kernel 0 -> 120 MB, current 3 -> 166 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 51,629 | 0.02 | 0.02 | 0.07 | 0.2 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 134,963 | 1.87 | 2.27 | 2.84 | 3.1 | 0 | 0.00 |  |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 93 | 0.00 | 9.4 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.3); anon 1 -> 55 MB, kernel 0 -> 38 MB, current 3 -> 94 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 279 | 0.00 | 8.9 KB per connection (anon 5.0 + kernel 3.9, of which sock 0.0; memory.current 8.9); anon 1 -> 159 MB, kernel 0 -> 121 MB, current 3 -> 280 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 54,865 | 0.01 | 0.09 | 0.21 | 0.3 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 115,232 | 2.19 | 2.48 | 2.92 | 3.1 | 0 | 0.00 |  |
| anole@fix | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 137 MB, kernel 0 -> 64 MB, current 4 -> 202 MB |
| anole@fix | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 637 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 435 MB, kernel 0 -> 203 MB, current 3 -> 638 MB |
| anole@fix | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 50,565 | 0.02 | 0.04 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo wake all 32000, 256 at a time | 32,000 | 117,348 | 2.14 | 2.63 | 3.07 | 3.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo burst n=16000 | 16,000 | 50,049 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.21 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.3 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.4); anon 1 -> 218 MB, kernel 0 -> 102 MB, current 4 -> 322 MB 30 s later |
| anole@fix | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 58 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 1 -> 20 MB, kernel 0 -> 38 MB, current 3 -> 59 MB |
| anole@fix | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 177 | 0.00 | 5.6 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 1 -> 56 MB, kernel 0 -> 121 MB, current 4 -> 178 MB |
| anole@fix | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 42,321 | 0.02 | 0.04 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 142,986 | 1.77 | 1.93 | 2.03 | 2.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb burst n=16000 | 16,000 | 48,862 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.20 | peak 20.5 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.3 s; 5.9 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 6.0); anon 1 -> 34 MB, kernel 0 -> 61 MB, current 3 -> 96 MB 30 s later |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 149 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 86 MB, kernel 0 -> 63 MB, current 4 -> 150 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 471 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 270 MB, kernel 0 -> 201 MB, current 4 -> 472 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 44,012 | 0.02 | 0.10 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 401,861 | 0.10 | 2.42 | 2.49 | 2.5 | 0 | 0.00 |  |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 188 | 0.00 | 19.0 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 125 MB, kernel 0 -> 63 MB, current 4 -> 189 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 591 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 390 MB, kernel 0 -> 201 MB, current 4 -> 592 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 40,148 | 0.02 | 0.11 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 293,172 | 0.14 | 3.39 | 4.58 | 4.6 | 0 | 0.00 |  |
| anole@main2 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 291 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 227 MB, kernel 0 -> 64 MB, current 5 -> 292 MB |
| anole@main2 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 720 MB, kernel 0 -> 204 MB, current 4 -> 925 MB |
| anole@main2 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 46,037 | 0.02 | 0.11 | 0.21 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /ws/echo wake all 32000, 256 at a time | 32,000 | 340,755 | 0.10 | 2.85 | 3.14 | 3.9 | 0 | 0.00 |  |
| anole@main2 | /ws/echo burst n=16000 | 16,000 | 74,898 | 0.00 | 0.00 | 0.00 | 0.0 | 526 | 0.35 | peak 33.5 KB per connection (523 MB over the idle server's 3 MB) while connecting in 0.2 s; 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 361 MB, kernel 0 -> 102 MB, current 4 -> 465 MB 30 s later |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 56 | 0.00 | 5.4 KB per connection (anon 1.5 + kernel 3.9, of which sock 0.0; memory.current 5.4); anon 2 -> 17 MB, kernel 0 -> 38 MB, current 4 -> 57 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 168 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 2 -> 47 MB, kernel 0 -> 121 MB, current 4 -> 170 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 56,425 | 0.01 | 0.03 | 0.12 | 0.1 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 442,589 | 0.13 | 2.05 | 2.12 | 2.2 | 0 | 0.00 |  |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.6 KB per connection (anon 5.8 + kernel 3.9, of which sock 0.0; memory.current 9.7); anon 2 -> 58 MB, kernel 0 -> 39 MB, current 4 -> 98 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 298 | 0.00 | 9.4 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 2 -> 176 MB, kernel 0 -> 122 MB, current 4 -> 300 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 50,417 | 0.01 | 0.10 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 387,115 | 0.36 | 2.37 | 2.45 | 2.5 | 0 | 0.00 |  |
| anole@fix | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 201 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 137 MB, kernel 0 -> 64 MB, current 5 -> 203 MB |
| anole@fix | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 639 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 436 MB, kernel 0 -> 203 MB, current 5 -> 640 MB |
| anole@fix | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 43,893 | 0.02 | 0.10 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo wake all 32000, 256 at a time | 32,000 | 347,864 | 0.07 | 2.75 | 2.79 | 2.8 | 0 | 0.00 |  |
| anole@fix | /ws/echo burst n=16000 | 16,000 | 76,849 | 0.00 | 0.00 | 0.00 | 0.0 | 384 | 0.35 | peak 24.4 KB per connection (381 MB over the idle server's 3 MB) while connecting in 0.2 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 219 MB, kernel 0 -> 102 MB, current 4 -> 322 MB 30 s later |
| anole@fix | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 60 | 0.00 | 5.9 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 2 -> 21 MB, kernel 0 -> 39 MB, current 4 -> 61 MB |
| anole@fix | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 178 | 0.00 | 5.6 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 57 MB, kernel 0 -> 121 MB, current 5 -> 179 MB |
| anole@fix | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 35,720 | 0.02 | 0.15 | 0.24 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 471,102 | 0.15 | 1.90 | 2.03 | 2.1 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb burst n=16000 | 16,000 | 78,821 | 0.00 | 0.00 | 0.00 | 0.0 | 326 | 0.33 | peak 20.7 KB per connection (323 MB over the idle server's 3 MB) while connecting in 0.2 s; 6.1 KB per connection (anon 2.3 + kernel 3.9, of which sock 0.0; memory.current 6.1); anon 2 -> 38 MB, kernel 0 -> 61 MB, current 4 -> 100 MB 30 s later |

