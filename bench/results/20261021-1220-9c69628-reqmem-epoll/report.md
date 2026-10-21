# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "9c69628680bd3cb77fd1b9cfaa2d84053477a748",
  "date": "2026-10-21T12:20:25Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@a": "ef0d75a3a5d3", "anole@b": "c6e0bad83571", "loadgen": "45b85a4f7588"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **228,718** p99 1.26 ms [9 MB, 1.00] | **208,026** p99 1.48 ms [17 MB, 1.00] | **683,265** mean 0.93 ms [23 MB, 1.00] |
| anole@b | **246,959** p99 1.09 ms [7 MB, 1.00] | **203,958** p99 1.36 ms [16 MB, 1.00] | **693,173** mean 0.92 ms [18 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **243,263** p99 1.10 ms [8 MB, 1.00] | **201,942** p99 1.36 ms [17 MB, 1.00] | **665,199** mean 0.96 ms [22 MB, 1.00] |
| anole@b | **242,864** p99 1.11 ms [7 MB, 1.00] | **196,569** p99 1.36 ms [16 MB, 1.00] | **657,591** mean 0.97 ms [15 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **608,755** p99 0.51 ms [9 MB, 4.00] | **525,631** p99 0.65 ms [16 MB, 3.99] | **1,951,230** mean 0.32 ms [23 MB, 3.99] |
| anole@b | **605,831** p99 0.48 ms [8 MB, 4.00] | **511,905** p99 0.67 ms [15 MB, 3.99] | **1,923,437** mean 0.32 ms [19 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **606,932** p99 0.47 ms [9 MB, 4.00] | **520,954** p99 0.56 ms [16 MB, 3.99] | **1,913,485** mean 0.32 ms [23 MB, 3.99] |
| anole@b | **606,833** p99 0.48 ms [8 MB, 3.99] | **505,587** p99 0.58 ms [15 MB, 3.99] | **1,871,065** mean 0.33 ms [19 MB, 3.99] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@a | 261,297 / 0.3 / 3 | 239,904 / 1.1 / 8 | 226,827 / 4.9 / 28 | 161,051 / 27.0 / 110 | 123,061 / 492.4 / 251 |
| anole@b | 267,170 / 0.3 / 3 | 243,523 / 1.1 / 7 | 227,629 / 5.0 / 24 | 159,662 / 27.7 / 91 | 121,324 / 364.9 / 216 |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /ws/echo c=512, 16 in flight | 53,192,624 | 3,545,702 | 2.30 | 2.49 | 2.81 | 0.0 | 18 | 1.00 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 36,911,376 | 2,460,266 | 26.40 | 28.70 | 32.30 | 0.0 | 134 | 1.00 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 32,066,032 | 2,137,450 | 116.40 | 120.40 | 121.60 | 0.0 | 532 | 1.00 |  |
| anole@b | /ws/echo c=512, 16 in flight | 52,167,344 | 3,477,591 | 2.35 | 2.51 | 2.84 | 0.0 | 15 | 1.00 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 36,165,072 | 2,410,683 | 27.00 | 28.60 | 32.40 | 0.0 | 109 | 1.00 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 31,966,896 | 2,130,984 | 117.90 | 122.60 | 136.70 | 0.0 | 424 | 1.00 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 54,063,744 | 3,603,769 | 2.26 | 2.47 | 2.87 | 0.0 | 193 | 1.00 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 32,448,576 | 2,162,950 | 30.00 | 31.80 | 32.60 | 0.0 | 150 | 1.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 21,494,720 | 1,432,790 | 146.50 | 159.20 | 160.50 | 0.0 | 705 | 1.00 |  |
| anole@a | /ws/echo c=512, 16 in flight | 137,947,248 | 9,195,870 | 0.85 | 1.22 | 1.24 | 0.0 | 20 | 3.98 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 103,967,488 | 6,930,704 | 9.54 | 9.96 | 11.30 | 0.0 | 137 | 3.98 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 73,163,056 | 4,877,212 | 54.20 | 56.60 | 57.20 | 0.0 | 536 | 3.98 |  |
| anole@b | /ws/echo c=512, 16 in flight | 126,200,560 | 8,412,810 | 0.97 | 1.05 | 1.08 | 0.0 | 17 | 3.99 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 102,345,200 | 6,822,558 | 9.60 | 10.00 | 11.00 | 0.0 | 111 | 3.98 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 71,892,944 | 4,792,224 | 55.00 | 56.00 | 56.40 | 0.0 | 438 | 3.99 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 132,989,664 | 8,865,387 | 0.89 | 1.10 | 1.14 | 0.0 | 216 | 3.99 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 102,169,296 | 6,810,832 | 9.50 | 10.30 | 12.10 | 0.0 | 124 | 4.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 71,325,360 | 4,754,707 | 55.40 | 58.00 | 58.70 | 0.0 | 485 | 4.00 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 15.0 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 15.1); anon 1 -> 85 MB, kernel 0 -> 63 MB, current 3 -> 150 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 470 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 269 MB, kernel 0 -> 201 MB, current 3 -> 471 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 45,360 | 0.02 | 0.03 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 127,728 | 1.97 | 2.27 | 2.95 | 3.2 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 186 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 19.0); anon 1 -> 123 MB, kernel 0 -> 63 MB, current 2 -> 188 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 589 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 388 MB, kernel 0 -> 201 MB, current 3 -> 590 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 53,697 | 0.02 | 0.03 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 97,024 | 2.59 | 3.48 | 5.94 | 6.0 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 226 MB, kernel 0 -> 64 MB, current 3 -> 291 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 720 MB, kernel 0 -> 203 MB, current 3 -> 925 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 50,757 | 0.02 | 0.03 | 0.09 | 0.1 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 117,703 | 2.15 | 2.36 | 2.47 | 2.5 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 42,631 | 0.00 | 0.00 | 0.00 | 0.0 | 524 | 0.21 | peak 33.4 KB per connection (522 MB over the idle server's 2 MB) while connecting in 0.4 s; 29.4 KB per connection (anon 22.9 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 360 MB, kernel 0 -> 102 MB, current 3 -> 464 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 53 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 1 -> 15 MB, kernel 0 -> 38 MB, current 2 -> 54 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.4 + kernel 3.8, of which sock 0.0; memory.current 5.2); anon 1 -> 44 MB, kernel 0 -> 121 MB, current 3 -> 167 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 61,950 | 0.01 | 0.03 | 0.16 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 138,552 | 1.81 | 2.18 | 2.83 | 3.0 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 93 | 0.00 | 9.3 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 1 -> 55 MB, kernel 0 -> 38 MB, current 3 -> 95 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 281 | 0.00 | 8.9 KB per connection (anon 5.1 + kernel 3.9, of which sock 0.0; memory.current 8.9); anon 1 -> 160 MB, kernel 0 -> 121 MB, current 3 -> 282 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 49,401 | 0.02 | 0.04 | 0.16 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 113,795 | 2.23 | 2.44 | 2.68 | 2.9 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 136 MB, kernel 0 -> 64 MB, current 3 -> 201 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 637 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.4); anon 1 -> 435 MB, kernel 0 -> 203 MB, current 2 -> 638 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 50,700 | 0.02 | 0.03 | 0.20 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 119,809 | 2.10 | 2.71 | 2.99 | 3.1 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 48,944 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.20 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.3 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.4); anon 1 -> 218 MB, kernel 0 -> 102 MB, current 3 -> 322 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 58 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 1 -> 20 MB, kernel 0 -> 38 MB, current 3 -> 59 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 176 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 1 -> 55 MB, kernel 0 -> 121 MB, current 3 -> 177 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 34,841 | 0.02 | 0.08 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 143,688 | 1.76 | 2.00 | 2.07 | 2.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 48,313 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.93 | peak 20.5 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.3 s; 5.9 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 1 -> 34 MB, kernel 0 -> 60 MB, current 3 -> 95 MB 30 s later |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 149 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 86 MB, kernel 0 -> 63 MB, current 4 -> 150 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 471 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 270 MB, kernel 0 -> 201 MB, current 4 -> 472 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 61,409 | 0.01 | 0.09 | 0.18 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 407,504 | 0.11 | 2.31 | 2.48 | 2.5 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 188 | 0.00 | 19.0 KB per connection (anon 12.6 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 125 MB, kernel 0 -> 63 MB, current 4 -> 189 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 591 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 390 MB, kernel 0 -> 201 MB, current 4 -> 593 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 44,119 | 0.02 | 0.10 | 0.20 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 321,127 | 0.23 | 2.99 | 3.04 | 3.1 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 291 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 227 MB, kernel 0 -> 64 MB, current 5 -> 292 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 925 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 721 MB, kernel 0 -> 204 MB, current 5 -> 925 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 48,298 | 0.02 | 0.08 | 0.25 | 0.3 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 380,027 | 0.26 | 2.52 | 2.58 | 2.6 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 76,366 | 0.00 | 0.00 | 0.00 | 0.0 | 525 | 0.38 | peak 33.5 KB per connection (523 MB over the idle server's 3 MB) while connecting in 0.2 s; 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 361 MB, kernel 0 -> 102 MB, current 4 -> 464 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 57 | 0.00 | 5.6 KB per connection (anon 1.6 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 18 MB, kernel 0 -> 39 MB, current 4 -> 58 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 168 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 2 -> 47 MB, kernel 0 -> 121 MB, current 5 -> 169 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 52,545 | 0.02 | 0.06 | 0.13 | 0.1 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 456,694 | 0.49 | 1.55 | 1.68 | 1.7 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.6 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.6); anon 2 -> 58 MB, kernel 0 -> 39 MB, current 4 -> 98 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 299 | 0.00 | 9.5 KB per connection (anon 5.6 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 2 -> 177 MB, kernel 0 -> 122 MB, current 5 -> 300 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 52,071 | 0.01 | 0.10 | 0.20 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 384,213 | 0.15 | 2.40 | 2.48 | 2.5 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 201 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.4); anon 2 -> 137 MB, kernel 0 -> 64 MB, current 4 -> 203 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 639 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 436 MB, kernel 0 -> 203 MB, current 4 -> 639 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 37,632 | 0.02 | 0.11 | 0.20 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 380,467 | 0.30 | 2.51 | 3.17 | 4.5 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 82,409 | 0.00 | 0.00 | 0.00 | 0.0 | 385 | 0.34 | peak 24.5 KB per connection (382 MB over the idle server's 3 MB) while connecting in 0.2 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 219 MB, kernel 0 -> 102 MB, current 5 -> 322 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 61 | 0.00 | 6.0 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 6.0); anon 2 -> 22 MB, kernel 0 -> 39 MB, current 4 -> 62 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 180 | 0.00 | 5.7 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 59 MB, kernel 0 -> 122 MB, current 5 -> 182 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 34,812 | 0.02 | 0.10 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 484,543 | 0.37 | 1.72 | 1.82 | 1.9 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 78,104 | 0.00 | 0.00 | 0.00 | 0.0 | 325 | 1.20 | peak 20.6 KB per connection (322 MB over the idle server's 3 MB) while connecting in 0.2 s; 6.1 KB per connection (anon 2.2 + kernel 3.9, of which sock 0.0; memory.current 6.1); anon 2 -> 37 MB, kernel 0 -> 61 MB, current 5 -> 100 MB 30 s later |

