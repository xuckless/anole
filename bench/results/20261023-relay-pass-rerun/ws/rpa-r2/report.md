# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "8a0749e76840a099ef713d7b74793f576b911cb5",
  "date": "2026-10-23T11:58:58Z",
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
| anole@rpa | /ws/echo echo c=64 | 4,133,218 | 275,544 | 0.23 | 0.48 | 0.85 | 6.9 | 199 | 1.00 |  |
| anole@rpa | /ws/echo echo c=1024 | 3,539,107 | 235,869 | 4.29 | 5.02 | 5.88 | 9.6 | 37 | 1.00 |  |
| anole@rpa | /ws/feed fanout-100x1000hz | 100 | 99,996 | 1.47 | 2.98 | 3.15 | 3.6 | 5 | 0.31 | 100/100 connected, 99996 of 100000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-1000x1000hz | 1,000 | 269,715 | 6944.95 | 12350.64 | 12452.27 | 12471.2 | 144 | 1.00 | 1000/1000 connected, 269715 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed fanout-10000x100hz | 10,000 | 195,415 | 13.96 | 40.20 | 51.09 | 52.4 | 326 | 1.00 | 10000/10000 connected, 195415 of 1000000 msgs/s expected, 0 gaps |
| anole@rpa | /ws/feed trading-500bots | 500 | 100,000 | 1.11 | 2.62 | 3.25 | 3.8 | 19 | 0.40 | 500/500 connected, 100000 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 1.14 p99 2.35 p99.9 3.35 ms, 0 errors |
| anole@rpa | /ws/feed trading-2000bots | 2,000 | 254,006 | 7257.33 | 12719.65 | 12821.92 | 12850.9 | 218 | 1.00 | 2000/2000 connected, 254006 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 8.69 p99 10.41 p99.9 11.93 ms, 0 errors |

