# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "105b66af2a72fd24e9dad31a9aad39abe7869c40",
  "date": "2026-10-21T23:59:49Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@a5": "fd2bb943f847", "loadgen": "75b50004f33c"}
}

```

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 15.0 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 85 MB, kernel 0 -> 63 MB, current 3 -> 150 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 470 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 269 MB, kernel 0 -> 201 MB, current 3 -> 471 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 68,971 | 0.01 | 0.02 | 0.09 | 0.1 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 128,259 | 1.97 | 2.20 | 2.94 | 3.2 | 0 | 0.00 |  |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 186 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 123 MB, kernel 0 -> 63 MB, current 3 -> 187 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 589 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 388 MB, kernel 0 -> 201 MB, current 3 -> 590 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 44,389 | 0.02 | 0.06 | 0.17 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 96,655 | 2.61 | 3.48 | 5.15 | 5.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 290 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.6); anon 1 -> 226 MB, kernel 0 -> 64 MB, current 3 -> 291 MB |
| anole@a5 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 922 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 719 MB, kernel 0 -> 203 MB, current 3 -> 923 MB |
| anole@a5 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 48,279 | 0.02 | 0.07 | 0.17 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /ws/echo wake all 32000, 256 at a time | 32,000 | 116,806 | 2.17 | 2.38 | 2.81 | 3.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo burst n=16000 | 16,000 | 43,976 | 0.00 | 0.00 | 0.00 | 0.0 | 524 | 0.23 | peak 33.4 KB per connection (523 MB over the idle server's 2 MB) while connecting in 0.4 s; 29.4 KB per connection (anon 22.9 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 360 MB, kernel 0 -> 102 MB, current 3 -> 463 MB 30 s later |
| anole@v010 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 53 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 1 -> 15 MB, kernel 0 -> 38 MB, current 3 -> 55 MB |
| anole@v010 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.4 + kernel 3.8, of which sock 0.0; memory.current 5.3); anon 1 -> 44 MB, kernel 0 -> 120 MB, current 3 -> 167 MB |
| anole@v010 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 48,788 | 0.02 | 0.03 | 0.10 | 0.1 | 0 | 0.00 |  |
| anole@v010 | /plaintext wake all 32000, 256 at a time | 32,000 | 131,300 | 1.92 | 2.12 | 2.80 | 3.0 | 0 | 0.00 |  |
| anole@v010 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 95 | 0.00 | 9.5 KB per connection (anon 5.6 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 1 -> 56 MB, kernel 0 -> 38 MB, current 3 -> 96 MB |
| anole@v010 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 285 | 0.00 | 9.1 KB per connection (anon 5.2 + kernel 3.9, of which sock 0.0; memory.current 9.1); anon 1 -> 164 MB, kernel 0 -> 122 MB, current 3 -> 286 MB |
| anole@v010 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 60,643 | 0.01 | 0.03 | 0.08 | 0.1 | 0 | 0.00 |  |
| anole@v010 | /plaintext wake all 32000, 256 at a time | 32,000 | 115,717 | 2.19 | 2.39 | 2.60 | 2.8 | 0 | 0.00 |  |
| anole@v010 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 136 MB, kernel 0 -> 64 MB, current 3 -> 201 MB |
| anole@v010 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 637 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 435 MB, kernel 0 -> 203 MB, current 3 -> 638 MB |
| anole@v010 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 40,912 | 0.02 | 0.04 | 0.17 | 0.3 | 0 | 0.00 |  |
| anole@v010 | /ws/echo wake all 32000, 256 at a time | 32,000 | 121,786 | 2.08 | 2.24 | 2.33 | 2.5 | 0 | 0.00 |  |
| anole@v010 | /ws/echo burst n=16000 | 16,000 | 46,745 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.20 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.3 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 218 MB, kernel 0 -> 102 MB, current 3 -> 321 MB 30 s later |
| anole@v010 | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 58 | 0.00 | 5.8 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 1 -> 20 MB, kernel 0 -> 38 MB, current 3 -> 59 MB |
| anole@v010 | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 176 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 1 -> 55 MB, kernel 0 -> 121 MB, current 3 -> 177 MB |
| anole@v010 | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 43,889 | 0.02 | 0.08 | 0.13 | 0.2 | 0 | 0.00 |  |
| anole@v010 | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 145,560 | 1.73 | 1.98 | 2.05 | 3.0 | 0 | 0.00 |  |
| anole@v010 | /ws/echo-cb burst n=16000 | 16,000 | 49,516 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.20 | peak 20.6 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.3 s; 5.9 KB per connection (anon 2.1 + kernel 3.8, of which sock 0.0; memory.current 5.8); anon 1 -> 34 MB, kernel 0 -> 60 MB, current 3 -> 94 MB 30 s later |

