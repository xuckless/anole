# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "832f93eb6a6c879cf2394cf20a2f070d39733af5",
  "date": "2026-10-22T13:09:55Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "3bc06beade3c", "fiber": "d638a84273d0", "axum": "2d143fbf2c9e", "express": "334a9cdf1a09", "fastify": "a1f8b33e5ace", "fastapi": "eec38cf0322e", "gohttp-wt": "8285bcf0490a", "axum-wt": "8166213c47b7", "fastify-wt": "c3746fe42399", "fastapi-wt": "c916038fbcaa", "loadgen": "2367e7059a20"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **239,737** p99 1.09 ms [8 MB, 1.00] | **198,072** p99 1.35 ms [15 MB, 1.00] | **717,595** mean 0.89 ms [11 MB, 1.00] | **676,728** mean 0.94 ms [15 MB, 1.00] | **385,266** mean 1.66 ms [68 MB, 1.00] |
| fiber | **232,334** p99 1.63 ms [8 MB, 1.00] | **203,611** p99 1.86 ms [23 MB, 1.00] | N/A | N/A | N/A |
| axum | **220,511** p99 1.21 ms [10 MB, 1.00] | **198,490** p99 1.36 ms [12 MB, 1.00] | **272,453** mean 2.34 ms [6 MB, 1.00] | **257,164** mean 2.47 ms [12 MB, 1.00] | **113,880** mean 5.62 ms [16 MB, 1.00] |
| express | **82,602** p99 3.61 ms [108 MB, 1.00] | **65,061** p99 5.59 ms [178 MB, 1.00] | N/A | N/A | N/A |
| fastify | **122,418** p99 2.24 ms [103 MB, 1.00] | **96,507** p99 3.09 ms [169 MB, 1.00] | **68,706** mean 9.31 ms [242 MB, 1.00] | **63,232** mean 10.12 ms [271 MB, 1.00] | N/A |
| fastapi | **23,066** p99 21.87 ms [48 MB, 1.00] | **20,882** p99 13.51 ms [86 MB, 1.00] | **5,333** mean 119.89 ms [164 MB, 1.00] | N/A | **2,658** mean 212.29 ms [97 MB, 0.99] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **239,174** p99 1.09 ms [7 MB, 1.00] | **193,209** p99 1.37 ms [15 MB, 1.00] | **681,200** mean 0.94 ms [11 MB, 1.00] | **643,456** mean 0.99 ms [15 MB, 1.00] | **370,892** mean 1.72 ms [80 MB, 1.00] |
| fiber | **220,302** p99 1.71 ms [15 MB, 1.00] | **196,284** p99 1.94 ms [27 MB, 1.00] | N/A | N/A | N/A |
| axum | **218,665** p99 1.21 ms [11 MB, 1.00] | **192,141** p99 1.67 ms [12 MB, 1.00] | **266,561** mean 2.39 ms [6 MB, 1.00] | **251,221** mean 2.51 ms [12 MB, 1.00] | **117,649** mean 5.43 ms [16 MB, 1.00] |
| express | **78,260** p99 4.01 ms [107 MB, 1.00] | **62,808** p99 5.74 ms [181 MB, 1.00] | N/A | N/A | N/A |
| fastify | **119,977** p99 2.29 ms [109 MB, 1.00] | **94,356** p99 3.17 ms [174 MB, 1.00] | **66,943** mean 9.55 ms [252 MB, 1.00] | **62,087** mean 10.29 ms [271 MB, 1.00] | N/A |
| fastapi | **19,081** p99 26.79 ms [53 MB, 1.00] | **17,427** p99 15.75 ms [114 MB, 1.00] | **4,098** mean 155.82 ms [276 MB, 1.00] | N/A | **2,541** mean 141.18 ms [103 MB, 0.99] |

