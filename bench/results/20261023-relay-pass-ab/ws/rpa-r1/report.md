# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "99c0fbdd0eee118c998a3e1243bab1be5e6873cd",
  "date": "2026-10-23T09:35:48Z",
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
| anole@rpa | /ws/echo echo c=64 | 4,178,362 | 278,553 | 0.23 | 0.46 | 0.88 | 7.6 | 194 | 1.00 |  |
| anole@rpa | /ws/echo echo c=1024 | 3,478,508 | 231,830 | 4.38 | 5.08 | 6.03 | 10.9 | 37 | 1.00 |  |
| anole@rpa | /ws/feed fanout-100x1000hz | 100 | 99,994 | 1.45 | 2.96 | 3.19 | 3.5 | 5 | 0.31 | 100/100 connected, 99994 of 100000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-1000x1000hz | 1,000 | 267,991 | 6988.69 | 12384.94 | 12488.82 | 12517.2 | 145 | 1.00 | 1000/1000 connected, 267991 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-10000x100hz | 10,000 | 190,101 | 21.42 | 48.30 | 52.82 | 54.9 | 328 | 1.00 | 10000/10000 connected, 190101 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed trading-500bots | 500 | 100,000 | 1.16 | 2.59 | 3.22 | 3.7 | 19 | 0.38 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1002/s, rtt p50 0.24 p99 0.40 p99.9 0.49 ms, 0 errors |
| anole@rpa | /ws/feed trading-2000bots | 2,000 | 253,533 | 7241.98 | 12686.18 | 12787.53 | 12816.8 | 218 | 1.00 | 2000/2000 connected, 253533 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 8.70 p99 10.54 p99.9 14.03 ms, 0 errors |

