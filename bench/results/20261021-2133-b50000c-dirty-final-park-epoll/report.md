# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "b50000c42ead00a20c3e6087816af22884791972 (dirty)",
  "date": "2026-10-21T21:33:41Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@a5": "fd2bb943f847", "anole@b74": "070e07554e3b", "loadgen": "75b50004f33c"}
}

```

## Idle connections: memory and wake-up

Idle: n connections (keep-alive after one GET /plaintext, plain or TLS; or WebSockets on /ws/echo, a loop, or /ws/echo-cb, callbacks) sit idle 30 s; memory per connection from the cgroup (anon + kernel; the parts and memory.current in the notes). Wake: after 5 s more of idle, one request (or echo) on 1,000 of them one at a time, then on all of them 256 at a time; response time. Burst: 16,000 WebSockets connect as fast as the client can; peak memory sampled every 50 ms.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 15.0 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 85 MB, kernel 0 -> 63 MB, current 11 -> 157 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 470 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 1 -> 269 MB, kernel 0 -> 201 MB, current 2 -> 470 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 44,996 | 0.02 | 0.07 | 0.15 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 121,217 | 2.08 | 2.40 | 3.04 | 3.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 186 | 0.00 | 18.9 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 1 -> 123 MB, kernel 0 -> 63 MB, current 3 -> 187 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 589 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 388 MB, kernel 0 -> 201 MB, current 3 -> 592 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 40,386 | 0.02 | 0.06 | 0.22 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 97,451 | 2.58 | 3.53 | 4.18 | 4.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 225 MB, kernel 0 -> 64 MB, current 5 -> 292 MB |
| anole@a5 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 1 -> 720 MB, kernel 0 -> 203 MB, current 3 -> 924 MB |
| anole@a5 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 51,000 | 0.02 | 0.03 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo wake all 32000, 256 at a time | 32,000 | 116,487 | 2.18 | 2.39 | 2.47 | 2.5 | 0 | 0.00 |  |
| anole@a5 | /ws/echo burst n=16000 | 16,000 | 44,390 | 0.00 | 0.00 | 0.00 | 0.0 | 524 | 0.21 | peak 33.4 KB per connection (522 MB over the idle server's 2 MB) while connecting in 0.4 s; 29.4 KB per connection (anon 22.9 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 1 -> 359 MB, kernel 0 -> 102 MB, current 7 -> 466 MB 30 s later |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 53 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 1 -> 15 MB, kernel 0 -> 38 MB, current 12 -> 62 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 165 | 0.00 | 5.2 KB per connection (anon 1.4 + kernel 3.8, of which sock 0.0; memory.current 5.2); anon 1 -> 44 MB, kernel 0 -> 120 MB, current 2 -> 166 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 53,292 | 0.02 | 0.03 | 0.09 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 138,500 | 1.82 | 2.20 | 2.97 | 3.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 93 | 0.00 | 9.4 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.3); anon 1 -> 55 MB, kernel 0 -> 38 MB, current 3 -> 94 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 282 | 0.00 | 9.0 KB per connection (anon 5.1 + kernel 3.9, of which sock 0.0; memory.current 9.0); anon 1 -> 161 MB, kernel 0 -> 121 MB, current 3 -> 283 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 39,694 | 0.02 | 0.04 | 0.12 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 114,495 | 2.22 | 2.40 | 2.58 | 2.7 | 0 | 0.00 |  |
| anole@b74 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 137 MB, kernel 0 -> 64 MB, current 3 -> 201 MB |
| anole@b74 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 637 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 435 MB, kernel 0 -> 203 MB, current 3 -> 638 MB |
| anole@b74 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 34,635 | 0.03 | 0.04 | 0.16 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /ws/echo wake all 32000, 256 at a time | 32,000 | 119,939 | 2.11 | 2.28 | 2.44 | 2.7 | 0 | 0.00 |  |
| anole@b74 | /ws/echo burst n=16000 | 16,000 | 48,167 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.20 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.3 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 218 MB, kernel 0 -> 102 MB, current 3 -> 321 MB 30 s later |
| anole@b74 | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 59 | 0.00 | 5.9 KB per connection (anon 1.9 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 1 -> 20 MB, kernel 0 -> 38 MB, current 3 -> 60 MB |
| anole@b74 | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 177 | 0.00 | 5.6 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 1 -> 56 MB, kernel 0 -> 121 MB, current 3 -> 178 MB |
| anole@b74 | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 35,109 | 0.02 | 0.04 | 0.17 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 143,583 | 1.77 | 1.88 | 1.98 | 2.3 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb burst n=16000 | 16,000 | 52,085 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.19 | peak 20.6 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.3 s; 5.9 KB per connection (anon 2.1 + kernel 3.9, of which sock 0.0; memory.current 5.9); anon 1 -> 34 MB, kernel 0 -> 60 MB, current 3 -> 95 MB 30 s later |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 149 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 86 MB, kernel 0 -> 63 MB, current 7 -> 152 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 471 | 0.00 | 15.0 KB per connection (anon 8.6 + kernel 6.4, of which sock 0.0; memory.current 15.0); anon 2 -> 270 MB, kernel 0 -> 201 MB, current 4 -> 472 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 49,604 | 0.02 | 0.08 | 0.20 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 403,649 | 0.15 | 2.45 | 2.52 | 2.6 | 0 | 0.00 |  |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 188 | 0.00 | 19.0 KB per connection (anon 12.6 + kernel 6.4, of which sock 0.0; memory.current 18.9); anon 2 -> 125 MB, kernel 0 -> 63 MB, current 7 -> 192 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 591 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 390 MB, kernel 0 -> 201 MB, current 5 -> 592 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 39,177 | 0.02 | 0.12 | 0.16 | 0.3 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 296,312 | 0.09 | 3.35 | 3.45 | 3.5 | 0 | 0.00 |  |
| anole@a5 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 290 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 226 MB, kernel 0 -> 64 MB, current 7 -> 293 MB |
| anole@a5 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 924 | 0.00 | 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.5); anon 2 -> 721 MB, kernel 0 -> 204 MB, current 5 -> 925 MB |
| anole@a5 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 48,184 | 0.02 | 0.08 | 0.13 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo wake all 32000, 256 at a time | 32,000 | 345,142 | 0.08 | 2.82 | 2.87 | 2.9 | 0 | 0.00 |  |
| anole@a5 | /ws/echo burst n=16000 | 16,000 | 82,279 | 0.00 | 0.00 | 0.00 | 0.0 | 526 | 0.36 | peak 33.5 KB per connection (523 MB over the idle server's 3 MB) while connecting in 0.2 s; 29.5 KB per connection (anon 23.0 + kernel 6.5, of which sock 0.0; memory.current 29.4); anon 2 -> 361 MB, kernel 0 -> 102 MB, current 4 -> 464 MB 30 s later |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 56 | 0.00 | 5.5 KB per connection (anon 1.6 + kernel 3.9, of which sock 0.0; memory.current 5.4); anon 2 -> 18 MB, kernel 0 -> 39 MB, current 4 -> 57 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 168 | 0.00 | 5.3 KB per connection (anon 1.4 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 2 -> 47 MB, kernel 0 -> 121 MB, current 4 -> 169 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 46,540 | 0.02 | 0.08 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 426,497 | 0.09 | 2.24 | 2.32 | 2.4 | 0 | 0.00 |  |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.6 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 2 -> 58 MB, kernel 0 -> 39 MB, current 6 -> 98 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 300 | 0.00 | 9.5 KB per connection (anon 5.6 + kernel 3.9, of which sock 0.0; memory.current 9.5); anon 2 -> 177 MB, kernel 0 -> 122 MB, current 5 -> 301 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 55,368 | 0.01 | 0.09 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 369,619 | 0.12 | 2.63 | 2.69 | 2.7 | 0 | 0.00 |  |
| anole@b74 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 201 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 137 MB, kernel 0 -> 64 MB, current 4 -> 202 MB |
| anole@b74 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 638 | 0.00 | 20.3 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 436 MB, kernel 0 -> 203 MB, current 4 -> 640 MB |
| anole@b74 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 47,568 | 0.02 | 0.10 | 0.14 | 0.1 | 0 | 0.00 |  |
| anole@b74 | /ws/echo wake all 32000, 256 at a time | 32,000 | 384,289 | 0.26 | 2.38 | 2.43 | 2.5 | 0 | 0.00 |  |
| anole@b74 | /ws/echo burst n=16000 | 16,000 | 78,640 | 0.00 | 0.00 | 0.00 | 0.0 | 384 | 0.33 | peak 24.4 KB per connection (382 MB over the idle server's 3 MB) while connecting in 0.2 s; 20.4 KB per connection (anon 13.9 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 219 MB, kernel 0 -> 102 MB, current 4 -> 322 MB 30 s later |
| anole@b74 | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 60 | 0.00 | 5.9 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 2 -> 21 MB, kernel 0 -> 39 MB, current 4 -> 61 MB |
| anole@b74 | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 176 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.5); anon 2 -> 56 MB, kernel 0 -> 121 MB, current 5 -> 177 MB |
| anole@b74 | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 47,885 | 0.01 | 0.10 | 0.17 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 479,439 | 0.36 | 1.74 | 1.86 | 1.9 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb burst n=16000 | 16,000 | 77,033 | 0.00 | 0.00 | 0.00 | 0.0 | 325 | 0.31 | peak 20.6 KB per connection (322 MB over the idle server's 3 MB) while connecting in 0.2 s; 6.1 KB per connection (anon 2.3 + kernel 3.9, of which sock 0.0; memory.current 6.1); anon 2 -> 37 MB, kernel 0 -> 61 MB, current 4 -> 99 MB 30 s later |

