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
| anole | h1 | rate=1000 | 1,000 | 0.02 | 0.11 | 0.20 | 13.8 | 3 | 0.01 |
| anole | h1 | rate=5000 | 5,000 | 0.06 | 0.17 | 0.22 | 5.7 | 3 | 0.03 |
| anole | h1 | rate=20000 | 19,999 | 0.11 | 0.23 | 0.43 | 19.2 | 3 | 0.07 |
| anole | h1 | rate=50%max | 119,574 | 0.44 | 4.49 | 32.79 | 83.3 | 3 | 0.29 |
| anole | h1 | rate=75%max | 179,370 | 0.80 | 47.16 | 95.77 | 144.6 | 3 | 0.43 |
| anole | h2-tls | rate=1000 | 1,000 | 0.04 | 0.13 | 0.28 | 8.5 | 8 | 0.01 |
| anole | h2-tls | rate=5000 | 5,001 | 0.08 | 0.20 | 0.71 | 26.5 | 10 | 0.04 |
| anole | h2-tls | rate=20000 | 19,999 | 0.16 | 0.33 | 2.29 | 20.3 | 10 | 0.11 |
| anole | h2-tls | rate=75%max | 152,612 [1] | 9808.98 | 20279.87 | 20487.26 | 20510.6 | 10 | 0.65 |
| anole | h2-tls | rate=50%max | 160,184 [2] | 6989.20 | 14902.78 | 15044.63 | 15061.5 | 10 | 0.65 |
| anole | h3 | rate=1000 | fail [3] | | | | | | |
| anole | h3 | rate=5000 | fail [4] | | | | | | |
| anole | h3 | rate=20000 | fail [5] | | | | | | |
| anole | h3 | rate=50%max | fail [6] | | | | | | |
| anole | h3 | rate=75%max | fail [7] | | | | | | |
| fiber | h1 | rate=1000 | 1,000 | 0.02 | 0.10 | 0.16 | 6.4 | 5 | 0.01 |
| fiber | h1 | rate=5000 | 5,000 | 0.05 | 0.16 | 0.20 | 10.4 | 7 | 0.03 |
| fiber | h1 | rate=20000 | 19,998 | 0.11 | 0.26 | 0.50 | 18.8 | 7 | 0.08 |
| fiber | h1 | rate=50%max | 110,140 | 0.46 | 2.53 | 37.86 | 90.6 | 7 | 0.33 |
| fiber | h1 | rate=75%max | 165,215 | 0.76 | 53.14 | 104.80 | 149.5 | 7 | 0.46 |
| fiber | h1-tls | rate=1000 | 1,000 | 0.02 | 0.11 | 1.61 | 22.6 | 9 | 0.01 |
| fiber | h1-tls | rate=5000 | 5,000 | 0.05 | 0.17 | 1.54 | 27.6 | 9 | 0.04 |
| fiber | h1-tls | rate=20000 | 19,999 | 0.12 | 0.31 | 4.15 | 32.9 | 9 | 0.09 |
| fiber | h1-tls | rate=50%max | 98,135 | 0.42 | 3.51 | 26.46 | 74.1 | 9 | 0.32 |
| fiber | h1-tls | rate=75%max | 147,206 | 0.72 | 90.97 | 144.52 | 214.2 | 9 | 0.46 |
| axum | h1 | rate=1000 | 1,000 | 0.02 | 0.10 | 0.17 | 10.5 | 3 | 0.01 |
| axum | h1 | rate=5000 | 5,000 | 0.06 | 0.17 | 0.23 | 7.7 | 4 | 0.03 |
| axum | h1 | rate=20000 | 19,998 | 0.11 | 0.25 | 0.53 | 18.5 | 4 | 0.08 |
| axum | h1 | rate=50%max | 109,324 | 0.48 | 1.16 | 31.53 | 80.0 | 4 | 0.33 |
| axum | h1 | rate=75%max | 163,987 | 0.81 | 51.67 | 102.93 | 148.9 | 4 | 0.46 |
| axum | h2-tls | rate=1000 | 1,000 | 0.04 | 0.13 | 0.28 | 63.5 | 4 | 0.02 |
| axum | h2-tls | rate=5000 | 5,001 | 0.08 | 0.21 | 42.44 | 47.9 | 5 | 0.05 |
| axum | h2-tls | rate=20000 | 20,000 | 0.18 | 0.42 | 43.64 | 74.4 | 5 | 0.15 |
| axum | h2-tls | rate=75%max | 122,102 [8] | 5119.76 | 10454.98 | 10546.16 | 10557.3 | 5 | 0.73 |
| axum | h2-tls | rate=50%max | 124,108 | 1.29 | 346.41 | 357.90 | 359.6 | 5 | 0.73 |
| axum | h3 | rate=1000 | fail [9] | | | | | | |
| axum | h3 | rate=5000 | fail [10] | | | | | | |
| axum | h3 | rate=20000 | fail [11] | | | | | | |
| axum | h3 | rate=50%max | fail [12] | | | | | | |
| axum | h3 | rate=75%max | fail [13] | | | | | | |
| express | h1 | rate=1000 | 1,000 | 0.04 | 0.15 | 0.28 | 3.5 | 45 | 0.03 |
| express | h1 | rate=5000 | 5,000 | 0.09 | 0.21 | 0.28 | 11.8 | 39 | 0.08 |
| express | h1 | rate=20000 | 19,999 | 0.22 | 0.58 | 2.77 | 27.9 | 64 | 0.25 |
| express | h1 | rate=50%max | 39,126 | 0.63 | 1.33 | 15.07 | 43.0 | 92 | 0.51 |
| express | h1 | rate=75%max | 58,692 | 0.88 | 5.14 | 37.34 | 55.6 | 92 | 0.69 |
| express | h1-tls | rate=1000 | 1,000 | 0.04 | 0.15 | 2.83 | 18.3 | 49 | 0.03 |
| express | h1-tls | rate=5000 | 5,000 | 0.09 | 0.26 | 2.54 | 34.6 | 54 | 0.09 |
| express | h1-tls | rate=20000 | 19,999 | 0.26 | 0.64 | 8.50 | 38.2 | 94 | 0.30 |
| express | h1-tls | rate=50%max | 31,402 | 0.51 | 1.23 | 17.10 | 35.6 | 149 | 0.49 |
| express | h1-tls | rate=75%max | 47,103 | 0.92 | 7.10 | 25.44 | 38.5 | 150 | 0.71 |
| fastify | h1 | rate=1000 | 1,000 | 0.03 | 0.11 | 0.18 | 4.3 | 49 | 0.02 |
| fastify | h1 | rate=5000 | 5,000 | 0.07 | 0.18 | 0.28 | 8.6 | 42 | 0.06 |
| fastify | h1 | rate=20000 | 19,998 | 0.17 | 0.43 | 1.48 | 28.3 | 50 | 0.16 |
| fastify | h1 | rate=50%max | 59,984 | 0.55 | 1.24 | 13.37 | 37.3 | 64 | 0.46 |
| fastify | h1 | rate=75%max | 89,975 | 0.87 | 20.08 | 53.37 | 76.0 | 92 | 0.63 |
| fastify | h2-tls | rate=1000 | 1,001 | 0.06 | 0.16 | 16.06 | 25.2 | 117 | 0.04 |
| fastify | h2-tls | rate=5000 | 5,001 | 0.17 | 0.41 | 16.47 | 28.0 | 120 | 0.13 |
| fastify | h2-tls | rate=20000 | 19,998 | 0.76 | 13.21 | 34.25 | 44.0 | 175 | 0.44 |
| fastify | h2-tls | rate=50%max | 31,043 | 1.50 | 39.99 | 53.99 | 57.2 | 239 | 0.69 |
| fastify | h2-tls | rate=75%max | 38,867 [14] | 2422.83 | 4906.15 | 4956.10 | 4961.4 | 276 | 0.84 |
| fastapi | h1 | rate=1000 | 1,000 | 0.08 | 0.19 | 0.26 | 4.9 | 42 | 0.07 |
| fastapi | h1 | rate=5000 | 5,000 | 0.27 | 0.54 | 0.61 | 12.0 | 42 | 0.27 |
| fastapi | h1 | rate=50%max | 9,539 | 0.47 | 1.01 | 1.15 | 15.1 | 42 | 0.48 |
| fastapi | h1 | rate=75%max | 14,310 | 0.87 | 1.70 | 7.26 | 16.1 | 42 | 0.73 |
| fastapi | h1-tls | rate=1000 | 1,000 | 0.09 | 0.20 | 4.32 | 26.4 | 46 | 0.08 |
| fastapi | h1-tls | rate=5000 | 5,000 | 0.28 | 0.61 | 2.46 | 46.3 | 48 | 0.30 |
| fastapi | h1-tls | rate=50%max | 8,712 | 0.49 | 1.05 | 8.75 | 74.0 | 48 | 0.49 |
| fastapi | h1-tls | rate=75%max | 13,069 | 0.88 | 1.82 | 21.95 | 114.6 | 49 | 0.74 |
| fastapi | h3 | rate=1000 | fail [15] | | | | | | |
| fastapi | h3 | rate=50%max | fail [16] | | | | | | |
| fastapi | h3 | rate=75%max | fail [17] | | | | | | |

