# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "99c0fbdd0eee118c998a3e1243bab1be5e6873cd",
  "date": "2026-10-23T09:46:15Z",
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
| anole@rpa | /ws/echo echo c=64 | 4,118,724 | 274,577 | 0.23 | 0.50 | 0.91 | 7.0 | 194 | 1.00 |  |
| anole@rpa | /ws/echo echo c=1024 | 3,512,420 | 234,092 | 4.33 | 5.09 | 6.58 | 11.0 | 38 | 1.00 |  |
| anole@rpa | /ws/feed fanout-100x1000hz | 100 | 100,000 | 1.44 | 3.00 | 3.28 | 3.7 | 5 | 0.31 | 100/100 connected, 100000 of 100000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-1000x1000hz | 1,000 | 270,702 | 7004.14 | 12346.63 | 12445.80 | 12464.5 | 144 | 1.00 | 1000/1000 connected, 270702 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-10000x100hz | 10,000 | 188,352 | 23.29 | 49.75 | 53.08 | 56.4 | 336 | 1.00 | 10000/10000 connected, 188352 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed trading-500bots | 500 | 100,000 | 1.24 | 2.87 | 3.82 | 4.2 | 19 | 0.40 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.84 p99 2.15 p99.9 3.94 ms, 0 errors |
| anole@rpa | /ws/feed trading-2000bots | 2,000 | 215,044 | 7504.03 | 13271.92 | 13377.05 | 13394.8 | 218 | 1.00 | 2000/2000 connected, 215044 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 10.15 p99 13.07 p99.9 15.51 ms, 0 errors |

