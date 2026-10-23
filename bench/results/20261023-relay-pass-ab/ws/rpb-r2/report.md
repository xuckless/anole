# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "99c0fbdd0eee118c998a3e1243bab1be5e6873cd",
  "date": "2026-10-23T09:42:46Z",
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
| anole@rpb | /ws/echo echo c=64 | 4,171,962 | 278,126 | 0.23 | 0.49 | 0.87 | 6.6 | 194 | 1.00 |  |
| anole@rpb | /ws/echo echo c=1024 | 3,492,604 | 232,769 | 4.36 | 5.09 | 6.10 | 10.3 | 37 | 1.00 |  |
| anole@rpb | /ws/feed fanout-100x1000hz | 100 | 99,989 | 0.63 | 1.70 | 1.95 | 2.3 | 5 | 0.06 | 100/100 connected, 99989 of 100000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed fanout-1000x1000hz | 1,000 | 664,149 | 3099.24 | 5788.41 | 6048.31 | 6433.2 | 37 | 0.40 | 1000/1000 connected, 664149 of 1000000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed fanout-10000x100hz | 10,000 | 187,900 | 25.03 | 52.14 | 53.96 | 55.5 | 351 | 1.00 | 10000/10000 connected, 187900 of 1000000 msgs/s expected, 0 gaps |
| anole@rpb | /ws/feed trading-500bots | 500 | 100,000 | 0.79 | 1.94 | 2.58 | 3.1 | 20 | 0.32 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.89 p99 2.40 p99.9 3.35 ms, 0 errors |
| anole@rpb | /ws/feed trading-2000bots | 2,000 | 621,023 | 1657.72 | 3883.00 | 4200.45 | 4699.7 | 77 | 0.98 | 2000/2000 connected, 621023 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 40.42 p99 114.75 p99.9 143.83 ms, 0 errors |