## The $12 server challenge (Postgres)

load.js's users (feed, think, post, think, 15% like, 2% write, idle), added in steps; each step's window must keep p95 < 500 ms, p99 < 1 s and < 1% errors. Score: the most users that passed. Server memory is the peak in that step.

### 1cpu

| Server | Score (users) | req/s at score | p95 ms | p99 ms | memory MB | cores busy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| anole | **100,000** | 10,583 | 1 | 1 | 493 | 0.29 |
| fiber | 43,750 | | | | | |
| axum | **50,000** | 5,293 | 1 | 1 | 1960 | 0.27 |
| bun | **100,000** | 10,587 | 1 | 2 | 426 | 0.42 |

### 4cpu

| Server | Score (users) | req/s at score | p95 ms | p99 ms | memory MB | cores busy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| anole | **100,000** | 10,587 | 1 | 1 | 492 | 0.41 |
| fiber | **100,000** | 10,585 | 1 | 1 | 5000 | 0.50 |
| axum | **100,000** | 10,586 | 1 | 1 | 3958 | 0.73 |
| bun | **100,000** | 10,587 | 1 | 1 | 472 | 0.61 |

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo idle=50000 | 50,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1188 | 0.04 | 24.3 KB per socket (2 MB -> 1188 MB) |
| anole | /ws/echo echo c=64 | 7,888,006 | 262,931 | 0.24 | 0.28 | 2.43 | 31.6 | 721 | 0.98 |  |
| anole | /ws/echo echo c=1024 | 6,162,381 | 205,374 | 4.80 | 7.17 | 9.21 | 14.0 | 92 | 1.00 |  |
| anole | /ws/feed fanout-100x1000hz | 100 | 100,001 | 1.45 | 3.14 | 4.50 | 5.7 | 5 | 0.32 | 100/100 connected, 100001 of 100000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-1000x1000hz | 1,000 | 269,017 | 1.98 | 4.22 | 5.89 | 7.5 | 28 | 1.00 | 1000/1000 connected, 269017 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-10000x100hz | 10,000 | 214,451 | 23.69 | 46.51 | 47.95 | 52.7 | 246 | 1.00 | 10000/10000 connected, 214451 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed trading-500bots | 500 | 99,999 | 0.96 | 2.51 | 3.52 | 4.4 | 18 | 0.39 | 500/500 connected, 99999 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.26 p99 0.42 p99.9 0.47 ms, 0 errors |
| anole | /ws/feed trading-2000bots | 2,000 | 245,557 | 10326.69 | 22140.47 | 22349.51 | 22353.0 | 285 | 1.00 | 2000/2000 connected, 245557 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 8.99 p99 11.26 p99.9 18.96 ms, 0 errors |
| fiber | /ws/echo idle=50000 | 50,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 999 | 0.05 | 20.4 KB per socket (2 MB -> 999 MB) |
| fiber | /ws/echo echo c=64 | 6,956,555 | 231,883 | 0.26 | 0.54 | 2.55 | 99.8 | 1403 | 0.99 |  |
| fiber | /ws/echo echo c=1024 | 6,168,534 | 205,578 | 4.91 | 7.44 | 15.17 | 29.8 | 1287 | 1.00 |  |
| fiber | /ws/feed fanout-100x1000hz | 100 | 99,997 | 1.54 | 4.03 | 5.19 | 14.3 | 12 | 0.33 | 100/100 connected, 99997 of 100000 msgs/s expected, 0 gaps |
| fiber | /ws/feed fanout-1000x1000hz | 1,000 | 382,691 | 7.71 | 759.26 | 1444.64 | 2973.1 | 60 | 1.00 | 1000/1000 connected, 382691 of 1000000 msgs/s expected, 0 gaps |
| fiber | /ws/feed fanout-10000x100hz | 10,000 | 488,276 | 11413.47 | 21165.29 | 23096.54 | 27470.6 | 524 | 1.00 | 10000/10000 connected, 488276 of 1000000 msgs/s expected, 0 gaps |
| fiber | /ws/feed trading-500bots | 500 | 99,997 | 1.65 | 3.64 | 4.88 | 5.8 | 38 | 0.37 | 500/500 connected, 99997 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 2.44 p99 3.88 p99.9 4.63 ms, 0 errors |
| fiber | /ws/feed trading-2000bots | 2,000 | 582,975 | 5104.45 | 11367.22 | 12102.37 | 12947.8 | 122 | 0.99 | 2000/2000 connected, 582975 of 1000000 msgs/s expected, 0 gaps; orders 805/s, rtt p50 157.31 p99 898.17 p99.9 1420.76 ms, 0 errors |
| axum | /ws/echo idle=50000 | 15,226 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 2034 | 0.03 | -0.1 KB per socket (1 MB -> 0 MB); server oom-killed |
| axum | /ws/echo echo c=64 | 0 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 0 | 0.00 | server oom-killed |
| axum | /ws/echo echo c=1024 | 0 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 0 | 0.00 | server oom-killed |
| axum | /ws/feed fanout-100x1000hz | 100 | 99,999 | 1.01 | 2.38 | 2.75 | 3.5 | 15 | 0.20 | 100/100 connected, 99999 of 100000 msgs/s expected, 0 gaps |
| axum | /ws/feed fanout-1000x1000hz | 1,000 | 663,871 | 4411.35 | 6504.53 | 7175.16 | 7575.6 | 139 | 0.98 | 1000/1000 connected, 663871 of 1000000 msgs/s expected, 78359 gaps |
| axum | /ws/feed fanout-10000x100hz | 10,000 | 532,338 | 18320.55 | 30607.35 | 33639.83 | 37018.9 | 1362 | 1.00 | 10000/10000 connected, 532338 of 1000000 msgs/s expected, 0 gaps |
| axum | /ws/feed trading-500bots | 500 | 100,002 | 3.34 | 7.03 | 7.44 | 8.5 | 76 | 0.67 | 500/500 connected, 100002 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 3.17 p99 6.88 p99.9 7.58 ms, 0 errors |
| axum | /ws/feed trading-2000bots | 2,000 | 599,758 | 6932.22 | 8572.39 | 8684.35 | 9252.5 | 300 | 0.98 | 2000/2000 connected, 599758 of 1000000 msgs/s expected, 31609 gaps; orders 664/s, rtt p50 28.30 p99 611.30 p99.9 616.03 ms, 0 errors |
| bun | /ws/echo idle=50000 | 50,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 239 | 0.04 | 4.7 KB per socket (7 MB -> 239 MB) |
| bun | /ws/echo echo c=64 | 8,478,871 | 282,626 | 0.21 | 0.44 | 2.34 | 3.6 | 36 | 0.98 |  |
| bun | /ws/echo echo c=1024 | 7,611,621 | 253,683 | 4.08 | 6.99 | 9.49 | 15.4 | 37 | 1.00 |  |
| bun | /ws/feed fanout-100x1000hz | 100 | 100,010 | 0.77 | 1.60 | 3.95 | 5.0 | 8 | 0.06 | 100/100 connected, 100010 of 100000 msgs/s expected, 0 gaps |
| bun | /ws/feed fanout-1000x1000hz | 1,000 | 703,848 | 5073.07 | 9495.74 | 9962.64 | 10476.4 | 136 | 0.23 | 1000/1000 connected, 703848 of 1000000 msgs/s expected, 0 gaps |
| bun | /ws/feed fanout-10000x100hz | 10,000 | 230,863 | 21.62 | 42.00 | 43.15 | 44.6 | 58 | 0.98 | 10000/10000 connected, 230863 of 1000000 msgs/s expected, 0 gaps |
| bun | /ws/feed trading-500bots | 500 | 100,000 | 0.83 | 1.80 | 3.93 | 5.4 | 11 | 0.19 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.21 p99 0.95 p99.9 2.41 ms, 0 errors |
| bun | /ws/feed trading-2000bots | 2,000 | 639,839 | 6139.03 | 11691.74 | 12212.34 | 12773.9 | 69 | 0.48 | 2000/2000 connected, 639839 of 1000000 msgs/s expected, 0 gaps; orders 2003/s, rtt p50 10.86 p99 96.03 p99.9 113.01 ms, 0 errors |

