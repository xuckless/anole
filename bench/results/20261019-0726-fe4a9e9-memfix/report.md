# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "fe4a9e902c2619de54b4008c0536a525409dd5d4",
  "date": "2026-10-19T07:28:16Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"anole": "2f567f8c2e2f", "loadgen": "7d475e309ccf"}
}

```

## WebSockets (HTTP/1.1)

Idle: sockets held open and the memory each costs. Echo: closed-loop 64-byte messages, msgs/s and round trip. Fan-out: subscribers on /ws/feed at the tick rate; delivered msgs/s against expected, and tick lag (receive time minus the server's send stamp). Trading: one bot in ten also sends orders on /ws/trade and waits for each fill; order round trip in the notes and the feed column.

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | /ws/echo idle=10000 | 10,000 | 0 | 0.00 | 0.00 | 0.00 | 0.0 | 309 | 0.03 | 31.4 KB per socket (2 MB -> 308 MB) |
| anole | /ws/echo echo c=64 | 4,184,294 | 278,949 | 0.23 | 0.48 | 0.84 | 1.6 | 272 | 0.99 |  |
| anole | /ws/echo echo c=1024 | 3,540,341 | 235,953 | 4.29 | 5.13 | 5.90 | 6.8 | 279 | 1.00 |  |
| anole | /ws/feed fanout-100x1000hz | 100 | 99,998 | 0.17 | 0.56 | 1.12 | 1.6 | 5 | 0.37 | 100/100 connected, 99998 of 100000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-1000x1000hz | 1,000 | 279,706 | 1.81 | 3.66 | 4.14 | 5.2 | 36 | 1.00 | 1000/1000 connected, 279706 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed fanout-10000x100hz | 10,000 | 226,128 | 22.30 | 44.08 | 45.59 | 46.5 | 347 | 1.00 | 10000/10000 connected, 226128 of 1000000 msgs/s expected, 0 gaps |
| anole | /ws/feed trading-500bots | 500 | 99,995 | 0.86 | 1.92 | 2.61 | 2.9 | 21 | 0.33 | 500/500 connected, 99995 of 100000 msgs/s expected, 0 gaps; orders 1000/s, rtt p50 0.25 p99 0.41 p99.9 0.49 ms, 0 errors |
| anole | /ws/feed trading-2000bots | 2,000 | 260,559 | 3.88 | 8.28 | 9.59 | 11.2 | 78 | 1.00 | 2000/2000 connected, 260559 of 1000000 msgs/s expected, 0 gaps; orders 2000/s, rtt p50 0.60 p99 1.07 p99.9 1.70 ms, 0 errors |

## gRPC

ghz, unary grpc.testing.TestService/UnaryCall (the interop semantics: a reply of response_size zero bytes) over plaintext HTTP/2, 8 connections with 64 calls in flight; ghz has no p99.9. Anole uses its interop server; the others the standard library of their language (grpc-go, tonic, @grpc/grpc-js, grpcio aio).

| Server | Case | Count | Rate/s | p50 ms | p99 ms | p99.9 ms | max ms | Memory MB | Cores busy | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| anole | UnaryCall 1cpu, 0 B reply | 1,266,784 | 84,456 | 0.25 | 1.54 | 0.00 | 8.7 | 7 | 0.74 | load generator at 13.4 of 16 CPUs |
| anole | UnaryCall 1cpu, 1024 B reply | 1,225,609 | 81,702 | 0.27 | 1.61 | 0.00 | 7.4 | 9 | 0.74 | load generator at 13.4 of 16 CPUs |
| anole | UnaryCall 4cpu, 0 B reply | 1,207,878 | 80,527 | 0.16 | 1.59 | 0.00 | 6.7 | 7 | 1.27 | load generator at 13.4 of 16 CPUs |
| anole | UnaryCall 4cpu, 1024 B reply | 1,164,469 | 77,632 | 0.17 | 1.69 | 0.00 | 8.5 | 9 | 1.25 | load generator at 13.3 of 16 CPUs |

