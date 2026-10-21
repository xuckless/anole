# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "dfe32fc0aa9cbba1123fdd6251fcf0ed28b04ba6",
  "date": "2026-10-21T08:46:15Z",
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
| bun | **217,555** p99 1.31 ms [14 MB, 1.00] | **194,432** p99 1.46 ms [16 MB, 1.00] | **541,293** mean 1.18 ms [17 MB, 1.00] |
| anole@a | **268,843** p99 1.01 ms [8 MB, 1.00] | **223,094** p99 1.26 ms [17 MB, 1.00] | **734,602** mean 0.84 ms [21 MB, 1.00] |
| anole@b | **266,849** p99 1.01 ms [8 MB, 1.00] | **208,428** p99 1.29 ms [17 MB, 1.00] | **742,052** mean 0.83 ms [21 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **220,057** p99 1.30 ms [14 MB, 1.00] | **190,659** p99 1.51 ms [16 MB, 1.00] | **557,745** mean 1.14 ms [17 MB, 1.00] |
| anole@a | **270,032** p99 0.99 ms [8 MB, 1.00] | **200,859** p99 1.36 ms [16 MB, 1.00] | **699,921** mean 0.90 ms [21 MB, 1.00] |
| anole@b | **262,400** p99 1.03 ms [8 MB, 1.00] | **205,914** p99 1.33 ms [16 MB, 1.00] | **715,223** mean 0.85 ms [19 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **553,617** p99 0.85 ms [59 MB, 3.99] | **462,231** p99 1.06 ms [61 MB, 3.99] | **1,468,327** mean 0.43 ms [72 MB, 3.99] |
| anole@a | **684,308** p99 0.53 ms [9 MB, 4.00] | **583,511** p99 0.69 ms [16 MB, 3.99] | **1,992,506** mean 0.30 ms [23 MB, 3.99] |
| anole@b | **662,892** p99 0.45 ms [10 MB, 3.99] | **576,111** p99 0.53 ms [16 MB, 3.99] | **2,025,452** mean 0.29 ms [23 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2-tls |
| --- | ---: | ---: | ---: |
| bun | **557,430** p99 0.87 ms [57 MB, 4.00] | **486,122** p99 1.06 ms [60 MB, 3.99] | **1,508,543** mean 0.41 ms [70 MB, 3.98] |
| anole@a | **671,721** p99 0.48 ms [9 MB, 4.00] | **572,518** p99 0.54 ms [17 MB, 3.99] | **1,949,763** mean 0.30 ms [24 MB, 3.99] |
| anole@b | **660,128** p99 0.47 ms [10 MB, 4.00] | **574,448** p99 0.55 ms [17 MB, 3.99] | **1,966,635** mean 0.30 ms [21 MB, 4.00] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=64 | c=256 | c=1024 | c=4096 | c=10000 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole@a | 272,584 / 0.3 / 3 | 245,723 / 1.1 / 8 | 224,942 / 5.5 / 29 | 159,996 / 27.2 / 106 | 122,178 / 464.9 / 251 |
| anole@b | 283,587 / 0.3 / 3 | 253,054 / 1.2 / 8 | 214,530 / 6.9 / 29 | 154,378 / 28.9 / 107 | 122,690 / 462.9 / 258 |

## WebSocket echo, 16 in flight (HttpArena echo-ws-pipeline)

gcannon (HttpArena's load generator) in WebSocket mode: each connection keeps 16 five-byte text messages ("hello") in flight on /ws/echo; 512, 4,096 and 16,384 connections. Rate is echoed frames/s; latency is per frame.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| bun | /ws/echo c=512, 16 in flight | 45,819,040 | 3,054,195 | 2.68 | 2.92 | 3.13 | 0.0 | 30 | 1.00 |  |
| bun | /ws/echo c=4096, 16 in flight | 36,549,232 | 2,436,291 | 26.80 | 29.20 | 31.20 | 0.0 | 46 | 1.00 |  |
| bun | /ws/echo c=16384, 16 in flight | 34,637,168 | 2,308,837 | 80.40 | 89.10 | 94.50 | 0.0 | 83 | 1.00 |  |
| bun | /ws/echo c=512, 16 in flight | 124,027,424 | 8,267,944 | 0.97 | 1.31 | 2.36 | 0.0 | 108 | 3.97 |  |
| bun | /ws/echo c=4096, 16 in flight | 108,627,040 | 7,240,837 | 9.06 | 10.40 | 12.20 | 0.0 | 118 | 3.98 |  |
| bun | /ws/echo c=16384, 16 in flight | 98,983,776 | 6,598,039 | 38.80 | 54.80 | 60.50 | 0.0 | 191 | 3.97 |  |
| anole@a | /ws/echo c=512, 16 in flight | 52,309,152 | 3,486,812 | 2.34 | 2.55 | 2.66 | 0.0 | 18 | 1.00 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 35,516,384 | 2,367,601 | 27.50 | 29.80 | 43.60 | 0.0 | 134 | 1.00 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 31,746,448 | 2,116,148 | 117.50 | 129.40 | 132.30 | 0.0 | 531 | 1.00 |  |
| anole@b | /ws/echo c=512, 16 in flight | 47,048,160 | 3,136,126 | 2.61 | 2.94 | 3.19 | 0.0 | 18 | 1.00 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 31,197,296 | 2,079,681 | 31.30 | 33.40 | 36.40 | 0.0 | 137 | 1.00 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 29,258,624 | 1,950,315 | 127.40 | 132.50 | 145.30 | 0.0 | 544 | 1.00 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 47,473,456 | 3,164,475 | 2.58 | 2.83 | 3.14 | 0.0 | 315 | 1.00 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 28,248,624 | 1,882,991 | 34.50 | 37.20 | 39.30 | 0.0 | 227 | 1.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 18,088,784 | 1,205,839 | 154.90 | 182.00 | 183.20 | 0.0 | 1311 | 1.00 |  |
| anole@a | /ws/echo c=512, 16 in flight | 149,440,064 | 9,962,007 | 0.88 | 1.02 | 1.25 | 0.0 | 19 | 3.99 |  |
| anole@a | /ws/echo c=4096, 16 in flight | 111,137,088 | 7,408,645 | 8.72 | 9.82 | 10.70 | 0.0 | 136 | 3.98 |  |
| anole@a | /ws/echo c=16384, 16 in flight | 74,925,200 | 4,994,680 | 52.30 | 59.30 | 63.40 | 0.0 | 535 | 3.98 |  |
| anole@b | /ws/echo c=512, 16 in flight | 133,093,392 | 8,872,301 | 0.90 | 1.29 | 1.45 | 0.0 | 20 | 3.99 |  |
| anole@b | /ws/echo c=4096, 16 in flight | 104,282,560 | 6,951,707 | 9.39 | 10.70 | 11.60 | 0.0 | 139 | 3.97 |  |
| anole@b | /ws/echo c=16384, 16 in flight | 71,219,936 | 4,747,679 | 55.10 | 60.50 | 61.20 | 0.0 | 548 | 3.98 |  |
| anole@b | /ws/echo-cb c=512, 16 in flight | 137,587,984 | 9,171,921 | 0.91 | 1.01 | 1.27 | 0.0 | 320 | 3.99 |  |
| anole@b | /ws/echo-cb c=4096, 16 in flight | 98,247,904 | 6,548,987 | 10.00 | 10.70 | 12.20 | 0.0 | 176 | 4.00 |  |
| anole@b | /ws/echo-cb c=16384, 16 in flight | 64,638,192 | 4,308,638 | 59.10 | 66.00 | 67.80 | 0.0 | 774 | 4.00 |  |

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 147 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 83 MB, kernel 0 -> 63 MB, current 4 -> 150 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 466 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 265 MB, kernel 0 -> 201 MB, current 2 -> 467 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 60,566 | 0.01 | 0.04 | 0.11 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 133,875 | 1.87 | 2.17 | 2.29 | 2.9 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 185 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 122 MB, kernel 0 -> 63 MB, current 2 -> 185 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 586 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 384 MB, kernel 0 -> 202 MB, current 2 -> 586 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 46,522 | 0.02 | 0.04 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 126,477 | 1.99 | 2.27 | 2.40 | 2.5 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 288 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 224 MB, kernel 0 -> 64 MB, current 2 -> 288 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 918 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 714 MB, kernel 0 -> 204 MB, current 2 -> 919 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 33,187 | 0.02 | 0.09 | 0.18 | 0.2 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 118,310 | 2.13 | 2.42 | 2.50 | 2.6 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 43,815 | 0.00 | 0.00 | 0.00 | 0.0 | 522 | 0.22 | peak 33.3 KB per connection (521 MB over the idle server's 1 MB) while connecting in 0.4 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 357 MB, kernel 0 -> 102 MB, current 2 -> 461 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 52 | 0.00 | 5.1 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 1 -> 13 MB, kernel 0 -> 38 MB, current 5 -> 56 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 160 | 0.00 | 5.1 KB per connection (anon 1.2 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 39 MB, kernel 0 -> 121 MB, current 2 -> 161 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 44,266 | 0.02 | 0.05 | 0.20 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 91,374 | 2.78 | 3.22 | 3.40 | 3.5 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 93 | 0.00 | 9.4 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 1 -> 55 MB, kernel 0 -> 39 MB, current 2 -> 94 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 278 | 0.00 | 8.9 KB per connection (anon 5.0 + kernel 3.9, of which sock 0.0; memory.current 8.8); anon 1 -> 156 MB, kernel 0 -> 122 MB, current 3 -> 279 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 34,601 | 0.03 | 0.07 | 0.12 | 0.4 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 82,066 | 3.08 | 3.72 | 4.30 | 4.4 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 335 | 0.00 | 34.2 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 1 -> 271 MB, kernel 0 -> 64 MB, current 2 -> 336 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1069 | 0.00 | 34.2 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.1); anon 1 -> 864 MB, kernel 0 -> 204 MB, current 3 -> 1069 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 42,995 | 0.02 | 0.06 | 0.23 | 0.5 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 139,610 | 1.81 | 2.01 | 2.11 | 2.2 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 45,435 | 0.00 | 0.00 | 0.00 | 0.0 | 535 | 0.21 | peak 34.2 KB per connection (534 MB over the idle server's 1 MB) while connecting in 0.4 s; 34.2 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.2); anon 1 -> 433 MB, kernel 0 -> 102 MB, current 3 -> 537 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 64 | 0.00 | 6.5 KB per connection (anon 2.5 + kernel 4.0, of which sock 0.0; memory.current 6.5); anon 1 -> 25 MB, kernel 0 -> 39 MB, current 2 -> 66 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 182 | 0.00 | 5.8 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 1 -> 59 MB, kernel 0 -> 123 MB, current 3 -> 183 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 38,879 | 0.02 | 0.05 | 0.08 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 95,146 | 2.60 | 3.01 | 12.24 | 12.3 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 42,478 | 0.00 | 0.00 | 0.00 | 0.0 | 537 | 0.94 | peak 34.3 KB per connection (535 MB over the idle server's 1 MB) while connecting in 0.4 s; 9.8 KB per connection (anon 5.9 + kernel 4.0, of which sock 0.0; memory.current 9.8); anon 1 -> 92 MB, kernel 0 -> 62 MB, current 3 -> 156 MB 30 s later |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 14.9 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 85 MB, kernel 1 -> 63 MB, current 4 -> 149 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 468 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 266 MB, kernel 1 -> 202 MB, current 5 -> 469 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 51,465 | 0.02 | 0.08 | 0.23 | 0.3 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 456,456 | 0.13 | 2.04 | 2.13 | 2.2 | 0 | 0.00 |  |
| anole@a | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 187 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 124 MB, kernel 1 -> 64 MB, current 4 -> 188 MB |
| anole@a | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 588 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 2 -> 386 MB, kernel 1 -> 202 MB, current 4 -> 589 MB |
| anole@a | /plaintext wake 1000 of 32000, one at a time | 1,000 | 41,936 | 0.02 | 0.12 | 0.21 | 0.3 | 0 | 0.00 |  |
| anole@a | /plaintext wake all 32000, 256 at a time | 32,000 | 373,218 | 0.10 | 2.60 | 2.69 | 2.7 | 0 | 0.00 |  |
| anole@a | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.2); anon 2 -> 225 MB, kernel 1 -> 64 MB, current 4 -> 290 MB |
| anole@a | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 919 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 715 MB, kernel 1 -> 204 MB, current 4 -> 920 MB |
| anole@a | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 50,994 | 0.01 | 0.10 | 0.15 | 0.1 | 0 | 0.00 |  |
| anole@a | /ws/echo wake all 32000, 256 at a time | 32,000 | 401,781 | 0.21 | 2.36 | 2.44 | 2.9 | 0 | 0.00 |  |
| anole@a | /ws/echo burst n=16000 | 16,000 | 74,786 | 0.00 | 0.00 | 0.00 | 0.0 | 523 | 0.35 | peak 33.3 KB per connection (521 MB over the idle server's 2 MB) while connecting in 0.2 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 358 MB, kernel 1 -> 102 MB, current 4 -> 461 MB 30 s later |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 55 | 0.00 | 5.4 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 2 -> 16 MB, kernel 1 -> 39 MB, current 4 -> 56 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 163 | 0.00 | 5.1 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 2 -> 41 MB, kernel 1 -> 122 MB, current 4 -> 165 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 38,325 | 0.02 | 0.11 | 0.26 | 0.3 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 256,140 | 0.94 | 2.02 | 2.36 | 2.5 | 0 | 0.00 |  |
| anole@b | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.7 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 2 -> 58 MB, kernel 1 -> 39 MB, current 4 -> 98 MB |
| anole@b | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 294 | 0.00 | 9.3 KB per connection (anon 5.4 + kernel 3.9, of which sock 0.0; memory.current 9.3); anon 2 -> 171 MB, kernel 1 -> 123 MB, current 5 -> 295 MB |
| anole@b | /plaintext wake 1000 of 32000, one at a time | 1,000 | 42,771 | 0.02 | 0.08 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@b | /plaintext wake all 32000, 256 at a time | 32,000 | 231,191 | 1.09 | 2.00 | 2.17 | 2.3 | 0 | 0.00 |  |
| anole@b | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 336 | 0.00 | 34.2 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.1); anon 2 -> 272 MB, kernel 1 -> 64 MB, current 4 -> 337 MB |
| anole@b | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1070 | 0.00 | 34.2 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.1); anon 2 -> 865 MB, kernel 1 -> 204 MB, current 4 -> 1071 MB |
| anole@b | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 43,820 | 0.02 | 0.09 | 0.15 | 0.2 | 0 | 0.00 |  |
| anole@b | /ws/echo wake all 32000, 256 at a time | 32,000 | 465,425 | 0.37 | 2.00 | 2.05 | 2.1 | 0 | 0.00 |  |
| anole@b | /ws/echo burst n=16000 | 16,000 | 78,370 | 0.00 | 0.00 | 0.00 | 0.0 | 536 | 0.35 | peak 34.2 KB per connection (534 MB over the idle server's 2 MB) while connecting in 0.2 s; 34.1 KB per connection (anon 27.6 + kernel 6.5, of which sock 0.0; memory.current 34.1); anon 2 -> 434 MB, kernel 1 -> 103 MB, current 4 -> 537 MB 30 s later |
| anole@b | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 72 | 0.00 | 7.2 KB per connection (anon 3.1 + kernel 4.1, of which sock 0.0; memory.current 7.1); anon 2 -> 32 MB, kernel 1 -> 41 MB, current 4 -> 73 MB |
| anole@b | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 187 | 0.00 | 5.9 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 2 -> 63 MB, kernel 1 -> 124 MB, current 4 -> 188 MB |
| anole@b | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 39,443 | 0.02 | 0.09 | 0.24 | 0.3 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 241,255 | 0.89 | 2.50 | 2.85 | 3.2 | 0 | 0.00 |  |
| anole@b | /ws/echo-cb burst n=16000 | 16,000 | 77,976 | 0.00 | 0.00 | 0.00 | 0.0 | 539 | 1.23 | peak 34.3 KB per connection (536 MB over the idle server's 2 MB) while connecting in 0.2 s; 10.0 KB per connection (anon 6.0 + kernel 4.0, of which sock 0.0; memory.current 9.9); anon 2 -> 96 MB, kernel 1 -> 63 MB, current 4 -> 159 MB 30 s later |

