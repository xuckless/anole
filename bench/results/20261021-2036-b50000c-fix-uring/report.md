# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "b50000c42ead00a20c3e6087816af22884791972",
  "date": "2026-10-21T20:36:22Z",
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
| anole@fix | **269,149** p99 1.02 ms [7 MB, 1.00] | **205,497** p99 1.32 ms [16 MB, 1.00] | **744,715** mean 0.82 ms [16 MB, 1.00] |
| anole@main2 | **269,569** p99 1.03 ms [8 MB, 1.00] | **224,448** p99 1.24 ms [17 MB, 1.00] | **717,932** mean 0.86 ms [20 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **257,208** p99 1.05 ms [7 MB, 1.00] | **209,837** p99 1.29 ms [15 MB, 1.00] | **710,456** mean 0.87 ms [14 MB, 1.00] |
| anole@main2 | **266,367** p99 1.02 ms [8 MB, 1.00] | **217,183** p99 1.29 ms [16 MB, 1.00] | **703,688** mean 0.90 ms [22 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **671,430** p99 0.50 ms [8 MB, 4.00] | **587,527** p99 0.54 ms [15 MB, 3.99] | **2,105,259** mean 0.27 ms [18 MB, 3.99] |
| anole@main2 | **683,531** p99 0.45 ms [9 MB, 4.00] | **591,534** p99 0.51 ms [16 MB, 3.99] | **2,098,402** mean 0.28 ms [23 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@fix | **665,459** p99 0.57 ms [8 MB, 4.00] | **579,135** p99 0.53 ms [15 MB, 3.99] | **2,036,792** mean 0.29 ms [20 MB, 3.99] |
| anole@main2 | **677,818** p99 0.42 ms [9 MB, 4.00] | **584,106** p99 0.56 ms [17 MB, 3.99] | **2,041,514** mean 0.29 ms [24 MB, 3.99] |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@main2 | /ws/echo c=512, 16 in flight | 55,839,920 | 3,722,413 | 2.19 | 2.39 | 2.63 | 0.0 | 18 | 1.00 |  |
| anole@main2 | /ws/echo c=4096, 16 in flight | 38,284,976 | 2,552,162 | 25.40 | 27.80 | 30.30 | 0.0 | 134 | 1.00 |  |
| anole@main2 | /ws/echo c=16384, 16 in flight | 32,219,008 | 2,147,791 | 115.90 | 121.30 | 123.70 | 0.0 | 531 | 1.00 |  |
| anole@fix | /ws/echo c=512, 16 in flight | 54,701,328 | 3,646,269 | 2.23 | 2.48 | 2.69 | 0.0 | 15 | 1.00 |  |
| anole@fix | /ws/echo c=4096, 16 in flight | 38,028,144 | 2,534,872 | 25.60 | 27.60 | 29.00 | 0.0 | 108 | 1.00 |  |
| anole@fix | /ws/echo c=16384, 16 in flight | 32,501,312 | 2,166,465 | 116.40 | 120.40 | 121.80 | 0.0 | 429 | 1.00 |  |
| anole@fix | /ws/echo-cb c=512, 16 in flight | 57,026,368 | 3,801,251 | 2.14 | 2.39 | 2.61 | 0.0 | 14 | 1.00 |  |
| anole@fix | /ws/echo-cb c=4096, 16 in flight | 39,258,496 | 2,617,059 | 24.80 | 26.70 | 30.00 | 0.0 | 103 | 1.00 |  |
| anole@fix | /ws/echo-cb c=16384, 16 in flight | 33,625,632 | 2,241,410 | 111.20 | 117.00 | 118.40 | 0.0 | 369 | 1.00 |  |
| anole@main2 | /ws/echo c=512, 16 in flight | 150,389,712 | 10,025,312 | 0.84 | 0.93 | 0.98 | 0.0 | 19 | 3.99 |  |
| anole@main2 | /ws/echo c=4096, 16 in flight | 112,453,936 | 7,495,930 | 8.69 | 9.34 | 9.59 | 0.0 | 136 | 3.98 |  |
| anole@main2 | /ws/echo c=16384, 16 in flight | 79,871,776 | 5,324,430 | 53.40 | 56.60 | 57.10 | 0.0 | 536 | 3.98 |  |
| anole@fix | /ws/echo c=512, 16 in flight | 144,043,040 | 9,602,229 | 0.84 | 1.05 | 1.14 | 0.0 | 17 | 3.99 |  |
| anole@fix | /ws/echo c=4096, 16 in flight | 110,502,288 | 7,366,328 | 8.86 | 9.59 | 10.20 | 0.0 | 112 | 3.98 |  |
| anole@fix | /ws/echo c=16384, 16 in flight | 76,111,200 | 5,073,742 | 51.70 | 53.90 | 54.40 | 0.0 | 435 | 3.98 |  |
| anole@fix | /ws/echo-cb c=512, 16 in flight | 151,957,888 | 10,129,851 | 0.80 | 1.00 | 1.03 | 0.0 | 16 | 3.99 |  |
| anole@fix | /ws/echo-cb c=4096, 16 in flight | 114,181,024 | 7,611,053 | 8.70 | 9.09 | 9.74 | 0.0 | 104 | 3.98 |  |
| anole@fix | /ws/echo-cb c=16384, 16 in flight | 79,158,416 | 5,276,876 | 51.20 | 54.10 | 58.50 | 0.0 | 405 | 3.98 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 147 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 83 MB, kernel 0 -> 63 MB, current 2 -> 148 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 466 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 265 MB, kernel 0 -> 201 MB, current 2 -> 468 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 52,576 | 0.02 | 0.07 | 0.15 | 0.3 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 149,447 | 1.67 | 1.95 | 1.97 | 2.0 | 0 | 0.00 |  |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 185 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 122 MB, kernel 0 -> 63 MB, current 3 -> 186 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 586 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 384 MB, kernel 0 -> 202 MB, current 3 -> 587 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,576 | 0.02 | 0.03 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 128,138 | 1.96 | 2.24 | 3.89 | 4.0 | 0 | 0.00 |  |
| anole@main2 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 288 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 224 MB, kernel 0 -> 64 MB, current 2 -> 288 MB |
| anole@main2 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 918 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 714 MB, kernel 0 -> 204 MB, current 3 -> 919 MB |
| anole@main2 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 49,567 | 0.02 | 0.08 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /ws/echo wake all 32000, 256 at a time | 32,000 | 125,195 | 2.02 | 2.18 | 2.24 | 2.4 | 0 | 0.00 |  |
| anole@main2 | /ws/echo burst n=16000 | 16,000 | 48,242 | 0.00 | 0.00 | 0.00 | 0.0 | 522 | 0.21 | peak 33.3 KB per connection (521 MB over the idle server's 1 MB) while connecting in 0.3 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 357 MB, kernel 0 -> 102 MB, current 3 -> 461 MB 30 s later |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 52 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 1 -> 14 MB, kernel 0 -> 38 MB, current 2 -> 54 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 162 | 0.00 | 5.1 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 40 MB, kernel 0 -> 121 MB, current 3 -> 163 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 60,687 | 0.01 | 0.03 | 0.22 | 0.3 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 159,074 | 1.59 | 1.75 | 2.15 | 2.2 | 0 | 0.00 |  |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 94 | 0.00 | 9.5 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 1 -> 55 MB, kernel 0 -> 39 MB, current 3 -> 95 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 279 | 0.00 | 8.9 KB per connection (anon 5.0 + kernel 3.9, of which sock 0.0; memory.current 8.9); anon 1 -> 157 MB, kernel 0 -> 122 MB, current 3 -> 281 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,048 | 0.02 | 0.03 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 133,565 | 1.88 | 2.14 | 2.38 | 2.5 | 0 | 0.00 |  |
| anole@fix | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 199 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 135 MB, kernel 0 -> 64 MB, current 3 -> 200 MB |
| anole@fix | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 634 | 0.00 | 20.2 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 431 MB, kernel 0 -> 204 MB, current 3 -> 635 MB |
| anole@fix | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 40,258 | 0.02 | 0.08 | 0.20 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo wake all 32000, 256 at a time | 32,000 | 128,746 | 1.97 | 2.12 | 2.16 | 2.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo burst n=16000 | 16,000 | 49,116 | 0.00 | 0.00 | 0.00 | 0.0 | 381 | 0.19 | peak 24.3 KB per connection (380 MB over the idle server's 1 MB) while connecting in 0.3 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 216 MB, kernel 0 -> 102 MB, current 3 -> 319 MB 30 s later |
| anole@fix | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 58 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 1 -> 19 MB, kernel 0 -> 39 MB, current 3 -> 59 MB |
| anole@fix | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 174 | 0.00 | 5.5 KB per connection (anon 1.6 + kernel 3.9, of which sock 0.0; memory.current 5.5); anon 1 -> 52 MB, kernel 0 -> 122 MB, current 3 -> 175 MB |
| anole@fix | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 51,268 | 0.01 | 0.03 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 164,145 | 1.53 | 1.73 | 1.80 | 1.8 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb burst n=16000 | 16,000 | 54,760 | 0.00 | 0.00 | 0.00 | 0.0 | 321 | 0.18 | peak 20.5 KB per connection (320 MB over the idle server's 1 MB) while connecting in 0.3 s; 5.9 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 1 -> 32 MB, kernel 0 -> 61 MB, current 2 -> 94 MB 30 s later |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 14.9 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 14.8); anon 2 -> 85 MB, kernel 1 -> 63 MB, current 4 -> 149 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 468 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 266 MB, kernel 1 -> 202 MB, current 5 -> 469 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 55,262 | 0.01 | 0.10 | 0.23 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 469,090 | 0.17 | 2.08 | 2.21 | 2.3 | 0 | 0.00 |  |
| anole@main2 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 187 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 124 MB, kernel 1 -> 64 MB, current 4 -> 188 MB |
| anole@main2 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 588 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 2 -> 386 MB, kernel 1 -> 202 MB, current 4 -> 589 MB |
| anole@main2 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 55,153 | 0.01 | 0.09 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@main2 | /plaintext wake all 32000, 256 at a time | 32,000 | 367,369 | 0.12 | 2.63 | 2.77 | 2.8 | 0 | 0.00 |  |
| anole@main2 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 225 MB, kernel 1 -> 64 MB, current 3 -> 289 MB |
| anole@main2 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 919 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 715 MB, kernel 1 -> 204 MB, current 2 -> 920 MB |
| anole@main2 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 30,681 | 0.03 | 0.10 | 0.18 | 0.3 | 0 | 0.00 |  |
| anole@main2 | /ws/echo wake all 32000, 256 at a time | 32,000 | 354,878 | 0.29 | 3.03 | 3.97 | 4.2 | 0 | 0.00 |  |
| anole@main2 | /ws/echo burst n=16000 | 16,000 | 69,585 | 0.00 | 0.00 | 0.00 | 0.0 | 523 | 0.42 | peak 33.3 KB per connection (521 MB over the idle server's 2 MB) while connecting in 0.2 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 358 MB, kernel 1 -> 102 MB, current 3 -> 461 MB 30 s later |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 55 | 0.00 | 5.4 KB per connection (anon 1.5 + kernel 3.9, of which sock 0.0; memory.current 5.4); anon 2 -> 16 MB, kernel 1 -> 39 MB, current 4 -> 57 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 2 -> 43 MB, kernel 1 -> 122 MB, current 2 -> 166 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 60,835 | 0.01 | 0.10 | 0.18 | 0.2 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 497,219 | 0.15 | 1.80 | 1.86 | 1.9 | 0 | 0.00 |  |
| anole@fix | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 98 | 0.00 | 9.8 KB per connection (anon 5.8 + kernel 4.0, of which sock 0.0; memory.current 9.8); anon 2 -> 59 MB, kernel 1 -> 39 MB, current 4 -> 99 MB |
| anole@fix | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 299 | 0.00 | 9.5 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 2 -> 175 MB, kernel 1 -> 124 MB, current 4 -> 301 MB |
| anole@fix | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,373 | 0.02 | 0.08 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@fix | /plaintext wake all 32000, 256 at a time | 32,000 | 416,682 | 0.14 | 2.27 | 2.36 | 2.5 | 0 | 0.00 |  |
| anole@fix | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 136 MB, kernel 1 -> 64 MB, current 4 -> 201 MB |
| anole@fix | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 635 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 431 MB, kernel 1 -> 204 MB, current 4 -> 636 MB |
| anole@fix | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 49,244 | 0.02 | 0.08 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo wake all 32000, 256 at a time | 32,000 | 427,576 | 0.39 | 1.96 | 2.04 | 2.2 | 0 | 0.00 |  |
| anole@fix | /ws/echo burst n=16000 | 16,000 | 81,145 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.33 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.2 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 217 MB, kernel 1 -> 102 MB, current 4 -> 320 MB 30 s later |
| anole@fix | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 59 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 2 -> 20 MB, kernel 1 -> 39 MB, current 5 -> 60 MB |
| anole@fix | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 177 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 54 MB, kernel 1 -> 122 MB, current 4 -> 178 MB |
| anole@fix | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 42,979 | 0.02 | 0.11 | 0.22 | 0.3 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 540,946 | 0.34 | 1.22 | 1.31 | 1.4 | 0 | 0.00 |  |
| anole@fix | /ws/echo-cb burst n=16000 | 16,000 | 78,918 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.30 | peak 20.5 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.2 s; 6.0 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 2 -> 34 MB, kernel 1 -> 61 MB, current 4 -> 97 MB 30 s later |

