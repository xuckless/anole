# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "3977674330f220bf6fa2babb1f0ad4b90f2f2df1",
  "date": "2026-10-19T02:35:55Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "066855b5c62e", "fiber": "75b68811f0bb", "gohttp": "e09ab561c9fc", "axum": "f0f361092ea2", "express": "b57939d6c832", "fastify": "1ef55db601fb", "fastapi": "a2c18b75f476", "nginx": "778bf4546dfe", "gohttp-wt": "34b4385e5c62", "axum-wt": "64895e89e857", "fastify-wt": "b20800801541", "fastapi-wt": "6ffa43a00a6b", "loadgen": "e3b957a4d74f"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **243,676** p99 1.09 ms [12 MB, 1.00] | **203,390** p99 1.49 ms [22 MB, 1.00] | **409,465** mean 1.55 ms [39 MB, 1.00] | **393,020** mean 1.62 ms [50 MB, 1.00] | **160,759** mean 3.95 ms [71 MB, 1.00] |
| fiber | **237,496** p99 1.59 ms [7 MB, 1.00] | **200,632** p99 1.89 ms [28 MB, 1.00] | N/A | N/A | N/A |
| gohttp | **145,311** p99 3.76 ms [12 MB, 1.00] | **137,547** p99 3.65 ms [18 MB, 1.00] | **65,029** mean 9.84 ms [16 MB, 1.00] | **65,153** mean 9.81 ms [18 MB, 1.00] | **84,657** mean 7.55 ms [20 MB, 1.00] |
| axum | **223,543** p99 1.22 ms [10 MB, 1.00] | **199,541** p99 1.40 ms [11 MB, 1.00] | **276,006** mean 2.31 ms [6 MB, 1.00] | **259,445** mean 2.45 ms [11 MB, 1.00] | **114,431** mean 5.57 ms [14 MB, 1.00] |
| express | **82,796** p99 3.62 ms [93 MB, 1.00] | **65,088** p99 5.55 ms [177 MB, 1.00] | N/A | N/A | N/A |
| fastify | **123,257** p99 2.24 ms [74 MB, 1.00] | **94,506** p99 3.14 ms [168 MB, 1.00] | **68,951** mean 9.28 ms [241 MB, 1.00] | **64,867** mean 9.84 ms [256 MB, 1.00] | N/A |
| fastapi | **23,230** p99 224.86 ms [47 MB, 1.00] | **20,817** p99 12.91 ms [73 MB, 1.00] | **5,722** mean 111.31 ms [115 MB, 1.00] | N/A | **2,623** mean 177.35 ms [94 MB, 0.99] |
| nginx | **257,946** p99 1.04 ms [31 MB, 1.00] | **186,096** p99 1.47 ms [42 MB, 1.00] | N/A | **222,307** mean 2.87 ms [41 MB, 1.00] | **436,911** mean 1.47 ms [70 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **238,174** p99 1.11 ms [12 MB, 1.00] | **186,975** p99 1.43 ms [22 MB, 1.00] | **413,906** mean 1.54 ms [56 MB, 1.00] | **387,448** mean 1.65 ms [66 MB, 1.00] | **150,621** mean 4.16 ms [85 MB, 1.00] |
| fiber | **223,306** p99 1.69 ms [14 MB, 1.00] | **192,997** p99 1.97 ms [26 MB, 1.00] | N/A | N/A | N/A |
| gohttp | **140,778** p99 3.80 ms [12 MB, 1.00] | **132,481** p99 3.87 ms [18 MB, 1.00] | **64,753** mean 9.88 ms [16 MB, 1.00] | **63,935** mean 10.00 ms [18 MB, 1.00] | **84,098** mean 7.60 ms [20 MB, 1.00] |
| axum | **220,339** p99 1.26 ms [11 MB, 1.00] | **184,445** p99 1.49 ms [12 MB, 1.00] | **270,861** mean 2.35 ms [6 MB, 1.00] | **254,428** mean 2.50 ms [11 MB, 1.00] | **117,882** mean 5.41 ms [15 MB, 1.00] |
| express | **79,175** p99 3.78 ms [121 MB, 1.00] | **62,337** p99 5.94 ms [180 MB, 1.00] | N/A | N/A | N/A |
| fastify | **117,122** p99 3.60 ms [103 MB, 1.00] | **93,336** p99 3.17 ms [170 MB, 1.00] | **68,295** mean 9.37 ms [253 MB, 1.00] | **64,153** mean 9.96 ms [260 MB, 1.00] | N/A |
| fastapi | **19,401** p99 276.68 ms [52 MB, 1.00] | **17,496** p99 15.76 ms [103 MB, 1.00] | **4,954** mean 128.96 ms [154 MB, 1.00] | N/A | **2,438** mean 78.02 ms [100 MB, 0.97] |
| nginx | **259,360** p99 1.05 ms [31 MB, 1.00] | **181,185** p99 1.52 ms [42 MB, 1.00] | N/A | **223,146** mean 2.86 ms [41 MB, 1.00] | **428,977** mean 1.51 ms [71 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **618,030** p99 0.50 ms [13 MB, 4.00] | **509,865** p99 0.65 ms [23 MB, 4.00] | **954,350** mean 0.66 ms [38 MB, 3.90] | **900,996** mean 0.73 ms [47 MB, 3.93] | **378,594** mean 1.70 ms [111 MB, 3.98] |
| fiber | **477,332** p99 3.87 ms [8 MB, 3.28] | **426,238** p99 3.89 ms [24 MB, 3.32] | N/A | N/A | N/A |
| gohttp | **334,250** p99 3.14 ms [15 MB, 3.86] | **305,637** p99 3.38 ms [20 MB, 3.88] | **163,989** mean 3.89 ms [23 MB, 3.93] | **154,242** mean 4.12 ms [23 MB, 3.91] | **202,365** mean 3.16 ms [25 MB, 3.84] |
| axum | **457,261** p99 1.06 ms [11 MB, 3.96] | **406,632** p99 1.20 ms [12 MB, 3.97] | **599,315** mean 1.06 ms [8 MB, 3.97] | **560,970** mean 1.12 ms [13 MB, 3.97] | **275,118** mean 2.33 ms [16 MB, 3.89] |
| express | **246,778** p99 1.40 ms [346 MB, 4.00] | **198,503** p99 2.71 ms [650 MB, 3.99] | N/A | N/A | N/A |
| fastify | **357,362** p99 1.01 ms [278 MB, 4.00] | **279,421** p99 1.39 ms [558 MB, 3.99] | **255,040** mean 2.43 ms [1148 MB, 3.98] | **223,445** mean 2.90 ms [879 MB, 3.94] | N/A |
| fastapi | **77,960** p99 3.64 ms [195 MB, 3.99] | **69,370** p99 3.97 ms [222 MB, 4.00] | **16,205** mean 39.40 ms [261 MB, 3.03] | N/A | **9,002** mean 55.54 ms [329 MB, 3.91] |
| nginx | **609,539** p99 0.53 ms [115 MB, 3.99] | **444,546** p99 0.67 ms [125 MB, 3.99] | N/A | **644,672** mean 0.95 ms [125 MB, 3.99] | **1,288,949** mean 0.50 ms [148 MB, 3.99] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| anole | **611,983** p99 0.52 ms [13 MB, 4.00] | **501,899** p99 0.64 ms [23 MB, 3.99] | **945,123** mean 0.67 ms [53 MB, 3.91] | **903,621** mean 0.70 ms [60 MB, 3.93] | **346,263** mean 1.82 ms [136 MB, 3.99] |
| fiber | **454,770** p99 4.09 ms [17 MB, 3.34] | **407,015** p99 4.07 ms [28 MB, 3.38] | N/A | N/A | N/A |
| gohttp | **326,843** p99 3.09 ms [14 MB, 3.87] | **293,594** p99 3.48 ms [20 MB, 3.88] | **161,519** mean 3.96 ms [23 MB, 3.92] | **149,522** mean 4.31 ms [25 MB, 3.90] | **201,011** mean 3.19 ms [26 MB, 3.84] |
| axum | **452,142** p99 1.07 ms [13 MB, 3.97] | **404,985** p99 1.19 ms [13 MB, 3.97] | **566,264** mean 1.12 ms [8 MB, 3.95] | **531,298** mean 1.19 ms [13 MB, 3.95] | **286,725** mean 2.22 ms [17 MB, 3.89] |
| express | **242,876** p99 1.53 ms [382 MB, 4.00] | **194,340** p99 2.76 ms [654 MB, 3.99] | N/A | N/A | N/A |
| fastify | **355,888** p99 0.94 ms [282 MB, 4.00] | **281,122** p99 1.12 ms [617 MB, 4.00] | **239,717** mean 2.62 ms [1255 MB, 3.97] | **222,077** mean 2.89 ms [892 MB, 3.96] | N/A |
| fastapi | **65,164** p99 4.08 ms [200 MB, 4.00] | **58,532** p99 4.67 ms [253 MB, 4.00] | **15,009** mean 42.54 ms [325 MB, 3.03] | N/A | **8,601** mean 48.28 ms [335 MB, 3.91] |
| nginx | **611,673** p99 0.51 ms [115 MB, 4.00] | **460,170** p99 0.65 ms [126 MB, 3.99] | N/A | **644,073** mean 0.95 ms [125 MB, 3.99] | **1,285,791** mean 0.50 ms [150 MB, 3.99] |

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 534 | 0.04 | 54.5 KB per socket (2 MB -> 534 MB) |
| anole | /ws/echo echo c=64 | 4,184,255 | 278,945 | 0.23 | 0.51 | 0.92 | 2.1 | 497 | 0.99 |  |
| anole | /ws/echo echo c=1024 | 3,490,537 | 232,634 | 4.35 | 5.20 | 5.91 | 8.4 | 509 | 1.00 |  |
| anole | /ws/feed fanout-100x1000hz | 100 | 100,001 | 0.17 | 0.61 | 1.14 | 2.0 | 7 | 0.35 | 100/100 connected, 100001 of 100000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-1000x1000hz | 1,000 | 295,147 | 1.71 | 3.62 | 4.46 | 6.3 | 55 | 1.00 | 1000/1000 connected, 295147 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-10000x100hz | 10,000 | 227,500 | 22.11 | 43.63 | 45.03 | 46.3 | 534 | 0.99 | 10000/10000 connected, 227500 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed trading-500bots | 500 | 100,000 | 0.87 | 1.82 | 2.81 | 4.1 | 31 | 0.33 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.16 p99 0.40 p99.9 1.22 ms, 0 errors |
| anole | /ws/feed trading-2000bots | 2,000 | 259,822 | 3.88 | 8.31 | 9.34 | 10.2 | 119 | 1.00 | 2000/2000 connected, 259822 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 0.58 p99 1.01 p99.9 1.68 ms, 0 errors |
| fiber | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 203 | 0.04 | 20.6 KB per socket (2 MB -> 203 MB) |
| fiber | /ws/echo echo c=64 | 3,550,588 | 236,701 | 0.26 | 0.55 | 1.47 | 22.0 | 362 | 0.99 |  |
| fiber | /ws/echo echo c=1024 | 3,198,054 | 213,067 | 4.75 | 6.22 | 10.63 | 25.8 | 70 | 1.00 |  |
| fiber | /ws/feed fanout-100x1000hz | 100 | 99,995 | 1.55 | 3.18 | 3.87 | 4.5 | 10 | 0.33 | 100/100 connected, 99995 of 100000 msgs/s expected, 0 gaps |
| fiber | /ws/feed fanout-1000x1000hz | 1,000 | 513,892 | 531.74 | 1373.41 | 1872.26 | 2307.0 | 57 | 0.99 | 1000/1000 connected, 513892 of 1000000 msgs/s expected, 0 gaps |
| fiber | /ws/feed fanout-10000x100hz | 10,000 | 498,323 | 7181.75 | 14674.34 | 17461.37 | 20875.5 | 518 | 1.00 | 10000/10000 connected, 498323 of 1000000 msgs/s expected, 0 gaps |
| fiber | /ws/feed trading-500bots | 500 | 100,005 | 1.64 | 3.56 | 4.04 | 4.4 | 36 | 0.37 | 500/500 connected, 100005 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 3.25 p99 3.95 p99.9 4.24 ms, 0 errors |
| fiber | /ws/feed trading-2000bots | 2,000 | 602,455 | 3475.05 | 6969.65 | 7513.31 | 8388.7 | 116 | 0.99 | 2000/2000 connected, 602455 of 1000000 msgs/s expected, 0 gaps; orders 756/s, rtt p50 172.35 p99 1000.95 p99.9 1564.10 ms, 0 errors |
| gohttp | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 273 | 0.04 | 27.8 KB per socket (2 MB -> 273 MB) |
| gohttp | /ws/echo echo c=64 | 2,822,472 | 188,159 | 0.32 | 1.30 | 1.85 | 7.9 | 236 | 0.99 |  |
| gohttp | /ws/echo echo c=1024 | 2,343,454 | 156,150 | 6.25 | 13.40 | 14.31 | 31.2 | 74 | 1.00 |  |
| gohttp | /ws/feed fanout-100x1000hz | 100 | 100,018 | 1.61 | 3.46 | 4.17 | 5.2 | 14 | 0.35 | 100/100 connected, 100018 of 100000 msgs/s expected, 0 gaps |
| gohttp | /ws/feed fanout-1000x1000hz | 1,000 | 211,994 | 3.42 | 6.82 | 7.95 | 9.7 | 102 | 0.81 | 1000/1000 connected, 211994 of 1000000 msgs/s expected, 0 gaps |
| gohttp | /ws/feed fanout-10000x100hz | 10,000 | 314,946 | 2379.93 | 19247.79 | 22355.37 | 26756.0 | 942 | 1.00 | 10000/10000 connected, 314946 of 1000000 msgs/s expected, 0 gaps |
| gohttp | /ws/feed trading-500bots | 500 | 100,000 | 1.82 | 3.79 | 5.49 | 8.2 | 58 | 0.40 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 3.56 p99 4.48 p99.9 5.96 ms, 0 errors |
| gohttp | /ws/feed trading-2000bots | 2,000 | 127,040 | 2.12 | 4.42 | 7.91 | 8.8 | 208 | 0.68 | 2000/2000 connected, 127040 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 2.21 p99 9.99 p99.9 11.78 ms, 0 errors |
| axum | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 1345 | 0.05 | 137.6 KB per socket (1 MB -> 1345 MB) |
| axum | /ws/echo echo c=64 | 2,673,024 | 178,196 | 0.36 | 0.51 | 1.66 | 2.3 | 11 | 0.99 |  |
| axum | /ws/echo echo c=1024 | 2,253,519 | 149,989 | 1.28 | 159.08 | 174.46 | 179.4 | 142 | 1.00 |  |
| axum | /ws/feed fanout-100x1000hz | 100 | 99,998 | 1.01 | 2.63 | 3.25 | 3.9 | 15 | 0.20 | 100/100 connected, 99998 of 100000 msgs/s expected, 0 gaps |
| axum | /ws/feed fanout-1000x1000hz | 1,000 | 609,396 | 3658.46 | 4185.91 | 4273.77 | 4535.5 | 139 | 0.98 | 1000/1000 connected, 609396 of 1000000 msgs/s expected, 19172 gaps |
| axum | /ws/feed fanout-10000x100hz | 10,000 | 535,755 | 21297.29 | 32472.10 | 34832.39 | 38393.3 | 1359 | 1.00 | 10000/10000 connected, 535755 of 1000000 msgs/s expected, 4 gaps |
| axum | /ws/feed trading-500bots | 500 | 100,006 | 3.31 | 7.04 | 7.50 | 8.3 | 76 | 0.65 | 500/500 connected, 100006 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 2.66 p99 3.48 p99.9 3.69 ms, 0 errors |
| axum | /ws/feed trading-2000bots | 2,000 | 552,767 | 7969.50 | 8435.37 | 8572.91 | 8799.4 | 299 | 0.99 | 2000/2000 connected, 552767 of 1000000 msgs/s expected, 52352 gaps; orders 725/s, rtt p50 424.37 p99 437.67 p99.9 440.34 ms, 0 errors |
| express | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 128 | 0.04 | 10.2 KB per socket (29 MB -> 128 MB) |
| express | /ws/echo echo c=64 | 3,137,090 | 209,134 | 0.29 | 0.65 | 1.92 | 8.1 | 172 | 0.99 |  |
| express | /ws/echo echo c=1024 | 2,743,022 | 182,800 | 5.38 | 8.05 | 10.47 | 15.0 | 186 | 1.00 |  |
| express | /ws/feed fanout-100x1000hz | 100 | 99,999 | 0.18 | 1.01 | 1.67 | 2.6 | 42 | 0.37 | 100/100 connected, 99999 of 100000 msgs/s expected, 0 gaps |
| express | /ws/feed fanout-1000x1000hz | 1,000 | 263,292 | 1.88 | 3.95 | 4.84 | 6.2 | 49 | 0.98 | 1000/1000 connected, 263292 of 1000000 msgs/s expected, 0 gaps |
| express | /ws/feed fanout-10000x100hz | 9,698 | 197,704 | 24.07 | 47.99 | 49.17 | 50.1 | 162 | 0.98 | 9698/10000 connected, 197704 of 1000000 msgs/s expected, 0 gaps |
| express | /ws/feed trading-500bots | 500 | 100,013 | 0.99 | 2.16 | 2.78 | 3.0 | 48 | 0.41 | 500/500 connected, 100013 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 3.66 p99 5.39 p99.9 6.34 ms, 0 errors |
| express | /ws/feed trading-2000bots | 2,000 | 220,792 | 4.42 | 9.00 | 9.72 | 10.2 | 119 | 0.99 | 2000/2000 connected, 220792 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 24.59 p99 49.12 p99.9 63.80 ms, 0 errors |
| fastify | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 176 | 0.05 | 14.7 KB per socket (32 MB -> 176 MB) |
| fastify | /ws/echo echo c=64 | 2,932,181 | 195,474 | 0.31 | 0.66 | 1.98 | 11.2 | 216 | 0.99 |  |
| fastify | /ws/echo echo c=1024 | 2,541,360 | 169,357 | 5.79 | 8.45 | 10.70 | 14.9 | 226 | 1.00 |  |
| fastify | /ws/feed fanout-100x1000hz | 100 | 99,998 | 0.18 | 0.94 | 1.52 | 2.5 | 44 | 0.37 | 100/100 connected, 99998 of 100000 msgs/s expected, 0 gaps |
| fastify | /ws/feed fanout-1000x1000hz | 1,000 | 261,406 | 1.88 | 3.82 | 4.40 | 5.8 | 78 | 0.98 | 1000/1000 connected, 261406 of 1000000 msgs/s expected, 0 gaps |
| fastify | /ws/feed fanout-10000x100hz | 8,938 | 196,516 | 22.14 | 44.01 | 45.95 | 47.9 | 251 | 0.98 | 8938/10000 connected, 196516 of 1000000 msgs/s expected, 0 gaps |
| fastify | /ws/feed trading-500bots | 500 | 100,000 | 0.98 | 2.00 | 2.54 | 3.2 | 65 | 0.41 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1001/s, rtt p50 0.35 p99 2.15 p99.9 6.82 ms, 0 errors |
| fastify | /ws/feed trading-2000bots | 2,000 | 223,081 | 4.35 | 8.97 | 15.10 | 16.6 | 133 | 0.99 | 2000/2000 connected, 223081 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 23.25 p99 46.88 p99.9 56.65 ms, 0 errors |
| fastapi | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 379 | 0.22 | 34.6 KB per socket (41 MB -> 379 MB) |
| fastapi | /ws/echo echo c=64 | 1,409,356 | 93,953 | 0.68 | 0.77 | 1.92 | 2.4 | 342 | 1.00 |  |
| fastapi | /ws/echo echo c=1024 | 1,038,358 | 69,154 | 14.56 | 17.39 | 18.29 | 131.9 | 345 | 1.00 |  |
| fastapi | /ws/feed fanout-100x1000hz | 100 | 100,002 | 0.25 | 0.58 | 1.53 | 2.2 | 44 | 0.48 | 100/100 connected, 100002 of 100000 msgs/s expected, 0 gaps |
| fastapi | /ws/feed fanout-1000x1000hz | 1,000 | 195,874 | 2.55 | 5.37 | 6.05 | 7.5 | 74 | 1.00 | 1000/1000 connected, 195874 of 1000000 msgs/s expected, 0 gaps |
| fastapi | /ws/feed fanout-10000x100hz | 4,896 | 128,642 | 18.28 | 35.88 | 37.19 | 39.1 | 207 | 1.00 | 4896/10000 connected, 128642 of 1000000 msgs/s expected, 0 gaps |
| fastapi | /ws/feed trading-500bots | 500 | 100,003 | 1.33 | 2.71 | 3.45 | 4.2 | 59 | 0.55 | 500/500 connected, 100003 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 5.70 p99 6.67 p99.9 6.95 ms, 0 errors |
| fastapi | /ws/feed trading-2000bots | 2,000 | 160,357 | 6.14 | 12.25 | 13.17 | 13.6 | 111 | 1.00 | 2000/2000 connected, 160357 of 1000000 msgs/s expected, 0 gaps; orders 407/s, rtt p50 92.33 p99 124.36 p99.9 124.99 ms, 159 errors |

