# Benchmark report

Environment: see `env.json`.

```json
{
  "commit": "cfa75fa5543178c74bc0212e390ab5a30107199c",
  "date": "2026-10-19T07:12:45Z",
  "cpu": "Intel(R) Core(TM) i7-14700F",
  "kernel": "7.2.9-200.fc44.x86_64",
  "governor": "performance",
  "docker": "29.8.0",
  "cpusets": {"sut_1cpu": "2", "sut_4cpu": "0,2,4,6", "postgres": "16-19", "loadgen": "8-15,20-27"},
  "images": {"bun": "b4823cba1d44", "loadgen": "6ebb6eff11cf"}
}

```

## Max throughput (closed loop)

Requests per second, then p99 latency for wrk runs (HTTP/1.1) or mean latency for h2load runs (h2load gives no percentiles); server memory (anon + kernel, MB) and how busy its cpuset was (cores, softirq included) in brackets. HTTP/1.1: wrk, 256 connections. HTTP/2 and HTTP/3: h2load, 64 connections × 10 streams.

### 1cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| bun | **215,463** p99 1.42 ms [14 MB, 1.00] | **195,083** p99 1.45 ms [16 MB, 1.00] | **563,611** mean 1.13 ms [17 MB, 1.00] | **544,262** mean 1.17 ms [17 MB, 1.00] | **394,858** mean 1.62 ms [24 MB, 1.00] |

### 1cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| bun | **217,975** p99 1.31 ms [14 MB, 1.00] | **194,817** p99 1.46 ms [16 MB, 1.00] | **579,519** mean 1.10 ms [17 MB, 1.00] | **560,089** mean 1.14 ms [17 MB, 1.00] | **397,133** mean 1.61 ms [24 MB, 1.00] |

### 4cpu, GET /plaintext

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| bun | **545,020** p99 0.85 ms [59 MB, 3.99] | **475,823** p99 1.05 ms [61 MB, 3.99] | **1,581,774** mean 0.40 ms [70 MB, 3.99] | **1,501,571** mean 0.41 ms [71 MB, 4.00] | **1,054,883** mean 0.61 ms [80 MB, 3.95] |

### 4cpu, GET /json

| Server | h1 | h1-tls | h2c | h2-tls | h3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| bun | **551,166** p99 0.90 ms [57 MB, 3.99] | **486,887** p99 1.04 ms [60 MB, 3.99] | **1,618,949** mean 0.39 ms [68 MB, 3.99] | **1,543,954** mean 0.40 ms [69 MB, 3.99] | **1,044,584** mean 0.61 ms [80 MB, 3.97] |

