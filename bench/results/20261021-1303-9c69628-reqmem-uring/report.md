# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "9c69628680bd3cb77fd1b9cfaa2d84053477a748",
  "date": "2026-10-21T13:03:41Z",
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
| anole@a | **272,140** p99 0.99 ms [8 MB, 1.00] | **224,467** p99 1.23 ms [16 MB, 1.00] | **733,605** mean 0.85 ms [21 MB, 1.00] |
| anole@b | **265,602** p99 1.02 ms [7 MB, 1.00] | **212,591** p99 1.28 ms [15 MB, 1.00] | **734,346** mean 0.86 ms [15 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **273,394** p99 0.99 ms [8 MB, 1.00] | **212,140** p99 1.31 ms [16 MB, 1.00] | **713,979** mean 0.86 ms [20 MB, 1.00] |
| anole@b | **262,744** p99 1.02 ms [7 MB, 1.00] | **202,216** p99 1.34 ms [15 MB, 1.00] | **697,801** mean 0.88 ms [14 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **688,998** p99 0.44 ms [9 MB, 3.99] | **591,768** p99 0.52 ms [16 MB, 3.99] | **2,088,787** mean 0.28 ms [23 MB, 3.99] |
| anole@b | **673,029** p99 0.44 ms [8 MB, 4.00] | **586,228** p99 0.68 ms [15 MB, 3.99] | **2,073,692** mean 0.28 ms [19 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| anole@a | **670,970** p99 0.47 ms [9 MB, 4.00] | **592,213** p99 0.57 ms [17 MB, 3.99] | **2,028,819** mean 0.29 ms [24 MB, 3.99] |
| anole@b | **667,179** p99 0.53 ms [8 MB, 4.00] | **576,263** p99 0.57 ms [15 MB, 3.99] | **1,996,207** mean 0.29 ms [20 MB, 3.99] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@a | 282,242 / 0.2 / 3 | 250,534 / 1.1 / 9 | 238,695 / 4.9 / 30 | 168,200 / 26.4 / 106 | 123,928 / 441.5 / 246 |
| anole@b | 293,667 / 0.2 / 3 | 264,303 / 1.0 / 7 | 239,164 / 4.8 / 23 | 166,899 / 26.7 / 88 | 123,696 / 461.8 / 211 |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /ws/echo c=512, 16 in flight | 55,380,576 | 3,691,546 | 2.21 | 2.44 | 2.60 | 0.0 | 18 | 1.00 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 38,092,432 | 2,538,988 | 25.60 | 28.10 | 31.90 | 0.0 | 134 | 1.00 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 32,652,432 | 2,176,539 | 115.70 | 120.20 | 127.40 | 0.0 | 532 | 1.00 |  |
| anole@b | /ws/echo c=512, 16 in flight | 55,215,888 | 3,680,323 | 2.21 | 2.43 | 2.60 | 0.0 | 15 | 1.00 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 37,397,232 | 2,492,650 | 26.00 | 28.30 | 31.60 | 0.0 | 110 | 1.00 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 32,853,024 | 2,189,910 | 114.80 | 119.70 | 126.90 | 0.0 | 428 | 1.00 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 56,826,720 | 3,787,943 | 2.15 | 2.40 | 2.87 | 0.0 | 196 | 1.00 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 34,276,352 | 2,284,785 | 28.40 | 30.70 | 31.40 | 0.0 | 145 | 1.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 23,470,768 | 1,564,614 | 139.70 | 148.90 | 149.60 | 0.0 | 679 | 1.00 |  |
| anole@a | /ws/echo c=512, 16 in flight | 160,312,032 | 10,686,756 | 0.78 | 0.95 | 4.59 | 0.0 | 20 | 3.95 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 112,825,008 | 7,521,166 | 8.73 | 9.22 | 9.49 | 0.0 | 137 | 3.98 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 75,776,256 | 5,051,414 | 52.40 | 54.50 | 60.10 | 0.0 | 535 | 3.98 |  |
| anole@b | /ws/echo c=512, 16 in flight | 146,693,568 | 9,778,919 | 0.81 | 1.05 | 1.09 | 0.0 | 17 | 3.99 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 111,226,608 | 7,414,119 | 8.72 | 9.58 | 10.20 | 0.0 | 113 | 3.98 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 75,619,440 | 5,040,624 | 52.20 | 55.20 | 67.60 | 0.0 | 436 | 3.98 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 151,306,272 | 10,086,412 | 0.83 | 0.99 | 1.09 | 0.0 | 214 | 3.99 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 110,467,680 | 7,364,021 | 8.73 | 9.74 | 10.10 | 0.0 | 125 | 4.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 78,853,184 | 5,256,178 | 51.90 | 53.90 | 56.80 | 0.0 | 450 | 4.00 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 147 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 83 MB, kernel 0 -> 63 MB, current 2 -> 149 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 466 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 265 MB, kernel 0 -> 201 MB, current 2 -> 468 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 63,297 | 0.01 | 0.03 | 0.09 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 149,176 | 1.68 | 1.95 | 2.04 | 2.1 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 185 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 1 -> 122 MB, kernel 0 -> 63 MB, current 2 -> 187 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 586 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 384 MB, kernel 0 -> 202 MB, current 3 -> 587 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 49,293 | 0.02 | 0.04 | 0.15 | 0.3 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 113,934 | 2.21 | 2.97 | 3.75 | 3.8 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 288 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 224 MB, kernel 0 -> 64 MB, current 3 -> 289 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 918 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 714 MB, kernel 0 -> 204 MB, current 3 -> 919 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 51,103 | 0.02 | 0.04 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 125,784 | 2.01 | 2.50 | 2.71 | 2.8 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 47,408 | 0.00 | 0.00 | 0.00 | 0.0 | 522 | 0.22 | peak 33.3 KB per connection (521 MB over the idle server's 1 MB) while connecting in 0.3 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 357 MB, kernel 0 -> 102 MB, current 2 -> 461 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 52 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 1 -> 14 MB, kernel 0 -> 38 MB, current 3 -> 53 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 162 | 0.00 | 5.1 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 40 MB, kernel 0 -> 121 MB, current 3 -> 164 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 58,556 | 0.01 | 0.08 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 156,570 | 1.61 | 1.75 | 2.04 | 2.2 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 94 | 0.00 | 9.4 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 1 -> 55 MB, kernel 0 -> 39 MB, current 2 -> 95 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 275 | 0.00 | 8.7 KB per connection (anon 4.9 + kernel 3.9, of which sock 0.0; memory.current 8.7); anon 1 -> 153 MB, kernel 0 -> 122 MB, current 3 -> 275 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 59,705 | 0.01 | 0.04 | 0.11 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 126,661 | 1.99 | 2.20 | 3.07 | 3.2 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 199 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 135 MB, kernel 0 -> 64 MB, current 3 -> 200 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 634 | 0.00 | 20.2 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 430 MB, kernel 0 -> 204 MB, current 3 -> 635 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 46,389 | 0.02 | 0.08 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 125,523 | 2.02 | 2.16 | 2.20 | 2.2 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 51,271 | 0.00 | 0.00 | 0.00 | 0.0 | 381 | 0.19 | peak 24.3 KB per connection (380 MB over the idle server's 1 MB) while connecting in 0.3 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 216 MB, kernel 0 -> 102 MB, current 3 -> 319 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 57 | 0.00 | 5.7 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 1 -> 18 MB, kernel 0 -> 39 MB, current 3 -> 58 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 175 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 1 -> 53 MB, kernel 0 -> 122 MB, current 3 -> 176 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 36,880 | 0.02 | 0.08 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 168,220 | 1.50 | 1.63 | 1.91 | 1.9 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 55,252 | 0.00 | 0.00 | 0.00 | 0.0 | 321 | 0.95 | peak 20.5 KB per connection (320 MB over the idle server's 1 MB) while connecting in 0.3 s; 5.8 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 1 -> 32 MB, kernel 0 -> 61 MB, current 3 -> 94 MB 30 s later |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 14.9 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 85 MB, kernel 1 -> 63 MB, current 3 -> 150 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 468 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 266 MB, kernel 1 -> 202 MB, current 4 -> 468 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 42,559 | 0.02 | 0.10 | 0.23 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 440,992 | 0.10 | 2.19 | 2.25 | 2.3 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 187 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 124 MB, kernel 1 -> 64 MB, current 4 -> 189 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 588 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 2 -> 386 MB, kernel 1 -> 202 MB, current 4 -> 589 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,783 | 0.01 | 0.11 | 0.24 | 0.3 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 364,039 | 0.08 | 2.67 | 3.28 | 3.7 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.2); anon 2 -> 224 MB, kernel 1 -> 64 MB, current 4 -> 290 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 919 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 715 MB, kernel 1 -> 204 MB, current 4 -> 921 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 32,368 | 0.02 | 0.10 | 0.21 | 0.3 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 403,088 | 0.13 | 2.35 | 2.43 | 2.5 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 79,677 | 0.00 | 0.00 | 0.00 | 0.0 | 523 | 0.34 | peak 33.3 KB per connection (521 MB over the idle server's 2 MB) while connecting in 0.2 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 358 MB, kernel 1 -> 103 MB, current 4 -> 462 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 55 | 0.00 | 5.4 KB per connection (anon 1.5 + kernel 3.9, of which sock 0.0; memory.current 5.4); anon 2 -> 16 MB, kernel 1 -> 39 MB, current 4 -> 57 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 2 -> 43 MB, kernel 1 -> 122 MB, current 4 -> 167 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 61,793 | 0.01 | 0.10 | 0.18 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 468,051 | 0.14 | 1.97 | 2.75 | 2.9 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.7 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.6); anon 2 -> 58 MB, kernel 1 -> 39 MB, current 4 -> 98 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 293 | 0.00 | 9.3 KB per connection (anon 5.4 + kernel 3.9, of which sock 0.0; memory.current 9.3); anon 2 -> 170 MB, kernel 1 -> 123 MB, current 4 -> 294 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 37,866 | 0.02 | 0.10 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 416,312 | 0.20 | 2.29 | 2.36 | 2.4 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 136 MB, kernel 1 -> 64 MB, current 4 -> 202 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 635 | 0.00 | 20.2 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 431 MB, kernel 1 -> 204 MB, current 4 -> 636 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 52,265 | 0.02 | 0.04 | 0.18 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 430,599 | 0.48 | 1.29 | 1.37 | 1.6 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 76,341 | 0.00 | 0.00 | 0.00 | 0.0 | 382 | 0.31 | peak 24.3 KB per connection (380 MB over the idle server's 2 MB) while connecting in 0.2 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 217 MB, kernel 1 -> 102 MB, current 5 -> 320 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 60 | 0.00 | 5.9 KB per connection (anon 1.9 + kernel 4.0, of which sock 0.0; memory.current 5.8); anon 2 -> 21 MB, kernel 1 -> 39 MB, current 4 -> 61 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 178 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 55 MB, kernel 1 -> 123 MB, current 5 -> 179 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 36,933 | 0.02 | 0.09 | 0.19 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 531,271 | 0.20 | 1.60 | 1.69 | 1.7 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 75,062 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 1.16 | peak 20.5 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.2 s; 6.0 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 6.0); anon 2 -> 35 MB, kernel 1 -> 62 MB, current 5 -> 98 MB 30 s later |

