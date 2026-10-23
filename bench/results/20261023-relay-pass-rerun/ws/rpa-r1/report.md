# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "8a0749e76840a099ef713d7b74793f576b911cb5",
  "date": "2026-10-23T11:48:30Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@rpa": "922d6458bca3", "loadgen": "bc6c1d9f28c2"}
}

```

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@rpa | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 239 | 0.03 | 24.3 KB per socket (2 MB -> 239 MB) |
| anole@rpa | /ws/echo echo c=64 | 4,207,161 | 280,473 | 0.22 | 0.47 | 0.85 | 6.9 | 194 | 1.00 |  |
| anole@rpa | /ws/echo echo c=1024 | 3,563,561 | 237,502 | 4.27 | 4.96 | 5.79 | 9.9 | 37 | 1.00 |  |
| anole@rpa | /ws/feed fanout-100x1000hz | 100 | 99,999 | 1.47 | 3.00 | 3.15 | 3.5 | 5 | 0.31 | 100/100 connected, 99999 of 100000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-1000x1000hz | 1,000 | 268,700 | 6969.74 | 12361.10 | 12461.01 | 12490.1 | 144 | 1.00 | 1000/1000 connected, 268700 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-10000x100hz | 10,000 | 191,989 | 19.07 | 45.54 | 51.95 | 53.3 | 325 | 1.00 | 10000/10000 connected, 191989 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed trading-500bots | 500 | 100,000 | 0.87 | 2.27 | 2.78 | 3.3 | 19 | 0.41 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1001/s, rtt p50 0.23 p99 0.40 p99.9 0.50 ms, 0 errors |
| anole@rpa | /ws/feed trading-2000bots | 2,000 | 254,562 | 7248.63 | 12675.85 | 12775.79 | 12812.1 | 218 | 1.00 | 2000/2000 connected, 254562 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 8.60 p99 10.40 p99.9 18.13 ms, 0 errors |

