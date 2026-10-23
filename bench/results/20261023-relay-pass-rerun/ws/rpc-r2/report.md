# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "8a0749e76840a099ef713d7b74793f576b911cb5",
  "date": "2026-10-23T11:55:28Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole@rpc": "3d1c13b262aa", "loadgen": "bc6c1d9f28c2"}
}

```

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole@rpc | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 239 | 0.03 | 24.3 KB per socket (2 MB -> 239 MB) |
| anole@rpc | /ws/echo echo c=64 | 4,172,253 | 278,145 | 0.23 | 0.47 | 0.87 | 7.0 | 194 | 1.00 |  |
| anole@rpc | /ws/echo echo c=1024 | 3,511,531 | 234,027 | 4.33 | 5.08 | 6.09 | 10.4 | 37 | 1.00 |  |
| anole@rpc | /ws/feed fanout-100x1000hz | 100 | 99,994 | 0.71 | 1.76 | 2.00 | 2.4 | 5 | 0.09 | 100/100 connected, 99994 of 100000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed fanout-1000x1000hz | 1,000 | 648,871 | 3402.72 | 6091.65 | 6355.19 | 6829.4 | 37 | 0.42 | 1000/1000 connected, 648871 of 1000000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed fanout-10000x100hz | 10,000 | 191,479 | 20.39 | 46.92 | 48.36 | 54.0 | 347 | 0.99 | 10000/10000 connected, 191479 of 1000000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed trading-500bots | 500 | 100,000 | 0.86 | 1.89 | 2.68 | 3.1 | 20 | 0.30 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1003/s, rtt p50 0.25 p99 0.43 p99.9 0.54 ms, 0 errors |
| anole@rpc | /ws/feed trading-2000bots | 2,000 | 633,128 | 1240.65 | 2815.20 | 3117.94 | 3691.3 | 77 | 0.99 | 2000/2000 connected, 633128 of 1000000 msgs/s expected, 0 gaps; orders 1997/s, rtt p50 59.31 p99 129.19 p99.9 157.34 ms, 0 errors |

