# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "dfe32fc0aa9cbba1123fdd6251fcf0ed28b04ba6",
  "date": "2026-10-21T07:56:46Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@a": "ef0d75a3a5d3", "anole@b": "47b502b9a710", "bun": "deaed1e11216", "loadgen": "45b85a4f7588"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **217,131** p99 1.29 ms [14 MB, 1.00] | **195,424** p99 1.43 ms [16 MB, 1.00] | **542,579** mean 1.18 ms [17 MB, 1.00] |
| anole@a | **234,457** p99 1.21 ms [9 MB, 1.00] | **208,540** p99 1.24 ms [16 MB, 1.00] | **684,085** mean 0.93 ms [22 MB, 1.00] |
| anole@b | **246,163** p99 1.05 ms [9 MB, 1.00] | **209,582** p99 1.27 ms [17 MB, 1.00] | **686,588** mean 0.93 ms [21 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **217,062** p99 1.29 ms [14 MB, 1.00] | **194,912** p99 1.44 ms [16 MB, 1.00] | **557,096** mean 1.14 ms [17 MB, 1.00] |
| anole@a | **242,058** p99 1.07 ms [9 MB, 1.00] | **205,020** p99 1.27 ms [17 MB, 1.00] | **664,203** mean 0.96 ms [23 MB, 1.00] |
| anole@b | **241,906** p99 1.07 ms [8 MB, 1.00] | **194,449** p99 1.37 ms [17 MB, 1.00] | **666,838** mean 0.95 ms [19 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **546,206** p99 0.85 ms [58 MB, 4.00] | **465,168** p99 1.14 ms [61 MB, 3.99] | **1,491,890** mean 0.42 ms [72 MB, 3.99] |
| anole@a | **638,106** p99 0.54 ms [10 MB, 4.00] | **510,845** p99 0.59 ms [16 MB, 3.99] | **1,919,777** mean 0.32 ms [23 MB, 3.99] |
| anole@b | **606,264** p99 0.53 ms [10 MB, 4.00] | **517,883** p99 0.62 ms [17 MB, 3.99] | **1,871,097** mean 0.33 ms [24 MB, 4.00] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **550,351** p99 0.90 ms [57 MB, 4.00] | **470,121** p99 1.08 ms [60 MB, 3.99] | **1,534,581** mean 0.40 ms [70 MB, 3.99] |
| anole@a | **600,468** p99 0.53 ms [9 MB, 3.99] | **509,438** p99 0.56 ms [17 MB, 3.99] | **1,882,297** mean 0.32 ms [23 MB, 3.99] |
| anole@b | **600,028** p99 0.49 ms [10 MB, 4.00] | **513,224** p99 0.61 ms [17 MB, 3.99] | **1,841,733** mean 0.33 ms [24 MB, 3.99] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@a | 255,704 / 0.3 / 3 | 232,337 / 1.2 / 8 | 220,949 / 5.2 / 29 | 156,612 / 28.6 / 109 | 121,971 / 474.2 / 255 |
| anole@b | 266,427 / 0.3 / 3 | 241,844 / 1.1 / 8 | 222,232 / 5.1 / 29 | 155,181 / 28.6 / 113 | 121,268 / 524.5 / 263 |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| bun | /ws/echo c=512, 16 in flight | 47,987,840 | 3,198,550 | 2.54 | 2.79 | 2.89 | 0.0 | 30 | 1.00 |  |
| bun | /ws/echo c=4096, 16 in flight | 39,534,640 | 2,635,116 | 24.60 | 27.10 | 28.30 | 0.0 | 46 | 1.00 |  |
| bun | /ws/echo c=16384, 16 in flight | 37,921,808 | 2,527,783 | 52.70 | 60.80 | 62.30 | 0.0 | 66 | 1.00 |  |
| bun | /ws/echo c=512, 16 in flight | 123,029,456 | 8,201,417 | 1.00 | 1.22 | 2.00 | 0.0 | 85 | 3.99 |  |
| bun | /ws/echo c=4096, 16 in flight | 112,263,312 | 7,483,223 | 8.67 | 10.60 | 16.30 | 0.0 | 119 | 3.97 |  |
| bun | /ws/echo c=16384, 16 in flight | 105,936,144 | 7,061,468 | 36.70 | 40.70 | 41.70 | 0.0 | 193 | 3.98 |  |
| anole@a | /ws/echo c=512, 16 in flight | 52,152,544 | 3,476,373 | 2.32 | 2.60 | 2.67 | 0.0 | 18 | 1.00 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 35,902,256 | 2,393,165 | 27.00 | 29.60 | 33.30 | 0.0 | 134 | 1.00 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 32,077,952 | 2,138,245 | 117.00 | 127.80 | 135.80 | 0.0 | 531 | 1.00 |  |
| anole@b | /ws/echo c=512, 16 in flight | 48,561,744 | 3,237,018 | 2.50 | 2.77 | 3.04 | 0.0 | 19 | 1.00 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 34,296,752 | 2,286,145 | 28.30 | 30.60 | 33.20 | 0.0 | 138 | 1.00 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 30,217,360 | 2,014,222 | 123.20 | 133.60 | 135.40 | 0.0 | 544 | 1.00 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 48,768,864 | 3,250,607 | 2.48 | 2.78 | 3.15 | 0.0 | 315 | 1.00 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 27,135,952 | 1,808,822 | 35.70 | 38.30 | 40.30 | 0.0 | 258 | 1.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 20,585,104 | 1,372,157 | 154.30 | 171.50 | 173.60 | 0.0 | 1098 | 1.00 |  |
| anole@a | /ws/echo c=512, 16 in flight | 127,832,128 | 8,521,574 | 0.89 | 1.32 | 1.35 | 0.0 | 20 | 3.99 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 102,966,112 | 6,863,492 | 9.71 | 10.40 | 10.90 | 0.0 | 137 | 3.98 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 70,262,816 | 4,683,875 | 54.80 | 61.90 | 64.20 | 0.0 | 538 | 3.98 |  |
| anole@b | /ws/echo c=512, 16 in flight | 118,844,704 | 7,922,452 | 1.02 | 1.19 | 1.21 | 0.0 | 20 | 3.99 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 97,791,840 | 6,518,587 | 10.00 | 10.50 | 11.00 | 0.0 | 140 | 3.98 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 66,552,432 | 4,436,533 | 57.20 | 64.20 | 66.60 | 0.0 | 551 | 3.98 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 113,414,256 | 7,560,446 | 1.08 | 1.71 | 1.79 | 0.0 | 329 | 3.99 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 91,115,664 | 6,073,568 | 10.70 | 12.60 | 15.80 | 0.0 | 178 | 4.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 66,822,576 | 4,454,541 | 58.70 | 60.80 | 62.50 | 0.0 | 771 | 4.00 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 15.0 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 85 MB, kernel 0 -> 63 MB, current 3 -> 149 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 470 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 269 MB, kernel 0 -> 201 MB, current 3 -> 471 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 49,540 | 0.02 | 0.06 | 0.16 | 0.3 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 127,309 | 1.98 | 2.22 | 2.94 | 3.2 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 186 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 1 -> 123 MB, kernel 0 -> 63 MB, current 3 -> 187 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 589 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 388 MB, kernel 0 -> 201 MB, current 3 -> 590 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 46,613 | 0.02 | 0.04 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 97,168 | 2.58 | 3.55 | 4.55 | 4.6 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 226 MB, kernel 0 -> 64 MB, current 3 -> 290 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 720 MB, kernel 0 -> 203 MB, current 4 -> 925 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 41,341 | 0.02 | 0.03 | 0.11 | 2.3 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 117,153 | 2.16 | 2.32 | 2.75 | 2.9 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 43,118 | 0.00 | 0.00 | 0.00 | 0.0 | 524 | 0.23 | peak 33.4 KB per connection (522 MB over the idle server's 2 MB) while connecting in 0.4 s; 29.4 KB per connection (anon 22.9 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 360 MB, kernel 0 -> 102 MB, current 2 -> 464 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 53 | 0.00 | 5.2 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 15 MB, kernel 0 -> 38 MB, current 3 -> 53 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 164 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.8, of which sock 0.0; memory.current 5.2); anon 1 -> 43 MB, kernel 0 -> 120 MB, current 3 -> 165 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 39,916 | 0.02 | 0.09 | 0.19 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 89,451 | 2.85 | 3.31 | 3.36 | 3.4 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 94 | 0.00 | 9.5 KB per connection (anon 5.6 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 1 -> 56 MB, kernel 0 -> 38 MB, current 3 -> 95 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 279 | 0.00 | 8.9 KB per connection (anon 5.0 + kernel 3.9, of which sock 0.0; memory.current 8.9); anon 1 -> 158 MB, kernel 0 -> 121 MB, current 3 -> 280 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 38,886 | 0.02 | 0.07 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 81,523 | 3.11 | 4.17 | 5.13 | 5.2 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 336 | 0.00 | 34.2 KB per connection (anon 27.7 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 1 -> 272 MB, kernel 0 -> 64 MB, current 3 -> 337 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1073 | 0.00 | 34.3 KB per connection (anon 27.8 + kernel 6.5, of which sock 0.0; memory.current 34.3); anon 1 -> 869 MB, kernel 0 -> 203 MB, current 3 -> 1074 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 53,348 | 0.02 | 0.03 | 0.14 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 131,501 | 1.92 | 2.27 | 2.68 | 2.7 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 42,052 | 0.00 | 0.00 | 0.00 | 0.0 | 537 | 0.22 | peak 34.3 KB per connection (535 MB over the idle server's 2 MB) while connecting in 0.4 s; 34.3 KB per connection (anon 27.8 + kernel 6.5, of which sock 0.0; memory.current 34.3); anon 1 -> 435 MB, kernel 0 -> 102 MB, current 3 -> 539 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 70 | 0.00 | 7.0 KB per connection (anon 2.9 + kernel 4.1, of which sock 0.0; memory.current 7.0); anon 1 -> 30 MB, kernel 0 -> 40 MB, current 3 -> 71 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 181 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 1 -> 60 MB, kernel 0 -> 122 MB, current 3 -> 183 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 41,880 | 0.02 | 0.08 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 93,697 | 2.67 | 3.27 | 8.70 | 8.7 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 42,144 | 0.00 | 0.00 | 0.00 | 0.0 | 539 | 0.93 | peak 34.4 KB per connection (538 MB over the idle server's 2 MB) while connecting in 0.4 s; 9.9 KB per connection (anon 5.9 + kernel 3.9, of which sock 0.0; memory.current 9.9); anon 1 -> 94 MB, kernel 0 -> 62 MB, current 3 -> 158 MB 30 s later |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 149 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 86 MB, kernel 0 -> 63 MB, current 5 -> 150 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 471 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 270 MB, kernel 0 -> 201 MB, current 5 -> 472 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,632 | 0.02 | 0.10 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 423,978 | 0.44 | 1.93 | 1.97 | 2.0 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 188 | 0.00 | 19.0 KB per connection (anon 12.6 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 125 MB, kernel 0 -> 63 MB, current 4 -> 189 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 591 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 390 MB, kernel 0 -> 201 MB, current 4 -> 593 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 41,622 | 0.02 | 0.10 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 318,341 | 0.35 | 2.98 | 3.08 | 3.1 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 291 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 227 MB, kernel 0 -> 64 MB, current 4 -> 292 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 721 MB, kernel 0 -> 204 MB, current 4 -> 925 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 42,788 | 0.02 | 0.11 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 366,706 | 0.33 | 2.53 | 3.42 | 3.7 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 85,656 | 0.00 | 0.00 | 0.00 | 0.0 | 526 | 0.35 | peak 33.5 KB per connection (523 MB over the idle server's 3 MB) while connecting in 0.2 s; 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 361 MB, kernel 0 -> 102 MB, current 4 -> 464 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 56 | 0.00 | 5.4 KB per connection (anon 1.5 + kernel 3.9, of which sock 0.0; memory.current 5.5); anon 2 -> 17 MB, kernel 0 -> 39 MB, current 4 -> 57 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 168 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 2 -> 46 MB, kernel 0 -> 121 MB, current 4 -> 169 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 45,029 | 0.02 | 0.08 | 0.13 | 0.1 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 244,771 | 0.93 | 2.32 | 2.63 | 3.0 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 96 | 0.00 | 9.6 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 2 -> 58 MB, kernel 0 -> 39 MB, current 4 -> 97 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 292 | 0.00 | 9.3 KB per connection (anon 5.4 + kernel 3.9, of which sock 0.0; memory.current 9.2); anon 2 -> 170 MB, kernel 0 -> 122 MB, current 5 -> 293 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 40,258 | 0.02 | 0.08 | 0.21 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 225,668 | 1.01 | 2.99 | 3.40 | 3.5 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 337 | 0.00 | 34.2 KB per connection (anon 27.7 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 2 -> 273 MB, kernel 0 -> 64 MB, current 5 -> 338 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1074 | 0.00 | 34.3 KB per connection (anon 27.8 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 2 -> 870 MB, kernel 0 -> 204 MB, current 5 -> 1074 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 43,999 | 0.02 | 0.11 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 433,379 | 0.12 | 2.15 | 2.47 | 2.5 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 78,473 | 0.00 | 0.00 | 0.00 | 0.0 | 538 | 0.40 | peak 34.3 KB per connection (535 MB over the idle server's 3 MB) while connecting in 0.2 s; 34.3 KB per connection (anon 27.8 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 2 -> 436 MB, kernel 0 -> 102 MB, current 5 -> 539 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 74 | 0.00 | 7.3 KB per connection (anon 3.2 + kernel 4.1, of which sock 0.0; memory.current 7.2); anon 2 -> 33 MB, kernel 0 -> 41 MB, current 4 -> 74 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 190 | 0.00 | 6.0 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 2 -> 67 MB, kernel 0 -> 123 MB, current 4 -> 190 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 52,103 | 0.01 | 0.05 | 0.13 | 0.1 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 234,934 | 0.79 | 3.31 | 4.46 | 4.9 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 73,967 | 0.00 | 0.00 | 0.00 | 0.0 | 541 | 1.23 | peak 34.4 KB per connection (538 MB over the idle server's 3 MB) while connecting in 0.2 s; 10.0 KB per connection (anon 6.0 + kernel 4.0, of which sock 0.0; memory.current 9.9); anon 2 -> 96 MB, kernel 0 -> 62 MB, current 4 -> 158 MB 30 s later |