## Notes

1. latency anole 1cpu h2-tls /json rate=75%max: fell behind: 152612 of 482592 req/s
2. latency anole 1cpu h2-tls /json rate=50%max: fell behind: 160184 of 321728 req/s
3. latency anole 1cpu h3 /json rate=1000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
4. latency anole 1cpu h3 /json rate=5000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 5000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
5. latency anole 1cpu h3 /json rate=20000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 20000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
6. latency anole 1cpu h3 /json rate=50%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 185446 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with H...
7. latency anole 1cpu h3 /json rate=75%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 278169 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with H...
8. latency axum 1cpu h2-tls /json rate=75%max: fell behind: 122102 of 188416 req/s
9. latency axum 1cpu h3 /json rate=1000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
10. latency axum 1cpu h3 /json rate=5000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 5000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
11. latency axum 1cpu h3 /json rate=20000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 20000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
12. latency axum 1cpu h3 /json rate=50%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 58824 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
13. latency axum 1cpu h3 /json rate=75%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 88236 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HT...
14. latency fastify 1cpu h2-tls /json rate=75%max: fell behind: 38867 of 46565 req/s
15. latency fastapi 1cpu h3 /json rate=1000: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1000 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
16. latency fastapi 1cpu h3 /json rate=50%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1270 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
17. latency fastapi 1cpu h3 /json rate=75%max: error: oha --no-tui --output-format json -z 30s -c 64 --insecure -q 1905 --latency-correction --http-version 3 https://127.0.0.1:8443/json: exit status 1: Error: Your Oha instance has not been built with HTT...
