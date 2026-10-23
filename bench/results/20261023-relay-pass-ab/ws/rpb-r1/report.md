# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "99c0fbdd0eee118c998a3e1243bab1be5e6873cd",
  "date": "2026-10-23T09:39:17Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@rpb": "8af15fde1c0b", "loadgen": "bc6c1d9f28c2"}
}

```

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@rpb | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 239 | 0.03 | 24.3 KB per socket (2 MB -> 239 MB) |
| anole@rpb | /ws/echo echo c=64 | 4,142,046 | 276,132 | 0.23 | 0.48 | 0.89 | 8.1 | 194 | 0.99 |  |
| anole@rpb | /ws/echo echo c=1024 | 3,547,811 | 236,443 | 4.29 | 5.04 | 5.99 | 13.4 | 37 | 1.00 |  |
| anole@rpb | /ws/feed fanout-100x1000hz | 100 | 100,000 | 0.70 | 1.69 | 1.97 | 2.2 | 5 | 0.11 | 100/100 connected, 100000 of 100000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed fanout-1000x1000hz | 1,000 | 627,454 | 3436.45 | 6382.12 | 6644.27 | 6862.8 | 37 | 0.43 | 1000/1000 connected, 627454 of 1000000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed fanout-10000x100hz | 10,000 | 197,269 | 12.53 | 36.80 | 50.83 | 55.2 | 340 | 1.00 | 10000/10000 connected, 197269 of 1000000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed trading-500bots | 500 | 99,998 | 0.86 | 2.17 | 2.79 | 3.2 | 20 | 0.35 | 500/500 connected, 99998 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.25 p99 0.41 p99.9 0.50 ms, 0 errors |
| anole@rpb | /ws/feed trading-2000bots | 2,000 | 642,936 | 1550.28 | 3609.62 | 3967.12 | 4391.4 | 77 | 0.99 | 2000/2000 connected, 642936 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 47.88 p99 120.93 p99.9 145.46 ms, 0 errors |