### 1cpu, GET /list

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **109,226** p99 2.38 ms [9 MB, 1.00] | **98,125** p99 2.67 ms [18 MB, 1.00] | **161,332** mean 3.97 ms [16 MB, 1.00] | **142,533** mean 4.49 ms [20 MB, 1.00] | **108,783** mean 5.88 ms [82 MB, 1.00] |
| fiber | **72,021** p99 5.69 ms [16 MB, 1.00] | **67,556** p99 6.32 ms [28 MB, 1.00] | N/A | N/A | N/A |
| axum | **82,749** p99 3.18 ms [11 MB, 1.00] | **75,701** p99 3.50 ms [12 MB, 1.00] | **84,823** mean 7.52 ms [8 MB, 1.00] | **78,943** mean 8.10 ms [12 MB, 1.00] | **56,264** mean 11.37 ms [18 MB, 1.00] |
| express | **53,860** p99 5.15 ms [113 MB, 1.00] | **43,420** p99 7.36 ms [209 MB, 1.00] | N/A | N/A | N/A |
| fastify | **67,677** p99 3.98 ms [183 MB, 1.00] | **53,510** p99 5.22 ms [203 MB, 1.00] | **44,290** mean 14.43 ms [266 MB, 1.00] | **39,993** mean 15.98 ms [292 MB, 1.00] | N/A |
| fastapi | **3,770** p99 5453.11 ms [54 MB, 1.00] | **3,608** p99 77.29 ms [121 MB, 1.00] | **1,965** mean 323.33 ms [374 MB, 1.00] | N/A | **1,497** mean 326.65 ms [105 MB, 0.99] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **597,589** p99 0.48 ms [8 MB, 4.00] | **522,580** p99 0.69 ms [15 MB, 4.00] | **2,066,881** mean 0.30 ms [12 MB, 4.00] | **1,994,600** mean 0.30 ms [19 MB, 4.00] | **1,361,374** mean 0.47 ms [57 MB, 3.99] |
| fiber | **469,840** p99 3.88 ms [8 MB, 3.24] | **417,901** p99 3.98 ms [26 MB, 3.22] | N/A | N/A | N/A |
| axum | **457,060** p99 1.06 ms [12 MB, 3.97] | **404,178** p99 1.19 ms [13 MB, 3.98] | **596,731** mean 1.06 ms [8 MB, 3.97] | **547,235** mean 1.15 ms [14 MB, 3.96] | **274,841** mean 2.32 ms [17 MB, 3.89] |
| express | **249,965** p99 1.43 ms [358 MB, 4.00] | **201,270** p99 2.78 ms [637 MB, 4.00] | N/A | N/A | N/A |
| fastify | **342,479** p99 0.98 ms [280 MB, 4.00] | **273,774** p99 1.04 ms [620 MB, 4.00] | **228,191** mean 2.73 ms [1084 MB, 3.95] | **209,677** mean 3.05 ms [919 MB, 3.96] | N/A |
| fastapi | **77,878** p99 3.50 ms [195 MB, 4.00] | **69,258** p99 3.87 ms [237 MB, 4.00] | **19,458** mean 32.86 ms [403 MB, 4.00] | N/A | **8,974** mean 54.72 ms [335 MB, 3.92] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **589,961** p99 0.51 ms [8 MB, 4.00] | **514,509** p99 0.63 ms [16 MB, 4.00] | **1,999,866** mean 0.31 ms [12 MB, 4.00] | **1,922,538** mean 0.32 ms [19 MB, 4.00] | **1,329,716** mean 0.48 ms [65 MB, 3.99] |
| fiber | **446,508** p99 4.07 ms [17 MB, 3.29] | **399,520** p99 4.13 ms [29 MB, 3.26] | N/A | N/A | N/A |
| axum | **452,322** p99 1.07 ms [12 MB, 3.97] | **393,225** p99 1.24 ms [15 MB, 3.97] | **563,045** mean 1.12 ms [8 MB, 3.95] | **521,831** mean 1.21 ms [14 MB, 3.94] | **284,643** mean 2.25 ms [17 MB, 3.89] |
| express | **242,614** p99 1.67 ms [459 MB, 4.00] | **194,559** p99 2.58 ms [643 MB, 4.00] | N/A | N/A | N/A |
| fastify | **336,366** p99 0.95 ms [288 MB, 4.00] | **267,078** p99 1.05 ms [626 MB, 4.00] | **223,029** mean 2.80 ms [1274 MB, 3.96] | **206,373** mean 3.09 ms [955 MB, 3.96] | N/A |
| fastapi | **64,558** p99 4.38 ms [200 MB, 4.00] | **58,084** p99 4.57 ms [260 MB, 4.00] | **14,177** mean 45.05 ms [652 MB, 3.03] | N/A | **8,658** mean 60.54 ms [344 MB, 3.93] |

### 4cpu, GET /list

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **321,298** p99 0.86 ms [10 MB, 4.00] | **275,967** p99 1.05 ms [17 MB, 4.00] | **537,196** mean 1.18 ms [18 MB, 4.00] | **461,630** mean 1.39 ms [26 MB, 4.00] | **377,968** mean 1.72 ms [74 MB, 4.00] |
| fiber | **192,097** p99 7.03 ms [22 MB, 3.85] | **181,019** p99 7.50 ms [31 MB, 3.86] | N/A | N/A | N/A |
| axum | **178,860** p99 2.64 ms [13 MB, 3.79] | **201,118** p99 2.30 ms [15 MB, 3.98] | **193,076** mean 3.30 ms [10 MB, 3.83] | **206,348** mean 3.08 ms [14 MB, 3.93] | **143,615** mean 4.45 ms [22 MB, 3.84] |
| express | **169,407** p99 1.88 ms [431 MB, 4.00] | **139,639** p99 3.01 ms [696 MB, 4.00] | N/A | N/A | N/A |
| fastify | **206,435** p99 1.47 ms [426 MB, 4.00] | **166,055** p99 1.92 ms [654 MB, 4.00] | **149,510** mean 4.21 ms [1331 MB, 3.99] | **133,359** mean 4.86 ms [974 MB, 3.99] | N/A |
| fastapi | **13,025** p99 21.12 ms [200 MB, 4.00] | **12,643** p99 22.54 ms [269 MB, 4.00] | **4,697** mean 135.89 ms [853 MB, 2.04] | N/A | **5,098** mean 100.05 ms [345 MB, 3.93] |

