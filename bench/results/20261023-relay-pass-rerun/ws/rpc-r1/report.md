# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "8a0749e76840a099ef713d7b74793f576b911cb5",
  "date": "2026-10-23T11:51:59Z",
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
| anole@rpc | /ws/echo echo c=64 | 4,180,634 | 278,704 | 0.23 | 0.49 | 0.85 | 6.8 | 187 | 1.00 |  |
| anole@rpc | /ws/echo echo c=1024 | 3,583,132 | 238,804 | 4.24 | 4.95 | 5.83 | 11.8 | 37 | 1.00 |  |
| anole@rpc | /ws/feed fanout-100x1000hz | 100 | 99,993 | 0.70 | 1.75 | 2.02 | 2.2 | 5 | 0.09 | 100/100 connected, 99993 of 100000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed fanout-1000x1000hz | 1,000 | 647,944 | 3310.91 | 6100.89 | 6345.03 | 6612.3 | 37 | 0.42 | 1000/1000 connected, 647944 of 1000000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed fanout-10000x100hz | 10,000 | 189,433 | 23.31 | 50.02 | 52.80 | 54.5 | 350 | 0.99 | 10000/10000 connected, 189433 of 1000000 msgs/s expected, 0 gaps |
| anole@rpc | /ws/feed trading-500bots | 500 | 99,998 | 0.86 | 1.92 | 2.84 | 3.2 | 20 | 0.31 | 500/500 connected, 99998 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.23 p99 0.43 p99.9 1.40 ms, 0 errors |
| anole@rpc | /ws/feed trading-2000bots | 2,000 | 633,927 | 1553.37 | 3635.01 | 3952.31 | 4398.9 | 77 | 0.99 | 2000/2000 connected, 633927 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 31.07 p99 100.66 p99.9 128.55 ms, 0 errors |

