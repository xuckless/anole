# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "e99ffe15f08d8d18d5da031584b3936e29f1adda",
  "date": "2026-10-21T21:59:57Z",
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
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 147 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 15.1); anon 1 -> 83 MB, kernel 0 -> 63 MB, current 2 -> 149 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 466 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 1 -> 265 MB, kernel 0 -> 201 MB, current 3 -> 467 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 47,151 | 0.02 | 0.07 | 0.11 | 0.1 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 147,118 | 1.69 | 2.02 | 2.12 | 2.2 | 0 | 0.00 |  |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 185 | 0.00 | 18.8 KB per connection (anon 12.4 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 1 -> 122 MB, kernel 0 -> 63 MB, current 3 -> 186 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 586 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 1 -> 384 MB, kernel 0 -> 202 MB, current 3 -> 587 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 51,785 | 0.01 | 0.09 | 0.14 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 121,201 | 2.06 | 2.39 | 4.77 | 4.9 | 0 | 0.00 |  |
| anole@a5 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 288 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 224 MB, kernel 0 -> 64 MB, current 3 -> 289 MB |
| anole@a5 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 918 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 714 MB, kernel 0 -> 204 MB, current 3 -> 919 MB |
| anole@a5 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 41,199 | 0.02 | 0.04 | 0.12 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo wake all 32000, 256 at a time | 32,000 | 122,817 | 2.07 | 2.22 | 2.26 | 2.4 | 0 | 0.00 |  |
| anole@a5 | /ws/echo burst n=16000 | 16,000 | 45,223 | 0.00 | 0.00 | 0.00 | 0.0 | 522 | 0.20 | peak 33.3 KB per connection (521 MB over the idle server's 1 MB) while connecting in 0.4 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 1 -> 357 MB, kernel 0 -> 102 MB, current 3 -> 462 MB 30 s later |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 52 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.3); anon 1 -> 14 MB, kernel 0 -> 38 MB, current 2 -> 54 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 162 | 0.00 | 5.1 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.1); anon 1 -> 40 MB, kernel 0 -> 121 MB, current 3 -> 163 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 56,918 | 0.01 | 0.04 | 0.10 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 150,641 | 1.68 | 1.85 | 2.03 | 2.1 | 0 | 0.00 |  |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 94 | 0.00 | 9.5 KB per connection (anon 5.5 + kernel 3.9, of which sock 0.0; memory.current 9.4); anon 1 -> 55 MB, kernel 0 -> 39 MB, current 3 -> 95 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 275 | 0.00 | 8.7 KB per connection (anon 4.9 + kernel 3.9, of which sock 0.0; memory.current 8.7); anon 1 -> 153 MB, kernel 0 -> 122 MB, current 3 -> 276 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 46,976 | 0.02 | 0.09 | 0.22 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 127,610 | 1.98 | 2.17 | 2.91 | 3.0 | 0 | 0.00 |  |
| anole@b74 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 199 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 1 -> 135 MB, kernel 0 -> 64 MB, current 2 -> 200 MB |
| anole@b74 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 634 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 431 MB, kernel 0 -> 204 MB, current 2 -> 635 MB |
| anole@b74 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 40,398 | 0.02 | 0.10 | 0.15 | 2.4 | 0 | 0.00 |  |
| anole@b74 | /ws/echo wake all 32000, 256 at a time | 32,000 | 126,670 | 2.00 | 2.21 | 2.67 | 2.7 | 0 | 0.00 |  |
| anole@b74 | /ws/echo burst n=16000 | 16,000 | 54,067 | 0.00 | 0.00 | 0.00 | 0.0 | 381 | 0.20 | peak 24.3 KB per connection (380 MB over the idle server's 1 MB) while connecting in 0.3 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 1 -> 216 MB, kernel 0 -> 102 MB, current 2 -> 319 MB 30 s later |
| anole@b74 | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 59 | 0.00 | 5.9 KB per connection (anon 1.9 + kernel 4.0, of which sock 0.0; memory.current 5.9); anon 1 -> 20 MB, kernel 0 -> 39 MB, current 2 -> 60 MB |
| anole@b74 | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 173 | 0.00 | 5.5 KB per connection (anon 1.6 + kernel 3.9, of which sock 0.0; memory.current 5.5); anon 1 -> 51 MB, kernel 0 -> 122 MB, current 3 -> 174 MB |
| anole@b74 | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 51,092 | 0.01 | 0.04 | 0.16 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 164,186 | 1.54 | 1.68 | 1.78 | 1.8 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb burst n=16000 | 16,000 | 55,106 | 0.00 | 0.00 | 0.00 | 0.0 | 321 | 0.18 | peak 20.5 KB per connection (320 MB over the idle server's 1 MB) while connecting in 0.3 s; 5.8 KB per connection (anon 2.0 + kernel 3.9, of which sock 0.0; memory.current 5.8); anon 1 -> 32 MB, kernel 0 -> 61 MB, current 3 -> 94 MB 30 s later |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 148 | 0.00 | 14.9 KB per connection (anon 8.5 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 85 MB, kernel 1 -> 63 MB, current 4 -> 149 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 468 | 0.00 | 14.9 KB per connection (anon 8.4 + kernel 6.4, of which sock 0.0; memory.current 14.9); anon 2 -> 266 MB, kernel 1 -> 202 MB, current 4 -> 469 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 45,551 | 0.02 | 0.09 | 0.23 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 386,217 | 0.33 | 3.11 | 3.72 | 4.0 | 0 | 0.00 |  |
| anole@a5 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 187 | 0.00 | 18.9 KB per connection (anon 12.5 + kernel 6.4, of which sock 0.0; memory.current 18.8); anon 2 -> 124 MB, kernel 1 -> 64 MB, current 4 -> 188 MB |
| anole@a5 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 588 | 0.00 | 18.7 KB per connection (anon 12.3 + kernel 6.4, of which sock 0.0; memory.current 18.7); anon 2 -> 386 MB, kernel 1 -> 202 MB, current 4 -> 589 MB |
| anole@a5 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 42,133 | 0.02 | 0.11 | 0.23 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /plaintext wake all 32000, 256 at a time | 32,000 | 378,127 | 0.13 | 2.54 | 2.66 | 2.7 | 0 | 0.00 |  |
| anole@a5 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 289 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 225 MB, kernel 1 -> 64 MB, current 4 -> 290 MB |
| anole@a5 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 919 | 0.00 | 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.3); anon 2 -> 714 MB, kernel 1 -> 204 MB, current 4 -> 920 MB |
| anole@a5 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 46,203 | 0.02 | 0.10 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@a5 | /ws/echo wake all 32000, 256 at a time | 32,000 | 399,718 | 0.11 | 2.33 | 2.39 | 2.6 | 0 | 0.00 |  |
| anole@a5 | /ws/echo burst n=16000 | 16,000 | 76,122 | 0.00 | 0.00 | 0.00 | 0.0 | 523 | 0.36 | peak 33.3 KB per connection (521 MB over the idle server's 2 MB) while connecting in 0.2 s; 29.3 KB per connection (anon 22.8 + kernel 6.5, of which sock 0.0; memory.current 29.2); anon 2 -> 358 MB, kernel 1 -> 103 MB, current 4 -> 461 MB 30 s later |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 56 | 0.00 | 5.5 KB per connection (anon 1.5 + kernel 4.0, of which sock 0.0; memory.current 5.4); anon 2 -> 17 MB, kernel 1 -> 39 MB, current 4 -> 57 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 164 | 0.00 | 5.2 KB per connection (anon 1.3 + kernel 3.9, of which sock 0.0; memory.current 5.2); anon 2 -> 42 MB, kernel 1 -> 122 MB, current 4 -> 166 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 59,637 | 0.01 | 0.08 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 513,649 | 0.38 | 1.55 | 1.62 | 1.7 | 0 | 0.00 |  |
| anole@b74 | /plaintext idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 97 | 0.00 | 9.7 KB per connection (anon 5.7 + kernel 3.9, of which sock 0.0; memory.current 9.6); anon 2 -> 58 MB, kernel 1 -> 39 MB, current 4 -> 98 MB |
| anole@b74 | /plaintext idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 292 | 0.00 | 9.3 KB per connection (anon 5.3 + kernel 3.9, of which sock 0.0; memory.current 9.2); anon 2 -> 169 MB, kernel 1 -> 123 MB, current 4 -> 293 MB |
| anole@b74 | /plaintext wake 1000 of 32000, one at a time | 1,000 | 43,525 | 0.02 | 0.11 | 0.19 | 0.2 | 0 | 0.00 |  |
| anole@b74 | /plaintext wake all 32000, 256 at a time | 32,000 | 432,350 | 0.35 | 1.98 | 2.08 | 2.2 | 0 | 0.00 |  |
| anole@b74 | /ws/echo idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 200 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.3); anon 2 -> 136 MB, kernel 1 -> 64 MB, current 4 -> 202 MB |
| anole@b74 | /ws/echo idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 635 | 0.00 | 20.3 KB per connection (anon 13.7 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 431 MB, kernel 1 -> 204 MB, current 4 -> 636 MB |
| anole@b74 | /ws/echo wake 1000 of 32000, one at a time | 1,000 | 47,425 | 0.02 | 0.09 | 0.24 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /ws/echo wake all 32000, 256 at a time | 32,000 | 408,173 | 0.29 | 2.28 | 2.35 | 2.5 | 0 | 0.00 |  |
| anole@b74 | /ws/echo burst n=16000 | 16,000 | 82,317 | 0.00 | 0.00 | 0.00 | 0.0 | 383 | 0.33 | peak 24.4 KB per connection (381 MB over the idle server's 2 MB) while connecting in 0.2 s; 20.3 KB per connection (anon 13.8 + kernel 6.5, of which sock 0.0; memory.current 20.2); anon 2 -> 217 MB, kernel 1 -> 102 MB, current 4 -> 319 MB 30 s later |
| anole@b74 | /ws/echo-cb idle n=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 59 | 0.00 | 5.8 KB per connection (anon 1.8 + kernel 3.9, of which sock 0.0; memory.current 5.7); anon 2 -> 20 MB, kernel 1 -> 39 MB, current 5 -> 60 MB |
| anole@b74 | /ws/echo-cb idle n=32000 | 32,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 177 | 0.00 | 5.6 KB per connection (anon 1.7 + kernel 3.9, of which sock 0.0; memory.current 5.6); anon 2 -> 54 MB, kernel 1 -> 122 MB, current 5 -> 178 MB |
| anole@b74 | /ws/echo-cb wake 1000 of 32000, one at a time | 1,000 | 43,668 | 0.02 | 0.10 | 0.18 | 0.3 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb wake all 32000, 256 at a time | 32,000 | 523,652 | 0.28 | 1.43 | 1.53 | 1.6 | 0 | 0.00 |  |
| anole@b74 | /ws/echo-cb burst n=16000 | 16,000 | 89,813 | 0.00 | 0.00 | 0.00 | 0.0 | 323 | 0.36 | peak 20.5 KB per connection (321 MB over the idle server's 2 MB) while connecting in 0.2 s; 6.1 KB per connection (anon 2.2 + kernel 3.9, of which sock 0.0; memory.current 6.0); anon 2 -> 36 MB, kernel 1 -> 62 MB, current 5 -> 99 MB 30 s later |

