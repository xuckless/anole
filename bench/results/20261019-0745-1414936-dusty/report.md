# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "1414936a3b43baec66d35852b8040ccb5f83c953",
  "date": "2026-10-19T07:45:06Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"dusty": "d6170195a225", "loadgen": "5597c023c44a"}
}

```

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| dusty | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 395 | 0.03 | 40.3 KB per socket (1 MB -> 395 MB) |
| dusty | /ws/echo echo c=64 | 4,202,645 | 280,172 | 0.22 | 0.50 | 0.90 | 3.1 | 358 | 0.99 |  |
| dusty | /ws/echo echo c=1024 | 3,673,824 | 244,708 | 0.77 | 85.05 | 151.21 | 251.1 | 361 | 1.00 |  |
| dusty | /ws/feed fanout-100x1000hz | 100 | 99,993 | 0.17 | 0.58 | 1.08 | 1.6 | 5 | 0.31 | 100/100 connected, 99993 of 100000 msgs/s expected, 0 gaps |
| dusty | /ws/feed fanout-1000x1000hz | 1,000 | 287,816 | 1.75 | 3.55 | 4.02 | 5.0 | 41 | 0.99 | 1000/1000 connected, 287816 of 1000000 msgs/s expected, 0 gaps |
| dusty | /ws/feed fanout-10000x100hz | 10,000 | 233,446 | 17.58 | 41.54 | 43.21 | 44.8 | 394 | 1.00 | 10000/10000 connected, 233446 of 1000000 msgs/s expected, 0 gaps |
| dusty | /ws/feed trading-500bots | 500 | 100,000 | 0.84 | 1.85 | 2.30 | 2.5 | 23 | 0.32 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.24 p99 0.43 p99.9 0.54 ms, 0 errors |
| dusty | /ws/feed trading-2000bots | 2,000 | 265,706 | 3.76 | 7.96 | 8.87 | 10.0 | 88 | 1.00 | 2000/2000 connected, 265706 of 1000000 msgs/s expected, 0 gaps; orders 2001/s, rtt p50 0.60 p99 1.02 p99.9 1.72 ms, 0 errors |