## Concurrent connections (HTTP/1.1 keep-alive, GET /json)

req/s / p99 ms / server memory MB at each connection count.

### 1cpu

| Server | c=16 | c=64 | c=256 | c=1024 | c=4096 | c=10000 | c=25000 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| anole | 237,779 / 0.1 / 2 | 251,999 / 0.3 / 3 | 228,215 / 1.3 / 7 | 217,067 / 5.1 / 23 | 154,480 / 27.7 / 89 | 120,000 / 85.7 / 218 | 133,042 / 6319.6 / 498 |
| fiber | 220,119 / 0.1 / 7 | 217,576 / 0.6 / 7 | 209,755 / 1.8 / 16 | 205,675 / 5.9 / 49 | 160,833 / 27.1 / 179 | 145,847 / 72.6 / 393 | 142,702 / 183.3 / 917 |
| axum | 223,468 / 0.1 / 2 | 215,925 / 0.3 / 3 | 208,744 / 1.3 / 10 | 200,571 / 168.3 / 33 | 199,141 / 776.4 / 137 | 198,600 / 1958.4 / 346 | 198,347 / 4530.6 / 833 |
| express | 82,337 / 0.4 / 67 | 80,864 / 1.2 / 92 | 79,676 / 3.7 / 103 | 75,809 / 1990.2 / 192 | 67,682 / 877.3 / 237 | 64,660 / 76.8 / 269 | 59,700 / 173.9 / 334 |
| fastify | 124,489 / 0.2 / 60 | 122,596 / 0.6 / 62 | 121,255 / 2.3 / 97 | 119,086 / 1222.5 / 185 | 99,694 / 2314.2 / 218 | 93,180 / 58.1 / 277 | 84,276 / 118.4 / 320 |
| fastapi | 20,006 / 1.5 / 41 | 19,817 / 3.4 / 42 | 19,171 / 262.7 / 48 | 17,783 / 5292.4 / 77 | 17,424 / 1843.0 / 90 | 17,372 / 85.2 / 90 | 16,902 / 90.3 / 99 |

## Latency at fixed request rates (open loop, GET /json)

oha with `--latency-correction` (coordinated omission accounted for), 64 connections. p50 / p99 / p99.9 in ms; a rate a server could not sustain is marked in the notes.

| Server | Proto | Rate | Achieved req/s | p50 | p99 | p99.9 | max | Memory MB | CPU |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| axum | h1 | rate=1000 | 1,000 | 0.02 | 0.10 | 0.17 | 10.5 | 3 | 0.01 |
| axum | h1 | rate=5000 | 5,000 | 0.06 | 0.17 | 0.23 | 7.7 | 4 | 0.03 |
| axum | h1 | rate=20000 | 19,998 | 0.11 | 0.25 | 0.53 | 18.5 | 4 | 0.08 |
| axum | h1 | rate=50%max | 109,324 | 0.48 | 1.16 | 31.53 | 80.0 | 4 | 0.33 |
| axum | h1 | rate=75%max | 163,987 | 0.81 | 51.67 | 102.93 | 148.9 | 4 | 0.46 |
| axum | h2-tls | rate=1000 | 1,000 | 0.04 | 0.13 | 0.28 | 63.5 | 4 | 0.02 |
| axum | h2-tls | rate=5000 | 5,001 | 0.08 | 0.21 | 42.44 | 47.9 | 5 | 0.05 |
| axum | h2-tls | rate=20000 | 20,000 | 0.18 | 0.42 | 43.64 | 74.4 | 5 | 0.15 |
| axum | h2-tls | rate=75%max | 122,102 [1] | 5119.76 | 10454.98 | 10546.16 | 10557.3 | 5 | 0.73 |
| axum | h2-tls | rate=50%max | 124,108 | 1.29 | 346.41 | 357.90 | 359.6 | 5 | 0.73 |
| axum | h3 | rate=1000 | fail [2] | | | | | | |
| axum | h3 | rate=5000 | fail [3] | | | | | | |
| axum | h3 | rate=20000 | fail [4] | | | | | | |
| axum | h3 | rate=50%max | fail [5] | | | | | | |
| axum | h3 | rate=75%max | fail [6] | | | | | | |

## Notes

1. latency axum 1cpu h2-tls /json rate=75%max: fell behind: 122102 of 188416 req/s
2. latency axum 1cpu h3 /json rate=1000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
3. latency axum 1cpu h3 /json rate=5000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 5000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
4. latency axum 1cpu h3 /json rate=20000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 20000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
5. latency axum 1cpu h3 /json rate=50%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 58824 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
6. latency axum 1cpu h3 /json rate=75%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 88236 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
